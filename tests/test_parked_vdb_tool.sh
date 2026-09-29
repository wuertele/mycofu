#!/usr/bin/env bash
# test_parked_vdb_tool.sh — Sprint 044 parked-vdb operator tool fixture.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"
# shellcheck source=tests/lib/vdb_park_fixture.sh
source "${REPO_ROOT}/tests/lib/vdb_park_fixture.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

run_tool() {
  set +e
  OUT="$(vdb_fixture_run_cmd "${VDB_FIXTURE_REPO}/framework/scripts/parked-vdb.sh" "$@" 2>&1)"
  RC=$?
  set -e
}

make_park_with_healthy_vm() {
  vdb_fixture_create_dataset pve01 vmstore/data/mycofu-park-101-vdb guid-park-101 50G
  vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:orig-volname vm-101-disk-0
  vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:slot scsi1
  vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:drive-options "backup=1,replicate=1"
  vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:guid guid-park-101
  vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:pin-volid pbs:backup/vm/101/pin
  vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:parked-at "2026-07-05T00:00:00Z"
  vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 guid-canonical-101 50G
  vdb_fixture_set_vm pve01 101 running $'scsi1: vmstore:vm-101-disk-0,backup=1,replicate=1'
}

test_start "A7.a" "list enumerates parks and empty cluster is clean"
vdb_fixture_make
make_park_with_healthy_vm
run_tool --list --format json
if [[ "$RC" -eq 0 ]] &&
   jq -e 'length == 1 and .[0].vmid == 101 and .[0].node == "pve01" and .[0].properties["mycofu:orig-volname"] == "vm-101-disk-0"' <<< "$OUT" >/dev/null; then
  test_pass "--list --format json reports parked dataset identity"
else
  test_fail "--list json output did not include the park"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

vdb_fixture_make
run_tool --list
if [[ "$RC" -eq 0 ]] && grep -Fq "No parked vdb zvols found" <<< "$OUT"; then
  test_pass "empty cluster lists cleanly"
else
  test_fail "empty list did not report clean state"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

test_start "A7.b" "inspect emits park state, user properties, live slot map, and canonical state"
vdb_fixture_make
make_park_with_healthy_vm
run_tool inspect 101
if [[ "$RC" -eq 0 ]] &&
   jq -e '.found == true
          and .park.dataset == "vmstore/data/mycofu-park-101-vdb"
          and .park.properties["mycofu:pin-volid"] == "pbs:backup/vm/101/pin"
          and .live.canonical_zvol_state == "present"
          and .live.attached_vdb_health == "attached"
          and (.live.slot_map[] | contains("scsi1: vmstore:vm-101-disk-0"))' <<< "$OUT" >/dev/null; then
  test_pass "inspect output is parseable and complete"
else
  test_fail "inspect output missing identity details"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

test_start "A7.c" "release refuses unsafe states and dry-run destroys nothing"
vdb_fixture_make
make_park_with_healthy_vm
vdb_fixture_set_vm pve01 101 running $'scsi0: vmstore:vm-101-disk-1,size=4G'
run_tool release 101
if [[ "$RC" -ne 0 ]] && grep -Fq "healthy canonical vdb is not attached" <<< "$OUT"; then
  test_pass "release refuses without healthy canonical vdb"
else
  test_fail "release allowed missing canonical vdb"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

vdb_fixture_make
make_park_with_healthy_vm
vdb_fixture_set_vm pve01 999 running $'unused0: vmstore:mycofu-park-101-vdb'
run_tool release 101
if [[ "$RC" -ne 0 ]] && grep -Fq "still referenced" <<< "$OUT"; then
  test_pass "release refuses when park is referenced by any VM config"
else
  test_fail "release allowed referenced park"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

vdb_fixture_make
make_park_with_healthy_vm
run_tool release 101 --dry-run
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "DRY-RUN" <<< "$OUT" &&
   [[ -d "$(vdb_fixture_dataset_path pve01 vmstore/data/mycofu-park-101-vdb)" ]] &&
   ! grep -Fq "zfs destroy" "$VDB_EVENT_LOG"; then
  test_pass "release --dry-run leaves park intact"
else
  test_fail "release --dry-run mutated state"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

test_start "A7.d" "happy release destroys exactly the park dataset"
vdb_fixture_make
make_park_with_healthy_vm
run_tool release 101
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "loss of all writes newer than pin pbs:backup/vm/101/pin" <<< "$OUT" &&
   grep -Fq "zfs destroy vmstore/data/mycofu-park-101-vdb" "$VDB_EVENT_LOG" &&
   [[ ! -d "$(vdb_fixture_dataset_path pve01 vmstore/data/mycofu-park-101-vdb)" ]] &&
   [[ -d "$(vdb_fixture_dataset_path pve01 vmstore/data/vm-101-disk-0)" ]]; then
  test_pass "release destroys only the parked dataset"
else
  test_fail "happy release failed"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

test_start "A7.e" "park scan failure exits non-zero"
vdb_fixture_make
touch "${VDB_FIXTURE_STATE}/scan-fail-pve01"
run_tool --list --format json
if [[ "$RC" -ne 0 ]] && grep -Fq "failed to scan parked vdb zvols on pve01" <<< "$OUT"; then
  test_pass "scan failure fails closed"
else
  test_fail "scan failure did not fail closed"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

vdb_fixture_make
make_park_with_healthy_vm
touch "${VDB_FIXTURE_STATE}/reference-scan-fail-pve01"
run_tool release 101
if [[ "$RC" -ne 0 ]] && grep -Fq "could not verify park mycofu-park-101-vdb is unreferenced" <<< "$OUT"; then
  test_pass "release refuses when VM config reference scan fails"
else
  test_fail "release reference scan failure did not fail closed"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

vdb_fixture_make
make_park_with_healthy_vm
touch "${VDB_FIXTURE_STATE}/reference-qm-list-fail-pve01"
run_tool release 101
if [[ "$RC" -ne 0 ]] && grep -Fq "could not verify park mycofu-park-101-vdb is unreferenced" <<< "$OUT"; then
  test_pass "release refuses when qm list fails during reference scan"
else
  test_fail "release qm list failure did not fail closed"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

vdb_fixture_make
make_park_with_healthy_vm
touch "${VDB_FIXTURE_STATE}/reference-config-fail-pve01"
run_tool release 101
if [[ "$RC" -ne 0 ]] && grep -Fq "could not verify park mycofu-park-101-vdb is unreferenced" <<< "$OUT"; then
  test_pass "release refuses when a qm config scan fails"
else
  test_fail "release qm config failure did not fail closed"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

runner_summary
