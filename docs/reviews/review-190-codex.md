# Review: Issue #190 -- reconcile_ha_resources orphan cleanup

**Verdict: ISSUES_FOUND**

**Reviewer:** Codex (adversarial review)
**Date:** 2026-04-13
**Files reviewed:**
- `framework/scripts/rebuild-cluster.sh` (`reconcile_ha_resources`: lines 605-729, atomic loop call: line 933)
- `framework/scripts/safe-apply.sh` (`reconcile_ha_resources`: lines 216-337)
- `.claude/rules/proxmox-tofu.md`
- `.claude/rules/destructive-operations.md`

## Findings

### 1. Blocking: the new Phase 1b never runs when state has zero HA resources

**Affected lines:** `framework/scripts/rebuild-cluster.sh:612-615`, `framework/scripts/safe-apply.sh:223-226`

Both functions still return immediately when `tofu state list | grep 'haresource'`
is empty:

```bash
if [[ -z "$ha_resources" ]]; then
  ...
  return 0
fi
```

That bypasses Phase 1b entirely. It misses the exact case this fix is meant to
handle when the interrupted apply created the first or only Proxmox HA resource,
or when all HA state entries for the current scope are missing. On rerun,
Proxmox still has `vm:<id>`, tofu still has no corresponding `haresource`, and
the next apply still hits `resource ID already defined`.

This is especially reachable in:
- an early `rebuild-cluster.sh` interruption before any HA state was written
- a scoped run whose only intended HA resource was orphaned
- any case where `haresource` entries were removed from state but the Proxmox HA
  objects remained

The fix needs Phase 1b to run even when `ha_resources` is empty. One caveat:
the current `state list ... || true` also conflates "no HA resources exist" with
"state read failed", so the eventual fix should preserve fail-closed behavior by
distinguishing an empty result from a backend/read error.

### 2. Medium: orphan identification is broader than the bug and can remove legitimate HA resources

**Affected lines:** `framework/scripts/rebuild-cluster.sh:670-687`, `framework/scripts/safe-apply.sh:281-296`, `framework/scripts/rebuild-cluster.sh:933`

Phase 1b removes every Proxmox `vm:*` HA resource whose VMID is absent from this
tofu state snapshot. That is wider than "orphan created by interrupted apply."
It will also remove:

- operator-managed HA resources for VMs outside this repo/state
- HA resources created by another workspace/state backend
- unrelated HA resources encountered during a targeted `safe-apply.sh`
- unrelated HA resources encountered during the atomic single-VM rebuild path in
  `rebuild-cluster.sh` at line 933

Because `reconcile_ha_resources` is cluster-wide, a narrowly scoped deploy can
strip HA protection from unrelated VMs. The rule docs describe manual
`ha-manager remove`/`add` flows for maintenance, but they do not establish that
every cluster HA resource is owned by this state file.

The cleanup should be narrowed to HA resources this repo expects to own, such as
VMIDs declared in config with `ha_enabled = true`, instead of treating "not in
state right now" as sufficient proof of orphanhood.

### 3. Medium: `state_vmids` collection and orphan removal both fail open

**Affected lines:** `framework/scripts/rebuild-cluster.sh:646-656`, `framework/scripts/rebuild-cluster.sh:680-685`, `framework/scripts/safe-apply.sh:257-267`, `framework/scripts/safe-apply.sh:289-294`

The new delete path depends on `state_vmids` being complete, but it is built
from per-resource `tofu state show` calls that intentionally swallow failures:

```bash
vmid=$("${SCRIPT_DIR}/tofu-wrapper.sh" state show "$resource_addr" \
  2>/dev/null | grep 'resource_id' | grep -o '[0-9]*' || true)
```

If `state show` fails for a legitimate HA resource, the code logs a warning,
omits that VMID from `state_vmids`, and Phase 1b can then remove the matching
Proxmox HA resource as a false orphan.

Removal itself also fails open:

```bash
ssh ... "ha-manager remove vm:${proxmox_vmid}" 2>/dev/null || warning
orphan_count=$((orphan_count + 1))
```

So the function reports progress and returns success even when the delete did
not happen. Under `set -euo pipefail`, the initial cluster query fails closed,
but the critical cleanup step does not. That means the caller can proceed into
`tofu apply` without any guarantee that the "already defined" conflict was
actually cleared.

At minimum, a failed `state show` or `ha-manager remove` should abort the
reconciliation, or the code should re-query Proxmox and verify the resource is
gone before continuing.

## Notes

- The two copies are functionally consistent. The only differences are logging
  style and comment wording.
- The placement inside the atomic rebuild loop is otherwise reasonable: once the
  targeted apply at `framework/scripts/rebuild-cluster.sh:931` succeeds, the
  just-recreated module should already have its HA state entry, so it will not
  be mistaken for an orphan. The main remaining risk is the cluster-wide scope
  of the Phase 1b deletion, not the ordering of the loop itself.
