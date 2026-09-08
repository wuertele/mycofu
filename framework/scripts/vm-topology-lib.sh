#!/usr/bin/env bash
# vm-topology-lib.sh — VM disk topology completeness predicates.

set -euo pipefail

VM_TOPOLOGY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_TOPOLOGY_REPO_DIR="$(cd "${VM_TOPOLOGY_SCRIPT_DIR}/../.." && pwd)"
: "${VM_TOPOLOGY_CONFIG:=${VM_TOPOLOGY_REPO_DIR}/site/config.yaml}"
: "${VM_TOPOLOGY_APPS_CONFIG:=${VM_TOPOLOGY_REPO_DIR}/site/applications.yaml}"
: "${VM_SCOPE_SCRIPT:=${VM_TOPOLOGY_SCRIPT_DIR}/vm-scope.sh}"

VM_TOPOLOGY_RC_COMPLETE=0
VM_TOPOLOGY_RC_INCOMPLETE=2
VM_TOPOLOGY_RC_UNVERIFIABLE=3

vm_topology_node_rows() {
  yq -r '.nodes[] | [.name, .mgmt_ip] | @tsv' "$VM_TOPOLOGY_CONFIG"
}

vm_qm_config() {
  local vmid="$1"
  local node_name node_ip output rc
  local ssh_failures=0
  local last_failure=""

  while IFS=$'\t' read -r node_name node_ip; do
    [[ -z "${node_name:-}" || -z "${node_ip:-}" ]] && continue
    set +e
    output="$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${node_ip}" "qm config ${vmid}" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 && -n "$output" ]]; then
      printf '%s\n' "$output"
      return 0
    fi
    if [[ "$rc" -eq 255 ]]; then
      ssh_failures=$((ssh_failures + 1))
    fi
    last_failure="${node_name} (${node_ip}) rc=${rc}: ${output:-no output}"
  done < <(vm_topology_node_rows)

  if [[ "$ssh_failures" -gt 0 ]]; then
    echo "ERROR: topology unverifiable for VM ${vmid}: qm config query failed on ${ssh_failures} configured node(s); last failure: ${last_failure}" >&2
  else
    echo "ERROR: topology unverifiable for VM ${vmid}: qm config was not found on any configured node" >&2
  fi
  return "$VM_TOPOLOGY_RC_UNVERIFIABLE"
}

vm_expected_disks_for_vmid() {
  local vmid="$1"
  local classes_json classes_rc

  set +e
  classes_json="$("${VM_SCOPE_SCRIPT}" classes --format json 2>&1)"
  classes_rc=$?
  set -e
  if [[ "$classes_rc" -ne 0 || -z "$classes_json" ]]; then
    echo "ERROR: topology unverifiable for VM ${vmid}: vm-scope classes query failed (rc=${classes_rc}): ${classes_json:-no output}" >&2
    return "$VM_TOPOLOGY_RC_UNVERIFIABLE"
  fi

  VMID="$vmid" \
  CONFIG_FILE="$VM_TOPOLOGY_CONFIG" \
  APPS_CONFIG_FILE="$VM_TOPOLOGY_APPS_CONFIG" \
  VM_CLASSES_JSON="$classes_json" \
  python3 - <<'PY'
import json
import os
import re
import subprocess
import sys


def load_yaml(path, default):
    if not os.path.exists(path):
        return default
    try:
        raw = subprocess.check_output(
            ["yq", "-o=json", ".", path],
            stderr=subprocess.PIPE,
            text=True,
        )
        return json.loads(raw)
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        print(f"ERROR: topology unverifiable: failed to parse YAML config with yq: {path}", file=sys.stderr)
        if stderr:
            print(stderr, file=sys.stderr)
        sys.exit(3)
    except json.JSONDecodeError as exc:
        print(f"ERROR: topology unverifiable: yq produced invalid JSON for {path}: {exc}", file=sys.stderr)
        sys.exit(3)


def normalize(label):
    return label.replace("-", "_")


def resolve_class(label, classes):
    norm = normalize(label)
    if norm in classes:
        return norm
    match = re.match(r"^(.+)_(dev|prod)$", norm)
    if match and match.group(1) in classes:
        return match.group(1)
    if match:
        # Numbered env labels such as dns1_dev are instances of dns.
        numbered_base = re.sub(r"[0-9]+$", "", match.group(1))
        if numbered_base in classes:
            return numbered_base
    return None


try:
    target = int(os.environ["VMID"])
except Exception:
    print(f"ERROR: topology unverifiable: invalid VMID {os.environ.get('VMID', '')!r}", file=sys.stderr)
    sys.exit(3)

config = load_yaml(os.environ["CONFIG_FILE"], {})
apps = load_yaml(os.environ["APPS_CONFIG_FILE"], {"applications": {}})
try:
    classes = json.loads(os.environ["VM_CLASSES_JSON"])
except json.JSONDecodeError as exc:
    print(f"ERROR: topology unverifiable for VMID {target}: vm-scope classes returned malformed JSON: {exc}", file=sys.stderr)
    sys.exit(3)
if not isinstance(classes, dict) or not classes:
    print(f"ERROR: topology unverifiable for VMID {target}: vm-scope classes returned no class data", file=sys.stderr)
    sys.exit(3)

records = []
for label, vm in (config.get("vms") or {}).items():
    if not isinstance(vm, dict):
        continue
    try:
        vmid = int(vm.get("vmid"))
    except Exception:
        continue
    records.append((label, vmid, vm.get("backup") is True))

for app, app_cfg in (apps.get("applications") or {}).items():
    if not isinstance(app_cfg, dict) or app_cfg.get("enabled") is not True:
        continue
    backup = app_cfg.get("backup") is True
    for env, env_cfg in (app_cfg.get("environments") or {}).items():
        if not isinstance(env_cfg, dict):
            continue
        try:
            vmid = int(env_cfg.get("vmid"))
        except Exception:
            continue
        records.append((f"{app}_{env}", vmid, backup))

for label, vmid, backup in records:
    if vmid != target:
        continue
    class_key = resolve_class(label, classes)
    if class_key is None:
        print(f"ERROR: topology unverifiable for VMID {target}: label {label} is not declared in vm-scope classes", file=sys.stderr)
        sys.exit(3)
    class_data = classes.get(class_key)
    if not isinstance(class_data, dict):
        print(f"ERROR: topology unverifiable for VMID {target}: class {class_key} has malformed class data", file=sys.stderr)
        sys.exit(3)
    category = class_data.get("category")
    if category == "vendor":
        print("scsi0")
    elif category == "nix":
        disks = ["scsi0", "ide2"]
        if backup:
            disks.append("scsi1")
        print(",".join(disks))
    else:
        print(f"ERROR: topology unverifiable for VMID {target}: unsupported or missing VM category for {label}: {category}", file=sys.stderr)
        sys.exit(3)
    sys.exit(0)

print(f"ERROR: topology unverifiable for VMID {target}: VMID not found in config.yaml/applications.yaml", file=sys.stderr)
sys.exit(3)
PY
}

vm_config_has_disk() {
  local qm_config="$1"
  local disk="$2"

  grep -Eq "^${disk}:[[:space:]]*[^[:space:]].*" <<< "$qm_config"
}

vm_is_complete() {
  local vmid="$1"
  local expected_csv="${2:-}"
  local qm_config disk
  local expected_rc config_rc nonempty_expected=0
  local -a missing expected_disks

  if [[ -z "$expected_csv" ]]; then
    set +e
    expected_csv="$(vm_expected_disks_for_vmid "$vmid")"
    expected_rc=$?
    set -e
    if [[ "$expected_rc" -ne 0 ]]; then
      return "$VM_TOPOLOGY_RC_UNVERIFIABLE"
    fi
  fi

  set +e
  qm_config="$(vm_qm_config "$vmid")"
  config_rc=$?
  set -e
  if [[ "$config_rc" -ne 0 ]]; then
    return "$VM_TOPOLOGY_RC_UNVERIFIABLE"
  fi

  missing=()
  IFS=',' read -r -a expected_disks <<< "$expected_csv"
  for disk in "${expected_disks[@]}"; do
    [[ -z "$disk" ]] && continue
    nonempty_expected=1
    if ! vm_config_has_disk "$qm_config" "$disk"; then
      missing+=("$disk")
    fi
  done

  if [[ "$nonempty_expected" -eq 0 ]]; then
    echo "ERROR: topology unverifiable for VM ${vmid}: expected disk list is empty" >&2
    return "$VM_TOPOLOGY_RC_UNVERIFIABLE"
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "VM ${vmid} is incomplete; missing expected disk(s): ${missing[*]}" >&2
    return "$VM_TOPOLOGY_RC_INCOMPLETE"
  fi

  echo "VM ${vmid} complete (${expected_csv})"
}
