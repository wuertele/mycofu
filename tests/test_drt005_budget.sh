#!/usr/bin/env bash
# test_drt005_budget.sh — Static + fixture guard for the DRT-005 recovery
# budget and universal failover predicate (Sprint 048 / T6.6).
#
# DRT-005 is a live, destructive, operator-attended test — it cannot run in CI.
# This hermetic guard instead asserts, at the SOURCE level, that the budget
# mechanism and the post-recovery assertions are present and have not silently
# regressed to older clocks or state-class-scoped predicates. It is a ratchet:
# if a future edit drops membership_loss_t0, the 600s first-run ceiling, the
# mode selector, the policy-off empty SKIP, either post-recovery assertion, or
# the mechanism-present pre-check, this test fails.
#
# Rationale for the current gate (see DRT-005-node-failure.sh header):
#   - First-run mode: recovery_end - membership_loss_t0 must be <600s.
#   - Budget mode: measured bands are deferred to MR-7 and supplied by env.
#   - BASELINE_VM_COUNT remains documentary only in first-run mode.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

DRT="${REPO_ROOT}/framework/dr-tests/tests/DRT-005-node-failure.sh"
COMMON="${REPO_ROOT}/framework/dr-tests/lib/common.sh"

# --- Basic sanity: files parse ---
test_start "DB.0" "DRT-005 and common.sh parse (bash -n)"
if bash -n "$DRT" 2>/dev/null; then
  test_pass "DB.0: DRT-005-node-failure.sh is syntactically valid"
else
  test_fail "DB.0: DRT-005-node-failure.sh has a syntax error"
fi
if bash -n "$COMMON" 2>/dev/null; then
  test_pass "DB.0: common.sh is syntactically valid"
else
  test_fail "DB.0: common.sh has a syntax error"
fi

# --- Assertion helpers ---
# assert_grep_file: fixed-string search in a named file.
assert_grep_file() {
  local file="$1" needle="$2" detail="$3"
  if grep -qF -- "$needle" "$file"; then
    test_pass "$detail"
  else
    test_fail "$detail (missing: '${needle}' in ${file##*/})"
  fi
}
assert_grep_file_re() {
  local file="$1" pattern="$2" detail="$3"
  if grep -qE -- "$pattern" "$file"; then
    test_pass "$detail"
  else
    test_fail "$detail (no line matching /${pattern}/ in ${file##*/})"
  fi
}
assert_absent_file() {
  local file="$1" needle="$2" detail="$3"
  if grep -qF -- "$needle" "$file"; then
    test_fail "$detail (unexpected: '${needle}' still present in ${file##*/})"
  else
    test_pass "$detail"
  fi
}

field_from_fixture() {
  local fixture="$1" key="$2"
  grep -m1 -E "^${key}=" "$fixture" | sed 's/^[^=]*=//' || true
}

csv_contains() {
  local csv="$1" needle="$2"
  [[ ",${csv}," == *",${needle},"* ]]
}

drt005_eval_fixture() {
  local fixture="$1"
  local mode="${DRT005_MODE:-first-run}"
  local failures=0

  local membership recovery duration
  membership=$(field_from_fixture "$fixture" "membership_loss_t0")
  recovery=$(field_from_fixture "$fixture" "recovery_end")
  if [[ -z "${membership// /}" ]]; then
    echo "FAIL: missing membership_loss_t0"
    return 1
  fi
  if [[ ! "$membership" =~ ^[0-9]+$ ]]; then
    echo "FAIL: membership_loss_t0 is not numeric: ${membership}"
    return 1
  fi
  if [[ -z "${recovery// /}" ]]; then
    echo "FAIL: missing recovery_end"
    return 1
  fi
  if [[ ! "$recovery" =~ ^[0-9]+$ ]]; then
    echo "FAIL: recovery_end is not numeric: ${recovery}"
    return 1
  fi
  if [[ "$recovery" -lt "$membership" ]]; then
    echo "FAIL: recovery_end precedes membership_loss_t0"
    return 1
  fi
  duration=$((recovery - membership))

  case "$mode" in
    first-run)
      if [[ "$duration" -ge 600 ]]; then
        echo "FAIL: first-run recovery ${duration}s reached 600s analytic ceiling"
        failures=$((failures + 1))
      fi
      ;;
    budget)
      if [[ ! "${DRT005_BUDGET_WARN_SECONDS:-}" =~ ^[0-9]+$ ]] || \
         [[ ! "${DRT005_BUDGET_FAIL_SECONDS:-}" =~ ^[0-9]+$ ]] || \
         [[ "$DRT005_BUDGET_WARN_SECONDS" -ge "$DRT005_BUDGET_FAIL_SECONDS" ]]; then
        echo "FAIL: DRT005_MODE=budget requires numeric mock bands"
        return 1
      fi
      if [[ "$duration" -ge "$DRT005_BUDGET_FAIL_SECONDS" ]]; then
        echo "FAIL: budget recovery ${duration}s reached hard band ${DRT005_BUDGET_FAIL_SECONDS}s"
        failures=$((failures + 1))
      elif [[ "$duration" -ge "$DRT005_BUDGET_WARN_SECONDS" ]]; then
        echo "WARN: budget recovery ${duration}s reached warn band ${DRT005_BUDGET_WARN_SECONDS}s"
      fi
      ;;
    *)
      echo "FAIL: unknown DRT005_MODE='${mode}'"
      return 1
      ;;
  esac

  local policy_off ladder_ran
  policy_off=$(field_from_fixture "$fixture" "POLICY_OFF_ALL_VMIDS")
  ladder_ran=$(field_from_fixture "$fixture" "POLICY_OFF_LADDER_RAN")
  if [[ -z "${policy_off// /}" ]]; then
    echo "SKIP (policy-off set empty — override contract not exercised)"
    if [[ "$ladder_ran" == "true" ]]; then
      echo "FAIL: policy-off-specific ladder ran despite empty set"
      failures=$((failures + 1))
    fi
  else
    if [[ "$ladder_ran" != "true" ]]; then
      echo "FAIL: policy-off set non-empty but override ladder did not run"
      failures=$((failures + 1))
    else
      echo "RUN policy-off-specific ladder"
    fi
  fi

  local target running ha_started
  target=$(field_from_fixture "$fixture" "TARGET_VMIDS_CSV")
  running=$(field_from_fixture "$fixture" "RECOVERED_RUNNING_VMIDS")
  ha_started=$(field_from_fixture "$fixture" "RECOVERED_HA_STARTED_VMIDS")
  if [[ -z "${target// /}" ]]; then
    echo "FAIL: fixture has empty TARGET_VMIDS_CSV"
    failures=$((failures + 1))
  else
    local vmid
    IFS=',' read -ra TARGET_ARR <<< "$target"
    for vmid in "${TARGET_ARR[@]}"; do
      [[ -z "$vmid" ]] && continue
      if ! csv_contains "$running" "$vmid"; then
        echo "FAIL: universal predicate not met: vm:${vmid} qemu running missing"
        failures=$((failures + 1))
      fi
      if ! csv_contains "$ha_started" "$vmid"; then
        echo "FAIL: universal predicate not met: vm:${vmid} HA started missing"
        failures=$((failures + 1))
      fi
    done
  fi

  local qmstarts pair elapsed
  qmstarts=$(field_from_fixture "$fixture" "QMSTART_WALL_TIMES")
  IFS=',' read -ra QMSTART_ARR <<< "$qmstarts"
  for pair in "${QMSTART_ARR[@]}"; do
    [[ -z "$pair" ]] && continue
    elapsed="${pair#*:}"
    if [[ ! "$elapsed" =~ ^[0-9]+$ ]]; then
      echo "FAIL: malformed qmstart wall-time fixture: ${pair}"
      failures=$((failures + 1))
      continue
    fi
    if [[ "$elapsed" -ge 60 ]]; then
      echo "FAIL: qmstart wall time ${elapsed}s reached #691 tripwire"
      failures=$((failures + 1))
    fi
  done

  echo "membership_loss_t0=${membership}"
  echo "recovery_end=${recovery}"
  echo "duration=${duration}"

  if [[ "$failures" -eq 0 ]]; then
    echo "RESULT: PASS"
    return 0
  fi
  echo "RESULT: FAIL"
  return 1
}

RUN_OUT=""
RUN_RC=0
run_fixture_eval() {
  local fixture="$1"
  shift
  set +e
  RUN_OUT=$(env "$@" bash -c '
    set -euo pipefail
    source "$1"
    drt005_eval_fixture "$2"
  ' bash "$0" "$fixture" 2>&1)
  RUN_RC=$?
  set -e
}

assert_fixture_rc() {
  local expected="$1" detail="$2"
  if [[ "$RUN_RC" -eq "$expected" ]]; then
    test_pass "$detail"
  else
    test_fail "$detail (expected rc=${expected}, got rc=${RUN_RC}; output: ${RUN_OUT})"
  fi
}

assert_run_contains() {
  local needle="$1" detail="$2"
  if grep -qF -- "$needle" <<< "$RUN_OUT"; then
    test_pass "$detail"
  else
    test_fail "$detail (missing '${needle}' in output: ${RUN_OUT})"
  fi
}

assert_run_absent() {
  local needle="$1" detail="$2"
  if grep -qF -- "$needle" <<< "$RUN_OUT"; then
    test_fail "$detail (unexpected '${needle}' in output: ${RUN_OUT})"
  else
    test_pass "$detail"
  fi
}

# --- DB.1: measured bands from M4 attempt-3 (Sprint 048 MR-7) ---
# B=136s (M4 attempt-3 PASS 2026-07-23, commit b9fc097, series 146/146/136).
# WARN = max(B+30, ceil(1.15*B)) = max(166, 157) = 166s.
# FAIL = ceil(1.85*B) = 252s.
test_start "DB.1" "MR-7 measured hard-FAIL ceiling=252s and WARN=166s (B=136s)"
assert_grep_file "$DRT" "BASELINE_MIGRATION_SECONDS=136" \
  "DB.1: measured baseline B=136 literal present"
assert_grep_file "$DRT" "DRT005_WARN_SECONDS=166" \
  "DB.1: WARN=166s literal present (max(B+30, ceil(1.15B)))"
assert_grep_file "$DRT" "DRT005_FAIL_SECONDS=252" \
  "DB.1: FAIL=252s literal present (ceil(1.85B))"
assert_grep_file "$DRT" "series 146/146/136" \
  "DB.1: three-run baseline series recorded in header"

# --- DB.2: first-run analytic switch is retired (MR-7 T4 principle-4 removal) ---
# The first-run analytic-ceiling switch was one-time machinery whose event
# (M4 first observed clean cycle) completed. Any residual is a regression.
test_start "DB.2" "MR-7: first-run analytic switch fully retired"
assert_absent_file "$DRT" "DRT005_MODE=" \
  "DB.2: DRT005_MODE variable removed"
assert_absent_file "$DRT" "DRT005_FIRST_RUN_CEILING_SECONDS" \
  "DB.2: DRT005_FIRST_RUN_CEILING_SECONDS variable removed"
assert_absent_file "$DRT" "DRT005_ACTIVE_FAIL_SECONDS" \
  "DB.2: DRT005_ACTIVE_FAIL_SECONDS shim removed"
assert_absent_file "$DRT" "DRT005_ACTIVE_WARN_SECONDS" \
  "DB.2: DRT005_ACTIVE_WARN_SECONDS shim removed"
assert_absent_file "$DRT" "DRT005_BUDGET_WARN_SECONDS" \
  "DB.2: DRT005_BUDGET_WARN_SECONDS override removed"
assert_absent_file "$DRT" "DRT005_BUDGET_FAIL_SECONDS" \
  "DB.2: DRT005_BUDGET_FAIL_SECONDS override removed"

# --- DB.3: BASELINE_VM_COUNT documentary only (shape self-signal, not gate) ---
test_start "DB.3" "BASELINE_VM_COUNT=9 documentary literal preserved"
assert_grep_file "$DRT" "BASELINE_VM_COUNT=9" \
  "DB.3: BASELINE_VM_COUNT=9 literal preserved (documentary)"
assert_grep_file "$DRT" "BASELINE_VM_COUNT=\${BASELINE_VM_COUNT} is documentary only" \
  "DB.3: run-time announce line confirms BASELINE_VM_COUNT does not gate"

# --- DB.4: both post-recovery assertions present ---
test_start "DB.4" "post-recovery: rebalance verify (#514) + vaccine soak (#511)"
assert_grep_file "$DRT" "MYCOFU_REBALANCE_ONLY_VERIFY=1" \
  "DB.4: MYCOFU_REBALANCE_ONLY_VERIFY=1 post-recovery assertion present (#514)"
assert_grep_file "$DRT" "MYCOFU_VALIDATE_ONLY_CIDATA_RENAME=1" \
  "DB.4: MYCOFU_VALIDATE_ONLY_CIDATA_RENAME=1 vaccine-soak assertion present (#511)"

# --- DB.5: anti-affinity mechanism-present pre-check ---
test_start "DB.5" "mechanism-present pre-check queries live HA rules for the negative harule"
assert_grep_file "$DRT" "pvesh get /cluster/ha/rules" \
  "DB.5: pre-check reads /cluster/ha/rules from the live cluster"
assert_grep_file "$DRT" "resource-affinity" \
  "DB.5: pre-check matches the resource-affinity rule type"
assert_grep_file "$DRT" "half-landed" \
  "DB.5: pre-check names the half-landed-A2 failure mode"

# --- DB.6: M1 side-finding — post-recovery re-separation with >=2 healthy ---
test_start "DB.6" "M1 side-finding: DNS pair re-separation asserted once >=2 nodes healthy"
assert_grep_file "$DRT" "HEALTHY_NODES" \
  "DB.6: healthy-node count gates the re-separation assertion"
assert_grep_file "$DRT" "re-separated" \
  "DB.6: post-recovery anti-affinity re-separation assertion present"

# --- DB.7: the old 120s comment-only baseline is gone (ratchet) ---
test_start "DB.7" "old 120s migration assertion removed (no silent revert)"
assert_absent_file "$DRT" 'ELAPSED_AT_PASS" -le 120' \
  "DB.7: no leftover 120s hard budget assertion"

# --- DB.8: recovery poll loop gates on measured DRT005_FAIL_SECONDS ---
# Sprint 048 MR-7: the poll loop reads the measured 252s hard ceiling.
test_start "DB.8" "recovery poll loop gates on measured DRT005_FAIL_SECONDS"
assert_grep_file "$DRT" '"$WAIT" -ge "$DRT005_FAIL_SECONDS"' \
  "DB.8: poll loop compares WAIT against the measured hard ceiling"

# --- DB.8b (Sprint 048 T6.6): no-VM-in-HA-error terminal assertion ---
# Codex adversarial review: the DRT's terminal "no VM in HA error after
# recovery window" assertion must exist and must be lockstepped by the
# budget test — otherwise a silent rename would drop the terminal
# state-cleanliness gate.
test_start "DB.8b" "Sprint 048 T6.6: 'no VM in HA error after recovery window' terminal assertion lockstepped"
assert_grep_file "$DRT" "no VM in HA error after recovery window" \
  "DB.8b: DRT-005 asserts terminal state-cleanliness (no lingering HA errors)"

# --- DB.9: drt_warn exists as a registry-note mechanism (not a silent log) ---
test_start "DB.9" "drt_warn defined in common.sh and surfaced in the DR-REGISTRY block"
assert_grep_file "$COMMON" "drt_warn()" \
  "DB.9: drt_warn helper defined in common.sh"
assert_grep_file "$COMMON" "DRT_WARNING_LIST" \
  "DB.9: warnings collected for the registry paste block"
assert_grep_file "$DRT" "drt_warn " \
  "DB.9: DRT-005 records soft breaches via drt_warn"

# --- DB.10 (Sprint 048 T6.6): universal predicate — EVERY VM, not policy-on ---
# The Sprint 048 doctrine flip makes every enabled VM a replicated failover
# target. The DRT-005 predicate is therefore universal: every VM that was
# running on the failed node must reach qemu status=running AND HA
# state=started on a survivor.
test_start "DB.10" "Sprint 048 T6.6: universal predicate (EVERY VM, not policy-on)"
assert_grep_file "$DRT" "EVERY VM from failed node reaches qemu status=running and HA state=started on a survivor" \
  "DB.10: universal predicate label present in DRT_PREDICATE_LIST"
assert_grep_file "$DRT" "EVERY VM from failed node reaches qemu status=running and HA state=started on a survivor before" \
  "DB.10: universal predicate wired into drt_assert with active ceiling"

# --- DB.11 (Sprint 048 T6.6): policy-off leg conditional on non-empty set ---
# When no `replicate: false` overrides exist, POLICY_OFF_ALL_VMIDS is empty
# and the leg SKIPs with an explicit note. When overrides exist, the
# error/stopped end-state assertion still runs (the leg is preserved for
# the override contract).
test_start "DB.11" "Sprint 048 T6.6: policy-off leg conditional on non-empty override set"
assert_grep_file "$DRT" "POLICY_OFF_ALL_VMIDS" \
  "DB.11: DRT-005 fetches the policy-off (override) set from single authority"
assert_grep_file "$DRT" "policy-off set empty" \
  "DB.11: empty override set is announced with the SKIP note"
assert_grep_file "$DRT" "override contract not exercised" \
  "DB.11: SKIP note explains the leg is a no-op when no overrides exist"
assert_grep_file "$DRT" "POLICY-OFF VMs on dead node in expected error/stopped state" \
  "DB.11: end-state assertion preserved for non-empty override set"

# --- DB.12 (Sprint 047 A6 / issue #668): recreate-derivable-vm.sh dry-run leg ---
# The recreate-exercise leg walks the operator recovery contract: dry-run first
# (proving guards fire and the deploy hint is printed), then the real invocation.
# The dry-run assertion is what turns a comment-only reference into a fired
# code path in the DRT.
test_start "DB.12" "issue #668: DRT-005 exercises recreate-derivable-vm.sh --dry-run"
assert_grep_file "$DRT" "recreate-derivable-vm.sh --dry-run" \
  "DB.12: dry-run invocation of recreate-derivable-vm.sh present"
assert_grep_file "$DRT" "guards passed" \
  "DB.12: dry-run assertion labeled as guards-passed proof (not a bare exit-code check)"
assert_grep_file "$DRT" '[DRY-RUN]' \
  "DB.12: dry-run output asserted to contain [DRY-RUN] marker (proves flag honored)"
assert_grep_file "$DRT" 'safe-apply\.sh dev' \
  "DB.12: dry-run output asserted to print the safe-apply.sh dev deploy contract"

# --- DB.13 (issue #668): real recreate-derivable-vm.sh invocation ---
# The real invocation is what makes DR-REGISTRY's promise true: the recovery
# contract is walked end-to-end, not merely dry-runned.
test_start "DB.13" "issue #668: DRT-005 runs the real recreate-derivable-vm.sh (destroys + zvols)"
assert_grep_file "$DRT" 'recreate-derivable-vm.sh "$RECREATE_TARGET_VMID"' \
  "DB.13: real (no --dry-run) invocation of recreate-derivable-vm.sh present"
assert_grep_file "$DRT" "no longer present in cluster resources after recreate helper" \
  "DB.13: post-real-invocation assertion verifies VM shell is gone"

# --- DB.14 (issue #668): printed-deploy follow-through ---
# The recovery contract's third mandatory step is running the deploy hint the
# helper prints. Without it, the DRT proves only that the helper STOPS at the
# right place — not that the printed deploy actually recovers the VM.
test_start "DB.14" "issue #668: DRT-005 runs the printed safe-apply.sh dev and verifies VM back"
assert_grep_file "$DRT" 'framework/scripts/safe-apply.sh dev' \
  "DB.14: safe-apply.sh dev invocation present (matches recreate helper's printed deploy)"
assert_grep_file "$DRT" "running after safe-apply.sh dev" \
  "DB.14: post-deploy assertion verifies VM is back to running"

# --- DB.15 (issue #668): target selection scoped to ruling ---
# Ruling names testapp_dev as preferred and acme_dev as fallback (with the
# structural caveat that acme_dev homes on pve03, typically PBS-excluded).
# cicd and vendor appliances are excluded by the recreate helper itself;
# the DRT MUST NOT introduce a wider net.
test_start "DB.15" "issue #668: recreate-exercise targets are the operator-ruled dev-side pair"
assert_grep_file "$DRT" 'EXERCISE_TESTAPP_VMID}:testapp_dev' \
  "DB.15: testapp_dev present as preferred exercise target"
assert_grep_file "$DRT" 'EXERCISE_ACME_VMID}:acme_dev' \
  "DB.15: acme_dev present as fallback exercise target"
assert_absent_file "$DRT" ':cicd"' \
  "DB.15: cicd NOT selectable as recreate-exercise target (operator ruling)"

# --- DB.16 (issue #668): recreate leg sequenced BEFORE rebalance ---
# rebalance-cluster.sh FAILs on any HA `error`. The recreate exercise clears
# the target VM's error state; if it lands AFTER rebalance, rebalance breaks
# before the exercise ever runs. Static line-order check.
test_start "DB.16" "issue #668: recreate-exercise leg precedes rebalance-cluster.sh in DRT-005"
RECREATE_LINE=$(grep -n "Sprint 047 A6 / issue #668: walk the recreate-derivable-vm.sh contract" "$DRT" | head -1 | cut -d: -f1)
REBALANCE_LINE=$(grep -n "Running rebalance-cluster.sh" "$DRT" | head -1 | cut -d: -f1)
if [[ -n "$RECREATE_LINE" && -n "$REBALANCE_LINE" && "$RECREATE_LINE" -lt "$REBALANCE_LINE" ]]; then
  test_pass "DB.16: recreate-exercise step (line $RECREATE_LINE) precedes rebalance step (line $REBALANCE_LINE)"
else
  test_fail "DB.16: recreate-exercise must precede rebalance (recreate=$RECREATE_LINE rebalance=$REBALANCE_LINE)"
fi

# --- DB.17 (issue #668 / MR-6 P1 lesson): fail-closed on HA state source ---
# MR-6 P1 (codex + sub-claude): silent-empty capture of a helper's output
# converts a failure into a false pass. The recreate leg reads live HA
# state; that capture must be fail-closed, not `2>/dev/null || echo ""`,
# and stderr must be captured SEPARATELY so an SSH banner cannot corrupt
# the JSON payload (round-2 sub-claude P2).
#
# Issue #688: the source is now /etc/pve/ha/manager_status (JSON object).
# The pre-#688 `ha-manager status --output-format json` command does not
# exist on PVE 9.1.1 and returned nothing every run; the ratchet strings
# below have been updated to the new source. The FAIL-CLOSED SHAPE is what
# this test enforces — the specific source only appears in the strings.
test_start "DB.17" "issue #688: HA-state read in recreate leg is fail-closed with separated stderr"
assert_grep_file "$DRT" 'HA_STATUS_STDERR=$(mktemp)' \
  "DB.17: recreate leg captures HA-state read stderr to a separate tempfile"
assert_grep_file "$DRT" '2>"$HA_STATUS_STDERR"' \
  "DB.17: recreate leg redirects stderr AWAY from the JSON stdout capture"
assert_grep_file "$DRT" "/etc/pve/ha/manager_status read failed or returned empty output" \
  "DB.17: recreate leg fails closed on empty/failed manager_status read (issue #688)"
assert_grep_file "$DRT" 'type == "object" and has("service_status")' \
  "DB.17: recreate leg validates manager_status parses as JSON object before use"

# --- DB.18 (round-2): candidate VMIDs sourced from config.yaml ---
# .claude/rules/config-yaml.md: no hardcoded VMIDs in framework/. The
# candidate list uses drt_vm_vmid so a future VMID renumber does not
# silently drop the exercise.
test_start "DB.18" "issue #668: recreate-exercise VMIDs resolved via drt_vm_vmid (config.yaml SoT)"
assert_grep_file "$DRT" 'EXERCISE_TESTAPP_VMID=$(drt_vm_vmid testapp dev)' \
  "DB.18: testapp_dev VMID resolved via drt_vm_vmid (config-yaml rule)"
assert_grep_file "$DRT" 'EXERCISE_ACME_VMID=$(drt_vm_vmid acme dev)' \
  "DB.18: acme_dev VMID resolved via drt_vm_vmid (config-yaml rule)"

# --- DB.19 (round-2): destructive chain gates itself ---
# codex round-2 P1: drt_assert is record-and-continue, so the dry-run →
# real → safe-apply chain must gate itself on DRY_OK / REAL_OK guard
# variables, else a failed dry-run cascades into the real destroy.
test_start "DB.19" "issue #668: destructive chain gated by DRY_OK / REAL_OK"
assert_grep_file "$DRT" 'DRY_OK=false' \
  "DB.19: DRY_OK guard variable declared"
assert_grep_file "$DRT" 'REAL_OK=false' \
  "DB.19: REAL_OK guard variable declared"
assert_grep_file "$DRT" 'if [[ "$DRY_OK" == "true" ]]; then' \
  "DB.19: real destroy invocation gated behind DRY_OK==true"
assert_grep_file "$DRT" 'if [[ "$REAL_OK" == "true" ]]; then' \
  "DB.19: safe-apply.sh dev invocation gated behind REAL_OK==true"

# --- DB.20 (round-2): HA daemon settle after node rejoin ---
# agy round-2 P2: cluster-status `online=1` fires before pve-ha-crm/lrm
# are leader-elected and heartbeating; the recreate helper mutates HA
# state and needs a settle window.
test_start "DB.20" "issue #668: recreate leg sleeps to let HA daemons settle after rejoin"
assert_grep_file "$DRT" '[settle] sleeping 15s for HA daemons on rejoined node' \
  "DB.20: 15s HA-daemon settle sleep present after node rejoin"

# --- DB.21 (round-2): missing target is a hard FAIL, not a WARN ---
# codex round-2 P1 / sub-claude P1-B: skip-with-WARN then drt_finish
# RESULT: PASS was a false-pass on the M4 acceptance gate. The leg IS
# the acceptance proof; if it can't walk, the run is not certifiable.
test_start "DB.21" "issue #668: absent recreate-exercise target is a hard FAIL (not a soft WARN)"
assert_grep_file "$DRT" 'drt_assert "recreate-exercise target present in HA' \
  "DB.21: target-presence check uses drt_assert (fails the DRT)"
assert_absent_file "$DRT" 'recreate-exercise skipped: neither' \
  "DB.21: the pre-round-2 warn-and-skip message has been removed"

# --- DB.22 (round-2): residual §6A ladder cleanup ---
# agy/codex/sub-claude unanimous round-2 P1: the fix as-written left prod
# and other-dev policy-off VMs in HA `error`, which broke rebalance. The
# residual cleanup applies the storage-failure-fence §6A ladder to all
# residual policy-off errors (excluding exercise target, cicd, hil_boot).
test_start "DB.22" "issue #668: residual policy-off HA errors are cleared via §6A ladder"
assert_grep_file "$DRT" 'POLICY_OFF_ERRORS=' \
  "DB.22: residual set of policy-off VMs in HA error is computed"
assert_grep_file "$DRT" 'Clearing residual policy-off HA' \
  "DB.22: residual cleanup step announced"
assert_grep_file "$DRT" '--state disabled' \
  "DB.22: §6A step 1 (disabled) invoked on residuals"
assert_grep_file "$DRT" '--state started' \
  "DB.22: §6A step 2 (started) invoked on residuals"
assert_grep_file "$DRT" 'CICD_VMID=$(drt_vm_vmid cicd' \
  "DB.22: cicd VMID resolved for exclusion from §6A ladder (control-plane recovery differs)"
assert_grep_file "$DRT" 'HIL_VMID=$(drt_vm_vmid hil_boot' \
  "DB.22: hil_boot VMID resolved for exclusion from §6A ladder (vendor-adjacent recovery differs)"

# --- DB.23 (round-2): safe-apply.sh dev invoked INLINE, not through drt_assert ---
# agy round-2 P1: drt_assert captures 10-15 minutes of stdout/stderr
# into a variable — an operator staring at silence during a live DRT
# run cannot tell whether safe-apply is progressing or hung.
test_start "DB.23" "issue #668: safe-apply.sh dev runs inline (operator sees live output)"
assert_grep_file "$DRT" 'framework/scripts/safe-apply.sh dev
  SAFE_APPLY_RC=$?' \
  "DB.23: safe-apply.sh dev runs directly (RC captured, not through drt_assert)"
assert_grep_file "$DRT" 'test "$SAFE_APPLY_RC" -eq 0' \
  "DB.23: drt_assert operates on captured rc, not the running command"

# --- DB.24 (issue #688 defect 2): no `ha-manager status --output-format json`
# The pre-#688 use of this command is invalid on PVE 9.1.1 (option does not
# apply to `ha-manager status`); the correct source is /etc/pve/ha/manager_status.
# The ratchet forbids any live-code re-introduction (comment references are
# allowed because the fix commentary names the defect).
test_start "DB.24" 'issue #688 defect 2: no live "ha-manager status --output-format json" in DRT-005'
# Any line that CALLS the invalid command is a hit. We look for lines that
# EXECUTE the string (leading `"` or the SSH-payload string form) and
# exclude commentary lines that reference the phrase inside `#` comments.
LIVE_HITS=$(grep -nE 'ha-manager status --output-format json' "$DRT" \
  | grep -vE '^\s*[0-9]+:\s*#' \
  | grep -vE 'previous .ha-manager status --output-format json' \
  | grep -vE 'defect 2: .ha-manager status' || true)
if [[ -z "$LIVE_HITS" ]]; then
  test_pass 'DB.24: no live invocation of "ha-manager status --output-format json"'
else
  test_fail 'DB.24: live use of "ha-manager status --output-format json" re-introduced'
  echo "$LIVE_HITS" >&2
fi

# --- DB.25 (issue #688 defect 2): /etc/pve/ha/manager_status is the HA read source
# All three HA-read blocks (policy-off contract check, recreate-exercise leg,
# post-§6A verify) MUST consume /etc/pve/ha/manager_status.
test_start "DB.25" "issue #688 defect 2: /etc/pve/ha/manager_status is the HA-read source in DRT-005"
COUNT=$(grep -cE 'cat /etc/pve/ha/manager_status' "$DRT")
if [[ "$COUNT" -ge 3 ]]; then
  test_pass "DB.25: /etc/pve/ha/manager_status read appears >=3 times (found $COUNT)"
else
  test_fail "DB.25: /etc/pve/ha/manager_status read appears $COUNT times; expected >=3"
fi

# --- DB.26 (issue #688 defect 4): checker-crash AND observed-unexpected
# both become hard FAILs (not WARN). Per destruction-safety doctrine +
# RCA remediation §3: a safety check that cannot determine its input is
# a FAIL, and an observed policy-off `started`/`running` on a survivor
# is a real contract violation, not a warning.
test_start "DB.26" "issue #688 defect 4: policy-off checker parse-error AND observed-unexpected are hard FAILs"
assert_grep_file "$DRT" 'POLICY_OFF_PY_RC -eq 2' \
  "DB.26: policy-off checker parse error branch present"
assert_grep_file "$DRT" 'policy-off state checker parse error' \
  "DB.26: checker-crash FAIL message is explicit about the destruction-safety rule"
assert_grep_file "$DRT" 'unexpected POLICY-OFF state(s) observed on dead node' \
  "DB.26: observed-unexpected policy-off state is a hard FAIL (RCA remediation §3)"
assert_grep_file "$DRT" 'issue #688 defect 4)" false' \
  "DB.26: observed-unexpected uses drt_assert with an explicit false verdict"
# Codex adversarial review: `VAR=$(cmd)` under `set -euo pipefail` exits
# BEFORE `$?` is captured. The set +e wrap makes rc capture reachable.
assert_grep_file "$DRT" 'set +e
UNEXPECTED_POLICY_OFF_STATE=' \
  "DB.26: policy-off checker rc capture wraps assignment in set +e (unreachable-rc bug fixed)"

# --- DB.27 (issue #688 defect 4b): fail-fast-regression detector on qmstart
# Detect HA qmstart tasks on policy-off VMIDs running > 60s (the 2026-07-20
# regression symptom) and FAIL with the 300s ZFS zvol-link worker-timeout
# mechanism named. This IS the regression detector, not a comment.
test_start "DB.27" "Sprint 048 T6.6: qmstart >=60s on ANY recovered VMID is a hard FAIL (#691 permanent tripwire)"
assert_grep_file "$DRT" '/nodes/${N_NAME}/tasks --source active' \
  "DB.27: detector polls active tasks per node"
assert_grep_file "$DRT" 'no HA qmstart >=60s on recovered VMIDs' \
  "DB.27: detector's drt_assert label present (universal — every recovered VMID)"
assert_grep_file "$DRT" '#691 permanent tripwire' \
  "DB.27: detector labeled as the permanent #691 tripwire (retained past Sprint 048)"
# Agy + codex adversarial review: the detector must extract VMID from
# `id` OR `upid` (PVE task shape varies by endpoint) — a fallback parser
# is required for the exact hang shape we're detecting.
assert_grep_file "$DRT" 'def parse_vmid' \
  "DB.27: qmstart detector uses parse_vmid helper (id + upid fallback)"
assert_grep_file "$DRT" 'UPID:<node>:<pid>:<pstart>:<starttime>:<type>:<id>:<user>' \
  "DB.27: qmstart detector documents the UPID shape it parses"
# Codex adversarial review: SURVIVOR task-query failure must be fail-closed,
# not treated as 'no active qmstarts' (that false-passes when the failing
# node is the very one holding a hung worker).
assert_grep_file "$DRT" 'could not query active tasks on survivor' \
  "DB.27: survivor task-query failure is fail-closed (hard FAIL, not skipped)"

# --- DB.28 (issue #688 defect 5): python3 embedded snippets avoid backslash
# in f-string expressions (a 3.12+ feature). The workstation runs python3
# 3.9; the pre-#688 snippet with `f"...{e.get(\"state\")}..."` crashed live.
# The ratchet grep runs against the actual file bytes; any f-string with
# `\"` in an expression is a regression.
test_start "DB.28" "issue #688 defect 5: no python3 f-string backslash-in-expression"
# Only look inside python -c blocks (single-quoted shell heredoc-style),
# where the shell does not translate `\"` → `"` before python parses.
# Sub-claude adversarial review: check BOTH quote directions — the pre-#688
# defect was f"...\"..." but a mirror f'...\'...' regression would be
# equally 3.9-incompatible and the earlier ratchet missed it.
BACKSLASH_HITS_DQ=$(grep -nE 'f"[^"]*\\"' "$DRT" || true)
BACKSLASH_HITS_SQ=$(grep -nE "f'[^']*\\\\'" "$DRT" || true)
BACKSLASH_HITS="${BACKSLASH_HITS_DQ}${BACKSLASH_HITS_SQ}"
if [[ -z "${BACKSLASH_HITS// /}" ]]; then
  test_pass "DB.28: no f-string backslash-in-expression regression (both quote directions checked)"
else
  test_fail "DB.28: f-string backslash-in-expression re-introduced (breaks python < 3.12)"
  echo "$BACKSLASH_HITS" >&2
fi

# --- DB.29 (codex adversarial P1): migration budget requires HA state=started
# The corrected predicate must combine (qemu running on survivor) AND
# (HA state=started). A qemu-running VM that HA still sees as `starting`/
# `migrate`/`freeze` is not settled and should NOT satisfy the budget.
test_start "DB.29" "codex P1: migration-budget predicate combines qemu-running AND HA state=started"
assert_grep_file "$DRT" 'BUDGET_MANAGER_STATUS' \
  "DB.29: budget predicate reads /etc/pve/ha/manager_status for HA-state"
assert_grep_file "$DRT" '"HA state=" + (ha_state or "<absent>")' \
  "DB.29: budget predicate reports HA-state pendency per-VMID"
assert_grep_file "$DRT" '(need started)' \
  "DB.29: budget predicate documents the required HA state"

# --- DB.30 (Sprint 048 T6.6): predicate must converge before timing gate ---
# Prevent the false-PASS timing report when the universal predicate never
# converged. VALIDATE_OK gates whether the ceiling is evaluated.
test_start "DB.30" "Sprint 048 T6.6: predicate convergence gates the timing ceiling"
assert_grep_file "$DRT" 'VALIDATE_OK' \
  "DB.30: VALIDATE_OK flag drives whether the ceiling assertion evaluates"
assert_grep_file "$DRT" "test \"\$VALIDATE_OK\" = \"true\"" \
  "DB.30: universal predicate drt_assert bound to VALIDATE_OK==true"

# --- DB.31 (issue #688 defect 1 + agy P1): recreate-derivable-vm.sh HA read
# ratchets. The recreate helper reads HA state from valid PVE 9.1.1 JSON
# sources and fails closed on any input undeterminability.
RECREATE="${REPO_ROOT}/framework/scripts/recreate-derivable-vm.sh"
test_start "DB.31" "issue #688 defect 1: recreate-derivable-vm.sh reads HA state from valid JSON sources"
assert_grep_file "$RECREATE" 'pvesh get /cluster/ha/resources --output-format json' \
  "DB.31: /cluster/ha/resources used for HA registration + requested state"
assert_grep_file "$RECREATE" 'cat /etc/pve/ha/manager_status' \
  "DB.31: /etc/pve/ha/manager_status used for internal state"
assert_grep_file "$RECREATE" 'select(.sid == $sid or .id == $sid)' \
  "DB.31: sid/id belt-and-suspenders match (agy P1 fail-open guard)"
assert_grep_file "$RECREATE" 'could not read /cluster/ha/resources' \
  "DB.31: recreate helper fails closed when /cluster/ha/resources unreadable"
assert_grep_file "$RECREATE" 'could not read /etc/pve/ha/manager_status' \
  "DB.31: recreate helper fails closed when manager_status unreadable"
assert_grep_file "$RECREATE" 'HA-registered but manager_status has no state entry' \
  "DB.31: recreate helper fails closed when state entry absent for registered VM"
# Any non-stopped/non-disabled state must route through §6A ladder.
assert_grep_file "$RECREATE" 'case "$HA_STATE" in' \
  "DB.31: HA_STATE case statement present"
assert_grep_file "$RECREATE" 'stopped|disabled)' \
  "DB.31: only stopped/disabled bypass §6A ladder"
# Regression guard: no live use of the invalid ha-manager status --output-format json.
LIVE_HITS=$(grep -nE 'ha-manager status --output-format json' "$RECREATE" \
  | grep -vE '^\s*[0-9]+:\s*#' \
  | grep -vE 'The previous .ha-manager status --output-format json' || true)
if [[ -z "$LIVE_HITS" ]]; then
  test_pass 'DB.31: no live invocation of "ha-manager status --output-format json" in recreate helper'
else
  test_fail 'DB.31: live use of "ha-manager status --output-format json" re-introduced in recreate helper'
  echo "$LIVE_HITS" >&2
fi

# --- DB.32 (issue #696): step 12 settle-then-retry is bounded to exactly one ---
# The M4 attempt 1 attended run (2026-07-22, commit 236b09b) passed every
# failover-acceptance criterion but hard-failed on step 12 because
# validate.sh ran IMMEDIATELY after nine failback relocations. An identical
# validate.sh minutes later was green. The fix gives ONE 75s replication-
# cycle worth of settle and retries ONCE. This ratchet enforces the "bounded
# to exactly one" property so a future edit cannot silently expand the retry
# into a loop or convert "one settle" into "N settles until green".
test_start "DB.32" "issue #696: step 12 validate has bounded (=1) settle-then-retry"
assert_grep_file "$DRT" 'validate-attempt-1.log' \
  "DB.32: attempt 1 log filename referenced (per-run persistence)"
assert_grep_file "$DRT" 'validate-attempt-2.log' \
  "DB.32: attempt 2 log filename referenced (per-run persistence)"
assert_grep_file "$DRT" 'sleep 75' \
  "DB.32: 75s settle sleep present (one replication-cycle window)"
assert_grep_file "$DRT" 'post-churn attempt 1 failed' \
  "DB.32: attempt 1 failure is logged explicitly (not a silent retry)"
assert_absent_file "$DRT" 'validate-attempt-3.log' \
  "DB.32: bounded — no third attempt referenced anywhere in DRT-005"
# Structural bound: the attempt-2 invocation must appear exactly once at the
# source level AND no looping keyword may bracket it. Codex/agy adversarial
# review P2: a `while`/`for`/`until` around the single line would keep the
# grep count at 1 while runtime retries become unbounded — the "bounded once"
# property must survive that structural drift.
COUNT_ATTEMPT2=$(grep -cE 'framework/scripts/validate\.sh > "\$VALIDATE_ATTEMPT_2_LOG"' "$DRT" || true)
if [[ "$COUNT_ATTEMPT2" == "1" ]]; then
  test_pass "DB.32: attempt-2 invocation appears exactly once (no source-level duplication)"
else
  test_fail "DB.32: attempt-2 invocation must appear exactly once; found $COUNT_ATTEMPT2"
fi
# Scan the BEGIN/END block for loop keywords. The block should be strictly
# linear: capture rc-1 → if-rc-nonzero → sleep 75 → capture rc-2 → drt_assert.
# Comment lines are excluded so the block's own rationale (which mentions
# "loops") is not mistaken for a construct.
STEP12_LINEAR=$(awk '/# BEGIN issue #696 step 12 retry block/,/# END issue #696 step 12 retry block/' "$DRT" \
  | grep -vE '^\s*#')
if grep -qE '^\s*(while|for|until)\b' <<< "$STEP12_LINEAR"; then
  test_fail "DB.32: step 12 retry block contains a loop keyword — 'bounded to exactly one' broken"
else
  test_pass "DB.32: step 12 retry block is loop-free (bounded-to-one survives loop-wrapping drift)"
fi

# --- DB.33 (issue #696): full inner-check output capture — no anonymous check ---
# The M4 attempt 1 finding: the failing inner check's name was lost because
# drt_assert captured only a 10-line output tail. Fix: persist each attempt's
# COMPLETE output as a separate file, referenced by name from the main log.
# Ratchet: the redirect pattern must be present, the per-run log directory
# must be created before the write, and the drt_assert descriptions must name
# the log paths so DR-REGISTRY paste blocks preserve the reference.
test_start "DB.33" "issue #696: full inner-check output capture (validate-attempt-N.log)"
assert_grep_file "$DRT" 'framework/scripts/validate.sh > "$VALIDATE_ATTEMPT_1_LOG"' \
  "DB.33: attempt 1 full output redirected to file (not just tailed)"
assert_grep_file "$DRT" 'framework/scripts/validate.sh > "$VALIDATE_ATTEMPT_2_LOG"' \
  "DB.33: attempt 2 full output redirected to file (not just tailed)"
assert_grep_file "$DRT" 'mkdir -p "$DRT005_LOGDIR"' \
  "DB.33: per-run log directory created before any write"

# --- DB.34 (issue #696): second-attempt failure is FAIL not WARN ---
# Operator ruling per issue #696: "the second result is final and its failure
# is a hard DRT FAIL". A future edit that softens this to drt_warn would let
# a genuine 88/0/0-refusing regression pass silently as a soft breach — the
# exact false-pass surface .claude/rules/design-taste.md principle 8 rejects.
test_start "DB.34" "issue #696: second-attempt validate failure is hard FAIL (not drt_warn)"
# The terminal assertion must be drt_assert (which increments DRT_FAILURES)
# operating on the attempt-2 exit code specifically, not attempt-1. Codex
# adversarial review P2: greping for the test expression alone would pass
# even if a rewrite kept the expression outside a drt_assert call and never
# incremented DRT_FAILURES. Prove the expression is consumed by drt_assert
# by scanning the SAME logical drt_assert stanza — grep -A1 pairs the
# drt_assert description line with its command continuation line.
if grep -A1 -F 'drt_assert "validate.sh passes after rebalance (attempt 2 of 2 after 75s settle' "$DRT" \
    | grep -qE 'test "\$VALIDATE_ATTEMPT_2_RC" -eq 0'; then
  test_pass "DB.34: attempt-2 exit code drives the terminal drt_assert (not a bare test expression)"
else
  test_fail "DB.34: attempt-2 exit code is not paired with drt_assert in the same stanza"
fi
# And no drt_warn CALL may be substituted inside the retry block. Scan
# between the BEGIN/END markers, skipping comment lines (the block's
# rationale explicitly names drt_warn — that mention is not a call).
STEP12_BLOCK=$(awk '/# BEGIN issue #696 step 12 retry block/,/# END issue #696 step 12 retry block/' "$DRT" \
  | grep -vE '^\s*#')
if grep -qE '\bdrt_warn\b' <<< "$STEP12_BLOCK"; then
  test_fail "DB.34: drt_warn call found inside step 12 retry block — second-attempt failure must be a hard FAIL"
else
  test_pass "DB.34: no drt_warn call in step 12 retry block — second-attempt failure remains a hard FAIL"
fi
# Guard against a future edit that removes the markers themselves (which
# would silently disable the drt_warn scan above).
assert_grep_file "$DRT" '# BEGIN issue #696 step 12 retry block' \
  "DB.34: retry-block BEGIN marker present (anchor for the drt_warn scan)"
assert_grep_file "$DRT" '# END issue #696 step 12 retry block' \
  "DB.34: retry-block END marker present (anchor for the drt_warn scan)"

runner_summary
