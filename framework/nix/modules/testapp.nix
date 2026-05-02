# testapp.nix — Minimal stateful test application (guinea pig VM).
#
# Exercises the full VM lifecycle: image build, deploy, cert issuance,
# stateful data on vdb, PBS backup/restore, HA failover.
#
# Heartbeat writer: systemd timer writes to SQLite every 60 seconds.
# Health endpoint: HTTP on port 8080 returns JSON with heartbeat stats.
#
# Category 3 (precious state): heartbeat database on sdb (/var/lib/testapp).

{ config, pkgs, lib, ... }:

let
  heartbeatScript = pkgs.writeShellScript "testapp-heartbeat" ''
    export PATH=${lib.makeBinPath [ pkgs.sqlite ]}:$PATH
    DB=/var/lib/testapp/heartbeats.db
    sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS heartbeats (id INTEGER PRIMARY KEY, ts TEXT);"
    sqlite3 "$DB" "INSERT INTO heartbeats (ts) VALUES (datetime('now'));"
  '';

  healthScript = pkgs.writeScript "testapp-health" ''
    #!${pkgs.python3}/bin/python3
    import http.server
    import json
    import sqlite3
    import os

    DB = "/var/lib/testapp/heartbeats.db"

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            try:
                if not os.path.exists(DB):
                    body = {"last": None, "count": 0, "status": "starting"}
                else:
                    conn = sqlite3.connect(DB)
                    cur = conn.cursor()
                    cur.execute("SELECT ts FROM heartbeats ORDER BY id DESC LIMIT 1")
                    row = cur.fetchone()
                    cur.execute("SELECT COUNT(*) FROM heartbeats")
                    count = cur.fetchone()[0]
                    conn.close()
                    if row:
                        body = {"last": row[0], "count": count, "status": "healthy"}
                    else:
                        body = {"last": None, "count": 0, "status": "starting"}
            except Exception:
                body = {"last": None, "count": 0, "status": "starting"}
            payload = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, fmt, *args):
            pass  # suppress access logs

    http.server.HTTPServer(("", 8080), Handler).serve_forever()
  '';
in
{
  imports = [ ./certbot.nix ./vault-agent.nix ];

  vaultAgent.enable = true;

  # Mount data disk at /var/lib/testapp (overrides base.nix /var/lib/data)
  fileSystems."/var/lib/testapp" = {
    device = "/dev/sdb";
    fsType = "ext4";
    options = [ "nofail" "x-systemd.device-timeout=5s" ];
  };

  fileSystems."/var/lib/data" = lib.mkForce {
    device = "none";
    fsType = "none";
    options = [ "noauto" ];
  };

  # Format vdb on first boot
  systemd.services.testapp-format-vdb = {
    description = "Format vdb for testapp data";
    wantedBy = [ "var-lib-testapp.mount" ];
    before = [ "var-lib-testapp.mount" ];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "testapp-format-vdb" ''
        if [ ! -b /dev/sdb ]; then exit 0; fi
        if ${pkgs.util-linux}/bin/blkid -o value -s TYPE /dev/sdb 2>/dev/null | grep -q ext4; then exit 0; fi
        ${pkgs.e2fsprogs}/bin/mkfs.ext4 -L testapp-data /dev/sdb
      '';
    };
  };

  # Heartbeat writer (timer)
  systemd.services.testapp-heartbeat = {
    description = "Testapp heartbeat writer";
    after = [ "var-lib-testapp.mount" ];
    requires = [ "var-lib-testapp.mount" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = heartbeatScript;
    };
  };

  systemd.timers.testapp-heartbeat = {
    description = "Testapp heartbeat timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnActiveSec = "10s";
      OnUnitActiveSec = "60s";
      AccuracySec = "1s";
    };
  };

  # Health endpoint
  systemd.services.testapp-health = {
    description = "Testapp health endpoint";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "var-lib-testapp.mount" ];
    wants = [ "network-online.target" ];
    requires = [ "var-lib-testapp.mount" ];
    serviceConfig = {
      ExecStart = healthScript;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8080 ];

  environment.systemPackages = [ pkgs.sqlite ];
}
