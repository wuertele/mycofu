#!/usr/bin/env bash
# seed-github-deploy-key.sh — Seed the GitHub publish deploy key into SOPS and Vault.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SEED_GITHUB_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CONFIG_FILE="${SEED_GITHUB_CONFIG_FILE:-${REPO_DIR}/site/config.yaml}"
SECRETS_FILE="${SEED_GITHUB_SECRETS_FILE:-${REPO_DIR}/site/sops/secrets.yaml}"
SOPS_BIN="${SEED_GITHUB_SOPS_BIN:-sops}"
YQ_BIN="${SEED_GITHUB_YQ_BIN:-yq}"
JQ_BIN="${SEED_GITHUB_JQ_BIN:-jq}"
CURL_BIN="${SEED_GITHUB_CURL_BIN:-curl}"
GIT_BIN="${SEED_GITHUB_GIT_BIN:-git}"
SSH_KEYGEN_BIN="${SEED_GITHUB_SSH_KEYGEN_BIN:-ssh-keygen}"
SSH_BIN="${SEED_GITHUB_SSH_BIN:-ssh}"

source "${SCRIPT_DIR}/github-publish-lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") prod --key-file <path> [--rotate] [--shred-source] [--dry-run]

Seeds the prod-only GitHub publish deploy key into SOPS and Vault.
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

ENV="$1"
shift
if [[ "${ENV}" != "prod" ]]; then
  echo "ERROR: GitHub publishing is prod-only; run this script with 'prod'." >&2
  exit 1
fi

KEY_FILE=""
ROTATE=0
SHRED_SOURCE=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key-file)
      KEY_FILE="${2:-}"
      [[ -n "${KEY_FILE}" ]] || { echo "ERROR: --key-file requires a path" >&2; exit 1; }
      shift 2
      ;;
    --rotate)
      ROTATE=1
      shift
      ;;
    --shred-source)
      SHRED_SOURCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -n "${KEY_FILE}" ]] || { echo "ERROR: --key-file is required" >&2; exit 1; }
[[ -s "${KEY_FILE}" ]] || { echo "ERROR: key file not found or empty: ${KEY_FILE}" >&2; exit 1; }

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

key_fingerprint_from_file() {
  local private_key_file="$1"
  local public_key_file=""
  public_key_file="$(mktemp "${TMPDIR:-/tmp}/github-key-public.XXXXXX")"
  if ! "${SSH_KEYGEN_BIN}" -y -f "${private_key_file}" > "${public_key_file}"; then
    rm -f "${public_key_file}"
    return 1
  fi
  if ! "${SSH_KEYGEN_BIN}" -lf "${public_key_file}" -E sha256 | awk '{print $2}'; then
    rm -f "${public_key_file}"
    return 1
  fi
  rm -f "${public_key_file}"
}

key_fingerprint_from_value() {
  local key_value="$1"
  local tmp_key=""
  tmp_key="$(mktemp "${TMPDIR:-/tmp}/github-key.XXXXXX")"
  printf '%s\n' "${key_value}" > "${tmp_key}"
  chmod 600 "${tmp_key}"
  key_fingerprint_from_file "${tmp_key}"
  rm -f "${tmp_key}"
}

vault_api() {
  local method="$1"
  local path="$2"
  local response=""
  local curl_exit=0
  shift 2

  set +e
  response="$("${CURL_BIN}" -fSsk -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -X "${method}" "${VAULT_ADDR}/v1/${path}" "$@" 2>&1)"
  curl_exit=$?
  set -e
  if [[ "${curl_exit}" -ne 0 ]]; then
    printf '%s\n' "${response}" >&2
    return "${curl_exit}"
  fi
  if printf '%s' "${response}" | "${JQ_BIN}" -e '((.errors // []) | length) > 0' >/dev/null 2>&1; then
    echo "ERROR: Vault API ${method} ${path} returned errors:" >&2
    printf '%s\n' "${response}" >&2
    return 1
  fi
  printf '%s\n' "${response}"
}

read_sops_key() {
  local key="$1"
  "${SOPS_BIN}" -d --extract "[\"${key}\"]" "${SECRETS_FILE}" 2>/dev/null || true
}

set_sops_key() {
  local key="$1"
  local value="$2"
  local value_json=""
  value_json="$(printf '%s' "${value}" | "${JQ_BIN}" -Rs .)"
  "${SOPS_BIN}" --set "[\"${key}\"] ${value_json}" "${SECRETS_FILE}"
}

MODE="$(file_mode "${KEY_FILE}")"
MODE_DEC=$((8#${MODE}))
if (( (MODE_DEC & 8#077) != 0 )); then
  echo "ERROR: key file permissions are too broad (${MODE}); run: chmod 600 ${KEY_FILE}" >&2
  exit 1
fi

KEY_VALUE="$(cat "${KEY_FILE}")"
if ! KEY_FINGERPRINT="$(key_fingerprint_from_file "${KEY_FILE}")"; then
  echo "ERROR: invalid or unreadable SSH private key: ${KEY_FILE}" >&2
  exit 1
fi

REMOTE_URL="$("${YQ_BIN}" -r '.github.remote_url // ""' "${CONFIG_FILE}")"
if [[ -z "${REMOTE_URL}" || "${REMOTE_URL}" == "null" ]]; then
  echo "ERROR: github.remote_url is missing from ${CONFIG_FILE}" >&2
  exit 1
fi
if ! github_remote_validate "${REMOTE_URL}"; then
  echo "ERROR: github.remote_url must be git@github.com:<owner>/<repo>.git: ${REMOTE_URL}" >&2
  exit 1
fi

echo "Remote URL: ${REMOTE_URL}"
echo "Public key fingerprint: ${KEY_FINGERPRINT}"

EXISTING_SOPS_KEY="$(read_sops_key github_deploy_key)"
SOPS_ACTION="written"
if [[ -n "${EXISTING_SOPS_KEY}" && "${EXISTING_SOPS_KEY}" != "null" ]]; then
  EXISTING_FINGERPRINT="$(key_fingerprint_from_value "${EXISTING_SOPS_KEY}")"
  if [[ "${EXISTING_FINGERPRINT}" == "${KEY_FINGERPRINT}" ]]; then
    SOPS_ACTION="already present with matching fingerprint"
  elif [[ "${ROTATE}" -eq 1 ]]; then
    SOPS_ACTION="rotated"
  else
    echo "ERROR: SOPS github_deploy_key already exists with a different fingerprint; rerun with --rotate to replace it." >&2
    exit 1
  fi
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "SOPS github_deploy_key: would be ${SOPS_ACTION}"
else
  if [[ "${SOPS_ACTION}" == "written" || "${SOPS_ACTION}" == "rotated" ]]; then
    set_sops_key github_deploy_key "${KEY_VALUE}"
  fi
  echo "SOPS github_deploy_key: ${SOPS_ACTION}"
fi

SOPS_VALUE="${KEY_VALUE}"
if [[ "${DRY_RUN}" -eq 0 ]]; then
  SOPS_VALUE="$(read_sops_key github_deploy_key)"
fi

VAULT_IP="$("${YQ_BIN}" -r '.vms.vault_prod.ip // ""' "${CONFIG_FILE}")"
if [[ -z "${VAULT_IP}" || "${VAULT_IP}" == "null" ]]; then
  echo "ERROR: vms.vault_prod.ip is missing from ${CONFIG_FILE}" >&2
  exit 1
fi
VAULT_ADDR="https://${VAULT_IP}:8200"
ROOT_TOKEN="${VAULT_ROOT_TOKEN:-}"
if [[ -z "${ROOT_TOKEN}" ]]; then
  ROOT_TOKEN="$(read_sops_key vault_prod_root_token)"
fi
if [[ -z "${ROOT_TOKEN}" || "${ROOT_TOKEN}" == "null" ]]; then
  echo "ERROR: vault_prod_root_token is missing from SOPS; cannot write Vault." >&2
  exit 1
fi

VAULT_ACTION="written"
set +e
VAULT_EXISTING_JSON="$(vault_api GET "secret/data/github/deploy-key" 2>/dev/null)"
VAULT_EXISTING_EXIT=$?
set -e
if [[ "${VAULT_EXISTING_EXIT}" -eq 0 ]]; then
  VAULT_EXISTING_VALUE="$(printf '%s' "${VAULT_EXISTING_JSON}" | "${JQ_BIN}" -r '.data.data.value // ""' 2>/dev/null || true)"
  if [[ -n "${VAULT_EXISTING_VALUE}" && "${VAULT_EXISTING_VALUE}" == "${SOPS_VALUE}" ]]; then
    VAULT_ACTION="already current"
  fi
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "Vault secret/data/github/deploy-key: would be ${VAULT_ACTION}"
else
  if [[ "${VAULT_ACTION}" != "already current" ]]; then
    vault_api POST "secret/data/github/deploy-key" \
      -d "$("${JQ_BIN}" -n --arg value "${SOPS_VALUE}" '{data: {value: $value}}')" >/dev/null
  fi
  echo "Vault secret/data/github/deploy-key: ${VAULT_ACTION}"
fi

TMP_KEY="$(mktemp "${TMPDIR:-/tmp}/github-deploy-key.XXXXXX")"
printf '%s\n' "${SOPS_VALUE}" > "${TMP_KEY}"
chmod 600 "${TMP_KEY}"
set +e
LS_REMOTE_OUTPUT="$(GIT_SSH_COMMAND="${SSH_BIN} -i ${TMP_KEY} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" \
  "${GIT_BIN}" ls-remote "${REMOTE_URL}" refs/heads/main 2>&1)"
LS_REMOTE_EXIT=$?
set -e
rm -f "${TMP_KEY}"
if [[ "${LS_REMOTE_EXIT}" -ne 0 ]]; then
  echo "GitHub ls-remote: FAIL" >&2
  printf '%s\n' "${LS_REMOTE_OUTPUT}" >&2
  exit 1
fi
echo "GitHub ls-remote: PASS"

shred_file() {
  local path="$1"
  [[ -e "${path}" ]] || return 0
  if command -v shred >/dev/null 2>&1; then
    shred -u "${path}"
  elif rm -P "${path}" >/dev/null 2>&1; then
    :
  else
    rm -f "${path}"
  fi
}

if [[ "${SHRED_SOURCE}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
  shred_file "${KEY_FILE}"
  shred_file "${KEY_FILE}.pub"
  echo "Source key shredded"
fi
