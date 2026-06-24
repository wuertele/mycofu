#!/usr/bin/env bash
# Sprint 038 R1: PBS freshness rejects content for the wrong VMID.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d -t validate-pbs-content.XXXXXX)"
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

case "${cmd}" in
  *'--vmid 150'*)
    printf '[{"vmid":150,"ctime":%s,"volid":"pbs-nas:backup/vm/150/fresh"}]\n' "${fresh}"
    ;;
  *'--vmid 303'*)
    printf '[{"vmid":150,"ctime":%s,"volid":"pbs-nas:backup/vm/150/wrong"}]\n' "${fresh}"
    ;;
  *)
    echo "unexpected ssh invocation: $*" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

test_start "wrong-vmid-content" "content response for another VMID fails closed"
set +e
OUTPUT="$(
  cd "${FIXTURE_REPO}" &&
  PATH="${SHIM_DIR}:${PATH}" MYCOFU_VALIDATE_ONLY_PBS_FRESHNESS=1 \
    framework/scripts/validate.sh 2>&1
)"
STATUS=$?
set -e

if [[ "${STATUS}" -eq 1 ]]; then
  test_pass "wrong-VMID content exits non-zero"
else
  test_fail "wrong-VMID content should fail"
  printf '    status=%s\n    output:\n%s\n' "${STATUS}" "${OUTPUT}" >&2
fi

if grep -Fq "returned backup content for VMID(s): 150" <<< "${OUTPUT}"; then
  test_pass "output names wrong returned VMID"
else
  test_fail "output should name wrong returned VMID"
  printf '    output:\n%s\n' "${OUTPUT}" >&2
fi

if grep -Fq "303" <<< "${OUTPUT}" && grep -Fq "FAIL wrong VMID" <<< "${OUTPUT}"; then
  test_pass "output ties failure to requested VMID"
else
  test_fail "output should tie failure to requested VMID"
  printf '    output:\n%s\n' "${OUTPUT}" >&2
fi

runner_summary
