#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
LE_DIR="${TMP_DIR}/letsencrypt"
PROD_URL="https://acme-v02.api.letsencrypt.org/directory"
mkdir -p "${SHIM_DIR}" "${LE_DIR}/renewal" "${LE_DIR}/accounts/acme-v02.api.letsencrypt.org/directory/prod-account"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

host=""
cmd_start=-1
args=("$@")

for ((i = 0; i < ${#args[@]}; i++)); do
  arg="${args[i]}"
  if [[ "${arg}" == root@* ]]; then
    host="${arg#root@}"
  fi
  if [[ "${arg}" == "bash" && $((i + 1)) -lt ${#args[@]} && "${args[i + 1]}" == "-s" ]]; then
    cmd_start="${i}"
    break
  fi
done

if [[ "${host}" == "${STUB_UNREACHABLE_HOST:-}" ]]; then
  printf 'ssh: connect to host %s port 22: Operation timed out\n' "${host}" >&2
  exit 255
fi

if [[ "${cmd_start}" -lt 0 ]]; then
  printf 'unexpected ssh invocation: %s\n' "$*" >&2
  exit 98
fi

remote_args=("${args[@]:cmd_start}")
exec "${remote_args[@]}"
EOF
chmod +x "${SHIM_DIR}/ssh"

cat > "${SHIM_DIR}/certbot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${STUB_CERTBOT_CASE:-valid}" in
  valid)
    cat <<'OUT'
Found the following certs:
  Certificate Name: vault.prod.example.test
    Domains: vault.prod.example.test
    Expiry Date: 2026-10-01 00:00:00+00:00 (VALID: 87 days)
    Certificate Path: /etc/letsencrypt/live/vault.prod.example.test/fullchain.pem
OUT
    ;;
  skipped)
    cat <<'OUT'
Renewal configuration file /etc/letsencrypt/renewal/vault.prod.example.test.conf is broken. The error was: fullchain mismatch. Skipping.
OUT
    ;;
  *)
    printf 'unknown STUB_CERTBOT_CASE=%s\n' "${STUB_CERTBOT_CASE:-}" >&2
    exit 99
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/certbot"

cat > "${LE_DIR}/renewal/vault.prod.example.test.conf" <<EOF
version = 2.11.0
archive_dir = ${LE_DIR}/archive/vault.prod.example.test
cert = ${LE_DIR}/live/vault.prod.example.test/cert.pem
privkey = ${LE_DIR}/live/vault.prod.example.test/privkey.pem
chain = ${LE_DIR}/live/vault.prod.example.test/chain.pem
fullchain = ${LE_DIR}/live/vault.prod.example.test/fullchain.pem
server = ${PROD_URL}
account = prod-account
EOF

export PATH="${SHIM_DIR}:${PATH}"
export CERTBOT_CLUSTER_SSH_BIN="${SHIM_DIR}/ssh"
source "${REPO_ROOT}/framework/scripts/certbot-cluster.sh"

run_capture() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  STATUS=$?
  set -e
}

assert_exit() {
  local expected_status="$1"
  local label="$2"

  if [[ "${STATUS}" -eq "${expected_status}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected exit %s, got %s\n' "${expected_status}" "${STATUS}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_output_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq "${needle}" <<< "${OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing output: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

test_start "RS1" "remote renewability probe executes streamed helper and returns rc=0 for a valid cert"
export STUB_CERTBOT_CASE=valid
run_capture certbot_cluster_run_remote_renewability_probe "10.0.0.31" "vault.prod.example.test"
assert_exit 0 "streamed renewability helper accepts valid lineage"
assert_output_contains "days_remaining=87" "streamed renewability helper emits predicate output"

test_start "RS2" "remote renewability probe returns rc=1 for a skipped lineage"
export STUB_CERTBOT_CASE=skipped
run_capture certbot_cluster_run_remote_renewability_probe "10.0.0.31" "vault.prod.example.test"
assert_exit 1 "streamed renewability helper preserves unrenewable rc=1"
assert_output_contains "reason=cert-skipped" "streamed renewability helper emits skipped-lineage reason"

test_start "RS3" "remote renewability probe maps SSH rc=255 to rc=3 with vm-unreachable reason"
export STUB_UNREACHABLE_HOST="10.0.0.255"
run_capture certbot_cluster_run_remote_renewability_probe "10.0.0.255" "vault.prod.example.test"
assert_exit 3 "streamed renewability helper maps unreachable VM to unknowable rc=3"
assert_output_contains "reason=vm-unreachable" "streamed renewability helper emits vm-unreachable reason"
unset STUB_UNREACHABLE_HOST

test_start "RS4" "remote persisted-state helper executes streamed check helper"
run_capture certbot_cluster_run_remote_helper \
  "10.0.0.31" \
  --mode check \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --letsencrypt-dir "${LE_DIR}" \
  --work-dir "${TMP_DIR}/work" \
  --logs-dir "${TMP_DIR}/logs" \
  --fqdn "vault.prod.example.test" \
  --label "vault_prod"
assert_exit 0 "streamed persisted-state helper passes canonical fixture"

runner_summary
