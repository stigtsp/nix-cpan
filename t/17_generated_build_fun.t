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
        module       => "Build::Only",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
    ],
    provides => { "Root" => { file => "lib/Root.pm" } },
  },
  {
    name             => "Build-Only-1.0",
    distribution     => "Build-Only",
    main_module      => "Build::Only",
    version          => "1.0",
    version_numified => 1.0,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/B/BU/BUILD/Build-Only-1.0.tar.gz",
    metadata         => {
      prereqs => {
        configure => {
          requires => {
            "Module::Build::Tiny" => "0",
          },
        },
      },
    },
    dependency       => [],
    provides         => { "Build::Only" => { file => "lib/Build/Only.pm" } },
  },
];
$mcc->write_releases($releases);
$mcc->write_dependencies();

my $res = run_nix_cpan(
  $cache_home,
  {},
  "update",
  "Root",
  "--missing",
  "--inplace",
  "--nix-file",
  $nix_file,
);
ok($res->{ok}, "update --missing succeeds");

open my $rfh, "<", $nix_file or die $!;
local $/ = undef;
my $new_nix = <$rfh>;
close $rfh;

like($new_nix, qr/BuildOnly\s*=\s*buildPerlModule\s*\{/s,
     "generated missing stanza uses buildPerlModule when metadata indicates Module::Build");

done_testing();
