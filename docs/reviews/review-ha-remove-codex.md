# MR !141 Review: remove optional HA attributes to eliminate perpetual drift

Verdict: ISSUES_FOUND

## Findings

1. Blocking: `module.pbs` still hardcodes the removed HA attributes.
   - `framework/tofu/modules/pbs/main.tf:85-92` still sets `comment`, `max_restart`, and `max_relocate` on `proxmox_virtual_environment_haresource.ha`.
   - `framework/scripts/rebuild-cluster.sh:64` keeps `module.pbs` in `CONTROL_PLANE_MODULES`, and the PBS recreate path still runs `tofu apply -target=module.pbs` at `framework/scripts/rebuild-cluster.sh:1089`.
   - Result: the repo still has an active HA code path that expects the removed optional attributes. The MR fixes `framework/tofu/modules/proxmox-vm/ha.tf` and its two symlinks, but it does not eliminate HA attribute drift repo-wide.

## Verified

- `framework/tofu/modules/proxmox-vm/ha.tf:3-9` now contains only `resource_id` and `state`.
- `framework/tofu/modules/proxmox-vm-precious/ha.tf` and `framework/tofu/modules/proxmox-vm-field-updatable/ha.tf` are symlinks to `../proxmox-vm/ha.tf`.
- No repo-local `reconcile_ha_resources` references remain in runtime code or tests. Runtime uses `verify_ha_resources` only: `framework/scripts/safe-apply.sh:216,341,359` and `framework/scripts/rebuild-cluster.sh:605,729,930,988`.
- No repo-local `pvesh set /cluster/ha/resources...` HA settlement calls remain under `framework/`, `tests/`, or `site/`.
- `verify_ha_resources` still performs Phase 1 stale-state removal and Phase 1b orphan removal in both scripts: `framework/scripts/safe-apply.sh:260-324` and `framework/scripts/rebuild-cluster.sh:650-717`.
- Remaining HA flow tests pass:
  - `bash tests/test_safe_apply_ha_flow.sh`
  - `bash tests/test_rebuild_ha_flow.sh`

## Caller Audit

- No repo-local caller still depends on the old `reconcile_ha_resources` name.
- The passing HA flow tests do not exercise `framework/tofu/modules/pbs/main.tf`, so they would not catch the PBS holdout above.
