#!/usr/bin/env bash
# safe-apply.sh — Plan, guard control-plane, apply only the target environment.
#
# Usage:
#   safe-apply.sh dev             # deploy dev data-plane VMs
#   safe-apply.sh prod            # deploy prod data-plane VMs
#   safe-apply.sh dev --dry-run   # show categorization without applying
#
# The script:
#   1. Runs tofu plan (all modules)
#   2. Exports plan to JSON
#   3. Categorizes every change by environment and protection status
#   4. Warns if control-plane modules have drift (skips them)
#   5. Applies only data-plane modules belonging to the specified environment
#
# Module categorization (by naming convention):
#   Control-plane:  module.gitlab, module.cicd, module.pbs → workstation only
#   Dev data-plane: module.*_dev, module.pebble            → deploy:dev
#   Prod data-plane: module.*_prod, module.gatus           → deploy:prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# --- Run tofu plan ---
echo "Planning all modules..."
"${SCRIPT_DIR}/tofu-wrapper.sh" plan -out="$PLAN_OUT" -no-color
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
set +e
DEPLOY_ENV="$ENV" python3 -c "
import sys, json, os, re

env = os.environ['DEPLOY_ENV']
PROTECTED = {'module.gitlab', 'module.cicd', 'module.pbs'}
DEV_EXTRAS = {'module.pebble'}
PROD_EXTRAS = {'module.gatus'}

with open('$PLAN_JSON') as f:
    plan = json.load(f)

control_plane_drift = []
deployable = []
skipped = []

for rc in plan.get('resource_changes', []):
    actions = rc.get('change', {}).get('actions', [])
    if actions == ['no-op'] or actions == ['read']:
        continue

    addr = rc.get('address', '')
    mod = '.'.join(addr.split('.')[:2]) if '.' in addr else addr
    # Strip count/for_each index (e.g., module.grafana_dev[0] → module.grafana_dev)
    mod = re.sub(r'\[.*\]$', '', mod)

    if mod in PROTECTED:
        if 'delete' in actions or 'create' in actions:
            control_plane_drift.append(f'  {addr}: {actions}')
        skipped.append(mod)
    elif mod.endswith(f'_{env}') or mod in (DEV_EXTRAS if env == 'dev' else PROD_EXTRAS):
        deployable.append(mod)
    else:
        if mod not in (DEV_EXTRAS | PROD_EXTRAS | PROTECTED):
            other_env = 'prod' if env == 'dev' else 'dev'
            if not mod.endswith(f'_{other_env}'):
                print(f'WARNING: module {mod} does not match any environment — skipping', file=sys.stderr)
        skipped.append(mod)

if control_plane_drift:
    print('CONTROL_PLANE_DRIFT')
    for d in control_plane_drift:
        print(d)

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

# --- Warn about control-plane drift (but don't block) ---
# The pipeline can't deploy control-plane VMs (it runs on them).
# The guard:control-plane CI job blocks prod MRs until drift is resolved.
if grep -q "^CONTROL_PLANE_DRIFT$" "$CATEGORIZE_OUT"; then
  echo ""
  echo "=================================================="
  echo "WARNING: Control-plane VMs need manual deployment"
  echo "=================================================="
  echo ""
  grep -v "^CONTROL_PLANE_DRIFT$" "$CATEGORIZE_OUT" | grep -v "^module\." | grep -v "^WARNING:" | grep -v "^$" || true
  echo ""
  echo "Deploy from the workstation when ready:"
  echo "  framework/scripts/rebuild-cluster.sh --scope control-plane"
  echo ""
  echo "DO NOT run 'tofu apply' directly on control-plane modules."
  echo ""
fi

# Extract -target flags from categorize output (skip non-module lines)
TARGETS=""
while IFS= read -r line; do
  [[ "$line" == WARNING:* ]] && echo "$line" >&2 && continue
  [[ "$line" == CONTROL_PLANE_DRIFT ]] && continue
  [[ "$line" == "  "* ]] && continue  # drift detail lines (indented)
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
"${SCRIPT_DIR}/tofu-wrapper.sh" apply ${TARGETS} -auto-approve

echo ""
echo "=== Second apply (HA resources) ==="
"${SCRIPT_DIR}/tofu-wrapper.sh" apply ${TARGETS} -auto-approve
