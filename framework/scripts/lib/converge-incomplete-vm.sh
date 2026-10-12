#!/usr/bin/env bash
# converge-incomplete-vm.sh — shared bounded convergence for incomplete VMs.

set -euo pipefail

CONVERGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONVERGE_SCRIPT_DIR="$(cd "${CONVERGE_LIB_DIR}/.." && pwd)"
CONVERGE_REPO_DIR="$(cd "${CONVERGE_SCRIPT_DIR}/../.." && pwd)"
source "${CONVERGE_SCRIPT_DIR}/vm-topology-lib.sh"

converge_module_for_vmid() {
  local vmid="$1"

  VMID="$vmid" \
  CONFIG_FILE="${VM_TOPOLOGY_CONFIG}" \
  APPS_CONFIG_FILE="${VM_TOPOLOGY_APPS_CONFIG}" \
  python3 - <<'PY'
import json
import os
import subprocess
import sys


def load_yaml(path, default):
    if not os.path.exists(path):
        return default
    raw = subprocess.check_output(["yq", "-o=json", ".", path], text=True)
    return json.loads(raw)


target = int(os.environ["VMID"])
config = load_yaml(os.environ["CONFIG_FILE"], {})
apps = load_yaml(os.environ["APPS_CONFIG_FILE"], {"applications": {}})

for label, vm in (config.get("vms") or {}).items():
    if not isinstance(vm, dict):
        continue
    try:
        if int(vm.get("vmid")) == target:
            print(label)
            sys.exit(0)
    except Exception:
        pass

for app, app_cfg in (apps.get("applications") or {}).items():
    if not isinstance(app_cfg, dict) or app_cfg.get("enabled") is not True:
        continue
    for env, env_cfg in (app_cfg.get("environments") or {}).items():
        if not isinstance(env_cfg, dict):
            continue
        try:
            if int(env_cfg.get("vmid")) == target:
                print(f"{app}_{env}")
                sys.exit(0)
        except Exception:
            pass

print(f"ERROR: VMID {target} not found in config.yaml/applications.yaml", file=sys.stderr)
sys.exit(1)
PY
}

converge_incomplete_vm() {
  local env="$1"
  local vmid="$2"
  local exact_pin="$3"
  local label target expected_disks manifest manifest_dir pin_file
  local plan_out plan_json show_raw

  if [[ -z "$env" || -z "$vmid" || -z "$exact_pin" ]]; then
    echo "ERROR: converge_incomplete_vm requires <env> <vmid> <exact-pin>" >&2
    return 2
  fi

  label="$(converge_module_for_vmid "$vmid")" || return 1
  target="module.${label}"
  expected_disks="$(vm_expected_disks_for_vmid "$vmid")" || return 1
  manifest_dir="${CONVERGE_REPO_DIR}/build"
  manifest="${manifest_dir}/converge-incomplete-${env}-${vmid}.json"
  pin_file="${manifest_dir}/restore-pin-${env}.json"
  plan_out="${manifest_dir}/converge-incomplete-${env}-${vmid}.tfplan"
  plan_json="${manifest_dir}/converge-incomplete-${env}-${vmid}-plan.json"
  show_raw="${manifest_dir}/converge-incomplete-${env}-${vmid}-show.raw"
  mkdir -p "$manifest_dir"

  jq -n \
    --arg env "$env" \
    --arg label "$label" \
    --arg target "$target" \
    --argjson vmid "$vmid" \
    --arg expected "$expected_disks" \
    --arg pin "$exact_pin" \
    '{
      version: 1,
      scope: $env,
      source: "converge-incomplete-vm",
      entries: [{
        label: $label,
        module: $target,
        vmid: $vmid,
        env: $env,
        kind: "infrastructure",
        reason: "incomplete-convergence",
        expected_disks: ($expected | split(",")),
        pin: $pin
      }]
    }' > "$manifest"

  echo "=== Converging incomplete VM ${vmid} (${label}) ==="
  echo "Target: ${target}"
  echo "Pin: ${exact_pin}"

  "${CONVERGE_SCRIPT_DIR}/tofu-wrapper.sh" plan -target="${target}" \
    -var=start_vms=false \
    -var=register_ha=false \
    -out="$plan_out" \
    -no-color

  tofu -chdir="${CONVERGE_SCRIPT_DIR}/../tofu/root" show -json "$plan_out" > "$show_raw"
  SHOW_RAW="$show_raw" PLAN_JSON="$plan_json" python3 - <<'PY'
import json
import os
import sys

with open(os.environ["SHOW_RAW"]) as f:
    data = f.read()

start = data.find("{")
if start < 0:
    print("ERROR: No JSON object in tofu show output", file=sys.stderr)
    print(f"Output was: {data[:500]}", file=sys.stderr)
    sys.exit(1)

decoder = json.JSONDecoder()
obj, _ = decoder.raw_decode(data[start:])
with open(os.environ["PLAN_JSON"], "w") as f:
    json.dump(obj, f)
    f.write("\n")
PY

  "${CONVERGE_SCRIPT_DIR}/check-plan-images-present.sh" --plan-json "$plan_json"

  "${CONVERGE_SCRIPT_DIR}/tofu-wrapper.sh" apply -target="${target}" \
    -var=start_vms=false \
    -var=register_ha=false \
    -auto-approve -input=false

  "${CONVERGE_SCRIPT_DIR}/backup-now.sh" --env "$env" --skip-vmid "$vmid" --pin-out "$pin_file"

  "${CONVERGE_SCRIPT_DIR}/restore-before-start.sh" "$env" \
    --manifest "$manifest" \
    --backup-id "$exact_pin"

  "${CONVERGE_SCRIPT_DIR}/vm-is-complete.sh" "$vmid" --expected-disks "$expected_disks"

  "${CONVERGE_SCRIPT_DIR}/tofu-wrapper.sh" apply -target="${target}" \
    -var=start_vms=true \
    -var=register_ha=true \
    -auto-approve -input=false
}
