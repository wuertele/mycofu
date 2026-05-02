{ config, pkgs, lib, ... }:

let
  authKeyPath = "/run/secrets/tailscale/auth-key";
  identityFile = "/run/secrets/vault-agent/tailscale-identity";
  roleOverrideFile = "/run/secrets/tailscale/role";
  stateDir = "/var/lib/tailscale";
  vaultTokenPath = "/run/vault-agent/token";

  tailscaleCli = lib.getExe config.services.tailscale.package;

  restoreIdentity = pkgs.writeShellScript "tailscale-identity-restore" ''
    set -euo pipefail

    AWK=${pkgs.gawk}/bin/awk
    BASE64=${pkgs.coreutils}/bin/base64
    CP=${pkgs.coreutils}/bin/cp
    CURL=${pkgs.curl}/bin/curl
    DNSDOMAINNAME=${pkgs.inetutils}/bin/dnsdomainname
    HOSTNAME=${pkgs.inetutils}/bin/hostname
    MKDIR=${pkgs.coreutils}/bin/mkdir
    MKTEMP=${pkgs.coreutils}/bin/mktemp
    JQ=${pkgs.jq}/bin/jq
    RM=${pkgs.coreutils}/bin/rm
    SEQ=${pkgs.coreutils}/bin/seq
    SED=${pkgs.gnused}/bin/sed
    SLEEP=${pkgs.coreutils}/bin/sleep
    TAR=${pkgs.gnutar}/bin/tar
    TAIL=${pkgs.coreutils}/bin/tail
    TR=${pkgs.coreutils}/bin/tr
    FIND=${pkgs.findutils}/bin/find
    TOKEN_TIMEOUT_SEC=60

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

    read_identity_from_vault() {
      local token=""
      local response=""
      local format=""
      local value=""

      token="$(get_vault_token)" || return 1
      response="$($CURL -skf -H "X-Vault-Token: $token" "''${VAULT_ADDR}/v1/''${VAULT_PATH}" 2>/dev/null || true)"
      [[ -n "$response" ]] || return 1

      format="$(printf '%s' "$response" | $JQ -r '.data.data.format // empty' 2>/dev/null || true)"
      value="$(printf '%s' "$response" | $JQ -r '.data.data.value // empty' 2>/dev/null || true)"
      [[ -n "$format" && -n "$value" ]] || return 1

      printf '%s\n%s\n' "$format" "$value"
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

    if ! read_identity_from_vault > "${identityFile}"; then
      echo "tailscale-identity-restore: no Vault identity found at ''${VAULT_PATH}"
      exit 0
    fi

    FORMAT="$($SED -n '1p' "${identityFile}" | $TR -d '[:space:]')"
    if [[ "$FORMAT" != "tar-b64" ]]; then
      echo "tailscale-identity-restore: unsupported format '$FORMAT', skipping restore"
      exit 0
    fi

    PAYLOAD="$($TAIL -n +2 "${identityFile}" | $TR -d '[:space:]')"
    if [[ -z "$PAYLOAD" ]]; then
      echo "tailscale-identity-restore: Vault identity payload is empty"
      exit 0
    fi

    TMP_DIR="$($MKTEMP -d)"
    cleanup() {
      $RM -rf "$TMP_DIR"
    }
    trap cleanup EXIT

    if printf '%s' "$PAYLOAD" | $BASE64 -d | $TAR -C "$TMP_DIR" -xf -; then
      $MKDIR -p "${stateDir}"
      $FIND "${stateDir}" -mindepth 1 -maxdepth 1 -exec $RM -rf {} + 2>/dev/null || true
      $CP -a "$TMP_DIR"/. "${stateDir}"/
      echo "tailscale-identity-restore: restored identity into ${stateDir}"
    else
      echo "tailscale-identity-restore: failed to decode or extract Vault identity, continuing without restore"
    fi
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
    TAR=${pkgs.gnutar}/bin/tar
    TR=${pkgs.coreutils}/bin/tr

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

    read_vault_identity() {
      local token=""
      local response=""
      local value=""

      token="$(get_vault_token)" || return 1
      response="$($CURL -skf -H "X-Vault-Token: $token" "''${VAULT_ADDR}/v1/''${VAULT_PATH}" 2>/dev/null || true)"
      [[ -n "$response" ]] || return 1

      value="$(printf '%s' "$response" | $JQ -r '.data.data.value // empty' 2>/dev/null || true)"
      [[ -n "$value" ]] || return 1

      printf '%s\n' "$value"
    }

    vault_has_identity() {
      local value=""
      value="$(read_vault_identity || true)"
      [[ -n "$value" ]]
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

  systemd.services.tailscaled.unitConfig.ConditionPathExists = authKeyPath;

  systemd.services.tailscale-identity-restore = {
    description = "Restore Tailscale identity from Vault";
    wantedBy = [ "multi-user.target" ];
    after = [ "vault-agent.service" ];
    wants = [ "vault-agent.service" ];
    before = [ "tailscaled.service" ];
    unitConfig.ConditionPathExists = authKeyPath;
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
    unitConfig.ConditionPathExists = authKeyPath;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      exec ${joinTailnet}
    '';
  };
}
