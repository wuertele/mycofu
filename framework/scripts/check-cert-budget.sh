#!/usr/bin/env bash
# check-cert-budget.sh — Preflight check for Let's Encrypt rate limits.
#
# The authoritative oracle is Vault metadata at
# `mycofu/metadata/certs/<fqdn>`. Every fresh cert observed by
# `cert-storage-backfill.sh` or written by the `cert-sync` deploy
# hook produces a new versioned KV write — so the count of versions
# created within the LE 168-hour rate-limit window approximates the
# number of LE issuances against this FQDN. Versions outside the
# window do not count against the duplicate-cert quota and are
# excluded.
#
# This replaces the prior file-count oracle (cert*.pem files on the
# running VM) which gave false-OK reports on freshly recreated VMs
# whose /etc/letsencrypt/ was empty even when LE quota for the FQDN
# was exhausted. See incident report
# docs/reports/le-rate-limit-incident-2026-05-01.md (Layer 3) and
# Issue #303.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"

source "${SCRIPT_DIR}/certbot-cluster.sh"

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

# --no-vault is now a synonym for --ignore-cert-budget. The oracle is
# Vault, so opting out of Vault means opting out of the budget check.
# Any caller that previously relied on the SSH file-count fallthrough
# is now opting into a deploy with no rate-limit verification, which
# is acceptable as an explicit operator-opt-out (matches the
# --ignore-cert-budget semantics).
if [[ "$NO_VAULT" -eq 1 ]]; then
  echo "cert-budget: WARNING — cert budget check skipped (--no-vault); the oracle is Vault and was bypassed at operator request"
  exit 0
fi

for tool in sops jq curl yq; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: ${tool}" >&2
    exit 1
  fi
done

RATE_LIMIT=5
WINDOW_HOURS=168
THRESHOLD=4
SUBJECT_TO_BUDGET=0
FAILURES=0

if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
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

# Fetch Vault metadata for an FQDN.
#
# Sets:
#   VAULT_METADATA_BODY   — JSON body (may be empty on transport error)
#   VAULT_METADATA_STATUS — one of: "ok" (200), "missing" (404), "error" (other)
#
# "ok" means the response contained valid metadata for the FQDN.
# "missing" means Vault returned 404 — FQDN has no entry yet.
# "error" covers Vault unreachable, auth failure (403), or any other
# non-2xx response. The caller decides how to interpret each.
vault_get_metadata() {
  local fqdn="$1"
  local body_file http_code
  body_file="$(mktemp)"
  http_code="$(
    curl -sk \
      --connect-timeout 10 \
      --max-time 20 \
      -o "${body_file}" \
      -w '%{http_code}' \
      -H "X-Vault-Token: ${VAULT_ROOT_TOKEN_VALUE}" \
      "${VAULT_ADDR}/v1/mycofu/metadata/certs/${fqdn}" \
      2>/dev/null || true
  )"
  VAULT_METADATA_BODY="$(cat "${body_file}" 2>/dev/null || true)"
  rm -f "${body_file}"

  case "${http_code}" in
    200)
      # 200 with no .data is treated as error (unexpected shape).
      if printf '%s' "${VAULT_METADATA_BODY}" | jq -e '.data.versions' >/dev/null 2>&1; then
        VAULT_METADATA_STATUS="ok"
      else
        VAULT_METADATA_STATUS="error"
      fi
      ;;
    404)
      VAULT_METADATA_STATUS="missing"
      ;;
    *)
      VAULT_METADATA_STATUS="error"
      ;;
  esac
}

# Extract not_after from a metadata response body.
extract_not_after() {
  local body="$1"
  printf '%s' "${body}" | jq -r '.data.custom_metadata.not_after // empty' 2>/dev/null
}

# Count versions whose created_time falls within the LE rate-limit
# window (last WINDOW_HOURS hours). Deleted/destroyed versions are
# included — the LE issuance happened regardless of whether Vault
# still has the data.
#
# Vault emits created_time in Go's time.RFC3339Nano format with
# nanosecond precision (e.g., "2026-05-01T12:34:56.123456789Z"). jq's
# `fromdate` rejects fractional seconds, so we strip them before
# parsing. Any version with a missing or unparseable created_time is
# counted (fail-closed: an unknown timestamp could be inside the
# window, so we treat it as if it were).
versions_in_window() {
  local body="$1"
  local window_seconds="$((WINDOW_HOURS * 3600))"
  printf '%s' "${body}" \
    | jq --argjson window "${window_seconds}" \
        '[.data.versions
            | to_entries[]
            | (
                if .value.created_time == null or .value.created_time == ""
                then null
                else .value.created_time
                  | sub("\\.[0-9]+Z$"; "Z")
                  | try fromdate catch null
                end
              ) as $ts
            | select($ts == null or $ts > (now - $window))
         ] | length' \
        2>/dev/null
}

echo "cert-budget: checking prod FQDNs against LE rate limit (${RATE_LIMIT}/${WINDOW_HOURS}h)"

while IFS=$'\t' read -r vm_label module_name ip_addr vmid fqdn kind; do
  [[ -z "${fqdn}" ]] && continue

  vault_get_metadata "${fqdn}"

  case "${VAULT_METADATA_STATUS}" in
    error)
      echo "  ${fqdn}: Vault unreachable or returned error — failing closed"
      FAILURES=$((FAILURES + 1))
      continue
      ;;
    missing)
      echo "  ${fqdn}: Vault has no entry for this FQDN — failing closed"
      echo "    The framework cannot determine prior LE issuance count without a Vault entry."
      echo "    If this FQDN is genuinely new (never issued), run cert-storage-backfill.sh after first issuance,"
      echo "    or pass --ignore-cert-budget to skip this check explicitly."
      FAILURES=$((FAILURES + 1))
      continue
      ;;
    ok)
      ;;
  esac

  # The version count is the authoritative budget. We do NOT skip the
  # check based on a fresh not_after — the issue's acceptance criteria
  # require failing at 4 or 5 versions in window regardless of cert
  # freshness. A fresh cert in Vault means cert-restore will likely
  # succeed and avoid an LE call, but if anything in the deploy path
  # forces an LE call (cert-restore failure, key rotation, manual
  # renewal), the rate limit applies. The 1-slot headroom protects that
  # case.
  not_after="$(extract_not_after "${VAULT_METADATA_BODY}")"
  if [[ -n "${not_after}" ]]; then
    echo "  ${fqdn}: Vault not_after=${not_after} — checking LE budget against Vault version count"
  else
    echo "  ${fqdn}: Vault entry has no not_after — checking LE budget against Vault version count"
  fi

  SUBJECT_TO_BUDGET=$((SUBJECT_TO_BUDGET + 1))

  count="$(versions_in_window "${VAULT_METADATA_BODY}" 2>/dev/null || true)"
  if [[ -z "${count}" || ! "${count}" =~ ^[0-9]+$ ]]; then
    echo "  ${fqdn}: could not parse Vault metadata version timestamps — failing closed"
    FAILURES=$((FAILURES + 1))
    continue
  fi

  if [[ "${count}" -ge "${THRESHOLD}" ]]; then
    if [[ "${count}" -ge "${RATE_LIMIT}" ]]; then
      echo "  ${fqdn}: ${count}/${RATE_LIMIT} Vault versions in last ${WINDOW_HOURS}h — RATE LIMIT EXHAUSTED"
    else
      echo "  ${fqdn}: ${count}/${RATE_LIMIT} Vault versions in last ${WINDOW_HOURS}h — FAILED (no headroom for emergency issuance)"
    fi
    FAILURES=$((FAILURES + 1))
  else
    echo "  ${fqdn}: ${count}/${RATE_LIMIT} Vault versions in last ${WINDOW_HOURS}h — OK"
  fi
done < <(certbot_cluster_cert_storage_records "${CONFIG_FILE}" "${APPS_CONFIG}" "${ENV}")

echo ""
echo "cert-budget: ${SUBJECT_TO_BUDGET} FQDN(s) checked against LE budget"

if [[ "${FAILURES}" -gt 0 ]]; then
  echo "cert-budget: FAILED — ${FAILURES} FQDN(s) at or over rate limit, or unable to verify"
  exit 1
fi

echo "cert-budget: PASS"
