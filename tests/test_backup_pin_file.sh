#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
PBS_JSON_FILE="${TMP_DIR}/pbs-content.json"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${FIXTURE_REPO}/build" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/backup-now.sh" "${FIXTURE_REPO}/framework/scripts/backup-now.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/backup-now.sh"

cat > "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

certbot_cluster_expected_mode() { echo "staging"; }
certbot_cluster_expected_url() { echo "https://staging.invalid/directory"; }
certbot_cluster_prod_shared_backup_certbot_records() { return 0; }
certbot_cluster_run_remote_helper() { return 0; }
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh"

cat > "${FIXTURE_REPO}/framework/scripts/vm-health-lib.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

VM_HEALTH_LAST_REASON=""
VM_HEALTH_LAST_CLASS=""

vm_health_check() {
  local vm_key="$1"
  local label="$2"
  local _vm_ip="$3"
  local _host_ip="$4"
  local _vmid="$5"

  case " ${STUB_HEALTH_FAIL_KEYS:-} " in
    *" ${vm_key} "*)
      VM_HEALTH_LAST_REASON="${label}: simulated health failure"
      VM_HEALTH_LAST_CLASS="unhealthy"
      echo "${VM_HEALTH_LAST_REASON}" >&2
      return 1
      ;;
    *)
      VM_HEALTH_LAST_REASON=""
      VM_HEALTH_LAST_CLASS=""
      return 0
      ;;
  esac
}
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/vm-health-lib.sh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
  - name: pve02
    mgmt_ip: 10.0.0.12
proxmox:
  storage_pool: vmstore
vms:
  vault_dev:
    vmid: 303
    ip: 10.0.0.23
    backup: true
  vault_prod:
    vmid: 403
    ip: 10.0.0.24
    backup: true
  gitlab:
    vmid: 150
    ip: 10.0.0.25
    backup: true
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

append_backup_record() {
  local vmid="$1"
  local ctime="$2"
  local volid="$3"
  local size=1048576
  local verify_state="ok"

  case " ${STUB_ZERO_SIZE_VMIDS:-} " in
    *" ${vmid} "*)
      size=0
      ;;
  esac

  case " ${STUB_VERIFY_FAIL_VMIDS:-} " in
    *" ${vmid} "*)
      verify_state="failed"
      ;;
  esac

  jq \
    --argjson vmid "$vmid" \
    --argjson ctime "$ctime" \
    --arg volid "$volid" \
    --argjson size "$size" \
    --arg state "$verify_state" \
    '. + [{"vmid":$vmid,"ctime":$ctime,"volid":$volid,"size":$size,"verification":{"state":$state}}]' \
    "$STUB_PBS_JSON_FILE" > "${STUB_PBS_JSON_FILE}.tmp"
  mv "${STUB_PBS_JSON_FILE}.tmp" "$STUB_PBS_JSON_FILE"
}

host=""
for arg in "$@"; do
  if [[ "$arg" == root@* ]]; then
    host="${arg#root@}"
  fi
done
cmd="${*: -1}"

case "$cmd" in
  *'pvesm status'*)
    exit 0
    ;;
  'qm status 303')
    [[ "$host" == "10.0.0.11" ]] && exit 0 || exit 1
    ;;
  'qm status 403')
    [[ "$host" == "10.0.0.12" ]] && exit 0 || exit 1
    ;;
  'qm status 150')
    [[ "$host" == "10.0.0.11" ]] && exit 0 || exit 1
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    cat "$STUB_PBS_JSON_FILE"
    exit 0
    ;;
  'vzdump 303 --storage pbs-nas --mode snapshot --compress zstd --quiet 1')
    append_backup_record 303 1001 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z'
    exit 0
    ;;
  'vzdump 150 --storage pbs-nas --mode snapshot --compress zstd --quiet 1')
    append_backup_record 150 1002 'pbs-nas:backup/vm/150/2026-04-12T18:30:01Z'
    exit 0
    ;;
  'vzdump 403 --storage pbs-nas --mode snapshot --compress zstd --quiet 1')
    append_backup_record 403 1003 'pbs-nas:backup/vm/403/2026-04-12T18:30:02Z'
    exit 0
    ;;
  *)
    echo "unexpected ssh invocation: $*" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

run_capture() {
  local fixture_repo="$1"
  shift
  local output=""
  set +e
  output="$(
    cd "${fixture_repo}" &&
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

assert_output_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq "$needle" <<< "$OUTPUT"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    missing output: %s\n' "$needle" >&2
    printf '    output:\n%s\n' "$OUTPUT" >&2
  fi
}

export PATH="${SHIM_DIR}:${PATH}"
export STUB_PBS_JSON_FILE="${PBS_JSON_FILE}"

test_start "12.7" "backup-now excludes shared Tier 2 VMs from env-scoped pipeline backups"
printf '%s\n' '[]' > "${PBS_JSON_FILE}"
unset STUB_HEALTH_FAIL_KEYS
run_capture "${FIXTURE_REPO}" framework/scripts/backup-now.sh --env dev --pin-out build/pin-dev.json
assert_exit 0 "backup-now succeeds for healthy dev VMs"
if jq -e '.version == 1' "${FIXTURE_REPO}/build/pin-dev.json" >/dev/null 2>&1; then
  test_pass "pin file version is 1"
else
  test_fail "pin file version is 1"
fi
if [[ "$(jq -r '.pins | length' "${FIXTURE_REPO}/build/pin-dev.json")" == "1" ]]; then
  test_pass "env-scoped pin file only includes Tier 1 VM backups"
else
  test_fail "env-scoped pin file only includes Tier 1 VM backups"
  jq . "${FIXTURE_REPO}/build/pin-dev.json" >&2
fi
if [[ "$(jq -r '.pins["303"]' "${FIXTURE_REPO}/build/pin-dev.json")" == 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z' ]]; then
  test_pass "vault_dev pin was recorded"
else
  test_fail "vault_dev pin was recorded"
fi
if [[ "$(jq -r '.pins["150"] // empty' "${FIXTURE_REPO}/build/pin-dev.json")" == "" ]]; then
  test_pass "gitlab is excluded from env-scoped backups"
else
  test_fail "gitlab is excluded from env-scoped backups"
  jq . "${FIXTURE_REPO}/build/pin-dev.json" >&2
fi

test_start "12.8" "backup-now still includes shared Tier 2 VMs in full-cluster backups"
printf '%s\n' '[]' > "${PBS_JSON_FILE}"
unset STUB_HEALTH_FAIL_KEYS
run_capture "${FIXTURE_REPO}" framework/scripts/backup-now.sh --env all --pin-out build/pin-all.json
assert_exit 0 "backup-now succeeds for healthy full-cluster backups"
if [[ "$(jq -r '.pins | length' "${FIXTURE_REPO}/build/pin-all.json")" == "3" ]]; then
  test_pass "full-cluster pin file includes shared and env-scoped VMs"
else
  test_fail "full-cluster pin file includes shared and env-scoped VMs"
  jq . "${FIXTURE_REPO}/build/pin-all.json" >&2
fi
if [[ "$(jq -r '.pins["150"]' "${FIXTURE_REPO}/build/pin-all.json")" == 'pbs-nas:backup/vm/150/2026-04-12T18:30:01Z' ]]; then
  test_pass "gitlab pin is still recorded for --env all"
else
  test_fail "gitlab pin is still recorded for --env all"
fi

test_start "12.9" "backup-now skips first-deploy health failures when no historical PBS backup exists"
printf '%s\n' '[]' > "${PBS_JSON_FILE}"
export STUB_HEALTH_FAIL_KEYS="vault_prod"
run_capture "${FIXTURE_REPO}" framework/scripts/backup-now.sh --env all --pin-out build/pin-first-deploy.json
assert_exit 0 "first-deploy health failure does not block the backup run"
assert_output_contains "SKIP: vault_prod — first deploy (vault_prod: simulated health failure)" "first-deploy skip is logged"
if [[ "$(jq -r '.pins["403"] // empty' "${FIXTURE_REPO}/build/pin-first-deploy.json")" == "" ]]; then
  test_pass "first-deploy skipped VM is omitted from the pin file"
else
  test_fail "first-deploy skipped VM is omitted from the pin file"
  jq . "${FIXTURE_REPO}/build/pin-first-deploy.json" >&2
fi

test_start "12.10" "backup-now exits non-zero and omits failed VMs when historical data exists"
printf '%s\n' '[]' > "${PBS_JSON_FILE}"
printf '%s\n' '[{"vmid":403,"ctime":999,"volid":"pbs-nas:backup/vm/403/2026-04-11T18:30:00Z"}]' > "${PBS_JSON_FILE}"
export STUB_HEALTH_FAIL_KEYS="vault_prod"
run_capture "${FIXTURE_REPO}" framework/scripts/backup-now.sh --env all --pin-out build/pin-all.json
assert_exit 1 "backup-now fails closed on any health failure"
assert_output_contains "vault_prod" "health failure output names the failing VM"
if jq -e '.version == 1' "${FIXTURE_REPO}/build/pin-all.json" >/dev/null 2>&1; then
  test_pass "pin file is still initialized on failure"
else
  test_fail "pin file is still initialized on failure"
fi
if [[ "$(jq -r '.pins["403"] // empty' "${FIXTURE_REPO}/build/pin-all.json")" == "" ]]; then
  test_pass "failed VM is omitted from the pin file"
else
  test_fail "failed VM is omitted from the pin file"
  jq . "${FIXTURE_REPO}/build/pin-all.json" >&2
fi

test_start "12.11" "backup-now --verify accepts healthy PBS metadata and writes pins after verification"
printf '%s\n' '[]' > "${PBS_JSON_FILE}"
unset STUB_HEALTH_FAIL_KEYS
unset STUB_VERIFY_FAIL_VMIDS
unset STUB_ZERO_SIZE_VMIDS
run_capture "${FIXTURE_REPO}" framework/scripts/backup-now.sh --env all --verify --pin-out build/pin-verified.json
assert_exit 0 "backup-now --verify succeeds for healthy backups"
assert_output_contains "=== Verified 3 backup(s) in PBS metadata ===" "verification summary is printed"
if [[ "$(jq -r '.pins | length' "${FIXTURE_REPO}/build/pin-verified.json")" == "3" ]]; then
  test_pass "verified pin file is written after metadata verification"
else
  test_fail "verified pin file is written after metadata verification"
  jq . "${FIXTURE_REPO}/build/pin-verified.json" >&2
fi

test_start "12.12" "backup-now --verify fails closed when PBS verification metadata reports a bad backup"
printf '%s\n' '[]' > "${PBS_JSON_FILE}"
unset STUB_HEALTH_FAIL_KEYS
export STUB_VERIFY_FAIL_VMIDS="403"
unset STUB_ZERO_SIZE_VMIDS
run_capture "${FIXTURE_REPO}" framework/scripts/backup-now.sh --env all --verify --pin-out build/pin-verify-fail.json
assert_exit 1 "backup-now --verify exits non-zero on verification failure"
assert_output_contains "verification state is 'failed'" "verification failure names the bad PBS record"
if [[ "$(jq -r '.pins | length' "${FIXTURE_REPO}/build/pin-verify-fail.json")" == "0" ]]; then
  test_pass "pin file stays empty when verification fails"
else
  test_fail "pin file stays empty when verification fails"
  jq . "${FIXTURE_REPO}/build/pin-verify-fail.json" >&2
fi

runner_summary
