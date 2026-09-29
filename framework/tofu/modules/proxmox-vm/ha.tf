# --- HA resource (conditional) ---

resource "proxmox_virtual_environment_haresource" "ha" {
  count = var.ha_enabled && var.register_ha ? 1 : 0

  resource_id = "vm:${proxmox_virtual_environment_vm.vm.vm_id}"
  state       = "started"

  # Interim #691 damage limiter — see var.replication_policy_on for context.
  # Attribute-absent (null) preserves PVE defaults (max_restart=1, max_relocate=1)
  # so callers that leave this variable unset produce a ZERO plan diff on
  # existing haresources. Only policy-off callers explicitly clamp to 0.
  max_restart  = var.replication_policy_on == false ? 0 : null
  max_relocate = var.replication_policy_on == false ? 0 : null

  depends_on = [proxmox_virtual_environment_vm.vm]
}

# NOTE (Sprint 045 / #513, M1 ruling 2026-07-08): a per-VM node-affinity
# home-steering rule was prototyped here and DROPPED. The M1 live smoke showed
# PVE 9.1.1 honors node-affinity harules by actively migrating a running service
# to its preferred node (~30s). That auto-failback is a migrate-BACK executed
# OUTSIDE rebalance-cluster.sh — the exact rename-victim minting event, on the
# path the Phase-3 vaccine's pre-migrate sweep does NOT guard. Node-affinity here
# would structurally re-open the cidata collision hole this sprint closes. The
# DNS pair anti-affinity is a pair-level negative resource-affinity rule in the
# dns-pair module; home placement stays owned by config.yaml + rebalance-cluster.sh.
