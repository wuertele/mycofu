#!/usr/bin/env bash
# check_bulk_artifacts_populated.sh — CI post-deploy gate for #518 (A6).
#
# WHY (RCA: docs/reports/2026-07-08-issue-518-bulk-artifact-rca.md):
# rebuild-cluster.sh pointed every per-phase restore-before-start.sh invocation
# at ONE shared preboot-restore-status-all.json, and restore-before-start.sh
# overwrites that file whole. So an empty bulk phase clobbered the atomic phase's
# entries and a successful multi-VM rebuild reported an empty entries[]. Phase 4
# fixed the WRITER (per-phase files + aggregate-preboot-status.sh merge). This
# check is the READER-side gate: it FAILs the pipeline if the aggregated artifact
# does not account for every VMID the preboot manifests said would be restored.
#
# Contract:
#   - expected VMIDs = union of .entries[].vmid across every preboot-restore
#     manifest in the build dir (preboot-restore-atomic-*.json + -bulk.json).
#   - actual VMIDs   = .entries[].vmid in preboot-restore-status-all.json.
#   - both empty (no VM recreated) => legitimate no-op => PASS.
#   - expected non-empty but status missing/short => FAIL naming missing VMIDs.
#   - vdb-park-status-*.json files must be well-formed JSON with an entries array
#     (the strict eligible-vs-recorded park parity is enforced at RUNTIME inside
#     vdb_park_batch; here we guard against a corrupt/absent park artifact).
#
# Usage:
#   check_bulk_artifacts_populated.sh [--build-dir <dir>]
# Env:
#   BULK_ARTIFACT_BUILD_DIR  alternative to --build-dir.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${BULK_ARTIFACT_BUILD_DIR:-${REPO_DIR}/build}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="$2"; shift 2 ;;
    -h|--help) grep -E '^# ' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -d "$BUILD_DIR" ]]; then
  echo "check_bulk_artifacts_populated: build dir not found: ${BUILD_DIR}" >&2
  echo "  (no rebuild artifacts to check — nothing was produced)"
  exit 0
fi

STATUS_ALL="${BUILD_DIR}/preboot-restore-status-all.json"

BUILD_DIR="$BUILD_DIR" STATUS_ALL="$STATUS_ALL" python3 - <<'PY'
import glob, json, os, sys

build = os.environ["BUILD_DIR"]
status_all = os.environ["STATUS_ALL"]

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception as exc:
        print("  ERROR: unreadable JSON %s: %s" % (path, exc))
        return None

def manifest_vmids(doc):
    if isinstance(doc, list):
        entries = doc
    elif isinstance(doc, dict):
        entries = doc.get("entries", [])
    else:
        return set(), True
    out = set()
    for e in entries or []:
        if isinstance(e, dict) and "vmid" in e:
            try:
                out.add(int(e["vmid"]))
            except (TypeError, ValueError):
                pass
    return out, False

failures = []

# --- 1. expected VMIDs from preboot manifests (atomic + bulk) ---
manifest_files = sorted(
    glob.glob(os.path.join(build, "preboot-restore-atomic-*.json"))
    + glob.glob(os.path.join(build, "preboot-restore-bulk.json"))
)
expected = set()
for mf in manifest_files:
    doc = load(mf)
    if doc is None:
        failures.append("manifest %s is not valid JSON" % os.path.basename(mf))
        continue
    ids, bad = manifest_vmids(doc)
    if bad:
        failures.append("manifest %s has an unexpected shape" % os.path.basename(mf))
    expected |= ids

print("Preboot manifests: %d file(s), %d expected VMID(s): %s"
      % (len(manifest_files), len(expected), sorted(expected)))

# --- 2. actual VMIDs from the aggregated status artifact ---
actual = set()
if os.path.exists(status_all):
    doc = load(status_all)
    if doc is None:
        failures.append("preboot-restore-status-all.json is not valid JSON")
    else:
        ids, bad = manifest_vmids(doc)
        if bad:
            failures.append("preboot-restore-status-all.json has an unexpected shape")
        actual = ids
    print("Aggregated status: %d entr(y/ies): %s" % (len(actual), sorted(actual)))
else:
    print("Aggregated status: preboot-restore-status-all.json ABSENT")

# --- 3. the #518 parity gate ---
if not expected:
    # No VM was recreated: an absent/empty status artifact is the legitimate
    # no-op. (An artifact that somehow has entries without a manifest is odd but
    # not the #518 failure — do not fail on it.)
    print("PASS: no preboot manifest VMIDs — both-empty no-op is legitimate.")
else:
    if not os.path.exists(status_all):
        failures.append(
            "preboot manifest names %d VMID(s) but preboot-restore-status-all.json is ABSENT "
            "(aggregation did not run — the #518 clobber symptom)" % len(expected))
    missing = sorted(expected - actual)
    if missing:
        failures.append(
            "preboot-restore-status-all.json is missing status entries for VMID(s): %s "
            "(a phase clobbered another's entries — the #518 regression)"
            % ", ".join(str(v) for v in missing))

# --- 4. park artifacts: well-formedness only (strict parity is a runtime gate) ---
park_files = sorted(glob.glob(os.path.join(build, "vdb-park-status-*.json")))
for pf in park_files:
    doc = load(pf)
    if doc is None:
        failures.append("park status %s is not valid JSON" % os.path.basename(pf))
        continue
    if not isinstance(doc, dict) or not isinstance(doc.get("entries"), list):
        failures.append("park status %s lacks an entries array" % os.path.basename(pf))
        continue
    print("Park artifact %s: %d entr(y/ies)" % (os.path.basename(pf), len(doc["entries"])))

if failures:
    print("")
    print("FAIL: bulk artifact population check found %d problem(s):" % len(failures))
    for f in failures:
        print("  - %s" % f)
    sys.exit(1)

print("")
print("PASS: bulk restore/park artifacts are populated and consistent.")
PY
