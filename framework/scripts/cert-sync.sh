#!/usr/bin/env bash
# cert-sync.sh — Sync the local certbot lineage back to Vault KV.

set -euo pipefail

LETSENCRYPT_DIR="${CERTBOT_LETSENCRYPT_DIR:-/etc/letsencrypt}"
TOKEN_FILE="${VAULT_TOKEN_FILE:-/run/vault-agent/token}"
RETRY_TIMER_UNIT="${CERT_SYNC_RETRY_TIMER_UNIT:-cert-sync-retry.timer}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
VAULT_ADDR_OVERRIDE="${VAULT_ADDR:-}"
FQDN_OVERRIDE="${CERTBOT_FQDN:-}"
SEARCH_DOMAIN_OVERRIDE="${CERTBOT_SEARCH_DOMAIN:-}"

log() {
  echo "cert-sync: $*"
}

warn() {
  echo "cert-sync: WARNING: $*" >&2
}

to_iso8601_utc() {
  local value="$1"

  if date -u -d "${value}" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -d "${value}" '+%Y-%m-%dT%H:%M:%SZ'
    return 0
  fi

  if date -u -j -f '%b %e %T %Y %Z' "${value}" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -j -f '%b %e %T %Y %Z' "${value}" '+%Y-%m-%dT%H:%M:%SZ'
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$value" <<'PY'
import datetime
import sys

value = sys.argv[1]
parsed = datetime.datetime.strptime(value, "%b %d %H:%M:%S %Y %Z")
print(parsed.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
    return 0
  fi

  return 1
}

discover_search_domain() {
  if [[ -n "${SEARCH_DOMAIN_OVERRIDE}" ]]; then
    printf '%s\n' "${SEARCH_DOMAIN_OVERRIDE}"
    return 0
  fi

  if [[ -s /run/secrets/network/search-domain ]]; then
    tr -d '[:space:]' < /run/secrets/network/search-domain
    return 0
  fi

  awk '/^search / { print $2; exit }' /etc/resolv.conf 2>/dev/null || true
}

discover_fqdn() {
  local search_domain=""
  if [[ -n "${FQDN_OVERRIDE}" ]]; then
    printf '%s\n' "${FQDN_OVERRIDE}"
    return 0
  fi

  if [[ -s /run/secrets/certbot/fqdn ]]; then
    tr -d '[:space:]' < /run/secrets/certbot/fqdn
    return 0
  fi

  search_domain="$(discover_search_domain)"
  if [[ -z "${search_domain}" ]]; then
    return 1
  fi

  printf '%s.%s\n' "$(hostname)" "${search_domain}"
}

vault_addr() {
  local search_domain=""
  if [[ -n "${VAULT_ADDR_OVERRIDE}" ]]; then
    printf '%s\n' "${VAULT_ADDR_OVERRIDE}"
    return 0
  fi

  search_domain="$(discover_search_domain)"
  if [[ -z "${search_domain}" ]]; then
    return 1
  fi

  printf 'https://vault.%s:8200\n' "${search_domain}"
}

enable_retry_timer() {
  if ! command -v "${SYSTEMCTL_BIN}" >/dev/null 2>&1; then
    warn "cannot enable ${RETRY_TIMER_UNIT}; ${SYSTEMCTL_BIN} not found"
    return 0
  fi
  "${SYSTEMCTL_BIN}" enable --now "${RETRY_TIMER_UNIT}" >/dev/null 2>&1 || true
}

disable_retry_timer() {
  if ! command -v "${SYSTEMCTL_BIN}" >/dev/null 2>&1; then
    return 0
  fi
  "${SYSTEMCTL_BIN}" stop "${RETRY_TIMER_UNIT}" >/dev/null 2>&1 || true
  "${SYSTEMCTL_BIN}" disable "${RETRY_TIMER_UNIT}" >/dev/null 2>&1 || true
}

main() {
  local fqdn=""
  local vault_addr_value=""
  local live_dir=""
  local fullchain_file=""
  local privkey_file=""
  local chain_file=""
  local cert_file=""
  local token=""
  local enddate=""
  local not_after=""
  local fingerprint=""
  local issued_at=""
  local fullchain=""
  local privkey=""
  local chain=""
  local cert=""
  local payload=""
  local metadata_payload=""
  local http_code=""
  local metadata_http_code=""

  fqdn="$(discover_fqdn)" || true
  if [[ -z "${fqdn}" ]]; then
    warn "unable to determine FQDN; skipping Vault sync"
    return 0
  fi

  live_dir="${LETSENCRYPT_DIR}/live/${fqdn}"
  fullchain_file="${live_dir}/fullchain.pem"
  privkey_file="${live_dir}/privkey.pem"
  chain_file="${live_dir}/chain.pem"
  cert_file="${live_dir}/cert.pem"

  if [[ ! -s "${TOKEN_FILE}" ]]; then
    warn "Vault token not available at ${TOKEN_FILE}; skipping Vault sync"
    return 0
  fi
  token="$(tr -d '[:space:]' < "${TOKEN_FILE}")"

  if [[ ! -s "${fullchain_file}" || ! -s "${privkey_file}" || ! -s "${chain_file}" || ! -s "${cert_file}" ]]; then
    warn "certificate files for ${fqdn} are incomplete; skipping Vault sync"
    return 0
  fi

  vault_addr_value="$(vault_addr)" || true
  if [[ -z "${vault_addr_value}" ]]; then
    warn "unable to determine Vault address for ${fqdn}; skipping Vault sync"
    return 0
  fi

  enddate="$(openssl x509 -in "${fullchain_file}" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')" || true
  if [[ -z "${enddate}" ]]; then
    warn "could not read certificate expiration for ${fqdn}; skipping Vault sync"
    return 0
  fi

  not_after="$(to_iso8601_utc "${enddate}" 2>/dev/null)" || true
  if [[ -z "${not_after}" ]]; then
    warn "could not normalize certificate expiration for ${fqdn}; skipping Vault sync"
    return 0
  fi

  fingerprint="$(
    openssl x509 -in "${fullchain_file}" -noout -fingerprint -sha256 2>/dev/null \
      | sed 's/^.*=//' \
      | tr -d ':' \
      | tr '[:upper:]' '[:lower:]'
  )" || true
  if [[ -z "${fingerprint}" ]]; then
    warn "could not compute certificate fingerprint for ${fqdn}; skipping Vault sync"
    return 0
  fi

  issued_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  fullchain="$(cat "${fullchain_file}")"
  privkey="$(cat "${privkey_file}")"
  chain="$(cat "${chain_file}")"
  cert="$(cat "${cert_file}")"

  payload="$(
    jq -n \
      --arg fullchain "${fullchain}" \
      --arg privkey "${privkey}" \
      --arg chain "${chain}" \
      --arg cert "${cert}" \
      --arg not_after "${not_after}" \
      --arg fingerprint "${fingerprint}" \
      --arg issued_at "${issued_at}" \
      '{
        data: {
          fullchain: $fullchain,
          privkey: $privkey,
          chain: $chain,
          cert: $cert,
          not_after: $not_after,
          fingerprint: $fingerprint,
          issued_at: $issued_at
        }
      }'
  )"

  metadata_payload="$(
    jq -n \
      --arg not_after "${not_after}" \
      --arg fingerprint "${fingerprint}" \
      '{custom_metadata: {not_after: $not_after, fingerprint: $fingerprint}}'
  )"

  http_code="$(
    curl -sk \
      -o /dev/null \
      -w '%{http_code}' \
      -H "X-Vault-Token: ${token}" \
      -H 'Content-Type: application/json' \
      -X POST \
      -d "${payload}" \
      "${vault_addr_value}/v1/mycofu/data/certs/${fqdn}" \
      2>/dev/null || true
  )"

  if [[ "${http_code}" =~ ^2[0-9][0-9]$ ]]; then
    metadata_http_code="$(
      curl -sk \
        -o /dev/null \
        -w '%{http_code}' \
        -H "X-Vault-Token: ${token}" \
        -H 'Content-Type: application/json' \
        -X POST \
        -d "${metadata_payload}" \
        "${vault_addr_value}/v1/mycofu/metadata/certs/${fqdn}" \
        2>/dev/null || true
    )"
    if [[ "${metadata_http_code}" =~ ^2[0-9][0-9]$ ]]; then
      log "synced ${fqdn} to Vault (fingerprint ${fingerprint})"
      disable_retry_timer
      return 0
    fi

    warn "Vault metadata sync failed for ${fqdn} (HTTP ${metadata_http_code:-curl-error}); enabling ${RETRY_TIMER_UNIT}"
    enable_retry_timer
    return 0
  fi

  warn "Vault sync failed for ${fqdn} (HTTP ${http_code:-curl-error}); enabling ${RETRY_TIMER_UNIT}"
  enable_retry_timer
  return 0
}

main "$@"
