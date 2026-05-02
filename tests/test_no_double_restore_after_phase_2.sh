#!/usr/bin/env bash
# test_no_double_restore_after_phase_2.sh - no post-boot restore remains.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

DEPLOY_WORD="deploy"
OLD_RESTORE="restore-after-${DEPLOY_WORD}.sh"

test_start "1" "old post-boot restore script is deleted"
if [[ ! -e "${REPO_ROOT}/framework/scripts/${OLD_RESTORE}" ]]; then
  test_pass "${OLD_RESTORE} is absent"
else
  test_fail "${OLD_RESTORE} still exists"
fi

test_start "2" "deploy and rebuild paths do not call the old post-boot restore"
set +e
MATCHES="$(
  git -C "${REPO_ROOT}" grep -nF "${OLD_RESTORE}" -- \
    ':!docs/**' \
    ':!**/*.md' \
    ':!tests/test_no_double_restore_after_phase_2.sh'
)"
GREP_STATUS=$?
set -e

if [[ "$GREP_STATUS" -eq 1 ]]; then
  test_pass "no non-doc references to ${OLD_RESTORE} remain"
elif [[ "$GREP_STATUS" -eq 0 ]]; then
  test_fail "non-doc references to ${OLD_RESTORE} remain"
  printf '%s\n' "$MATCHES" >&2
else
  test_fail "git grep failed while checking for ${OLD_RESTORE}"
  printf '%s\n' "$MATCHES" >&2
fi

test_start "3" "safe-apply success path uses preboot restore exactly once"
if bash "${REPO_ROOT}/tests/test_safe_apply_preboot_restore.sh" >/dev/null; then
  test_pass "safe-apply preboot restore regression passes"
else
  test_fail "safe-apply preboot restore regression failed"
fi

runner_summary
