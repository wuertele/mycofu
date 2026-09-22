#!/usr/bin/env bash
# DRT-ID: DRT-001
# DRT-NAME: Warm Rebuild
# DRT-TIME: ~35 min
# DRT-DESTRUCTIVE: yes
# DRT-DESC: Validate the rebuild path from the current (warm) checkout.
#           VMs are replaced only where the plan drifts; replacements are
#           recorded. Forced recreation coverage belongs to DRT-010.

set -euo pipefail

DRT_ID="DRT-001"
DRT_NAME="Warm Rebuild"

source "$(dirname "$0")/../lib/common.sh"

drt_init

# ── Preconditions ────────────────────────────────────────────────────

drt_check "validate.sh is green" framework/scripts/validate.sh

drt_check "git tree is clean" git diff --quiet HEAD

drt_check "PBS is reachable" \
  ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "root@$(drt_vm_ip pbs)" "true"

drt_check "backup-now.sh exists" test -x framework/scripts/backup-now.sh

# ── Pre-test ─────────────────────────────────────────────────────────

drt_step "Capturing pre-test state fingerprint"
drt_fingerprint_state

drt_step "Taking pre-test backup of all precious VMs"
drt_assert "backup-now.sh succeeds" framework/scripts/backup-now.sh
if [[ $DRT_FAILURES -gt 0 ]]; then
  echo ""
  echo "ABORT: Pre-test backup failed — cannot proceed with destructive test."
  echo "       Fix backup-now.sh and re-run."
  drt_finish
fi

# ── Test ─────────────────────────────────────────────────────────────

drt_step "Running rebuild-cluster.sh (full warm rebuild)"
echo "  This runs the rebuild path from the current checkout; replacements are drift-driven."
echo "  Precious state is preserved by park/adopt or PBS restore when VMs are replaced."
echo "  Replacements are recorded; forced recreation coverage is DRT-010."
echo "  Using --override-branch-check: DR tests are disaster recovery scenarios."
echo ""

REBUILD_START=$(date +%s)
drt_assert "rebuild-cluster.sh completes successfully" \
  framework/scripts/rebuild-cluster.sh --override-branch-check
REBUILD_END=$(date +%s)
REBUILD_ELAPSED=$(( REBUILD_END - REBUILD_START ))
drt_record_plan_replacements build/preboot-restore-plan-bulk.json
printf "  Rebuild took: %dm %ds\n" $((REBUILD_ELAPSED / 60)) $((REBUILD_ELAPSED % 60))

# ── Verification ─────────────────────────────────────────────────────

drt_step "Validating deploy manifest"
MANIFEST="build/rebuild-manifest.json"
drt_assert "rebuild-manifest.json exists" test -s "$MANIFEST"
if [[ -s "$MANIFEST" ]]; then
  drt_assert "manifest has override_branch_check=true" \
    bash -c "jq -e '.override_branch_check == true' '$MANIFEST' >/dev/null"
  drt_assert "manifest has non-empty commit" \
    bash -c "jq -e '.commit != \"\" and .commit != null' '$MANIFEST' >/dev/null"
  drt_assert "manifest has impact field" \
    bash -c "jq -e '.impact != \"\" and .impact != null' '$MANIFEST' >/dev/null"
fi

drt_step "Running validate.sh"
drt_assert "validate.sh passes after rebuild" framework/scripts/validate.sh

drt_step "Verifying state fingerprint"
drt_verify_state_fingerprint

drt_step "Checking elapsed time"
TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$(( TOTAL_END - DRT_START_EPOCH ))
TOTAL_MINUTES=$(( TOTAL_ELAPSED / 60 ))
printf "  Total elapsed: %dm %ds\n" $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
echo "  Baseline: 29m 49s (2026-03-23)"
if [[ $TOTAL_MINUTES -gt 45 ]]; then
  echo "[WARN] Elapsed time exceeds 45 min threshold — investigate slowdown"
fi

# ── Finish ───────────────────────────────────────────────────────────

drt_finish
