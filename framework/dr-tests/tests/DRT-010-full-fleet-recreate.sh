#!/usr/bin/env bash
# DRT-ID: DRT-010
# DRT-NAME: Full-Fleet Recreate
# DRT-TIME: ~30 min (--scope dev) / ~90 min (--scope all)
# DRT-DESTRUCTIVE: yes
# DRT-DESC: Force VM recreation with precious-state continuity: dev vdb
#           park/adopt, prod/shared PBS-pin preboot restore, and the
#           control-plane atomic ladder, anchored to a run-scoped restore
#           pin. PBS itself is excluded.

set -euo pipefail

# These identifiers are consumed by the sourced DRT harness.
# shellcheck disable=SC2034
DRT_ID="DRT-010"
# shellcheck disable=SC2034
DRT_NAME="Full-Fleet Recreate"
SCOPE=""
# Run-scoped restore pin: written by backup-now.sh --pin-out and handed to
# rebuild-cluster.sh --restore-pin-file, so the park bridge and the preboot
# restore anchor to this run's backup rather than an unpinned "latest".
PIN_FILE="build/restore-pin-drt010.json"

usage() {
  echo "Usage: framework/dr-tests/run-dr-test.sh DRT-010 --scope dev|all"
  echo "Run --scope all from a prod checkout; it uses --override-branch-check."
  echo "See OPERATIONS.md: Full-fleet recreate and ACME Staging for DR Tests."
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      [[ $# -ge 2 ]] || { usage >&2; exit 1; }
      SCOPE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
case "$SCOPE" in
  dev|all) ;;
  *) usage >&2; exit 1 ;;
esac

# shellcheck source=framework/dr-tests/lib/common.sh
source "$(dirname "$0")/../lib/common.sh"
drt_init
DRT_COVERAGE_LIST+=("scope: ${SCOPE} (PBS excluded)")

drt_check "validate.sh is green" framework/scripts/validate.sh
drt_check "git tree is clean" git diff --quiet HEAD
drt_check "PBS is reachable" \
  ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$(drt_vm_ip pbs)" true
drt_check "backup-now.sh exists" test -x framework/scripts/backup-now.sh
if [[ "$SCOPE" == all ]]; then
  echo "  Full-fleet operation: use a prod checkout; rebuild uses --override-branch-check."
fi

VMIDS=()
INVENTORY_RC=0
VMIDS_TEXT="$(drt_in_scope_vmids "$SCOPE")" || INVENTORY_RC=$?
drt_assert "In-scope VM inventory is available" test "$INVENTORY_RC" -eq 0
[[ "$DRT_FAILURES" -eq 0 ]] || drt_finish
while IFS= read -r vmid; do
  [[ -z "$vmid" ]] || VMIDS+=("$vmid")
done <<< "$VMIDS_TEXT"

# Reuse the existing precious-state inventory; intersect it with the exact
# recreation inventory so PBS/disabled VMs cannot enter the evidence set.
PRECIOUS_VMIDS=()
PRECIOUS_RC=0
PRECIOUS_ROWS="$(framework/scripts/list-backup-backed-vmids.sh --format tsv "$SCOPE")" || PRECIOUS_RC=$?
drt_assert "Backup-backed VM inventory is available" test "$PRECIOUS_RC" -eq 0
[[ "$DRT_FAILURES" -eq 0 ]] || drt_finish
while IFS=$'\t' read -r vmid _label _env; do
  for selected in "${VMIDS[@]}"; do
    [[ "$vmid" != "$selected" ]] || PRECIOUS_VMIDS+=("$vmid")
  done
done <<< "$PRECIOUS_ROWS"

drt_step "Capturing pre-test state fingerprint"
drt_fingerprint_state

drt_step "Taking pinned pre-test backup of all precious VMs"
rm -f "$PIN_FILE"
drt_assert "backup-now.sh succeeds and writes ${PIN_FILE}" \
  framework/scripts/backup-now.sh --pin-out "$PIN_FILE"
if [[ "$DRT_FAILURES" -gt 0 ]]; then
  echo "ABORT: Pre-test backup failed — cannot proceed with destructive test."
  echo "       Fix backup-now.sh and re-run."
  drt_finish
fi
# The pin must exist and cover every backup-backed VM in scope: without a
# pinned volid the dev park bridge refuses to park and the prod/shared preboot
# restore would fall back to an unpinned "latest" backup.
# $vmids/$vmid/$doc are jq variables, supplied by --arg and jq bindings.
# shellcheck disable=SC2016
drt_assert "Restore pin covers every backup-backed in-scope VMID" \
  jq -e --arg vmids "${PRECIOUS_VMIDS[*]+"${PRECIOUS_VMIDS[*]}"}" '
    . as $doc
    | ($doc.pins | type) == "object" and ($doc.pins | length) > 0
    and all($vmids | split(" ") | map(select(length > 0))[];
      . as $vmid | ($doc.pins[$vmid] | type) == "object" and (($doc.pins[$vmid].volid // "") | length) > 0)' \
  "$PIN_FILE"
if [[ "$DRT_FAILURES" -gt 0 ]]; then
  echo "ABORT: ${PIN_FILE} is missing, empty, or does not pin every precious VM."
  echo "       Nothing was destroyed. Fix backup-now.sh --pin-out and re-run."
  drt_finish
fi
DRT_COVERAGE_LIST+=("restore pin: ${PIN_FILE}")

drt_step "Capturing baseline VM disks across every configured node"
CAPTURE_RC=0
drt_capture_vm_disks "${VMIDS[@]}" || CAPTURE_RC=$?
drt_assert "Baseline disk evidence is complete" test "$CAPTURE_RC" -eq 0
[[ "$DRT_FAILURES" -eq 0 ]] || drt_finish

drt_step "Forcing recreation (${SCOPE})"
START=$(date +%s)
if [[ "$SCOPE" == dev ]]; then
  drt_assert "rebuild-cluster.sh completes successfully" \
    framework/scripts/rebuild-cluster.sh --recreate --scope env=dev --restore-pin-file "$PIN_FILE"
else
  drt_assert "rebuild-cluster.sh completes successfully" \
    framework/scripts/rebuild-cluster.sh --recreate --override-branch-check --restore-pin-file "$PIN_FILE"
fi
ELAPSED=$(( $(date +%s) - START ))
printf '  Rebuild took: %dm %ds\n' "$((ELAPSED / 60))" "$((ELAPSED % 60))"

drt_step "Verifying forced plan and deploy evidence"
EXPECTED_SCOPE=all
[[ "$SCOPE" != dev ]] || EXPECTED_SCOPE=env=dev
# $scope is a jq variable, supplied by --arg.
# shellcheck disable=SC2016
drt_assert "Deploy manifest records requested recreation scope" \
  jq -e --arg scope "$EXPECTED_SCOPE" '.recreate == true and .recreate_scope == $scope' build/rebuild-manifest.json
drt_assert "Bulk plan assertion records every expected replacement/create" \
  jq -e '(.expected | type) == "number" and .expected > 0 and .expected == .replacing
    and (.addresses | type) == "array" and (.addresses | length) == .expected' \
    build/recreate-plan-assert-bulk.json

drt_step "Validating cluster and precious state"
drt_assert "validate.sh passes after recreation" framework/scripts/validate.sh
drt_verify_state_fingerprint --strict
drt_verify_vm_recreated "$START" "${VMIDS[@]}"

if [[ "$SCOPE" == dev ]]; then
  if [[ "${#PRECIOUS_VMIDS[@]}" -gt 0 ]]; then
    drt_verify_vdb_guid_preserved "${PRECIOUS_VMIDS[@]}"
  fi
else
  # Phase files carry status (not outcome) and generated_at. Read only this
  # run's phases: a stale atomic file must not fill a hole in an empty bulk
  # summary (#518). Disk ground truth above remains the primary evidence.
  drt_assert "Every precious VM has current spared/restored preboot evidence" \
    python3 - "$START" "${PRECIOUS_VMIDS[@]+"${PRECIOUS_VMIDS[@]}"}" <<'PY'
import glob
import json
import sys
from datetime import datetime, timezone

since = int(sys.argv[1])
expected = set(sys.argv[2:])
observed = set()
paths = glob.glob("build/preboot-restore-status-atomic-*.json") + glob.glob("build/preboot-restore-status-bulk.json")
for path in paths:
    with open(path) as f:
        status = json.load(f)
    generated = datetime.strptime(status["generated_at"], "%Y-%m-%dT%H:%M:%SZ")
    if generated.replace(tzinfo=timezone.utc).timestamp() < since:
        continue
    for entry in status["entries"]:
        if entry.get("status") in {"spared", "restored"}:
            observed.add(str(entry["vmid"]))
if not observed or expected - observed:
    sys.exit("Missing current spared/restored evidence for VMIDs: " + ", ".join(sorted(expected - observed)) + " (empty artifacts also fail)")
print("Precious-state preboot evidence: " + ", ".join(sorted(expected)))
PY
fi

WARN_MINUTES=45
[[ "$SCOPE" != all ]] || WARN_MINUTES=120
if [[ "$ELAPSED" -gt $((WARN_MINUTES * 60)) ]]; then
  drt_warn "Recreation exceeded ${WARN_MINUTES} min for --scope ${SCOPE}"
fi
drt_finish
