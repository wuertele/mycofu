#!/usr/bin/env bash
# Ratchets that ballooned VMs use stop/start relocate, never live migrate.

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
  printf 'balloon: 0\n' > "${FIXTURE_DIR}/state/qm-config"

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
  if [[ -f "${FIXTURE_DIR}/state/moved" ]]; then
    node="$(cat "${FIXTURE_DIR}/state/intended-node")"
  else
    node="$(cat "${FIXTURE_DIR}/state/actual-node")"
  fi
  printf '[{"type":"qemu","vmid":510,"name":"drift-vm","node":"%s","status":"running"}]\n' "${node}"
}

emit_ha_status() {
  local state node
  state="$(cat "${FIXTURE_DIR}/state/ha-state")"
  if [[ -f "${FIXTURE_DIR}/state/moved" ]]; then
    node="$(cat "${FIXTURE_DIR}/state/intended-node")"
  else
    node="$(cat "${FIXTURE_DIR}/state/actual-node")"
  fi
  printf 'service vm:510 (%s, %s)\n' "${node}" "${state}"
}

current_owner_node() {
  if [[ -f "${FIXTURE_DIR}/state/moved" ]]; then
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
    [[ ! -f "${FIXTURE_DIR}/fail-qm-config" ]] || exit 1
    owner="$(current_owner_node)"
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
    printf '%s\n__rc=0\n' "${refer}"
    exit 0
    ;;
  *"zfs destroy"*)
    zvol="$(zvol_from_remote)"
    log_event "MUTATE zfs destroy@${node_ip} ${POOL}/data/${zvol}"
    rm -f "${FIXTURE_DIR}/state/zvols/${node_name}/${zvol}"
    exit 0
    ;;
  *"ha-manager crm-command relocate vm:510 pve01"*)
    log_event "MUTATE relocate vm:510 pve01"
    : > "${FIXTURE_DIR}/state/moved"
    exit 0
    ;;
  *"ha-manager migrate vm:510 pve01"*)
    log_event "MUTATE migrate vm:510 pve01"
    : > "${FIXTURE_DIR}/state/moved"
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

set_qm_config() {
  printf '%s\n' "$1" > "${FIXTURE_DIR}/state/qm-config"
  rm -f "${FIXTURE_DIR}/fail-qm-config"
}

run_rebalance() {
  set +e
  (
    export FIXTURE_DIR POOL
    export PATH="${FIXTURE_DIR}/shims:${PATH}"
    export MYCOFU_REBALANCE_VERIFY_TIMEOUT=0
    export MYCOFU_REBALANCE_VERIFY_INTERVAL=1
    cd "${FIXTURE_DIR}/repo"
    bash framework/scripts/rebalance-cluster.sh
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

script_has_move_primitive() {
  awk '
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
    }
    line ~ /ha-manager[[:space:]]+migrate/ ||
    line ~ /ha-manager[[:space:]]+crm-command[[:space:]]+relocate/ ||
    line ~ /node-maintenance[[:space:]]+enable/ { found=1 }
    END { exit(found ? 0 : 1) }
  ' "$1"
}

static_check_script() {
  local script="$1" guard_lines issue_lines issue_line guard_line has_prior_guard

  script_has_move_primitive "$script" || return 0

  guard_lines="$(awk '
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
    }
    line ~ /cidata_guard_node_change/ && line !~ /required_fn/ { print FNR }
  ' "$script")"
  if [[ -z "${guard_lines}" ]]; then
    echo "${script}: no cidata_guard_node_change call protects node-changing primitive" >&2
    return 1
  fi

  issue_lines="$(awk '
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
    }
    line ~ /^[[:space:]]*ha-manager[[:space:]]+migrate[[:space:]]/ { print FNR; next }
    line ~ /^[[:space:]]*ha-manager[[:space:]]+crm-command[[:space:]]+relocate[[:space:]]/ { print FNR; next }
    line ~ /^[[:space:]]*ha-manager[[:space:]]+crm-command[[:space:]]+node-maintenance[[:space:]]+enable[[:space:]]/ { print FNR; next }
    line ~ /ssh .*"\$MOVE_CMD"/ { print FNR; next }
  ' "$script")"
  if [[ -z "${issue_lines}" ]]; then
    echo "${script}: contains node-changing primitive but no issuing line was classified" >&2
    return 1
  fi

  for issue_line in ${issue_lines}; do
    has_prior_guard=0
    for guard_line in ${guard_lines}; do
      if [[ "${guard_line}" -lt "${issue_line}" ]]; then
        has_prior_guard=1
        break
      fi
    done
    if [[ "${has_prior_guard}" -ne 1 ]]; then
      echo "${script}:${issue_line}: node-changing primitive lacks earlier cidata_guard_node_change call" >&2
      return 1
    fi
  done
}

static_check_tree() {
  local dir="$1" script failed=0
  for script in "${dir}"/*.sh "${dir}"/lib/*.sh; do
    [[ -e "$script" ]] || continue
    static_check_script "$script" || failed=1
  done
  [[ "${failed}" -eq 0 ]]
}

mutate_guard_comment_only() {
  local src="$1" dst="$2"
  awk '
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      is_issue=0
      if (line ~ /^[[:space:]]*ha-manager[[:space:]]+migrate[[:space:]]/) is_issue=1
      if (line ~ /^[[:space:]]*ha-manager[[:space:]]+crm-command[[:space:]]+relocate[[:space:]]/) is_issue=1
      if (line ~ /^[[:space:]]*ha-manager[[:space:]]+crm-command[[:space:]]+node-maintenance[[:space:]]+enable[[:space:]]/) is_issue=1
      if (line ~ /ssh .*"\$MOVE_CMD"/) is_issue=1
    }
    line ~ /cidata_guard_node_change/ && line !~ /required_fn/ { next }
    !inserted && is_issue {
      print $0 " # cidata_guard_node_change moved-to-comment"
      inserted=1
      next
    }
    { print }
  ' "$src" > "$dst"
}

mutate_guard_after_issue() {
  local src="$1" dst="$2"
  awk '
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      is_issue=0
      if (line ~ /^[[:space:]]*ha-manager[[:space:]]+migrate[[:space:]]/) is_issue=1
      if (line ~ /^[[:space:]]*ha-manager[[:space:]]+crm-command[[:space:]]+relocate[[:space:]]/) is_issue=1
      if (line ~ /^[[:space:]]*ha-manager[[:space:]]+crm-command[[:space:]]+node-maintenance[[:space:]]+enable[[:space:]]/) is_issue=1
      if (line ~ /ssh .*"\$MOVE_CMD"/) is_issue=1
    }
    guard == "" && line ~ /cidata_guard_node_change/ && line !~ /required_fn/ {
      guard=$0
      next
    }
    line ~ /cidata_guard_node_change/ && line !~ /required_fn/ { next }
    {
      print
      if (!inserted && is_issue) {
        if (guard == "") {
          guard="cidata_guard_node_change moved_after_issue"
        }
        print guard
        inserted=1
      }
    }
  ' "$src" > "$dst"
}

test_start "ballooned.1" "ballooned drift VM relocates and never live-migrates"
setup_case "ballooned"
set_qm_config $'balloon: 8192\nmemory: 32768'
run_rebalance
assert_exit 0 "rebalance exits 0"
event_has "READ qm-config@${SOURCE_IP}" && test_pass "qm config read from current owner" || test_fail "qm config read from current owner"
event_not_has "READ qm-config@${DEST_IP}" && test_pass "qm config not read from non-owner destination" || test_fail "qm config not read from non-owner destination"
event_has "MUTATE relocate vm:510 pve01" && test_pass "relocate executed" || test_fail "relocate executed"
event_not_has "MUTATE migrate" && test_pass "no live migrate" || test_fail "no live migrate"

test_start "ballooned.2" "fixed drift VM still live-migrates"
setup_case "fixed"
set_qm_config $'balloon: 0\nmemory: 32768'
run_rebalance
assert_exit 0 "rebalance exits 0"
event_has "MUTATE migrate vm:510 pve01" && test_pass "migrate executed" || test_fail "migrate executed"
event_not_has "MUTATE relocate" && test_pass "no relocate" || test_fail "no relocate"

test_start "ballooned.3" "unreadable qm config aborts before any move primitive"
setup_case "qm-config-unreadable"
: > "${FIXTURE_DIR}/fail-qm-config"
run_rebalance
assert_nonzero_exit "rebalance exits non-zero"
event_not_has "MUTATE migrate" && test_pass "no migrate" || test_fail "no migrate"
event_not_has "MUTATE relocate" && test_pass "no relocate" || test_fail "no relocate"
output_has "cannot determine whether vm:${VMID} is ballooned" && output_has "fail-closed" && test_pass "output says fail-closed" || test_fail "output says fail-closed"

test_start "static.1" "node-changing primitives are guarded before issue"
if static_check_tree "${REPO_ROOT}/framework/scripts"; then
  test_pass "framework/scripts node-changing primitives are statically guarded"
else
  test_fail "framework/scripts node-changing primitives are statically guarded"
fi

test_start "static.2" "ratchet detects stripped guard calls in every moving script"
MUTATION_DIR="${TMP_DIR}/static-mutants"
mkdir -p "${MUTATION_DIR}"
found_moving_script=0
for script in "${REPO_ROOT}"/framework/scripts/*.sh "${REPO_ROOT}"/framework/scripts/lib/*.sh; do
  [[ -e "$script" ]] || continue
  if script_has_move_primitive "$script"; then
    found_moving_script=1
    mutant="${MUTATION_DIR}/$(basename "$script")"
    sed '/cidata_guard_node_change/d' "$script" > "$mutant"
    if static_check_script "$mutant" >/dev/null 2>&1; then
      test_fail "mutated $(basename "$script") fails static check"
    else
      test_pass "mutated $(basename "$script") fails static check"
    fi
  fi
done
[[ "${found_moving_script}" -eq 1 ]] && test_pass "self-test exercised at least one moving script" || test_fail "self-test exercised at least one moving script"

test_start "static.3" "ratchet ignores trailing cidata_guard_node_change comments"
found_moving_script=0
for script in "${REPO_ROOT}"/framework/scripts/*.sh "${REPO_ROOT}"/framework/scripts/lib/*.sh; do
  [[ -e "$script" ]] || continue
  if script_has_move_primitive "$script"; then
    found_moving_script=1
    mutant="${MUTATION_DIR}/comment-$(basename "$script")"
    mutate_guard_comment_only "$script" "$mutant"
    if static_check_script "$mutant" >/dev/null 2>&1; then
      test_fail "comment-spoofed $(basename "$script") fails static check"
    else
      test_pass "comment-spoofed $(basename "$script") fails static check"
    fi
  fi
done
[[ "${found_moving_script}" -eq 1 ]] && test_pass "comment self-test exercised at least one moving script" || test_fail "comment self-test exercised at least one moving script"

test_start "static.4" "ratchet detects guard calls moved after node-changing issue lines"
found_moving_script=0
for script in "${REPO_ROOT}"/framework/scripts/*.sh "${REPO_ROOT}"/framework/scripts/lib/*.sh; do
  [[ -e "$script" ]] || continue
  if script_has_move_primitive "$script"; then
    found_moving_script=1
    mutant="${MUTATION_DIR}/after-$(basename "$script")"
    mutate_guard_after_issue "$script" "$mutant"
    if static_check_script "$mutant" >/dev/null 2>&1; then
      test_fail "guard-after-issue $(basename "$script") fails static check"
    else
      test_pass "guard-after-issue $(basename "$script") fails static check"
    fi
  fi
done
[[ "${found_moving_script}" -eq 1 ]] && test_pass "ordering self-test exercised at least one moving script" || test_fail "ordering self-test exercised at least one moving script"

runner_summary
