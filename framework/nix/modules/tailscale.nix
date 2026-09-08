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

    identity_fetch_from_vault() {
      local vault_addr="$1"
      local vault_path="$2"
      local token="$3"
      local response=""
      local format=""
      local value=""

      if ! response="$($IDC_CURL -skf -H "X-Vault-Token: $token" "''${vault_addr}/v1/''${vault_path}" 2>/dev/null)"; then
        return 1
      fi
      [[ -n "$response" ]] || return 1

      format="$(printf '%s' "$response" | $IDC_JQ -r '.data.data.format // empty' 2>/dev/null || true)"
      value="$(printf '%s' "$response" | $IDC_JQ -r '.data.data.value // empty' 2>/dev/null || true)"
      [[ -n "$format" && -n "$value" ]] || return 1

      printf '%s\n%s\n' "$format" "$value"
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
      local state=""
      for _ in $($SEQ 1 60); do
        state="$(get_backend_state)"
        if [[ -n "$state" && "$state" != "NoState" ]]; then
          printf '%s\n' "$state"
          return 0
        fi
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

    # #1002/#407: the restore unit's bounded 60s token wait can expire before
    # vault-agent authenticates. NeedsLogin is the only backend state meaning
    # there is no usable login profile: Starting, Stopped, and NeedsMachineAuth
    # all imply an existing profile that must not be destroyed, while Running
    # is handled above. NeedsLogin is also the recreated-VM incident state.
    if [[ "$INITIAL_STATE" == "NeedsLogin" && "$HAVE_VAULT_TOKEN" -eq 1 ]]; then
      VAULT_TOKEN=""
      IDENTITY=""
      if VAULT_TOKEN="$(get_vault_token)" && \
         IDENTITY="$(identity_fetch_from_vault "$VAULT_ADDR" "$VAULT_PATH" "$VAULT_TOKEN")"; then
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
        elif [[ "$INSTALL_RC" -eq 1 ]]; then
          echo "tailscale-join: ERROR: a recoverable Vault identity exists but could not be installed locally"
          echo "tailscale-join: ERROR: deliberately NOT enrolling because fresh enrollment would orphan the recoverable Vault identity"
          exit 1
        fi

        # INSTALL_RC=2: the stored record cannot produce state (bad format,
        # empty, or undecodable) and the state dir was never touched, so
        # enrolling is safe. Bring the daemon back first.
        echo "tailscale-join: stored Vault identity payload is unusable; falling back to the auth key"
        if ! $SYSTEMCTL start tailscaled.service; then
          echo "tailscale-join: failed to start tailscaled.service after rejecting the unusable Vault identity"
        fi
      else
        echo "tailscale-join: no usable Vault identity available (absent, unreadable, or Vault transiently unavailable); falling back to the auth key"
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
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # 60s backend wait + 60s token wait + 30s connection wait, with
      # another 150s of margin for the bounded restore and Vault operations.
      TimeoutStartSec = "300s";
    };
    script = ''
      exec ${joinTailnet}
    '';
  };
}
