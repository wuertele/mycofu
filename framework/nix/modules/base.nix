# base.nix — Base NixOS module inherited by every VM.
#
# Provides: NoCloud cloud-init (Python replacement), root FS expansion,
# DHCP networking, SSH, qemu-guest-agent, firewall, journal limits,
# vdb mount, and minimal operator tooling.
#
# Image size is a priority. VMs are immutable (replaced wholesale via
# build-image.sh + upload-image.sh), so nix tooling, man pages, and
# desktop leftovers are stripped.
#
# Role-specific modules (dns.nix, vault.nix, etc.) import this module
# and add their own services, packages, and firewall rules.

{ config, pkgs, lib, ... }:

{
  imports = [
    ./wait-for-vdb.nix
  ];

  # ── Boot ────────────────────────────────────────────────────────────
  # Initrd: only virtio drivers + iso9660 (for CIDATA CD-ROM)
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_scsi"
    "virtio_blk"
    "virtio_net"
    "iso9660"
  ];

  # Disable storage subsystems we will never use in VMs
  boot.initrd.supportedFilesystems = lib.mkForce [ "ext4" ];
  boot.supportedFilesystems = lib.mkForce [ "ext4" "nfs" "cifs" ];

  # ── Kernel ───────────────────────────────────────────────────────────
  # The default NixOS kernel ships ~130 MiB of hardware drivers that will
  # never load in a VM. A custom kernel config could cut this to ~20 MiB,
  # but NixOS's structured config system makes it fragile (cascading
  # kconfig dependencies cause build failures). Accepting the default
  # kernel for now; the modules exist on disk but never load.
  boot.kernelParams = [ "console=ttyS0" ];

  # ── Image size: strip everything non-essential ──────────────────────
  documentation.enable = false;
  boot.enableContainers = false;
  nix.enable = false;                      # immutable VMs — no nix daemon
  system.disableInstallerTools = true;      # no nixos-rebuild, nixos-generate-config
  programs.command-not-found.enable = false; # avoids nix-index / channel dep
  fonts.fontconfig.enable = false;
  xdg.mime.enable = false;
  xdg.icons.enable = false;

  # ── Root filesystem expansion ───────────────────────────────────────
  # Images are built with 1 GiB disk but Tofu deploys to larger vda.
  # Expand the root partition + filesystem on first boot to fill the disk.
  systemd.services.growfs-root = {
    description = "Expand root filesystem to fill disk";
    wantedBy = [ "local-fs-pre.target" ];
    before = [ "local-fs-pre.target" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "growfs-root" ''
        set -euo pipefail
        export PATH=${pkgs.util-linux}/bin:${pkgs.coreutils}/bin:$PATH

        # Resolve symlinks (findmnt may return /dev/disk/by-label/nixos)
        ROOT_DEV=$(readlink -f "$(findmnt -n -o SOURCE /)")
        DISK=$(echo "$ROOT_DEV" | sed 's/p\?[0-9]*$//')
        PART_NUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$')

        DISK_SIZE=$(blockdev --getsz "$DISK")
        PART_END=$(partx -g -o END "$ROOT_DEV" | tail -1 | tr -d ' ')

        echo "ROOT_DEV=$ROOT_DEV DISK=$DISK PART=$PART_NUM DISK_SIZE=$DISK_SIZE PART_END=$PART_END"

        if [ "$PART_END" -lt "$((DISK_SIZE - 2048))" ]; then
          echo "Growing partition $PART_NUM on $DISK"
          ${pkgs.cloud-utils.guest}/bin/growpart "$DISK" "$PART_NUM" || true
          ${pkgs.e2fsprogs}/bin/resize2fs "$ROOT_DEV"
          echo "Root filesystem expanded"
        else
          echo "Root filesystem already fills disk, skipping"
        fi
      '';
    };
  };

  # ── Cloud-init replacement ──────────────────────────────────────────
  # Proxmox attaches a NoCloud ISO (label=cidata) on /dev/sr0 containing
  # meta-data, user-data, and network-config.  Full cloud-init pulls in
  # Python (~200 MiB).  This Python script uses only stdlib to parse the
  # YAML subset we need: hostname, SSH keys, and write_files.
  #
  # Runs every boot (/run/secrets is tmpfs — does not persist).
  # Networking is handled by systemd-networkd + DHCP (no cloud-init needed).
  #
  # Bootstrap secrets convention
  #
  # Bootstrap-tier secrets (those needed before Vault is reachable) are delivered
  # to VMs at first boot via the cloud-init `write_files` mechanism in OpenTofu,
  # and written to /run/secrets/ by nocloud-init.service.
  #
  # /run/ is a tmpfs — it is empty at every boot. nocloud-init runs on every boot
  # (not just first boot) and re-writes all secrets from the CIDATA ISO each time.
  # This means secrets are never at rest on the VM's persistent disk.
  #
  # Standard paths for bootstrap-tier secrets:
  #   /run/secrets/certbot/pdns-api-key    — PowerDNS HTTP API key (DNS VMs, certbot hooks)
  #   /run/secrets/certbot/acme-server-url — ACME directory URL (all VMs with certbot)
  #   /run/secrets/extra-ca-cert           — Extra root CA cert, optional (dev ACME only)
  #   /run/secrets/vault-unseal-key        — Vault unseal key (Vault VMs, Step 5)
  #
  # All files written to /run/secrets/ should have permissions 0400, owner root:root.
  # The nocloud-init.py script enforces this for write_files entries that specify
  # permissions; OpenTofu write_files entries for secrets must always include:
  #   permissions: "0400"
  #   owner: root:root
  #
  # When adding a new VM role that needs a bootstrap secret:
  #   1. Add the secret to site/sops/secrets.yaml (via bootstrap-sops.sh or sops --set)
  #   2. Add a write_files entry to the VM's OpenTofu cloud-init user-data
  #   3. Add the path to this comment block
  #   4. Ensure the consuming service has After = nocloud-init.service (or relies
  #      on the Before = multi-user.target ordering established here)
  systemd.services.nocloud-init = {
    description = "NoCloud instance initialization";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "multi-user.target" ];
    onFailure = [ "nocloud-init-failed.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.python3}/bin/python3 ${./nocloud-init.py}";
    };
    path = with pkgs; [ util-linux inetutils ];
  };

  # ── Optional extra CA bundle augmentation ─────────────────────────
  # Dev VMs receive /run/secrets/extra-ca-cert via CIDATA. When present,
  # build a writable combined trust bundle and repoint the standard system
  # CA path at it. Prod VMs never receive the file, so this unit is a no-op.
  systemd.services.extra-ca-bundle = {
    description = "Augment the system CA bundle with an extra CIDATA CA";
    wantedBy = [ "multi-user.target" ];
    after = [ "nocloud-init.service" ];
    requires = [ "nocloud-init.service" ];
    before = [ "certbot-initial.service" "certbot-renew.service" "vault-agent.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecCondition = pkgs.writeShellScript "extra-ca-bundle-needed" ''
        test -s /run/secrets/extra-ca-cert
      '';
      ExecStart = pkgs.writeShellScript "extra-ca-bundle-build" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.openssl ]}:$PATH

        EXTRA_CA=/run/secrets/extra-ca-cert
        BUNDLE_DIR=/run/ca-bundle
        SYSTEM_BUNDLE=$BUNDLE_DIR/system-ca-certificates.crt
        COMBINED_BUNDLE=$BUNDLE_DIR/ca-certificates.crt
        TARGET_LINK=/etc/ssl/certs/ca-certificates.crt

        mkdir -p "$BUNDLE_DIR"

        # Capture the pristine NixOS bundle once per boot so reruns do not
        # append the extra CA repeatedly to an already-managed file.
        if [ ! -s "$SYSTEM_BUNDLE" ]; then
          ORIGINAL_BUNDLE=$(readlink -f "$TARGET_LINK")
          if [ "$ORIGINAL_BUNDLE" = "$COMBINED_BUNDLE" ]; then
            echo "ERROR: combined bundle is active but original bundle cache is missing" >&2
            exit 1
          fi
          cp "$ORIGINAL_BUNDLE" "$SYSTEM_BUNDLE"
          chmod 0444 "$SYSTEM_BUNDLE"
        fi

        openssl x509 -in "$EXTRA_CA" -noout >/dev/null

        cat "$SYSTEM_BUNDLE" "$EXTRA_CA" > "$COMBINED_BUNDLE"
        chmod 0444 "$COMBINED_BUNDLE"

        rm -f "$TARGET_LINK"
        ln -s "$COMBINED_BUNDLE" "$TARGET_LINK"

        echo "System CA bundle augmented with /run/secrets/extra-ca-cert"
      '';
    };
  };

  # Emit a clear wall message when nocloud-init fails so operators
  # notice immediately via the Proxmox console.
  systemd.services.nocloud-init-failed = {
    description = "NoCloud init failure alert";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "nocloud-init-failed" ''
        echo ""
        echo "========================================" > /dev/console
        echo "  NOCLOUD-INIT FAILED"                   > /dev/console
        echo "  SSH keys and secrets were NOT applied" > /dev/console
        echo "  Run: journalctl -u nocloud-init"       > /dev/console
        echo "========================================" > /dev/console
      '';
    };
  };

  # ── Networking ──────────────────────────────────────────────────────
  # Static IP from CIDATA — no DHCP dependency.
  # NixOS doesn't consume Proxmox cloud-init network-config, so network
  # values are delivered via CIDATA write_files at /run/secrets/network/.
  # A boot service reads them and writes a systemd-networkd .network file.
  #
  # DNS resolution: systemd-resolved bridges networkd's DNS= and Domains=
  # directives to /etc/resolv.conf automatically. No manual resolv.conf
  # management needed. DNS VMs disable resolved (it binds port 53) and
  # manage resolv.conf themselves in dns.nix.
  networking.useNetworkd = true;
  networking.useDHCP = lib.mkForce false;
  services.resolved.enable = lib.mkDefault true;

  # Configure the primary NIC with static IP from CIDATA write_files.
  # Runs before systemd-networkd so the interface comes up with the
  # correct address on first boot. resolved reads the DNS= and Domains=
  # directives from the .network file and writes resolv.conf.
  systemd.services.configure-static-network = {
    description = "Configure primary NIC with static IP from CIDATA";
    wantedBy = [ "multi-user.target" ];
    before = [ "systemd-networkd.service" "network-online.target" ];
    after = [ "nocloud-init.service" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "configure-static-network" ''
        MAC=$(${pkgs.coreutils}/bin/cat /run/secrets/network/mac 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '[:space:]')
        IP=$(${pkgs.coreutils}/bin/cat /run/secrets/network/ip 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '[:space:]')
        GW=$(${pkgs.coreutils}/bin/cat /run/secrets/network/gateway 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '[:space:]')
        SEARCH=$(${pkgs.coreutils}/bin/cat /run/secrets/network/search-domain 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '[:space:]')

        if [ -z "$MAC" ] || [ -z "$IP" ] || [ -z "$GW" ]; then
          echo "WARNING: No static network config in CIDATA — interface will be unconfigured" >&2
          exit 0
        fi

        # Build DNS server lines
        DNS_LINES=""
        if [ -f /run/secrets/network/dns ]; then
          while IFS= read -r server; do
            server=$(echo "$server" | ${pkgs.coreutils}/bin/tr -d '[:space:]')
            [ -n "$server" ] && DNS_LINES="''${DNS_LINES}DNS=$server
        "
          done < /run/secrets/network/dns
        fi

        DOMAINS_LINE=""
        [ -n "$SEARCH" ] && DOMAINS_LINE="Domains=$SEARCH"

        ${pkgs.coreutils}/bin/mkdir -p /etc/systemd/network
        # Match by MAC — not by name pattern (en*/ens*) which would also
        # match the management NIC and give it the primary IP.
        ${pkgs.coreutils}/bin/cat > /etc/systemd/network/10-primary.network <<EOF
        [Match]
        MACAddress=$MAC

        [Network]
        Address=$IP
        Gateway=$GW
        $DNS_LINES
        $DOMAINS_LINE
        EOF
        ${pkgs.gnused}/bin/sed -i 's/^[[:space:]]*//' /etc/systemd/network/10-primary.network
        ${pkgs.gnused}/bin/sed -i '/^$/d' /etc/systemd/network/10-primary.network

        echo "Primary NIC configured: $IP via $GW (search: $SEARCH)"
      '';
    };
  };

  # ── Management NIC (optional) ─────────────────────────────────────
  # VMs with a management network NIC (on vmbr1) get their IP and MAC
  # via CIDATA write_files at /run/secrets/mgmt-{ip,mac}. This service
  # writes a systemd-networkd config matching by MAC with a static IP
  # and no default route. No-ops if the files are absent.
  systemd.services.configure-mgmt-nic = {
    description = "Configure management NIC from CIDATA";
    wantedBy = [ "multi-user.target" ];
    before = [ "systemd-networkd.service" ];
    after = [ "nocloud-init.service" "configure-static-network.service" ];
    requires = [ "configure-static-network.service" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "configure-mgmt-nic" ''
        MGMT_IP=$(${pkgs.coreutils}/bin/cat /run/secrets/mgmt-ip 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '[:space:]')
        MGMT_MAC=$(${pkgs.coreutils}/bin/cat /run/secrets/mgmt-mac 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '[:space:]')
        [ -z "$MGMT_IP" ] && exit 0
        [ -z "$MGMT_MAC" ] && exit 0

        # Read primary NIC info for policy routing
        PRIMARY_IP=$(${pkgs.coreutils}/bin/cat /run/secrets/network/ip 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '[:space:]')
        PRIMARY_GW=$(${pkgs.coreutils}/bin/cat /run/secrets/network/gateway 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '[:space:]')
        PRIMARY_ADDR=''${PRIMARY_IP%%/*}

        ${pkgs.coreutils}/bin/mkdir -p /etc/systemd/network
        ${pkgs.coreutils}/bin/cat > /etc/systemd/network/40-mgmt.network <<EOF
        [Match]
        MACAddress=$MGMT_MAC

        [Network]
        Address=$MGMT_IP/24
        DHCP=no
        EOF
        ${pkgs.gnused}/bin/sed -i 's/^[[:space:]]*//' /etc/systemd/network/40-mgmt.network

        # Source-based policy routing via the PRIMARY NIC's .network file.
        # On dual-NIC VMs, the kernel routes replies to management-network
        # hosts via the mgmt NIC (direct route) instead of the VLAN NIC
        # (via gateway). The gateway drops these as spoofed (VLAN source
        # address on the management port). Fix: add a routing policy rule
        # so traffic FROM the primary IP uses table 100 which routes via
        # the primary interface.
        if [ -n "$PRIMARY_ADDR" ] && [ -n "$PRIMARY_GW" ]; then
          # Derive the subnet from the CIDR address (e.g., 172.27.60.57/24 → 172.27.60.0/24)
          PRIMARY_SUBNET=$(${pkgs.python3}/bin/python3 -c "import ipaddress; print(ipaddress.ip_interface('$PRIMARY_IP').network)" 2>/dev/null)

          ${pkgs.coreutils}/bin/cat >> /etc/systemd/network/10-primary.network <<POLICY
        [RoutingPolicyRule]
        From=$PRIMARY_ADDR
        Table=100
        Priority=50

        [Route]
        Gateway=$PRIMARY_GW
        Table=100

        [Route]
        Destination=$PRIMARY_SUBNET
        Table=100
        POLICY
          ${pkgs.gnused}/bin/sed -i 's/^[[:space:]]*//' /etc/systemd/network/10-primary.network
          echo "Policy routing added: from $PRIMARY_ADDR -> table 100 via $PRIMARY_GW (subnet $PRIMARY_SUBNET)"
        fi

        echo "Management NIC configured: $MGMT_MAC -> $MGMT_IP/24"
      '';
    };
  };

  # ── Network Mounts (optional) ──────────────────────────────────────
  # VMs with mounts configured in config.yaml get them via CIDATA at
  # /run/secrets/mounts.json. A boot service reads the JSON and creates
  # systemd .mount units. Supports NFS, CIFS, or any fstype.
  # No-ops if the file is absent.
  systemd.services.configure-mounts = {
    description = "Configure network mounts from CIDATA";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nocloud-init.service" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "configure-mounts" ''
        MOUNTS_FILE="/run/secrets/mounts.json"
        [ -f "$MOUNTS_FILE" ] || exit 0

        ${pkgs.coreutils}/bin/mkdir -p /run/systemd/system

        ${pkgs.jq}/bin/jq -c '.[]' "$MOUNTS_FILE" | while IFS= read -r mount; do
          MOUNT_PATH=$(echo "$mount" | ${pkgs.jq}/bin/jq -r '.path')
          DEVICE=$(echo "$mount" | ${pkgs.jq}/bin/jq -r '.device')
          FSTYPE=$(echo "$mount" | ${pkgs.jq}/bin/jq -r '.fstype')
          OPTIONS=$(echo "$mount" | ${pkgs.jq}/bin/jq -r '.options // ""')

          ${pkgs.coreutils}/bin/mkdir -p "$MOUNT_PATH"

          UNIT_NAME=$(${pkgs.systemd}/bin/systemd-escape --path "$MOUNT_PATH").mount
          AUTOMOUNT_NAME=$(${pkgs.systemd}/bin/systemd-escape --path "$MOUNT_PATH").automount

          # Write mount unit (printf avoids heredoc indentation issues in nix)
          printf '[Unit]\nDescription=Mount %s (%s)\nAfter=network-online.target\nWants=network-online.target\n\n[Mount]\nWhat=%s\nWhere=%s\nType=%s\nOptions=%s\n\n[Install]\nWantedBy=multi-user.target\n' \
            "$MOUNT_PATH" "$DEVICE" "$DEVICE" "$MOUNT_PATH" "$FSTYPE" "$OPTIONS" \
            > "/run/systemd/system/$UNIT_NAME"

          # Write automount unit
          printf '[Unit]\nDescription=Automount %s\n\n[Automount]\nWhere=%s\nTimeoutIdleSec=0\n\n[Install]\nWantedBy=multi-user.target\n' \
            "$MOUNT_PATH" "$MOUNT_PATH" \
            > "/run/systemd/system/$AUTOMOUNT_NAME"

          ${pkgs.systemd}/bin/systemctl daemon-reload
          ${pkgs.systemd}/bin/systemctl enable --now "$AUTOMOUNT_NAME" 2>/dev/null || true

          echo "Mount configured: $MOUNT_PATH -> $DEVICE ($FSTYPE)"
        done
      '';
    };
  };

  # Disable password login for root. SSH key auth is the only access path
  # (pubkey delivered via CIDATA). "!" locks the password field in /etc/shadow.
  users.users.root.initialHashedPassword = "!";

  # ── SSH ─────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = lib.mkDefault "prohibit-password";
      PasswordAuthentication = false;
    };
  };

  # ── Proxmox integration ────────────────────────────────────────────
  services.qemuGuest.enable = true;

  # ── Time ────────────────────────────────────────────────────────────
  time.timeZone = "UTC";

  # ── Firewall ────────────────────────────────────────────────────────
  networking.firewall = {
    enable = lib.mkDefault true;
    allowedTCPPorts = [ 22 ];
  };

  # ── Operator tooling (minimal) ─────────────────────────────────────
  environment.systemPackages = with pkgs; [
    curl
    htop
    tmux
    jq
  ];

  # ── Journal ─────────────────────────────────────────────────────────
  services.journald.extraConfig = ''
    SystemMaxUse=500M
    Compress=yes
  '';

  # ── Optional data disk (scsi1 → sdb) ──────────────────────────────
  fileSystems."/var/lib/data" = {
    device = "/dev/sdb";
    fsType = "ext4";
    options = [
      "nofail"
      "x-systemd.device-timeout=5s"
    ];
  };

  # ── State version ──────────────────────────────────────────────────
  system.stateVersion = lib.mkDefault "24.11";
}
