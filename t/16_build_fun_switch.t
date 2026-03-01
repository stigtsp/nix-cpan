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
  BuildSwitch = buildPerlModule {
    pname = "Build-Switch";
    version = "1.0";
    src = fetchurl {
      url = "mirror://cpan/authors/id/B/BU/BUILD/Build-Switch-1.0.tar.gz";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
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
    name             => "Build-Switch-1.1",
    distribution     => "Build-Switch",
    main_module      => "Build::Switch",
    version          => "1.1",
    version_numified => 1.1,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/B/BU/BUILD/Build-Switch-1.1.tar.gz",
    metadata         => {
      prereqs => {
        configure => {
          requires => {
            "ExtUtils::MakeMaker" => "0",
          },
        },
      },
      license => [ "perl_5" ],
    },
    license          => [ "perl_5" ],
    dependency       => [],
    provides         => { "Build::Switch" => { file => "lib/Build/Switch.pm" } },
  },
];
$mcc->write_releases($releases);
$mcc->write_dependencies();

my $res = run_nix_cpan(
  $cache_home,
  {},
  "update",
  "BuildSwitch",
  "--inplace",
  "--nix-file",
  $nix_file,
);
ok($res->{ok}, "update succeeds for build function switch");
ok(!defined($res->{err}) || $res->{err} eq "", "update has no stderr for build function switch");

open my $rfh, "<", $nix_file or die $!;
local $/ = undef;
my $new_nix = <$rfh>;
close $rfh;

like($new_nix, qr/BuildSwitch\s*=\s*buildPerlPackage\s*\{/s,
     "build function switches from buildPerlModule to buildPerlPackage");
like($new_nix, qr/version = "1\.1";/s,
     "version updated");
like($new_nix, qr/mirror:\/\/cpan\/authors\/id\/B\/BU\/BUILD\/Build-Switch-1\.1\.tar\.gz/s,
     "source url updated");

done_testing();
