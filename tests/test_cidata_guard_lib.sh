#!/usr/bin/env bash
# Hermetic coverage for framework/scripts/lib/cidata-guard.sh.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

# shellcheck source=framework/scripts/lib/cidata-guard.sh
source "${REPO_ROOT}/framework/scripts/lib/cidata-guard.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_DIR=""
VMID=510
POOL="vmstore"
ZVOL="vm-${VMID}-cloudinit"
DATASET="${POOL}/data/${ZVOL}"

setup_case() {
  local name="$1"
  FIXTURE_DIR="${TMP_DIR}/${name}"
  mkdir -p \
    "${FIXTURE_DIR}/shims" \
    "${FIXTURE_DIR}/state/zvols/pve01" \
    "${FIXTURE_DIR}/state/zvols/pve02" \
    "${FIXTURE_DIR}/state/zvols/pve03"

  : > "${FIXTURE_DIR}/events.log"
  printf 'pve02\n' > "${FIXTURE_DIR}/state/ha-node"
  printf 'started\n' > "${FIXTURE_DIR}/state/ha-state"
  printf 'balloon: 0\n' > "${FIXTURE_DIR}/state/qm-config"

  cat > "${FIXTURE_DIR}/shims/ssh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

node_ip=""
remote=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-q|-A) shift ;;
    -o) shift 2 ;;
    root@*) node_ip="${1#root@}"; shift; remote="$*"; break ;;
    *) shift ;;
  esac
done

[[ -n "${node_ip}" ]] || { echo "ssh shim: missing root@<ip>" >&2; exit 2; }
case "${node_ip}" in
  10.0.0.10) node_name="pve00" ;;
  10.0.0.11) node_name="pve01" ;;
  10.0.0.12) node_name="pve02" ;;
  10.0.0.13) node_name="pve03" ;;
  *) echo "ssh shim: unknown node IP ${node_ip}" >&2; exit 2 ;;
esac

log_event() {
  printf '%s\n' "$*" >> "${FIXTURE_DIR}/events.log"
}

emit_ha_status() {
  [[ ! -f "${FIXTURE_DIR}/fail-ha-status" ]] || exit 1
  local node state
  node="$(cat "${FIXTURE_DIR}/state/ha-node")"
  state="$(cat "${FIXTURE_DIR}/state/ha-state")"
  [[ "${state}" != "__ABSENT__" ]] || exit 0
  printf 'service vm:510 (%s, %s)\n' "${node}" "${state}"
}

zvol_from_remote() {
  printf '%s\n' "${remote}" | sed -n "s#.*${POOL}/data/\([^'\" ]*\).*#\1#p" | head -1
}

case "${remote}" in
  *"ha-manager status"*)
    log_event "READ ha-status@${node_ip}"
    emit_ha_status
    exit 0
    ;;
  *"qm config"*)
    log_event "READ qm-config@${node_ip}"
    [[ ! -f "${FIXTURE_DIR}/fail-qm-config" ]] || exit 1
    owner="$(cat "${FIXTURE_DIR}/state/ha-node")"
    if [[ "${node_name}" != "${owner}" ]]; then
      echo "Configuration file 'nodes/${node_name}/qemu-server/510.conf' does not exist" >&2
      exit 2
    fi
    cat "${FIXTURE_DIR}/state/qm-config"
    exit 0
    ;;
  *"zfs list -Hp -o refer"*)
    zvol="$(zvol_from_remote)"
    log_event "READ zfs list@${node_ip} ${POOL}/data/${zvol}"
    file="${FIXTURE_DIR}/state/zvols/${node_name}/${zvol}"
    if [[ ! -f "${file}" ]]; then
      printf '__rc=1\n'
      exit 0
    fi
    refer="$(cat "${file}")"
    if [[ "${refer}" == "__UNKNOWN__" ]]; then
      printf '__rc=2\n'
      exit 0
    fi
    printf '%s\n__rc=0\n' "${refer}"
    exit 0
    ;;
  *"zfs destroy"*)
    zvol="$(zvol_from_remote)"
    log_event "MUTATE zfs destroy@${node_ip} ${POOL}/data/${zvol}"
    [[ ! -f "${FIXTURE_DIR}/fail-destroy" ]] || exit 1
    rm -f "${FIXTURE_DIR}/state/zvols/${node_name}/${zvol}"
    exit 0
    ;;
  *)
    echo "ssh shim: unexpected remote command on ${node_ip}: ${remote}" >&2
    exit 98
    ;;
esac
SHIM
  chmod +x "${FIXTURE_DIR}/shims/ssh"
}

add_zvol() {
  local node="$1" refer="$2"
  printf '%s\n' "${refer}" > "${FIXTURE_DIR}/state/zvols/${node}/${ZVOL}"
}

set_ha_state() {
  printf '%s\n' "$1" > "${FIXTURE_DIR}/state/ha-state"
}

set_ha_node() {
  printf '%s\n' "$1" > "${FIXTURE_DIR}/state/ha-node"
}

set_qm_config() {
  printf '%s\n' "$1" > "${FIXTURE_DIR}/state/qm-config"
  rm -f "${FIXTURE_DIR}/fail-qm-config"
}

run_guard() {
  set +e
  (
    export FIXTURE_DIR POOL
    export PATH="${FIXTURE_DIR}/shims:${PATH}"
    cidata_guard_node_change "$@"
  ) > "${FIXTURE_DIR}/stdout.log" 2> "${FIXTURE_DIR}/stderr.log"
  local rc=$?
  set -e
  printf '%s\n' "${rc}" > "${FIXTURE_DIR}/exit-code"
}

run_balloon_check() {
  local target="${1:-root@10.0.0.12}"
  set +e
  (
    export FIXTURE_DIR
    export PATH="${FIXTURE_DIR}/shims:${PATH}"
    vm_is_ballooned "${target}" "${VMID}"
  ) > "${FIXTURE_DIR}/stdout.log" 2> "${FIXTURE_DIR}/stderr.log"
  local rc=$?
  set -e
  printf '%s\n' "${rc}" > "${FIXTURE_DIR}/exit-code"
}

exit_code() {
  cat "${FIXTURE_DIR}/exit-code"
}

stdout_has() {
  grep -qF "$1" "${FIXTURE_DIR}/stdout.log"
}

stderr_has() {
  grep -qF "$1" "${FIXTURE_DIR}/stderr.log"
}

event_has() {
  grep -qF "$1" "${FIXTURE_DIR}/events.log"
}

event_not_has() {
  ! grep -qF "$1" "${FIXTURE_DIR}/events.log"
}

assert_exit() {
  local want="$1" desc="$2" got
  got="$(exit_code)"
  if [[ "${got}" == "${want}" ]]; then
    test_pass "${desc}"
  else
    test_fail "${desc} (got ${got})"
    cat "${FIXTURE_DIR}/stdout.log" >&2
    cat "${FIXTURE_DIR}/stderr.log" >&2
  fi
}

assert_nonzero_exit() {
  local desc="$1" got
  got="$(exit_code)"
  if [[ "${got}" -ne 0 ]]; then
    test_pass "${desc}"
  else
    test_fail "${desc} (got 0)"
    cat "${FIXTURE_DIR}/stdout.log" >&2
    cat "${FIXTURE_DIR}/stderr.log" >&2
  fi
}

test_start "cidata-lib.1" "absent destination zvol allows node change"
setup_case "absent"
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" false pve01=root@10.0.0.11
assert_exit 0 "guard exits 0"
event_not_has "MUTATE zfs destroy" && test_pass "no destroy" || test_fail "no destroy"

test_start "cidata-lib.2" "stale orphan is destroyed before allowing"
setup_case "stale-orphan"
add_zvol pve01 18944
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" false pve01=root@10.0.0.11
assert_exit 0 "guard exits 0"
event_has "MUTATE zfs destroy@10.0.0.11 ${DATASET}" && test_pass "stale orphan destroyed" || test_fail "stale orphan destroyed"
[[ ! -f "${FIXTURE_DIR}/state/zvols/pve01/${ZVOL}" ]] && test_pass "dataset removed" || test_fail "dataset removed"

test_start "cidata-lib.3" "oversized same-name dataset fails closed"
setup_case "oversized"
add_zvol pve01 5368709120
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" false pve01=root@10.0.0.11
assert_nonzero_exit "guard exits non-zero"
stderr_has "not cidata-shaped" && test_pass "stderr says not cidata-shaped" || test_fail "stderr says not cidata-shaped"
event_not_has "MUTATE zfs destroy" && test_pass "no destroy" || test_fail "no destroy"

test_start "cidata-lib.4" "unknown zvol probe fails closed"
setup_case "unknown-probe"
add_zvol pve01 "__UNKNOWN__"
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" false pve01=root@10.0.0.11
assert_nonzero_exit "guard exits non-zero"
stderr_has "cannot determine whether ${ZVOL} exists" && stderr_has "fail-closed" && test_pass "stderr says fail-closed" || test_fail "stderr says fail-closed"
event_not_has "MUTATE zfs destroy" && test_pass "no destroy" || test_fail "no destroy"

test_start "cidata-lib.5" "HA error refuses and routes to realign-cidata.sh"
setup_case "ha-error"
set_ha_state error
add_zvol pve01 18944
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" false pve01=root@10.0.0.11
assert_nonzero_exit "guard exits non-zero"
stderr_has "realign-cidata.sh" && stderr_has "vmid ${VMID}" && test_pass "stderr names realign-cidata.sh" || test_fail "stderr names realign-cidata.sh"
event_not_has "MUTATE zfs destroy" && test_pass "no destroy" || test_fail "no destroy"

test_start "cidata-lib.6" "unreadable HA state fails closed"
setup_case "ha-unreadable"
: > "${FIXTURE_DIR}/fail-ha-status"
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" false pve01=root@10.0.0.11
assert_nonzero_exit "guard exits non-zero"
stderr_has "cannot read HA state" && stderr_has "fail-closed" && test_pass "stderr says fail-closed" || test_fail "stderr says fail-closed"
event_not_has "MUTATE zfs destroy" && test_pass "no destroy" || test_fail "no destroy"

test_start "cidata-lib.7" "multi-destination sweep hits non-owners and skips owner"
setup_case "multi-dest"
add_zvol pve01 18944
add_zvol pve02 18944
add_zvol pve03 18944
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" false \
  pve01=root@10.0.0.11 \
  pve02=root@10.0.0.12 \
  pve03=root@10.0.0.13
assert_exit 0 "guard exits 0"
event_has "MUTATE zfs destroy@10.0.0.11 ${DATASET}" && test_pass "pve01 swept" || test_fail "pve01 swept"
event_has "MUTATE zfs destroy@10.0.0.13 ${DATASET}" && test_pass "pve03 swept" || test_fail "pve03 swept"
event_not_has "MUTATE zfs destroy@10.0.0.12 ${DATASET}" && test_pass "owner pve02 skipped" || test_fail "owner pve02 skipped"

test_start "cidata-lib.7b" "live HA owner drift fails closed before any destination probe"
setup_case "live-owner-drift"
set_ha_node pve01
add_zvol pve01 18944
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" false pve01=root@10.0.0.11
assert_nonzero_exit "guard exits non-zero"
stderr_has "live HA owner for vm:${VMID} is pve01" && stderr_has "caller snapshot owner was pve02" && test_pass "stderr names owner drift" || test_fail "stderr names owner drift"
stderr_has "Re-run the operation with fresh placement state" && test_pass "stderr tells operator to re-run" || test_fail "stderr tells operator to re-run"
event_not_has "READ zfs list@10.0.0.11 ${DATASET}" && test_pass "no destination probe after owner drift" || test_fail "no destination probe after owner drift"
event_not_has "MUTATE zfs destroy@10.0.0.11 ${DATASET}" && test_pass "no destroy after owner drift" || test_fail "no destroy after owner drift"

test_start "cidata-lib.8" "dry run reports sweep but does not destroy"
setup_case "dry-run"
add_zvol pve01 18944
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" true pve01=root@10.0.0.11
assert_exit 0 "guard exits 0"
stdout_has "Would sweep stale orphan cidata" && test_pass "dry-run reports would sweep" || test_fail "dry-run reports would sweep"
event_not_has "MUTATE zfs destroy" && test_pass "no destroy" || test_fail "no destroy"
[[ -f "${FIXTURE_DIR}/state/zvols/pve01/${ZVOL}" ]] && test_pass "dataset remains" || test_fail "dataset remains"

test_start "cidata-lib.9" "vm_is_ballooned classifies qm config"
setup_case "vm-balloon"
set_qm_config $'balloon: 8192\nmemory: 32768'
run_balloon_check
assert_exit 0 "positive balloon returns 0"
set_qm_config $'balloon: 0\nmemory: 32768'
run_balloon_check
assert_exit 1 "balloon 0 returns fixed rc 1"
set_qm_config $'memory: 32768\ncores: 4'
run_balloon_check
assert_exit 1 "absent balloon line returns fixed rc 1"
: > "${FIXTURE_DIR}/fail-qm-config"
run_balloon_check
assert_exit 2 "failing qm config returns unknown rc 2"
set_qm_config 'balloon: not-a-number'
run_balloon_check
assert_exit 2 "non-numeric balloon returns unknown rc 2"
set_qm_config $'balloon: 8192\nmemory: 32768'
run_balloon_check root@10.0.0.11
assert_exit 2 "non-owner qm config probe returns unknown rc 2"

test_start "cidata-lib.10" "HA status with no service lines is UNKNOWN"
setup_case "ha-status-no-services"
set_ha_state "__ABSENT__"
run_guard "${VMID}" pve02 root@10.0.0.10 "${POOL}" false pve01=root@10.0.0.11
assert_nonzero_exit "guard exits non-zero"
stderr_has "cannot read HA state" && stderr_has "fail-closed" && test_pass "stderr says unreadable HA state" || test_fail "stderr says unreadable HA state"
event_not_has "MUTATE zfs destroy" && test_pass "no destroy" || test_fail "no destroy"

runner_summary
