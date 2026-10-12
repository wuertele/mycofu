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

# These cases exercise the GitHub KV seeding path, not key resolution.
# SOPS_AGE_KEY_FILE is pinned so the run is hermetic: configure-vault.sh now
# resolves the variable itself (#862), and without a pin these cases would
# either inherit the runner's ambient value or trip the new fail-closed guard
# depending on the machine. The value is never dereferenced — the shimmed
# `sops` above ignores it.
run_configure_vault() {
  local fixture="$1"
  local github_key_mode="$2"
  set +e
  OUTPUT="$(
    PATH="${fixture}/shims:${PATH}" \
    FAKE_SOPS_GITHUB_KEY="${github_key_mode}" \
    FAKE_VAULT_WRITE_MODE="${FAKE_VAULT_WRITE_MODE:-ok}" \
    FAKE_CURL_STATE_DIR="${fixture}" \
    SOPS_AGE_KEY_FILE="${fixture}/fixture.age.key" \
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

# --- #862: SOPS_AGE_KEY_FILE self-resolution -----------------------------
#
# configure-vault.sh decrypts SECRETS_FILE for the root token, the AppRole
# write-once check, and the KV seed values. On the cicd runner the variable
# comes from the runner service environment, so the resolution branch is dead
# there; these cases drive it with the variable genuinely unset.
#
# A standalone fixture repo is required because configure-vault.sh locates
# REPO_DIR with find_repo_root(), which walks up looking for flake.nix — without
# a fixture flake.nix the walk escapes into the real checkout.
make_configure_vault_repo() {
  local out_var="$1" place_key="$2"
  local repo
  make_temp_dir repo
  # Canonicalize: find_repo_root() uses `cd ... && pwd`, which resolves the
  # macOS /var -> /private/var symlink that mktemp hands back.
  repo="$(cd "${repo}" && pwd -P)"
  mkdir -p "${repo}/framework/scripts" "${repo}/site/sops" "${repo}/shims"
  printf 'fixture flake\n' > "${repo}/flake.nix"
  cp "${REPO_ROOT}/framework/scripts/configure-vault.sh" "${repo}/framework/scripts/"
  # Sourced unconditionally near the top, before the guard.
  cp "${REPO_ROOT}/framework/scripts/vault-requirements-lib.sh" "${repo}/framework/scripts/"
  chmod +x "${repo}/framework/scripts/configure-vault.sh"
  cat > "${repo}/site/config.yaml" <<'EOF'
domain: fixture.example.com
vms:
  vault_dev:
    ip: 10.0.0.21
EOF
  printf 'fixture: secrets\n' > "${repo}/site/sops/secrets.yaml"
  # Recording sops shim: reports the key it was handed, then stops the run.
  # This proves the real script reached its first decrypt with a resolved key.
  cat > "${repo}/shims/sops" <<'EOF'
#!/usr/bin/env bash
printf 'SOPS_SAW_KEY=[%s]\n' "${SOPS_AGE_KEY_FILE:-<unset>}" >&2
exit 1
EOF
  chmod +x "${repo}/shims/sops"
  if [[ "${place_key}" == "yes" ]]; then
    printf 'AGE-SECRET-KEY-FIXTURE\n' > "${repo}/operator.age.key"
  fi
  printf -v "${out_var}" '%s' "${repo}"
}

run_configure_vault_repo() {
  local repo="$1"
  shift
  set +e
  (
    export PATH="${repo}/shims:${PATH}"
    export HOME="${repo}/nonexistent-home"
    export XDG_CONFIG_HOME="${repo}/nonexistent-xdg"
    unset SOPS_AGE_KEY_FILE
    unset VAULT_ROOT_TOKEN
    cd "${repo}"
    framework/scripts/configure-vault.sh "$@"
  ) > "${repo}/out.txt" 2>&1
  local rc=$?
  set -e
  printf '%s' "${rc}"
}

test_start "6" "configure-vault.sh fails closed when no SOPS age key exists anywhere (#862)"
make_configure_vault_repo NOKEY_REPO no
nokey_rc="$(run_configure_vault_repo "${NOKEY_REPO}" dev)"
nokey_out="$(cat "${NOKEY_REPO}/out.txt")"
# Fails closed (G4) naming both candidate paths, and before reaching the first
# decrypt — the sops shim never runs, so SOPS_SAW_KEY must be absent.
if [[ "${nokey_rc}" -ne 0 \
      && "${nokey_out}" == *"No SOPS age key found"* \
      && "${nokey_out}" == *"operator.age.key"* \
      && "${nokey_out}" == *"sops/age/keys.txt"* \
      && "${nokey_out}" != *"SOPS_SAW_KEY"* ]]; then
  test_pass "missing key exits non-zero with named candidates before any decrypt"
else
  test_fail "configure-vault.sh did not fail closed on a missing SOPS age key"
  sed 's/^/    /' "${NOKEY_REPO}/out.txt" >&2
fi

test_start "7" "configure-vault.sh self-resolves SOPS_AGE_KEY_FILE for its first decrypt (#862)"
make_configure_vault_repo KEY_REPO yes
key_rc="$(run_configure_vault_repo "${KEY_REPO}" dev)"
key_out="$(cat "${KEY_REPO}/out.txt")"
# The recording sops shim exits 1 by design, to stop the run at the first
# decrypt. A zero exit would mean the run never reached that shim, so the
# status is part of the assertion rather than incidental.
if [[ "${key_rc}" -ne 0 \
      && "${key_out}" == *"SOPS_SAW_KEY=[${KEY_REPO}/operator.age.key]"* ]]; then
  test_pass "unset SOPS_AGE_KEY_FILE resolves to repo-root operator.age.key at the decrypt"
else
  test_fail "configure-vault.sh did not resolve SOPS_AGE_KEY_FILE before decrypting"
  sed 's/^/    /' "${KEY_REPO}/out.txt" >&2
fi

test_start "8" "configure-vault.sh --dry-run still needs no SOPS age key (#862)"
# The guard is wrapped in `if [[ "$DRY_RUN" -eq 0 ]]` precisely so --dry-run
# keeps its no-sops contract (REQUIRED_TOOLS drops sops for dry runs). Run
# against the real repo, which is what test_cert_storage_policy.sh does.
set +e
dryrun_out="$(
  env -u SOPS_AGE_KEY_FILE \
      HOME=/tmp/mycofu-fixture-home-doesnotexist \
      XDG_CONFIG_HOME=/tmp/mycofu-fixture-xdg-doesnotexist \
      "${REPO_ROOT}/framework/scripts/configure-vault.sh" dev --dry-run 2>&1
)"
dryrun_rc=$?
set -e
if [[ "${dryrun_rc}" -eq 0 && "${dryrun_out}" != *"No SOPS age key found"* ]]; then
  test_pass "--dry-run succeeds with no key present (guard did not regress it)"
else
  test_fail "--dry-run regressed: it now demands a SOPS age key"
  sed 's/^/    /' <<< "${dryrun_out}" >&2
fi

runner_summary
