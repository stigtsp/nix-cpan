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
    name             => "Missing-Dep-1.0",
    distribution     => "Missing-Dep",
    main_module      => "Missing::Dep",
    version          => "1.0",
    version_numified => 1,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/M/MI/MISS/Missing-Dep-1.0.tar.gz",
    abstract         => "a useful dependency.",
    resources        => { homepage => "https://metacpan.org/release/Missing-Dep" },
    license          => [ "perl_5" ],
    dependency       => [],
    provides         => { "Missing::Dep" => { file => "lib/Missing/Dep.pm" } },
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
ok($res->{ok}, "update --missing --inplace succeeds");
ok(!defined($res->{err}) || $res->{err} eq "", "update --missing --inplace has no stderr");

open my $rfh, "<", $nix_file or die $!;
local $/ = undef;
my $new_nix = <$rfh>;
close $rfh;

like($new_nix, qr/Root = buildPerlPackage.*?version = "2\.0";/s,
     "update changed existing package version");
like($new_nix, qr/MissingDep\s*=\s*buildPerlPackage/s,
     "update --missing appended missing dependency stanza");
like($new_nix, qr/MissingDep\s*=\s*buildPerlPackage.*?pname = "Missing-Dep";.*?version = "1\.0";/s,
     "generated missing stanza uses pname/version instead of legacy name");
like($new_nix, qr/MissingDep\s*=\s*buildPerlPackage.*?meta\s*=\s*\{/s,
     "generated missing stanza includes meta block");
like($new_nix, qr/MissingDep\s*=\s*buildPerlPackage.*?description = "a useful dependency";/s,
     "generated missing stanza includes normalized description");
like($new_nix, qr/MissingDep\s*=\s*buildPerlPackage.*?homepage = "https:\/\/metacpan\.org\/release\/Missing-Dep";/s,
     "generated missing stanza includes homepage");
like($new_nix, qr/MissingDep\s*=\s*buildPerlPackage.*?license = with lib\.licenses; \[ artistic1 gpl1Plus \];/s,
     "generated missing stanza includes mapped license");
like($new_nix, qr/\n}\s*\z/s, "nix file still ends with closing brace");

done_testing();
