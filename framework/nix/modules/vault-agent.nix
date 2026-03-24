# vault-agent.nix — Reusable Vault agent module for secret retrieval.
#
# Any VM that imports this module gets a vault-agent service that:
#   - Authenticates to Vault using the VM's TLS certificate (cert auth)
#   - Renders secret templates to /run/secrets/vault-agent/
#   - Watches cert files for changes and re-authenticates
#   - Manages its own token lifecycle
#
# Consuming modules (like dns.nix) declare templates via the
# vaultAgent.templates option.
#
# CA trust: if /run/secrets/certbot/acme-ca-cert exists (dev/Pebble),
# vault-agent uses it. Otherwise falls back to system CA bundle.
# This keeps the image environment-ignorant.

{ config, pkgs, lib, vaultPackage ? pkgs.vault, ... }:

let
  cfg = config.vaultAgent;

  # Generate vault-agent config at runtime (FQDN not known at build time)
  agentConfigScript = pkgs.writeShellScript "vault-agent-write-config" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.gawk pkgs.coreutils pkgs.inetutils ]}:$PATH

    HOSTNAME=$(hostname)
    SEARCH_DOMAIN=$(awk '/^search / { print $2; exit }' /etc/resolv.conf)
    if [ -z "$SEARCH_DOMAIN" ]; then
      SEARCH_DOMAIN=$(awk -F= '/^DOMAINNAME=/ { print $2; exit }' /run/systemd/netif/leases/* 2>/dev/null || true)
    fi
    if [ -z "$SEARCH_DOMAIN" ]; then
      echo "ERROR: No search domain found for vault-agent" >&2
      exit 1
    fi
    FQDN="''${HOSTNAME}.''${SEARCH_DOMAIN}"

    mkdir -p /run/vault-agent /run/secrets/vault-agent

    # CA cert: use Pebble CA if present, otherwise system bundle
    CA_CERT_LINE=""
    if [ -f /run/secrets/certbot/acme-ca-cert ]; then
      CA_CERT_LINE="ca_cert = \"/run/secrets/certbot/acme-ca-cert\""
    fi

    cat > /run/vault-agent/agent.hcl <<AGENTEOF
    vault {
      address = "https://vault.''${SEARCH_DOMAIN}:8200"
      $CA_CERT_LINE
    }

    auto_auth {
      method "cert" {
        config = {
          client_cert = "/etc/letsencrypt/live/''${FQDN}/cert.pem"
          client_key  = "/etc/letsencrypt/live/''${FQDN}/privkey.pem"
        }
      }

      sink "file" {
        config = {
          path = "/run/vault-agent/token"
          mode = 0640
        }
      }
    }

    ${cfg.extraConfig}
    AGENTEOF

    echo "vault-agent config written for ''${FQDN} → vault.''${SEARCH_DOMAIN}:8200"
  '';
in
{
  options.vaultAgent = {
    enable = lib.mkEnableOption "vault-agent for secret retrieval";

    extraConfig = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Additional HCL config appended to vault-agent config (templates, etc.)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Vault has a BSL 1.1 license (unfree in nixpkgs)
    nixpkgs.config.allowUnfreePredicate = pkg:
      builtins.elem (lib.getName pkg) [ "vault" ];
    # vault-agent systemd service
    systemd.services.vault-agent = {
      description = "Vault Agent — secret retrieval";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-online.target"
        "certbot-initial.service"
        "write-resolv-conf.service"
      ];
      wants = [ "network-online.target" ];
      requires = [ "certbot-initial.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "+${agentConfigScript}";
        ExecStart = "${vaultPackage}/bin/vault agent -config=/run/vault-agent/agent.hcl";
        Restart = "on-failure";
        RestartSec = "10s";
        StartLimitIntervalSec = 300;
        StartLimitBurst = 5;
      };
    };

    environment.systemPackages = [ vaultPackage ];
  };
}
