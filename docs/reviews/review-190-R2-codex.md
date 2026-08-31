# Review: Issue #190 -- second-round adversarial review

**Verdict:** ISSUES_FOUND

**Reviewer:** Codex
**Date:** 2026-04-13
**Files reviewed:**
- `framework/scripts/rebuild-cluster.sh`
- `framework/scripts/safe-apply.sh`
- `docs/reviews/review-190-claude.md`
- `docs/reviews/review-190-codex.md`
- `docs/reviews/review-190-gemini.md`

## Findings

### 1. Blocking: `tofu state list` failure still collapses to "empty state" and can delete legitimate Proxmox HA resources

**Affected lines:** `framework/scripts/rebuild-cluster.sh:609-610`, `framework/scripts/rebuild-cluster.sh:643-645`, `framework/scripts/rebuild-cluster.sh:683-698`, `framework/scripts/safe-apply.sh:220-221`, `framework/scripts/safe-apply.sh:254-256`, `framework/scripts/safe-apply.sh:291-306`

The round-2 guard only covers per-resource `tofu state show` failures after
`ha_resources` has already been enumerated. The initial state enumeration still
uses:

```bash
ha_resources=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null \
  | grep 'haresource' || true)
```

Under `set -euo pipefail`, that `|| true` makes a failed `tofu state list`
indistinguishable from a genuinely empty HA state. When `state list` fails
(backend/init/read error, transient lock issue, etc.), the function gets:

- `ha_resources=""`
- `state_extract_failures=0`
- `state_vmids=""`

Phase 1 is skipped, but Phase 1b still runs because the new guard sees zero
`state_extract_failures`. The code then treats every Proxmox `vm:*` HA resource
as an orphan and removes it.

That means round-1 issue (2) is not actually closed end-to-end: an incomplete
`state_vmids` set can still remove legitimate HA resources, just one step earlier
than the newly added guard.

The fix needs the same fail-closed behavior on `tofu state list` itself:
distinguish "state list succeeded and returned zero HA resources" from
"state list failed, so ownership is unknown."

### 2. Medium: orphan deletion still fails open

**Affected lines:** `framework/scripts/rebuild-cluster.sh:690-696`, `framework/scripts/safe-apply.sh:298-304`

Phase 1b logs a warning when `ha-manager remove` fails, but still increments
`orphan_count` and returns success:

```bash
ssh ... "ha-manager remove vm:${proxmox_vmid}" 2>/dev/null || \
  log/echo "WARNING: ha-manager remove failed ..."
orphan_count=$((orphan_count + 1))
```

If the delete fails, the caller proceeds into the next apply without any proof
that the `resource ID already defined` conflict was actually cleared. This is a
new fail-open path introduced by the Phase 1b cleanup logic.

At minimum, failed deletes should not be counted as removed, and the function
should return non-zero or re-query Proxmox to verify the resource is gone.

## Verified

- Round-1 issue (1) is fixed in both copies: the old early return on empty
  `ha_resources` is gone.
- The requested empty-state scenario now works: with `ha_resources=""`,
  `state_extract_failures=0`, and Proxmox orphan HA resources present, Phase 1
  is skipped and Phase 1b removes all Proxmox `vm:*` HA entries.
- Both copies are functionally consistent. Differences are limited to
  logging/comment wording and indentation.
- `if`/`else`/`fi` structure parses correctly in both scripts: `bash -n
  framework/scripts/rebuild-cluster.sh` and `bash -n
  framework/scripts/safe-apply.sh` both succeed.

## Remaining edge cases

- The Python extractors still use bare `except: pass`. If `pvesh` returns
  malformed but non-empty JSON, `proxmox_vmids` becomes empty and Phase 1 can
  remove valid HA state entries as "stale."
- Operator-managed or foreign-workspace HA resources are still considered
  orphans if they are absent from this state file. That may be acceptable here,
  but it remains a cluster-wide ownership assumption.
