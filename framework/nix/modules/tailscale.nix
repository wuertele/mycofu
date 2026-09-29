{ config, pkgs, lib, ... }:

let
  authKeyPath = "/run/secrets/tailscale/auth-key";
  identityFile = "/run/secrets/vault-agent/tailscale-identity";
  roleOverrideFile = "/run/secrets/tailscale/role";
  stateDir = "/var/lib/tailscale";
  vaultTokenPath = "/run/vault-agent/token";

  tailscaleCli = lib.getExe config.services.tailscale.package;

  identityCommon = ''
    IDC_BASE64=${pkgs.coreutils}/bin/base64
    IDC_CP=${pkgs.coreutils}/bin/cp
    IDC_CURL=${pkgs.curl}/bin/curl
    IDC_FIND=${pkgs.findutils}/bin/find
    IDC_JQ=${pkgs.jq}/bin/jq
    IDC_MKDIR=${pkgs.coreutils}/bin/mkdir
    IDC_MKTEMP=${pkgs.coreutils}/bin/mktemp
    IDC_RM=${pkgs.coreutils}/bin/rm
    IDC_TAR=${pkgs.gnutar}/bin/tar
    IDC_TR=${pkgs.coreutils}/bin/tr

    # #1002/#407: callers must be able to tell a DEFINITIVE ABSENCE (Vault
    # reached and authenticated, but no stored identity for this node — safe to
    # enroll fresh) from a TRANSIENT/INDETERMINATE failure (no answer, 403,
    # 5xx/sealed — must NOT enroll, or a recreated VM with a recoverable
    # identity would be orphaned behind an expired auth key). Return codes:
    #   0   usable identity found (prints "format\nvalue" on stdout)
    #   10  definitive absence — ONLY a clean KV v2 missing-secret 404
    #       (a single {"errors":[]} object, no .data). Nothing else is 10.
    #   11  transient/indeterminate — everything else: connection failure,
    #       403, 5xx/sealed, any non-200/404 status, a malformed or
    #       metadata-bearing or error-bearing 404, and an HTTP 200 that is
    #       unparseable or carries no usable identity.
    identity_fetch_from_vault() {
      local vault_addr="$1"
      local vault_path="$2"
      local token="$3"
      local body_file=""
      local http_code=""
      local curl_rc=0
      local body=""
      local format=""
      local value=""

      local fmt_rc=0
      local val_rc=0
      local data_rc=0
      local rc=11
      local out=""
      # Run ALL fallible I/O with errexit OFF and classify explicitly, so an
      # incidental non-zero (curl error, missing temp file, jq parse failure,
      # cleanup) can never be misread as "absence": every ambiguity fails
      # closed as transient (11). Only a clean, parseable HTTP 404 with no
      # version metadata is a genuine first-deploy absence (10). Save and
      # restore errexit because restore.sh calls this in-process, not in a
      # subshell.
      local _saved_e=0
      case $- in *e*) _saved_e=1 ;; esac
      set +e

      body_file="$($IDC_MKTEMP)"
      if [[ -z "$body_file" ]]; then
        [[ "$_saved_e" -eq 1 ]] && set -e
        echo "''${IDC_LOG_PREFIX}: could not create temp file for the Vault lookup" >&2
        return 11
      fi

      http_code="$($IDC_CURL -sk --connect-timeout 5 --max-time 15 -o "$body_file" -w '%{http_code}' -H "X-Vault-Token: $token" "''${vault_addr}/v1/''${vault_path}" 2>/dev/null)"
      curl_rc=$?
      body="$(< "$body_file")"
      $IDC_RM -f "$body_file" 2>/dev/null

      if [[ "$curl_rc" -ne 0 || -z "$http_code" || "$http_code" == "000" ]]; then
        echo "''${IDC_LOG_PREFIX}: Vault lookup transport failure (curl_rc=$curl_rc http_code=''${http_code:-none}); treating as transient" >&2
        rc=11
      else
        case "$http_code" in
          200)
            # A 200 means the secret exists. Only a fully parseable, usable
            # identity is a restore; a parse failure or a present-but-unusable
            # record is indeterminate (never "absence") and fails closed.
            format="$(printf '%s' "$body" | $IDC_JQ -r '.data.data.format // empty' 2>/dev/null)"; fmt_rc=$?
            value="$(printf '%s' "$body" | $IDC_JQ -r '.data.data.value // empty' 2>/dev/null)"; val_rc=$?
            if [[ "$fmt_rc" -ne 0 || "$val_rc" -ne 0 ]]; then
              echo "''${IDC_LOG_PREFIX}: Vault returned 200 but the identity record could not be parsed; treating as indeterminate" >&2
              rc=11
            elif [[ -n "$format" && -n "$value" ]]; then
              out="$(printf '%s\n%s\n' "$format" "$value")"
              rc=0
            else
              echo "''${IDC_LOG_PREFIX}: Vault returned 200 with no usable identity fields; treating as indeterminate, not absence" >&2
              rc=11
            fi
            ;;
          404)
            # Only the clean KV v2 missing-secret 404 is a genuine first-deploy
            # absence: a SINGLE JSON object of the exact shape {"errors":[]}
            # with no .data. Everything else fails closed — a metadata-bearing
            # 404 (soft-deleted/destroyed, still recoverable), a routing or
            # permission error 404 ({"errors":["no handler for route ..."]}),
            # a bare null, a multi-value body, or an unparseable body. None of
            # those establish that the intended secret is absent.
            printf '%s' "$body" | $IDC_JQ -s -e 'length == 1 and (.[0].errors == []) and (.[0] | has("data") | not)' >/dev/null 2>&1
            data_rc=$?
            if [[ "$data_rc" -eq 0 ]]; then
              rc=10
            else
              echo "''${IDC_LOG_PREFIX}: Vault 404 was not the clean missing-secret shape (metadata, error, multi-value, or unparseable); treating as indeterminate, not absence" >&2
              rc=11
            fi
            ;;
          *)
            echo "''${IDC_LOG_PREFIX}: Vault lookup returned HTTP $http_code; treating as transient" >&2
            rc=11
            ;;
        esac
      fi

      [[ "$_saved_e" -eq 1 ]] && set -e
      if [[ "$rc" -eq 0 ]]; then
        printf '%s\n' "$out"
      fi
      return "$rc"
    }

    identity_install_payload() {
      local format="$1"
      local payload="$2"
      local tmp_dir=""

      if [[ "$format" != "tar-b64" ]]; then
        echo "''${IDC_LOG_PREFIX}: unsupported format '$format', skipping restore"
        return 2
      fi
      # Normalize here rather than at each call site: the restore path already
      # stripped whitespace when parsing its two-line scratch file, and the
      # join path passes the Vault value straight through. base64 payloads
      # contain no whitespace, so stripping is a no-op on well-formed input.
      payload="$(printf '%s' "$payload" | $IDC_TR -d '[:space:]')"
      if [[ -z "$payload" ]]; then
        echo "''${IDC_LOG_PREFIX}: Vault identity payload is empty"
        return 2
      fi

      tmp_dir="$($IDC_MKTEMP -d)" || return 1
      if printf '%s' "$payload" | $IDC_BASE64 -d | $IDC_TAR -C "$tmp_dir" -xf -; then
        if ! $IDC_MKDIR -p "${stateDir}"; then
          $IDC_RM -rf "$tmp_dir"
          return 1
        fi
        $IDC_FIND "${stateDir}" -mindepth 1 -maxdepth 1 -exec $IDC_RM -rf {} + 2>/dev/null || true
        if ! $IDC_CP -a "$tmp_dir"/. "${stateDir}"/; then
          $IDC_RM -rf "$tmp_dir"
          return 1
        fi
        $IDC_RM -rf "$tmp_dir"
        echo "''${IDC_LOG_PREFIX}: restored identity into ${stateDir}"
        return 0
      fi

      $IDC_RM -rf "$tmp_dir"
      echo "''${IDC_LOG_PREFIX}: failed to decode or extract Vault identity, continuing without restore"
      return 2
    }
  '';

  restoreIdentity = pkgs.writeShellScript "tailscale-identity-restore" ''
    set -euo pipefail

    AWK=${pkgs.gawk}/bin/awk
    DNSDOMAINNAME=${pkgs.inetutils}/bin/dnsdomainname
    HOSTNAME=${pkgs.inetutils}/bin/hostname
    SEQ=${pkgs.coreutils}/bin/seq
    SED=${pkgs.gnused}/bin/sed
    SLEEP=${pkgs.coreutils}/bin/sleep
    TAIL=${pkgs.coreutils}/bin/tail
    TR=${pkgs.coreutils}/bin/tr
    TOKEN_TIMEOUT_SEC=60
    IDC_LOG_PREFIX="tailscale-identity-restore"

    ${identityCommon}

    wait_for_vault_token() {
      # Trade-off: wait long enough for vault-agent authentication to complete
      # so recreated VMs can recover their prior identity from Vault, but keep
      # the timeout bounded so first boot without a stored secret still falls
      # back to a fresh join.
      for _ in $($SEQ 1 "$TOKEN_TIMEOUT_SEC"); do
        if [[ -s "${vaultTokenPath}" ]]; then
          return 0
        fi
        $SLEEP 1
      done
      return 1
    }

    get_vault_token() {
      if [[ ! -s "${vaultTokenPath}" ]]; then
        return 1
      fi
      $TR -d '[:space:]' < "${vaultTokenPath}"
    }

    ROLE="$($HOSTNAME | $TR -d '[:space:]')"
    if [[ -s "${roleOverrideFile}" ]]; then
      ROLE="$($TR -d '[:space:]' < "${roleOverrideFile}")"
    fi

    SEARCH_DOMAIN="$($DNSDOMAINNAME 2>/dev/null | $TR -d '[:space:]' || true)"
    if [[ -z "$SEARCH_DOMAIN" || "$SEARCH_DOMAIN" == "(none)" ]]; then
      SEARCH_DOMAIN="$($AWK '/^search / { print $2; exit }' /etc/resolv.conf 2>/dev/null | $TR -d '[:space:]' || true)"
    fi
    if [[ -z "$SEARCH_DOMAIN" ]]; then
      echo "tailscale-identity-restore: no search domain available"
      exit 0
    fi

    BASE_DOMAIN="$SEARCH_DOMAIN"
    case "$BASE_DOMAIN" in
      prod.*|dev.*) BASE_DOMAIN="''${BASE_DOMAIN#*.}" ;;
    esac

    VAULT_ADDR="https://vault.''${SEARCH_DOMAIN}:8200"
    VAULT_PATH="secret/data/tailscale/nodes/''${BASE_DOMAIN}/''${ROLE}"

    if ! wait_for_vault_token; then
      echo "tailscale-identity-restore: no Vault token after ''${TOKEN_TIMEOUT_SEC}s"
      exit 0
    fi

    if ! {
      TOKEN="$(get_vault_token)" &&
      identity_fetch_from_vault "$VAULT_ADDR" "$VAULT_PATH" "$TOKEN"
    } > "${identityFile}"; then
      echo "tailscale-identity-restore: no Vault identity found at ''${VAULT_PATH}"
      exit 0
    fi

    FORMAT="$($SED -n '1p' "${identityFile}" | $TR -d '[:space:]')"
    PAYLOAD="$($TAIL -n +2 "${identityFile}" | $TR -d '[:space:]')"
    set +e
    identity_install_payload "$FORMAT" "$PAYLOAD"
    INSTALL_RC=$?
    set -e
    if [[ "$INSTALL_RC" -eq 1 ]]; then
      exit 1
    fi
    exit 0
  '';

  joinTailnet = pkgs.writeShellScript "tailscale-join" ''
    set -euo pipefail

    AWK=${pkgs.gawk}/bin/awk
    BASE64=${pkgs.coreutils}/bin/base64
    CURL=${pkgs.curl}/bin/curl
    DNSDOMAINNAME=${pkgs.inetutils}/bin/dnsdomainname
    HOSTNAME=${pkgs.inetutils}/bin/hostname
    JQ=${pkgs.jq}/bin/jq
    SEQ=${pkgs.coreutils}/bin/seq
    SLEEP=${pkgs.coreutils}/bin/sleep
    SYSTEMCTL=${config.systemd.package}/bin/systemctl
    TAR=${pkgs.gnutar}/bin/tar
    TR=${pkgs.coreutils}/bin/tr
    IDC_LOG_PREFIX="tailscale-join"

    ${identityCommon}

    ROLE="$($HOSTNAME | $TR -d '[:space:]')"
    if [[ -s "${roleOverrideFile}" ]]; then
      ROLE="$($TR -d '[:space:]' < "${roleOverrideFile}")"
    fi
    SEARCH_DOMAIN="$($DNSDOMAINNAME 2>/dev/null | $TR -d '[:space:]' || true)"
    if [[ -z "$SEARCH_DOMAIN" || "$SEARCH_DOMAIN" == "(none)" ]]; then
      SEARCH_DOMAIN="$($AWK '/^search / { print $2; exit }' /etc/resolv.conf 2>/dev/null | $TR -d '[:space:]' || true)"
    fi
    if [[ -z "$SEARCH_DOMAIN" ]]; then
      echo "tailscale-join: no search domain available"
      exit 1
    fi

    BASE_DOMAIN="$SEARCH_DOMAIN"
    case "$BASE_DOMAIN" in
      prod.*|dev.*) BASE_DOMAIN="''${BASE_DOMAIN#*.}" ;;
    esac

    DOMAIN_DASHED="$(printf '%s' "$BASE_DOMAIN" | $TR '.' '-')"
    MACHINE_NAME="''${ROLE}-''${DOMAIN_DASHED}"

    TAGS="tag:mycofu"
    SHARED_ROLE=0
    case "$ROLE" in
      gitlab|cicd|pbs)
        TAGS="''${TAGS},tag:mycofu-ctl"
        SHARED_ROLE=1
        ;;
    esac

    ENV_PREFIX="$(printf '%s' "$SEARCH_DOMAIN" | $AWK -F. '{print $1}')"
    if [[ "$SHARED_ROLE" -eq 0 && ( "$ENV_PREFIX" == "prod" || "$ENV_PREFIX" == "dev" ) ]]; then
      TAGS="''${TAGS},tag:mycofu-''${ENV_PREFIX}"
    fi

    VAULT_ADDR="https://vault.''${SEARCH_DOMAIN}:8200"
    VAULT_PATH="secret/data/tailscale/nodes/''${BASE_DOMAIN}/''${ROLE}"
    HAVE_VAULT_TOKEN=0

    get_backend_state() {
      ${tailscaleCli} status --json --peers=false 2>/dev/null | $JQ -r '.BackendState // empty' 2>/dev/null || true
    }

    get_tailscale_ip() {
      ${tailscaleCli} status --json --peers=false 2>/dev/null | $JQ -r '.Self.TailscaleIPs[0] // empty' 2>/dev/null || true
    }

    wait_for_backend_state() {
      # Wait for a SETTLED state. NoState and Starting are transient startup
      # states: a freshly-recreated node passes through Starting on its way to
      # NeedsLogin, so returning on Starting could let it bypass the NeedsLogin
      # fail-closed gate and reach enrollment (#1002). If it never settles
      # within the window, return non-zero so the caller fails closed and
      # systemd retries — never enroll on an unsettled state.
      local state=""
      for _ in $($SEQ 1 60); do
        state="$(get_backend_state)"
        case "$state" in
          Running|NeedsLogin|Stopped|NeedsMachineAuth)
            printf '%s\n' "$state"
            return 0
            ;;
        esac
        $SLEEP 1
      done
      return 1
    }

    wait_for_connected() {
      local state=""
      local ip=""
      for _ in $($SEQ 1 30); do
        state="$(get_backend_state)"
        ip="$(get_tailscale_ip)"
        if [[ "$state" == "Running" && -n "$ip" ]]; then
          printf '%s\n' "$ip"
          return 0
        fi
        $SLEEP 1
      done
      return 1
    }

    wait_for_vault_token() {
      for _ in $($SEQ 1 60); do
        if [[ -s "${vaultTokenPath}" ]]; then
          return 0
        fi
        $SLEEP 1
      done
      return 1
    }

    get_vault_token() {
      if [[ ! -s "${vaultTokenPath}" ]]; then
        return 1
      fi
      $TR -d '[:space:]' < "${vaultTokenPath}"
    }

    vault_has_identity() {
      local token=""

      token="$(get_vault_token)" || return 1
      # The shared reader intentionally requires both format and value: a
      # value-only record cannot be restored, so the Running path repairs it.
      identity_fetch_from_vault "$VAULT_ADDR" "$VAULT_PATH" "$token" >/dev/null
    }

    serialize_identity() {
      [[ -d "${stateDir}" ]] || return 1
      $TAR -C "${stateDir}" -cf - . | $BASE64 -w0
    }

    write_identity_to_vault() {
      local token=""
      local identity=""
      local payload=""

      token="$(get_vault_token)" || return 1
      identity="$(serialize_identity)" || return 1
      payload="$(printf '%s' "$identity" | $JQ -Rs '{data:{format:"tar-b64",value:.}}')"

      $CURL -skf -X POST \
        -H "X-Vault-Token: ''${token}" \
        -H "Content-Type: application/json" \
        -d "''${payload}" \
        "''${VAULT_ADDR}/v1/''${VAULT_PATH}" >/dev/null
    }

    echo "tailscale-join: waiting for tailscaled backend state"
    if ! INITIAL_STATE="$(wait_for_backend_state)"; then
      echo "tailscale-join: tailscaled did not become ready within 60s"
      exit 1
    fi

    if wait_for_vault_token; then
      HAVE_VAULT_TOKEN=1
    else
      echo "tailscale-join: Vault token unavailable after 60s, continuing without Vault sync"
    fi

    if [[ "$INITIAL_STATE" == "Running" ]]; then
      if [[ "$HAVE_VAULT_TOKEN" -eq 1 ]]; then
        if vault_has_identity; then
          echo "tailscale-join: already connected and Vault identity is present"
          exit 0
        fi

        if write_identity_to_vault; then
          echo "tailscale-join: repaired missing Vault identity"
        else
          echo "tailscale-join: connected, but failed to repair Vault identity"
        fi
      else
        echo "tailscale-join: already connected; skipping Vault identity check"
      fi
      exit 0
    fi

    # #1002/#407: NeedsLogin is the only backend state meaning there is no
    # usable login profile — the recreated-VM incident state. Starting and
    # NoState are unsettled and are waited past by wait_for_backend_state (which
    # fails closed if they never settle), so they never reach this decision.
    # Stopped and NeedsMachineAuth imply an existing profile that must not be
    # destroyed, handled by the pre-existing fall-through below; Running is
    # handled above. The enrollment fallback must be reached ONLY on a
    # DEFINITIVE ABSENCE (a clean KV v2 missing-secret 404, FETCH_RC=10).
    # Everything else — no token yet, Vault unreachable/403/5xx/sealed, a
    # metadata/error/malformed 404, or a fetched record that will not install —
    # must FAIL CLOSED so systemd (Restart=on-failure) retries until Vault
    # answers, rather than fresh-enrolling on a timing coincidence and orphaning
    # a recoverable identity behind a long-expired auth key.
    if [[ "$INITIAL_STATE" == "NeedsLogin" ]]; then
      if [[ "$HAVE_VAULT_TOKEN" -ne 1 ]]; then
        echo "tailscale-join: ERROR: NeedsLogin but no Vault token yet (Vault/DNS not ready); refusing to fresh-enroll on a transient. Failing so systemd retries."
        exit 1
      fi

      VAULT_TOKEN="$(get_vault_token)"
      set +e
      IDENTITY="$(identity_fetch_from_vault "$VAULT_ADDR" "$VAULT_PATH" "$VAULT_TOKEN")"
      FETCH_RC=$?
      set -e

      if [[ "$FETCH_RC" -eq 11 ]]; then
        echo "tailscale-join: ERROR: Vault unreachable or indeterminate during identity lookup; refusing to fresh-enroll on a transient. Failing so systemd retries."
        exit 1
      elif [[ "$FETCH_RC" -eq 0 ]]; then
        FORMAT="''${IDENTITY%%$'\n'*}"
        PAYLOAD="''${IDENTITY#*$'\n'}"
        # Stop the daemon before touching its state dir. tailscaled owns
        # tailscaled.state and flushes its in-memory profile at shutdown, so
        # installing first and restarting afterwards lets the outgoing daemon
        # clobber the file that was just restored.
        if ! $SYSTEMCTL stop tailscaled.service; then
          echo "tailscale-join: ERROR: Vault holds an identity for this node but tailscaled.service could not be stopped, so it cannot be installed safely"
          echo "tailscale-join: ERROR: deliberately NOT enrolling because fresh enrollment would orphan the stored Vault identity"
          exit 1
        fi

        set +e
        identity_install_payload "$FORMAT" "$PAYLOAD"
        INSTALL_RC=$?
        set -e
        if [[ "$INSTALL_RC" -eq 0 ]]; then
          if ! $SYSTEMCTL start tailscaled.service; then
            echo "tailscale-join: failed to start tailscaled.service after restoring Vault identity; checking the authoritative backend state anyway"
          fi
          if TAILSCALE_IP="$(wait_for_connected)"; then
            echo "tailscale-join: restored Vault identity and connected with Tailscale IP ''${TAILSCALE_IP}"
            exit 0
          fi
          echo "tailscale-join: ERROR: Vault identity was restored, but tailscaled did not reach Running state within 30s"
          echo "tailscale-join: ERROR: deliberately NOT falling back to the auth key because fresh enrollment would orphan the restored identity"
          exit 1
        fi

        # ANY install failure (RC=1 local error, RC=2 undecodable/extraction
        # failure, or anything unexpected) means we FETCHED a Vault record but
        # could not install it — fail closed and let systemd retry. The failure
        # may be transient (a filesystem/tar hiccup on a valid, recoverable
        # identity), and enrolling fresh would orphan that record. A genuinely
        # corrupt record is recovered by deleting the Vault secret, after which
        # the lookup returns a clean 404 and first-enrollment proceeds. The
        # state dir was untouched on a decode failure, so restart the daemon so
        # the retry re-reads it.
        $SYSTEMCTL start tailscaled.service || echo "tailscale-join: failed to restart tailscaled.service after an install failure"
        echo "tailscale-join: ERROR: a Vault identity exists but could not be installed (INSTALL_RC=$INSTALL_RC); refusing to fresh-enroll. Failing so systemd retries."
        exit 1
      elif [[ "$FETCH_RC" -eq 10 ]]; then
        # Definitive absence (clean HTTP 404, no recoverable version) is the
        # ONLY path to first-time enrollment.
        echo "tailscale-join: no stored Vault identity for this node (definitive absence); proceeding to first-time enrollment"
      else
        # Any other result is unexpected — fail closed rather than enroll on an
        # ambiguity (design-taste P8: safety fails closed).
        echo "tailscale-join: ERROR: unexpected identity-lookup result (FETCH_RC=$FETCH_RC); refusing to fresh-enroll. Failing so systemd retries."
        exit 1
      fi
    fi

    if [[ ! -s "${authKeyPath}" ]]; then
      echo "tailscale-join: no Vault identity to restore and no fallback auth key at ${authKeyPath}; cannot enroll this node"
      exit 1
    fi
    AUTH_KEY="$($TR -d '[:space:]' < "${authKeyPath}")"
    if [[ -z "$AUTH_KEY" ]]; then
      echo "tailscale-join: auth key file is empty"
      exit 1
    fi

    echo "tailscale-join: joining tailnet as ''${MACHINE_NAME} with tags ''${TAGS}"
    ${tailscaleCli} up \
      --auth-key "''${AUTH_KEY}" \
      --hostname "''${MACHINE_NAME}" \
      --advertise-tags "''${TAGS}" \
      --accept-dns=false \
      --accept-routes=false

    if ! TAILSCALE_IP="$(wait_for_connected)"; then
      echo "tailscale-join: join completed, but node never reached Running state"
      exit 1
    fi
    echo "tailscale-join: connected with Tailscale IP ''${TAILSCALE_IP}"

    if [[ "$HAVE_VAULT_TOKEN" -eq 1 ]]; then
      if write_identity_to_vault; then
        echo "tailscale-join: identity written to Vault"
      else
        echo "tailscale-join: connected, but failed to write identity to Vault"
      fi
    else
      echo "tailscale-join: connected, but Vault token is unavailable so identity sync is deferred"
    fi
  '';

in
{
  services.tailscale.enable = true;

  # Tell systemd-networkd-wait-online to skip tailscale0 when computing
  # online status. Reason: the upstream services.tailscale module generates
  # /etc/systemd/network/50-tailscale.network with `[Match] Name=tailscale0`
  # + `[Link] Unmanaged=true`. The Match makes networkd notice the
  # interface; Unmanaged=true tells networkd not to configure it (tailscaled
  # owns it). The upstream file does NOT set `RequiredForOnline=no`, so the
  # SETUP state stays `pending` indefinitely — networkd never configures it,
  # tailscaled does. wait-online's default "all interfaces must be
  # configured" criterion then times out at --timeout=120 on every closure
  # switch, producing a switch-to-configuration exit 4 false positive.
  #
  # This option preserves wait-online's strict semantic for every interface
  # networkd legitimately manages (ens18, future mgmt-nics, etc.) while
  # declaring the true fact that tailscale0 is not managed by networkd.
  # See issue #434.
  # Use the upstream-tracked interface name (defaults to "tailscale0") so
  # this stays correct if a future role overrides services.tailscale.interfaceName.
  # Both the upstream-generated .network's [Match] Name= and the wait-online
  # ignore then point at the same name.
  systemd.network.wait-online.ignoredInterfaces = [ config.services.tailscale.interfaceName ];

  # Deliberately no auth-key ConditionPathExists on tailscaled, restore, or
  # join: module import is the capability gate, and a Vault-restored identity
  # must boot without a fallback key. See #1002 and its RCA.

  systemd.services.tailscale-identity-restore = {
    description = "Restore Tailscale identity from Vault";
    wantedBy = [ "multi-user.target" ];
    after = [ "vault-agent.service" ];
    wants = [ "vault-agent.service" ];
    before = [ "tailscaled.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # systemd 256 disables the oneshot startup timeout by default. Bound this
      # unit explicitly: it runs before tailscaled, so a stalled Vault GET here
      # would otherwise hang the boot behind it and the self-healing join would
      # never start. The curl calls are also bounded by --max-time; this is
      # defense in depth. 60s token wait + one ~15s bounded GET, with margin.
      TimeoutStartSec = "120s";
    };
    script = ''
      exec ${restoreIdentity}
    '';
  };

  systemd.services.tailscale-join = {
    description = "Join Tailscale and sync identity to Vault";
    wantedBy = [ "multi-user.target" ];
    after = [ "tailscaled.service" ];
    wants = [ "tailscaled.service" "vault-agent.service" ];
    # #1002: the script fails closed on any transient (Vault/DNS not ready)
    # rather than fresh-enrolling. Restart=on-failure self-heals the moment
    # DNS and Vault become reachable. startLimitIntervalSec=0 disables the
    # start-rate limit so a long Vault/DNS outage never trips the unit into a
    # terminal `failed` state that would strand the node off the tailnet — it
    # keeps retrying, and never fresh-enrolls on a timing coincidence. Each
    # fail-closed attempt logs its reason to the journal; persistent
    # degradation is caught by validate.sh on every pipeline/DRT today, and
    # will be surfaced continuously by the Gatus watchdog (#1002 follow-up).
    # oneshot + Restart=on-failure is the same pattern used in gitlab.nix.
    startLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # 60s backend wait + 60s token wait + 30s connection wait, with
      # another 150s of margin for the bounded restore and Vault operations.
      TimeoutStartSec = "300s";
      Restart = "on-failure";
      RestartSec = "15s";
    };
    script = ''
      exec ${joinTailnet}
    '';
  };
}
