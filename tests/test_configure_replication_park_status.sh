#!/usr/bin/env bash
# test_configure_replication_park_status.sh — Sprint 044 replication/reset park awareness.
# shellcheck disable=SC2016

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIGURE="${REPO_ROOT}/framework/scripts/configure-replication.sh"
RESET="${REPO_ROOT}/framework/scripts/reset-cluster.sh"
CONVERGE="${REPO_ROOT}/framework/scripts/converge-lib.sh"

function_body() {
  local name="$1" file="$2"
  awk -v name="$name" '
    $0 ~ "^" name "\\(\\)" { in_fn=1 }
    in_fn { print }
    in_fn && $0 == "}" { exit }
  ' "$file"
}

test_start "A6.a" "configure-replication accepts park-status and reads adopted volname"
if grep -Fq -- '--park-status) PARK_STATUS_FILE="$2"; shift 2 ;;' "$CONFIGURE" &&
   grep -Fq 'select(.vmid == $vmid and .status == "adopted")' "$CONFIGURE" &&
   grep -Fq '.volname // empty' "$CONFIGURE"; then
  test_pass "park-status parser and adopted-volname lookup are present"
else
  test_fail "park-status parser or adopted-volname lookup missing"
fi

test_start "A6.b" "cleanup preserves adopted vdb and destroys other VM zvols"
destroy_body="$(function_body destroy_vm_zvols_on_target "$CONFIGURE")"
if grep -Fq 'base=\${zvol##*/}' <<< "$destroy_body" &&
   grep -Fq 'PRESERVE_VDB' <<< "$destroy_body" &&
   grep -Fq 'base\" = \"\$PRESERVE_VDB' <<< "$destroy_body" &&
   grep -Fq 'Preserving adopted vdb replica' <<< "$destroy_body" &&
   grep -Fq 'zfs destroy -r \"\$zvol\"' <<< "$destroy_body"; then
  test_pass "selective cleanup preserves only the recorded adopted vdb volname"
else
  test_fail "selective cleanup preserve/destroy contract missing"
  printf '%s\n' "$destroy_body" >&2
fi

test_start "A6.c" "all destructive zvol cleanup paths use the selective helper"
if [[ "$(grep -c 'destroy_vm_zvols_on_target' "$CONFIGURE")" -ge 4 ]] &&
   ! grep -Fq 'for zvol in $(zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep "vm-${vmid}-")' "$CONFIGURE" &&
   ! grep -Fq 'for zvol in $(zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep '\''vm-${VMID}-'\'')' "$CONFIGURE"; then
  test_pass "stale, orphan, and global cleanup route through selective helper"
else
  test_fail "a cleanup path still destroys vm zvols directly"
fi

test_start "A6.d" "parked vdb sweep warns and never destroys"
warn_body="$(function_body warn_parked_vdbs "$CONFIGURE")"
if grep -Fq 'mycofu-park-[0-9][0-9]*-vdb' <<< "$warn_body" &&
   grep -Fq 'parked-vdb.sh inspect' <<< "$warn_body" &&
   grep -Fq 'parked-vdb.sh release' <<< "$warn_body" &&
   ! grep -Fq 'zfs destroy' <<< "$warn_body"; then
  test_pass "park sweep warns with sanctioned commands and has no destroy"
else
  test_fail "park sweep warning contract missing"
  printf '%s\n' "$warn_body" >&2
fi

test_start "A8.a" "reset-cluster purges parked zvols alongside VM zvols"
if grep -Fq 'grep -E "vmstore/data/(vm-|mycofu-park-)"' "$RESET" &&
   grep -Fq "grep -Ec 'vmstore/data/(vm-|mycofu-park-)'" "$RESET"; then
  test_pass "reset-cluster destroy and postcondition include parked zvols"
else
  test_fail "reset-cluster does not include parked zvols in purge/postcondition"
fi

test_start "A6.e" "convergence replication step forwards park-status when available"
replication_body="$(function_body converge_step_replication "$CONVERGE")"
if grep -Fq 'CONVERGE_PARK_STATUS_FILE' <<< "$replication_body" &&
   grep -Fq 'vdb-park-status-converge.json' <<< "$replication_body" &&
   grep -Fq '"${SCRIPT_DIR}/configure-replication.sh" "*" --park-status "$park_status_file"' <<< "$replication_body"; then
  test_pass "convergence replication preserves adopted vdb replicas with park-status"
else
  test_fail "convergence replication does not pass park-status"
  printf '%s\n' "$replication_body" >&2
fi

runner_summary
