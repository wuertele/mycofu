#!/usr/bin/env bash
# backup-now.sh — Immediately back up all precious-state VMs to PBS.
#
# Usage:
#   framework/scripts/backup-now.sh
#
# Reads config.yaml for all VMs with backup: true (infrastructure and
# applications), finds which Proxmox node hosts each VM, runs vzdump.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.yaml not found: $CONFIG" >&2
  exit 1
fi

NODE_IPS=$(yq -r '.nodes[].mgmt_ip' "$CONFIG")

# Check PBS storage is available
PBS_AVAIL=""
for ip in $NODE_IPS; do
  if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${ip}" "pvesm status 2>/dev/null | grep -q pbs-nas" 2>/dev/null; then
    PBS_AVAIL="$ip"
    break
  fi
done

if [[ -z "$PBS_AVAIL" ]]; then
  echo "ERROR: PBS storage (pbs-nas) not registered on any node" >&2
  exit 1
fi

# Find and back up all precious VMs
TOTAL=0
FAILED=0

backup_vm() {
  local label="$1" vmid="$2"
  # Find hosting node
  local host_ip=""
  for ip in $NODE_IPS; do
    if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${ip}" "qm status ${vmid}" >/dev/null 2>&1; then
      host_ip="$ip"
      break
    fi
  done

  if [[ -z "$host_ip" ]]; then
    echo "  SKIP: ${label} (VMID ${vmid}) — not found on any node"
    return
  fi

  TOTAL=$((TOTAL + 1))
  echo "  ${label} (VMID ${vmid}) on ${host_ip}..."
  if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${host_ip}" \
      "vzdump ${vmid} --storage pbs-nas --mode snapshot --compress zstd --quiet 1" 2>&1; then
    echo "    Done"
  else
    echo "    WARNING: backup failed"
    FAILED=$((FAILED + 1))
  fi
}

echo "=== Backing up precious-state VMs ==="
echo ""

# Infrastructure VMs with backup: true
for vm_key in $(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG"); do
  vmid=$(yq -r ".vms.${vm_key}.vmid" "$CONFIG")
  backup_vm "$vm_key" "$vmid"
done

# Application VMs with backup: true
for app_key in $(yq -r '.applications | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$CONFIG" 2>/dev/null); do
  for env in prod dev; do
    vmid=$(yq -r ".applications.${app_key}.environments.${env}.vmid // \"\"" "$CONFIG")
    [[ -z "$vmid" || "$vmid" == "null" ]] && continue
    backup_vm "${app_key}_${env}" "$vmid"
  done
done

echo ""
if [[ $FAILED -eq 0 ]]; then
  echo "=== All ${TOTAL} backups complete ==="
else
  echo "=== ${TOTAL} attempted, ${FAILED} failed ==="
  exit 1
fi
