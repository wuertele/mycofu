#!/usr/bin/env bash
# migrate-snippet-state.sh — Rename snippet resources in OpenTofu state
# after converting from single-node to for_each (all-node) deployment.
#
# Run ONCE before the first `tofu apply` after the HA snippet fix.
# Must be run from site/tofu/ with tofu-wrapper.sh env vars set.
#
# Usage: cd site/tofu && source <(../../framework/scripts/tofu-wrapper.sh env) or
#        just run the state mv commands below manually.

set -euo pipefail

# State addresses and their target_node (the node that currently owns the snippet).
# Format: "state_address target_node"
MOVES=(
  "module.dns_prod.module.dns1 pve01"
  "module.dns_prod.module.dns2 pve02"
  "module.dns_dev.module.dns1 pve01"
  "module.dns_dev.module.dns2 pve02"
  "module.vault_prod.module.vault pve03"
  "module.vault_dev.module.vault pve03"
  "module.acme_dev.module.acme_dev pve03"
  "module.gitlab.module.gitlab pve03"
  "module.cicd.module.cicd pve01"
  "module.gatus.module.gatus pve02"
  "module.testapp_dev.module.testapp pve02"
  "module.testapp_prod.module.testapp pve02"
)

RESOURCES=("proxmox_virtual_environment_file.user_data" "proxmox_virtual_environment_file.meta_data")

echo "=== Snippet state migration ==="
echo "Moving non-indexed snippet resources to for_each index keys."
echo ""

ERRORS=0
for entry in "${MOVES[@]}"; do
  mod="${entry% *}"
  node="${entry#* }"
  for res in "${RESOURCES[@]}"; do
    from="${mod}.${res}"
    to="${mod}.${res}[\"${node}\"]"
    echo "  ${from} -> [\"${node}\"]"
    if ! tofu state mv "$from" "$to" 2>&1; then
      echo "  WARNING: failed (may already be migrated)"
      ((ERRORS++)) || true
    fi
  done
done

echo ""
if [[ $ERRORS -gt 0 ]]; then
  echo "Completed with $ERRORS warnings."
else
  echo "All 24 resources migrated successfully."
fi
echo "Next: run 'tofu plan' to verify no VM recreation, then 'tofu apply'."
