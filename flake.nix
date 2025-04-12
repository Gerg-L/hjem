{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixos-unstable";
    systems.url = "github:nix-systems/default-linux";
    smfh = {
      url = "github:Gerg-L/smfh";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    systems,
    smfh,
    ...
  }: let
    forAllSystems = nixpkgs.lib.genAttrs (import systems);
    inherit (builtins) attrValues;
  in {
    nixosModules = {
      hjem = import ./modules/nixos smfh;
      default = self.nixosModules.hjem;
    };

    checks = forAllSystems (system: let
      checkArgs = {
        inherit self;
        pkgs = nixpkgs.legacyPackages.${system};
      };
    in {
      hjem-basic = import ./tests/basic.nix checkArgs;
      hjem-special-args = import ./tests/special-args.nix checkArgs;
      # Build smfh as a part of 'nix flake check'
      inherit (smfh.packages.${system}) smfh;
    });

    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.mkShellNoCC {
        packages = attrValues {
          inherit
            (pkgs)
            # cue validator
            cue
            go
            ;
        };
      };
    });

    formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.alejandra);
  };
}
