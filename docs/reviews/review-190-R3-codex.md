# Review: Issue #190 -- third-round adversarial review

**Verdict:** ISSUES_FOUND

**Reviewer:** Codex
**Date:** 2026-04-13
**Files reviewed:**
- `framework/scripts/rebuild-cluster.sh`
- `framework/scripts/safe-apply.sh`
- `docs/reviews/review-190-claude.md`
- `docs/reviews/review-190-gemini.md`
- `docs/reviews/review-190-codex.md`
- `docs/reviews/review-190-R2-claude.md`
- `docs/reviews/review-190-R2-gemini.md`
- `docs/reviews/review-190-R2-codex.md`

## Findings

### 1. Medium: `ha-manager remove` failure still leaves reconciliation fail-open, and the new count fix can now produce a false clean summary

**Affected lines:** `framework/scripts/rebuild-cluster.sh:699-715`, `framework/scripts/rebuild-cluster.sh:748-749`, `framework/scripts/safe-apply.sh:306-322`, `framework/scripts/safe-apply.sh:361-362`

The round-2 change correctly stops incrementing `orphan_count` when
`ha-manager remove` fails:

```bash
if ssh ... "ha-manager remove vm:${proxmox_vmid}" 2>/dev/null; then
  orphan_count=$((orphan_count + 1))
else
  ...
fi
```

That fixes the incorrect removal count. However, the function still only logs
the failure and continues. It does not return non-zero, set a failure flag, or
re-verify that the orphan is gone. As a result:

- the caller still proceeds into the next apply with the orphan potentially
  still present
- if `stale_count == 0`, `orphan_count == 0`, and `settled_count == 0`, the
  final summary still prints `All HA resources verified and attributes settled`
  even though an orphan removal just failed

So the R2 `ha-manager remove` issue is only partially fixed. The counting is
now correct, but the reconciliation path still fails open and can emit a false
all-clear message. A failed orphan delete should suppress the clean summary and
return non-zero, or re-query Proxmox and prove the resource is gone before
continuing.

## Verified

- The R2 `tofu state list` fix is correct in both copies. The code now probes
  `state list` under a localized `set +e`, captures the exit status, restores
  `set -e`, and returns `1` before Phase 1b on failure:
  `framework/scripts/rebuild-cluster.sh:612-623`,
  `framework/scripts/safe-apply.sh:222-233`.
- The new `set +e` / `set -e` block is balanced. There is no path that returns
  between disabling and restoring `errexit`.
- `orphan_count` now increments only on successful `ha-manager remove` in both
  copies:
  `framework/scripts/rebuild-cluster.sh:701-705`,
  `framework/scripts/safe-apply.sh:308-312`.
- The two `reconcile_ha_resources` copies remain behaviorally consistent. The
  differences are limited to logging style (`log` vs `echo`), indentation, and
  comment wording.
- `bash -n framework/scripts/rebuild-cluster.sh` and
  `bash -n framework/scripts/safe-apply.sh` both succeed.

## Not Counted As New

- The bare Python `except: pass` in `proxmox_vmids` extraction remains present
  in both copies and is still pre-existing, as called out in the review
  request.
