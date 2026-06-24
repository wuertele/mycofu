#!/usr/bin/env bash
# Sprint 038: configure-pbs.sh is not a backup-job writer and verify delegates.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d -t configure-pbs.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
HOME_DIR="${TMP_DIR}/home"
mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site/sops" "${SHIM_DIR}" "${HOME_DIR}/.ssh"

cp "${REPO_ROOT}/framework/scripts/configure-pbs.sh" "${FIXTURE_REPO}/framework/scripts/configure-pbs.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/configure-pbs.sh"

cat > "${FIXTURE_REPO}/flake.nix" <<'EOF'
{}
EOF

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
vms:
  pbs:
    ip: 10.0.0.60
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
nas:
  ip: 10.0.0.200
  nfs_export: /volume1/pbs
pbs:
  datastore_name: backups
  datastore_mount: /mnt/datastore/backups
  keep_daily: 7
  keep_weekly: 4
  keep_monthly: 6
  backup_schedule: "02:00"
EOF

cat > "${FIXTURE_REPO}/site/sops/secrets.yaml" <<'EOF'
{}
EOF

cat > "${HOME_DIR}/.ssh/id_ed25519.pub" <<'EOF'
ssh-ed25519 AAAATEST operator@test
EOF

cat > "${FIXTURE_REPO}/framework/scripts/configure-backups.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${STUB_DELEGATE_FILE}"
exit "${STUB_CONFIGURE_BACKUPS_RC:-1}"
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/configure-backups.sh"

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'pbs_root_password'* ]]; then
  printf '%s\n' 'password'
elif [[ "$*" == *'pbs_api_token'* ]]; then
  printf '%s\n' 'token'
else
  printf '%s\n' 'value'
fi
EOF
chmod +x "${SHIM_DIR}/sops"

cat > "${SHIM_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${SHIM_DIR}/curl"

cat > "${SHIM_DIR}/sshpass" <<'EOF'
#!/usr/bin/env bash
shift 2
exec ssh "$@"
EOF
chmod +x "${SHIM_DIR}/sshpass"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
case "${cmd}" in
  'echo ok')
    printf '%s\n' 'ok'
    ;;
  *'mount | grep -q'*)
    exit 0
    ;;
  *'proxmox-backup-manager datastore list --output-format json'*)
    printf '[{"name":"backups"}]\n'
    ;;
  *'proxmox-backup-manager user list-tokens root@pam --output-format json'*)
    printf '[{"token-name":"proxmox-backup"}]\n'
    ;;
  *'pvesh get /storage/pbs-nas --output-format json'*)
    printf '{"storage":"pbs-nas"}\n'
    ;;
  *'/cluster/backup'*)
    echo "configure-pbs.sh must not query or write /cluster/backup directly: ${cmd}" >&2
    exit 77
    ;;
  *)
    echo "unexpected ssh invocation: $*" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

test_start "static-no-writer" "configure-pbs.sh contains no direct /cluster/backup writer"
if ! grep -Eq 'pvesh (create|set) /cluster/backup' "${REPO_ROOT}/framework/scripts/configure-pbs.sh"; then
  test_pass "no pvesh create/set /cluster/backup calls remain"
else
  test_fail "configure-pbs.sh still writes backup jobs"
fi

test_start "verify-delegates" "configure-pbs.sh --verify delegates backup contract to configure-backups.sh --verify"
set +e
OUTPUT="$(
  cd "${FIXTURE_REPO}" &&
  PATH="${SHIM_DIR}:${PATH}" HOME="${HOME_DIR}" STUB_DELEGATE_FILE="${TMP_DIR}/delegate.args" \
    STUB_CONFIGURE_BACKUPS_RC=1 framework/scripts/configure-pbs.sh --verify 2>&1
)"
STATUS=$?
set -e

if [[ "${STATUS}" -eq 1 ]]; then
  test_pass "--verify exits non-zero when configure-backups.sh --verify fails"
else
  test_fail "--verify should fail through delegated backup check"
  printf '    status=%s\n    output:\n%s\n' "${STATUS}" "${OUTPUT}" >&2
fi

if [[ -f "${TMP_DIR}/delegate.args" ]] && grep -Fxq -- "--verify" "${TMP_DIR}/delegate.args"; then
  test_pass "delegation invoked configure-backups.sh --verify"
else
  test_fail "delegation did not invoke configure-backups.sh --verify"
  printf '    output:\n%s\n' "${OUTPUT}" >&2
fi

if grep -Fq "Backup job contract" <<< "${OUTPUT}"; then
  test_pass "verify output names delegated backup job contract"
else
  test_fail "verify output should name backup job contract"
  printf '    output:\n%s\n' "${OUTPUT}" >&2
fi

runner_summary
