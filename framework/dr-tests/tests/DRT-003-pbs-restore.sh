#!/usr/bin/env bash
# DRT-ID: DRT-003
# DRT-NAME: PBS Restore
# DRT-TIME: ~20 min
# DRT-DESTRUCTIVE: yes
# DRT-DESC: Restore all precious-state VMs from their most recent PBS backups
#           and verify that data and services survive the restore cycle.

set -euo pipefail

DRT_ID="DRT-003"
DRT_NAME="PBS Restore"

source "$(dirname "$0")/../lib/common.sh"

drt_init

# ── Precious VMs to restore ─────────────────────────────────────────
# Infrastructure VMs with backup: true plus application VMs with backup: true.
# Each entry: "<config_key> <env_or_none>"
# drt_vm_vmid resolves the VMID from config.yaml or applications.yaml.

PRECIOUS_VMS=(
  "vault prod"
  "gitlab none"
  "influxdb prod"
  "roon prod"
)

# ── Preconditions ────────────────────────────────────────────────────

drt_check "validate.sh is green" framework/scripts/validate.sh

drt_check "PBS is reachable" \
  ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "root@$(drt_vm_ip pbs)" "true"

drt_check "restore-from-pbs.sh exists" test -x framework/scripts/restore-from-pbs.sh

drt_step "Verifying at least one PBS backup exists per precious VM"
ALL_BACKUPS_EXIST=0
for entry in ${PRECIOUS_VMS[@]+"${PRECIOUS_VMS[@]}"}; do
  # Split entry into name and env
  set -- $entry
  vm_name="$1"
  vm_env="$2"

  if [[ "$vm_env" == "none" ]]; then
    vmid=$(drt_vm_vmid "$vm_name")
  else
    vmid=$(drt_vm_vmid "$vm_name" "$vm_env")
  fi

  if [[ -z "$vmid" ]]; then
    echo "  [WARN] Could not resolve VMID for ${vm_name} (env=${vm_env})"
    ALL_BACKUPS_EXIST=1
    continue
  fi

  # Check if PBS has a backup for this VMID by querying any node
  FOUND_BACKUP=0
  for node_ip in $(yq -r '.nodes[].mgmt_ip' site/config.yaml); do
    if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        "root@${node_ip}" \
        "pvesh get /nodes/\$(hostname)/storage/pbs-nas/content --vmid ${vmid} --output-format json 2>/dev/null" \
        | jq -e 'length > 0' >/dev/null 2>&1; then
      FOUND_BACKUP=1
      break
    fi
  done

  if [[ $FOUND_BACKUP -eq 1 ]]; then
    echo "  [OK] Backup exists for ${vm_name} (VMID ${vmid})"
  else
    echo "  [MISSING] No backup found for ${vm_name} (VMID ${vmid})"
    ALL_BACKUPS_EXIST=1
  fi
done

if [[ $ALL_BACKUPS_EXIST -ne 0 ]]; then
  echo ""
  echo "WARNING: Not all precious VMs have backups."
  echo "         Proceeding — restore-from-pbs.sh will skip VMs without backups."
fi

# ── Pre-test ─────────────────────────────────────────────────────────

drt_step "Capturing pre-test state fingerprint"
drt_fingerprint_state
# No pre-test backup — we are testing the existing backups.

# ── Test ─────────────────────────────────────────────────────────────

drt_step "Restoring precious VMs from PBS"
for entry in ${PRECIOUS_VMS[@]+"${PRECIOUS_VMS[@]}"}; do
  set -- $entry
  vm_name="$1"
  vm_env="$2"

  if [[ "$vm_env" == "none" ]]; then
    vmid=$(drt_vm_vmid "$vm_name")
  else
    vmid=$(drt_vm_vmid "$vm_name" "$vm_env")
  fi

  if [[ -z "$vmid" ]]; then
    echo "  [SKIP] Cannot resolve VMID for ${vm_name} — skipping"
    continue
  fi

  echo ""
  echo "  Restoring ${vm_name} (VMID ${vmid})..."
  drt_assert "restore ${vm_name} (VMID ${vmid})" \
    framework/scripts/restore-from-pbs.sh --force --target "$vmid"
done

# ── Verification ─────────────────────────────────────────────────────

drt_step "Waiting for services to settle after restore"
echo "  Sleeping 30s for VMs to boot and services to start..."
sleep 30

drt_step "Running validate.sh"
drt_assert "validate.sh passes after PBS restore" framework/scripts/validate.sh

drt_step "Verifying state fingerprint"
drt_verify_state_fingerprint

drt_step "Checking elapsed time"
TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$(( TOTAL_END - DRT_START_EPOCH ))
printf "  Total elapsed: %dm %ds\n" $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
echo "  Baseline: ~20 min (2026-03-25)"

# ── Finish ───────────────────────────────────────────────────────────

drt_finish
