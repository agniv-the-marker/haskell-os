{
  description = "haskell-os";
  nixConfig = {
    # For .#haskell-os-disk
    allow-import-from-derivation = true;
  };
  inputs = {
    nixpkgs.url = "flake:nixpkgs";
    cs140e = {
      url = "github:dddrrreee/cs140e-25win";
      flake = false;
    };
    nixos-on-arm = {
      url = "github:ProjectInitiative/nixos-on-arm";
      flake = false;
    };
  };
  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
      foreachSystem =
        f:
        lib.genAttrs lib.systems.flakeExposed (
          system:
          f rec {
            inherit system;
            pkgs = inputs.nixpkgs.legacyPackages.${system};
          }
        );
    in
    {
      packages = foreachSystem (
        { pkgs, system, ... }:
        {
          haskell-os-kernel = pkgs.stdenv.mkDerivation {
            name = "haskell-os-kernel";
            src =
              with lib.fileset;
              toSource {
                root = ./.;
                fileset = unions [
                  ./Makefile
                  ./asm
                  ./c
                  ./hs
                  ./memmap
                ];
              };
            nativeBuildInputs = [
              # https://github.com/agniv-the-marker/haskell-os/blob/main/GUIDE.md
              # requires MicroHs 0.15.0.0 or similar, this is 0.15.4.0
              pkgs.microhs
              #pkgs.targetPackages.haskell.packages.microhs.ghc
              pkgs.pkgsCross.arm-embedded.buildPackages.gcc
            ];
            buildPhase = ''
              set -x
              make kernel.img \
                PATH="$PATH" \
                MHS_RUNTIME=${
                  # Note that this does not include any patch from Nixpkgs
                  pkgs.microhs.src
                }/src/runtime
            '';
            installPhase = ''
              cp -v kernel.img $out
            '';
          };
          haskell-os-disk = pkgs.callPackage (inputs.nixos-on-arm + "/modules/make-fat-fs.nix") {
            volumeLabel = "HASKELL_OS";
            size = "4M";
            # FixMe(completeness): some firmware files may be missing
            populateImageCommands = ''
              cp -vrt files/ ${inputs.cs140e}/firmware/{bootcode.bin,config.txt,start.elf}
              cp -v ${inputs.self.packages.${system}.haskell-os-kernel} files/kernel.img
            '';
            storePaths = [
            ];
          };
        }
      );
    };
}
