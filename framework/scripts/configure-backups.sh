#!/usr/bin/env bash
# configure-backups.sh — Create Proxmox scheduled backup jobs for VMs with precious state.
#
# Reads config.yaml to find VMs with backup: true, looks up their VMIDs
# via the Proxmox API, and creates a single vzdump backup job targeting
# all of them. Uses the PBS storage and schedule from config.yaml.
#
# Usage:
#   framework/scripts/configure-backups.sh
#   framework/scripts/configure-backups.sh --verify   # Check only, don't create
#
# Idempotent: if a backup job already exists covering all required VMIDs,
# it is left unchanged. If the VMID set changes, the job is updated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

VERIFY_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) VERIFY_ONLY=1; shift ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 1
fi

FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
BACKUP_SCHEDULE=$(yq -r '.pbs.backup_schedule // "02:00"' "$CONFIG")

# Find VMs with backup: true (infrastructure VMs)
BACKUP_VMS=$(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG")

# Also find catalog applications with backup: true
# Applications have per-environment VMs named <app>_<env>
APP_BACKUP_VMS=$(yq -r '
  .applications // {} | to_entries[] |
  select(.value.enabled == true and .value.backup == true) |
  .key as $app | .value.environments | keys[] |
  $app + "_" + .
' "$APPS_CONFIG" 2>/dev/null || true)
if [[ -n "$APP_BACKUP_VMS" ]]; then
  BACKUP_VMS="${BACKUP_VMS}
${APP_BACKUP_VMS}"
fi

if [[ -z "$BACKUP_VMS" ]]; then
  echo "No VMs with backup: true in config.yaml"
  exit 0
fi

echo "VMs marked for backup:"
for vm_key in $BACKUP_VMS; do
  echo "  ${vm_key}"
done
echo ""

# Resolve VM names to VMIDs via the Proxmox API
# VM keys in config use underscores (vault_prod), Proxmox names use hyphens (vault-prod)
ALL_VMS_JSON=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null)

BACKUP_VMIDS=""
MISSING=0
for vm_key in $BACKUP_VMS; do
  # Convert config key to Proxmox name: vault_prod -> vault-prod
  vm_name=$(echo "$vm_key" | tr '_' '-')
  vmid=$(echo "$ALL_VMS_JSON" | jq -r --arg name "$vm_name" \
    '.[] | select(.name == $name) | .vmid' 2>/dev/null)
  if [[ -z "$vmid" || "$vmid" == "null" ]]; then
    echo "WARNING: VM '${vm_name}' not found in cluster — skipping"
    MISSING=$((MISSING + 1))
    continue
  fi
  echo "  ${vm_name} -> VMID ${vmid}"
  if [[ -n "$BACKUP_VMIDS" ]]; then
    BACKUP_VMIDS="${BACKUP_VMIDS},${vmid}"
  else
    BACKUP_VMIDS="${vmid}"
  fi
done
echo ""

if [[ -z "$BACKUP_VMIDS" ]]; then
  echo "ERROR: No VMs resolved to VMIDs — cannot create backup job" >&2
  exit 1
fi

# Sort VMIDs for consistent comparison
BACKUP_VMIDS_SORTED=$(echo "$BACKUP_VMIDS" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//')

# Check existing backup jobs
EXISTING_JOBS=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/backup --output-format json" 2>/dev/null || echo "[]")

# Look for a job targeting pbs-nas storage
EXISTING_PBS_JOB=$(echo "$EXISTING_JOBS" | jq -r \
  '[.[] | select(.storage == "pbs-nas")] | first // empty')

if [[ -n "$EXISTING_PBS_JOB" ]]; then
  EXISTING_VMIDS=$(echo "$EXISTING_PBS_JOB" | jq -r '.vmid // ""')
  EXISTING_ID=$(echo "$EXISTING_PBS_JOB" | jq -r '.id // ""')
  EXISTING_VMIDS_SORTED=$(echo "$EXISTING_VMIDS" | tr ',' '\n' | sort -n | tr '\n' ',' | sed 's/,$//')

  if [[ "$EXISTING_VMIDS_SORTED" == "$BACKUP_VMIDS_SORTED" ]]; then
    echo "Backup job already exists with correct VMIDs (${BACKUP_VMIDS_SORTED})"
    echo "  Job ID: ${EXISTING_ID}"
    echo "  Schedule: $(echo "$EXISTING_PBS_JOB" | jq -r '.schedule // "unknown"')"
    exit 0
  else
    echo "Backup job exists but VMIDs differ:"
    echo "  Current:  ${EXISTING_VMIDS_SORTED}"
    echo "  Expected: ${BACKUP_VMIDS_SORTED}"

    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
      echo "VERIFY FAILED: backup job VMIDs do not match config" >&2
      exit 1
    fi

    echo "Updating backup job ${EXISTING_ID}..."
    ssh -n "root@${FIRST_NODE_IP}" \
      "pvesh set /cluster/backup/${EXISTING_ID} \
        --vmid '${BACKUP_VMIDS_SORTED}' \
        --schedule '${BACKUP_SCHEDULE}'" 2>&1
    echo "Backup job updated"
    exit 0
  fi
fi

# No existing job — verify or create
if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  echo "VERIFY FAILED: no backup job exists for VMs with precious state" >&2
  exit 1
fi

echo "Creating backup job..."
echo "  VMIDs: ${BACKUP_VMIDS_SORTED}"
echo "  Storage: pbs-nas"
echo "  Schedule: ${BACKUP_SCHEDULE}"
echo "  Mode: snapshot"
echo "  Compression: zstd"

ssh -n "root@${FIRST_NODE_IP}" \
  "pvesh create /cluster/backup \
    --storage pbs-nas \
    --schedule '${BACKUP_SCHEDULE}' \
    --vmid '${BACKUP_VMIDS_SORTED}' \
    --mode snapshot \
    --compress zstd \
    --enabled 1 \
    --notes-template 'Precious state — automated by configure-backups.sh'" 2>&1

echo ""
echo "Backup job created successfully"
