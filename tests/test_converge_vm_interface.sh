#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/converge-vm.sh"
LIB="${REPO_ROOT}/framework/scripts/converge-lib.sh"

run_capture() {
  set +e
  local output
  output="$("$@" 2>&1)"
  local status=$?
  set -e

  printf '%s\n__OUTPUT__\n%s\n' "${status}" "${output}"
}

capture_status() {
  printf '%s\n' "$1" | sed -n '1p'
}

capture_output() {
  printf '%s\n' "$1" | sed -n '3,$p'
}

assert_usage_error_for_missing_value() {
  local option="$1"
  local result="$2"
  local status output

  status="$(capture_status "${result}")"
  output="$(capture_output "${result}")"
  if [[ "${status}" == "2" && "${output}" == *"${option} requires a value"* ]]; then
    test_pass "${option} missing value returns usage error"
  else
    test_fail "${option} missing value returns usage error"
    printf '    output:\n%s\n' "${output}" >&2
  fi
}

test_start "4.1" "converge-vm.sh --help exits 0 and prints usage"
HELP_RESULT="$(run_capture "${SCRIPT}" --help)"
HELP_STATUS="$(capture_status "${HELP_RESULT}")"
HELP_OUTPUT="$(capture_output "${HELP_RESULT}")"
if [[ "${HELP_STATUS}" == "0" && "${HELP_OUTPUT}" == *"Usage:"* ]]; then
  test_pass "--help exits 0 and prints usage"
else
  test_fail "--help exits 0 and prints usage"
  printf '    output:\n%s\n' "${HELP_OUTPUT}" >&2
fi

test_start "4.2" "converge-vm.sh without --config exits non-zero with a clear error"
MISSING_CONFIG_RESULT="$(run_capture "${SCRIPT}")"
MISSING_CONFIG_STATUS="$(capture_status "${MISSING_CONFIG_RESULT}")"
MISSING_CONFIG_OUTPUT="$(capture_output "${MISSING_CONFIG_RESULT}")"
if [[ "${MISSING_CONFIG_STATUS}" == "2" && "${MISSING_CONFIG_OUTPUT}" == *"--config is required"* ]]; then
  test_pass "missing --config is rejected"
else
  test_fail "missing --config is rejected"
  printf '    output:\n%s\n' "${MISSING_CONFIG_OUTPUT}" >&2
fi

test_start "4.3" "options that require values fail with usage errors under set -u"
assert_usage_error_for_missing_value "--config" "$(run_capture "${SCRIPT}" --config)"
assert_usage_error_for_missing_value "--apps-config" "$(run_capture "${SCRIPT}" --apps-config)"
assert_usage_error_for_missing_value "--targets" "$(run_capture "${SCRIPT}" --targets)"
assert_usage_error_for_missing_value "--closure" "$(run_capture "${SCRIPT}" --closure)"
assert_usage_error_for_missing_value "--repo-dir" "$(run_capture "${SCRIPT}" --repo-dir)"

test_start "4.4" "converge-vm.sh accepts --closure when a path is provided"
CLOSURE_ACCEPT_RESULT="$(
  run_capture \
    "${SCRIPT}" \
    --config "${REPO_ROOT}/site/config.yaml" \
    --apps-config "${REPO_ROOT}/site/applications.yaml" \
    --closure "${REPO_ROOT}"
)"
CLOSURE_ACCEPT_STATUS="$(capture_status "${CLOSURE_ACCEPT_RESULT}")"
CLOSURE_ACCEPT_OUTPUT="$(capture_output "${CLOSURE_ACCEPT_RESULT}")"
if [[ "${CLOSURE_ACCEPT_STATUS}" != "2" && "${CLOSURE_ACCEPT_OUTPUT}" == *"--closure requires exactly one --targets module"* ]]; then
  test_pass "--closure accepts a provided path and reaches closure validation"
else
  test_fail "--closure accepts a provided path and reaches closure validation"
  printf '    output:\n%s\n' "${CLOSURE_ACCEPT_OUTPUT}" >&2
fi

test_start "4.5" "unknown targets are rejected before convergence runs"
UNKNOWN_TARGET_RESULT="$(
  run_capture \
    "${SCRIPT}" \
    --config "${REPO_ROOT}/site/config.yaml" \
    --apps-config "${REPO_ROOT}/site/applications.yaml" \
    --targets "-target=module.vautl_dev"
)"
UNKNOWN_TARGET_STATUS="$(capture_status "${UNKNOWN_TARGET_RESULT}")"
UNKNOWN_TARGET_OUTPUT="$(capture_output "${UNKNOWN_TARGET_RESULT}")"
if [[ "${UNKNOWN_TARGET_STATUS}" != "0" \
   && "${UNKNOWN_TARGET_OUTPUT}" == *"Unknown target module(s): module.vautl_dev"* \
   && "${UNKNOWN_TARGET_OUTPUT}" != *"=== Step"* ]]; then
  test_pass "unknown target modules fail closed before convergence starts"
else
  test_fail "unknown target modules fail closed before convergence starts"
  printf '    output:\n%s\n' "${UNKNOWN_TARGET_OUTPUT}" >&2
fi

test_start "4.6" "converge-vm.sh rejects a nonexistent config path"
BAD_CONFIG_RESULT="$(
  run_capture \
    "${SCRIPT}" \
    --config /nonexistent/config.yaml \
    --apps-config "${REPO_ROOT}/site/applications.yaml"
)"
BAD_CONFIG_STATUS="$(capture_status "${BAD_CONFIG_RESULT}")"
BAD_CONFIG_OUTPUT="$(capture_output "${BAD_CONFIG_RESULT}")"
if [[ "${BAD_CONFIG_STATUS}" != "0" && "${BAD_CONFIG_OUTPUT}" == *"Config file not found"* ]]; then
  test_pass "nonexistent config path is rejected"
else
  test_fail "nonexistent config path is rejected"
  printf '    output:\n%s\n' "${BAD_CONFIG_OUTPUT}" >&2
fi

test_start "4.7" "bash -n passes for converge-vm.sh and converge-lib.sh"
if bash -n "${SCRIPT}" && bash -n "${LIB}"; then
  test_pass "bash -n passes for both convergence scripts"
else
  test_fail "bash -n passes for both convergence scripts"
fi

test_start "4.8" "PBS targets are rejected with a clear message"
PBS_RESULT="$(
  run_capture \
    "${SCRIPT}" \
    --config "${REPO_ROOT}/site/config.yaml" \
    --apps-config "${REPO_ROOT}/site/applications.yaml" \
    --targets "-target=module.pbs"
)"
PBS_STATUS="$(capture_status "${PBS_RESULT}")"
PBS_OUTPUT="$(capture_output "${PBS_RESULT}")"
if [[ "${PBS_STATUS}" != "0" && "${PBS_OUTPUT}" == *"PBS convergence is not supported in Phase 1"* ]]; then
  test_pass "module.pbs is rejected before convergence runs"
else
  test_fail "module.pbs is rejected before convergence runs"
  printf '    output:\n%s\n' "${PBS_OUTPUT}" >&2
fi

runner_summary
