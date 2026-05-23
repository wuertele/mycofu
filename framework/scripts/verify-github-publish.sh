#!/usr/bin/env bash
# verify-github-publish.sh — Verify GitHub publish configuration and materialization.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${VERIFY_GITHUB_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CONFIG_FILE="${VERIFY_GITHUB_CONFIG_FILE:-${REPO_DIR}/site/config.yaml}"
SECRETS_FILE="${VERIFY_GITHUB_SECRETS_FILE:-${REPO_DIR}/site/sops/secrets.yaml}"
SOPS_BIN="${VERIFY_GITHUB_SOPS_BIN:-sops}"
YQ_BIN="${VERIFY_GITHUB_YQ_BIN:-yq}"
JQ_BIN="${VERIFY_GITHUB_JQ_BIN:-jq}"
CURL_BIN="${VERIFY_GITHUB_CURL_BIN:-curl}"
SSH_BIN="${VERIFY_GITHUB_SSH_BIN:-ssh}"
SSH_KEYGEN_BIN="${VERIFY_GITHUB_SSH_KEYGEN_BIN:-ssh-keygen}"

source "${SCRIPT_DIR}/github-publish-lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") prod [--vault-only|--runner-only] [--write-smoke-branch <branch>]
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 1
fi

ENV="$1"
shift
if [[ "${ENV}" != "prod" ]]; then
  echo "ERROR: GitHub publishing verification is prod-only." >&2
  exit 1
fi

VAULT_ONLY=0
RUNNER_ONLY=0
SMOKE_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault-only)
      VAULT_ONLY=1
      shift
      ;;
    --runner-only)
      RUNNER_ONLY=1
      shift
      ;;
    --write-smoke-branch)
      SMOKE_BRANCH="${2:-}"
      [[ -n "${SMOKE_BRANCH}" ]] || { echo "ERROR: --write-smoke-branch requires a branch name" >&2; exit 1; }
      shift 2
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

if [[ "${VAULT_ONLY}" -eq 1 && "${RUNNER_ONLY}" -eq 1 ]]; then
  echo "ERROR: --vault-only and --runner-only are mutually exclusive." >&2
  exit 1
fi

PASS=0
FAIL=0
REMOTE_URL=""
SOPS_KEY=""
SOPS_FP=""

pass() {
  echo "[PASS] $*"
  PASS=$((PASS + 1))
}

fail() {
  echo "[FAIL] $*"
  FAIL=$((FAIL + 1))
}

read_sops_key() {
  local key="$1"
  "${SOPS_BIN}" -d --extract "[\"${key}\"]" "${SECRETS_FILE}" 2>/dev/null || true
}

fingerprint_from_value() {
  local key_value="$1"
  local tmp_key=""
  local tmp_pub=""
  tmp_key="$(mktemp "${TMPDIR:-/tmp}/verify-github-key.XXXXXX")"
  tmp_pub="$(mktemp "${TMPDIR:-/tmp}/verify-github-pub.XXXXXX")"
  printf '%s\n' "${key_value}" > "${tmp_key}"
  chmod 600 "${tmp_key}"
  "${SSH_KEYGEN_BIN}" -y -f "${tmp_key}" > "${tmp_pub}"
  "${SSH_KEYGEN_BIN}" -lf "${tmp_pub}" -E sha256 | awk '{print $2}'
  rm -f "${tmp_key}" "${tmp_pub}"
}

vault_api() {
  local method="$1"
  local path="$2"
  shift 2
  "${CURL_BIN}" -sk -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -X "${method}" "${VAULT_ADDR}/v1/${path}" "$@"
}

check_config() {
  REMOTE_URL="$("${YQ_BIN}" -r '.github.remote_url // ""' "${CONFIG_FILE}")"
  if [[ -n "${REMOTE_URL}" && "${REMOTE_URL}" != "null" ]] && github_remote_validate "${REMOTE_URL}"; then
    pass "config remote URL: ${REMOTE_URL}"
  else
    fail "config remote URL invalid or missing"
  fi
}

check_sops() {
  SOPS_KEY="$(read_sops_key github_deploy_key)"
  if [[ -z "${SOPS_KEY}" || "${SOPS_KEY}" == "null" ]]; then
    fail "SOPS github_deploy_key missing"
    return
  fi

  set +e
  SOPS_FP="$(fingerprint_from_value "${SOPS_KEY}")"
  local fp_exit=$?
  set -e
  if [[ "${fp_exit}" -eq 0 && -n "${SOPS_FP}" ]]; then
    pass "SOPS github_deploy_key present (${SOPS_FP})"
  else
    fail "SOPS github_deploy_key is not a usable private key"
  fi
}

check_vault() {
  local vault_value=""
  local vault_fp=""
  local vault_json=""

  VAULT_IP="$("${YQ_BIN}" -r '.vms.vault_prod.ip // ""' "${CONFIG_FILE}")"
  if [[ -z "${VAULT_IP}" || "${VAULT_IP}" == "null" ]]; then
    fail "Vault IP missing from config"
    return
  fi
  VAULT_ADDR="https://${VAULT_IP}:8200"
  ROOT_TOKEN="${VAULT_ROOT_TOKEN:-}"
  if [[ -z "${ROOT_TOKEN}" ]]; then
    ROOT_TOKEN="$(read_sops_key vault_prod_root_token)"
  fi
  if [[ -z "${ROOT_TOKEN}" || "${ROOT_TOKEN}" == "null" ]]; then
    fail "Vault root token missing from SOPS"
    return
  fi

  set +e
  vault_json="$(vault_api GET "secret/data/github/deploy-key" 2>&1)"
  local vault_exit=$?
  set -e
  if [[ "${vault_exit}" -ne 0 ]]; then
    fail "Vault secret/data/github/deploy-key read failed"
    return
  fi
  vault_value="$(printf '%s' "${vault_json}" | "${JQ_BIN}" -r '.data.data.value // ""' 2>/dev/null || true)"
  if [[ -z "${vault_value}" ]]; then
    fail "Vault secret/data/github/deploy-key missing"
    return
  fi
  vault_fp="$(fingerprint_from_value "${vault_value}")"
  if [[ -n "${SOPS_FP}" && "${vault_fp}" == "${SOPS_FP}" ]]; then
    pass "Vault secret/data/github/deploy-key fingerprint matches SOPS"
  else
    fail "Vault secret/data/github/deploy-key fingerprint mismatch"
  fi
}

runner_ssh() {
  "${SSH_BIN}" -n -o BatchMode=yes -o ConnectTimeout=5 "root@${CICD_IP}" "$@"
}

check_runner() {
  local runner_remote=""
  local ls_output=""
  local classifier=""

  CICD_IP="$("${YQ_BIN}" -r '.vms.cicd.ip // ""' "${CONFIG_FILE}")"
  if [[ -z "${CICD_IP}" || "${CICD_IP}" == "null" ]]; then
    fail "runner IP missing from config"
    return
  fi

  runner_remote="$(runner_ssh 'cat /run/secrets/github/remote-url 2>/dev/null || true' 2>/dev/null || true)"
  if [[ "${runner_remote}" == "${REMOTE_URL}" ]]; then
    pass "runner remote-url materialized"
  else
    fail "runner remote-url mismatch"
  fi

  if runner_ssh 'test -s /run/secrets/vault-agent/github-deploy-key' >/dev/null 2>&1; then
    pass "runner deploy key materialized"
  else
    fail "runner deploy key missing"
    return
  fi

  set +e
  ls_output="$(runner_ssh "GIT_SSH_COMMAND='ssh -i /run/secrets/vault-agent/github-deploy-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' git ls-remote '${REMOTE_URL}' refs/heads/main" 2>&1)"
  local ls_exit=$?
  set -e
  if [[ "${ls_exit}" -eq 0 ]]; then
    pass "runner git ls-remote"
  else
    classifier="$(github_publish_classify_git_error "${ls_output}")"
    fail "runner git ls-remote (${classifier})"
  fi
}

check_smoke_branch() {
  local branch="$1"
  local smoke_cmd=""
  local smoke_output=""

  smoke_cmd="$(cat <<EOF
set -euo pipefail
tmp=\$(mktemp -d)
trap 'rm -rf "\$tmp"' EXIT
cd "\$tmp"
git init >/dev/null
git config user.name 'Mycofu Publish Smoke'
git config user.email 'publish@mycofu.invalid'
git commit --allow-empty -m 'publish smoke branch' >/dev/null
git remote add github '${REMOTE_URL}'
export GIT_SSH_COMMAND='ssh -i /run/secrets/vault-agent/github-deploy-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new'
git push github HEAD:refs/heads/${branch} >/dev/null
git push github :refs/heads/${branch} >/dev/null
EOF
)"
  set +e
  smoke_output="$(runner_ssh "${smoke_cmd}" 2>&1)"
  local smoke_exit=$?
  set -e
  if [[ "${smoke_exit}" -eq 0 ]]; then
    pass "pushed refs/heads/${branch}"
    pass "deleted refs/heads/${branch}"
  else
    fail "smoke branch push/delete failed"
    printf '%s\n' "${smoke_output}" >&2
  fi
}

check_config
if [[ "${RUNNER_ONLY}" -eq 0 ]]; then
  check_sops
  check_vault
fi
if [[ "${VAULT_ONLY}" -eq 0 ]]; then
  check_runner
  if [[ -n "${SMOKE_BRANCH}" ]]; then
    check_smoke_branch "${SMOKE_BRANCH}"
  fi
fi

echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]

