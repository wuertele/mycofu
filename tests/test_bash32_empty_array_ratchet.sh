#!/usr/bin/env bash
# test_bash32_empty_array_ratchet.sh — CI ratchet for the bash 3.2 +
# `set -u` + empty-array expansion bug class (#410).
#
# ## The bug this guards against
#
# On bash 3.2 (the macOS operator workstation's `/bin/bash`, 3.2.57),
# expanding an EMPTY array with `"${ARR[@]}"` or `"${ARR[*]}"` under
# `set -u` aborts the script with `ARR[@]: unbound variable`. bash 4.4+
# (the Linux cicd runner) treats the same expansion as harmless, so the
# bug is INVISIBLE to the normal CI runner — it only fires on the
# workstation, exactly where DR-shaped scripts (`rebuild-cluster.sh`
# et al.) run. Most recently fixed in `build-image.sh` /
# `rebuild-cluster.sh` (MR mycofu-fix/build-image-bash32-empty-array,
# where `NIX_BUILD_FLAGS` — a flag array appended only conditionally
# inside a loop — was the culprit).
#
# ## How this ratchet works (golden-master baseline)
#
# `tests/lib/bash32_empty_array_scan.py` emits every UNGUARDED bare
# `"${ARR[@]}"`/`"${ARR[*]}"` expansion of an empty-initialized array
# (`ARR=()`, `local ARR=()`, `declare -a ARR=()`, ...) in
# `framework/scripts` files that run under `set -u`, as a stable,
# line-number-free `<relpath>\t<ARRAY>\t<sym>` key. "Unguarded" excludes
# the safe idioms `${ARR[@]+"${ARR[@]}"}` / `"${ARR[@]:-}"` and
# `${#ARR[@]}` count guards.
#
# The current set of such keys is committed to
# `tests/fixtures/bash32_empty_array_baseline.txt`. This test FAILS when
# the live scan and the baseline disagree:
#   - A NET-NEW key means a new unguarded expansion was introduced —
#     INCLUDING an idiom->bare regression of a currently-safe array such
#     as NIX_BUILD_FLAGS (reverting its idiom to a bare expansion adds a
#     `build-image.sh NIX_BUILD_FLAGS @` key that is not in the baseline).
#     Fix it with the canonical idiom; do NOT add it to the baseline.
#   - A MISSING key means a baselined expansion was removed or fixed —
#     regenerate the baseline (command below) so it stays honest.
#
# ## Why a baseline instead of a pure pass/fail scanner
#
# A precise "is this array reachable-empty?" static analysis is not
# decidable from regexes: `for ip in "${NODE_IPS[@]}"` (NODE_IPS filled
# unconditionally from config) is safe, while an identically-shaped
# loop-appended flag array is not. A pure scanner that tried to tell them
# apart either floods false positives or — as an earlier draft of this
# ratchet did — excludes loop-appended arrays and thereby MISSES the very
# NIX_BUILD_FLAGS regression #410 exists to trap. The baseline sidesteps
# the undecidable question: it pins the CURRENT set (all triaged as
# existing) and rejects anything NEW. It is a single machine-consumed
# snapshot (cf. tests/test_vm_scope_golden_master.sh), not a hand-curated
# second source of truth.
#
# NOTE: several baselined keys (e.g. check-boot-integrity.sh /
# check-control-plane-drift.sh host arrays) are genuine PRE-EXISTING
# reachable-empty candidates surfaced during #410 review; they are
# recorded here rather than fixed in this MR (tracked separately).
#
# ## Regenerating the baseline (after an INTENTIONAL change)
#
#   { grep '^#' tests/fixtures/bash32_empty_array_baseline.txt
#     python3 tests/lib/bash32_empty_array_scan.py framework/scripts
#   } > /tmp/b && mv /tmp/b tests/fixtures/bash32_empty_array_baseline.txt

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

SCANNER="${REPO_ROOT}/tests/lib/bash32_empty_array_scan.py"
BASELINE="${REPO_ROOT}/tests/fixtures/bash32_empty_array_baseline.txt"

WORK="$(mktemp -d -t bash32-arr.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Compare a live scan of $1 against baseline file $2 (tagged $3). Writes
# added/removed key lists under $WORK and echoes "added=<n> removed=<n>".
compare_scan() {
  local scripts_dir="$1" baseline_file="$2" tag="$3"
  python3 "$SCANNER" "$scripts_dir" | sort -u > "${WORK}/scan.${tag}"
  { grep -v '^#' "$baseline_file" 2>/dev/null || true; } | sed '/^[[:space:]]*$/d' | sort -u > "${WORK}/base.${tag}"
  comm -13 "${WORK}/base.${tag}" "${WORK}/scan.${tag}" > "${WORK}/added.${tag}"    # in scan, not baseline
  comm -23 "${WORK}/base.${tag}" "${WORK}/scan.${tag}" > "${WORK}/removed.${tag}"  # in baseline, not scan
  local added removed
  added=$(grep -c . "${WORK}/added.${tag}" 2>/dev/null || true); added=${added:-0}
  removed=$(grep -c . "${WORK}/removed.${tag}" 2>/dev/null || true); removed=${removed:-0}
  echo "added=${added} removed=${removed}"
}

# --- Test 1: framework/scripts scan matches the committed baseline --------
test_start "1" "framework/scripts unguarded empty-array expansions match baseline"
RES="$(compare_scan "${REPO_ROOT}/framework/scripts" "$BASELINE" real)"
if [[ "$RES" == "added=0 removed=0" ]]; then
  test_pass "no new or removed unguarded empty-array expansions"
else
  {
    if [[ -s "${WORK}/added.real" ]]; then
      echo "FAIL: NEW unguarded empty-array expansion(s) — will crash on bash 3.2 + set -u:"
      sed 's/^/  + /' "${WORK}/added.real"
      echo ""
      echo "Fix each with the canonical idiom  \${ARR[@]+\"\${ARR[@]}\"}  (or a"
      echo "count guard  [[ \${#ARR[@]} -gt 0 ]]). Do NOT add it to the baseline."
    fi
    if [[ -s "${WORK}/removed.real" ]]; then
      echo "FAIL: baselined expansion(s) no longer present (removed/fixed):"
      sed 's/^/  - /' "${WORK}/removed.real"
      echo ""
      echo "Regenerate the baseline (see header of this test / the fixture file)."
    fi
    echo "See tests/test_bash32_empty_array_ratchet.sh and #410."
  } >&2
  test_fail "baseline drift ($RES)"
fi

# --- Self-tests -----------------------------------------------------------
# Build fixtures under $WORK and scan them against an EMPTY baseline so any
# detected key shows up as "added". These pin the scanner's contract.
: > "${WORK}/empty_base"
mkfix() { # mkfix <tag> <body>  -> echoes the scripts dir to scan
  local dir="${WORK}/fix_$1/framework/scripts"
  rm -rf "${WORK}/fix_$1"; mkdir -p "$dir"
  printf '%s\n' "$2" > "${dir}/s.sh"
  echo "$dir"
}

# 2: a NEW conditional-append (if) offender is detected.
test_start "2" "detects an unguarded conditional-append offender"
D="$(mkfix cond '#!/usr/bin/env bash
set -euo pipefail
FLAGS=()
if [[ "${DBG:-0}" == "1" ]]; then FLAGS+=(--v); fi
run "${FLAGS[@]}"')"
compare_scan "$D" "${WORK}/empty_base" cond >/dev/null
grep -q 'FLAGS' "${WORK}/added.cond" && test_pass "conditional-append offender flagged" \
  || test_fail "conditional-append offender NOT flagged"

# 3: a LOOP-appended offender is detected (the regression class the earlier
#    draft MISSED — NIX_BUILD_FLAGS is appended inside a loop).
test_start "3" "detects a loop-appended offender (NIX_BUILD_FLAGS class)"
D="$(mkfix loop '#!/usr/bin/env bash
set -euo pipefail
BF=()
for m in a b; do
  if [[ "$m" == a ]]; then BF+=(--impure); fi
done
nix build "${BF[@]}"')"
compare_scan "$D" "${WORK}/empty_base" loop >/dev/null
grep -q 'BF' "${WORK}/added.loop" && test_pass "loop-appended offender flagged" \
  || test_fail "loop-appended offender NOT flagged — coverage regression"

# 4: a local/declare array offender is detected.
test_start "4" "detects a local/declare array offender"
D="$(mkfix local '#!/usr/bin/env bash
set -euo pipefail
f() {
  local -a items=()
  [[ -n "${X:-}" ]] && items+=("$X")
  printf "%s\n" "${items[@]}"
}')"
compare_scan "$D" "${WORK}/empty_base" local >/dev/null
grep -q 'items' "${WORK}/added.local" && test_pass "local array offender flagged" \
  || test_fail "local array offender NOT flagged"

# 5: the canonical + idiom is NOT flagged (no false positive).
test_start "5" "accepts the canonical + idiom (no false positive)"
D="$(mkfix idiom '#!/usr/bin/env bash
set -euo pipefail
FLAGS=()
[[ -n "${X:-}" ]] && FLAGS+=(--v)
run ${FLAGS[@]+"${FLAGS[@]}"}')"
compare_scan "$D" "${WORK}/empty_base" idiom >/dev/null
[[ -s "${WORK}/added.idiom" ]] && test_fail "+ idiom FALSE-flagged" \
  || test_pass "+ idiom correctly accepted"

# 6: a ${#ARR[@]} count guard suppresses the flag (no false positive).
test_start "6" "accepts a count-guarded expansion (no false positive)"
D="$(mkfix guard '#!/usr/bin/env bash
set -euo pipefail
A=()
[[ -n "${X:-}" ]] && A+=("$X")
if [[ ${#A[@]} -gt 0 ]]; then
  run "${A[@]}"
fi')"
compare_scan "$D" "${WORK}/empty_base" guard >/dev/null
[[ -s "${WORK}/added.guard" ]] && test_fail "count-guarded expansion FALSE-flagged" \
  || test_pass "count-guarded expansion correctly accepted"

# 7: a prose comment containing a loop word / assignment does not corrupt
#    detection (comment-stripping).
test_start "7" "comments do not corrupt detection"
D="$(mkfix comment '#!/usr/bin/env bash
set -euo pipefail
FLAGS=()
# for safety we do this; ARR=(a b c) would be wrong
[[ -n "${X:-}" ]] && FLAGS+=(--v)
run "${FLAGS[@]}"')"
compare_scan "$D" "${WORK}/empty_base" comment >/dev/null
grep -q 'FLAGS' "${WORK}/added.comment" && test_pass "comment noise ignored; offender still flagged" \
  || test_fail "comment noise suppressed a real offender"

runner_summary
