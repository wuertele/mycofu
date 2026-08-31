#!/usr/bin/env bash
# test_configure_replication_global_orphans_unbound.sh — #615 / #255
# and #624 regression.
#
# Two guard-completeness bugs in the same `if [[ -z "$ALL_VMIDS" ]]`
# block of `framework/scripts/configure-replication.sh`:
#
# #615 / #255 (GLOBAL_ORPHANS unbound in WARNING branch, fixed in MR !475):
# `GLOBAL_ORPHANS=0` was initialized only inside the `else` branch. If the
# WARNING branch fired, `${GLOBAL_ORPHANS}` at the summary echo was
# unbound and under `set -euo pipefail` killed the script — exactly in
# the failure mode the guard was written to survive. Fix: initialize
# `GLOBAL_ORPHANS=0` BEFORE the guard.
#
# #624 (ALL_VMIDS='null' bypasses guard, cluster-wide zvol destruction):
# The jq expression `.[].vmid` emitted the literal string `null` when
# cluster API entries had `vmid: null` (a VM being destroyed mid-scan).
# `[[ -z "$ALL_VMIDS" ]]` accepted `null` as non-empty, so the destruction
# branch ran. The subsequent `grep -qw "$ZVOL_VMID"` membership tests
# never matched any integer ZVOL_VMID against the literal string `null`,
# classifying every zvol on every node as globally orphaned and destroying
# them cluster-wide. Blast radius: catastrophic — exactly the outcome the
# WARNING branch was written to prevent.
#
# Fix (#624), belt-and-suspenders across three layers:
#   Layer 0 (partial-inventory poison): if VM_DATA contains ANY entry
#     with a non-integer vmid (null, missing, string, float), set
#     ALL_VMIDS to empty so the WARNING branch fires. Without this,
#     mixed inventories like `[{"vmid":100},{"vmid":null},{"vmid":200}]`
#     would proceed with a partial view (100+200) and misclassify the
#     null-vmid VM's zvol as orphan. Codex + fork-sub-claude P1 finding
#     during the #624 adversarial review confirmed this leak in the
#     naive Layers 1+2-only design. Fails closed on jq errors.
#   Layer 1 (source): `jq -r '.[].vmid | numbers'` drops any non-numeric
#     vmid value at the jq level. Redundant after Layer 0 but stays as
#     defense in depth. Note: jq's `numbers` accepts floats too — Layer 2
#     is what enforces DECIMAL INTEGER shape on the shell string.
#   Layer 2 (guard, defense in depth): a `grep -E '^[0-9]+$' || true`
#     integer-shape re-filter before the `[[ -z "$ALL_VMIDS" ]]` guard.
#     Routes any leaked non-integer noise into the WARNING branch rather
#     than the destruction branch. `|| true` covers the entirely-empty
#     result under `set -euo pipefail` (grep with no matches exits 1).
#
# This test:
#   - Structural (#615): `GLOBAL_ORPHANS=0` is initialized at least once
#     BEFORE the `if [[ -z "$ALL_VMIDS" ]]` line (regression floor).
#   - Reproducer (#615): a self-contained snippet mirroring the exact
#     `set -euo pipefail` + guard + summary shape. Under the pre-fix
#     ordering it dies with `unbound variable`; under the post-fix
#     ordering it prints the summary cleanly.
#   - Structural (#624 Layer 1): the jq expression producing ALL_VMIDS
#     filters to numeric vmid values (`| numbers`, or a grep-based
#     integer post-filter on the same line — any shape that keeps
#     non-integer content out of the shell string).
#   - Structural (#624 Layer 2): a post-jq integer-shape filter is
#     applied before the `[[ -z "$ALL_VMIDS" ]]` guard, so future
#     Layer 1 regressions still route pathological content into the
#     WARNING branch rather than the destruction branch.
#   - Structural (#624 Layer 0): a `jq -e 'all(...vmid... == floor)'`
#     poison check runs against VM_DATA before ALL_VMIDS is populated.
#   - Reproducer (#624 negative control, all-null): pre-fix ordering with
#     `[{"vmid":null,...}]` yields ALL_VMIDS="null", the guard accepts
#     it, and the loop misclassifies every integer ZVOL_VMID as orphan.
#   - Reproducer (#624 positive control, all-null): post-fix ordering
#     with the same input yields ALL_VMIDS="", the WARNING branch fires,
#     and no zvols are classified as orphan.
#   - Reproducer (#624 mixed negative control): with the naive Layers
#     1+2-only fix, `[{"vmid":100},{"vmid":null},{"vmid":200}]` yields
#     ALL_VMIDS="100\n200", and the null-vmid VM's zvol (simulated as
#     ZVOL_VMID=150) is misclassified as orphan. This is codex's P1
#     failure mode.
#   - Reproducer (#624 mixed positive control): with Layer 0 in place,
#     the same input poisons ALL_VMIDS, the WARNING branch fires, and
#     no zvols are classified as orphan even though two valid integer
#     VMIDs are present.
# shellcheck disable=SC2016

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIGURE="${REPO_ROOT}/framework/scripts/configure-replication.sh"

# --- Structural guard ---------------------------------------------------

test_start "615.a" "GLOBAL_ORPHANS=0 is initialized BEFORE 'if [[ -z \"\$ALL_VMIDS\" ]]' (#615 / #255)"
# Find line numbers of the first GLOBAL_ORPHANS=0 assignment and the
# ALL_VMIDS emptiness guard. The initialization must come first.
#
# Notes on the regex shapes:
#   - The GLOBAL_ORPHANS=0 pattern does NOT anchor to column 0 (^): a
#     future refactor that wraps the block in a function would indent
#     the assignment. Word-boundary shape is enough — the assignment
#     value `0` is load-bearing (any counter renamed to a non-zero
#     literal isn't the initialization we care about).
#   - The ALL_VMIDS guard pattern tolerates single-quote/no-quote shape
#     variants — `[[ -z "$ALL_VMIDS" ]]` vs `[[ -z $ALL_VMIDS ]]` — so
#     harmless quoting cleanups don't silently break the ordering test.
#
# `|| true` on each pipeline: under `set -euo pipefail` a `grep` with no
# matches returns non-zero; the pipefail carries that into the command
# substitution and would kill the whole test at this line, leaving the
# subsequent `-z` reports as dead code. Force empty on no-match so those
# reports fire.
INIT_LINE=$(grep -nE '^[[:space:]]*GLOBAL_ORPHANS=0([[:space:]]|$)' "$CONFIGURE" | head -1 | cut -d: -f1 || true)
GUARD_LINE=$(grep -nE 'if[[:space:]]+\[\[[[:space:]]+-z[[:space:]]+"?\$ALL_VMIDS"?[[:space:]]+\]\]' "$CONFIGURE" | head -1 | cut -d: -f1 || true)

if [[ -z "$INIT_LINE" ]]; then
  test_fail "no 'GLOBAL_ORPHANS=0' assignment found in the script"
elif [[ -z "$GUARD_LINE" ]]; then
  test_fail "no 'if [[ -z \"\$ALL_VMIDS\" ]]' guard found in the script"
elif (( INIT_LINE < GUARD_LINE )); then
  test_pass "GLOBAL_ORPHANS=0 at line ${INIT_LINE} precedes ALL_VMIDS guard at line ${GUARD_LINE}"
else
  test_fail "GLOBAL_ORPHANS=0 at line ${INIT_LINE} does NOT precede ALL_VMIDS guard at line ${GUARD_LINE} — WARNING branch will leave the counter unbound"
fi

# --- Reproducer: negative control ---------------------------------------
# Prove the reproducer actually catches the pre-fix shape. Under
# `set -euo pipefail`, the pre-fix ordering (GLOBAL_ORPHANS=0 only in
# else) must die with "unbound variable" when the WARNING branch fires.
# If this test does NOT observe the crash, the reproducer is malformed
# and the positive test below is not proving anything.
#
# `env -u GLOBAL_ORPHANS -u ALL_VMIDS bash -c ...` scrubs those two names
# from the child environment. Without this, an inherited exported
# `GLOBAL_ORPHANS` from the parent shell (e.g. an operator who exported it
# for debugging) would defeat the pre-fix reproducer: bash would find the
# name in the exported environment and `set -u` would NOT crash. The
# scrub makes the reproducer environment-agnostic. Same scrub is applied
# to 615.c for symmetry — the positive control's outcome is not env-
# sensitive, but keeping the invocation shape identical between the two
# tests makes drift easier to catch.
#
# The synthetic reproducers here isolate the bash mechanic (init-in-else
# vs init-before-guard). A shim-driven end-to-end version isn't wired
# because the WARNING branch is currently unreachable via
# configure-replication.sh's normal control flow — an earlier check on
# empty MATCHING_VMS exits before the ALL_VMIDS guard is reached. That
# unreachability itself is a PRE-EXISTING guard-completeness concern
# filed separately as a follow-up to this MR. Structural test 615.a
# covers the actual script; 615.b/c cover the fix pattern.

test_start "615.b" "reproducer (negative control): pre-fix ordering dies with 'unbound variable' when WARNING branch fires"
tmp=$(mktemp)
prefix_rc=0
env -u GLOBAL_ORPHANS -u ALL_VMIDS bash -c '
set -euo pipefail
ALL_VMIDS=""
if [[ -z "$ALL_VMIDS" ]]; then
  echo "  WARNING: ..." >&2
else
  GLOBAL_ORPHANS=0
fi
echo "Summary: ${GLOBAL_ORPHANS}"
' >"$tmp" 2>&1 || prefix_rc=$?

if (( prefix_rc != 0 )) && grep -q 'unbound variable' "$tmp"; then
  test_pass "pre-fix reproducer dies with 'unbound variable' as expected (rc=${prefix_rc})"
else
  test_fail "pre-fix reproducer did not observe the crash (rc=${prefix_rc}); output:
$(cat "$tmp")"
fi
rm -f "$tmp"

# --- Reproducer: positive control ---------------------------------------
# The fix pattern (initialize BEFORE the guard) must survive the same
# WARNING-branch path cleanly and print the summary with GLOBAL_ORPHANS=0.

test_start "615.c" "reproducer (positive control): post-fix ordering survives WARNING branch and prints Summary"
tmp=$(mktemp)
postfix_rc=0
env -u GLOBAL_ORPHANS -u ALL_VMIDS bash -c '
set -euo pipefail
GLOBAL_ORPHANS=0
ALL_VMIDS=""
if [[ -z "$ALL_VMIDS" ]]; then
  echo "  WARNING: ..." >&2
else
  :
fi
echo "Summary: ${GLOBAL_ORPHANS} globally orphaned VMIDs cleaned"
' >"$tmp" 2>&1 || postfix_rc=$?

if (( postfix_rc == 0 )) \
   && grep -q '^Summary: 0 globally orphaned VMIDs cleaned' "$tmp" \
   && ! grep -q 'unbound variable' "$tmp"; then
  test_pass "post-fix reproducer exits 0 and prints the Summary line"
else
  test_fail "post-fix reproducer failed (rc=${postfix_rc}); output:
$(cat "$tmp")"
fi
rm -f "$tmp"

# --- Structural coverage of the surrounding gate ------------------------
# Make sure the fix didn't accidentally remove either the WARNING message
# or the ALL_VMIDS guard's else-branch flow. A future refactor that moves
# the initialization but drops the guard would silently regress the
# safety property the guard exists to enforce (don't sweep zvols cluster-
# wide when the cluster API is empty/unreachable).

test_start "615.d" "the ALL_VMIDS WARNING branch text is preserved"
if grep -q 'Could not enumerate VMs from cluster API — skipping global orphan cleanup' "$CONFIGURE"; then
  test_pass "WARNING branch text is intact"
else
  test_fail "WARNING branch text is missing — the guard that prevents cluster-wide zvol sweep on API blip may have been removed"
fi

test_start "615.e" "the summary line still references GLOBAL_ORPHANS"
# Match either brace form (`${GLOBAL_ORPHANS}`) or bare form
# (`$GLOBAL_ORPHANS`). Both are semantically equivalent in bash and a
# harmless style refactor could switch between them. What matters is
# that the summary line's expansion of the counter is still there, so
# a future rename catches this guard.
if grep -qE '\$\{?GLOBAL_ORPHANS\}?' "$CONFIGURE"; then
  test_pass "summary line still references GLOBAL_ORPHANS"
else
  test_fail "summary line no longer references GLOBAL_ORPHANS — either the summary was reshaped, or the counter was renamed; adjust this test and reverify the guard"
fi

# =========================================================================
# #624 regression — ALL_VMIDS='null' bypasses guard, cluster-wide zvol
# destruction.
# =========================================================================

# Find the ALL_VMIDS assignment line and the guard line. Used by 624.a
# and 624.b. Failing to find either aborts those tests with a clear
# fail rather than continuing with stale locals.
ALL_VMIDS_LINE=$(grep -nE '^[[:space:]]*ALL_VMIDS=\$\(echo[[:space:]]+"?\$VM_DATA"?' "$CONFIGURE" | head -1 | cut -d: -f1 || true)
GUARD_LINE_2=$(grep -nE 'if[[:space:]]+\[\[[[:space:]]+-z[[:space:]]+"?\$ALL_VMIDS"?[[:space:]]+\]\]' "$CONFIGURE" | head -1 | cut -d: -f1 || true)

# --- Structural guard: Layer 1 (jq numbers filter or same-line int filter) --
# The ALL_VMIDS-producing line must drop non-integer vmid values at the
# source. Canonical forms:
#   .[].vmid | numbers            (jq builtin post-vmid)
#   .[] | .vmid | numbers         (jq builtin equivalent)
#   ... | grep -E '^[0-9]+$'      (same-line integer post-filter)

test_start "624.a" "ALL_VMIDS assignment filters vmid to integers only (#624 Layer 1)"
if [[ -z "$ALL_VMIDS_LINE" ]]; then
  test_fail "no 'ALL_VMIDS=\$(echo \"\$VM_DATA\" ...)' assignment found in the script"
else
  ALL_VMIDS_TEXT=$(sed -n "${ALL_VMIDS_LINE}p" "$CONFIGURE")
  # Accept `| numbers` (jq builtin) OR a same-line `grep -E`. Any string
  # containing the token "numbers" as a jq filter OR the integer-shape
  # grep pattern is sufficient. Both filter non-integer vmid noise before
  # it can reach ALL_VMIDS.
  if grep -q 'numbers' <<< "$ALL_VMIDS_TEXT" \
     || grep -q 'grep -E' <<< "$ALL_VMIDS_TEXT"; then
    test_pass "ALL_VMIDS assignment (line ${ALL_VMIDS_LINE}) has an integer-shape filter"
  else
    test_fail "ALL_VMIDS assignment (line ${ALL_VMIDS_LINE}) does NOT filter to integers — non-integer vmid values (e.g. transitional 'null') will reach the shell and bypass the WARNING guard. Line: ${ALL_VMIDS_TEXT}"
  fi
fi

# --- Structural guard: Layer 2 (defense-in-depth grep filter) ----------
# Immediately after the ALL_VMIDS assignment, a re-filter step must
# reduce ALL_VMIDS to integer-only lines with `|| true` to survive the
# empty case under `set -e`. This is the belt-and-suspenders layer: if
# a future refactor loosens the jq expression in Layer 1, this filter
# still routes pathological content into the WARNING branch.

test_start "624.b" "ALL_VMIDS has a post-jq integer-shape filter with '|| true' (#624 Layer 2)"
if [[ -z "$ALL_VMIDS_LINE" ]]; then
  test_fail "no ALL_VMIDS assignment found (see 624.a) — cannot check for Layer 2"
elif [[ -z "$GUARD_LINE_2" ]]; then
  test_fail "no ALL_VMIDS guard found — cannot check Layer 2 ordering"
else
  # Extract the window from ALL_VMIDS assignment through the guard. Look
  # for a line that reassigns ALL_VMIDS from itself through an integer-
  # shape grep filter with `|| true`. Structural, not exact-textual, so a
  # future refactor that keeps the semantic (self-reassign + integer
  # filter + `|| true`) can still pass.
  WINDOW=$(sed -n "${ALL_VMIDS_LINE},${GUARD_LINE_2}p" "$CONFIGURE")
  if grep -qE 'ALL_VMIDS=\$\(echo[[:space:]]+"?\$ALL_VMIDS"?.*grep[[:space:]]+-E[[:space:]]+.\^\[0-9\]\+\$.*\|\|[[:space:]]+true' <<< "$WINDOW"; then
    test_pass "Layer 2 integer re-filter with '|| true' is present between the ALL_VMIDS assignment and the guard"
  else
    test_fail "Layer 2 integer re-filter missing between line ${ALL_VMIDS_LINE} and guard at line ${GUARD_LINE_2}. Expected an 'ALL_VMIDS=\$(echo \"\$ALL_VMIDS\" | grep -E \"^[0-9]+\$\" || true)' step (defense-in-depth for a future Layer 1 regression). Window:
${WINDOW}"
  fi
fi

# --- Structural guard: Layer 0 (partial-inventory poison via jq -e) -----
# The naive fix (drop non-integer vmids at the source) closes the
# all-invalid case but leaks the MIXED case: with valid+null vmids,
# jq's `numbers` yields a partial ALL_VMIDS which is treated as
# authoritative. The Layer 0 poison check runs BEFORE ALL_VMIDS is
# populated and detects "any non-integer vmid in the payload → whole
# inventory is untrusted → set ALL_VMIDS to empty → WARNING branch
# fires". Structural check: within a 40-line window before ALL_VMIDS
# assignment, look for a `jq -e` invocation with `all(` and both
# integer-strictness conditions (`type == "number"` AND `. == floor`).

test_start "624.a2" "ALL_VMIDS has a Layer 0 partial-inventory poison via jq -e 'all(...)' (#624 Layer 0)"
if [[ -z "$ALL_VMIDS_LINE" ]]; then
  test_fail "no ALL_VMIDS assignment found (see 624.a) — cannot check for Layer 0"
else
  START=$(( ALL_VMIDS_LINE > 40 ? ALL_VMIDS_LINE - 40 : 1 ))
  WINDOW=$(sed -n "${START},${ALL_VMIDS_LINE}p" "$CONFIGURE")
  if grep -qE 'jq[[:space:]]+-e' <<< "$WINDOW" \
     && grep -qE 'all\(' <<< "$WINDOW" \
     && grep -qE 'type[[:space:]]*==[[:space:]]*"number"' <<< "$WINDOW" \
     && grep -qE '==[[:space:]]*floor' <<< "$WINDOW"; then
    test_pass "Layer 0 poison check (jq -e all(...) with integer-strict predicate) is present before ALL_VMIDS assignment"
  else
    test_fail "Layer 0 poison check missing before line ${ALL_VMIDS_LINE}. Expected a 'jq -e' invocation with an 'all(...)' predicate testing both 'type == \"number\"' and '. == floor'. Window (lines ${START}-${ALL_VMIDS_LINE}):
${WINDOW}"
  fi
fi

# --- Reproducer (#624): negative control -------------------------------
# Prove the reproducer actually catches the pre-fix shape. Under the
# unfiltered `jq -r '.[].vmid'`, a `vmid: null` entry emits the literal
# string `null`, the guard accepts it as non-empty, and the loop's
# `grep -qw "$ZVOL_VMID"` never matches any integer ZVOL_VMID against
# `null` — so every ZVOL_VMID is classified as globally orphaned.

test_start "624.c" "reproducer (negative control): pre-fix unfiltered jq lets vmid:null misclassify all ZVOL_VMIDs as orphans"
tmp=$(mktemp)
prefix_rc=0
env -u GLOBAL_ORPHANS -u ALL_VMIDS bash -c '
set -euo pipefail
# Simulate pvesh returning one entry with vmid:null (a VM being destroyed
# mid-scan).
VM_DATA='"'"'[{"vmid":null,"name":"cicd","node":"pve01"}]'"'"'
# Pre-fix expression.
ALL_VMIDS=$(echo "$VM_DATA" | jq -r ".[].vmid" | sort -u)
if [[ -z "$ALL_VMIDS" ]]; then
  echo "WARNING-branch-fired"
  echo "ORPHANS=0"
else
  # Simulate three real ZVOL_VMIDs on target nodes.
  ORPHANS=0
  for ZVOL_VMID in 100 200 300; do
    if echo "$ALL_VMIDS" | grep -qw "$ZVOL_VMID"; then
      continue
    fi
    ORPHANS=$((ORPHANS + 1))
  done
  echo "destruction-branch-fired"
  echo "ORPHANS=${ORPHANS}"
fi
' >"$tmp" 2>&1 || prefix_rc=$?

if (( prefix_rc == 0 )) \
   && grep -q '^destruction-branch-fired$' "$tmp" \
   && grep -q '^ORPHANS=3$' "$tmp"; then
  test_pass "pre-fix reproducer misclassifies all 3 ZVOL_VMIDs as orphans (destruction branch fired)"
else
  test_fail "pre-fix reproducer did not observe the misclassification (rc=${prefix_rc}); expected 'destruction-branch-fired' + 'ORPHANS=3'. Output:
$(cat "$tmp")"
fi
rm -f "$tmp"

# --- Reproducer (#624): positive control -------------------------------
# The post-fix expression (Layer 1 = `jq -r '.[].vmid | numbers'`) drops
# `null` at the source, so ALL_VMIDS is empty and the WARNING branch
# fires. Zero orphans.

test_start "624.d" "reproducer (positive control): post-fix jq 'numbers' filter drops vmid:null, WARNING branch fires, no orphans"
tmp=$(mktemp)
postfix_rc=0
env -u GLOBAL_ORPHANS -u ALL_VMIDS bash -c '
set -euo pipefail
VM_DATA='"'"'[{"vmid":null,"name":"cicd","node":"pve01"}]'"'"'
# Post-fix expression (Layer 1). `numbers` filters to numeric vmids only.
ALL_VMIDS=$(echo "$VM_DATA" | jq -r ".[].vmid | numbers" | sort -u)
# Post-fix Layer 2 defense-in-depth filter (would be a no-op here since
# Layer 1 already scrubbed the null, but must not crash).
ALL_VMIDS=$(echo "$ALL_VMIDS" | grep -E "^[0-9]+$" || true)
if [[ -z "$ALL_VMIDS" ]]; then
  echo "WARNING-branch-fired"
  echo "ORPHANS=0"
else
  ORPHANS=0
  for ZVOL_VMID in 100 200 300; do
    if echo "$ALL_VMIDS" | grep -qw "$ZVOL_VMID"; then
      continue
    fi
    ORPHANS=$((ORPHANS + 1))
  done
  echo "destruction-branch-fired"
  echo "ORPHANS=${ORPHANS}"
fi
' >"$tmp" 2>&1 || postfix_rc=$?

if (( postfix_rc == 0 )) \
   && grep -q '^WARNING-branch-fired$' "$tmp" \
   && grep -q '^ORPHANS=0$' "$tmp" \
   && ! grep -q '^destruction-branch-fired$' "$tmp"; then
  test_pass "post-fix reproducer routes vmid:null into WARNING branch, no orphans classified"
else
  test_fail "post-fix reproducer failed (rc=${postfix_rc}); expected 'WARNING-branch-fired' + 'ORPHANS=0'. Output:
$(cat "$tmp")"
fi
rm -f "$tmp"

# --- Reproducer (#624): normal-operation baseline ----------------------
# Verify the post-fix expression preserves normal-operation semantics:
# a valid list of integer vmids drives the loop normally, and only
# ZVOL_VMIDs not in the list are classified as orphans.

test_start "624.e" "reproducer (baseline): post-fix expression preserves normal-operation semantics with valid integer vmids"
tmp=$(mktemp)
baseline_rc=0
env -u GLOBAL_ORPHANS -u ALL_VMIDS bash -c '
set -euo pipefail
# Two real VMs currently exist in the cluster.
VM_DATA='"'"'[{"vmid":100,"name":"gitlab","node":"pve01"},{"vmid":200,"name":"dns1","node":"pve02"}]'"'"'
ALL_VMIDS=$(echo "$VM_DATA" | jq -r ".[].vmid | numbers" | sort -u)
ALL_VMIDS=$(echo "$ALL_VMIDS" | grep -E "^[0-9]+$" || true)
if [[ -z "$ALL_VMIDS" ]]; then
  echo "WARNING-branch-fired"
  echo "ORPHANS=0"
else
  # Simulate ZVOL_VMIDs on target nodes: 100 (real), 200 (real), 300 (stale).
  ORPHANS=0
  for ZVOL_VMID in 100 200 300; do
    if echo "$ALL_VMIDS" | grep -qw "$ZVOL_VMID"; then
      continue
    fi
    ORPHANS=$((ORPHANS + 1))
  done
  echo "destruction-branch-fired"
  echo "ORPHANS=${ORPHANS}"
fi
' >"$tmp" 2>&1 || baseline_rc=$?

if (( baseline_rc == 0 )) \
   && grep -q '^destruction-branch-fired$' "$tmp" \
   && grep -q '^ORPHANS=1$' "$tmp"; then
  test_pass "post-fix expression preserves normal-operation: 100/200 skipped, 300 classified as orphan"
else
  test_fail "post-fix baseline failed (rc=${baseline_rc}); expected 'destruction-branch-fired' + 'ORPHANS=1' (only 300 classified). Output:
$(cat "$tmp")"
fi
rm -f "$tmp"

# --- Reproducer (#624): empty-array baseline ---------------------------
# Verify the post-fix expression handles the empty-array case cleanly
# (no VMs matching pattern, or cluster with no VMs at all). This is the
# case (b) requested by the fix directive.

# --- Reproducer (#624): mixed-inventory negative control ---------------
# Codex + fork sub-claude P1 finding — the naive fix without Layer 0
# silently drops vmid:null entries and proceeds with a PARTIAL
# inventory. The VM whose vmid was null gets its zvol classified as
# orphan and destroyed. Blast radius: smaller than "cluster-wide" but
# still real destruction of real-VM state.

test_start "624.g" "reproducer (mixed negative control): pre-Layer-0 (Layers 1+2 only) misclassifies null-vmid VM's zvol as orphan"
tmp=$(mktemp)
mixed_neg_rc=0
env -u GLOBAL_ORPHANS -u ALL_VMIDS bash -c '
set -euo pipefail
# Mixed VM_DATA: two valid integer vmids, one null. Simulates a real
# cluster inventory during a mid-scan destroy transient.
VM_DATA='"'"'[{"vmid":100,"name":"gitlab","node":"pve01"},{"vmid":null,"name":"dns1","node":"pve02"},{"vmid":200,"name":"pbs","node":"pve03"}]'"'"'
# Pre-Layer-0 expression: only Layer 1 (numbers) + Layer 2 (grep).
# Drops the null, leaves ALL_VMIDS="100\n200".
ALL_VMIDS=$(echo "$VM_DATA" | jq -r ".[].vmid | numbers" | sort -u)
ALL_VMIDS=$(echo "$ALL_VMIDS" | grep -E "^[0-9]+$" || true)
if [[ -z "$ALL_VMIDS" ]]; then
  echo "WARNING-branch-fired"
  echo "ORPHANS=0"
else
  # Real ZVOL_VMIDs on target nodes: 100 (valid), 150 (belongs to the
  # VM whose vmid was null), 200 (valid).
  ORPHANS=0
  ORPHAN_LIST=""
  for ZVOL_VMID in 100 150 200; do
    if echo "$ALL_VMIDS" | grep -qw "$ZVOL_VMID"; then
      continue
    fi
    ORPHANS=$((ORPHANS + 1))
    ORPHAN_LIST="${ORPHAN_LIST} ${ZVOL_VMID}"
  done
  echo "destruction-branch-fired"
  echo "ORPHANS=${ORPHANS}"
  echo "ORPHAN_LIST=${ORPHAN_LIST# }"
fi
' >"$tmp" 2>&1 || mixed_neg_rc=$?

if (( mixed_neg_rc == 0 )) \
   && grep -q '^destruction-branch-fired$' "$tmp" \
   && grep -q '^ORPHANS=1$' "$tmp" \
   && grep -q '^ORPHAN_LIST=150$' "$tmp"; then
  test_pass "pre-Layer-0 reproducer misclassifies ZVOL 150 (the null-vmid VM's zvol) as orphan — codex P1 failure mode confirmed"
else
  test_fail "pre-Layer-0 reproducer did not observe the misclassification (rc=${mixed_neg_rc}); expected 'destruction-branch-fired' + 'ORPHANS=1' + 'ORPHAN_LIST=150'. Output:
$(cat "$tmp")"
fi
rm -f "$tmp"

# --- Reproducer (#624): mixed-inventory positive control ---------------
# With Layer 0's partial-inventory poison in place, the SAME mixed
# input is detected as pathological before ALL_VMIDS is populated, and
# the WARNING branch fires. No zvols are classified as orphan even
# though two valid integer VMIDs are present.

test_start "624.h" "reproducer (mixed positive control): Layer 0 poison detects vmid:null in mixed inventory, fires WARNING branch, no orphans"
tmp=$(mktemp)
mixed_pos_rc=0
env -u GLOBAL_ORPHANS -u ALL_VMIDS bash -c '
set -euo pipefail
VM_DATA='"'"'[{"vmid":100,"name":"gitlab","node":"pve01"},{"vmid":null,"name":"dns1","node":"pve02"},{"vmid":200,"name":"pbs","node":"pve03"}]'"'"'
# Post-fix expression: Layer 0 poison first.
if ! echo "$VM_DATA" \
     | jq -e "all(.[]?.vmid; (type == \"number\") and (. == floor))" \
       >/dev/null 2>&1; then
  ALL_VMIDS=""
else
  ALL_VMIDS=$(echo "$VM_DATA" | jq -r ".[].vmid | numbers" | sort -u)
fi
ALL_VMIDS=$(echo "$ALL_VMIDS" | grep -E "^[0-9]+$" || true)
if [[ -z "$ALL_VMIDS" ]]; then
  echo "WARNING-branch-fired"
  echo "ORPHANS=0"
else
  ORPHANS=0
  for ZVOL_VMID in 100 150 200; do
    if echo "$ALL_VMIDS" | grep -qw "$ZVOL_VMID"; then
      continue
    fi
    ORPHANS=$((ORPHANS + 1))
  done
  echo "destruction-branch-fired"
  echo "ORPHANS=${ORPHANS}"
fi
' >"$tmp" 2>&1 || mixed_pos_rc=$?

if (( mixed_pos_rc == 0 )) \
   && grep -q '^WARNING-branch-fired$' "$tmp" \
   && grep -q '^ORPHANS=0$' "$tmp" \
   && ! grep -q '^destruction-branch-fired$' "$tmp"; then
  test_pass "post-fix (Layer 0+1+2) routes mixed inventory into WARNING branch — no zvols classified as orphan even with valid integer VMIDs present"
else
  test_fail "post-fix mixed positive control failed (rc=${mixed_pos_rc}); expected 'WARNING-branch-fired' + 'ORPHANS=0'. Output:
$(cat "$tmp")"
fi
rm -f "$tmp"

test_start "624.f" "reproducer (baseline): post-fix expression on empty array routes into WARNING branch cleanly"
tmp=$(mktemp)
empty_rc=0
env -u GLOBAL_ORPHANS -u ALL_VMIDS bash -c '
set -euo pipefail
VM_DATA='"'"'[]'"'"'
ALL_VMIDS=$(echo "$VM_DATA" | jq -r ".[].vmid | numbers" | sort -u)
ALL_VMIDS=$(echo "$ALL_VMIDS" | grep -E "^[0-9]+$" || true)
if [[ -z "$ALL_VMIDS" ]]; then
  echo "WARNING-branch-fired"
  echo "ORPHANS=0"
else
  echo "destruction-branch-fired"
fi
' >"$tmp" 2>&1 || empty_rc=$?

if (( empty_rc == 0 )) \
   && grep -q '^WARNING-branch-fired$' "$tmp" \
   && grep -q '^ORPHANS=0$' "$tmp"; then
  test_pass "post-fix expression on empty array fires WARNING branch cleanly"
else
  test_fail "post-fix empty-array baseline failed (rc=${empty_rc}); expected 'WARNING-branch-fired' + 'ORPHANS=0'. Output:
$(cat "$tmp")"
fi
rm -f "$tmp"

runner_summary
