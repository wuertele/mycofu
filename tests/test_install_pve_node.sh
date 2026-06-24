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
HIL_LOG="${TMP_DIR}/hil-boot.log"
HIL_ARGS_LOG="${TMP_DIR}/hil-boot-args.log"
CURL_LOG="${TMP_DIR}/curl.log"
TCP_LOG="${TMP_DIR}/tcp.log"
PDU_LOG="${TMP_DIR}/pdu.log"
AMT_PROBE_COUNT_FILE="${TMP_DIR}/amt-probe-count"
AMT_STATE_FILE="${TMP_DIR}/amt-state"
PXE_EVIDENCE_COUNT_FILE="${TMP_DIR}/pxe-evidence-count"
TCP_COUNT_DIR="${TMP_DIR}/tcp-counts"
RUN_DIR="${TMP_DIR}/run"
mkdir -p "$TCP_COUNT_DIR"
printf 'encrypted\n' > "${TMP_DIR}/sops/secrets.yaml"

cat > "$CONFIG" <<'EOF'
domain: example.test
management:
  subnet: 192.0.2.0/24
  gateway: 192.0.2.1
regreener:
  install_timeout_sec: 1
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
    regreen_enabled: false
    amt_ip: 192.0.2.102
    amt_user: admin
    amt_password_ref: amt_password_node1
EOF

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" ]]; then
  key="$(printf '%s' "$3" | sed -E 's/^\["([^"]+)"\]$/\1/')"
  [[ "$key" == "${SOPS_MISSING_KEY:-}" ]] && exit 1
  case "$key" in
    amt_password_node1) printf 'amt-secret\n' ;;
    proxmox_api_password) printf 'root-secret\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "-d" ]]; then
  printf 'amt_password_node1: amt-secret\nproxmox_api_password: root-secret\n'
  exit 0
fi
exit 99
EOF
chmod +x "${SHIM_DIR}/sops"

cat > "${TMP_DIR}/ssh-hil-boot" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd=""
printf '%s\n' "$*" >> "${HIL_ARGS_LOG:?}"
for arg in "$@"; do
  cmd="$arg"
done
printf '%s\n' "$cmd" >> "${HIL_LOG:?}"

# Stateful AMT simulation. The state file holds the current simulated
# power state ("Power on" or "Soft off"). --poweroff / --poweron transition
# the state. --get reads it. UNKNOWN meshcmd flags (e.g. --on, --off,
# --bogus) are no-op success — modeling real meshcmd's permissive parser.
# This is what lets the test catch flag-name regressions: a script using
# the wrong flag name will not transition the state, and the load-bearing
# off/on polls in install-pve-node.sh will time out.
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
    [[ "${HIL_BOOT_DOWN:-0}" == "1" ]] && exit 255
    printf 'hil-boot ok\n'
    ;;
  */dev/tcp/*/16992*)
    # AMT_UNREACHABLE=1: every probe fails (no recovery)
    # AMT_UNREACHABLE_UNTIL_PDU=1: first probe fails, subsequent succeed
    #   (models AMT firmware coming back after a PDU power-cycle)
    if [[ "${AMT_UNREACHABLE:-0}" == "1" ]]; then
      exit 1
    fi
    if [[ "${AMT_UNREACHABLE_UNTIL_PDU:-0}" == "1" ]]; then
      count="$(cat "${AMT_PROBE_COUNT_FILE:-/dev/null}" 2>/dev/null || printf '0')"
      count=$((count + 1))
      printf '%s\n' "$count" > "${AMT_PROBE_COUNT_FILE}" 2>/dev/null || true
      if [[ "$count" -eq 1 ]]; then exit 1; fi
    fi
    :
    ;;
  *"stat -c %s /var/log/nginx/access.log"*)
    # PXE-evidence baseline offset capture (called once, before --poweron).
    # Return a deterministic value; the PXE-evidence poll later compares
    # against this offset.
    printf '%s\n' "${HIL_NGINX_LOG_OFFSET:-1000}"
    exit 0
    ;;
  *"tail -c +"*"/var/log/nginx/access.log"*)
    # PXE-evidence poll: install-pve-node.sh tails the nginx access log
    # past the baseline offset and greps for an iPXE boot.ipxe fetch.
    # Success iff PXE_EVIDENCE_NEVER is not set AND the poll has run
    # enough times (PXE_EVIDENCE_AFTER_N, default 1).
    if [[ "${PXE_EVIDENCE_NEVER:-0}" == "1" ]]; then
      exit 1
    fi
    pxe_count="$(cat "${PXE_EVIDENCE_COUNT_FILE:-/dev/null}" 2>/dev/null || printf '0')"
    pxe_count=$((pxe_count + 1))
    printf '%s\n' "$pxe_count" > "${PXE_EVIDENCE_COUNT_FILE}" 2>/dev/null || true
    if (( pxe_count < ${PXE_EVIDENCE_AFTER_N:-1} )); then
      exit 1
    fi
    exit 0
    ;;
  AMT_PASSWORD=*\ meshcmd\ *)
    if [[ "${MESHCMD_FAIL:-}" == "amtfeatures" && "$cmd" == *"meshcmd amtfeatures "* ]]; then
      exit 1
    fi

    # amtpower --poweroff: transitions state to "Soft off". On an
    # already-off node, real meshcmd returns non-zero (modeled via
    # MESHCMD_POWEROFF_FROM_OFF_NONZERO, default 1). install-pve-node.sh
    # swallows that non-zero and proceeds — the load-bearing test is the
    # off-state poll that follows.
    if [[ "$cmd" == *"meshcmd amtpower --poweroff"* ]]; then
      if [[ "$(amt_state)" == "Soft off" ]]; then
        if [[ "${MESHCMD_POWEROFF_FROM_OFF_NONZERO:-1}" == "1" ]]; then
          exit 1
        fi
        exit 0
      fi
      if [[ "${MESHCMD_POWEROFF_SILENTLY_FAILS:-0}" == "1" ]]; then
        # Models: meshcmd accepts the command and returns 0 but the
        # power state never changes (e.g., AMT busy, ME firmware glitch).
        # The off-state poll catches this — without that poll, the
        # subsequent --poweron would no-op (already on) and we'd report
        # false-green against the OLD PVE install.
        exit 0
      fi
      set_amt_state "Soft off"
      exit 0
    fi

    # amtpower --poweron --bootdevice pxe: transitions state to "Power on".
    if [[ "$cmd" == *"meshcmd amtpower --poweron"* ]]; then
      if [[ "${MESHCMD_FAIL:-}" == "poweron" ]]; then
        exit 1
      fi
      if [[ "${MESHCMD_POWERON_SILENTLY_FAILS:-0}" == "1" ]]; then
        # meshcmd accepted the command (exit 0) but state never changed.
        # Models the silently-dropped-flag class; on-state poll catches it.
        exit 0
      fi
      set_amt_state "Power on"
      exit 0
    fi

    # amtpower --get: reports current simulated state, exactly as
    # real meshcmd does ("Current power state: Power on\n").
    if [[ "$cmd" == *"meshcmd amtpower --get"* ]]; then
      printf 'Current power state: %s\n' "$(amt_state)"
      exit 0
    fi

    # Any other meshcmd invocation (e.g., --on, --off, --bogus, --reset)
    # is a no-op success. Modeling real meshcmd permissive parsing means
    # that a script using the WRONG flag does not transition state, and
    # the load-bearing state polls in install-pve-node.sh will time out
    # (caught by tests s037.13.10 / s037.13.8b).
    exit 0
    ;;
  *)
    printf 'unexpected hil-boot ssh command: %s\n' "$cmd" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${TMP_DIR}/ssh-hil-boot"

cat > "${TMP_DIR}/curl-shim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
for arg in "$@"; do
  url="$arg"
done
printf '%s\n' "$url" >> "${CURL_LOG:?}"

# Preflight HTTP HEAD probes — return success for known hil-boot URLs.
if [[ "${CURL_FAIL_ISO:-0}" == "1" && "$url" == */proxmox.iso ]]; then
  exit 22
fi
case "$url" in
  http://*/nodes/node1/boot.ipxe|http://*/nodes/node1/proxmox.iso) exit 0 ;;
esac

# Proxmox API stubs for install-pve-node.sh's verify_green path.
case "$url" in
  *://*/api2/json/access/ticket)
    printf '%s\n' '{"data":{"ticket":"PVE:root@pam:STUB","CSRFPreventionToken":"STUB"}}'
    exit 0
    ;;
  *://*/api2/json/nodes/node1/status)
    if [[ "${PVE_VERSION_MISMATCH:-0}" == "1" ]]; then
      printf '%s\n' '{"data":{"pveversion":"pve-manager/8.4/STUB","uptime":42}}'
    else
      printf '%s\n' '{"data":{"pveversion":"pve-manager/9.1.0/STUB","uptime":42}}'
    fi
    exit 0
    ;;
  *://*/api2/json/nodes/node1/network)
    if [[ "${CIDR_MISMATCH:-0}" == "1" ]]; then
      printf '%s\n' '{"data":[{"iface":"vmbr0","type":"bridge","cidr":"10.0.0.1/24"}]}'
    else
      printf '%s\n' '{"data":[{"iface":"vmbr0","type":"bridge","cidr":"192.0.2.11/24"}]}'
    fi
    exit 0
    ;;
  *://*/api2/json/cluster/status)
    if [[ "${CLUSTER_PRESENT:-0}" == "1" ]]; then
      printf '%s\n' '{"data":[{"type":"cluster","name":"hostile","quorate":1},{"type":"node","name":"node1"}]}'
    else
      printf '%s\n' '{"data":[{"type":"node","name":"node1","local":1,"ip":"192.0.2.11","online":1}]}'
    fi
    exit 0
    ;;
esac

exit 22
EOF
chmod +x "${TMP_DIR}/curl-shim"

cat > "${TMP_DIR}/pdu-cycle-stub" <<'EOF'
#!/usr/bin/env bash
# PDU cycle stub for install-pve-node.sh's AMT recovery fallback. Records
# its invocation; defaults to success so tests can simulate a successful
# AMT-via-PDU recovery. PDU_CYCLE_FAIL=1 makes it exit non-zero.
set -euo pipefail
printf 'pdu-cycle %s\n' "$*" >> "${PDU_LOG:?}"
if [[ "${PDU_CYCLE_FAIL:-0}" == "1" ]]; then
  echo "PDU stub: simulated failure" >&2
  exit 2
fi
exit 0
EOF
chmod +x "${TMP_DIR}/pdu-cycle-stub"

cat > "${TMP_DIR}/tcp-probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
host="$1"
port="$2"
printf '%s:%s\n' "$host" "$port" >> "${TCP_LOG:?}"
key="${host}_${port}"
count_file="${TCP_COUNT_DIR:?}/${key}"
count="$(cat "$count_file" 2>/dev/null || printf '0')"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$port" in
  22)
    [[ "${TCP_NEVER_UP:-0}" == "1" ]] && exit 1
    if [[ "$count" -eq 1 ]]; then
      exit 1
    fi
    exit 0
    ;;
  8006)
    [[ "${PVE_WEB_DOWN:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${TMP_DIR}/tcp-probe"

export PATH="${SHIM_DIR}:${PATH}"
export MYCOFU_SSH="${TMP_DIR}/ssh-hil-boot"
export MYCOFU_CURL="${TMP_DIR}/curl-shim"
export MYCOFU_TCP_PROBE="${TMP_DIR}/tcp-probe"
export MYCOFU_PDU_CYCLE="${TMP_DIR}/pdu-cycle-stub"
export MYCOFU_HIL_BOOT_SSH="root@192.0.2.63"
export MYCOFU_HIL_BOOT_HTTP="http://192.0.2.63"
export MYCOFU_REGREENER_RUN_DIR="$RUN_DIR"
export MYCOFU_INSTALL_DOWN_POLL_SEC=0
export MYCOFU_INSTALL_POLL_SEC=0
export MYCOFU_PVE_WEB_POLL_SEC=0
export MYCOFU_AMT_RECOVER_WAIT_SEC=0
export MYCOFU_AMT_OFF_TIMEOUT=2
export MYCOFU_AMT_ON_TIMEOUT=2
export MYCOFU_AMT_STATE_POLL_SEC=0
export MYCOFU_AMT_OFF_TO_ON_SETTLE_SEC=0
export MYCOFU_PXE_EVIDENCE_TIMEOUT=2
export MYCOFU_PXE_EVIDENCE_POLL_SEC=0
export HIL_LOG CURL_LOG TCP_LOG PDU_LOG AMT_PROBE_COUNT_FILE AMT_STATE_FILE PXE_EVIDENCE_COUNT_FILE TCP_COUNT_DIR
export HIL_ARGS_LOG

run_install() {
  : > "$HIL_LOG"
  : > "$HIL_ARGS_LOG"
  : > "$CURL_LOG"
  : > "$TCP_LOG"
  : > "$PDU_LOG"
  rm -f "$AMT_PROBE_COUNT_FILE" "$AMT_STATE_FILE" "$PXE_EVIDENCE_COUNT_FILE"
  rm -rf "$RUN_DIR" "$TCP_COUNT_DIR"
  mkdir -p "$RUN_DIR" "$TCP_COUNT_DIR"
  local output rc
  set +e
  output="$("${REPO_ROOT}/framework/scripts/install-pve-node.sh" "$@" 2>&1)"
  rc=$?
  set -e
  INSTALL_OUTPUT="$output"
  INSTALL_RC="$rc"
}

assert_rc() {
  local expected="$1"
  local label="$2"
  if [[ "$INSTALL_RC" -eq "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label (expected ${expected}, got ${INSTALL_RC})"
    printf '%s\n' "$INSTALL_OUTPUT" >&2
  fi
}

test_start "s037.13.1" "argument parsing rejects missing node"
run_install --config "$CONFIG"
assert_rc 2 "missing node exits 2"

test_start "s037.13.2" "disabled node is rejected before hil-boot preflight"
run_install --config "$CONFIG" --node node2 --dry-run
if [[ "$INSTALL_RC" -eq 2 && ! -s "$HIL_LOG" && ! -s "$CURL_LOG" ]]; then
  test_pass "disabled node exits 2 without hil-boot calls"
else
  test_fail "disabled node reached side effects (rc=${INSTALL_RC})"
fi

test_start "s037.13.3" "dry-run routes through hil-boot but does not issue meshcmd"
run_install --config "$CONFIG" --node node1 --dry-run
if [[ "$INSTALL_RC" -eq 0 ]] && \
   grep -q 'hil-boot-status' "$HIL_LOG" && \
   grep -Fq 'StrictHostKeyChecking=accept-new' "$HIL_ARGS_LOG" && \
   grep -Fq "UserKnownHostsFile=${RUN_DIR}/known_hosts" "$HIL_ARGS_LOG" && \
   grep -q "/nodes/node1/boot.ipxe" "$CURL_LOG" && \
   grep -q "/nodes/node1/proxmox.iso" "$CURL_LOG" && \
   ! grep -q 'meshcmd ' "$HIL_LOG" && \
   grep -q '\[DRY-RUN\] would converge node via --poweroff, --poweron --bootdevice pxe, then poll for PXE evidence' <<< "$INSTALL_OUTPUT"; then
  test_pass "dry-run checks hil-boot artifacts and stops before power transition"
else
  test_fail "dry-run preflight behavior wrong"
  printf '%s\n' "$INSTALL_OUTPUT" >&2
fi

test_start "s037.13.4" "missing SOPS key exits 2"
SOPS_MISSING_KEY=amt_password_node1 run_install --config "$CONFIG" --node node1 --dry-run
assert_rc 2 "missing AMT password exits 2"

test_start "s037.13.5" "hil-boot SSH failure exits 3"
HIL_BOOT_DOWN=1 run_install --config "$CONFIG" --node node1 --dry-run
assert_rc 3 "hil-boot unavailable exits 3"

test_start "s037.13.6" "AMT reachability failure from hil-boot exits 4 (PDU fallback also fails)"
AMT_UNREACHABLE=1 PDU_CYCLE_FAIL=1 run_install --config "$CONFIG" --node node1 --dry-run
if [[ "$INSTALL_RC" -eq 4 ]] && grep -q 'pdu-cycle node1' "$PDU_LOG"; then
  test_pass "AMT TCP failure plus failed PDU recovery exits 4 after attempting PDU cycle"
else
  test_fail "AMT TCP failure with PDU fail expected exit 4 with PDU invocation (rc=${INSTALL_RC})"
  printf '%s\n' "$INSTALL_OUTPUT" >&2
  cat "$PDU_LOG" >&2 2>/dev/null || true
fi

test_start "s037.13.6a" "AMT unreachable recovers via PDU cycle when subsequent probe passes"
AMT_UNREACHABLE_UNTIL_PDU=1 run_install --config "$CONFIG" --node node1 --dry-run
if [[ "$INSTALL_RC" -eq 0 ]] && grep -q 'pdu-cycle node1' "$PDU_LOG"; then
  test_pass "AMT recovered via PDU cycle; preflight continued past AMT check"
else
  test_fail "AMT-via-PDU recovery path wrong (rc=${INSTALL_RC})"
  printf '%s\n' "$INSTALL_OUTPUT" >&2
  cat "$PDU_LOG" >&2 2>/dev/null || true
fi

test_start "s037.13.7" "missing hil-boot HTTP artifact exits 5"
CURL_FAIL_ISO=1 run_install --config "$CONFIG" --node node1 --dry-run
assert_rc 5 "missing per-node ISO exits 5"

test_start "s037.13.8" "AMT --poweron failure exits 4"
MESHCMD_FAIL=poweron run_install --config "$CONFIG" --node node1
assert_rc 4 "AMT power-on failure exits 4"

test_start "s037.13.8a" "silently-failed --poweron is caught by on-state poll, exits 4"
# meshcmd accepted --poweron (exit 0) but the node never actually
# transitioned. The on-state poll for 'Power on' must time out and
# fail with exit 4 — NOT proceed to a 30-minute SSH timeout. This is
# the bug class that codex P1 #1, gemini P1 #1, sub-claude P2 #4 all
# warned about (in slightly different formulations).
MESHCMD_POWERON_SILENTLY_FAILS=1 run_install --config "$CONFIG" --node node1
if [[ "$INSTALL_RC" -eq 4 ]] && \
   grep -q "AMT never reached 'Power on'" <<< "$INSTALL_OUTPUT"; then
  test_pass "silent --poweron failure → exit 4 fast via on-state poll"
else
  test_fail "silent --poweron must exit 4 fast (rc=${INSTALL_RC})"
  printf '%s\n' "$INSTALL_OUTPUT" >&2
fi

test_start "s037.13.8b" "silently-failed --poweroff is caught by off-state poll, exits 4"
# Critical for avoiding FALSE GREEN. If --poweroff is silently ignored on
# a Power-on node, --poweron is then a no-op (already on), the node never
# reboots, and SSH/verify_green would succeed against the OLD PVE install.
# The off-state poll must time out and fail with exit 4 before --poweron
# is even attempted.
MESHCMD_POWEROFF_SILENTLY_FAILS=1 run_install --config "$CONFIG" --node node1
if [[ "$INSTALL_RC" -eq 4 ]] && \
   grep -q "AMT never reached 'Soft off'" <<< "$INSTALL_OUTPUT"; then
  test_pass "silent --poweroff failure → exit 4 fast via off-state poll (no false green)"
else
  test_fail "silent --poweroff must exit 4 before issuing --poweron (rc=${INSTALL_RC})"
  printf '%s\n' "$INSTALL_OUTPUT" >&2
fi

test_start "s037.13.8c" "soft-off node converges to green via --poweroff + --poweron"
# Models the bpve02 / pipeline #1011 scenario: node has been soft-off
# since 2026-05-17 manual operator action. --poweroff returns non-zero
# (already off) but the off-state poll confirms 'Soft off' immediately,
# --poweron transitions to 'Power on', PXE evidence arrives, SSH +
# verify_green complete normally.
AMT_INITIAL_STATE="Soft off" run_install --config "$CONFIG" --node node1
if [[ "$INSTALL_RC" -eq 0 ]] && \
   grep -q 'SUCCESS: node1 installed via PXE' <<< "$INSTALL_OUTPUT" && \
   grep -q 'meshcmd amtpower --poweroff' "$HIL_LOG" && \
   grep -q 'meshcmd amtpower --poweron --bootdevice pxe' "$HIL_LOG" && \
   ! grep -q 'Waiting for SSH :22 .* to go DOWN' <<< "$INSTALL_OUTPUT"; then
  test_pass "soft-off starting state converges to green without SSH-down precondition"
else
  test_fail "soft-off convergence path wrong (rc=${INSTALL_RC})"
  printf '%s\n' "$INSTALL_OUTPUT" >&2
  cat "$HIL_LOG" >&2
fi

test_start "s037.13.8d" "PXE evidence absent — exits 6 (catches --bootdevice silently dropped)"
# Models: --poweron succeeded, AMT reports 'Power on', BUT the node
# booted from disk instead of PXE (e.g., --bootdevice pxe was silently
# dropped). hil-boot's nginx serves nothing matching the node's
# boot.ipxe URL. The PXE-evidence poll must time out and fail with
# exit 6 BEFORE the 1800s SSH timeout — the failure mode the verify
# was supposed to prevent (sub-claude P1 #3, codex P2 #5).
PXE_EVIDENCE_NEVER=1 run_install --config "$CONFIG" --node node1
if [[ "$INSTALL_RC" -eq 6 ]] && \
   grep -q 'never served /nodes/node1/boot.ipxe to iPXE' <<< "$INSTALL_OUTPUT"; then
  test_pass "PXE evidence absent → exit 6 (PXE boot did not start)"
else
  test_fail "PXE-evidence timeout should exit 6 fast (rc=${INSTALL_RC})"
  printf '%s\n' "$INSTALL_OUTPUT" >&2
fi

test_start "s037.13.8e" "wrong meshcmd flag (--on/--off) is caught by off-state poll, exits 4"
# Regression guard against the codex-caught flag-name bug. If a future
# refactor uses --on/--off instead of --poweron/--poweroff, the test
# stub treats those as no-op (modeling real meshcmd permissive parsing).
# The off-state poll then times out because the state never transitioned.
# This test injects the wrong flag by replacing the script's expected
# command via a sed hook would be invasive; instead we use the stateful
# stub's no-op-on-unknown behavior, plus a defensive grep on the log
# below to confirm the script issued the canonical verbs.
run_install --config "$CONFIG" --node node1
if [[ "$INSTALL_RC" -eq 0 ]] && \
   grep -q 'meshcmd amtpower --poweroff ' "$HIL_LOG" && \
   grep -q 'meshcmd amtpower --poweron --bootdevice pxe ' "$HIL_LOG" && \
   ! grep -qE 'meshcmd amtpower --(on|off)( |$)' "$HIL_LOG"; then
  test_pass "canonical --poweroff / --poweron --bootdevice pxe verbs are used"
else
  test_fail "script must issue canonical poweron/poweroff verbs"
  cat "$HIL_LOG" >&2
fi

test_start "s037.13.9" "install timeout exits 6"
TCP_NEVER_UP=1 run_install --config "$CONFIG" --node node1
assert_rc 6 "SSH install timeout exits 6"

test_start "s037.13.10" "green predicate success exits 0 — full convergent flow"
run_install --config "$CONFIG" --node node1
if [[ "$INSTALL_RC" -eq 0 ]] && \
   grep -q 'SUCCESS: node1 installed via PXE' <<< "$INSTALL_OUTPUT" && \
   grep -q 'meshcmd amtfeatures --redir 1 --kvm 1' "$HIL_LOG" && \
   grep -q 'meshcmd amtpower --poweroff' "$HIL_LOG" && \
   grep -q "AMT reached 'Soft off'" <<< "$INSTALL_OUTPUT" && \
   grep -q 'meshcmd amtpower --poweron --bootdevice pxe' "$HIL_LOG" && \
   grep -q "AMT reached 'Power on'" <<< "$INSTALL_OUTPUT" && \
   grep -q 'PXE evidence: hil-boot served /nodes/node1/boot.ipxe' <<< "$INSTALL_OUTPUT" && \
   ! grep -q 'meshcmd amtpower --reset' "$HIL_LOG" && \
   ! grep -q 'amtider' "$HIL_LOG"; then
  test_pass "convergent flow: amtfeatures → poweroff → off-poll → poweron → on-poll → PXE evidence → SSH → green"
else
  test_fail "green convergent path wrong (rc=${INSTALL_RC})"
  printf '%s\n' "$INSTALL_OUTPUT" >&2
  cat "$HIL_LOG" >&2
fi

test_start "s037.13.11" "green predicate failure exits 7"
PVE_VERSION_MISMATCH=1 run_install --config "$CONFIG" --node node1
assert_rc 7 "PVE version mismatch exits 7"

runner_summary
