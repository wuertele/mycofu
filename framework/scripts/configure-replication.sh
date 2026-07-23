#!/usr/bin/env bash
# configure-replication.sh — Configure Proxmox ZFS replication for VMs.
#
# Configures ZFS replication from each VM's home node to all other nodes.
# This enables Proxmox HA to restart a VM on a surviving node without
# re-importing the image — it uses the replicated zvol directly.
#
# For DNS VMs, zone data is Category 2 (pushed from Git). Replication is
# for HA restart speed, not data durability.
#
# Usage:
#   framework/scripts/configure-replication.sh <vm-name-pattern> [--park-status <file>] [--env <dev|prod>]
#
# Examples:
#   framework/scripts/configure-replication.sh "dns*"
#
# The script SSHes to the first Proxmox node to run pvesh commands.
# It is idempotent — existing replication jobs are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

usage() {
  cat <<EOF
Usage: $(basename "$0") <vm-name-pattern> [--park-status <file>] [--env <dev|prod>]

Configure Proxmox ZFS replication for VMs matching the given pattern.

Arguments:
  <vm-name-pattern>   Pattern to match VM names (e.g., "dns*", "vault*")

Options:
  --park-status <file>
                      Sprint 044 vdb park status artifact (accepted here;
                      selective cleanup is implemented in the replication phase)
  --env <dev|prod>    Scope policy-off pruning only (default: all)
  --help              Show this help message
EOF
}

VM_PATTERN=""
PARK_STATUS_FILE=""
ENV_SCOPE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --interval)
      echo "ERROR: --interval is removed; schedule is policy (see list-replicated-vmids.sh)" >&2
      exit 2
      ;;
    --park-status) PARK_STATUS_FILE="$2"; shift 2 ;;
    --env)
      [[ $# -ge 2 ]] || { echo "ERROR: --env requires dev or prod" >&2; usage >&2; exit 2; }
      ENV_SCOPE="$2"
      shift 2
      ;;
    -*) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -z "$VM_PATTERN" ]]; then
        VM_PATTERN="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2; usage >&2; exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$VM_PATTERN" ]]; then
  echo "ERROR: VM name pattern required." >&2
  usage >&2
  exit 2
fi

shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

csv_contains_vmid() {
  local csv="$1"
  local vmid="$2"
  [[ ",${csv}," == *",${vmid},"* ]]
}

adopted_vdb_volname_for_vmid() {
  local vmid="$1"

  if [[ -z "$PARK_STATUS_FILE" || ! -f "$PARK_STATUS_FILE" ]]; then
    return 0
  fi

  jq -r --argjson vmid "$vmid" '
    first(.entries[]? | select(.vmid == $vmid and .status == "adopted")) | .volname // empty
  ' "$PARK_STATUS_FILE"
}

destroy_vm_zvols_on_target() {
  local target_ip="$1"
  local vmid="$2"
  local preserve_volname

  preserve_volname="$(adopted_vdb_volname_for_vmid "$vmid")"
  # #596: bound ssh connect to 5s so a hung/unreachable target does not
  # stall the whole cleanup script for the OS-default TCP connect
  # timeout (~2 minutes on many systems). Matches the wait-block pattern.
  ssh -n -o ConnectTimeout=5 "root@${target_ip}" "
    PRESERVE_VDB=$(shell_quote "$preserve_volname")
    for zvol in \$(zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep 'vm-${vmid}-'); do
      base=\${zvol##*/}
      if [ -n \"\$PRESERVE_VDB\" ] && [ \"\$base\" = \"\$PRESERVE_VDB\" ]; then
        echo \"    Preserving adopted vdb replica: \$zvol\"
        continue
      fi
      echo \"    Destroying orphan zvol: \$zvol\"
      zfs destroy -r \"\$zvol\" 2>&1 || true
    done
  " 2>/dev/null || true
}

warn_parked_vdbs() {
  local node_name node_ip rows zvol vmid warned=0

  echo "==> Checking for parked vdb zvols..."
  for node_name in $NODE_NAMES; do
    node_ip=$(yq -r ".nodes[] | select(.name == \"${node_name}\") | .mgmt_ip" "$CONFIG")
    [[ -z "$node_ip" || "$node_ip" == "null" ]] && continue
    rows=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${node_ip}" \
      "zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep '/mycofu-park-[0-9][0-9]*-vdb$' || true" 2>/dev/null || true)
    while IFS= read -r zvol; do
      [[ -z "$zvol" ]] && continue
      vmid="$(sed -n 's|.*/mycofu-park-\([0-9][0-9]*\)-vdb$|\1|p' <<< "$zvol")"
      echo "  WARNING: parked vdb remains on ${node_name}: ${zvol}"
      echo "    Inspect/recover first: framework/scripts/parked-vdb.sh inspect ${vmid}"
      echo "    Release only after accepting freshness loss: framework/scripts/parked-vdb.sh release ${vmid}"
      warned=$((warned + 1))
    done <<< "$rows"
  done
  if [[ "$warned" -eq 0 ]]; then
    echo "  No parked vdb zvols found"
  fi
  echo ""
}

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 1
fi

HELPER="${SCRIPT_DIR}/list-replicated-vmids.sh"
CLEANUP_FILES=""
# shellcheck disable=SC2086
# Word-split on $CLEANUP_FILES is deliberate: rm needs individual paths,
# not one space-separated argument. See #626.
trap 'rm -f $CLEANUP_FILES' EXIT

# GLOBAL sets are always all-env regardless of --env. They drive create/keep,
# node artifact delivery, and the later validate conformance baseline.
# Cache the helper TSV projection once. Separate stderr from stdout so any
# informational WARNs the helper emits (e.g., the redundant-1m WARN on a
# backup:true VM carrying an explicit "1m" cadence) don't contaminate the
# parsed policy data. Preserve WARN visibility by echoing captured stderr
# to our own stderr.
HELPER_ERR=$(mktemp "${TMPDIR:-/tmp}/list-repl-vmids-err.XXXXXX"); CLEANUP_FILES="$CLEANUP_FILES $HELPER_ERR"
HELPER_TSV_CACHE=$(mktemp "${TMPDIR:-/tmp}/list-repl-vmids-tsv.XXXXXX"); CLEANUP_FILES="$CLEANUP_FILES $HELPER_TSV_CACHE"
if ! "${HELPER}" --format tsv --mode all all >"$HELPER_TSV_CACHE" 2>"$HELPER_ERR"; then
  echo "ERROR: helper failed for --mode all all: $(cat "$HELPER_ERR")" >&2
  exit 1
fi
[[ -s "$HELPER_ERR" ]] && cat "$HELPER_ERR" >&2

GLOBAL_POLICY_ON=$(awk -F'\t' '$4 == "true" {print $1}' "$HELPER_TSV_CACHE" | paste -sd, -)
GLOBAL_POLICY_OFF=$(awk -F'\t' '$4 == "false" {print $1}' "$HELPER_TSV_CACHE" | paste -sd, -)

# Fail-closed: an empty policy-on set from a working helper is corrupt config,
# not an instruction to prune everything.
if [[ -z "${GLOBAL_POLICY_ON// /}" ]]; then
  echo "ERROR: helper returned empty GLOBAL_POLICY_ON — refusing to run" >&2
  exit 1
fi

# PRUNE subset is the only set scoped by --env:
#   --env dev  => dev+shared policy-off subset
#   --env prod => prod policy-off subset
#   no --env   => all policy-off
if [[ -z "$ENV_SCOPE" ]]; then
  PRUNE_POLICY_OFF="$GLOBAL_POLICY_OFF"
elif [[ "$ENV_SCOPE" == "dev" ]]; then
  PRUNE_POLICY_OFF=$(awk -F'\t' '$4 == "false" && ($3 == "dev" || $3 == "shared") {print $1}' \
    "$HELPER_TSV_CACHE" | paste -sd, -) || exit 1
elif [[ "$ENV_SCOPE" == "prod" ]]; then
  PRUNE_POLICY_OFF=$(awk -F'\t' '$4 == "false" && $3 == "prod" {print $1}' \
    "$HELPER_TSV_CACHE" | paste -sd, -) || exit 1
else
  echo "ERROR: --env must be dev, prod, or unset" >&2
  exit 2
fi

helper_schedule_for() { awk -F'\t' -v vmid="$1" '$1 == vmid {print $7; exit}' "$HELPER_TSV_CACHE"; }
helper_seed_class_for() { awk -F'\t' -v vmid="$1" '$1 == vmid {print $9; exit}' "$HELPER_TSV_CACHE"; }

SCHEDULE_POLICY_SUMMARY=$(awk -F'\t' '$4 == "true" && $7 != "" {count[$7]++}
  END {for (schedule in count) print schedule "=" count[schedule]}' "$HELPER_TSV_CACHE" \
  | sort | paste -sd, -)

# Read node info from config
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
NODE_NAMES=$(yq -r '.nodes[].name' "$CONFIG")
STORAGE_POOL=$(yq -r '.proxmox.storage_pool' "$CONFIG")

echo "VM pattern: ${VM_PATTERN}"
echo "Schedule policy: per-VM helper pvesr_schedule (${SCHEDULE_POLICY_SUMMARY:-none})"
if [[ -n "$PARK_STATUS_FILE" ]]; then
  echo "Park status: ${PARK_STATUS_FILE}"
fi
if [[ -n "$ENV_SCOPE" ]]; then
  echo "Env scope:   ${ENV_SCOPE}"
fi
echo ""

# Get all VMs matching the pattern and their details
echo "==> Finding VMs matching '${VM_PATTERN}'..."
VM_DATA=$(ssh -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null)

# Filter VMs by name pattern (convert glob to grep-compatible regex)
GREP_PATTERN=$(echo "$VM_PATTERN" | sed 's/\*/\.\*/g')
MATCHING_VMS=$(echo "$VM_DATA" | jq -r --arg pat "$GREP_PATTERN" \
  '.[] | select(.name | test($pat)) | "\(.vmid) \(.name) \(.node)"')

if [[ -z "$MATCHING_VMS" ]]; then
  echo "No VMs found matching '${VM_PATTERN}'"
  exit 0
fi

echo "Found VMs:"
echo "$MATCHING_VMS" | while read -r VMID NAME NODE; do
  echo "  ${NAME} (VMID ${VMID}) on ${NODE}"
done
echo ""

# Get existing replication jobs
EXISTING_JOBS=$(ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/replication --output-format json" 2>/dev/null || echo "[]")

# --- Clean up stale/failed replication jobs AND orphan zvols ---
# Two cleanup scenarios after VM recreation:
# 1. Failed jobs: VM was recreated but replication jobs persist with fail_count > 0
#    (stale snapshots don't match the new disk). Fix: delete job, destroy zvols, recreate.
# 2. Orphan zvols: VM was destroyed (jobs auto-removed by Proxmox) then recreated.
#    Orphan zvols remain on target nodes with no corresponding job. Fix: destroy zvols
#    before creating new jobs (otherwise new jobs fail with "No common base snapshot").

echo "==> Checking for stale replication jobs..."
# Arm the CLEANUP_FILES trap BEFORE the first mktemp, and register each
# subsequent tempfile immediately on the same physical line as its
# mktemp. Rationale (#626):
#   - Arming the trap first means the trap fires with a valid (possibly
#     empty) $CLEANUP_FILES even if the very first mktemp is
#     followed by a fatal error before its register step runs.
#   - Same-line `mktemp; CLEANUP_FILES=...` doesn't guarantee atomicity
#     against every signal (bash still treats `;` as command
#     boundaries), but it eliminates the wider batched-append window
#     where several mktemps ran before any of them was registered, and
#     it also prevents a future maintainer from inserting real work
#     between the mktemp and the register step.
# The residual `set -e` risk is bounded: mktemp rarely fails, and if it
# does the failure is on the mktemp step itself — no file was created,
# nothing to leak.
STALE_STATUS=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $STALE_STATUS"

# Get list of matching VMIDs for filtering
MATCHING_VMIDS=$(echo "$MATCHING_VMS" | awk '{print $1}')

# pvesr status only shows jobs sourced from the local node.
# Check each unique source node for failed jobs.
SOURCE_NODES=$(echo "$MATCHING_VMS" | awk '{print $3}' | sort -u)
for SRC_NODE in $SOURCE_NODES; do
  SRC_IP=$(yq -r ".nodes[] | select(.name == \"${SRC_NODE}\") | .mgmt_ip" "$CONFIG")
  [[ -z "$SRC_IP" || "$SRC_IP" == "null" ]] && continue

  # #595: capture ssh output into a variable BEFORE iterating, rather than
  # feeding the loop through a pipe. Under `set -euo pipefail`, a failing
  # ssh (unreachable node, auth failure, transient network drop) makes
  # `ssh ... | while read ...` return non-zero, and pipefail kills the
  # script. That defeats the exact use case this script exists for —
  # cleaning up replication state on a cluster where a node has just
  # died.
  #
  # Adversarial-review refinement (codex P2 / claude-fork P2.1): capture
  # ssh output and exit code separately. A `pvesr_status=$(ssh ... || true)`
  # form conflates two failure modes we want to disambiguate:
  #   1. Partial stdout, then non-zero exit — the retained partial rows
  #      would be parsed and could hide missing rows behind a "no stale
  #      found" result.
  #   2. Silent skip on unreachable node with no operator-visible signal.
  # `if !` captures the exit code into the `if` conditional (bypassing
  # `set -e`); a non-zero rc discards any partial output and prints a
  # WARN naming the source node, then continues to the next source.
  # A truly unreachable node's stale jobs remain visible via the
  # cluster-wide replication list (used by the orphan-zvol phase below)
  # and via the wait-loop's UNREACHABLE_NODES accounting.
  if ! pvesr_status=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${SRC_IP}" "pvesr status 2>/dev/null" 2>/dev/null); then
    echo "  WARN: could not read pvesr status from ${SRC_NODE} (${SRC_IP}) — stale jobs sourced there will not be detected this run" >&2
    continue
  fi
  if [[ -z "$pvesr_status" ]]; then
    # ssh returned rc=0 but produced no output — the source node is
    # reachable and simply has no replication jobs. Nothing to check.
    continue
  fi
  while IFS= read -r line; do
    [[ "$line" =~ ^JobID ]] && continue
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[0-9]+-[0-9]+ ]] || continue

    job_id=$(echo "$line" | awk '{print $1}')
    last_sync=$(echo "$line" | awk '{print $4}')
    fail_count=$(echo "$line" | awk '{print $7}')
    vmid=$(echo "$job_id" | cut -d- -f1)

    # Only clean jobs for VMs we're managing
    if ! echo "$MATCHING_VMIDS" | grep -qw "$vmid"; then
      continue
    fi

    # #536: a job with LastSync="-" (never run) but FailCount=0 was previously
    # missed here. The create phase later SKIPs it as "already exists", so
    # CREATED stays 0 and the #502 initial-sync wait block never runs — a
    # presence-based false-pass shape. Fix: treat a never-run job as stale so
    # it is torn down and recreated; the recreate then feeds the wait block.
    #
    # #594: fail-closed on a non-numeric FailCount. The previous predicate
    # `[[ "${fail_count:-0}" -gt 0 ]]` treated whatever came out of column 7
    # as an integer under `set -euo pipefail`. If a `pvesr` row ever emits
    # a non-numeric bareword in column 7 (schema drift, a locale-changed
    # header row that slipped past the `^JobID` and job-id regex filters,
    # a truncated pipe), bash arithmetic context tries to resolve the word
    # as a variable name. Under `set -u` that aborts the whole script with
    # `bash: <word>: unbound variable`. Guard with a numeric-shape test and
    # explicitly mark a non-numeric FailCount as stale (same fail-closed
    # convention the wait-loop uses at the `r_fail` check below).
    #
    # Adversarial-review refinement (codex P2 / claude-fork-2 P2-1): the
    # nonzero test uses `! =~ ^0+$` string-match, not `[[ -gt 0 ]]`
    # arithmetic. Reason: after the shape guard passes `^[0-9]+$`, a
    # leading-zero string like `08`/`09` still crashes bash arithmetic
    # (invalid octal) and — worse — that crash inside `[[ ]]` returns
    # non-zero, so the whole `||` clause falls through and a genuinely
    # failing job (FailCount=8) is misclassified as OK. The string-match
    # form has no arithmetic and correctly stales any non-all-zero value.
    #
    # PVE semantics: `pvesr status` populates the LastSync column on
    # successful sync completion, not on scheduler pickup — the same reading
    # `repl-health.sh:291` uses when it treats LastSync="-" as unambiguously
    # stale. A run of configure-replication.sh that happens to coincide with
    # an in-progress first sync therefore tears that sync down and starts a
    # fresh one; data is not at risk (no committed vdb writes are lost —
    # recreate+wait absorbs the redo), but this is operational disruption in
    # a narrow window. Current invocation sites (a future reader debugging a
    # mid-first-sync tear-down should not have to re-derive this from
    # scratch — #622):
    #   1. safe-apply.sh Phase 2 (post-Phase-2 convergence, run_post_success),
    #      after tofu apply completes — the dominant deploy path.
    #   2. converge-lib.sh (invoked by converge-cluster.sh, which is invoked
    #      by rebuild-cluster.sh) — control-plane rebuild path.
    #   3. validate.sh R2.6 replication health check — periodic reconvergence
    #      + validation runs, unrelated to a fresh tofu apply.
    #   4. Operator manual invocation (documented in OPERATIONS.md, CLAUDE.md).
    # (Update this list when adding a new caller so the race analysis
    # below stays honest.)
    # Sites 1 and 2 both run after a completed apply, so they never race an
    # in-progress first sync in practice. Site 3 runs during validation and
    # can plausibly coincide with a first sync in a narrow window (the run
    # will tear down the transient first sync and recreate). Site 4 is
    # operator-timed and inherits whichever race window is currently open.
    if [[ ! "${fail_count:-}" =~ ^[0-9]+$ ]] || [[ ! "$fail_count" =~ ^0+$ ]] || [[ "${last_sync:--}" == "-" ]]; then
      echo "$job_id" >> "$STALE_STATUS"
    fi
  done <<< "$pvesr_status"
done

CLEANED=0
if [[ -s "$STALE_STATUS" ]]; then
  echo "  Found stale replication jobs:"
  while IFS= read -r job_id; do
    vmid=$(echo "$job_id" | cut -d- -f1)

    # Look up the target node from the replication job metadata (not from the job ID).
    # Job IDs are opaque — the target node name is in the job's JSON, not derivable
    # from the numeric suffix.
    target_node=$(echo "$EXISTING_JOBS" | jq -r \
      --arg id "$job_id" '.[] | select(.id == $id) | .target' 2>/dev/null)
    if [[ -z "$target_node" || "$target_node" == "null" ]]; then
      echo "  WARNING: Cannot determine target node for job ${job_id} — skipping cleanup"
      continue
    fi

    echo "  CLEAN: ${job_id} (VM ${vmid} -> ${target_node})"

    # Delete the broken replication job
    ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
      "pvesh delete /cluster/replication/${job_id}" 2>&1 || true

    # Destroy orphaned zvols on the target node
    TARGET_IP=$(yq -r ".nodes[] | select(.name == \"${target_node}\") | .mgmt_ip" "$CONFIG")
    if [[ -n "$TARGET_IP" && "$TARGET_IP" != "null" ]]; then
      destroy_vm_zvols_on_target "$TARGET_IP" "$vmid"
    fi

    CLEANED=$((CLEANED + 1))
  done < "$STALE_STATUS"
  echo "  Cleaned ${CLEANED} stale jobs"
  # Proxmox removes replication jobs asynchronously — wait for removal to complete
  echo "  Waiting for background removal to finish..."
  for wait_i in $(seq 1 12); do
    sleep 5
    # Check if any of the deleted jobs still appear in the cluster replication list
    REMAINING=$(ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
      "pvesh get /cluster/replication --output-format json" 2>/dev/null || echo "[]")
    STILL_PRESENT=0
    while IFS= read -r del_job_id; do
      if echo "$REMAINING" | jq -e --arg id "$del_job_id" '.[] | select(.id == $id)' &>/dev/null; then
        STILL_PRESENT=$((STILL_PRESENT + 1))
      fi
    done < "$STALE_STATUS"
    if [[ "$STILL_PRESENT" -eq 0 ]]; then
      echo "  All stale jobs removed"
      break
    fi
    echo "  Still waiting... (${STILL_PRESENT} jobs remaining)"
  done
  echo ""
else
  echo "  No stale replication jobs found"
fi

# --- Clean orphan zvols (scenario 2: jobs removed but zvols remain) ---
# For each matching VM, check every non-source node for leftover zvols that
# have no corresponding replication job. These block new job creation.
echo "==> Checking for orphan zvols on target nodes..."
# Refresh jobs list after any stale cleanup above
EXISTING_JOBS=$(ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/replication --output-format json" 2>/dev/null || echo "[]")

# #626: single-line mktemp+append shape so a SIGINT or `set -e` cannot
# fire between the mktemp and the CLEANUP_FILES registration.
ORPHAN_STATUS=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $ORPHAN_STATUS"

echo "$MATCHING_VMS" | while read -r VMID NAME SOURCE_NODE; do
  for TARGET_NODE in $NODE_NAMES; do
    [[ "$TARGET_NODE" == "$SOURCE_NODE" ]] && continue

    TARGET_IP=$(yq -r ".nodes[] | select(.name == \"${TARGET_NODE}\") | .mgmt_ip" "$CONFIG")
    [[ -z "$TARGET_IP" || "$TARGET_IP" == "null" ]] && continue

    # Check if this VM has zvols on the target node
    TARGET_ZVOLS=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${TARGET_IP}" \
      "zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep 'vm-${VMID}-'" 2>/dev/null || true)
    [[ -z "$TARGET_ZVOLS" ]] && continue

    # Check if there's a healthy replication job for this VM -> target
    JOB_FOR_TARGET=$(echo "$EXISTING_JOBS" | jq -r \
      --argjson vmid "$VMID" --arg target "$TARGET_NODE" \
      '[.[] | select(.guest == $vmid and .target == $target)] | length')

    if [[ "$JOB_FOR_TARGET" -eq 0 ]]; then
      # Orphan zvols with no replication job — clean them
      echo "  ORPHAN: VM ${VMID} (${NAME}) has zvols on ${TARGET_NODE} with no replication job"
      destroy_vm_zvols_on_target "$TARGET_IP" "$VMID"
      echo "CLEANED" >> "$ORPHAN_STATUS"
    fi
  done
done

ORPHAN_CLEANED=0
if [[ -s "$ORPHAN_STATUS" ]]; then
  ORPHAN_CLEANED=$(wc -l < "$ORPHAN_STATUS" | tr -d ' ')
fi
echo "  Cleaned orphan zvols from ${ORPHAN_CLEANED} VM/node pairs"
echo ""

# --- Clean globally orphaned zvols (VMIDs that no longer exist anywhere) ---
# When a VM is destroyed and recreated with a new VMID, Proxmox auto-removes
# the replication jobs, but zvols for the old VMID remain on target nodes.
# The orphan cleanup above only checks VMs that currently exist. This phase
# scans ALL nodes for zvols belonging to VMIDs that don't match any running VM.
echo "==> Checking for globally orphaned zvols (destroyed VMIDs)..."
# Initialize GLOBAL_ORPHANS BEFORE the ALL_VMIDS guard so the summary echo
# at script end can reference it even when the WARNING branch fires. Under
# this script's `set -euo pipefail`, an unbound-variable expansion in the
# summary would abort the script exactly in the failure mode the guard was
# written to survive gracefully. See #615 / #255.
#
# WARNING-branch reachability (#625): with the ALL_VMIDS expression on
# this line alone, the WARNING branch is not reachable via normal control
# flow — an empty/null/invalid VM_DATA crashes the `jq` at MATCHING_VMS
# assignment under `set -euo pipefail` before this guard runs; a valid
# VM_DATA with entries has vmid fields (pvesh always emits them) and
# yields non-empty ALL_VMIDS. But this guard is NOT deletable dead code:
# it's the intended landing zone for #624's integer-filtering guards,
# which route pathological vmid content (e.g. `vmid: null` on a VM
# being destroyed mid-scan) into an empty ALL_VMIDS. Removing this branch would
# delete the fail-safe path that #624 relies on to avoid classifying
# every ZVOL_VMID as globally orphaned when the API returns transitional
# content. Per operator instruction, guards whose downstream design
# depends on their presence are not to be deleted blindly, even when
# temporarily unreachable in the current control flow.
GLOBAL_ORPHANS=0
# Multi-layer defense against pathological cluster API responses that
# would let the global-orphan sweep destroy zvols belonging to real VMs.
# See #624.
#
# The failure mode: the Proxmox cluster resources API can return a payload
# where at least one VM entry has `vmid: null` (a VM being destroyed
# mid-scan, or a schema surprise). Without any filter, `jq -r '.[].vmid'`
# emits the literal string `null`, `[[ -z "$ALL_VMIDS" ]]` accepts that as
# non-empty, the destruction branch runs, and the subsequent
# `grep -qw "$ZVOL_VMID"` membership tests never match any integer
# ZVOL_VMID against the literal string `null` — classifying every zvol
# on every node as globally orphaned. Blast radius: cluster-wide
# destruction.
#
# Naive fix (drop non-integer vmids at the source with jq's `numbers`
# builtin) closes the all-null case, but LEAKS the mixed case: with
# `[{"vmid":100},{"vmid":null},{"vmid":200}]` the naive filter yields
# ALL_VMIDS="100\n200". The guard does not fire. The membership check
# then classifies the zvol for the VM with the null vmid as globally
# orphaned and destroys it. That is not the original blast radius, but
# it is still real-VM destruction driven by a bad inventory. For
# destruction safety, any inventory with even one invalid vmid MUST be
# treated as untrusted — the whole payload routes into the WARNING
# branch rather than proceeding with a partial view.
#
# Layer 0 (partial-inventory poison): if VM_DATA is not an array, or
# any entry has a non-integer vmid (null, missing, string, strict
# float, boolean), set ALL_VMIDS to empty so the WARNING branch fires.
# The jq predicate:
#   - `type == "array"` self-guard so Layer 0 does not depend on the
#     upstream MATCHING_VMS iteration to have already crashed on a
#     non-array top-level VM_DATA;
#   - `all(.[]?.vmid; (type == "number") and (. == floor))` requires
#     every entry's vmid to be a JSON number AND equal to its floor.
#     This rejects strict floats (100.5) but ADMITS float-integer
#     forms (100.0) — jq's number type covers both. The float-integer
#     case is stripped by Layer 2's decimal-integer regex, so the
#     layered defense still holds.
# Under `set -euo pipefail`, `jq -e` returns non-zero if the predicate
# is false, and `2>/dev/null` catches jq stderr. The `if !` structure
# treats non-zero jq exit (including a jq parse failure) as fail-closed
# "cannot trust inventory". See #624.
if ! echo "$VM_DATA" \
     | jq -e '(type == "array") and all(.[]?.vmid; (type == "number") and (. == floor))' \
       >/dev/null 2>&1; then
  ALL_VMIDS=""
else
  # Layer 1 (source): jq's `numbers` builtin drops any non-numeric vmid
  # value. Redundant after Layer 0 but stays as defense in depth in
  # case Layer 0 is later refactored or bypassed. Note: jq's `numbers`
  # accepts floats; Layer 2's grep is what enforces DECIMAL INTEGER
  # shape on the shell string.
  ALL_VMIDS=$(echo "$VM_DATA" | jq -r '.[].vmid | numbers' | sort -u)
fi
# Layer 2 (guard, defense in depth): a decimal-integer regex re-filter
# with `|| true`. If Layers 0/1 are ever weakened to admit non-integer
# noise (float, string, "null"), this pass strips it. `|| true` covers
# the entirely-empty result under `set -euo pipefail` (grep with no
# matches exits 1). See #624.
ALL_VMIDS=$(echo "$ALL_VMIDS" | grep -E '^[0-9]+$' || true)
if [[ -z "$ALL_VMIDS" ]]; then
  echo "  WARNING: Could not enumerate VMs from cluster API — skipping global orphan cleanup"
  echo "  (This prevents accidental destruction of all zvols when the API is temporarily unreachable)"
else

for NODE_NAME_ITER in $NODE_NAMES; do
  NODE_IP_ITER=$(yq -r ".nodes[] | select(.name == \"${NODE_NAME_ITER}\") | .mgmt_ip" "$CONFIG")
  [[ -z "$NODE_IP_ITER" || "$NODE_IP_ITER" == "null" ]] && continue

  # Get all VM zvol VMIDs on this node
  ZVOL_VMIDS=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${NODE_IP_ITER}" \
    "zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep -oP 'vm-\K[0-9]+' | sort -u" \
    2>/dev/null || true)
  [[ -z "$ZVOL_VMIDS" ]] && continue

  for ZVOL_VMID in $ZVOL_VMIDS; do
    # Skip if this VMID belongs to a running VM
    if echo "$ALL_VMIDS" | grep -qw "$ZVOL_VMID"; then
      continue
    fi
    # Skip if there's a replication job for this VMID (shouldn't happen, but be safe)
    if echo "$EXISTING_JOBS" | jq -e --argjson vmid "$ZVOL_VMID" '.[] | select(.guest == $vmid)' &>/dev/null; then
      continue
    fi
    echo "  GLOBAL ORPHAN: VMID ${ZVOL_VMID} zvols on ${NODE_NAME_ITER} (VM no longer exists)"
    destroy_vm_zvols_on_target "$NODE_IP_ITER" "$ZVOL_VMID"
    GLOBAL_ORPHANS=$((GLOBAL_ORPHANS + 1))
  done
done
echo "  Cleaned ${GLOBAL_ORPHANS} globally orphaned VMID sets"
fi  # end ALL_VMIDS guard
echo ""

warn_parked_vdbs

SCHEDULE_RECONCILED=0
# In-place schedule reconcile — for existing jobs whose live schedule drifted
# from the policy schedule from the helper tsv.
# NEVER delete+create (that would orphan the replica and force a full re-seed).
if [[ -n "$EXISTING_JOBS" ]]; then
  while IFS= read -r job_id; do
    [[ -z "$job_id" ]] && continue
    vmid_of_job="${job_id%-*}"
    live_sched=$(echo "$EXISTING_JOBS" | jq -r --arg id "$job_id" '.[] | select(.id == $id) | .schedule')
    policy_sched=$(helper_schedule_for "$vmid_of_job")
    if [[ -n "$policy_sched" && "$live_sched" != "$policy_sched" ]]; then
      echo "  RECONCILE: ${job_id} schedule '${live_sched}' -> '${policy_sched}'"
      if ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
        "pvesh set /cluster/replication/${job_id} --schedule $(shell_quote "$policy_sched")"; then
        SCHEDULE_RECONCILED=$((SCHEDULE_RECONCILED + 1))
      else
        echo "ERROR: failed to reconcile schedule for ${job_id}" >&2
        exit 1
      fi
    fi
  done < <(echo "$EXISTING_JOBS" | jq -r '.[].id')
fi

# --- Create/verify replication jobs ---
# #626: register each tempfile in CLEANUP_FILES immediately after mktemp
# (single-line shape), so a SIGINT or `set -e` firing between the mktemp
# and a later batched append does not leak the un-registered tempfile in
# /tmp.
STATUS_FILE=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $STATUS_FILE"
ALLOCATED_IDS_FILE=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $ALLOCATED_IDS_FILE"
# CREATED_IDS_FILE holds all successful creates for audit/debug. The wait
# partitions those creates into strict and async tempfiles by helper-emitted
# seed_wait_class.
CREATED_IDS_FILE=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $CREATED_IDS_FILE"
CREATED_STRICT_IDS_FILE=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $CREATED_STRICT_IDS_FILE"
CREATED_ASYNC_META_FILE=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $CREATED_ASYNC_META_FILE"

echo "==> Configuring replication..."
echo "$MATCHING_VMS" | while read -r VMID NAME SOURCE_NODE; do
  VM_SCHEDULE=""
  SEED_WAIT_CLASS=""
  if csv_contains_vmid "$GLOBAL_POLICY_ON" "$VMID"; then
    if ! VM_SCHEDULE="$(helper_schedule_for "$VMID")" || [[ -z "$VM_SCHEDULE" ]]; then
      echo "  ERROR: ${NAME} (${VMID}) missing pvesr_schedule in helper TSV" >&2
      echo "ERROR" >> "$STATUS_FILE"
      continue
    fi
    if ! SEED_WAIT_CLASS="$(helper_seed_class_for "$VMID")" || [[ -z "$SEED_WAIT_CLASS" ]]; then
      echo "  ERROR: ${NAME} (${VMID}) missing seed_wait_class in helper TSV" >&2
      echo "ERROR" >> "$STATUS_FILE"
      continue
    fi
  elif csv_contains_vmid "$GLOBAL_POLICY_OFF" "$VMID"; then
    echo "  POLICY-OFF: ${NAME} (${VMID}) → no replication job"
    echo "SKIPPED" >> "$STATUS_FILE"
    continue
  else
    echo "  WARNING: ${NAME} (${VMID}) unknown to policy classifier — replicating conservatively" >&2
    VM_SCHEDULE="*/1"
    SEED_WAIT_CLASS="strict"
  fi

  # Replicate to every node except the source node
  for TARGET_NODE in $NODE_NAMES; do
    if [[ "$TARGET_NODE" == "$SOURCE_NODE" ]]; then
      continue
    fi

    # Check if replication job already exists for this VM -> target pair
    JOB_EXISTS=$(echo "$EXISTING_JOBS" | jq -r \
      --argjson vmid "$VMID" --arg target "$TARGET_NODE" \
      '[.[] | select(.guest == $vmid and .target == $target)] | length')

    if [[ "$JOB_EXISTS" -gt 0 ]]; then
      echo "  SKIP: ${NAME} (${VMID}) -> ${TARGET_NODE} (already exists)"
      echo "SKIPPED" >> "$STATUS_FILE"
      continue
    fi

    # Find next available job number for this VMID (format: VMID-N, N=0..9)
    # Check both the cluster state AND IDs allocated in this run
    JOB_NUM=0
    for n in $(seq 0 9); do
      candidate="${VMID}-${n}"
      if ! echo "$EXISTING_JOBS" | jq -e --arg id "$candidate" '.[] | select(.id == $id)' &>/dev/null \
         && ! grep -qw "$candidate" "$ALLOCATED_IDS_FILE" 2>/dev/null; then
        JOB_NUM=$n
        break
      fi
    done

    echo "  CREATE: ${NAME} (${VMID}) -> ${TARGET_NODE} (job ${VMID}-${JOB_NUM})"
    echo "${VMID}-${JOB_NUM}" >> "$ALLOCATED_IDS_FILE"
    # -n: prevent SSH from consuming loop stdin (see scripts/README.md)
    if ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
      "pvesh create /cluster/replication \
        --id ${VMID}-${JOB_NUM} \
        --target ${TARGET_NODE} \
        --type local \
        --schedule $(shell_quote "$VM_SCHEDULE")" 2>&1; then
      echo "CREATED" >> "$STATUS_FILE"
      echo "${VMID}-${JOB_NUM}" >> "$CREATED_IDS_FILE"
      if [[ "$SEED_WAIT_CLASS" == "async" ]]; then
        printf '%s\t%s\t%s\t%s\n' "${VMID}-${JOB_NUM}" "$SOURCE_NODE" "$VMID" "$NAME" >> "$CREATED_ASYNC_META_FILE"
      else
        echo "${VMID}-${JOB_NUM}" >> "$CREATED_STRICT_IDS_FILE"
      fi
    else
      echo "  ERROR: Failed to create replication for ${NAME} -> ${TARGET_NODE}" >&2
      echo "ERROR" >> "$STATUS_FILE"
    fi
  done
done

# Count results
CREATED=0
SKIPPED=0
ERRORS=0
POLICY_PRUNED=0
if [[ -s "$STATUS_FILE" ]]; then
  CREATED=$(grep -c "CREATED" "$STATUS_FILE" 2>/dev/null || true)
  SKIPPED=$(grep -c "SKIPPED" "$STATUS_FILE" 2>/dev/null || true)
  ERRORS=$(grep -c "ERROR" "$STATUS_FILE" 2>/dev/null || true)
fi

# --- Env-scoped policy prune (Sprint 047 A3.3) ---
if [[ -n "$PRUNE_POLICY_OFF" ]]; then
  echo ""
  echo "==> Env-scoped policy prune (scope='${ENV_SCOPE:-all}'): ${PRUNE_POLICY_OFF}"

  IFS=',' read -ra PRUNE_VMIDS <<< "$PRUNE_POLICY_OFF"
  for PVMID in "${PRUNE_VMIDS[@]}"; do
    [[ -z "$PVMID" ]] && continue

    # Delete any pvesr jobs for this VMID.
    JOBS_TO_DELETE=$(echo "$EXISTING_JOBS" | jq -r --argjson vmid "$PVMID" \
      '.[] | select(.guest == $vmid) | .id')
    for JOB_ID in $JOBS_TO_DELETE; do
      echo "  PRUNE: deleting job ${JOB_ID} (policy-off VMID ${PVMID})"
      ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
        "pvesh delete /cluster/replication/${JOB_ID}" 2>&1 || {
        echo "  ERROR: failed to delete ${JOB_ID}" >&2
      }

      WAIT=0
      while [[ $WAIT -lt 60 ]]; do
        REMAINING=$(ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
          "pvesh get /cluster/replication --output-format json" 2>/dev/null | \
          jq -r --arg id "$JOB_ID" '.[] | select(.id == $id) | .id')
        [[ -z "$REMAINING" ]] && break
        sleep 2
        WAIT=$((WAIT + 2))
      done
    done

    for TARGET_NODE in $NODE_NAMES; do
      SOURCE=$(echo "$VM_DATA" | jq -r --argjson vmid "$PVMID" \
        '.[] | select(.vmid == $vmid) | .node')
      [[ "$TARGET_NODE" == "$SOURCE" ]] && continue

      TARGET_IP=$(yq -r ".nodes[] | select(.name == \"${TARGET_NODE}\") | .mgmt_ip" "$CONFIG")
      [[ -z "$TARGET_IP" || "$TARGET_IP" == "null" ]] && continue

      echo "  PRUNE: destroying policy-off VMID ${PVMID} replicas on ${TARGET_NODE}"
      destroy_vm_zvols_on_target "$TARGET_IP" "$PVMID"

      REMAINING_ZVOLS=$(ssh -n -o ConnectTimeout=5 "root@${TARGET_IP}" \
        "zfs list -H -t volume -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep -E 'vm-${PVMID}-' || true")
      if [[ -n "$REMAINING_ZVOLS" ]]; then
        echo "  ERROR: policy-off VMID ${PVMID} still has replicas on ${TARGET_NODE}:" >&2
        echo "$REMAINING_ZVOLS" >&2
        echo "  ERROR: verify-after-destroy FAILED (Sprint 047 A3.3 ratchet)" >&2
        exit 1
      fi
    done
    POLICY_PRUNED=$((POLICY_PRUNED + 1))
  done
fi

echo ""
echo "Summary: ${CLEANED} stale jobs cleaned, ${ORPHAN_CLEANED} orphan zvol sets removed, ${GLOBAL_ORPHANS} globally orphaned VMIDs cleaned, ${CREATED} created, ${SKIPPED} skipped, SCHEDULE_RECONCILED=${SCHEDULE_RECONCILED}, ${ERRORS} errors, ${POLICY_PRUNED} policy-off VMIDs pruned"

if [[ "$ERRORS" -gt 0 ]]; then
  exit 1
fi

# --- Wait for initial sync of newly created jobs, verifying real job OUTCOME ---
#
# This is a data-protection gate, not a cosmetic wait. Job *presence* in the
# pvesr registry says nothing about whether the first `zfs send | zfs recv`
# actually succeeded — a job can exist while every run fails at ~1.5s with no
# data transmitted (see #502). Trusting presence produced a false "All
# replication jobs synced." on jobs that had LastSync=- and FailCount=2.
#
# We poll each source node's `pvesr status` and, for every job we created in
# this run, require the same truth predicate that `repl-health.sh` /
# `validate.sh` already use to catch the lie:
#   - LastSync != "-"  (the job has actually completed a sync at least once)
#   - FailCount == 0    (that most recent run did not fail)
# A job that cannot be found in any source node's status is treated as
# NOT-synced (fail-closed): we must not report success for a signal we
# cannot confirm.
#
# If any strict created job fails to reach the synced predicate within the
# timeout, we log each offending job with its State field (the actual zfs
# error) and exit non-zero. A check that cannot confirm sync success must
# fail, not pass. Async jobs are kicked immediately and observed best-effort
# off the deploy hot path.
async_job_registered() {
  local job_id="$1"
  local source_node="$2"
  local source_ip source_status

  source_ip=$(yq -r ".nodes[] | select(.name == \"${source_node}\") | .mgmt_ip" "$CONFIG")
  [[ -z "$source_ip" || "$source_ip" == "null" ]] && return 1
  if ! source_status=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${source_ip}" "pvesr status 2>/dev/null" 2>/dev/null); then
    return 1
  fi
  awk -v id="$job_id" 'NR == 1 && /^JobID/ {next} $1 == id {found = 1} END {exit found ? 0 : 1}' <<< "$source_status"
}

async_job_synced() {
  local job_id="$1"
  local source_node="$2"
  local source_ip source_status

  source_ip=$(yq -r ".nodes[] | select(.name == \"${source_node}\") | .mgmt_ip" "$CONFIG")
  [[ -z "$source_ip" || "$source_ip" == "null" ]] && return 1
  if ! source_status=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${source_ip}" "pvesr status 2>/dev/null" 2>/dev/null); then
    return 1
  fi
  awk -v id="$job_id" '
    NR == 1 && /^JobID/ {next}
    $1 == id {
      found = 1
      if ($4 == "-" || $4 == "" || $7 !~ /^[0-9]+$/ || $7 !~ /^0+$/) {
        bad = 1
      }
    }
    END {exit (found && !bad) ? 0 : 1}
  ' <<< "$source_status"
}

ASYNC_CREATED_COUNT=0
if [[ -s "$CREATED_ASYNC_META_FILE" ]]; then
  ASYNC_CREATED_COUNT=$(wc -l < "$CREATED_ASYNC_META_FILE" | tr -d ' ')
fi

if [[ "$ASYNC_CREATED_COUNT" -gt 0 ]]; then
  echo ""
  echo "==> Kicking async initial replication seeds..."
  ASYNC_ERRORS=0
  while IFS=$'\t' read -r job_id source_node vmid name; do
    [[ -z "$job_id" ]] && continue
    if ! async_job_registered "$job_id" "$source_node"; then
      echo "ERROR: async job ${job_id} not registered — cannot fire schedule-now" >&2
      ASYNC_ERRORS=$((ASYNC_ERRORS + 1))
      continue
    fi

    SOURCE_IP=$(yq -r ".nodes[] | select(.name == \"${source_node}\") | .mgmt_ip" "$CONFIG")
    if ! ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${SOURCE_IP}" "pvesr schedule-now ${job_id}" 2>&1; then
      echo "ERROR: failed to kick async replication seed for ${job_id} on ${source_node}" >&2
      ASYNC_ERRORS=$((ASYNC_ERRORS + 1))
      continue
    fi
    echo "  STARTED (async): ${job_id} (${name}) on ${source_node}"
  done < "$CREATED_ASYNC_META_FILE"

  if [[ "$ASYNC_ERRORS" -gt 0 ]]; then
    exit 1
  fi
fi

STRICT_CREATED_COUNT=0
if [[ -s "$CREATED_STRICT_IDS_FILE" ]]; then
  STRICT_CREATED_COUNT=$(wc -l < "$CREATED_STRICT_IDS_FILE" | tr -d ' ')
fi

if [[ "$STRICT_CREATED_COUNT" -gt 0 ]]; then
  echo ""
  echo "==> Waiting for initial replication sync..."

  # Poll exactly the strict jobs whose `pvesh create` succeeded this run.
  # ALLOCATED_IDS_FILE also holds IDs whose create failed; those must not be
  # polled for a sync they can never complete.
  CREATED_JOB_IDS=$(sort -u "$CREATED_STRICT_IDS_FILE" 2>/dev/null || true)

  # #626: single-line mktemp+append shape so a SIGINT or `set -e` cannot
  # fire between the mktemp and the CLEANUP_FILES registration.
  UNSYNCED_REPORT=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $UNSYNCED_REPORT"

  for attempt in $(seq 1 30); do
    # Snapshot the current status of every job from every source node, tagging
    # each row with the node it came from so a failing replica of a same-named
    # job on another node cannot be masked by a healthy first-match.
    # Format per line: "<job_id>\t<node>\t<last_sync>\t<fail_count>\t<state...>"
    ALL_JOB_STATUS=""
    UNREACHABLE_NODES=""
    for NODE_NAME_ITER in $NODE_NAMES; do
      NODE_IP_ITER=$(yq -r ".nodes[] | select(.name == \"${NODE_NAME_ITER}\") | .mgmt_ip" "$CONFIG")
      [[ -z "$NODE_IP_ITER" || "$NODE_IP_ITER" == "null" ]] && continue
      # pvesr columns: JobID Enabled Target LastSync NextSync Duration FailCount State...
      NODE_STATUS=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${NODE_IP_ITER}" \
        "pvesr status 2>/dev/null" 2>/dev/null \
        | awk -v node="$NODE_NAME_ITER" 'NR==1 && /^JobID/ {next} /^[0-9]+-[0-9]+/ {
            state=""; for (i=8;i<=NF;i++) state=state (i>8?" ":"") $i;
            printf "%s\t%s\t%s\t%s\t%s\n", $1, node, $4, $7, state
          }') || NODE_STATUS=""
      if [[ -z "$NODE_STATUS" ]]; then
        # Could not read status from this node (SSH failure, or pvesr empty).
        # Record it so the failure message can name the unreachable node.
        UNREACHABLE_NODES+="${NODE_NAME_ITER} "
      else
        ALL_JOB_STATUS+="${NODE_STATUS}"$'\n'
      fi
    done

    # Evaluate every job we created against the synced predicate. A job is
    # synced ONLY if at least one row exists for it AND every row for it
    # satisfies: LastSync != "-" AND FailCount is a number equal to 0.
    # Anything else — missing row, non-numeric FailCount, any failing row —
    # is unsynced (fail-closed).
    : > "$UNSYNCED_REPORT"
    UNSYNCED_COUNT=0
    while IFS= read -r job_id; do
      [[ -z "$job_id" ]] && continue
      # All rows for this job id, across every source node.
      job_rows=$(awk -F'\t' -v id="$job_id" '$1 == id' <<< "$ALL_JOB_STATUS")
      if [[ -z "$job_rows" ]]; then
        # Job not visible in any source node's status — cannot confirm.
        echo "${job_id}"$'\t''(not found in pvesr status)' >> "$UNSYNCED_REPORT"
        UNSYNCED_COUNT=$((UNSYNCED_COUNT + 1))
        continue
      fi
      job_unsynced=0
      job_detail=""
      while IFS=$'\t' read -r r_id r_node r_last r_fail r_state; do
        [[ -z "$r_id" ]] && continue
        row_bad=0
        if [[ "$r_last" == "-" || -z "$r_last" ]]; then
          row_bad=1
        fi
        # Non-numeric or non-zero FailCount is a failure. Do NOT coerce an
        # unparsable count to 0 (that would be fail-open). #594-adjacent:
        # nonzero test uses `! =~ ^0+$` string-match, not `-gt 0`
        # arithmetic, to avoid the same octal-parsing surprise (`08`/`09`)
        # the stale-detection predicate above dodges. Given the shape
        # guard already asserts `^[0-9]+$`, this reduces to "any digit
        # that is not entirely zeros".
        if [[ ! "$r_fail" =~ ^[0-9]+$ ]] || [[ ! "$r_fail" =~ ^0+$ ]]; then
          row_bad=1
        fi
        if [[ "$row_bad" -eq 1 ]]; then
          job_unsynced=1
          job_detail+="[${r_node}: LastSync=${r_last:--} FailCount=${r_fail:-?} State=${r_state}] "
        fi
      done <<< "$job_rows"

      if [[ "$job_unsynced" -eq 1 ]]; then
        echo "${job_id}"$'\t'"${job_detail}" >> "$UNSYNCED_REPORT"
        UNSYNCED_COUNT=$((UNSYNCED_COUNT + 1))
      fi
    done <<< "$CREATED_JOB_IDS"

    if [[ "$UNSYNCED_COUNT" -eq 0 ]]; then
      echo "  All replication jobs completed a successful initial sync."
      break
    fi
    echo "  Waiting for ${UNSYNCED_COUNT} replication job(s) to complete a successful initial sync... (${attempt}/30)"
    sleep 10
  done

  if [[ "$UNSYNCED_COUNT" -gt 0 ]]; then
    echo "" >&2
    echo "ERROR: ${UNSYNCED_COUNT} replication job(s) did NOT complete a successful initial sync within 5 minutes." >&2
    echo "       Job presence is not sync success — these jobs never confirmed LastSync with FailCount=0:" >&2
    while IFS=$'\t' read -r job_id detail; do
      [[ -z "$job_id" ]] && continue
      echo "  FAILED: ${job_id} — ${detail}" >&2
    done < "$UNSYNCED_REPORT"
    if [[ -n "${UNREACHABLE_NODES// }" ]]; then
      echo "       NOTE: could not read pvesr status from: ${UNREACHABLE_NODES}(treated as not-synced)" >&2
    fi
    echo "       Inspect on the source node with: pvesr status" >&2
    exit 1
  fi
fi

if [[ "$ASYNC_CREATED_COUNT" -gt 0 ]]; then
  echo ""
  echo "==> Observing async replication seeds (best effort, 90s)..."
  ASYNC_PENDING_REPORT=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $ASYNC_PENDING_REPORT"
  ASYNC_COMPLETED_FILE=$(mktemp); CLEANUP_FILES="$CLEANUP_FILES $ASYNC_COMPLETED_FILE"
  ASYNC_PENDING_COUNT=0

  # 10 checks × 10 s sleeps between → 90 s best-effort window (matches
  # plan A3 T3.2 async wait bound and the "90s" text above).
  for attempt in $(seq 1 10); do
    : > "$ASYNC_PENDING_REPORT"
    ASYNC_PENDING_COUNT=0
    while IFS=$'\t' read -r job_id source_node vmid name; do
      [[ -z "$job_id" ]] && continue
      if async_job_synced "$job_id" "$source_node"; then
        if ! grep -qx "$job_id" "$ASYNC_COMPLETED_FILE" 2>/dev/null; then
          echo "  COMPLETED (async): ${job_id} (${name})"
          echo "$job_id" >> "$ASYNC_COMPLETED_FILE"
        fi
      else
        printf '%s\t%s\n' "$job_id" "$name" >> "$ASYNC_PENDING_REPORT"
        ASYNC_PENDING_COUNT=$((ASYNC_PENDING_COUNT + 1))
      fi
    done < "$CREATED_ASYNC_META_FILE"

    [[ "$ASYNC_PENDING_COUNT" -eq 0 ]] && break
    [[ "$attempt" -lt 10 ]] && sleep 10
  done

  if [[ "$ASYNC_PENDING_COUNT" -gt 0 ]]; then
    while IFS=$'\t' read -r job_id name; do
      [[ -z "$job_id" ]] && continue
      echo "  SEEDING (async): ${job_id} — first sync in progress; repl-health tracks it"
    done < "$ASYNC_PENDING_REPORT"
  fi
fi

# --- Deliver /etc/repl-policy.vmids to every node (Sprint 047 A3.6) ---
# Build CADENCE_MAP=vmid1:secs1,vmid2:secs2,... sorted by vmid.
CADENCE_MAP=$(awk -F'\t' 'BEGIN{OFS=":"} $4 == "true" && $8 ~ /^[0-9]+$/ {print $1, $8}' "$HELPER_TSV_CACHE" | sort -n | paste -sd, -)
POLICY_GEN=$(printf '%s|%s|%s\n' "$GLOBAL_POLICY_ON" "$GLOBAL_POLICY_OFF" "$CADENCE_MAP" | sha256sum | awk '{print $1}')
ARTIFACT_CONTENT="POLICY_ON_VMIDS=${GLOBAL_POLICY_ON}
POLICY_OFF_VMIDS=${GLOBAL_POLICY_OFF}
CADENCE_MAP=${CADENCE_MAP}
POLICY_GEN=${POLICY_GEN}
"
for NODE in $NODE_NAMES; do
  NODE_IP=$(yq -r ".nodes[] | select(.name == \"${NODE}\") | .mgmt_ip" "$CONFIG")
  [[ -z "$NODE_IP" || "$NODE_IP" == "null" ]] && continue
  echo "$ARTIFACT_CONTENT" | ssh -o ConnectTimeout=5 "root@${NODE_IP}" \
    "cat > /etc/repl-policy.vmids.tmp && mv /etc/repl-policy.vmids.tmp /etc/repl-policy.vmids" \
    || echo "  WARN: failed to deliver artifact to ${NODE}" >&2
done
echo "==> Delivered /etc/repl-policy.vmids to all nodes (POLICY_GEN=${POLICY_GEN:0:8}...)"

# The companion `framework/scripts/cleanup-orphan-cidata.sh` script handles
# migration-orphan cidata zvols. It is intentionally NOT invoked
# automatically here — see `.claude/rules/replication.md` for the
# operator-invocation contract. The auto-invocation case requires
# additional design work tracked as a follow-up to #417 (codex R2 P1:
# name-only cluster-wide attached check is not node-aware enough to
# safely run automatically before a migration-back).
