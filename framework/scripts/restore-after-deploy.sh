#!/usr/bin/env bash
# restore-after-deploy.sh — Restore vdb for precious VMs that were just recreated.
#
# Called by the pipeline after safe-apply.sh. Checks each precious-state VM
# to see if its vdb was freshly formatted (empty — no application data).
# Only restores VMs that need it. VMs with existing data are left alone.
#
# Usage:
#   framework/scripts/restore-after-deploy.sh <dev|prod>           # all precious VMs
#   framework/scripts/restore-after-deploy.sh <dev|prod> --vm vault # single VM
#
# Detection: a freshly formatted vdb has a filesystem but no role-specific
# data files. A vdb with real data has files like PG_VERSION, raft.db, etc.
# This avoids needing --force and avoids restoring VMs that weren't recreated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

ENV="${1:-}"
if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "Usage: $(basename "$0") <dev|prod> [--vm <name>]" >&2
  exit 1
fi
shift

TARGET_VM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm) TARGET_VM="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

ssh_node() {
  local ip="$1"; shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

# Detection: if a VM booted recently (< 10 minutes), it was just recreated
# by safe-apply.sh and needs restore. VMs that were not recreated have been
# running for hours/days and should not be touched.
#
# This is more reliable than file-based markers because some applications
# (InfluxDB, Roon) create data-like directory structure on first boot
# that is indistinguishable from real data.
MAX_UPTIME_SECONDS=600  # 10 minutes

vm_needs_restore() {
  local ip="$1"
  local uptime_seconds
  uptime_seconds=$(ssh_node "$ip" "cat /proc/uptime | cut -d. -f1" 2>/dev/null || echo "999999")
  [[ "$uptime_seconds" -lt "$MAX_UPTIME_SECONDS" ]]
}

RESTORED=0
FAILED=0

echo "=== Checking precious-state VMs for empty vdb ==="
echo ""

# Infrastructure VMs with backup: true
for vm_key in $(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG"); do
  # Filter by environment — vault_prod only in prod, vault_dev only in dev (skip if no env suffix match)
  if [[ "$vm_key" == *_prod && "$ENV" != "prod" ]]; then continue; fi
  if [[ "$vm_key" == *_dev && "$ENV" != "dev" ]]; then continue; fi
  # gitlab and pbs have no env suffix — they're shared, check both
  if [[ "$vm_key" != *_prod && "$vm_key" != *_dev && "$vm_key" != "gitlab" && "$vm_key" != "pbs" ]]; then continue; fi

  # Filter by --vm if specified (match role name without env suffix)
  if [[ -n "$TARGET_VM" ]]; then
    ROLE_NAME=$(echo "$vm_key" | sed 's/_prod$//;s/_dev$//')
    [[ "$ROLE_NAME" != "$TARGET_VM" && "$vm_key" != "$TARGET_VM" ]] && continue
  fi

  VM_IP=$(yq -r ".vms.${vm_key}.ip" "$CONFIG")
  [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue
  VMID=$(yq -r ".vms.${vm_key}.vmid" "$CONFIG")

  # Check if VM was recently recreated (booted < 10 minutes ago)
  if vm_needs_restore "$VM_IP"; then
    UPTIME=$(ssh_node "$VM_IP" "cat /proc/uptime | cut -d. -f1" 2>/dev/null || echo "?")
    echo "  ${vm_key}: recently recreated (uptime ${UPTIME}s) — restoring from PBS..."
    if "${SCRIPT_DIR}/restore-from-pbs.sh" --force --target "$VMID"; then
      RESTORED=$((RESTORED + 1))
    else
      echo "  ERROR: restore failed for ${vm_key}" >&2
      FAILED=$((FAILED + 1))
    fi
  else
    echo "  ${vm_key}: running (not recently recreated) — skipping"
  fi
done

# Application VMs with backup: true
for app_key in $(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null); do
  # Filter by --vm if specified
  if [[ -n "$TARGET_VM" && "$app_key" != "$TARGET_VM" ]]; then continue; fi

  VMID=$(yq -r ".applications.${app_key}.environments.${ENV}.vmid // \"\"" "$APPS_CONFIG")
  [[ -z "$VMID" || "$VMID" == "null" ]] && continue
  VM_IP=$(yq -r ".applications.${app_key}.environments.${ENV}.ip // \"\"" "$APPS_CONFIG")
  [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue

  if vm_needs_restore "$VM_IP"; then
    UPTIME=$(ssh_node "$VM_IP" "cat /proc/uptime | cut -d. -f1" 2>/dev/null || echo "?")
    echo "  ${app_key}_${ENV}: recently recreated (uptime ${UPTIME}s) — restoring from PBS..."
    if "${SCRIPT_DIR}/restore-from-pbs.sh" --force --target "$VMID"; then
      RESTORED=$((RESTORED + 1))
    else
      echo "  ERROR: restore failed for ${app_key}_${ENV}" >&2
      FAILED=$((FAILED + 1))
    fi
  else
    echo "  ${app_key}_${ENV}: running (not recently recreated) — skipping"
  fi
done

echo ""
if [[ $FAILED -gt 0 ]]; then
  echo "=== Restore INCOMPLETE: ${RESTORED} restored, ${FAILED} FAILED ==="
  exit 1
elif [[ $RESTORED -gt 0 ]]; then
  echo "=== Restored ${RESTORED} VM(s) ==="
else
  echo "=== No VMs needed restore (all have data) ==="
fi
