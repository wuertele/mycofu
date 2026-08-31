# vault-agent.nix — Reusable Vault agent module for secret retrieval.
#
# Any VM that imports this module gets a vault-agent service that:
#   - Authenticates to Vault using AppRole (role_id + secret_id from CIDATA)
#   - Renders secret templates to /run/secrets/vault-agent/
#   - Manages its own token lifecycle (auto-renew)
#
# AppRole credentials are bootstrap-tier secrets delivered via CIDATA:
#   /run/secrets/vault/role-id   — stable, write-once
#   /run/secrets/vault/secret-id — stable, write-once
#
# Consuming modules (like dns.nix) declare templates via the
# vaultAgent.templates option.
#
# CA trust uses the system bundle path unconditionally. On dev, the
# extra-ca-bundle boot service augments that path with the step-ca root.

{ config, pkgs, lib, vaultPackage ? pkgs.vault, ... }:

let
  cfg = config.vaultAgent;

  # Generate vault-agent config at runtime (FQDN not known at build time)
  agentConfigScript = pkgs.writeShellScript "vault-agent-write-config" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [ pkgs.gawk pkgs.coreutils pkgs.inetutils ]}:$PATH

    SEARCH_DOMAIN=$(cat /run/secrets/network/search-domain 2>/dev/null || true)
    if [ -z "$SEARCH_DOMAIN" ]; then
      SEARCH_DOMAIN=$(awk '/^search / { print $2; exit }' /etc/resolv.conf)
    fi
    if [ -z "$SEARCH_DOMAIN" ]; then
      echo "ERROR: No search domain found for vault-agent" >&2
      exit 1
    fi

    mkdir -p /run/vault-agent /run/secrets/vault-agent

    cat > /run/vault-agent/agent.hcl <<AGENTEOF
    vault {
      address = "https://vault.''${SEARCH_DOMAIN}:8200"
    }

    auto_auth {
      method "approle" {
        config = {
          role_id_file_path   = "/run/secrets/vault/role-id"
          secret_id_file_path = "/run/secrets/vault/secret-id"
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

    echo "vault-agent config written: vault.''${SEARCH_DOMAIN}:8200 (AppRole auth)"
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
        "extra-ca-bundle.service"
        "network-online.target"
        "nocloud-init.service"
        "write-resolv-conf.service"
      ];
      wants = [ "extra-ca-bundle.service" "network-online.target" ];
      requires = [ "nocloud-init.service" ];
      # vault binary requires getent at runtime for token helper path
      # expansion. Without it: "exec: getent: executable file not found
      # in $PATH" and vault-agent crash-loops indefinitely.
      # getent is in pkgs.glibc.getent (split from pkgs.glibc.bin in newer nixpkgs).
      path = [ pkgs.glibc.getent ];
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
