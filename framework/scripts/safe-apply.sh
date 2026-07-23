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
#   Dev data-plane: module.*_dev, module.acme_dev, module.hil_boot → deploy:dev
#   Prod data-plane: module.*_prod, module.gatus           → deploy:prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TOFU_BIN_LIB="${SCRIPT_DIR}/lib/tofu-bin.sh"
if [[ -f "$TOFU_BIN_LIB" ]]; then
  source "$TOFU_BIN_LIB"
else
  mycofu_resolve_tofu_bin() {
    if [[ -n "${MYCOFU_TOFU_BIN:-}" ]]; then
      if [[ ! -x "${MYCOFU_TOFU_BIN}" ]]; then
        echo "ERROR: MYCOFU_TOFU_BIN is not executable: ${MYCOFU_TOFU_BIN}" >&2
        return 1
      fi
      printf '%s\n' "${MYCOFU_TOFU_BIN}"
    elif command -v tofu >/dev/null 2>&1; then
      command -v tofu
    else
      echo "ERROR: Required tool not found: tofu" >&2
      return 1
    fi
  }
fi
: "${VM_SCOPE_SCRIPT:=${SCRIPT_DIR}/vm-scope.sh}"
TOFU_WRAPPER="${MYCOFU_TOFU_WRAPPER:-${SCRIPT_DIR}/tofu-wrapper.sh}"
APPROLE_CHECK="${MYCOFU_APPROLE_CHECK:-${SCRIPT_DIR}/check-approle-creds.sh}"
DRIFT_CHECK="${MYCOFU_DRIFT_CHECK:-${SCRIPT_DIR}/check-control-plane-drift.sh}"
source "${SCRIPT_DIR}/lib/converge-incomplete-vm.sh"
VDB_PARK_CONFIG="${REPO_DIR}/site/config.yaml"
VDB_PARK_APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
# shellcheck source=framework/scripts/vdb-park-lib.sh
source "${SCRIPT_DIR}/vdb-park-lib.sh"

# --- Control-plane module list ---
# These modules are excluded from plan and apply. The authoritative taxonomy is
# framework/scripts/vm-scope.sh reading scope/control_plane from the manifests.
CONTROL_PLANE_MODULES="$("${VM_SCOPE_SCRIPT}" control-plane-modules | tr '\n' ' ' | sed 's/ $//')"

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
PARK_STATUS_FILE="${REPO_DIR}/build/vdb-park-status-${ENV}.json"
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

# run_configure_backups — invoke configure-backups.sh iff PBS storage is
# registered on the first Proxmox node.
#
# Skips (rc=0) when PBS storage isn't registered — the first-deploy case
# where install-pbs.sh hasn't run yet. That's a false-error, not real drift.
#
# Shared between run_post_success and the no-change retry path so both use
# the same PBS-availability guard. The guard mirrors the one that previously
# lived inside post-deploy.sh (extracted per #620): reconciliation of the
# managed vzdump job must NOT be gated behind Vault-init or replication
# success, because Proxmox purges VMIDs from that job on any destructive
# VM recreation.
#
# Reads REPO_DIR and SCRIPT_DIR from outer scope. Returns configure-backups.sh's
# exit code when it runs, or 0 when the PBS-availability guard skips it.
run_configure_backups() {
  local first_node_ip
  # Fail loudly (rc=1) if yq cannot resolve the first node's mgmt IP:
  # the caller has errexit disabled around this helper (both callers use
  # `|| ...=$?` / `set +e`), so an unchecked yq failure would leave
  # first_node_ip empty, cause the ssh probe to fail, and take the
  # "PBS storage not available" branch — silently converting a real
  # config error into a "no-op, exit 0" false success. That violates the
  # .claude/rules/destruction-safety.md "unknown state → FAIL, not SKIP"
  # rule for the backup-job reconciliation invariant. Adversarial review
  # P2-1 on this MR.
  if ! first_node_ip=$(yq -r '.nodes[0].mgmt_ip' "${REPO_DIR}/site/config.yaml" 2>/dev/null) \
     || [[ -z "$first_node_ip" || "$first_node_ip" == "null" ]]; then
    echo "ERROR: could not resolve first node mgmt_ip from ${REPO_DIR}/site/config.yaml" >&2
    return 1
  fi
  # Query PBS availability with an anchored grep so future storages named
  # e.g. `pbs-nas-legacy` cannot false-positive. Capture SSH's exit code
  # so we can distinguish a connection failure (255 from OpenSSH) or a
  # "storage-list ran, pbs-nas absent" case (grep exit 1) from an
  # unexpected fault — otherwise the operator would see the same
  # "PBS storage not available" line for real connectivity outages.
  # Adversarial review P2 on this MR (SSH-failure/PBS-absent conflation).
  local ssh_out ssh_rc
  ssh_out=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
       -o UserKnownHostsFile=/dev/null \
       "root@${first_node_ip}" \
       "pvesm status 2>/dev/null" 2>/dev/null)
  ssh_rc=$?
  if [[ $ssh_rc -eq 255 ]]; then
    echo "ERROR: SSH connection to root@${first_node_ip} failed (rc=255)" >&2
    echo "Cannot determine PBS availability — refusing to silent-skip" >&2
    return 1
  fi
  if [[ $ssh_rc -ne 0 ]]; then
    echo "ERROR: pvesm status via root@${first_node_ip} failed (rc=${ssh_rc})" >&2
    echo "Cannot determine PBS availability — refusing to silent-skip" >&2
    return 1
  fi
  if grep -Eq '(^|[[:space:]])pbs-nas([[:space:]]|$)' <<< "$ssh_out"; then
    "${SCRIPT_DIR}/configure-backups.sh"
    return $?
  else
    echo "PBS storage not available — skipping backup-job reconciliation"
    return 0
  fi
}

# run_post_success — post-Phase-2 convergence: Vault post-deploy (via
# post-deploy.sh), backup-job reconciliation (via configure-backups.sh),
# and ZFS replication state (via configure-replication.sh).
#
# All three steps are INVOKED unconditionally: a failure in one does NOT
# cause a later one to be skipped. The load-bearing invariant is that
# configure-backups.sh runs after destructive recreation independently
# of BOTH Vault-init failures inside post-deploy.sh (#620) AND replication
# convergence failures (#617), because Proxmox purges VMIDs from the
# managed vzdump job during destructive VM recreation, and the deploy
# path needs to reconcile that drift regardless of adjacent failure modes.
# See #617, #620, and RCA
# docs/reports/2026-07-17-dev-precious-backup-jobs-missing-rca.md.
#
# Return value: 0 iff all three steps succeeded. Otherwise the first
# non-zero rc encountered in execution order: post-deploy → backups →
# replication. This preserves the "deploy still fails on downstream
# convergence error" contract while ensuring backup-job reconciliation
# happens on every path.
#
# Called only from the success path after Phase 2 completes (bottom of
# this script). The "No changes" exit uses a tighter path — direct
# run_configure_backups — because on a no-change retry the only
# documented drift is backup-job membership (per the RCA retry-scenario
# evidence); running the full post-success workflow there would tear
# down transient replication first-syncs and hang on Vault reachability
# probes.
#
# Defined here (before the "No changes" exit further down) so the file
# is readable top-to-bottom without hunting for the definition. Reads
# PARK_STATUS_FILE, NO_RECOVERY, SCRIPT_DIR, ENV from outer scope.
# PARK_STATUS_FILE is set unconditionally at cleanup-trap time.
run_post_success() {
  if [[ $NO_RECOVERY -eq 1 ]]; then
    echo ""
    echo "=== Skipping post-success convergence (--no-recovery) ==="
    return 0
  fi

  echo ""
  echo "--- post-deploy.sh ${ENV} ---"
  local post_rc=0
  "${SCRIPT_DIR}/post-deploy.sh" "$ENV" || post_rc=$?
  if [[ $post_rc -ne 0 ]]; then
    echo ""
    echo "ERROR: post-deploy.sh failed (rc=$post_rc)"
    echo "Continuing to configure-backups.sh and configure-replication.sh."
    echo "Backup-job reconciliation must not be gated behind Vault post-deploy."
    echo "First non-zero rc is propagated at exit."
  fi

  echo ""
  echo "--- configure-backups.sh (post-success reconciliation) ---"
  local backups_rc=0
  run_configure_backups || backups_rc=$?
  if [[ $backups_rc -ne 0 ]]; then
    echo ""
    echo "ERROR: configure-backups.sh failed (rc=$backups_rc)"
    echo "Continuing to configure-replication.sh — replication convergence"
    echo "is independent of backup-job reconciliation."
  fi

  echo ""
  echo "--- configure-replication.sh \"*\" ---"
  local repl_rc=0
  if [[ -f "$PARK_STATUS_FILE" ]]; then
    "${SCRIPT_DIR}/configure-replication.sh" "*" --park-status "$PARK_STATUS_FILE" --env "$ENV" || repl_rc=$?
  else
    "${SCRIPT_DIR}/configure-replication.sh" "*" --env "$ENV" || repl_rc=$?
  fi
  if [[ $repl_rc -ne 0 ]]; then
    echo ""
    echo "ERROR: configure-replication.sh failed (rc=$repl_rc)"
  fi

  # First non-zero rc wins in execution order: post-deploy → backups →
  # replication. Each rc is a real deploy failure the caller must see.
  if [[ $post_rc -ne 0 ]]; then
    return $post_rc
  fi
  if [[ $backups_rc -ne 0 ]]; then
    return $backups_rc
  fi
  return $repl_rc
}

# --- Preflight AppRole credential check ---
# Run before any tofu-wrapper command so missing catalog AppRole credentials
# fail before tofu init/image validation and before any state-modifying action.
echo ""
echo "=== AppRole credential preflight ==="
if [[ $IGNORE_APPROLE_CREDS -eq 1 ]]; then
  echo "WARNING: Skipping AppRole credential preflight due to --ignore-approle-creds"
  echo ""
else
  FORCE_ENV="$ENV" "$APPROLE_CHECK"
  echo ""
fi

# --- Check for control-plane live closure drift (informational, non-fatal) ---
# Uses check-control-plane-drift.sh to compare flake closure paths against
# /run/current-system on gitlab/cicd. This warning helps the operator see
# control-plane drift early, but does not block the data-plane deploy.
echo ""
echo "=== Checking control-plane live closure drift ==="
set +e
"$DRIFT_CHECK" 2>&1
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
"$TOFU_WRAPPER" plan ${EXCLUDES} -out="$PLAN_OUT" -no-color
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
TOFU_BIN="$(mycofu_resolve_tofu_bin)" || exit 1
"$TOFU_BIN" -chdir="${SCRIPT_DIR}/../tofu/root" show -json "$PLAN_OUT" > "$SHOW_RAW"
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

set +e
"${VM_SCOPE_SCRIPT}" deployable-modules --env "$ENV" --plan-json "$PLAN_JSON" > "$CATEGORIZE_OUT" 2>&1
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
  # A prior deploy may have destructively recreated VMs and then failed
  # somewhere between Phase 2 and post-success convergence. Proxmox
  # purges destroyed VMIDs from the managed vzdump job during purge, so
  # the next no-change safe-apply must still reconcile that drift —
  # otherwise scheduled backups stay silently missing for restored
  # precious-state VMs. See #617 and RCA
  # docs/reports/2026-07-17-dev-precious-backup-jobs-missing-rca.md.
  #
  # Scope: only backup-job reconciliation runs here — NOT the full
  # run_post_success. The RCA's retry-scenario evidence is specifically
  # backup-job drift; running post-deploy.sh (Vault probes) and
  # configure-replication.sh (which tears down transient first-syncs)
  # on every steady-state safe-apply would introduce operational risk
  # and up to 5-minute Vault-unreachable hangs on legitimate no-change
  # invocations. See adversarial review findings on this MR.
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "(dry-run — not applying)"
    exit 0
  fi
  if [[ $NO_RECOVERY -eq 1 ]]; then
    echo "=== Skipping no-change backup-job reconciliation (--no-recovery) ==="
    exit 0
  fi
  echo ""
  echo "=== Backup-job reconciliation (no-change path) ==="
  set +e
  run_configure_backups
  NO_CHANGE_POST_RC=$?
  set -e
  exit "$NO_CHANGE_POST_RC"
fi

SAFE_APPLY_CONFIG="${REPO_DIR}/site/config.yaml"
SAFE_APPLY_APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
VM_CLASSES_JSON="$("${VM_SCOPE_SCRIPT}" classes --format json)"
export VM_CLASSES_JSON

# Resolve PIN_FILE once. restore-before-start.sh and failure recovery receive
# the same absolute path no matter where the operator invoked safe-apply from.
#
# Concurrent-run risk: two safe-apply.sh invocations for the same $ENV would
# race on this pin-file path AND on the shared tofu state (PostgreSQL backend
# on the NAS). The per-invocation tmpdir at SAFE_APPLY_TMPDIR isolates plan/
# categorize outputs, but the pin file and the tofu backend are NOT protected
# by this script — the backup pin is a well-known, env-scoped path and the
# tofu state is a single shared resource (Mycofu uses only the default
# workspace, so dev and prod share state and rely on branch/pipeline
# isolation rather than terraform.workspace to stay separate). Serialization
# is the operator's responsibility: the deploy:dev / deploy:prod jobs in
# .gitlab-ci.yml do NOT set `resource_group` today, so two overlapping
# deploy pipelines on the same env would race here. Do not launch a second
# safe-apply against the same env until the current one exits. See #63.
if [[ -z "${PIN_FILE:-}" ]]; then
  PIN_FILE_ABS="${REPO_DIR}/build/restore-pin-${ENV}.json"
elif [[ "${PIN_FILE}" == /* ]]; then
  PIN_FILE_ABS="${PIN_FILE}"
else
  PIN_FILE_ABS="${REPO_DIR}/${PIN_FILE}"
fi

PREBOOT_STATUS_FILE="${REPO_DIR}/build/preboot-restore-status-${ENV}.json"
INCOMPLETE_CONVERGENCE_RAN=0
RECOVERY_RESTORE_ALREADY_HANDLED=0
INCOMPLETE_CONVERGED_VMIDS=""

is_backup_backed_vmid() {
  local vmid="$1"
  "${SCRIPT_DIR}/list-backup-backed-vmids.sh" --format tsv "$ENV" \
    | awk -F '\t' '{print $1}' \
    | grep -Fxq "$vmid"
}

handle_incomplete_restore_rc2() {
  local pin_file="$1"
  local vmids vmid pin rc
  local failures=0

  if [[ ! -f "$PREBOOT_STATUS_FILE" ]]; then
    echo "ERROR: restore-before-start returned rc=2 but status file is missing: ${PREBOOT_STATUS_FILE}" >&2
    return 2
  fi

  vmids="$(jq -r '.entries[]? | select(.status == "incomplete") | .vmid' "$PREBOOT_STATUS_FILE" | sort -n -u)"
  if [[ -z "$vmids" ]]; then
    echo "ERROR: restore-before-start returned rc=2 but no incomplete VMIDs were recorded" >&2
    return 2
  fi

  while IFS= read -r vmid; do
    [[ -z "$vmid" ]] && continue
    if ! is_backup_backed_vmid "$vmid"; then
      echo "VM ${vmid} is incomplete; non-precious VM needs full recreate because vdb-only restore cannot repair missing boot topology. Recover with \`qmrestore <exact-pin> ${vmid} --force\` (whole-VM; requires operator approval per .claude/rules/destructive-operations.md) and re-run the pipeline." >&2
      failures=$((failures + 1))
      continue
    fi

    pin=""
    if [[ -f "$pin_file" ]]; then
      pin="$(jq -r --arg vmid "$vmid" '(.pins[$vmid] // "") | if type == "object" then (.volid // "") else . end' "$pin_file")"
    fi
    if [[ -z "$pin" ]]; then
      echo "VM ${vmid} is incomplete; no exact pin available in ${pin_file}. This needs full recreate because vdb-only restore cannot repair missing boot topology. Recover with \`qmrestore <exact-pin> ${vmid} --force\` (whole-VM; requires operator approval per .claude/rules/destructive-operations.md) and re-run the pipeline." >&2
      failures=$((failures + 1))
      continue
    fi

    set +e
    converge_incomplete_vm "$ENV" "$vmid" "$pin"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      echo "VM ${vmid} is incomplete; convergence failed: rc=${rc}. This needs full recreate because vdb-only restore cannot repair missing boot topology. Recover with \`qmrestore ${pin} ${vmid} --force\` (whole-VM; requires operator approval per .claude/rules/destructive-operations.md) and re-run the pipeline." >&2
      failures=$((failures + 1))
      continue
    fi
    INCOMPLETE_CONVERGENCE_RAN=1
    INCOMPLETE_CONVERGED_VMIDS="${INCOMPLETE_CONVERGED_VMIDS}${vmid}"$'\n'
    echo "VM ${vmid}: incomplete topology converged from exact pin ${pin}"
  done <<< "$vmids"

  [[ "$failures" -eq 0 ]]
}

vmid_was_converged() {
  local vmid="$1"
  grep -Fxq "$vmid" <<< "$INCOMPLETE_CONVERGED_VMIDS"
}

recovery_status_safe_for_phase2() {
  local vmid label status
  local unsafe=0

  if [[ ! -f "$PREBOOT_STATUS_FILE" ]]; then
    echo "ERROR: recovery status file is missing: ${PREBOOT_STATUS_FILE}" >&2
    return 1
  fi

  while IFS=$'\t' read -r vmid label status; do
    [[ -z "$vmid" ]] && continue
    case "$status" in
      restored|first-deploy-empty|spared)
        ;;
      incomplete)
        if ! vmid_was_converged "$vmid"; then
          echo "ERROR: recovery status for ${label} (VMID ${vmid}) is incomplete but this VMID was not converged; refusing Phase 2." >&2
          unsafe=$((unsafe + 1))
        fi
        ;;
      *)
        echo "ERROR: recovery status for ${label} (VMID ${vmid}) is ${status}; refusing Phase 2 after Phase 1 failure." >&2
        unsafe=$((unsafe + 1))
        ;;
    esac
  done < <(jq -r '.entries[]? | [.vmid, .label, .status] | @tsv' "$PREBOOT_STATUS_FILE")

  [[ "$unsafe" -eq 0 ]]
}

build_preboot_restore_manifest() {
  DEPLOY_ENV="$ENV" \
  PLAN_JSON="$PLAN_JSON" \
  MANIFEST_OUT="$PREBOOT_MANIFEST" \
  CONFIG_FILE="$SAFE_APPLY_CONFIG" \
  APPS_CONFIG_FILE="$SAFE_APPLY_APPS_CONFIG" \
  PIN_FILE_ABS="$PIN_FILE_ABS" \
  VM_CLASSES_JSON="$VM_CLASSES_JSON" \
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


def expected_disks(change):
    after = change.get("after") or {}
    disks = set()
    for disk in after.get("disk") or []:
        if isinstance(disk, dict):
            interface = disk.get("interface")
            if isinstance(interface, str) and interface:
                disks.add(interface)
    for cdrom in after.get("cdrom") or []:
        if isinstance(cdrom, dict):
            interface = cdrom.get("interface") or "ide2"
            if isinstance(interface, str) and interface:
                disks.add(interface)
    initialization = after.get("initialization")
    if initialization not in (None, [], {}):
        disks.add("ide2")
    return sorted(disks)


def data_disk_info(change):
    after = change.get("after") or {}
    for disk in after.get("disk") or []:
        if not isinstance(disk, dict):
            continue
        if disk.get("interface") != "scsi1":
            continue
        info = {"data_disk_slot": "scsi1"}
        size = disk.get("size")
        if size not in (None, "", "null"):
            text = str(size)
            if text.endswith(("G", "g")):
                text = text[:-1]
            info["data_disk_size_gb"] = text
        return info
    return {}


def label_env(label):
    if label.endswith("_dev"):
        return "dev"
    if label.endswith("_prod"):
        return "prod"
    return "shared"


def normalize_label(label):
    return label.replace("-", "_")


def resolve_class(label, classes):
    norm = normalize_label(label)
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


def backup_kind(label, classes):
    key = resolve_class(label, classes)
    if key is None:
        print(f"ERROR: backup VM class '{label}' is not declared in vm-scope manifests", file=sys.stderr)
        sys.exit(1)
    if classes[key].get("control_plane") is True:
        return "control-plane"
    return "infrastructure"


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
classes = json.loads(os.environ["VM_CLASSES_JSON"])

backups = {}
for label, vm in (config.get("vms") or {}).items():
    if isinstance(vm, dict) and vm.get("backup") is True:
        kind = backup_kind(label, classes)
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
    entry["expected_disks"] = expected_disks(change)
    entry.update(data_disk_info(change))
    pin = pins.get(str(entry["vmid"]))
    if pin:
        if isinstance(pin, dict):
            entry["pin"] = pin.get("volid", "")
            entry["pin_trust"] = pin.get("trust", "unknown")
        else:
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
  echo ""
  echo "=== VDB park bridge dry-run preview ==="
  VDB_PARK_PIN_FILE="$PIN_FILE_ABS" vdb_park_preview_batch "$PREBOOT_MANIFEST" "$ENV"
  echo ""
  echo "(dry-run — not applying)"
  exit 0
fi

# --- Image presence precondition ---
# Fail before HA cleanup, stopped apply, or any other state-changing action if
# the plan references an image missing from any target node.
echo ""
echo "=== Plan image presence precondition ==="
"${SCRIPT_DIR}/check-plan-images-present.sh" --plan-json "$PLAN_JSON"

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

echo ""
echo "=== VDB park bridge (pre-destroy) ==="
VDB_PARK_PIN_FILE="$PIN_FILE_ABS" vdb_park_batch "$PREBOOT_MANIFEST" "$PARK_STATUS_FILE" "$ENV"

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
  echo "    Park status file: ${PARK_STATUS_FILE}"

  if [[ -f "$PARK_STATUS_FILE" ]]; then
    echo ""
    echo "--- vdb_adopt_batch ${ENV} --recovery-mode ---"
    vdb_adopt_batch "$PARK_STATUS_FILE" --recovery-mode --manifest "$PREBOOT_MANIFEST" || true
  fi

  echo ""
  echo "--- restore-before-start.sh ${ENV} --recovery-mode ---"
  local restore_rc=0
  "${SCRIPT_DIR}/restore-before-start.sh" "$ENV" \
    --manifest "$PREBOOT_MANIFEST" \
    --pin-file "$PIN_FILE_ABS" \
    --park-status "$PARK_STATUS_FILE" \
    --recovery-mode || restore_rc=$?
  if [[ $restore_rc -ne 0 ]]; then
    echo ""
    if [[ $restore_rc -eq 2 ]]; then
      echo "ERROR: restore-before-start.sh --recovery-mode found incomplete VM topology (rc=2)"
      if handle_incomplete_restore_rc2 "$PIN_FILE_ABS"; then
        echo "Incomplete VM convergence succeeded during recovery."
        return 0
      fi
      echo "ERROR: incomplete VM convergence failed during recovery."
      return 2
    fi
    echo "ERROR: restore-before-start.sh --recovery-mode failed (rc=$restore_rc)"
    return $restore_rc
  fi

  return 0
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
  echo "and post-deploy will be skipped unless bounded convergence"
  echo "successfully repairs incomplete topology."
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
  elif [[ "$INCOMPLETE_CONVERGENCE_RAN" -eq 1 ]]; then
    echo ""
    if recovery_status_safe_for_phase2; then
      echo "Recovery converged incomplete VM(s) after Phase 1 failure; skipping duplicate restore and continuing to Phase 2."
      PHASE1_RC=0
      RECOVERY_RESTORE_ALREADY_HANDLED=1
    else
      echo "Recovery converged at least one incomplete VM, but the recovery manifest still has entries that are not safe for Phase 2." >&2
      echo "Keeping original Phase 1 apply failure rc=${PHASE1_RC}." >&2
    fi
  fi
  if [[ "$PHASE1_RC" -ne 0 ]]; then
    exit $PHASE1_RC
  fi
fi

echo ""
echo "=== VDB park bridge adopt (${ENV}) ==="
ADOPT_RC=0
set +e
vdb_adopt_batch "$PARK_STATUS_FILE"
ADOPT_RC=$?
set -e
if [[ "$ADOPT_RC" -ne 0 ]]; then
  echo "WARNING: vdb_adopt_batch returned rc=${ADOPT_RC}; continuing to restore-before-start.sh so failed entries can use the pinned PBS fallback." >&2
fi

if [[ "$RECOVERY_RESTORE_ALREADY_HANDLED" -eq 1 ]]; then
  echo ""
  echo "=== Restore before start (${ENV}) skipped ==="
  echo "Recovery-mode restore/convergence already processed this manifest."
  RESTORE_RC=0
else
  echo ""
  echo "=== Restore before start (${ENV}) ==="
  set +e
  "${SCRIPT_DIR}/restore-before-start.sh" "$ENV" \
    --manifest "$PREBOOT_MANIFEST" \
    --pin-file "$PIN_FILE_ABS" \
    --park-status "$PARK_STATUS_FILE"
  RESTORE_RC=$?
  set -e
fi

if [[ $RESTORE_RC -ne 0 ]]; then
  echo ""
  if [[ $RESTORE_RC -eq 2 ]]; then
    echo "=================================================="
    echo "ERROR: restore-before-start.sh found incomplete VM topology (rc=2)"
    echo "Attempting bounded convergence for incomplete precious VM(s)."
    echo "=================================================="
    if handle_incomplete_restore_rc2 "$PIN_FILE_ABS"; then
      echo "Incomplete VM convergence succeeded; continuing to phase 2."
    else
      echo "Incomplete VM convergence failed; skipping phase 2."
      exit 2
    fi
  else
  echo "=================================================="
  echo "ERROR: restore-before-start.sh failed (rc=$RESTORE_RC)"
  echo "Skipping phase 2: one or more vdb restores failed."
  echo "Skipping post-deploy.sh, configure-backups.sh, and configure-replication.sh."
  echo "=================================================="
  exit $RESTORE_RC
  fi
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
