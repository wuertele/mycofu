#!/usr/bin/env bash
# backup-now.sh — Immediately back up all precious-state VMs to PBS.
#
# Usage:
#   framework/scripts/backup-now.sh
#   framework/scripts/backup-now.sh --env dev
#   framework/scripts/backup-now.sh --env all --verify
#   framework/scripts/backup-now.sh --env prod --pin-out build/restore-pin-prod.json
#
# Reads config.yaml for all VMs with backup: true (infrastructure and
# applications), checks that each selected VM is healthy enough to snapshot,
# then runs vzdump and records the exact PBS volid in a pin file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
source "${SCRIPT_DIR}/certbot-cluster.sh"
source "${SCRIPT_DIR}/vm-health-lib.sh"

BACKUP_ENV="all"
PIN_OUT="${REPO_DIR}/build/restore-pin.json"
VERIFY=0
PIN_MAP_FILE="$(mktemp "${TMPDIR:-/tmp}/backup-now-pins.XXXXXX")"
trap 'rm -f "${PIN_MAP_FILE}"' EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      BACKUP_ENV="$2"
      shift 2
      ;;
    --verify)
      VERIFY=1
      shift
      ;;
    --pin-out)
      PIN_OUT="$2"
      shift 2
      ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$BACKUP_ENV" != "dev" && "$BACKUP_ENV" != "prod" && "$BACKUP_ENV" != "all" ]]; then
  echo "ERROR: --env must be one of: dev, prod, all" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.yaml not found: $CONFIG" >&2
  exit 1
fi

mkdir -p "$(dirname "$PIN_OUT")"
jq -n --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{version: 1, captured_at: $captured_at, pins: {}}' > "$PIN_OUT"

NODE_IPS=$(yq -r '.nodes[].mgmt_ip' "$CONFIG")
STORAGE_POOL=$(yq -r '.proxmox.storage_pool // "vmstore"' "$CONFIG")
export VM_HEALTH_STORAGE_POOL="$STORAGE_POOL"
FIRST_DEPLOY_SKIP_VMIDS=""

backup_env_matches_label() {
  local label="$1"

  case "$BACKUP_ENV" in
    all)
      return 0
      ;;
  esac

  # Env-scoped CI backups intentionally stop at the Tier 1/Tier 2 boundary.
  # The pipeline cannot recreate gitlab/cicd/pbs, so letting their health
  # block a dev/prod data-plane deploy adds coupling without a restore path.
  # `--env all` remains the workstation flow for full-cluster backups.
  case "$label" in
    gitlab|cicd|pbs)
      return 1
      ;;
  esac

  case "$BACKUP_ENV" in
    dev)
      [[ "$label" != *_prod ]]
      ;;
    prod)
      [[ "$label" != *_dev ]]
      ;;
  esac
}

mark_first_deploy_skip() {
  local vmid="$1"

  case " ${FIRST_DEPLOY_SKIP_VMIDS} " in
    *" ${vmid} "*)
      ;;
    *)
      FIRST_DEPLOY_SKIP_VMIDS="${FIRST_DEPLOY_SKIP_VMIDS} ${vmid}"
      ;;
  esac
}

first_deploy_skip_marked() {
  local vmid="$1"

  case " ${FIRST_DEPLOY_SKIP_VMIDS} " in
    *" ${vmid} "*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

find_host_ip_for_vmid() {
  local vmid="$1"
  local ip=""

  for ip in $NODE_IPS; do
    if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${ip}" "qm status ${vmid}" >/dev/null 2>&1; then
      echo "$ip"
      return 0
    fi
  done

  return 1
}

collect_backup_records() {
  local vm_key=""
  local app_key=""
  local env_key=""
  local vmid=""
  local vm_ip=""
  local label=""

  while IFS= read -r vm_key; do
    [[ -z "$vm_key" ]] && continue
    label="$vm_key"
    backup_env_matches_label "$label" || continue
    vmid=$(yq -r ".vms.${vm_key}.vmid" "$CONFIG")
    vm_ip=$(yq -r ".vms.${vm_key}.ip" "$CONFIG")
    printf '%s\t%s\t%s\t%s\n' "$vm_key" "$label" "$vmid" "$vm_ip"
  done < <(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG")

  while IFS= read -r app_key; do
    [[ -z "$app_key" ]] && continue
    while IFS= read -r env_key; do
      [[ -z "$env_key" ]] && continue
      label="${app_key}_${env_key}"
      backup_env_matches_label "$label" || continue
      vmid=$(yq -r ".applications.${app_key}.environments.${env_key}.vmid // \"\"" "$APPS_CONFIG")
      # Prefer the management NIC when present: backup health checks run from
      # the management network, and some apps intentionally expose SSH there.
      vm_ip=$(yq -r ".applications.${app_key}.environments.${env_key}.mgmt_nic.ip // .applications.${app_key}.environments.${env_key}.ip // \"\"" "$APPS_CONFIG")
      [[ -z "$vmid" || "$vmid" == "null" || -z "$vm_ip" || "$vm_ip" == "null" ]] && continue
      printf '%s\t%s\t%s\t%s\n' "$label" "$label" "$vmid" "$vm_ip"
    done < <(yq -r ".applications.${app_key}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null)
  done < <(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null)
}

pbs_content_json() {
  ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${PBS_AVAIL}" \
    "pvesh get /nodes/\$(hostname)/storage/pbs-nas/content --output-format json 2>/dev/null"
}

pbs_historical_backup_exists() {
  local vmid="$1"
  local json="$2"

  if jq -e --arg vmid "$vmid" 'any(.[]?; (.vmid | tostring) == $vmid)' >/dev/null 2>&1 <<< "$json"; then
    return 0
  fi

  if jq empty >/dev/null 2>&1 <<< "$json"; then
    return 1
  fi

  echo "ERROR: Could not parse PBS content JSON while checking VMID ${vmid}" >&2
  exit 1
}

capture_new_backup_volids() {
  local before_json="$1"
  local after_json="$2"
  local vmid="$3"

  BEFORE_JSON="$before_json" AFTER_JSON="$after_json" TARGET_VMID="$vmid" python3 - <<'PY'
import json
import os

vmid = int(os.environ["TARGET_VMID"])
before = {
    entry.get("volid")
    for entry in json.loads(os.environ["BEFORE_JSON"])
    if entry.get("vmid") == vmid and entry.get("volid")
}
after = sorted(
    {
        entry.get("volid")
        for entry in json.loads(os.environ["AFTER_JSON"])
        if entry.get("vmid") == vmid and entry.get("volid")
    }
    - before
)
for volid in after:
    print(volid)
PY
}

pin_file_set() {
  local vmid="$1"
  local volid="$2"
  local tmp_file=""

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/restore-pin.XXXXXX")"
  jq --arg vmid "$vmid" --arg volid "$volid" '.pins[$vmid] = $volid' "$PIN_OUT" > "$tmp_file"
  mv "$tmp_file" "$PIN_OUT"
}

pin_map_set() {
  local vmid="$1"
  local volid="$2"

  printf '%s\t%s\n' "$vmid" "$volid" >> "$PIN_MAP_FILE"
}

pin_file_write_from_map() {
  local vmid=""
  local volid=""
  local tmp_file=""

  while IFS=$'\t' read -r vmid volid; do
    [[ -z "$vmid" || -z "$volid" ]] && continue
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/restore-pin.XXXXXX")"
    jq --arg vmid "$vmid" --arg volid "$volid" '.pins[$vmid] = $volid' "$PIN_OUT" > "$tmp_file"
    mv "$tmp_file" "$PIN_OUT"
  done < "$PIN_MAP_FILE"
}

pbs_backup_record_for_volid() {
  local json="$1"
  local volid="$2"

  jq -c --arg volid "$volid" 'first(.[]? | select(.volid == $volid)) // empty' <<< "$json"
}

pbs_backup_verify_state() {
  local record_json="$1"

  jq -r '
    if has("verification") then
      if (.verification | type) == "object" then
        (.verification.state // .verification.status // "")
      else
        (.verification | tostring)
      end
    elif has("verify-state") then
      .["verify-state"] | tostring
    elif has("verify_status") then
      .verify_status | tostring
    elif has("verified") then
      if .verified == true then "ok" else "failed" end
    else
      ""
    end
  ' <<< "$record_json"
}

verify_backup_pins() {
  local content_json="$1"
  local vmid=""
  local volid=""
  local record_json=""
  local verify_state=""
  local verify_state_lc=""
  local failures=0
  local verified=0

  echo "=== Verifying PBS metadata for new backups ==="
  while IFS=$'\t' read -r vmid volid; do
    [[ -z "$vmid" || -z "$volid" ]] && continue
    verified=$((verified + 1))
    record_json="$(pbs_backup_record_for_volid "$content_json" "$volid")"
    if [[ -z "$record_json" ]]; then
      echo "  FAILED: VMID ${vmid} — ${volid} not found in PBS content list"
      failures=$((failures + 1))
      continue
    fi

    if ! jq -e '(.size // 0 | tonumber? // 0) > 0' >/dev/null 2>&1 <<< "$record_json"; then
      echo "  FAILED: VMID ${vmid} — ${volid} has size 0 or missing size metadata"
      failures=$((failures + 1))
      continue
    fi

    verify_state="$(pbs_backup_verify_state "$record_json")"
    if [[ -n "$verify_state" ]]; then
      verify_state_lc="$(printf '%s' "$verify_state" | tr '[:upper:]' '[:lower:]')"
      case "$verify_state_lc" in
        ok|success|successful|passed|verified)
          ;;
        *)
          echo "  FAILED: VMID ${vmid} — ${volid} verification state is '${verify_state}'"
          failures=$((failures + 1))
          continue
          ;;
      esac
    fi

    echo "  OK: VMID ${vmid} — ${volid}"
  done < "$PIN_MAP_FILE"

  if [[ "$verified" -eq 0 ]]; then
    echo "  No new backup pins to verify"
    return 0
  fi

  if [[ "$failures" -gt 0 ]]; then
    echo "ERROR: PBS metadata verification failed for ${failures} backup(s)." >&2
    return 1
  fi

  echo "=== Verified ${verified} backup(s) in PBS metadata ==="
  return 0
}

backup_vm() {
  local vm_key="$1"
  local label="$2"
  local vmid="$3"
  local vm_ip="$4"
  local host_ip=""
  local before_json=""
  local after_json=""
  local backup_output=""
  local new_volids=""
  local pin_count=""
  local volid=""

  if first_deploy_skip_marked "$vmid"; then
    echo "  SKIP: ${label} (VMID ${vmid}) — first deploy (no historical PBS backup)"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  if host_ip="$(find_host_ip_for_vmid "$vmid")"; then
    :
  else
    if pbs_historical_backup_exists "$vmid" "$EXISTING_PBS_JSON"; then
      echo "  FAILED: ${label} (VMID ${vmid}) — not found on any node but historical PBS backups exist"
      FAILED=$((FAILED + 1))
    else
      echo "  SKIP: ${label} (VMID ${vmid}) — first deploy (no historical PBS backup)"
      SKIPPED=$((SKIPPED + 1))
    fi
    return
  fi

  if before_json="$(pbs_content_json)"; then
    :
  else
    echo "  FAILED: ${label} (VMID ${vmid}) — could not query PBS content before backup"
    FAILED=$((FAILED + 1))
    return
  fi

  TOTAL=$((TOTAL + 1))
  echo "  ${label} (VMID ${vmid}) on ${host_ip}..."
  if backup_output="$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${host_ip}" \
      "vzdump ${vmid} --storage pbs-nas --mode snapshot --compress zstd --quiet 1" 2>&1)"; then
    :
  else
    echo "    WARNING: backup failed"
    if [[ -n "$backup_output" ]]; then
      printf '%s\n' "$backup_output" | sed 's/^/      /'
    fi
    FAILED=$((FAILED + 1))
    return
  fi

  if after_json="$(pbs_content_json)"; then
    :
  else
    echo "    WARNING: backup completed but PBS content could not be queried afterwards"
    FAILED=$((FAILED + 1))
    return
  fi

  if new_volids="$(capture_new_backup_volids "$before_json" "$after_json" "$vmid")"; then
    :
  else
    echo "    WARNING: backup completed but pin extraction failed"
    FAILED=$((FAILED + 1))
    return
  fi
  pin_count=$(printf '%s\n' "$new_volids" | sed '/^$/d' | wc -l | tr -d ' ')

  if [[ "$pin_count" != "1" ]]; then
    echo "    WARNING: expected exactly one new PBS backup for VMID ${vmid}, found ${pin_count}"
    if [[ -n "$new_volids" ]]; then
      printf '%s\n' "$new_volids" | sed 's/^/      /'
    fi
    FAILED=$((FAILED + 1))
    return
  fi

  volid="$(printf '%s\n' "$new_volids" | sed -n '1p')"
  if [[ "$VERIFY" -eq 1 ]]; then
    if pin_map_set "$vmid" "$volid"; then
      echo "    Done"
      echo "    Pin: ${volid}"
    else
      echo "    WARNING: backup succeeded but pin map update failed"
      FAILED=$((FAILED + 1))
    fi
  else
    if pin_file_set "$vmid" "$volid"; then
      echo "    Done"
      echo "    Pin: ${volid}"
    else
      echo "    WARNING: backup succeeded but pin file update failed"
      FAILED=$((FAILED + 1))
    fi
  fi
}

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

if EXISTING_PBS_JSON="$(pbs_content_json)"; then
  :
else
  echo "ERROR: Could not query PBS content to verify historical backups" >&2
  exit 1
fi

HEALTH_FAILURES=0
HEALTH_CHECKED=0
echo "=== Checking VM health on backup-backed VMs ==="
while IFS=$'\t' read -r vm_key label vmid vm_ip; do
  [[ -z "$label" ]] && continue
  HEALTH_CHECKED=$((HEALTH_CHECKED + 1))

  HAS_HISTORY=0
  if pbs_historical_backup_exists "$vmid" "$EXISTING_PBS_JSON"; then
    HAS_HISTORY=1
  fi

  host_ip=""
  if host_ip="$(find_host_ip_for_vmid "$vmid")"; then
    :
  else
    if [[ "$HAS_HISTORY" -eq 1 ]]; then
      echo "  FAILED: ${label} (not found on any node; historical PBS backups exist)"
      HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
    else
      mark_first_deploy_skip "$vmid"
      echo "  SKIP: ${label} — first deploy (unreachable and no historical PBS backup)"
    fi
    continue
  fi

  if vm_health_check "$vm_key" "$label" "$vm_ip" "$host_ip" "$vmid"; then
    echo "  OK: ${label}"
  else
    if [[ "$HAS_HISTORY" -eq 0 ]]; then
      mark_first_deploy_skip "$vmid"
      echo "  SKIP: ${label} — first deploy (${VM_HEALTH_LAST_REASON})"
    else
      echo "  FAILED: ${label} (${VM_HEALTH_LAST_REASON})"
      HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
    fi
  fi
done < <(collect_backup_records)

if [[ "$HEALTH_CHECKED" -eq 0 ]]; then
  echo "  No backup-backed VMs matched --env ${BACKUP_ENV}"
fi

if [[ "$HEALTH_FAILURES" -gt 0 ]]; then
  echo "ERROR: Refusing backup while ${HEALTH_FAILURES} VM(s) failed health check." >&2
  exit 1
fi
echo ""

SITE_ACME_MODE="$(certbot_cluster_expected_mode "${CONFIG}")"
if [[ "${SITE_ACME_MODE}" == "production" && "$BACKUP_ENV" != "dev" ]]; then
  EXPECTED_ACME_URL="$(certbot_cluster_expected_url "${CONFIG}")"
  LINEAGE_FAILURES=0
  LINEAGE_CHECKED=0
  BACKUP_CERTBOT_RECORDS=""

  echo "=== Checking persisted certbot lineage on backup-backed prod/shared VMs ==="
  if ! BACKUP_CERTBOT_RECORDS="$(certbot_cluster_prod_shared_backup_certbot_records "${CONFIG}" "${APPS_CONFIG}")"; then
    echo "ERROR: Refusing backup because a backup-backed prod/shared certbot VM could not be inspected." >&2
    exit 1
  fi

  while IFS=$'\t' read -r vm_label _ vm_ip _ fqdn _ _; do
    [[ -z "${vm_label}" ]] && continue
    LINEAGE_CHECKED=$((LINEAGE_CHECKED + 1))
    if certbot_cluster_run_remote_helper \
      "${vm_ip}" \
      --mode check \
      --expected-acme-url "${EXPECTED_ACME_URL}" \
      --expected-mode production \
      --fqdn "${fqdn}" \
      --label "${vm_label}"; then
      echo "  OK: ${vm_label} (${fqdn})"
    else
      echo "  FAILED: ${vm_label} (${fqdn})"
      LINEAGE_FAILURES=$((LINEAGE_FAILURES + 1))
    fi
  done <<< "${BACKUP_CERTBOT_RECORDS}"

  if [[ "${LINEAGE_CHECKED}" -eq 0 ]]; then
    echo "  No backup-backed prod/shared certbot VMs detected"
  fi

  if [[ "${LINEAGE_FAILURES}" -gt 0 ]]; then
    echo "ERROR: Refusing backup while backup-backed prod/shared certbot lineage is not clean." >&2
    exit 1
  fi
  echo ""
fi

TOTAL=0
FAILED=0
SKIPPED=0

echo "=== Backing up precious-state VMs ==="
echo ""
while IFS=$'\t' read -r vm_key label vmid vm_ip; do
  [[ -z "$label" ]] && continue
  backup_vm "$vm_key" "$label" "$vmid" "$vm_ip"
done < <(collect_backup_records)

echo ""
if [[ $FAILED -eq 0 ]]; then
  if [[ "$VERIFY" -eq 1 ]]; then
    if FINAL_PBS_JSON="$(pbs_content_json)"; then
      :
    else
      echo "ERROR: Could not query PBS content to verify new backups" >&2
      exit 1
    fi

    verify_backup_pins "$FINAL_PBS_JSON"
    pin_file_write_from_map
  fi
  echo "=== All ${TOTAL} backups complete (${SKIPPED} skipped) ==="
else
  echo "=== ${TOTAL} attempted, ${FAILED} failed, ${SKIPPED} skipped ==="
  exit 1
fi
