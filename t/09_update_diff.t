use v5.38;
use Test::More;
use File::Temp qw(tempdir);
use lib qw(t/lib);
use Test::CommandUtil qw(run_nix_cpan);

use_ok("Nix::MetaCPANCache");

my $tmpdir = tempdir(CLEANUP => 1);
my $cache_home = "$tmpdir/xdg";
my $cache_ns = "$cache_home/nix-cpan";
mkdir $cache_home or die $!;
mkdir $cache_ns or die $!;

my $nix_file = "$tmpdir/perl-packages-mini.nix";
open my $fh, ">", $nix_file or die $!;
print {$fh} <<'NIX';
{
  Root = buildPerlPackage {
    name = "Root";
    version = "1.0";
    url = "mirror://cpan/authors/id/R/RO/ROOT/Root-1.0.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    buildInputs = [  ];
    propagatedBuildInputs = [  ];
  };
}
NIX
close $fh;

my $db_file = "$cache_ns/metacpan-cache.db";
my $cache_file = "$tmpdir/download.jsonl.gz";
my $mcc = new_ok(
  "Nix::MetaCPANCache" => [ cache_file => $cache_file, db_file => $db_file ],
  "Nix::MetaCPANCache"
);

my $releases = [
  {
    name             => "Root-2.0",
    distribution     => "Root",
    main_module      => "Root",
    version          => "2.0",
    version_numified => 2,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/R/RO/ROOT/Root-2.0.tar.gz",
    dependency       => [],
    provides         => { "Root" => { file => "lib/Root.pm" } },
  },
];
$mcc->write_releases($releases);
$mcc->write_dependencies();

my $res = run_nix_cpan(
  $cache_home,
  {},
  "update",
  "Root",
  "--diff",
  "--nix-file",
  $nix_file,
);
ok($res->{ok}, "update --diff command succeeds");
ok(!defined($res->{err}) || $res->{err} eq "", "update --diff has no stderr");
my $out = $res->{out};
like($out, qr/diff -- perlPackages\.Root/,
     "update --diff prints derivation diff header");
like($out, qr/^\Q-\E.*version = "1\.0";/m,
     "update --diff includes removed old version line");
like($out, qr/^\Q+\E.*version = "2\.0";/m,
     "update --diff includes added new version line");

open my $rfh, "<", $nix_file or die $!;
local $/ = undef;
my $current = <$rfh>;
close $rfh;
like($current, qr/version = "1\.0";/,
     "update --diff without --inplace does not modify nix file");

done_testing();
