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
  CLIHelpers = buildPerlPackage {
    name = "CLI-Helpers";
    version = "1.8";
    url = "mirror://cpan/authors/id/B/BL/BLHOTSKY/CLI-Helpers-1.8.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    propagatedBuildInputs = [ CaptureTiny ];
  };

  CPAN = buildPerlPackage {
    name = "CPAN";
    version = "2.29";
    url = "mirror://cpan/authors/id/A/AN/ANDK/CPAN-2.29.tar.gz";
    hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
    propagatedBuildInputs = [ ArchiveZip ];
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
    name             => "CLI-Helpers-2.2",
    distribution     => "CLI-Helpers",
    main_module      => "CLI::Helpers",
    version          => "2.2",
    version_numified => 2.2,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/B/BL/BLHOTSKY/CLI-Helpers-2.2.tar.gz",
    dependency       => [
      {
        module       => "Term::ReadKey",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
    ],
    provides         => { "CLI::Helpers" => { file => "lib/CLI/Helpers.pm" } },
  },
  {
    name             => "CPAN-2.38",
    distribution     => "CPAN",
    main_module      => "CPAN",
    version          => "2.38",
    version_numified => 2.38,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/A/AN/ANDK/CPAN-2.38.tar.gz",
    dependency       => [
      {
        module       => "Term::ReadKey",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
    ],
    provides         => { "CPAN" => { file => "lib/CPAN.pm" } },
  },
  {
    name             => "TermReadKey-2.38",
    distribution     => "TermReadKey",
    main_module      => "Term::ReadKey",
    version          => "2.38",
    version_numified => 2.38,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/J/JS/JSTOWE/TermReadKey-2.38.tar.gz",
    dependency       => [],
    provides         => { "Term::ReadKey" => { file => "lib/Term/ReadKey.pm" } },
  },
];
$mcc->write_releases($releases);
$mcc->write_dependencies();

my $res = run_nix_cpan(
  $cache_home,
  {},
  "update",
  "CLIHelpers",
  "CPAN",
  "--missing",
  "--inplace",
  "--nix-file",
  $nix_file,
);
ok($res->{ok}, "multi-update with --missing succeeds");
ok(!defined($res->{err}) || $res->{err} eq "", "multi-update with --missing has no stderr");

open my $rfh, "<", $nix_file or die $!;
local $/ = undef;
my $new_nix = <$rfh>;
close $rfh;

like($new_nix, qr/CLIHelpers = buildPerlPackage.*?version = "2\.2";/s,
     "CLIHelpers updated");
like($new_nix, qr/CPAN = buildPerlPackage.*?version = "2\.38";/s,
     "CPAN updated");
like($new_nix, qr/TermReadKey\s*=\s*buildPerlPackage/s,
     "missing TermReadKey stanza persists after later updates");
like($new_nix, qr/\n}\s*\z/s, "nix file still ends with closing brace");

done_testing();
