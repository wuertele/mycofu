# grafana/module.nix — NixOS module for Grafana (catalog application).
#
# Provides:
#   - Grafana server on 0.0.0.0:443 (HTTPS via certbot)
#   - Persistent data on vdb (/var/lib/grafana)
#   - Provisioned data sources from datasources.yaml
#   - Admin password from SOPS secret
#   - Health endpoint at /api/health
#
# Configuration: services.grafana-app.configDir points at the operator's
# config directory (site/apps/grafana/). The module reads recognized
# filenames and places them at the correct locations on the VM.
#
# Required files in configDir:
#   grafana.ini        — Grafana server configuration
#   datasources.yaml   — Data source provisioning
#
# Optional files:
#   dashboards.yaml    — Dashboard provisioning config
#   dashboards/        — Directory of JSON dashboard files

{ config, pkgs, lib, ... }:

let
  cfg = config.services.grafana-app;
  getRealRootDevice = import ../../nix/lib/get-real-root-device.nix { inherit pkgs; };

  # Read and validate config files from the operator's configDir
  grafanaIniPath = cfg.configDir + "/grafana.ini";
  datasourcesYamlPath = cfg.configDir + "/datasources.yaml";
  dashboardsYamlPath = cfg.configDir + "/dashboards.yaml";
  dashboardsDir = cfg.configDir + "/dashboards";
  hasExtraDashboards = cfg.extraDashboardPaths != [];

  hasGrafanaIni = builtins.pathExists grafanaIniPath;
  hasDatasourcesYaml = builtins.pathExists datasourcesYamlPath;
  hasDashboardsYaml = builtins.pathExists dashboardsYamlPath;
  hasDashboardsDir = builtins.pathExists dashboardsDir;

  # Read file content for CHANGEME validation
  grafanaIniContent = if hasGrafanaIni then builtins.readFile grafanaIniPath else "";
  datasourcesYamlContent = if hasDatasourcesYaml then builtins.readFile datasourcesYamlPath else "";

  # Script to discover FQDN, wait for TLS cert, and write Grafana config overrides.
  # Polls for the cert independently of certbot-initial's systemd lifecycle.
  # (Same pattern as vault-cert-link and influxdb-tls-config.)
  grafanaConfigScript = pkgs.writeShellScript "grafana-write-tls-config" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.gawk pkgs.coreutils pkgs.inetutils pkgs.gnused ]}:$PATH

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

    # Certbot creates /etc/letsencrypt with mode 700. With overlay root,
    # permissions don't persist across reboots. Open the parent for
    # traversal. Grafana runs as root so no private key group fix needed.
    chmod 755 /etc/letsencrypt /etc/letsencrypt/live /etc/letsencrypt/archive

    mkdir -p /run/grafana

    # Write TLS overrides for Grafana
    cat > /run/grafana/tls.env <<EOF
    GF_SERVER_CERT_FILE=$CERT_DIR/fullchain.pem
    GF_SERVER_CERT_KEY=$CERT_DIR/privkey.pem
    GF_SERVER_PROTOCOL=https
    GF_SERVER_DOMAIN=$FQDN
    GF_SERVER_ROOT_URL=https://$FQDN/
    EOF
    # Strip leading whitespace from heredoc
    sed -i 's/^[[:space:]]*//' /run/grafana/tls.env

    # Read admin password from SOPS-injected secret
    if [ -f /run/secrets/grafana/admin-password ]; then
      ADMIN_PASS=$(cat /run/secrets/grafana/admin-password | tr -d '[:space:]')
      echo "GF_SECURITY_ADMIN_PASSWORD=$ADMIN_PASS" >> /run/grafana/tls.env
    fi

    # Read InfluxDB token from SOPS-injected secret (for datasource env var substitution)
    if [ -f /run/secrets/grafana/influxdb-token ]; then
      INFLUXDB_TOKEN=$(cat /run/secrets/grafana/influxdb-token | tr -d '[:space:]')
      echo "INFLUXDB_TOKEN=$INFLUXDB_TOKEN" >> /run/grafana/tls.env
    fi

    echo "Grafana TLS configured for $FQDN"
  '';

in
{
  options.services.grafana-app = {
    configDir = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to the operator's Grafana configuration directory.
        Must contain grafana.ini and datasources.yaml. See framework/catalog/grafana/README.md.
      '';
    };
    extraDashboardPaths = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Additional dashboard JSON files to provision into /var/lib/grafana/dashboards.
        Use this for dashboards that should remain sourced from another repo path.
      '';
    };
  };

  config = {
    # --- Build-time assertions for required config files ---
    assertions = [
      {
        assertion = hasGrafanaIni;
        message = ''
          Grafana catalog module: required configuration file 'grafana.ini'
          not found in ${toString cfg.configDir}/

          This file configures the Grafana server (HTTP port, domain, auth
          settings, logging, etc.).

          Create ${toString cfg.configDir}/grafana.ini with at minimum:
            [server]
            http_port = 443

            [security]
            admin_user = admin

            [auth.anonymous]
            enabled = false

          See: framework/catalog/grafana/README.md
          See: https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/
        '';
      }
      {
        assertion = hasDatasourcesYaml;
        message = ''
          Grafana catalog module: required configuration file 'datasources.yaml'
          not found in ${toString cfg.configDir}/

          This file configures Grafana data source connections (InfluxDB,
          Prometheus, etc.). Without it, Grafana starts with no data sources.

          Create ${toString cfg.configDir}/datasources.yaml with at minimum:
          apiVersion: 1
          datasources:
            - name: InfluxDB
              type: influxdb
              access: proxy
              url: https://influxdb:8086

          See: framework/catalog/grafana/README.md
          See: https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources
        '';
      }
      {
        assertion = !hasGrafanaIni || !lib.hasInfix "CHANGEME" grafanaIniContent;
        message = ''
          Grafana catalog module: grafana.ini contains placeholder values.

          Edit ${toString cfg.configDir}/grafana.ini and replace CHANGEME with your
          actual configuration.

          See: framework/catalog/grafana/README.md
        '';
      }
      {
        assertion = !hasDatasourcesYaml || !lib.hasInfix "CHANGEME" datasourcesYamlContent;
        message = ''
          Grafana catalog module: datasources.yaml contains placeholder values.

          Edit ${toString cfg.configDir}/datasources.yaml and replace CHANGEME with your
          actual data source configuration (organization, bucket, etc.).

          See: framework/catalog/grafana/README.md
        '';
      }
    ];

    # --- Grafana package ---
    environment.systemPackages = [ pkgs.grafana ];

    # --- vdb mount at /var/lib/grafana ---
    # Mount by label (not /dev/sdb) — device letter assignment is not stable
    # across VM recreations with virtio-scsi.
    fileSystems."/var/lib/grafana" = {
      device = "/dev/disk/by-label/grafana-data";
      fsType = "ext4";
      options = [ "nofail" "x-systemd.device-timeout=5s" ];
    };

    fileSystems."/var/lib/data" = lib.mkForce {
      device = "none";
      fsType = "none";
      options = [ "noauto" ];
    };

    # Format vdb on first boot — finds the data disk dynamically
    systemd.services.grafana-format-vdb = {
      description = "Format vdb for Grafana data";
      wantedBy = [ "var-lib-grafana.mount" ];
      before = [ "var-lib-grafana.mount" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "grafana-format-vdb" ''
          set -euo pipefail
          export PATH=${lib.makeBinPath [ pkgs.e2fsprogs pkgs.util-linux pkgs.coreutils ]}:$PATH

          # Already formatted — skip
          if [ -e /dev/disk/by-label/grafana-data ]; then
            echo "grafana-data disk already formatted"
            exit 0
          fi

          # Find the data disk: the non-boot whole disk (no partitions)
          BOOT_DISK=$(lsblk -ndo PKNAME "$("${getRealRootDevice}")" 2>/dev/null || true)
          for dev in /dev/sd?; do
            NAME=$(basename "$dev")
            [ "$NAME" = "$BOOT_DISK" ] && continue
            if [ -b "$dev" ] && ! blkid -o value -s TYPE "$dev" 2>/dev/null | grep -q .; then
              echo "Formatting $dev as ext4..."
              mkfs.ext4 -L grafana-data "$dev"
              echo "vdb formatted"
              exit 0
            fi
          done

          echo "WARNING: No unformatted data disk found — skipping format"
        '';
      };
    };

    # --- Place config files from configDir ---

    # grafana.ini -> /etc/grafana/grafana.ini
    environment.etc."grafana/grafana.ini" = {
      source = grafanaIniPath;
      mode = "0640";
    };

    # datasources.yaml -> /etc/grafana/provisioning/datasources/datasources.yaml
    environment.etc."grafana/provisioning/datasources/datasources.yaml" = {
      source = datasourcesYamlPath;
      mode = "0640";
    };

    # Optional: dashboards.yaml -> /etc/grafana/provisioning/dashboards/dashboards.yaml
    environment.etc."grafana/provisioning/dashboards/dashboards.yaml" = lib.mkIf hasDashboardsYaml {
      source = dashboardsYamlPath;
      mode = "0640";
    };

    # --- tmpfiles for grafana directories ---
    systemd.tmpfiles.rules = [
      "d /var/lib/grafana 0750 root root -"
      "d /var/lib/grafana/dashboards 0750 root root -"
    ];

    # Optional: dashboards/ directory -> /var/lib/grafana/dashboards/
    systemd.services.grafana-place-dashboards = lib.mkIf (hasDashboardsDir || hasExtraDashboards) {
      description = "Place Grafana dashboard JSON files on data volume";
      after = [ "var-lib-grafana.mount" ];
      requires = [ "var-lib-grafana.mount" ];
      before = [ "grafana.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "grafana-place-dashboards" ''
          set -euo pipefail
          mkdir -p /var/lib/grafana/dashboards
          rm -f /var/lib/grafana/dashboards/*.json
          ${lib.optionalString hasDashboardsDir "cp -r ${dashboardsDir}/*.json /var/lib/grafana/dashboards/ 2>/dev/null || true"}
          ${lib.concatMapStringsSep "\n" (dashboardPath: ''
            ln -sf ${dashboardPath} /var/lib/grafana/dashboards/$(basename ${dashboardPath})
          '') cfg.extraDashboardPaths}
          chmod -R 640 /var/lib/grafana/dashboards/ 2>/dev/null || true
        '';
      };
    };

    # --- TLS configuration (discovers FQDN at runtime) ---
    systemd.services.grafana-tls-config = {
      description = "Wait for TLS cert and generate Grafana TLS environment";
      after = [ "certbot-initial.service" "nocloud-init.service" ];
      wants = [ "certbot-initial.service" ];
      requires = [ "nocloud-init.service" ];
      before = [ "grafana.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = grafanaConfigScript;
      };
    };

    # --- Grafana systemd service ---
    systemd.services.grafana = {
      description = "Grafana dashboard and visualization platform";
      after = [
        "network-online.target"
        "var-lib-grafana.mount"
        "grafana-tls-config.service"
      ];
      requires = [
        "var-lib-grafana.mount"
        "grafana-tls-config.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        ExecStart = "${pkgs.grafana}/bin/grafana server --config=/etc/grafana/grafana.ini --homepath=${pkgs.grafana}/share/grafana";
        EnvironmentFile = [
          "/run/grafana/tls.env"
        ];
        Environment = [
          "GF_PATHS_DATA=/var/lib/grafana"
          "GF_PATHS_PROVISIONING=/etc/grafana/provisioning"
          "GF_PATHS_PLUGINS=/var/lib/grafana/plugins"
        ];
        Restart = "on-failure";
        RestartSec = "5s";
        StateDirectory = "grafana";
        RuntimeDirectory = "grafana";
        WorkingDirectory = "/var/lib/grafana";
      };
    };

    # --- Firewall ---
    networking.firewall.allowedTCPPorts = [ 443 ];
  };
}
