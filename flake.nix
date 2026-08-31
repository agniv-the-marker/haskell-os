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
              mkdir $out
              cp -vt $out kernel.{img,elf}
            '';
          };
          haskell-os-disk = pkgs.callPackage (inputs.nixos-on-arm + "/modules/make-fat-fs.nix") {
            volumeLabel = "HASKELL_OS";
            size = "4M";
            # FixMe(completeness): some firmware files may be missing
            populateImageCommands = ''
              cp -vrt files/ \
                ${inputs.cs140e}/firmware/{bootcode.bin,config.txt,start.elf} \
                ${inputs.self.packages.${system}.haskell-os-kernel}/kernel.elf
              cp -v ${./DEMO.LSP} files/demo.lsp
            '';
            storePaths = [
            ];
          };
        }
      );
      apps = foreachSystem (
        { pkgs, system, ... }:
        {
          haskell-os-qemu-raspi0 = {
            type = "app";
            program = lib.getExe (
              pkgs.writeShellApplication {
                name = "haskell-os-qemu-raspi0";
                runtimeInputs = [
                  pkgs.qemu
                ];
                text =
                  let
                    haskellOsDisk = "\"\${TMPDIR:-/tmp}\"/haskell-os.img";
                    kernelElf = "${inputs.self.packages.${system}.haskell-os-kernel}/kernel.elf";
                    qemuCmd = ''
                      qemu-system-arm \
                        -nographic \
                        -nodefaults \
                        -serial null \
                        -serial mon:stdio \
                        -d guest_errors \
                        -no-reboot \
                        -dtb ${dtbs/bcm2708-rpi-zero.dtb} \
                        -M raspi0 \
                        -cpu arm1176 \
                        -m 512M \
                        -kernel ${kernelElf} \
                        -drive file=${haskellOsDisk},if=none,format=raw,id=sdcard-os \
                        -device sd-card,drive=sdcard-os \
                        -smp 1'';
                    id_gdb = "gdb.haskell-os-qemu-raspi0";
                  in
                  ''
                    set -x
                    cp --no-preserve=mode -vf \
                      ${inputs.self.packages.${system}.haskell-os-disk} \
                      ${haskellOsDisk}
                    if [ "''${debug:+set}" ]; then
                      ${qemuCmd} \
                        -S \
                        -chardev socket,path=${id_gdb}.sock,server=on,wait=off,id=${id_gdb} \
                        -gdb chardev:${id_gdb} \
                        "$@" &
                      sleep 1
                      gdb -ex "target remote ${id_gdb}.sock" ${kernelElf}
                    else
                      socat \
                        STDIO,b115200,cs8,parenb=0,cstopb=0,crtscts=0 \
                        EXEC:"${
                          # For having an stdin that is not too messy (though it's not enough):
                          # wrap qemu in socat and let socat buffer the line.
                          lib.getExe (
                            pkgs.writeShellApplication {
                              name = "qemu-raspi0-haskell-os";
                              text = ''
                                set -eux
                                exec ${qemuCmd}
                              '';
                            }
                          )
                        }",pty
                    fi
                  '';
              }
            );
          };
        }
      );
    };
}
