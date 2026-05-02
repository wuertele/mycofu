#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
SSH_LOG="${TMP_DIR}/ssh.log"
CURL_LOG="${TMP_DIR}/curl.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site/sops" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/check-cert-budget.sh" "${FIXTURE_REPO}/framework/scripts/check-cert-budget.sh"
cp "${REPO_ROOT}/framework/scripts/certbot-cluster.sh" "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/check-cert-budget.sh" "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh"

cat > "${FIXTURE_REPO}/flake.nix" <<'EOF'
{
  description = "fixture";
}
EOF

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
domain: example.com
vms:
  vault_prod:
    ip: 127.0.0.1
  testapp_prod:
    vmid: 600
    ip: 192.0.2.10
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${FIXTURE_REPO}/site/sops/secrets.yaml" <<'EOF'
{}
EOF

cat > "${FIXTURE_REPO}/operator.age.key" <<'EOF'
AGE-SECRET-KEY-FAKE
EOF

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *'vault_prod_root_token'* ]]; then
  printf 'root-token\n'
  exit 0
fi

printf '{}\n'
EOF
chmod +x "${SHIM_DIR}/sops"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${SSH_LOG}"
printf '%s\n' "${STUB_SSH_COUNT:-0}"
EOF
chmod +x "${SHIM_DIR}/ssh"

cat > "${SHIM_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CURL_LOG}"
case "$*" in
  *"/mycofu/metadata/certs/testapp.prod.example.com"*)
    MODE="${STUB_TESTAPP_METADATA_MODE:-missing}"
    ;;
  *"/mycofu/metadata/certs/vault.prod.example.com"*)
    MODE="${STUB_VAULT_METADATA_MODE:-missing}"
    ;;
  *)
    MODE="missing"
    ;;
esac
case "${MODE}" in
  covered)
    printf '{"data":{"custom_metadata":{"not_after":"%s"}}}\n' "${STUB_NOT_AFTER}"
    ;;
  stale)
    printf '{"data":{"custom_metadata":{"not_after":"%s"}}}\n' "${STUB_NOT_AFTER}"
    ;;
  missing)
    printf '{}\n'
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/curl"

iso_after_days() {
  python3 - "$1" <<'PY'
import datetime, sys
days = int(sys.argv[1])
ts = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)
print(ts.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

run_budget() {
  (
    cd "${FIXTURE_REPO}"
    PATH="${SHIM_DIR}:${PATH}" \
    SSH_LOG="${SSH_LOG}" \
    CURL_LOG="${CURL_LOG}" \
    STUB_VAULT_MODE="${STUB_VAULT_MODE:-missing}" \
    STUB_NOT_AFTER="${STUB_NOT_AFTER:-}" \
    STUB_SSH_COUNT="${STUB_SSH_COUNT:-0}" \
    framework/scripts/check-cert-budget.sh "$@"
  )
}

test_start "1" "Vault metadata 60 days out reports the FQDN as covered"
rm -f "${SSH_LOG}" "${CURL_LOG}"
export STUB_TESTAPP_METADATA_MODE=covered
export STUB_VAULT_METADATA_MODE=missing
export STUB_NOT_AFTER="$(iso_after_days 60)"
export STUB_SSH_COUNT=0
set +e
COVERED_OUTPUT="$(
  run_budget prod 2>&1
)"
COVERED_STATUS=$?
set -e
if [[ "${COVERED_STATUS}" -eq 0 ]] && \
   grep -Fq 'covered by Vault' <<< "${COVERED_OUTPUT}" && \
   grep -Fq '1 FQDNs covered by Vault; 1 subject to LE budget' <<< "${COVERED_OUTPUT}" && \
   [[ -s "${SSH_LOG}" ]] && \
   grep -Fq 'root@127.0.0.1' "${SSH_LOG}" && \
   ! grep -Fq 'root@192.0.2.10' "${SSH_LOG}"; then
  test_pass "valid Vault metadata skips the covered FQDN but still checks vault over SSH"
else
  test_fail "Vault-covered certs should skip only the covered FQDN"
  printf '    output:\n%s\n' "${COVERED_OUTPUT}" >&2
fi

test_start "2" "missing Vault entry falls back to the SSH archive count"
rm -f "${SSH_LOG}" "${CURL_LOG}"
export STUB_TESTAPP_METADATA_MODE=missing
export STUB_VAULT_METADATA_MODE=missing
export STUB_SSH_COUNT=2
set +e
MISSING_OUTPUT="$(
  run_budget prod 2>&1
)"
MISSING_STATUS=$?
set -e
if [[ "${MISSING_STATUS}" -eq 0 ]] && \
   grep -Fq '2/5 — OK' <<< "${MISSING_OUTPUT}" && \
   grep -Fq '0 FQDNs covered by Vault; 2 subject to LE budget' <<< "${MISSING_OUTPUT}" && \
   [[ -s "${SSH_LOG}" ]] && \
   grep -Fq 'root@127.0.0.1' "${SSH_LOG}" && \
   grep -Fq 'root@192.0.2.10' "${SSH_LOG}"; then
  test_pass "missing Vault metadata falls back to SSH for both testapp and vault"
else
  test_fail "missing Vault metadata should use the SSH archive fallback for every inventory row"
  printf '    output:\n%s\n' "${MISSING_OUTPUT}" >&2
fi

test_start "3" "Vault metadata 20 days out is treated as stale"
rm -f "${SSH_LOG}" "${CURL_LOG}"
export STUB_TESTAPP_METADATA_MODE=stale
export STUB_VAULT_METADATA_MODE=missing
export STUB_NOT_AFTER="$(iso_after_days 20)"
export STUB_SSH_COUNT=1
set +e
STALE_OUTPUT="$(
  run_budget prod 2>&1
)"
STALE_STATUS=$?
set -e
if [[ "${STALE_STATUS}" -eq 0 ]] && \
   grep -Fq 'Vault entry is stale' <<< "${STALE_OUTPUT}" && \
   grep -Fq '0 FQDNs covered by Vault; 2 subject to LE budget' <<< "${STALE_OUTPUT}" && \
   [[ -s "${SSH_LOG}" ]] && \
   grep -Fq 'root@127.0.0.1' "${SSH_LOG}" && \
   grep -Fq 'root@192.0.2.10' "${SSH_LOG}"; then
  test_pass "stale Vault metadata falls back to the SSH archive count"
else
  test_fail "stale Vault metadata should not count as covered"
  printf '    output:\n%s\n' "${STALE_OUTPUT}" >&2
fi

test_start "4" "--no-vault bypasses the Vault query entirely"
rm -f "${SSH_LOG}" "${CURL_LOG}"
export STUB_TESTAPP_METADATA_MODE=covered
export STUB_VAULT_METADATA_MODE=covered
export STUB_NOT_AFTER="$(iso_after_days 60)"
export STUB_SSH_COUNT=1
set +e
NO_VAULT_OUTPUT="$(
  run_budget --no-vault prod 2>&1
)"
NO_VAULT_STATUS=$?
set -e
if [[ "${NO_VAULT_STATUS}" -eq 0 ]] && \
   grep -Fq '0 FQDNs covered by Vault; 2 subject to LE budget' <<< "${NO_VAULT_OUTPUT}" && \
   [[ -s "${SSH_LOG}" ]] && \
   grep -Fq 'root@127.0.0.1' "${SSH_LOG}" && \
   grep -Fq 'root@192.0.2.10' "${SSH_LOG}" && \
   [[ ! -e "${CURL_LOG}" ]]; then
  test_pass "--no-vault forces the legacy SSH-only budget path"
else
  test_fail "--no-vault should skip Vault and use SSH only"
  printf '    output:\n%s\n' "${NO_VAULT_OUTPUT}" >&2
fi

unset STUB_TESTAPP_METADATA_MODE STUB_VAULT_METADATA_MODE STUB_NOT_AFTER STUB_SSH_COUNT

runner_summary
