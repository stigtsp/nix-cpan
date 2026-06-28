# The runnable nix-cpan tool: the Perl script + lib/, wrapped so it runs with all
# its Perl deps and the external tools it shells out to (nixfmt, git) on PATH.
{ pkgs }:
let
  perl = pkgs.perl;
  perlModules = import ./perl-deps.nix { inherit pkgs; };
  perlEnv = perl.withPackages (_: perlModules);

  # Tools the script invokes via the shell. nixfmt is REQUIRED (the write/commit
  # path dies without it) and pinned here for nixpkgs-treefmt parity; git is used
  # for sanity/commit/revert. `nix-build` (from the user's nix) is resolved from
  # the ambient PATH, which the wrapper preserves — bundling nix would be a heavy,
  # circular dependency for a tool you already run via nix.
  runtimePath = pkgs.lib.makeBinPath [ pkgs.nixfmt pkgs.git ];
in
pkgs.stdenv.mkDerivation {
  pname = "nix-cpan";
  version = "0.2";
  src = ./.;

  nativeBuildInputs = [ pkgs.makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/nix-cpan
    cp nix-cpan.pl $out/share/nix-cpan/nix-cpan.pl
    cp -r lib $out/share/nix-cpan/lib

    # Wrap perl (with all CPAN deps) to run the script. -I adds our lib to @INC
    # robustly regardless of how perl.withPackages manages PERL5LIB; the script's
    # own `use lib qw(lib)` is then a harmless no-op.
    makeWrapper ${perlEnv}/bin/perl $out/bin/nix-cpan \
      --add-flags "-I$out/share/nix-cpan/lib" \
      --add-flags "$out/share/nix-cpan/nix-cpan.pl" \
      --prefix PATH : "${runtimePath}"

    runHook postInstall
  '';

  # Smoke-test that every `use`d module (core + CPAN deps + our lib) resolves:
  # `perl -c` loads all of them at compile time, so a missing dependency fails
  # the build here rather than at runtime.
  doInstallCheck = true;
  installCheckPhase = ''
    ${perlEnv}/bin/perl -I$out/share/nix-cpan/lib -c $out/share/nix-cpan/nix-cpan.pl
  '';

  meta = {
    description = "Mechanical bulk updater for nixpkgs perlPackages (compare/update/auto)";
    homepage = "https://github.com/stigtsp/nix-cpan";
    license = pkgs.lib.licenses.unlicense;
    mainProgram = "nix-cpan";
  };
}
