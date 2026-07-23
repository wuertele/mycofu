#!/usr/bin/env bash
#
# Regression test for issue #430: gitlab-gen-secrets recursive chowns must
# tolerate files that disappear mid-traversal (the postgres pg_internal.init
# race during closure-switch re-runs).
#
# The fix introduces a chown_recursive_tolerant helper and uses it for ALL
# three recursive chowns in the gitlab-gen-secrets script (postgresql,
# statePath, SECRETS_DIR). This test asserts that the helper exists and
# that no bare `chown -R` calls remain in the script body — if a future
# refactor reverts to bare chown -R, the race returns and the next dev
# pipeline that updates the gitlab closure will fail at
# deploy:control-plane:gitlab:dev with "No such file or directory" exit 1.
#
# This is a static-text check on the NixOS module. The race itself is hard
# to exercise deterministically; the structural check catches the regression
# class.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

MODULE="${REPO_ROOT}/framework/nix/modules/gitlab.nix"

if [[ ! -f "${MODULE}" ]]; then
  echo "ERROR: ${MODULE} not found"
  exit 1
fi

# Extract just the gitlab-gen-secrets ExecStart script body (between the
# heredoc delimiters) so subsequent checks don't get confused by other
# chown calls elsewhere in the file (e.g., gitlab-format-vdb).
SCRIPT_BLOCK=$(awk '
  /writeShellScript "gitlab-gen-secrets"/ { in_script=1; next }
  in_script && /^      '"'"''"'"';/      { exit }
  in_script
' "${MODULE}")

if [[ -z "${SCRIPT_BLOCK}" ]]; then
  echo "ERROR: failed to extract gitlab-gen-secrets script body from ${MODULE}"
  exit 1
fi

test_start "1" "gitlab-gen-secrets defines chown_recursive_tolerant helper"

if printf '%s\n' "${SCRIPT_BLOCK}" | grep -qE '^\s*chown_recursive_tolerant\(\)'; then
  test_pass "chown_recursive_tolerant() function is defined"
else
  test_fail "chown_recursive_tolerant() function not defined in gitlab-gen-secrets script (issue #430)"
fi

test_start "2" "no bare 'chown -R' remains in gitlab-gen-secrets script body"

# Match bare 'chown -R' (with whitespace before it), not chown_recursive_tolerant
BARE_CHOWN_COUNT=$(printf '%s\n' "${SCRIPT_BLOCK}" | grep -cE '^\s*chown -R ' || true)

if [[ "${BARE_CHOWN_COUNT}" -eq 0 ]]; then
  test_pass "no bare 'chown -R' calls (all use chown_recursive_tolerant)"
else
  test_fail "found ${BARE_CHOWN_COUNT} bare 'chown -R' call(s) — must use chown_recursive_tolerant (issue #430)"
  # Show the offending lines for diagnosis
  printf '%s\n' "${SCRIPT_BLOCK}" | grep -nE '^\s*chown -R ' | sed 's/^/    OFFENDER: /' >&2
fi

test_start "3" "at least 3 chown_recursive_tolerant calls (postgresql, statePath, SECRETS_DIR)"

TOLERANT_COUNT=$(printf '%s\n' "${SCRIPT_BLOCK}" | grep -cE '^\s*chown_recursive_tolerant ' || true)

if [[ "${TOLERANT_COUNT}" -ge 3 ]]; then
  test_pass "found ${TOLERANT_COUNT} chown_recursive_tolerant calls (≥ 3 required)"
else
  test_fail "found ${TOLERANT_COUNT} chown_recursive_tolerant calls, expected ≥ 3 — covering postgresql, statePath, and SECRETS_DIR (issue #430)"
fi

test_start "4" "helper filters ENOENT but surfaces other errors"

# Sanity check: the helper body must contain both the ENOENT filter and a
# non-zero return path. If a future refactor swallows ALL errors (e.g., just
# 'chown -R ... 2>/dev/null || true'), the test should catch that regression.
HELPER_BLOCK=$(printf '%s\n' "${SCRIPT_BLOCK}" | awk '
  /^[[:space:]]*chown_recursive_tolerant\(\)/ { in_fn=1 }
  in_fn { print }
  in_fn && /^[[:space:]]*\}/ { exit }
')

if [[ -z "${HELPER_BLOCK}" ]]; then
  test_fail "could not extract chown_recursive_tolerant function body"
else
  if printf '%s\n' "${HELPER_BLOCK}" | grep -qF "No such file or directory"; then
    test_pass "helper filters ENOENT (No such file or directory)"
  else
    test_fail "helper does not appear to filter ENOENT specifically (would swallow real errors or fail on benign race)"
  fi
  if printf '%s\n' "${HELPER_BLOCK}" | grep -qE 'return 1|exit 1'; then
    test_pass "helper has a non-zero exit path for real errors"
  else
    test_fail "helper has no return 1 / exit 1 — would silently swallow real chown errors"
  fi
fi

runner_summary
