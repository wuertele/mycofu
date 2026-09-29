# Review: Issue #190 -- reconcile_ha_resources orphan cleanup (Round 2)

**Verdict: ISSUES_FOUND**

**Reviewer:** Gemini CLI (adversarial review)
**Date:** 2026-04-13
**Files reviewed:**
- `framework/scripts/safe-apply.sh`
- `framework/scripts/rebuild-cluster.sh`

## Summary

The fixes for Round 1 issues are present: the early return is removed (fixing the bypass), and a `state_extract_failures` counter with a fail-closed guard is added (protecting against partial state read failures). However, two critical "fail-open" vulnerabilities identified in Round 1 remain, which could lead to accidental mass deletion of HA resources from either Proxmox or the OpenTofu state.

---

## Critical Issues

### 1. Fail-Open on `tofu state list` failure (Destructive)

**Both files: `safe-apply.sh:220` / `rebuild-cluster.sh:609`**

```bash
  ha_resources=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null \
    | grep 'haresource' || true)
```

If `tofu state list` fails (e.g., due to a state lock or backend network issue), the `|| true` and `grep` behavior will result in `ha_resources` being empty. 

**Impact:** `state_extract_failures` remains `0`, and the script proceeds to Phase 1b with an empty `state_vmids` list. Phase 1b then identifies **every** HA resource in Proxmox as an orphan and executes `ha-manager remove`. This is a catastrophic failure mode where a transient state lock causes the deletion of all HA protection in the cluster.

**Fix:** Remove `|| true` and check the exit code of the state query. If it fails, the function should return 1 (fail closed).

### 2. Fail-Open on Python JSON parsing (Destructive)

**Both files: `safe-apply.sh:243` / `rebuild-cluster.sh:632`**

```python
except:
    pass
```

The `proxmox_vmids` extraction swallows all Python exceptions. If `proxmox_ha` contains malformed JSON or the `pvesh` output format changes, `proxmox_vmids` will be an empty string.

**Impact:** Phase 1 (stale state removal) will see that every resource in the OpenTofu state is "missing" from Proxmox (since the list is empty) and will execute `tofu state rm` for every HA resource. This results in the corruption of the OpenTofu state due to a parsing error.

**Fix:** Change `pass` to `sys.exit(1)` and log an error to `stderr`. Ensure the shell script detects this failure and returns 1.

---

## Minor Issues

### 1. Incorrect Indentation in Phase 1b

**Both files: `safe-apply.sh:282-297` / `rebuild-cluster.sh:678-693`**

The `while` loop and the subsequent `if [[ $orphan_count -gt 0 ]]` block inside the `else` statement are not indented. While functionally correct in Bash, it makes the code difficult to read and maintain.

### 2. Comment Consistency

The comments for Phase 1b differ slightly between the two files. While not a bug, keeping them synchronized (as they were in R1) reduces maintenance overhead.

---

## Conclusion

The specific blockers called out in Round 1 were addressed, but the underlying safety concerns regarding "empty result vs. error" remain unresolved for the primary queries. The script is still unsafe for production use as it can perform mass deletions triggered by transient infrastructure or state failures.
