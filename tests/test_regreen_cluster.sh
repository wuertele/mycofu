#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

CONFIG="${TMP_DIR}/config.yaml"
RUN_DIR="${TMP_DIR}/run"
CALL_LOG="${TMP_DIR}/install-calls.log"

cat > "$CONFIG" <<'EOF'
domain: example.test
management:
  subnet: 192.0.2.0/24
regreener:
  install_timeout_sec: 10
  ssh_timeout_sec: 1
proxmox:
  installer:
    expected_version: "pve-manager/9.1"
nodes:
  - name: node1
    mgmt_ip: 192.0.2.11
    regreen_enabled: true
    amt_ip: 192.0.2.101
    amt_user: admin
    amt_password_ref: amt_password_test
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
  - name: node2
    mgmt_ip: 192.0.2.12
    regreen_enabled: false
    amt_ip: 192.0.2.102
    amt_user: admin
    amt_password_ref: amt_password_test
  - name: node3
    mgmt_ip: 192.0.2.13
    regreen_enabled: true
    amt_ip: 192.0.2.103
    amt_user: admin
    amt_password_ref: amt_password_test
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
  - name: node4
    mgmt_ip: 192.0.2.14
    regreen_enabled: true
    amt_ip: 192.0.2.104
    amt_user: admin
    amt_password_ref: amt_password_test
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
EOF

INSTALL_SHIM="${TMP_DIR}/install-pve-node"
cat > "$INSTALL_SHIM" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
node=""
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node) node="$2"; shift 2 ;;
    --config) shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    *) shift ;;
  esac
done
printf '%s dry_run=%s\n' "$node" "$dry_run" >> "${CALL_LOG:?}"
if [[ "$node" == "${FAIL_NODE:-}" ]]; then
  exit "${FAIL_RC:-7}"
fi
exit 0
EOF
chmod +x "$INSTALL_SHIM"

export MYCOFU_INSTALL_PVE_NODE="$INSTALL_SHIM"
export CALL_LOG

run_regreen() {
  : > "$CALL_LOG"
  rm -rf "$RUN_DIR"
  mkdir -p "$RUN_DIR"
  local output rc
  set +e
  output="$(
    MYCOFU_REGREENER_RUN_DIR="$RUN_DIR" \
      "${REPO_ROOT}/framework/scripts/regreen-cluster.sh" "$@" 2>&1
  )"
  rc=$?
  set -e
  REGREEN_OUTPUT="$output"
  REGREEN_RC="$rc"
}

test_start "s037.14.1" "missing config is rejected"
run_regreen --config "${TMP_DIR}/missing.yaml"
if [[ "$REGREEN_RC" -eq 2 ]]; then
  test_pass "missing config exits 2"
else
  test_fail "missing config exit code wrong: ${REGREEN_RC}"
fi

test_start "s037.14.2" "--node rejects disabled nodes before install"
run_regreen --config "$CONFIG" --node node2 --dry-run
if [[ "$REGREEN_RC" -eq 2 && ! -s "$CALL_LOG" ]]; then
  test_pass "disabled node rejected with no install call"
else
  test_fail "disabled node behavior wrong (rc=${REGREEN_RC})"
fi

test_start "s037.14.3" "all enumerates enabled nodes in config order"
run_regreen --config "$CONFIG" --dry-run
if [[ "$REGREEN_RC" -eq 0 ]] && \
   diff -u <(printf 'node1 dry_run=1\nnode3 dry_run=1\nnode4 dry_run=1\n') "$CALL_LOG" >/dev/null && \
   jq -e '.dry_run == true and .nodes.node1.state == "green" and .nodes.node3.state == "green" and .nodes.node4.state == "green" and .outcome == "green" and .hil_boot.status == "checked"' "${RUN_DIR}/status.json" >/dev/null && \
   grep -q 'Results: 3 green, 0 failed' <<< "$REGREEN_OUTPUT"; then
  test_pass "enabled nodes ran sequentially and status JSON was written"
else
  test_fail "all-node enumeration/status wrong"
  printf '%s\n' "$REGREEN_OUTPUT" >&2
  cat "$CALL_LOG" >&2
  cat "${RUN_DIR}/status.json" >&2 || true
fi

test_start "s037.14.4" "single-node target restricts execution"
run_regreen --config "$CONFIG" node3 --dry-run
if [[ "$REGREEN_RC" -eq 0 ]] && [[ "$(cat "$CALL_LOG")" == "node3 dry_run=1" ]]; then
  test_pass "positional target restricted to node3"
else
  test_fail "single-node restriction wrong"
fi

test_start "s037.14.5" "fail-fast records failed and not-attempted states"
FAIL_NODE=node3 FAIL_RC=7 run_regreen --config "$CONFIG"
if [[ "$REGREEN_RC" -eq 7 ]] && \
   diff -u <(printf 'node1 dry_run=0\nnode3 dry_run=0\n') "$CALL_LOG" >/dev/null && \
   jq -e '.nodes.node1.state == "green" and .nodes.node3.state == "failed" and .nodes.node3.exit_code == 7 and .nodes.node4.state == "not-attempted" and .outcome == "failed"' "${RUN_DIR}/status.json" >/dev/null; then
  test_pass "fail-fast stopped before node4 and wrote documented status"
else
  test_fail "fail-fast behavior wrong (rc=${REGREEN_RC})"
  printf '%s\n' "$REGREEN_OUTPUT" >&2
  cat "$CALL_LOG" >&2
  cat "${RUN_DIR}/status.json" >&2 || true
fi

test_start "s037.14.6" "invalid config fails before install shim"
BAD_CONFIG="${TMP_DIR}/bad-regreener-config.yaml"
cp "$CONFIG" "$BAD_CONFIG"
yq -i '.nodes[0].amt_password_ref = "bad/key"' "$BAD_CONFIG"
run_regreen --config "$BAD_CONFIG" --dry-run
if [[ "$REGREEN_RC" -eq 2 && ! -s "$CALL_LOG" ]]; then
  test_pass "central validator rejected config before install call"
else
  test_fail "invalid config reached install shim (rc=${REGREEN_RC})"
  printf '%s\n' "$REGREEN_OUTPUT" >&2
  cat "$CALL_LOG" >&2
fi

runner_summary
