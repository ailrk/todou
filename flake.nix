{
  description = "todou";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/48652e9d5aea46e555b3df87354280d4f29cd3a3";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, flake-utils, ... }@inputs:
    let
      overlay = final: prev: {
        haskell = prev.haskell // {
          packageOverrides = hfinal: hprev:
            prev.haskell.packageOverrides hfinal hprev // {

              todou = (hfinal.callPackage ./default.nix {}).overrideAttrs (old: {
                nativeBuildInputs = (old.nativeBuildInputs or []) ++ [ final.upx ];
              });
            };
        };

        todou =
          with final.haskell.lib.compose;
          overrideCabal (drv: {
            disallowGhcReference = false;
            enableSeparateDataOutput = false;
            configureFlags = drv.configureFlags or [] ++ [
              "--ghc-options=-optc-O2"
              "--ghc-options=-O2"
              "--ghc-options=-optl=-s"                 # Strip via linker
              "--ghc-options=-split-sections"
              "--ghc-options=-optl-Wl,--gc-sections"
              "--ghc-options=-optl-Wl,--build-id=none" # Remove build-id
              "--ghc-options=-optl-Wl,-R,.comment"     # Remove comment section
            ];
          }) (justStaticExecutables final.haskellPackages.todou);
        };

      perSystem = system:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ overlay ];
            config.allowBroken    = true;
            config.stripDebugInfo = true; # strip all debug infos
          };
          hspkgs = pkgs.haskellPackages;
        in
        {
          nixosModules = rec {
            todou = import ./nix/modules self;
            default = todou;
          };

          devShells = rec {
            default = filehub-shell;
            filehub-shell = pkgs.callPackage ./shell.nix { hspkgs = hspkgs; };
          };

          packages = rec {
            default = todou;
            todou= pkgs.todou;
          };

          checks = {
            todou-tests = pkgs.haskell.lib.doCheck hspkgs.todou;
          };
        };
    in
    { inherit overlay; } // flake-utils.lib.eachDefaultSystem perSystem;
}
