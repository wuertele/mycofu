#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "$SHIM_DIR" "${TMP_DIR}/sops"

CONFIG="${TMP_DIR}/config.yaml"
EXPECT_LOG="${TMP_DIR}/expect.log"
printf 'encrypted\n' > "${TMP_DIR}/sops/secrets.yaml"

cat > "$CONFIG" <<'EOF'
domain: example.test
management:
  subnet: 192.0.2.0/24
regreener:
  install_timeout_sec: 10
  ssh_timeout_sec: 1
pdu:
  host: pdu.fixture
  user: fixture-user
  password_ref: pdu_password_fixture
proxmox:
  installer:
    expected_version: "pve-manager/9.1"
    iso_sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
nodes:
  - name: bpve02
    mgmt_ip: 192.0.2.12
    regreen_enabled: true
    amt_ip: 192.0.2.112
    amt_user: admin
    amt_password_ref: amt_password_fixture
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
    pdu_outlet: 5
  - name: bpve05
    mgmt_ip: 192.0.2.15
    regreen_enabled: true
    amt_ip: 192.0.2.115
    amt_user: admin
    amt_password_ref: amt_password_fixture
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
    pdu_outlet: 18
EOF

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" ]]; then
  key="$(printf '%s' "$3" | sed -E 's/^\["([^"]+)"\]$/\1/')"
  [[ "$key" == "${SOPS_MISSING_KEY:-}" ]] && exit 1
  case "$key" in
    pdu_password_fixture) printf 'pdu-secret\n' ;;
    amt_password_fixture) printf 'amt-secret\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "-d" ]]; then
  printf 'ok\n'
  exit 0
fi
exit 99
EOF
chmod +x "${SHIM_DIR}/sops"

EXPECT_SHIM="${TMP_DIR}/pdu-expect"
cat > "$EXPECT_SHIM" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
host="$1"
user="$2"
outlet="$3"
action="$4"
if [[ "${PDU_PASSWORD:-}" != "pdu-secret" ]]; then
  printf 'missing env password\n' >&2
  exit 93
fi
printf 'host=%s user=%s outlet=%s action=%s\n' "$host" "$user" "$outlet" "$action" >> "${EXPECT_LOG:?}"
EOF
chmod +x "$EXPECT_SHIM"

export PATH="${SHIM_DIR}:${PATH}"
export MYCOFU_PDU_EXPECT="$EXPECT_SHIM"
export EXPECT_LOG

run_pdu() {
  : > "$EXPECT_LOG"
  local output rc
  set +e
  output="$("${REPO_ROOT}/framework/scripts/pdu-cycle.sh" --config "$CONFIG" "$@" 2>&1)"
  rc=$?
  set -e
  PDU_OUTPUT="$output"
  PDU_RC="$rc"
}

test_start "s037.16.1" "node outlet mapping is read from config"
run_pdu bpve02
if [[ "$PDU_RC" -eq 0 ]] && [[ "$(cat "$EXPECT_LOG")" == "host=pdu.fixture user=fixture-user outlet=5 action=Reboot" ]]; then
  test_pass "bpve02 maps to configured outlet 5"
else
  test_fail "bpve02 outlet mapping wrong"
  printf '%s\n' "$PDU_OUTPUT" >&2
  cat "$EXPECT_LOG" >&2
fi

test_start "s037.16.2" "non-formula outlet exception is honored"
run_pdu bpve05
if [[ "$PDU_RC" -eq 0 ]] && grep -q 'outlet=18 action=Reboot' "$EXPECT_LOG"; then
  test_pass "bpve05 maps to configured outlet 18"
else
  test_fail "bpve05 outlet was not read from config"
  printf '%s\n' "$PDU_OUTPUT" >&2
  cat "$EXPECT_LOG" >&2
fi

test_start "s037.16.3" "raw outlet form uses config PDU host and user"
run_pdu --outlet 5
if [[ "$PDU_RC" -eq 0 ]] && [[ "$(cat "$EXPECT_LOG")" == "host=pdu.fixture user=fixture-user outlet=5 action=Reboot" ]]; then
  test_pass "--outlet uses configured PDU endpoint"
else
  test_fail "--outlet behavior wrong"
fi

test_start "s037.16.4" "--check queries status and does not cycle"
run_pdu --check
if [[ "$PDU_RC" -eq 0 ]] && [[ "$(cat "$EXPECT_LOG")" == "host=pdu.fixture user=fixture-user outlet=all action=Status" ]] && ! grep -q 'Reboot' "$EXPECT_LOG"; then
  test_pass "--check used Status action only"
else
  test_fail "--check cycled or used wrong action"
  printf '%s\n' "$PDU_OUTPUT" >&2
  cat "$EXPECT_LOG" >&2
fi

test_start "s037.16.5" "missing PDU SOPS key fails before expect"
SOPS_MISSING_KEY=pdu_password_fixture run_pdu bpve02
if [[ "$PDU_RC" -eq 2 && ! -s "$EXPECT_LOG" ]]; then
  test_pass "missing PDU password stopped before expect helper"
else
  test_fail "missing PDU password reached expect helper"
  printf '%s\n' "$PDU_OUTPUT" >&2
  cat "$EXPECT_LOG" >&2
fi

test_start "s037.16.6" "script has no formulaic outlet derivation"
if ! rg -n 'N\+3|bpve0|pdu_outlet.*\+|OUTLET=.*\+' "${REPO_ROOT}/framework/scripts/pdu-cycle.sh" >/tmp/pdu-formula.$$ 2>&1; then
  test_pass "pdu-cycle.sh has no node-number outlet formula"
else
  test_fail "formula-like outlet derivation found"
  cat /tmp/pdu-formula.$$ >&2
fi
rm -f /tmp/pdu-formula.$$

runner_summary
