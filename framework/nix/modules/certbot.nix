# certbot.nix — Reusable ACME certificate management module.
#
# Any VM that imports this module gets automatic TLS certificate issuance
# and renewal via certbot with DNS-01 challenges against PowerDNS.
#
# Runtime discovery (no hardcoded values):
#   FQDN:        hostname (from /etc/hostname) + search domain (from /etc/resolv.conf)
#   ACME server: /run/secrets/certbot/acme-server-url (injected by nocloud-init)
#   API key:     /run/secrets/certbot/pdns-api-key (injected by nocloud-init)
#   CA bundle:   /etc/ssl/certs/ca-certificates.crt (rewritten by extra-ca-bundle on dev)
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

  caBundlePath = "/etc/ssl/certs/ca-certificates.crt";

  # Script to discover FQDN and run certbot
  certbotRunScript = pkgs.writeShellScript "certbot-run" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.certbot pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.gawk pkgs.inetutils pkgs.findutils
    ]}:$PATH

    # Clean up stale certbot account data after PBS restore (#165).
    # PBS may restore /etc/letsencrypt/accounts/ with an empty regr.json,
    # causing certbot to crash with DeserializationError. Deleting the
    # accounts directory forces certbot to register a fresh ACME account.
    if find /etc/letsencrypt/accounts -name 'regr.json' -empty 2>/dev/null | grep -q .; then
      echo "WARNING: Found empty regr.json in certbot accounts — removing stale account data"
      rm -rf /etc/letsencrypt/accounts
    fi

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

    # requests may still use certifi depending on the Python packaging path.
    # Point it at the standard bundle path, which extra-ca-bundle rewrites
    # to the combined bundle on dev and leaves untouched on prod.
    export REQUESTS_CA_BUNDLE=${caBundlePath}

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
      --domain "$FQDN"

    echo "Certificate issued successfully for $FQDN"
  '';

  # Script for renewal (reuses the same hooks and env detection)
  certbotRenewScript = pkgs.writeShellScript "certbot-renew" ''
    set -euo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.certbot pkgs.curl pkgs.coreutils pkgs.gnugrep pkgs.gawk
    ]}:$PATH

    export REQUESTS_CA_BUNDLE=${caBundlePath}

    certbot renew --non-interactive
  '';
  # If the VM has a vdb data disk, persist /etc/letsencrypt on it so certs
  # survive VM recreation and PBS restore. This prevents LE rate limit
  # exhaustion during development rebuilds (#165).
  vdbMountPoint = config.mycofu.vdbMountPoint or "";
  hasVdb = vdbMountPoint != "";
in
{
  # certbot package
  environment.systemPackages = [ pkgs.certbot ];

  # Persist /etc/letsencrypt on vdb when available. On VMs without vdb,
  # /etc/letsencrypt is a normal directory on vda (lost on rebuild).
  systemd.services.certbot-persist-certs = lib.mkIf hasVdb {
    description = "Symlink /etc/letsencrypt to vdb for cert persistence";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" ];
    before = [ "certbot-initial.service" "certbot-renew.service" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    path = [ pkgs.coreutils ];

    script = ''
      VDB_LE="${vdbMountPoint}/letsencrypt"

      # Create the directory on vdb if it doesn't exist
      mkdir -p "$VDB_LE"

      # If /etc/letsencrypt is a real directory (first boot after image
      # change, or legacy VM), move any existing content to vdb
      if [ -d /etc/letsencrypt ] && [ ! -L /etc/letsencrypt ]; then
        # Move existing cert data to vdb (preserves certs from first boot
        # if certbot ran before this service existed)
        if [ "$(ls -A /etc/letsencrypt 2>/dev/null)" ]; then
          cp -a /etc/letsencrypt/. "$VDB_LE/"
        fi
        rm -rf /etc/letsencrypt
      fi

      # Create the symlink if it doesn't exist or points elsewhere
      if [ ! -L /etc/letsencrypt ] || [ "$(readlink /etc/letsencrypt)" != "$VDB_LE" ]; then
        rm -f /etc/letsencrypt
        ln -s "$VDB_LE" /etc/letsencrypt
        echo "Symlinked /etc/letsencrypt -> $VDB_LE"
      else
        echo "/etc/letsencrypt already symlinked to $VDB_LE"
      fi
    '';
  };

  # Initial certificate request — runs once on first boot
  systemd.services.certbot-initial = {
    description = "Initial ACME certificate request";
    wantedBy = [ "multi-user.target" ];
    after = [
      "extra-ca-bundle.service"
      "network-online.target"
      "nocloud-init.service"
      "nss-lookup.target"
    ] ++ lib.optionals hasVdb [ "certbot-persist-certs.service" ];
    wants = [ "extra-ca-bundle.service" "network-online.target" "nss-lookup.target" ];
    requires = [ "nocloud-init.service" ] ++ lib.optionals hasVdb [ "certbot-persist-certs.service" ];

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
      "extra-ca-bundle.service"
      "network-online.target"
      "nocloud-init.service"
      "nss-lookup.target"
    ] ++ lib.optionals hasVdb [ "certbot-persist-certs.service" ];
    wants = [ "extra-ca-bundle.service" "network-online.target" "nss-lookup.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = certbotRenewScript;
    };
  };
}
