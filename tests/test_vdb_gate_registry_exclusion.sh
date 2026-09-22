#!/usr/bin/env bash
# test_vdb_gate_registry_exclusion.sh - Fixture test for issue #526.
#
# Verifies that the vdb-gate substring scan (tests/test_vdb_gate_removed.sh
# checks 3/4) excludes forensic registry files from its target set while
# retaining full-strength coverage of prescriptive/authoritative docs.
#
# The test drives the SHARED helper vdb_gate_collect_rule_doc_targets against
# a controlled fixture layout under a temporary REPO_ROOT. That is the
# load-bearing coupling: if a future change removes the exclusion from the
# helper, this test fails.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/vdb_gate_targets.sh"

FIXTURE_ROOT="$(mktemp -d 2>/dev/null || mktemp -d -t vdbgate)"
trap 'rm -rf "${FIXTURE_ROOT}"' EXIT

mkdir -p "${FIXTURE_ROOT}/framework/dr-tests"
mkdir -p "${FIXTURE_ROOT}/framework/catalog"
mkdir -p "${FIXTURE_ROOT}/.claude/rules"

# Fixture A: DR-REGISTRY.md — forensic append-only log. Contains a NEGATED
# mention of the forbidden phrase. Correct behavior: not scanned, no FAIL.
cat > "${FIXTURE_ROOT}/framework/dr-tests/DR-REGISTRY.md" <<'MD'
# DR Registry (fixture)

DRT-999 (2026-07-10): scenario passed. No post-boot restore is run.
All vdb continuity was proven via ZFS GUID equality pre/post.
MD

# Fixture B: README.md in the same directory — this IS prescriptive framework
# documentation. Contains the forbidden phrase in a prescriptive form. Correct
# behavior: scanned, FAIL surfaces this line.
cat > "${FIXTURE_ROOT}/framework/dr-tests/README.md" <<'MD'
# DR Test Framework (fixture)

Legacy design: the runner performs a post-boot restore of vdb after guest start.
MD

# Fixture C: a rules doc containing a prescriptive mention. Correct behavior:
# scanned, FAIL surfaces this line.
cat > "${FIXTURE_ROOT}/.claude/rules/legacy-doctrine.md" <<'MD'
Prescriptive rule: use post-boot restore when vdb is empty on first boot.
MD

# Collect the target set from the shared helper against the fixture root.
FIXTURE_TARGETS=()
while IFS= read -r -d '' path; do
  FIXTURE_TARGETS+=("$path")
done < <(vdb_gate_collect_rule_doc_targets "${FIXTURE_ROOT}")

test_start "1" "DR-REGISTRY.md is NOT in the collected target set"
registry_seen=0
for t in "${FIXTURE_TARGETS[@]}"; do
  if [[ "$(basename "$t")" == "DR-REGISTRY.md" ]]; then
    registry_seen=1
    break
  fi
done
if [[ "${registry_seen}" -eq 0 ]]; then
  test_pass "helper omitted DR-REGISTRY.md from the target set"
else
  test_fail "helper included DR-REGISTRY.md in the target set (issue #526 regression)"
fi

test_start "2" "other framework/dr-tests markdown IS in the collected target set"
readme_seen=0
for t in "${FIXTURE_TARGETS[@]}"; do
  if [[ "$t" == *"framework/dr-tests/README.md" ]]; then
    readme_seen=1
    break
  fi
done
if [[ "${readme_seen}" -eq 1 ]]; then
  test_pass "helper included framework/dr-tests/README.md (prescriptive scope preserved)"
else
  test_fail "helper omitted framework/dr-tests/README.md — exclusion is over-broad"
fi

# Drive the actual grep from the guard against the fixture set. This is a full
# behavioural round-trip, not just a target-list assertion.
#
# Filter to targets that actually exist under the fixture root. In the real
# repo every default target exists; in this minimal fixture only the ones the
# test creates do. Filtering here keeps grep's exit status meaningful
# (0=match, 1=no-match) so the subsequent asserts read what they intend.
EXISTING_TARGETS=()
for t in "${FIXTURE_TARGETS[@]}"; do
  [[ -e "$t" ]] && EXISTING_TARGETS+=("$t")
done
# Guard against grep-hangs-on-stdin: if the helper ever produced zero
# existing targets, grep with no file args would block reading stdin. Fail
# loud instead of hanging.
if [[ "${#EXISTING_TARGETS[@]}" -eq 0 ]]; then
  echo "FATAL: fixture produced zero existing targets — grep would hang" >&2
  exit 2
fi

GREP_LOG="${FIXTURE_ROOT}/grep.log"
set +e
grep -rnE --include='*.md' -e "post-boot restore" "${EXISTING_TARGETS[@]}" > "${GREP_LOG}" 2>/dev/null
grep_status=$?
set -e

test_start "3" "grep over the collected target set does NOT surface DR-REGISTRY.md"
if [[ "${grep_status}" -eq 2 ]]; then
  test_fail "grep errored while scanning fixture targets"
  cat "${GREP_LOG}" >&2
elif grep -qF "DR-REGISTRY.md" "${GREP_LOG}"; then
  test_fail "DR-REGISTRY.md forensic mention tripped the substring scan"
  cat "${GREP_LOG}" >&2
else
  test_pass "forensic mention in DR-REGISTRY.md was not surfaced"
fi

test_start "4" "grep over the collected target set DOES surface prescriptive docs"
missing=0
if ! grep -qF ".claude/rules/legacy-doctrine.md" "${GREP_LOG}"; then
  test_fail "prescriptive .claude/rules mention was NOT surfaced (guard lost teeth on rules)"
  missing=1
fi
if ! grep -qF "framework/dr-tests/README.md" "${GREP_LOG}"; then
  test_fail "prescriptive framework/dr-tests/README.md mention was NOT surfaced (over-broad exclusion)"
  missing=1
fi
if [[ "${missing}" -eq 0 ]]; then
  test_pass "prescriptive docs were surfaced on both rules and dr-tests README paths"
fi

# Negative control: reproduce the PRE-FIX target selection (include every
# framework/dr-tests/*.md unconditionally) and confirm the same fixture WOULD
# have surfaced DR-REGISTRY.md. This proves the fixture is well-formed and
# that the fix in the helper is load-bearing — not a no-op.
test_start "5" "pre-fix target selection WOULD have surfaced DR-REGISTRY.md (negative control)"
PRE_FIX_TARGETS=("${FIXTURE_ROOT}/.claude/rules")
for path in "${FIXTURE_ROOT}"/framework/dr-tests/*.md; do
  [[ -e "$path" ]] && PRE_FIX_TARGETS+=("$path")
done
# (fixture-root paths only; all already exist by construction)
if [[ "${#PRE_FIX_TARGETS[@]}" -eq 0 ]]; then
  echo "FATAL: negative-control produced zero targets — grep would hang" >&2
  exit 2
fi
PRE_FIX_LOG="${FIXTURE_ROOT}/pre_fix_grep.log"
set +e
grep -rnE --include='*.md' -e "post-boot restore" "${PRE_FIX_TARGETS[@]}" > "${PRE_FIX_LOG}" 2>/dev/null
set -e
if grep -qF "DR-REGISTRY.md" "${PRE_FIX_LOG}"; then
  test_pass "confirmed pre-fix behavior: fixture forensic sentence tripped the scan when DR-REGISTRY.md was included"
else
  test_fail "negative control did not fire — the fixture cannot demonstrate the pre-fix failure mode"
  cat "${PRE_FIX_LOG}" >&2
fi

runner_summary
