#!/usr/bin/env bash
# cert-storage-backfill.sh — Seed existing live certs into Vault KV.

set -euo pipefail

find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
Usage: cert-storage-backfill.sh <prod|dev>
EOF
}

REPO_DIR="$(find_repo_root)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"

if [[ $# -ne 1 || ( "$1" != "prod" && "$1" != "dev" ) ]]; then
  usage
  exit 2
fi
ENV="$1"

for tool in sops yq jq curl ssh openssl; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: ${tool}" >&2
    exit 1
  fi
done

if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
  elif [[ -f "${REPO_DIR}/operator.age.key.production" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key.production"
  fi
fi

source "${REPO_DIR}/framework/scripts/certbot-cluster.sh"

SSH_OPTS=(-n -q -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)

# Number of days of remaining validity below which a stored Vault cert entry
# is treated as stale and refreshed from disk. This must stay aligned with
# certbot's renewal window and cert-restore.service's staleness threshold.
# If these diverge, backfill, restore, and renewal can disagree about whether
# a cert is current. Follow-up issue: "Promote cert staleness threshold to a
# single source of truth".
STALE_THRESHOLD_DAYS=30

# Maximum seconds to wait for live PEM files after fresh VM recreation.
: "${CERT_BACKFILL_WAIT_SECONDS:=300}"
: "${CERT_BACKFILL_WAIT_INTERVAL_SECONDS:=5}"

to_iso8601_utc() {
  local value="$1"
  if date -u -d "${value}" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
    date -u -d "${value}" '+%Y-%m-%dT%H:%M:%SZ'
    return 0
  fi

  date -u -j -f '%b %e %T %Y %Z' "${value}" '+%Y-%m-%dT%H:%M:%SZ'
}

date_to_epoch_utc() {
  local value="$1"
  if date -u -d "${value}" '+%s' >/dev/null 2>&1; then
    date -u -d "${value}" '+%s'
    return 0
  fi

  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${value}" '+%s'
}

validity_days_remaining() {
  local not_after="$1"
  local not_after_epoch
  local now_epoch

  not_after_epoch="$(date_to_epoch_utc "${not_after}")"
  now_epoch="$(date -u '+%s')"

  printf '%s\n' "$(( (not_after_epoch - now_epoch) / 86400 ))"
}

ssh_with_wait() {
  local ip_addr="$1"
  local remote_cmd="$2"
  local deadline_epoch="$3"
  local output=""
  local rc=0
  local now_epoch=0
  local remaining=0
  local sleep_seconds=0

  while true; do
    set +e
    output="$(ssh "${SSH_OPTS[@]}" "root@${ip_addr}" "${remote_cmd}" 2>/dev/null)"
    rc=$?
    set -e

    if [[ ${rc} -eq 0 && -n "${output}" ]]; then
      printf '%s' "${output}"
      return 0
    fi

    now_epoch="$(date -u '+%s')"
    if (( now_epoch >= deadline_epoch )); then
      return 1
    fi

    remaining=$((deadline_epoch - now_epoch))
    sleep_seconds="${CERT_BACKFILL_WAIT_INTERVAL_SECONDS}"
    if (( sleep_seconds <= 0 )); then
      sleep_seconds=1
    fi
    if (( sleep_seconds > remaining )); then
      sleep_seconds="${remaining}"
    fi
    sleep "${sleep_seconds}"
  done
}

if [[ -n "${VAULT_ROOT_TOKEN:-}" ]]; then
  ROOT_TOKEN="${VAULT_ROOT_TOKEN}"
else
  ROOT_TOKEN="$(sops -d --extract "[\"vault_${ENV}_root_token\"]" "${SECRETS_FILE}")"
fi

VAULT_IP="$(yq -r ".vms.vault_${ENV}.ip" "${CONFIG}")"
if [[ -z "${VAULT_IP}" || "${VAULT_IP}" == "null" ]]; then
  echo "ERROR: No vault_${ENV} IP found in config.yaml" >&2
  exit 1
fi
VAULT_ADDR="https://${VAULT_IP}:8200"

vault_api() {
  local method="$1"
  local path="$2"
  shift 2
  curl -sk -H "X-Vault-Token: ${ROOT_TOKEN}" -X "${method}" "${VAULT_ADDR}/v1/${path}" "$@"
}

FAILURES=0
SEEDED=0
SKIPPED=0

while IFS=$'\t' read -r vm_label module_name ip_addr vmid fqdn kind; do
  [[ -z "${vm_label}" ]] && continue

  echo "backfill: checking ${fqdn} from ${vm_label} (${ip_addr})"

  # Share one PEM wait deadline across the lineage so partial lineages cannot
  # stall once per cert.pem/fullchain.pem/privkey.pem/chain.pem read.
  fqdn_deadline_epoch="$(($(date -u '+%s') + CERT_BACKFILL_WAIT_SECONDS))"

  set +e
  cert="$(ssh_with_wait "${ip_addr}" "cat /etc/letsencrypt/live/${fqdn}/cert.pem" "${fqdn_deadline_epoch}")"
  rc_cert=$?
  set -e

  if [[ ${rc_cert} -ne 0 ]]; then
    echo "  ERROR: timed out waiting for cert.pem for ${fqdn} (${ip_addr})" >&2
    echo "  Fallback: restore cert-bearing VM state with restore-from-pbs.sh if SSH remains unavailable." >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  tmp_cert="$(mktemp)"
  printf '%s' "${cert}" > "${tmp_cert}"

  enddate="$(openssl x509 -in "${tmp_cert}" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')" || true
  fingerprint="$(
    openssl x509 -in "${tmp_cert}" -noout -fingerprint -sha256 2>/dev/null \
      | sed 's/^.*=//' \
      | tr -d ':' \
      | tr '[:upper:]' '[:lower:]'
  )" || true
  rm -f "${tmp_cert}"

  if [[ -z "${enddate}" || -z "${fingerprint}" ]]; then
    echo "  ERROR: could not derive metadata for ${fqdn}" >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  not_after="$(to_iso8601_utc "${enddate}")"

  vault_metadata_resp="$(vault_api GET "mycofu/metadata/certs/${fqdn}" 2>/dev/null || true)"
  stored_fingerprint="$(printf '%s' "${vault_metadata_resp}" | jq -r '.data.custom_metadata.fingerprint // empty' 2>/dev/null || true)"
  stored_not_after="$(printf '%s' "${vault_metadata_resp}" | jq -r '.data.custom_metadata.not_after // empty' 2>/dev/null || true)"
  if [[ -n "${stored_fingerprint}" && -n "${stored_not_after}" ]]; then
    remaining_days="$(validity_days_remaining "${stored_not_after}" 2>/dev/null || printf '0\n')"
    if [[ "${stored_fingerprint}" == "${fingerprint}" ]] && (( remaining_days > STALE_THRESHOLD_DAYS )); then
      echo "  OK: ${fqdn} already current in Vault, skipping"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi
  fi

  set +e
  fullchain="$(ssh_with_wait "${ip_addr}" "cat /etc/letsencrypt/live/${fqdn}/fullchain.pem" "${fqdn_deadline_epoch}")"
  rc_fullchain=$?
  set -e
  if [[ ${rc_fullchain} -ne 0 ]]; then
    echo "  ERROR: SSH read failed for ${fqdn} (${ip_addr})" >&2
    echo "  Fallback: restore cert-bearing VM state with restore-from-pbs.sh if SSH remains unavailable." >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  set +e
  privkey="$(ssh_with_wait "${ip_addr}" "cat /etc/letsencrypt/live/${fqdn}/privkey.pem" "${fqdn_deadline_epoch}")"
  rc_privkey=$?
  set -e
  if [[ ${rc_privkey} -ne 0 ]]; then
    echo "  ERROR: SSH read failed for ${fqdn} (${ip_addr})" >&2
    echo "  Fallback: restore cert-bearing VM state with restore-from-pbs.sh if SSH remains unavailable." >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  set +e
  chain="$(ssh_with_wait "${ip_addr}" "cat /etc/letsencrypt/live/${fqdn}/chain.pem" "${fqdn_deadline_epoch}")"
  rc_chain=$?
  set -e
  if [[ ${rc_chain} -ne 0 ]]; then
    echo "  ERROR: SSH read failed for ${fqdn} (${ip_addr})" >&2
    echo "  Fallback: restore cert-bearing VM state with restore-from-pbs.sh if SSH remains unavailable." >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  issued_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

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

  write_code="$(
    curl -sk -o /dev/null -w '%{http_code}' \
      -H "X-Vault-Token: ${ROOT_TOKEN}" \
      -H 'Content-Type: application/json' \
      -X POST \
      -d "${payload}" \
      "${VAULT_ADDR}/v1/mycofu/data/certs/${fqdn}" 2>/dev/null || true
  )"
  if [[ ! "${write_code}" =~ ^2[0-9][0-9]$ ]]; then
    echo "  ERROR: Vault data write failed for ${fqdn} (data=${write_code:-curl-error})" >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  metadata_code="$(
    curl -sk -o /dev/null -w '%{http_code}' \
      -H "X-Vault-Token: ${ROOT_TOKEN}" \
      -H 'Content-Type: application/json' \
      -X POST \
      -d "${metadata_payload}" \
      "${VAULT_ADDR}/v1/mycofu/metadata/certs/${fqdn}" 2>/dev/null || true
  )"
  if [[ ! "${metadata_code}" =~ ^2[0-9][0-9]$ ]]; then
    echo "  ERROR: Vault metadata write failed for ${fqdn} (metadata=${metadata_code:-curl-error})" >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  verify_json="$(vault_api GET "mycofu/metadata/certs/${fqdn}" 2>/dev/null || true)"
  stored_fingerprint="$(printf '%s' "${verify_json}" | jq -r '.data.custom_metadata.fingerprint // empty' 2>/dev/null || true)"
  if [[ "${stored_fingerprint}" != "${fingerprint}" ]]; then
    echo "  ERROR: verification failed for ${fqdn} (stored fingerprint mismatch)" >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  echo "  OK: ${fqdn} stored in Vault"
  SEEDED=$((SEEDED + 1))
done < <(certbot_cluster_cert_storage_records "${CONFIG}" "${APPS_CONFIG}" "${ENV}")

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "backfill: FAILED - seeded ${SEEDED}, skipped ${SKIPPED}, failures ${FAILURES}" >&2
  exit 1
fi

echo "backfill: PASS - seeded ${SEEDED}, skipped ${SKIPPED}, failures ${FAILURES}"
