#!/usr/bin/env bash
# test_restore_from_pbs_vdb_capture.sh — VDB_HAS_DATA capture must produce
# a single-line numeric value regardless of remote `grep -c` exit code (#451).
#
# Background: restore-from-pbs.sh used to capture VDB_HAS_DATA as:
#   VDB_HAS_DATA=$(ssh_node ... "blkid ... | grep -c TYPE" || echo "0")
# When `grep -c TYPE` matches zero lines, it prints "0\n" AND exits non-zero.
# ssh propagates both, then the outer `|| echo "0"` appends another "0\n".
# The captured string is "0\n0", and the subsequent `[[ "$VDB_HAS_DATA" -gt 0 ]]`
# chokes with "syntax error in expression (error token is "0")".
#
# Fix: move the "0" fallback INSIDE the remote command so ssh returns a
# single token, and pipe through `head -1` as defense-in-depth.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

# Extract the VDB_HAS_DATA capture block from the live script. We look for
# the `set +e` immediately before the assignment, then end at the
# normalization line `[[ -z "$VDB_HAS_DATA" ]] && VDB_HAS_DATA=0`. This
# couples the test to the fix; if someone reverts to the buggy form, the
# extracted snippet will exhibit the bug under the harness.
VDB_BLOCK_START=$(awk '/^ *set \+e *$/ { last_set=NR } /VDB_HAS_DATA=\$\(ssh_node/ { print last_set; exit }' \
  "${REPO_ROOT}/framework/scripts/restore-from-pbs.sh")
if [[ -z "$VDB_BLOCK_START" ]]; then
  # Fallback for the buggy form (no set +e wrap): start at the assignment line
  VDB_BLOCK_START=$(grep -n 'VDB_HAS_DATA=\$(ssh_node' \
    "${REPO_ROOT}/framework/scripts/restore-from-pbs.sh" | head -1 | cut -d: -f1)
fi
VDB_BLOCK_END=$(awk -v start="$VDB_BLOCK_START" 'NR>=start {
    print;
    # Stop at the explicit end-of-block markers:
    #   - new fixed form: `... && VDB_HAS_DATA=0` (the empty-string normalization)
    #   - legacy buggy form: assignment line ending with `|| echo "0")`
    if (/&& VDB_HAS_DATA=0/ || /\|\| echo "0"\)$/) { exit }
  }' "${REPO_ROOT}/framework/scripts/restore-from-pbs.sh" | wc -l)

# Build a hermetic harness that uses a fake ssh_node returning configurable
# output + exit code. The harness then runs the actual capture line and
# inspects the result.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Extract the VDB_HAS_DATA capture snippet
sed -n "${VDB_BLOCK_START},$((VDB_BLOCK_START + VDB_BLOCK_END - 1))p" \
  "${REPO_ROOT}/framework/scripts/restore-from-pbs.sh" > "${TMP_DIR}/snippet.sh"

# Build the harness
HARNESS="${TMP_DIR}/harness.sh"
cat > "$HARNESS" <<'HARNESS_EOF'
#!/usr/bin/env bash
set -euo pipefail

# Fake ssh_node — emits FAKE_SSH_OUT then exits FAKE_SSH_RC
ssh_node() {
  printf '%s' "${FAKE_SSH_OUT:-}"
  return "${FAKE_SSH_RC:-0}"
}

HOSTING_IP="fake-host"
STORAGE_POOL="vmstore"
VDB_ZVOL="vm-303-disk-1"

HARNESS_EOF
cat "${TMP_DIR}/snippet.sh" >> "$HARNESS"
cat >> "$HARNESS" <<'HARNESS_EOF'

# Probe: assert VDB_HAS_DATA is a single line containing only digits
printf 'VDB_HAS_DATA=%q\n' "$VDB_HAS_DATA"
if [[ "$VDB_HAS_DATA" =~ ^[0-9]+$ ]]; then
  printf 'shape=clean-integer\n'
else
  printf 'shape=malformed (contains newline or non-digit)\n'
fi

# Probe: try the actual downstream `[[ -gt 0 ]]` test the buggy form choked on
if [[ "$VDB_HAS_DATA" -gt 0 ]] 2>/dev/null; then
  printf 'gt-test=true\n'
elif [[ "$VDB_HAS_DATA" -le 0 ]] 2>/dev/null; then
  printf 'gt-test=false\n'
else
  printf 'gt-test=error\n'
fi
HARNESS_EOF
chmod +x "$HARNESS"

run_harness() {
  set +e
  OUT="$(FAKE_SSH_OUT="$1" FAKE_SSH_RC="$2" bash "$HARNESS" 2>&1)"
  RC=$?
  set -e
}

# --- Test cases ---

test_start "RFP.1" "remote grep matched (rc=0, output '1') → integer 1, gt-test true"
run_harness "1
" 0
if grep -Fq 'shape=clean-integer' <<< "$OUT" && grep -Fq 'gt-test=true' <<< "$OUT"; then
  test_pass "happy path captures integer"
else
  test_fail "happy path did not produce a clean integer"
  printf '%s\n' "$OUT" >&2
fi

test_start "RFP.2" "remote grep matched zero lines (rc=1, output '0') → integer 0, no syntax error"
run_harness "0
" 1
if grep -Fq 'shape=clean-integer' <<< "$OUT" && grep -Fq 'gt-test=false' <<< "$OUT" \
   && ! grep -Fq 'syntax error in expression' <<< "$OUT"; then
  test_pass "zero-match case captures '0' without [[: syntax error"
else
  test_fail "zero-match case still produces multi-line/syntax error (#451 regression)"
  printf '%s\n' "$OUT" >&2
fi

test_start "RFP.3" "remote command failed entirely (rc=255, no output) → integer 0, no error"
run_harness "" 255
if grep -Fq 'shape=clean-integer' <<< "$OUT" && grep -Fq 'gt-test=false' <<< "$OUT" \
   && ! grep -Fq 'syntax error in expression' <<< "$OUT"; then
  test_pass "ssh failure case captures '0'"
else
  test_fail "ssh failure case did not produce clean 0"
  printf '%s\n' "$OUT" >&2
fi

test_start "RFP.4" "remote grep matched multiple TYPE lines (rc=0, output '2') → integer 2, gt-test true"
run_harness "2
" 0
if grep -Fq 'shape=clean-integer' <<< "$OUT" && grep -Fq 'gt-test=true' <<< "$OUT"; then
  test_pass "multi-match case captures positive integer"
else
  test_fail "multi-match case did not capture positive integer"
  printf '%s\n' "$OUT" >&2
fi

runner_summary
