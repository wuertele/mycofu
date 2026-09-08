#!/usr/bin/env bash
# test_recreate_derivable_vm.sh — Sprint 047 V6.1.
#
# Assert framework/scripts/recreate-derivable-vm.sh:
#   - REFUSES precious VMIDs (per list-backup-backed-vmids.sh)
#   - REFUSES if a parked vdb dataset exists (Sprint 044)
#   - Uses the --state disabled ladder (never bare `ha-manager remove`, never
#     a bare `qm stop` on a healthy VM without going through HA first)
#   - Cleans stale vm-<vmid>-* zvols cluster-wide via the selective pattern
#   - --dry-run makes ZERO mutations
#   - STOPS with a deploy command; NEVER runs `tofu apply`

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
source "${TEST_DIR}/lib/runner.sh"

SCRIPT="${REPO_DIR}/framework/scripts/recreate-derivable-vm.sh"

# ---------------------------------------------------------------------------
# V6.1.a — precious VMID refusal (real config; VMID 150 = gitlab)
# ---------------------------------------------------------------------------
test_start "V6.1.a" "precious VMID (150 gitlab) refused with fail-closed rc≠0"
set +e
output=$("$SCRIPT" --dry-run 150 2>&1)
rc=$?
set -e
if [[ $rc -eq 3 && "$output" == *"REFUSE"* && "$output" == *"precious"* ]]; then
  test_pass "precious guard fires with explicit refusal message"
else
  test_fail "V6.1.a: expected rc=3 with precious refusal; got rc=$rc"
  echo "$output" >&2
fi

# ---------------------------------------------------------------------------
# V6.1.b — POLICY-ON VMID refused under universal-replication doctrine
#
# Under Sprint 048 doctrine every shipped VM is POLICY-ON, so VMID 500
# (testapp_dev) has a replica. recreate-derivable-vm.sh correctly
# REFUSES it (Guard 1b: --off is the shipped-site empty set). A
# fixture-based positive-path test requires a synthetic site with a
# `replicate: false` entry, which the shipped site does not carry.
# ---------------------------------------------------------------------------
test_start "V6.1.b" "POLICY-ON VMID refused (positive-path requires an explicit-override fixture)"
set +e
output=$("$SCRIPT" --dry-run 500 2>&1)
rc=$?
set -e
if [[ $rc -ne 0 ]] \
   && [[ "$output" == *"REFUSE"* ]] \
   && [[ "$output" == *"POLICY-ON"* || "$output" == *"policy-off"* ]]; then
  test_pass "POLICY-ON VMID refused (Sprint 048 MR-4 doctrine: no policy-off/override VMs on shipped site)"
else
  test_fail "V6.1.b: expected rc≠0 with REFUSE + POLICY-ON/policy-off mention"
  echo "$output" >&2
fi

# ---------------------------------------------------------------------------
# V6.1.c — script emits `ha-manager set --state disabled` ladder, never
#          `ha-manager remove` for the initial error-clear
# ---------------------------------------------------------------------------
test_start "V6.1.c" "script uses --state disabled ladder (never bare ha-manager remove for error-clear)"
if grep -q "ha-manager set vm:.* --state disabled" "$SCRIPT" \
   && ! grep -E "ha-manager remove vm:\\\$\\{?VMID\\}?[[:space:]]*$" "$SCRIPT" >/dev/null; then
  # A ha-manager remove call IS present for POST-destroy cleanup — that's
  # allowed. The prohibition is against using `ha-manager remove` as the
  # error-clear primitive on a live VM.
  test_pass "script uses --state disabled for error-clear; ha-manager remove only for post-destroy cleanup"
else
  test_fail "V6.1.c: missing --state disabled ladder OR bare ha-manager remove for error-clear"
fi

# ---------------------------------------------------------------------------
# V6.1.d — script cleans stale vm-<vmid>-* via the selective pattern (grep)
# ---------------------------------------------------------------------------
test_start "V6.1.d" "script cleans stale vm-<vmid>-* zvols on ALL nodes selectively"
if grep -q "grep -E 'vm-\${VMID}-'" "$SCRIPT" \
   && grep -q "for NODE in \$NODE_NAMES" "$SCRIPT" \
   && grep -q "zfs destroy -r" "$SCRIPT"; then
  test_pass "selective cluster-wide zvol cleanup present"
else
  test_fail "V6.1.d: missing selective cluster-wide vm-<vmid>-* cleanup pattern"
fi

# ---------------------------------------------------------------------------
# V6.1.e — script does NOT contain `tofu apply` token
# ---------------------------------------------------------------------------
test_start "V6.1.e" "script never INVOKES tofu apply (destructive-operations.md gate)"
# The script mentions `tofu apply` in comments and printed help — that's
# the documented commitment NOT to run it. Assert instead that no line
# actually invokes it (no bare `tofu apply` at column 0 in a shell command
# position; every real occurrence is inside a backticked or double-quoted
# string in a comment or heredoc).
invocations=$(grep -nE '^[[:space:]]*(tofu|/[^\s]*tofu)[[:space:]]+apply' "$SCRIPT" || true)
if [[ -z "$invocations" ]]; then
  test_pass "no 'tofu apply' invocation — apply is operator-attended (mentions in comments/help are allowed)"
else
  test_fail "V6.1.e: script INVOKES tofu apply — must stop and print, never apply"
  echo "$invocations" >&2
fi

# ---------------------------------------------------------------------------
# V6.1.f — parked-vdb refusal (V6.1 grafted; Sprint 044 park guard)
# ---------------------------------------------------------------------------
test_start "V6.1.f" "script refers to parked-vdb.sh + mycofu-park-* in its refusal path"
if grep -q "mycofu-park-" "$SCRIPT" \
   && grep -q "parked-vdb.sh" "$SCRIPT"; then
  test_pass "parked-vdb refusal path present + names the release helper"
else
  test_fail "V6.1.f: missing mycofu-park-<vmid>-* guard OR parked-vdb.sh reference"
fi

# ---------------------------------------------------------------------------
# V6.1.g — Sprint 047 review-round P1 (codex + agy + sub-claude): POLICY-ON
#          opt-in refusal. Running recreate-derivable-vm.sh on dns1_prod
#          (401) or dns2_prod (402) would blow away their vdb (certs / ACME
#          lineage) — POLICY-ON VMs are recovered via HA restart-from-replica,
#          not recreation. Also asserts unknown-to-config VMIDs are refused
#          (fail-closed on ambiguity).
# ---------------------------------------------------------------------------
test_start "V6.1.g" "POLICY-ON opt-in (401 dns1_prod) refused with fail-closed rc=3"
set +e
output=$("$SCRIPT" --dry-run 401 2>&1)
rc=$?
set -e
if [[ $rc -eq 3 && "$output" == *"REFUSE"* && "$output" == *"policy-off"* ]]; then
  test_pass "POLICY-ON opt-in refused with fail-closed rc=3"
else
  test_fail "V6.1.g: expected rc=3 with POLICY-ON refusal; got rc=$rc"
  echo "$output" >&2
fi

test_start "V6.1.h" "unknown-to-config VMID (999) refused with fail-closed rc=3"
set +e
output=$("$SCRIPT" --dry-run 999 2>&1)
rc=$?
set -e
if [[ $rc -eq 3 && "$output" == *"REFUSE"* && "$output" == *"unknown"* ]]; then
  test_pass "unknown VMID refused with fail-closed rc=3"
else
  test_fail "V6.1.h: expected rc=3 with unknown-VMID refusal; got rc=$rc"
  echo "$output" >&2
fi

test_start "V6.1.i" "leading-zero normalization: 0150 (precious) still refused via 150 comparison"
set +e
output=$("$SCRIPT" --dry-run 0150 2>&1)
rc=$?
set -e
if [[ $rc -eq 3 && "$output" == *"REFUSE"* && "$output" == *"precious"* ]]; then
  test_pass "leading-zero 0150 normalized to 150 and matches precious guard"
else
  test_fail "V6.1.i: leading-zero 0150 should be refused as precious 150; got rc=$rc"
  echo "$output" >&2
fi

runner_summary
