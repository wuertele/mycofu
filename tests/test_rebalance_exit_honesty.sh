#!/usr/bin/env bash
# test_rebalance_exit_honesty.sh — #697 P4 ratchet.
#
# rebalance-cluster.sh's Sprint 048 M4 attempt-2 (DRT-005, 2026-07-23)
# showed nine attempted migrations, zero successful, exit 0. The 5-min
# timeout branch printed a WARNING but did not feed the exit code, and
# verify_recovery only checked HA states (error/started) not placement,
# so drifted-but-running VMs slipped through.
#
# This test locks in the fixed shape: any per-VM migration failure —
# either the `ha-manager migrate` command errored, or the VM did not
# reach its intended node within the 5-minute placement window — is
# collected into MIGRATE_FAILURES and drives a nonzero exit. And the
# placement-watchdog captures rebalance's rc without pipefail-crashing
# the cron job.
#
# Coverage:
#   1. rebalance-cluster.sh declares MIGRATE_FAILURES array.
#   2. move-command rc is captured (not silently discarded) and
#      failures push into MIGRATE_FAILURES.
#   3. placement-timeout arm ALSO pushes into MIGRATE_FAILURES.
#   4. Tail block exits 1 when MIGRATE_FAILURES is non-empty.
#   5. Failure list is printed on stdout so the operator sees which
#      VMs failed.
#   6. placement-watchdog.sh captures rebalance's exit under pipefail
#      (no crash-loop) and logs a WARNING.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

REBALANCE="${REPO_ROOT}/framework/scripts/rebalance-cluster.sh"
WATCHDOG="${REPO_ROOT}/framework/scripts/placement-watchdog.sh"

test_start "p4.a" "MIGRATE_FAILURES accumulator declared"
if grep -Fq 'MIGRATE_FAILURES=()' "$REBALANCE"; then
  test_pass "MIGRATE_FAILURES array declared"
else
  test_fail "MIGRATE_FAILURES accumulator missing"
fi

test_start "p4.b" "move-command rc captured; failure pushes MIGRATE_FAILURES and skips the wait loop"
# Also ratchet that `continue` follows the failure push — else the 5-min
# wait loop runs on a VM whose move already failed, double-counting the
# same VM into MIGRATE_FAILURES (sub-claude P3-2).
move_fail_block=$(awk '/if \[\[ "\$move_rc" -ne 0 \]\]; then/,/fi$/' "$REBALANCE")
if grep -Fq 'move_rc=$?' "$REBALANCE" && \
   grep -Fq 'MIGRATE_FAILURES+=("${vm} (VMID ${vmid}): ${MOVE_VERB} command failed' "$REBALANCE" && \
   grep -Fq continue <<< "$move_fail_block"; then
  test_pass "move-command failure pushes MIGRATE_FAILURES and continues"
else
  test_fail "move-command failure branch missing push or missing continue"
fi

test_start "p4.c" "placement-timeout branch feeds MIGRATE_FAILURES (was WARNING-only)"
if grep -Fq 'migration_done=0' "$REBALANCE" && \
   grep -Fq 'MIGRATE_FAILURES+=("${vm} (VMID ${vmid}): ${MOVE_VERB} timed out' "$REBALANCE"; then
  test_pass "5-min timeout branch pushes into MIGRATE_FAILURES"
else
  test_fail "timeout branch does not update MIGRATE_FAILURES — the M4 attempt-2 shape"
fi

test_start "p4.d" "nonempty MIGRATE_FAILURES exits 1"
tail_block=$(awk '/^# Any VM the script ATTEMPTED to migrate/,/^exit 0$/' "$REBALANCE")
if [[ -z "$tail_block" ]]; then
  test_fail "could not locate P4 tail block (exit-honesty guard)"
elif ! grep -Fq 'exit 1' <<< "$tail_block"; then
  test_fail "P4 tail block does not exit 1 on failed migrations"
elif ! grep -Fq '#697 P4' <<< "$tail_block"; then
  test_fail "P4 tail block missing #697 P4 pointer"
else
  test_pass "any attempted-and-failed migration produces exit 1"
fi

test_start "p4.e" "per-VM failure list printed on stdout"
if grep -Fq 'Migration failures:' "$REBALANCE" && \
   grep -Fq 'for f in "${MIGRATE_FAILURES[@]}"' "$REBALANCE"; then
  test_pass "per-VM failure list is enumerated for the operator"
else
  test_fail "per-VM failure list missing — operator loses forensic detail"
fi

test_start "p4.f" "placement-watchdog captures rebalance rc without pipefail-crashing"
# Ratchet: the PIPESTATUS capture must be wrapped in set +e / set -e so a
# nonzero rebalance rc doesn't kill the watchdog via errexit BEFORE the
# capture line executes (sub-claude P3-4). Without this guard the exit
# happens too early and the watchdog log never records the rc.
watchdog_capture_block=$(awk '/set \+e/,/set -e/' "$WATCHDOG" | head -20)
if grep -Fq 'REBALANCE_RC=${PIPESTATUS[0]}' "$WATCHDOG" && \
   grep -Fq 'rebalance-cluster.sh exited with rc=' "$WATCHDOG" && \
   grep -Fq 'set +e' "$WATCHDOG" && \
   grep -Fq 'REBALANCE_RC=${PIPESTATUS[0]}' <<< "$watchdog_capture_block"; then
  test_pass "placement-watchdog tolerates nonzero rebalance exit and logs it (wrapped in set +e/-e)"
else
  test_fail "placement-watchdog does not capture/log rebalance rc under set +e — crash-loop risk"
fi

test_start "p4.g" "placement-watchdog Rebalance complete only logs on success (codex-tightened)"
# A log line that reads "Rebalance complete." after a failed rebalance is a
# lie the operator has to disprove by scrolling. The success line must be
# gated on REBALANCE_RC == 0.
watchdog_block=$(awk '/if \[\[ -x "\$REBALANCE" \]\]; then/,/^fi$/' "$WATCHDOG")
if [[ -z "$watchdog_block" ]]; then
  test_fail "could not locate REBALANCE block in placement-watchdog.sh"
elif ! grep -Fq '"$REBALANCE_RC" -ne 0' <<< "$watchdog_block"; then
  test_fail "watchdog does not branch on REBALANCE_RC"
elif ! grep -B0 -A2 '"$REBALANCE_RC" -ne 0' <<< "$watchdog_block" | grep -Fq 'else'; then
  test_fail "watchdog logs 'Rebalance complete' unconditionally — dishonest on failure"
else
  test_pass "success line gated on REBALANCE_RC == 0"
fi

test_start "p4.h" "rebalance polling wrapped in set +e so a transient poll error cannot skip MIGRATE_FAILURES bookkeeping (codex-tightened)"
# The wait loop between move-command and result-check must not be able to
# abort the script under `set -euo pipefail` — otherwise a ssh/pvesh
# hiccup after a successful command dispatch causes the script to bail and
# never record the failure in MIGRATE_FAILURES.
poll_block=$(awk '/# Wait for migration to complete \(up to 5 minutes\)/,/^      if \[\[ "\$migration_done" -ne 1 \]\]; then$/' "$REBALANCE")
if [[ -z "$poll_block" ]]; then
  test_fail "could not locate polling block"
elif ! grep -Fq 'set +e' <<< "$poll_block" || ! grep -Fq 'set -e' <<< "$poll_block"; then
  test_fail "polling block lacks set +e / set -e envelope — bookkeeping can be skipped by pipefail"
else
  test_pass "polling wrapped in set +e / set -e"
fi

runner_summary
