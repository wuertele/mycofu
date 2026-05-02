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
source framework/scripts/certbot-cluster.sh

drt_init

EXPECTED_ACME_MODE=$(certbot_cluster_expected_mode site/config.yaml)
EXPECTED_ACME_URL=$(certbot_cluster_expected_url site/config.yaml)

drt_check_certbot_lineage() {
  local vm_label="$1"
  local vm_ip="$2"
  local fqdn="$3"
  shift 3

  certbot_cluster_run_remote_helper \
    "${vm_ip}" \
    --mode check \
    --expected-acme-url "${EXPECTED_ACME_URL}" \
    --expected-mode "${EXPECTED_ACME_MODE}" \
    --fqdn "${fqdn}" \
    --label "${vm_label}" \
    "$@"
}

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

drt_step "Verifying restored cert lineage on live backup-backed prod/shared certbot VMs"
CERTBOT_LINEAGE_CHECKED=0
CERTBOT_LINEAGE_RECORDS=""
CERTBOT_LINEAGE_RECORDS_STATUS=0

set +e
CERTBOT_LINEAGE_RECORDS="$(certbot_cluster_prod_shared_backup_certbot_records site/config.yaml site/applications.yaml 2>&1)"
CERTBOT_LINEAGE_RECORDS_STATUS=$?
set -e

if [[ "${CERTBOT_LINEAGE_RECORDS_STATUS}" -ne 0 ]]; then
  drt_assert "backup-backed prod/shared certbot inventory is inspectable" false
  while IFS= read -r inventory_line; do
    [[ -z "${inventory_line}" ]] && continue
    echo "       ${inventory_line}"
  done <<< "${CERTBOT_LINEAGE_RECORDS}"
else
  while IFS=$'\t' read -r vm_label _ vm_ip _ fqdn _ _; do
    [[ -z "$vm_label" ]] && continue
    CERTBOT_LINEAGE_CHECKED=$((CERTBOT_LINEAGE_CHECKED + 1))
    if [[ "$vm_label" == "gitlab" && "$EXPECTED_ACME_MODE" == "production" ]]; then
      drt_assert "${vm_label} renewal lineage and live issuer are production-clean" \
        drt_check_certbot_lineage "${vm_label}" "${vm_ip}" "${fqdn}" --fail-on-fake-leaf
    else
      drt_assert "${vm_label} renewal lineage matches configured ACME URL" \
        drt_check_certbot_lineage "${vm_label}" "${vm_ip}" "${fqdn}"
    fi
  done <<< "${CERTBOT_LINEAGE_RECORDS}"
fi

if [[ "${CERTBOT_LINEAGE_RECORDS_STATUS}" -eq 0 && "$CERTBOT_LINEAGE_CHECKED" -eq 0 ]]; then
  echo "  [WARN] No backup-backed prod/shared certbot VMs detected for lineage checks"
fi

drt_step "Verifying state fingerprint"
drt_verify_state_fingerprint

drt_step "Checking elapsed time"
TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$(( TOTAL_END - DRT_START_EPOCH ))
printf "  Total elapsed: %dm %ds\n" $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
echo "  Baseline: ~20 min (2026-03-25)"

# ── Finish ───────────────────────────────────────────────────────────

drt_finish
