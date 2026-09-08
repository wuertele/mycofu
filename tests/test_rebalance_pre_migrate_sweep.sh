#!/usr/bin/env bash
# Hermetic coverage for rebalance-cluster.sh's pre-migrate cidata guard.
#
# The fixture copies the production script into a temporary repo so
# find_repo_root reads the fixture config.yaml. SSH is shimmed and keyed by
# remote command text; all mutations are appended to events.log.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

REBALANCE="${REPO_ROOT}/framework/scripts/rebalance-cluster.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_DIR=""
VMID=510
POOL="vmstore"
DEST_IP="10.0.0.11"
SOURCE_IP="10.0.0.12"

setup_case() {
  local name="$1"
  FIXTURE_DIR="${TMP_DIR}/${name}"
  mkdir -p \
    "${FIXTURE_DIR}/repo/framework/scripts/lib" \
    "${FIXTURE_DIR}/repo/site" \
    "${FIXTURE_DIR}/shims" \
    "${FIXTURE_DIR}/state/zvols/pve01" \
    "${FIXTURE_DIR}/state/zvols/pve02" \
    "${FIXTURE_DIR}/state/zvols/pve03"

  : > "${FIXTURE_DIR}/events.log"
  : > "${FIXTURE_DIR}/repo/flake.nix"
  printf 'started\n' > "${FIXTURE_DIR}/state/ha-state"
  printf 'pve02\n' > "${FIXTURE_DIR}/state/actual-node"
  printf 'pve01\n' > "${FIXTURE_DIR}/state/intended-node"

  cat > "${FIXTURE_DIR}/repo/site/config.yaml" <<EOF
nodes:
  - name: pve01
    mgmt_ip: ${DEST_IP}
  - name: pve02
    mgmt_ip: ${SOURCE_IP}
  - name: pve03
    mgmt_ip: 10.0.0.13
proxmox:
  storage_pool: ${POOL}
vms:
  drift_vm:
    vmid: ${VMID}
    node: pve01
applications: {}
EOF

  cp "${REBALANCE}" "${FIXTURE_DIR}/repo/framework/scripts/rebalance-cluster.sh"
  cp "${REPO_ROOT}/framework/scripts/lib/cidata-guard.sh" "${FIXTURE_DIR}/repo/framework/scripts/lib/cidata-guard.sh"
  chmod +x "${FIXTURE_DIR}/repo/framework/scripts/rebalance-cluster.sh"

  cat > "${FIXTURE_DIR}/shims/sleep" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM
  chmod +x "${FIXTURE_DIR}/shims/sleep"

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
  10.0.0.11) node_name="pve01" ;;
  10.0.0.12) node_name="pve02" ;;
  10.0.0.13) node_name="pve03" ;;
  *) echo "ssh shim: unknown node IP ${node_ip}" >&2; exit 2 ;;
esac

log_event() {
  printf '%s\n' "$*" >> "${FIXTURE_DIR}/events.log"
}

emit_resources() {
  local node
  if [[ -f "${FIXTURE_DIR}/state/migrated" ]]; then
    node="$(cat "${FIXTURE_DIR}/state/intended-node")"
  else
    node="$(cat "${FIXTURE_DIR}/state/actual-node")"
  fi
  printf '[{"type":"qemu","vmid":510,"name":"drift-vm","node":"%s","status":"running"}]\n' "${node}"
}

emit_ha_status() {
  local state node
  state="$(cat "${FIXTURE_DIR}/state/ha-state")"
  if [[ -f "${FIXTURE_DIR}/state/migrated" ]]; then
    node="$(cat "${FIXTURE_DIR}/state/intended-node")"
  else
    node="$(cat "${FIXTURE_DIR}/state/actual-node")"
  fi
  maintenance_node=""
  [[ ! -f "${FIXTURE_DIR}/state/maintenance-node" ]] || maintenance_node="$(cat "${FIXTURE_DIR}/state/maintenance-node")"
  for lrm_node in pve01 pve02 pve03; do
    if [[ "${lrm_node}" == "${maintenance_node}" ]]; then
      printf 'lrm %s (maintenance mode, Tue Jan 01 00:00:00 2026)\n' "${lrm_node}"
    else
      printf 'lrm %s (active, Tue Jan 01 00:00:00 2026)\n' "${lrm_node}"
    fi
  done
  printf 'service vm:510 (%s, %s)\n' "${node}" "${state}"
}

current_owner_node() {
  if [[ -f "${FIXTURE_DIR}/state/migrated" ]]; then
    cat "${FIXTURE_DIR}/state/intended-node"
  else
    cat "${FIXTURE_DIR}/state/actual-node"
  fi
}

emit_ha_config() {
  printf 'vm:510\n  state started\n'
}

zvol_from_remote() {
  printf '%s\n' "${remote}" | sed -n "s#.*${POOL}/data/\([^'\" ]*\).*#\1#p" | head -1
}

case "${remote}" in
  true)
    log_event "READ true@${node_ip}"
    exit 0
    ;;
  *"pvesh get /cluster/resources --type vm --output-format json"*)
    log_event "READ pvesh@${node_ip}"
    emit_resources
    exit 0
    ;;
  *"ha-manager status"*)
    log_event "READ ha-status@${node_ip}"
    emit_ha_status
    exit 0
    ;;
  *"ha-manager config"*)
    log_event "READ ha-config@${node_ip}"
    emit_ha_config
    exit 0
    ;;
  *"qm config"*)
    log_event "READ qm-config@${node_ip}"
    owner="$(current_owner_node)"
    if [[ "${node_name}" != "${owner}" ]]; then
      echo "Configuration file 'nodes/${node_name}/qemu-server/510.conf' does not exist" >&2
      exit 2
    fi
    printf 'balloon: 0\n'
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
    [[ -f "${FIXTURE_DIR}/fail-destroy" ]] && exit 1
    rm -f "${FIXTURE_DIR}/state/zvols/${node_name}/${zvol}"
    exit 0
    ;;
  *"ha-manager migrate vm:510 pve01"*)
    log_event "MUTATE migrate vm:510 pve01"
    : > "${FIXTURE_DIR}/state/migrated"
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
  local node="$1" zvol="$2" refer="$3"
  printf '%s\n' "${refer}" > "${FIXTURE_DIR}/state/zvols/${node}/${zvol}"
}

set_ha_state() {
  printf '%s\n' "$1" > "${FIXTURE_DIR}/state/ha-state"
}

set_ha_maintenance() {
  printf '%s\n' "$1" > "${FIXTURE_DIR}/state/maintenance-node"
}

run_rebalance() {
  set +e
  (
    export FIXTURE_DIR POOL
    export PATH="${FIXTURE_DIR}/shims:${PATH}"
    export MYCOFU_REBALANCE_VERIFY_TIMEOUT=0
    export MYCOFU_REBALANCE_VERIFY_INTERVAL=1
    cd "${FIXTURE_DIR}/repo"
    bash framework/scripts/rebalance-cluster.sh "$@"
  ) > "${FIXTURE_DIR}/output.log" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "${rc}" > "${FIXTURE_DIR}/exit-code"
}

exit_code() {
  cat "${FIXTURE_DIR}/exit-code"
}

output_has() {
  grep -qF "$1" "${FIXTURE_DIR}/output.log"
}

event_has() {
  grep -qF "$1" "${FIXTURE_DIR}/events.log"
}

event_not_has() {
  ! grep -qF "$1" "${FIXTURE_DIR}/events.log"
}

event_count() {
  grep -cF "$1" "${FIXTURE_DIR}/events.log" 2>/dev/null || true
}

first_event_line() {
  grep -nF "$1" "${FIXTURE_DIR}/events.log" 2>/dev/null | head -1 | cut -d: -f1 || true
}

assert_exit() {
  local want="$1" desc="$2" got
  got="$(exit_code)"
  if [[ "${got}" == "${want}" ]]; then
    test_pass "${desc}"
  else
    test_fail "${desc} (got ${got})"
    cat "${FIXTURE_DIR}/output.log" >&2
  fi
}

assert_nonzero_exit() {
  local desc="$1" got
  got="$(exit_code)"
  if [[ "${got}" -ne 0 ]]; then
    test_pass "${desc}"
  else
    test_fail "${desc} (got 0)"
    cat "${FIXTURE_DIR}/output.log" >&2
  fi
}

assert_event_order() {
  local before="$1" after="$2" desc="$3" b a
  b="$(first_event_line "${before}")"
  a="$(first_event_line "${after}")"
  if [[ -n "${b}" && -n "${a}" && "${b}" -lt "${a}" ]]; then
    test_pass "${desc}"
  else
    test_fail "${desc}"
    cat "${FIXTURE_DIR}/events.log" >&2
  fi
}

ZVOL="vm-${VMID}-cloudinit"
DEST_DATASET="${POOL}/data/${ZVOL}"

test_start "precondition.maintenance" "rebalance warns and continues when an LRM label lags in HA maintenance"
setup_case "ha-maintenance"
set_ha_maintenance pve01
add_zvol pve01 "${ZVOL}" 18944
run_rebalance
assert_exit 0 "rebalance exits 0"
event_has "MUTATE zfs destroy@${DEST_IP} ${DEST_DATASET}" && test_pass "lagging label did not block cidata sweep" || test_fail "lagging label did not block cidata sweep"
event_has "MUTATE migrate vm:${VMID} pve01" && test_pass "lagging label did not block post-reboot rebalance" || test_fail "lagging label did not block post-reboot rebalance"
if output_has "WARNING: Node pve01 appears in HA maintenance; rebalance will continue." \
   && output_has "HA status: lrm pve01 (maintenance mode," \
   && output_has "HA maintenance labels are advisory for rebalance"; then
  test_pass "output warns but explains advisory status"
else
  test_fail "output warns but explains advisory status"
  cat "${FIXTURE_DIR}/output.log" >&2
fi

test_start "pre-migrate.1" "same-name destination orphan is destroyed before migrate"
setup_case "dest-orphan"
add_zvol pve01 "${ZVOL}" 18944
run_rebalance
assert_exit 0 "rebalance exits 0"
event_has "MUTATE zfs destroy@${DEST_IP} ${DEST_DATASET}" && test_pass "destination cidata orphan destroyed" || test_fail "destination cidata orphan destroyed"
event_has "MUTATE migrate vm:${VMID} pve01" && test_pass "migrate executed" || test_fail "migrate executed"
assert_event_order "MUTATE zfs destroy@${DEST_IP} ${DEST_DATASET}" "MUTATE migrate vm:${VMID} pve01" "destroy happens before migrate"

test_start "pre-migrate.2" "current-host canonical cidata is preserved"
setup_case "current-host-preserved"
add_zvol pve01 "${ZVOL}" 18944
add_zvol pve02 "${ZVOL}" 18944
run_rebalance
assert_exit 0 "rebalance exits 0"
if [[ "$(event_count "MUTATE zfs destroy@")" -eq 1 ]] &&
   event_has "MUTATE zfs destroy@${DEST_IP} ${DEST_DATASET}" &&
   event_not_has "MUTATE zfs destroy@${SOURCE_IP} ${DEST_DATASET}"; then
  test_pass "only the destination copy is destroyed"
else
  test_fail "only the destination copy is destroyed"
  cat "${FIXTURE_DIR}/events.log" >&2
fi
event_has "MUTATE migrate vm:${VMID} pve01" && test_pass "migrate still executed" || test_fail "migrate still executed"

test_start "pre-migrate.3" "HA error refuses and routes to realign-cidata.sh"
setup_case "ha-error"
set_ha_state error
add_zvol pve01 "${ZVOL}" 18944
run_rebalance
assert_nonzero_exit "rebalance exits non-zero"
event_not_has "MUTATE zfs destroy" && test_pass "no zfs destroy" || test_fail "no zfs destroy"
event_not_has "MUTATE migrate" && test_pass "no migrate" || test_fail "no migrate"
if output_has "realign-cidata.sh" && output_has "vm:${VMID}"; then
  test_pass "stderr names realign-cidata.sh and vmid"
else
  test_fail "stderr names realign-cidata.sh and vmid"
  cat "${FIXTURE_DIR}/output.log" >&2
fi

test_start "pre-migrate.4" "unknown destination zvol state fails closed before migrate"
setup_case "unknown-probe"
add_zvol pve01 "${ZVOL}" "__UNKNOWN__"
run_rebalance
assert_nonzero_exit "rebalance exits non-zero"
event_not_has "MUTATE migrate" && test_pass "no migrate" || test_fail "no migrate"
if output_has "fail-closed" && output_has "cannot determine whether ${ZVOL} exists"; then
  test_pass "stderr says fail-closed"
else
  test_fail "stderr says fail-closed"
  cat "${FIXTURE_DIR}/output.log" >&2
fi

test_start "pre-migrate.5" "oversized same-name dataset fails closed"
setup_case "oversized"
add_zvol pve01 "${ZVOL}" 5368709120
run_rebalance
assert_nonzero_exit "rebalance exits non-zero"
event_not_has "MUTATE zfs destroy" && test_pass "no zfs destroy" || test_fail "no zfs destroy"
event_not_has "MUTATE migrate" && test_pass "no migrate" || test_fail "no migrate"
if output_has "not cidata-shaped"; then
  test_pass "stderr says not cidata-shaped"
else
  test_fail "stderr says not cidata-shaped"
  cat "${FIXTURE_DIR}/output.log" >&2
fi

test_start "pre-migrate.6" "dry-run reports sweep but performs no mutations"
setup_case "dry-run"
add_zvol pve01 "${ZVOL}" 18944
run_rebalance --dry-run
assert_exit 0 "dry-run exits 0"
output_has "Would sweep stale orphan cidata" && test_pass "dry-run reports would sweep" || test_fail "dry-run reports would sweep"
event_not_has "MUTATE zfs destroy" && test_pass "no zfs destroy mutation" || test_fail "no zfs destroy mutation"
event_not_has "MUTATE migrate" && test_pass "no migrate mutation" || test_fail "no migrate mutation"

test_start "pre-migrate.7" "absent destination orphan allows clean migrate"
setup_case "absent"
run_rebalance
assert_exit 0 "rebalance exits 0"
event_not_has "MUTATE zfs destroy" && test_pass "no zfs destroy" || test_fail "no zfs destroy"
event_has "MUTATE migrate vm:${VMID} pve01" && test_pass "migrate executed" || test_fail "migrate executed"

runner_summary
