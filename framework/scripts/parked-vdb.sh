#!/usr/bin/env bash
# parked-vdb.sh — inspect and release Sprint 044 parked vdb datasets.
#
# Sprint 044 transition mechanism: raw ZFS rename parking selected by
# docs/research/RESEARCH-004-vdb-survives-recreation.md. Sunset is the
# upstream PVE keep-volume/detach-without-delete verb tracked by
# docs/reports/2026-07-05-pve-upstream-detach-campaign.md. Verified
# qemu-server baseline: 9.0.30. Issue #412 must rerun the gated experiment
# before extending the trusted version list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=framework/scripts/vdb-park-lib.sh
source "${SCRIPT_DIR}/vdb-park-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  parked-vdb.sh --list [--format json]
  parked-vdb.sh inspect <vmid>
  parked-vdb.sh release <vmid> [--dry-run]

Commands:
  --list          Enumerate parked vdb datasets across configured nodes.
  inspect         Print identity and live attachment state for one VMID.
  release         Destroy an orphaned park after safety checks.

Release is destructive. It accepts loss of writes newer than the park's
recorded PBS pin and is for explicit operator use only.
EOF
}

parked_vdb_find_record() {
  local vmid="$1"
  vdb_park_list_parks_json | jq -c --argjson vmid "$vmid" 'first(.[]? | select(.vmid == $vmid))'
}

parked_vdb_vm_config() {
  local node="$1"
  local vmid="$2"
  vdb_park_ssh_node "$node" "qm config ${vmid}" 2>/dev/null || true
}

parked_vdb_vm_status() {
  local node="$1"
  local vmid="$2"
  vdb_park_ssh_node "$node" "qm status ${vmid} 2>/dev/null | awk '{print \$2}'" 2>/dev/null || true
}

parked_vdb_inspect_json() {
  local vmid="$1"
  local record node dataset props orig slot config canonical_state hosting status health

  record="$(parked_vdb_find_record "$vmid")"
  if [[ -z "$record" || "$record" == "null" ]]; then
    jq -n --argjson vmid "$vmid" '{vmid: $vmid, park: null, found: false}'
    return 1
  fi

  node="$(jq -r '.node' <<< "$record")"
  dataset="$(jq -r '.dataset' <<< "$record")"
  orig="$(jq -r '.properties["mycofu:orig-volname"] // ""' <<< "$record")"
  slot="$(jq -r '.properties["mycofu:slot"] // ""' <<< "$record")"
  hosting="$(vdb_park_hosting_node "$vmid" 2>/dev/null || true)"
  config=""
  status=""
  if [[ -n "$hosting" ]]; then
    config="$(parked_vdb_vm_config "$hosting" "$vmid")"
    status="$(parked_vdb_vm_status "$hosting" "$vmid")"
  fi

  canonical_state="missing"
  if [[ -n "$orig" ]]; then
    local parent
    parent="$(dirname "$dataset")"
    if vdb_park_zfs_exists "$node" "${parent}/${orig}"; then
      canonical_state="present"
    fi
  fi

  health="missing"
  if [[ -n "$config" && -n "$orig" && -n "$slot" ]] && grep -Eq "^${slot}:[[:space:]]*[^,]*:${orig}(,|$)" <<< "$config"; then
    health="attached"
  elif [[ -n "$config" && -n "$orig" ]] && grep -Fq ":${orig}" <<< "$config"; then
    health="attached-wrong-slot"
  elif [[ -n "$config" ]]; then
    health="not-attached"
  fi

  RECORD="$record" HOSTING_NODE="$hosting" VM_STATUS="$status" VM_CONFIG="$config" \
    CANONICAL_STATE="$canonical_state" ATTACHED_HEALTH="$health" python3 - <<'PY'
import json
import os

record = json.loads(os.environ["RECORD"])
print(json.dumps({
    "found": True,
    "park": record,
    "live": {
        "hosting_node": os.environ["HOSTING_NODE"] or None,
        "vm_status": os.environ["VM_STATUS"] or None,
        "slot_map": os.environ["VM_CONFIG"].splitlines(),
        "canonical_zvol_state": os.environ["CANONICAL_STATE"],
        "attached_vdb_health": os.environ["ATTACHED_HEALTH"],
    },
}, indent=2, sort_keys=True))
PY
}

parked_vdb_inspect() {
  local vmid="$1"
  parked_vdb_inspect_json "$vmid"
}

parked_vdb_referenced_anywhere() {
  local park_name="$1"
  local node ip output scan_rc park_name_quoted

  park_name_quoted="$(vdb_park_shell_quote "$park_name")"
  while IFS=$'\t' read -r node ip; do
    [[ -z "$node" || -z "$ip" ]] && continue
    if output="$(vdb_park_ssh_ip "$ip" "qm_rows=\$(qm list 2>/dev/null) || exit \$?; ids=\$(printf '%s\n' \"\$qm_rows\" | tail -n +2 | awk '{print \$1}'); found=1; for id in \$ids; do config=\$(qm config \"\$id\" 2>/dev/null) || exit \$?; if printf '%s\n' \"\$config\" | grep -F ${park_name_quoted} >/dev/null; then printf '%s\n' \"\$config\"; found=0; fi; done; exit \$found" 2>/dev/null)"; then
      scan_rc=0
    else
      scan_rc=$?
    fi
    if [[ "$scan_rc" -ne 0 && "$scan_rc" -ne 1 ]]; then
      echo "ERROR: failed to scan VM configs for parked vdb references on ${node}" >&2
      return 2
    fi
    if [[ -n "$output" ]]; then
      return 0
    fi
  done < <(vdb_park_node_rows)

  return 1
}

parked_vdb_release() {
  local vmid="$1"
  local dry_run="$2"
  local inspect record node dataset orig slot pin hosting status health park_name

  set +e
  inspect="$(parked_vdb_inspect_json "$vmid")"
  inspect_rc=$?
  set -e
  if [[ "$inspect_rc" -ne 0 ]]; then
    echo "ERROR: no parked vdb found for VMID ${vmid}" >&2
    return 1
  fi

  record="$(jq -c '.park' <<< "$inspect")"
  node="$(jq -r '.node' <<< "$record")"
  dataset="$(jq -r '.dataset' <<< "$record")"
  orig="$(jq -r '.properties["mycofu:orig-volname"] // ""' <<< "$record")"
  slot="$(jq -r '.properties["mycofu:slot"] // ""' <<< "$record")"
  pin="$(jq -r '.properties["mycofu:pin-volid"] // "unknown"' <<< "$record")"
  hosting="$(jq -r '.live.hosting_node // ""' <<< "$inspect")"
  status="$(jq -r '.live.vm_status // ""' <<< "$inspect")"
  health="$(jq -r '.live.attached_vdb_health // ""' <<< "$inspect")"
  park_name="$(basename "$dataset")"

  if [[ -z "$hosting" ]]; then
    echo "ERROR: refusing release for VMID ${vmid}: VM does not exist" >&2
    return 1
  fi
  if [[ "$status" != "running" && "$status" != "stopped" ]]; then
    echo "ERROR: refusing release for VMID ${vmid}: VM status is ${status:-unknown}" >&2
    return 1
  fi
  if [[ "$health" != "attached" ]]; then
    echo "ERROR: refusing release for VMID ${vmid}: healthy canonical vdb is not attached on ${slot:-unknown}" >&2
    return 1
  fi
  local referenced_rc=0
  set +e
  parked_vdb_referenced_anywhere "$park_name"
  referenced_rc=$?
  set -e
  if [[ "$referenced_rc" -eq 0 ]]; then
    echo "ERROR: refusing release for VMID ${vmid}: park ${park_name} is still referenced by a VM config" >&2
    return 1
  elif [[ "$referenced_rc" -ne 1 ]]; then
    echo "ERROR: refusing release for VMID ${vmid}: could not verify park ${park_name} is unreferenced on every node" >&2
    return 1
  fi

  echo "VMID ${vmid}: release accepts loss of all writes newer than pin ${pin}"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "DRY-RUN: would release ${dataset} on ${node}"
    return 0
  fi

  vdb_park_ssh_node "$node" "zfs destroy -r $(vdb_park_shell_quote "$dataset")"
  echo "Released parked vdb ${dataset} for VMID ${vmid}; canonical vdb ${orig} remains attached."
}

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  --list)
    shift
    format="text"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format)
          format="$2"
          shift 2
          ;;
        --help|-h)
          usage
          exit 0
          ;;
        *)
          echo "ERROR: unknown --list argument: $1" >&2
          usage >&2
          exit 2
          ;;
      esac
    done
    parks_json="$(vdb_park_list_parks_json)"
    if [[ "$format" == "json" ]]; then
      jq . <<< "$parks_json"
    elif [[ "$format" == "text" ]]; then
      jq -r '
        if length == 0 then
          "No parked vdb zvols found"
        else
          .[] | "VMID \(.vmid) on \(.node): \(.dataset) size=\(.size) attached_vdb=\(.attached_vdb_health)"
        end
      ' <<< "$parks_json"
    else
      echo "ERROR: unsupported format: $format" >&2
      exit 2
    fi
    ;;
  inspect)
    [[ $# -eq 2 ]] || { usage >&2; exit 2; }
    [[ "$2" =~ ^[0-9]+$ ]] || { echo "ERROR: inspect requires numeric VMID" >&2; exit 2; }
    parked_vdb_inspect "$2"
    ;;
  release)
    shift
    dry_run=0
    [[ $# -ge 1 ]] || { usage >&2; exit 2; }
    vmid="$1"
    shift
    [[ "$vmid" =~ ^[0-9]+$ ]] || { echo "ERROR: release requires numeric VMID" >&2; exit 2; }
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --dry-run) dry_run=1; shift ;;
        *) echo "ERROR: unknown release argument: $1" >&2; usage >&2; exit 2 ;;
      esac
    done
    parked_vdb_release "$vmid" "$dry_run"
    ;;
  --help|-h)
    usage
    ;;
  *)
    echo "ERROR: unknown command: $1" >&2
    usage >&2
    exit 2
    ;;
esac
