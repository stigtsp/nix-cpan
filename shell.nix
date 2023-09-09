{ pkgs ? import <nixpkgs> {} }:

with pkgs;

mkShell {
  buildInputs = with perl.pkgs; [
    perl Applify Log4Perl MetaCPANClient SmartComments MojoSQLite
    DBDSQLite CpanelJSONXS FileUtilTempdir HTTPTinyCache
    RegexpCommon Mojolicious MathBigInt SortVersions TextDiff Perl6Junction
  ];
}
