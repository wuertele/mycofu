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
RUN_DIR="${TMP_DIR}/run"
EVENT_LOG="${TMP_DIR}/events.log"
TCP_COUNT_DIR="${TMP_DIR}/tcp-counts"
printf 'encrypted\n' > "${TMP_DIR}/sops/secrets.yaml"

cat > "$CONFIG" <<'EOF'
domain: example.test
management:
  subnet: 192.0.2.0/24
regreener:
  install_timeout_sec: 3
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
    amt_password_ref: amt_password_node1
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
  - name: node2
    mgmt_ip: 192.0.2.12
    regreen_enabled: true
    amt_ip: 192.0.2.102
    amt_user: admin
    amt_password_ref: amt_password_node1
    install_nic_driver: e1000e
    install_disk_id_path: pci-0000:00:1d.0-nvme-1
EOF

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" ]]; then
  key="$(printf '%s' "$3" | sed -E 's/^\["([^"]+)"\]$/\1/')"
  case "$key" in
    amt_password_node1) printf 'amt-secret\n' ;;
    proxmox_api_password) printf 'root-secret\n' ;;
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

cat > "${TMP_DIR}/ssh-hil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd=""
for arg in "$@"; do
  cmd="$arg"
done
amt_state() {
  if [[ -s "${AMT_STATE_FILE:-/dev/null}" ]]; then
    cat "${AMT_STATE_FILE}"
  else
    printf '%s\n' "${AMT_INITIAL_STATE:-Power on}"
  fi
}
set_amt_state() {
  printf '%s\n' "$1" > "${AMT_STATE_FILE}" 2>/dev/null || true
}

case "$cmd" in
  hil-boot-status)
    printf 'hil-status\n' >> "${EVENT_LOG:?}"
    ;;
  */dev/tcp/*/16992*)
    printf 'amt-tcp\n' >> "${EVENT_LOG:?}"
    ;;
  *"stat -c %s /var/log/nginx/access.log"*)
    printf 'nginx-offset\n' >> "${EVENT_LOG:?}"
    printf '%s\n' "${HIL_NGINX_LOG_OFFSET:-1000}"
    ;;
  *"tail -c +"*"/var/log/nginx/access.log"*)
    printf 'pxe-evidence\n' >> "${EVENT_LOG:?}"
    if [[ "${PXE_EVIDENCE_NEVER:-0}" == "1" ]]; then
      exit 1
    fi
    ;;
  AMT_PASSWORD=*\ meshcmd\ *)
    if [[ "$cmd" == *"amtider"* ]]; then
      printf 'unexpected-amtider\n' >> "${EVENT_LOG:?}"
      exit 90
    fi
    if [[ "$cmd" == *"meshcmd amtfeatures"* ]]; then
      printf 'amtfeatures\n' >> "${EVENT_LOG:?}"
    elif [[ "$cmd" == *"meshcmd amtpower --poweroff"* ]]; then
      printf 'power-off\n' >> "${EVENT_LOG:?}"
      if [[ -n "${MESHCMD_FAIL_HOST:-}" && "$cmd" == *"--host '${MESHCMD_FAIL_HOST}'"* ]]; then
        exit 1
      fi
      if [[ "$(amt_state)" == "Soft off" ]]; then
        # Already off — real meshcmd returns non-zero; install-pve-node.sh
        # swallows that and proceeds to the off-state poll.
        exit 1
      fi
      set_amt_state "Soft off"
    elif [[ "$cmd" == *"meshcmd amtpower --poweron"* ]]; then
      printf 'power-on\n' >> "${EVENT_LOG:?}"
      if [[ -n "${MESHCMD_FAIL_HOST:-}" && "$cmd" == *"--host '${MESHCMD_FAIL_HOST}'"* ]]; then
        exit 1
      fi
      set_amt_state "Power on"
    elif [[ "$cmd" == *"meshcmd amtpower --get"* ]]; then
      printf 'power-get\n' >> "${EVENT_LOG:?}"
      printf 'Current power state: %s\n' "$(amt_state)"
    else
      printf 'unexpected-meshcmd %s\n' "$cmd" >&2
      exit 91
    fi
    ;;
  *)
    printf 'unexpected hil command: %s\n' "$cmd" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${TMP_DIR}/ssh-hil"

cat > "${TMP_DIR}/curl-ok" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
for arg in "$@"; do
  url="$arg"
done
printf 'http %s\n' "$url" >> "${EVENT_LOG:?}"
case "$url" in
  *://*/api2/json/access/ticket)
    printf '%s\n' '{"data":{"ticket":"PVE:root@pam:STUB","CSRFPreventionToken":"STUB"}}' ;;
  *://*/api2/json/nodes/node1/status)
    printf '%s\n' '{"data":{"pveversion":"pve-manager/9.1.0/STUB","uptime":42}}' ;;
  *://*/api2/json/nodes/node1/network)
    printf '%s\n' '{"data":[{"iface":"vmbr0","type":"bridge","cidr":"192.0.2.11/24"}]}' ;;
  *://*/api2/json/cluster/status)
    printf '%s\n' '{"data":[{"type":"node","name":"node1","local":1,"online":1}]}' ;;
esac
exit 0
EOF
chmod +x "${TMP_DIR}/curl-ok"

cat > "${TMP_DIR}/tcp-state" <<'EOF'
#!/usr/bin/env bash
# Convergent flow drops wait_for_ssh_down — SSH is polled only for UP.
# First call returns "still pending" (exit 1, models post-reboot kernel
# coming up); subsequent calls succeed.
set -euo pipefail
host="$1"
port="$2"
mkdir -p "${TCP_COUNT_DIR:?}"
if [[ "$port" == "22" ]]; then
  file="${TCP_COUNT_DIR}/${host}_${port}"
  count="$(cat "$file" 2>/dev/null || printf '0')"
  count=$((count + 1))
  printf '%s\n' "$count" > "$file"
  if (( count == 1 )); then
    printf 'ssh-pending\n' >> "${EVENT_LOG:?}"
    exit 1
  fi
  printf 'ssh-up\n' >> "${EVENT_LOG:?}"
  exit 0
fi
if [[ "$port" == "8006" ]]; then
  printf 'pve-web\n' >> "${EVENT_LOG:?}"
  exit 0
fi
exit 0
EOF
chmod +x "${TMP_DIR}/tcp-state"

AMT_STATE_FILE="${TMP_DIR}/amt-state"
export PATH="${SHIM_DIR}:${PATH}"
export EVENT_LOG TCP_COUNT_DIR AMT_STATE_FILE
export MYCOFU_SSH="${TMP_DIR}/ssh-hil"
export MYCOFU_CURL="${TMP_DIR}/curl-ok"
export MYCOFU_TCP_PROBE="${TMP_DIR}/tcp-state"
export MYCOFU_HIL_BOOT_SSH="root@192.0.2.63"
export MYCOFU_HIL_BOOT_HTTP="http://192.0.2.63"
export MYCOFU_INSTALL_POLL_SEC=0
export MYCOFU_PVE_WEB_POLL_SEC=0
export MYCOFU_AMT_STATE_POLL_SEC=0
export MYCOFU_AMT_OFF_TIMEOUT=2
export MYCOFU_AMT_ON_TIMEOUT=2
export MYCOFU_AMT_OFF_TO_ON_SETTLE_SEC=0
export MYCOFU_PXE_EVIDENCE_TIMEOUT=2
export MYCOFU_PXE_EVIDENCE_POLL_SEC=0

run_regreen() {
  : > "$EVENT_LOG"
  rm -f "$AMT_STATE_FILE"
  rm -rf "$RUN_DIR" "$TCP_COUNT_DIR"
  mkdir -p "$RUN_DIR" "$TCP_COUNT_DIR"
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

test_start "s037.15.1" "stub PXE state machine reaches green through real scripts"
run_regreen --config "$CONFIG" --node node1
expected="${TMP_DIR}/expected-events.log"
cat > "$expected" <<'EOF'
hil-status
amt-tcp
http http://192.0.2.63/nodes/node1/boot.ipxe
http http://192.0.2.63/nodes/node1/proxmox.iso
amtfeatures
power-get
nginx-offset
power-off
power-get
power-on
power-get
pxe-evidence
ssh-pending
ssh-up
pve-web
http https://192.0.2.11:8006/api2/json/access/ticket
http https://192.0.2.11:8006/api2/json/nodes/node1/status
http https://192.0.2.11:8006/api2/json/nodes/node1/network
http https://192.0.2.11:8006/api2/json/cluster/status
EOF

if [[ "$REGREEN_RC" -eq 0 ]] && \
   diff -u "$expected" "$EVENT_LOG" >/dev/null && \
   jq -e '.nodes.node1.state == "green" and .outcome == "green"' "${RUN_DIR}/status.json" >/dev/null && \
   ! grep -q 'amtider' "$EVENT_LOG"; then
  test_pass "convergent PXE path completed in order without IDER or --reset"
else
  test_fail "stub e2e sequence failed (rc=${REGREEN_RC})"
  printf '%s\n' "$REGREEN_OUTPUT" >&2
  cat "$EVENT_LOG" >&2
  cat "${RUN_DIR}/status.json" >&2 || true
fi

test_start "s037.15.2" "first-node AMT failure stops before second node"
MESHCMD_FAIL_HOST=192.0.2.101 run_regreen --config "$CONFIG"
if [[ "$REGREEN_RC" -eq 4 ]] && \
   grep -qE '^power-(off|on)$' "$EVENT_LOG" && \
   ! grep -q '/nodes/node2/' "$EVENT_LOG" && \
   jq -e '.nodes.node1.state == "failed" and .nodes.node1.exit_code == 4 and .nodes.node2.state == "not-attempted" and .outcome == "failed"' "${RUN_DIR}/status.json" >/dev/null; then
  test_pass "fail-fast path recorded node2 as not-attempted"
else
  test_fail "fail-fast e2e path wrong (rc=${REGREEN_RC})"
  printf '%s\n' "$REGREEN_OUTPUT" >&2
  cat "$EVENT_LOG" >&2
  cat "${RUN_DIR}/status.json" >&2 || true
fi

runner_summary
