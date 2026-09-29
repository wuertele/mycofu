#!/usr/bin/env bash
# Hermetic validate.sh fixture for cicd failover-fit guardrail.
#
# The check must use qm config's effective floor, declared home node, and live
# survivor MemAvailable only. The deliberately bogus nodes[].ram_gb values below
# prove the predicate never consults configured RAM.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

VALIDATE="${REPO_ROOT}/framework/scripts/validate.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_CONFIG="${TMP_DIR}/config.yaml"
SHIMS_DIR="${TMP_DIR}/shims"
mkdir -p "${SHIMS_DIR}"

cat > "${FIXTURE_CONFIG}" <<'EOF'
domain: example.test
acme: staging
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
    ram_gb: 2
  - name: pve02
    mgmt_ip: 10.0.0.12
    ram_gb: 2
  - name: pve03
    mgmt_ip: 10.0.0.13
    ram_gb: 2
vms:
  cicd:
    vmid: 160
    node: pve01
EOF

cat > "${SHIMS_DIR}/ssh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

list_contains() {
  local needle="$1" item
  for item in ${2:-}; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

remote_host=""
remote=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-q|-A) shift ;;
    -o) shift 2 ;;
    root@*) remote_host="$1"; shift; remote="$*"; break ;;
    *) shift ;;
  esac
done

[[ -n "${remote_host}" && -n "${remote}" ]] || { echo "ssh shim: missing host or remote command" >&2; exit 2; }

ip="${remote_host#root@}"
case "${ip}" in
  10.0.0.11) node="pve01" ;;
  10.0.0.12) node="pve02" ;;
  10.0.0.13) node="pve03" ;;
  *) echo "ssh shim: unknown host ${remote_host}" >&2; exit 2 ;;
esac

case "${remote}" in
  "pvesh get /nodes --output-format json")
    if [[ "${PVESH_BAD_JSON:-0}" == "1" ]]; then
      printf 'not json\n'
      exit 0
    fi
    printf '['
    first=1
    for n in pve01 pve02 pve03; do
      status="online"
      if list_contains "${n}" "${OFFLINE_NODES:-}"; then
        status="offline"
      fi
      if [[ "${first}" -eq 0 ]]; then
        printf ','
      fi
      first=0
      printf '{"node":"%s","status":"%s"}' "${n}" "${status}"
    done
    printf ']\n'
    ;;
  "qm config 160")
    if [[ "${QM_FAIL:-0}" == "1" ]]; then
      exit 1
    fi
    printf 'memory: %s\n' "${QM_MEMORY:?QM_MEMORY unset}"
    if [[ -n "${QM_BALLOON:-}" ]]; then
      printf 'balloon: %s\n' "${QM_BALLOON}"
    fi
    ;;
  "cat /proc/meminfo")
    # Flap recovery: the first read for FLAP_RECOVER_NODE fails, later reads
    # succeed — exercises the re-read-once path (both reads must fail to FAIL).
    if [[ -n "${FLAP_STATE_DIR:-}" && "${node}" == "${FLAP_RECOVER_NODE:-}" ]]; then
      cnt_file="${FLAP_STATE_DIR}/flap_${node}"
      n=0; [[ -f "${cnt_file}" ]] && n="$(cat "${cnt_file}")"
      n=$(( n + 1 )); printf '%s' "${n}" > "${cnt_file}"
      [[ "${n}" -eq 1 ]] && exit 1
    fi
    if list_contains "${node}" "${MEMFAIL_NODES:-}"; then
      exit 1
    fi
    mem_var="MEMAVAIL_${node}"
    mem_mib="${!mem_var:-}"
    [[ -n "${mem_mib}" ]] || { echo "ssh shim: ${mem_var} unset" >&2; exit 2; }
    mem_kb=$(( mem_mib * 1024 ))
    printf 'MemTotal:       %8d kB\n' $(( 65536 * 1024 ))
    printf 'MemFree:        %8d kB\n' $(( mem_kb / 2 ))
    if list_contains "${node}" "${MEM_BAD_UNIT_NODES:-}"; then
      # Trailing-garbage unit: strict parser must treat this as unreadable.
      printf 'MemAvailable:  %8d kBogus\n' "${mem_kb}"
    else
      printf 'MemAvailable:  %8d kB\n' "${mem_kb}"
    fi
    ;;
  "cat /proc/spl/kstat/zfs/arcstats")
    if [[ "${ARC_BAD:-0}" == "1" ]]; then
      # Non-numeric arcstats must degrade to "unknown", never abort the gate.
      printf 'size 4 abc\n'
      printf 'c_min 4 1073741824\n'
    else
      printf 'size 4 8589934592\n'
      printf 'c_min 4 1073741824\n'
    fi
    ;;
  "pvesh get /cluster/resources --type vm"|"pvesh get /cluster/resources --type vm --output-format json"|"pvesh get /cluster/resources --output-format json --type vm")
    printf '[{"type":"qemu","vmid":160,"name":"cicd","node":"pve03","status":"running"}]\n'
    ;;
  *)
    echo "ssh shim: unexpected remote command on ${remote_host}: ${remote}" >&2
    exit 98
    ;;
esac
SHIM
chmod +x "${SHIMS_DIR}/ssh"

run_validate() {
  local qm_balloon="$1"
  local qm_memory="$2"
  local mem_pve01="$3"
  local mem_pve02="$4"
  local mem_pve03="$5"
  local memfail_nodes="${6:-}"
  local offline_nodes="${7:-}"
  local qm_fail="${8:-0}"

  set +e
  OUTPUT="$(
    QM_BALLOON="${qm_balloon}" \
    QM_MEMORY="${qm_memory}" \
    QM_FAIL="${qm_fail}" \
    MEMAVAIL_pve01="${mem_pve01}" \
    MEMAVAIL_pve02="${mem_pve02}" \
    MEMAVAIL_pve03="${mem_pve03}" \
    MEMFAIL_NODES="${memfail_nodes}" \
    OFFLINE_NODES="${offline_nodes}" \
    PVESH_BAD_JSON="${PVESH_BAD_JSON:-0}" \
    ARC_BAD="${ARC_BAD:-0}" \
    MEM_BAD_UNIT_NODES="${MEM_BAD_UNIT_NODES:-}" \
    FLAP_STATE_DIR="${FLAP_STATE_DIR:-}" \
    FLAP_RECOVER_NODE="${FLAP_RECOVER_NODE:-}" \
    PATH="${SHIMS_DIR}:${PATH}" \
    MYCOFU_VALIDATE_CONFIG="${CONFIG_OVERRIDE:-${FIXTURE_CONFIG}}" \
    MYCOFU_VALIDATE_ONLY_CICD_FAILOVER_FIT=1 \
    MYCOFU_FAILOVER_FIT_REREAD_DELAY=0 \
    bash "${VALIDATE}" dev 2>&1
  )"
  STATUS=$?
  set -e
}

# Second fixture: declared cicd home names a node absent from nodes[] (typo).
FIXTURE_CONFIG_BADHOME="${TMP_DIR}/config-badhome.yaml"
cat > "${FIXTURE_CONFIG_BADHOME}" <<'EOF'
domain: example.test
acme: staging
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
    ram_gb: 2
  - name: pve02
    mgmt_ip: 10.0.0.12
    ram_gb: 2
  - name: pve03
    mgmt_ip: 10.0.0.13
    ram_gb: 2
vms:
  cicd:
    vmid: 160
    node: pve99
EOF

test_start "cicd-fit.1" "balloon floor fits smallest survivor"
run_validate 8192 61440 62000 11653 11700
GREEN_OUTPUT="${OUTPUT}"
GREEN_STATUS="${STATUS}"
if [[ "${STATUS}" -eq 0 ]] \
   && grep -qF '[PASS] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'OK:' <<< "${OUTPUT}" \
   && grep -qF 'effective_floor = 8192' <<< "${OUTPUT}"; then
  test_pass "balloon floor produces PASS"
else
  test_fail "balloon floor did not pass"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.2" "fixed 24 GiB floor fails against same survivors"
# NON-VACUITY: same survivor MemAvailable as #1; only effective_floor changes.
run_validate 0 24576 62000 11653 11700
RED_OUTPUT="${OUTPUT}"
RED_STATUS="${STATUS}"
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'EXCEEDS' <<< "${OUTPUT}" \
   && grep -qF 'effective_floor = 24576' <<< "${OUTPUT}"; then
  test_pass "fixed 24 GiB floor produces FAIL"
else
  test_fail "fixed 24 GiB floor did not fail"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.3" "balloon floor too large fails"
run_validate 12288 61440 62000 11653 11700
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'EXCEEDS' <<< "${OUTPUT}" \
   && grep -qF 'effective_floor = 12288' <<< "${OUTPUT}"; then
  test_pass "oversized balloon floor produces FAIL"
else
  test_fail "oversized balloon floor did not fail"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.4" "bogus ram_gb does not affect green result"
run_validate 8192 61440 62000 11653 11700
if [[ "${STATUS}" -eq "${GREEN_STATUS}" ]] \
   && [[ "${OUTPUT}" == "${GREEN_OUTPUT}" ]] \
   && grep -qF '[PASS] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'OK:' <<< "${OUTPUT}" \
   && grep -qF 'effective_floor = 8192' <<< "${OUTPUT}"; then
  test_pass "bogus ram_gb leaves green result identical"
else
  test_fail "bogus ram_gb changed green result"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.5" "bogus ram_gb does not affect red result"
run_validate 0 24576 62000 11653 11700
if [[ "${STATUS}" -eq "${RED_STATUS}" ]] \
   && [[ "${OUTPUT}" == "${RED_OUTPUT}" ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'EXCEEDS' <<< "${OUTPUT}" \
   && grep -qF 'effective_floor = 24576' <<< "${OUTPUT}"; then
  test_pass "bogus ram_gb leaves red result identical"
else
  test_fail "bogus ram_gb changed red result"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.6" "unreachable offline survivor fails closed as outage"
run_validate 0 24576 62000 11653 11700 "pve03" "pve03"
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'fail-closed' <<< "${OUTPUT}" \
   && grep -qF 'OFFLINE per HA/corosync' <<< "${OUTPUT}"; then
  test_pass "offline survivor read failure is classified as outage"
else
  test_fail "offline survivor read failure was not classified"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.7" "unreachable online survivor fails closed as unknown"
run_validate 0 24576 62000 11653 11700 "pve03" ""
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'fail-closed' <<< "${OUTPUT}" \
   && grep -qF 'UNKNOWN reasons' <<< "${OUTPUT}"; then
  test_pass "online survivor read failure is classified as unknown"
else
  test_fail "online survivor read failure was not classified"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.8" "qm config unreadable fails closed"
run_validate 0 24576 62000 11653 11700 "" "" 1
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'fail-closed' <<< "${OUTPUT}" \
   && grep -qF 'qm config' <<< "${OUTPUT}"; then
  test_pass "unreadable qm config fails closed"
else
  test_fail "unreadable qm config did not fail closed"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.9" "declared home remains authoritative when cicd drifted live"
run_validate 0 24576 62000 62000 11700
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'home node (declared, config.vms.cicd.node) = pve01' <<< "${OUTPUT}" \
   && grep -qF 'EXCEEDS' <<< "${OUTPUT}"; then
  test_pass "declared home pve01 keeps pve03 in survivor set"
else
  test_fail "declared home was not authoritative"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.10" "malformed qm memory value fails closed"
run_validate "" "61440x" 62000 11653 11700
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'fail-closed' <<< "${OUTPUT}" \
   && grep -qF 'memory' <<< "${OUTPUT}"; then
  test_pass "non-integer memory fails closed (no numeric-prefix fail-open)"
else
  test_fail "malformed memory did not fail closed"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.11" "malformed MemAvailable unit fails closed as unknown"
MEM_BAD_UNIT_NODES="pve03"
run_validate 0 24576 62000 11653 11700
unset MEM_BAD_UNIT_NODES
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'fail-closed' <<< "${OUTPUT}" \
   && grep -qF 'UNKNOWN reasons' <<< "${OUTPUT}"; then
  test_pass "trailing-garbage MemAvailable unit is treated as unreadable"
else
  test_fail "malformed MemAvailable unit did not fail closed"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.12" "unparseable node-status JSON fails closed"
PVESH_BAD_JSON=1
run_validate 0 24576 62000 11653 11700
unset PVESH_BAD_JSON
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'fail-closed' <<< "${OUTPUT}" \
   && grep -qF 'unparseable' <<< "${OUTPUT}"; then
  test_pass "malformed pvesh /nodes JSON fails closed with a clear message"
else
  test_fail "unparseable node status did not fail closed"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.13" "declared home absent from nodes[] fails closed"
CONFIG_OVERRIDE="${FIXTURE_CONFIG_BADHOME}"
run_validate 8192 61440 62000 11653 11700
unset CONFIG_OVERRIDE
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'fail-closed' <<< "${OUTPUT}" \
   && grep -qF 'is not present in config nodes' <<< "${OUTPUT}"; then
  test_pass "home node not in nodes[] fails closed (no fail-open survivor set)"
else
  test_fail "home-not-in-nodes did not fail closed"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.14" "malformed ARC diagnostic does not change the pass result"
ARC_BAD=1
run_validate 8192 61440 62000 11653 11700
unset ARC_BAD
if [[ "${STATUS}" -eq 0 ]] \
   && grep -qF '[PASS] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'OK:' <<< "${OUTPUT}" \
   && grep -qF 'ARC reclaimable ~unknown' <<< "${OUTPUT}"; then
  test_pass "non-numeric arcstats degrades to unknown without aborting the gate"
else
  test_fail "malformed ARC diagnostic changed the gate result"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "cicd-fit.15" "flap recovery: first read fails, re-read succeeds, predicate proceeds"
FLAP_STATE_DIR="${TMP_DIR}/flap"
FLAP_RECOVER_NODE="pve03"
mkdir -p "${FLAP_STATE_DIR}"
rm -f "${FLAP_STATE_DIR}/flap_pve03"
run_validate 8192 61440 62000 11653 11700
unset FLAP_STATE_DIR FLAP_RECOVER_NODE
if [[ "${STATUS}" -eq 0 ]] \
   && grep -qF '[PASS] cicd effective floor fits smallest survivor' <<< "${OUTPUT}" \
   && grep -qF 'OK:' <<< "${OUTPUT}" \
   && ! grep -qF 'fail-closed' <<< "${OUTPUT}"; then
  test_pass "a single transient read failure does not red the check (re-read recovers)"
else
  test_fail "flap recovery did not proceed to the predicate"
  printf '%s\n' "${OUTPUT}" >&2
fi

runner_summary
