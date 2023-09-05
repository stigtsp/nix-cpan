{ pkgs ? import <nixpkgs> {} }:

with pkgs;

mkShell {
  buildInputs = with perl.pkgs; [
    perl Applify Log4Perl MetaCPANClient SmartComments
    MojoSQLite DBDSQLite CpanelJSONXS
    RegexpCommon Mojolicious MathBigInt SortVersions HTTPTinyCache TextDiff Perl6Junction
    IOSocketSSL
  ];
}
