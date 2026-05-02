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
#   framework/scripts/configure-replication.sh <vm-name-pattern> [--interval <minutes>]
#
# Examples:
#   framework/scripts/configure-replication.sh "dns*"
#   framework/scripts/configure-replication.sh "dns*" --interval 1
#   framework/scripts/configure-replication.sh "vault*" --interval 5
#
# The script SSHes to the first Proxmox node to run pvesh commands.
# It is idempotent — existing replication jobs are skipped.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

INTERVAL=1  # minutes

usage() {
  cat <<EOF
Usage: $(basename "$0") <vm-name-pattern> [--interval <minutes>]

Configure Proxmox ZFS replication for VMs matching the given pattern.

Arguments:
  <vm-name-pattern>   Pattern to match VM names (e.g., "dns*", "vault*")

Options:
  --interval <min>    Replication interval in minutes (default: 1)
  --help              Show this help message
EOF
}

VM_PATTERN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
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

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 1
fi

# Read node info from config
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
NODE_NAMES=$(yq -r '.nodes[].name' "$CONFIG")
STORAGE_POOL=$(yq -r '.proxmox.storage_pool' "$CONFIG")

# Proxmox uses systemd calendar event format, not cron.
# */N means "every N minutes" in Proxmox's schedule syntax.
SCHEDULE="*/${INTERVAL}"

echo "VM pattern: ${VM_PATTERN}"
echo "Interval:   every ${INTERVAL} minute(s)"
echo "Schedule:   ${SCHEDULE}"
echo ""

# Get all VMs matching the pattern and their details
echo "==> Finding VMs matching '${VM_PATTERN}'..."
VM_DATA=$(ssh "root@${FIRST_NODE_IP}" \
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
EXISTING_JOBS=$(ssh -n "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/replication --output-format json" 2>/dev/null || echo "[]")

# --- Clean up stale/failed replication jobs AND orphan zvols ---
# Two cleanup scenarios after VM recreation:
# 1. Failed jobs: VM was recreated but replication jobs persist with fail_count > 0
#    (stale snapshots don't match the new disk). Fix: delete job, destroy zvols, recreate.
# 2. Orphan zvols: VM was destroyed (jobs auto-removed by Proxmox) then recreated.
#    Orphan zvols remain on target nodes with no corresponding job. Fix: destroy zvols
#    before creating new jobs (otherwise new jobs fail with "No common base snapshot").

echo "==> Checking for stale replication jobs..."
STALE_STATUS=$(mktemp)
CLEANUP_FILES="$STALE_STATUS"
trap 'rm -f $CLEANUP_FILES' EXIT

# Get list of matching VMIDs for filtering
MATCHING_VMIDS=$(echo "$MATCHING_VMS" | awk '{print $1}')

# pvesr status only shows jobs sourced from the local node.
# Check each unique source node for failed jobs.
SOURCE_NODES=$(echo "$MATCHING_VMS" | awk '{print $3}' | sort -u)
for SRC_NODE in $SOURCE_NODES; do
  SRC_IP=$(yq -r ".nodes[] | select(.name == \"${SRC_NODE}\") | .mgmt_ip" "$CONFIG")
  [[ -z "$SRC_IP" || "$SRC_IP" == "null" ]] && continue

  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${SRC_IP}" "pvesr status 2>/dev/null" 2>/dev/null | while IFS= read -r line; do
    [[ "$line" =~ ^JobID ]] && continue
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[0-9]+-[0-9]+ ]] || continue

    job_id=$(echo "$line" | awk '{print $1}')
    fail_count=$(echo "$line" | awk '{print $7}')
    vmid=$(echo "$job_id" | cut -d- -f1)

    # Only clean jobs for VMs we're managing
    if ! echo "$MATCHING_VMIDS" | grep -qw "$vmid"; then
      continue
    fi

    if [[ "${fail_count:-0}" -gt 0 ]]; then
      echo "$job_id" >> "$STALE_STATUS"
    fi
  done
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
    ssh -n "root@${FIRST_NODE_IP}" \
      "pvesh delete /cluster/replication/${job_id}" 2>&1 || true

    # Destroy orphaned zvols on the target node
    TARGET_IP=$(yq -r ".nodes[] | select(.name == \"${target_node}\") | .mgmt_ip" "$CONFIG")
    if [[ -n "$TARGET_IP" && "$TARGET_IP" != "null" ]]; then
      ssh -n "root@${TARGET_IP}" "
        for zvol in \$(zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep \"vm-${vmid}-\"); do
          echo \"    Destroying orphan zvol: \$zvol\"
          zfs destroy -r \"\$zvol\" 2>&1 || true
        done
      " 2>/dev/null || true
    fi

    CLEANED=$((CLEANED + 1))
  done < "$STALE_STATUS"
  echo "  Cleaned ${CLEANED} stale jobs"
  # Proxmox removes replication jobs asynchronously — wait for removal to complete
  echo "  Waiting for background removal to finish..."
  for wait_i in $(seq 1 12); do
    sleep 5
    # Check if any of the deleted jobs still appear in the cluster replication list
    REMAINING=$(ssh -n "root@${FIRST_NODE_IP}" \
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
EXISTING_JOBS=$(ssh -n "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/replication --output-format json" 2>/dev/null || echo "[]")

ORPHAN_STATUS=$(mktemp)
CLEANUP_FILES="$CLEANUP_FILES $ORPHAN_STATUS"

echo "$MATCHING_VMS" | while read -r VMID NAME SOURCE_NODE; do
  for TARGET_NODE in $NODE_NAMES; do
    [[ "$TARGET_NODE" == "$SOURCE_NODE" ]] && continue

    TARGET_IP=$(yq -r ".nodes[] | select(.name == \"${TARGET_NODE}\") | .mgmt_ip" "$CONFIG")
    [[ -z "$TARGET_IP" || "$TARGET_IP" == "null" ]] && continue

    # Check if this VM has zvols on the target node
    TARGET_ZVOLS=$(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
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
      ssh -n "root@${TARGET_IP}" "
        for zvol in \$(zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep 'vm-${VMID}-'); do
          echo \"    Destroying orphan zvol: \$zvol\"
          zfs destroy -r \"\$zvol\" 2>&1 || true
        done
      " 2>/dev/null || true
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
ALL_VMIDS=$(echo "$VM_DATA" | jq -r '.[].vmid' | sort -u)
if [[ -z "$ALL_VMIDS" ]]; then
  echo "  WARNING: Could not enumerate VMs from cluster API — skipping global orphan cleanup"
  echo "  (This prevents accidental destruction of all zvols when the API is temporarily unreachable)"
else
GLOBAL_ORPHANS=0

for NODE_NAME_ITER in $NODE_NAMES; do
  NODE_IP_ITER=$(yq -r ".nodes[] | select(.name == \"${NODE_NAME_ITER}\") | .mgmt_ip" "$CONFIG")
  [[ -z "$NODE_IP_ITER" || "$NODE_IP_ITER" == "null" ]] && continue

  # Get all VM zvol VMIDs on this node
  ZVOL_VMIDS=$(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
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
    ssh -n "root@${NODE_IP_ITER}" "
      for zvol in \$(zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep 'vm-${ZVOL_VMID}-'); do
        echo \"    Destroying: \$zvol\"
        zfs destroy -r \"\$zvol\" 2>&1 || true
      done
    " 2>/dev/null || true
    GLOBAL_ORPHANS=$((GLOBAL_ORPHANS + 1))
  done
done
echo "  Cleaned ${GLOBAL_ORPHANS} globally orphaned VMID sets"
fi  # end ALL_VMIDS guard
echo ""

# --- Create/verify replication jobs ---
STATUS_FILE=$(mktemp)
ALLOCATED_IDS_FILE=$(mktemp)
CLEANUP_FILES="$CLEANUP_FILES $STATUS_FILE $ALLOCATED_IDS_FILE"

echo "==> Configuring replication..."
echo "$MATCHING_VMS" | while read -r VMID NAME SOURCE_NODE; do
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
    if ssh -n "root@${FIRST_NODE_IP}" \
      "pvesh create /cluster/replication \
        --id ${VMID}-${JOB_NUM} \
        --target ${TARGET_NODE} \
        --type local \
        --schedule '${SCHEDULE}'" 2>&1; then
      echo "CREATED" >> "$STATUS_FILE"
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
if [[ -s "$STATUS_FILE" ]]; then
  CREATED=$(grep -c "CREATED" "$STATUS_FILE" 2>/dev/null || true)
  SKIPPED=$(grep -c "SKIPPED" "$STATUS_FILE" 2>/dev/null || true)
  ERRORS=$(grep -c "ERROR" "$STATUS_FILE" 2>/dev/null || true)
fi

echo ""
echo "Summary: ${CLEANED} stale jobs cleaned, ${ORPHAN_CLEANED} orphan zvol sets removed, ${GLOBAL_ORPHANS} globally orphaned VMIDs cleaned, ${CREATED} created, ${SKIPPED} skipped, ${ERRORS} errors"

if [[ "$ERRORS" -gt 0 ]]; then
  exit 1
fi

# Wait for initial sync of newly created jobs
if [[ "$CREATED" -gt 0 ]]; then
  echo ""
  echo "==> Waiting for initial replication sync..."
  for attempt in $(seq 1 30); do
    STALE_COUNT=0
    for NODE_NAME_ITER in $NODE_NAMES; do
      NODE_IP_ITER=$(yq -r ".nodes[] | select(.name == \"${NODE_NAME_ITER}\") | .mgmt_ip" "$CONFIG")
      [[ -z "$NODE_IP_ITER" || "$NODE_IP_ITER" == "null" ]] && continue
      NODE_STALE=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${NODE_IP_ITER}" \
        "pvesr status 2>/dev/null | awk 'NR>1' | grep -cv 'OK\$' || echo 0" 2>/dev/null | tail -1 | tr -d '[:space:]')
      [[ -z "$NODE_STALE" || ! "$NODE_STALE" =~ ^[0-9]+$ ]] && NODE_STALE=0
      STALE_COUNT=$((STALE_COUNT + NODE_STALE))
    done
    if [[ "$STALE_COUNT" -eq 0 ]]; then
      echo "  All replication jobs synced."
      break
    fi
    echo "  Waiting for ${STALE_COUNT} replication jobs to complete initial sync... (${attempt}/30)"
    sleep 10
  done
  if [[ "$STALE_COUNT" -gt 0 ]]; then
    echo "  WARNING: ${STALE_COUNT} replication jobs still not synced after 5 minutes." >&2
  fi
fi
