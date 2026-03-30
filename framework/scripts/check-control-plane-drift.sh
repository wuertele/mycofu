#!/usr/bin/env bash
# check-control-plane-drift.sh — MR guard for prod promotions.
#
# Compares nix derivation hashes for control-plane (Tier 2) images against
# what's currently deployed in tofu state. If they differ, the operator
# must deploy control-plane VMs from the workstation before merging to prod.
#
# The pipeline cannot deploy control-plane VMs (it runs on them), so merging
# to prod with stale control-plane images means those VMs silently miss the
# update. This guard prevents that.
#
# Usage:
#   framework/scripts/check-control-plane-drift.sh
#
# Exit codes:
#   0 — control-plane images match deployed state (safe to merge)
#   1 — drift detected (deploy control-plane first, then retry)
#   2 — check could not be performed (missing prerequisites)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WRAPPER="${SCRIPT_DIR}/tofu-wrapper.sh"

cd "$REPO_DIR"

# --- Prerequisites ---
if [[ ! -f "$WRAPPER" ]]; then
  echo "ERROR: tofu-wrapper.sh not found" >&2
  exit 2
fi

# Initialize tofu (needed for state queries)
if ! "$WRAPPER" init -input=false >/dev/null 2>&1; then
  echo "ERROR: tofu init failed — cannot check state" >&2
  exit 2
fi

echo "=== Checking control-plane image drift ==="
echo ""

# Control-plane roles: nix-built Tier 2 VMs that the pipeline cannot deploy.
# PBS is a vendor appliance (not nix-built) and is excluded from this check.
ROLES="gitlab cicd"

DRIFT=0
DRIFT_ROLES=""

for role in $ROLES; do
  # Get expected hash from nix evaluation (fast, no build needed).
  # nix eval prints a quoted string: "/nix/store/knq2y5q3...-nixos-disk-image"
  out_path=$(nix eval ".#packages.x86_64-linux.${role}-image.outPath" 2>/dev/null || echo "")
  if [[ -z "$out_path" ]]; then
    echo "  ${role}: SKIP (nix eval failed — flake output may not exist)"
    continue
  fi
  # Strip quotes, extract first 8 chars of the store path basename
  clean_path=$(echo "$out_path" | tr -d '"')
  expected_hash=$(basename "$clean_path" | cut -c1-8)

  # Get deployed hash from tofu state.
  # The resource address follows the proxmox-vm module convention.
  state_output=$("$WRAPPER" state show "module.${role}.module.${role}.proxmox_virtual_environment_vm.vm" 2>/dev/null || echo "")
  deployed_file=$(echo "$state_output" | grep "file_id" | grep "iso/" | head -1 | grep -o "${role}-[a-z0-9]*\.img" || echo "")
  deployed_hash=$(echo "$deployed_file" | sed "s/^${role}-//;s/\.img$//" || echo "")

  if [[ -z "$deployed_hash" ]]; then
    echo "  ${role}: NOT DEPLOYED (expected ${expected_hash})"
    DRIFT=1
    DRIFT_ROLES="${DRIFT_ROLES} ${role}"
  elif [[ "$expected_hash" != "$deployed_hash" ]]; then
    echo "  ${role}: DRIFT (deployed=${deployed_hash}, code=${expected_hash})"
    DRIFT=1
    DRIFT_ROLES="${DRIFT_ROLES} ${role}"
  else
    echo "  ${role}: OK (${expected_hash})"
  fi
done

echo ""

if [[ $DRIFT -eq 1 ]]; then
  echo "=================================================="
  echo "BLOCKED: Control-plane images need manual deploy"
  echo "=================================================="
  echo ""
  echo "These are control-plane VMs with stateful data (GitLab database,"
  echo "git repos, CI history). The pipeline cannot deploy them."
  echo ""
  echo "  Deploy from the workstation:"
  echo "     framework/scripts/rebuild-cluster.sh --scope control-plane"
  echo ""
  echo "  Then retry this CI job to verify the drift is resolved."
  echo ""
  echo "DO NOT run 'tofu apply' directly on control-plane modules."
  echo ""
  exit 1
fi

echo "Control-plane images match deployed state — safe to merge."
