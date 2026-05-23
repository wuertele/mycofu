#!/usr/bin/env bash
# Shared fixture for restore-before-start failure-injection tests.

preboot_fixture_setup() {
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
target=""
args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      target="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'restore-from-pbs.sh %s\n' "${args[*]}" >> "${RESTORE_LOG}"
if [[ -n "${STUB_RESTORE_FAIL_TARGET:-}" && "$target" == "${STUB_RESTORE_FAIL_TARGET}" ]]; then
  exit "${STUB_RESTORE_EXIT:-42}"
fi
exit 0
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
    default_resources='[{"vmid":303,"node":"pve01"},{"vmid":304,"node":"pve01"},{"vmid":403,"node":"pve01"}]'
    printf '%s\n' "${STUB_CLUSTER_RESOURCES:-$default_resources}"
    ;;
  *'qm status 303'*)
    printf '%s\n' "${STUB_VM_STATUS_303:-stopped}"
    ;;
  *'qm status 304'*)
    printf '%s\n' "${STUB_VM_STATUS_304:-stopped}"
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
  'ha-manager remove vm:303'|'ha-manager remove vm:304'|'ha-manager remove vm:403')
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
}

preboot_reset_fixture() {
  : > "$SSH_LOG"
  : > "$RESTORE_LOG"
  rm -f "$STATUS_FILE" "$MANIFEST_FILE" "$PIN_FILE" "$ALLOW_FILE"
  unset STUB_CLUSTER_RESOURCES STUB_VM_STATUS_303 STUB_VM_STATUS_304 STUB_VM_STATUS_403
  unset STUB_HA_STATUS STUB_PVESM_STATUS STUB_PVESM_STATUS_EXIT
  unset STUB_PBS_CONTENT STUB_PBS_CONTENT_EXIT STUB_RESTORE_FAIL_TARGET STUB_RESTORE_EXIT
  unset FIRST_DEPLOY_ALLOW_VMIDS CI ALLOW_UNPINNED_RESTORE
}

preboot_run_capture() {
  local output=""
  set +e
  output="$(
    cd "${FIXTURE_REPO}" &&
    framework/scripts/restore-before-start.sh dev \
      --manifest "$MANIFEST_FILE" \
      --pin-file "$PIN_FILE" \
      --first-deploy-allow-file "$ALLOW_FILE" \
      --status-file "$STATUS_FILE" \
      2>&1
  )"
  STATUS=$?
  set -e
  OUTPUT="$output"
}

preboot_assert_exit() {
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

preboot_assert_output_contains() {
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

preboot_assert_file_empty() {
  local file="$1"
  local label="$2"

  if [[ ! -s "$file" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected empty file %s, got:\n%s\n' "$file" "$(cat "$file")" >&2
  fi
}

preboot_assert_no_start() {
  local label="$1"

  if ! grep -Eq 'qm start|ha-manager add' "$SSH_LOG" "$RESTORE_LOG"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    ssh log:\n%s\n' "$(cat "$SSH_LOG")" >&2
    printf '    restore log:\n%s\n' "$(cat "$RESTORE_LOG")" >&2
  fi
}

preboot_assert_entry_status() {
  local vmid="$1"
  local expected="$2"
  local label="$3"
  local actual=""

  actual="$(jq -r --argjson vmid "$vmid" '.entries[] | select(.vmid == $vmid) | .status' "$STATUS_FILE" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected VMID %s status %s, got %s\n' "$vmid" "$expected" "${actual:-<missing>}" >&2
    printf '    status file:\n%s\n' "$(cat "$STATUS_FILE" 2>/dev/null || true)" >&2
  fi
}
