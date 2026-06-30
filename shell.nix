# Dev shell for nix-cpan. Also used as the flake's devShells.default.
# The Perl dependency set lives in ./perl-deps.nix so it stays in sync with the
# packaged tool (flake.nix / package.nix).
{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  buildInputs =
    [
      pkgs.perl
      pkgs.sqlite
      # nixfmt: required by the write/commit path (has_nixfmt). For CI parity with
      # nixpkgs treefmt this should match the nixfmt the target nixpkgs pins; see
      # PLAN.ng.md D2.
      pkgs.nixfmt
      pkgs.git
      # perlcritic: CI lints nix-cpan.pl with it; keep it in the dev shell so the
      # same check is runnable locally.
      pkgs.perlPackages.PerlCritic
    ]
    ++ import ./perl-deps.nix { inherit pkgs; };
}
