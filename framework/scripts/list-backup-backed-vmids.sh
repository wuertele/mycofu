#!/usr/bin/env bash
# list-backup-backed-vmids.sh — Print backup-backed VMIDs for first-deploy approval.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

usage() {
  cat >&2 <<'EOF'
Usage: list-backup-backed-vmids.sh <dev|prod|all>

Prints a comma-separated VMID list for backup-backed VMs in scope. Use this
for explicit FIRST_DEPLOY_ALLOW_VMIDS approval on a fresh cluster with no PBS
backups yet.
EOF
}

SCOPE="${1:-}"
if [[ "$SCOPE" == "--help" || "$SCOPE" == "-h" ]]; then
  usage
  exit 0
fi
if [[ "$SCOPE" != "dev" && "$SCOPE" != "prod" && "$SCOPE" != "all" ]]; then
  usage
  exit 2
fi

SCOPE="$SCOPE" \
CONFIG_FILE="$CONFIG" \
APPS_CONFIG_FILE="$APPS_CONFIG" \
python3 - <<'PY'
import json
import os
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


def label_env(label):
    if label.endswith("_dev"):
        return "dev"
    if label.endswith("_prod"):
        return "prod"
    return "shared"


def in_scope(env_name, scope):
    return scope == "all" or env_name == scope


def add_vmid(vmids, seen, vmid):
    if vmid in (None, ""):
        return
    try:
        value = int(vmid)
    except (TypeError, ValueError):
        return
    if value not in seen:
        seen.add(value)
        vmids.append(value)


scope = os.environ["SCOPE"]
config = load_yaml_json(os.environ["CONFIG_FILE"], {}, required=True)
apps = load_yaml_json(os.environ["APPS_CONFIG_FILE"], {"applications": {}})

vmids = []
seen = set()

for label, vm in (config.get("vms") or {}).items():
    if isinstance(vm, dict) and vm.get("backup") is True and in_scope(label_env(label), scope):
        add_vmid(vmids, seen, vm.get("vmid"))

for app, app_cfg in (apps.get("applications") or {}).items():
    if not isinstance(app_cfg, dict):
        continue
    if app_cfg.get("enabled") is not True or app_cfg.get("backup") is not True:
        continue
    for app_env, env_cfg in (app_cfg.get("environments") or {}).items():
        if isinstance(env_cfg, dict) and in_scope(app_env, scope):
            add_vmid(vmids, seen, env_cfg.get("vmid"))

print(",".join(str(vmid) for vmid in vmids))
PY
