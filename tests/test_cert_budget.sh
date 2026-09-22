#!/usr/bin/env bash
# Test cert budget preflight check.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

test_start "5.1" "cert budget skips dev environment"
OUTPUT=$(framework/scripts/check-cert-budget.sh dev 2>&1)
RC=$?
if [[ $RC -eq 0 ]] && echo "$OUTPUT" | grep -q "Pebble"; then
  test_pass "dev environment skipped with Pebble message"
else
  test_fail "dev environment should skip with exit 0"
fi

test_start "5.2" "cert budget respects --ignore-cert-budget"
OUTPUT=$(framework/scripts/check-cert-budget.sh --ignore-cert-budget prod 2>&1)
RC=$?
if [[ $RC -eq 0 ]] && echo "$OUTPUT" | grep -q "skipped"; then
  test_pass "--ignore-cert-budget produces warning and exits 0"
else
  test_fail "--ignore-cert-budget should exit 0 with warning"
fi

test_start "5.3" "cert budget rejects invalid arguments"
set +e
OUTPUT=$(framework/scripts/check-cert-budget.sh 2>&1)
RC=$?
set -e
if [[ $RC -eq 2 ]]; then
  test_pass "no arguments exits 2"
else
  test_fail "no arguments should exit 2, got $RC"
fi

test_start "5.4" "cert budget script passes bash -n"
if bash -n framework/scripts/check-cert-budget.sh 2>&1; then
  test_pass "syntax check passes"
else
  test_fail "syntax check failed"
fi

test_start "5.5" "cert budget script is executable"
if [[ -x framework/scripts/check-cert-budget.sh ]]; then
  test_pass "script is executable"
else
  test_fail "script is not executable"
fi

runner_summary
