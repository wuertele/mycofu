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
# Procedure (must be invoked as:
#   bash rolling-reboot-node-inner.sh <N> <OTHER> <pool> <lib-path> <name=ip> [<name=ip> ...]
# ):
#   <N>        Proxmox node to reboot.
#   <OTHER>    Surviving Proxmox node this script is running on.
#   <pool>     ZFS storage pool, passed opaquely by the workstation wrapper.
#   <lib-path> Absolute on-node path to the SCP'd cidata guard library.
#   <name=ip>  Full node inventory, at least two entries, containing
#              both <N> and <OTHER>. Names and IPv4 addresses are
#              validated before any HA state is touched.
#
#   0. Pre-check ssh+qm reachability to <N>, while MAINT_ENABLED=0.
#   a0. Before HA maintenance, read HA state locally, guard every VM
#       owned by <N> across every non-owner node, relocate ballooned
#       started VMs to <OTHER>, and verify those VMIDs leave <N>'s
#       qm list and are HA-started on a node other than <N>. The verify
#       wait is bounded: 600s by default, or MYCOFU_A0_RELOCATE_TIMEOUT=<seconds>.
#   a. ha-manager crm-command node-maintenance enable <N>
#   b. Drain wait: poll `qm list` on <N> until no VM is in a non-stopped
#      state. Non-stopped includes running, paused, suspended,
#      prelaunch, and io-error.
#   c. ssh root@<N> reboot
#   d. Poll SSH+quorum on <N> until back, 10-min cap.
#   z. Immediately before disabling maintenance, guard the failback
#      destination <N> for every VMID step a0 saw on <N>. If the guard
#      cannot prove <N> is safe, fail closed and deliberately do NOT
#      auto-disable maintenance.
#   e. ha-manager crm-command node-maintenance disable <N>
#
# Safety contract:
#   - `set -uo pipefail` (NOT -e; see comment block at top of script body).
#   - Every external command's exit code is checked explicitly.
#   - The cidata guard library is sourced fail-closed before HA state
#     changes. A missing or unsourceable lib aborts the reboot.
#   - The cleanup trap auto-disables HA maintenance on ANY non-zero
#     exit (die from step b/c/d/e, Ctrl-C, SIGTERM), preventing the
#     2026-05-14 incident pattern: a step-b ssh failure that left
#     pve02 in HA maintenance for 12 minutes / ~30 aborted migrations.
#     Step z is the deliberate exception: on failback-guard failure,
#     auto-disabling maintenance would trigger exactly the unguarded
#     failback this script is trying to prevent. That refusal exits
#     with STEP_Z_REFUSAL_RC so the workstation wrapper can print the
#     longer remediation instead of generic cleanup advice.
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

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
  printf '%s\n' \
    "Usage: bash rolling-reboot-node-inner.sh <N> <OTHER> <pool> <lib-path> <name=ip> [<name=ip> ...]" \
    "" \
    "  <N>        Proxmox node to reboot." \
    "  <OTHER>    Surviving Proxmox node this script is running on." \
    "  <pool>     ZFS storage pool, passed opaquely by the workstation wrapper." \
    "  <lib-path> Absolute on-node path to the SCP'd cidata-guard.sh." \
    "  <name=ip>  Full node inventory. At least two entries, and it must" \
    "             include both <N> and <OTHER>."
}

HOSTNAME_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
IPV4_REGEX='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'

validate_hostname() {
  local what="$1" name="$2"
  if [[ ! "$name" =~ $HOSTNAME_REGEX ]]; then
    die "$what '$name' does not match strict hostname regex ${HOSTNAME_REGEX}. Refusing to proceed (shell-injection guard)."
  fi
}

validate_ipv4() {
  local what="$1" ip="$2"
  if [[ ! "$ip" =~ $IPV4_REGEX ]]; then
    die "$what '$ip' does not match strict IPv4 regex. Refusing to proceed (shell-injection guard)."
  fi
}

if [[ $# -lt 6 ]]; then
  usage >&2
  exit 1
fi

N="$1"
OTHER="$2"
POOL="$3"
LIB="$4"
shift 4

validate_hostname "<N>" "$N"
validate_hostname "<OTHER>" "$OTHER"
[[ -n "$POOL" ]] || die "<pool> must not be empty"
[[ "$LIB" == /* ]] || die "<lib-path> must be absolute: $LIB"

# Validate args before touching HA state. A same-node migrate would
# be a long-running fail-closed run via qm migrate's own rejection,
# but it's clearer to die early.
[[ "$N" != "$OTHER" ]] || die "<N> and <other-node> must be different nodes"

if [[ $# -lt 2 ]]; then
  die "node inventory must contain at least two <name=ip> entries"
fi

INVENTORY_NAMES=()
INVENTORY_IPS=()
INVENTORY_LOOKUP_IP=""

inventory_ip_for_name() {
  local search="$1" i
  INVENTORY_LOOKUP_IP=""
  for ((i = 0; i < ${#INVENTORY_NAMES[@]}; i++)); do
    if [[ "${INVENTORY_NAMES[$i]}" == "$search" ]]; then
      INVENTORY_LOOKUP_IP="${INVENTORY_IPS[$i]}"
      return 0
    fi
  done
  return 1
}

for entry in "$@"; do
  if [[ "$entry" != *=* ]]; then
    die "invalid inventory entry '$entry'; expected <name=ip>"
  fi
  name="${entry%%=*}"
  ip="${entry#*=}"
  [[ -n "$name" && -n "$ip" ]] || die "invalid inventory entry '$entry'; expected non-empty <name=ip>"
  validate_hostname "inventory node name" "$name"
  validate_ipv4 "inventory IPv4 for $name" "$ip"
  if inventory_ip_for_name "$name"; then
    die "duplicate inventory entry for node '$name'"
  fi
  INVENTORY_NAMES+=("$name")
  INVENTORY_IPS+=("$ip")
done

inventory_ip_for_name "$N" || die "node inventory does not contain <N> '$N'"
inventory_ip_for_name "$OTHER" || die "node inventory does not contain <OTHER> '$OTHER'"

TARGET_FOR_NODE=""
set_target_for_node() {
  local name="$1"
  TARGET_FOR_NODE=""
  if [[ "$name" == "$OTHER" ]]; then
    TARGET_FOR_NODE="local"
    return 0
  fi
  if ! inventory_ip_for_name "$name"; then
    die "unknown node '$name' in inventory"
  fi
  TARGET_FOR_NODE="root@${INVENTORY_LOOKUP_IP}"
}

target_for_node() {
  set_target_for_node "$1"
  printf '%s\n' "$TARGET_FOR_NODE"
}

CIDATA_GUARD_DESTS=()
for name in "${INVENTORY_NAMES[@]}"; do
  set_target_for_node "$name"
  CIDATA_GUARD_DESTS+=("${name}=${TARGET_FOR_NODE}")
done

if [[ ! -f "$LIB" ]]; then
  die "cidata guard library not found at $LIB; refusing rolling reboot unguarded (fail-closed)"
fi
# shellcheck source=/dev/null
source "$LIB" || die "failed to source cidata guard library at $LIB (fail-closed)"

# A stale-but-valid lib still defines every function, so a function-presence check alone
# cannot catch it. Pin the minimum contract version too.
REQUIRED_CIDATA_GUARD_LIB_VERSION=3
if [[ ! "${CIDATA_GUARD_LIB_VERSION:-}" =~ ^[0-9]+$ ]] \
   || [[ "$CIDATA_GUARD_LIB_VERSION" -lt "$REQUIRED_CIDATA_GUARD_LIB_VERSION" ]]; then
  die "cidata guard library at $LIB is version '${CIDATA_GUARD_LIB_VERSION:-unset}'; this script requires >= ${REQUIRED_CIDATA_GUARD_LIB_VERSION} (fail-closed)"
fi

for required_fn in cidata_guard_node_change cidata_ha_service_node cidata_ha_service_state vm_is_ballooned; do
  if ! declare -F "$required_fn" >/dev/null; then
    die "cidata guard library at $LIB does not define $required_fn (fail-closed)"
  fi
done

A0_RELOCATE_TIMEOUT_RAW="${MYCOFU_A0_RELOCATE_TIMEOUT:-600}"
if [[ ! "$A0_RELOCATE_TIMEOUT_RAW" =~ ^[0-9]+$ ]]; then
  die "MYCOFU_A0_RELOCATE_TIMEOUT must be a non-negative integer number of seconds"
fi
A0_RELOCATE_TIMEOUT=$((10#$A0_RELOCATE_TIMEOUT_RAW))

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
STEP_Z_REFUSAL_RC=3

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

# Read every VMID present in $N's local qm list. This is separate from
# read_non_stopped_vmids because Step a0 must prove relocated VMs are
# gone from the node entirely, not merely stopped there.
read_node_vmids() {
  local out rc filtered awk_rc
  out="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 root@"$N" "qm list" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    die "cannot read VM list on $N (ssh+qm rc=$rc): $out"
  fi
  filtered="$(printf '%s\n' "$out" \
    | awk 'NR>1 {print $1}')"
  awk_rc=$?
  if [[ $awk_rc -ne 0 ]]; then
    die "VMID filter (awk) failed on $N (rc=$awk_rc)"
  fi
  QM_NODE_VMIDS="$filtered"
}

vmid_in_list() {
  local needle="$1" list="$2" line
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done <<< "$list"
  return 1
}

A0_NODE_VMIDS=()
A0_RELOCATED_VMIDS=()

guard_vm_before_drain() {
  local vmid="$1"
  if ! cidata_guard_node_change "$vmid" "$N" local "$POOL" false "${CIDATA_GUARD_DESTS[@]}"; then
    die "cidata guard failed for vm:${vmid} before draining $N (fail-closed)"
  fi
}

verify_a0_relocated_vmids_gone() {
  local waited remaining_wait sleep_for sleep_rc vmid state owner
  local -a remaining

  if [[ ${#A0_RELOCATED_VMIDS[@]} -eq 0 ]]; then
    echo "Step a0: no ballooned started VMs required pre-maintenance relocate."
    return 0
  fi

  echo "Step a0: verifying relocated ballooned VMs left $N and HA-started elsewhere (timeout ${A0_RELOCATE_TIMEOUT}s)..."
  waited=0
  while [[ $waited -le $A0_RELOCATE_TIMEOUT ]]; do
    read_node_vmids

    remaining=()
    for vmid in "${A0_RELOCATED_VMIDS[@]}"; do
      state="$(cidata_ha_service_state local "$vmid")"
      owner="$(cidata_ha_service_node local "$vmid")"
      if [[ "$state" == "error" ]]; then
        die "vm:${vmid} entered HA error state after pre-maintenance relocate; run framework/scripts/realign-cidata.sh --dry-run --vmid ${vmid}; then framework/scripts/realign-cidata.sh --vmid ${vmid}"
      fi
      if [[ "$state" == "UNKNOWN" || "$owner" == "UNKNOWN" || -z "$owner" ]]; then
        die "cannot verify HA recovery for relocated vm:${vmid} (owner='${owner:-empty}', state='${state:-empty}'; fail-closed)"
      fi
      if vmid_in_list "$vmid" "$QM_NODE_VMIDS"; then
        remaining+=("${vmid}:still-on-${N}")
        continue
      fi
      if [[ "$state" == "started" && "$owner" != "$N" ]]; then
        continue
      fi
      remaining+=("${vmid}:${owner}/${state}")
    done

    if [[ ${#remaining[@]} -eq 0 ]]; then
      echo "  relocated ballooned VMs are gone from $N and HA-started off $N."
      return 0
    fi

    if [[ $waited -ge $A0_RELOCATE_TIMEOUT ]]; then
      die "relocated ballooned VM(s) did not reach HA-started off $N after ${A0_RELOCATE_TIMEOUT}s: ${remaining[*]}"
    fi

    remaining_wait=$((A0_RELOCATE_TIMEOUT - waited))
    sleep_for=$remaining_wait
    [[ $sleep_for -gt 10 ]] && sleep_for=10
    sleep "$sleep_for"
    sleep_rc=$?
    if [[ $sleep_rc -ne 0 ]]; then
      die "sleep failed during Step a0 relocate verification (rc=$sleep_rc)"
    fi
    waited=$((waited + sleep_for))
  done

  die "relocated ballooned VM verification loop ended unexpectedly (fail-closed)"
}

run_step_a0() {
  local ha_status rc line vmid owner_node state bal_rc saw_owned service_re owner_target
  service_re='^service[[:space:]]+vm:([0-9]+)[[:space:]]+\(([^,]+),[[:space:]]*([^)]+)\)'

  echo "Step a0: guarding HA drain from $N before enabling HA maintenance..."
  ha_status="$(ha-manager status 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    die "cannot read HA state before draining $N (ha-manager status rc=$rc): $ha_status"
  fi
  if [[ -z "$ha_status" ]]; then
    die "ha-manager status returned empty output before draining $N (fail-closed)"
  fi

  saw_owned=0
  while IFS= read -r line; do
    if [[ "$line" =~ $service_re ]]; then
      vmid="${BASH_REMATCH[1]}"
      owner_node="${BASH_REMATCH[2]}"
      state="${BASH_REMATCH[3]}"
      [[ "$owner_node" == "$N" ]] || continue

      saw_owned=1
      case "$state" in
        started)
          echo "  vm:${vmid} state=started: guarding all non-owner nodes before drain."
          A0_NODE_VMIDS+=("$vmid")
          guard_vm_before_drain "$vmid"

          set_target_for_node "$N"
          owner_target="$TARGET_FOR_NODE"
          vm_is_ballooned "$owner_target" "$vmid"
          bal_rc=$?
          case "$bal_rc" in
            0)
              echo "  vm:${vmid} is ballooned: relocating to $OTHER before maintenance."
              ha-manager crm-command relocate "vm:${vmid}" "$OTHER"
              rc=$?
              if [[ $rc -ne 0 ]]; then
                die "ha-manager relocate failed for vm:${vmid} to $OTHER (rc=$rc)"
              fi
              A0_RELOCATED_VMIDS+=("$vmid")
              ;;
            1)
              echo "  vm:${vmid} is fixed-memory: leaving it for HA maintenance drain."
              ;;
            2)
              die "cannot determine whether vm:${vmid} is ballooned; aborting rolling reboot (fail-closed)"
              ;;
            *)
              die "vm_is_ballooned returned unexpected rc=$bal_rc for vm:${vmid} (fail-closed)"
              ;;
          esac
          ;;
        stopped|disabled)
          echo "  vm:${vmid} state=${state}: guarding all non-owner nodes; no relocate or wait needed."
          A0_NODE_VMIDS+=("$vmid")
          guard_vm_before_drain "$vmid"
          ;;
        error)
          die "vm:${vmid} is in HA error state; run framework/scripts/realign-cidata.sh --dry-run --vmid ${vmid}; then framework/scripts/realign-cidata.sh --vmid ${vmid} before rolling reboot"
          ;;
        UNKNOWN|"")
          die "vm:${vmid} HA state is unreadable; aborting rolling reboot (fail-closed)"
          ;;
        *)
          die "vm:${vmid} HA state '${state}' is transient or unsupported; aborting rolling reboot (fail-closed)"
          ;;
      esac
    elif [[ "$line" == service[[:space:]]vm:* ]]; then
      die "cannot parse HA service line before draining $N: $line"
    fi
  done <<< "$ha_status"

  if [[ $saw_owned -eq 0 ]]; then
    echo "  no HA services are currently owned by $N."
  fi

  verify_a0_relocated_vmids_gone
}

# Step z failure deliberately suppresses the blanket cleanup trap's
# auto-disable behavior. Disabling maintenance is exactly the unguarded
# failback leg this guard exists to prevent. The stuck maintenance state
# is visible as a WARN in validate.sh and blocks rebalance-cluster.sh,
# while a minted rename-victim silently freezes cidata content and can
# go unnoticed until a later HA restart. Recovery is not a blanket
# disable: inspect cidata orphans, repair any victim, then disable
# maintenance only after the failback destination is safe.
step_z_fail_closed() {
  local vmid="$1" reason="$2"
  MAINT_ENABLED=0
  echo "ERROR: Step z failback guard failed for vm:${vmid}: ${reason}" >&2
  echo "Refusing to disable HA maintenance on $N (fail-closed)." >&2
  echo "Remediation:" >&2
  echo "  1. framework/scripts/cleanup-orphan-cidata.sh --dry-run" >&2
  echo "  2. If a victim already exists: framework/scripts/realign-cidata.sh --dry-run --vmid ${vmid}" >&2
  echo "  3. Once resolved: ha-manager crm-command node-maintenance disable ${N}" >&2
  echo "ERROR: HA maintenance remains enabled on $N by design until the failback destination is safe" >&2
  exit "$STEP_Z_REFUSAL_RC"
}

run_step_z() {
  local vmid owner rc failback_target failback_dest

  echo "Step z: guarding HA failback to $N before disabling HA maintenance..."
  if [[ ${#A0_NODE_VMIDS[@]} -eq 0 ]]; then
    echo "  no HA services were seen on $N in Step a0; no failback guard needed."
    return 0
  fi

  set_target_for_node "$N"
  failback_target="$TARGET_FOR_NODE"
  failback_dest="${N}=${failback_target}"

  for vmid in "${A0_NODE_VMIDS[@]}"; do
    echo "  vm:${vmid}: guarding failback destination $N."
    owner="$(cidata_ha_service_node local "$vmid")" && rc=0 || rc=$?
    if [[ $rc -ne 0 ]]; then
      step_z_fail_closed "$vmid" "cannot read HA owner (rc=$rc)"
    fi
    if [[ -z "$owner" || "$owner" == "UNKNOWN" ]]; then
      step_z_fail_closed "$vmid" "HA owner is '${owner:-empty}'"
    fi
    if ! cidata_guard_node_change "$vmid" "$owner" local "$POOL" false "$failback_dest"; then
      step_z_fail_closed "$vmid" "cidata guard could not prove $N safe"
    fi
  done
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

# Step a0: guard the HA drain before asking PVE to queue any
# maintenance migrations. MAINT_ENABLED is still 0 here, so any die in
# the guard, HA-state table, balloon predicate, relocate, or bounded
# verify wait queues no maintenance migrations and the cleanup trap is
# a no-op. Preserve this ordering.
run_step_a0

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

# Step z: guard the failback leg immediately before disabling
# maintenance. PVE's CRM will live-migrate drained VMs back to $N when
# failback is enabled; $N is the one destination Step a0 never sweeps.
run_step_z

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
echo "Next REQUIRED post-reboot step: from your operator workstation, run"
echo "    framework/scripts/rebalance-cluster.sh"
echo "to migrate VMs back to their intended placements (config.yaml's"
echo "vms.<n>.node). A ballooned VM relocated in Step a0 does not"
echo "auto-return. Then re-run the original rebuild-cluster.sh or"
echo "configure-node-kernel.sh --all -- both are idempotent."
# MAINT_SH_TEMPLATE_END -- DO NOT REMOVE: anchor for tests/test_rolling_reboot_node.sh
