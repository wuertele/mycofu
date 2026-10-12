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

# Disk evidence uses only a shimmed ssh. Include a differently named pool,
# two nodes, and nonstandard disk suffixes so the test cannot encode vdb=0.
# n1 (192.0.2.11) is the hosting node for every fixture VMID unless a mode
# says otherwise; n2 (192.0.2.12) is a replication target whose rows must
# never count as evidence (P2-1). `qm list` on each node answers the
# hosting-node probe; the zfs listing answers the disk read.
mkdir -p "$WORK/site" "$TMPDIR_ROOT/disk-shims"
cat > "$WORK/site/config.yaml" <<'EOF'
domain: example.test
storage: {pool_name: evidencepool}
proxmox: {storage_pool: ignored-storage-id}
nodes:
  - {name: n1, mgmt_ip: 192.0.2.11}
  - {name: n2, mgmt_ip: 192.0.2.12}
vms:
  vault_dev: {vmid: 101, backup: true}
  vault_prod: {vmid: 102, backup: true}
  gitlab: {vmid: 150, backup: true}
  cicd: {vmid: 160}
  hil_boot: {vmid: 170}
  pbs: {vmid: 190, ip: 192.0.2.19, backup: true}
EOF
cat > "$WORK/site/applications.yaml" <<'EOF'
applications:
  app:
    enabled: true
    environments:
      dev: {vmid: 501}
      prod: {vmid: 601}
  disabled:
    enabled: false
    environments:
      dev: {vmid: 999}
EOF
cat > "$TMPDIR_ROOT/disk-shims/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ " $* " == *" -n "* ]] || exit 97
[[ "${*: -1}" != true ]] || exit 0
mode="${STUB_ZFS_MODE:-old}"
if [[ -n "${DRT_REBUILD_MARKER:-}" && -f "$DRT_REBUILD_MARKER" ]]; then
  mode=new
fi
on_n2=0
[[ "$*" != *root@192.0.2.12* ]] || on_n2=1
if [[ "$on_n2" -eq 1 && "$mode" == unreachable ]]; then
  echo 'fixture SSH unreachable' >&2; exit 255
fi
if [[ "${*: -1}" == 'qm list' ]]; then
  # Hosting-node probe: exactly one node lists each VMID unless the mode
  # makes it unresolvable (nobody) or ambiguous (both).
  printf '      VMID NAME                 STATUS     MEM(MB)    BOOTDISK(GB) PID\n'
  case "$mode" in
    unhosted) ;;
    hosted_n2)
      [[ "$on_n2" -eq 0 ]] || printf '       101 vault                running    2048              20.00 4242\n' ;;
    multi_hosted)
      printf '       101 vault                running    2048              20.00 4242\n' ;;
    *)
      if [[ "$on_n2" -eq 0 ]]; then
        for vmid in 101 102 150 160 170 501 601; do
          printf '       %s vm-%s               running    2048              20.00 4242\n' "$vmid" "$vmid"
        done
      fi ;;
  esac
  exit 0
fi
[[ "${*: -1}" == 'zfs list -Hp -o name,creation,guid -t volume -r evidencepool/data' ]] || exit 98
if [[ "$on_n2" -eq 1 ]]; then
  case "$mode" in
    empty) exit 0 ;;
    malformed) echo 'invalid disk evidence'; exit 0 ;;
    # A reseeded replica: fresh creation on the target node only.
    replica_new) printf 'evidencepool/data/vm-101-disk-2\t2000000000\t101555\n' ;;
    # A stale replica still carrying the baseline vdb GUID.
    guid_replica) printf 'evidencepool/data/vm-101-disk-9\t80\t101111\n' ;;
    # The VM really lives on n2 now: its live disks are here.
    hosted_n2) printf 'evidencepool/data/vm-101-disk-2\t2000000000\t101777\n' ;;
  esac
  printf 'evidencepool/data/vm-999-disk-3\t80\t900\n'
  exit 0
fi
creation=90
guid=222
if [[ "$mode" == new || "$mode" == guid_lost || "$mode" == guid_replica || "$mode" == multi_hosted ]]; then creation=2000000000; guid=444; fi
for vmid in 101 102 150 160 170 501 601; do
  data_guid="${vmid}111"
  [[ "$mode" != guid_lost && "$mode" != guid_replica ]] || data_guid="${vmid}999"
  [[ "$mode" != mixed || "$vmid" != 101 ]] || creation=2000000000
  [[ "$mode" != mixed || "$vmid" != 102 ]] || creation=90
  printf 'evidencepool/data/vm-%s-disk-9\t80\t%s\n' "$vmid" "$data_guid"
  printf 'evidencepool/data/vm-%s-disk-2\t%s\t%s%s\n' "$vmid" "$creation" "$vmid" "$guid"
  printf 'evidencepool/data/vm-%s-cloudinit\t2000000000\t%s333\n' "$vmid" "$vmid"
done
EOF
chmod +x "$TMPDIR_ROOT/disk-shims/ssh"

# new: recreated on the hosting node -> PASS. hosted_n2: the VM migrated and
# its fresh disks are on n2 -> PASS (hosting resolved per read). replica_new:
# fresh dataset only on the replica node -> FAIL. unhosted: no node lists the
# VMID -> FAIL. multi_hosted: both nodes claim it -> FAIL. Never SKIP.
for mode in old new cloud unreachable empty malformed hosted_n2 replica_new unhosted multi_hosted; do
  test_start "H.disks.${mode}" "recreation evidence: ${mode}"
  SCRIPT=$(make_synthetic_drt "disks-${mode}" 'drt_verify_vm_recreated 100 101' "$TMPDIR_ROOT/disks-side-effect")
  set +e
  OUTPUT=$(cd "$WORK" && PATH="$TMPDIR_ROOT/disk-shims:$PATH" STUB_ZFS_MODE="$mode" bash "$SCRIPT" 2>&1)
  RC=$?
  set -e
  EXPECTED_RC=1; EXPECTED_OBSERVED=0
  case "$mode" in new|hosted_n2) EXPECTED_RC=0; EXPECTED_OBSERVED=1 ;; esac
  if [[ "$RC" -eq "$EXPECTED_RC" ]] &&
     [[ "$OUTPUT" == *"Coverage: recreation observed ${EXPECTED_OBSERVED}/1"* ]] &&
     [[ "$OUTPUT" != *"RESULT: BLOCKED"* ]]; then
    test_pass "${mode}: correct verdict and recreation coverage (never SKIP)"
  else
    test_fail "${mode}: expected ${EXPECTED_RC}, got ${RC}"
    printf '%s\n' "$OUTPUT" >&2
  fi
  case "$mode" in
    unhosted)
      if [[ "$OUTPUT" == *"Cannot resolve hosting node for VMIDs: 101"* ]]; then
        test_pass "${mode}: unresolvable hosting node is named in the failure"
      else
        test_fail "${mode}: hosting-node failure message missing"
        printf '%s\n' "$OUTPUT" >&2
      fi ;;
    multi_hosted)
      if [[ "$OUTPUT" == *"VMIDs listed on more than one node: 101"* ]]; then
        test_pass "${mode}: ambiguous hosting node is named in the failure"
      else
        test_fail "${mode}: ambiguous-hosting failure message missing"
        printf '%s\n' "$OUTPUT" >&2
      fi ;;
  esac
done

test_start "H.disks.rows" "replica rows are retained as informational context with hosting=false"
ROWS_JSON="$TMPDIR_ROOT/rows.json"
set +e
(cd "$WORK" && PATH="$TMPDIR_ROOT/disk-shims:$PATH" STUB_ZFS_MODE=replica_new bash -c "source '$COMMON_SH'; _drt_read_vm_disks '$ROWS_JSON' 101")
RC=$?
set -e
if [[ "$RC" -eq 0 ]] &&
   jq -e '.["101"] | (map(select(.hosting)) | length) == 2 and (map(select(.hosting | not)) | length) == 1
          and all(.[]; (.node == "192.0.2.11") == .hosting)' "$ROWS_JSON" >/dev/null; then
  test_pass "hosting flag follows the qm list owner; replica row kept but not evidence"
else
  test_fail "row hosting flags are wrong (rc=${RC})"
  cat "$ROWS_JSON" >&2 2>/dev/null || true
fi

test_start "H.disks.mixed" "each VM receives its own assertion and the summary records partial coverage"
SCRIPT=$(make_synthetic_drt mixed 'drt_verify_vm_recreated 100 101 102' "$TMPDIR_ROOT/mixed-side-effect")
set +e
OUTPUT=$(cd "$WORK" && PATH="$TMPDIR_ROOT/disk-shims:$PATH" STUB_ZFS_MODE=mixed bash "$SCRIPT" 2>&1)
RC=$?
set -e
if [[ "$RC" -eq 1 && "$OUTPUT" == *'[PASS] VM 101:'* && "$OUTPUT" == *'[FAIL] VM 102:'* &&
      "$OUTPUT" == *'Coverage: recreation observed 1/2'* ]]; then
  test_pass "partial recreation cannot certify the whole fleet"
else
  test_fail "partial recreation was misclassified"
  printf '%s\n' "$OUTPUT" >&2
fi

# guid_replica: the hosting node's GUIDs changed (PBS restore) while a stale
# replica on n2 still carries the baseline GUID -> FAIL (P2-1).
for mode in new guid_lost guid_replica; do
  test_start "H.guid.${mode}" "baseline GUID continuity: ${mode}"
  # The body is executed later by the synthetic script.
  # shellcheck disable=SC2016
  BODY='export STUB_ZFS_MODE=old
rc=0
drt_capture_vm_disks 101 || rc=$?
drt_assert "baseline captured" test "$rc" -eq 0
export STUB_ZFS_MODE='"$mode"'
drt_verify_vm_recreated 100 101
drt_verify_vdb_guid_preserved 101'
  SCRIPT=$(make_synthetic_drt "guid-${mode}" "$BODY" "$TMPDIR_ROOT/guid-side-effect")
  set +e
  OUTPUT=$(cd "$WORK" && PATH="$TMPDIR_ROOT/disk-shims:$PATH" bash "$SCRIPT" 2>&1)
  RC=$?
  set -e
  EXPECTED_RC=0
  [[ "$mode" != guid_lost && "$mode" != guid_replica ]] || EXPECTED_RC=1
  if [[ "$RC" -eq "$EXPECTED_RC" && "$OUTPUT" == *'Coverage: recreation observed 1/1'* ]]; then
    test_pass "${mode}: GUID continuity is independent of recreation"
  else
    test_fail "${mode}: GUID check verdict is wrong"
    printf '%s\n' "$OUTPUT" >&2
  fi
done

test_start "H.inventory" "inventory includes enabled app environments and excludes PBS/disabled HIL"
for scope in dev prod all; do
  # shellcheck source=framework/dr-tests/lib/common.sh
  OUTPUT=$(cd "$WORK" && source "$COMMON_SH" && drt_in_scope_vmids "$scope")
  case "$scope" in
    dev) EXPECTED=$'101\n501' ;;
    prod) EXPECTED=$'102\n601' ;;
    all) EXPECTED=$'101\n102\n150\n160\n170\n501\n601' ;;
  esac
  if [[ "$OUTPUT" == "$EXPECTED" ]]; then test_pass "${scope}: exact VM inventory"; else test_fail "${scope}: $OUTPUT"; fi
done
yq -i '.vms.hil_boot.enabled = false' "$WORK/site/config.yaml"
# shellcheck source=framework/dr-tests/lib/common.sh
OUTPUT=$(cd "$WORK" && source "$COMMON_SH" && drt_in_scope_vmids all)
if [[ "$OUTPUT" != *170* ]]; then test_pass "disabled HIL is excluded"; else test_fail "disabled HIL included"; fi
yq -i 'del(.vms.hil_boot.enabled)' "$WORK/site/config.yaml"

cat > "$WORK/plan.json" <<'EOF'
{"resource_changes":[
  {"type":"proxmox_virtual_environment_vm","change":{"actions":["delete","create"]}},
  {"type":"proxmox_virtual_environment_vm","change":{"actions":["create"]}},
  {"type":"proxmox_virtual_environment_vm","change":{"actions":["no-op"]}},
  {"type":"proxmox_virtual_environment_vm","change":{"actions":["update"]}},
  {"type":"terraform_data","change":{"actions":["delete","create"]}}
]}
EOF
for verdict in pass fail blocked; do
  test_start "H.plan.${verdict}" "plan observation appears in ${verdict} registry block"
  BODY='drt_record_plan_replacements plan.json'
  EXPECTED_RC=0
  case "$verdict" in
    fail) BODY+=$'\ndrt_assert "failure" false'; EXPECTED_RC=1 ;;
    blocked) BODY+=$'\ndrt_expect "attended"'; EXPECTED_RC=77 ;;
  esac
  SCRIPT=$(make_synthetic_drt "plan-${verdict}" "$BODY" "$TMPDIR_ROOT/plan-side-effect")
  set +e
  OUTPUT=$(cd "$WORK" && DRT_HEADLESS=1 bash "$SCRIPT" 2>&1)
  RC=$?
  set -e
  if [[ "$RC" -eq "$EXPECTED_RC" && "$OUTPUT" == *'Coverage: replacements observed: 1 replace / 1 create / 1 no-op of 4 VM resources'* ]]; then
    test_pass "${verdict}: observations survive into registry output without altering criteria"
  else
    test_fail "${verdict}: plan coverage missing or verdict wrong"
    printf '%s\n' "$OUTPUT" >&2
  fi
done

# Strict fingerprint mode is used only by DRT-010. Exercise the actual
# verifier with synthetic API responses, including UNKNOWN values that the
# older DRTs historically warn about or skip.
for fingerprint_case in known unknown_strict unknown_legacy; do
  test_start "H.fingerprint.${fingerprint_case}" "fingerprint verification: ${fingerprint_case}"
  cat > "$TMPDIR_ROOT/fingerprint-body.sh" <<'EOF'
drt_domain() { echo example.test; }
drt_vm_ip() { echo 192.0.2.1; }
drt_sops_value() { [[ "$FINGERPRINT_CASE" != unknown* ]] && echo fixture || true; }
drt_curl() {
  if [[ "$FINGERPRINT_CASE" == unknown* ]]; then echo '{}'; return; fi
  case "$*" in
    *oauth/token*) echo '{"access_token":"fixture"}' ;;
    *projects*) echo '[{}]' ;;
    *orgs*) echo '{"orgs":[{"name":"fixture"}]}' ;;
  esac
}
ssh() {
  case "$*" in
    *sys/health*)
      if [[ "$FINGERPRINT_CASE" == unknown* ]]; then echo '{}'; else echo '{"initialized":true}'; fi ;;
    *sys/mounts*) echo '{"fixture":{}}' ;;
    *du*) if [[ "$FINGERPRINT_CASE" == unknown* ]]; then echo 0; else echo 10; fi ;;
    *) return 98 ;;
  esac
}
DRT_FINGERPRINT=$(mktemp)
if [[ "$FINGERPRINT_CASE" == known ]]; then
  printf '%s\n' gitlab_project_count=1 vault_initialized=true vault_mount_count=1 influxdb_org=fixture roon_db_size_mb=10 > "$DRT_FINGERPRINT"
else
  printf '%s\n' gitlab_project_count=UNKNOWN vault_initialized=UNKNOWN vault_mount_count=UNKNOWN influxdb_org=UNKNOWN roon_db_size_mb=0 > "$DRT_FINGERPRINT"
fi
if [[ "$FINGERPRINT_CASE" == unknown_legacy ]]; then
  drt_verify_state_fingerprint
else
  drt_verify_state_fingerprint --strict
fi
EOF
  BODY="$(cat "$TMPDIR_ROOT/fingerprint-body.sh")"
  SCRIPT=$(make_synthetic_drt "fingerprint-${fingerprint_case}" "$BODY" "$TMPDIR_ROOT/fingerprint-side-effect")
  set +e
  OUTPUT=$(cd "$WORK" && FINGERPRINT_CASE="$fingerprint_case" bash "$SCRIPT" 2>&1)
  RC=$?
  set -e
  EXPECTED_RC=0
  [[ "$fingerprint_case" != unknown_strict ]] || EXPECTED_RC=1
  if [[ "$RC" -eq "$EXPECTED_RC" ]]; then
    test_pass "${fingerprint_case}: fingerprint exit ${RC}"
  else
    test_fail "${fingerprint_case}: fingerprint expected ${EXPECTED_RC}, got ${RC}"
    printf '%s\n' "$OUTPUT" >&2
  fi
done

# Execute the complete DRT-010 entry point in the synthetic repo. Only the
# expensive fingerprint/application operations are stubbed; the new inventory,
# disk evidence, manifest/status checks, and drt_finish run end-to-end.
mkdir -p "$WORK/framework/dr-tests/tests" "$WORK/framework/dr-tests/lib" "$WORK/framework/scripts" "$WORK/build"
cp "$REPO_ROOT/framework/dr-tests/tests/DRT-010-full-fleet-recreate.sh" "$WORK/framework/dr-tests/tests/"
cp "$REPO_ROOT/framework/scripts/list-backup-backed-vmids.sh" "$WORK/framework/scripts/"
cat > "$WORK/framework/dr-tests/lib/common.sh" <<EOF
source "$COMMON_SH"
drt_fingerprint_state() { DRT_FINGERPRINT=\$(mktemp); echo fixture > "\$DRT_FINGERPRINT"; }
drt_verify_state_fingerprint() { drt_assert "synthetic fingerprint matches" true; }
EOF
cat > "$WORK/framework/scripts/validate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$WORK/framework/scripts/validate.sh"
# backup-now.sh writes the run-scoped pin the DRT hands to rebuild-cluster.sh.
# pin_missing: exits 0 without writing it; pin_incomplete: pins only 101.
cat > "$WORK/framework/scripts/backup-now.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
pin_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pin-out) pin_out="$2"; shift 2 ;;
    *) echo "backup-now stub: unexpected argument $1" >&2; exit 3 ;;
  esac
done
[[ "${DRT_TEST_CASE:-}" != backup_failed ]] || exit 1
[[ -n "$pin_out" ]] || { echo "backup-now stub: --pin-out is required" >&2; exit 4; }
[[ "${DRT_TEST_CASE:-}" != pin_missing ]] || exit 0
pins='{"101":{"volid":"pbs-nas:backup/vm/101/2026-09-13T00:00:00Z","trust":"trusted"},"102":{"volid":"pbs-nas:backup/vm/102/2026-09-13T00:00:00Z","trust":"trusted"},"150":{"volid":"pbs-nas:backup/vm/150/2026-09-13T00:00:00Z","trust":"trusted"},"190":{"volid":"pbs-nas:backup/vm/190/2026-09-13T00:00:00Z","trust":"trusted"}}'
[[ "${DRT_TEST_CASE:-}" != pin_incomplete ]] || pins='{"101":{"volid":"pbs-nas:backup/vm/101/2026-09-13T00:00:00Z","trust":"trusted"}}'
mkdir -p "$(dirname "$pin_out")"
jq -n --argjson pins "$pins" '{version: 1, captured_at: "2026-09-13T00:00:00Z", pins: $pins}' > "$pin_out"
EOF
chmod +x "$WORK/framework/scripts/backup-now.sh"
cat > "$WORK/framework/scripts/rebuild-cluster.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "$DRT_REBUILD_MARKER"
scope=all
[[ "$*" != *env=dev* ]] || scope=env=dev
jq -n --arg scope "$scope" '{recreate:true, recreate_scope:$scope}' > build/rebuild-manifest.json
case "${DRT_TEST_CASE:-}" in
  not_forced) echo '{"recreate":false}' > build/rebuild-manifest.json ;;
esac
echo '{"expected":2,"replacing":2,"addresses":["vm1","vm2"]}' > build/recreate-plan-assert-bulk.json
[[ "${DRT_TEST_CASE:-}" != missing_plan ]] || rm build/recreate-plan-assert-bulk.json
entries='[{"vmid":101,"status":"spared"},{"vmid":102,"status":"restored"},{"vmid":150,"status":"restored"}]'
case "${DRT_TEST_CASE:-}" in
  empty_status) entries='[]' ;;
  incomplete_status) entries='[{"vmid":101,"status":"spared"},{"vmid":102,"status":"restored"}]' ;;
esac
jq -n --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson entries "$entries" \
  '{generated_at:$generated_at, entries:$entries}' > build/preboot-restore-status-bulk.json
[[ "${DRT_TEST_CASE:-}" != missing_status ]] || rm build/preboot-restore-status-bulk.json
EOF
chmod +x "$WORK/framework/scripts/rebuild-cluster.sh"
for case_name in dev all not_forced missing_plan empty_status incomplete_status missing_status backup_failed pin_missing pin_incomplete baseline_unreachable; do
  test_start "H.drt010.${case_name}" "synthetic DRT-010: ${case_name}"
  rm -f "$WORK/build/rebuild-marker" "$WORK/build/restore-pin-drt010.json"
  scope=all
  [[ "$case_name" != dev ]] || scope=dev
  zfs_mode=old
  [[ "$case_name" != baseline_unreachable ]] || zfs_mode=unreachable
  set +e
  OUTPUT=$(cd "$WORK" && PATH="$TMPDIR_ROOT/disk-shims:$PATH" DRT_TEST_CASE="$case_name" \
    STUB_ZFS_MODE="$zfs_mode" DRT_REBUILD_MARKER="$WORK/build/rebuild-marker" \
    bash framework/dr-tests/tests/DRT-010-full-fleet-recreate.sh --scope "$scope" 2>&1)
  RC=$?
  set -e
  EXPECTED_RC=1
  case "$case_name" in dev|all) EXPECTED_RC=0 ;; esac
  if [[ "$RC" -eq "$EXPECTED_RC" ]]; then
    test_pass "${case_name}: DRT-010 exits ${RC}"
  else
    test_fail "${case_name}: expected ${EXPECTED_RC}, got ${RC}"
    printf '%s\n' "$OUTPUT" >&2
  fi
  case "$case_name" in
    dev) EXPECTED='--recreate --scope env=dev --restore-pin-file build/restore-pin-drt010.json' ;;
    all) EXPECTED='--recreate --override-branch-check --restore-pin-file build/restore-pin-drt010.json' ;;
    backup_failed|baseline_unreachable|pin_missing|pin_incomplete)
      if [[ ! -e "$WORK/build/rebuild-marker" ]]; then test_pass "${case_name} aborts before rebuild"; else test_fail "${case_name} reached rebuild"; fi
      if [[ "$case_name" == pin_* ]]; then
        if [[ "$OUTPUT" == *"[FAIL] Restore pin covers every backup-backed in-scope VMID"* ]]; then
          test_pass "${case_name}: pin coverage assertion names the failure"
        else
          test_fail "${case_name}: pin coverage assertion did not fire"
          printf '%s\n' "$OUTPUT" >&2
        fi
      fi
      continue ;;
    *) continue ;;
  esac
  if [[ -f "$WORK/build/rebuild-marker" && "$(cat "$WORK/build/rebuild-marker")" == "$EXPECTED" ]]; then
    test_pass "${case_name}: exact rebuild invocation"
  else
    test_fail "${case_name}: wrong rebuild invocation"
  fi
  if [[ "$OUTPUT" == *"Coverage: restore pin: build/restore-pin-drt010.json"* ]]; then
    test_pass "${case_name}: registry block records the run-scoped pin"
  else
    test_fail "${case_name}: pin coverage line missing"
    printf '%s\n' "$OUTPUT" >&2
  fi
done

runner_summary
