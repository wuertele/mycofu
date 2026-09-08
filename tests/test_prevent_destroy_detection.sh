#!/usr/bin/env bash
# test_prevent_destroy_detection.sh — hermetic regression fence for #741.
#
# In the G2-attended-window cicd recreation attempt (SPRINT-049 MR-3),
# `rebuild-cluster.sh --scope vm=cicd --override-branch-check` died at
# Step 7 because the control-plane-ladder's `grep` for a
# prevent_destroy-blocked plan matched only the OLDER OpenTofu wording:
#
#   older: "Error: Instance cannot be destroyed"
#   newer: "has lifecycle.prevent_destroy set, but the plan calls for
#           this resource to be destroyed"
#
# The ladder never fired for cicd; recreation was blocked. This test
# hermetically pins BOTH wordings by feeding canned stderr into the
# exact grep pattern used at the detection site in rebuild-cluster.sh,
# so a future silent wording-drift (or an accidental narrowing of the
# grep pattern) fails a test instead of a live G-window.
#
# The test extracts the ACTIVE grep pattern from rebuild-cluster.sh
# rather than hard-coding it here — so this file remains the single
# authority on which wordings must be recognised, and the pattern is
# not duplicated across the source and the fixture.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

REBUILD_SCRIPT="${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"

# Extract the exact grep invocation used at the detection site.
# The line looks like:
#   if grep -qE "Instance cannot be destroyed|has lifecycle\.prevent_destroy set" "$plan_stderr" 2>/dev/null; then
DETECTION_LINE="$(grep -nE 'grep -qE?.*prevent_destroy.*"\$plan_stderr"' "$REBUILD_SCRIPT" | head -1 || true)"
# Pull the first double-quoted argument from the grep invocation.
DETECTION_PATTERN="$(printf '%s\n' "$DETECTION_LINE" | awk -F\" '/prevent_destroy/{print $2; exit}')"

test_start "PD.1" "detection line found in rebuild-cluster.sh"
if [[ -n "$DETECTION_LINE" && -n "$DETECTION_PATTERN" ]]; then
  test_pass "pattern extracted: ${DETECTION_PATTERN}"
else
  test_fail "detection grep not found; test needs updating in lockstep with rebuild-cluster.sh"
  echo "  matched line: ${DETECTION_LINE}" >&2
  runner_summary
  exit 1
fi

# Helper: given canned stderr, exercise the extracted pattern the same
# way rebuild-cluster.sh does. Returns 0 if the pattern matches (i.e.
# the ladder would fire), non-zero if not (i.e. rebuild-cluster.sh
# would die).
detect_would_fire() {
  local stderr_input="$1"
  local plan_stderr
  plan_stderr="$(mktemp)"
  printf '%s\n' "$stderr_input" > "$plan_stderr"
  local rc=0
  grep -qE "$DETECTION_PATTERN" "$plan_stderr" 2>/dev/null || rc=$?
  rm -f "$plan_stderr"
  return $rc
}

test_start "PD.2" "older tofu wording matches (Instance cannot be destroyed)"
OLD_WORDING='│ Error: Instance cannot be destroyed
│
│   on ../modules/proxmox-vm-precious/vm.tf line 22:
│   22:   lifecycle {
│
│ Resource module.gitlab.proxmox_virtual_environment_vm.vm has
│ lifecycle.prevent_destroy set, but the plan calls for this resource
│ to be destroyed.'
# Old wording had both "Instance cannot be destroyed" AND (in newer
# tofu) the second sentence. This case simulates a tofu that still
# emits the "Instance cannot be destroyed" leader.
if detect_would_fire "$OLD_WORDING"; then
  test_pass "detection fires on the older 'Instance cannot be destroyed' wording"
else
  test_fail "detection missed the older wording — regression for #741"
fi

test_start "PD.3" "current tofu wording matches (has lifecycle.prevent_destroy set)"
NEW_WORDING='╷
│ Error: Resource cannot be destroyed
│
│   on ../modules/proxmox-vm-precious/vm.tf line 22:
│   22:   lifecycle {
│
│ Resource module.cicd.proxmox_virtual_environment_vm.vm has
│ lifecycle.prevent_destroy set, but the plan calls for this resource
│ to be destroyed. If you do want to destroy this resource, either
│ change or disable the lifecycle.prevent_destroy argument, or remove
│ the resource from the configuration.
╵'
# This case is exactly what current OpenTofu emits — the #741 defect.
# The old grep pattern ("Instance cannot be destroyed" only) did NOT
# match because current tofu writes "Resource cannot be destroyed"
# on the leader and "has lifecycle.prevent_destroy set, but the plan
# calls for this resource to be destroyed" as the body — no
# "Instance cannot be destroyed" substring anywhere.
if detect_would_fire "$NEW_WORDING"; then
  test_pass "detection fires on the current 'has lifecycle.prevent_destroy set' wording"
else
  test_fail "detection missed the current wording — #741 has regressed"
fi

test_start "PD.4" "unrelated infra error does NOT match (fail-closed)"
UNRELATED='Error: Failed to load state: connection to backend refused
│
│ The tofu backend could not open the state file. This is a transient
│ infrastructure error unrelated to any resource lifecycle.'
# The detection must NOT match an unrelated exit-1 error — that path
# is meant to die() so the operator investigates. A too-loose grep
# (e.g. matching bare "prevent_destroy" anywhere) could silently
# route a real infra error into the destroy-recreate ladder.
if ! detect_would_fire "$UNRELATED"; then
  test_pass "detection correctly does NOT fire on an unrelated infra error"
else
  test_fail "detection over-matched on an unrelated error — safety regression"
fi

test_start "PD.5" "empty stderr does NOT match"
if ! detect_would_fire ""; then
  test_pass "detection correctly does NOT fire on empty stderr"
else
  test_fail "detection matched on empty stderr — safety regression"
fi

runner_summary
