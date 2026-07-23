#!/usr/bin/env bash
#
# Behavioral regression test for chown_recursive_tolerant helper (issue #430).
#
# The companion test_gitlab_gen_secrets_chown_tolerant.sh asserts that the
# helper EXISTS and is called from the right places, but doesn't exercise its
# behavior. This test extracts the helper function body from gitlab.nix,
# evaluates it into the current shell, and runs it against a fake chown
# (PATH-overridden) that simulates each scenario the helper must handle:
#
#   1. All-ENOENT chown failures (the benign race) → helper returns 0
#   2. Mixed ENOENT + real error                  → helper returns 1
#   3. Non-zero chown exit with empty stderr      → helper returns 1
#   4. Successful chown                           → helper returns 0
#   5. Top-level directory does not exist         → helper returns 1
#   6. ENOENT-string-as-filename (e.g., a file literally named
#      "No such file or directory") with a real error                → helper returns 1
#
# Addresses codex P2 #4 + sub-claude P2-3 from the adversarial review of #430.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

MODULE="${REPO_ROOT}/framework/nix/modules/gitlab.nix"

if [[ ! -f "${MODULE}" ]]; then
  echo "ERROR: ${MODULE} not found"
  exit 1
fi

# Extract the gitlab-gen-secrets script body
SCRIPT_BLOCK=$(awk '
  /writeShellScript "gitlab-gen-secrets"/ { in_script=1; next }
  in_script && /^      '"'"''"'"';/      { exit }
  in_script
' "${MODULE}")

# Extract just the chown_recursive_tolerant function from that block
HELPER=$(printf '%s\n' "${SCRIPT_BLOCK}" | awk '
  /^[[:space:]]*chown_recursive_tolerant\(\)/ { in_fn=1 }
  in_fn { print }
  in_fn && /^[[:space:]]*\}$/ { exit }
')

if [[ -z "${HELPER}" ]]; then
  echo "ERROR: failed to extract chown_recursive_tolerant from ${MODULE}"
  exit 1
fi

# eval the helper into the current shell
eval "${HELPER}"

if ! declare -F chown_recursive_tolerant >/dev/null; then
  echo "ERROR: chown_recursive_tolerant not defined after eval"
  exit 1
fi

# Fake chown harness
TMP_BIN=$(mktemp -d)
trap "rm -rf ${TMP_BIN}" EXIT
ORIG_PATH="${PATH}"

# A real target directory the helper can exist-check against
TARGET_DIR="${TMP_BIN}/target"
mkdir -p "${TARGET_DIR}"

# Write a fake chown that emits given stderr and exits given code.
# Args: $1=stderr_content $2=exit_code
make_fake_chown() {
  cat > "${TMP_BIN}/chown" <<FAKEEOF
#!/bin/sh
$1
exit $2
FAKEEOF
  chmod +x "${TMP_BIN}/chown"
}

# Wrap chown_recursive_tolerant in a way that doesn't tip our test under set -e
run_helper() {
  local rc=0
  set +e
  PATH="${TMP_BIN}:${ORIG_PATH}" chown_recursive_tolerant "$@" 2>/tmp/helper_stderr.$$
  rc=$?
  set -e
  return $rc
}

#--- Test 1: all-ENOENT → return 0 ---
test_start "1" "all-ENOENT chown failures (benign race) → helper returns 0"

make_fake_chown 'echo "chown: changing ownership of '\''/foo/pg_internal.init'\'': No such file or directory" >&2' 1

if run_helper "u:g" "${TARGET_DIR}"; then
  test_pass "all-ENOENT returns 0"
else
  test_fail "all-ENOENT should return 0 (got non-zero)"
fi

#--- Test 2: mixed ENOENT + permission denied → return 1 ---
test_start "2" "mixed ENOENT + Permission denied → helper returns 1"

make_fake_chown '
echo "chown: changing ownership of '\''/foo/a'\'': No such file or directory" >&2
echo "chown: changing ownership of '\''/foo/b'\'': Permission denied" >&2' 1

if run_helper "u:g" "${TARGET_DIR}"; then
  test_fail "mixed errors should return 1 (got 0)"
else
  test_pass "mixed errors returns 1"
fi

#--- Test 3: non-zero with empty stderr → return 1 ---
test_start "3" "non-zero chown exit with empty stderr → helper returns 1"

make_fake_chown '' 1

if run_helper "u:g" "${TARGET_DIR}"; then
  test_fail "empty-stderr failure should return 1 (got 0)"
else
  test_pass "empty-stderr failure returns 1"
fi

#--- Test 4: successful chown → return 0 ---
test_start "4" "successful chown → helper returns 0"

make_fake_chown '' 0

if run_helper "u:g" "${TARGET_DIR}"; then
  test_pass "success returns 0"
else
  test_fail "success should return 0"
fi

#--- Test 5: top-level missing → return 1 ---
test_start "5" "missing top-level directory → helper returns 1 (precondition)"

# Even with a successful fake chown, the precondition should refuse
make_fake_chown '' 0

if run_helper "u:g" "${TMP_BIN}/this_does_not_exist"; then
  test_fail "missing top-level should return 1 (got 0)"
else
  test_pass "missing top-level returns 1"
fi

#--- Test 6: ENOENT-anchored match doesn't swallow real errors ---
# A real chown error that happens to contain the phrase "No such file or
# directory" in the FILENAME (not the suffix) should still be treated as a
# real error. This proves the anchor (`: No such file or directory$`) is
# doing its job vs the looser unanchored match.
test_start "6" "ENOENT-as-filename + real error → helper returns 1 (anchored)"

make_fake_chown 'echo "chown: changing ownership of '\''/foo/No such file or directory.txt'\'': Permission denied" >&2' 1

if run_helper "u:g" "${TARGET_DIR}"; then
  test_fail "real error with phrase-in-filename should return 1 (got 0)"
else
  test_pass "real error with phrase-in-filename returns 1"
fi

#--- Test 7: ENOENT-counter observability log ---
test_start "7" "ENOENT-count log emitted on benign-race success path"

make_fake_chown '
echo "chown: changing ownership of '\''/foo/a'\'': No such file or directory" >&2
echo "chown: changing ownership of '\''/foo/b'\'': No such file or directory" >&2
echo "chown: changing ownership of '\''/foo/c'\'': No such file or directory" >&2' 1

run_helper "u:g" "${TARGET_DIR}" || :
if grep -qE "filtered 3 ENOENT race" /tmp/helper_stderr.$$; then
  test_pass "filtered-count log present (observability)"
else
  test_fail "expected 'filtered 3 ENOENT race(s)' in stderr; got: $(cat /tmp/helper_stderr.$$)"
fi

rm -f /tmp/helper_stderr.$$

runner_summary
