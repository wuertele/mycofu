#!/usr/bin/env bash
# DRT-ID: DRT-002
# DRT-NAME: Cold Rebuild
# DRT-TIME: ~50 min
# DRT-DESTRUCTIVE: yes
# DRT-DESC: Simulate a full cold-start rebuild from a fresh clone. Clones
#           the repo to a temp directory, runs new-site.sh + rebuild-cluster.sh
#           to verify the framework can bootstrap from scratch.

set -euo pipefail

DRT_ID="DRT-002"
DRT_NAME="Cold Rebuild"

source "$(dirname "$0")/../lib/common.sh"

drt_init

TEMP_CLONE=""

# ── Preconditions ────────────────────────────────────────────────────

drt_check "git tree is clean" git diff --quiet HEAD

drt_check "nix builder is configured" \
  test -f framework/scripts/setup-nix-builder.sh

drt_check "PBS is reachable" \
  ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "root@$(drt_vm_ip pbs)" "true"

drt_check "operator.age.key exists in repo root" \
  test -f operator.age.key

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

drt_step "Cloning repo to temp directory"
# TODO: automate this — in a real cold start the operator clones from GitLab
TEMP_CLONE=$(mktemp -d)
echo "  Temp clone: ${TEMP_CLONE}"
drt_assert "git clone succeeds" \
  git clone "$(pwd)" "${TEMP_CLONE}/home-infrastructure"

drt_step "Copying operator.age.key to temp clone"
# TODO: automate this — in a real cold start the operator copies from secure storage
# The key lives in the repo root, NOT in ~/.sops/
drt_assert "operator.age.key copied" \
  cp operator.age.key "${TEMP_CLONE}/home-infrastructure/operator.age.key"

drt_step "Running new-site.sh from temp clone"
echo "  (Simulates a fresh operator bootstrapping a new site)"
# new-site.sh is idempotent — it will skip if site/config.yaml exists
# Since we cloned the full repo, site/ already has config.yaml
# In a real cold start, the operator would have a bare framework clone
echo "  Note: site/ already exists in the clone — new-site.sh will skip."
echo "  This test validates rebuild-cluster.sh from a clean checkout."

drt_step "Running rebuild-cluster.sh from temp clone"
echo "  Using --override-branch-check: DR tests are disaster recovery scenarios."
REBUILD_START=$(date +%s)
drt_assert "rebuild-cluster.sh completes successfully" \
  bash -c "cd '${TEMP_CLONE}/home-infrastructure' && framework/scripts/rebuild-cluster.sh --override-branch-check"
REBUILD_END=$(date +%s)
REBUILD_ELAPSED=$(( REBUILD_END - REBUILD_START ))
printf "  Rebuild took: %dm %ds\n" $((REBUILD_ELAPSED / 60)) $((REBUILD_ELAPSED % 60))

# ── Verification ─────────────────────────────────────────────────────

drt_step "Validating deploy manifest"
MANIFEST="${TEMP_CLONE}/home-infrastructure/build/rebuild-manifest.json"
drt_assert "rebuild-manifest.json exists" test -s "$MANIFEST"
if [[ -s "$MANIFEST" ]]; then
  drt_assert "manifest has override_branch_check=true" \
    bash -c "jq -e '.override_branch_check == true' '$MANIFEST' >/dev/null"
  drt_assert "manifest has non-empty commit" \
    bash -c "jq -e '.commit != \"\" and .commit != null' '$MANIFEST' >/dev/null"
  drt_assert "manifest has impact field" \
    bash -c "jq -e '.impact != \"\" and .impact != null' '$MANIFEST' >/dev/null"
fi

drt_step "Running validate.sh (from original repo)"
drt_assert "validate.sh passes after cold rebuild" framework/scripts/validate.sh

drt_step "Checking pipeline health"
drt_expect "Pipeline is green on first push after cold rebuild (check GitLab UI)"

drt_step "Checking elapsed time"
TOTAL_END=$(date +%s)
TOTAL_ELAPSED=$(( TOTAL_END - DRT_START_EPOCH ))
TOTAL_MINUTES=$(( TOTAL_ELAPSED / 60 ))
printf "  Total elapsed: %dm %ds\n" $((TOTAL_ELAPSED / 60)) $((TOTAL_ELAPSED % 60))
echo "  Baseline: 47m (2026-03-25)"
if [[ $TOTAL_MINUTES -gt 60 ]]; then
  echo "[WARN] Elapsed time exceeds 60 min threshold — investigate slowdown"
fi

# ── Cleanup ──────────────────────────────────────────────────────────

drt_step "Cleaning up temp clone"
if [[ -n "$TEMP_CLONE" && -d "$TEMP_CLONE" ]]; then
  rm -rf "$TEMP_CLONE"
  echo "  Removed: ${TEMP_CLONE}"
fi

echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ MANUAL STEP: If site/ was modified during cold rebuild,     │"
echo "  │ restore it from GitLab:                                     │"
echo "  │   git checkout dev -- site/                                 │"
echo "  │ Or pull from GitLab remote to ensure site/ is current.      │"
echo "  └─────────────────────────────────────────────────────────────┘"

# ── Finish ───────────────────────────────────────────────────────────

drt_finish
