{
  description = "nix-cpan — mechanical bulk updater for nixpkgs perlPackages";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      eachSystem = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      packages = eachSystem (pkgs: rec {
        nix-cpan = import ./package.nix { inherit pkgs; };
        default = nix-cpan;
      });

      apps = eachSystem (pkgs: rec {
        nix-cpan = {
          type = "app";
          program = "${self.packages.${pkgs.system}.nix-cpan}/bin/nix-cpan";
          meta.description = "Mechanical bulk updater for nixpkgs perlPackages";
        };
        default = nix-cpan;
      });

      devShells = eachSystem (pkgs: {
        default = import ./shell.nix { inherit pkgs; };
      });

      formatter = eachSystem (pkgs: pkgs.nixfmt);
    };
}
