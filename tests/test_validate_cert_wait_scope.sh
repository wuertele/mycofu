#!/usr/bin/env bash
#
# Regression test for issue #277: validate.sh must not call wait_for_certs
# when prod is out of scope. Pre-fix, dev pipeline runs blocked 600s on prod
# cert state because Gatus cert-monitor records are predominantly prod.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

VALIDATE_SH="${REPO_ROOT}/framework/scripts/validate.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Extract the env-scope guard block from validate.sh and verify behavior
# with shimmed wait_for_certs / check_skip. Source the block in a subshell
# with the desired ENVS array; confirm only the expected branch fires.

extract_guard() {
  awk '
    /^# wait_for_certs enumerates endpoints from$/,/^unset WAIT_FOR_CERTS_SCOPED$/
  ' "${VALIDATE_SH}"
}

GUARD_FILE="${TMP_DIR}/guard.sh"
extract_guard > "${GUARD_FILE}"

if [[ ! -s "${GUARD_FILE}" ]]; then
  echo "ERROR: failed to extract env-scope guard from ${VALIDATE_SH}"
  exit 2
fi

EXPECTED_LINES=14
ACTUAL_LINES="$(wc -l < "${GUARD_FILE}")"
if [[ "${ACTUAL_LINES}" -lt "${EXPECTED_LINES}" ]]; then
  echo "ERROR: extracted guard is shorter than expected (${ACTUAL_LINES} < ${EXPECTED_LINES})"
  cat "${GUARD_FILE}"
  exit 2
fi

run_guard() {
  local marker_file="${TMP_DIR}/marker"
  rm -f "${marker_file}"

  bash <(cat <<EOF
set -euo pipefail
ENVS=( $* )
wait_for_certs() { printf 'wait_for_certs\n' >> "${marker_file}"; }
check_skip()    { printf 'check_skip %s | %s\n' "\$1" "\$2" >> "${marker_file}"; }
$(cat "${GUARD_FILE}")
EOF
)
  cat "${marker_file}" 2>/dev/null || true
}

test_start "1" "ENVS=(dev) skips wait_for_certs and emits check_skip"
OUT="$(run_guard dev)"
if [[ "${OUT}" == check_skip* ]]; then
  test_pass "ENVS=(dev) emits check_skip not wait_for_certs"
else
  test_fail "ENVS=(dev) emits check_skip not wait_for_certs"
  printf '    output: %s\n' "${OUT}" >&2
fi
if [[ "${OUT}" == *"prod not in scope"* ]]; then
  test_pass "check_skip reason mentions 'prod not in scope'"
else
  test_fail "check_skip reason mentions 'prod not in scope'"
  printf '    output: %s\n' "${OUT}" >&2
fi

test_start "2" "ENVS=(prod) calls wait_for_certs"
OUT="$(run_guard prod)"
if [[ "${OUT}" == "wait_for_certs" ]]; then
  test_pass "ENVS=(prod) calls wait_for_certs"
else
  test_fail "ENVS=(prod) calls wait_for_certs"
  printf '    output: %s\n' "${OUT}" >&2
fi

test_start "3" "ENVS=(prod dev) calls wait_for_certs"
OUT="$(run_guard prod dev)"
if [[ "${OUT}" == "wait_for_certs" ]]; then
  test_pass "ENVS=(prod dev) calls wait_for_certs"
else
  test_fail "ENVS=(prod dev) calls wait_for_certs"
  printf '    output: %s\n' "${OUT}" >&2
fi

test_start "4" "ENVS=(dev prod) calls wait_for_certs (order-independent)"
OUT="$(run_guard dev prod)"
if [[ "${OUT}" == "wait_for_certs" ]]; then
  test_pass "ENVS=(dev prod) calls wait_for_certs"
else
  test_fail "ENVS=(dev prod) calls wait_for_certs"
  printf '    output: %s\n' "${OUT}" >&2
fi

test_start "5" "Substring values containing 'prod' do NOT spuriously match"
OUT="$(run_guard production prods prod-test)"
if [[ "${OUT}" == check_skip* ]]; then
  test_pass "ENVS=(production prods prod-test) correctly does NOT match"
else
  test_fail "ENVS=(production prods prod-test) correctly does NOT match"
  printf '    output: %s\n' "${OUT}" >&2
fi

runner_summary
