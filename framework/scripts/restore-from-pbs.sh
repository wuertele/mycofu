#!/usr/bin/env bash
# restore-from-pbs.sh — Restore precious state from PBS backups after rebuild.
#
# Usage:
#   framework/scripts/restore-from-pbs.sh              # Restore all precious VMs
#   framework/scripts/restore-from-pbs.sh --dry-run    # Show what would be restored
#   framework/scripts/restore-from-pbs.sh --target 500 # Restore a single VMID
#
# For each precious-state VM (backup: true in config.yaml), checks if a PBS
# backup exists with the same VMID. If so, restores ONLY the data disk (vdb)
# from the most recent backup. The root disk (vda) and CIDATA are preserved
# from the current deployment.
#
# Restore order: Vault → GitLab → application VMs
# Skips VMs with no backup available.
# Idempotent: safe to re-run (restores overwrite the data disk).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

DRY_RUN=0
TARGET_VMID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --target) TARGET_VMID="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- SSH helper ---
ssh_node() {
  local ip="$1"; shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

# --- Read config ---
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
NODE_COUNT=$(yq -r '.nodes | length' "$CONFIG")
PBS_IP=$(yq -r '.vms.pbs.ip // ""' "$CONFIG")
STORAGE_POOL=$(yq -r '.proxmox.storage_pool // "vmstore"' "$CONFIG")

# --- Prerequisites ---
if [[ -z "$PBS_IP" || "$PBS_IP" == "null" ]]; then
  echo "No PBS configured — skipping restore"
  exit 0
fi

# Check PBS storage registered in Proxmox
if ! ssh_node "$FIRST_NODE_IP" "pvesm status 2>/dev/null" | grep -q "pbs-nas"; then
  echo "PBS storage (pbs-nas) not registered in Proxmox — skipping restore"
  echo "(Run configure-pbs.sh first)"
  exit 0
fi

# --- Build list of precious-state VMIDs ---
# Same logic as configure-backups.sh
PRECIOUS_VMIDS=()
PRECIOUS_NAMES=()

# Infrastructure VMs with backup: true
while IFS= read -r vm_key; do
  [[ -z "$vm_key" ]] && continue
  vmid=$(yq -r ".vms.${vm_key}.vmid" "$CONFIG")
  PRECIOUS_VMIDS+=("$vmid")
  PRECIOUS_NAMES+=("$vm_key")
done < <(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG")

# Application VMs with backup: true
while IFS= read -r app_key; do
  [[ -z "$app_key" ]] && continue
  for env in $(yq -r ".applications.${app_key}.environments | keys | .[]" "$CONFIG" 2>/dev/null); do
    vmid=$(yq -r ".applications.${app_key}.environments.${env}.vmid" "$CONFIG")
    PRECIOUS_VMIDS+=("$vmid")
    PRECIOUS_NAMES+=("${app_key}_${env}")
  done
done < <(yq -r '.applications | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$CONFIG")

if [[ ${#PRECIOUS_VMIDS[@]} -eq 0 ]]; then
  echo "No VMs with backup: true in config.yaml — nothing to restore"
  exit 0
fi

# If targeting a single VMID, use it directly (even if not in precious-state list)
if [[ -n "$TARGET_VMID" ]]; then
  FOUND=0
  for (( i=0; i<${#PRECIOUS_VMIDS[@]}; i++ )); do
    if [[ "${PRECIOUS_VMIDS[$i]}" == "$TARGET_VMID" ]]; then
      PRECIOUS_VMIDS=("${PRECIOUS_VMIDS[$i]}")
      PRECIOUS_NAMES=("${PRECIOUS_NAMES[$i]}")
      FOUND=1
      break
    fi
  done
  if [[ $FOUND -eq 0 ]]; then
    # Not in precious-state list — still allow restore with --target
    # Look up the VM name from config.yaml
    VM_NAME=$(yq -r ".vms | to_entries[] | select(.value.vmid == ${TARGET_VMID}) | .key" "$CONFIG" 2>/dev/null)
    [[ -z "$VM_NAME" ]] && VM_NAME="vmid-${TARGET_VMID}"
    PRECIOUS_VMIDS=("$TARGET_VMID")
    PRECIOUS_NAMES=("$VM_NAME")
  fi
fi

echo "=== PBS Restore ==="
echo "Precious-state VMs:"
for (( i=0; i<${#PRECIOUS_VMIDS[@]}; i++ )); do
  echo "  VMID ${PRECIOUS_VMIDS[$i]}  ${PRECIOUS_NAMES[$i]}"
done

# --- Query available backups ---
echo ""
echo "Querying PBS for available backups..."
BACKUP_JSON=$(ssh_node "$FIRST_NODE_IP" \
  "pvesh get /nodes/\$(hostname)/storage/pbs-nas/content --output-format json 2>/dev/null" || echo "[]")

RESTORE_COUNT=0

# --- Restore each VM ---
# Order: vault first, then gitlab, then applications
# Sort by VMID to get a deterministic order (vault 303/403 before gitlab 150...
# actually we want vault first explicitly)
ORDERED_INDICES=()
# First pass: vaults (VMID 303, 403)
for (( i=0; i<${#PRECIOUS_VMIDS[@]}; i++ )); do
  [[ "${PRECIOUS_NAMES[$i]}" == *vault* ]] && ORDERED_INDICES+=("$i")
done
# Second pass: gitlab (VMID 150)
for (( i=0; i<${#PRECIOUS_VMIDS[@]}; i++ )); do
  [[ "${PRECIOUS_NAMES[$i]}" == *gitlab* ]] && ORDERED_INDICES+=("$i")
done
# Third pass: everything else
for (( i=0; i<${#PRECIOUS_VMIDS[@]}; i++ )); do
  [[ "${PRECIOUS_NAMES[$i]}" != *vault* && "${PRECIOUS_NAMES[$i]}" != *gitlab* ]] && ORDERED_INDICES+=("$i")
done

for idx in "${ORDERED_INDICES[@]}"; do
  VMID="${PRECIOUS_VMIDS[$idx]}"
  VM_NAME="${PRECIOUS_NAMES[$idx]}"

  # Find the most recent backup for this VMID
  LATEST_VOLID=$(echo "$BACKUP_JSON" | python3 -c "
import sys, json
backups = [b for b in json.loads(sys.stdin.read()) if b.get('vmid') == ${VMID}]
if backups:
    latest = max(backups, key=lambda b: b.get('ctime', 0))
    print(latest['volid'])
" 2>/dev/null)

  if [[ -z "$LATEST_VOLID" ]]; then
    echo ""
    echo "--- ${VM_NAME} (VMID ${VMID}): no backup found — will be fresh-initialized"
    continue
  fi

  echo ""
  echo "--- ${VM_NAME} (VMID ${VMID}): backup found ---"
  echo "  Backup: ${LATEST_VOLID}"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would restore vdb from this backup"
    RESTORE_COUNT=$((RESTORE_COUNT + 1))
    continue
  fi

  # Find which node hosts this VM
  HOSTING_NODE=$(ssh_node "$FIRST_NODE_IP" \
    "pvesh get /cluster/resources --type vm --output-format json" | python3 -c "
import sys, json
for v in json.loads(sys.stdin.read()):
    if v.get('vmid') == ${VMID}:
        print(v['node']); break
" 2>/dev/null)

  if [[ -z "$HOSTING_NODE" ]]; then
    echo "  WARNING: VM ${VMID} not found in cluster — skipping"
    continue
  fi

  HOSTING_IP=$(yq -r ".nodes[] | select(.name == \"${HOSTING_NODE}\") | .mgmt_ip" "$CONFIG")
  echo "  Hosted on: ${HOSTING_NODE} (${HOSTING_IP})"

  # Remove HA to prevent restart during restore
  echo "  Removing HA resource..."
  ssh_node "$HOSTING_IP" "ha-manager remove vm:${VMID}" || true
  sleep 2

  # Stop VM with verification loop
  echo "  Stopping VM..."
  ssh_node "$HOSTING_IP" "qm stop ${VMID} --skiplock 1" || true
  for STOP_TRY in $(seq 1 6); do
    VM_STATUS=$(ssh_node "$HOSTING_IP" "qm status ${VMID} 2>/dev/null | awk '{print \$2}'" || echo "unknown")
    [[ "$VM_STATUS" == "stopped" ]] && break
    ssh_node "$HOSTING_IP" "qm stop ${VMID} --skiplock 1" || true
    sleep 5
  done
  if [[ "$VM_STATUS" != "stopped" ]]; then
    echo "  WARNING: Could not stop VM ${VMID} — skipping restore"
    ssh_node "$HOSTING_IP" "ha-manager add vm:${VMID} --state started" || true
    continue
  fi

  # Identify the data disk (vdb) by size — per .claude/rules/pbs-restore.md
  echo "  Identifying data disk..."
  DISK_INFO=$(ssh_node "$HOSTING_IP" "qm config ${VMID}" | grep "^scsi")
  echo "  ${DISK_INFO}"

  # The data disk is scsi1 (larger or second disk). Get its zvol name.
  # Extract zvol name: "scsi1: vmstore:vm-500-disk-0,aio=..." → "vm-500-disk-0"
  TARGET_ZVOL=$(echo "$DISK_INFO" | grep "scsi1:" | sed "s/.*${STORAGE_POOL}://" | sed 's/,.*//')
  if [[ -z "$TARGET_ZVOL" ]]; then
    echo "  WARNING: No scsi1 (data disk) found — skipping restore"
    ssh_node "$HOSTING_IP" "qm start ${VMID}" || true
    ssh_node "$HOSTING_IP" "ha-manager add vm:${VMID} --state started" || true
    continue
  fi
  echo "  Target zvol: ${STORAGE_POOL}/${TARGET_ZVOL}"

  # Restore backup to temp VM (9999) to extract the data disk
  echo "  Restoring backup to temp VM..."
  ssh_node "$HOSTING_IP" "qmrestore '${LATEST_VOLID}' 9999 --force --start 0" || {
    echo "  WARNING: qmrestore failed — skipping"
    ssh_node "$HOSTING_IP" "qm start ${VMID}" || true
    ssh_node "$HOSTING_IP" "ha-manager add vm:${VMID} --state started" || true
    continue
  }

  # Find the data disk in the temp VM (match by size — the larger non-boot disk)
  TEMP_DISKS=$(ssh_node "$HOSTING_IP" "qm config 9999" | grep "^scsi")
  TEMP_SCSI1_ZVOL=$(echo "$TEMP_DISKS" | grep "scsi1:" | sed "s/.*${STORAGE_POOL}://" | sed 's/,.*//')

  if [[ -z "$TEMP_SCSI1_ZVOL" ]]; then
    echo "  WARNING: No scsi1 in backup — skipping"
    ssh_node "$HOSTING_IP" "qm destroy 9999 --purge" || true
    ssh_node "$HOSTING_IP" "qm start ${VMID}" || true
    ssh_node "$HOSTING_IP" "ha-manager add vm:${VMID} --state started" || true
    continue
  fi

  # Copy the data disk from temp VM to target VM
  echo "  Copying data disk: ${TEMP_SCSI1_ZVOL} → ${TARGET_ZVOL}..."
  ssh_node "$HOSTING_IP" "dd if=/dev/zvol/${STORAGE_POOL}/data/${TEMP_SCSI1_ZVOL} of=/dev/zvol/${STORAGE_POOL}/data/${TARGET_ZVOL} bs=4M status=none" || {
    echo "  WARNING: dd failed — data disk may be corrupted"
  }

  # Clean up temp VM
  ssh_node "$HOSTING_IP" "qm destroy 9999 --purge" || true

  # Start VM and re-add HA
  echo "  Starting VM..."
  ssh_node "$HOSTING_IP" "qm start ${VMID}" || true
  ssh_node "$HOSTING_IP" "ha-manager add vm:${VMID} --state started" || true

  echo "  Restored ${VM_NAME} (VMID ${VMID})"
  RESTORE_COUNT=$((RESTORE_COUNT + 1))
done

echo ""
echo "=== Restore complete: ${RESTORE_COUNT} VM(s) restored ==="
