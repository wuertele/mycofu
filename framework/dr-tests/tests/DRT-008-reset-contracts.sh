#!/usr/bin/env bash
# DRT-ID: DRT-008
# DRT-NAME: Reset Contract Ratchet
# DRT-TIME: ~2 min
# DRT-DESTRUCTIVE: no
# DRT-DESC: Non-destructive fixture-based contract test for reset-cluster.sh.
#           Verifies legacy-cluster refusal, removed-backup refusal, --test dry-run,
#           and --recover pin-file validation gates without destroying anything.

set -euo pipefail

DRT_ID="DRT-008"
DRT_NAME="Reset Contract Ratchet"

source "$(dirname "$0")/../lib/common.sh"

drt_init

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
PBS_JSON_FILE="${TMP_DIR}/pbs-content.json"
BACKUP_LOG="${TMP_DIR}/backup.log"
DESTRUCTIVE_LOG="${TMP_DIR}/destructive.log"
LEGACY_CLUSTER_FLAG="--clu""ster"
REMOVED_BACKUP_FLAG="--back""up"
REMOVED_BACKUP_TEXT="${REMOVED_BACKUP_FLAG} has been removed"

LAST_OUTPUT=""
LAST_STATUS=0

record_pass() {
  echo "[PASS] $1"
}

record_fail() {
  echo "[FAIL] $1"
  DRT_FAILURES=$((DRT_FAILURES + 1))
  DRT_FAILURE_LIST+=("$1")
}

make_noop_tool() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${path}"
}

setup_fixture_repo() {
  mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${FIXTURE_REPO}/build" "${SHIM_DIR}"

  cp "framework/scripts/reset-cluster.sh" "${FIXTURE_REPO}/framework/scripts/reset-cluster.sh"
  chmod +x "${FIXTURE_REPO}/framework/scripts/reset-cluster.sh"

  cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nas:
  ip: 10.0.0.50
  ssh_user: admin
  postgres_port: 5432
storage:
  pool_name: vmstore
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
vms:
  gitlab:
    vmid: 150
    ip: 10.0.0.31
    backup: true
  vault_dev:
    vmid: 302
    ip: 10.0.0.21
    backup: true
EOF

  cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  cat > "${FIXTURE_REPO}/build/valid-pins.json" <<'EOF'
{
  "version": 1,
  "captured_at": "2026-04-15T13:20:00Z",
  "pins": {
    "150": "pbs-nas:backup/vm/150/2026-04-12T18:30:01Z",
    "302": "pbs-nas:backup/vm/302/2026-04-12T18:30:00Z"
  }
}
EOF

  cat > "${FIXTURE_REPO}/build/incomplete-pins.json" <<'EOF'
{
  "version": 1,
  "captured_at": "2026-04-15T13:20:00Z",
  "pins": {
    "302": "pbs-nas:backup/vm/302/2026-04-12T18:30:00Z"
  }
}
EOF

  cat > "${FIXTURE_REPO}/build/nonexistent-pins.json" <<'EOF'
{
  "version": 1,
  "captured_at": "2026-04-15T13:20:00Z",
  "pins": {
    "150": "pbs-nas:backup/vm/150/2026-04-12T18:30:01Z",
    "302": "pbs-nas:backup/vm/302/2026-04-12T18:39:59Z"
  }
}
EOF

  cat > "${FIXTURE_REPO}/framework/scripts/backup-now.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${STUB_BACKUP_LOG}"
exit 99
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/backup-now.sh"

  cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"

case "${remote_cmd}" in
  *'qm destroy '*|*'zpool destroy '*|*'sgdisk --zap-all '*|*'wipefs -a '*|*'shred -u '*)
    printf '%s\n' "${remote_cmd}" >> "${STUB_DESTRUCTIVE_LOG}"
    exit 97
    ;;
esac

case "${remote_cmd}" in
  *'pvesm status 2>/dev/null | grep -q pbs-nas'*)
    exit 0
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    cat "${STUB_PBS_JSON_FILE}"
    exit 0
    ;;
  *'findmnt -n -o SOURCE /'*)
    printf '%s\n' 'BOOT_DEVICE=nvme0n1'
    printf '%s\n' 'DATA_DEVICES=nvme1n1'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${SHIM_DIR}/ssh"

  for shim_name in sshpass sops git shred; do
    make_noop_tool "${SHIM_DIR}/${shim_name}"
  done
}

run_fixture_capture() {
  LAST_OUTPUT=""
  LAST_STATUS=0
  : > "${BACKUP_LOG}"
  : > "${DESTRUCTIVE_LOG}"

  set +e
  LAST_OUTPUT="$(
    cd "${FIXTURE_REPO}" &&
    PATH="${SHIM_DIR}:${PATH}" \
      STUB_PBS_JSON_FILE="${PBS_JSON_FILE}" \
      STUB_BACKUP_LOG="${BACKUP_LOG}" \
      STUB_DESTRUCTIVE_LOG="${DESTRUCTIVE_LOG}" \
      "$@" 2>&1
  )"
  LAST_STATUS=$?
  set -e
}

assert_exit_code() {
  local expected="$1"
  local desc="$2"

  if [[ "${LAST_STATUS}" -eq "${expected}" ]]; then
    record_pass "${desc}"
  else
    record_fail "${desc}"
    printf '       expected exit %s, got %s\n' "${expected}" "${LAST_STATUS}"
    printf '%s\n' "${LAST_OUTPUT}" | sed 's/^/       /'
  fi
}

assert_nonzero_exit() {
  local desc="$1"

  if [[ "${LAST_STATUS}" -ne 0 ]]; then
    record_pass "${desc}"
  else
    record_fail "${desc}"
    printf '       expected non-zero exit, got 0\n'
    printf '%s\n' "${LAST_OUTPUT}" | sed 's/^/       /'
  fi
}

assert_output_contains() {
  local needle="$1"
  local desc="$2"

  if grep -Fq -- "${needle}" <<< "${LAST_OUTPUT}"; then
    record_pass "${desc}"
  else
    record_fail "${desc}"
    printf '       missing output: %s\n' "${needle}"
    printf '%s\n' "${LAST_OUTPUT}" | sed 's/^/       /'
  fi
}

assert_file_empty() {
  local file="$1"
  local desc="$2"

  if [[ ! -s "${file}" ]]; then
    record_pass "${desc}"
  else
    record_fail "${desc}"
    printf '       file contents:\n'
    sed 's/^/       /' "${file}"
  fi
}

assert_file_absent() {
  local file="$1"
  local desc="$2"

  if [[ ! -e "${file}" ]]; then
    record_pass "${desc}"
  else
    record_fail "${desc}"
    printf '       unexpected file: %s\n' "${file}"
  fi
}

drt_check "reset-cluster.sh exists" test -x framework/scripts/reset-cluster.sh
drt_check "jq available" command -v jq
drt_check "yq available" command -v yq

printf '%s\n' '[
  {"vmid":150,"volid":"pbs-nas:backup/vm/150/2026-04-12T18:30:01Z","size":1048576},
  {"vmid":302,"volid":"pbs-nas:backup/vm/302/2026-04-12T18:30:00Z","size":1048576}
]' > "${PBS_JSON_FILE}"

setup_fixture_repo

drt_step "Refusing the legacy cluster flag"
run_fixture_capture framework/scripts/reset-cluster.sh "${LEGACY_CLUSTER_FLAG}" --confirm
assert_exit_code 1 "legacy cluster flag exits non-zero with a hard break"
assert_output_contains "--test" "deprecation output names --test"
assert_output_contains "--recover" "deprecation output names --recover"

drt_step "Refusing the removed backup flag"
run_fixture_capture framework/scripts/reset-cluster.sh --vms "${REMOVED_BACKUP_FLAG}" --confirm
assert_exit_code 1 "removed backup flag exits non-zero"
assert_output_contains "${REMOVED_BACKUP_TEXT}" "removed flag output is explicit"

drt_step "Keeping --test dry-run only"
run_fixture_capture framework/scripts/reset-cluster.sh --test
assert_exit_code 0 "--test without --confirm succeeds as dry-run"
assert_output_contains "Verified backup:" "--test dry-run shows the verified backup preflight"
assert_file_empty "${BACKUP_LOG}" "--test dry-run does not invoke backup-now.sh"

drt_step "Requiring a restore pin file for --recover"
run_fixture_capture framework/scripts/reset-cluster.sh --recover
assert_exit_code 1 "--recover without --restore-pin-file exits non-zero"
assert_output_contains "requires --restore-pin-file" "missing pin file error is explicit"

drt_step "Validating a complete --recover pin file in dry-run"
run_fixture_capture framework/scripts/reset-cluster.sh --recover --restore-pin-file build/valid-pins.json
assert_exit_code 0 "valid restore pin file passes dry-run validation"
assert_output_contains "All precious-state VMs are covered by restore pins" "valid restore pin file reports full coverage"
assert_file_absent "${FIXTURE_REPO}/build/restore-pin-reset.json" "dry-run does not normalize the restore pin file"

drt_step "Rejecting an incomplete --recover pin file"
run_fixture_capture framework/scripts/reset-cluster.sh --recover --restore-pin-file build/incomplete-pins.json
assert_nonzero_exit "incomplete restore pin file exits non-zero"
assert_output_contains "has no restore pin" "incomplete restore pin file names the uncovered VM"

drt_step "Rejecting a nonexistent pinned volid"
run_fixture_capture framework/scripts/reset-cluster.sh --recover --restore-pin-file build/nonexistent-pins.json
assert_exit_code 1 "nonexistent pinned volid exits non-zero"
assert_output_contains "not found in PBS" "nonexistent pinned volid is reported explicitly"

drt_step "Confirming no destructive path was reached"
assert_file_empty "${DESTRUCTIVE_LOG}" "no destructive remote commands were issued in dry-run contract tests"

drt_finish
