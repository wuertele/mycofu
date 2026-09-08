#!/usr/bin/env bash
# test_vdb_park_lib.sh — Sprint 044 vdb park/adopt primitive fixtures.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"
# shellcheck source=tests/lib/vdb_park_fixture.sh
source "${REPO_ROOT}/tests/lib/vdb_park_fixture.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

make_base_vm() {
  vdb_fixture_set_vm pve01 101 running $'scsi0: vmstore:vm-101-disk-1,size=4G\nscsi1: vmstore:vm-101-disk-0,size=50G,discard=on,iothread=1,replicate=1,backup=1'
  vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 guid-data-101 50G same-hash-101
  vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-1 guid-os-101 4G os-hash-101
}

write_manifest_one() {
  local entry
  entry="$(vdb_fixture_entry app_dev 101 dev 50 "${1:-pbs:backup/vm/101/pin}" "${2:-trusted}")"
  vdb_fixture_manifest "${VDB_FIXTURE_REPO}/build/preboot.json" "$entry"
}

run_park() {
  local manifest="${VDB_FIXTURE_REPO}/build/preboot.json"
  local status="${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json"
  set +e
  OUT="$(vdb_fixture_run_lib "vdb_park_batch '$manifest' '$status' dev" 2>&1)"
  RC=$?
  set -e
}

run_adopt() {
  local status="${1:-${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json}"
  local mode="${2:-}"
  set +e
  OUT="$(vdb_fixture_run_lib "vdb_adopt_batch '$status' $mode" 2>&1)"
  RC=$?
  set -e
}

event_line() {
  local pattern="$1"
  grep -nF "$pattern" "$VDB_EVENT_LOG" | head -1 | cut -d: -f1
}

test_start "A1.a/h/j" "park records live state, user properties, replication ordering, and pin trust"
vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one "pbs:backup/vm/101/pin" "untrusted"
run_park
if [[ "$RC" -eq 0 ]] &&
   jq -e '.entries[0].status == "parked"
          and .entries[0].volname == "vm-101-disk-0"
          and .entries[0].slot == "scsi1"
          and .entries[0].drive_options == "discard=on,iothread=1,replicate=1,backup=1"
          and .entries[0].guid == "guid-data-101"
          and .entries[0].pin_trust == "untrusted"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   grep -Fq "restore pin pbs:backup/vm/101/pin is marked untrusted" <<< "$OUT" &&
   grep -Fq "zfs set mycofu:orig-volname vmstore/data/mycofu-park-101-vdb" "$VDB_EVENT_LOG" &&
   [[ "$(event_line "pvesh disable 101-0 1")" -lt "$(event_line "qm delete 101 scsi1")" ]]; then
  test_pass "park captured options before detach, set self-describing props, and disabled replication first"
else
  test_fail "happy park or pin-trust behavior failed"
  printf 'rc=%s\nout=%s\nevents=\n%s\nstatus=\n%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" 2>/dev/null || true)" >&2
fi

test_start "A1.b" "vdb discovery anchors on slot and cross-checks size"
vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
vdb_fixture_set_vm pve01 101 running $'scsi0: vmstore:vm-101-disk-0,size=4G\nscsi1: vmstore:vm-101-disk-1,size=50G,discard=on,backup=1'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 guid-os-flipped 4G
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-1 guid-data-flipped 50G
write_manifest_one
run_park
if [[ "$RC" -eq 0 ]] &&
   jq -e '.entries[0].volname == "vm-101-disk-1" and .entries[0].slot == "scsi1"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null; then
  test_pass "flipped disk-N names still park the 50G data disk"
else
  test_fail "flipped disk-N discovery failed"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
vdb_fixture_set_vm pve01 101 running $'scsi0: vmstore:vm-101-disk-1,size=50G\nscsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 guid-data 50G
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-1 guid-os 50G
write_manifest_one
run_park
if [[ "$RC" -ne 0 ]] && grep -Fq "ambiguous vdb candidates" <<< "$OUT"; then
  test_pass "equal-size ambiguity aborts before destroy"
else
  test_fail "equal-size ambiguity did not abort"
  printf 'rc=%s\nout=%s\n' "$RC" "$OUT" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
vdb_fixture_set_vm pve01 101 running $'scsi0: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 guid-data 50G
write_manifest_one
run_park
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "expected vdb slot scsi1 is missing" <<< "$OUT" &&
   grep -Fq "pvesh disable 101-0 0" "$VDB_EVENT_LOG" &&
   grep -Fq "qm start 101" "$VDB_EVENT_LOG" &&
   jq -e '.entries[0].status == "unparked"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null; then
  test_pass "missing slot aborts and reverses the already-prepared VM"
else
  test_fail "missing slot rollback behavior failed"
  printf 'rc=%s\nout=%s\nevents=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" 2>/dev/null || true)" >&2
fi

test_start "A1.c/e" "env and vendor gates degrade to restore path without mutations"
vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
prod_entry="$(vdb_fixture_entry app_prod 201 prod 50)"
shared_entry="$(vdb_fixture_entry shared_app 301 shared 50)"
vendor_entry="$(vdb_fixture_entry vendor_dev 401 dev 50)"
vdb_fixture_manifest "${VDB_FIXTURE_REPO}/build/preboot.json" "$prod_entry" "$shared_entry" "$vendor_entry"
run_park
if [[ "$RC" -eq 0 ]] &&
   [[ ! -s "$VDB_EVENT_LOG" ]] &&
   jq -e '.entries | length == 0' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null; then
  test_pass "disabled envs and vendor class produce no qm/zfs mutations"
else
  test_fail "env/vendor gate mutated state"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
printf '{"version":1,"scope":"dev","entries":[{"vmid":101,"status":"adopted","label":"old-adopted"},{"vmid":102,"status":"parked","label":"active-park"}]}\n' > "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json"
prod_entry="$(vdb_fixture_entry app_prod 201 prod 50)"
vdb_fixture_manifest "${VDB_FIXTURE_REPO}/build/preboot.json" "$prod_entry"
run_park
if [[ "$RC" -eq 0 ]] &&
   jq -e '(.entries | length == 1) and .entries[0].vmid == 102 and .entries[0].status == "parked"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null; then
  test_pass "normal status init prunes stale terminal entries but preserves active parks"
else
  test_fail "normal status init did not scope old terminal entries out"
  printf 'rc=%s\nout=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" 2>/dev/null || true)" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
export STUB_VM_SCOPE_UNKNOWN=1
run_park
unset STUB_VM_SCOPE_UNKNOWN
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "VM class category is unverifiable" <<< "$OUT" &&
   [[ ! -s "$VDB_EVENT_LOG" ]] &&
   jq -e '.entries | length == 0' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null; then
  test_pass "unknown class degrades to restore path without mutation"
else
  test_fail "unknown class did not degrade safely"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

test_start "A1.d" "unverified qemu-server version skips bridge with rerun warning"
vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
echo "9.2.1" > "${VDB_FIXTURE_STATE}/version/pve01"
write_manifest_one
run_park
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "qemu-server 9.2.1" <<< "$OUT" &&
   grep -Fq "RESEARCH-004 gated experiment" <<< "$OUT" &&
   [[ ! -s "$VDB_EVENT_LOG" ]]; then
  test_pass "version ratchet degrades to off with loud warning"
else
  test_fail "version ratchet behavior failed"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

test_start "A1.f/j/k" "placement drift, missing pin, and park collision abort before mutation"
vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
touch "${VDB_FIXTURE_STATE}/cluster-resources-fail"
write_manifest_one
run_park
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "cannot determine whether VMID 101 exists" <<< "$OUT" &&
   [[ ! -s "$VDB_EVENT_LOG" ]]; then
  test_pass "cluster query failure hard-stops before mutation"
else
  test_fail "cluster query failure did not fail closed"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
vdb_fixture_set_vm pve02 101 running $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve02 vmstore/data/vm-101-disk-0 guid-data 50G
write_manifest_one
run_park
if [[ "$RC" -ne 0 ]] && grep -Fq "expected pve01" <<< "$OUT" && [[ ! -s "$VDB_EVENT_LOG" ]]; then
  test_pass "placement drift hard-stops before mutation"
else
  test_fail "placement drift did not fail closed"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
missing_pin_entry="$(jq 'del(.pin)' <<< "$(vdb_fixture_entry app_dev 101 dev 50)")"
vdb_fixture_manifest "${VDB_FIXTURE_REPO}/build/preboot.json" "$missing_pin_entry"
run_park
if [[ "$RC" -ne 0 ]] && grep -Fq "missing restore pin" <<< "$OUT" && [[ ! -s "$VDB_EVENT_LOG" ]]; then
  test_pass "missing pin aborts before any mutation"
else
  test_fail "missing pin gate failed"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
vdb_fixture_create_dataset pve01 vmstore/data/mycofu-park-101-vdb stale-guid 50G
write_manifest_one
run_park
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "parked-vdb.sh inspect 101" <<< "$OUT" &&
   grep -Fq "parked-vdb.sh release 101" <<< "$OUT" &&
   ! grep -Eq "qm delete|zfs rename|zfs set|qm attach|pvesh disable" "$VDB_EVENT_LOG"; then
  test_pass "park collision refuses with sanctioned commands"
else
  test_fail "park collision guard failed"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
touch "${VDB_FIXTURE_STATE}/zfs-exists-fail-pve01"
write_manifest_one
run_park
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "cannot verify park-collision state" <<< "$OUT" &&
   ! grep -Eq "qm stop|qm delete|zfs rename|zfs set|qm attach|pvesh disable" "$VDB_EVENT_LOG"; then
  test_pass "park-collision query failure aborts before mutation"
else
  test_fail "park-collision query failure did not fail closed"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

test_start "A1.g/i" "stop loop reissues stop and batch failure unparks prior VMs in reverse"
vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
touch "${VDB_FIXTURE_STATE}/stop-sticky-101"
write_manifest_one
set +e
OUT="$(PATH="${VDB_FIXTURE_SHIMS}:${PATH}" REAL_YQ_BIN="$REAL_YQ_BIN" VDB_FIXTURE_STATE="$VDB_FIXTURE_STATE" VDB_EVENT_LOG="$VDB_EVENT_LOG" VDB_PARK_STOP_TIMEOUT=2 VDB_PARK_STOP_INTERVAL=1 bash -c "cd '$VDB_FIXTURE_REPO' && source framework/scripts/vdb-park-lib.sh && vdb_park_batch build/preboot.json build/vdb-park-status-dev.json dev" 2>&1)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]] && [[ "$(grep -c 'qm stop 101' "$VDB_EVENT_LOG")" -gt 1 ]]; then
  test_pass "stop verification loop reissues qm stop before abort"
else
  test_fail "stop loop did not reissue stop"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
vdb_fixture_set_vm pve01 102 running $'scsi0: vmstore:vm-102-disk-1,size=4G\nscsi1: vmstore:vm-102-disk-0,size=20G,backup=1'
vdb_fixture_create_dataset pve01 vmstore/data/vm-102-disk-0 guid-data-102 20G
vdb_fixture_create_dataset pve01 vmstore/data/vm-102-disk-1 guid-os-102 4G
entry1="$(vdb_fixture_entry app_dev 101 dev 50)"
entry2="$(vdb_fixture_entry app2_dev 102 dev 20)"
vdb_fixture_manifest "${VDB_FIXTURE_REPO}/build/preboot.json" "$entry1" "$entry2"
set +e
OUT="$(PATH="${VDB_FIXTURE_SHIMS}:${PATH}" REAL_YQ_BIN="$REAL_YQ_BIN" VDB_FIXTURE_STATE="$VDB_FIXTURE_STATE" VDB_EVENT_LOG="$VDB_EVENT_LOG" STUB_RENAME_FAIL_NEW="mycofu-park-102-vdb" bash -c "cd '$VDB_FIXTURE_REPO' && source framework/scripts/vdb-park-lib.sh && vdb_park_batch build/preboot.json build/vdb-park-status-dev.json dev" 2>&1)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "zfs rename vmstore/data/mycofu-park-101-vdb vmstore/data/vm-101-disk-0" "$VDB_EVENT_LOG" &&
   grep -Fq "qm attach 101 scsi1 vmstore:vm-101-disk-0" "$VDB_EVENT_LOG" &&
   grep -Fq "pvesh disable 101-0 0" "$VDB_EVENT_LOG" &&
   grep -Fq "qm start 101" "$VDB_EVENT_LOG"; then
  test_pass "park failure unparks prior parked VM"
else
  test_fail "reverse unpark on batch failure failed"
  printf 'rc=%s\nout=%s\nevents=\n%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
run_park
vdb_fixture_reset_log
set +e
OUT="$(PATH="${VDB_FIXTURE_SHIMS}:${PATH}" REAL_YQ_BIN="$REAL_YQ_BIN" VDB_FIXTURE_STATE="$VDB_FIXTURE_STATE" VDB_EVENT_LOG="$VDB_EVENT_LOG" STUB_RENAME_FAIL_NEW="vm-101-disk-0" bash -c "cd '$VDB_FIXTURE_REPO' && source framework/scripts/vdb-park-lib.sh && vdb_unpark_batch build/vdb-park-status-dev.json" 2>&1)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]] &&
   jq -e '.entries[0].status == "unpark-failed"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   grep -Fq "zfs rename vmstore/data/mycofu-park-101-vdb vmstore/data/vm-101-disk-0" "$VDB_EVENT_LOG" &&
   ! grep -Fq "qm start 101" "$VDB_EVENT_LOG"; then
  test_pass "unpark rename failure records unpark-failed and stops before start"
else
  test_fail "unpark rename failure was not loud"
  printf 'rc=%s\nout=%s\nevents=\n%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" 2>/dev/null || true)" >&2
fi

test_start "A2.a/g" "adopt verifies park existence before freeing fresh vdb and checks fingerprint"
vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
set +e
OUT="$(PATH="${VDB_FIXTURE_SHIMS}:${PATH}" REAL_YQ_BIN="$REAL_YQ_BIN" VDB_FIXTURE_STATE="$VDB_FIXTURE_STATE" VDB_EVENT_LOG="$VDB_EVENT_LOG" VDB_PARK_FINGERPRINT=full bash -c "cd '$VDB_FIXTURE_REPO' && source framework/scripts/vdb-park-lib.sh && vdb_park_batch build/preboot.json build/vdb-park-status-dev.json dev" 2>&1)"
RC=$?
set -e
vdb_fixture_set_vm pve01 101 stopped $'scsi0: vmstore:vm-101-disk-1,size=4G\nscsi1: vmstore:vm-101-disk-0,size=50G,discard=on,iothread=1,replicate=1,backup=1'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G fresh-hash
vdb_fixture_reset_log
run_adopt
if [[ "$RC" -eq 0 ]] &&
   jq -e '.entries[0].status == "adopted" and .entries[0].fingerprint.park_sha256 == "same-hash-101"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   [[ "$(event_line "zfs list vmstore/data/mycofu-park-101-vdb")" -lt "$(event_line "qm delete 101 scsi1")" ]] &&
   [[ "$(event_line "zfs rename vmstore/data/mycofu-park-101-vdb vmstore/data/vm-101-disk-0")" -gt "$(event_line "qm delete 101 unused0")" ]] &&
   grep -Fq "zfs inherit mycofu:orig-volname vmstore/data/vm-101-disk-0" "$VDB_EVENT_LOG"; then
  test_pass "adopt frees fresh vdb after park check, renames back, reattaches, clears props, verifies fingerprint"
else
  test_fail "happy adopt failed"
  printf 'rc=%s\nout=%s\nevents=\n%s\nstatus=\n%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json")" >&2
fi

test_start "A2.b/c" "park-lost keeps fresh vdb; reattach failure un-renames and allocates restore target"
vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
run_park
rm -rf "$(vdb_fixture_dataset_path pve01 vmstore/data/mycofu-park-101-vdb)"
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G
vdb_fixture_reset_log
run_adopt
if [[ "$RC" -ne 0 ]] &&
   jq -e '.entries[0].status == "park-lost"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   ! grep -Fq "qm delete 101 scsi1" "$VDB_EVENT_LOG"; then
  test_pass "park-lost fails before touching fresh restore target"
else
  test_fail "park-lost ordering failed"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
run_park
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G
touch "${VDB_FIXTURE_STATE}/attach-fail-once-101"
vdb_fixture_reset_log
run_adopt
if [[ "$RC" -ne 0 ]] &&
   jq -e '.entries[0].status == "adopt-failed"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   grep -Fq "zfs rename vmstore/data/vm-101-disk-0 vmstore/data/mycofu-park-101-vdb" "$VDB_EVENT_LOG" &&
   grep -Fq "pvesm alloc vmstore 101 vm-101-disk-0 50G" "$VDB_EVENT_LOG" &&
   ! grep -Fq "zfs destroy vmstore/data/mycofu-park-101-vdb" "$VDB_EVENT_LOG"; then
  test_pass "reattach failure returns volume to park name and allocates empty target"
else
  test_fail "adopt-failure fallback failed"
  printf 'rc=%s\nout=%s\nevents=\n%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
run_park
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G
touch "${VDB_FIXTURE_STATE}/attach-fail-101"
vdb_fixture_reset_log
set +e
OUT="$(PATH="${VDB_FIXTURE_SHIMS}:${PATH}" REAL_YQ_BIN="$REAL_YQ_BIN" VDB_FIXTURE_STATE="$VDB_FIXTURE_STATE" VDB_EVENT_LOG="$VDB_EVENT_LOG" STUB_RENAME_FAIL_NEW="mycofu-park-101-vdb" bash -c "cd '$VDB_FIXTURE_REPO' && source framework/scripts/vdb-park-lib.sh && vdb_adopt_batch build/vdb-park-status-dev.json" 2>&1)"
RC=$?
set -e
if [[ "$RC" -ne 0 ]] &&
   jq -e '.entries[0].status == "adopt-cleanup-failed"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   grep -Fq "zfs rename vmstore/data/vm-101-disk-0 vmstore/data/mycofu-park-101-vdb" "$VDB_EVENT_LOG" &&
   ! grep -Fq "pvesm alloc vmstore 101 vm-101-disk-0 50G" "$VDB_EVENT_LOG"; then
  test_pass "rename-back cleanup failure records distinct fail-closed status"
else
  test_fail "rename-back cleanup failure was not distinguished"
  printf 'rc=%s\nout=%s\nevents=\n%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" 2>/dev/null || true)" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
run_park
jq '(.entries[] | select(.vmid == 101) | .guid) = "wrong-recorded-guid"' \
  "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" > "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json.tmp"
mv "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json.tmp" "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json"
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G
vdb_fixture_reset_log
run_adopt
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "adopt verification failed" <<< "$OUT" &&
   jq -e '.entries[0].status == "adopt-failed"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   grep -Fq "zfs rename vmstore/data/vm-101-disk-0 vmstore/data/mycofu-park-101-vdb" "$VDB_EVENT_LOG" &&
   grep -Fq "pvesm alloc vmstore 101 vm-101-disk-0 50G" "$VDB_EVENT_LOG"; then
  test_pass "post-rename verification failure returns volume to park name"
else
  test_fail "post-rename verification failure did not preserve park"
  printf 'rc=%s\nout=%s\nevents=\n%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
set +e
OUT="$(PATH="${VDB_FIXTURE_SHIMS}:${PATH}" REAL_YQ_BIN="$REAL_YQ_BIN" VDB_FIXTURE_STATE="$VDB_FIXTURE_STATE" VDB_EVENT_LOG="$VDB_EVENT_LOG" VDB_PARK_FINGERPRINT=full bash -c "cd '$VDB_FIXTURE_REPO' && source framework/scripts/vdb-park-lib.sh && vdb_park_batch build/preboot.json build/vdb-park-status-dev.json dev" 2>&1)"
RC=$?
set -e
printf '%s\n' "changed-hash-101" > "$(vdb_fixture_dataset_path pve01 vmstore/data/mycofu-park-101-vdb)/sha256"
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G fresh-hash
vdb_fixture_reset_log
run_adopt
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "adopt fingerprint verification failed" <<< "$OUT" &&
   jq -e '.entries[0].status == "adopt-failed"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   grep -Fq "zfs rename vmstore/data/vm-101-disk-0 vmstore/data/mycofu-park-101-vdb" "$VDB_EVENT_LOG" &&
   grep -Fq "pvesm alloc vmstore 101 vm-101-disk-0 50G" "$VDB_EVENT_LOG"; then
  test_pass "post-rename fingerprint mismatch returns volume to park name"
else
  test_fail "post-rename fingerprint mismatch did not preserve park"
  printf 'rc=%s\nout=%s\nevents=\n%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json")" >&2
fi

test_start "A2.d/e/f" "recovery idempotence, partial adopt failure, and reconstruction from user properties"
vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
run_park
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G
run_adopt
vdb_fixture_reset_log
run_adopt "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" "--recovery-mode"
if [[ "$RC" -eq 0 ]] && [[ ! -s "$VDB_EVENT_LOG" || "$(grep -c 'zfs rename' "$VDB_EVENT_LOG" || true)" == "0" ]]; then
  test_pass "already-adopted recovery verifies without mutation"
else
  test_fail "adopted idempotence failed"
  printf 'rc=%s\nout=%s\nevents=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
vdb_fixture_set_vm pve01 102 running $'scsi1: vmstore:vm-102-disk-0,size=20G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-102-disk-0 guid-data-102 20G
entry1="$(vdb_fixture_entry app_dev 101 dev 50)"
entry2="$(vdb_fixture_entry app2_dev 102 dev 20)"
vdb_fixture_manifest "${VDB_FIXTURE_REPO}/build/preboot.json" "$entry1" "$entry2"
run_park
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G
vdb_fixture_set_vm pve01 102 stopped $'scsi1: vmstore:vm-102-disk-0,size=20G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-102-disk-0 fresh-guid-102 20G
touch "${VDB_FIXTURE_STATE}/attach-fail-once-102"
run_adopt
if [[ "$RC" -ne 0 ]] &&
   jq -e '([.entries[] | select(.vmid == 101)][0].status == "adopted") and ([.entries[] | select(.vmid == 102)][0].status == "adopt-failed")' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null; then
  test_pass "multi-VM adopt continues after one VM failure"
else
  test_fail "multi-VM adopt failure behavior failed"
  printf 'rc=%s\nout=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
run_park
vdb_fixture_set_vm pve01 101 running $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G
vdb_fixture_reset_log
run_adopt
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "is not stopped before adopt" <<< "$OUT" &&
   jq -e '.entries[0].status == "adopt-failed"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   ! grep -Fq "qm delete 101 scsi1" "$VDB_EVENT_LOG"; then
  test_pass "adopt refuses to free a fresh target while the VM is running"
else
  test_fail "running-VM adopt guard failed"
  printf 'rc=%s\nout=%s\nevents=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
make_base_vm
write_manifest_one
run_park
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 guid-data-101 50G
vdb_fixture_reset_log
run_adopt
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "already has parked GUID" <<< "$OUT" &&
   jq -e '.entries[0].status == "adopt-failed"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   ! grep -Fq "qm delete 101 scsi1" "$VDB_EVENT_LOG"; then
  test_pass "adopt verifies the fresh provider target before deleting it"
else
  test_fail "fresh-target adopt guard failed"
  printf 'rc=%s\nout=%s\nevents=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
vdb_park_status='{"version":1,"scope":"dev","entries":[]}'
printf '%s\n' "$vdb_park_status" > "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json"
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G
vdb_fixture_create_dataset pve01 vmstore/data/mycofu-park-101-vdb guid-data-101 50G
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:orig-volname vm-101-disk-0
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:slot scsi1
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:drive-options backup=1
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:guid guid-data-101
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:pin-volid pbs:backup/vm/101/pin
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:parked-at "2026-07-05T00:00:00Z"
run_adopt "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" "--recovery-mode"
if [[ "$RC" -eq 0 ]] &&
   jq -e '.entries[0].status == "adopted" and .entries[0].detail == "adopted parked vdb guid guid-data-101"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null; then
  test_pass "recovery-mode reconstructs and adopts from ZFS user properties"
else
  test_fail "recovery reconstruction failed"
  printf 'rc=%s\nout=%s\nevents=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
vdb_park_status='{"version":1,"scope":"dev","entries":[]}'
printf '%s\n' "$vdb_park_status" > "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json"
entry1="$(vdb_fixture_entry app_dev 101 dev 50)"
vdb_fixture_manifest "${VDB_FIXTURE_REPO}/build/preboot.json" "$entry1"
vdb_fixture_set_vm pve01 101 stopped $'scsi1: vmstore:vm-101-disk-0,size=50G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 fresh-guid-101 50G
vdb_fixture_create_dataset pve01 vmstore/data/mycofu-park-101-vdb guid-data-101 50G
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:orig-volname vm-101-disk-0
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:slot scsi1
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:drive-options backup=1
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:guid guid-data-101
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:pin-volid pbs:backup/vm/101/pin
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-101-vdb mycofu:parked-at "2026-07-05T00:00:00Z"
vdb_fixture_set_vm pve01 102 stopped $'scsi1: vmstore:vm-102-disk-0,size=20G'
vdb_fixture_create_dataset pve01 vmstore/data/vm-102-disk-0 fresh-guid-102 20G
vdb_fixture_create_dataset pve01 vmstore/data/mycofu-park-102-vdb guid-data-102 20G
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-102-vdb mycofu:orig-volname vm-102-disk-0
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-102-vdb mycofu:slot scsi1
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-102-vdb mycofu:drive-options backup=1
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-102-vdb mycofu:guid guid-data-102
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-102-vdb mycofu:pin-volid pbs:backup/vm/102/pin
vdb_fixture_set_prop pve01 vmstore/data/mycofu-park-102-vdb mycofu:parked-at "2026-07-05T00:00:00Z"
run_adopt "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" "--recovery-mode --manifest ${VDB_FIXTURE_REPO}/build/preboot.json"
if [[ "$RC" -eq 0 ]] &&
   jq -e '(.entries | length == 1) and .entries[0].vmid == 101 and .entries[0].status == "adopted"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null &&
   [[ -d "$(vdb_fixture_dataset_path pve01 vmstore/data/mycofu-park-102-vdb)" ]] &&
   ! grep -Fq "vm-102-disk-0" "$VDB_EVENT_LOG"; then
  test_pass "recovery-mode orphan discovery is restricted to manifest VMIDs"
else
  test_fail "recovery-mode manifest restriction failed"
  printf 'rc=%s\nout=%s\nevents=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json")" >&2
fi

vdb_fixture_make
mkdir -p "${VDB_FIXTURE_REPO}/build"
vdb_park_status='{"version":1,"scope":"dev","entries":[]}'
printf '%s\n' "$vdb_park_status" > "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json"
entry1="$(vdb_fixture_entry app_dev 101 dev 50)"
vdb_fixture_manifest "${VDB_FIXTURE_REPO}/build/preboot.json" "$entry1"
touch "${VDB_FIXTURE_STATE}/scan-fail-pve01"
run_adopt "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" "--recovery-mode --manifest ${VDB_FIXTURE_REPO}/build/preboot.json"
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "failed to scan orphan parked vdbs on pve01" <<< "$OUT" &&
   jq -e '.entries | length == 0' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null; then
  test_pass "recovery-mode orphan scan failure fails closed"
else
  test_fail "recovery-mode orphan scan failure was swallowed"
  printf 'rc=%s\nout=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json")" >&2
fi

runner_summary
