use v5.38;
use Test::More;
use experimental qw(class);

use_ok("Nix::PerlPackages::Drv");

# Minimal mock standing in for a MetaCPANCache::Release.
package MockRelease {
  sub new ($class, %a) { return bless { %a }, $class }
  sub version              ($self) { $self->{version} }
  sub checksum_sha256      ($self) { $self->{checksum} }
  sub download_url         ($self) { $self->{url} }
  sub distribution         ($self) { $self->{distribution} // "Mock-Dist" }
  sub preferred_build_fun  ($self) { undef }
  sub build_inputs         ($self) { () }
  sub propagated_build_inputs ($self) { () }
}

my $checksum = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
my $new_url  = "https://cpan.metacpan.org/authors/id/X/XX/XXX/Foo-2.0.tar.gz";
my $mc = MockRelease->new(
  version => "2.0", checksum => $checksum, url => $new_url, distribution => "Foo",
);

# --- Case 1: derivation with a fetchpatch carrying its own url/hash ---------
my $part_fetchpatch = <<'NIX';
  Foo = buildPerlPackage {
    pname = "Foo";
    version = "1.0";
    src = fetchurl {
      url = "mirror://cpan/authors/id/X/XX/XXX/Foo-1.0.tar.gz";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
    patches = [
      (fetchpatch {
        name = "fix.patch";
        url = "https://example.org/fix.patch";
        hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=";
      })
    ];
    meta = {
      description = "Foo";
    };
  };
NIX

my $drv = Nix::PerlPackages::Drv->new(
  prepart => "  Foo = buildPerlPackage ", attrname => "Foo",
  build_fun => "Package", part => $part_fetchpatch,
);
$drv->update_from_metacpan($mc);
my $out = $drv->part;

like($out, qr/url = "mirror:\/\/cpan\/authors\/id\/X\/XX\/XXX\/Foo-2\.0\.tar\.gz"/,
     "src url updated");
unlike($out, qr/Foo-1\.0\.tar\.gz/, "old src url gone");
like($out, qr/url = "https:\/\/example\.org\/fix\.patch"/,
     "fetchpatch url PRESERVED");
like($out, qr/hash = "sha256-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="/,
     "fetchpatch hash PRESERVED");
unlike($out, qr/sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=/,
       "old src hash replaced");

# --- Case 2: legacy sha256 = "<hex>" form ----------------------------------
my $part_legacy = <<'NIX';
  Bar = buildPerlPackage {
    pname = "Bar";
    version = "1.0";
    src = fetchurl {
      url = "mirror://cpan/authors/id/X/XX/XXX/Bar-1.0.tar.gz";
      sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
    };
    meta = {
      description = "Bar";
    };
  };
NIX

my $drv2 = Nix::PerlPackages::Drv->new(
  prepart => "  Bar = buildPerlPackage ", attrname => "Bar",
  build_fun => "Package", part => $part_legacy,
);
$drv2->update_from_metacpan($mc);
my $out2 = $drv2->part;
like($out2, qr/sha256 = "\Q$checksum\E"/,
     "legacy sha256 updated with hex checksum (Bug #9)");
unlike($out2, qr/0000000000000000/, "old legacy sha256 gone");
unlike($out2, qr/Bar-1\.0\.tar\.gz/, "old legacy src url gone");
like($out2, qr/url = "mirror:\/\/cpan\/authors\/id\/X\/XX\/XXX\/Foo-2\.0\.tar\.gz"/,
     "legacy src url updated (mirror-transformed)");

done_testing();
