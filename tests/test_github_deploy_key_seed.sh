#!/usr/bin/env bash
# test_github_deploy_key_seed.sh — Verify GitHub deploy key seeding semantics.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REAL_YQ="$(command -v yq)"
REAL_JQ="$(command -v jq)"
REAL_SSH_KEYGEN="$(command -v ssh-keygen)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TEMP_PATHS=()

cleanup() {
  set +u
  local path=""
  for path in "${TEMP_PATHS[@]}"; do
    rm -rf "${path}"
  done
}
trap cleanup EXIT

make_temp_dir() {
  local target_var="$1"
  local path
  path="$(mktemp -d "${TMPDIR:-/tmp}/github-seed-test.XXXXXX")"
  TEMP_PATHS+=("${path}")
  printf -v "${target_var}" '%s' "${path}"
}

make_config() {
  local path="$1"
  cat > "${path}" <<'EOF'
github:
  remote_url: git@github.com:example/mycofu.git
vms:
  vault_prod:
    ip: 127.0.0.1
EOF
}

make_key() {
  local path="$1"
  "${REAL_SSH_KEYGEN}" -t ed25519 -f "${path}" -N "" -C "seed-test" >/dev/null
  chmod 600 "${path}"
}

same_private_key() {
  local left="$1"
  local right="$2"
  local left_tmp=""
  local right_tmp=""
  [[ -s "${left}" && -s "${right}" ]] || return 1
  left_tmp="$(mktemp "${TMPDIR:-/tmp}/seed-key-left.XXXXXX")"
  right_tmp="$(mktemp "${TMPDIR:-/tmp}/seed-key-right.XXXXXX")"
  cat "${left}" > "${left_tmp}"
  cat "${right}" > "${right_tmp}"
  printf '\n' >> "${left_tmp}"
  printf '\n' >> "${right_tmp}"
  chmod 600 "${left_tmp}" "${right_tmp}"
  diff -q <("${REAL_SSH_KEYGEN}" -y -f "${left_tmp}") <("${REAL_SSH_KEYGEN}" -y -f "${right_tmp}") >/dev/null
  local rc=$?
  rm -f "${left_tmp}" "${right_tmp}"
  return "${rc}"
}

create_fake_sops() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_SOPS_STATE_DIR:?}"

extract_key() {
  sed -n 's/.*\["\([^"]*\)"\].*/\1/p' <<< "$1"
}

if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" ]]; then
  key="$(extract_key "$3")"
  case "${key}" in
    vault_prod_root_token)
      printf 'root-token\n'
      exit 0
      ;;
    github_deploy_key)
      if [[ -f "${state}/github_deploy_key" ]]; then
        cat "${state}/github_deploy_key"
        exit 0
      fi
      exit 1
      ;;
    *)
      exit 1
      ;;
  esac
fi

if [[ "${1:-}" == "--set" ]]; then
  key="$(extract_key "$2")"
  json="${2#*] }"
  mkdir -p "${state}"
  printf '%s' "${json}" | jq -r -j . > "${state}/${key}"
  chmod 600 "${state}/${key}"
  count_file="${state}/sops-set-count"
  count=0
  [[ -f "${count_file}" ]] && count="$(cat "${count_file}")"
  printf '%s' "$((count + 1))" > "${count_file}"
  exit 0
fi

echo "unexpected fake sops invocation: $*" >&2
exit 1
EOF
  chmod +x "${path}"
}

create_fake_curl() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_VAULT_STATE_DIR:?}"
method="GET"
data=""
url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -X)
      method="$2"
      shift 2
      ;;
    -d)
      data="$2"
      shift 2
      ;;
    -H|-sk)
      shift
      [[ "${1:-}" != -* && "${1:-}" != http* ]] && shift || true
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "${method}:${url}" in
  GET:*secret/data/github/deploy-key)
    if [[ -f "${state}/vault-value" ]]; then
      jq -n --rawfile value "${state}/vault-value" '{data:{data:{value:$value}}}'
    else
      printf '{"errors":["404 Not Found"]}\n'
    fi
    ;;
  POST:*secret/data/github/deploy-key)
    if [[ "${FAKE_VAULT_WRITE_MODE:-ok}" == "reject" ]]; then
      printf '{"errors":["permission denied"]}\n'
      exit 0
    fi
    mkdir -p "${state}"
    printf '%s' "${data}" | jq -r -j '.data.value' > "${state}/vault-value"
    chmod 600 "${state}/vault-value"
    count_file="${state}/vault-post-count"
    count=0
    [[ -f "${count_file}" ]] && count="$(cat "${count_file}")"
    printf '%s' "$((count + 1))" > "${count_file}"
    printf '{}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "${path}"
}

create_fake_git() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "ls-remote" ]]; then
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/main\n'
  exit 0
fi
echo "unexpected fake git invocation: $*" >&2
exit 1
EOF
  chmod +x "${path}"
}

run_seed() {
  local fixture="$1"
  shift
  FAKE_SOPS_STATE_DIR="${fixture}/sops" \
  FAKE_VAULT_STATE_DIR="${fixture}/vault" \
  FAKE_VAULT_WRITE_MODE="${FAKE_VAULT_WRITE_MODE:-ok}" \
  SEED_GITHUB_CONFIG_FILE="${fixture}/config.yaml" \
  SEED_GITHUB_SECRETS_FILE="${fixture}/secrets.yaml" \
  SEED_GITHUB_SOPS_BIN="${fixture}/fake-sops.sh" \
  SEED_GITHUB_CURL_BIN="${fixture}/fake-curl.sh" \
  SEED_GITHUB_GIT_BIN="${fixture}/fake-git.sh" \
  SEED_GITHUB_YQ_BIN="${REAL_YQ}" \
  SEED_GITHUB_JQ_BIN="${REAL_JQ}" \
  SEED_GITHUB_SSH_KEYGEN_BIN="${REAL_SSH_KEYGEN}" \
  SEED_GITHUB_SSH_BIN="ssh" \
  "${REPO_ROOT}/framework/scripts/seed-github-deploy-key.sh" "$@"
}

setup_fixture() {
  local target_var="$1"
  make_temp_dir fixture
  mkdir -p "${fixture}/sops" "${fixture}/vault"
  make_config "${fixture}/config.yaml"
  : > "${fixture}/secrets.yaml"
  create_fake_sops "${fixture}/fake-sops.sh"
  create_fake_curl "${fixture}/fake-curl.sh"
  create_fake_git "${fixture}/fake-git.sh"
  printf -v "${target_var}" '%s' "${fixture}"
}

setup_fixture FIXTURE
make_key "${FIXTURE}/key1"
make_key "${FIXTURE}/key2"

test_start "1" "valid first seed writes SOPS and Vault"
set +e
FIRST_OUTPUT="$(run_seed "${FIXTURE}" prod --key-file "${FIXTURE}/key1" 2>&1)"
FIRST_EXIT=$?
set -e
if [[ "${FIRST_EXIT}" -eq 0 ]] && \
   grep -q 'SOPS github_deploy_key: written' <<< "${FIRST_OUTPUT}" && \
   grep -q 'Vault secret/data/github/deploy-key: written' <<< "${FIRST_OUTPUT}" && \
   same_private_key "${FIXTURE}/key1" "${FIXTURE}/sops/github_deploy_key" && \
   same_private_key "${FIXTURE}/key1" "${FIXTURE}/vault/vault-value"; then
  test_pass "first seed wrote both persistence targets"
else
  test_fail "first seed did not write SOPS and Vault"
fi

test_start "2" "same key rerun is no-op"
before_sops_count="$(cat "${FIXTURE}/sops/sops-set-count")"
before_vault_count="$(cat "${FIXTURE}/vault/vault-post-count")"
set +e
RERUN_OUTPUT="$(run_seed "${FIXTURE}" prod --key-file "${FIXTURE}/key1" 2>&1)"
RERUN_EXIT=$?
set -e
after_sops_count="$(cat "${FIXTURE}/sops/sops-set-count")"
after_vault_count="$(cat "${FIXTURE}/vault/vault-post-count")"
if [[ "${RERUN_EXIT}" -eq 0 ]] && \
   grep -q 'already present with matching fingerprint' <<< "${RERUN_OUTPUT}" && \
   grep -q 'already current' <<< "${RERUN_OUTPUT}" && \
   [[ "${before_sops_count}" == "${after_sops_count}" ]] && \
   [[ "${before_vault_count}" == "${after_vault_count}" ]]; then
  test_pass "same-key rerun did not rewrite SOPS or Vault"
else
  test_fail "same-key rerun was not idempotent"
fi

test_start "3" "different key without --rotate fails"
set +e
DIFF_OUTPUT="$(run_seed "${FIXTURE}" prod --key-file "${FIXTURE}/key2" 2>&1)"
DIFF_EXIT=$?
set -e
if [[ "${DIFF_EXIT}" -ne 0 ]] && grep -q -- '--rotate' <<< "${DIFF_OUTPUT}" && same_private_key "${FIXTURE}/key1" "${FIXTURE}/sops/github_deploy_key"; then
  test_pass "different key requires explicit rotation"
else
  test_fail "different key without --rotate did not fail safely"
fi

test_start "4" "different key with --rotate writes both SOPS and Vault"
set +e
ROTATE_OUTPUT="$(run_seed "${FIXTURE}" prod --key-file "${FIXTURE}/key2" --rotate 2>&1)"
ROTATE_EXIT=$?
set -e
if [[ "${ROTATE_EXIT}" -eq 0 ]] && \
   grep -q 'SOPS github_deploy_key: rotated' <<< "${ROTATE_OUTPUT}" && \
   same_private_key "${FIXTURE}/key2" "${FIXTURE}/sops/github_deploy_key" && \
   same_private_key "${FIXTURE}/key2" "${FIXTURE}/vault/vault-value"; then
  test_pass "rotation updated both persistence targets"
else
  test_fail "rotation did not update SOPS and Vault together"
fi

test_start "5" "invalid private key fails before any write"
setup_fixture INVALID_FIXTURE
printf 'not a private key\n' > "${INVALID_FIXTURE}/bad-key"
chmod 600 "${INVALID_FIXTURE}/bad-key"
set +e
INVALID_OUTPUT="$(run_seed "${INVALID_FIXTURE}" prod --key-file "${INVALID_FIXTURE}/bad-key" 2>&1)"
INVALID_EXIT=$?
set -e
if [[ "${INVALID_EXIT}" -ne 0 ]] && \
   [[ ! -e "${INVALID_FIXTURE}/sops/github_deploy_key" ]] && \
   [[ ! -e "${INVALID_FIXTURE}/vault/vault-value" ]]; then
  test_pass "invalid key failed before SOPS or Vault writes"
else
  test_fail "invalid key wrote state before failing"
fi

test_start "6" "--dry-run writes nothing"
setup_fixture DRY_FIXTURE
make_key "${DRY_FIXTURE}/key"
set +e
DRY_OUTPUT="$(run_seed "${DRY_FIXTURE}" prod --key-file "${DRY_FIXTURE}/key" --dry-run 2>&1)"
DRY_EXIT=$?
set -e
if [[ "${DRY_EXIT}" -eq 0 ]] && \
   grep -q 'would be written' <<< "${DRY_OUTPUT}" && \
   [[ ! -e "${DRY_FIXTURE}/sops/github_deploy_key" ]] && \
   [[ ! -e "${DRY_FIXTURE}/vault/vault-value" ]]; then
  test_pass "dry run performed validation without writes"
else
  test_fail "dry run wrote SOPS or Vault state"
fi

test_start "7" "no key material is plumbed through CIDATA or TF_VAR"
if ! rg -n 'TF_VAR_github_deploy_key|github_deploy_key' "${REPO_ROOT}/framework/tofu" "${REPO_ROOT}/site/tofu" >/dev/null 2>&1; then
  test_pass "github_deploy_key is absent from OpenTofu variables and CIDATA plumbing"
else
  test_fail "github_deploy_key appears in OpenTofu/CIDATA plumbing"
fi

test_start "8" "Vault API write errors fail the seeding ceremony"
setup_fixture VAULT_REJECT_FIXTURE
make_key "${VAULT_REJECT_FIXTURE}/key"
set +e
VAULT_REJECT_OUTPUT="$(FAKE_VAULT_WRITE_MODE=reject run_seed "${VAULT_REJECT_FIXTURE}" prod --key-file "${VAULT_REJECT_FIXTURE}/key" 2>&1)"
VAULT_REJECT_EXIT=$?
set -e
if [[ "${VAULT_REJECT_EXIT}" -ne 0 ]] && \
   grep -q 'Vault API POST secret/data/github/deploy-key returned errors' <<< "${VAULT_REJECT_OUTPUT}" && \
   ! grep -q 'Vault secret/data/github/deploy-key: written' <<< "${VAULT_REJECT_OUTPUT}" && \
   [[ ! -e "${VAULT_REJECT_FIXTURE}/vault/vault-value" ]]; then
  test_pass "Vault rejection stopped seed before reporting success"
else
  test_fail "Vault rejection was not fail-loud during seed"
fi

runner_summary
