#!/usr/bin/env bash
# check-cert-budget.sh — Preflight check for Let's Encrypt rate limits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"

source "${SCRIPT_DIR}/certbot-cluster.sh"

SSH_OPTS=(-n -q -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes)

IGNORE_BUDGET=0
NO_VAULT=0
ENV=""

usage() {
  cat >&2 <<'EOF'
Usage: check-cert-budget.sh [--ignore-cert-budget] [--no-vault] <prod|dev>
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ignore-cert-budget)
      IGNORE_BUDGET=1
      shift
      ;;
    --no-vault)
      NO_VAULT=1
      shift
      ;;
    prod|dev)
      ENV="$1"
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$ENV" ]]; then
  usage
  exit 2
fi

if [[ "$ENV" == "dev" ]]; then
  echo "cert-budget: dev environment uses Pebble — no rate limit check needed"
  exit 0
fi

if [[ "$IGNORE_BUDGET" -eq 1 ]]; then
  echo "cert-budget: WARNING — cert budget check skipped (--ignore-cert-budget)"
  exit 0
fi

for tool in yq ssh; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: ${tool}" >&2
    exit 1
  fi
done

RATE_LIMIT=5
WINDOW_HOURS=168
THRESHOLD=4
VAULT_COVERED=0
SUBJECT_TO_BUDGET=0
FAILURES=0
WARNINGS=0
CUTOFF_EPOCH="$(($(date +%s) - WINDOW_HOURS * 3600))"
STALE_THRESHOLD_EPOCH="$(($(date +%s) + 30 * 24 * 3600))"

iso_to_epoch() {
  local value="$1"
  if date -u -d "${value}" '+%s' >/dev/null 2>&1; then
    date -u -d "${value}" '+%s'
    return 0
  fi

  date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "${value}" '+%s'
}

VAULT_ROOT_TOKEN_VALUE=""
VAULT_ADDR=""
if [[ "$NO_VAULT" -eq 0 ]]; then
  for tool in sops jq curl yq ssh; do
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

  if [[ -n "${VAULT_ROOT_TOKEN:-}" ]]; then
    VAULT_ROOT_TOKEN_VALUE="${VAULT_ROOT_TOKEN}"
  else
    VAULT_ROOT_TOKEN_VALUE="$(sops -d --extract "[\"vault_${ENV}_root_token\"]" "${SECRETS_FILE}")"
  fi

  VAULT_IP="$(yq -r ".vms.vault_${ENV}.ip" "${CONFIG_FILE}")"
  if [[ -z "${VAULT_IP}" || "${VAULT_IP}" == "null" ]]; then
    echo "ERROR: No vault_${ENV} IP found in config.yaml" >&2
    exit 1
  fi
  VAULT_ADDR="https://${VAULT_IP}:8200"
fi

vault_lookup_not_after() {
  local fqdn="$1"
  local response=""

  if [[ "$NO_VAULT" -eq 1 ]]; then
    return 1
  fi

  response="$(
    curl -sk \
      -H "X-Vault-Token: ${VAULT_ROOT_TOKEN_VALUE}" \
      "${VAULT_ADDR}/v1/mycofu/metadata/certs/${fqdn}" \
      2>/dev/null || true
  )"
  [[ -n "${response}" ]] || return 1

  printf '%s' "${response}" | jq -r '.data.custom_metadata.not_after // empty' 2>/dev/null
}

echo "cert-budget: checking prod FQDNs against LE rate limit (${RATE_LIMIT}/${WINDOW_HOURS}h)"

while IFS=$'\t' read -r vm_label module_name ip_addr vmid fqdn kind; do
  [[ -z "${fqdn}" ]] && continue

  if [[ "$NO_VAULT" -eq 0 ]]; then
    not_after="$(vault_lookup_not_after "${fqdn}" || true)"
    if [[ -n "${not_after}" ]]; then
      expiry_epoch="$(iso_to_epoch "${not_after}" 2>/dev/null || echo 0)"
      if [[ "${expiry_epoch}" -gt "${STALE_THRESHOLD_EPOCH}" ]]; then
        echo "  ${fqdn}: covered by Vault (not_after=${not_after})"
        VAULT_COVERED=$((VAULT_COVERED + 1))
        continue
      fi

      if [[ "${expiry_epoch}" -gt 0 ]]; then
        echo "  ${fqdn}: Vault entry is stale (not_after=${not_after}) — checking LE budget"
      else
        echo "  ${fqdn}: Vault entry unreadable — checking LE budget"
      fi
    fi
  fi

  SUBJECT_TO_BUDGET=$((SUBJECT_TO_BUDGET + 1))

  set +e
  count="$(
    ssh "${SSH_OPTS[@]}" "root@${ip_addr}" "
      ARCHIVE_DIR=/etc/letsencrypt/archive/${fqdn}
      if [ ! -d \"\$ARCHIVE_DIR\" ]; then
        echo 0
        exit 0
      fi
      COUNT=0
      for cert in \"\$ARCHIVE_DIR\"/cert*.pem; do
        [ -f \"\$cert\" ] || continue
        [ -s \"\$cert\" ] || continue
        MTIME=\$(stat -c %Y \"\$cert\" 2>/dev/null || echo 0)
        if [ \"\$MTIME\" -ge ${CUTOFF_EPOCH} ]; then
          COUNT=\$((COUNT + 1))
        fi
      done
      echo \$COUNT
    " 2>/dev/null
  )"
  rc=$?
  set -e

  if [[ $rc -ne 0 || -z "${count}" || ! "${count}" =~ ^[0-9]+$ ]]; then
    echo "  ${fqdn}: UNREACHABLE (${ip_addr}) — cannot verify cert budget"
    echo "    WARNING: If this VM was recently recreated, prior cert requests still count against the LE rate limit."
    WARNINGS=$((WARNINGS + 1))
    continue
  fi

  if [[ "${count}" -ge "${RATE_LIMIT}" ]]; then
    echo "  ${fqdn}: ${count}/${RATE_LIMIT} certificates issued in last ${WINDOW_HOURS}h — RATE LIMIT EXHAUSTED"
    FAILURES=$((FAILURES + 1))
  elif [[ "${count}" -ge "${THRESHOLD}" ]]; then
    echo "  ${fqdn}: ${count}/${RATE_LIMIT} certificates issued in last ${WINDOW_HOURS}h — WARNING: approaching limit"
    WARNINGS=$((WARNINGS + 1))
  else
    echo "  ${fqdn}: ${count}/${RATE_LIMIT} — OK"
  fi
done < <(certbot_cluster_cert_storage_records "${CONFIG_FILE}" "${APPS_CONFIG}" "${ENV}")

echo ""
echo "cert-budget: ${VAULT_COVERED} FQDNs covered by Vault; ${SUBJECT_TO_BUDGET} subject to LE budget"

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "cert-budget: FAILED — ${FAILURES} FQDN(s) at or over rate limit"
  exit 1
fi

if [[ "${WARNINGS}" -gt 0 ]]; then
  echo "cert-budget: PASSED with warnings — ${WARNINGS} FQDN(s) require operator review"
  exit 0
fi

echo "cert-budget: PASS"
