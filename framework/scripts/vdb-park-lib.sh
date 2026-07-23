#!/usr/bin/env bash
# vdb-park-lib.sh — park/adopt bridge for preserving vdb across VM recreation.
#
# Sprint 044 transition mechanism: raw ZFS rename parking selected by
# docs/research/RESEARCH-004-vdb-survives-recreation.md. Sunset is the
# upstream PVE keep-volume/detach-without-delete verb tracked by
# docs/reports/2026-07-05-pve-upstream-detach-campaign.md. Verified
# qemu-server baseline: 9.0.30. Issue #412 must rerun the gated experiment
# before extending the trusted version list.

set -euo pipefail

VDB_PARK_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VDB_PARK_REPO_DIR="$(cd "${VDB_PARK_SCRIPT_DIR}/../.." && pwd)"

: "${VDB_PARK_CONFIG:=${VDB_PARK_REPO_DIR}/site/config.yaml}"
: "${VDB_PARK_APPS_CONFIG:=${VDB_PARK_REPO_DIR}/site/applications.yaml}"
: "${VDB_PARK_VM_SCOPE_SCRIPT:=${VDB_PARK_SCRIPT_DIR}/vm-scope.sh}"
: "${VDB_PARK_VERIFIED_QEMU_SERVER:=9.0.30}"
: "${VDB_PARK_DATA_DISK_SLOT:=scsi1}"
: "${VDB_PARK_STOP_TIMEOUT:=30}"
: "${VDB_PARK_STOP_INTERVAL:=2}"

VDB_PARK_STATUS_FILE=""
VDB_PARK_CURRENT_MANIFEST=""

vdb_park_log() {
  printf '%s\n' "$*"
}

vdb_park_warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

vdb_park_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

vdb_park_json_quote() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

vdb_park_shell_quote() {
  local value="$1"
  printf "'%s'" "$(printf '%s' "$value" | sed "s/'/'\\\\''/g")"
}

vdb_park_require_file() {
  local file="$1"
  local label="$2"
  if [[ ! -f "$file" ]]; then
    vdb_park_error "${label} not found: ${file}"
    return 1
  fi
}

vdb_park_dataset_parent() {
  local pool
  pool="$(yq -r '.storage.pool_name // .proxmox.storage_pool // ""' "$VDB_PARK_CONFIG" 2>/dev/null || true)"
  if [[ -z "$pool" || "$pool" == "null" ]]; then
    vdb_park_error "could not resolve storage pool from ${VDB_PARK_CONFIG}"
    return 1
  fi
  printf '%s/data\n' "$pool"
}

vdb_park_storage_pool() {
  yq -r '.proxmox.storage_pool // .storage.pool_name // ""' "$VDB_PARK_CONFIG"
}

vdb_park_node_rows() {
  yq -r '.nodes[] | [.name, .mgmt_ip] | @tsv' "$VDB_PARK_CONFIG"
}

vdb_park_first_node_ip() {
  yq -r '.nodes[0].mgmt_ip' "$VDB_PARK_CONFIG"
}

vdb_park_node_ip() {
  local node="$1"
  NODE_NAME="$node" yq -r '.nodes[] | select(.name == strenv(NODE_NAME)) | .mgmt_ip' "$VDB_PARK_CONFIG"
}

vdb_park_ssh_ip() {
  local ip="$1"
  shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
    "root@${ip}" "$@"
}

vdb_park_ssh_node() {
  local node="$1"
  shift
  local ip
  ip="$(vdb_park_node_ip "$node")"
  if [[ -z "$ip" || "$ip" == "null" ]]; then
    vdb_park_error "node ${node} has no management IP in ${VDB_PARK_CONFIG}"
    return 1
  fi
  vdb_park_ssh_ip "$ip" "$@"
}

vdb_park_ssh_first() {
  local ip
  ip="$(vdb_park_first_node_ip)"
  vdb_park_ssh_ip "$ip" "$@"
}

vdb_park_env_enabled() {
  local env="$1"
  [[ "$env" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  [[ "$(yq -r ".environments.${env}.vdb_park_bridge // false" "$VDB_PARK_CONFIG" 2>/dev/null || echo false)" == "true" ]]
}

vdb_park_class_category() {
  local label="$1"
  local classes rc
  set +e
  classes="$("${VDB_PARK_VM_SCOPE_SCRIPT}" classes --format json 2>/dev/null)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 || -z "$classes" ]]; then
    vdb_park_error "vm-scope classes query failed while classifying ${label}"
    return 1
  fi
  LABEL="$label" VM_CLASSES_JSON="$classes" python3 - <<'PY'
import json
import os
import re
import sys

label = os.environ["LABEL"].replace("-", "_")
classes = json.loads(os.environ["VM_CLASSES_JSON"])

def resolve(name):
    if name in classes:
        return name
    m = re.match(r"^(.+)_(dev|prod)$", name)
    if m:
        if m.group(1) in classes:
            return m.group(1)
        numbered = re.sub(r"[0-9]+$", "", m.group(1))
        if numbered in classes:
            return numbered
    return None

key = resolve(label)
if key is None:
    print("unknown")
else:
    print(classes.get(key, {}).get("category") or "unknown")
PY
}

vdb_park_expected_node() {
  local label="$1"
  local env="$2"
  LABEL="$label" ENTRY_ENV="$env" CONFIG_FILE="$VDB_PARK_CONFIG" APPS_CONFIG_FILE="$VDB_PARK_APPS_CONFIG" python3 - <<'PY'
import json
import os
import subprocess
import sys

def load_yaml(path, default):
    if not os.path.exists(path):
        return default
    raw = subprocess.check_output(["yq", "-o=json", ".", path], text=True)
    return json.loads(raw)

label = os.environ["LABEL"]
entry_env = os.environ["ENTRY_ENV"]
config = load_yaml(os.environ["CONFIG_FILE"], {})
apps = load_yaml(os.environ["APPS_CONFIG_FILE"], {"applications": {}})

vm = (config.get("vms") or {}).get(label)
if isinstance(vm, dict):
    print(vm.get("node") or "")
    sys.exit(0)

if "_" in label:
    app, env = label.rsplit("_", 1)
else:
    app, env = label, entry_env
app_cfg = (apps.get("applications") or {}).get(app)
if isinstance(app_cfg, dict):
    env_cfg = (app_cfg.get("environments") or {}).get(env)
    if isinstance(env_cfg, dict):
        print(env_cfg.get("node") or app_cfg.get("node") or "")
        sys.exit(0)

print("")
PY
}

vdb_park_expected_size_gb() {
  local entry_json="$1"
  ENTRY_JSON="$entry_json" CONFIG_FILE="$VDB_PARK_CONFIG" APPS_CONFIG_FILE="$VDB_PARK_APPS_CONFIG" python3 - <<'PY'
import json
import os
import subprocess

entry = json.loads(os.environ["ENTRY_JSON"])
for key in ("vdb_size_gb", "data_disk_size_gb", "data_disk_size", "size_gb", "size"):
    value = entry.get(key)
    if value not in (None, "", "null"):
        print(str(value).rstrip("Gg"))
        raise SystemExit(0)

def load_yaml(path, default):
    if not os.path.exists(path):
        return default
    raw = subprocess.check_output(["yq", "-o=json", ".", path], text=True)
    return json.loads(raw)

label = entry.get("label", "")
env = entry.get("env", "")
config = load_yaml(os.environ["CONFIG_FILE"], {})
apps = load_yaml(os.environ["APPS_CONFIG_FILE"], {"applications": {}})

vm = (config.get("vms") or {}).get(label)
if isinstance(vm, dict):
    for key in ("vdb_size_gb", "data_disk_size_gb", "data_disk_size"):
        value = vm.get(key)
        if value not in (None, "", "null"):
            print(str(value).rstrip("Gg"))
            raise SystemExit(0)

if "_" in label:
    app, app_env = label.rsplit("_", 1)
else:
    app, app_env = label, env
app_cfg = (apps.get("applications") or {}).get(app)
if isinstance(app_cfg, dict):
    env_cfg = (app_cfg.get("environments") or {}).get(app_env) or {}
    keys = [
        f"data_disk_size_{app_env}",
        "data_disk_size_gb",
        "data_disk_size",
    ]
    for source in (env_cfg, app_cfg):
        if not isinstance(source, dict):
            continue
        for key in keys:
            value = source.get(key)
            if value not in (None, "", "null"):
                print(str(value).rstrip("Gg"))
                raise SystemExit(0)

print("")
PY
}

vdb_park_cluster_resources_json() {
  vdb_park_ssh_first "pvesh get /cluster/resources --type vm --output-format json"
}

vdb_park_hosting_node() {
  local vmid="$1"
  local resources rc
  set +e
  resources="$(vdb_park_cluster_resources_json 2>/dev/null)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 || -z "$resources" ]]; then
    vdb_park_error "failed to query cluster resources while locating VMID ${vmid}"
    return 2
  fi
  jq -r --argjson vmid "$vmid" 'first(.[]? | select(.vmid == $vmid) | .node) // empty' <<< "$resources"
}

vdb_park_qemu_server_version() {
  local node="$1"
  vdb_park_ssh_node "$node" "dpkg-query -W -f='\${Version}' qemu-server 2>/dev/null"
}

vdb_park_version_allowed() {
  local version="$1"
  local allowed
  for allowed in $VDB_PARK_VERIFIED_QEMU_SERVER; do
    [[ "$version" == "$allowed" ]] && return 0
  done
  return 1
}

vdb_park_pin_from_entry() {
  local entry_json="$1"
  ENTRY_JSON="$entry_json" VDB_PARK_PIN_FILE="${VDB_PARK_PIN_FILE:-}" python3 - <<'PY'
import json
import os
import sys

entry = json.loads(os.environ["ENTRY_JSON"])
pin = entry.get("pin")
trust = entry.get("pin_trust") or "unknown"
volid = ""
if isinstance(pin, dict):
    volid = pin.get("volid") or ""
    trust = pin.get("trust") or trust
elif isinstance(pin, str):
    volid = pin

pin_file = os.environ.get("VDB_PARK_PIN_FILE") or ""
if not volid and pin_file and os.path.exists(pin_file):
    with open(pin_file) as f:
        pins = (json.load(f).get("pins") or {})
    value = pins.get(str(entry.get("vmid")))
    if isinstance(value, dict):
        volid = value.get("volid") or ""
        trust = value.get("trust") or trust
    elif isinstance(value, str):
        volid = value

print(json.dumps({"volid": volid, "trust": trust}))
PY
}

vdb_park_pin_volid() {
  jq -r '.volid // empty' <<< "$1"
}

vdb_park_pin_trust() {
  jq -r '.trust // "unknown"' <<< "$1"
}

vdb_park_park_name() {
  local vmid="$1"
  printf 'mycofu-park-%s-vdb\n' "$vmid"
}

vdb_park_remediation_message() {
  local vmid="$1"
  local env="$2"
  local pin="$3"
  local manifest="${4:-${VDB_PARK_CURRENT_MANIFEST:-build/preboot-restore-${env}.json}}"
  local status="${5:-${VDB_PARK_STATUS_FILE:-build/vdb-park-status-${env}.json}}"

  cat <<EOF
VMID ${vmid} has a parked vdb that may contain writes newer than the PBS pin.
Sanctioned exits, in order:
  1. Inspect the park and fix the adoption blocker:
     framework/scripts/parked-vdb.sh inspect ${vmid}
     framework/scripts/restore-before-start.sh ${env} --manifest ${manifest} --park-status ${status} --recovery-mode
  2. Accept loss of all writes newer than pin ${pin:-unknown} and release the park:
     framework/scripts/parked-vdb.sh release ${vmid}
EOF
}

vdb_park_status_init() {
  local file="$1"
  local scope="$2"
  local mode="${3:-normal}"
  local generated_at run_id
  generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run_id="${scope}-${generated_at}-$$-${RANDOM}"
  mkdir -p "$(dirname "$file")"
  STATUS_FILE="$file" STATUS_SCOPE="$scope" STATUS_MODE="$mode" GENERATED_AT="$generated_at" RUN_ID="$run_id" python3 - <<'PY' > "${file}.tmp"
import json
import os
import sys

path = os.environ["STATUS_FILE"]
mode = os.environ["STATUS_MODE"]
status = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            status = json.load(f)
    except Exception as exc:
        print(f"invalid existing vdb park status file {path}: {exc}", file=sys.stderr)
        raise SystemExit(1)
if not isinstance(status, dict):
    print(f"invalid existing vdb park status file {path}: expected object", file=sys.stderr)
    raise SystemExit(1)
entries = status.get("entries", [])
if not isinstance(entries, list):
    entries = []
if mode == "normal":
    non_terminal = {"park-prepared", "detaching", "parked", "adopt-cleanup-failed"}
    entries = [e for e in entries if isinstance(e, dict) and e.get("status") in non_terminal]
elif mode != "recovery":
    print(f"invalid vdb park status init mode {mode}", file=sys.stderr)
    raise SystemExit(1)
status["version"] = 1
status["scope"] = os.environ["STATUS_SCOPE"]
status["generated_at"] = os.environ["GENERATED_AT"]
status["run_id"] = os.environ["RUN_ID"]
if not isinstance(status.get("qemu_server_versions"), dict):
    status["qemu_server_versions"] = {}
status["entries"] = entries
print(json.dumps(status, indent=2))
PY
  mv "${file}.tmp" "$file"
}

vdb_park_status_upsert_json() {
  local file="$1"
  local entry_json="$2"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/vdb-park-status.XXXXXX")"
  STATUS_FILE="$file" ENTRY_JSON="$entry_json" python3 - <<'PY' > "$tmp"
import json
import os

with open(os.environ["STATUS_FILE"]) as f:
    status = json.load(f)
entry = json.loads(os.environ["ENTRY_JSON"])
vmid = int(entry["vmid"])
if status.get("run_id"):
    entry["run_id"] = status["run_id"]
if status.get("generated_at"):
    entry["updated_at"] = status["generated_at"]
entries = [e for e in status.get("entries", []) if int(e.get("vmid", -1)) != vmid]
entries.append(entry)
entries.sort(key=lambda e: (str(e.get("label", "")), int(e.get("vmid", 0))))
status["entries"] = entries
print(json.dumps(status, indent=2))
PY
  mv "$tmp" "$file"
}

vdb_park_status_set() {
  local file="$1"
  local vmid="$2"
  local status_value="$3"
  local detail="${4:-}"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/vdb-park-status.XXXXXX")"
  STATUS_FILE="$file" VMID="$vmid" STATUS_VALUE="$status_value" DETAIL="$detail" python3 - <<'PY' > "$tmp"
import json
import os

with open(os.environ["STATUS_FILE"]) as f:
    status = json.load(f)
vmid = int(os.environ["VMID"])
for entry in status.get("entries", []):
    if int(entry.get("vmid", -1)) == vmid:
        entry["status"] = os.environ["STATUS_VALUE"]
        entry["detail"] = os.environ["DETAIL"]
        if status.get("run_id"):
            entry["run_id"] = status["run_id"]
        if status.get("generated_at"):
            entry["updated_at"] = status["generated_at"]
print(json.dumps(status, indent=2))
PY
  mv "$tmp" "$file"
}

vdb_park_status_record_version() {
  local file="$1"
  local node="$2"
  local version="$3"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/vdb-park-status.XXXXXX")"
  jq --arg node "$node" --arg version "$version" \
    '.qemu_server_versions[$node] = $version' "$file" > "$tmp"
  mv "$tmp" "$file"
}

vdb_park_manifest_entries() {
  local manifest="$1"
  local scope="${2:-all}"
  jq -c --arg scope "$scope" '
    (if type == "array" then . else .entries end)[]
    | select($scope == "all" or (.env // "") == $scope)
    | select(.reason == "replace")
  ' "$manifest"
}

vdb_park_discover_vdb_json() {
  local qm_config="$1"
  local expected_size_gb="$2"
  local expected_slot="$3"
  local storage_pool="$4"
  QM_CONFIG="$qm_config" EXPECTED_SIZE_GB="$expected_size_gb" EXPECTED_SLOT="$expected_slot" STORAGE_POOL="$storage_pool" python3 - <<'PY'
import json
import os
import re
import sys

expected = str(os.environ["EXPECTED_SIZE_GB"]).rstrip("Gg")
expected_slot = os.environ["EXPECTED_SLOT"] or "scsi1"
storage_pool = os.environ["STORAGE_POOL"]
slot_candidate = None
size_matches = []

def norm_size(value):
    if not value:
        return ""
    value = str(value).strip()
    m = re.fullmatch(r"([0-9]+)([GgMmTt]?)", value)
    if not m:
        return value
    number = int(m.group(1))
    unit = m.group(2).lower() or "g"
    if unit == "g":
        return str(number)
    if unit == "m" and number % 1024 == 0:
        return str(number // 1024)
    if unit == "t":
        return str(number * 1024)
    return value

for line in os.environ["QM_CONFIG"].splitlines():
    m = re.match(r"^(scsi[0-9]+):\s*([^,\s]+)(?:,(.*))?$", line.strip())
    if not m:
        continue
    slot, volid, rest = m.group(1), m.group(2), m.group(3) or ""
    if ":" not in volid:
        continue
    storage, volname = volid.split(":", 1)
    if storage_pool and storage != storage_pool:
        continue
    options = []
    size = ""
    for part in [p for p in rest.split(",") if p]:
        if part.startswith("size="):
            size = part.split("=", 1)[1]
        else:
            options.append(part)
    candidate = {
        "slot": slot,
        "storage": storage,
        "volname": volname,
        "drive_options": ",".join(options),
        "size": size or f"{expected}G",
    }
    if slot == expected_slot:
        slot_candidate = candidate
    if norm_size(size) == norm_size(expected):
        size_matches.append(candidate)

if slot_candidate is None:
    print(f"expected vdb slot {expected_slot} is missing", file=sys.stderr)
    sys.exit(1)
if len(size_matches) > 1:
    print("ambiguous vdb candidates matched the expected size", file=sys.stderr)
    sys.exit(2)
if norm_size(slot_candidate.get("size")) != norm_size(expected):
    print(
        f"expected vdb slot {expected_slot} size {slot_candidate.get('size') or 'unknown'} "
        f"does not match planned data-disk size {expected}G",
        file=sys.stderr,
    )
    sys.exit(1)

print(json.dumps(slot_candidate, sort_keys=True))
PY
}

vdb_park_slot_disk_json() {
  local qm_config="$1"
  local expected_slot="$2"
  local storage_pool="$3"
  local expected_volname="$4"
  QM_CONFIG="$qm_config" EXPECTED_SLOT="$expected_slot" STORAGE_POOL="$storage_pool" EXPECTED_VOLNAME="$expected_volname" python3 - <<'PY'
import json
import os
import re
import sys

expected_slot = os.environ["EXPECTED_SLOT"]
storage_pool = os.environ["STORAGE_POOL"]
expected_volname = os.environ["EXPECTED_VOLNAME"]

for line in os.environ["QM_CONFIG"].splitlines():
    m = re.match(r"^(scsi[0-9]+):\s*([^,\s]+)(?:,(.*))?$", line.strip())
    if not m or m.group(1) != expected_slot:
        continue
    volid = m.group(2)
    rest = m.group(3) or ""
    if ":" not in volid:
        break
    storage, volname = volid.split(":", 1)
    if storage != storage_pool or volname != expected_volname:
        break
    options = []
    size = ""
    for part in [p for p in rest.split(",") if p]:
        if part.startswith("size="):
            size = part.split("=", 1)[1]
        else:
            options.append(part)
    print(json.dumps({
        "slot": expected_slot,
        "storage": storage,
        "volname": volname,
        "drive_options": ",".join(options),
        "size": size,
    }, sort_keys=True))
    raise SystemExit(0)

print(
    f"expected fresh restore target {storage_pool}:{expected_volname} on {expected_slot} is missing",
    file=sys.stderr,
)
raise SystemExit(1)
PY
}

vdb_park_zfs_exists() {
  local node="$1"
  local dataset="$2"
  local rc
  if vdb_park_ssh_node "$node" "zfs list -H -o name $(vdb_park_shell_quote "$dataset") >/dev/null 2>&1"; then
    return 0
  else
    rc=$?
  fi
  case "$rc" in
    1) return 1 ;;
    *)
      vdb_park_error "failed to query zfs dataset ${dataset} on ${node} (rc=${rc})"
      return 2
      ;;
  esac
}

vdb_park_zfs_get_value() {
  local node="$1"
  local prop="$2"
  local dataset="$3"
  vdb_park_ssh_node "$node" "zfs get -H -o value ${prop} $(vdb_park_shell_quote "$dataset") 2>/dev/null"
}

vdb_park_set_prop() {
  local node="$1"
  local dataset="$2"
  local prop="$3"
  local value="$4"
  vdb_park_ssh_node "$node" "zfs set ${prop}=$(vdb_park_shell_quote "$value") $(vdb_park_shell_quote "$dataset")"
}

vdb_park_clear_props() {
  local node="$1"
  local dataset="$2"
  local prop
  for prop in mycofu:orig-volname mycofu:slot mycofu:drive-options mycofu:guid mycofu:pin-volid mycofu:parked-at; do
    vdb_park_ssh_node "$node" "zfs inherit -r ${prop} $(vdb_park_shell_quote "$dataset") 2>/dev/null || true"
  done
}

vdb_park_replication_jobs_for_vmid() {
  local vmid="$1"
  local jobs
  jobs="$(vdb_park_ssh_first "pvesh get /cluster/replication --output-format json" 2>/dev/null || echo "[]")"
  jq -r --argjson vmid "$vmid" --arg prefix "${vmid}-" '
    .[]?
    | select((.guest // null) == $vmid or ((.id // "") | startswith($prefix)))
    | .id
  ' <<< "$jobs"
}

vdb_park_disable_replication() {
  local vmid="$1"
  local job
  while IFS= read -r job; do
    [[ -z "$job" ]] && continue
    vdb_park_ssh_first "pvesh set /cluster/replication/${job} --disable 1"
  done < <(vdb_park_replication_jobs_for_vmid "$vmid")
}

vdb_park_enable_recorded_replication() {
  local entry_json="$1"
  local job
  while IFS= read -r job; do
    [[ -z "$job" ]] && continue
    vdb_park_ssh_first "pvesh set /cluster/replication/${job} --disable 0"
  done < <(jq -r '.replication_jobs[]? // empty' <<< "$entry_json")
}

vdb_park_stop_vm() {
  local node="$1"
  local vmid="$2"
  local waited=0
  local status=""

  vdb_park_ssh_node "$node" "qm stop ${vmid} --skiplock 2>/dev/null || true"
  while [[ "$waited" -lt "$VDB_PARK_STOP_TIMEOUT" ]]; do
    status="$(vdb_park_ssh_node "$node" "qm status ${vmid} 2>/dev/null | awk '{print \$2}'" 2>/dev/null || true)"
    if [[ "$status" == "stopped" ]]; then
      return 0
    fi
    sleep "$VDB_PARK_STOP_INTERVAL"
    waited=$((waited + VDB_PARK_STOP_INTERVAL))
    vdb_park_ssh_node "$node" "qm stop ${vmid} --skiplock 2>/dev/null || true"
  done

  vdb_park_error "VMID ${vmid} did not stop on ${node}; status=${status:-unknown}"
  return 1
}

vdb_park_fingerprint_dataset() {
  local node="$1"
  local dataset="$2"
  if [[ "${VDB_PARK_FINGERPRINT:-}" != "full" ]]; then
    printf 'null\n'
    return 0
  fi
  vdb_park_ssh_node "$node" "sha256sum /dev/zvol/$(vdb_park_shell_quote "$dataset") 2>/dev/null | awk '{print \$1}'"
}

vdb_park_build_entry_json() {
  local base_entry="$1"
  local node="$2"
  local dataset_parent="$3"
  local disk_json="$4"
  local guid="$5"
  local pin="$6"
  local pin_trust="$7"
  local fingerprint="$8"
  local version="$9"
  local jobs_json="${10}"
  local parked_at="${11}"

  BASE_ENTRY="$base_entry" DISK_JSON="$disk_json" NODE="$node" DATASET_PARENT="$dataset_parent" \
    GUID="$guid" PIN="$pin" PIN_TRUST="$pin_trust" FINGERPRINT="$fingerprint" VERSION="$version" \
    JOBS_JSON="$jobs_json" PARKED_AT="$parked_at" python3 - <<'PY'
import json
import os

entry = json.loads(os.environ["BASE_ENTRY"])
disk = json.loads(os.environ["DISK_JSON"])
vmid = int(entry["vmid"])
park_name = f"mycofu-park-{vmid}-vdb"
fingerprint = os.environ["FINGERPRINT"]
entry.update({
    "node": os.environ["NODE"],
    "storage": disk["storage"],
    "dataset_parent": os.environ["DATASET_PARENT"],
    "volname": disk["volname"],
    "slot": disk["slot"],
    "drive_options": disk.get("drive_options", ""),
    "size": disk.get("size", ""),
    "guid": os.environ["GUID"],
    "park_name": park_name,
    "pin": os.environ["PIN"],
    "pin_trust": os.environ["PIN_TRUST"],
    "fingerprint": None if fingerprint == "null" else {"park_sha256": fingerprint},
    "qemu_server_version": os.environ["VERSION"],
    "replication_jobs": json.loads(os.environ["JOBS_JSON"]),
    "parked_at": os.environ["PARKED_AT"],
    "status": "parked",
    "detail": "parked before VM recreation",
})
print(json.dumps(entry, sort_keys=True))
PY
}

vdb_park_build_progress_entry_json() {
  local base_entry="$1"
  local node="$2"
  local dataset_parent="$3"
  local disk_json="$4"
  local guid="$5"
  local pin="$6"
  local pin_trust="$7"
  local fingerprint="$8"
  local version="$9"
  local jobs_json="${10}"
  local parked_at="${11}"
  local status_value="${12}"
  local detail="${13}"

  BASE_ENTRY="$base_entry" DISK_JSON="$disk_json" NODE="$node" DATASET_PARENT="$dataset_parent" \
    GUID="$guid" PIN="$pin" PIN_TRUST="$pin_trust" FINGERPRINT="$fingerprint" VERSION="$version" \
    JOBS_JSON="$jobs_json" PARKED_AT="$parked_at" STATUS_VALUE="$status_value" DETAIL="$detail" \
    STORAGE_POOL="$(vdb_park_storage_pool)" python3 - <<'PY'
import json
import os

entry = json.loads(os.environ["BASE_ENTRY"])
disk_raw = os.environ["DISK_JSON"]
disk = json.loads(disk_raw) if disk_raw else {}
vmid = int(entry["vmid"])
entry.update({
    "node": os.environ["NODE"],
    "storage": disk.get("storage") or os.environ["STORAGE_POOL"],
    "dataset_parent": os.environ["DATASET_PARENT"],
    "pin": os.environ["PIN"],
    "pin_trust": os.environ["PIN_TRUST"],
    "fingerprint": None if os.environ["FINGERPRINT"] == "null" else {"park_sha256": os.environ["FINGERPRINT"]},
    "qemu_server_version": os.environ["VERSION"],
    "replication_jobs": json.loads(os.environ["JOBS_JSON"]),
    "parked_at": os.environ["PARKED_AT"],
    "park_name": f"mycofu-park-{vmid}-vdb",
    "status": os.environ["STATUS_VALUE"],
    "detail": os.environ["DETAIL"],
})
if disk:
    entry.update({
        "volname": disk.get("volname", ""),
        "slot": disk.get("slot", ""),
        "drive_options": disk.get("drive_options", ""),
        "size": disk.get("size", ""),
    })
if os.environ["GUID"]:
    entry["guid"] = os.environ["GUID"]
print(json.dumps(entry, sort_keys=True))
PY
}

vdb_park_eligible_entry_jsons() {
  local manifest="$1"
  local scope="${2:-all}"
  local entry label vmid env category class_rc expected_node hosting_node hosting_rc version pin_json pin_volid pin_trust dataset_parent park_dataset zfs_rc

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    label="$(jq -r '.label' <<< "$entry")"
    vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
    env="$(jq -r '.env' <<< "$entry")"

    if ! vdb_park_env_enabled "$env"; then
      vdb_park_log "  ${label}: vdb park bridge disabled for env ${env}; using restore path" >&2
      continue
    fi

    set +e
    category="$(vdb_park_class_category "$label" 2>/dev/null)"
    class_rc=$?
    set -e
    if [[ "$class_rc" -ne 0 || -z "$category" || "$category" == "unknown" ]]; then
      vdb_park_warn "${label}: VM class category is unverifiable; vdb park bridge skipped"
      continue
    fi
    if [[ "$category" == "vendor" ]]; then
      vdb_park_log "  ${label}: vendor appliance; vdb park bridge skipped" >&2
      continue
    fi

    expected_node="$(jq -r '.node // empty' <<< "$entry")"
    if [[ -z "$expected_node" ]]; then
      expected_node="$(vdb_park_expected_node "$label" "$env")"
    fi
    if [[ -z "$expected_node" ]]; then
      vdb_park_error "${label}: cannot determine intended node"
      return 1
    fi

    set +e
    hosting_node="$(vdb_park_hosting_node "$vmid")"
    hosting_rc=$?
    set -e
    if [[ "$hosting_rc" -ne 0 ]]; then
      vdb_park_error "${label}: cannot determine whether VMID ${vmid} exists in the cluster; aborting before mutation"
      return 1
    fi
    if [[ -z "$hosting_node" ]]; then
      vdb_park_log "  ${label}: VMID ${vmid} not present; no old vdb to park" >&2
      continue
    fi
    if [[ "$hosting_node" != "$expected_node" ]]; then
      vdb_park_error "${label}: VMID ${vmid} is on ${hosting_node}, expected ${expected_node}; rebalance before deploy"
      return 1
    fi

    version="$(vdb_park_qemu_server_version "$hosting_node")"
    if ! vdb_park_version_allowed "$version"; then
      vdb_park_warn "${label}: qemu-server ${version} on ${hosting_node} is not in verified baseline (${VDB_PARK_VERIFIED_QEMU_SERVER}); bridge skipped. Re-run RESEARCH-004 gated experiment before extending the list."
      continue
    fi

    pin_json="$(vdb_park_pin_from_entry "$entry")"
    pin_volid="$(vdb_park_pin_volid "$pin_json")"
    pin_trust="$(vdb_park_pin_trust "$pin_json")"
    if [[ -z "$pin_volid" ]]; then
      vdb_park_error "${label}: missing restore pin for VMID ${vmid}; aborting before any vdb park mutation"
      return 1
    fi
    if [[ "$pin_trust" == "untrusted" ]]; then
      vdb_park_warn "${label}: restore pin ${pin_volid} is marked untrusted; parking continues but fallback certificate quality is degraded"
    fi

    dataset_parent="$(vdb_park_dataset_parent)"
    park_dataset="${dataset_parent}/$(vdb_park_park_name "$vmid")"
    set +e
    vdb_park_zfs_exists "$hosting_node" "$park_dataset"
    zfs_rc=$?
    set -e
    if [[ "$zfs_rc" -eq 0 ]]; then
      vdb_park_error "${label}: parked vdb dataset already exists for VMID ${vmid}"
      vdb_park_remediation_message "$vmid" "$env" "$pin_volid" "$manifest" "${VDB_PARK_STATUS_FILE:-}" >&2
      return 1
    elif [[ "$zfs_rc" -ne 1 ]]; then
      vdb_park_error "${label}: cannot verify park-collision state for ${park_dataset}; aborting before mutation"
      return 1
    fi

    ENTRY_JSON="$entry" EXPECTED_NODE="$expected_node" HOSTING_NODE="$hosting_node" VERSION="$version" PIN_JSON="$pin_json" python3 - <<'PY'
import json
import os

entry = json.loads(os.environ["ENTRY_JSON"])
pin = json.loads(os.environ["PIN_JSON"])
entry["node"] = os.environ["HOSTING_NODE"]
entry["intended_node"] = os.environ["EXPECTED_NODE"]
entry["qemu_server_version"] = os.environ["VERSION"]
entry["pin"] = pin["volid"]
entry["pin_trust"] = pin.get("trust") or "unknown"
print(json.dumps(entry, sort_keys=True))
PY
  done < <(vdb_park_manifest_entries "$manifest" "$scope")
}

vdb_park_one() {
  local entry="$1"
  local status_file="$2"
  local label vmid env node expected_size expected_slot storage_pool dataset_parent qm_config disk_json
  local volname slot drive_options size canonical_dataset park_name park_dataset guid fingerprint parked_at jobs_json entry_json pin pin_trust version
  local exists_rc

  label="$(jq -r '.label' <<< "$entry")"
  vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
  env="$(jq -r '.env' <<< "$entry")"
  node="$(jq -r '.node' <<< "$entry")"
  pin="$(jq -r '.pin // empty' <<< "$entry")"
  pin_trust="$(jq -r '.pin_trust // "unknown"' <<< "$entry")"
  version="$(jq -r '.qemu_server_version // empty' <<< "$entry")"
  expected_size="$(vdb_park_expected_size_gb "$entry")"
  if [[ -z "$expected_size" ]]; then
    vdb_park_error "${label}: cannot determine expected vdb size from manifest/config"
    return 1
  fi
  expected_slot="$(jq -r ".data_disk_slot // \"${VDB_PARK_DATA_DISK_SLOT}\"" <<< "$entry")"

  storage_pool="$(vdb_park_storage_pool)"
  dataset_parent="$(vdb_park_dataset_parent)"

  vdb_park_log "  ${label}: stopping VMID ${vmid} on ${node}"
  vdb_park_stop_vm "$node" "$vmid"

  vdb_park_log "  ${label}: disabling replication jobs before detach"
  jobs_json="$(vdb_park_replication_jobs_for_vmid "$vmid" | jq -R -s -c 'split("\n") | map(select(length > 0))')"
  vdb_park_disable_replication "$vmid"
  parked_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  entry_json="$(vdb_park_build_progress_entry_json "$entry" "$node" "$dataset_parent" "" "" "$pin" "$pin_trust" "null" "$version" "$jobs_json" "$parked_at" "park-prepared" "VM stopped and replication disabled before park")"
  vdb_park_status_upsert_json "$status_file" "$entry_json"
  vdb_park_status_record_version "$status_file" "$node" "$version"

  qm_config="$(vdb_park_ssh_node "$node" "qm config ${vmid}")"
  disk_json="$(vdb_park_discover_vdb_json "$qm_config" "$expected_size" "$expected_slot" "$storage_pool")"
  volname="$(jq -r '.volname' <<< "$disk_json")"
  slot="$(jq -r '.slot' <<< "$disk_json")"
  drive_options="$(jq -r '.drive_options // ""' <<< "$disk_json")"
  size="$(jq -r '.size // ""' <<< "$disk_json")"
  canonical_dataset="${dataset_parent}/${volname}"
  park_name="$(vdb_park_park_name "$vmid")"
  park_dataset="${dataset_parent}/${park_name}"
  guid="$(vdb_park_zfs_get_value "$node" guid "$canonical_dataset")"
  fingerprint="$(vdb_park_fingerprint_dataset "$node" "$canonical_dataset")"
  entry_json="$(vdb_park_build_progress_entry_json "$entry" "$node" "$dataset_parent" "$disk_json" "$guid" "$pin" "$pin_trust" "$fingerprint" "$version" "$jobs_json" "$parked_at" "detaching" "vdb identified before detach")"
  vdb_park_status_upsert_json "$status_file" "$entry_json"

  vdb_park_log "  ${label}: detaching ${slot} (${volname})"
  vdb_park_ssh_node "$node" "qm set ${vmid} --delete ${slot}"

  vdb_park_log "  ${label}: parking ${volname} as ${park_name}"
  vdb_park_ssh_node "$node" "zfs rename $(vdb_park_shell_quote "$canonical_dataset") $(vdb_park_shell_quote "$park_dataset")"

  set +e
  vdb_park_zfs_exists "$node" "$park_dataset"
  exists_rc=$?
  set -e
  if [[ "$exists_rc" -ne 0 ]]; then
    vdb_park_error "${label}: park dataset ${park_dataset} was not found after rename"
    return 1
  fi
  set +e
  vdb_park_zfs_exists "$node" "$canonical_dataset"
  exists_rc=$?
  set -e
  if [[ "$exists_rc" -eq 0 ]]; then
    vdb_park_error "${label}: canonical dataset ${canonical_dataset} still exists after park"
    return 1
  elif [[ "$exists_rc" -ne 1 ]]; then
    vdb_park_error "${label}: could not verify canonical dataset ${canonical_dataset} after park"
    return 1
  fi

  vdb_park_set_prop "$node" "$park_dataset" "mycofu:orig-volname" "$volname"
  vdb_park_set_prop "$node" "$park_dataset" "mycofu:slot" "$slot"
  vdb_park_set_prop "$node" "$park_dataset" "mycofu:drive-options" "$drive_options"
  vdb_park_set_prop "$node" "$park_dataset" "mycofu:guid" "$guid"
  vdb_park_set_prop "$node" "$park_dataset" "mycofu:pin-volid" "$pin"
  vdb_park_set_prop "$node" "$park_dataset" "mycofu:parked-at" "$parked_at"

  entry_json="$(vdb_park_build_entry_json "$entry" "$node" "$dataset_parent" "$disk_json" "$guid" "$pin" "$pin_trust" "$fingerprint" "$version" "$jobs_json" "$parked_at")"
  vdb_park_status_upsert_json "$status_file" "$entry_json"
  vdb_park_status_record_version "$status_file" "$node" "$version"
  vdb_park_log "  ${label}: parked ${size} vdb (${guid})"
}

vdb_park_batch() {
  local manifest="$1"
  local status_file="$2"
  local scope="${3:-all}"
  local eligible_file entry rc=0

  vdb_park_require_file "$manifest" "preboot manifest" || return 1
  jq empty "$manifest" >/dev/null
  VDB_PARK_STATUS_FILE="$status_file"
  VDB_PARK_CURRENT_MANIFEST="$manifest"
  vdb_park_status_init "$status_file" "$scope"

  eligible_file="$(mktemp "${TMPDIR:-/tmp}/vdb-park-eligible.XXXXXX")"
  trap 'rm -f "$eligible_file"' RETURN
  if ! vdb_park_eligible_entry_jsons "$manifest" "$scope" > "$eligible_file"; then
    return 1
  fi

  if [[ ! -s "$eligible_file" ]]; then
    vdb_park_log "No eligible vdb park entries for ${scope}"
    return 0
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    set +e
    ( set -e; vdb_park_one "$entry" "$status_file" )
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      vdb_park_error "vdb park failed; unparking already parked entries in reverse order"
      vdb_unpark_batch "$status_file" || true
      return "$rc"
    fi
  done < "$eligible_file"

  # Manifest-vs-entries parity check (#518, A6): every eligible park entry must
  # have produced a status entry. A silent gap under-reports the bulk park
  # artifact — the exact #518 class (empty/short entries[] read as "nothing
  # parked" on a run that DID park). FAIL-not-silent, naming the missing VMIDs.
  local eligible_vmids status_vmids missing
  eligible_vmids="$(jq -r '.vmid | tostring' "$eligible_file" | sort -u)"
  status_vmids="$(jq -r '.entries[]?.vmid | tostring' "$status_file" | sort -u)"
  missing="$(comm -23 \
    <(printf '%s\n' "$eligible_vmids" | grep -v '^$') \
    <(printf '%s\n' "$status_vmids" | grep -v '^$') | tr '\n' ' ')"
  if [[ -n "${missing// /}" ]]; then
    vdb_park_error "park status parity check failed (#518): eligible VMID(s) with no status entry: ${missing}"
    return 1
  fi
}

vdb_park_preview_batch() {
  local manifest="$1"
  local scope="${2:-all}"
  local any=0
  local entry label vmid env reason category pin_json pin_volid trust

  vdb_park_require_file "$manifest" "preboot manifest" || return 1

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    label="$(jq -r '.label // ("vm-" + (.vmid|tostring))' <<< "$entry")"
    vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
    env="$(jq -r '.env // ""' <<< "$entry")"
    reason="$(jq -r '.reason // ""' <<< "$entry")"

    [[ "$reason" == "replace" ]] || continue
    [[ "$scope" == "all" || "$env" == "$scope" ]] || continue
    if ! vdb_park_env_enabled "$env"; then
      continue
    fi

    category="$(vdb_park_class_category "$label" 2>/dev/null || echo "unknown")"
    if [[ "$category" == "unknown" ]]; then
      echo "WOULD skip ${label} (VMID ${vmid}): VM class category is unverifiable"
      continue
    fi
    if [[ "$category" == "vendor" ]]; then
      continue
    fi

    pin_json="$(vdb_park_pin_from_entry "$entry")"
    pin_volid="$(vdb_park_pin_volid "$pin_json")"
    trust="$(vdb_park_pin_trust "$pin_json")"
    any=1
    if [[ -z "$pin_volid" ]]; then
      echo "WOULD abort before parking ${label} (VMID ${vmid}): missing restore pin"
    else
      echo "WOULD park vdb for ${label} (VMID ${vmid}) using fallback pin ${pin_volid} (trust=${trust})"
    fi
  done < <(vdb_park_manifest_entries "$manifest" "$scope")

  if [[ "$any" -eq 0 ]]; then
    echo "No VMs eligible for vdb park bridge in scope ${scope}"
  fi
}

vdb_park_delete_unused_for_slot() {
  local node="$1"
  local vmid="$2"
  local slot="$3"
  local unused
  vdb_park_ssh_node "$node" "qm set ${vmid} --delete ${slot}"
  unused="$(vdb_park_ssh_node "$node" "qm config ${vmid} 2>/dev/null | awk -F: '/^unused[0-9]+:/ {print \$1; exit}'" 2>/dev/null || true)"
  if [[ -n "$unused" ]]; then
    vdb_park_ssh_node "$node" "qm set ${vmid} --delete ${unused}"
  fi
}

vdb_park_attach_disk() {
  local node="$1"
  local vmid="$2"
  local slot="$3"
  local storage="$4"
  local volname="$5"
  local options="$6"
  local spec="${storage}:${volname}"
  if [[ -n "$options" ]]; then
    spec="${spec},${options}"
  fi
  vdb_park_ssh_node "$node" "qm set ${vmid} --${slot} $(vdb_park_shell_quote "$spec")"
}

vdb_park_allocate_empty_target() {
  local node="$1"
  local vmid="$2"
  local storage="$3"
  local volname="$4"
  local size="$5"
  local slot="$6"
  local options="$7"
  vdb_park_ssh_node "$node" "pvesm alloc ${storage} ${vmid} ${volname} ${size}"
  vdb_park_attach_disk "$node" "$vmid" "$slot" "$storage" "$volname" "$options"
}

vdb_park_vm_status_on_node() {
  local node="$1"
  local vmid="$2"
  vdb_park_ssh_node "$node" "qm status ${vmid} 2>/dev/null | awk '{print \$2}'"
}

vdb_park_verify_fresh_target_for_adopt() {
  local entry="$1"
  local node vmid storage volname slot dataset_parent canonical_dataset expected_guid qm_config target_json target_guid
  node="$(jq -r '.node' <<< "$entry")"
  vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
  storage="$(jq -r '.storage' <<< "$entry")"
  volname="$(jq -r '.volname' <<< "$entry")"
  slot="$(jq -r '.slot' <<< "$entry")"
  dataset_parent="$(jq -r '.dataset_parent' <<< "$entry")"
  expected_guid="$(jq -r '.guid // empty' <<< "$entry")"
  canonical_dataset="${dataset_parent}/${volname}"

  qm_config="$(vdb_park_ssh_node "$node" "qm config ${vmid}")"
  target_json="$(vdb_park_slot_disk_json "$qm_config" "$slot" "$storage" "$volname")"
  target_guid="$(vdb_park_zfs_get_value "$node" guid "$canonical_dataset" 2>/dev/null || true)"
  if [[ -z "$target_guid" ]]; then
    vdb_park_error "VMID ${vmid} fresh vdb target ${canonical_dataset} is missing"
    return 1
  fi
  if [[ -n "$expected_guid" && "$target_guid" == "$expected_guid" ]]; then
    vdb_park_error "VMID ${vmid} ${canonical_dataset} already has parked GUID ${expected_guid}; refusing to delete it as a fresh target"
    return 1
  fi
  printf '%s\n' "$target_json"
}

vdb_park_return_to_park_and_allocate() {
  local status_file="$1"
  local vmid="$2"
  local label="$3"
  local node="$4"
  local storage="$5"
  local volname="$6"
  local size="$7"
  local slot="$8"
  local options="$9"
  local canonical_dataset="${10}"
  local park_dataset="${11}"
  local detail="${12}"
  local rename_rc alloc_rc

  vdb_park_warn "${label}: ${detail}; returning volume to park name and allocating empty restore target"
  set +e
  vdb_park_ssh_node "$node" "zfs rename $(vdb_park_shell_quote "$canonical_dataset") $(vdb_park_shell_quote "$park_dataset")"
  rename_rc=$?
  if [[ "$rename_rc" -eq 0 ]]; then
    vdb_park_allocate_empty_target "$node" "$vmid" "$storage" "$volname" "$size" "$slot" "$options"
    alloc_rc=$?
  else
    alloc_rc=1
  fi
  set -e

  if [[ "$rename_rc" -ne 0 || "$alloc_rc" -ne 0 ]]; then
    vdb_park_status_set "$status_file" "$vmid" "adopt-cleanup-failed" "${detail}; failed to restore park name or allocate empty restore target"
    return 1
  fi

  vdb_park_status_set "$status_file" "$vmid" "adopt-failed" "${detail}; park retained and empty restore target allocated"
  return 1
}

vdb_park_verify_adopted_entry() {
  local entry="$1"
  local node vmid slot volname dataset_parent dataset guid expected_guid qm_config
  node="$(jq -r '.node' <<< "$entry")"
  vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
  slot="$(jq -r '.slot' <<< "$entry")"
  volname="$(jq -r '.volname' <<< "$entry")"
  dataset_parent="$(jq -r '.dataset_parent' <<< "$entry")"
  expected_guid="$(jq -r '.guid' <<< "$entry")"
  dataset="${dataset_parent}/${volname}"
  qm_config="$(vdb_park_ssh_node "$node" "qm config ${vmid}" 2>/dev/null || true)"
  if ! grep -Eq "^${slot}:[[:space:]]*[^,]*:${volname}(,|$)" <<< "$qm_config"; then
    vdb_park_error "VMID ${vmid} does not reference ${volname} on ${slot}"
    return 1
  fi
  guid="$(vdb_park_zfs_get_value "$node" guid "$dataset" 2>/dev/null || true)"
  if [[ "$guid" != "$expected_guid" ]]; then
    vdb_park_error "VMID ${vmid} adopted GUID mismatch: expected ${expected_guid}, got ${guid:-missing}"
    return 1
  fi
}

vdb_park_verify_fingerprint_if_recorded() {
  local entry="$1"
  local node dataset_parent volname expected actual
  expected="$(jq -r '.fingerprint.park_sha256 // empty' <<< "$entry")"
  [[ -n "$expected" ]] || return 0
  node="$(jq -r '.node' <<< "$entry")"
  dataset_parent="$(jq -r '.dataset_parent' <<< "$entry")"
  volname="$(jq -r '.volname' <<< "$entry")"
  actual="$(vdb_park_ssh_node "$node" "sha256sum /dev/zvol/$(vdb_park_shell_quote "${dataset_parent}/${volname}") 2>/dev/null | awk '{print \$1}'")"
  if [[ "$actual" != "$expected" ]]; then
    vdb_park_error "adopted vdb fingerprint mismatch: expected ${expected}, got ${actual:-missing}"
    return 1
  fi
}

vdb_park_adopt_one() {
  local entry="$1"
  local status_file="$2"
  local recovery_mode="$3"
  local label vmid node storage dataset_parent volname slot options size guid park_name park_dataset canonical_dataset status
  local hosting_node hosting_rc vm_status fresh_json fresh_size park_exists_rc attach_rc

  label="$(jq -r '.label // ("vm-" + (.vmid|tostring))' <<< "$entry")"
  vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
  node="$(jq -r '.node' <<< "$entry")"
  storage="$(jq -r '.storage' <<< "$entry")"
  dataset_parent="$(jq -r '.dataset_parent' <<< "$entry")"
  volname="$(jq -r '.volname' <<< "$entry")"
  slot="$(jq -r '.slot' <<< "$entry")"
  options="$(jq -r '.drive_options // ""' <<< "$entry")"
  size="$(jq -r '.size // ""' <<< "$entry")"
  guid="$(jq -r '.guid' <<< "$entry")"
  park_name="$(jq -r '.park_name' <<< "$entry")"
  status="$(jq -r '.status // "parked"' <<< "$entry")"
  park_dataset="${dataset_parent}/${park_name}"
  canonical_dataset="${dataset_parent}/${volname}"

  if [[ "$status" == "adopted" ]]; then
    vdb_park_verify_adopted_entry "$entry"
    # Recovery may inherit an old adopted entry, while normal runs must not
    # turn stale evidence into `spared`. Re-stamp only after live GUID/slot
    # verification so B9 reconstruction and run-scoped restore evidence meet.
    vdb_park_status_set "$status_file" "$vmid" "adopted" "verified adopted parked vdb guid ${guid}"
    vdb_park_log "  ${label}: already adopted"
    return 0
  fi

  if [[ "$recovery_mode" -eq 1 ]]; then
    set +e
    hosting_node="$(vdb_park_hosting_node "$vmid")"
    hosting_rc=$?
    set -e
    if [[ "$hosting_rc" -ne 0 ]]; then
      vdb_park_status_set "$status_file" "$vmid" "adopt-failed" "could not query cluster resources before recovery adopt"
      return 1
    fi
    if [[ -z "$hosting_node" ]]; then
      vdb_park_log "  ${label}: VMID ${vmid} not created yet; parked vdb retained"
      return 0
    fi
  fi

  vm_status="$(vdb_park_vm_status_on_node "$node" "$vmid" 2>/dev/null || true)"
  if [[ "$vm_status" != "stopped" ]]; then
    vdb_park_status_set "$status_file" "$vmid" "adopt-failed" "VM must be stopped before adopt; status=${vm_status:-unknown}"
    vdb_park_error "${label}: VMID ${vmid} is not stopped before adopt (status=${vm_status:-unknown})"
    return 1
  fi

  set +e
  vdb_park_zfs_exists "$node" "$park_dataset"
  park_exists_rc=$?
  set -e
  if [[ "$park_exists_rc" -eq 1 ]]; then
    vdb_park_status_set "$status_file" "$vmid" "park-lost" "park dataset missing before adopt; fresh vdb left intact for PBS restore"
    vdb_park_error "${label}: park dataset missing before adopt; fresh vdb was not touched"
    return 1
  elif [[ "$park_exists_rc" -ne 0 ]]; then
    vdb_park_status_set "$status_file" "$vmid" "adopt-failed" "could not verify park dataset before adopt"
    return 1
  fi

  fresh_json="$(vdb_park_verify_fresh_target_for_adopt "$entry")" || {
    vdb_park_status_set "$status_file" "$vmid" "adopt-failed" "fresh restore target verification failed before adopt"
    return 1
  }
  fresh_size="$(jq -r '.size // empty' <<< "$fresh_json")"
  if [[ -z "$size" || "$size" == "null" ]]; then
    size="$fresh_size"
  fi

  vdb_park_log "  ${label}: freeing fresh vdb only after park existence check"
  vdb_park_delete_unused_for_slot "$node" "$vmid" "$slot"

  vdb_park_log "  ${label}: renaming parked vdb back to ${volname}"
  vdb_park_ssh_node "$node" "zfs rename $(vdb_park_shell_quote "$park_dataset") $(vdb_park_shell_quote "$canonical_dataset")"

  set +e
  vdb_park_attach_disk "$node" "$vmid" "$slot" "$storage" "$volname" "$options"
  attach_rc=$?
  set -e
  if [[ "$attach_rc" -ne 0 ]]; then
    vdb_park_return_to_park_and_allocate "$status_file" "$vmid" "$label" "$node" "$storage" "$volname" "$size" "$slot" "$options" "$canonical_dataset" "$park_dataset" "reattach failed"
    return $?
  fi

  if ! vdb_park_verify_adopted_entry "$entry"; then
    vdb_park_return_to_park_and_allocate "$status_file" "$vmid" "$label" "$node" "$storage" "$volname" "$size" "$slot" "$options" "$canonical_dataset" "$park_dataset" "adopt verification failed"
    return $?
  fi
  if ! vdb_park_verify_fingerprint_if_recorded "$entry"; then
    vdb_park_return_to_park_and_allocate "$status_file" "$vmid" "$label" "$node" "$storage" "$volname" "$size" "$slot" "$options" "$canonical_dataset" "$park_dataset" "adopt fingerprint verification failed"
    return $?
  fi

  vdb_park_clear_props "$node" "$canonical_dataset"
  vdb_park_status_set "$status_file" "$vmid" "adopted" "adopted parked vdb guid ${guid}"
  vdb_park_log "  ${label}: adopted ${volname}"
}

vdb_park_reconstruct_entry_json() {
  local node="$1"
  local dataset="$2"
  local props
  props="$(vdb_park_ssh_node "$node" "zfs get -H -o property,value all $(vdb_park_shell_quote "$dataset") 2>/dev/null | grep '^mycofu:' || true")"
  NODE="$node" DATASET="$dataset" PROPS="$props" STORAGE_POOL="$(vdb_park_storage_pool)" python3 - <<'PY'
import json
import os
import re

dataset = os.environ["DATASET"]
node = os.environ["NODE"]
props = {}
for line in os.environ["PROPS"].splitlines():
    parts = line.split(None, 1)
    if len(parts) == 2:
        props[parts[0]] = "" if parts[1] == "-" else parts[1]
m = re.search(r"/mycofu-park-([0-9]+)-vdb$", dataset)
if not m:
    raise SystemExit(0)
vmid = int(m.group(1))
dataset_parent, park_name = dataset.rsplit("/", 1)
volname = props.get("mycofu:orig-volname", "")
entry = {
    "label": f"vm_{vmid}",
    "vmid": vmid,
    "env": "all",
    "node": node,
    "storage": os.environ["STORAGE_POOL"],
    "dataset_parent": dataset_parent,
    "volname": volname,
    "slot": props.get("mycofu:slot", ""),
    "drive_options": props.get("mycofu:drive-options", ""),
    "size": "",
    "guid": props.get("mycofu:guid", ""),
    "park_name": park_name,
    "pin": props.get("mycofu:pin-volid", ""),
    "pin_trust": "unknown",
    "fingerprint": None,
    "status": "parked",
    "detail": "reconstructed from ZFS user properties",
}
print(json.dumps(entry, sort_keys=True))
PY
}

vdb_park_discover_orphan_entries() {
  local allowed_file="${1:-}"
  local dataset_parent node ip rows dataset vmid scan_rc
  dataset_parent="$(vdb_park_dataset_parent)"
  while IFS=$'\t' read -r node ip; do
    [[ -z "$node" || -z "$ip" ]] && continue
    set +e
    rows="$(vdb_park_ssh_ip "$ip" "zfs list -H -o name -r $(vdb_park_shell_quote "$dataset_parent") 2>/dev/null" 2>/dev/null)"
    scan_rc=$?
    set -e
    if [[ "$scan_rc" -ne 0 ]]; then
      vdb_park_error "failed to scan orphan parked vdbs on ${node}"
      return 1
    fi
    while IFS= read -r dataset; do
      [[ -z "$dataset" ]] && continue
      case "$dataset" in
        */mycofu-park-*-vdb) ;;
        *) continue ;;
      esac
      vmid="$(sed -n 's|.*/mycofu-park-\([0-9][0-9]*\)-vdb$|\1|p' <<< "$dataset")"
      if [[ -n "$allowed_file" ]] && ! grep -Fxq "$vmid" "$allowed_file"; then
        continue
      fi
      vdb_park_reconstruct_entry_json "$node" "$dataset"
    done <<< "$rows"
  done < <(vdb_park_node_rows)
}

vdb_adopt_batch() {
  local status_file="$1"
  local recovery_mode=0
  local manifest=""
  local entry tmp allowed_file="" entries rc failures=0 vmid orphan_tmp="" scan_rc had_errexit=0
  # Preserve the caller's errexit mode so wrappers can capture adopt failures
  # and continue into restore-before-start for PBS fallback.
  case "$-" in
    *e*) had_errexit=1 ;;
  esac
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --recovery-mode) recovery_mode=1; shift ;;
      --manifest) manifest="$2"; shift 2 ;;
      *) vdb_park_error "unknown vdb_adopt_batch argument: $1"; return 2 ;;
    esac
  done

  vdb_park_require_file "$status_file" "park status" || return 1

  tmp="$(mktemp "${TMPDIR:-/tmp}/vdb-adopt-entries.XXXXXX")"
  : > "$tmp"
  if [[ "$recovery_mode" -eq 1 && -n "$manifest" ]]; then
    vdb_park_require_file "$manifest" "recovery manifest" || return 1
    allowed_file="$(mktemp "${TMPDIR:-/tmp}/vdb-adopt-allowed.XXXXXX")"
    jq -r '(if type == "array" then . else .entries end)[]? | .vmid | tonumber' "$manifest" | sort -n -u > "$allowed_file"
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
    if [[ -n "$allowed_file" ]] && ! grep -Fxq "$vmid" "$allowed_file"; then
      continue
    fi
    printf '%s\n' "$entry" >> "$tmp"
  done < <(jq -c '.entries[]? | select(.status == "parked" or .status == "adopted")' "$status_file")

  if [[ "$recovery_mode" -eq 1 ]]; then
    orphan_tmp="$(mktemp "${TMPDIR:-/tmp}/vdb-adopt-orphans.XXXXXX")"
    set +e
    vdb_park_discover_orphan_entries "$allowed_file" > "$orphan_tmp"
    scan_rc=$?
    if [[ "$had_errexit" -eq 1 ]]; then set -e; else set +e; fi
    if [[ "$scan_rc" -ne 0 ]]; then
      rm -f "$tmp" "$orphan_tmp"
      [[ -z "$allowed_file" ]] || rm -f "$allowed_file"
      return 1
    fi
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
      if ! jq -e --argjson vmid "$vmid" 'any(.entries[]?; .vmid == $vmid)' "$status_file" >/dev/null; then
        vdb_park_status_upsert_json "$status_file" "$entry"
        printf '%s\n' "$entry" >> "$tmp"
      fi
    done < "$orphan_tmp"
    rm -f "$orphan_tmp"
  fi

  entries="$(cat "$tmp")"
  rm -f "$tmp"
  [[ -z "$allowed_file" ]] || rm -f "$allowed_file"
  if [[ -z "$entries" ]]; then
    vdb_park_log "No parked vdb entries to adopt"
    return 0
  fi

  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    set +e
    ( set -e; vdb_park_adopt_one "$entry" "$status_file" "$recovery_mode" )
    rc=$?
    if [[ "$had_errexit" -eq 1 ]]; then set -e; else set +e; fi
    if [[ "$rc" -ne 0 ]]; then
      failures=$((failures + 1))
    fi
  done <<< "$entries"

  if [[ "$failures" -eq 0 ]]; then
    return 0
  fi
  return 1
}

vdb_unpark_one() {
  local entry="$1"
  local node vmid storage dataset_parent volname slot options park_name park_dataset canonical_dataset
  node="$(jq -r '.node' <<< "$entry")"
  vmid="$(jq -r '.vmid | tonumber' <<< "$entry")"
  storage="$(jq -r '.storage' <<< "$entry")"
  dataset_parent="$(jq -r '.dataset_parent' <<< "$entry")"
  volname="$(jq -r '.volname' <<< "$entry")"
  slot="$(jq -r '.slot' <<< "$entry")"
  options="$(jq -r '.drive_options // ""' <<< "$entry")"
  park_name="$(jq -r '.park_name' <<< "$entry")"
  park_dataset="${dataset_parent}/${park_name}"
  canonical_dataset="${dataset_parent}/${volname}"

  local exists_rc=1
  if [[ -n "$volname" && "$volname" != "null" ]]; then
    set +e
    vdb_park_zfs_exists "$node" "$park_dataset"
    exists_rc=$?
    set -e
  fi
  if [[ "$exists_rc" -eq 0 ]]; then
    vdb_park_ssh_node "$node" "zfs rename $(vdb_park_shell_quote "$park_dataset") $(vdb_park_shell_quote "$canonical_dataset")"
  elif [[ "$exists_rc" -ne 1 ]]; then
    return 1
  fi
  if [[ -n "$slot" && "$slot" != "null" && -n "$volname" && "$volname" != "null" ]]; then
    vdb_park_ssh_node "$node" "qm config ${vmid} 2>/dev/null | awk -F: '/^unused[0-9]+:/ {print \$1}' | while read unused; do [ -n \"\$unused\" ] && qm set ${vmid} --delete \"\$unused\" 2>/dev/null || true; done"
    vdb_park_attach_disk "$node" "$vmid" "$slot" "$storage" "$volname" "$options"
  fi
  vdb_park_enable_recorded_replication "$entry"
  vdb_park_ssh_node "$node" "qm start ${vmid}"
}

vdb_unpark_batch() {
  local status_file="$1"
  local entries entry vmids vmid rc failures=0
  vdb_park_require_file "$status_file" "park status" || return 1
  vmids="$(jq -r '.entries[]? | select(.status == "parked" or .status == "detaching" or .status == "park-prepared") | .vmid' "$status_file" | sort -nr)"
  while IFS= read -r vmid; do
    [[ -z "$vmid" ]] && continue
    entry="$(jq -c --argjson vmid "$vmid" 'first(.entries[]? | select(.vmid == $vmid))' "$status_file")"
    [[ -z "$entry" || "$entry" == "null" ]] && continue
    set +e
    ( set -e; vdb_unpark_one "$entry" )
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      vdb_park_status_set "$status_file" "$vmid" "unparked" "unparked after pre-destroy failure"
    else
      failures=$((failures + 1))
      vdb_park_status_set "$status_file" "$vmid" "unpark-failed" "unpark failed after pre-destroy failure; inspect and recover with parked-vdb.sh"
      vdb_park_error "failed to unpark VMID ${vmid}; inspect with framework/scripts/parked-vdb.sh inspect ${vmid}"
    fi
  done <<< "$vmids"
  [[ "$failures" -eq 0 ]]
}

vdb_park_list_parks_json() {
  local dataset_parent node ip rows dataset size vmid props health canonical scan_rc
  dataset_parent="$(vdb_park_dataset_parent)"
  printf '['
  local first=1
  while IFS=$'\t' read -r node ip; do
    [[ -z "$node" || -z "$ip" ]] && continue
    set +e
    rows="$(vdb_park_ssh_ip "$ip" "rows=\$(zfs list -H -o name,volsize -r $(vdb_park_shell_quote "$dataset_parent") 2>/dev/null) || exit \$?; printf '%s\n' \"\$rows\" | awk '\$1 ~ /\\/mycofu-park-[0-9][0-9]*-vdb$/ { print }'" 2>/dev/null)"
    scan_rc=$?
    set -e
    if [[ "$scan_rc" -ne 0 ]]; then
      vdb_park_error "failed to scan parked vdb zvols on ${node}"
      return 1
    fi
    while IFS=$'\t' read -r dataset size; do
      [[ -z "$dataset" ]] && continue
      vmid="$(sed -n 's|.*/mycofu-park-\([0-9][0-9]*\)-vdb$|\1|p' <<< "$dataset")"
      props="$(vdb_park_ssh_ip "$ip" "zfs get -H -o property,value all $(vdb_park_shell_quote "$dataset") 2>/dev/null | grep '^mycofu:' || true" 2>/dev/null || true)"
      canonical="$(awk '$1=="mycofu:orig-volname"{print $2}' <<< "$props")"
      health="unknown"
      if [[ -n "$vmid" && -n "$canonical" ]]; then
        if vdb_park_hosting_node "$vmid" >/dev/null 2>&1; then
          health="check-inspect"
        fi
      fi
      [[ "$first" -eq 0 ]] && printf ','
      first=0
      NODE="$node" DATASET="$dataset" SIZE="${size:-}" VMID="$vmid" PROPS="$props" HEALTH="$health" python3 - <<'PY'
import json
import os

props = {}
for line in os.environ["PROPS"].splitlines():
    parts = line.split(None, 1)
    if len(parts) == 2:
        props[parts[0]] = "" if parts[1] == "-" else parts[1]
print(json.dumps({
    "vmid": int(os.environ["VMID"]) if os.environ["VMID"] else None,
    "node": os.environ["NODE"],
    "dataset": os.environ["DATASET"],
    "size": os.environ["SIZE"],
    "properties": props,
    "attached_vdb_health": os.environ["HEALTH"],
}, sort_keys=True))
PY
    done <<< "$rows"
  done < <(vdb_park_node_rows)
  printf ']\n'
}
