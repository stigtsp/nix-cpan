use v5.42;
use Test::More;

use_ok("Nix::PerlPackages::Drv");

# Minimal MetaCPAN::Release stand-in with configurable deps + meta.
package MockRel {
  sub new ($class, %a) { bless { %a }, $class }
  sub version             ($s) { $s->{version} // "2.0" }
  sub checksum_sha256     ($s) { "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" }
  sub download_url        ($s) { "https://cpan.metacpan.org/authors/id/X/XX/XXX/Foo-2.0.tar.gz" }
  sub distribution        ($s) { "Foo" }
  sub preferred_build_fun ($s) { undef }
  sub build_inputs            ($s) { ($s->{build} // [])->@* }
  sub propagated_build_inputs ($s) { ($s->{prop}  // [])->@* }
  sub abstract            ($s) { $s->{abstract} }
  sub homepage            ($s) { $s->{homepage} }
}

sub mkdrv ($part) {
  Nix::PerlPackages::Drv->new(
    prepart => "  Foo = buildPerlPackage ", attrname => "Foo",
    build_fun => "Package", part => $part,
  );
}

# --- #2: a dep declared in BOTH build and runtime lands only in propagated ---
{
  my $d = mkdrv(<<'NIX');
  Foo = buildPerlPackage {
    pname = "Foo";
    version = "1.0";
    src = fetchurl {
      url = "mirror://cpan/authors/id/X/XX/XXX/Foo-1.0.tar.gz";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
    buildInputs = [ Old ];
    propagatedBuildInputs = [ Old2 ];
  };
NIX
  $d->update_from_metacpan(MockRel->new(
    build => [qw(Aaa Shared)], prop => [qw(Shared Ccc)],
  ));
  my $p = $d->part;
  like($p,   qr/buildInputs = \[ Aaa \];/,                "Shared excluded from buildInputs (dedup)");
  like($p,   qr/propagatedBuildInputs = \[ Ccc Shared \];/, "Shared kept in propagatedBuildInputs");
  unlike($p, qr/buildInputs = \[[^\]]*\bShared\b/,        "Shared not duplicated into buildInputs");
}

# --- #1: bump refreshes existing description + homepage, leaves license alone ---
{
  my $d = mkdrv(<<'NIX');
  Foo = buildPerlPackage {
    pname = "Foo";
    version = "1.0";
    src = fetchurl {
      url = "mirror://cpan/authors/id/X/XX/XXX/Foo-1.0.tar.gz";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
    meta = {
      description = "Old description";
      homepage = "https://old.example";
      license = with lib.licenses; [ artistic1 gpl1Plus ];
    };
  };
NIX
  $d->update_from_metacpan(MockRel->new(
    abstract => "A shiny new abstract.", homepage => "https://new.example",
  ));
  my $p = $d->part;
  like($p, qr/description = "A shiny new abstract";/, "description refreshed (trailing period stripped)");
  like($p, qr/homepage = "https:\/\/new\.example";/, "homepage refreshed");
  like($p, qr/license = with lib\.licenses; \[ artistic1 gpl1Plus \];/, "license left untouched");
}

# --- #1: never ADD meta fields the derivation doesn't already have ---
{
  my $d = mkdrv(<<'NIX');
  Foo = buildPerlPackage {
    pname = "Foo";
    version = "1.0";
    src = fetchurl {
      url = "mirror://cpan/authors/id/X/XX/XXX/Foo-1.0.tar.gz";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  };
NIX
  $d->update_from_metacpan(MockRel->new(
    abstract => "Would-be description", homepage => "https://x.example",
  ));
  my $p = $d->part;
  unlike($p, qr/description =/, "no description added when absent");
  unlike($p, qr/homepage =/, "no homepage added when absent");
}

done_testing();
