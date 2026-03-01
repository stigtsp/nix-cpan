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
  GoodDoc = buildPerlPackage {
    pname = "docmake";
    name = "App-XML-DocBook-Builder";
    version = "1.0";
    url = "mirror://cpan/authors/id/A/AP/APP/App-XML-DocBook-Builder-1.0.tar.gz";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  NoVersion = buildPerlPackage {
    name = "No-Version";
    url = "mirror://cpan/authors/id/N/NO/NOV/No-Version-0.1.tar.gz";
    hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
  };

  NoName = buildPerlPackage {
    pname = "Only-PName";
    version = "1.0";
    url = "mirror://cpan/authors/id/O/ON/ONLY/Only-PName-1.0.tar.gz";
    hash = "sha256-DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD=";
  };

  InterpUrl = buildPerlPackage {
    pname = "Interp-Url";
    version = "1.0";
    url = "mirror://cpan/authors/id/I/IN/INT/${pname}-${version}.tar.gz";
    hash = "sha256-EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE=";
    patches = let
      pname = "libinterp-url";
    in [
      (fetchpatch {
        name = "CVE-2025-99999.patch";
        url = "https://example.invalid/CVE-2025-99999.patch";
        hash = "sha256-FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF=";
      })
    ];
  };

  GitSource = buildPerlPackage {
    name = "Git-Source";
    version = "1.0";
    src = fetchFromGitHub {
      owner = "nixos";
      repo = "nixpkgs";
      rev = "deadbeef";
      hash = "sha256-CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC=";
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
    name             => "App-XML-DocBook-Builder-1.1",
    distribution     => "App-XML-DocBook-Builder",
    main_module      => "App::XML::DocBook::Builder",
    version          => "1.1",
    version_numified => 1.1,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/A/AP/APP/App-XML-DocBook-Builder-1.1.tar.gz",
    dependency       => [],
    provides         => { "App::XML::DocBook::Builder" => { file => "lib/App/XML/DocBook/Builder.pm" } },
  },
  {
    name             => "No-Version-2.0",
    distribution     => "No-Version",
    main_module      => "No::Version",
    version          => "2.0",
    version_numified => 2.0,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/N/NO/NOV/No-Version-2.0.tar.gz",
    dependency       => [],
    provides         => { "No::Version" => { file => "lib/No/Version.pm" } },
  },
  {
    name             => "Git-Source-2.0",
    distribution     => "Git-Source",
    main_module      => "Git::Source",
    version          => "2.0",
    version_numified => 2.0,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/G/GI/GIT/Git-Source-2.0.tar.gz",
    dependency       => [],
    provides         => { "Git::Source" => { file => "lib/Git/Source.pm" } },
  },
  {
    name             => "Only-PName-1.1",
    distribution     => "Only-PName",
    main_module      => "Only::PName",
    version          => "1.1",
    version_numified => 1.1,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/O/ON/ONLY/Only-PName-1.1.tar.gz",
    dependency       => [],
    provides         => { "Only::PName" => { file => "lib/Only/PName.pm" } },
  },
  {
    name             => "Interp-Url-2.0",
    distribution     => "Interp-Url",
    main_module      => "Interp::Url",
    version          => "2.0",
    version_numified => 2.0,
    checksum_sha256  => $sha,
    download_url     => "https://cpan.metacpan.org/authors/id/I/IN/INT/Interp-Url-2.0.tar.gz",
    dependency       => [],
    provides         => { "Interp::Url" => { file => "lib/Interp/Url.pm" } },
  },
];
$mcc->write_releases($releases);
$mcc->write_dependencies();

my $res = run_nix_cpan(
  $cache_home,
  {},
  "update",
  "GoodDoc",
  "NoVersion",
  "NoName",
  "InterpUrl",
  "GitSource",
  "--missing",
  "--inplace",
  "--nix-file",
  $nix_file,
);
ok($res->{ok}, "update --missing succeeds for mixed edge-case derivations");

open my $rfh, "<", $nix_file or die $!;
local $/ = undef;
my $new_nix = <$rfh>;
close $rfh;

like($new_nix, qr/GoodDoc = buildPerlPackage.*?version = "1\.1";/s,
     "GoodDoc updates via name even with differing pname");
unlike($new_nix, qr/NoVersion = buildPerlPackage \{[^}]*version = "2\.0";/s,
       "NoVersion is skipped when version attribute is missing");
like($new_nix, qr/NoName = buildPerlPackage.*?version = "1\.1";/s,
     "NoName updates via pname when name attribute is missing");
like($new_nix, qr/InterpUrl = buildPerlPackage.*?version = "2\.0";/s,
     "InterpUrl updates version");
like($new_nix, qr/InterpUrl = buildPerlPackage.*?url = "mirror:\/\/cpan\/authors\/id\/I\/IN\/INT\/Interp-Url-2\.0\.tar\.gz";/s,
     "InterpUrl rewrites interpolated url to concrete MetaCPAN URL");
like($new_nix, qr/InterpUrl = buildPerlPackage.*?name = "CVE-2025-99999\.patch";/s,
     "nested patch name remains untouched");
like($new_nix, qr/GitSource = buildPerlPackage.*?version = "1\.0";/s,
     "GitSource is skipped when url/hash source is absent");
unlike($new_nix, qr/GitSource = buildPerlPackage.*?\n\s+url = /s,
       "GitSource update does not inject url/hash into fetchFromGitHub-style source");

done_testing();
