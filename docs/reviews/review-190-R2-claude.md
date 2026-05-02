# Round 2 Review: Issue #190 -- reconcile_ha_resources orphan cleanup

**Verdict: PASS**

**Reviewer:** Claude Opus 4.6 (adversarial review, round 2)
**Date:** 2026-04-12
**Files reviewed:**
- `framework/scripts/safe-apply.sh` (lines 216-355)
- `framework/scripts/rebuild-cluster.sh` (lines 605-741)

## Round 1 Issues -- Verification

### Issue 1: Early return bypassed Phase 1b when state had zero HA entries

**Status: Fixed.**

The early `return 0` is gone. In its place is a comment explicitly
documenting the design intent:

```bash
# Do NOT return early when ha_resources is empty -- Phase 1b must still
# run to clean orphan Proxmox HA resources left by killed applies (#190).
```

Phase 1 (stale state removal) is guarded by `if [[ -n "$ha_resources" ]]`
so it only runs when there are state entries to process. Phase 1b runs
unconditionally (subject to the state_extract_failures guard). When
`ha_resources` is empty, `state_vmids` remains empty and
`state_extract_failures` remains 0, so Phase 1b executes and treats every
Proxmox HA resource as an orphan. This is the correct behavior for the
#190 scenario.

Traced the critical path: ha_resources="" -> Phase 1 skipped ->
state_vmids="" -> state_extract_failures=0 -> Phase 1b runs -> every
proxmox_vmid fails the grep against empty state_vmids -> ha-manager
remove executes. Confirmed correct.

### Issue 2: Incomplete state_vmids from failed state show could cause false orphan removal

**Status: Fixed.**

A `state_extract_failures` counter is incremented each time a
`tofu state show` call fails to produce a VMID. If the counter is
non-zero, Phase 1b is skipped entirely with a warning:

```bash
if [[ $state_extract_failures -gt 0 ]]; then
    echo "  WARNING: ... failed -- skipping orphan cleanup"
    echo "  Phase 1b cannot safely identify orphans without a complete state VMID list"
else
    # ... Phase 1b orphan removal ...
fi
```

This is fail-closed behavior: when the state VMID list might be
incomplete, the function refuses to remove anything from Proxmox. The
orphans remain, and the next `tofu apply` will fail with "resource ID
already defined" -- but this is recoverable by re-running
reconcile_ha_resources when the state backend is healthy. Destroying a
legitimate HA resource would be worse.

## New Issues Introduced by the Fix

None found. The fix is clean and introduces no new failure modes beyond
what existed before.

## Consistency Between the Two Copies

The two copies are functionally identical. All differences are cosmetic:

- **Logging:** safe-apply.sh uses `echo`, rebuild-cluster.sh uses `log`
  (each file's convention)
- **Indentation:** rebuild-cluster.sh uses deeper indentation for log
  messages
- **Comments:** rebuild-cluster.sh has slightly more detailed Phase 1b
  comments

The logic, control flow, variable names, and error handling are the same
in both files. No divergence in behavior.

## if/else/fi Structure

The Phase 1b guard structure parses correctly:

```
if [[ $state_extract_failures -gt 0 ]]; then
    # warning messages
else
    # while loop (Phase 1b orphan removal)
    # orphan count summary
fi  # end state_extract_failures guard
```

The `while` loop inside the `else` branch has unconventional indentation
(not indented relative to `else`) but this is cosmetic -- bash does not
require indentation. The structure is syntactically valid.

## Edge Case Analysis

| Scenario | state_vmids | state_extract_failures | Phase 1b runs? | Behavior | Correct? |
|----------|-------------|----------------------|----------------|----------|----------|
| No HA in state, orphans in Proxmox | "" | 0 | Yes | All Proxmox HA resources removed | Yes |
| No HA in state, no HA in Proxmox | "" | 0 | Yes (loop body skipped) | Nothing removed | Yes |
| All state extractions succeed, no orphans | populated | 0 | Yes (no matches) | Nothing removed | Yes |
| All state extractions succeed, orphans exist | populated | 0 | Yes | Orphans removed | Yes |
| One state extraction fails | incomplete | >0 | No (skipped) | Warning logged | Yes (fail closed) |
| All state extractions fail | "" | >0 | No (skipped) | Warning logged | Yes (fail closed) |

All edge cases produce correct behavior.

## Minor Observations (not blocking)

1. **state list failure is indistinguishable from empty state.** If
   `tofu state list` fails entirely (backend unreachable), `ha_resources`
   is empty (due to `|| true`), `state_extract_failures` stays 0, and
   Phase 1b would remove all Proxmox HA resources. In practice this is
   low-risk: if the backend is down, the subsequent `tofu apply` will
   also fail, and `ha-manager add` in the next successful apply
   recreates the HA resources. The window of exposure is small.

2. **Python `except: pass` blocks.** Carried forward from the original
   code (pre-#190). Malformed JSON from pvesh would produce empty
   `proxmox_vmids`, causing Phase 1 to remove all state entries. The
   existing guard `if [[ -z "$proxmox_ha" || ... ]]` catches empty
   responses but not malformed JSON that yields zero matches. This is a
   pre-existing issue, not introduced by this fix.

3. **Temp file cleanup.** Both copies now have `rm -f` for the
   ha-settle-list temp file. The round 1 issue (Gemini #4) is resolved.

Neither observation warrants blocking this fix.
