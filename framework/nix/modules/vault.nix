# vault.nix — HashiCorp Vault server with Raft integrated storage.
#
# This module extends base.nix with:
#   - Vault server on 0.0.0.0:8200 (HTTPS, using certbot-issued TLS cert)
#   - Raft integrated storage on sdb (/var/lib/vault)
#   - Auto-unseal systemd service (reads key from /run/secrets/vault/unseal-key)
#   - certbot for TLS certificate issuance
#
# Environment ignorance: this module contains zero environment-specific values.
# The same image deploys as vault-prod or vault-dev. Environment identity comes
# from DHCP (VLAN assignment + search domain).
#
# Vault is Category 3 (precious state). The sdb data disk holds Raft storage
# and must be backed up via PBS (configured in Step 6).

{ config, pkgs, lib, vaultPackage ? pkgs.vault, ... }:

let
  getRealRootDevice = import ../lib/get-real-root-device.nix { inherit pkgs; };
  vaultCertPersistScript = pkgs.writeShellScript "vault-cert-persist" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.findutils pkgs.util-linux ]}:$PATH

    SOURCE_DIR="/etc/letsencrypt"
    TARGET_DIR="/var/lib/vault/letsencrypt"
    TMP_DIR=""

    cleanup() {
      if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
      fi
    }
    trap cleanup EXIT

    mkdir -p "$TARGET_DIR"

    copy_source_into_target() {
      local source_path="$1"
      if find "$source_path" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
        cp -a "$source_path"/. "$TARGET_DIR"/
      fi
    }

    if mountpoint -q "$SOURCE_DIR"; then
      TMP_DIR=$(mktemp -d /var/lib/vault/letsencrypt-migrate.XXXXXX)
      copy_source_into_target "$SOURCE_DIR"
      umount "$SOURCE_DIR"
      rm -rf "$SOURCE_DIR"
    elif [ -L "$SOURCE_DIR" ]; then
      CURRENT_TARGET=$(readlink -f "$SOURCE_DIR" 2>/dev/null || true)
      if [ "$CURRENT_TARGET" = "$TARGET_DIR" ]; then
        echo "vault-cert-persist: $SOURCE_DIR already points at $TARGET_DIR"
        exit 0
      fi
      rm -f "$SOURCE_DIR"
    elif [ -d "$SOURCE_DIR" ]; then
      copy_source_into_target "$SOURCE_DIR"
      rm -rf "$SOURCE_DIR"
    elif [ -e "$SOURCE_DIR" ]; then
      rm -f "$SOURCE_DIR"
    fi

    ln -s "$TARGET_DIR" "$SOURCE_DIR"
    echo "vault-cert-persist: $SOURCE_DIR -> $TARGET_DIR"
  '';
  # Discover FQDN at runtime for Vault config
  vaultConfigScript = pkgs.writeShellScript "vault-write-config" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.gawk pkgs.coreutils pkgs.inetutils ]}:$PATH

    HOSTNAME=$(hostname)
    SEARCH_DOMAIN=$(awk '/^search / { print $2; exit }' /etc/resolv.conf)
    if [ -z "$SEARCH_DOMAIN" ]; then
      SEARCH_DOMAIN=$(awk -F= '/^DOMAINNAME=/ { print $2; exit }' /run/systemd/netif/leases/* 2>/dev/null || true)
    fi
    if [ -z "$SEARCH_DOMAIN" ]; then
      echo "ERROR: No search domain found" >&2
      exit 1
    fi
    FQDN="''${HOSTNAME}.''${SEARCH_DOMAIN}"

    mkdir -p /var/lib/vault/data

    cat > /run/vault/vault.hcl <<EOF
    listener "tcp" {
      address       = "0.0.0.0:8200"
      tls_cert_file = "/etc/letsencrypt/live/''${FQDN}/fullchain.pem"
      tls_key_file  = "/etc/letsencrypt/live/''${FQDN}/privkey.pem"
    }

    storage "raft" {
      path    = "/var/lib/vault/data"
      node_id = "''${HOSTNAME}"
    }

    api_addr     = "https://''${FQDN}:8200"
    cluster_addr = "https://''${FQDN}:8201"

    disable_mlock = true
    ui            = false
    EOF

    chown vault:vault /run/vault/vault.hcl

    # Make TLS certs readable by vault user. The parent /etc/letsencrypt
    # must also be traversable — certbot creates it with mode 700. With
    # overlay root, this permission doesn't persist across reboots.
    chmod 755 /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive
    if [ -d "/etc/letsencrypt/archive/''${FQDN}" ]; then
      chmod 640 /etc/letsencrypt/archive/''${FQDN}/privkey*.pem
      chgrp vault /etc/letsencrypt/archive/''${FQDN}/privkey*.pem
    fi

    echo "Vault config written for ''${FQDN}"
  '';

  # Auto-unseal script: waits for Vault to start, then unseals
  autoUnsealScript = pkgs.writeShellScript "vault-auto-unseal" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.curl pkgs.coreutils pkgs.jq ]}:$PATH

    UNSEAL_KEY_FILE="/var/lib/vault/unseal-key"
    VAULT_ADDR="https://127.0.0.1:8200"
    export VAULT_ADDR
    export VAULT_SKIP_VERIFY=1

    # Read unseal key from vdb (written by init-vault.sh via SSH)
    UNSEAL_KEY=""
    if [ -f "$UNSEAL_KEY_FILE" ]; then
      UNSEAL_KEY=$(cat "$UNSEAL_KEY_FILE" | tr -d '[:space:]')
      if [ -n "$UNSEAL_KEY" ]; then
        echo "Using unseal key from $UNSEAL_KEY_FILE"
      fi
    fi
    if [ -z "$UNSEAL_KEY" ]; then
      echo "No unseal key found — Vault will remain sealed (run init-vault.sh)"
      exit 0
    fi

    # Wait for Vault to be listening (up to 60 seconds)
    for i in $(seq 1 30); do
      if HEALTH=$(curl -sk --max-time 2 "$VAULT_ADDR/v1/sys/health" 2>/dev/null); then
        break
      fi
      echo "Waiting for Vault to start... ($i/30)"
      sleep 2
    done

    if [ -z "''${HEALTH:-}" ]; then
      echo "ERROR: Vault did not become available within 60 seconds" >&2
      exit 1
    fi

    INITIALIZED=$(echo "$HEALTH" | jq -r '.initialized')
    SEALED=$(echo "$HEALTH" | jq -r '.sealed')

    if [ "$INITIALIZED" != "true" ]; then
      echo "Vault is not initialized — run init-vault.sh"
      exit 0
    fi

    if [ "$SEALED" != "true" ]; then
      echo "Vault is already unsealed"
      exit 0
    fi

    echo "Unsealing Vault..."
    UNSEAL_RESULT=$(curl -sk --max-time 5 "$VAULT_ADDR/v1/sys/unseal" \
      -X PUT -d "{\"key\": \"$UNSEAL_KEY\"}")
    STILL_SEALED=$(echo "$UNSEAL_RESULT" | jq -r '.sealed')
    if [ "$STILL_SEALED" = "false" ]; then
      echo "Vault unsealed successfully"
    else
      echo "ERROR: Unseal failed" >&2
      echo "$UNSEAL_RESULT" | jq . >&2
      exit 1
    fi
  '';
in
{
  imports = [ ./certbot.nix ];

  # Vault has a BSL 1.1 license (unfree in nixpkgs)
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "vault" ];

  # resolved is enabled by base.nix for DNS resolution from networkd

  # DNS resolution handled by systemd-resolved (enabled in base.nix).
  # resolved reads DNS= and Domains= from the networkd .network file
  # written by configure-static-network and writes resolv.conf.

  # Vault user and group
  users.users.vault = {
    isSystemUser = true;
    group = "vault";
    home = "/var/lib/vault";
  };
  users.groups.vault = {};

  # Mount data disk at /var/lib/vault (Raft storage)
  # base.nix mounts sdb at /var/lib/data — override for Vault
  fileSystems."/var/lib/vault" = {
    device = "/dev/disk/by-label/vault-data";
    fsType = "ext4";
    options = [
      "nofail"
      "x-systemd.device-timeout=5s"
    ];
  };
  # Override the default /var/lib/data mount from base.nix (sdb is used for /var/lib/vault instead)
  fileSystems."/var/lib/data" = lib.mkForce {
    device = "none";
    fsType = "none";
    options = [ "noauto" ];
  };

  # Format vdb on first boot if needed
  systemd.services.vault-format-vdb = {
    description = "Format vdb for Vault Raft storage";
    wantedBy = [ "var-lib-vault.mount" ];
    before = [ "var-lib-vault.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vault-format-vdb" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.e2fsprogs pkgs.util-linux pkgs.coreutils ]}:$PATH

        # Already formatted — skip
        if [ -e /dev/disk/by-label/vault-data ]; then
          echo "vault-data disk already formatted"
          exit 0
        fi

        # Find the data disk: the non-boot whole disk (no partitions)
        BOOT_DISK=$(lsblk -ndo PKNAME "$("${getRealRootDevice}")" 2>/dev/null || true)
        for dev in /dev/sd?; do
          NAME=$(basename "$dev")
          [ "$NAME" = "$BOOT_DISK" ] && continue
          if [ -b "$dev" ] && ! blkid -o value -s TYPE "$dev" 2>/dev/null | grep -q .; then
            echo "Formatting $dev as ext4..."
            mkfs.ext4 -L vault-data "$dev"
            echo "vdb formatted"
            exit 0
          fi
        done

        echo "WARNING: No unformatted data disk found"
      '';
    };
  };

  # Ensure vault owns its data directory after mount
  systemd.services.vault-init-dirs = {
    description = "Initialize Vault directories";
    wantedBy = [ "vault.service" ];
    after = [ "var-lib-vault.mount" ];
    before = [ "vault.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vault-init-dirs" ''
        set -euo pipefail
        mkdir -p /var/lib/vault/data /run/vault
        chown -R vault:vault /var/lib/vault
        chown vault:vault /run/vault
      '';
    };
  };

  systemd.services.vault-cert-persist = {
    description = "Persist Vault TLS certbot state on vdb";
    wantedBy = [ "multi-user.target" ];
    after = [ "var-lib-vault.mount" ];
    before = [
      "certbot-initial.service"
      "vault-cert-link.service"
      "vault.service"
    ];
    unitConfig.ConditionPathIsMountPoint = "/var/lib/vault";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = vaultCertPersistScript;
    };
  };

  # Poll for the TLS certificate with retries, then fix permissions.
  # Decouples Vault startup from certbot-initial's lifecycle: if certbot
  # takes multiple retries, Vault will start as soon as the cert exists.
  systemd.services.vault-cert-link = {
    description = "Wait for Vault TLS certificate";
    wantedBy = [ "multi-user.target" ];
    after = [ "nocloud-init.service" "network-online.target" "certbot-initial.service" "vault-cert-persist.service" ];
    wants = [ "network-online.target" ];
    requires = [ "nocloud-init.service" ];
    before = [ "vault.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "vault-cert-link" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.inetutils pkgs.gawk ]}:$PATH

        FQDN_FILE="/run/secrets/certbot/fqdn"
        if [ -f "$FQDN_FILE" ] && [ -s "$FQDN_FILE" ]; then
          FQDN=$(tr -d '[:space:]' < "$FQDN_FILE")
        else
          FQDN=$(hostname).$(awk '/^search / { print $2; exit }' /etc/resolv.conf)
        fi

        CERT_DIR="/etc/letsencrypt/live/$FQDN"
        TIMEOUT=900
        ELAPSED=0
        # Use test -s (non-empty), not test -f. Certbot can leave 0-byte
        # PEM files after a failed ACME challenge. See .claude/rules/platform.md.
        echo "Waiting for TLS certificate ($FQDN)..."
        while [ ! -s "$CERT_DIR/fullchain.pem" ] || [ ! -s "$CERT_DIR/privkey.pem" ]; do
          if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "ERROR: TLS certificate not available (or empty) after ''${TIMEOUT}s" >&2
            exit 1
          fi
          echo "  Certificate not yet available (''${ELAPSED}s elapsed, timeout ''${TIMEOUT}s)"
          sleep 5
          ELAPSED=$((ELAPSED + 5))
        done
        echo "Certificate found after ''${ELAPSED}s."

        # Fix permissions for vault user. Include the parent directory —
        # certbot creates /etc/letsencrypt with mode 700. With overlay root,
        # permissions don't persist across reboots.
        chmod 755 /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive
        if [ -d "/etc/letsencrypt/archive/$FQDN" ]; then
          chmod 640 /etc/letsencrypt/archive/"$FQDN"/privkey*.pem
          chgrp vault /etc/letsencrypt/archive/"$FQDN"/privkey*.pem
        fi
        echo "Vault cert ready: $FQDN"
      '';
    };
  };

  # Vault server systemd service
  systemd.services.vault = {
    description = "HashiCorp Vault";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "vault-cert-link.service"
      "vault-cert-persist.service"
      "var-lib-vault.mount"
      "vault-init-dirs.service"
    ];
    wants = [ "network-online.target" "vault-cert-link.service" ];
    requires = [
      "var-lib-vault.mount"
      "vault-init-dirs.service"
    ];
    serviceConfig = {
      Type = "simple";
      User = "vault";
      Group = "vault";
      RuntimeDirectory = "vault";
      ExecStartPre = "+${vaultConfigScript}";
      ExecStart = "${vaultPackage}/bin/vault server -config=/run/vault/vault.hcl";
      Restart = "on-failure";
      RestartSec = "5s";
      LimitNOFILE = 65536;
      LimitMEMLOCK = "infinity";
      AmbientCapabilities = "CAP_IPC_LOCK";
    };
  };

  # Auto-unseal service
  systemd.services.vault-unseal = {
    description = "Auto-unseal Vault";
    wantedBy = [ "multi-user.target" ];
    after = [ "vault.service" ];
    requires = [ "vault.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = autoUnsealScript;
    };
  };

  # Raft snapshot timer: takes a consistent snapshot before the PBS backup window.
  # Schedule must run before config.yaml → pbs.backup_schedule (default: 02:00).
  # See architecture.md section 16.3.
  systemd.timers.vault-raft-snapshot = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "01:30";  # matches config.yaml → pbs.raft_snapshot_schedule
      Persistent = true;
    };
  };

  systemd.services.vault-raft-snapshot = {
    description = "Vault Raft consistent snapshot";
    after = [ "vault.service" "vault-unseal.service" ];
    requires = [ "vault.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "vault-raft-snapshot" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.curl pkgs.coreutils ]}:$PATH

        VAULT_ADDR="https://127.0.0.1:8200"
        SNAPSHOT_PATH="/var/lib/vault/raft-snapshot.gz"

        # Read root token from persistent storage
        ROOT_TOKEN=""
        for tf in /var/lib/vault/root-token /run/secrets/vault/root-token; do
          if [ -f "$tf" ]; then
            ROOT_TOKEN=$(cat "$tf" | tr -d '[:space:]')
            [ -n "$ROOT_TOKEN" ] && break
          fi
        done

        if [ -z "$ROOT_TOKEN" ]; then
          echo "ERROR: No root token found — cannot take Raft snapshot" >&2
          exit 1
        fi

        # Check if Vault is unsealed
        HEALTH=$(curl -sk --max-time 5 "$VAULT_ADDR/v1/sys/health" 2>/dev/null || true)
        if [ -z "$HEALTH" ]; then
          echo "ERROR: Vault not responding" >&2
          exit 1
        fi

        SEALED=$(echo "$HEALTH" | ${pkgs.jq}/bin/jq -r '.sealed')
        if [ "$SEALED" = "true" ]; then
          echo "Vault is sealed — skipping Raft snapshot"
          exit 0
        fi

        # Take the snapshot
        HTTP_CODE=$(curl -sk -o "$SNAPSHOT_PATH" -w '%{http_code}' \
          --header "X-Vault-Token: $ROOT_TOKEN" \
          "$VAULT_ADDR/v1/sys/storage/raft/snapshot")

        if [ "$HTTP_CODE" != "200" ]; then
          echo "ERROR: Raft snapshot failed with HTTP $HTTP_CODE" >&2
          rm -f "$SNAPSHOT_PATH"
          exit 1
        fi

        SIZE=$(stat -c %s "$SNAPSHOT_PATH" 2>/dev/null || stat -f %z "$SNAPSHOT_PATH" 2>/dev/null || echo 0)
        if [ "$SIZE" -eq 0 ]; then
          echo "ERROR: Raft snapshot file is empty" >&2
          rm -f "$SNAPSHOT_PATH"
          exit 1
        fi

        echo "Raft snapshot saved to $SNAPSHOT_PATH ($SIZE bytes)"
      '';
    };
  };

  # Firewall: Vault API
  networking.firewall.allowedTCPPorts = [ 8200 ];

  # Operator tooling
  environment.systemPackages = [ vaultPackage ];
}
