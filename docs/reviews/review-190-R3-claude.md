# Round 3 Review: Issue #190 -- reconcile_ha_resources orphan cleanup

**Verdict: PASS**

**Reviewer:** Claude Opus 4.6 (adversarial review, round 3)
**Date:** 2026-04-12
**Files reviewed:**
- `framework/scripts/safe-apply.sh` (lines 216-366)
- `framework/scripts/rebuild-cluster.sh` (lines 605-753)

## Round 2 Issues -- Verification

### R2 Issue 1: `tofu state list` failure masked by `|| true` causing mass HA deletion

**Status: Fixed.**

The `|| true` on the state list command is gone. The code now uses the
`set +e` / capture / `set -e` pattern (per `.claude/rules/platform.md`):

```bash
set +e
all_state=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null)
local state_list_exit=$?
set -e
if [[ $state_list_exit -ne 0 ]]; then
    echo "ERROR: tofu state list failed (exit ${state_list_exit}) ..."
    return 1
fi
ha_resources=$(echo "$all_state" | grep 'haresource' || true)
```

The `|| true` now only appears on the `grep` after a confirmed-successful
state list. This correctly distinguishes "state list failed" (return 1,
fail closed) from "state list succeeded with zero HA entries" (`ha_resources`
is empty, function continues to Phase 1b).

Traced the failure path: `state list` returns non-zero -> `state_list_exit`
captures the code -> `set -e` is restored -> the `if` check fires ->
function returns 1 -> caller receives failure and aborts. No HA resources
are touched. Confirmed correct.

### R2 Issue 2: Failed `ha-manager remove` counted as successful removal

**Status: Fixed.**

The code now wraps the SSH call in an `if` conditional:

```bash
if ssh -n ... "ha-manager remove vm:${proxmox_vmid}" 2>/dev/null; then
    orphan_count=$((orphan_count + 1))
else
    echo "  ERROR: ha-manager remove failed for vm:${proxmox_vmid} -- orphan remains"
fi
```

`orphan_count` is only incremented on success. Failed removals log an
error and leave the orphan in place. The function still returns 0 (the
next `tofu apply` will fail with "resource ID already defined" for that
specific resource, giving the operator a clear signal). This is
acceptable: the function is best-effort cleanup, and a hard failure here
would block the entire pipeline for a single stubborn HA resource.

## Consistency Between the Two Copies

Both copies are functionally identical. All differences are cosmetic:

- **Logging:** safe-apply.sh uses `echo`, rebuild-cluster.sh uses `log`
- **Indentation prefixes:** rebuild-cluster.sh adds extra leading spaces
  for alignment with its log format
- **Comments:** rebuild-cluster.sh has slightly more verbose Phase 1b
  comments (explains the kill scenario in more detail)

Verified via diff: no logic, control flow, variable name, or error
handling divergence between the two files.

## `set +e` / `set -e` Correctness

The pattern is correct and follows the project convention documented in
`.claude/rules/platform.md`. Key points verified:

1. `set +e` disables errexit before the potentially-failing command
2. `local state_list_exit=$?` captures the exit code on the next line
   (safe because `set -e` is off)
3. `set -e` re-enables errexit immediately after capture
4. The `if` check on `state_list_exit` provides the branching logic

One subtlety: `local` in bash always returns 0 as its own exit status,
so `local state_list_exit=$?` captures `$?` from the previous command
(the state list), not from `local` itself. This is correct behavior
in bash.

## Edge Case Re-verification

| Scenario | state_list_exit | ha_resources | state_extract_failures | Phase 1b? | Behavior |
|----------|----------------|-------------|----------------------|-----------|----------|
| State backend down | non-zero | n/a | n/a | No | return 1 (fail closed) |
| State OK, zero HA entries, orphans in Proxmox | 0 | "" | 0 | Yes | Orphans removed |
| State OK, zero HA entries, no orphans | 0 | "" | 0 | Yes (loop empty) | Nothing removed |
| State OK, all extractions succeed, no orphans | 0 | populated | 0 | Yes (no matches) | Nothing removed |
| State OK, all extractions succeed, orphans exist | 0 | populated | 0 | Yes | Orphans removed |
| State OK, one extraction fails | 0 | populated | >0 | No (skipped) | Warning logged |
| ha-manager remove fails for one orphan | 0 | any | 0 | Yes | Error logged, count not incremented |

All edge cases produce correct behavior.

## New Issues

None found. Both R2 issues are adequately fixed. No new issues introduced.

The pre-existing Python `except: pass` issue (noted in R2 but not in
scope for this fix) remains unchanged, as expected.
