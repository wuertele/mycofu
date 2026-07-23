#!/usr/bin/env bash
# test_rebuild_park_adopt.sh — Sprint 044 rebuild-cluster park/adopt choreography.
# shellcheck disable=SC2016

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"
LIB="${REPO_ROOT}/framework/scripts/vdb-park-lib.sh"

line_no() {
  local pattern="$1"
  grep -nF "$pattern" "$SCRIPT" | head -1 | cut -d: -f1 || true
}

line_no_after() {
  local pattern="$1"
  local after="$2"
  awk -v pat="$pattern" -v after="$after" 'NR > after && index($0, pat) { print NR; exit }' "$SCRIPT"
}

test_start "A5.a" "bulk path writes manifest, parks, applies stopped, adopts, then restores"
bulk_manifest_line="$(line_no 'write_preboot_manifest_for_modules "$BULK_MANIFEST" "$BULK_TARGETS" "$BULK_PLAN_JSON"')"
bulk_park_line="$(line_no 'vdb_park_batch "$BULK_MANIFEST" "$BULK_PARK_STATUS" all')"
bulk_apply_line="$(line_no '=== OpenTofu stopped apply ===')"
bulk_adopt_line="$(line_no 'vdb_adopt_batch "$BULK_PARK_STATUS"')"
bulk_restore_line="$(line_no 'run_preboot_restore_for_modules "bulk" "$BULK_TARGETS" "$BULK_PLAN_JSON" "$BULK_MANIFEST" "$BULK_PARK_STATUS"')"
if [[ -n "$bulk_manifest_line" && -n "$bulk_park_line" && -n "$bulk_apply_line" && -n "$bulk_adopt_line" && -n "$bulk_restore_line" ]] &&
   [[ "$bulk_manifest_line" -lt "$bulk_park_line" && "$bulk_park_line" -lt "$bulk_apply_line" ]] &&
   [[ "$bulk_apply_line" -lt "$bulk_adopt_line" && "$bulk_adopt_line" -lt "$bulk_restore_line" ]]; then
  test_pass "bulk choreography is manifest -> park -> stopped apply -> adopt -> restore"
else
  test_fail "bulk choreography ordering is incorrect"
  printf 'manifest=%s park=%s apply=%s adopt=%s restore=%s\n' \
    "$bulk_manifest_line" "$bulk_park_line" "$bulk_apply_line" "$bulk_adopt_line" "$bulk_restore_line" >&2
fi

test_start "A5.b" "atomic path parks before qm destroy and adopts before restore"
atomic_manifest_line="$(line_no 'write_preboot_manifest_for_modules "$ATOMIC_MANIFEST" "-target=${mod}" "$ATOMIC_PRECHECK_PLAN_JSON"')"
atomic_park_line="$(line_no 'vdb_park_batch "$ATOMIC_MANIFEST" "$ATOMIC_PARK_STATUS" all')"
atomic_destroy_line="$(line_no 'qm destroy ${VMID} --purge')"
atomic_apply_line="$(line_no 'Recreating ${mod_name} stopped with HA disabled')"
atomic_adopt_line="$(line_no 'vdb_adopt_batch "$ATOMIC_PARK_STATUS"')"
atomic_restore_line="$(line_no 'run_preboot_restore_for_modules "atomic-${mod_name}" "-target=${mod}" "$ATOMIC_PLAN_JSON" "$ATOMIC_MANIFEST" "$ATOMIC_PARK_STATUS"')"
if [[ -n "$atomic_manifest_line" && -n "$atomic_park_line" && -n "$atomic_destroy_line" && -n "$atomic_apply_line" && -n "$atomic_adopt_line" && -n "$atomic_restore_line" ]] &&
   [[ "$atomic_manifest_line" -lt "$atomic_park_line" && "$atomic_park_line" -lt "$atomic_destroy_line" ]] &&
   [[ "$atomic_destroy_line" -lt "$atomic_apply_line" && "$atomic_apply_line" -lt "$atomic_adopt_line" && "$atomic_adopt_line" -lt "$atomic_restore_line" ]]; then
  test_pass "atomic choreography is precheck manifest -> park -> destroy -> stopped apply -> adopt -> restore"
else
  test_fail "atomic choreography ordering is incorrect"
  printf 'manifest=%s park=%s destroy=%s apply=%s adopt=%s restore=%s\n' \
    "$atomic_manifest_line" "$atomic_park_line" "$atomic_destroy_line" "$atomic_apply_line" "$atomic_adopt_line" "$atomic_restore_line" >&2
fi

test_start "A5.c" "shared/prod remain no-op when vdb_park_bridge flag is absent"
if grep -Fq 'if ! vdb_park_env_enabled "$env"; then' "$LIB" &&
   grep -Fq 'vdb park bridge disabled for env ${env}; using restore path' "$LIB" &&
   grep -Fq 'vdb_park_status_init "$status_file" "$scope"' "$LIB" &&
   grep -Fq 'No eligible vdb park entries for ${scope}' "$LIB"; then
  test_pass "bridge calls are gated by explicit env flag and no eligible entries remain a no-op"
else
  test_fail "bridge no-op gating contract is missing"
fi

test_start "A5.d" "restore helper passes park-status artifact through"
helper_status_line="$(line_no 'local park_status_file="${5:-${LOG_DIR}/vdb-park-status-${label}.json}"')"
helper_arg_line="$(line_no 'args+=(--park-status "$park_status_file")')"
restore_call_after_helper="$(line_no_after '"${SCRIPT_DIR}/restore-before-start.sh" "${args[@]}"' "$helper_arg_line")"
if [[ -n "$helper_status_line" && -n "$helper_arg_line" && -n "$restore_call_after_helper" ]] &&
   [[ "$helper_status_line" -lt "$helper_arg_line" && "$helper_arg_line" -lt "$restore_call_after_helper" ]]; then
  test_pass "run_preboot_restore_for_modules forwards park-status"
else
  test_fail "restore helper does not forward park-status"
  printf 'status=%s arg=%s restore=%s\n' "$helper_status_line" "$helper_arg_line" "$restore_call_after_helper" >&2
fi

test_start "A5.d2" "manifest builder records plan data-disk metadata and pin trust"
if grep -Fq 'def data_disk_info(change):' "$SCRIPT" &&
   grep -Fq 'if disk.get("interface") != "scsi1":' "$SCRIPT" &&
   grep -Fq 'entry.update(data_disk_info(change))' "$SCRIPT" &&
   grep -Fq 'entry["pin_trust"] = pin.get("trust", "unknown")' "$SCRIPT" &&
   grep -Fq 'VDB_PARK_PIN_FILE="$RESTORE_PIN_FILE" vdb_park_batch' "$SCRIPT"; then
  test_pass "rebuild manifests carry scsi1 size/slot metadata and pin trust"
else
  test_fail "rebuild manifest data-disk or pin-trust threading is missing"
fi

test_start "A5.e" "adopt failures are captured before restore fallback"
atomic_capture_line="$(line_no_after 'ADOPT_RC=$?' "$atomic_adopt_line")"
atomic_warning_line="$(line_no_after 'vdb_adopt_batch returned rc=${ADOPT_RC}; continuing to preboot restore' "$atomic_capture_line")"
bulk_capture_line="$(line_no_after 'ADOPT_RC=$?' "$bulk_adopt_line")"
bulk_warning_line="$(line_no_after 'vdb_adopt_batch returned rc=${ADOPT_RC}; continuing to preboot restore' "$bulk_capture_line")"
if [[ -n "$atomic_capture_line" && -n "$atomic_warning_line" && -n "$bulk_capture_line" && -n "$bulk_warning_line" ]] &&
   [[ "$atomic_adopt_line" -lt "$atomic_capture_line" && "$atomic_warning_line" -lt "$atomic_restore_line" ]] &&
   [[ "$bulk_adopt_line" -lt "$bulk_capture_line" && "$bulk_warning_line" -lt "$bulk_restore_line" ]]; then
  test_pass "atomic and bulk adopt failures continue into restore fallback"
else
  test_fail "rebuild adopt rc capture contract is missing"
  printf 'atomic_adopt=%s atomic_capture=%s atomic_warning=%s atomic_restore=%s bulk_adopt=%s bulk_capture=%s bulk_warning=%s bulk_restore=%s\n' \
    "$atomic_adopt_line" "$atomic_capture_line" "$atomic_warning_line" "$atomic_restore_line" \
    "$bulk_adopt_line" "$bulk_capture_line" "$bulk_warning_line" "$bulk_restore_line" >&2
fi

runner_summary
