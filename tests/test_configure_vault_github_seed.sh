#!/usr/bin/env bash
# test_configure_vault_github_seed.sh — Verify configure-vault GitHub KV seeding.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

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
  path="$(mktemp -d "${TMPDIR:-/tmp}/configure-vault-github-test.XXXXXX")"
  TEMP_PATHS+=("${path}")
  printf -v "${target_var}" '%s' "${path}"
}

create_fake_sops() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

extract_key() {
  sed -n 's/.*\["\([^"]*\)"\].*/\1/p' <<< "$1"
}

if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" ]]; then
  key="$(extract_key "$3")"
  case "${key}" in
    vault_prod_root_token) printf 'root-token\n' ;;
    github_deploy_key)
      if [[ "${FAKE_SOPS_GITHUB_KEY:-present}" == "present" ]]; then
        printf 'github-private-key\n'
      else
        exit 1
      fi
      ;;
    pdns_api_key) printf 'pdns-key\n' ;;
    vault_approle_*_role_id) printf 'role-id\n' ;;
    vault_approle_*_secret_id) printf 'secret-id\n' ;;
    *) printf 'fixture-secret\n' ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "--set" ]]; then
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

method="GET"
data=""
url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d) data="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done

if [[ "${method}" == "POST" && "${url}" == *"secret/data/github/deploy-key" ]]; then
  if [[ "${FAKE_VAULT_WRITE_MODE:-ok}" == "reject" ]]; then
    printf '{"errors":["permission denied"]}\n'
    exit 0
  fi
  mkdir -p "${FAKE_CURL_STATE_DIR:?}"
  printf '%s' "${data}" | jq -r '.data.value' > "${FAKE_CURL_STATE_DIR}/github-vault-value"
  printf '{}\n'
  exit 0
fi

case "${url}" in
  *sys/health) printf '{"initialized":true,"sealed":false}\n' ;;
  *sys/mounts) printf '{"data":{"secret/":{"type":"kv"},"mycofu/":{"type":"kv"}}}\n' ;;
  *sys/auth) printf '{"data":{"approle/":{"type":"approle"}}}\n' ;;
  *auth/approle/role/*/role-id) printf '{"data":{"role_id":"role-id"}}\n' ;;
  *auth/approle/role/*/secret-id) printf '{"data":{"secret_id":"secret-id"}}\n' ;;
  *auth/approle/role/*) printf '{"data":{"token_ttl":"1h"}}\n' ;;
  *sys/policies/acl) printf '{"data":{"keys":["default-policy","github-publish-policy"]}}\n' ;;
  *) printf '{}\n' ;;
esac
EOF
  chmod +x "${path}"
}

run_configure_vault() {
  local fixture="$1"
  local github_key_mode="$2"
  set +e
  OUTPUT="$(
    PATH="${fixture}/shims:${PATH}" \
    FAKE_SOPS_GITHUB_KEY="${github_key_mode}" \
    FAKE_VAULT_WRITE_MODE="${FAKE_VAULT_WRITE_MODE:-ok}" \
    FAKE_CURL_STATE_DIR="${fixture}" \
    "${REPO_ROOT}/framework/scripts/configure-vault.sh" prod 2>&1
  )"
  STATUS=$?
  set -e
  printf '%s' "${OUTPUT}" > "${fixture}/output.txt"
  printf '%s' "${STATUS}" > "${fixture}/exit.txt"
}

setup_fixture() {
  local target_var="$1"
  make_temp_dir fixture
  mkdir -p "${fixture}/shims"
  create_fake_sops "${fixture}/shims/sops"
  create_fake_curl "${fixture}/shims/curl"
  printf -v "${target_var}" '%s' "${fixture}"
}

test_start "1" "configure-vault.sh maps github_deploy_key to secret/data/github/deploy-key"
if grep -Fq 'secret/data/github/deploy-key=github_deploy_key' "${REPO_ROOT}/framework/scripts/configure-vault.sh"; then
  test_pass "KV map includes GitHub deploy key"
else
  test_fail "KV map does not include GitHub deploy key"
fi

test_start "2" "missing SOPS key logs the seeding script action"
setup_fixture MISSING_FIXTURE
run_configure_vault "${MISSING_FIXTURE}" absent
if [[ "$(cat "${MISSING_FIXTURE}/exit.txt")" -eq 0 ]] && \
   grep -q 'seed-github-deploy-key.sh prod --key-file <path>' "${MISSING_FIXTURE}/output.txt" && \
   [[ ! -e "${MISSING_FIXTURE}/github-vault-value" ]]; then
  test_pass "missing github_deploy_key logs action and skips GitHub KV write"
else
  test_fail "missing github_deploy_key behavior is wrong"
fi

test_start "3" "present SOPS key writes KV through the Vault API helper"
setup_fixture PRESENT_FIXTURE
run_configure_vault "${PRESENT_FIXTURE}" present
if [[ "$(cat "${PRESENT_FIXTURE}/exit.txt")" -eq 0 ]] && \
   grep -q "secret/data/github/deploy-key: written from SOPS key 'github_deploy_key'" "${PRESENT_FIXTURE}/output.txt" && \
   [[ "$(cat "${PRESENT_FIXTURE}/github-vault-value")" == "github-private-key" ]]; then
  test_pass "present github_deploy_key writes the expected Vault KV value"
else
  test_fail "present github_deploy_key was not written to Vault"
fi

test_start "4" "old manual vault kv put instruction is gone"
if ! grep -Fq 'vault kv put secret/github/deploy-key' "${REPO_ROOT}/framework/scripts/configure-vault.sh"; then
  test_pass "manual-only seed instruction removed"
else
  test_fail "manual-only seed instruction still exists"
fi

test_start "5" "GitHub KV Vault write errors fail configure-vault"
setup_fixture REJECT_FIXTURE
FAKE_VAULT_WRITE_MODE=reject run_configure_vault "${REJECT_FIXTURE}" present
if [[ "$(cat "${REJECT_FIXTURE}/exit.txt")" -ne 0 ]] && \
   grep -q 'Vault API POST secret/data/github/deploy-key returned errors' "${REJECT_FIXTURE}/output.txt" && \
   ! grep -q "secret/data/github/deploy-key: written from SOPS key 'github_deploy_key'" "${REJECT_FIXTURE}/output.txt" && \
   [[ ! -e "${REJECT_FIXTURE}/github-vault-value" ]]; then
  test_pass "configure-vault fails loud when Vault rejects the GitHub KV write"
else
  test_fail "configure-vault did not fail loud on GitHub KV Vault rejection"
fi

runner_summary
