#!/usr/bin/env bash
# Sprint 038: PBS freshness distinguishes first-deploy empty from fail-closed errors.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d -t validate-pbs-empty.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/validate.sh" "${FIXTURE_REPO}/framework/scripts/validate.sh"
cp "${REPO_ROOT}/framework/scripts/list-backup-backed-vmids.sh" "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/validate.sh" "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh"

cat > "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
certbot_cluster_expected_mode() { echo "staging"; }
certbot_cluster_expected_url() { echo "https://staging.invalid/directory"; }
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
domain: example.test
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
nas:
  ip: 10.0.0.200
vms:
  pbs:
    ip: 10.0.0.60
  gatus:
    ip: 10.0.0.62
  gitlab:
    vmid: 150
    ip: 10.0.0.50
    backup: true
  vault_dev:
    vmid: 303
    ip: 10.0.0.53
    backup: true
replication:
  health_port: 9100
proxmox:
  storage_pool: vmstore
pbs:
  backup_schedule: "02:00"
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${*: -1}"
now="$(date +%s)"
fresh=$((now - 3600))
stale=$((now - 200000))

case "${cmd}" in
  *'pvesm status'*)
    printf '%s\n' 'pbs-nas active'
    ;;
  *'--vmid 150'*)
    case "${STUB_PBS_MODE}" in
      all-zero|mixed-zero) printf '[]\n' ;;
      query-fail) echo "simulated pvesh failure" >&2; exit 55 ;;
      invalid-json) printf '{not-json\n' ;;
      *) printf '[{"vmid":150,"ctime":%s,"volid":"pbs-nas:backup/vm/150/fresh"}]\n' "${fresh}" ;;
    esac
    ;;
  *'--vmid 303'*)
    case "${STUB_PBS_MODE}" in
      all-zero) printf '[]\n' ;;
      mixed-zero) printf '[{"vmid":303,"ctime":%s,"volid":"pbs-nas:backup/vm/303/stale"}]\n' "${stale}" ;;
      query-fail|invalid-json) printf '[{"vmid":303,"ctime":%s,"volid":"pbs-nas:backup/vm/303/fresh"}]\n' "${fresh}" ;;
      *) printf '[{"vmid":303,"ctime":%s,"volid":"pbs-nas:backup/vm/303/fresh"}]\n' "${fresh}" ;;
    esac
    ;;
  *)
    echo "unexpected ssh invocation: $*" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

run_validate_freshness() {
  local mode="$1"

  set +e
  OUTPUT="$(
    cd "${FIXTURE_REPO}" &&
    PATH="${SHIM_DIR}:${PATH}" MYCOFU_VALIDATE_ONLY_PBS_FRESHNESS=1 STUB_PBS_MODE="${mode}" \
      framework/scripts/validate.sh 2>&1
  )"
  STATUS=$?
  set -e
}

assert_status() {
  local expected="$1"
  local label="$2"

  if [[ "${STATUS}" -eq "${expected}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected %s got %s\n    output:\n%s\n' "${expected}" "${STATUS}" "${OUTPUT}" >&2
  fi
}

assert_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq -- "${needle}" <<< "${OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing: %s\n    output:\n%s\n' "${needle}" "${OUTPUT}" >&2
  fi
}

test_start "all-zero" "no backups for any expected VMID is a first-deploy SKIP"
run_validate_freshness all-zero
assert_status 0 "all-zero exits successfully as a skip"
assert_contains "[SKIP] PBS backup freshness" "all-zero output is a skip"
assert_contains "no backups for any expected VMID" "skip reason is explicit"

test_start "mixed-zero-stale" "zero backups for one VM while peers have backups is fatal"
run_validate_freshness mixed-zero
assert_status 1 "mixed zero plus stale exits non-zero"
assert_contains "150" "mixed output names zero VMID"
assert_contains "NO_BACKUP" "mixed output marks zero VMID"
assert_contains "303" "mixed output names stale peer"
assert_contains "STALE" "mixed output marks stale peer"

test_start "query-fail" "PBS query failure fails closed"
run_validate_freshness query-fail
assert_status 1 "query failure exits non-zero"
assert_contains "query failed" "query failure is explicit"

test_start "invalid-json" "invalid PBS JSON fails closed"
run_validate_freshness invalid-json
assert_status 1 "invalid JSON exits non-zero"
assert_contains "invalid JSON" "invalid JSON is explicit"

test_start "unsupported-schedule" "non-HH:MM backup schedule fails closed"
yq -i '.pbs.backup_schedule = "mon,wed,fri 02:00"' "${FIXTURE_REPO}/site/config.yaml"
run_validate_freshness all-zero
assert_status 1 "unsupported schedule exits non-zero"
assert_contains "Only bare HH:MM daily schedules are supported" "unsupported schedule error is explicit"

runner_summary
