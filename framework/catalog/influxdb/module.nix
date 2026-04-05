# influxdb/module.nix — NixOS module for InfluxDB 2.x (catalog application).
#
# Provides:
#   - InfluxDB 2.x server on 0.0.0.0:8086 (HTTPS via certbot)
#   - Persistent data on vdb (/var/lib/influxdb2)
#   - Initial setup on first boot (org, bucket, admin token)
#   - Health endpoint at /health
#
# Configuration: services.influxdb.configDir points at the operator's
# config directory (site/apps/influxdb/). The module reads recognized
# filenames and places them at the correct locations on the VM.
#
# Required files in configDir:
#   env.conf    — InfluxDB environment variable overrides
#   setup.json  — Initial setup parameters (org, bucket, retention)
#
# Optional files:
#   config.toml — Full InfluxDB config (overrides env.conf for matching settings)

{ config, pkgs, lib, ... }:

let
  cfg = config.services.influxdb;

  # Read and validate config files from the operator's configDir
  envConfPath = cfg.configDir + "/env.conf";
  setupJsonPath = cfg.configDir + "/setup.json";
  configTomlPath = cfg.configDir + "/config.toml";

  hasEnvConf = builtins.pathExists envConfPath;
  hasSetupJson = builtins.pathExists setupJsonPath;
  hasConfigToml = builtins.pathExists configTomlPath;

  # Read setup.json content for CHANGEME validation
  setupJsonContent = if hasSetupJson then builtins.readFile setupJsonPath else "";

  # Script to discover FQDN, wait for the TLS cert, and write env overrides.
  # Polls for the cert independently of certbot-initial's systemd lifecycle,
  # so a transient certbot ordering issue doesn't permanently block InfluxDB.
  # (Same pattern as vault-cert-link in vault.nix.)
  influxdbConfigScript = pkgs.writeShellScript "influxdb-write-tls-config" ''
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

    # Wait for certbot to acquire the certificate (up to 15 minutes).
    CERT_DIR="/etc/letsencrypt/live/$FQDN"
    TIMEOUT=900
    ELAPSED=0
    echo "Waiting for TLS certificate ($FQDN)..."
    while [ ! -f "$CERT_DIR/fullchain.pem" ]; do
      if [ $ELAPSED -ge $TIMEOUT ]; then
        echo "ERROR: TLS certificate not available after ''${TIMEOUT}s" >&2
        exit 1
      fi
      echo "  Certificate not yet available (''${ELAPSED}s elapsed, timeout ''${TIMEOUT}s)"
      sleep 5
      ELAPSED=$((ELAPSED + 5))
    done
    echo "Certificate found after ''${ELAPSED}s."

    mkdir -p /run/influxdb2

    # Write TLS environment overrides (merged with operator's env.conf)
    cat > /run/influxdb2/tls.env <<EOF
    INFLUXD_TLS_CERT=$CERT_DIR/fullchain.pem
    INFLUXD_TLS_KEY=$CERT_DIR/privkey.pem
    EOF
    # Strip leading whitespace from heredoc
    ${pkgs.gnused}/bin/sed -i 's/^[[:space:]]*//' /run/influxdb2/tls.env

    echo "InfluxDB TLS configured for $FQDN"
  '';

  # Script for initial setup on first boot
  influxdbSetupScript = pkgs.writeShellScript "influxdb-initial-setup" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.curl pkgs.jq pkgs.coreutils ]}:$PATH

    # Wait for InfluxDB to be ready
    for i in $(seq 1 30); do
      if curl -sk https://localhost:8086/health 2>/dev/null | jq -e '.status == "pass"' >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done

    # Check if setup is needed
    SETUP_ALLOWED=$(curl -sk https://localhost:8086/api/v2/setup 2>/dev/null | jq -r '.allowed // false')
    if [ "$SETUP_ALLOWED" != "true" ]; then
      echo "InfluxDB already initialized — skipping setup"
      exit 0
    fi

    # Read admin token from SOPS-injected secret
    if [ ! -f /run/secrets/influxdb/admin-token ]; then
      echo "ERROR: /run/secrets/influxdb/admin-token not found" >&2
      exit 1
    fi
    ADMIN_TOKEN=$(cat /run/secrets/influxdb/admin-token | tr -d '[:space:]')

    # Read setup parameters from operator's setup.json
    SETUP_JSON="/var/lib/influxdb2/setup.json"
    if [ ! -f "$SETUP_JSON" ]; then
      echo "ERROR: setup.json not found at $SETUP_JSON" >&2
      exit 1
    fi

    ORG=$(jq -r '.org' "$SETUP_JSON")
    BUCKET=$(jq -r '.bucket' "$SETUP_JSON")
    RETENTION=$(jq -r '.retention // "0"' "$SETUP_JSON")
    USERNAME=$(jq -r '.username // "admin"' "$SETUP_JSON")

    # Convert retention string to seconds (e.g., "30d" -> 2592000)
    RETENTION_SECONDS=0
    if [ "$RETENTION" != "0" ] && [ -n "$RETENTION" ]; then
      case "$RETENTION" in
        *d) RETENTION_SECONDS=$(( ''${RETENTION%d} * 86400 )) ;;
        *h) RETENTION_SECONDS=$(( ''${RETENTION%h} * 3600 )) ;;
        *s) RETENTION_SECONDS=''${RETENTION%s} ;;
        *)  RETENTION_SECONDS=$RETENTION ;;
      esac
    fi

    echo "Running InfluxDB initial setup:"
    echo "  Org:       $ORG"
    echo "  Bucket:    $BUCKET"
    echo "  Retention: $RETENTION ($RETENTION_SECONDS seconds)"
    echo "  Username:  $USERNAME"

    # POST to setup API
    RESULT=$(curl -sk -X POST https://localhost:8086/api/v2/setup \
      -H "Content-Type: application/json" \
      -d "{
        \"username\": \"$USERNAME\",
        \"password\": \"$ADMIN_TOKEN\",
        \"token\": \"$ADMIN_TOKEN\",
        \"org\": \"$ORG\",
        \"bucket\": \"$BUCKET\",
        \"retentionPeriodSeconds\": $RETENTION_SECONDS
      }" 2>&1)

    if echo "$RESULT" | jq -e '.user.id' >/dev/null 2>&1; then
      echo "InfluxDB setup complete"
    else
      echo "ERROR: Setup failed: $RESULT" >&2
      exit 1
    fi
  '';

in
{
  options.services.influxdb = {
    configDir = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the operator's InfluxDB configuration directory.
        Must contain env.conf and setup.json. See framework/catalog/influxdb/README.md.
      '';
    };
  };

  config = {
    # --- Build-time assertions for required config files ---
    assertions = [
      {
        assertion = hasEnvConf;
        message = ''
          InfluxDB catalog module: required configuration file 'env.conf'
          not found in ${toString cfg.configDir}/

          This file configures InfluxDB environment variable overrides
          (bind address, storage paths, WAL settings, etc.).

          Create ${toString cfg.configDir}/env.conf with at minimum:
            INFLUXD_BOLT_PATH=/var/lib/influxdb2/influxd.bolt
            INFLUXD_ENGINE_PATH=/var/lib/influxdb2/engine
            INFLUXD_HTTP_BIND_ADDRESS=:8086

          See: framework/catalog/influxdb/README.md
          See: https://docs.influxdata.com/influxdb/v2/reference/config-options/
        '';
      }
      {
        assertion = hasSetupJson;
        message = ''
          InfluxDB catalog module: required configuration file 'setup.json'
          not found in ${toString cfg.configDir}/

          This file configures the initial InfluxDB setup (organization,
          bucket, retention policy, admin username). Without it, InfluxDB
          cannot be initialized.

          Create ${toString cfg.configDir}/setup.json with at minimum:
          {
            "org": "your-org-name",
            "bucket": "default",
            "retention": "30d",
            "username": "admin"
          }

          See: framework/catalog/influxdb/README.md
          See: https://docs.influxdata.com/influxdb/v2/reference/config-options/
        '';
      }
      {
        assertion = !hasSetupJson || !lib.hasInfix "CHANGEME" setupJsonContent;
        message = ''
          InfluxDB catalog module: setup.json contains placeholder values.

          Edit ${toString cfg.configDir}/setup.json and replace CHANGEME with your
          actual configuration:
            "org": your organization name
            "bucket": your default bucket name

          See: framework/catalog/influxdb/README.md
        '';
      }
    ];

    # --- InfluxDB package ---
    environment.systemPackages = [ pkgs.influxdb2-server pkgs.influxdb2-cli ];

    # --- vdb mount at /var/lib/influxdb2 ---
    # Mount by label (not /dev/sdb) — device letter assignment is not stable
    # across VM recreations with virtio-scsi.
    mycofu.vdbMountPoint = "/var/lib/influxdb2";
    fileSystems."/var/lib/influxdb2" = {
      device = "/dev/disk/by-label/influxdb-data";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=5s" ];
    };

    fileSystems."/var/lib/data" = lib.mkForce {
      device = "none";
      fsType = "none";
      options = [ "noauto" ];
    };

    # Format vdb on first boot — finds the data disk dynamically (not by
    # device letter, which is unstable with virtio-scsi).
    systemd.services.influxdb-format-vdb = {
      description = "Format vdb for InfluxDB data";
      wantedBy = [ "var-lib-influxdb2.mount" ];
      before = [ "var-lib-influxdb2.mount" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "influxdb-format-vdb" ''
          set -euo pipefail
          export PATH=${lib.makeBinPath [ pkgs.e2fsprogs pkgs.util-linux pkgs.coreutils ]}:$PATH

          # Already formatted — skip
          if [ -e /dev/disk/by-label/influxdb-data ]; then
            echo "influxdb-data disk already formatted"
            exit 0
          fi

          # Find the data disk: the non-boot whole disk (no partitions)
          BOOT_DISK=$(lsblk -ndo PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null || true)
          for dev in /dev/sd?; do
            NAME=$(basename "$dev")
            [ "$NAME" = "$BOOT_DISK" ] && continue
            if [ -b "$dev" ] && ! blkid -o value -s TYPE "$dev" 2>/dev/null | grep -q .; then
              echo "Formatting $dev as ext4..."
              mkfs.ext4 -L influxdb-data "$dev"
              echo "vdb formatted"
              exit 0
            fi
          done

          echo "WARNING: No unformatted data disk found — skipping format"
        '';
      };
    };

    # --- Place config files from configDir ---

    # env.conf -> /etc/influxdb2/env.conf
    environment.etc."influxdb2/env.conf" = {
      source = envConfPath;
      mode = "0640";
    };

    # setup.json -> /var/lib/influxdb2/setup.json (via tmpfiles, since vdb mount)
    systemd.tmpfiles.rules = [
      "d /var/lib/influxdb2 0750 root root -"
    ];

    systemd.services.influxdb-place-setup = {
      description = "Place InfluxDB setup.json on data volume";
      after = [ "var-lib-influxdb2.mount" ];
      requires = [ "var-lib-influxdb2.mount" ];
      before = [ "influxdb.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "influxdb-place-setup" ''
          cp ${setupJsonPath} /var/lib/influxdb2/setup.json
          chmod 640 /var/lib/influxdb2/setup.json
        '';
      };
    };

    # Optional: config.toml
    environment.etc."influxdb2/config.toml" = lib.mkIf hasConfigToml {
      source = configTomlPath;
      mode = "0640";
    };

    # --- TLS configuration (discovers FQDN at runtime) ---
    # Uses wants (not requires) for certbot-initial: the script polls for the
    # cert file independently, so a transient systemd ordering issue with
    # certbot doesn't permanently block the InfluxDB service chain.
    systemd.services.influxdb-tls-config = {
      description = "Wait for TLS cert and generate InfluxDB TLS environment";
      after = [ "certbot-initial.service" "nocloud-init.service" ];
      wants = [ "certbot-initial.service" ];
      requires = [ "nocloud-init.service" ];
      before = [ "influxdb.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = influxdbConfigScript;
      };
    };

    # --- InfluxDB systemd service ---
    # The cert wait is handled by influxdb-tls-config (polls for cert file).
    # No ExecStartPre cert wait needed here — by the time this starts,
    # influxdb-tls-config has already confirmed the cert exists.
    systemd.services.influxdb = {
      description = "InfluxDB 2.x time-series database";
      after = [
        "network-online.target"
        "var-lib-influxdb2.mount"
        "influxdb-tls-config.service"
        "influxdb-place-setup.service"
        "vdb-ready.target"
      ];
      requires = [
        "var-lib-influxdb2.mount"
        "influxdb-tls-config.service"
        "influxdb-place-setup.service"
        "vdb-ready.target"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.influxdb2-server}/bin/influxd";
        EnvironmentFile = [
          "/etc/influxdb2/env.conf"
          "/run/influxdb2/tls.env"
        ];
        Restart = "on-failure";
        RestartSec = "5s";
        StateDirectory = "influxdb2";
        RuntimeDirectory = "influxdb2";
      };
    };

    # --- Initial setup on first boot ---
    systemd.services.influxdb-setup = {
      description = "InfluxDB initial setup (first boot only)";
      after = [ "influxdb.service" "nocloud-init.service" ];
      requires = [ "influxdb.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = influxdbSetupScript;
      };
    };

    # --- Firewall ---
    networking.firewall.allowedTCPPorts = [ 8086 ];
  };
}
