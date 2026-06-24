#!/usr/bin/env bash
# Sprint 038: one fresh PBS backup must not mask stale backup-backed VM peers.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d -t validate-pbs-fresh.XXXXXX)"
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
  vault_prod:
    vmid: 403
    ip: 10.0.0.54
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
    printf '[{"vmid":150,"ctime":%s,"volid":"pbs-nas:backup/vm/150/fresh"}]\n' "${fresh}"
    ;;
  *'--vmid 303'*)
    printf '[{"vmid":303,"ctime":%s,"volid":"pbs-nas:backup/vm/303/stale"}]\n' "${stale}"
    ;;
  *'--vmid 403'*)
    printf '[{"vmid":403,"ctime":%s,"volid":"pbs-nas:backup/vm/403/stale"}]\n' "${stale}"
    ;;
  *)
    echo "unexpected ssh invocation: $*" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

run_validate_freshness() {
  set +e
  OUTPUT="$(
    cd "${FIXTURE_REPO}" &&
    PATH="${SHIM_DIR}:${PATH}" MYCOFU_VALIDATE_ONLY_PBS_FRESHNESS=1 \
      framework/scripts/validate.sh 2>&1
  )"
  STATUS=$?
  set -e
}

test_start "per-vm-stale" "fresh VMID 150 does not mask stale VMIDs 303 and 403"
run_validate_freshness

if [[ "${STATUS}" -eq 1 ]]; then
  test_pass "per-VM freshness exits non-zero when any expected VMID is stale"
else
  test_fail "per-VM freshness should fail"
  printf '    status=%s\n    output:\n%s\n' "${STATUS}" "${OUTPUT}" >&2
fi

for needle in "150" "OK" "303" "STALE" "403"; do
  if grep -Fq -- "${needle}" <<< "${OUTPUT}"; then
    test_pass "output contains ${needle}"
  else
    test_fail "output should contain ${needle}"
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
done

runner_summary
