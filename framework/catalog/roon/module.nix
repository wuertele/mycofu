# roon/module.nix — NixOS module for Roon Server (catalog application).
#
# Provides:
#   - Roon Server with persistent data on vdb (/var/lib/roon-server)
#   - NFS mount for music library (read-only)
#   - Firewall ports for Roon Remote, RAAT streaming, and discovery
#   - Auto-update disabled (binary comes from nix store)
#
# No TLS needed — Roon uses its own protocol, not HTTPS.
# No certbot — this module does NOT import certbot.nix.
# No initial setup API — Roon is configured via the Roon Remote app.

{ config, pkgs, lib, ... }:

{
  config = {
    # --- Allow unfree package ---
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [ "roon-server" ];

    # --- Override roon-server to latest version ---
    # The pinned nixpkgs (24.11) has roon-server 2.0-1470 which is
    # incompatible with Roon Remote 2.62 (build 1641). RAAT sessions
    # fail with InvalidCodeSignature. Override to the latest release.
    nixpkgs.overlays = [
      (final: prev: {
        roon-server = prev.roon-server.overrideAttrs (old: rec {
          version = "2.0-1641";
          src = prev.fetchurl {
            url = "https://download.roonlabs.com/updates/production/RoonServer_linuxx64_206201641.tar.bz2";
            hash = "sha256-DX05i4bgTar2d2xHyEqFXNlQ86FladX/xoEC4YLIxnI=";
          };
        });
      })
    ];

    # --- Operator marker file ---
    environment.etc."dave".text = "was here 2026.03.16a\n";

    # --- Networking: management NIC for RAAT multicast discovery ---
    # The management NIC is configured by the framework (base.nix
    # configure-mgmt-nic service) using /run/secrets/mgmt-{ip,mac}
    # from CIDATA. The NIC is on vmbr1 (management bridge), separate
    # from vmbr0 (VLAN-aware bridge) to avoid MAC learning confusion.
    # No Roon-specific networking config is needed here.

    # --- Roon Server package ---
    environment.systemPackages = [ pkgs.roon-server ];

    # --- vdb mount at /var/lib/roon-server ---
    mycofu.vdbMountPoint = "/var/lib/roon-server";
    fileSystems."/var/lib/roon-server" = {
      device = "/dev/disk/by-label/roon-data";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=5s" ];
    };

    # Disable the default /var/lib/data mount from base.nix
    fileSystems."/var/lib/data" = lib.mkForce {
      device = "none";
      fsType = "none";
      options = [ "noauto" ];
    };

    # Format vdb on first boot
    systemd.services.roon-format-vdb = {
      description = "Format vdb for Roon Server data";
      wantedBy = [ "var-lib-roon\\x2dserver.mount" ];
      before = [ "var-lib-roon\\x2dserver.mount" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "roon-format-vdb" ''
          set -euo pipefail
          export PATH=${lib.makeBinPath [ pkgs.e2fsprogs pkgs.util-linux pkgs.coreutils ]}:$PATH

          # Already formatted — skip
          if [ -e /dev/disk/by-label/roon-data ]; then
            echo "roon-data disk already formatted"
            exit 0
          fi

          # Find the data disk: the non-boot whole disk (no partitions)
          BOOT_DISK=$(lsblk -ndo PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null || true)
          for dev in /dev/sd?; do
            NAME=$(basename "$dev")
            [ "$NAME" = "$BOOT_DISK" ] && continue
            if [ -b "$dev" ] && ! blkid -o value -s TYPE "$dev" 2>/dev/null | grep -q .; then
              echo "Formatting $dev as ext4..."
              mkfs.ext4 -L roon-data "$dev"
              echo "vdb formatted"
              exit 0
            fi
          done

          echo "WARNING: No unformatted data disk found — skipping format"
        '';
      };
    };

    # Network mounts (NFS music library, etc.) are configured via
    # config.yaml mounts list, delivered via CIDATA, and mounted by
    # the configure-mounts service in base.nix.

    # --- Roon Server systemd service ---
    systemd.services.roon-server = {
      description = "Roon Server";
      after = [
        "network-online.target"
        "var-lib-roon\\x2dserver.mount"
        "vdb-ready.target"
      ];
      requires = [
        "var-lib-roon\\x2dserver.mount"
        "vdb-ready.target"
      ];
      wants = [
        "network-online.target"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        ROON_DATAROOT = "/var/lib/roon-server";
        ROON_ID_DIR = "/var/lib/roon-server";
      };
      serviceConfig = {
        ExecStart = "${pkgs.roon-server}/bin/RoonServer";
        Restart = "on-failure";
        RestartSec = "5s";
        # Roon needs access to the music directory and data directory
        # Music directory is mounted by configure-mounts from CIDATA
        ReadWritePaths = [ "/var/lib/roon-server" ];
      };
    };

    # --- Firewall ---
    # Roon uses TCP 9100-9200 (Remote), 9330-9339 (RAAT), 55000 (ARC),
    # and UDP 9003 (discovery). Use iptables ranges via extraCommands.
    networking.firewall = {
      allowedTCPPorts = [ 55000 ];
      allowedUDPPorts = [ 9003 ];
      extraCommands = ''
        iptables -A nixos-fw -p tcp --dport 9100:9200 -j nixos-fw-accept
        iptables -A nixos-fw -p tcp --dport 9330:9339 -j nixos-fw-accept
      '';
    };
  };
}
