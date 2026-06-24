#!/usr/bin/env bash
# Sprint 038 follow-up (dev pipeline 1079): SSH host-key warnings on stderr must
# NOT contaminate the per-VM PBS freshness JSON. The freshness query used
# `2>&1`, so SSH's "Warning: Permanently added <host> to the list of known
# hosts" (emitted on every connect because UserKnownHostsFile=/dev/null) was
# folded into the captured content and tripped the fail-closed invalid-JSON
# path — failing validate.sh against the live cluster even though every backup
# was fresh. The fix captures stdout separately from stderr (and adds
# LogLevel=ERROR). This test models the stderr warning and asserts the freshness
# check still parses clean JSON. It FAILS against the pre-fix `2>&1` capture.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d -t validate-pbs-stderr.XXXXXX)"
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

# ssh stub: emit the SSH host-key warning to STDERR (a stub cannot honor
# LogLevel=ERROR, so this directly exercises the stdout/stderr separation), and
# clean JSON to STDOUT. All three VMIDs are fresh — the ONLY way this run can
# fail is if the stderr warning contaminates the parsed JSON.
cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
now="$(date +%s)"
fresh=$((now - 3600))
case "${cmd}" in
  *'pvesm status'*)
    printf '%s\n' 'pbs-nas active'
    ;;
  *'--vmid 150'*|*'--vmid 303'*|*'--vmid 403'*)
    vmid="$(printf '%s\n' "${cmd}" | sed -n 's/.*--vmid \([0-9]*\).*/\1/p')"
    echo "Warning: Permanently added '10.0.0.11' (ED25519) to the list of known hosts." >&2
    printf '[{"vmid":%s,"ctime":%s,"volid":"pbs-nas:backup/vm/%s/fresh"}]\n' "${vmid}" "${fresh}" "${vmid}"
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

test_start "ssh-stderr-noise" "host-key warning on stderr must not break JSON parse"
run_validate_freshness

if [[ "${STATUS}" -eq 0 ]] && ! printf '%s\n' "${OUTPUT}" | grep -q "invalid JSON"; then
  test_pass "per-VM freshness parses clean JSON despite SSH stderr warning"
else
  test_fail "stderr warning contaminated the freshness JSON (regression)"
  printf '    status=%s\n    output:\n%s\n' "${STATUS}" "${OUTPUT}" >&2
fi

runner_summary
