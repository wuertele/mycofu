# dns.nix — PowerDNS authoritative DNS server with pdns-recursor.
#
# This module extends base.nix with PowerDNS authoritative (on 0.0.0.0:8053)
# and pdns-recursor (on 0.0.0.0:53). The recursor is the client-facing entry
# point for LAN clients: it forwards local zone queries to the co-located
# authoritative instance and resolves external queries via the gateway.
#
# The authoritative also listens on 0.0.0.0:8053 so that external queries
# (via WAN port forward to :8053) receive proper authoritative answers with
# the AA flag set, which public resolvers require for delegation.
#
# Environment ignorance: this module contains zero environment-specific
# values. The same image deploys as dns1-prod or dns1-dev. Environment
# identity comes from DHCP (VLAN assignment + search domain).
#
# Secret handling (bootstrap tier):
#   API key is delivered at boot by nocloud-init.service from the CIDATA write_files
#   entry provisioned by OpenTofu at /run/secrets/certbot/pdns-api-key.
#   The certbot module also reads this key for DNS-01 challenge hooks.

{ config, pkgs, lib, ... }:

{
  imports = [ ./certbot.nix ./vault-agent.nix ];
  # Disable systemd-resolved — it binds to port 53 on loopback,
  # which conflicts with pdns-recursor.
  services.resolved.enable = false;

  # With resolved disabled, we write /etc/resolv.conf via a oneshot service.
  # Now points to 127.0.0.1 (the recursor) instead of the gateway directly.
  networking.nameservers = lib.mkForce [];
  systemd.services.write-resolv-conf = {
    description = "Write /etc/resolv.conf for DNS VMs";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nocloud-init.service" ];
    wants = [ "network-online.target" ];
    requires = [ "nocloud-init.service" ];
    before = [ "pdns.service" "pdns-recursor.service" "certbot-initial.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "write-resolv-conf" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

        # Read search domain from write_files (CIDATA — always available,
        # no DHCP race). Same file the recursor uses for forward-zones.
        SEARCH_DOMAIN=""
        FORWARD_ZONE_FILE="/run/secrets/dns/forward-zone-domain"
        if [ -f "$FORWARD_ZONE_FILE" ]; then
          SEARCH_DOMAIN=$(tr -d '[:space:]' < "$FORWARD_ZONE_FILE")
        fi

        {
          echo "nameserver 127.0.0.1"
          [ -n "$SEARCH_DOMAIN" ] && echo "search $SEARCH_DOMAIN"
          echo "options edns0"
        } > /etc/resolv.conf

        echo "Wrote /etc/resolv.conf (nameserver=127.0.0.1, search=''${SEARCH_DOMAIN:-none})"
      '';
    };
  };

  # PowerDNS authoritative server with SQLite3 backend (0.0.0.0:8053).
  # Listens on all interfaces so it can serve both:
  #   - The co-located recursor (127.0.0.1:8053)
  #   - External queries via WAN port forward (WAN:53 → VM:8053)
  # External (public resolver) queries require authoritative answers with
  # the AA flag, which only the authoritative server provides.
  services.powerdns = {
    enable = true;
    extraConfig = ''
      # SQLite backend — lightweight, no external DB dependency
      launch=gsqlite3
      gsqlite3-database=/var/lib/pdns/pdns.db
      gsqlite3-pragma-synchronous=1

      # DNS listener — all interfaces, non-standard port.
      # The recursor forwards local zone queries here on loopback.
      # External queries arrive via WAN port forward (WAN:53 → :8053).
      local-address=0.0.0.0
      local-port=8053

      # HTTP API — webserver=yes is required for the API to function.
      # Stays on 0.0.0.0:8081 for zone-loading and certbot hooks.
      webserver=yes
      webserver-address=0.0.0.0
      webserver-port=8081
      webserver-allow-from=0.0.0.0/0
      api=yes

      # SOA defaults
      default-soa-content=ns1.@ hostmaster.@ 1 10800 3600 604800 300

      # No zone transfers
      allow-axfr-ips=

      # Runtime config directory for secrets (API key)
      include-dir=/run/pdns/conf.d
    '';
  };

  # Customize the pdns systemd service
  systemd.services.pdns = {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      StateDirectory = "pdns";

      # Inject runtime config as root (+ prefix) before the pdns-user preStart.
      ExecStartPre = lib.mkBefore [
        "+${pkgs.writeShellScript "pdns-inject-config" ''
          mkdir -p /run/pdns/conf.d

          # API key
          if [ -f /run/secrets/certbot/pdns-api-key ]; then
            echo "api-key=$(cat /run/secrets/certbot/pdns-api-key)" > /run/pdns/conf.d/api-key.conf
            chown pdns:pdns /run/pdns/conf.d/api-key.conf
            chmod 400 /run/pdns/conf.d/api-key.conf
          else
            echo "WARNING: /run/secrets/certbot/pdns-api-key not found — API will reject authenticated requests" >&2
          fi
        ''}"
      ];
    };

    preStart = lib.mkAfter ''
      # Initialize SQLite schema on first boot if database doesn't exist.
      # PowerDNS does not auto-create the schema — we must seed it.
      if [ ! -f /var/lib/pdns/pdns.db ]; then
        echo "Initializing PowerDNS SQLite database..."
        ${pkgs.sqlite}/bin/sqlite3 /var/lib/pdns/pdns.db < ${pkgs.pdns}/share/doc/pdns/schema.sqlite3.sql
      fi
    '';
  };

  # pdns-recursor — client-facing recursive resolver on 0.0.0.0:53.
  # Forwards local zones to the co-located authoritative (127.0.0.1:8053)
  # and external queries to the environment gateway.
  services.pdns-recursor = {
    enable = true;
    dns.address = "0.0.0.0, 127.0.0.1";
    dns.port = 53;
    dns.allowFrom = [ "0.0.0.0/0" "::/0" ];
    settings = {
      include-dir = "/run/pdns-recursor/conf.d";
    };
  };

  # Configure recursor forwarding at runtime (zone and gateway are not
  # known at image build time).
  systemd.services.pdns-recursor = {
    after = [ "network-online.target" "nocloud-init.service" "pdns.service" ];
    wants = [ "network-online.target" ];
    requires = [ "nocloud-init.service" "pdns.service" ];
    serviceConfig = {
      ExecStartPre = lib.mkBefore [
        "+${pkgs.writeShellScript "recursor-inject-config" ''
          set -euo pipefail
          export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

          # Read the forward-zone domain from write_files (CIDATA — always available)
          FORWARD_ZONE_DOMAIN=""
          FORWARD_ZONE_FILE="/run/secrets/dns/forward-zone-domain"
          if [ -f "$FORWARD_ZONE_FILE" ]; then
            FORWARD_ZONE_DOMAIN=$(tr -d '[:space:]' < "$FORWARD_ZONE_FILE")
          else
            echo "WARNING: $FORWARD_ZONE_FILE not found — recursor will not forward local zone queries" >&2
          fi

          # Read the upstream forwarder (also from write_files)
          GATEWAY_IP=""
          RECURSOR_IP_FILE="/run/secrets/dns/recursor-ip"
          if [ -f "$RECURSOR_IP_FILE" ]; then
            GATEWAY_IP=$(tr -d '[:space:]' < "$RECURSOR_IP_FILE")
          else
            echo "WARNING: $RECURSOR_IP_FILE not found — recursor will have no upstream forwarder" >&2
          fi

          # Write forwarding config
          CONF_DIR="/run/pdns-recursor/conf.d"
          mkdir -p "$CONF_DIR"

          {
            if [ -n "$FORWARD_ZONE_DOMAIN" ]; then
              echo "forward-zones=$FORWARD_ZONE_DOMAIN=127.0.0.1:8053"
            fi
            if [ -n "$GATEWAY_IP" ]; then
              echo "forward-zones-recurse=.=$GATEWAY_IP"
            fi
          } > "$CONF_DIR/forwarding.conf"

          echo "Recursor config: zone=''${FORWARD_ZONE_DOMAIN:-MISSING} gateway=''${GATEWAY_IP:-MISSING}"
        ''}"
      ];
    };
  };

  # Load zone data from CIDATA into PowerDNS at boot.
  # Zone data is generated by OpenTofu from config.yaml and delivered via
  # write_files. This eliminates the need for post-deploy zone-deploy.sh.
  systemd.services.pdns-zone-load = {
    description = "Load DNS zone data from CIDATA into PowerDNS";
    after = [ "pdns.service" "nocloud-init.service" ];
    wants = [ "pdns.service" ];
    requires = [ "nocloud-init.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "load-zones" ''
        set -euo pipefail
        export PATH=${lib.makeBinPath [ pkgs.coreutils pkgs.curl ]}:$PATH

        ZONE_DATA="/run/secrets/dns/zone-data.json"
        if [ ! -f "$ZONE_DATA" ]; then
          echo "No zone data found at $ZONE_DATA — skipping"
          exit 0
        fi

        # Wait for PowerDNS API to be ready
        for i in $(seq 1 30); do
          if ${pkgs.curl}/bin/curl -s -o /dev/null http://127.0.0.1:8081/api/v1/servers/localhost 2>/dev/null; then
            break
          fi
          sleep 1
        done

        ${pkgs.python3}/bin/python3 ${./load-zones.py} "$ZONE_DATA"
      '';
    };
  };

  # Firewall: DNS recursor (53), authoritative (8053), API (8081)
  # Port 8053 must be open for WAN port-forwarded queries to reach
  # the authoritative server directly (public DNS delegation).
  networking.firewall = {
    allowedTCPPorts = [ 53 8053 8081 ];
    allowedUDPPorts = [ 53 8053 ];
  };

  # vault-agent retrieves the PowerDNS API key from Vault (runtime path).
  # The SOPS-injected key at /run/secrets/certbot/pdns-api-key remains as
  # the bootstrap path. Both deliver the same value.
  vaultAgent.enable = true;
  vaultAgent.extraConfig = ''
    template {
      contents    = "{{ with secret \"secret/data/dns/pdns-api-key\" }}{{ .Data.data.value }}{{ end }}"
      destination = "/run/secrets/vault-agent/pdns-api-key"
      perms       = "0640"
    }
  '';

  # sqlite3 CLI for debugging (optional operator convenience)
  environment.systemPackages = with pkgs; [
    sqlite
  ];
}
