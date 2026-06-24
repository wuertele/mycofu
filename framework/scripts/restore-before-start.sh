#!/usr/bin/env bash
# restore-before-start.sh — Restore precious vdb state before VMs are started.
#
# Usage:
#   restore-before-start.sh <dev|prod|all> \
#     --manifest build/preboot-restore-<scope>.json \
#     --pin-file build/restore-pin-<env>.json \
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

SCOPE="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

MANIFEST=""
PIN_FILE=""
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
      (.reason | type == "string")
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
  local status="$3"
  local reason="$4"
  local message="$5"
  local pin="${6:-}"
  local tmp=""

  tmp="$(mktemp "${TMPDIR:-/tmp}/preboot-restore-status.XXXXXX")"
  jq \
    --arg label "$label" \
    --arg vmid "$vmid" \
    --arg status "$status" \
    --arg reason "$reason" \
    --arg message "$message" \
    --arg pin "$pin" \
    '.entries += [{
      label: $label,
      vmid: ($vmid | tonumber),
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

  if [[ -f "$PIN_FILE" ]]; then
    jq -r --arg vmid "$vmid" '.pins[$vmid] // empty' "$PIN_FILE"
    return 0
  fi

  printf '%s\n' "$manifest_pin"
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
echo "First-deploy allow file: $FIRST_DEPLOY_ALLOW_FILE"

CLUSTER_RESOURCES_JSON="$(cluster_resources_json || echo "[]")"

FAILED=0
PROCESSED=0

while IFS= read -r entry; do
  [[ -z "$entry" ]] && continue

  PROCESSED=$((PROCESSED + 1))
  label="$(jq -r '.label' <<< "$entry")"
  module="$(jq -r '.module' <<< "$entry")"
  vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
  reason="$(jq -r '.reason' <<< "$entry")"
  manifest_pin="$(jq -r '.pin // empty' <<< "$entry")"

  echo ""
  echo "--- ${label} (VMID ${vmid}, ${reason}) ---"

  hosting_node="$(hosting_node_for_vmid "$vmid")"
  if [[ -z "$hosting_node" ]]; then
    message="VM ${vmid} from ${module} not found in cluster"
    echo "  ${message}"
    status_add "$label" "$vmid" "not-created-yet" "$reason" "$message"
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
    status_add "$label" "$vmid" "failed" "$reason" "$message"
    FAILED=1
    break
  fi

  status="$(vm_status "$hosting_ip" "$vmid")"
  if [[ "$status" != "stopped" ]]; then
    message="VM unexpectedly running or unavailable before restore (status=${status:-unknown})"
    echo "  ERROR: ${message}"
    status_add "$label" "$vmid" "failed" "$reason" "$message"
    FAILED=1
    break
  fi

  if ha_resource_present "$vmid"; then
    if ! remove_ha_if_allowed "$hosting_ip" "$vmid"; then
      message="HA resource vm:${vmid} exists before restore"
      echo "  ERROR: ${message}"
      status_add "$label" "$vmid" "failed" "$reason" "$message"
      FAILED=1
      break
    fi
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
      status_add "$label" "$vmid" "failed" "$reason" "$message" "$pin"
      FAILED=1
      break
    fi
    status_add "$label" "$vmid" "restored" "$reason" "restored from pinned backup" "$pin"
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
      status_add "$label" "$vmid" "first-deploy-empty" "$reason" "$message"
      continue
    fi

    message="PBS storage pbs-nas is not registered for ${label} (VMID ${vmid}); set FIRST_DEPLOY_ALLOW_VMIDS=${vmid} and rerun"
    echo "ERROR: PBS storage pbs-nas is not registered for ${label} (VMID ${vmid})" >&2
    echo "Refusing to start empty vdb without first-deploy approval." >&2
    echo "Set FIRST_DEPLOY_ALLOW_VMIDS=${vmid} and rerun." >&2
    status_add "$label" "$vmid" "failed" "$reason" "$message"
    FAILED=1
    break
  fi
  if [[ "$pbs_storage_rc" -ne 0 ]]; then
    message="could not query Proxmox storage status for ${label} (VMID ${vmid}); refusing first-deploy approval while PBS availability is unknown"
    echo "  ERROR: ${message}" >&2
    status_add "$label" "$vmid" "failed" "$reason" "$message"
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
    status_add "$label" "$vmid" "failed" "$reason" "$message"
    FAILED=1
    break
  fi
  if [[ -n "$latest_backup" ]]; then
    if [[ -n "${CI:-}" && "${ALLOW_UNPINNED_RESTORE:-0}" != "1" ]]; then
      message="existing PBS backup found but no pin was supplied in CI"
      echo "  ERROR: ${message}"
      status_add "$label" "$vmid" "failed" "$reason" "$message"
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
      status_add "$label" "$vmid" "failed" "$reason" "$message" "$latest_backup"
      FAILED=1
      break
    fi
    status_add "$label" "$vmid" "restored" "$reason" "restored from unpinned latest backup" "$latest_backup"
    echo "  ${label}: restored from unpinned fallback; leaving VM stopped"
    continue
  fi

  if first_deploy_allowed "$vmid"; then
    message="no PBS backup found; first-deploy approval present"
    echo "  ${label}: no PBS backup found"
    echo "  ${label}: first-deploy approval present; leaving vdb empty"
    status_add "$label" "$vmid" "first-deploy-empty" "$reason" "$message"
    continue
  fi

  message="no PBS backup found for ${label} (VMID ${vmid}); set FIRST_DEPLOY_ALLOW_VMIDS=${vmid} and rerun"
  echo "ERROR: no PBS backup found for ${label} (VMID ${vmid})" >&2
  echo "Refusing to start empty vdb without first-deploy approval." >&2
  echo "Set FIRST_DEPLOY_ALLOW_VMIDS=${vmid} and rerun." >&2
  status_add "$label" "$vmid" "failed" "$reason" "$message"
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

echo "=== Restore-before-start complete: ${PROCESSED} VM(s) checked ==="
