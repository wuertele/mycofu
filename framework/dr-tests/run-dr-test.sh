#!/usr/bin/env bash
# run-dr-test.sh — Master runner for DR test scripts.
#
# Usage:
#   framework/dr-tests/run-dr-test.sh <DRT-ID>
#   framework/dr-tests/run-dr-test.sh              # list available tests
#
# Example:
#   framework/dr-tests/run-dr-test.sh DRT-001

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/tests"

# --- List available tests ---

list_tests() {
  echo "Available DR tests:"
  echo ""
  for script in "${TESTS_DIR}"/DRT-*.sh; do
    [[ -f "$script" ]] || continue
    local id name time destructive
    id=$(grep '^# DRT-ID:' "$script" | sed 's/^# DRT-ID: *//')
    name=$(grep '^# DRT-NAME:' "$script" | sed 's/^# DRT-NAME: *//')
    time=$(grep '^# DRT-TIME:' "$script" | sed 's/^# DRT-TIME: *//')
    destructive=$(grep '^# DRT-DESTRUCTIVE:' "$script" | sed 's/^# DRT-DESTRUCTIVE: *//')
    if [[ "$destructive" == "yes" ]]; then
      destructive="DESTRUCTIVE"
    else
      destructive="non-destructive"
    fi
    printf "  %-8s %-30s %-12s %s\n" "$id" "$name" "($time)" "$destructive"
  done
  echo ""
  echo "Usage: framework/dr-tests/run-dr-test.sh <DRT-ID>"
}

# --- Parse argument ---

if [[ $# -lt 1 ]]; then
  list_tests
  exit 1
fi

DRT_ID="$1"

# Find the test script
TEST_SCRIPT=$(find "${TESTS_DIR}" -name "${DRT_ID}-*.sh" -type f 2>/dev/null | head -1)

if [[ -z "$TEST_SCRIPT" ]]; then
  echo "ERROR: Test '${DRT_ID}' not found." >&2
  echo "" >&2
  list_tests >&2
  exit 1
fi

if [[ ! -x "$TEST_SCRIPT" ]]; then
  echo "ERROR: ${TEST_SCRIPT} is not executable. Run: chmod +x ${TEST_SCRIPT}" >&2
  exit 1
fi

# --- Find repo root and execute from there ---
REPO_ROOT="${SCRIPT_DIR}/../.."
cd "$REPO_ROOT"

exec "$TEST_SCRIPT"
