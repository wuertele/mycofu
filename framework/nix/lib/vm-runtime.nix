{ ... }:

{
  # Root filesystem — the image build labels the partition "nixos".
  # Using by-label keeps the runtime config stable across virtio/scsi naming.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # SeaBIOS guests boot via grub from the primary disk.
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";
}
