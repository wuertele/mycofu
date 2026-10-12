{ config, lib, pkgs, ... }:

let
  cfg = config.services.clusterDashboard;

  dashboardSite = pkgs.runCommand "cluster-dashboard-static" {} ''
    mkdir -p "$out"
    cp -R ${./static}/. "$out/"
    chmod -R u+w "$out"
    find "$out" -type d -exec chmod 755 {} +
    find "$out" -type f -exec chmod 644 {} +
  '';

  dashboardWriteNginxRuntime = pkgs.writeShellScript "cluster-dashboard-write-nginx-runtime" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.jq pkgs.python3 ]}:$PATH

    CONFIG_JSON=/run/secrets/dashboard/config.json
    PROXMOX_TOKEN_FILE=/run/secrets/proxmox-api-token
    INFLUX_TOKEN_FILE=/run/secrets/dashboard-influxdb-token
    OUTPUT_DIR=/run/cluster-dashboard

    wait_for_file() {
      local path="$1"
      local label="$2"
      local waited=0
      while [ ! -s "$path" ]; do
        if [ "$waited" -ge 300 ]; then
          echo "ERROR: ''${label} not available at ''${path}" >&2
          exit 1
        fi
        sleep 2
        waited=$((waited + 2))
      done
    }

    wait_for_file "$CONFIG_JSON" "dashboard config"
    wait_for_file "$PROXMOX_TOKEN_FILE" "Proxmox API token"
    wait_for_file "$INFLUX_TOKEN_FILE" "InfluxDB dashboard token"

    mkdir -p "$OUTPUT_DIR"

    PROXMOX_AUTH=$(tr -d '\r\n' < "$PROXMOX_TOKEN_FILE")
    INFLUX_TOKEN=$(tr -d '\r\n' < "$INFLUX_TOKEN_FILE")

    python3 - "$CONFIG_JSON" "$PROXMOX_AUTH" "$INFLUX_TOKEN" "$OUTPUT_DIR" <<'PY'
import json
import os
import pathlib
import sys

config_path, proxmox_auth, influx_token, output_dir = sys.argv[1:]
config = json.loads(pathlib.Path(config_path).read_text(encoding="utf-8"))
targets = config.get("proxmoxApiTargets", [])

if not targets:
    raise SystemExit("dashboard config is missing proxmoxApiTargets")

root = pathlib.Path(output_dir)
root.mkdir(parents=True, exist_ok=True)

def write_file(path, lines, mode):
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(path, mode)

upstream_lines = ["upstream cluster_dashboard_proxmox {"]
for target in targets:
    upstream_lines.append(f"    server {target}:8006 max_fails=1 fail_timeout=5s;")
upstream_lines.append("    keepalive 8;")
upstream_lines.append("}")
write_file(root / "upstreams.conf", upstream_lines, 0o644)

proxmox_headers = [
    f'proxy_set_header Authorization "{proxmox_auth}";',
    'proxy_set_header Host $proxy_host;',
]
# nginx reads these includes at startup, so the nginx user needs read access.
# The tokens are server-side proxy_set_header directives — never sent to the browser.
write_file(root / "proxmox-headers.conf", proxmox_headers, 0o644)

influx_headers = [
    f'proxy_set_header Authorization "Token {influx_token}";',
]
# `proxyPass` already emits the standard Host/X-Forwarded headers for this
# location. Adding a second Host header here makes InfluxDB return 400.
write_file(root / "influx-headers.conf", influx_headers, 0o644)
PY
  '';
in
{
  options.services.clusterDashboard = {
    enable = lib.mkEnableOption "cluster dashboard static site and reverse proxy";
  };

  config = lib.mkIf cfg.enable {
    services.nginx = {
      enable = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;
      appendHttpConfig = ''
        include /run/cluster-dashboard/upstreams.conf;
      '';

      virtualHosts."cluster-dashboard" = {
        listen = [
          { addr = "0.0.0.0"; port = 443; ssl = true; }
        ];
        onlySSL = true;
        sslCertificate = "/etc/letsencrypt/live/influxdb/fullchain.pem";
        sslCertificateKey = "/etc/letsencrypt/live/influxdb/privkey.pem";

        locations."/" = {
          root = dashboardSite;
          extraConfig = ''
            add_header Cache-Control "no-store";
            try_files $uri $uri/ /index.html;
          '';
        };

        locations."/api/proxmox/" = {
          extraConfig = ''
            return 404;
          '';
        };

        locations."= /api/proxmox/cluster/resources" = {
          proxyPass = "https://cluster_dashboard_proxmox/api2/json/cluster/resources";
          extraConfig = ''
            # Trade-off: rely on nginx's explicit route allowlist instead of the
            # broader Proxmox token ACL boundary. Proxmox ACLs are coarse, but
            # nginx can confine the unauthenticated dashboard to the exact
            # read-only cluster/resources queries the current UI uses.
            if ($arg_type !~ "^(vm|node)$") {
              return 403;
            }
            limit_except GET {
              deny all;
            }
            proxy_ssl_server_name on;
            proxy_ssl_verify off;
            proxy_next_upstream error timeout invalid_header http_502 http_503 http_504;
            include /run/cluster-dashboard/proxmox-headers.conf;
          '';
        };

        locations."/api/influxdb/" = {
          proxyPass = "https://127.0.0.1:8086/";
          extraConfig = ''
            proxy_ssl_server_name on;
            proxy_ssl_verify off;
            proxy_next_upstream error timeout invalid_header http_502 http_503 http_504;
            include /run/cluster-dashboard/influx-headers.conf;
          '';
        };

        locations."= /api/config" = {
          extraConfig = ''
            default_type application/json;
            add_header Cache-Control "no-store";
            alias /run/secrets/dashboard/config.json;
          '';
        };
      };
    };

    systemd.services.cluster-dashboard-nginx-runtime = {
      description = "Render runtime nginx includes for the cluster dashboard";
      wantedBy = [ "multi-user.target" ];
      after = [ "nocloud-init.service" "vault-agent.service" "influxdb-tls-config.service" ];
      requires = [ "nocloud-init.service" "vault-agent.service" ];
      before = [ "nginx.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = dashboardWriteNginxRuntime;
      };
    };

    systemd.services.nginx.after = [ "influxdb-tls-config.service" "cluster-dashboard-nginx-runtime.service" ];
    systemd.services.nginx.requires = [ "cluster-dashboard-nginx-runtime.service" ];

    networking.firewall.allowedTCPPorts = [ 443 ];
  };
}
