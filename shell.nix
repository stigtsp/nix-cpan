{ pkgs ? import <nixpkgs> { } }:
with pkgs;
with perl.pkgs;
let FileXDG = buildPerlPackage {
    pname = "File-XDG";
    version = "1.03";
    src = fetchurl {
      url = "mirror://cpan/authors/id/P/PL/PLICEASE/File-XDG-1.03.tar.gz";
      hash = "sha256-iL18FFjLdjvs7W570MEZcqFWseOSMphPinqL5CBr984=";
    };
    preCheck = ''
      rm t/file_xdg.t
    '';
    buildInputs = [  ];
    propagatedBuildInputs = [ PathClass PathTiny RefUtil ];
    meta = {
      homepage = "https://metacpan.org/pod/File::XDG";
      description = "Basic implementation of the XDG base directory specification";
      license = with lib.licenses; [ artistic1 gpl1Plus ];
    };
  };
in mkShell {
  buildInputs = with perl.pkgs; [
    perl
    sqlite
    # perl modules
    Applify
    FileXDG
    ArrayDiff
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
