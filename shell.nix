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
  MetaCPANClient = buildPerlPackage {
    pname = "MetaCPAN-Client";
    version = "2.037000";
    src = fetchurl {
      url = "mirror://cpan/authors/id/M/MI/MICKEY/MetaCPAN-Client-2.037000.tar.gz";
      hash = "sha256-Y8bqoEUtE+J6f3/8Yld85zsK5qqI/HvphcOghdp8P+g=";
    };
    buildInputs = [ LWPProtocolhttps TestFatal TestNeeds ];
    propagatedBuildInputs = [ IOSocketSSL JSONMaybeXS Moo NetSSLeay RefUtil SafeIsa TypeTiny URI ];
    postPatch = ''
      substituteInPlace Makefile.PL \
        --replace '"t/*.t t/api/*.t"' \
        '"t/00-report-prereqs.t t/api/_get.t t/api/_get_or_search.t t/api/_search.t t/entity.t t/request.t t/resultset.t"'
    '';
    meta = {
      description = "A comprehensive, DWIM-featured client to the MetaCPAN API";
      license = with lib.licenses; [ artistic1 gpl1Plus ];
    };
  };
in mkShell {
  buildInputs = with perl.pkgs; [
    perl
    sqlite
    # nixfmt: required by the write/commit path (has_nixfmt). The tool formats
    # generated/edited nix. For CI parity with nixpkgs treefmt this should match
    # the nixfmt the target nixpkgs pins; see PLAN.ng.md D2.
    pkgs.nixfmt
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
