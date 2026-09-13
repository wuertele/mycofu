# Review: Issue #190 -- reconcile_ha_resources orphan cleanup

**Verdict: ISSUES_FOUND**

**Reviewer:** Claude Opus 4.6 (adversarial review)
**Date:** 2026-04-12
**Files reviewed:**
- `framework/scripts/safe-apply.sh` (lines 216-330)
- `framework/scripts/rebuild-cluster.sh` (lines 605-728)

## Summary

Phase 1b correctly identifies the problem (HA resource exists in Proxmox
but not in tofu state) and the `ha-manager remove` approach is the right
fix. However, there is one blocking bug and several lesser issues.

---

## BLOCKING: Early return bypasses Phase 1b when state has zero haresource entries

**Both files, lines 223-226 (safe-apply) / 612-615 (rebuild-cluster):**

```bash
if [[ -z "$ha_resources" ]]; then
    echo "  No HA resources in state -- skipping"
    return 0
fi
```

If there are NO haresource entries in tofu state, the function returns
before reaching Phase 1b. This is exactly the scenario described in
issue #190: a killed `tofu apply` created the HA resource in Proxmox but
never wrote the state entry. If ALL HA resources are in this condition
(e.g., rebuild-cluster.sh was killed during the first module's apply,
before any HA resource was written to state), `ha_resources` is empty,
the function returns 0, and Phase 1b never runs. The orphan HA resources
remain in Proxmox and the next `tofu apply` fails with "resource ID
already defined."

**Fix:** Move the early return to after the Proxmox query and Phase 1b
check. The function should still query Proxmox HA resources and run
Phase 1b even when no haresource entries exist in state. When
`ha_resources` is empty, Phase 1 (stale state removal) and
`state_vmids` collection can be skipped, but Phase 1b must still run
with `state_vmids=""` (which means every Proxmox HA resource would be
treated as an orphan -- which is correct when state has none).

**Severity:** This defeats the fix for the exact scenario #190 describes.

---

## Non-blocking issues

### 1. state_vmids is built only from haresource entries, not from VM entries

`state_vmids` is populated by extracting `resource_id` from each
haresource in state. If a VM has `ha_enabled = true` in its tofu config
but the haresource entry was not yet written to state (partial apply),
the VM's VMID would NOT appear in `state_vmids`. Phase 1b would see the
Proxmox HA resource as an orphan and remove it.

In the #190 scenario this is actually the desired behavior -- the HA
resource was orphaned and should be removed so tofu can recreate it.
But if a legitimate HA resource exists in Proxmox and its state entry
was temporarily unreadable (e.g., state lock contention causing
`tofu state show` to fail), the `|| true` fallback would produce an
empty VMID, the WARNING would fire, and the VMID would be missing from
`state_vmids`. Phase 1b would then remove a legitimate HA resource.

**Risk:** Low. `tofu state show` failures are rare, and the function
already logs a WARNING for this case. The subsequent `tofu apply` would
recreate the HA resource.

### 2. Bare `except: pass` in Python swallows all errors silently

Both the `proxmox_vmids` extraction (line 241/630) and the Phase 2
settle-list generation use `except: pass`, which swallows JSON parse
errors, key errors, and any other exception. If the pvesh output format
changes or is malformed, the function proceeds with an empty
`proxmox_vmids` list. Phase 1 would then remove ALL haresource entries
from state (every VMID would be "not in Proxmox"). Phase 1b would not
run (empty `proxmox_vmids`), so no Proxmox damage, but the state
corruption is significant.

The Proxmox query failure check (`if [[ -z "$proxmox_ha" ...]]`) guards
against empty/null responses but not against malformed JSON that produces
zero matches. Consider checking that `proxmox_vmids` is non-empty when
`proxmox_ha` is non-empty, or using `except Exception as e:
print(f"ERROR: {e}", file=sys.stderr); sys.exit(1)`.

**Risk:** Low (pvesh JSON output is stable), but the failure mode is
destructive (mass state removal).

### 3. Operator-managed HA resources would be removed

If the operator manually added an HA resource via `pvesh create
/cluster/ha/resources/vm:999` for a VM not managed by tofu, Phase 1b
would remove it (VMID 999 would not appear in `state_vmids`).

**Risk:** Low in this project (all VMs are tofu-managed). Document the
behavior in the function comment so future operators are aware.

### 4. Log output consistency between the two copies

The two copies use different logging functions (`echo` in safe-apply.sh
vs `log` in rebuild-cluster.sh) and different indentation levels. The
Phase 1b comment text also differs slightly (rebuild-cluster.sh has a
more detailed comment). These are cosmetic but make maintenance harder
when the function is duplicated. Consider extracting to a shared library.

### 5. Interaction with the atomic rebuild loop

The interaction at rebuild-cluster.sh line 933 is correct. In the atomic
loop:
1. Line 889 removes the HA resource from Proxmox
2. Lines 913-923 remove all resources (including haresource) from state
3. Line 931 `tofu apply` creates VM + HA resource
4. Line 933 `reconcile_ha_resources` runs Phase 1b

If the apply at line 931 creates the HA resource in Proxmox AND state,
Phase 1b finds a match and does nothing (correct). If the bpg provider
creates it in Proxmox but not in state (the known bug), Phase 1b removes
it from Proxmox, and the second apply at line 935 recreates it (correct).

No adverse interaction found.

### 6. Error handling under set -euo pipefail

The `ha-manager remove ... 2>/dev/null || log "WARNING..."` pattern
correctly prevents `set -e` from killing the script on removal failure.
The `|| true` on grep commands and the `|| true` on the
`tofu-wrapper.sh state rm` command are also correct.

One concern: `2>/dev/null` on the `ha-manager remove` suppresses the
error message. If removal fails, the operator only sees "WARNING:
ha-manager remove failed" with no details about why. Consider capturing
stderr and including it in the warning.

---

## Recommendation

Fix the blocking issue (early return bypassing Phase 1b) before merging.
The non-blocking issues are acceptable for this fix but should be tracked
for follow-up.

Suggested fix structure:

```bash
reconcile_ha_resources() {
  local node_ip="$1"

  local ha_resources
  ha_resources=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null \
    | grep 'haresource' || true)

  # Query Proxmox HA resources regardless of state contents.
  # Phase 1b needs this even when state has no haresource entries.
  local proxmox_ha
  proxmox_ha=$(ssh -n ... "pvesh get /cluster/ha/resources ..." 2>/dev/null)

  if [[ -z "$proxmox_ha" || "$proxmox_ha" == "null" ]]; then
    # No HA resources in state AND cannot query Proxmox
    if [[ -z "$ha_resources" ]]; then
      echo "  No HA resources in state or Proxmox -- nothing to do"
      return 0
    fi
    echo "ERROR: Cannot query HA resources from ${node_ip}"
    return 1
  fi

  # ... extract proxmox_vmids ...

  # Phase 1: only if ha_resources is non-empty
  local state_vmids=""
  if [[ -n "$ha_resources" ]]; then
    # ... existing Phase 1 loop ...
  fi

  # Phase 1b: always runs (state_vmids may be empty, which is correct)
  # ... existing Phase 1b loop ...
```
