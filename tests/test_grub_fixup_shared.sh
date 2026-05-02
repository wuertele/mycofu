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

runner_summary
