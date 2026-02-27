use v5.38;
use Test::More;
use File::Temp qw(tempdir);
use lib qw(t/lib);
use Test::CommandUtil qw(run_cmd run_nix_cpan git_cmd git_ok);

use_ok("Nix::MetaCPANCache");

my $tmpdir = tempdir(CLEANUP => 1);
my $cache_home = "$tmpdir/xdg";
my $cache_ns = "$cache_home/nix-cpan";
mkdir $cache_home or die $!;
mkdir $cache_ns or die $!;

my $repo = "$tmpdir/repo";
my $nix_dir = "$repo/pkgs/top-level";
my $nix_file = "$nix_dir/perl-packages.nix";

mkdir $repo or die $!;
mkdir "$repo/pkgs" or die $!;
mkdir "$repo/pkgs/top-level" or die $!;

open my $fh, ">", $nix_file or die $!;
print {$fh} <<'NIX';
{
  Root = buildPerlPackage {
    name = "Root";
    version = "1.0";
    url = "mirror://cpan/authors/id/R/RO/ROOT/Root-1.0.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    propagatedBuildInputs = [  ];
  };
}
NIX
close $fh;

{
  git_ok("git init succeeds", $repo, "init");
  git_ok("git checkout -b feature succeeds", $repo, "checkout", "-b", "feature");
  git_ok("git add succeeds", $repo, "add", "pkgs/top-level/perl-packages.nix");
  my $init = run_cmd(
    "env",
    "GIT_CONFIG_NOSYSTEM=1",
    "GIT_CONFIG_GLOBAL=/dev/null",
    "HOME=$repo",
    "XDG_CONFIG_HOME=$repo/.xdg-config",
    "GIT_AUTHOR_NAME=test",
    "GIT_AUTHOR_EMAIL=test\@example.org",
    "GIT_COMMITTER_NAME=test",
    "GIT_COMMITTER_EMAIL=test\@example.org",
    "git",
    "-C",
    $repo,
    "commit",
    "-m",
    "init"
  );
  ok($init->{ok}, "initial commit succeeds");
}

my $db_file = "$cache_ns/metacpan-cache.db";
my $cache_file = "$tmpdir/download.jsonl.gz";
my $mcc = new_ok(
  "Nix::MetaCPANCache" => [ cache_file => $cache_file, db_file => $db_file ],
  "Nix::MetaCPANCache"
);

my $sha = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
my $releases = [
  {
    name             => "Root-2.0",
    distribution     => "Root",
    main_module      => "Root",
    version          => "2.0",
    version_numified => 2.0,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/R/RO/ROOT/Root-2.0.tar.gz",
    dependency       => [
      {
        module       => "Missing::Dep",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
    ],
    provides         => { "Root" => { file => "lib/Root.pm" } },
  },
  {
    name             => "Missing-Dep-1.2",
    distribution     => "Missing-Dep",
    main_module      => "Missing::Dep",
    version          => "1.2",
    version_numified => 1.2,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/M/MI/MISS/Missing-Dep-1.2.tar.gz",
    dependency       => [],
    provides         => { "Missing::Dep" => { file => "lib/Missing/Dep.pm" } },
  },
];
$mcc->write_releases($releases);
$mcc->write_dependencies();

my $update = run_nix_cpan(
  $cache_home,
  {
    GIT_CONFIG_NOSYSTEM => 1,
    GIT_CONFIG_GLOBAL   => "/dev/null",
    HOME                => $repo,
    XDG_CONFIG_HOME     => "$repo/.xdg-config",
    GIT_AUTHOR_NAME     => "test",
    GIT_AUTHOR_EMAIL    => "test\@example.org",
    GIT_COMMITTER_NAME  => "test",
    GIT_COMMITTER_EMAIL => "test\@example.org",
  },
  "update",
  "Root",
  "--missing",
  "--inplace",
  "--commit",
  "--nix-file",
  $nix_file,
);
ok($update->{ok}, "update --missing --commit succeeds");
ok(!defined($update->{err}) || $update->{err} eq "", "update --missing --commit has no stderr");

my $log = git_cmd($repo, "log", "-1", "--pretty=%B");
ok($log->{ok}, "git log for latest commit succeeds");
my $msg = $log->{out};
like($msg, qr/^perlPackages\.Root: 1\.0 -> 2\.0/m, "commit subject is update message");
like($msg, qr/^dependencies:$/m, "commit body contains dependencies header");
like($msg, qr/^perlPackages\.MissingDep: init at 1\.2$/m,
     "commit body lists missing dependency with version");

done_testing();
