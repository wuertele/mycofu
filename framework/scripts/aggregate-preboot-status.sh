#!/usr/bin/env bash
# aggregate-preboot-status.sh — merge per-phase preboot-restore status files into
# the canonical preboot-restore-status-all.json (Sprint 045 / #518, A6).
#
# WHY THIS EXISTS (the #518 RCA — docs/reports/2026-07-08-issue-518-bulk-artifact-rca.md):
# rebuild-cluster.sh runs restore-before-start.sh once per atomic module and once
# for the bulk phase. It used to point EVERY invocation at a single shared
# preboot-restore-status-all.json. restore-before-start.sh re-inits {entries:[]}
# and cp-overwrites the whole file, so each phase clobbered the previous one's
# entries — and a legitimately empty bulk phase (nothing left to restore after
# atomic recreations) wrote {entries:[]} last, erasing the atomic entries. The
# artifact then read as "nothing happened" on a successful rebuild.
#
# The fix: each phase writes its OWN status file
# (preboot-restore-status-atomic-<mod>.json / preboot-restore-status-bulk.json),
# and this script unions them into the canonical all.json AFTER all phases run.
# A VMID normally appears in exactly one phase; if it appears in more than one,
# the entry with the most recent generated_at wins (last writer reflects final
# state). Missing or empty phase files are skipped. No per-phase file / all empty
# => an entries:[] canonical file, which is the legitimate no-op (no VM recreated).
#
# This is a seam-planted storage primitive: pure read of per-phase JSON, pure
# write of the canonical JSON. It performs no cluster access.
#
# Usage:
#   aggregate-preboot-status.sh --out <canonical.json> <phase.json> [<phase.json> ...]
#   aggregate-preboot-status.sh --out <canonical.json> --glob-dir <dir>
#     (globs <dir>/preboot-restore-status-atomic-*.json and
#      <dir>/preboot-restore-status-bulk.json)

set -euo pipefail

OUT=""
GLOB_DIR=""
INPUTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT="$2"; shift 2 ;;
    --glob-dir)
      GLOB_DIR="$2"; shift 2 ;;
    -h|--help)
      grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *)
      INPUTS+=("$1"); shift ;;
  esac
done

if [[ -z "$OUT" ]]; then
  echo "ERROR: --out <canonical.json> is required" >&2
  exit 1
fi

if [[ -n "$GLOB_DIR" ]]; then
  # nullglob so a missing pattern expands to nothing, not the literal glob.
  shopt -s nullglob
  for f in "${GLOB_DIR}"/preboot-restore-status-atomic-*.json "${GLOB_DIR}"/preboot-restore-status-bulk.json; do
    INPUTS+=("$f")
  done
  shopt -u nullglob
fi

mkdir -p "$(dirname "$OUT")"

OUT="$OUT" python3 - "${INPUTS[@]+"${INPUTS[@]}"}" <<'PY'
import json, os, sys

out_path = os.environ["OUT"]
inputs = sys.argv[1:]

# vmid -> (generated_at, entry). Last (most recent generated_at) wins so the
# final phase to touch a VMID reflects its terminal state.
by_vmid = {}
aggregated_from = []

for path in inputs:
    if not path or not os.path.exists(path):
        continue
    try:
        with open(path) as f:
            doc = json.load(f)
    except Exception as exc:
        sys.stderr.write("aggregate-preboot-status: skipping unreadable %s: %s\n" % (path, exc))
        continue
    if not isinstance(doc, dict):
        continue
    aggregated_from.append(os.path.basename(path))
    gen = str(doc.get("generated_at", ""))
    for e in doc.get("entries", []) or []:
        if not isinstance(e, dict) or "vmid" not in e:
            continue
        try:
            vmid = int(e["vmid"])
        except (TypeError, ValueError):
            continue
        prev = by_vmid.get(vmid)
        # Keep the entry whose source file has the latest generated_at.
        if prev is None or gen >= prev[0]:
            by_vmid[vmid] = (gen, e)

entries = [by_vmid[v][1] for v in sorted(by_vmid)]

# Stamp generated_at from the newest source (deterministic; no wall-clock read
# so repeated runs over the same inputs are byte-stable).
newest = max((by_vmid[v][0] for v in by_vmid), default="")

canonical = {
    "version": 1,
    "scope": "all",
    "source": "aggregate-preboot-status",
    "generated_at": newest,
    "aggregated_from": sorted(aggregated_from),
    "entries": entries,
}

tmp = out_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(canonical, f, indent=2)
    f.write("\n")
os.replace(tmp, out_path)

sys.stderr.write(
    "aggregate-preboot-status: %d entr(ies) from %d phase file(s) -> %s\n"
    % (len(entries), len(aggregated_from), out_path))
PY
