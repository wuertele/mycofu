#!/usr/bin/env bash
# test_grub_fixup_shared.sh — Verify grub fixup extraction.
#
# Validates that converge_fix_grub_paths exists as a standalone function
# and that converge_step_closure calls it (not an inline sed).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

CONVERGE_LIB="${REPO_ROOT}/framework/scripts/converge-lib.sh"

test_start "1" "converge_fix_grub_paths function exists"
if grep -q "^converge_fix_grub_paths()" "$CONVERGE_LIB"; then
  test_pass "function defined"
else
  test_fail "converge_fix_grub_paths not found as standalone function"
fi

test_start "2" "converge_fix_grub_paths contains the grub sed"
if grep -A5 "^converge_fix_grub_paths()" "$CONVERGE_LIB" | grep -q ')/store/'; then
  test_pass "sed expression present in function"
else
  test_fail "sed expression not found in converge_fix_grub_paths"
fi

test_start "3" "converge_step_closure calls converge_fix_grub_paths"
# Extract the closure step function body and check for the call
if sed -n '/^converge_step_closure()/,/^}/p' "$CONVERGE_LIB" | grep -q 'converge_fix_grub_paths'; then
  test_pass "converge_step_closure calls converge_fix_grub_paths"
else
  test_fail "converge_step_closure does not call converge_fix_grub_paths"
fi

test_start "4" "No inline grub sed command in converge_step_closure"
# The inline sed command should be gone; only comments and the function call should remain
inline_sed_count=$(sed -n '/^converge_step_closure()/,/^}/p' "$CONVERGE_LIB" | grep -v '^[[:space:]]*#' | grep -c "sed.*)/store/" || true)
if [[ "$inline_sed_count" -eq 0 ]]; then
  test_pass "no inline grub sed command in converge_step_closure"
else
  test_fail "found ${inline_sed_count} inline grub sed commands in converge_step_closure"
fi

test_start "5" "Exactly one sed command for grub fixup in converge-lib.sh"
# Count actual sed commands (not comments) containing the grub pattern
total_sed=$(grep -v '^[[:space:]]*#' "$CONVERGE_LIB" | grep -c "sed.*)/store/" || true)
if [[ "$total_sed" -eq 1 ]]; then
  test_pass "exactly one sed command (in converge_fix_grub_paths)"
else
  test_fail "expected 1 sed command, found ${total_sed}"
fi

# The sed alone can be silently missed by an install-grub race, a
# variant path the regex doesn't match, or a control-flow bug. #339's
# hardening is: verify AFTER the sed that no )/store/ paths remain,
# and exit non-zero if any do. Without this, the caller can proceed to
# reboot a VM with a broken grub.cfg (which is exactly what bricked
# cicd on 2026-07-06 → #496). Assert the function body contains both
# the sed AND a follow-up grep that would fire on residual paths.
test_start "6" "converge_fix_grub_paths verifies )/store/ absent after sed (#339)"
fn_body=$(sed -n '/^converge_fix_grub_paths()/,/^}/p' "$CONVERGE_LIB")
# Non-comment lines only, so we don't match documentation
fn_code=$(echo "$fn_body" | grep -v '^[[:space:]]*#')
if echo "$fn_code" | grep -q "grep.*)/store/"; then
  test_pass "verify-after-write grep present"
else
  test_fail "converge_fix_grub_paths does not verify )/store/ absent after sed — a silently-missed sed can brick the VM (see #339 note 2774, #496)"
fi

test_start "7" "converge_fix_grub_paths verify emits non-zero exit on failure (#339)"
# The remote script must `exit 1` on residual paths so cert_ssh returns
# non-zero and the die at the outer level fires.
if echo "$fn_code" | grep -q "exit 1"; then
  test_pass "explicit exit 1 in remote script"
else
  test_fail "converge_fix_grub_paths does not exit 1 on verify failure — die would not fire"
fi

runner_summary
