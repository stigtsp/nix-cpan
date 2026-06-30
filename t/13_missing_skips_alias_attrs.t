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

  AliasDep = self.SomeOtherPackage;
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
        module       => "Alias::Dep",
        relationship => "requires",
        phase        => "runtime",
        version      => "0",
      },
    ],
    provides         => { "Root" => { file => "lib/Root.pm" } },
  },
  {
    name             => "Alias-Dep-1.2",
    distribution     => "Alias-Dep",
    main_module      => "Alias::Dep",
    version          => "1.2",
    version_numified => 1.2,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/A/AL/ALIAS/Alias-Dep-1.2.tar.gz",
    dependency       => [],
    provides         => { "Alias::Dep" => { file => "lib/Alias/Dep.pm" } },
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
ok($res->{ok}, "update with --missing succeeds when dependency attr exists as alias");
ok(!defined($res->{err}) || $res->{err} eq "", "update with --missing has no stderr");

open my $rfh, "<", $nix_file or die $!;
local $/ = undef;
my $new_nix = <$rfh>;
close $rfh;

like($new_nix, qr/Root = buildPerlPackage.*?version = "2\.0";/s,
     "Root updated");
like($new_nix, qr/^\s{2}AliasDep = self\.SomeOtherPackage;/m,
     "existing alias attr remains");
unlike($new_nix, qr/^\s{2}AliasDep = buildPerlPackage/m,
       "missing generation does not add duplicate derivation for alias attr");

done_testing();
