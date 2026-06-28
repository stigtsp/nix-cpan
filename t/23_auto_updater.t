use v5.38;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use lib qw(t/lib);
use Test::CommandUtil qw(run_nix_cpan git_cmd);
use CPAN::Meta::YAML ();
sub load_yaml ($p) { CPAN::Meta::YAML->read($p)->[0] }

use_ok("Nix::MetaCPANCache");

my $tmpdir = tempdir(CLEANUP => 1);
my $cache_home = "$tmpdir/xdg";
my $cache_ns = "$cache_home/nix-cpan";
make_path($cache_ns);

# nixpkgs-shaped repo so nixpkgs_root resolves.
my $root = "$tmpdir/nixpkgs";
my $nix_file = "$root/pkgs/top-level/perl-packages.nix";
make_path("$root/pkgs/top-level");
open my $fh, ">", $nix_file or die $!;
print {$fh} <<'NIX';
{
  Root = buildPerlPackage {
    pname = "Root";
    version = "1.0";
    src = fetchurl {
      url = "mirror://cpan/authors/id/R/RO/ROOT/Root-1.0.tar.gz";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  };
}
NIX
close $fh;

# git repo on a non-main branch (git_sanity refuses main/master), with local user.
git_cmd($root, "init", "-q", "-b", "work");
git_cmd($root, "config", "user.email", "test\@example.com");
git_cmd($root, "config", "user.name", "Test");
git_cmd($root, "add", "-A");
git_cmd($root, "commit", "-q", "-m", "baseline");

# Mock cache: Root 2.0, no deps -> a safe (dep_delta 0) candidate.
my $mcc = Nix::MetaCPANCache->new(
  cache_file => "$tmpdir/dl.jsonl.gz", db_file => "$cache_ns/metacpan-cache.db");
$mcc->write_releases([
  {
    name => "Root-2.0", distribution => "Root", main_module => "Root",
    version => "2.0", version_numified => 2,
    checksum_sha256 => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url => "https://cpan.metacpan.org/authors/id/R/RO/ROOT/Root-2.0.tar.gz",
    dependency => [], provides => { "Root" => { file => "lib/Root.pm" } },
  },
]);

sub read_file ($p) { open my $f, "<", $p or die $!; local $/; <$f> }
sub porcelain { my $r = git_cmd($root, "status", "--porcelain"); $r->{out} }
sub commit_count { my $r = git_cmd($root, "rev-list", "--count", "HEAD"); my $n = $r->{out}; $n =~ s/\s+//g; $n }

my $base_commits = commit_count();

# --- 1) dry-run: verifies (stub build passes), reverts, no commit ---
my $rpt = "$tmpdir/report.yaml";
{
  my $r = run_nix_cpan($cache_home, {}, "auto", "Root", "--risk", "safe",
                       "--report_file", $rpt, "--nix-file", $nix_file);
  ok($r->{ok}, "auto dry-run exits 0 (no failures)");
  like($r->{out}, qr/OK\s+Root\s+1\.0 -> 2\.0/, "dry-run verifies Root");
  is(porcelain(), "", "dry-run leaves working tree clean (reverted)");
  is(commit_count(), $base_commits, "dry-run makes no commit");
  like(read_file($nix_file), qr/version = "1\.0"/, "file still at old version after dry-run");

  my $j = load_yaml($rpt);
  is(scalar $j->{updated}->@*, 1, "report: 1 updated");
  is($j->{updated}[0]{committed}, 0, "report: dry-run not committed");
  is(scalar $j->{failed}->@*, 0, "report: 0 failed");
}

# --- 2) forced build failure: reverts, no commit, recorded in report ---
{
  my $rpt2 = "$tmpdir/report2.yaml";
  my $r = run_nix_cpan($cache_home, { NIX_CPAN_FORCE_BUILD_FAIL => "Root" },
                       "auto", "Root", "--risk", "safe", "--commit",
                       "--report_file", $rpt2, "--nix-file", $nix_file);
  ok(!$r->{ok}, "auto exits non-zero when a build gate fails");
  is(porcelain(), "", "failed bump reverted -> working tree clean");
  is(commit_count(), $base_commits, "failed bump produces no commit");
  like(read_file($nix_file), qr/version = "1\.0"/, "file unchanged after failed bump");

  my $j = load_yaml($rpt2);
  is(scalar $j->{failed}->@*, 1, "report: 1 failed");
  is($j->{failed}[0]{attr}, "Root", "report: failure records attr");
  is($j->{failed}[0]{old}, "1.0", "report: failure records old version");
  is($j->{failed}[0]{new}, "2.0", "report: failure records new version");
  like($j->{failed}[0]{reason}, qr/forced build failure/, "report: failure records reason");
}

# --- 3) real commit path (stub build passes): one per-package commit ---
{
  my $r = run_nix_cpan($cache_home, {}, "auto", "Root", "--risk", "safe",
                       "--commit", "--nix-file", $nix_file);
  ok($r->{ok}, "auto --commit exits 0");
  is(commit_count(), $base_commits + 1, "exactly one commit created");
  like(read_file($nix_file), qr/version = "2\.0"/, "file bumped to new version");
  my $log = git_cmd($root, "log", "-1", "--format=%s")->{out};
  like($log, qr/perlPackages\.Root: 1\.0 -> 2\.0/, "commit message follows nixpkgs convention");
  is(porcelain(), "", "tree clean after commit");
}

# --- 4) refuses on a dirty file (auto reverts via git checkout -> data loss) ---
{
  open my $a, ">>", $nix_file or die $!;
  print {$a} "\n# precious uncommitted edit\n";
  close $a;
  my $r = run_nix_cpan($cache_home, {}, "auto", "Root", "--risk", "safe",
                       "--nix-file", $nix_file);
  ok(!$r->{ok}, "auto refuses to run on a dirty file");
  like($r->{out} . ($r->{err} // ""), qr/uncommitted changes/, "explains why it refused");
  like(read_file($nix_file), qr/precious uncommitted edit/,
       "the user's uncommitted edit is preserved (not reverted)");
}

done_testing();
