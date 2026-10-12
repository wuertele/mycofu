#!/usr/bin/env bash
# list-backup-backed-vmids.sh — Print backup-backed VMIDs for first-deploy approval.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

usage() {
  cat >&2 <<'EOF'
Usage: list-backup-backed-vmids.sh [--format csv|tsv] <dev|prod|all>

Prints a comma-separated VMID list for backup-backed VMs in scope. Use this
for explicit FIRST_DEPLOY_ALLOW_VMIDS approval on a fresh cluster with no PBS
backups yet.

With --format tsv, prints: VMID<TAB>label<TAB>environment.
EOF
}

FORMAT="csv"
SCOPE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      FORMAT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    dev|prod|all)
      if [[ -n "$SCOPE" ]]; then
        usage
        exit 2
      fi
      SCOPE="$1"
      shift
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ "$FORMAT" != "csv" && "$FORMAT" != "tsv" ]]; then
  usage
  exit 2
fi
if [[ "$SCOPE" != "dev" && "$SCOPE" != "prod" && "$SCOPE" != "all" ]]; then
  usage
  exit 2
fi

SCOPE="$SCOPE" \
FORMAT="$FORMAT" \
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


def normalize_vmid(label, vmid):
    if vmid in (None, ""):
        print(f"ERROR: backup-backed VM '{label}' has no vmid", file=sys.stderr)
        sys.exit(1)
    try:
        value = int(vmid)
    except (TypeError, ValueError):
        print(f"ERROR: backup-backed VM '{label}' has invalid vmid: {vmid}", file=sys.stderr)
        sys.exit(1)
    if value <= 0:
        print(f"ERROR: backup-backed VM '{label}' has invalid vmid: {vmid}", file=sys.stderr)
        sys.exit(1)
    return value


def add_vmid(rows, seen, label, env_name, vmid):
    value = normalize_vmid(label, vmid)
    if value in seen:
        prev_label, prev_env = seen[value]
        print(
            f"ERROR: duplicate backup-backed VMID {value}: "
            f"{prev_label} ({prev_env}) and {label} ({env_name})",
            file=sys.stderr,
        )
        sys.exit(1)
    seen[value] = (label, env_name)
    rows.append((value, label, env_name))


scope = os.environ["SCOPE"]
output_format = os.environ["FORMAT"]
config = load_yaml_json(os.environ["CONFIG_FILE"], {}, required=True)
apps = load_yaml_json(os.environ["APPS_CONFIG_FILE"], {"applications": {}})

rows = []
seen = {}

for label, vm in (config.get("vms") or {}).items():
    if not isinstance(vm, dict):
        continue
    env_name = label_env(label)
    if vm.get("backup") is True and vm.get("enabled", True) is not False and in_scope(env_name, scope):
        add_vmid(rows, seen, label.replace("_", "-"), env_name, vm.get("vmid"))

for app, app_cfg in (apps.get("applications") or {}).items():
    if not isinstance(app_cfg, dict):
        continue
    if app_cfg.get("enabled") is not True or app_cfg.get("backup") is not True:
        continue
    for app_env, env_cfg in (app_cfg.get("environments") or {}).items():
        if isinstance(env_cfg, dict) and in_scope(app_env, scope):
            add_vmid(rows, seen, f"{app}-{app_env}", app_env, env_cfg.get("vmid"))

if output_format == "tsv":
    for vmid, label, env_name in rows:
        print(f"{vmid}\t{label}\t{env_name}")
else:
    print(",".join(str(vmid) for vmid, _, _ in rows))
PY
