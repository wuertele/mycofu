#!/usr/bin/env bash
# restore-from-pbs.sh — Restore precious state from PBS backups after rebuild.
#
# Usage:
#   framework/scripts/restore-from-pbs.sh              # Restore all precious VMs
#   framework/scripts/restore-from-pbs.sh --dry-run    # Show what would be restored
#   framework/scripts/restore-from-pbs.sh --target 500 # Restore a single VMID
#   framework/scripts/restore-from-pbs.sh --target 500 --backup-id <volid>
#                                                    # Restore a specific PBS snapshot
#   framework/scripts/restore-from-pbs.sh --force      # Overwrite vdb even if it has data
#   framework/scripts/restore-from-pbs.sh --leave-stopped
#                                                    # Restore vdb but do not start or re-add HA
#
# For each precious-state VM (backup: true in config.yaml), checks if a PBS
# backup exists with the same VMID. If so, restores ONLY the data disk (vdb)
# from the most recent backup, unless --backup-id pins a specific PBS volid.
# The root disk (vda) and CIDATA are preserved
# from the current deployment.
#
# Restore order: Vault → GitLab → application VMs
# Skips VMs with no backup available.
# Idempotent: safe to re-run (restores overwrite the data disk).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
source "${SCRIPT_DIR}/vdb-state-lib.sh"

DRY_RUN=0
TARGET_VMID=""
FORCE=0
BACKUP_ID=""
LEAVE_STOPPED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --target) TARGET_VMID="$2"; shift 2 ;;
    --backup-id) BACKUP_ID="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --leave-stopped) LEAVE_STOPPED=1; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -n "$BACKUP_ID" && -z "$TARGET_VMID" ]]; then
  echo "ERROR: --backup-id requires --target <vmid>" >&2
  exit 1
fi

if [[ -n "$BACKUP_ID" ]]; then
  if [[ ! "$BACKUP_ID" =~ ^pbs-nas:backup/vm/([0-9]+)/.+$ ]]; then
    echo "ERROR: Invalid --backup-id format: ${BACKUP_ID}" >&2
    echo "Expected: pbs-nas:backup/vm/<vmid>/<timestamp>" >&2
    exit 1
  fi

  BACKUP_ID_VMID="${BASH_REMATCH[1]}"
  if [[ -n "$TARGET_VMID" && "$BACKUP_ID_VMID" != "$TARGET_VMID" ]]; then
    echo "ERROR: --backup-id VMID ${BACKUP_ID_VMID} does not match --target ${TARGET_VMID}" >&2
    exit 1
  fi
fi

# --- SSH helper ---
ssh_node() {
  local ip="$1"; shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

vm_ip_for_label() {
  local label="$1"
  local ip=""
  local app_key=""
  local env_name=""

  ip="$(yq -r ".vms.${label}.ip // \"\"" "$CONFIG" 2>/dev/null || true)"
  if [[ -n "$ip" && "$ip" != "null" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  app_key="${label%_*}"
  env_name="${label##*_}"
  if [[ "$app_key" == "$label" || "$env_name" == "$label" ]]; then
    return 1
  fi

  ip="$(yq -r ".applications.${app_key}.environments.${env_name}.mgmt_nic.ip // .applications.${app_key}.environments.${env_name}.ip // \"\"" "$APPS_CONFIG" 2>/dev/null || true)"
  if [[ -n "$ip" && "$ip" != "null" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  return 1
}

vm_vdb_has_real_state() {
  local label="$1"
  local ip="$2"
  local probe_script=""

  probe_script="$(vdb_state_probe_script_for_label "$label")"
  ssh_node "$ip" "$probe_script" >/dev/null
}

start_vm_if_requested() {
  local node_ip="$1"
  local vmid="$2"

  if [[ "$LEAVE_STOPPED" -eq 1 ]]; then
    echo "  Leaving VM ${vmid} stopped (--leave-stopped)"
    return 0
  fi

  ssh_node "$node_ip" "qm start ${vmid}" || true
}

add_ha_if_requested() {
  local node_ip="$1"
  local vmid="$2"

  if [[ "$LEAVE_STOPPED" -eq 1 ]]; then
    echo "  Leaving HA resource for VM ${vmid} absent (--leave-stopped)"
    return 0
  fi

  ssh_node "$node_ip" "ha-manager add vm:${vmid} --state started" || true
}

# --- Read config ---
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
NODE_COUNT=$(yq -r '.nodes | length' "$CONFIG")
PBS_IP=$(yq -r '.vms.pbs.ip // ""' "$CONFIG")
STORAGE_POOL=$(yq -r '.proxmox.storage_pool // "vmstore"' "$CONFIG")

# --- Prerequisites ---
if [[ -z "$PBS_IP" || "$PBS_IP" == "null" ]]; then
  echo "ERROR: No PBS configured; cannot restore precious vdb state" >&2
  exit 1
fi

# Check PBS storage registered in Proxmox. Query failure is distinct from a
# successful query with no pbs-nas entry, but both are fatal for restore paths:
# callers must not proceed as if an empty vdb is safe when PBS state is unknown.
PVESM_STATUS=""
set +e
PVESM_STATUS="$(ssh_node "$FIRST_NODE_IP" "pvesm status 2>/dev/null")"
PVESM_RC=$?
set -e
if [[ "$PVESM_RC" -ne 0 ]]; then
  echo "ERROR: Could not query Proxmox storage status from ${FIRST_NODE_IP}" >&2
  exit 1
fi
if ! grep -Eq '(^|[[:space:]])pbs-nas([[:space:]]|$)' <<< "$PVESM_STATUS"; then
  echo "ERROR: PBS storage (pbs-nas) is not registered in Proxmox" >&2
  echo "Run configure-pbs.sh first, or use explicit first-deploy approval where supported." >&2
  exit 1
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
  for env in $(yq -r ".applications.${app_key}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null); do
    vmid=$(yq -r ".applications.${app_key}.environments.${env}.vmid" "$APPS_CONFIG")
    PRECIOUS_VMIDS+=("$vmid")
    PRECIOUS_NAMES+=("${app_key}_${env}")
  done
done < <(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null)

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
BACKUP_JSON="[]"
if [[ -z "$BACKUP_ID" ]]; then
  echo ""
  echo "Querying PBS for available backups..."
  set +e
  BACKUP_JSON=$(ssh_node "$FIRST_NODE_IP" \
    "pvesh get /nodes/\$(hostname)/storage/pbs-nas/content --output-format json 2>/dev/null")
  BACKUP_QUERY_RC=$?
  set -e
  if [[ "$BACKUP_QUERY_RC" -ne 0 ]]; then
    echo "ERROR: Could not query PBS content from Proxmox storage pbs-nas" >&2
    exit 1
  fi
  if ! jq -e 'type == "array"' <<< "$BACKUP_JSON" >/dev/null 2>&1; then
    echo "ERROR: PBS content query returned invalid JSON" >&2
    exit 1
  fi
fi

RESTORE_COUNT=0
FAIL_COUNT=0

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

  if [[ -n "$BACKUP_ID" ]]; then
    LATEST_VOLID="$BACKUP_ID"
  else
    # Find the most recent backup for this VMID
    LATEST_VOLID=$(echo "$BACKUP_JSON" | python3 -c "
import sys, json
backups = [b for b in json.loads(sys.stdin.read()) if b.get('vmid') == ${VMID}]
if backups:
    latest = max(backups, key=lambda b: b.get('ctime', 0))
    print(latest['volid'])
" 2>/dev/null)
  fi

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
    echo "  FAILED: VM ${VMID} not found in cluster — skipping"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  HOSTING_IP=$(yq -r ".nodes[] | select(.name == \"${HOSTING_NODE}\") | .mgmt_ip" "$CONFIG")
  echo "  Hosted on: ${HOSTING_NODE} (${HOSTING_IP})"

  # Check if vdb already has real state. A plain ext4 filesystem is not enough:
  # field-updatable workstation boots create a bootstrap /home skeleton before
  # PBS restore, and treating that as "safe to skip" would strand the backup.
  # We only skip when the mounted vdb content probe says the VM has real data.
  # Find the scsi1 zvol name from the VM config (disk numbering varies).
  VDB_ZVOL=$(ssh_node "$HOSTING_IP" \
    "qm config ${VMID} 2>/dev/null | grep '^scsi1:' | sed 's/.*${STORAGE_POOL}://' | sed 's/,.*//'")
  if [[ -n "$VDB_ZVOL" ]]; then
    VDB_HAS_DATA=$(ssh_node "$HOSTING_IP" \
      "blkid /dev/zvol/${STORAGE_POOL}/data/${VDB_ZVOL} 2>/dev/null | grep -c TYPE" || echo "0")
    if [[ "$VDB_HAS_DATA" -gt 0 && "$FORCE" -eq 0 ]]; then
      VM_IP="$(vm_ip_for_label "$VM_NAME" || true)"
      if [[ -z "$VM_IP" ]]; then
        echo "  FAILED: ${VM_NAME} has a formatted vdb but no reachable IP for content verification"
        echo "  Refusing to overwrite without --force"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
      fi

      set +e
      vm_vdb_has_real_state "$VM_NAME" "$VM_IP"
      VDB_STATE_RC=$?
      set -e

      if [[ "$VDB_STATE_RC" -eq 0 ]]; then
        echo "  Skipping — vdb already has real state"
        echo "  Use --force to overwrite existing data with PBS backup"
        continue
      fi

      if [[ "$VDB_STATE_RC" -eq 1 ]]; then
        echo "  Existing filesystem detected but no real state found — continuing restore"
      else
        echo "  FAILED: Could not verify whether ${VM_NAME} vdb contains real state"
        echo "  Refusing to overwrite without --force"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
      fi
    elif [[ "$VDB_HAS_DATA" -gt 0 && "$FORCE" -eq 1 ]]; then
      echo "  WARNING: Overwriting existing filesystem on vdb (--force)"
    fi
  fi

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
    echo "  FAILED: Could not stop VM ${VMID} — skipping restore"
    add_ha_if_requested "$HOSTING_IP" "$VMID"
    FAIL_COUNT=$((FAIL_COUNT + 1))
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
    echo "  FAILED: No scsi1 (data disk) found — skipping restore"
    start_vm_if_requested "$HOSTING_IP" "$VMID"
    add_ha_if_requested "$HOSTING_IP" "$VMID"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi
  echo "  Target zvol: ${STORAGE_POOL}/${TARGET_ZVOL}"

  # Restore backup to temp VM (9999) to extract the data disk
  echo "  Restoring backup to temp VM..."
  ssh_node "$HOSTING_IP" "qmrestore '${LATEST_VOLID}' 9999 --force --start 0" || {
    echo "  FAILED: qmrestore failed — skipping"
    start_vm_if_requested "$HOSTING_IP" "$VMID"
    add_ha_if_requested "$HOSTING_IP" "$VMID"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  }

  # Find the data disk in the temp VM (match by size — the larger non-boot disk)
  TEMP_DISKS=$(ssh_node "$HOSTING_IP" "qm config 9999" | grep "^scsi")
  TEMP_SCSI1_ZVOL=$(echo "$TEMP_DISKS" | grep "scsi1:" | sed "s/.*${STORAGE_POOL}://" | sed 's/,.*//')

  if [[ -z "$TEMP_SCSI1_ZVOL" ]]; then
    echo "  FAILED: No scsi1 in backup — skipping"
    ssh_node "$HOSTING_IP" "qm destroy 9999 --purge" || true
    start_vm_if_requested "$HOSTING_IP" "$VMID"
    add_ha_if_requested "$HOSTING_IP" "$VMID"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  # Copy the data disk from temp VM to target VM
  echo "  Copying data disk: ${TEMP_SCSI1_ZVOL} → ${TARGET_ZVOL}..."
  if ! ssh_node "$HOSTING_IP" "dd if=/dev/zvol/${STORAGE_POOL}/data/${TEMP_SCSI1_ZVOL} of=/dev/zvol/${STORAGE_POOL}/data/${TARGET_ZVOL} bs=4M status=none"; then
    echo "  FAILED: dd failed — data disk may be corrupted"
    echo "  Temp VM 9999 preserved for manual recovery"
    echo "  DO NOT start VM ${VMID} — vdb is in an unknown state"
    add_ha_if_requested "$HOSTING_IP" "$VMID"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    continue
  fi

  # Clean up temp VM
  ssh_node "$HOSTING_IP" "qm destroy 9999 --purge" || true

  # Start VM and re-add HA
  if [[ "$LEAVE_STOPPED" -eq 1 ]]; then
    echo "  Restored; leaving VM stopped (--leave-stopped)"
  else
    echo "  Starting VM..."
  fi
  start_vm_if_requested "$HOSTING_IP" "$VMID"
  add_ha_if_requested "$HOSTING_IP" "$VMID"

  echo "  Restored ${VM_NAME} (VMID ${VMID})"
  RESTORE_COUNT=$((RESTORE_COUNT + 1))
done

echo ""
if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "=== Restore INCOMPLETE: ${RESTORE_COUNT} restored, ${FAIL_COUNT} FAILED ==="
  exit 1
fi
echo "=== Restore complete: ${RESTORE_COUNT} VM(s) restored ==="
