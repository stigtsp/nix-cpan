# Shared Perl dependency set for nix-cpan, imported by both flake.nix (to build
# the packaged tool and dev shell) and shell.nix (for `nix-shell`). Returns the
# list of Perl module derivations the tool needs at runtime (not perl itself,
# nor non-Perl tools like nixfmt/sqlite). Keeping this in one place stops the
# flake and shell.nix from drifting.
{ pkgs }:
let
  perl = pkgs.perl;
  pp = perl.pkgs;
  inherit (pkgs) fetchurl lib;

  # Not currently in nixpkgs' perl package set (or needs a test tweak), so built
  # here. Mirrors the definitions that previously lived inline in shell.nix.
  FileXDG = pp.buildPerlPackage {
    pname = "File-XDG";
    version = "1.03";
    src = fetchurl {
      url = "mirror://cpan/authors/id/P/PL/PLICEASE/File-XDG-1.03.tar.gz";
      hash = "sha256-iL18FFjLdjvs7W570MEZcqFWseOSMphPinqL5CBr984=";
    };
    preCheck = ''
      rm t/file_xdg.t
    '';
    buildInputs = [ ];
    propagatedBuildInputs = with pp; [ PathClass PathTiny RefUtil ];
    meta = {
      homepage = "https://metacpan.org/pod/File::XDG";
      description = "Basic implementation of the XDG base directory specification";
      license = with lib.licenses; [ artistic1 gpl1Plus ];
    };
  };

  MetaCPANClient = pp.buildPerlPackage {
    pname = "MetaCPAN-Client";
    version = "2.037000";
    src = fetchurl {
      url = "mirror://cpan/authors/id/M/MI/MICKEY/MetaCPAN-Client-2.037000.tar.gz";
      hash = "sha256-Y8bqoEUtE+J6f3/8Yld85zsK5qqI/HvphcOghdp8P+g=";
    };
    buildInputs = with pp; [ LWPProtocolhttps TestFatal TestNeeds ];
    propagatedBuildInputs = with pp; [
      IOSocketSSL
      JSONMaybeXS
      Moo
      NetSSLeay
      RefUtil
      SafeIsa
      TypeTiny
      URI
    ];
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
in
with pp;
[
  Applify
  ArrayDiff
  CpanelJSONXS
  DBDSQLite
  FileUtilTempdir
  FileXDG
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
]
