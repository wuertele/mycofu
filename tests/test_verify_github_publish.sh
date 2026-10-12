#!/usr/bin/env bash
# test_verify_github_publish.sh — Verify verify-github-publish.sh fixture behavior.

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
  path="$(mktemp -d "${TMPDIR:-/tmp}/verify-github-test.XXXXXX")"
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
  cicd:
    ip: 127.0.0.2
EOF
}

make_key() {
  local path="$1"
  "${REAL_SSH_KEYGEN}" -t ed25519 -f "${path}" -N "" -C "verify-test" >/dev/null
  chmod 600 "${path}"
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
      if [[ "${VERIFY_FAKE_MODE:-pass}" == "missing-sops" ]]; then
        exit 1
      fi
      cat "${VERIFY_FAKE_STATE_DIR:?}/sops-key"
      ;;
    *) exit 1 ;;
  esac
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
value_file="${VERIFY_FAKE_STATE_DIR:?}/sops-key"
if [[ "${VERIFY_FAKE_MODE:-pass}" == "vault-mismatch" ]]; then
  value_file="${VERIFY_FAKE_STATE_DIR}/vault-key"
fi
jq -n --rawfile value "${value_file}" '{data:{data:{value:$value}}}'
EOF
  chmod +x "${path}"
}

create_fake_ssh() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
case "${cmd}" in
  *'cat /run/secrets/github/remote-url'*)
    if [[ "${VERIFY_FAKE_MODE:-pass}" == "runner-url-mismatch" ]]; then
      printf 'git@github.com:wrong/repo.git\n'
    else
      printf 'git@github.com:example/mycofu.git\n'
    fi
    ;;
  *'test -s /run/secrets/vault-agent/github-deploy-key'*)
    [[ "${VERIFY_FAKE_MODE:-pass}" != "runner-key-missing" ]]
    ;;
  *'git ls-remote'*)
    if [[ "${VERIFY_FAKE_MODE:-pass}" == "ls-remote-failure" ]]; then
      echo "git@github.com: Permission denied (publickey)." >&2
      exit 128
    fi
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/main\n'
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${path}"
}

setup_fixture() {
  local target_var="$1"
  make_temp_dir fixture
  make_config "${fixture}/config.yaml"
  : > "${fixture}/secrets.yaml"
  make_key "${fixture}/sops-key"
  make_key "${fixture}/vault-key"
  create_fake_sops "${fixture}/fake-sops.sh"
  create_fake_curl "${fixture}/fake-curl.sh"
  create_fake_ssh "${fixture}/fake-ssh.sh"
  printf -v "${target_var}" '%s' "${fixture}"
}

run_verify() {
  local fixture="$1"
  local mode="$2"
  set +e
  OUTPUT="$(
    VERIFY_FAKE_MODE="${mode}" \
    VERIFY_FAKE_STATE_DIR="${fixture}" \
    VERIFY_GITHUB_CONFIG_FILE="${fixture}/config.yaml" \
    VERIFY_GITHUB_SECRETS_FILE="${fixture}/secrets.yaml" \
    VERIFY_GITHUB_SOPS_BIN="${fixture}/fake-sops.sh" \
    VERIFY_GITHUB_CURL_BIN="${fixture}/fake-curl.sh" \
    VERIFY_GITHUB_SSH_BIN="${fixture}/fake-ssh.sh" \
    VERIFY_GITHUB_YQ_BIN="${REAL_YQ}" \
    VERIFY_GITHUB_JQ_BIN="${REAL_JQ}" \
    VERIFY_GITHUB_SSH_KEYGEN_BIN="${REAL_SSH_KEYGEN}" \
    "${REPO_ROOT}/framework/scripts/verify-github-publish.sh" prod 2>&1
  )"
  STATUS=$?
  set -e
  printf '%s' "${OUTPUT}" > "${fixture}/output.txt"
  printf '%s' "${STATUS}" > "${fixture}/exit.txt"
}

test_start "1" "all PASS case with shims"
setup_fixture PASS_FIXTURE
run_verify "${PASS_FIXTURE}" pass
if [[ "$(cat "${PASS_FIXTURE}/exit.txt")" -eq 0 ]] && \
   grep -q '\[PASS\] config remote URL' "${PASS_FIXTURE}/output.txt" && \
   grep -q '\[PASS\] SOPS github_deploy_key present' "${PASS_FIXTURE}/output.txt" && \
   grep -q '\[PASS\] Vault secret/data/github/deploy-key fingerprint matches SOPS' "${PASS_FIXTURE}/output.txt" && \
   grep -q '\[PASS\] runner git ls-remote' "${PASS_FIXTURE}/output.txt"; then
  test_pass "all verification sub-checks passed"
else
  test_fail "all-pass verification did not pass"
fi

test_start "2" "missing SOPS key fails"
setup_fixture MISSING_SOPS_FIXTURE
run_verify "${MISSING_SOPS_FIXTURE}" missing-sops
if [[ "$(cat "${MISSING_SOPS_FIXTURE}/exit.txt")" -ne 0 ]] && grep -q '\[FAIL\] SOPS github_deploy_key missing' "${MISSING_SOPS_FIXTURE}/output.txt"; then
  test_pass "missing SOPS key is reported"
else
  test_fail "missing SOPS key was not reported"
fi

test_start "3" "Vault key mismatch fails"
setup_fixture VAULT_MISMATCH_FIXTURE
run_verify "${VAULT_MISMATCH_FIXTURE}" vault-mismatch
if [[ "$(cat "${VAULT_MISMATCH_FIXTURE}/exit.txt")" -ne 0 ]] && grep -q '\[FAIL\] Vault secret/data/github/deploy-key fingerprint mismatch' "${VAULT_MISMATCH_FIXTURE}/output.txt"; then
  test_pass "Vault mismatch is reported"
else
  test_fail "Vault mismatch was not reported"
fi

test_start "4" "runner key missing fails"
setup_fixture RUNNER_KEY_FIXTURE
run_verify "${RUNNER_KEY_FIXTURE}" runner-key-missing
if [[ "$(cat "${RUNNER_KEY_FIXTURE}/exit.txt")" -ne 0 ]] && grep -q '\[FAIL\] runner deploy key missing' "${RUNNER_KEY_FIXTURE}/output.txt"; then
  test_pass "runner missing key is reported"
else
  test_fail "runner missing key was not reported"
fi

test_start "5" "runner remote URL mismatch fails"
setup_fixture RUNNER_URL_FIXTURE
run_verify "${RUNNER_URL_FIXTURE}" runner-url-mismatch
if [[ "$(cat "${RUNNER_URL_FIXTURE}/exit.txt")" -ne 0 ]] && grep -q '\[FAIL\] runner remote-url mismatch' "${RUNNER_URL_FIXTURE}/output.txt"; then
  test_pass "runner URL mismatch is reported"
else
  test_fail "runner URL mismatch was not reported"
fi

test_start "6" "ls-remote failure reports classifier output"
setup_fixture LS_FAIL_FIXTURE
run_verify "${LS_FAIL_FIXTURE}" ls-remote-failure
if [[ "$(cat "${LS_FAIL_FIXTURE}/exit.txt")" -ne 0 ]] && grep -q '\[FAIL\] runner git ls-remote (auth_error)' "${LS_FAIL_FIXTURE}/output.txt"; then
  test_pass "ls-remote failure includes auth_error classifier"
else
  test_fail "ls-remote failure did not include classifier output"
fi

runner_summary

