#!/usr/bin/env bash
# rolling-reboot-node-inner.sh — HA-aware rolling reboot of one Proxmox node.
#
# **Do NOT invoke this directly from the workstation.** It is the
# Proxmox-node-side component of the rolling-reboot procedure. Use
# `framework/scripts/reboot-node-rolling.sh <target>` from the
# workstation; that wrapper SCPs this script to a surviving node and
# executes it with the right arguments.
#
# Why a separate file: this script uses `qm`, `ha-manager`, and
# `pvecm`, which only exist on Proxmox hosts. It must run on a
# surviving cluster member (NOT the target node, since the target is
# about to reboot). The wrapper handles workstation→node transport;
# this script handles the host-local dance.
#
# Procedure (must be invoked as: bash rolling-reboot-node-inner.sh <N> <other>):
#   a. ha-manager crm-command node-maintenance enable <N>
#   b. Drain wait: poll `qm list` on <N> until no VM is in a non-stopped
#      state. Non-stopped includes running, paused, suspended,
#      prelaunch, and io-error.
#   c. ssh root@<N> reboot
#   d. Poll SSH+quorum on <N> until back, 10-min cap.
#   e. ha-manager crm-command node-maintenance disable <N>
#
# Safety contract:
#   - `set -uo pipefail` (NOT -e; see comment block at top of script body).
#   - Every external command's exit code is checked explicitly.
#   - The cleanup trap auto-disables HA maintenance on ANY non-zero
#     exit (die from step b/c/d/e, Ctrl-C, SIGTERM), preventing the
#     2026-05-14 incident pattern: a step-b ssh failure that left
#     pve02 in HA maintenance for 12 minutes / ~30 aborted migrations.
#
# History:
#   - #338 — original cleanup trap was INT/TERM-only; any die() exited
#     with maintenance enabled. The cleanup-on-EXIT fix was originally
#     drafted into OPERATIONS.md's inline template.
#   - #345 — extract from OPERATIONS.md into this file so hermetic tests
#     can exercise it. Apply the #338 fix as part of the same change.
#   - 2026-05-16 T5b integration test against pve01 uncovered a race
#     in the original step-a-first ordering: `ha-manager crm-command
#     node-maintenance enable` is fire-and-forget. The target node's
#     LRM picks up the request ~5s later. If step b's first ssh+qm
#     poll fails immediately (target was unreachable from the start),
#     the trap correctly disables maintenance, but the LRM has by
#     then queued migrations for ALL HA-managed VMs on the target.
#     Some migrate-back cleanly once the disable lands; some hit
#     unrelated migration bugs (#336) and stick. Observed outcome on
#     pve01: ~5s of migration churn, vm:160 (cicd) failed to migrate
#     entirely, and the LRM's local `state` field was left stuck at
#     `maintenance` for ~hours (cosmetic: CRM treats node as online,
#     but `ha-manager status` shows the wrong label).
#     Step 0 below pre-checks ssh+qm to $N BEFORE asking HA to do
#     anything. If the target is already unreachable, we fail with
#     MAINT_ENABLED still 0; the trap fires as a no-op and no
#     migrations are queued. The post-enable trap remains as the
#     safety net for failures that happen later in the procedure
#     (target dies mid-drain, network blips mid-quorum-wait, signal
#     during sleep, etc.) — those still produce some migration
#     churn but are rare and unpredictable, vs. the pre-script
#     reachability check which catches the common case deterministically.

# MAINT_SH_TEMPLATE -- DO NOT REMOVE: anchor for tests/test_rolling_reboot_node.sh
# Note: this script intentionally does NOT use `set -e`. Bash silently
# swallows `$(...)` failures inside assignments under `set -e`, which
# would defeat the whole point of fail-closed safety checks here.
# Every ssh+qm call below explicitly checks its exit code and dies on
# failure -- read top to bottom to verify the safety contract.
set -uo pipefail

N="${1:?usage: bash rolling-reboot-node-inner.sh <node> <other-node>}"
OTHER="${2:?usage: bash rolling-reboot-node-inner.sh <node> <other-node>}"

die() { echo "ERROR: $*" >&2; exit 1; }

# Validate args before touching HA state. A same-node migrate would
# be a long-running fail-closed run via qm migrate's own rejection,
# but it's clearer to die early.
[[ "$N" != "$OTHER" ]] || die "<N> and <other-node> must be different nodes"

# MAINT_ENABLED tracks whether the script BELIEVES $N may be in HA
# maintenance. The cleanup trap reads this to decide whether to call
# `ha-manager ... disable`. We set it to 1 BEFORE the `ha-manager
# enable` call so the cleanup arm covers BOTH:
#   - enable succeeded then a later step died/was interrupted (the
#     2026-05-14 incident: die() from step b left maintenance enabled
#     for 12 minutes while HA retried ~30 migrations);
#   - enable returned non-zero or was interrupted partway through
#     (rare, but ha-manager has been observed to apply maintenance
#     server-side then fail the client response).
# `ha-manager disable` is idempotent: calling it on a node that is
# not in maintenance is a benign no-op, so a false-positive cleanup
# attempt after a pre-enable die has no cost beyond a log line.
MAINT_ENABLED=0

# Cleanup on ANY exit (#338):
# - Successful completion path sets MAINT_ENABLED=0 after step e, so
#   the trap fires as a no-op.
# - Any failure path (die from step b/c/d/e, ssh failure during step
#   b's loop, Ctrl-C/SIGTERM interrupt) leaves MAINT_ENABLED=1 with a
#   non-zero rc, so the trap auto-disables maintenance to avoid
#   leaving the cluster in a stuck-migration loop. The auto-disable
#   is the LEAST-SURPRISING recovery: HA returns to normal placement
#   decisions, and the operator can investigate the underlying
#   failure without the cluster's degraded state masking new symptoms.
#
# Signal handling: the EXIT trap fires on every exit, but $? at trap
# entry reflects the LAST command's rc, not the signal that caused
# exit. When SIGINT/SIGTERM arrives while bash is waiting on `sleep`,
# $? is 0, which would defeat the rc-based guard below. To avoid
# that, we install dedicated signal handlers that exit with the
# canonical signal-encoded rc (130 for SIGINT, 143 for SIGTERM); the
# EXIT trap then sees a non-zero rc and runs the auto-disable arm.
# The signal handlers do not call cleanup directly -- they just exit;
# cleanup runs once, via EXIT, with the correct rc.
cleanup() {
  local rc=$?
  if [[ $MAINT_ENABLED -eq 1 && $rc -ne 0 ]]; then
    echo "ERROR: $0 exited with rc=$rc while $N was in HA maintenance." >&2
    echo "Auto-disabling maintenance on $N to restore cluster operation." >&2
    ha-manager crm-command node-maintenance disable "$N" \
      || echo "WARNING: auto-disable failed; manual cleanup needed: ha-manager crm-command node-maintenance disable $N" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# HUP is the signal a backgrounded bash receives when its controlling
# ssh tears down — exactly what happens when an operator Ctrl-Cs the
# `reboot-node-rolling.sh` wrapper. Without an explicit HUP trap, bash
# exits with the default disposition (terminate without running EXIT)
# and the cleanup arm never fires; codex reviewer reproduced this
# during step-c's settle sleep. 129 = 128 + SIGHUP.
trap 'exit 129' HUP

# Read $N's qm list. On ssh+qm failure or awk failure, dies. On
# success, sets the global QM_NON_STOPPED_VMIDS to a (possibly empty)
# newline-separated list of VMIDs whose status is not 'stopped'. The
# caller MUST check QM_NON_STOPPED_VMIDS, never call this through
# $(...) which would suppress the die.
read_non_stopped_vmids() {
  local out rc filtered awk_rc
  # BatchMode=yes: never prompt for auth (suppresses agent prompts).
  # ConnectTimeout=10: don't wait the system default (~75s) if $N's
  # sshd is hung mid-drain. A real `qm list` returns in well under 1s,
  # so 10s is generous; if we hit the timeout, the node is unhealthy
  # and the drain loop's die-on-ssh-fail is the right outcome.
  out="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 root@"$N" "qm list" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    die "cannot read VM state on $N (ssh+qm rc=$rc): $out"
  fi
  # Capture awk rc separately. Without this, awk failure (binary
  # missing, parse error, etc.) under set -uo would silently produce
  # an empty result -- another fail-open variant of the same class
  # as the round-5/6/7 P1s. set -o pipefail does not help when the
  # pipeline is on the right-hand side of an assignment whose exit
  # status is then ignored.
  filtered="$(printf '%s\n' "$out" \
    | awk 'NR>1 && $3 != "stopped" {print $1}')"
  awk_rc=$?
  if [[ $awk_rc -ne 0 ]]; then
    die "VM-state filter (awk) failed on $N (rc=$awk_rc)"
  fi
  QM_NON_STOPPED_VMIDS="$filtered"
}

# Step 0 (pre-check): verify $N is reachable via ssh+qm BEFORE asking
# HA to do anything. See the 2026-05-16 T5b history entry at the top
# of this file for the race this avoids. read_non_stopped_vmids dies
# on ssh+qm or awk failure; MAINT_ENABLED is still 0 here, so the
# trap fires as a no-op and no migrations are queued. The pre-check's
# QM_NON_STOPPED_VMIDS value is discarded for hygiene -- step b's
# loop calls read_non_stopped_vmids unconditionally on each iteration
# and overwrites the global, so leaving a stale value here would be
# benign, but the unset prevents any future code path from
# accidentally consuming a pre-enable snapshot.
echo "Step 0: pre-checking $N is reachable via ssh+qm before enabling HA maintenance..."
read_non_stopped_vmids
unset QM_NON_STOPPED_VMIDS

# Step a: put <N> into HA maintenance. HA migrates managed VMs off
# and refuses new placements until maintenance is disabled. This
# handles the project's data-plane VMs (DNS, Vault, Pebble, Gatus,
# etc.) which all run under HA. (Non-HA running VMs do NOT migrate
# here -- see the precondition above.) MAINT_ENABLED is set BEFORE
# the call (see top-of-script comment) so the cleanup trap covers a
# partial-apply or signal during enable.
MAINT_ENABLED=1
ha-manager crm-command node-maintenance enable "$N" \
  || die "ha-manager enable failed on $N"

# Step b: wait until <N> has zero non-stopped VMs. The filter is
# "anything that isn't 'stopped'" -- catches running VMs (now
# migrating under HA) plus paused, suspended, prelaunch, and
# io-error states. The io-error case is what the 2026-05-03
# incident produced; rebooting on top of it would crash the
# zombie qemu against a hung pool. read_non_stopped_vmids dies
# on ssh+qm or awk failure (NOT silenced by $(...)); the script
# exits the loop AND the script.
while true; do
  read_non_stopped_vmids
  [[ -z "$QM_NON_STOPPED_VMIDS" ]] && break
  sleep 10
done

# Step c: reboot gracefully. corosync exits cleanly on systemd
# shutdown so HA sees the node leave normally (no fence event).
# ssh may tear down before reply, so a non-zero rc here is not
# fatal -- step d's poll for SSH+quorum is the real gate. The
# 30s settle before polling matches Step 1.5 in rebuild-
# cluster.sh and avoids racing against still-up sshd.
ssh -n -o BatchMode=yes -o ConnectTimeout=10 root@"$N" reboot 2>/dev/null || true
sleep 30

# Step d: wait for SSH and quorum to come back. 10-min ceiling
# matches Step 1.5 in rebuild-cluster.sh.
waited=0
until ssh -n -o BatchMode=yes -o ConnectTimeout=5 root@"$N" \
      "pvecm status | grep -q 'Quorate: *Yes'" 2>/dev/null; do
  sleep 10
  waited=$((waited + 10))
  [[ $waited -ge 600 ]] && die "$N did not return / quorate within 10 minutes"
done

# Step e: disable maintenance. If this call dies, the cleanup trap
# still fires and re-attempts disable -- but since the die path here
# ALREADY includes the manual-cleanup hint, the trap's auto-disable
# is the safety net for the same condition. Clearing MAINT_ENABLED
# and detaching the traps happens only AFTER disable succeeds, so
# the post-success footer below doesn't carry a stale hint and the
# EXIT trap on normal exit is a no-op.
ha-manager crm-command node-maintenance disable "$N" \
  || die "ha-manager disable failed on $N (manual cleanup needed: ha-manager crm-command node-maintenance disable $N)"
MAINT_ENABLED=0
trap - EXIT INT TERM

echo
echo "Node $N has been rebooted and re-joined the cluster."
echo "Next: from your operator workstation, run"
echo "    framework/scripts/rebalance-cluster.sh"
echo "to migrate VMs back to their intended placements (config.yaml's"
echo "vms.<n>.node), then re-run the original rebuild-cluster.sh or"
echo "configure-node-kernel.sh --all -- both are idempotent."
# MAINT_SH_TEMPLATE_END -- DO NOT REMOVE: anchor for tests/test_rolling_reboot_node.sh
