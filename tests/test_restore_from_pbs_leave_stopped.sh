#!/usr/bin/env bash
# test_restore_from_pbs_leave_stopped.sh — fixture checks for --leave-stopped.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
SSH_LOG="${TMP_DIR}/ssh.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/restore-from-pbs.sh" "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-state-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-state-lib.sh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
proxmox:
  storage_pool: vmstore
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
vms:
  pbs:
    ip: 10.0.0.60
  vault_dev:
    vmid: 303
    ip: 10.0.0.23
    backup: true
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${*: -1}"
printf '%s\n' "$cmd" >> "${SSH_LOG}"

case "$cmd" in
  'pvesm status 2>/dev/null')
    if [[ "${STUB_MODE:-success}" == "pbs_storage_missing" ]]; then
      printf '%s\n' 'local active'
      exit 0
    fi
    if [[ "${STUB_MODE:-success}" == "pvesm_fail" ]]; then
      exit 19
    fi
    printf '%s\n' 'pbs-nas active'
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    if [[ "${STUB_MODE:-success}" == "pbs_content_fail" ]]; then
      exit 20
    fi
    printf '%s\n' '[{"vmid":303,"ctime":1000,"volid":"pbs-nas:backup/vm/303/2026-04-12T18:30:00Z"}]'
    ;;
  *'/cluster/resources --type vm --output-format json'*)
    printf '%s\n' '[{"vmid":303,"node":"pve01"}]'
    ;;
  *"qm config 303 2>/dev/null | grep '^scsi1:'"*)
    printf '%s\n' 'vm-303-disk-1'
    ;;
  *'blkid /dev/zvol/vmstore/data/'*)
    printf '%s\n' '0'
    ;;
  'ha-manager remove vm:303')
    ;;
  'qm stop 303 --skiplock 1')
    ;;
  *'qm status 303'*)
    printf '%s\n' 'stopped'
    ;;
  'qm config 303')
    printf '%s\n' 'scsi0: vmstore:vm-303-disk-0,size=16G'
    printf '%s\n' 'scsi1: vmstore:vm-303-disk-1,size=10G'
    ;;
  qmrestore*)
    if [[ "${STUB_MODE:-success}" == "qmrestore_fail" ]]; then
      exit 17
    fi
    ;;
  'qm config 9999')
    printf '%s\n' 'scsi0: vmstore:vm-9999-disk-0,size=16G'
    printf '%s\n' 'scsi1: vmstore:vm-9999-disk-1,size=10G'
    ;;
  dd\ if=*)
    if [[ "${STUB_MODE:-success}" == "dd_fail" ]]; then
      exit 18
    fi
    ;;
  'qm destroy 9999 --purge')
    ;;
  'qm start 303')
    ;;
  'ha-manager add vm:303 --state started')
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"
export SSH_LOG

run_capture() {
  local output=""
  set +e
  output="$(
    cd "${FIXTURE_REPO}" &&
    "$@" 2>&1
  )"
  STATUS=$?
  set -e
  OUTPUT="$output"
}

assert_exit() {
  local expected="$1"
  local label="$2"

  if [[ "$STATUS" -eq "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected exit %s, got %s\n' "$expected" "$STATUS" >&2
    printf '    output:\n%s\n' "$OUTPUT" >&2
  fi
}

assert_log_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq "$needle" "$SSH_LOG"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    missing command: %s\n' "$needle" >&2
    printf '    ssh log:\n%s\n' "$(cat "$SSH_LOG")" >&2
  fi
}

assert_log_absent() {
  local needle="$1"
  local label="$2"

  if grep -Fq "$needle" "$SSH_LOG"; then
    test_fail "$label"
    printf '    unexpected command: %s\n' "$needle" >&2
    printf '    ssh log:\n%s\n' "$(cat "$SSH_LOG")" >&2
  else
    test_pass "$label"
  fi
}

assert_output_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq -- "$needle" <<< "$OUTPUT"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    missing output: %s\n' "$needle" >&2
    printf '    output:\n%s\n' "$OUTPUT" >&2
  fi
}

run_restore() {
  local mode="$1"
  local leave_stopped="$2"
  local with_backup_id="${3:-yes}"

  : > "$SSH_LOG"
  export STUB_MODE="$mode"

  args=(
    framework/scripts/restore-from-pbs.sh
    --target 303
    --force
  )
  if [[ "$with_backup_id" == "yes" ]]; then
    args+=(--backup-id 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z')
  fi
  if [[ "$leave_stopped" == "yes" ]]; then
    args+=(--leave-stopped)
  fi

  run_capture "${args[@]}"
}

test_start "13.1" "default restore still starts VM and re-adds HA"
run_restore success no
assert_exit 0 "default restore succeeds"
assert_log_contains "qm start 303" "default mode starts VM"
assert_log_contains "ha-manager add vm:303 --state started" "default mode re-adds HA"

test_start "13.2" "--leave-stopped success path emits no start or HA add"
run_restore success yes
assert_exit 0 "leave-stopped restore succeeds"
assert_log_contains "qm destroy 9999 --purge" "temp VM is still cleaned up after successful copy"
assert_log_absent "qm start 303" "leave-stopped does not start VM"
assert_log_absent "ha-manager add vm:303 --state started" "leave-stopped does not re-add HA"

test_start "13.3" "--leave-stopped qmrestore failure emits no start or HA add"
run_restore qmrestore_fail yes
assert_exit 1 "qmrestore failure is fatal"
assert_log_absent "qm start 303" "qmrestore failure leaves VM stopped"
assert_log_absent "ha-manager add vm:303 --state started" "qmrestore failure leaves HA absent"

test_start "13.4" "--leave-stopped dd failure emits no start or HA add"
run_restore dd_fail yes
assert_exit 1 "dd failure is fatal"
assert_log_absent "qm destroy 9999 --purge" "temp VM 9999 is preserved after dd failure"
assert_log_absent "qm start 303" "dd failure leaves VM stopped"
assert_log_absent "ha-manager add vm:303 --state started" "dd failure leaves HA absent"

test_start "13.5" "--leave-stopped fails closed when pbs-nas storage is absent"
run_restore pbs_storage_missing yes
assert_exit 1 "missing PBS storage is fatal"
assert_log_absent "qmrestore" "restore is not attempted without registered PBS storage"
assert_log_absent "qm start 303" "missing PBS storage leaves VM stopped"
assert_log_absent "ha-manager add vm:303 --state started" "missing PBS storage leaves HA absent"

test_start "13.6" "--leave-stopped fails closed when PBS content query fails"
run_restore pbs_content_fail yes no
assert_exit 1 "PBS content query failure is fatal"
assert_log_absent "qmrestore" "restore is not attempted after PBS query failure"
assert_log_absent "qm start 303" "PBS query failure leaves VM stopped"
assert_log_absent "ha-manager add vm:303 --state started" "PBS query failure leaves HA absent"

test_start "13.7" "--leave-stopped fails closed when pvesm status fails"
run_restore pvesm_fail yes
assert_exit 1 "pvesm status failure is fatal"
assert_output_contains "Could not query Proxmox storage status" "pvesm failure error is explicit"
assert_log_absent "/storage/pbs-nas/content" "PBS content is not queried after pvesm failure"
assert_log_absent "qmrestore" "restore is not attempted after pvesm failure"
assert_log_absent "qm start 303" "pvesm failure leaves VM stopped"
assert_log_absent "ha-manager add vm:303 --state started" "pvesm failure leaves HA absent"

runner_summary
