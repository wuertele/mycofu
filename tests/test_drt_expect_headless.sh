#!/usr/bin/env bash
# test_drt_expect_headless.sh — regression coverage for issue #523.
#
# Before #523: drt_expect always ran `read -rp` against stdin. Under
# `set -euo pipefail`, an EOF stdin (agent session, CI, `< /dev/null`)
# aborted the whole test with a bare `exit 1` — no verdict block, no
# [FAIL] line, and any post-drt_expect commands never ran either.
# The 2026-07-08 DRT-002 rerun manufactured a failure this way with
# all 8 automated assertions already passing.
#
# The fix (see framework/dr-tests/lib/common.sh) adds:
#   - _drt_is_headless: DRT_HEADLESS=1 OR non-TTY stdin.
#   - drt_expect <desc> [verify_cmd...]: verify_cmd runs headless;
#     otherwise the step is BLOCKED and the test terminates before
#     any downstream side-effect command (rebalance-cluster.sh,
#     qm start, ha-manager set, ...).
#   - drt_finish: BLOCKED(attended-required) verdict on non-empty
#     DRT_BLOCKED_LIST, distinct exit code $DRT_BLOCKED_EXIT (77).
#
# The tests below drive the lib through synthetic single-file DRT
# scripts written into a tempdir, so this test is fully hermetic —
# no cluster, no GitLab, no sops.

set -euo pipefail

# Force a predictable PS4 for H.6's bash -x trace grep. If the parent shell
# customizes PS4 to strip the leading '+', the impossibility guarantee grep
# would silently miss executed `read -rp` lines. Set it here so the test's
# structural proof is env-independent.
export PS4='+ '

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

COMMON_SH="${REPO_ROOT}/framework/dr-tests/lib/common.sh"

# --- Sanity: the file parses ---
test_start "H.0" "common.sh parses (bash -n)"
if bash -n "$COMMON_SH" 2>/dev/null; then
  test_pass "H.0: common.sh is syntactically valid"
else
  test_fail "H.0: common.sh has a syntax error"
fi

# --- Shared harness ---
# make_synthetic_drt writes a self-contained script that sources common.sh
# from the real path and runs the fragment provided on stdin as the "body".
# The synthetic script writes SIDE_EFFECT_FILE just before drt_finish so
# tests can prove whether execution reached that point.
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

# Provide a stub `framework/dr-tests` directory so drt_init's repo-root
# check passes when the synthetic script runs with WORK as cwd, and a
# throwaway git repo so drt_init's `git rev-parse` returns something.
WORK="$TMPDIR_ROOT/work"
mkdir -p "$WORK/framework/dr-tests"
(
  cd "$WORK"
  git init -q
  git config user.email "test@example.invalid"
  git config user.name "test"
  # commit.gpgsign might be set at ~/.gitconfig; disable for the throwaway repo
  git config commit.gpgsign false
  git commit -q --allow-empty -m "seed"
) >/dev/null 2>&1

make_synthetic_drt() {
  local name="$1" body="$2" side_effect="$3"
  local script="$TMPDIR_ROOT/${name}.sh"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
DRT_ID="DRT-HEADLESS-TEST"
DRT_NAME="Synthetic Headless Test"
source "$COMMON_SH"
drt_init
${body}
# If execution reaches here, mark the side-effect file. Tests use presence
# of this file to prove drt_expect did NOT short-circuit.
touch "$side_effect"
drt_finish
EOF
  chmod +x "$script"
  echo "$script"
}

# --- H.1: EOF stdin + DRT_HEADLESS=1 + no verify_cmd → BLOCKED, no manufactured FAIL ---
test_start "H.1" "headless + no verifier: BLOCKED verdict, exit 77, no side-effect after drt_expect"
SIDE_EFFECT="$TMPDIR_ROOT/h1_side_effect"
SCRIPT=$(make_synthetic_drt "h1" 'drt_expect "attended-only step"' "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" < /dev/null 2>&1)
RC=$?
set -e
if [[ $RC -eq 77 ]]; then
  test_pass "H.1: exit code is 77 (BLOCKED)"
else
  test_fail "H.1: expected exit 77, got exit ${RC}"
fi
if echo "$OUTPUT" | grep -qF "[SKIP-ATTENDED]"; then
  test_pass "H.1: [SKIP-ATTENDED] emitted for the unverifiable step"
else
  test_fail "H.1: no [SKIP-ATTENDED] marker in output"
fi
if echo "$OUTPUT" | grep -qF "BLOCKED(attended-required)"; then
  test_pass "H.1: BLOCKED(attended-required) verdict present in output"
else
  test_fail "H.1: no BLOCKED(attended-required) verdict"
fi
if echo "$OUTPUT" | grep -qF "[FAIL] attended-only step"; then
  test_fail "H.1: manufactured [FAIL] for unverifiable step (the bug we're fixing)"
else
  test_pass "H.1: no manufactured [FAIL] for the unverifiable step"
fi
if [[ ! -e "$SIDE_EFFECT" ]]; then
  test_pass "H.1: post-drt_expect side-effect command did NOT execute"
else
  test_fail "H.1: post-drt_expect side-effect command executed — BLOCKED did not stop the run"
fi
if echo "$OUTPUT" | grep -qF "framework/dr-tests/run-dr-test.sh DRT-HEADLESS-TEST"; then
  test_pass "H.1: BLOCKED verdict directs operator to safe rerun-attended action (G7)"
else
  test_fail "H.1: BLOCKED verdict does not guide operator to a safe action"
fi

# --- H.2: TTY-less stdin without DRT_HEADLESS=1 → still detects headless ---
# Exercises the [ ! -t 0 ] auto-detect path — the exact DRT-002 shape.
test_start "H.2" "auto-detect: non-TTY stdin, no DRT_HEADLESS override, still BLOCKS"
SIDE_EFFECT="$TMPDIR_ROOT/h2_side_effect"
SCRIPT=$(make_synthetic_drt "h2" 'drt_expect "attended-only step"' "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && bash "$SCRIPT" < /dev/null 2>&1)
RC=$?
set -e
if [[ $RC -eq 77 ]]; then
  test_pass "H.2: non-TTY stdin auto-detected, exit 77"
else
  test_fail "H.2: expected exit 77 on non-TTY stdin, got ${RC}"
fi
if [[ ! -e "$SIDE_EFFECT" ]]; then
  test_pass "H.2: post-drt_expect side-effect did NOT execute under auto-detect"
else
  test_fail "H.2: auto-detect failed — post-drt_expect side-effect executed"
fi
if echo "$OUTPUT" | grep -qF "[FAIL] attended-only step"; then
  test_fail "H.2: manufactured [FAIL] under auto-detect"
else
  test_pass "H.2: no manufactured [FAIL] under auto-detect"
fi

# --- H.3: headless + PASSING verify_cmd → PASS, no BLOCK, script continues ---
test_start "H.3" "headless + verifier exits 0: PASS, script proceeds to drt_finish normally"
SIDE_EFFECT="$TMPDIR_ROOT/h3_side_effect"
SCRIPT=$(make_synthetic_drt "h3" 'drt_expect "machine-verifiable step" true' "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" < /dev/null 2>&1)
RC=$?
set -e
if [[ $RC -eq 0 ]]; then
  test_pass "H.3: verifier passed, exit 0"
else
  test_fail "H.3: expected exit 0 with passing verifier, got ${RC}"
fi
if echo "$OUTPUT" | grep -qF "[PASS] machine-verifiable step (headless verify)"; then
  test_pass "H.3: [PASS] emitted with (headless verify) marker"
else
  test_fail "H.3: no [PASS] (headless verify) line in output"
fi
if [[ -e "$SIDE_EFFECT" ]]; then
  test_pass "H.3: post-drt_expect command DID execute (verifier passed, script proceeded)"
else
  test_fail "H.3: verifier passed but script short-circuited before drt_finish"
fi
if echo "$OUTPUT" | grep -qF "BLOCKED"; then
  test_fail "H.3: unexpected BLOCKED verdict when verifier passed"
else
  test_pass "H.3: no BLOCKED verdict when verifier passed"
fi

# --- H.4: headless + FAILING verify_cmd → real [FAIL], exit 1, TERMINAL ---
# Post-fix contract: a headless verify_cmd failure is terminal (drt_finish +
# exit 1), so downstream side-effect commands never run. This closes the
# "power-off verifier fails → rebalance-cluster.sh runs anyway" hole that
# both gemini and the fork reviewer independently flagged as P1.
test_start "H.4" "headless + verifier fail: [FAIL] recorded, exit 1, downstream commands do NOT run"
SIDE_EFFECT="$TMPDIR_ROOT/h4_side_effect"
SCRIPT=$(make_synthetic_drt "h4" 'drt_expect "verifier-fails step" false' "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" < /dev/null 2>&1)
RC=$?
set -e
if [[ $RC -eq 1 ]]; then
  test_pass "H.4: verifier failed, exit 1 (FAIL — not the BLOCKED skip code 77)"
else
  test_fail "H.4: expected exit 1 with failing verifier, got ${RC}"
fi
if echo "$OUTPUT" | grep -qF "[FAIL] verifier-fails step (headless verify)"; then
  test_pass "H.4: [FAIL] emitted with (headless verify) marker"
else
  test_fail "H.4: no [FAIL] (headless verify) line in output"
fi
if echo "$OUTPUT" | grep -qF "RESULT: FAIL"; then
  test_pass "H.4: FAIL verdict emitted (not BLOCKED — verifier ran to completion)"
else
  test_fail "H.4: expected RESULT: FAIL, missing"
fi
if echo "$OUTPUT" | grep -qF "BLOCKED"; then
  test_fail "H.4: unexpected BLOCKED verdict when verifier ran and failed"
else
  test_pass "H.4: no BLOCKED verdict when verifier ran"
fi
if [[ ! -e "$SIDE_EFFECT" ]]; then
  test_pass "H.4: post-drt_expect side-effect did NOT execute (verifier fail is terminal)"
else
  test_fail "H.4: downstream side-effect ran after verifier FAIL — G3 hole open"
fi

# --- H.5: multi-step — verifier passes for step 1, no verifier for step 2 → BLOCKED,
#          and the second BLOCK still records only the truly-blocked step ---
test_start "H.5" "mixed run: passing verifier → then attended step: BLOCKED lists only the unverifiable step"
SIDE_EFFECT="$TMPDIR_ROOT/h5_side_effect"
BODY='drt_expect "verifiable step" true
drt_expect "attended-only step"'
SCRIPT=$(make_synthetic_drt "h5" "$BODY" "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" < /dev/null 2>&1)
RC=$?
set -e
if [[ $RC -eq 77 ]]; then
  test_pass "H.5: mixed run exits 77 (BLOCKED)"
else
  test_fail "H.5: expected exit 77, got ${RC}"
fi
# The verifiable step should record a PASS.
if echo "$OUTPUT" | grep -qF "[PASS] verifiable step (headless verify)"; then
  test_pass "H.5: verifiable step recorded PASS before the block"
else
  test_fail "H.5: verifiable step did not record PASS"
fi
# The attended-only step should be in the BLOCKED list, not the failure list.
# (Header may be singular "Attended step skipped:" or plural "Attended steps
# skipped:" depending on the count — both accepted here.)
if echo "$OUTPUT" | grep -qE "Attended steps? skipped:" \
   && echo "$OUTPUT" | grep -qF "  - attended-only step"; then
  test_pass "H.5: BLOCKED verdict lists the unverifiable step"
else
  test_fail "H.5: BLOCKED verdict does not enumerate the unverifiable step"
fi
if echo "$OUTPUT" | grep -qF "  - verifiable step"; then
  test_fail "H.5: the passing verifiable step was mislisted as blocked"
else
  test_pass "H.5: passing verifiable step is NOT in the BLOCKED list"
fi
if [[ ! -e "$SIDE_EFFECT" ]]; then
  test_pass "H.5: post-block side-effect did NOT execute"
else
  test_fail "H.5: post-block side-effect executed"
fi

# --- H.6: read -rp is NOT called under any headless path (structural guarantee) ---
# Uses bash -x tracing on the synthetic script to prove no `read` command
# executes when headless. This is the impossibility guarantee for G3:
# without `read`, EOF cannot trigger `set -e`. PS4='+ ' is forced at the top
# of this test file so the grep is env-independent (codex P2/fork P2).
test_start "H.6" "structural: no 'read -rp' invocation on the headless code path"
SIDE_EFFECT="$TMPDIR_ROOT/h6_side_effect"
SCRIPT=$(make_synthetic_drt "h6" 'drt_expect "attended-only step"' "$SIDE_EFFECT")
set +e
TRACE=$(cd "$WORK" && DRT_HEADLESS=1 PS4='+ ' bash -x "$SCRIPT" < /dev/null 2>&1)
TRACE_RC=$?
set -e
# grep for the read invocation on the headless path. The trace prefixes
# executed commands with '+'. We reject any executed `read -rp` line.
if echo "$TRACE" | grep -E '^\+.* read -rp' >/dev/null; then
  test_fail "H.6: 'read -rp' executed on the headless path — impossibility invariant broken"
else
  test_pass "H.6: no 'read -rp' executed on the headless path (EOF stdin cannot be reached)"
fi
# Sanity: the traced run should still exit with the BLOCKED code — otherwise
# the run silently died before reaching drt_expect and the impossibility grep
# above proved nothing.
if [[ $TRACE_RC -eq 77 ]]; then
  test_pass "H.6: traced synthetic exited 77 (BLOCKED — the impossibility grep is meaningful)"
else
  test_fail "H.6: traced synthetic exited ${TRACE_RC}, expected 77 — grep may have proved nothing"
fi

# --- H.7: BLOCKED verdict is emitted on stdout so run-dr-test.sh operator can see it ---
test_start "H.7" "BLOCKED verdict block contains all fields DR-REGISTRY.md expects"
SIDE_EFFECT="$TMPDIR_ROOT/h7_side_effect"
SCRIPT=$(make_synthetic_drt "h7" 'drt_expect "attended-only step"' "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" < /dev/null 2>&1)
set -e
for field in "DRT-HEADLESS-TEST" "Date:" "Commit:" "Result:  BLOCKED(attended-required)" "Time:"; do
  if echo "$OUTPUT" | grep -qF "$field"; then
    test_pass "H.7: BLOCKED verdict includes '${field}'"
  else
    test_fail "H.7: BLOCKED verdict missing '${field}'"
  fi
done

# --- H.8: exactly one read -rp in common.sh (structural regression ratchet) ---
# Not a claim that the read is on the "right" branch — the impossibility proof
# lives in H.6, which observes the trace at runtime. This is a static ratchet
# so any future edit introducing a second `read -rp` (thereby reopening the
# EOF-stdin exposure surface) fails this test loudly.
test_start "H.8" "static ratchet: exactly one 'read -rp' call remains in common.sh"
COUNT=$(grep -c 'read -rp' "$COMMON_SH")
if [[ $COUNT -eq 1 ]]; then
  test_pass "H.8: exactly one 'read -rp' invocation in common.sh"
else
  test_fail "H.8: expected 1 'read -rp' invocation in common.sh, found ${COUNT}"
fi

# --- H.9: FAIL + BLOCKED co-occur → exit 1 (FAIL), NOT exit 77 ---
# Regression coverage for the P1 all three reviewers flagged: BLOCKED must not
# mask a real drt_assert FAIL that happened before the block. Otherwise a
# failing DRT would exit 77 (SKIP) and any CI wrapper interpreting 77 as a
# soft-skip would silently downgrade the failure.
test_start "H.9" "FAIL + BLOCKED coexistence: verdict is FAIL (exit 1), not BLOCKED (exit 77)"
SIDE_EFFECT="$TMPDIR_ROOT/h9_side_effect"
BODY='drt_assert "always-fails assertion" bash -c "exit 3"
drt_expect "attended-only step after assertion FAIL"'
SCRIPT=$(make_synthetic_drt "h9" "$BODY" "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" < /dev/null 2>&1)
RC=$?
set -e
if [[ $RC -eq 1 ]]; then
  test_pass "H.9: FAIL+BLOCKED exits 1 (FAIL wins over BLOCKED)"
else
  test_fail "H.9: expected exit 1 (FAIL precedence), got ${RC} — BLOCKED masked FAIL"
fi
if echo "$OUTPUT" | grep -qE "RESULT: FAIL"; then
  test_pass "H.9: RESULT: FAIL verdict emitted (not BLOCKED)"
else
  test_fail "H.9: FAIL verdict absent — BLOCKED text masked FAIL text"
fi

# --- H.10: drt_finish is idempotent under repeated invocation ---
# Regression coverage for the re-entrancy P2 (gemini + fork): callers may add
# `trap drt_finish EXIT` for exception-safety, and drt_expect also invokes
# drt_finish directly. Double-printing the verdict block would be confusing;
# assert exactly one RESULT line lands.
test_start "H.10" "drt_finish is idempotent (safe under trap drt_finish EXIT + explicit call)"
SIDE_EFFECT="$TMPDIR_ROOT/h10_side_effect"
BODY='trap drt_finish EXIT
drt_expect "attended-only step"'
SCRIPT=$(make_synthetic_drt "h10" "$BODY" "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" < /dev/null 2>&1)
RC=$?
set -e
RESULT_COUNT=$(echo "$OUTPUT" | grep -cE "^RESULT: (PASS|FAIL|BLOCKED)" || true)
if [[ "$RESULT_COUNT" -eq 1 ]]; then
  test_pass "H.10: exactly one RESULT verdict line emitted under trap+explicit"
else
  test_fail "H.10: expected 1 RESULT line, got ${RESULT_COUNT} (idempotence broken)"
fi
if [[ $RC -eq 77 ]]; then
  test_pass "H.10: exit code is still 77 with trap installed"
else
  test_fail "H.10: expected exit 77, got ${RC}"
fi

# --- H.11: BLOCKED verdict does NOT echo the raw imperative description ---
# G7 sharpening (codex P1): DRT-005 style "Power off node ... now" is fine as
# an attended prompt but reads as a bogus instruction on the headless path.
# Assert the headless SKIP-ATTENDED path frames the outcome as "no action was
# performed", not as an imperative.
test_start "H.11" "headless SKIP-ATTENDED frames outcome; does not print the description as imperative"
SIDE_EFFECT="$TMPDIR_ROOT/h11_side_effect"
BODY='drt_expect "Power off node pve02 (172.17.77.42) now. Use IPMI/AMT/BMC or physical power button."'
SCRIPT=$(make_synthetic_drt "h11" "$BODY" "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" < /dev/null 2>&1)
set -e
# The description itself will appear on the [SKIP-ATTENDED] line — that's
# expected; SKIP-ATTENDED contextualizes it. What we forbid is the pre-fix
# "[?] Verify manually: <description>" line, which would read as an
# imperative on the headless path.
if echo "$OUTPUT" | grep -qF "[?] Verify manually: Power off"; then
  test_fail "H.11: '[?] Verify manually:' still emitted on headless path (misleading imperative)"
else
  test_pass "H.11: no '[?] Verify manually:' line on headless path"
fi
if echo "$OUTPUT" | grep -qF "[SKIP-ATTENDED] Power off"; then
  test_pass "H.11: SKIP-ATTENDED includes the description for the DR registry paste"
else
  test_fail "H.11: SKIP-ATTENDED marker missing the description"
fi
if echo "$OUTPUT" | grep -qF "No physical/manual"; then
  test_pass "H.11: SKIP-ATTENDED body clarifies no action was performed"
else
  test_fail "H.11: SKIP-ATTENDED body does not disclaim the action"
fi

# --- H.12: drt_expect with no description exits with a clear internal-error ---
# Arity guard (codex P2). Under set -u the pre-fix behavior was a cryptic
# unbound-variable message; the fix should surface a clear internal error.
test_start "H.12" "arity guard: drt_expect with no args fails with a clear internal error"
SIDE_EFFECT="$TMPDIR_ROOT/h12_side_effect"
BODY='drt_expect'
SCRIPT=$(make_synthetic_drt "h12" "$BODY" "$SIDE_EFFECT")
set +e
OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" < /dev/null 2>&1)
RC=$?
set -e
if [[ $RC -ne 0 ]]; then
  test_pass "H.12: drt_expect with no args exits non-zero (arity guard fires)"
else
  test_fail "H.12: drt_expect with no args exited 0 (arity guard missing)"
fi
if echo "$OUTPUT" | grep -qF "missing description"; then
  test_pass "H.12: arity guard emits a clear internal-error message"
else
  test_fail "H.12: arity-guard message unclear"
fi

runner_summary
