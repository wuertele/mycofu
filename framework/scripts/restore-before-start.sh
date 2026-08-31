#!/usr/bin/env bash
# restore-before-start.sh — Restore precious vdb state before VMs are started.
#
# Usage:
#   restore-before-start.sh <dev|prod|all> \
#     --manifest build/preboot-restore-<scope>.json \
#     --pin-file build/restore-pin-<env>.json \
#     [--park-status build/vdb-park-status-<env>.json] \
#     [--first-deploy-allow-file build/first-deploy-allow-<env>.json] \
#     [--recovery-mode]
#
# This script is part of the deploy path. It restores vdb while target VMs are
# stopped and HA resources are absent, then leaves VMs stopped for the second
# OpenTofu apply to start/register them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CALLER_CWD="$(pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
# shellcheck source=framework/scripts/vm-topology-lib.sh
source "${SCRIPT_DIR}/vm-topology-lib.sh"
VDB_PARK_CONFIG="$CONFIG"
# shellcheck source=framework/scripts/vdb-park-lib.sh
source "${SCRIPT_DIR}/vdb-park-lib.sh"

SCOPE="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

MANIFEST=""
PIN_FILE=""
PARK_STATUS_FILE=""
BACKUP_ID=""
FIRST_DEPLOY_ALLOW_FILE=""
STATUS_FILE=""
RECOVERY_MODE=0

usage() {
  sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
}

resolve_path() {
  local path="$1"

  if [[ -z "$path" ]]; then
    return 0
  fi
  if [[ "$path" == /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "${CALLER_CWD}/${path}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      MANIFEST="$(resolve_path "$2")"
      shift 2
      ;;
    --pin-file)
      PIN_FILE="$(resolve_path "$2")"
      shift 2
      ;;
    --park-status)
      PARK_STATUS_FILE="$(resolve_path "$2")"
      shift 2
      ;;
    --backup-id)
      BACKUP_ID="$2"
      shift 2
      ;;
    --first-deploy-allow-file)
      FIRST_DEPLOY_ALLOW_FILE="$(resolve_path "$2")"
      shift 2
      ;;
    --status-file)
      STATUS_FILE="$(resolve_path "$2")"
      shift 2
      ;;
    --recovery-mode)
      RECOVERY_MODE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SCOPE" != "dev" && "$SCOPE" != "prod" && "$SCOPE" != "all" ]]; then
  echo "ERROR: scope must be one of: dev, prod, all" >&2
  usage >&2
  exit 2
fi

if [[ -z "$MANIFEST" ]]; then
  echo "ERROR: --manifest is required" >&2
  exit 2
fi

if [[ -z "$PIN_FILE" ]]; then
  PIN_FILE="${REPO_DIR}/build/restore-pin-${SCOPE}.json"
fi

if [[ -z "$FIRST_DEPLOY_ALLOW_FILE" ]]; then
  FIRST_DEPLOY_ALLOW_FILE="${REPO_DIR}/build/first-deploy-allow-${SCOPE}.json"
fi

if [[ -z "$STATUS_FILE" ]]; then
  STATUS_FILE="${REPO_DIR}/build/preboot-restore-status-${SCOPE}.json"
fi

if [[ "$RECOVERY_MODE" -eq 1 && -z "$PARK_STATUS_FILE" ]]; then
  PARK_STATUS_FILE="${REPO_DIR}/build/vdb-park-status-${SCOPE}.json"
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.yaml not found: $CONFIG" >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  exit 1
fi

validate_manifest() {
  jq -e '
    def entries: if type == "array" then . else .entries end;
    (entries | type == "array") and
    all(entries[]?;
      (.label | type == "string") and
      (.module | type == "string") and
      ((.vmid | type == "number") or ((.vmid | type == "string") and (.vmid | test("^[0-9]+$")))) and
      (.env | type == "string") and
      (.kind | type == "string") and
      (.reason | type == "string") and
      ((.expected_disks | not) or (.expected_disks | type == "array"))
    )
  ' "$MANIFEST" >/dev/null
}

if ! jq empty "$MANIFEST" >/dev/null 2>&1; then
  echo "ERROR: malformed manifest JSON: $MANIFEST" >&2
  exit 1
fi

if ! validate_manifest; then
  echo "ERROR: manifest schema invalid: $MANIFEST" >&2
  echo "Required fields: label, module, vmid, env, kind, reason" >&2
  exit 1
fi

if [[ -f "$PIN_FILE" ]]; then
  if ! jq -e 'type == "object" and (.pins | type == "object")' "$PIN_FILE" >/dev/null 2>&1; then
    echo "ERROR: invalid restore pin file: $PIN_FILE" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$STATUS_FILE")"
STATUS_TMP="$(mktemp "${TMPDIR:-/tmp}/preboot-restore-status.XXXXXX")"
trap 'rm -f "$STATUS_TMP"' EXIT

jq -n \
  --arg scope "$SCOPE" \
  --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson recovery_mode "$RECOVERY_MODE" \
  '{version: 1, scope: $scope, generated_at: $generated_at, recovery_mode: ($recovery_mode == 1), entries: []}' \
  > "$STATUS_TMP"

status_add() {
  local label="$1"
  local vmid="$2"
  local env="$3"
  local status="$4"
  local reason="$5"
  local message="$6"
  local pin="${7:-}"
  local tmp=""

  tmp="$(mktemp "${TMPDIR:-/tmp}/preboot-restore-status.XXXXXX")"
  jq \
    --arg label "$label" \
    --arg vmid "$vmid" \
    --arg env "$env" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg message "$message" \
    --arg pin "$pin" \
    '.entries += [{
      label: $label,
      vmid: ($vmid | tonumber),
      env: $env,
      status: $status,
      reason: $reason,
      message: $message,
      pin: (if $pin == "" then null else $pin end)
    }]' "$STATUS_TMP" > "$tmp"
  mv "$tmp" "$STATUS_TMP"
}

write_status_file() {
  cp "$STATUS_TMP" "$STATUS_FILE"
}

ssh_node() {
  local ip="$1"; shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

FIRST_NODE_IP="$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")"

node_ip_for_name() {
  local node_name="$1"
  yq -r ".nodes[] | select(.name == \"${node_name}\") | .mgmt_ip" "$CONFIG"
}

cluster_resources_json() {
  ssh_node "$FIRST_NODE_IP" \
    "pvesh get /cluster/resources --type vm --output-format json"
}

hosting_node_for_vmid() {
  local vmid="$1"

  jq -r --argjson vmid "$vmid" \
    'first(.[]? | select(.vmid == $vmid) | .node) // empty' <<< "$CLUSTER_RESOURCES_JSON"
}

vm_status() {
  local node_ip="$1"
  local vmid="$2"

  ssh_node "$node_ip" "qm status ${vmid} 2>/dev/null | awk '{print \$2}'" || true
}

ha_resource_present() {
  local vmid="$1"

  ssh_node "$FIRST_NODE_IP" "ha-manager status" | grep -Fq "vm:${vmid}"
}

remove_ha_if_allowed() {
  local node_ip="$1"
  local vmid="$2"

  if [[ "${PREBOOT_RESTORE_REMOVE_HA:-0}" != "1" ]]; then
    return 1
  fi

  echo "  ${vmid}: HA resource present; removing because PREBOOT_RESTORE_REMOVE_HA=1"
  ssh_node "$node_ip" "ha-manager remove vm:${vmid}"
}

pin_for_vmid() {
  local vmid="$1"
  local manifest_pin="$2"

  if [[ -n "$BACKUP_ID" ]]; then
    printf '%s\n' "$BACKUP_ID"
    return 0
  fi

  if [[ -f "$PIN_FILE" ]]; then
    jq -r --arg vmid "$vmid" '(.pins[$vmid] // "") | if type == "object" then (.volid // "") else . end' "$PIN_FILE"
    return 0
  fi

  printf '%s\n' "$manifest_pin"
}

verify_vm_complete_for_entry() {
  local label="$1"
  local vmid="$2"
  local env="$3"
  local expected_disk_csv="$4"
  local reason="$5"
  local pin="${6:-}"
  local output rc

  [[ -n "$expected_disk_csv" ]] || return 0

  set +e
  output="$(vm_is_complete "$vmid" "$expected_disk_csv" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "  ${label}: topology complete (${expected_disk_csv})"
    return 0
  fi

  echo "  ERROR: ${output}" >&2
  if [[ "$rc" -eq "$VM_TOPOLOGY_RC_INCOMPLETE" ]]; then
    status_add "$label" "$vmid" "$env" "incomplete" "$reason" "$output" "$pin"
    INCOMPLETE=1
  else
    status_add "$label" "$vmid" "$env" "unverifiable" "$reason" "$output" "$pin"
    FAILED=1
  fi
  return 1
}

PBS_CONTENT_JSON=""
PBS_QUERIED=0
PVESM_STATUS=""
PVESM_QUERIED=0
PBS_STORAGE_STATE=""

pbs_storage_state() {
  if [[ "$PVESM_QUERIED" -eq 0 ]]; then
    local status_rc=0
    PVESM_STATUS="$(ssh_node "$FIRST_NODE_IP" "pvesm status 2>/dev/null")" || status_rc=$?
    PVESM_QUERIED=1
    if [[ "$status_rc" -ne 0 ]]; then
      PBS_STORAGE_STATE="query-failed"
      echo "ERROR: Could not query Proxmox storage status from ${FIRST_NODE_IP}" >&2
      return 2
    fi
    if grep -Eq '(^|[[:space:]])pbs-nas([[:space:]]|$)' <<< "$PVESM_STATUS"; then
      PBS_STORAGE_STATE="present"
    else
      PBS_STORAGE_STATE="absent"
    fi
  fi

  case "$PBS_STORAGE_STATE" in
    present)
      return 0
      ;;
    absent)
      return 1
      ;;
    query-failed)
      return 2
      ;;
  esac

  echo "ERROR: Internal PBS storage state error" >&2
  return 2
}

pbs_content_json() {
  if [[ "$PBS_QUERIED" -eq 0 ]]; then
    local storage_rc=0
    if pbs_storage_state; then
      storage_rc=0
    else
      storage_rc=$?
    fi
    if [[ "$storage_rc" -eq 1 ]]; then
      echo "ERROR: PBS storage (pbs-nas) is not registered in Proxmox" >&2
      return 1
    fi
    if [[ "$storage_rc" -ne 0 ]]; then
      return 1
    fi

    local query_rc=0
    PBS_CONTENT_JSON="$(ssh_node "$FIRST_NODE_IP" \
      "pvesh get /nodes/\$(hostname)/storage/pbs-nas/content --output-format json 2>/dev/null")" || query_rc=$?
    if [[ "$query_rc" -ne 0 ]]; then
      echo "ERROR: Could not query PBS content from Proxmox storage pbs-nas" >&2
      return 1
    fi
    if ! jq -e 'type == "array"' <<< "$PBS_CONTENT_JSON" >/dev/null 2>&1; then
      echo "ERROR: PBS content query returned invalid JSON" >&2
      return 1
    fi
    PBS_QUERIED=1
  fi
  printf '%s\n' "$PBS_CONTENT_JSON"
}

latest_backup_for_vmid() {
  local vmid="$1"
  local content=""

  content="$(pbs_content_json)" || return 1
  jq -r --argjson vmid "$vmid" '
    [ .[]? | select(.vmid == $vmid and (.volid // "") != "") ]
    | sort_by(.ctime // 0)
    | last
    | .volid // empty
  ' <<< "$content"
}

normalize_first_deploy_allow_file() {
  local allow_csv="${FIRST_DEPLOY_ALLOW_VMIDS:-}"
  local allow_json_tmp=""

  if [[ -z "$allow_csv" ]]; then
    return 0
  fi

  mkdir -p "$(dirname "$FIRST_DEPLOY_ALLOW_FILE")"
  allow_json_tmp="$(mktemp "${TMPDIR:-/tmp}/first-deploy-allow.XXXXXX")"
  ALLOW_CSV="$allow_csv" python3 - <<'PY' > "$allow_json_tmp"
import json
import os
import re
from datetime import datetime, timezone

vmids = []
seen = set()
for item in re.split(r"[,\s]+", os.environ.get("ALLOW_CSV", "")):
    if not item:
        continue
    if not re.fullmatch(r"\d+", item):
        raise SystemExit(f"invalid FIRST_DEPLOY_ALLOW_VMIDS entry: {item}")
    if item not in seen:
        seen.add(item)
        vmids.append(int(item))

print(json.dumps({
    "version": 1,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "source": "FIRST_DEPLOY_ALLOW_VMIDS",
    "vmids": vmids,
}, indent=2))
PY
  mv "$allow_json_tmp" "$FIRST_DEPLOY_ALLOW_FILE"
}

normalize_first_deploy_allow_file

if [[ -f "$FIRST_DEPLOY_ALLOW_FILE" ]]; then
  if ! jq -e 'type == "object" and (.vmids | type == "array")' "$FIRST_DEPLOY_ALLOW_FILE" >/dev/null 2>&1; then
    echo "ERROR: invalid first-deploy allow file: $FIRST_DEPLOY_ALLOW_FILE" >&2
    exit 1
  fi
fi

first_deploy_allowed() {
  local vmid="$1"

  if [[ ! -f "$FIRST_DEPLOY_ALLOW_FILE" ]]; then
    return 1
  fi

  jq -e --argjson vmid "$vmid" 'any(.vmids[]?; . == $vmid)' "$FIRST_DEPLOY_ALLOW_FILE" >/dev/null
}

manifest_entries() {
  jq -c --arg scope "$SCOPE" '
    (if type == "array" then . else .entries end)[]
    | select($scope == "all" or .env == $scope)
  ' "$MANIFEST"
}

echo "=== Restore before start (${SCOPE}) ==="
if [[ "$RECOVERY_MODE" -eq 1 ]]; then
  echo "Mode: recovery"
fi
echo "Manifest: $MANIFEST"
echo "Pin file: $PIN_FILE"
if [[ -n "$PARK_STATUS_FILE" ]]; then
  echo "Park status file: $PARK_STATUS_FILE"
fi
echo "First-deploy allow file: $FIRST_DEPLOY_ALLOW_FILE"

CLUSTER_RESOURCES_JSON="$(cluster_resources_json || echo "[]")"
if [[ "$RECOVERY_MODE" -eq 1 && -n "$PARK_STATUS_FILE" ]]; then
  echo "--- vdb_adopt_batch ${SCOPE} --recovery-mode ---"
  vdb_park_status_init "$PARK_STATUS_FILE" "$SCOPE" recovery
  set +e
  vdb_adopt_batch "$PARK_STATUS_FILE" --recovery-mode --manifest "$MANIFEST"
  ADOPT_RC=$?
  set -e
  if [[ "$ADOPT_RC" -ne 0 ]]; then
    echo "  WARNING: recovery-mode vdb adoption returned rc=${ADOPT_RC}; orphaned-park guard remains active before any PBS restore" >&2
  fi
fi
set +e
PARKED_VDB_JSON="$(vdb_park_list_parks_json 2>&1)"
PARKED_VDB_SCAN_RC=$?
set -e
if [[ "$PARKED_VDB_SCAN_RC" -ne 0 ]]; then
  PARKED_VDB_SCAN_ERROR="$PARKED_VDB_JSON"
  PARKED_VDB_JSON="[]"
else
  PARKED_VDB_SCAN_ERROR=""
fi

FAILED=0
INCOMPLETE=0
PROCESSED=0

park_status_entry_for_vmid() {
  local vmid="$1"

  if [[ -z "$PARK_STATUS_FILE" || ! -f "$PARK_STATUS_FILE" ]]; then
    return 0
  fi

  jq -c --argjson vmid "$vmid" \
    'first(.entries[]? | select(.vmid == $vmid)) // empty' \
    "$PARK_STATUS_FILE"
}

park_status_is_adopted() {
  local vmid="$1"
  local status_value

  status_value="$(park_status_value_for_vmid "$vmid")"
  [[ "$status_value" == "adopted" ]]
}

park_status_value_for_vmid() {
  local vmid="$1"
  local status_entry

  status_entry="$(park_status_entry_for_vmid "$vmid")"
  [[ -n "$status_entry" ]] || return 0

  jq -r '.status // ""' <<< "$status_entry"
}

park_status_entry_is_current_run() {
  local status_entry="$1"
  local file_run_id entry_run_id file_scope

  [[ -n "$PARK_STATUS_FILE" && -f "$PARK_STATUS_FILE" ]] || return 1
  file_run_id="$(jq -r '.run_id // ""' "$PARK_STATUS_FILE")"
  file_scope="$(jq -r '.scope // ""' "$PARK_STATUS_FILE")"
  entry_run_id="$(jq -r '.run_id // ""' <<< "$status_entry")"
  [[ -n "$file_run_id" && "$entry_run_id" == "$file_run_id" ]] || return 1
  [[ -z "$file_scope" || "$file_scope" == "$SCOPE" || "$SCOPE" == "all" ]]
}

parked_record_for_vmid() {
  local vmid="$1"

  jq -c --argjson vmid "$vmid" \
    'first(.[]? | select(.vmid == $vmid)) // empty' \
    <<< "$PARKED_VDB_JSON"
}

orphaned_park_guard() {
  local label="$1"
  local vmid="$2"
  local entry_env="$3"
  local record pin message status_path status_entry

  if [[ "$PARKED_VDB_SCAN_RC" -ne 0 ]]; then
    message="could not scan parked vdb datasets before restore: ${PARKED_VDB_SCAN_ERROR}"
    echo "  ERROR: ${message}" >&2
    status_add "$label" "$vmid" "$entry_env" "failed" "orphaned-park-scan-failed" "$message"
    FAILED=1
    return 0
  fi

  record="$(parked_record_for_vmid "$vmid")"
  [[ -n "$record" ]] || return 1

  status_entry="$(park_status_entry_for_vmid "$vmid")"
  case "$(jq -r '.status // ""' <<< "${status_entry:-"{}"}")" in
    adopted|adopt-failed)
      if [[ -n "$status_entry" ]] && park_status_entry_is_current_run "$status_entry"; then
        return 1
      fi
      ;;
  esac

  pin="$(jq -r '.properties["mycofu:pin-volid"] // "unknown"' <<< "$record")"
  status_path="${PARK_STATUS_FILE:-build/vdb-park-status-${SCOPE}.json}"
  message="$(vdb_park_remediation_message "$vmid" "$entry_env" "$pin" "$MANIFEST" "$status_path")"

  echo "  ERROR: orphaned parked vdb found for VMID ${vmid}; refusing PBS restore" >&2
  while IFS= read -r line; do
    echo "  ${line}" >&2
  done <<< "$message"
  status_add "$label" "$vmid" "$entry_env" "failed" "orphaned-park-present" "$message" "$pin"
  FAILED=1
  return 0
}

adopt_cleanup_failure_guard() {
  local label="$1"
  local vmid="$2"
  local entry_env="$3"
  local status_entry pin message status_path

  status_entry="$(park_status_entry_for_vmid "$vmid")"
  [[ -n "$status_entry" ]] || return 1
  [[ "$(jq -r '.status // ""' <<< "$status_entry")" == "adopt-cleanup-failed" ]] || return 1

  pin="$(jq -r '.pin_volid // (.pin | if type == "object" then .volid else . end) // ""' <<< "$status_entry")"
  status_path="${PARK_STATUS_FILE:-build/vdb-park-status-${SCOPE}.json}"
  message="$(cat <<EOF
VMID ${vmid} adopt cleanup failed after park/adopt attempted to recover from an adopt error.
PBS restore is refused because the freshest vdb may still be under the canonical zvol name, or the empty restore target may not have been safely recreated.
Sanctioned exits, in order:
  1. Inspect the park and live attachment state:
     framework/scripts/parked-vdb.sh inspect ${vmid}
  2. Fix the adoption blocker and rerun recovery mode:
     framework/scripts/restore-before-start.sh ${entry_env} --manifest ${MANIFEST} --park-status ${status_path} --recovery-mode
EOF
)"

  echo "  ERROR: adopt cleanup failed for VMID ${vmid}; refusing PBS restore" >&2
  while IFS= read -r line; do
    echo "  ${line}" >&2
  done <<< "$message"
  status_add "$label" "$vmid" "$entry_env" "failed" "adopt-cleanup-failed" "$message" "$pin"
  FAILED=1
  return 0
}

handle_spared_if_adopted() {
  local label="$1"
  local vmid="$2"
  local entry_env="$3"
  local expected_disk_csv="$4"
  local original_reason="$5"
  local hosting_ip="$6"
  local status_entry node storage dataset_parent volname slot canonical config pin message exists_rc guid guid_rc expected_guid

  status_entry="$(park_status_entry_for_vmid "$vmid")"
  [[ -n "$status_entry" ]] || return 1

  if [[ "$(jq -r '.status // ""' <<< "$status_entry")" != "adopted" ]]; then
    return 1
  fi
  if ! park_status_entry_is_current_run "$status_entry"; then
    echo "  WARNING: park-status adopted entry for ${label} is not current-run evidence; falling back to PBS restore" >&2
    return 1
  fi

  node="$(jq -r '.node // ""' <<< "$status_entry")"
  storage="$(jq -r '.storage // ""' <<< "$status_entry")"
  dataset_parent="$(jq -r '.dataset_parent // ""' <<< "$status_entry")"
  volname="$(jq -r '.volname // ""' <<< "$status_entry")"
  slot="$(jq -r '.slot // ""' <<< "$status_entry")"
  expected_guid="$(jq -r '.guid // ""' <<< "$status_entry")"
  pin="$(jq -r '.pin_volid // (.pin | if type == "object" then .volid else . end) // ""' <<< "$status_entry")"

  if [[ -z "$dataset_parent" || "$dataset_parent" == "null" ]]; then
    dataset_parent="${storage}/data"
  fi

  if [[ -z "$node" || -z "$storage" || -z "$volname" || -z "$slot" || -z "$expected_guid" ]]; then
    echo "  WARNING: park-status adopted entry for ${label} is incomplete; falling back to PBS restore" >&2
    return 1
  fi

  canonical="${dataset_parent}/${volname}"
  set +e
  vdb_park_zfs_exists "$node" "$canonical"
  exists_rc=$?
  set -e
  if [[ "$exists_rc" -eq 1 ]]; then
    echo "  WARNING: park-status adopted entry for ${label} has no canonical zvol ${canonical}; falling back to PBS restore" >&2
    return 1
  elif [[ "$exists_rc" -ne 0 ]]; then
    message="could not verify adopted vdb ${canonical}; refusing PBS restore while canonical zvol state is unknown"
    echo "  ERROR: ${message}" >&2
    status_add "$label" "$vmid" "$entry_env" "failed" "adopted-zvol-verification-failed" "$message" "$pin"
    FAILED=1
    return 0
  fi

  set +e
  guid="$(vdb_park_zfs_get_value "$node" guid "$canonical" 2>/dev/null)"
  guid_rc=$?
  set -e
  if [[ "$guid_rc" -ne 0 || -z "$guid" ]]; then
    message="could not read adopted vdb GUID for ${canonical}; refusing PBS restore while canonical zvol identity is unknown"
    echo "  ERROR: ${message}" >&2
    status_add "$label" "$vmid" "$entry_env" "failed" "adopted-guid-verification-failed" "$message" "$pin"
    FAILED=1
    return 0
  fi
  if [[ "$guid" != "$expected_guid" ]]; then
    echo "  WARNING: park-status adopted entry for ${label} GUID mismatch: expected ${expected_guid}, got ${guid:-missing}; falling back to PBS restore" >&2
    return 1
  fi

  config="$(ssh_node "$hosting_ip" "qm config ${vmid}" 2>/dev/null || true)"
  if ! grep -Eq "^${slot}:[[:space:]]*${storage}:${volname}(,|$)" <<< "$config"; then
    echo "  WARNING: park-status adopted entry for ${label} is not attached at ${slot}; falling back to PBS restore" >&2
    return 1
  fi

  if ! verify_vm_complete_for_entry "$label" "$vmid" "$entry_env" "$expected_disk_csv" "$original_reason" "$pin"; then
    return 0
  fi

  message="vdb preserved by Sprint 044 park/adopt bridge"
  [[ -z "$pin" ]] || message="${message}; fallback pin ${pin}"
  status_add "$label" "$vmid" "$entry_env" "spared" "$original_reason" "$message" "$pin"
  echo "  ${label}: vdb preserved by park/adopt bridge; skipping PBS restore"
  return 0
}

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue

  PROCESSED=$((PROCESSED + 1))
  label="$(jq -r '.label' <<< "$entry")"
  module="$(jq -r '.module' <<< "$entry")"
  vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
  entry_env="$(jq -r '.env' <<< "$entry")"
  reason="$(jq -r '.reason' <<< "$entry")"
  manifest_pin="$(jq -r '(.pin // empty) | if type == "object" then (.volid // "") else . end' <<< "$entry")"
  expected_disk_csv="$(jq -r '(.expected_disks // []) | join(",")' <<< "$entry")"

  echo ""
  echo "--- ${label} (VMID ${vmid}, ${reason}) ---"

  hosting_node="$(hosting_node_for_vmid "$vmid")"
  if [[ -z "$hosting_node" ]]; then
    message="VM ${vmid} from ${module} not found in cluster"
    echo "  ${message}"
    status_add "$label" "$vmid" "$entry_env" "not-created-yet" "$reason" "$message"
    if [[ "$RECOVERY_MODE" -eq 0 ]]; then
      FAILED=1
      break
    fi
    continue
  fi

  hosting_ip="$(node_ip_for_name "$hosting_node")"
  if [[ -z "$hosting_ip" || "$hosting_ip" == "null" ]]; then
    message="hosting node ${hosting_node} has no management IP in config"
    echo "  ERROR: ${message}"
    status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message"
    FAILED=1
    break
  fi

  status="$(vm_status "$hosting_ip" "$vmid")"
  if [[ "$status" != "stopped" ]]; then
    message="VM unexpectedly running or unavailable before restore (status=${status:-unknown})"
    echo "  ERROR: ${message}"
    status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message"
    FAILED=1
    break
  fi

  if ha_resource_present "$vmid"; then
    if ! remove_ha_if_allowed "$hosting_ip" "$vmid"; then
      message="HA resource vm:${vmid} exists before restore"
      echo "  ERROR: ${message}"
      status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message"
      FAILED=1
      break
    fi
  fi

  if adopt_cleanup_failure_guard "$label" "$vmid" "$entry_env"; then
    break
  fi

  if orphaned_park_guard "$label" "$vmid" "$entry_env"; then
    break
  fi

  if handle_spared_if_adopted "$label" "$vmid" "$entry_env" "$expected_disk_csv" "$reason" "$hosting_ip"; then
    continue
  fi

  pin="$(pin_for_vmid "$vmid" "$manifest_pin")"
  if [[ -n "$pin" ]]; then
    echo "  ${label}: pinned to ${pin}"
    set +e
    "${SCRIPT_DIR}/restore-from-pbs.sh" --target "$vmid" --force --backup-id "$pin" --leave-stopped
    restore_rc=$?
    set -e
    if [[ "$restore_rc" -ne 0 ]]; then
      message="restore-from-pbs failed with rc=${restore_rc}"
      echo "  ERROR: restore failed for ${label}"
      status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message" "$pin"
      FAILED=1
      break
    fi
    if ! verify_vm_complete_for_entry "$label" "$vmid" "$entry_env" "$expected_disk_csv" "$reason" "$pin"; then
      continue
    fi
    status_add "$label" "$vmid" "$entry_env" "restored" "$reason" "restored from pinned backup" "$pin"
    echo "  ${label}: restored; leaving VM stopped"
    continue
  fi

  pbs_storage_rc=0
  if pbs_storage_state; then
    pbs_storage_rc=0
  else
    pbs_storage_rc=$?
  fi
  if [[ "$pbs_storage_rc" -eq 1 ]]; then
    if first_deploy_allowed "$vmid"; then
      message="PBS storage pbs-nas is not registered; first-deploy approval present"
      echo "  ${label}: PBS storage pbs-nas is not registered"
      echo "  ${label}: first-deploy approval present; leaving vdb empty"
      if ! verify_vm_complete_for_entry "$label" "$vmid" "$entry_env" "$expected_disk_csv" "$reason"; then
        continue
      fi
      status_add "$label" "$vmid" "$entry_env" "first-deploy-empty" "$reason" "$message"
      continue
    fi

    message="PBS storage pbs-nas is not registered for ${label} (VMID ${vmid}); set FIRST_DEPLOY_ALLOW_VMIDS=${vmid} and rerun"
    echo "ERROR: PBS storage pbs-nas is not registered for ${label} (VMID ${vmid})" >&2
    echo "Refusing to start empty vdb without first-deploy approval." >&2
    echo "Set FIRST_DEPLOY_ALLOW_VMIDS=${vmid} and rerun." >&2
    status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message"
    FAILED=1
    break
  fi
  if [[ "$pbs_storage_rc" -ne 0 ]]; then
    message="could not query Proxmox storage status for ${label} (VMID ${vmid}); refusing first-deploy approval while PBS availability is unknown"
    echo "  ERROR: ${message}" >&2
    status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message"
    FAILED=1
    break
  fi

  set +e
  latest_backup="$(latest_backup_for_vmid "$vmid")"
  latest_backup_rc=$?
  set -e
  if [[ "$latest_backup_rc" -ne 0 ]]; then
    message="could not query PBS backups for ${label} (VMID ${vmid}); refusing first-deploy approval while PBS availability is unknown"
    echo "  ERROR: ${message}" >&2
    status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message"
    FAILED=1
    break
  fi
  if [[ -n "$latest_backup" ]]; then
    if [[ -n "${CI:-}" && "${ALLOW_UNPINNED_RESTORE:-0}" != "1" ]]; then
      message="existing PBS backup found but no pin was supplied in CI"
      echo "  ERROR: ${message}"
      status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message"
      FAILED=1
      break
    fi

    echo "  WARNING: no pin for ${label}; unpinned fallback to latest backup ${latest_backup}"
    set +e
    "${SCRIPT_DIR}/restore-from-pbs.sh" --target "$vmid" --force --backup-id "$latest_backup" --leave-stopped
    restore_rc=$?
    set -e
    if [[ "$restore_rc" -ne 0 ]]; then
      message="unpinned restore-from-pbs failed with rc=${restore_rc}"
      echo "  ERROR: restore failed for ${label}"
      status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message" "$latest_backup"
      FAILED=1
      break
    fi
    if ! verify_vm_complete_for_entry "$label" "$vmid" "$entry_env" "$expected_disk_csv" "$reason" "$latest_backup"; then
      continue
    fi
    status_add "$label" "$vmid" "$entry_env" "restored" "$reason" "restored from unpinned latest backup" "$latest_backup"
    echo "  ${label}: restored from unpinned fallback; leaving VM stopped"
    continue
  fi

  if first_deploy_allowed "$vmid"; then
    message="no PBS backup found; first-deploy approval present"
    echo "  ${label}: no PBS backup found"
    echo "  ${label}: first-deploy approval present; leaving vdb empty"
    if ! verify_vm_complete_for_entry "$label" "$vmid" "$entry_env" "$expected_disk_csv" "$reason"; then
      continue
    fi
    status_add "$label" "$vmid" "$entry_env" "first-deploy-empty" "$reason" "$message"
    continue
  fi

  message="no PBS backup found for ${label} (VMID ${vmid}); set FIRST_DEPLOY_ALLOW_VMIDS=${vmid} and rerun"
  echo "ERROR: no PBS backup found for ${label} (VMID ${vmid})" >&2
  echo "Refusing to start empty vdb without first-deploy approval." >&2
  echo "Set FIRST_DEPLOY_ALLOW_VMIDS=${vmid} and rerun." >&2
  status_add "$label" "$vmid" "$entry_env" "failed" "$reason" "$message"
  FAILED=1
  break
done < <(manifest_entries)

write_status_file
echo ""
echo "Status: $STATUS_FILE"

if [[ "$PROCESSED" -eq 0 ]]; then
  echo "No manifest entries in scope ${SCOPE}; nothing to restore"
  exit 0
fi

if [[ "$FAILED" -ne 0 ]]; then
  echo "Skipping phase 2: one or more vdb restores failed."
  exit 1
fi

if [[ "$INCOMPLETE" -ne 0 ]]; then
  echo "Skipping phase 2: one or more restored VM(s) are incomplete."
  exit 2
fi

# --- Manifest-vs-entries parity check (#518, A6) ---
# On the success path every in-scope manifest entry has produced exactly one
# status entry (each terminal branch calls status_add once). If the persisted
# status file is short of the manifest, a code path silently skipped a VM and
# the artifact would under-report — the exact #518 class (empty/short entries[]
# read as "nothing happened"). FAIL-not-silent, naming the missing VMIDs, rather
# than let an under-populated artifact pass for a successful run.
parity_manifest_vmids="$(manifest_entries | jq -r '.vmid | tostring' | sort -u)"
parity_status_vmids="$(jq -r '.entries[].vmid | tostring' "$STATUS_FILE" | sort -u)"
parity_manifest_n="$(printf '%s\n' "$parity_manifest_vmids" | grep -c . || true)"
parity_status_n="$(printf '%s\n' "$parity_status_vmids" | grep -c . || true)"
if [[ "$parity_manifest_n" -gt 0 && "$parity_status_n" != "$parity_manifest_n" ]]; then
  parity_missing="$(comm -23 \
    <(printf '%s\n' "$parity_manifest_vmids" | grep -v '^$') \
    <(printf '%s\n' "$parity_status_vmids" | grep -v '^$') | tr '\n' ' ')"
  echo "ERROR: preboot-restore status parity check failed (#518)." >&2
  echo "  Manifest has ${parity_manifest_n} VMID(s) in scope ${SCOPE}, but the status" >&2
  echo "  file recorded ${parity_status_n} entr(ies): ${STATUS_FILE}" >&2
  echo "  Missing status entries for VMID(s): ${parity_missing:-<unknown>}" >&2
  echo "  Refusing to report success on an under-populated status artifact." >&2
  exit 1
fi

echo "=== Restore-before-start complete: ${PROCESSED} VM(s) checked ==="
