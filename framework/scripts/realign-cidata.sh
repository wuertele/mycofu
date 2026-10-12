#!/usr/bin/env bash
# realign-cidata.sh - Repair rename-victim CIDATA references.
#
# Proxmox can import an incoming canonical CIDATA volume
# `vm-<vmid>-cloudinit` as `vm-<vmid>-disk-<N>` when the target node already
# holds a stale canonical zvol. That referenced disk-N volume is a
# rename-victim: it is cidata-sized, attached as a cdrom, and no longer matches
# Proxmox cloudinit regeneration logic.
#
# This tool keeps the existing cluster-wide snapshot-safe victim discovery
# scan, then handles each victim according to current state:
#   Path A: stopped or HA-error service uses the storage-fence 6A
#           disabled -> started ladder; no HA remove and no qm stop.
#   Path B: running and HA-healthy service hot-swaps the cdrom live.
#   Path C: fallback maintenance path captures HA config, removes HA, stops
#           with a re-issuing verification loop, repairs, starts, and restores
#           HA group/state.
#
# Usage:
#   realign-cidata.sh [--dry-run] [--vmid <id>|--all]
#
# Operator-invoked or DRT-invoked tool. See .claude/rules/destructive-operations.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
CLEANUP_ORPHAN="${SCRIPT_DIR}/cleanup-orphan-cidata.sh"
BACKUP_VMID_HELPER="${SCRIPT_DIR}/list-backup-backed-vmids.sh"

MAX_CIDATA_REFER_KIB=1024

DRY_RUN=0
TARGET_VMID=""
TARGET_ALL=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--vmid <id>|--all]

Repair rename-victim CIDATA for VMs discovered by a cluster-wide scan.

Options:
  --dry-run    list victims and planned actions, do nothing
  --vmid <id>  realign a specific VM by ID
  --all        realign all discovered victims
  --help       this message

Exit codes:
  0 - success (all targets realigned or none found)
  1 - at least one realignment failed or scan error
  2 - usage error
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --vmid)
      [[ $# -ge 2 ]] || { echo "ERROR: --vmid requires an argument" >&2; usage >&2; exit 2; }
      TARGET_VMID="$2"
      shift 2
      ;;
    --all)
      TARGET_ALL=1
      shift
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "${TARGET_VMID}" && "${TARGET_ALL}" -eq 1 ]]; then
  echo "ERROR: Specify either --vmid <id> or --all, not both" >&2
  usage >&2
  exit 2
fi

if [[ -z "${TARGET_VMID}" && "${TARGET_ALL}" -eq 0 ]]; then
  echo "ERROR: Specify --vmid <id> or --all" >&2
  usage >&2
  exit 2
fi

if [[ ! -f "${CONFIG}" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 1
fi

if [[ ! -x "${CLEANUP_ORPHAN}" ]]; then
  echo "ERROR: cleanup helper not executable: ${CLEANUP_ORPHAN}" >&2
  exit 1
fi

YQ="${YQ:-yq}"
SSH="${SSH:-ssh}"
# SSH options used in validate.sh and throughout the framework.
SSH_OPTS=(-o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o ConnectTimeout=5)

STORAGE_POOL="$("${YQ}" -r '.proxmox.storage_pool // "vmstore"' "${CONFIG}")"

NODE_IPS=()
NODE_NAMES=()
while read -r name ip; do
  [[ -z "${name}" || -z "${ip}" ]] && continue
  NODE_NAMES+=("${name}")
  NODE_IPS+=("${ip}")
done < <("${YQ}" -r '.nodes[] | .name + " " + .mgmt_ip' "${CONFIG}")

if [[ "${#NODE_IPS[@]}" -eq 0 ]]; then
  echo "ERROR: No nodes found in ${CONFIG} (.nodes[])" >&2
  exit 1
fi

node_ip_for() {
  local name="$1"
  local i
  for i in "${!NODE_NAMES[@]}"; do
    if [[ "${NODE_NAMES[$i]}" == "${name}" ]]; then
      printf '%s\n' "${NODE_IPS[$i]}"
      return 0
    fi
  done
  return 1
}

ssh_node() {
  local node_ip="$1"
  shift
  "${SSH}" -n "${SSH_OPTS[@]}" "root@${node_ip}" "$@"
}

run_capture() {
  local __out_var="$1"
  shift
  local __capture_output __capture_rc
  set +e
  __capture_output="$("$@" 2>&1)"
  __capture_rc=$?
  set -e
  printf -v "${__out_var}" '%s' "${__capture_output}"
  return "${__capture_rc}"
}

ssh_capture() {
  local __out_var="$1"
  local node_ip="$2"
  shift 2
  run_capture "${__out_var}" ssh_node "${node_ip}" "$@"
}

refer_to_kib() {
  local value="$1"
  if [[ "${value}" == "0" || "${value}" == "0B" ]]; then
    echo 0
    return
  fi
  if [[ "${value}" =~ ^([0-9]+(\.[0-9]+)?)K$ ]]; then
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", v }'
    return
  fi
  echo "$((MAX_CIDATA_REFER_KIB + 1))"
}

query_cluster_json() {
  local __out_var="$1"
  local command="$2"
  local node_ip output
  for node_ip in "${NODE_IPS[@]}"; do
    if ssh_capture output "${node_ip}" "${command}"; then
      printf -v "${__out_var}" '%s' "${output}"
      return 0
    fi
  done
  return 1
}

cluster_resource_row() {
  local vmid="$1"
  local json row
  if ! query_cluster_json json "pvesh get /cluster/resources --type vm --output-format json"; then
    return 1
  fi
  set +e
  row=$(VMID="${vmid}" JSON_INPUT="${json}" python3 -c '
import json, os, sys
target = os.environ["VMID"]
try:
    data = json.loads(os.environ["JSON_INPUT"])
except Exception:
    sys.exit(2)
for item in data:
    item_vmid = item.get("vmid")
    if item_vmid is None:
        ident = str(item.get("id", ""))
        item_vmid = ident.rsplit("/", 1)[-1].rsplit(":", 1)[-1]
    if str(item_vmid) == target:
        node = item.get("node", "")
        status = item.get("status", "")
        print(f"{node}\t{status}")
        sys.exit(0)
sys.exit(1)
')
  rc=$?
  set -e
  [[ "${rc}" -eq 0 ]] || return "${rc}"
  printf '%s\n' "${row}"
}

active_migration_exists() {
  local vmid="$1"
  local json found
  if ! query_cluster_json json "pvesh get /cluster/tasks --output-format json"; then
    return 2
  fi
  set +e
  found=$(VMID="${vmid}" JSON_INPUT="${json}" python3 -c '
import json, os, sys
target = os.environ["VMID"]
terminal = {"OK", "ERROR", "stopped", "done", "warning"}
try:
    data = json.loads(os.environ["JSON_INPUT"])
except Exception:
    sys.exit(2)
for item in data:
    text = " ".join(str(item.get(k, "")) for k in ("upid", "id", "type", "worker_type"))
    status = str(item.get("status", "running"))
    if target in text and "migr" in text.lower() and status not in terminal:
        print("yes")
        sys.exit(0)
print("no")
')
  rc=$?
  # Caller deliberately captures this helper's 0/1/2 status with set +e.
  [[ "${rc}" -eq 0 ]] || return "${rc}"
  [[ "${found}" == "yes" ]] && return 0
  return 1
}

ha_state_for() {
  local vmid="$1"
  local output node_ip line state
  for node_ip in "${NODE_IPS[@]}"; do
    if ssh_capture output "${node_ip}" "ha-manager status"; then
      line=$(printf '%s\n' "${output}" | awk -v sid="vm:${vmid}" '$0 ~ sid { print; exit }')
      if [[ -n "${line}" ]]; then
        state=$(printf '%s\n' "${line}" | sed -n 's/.*([^,]*,[[:space:]]*\([^)]*\)).*/\1/p' | awk '{print $1}')
        [[ -n "${state}" ]] || state="unknown"
        printf '%s\n' "${state}"
        return 0
      fi
    fi
  done
  printf '%s\n' "unknown"
}

ha_config_for() {
  local vmid="$1"
  local node_ip output
  for node_ip in "${NODE_IPS[@]}"; do
    if ssh_capture output "${node_ip}" "ha-manager config vm:${vmid} 2>/dev/null || ha-manager config 2>/dev/null"; then
      printf '%s\n' "${output}"
      return 0
    fi
  done
  return 1
}

ha_config_value() {
  local key="$1"
  awk -v key="${key}" '
    $1 == key || $1 == key ":" { print $2; exit }
  '
}

qm_status_is_running() {
  local node_ip="$1"
  local vmid="$2"
  local output
  if ! ssh_capture output "${node_ip}" "qm status ${vmid}"; then
    return 1
  fi
  grep -q 'status: running' <<< "${output}"
}

wait_for_qm_running() {
  local node_ip="$1"
  local vmid="$2"
  local waited=0
  while [[ "${waited}" -le 30 ]]; do
    if qm_status_is_running "${node_ip}" "${vmid}"; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

stop_with_reissue_loop() {
  local node_ip="$1"
  local vmid="$2"
  local waited=0
  local output
  while [[ "${waited}" -le 30 ]]; do
    ssh_node "${node_ip}" "qm stop ${vmid} --skiplock" >/dev/null 2>&1 || true
    if ssh_capture output "${node_ip}" "qm status ${vmid}" &&
       grep -q 'status: stopped' <<< "${output}"; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# M0 attended smoke pins this exact allocation form and Path-B hot-swap
# behavior for the deployed PVE version. If M0 finds a version-specific
# difference, update this single command builder and the Path-B decision.
#
# PVE 9.1.1 (pinned by the 2026-07-08 M0 live smoke on testapp_dev/500):
# the explicit-name form `<storage>:vm-<vmid>-cloudinit` is an ATTACH-EXISTING
# request — qm blocks up to 10s waiting for the /dev/zvol/.../vm-<vmid>-cloudinit
# device link and fails ("no zvol device link ... found after 10 sec") because a
# real rename-victim's canonical zvol does NOT exist (it was renamed to disk-N).
# The correct idiom is the ALLOCATE form `<storage>:cloudinit`, which makes
# Proxmox create vm-<vmid>-cloudinit fresh (config still ends up canonical, so
# current_config_is_canonical() still matches). This is the shared "work" step
# for Paths A/B/C, so the attach form broke all three.
canonical_repoint_cmd() {
  local vmid="$1"
  local drivekey="$2"
  printf 'qm set %s -%s %s:cloudinit,media=cdrom' \
    "${vmid}" "${drivekey}" "${STORAGE_POOL}"
}

run_repoint_and_update() {
  local node_ip="$1"
  local vmid="$2"
  local drivekey="$3"
  local cmd
  cmd="$(canonical_repoint_cmd "${vmid}" "${drivekey}")"
  ssh_node "${node_ip}" "${cmd}" &&
    ssh_node "${node_ip}" "qm cloudinit update ${vmid}"
}

current_config_is_canonical() {
  local node_ip="$1"
  local vmid="$2"
  local drivekey="$3"
  local output
  if ! ssh_capture output "${node_ip}" "qm config ${vmid} --current"; then
    return 1
  fi
  grep -qE "^${drivekey}:[[:space:]]*${STORAGE_POOL}:vm-${vmid}-cloudinit([,[:space:]]|$)" <<< "${output}"
}

cleanup_scoped() {
  local node_name="$1"
  local vmid="$2"
  "${CLEANUP_ORPHAN}" --vmid "${vmid}" --node "${node_name}"
}

print_g7_remediation() {
  local vmid="$1"
  local reason="$2"
  echo "  G7 remediation (${reason}):" >&2
  echo "    framework/scripts/validate.sh" >&2
  echo "    framework/scripts/realign-cidata.sh --dry-run --vmid ${vmid}" >&2
  echo "    framework/scripts/realign-cidata.sh --vmid ${vmid}" >&2
}

backup_backed_vmids() {
  if [[ -x "${BACKUP_VMID_HELPER}" ]]; then
    "${BACKUP_VMID_HELPER}" --format tsv all | awk '{print $1}'
    return
  fi

  "${YQ}" -r '.vms | to_entries[] | select(.value.backup == true) | .value.vmid' "${CONFIG}" 2>/dev/null || true
  if [[ -f "${APPS_CONFIG}" ]]; then
    "${YQ}" -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .value.environments[]?.vmid' "${APPS_CONFIG}" 2>/dev/null || true
  fi
}

is_backup_backed() {
  local vmid="$1"
  grep -qxF "${vmid}" <<< "${BACKUP_VMIDS}"
}

verify_cidata_class() {
  local node="$1"
  local volume="$2"
  local node_ip dataset refer refer_kib

  if ! node_ip="$(node_ip_for "${node}")"; then
    echo "ERROR: config node ${node} is not in ${CONFIG}" >&2
    return 1
  fi

  dataset="${STORAGE_POOL}/data/${volume#*:}"
  if ! ssh_capture refer "${node_ip}" "zfs list -H -o refer ${dataset} 2>/dev/null"; then
    echo "ERROR: could not verify cidata-class refer size for ${dataset} on ${node}" >&2
    return 1
  fi
  refer="${refer%%$'\n'*}"
  refer_kib="$(refer_to_kib "${refer}")"
  [[ "${refer_kib}" -le "${MAX_CIDATA_REFER_KIB}" ]]
}

# --- Discovery ---

echo "==> Scanning cluster for rename victims..."

remote="n=0; for f in /etc/pve/nodes/*/qemu-server/*.conf; do [ -e \"\$f\" ] || continue; n=\$((n+1)); awk '/^\\[/{exit} /^(ide|sata|scsi|virtio)[0-9]+:.*media=cdrom/{print FILENAME\":\"\$0}' \"\$f\"; done; echo \"__SCAN_FILES__ \$n\"; echo __SCAN_DONE__"

out=""
scanned=0
for node_ip in "${NODE_IPS[@]}"; do
  set +e
  out=$("${SSH}" -n "${SSH_OPTS[@]}" "root@${node_ip}" "${remote}" 2>/dev/null)
  rc=$?
  set -e
  if [[ "${rc}" -eq 0 ]] && grep -qx '__SCAN_DONE__' <<< "${out}"; then
    scanned=1
    break
  fi
done

if [[ "${scanned}" -ne 1 ]]; then
  echo "ERROR: could not scan cidata on any cluster member" >&2
  echo "G7 remediation:" >&2
  echo "  framework/scripts/validate.sh" >&2
  echo "  framework/scripts/realign-cidata.sh --dry-run --all" >&2
  exit 1
fi

VICTIMS=()
DISCOVERY_FAILED=0
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  case "${line}" in
    __SCAN_DONE__|__SCAN_FILES__*) continue ;;
  esac

  file="${line%%.conf:*}.conf"
  confline="${line#*.conf:}"
  drivekey="${confline%%:*}"
  after="${confline#*:}"
  after="${after#"${after%%[![:space:]]*}"}"
  volume="${after%%,*}"
  vmid="${file##*/}"
  vmid="${vmid%.conf}"
  node="${file#/etc/pve/nodes/}"
  node="${node%%/*}"

  if [[ "${volume}" =~ ^([^:]+):vm-([0-9]+)-disk-[0-9]+$ ]]; then
    vol_pool="${BASH_REMATCH[1]}"
    vol_vmid="${BASH_REMATCH[2]}"
    [[ "${vol_pool}" == "${STORAGE_POOL}" && "${vol_vmid}" == "${vmid}" ]] || continue
    [[ -z "${TARGET_VMID}" || "${TARGET_VMID}" == "${vmid}" ]] || continue

    if verify_cidata_class "${node}" "${volume}"; then
      VICTIMS+=("${vmid}|${node}|${drivekey}|${volume}")
    else
      DISCOVERY_FAILED=1
    fi
  fi
done <<< "${out}"

if [[ "${DISCOVERY_FAILED}" -ne 0 ]]; then
  echo "ERROR: one or more candidate rename victims could not be classified; refusing to proceed" >&2
  echo "G7 remediation:" >&2
  echo "  framework/scripts/validate.sh" >&2
  echo "  framework/scripts/realign-cidata.sh --dry-run --all" >&2
  exit 1
fi

if [[ "${#VICTIMS[@]}" -eq 0 ]]; then
  if [[ -n "${TARGET_VMID}" ]]; then
    echo "No rename victim found for VM ${TARGET_VMID}."
  else
    echo "No rename victims found cluster-wide."
  fi
  exit 0
fi

BACKUP_VMIDS=""
if ! run_capture BACKUP_VMIDS backup_backed_vmids; then
  echo "ERROR: could not read backup-backed VM manifest; refusing to realign" >&2
  echo "G7 remediation:" >&2
  echo "  framework/scripts/validate.sh" >&2
  echo "  framework/scripts/realign-cidata.sh --dry-run --all" >&2
  exit 1
fi

echo "Found ${#VICTIMS[@]} victim(s)."

# --- Realignment ---

FAILED_VMIDS=()
STOP_BATCH=0

record_failure() {
  local vmid="$1"
  local reason="$2"
  FAILED_VMIDS+=("${vmid}: ${reason}")
}

path_a() {
  local node_ip="$1"
  local vmid="$2"
  local drivekey="$3"

  echo "  Path A: stopped or HA-error service; using disabled->started ladder."
  ssh_node "${node_ip}" "ha-manager set vm:${vmid} --state disabled" || return 1
  run_repoint_and_update "${node_ip}" "${vmid}" "${drivekey}" || return 1
  ssh_node "${node_ip}" "ha-manager set vm:${vmid} --state started" || return 1
  wait_for_qm_running "${node_ip}" "${vmid}"
}

path_b() {
  local node_ip="$1"
  local vmid="$2"
  local drivekey="$3"

  echo "  Path B: running HA-healthy service; live cdrom hot-swap."
  run_repoint_and_update "${node_ip}" "${vmid}" "${drivekey}" || return 1
  current_config_is_canonical "${node_ip}" "${vmid}" "${drivekey}"
}

path_c() {
  local node_ip="$1"
  local vmid="$2"
  local drivekey="$3"
  local ha_config group state add_cmd ha_state

  echo "  Path C: fallback maintenance path with HA config capture/restore."
  if ! ha_config="$(ha_config_for "${vmid}")"; then
    echo "  ERROR: could not capture HA config for VM ${vmid}" >&2
    return 1
  fi
  group="$(printf '%s\n' "${ha_config}" | ha_config_value group || true)"
  state="$(printf '%s\n' "${ha_config}" | ha_config_value state || true)"
  [[ -n "${state}" ]] || state="started"

  ssh_node "${node_ip}" "ha-manager remove vm:${vmid}" || return 1
  stop_with_reissue_loop "${node_ip}" "${vmid}" || return 1
  run_repoint_and_update "${node_ip}" "${vmid}" "${drivekey}" || return 1
  ssh_node "${node_ip}" "qm start ${vmid}" || return 1
  wait_for_qm_running "${node_ip}" "${vmid}" || return 1

  add_cmd="ha-manager add vm:${vmid} --state ${state}"
  if [[ -n "${group}" ]]; then
    add_cmd="${add_cmd} --group ${group}"
  fi
  ssh_node "${node_ip}" "${add_cmd}" || return 1

  ha_state="$(ha_state_for "${vmid}")"
  [[ "${ha_state}" != "unknown" ]] || return 1
  if [[ -n "${group}" ]]; then
    ha_config="$(ha_config_for "${vmid}")" || return 1
    grep -qE "(^|[[:space:]])group:?[[:space:]]+${group}([[:space:]]|$)" <<< "${ha_config}" || return 1
  fi
}

for victim in "${VICTIMS[@]}"; do
  if [[ "${STOP_BATCH}" -ne 0 ]]; then
    break
  fi

  IFS='|' read -r vmid config_node drivekey volume <<< "${victim}"

  echo "==> VM ${vmid}: ${config_node} ${drivekey}=${volume}"

  node_ip=""
  if ! node_ip="$(node_ip_for "${config_node}")"; then
    echo "  ERROR: config node ${config_node} is not in ${CONFIG}" >&2
    print_g7_remediation "${vmid}" "unknown config node"
    record_failure "${vmid}" "unknown config node"
    continue
  fi

  resource_row=""
  if ! resource_row="$(cluster_resource_row "${vmid}")"; then
    echo "  ERROR: could not read pvesh cluster resource state for VM ${vmid}" >&2
    print_g7_remediation "${vmid}" "cluster resource state unreadable"
    record_failure "${vmid}" "cluster resource state unreadable"
    continue
  fi
  IFS=$'\t' read -r current_node run_state <<< "${resource_row}"
  ha_state="$(ha_state_for "${vmid}")"
  ha_healthy=0
  [[ "${ha_state}" == "started" ]] && ha_healthy=1
  echo "  State: pvesh_node=${current_node:-unknown} config_node=${config_node} run_state=${run_state:-unknown} ha_state=${ha_state}"

  if [[ -z "${current_node}" || "${current_node}" != "${config_node}" ]]; then
    echo "  ABORT: ambiguous owner; pvesh node (${current_node:-unknown}) differs from config node (${config_node})." >&2
    print_g7_remediation "${vmid}" "ambiguous owner"
    record_failure "${vmid}" "ambiguous owner"
    continue
  fi

  migration_check_rc=0
  set +e
  active_migration_exists "${vmid}"
  migration_check_rc=$?
  set -e
  if [[ "${migration_check_rc}" -eq 0 ]]; then
    echo "  ABORT: active migration task exists for VM ${vmid}." >&2
    print_g7_remediation "${vmid}" "active migration"
    record_failure "${vmid}" "active migration"
    continue
  elif [[ "${migration_check_rc}" -ne 1 ]]; then
    echo "  ABORT: could not verify active migration tasks for VM ${vmid}." >&2
    print_g7_remediation "${vmid}" "migration state unreadable"
    record_failure "${vmid}" "migration state unreadable"
    continue
  fi

  if is_backup_backed "${vmid}"; then
    echo "  REFUSAL: VM ${vmid} is backup-backed/precious-state; realign-cidata.sh will not mutate it." >&2
    print_g7_remediation "${vmid}" "backup-backed VM"
    record_failure "${vmid}" "backup-backed VM"
    continue
  fi

  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "  [DRY-RUN] ${CLEANUP_ORPHAN} --vmid ${vmid} --node ${current_node}"
    if [[ "${run_state}" != "running" || "${ha_state}" == "error" ]]; then
      echo "  [DRY-RUN] Path A: ha-manager set vm:${vmid} --state disabled"
      echo "  [DRY-RUN] Path A: $(canonical_repoint_cmd "${vmid}" "${drivekey}")"
      echo "  [DRY-RUN] Path A: qm cloudinit update ${vmid}"
      echo "  [DRY-RUN] Path A: ha-manager set vm:${vmid} --state started"
    elif [[ "${ha_healthy}" -eq 1 ]]; then
      echo "  [DRY-RUN] Path B: $(canonical_repoint_cmd "${vmid}" "${drivekey}")"
      echo "  [DRY-RUN] Path B: qm cloudinit update ${vmid}"
      echo "  [DRY-RUN] Path B: qm config ${vmid} --current"
      echo "  [DRY-RUN] Path C fallback if Path B fails: capture HA config, remove, stop-loop, repair, start, add restored group/state"
    else
      echo "  [DRY-RUN] Path C: running but HA state is ${ha_state}; capture HA config, remove, stop-loop, repair, start, add restored group/state"
    fi
    echo "  [DRY-RUN] ${CLEANUP_ORPHAN} --vmid ${vmid} --node ${current_node}"
    continue
  fi

  echo "  Clearing stale canonical on current host before reattach..."
  if ! cleanup_scoped "${current_node}" "${vmid}"; then
    echo "  ERROR: pre-realign cleanup failed for VM ${vmid} on ${current_node}" >&2
    print_g7_remediation "${vmid}" "pre-realign cleanup failed"
    record_failure "${vmid}" "pre-realign cleanup failed"
    continue
  fi

  if [[ "${run_state}" != "running" || "${ha_state}" == "error" ]]; then
    if ! path_a "${node_ip}" "${vmid}" "${drivekey}"; then
      echo "  ERROR: Path A failed for VM ${vmid}; victim retained for inspection." >&2
      print_g7_remediation "${vmid}" "Path A failed"
      record_failure "${vmid}" "Path A failed"
      STOP_BATCH=1
      continue
    fi
  elif [[ "${ha_healthy}" -eq 1 ]]; then
    if ! path_b "${node_ip}" "${vmid}" "${drivekey}"; then
      echo "  WARNING: Path B hot-swap failed for VM ${vmid}; falling back to Path C." >&2
      if ! path_c "${node_ip}" "${vmid}" "${drivekey}"; then
        echo "  ERROR: Path C failed for VM ${vmid}; victim retained for inspection." >&2
        print_g7_remediation "${vmid}" "Path C failed"
        record_failure "${vmid}" "Path C failed"
        STOP_BATCH=1
        continue
      fi
    fi
  else
    if ! path_c "${node_ip}" "${vmid}" "${drivekey}"; then
      echo "  ERROR: Path C failed for VM ${vmid}; victim retained for inspection." >&2
      print_g7_remediation "${vmid}" "Path C failed"
      record_failure "${vmid}" "Path C failed"
      STOP_BATCH=1
      continue
    fi
  fi

  echo "  Sweeping orphan victim after VM is up..."
  if ! cleanup_scoped "${current_node}" "${vmid}"; then
    echo "  ERROR: post-realign cleanup failed for VM ${vmid} on ${current_node}" >&2
    print_g7_remediation "${vmid}" "post-realign cleanup failed"
    record_failure "${vmid}" "post-realign cleanup failed"
    continue
  fi

  echo "  SUCCESS: VM ${vmid} realigned."
done

if [[ "${#FAILED_VMIDS[@]}" -gt 0 ]]; then
  echo ""
  echo "FAIL: One or more realignments failed."
  printf '  - %s\n' "${FAILED_VMIDS[@]}"
  if [[ "${STOP_BATCH}" -ne 0 ]]; then
    echo "Batch stopped after a state-changing failure; remaining victims were untouched."
  fi
  echo "Next safe framework checks:"
  echo "  framework/scripts/validate.sh"
  echo "  framework/scripts/realign-cidata.sh --dry-run --all"
  exit 1
fi

echo ""
echo "All targets realigned successfully."
echo "Next step: verify with validate.sh"
echo "  framework/scripts/validate.sh"
