# certbot.nix — Reusable ACME certificate management module.
#
# Any VM that imports this module gets automatic TLS certificate issuance
# and renewal via certbot with DNS-01 challenges against PowerDNS.
#
# Runtime discovery (no hardcoded values):
#   FQDN:        hostname (from /etc/hostname) + search domain (from /etc/resolv.conf)
#   ACME server: /run/secrets/certbot/acme-server-url (injected by nocloud-init)
#   API key:     /run/secrets/certbot/pdns-api-key (injected by nocloud-init)
#   CA cert:     /run/secrets/certbot/acme-ca-cert (optional, injected for dev/Pebble)
#
# Certificate output: /etc/letsencrypt/live/<fqdn>/
#   cert.pem, chain.pem, fullchain.pem, privkey.pem

{ config, pkgs, lib, ... }:

let
  hookScriptsDir = ../../../framework/scripts;

  # Wrapper that sets PATH for the hook scripts (they need curl)
  wrapHook = name: script: pkgs.writeShellScript name ''
    export PATH=${lib.makeBinPath [ pkgs.curl pkgs.coreutils ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${script} "$@"
  '';

  authHook = wrapHook "certbot-auth-hook" "${hookScriptsDir}/certbot-auth-hook.sh";
  cleanupHook = wrapHook "certbot-cleanup-hook" "${hookScriptsDir}/certbot-cleanup-hook.sh";

  # Script to discover FQDN and run certbot
  certbotRunScript = pkgs.writeShellScript "certbot-run" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.certbot pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.inetutils
    ]}:$PATH

    # Discover FQDN: check explicit file first, then hostname + search domain.
    # Management-network VMs inject /run/secrets/certbot/fqdn via write_files
    # because the management DHCP has no project search domain.
    if [ -f /run/secrets/certbot/fqdn ] && [ -s /run/secrets/certbot/fqdn ]; then
      FQDN=$(cat /run/secrets/certbot/fqdn | tr -d '[:space:]')
      echo "Using explicit FQDN from /run/secrets/certbot/fqdn: $FQDN"
    else
      # Use hostname command (not /etc/hostname) because nocloud-init sets
      # the transient hostname; /etc/hostname is read-only on NixOS.
      HOSTNAME=$(hostname)
      # Try resolv.conf first, fall back to DHCP lease files
      SEARCH_DOMAIN=$(awk '/^search / { print $2; exit }' /etc/resolv.conf)
      if [ -z "$SEARCH_DOMAIN" ]; then
        # networkd stores DHCP lease with DOMAINNAME
        SEARCH_DOMAIN=$(awk -F= '/^DOMAINNAME=/ { print $2; exit }' /run/systemd/netif/leases/* 2>/dev/null)
      fi
      if [ -z "$SEARCH_DOMAIN" ]; then
        echo "ERROR: No domain found in resolv.conf or DHCP leases" >&2
        exit 1
      fi
      FQDN="''${HOSTNAME}.''${SEARCH_DOMAIN}"
    fi
    echo "Requesting certificate for: $FQDN"

    # Read ACME server URL
    if [ ! -f /run/secrets/certbot/acme-server-url ]; then
      echo "ERROR: /run/secrets/certbot/acme-server-url not found" >&2
      exit 1
    fi
    ACME_SERVER=$(cat /run/secrets/certbot/acme-server-url | tr -d '[:space:]')

    # Check for custom CA cert (Pebble in dev)
    EXTRA_ARGS=()
    if [ -f /run/secrets/certbot/acme-ca-cert ]; then
      # certbot (via python requests) uses REQUESTS_CA_BUNDLE for TLS trust
      export REQUESTS_CA_BUNDLE=/run/secrets/certbot/acme-ca-cert
    fi

    # Run certbot
    certbot certonly \
      --non-interactive \
      --agree-tos \
      --register-unsafely-without-email \
      --preferred-challenges dns \
      --manual \
      --manual-auth-hook "${authHook}" \
      --manual-cleanup-hook "${cleanupHook}" \
      --server "$ACME_SERVER" \
      --domain "$FQDN" \
      "''${EXTRA_ARGS[@]}"

    echo "Certificate issued successfully for $FQDN"
  '';

  # Script for renewal (reuses the same hooks and env detection)
  certbotRenewScript = pkgs.writeShellScript "certbot-renew" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.certbot pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.gawk
    ]}:$PATH

    # Set CA bundle for Pebble trust if present
    if [ -f /run/secrets/certbot/acme-ca-cert ]; then
      export REQUESTS_CA_BUNDLE=/run/secrets/certbot/acme-ca-cert
    fi

    certbot renew --non-interactive
  '';
in
{
  # certbot package
  environment.systemPackages = [ pkgs.certbot ];

  # Initial certificate request — runs once on first boot
  systemd.services.certbot-initial = {
    description = "Initial ACME certificate request";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "nocloud-init.service"
      "nss-lookup.target"
    ];
    wants = [ "network-online.target" "nss-lookup.target" ];
    requires = [ "nocloud-init.service" ];

    # Only run if no certificate exists yet
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecCondition = pkgs.writeShellScript "certbot-check-needed" ''
        if [ -f /run/secrets/certbot/fqdn ] && [ -s /run/secrets/certbot/fqdn ]; then
          FQDN=$(${pkgs.coreutils}/bin/cat /run/secrets/certbot/fqdn | ${pkgs.coreutils}/bin/tr -d '[:space:]')
        else
          HOSTNAME=$(${pkgs.inetutils}/bin/hostname)
          SEARCH_DOMAIN=$(${pkgs.gawk}/bin/awk '/^search / { print $2; exit }' /etc/resolv.conf)
          if [ -z "$SEARCH_DOMAIN" ]; then
            SEARCH_DOMAIN=$(${pkgs.gawk}/bin/awk -F= '/^DOMAINNAME=/ { print $2; exit }' /run/systemd/netif/leases/* 2>/dev/null)
          fi
          FQDN="''${HOSTNAME}.''${SEARCH_DOMAIN}"
        fi
        # Exit 0 (run certbot) if cert doesn't exist or is empty.
        # Exit 1 (skip) only if a valid non-empty cert is present.
        # Certbot can leave empty cert files after an ACME server outage.
        CERT="/etc/letsencrypt/live/''${FQDN}/fullchain.pem"
        [ ! -s "$CERT" ]
      '';
      ExecStart = certbotRunScript;
      # Retry with backoff on failure (DNS might not be ready immediately)
      Restart = "on-failure";
      RestartSec = "10s";
      RestartMaxDelaySec = "120s";
      StartLimitIntervalSec = 600;
      StartLimitBurst = 10;
    };
  };

  # Daily renewal timer
  systemd.timers.certbot-renew = {
    description = "Daily certbot renewal check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "12h";
      Persistent = true;
    };
  };

  systemd.services.certbot-renew = {
    description = "Certbot certificate renewal";
    after = [
      "network-online.target"
      "nocloud-init.service"
      "nss-lookup.target"
    ];
    wants = [ "network-online.target" "nss-lookup.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = certbotRenewScript;
    };
  };
}
