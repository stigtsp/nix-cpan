{ pkgs ? import <nixpkgs> { } }:

with pkgs;

mkShell {
  buildInputs = with perl.pkgs; [
    perl
    sqlite
    # perl modules
    Applify
    CpanelJSONXS
    DBDSQLite
    FileUtilTempdir
    HTTPTinyCache
    Log4Perl
    MathBigInt
    MetaCPANClient
    Mojolicious
    Perl6Junction
    RegexpCommon
    SmartComments
    SortVersions
    TextDiff
  ];
}
