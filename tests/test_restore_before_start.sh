#!/usr/bin/env bash
# test_restore_before_start.sh — fixture checks for preboot restore orchestration.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
SSH_LOG="${TMP_DIR}/ssh.log"
RESTORE_LOG="${TMP_DIR}/restore.log"
STATUS_FILE="${TMP_DIR}/status.json"
MANIFEST_FILE="${TMP_DIR}/manifest.json"
PIN_FILE="${TMP_DIR}/pin.json"
ALLOW_FILE="${TMP_DIR}/allow.json"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/restore-before-start.sh" \
  "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"

cat > "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-from-pbs.sh %s\n' "$*" >> "${RESTORE_LOG}"
exit "${STUB_RESTORE_EXIT:-0}"
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
vms:
  pbs:
    ip: 10.0.0.60
EOF

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${*: -1}"
printf '%s\n' "$cmd" >> "${SSH_LOG}"

case "$cmd" in
  *'/cluster/resources --type vm --output-format json'*)
    if [[ -n "${STUB_CLUSTER_RESOURCES:-}" ]]; then
      printf '%s\n' "$STUB_CLUSTER_RESOURCES"
    else
      printf '%s\n' '[{"vmid":303,"node":"pve01"},{"vmid":403,"node":"pve01"}]'
    fi
    ;;
  *'qm status 303'*)
    printf '%s\n' "${STUB_VM_STATUS_303:-stopped}"
    ;;
  *'qm status 403'*)
    printf '%s\n' "${STUB_VM_STATUS_403:-stopped}"
    ;;
  'ha-manager status')
    printf '%s\n' "${STUB_HA_STATUS:-}"
    ;;
  'pvesm status 2>/dev/null')
    if [[ -n "${STUB_PVESM_STATUS_EXIT:-}" ]]; then
      exit "$STUB_PVESM_STATUS_EXIT"
    fi
    printf '%s\n' "${STUB_PVESM_STATUS:-pbs-nas active}"
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    if [[ -n "${STUB_PBS_CONTENT_EXIT:-}" ]]; then
      exit "$STUB_PBS_CONTENT_EXIT"
    fi
    printf '%s\n' "${STUB_PBS_CONTENT:-[]}"
    ;;
  'ha-manager remove vm:303')
    ;;
  'ha-manager remove vm:403')
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"
export SSH_LOG RESTORE_LOG

write_manifest() {
  local vmid="$1"
  local label="$2"

  cat > "$MANIFEST_FILE" <<EOF
{
  "version": 1,
  "entries": [
    {
      "label": "${label}",
      "module": "module.${label}",
      "vmid": ${vmid},
      "env": "dev",
      "kind": "infrastructure",
      "reason": "replace"
    }
  ]
}
EOF
}

write_pin() {
  local vmid="$1"
  local volid="$2"

  cat > "$PIN_FILE" <<EOF
{
  "version": 1,
  "pins": {
    "${vmid}": "${volid}"
  }
}
EOF
}

reset_fixture_state() {
  : > "$SSH_LOG"
  : > "$RESTORE_LOG"
  rm -f "$STATUS_FILE" "$MANIFEST_FILE" "$PIN_FILE" "$ALLOW_FILE"
  unset STUB_CLUSTER_RESOURCES STUB_VM_STATUS_303 STUB_VM_STATUS_403
  unset STUB_HA_STATUS STUB_PVESM_STATUS STUB_PVESM_STATUS_EXIT
  unset STUB_PBS_CONTENT STUB_PBS_CONTENT_EXIT STUB_RESTORE_EXIT
  unset FIRST_DEPLOY_ALLOW_VMIDS CI ALLOW_UNPINNED_RESTORE
}

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

run_restore_before_start() {
  framework/scripts/restore-before-start.sh dev \
    --manifest "$MANIFEST_FILE" \
    --pin-file "$PIN_FILE" \
    --first-deploy-allow-file "$ALLOW_FILE" \
    --status-file "$STATUS_FILE"
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

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq -- "$needle" "$file"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    missing file content: %s\n' "$needle" >&2
    printf '    file %s:\n%s\n' "$file" "$(cat "$file" 2>/dev/null || true)" >&2
  fi
}

assert_file_empty() {
  local file="$1"
  local label="$2"

  if [[ ! -s "$file" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected empty file %s, got:\n%s\n' "$file" "$(cat "$file")" >&2
  fi
}

assert_file_lacks() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq -- "$needle" "$file"; then
    test_fail "$label"
    printf '    unexpected file content: %s\n' "$needle" >&2
    printf '    file %s:\n%s\n' "$file" "$(cat "$file" 2>/dev/null || true)" >&2
  else
    test_pass "$label"
  fi
}

assert_status_value() {
  local expected="$1"
  local label="$2"
  local actual=""

  actual="$(jq -r '.entries[0].status // empty' "$STATUS_FILE" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected status %s, got %s\n' "$expected" "${actual:-<missing>}" >&2
    printf '    status file:\n%s\n' "$(cat "$STATUS_FILE" 2>/dev/null || true)" >&2
  fi
}

test_start "14.1" "bad JSON manifest aborts before touching Proxmox"
reset_fixture_state
printf '%s\n' 'not-json' > "$MANIFEST_FILE"
run_capture run_restore_before_start
assert_exit 1 "bad JSON is fatal"
assert_output_contains "malformed manifest JSON" "bad JSON error is explicit"
assert_file_empty "$SSH_LOG" "no Proxmox command is emitted for bad JSON"

test_start "14.2" "missing manifest field aborts before touching Proxmox"
reset_fixture_state
cat > "$MANIFEST_FILE" <<'EOF'
{"entries":[{"label":"vault_dev","module":"module.vault_dev","env":"dev","kind":"infrastructure","reason":"replace"}]}
EOF
run_capture run_restore_before_start
assert_exit 1 "missing vmid is fatal"
assert_output_contains "manifest schema invalid" "schema error is explicit"
assert_file_empty "$SSH_LOG" "no Proxmox command is emitted for schema errors"

test_start "14.3" "pinned restore passes --backup-id and --leave-stopped"
reset_fixture_state
write_manifest 303 vault_dev
write_pin 303 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z'
run_capture run_restore_before_start
assert_exit 0 "pinned restore succeeds"
assert_file_contains "$RESTORE_LOG" "--target 303 --force --backup-id pbs-nas:backup/vm/303/2026-04-12T18:30:00Z --leave-stopped" "restore-from-pbs receives pin and leave-stopped"
assert_status_value "restored" "status JSON records restored"

test_start "14.4" "existing backup without pin is fatal in CI"
reset_fixture_state
write_manifest 303 vault_dev
export CI=1
export STUB_PBS_CONTENT='[{"vmid":303,"ctime":1000,"volid":"pbs-nas:backup/vm/303/2026-04-12T18:30:00Z"}]'
run_capture run_restore_before_start
assert_exit 1 "missing pin with backup is fatal in CI"
assert_output_contains "existing PBS backup found but no pin was supplied in CI" "CI pin error is explicit"
assert_file_empty "$RESTORE_LOG" "restore-from-pbs is not called without CI pin"
assert_status_value "failed" "status JSON records failed CI pin"

test_start "14.5" "no backup without first-deploy approval fails closed"
reset_fixture_state
write_manifest 403 vault_prod
export STUB_PBS_CONTENT='[]'
run_capture run_restore_before_start
assert_exit 1 "missing backup without approval is fatal"
assert_output_contains "FIRST_DEPLOY_ALLOW_VMIDS=403" "error names approval variable"
assert_file_empty "$RESTORE_LOG" "restore-from-pbs is not called without backup"
assert_status_value "failed" "status JSON records missing backup failure"

test_start "14.6" "no backup with first-deploy approval records empty-vdb approval"
reset_fixture_state
write_manifest 403 vault_prod
export STUB_PBS_CONTENT='[]'
export FIRST_DEPLOY_ALLOW_VMIDS=403
run_capture run_restore_before_start
assert_exit 0 "first-deploy approval succeeds"
assert_output_contains "first-deploy approval present; leaving vdb empty" "approval log is explicit"
assert_file_empty "$RESTORE_LOG" "restore-from-pbs is not called for first deploy"
assert_status_value "first-deploy-empty" "status JSON records first-deploy-empty"
assert_file_contains "$ALLOW_FILE" '"vmids": [' "CI variable is converted to a per-run allow file"

test_start "14.7" "restore failure exits non-zero and records failed status"
reset_fixture_state
write_manifest 303 vault_dev
write_pin 303 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z'
export STUB_RESTORE_EXIT=23
run_capture run_restore_before_start
assert_exit 1 "restore failure is fatal"
assert_output_contains "restore failed for vault_dev" "restore failure names VM"
assert_status_value "failed" "status JSON records failed restore"

test_start "14.8" "running VM in manifest aborts before restore"
reset_fixture_state
write_manifest 303 vault_dev
write_pin 303 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z'
export STUB_VM_STATUS_303=running
run_capture run_restore_before_start
assert_exit 1 "running VM is fatal"
assert_output_contains "VM unexpectedly running" "runtime guard error is explicit"
assert_file_empty "$RESTORE_LOG" "restore-from-pbs is not called for running VM"
assert_status_value "failed" "status JSON records running guard failure"

test_start "14.9" "pre-existing HA resource aborts before restore"
reset_fixture_state
write_manifest 303 vault_dev
write_pin 303 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z'
export STUB_HA_STATUS='vm:303 started'
run_capture run_restore_before_start
assert_exit 1 "HA presence is fatal"
assert_output_contains "HA resource vm:303 exists before restore" "HA error is explicit"
assert_file_empty "$RESTORE_LOG" "restore-from-pbs is not called when HA exists"
assert_status_value "failed" "status JSON records HA guard failure"

test_start "14.10" "PBS query failure aborts before first-deploy approval"
reset_fixture_state
write_manifest 303 vault_dev
export FIRST_DEPLOY_ALLOW_VMIDS=303
export STUB_PBS_CONTENT_EXIT=44
run_capture run_restore_before_start
assert_exit 1 "PBS query failure is fatal"
assert_output_contains "could not query PBS backups for vault_dev" "PBS query failure names the unsafe state"
assert_file_empty "$RESTORE_LOG" "restore-from-pbs is not called after PBS query failure"
assert_status_value "failed" "status JSON records PBS query failure"

test_start "14.11" "missing pbs-nas storage honors first-deploy approval"
reset_fixture_state
write_manifest 403 vault_prod
export FIRST_DEPLOY_ALLOW_VMIDS=403
export STUB_PVESM_STATUS='local active'
run_capture run_restore_before_start
assert_exit 0 "known-absent PBS storage can use first-deploy approval"
assert_output_contains "PBS storage pbs-nas is not registered" "known-absent storage path is explicit"
assert_output_contains "first-deploy approval present; leaving vdb empty" "approval still records empty vdb"
assert_file_empty "$RESTORE_LOG" "restore-from-pbs is not called when PBS is known absent"
assert_file_lacks "$SSH_LOG" "/storage/pbs-nas/content" "PBS content query is skipped when storage is known absent"
assert_status_value "first-deploy-empty" "status JSON records known-absent first-deploy approval"

test_start "14.12" "pvesm status failure aborts before first-deploy approval"
reset_fixture_state
write_manifest 303 vault_dev
export FIRST_DEPLOY_ALLOW_VMIDS=303
export STUB_PVESM_STATUS_EXIT=45
run_capture run_restore_before_start
assert_exit 1 "pvesm status failure is fatal"
assert_output_contains "could not query Proxmox storage status for vault_dev" "pvesm failure names the unsafe state"
assert_file_empty "$RESTORE_LOG" "restore-from-pbs is not called after pvesm failure"
assert_file_lacks "$SSH_LOG" "/storage/pbs-nas/content" "PBS content query is skipped after pvesm failure"
assert_status_value "failed" "status JSON records pvesm failure"

runner_summary
