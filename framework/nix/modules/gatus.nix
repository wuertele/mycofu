# gatus.nix — Gatus health monitoring service.
#
# This module extends base.nix with:
#   - Gatus binary (from nixpkgs)
#   - Certbot for TLS certificate (prod VLAN, Let's Encrypt)
#   - Systemd service reading config from /run/secrets/gatus/config.yaml
#   - Firewall port 8080 (HTTP dashboard and API)
#
# Gatus config is delivered via write_files (CIDATA), not baked into the image.
# The config contains site-specific values (IPs, SMTP settings) that come
# from config.yaml → generate-gatus-config.sh → OpenTofu write_files.
#
# Gatus is prod-only, Category 1 (no precious state, fully rebuildable).

{ config, pkgs, lib, ... }:

{
  imports = [ ./certbot.nix ./vault-agent.nix ];

  # Gatus systemd service
  systemd.services.gatus = {
    description = "Gatus Health Monitor";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" "nocloud-init.service" "certbot-initial.service" ];
    wants = [ "network-online.target" ];
    requires = [ "nocloud-init.service" ];

    serviceConfig = {
      ExecStart = "${pkgs.gatus}/bin/gatus";
      Restart = "on-failure";
      RestartSec = "10s";
      DynamicUser = true;
      StateDirectory = "gatus";
      # Gatus reads config from GATUS_CONFIG_PATH
      Environment = "GATUS_CONFIG_PATH=/run/secrets/gatus/config.yaml";
    };

    # Wait for config file to exist (delivered by nocloud-init)
    unitConfig.ConditionPathExists = "/run/secrets/gatus/config.yaml";
  };

  # Firewall — HTTP dashboard and API
  networking.firewall.allowedTCPPorts = [ 8080 ];
}
