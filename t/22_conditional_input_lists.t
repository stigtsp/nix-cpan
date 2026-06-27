use v5.38;
use Test::More;

use_ok("Nix::PerlPackages::Drv");

sub mkdrv ($part) {
  return Nix::PerlPackages::Drv->new(
    prepart => "  Foo = buildPerlPackage ", attrname => "Foo",
    build_fun => "Package", part => $part,
  );
}

# --- single-line base ++ lib.optionals [Wx] ---
{
  my $d = mkdrv(<<'NIX');
  Foo = buildPerlPackage {
    propagatedBuildInputs = [ Aaa Bbb ] ++ lib.optionals (!stdenv.hostPlatform.isDarwin) [ Wx ];
  };
NIX
  # New metacpan deps include Wx (conditional) and a new dep Ccc; Aaa dropped.
  $d->set_or_add_attr_list("propagatedBuildInputs", qw(Bbb Ccc Wx));
  my $p = $d->part;
  like($p, qr/propagatedBuildInputs = \[ Bbb Ccc \] \+\+ lib\.optionals \(!stdenv\.hostPlatform\.isDarwin\) \[ Wx \];/,
       "base updated, Wx kept ONLY in conditional, suffix preserved");
  unlike($p, qr/\[ Bbb Ccc Wx \]/, "Wx not duplicated into base");
}

# --- multiline base ++ lib.optionals ---
{
  my $d = mkdrv(<<'NIX');
  Foo = buildPerlPackage {
    propagatedBuildInputs = [
      Aaa
      Bbb
    ]
    ++ lib.optionals stdenv.hostPlatform.isDarwin [ DarwinOnly ];
    meta = { };
  };
NIX
  $d->set_or_add_attr_list("propagatedBuildInputs", qw(Bbb Ccc DarwinOnly));
  my $p = $d->part;
  like($p, qr/propagatedBuildInputs = \[ Bbb Ccc \]\s*\n?\s*\+\+ lib\.optionals stdenv\.hostPlatform\.isDarwin \[ DarwinOnly \];/s,
       "multiline base collapsed+updated, conditional preserved");
  unlike($p, qr/DarwinOnly[^]]*Ccc|Ccc DarwinOnly/, "DarwinOnly not pulled into base");
}

# --- base ++ (with pkgs; [ ... ]) : pkgs append preserved ---
{
  my $d = mkdrv(<<'NIX');
  Foo = buildPerlPackage {
    buildInputs = [ Aaa ] ++ (with pkgs; [ zlib ]);
  };
NIX
  $d->set_or_add_attr_list("buildInputs", qw(Aaa Bbb));
  my $p = $d->part;
  like($p, qr/buildInputs = \[ Aaa Bbb \] \+\+ \(with pkgs; \[ zlib \]\);/,
       "base updated, (with pkgs; ...) append preserved");
}

# --- pkgs.* already in base is retained ---
{
  my $d = mkdrv(<<'NIX');
  Foo = buildPerlPackage {
    buildInputs = [ pkgs.cups Aaa ] ++ lib.optionals stdenv.cc.isClang [ Bbb ];
  };
NIX
  $d->set_or_add_attr_list("buildInputs", qw(Aaa Ccc));
  my $p = $d->part;
  like($p, qr/buildInputs = \[ Aaa Ccc pkgs\.cups \] \+\+ lib\.optionals stdenv\.cc\.isClang \[ Bbb \];/,
       "pkgs.cups retained in base, conditional preserved");
}

# --- non-handled complex shapes are left untouched ---
{
  my $with = <<'NIX';
  Foo = buildPerlPackage {
    propagatedBuildInputs = with perlPackages; [ Aaa Bbb ];
  };
NIX
  my $d = mkdrv($with);
  my $before = $d->part;
  $d->set_or_add_attr_list("propagatedBuildInputs", qw(Ccc Ddd));
  is($d->part, $before, "with-expression left untouched");

  my $override = <<'NIX';
  Foo = buildPerlPackage {
    propagatedBuildInputs = [ (pkgs.x.override { inherit perl; }) Aaa ];
  };
NIX
  my $d2 = mkdrv($override);
  my $b2 = $d2->part;
  $d2->set_or_add_attr_list("propagatedBuildInputs", qw(Ccc));
  is($d2->part, $b2, "override-expression list left untouched");
}

done_testing();
