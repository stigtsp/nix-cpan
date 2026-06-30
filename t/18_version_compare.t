use v5.38;
use Test::More;
use File::Temp qw(tempdir);
use Cpanel::JSON::XS ();

use_ok("Nix::MetaCPANCache");

my $tmpdir = tempdir(CLEANUP => 1);
my $cache_file = "$tmpdir/metacpan-download-cache.jsonl.gz";
my $db_file    = "$tmpdir/metacpan-cache.db";

my $mcc = Nix::MetaCPANCache->new(cache_file => $cache_file, db_file => $db_file);

# Helper: build a minimal release row carrying a given version.
my @releases;
my $i = 0;
sub mkrel ($version) {
  $i++;
  return {
    name             => "Pkg-$i-$version",
    distribution     => "Pkg-$i",
    main_module      => "Pkg::$i",
    version          => $version,
    version_numified => 1,
    checksum_sha256  => "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    download_url     => "https://cpan.metacpan.org/authors/id/X/XX/XXX/Pkg-$i-$version.tar.gz",
    dependency       => [],
    provides         => {},
  };
}

# Each case: [ metacpan_version, existing_nix_version, expected_newer_than ]
my @cases = (
  # genuine forward bump
  [ "0.50",    "0.48",     1, "real forward bump" ],
  # equal
  [ "1.00",    "1.00",     0, "equal versions are not newer" ],
  # plain downgrade
  [ "0.48",    "0.50",     0, "downgrade is not newer" ],
  # dev/underscore existing version: 0.10_027 (=0.10027) is NEWER than 0.10026,
  # so bumping to 0.10026 must NOT be treated as an update (it is a downgrade),
  # and we refuse to touch dev-pinned packages anyway.
  [ "0.10026", "0.10_027", 0, "do not downgrade a dev/underscore release" ],
  # candidate is a dev release -> never update to it
  [ "0.11_01", "0.10",     0, "never update to a dev/trial release" ],
  # dotted X.9 -> X.10 must be detected as newer (version.pm decimal parse got
  # this WRONG by ranking 1.10 == 1.1 < 1.9; versioncmp gets it right)
  [ "1.10",    "1.9",      1, "1.9 -> 1.10 is newer (dotted), not a regression" ],
  # and the reverse must NOT look newer (no downgrade when local is ahead)
  [ "1.9",     "1.10",     0, "1.10 -> 1.9 is not newer (no downgrade)" ],
  # real bump across a scheme change
  [ "3.000001", "2.0.1",   1, "2.0.1 -> 3.000001 is a real major bump" ],
);

for my $c (@cases) {
  my ($mc_ver, $nix_ver, $expect, $desc) = @$c;
  push @releases, mkrel($mc_ver);
  my $rel = $releases[-1];
  my $obj = Nix::MetaCPANCache::Release->new(
    name        => $rel->{name},
    distribution=> $rel->{distribution},
    main_module => $rel->{main_module},
    data        => Cpanel::JSON::XS::encode_json($rel),
    _mcc        => $mcc,
  );
  is($obj->newer_than($nix_ver) ? 1 : 0, $expect, "newer_than($mc_ver, $nix_ver): $desc");
}

done_testing();
