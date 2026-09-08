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
  vaultBackedCertStorage = config ? vaultAgent && config.vaultAgent.enable;
  vdbPersistedCertStorage = config.certbot.vdbPersistedCerts or false;
  systemdTools = config.systemd.package;

  # Wrapper that sets PATH for the hook scripts (they need curl)
  wrapHook = name: script: pkgs.writeShellScript name ''
    export PATH=${lib.makeBinPath [ pkgs.curl pkgs.coreutils ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${script} "$@"
  '';

  authHook = wrapHook "certbot-auth-hook" "${hookScriptsDir}/certbot-auth-hook.sh";
  cleanupHook = wrapHook "certbot-cleanup-hook" "${hookScriptsDir}/certbot-cleanup-hook.sh";
  persistedStateTool = pkgs.writeShellScriptBin "certbot-persisted-state.sh" ''
    export PATH=${lib.makeBinPath [
      pkgs.certbot pkgs.coreutils pkgs.findutils pkgs.gawk pkgs.gnused pkgs.openssl
    ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${hookScriptsDir}/certbot-persisted-state.sh "$@"
  '';
  renewabilityTool = pkgs.writeShellScriptBin "certbot-renewability.sh" ''
    export PATH=${lib.makeBinPath [
      pkgs.certbot pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.gawk
    ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${hookScriptsDir}/certbot-renewability.sh "$@"
  '';
  certSyncTool = pkgs.writeShellScriptBin "cert-sync" ''
    export PATH=${lib.makeBinPath [
      pkgs.coreutils pkgs.curl pkgs.gawk pkgs.gnused pkgs.inetutils pkgs.jq pkgs.openssl systemdTools
    ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${hookScriptsDir}/cert-sync.sh "$@"
  '';
  certbotInitialWrapperTool = pkgs.writeShellScriptBin "certbot-initial-wrapper" ''
    export PATH=${lib.makeBinPath [
      pkgs.coreutils pkgs.inetutils pkgs.jq systemdTools
    ]}:$PATH
    exec ${pkgs.bash}/bin/bash ${hookScriptsDir}/certbot-initial-wrapper.sh "$@"
  '';
  vaultReloadHook = pkgs.writeShellScript "certbot-vault-reload-hook" ''
    set -euo pipefail
    exec ${systemdTools}/bin/systemctl reload vault.service
  '';

  caBundlePath = "/etc/ssl/certs/ca-certificates.crt";

  certRestoreScript = pkgs.writeShellScript "cert-restore" ''
    set -uo pipefail
    export PATH=${lib.makeBinPath [
      pkgs.coreutils pkgs.curl pkgs.findutils pkgs.gawk pkgs.inetutils pkgs.jq pkgs.gnused
    ]}:$PATH

    log() {
      echo "cert-restore: $*"
    }

    main() {
      local token=""
      local wait_count=0
      local search_domain=""
      local fqdn=""
      local acme_server=""
      local vault_addr=""
      local response=""
      local fullchain=""
      local privkey=""
      local chain=""
      local cert=""
      local not_after=""
      local now_epoch=0
      local expiry_epoch=0
      local archive_dir=""
      local live_dir=""
      local renewal_conf=""

      while [ "$wait_count" -lt 60 ]; do
        if [ -s /run/vault-agent/token ]; then
          token=$(tr -d '[:space:]' < /run/vault-agent/token)
          break
        fi
        wait_count=$((wait_count + 1))
        sleep 1
      done

      if [ -z "$token" ]; then
        log "Vault token unavailable after 60s; skipping restore"
        return 0
      fi

      if [ -s /run/secrets/certbot/fqdn ]; then
        fqdn=$(tr -d '[:space:]' < /run/secrets/certbot/fqdn)
      else
        if [ -s /run/secrets/network/search-domain ]; then
          search_domain=$(tr -d '[:space:]' < /run/secrets/network/search-domain)
        else
          search_domain=$(awk '/^search / { print $2; exit }' /etc/resolv.conf 2>/dev/null || true)
        fi

        if [ -z "$search_domain" ]; then
          log "search domain unavailable; skipping restore"
          return 0
        fi

        fqdn="$(hostname).$search_domain"
      fi

      if [ ! -s /run/secrets/certbot/acme-server-url ]; then
        log "ACME server URL unavailable; skipping restore"
        return 0
      fi
      acme_server=$(tr -d '[:space:]' < /run/secrets/certbot/acme-server-url)

      if [ -n "$search_domain" ]; then
        vault_addr="https://vault.$search_domain:8200"
      elif [[ "$fqdn" == *.* ]]; then
        vault_addr="https://vault.''${fqdn#*.}:8200"
      else
        log "unable to derive Vault address for $fqdn; skipping restore"
        return 0
      fi

      response=$(
        curl -sk --max-time 10 \
          -H "X-Vault-Token: $token" \
          "$vault_addr/v1/mycofu/data/certs/$fqdn" 2>/dev/null || true
      )

      if [ -z "$response" ]; then
        log "Vault lookup failed for $fqdn; falling through to certbot"
        return 0
      fi

      fullchain=$(printf '%s' "$response" | jq -r '.data.data.fullchain // empty' 2>/dev/null || true)
      privkey=$(printf '%s' "$response" | jq -r '.data.data.privkey // empty' 2>/dev/null || true)
      chain=$(printf '%s' "$response" | jq -r '.data.data.chain // empty' 2>/dev/null || true)
      cert=$(printf '%s' "$response" | jq -r '.data.data.cert // empty' 2>/dev/null || true)
      not_after=$(printf '%s' "$response" | jq -r '.data.data.not_after // empty' 2>/dev/null || true)

      if [ -z "$fullchain" ] || [ -z "$privkey" ] || [ -z "$chain" ] || [ -z "$cert" ] || [ -z "$not_after" ]; then
        log "no restorable Vault cert found for $fqdn; falling through to certbot"
        return 0
      fi

      now_epoch=$(date -u +%s)
      expiry_epoch=$(date -u -d "$not_after" +%s 2>/dev/null || echo 0)
      if [ "$expiry_epoch" -le "$((now_epoch + 30 * 24 * 3600))" ]; then
        log "Vault cert for $fqdn is stale (not_after=$not_after); falling through to certbot"
        return 0
      fi

      archive_dir="/etc/letsencrypt/archive/$fqdn"
      live_dir="/etc/letsencrypt/live/$fqdn"
      renewal_conf="/etc/letsencrypt/renewal/$fqdn.conf"

      rm -rf "$archive_dir" "$live_dir"
      mkdir -p "$archive_dir" "$live_dir" /etc/letsencrypt/renewal

      # Write each PEM with a trailing newline (the Vault-stored values
      # have been normalized down through cert-sync's $(cat) and the
      # jq -r + $() round-trip here — both strip trailing newlines),
      # and reconstruct fullchain from cert + chain so certbot's
      # fullchain == cert + chain byte-comparison passes regardless of
      # what Vault stored for the fullchain field. $fullchain is still
      # fetched and non-empty-checked as a presence gate on the Vault
      # record; it is intentionally not used as the on-disk source of
      # truth for fullchain1.pem.
      printf '%s\n' "$cert" > "$archive_dir/cert1.pem"
      printf '%s\n' "$chain" > "$archive_dir/chain1.pem"
      cat "$archive_dir/cert1.pem" "$archive_dir/chain1.pem" \
        > "$archive_dir/fullchain1.pem"
      printf '%s\n' "$privkey" > "$archive_dir/privkey1.pem"

      chmod 644 "$archive_dir/cert1.pem" "$archive_dir/chain1.pem" "$archive_dir/fullchain1.pem"
      chmod 600 "$archive_dir/privkey1.pem"

      ln -sfn "../../archive/$fqdn/cert1.pem" "$live_dir/cert.pem"
      ln -sfn "../../archive/$fqdn/chain1.pem" "$live_dir/chain.pem"
      ln -sfn "../../archive/$fqdn/fullchain1.pem" "$live_dir/fullchain.pem"
      ln -sfn "../../archive/$fqdn/privkey1.pem" "$live_dir/privkey.pem"

      # Render renewal.conf to match certbot's native schema. R1.3 in
      # validate.sh asserts that dns1-prod and dns1-dev produce the
      # same set of field keys; the stub MUST emit the same active
      # keys certbot would write, otherwise restored VMs will fail
      # the regression check (issue #241).
      #
      # Shape captured from a known-good prod VM (vault-prod, which
      # has an unbroken cert lineage and was last touched by certbot
      # natively). Active-key set:
      #   version, archive_dir, cert, privkey, chain, fullchain,
      #   [renewalparams], account, pref_challs, server,
      #   authenticator, manual_auth_hook, manual_cleanup_hook,
      #   key_type, renew_hook
      # The `# renew_before_expiry = 30 days` line is commented in
      # certbot's native output (it's a default, not an override),
      # so it must be commented here too — uncommented would re-add
      # an extra key to the field-set diff.
      cat > "$renewal_conf" <<EOF
# renew_before_expiry = 30 days
version = 2.11.0
archive_dir = /etc/letsencrypt/archive/$fqdn
cert = /etc/letsencrypt/live/$fqdn/cert.pem
privkey = /etc/letsencrypt/live/$fqdn/privkey.pem
chain = /etc/letsencrypt/live/$fqdn/chain.pem
fullchain = /etc/letsencrypt/live/$fqdn/fullchain.pem

# Options used in the renewal process
[renewalparams]
account =
pref_challs = dns-01,
server = $acme_server
authenticator = manual
manual_auth_hook = ${authHook}
manual_cleanup_hook = ${cleanupHook}
key_type = ecdsa
renew_hook = ${certSyncTool}/bin/cert-sync
EOF

      log "restored certificate from Vault for $fqdn"
      return 0
    }

    if ! main; then
      log "restore encountered an error; continuing boot"
    fi
    exit 0
  '';

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
      ${lib.optionalString vaultBackedCertStorage "--deploy-hook \"${certSyncTool}/bin/cert-sync\" \\\n      "}--server "$ACME_SERVER" \
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

    # #642: operator-driven forced renewal. When CERTBOT_FORCE_RENEWAL is
    # set (delivered to the unit via the optional
    # /run/certbot-force-renewal.env EnvironmentFile below), certbot
    # renews even a far-from-expiry cert. This exists so the framework's
    # real renewal path -- including the deploy hooks and, on the Vault
    # VMs, `systemctl reload vault.service` -> ExecReload -- can be
    # exercised on demand (see framework/scripts/verify-vault-reload.sh).
    # Never set this on a schedule: on prod it consumes Let's Encrypt
    # duplicate-certificate quota (5/week).
    if [ -n "''${CERTBOT_FORCE_RENEWAL:-}" ]; then
      echo "certbot-renew: FORCED renewal requested via CERTBOT_FORCE_RENEWAL"
      # Single-use by construction. systemd has already read the
      # EnvironmentFile by the time ExecStart runs, so removing it here
      # cannot affect this invocation -- but it guarantees the next
      # timer-driven run is an ordinary renewal even if the operator (or
      # a crashed verify-vault-reload.sh) never cleans up. Without this,
      # a stale env file would force a renewal every day and, on prod,
      # exhaust the Let's Encrypt duplicate-certificate quota (5/week).
      # Never let cleanup failure block the renewal itself (set -e would
      # otherwise abort here on the extremely unlikely rm-fails path). The
      # workstation verify-vault-reload.sh EXIT trap is the primary cleanup;
      # this is defense-in-depth for the "verify process died" case.
      rm -f /run/certbot-force-renewal.env || \
        echo "certbot-renew: WARN failed to remove /run/certbot-force-renewal.env" >&2
    fi

    certbot renew --non-interactive ''${CERTBOT_FORCE_RENEWAL:+--force-renewal} \
      --manual-auth-hook "${authHook}" \
      --manual-cleanup-hook "${cleanupHook}"${lib.optionalString vaultBackedCertStorage " \\\n      --deploy-hook \"${certSyncTool}/bin/cert-sync\""}${lib.optionalString vdbPersistedCertStorage " \\\n      --deploy-hook \"${vaultReloadHook}\""}
  '';
in
{
  options.certbot.vdbPersistedCerts = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      If true, this host persists /etc/letsencrypt on vdb (per the
      vault-server exception in .claude/rules/certificates.md). Setting
      this exempts the host from the vaultAgent.enable / cert-restore
      requirement enforced by the assertion below, since recovery is
      disk-restore via PBS rather than Vault-restore.

      IMPORTANT: This option does NOT install the persistence
      mechanism — setting it true is a host's self-attestation that
      /etc/letsencrypt is already persisted via some other module.
      The only sanctioned consumer today is
      framework/nix/modules/vault.nix, which provides
      vault-cert-persist.service to migrate /etc/letsencrypt to
      /var/lib/vault/letsencrypt on vdb. Do NOT set this option
      without a corresponding service that performs the
      symlink/persistence — doing so silently bypasses the
      cert-recovery assertion and re-introduces the 2026-05-01
      LE rate-limit failure mode.

      The Vault role (both vault_dev and vault_prod, which share
      framework/nix/modules/vault.nix) must not depend on Vault to
      restore its own TLS certificate, so its /etc/letsencrypt tree
      is symlinked to /var/lib/vault/letsencrypt on vdb, and PBS
      backs up vdb. See framework/nix/modules/vault.nix.
    '';
  };

  config = {
    assertions = [{
      assertion = vaultBackedCertStorage || vdbPersistedCertStorage;
      message = ''
        This host imports certbot.nix but has no Vault-backed cert
        recovery path. Every VM recreation will consume a Let's Encrypt
        issuance against the per-domain rate limit (5 duplicate certs
        / 168h per FQDN), eventually triggering the outage pattern
        seen 2026-05-01. Either:
          • set vaultAgent.enable = true to enable cert-restore from
            Vault on boot (the standard pattern; see dns.nix, gatus.nix);
          • or set certbot.vdbPersistedCerts = true if this host
            persists /etc/letsencrypt on vdb (the vault-server case;
            see vault.nix and .claude/rules/certificates.md).

        Background:
          docs/reports/le-rate-limit-incident-2026-05-01.md
          .claude/rules/certificates.md
      '';
    }];

    # certbot package
    environment.systemPackages = [ pkgs.certbot persistedStateTool renewabilityTool certSyncTool certbotInitialWrapperTool ];

  # /etc/letsencrypt is bind-mounted from /nix/persist/letsencrypt in the
  # initrd overlay setup (base.nix). This service repairs the persisted
  # renewal lineage before certbot runs so rebooted overlay-root VMs do not
  # request unnecessary replacement certificates.
  systemd.services.certbot-repair-persisted-state = {
    description = "Repair persisted certbot renewal lineage";
    wantedBy = [ "multi-user.target" ];
    after = [
      "extra-ca-bundle.service"
      "network-online.target"
      "nocloud-init.service"
      "nss-lookup.target"
    ] ++ lib.optionals vaultBackedCertStorage [ "cert-restore.service" ];
    wants = [ "extra-ca-bundle.service" "network-online.target" "nss-lookup.target" ]
      ++ lib.optionals vaultBackedCertStorage [ "cert-restore.service" ];
    requires = [ "nocloud-init.service" ];
    before = [ "certbot-initial.service" "certbot-renew.service" ];

    # No RemainAfterExit: the repair must re-run before EVERY renewal, not just
    # once at boot (#610). certbot-renew.service both `wants` and `after`s this
    # unit, so a plain oneshot (which returns to inactive/dead after it exits)
    # is re-triggered and ordered ahead of each renewal. A prior successful boot
    # repair therefore cannot leave this unit `active (exited)` and get skipped
    # when a later step-ca account-DB reset kills the persisted account between
    # renewals (the F4 fragility called out in the RCA). Failure stays
    # best-effort: certbot-renew only `wants` (not `requires`) it, so a
    # fail-closed repair does not block the renewal attempt itself (#181).
    serviceConfig = {
      Type = "oneshot";
    };

    # Repair logic embedded directly (#181). Must not call framework
    # scripts — they don't exist on NixOS VMs. This is the boot-time
    # repair path only; the full check/repair script
    # (framework/scripts/certbot-persisted-state.sh) is for workstation
    # and pipeline use.
    path = with pkgs; [ coreutils gawk gnused findutils gnugrep certbot ];

    script = ''
      set -euo pipefail

      # certbot's python-requests defaults to the certifi bundle (public roots
      # only). The dev ACME CA root arrives via CIDATA and is merged into the
      # system bundle by extra-ca-bundle.service. Without this export,
      # show_account/register fail CERTIFICATE_VERIFY_FAILED against dev's CA,
      # the liveness probe returns `unreachable`, and the #525 self-heal fails
      # closed instead of re-registering the dead account (#568).
      export REQUESTS_CA_BUNDLE=${caBundlePath}

      LETSENCRYPT_DIR="/etc/letsencrypt"

      if [ ! -f /run/secrets/certbot/acme-server-url ]; then
        echo "certbot-repair: /run/secrets/certbot/acme-server-url not found" >&2
        exit 1
      fi

      EXPECTED_URL=$(tr -d '[:space:]' < /run/secrets/certbot/acme-server-url)
      if [ -z "$EXPECTED_URL" ] || ! echo "$EXPECTED_URL" | grep -qE '^https?://'; then
        echo "certbot-repair: invalid ACME URL: '$EXPECTED_URL'" >&2
        exit 1
      fi

      # Derive the account storage path from the URL
      # https://acme-v02.api.letsencrypt.org/directory
      # -> /etc/letsencrypt/accounts/acme-v02.api.letsencrypt.org/directory/
      EXPECTED_SERVER_PATH="''${EXPECTED_URL#https://}"
      EXPECTED_SERVER_PATH="''${EXPECTED_SERVER_PATH#http://}"
      EXPECTED_ACCOUNT_ROOT="''${LETSENCRYPT_DIR}/accounts/''${EXPECTED_SERVER_PATH}"

      # Find an account ID under the expected server directory
      find_expected_account() {
        [ -d "$EXPECTED_ACCOUNT_ROOT" ] || return 1
        local acct_dir
        acct_dir=$(find "$EXPECTED_ACCOUNT_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | head -1)
        [ -n "$acct_dir" ] || return 1
        basename "$acct_dir"
      }

      # Check if a specific account ID exists under the expected server.
      # Safe to call outside conditionals under set -e (#181 review issue 1).
      account_exists() {
        local acct_id="$1"
        if [ -z "$acct_id" ]; then
          return 1
        fi
        [ -d "''${EXPECTED_ACCOUNT_ROOT}/''${acct_id}" ]
      }

      # Rewrite a key = value line in a certbot renewal config file.
      # If the key doesn't exist, append it (END block).
      # Uses exact key match (word boundary) to avoid matching
      # dns_server when looking for server (#181 review issue 4).
      # Uses mv for atomic replacement (#181 review issue 5).
      rewrite_conf() {
        local file="$1" key="$2" value="$3"
        local tmp
        tmp=$(mktemp)
        awk -v key="$key" -v value="$value" '
          BEGIN { updated = 0 }
          $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            # Verify exact match — the first field before = must be
            # exactly the key, not a longer name containing the key
            split($0, parts, /=/)
            field = parts[1]
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", field)
            if (field == key) {
              print key " = " value
              updated = 1
              next
            }
          }
          { print }
          END { if (!updated) print key " = " value }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
      }

      # Extract a value from a certbot renewal config file.
      # Uses exact key match to avoid partial matches.
      extract_conf() {
        local file="$1" key="$2"
        awk -F '=' -v key="$key" '{
          field = $1
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", field)
          if (field == key) {
            sub(/^[^=]*=/, "", $0)
            v = $0
            sub(/^[[:space:]]+/, "", v)
            sub(/[[:space:]]+$/, "", v)
            print v
            exit
          }
        }' "$file"
      }

      # Probe the LIVE ACME server for a persisted account. Read-only:
      # `certbot show_account` performs a POST-as-GET to the stored account
      # URL, which the server answers when the account exists and rejects
      # with accountDoesNotExist when it does not. Echoes exactly one of:
      #   live        — server confirms the account (strict no-op)
      #   dead        — server definitively rejected it. certbot renders this
      #                 two ways: the ACME URN token `accountDoesNotExist`, and
      #                 the plain-text CLI form `Account does not exist`. Both
      #                 are matched (case/whitespace-robust) — matching only the
      #                 URN missed the plain-text form and left vault-dev's dead
      #                 account un-repaired (#610, follow-up to #525/#568).
      #   unreachable — no verdict; caller MUST fail closed and MUST NOT
      #                 re-register blind, because a dead account and a dead
      #                 network are otherwise indistinguishable (#525 / G4).
      # Only the classification token goes to stdout; raw certbot output is
      # kept on stderr so the $(...) capture stays clean.
      probe_account_liveness() {
        local server_url="$1"
        local out rc
        set +e
        out="$(certbot show_account --non-interactive --server "$server_url" \
          --config-dir "$LETSENCRYPT_DIR" 2>&1)"
        rc=$?
        set -e
        if [ "$rc" -eq 0 ]; then
          echo live
          return 0
        fi
        if printf '%s' "$out" | grep -qiE 'accountDoesNotExist|Account[[:space:]]+does[[:space:]]+not[[:space:]]+exist'; then
          echo dead
          return 0
        fi
        echo "certbot-repair: account-liveness probe against $server_url returned no verdict (rc=$rc)" >&2
        printf '%s\n' "$out" | sed 's/^/certbot-repair:   probe: /' >&2
        echo unreachable
        return 0
      }
      RENEWAL_DIR="''${LETSENCRYPT_DIR}/renewal"
      if [ ! -d "$RENEWAL_DIR" ]; then
        echo "certbot-repair: no renewal directory — nothing to repair"
        exit 0
      fi

      REPAIRED=0
      for conf in "$RENEWAL_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        cert_name=$(basename "$conf" .conf)

        current_server=$(extract_conf "$conf" "server")
        current_account=$(extract_conf "$conf" "account")

        if [ "$current_server" = "$EXPECTED_URL" ] && account_exists "$current_account"; then
          # Server and account look correct on disk. But the dev ACME server
          # (step-ca) may have been recreated or rebooted, leaving this
          # persisted account dangling server-side (#525). step-ca's ACME
          # account DB is ephemeral: it lives on the VM's tmpfs overlay, so
          # every reboot of the dev CA VM discards all registered accounts.
          # vault persists accounts/ on vdb via the /var/lib/vault/letsencrypt
          # symlink, so it is the one dev VM that carries a dead account across
          # a step-ca restart — every renewal then fails accountDoesNotExist.
          # Verify liveness against the live server before trusting the
          # on-disk account.
          liveness=$(probe_account_liveness "$EXPECTED_URL")
          case "$liveness" in
            live)
              : # server confirms the account
              ;;
            dead)
              echo "certbot-repair: $cert_name: ACME server rejected persisted account $current_account (accountDoesNotExist); re-registering" >&2
              # Remove the dangling on-disk account so find_expected_account
              # selects the freshly registered one, not the dead directory.
              rm -rf "''${EXPECTED_ACCOUNT_ROOT}/''${current_account:?}"
              certbot register \
                --non-interactive \
                --agree-tos \
                --register-unsafely-without-email \
                --server "$EXPECTED_URL" \
                --config-dir "$LETSENCRYPT_DIR" 2>/dev/null || true
              desired_account=$(find_expected_account 2>/dev/null || true)
              if [ -n "$desired_account" ]; then
                rewrite_conf "$conf" "account" "$desired_account"
                echo "certbot-repair: $cert_name: rewrote account to $desired_account"
                REPAIRED=1
              else
                echo "certbot-repair: $cert_name: ERROR: re-registration produced no account for $EXPECTED_URL" >&2
                exit 1
              fi
              ;;
            unreachable)
              echo "certbot-repair: $cert_name: could not verify account $current_account against $EXPECTED_URL; failing closed (not re-registering)" >&2
              exit 1
              ;;
          esac

          # Server and account are correct, but check for 0-byte cert files.
          # Certbot can leave empty PEM files after a failed ACME challenge.
          # These prevent certbot from re-requesting because it thinks the
          # cert exists. Remove the entire lineage so certbot treats it as
          # a fresh request.
          CERT_LIVE="''${LETSENCRYPT_DIR}/live/''${cert_name}"
          CERT_ARCHIVE="''${LETSENCRYPT_DIR}/archive/''${cert_name}"
          EMPTY_FOUND=0
          for pem in "$CERT_LIVE"/*.pem "$CERT_ARCHIVE"/*.pem; do
            [ -e "$pem" ] || continue
            if [ ! -s "$pem" ]; then
              EMPTY_FOUND=1
              break
            fi
          done
          if [ "$EMPTY_FOUND" -eq 1 ]; then
            echo "certbot-repair: $cert_name: EMPTY PEM FILES DETECTED — removing stale lineage"
            rm -rf "$CERT_LIVE" "$CERT_ARCHIVE"
            rm -f "$conf"
            echo "certbot-repair: $cert_name: removed live/, archive/, and renewal config"
            REPAIRED=1
          else
            echo "certbot-repair: $cert_name: cert files OK"
          fi
          continue
        fi

        # Server URL mismatch — rewrite metadata and delete stale certs.
        # The cert files were issued by the old ACME server (e.g. staging)
        # and won't be trusted. Deleting them lets certbot-initial
        # re-acquire from the correct server (#174).
        if [ "$current_server" != "$EXPECTED_URL" ]; then
          rewrite_conf "$conf" "server" "$EXPECTED_URL"
          CERT_LIVE="''${LETSENCRYPT_DIR}/live/''${cert_name}"
          CERT_ARCHIVE="''${LETSENCRYPT_DIR}/archive/''${cert_name}"
          if [ -d "$CERT_LIVE" ]; then
            rm -f "''${CERT_LIVE}"/*.pem
            echo "certbot-repair: $cert_name: deleted stale certs from live/"
          fi
          if [ -d "$CERT_ARCHIVE" ]; then
            rm -f "''${CERT_ARCHIVE}"/*.pem
            echo "certbot-repair: $cert_name: deleted stale certs from archive/"
          fi
          echo "certbot-repair: $cert_name: rewrote server to $EXPECTED_URL"
          REPAIRED=1
        fi

        # Account mismatch or missing — find the right one
        if ! account_exists "$current_account"; then
          desired_account=$(find_expected_account 2>/dev/null || true)
          if [ -n "$desired_account" ]; then
            rewrite_conf "$conf" "account" "$desired_account"
            echo "certbot-repair: $cert_name: rewrote account to $desired_account"
            REPAIRED=1
          else
            # No account exists for the expected server. Register one
            # so certbot-renew can use it. certbot-initial will also
            # register if needed, but having the account ready is cleaner.
            echo "certbot-repair: $cert_name: no account for $EXPECTED_URL; registering"
            certbot register \
              --non-interactive \
              --agree-tos \
              --register-unsafely-without-email \
              --server "$EXPECTED_URL" \
              --config-dir "$LETSENCRYPT_DIR" 2>/dev/null || true
            desired_account=$(find_expected_account 2>/dev/null || true)
            if [ -n "$desired_account" ]; then
              rewrite_conf "$conf" "account" "$desired_account"
              echo "certbot-repair: $cert_name: rewrote account to $desired_account"
              REPAIRED=1
            else
              echo "certbot-repair: $cert_name: WARNING: could not find or create account for $EXPECTED_URL" >&2
            fi
          fi
        fi

      done

      RENEWABILITY_FAILURES=0
      for conf in "$RENEWAL_DIR"/*.conf; do
        [ -f "$conf" ] || continue
        cert_name=$(basename "$conf" .conf)
        set +e
        probe_output="$(${renewabilityTool}/bin/certbot-renewability.sh --cert-name "$cert_name" 2>&1)"
        probe_rc=$?
        set -e
        case "$probe_rc" in
          0)
            echo "certbot-repair: $cert_name: renewability OK"
            if [ -n "$probe_output" ]; then
              printf '%s\n' "$probe_output" | sed 's/^/certbot-repair:   /'
            fi
            ;;
          1)
            echo "certbot-repair: $cert_name: renewability FAILED" >&2
            if [ -n "$probe_output" ]; then
              printf '%s\n' "$probe_output" | sed 's/^/certbot-repair:   /' >&2
            fi
            RENEWABILITY_FAILURES=$((RENEWABILITY_FAILURES + 1))
            ;;
          3)
            echo "certbot-repair: $cert_name: renewability UNKNOWN" >&2
            if [ -n "$probe_output" ]; then
              printf '%s\n' "$probe_output" | sed 's/^/certbot-repair:   /' >&2
            fi
            RENEWABILITY_FAILURES=$((RENEWABILITY_FAILURES + 1))
            ;;
          *)
            echo "certbot-repair: $cert_name: renewability probe returned unexpected rc=$probe_rc" >&2
            if [ -n "$probe_output" ]; then
              printf '%s\n' "$probe_output" | sed 's/^/certbot-repair:   /' >&2
            fi
            RENEWABILITY_FAILURES=$((RENEWABILITY_FAILURES + 1))
            ;;
        esac
      done

      if [ "$RENEWABILITY_FAILURES" -gt 0 ]; then
        exit 1
      fi

      if [ "$REPAIRED" -eq 0 ]; then
        echo "certbot-repair: all renewal configs OK and renewable"
      fi
    '';
  };

  systemd.services.cert-restore = lib.mkIf vaultBackedCertStorage {
    description = "Restore TLS certificate from Vault";
    wantedBy = [ "multi-user.target" ];
    after = [
      "vault-agent.service"
      "network-online.target"
      "nocloud-init.service"
    ];
    wants = [ "vault-agent.service" "network-online.target" ];
    requires = [ "nocloud-init.service" ];
    # Run certbot-repair after cert-restore on Vault-backed hosts. This keeps
    # cert-restore focused on rebuilding the on-disk lineage, and reuses the
    # existing repair path to create or rewrite the ACME account instead of
    # duplicating account-registration logic in two boot-time services.
    before = [ "certbot-repair-persisted-state.service" "certbot-initial.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = certRestoreScript;
    };
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
      "certbot-repair-persisted-state.service"
    ] ++ lib.optionals vaultBackedCertStorage [ "cert-restore.service" ];
    # certbot-repair is best-effort (Wants not Requires) — failure must not block cert acquisition (#181)
    wants = [ "extra-ca-bundle.service" "network-online.target" "nss-lookup.target" "certbot-repair-persisted-state.service" ]
      ++ lib.optionals vaultBackedCertStorage [ "cert-restore.service" ];
    requires = [ "nocloud-init.service" ];

    # Only run if no certificate exists yet
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "certbot";
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
      ExecStart = "${certbotInitialWrapperTool}/bin/certbot-initial-wrapper ${certbotRunScript}${lib.optionalString vaultBackedCertStorage " ${certSyncTool}/bin/cert-sync"}";
      Restart = "no";
    };
  };

  systemd.timers.cert-sync-retry = lib.mkIf vaultBackedCertStorage {
    description = "Retry TLS certificate sync to Vault";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15min";
      OnUnitActiveSec = "15min";
      Persistent = true;
      Unit = "cert-sync.service";
    };
  };

  systemd.services.cert-sync = lib.mkIf vaultBackedCertStorage {
    description = "Sync TLS certificate to Vault";
    after = [ "certbot-initial.service" ];
    unitConfig.ConditionPathExists = "/run/vault-agent/token";
    unitConfig.ConditionPathExistsGlob = "/etc/letsencrypt/live/*/fullchain.pem";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${certSyncTool}/bin/cert-sync";
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
      "certbot-repair-persisted-state.service"
    ];
    # certbot-repair is best-effort (Wants not Requires) — failure must not block renewal (#181)
    wants = [ "extra-ca-bundle.service" "network-online.target" "nss-lookup.target" "certbot-repair-persisted-state.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = certbotRenewScript;
      # #642: optional operator-provided env file (tmpfs, absent by
      # default -- the leading "-" makes it non-fatal). Lets
      # verify-vault-reload.sh run a FORCED renewal through the real
      # unit, preserving ordering (certbot-repair-persisted-state runs
      # first) instead of hand-invoking the renew script over SSH.
      EnvironmentFile = "-/run/certbot-force-renewal.env";
    };
  };
  };
}
