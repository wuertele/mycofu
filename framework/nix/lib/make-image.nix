# make-image.nix — Build a NixOS qcow2 VM image from a list of modules.
#
# Usage in flake.nix:
#   packages.x86_64-linux.base-image = import ./framework/nix/lib/make-image.nix {
#     inherit nixpkgs;
#     system = "x86_64-linux";
#     modules = [ ./framework/nix/modules/base.nix ];
#   };

{ nixpkgs, system ? "x86_64-linux", modules, diskSize ? "auto", additionalSpace ? "512M", extraSpecialArgs ? {} }:

let
  nixos = nixpkgs.lib.nixosSystem {
    inherit system;
    specialArgs = extraSpecialArgs;
    modules = modules ++ [
      # Image-specific overrides: grub for BIOS boot, ext4 root
      ({ config, lib, pkgs, ... }: {
        # Root filesystem — make-disk-image labels the partition "nixos".
        # Using by-label so it works regardless of disk interface (scsi/virtio).
        fileSystems."/" = {
          device = "/dev/disk/by-label/nixos";
          fsType = "ext4";
        };

        # Grub bootloader for SeaBIOS (Proxmox default)
        boot.loader.grub.enable = true;
        boot.loader.grub.device = "/dev/sda";

        # Ensure the build produces a qcow2 image
        system.build.qcow2 = import "${nixpkgs}/nixos/lib/make-disk-image.nix" ({
          inherit lib config pkgs;
          format = "qcow2";
          partitionTableType = "legacy";
          copyChannel = false;  # saves ~189 MiB — VMs are immutable
        } // (if diskSize == "auto" then {
          diskSize = "auto";
          inherit additionalSpace;
        } else {
          diskSize = lib.toInt diskSize;
        }));
      })
    ];
  };
in
  nixos.config.system.build.qcow2
