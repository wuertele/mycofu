#!/usr/bin/env bash
# Hermetic regression test for #347:
#   - reset-cluster.sh --vms must NOT clear CIDATA snippets (let tofu
#     manage them); the historical broad rm broke HA migration after
#     partial-scope rebuilds.
#   - validate.sh R2.1 must report which snippets are missing on which
#     node when the snippet sets diverge, not just "counts differ".
#
# This test is static-analysis-shaped: it verifies the source changes
# are in place. A full end-to-end simulation (reset → partial rebuild →
# validate) requires mocking ssh + ha-manager + pvesr + tofu + ZFS
# across multiple nodes and is out of scope for this mycofu-fix; see
# follow-up if the operator wants e2e coverage.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

RESET="${REPO_ROOT}/framework/scripts/reset-cluster.sh"
VALIDATE="${REPO_ROOT}/framework/scripts/validate.sh"

# --- TC1: reset-cluster.sh does not rm snippets in --vms path -----------

test_start "TC1" "reset-cluster.sh's --vms path does not rm /var/lib/vz/snippets"

if grep -qE 'rm[[:space:]]+-f[[:space:]]+/var/lib/vz/snippets' "$RESET"; then
  test_fail "TC1: reset-cluster.sh still contains rm of /var/lib/vz/snippets — would re-introduce the #347 regression"
  echo "    matching line(s):"
  grep -n 'rm.*snippets' "$RESET" | sed 's/^/      /'
else
  test_pass "TC1: no rm of /var/lib/vz/snippets in reset-cluster.sh"
fi

# Sanity check: the safety-net comment block (or equivalent rationale)
# is present, so a future cleanup pass doesn't drop the reasoning along
# with the dead code.
if grep -qE '#347|CIDATA snippets are NOT cleared' "$RESET"; then
  test_pass "TC1b: rationale comment for snippet-clear removal is present"
else
  test_fail "TC1b: no comment explaining why the snippet-clear was removed"
fi

# --- TC2: validate.sh R2.1 prints missing snippets on failure -----------

test_start "TC2" "validate.sh R2.1 diagnostic identifies missing snippets per node"

# The new R2.1 uses check_capture (which prints output on FAIL), and the
# implementation must compute the union of all per-node snippet sets and
# emit a "missing: ..." line per divergent node. Verify both: the
# check_capture invocation and the missing-set computation.

if grep -nB1 -A3 'R2.1: CIDATA snippets' "$VALIDATE" | grep -q 'check_capture'; then
  test_pass "TC2a: R2.1 uses check_capture (prints output on FAIL)"
else
  test_fail "TC2a: R2.1 does not use check_capture — failure output won't surface to operator"
fi

# The diff between union and per-node set must use a real diff utility
# (comm -23 is the convention) and must surface "missing" in the output.
# Extract the R2.1 block (from label to the next `check` invocation) so
# the assertions are bounded by the actual region, not a fixed line count.
R21_BLOCK="$(awk '
  /R2.1: CIDATA snippets/ {capture=1}
  capture {print}
  capture && /^[[:space:]]*check / && NR > 1 && !/R2.1/ {exit}
' "$VALIDATE")"

if printf '%s\n' "$R21_BLOCK" | grep -qE 'comm[[:space:]]+-23'; then
  test_pass "TC2b: R2.1 uses 'comm -23' to compute per-node missing snippets"
else
  test_fail "TC2b: R2.1 does not appear to compute set diff with 'comm -23'"
fi

if printf '%s\n' "$R21_BLOCK" | grep -q 'missing:'; then
  test_pass "TC2c: R2.1 diagnostic includes 'missing:' label for divergent nodes"
else
  test_fail "TC2c: R2.1 diagnostic does not label missing snippets"
fi

# --- TC3: behavioral test of R2.1 bash against synthetic snippet sets ---
#
# Reproduce the R2.1 check's bash body against three synthetic per-node
# snippet directories and assert the diagnostic output. If validate.sh's
# R2.1 logic changes shape, update this test alongside.

test_start "TC3" "R2.1 logic flags missing snippets per node on simulated divergence"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Three nodes with divergent snippet sets:
#   pve01 missing gitlab-user-data.yaml
#   pve02 has the full set
#   pve03 missing workstation-dev-user-data.yaml
mkdir -p "${WORK}/pve01" "${WORK}/pve02" "${WORK}/pve03"
common='cicd-user-data.yaml dns1-prod-user-data.yaml vault-prod-user-data.yaml'
for f in $common; do touch "${WORK}/pve01/$f" "${WORK}/pve02/$f" "${WORK}/pve03/$f"; done
touch "${WORK}/pve02/gitlab-user-data.yaml"
touch "${WORK}/pve03/gitlab-user-data.yaml"
touch "${WORK}/pve01/workstation-dev-user-data.yaml"
touch "${WORK}/pve02/workstation-dev-user-data.yaml"

# Mirror the R2.1 logic (sorted per-node lists + union + comm).
# Everything stays under ${WORK} so the single EXIT trap covers cleanup.
SETS_DIR="${WORK}/sets"
mkdir -p "${SETS_DIR}"

NODE_NAMES=(pve01 pve02 pve03)
for n in "${NODE_NAMES[@]}"; do
  ( cd "${WORK}/$n" && ls *.yaml 2>/dev/null || true ) | sort -u > "${SETS_DIR}/$n"
done
UNION="${SETS_DIR}/_union"
: > "${UNION}"
for n in "${NODE_NAMES[@]}"; do
  cat "${SETS_DIR}/$n" >> "${UNION}"
done
sort -u "${UNION}" -o "${UNION}"
TOTAL=$(wc -l < "${UNION}" | tr -d ' ')

OUTPUT="${WORK}/r21-output"
: > "${OUTPUT}"
RC=0
for n in "${NODE_NAMES[@]}"; do
  COUNT=$(wc -l < "${SETS_DIR}/$n" | tr -d ' ')
  if [[ $COUNT -eq $TOTAL ]]; then
    echo "$n: $COUNT/$TOTAL snippets present" >> "$OUTPUT"
  else
    MISSING=$(comm -23 "${UNION}" "${SETS_DIR}/$n" | paste -sd, -)
    echo "$n: $COUNT/$TOTAL snippets (missing: $MISSING)" >> "$OUTPUT"
    RC=1
  fi
done

# Assert: exit code 1 (divergence found)
if [[ $RC -eq 1 ]]; then
  test_pass "TC3a: divergence detected (exit 1)"
else
  test_fail "TC3a: did not detect divergence (exit $RC); fixture was 3 nodes with 2 divergent sets"
fi

# Assert: pve01 missing gitlab named
if grep -q 'pve01: 4/5 snippets (missing: gitlab-user-data.yaml)' "$OUTPUT"; then
  test_pass "TC3b: pve01's missing snippet named correctly"
else
  test_fail "TC3b: pve01 diagnostic incorrect; got:"
  grep '^pve01' "$OUTPUT" | sed 's/^/      /'
fi

# Assert: pve02 healthy (5/5)
if grep -q 'pve02: 5/5 snippets present' "$OUTPUT"; then
  test_pass "TC3c: pve02 reports 5/5 snippets present"
else
  test_fail "TC3c: pve02 diagnostic incorrect; got:"
  grep '^pve02' "$OUTPUT" | sed 's/^/      /'
fi

# Assert: pve03 missing workstation-dev named
if grep -q 'pve03: 4/5 snippets (missing: workstation-dev-user-data.yaml)' "$OUTPUT"; then
  test_pass "TC3d: pve03's missing snippet named correctly"
else
  test_fail "TC3d: pve03 diagnostic incorrect; got:"
  grep '^pve03' "$OUTPUT" | sed 's/^/      /'
fi

# --- TC4: R2.1 distinguishes SSH failure from snippet divergence -----

test_start "TC4" "R2.1 names ssh-unreachable nodes distinctively (not as 'missing every snippet')"

# Verify the source pattern: the new R2.1 must emit a line containing
# "ssh unreachable:" and "(snippet state unknown)" when ssh fails, and
# must skip the per-node missing-snippet report for the failed node so
# the operator isn't chasing a phantom divergence.
if grep -q 'ssh unreachable:' "$VALIDATE"; then
  test_pass "TC4a: R2.1 source emits an 'ssh unreachable:' line on ssh failure"
else
  test_fail "TC4a: R2.1 source does not distinguish ssh failure from snippet divergence"
fi

if grep -q 'snippet state unknown' "$VALIDATE"; then
  test_pass "TC4b: R2.1 source labels ssh-failed nodes as 'snippet state unknown'"
else
  test_fail "TC4b: R2.1 source does not label ssh-failed nodes"
fi

# Verify the bash -c body has set -euo pipefail (otherwise a yq failure
# during the data-collection phase could silently propagate as success).
if grep -A2 'R2.1: CIDATA snippets' "$VALIDATE" | grep -q 'check_capture' \
   && grep -A6 'R2.1: CIDATA snippets' "$VALIDATE" | grep -q 'set -euo pipefail'; then
  test_pass "TC4c: R2.1 bash -c body uses set -euo pipefail"
else
  test_fail "TC4c: R2.1 bash -c body does not use set -euo pipefail"
fi

runner_summary
