#!/usr/bin/env bash
# Hermetic test for #345 and #338:
#   framework/scripts/rolling-reboot-node-inner.sh must auto-disable HA
#   maintenance on ANY non-zero exit (not just on INT/TERM). The pre-#338
#   trap was INT/TERM-only, so a die() from step b/c/d/e left the
#   cluster in HA maintenance until manual intervention. The pre-#345
#   shape embedded this script as a markdown code block in
#   OPERATIONS.md, which prevented hermetic CI coverage.
#
# Approach:
#   - Inner-script scenarios (TC0-TC7): run rolling-reboot-node-inner.sh
#     under PATH shims that mock ssh + ha-manager + sleep. Inject
#     failures at each step and assert ha-manager ... disable was
#     called before the script exited.
#   - Wrapper scenarios (TC8-TC10): run reboot-node-rolling.sh against
#     a fixture config.yaml + shim ssh/scp. Verify auto-pick of
#     surviving node, target-validation, and SCP/SSH failure propagation.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

INNER_SH="${REPO_ROOT}/framework/scripts/rolling-reboot-node-inner.sh"
WRAPPER_SH="${REPO_ROOT}/framework/scripts/reboot-node-rolling.sh"
REBALANCE_SH="${REPO_ROOT}/framework/scripts/rebalance-cluster.sh"
CIDATA_GUARD_LIB="${REPO_ROOT}/framework/scripts/lib/cidata-guard.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- TC0: both scripts have valid bash syntax ----------------------------

test_start "TC0" "rolling-reboot-node-inner.sh + reboot-node-rolling.sh parse"
if bash -n "$INNER_SH" 2>/tmp/inner-syntax.err; then
  test_pass "TC0a: inner script bash -n passed"
else
  test_fail "TC0a: inner script bash -n failed; see /tmp/inner-syntax.err"
  cat /tmp/inner-syntax.err | sed 's/^/    /'
fi
if bash -n "$WRAPPER_SH" 2>/tmp/wrapper-syntax.err; then
  test_pass "TC0b: wrapper script bash -n passed"
else
  test_fail "TC0b: wrapper script bash -n failed; see /tmp/wrapper-syntax.err"
  cat /tmp/wrapper-syntax.err | sed 's/^/    /'
fi

# Sentinel survives the move from OPERATIONS.md to the framework script.
# A future refactor that strips the MAINT_SH_TEMPLATE marker would not
# fail any other test, but the marker exists as a forward-compat anchor
# for future test extraction tooling. Keep it asserted here so the
# marker doesn't silently rot.
test_start "TC0c" "inner script carries MAINT_SH_TEMPLATE anchor comments"
if grep -q 'MAINT_SH_TEMPLATE -- DO NOT REMOVE' "$INNER_SH" \
   && grep -q 'MAINT_SH_TEMPLATE_END' "$INNER_SH"; then
  test_pass "TC0c: both anchor markers present"
else
  test_fail "TC0c: anchor markers missing — extraction tooling would break"
fi

test_start "TC0d" "wrapper and inner agree on Step-z refusal rc"
INNER_STEP_Z_RC="$(sed -n 's/^STEP_Z_REFUSAL_RC=\([0-9][0-9]*\)$/\1/p' "$INNER_SH" | head -1)"
WRAPPER_STEP_Z_RC="$(sed -n 's/^STEP_Z_REFUSAL_RC=\([0-9][0-9]*\)$/\1/p' "$WRAPPER_SH" | head -1)"
if [[ -n "$INNER_STEP_Z_RC" && "$INNER_STEP_Z_RC" == "$WRAPPER_STEP_Z_RC" ]]; then
  test_pass "TC0d: both scripts use STEP_Z_REFUSAL_RC=${INNER_STEP_Z_RC}"
else
  test_fail "TC0d: STEP_Z_REFUSAL_RC mismatch (inner='${INNER_STEP_Z_RC}', wrapper='${WRAPPER_STEP_Z_RC}')"
fi

test_start "TC0f" "repo cidata guard lib version satisfies both caller minimums"
REPO_GUARD_VERSION="$(sed -n 's/^CIDATA_GUARD_LIB_VERSION="\([0-9][0-9]*\)"$/\1/p' "$CIDATA_GUARD_LIB" | head -1)"
INNER_REQUIRED_GUARD_VERSION="$(sed -n 's/^REQUIRED_CIDATA_GUARD_LIB_VERSION=\([0-9][0-9]*\)$/\1/p' "$INNER_SH" | head -1)"
REBALANCE_REQUIRED_GUARD_VERSION="$(sed -n 's/^REQUIRED_CIDATA_GUARD_LIB_VERSION=\([0-9][0-9]*\)$/\1/p' "$REBALANCE_SH" | head -1)"
if [[ -n "$REPO_GUARD_VERSION" \
      && -n "$INNER_REQUIRED_GUARD_VERSION" \
      && -n "$REBALANCE_REQUIRED_GUARD_VERSION" \
      && "$REPO_GUARD_VERSION" -ge "$INNER_REQUIRED_GUARD_VERSION" \
      && "$REPO_GUARD_VERSION" -ge "$REBALANCE_REQUIRED_GUARD_VERSION" ]]; then
  test_pass "TC0f: cidata-guard.sh version ${REPO_GUARD_VERSION} covers inner>=${INNER_REQUIRED_GUARD_VERSION} and rebalance>=${REBALANCE_REQUIRED_GUARD_VERSION}"
else
  test_fail "TC0f: cidata guard version ratchet failed (repo='${REPO_GUARD_VERSION}', inner-required='${INNER_REQUIRED_GUARD_VERSION}', rebalance-required='${REBALANCE_REQUIRED_GUARD_VERSION}')"
fi

test_start "TC0e" "kernel/rebuild caller guidance points at guarded wrapper and names Step z"
CONFIGURE_KERNEL_SH="${REPO_ROOT}/framework/scripts/configure-node-kernel.sh"
REBUILD_SH="${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"
if grep -qF 'bash /tmp/maint.sh' "$CONFIGURE_KERNEL_SH"; then
  test_fail "TC0e-a: configure-node-kernel.sh still points at /tmp/maint.sh"
else
  test_pass "TC0e-a: configure-node-kernel.sh no longer points at /tmp/maint.sh"
fi
if grep -qF 'framework/scripts/reboot-node-rolling.sh <target-node> [<surviving-node>]' "$CONFIGURE_KERNEL_SH"; then
  test_pass "TC0e-b: configure-node-kernel.sh points at reboot-node-rolling.sh"
else
  test_fail "TC0e-b: configure-node-kernel.sh does not point at reboot-node-rolling.sh"
fi
if grep -qF 'cluster is never left in a' "$REBUILD_SH"; then
  test_fail "TC0e-c: rebuild-cluster.sh still claims maintenance can never be left enabled"
else
  test_pass "TC0e-c: rebuild-cluster.sh removed the false never-left-enabled claim"
fi
if grep -qF 'Step z is the deliberate exception' "$REBUILD_SH" \
   && grep -qF 'distinct refusal code' "$REBUILD_SH"; then
  test_pass "TC0e-d: rebuild-cluster.sh names the Step-z exception"
else
  test_fail "TC0e-d: rebuild-cluster.sh does not name the Step-z exception"
fi

# --- Inner-script harness ------------------------------------------------
#
# Each scenario sets up a fresh SHIM_DIR + LOG file, injects the desired
# failure mode via env vars consumed by the shims, runs the inner
# script, then asserts on the LOG and the script's exit code.

LOG=""
SHIM_DIR=""
LIB_PATH=""
INNER_ARGS=()

setup_shims() {
  SHIM_DIR="$(mktemp -d "${TMP_DIR}/shims.XXXXXX")"
  LOG="${TMP_DIR}/log-$$-$RANDOM"
  : > "$LOG"
  LIB_PATH="${SHIM_DIR}/cidata-guard.sh"
  cp "${REPO_ROOT}/framework/scripts/lib/cidata-guard.sh" "$LIB_PATH"
  INNER_ARGS=(
    pve02
    pve01
    vmstore
    "$LIB_PATH"
    pve01=10.0.0.1
    pve02=10.0.0.2
    pve03=10.0.0.3
  )

  cat > "${SHIM_DIR}/ha-manager" <<EOF
#!/usr/bin/env bash
printf 'ha-manager %s\n' "\$*" >> "$LOG"

status_node_for_vmid() {
  local vmid="\$1"
  if [[ -f "${SHIM_DIR}/maintenance_enabled" || -f "${SHIM_DIR}/relocated_\${vmid}" ]]; then
    printf 'pve01'
  else
    printf 'pve02'
  fi
}

status_state_for_vmid() {
  local vmid="\$1" default_state="\$2"
  if [[ -f "${SHIM_DIR}/relocated_\${vmid}" && -n "\${RELOCATED_HA_STATE:-}" ]]; then
    printf '%s' "\${RELOCATED_HA_STATE}"
  else
    printf '%s' "\${default_state}"
  fi
}

extract_vmid_arg() {
  local arg
  for arg in "\$@"; do
    case "\${arg}" in
      vm:*) printf '%s\n' "\${arg#vm:}"; return 0 ;;
    esac
  done
  echo "ha-manager shim: missing vm:<id> argument in: \$*" >&2
  exit 2
}

emit_status() {
  case "\${HA_STATUS_SCENARIO:-default}" in
    default)
      printf 'service vm:999 (pve03, started)\n'
      ;;
    mixed)
      printf 'service vm:160 (%s, %s)\n' "\$(status_node_for_vmid 160)" "\$(status_state_for_vmid 160 started)"
      printf 'service vm:170 (%s, %s)\n' "\$(status_node_for_vmid 170)" "\$(status_state_for_vmid 170 started)"
      ;;
    stopped_disabled)
      printf 'service vm:171 (pve02, stopped)\n'
      printf 'service vm:172 (pve02, disabled)\n'
      ;;
    error)
      printf 'service vm:160 (pve02, error)\n'
      ;;
    unsupported)
      printf 'service vm:160 (pve02, migrate)\n'
      ;;
    empty)
      ;;
    custom)
      printf '%s\n' "\${HA_STATUS_CUSTOM:-}"
      ;;
    *)
      echo "ha-manager shim: unknown HA_STATUS_SCENARIO=\${HA_STATUS_SCENARIO}" >&2
      exit 2
      ;;
  esac
}

case "\$*" in
  status)
    [[ "\${FAIL_HA_STATUS:-0}" == "1" ]] && exit 1
    emit_status
    exit 0
    ;;
  *"crm-command relocate"*)
    [[ "\${FAIL_RELOCATE:-0}" == "1" ]] && exit 1
    vmid="\$(extract_vmid_arg "\$@")"
    : > "${SHIM_DIR}/relocated_\${vmid}"
    exit 0
    ;;
  *"node-maintenance enable"*)
    [[ "\${FAIL_HA_ENABLE:-0}" == "1" ]] && exit 1
    : > "${SHIM_DIR}/maintenance_enabled"
    ;;
  *"node-maintenance disable"*)
    [[ "\${FAIL_HA_DISABLE:-0}" == "1" ]] && exit 1
    ;;
esac
exit 0
EOF
  chmod +x "${SHIM_DIR}/ha-manager"

  cat > "${SHIM_DIR}/qm" <<EOF
#!/usr/bin/env bash
printf 'qm %s\n' "\$*" >> "$LOG"

owner_node_for_vmid() {
  local vmid="\$1"
  if [[ -f "${SHIM_DIR}/relocated_\${vmid}" ]]; then
    printf 'pve01'
  else
    printf 'pve02'
  fi
}

emit_qm_config() {
  local vmid="\$1"
  [[ "\${FAIL_QM_CONFIG:-0}" == "1" ]] && exit 1
  case " \${UNKNOWN_BALLOON_VMIDS:-} " in
    *" \${vmid} "*) exit 1 ;;
  esac
  case " \${BAD_BALLOON_VMIDS:-} " in
    *" \${vmid} "*) printf 'balloon: not-a-number\n'; exit 0 ;;
  esac
  case " \${BALLOONED_VMIDS:-} " in
    *" \${vmid} "*) printf 'balloon: 8192\nmemory: 32768\n'; exit 0 ;;
  esac
  printf 'balloon: 0\nmemory: 32768\n'
}

case "\$*" in
  config\\ *)
    vmid="\${2:-}"
    owner="\$(owner_node_for_vmid "\${vmid}")"
    if [[ "pve01" != "\${owner}" ]]; then
      echo "Configuration file 'nodes/pve01/qemu-server/\${vmid}.conf' does not exist" >&2
      exit 2
    fi
    emit_qm_config "\${vmid}"
    exit 0
    ;;
esac
echo "qm shim: unexpected args: \$*" >&2
exit 98
EOF
  chmod +x "${SHIM_DIR}/qm"

  cat > "${SHIM_DIR}/zfs" <<EOF
#!/usr/bin/env bash
dataset="\${*: -1}"
zvol="\${dataset##*/}"
node_name="pve01"
printf 'zfs %s local %s\n' "\$1" "\${dataset}" >> "$LOG"
case " \${UNKNOWN_ZVOL_NODES:-} " in
  *" \${node_name} "*) exit 2 ;;
esac
case "\$1" in
  list)
    case " \${PRESENT_ZVOL_NODES:-} " in
      *" \${node_name} "*) printf '%s\n' "\${ZVOL_REFER_BYTES:-18944}"; exit 0 ;;
    esac
    exit 1
    ;;
  destroy)
    printf 'zfs destroy local %s\n' "\${dataset}" >> "$LOG"
    [[ "\${FAIL_ZFS_DESTROY:-0}" == "1" ]] && exit 1
    exit 0
    ;;
esac
echo "zfs shim: unexpected args: \$*" >&2
exit 98
EOF
  chmod +x "${SHIM_DIR}/zfs"

  cat > "${SHIM_DIR}/ssh" <<EOF
#!/usr/bin/env bash
# Last positional arg is the remote command.
remote_cmd="\${*: -1}"
host_arg=""
for a in "\$@"; do
  case "\$a" in
    root@*) host_arg="\${a#root@}"; break ;;
  esac
done
printf 'ssh %s %s\n' "\${host_arg}" "\$remote_cmd" >> "$LOG"

node_name="\${host_arg}"
case "\${host_arg}" in
  10.0.0.1) node_name="pve01" ;;
  10.0.0.2) node_name="pve02" ;;
  10.0.0.3) node_name="pve03" ;;
esac

zvol_from_remote() {
  local rest
  rest="\${remote_cmd#*vmstore/data/}"
  rest="\${rest%%\\'*}"
  rest="\${rest%% *}"
  printf '%s\n' "\${rest}"
}

owner_node_for_vmid() {
  local vmid="\$1"
  if [[ -f "${SHIM_DIR}/relocated_\${vmid}" ]]; then
    printf 'pve01'
  else
    printf 'pve02'
  fi
}

vmid_from_qm_config_remote() {
  local rest
  rest="\${remote_cmd#*qm config }"
  rest="\${rest%% *}"
  rest="\${rest//\\'/}"
  rest="\${rest//\\"/}"
  printf '%s\n' "\${rest}"
}

emit_qm_config() {
  local vmid="\$1"
  [[ "\${FAIL_QM_CONFIG:-0}" == "1" ]] && exit 1
  case " \${UNKNOWN_BALLOON_VMIDS:-} " in
    *" \${vmid} "*) exit 1 ;;
  esac
  case " \${BAD_BALLOON_VMIDS:-} " in
    *" \${vmid} "*) printf 'balloon: not-a-number\n'; exit 0 ;;
  esac
  case " \${BALLOONED_VMIDS:-} " in
    *" \${vmid} "*) printf 'balloon: 8192\nmemory: 32768\n'; exit 0 ;;
  esac
  printf 'balloon: 0\nmemory: 32768\n'
}

case "\$remote_cmd" in
  "qm list")
    # FAIL_QM_LIST=1 simulates ssh failure on every call (the
    # 2026-05-16 T5b pre-check scenario: target unreachable from the
    # start; pre-check at Step 0 dies before HA enable).
    if [[ "\${FAIL_QM_LIST:-0}" == "1" ]]; then
      echo "ssh: connect to host pveXX port 22: No route to host" >&2
      exit 255
    fi
    # FAIL_QM_LIST_AFTER=N succeeds on the first N calls, then fails.
    # Used to exercise the post-enable trap path: pre-check (call 1)
    # succeeds, then a later call inside step b's drain loop fails
    # mid-procedure with MAINT_ENABLED=1, so the trap must auto-disable.
    # Counter is a file (cat-then-echo), NOT concurrent-safe. Safe for
    # current tests because the inner script issues qm-list calls
    # sequentially; if a future test backgrounds inner.sh invocations
    # against the same SHIM_DIR, the counter will need a flock or
    # equivalent.
    COUNTER_FILE="${SHIM_DIR}/qm_call_count"
    CURRENT=0
    [[ -f "\$COUNTER_FILE" ]] && CURRENT=\$(cat "\$COUNTER_FILE")
    NEW=\$((CURRENT + 1))
    echo "\$NEW" > "\$COUNTER_FILE"
    if [[ -n "\${FAIL_QM_LIST_AFTER:-}" ]] \
       && [[ "\$CURRENT" -ge "\${FAIL_QM_LIST_AFTER}" ]]; then
      echo "ssh: connect to host pveXX port 22: No route to host" >&2
      exit 255
    fi
    if [[ "\${QM_LIST_STUCK_RELOCATED:-0}" == "1" ]]; then
      printf '%s\n' "VMID NAME STATUS MEM PID"
      for marker in "${SHIM_DIR}"/relocated_*; do
        [[ -e "\$marker" ]] || continue
        vmid="\${marker##*_}"
        printf '%s stuck-%s running 1024 9999\n' "\$vmid" "\$vmid"
      done
      exit 0
    fi
    # By default return an empty VM list so step b's loop exits
    # immediately. STUB_QM_LIST overrides if needed.
    printf '%s\n' "\${STUB_QM_LIST:-VMID NAME STATUS}"
    exit 0
    ;;
  *"qm config"*)
    vmid="\$(vmid_from_qm_config_remote)"
    owner="\$(owner_node_for_vmid "\${vmid}")"
    if [[ "\${node_name}" != "\${owner}" ]]; then
      echo "Configuration file 'nodes/\${node_name}/qemu-server/\${vmid}.conf' does not exist" >&2
      exit 2
    fi
    emit_qm_config "\${vmid}"
    exit 0
    ;;
  "reboot")
    # Step c always uses '|| true' so this can't fail the script.
    exit 0
    ;;
  *"pvecm status"*)
    # FAIL_QUORUM_POLL simulates step d quorum never returning.
    [[ "\${FAIL_QUORUM_POLL:-0}" == "1" ]] && exit 1
    exit 0
    ;;
  *"zfs list -Hp -o refer"*)
    zvol="\$(zvol_from_remote)"
    printf 'zfs list@%s vmstore/data/%s\n' "\${host_arg}" "\${zvol}" >> "$LOG"
    case " \${UNKNOWN_ZVOL_NODES:-} " in
      *" \${node_name} "*) printf '__rc=2\n'; exit 0 ;;
    esac
    case " \${PRESENT_ZVOL_NODES:-} " in
      *" \${node_name} "*) printf '%s\n__rc=0\n' "\${ZVOL_REFER_BYTES:-18944}"; exit 0 ;;
    esac
    printf '__rc=1\n'
    exit 0
    ;;
  *"zfs destroy"*)
    zvol="\$(zvol_from_remote)"
    printf 'zfs destroy@%s vmstore/data/%s\n' "\${host_arg}" "\${zvol}" >> "$LOG"
    [[ "\${FAIL_ZFS_DESTROY:-0}" == "1" ]] && exit 1
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${SHIM_DIR}/ssh"

  cat > "${SHIM_DIR}/sleep" <<EOF
#!/usr/bin/env bash
# Make the script fast — no real sleeps.
exit 0
EOF
  chmod +x "${SHIM_DIR}/sleep"
}

run_inner() {
  OUT="$(PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" 2>&1)"
  RC=$?
}

assert_disable_called() {
  local case_id="$1"
  if grep -qE 'ha-manager .*node-maintenance disable' "$LOG"; then
    test_pass "$case_id: ha-manager disable was called"
  else
    test_fail "$case_id: ha-manager disable was NOT called (cluster left in maintenance)"
    echo "    LOG:"; sed 's/^/      /' "$LOG"
  fi
}

line_no() {
  local pattern="$1" file="${2:-$LOG}" line
  line="$(grep -nE "$pattern" "$file" | head -1 | cut -d: -f1 || true)"
  [[ -n "$line" ]] || return 1
  printf '%s\n' "$line"
}

assert_log_before() {
  local case_id="$1" before_re="$2" after_re="$3" before_line after_line
  before_line="$(line_no "$before_re")" || {
    test_fail "$case_id: missing earlier event /$before_re/"
    echo "    LOG:"; sed 's/^/      /' "$LOG"
    return
  }
  after_line="$(line_no "$after_re")" || {
    test_fail "$case_id: missing later event /$after_re/"
    echo "    LOG:"; sed 's/^/      /' "$LOG"
    return
  }
  if [[ "$before_line" -lt "$after_line" ]]; then
    test_pass "$case_id"
  else
    test_fail "$case_id: order was $before_line then $after_line"
    echo "    LOG:"; sed 's/^/      /' "$LOG"
  fi
}

assert_no_ha_enable() {
  local case_id="$1"
  if grep -qE 'ha-manager .*node-maintenance enable' "$LOG"; then
    test_fail "$case_id: node-maintenance enable was issued"
    echo "    LOG:"; sed 's/^/      /' "$LOG"
  else
    test_pass "$case_id"
  fi
}

assert_no_ha_disable() {
  local case_id="$1"
  if grep -qE 'ha-manager .*node-maintenance disable' "$LOG"; then
    test_fail "$case_id: node-maintenance disable was issued"
    echo "    LOG:"; sed 's/^/      /' "$LOG"
  else
    test_pass "$case_id"
  fi
}

assert_log_has() {
  local case_id="$1" pattern="$2"
  if grep -qE "$pattern" "$LOG"; then
    test_pass "$case_id"
  else
    test_fail "$case_id"
    echo "    LOG:"; sed 's/^/      /' "$LOG"
  fi
}

assert_log_not_has() {
  local case_id="$1" pattern="$2"
  if grep -qE "$pattern" "$LOG"; then
    test_fail "$case_id"
    echo "    LOG:"; sed 's/^/      /' "$LOG"
  else
    test_pass "$case_id"
  fi
}

# --- TC0g: stale-but-valid cidata guard lib version fails closed --------

test_start "TC0g" "old cidata guard lib version aborts before any ha-manager call"

setup_shims
cat > "$LIB_PATH" <<'OLDLIB'
# shellcheck shell=bash
CIDATA_GUARD_LIB_VERSION="2"
cidata_guard_node_change() { :; }
cidata_ha_service_node() { :; }
cidata_ha_service_state() { :; }
vm_is_ballooned() { :; }
OLDLIB
run_inner
if [[ $RC -ne 0 ]]; then
  test_pass "TC0g-a: old cidata guard lib version returns rc=$RC (non-zero)"
else
  test_fail "TC0g-a: old cidata guard lib version returned rc=0"
fi
if grep -qF "version '2'" <<<"$OUT" && grep -qF "requires >= 3" <<<"$OUT"; then
  test_pass "TC0g-b: error message names observed version and required floor"
else
  test_fail "TC0g-b: error message does not name observed version and required floor"
  echo "    OUT:"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi
if grep -qE 'ha-manager' "$LOG"; then
  test_fail "TC0g-c: ha-manager was called despite old cidata guard lib"
  echo "    LOG:"; sed 's/^/      /' "$LOG"
else
  test_pass "TC0g-c: ha-manager NOT called before old-lib abort"
fi

# --- TC1: success path ---------------------------------------------------

test_start "TC1" "success path: maintenance enabled then disabled, rc=0"

setup_shims
run_inner
if [[ $RC -eq 0 ]]; then
  test_pass "TC1a: success path returns rc=0"
else
  test_fail "TC1a: success path rc=$RC (expected 0)"
  echo "    OUT:"; printf '%s\n' "$OUT" | sed 's/^/      /'
fi
assert_disable_called "TC1b"
if grep -q 'Auto-disabling maintenance' <<<"$OUT"; then
  test_fail "TC1c: success path printed 'Auto-disabling' (trap fired unexpectedly)"
else
  test_pass "TC1c: success path did not print 'Auto-disabling' message"
fi

# --- TC2: step a failure (enable) ---------------------------------------
#
# MAINT_ENABLED=1 is set BEFORE the enable call (so the safety net covers
# partial-apply / signal during enable). The trap fires and calls disable;
# the shim's disable returns 0, so the script ends with rc=1 from the
# original die preserved by the trap.

test_start "TC2" "step a (enable) failure: rc=1, trap attempts safety-net disable"

setup_shims
FAIL_HA_ENABLE=1 PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc2.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
  test_pass "TC2a: step a failure returns rc=$RC (non-zero)"
else
  test_fail "TC2a: step a failure returned rc=0"
fi
assert_disable_called "TC2b"
if grep -q 'Auto-disabling maintenance' "${TMP_DIR}/tc2.out"; then
  test_pass "TC2c: 'Auto-disabling maintenance' diagnostic printed"
else
  test_fail "TC2c: trap fired but did not print 'Auto-disabling' diagnostic"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc2.out"
fi

# --- TC3: Step 0 pre-check ssh failure (the 2026-05-16 T5b race) --------
#
# With the Step 0 pre-check, an ssh failure on the FIRST qm list call
# fires inside the pre-check, BEFORE MAINT_ENABLED=1 and BEFORE the
# `ha-manager enable` call. The trap fires with MAINT_ENABLED=0, so
# no disable is attempted -- AND, more importantly, no ENABLE was ever
# attempted, so no HA migration churn is queued on the target node.
# The original "step b ssh failure → trap auto-disables" path is still
# tested by TC15 (post-pre-check mid-loop failure).

test_start "TC3" "Step 0 pre-check ssh failure: no HA enable, no HA disable, rc!=0"

setup_shims
FAIL_QM_LIST=1 PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc3.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
  test_pass "TC3a: pre-check failure returns rc=$RC (non-zero, error preserved)"
else
  test_fail "TC3a: pre-check failure returned rc=0 (error swallowed!)"
fi
if grep -qE 'ha-manager' "$LOG"; then
  test_fail "TC3b: ha-manager was called despite pre-check failure (race not avoided)"
  echo "    LOG:"; sed 's/^/      /' "$LOG"
else
  test_pass "TC3b: ha-manager NOT called (pre-check correctly aborted before HA enable)"
fi
if grep -q 'Auto-disabling maintenance' "${TMP_DIR}/tc3.out"; then
  test_fail "TC3c: trap printed 'Auto-disabling' but MAINT_ENABLED was never set"
else
  test_pass "TC3c: no spurious 'Auto-disabling' diagnostic (correct: nothing to disable)"
fi
if grep -qE 'cannot read VM state on pve02' "${TMP_DIR}/tc3.out"; then
  test_pass "TC3d: error message names the target node and ssh+qm cause"
else
  test_fail "TC3d: error message did not name target node + cause"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc3.out"
fi

# --- TC4: step d failure (quorum poll timeout) --------------------------

test_start "TC4" "step d (quorum poll timeout) failure: trap auto-disables maintenance"

setup_shims
FAIL_QUORUM_POLL=1 PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc4.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
  test_pass "TC4a: step d failure returns rc=$RC (non-zero)"
else
  test_fail "TC4a: step d failure returned rc=0"
fi
assert_disable_called "TC4b"

# --- TC5: step e failure (disable) --------------------------------------

test_start "TC5" "step e (disable) failure: trap re-attempts disable"

setup_shims
FAIL_HA_DISABLE=1 PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc5.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
  test_pass "TC5a: step e failure returns rc=$RC (non-zero)"
else
  test_fail "TC5a: step e failure returned rc=0"
fi
DISABLE_COUNT=$(grep -cE 'ha-manager .*node-maintenance disable' "$LOG" 2>/dev/null || true)
DISABLE_COUNT="${DISABLE_COUNT:-0}"
if [[ "$DISABLE_COUNT" -ge 2 ]]; then
  test_pass "TC5b: disable was called $DISABLE_COUNT times (step e + trap retry)"
else
  test_fail "TC5b: disable was called $DISABLE_COUNT times (expected >=2: step e + trap)"
fi
if grep -q 'manual cleanup needed' "${TMP_DIR}/tc5.out"; then
  test_pass "TC5c: WARNING with manual-cleanup hint printed"
else
  test_fail "TC5c: WARNING with manual-cleanup hint MISSING"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc5.out"
fi

# --- TC6: structural assertion - EXIT in trap signal set ----------------

test_start "TC6" "inner script trap registers EXIT (not just INT/TERM)"

if grep -qE 'trap[[:space:]]+cleanup[[:space:]]+EXIT' "$INNER_SH"; then
  test_pass "TC6: trap covers EXIT signal"
else
  test_fail "TC6: trap does not cover EXIT — #338 regression risk"
fi

# --- TC6b: bad-args invocation dies before installing the trap ----------
#
# The inner script's `${1:?...}` arg parse runs BEFORE `trap cleanup
# EXIT` is registered. A bad-args invocation should die cleanly with
# rc=1 and never call ha-manager (no logged shim invocations).

test_start "TC6b" "inner script bad-args dies before trap installs (no spurious disable)"

setup_shims
PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" > "${TMP_DIR}/tc6b.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
  test_pass "TC6b-a: missing args returns rc=$RC (non-zero)"
else
  test_fail "TC6b-a: missing args returned rc=0"
fi
if [[ ! -s "$LOG" ]]; then
  test_pass "TC6b-b: no ha-manager/ssh calls made (trap wasn't installed)"
else
  test_fail "TC6b-b: shim was called despite bad args"
  echo "    LOG:"; sed 's/^/      /' "$LOG"
fi

# --- TC6c: awk-failure path inside read_non_stopped_vmids ---------------
#
# If the awk binary is missing or returns non-zero, the inner script's
# explicit `awk_rc` check should die rather than fall through to an
# empty filter (which would mis-conclude "no non-stopped VMs" and
# proceed to reboot a populated node).
#
# With the Step 0 pre-check, the FIRST awk failure happens inside the
# pre-check, BEFORE HA enable. So the trap fires with MAINT_ENABLED=0
# and no disable is expected. The "no-fail-open" guarantee is preserved
# either way (die fires regardless of which step found the failure).

test_start "TC6c" "inner script dies on awk failure (no fail-open, no spurious HA)"

setup_shims
# Override awk to exit non-zero. Place in shim dir which is first on PATH.
cat > "${SHIM_DIR}/awk" <<'EOF'
#!/usr/bin/env bash
echo "INJECTED FAILURE: awk shim returning rc=2" >&2
exit 2
EOF
chmod +x "${SHIM_DIR}/awk"
PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc6c.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
  test_pass "TC6c-a: awk failure returns rc=$RC (non-zero)"
else
  test_fail "TC6c-a: awk failure returned rc=0 (fail-open regression)"
fi
if grep -qE 'VM-state filter \(awk\) failed' "${TMP_DIR}/tc6c.out"; then
  test_pass "TC6c-b: error message names awk as the failure"
else
  test_fail "TC6c-b: error message does not name awk"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc6c.out"
fi
# Pre-check fired the awk failure → HA was never enabled → no disable.
if grep -qE 'ha-manager' "$LOG"; then
  test_fail "TC6c-c: ha-manager was called despite pre-check awk failure"
  echo "    LOG:"; sed 's/^/      /' "$LOG"
else
  test_pass "TC6c-c: ha-manager NOT called (pre-check caught awk failure before HA enable)"
fi

# --- TC7: SIGTERM during step b drain loop ------------------------------
#
# Regression guard for the bug that motivated the trap-split fix: when
# a signal arrives while bash is waiting on `sleep 10` inside step b's
# drain loop, the EXIT trap's `local rc=$?` is 0 (the rc of the just-
# returned sleep, not the signal), which would defeat the rc-based
# guard. The fix installs dedicated signal handlers that `exit 130`
# (INT) / `exit 143` (TERM) before the EXIT trap runs.
#
# Why SIGTERM and not SIGINT: bash inherits SIG_IGN for SIGINT from a
# parent that backgrounded the script with `&`, and `trap 'cmd' INT`
# in the child does NOT override SIG_IGN once inherited. This quirk
# does not apply to interactive operator Ctrl-C (the original failure
# mode) — the terminal's job control delivers SIGINT to the foreground
# pgroup normally and the trap fires. SIGTERM exercises the same trap
# code path as SIGINT for the regression guard.

test_start "TC7" "SIGTERM during step b drain loop: trap auto-disables maintenance (rc=143 regression guard)"

setup_shims
# TC7/TC7d need a REAL sleep in Step b's drain loop so the signal races
# an actual pause, not a spinning `exit 0` stub. Hardcoding `/bin/sleep`
# breaks on NixOS (only /bin/sh exists — sleep lives at
# /run/current-system/sw/bin/sleep via the system profile), producing a
# tight hot-spin that turns signal delivery into a timing race under CI
# load. Resolve the real path at setup time — the harness's own PATH
# still has real coreutils here, before SHIM_DIR takes over.
REAL_SLEEP="$(command -v sleep)"
if [[ -z "$REAL_SLEEP" ]]; then
  echo "FATAL: TC7 setup could not resolve real 'sleep' via command -v" >&2
  exit 1
fi
cat > "${SHIM_DIR}/sleep" <<EOF
#!/usr/bin/env bash
exec "$REAL_SLEEP" "\$@"
EOF
chmod +x "${SHIM_DIR}/sleep"

STUB_QM_LIST="VMID NAME   STATUS  MEM PID
100 maint-tc7  running 1024 9999" \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc7.out" 2>&1 &
INNER_PID=$!
sleep 1.5
kill -TERM "$INNER_PID" 2>/dev/null
WAITED=0
while kill -0 "$INNER_PID" 2>/dev/null; do
  sleep 1
  WAITED=$((WAITED + 1))
  if [[ $WAITED -ge 20 ]]; then
    kill -9 "$INNER_PID" 2>/dev/null
    break
  fi
done
wait "$INNER_PID" 2>/dev/null
RC=$?
if [[ $RC -eq 143 ]]; then
  test_pass "TC7a: SIGTERM returns rc=143 (signal-encoded, non-zero)"
elif [[ $RC -ne 0 && $WAITED -lt 20 ]]; then
  test_pass "TC7a: SIGTERM returns rc=$RC (non-zero — acceptable, ideally 143)"
else
  test_fail "TC7a: SIGTERM returned rc=$RC (regression risk or test hung)"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc7.out"
fi
assert_disable_called "TC7b"
if grep -q 'Auto-disabling maintenance' "${TMP_DIR}/tc7.out"; then
  test_pass "TC7c: 'Auto-disabling maintenance' diagnostic printed after SIGTERM"
else
  test_fail "TC7c: trap fired but did not print 'Auto-disabling' diagnostic"
fi

# --- TC7d: SIGHUP during step b drain loop ------------------------------
#
# Regression guard for the codex-reviewer finding: the wrapper's
# operator-Ctrl-C path tears down the local ssh, which surfaces remotely
# as SIGHUP (not SIGTERM). Without an explicit `trap 'exit 129' HUP`,
# bash's default HUP action is "terminate," and while the EXIT trap
# still runs, the rc captured is whatever the interrupted sleep returned
# (0) — defeating the rc-based auto-disable guard. Empirically
# reproduced with /tmp/test-hup-trap.sh before fix.

test_start "TC7d" "SIGHUP during step b drain loop: trap auto-disables (codex P1 regression guard)"

setup_shims
# Same sleep-shim rationale as TC7 above — see comment there. Hardcoded
# /bin/sleep breaks on NixOS and turns the drain loop into a hot-spin,
# which made this case fail on cicd runner under I/O pressure from
# concurrent DR-test activity (see pipeline #1286 RCA, 2026-07-05).
REAL_SLEEP="$(command -v sleep)"
if [[ -z "$REAL_SLEEP" ]]; then
  echo "FATAL: TC7d setup could not resolve real 'sleep' via command -v" >&2
  exit 1
fi
cat > "${SHIM_DIR}/sleep" <<EOF
#!/usr/bin/env bash
exec "$REAL_SLEEP" "\$@"
EOF
chmod +x "${SHIM_DIR}/sleep"

STUB_QM_LIST="VMID NAME   STATUS  MEM PID
100 maint-tc7d running 1024 9999" \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc7d.out" 2>&1 &
INNER_PID=$!
sleep 1.5
kill -HUP "$INNER_PID" 2>/dev/null
WAITED=0
while kill -0 "$INNER_PID" 2>/dev/null; do
  sleep 1
  WAITED=$((WAITED + 1))
  if [[ $WAITED -ge 20 ]]; then
    kill -9 "$INNER_PID" 2>/dev/null
    break
  fi
done
wait "$INNER_PID" 2>/dev/null
RC=$?
if [[ $RC -eq 129 ]]; then
  test_pass "TC7d-a: SIGHUP returns rc=129 (signal-encoded)"
elif [[ $RC -ne 0 && $WAITED -lt 20 ]]; then
  test_pass "TC7d-a: SIGHUP returns rc=$RC (non-zero — acceptable, ideally 129)"
else
  test_fail "TC7d-a: SIGHUP returned rc=$RC (regression risk or test hung)"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc7d.out"
fi
assert_disable_called "TC7d-b"
if grep -q 'Auto-disabling maintenance' "${TMP_DIR}/tc7d.out"; then
  test_pass "TC7d-c: 'Auto-disabling maintenance' diagnostic printed after SIGHUP"
else
  test_fail "TC7d-c: trap fired but did not print 'Auto-disabling' diagnostic"
fi

# --- Wrapper harness -----------------------------------------------------
#
# The wrapper invokes scp + ssh against IPs read from site/config.yaml.
# To test it hermetically we:
#   - Build a fixture config.yaml with a 3-node nodes[] section.
#   - Shim scp/ssh/yq via PATH so the wrapper's transport calls are
#     captured to a log file. The ssh shim simulates pvecm-status
#     responses based on env vars.
#   - Invoke the wrapper with various target/surviving combinations.

wrapper_setup() {
  WTMP="${TMP_DIR}/wrapper-$$-$RANDOM"
  WLOG="${WTMP}/log"
  WCONFIG_DIR="${WTMP}/repo/site"
  WSCRIPT_DIR="${WTMP}/repo/framework/scripts"
  mkdir -p "$WTMP" "$WCONFIG_DIR" "$WSCRIPT_DIR/lib"
  : > "$WLOG"

  cat > "${WCONFIG_DIR}/config.yaml" <<'EOF'
proxmox:
  storage_pool: vmstore
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
  - name: pve02
    mgmt_ip: 10.0.0.2
  - name: pve03
    mgmt_ip: 10.0.0.3
EOF

  # Copy the real inner + wrapper into the fixture repo layout so the
  # wrapper's REPO_ROOT/CONFIG/INNER_SCRIPT resolution targets fixture
  # data rather than the real repo.
  cp "$INNER_SH" "${WSCRIPT_DIR}/rolling-reboot-node-inner.sh"
  cp "$WRAPPER_SH" "${WSCRIPT_DIR}/reboot-node-rolling.sh"
  cp "${REPO_ROOT}/framework/scripts/lib/cidata-guard.sh" "${WSCRIPT_DIR}/lib/cidata-guard.sh"
  chmod +x "${WSCRIPT_DIR}/"*

  WSHIM_DIR="${WTMP}/shims"
  mkdir -p "$WSHIM_DIR"

  cat > "${WSHIM_DIR}/ssh" <<EOF
#!/usr/bin/env bash
# Record what was asked, then succeed/fail per env vars.
printf 'ssh %s\n' "\$*" >> "$WLOG"
# Reachability/quorum probe: 'pvecm status | grep -q ...'
# Per-node-IP failure simulation via FAIL_SSH_PVECM_<lastoctet>.
last_arg="\${*: -1}"
host_arg=""
for a in "\$@"; do
  case "\$a" in
    root@*) host_arg="\${a#root@}"; break;;
  esac
done
host_last=\${host_arg##*.}
if [[ "\$last_arg" == *"pvecm status"* ]]; then
  var="FAIL_SSH_PVECM_\${host_last}"
  if [[ "\${!var:-0}" == "1" ]]; then
    exit 1
  fi
  exit 0
fi
# Other ssh invocations (rm -f cleanup; bash inner.sh) succeed unless
# WRAPPER_FAIL_INNER_SSH or WRAPPER_INNER_RC is set.
if [[ "\${WRAPPER_FAIL_INNER_SSH:-0}" == "1" && "\$last_arg" == *"bash "* ]]; then
  exit 22
fi
if [[ -n "\${WRAPPER_INNER_RC:-}" && "\$last_arg" == *"bash "* ]]; then
  exit "\${WRAPPER_INNER_RC}"
fi
# Inner ssh-bash invocation: report rc=0 silently. Don't actually run
# the inner script (we test the inner separately in TC1-7).
exit 0
EOF
  chmod +x "${WSHIM_DIR}/ssh"

  cat > "${WSHIM_DIR}/scp" <<EOF
#!/usr/bin/env bash
printf 'scp %s\n' "\$*" >> "$WLOG"
if [[ "\${WRAPPER_FAIL_SCP:-0}" == "1" ]]; then
  exit 1
fi
exit 0
EOF
  chmod +x "${WSHIM_DIR}/scp"

  # yq: pass through to the real binary against the fixture file.
  # We don't shim yq; the wrapper reads it through normal PATH.
}

run_wrapper() {
  WOUT="$(PATH="$WSHIM_DIR:$PATH" bash "${WSCRIPT_DIR}/reboot-node-rolling.sh" "$@" 2>&1)"
  WRC=$?
}

# --- TC8: wrapper auto-picks surviving node from config.yaml -------------

test_start "TC8" "wrapper auto-picks first reachable+quorate node != target"

wrapper_setup
run_wrapper pve02
if [[ $WRC -eq 0 ]]; then
  test_pass "TC8a: wrapper exited rc=0 with auto-pick"
else
  test_fail "TC8a: wrapper exited rc=$WRC (expected 0)"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
fi
# Auto-pick should land on pve01 (first node != pve02 in config order)
# and we should see scp + ssh-bash invocations against 10.0.0.1.
if grep -qE 'scp .*10\.0\.0\.1:' "$WLOG"; then
  test_pass "TC8b: scp targeted auto-picked surviving node (pve01 / 10.0.0.1)"
else
  test_fail "TC8b: scp did not target auto-picked surviving node"
  echo "    LOG:"; sed 's/^/      /' "$WLOG"
fi
if grep -qE 'ssh .*root@10\.0\.0\.1.*bash.*pve02.*pve01' "$WLOG"; then
  test_pass "TC8c: ssh-bash invoked inner with correct target/surviving args"
else
  test_fail "TC8c: ssh-bash did not invoke inner with expected args"
  echo "    LOG:"; sed 's/^/      /' "$WLOG"
fi

# --- TC9: wrapper validates target is in config.yaml --------------------

test_start "TC9" "wrapper rejects target not in config.yaml nodes[]"

wrapper_setup
run_wrapper pveXX
if [[ $WRC -ne 0 ]]; then
  test_pass "TC9a: wrapper rejected unknown target (rc=$WRC)"
else
  test_fail "TC9a: wrapper accepted unknown target (rc=0)"
fi
if grep -qE "'pveXX' not found in config.yaml" <<<"$WOUT"; then
  test_pass "TC9b: error message names the offending target"
else
  test_fail "TC9b: error message did not name the offending target"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
fi

# --- TC10: SCP failure propagates as non-zero rc ------------------------

test_start "TC10" "wrapper propagates scp failure as non-zero rc with named cause"

wrapper_setup
WRAPPER_FAIL_SCP=1 run_wrapper pve02
if [[ $WRC -ne 0 ]]; then
  test_pass "TC10a: scp failure returned rc=$WRC (non-zero)"
else
  test_fail "TC10a: scp failure returned rc=0"
fi
if grep -qE 'scp of inner script .* failed' <<<"$WOUT"; then
  test_pass "TC10b: error message identifies scp as the failure"
else
  test_fail "TC10b: error message did not identify scp"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
fi

# --- TC10b: wrapper handles Step-z refusal rc specially -----------------

test_start "TC10b" "wrapper prints Step-z remediation for distinct rc=3"

wrapper_setup
WRAPPER_INNER_RC=3 run_wrapper pve02
if [[ $WRC -eq 3 ]]; then
  test_pass "TC10b-a: wrapper propagated Step-z refusal rc=3"
else
  test_fail "TC10b-a: wrapper returned rc=$WRC (expected 3)"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
fi
if grep -qF 'Step z refused' <<<"$WOUT" \
   && grep -qF 'cleanup-orphan-cidata.sh --dry-run' <<<"$WOUT" \
   && grep -qF 'realign-cidata.sh --dry-run --vmid <vmid>' <<<"$WOUT"; then
  test_pass "TC10b-b: wrapper printed Step-z remediation"
else
  test_fail "TC10b-b: wrapper did not print Step-z remediation"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
fi
if grep -qF "If pve02 is shown in maintenance, run:" <<<"$WOUT"; then
  test_fail "TC10b-c: wrapper printed old blanket-disable footer"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
else
  test_pass "TC10b-c: wrapper did not print old blanket-disable footer"
fi

# --- TC11: wrapper rejects target==surviving (operator-typo guard) ------

test_start "TC11" "wrapper rejects <target> == <surviving>"

wrapper_setup
run_wrapper pve02 pve02
if [[ $WRC -ne 0 ]]; then
  test_pass "TC11a: wrapper rejected same-node (rc=$WRC)"
else
  test_fail "TC11a: wrapper accepted same-node (rc=0)"
fi
if grep -qE 'must be different' <<<"$WOUT"; then
  test_pass "TC11b: error message explains target/surviving must differ"
else
  test_fail "TC11b: error message did not explain"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
fi

# --- TC12: wrapper fails closed when no surviving node is reachable -----

test_start "TC12" "wrapper fails closed when all candidates fail quorum probe"

wrapper_setup
FAIL_SSH_PVECM_1=1 FAIL_SSH_PVECM_3=1 run_wrapper pve02
if [[ $WRC -ne 0 ]]; then
  test_pass "TC12a: wrapper failed closed (rc=$WRC)"
else
  test_fail "TC12a: wrapper proceeded with no reachable surviving node"
fi
if grep -qE 'no reachable.quorate surviving' <<<"$WOUT"; then
  test_pass "TC12b: error message names the diagnosis"
else
  test_fail "TC12b: error message did not name the diagnosis"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
fi

# --- TC13: wrapper accepts operator-provided surviving node (happy path) -

test_start "TC13" "wrapper accepts explicit <surviving-node> happy path"

wrapper_setup
run_wrapper pve02 pve03
if [[ $WRC -eq 0 ]]; then
  test_pass "TC13a: explicit surviving accepted (rc=0)"
else
  test_fail "TC13a: explicit surviving rejected (rc=$WRC)"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
fi
if grep -qE 'ssh .*root@10\.0\.0\.3.*bash.*pve02.*pve03' "$WLOG"; then
  test_pass "TC13b: ssh-bash routed via explicit surviving (pve03 / 10.0.0.3)"
else
  test_fail "TC13b: ssh-bash did not route via explicit surviving"
  echo "    LOG:"; sed 's/^/      /' "$WLOG"
fi

# --- TC14: wrapper rejects shell-metachar in target name ----------------
#
# Regression guard for the sub-claude P1: a target name containing a
# single quote would close the single-quoted interpolation in
# `bash '<target>' '<surviving>'` and execute arbitrary commands on
# the surviving node. The wrapper validates names against
# HOSTNAME_REGEX before doing anything dangerous; this test asserts the
# guard fires.

test_start "TC14" "wrapper rejects shell-metachar in <target-node>"

wrapper_setup
# Use a bash escape so the literal quote reaches the wrapper argv.
run_wrapper "pve02'; touch /tmp/INJECTION_PROOF_345 #"
if [[ $WRC -ne 0 ]]; then
  test_pass "TC14a: wrapper rejected target with shell metachar (rc=$WRC)"
else
  test_fail "TC14a: wrapper accepted target with shell metachar"
fi
if grep -qE 'does not match strict hostname regex' <<<"$WOUT"; then
  test_pass "TC14b: error message names the hostname-regex guard"
else
  test_fail "TC14b: error message did not name the hostname regex"
  echo "    OUT:"; printf '%s\n' "$WOUT" | sed 's/^/      /'
fi
if [[ -e /tmp/INJECTION_PROOF_345 ]]; then
  test_fail "TC14c: injection-proof file was created (regex guard bypassed!)"
  rm -f /tmp/INJECTION_PROOF_345
else
  test_pass "TC14c: no injection-proof file created"
fi

# --- TC15: post-pre-check step b ssh failure (trap regression guard) ----
#
# The 2026-05-16 T5b race is caught at Step 0 by the pre-check. But the
# original "step b ssh failure → trap auto-disables" path (#338) still
# matters for failures that happen AFTER the pre-check succeeds. This
# test covers the simplest such case: pre-check passes (target was
# reachable), step a's HA enable runs, then the FIRST iteration of
# step b's drain loop fails on ssh. In this scenario MAINT_ENABLED=1
# (enable succeeded), so the trap MUST fire the auto-disable arm.
#
# Shim setup: FAIL_QM_LIST_AFTER=1 means call 1 (pre-check) succeeds,
# call 2+ fails. STUB_QM_LIST returns a running VM (any non-empty body
# works since step b dies on call 2 before reading STUB content). The
# call sequence is:
#   call 1: pre-check succeeds (returns STUB_QM_LIST content, discarded)
#   call 2: step b iteration 1 hits FAIL_QM_LIST_AFTER -> ssh rc=255 ->
#           read_non_stopped_vmids dies -> trap fires -> disable issued

test_start "TC15" "post-pre-check step b ssh failure: trap fires #338 auto-disable"

setup_shims
FAIL_QM_LIST_AFTER=1 \
STUB_QM_LIST="VMID NAME      STATUS  MEM PID
100 maint-tc15 running 1024 9999" \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc15.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
  test_pass "TC15a: post-pre-check failure returns rc=$RC (non-zero)"
else
  test_fail "TC15a: post-pre-check failure returned rc=0 (regression)"
fi
# Pre-check succeeded; step a (enable) ran; trap MUST have called disable.
if grep -qE 'ha-manager .*node-maintenance enable' "$LOG"; then
  test_pass "TC15b: ha-manager enable ran (pre-check passed, step a fired)"
else
  test_fail "TC15b: ha-manager enable did NOT run (pre-check should have passed)"
  echo "    LOG:"; sed 's/^/      /' "$LOG"
fi
assert_disable_called "TC15c"
if grep -q 'Auto-disabling maintenance' "${TMP_DIR}/tc15.out"; then
  test_pass "TC15d: 'Auto-disabling maintenance' diagnostic printed"
else
  test_fail "TC15d: trap fired but did not print 'Auto-disabling' diagnostic"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc15.out"
fi
# Strictness: prove the failure was from read_non_stopped_vmids
# specifically (not some other future code path that might be added
# between step a and step b). The die() emits "cannot read VM state on
# $N (ssh+qm rc=...)" from read_non_stopped_vmids when ssh fails.
if grep -qE 'cannot read VM state on pve02' "${TMP_DIR}/tc15.out"; then
  test_pass "TC15e: failure was diagnosed as read_non_stopped_vmids ssh+qm die"
else
  test_fail "TC15e: failure source was not read_non_stopped_vmids ssh+qm (refactor regression?)"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc15.out"
fi

# --- TC16: Step a0 + Step z happy path for started VMs ------------------

test_start "TC16" "Step a0 guards before enable, relocates ballooned VMs, and Step z guards failback"

setup_shims
HA_STATUS_SCENARIO=mixed \
BALLOONED_VMIDS=160 \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc16.out" 2>&1
RC=$?
if [[ $RC -eq 0 ]]; then
  test_pass "TC16a: mixed started VM path exits rc=0"
else
  test_fail "TC16a: mixed started VM path rc=$RC (expected 0)"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc16.out"
fi
assert_log_before "TC16b: Step a0 guard probes before maintenance enable" \
  'zfs list local vmstore/data/vm-160-cloudinit' \
  'ha-manager crm-command node-maintenance enable'
assert_log_has "TC16c: Step a0 swept local non-owner pve01" \
  'zfs list local vmstore/data/vm-160-cloudinit'
assert_log_has "TC16d: Step a0 swept remote non-owner pve03" \
  'zfs list@10\.0\.0\.3 vmstore/data/vm-160-cloudinit'
assert_log_before "TC16e: owner pve02 was not probed until Step z" \
  'ha-manager crm-command node-maintenance enable' \
  'zfs list@10\.0\.0\.2 vmstore/data/vm-160-cloudinit'
assert_log_has "TC16f: ballooned VM 160 was relocated off N" \
  'ha-manager crm-command relocate vm:160 pve01'
assert_log_not_has "TC16g: fixed VM 170 was not relocated" \
  'ha-manager crm-command relocate vm:170'
if grep -qF 'relocated ballooned VMs are gone from pve02' "${TMP_DIR}/tc16.out"; then
  test_pass "TC16h: relocated ballooned VM was verified gone"
else
  test_fail "TC16h: relocated ballooned VM was not verified gone"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc16.out"
fi
assert_log_before "TC16i: Step z guards VM 160 destination N before disable" \
  'zfs list@10\.0\.0\.2 vmstore/data/vm-160-cloudinit' \
  'ha-manager crm-command node-maintenance disable'
assert_log_before "TC16j: Step z guards VM 170 destination N before disable" \
  'zfs list@10\.0\.0\.2 vmstore/data/vm-170-cloudinit' \
  'ha-manager crm-command node-maintenance disable'

# --- TC17: Step a0 stopped/disabled state table -------------------------

test_start "TC17" "Step a0 guards stopped/disabled services without relocate or wait"

setup_shims
HA_STATUS_SCENARIO=stopped_disabled \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc17.out" 2>&1
RC=$?
if [[ $RC -eq 0 ]]; then
  test_pass "TC17a: stopped/disabled path exits rc=0"
else
  test_fail "TC17a: stopped/disabled path rc=$RC (expected 0)"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc17.out"
fi
assert_log_has "TC17b: stopped VM 171 was guarded" \
  'zfs list@10\.0\.0\.3 vmstore/data/vm-171-cloudinit'
assert_log_has "TC17c: disabled VM 172 was guarded" \
  'zfs list@10\.0\.0\.3 vmstore/data/vm-172-cloudinit'
assert_log_not_has "TC17d: stopped/disabled VMs were not relocated" \
  'ha-manager crm-command relocate vm:17[12]'
if grep -qF 'verifying relocated ballooned VMs' "${TMP_DIR}/tc17.out"; then
  test_fail "TC17e: stopped/disabled path waited for relocated VMs"
else
  test_pass "TC17e: stopped/disabled path did not enter relocate wait"
fi
if grep -qF 'vm:171: guarding failback destination pve02.' "${TMP_DIR}/tc17.out"; then
  test_pass "TC17f: stopped VM 171 was included in Step z guard set"
else
  test_fail "TC17f: stopped VM 171 was not included in Step z guard set"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc17.out"
fi
if grep -qF 'vm:172: guarding failback destination pve02.' "${TMP_DIR}/tc17.out"; then
  test_pass "TC17g: disabled VM 172 was included in Step z guard set"
else
  test_fail "TC17g: disabled VM 172 was not included in Step z guard set"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc17.out"
fi

# --- TC18: Step a0 fail-closed before maintenance enable ----------------

test_start "TC18" "Step a0 guard failure aborts before maintenance enable"

setup_shims
HA_STATUS_SCENARIO=mixed \
BALLOONED_VMIDS=160 \
UNKNOWN_ZVOL_NODES=pve03 \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc18.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
  test_pass "TC18a: guard failure returns rc=$RC (non-zero)"
else
  test_fail "TC18a: guard failure returned rc=0"
fi
assert_no_ha_enable "TC18b: Step a0 failure issued no node-maintenance enable"
assert_log_not_has "TC18c: Step a0 failure queued no relocate" \
  'ha-manager crm-command relocate'
if grep -qF 'fail-closed' "${TMP_DIR}/tc18.out"; then
  test_pass "TC18d: output names fail-closed guard behavior"
else
  test_fail "TC18d: output did not name fail-closed guard behavior"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc18.out"
fi

# --- TC19: bounded Step a0 relocate verification ------------------------

test_start "TC19" "Step a0 relocate verification is bounded"

setup_shims
HA_STATUS_SCENARIO=mixed \
BALLOONED_VMIDS=160 \
MYCOFU_A0_RELOCATE_TIMEOUT=0 \
STUB_QM_LIST="VMID NAME      STATUS  MEM PID
160 stuck-160 running 1024 9999" \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc19.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]]; then
  test_pass "TC19a: unplaceable relocated VM returns rc=$RC (non-zero)"
else
  test_fail "TC19a: unplaceable relocated VM returned rc=0"
fi
assert_log_has "TC19b: ballooned VM relocate was issued before bounded verify failed" \
  'ha-manager crm-command relocate vm:160 pve01'
assert_no_ha_enable "TC19c: bounded Step a0 failure issued no node-maintenance enable"
if grep -qF 'after 0s' "${TMP_DIR}/tc19.out"; then
  test_pass "TC19d: failure message reports the configured cap"
else
  test_fail "TC19d: failure message did not report the configured cap"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc19.out"
fi

# --- TC19b: relocated VM must be HA-started off N -----------------------

test_start "TC19b" "Step a0 fails immediately when relocated ballooned VM enters HA error"

setup_shims
HA_STATUS_SCENARIO=mixed \
BALLOONED_VMIDS=160 \
RELOCATED_HA_STATE=error \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc19b.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]] && grep -qF 'entered HA error state after pre-maintenance relocate' "${TMP_DIR}/tc19b.out"; then
  test_pass "TC19b-a: HA error after relocate aborts immediately"
else
  test_fail "TC19b-a: HA error after relocate did not abort as expected"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc19b.out"
fi
assert_no_ha_enable "TC19b-b: HA error after relocate issued no node-maintenance enable"
if grep -qF 'realign-cidata.sh --dry-run --vmid 160' "${TMP_DIR}/tc19b.out"; then
  test_pass "TC19b-c: failure routes to realign-cidata.sh"
else
  test_fail "TC19b-c: failure did not route to realign-cidata.sh"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc19b.out"
fi

# --- TC20: Step a0 HA state table refuses unsafe states -----------------

test_start "TC20" "Step a0 refuses HA error, unsupported, and unreadable states"

setup_shims
HA_STATUS_SCENARIO=error \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc20-error.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]] && grep -qF 'realign-cidata.sh --dry-run --vmid 160' "${TMP_DIR}/tc20-error.out"; then
  test_pass "TC20a: HA error aborts and routes to realign-cidata.sh"
else
  test_fail "TC20a: HA error did not abort with realign-cidata.sh route"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc20-error.out"
fi
assert_no_ha_enable "TC20b: HA error issued no node-maintenance enable"

setup_shims
HA_STATUS_SCENARIO=unsupported \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc20-unsupported.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]] && grep -qF "transient or unsupported" "${TMP_DIR}/tc20-unsupported.out"; then
  test_pass "TC20c: unsupported HA state aborts"
else
  test_fail "TC20c: unsupported HA state did not abort"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc20-unsupported.out"
fi
assert_no_ha_enable "TC20d: unsupported HA state issued no node-maintenance enable"

setup_shims
HA_STATUS_SCENARIO=empty \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc20-empty.out" 2>&1
RC=$?
if [[ $RC -ne 0 ]] && grep -qF "ha-manager status returned empty output" "${TMP_DIR}/tc20-empty.out"; then
  test_pass "TC20e: unreadable/empty HA status aborts"
else
  test_fail "TC20e: unreadable/empty HA status did not abort"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc20-empty.out"
fi
assert_no_ha_enable "TC20f: unreadable HA status issued no node-maintenance enable"

# --- TC21: Step z fail-closed suppresses disable and trap disable -------

test_start "TC21" "Step z guard failure leaves maintenance enabled by design"

setup_shims
HA_STATUS_SCENARIO=mixed \
BALLOONED_VMIDS=160 \
UNKNOWN_ZVOL_NODES=pve02 \
  PATH="$SHIM_DIR:$PATH" bash "$INNER_SH" "${INNER_ARGS[@]}" > "${TMP_DIR}/tc21.out" 2>&1
RC=$?
if [[ $RC -eq 3 ]]; then
  test_pass "TC21a: Step z guard failure returns rc=3"
elif [[ $RC -ne 0 ]]; then
  test_fail "TC21a: Step z guard failure returned rc=$RC (expected distinct rc=3)"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc21.out"
else
  test_fail "TC21a: Step z guard failure returned rc=0"
fi
assert_log_has "TC21b: maintenance enable happened before Step z failure" \
  'ha-manager crm-command node-maintenance enable'
assert_no_ha_disable "TC21c: Step z failure issued no node-maintenance disable"
if grep -qF 'Auto-disabling maintenance' "${TMP_DIR}/tc21.out"; then
  test_fail "TC21d: EXIT trap auto-disabled maintenance after Step z failure"
else
  test_pass "TC21d: EXIT trap did not auto-disable after Step z failure"
fi
if grep -qF 'Refusing to disable HA maintenance' "${TMP_DIR}/tc21.out" \
   && grep -qF 'cleanup-orphan-cidata.sh --dry-run' "${TMP_DIR}/tc21.out"; then
  test_pass "TC21e: Step z failure prints explicit remediation"
else
  test_fail "TC21e: Step z failure remediation missing"
  echo "    OUT:"; sed 's/^/      /' "${TMP_DIR}/tc21.out"
fi

runner_summary
