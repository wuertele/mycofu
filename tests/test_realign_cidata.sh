#!/usr/bin/env bash
# Fixture test for framework/scripts/realign-cidata.sh.
#
# Hermetic Proxmox fixture: ssh dispatches remote commands into PATH shims for
# pvesh, ha-manager, qm, and zfs. The fixture owns an /etc/pve/nodes tree,
# per-node zvol refer values, and an event log for mutation assertions.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SCRIPT="${REPO_ROOT}/framework/scripts/realign-cidata.sh"

FIXTURE_DIR=""

setup_case() {
  FIXTURE_DIR="${TMP_DIR}/$1"
  mkdir -p \
    "${FIXTURE_DIR}/repo/framework/scripts" \
    "${FIXTURE_DIR}/repo/site" \
    "${FIXTURE_DIR}/etc-pve/nodes/pve01/qemu-server" \
    "${FIXTURE_DIR}/etc-pve/nodes/pve02/qemu-server" \
    "${FIXTURE_DIR}/etc-pve/nodes/pve03/qemu-server" \
    "${FIXTURE_DIR}/state/ha-config" \
    "${FIXTURE_DIR}/state/zvols/pve01" \
    "${FIXTURE_DIR}/state/zvols/pve02" \
    "${FIXTURE_DIR}/state/zvols/pve03" \
    "${FIXTURE_DIR}/shims"

  : > "${FIXTURE_DIR}/events.log"
  : > "${FIXTURE_DIR}/state/resources.tsv"
  : > "${FIXTURE_DIR}/state/ha-status.tsv"
  : > "${FIXTURE_DIR}/state/backup-vmids.tsv"
  printf '[]\n' > "${FIXTURE_DIR}/state/tasks.json"

  cat > "${FIXTURE_DIR}/repo/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.51
  - name: pve02
    mgmt_ip: 10.0.0.52
  - name: pve03
    mgmt_ip: 10.0.0.53
proxmox:
  storage_pool: vmstore
EOF

  cp "${SCRIPT}" "${FIXTURE_DIR}/repo/framework/scripts/realign-cidata.sh"
  chmod +x "${FIXTURE_DIR}/repo/framework/scripts/realign-cidata.sh"

  cat > "${FIXTURE_DIR}/repo/framework/scripts/cleanup-orphan-cidata.sh" <<'SHIM'
#!/usr/bin/env bash
echo "MUTATE cleanup $*" >> "${FIXTURE_DIR}/events.log"
exit 0
SHIM
  chmod +x "${FIXTURE_DIR}/repo/framework/scripts/cleanup-orphan-cidata.sh"

  cat > "${FIXTURE_DIR}/repo/framework/scripts/list-backup-backed-vmids.sh" <<'SHIM'
#!/usr/bin/env bash
cat "${FIXTURE_DIR}/state/backup-vmids.tsv"
SHIM
  chmod +x "${FIXTURE_DIR}/repo/framework/scripts/list-backup-backed-vmids.sh"

  cat > "${FIXTURE_DIR}/shims/yq" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
expr=""
if [[ "${1:-}" == "-r" ]]; then
  expr="$2"
else
  expr="$1"
fi
case "${expr}" in
  '.proxmox.storage_pool // "vmstore"') echo "vmstore" ;;
  '.nodes[] | .name + " " + .mgmt_ip')
    printf '%s\n' "pve01 10.0.0.51" "pve02 10.0.0.52" "pve03 10.0.0.53"
    ;;
  *) echo "shim yq: unhandled expression: ${expr}" >&2; exit 1 ;;
esac
SHIM
  chmod +x "${FIXTURE_DIR}/shims/yq"

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
  10.0.0.51) node_name="pve01" ;;
  10.0.0.52) node_name="pve02" ;;
  10.0.0.53) node_name="pve03" ;;
  *) echo "ssh shim: unknown node IP ${node_ip}" >&2; exit 2 ;;
esac

if [[ -f "${FIXTURE_DIR}/scan-fail" && "${remote}" == *"/etc/pve/nodes/"* ]]; then
  exit 255
fi

fixture_nodes="${FIXTURE_DIR}/etc-pve/nodes"
remote="${remote//\/etc\/pve\/nodes/${fixture_nodes}}"
if [[ "${remote}" == *"${fixture_nodes}"* ]]; then
  FIXTURE_REMOTE_NODE="${node_name}" PATH="${FIXTURE_DIR}/shims:${PATH}" bash -c "${remote}" \
    | sed "s#${fixture_nodes}#/etc/pve/nodes#g"
else
  FIXTURE_REMOTE_NODE="${node_name}" PATH="${FIXTURE_DIR}/shims:${PATH}" bash -c "${remote}"
fi
SHIM
  chmod +x "${FIXTURE_DIR}/shims/ssh"

  cat > "${FIXTURE_DIR}/shims/zfs" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"list"*"-o refer"* ]]; then
  dataset="${*: -1}"
  short="${dataset##*/}"
  file="${FIXTURE_DIR}/state/zvols/${FIXTURE_REMOTE_NODE}/${short}"
  [[ -f "${file}" ]] || exit 1
  cat "${file}"
  exit 0
fi
echo "zfs shim: unhandled $*" >&2
exit 1
SHIM
  chmod +x "${FIXTURE_DIR}/shims/zfs"

  cat > "${FIXTURE_DIR}/shims/pvesh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "get" && "${2:-}" == "/cluster/resources" ]]; then
  awk '
    BEGIN { printf "["; first=1 }
    NF >= 3 {
      if (!first) printf ",";
      first=0;
      printf "{\"vmid\":%s,\"type\":\"qemu\",\"node\":\"%s\",\"status\":\"%s\"}", $1, $2, $3
    }
    END { print "]" }
  ' "${FIXTURE_DIR}/state/resources.tsv"
  exit 0
fi
if [[ "${1:-}" == "get" && "${2:-}" == "/cluster/tasks" ]]; then
  cat "${FIXTURE_DIR}/state/tasks.json"
  exit 0
fi
echo "pvesh shim: unhandled $*" >&2
exit 1
SHIM
  chmod +x "${FIXTURE_DIR}/shims/pvesh"

  cat > "${FIXTURE_DIR}/shims/ha-manager" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

set_ha_state() {
  local vmid="$1" state="$2" tmp="${FIXTURE_DIR}/state/ha-status.tsv.tmp"
  awk -v vmid="${vmid}" -v state="${state}" 'BEGIN{done=0} $1==vmid {$2=state; done=1} {print} END{if(!done) print vmid, state}' \
    "${FIXTURE_DIR}/state/ha-status.tsv" > "${tmp}"
  mv "${tmp}" "${FIXTURE_DIR}/state/ha-status.tsv"
}

set_resource_status() {
  local vmid="$1" status="$2" tmp="${FIXTURE_DIR}/state/resources.tsv.tmp"
  awk -v vmid="${vmid}" -v status="${status}" '$1==vmid {$3=status} {print}' \
    "${FIXTURE_DIR}/state/resources.tsv" > "${tmp}"
  mv "${tmp}" "${FIXTURE_DIR}/state/resources.tsv"
}

case "${1:-}" in
  status)
    while read -r vmid node status; do
      [[ -n "${vmid}" ]] || continue
      ha_state="$(awk -v vmid="${vmid}" '$1==vmid {print $2; exit}' "${FIXTURE_DIR}/state/ha-status.tsv")"
      [[ -n "${ha_state}" ]] || ha_state="unknown"
      [[ "${ha_state}" == "removed" ]] && continue
      echo "service vm:${vmid} (${node}, ${ha_state})"
    done < "${FIXTURE_DIR}/state/resources.tsv"
    ;;
  config)
    if [[ "${2:-}" =~ ^vm:([0-9]+)$ ]]; then
      cat "${FIXTURE_DIR}/state/ha-config/${BASH_REMATCH[1]}" 2>/dev/null || true
    else
      cat "${FIXTURE_DIR}/state/ha-config/"* 2>/dev/null || true
    fi
    ;;
  set)
    sid="$2"; vmid="${sid#vm:}"; state=""
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --state) state="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo "MUTATE ha-manager set vm:${vmid} --state ${state}" >> "${FIXTURE_DIR}/events.log"
    if [[ "${state}" == "disabled" ]]; then
      set_ha_state "${vmid}" "stopped"
      set_resource_status "${vmid}" "stopped"
    elif [[ "${state}" == "started" ]]; then
      set_ha_state "${vmid}" "started"
      set_resource_status "${vmid}" "running"
    fi
    ;;
  remove)
    sid="$2"; vmid="${sid#vm:}"
    echo "MUTATE ha-manager remove vm:${vmid}" >> "${FIXTURE_DIR}/events.log"
    set_ha_state "${vmid}" "removed"
    ;;
  add)
    sid="$2"; vmid="${sid#vm:}"; state="started"; group=""
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --state) state="$2"; shift 2 ;;
        --group) group="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo "MUTATE ha-manager add vm:${vmid} --state ${state}${group:+ --group ${group}}" >> "${FIXTURE_DIR}/events.log"
    set_ha_state "${vmid}" "${state}"
    {
      echo "vm:${vmid}"
      echo "  state: ${state}"
      [[ -z "${group}" ]] || echo "  group: ${group}"
    } > "${FIXTURE_DIR}/state/ha-config/${vmid}"
    ;;
  *) echo "ha-manager shim: unhandled $*" >&2; exit 1 ;;
esac
SHIM
  chmod +x "${FIXTURE_DIR}/shims/ha-manager"

  cat > "${FIXTURE_DIR}/shims/qm" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

resource_node() {
  awk -v vmid="$1" '$1==vmid {print $2; exit}' "${FIXTURE_DIR}/state/resources.tsv"
}

resource_status() {
  awk -v vmid="$1" '$1==vmid {print $3; exit}' "${FIXTURE_DIR}/state/resources.tsv"
}

set_resource_status() {
  local vmid="$1" status="$2" tmp="${FIXTURE_DIR}/state/resources.tsv.tmp"
  awk -v vmid="${vmid}" -v status="${status}" '$1==vmid {$3=status} {print}' \
    "${FIXTURE_DIR}/state/resources.tsv" > "${tmp}"
  mv "${tmp}" "${FIXTURE_DIR}/state/resources.tsv"
}

config_file() {
  local vmid="$1" node
  node="$(resource_node "${vmid}")"
  echo "${FIXTURE_DIR}/etc-pve/nodes/${node}/qemu-server/${vmid}.conf"
}

case "${1:-}" in
  status)
    echo "status: $(resource_status "$2")"
    ;;
  set)
    vmid="$2"; drive_arg="$3"; vol="$4"; drivekey="${drive_arg#-}"
    if [[ -f "${FIXTURE_DIR}/fail-qm-set-once-${vmid}" ]]; then
      rm -f "${FIXTURE_DIR}/fail-qm-set-once-${vmid}"
      echo "simulated qm set failure" >&2
      exit 1
    fi
    echo "MUTATE qm set ${vmid} ${drive_arg} ${vol}" >> "${FIXTURE_DIR}/events.log"
    # Model Proxmox: the ALLOCATE form "<pool>:cloudinit" creates the volume and
    # names it canonically, so the stored config shows "<pool>:vm-<vmid>-cloudinit"
    # (pinned live by the 2026-07-08 M0 smoke). Explicit-name forms are stored
    # verbatim.
    stored_vol="${vol}"
    pool="${vol%%:*}"
    if [[ "${vol}" == "${pool}:cloudinit"* ]]; then
      stored_vol="${pool}:vm-${vmid}-cloudinit,media=cdrom"
    fi
    cfg="$(config_file "${vmid}")"
    tmp="${cfg}.tmp"
    awk -v key="${drivekey}" -v repl="${drivekey}: ${stored_vol}" 'BEGIN{done=0} $0 ~ "^"key":" {$0=repl; done=1} {print} END{if(!done) print repl}' \
      "${cfg}" > "${tmp}"
    mv "${tmp}" "${cfg}"
    ;;
  cloudinit)
    [[ "${2:-}" == "update" ]] || { echo "qm shim: unhandled $*" >&2; exit 1; }
    echo "MUTATE qm cloudinit update $3" >> "${FIXTURE_DIR}/events.log"
    ;;
  config)
    vmid="$2"
    echo "VERIFY qm config ${vmid} --current" >> "${FIXTURE_DIR}/events.log"
    cat "$(config_file "${vmid}")"
    ;;
  stop)
    vmid="$2"
    echo "MUTATE qm stop ${vmid} --skiplock" >> "${FIXTURE_DIR}/events.log"
    if [[ -f "${FIXTURE_DIR}/stop-timeout-${vmid}" ]]; then
      exit 0
    fi
    if [[ -f "${FIXTURE_DIR}/stop-count-${vmid}" ]]; then
      count="$(cat "${FIXTURE_DIR}/stop-count-${vmid}")"
      if [[ "${count}" -gt 1 ]]; then
        echo "$((count - 1))" > "${FIXTURE_DIR}/stop-count-${vmid}"
        exit 0
      fi
    fi
    set_resource_status "${vmid}" "stopped"
    ;;
  start)
    vmid="$2"
    echo "MUTATE qm start ${vmid}" >> "${FIXTURE_DIR}/events.log"
    if [[ -f "${FIXTURE_DIR}/fail-start-${vmid}" ]]; then
      echo "simulated start failure" >&2
      exit 1
    fi
    set_resource_status "${vmid}" "running"
    ;;
  *) echo "qm shim: unhandled $*" >&2; exit 1 ;;
esac
SHIM
  chmod +x "${FIXTURE_DIR}/shims/qm"
}

node_ip() {
  case "$1" in
    pve01) echo "10.0.0.51" ;;
    pve02) echo "10.0.0.52" ;;
    pve03) echo "10.0.0.53" ;;
  esac
}

add_resource() {
  local vmid="$1" node="$2" run_state="$3" ha_state="$4" group="${5:-}"
  printf '%s %s %s\n' "${vmid}" "${node}" "${run_state}" >> "${FIXTURE_DIR}/state/resources.tsv"
  printf '%s %s\n' "${vmid}" "${ha_state}" >> "${FIXTURE_DIR}/state/ha-status.tsv"
  {
    echo "vm:${vmid}"
    echo "  state: started"
    [[ -z "${group}" ]] || echo "  group: ${group}"
  } > "${FIXTURE_DIR}/state/ha-config/${vmid}"
}

add_config_line() {
  local node="$1" vmid="$2" line="$3"
  cat > "${FIXTURE_DIR}/etc-pve/nodes/${node}/qemu-server/${vmid}.conf" <<EOF
${line}
name: vm-${vmid}
EOF
}

add_zvol() {
  local node="$1" short="$2" refer="${3:-18.5K}"
  printf '%s\n' "${refer}" > "${FIXTURE_DIR}/state/zvols/${node}/${short}"
}

add_victim() {
  local node="$1" vmid="$2" drivekey="$3" disk_suffix="$4" run_state="$5" ha_state="$6" group="${7:-}"
  add_resource "${vmid}" "${node}" "${run_state}" "${ha_state}" "${group}"
  add_config_line "${node}" "${vmid}" "${drivekey}: vmstore:vm-${vmid}-disk-${disk_suffix},media=cdrom,size=4M"
  add_zvol "${node}" "vm-${vmid}-disk-${disk_suffix}" "18.5K"
}

add_canonical() {
  local node="$1" vmid="$2" drivekey="$3" run_state="$4" ha_state="$5"
  add_resource "${vmid}" "${node}" "${run_state}" "${ha_state}"
  add_config_line "${node}" "${vmid}" "${drivekey}: vmstore:vm-${vmid}-cloudinit,media=cdrom,size=4M"
  add_zvol "${node}" "vm-${vmid}-cloudinit" "18.5K"
}

mark_backup_backed() {
  local vmid="$1"
  printf '%s\tvm-%s\tdev\n' "${vmid}" "${vmid}" >> "${FIXTURE_DIR}/state/backup-vmids.tsv"
}

mark_active_migration() {
  local vmid="$1"
  cat > "${FIXTURE_DIR}/state/tasks.json" <<EOF
[{"upid":"UPID:pve01:00000000:00000000:00000000:qmigrate:${vmid}:root@pam:","status":"running"}]
EOF
}

run_realign() {
  local extra_args=("$@")
  set +e
  (
    export PATH="${FIXTURE_DIR}/shims:${PATH}"
    export FIXTURE_DIR
    cd "${FIXTURE_DIR}/repo"
    ./framework/scripts/realign-cidata.sh "${extra_args[@]+${extra_args[@]}}"
  ) > "${FIXTURE_DIR}/output.log" 2>&1
  local rc=$?
  set -e
  echo "${rc}" > "${FIXTURE_DIR}/exit-code"
  return 0
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

first_line() {
  grep -nF "$1" "${FIXTURE_DIR}/events.log" 2>/dev/null | head -1 | cut -d: -f1 || true
}

last_line() {
  grep -nF "$1" "${FIXTURE_DIR}/events.log" 2>/dev/null | tail -1 | cut -d: -f1 || true
}

assert_event_order() {
  local before="$1" after="$2" desc="$3" b a
  b="$(first_line "${before}")"
  a="$(first_line "${after}")"
  if [[ -n "${b}" && -n "${a}" && "${b}" -lt "${a}" ]]; then
    test_pass "${desc}"
  else
    test_fail "${desc}"
    cat "${FIXTURE_DIR}/events.log" >&2
  fi
}

assert_no_raw_g7() {
  if grep -Eq '^[[:space:]]+(qm|ha-manager|zfs)[[:space:]]' "${FIXTURE_DIR}/output.log"; then
    test_fail "G7 output contains raw cluster command"
    cat "${FIXTURE_DIR}/output.log" >&2
  else
    test_pass "G7 output names only framework commands"
  fi
}

# ---------------------------------------------------------------------------

test_start "A1.path-a" "stopped HA-error victim uses disabled->started, no remove/no stop"
setup_case "path-a"
add_victim pve01 160 ide2 1 stopped error
add_zvol pve01 "vm-160-cloudinit" "18.5K"
run_realign --vmid 160
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || { cat "${FIXTURE_DIR}/output.log" >&2; test_fail "exits 0"; }
event_has "MUTATE ha-manager set vm:160 --state disabled" && test_pass "disabled ladder issued" || test_fail "disabled ladder issued"
event_has "MUTATE ha-manager set vm:160 --state started" && test_pass "started ladder issued" || test_fail "started ladder issued"
event_not_has "MUTATE ha-manager remove vm:160" && test_pass "no HA remove" || test_fail "no HA remove"
event_not_has "MUTATE qm stop 160 --skiplock" && test_pass "no qm stop" || test_fail "no qm stop"
event_has "MUTATE qm set 160 -ide2 vmstore:cloudinit,media=cdrom" && test_pass "canonical repoint used" || test_fail "canonical repoint used"
[[ "$(event_count "MUTATE cleanup --vmid 160 --node pve01")" -eq 2 ]] && test_pass "pre and post scoped cleanup ran" || test_fail "pre and post scoped cleanup ran"
assert_event_order "MUTATE cleanup --vmid 160 --node pve01" "MUTATE qm set 160 -ide2" "stale canonical cleanup happens before reattach"
output_has "SUCCESS: VM 160 realigned" && test_pass "reported success" || test_fail "reported success"

test_start "A1.path-b" "running HA-healthy victim hot-swaps live"
setup_case "path-b"
add_victim pve02 170 ide2 2 running started
run_realign --vmid 170
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
event_has "MUTATE qm set 170 -ide2 vmstore:cloudinit,media=cdrom" && test_pass "hot-swap qm set issued" || test_fail "hot-swap qm set issued"
event_has "VERIFY qm config 170 --current" && test_pass "verified qm config --current" || test_fail "verified qm config --current"
event_not_has "MUTATE qm stop 170 --skiplock" && test_pass "no stop for Path B" || test_fail "no stop for Path B"
event_not_has "MUTATE ha-manager remove vm:170" && test_pass "no HA remove for Path B" || test_fail "no HA remove for Path B"
grep -qF "ide2: vmstore:vm-170-cloudinit,media=cdrom" "${FIXTURE_DIR}/etc-pve/nodes/pve02/qemu-server/170.conf" && test_pass "current config is canonical" || test_fail "current config is canonical"

test_start "A1.path-c" "Path B failure falls back to capture/remove/stop/start/add with group restored"
setup_case "path-c"
add_victim pve03 180 ide2 3 running started dns-prod-a
: > "${FIXTURE_DIR}/fail-qm-set-once-180"
echo 2 > "${FIXTURE_DIR}/stop-count-180"
run_realign --vmid 180
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
output_has "falling back to Path C" && test_pass "fallback announced" || test_fail "fallback announced"
event_has "MUTATE ha-manager remove vm:180" && test_pass "HA removed in fallback" || test_fail "HA removed in fallback"
[[ "$(event_count "MUTATE qm stop 180 --skiplock")" -ge 2 ]] && test_pass "stop loop re-issued" || test_fail "stop loop re-issued"
event_has "MUTATE qm start 180" && test_pass "VM started in fallback" || test_fail "VM started in fallback"
event_has "MUTATE ha-manager add vm:180 --state started --group dns-prod-a" && test_pass "HA add restored group" || test_fail "HA add restored group"
grep -qF "group: dns-prod-a" "${FIXTURE_DIR}/state/ha-config/180" && test_pass "HA config still has group" || test_fail "HA config still has group"

test_start "A1.dry-run" "--dry-run prints a plan and performs zero mutations"
setup_case "dry-run"
add_victim pve01 181 ide2 1 running started
run_realign --vmid 181 --dry-run
[[ "$(exit_code)" -eq 0 ]] && test_pass "dry-run exits 0" || test_fail "dry-run exits 0"
output_has "[DRY-RUN] Path B" && test_pass "dry-run path printed" || test_fail "dry-run path printed"
[[ ! -s "${FIXTURE_DIR}/events.log" ]] && test_pass "zero mutations" || test_fail "zero mutations"

test_start "A1.ambiguous-node" "node mismatch is ambiguous and aborts before mutation"
setup_case "ambiguous-node"
add_victim pve01 190 ide2 1 running started
# Move pvesh ownership away from the config-file node.
awk '$1==190 {$2="pve02"} {print}' "${FIXTURE_DIR}/state/resources.tsv" > "${FIXTURE_DIR}/state/resources.tsv.tmp"
mv "${FIXTURE_DIR}/state/resources.tsv.tmp" "${FIXTURE_DIR}/state/resources.tsv"
run_realign --vmid 190
[[ "$(exit_code)" -eq 1 ]] && test_pass "exits 1" || test_fail "exits 1"
output_has "ABORT: ambiguous owner" && test_pass "ambiguous owner reported" || test_fail "ambiguous owner reported"
[[ ! -s "${FIXTURE_DIR}/events.log" ]] && test_pass "no mutations" || test_fail "no mutations"
assert_no_raw_g7

test_start "A1.ambiguous-migration" "active migration task is ambiguous and aborts"
setup_case "ambiguous-migration"
add_victim pve01 191 ide2 1 running started
mark_active_migration 191
run_realign --vmid 191
[[ "$(exit_code)" -eq 1 ]] && test_pass "exits 1" || test_fail "exits 1"
output_has "active migration task exists" && test_pass "active migration reported" || test_fail "active migration reported"
[[ ! -s "${FIXTURE_DIR}/events.log" ]] && test_pass "no mutations" || test_fail "no mutations"
assert_no_raw_g7

test_start "A1.ha-error-handled" "HA error alone is handled by Path A, not ambiguous"
setup_case "ha-error-handled"
add_victim pve02 192 ide2 1 stopped error
run_realign --vmid 192
[[ "$(exit_code)" -eq 0 ]] && test_pass "HA-error victim exits 0" || test_fail "HA-error victim exits 0"
output_has "Path A" && test_pass "Path A selected" || test_fail "Path A selected"
! output_has "ABORT" && test_pass "no abort on HA error" || test_fail "no abort on HA error"

test_start "A1.stop-timeout" "Path C stop loop reissues and timeout aborts"
setup_case "stop-timeout"
add_victim pve01 200 ide2 1 running started dns-dev-a
: > "${FIXTURE_DIR}/fail-qm-set-once-200"
: > "${FIXTURE_DIR}/stop-timeout-200"
run_realign --vmid 200
[[ "$(exit_code)" -eq 1 ]] && test_pass "exits 1 on stop timeout" || test_fail "exits 1 on stop timeout"
[[ "$(event_count "MUTATE qm stop 200 --skiplock")" -gt 2 ]] && test_pass "stop reissued multiple times" || test_fail "stop reissued multiple times"
event_not_has "MUTATE qm start 200" && test_pass "start not attempted after stop timeout" || test_fail "start not attempted after stop timeout"
assert_no_raw_g7

test_start "A1.start-failure" "Path C start failure leaves victim unswept"
setup_case "start-failure"
add_victim pve02 201 ide2 1 running started dns-dev-b
: > "${FIXTURE_DIR}/fail-qm-set-once-201"
: > "${FIXTURE_DIR}/fail-start-201"
run_realign --vmid 201
[[ "$(exit_code)" -eq 1 ]] && test_pass "exits 1 on start failure" || test_fail "exits 1 on start failure"
event_has "MUTATE qm start 201" && test_pass "start attempted" || test_fail "start attempted"
[[ "$(event_count "MUTATE cleanup --vmid 201 --node pve02")" -eq 1 ]] && test_pass "only pre-cleanup ran; victim not swept after failed start" || test_fail "only pre-cleanup ran"
event_not_has "zfs destroy" && test_pass "no raw zfs destroy of victim" || test_fail "no raw zfs destroy of victim"
assert_no_raw_g7

test_start "A1.scan-failure" "cluster scan failure fails closed"
setup_case "scan-failure"
add_victim pve01 202 ide2 1 running started
: > "${FIXTURE_DIR}/scan-fail"
run_realign --all
[[ "$(exit_code)" -eq 1 ]] && test_pass "exits 1" || test_fail "exits 1"
output_has "could not scan cidata on any cluster member" && test_pass "fail-closed scan error reported" || test_fail "fail-closed scan error reported"
[[ ! -s "${FIXTURE_DIR}/events.log" ]] && test_pass "no mutations" || test_fail "no mutations"
assert_no_raw_g7

test_start "A1.idempotent" "already-canonical VM is skipped"
setup_case "idempotent"
add_canonical pve01 203 ide2 running started
run_realign --all
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
output_has "No rename victims found cluster-wide" && test_pass "reports no victims" || test_fail "reports no victims"
[[ ! -s "${FIXTURE_DIR}/events.log" ]] && test_pass "no mutations" || test_fail "no mutations"

test_start "A1.batch" "3-victim batch stops after VM2 start failure, leaving VM3 untouched"
setup_case "batch"
add_victim pve01 210 ide2 1 running started
add_victim pve02 211 ide2 1 running started dns-dev-b
add_victim pve03 212 ide2 1 running started
: > "${FIXTURE_DIR}/fail-qm-set-once-211"
: > "${FIXTURE_DIR}/fail-start-211"
run_realign --all
[[ "$(exit_code)" -eq 1 ]] && test_pass "batch exits nonzero" || test_fail "batch exits nonzero"
event_has "MUTATE qm set 210 -ide2 vmstore:cloudinit,media=cdrom" && test_pass "VM1 realigned" || test_fail "VM1 realigned"
[[ "$(event_count "MUTATE cleanup --vmid 210 --node pve01")" -eq 2 ]] && test_pass "VM1 swept after success" || test_fail "VM1 swept after success"
event_has "MUTATE qm start 211" && test_pass "VM2 reached start failure" || test_fail "VM2 reached start failure"
[[ "$(event_count "MUTATE cleanup --vmid 211 --node pve02")" -eq 1 ]] && test_pass "VM2 victim left intact after failed start" || test_fail "VM2 victim left intact"
event_not_has "212" && test_pass "VM3 untouched" || test_fail "VM3 untouched"
output_has "Batch stopped after a state-changing failure" && test_pass "batch stop reported" || test_fail "batch stop reported"

test_start "A1.precious" "backup-manifest VM is refused before mutation"
setup_case "precious"
add_victim pve01 220 ide2 1 running started
mark_backup_backed 220
run_realign --vmid 220
[[ "$(exit_code)" -eq 1 ]] && test_pass "exits 1" || test_fail "exits 1"
output_has "REFUSAL: VM 220 is backup-backed" && test_pass "precious-state refusal reported" || test_fail "precious-state refusal reported"
[[ ! -s "${FIXTURE_DIR}/events.log" ]] && test_pass "no mutations" || test_fail "no mutations"
assert_no_raw_g7

runner_summary
