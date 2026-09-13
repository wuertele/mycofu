#!/usr/bin/env bash
# test_configure_replication_tempfile_leak.sh — #626 regression.
#
# `framework/scripts/configure-replication.sh` accumulates tempfile paths
# in `CLEANUP_FILES` and rm-s them in an EXIT trap. Two bug shapes hid
# in the pre-fix code:
#
# 1. Tempfile leakage between mktemp and CLEANUP_FILES append.
#    Several sites created a tempfile with `mktemp` and only appended
#    it to `CLEANUP_FILES` after ALL sibling mktemps were done:
#
#      STATUS_FILE=$(mktemp)
#      ALLOCATED_IDS_FILE=$(mktemp)
#      CREATED_IDS_FILE=$(mktemp)
#      CLEANUP_FILES="$STATUS_FILE $ALLOCATED_IDS_FILE $CREATED_IDS_FILE $CLEANUP_FILES"
#
#    If SIGINT fires or `set -e` kills the script between any two of
#    those lines, the EXIT trap sees only the already-registered
#    tempfiles and leaks the ones created but not yet appended. Under
#    normal operation these are ~40-byte files, but the pattern is a
#    landmine for a future site that mktemps larger files.
#
#    Fix: single-line mktemp+append shape, e.g.
#      STATUS_FILE=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $STATUS_FILE"
#    Bash still treats `;` as a command boundary and CAN deliver a
#    signal between the two statements — the same-line shape doesn't
#    eliminate every race window. What it does provide:
#      (a) eliminates the wider batched-append window where several
#          mktemps ran before ANY was registered (the actual bug shape);
#      (b) prevents a future maintainer from inserting real work
#          between the mktemp and the register step;
#      (c) makes the `set -e` case a non-issue (mktemp rarely fails,
#          and if it does no file was created — nothing to leak).
#    A residual SIGINT-between-`;` race remains and is not addressed
#    by this fix. Getting rid of it would require a `mktemp_register()`
#    helper that traps SIGINT itself; that is out of scope.
#
#    Additionally, the trap is now armed BEFORE the first mktemp so
#    the trap fires with a valid (possibly empty) $CLEANUP_FILES even
#    if the very first mktemp is followed by a fatal error before its
#    register step runs.
#
# 2. ShellCheck SC2086 on the EXIT trap:
#      trap 'rm -f $CLEANUP_FILES' EXIT
#    Word-split on the string is deliberate (rm needs individual paths),
#    but ShellCheck flags SC2086. Fix: an explicit
#    "shellcheck-disable-SC2086" directive above the trap so a
#    script-wide shellcheck-clean initiative does not misdiagnose this.
#    (Written with hyphens above rather than the actual directive shape
#    so shellcheck lint of this comment does not parse it as a broken
#    directive — see the wire-up in the script itself for the real form.)
#
# This test:
#   - Structural (leak): every `mktemp` call is followed on the SAME
#     LINE by a `CLEANUP_FILES=...` append, so bash cannot interleave a
#     signal between the two.
#   - Structural (SC2086): there is a `# shellcheck disable=SC2086`
#     comment on a line immediately preceding the `trap ... EXIT` line.
# shellcheck disable=SC2016

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIGURE="${REPO_ROOT}/framework/scripts/configure-replication.sh"

# --- Structural: every mktemp is followed by CLEANUP_FILES on same line

test_start "626.a" "every mktemp registers its tempfile in CLEANUP_FILES on the same physical line (#626)"
# Find every non-comment, non-heredoc line containing `=$(mktemp)` where
# the RHS is a top-level mktemp (not `mktemp -d` for a directory, and not
# inside a subshell that manages its own cleanup). Any such line must
# also contain a `CLEANUP_FILES=` append with the same variable name on
# the same line.
#
# Regex shape:
#   ^[[:space:]]*<VAR>=\$\(mktemp\)  — the mktemp assignment
#   .*CLEANUP_FILES=.*\$<VAR>          — followed by CLEANUP_FILES append
#
# Any line that matches the first pattern but NOT the second is a leak
# shape.
#
# `|| true` under `set -e`: grep with no matches exits 1; we want the
# subsequent -z reports to fire even when the file has no mktemp lines.
MKTEMP_LINES=$(grep -nE '^[[:space:]]*[A-Z_][A-Z0-9_]*=\$\(mktemp\)' "$CONFIGURE" || true)
if [[ -z "$MKTEMP_LINES" ]]; then
  test_warn "no mktemp assignments found in the script — structural test is a no-op"
else
  LEAK_HITS=""
  while IFS=: read -r lineno rest; do
    # Extract the assigned variable name.
    varname=$(echo "$rest" | sed -nE 's/^[[:space:]]*([A-Z_][A-Z0-9_]*)=\$\(mktemp\).*/\1/p')
    if [[ -z "$varname" ]]; then
      continue
    fi
    # Look at the SAME line for a CLEANUP_FILES= assignment that
    # references the variable. A downstream refactor that renamed the
    # variable name would show up here.
    if ! echo "$rest" | grep -qE "CLEANUP_FILES=.*\\\$${varname}"; then
      LEAK_HITS="${LEAK_HITS}
    line ${lineno}: ${varname}=\$(mktemp) has no same-line CLEANUP_FILES=...\$${varname} append"
    fi
  done <<< "$MKTEMP_LINES"
  if [[ -z "$LEAK_HITS" ]]; then
    test_pass "all mktemp assignments register their tempfile in CLEANUP_FILES on the same line"
  else
    test_fail "tempfile leak shape found:${LEAK_HITS}"
  fi
fi

# --- Structural: trap armed BEFORE first mktemp (fork-P2)

test_start "626.e" "CLEANUP_FILES EXIT trap is armed BEFORE the first mktemp assignment (#626 fork-P2)"
# Find the line of the trap, then confirm every mktemp assignment
# appears AFTER it. Fork sub-claude P2: if the trap is armed after the
# first mktemp, a signal or fatal error between mktemp and trap arm
# leaks the un-registered tempfile — exactly the defect #626 exists
# to fix.
TRAP_ARM_LINE=$(grep -nE "^[[:space:]]*trap[[:space:]]+'rm[[:space:]]+-f[[:space:]]+\\\$CLEANUP_FILES'[[:space:]]+EXIT" "$CONFIGURE" | head -1 | cut -d: -f1 || true)
FIRST_MKTEMP_LINE=$(grep -nE '^[[:space:]]*[A-Z_][A-Z0-9_]*=\$\(mktemp\)' "$CONFIGURE" | head -1 | cut -d: -f1 || true)
if [[ -z "$TRAP_ARM_LINE" ]]; then
  test_fail "no 'trap ... rm -f \$CLEANUP_FILES ... EXIT' line found"
elif [[ -z "$FIRST_MKTEMP_LINE" ]]; then
  test_fail "no 'VAR=\$(mktemp)' assignment found in the script"
elif (( TRAP_ARM_LINE < FIRST_MKTEMP_LINE )); then
  test_pass "trap at line ${TRAP_ARM_LINE} is armed BEFORE first mktemp at line ${FIRST_MKTEMP_LINE}"
else
  test_fail "trap at line ${TRAP_ARM_LINE} is armed AFTER first mktemp at line ${FIRST_MKTEMP_LINE} — a signal or fatal error between the mktemp and the trap arm leaks the un-registered tempfile"
fi

# --- Structural: SC2086 disable on the EXIT trap

test_start "626.b" "'# shellcheck disable=SC2086' precedes the CLEANUP_FILES trap line (#626)"
# Find the trap line and check that a `disable=SC2086` comment appears
# in the 5 lines immediately above (to allow for a rationale comment
# between the disable and the trap).
TRAP_LINE=$(grep -nE "^[[:space:]]*trap[[:space:]]+'rm[[:space:]]+-f[[:space:]]+\\\$CLEANUP_FILES'[[:space:]]+EXIT" "$CONFIGURE" | head -1 | cut -d: -f1 || true)
if [[ -z "$TRAP_LINE" ]]; then
  test_fail "no 'trap ... rm -f \$CLEANUP_FILES ... EXIT' line found — either the trap was moved or the CLEANUP_FILES variable was renamed"
else
  # Grab a small window above the trap and check for the disable directive.
  START=$(( TRAP_LINE > 5 ? TRAP_LINE - 5 : 1 ))
  END=$(( TRAP_LINE - 1 ))
  WINDOW=$(sed -n "${START},${END}p" "$CONFIGURE")
  if grep -qE '# shellcheck disable=SC2086' <<< "$WINDOW"; then
    test_pass "trap at line ${TRAP_LINE} is preceded by a shellcheck SC2086 disable comment"
  else
    test_fail "trap at line ${TRAP_LINE} has no preceding '# shellcheck disable=SC2086' comment — the deliberate word-split on \$CLEANUP_FILES will trip a script-wide shellcheck-clean initiative. Window (lines ${START}-${END}):
${WINDOW}"
  fi
fi

# --- Reproducer (leak): pre-fix ordering leaks a tempfile on signal ----
# Prove the reproducer catches the pre-fix shape. Under a synthetic
# equivalent of the pre-fix ordering, a signal fired between the mktemp
# calls and the batched CLEANUP_FILES append leaks one of the tempfiles.

test_start "626.c" "reproducer (negative control): pre-fix batched append leaks tempfile when signal fires between mktemp and append"
# Simulate the pre-fix shape: mktemp two files, then append both. If
# the second mktemp's file is created but the append is skipped (via an
# early `exit` before the append line), the EXIT trap only sees the
# CLEANUP_FILES it was assigned before, so the second tempfile leaks.
#
# We use `exit` (not a signal) to make the reproducer deterministic and
# fast — the trap-firing mechanism is identical: the trap fires with
# whatever CLEANUP_FILES holds at that moment. A real SIGINT has a
# different delivery model (it can interrupt between commands under
# `set -e` too) but the specific defect this MR fixes — the trap firing
# with an incomplete CLEANUP_FILES because the batched append hadn't
# yet run — is what the exit reproducer proves. A background-timing
# signal test would add flakiness without adding coverage.
tmp_out=$(mktemp)
tmp_stderr=$(mktemp)
child_rc=0
bash -c '
CLEANUP_FILES=""
trap "rm -f \$CLEANUP_FILES" EXIT
FIRST=$(mktemp)       # created, will be registered
CLEANUP_FILES="$CLEANUP_FILES $FIRST"
SECOND=$(mktemp)      # created, NOT yet registered
# Emit the paths so the parent can check whether cleanup ran
echo "$FIRST"
echo "$SECOND"
# Simulate a set -e / signal firing before the batched append
exit 42
CLEANUP_FILES="$CLEANUP_FILES $SECOND"  # never reached
' >"$tmp_out" 2>"$tmp_stderr" || child_rc=$?
FIRST_PATH=$(sed -n '1p' "$tmp_out")
SECOND_PATH=$(sed -n '2p' "$tmp_out")
# After the child exits, FIRST_PATH should be cleaned up by the trap,
# SECOND_PATH should still exist (leaked).
if [[ "$child_rc" -eq 42 ]] && [[ ! -e "$FIRST_PATH" ]] && [[ -e "$SECOND_PATH" ]]; then
  test_pass "pre-fix reproducer leaks SECOND ($SECOND_PATH exists, $FIRST_PATH cleaned, child rc=42)"
  rm -f "$SECOND_PATH"
else
  test_fail "pre-fix reproducer did not observe the leak; child_rc=$child_rc; FIRST exists: $([[ -e $FIRST_PATH ]] && echo yes || echo no); SECOND exists: $([[ -e $SECOND_PATH ]] && echo yes || echo no)"
  rm -f "$FIRST_PATH" "$SECOND_PATH"
fi
rm -f "$tmp_out" "$tmp_stderr"

# --- Reproducer (leak): post-fix single-line shape does not leak ------

test_start "626.d" "reproducer (positive control): post-fix single-line shape cleans both tempfiles on signal"
tmp_out=$(mktemp)
tmp_stderr=$(mktemp)
child_rc=0
bash -c '
CLEANUP_FILES=""
trap "rm -f \$CLEANUP_FILES" EXIT
FIRST=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $FIRST"
SECOND=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $SECOND"
echo "$FIRST"
echo "$SECOND"
exit 42
' >"$tmp_out" 2>"$tmp_stderr" || child_rc=$?
FIRST_PATH=$(sed -n '1p' "$tmp_out")
SECOND_PATH=$(sed -n '2p' "$tmp_out")
if [[ "$child_rc" -eq 42 ]] && [[ ! -e "$FIRST_PATH" ]] && [[ ! -e "$SECOND_PATH" ]]; then
  test_pass "post-fix reproducer cleans both tempfiles (child rc=42)"
else
  test_fail "post-fix reproducer leaked; child_rc=$child_rc; FIRST exists: $([[ -e $FIRST_PATH ]] && echo yes || echo no); SECOND exists: $([[ -e $SECOND_PATH ]] && echo yes || echo no)"
  rm -f "$FIRST_PATH" "$SECOND_PATH"
fi
rm -f "$tmp_out" "$tmp_stderr"

runner_summary
