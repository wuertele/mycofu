# Review: MR !141 -- Remove optional HA attributes to eliminate perpetual drift

**Verdict: ISSUES_FOUND**

## Checklist Results

### 1. ha.tf only has resource_id and state -- PASS

`framework/tofu/modules/proxmox-vm/ha.tf` contains only `resource_id` and
`state`. No `comment`, `max_restart`, or `max_relocate`. Both symlinks
(`proxmox-vm-precious/ha.tf` and `proxmox-vm-field-updatable/ha.tf`) point
to the same file.

### 2. All references to reconcile_ha_resources renamed to verify_ha_resources -- PASS

- `framework/scripts/safe-apply.sh`: function defined as `verify_ha_resources` (line 216), called at lines 341 and 359.
- `framework/scripts/rebuild-cluster.sh`: function defined as `verify_ha_resources` (line 605), called at lines 729, 930, and 988.
- `tests/test_safe_apply_ha_flow.sh`: references `verify_ha_resources` in comments (lines 86, 95). No references to `reconcile_ha_resources`.
- `tests/test_rebuild_ha_flow.sh`: no references to either function name (tests the script end-to-end via shims).
- `framework/` and `tests/` directories: zero grep hits for `reconcile_ha_resources`.
- `docs/` directory: contains historical references to `reconcile_ha_resources` in prior review files and reports. These are historical records and do not need updating.

### 3. No remaining pvesh set calls for HA attributes -- PASS

No `pvesh set` calls for HA attributes remain in `framework/scripts/` or
`tests/`. All remaining `pvesh set` references are in `docs/` (historical
reports, reviews, sprint documents, and prompts).

### 4. No remaining references to "Managed by OpenTofu" comment in HA context -- ISSUES FOUND

**`framework/tofu/modules/pbs/main.tf` (line 90)** still contains:

```hcl
comment      = "Managed by OpenTofu"
max_restart  = 3
max_relocate = 2
```

The PBS module has its own inline `proxmox_virtual_environment_haresource`
resource (not using the symlinked `ha.tf`). This resource was NOT updated
by the MR. It still declares all three optional attributes that cause
perpetual drift.

This means the PBS HA resource will continue to experience the same
drift cycle that this MR is intended to fix for all other VMs.

### 5. verify_ha_resources still does Phase 1 and Phase 1b correctly -- PASS

Both copies (safe-apply.sh lines 216-333 and rebuild-cluster.sh lines
605-726) contain:

- **Phase 1** (stale state removal): iterates HA resources in tofu state,
  queries Proxmox, removes state entries for resources not in Proxmox.
- **Phase 1b** (orphan removal from #190): iterates Proxmox HA resources,
  removes those not in tofu state. Correctly guarded by
  `state_extract_failures` check -- skips Phase 1b if any state extraction
  failed.
- **Fail-closed on state list failure**: returns 1 if `tofu state list`
  exits non-zero.
- **Fail-closed on Proxmox query failure**: returns 1 if SSH query returns
  empty or null.

No Phase 2 (pvesh set) code remains. The function is correctly scoped to
verification and cleanup only.

### 6. Any callers using old function name reconcile_ha_resources -- PASS

Zero hits in `framework/` and `tests/`. All callers use `verify_ha_resources`.

### 7. Other scripts sourcing safe-apply.sh or rebuild-cluster.sh -- PASS

No script sources `safe-apply.sh`. `rebuild-cluster.sh` sources
`converge-lib.sh` and `git-deploy-context.sh` (not the other direction).
No external dependency on the function name.

### 8. Any test referencing old function name or removed attributes -- PASS

`tests/test_safe_apply_ha_flow.sh` and `tests/test_rebuild_ha_flow.sh`
contain no references to `reconcile_ha_resources`, `max_restart`,
`max_relocate`, or `"Managed by OpenTofu"`. The tests verify the two-apply
flow and target selection, not HA attribute values.

## Issue Summary

| # | Severity | File | Description |
|---|----------|------|-------------|
| 1 | **HIGH** | `framework/tofu/modules/pbs/main.tf:90-92` | PBS module's inline HA resource still declares `comment`, `max_restart`, and `max_relocate`. Same perpetual drift bug remains for PBS. Must be updated to match the cleaned `ha.tf`. |

## Recommendation

Remove lines 90-92 from `framework/tofu/modules/pbs/main.tf` so the PBS
HA resource matches the pattern established by this MR (only `resource_id`
and `state`). Without this fix, the MR solves the drift problem for all
VMs except PBS.
