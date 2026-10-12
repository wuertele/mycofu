#!/usr/bin/env bash
# list-replicated-vmids.sh — Print VMIDs selected by replication policy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${LIST_REPLICATED_VMIDS_CONFIG:-${REPO_DIR}/site/config.yaml}"
APPS_CONFIG="${LIST_REPLICATED_VMIDS_APPS_CONFIG:-${REPO_DIR}/site/applications.yaml}"

usage() {
  cat >&2 <<'EOF'
Usage: list-replicated-vmids.sh [--format csv|tsv] [--mode replicated|policy-off|all] <dev|prod|all>

Prints VMIDs selected by the cadence replication policy:
  explicit cadence/false if set, otherwise backup:true uses 1m, otherwise off.

With --off, emits only explicit replicate:false rows.
With --format tsv, prints:
  VMID<TAB>label<TAB>environment<TAB>replicated<TAB>source<TAB>cadence<TAB>pvesr_schedule<TAB>cadence_seconds<TAB>seed_wait_class
where source is default-backup, default-derivable, or explicit.
EOF
}

FORMAT="csv"
MODE="replicated"
EXPLICIT_OFF_ONLY="false"
SCOPE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      FORMAT="$2"
      shift 2
      ;;
    --mode)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      MODE="$2"
      shift 2
      ;;
    --off)
      MODE="policy-off"
      EXPLICIT_OFF_ONLY="true"
      shift
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
if [[ "$MODE" != "replicated" && "$MODE" != "policy-off" && "$MODE" != "all" ]]; then
  usage
  exit 2
fi
if [[ "$SCOPE" != "dev" && "$SCOPE" != "prod" && "$SCOPE" != "all" ]]; then
  usage
  exit 2
fi

SCOPE="$SCOPE" \
FORMAT="$FORMAT" \
MODE="$MODE" \
EXPLICIT_OFF_ONLY="$EXPLICIT_OFF_ONLY" \
CONFIG_FILE="$CONFIG" \
APPS_CONFIG_FILE="$APPS_CONFIG" \
python3 - <<'PY'
import json
import os
import re
import subprocess
import sys


PROD_LABEL_PINS = {"gatus"}
ANCHOR_24H = {
    160: "03:00",
    301: "02:10",
    302: "02:20",
    305: "02:30",
    500: "02:40",
    502: "02:50",
}
CADENCE_PATTERN = re.compile(r"^([1-9][0-9]*)([mh])$")


def die(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def warn(message):
    print(f"[list-replicated-vmids] WARN: {message}", file=sys.stderr)


def load_yaml_json(path, default, required=False):
    if not os.path.exists(path):
        if required:
            die(f"required config file not found: {path}")
        return default
    try:
        raw = subprocess.check_output(
            ["yq", "-o=json", ".", path],
            stderr=subprocess.PIPE,
            text=True,
        )
        return json.loads(raw)
    except FileNotFoundError:
        die("yq not found; list-replicated-vmids.sh requires mikefarah yq v4")
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        print(f"ERROR: failed to parse YAML config with yq: {path}", file=sys.stderr)
        if stderr:
            print(stderr, file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as exc:
        die(f"yq produced invalid JSON for {path}: {exc}")


def label_env(label):
    if label in PROD_LABEL_PINS:
        return "prod"
    if label.endswith("_dev"):
        return "dev"
    if label.endswith("_prod"):
        return "prod"
    return "shared"


def in_scope(env_name, scope):
    return scope == "all" or env_name == scope


def normalize_vmid(path, vmid):
    if vmid in (None, ""):
        die(f"replication-policy VM '{path}' has no vmid")
    try:
        value = int(vmid)
    except (TypeError, ValueError):
        die(f"replication-policy VM '{path}' has invalid vmid: {vmid}")
    if value <= 0:
        die(f"replication-policy VM '{path}' has invalid vmid: {vmid}")
    return value


def valid_cadence(value):
    match = CADENCE_PATTERN.fullmatch(value)
    if not match:
        return False
    number = int(match.group(1))
    unit = match.group(2)
    if unit == "m":
        return 1 <= number <= 59
    return 1 <= number <= 24


def invalid_replicate(path, value):
    rendered = json.dumps(value, sort_keys=True)
    die(
        f"{path}.replicate has invalid cadence {rendered} "
        '(expected "<N>m" with 1<=N<=59, "<N>h" with 1<=N<=24, or false)'
    )


def policy_for(path, cfg, env_name):
    # Cadence-first ratified doctrine:
    #   explicit override        -> its cadence (or None if false)
    #   backup: true             -> "1m"   (default-precious floor)
    #   env in {prod, shared}    -> "1m"   (default-prod | default-shared)
    #   env == dev               -> "24h"  (default-dev)
    # Boolean `true` is not a valid form for `replicate:`. Boolean `false`
    # remains a valid explicit override.
    backup = cfg.get("backup") is True
    if "replicate" in cfg:
        value = cfg.get("replicate")
        if value is False:
            if backup:
                die(f"{path}.replicate must not be false when {path}.backup is true")
            return None, "explicit"
        if not isinstance(value, str):
            invalid_replicate(path, value)
        if not valid_cadence(value):
            invalid_replicate(path, value)
        if backup and value != "1m":
            die(f"{path}.replicate must be \"1m\" when {path}.backup is true")
        if backup and value == "1m":
            warn(
                'replicate: "1m" on backup:true VMs is redundant; '
                "the precious-floor default already forces 1m. "
                f"key={path}.replicate"
            )
        return value, "explicit"
    if backup:
        return "1m", "default-precious"
    if env_name == "dev":
        return "24h", "default-dev"
    if env_name == "prod":
        return "1m", "default-prod"
    return "1m", "default-shared"


def translate_cadence(policy_path, vmid, cadence):
    if cadence is None:
        return "", "", ""
    match = CADENCE_PATTERN.fullmatch(cadence)
    if not match:
        die(f"{policy_path}.replicate has invalid cadence {json.dumps(cadence)}")

    number = int(match.group(1))
    unit = match.group(2)
    if unit == "m":
        cadence_seconds = number * 60
        schedule = f"*/{number}"
    elif number < 24:
        cadence_seconds = number * 3600
        schedule = f"0/{number}:00"
    else:
        cadence_seconds = 86400
        if vmid not in ANCHOR_24H:
            die(
                f"{policy_path}.replicate: VMID {vmid} has 24h cadence "
                "but is not in the 24h anchor table"
            )
        schedule = ANCHOR_24H[vmid]

    seed_wait_class = "strict" if cadence_seconds <= 60 else "async"
    return schedule, str(cadence_seconds), seed_wait_class


def add_vmid(rows, seen, path, policy_path, label, env_name, vmid, cadence, source):
    value = normalize_vmid(path, vmid)
    if value in seen:
        prev_path, prev_env = seen[value]
        die(
            f"duplicate replication-policy VMID {value}: "
            f"{prev_path} ({prev_env}) and {path} ({env_name})"
        )
    seen[value] = (path, env_name)
    pvesr_schedule, cadence_seconds, seed_wait_class = translate_cadence(
        policy_path, value, cadence
    )
    rows.append(
        (
            value,
            label,
            env_name,
            cadence is not None,
            source,
            cadence or "",
            pvesr_schedule,
            cadence_seconds,
            seed_wait_class,
        )
    )


def row_matches_mode(row, mode, explicit_off_only):
    replicated = row[3]
    source = row[4]
    if explicit_off_only:
        return (not replicated) and source == "explicit"
    if mode == "all":
        return True
    if mode == "replicated":
        return replicated
    return not replicated


scope = os.environ["SCOPE"]
output_format = os.environ["FORMAT"]
mode = os.environ["MODE"]
explicit_off_only = os.environ["EXPLICIT_OFF_ONLY"] == "true"
config = load_yaml_json(os.environ["CONFIG_FILE"], {}, required=True)
apps = load_yaml_json(os.environ["APPS_CONFIG_FILE"], {"applications": {}})

rows = []
seen = {}

for key, vm in (config.get("vms") or {}).items():
    if not isinstance(vm, dict):
        continue
    if vm.get("enabled", True) is False:
        continue
    env_name = label_env(key)
    cadence, source = policy_for(f"vms.{key}", vm, env_name)
    add_vmid(
        rows,
        seen,
        f"vms.{key}",
        f"vms.{key}",
        key.replace("_", "-"),
        env_name,
        vm.get("vmid"),
        cadence,
        source,
    )

for app, app_cfg in (apps.get("applications") or {}).items():
    if not isinstance(app_cfg, dict):
        continue
    if app_cfg.get("enabled") is not True:
        continue
    for app_env, env_cfg in (app_cfg.get("environments") or {}).items():
        if not isinstance(env_cfg, dict):
            continue
        # Sprint 048 MR-4: cadence resolved per-env (default-dev vs
        # default-prod). An app-level explicit cadence still applies to
        # every environment.
        cadence, source = policy_for(f"applications.{app}", app_cfg, app_env)
        add_vmid(
            rows,
            seen,
            f"applications.{app}.environments.{app_env}",
            f"applications.{app}",
            f"{app}-{app_env}",
            app_env,
            env_cfg.get("vmid"),
            cadence,
            source,
        )

filtered_rows = [
    row
    for row in rows
    if in_scope(row[2], scope) and row_matches_mode(row, mode, explicit_off_only)
]

if output_format == "tsv":
    for (
        vmid,
        label,
        env_name,
        replicated,
        source,
        cadence,
        pvesr_schedule,
        cadence_seconds,
        seed_wait_class,
    ) in filtered_rows:
        replicated_text = "true" if replicated else "false"
        print(
            f"{vmid}\t{label}\t{env_name}\t{replicated_text}\t{source}"
            f"\t{cadence}\t{pvesr_schedule}\t{cadence_seconds}\t{seed_wait_class}"
        )
else:
    print(",".join(str(row[0]) for row in filtered_rows))
PY
