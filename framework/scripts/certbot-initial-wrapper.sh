#!/usr/bin/env bash
# certbot-initial-wrapper.sh — Own certbot-initial retry state and backoff.

set -euo pipefail

STATE_FILE="${CERTBOT_INITIAL_STATE_FILE:-/var/lib/certbot/initial-retry.json}"
MAX_FAILURES="${CERTBOT_INITIAL_MAX_FAILURES:-10}"
WINDOW_SEC="${CERTBOT_INITIAL_WINDOW_SEC:-86400}"
BACKOFF_BASE_SEC="${CERTBOT_INITIAL_BACKOFF_BASE_SEC:-60}"
BACKOFF_CAP_SEC="${CERTBOT_INITIAL_BACKOFF_CAP_SEC:-3600}"
SINGLE_SHOT="${CERTBOT_INITIAL_SINGLE_SHOT:-0}"
FQDN_OVERRIDE="${CERTBOT_FQDN:-}"
SEARCH_DOMAIN_OVERRIDE="${CERTBOT_SEARCH_DOMAIN:-}"

usage() {
  cat >&2 <<'EOF'
Usage: certbot-initial-wrapper.sh <certbot-command> [cert-sync-command]
EOF
}

log() {
  echo "certbot-initial: $*"
}

warn() {
  echo "certbot-initial: WARNING: $*" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 2
fi

CERTBOT_COMMAND="$1"
CERT_SYNC_COMMAND="${2:-}"

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

load_state() {
  ATTEMPTS=0
  FIRST_FAILURE_EPOCH=0

  if [[ ! -s "${STATE_FILE}" ]]; then
    return 0
  fi

  ATTEMPTS="$(jq -r '.attempts // 0' "${STATE_FILE}" 2>/dev/null || echo "__invalid__")"
  FIRST_FAILURE_EPOCH="$(jq -r '.first_failure_epoch // 0' "${STATE_FILE}" 2>/dev/null || echo "__invalid__")"

  if [[ ! "${ATTEMPTS}" =~ ^[0-9]+$ || ! "${FIRST_FAILURE_EPOCH}" =~ ^[0-9]+$ ]]; then
    warn "retry state at ${STATE_FILE} is invalid; treating it as empty"
    ATTEMPTS=0
    FIRST_FAILURE_EPOCH=0
  fi
}

write_state() {
  local attempts="$1"
  local first_failure_epoch="$2"
  local tmp_file=""

  mkdir -p "$(dirname "${STATE_FILE}")"
  tmp_file="$(mktemp "${STATE_FILE}.XXXXXX")"
  jq -n \
    --argjson attempts "${attempts}" \
    --argjson first_failure_epoch "${first_failure_epoch}" \
    '{attempts: $attempts, first_failure_epoch: $first_failure_epoch}' > "${tmp_file}"
  mv "${tmp_file}" "${STATE_FILE}"
}

clear_state() {
  rm -f "${STATE_FILE}"
}

backoff_for_attempts() {
  local attempts="$1"
  local exponent=0
  local value="${BACKOFF_BASE_SEC}"

  if (( attempts <= 0 )); then
    echo 0
    return 0
  fi

  exponent=$((attempts - 1))
  while (( exponent > 0 )); do
    value=$((value * 2))
    if (( value >= BACKOFF_CAP_SEC )); then
      echo "${BACKOFF_CAP_SEC}"
      return 0
    fi
    exponent=$((exponent - 1))
  done

  if (( value > BACKOFF_CAP_SEC )); then
    value="${BACKOFF_CAP_SEC}"
  fi

  echo "${value}"
}

FQDN="$(discover_fqdn || true)"
if [[ -z "${FQDN}" ]]; then
  FQDN="<unknown-fqdn>"
fi

while true; do
  NOW_EPOCH="$(date +%s)"
  load_state

  if (( FIRST_FAILURE_EPOCH > 0 )) && (( NOW_EPOCH - FIRST_FAILURE_EPOCH >= WINDOW_SEC )); then
    ATTEMPTS=0
    FIRST_FAILURE_EPOCH=0
  fi

  if (( ATTEMPTS >= MAX_FAILURES )); then
    log "giving up for ${FQDN} after ${MAX_FAILURES} failures in 24h. Investigate the cause (rate limit? DNS? ACME outage?) then run: systemctl restart certbot-initial"
    clear_state
    exit 1
  fi

  if (( ATTEMPTS >= 1 )); then
    BACKOFF_SEC="$(backoff_for_attempts "${ATTEMPTS}")"
    log "sleeping ${BACKOFF_SEC}s before retry ${ATTEMPTS} for ${FQDN}"
    sleep "${BACKOFF_SEC}"
  fi

  if "${CERTBOT_COMMAND}"; then
    clear_state
    if [[ -n "${CERT_SYNC_COMMAND}" ]]; then
      "${CERT_SYNC_COMMAND}" || warn "cert-sync command reported failure after issuing ${FQDN}"
    fi
    exit 0
  fi

  NOW_EPOCH="$(date +%s)"
  if (( FIRST_FAILURE_EPOCH == 0 )) || (( NOW_EPOCH - FIRST_FAILURE_EPOCH >= WINDOW_SEC )); then
    FIRST_FAILURE_EPOCH="${NOW_EPOCH}"
    ATTEMPTS=0
  fi

  ATTEMPTS=$((ATTEMPTS + 1))
  write_state "${ATTEMPTS}" "${FIRST_FAILURE_EPOCH}"

  if [[ "${SINGLE_SHOT}" == "1" ]]; then
    exit 1
  fi
done
