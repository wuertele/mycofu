#!/usr/bin/env bash
# Test runner framework — pass/fail tracking and formatted output

_PASS_COUNT=0
_FAIL_COUNT=0
_WARN_COUNT=0
_SKIP_COUNT=0
_FAILURES=()
_WARNINGS=()

test_start() {
  local id="$1" desc="$2"
  echo ""
  echo "--- ${id}: ${desc} ---"
}

test_pass() {
  local detail="$1"
  _PASS_COUNT=$((_PASS_COUNT + 1))
  echo "  ✓ ${detail}"
}

test_fail() {
  local detail="$1"
  _FAIL_COUNT=$((_FAIL_COUNT + 1))
  _FAILURES+=("${detail}")
  echo "  ✗ ${detail}"
}

test_warn() {
  local detail="$1"
  _WARN_COUNT=$((_WARN_COUNT + 1))
  _WARNINGS+=("${detail}")
  echo "  ⚠ ${detail}"
}

test_skip() {
  local reason="$1"
  _SKIP_COUNT=$((_SKIP_COUNT + 1))
  echo "  ⊘ Skip: ${reason}"
}

runner_summary() {
  echo ""
  echo "=== Summary ==="
  echo "Passed: ${_PASS_COUNT}  Failed: ${_FAIL_COUNT}  Warnings: ${_WARN_COUNT}  Skipped: ${_SKIP_COUNT}"

  if [[ $_WARN_COUNT -gt 0 ]]; then
    echo ""
    echo "Warnings:"
    for w in "${_WARNINGS[@]}"; do
      echo "  - ${w}"
    done
  fi

  if [[ $_FAIL_COUNT -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for f in "${_FAILURES[@]}"; do
      echo "  - ${f}"
    done
    echo ""
    echo "RESULT: FAIL"
    exit 1
  else
    echo ""
    echo "RESULT: PASS"
    exit 0
  fi
}
