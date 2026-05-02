#!/usr/bin/env bash
# safe-apply.sh — Plan, guard control-plane, apply only the target environment.
#
# Usage:
#   safe-apply.sh dev             # deploy dev data-plane VMs
#   safe-apply.sh prod            # deploy prod data-plane VMs
#   safe-apply.sh dev --dry-run   # show categorization without applying
#   safe-apply.sh dev --ignore-approle-creds
#   safe-apply.sh dev --no-recovery   # skip failure recovery/post-success convergence (DR tests)
#
# The script:
#   1. Runs the AppRole credential preflight
#   2. Checks for control-plane image drift (informational warning)
#   3. Runs tofu plan (excluding control-plane modules)
#   4. Exports plan to JSON
#   5. Categorizes every change by environment
#   6. Builds a preboot restore manifest from the default plan
#      (start_vms=true/register_ha=true)
#   7. Applies target modules stopped with HA disabled
#   8. Runs restore-before-start.sh while VMs are stopped
#   9. Applies target modules again with start_vms/register_ha true
#  10. Runs post-success convergence. Failure recovery is phase-aware and
#      uses restore-before-start.sh --recovery-mode for Phase 1 failures.
#
# Module categorization (by naming convention):
#   Control-plane:  module.gitlab, module.cicd, module.pbs → workstation only
#   Dev data-plane: module.*_dev, module.acme_dev          → deploy:dev
#   Prod data-plane: module.*_prod, module.gatus           → deploy:prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Control-plane module list ---
# These modules are excluded from plan and apply. Two reasons:
#   gitlab, pbs: prevent_destroy = true (tofu plan crashes if they have changes)
#   cicd: self-hosting constraint (pipeline cannot redeploy the runner it runs on)
# IMPORTANT: if you add a control-plane module here, also update
# CONTROL_PLANE_MODULES in framework/scripts/validate.sh (R7.2 check).
CONTROL_PLANE_MODULES="module.gitlab module.cicd module.pbs"

# Build -exclude flags from the module list
# Requires OpenTofu >= 1.9. The cicd image includes opentofu from nixpkgs.
EXCLUDES=""
for mod in $CONTROL_PLANE_MODULES; do
  EXCLUDES="$EXCLUDES -exclude=$mod"
done

# --- Parse arguments ---
ENV=""
DRY_RUN=0
IGNORE_APPROLE_CREDS=0
NO_RECOVERY=0

USAGE="Usage: $(basename "$0") <dev|prod> [--dry-run] [--ignore-approle-creds] [--no-recovery]"

while [[ $# -gt 0 ]]; do
  case "$1" in
    dev|prod)
      if [[ -n "$ENV" ]]; then
        echo "ERROR: Environment specified more than once: $1" >&2
        exit 1
      fi
      ENV="$1"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --ignore-approle-creds)
      IGNORE_APPROLE_CREDS=1
      shift
      ;;
    --no-recovery)
      NO_RECOVERY=1
      shift
      ;;
    --help|-h)
      echo "$USAGE" >&2
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "$USAGE" >&2
      exit 1
      ;;
  esac
done

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "$USAGE" >&2
  exit 1
fi

# --- Temp files with cleanup ---
# Use a unique temp dir per invocation so concurrent runs (e.g., parallel
# CI fixture jobs) cannot collide on shared /tmp paths. (codex P2.2)
SAFE_APPLY_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/safe-apply.XXXXXX")"
PLAN_OUT="${SAFE_APPLY_TMPDIR}/plan.out"
PLAN_JSON="${SAFE_APPLY_TMPDIR}/plan.json"
CATEGORIZE_OUT="${SAFE_APPLY_TMPDIR}/categorize.out"
SHOW_RAW="${SAFE_APPLY_TMPDIR}/show-raw.out"
PREBOOT_MANIFEST="${REPO_DIR}/build/preboot-restore-${ENV}.json"
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "safe-apply.sh failed at line ${BASH_LINENO[0]} with exit code $exit_code" >&2
  fi
  rm -rf "$SAFE_APPLY_TMPDIR"
}
trap cleanup EXIT

# Sanity: refuse to run without a tmpdir
if [[ -z "$SAFE_APPLY_TMPDIR" || ! -d "$SAFE_APPLY_TMPDIR" ]]; then
  echo "ERROR: failed to create tmpdir" >&2
  exit 1
fi

# --- Preflight AppRole credential check ---
# Run before any tofu-wrapper command so missing catalog AppRole credentials
# fail before tofu init/image validation and before any state-modifying action.
echo ""
echo "=== AppRole credential preflight ==="
if [[ $IGNORE_APPROLE_CREDS -eq 1 ]]; then
  echo "WARNING: Skipping AppRole credential preflight due to --ignore-approle-creds"
  echo ""
else
  FORCE_ENV="$ENV" "${SCRIPT_DIR}/check-approle-creds.sh"
  echo ""
fi

# --- Check for control-plane live closure drift (informational, non-fatal) ---
# Uses check-control-plane-drift.sh to compare flake closure paths against
# /run/current-system on gitlab/cicd. This warning helps the operator see
# control-plane drift early, but does not block the data-plane deploy.
echo ""
echo "=== Checking control-plane live closure drift ==="
set +e
"${SCRIPT_DIR}/check-control-plane-drift.sh" 2>&1
CP_DRIFT_EXIT=$?
set -e

if [[ $CP_DRIFT_EXIT -eq 1 ]]; then
  echo ""
  echo "=================================================="
  echo "WARNING: Control-plane live closure drift detected"
  echo "=================================================="
  echo ""
  echo "  The data-plane deploy will proceed, but control-plane VMs"
  echo "  need manual deployment from the workstation."
  echo ""
  echo "  After this deploy completes, update control-plane VMs using converge-vm.sh:"
  echo "    1. Build the new closure: nix build .#nixosConfigurations.<host>.config.system.build.toplevel"
  echo "    2. Deploy: framework/scripts/converge-vm.sh --closure <store-path> --targets <host-ip>"
  echo "       Verify: VM reboots into new closure, validate.sh passes"
  echo "    3. Repeat for each drifted control-plane VM (gitlab, cicd)"
  echo ""
  echo "  Proceeding with data-plane deploy only."
  echo "=================================================="
  echo ""
elif [[ $CP_DRIFT_EXIT -eq 2 ]]; then
  echo "  (drift check could not run — proceeding with deploy)"
  echo ""
fi

# --- Run tofu plan (excluding control-plane modules) ---
# Control-plane modules are excluded so prevent_destroy doesn't crash the plan.
# Drift on those modules is detected separately (above warning + R7.2 in validate.sh).
echo "Planning data-plane modules (excluding control-plane)..."
"${SCRIPT_DIR}/tofu-wrapper.sh" plan ${EXCLUDES} -out="$PLAN_OUT" -no-color
echo "Plan complete, exporting to JSON..."

# --- Export plan to JSON ---
# tofu-wrapper.sh prints "Decrypting secrets..." before the JSON.
# Extract only the JSON object (find the first '{').
if [[ ! -f "$PLAN_OUT" ]]; then
  echo "ERROR: Plan file not found: $PLAN_OUT" >&2
  exit 1
fi
# tofu show -json reads a local plan file — no backend or secrets needed.
# Run it directly, bypassing the wrapper entirely.
# (SHOW_RAW is set above in SAFE_APPLY_TMPDIR for concurrency safety.)
tofu -chdir="${SCRIPT_DIR}/../tofu/root" show -json "$PLAN_OUT" > "$SHOW_RAW"
python3 -c "
import json, sys
with open('$SHOW_RAW') as f:
    d = f.read()
i = d.find('{')
if i < 0:
    print('ERROR: No JSON object in tofu show output', file=sys.stderr)
    print('Output was:', d[:500], file=sys.stderr)
    sys.exit(1)
decoder = json.JSONDecoder()
obj, _ = decoder.raw_decode(d[i:])
with open('$PLAN_JSON', 'w') as f:
    json.dump(obj, f)
    f.write('\n')
"

# --- Categorize changes ---
# With -exclude on plan, control-plane modules never appear in the plan JSON.
# Categorization only handles data-plane modules.
set +e
DEPLOY_ENV="$ENV" python3 -c "
import sys, json, os, re

env = os.environ['DEPLOY_ENV']
DEV_EXTRAS = {'module.acme_dev'}
PROD_EXTRAS = {'module.gatus'}

with open('$PLAN_JSON') as f:
    plan = json.load(f)

deployable = []
skipped = []

for rc in plan.get('resource_changes', []):
    actions = rc.get('change', {}).get('actions', [])
    if actions == ['no-op'] or actions == ['read']:
        continue

    addr = rc.get('address', '')
    mod = '.'.join(addr.split('.')[:2]) if '.' in addr else addr
    # Strip count/for_each index (e.g., module.grafana_dev[0] -> module.grafana_dev)
    mod = re.sub(r'\[.*\]$', '', mod)

    if mod.endswith(f'_{env}') or mod in (DEV_EXTRAS if env == 'dev' else PROD_EXTRAS):
        deployable.append(mod)
    else:
        other_env = 'prod' if env == 'dev' else 'dev'
        if not mod.endswith(f'_{other_env}') and mod not in (DEV_EXTRAS | PROD_EXTRAS):
            print(f'WARNING: module {mod} does not match any environment -- skipping', file=sys.stderr)
        skipped.append(mod)

# Output unique deployable modules (one per line)
for mod in sorted(set(deployable)):
    print(mod)
" > "$CATEGORIZE_OUT" 2>&1

CATEGORIZE_EXIT=$?
set -e

# --- Handle results ---
if [[ $CATEGORIZE_EXIT -ne 0 ]]; then
  echo "ERROR: Plan categorization failed:"
  cat "$CATEGORIZE_OUT"
  exit 1
fi

# Extract -target flags from categorize output (skip non-module lines)
TARGETS=""
while IFS= read -r line; do
  [[ "$line" == WARNING:* ]] && echo "$line" >&2 && continue
  [[ -z "$line" ]] && continue
  TARGETS="$TARGETS -target=$line"
done < "$CATEGORIZE_OUT"

if [[ -z "$TARGETS" ]]; then
  echo "No changes for ${ENV} environment"
  exit 0
fi

SAFE_APPLY_CONFIG="${REPO_DIR}/site/config.yaml"
SAFE_APPLY_APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

# Resolve PIN_FILE once. restore-before-start.sh and failure recovery receive
# the same absolute path no matter where the operator invoked safe-apply from.
if [[ -z "${PIN_FILE:-}" ]]; then
  PIN_FILE_ABS="${REPO_DIR}/build/restore-pin-${ENV}.json"
elif [[ "${PIN_FILE}" == /* ]]; then
  PIN_FILE_ABS="${PIN_FILE}"
else
  PIN_FILE_ABS="${REPO_DIR}/${PIN_FILE}"
fi

build_preboot_restore_manifest() {
  DEPLOY_ENV="$ENV" \
  PLAN_JSON="$PLAN_JSON" \
  MANIFEST_OUT="$PREBOOT_MANIFEST" \
  CONFIG_FILE="$SAFE_APPLY_CONFIG" \
  APPS_CONFIG_FILE="$SAFE_APPLY_APPS_CONFIG" \
  PIN_FILE_ABS="$PIN_FILE_ABS" \
  python3 - <<'PY'
import json
import os
import re
import subprocess
import sys


def load_yaml_json(path, default, required=False):
    if not os.path.exists(path):
        if required:
            print(f"ERROR: required config file not found: {path}", file=sys.stderr)
            sys.exit(1)
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
        print(f"ERROR: failed to parse YAML config with yq: {path}", file=sys.stderr)
        if stderr:
            print(stderr, file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as exc:
        print(f"ERROR: yq produced invalid JSON for {path}: {exc}", file=sys.stderr)
        sys.exit(1)


def root_module(address):
    parts = address.split(".")
    if len(parts) < 2 or parts[0] != "module":
        return ""
    label = re.sub(r"\[.*\]$", "", parts[1])
    return f"module.{label}"


def label_env(label):
    if label.endswith("_dev"):
        return "dev"
    if label.endswith("_prod"):
        return "prod"
    return "shared"


def add_backup_module(backups, label, vmid, kind):
    if vmid in (None, ""):
        return
    try:
        vmid_int = int(vmid)
    except Exception:
        return
    backups[f"module.{label}"] = {
        "label": label,
        "module": f"module.{label}",
        "vmid": vmid_int,
        "env": label_env(label),
        "kind": kind,
    }


env = os.environ["DEPLOY_ENV"]
plan_path = os.environ["PLAN_JSON"]
manifest_out = os.environ["MANIFEST_OUT"]
config = load_yaml_json(os.environ["CONFIG_FILE"], {}, required=True)
apps = load_yaml_json(os.environ["APPS_CONFIG_FILE"], {"applications": {}})

backups = {}
for label, vm in (config.get("vms") or {}).items():
    if isinstance(vm, dict) and vm.get("backup") is True:
        kind = "control-plane" if label in {"gitlab", "cicd", "pbs"} else "infrastructure"
        add_backup_module(backups, label, vm.get("vmid"), kind)

for app, app_cfg in (apps.get("applications") or {}).items():
    if not isinstance(app_cfg, dict):
        continue
    if app_cfg.get("enabled") is not True or app_cfg.get("backup") is not True:
        continue
    for app_env, env_cfg in (app_cfg.get("environments") or {}).items():
        if isinstance(env_cfg, dict):
            add_backup_module(backups, f"{app}_{app_env}", env_cfg.get("vmid"), "application")

pins = {}
pin_file = os.environ.get("PIN_FILE_ABS", "")
if pin_file and os.path.exists(pin_file):
    try:
        with open(pin_file) as f:
            pins = (json.load(f).get("pins") or {})
    except Exception:
        pins = {}

with open(plan_path) as f:
    plan = json.load(f)

entries = {}
for rc in plan.get("resource_changes", []):
    address = rc.get("address", "")
    if "proxmox_virtual_environment_vm.vm" not in address:
        continue

    module = root_module(address)
    backup = backups.get(module)
    if not backup:
        continue
    if backup["env"] != env:
        continue

    change = rc.get("change") or {}
    actions = change.get("actions") or []
    before = change.get("before") or {}
    after = change.get("after") or {}

    reason = ""
    if actions == ["create"]:
        reason = "create"
    elif "create" in actions and "delete" in actions:
        reason = "replace"
    elif before.get("started") is False and after.get("started") is True:
        reason = "started-false-resume"

    if not reason:
        continue

    entry = dict(backup)
    entry["reason"] = reason
    pin = pins.get(str(entry["vmid"]))
    if pin:
        entry["pin"] = pin
    entries[module] = entry

manifest = {
    "version": 1,
    "scope": env,
    "source": "default-plan",
    "entries": [entries[key] for key in sorted(entries)],
}
os.makedirs(os.path.dirname(manifest_out), exist_ok=True)
with open(manifest_out, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
}

echo ""
echo "=== Building preboot restore manifest (${ENV}) ==="
build_preboot_restore_manifest
echo "Manifest: ${PREBOOT_MANIFEST}"
if command -v jq >/dev/null 2>&1; then
  echo "Restore entries: $(jq '.entries | length' "$PREBOOT_MANIFEST")"
fi

echo ""
echo "=== Deploying ${ENV} modules ==="
echo "Targets:${TARGETS}"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(dry-run — not applying)"
  exit 0
fi

# --- Verify HA resources against Proxmox before apply ---
# The bpg provider's Read function does not detect HA resources that are
# missing from Proxmox but present in tofu state (verified broken on
# v0.99.0, v0.100.0, v0.101.0). This causes tofu to plan UPDATE on
# nonexistent resources, which fails with HTTP 500. Query Proxmox
# directly via SSH to detect and remove stale HA state entries before
# the apply encounters them.
# See: docs/reports/report-v0101-ha-read-still-broken-2026-04-09.md
# Verify HA resources: remove stale state entries for HA resources that
# don't exist in Proxmox, and remove orphan Proxmox HA resources that
# don't exist in state (left by killed applies, #190).
# See issues #20, #158, #190.
verify_ha_resources() {
  local node_ip="$1"

  # Distinguish "state list succeeded with zero HA entries" from "state list
  # failed." A failed state list produces empty ha_resources, which would
  # cause Phase 1b to treat every Proxmox HA resource as an orphan. (#190)
  local all_state=""
  local ha_resources=""
  set +e
  all_state=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null)
  local state_list_exit=$?
  set -e
  if [[ $state_list_exit -ne 0 ]]; then
    echo "ERROR: tofu state list failed (exit ${state_list_exit}) — cannot determine HA state"
    echo "ERROR: Failing closed — refusing to proceed without reliable state"
    return 1
  fi
  ha_resources=$(echo "$all_state" | grep 'haresource' || true)

  local proxmox_ha
  proxmox_ha=$(ssh -n -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${node_ip}" \
    "pvesh get /cluster/ha/resources --output-format json" 2>/dev/null)

  if [[ -z "$proxmox_ha" || "$proxmox_ha" == "null" ]]; then
    echo "ERROR: Cannot query HA resources from ${node_ip}"
    echo "ERROR: Failing closed — refusing to proceed without HA verification"
    return 1
  fi

  local proxmox_vmids
  proxmox_vmids=$(echo "$proxmox_ha" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for r in data:
        sid = r.get('sid', '')
        if sid.startswith('vm:'):
            print(sid.split(':')[1])
except:
    pass
  ")

  # Phase 1: Remove stale state entries (in state but not in Proxmox)
  # Also collect state VMIDs for the reverse check in Phase 1b.
  local stale_count=0
  local state_vmids=""
  local state_extract_failures=0
  if [[ -n "$ha_resources" ]]; then
    while IFS= read -r resource_addr; do
      [[ -z "$resource_addr" ]] && continue
      local vmid
      vmid=$("${SCRIPT_DIR}/tofu-wrapper.sh" state show "$resource_addr" \
        2>/dev/null | grep 'resource_id' | grep -o '[0-9]*' || true)

      if [[ -z "$vmid" ]]; then
        echo "  WARNING: Could not extract VMID from ${resource_addr} — skipping"
        state_extract_failures=$((state_extract_failures + 1))
        continue
      fi

      state_vmids="${state_vmids}${vmid}"$'\n'

      if ! echo "$proxmox_vmids" | grep -q "^${vmid}$"; then
        echo "  HA resource vm:${vmid} in state but NOT in Proxmox — removing stale entry"
        echo "    State address: ${resource_addr}"
        "${SCRIPT_DIR}/tofu-wrapper.sh" state rm "$resource_addr" >/dev/null 2>&1
        stale_count=$((stale_count + 1))
      fi
    done <<< "$ha_resources"

    if [[ $stale_count -gt 0 ]]; then
      echo "  Removed ${stale_count} stale HA resource(s) from state"
    fi
  fi

  # Phase 1b: Remove orphan Proxmox HA resources (in Proxmox but not in state).
  # Left behind by killed tofu apply runs. Without this, the next tofu apply
  # plans CREATE and Proxmox rejects with "resource ID already defined." (#190)
  #
  # Safety: skip if any state extraction failed — incomplete state_vmids
  # would cause legitimate HA resources to be removed.
  local orphan_count=0
  local orphan_remove_failures=0
  if [[ $state_extract_failures -gt 0 ]]; then
    echo "  WARNING: ${state_extract_failures} state extraction(s) failed — skipping orphan cleanup"
    echo "  Phase 1b cannot safely identify orphans without a complete state VMID list"
  else
  while IFS= read -r proxmox_vmid; do
    [[ -z "$proxmox_vmid" ]] && continue
    if ! echo "$state_vmids" | grep -q "^${proxmox_vmid}$"; then
      echo "  HA resource vm:${proxmox_vmid} in Proxmox but NOT in state — removing orphan"
      if ssh -n -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${node_ip}" \
        "ha-manager remove vm:${proxmox_vmid}" 2>/dev/null; then
        orphan_count=$((orphan_count + 1))
      else
        echo "  ERROR: ha-manager remove failed for vm:${proxmox_vmid} — orphan remains"
        orphan_remove_failures=$((orphan_remove_failures + 1))
      fi
    fi
  done <<< "$proxmox_vmids"

  if [[ $orphan_count -gt 0 ]]; then
    echo "  Removed ${orphan_count} orphan HA resource(s) from Proxmox"
  fi
  fi  # end state_extract_failures guard

  if [[ $orphan_remove_failures -gt 0 ]]; then
    echo "  WARNING: ${orphan_remove_failures} orphan removal(s) failed — next apply may encounter 'already defined'"
  elif [[ $stale_count -eq 0 && $orphan_count -eq 0 ]]; then
    echo "  All HA resources verified"
  fi

  return 0
}

FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$SAFE_APPLY_CONFIG")

# Pre-apply: remove stale/orphan HA state entries so the apply doesn't
# fail on resources that no longer exist in Proxmox (#190).
echo ""
echo "=== Pre-apply HA verification ==="
if ! verify_ha_resources "$FIRST_NODE_IP"; then
  echo "HA resource verification failed — cannot proceed with apply" >&2
  exit 1
fi

# --- Phase-aware recovery/convergence (#224 replacement) ---
# --no-recovery suppresses failure recovery and post-success convergence, but
# it does not suppress restore-before-start.sh after a successful Phase 1.
run_recovery() {
  local context="$1"  # currently "phase-1-failed"

  if [[ $NO_RECOVERY -eq 1 ]]; then
    echo ""
    echo "=== Skipping run_recovery (--no-recovery) ==="
    return 0
  fi

  echo ""
  echo "=== Phase-aware recovery (${context}) ==="
  echo "    Manifest: ${PREBOOT_MANIFEST}"
  echo "    Pin file: ${PIN_FILE_ABS}"

  echo ""
  echo "--- restore-before-start.sh ${ENV} --recovery-mode ---"
  local restore_rc=0
  "${SCRIPT_DIR}/restore-before-start.sh" "$ENV" \
    --manifest "$PREBOOT_MANIFEST" \
    --pin-file "$PIN_FILE_ABS" \
    --recovery-mode || restore_rc=$?
  if [[ $restore_rc -ne 0 ]]; then
    echo ""
    echo "ERROR: restore-before-start.sh --recovery-mode failed (rc=$restore_rc)"
    return $restore_rc
  fi

  return 0
}

run_post_success() {
  if [[ $NO_RECOVERY -eq 1 ]]; then
    echo ""
    echo "=== Skipping post-success convergence (--no-recovery) ==="
    return 0
  fi

  echo ""
  echo "--- configure-replication.sh \"*\" ---"
  local repl_rc=0
  "${SCRIPT_DIR}/configure-replication.sh" "*" || repl_rc=$?
  if [[ $repl_rc -ne 0 ]]; then
    echo ""
    echo "ERROR: configure-replication.sh failed (rc=$repl_rc)"
    echo "Skipping post-deploy.sh — cluster replication state is unknown."
    return $repl_rc
  fi

  echo ""
  echo "--- post-deploy.sh ${ENV} ---"
  local post_rc=0
  "${SCRIPT_DIR}/post-deploy.sh" "$ENV" || post_rc=$?
  return $post_rc
}

# Note: -target and -exclude are mutually exclusive in OpenTofu.
# The plan uses -exclude (to avoid prevent_destroy). The apply uses -target
# (from the categorizer, which already excludes control-plane modules).
echo ""
echo "=== First apply: create/update stopped VMs ==="
set +e
"${SCRIPT_DIR}/tofu-wrapper.sh" apply ${TARGETS} \
  -var=start_vms=false \
  -var=register_ha=false \
  -auto-approve
PHASE1_RC=$?
set -e

if [[ $PHASE1_RC -ne 0 ]]; then
  echo ""
  echo "=================================================="
  echo "ERROR: Phase 1 tofu apply failed (rc=$PHASE1_RC)"
  echo "Running recovery-mode restore for any stopped VM that"
  echo "was created before the failure. Phase 2, replication,"
  echo "and post-deploy will be skipped."
  echo "=================================================="
  set +e
  run_recovery "phase-1-failed"
  RECOVERY_RC=$?
  set -e
  if [[ $RECOVERY_RC -ne 0 ]]; then
    echo ""
    echo "WARNING: recovery failed (rc=$RECOVERY_RC) after Phase 1"
    echo "apply failure. Apply rc=$PHASE1_RC takes precedence as the"
    echo "exit code (more diagnostic of the original failure)."
  fi
  exit $PHASE1_RC
fi

echo ""
echo "=== Restore before start (${ENV}) ==="
set +e
"${SCRIPT_DIR}/restore-before-start.sh" "$ENV" \
  --manifest "$PREBOOT_MANIFEST" \
  --pin-file "$PIN_FILE_ABS"
RESTORE_RC=$?
set -e

if [[ $RESTORE_RC -ne 0 ]]; then
  echo ""
  echo "=================================================="
  echo "ERROR: restore-before-start.sh failed (rc=$RESTORE_RC)"
  echo "Skipping phase 2: one or more vdb restores failed."
  echo "Skipping configure-replication.sh and post-deploy.sh."
  echo "=================================================="
  exit $RESTORE_RC
fi

echo ""
echo "=== Second apply: start VMs and register HA ==="
set +e
"${SCRIPT_DIR}/tofu-wrapper.sh" apply ${TARGETS} \
  -var=start_vms=true \
  -var=register_ha=true \
  -auto-approve
PHASE2_RC=$?
set -e

if [[ $PHASE2_RC -ne 0 ]]; then
  echo ""
  echo "=================================================="
  echo "ERROR: Phase 2 tofu apply failed (rc=$PHASE2_RC)"
  echo "Data restore already completed. Skipping post-deploy;"
  echo "next run can retry the start/register phase."
  echo "=================================================="
  exit $PHASE2_RC
fi

# Final HA verification: clean up any stale/orphan HA entries created
# by the applies. Runs once after ALL applies complete.
echo ""
echo "=== Final HA verification ==="
if ! verify_ha_resources "$FIRST_NODE_IP"; then
  echo "WARNING: Final HA verification failed" >&2
fi

set +e
run_post_success
POST_SUCCESS_RC=$?
set -e
if [[ $POST_SUCCESS_RC -ne 0 ]]; then
  echo ""
  echo "ERROR: post-success convergence failed (rc=$POST_SUCCESS_RC)"
  exit $POST_SUCCESS_RC
fi
