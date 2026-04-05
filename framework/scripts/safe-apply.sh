#!/usr/bin/env bash
# safe-apply.sh — Plan, guard control-plane, apply only the target environment.
#
# Usage:
#   safe-apply.sh dev             # deploy dev data-plane VMs
#   safe-apply.sh prod            # deploy prod data-plane VMs
#   safe-apply.sh dev --dry-run   # show categorization without applying
#
# The script:
#   1. Checks for control-plane image drift (informational warning)
#   2. Runs tofu plan (excluding control-plane modules)
#   3. Exports plan to JSON
#   4. Categorizes every change by environment
#   5. Applies only data-plane modules belonging to the specified environment
#
# Module categorization (by naming convention):
#   Control-plane:  module.gitlab, module.cicd, module.pbs → workstation only
#   Dev data-plane: module.*_dev, module.acme_dev          → deploy:dev
#   Prod data-plane: module.*_prod, module.gatus           → deploy:prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
ENV="${1:-}"
DRY_RUN=0
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "Usage: $(basename "$0") <dev|prod> [--dry-run]" >&2
  exit 1
fi

# --- Temp files with cleanup ---
PLAN_OUT="/tmp/safe-apply-plan.out"
PLAN_JSON="/tmp/safe-apply-plan.json"
CATEGORIZE_OUT="/tmp/safe-apply-categorize.out"
cleanup() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    echo "safe-apply.sh failed at line ${BASH_LINENO[0]} with exit code $exit_code" >&2
  fi
  rm -f "$PLAN_OUT" "$PLAN_JSON" "$CATEGORIZE_OUT" /tmp/safe-apply-show-raw.out
}
trap cleanup EXIT

# --- Check for control-plane image drift (informational, non-fatal) ---
# Uses check-control-plane-drift.sh (nix-eval based, no build artifacts needed).
# Only detects image drift, not CIDATA drift. CIDATA drift is caught by R7.2
# in validate.sh after deploy. This warning helps the operator see image drift
# early, but does not block the data-plane deploy.
echo ""
echo "=== Checking control-plane image drift ==="
set +e
"${SCRIPT_DIR}/check-control-plane-drift.sh" 2>&1
CP_DRIFT_EXIT=$?
set -e

if [[ $CP_DRIFT_EXIT -eq 1 ]]; then
  echo ""
  echo "=================================================="
  echo "WARNING: Control-plane image drift detected"
  echo "=================================================="
  echo ""
  echo "  The data-plane deploy will proceed, but control-plane VMs"
  echo "  need manual deployment from the workstation."
  echo ""
  echo "  After this deploy completes:"
  echo "    1. Run: framework/scripts/backup-now.sh"
  echo "       Verify: exits 0, check backup sizes in output"
  echo "    2. Run: git checkout prod && framework/scripts/rebuild-cluster.sh --scope control-plane"
  echo "       Verify: exits 0, validate.sh passes"
  echo "    3. If cicd was rebuilt: framework/scripts/register-runner.sh"
  echo "       Verify: runner shows online in GitLab"
  echo ""
  echo "  Use --override-branch-check only for true disaster recovery."
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
SHOW_RAW="/tmp/safe-apply-show-raw.out"
tofu -chdir="${SCRIPT_DIR}/../tofu/root" show -json "$PLAN_OUT" > "$SHOW_RAW"
python3 -c "
import sys
with open('$SHOW_RAW') as f:
    d = f.read()
i = d.find('{')
if i < 0:
    print('ERROR: No JSON object in tofu show output', file=sys.stderr)
    print('Output was:', d[:500], file=sys.stderr)
    sys.exit(1)
with open('$PLAN_JSON', 'w') as f:
    f.write(d[i:])
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

echo ""
echo "=== Deploying ${ENV} modules ==="
echo "Targets:${TARGETS}"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
  echo "(dry-run — not applying)"
  exit 0
fi

# HA double-apply: when VMs are recreated, the HA resource is removed by Proxmox.
# The first apply creates VMs but can't create HA resources (VM must exist first).
# The second apply picks up the missing HA resources. Always run both — the first
# apply succeeds (VMs created) without error, so checking exit code is insufficient.
# Refresh state before apply to detect resources deleted outside of tofu.
# The bpg provider's HA resource Read function doesn't detect missing
# resources during plan-time refresh, but explicit refresh does. Without
# this, a missing HA resource causes "Error updating HA resource: no such
# resource" because tofu plans UPDATE instead of CREATE.
# See: report-ha-resource-state-drift-retrospective.md
echo ""
echo "=== Refreshing state (detect out-of-band changes) ==="
"${SCRIPT_DIR}/tofu-wrapper.sh" refresh ${TARGETS}

# Note: -target and -exclude are mutually exclusive in OpenTofu.
# The plan uses -exclude (to avoid prevent_destroy). The apply uses -target
# (from the categorizer, which already excludes control-plane modules).
# -exclude on apply is not needed — -target already constrains the scope.
"${SCRIPT_DIR}/tofu-wrapper.sh" apply ${TARGETS} -auto-approve

echo ""
echo "=== Second apply (HA resources) ==="
"${SCRIPT_DIR}/tofu-wrapper.sh" apply ${TARGETS} -auto-approve

echo ""
echo "=== Third apply (HA resource attribute convergence) ==="
# The bpg Proxmox provider's CREATE for proxmox_virtual_environment_haresource
# only sends the 'state' field. Optional attributes (comment, max_relocate,
# max_restart) are not included in the CREATE payload and require a subsequent
# UPDATE pass to be set. This third apply is that UPDATE pass.
# It is a no-op when no VMs were recreated (no HA resources were newly created).
# See: https://github.com/bpg/terraform-provider-proxmox (HA resource CREATE behavior)
"${SCRIPT_DIR}/tofu-wrapper.sh" apply ${TARGETS} -auto-approve
