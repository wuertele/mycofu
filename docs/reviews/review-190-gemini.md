# Adversarial Review: Issue #190 - HA Orphan Reconciliation Fix

- **Author**: Gemini CLI (Adversarial Reviewer)
- **Date**: 2026-04-13
- **Verdict**: ISSUES_FOUND

## Summary

The fix adds a "Phase 1b" to the `reconcile_ha_resources()` function in both `rebuild-cluster.sh` and `safe-apply.sh`. This phase correctly identifies and removes orphan HA resources from Proxmox that exist in reality but are missing from OpenTofu state. However, the implementation contains several critical bugs that prevent it from fully solving Issue #190 in all scenarios and introduces a dangerous destructive failure mode.

## Critical Issues

### 1. Issue #190 Persistence (Early Return Bug)
Both scripts contain an early return if no HA resources are found in the OpenTofu state:
```bash
  if [[ -z "$ha_resources" ]]; then
    log "    No HA resources in state — skipping"
    return 0
  fi
```
**Impact:** If a `tofu apply` is killed during the creation of the *first* or *only* HA resource, Proxmox will have created the resource but the Tofu state will be empty. On the subsequent run, `reconcile_ha_resources` will see the empty state and return early, skipping Phase 1b entirely. The following `tofu apply` will then fail with the original "resource ID already defined" error. The fix fails to solve the reported issue in the most common failure case.

### 2. Destructive Failure Mode (Transient State Failure)
In Phase 1, the script extracts VMIDs from existing state entries using `tofu state show`. If this extraction fails (e.g., transient state lock, network issue, or internal Tofu error), the script logs a warning and *continues* without adding the VMID to `state_vmids`:
```bash
    vmid=$("${SCRIPT_DIR}/tofu-wrapper.sh" state show "$resource_addr" \
      2>/dev/null | grep 'resource_id' | grep -o '[0-9]*' || true)

    if [[ -z "$vmid" ]]; then
      log "    WARNING: Could not extract VMID from ${resource_addr} — skipping"
      continue
    fi
```
**Impact:** Phase 1b then iterates through all Proxmox HA resources. Since the VMID for the "skipped" resource is missing from the local `state_vmids` list, Phase 1b identifies it as an orphan and executes `ha-manager remove`. This results in the **accidental deletion of a valid, state-backed HA resource** from Proxmox due to a transient read failure in Phase 1. This violates the safety principles in `.claude/rules/destructive-operations.md`.

## Secondary Issues

### 3. Performance/Scalability ($O(N)$ with Tofu overhead)
The script calls `${SCRIPT_DIR}/tofu-wrapper.sh state show` for every HA resource found in the state. Each call to `tofu` has significant initialization overhead (seconds). In a cluster with many HA resources, `reconcile_ha_resources` will become extremely slow, delaying deployments significantly.
**Recommendation:** Use `tofu state pull` once and parse the resulting JSON in Python or with `jq` to extract all VMIDs in a single pass.

### 4. Resource Leak (Temporary File)
In Phase 2, the scripts create a temporary file:
```bash
  echo "$proxmox_ha" | python3 -c "..." > ${TMPDIR:-/tmp}/ha-settle-list.$$.txt
```
This file is never deleted. Over time, `/tmp` (or `TMPDIR`) will accumulate orphaned settle-list files from every deployment run.

### 5. Silent Failure in Python Blocks
The Python blocks for VMID extraction and Phase 2 settling use `try: ... except: pass`. This masks malformed JSON or other unexpected input, potentially causing the script to silently "succeed" while skipping critical reconciliation steps.

## Recommendations

1.  **Remove the early return.** Let the loops handle empty inputs. If state is empty, `state_vmids` will be empty, and Phase 1b will correctly remove all orphans from Proxmox.
2.  **Ensure Atomic State Extraction.** If any `tofu state` command fails during Phase 1, the function should `return 1` (fail closed) instead of continuing. We must not proceed to Phase 1b without a guaranteed-complete `state_vmids` list.
3.  **Optimize with `tofu state pull`.** Extract all VMIDs in one JSON parsing step instead of calling `state show` in a loop.
4.  **Add `rm -f` for the temporary file.** Ensure the settle-list is cleaned up in a `trap` or immediately after use.
5.  **Improve Python error handling.** Log errors to `stderr` in the `except` block instead of silencing them.
