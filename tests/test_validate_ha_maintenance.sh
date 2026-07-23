#!/usr/bin/env bash
# Hermetic validate.sh fixture for HA node-maintenance visibility.
#
# Step z in rolling-reboot-node-inner.sh can deliberately leave a node in HA
# maintenance when the failback guard cannot prove the destination safe. This
# validates the WARN signal that makes that stuck state visible without running
# the full live-cluster validation suite.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

VALIDATE="${REPO_ROOT}/framework/scripts/validate.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_CONFIG="${TMP_DIR}/config.yaml"
SHIMS_DIR="${TMP_DIR}/shims"
mkdir -p "${SHIMS_DIR}"

cat > "${FIXTURE_CONFIG}" <<'EOF'
domain: example.test
acme: staging
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
  - name: pve02
    mgmt_ip: 10.0.0.12
  - name: pve03
    mgmt_ip: 10.0.0.13
nas:
  ip: 10.0.0.200
vms:
  gatus:
    ip: 10.0.0.20
  gitlab:
    ip: 10.0.0.30
  pbs:
    ip: 10.0.0.40
replication:
  health_port: 9100
proxmox:
  storage_pool: vmstore
EOF

cat > "${SHIMS_DIR}/ssh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

remote=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-q|-A) shift ;;
    -o) shift 2 ;;
    root@*) shift; remote="$*"; break ;;
    *) shift ;;
  esac
done

[[ -n "${remote}" ]] || { echo "ssh shim: missing remote command" >&2; exit 2; }

case "${remote}" in
  "ha-manager status")
    case "${HA_STATUS_MODE:-clean}" in
      clean)
        printf 'lrm pve01 (active, Tue Jan 01 00:00:00 2026)\n'
        printf 'lrm pve02 (active, Tue Jan 01 00:00:00 2026)\n'
        printf 'lrm pve03 (active, Tue Jan 01 00:00:00 2026)\n'
        printf 'service vm:510 (pve01, started)\n'
        ;;
      maintenance)
        printf 'lrm pve01 (active, Tue Jan 01 00:00:00 2026)\n'
        printf 'lrm pve02 (maintenance mode, Tue Jan 01 00:00:00 2026)\n'
        printf 'lrm pve03 (active, Tue Jan 01 00:00:00 2026)\n'
        printf 'service vm:510 (pve01, started)\n'
        ;;
      fail)
        exit 22
        ;;
      *)
        echo "unknown HA_STATUS_MODE=${HA_STATUS_MODE}" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    echo "ssh shim: unexpected remote command: ${remote}" >&2
    exit 98
    ;;
esac
SHIM
chmod +x "${SHIMS_DIR}/ssh"

run_validate() {
  local mode="$1"
  set +e
  OUTPUT="$(
    HA_STATUS_MODE="${mode}" \
    PATH="${SHIMS_DIR}:${PATH}" \
    MYCOFU_VALIDATE_CONFIG="${FIXTURE_CONFIG}" \
    MYCOFU_VALIDATE_ONLY_HA_MAINTENANCE=1 \
    bash "${VALIDATE}" dev 2>&1
  )"
  STATUS=$?
  set -e
}

test_start "ha-maintenance.1" "healthy active LRM status passes"
run_validate clean
if [[ "${STATUS}" -eq 0 ]] && grep -qF '[PASS] no nodes in HA maintenance' <<< "${OUTPUT}"; then
  test_pass "active LRM status produces PASS"
else
  test_fail "active LRM status did not pass"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "ha-maintenance.2" "maintenance node produces WARN and Step-z guidance"
run_validate maintenance
if [[ "${STATUS}" -eq 0 ]] \
   && grep -qF '[WARN] no nodes in HA maintenance' <<< "${OUTPUT}" \
   && grep -qF 'pve02: lrm pve02 (maintenance mode,' <<< "${OUTPUT}" \
   && grep -qF 'Step z refused failback' <<< "${OUTPUT}" \
   && grep -qF 'cleanup-orphan-cidata.sh --dry-run' <<< "${OUTPUT}"; then
  test_pass "maintenance status produces WARN with remediation"
else
  test_fail "maintenance status did not produce expected WARN"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "ha-maintenance.3" "unreadable HA status fails closed"
run_validate fail
if [[ "${STATUS}" -ne 0 ]] \
   && grep -qF '[FAIL] no nodes in HA maintenance' <<< "${OUTPUT}" \
   && grep -qF 'fail-closed' <<< "${OUTPUT}"; then
  test_pass "unreadable HA status fails closed"
else
  test_fail "unreadable HA status did not fail closed"
  printf '%s\n' "${OUTPUT}" >&2
fi

runner_summary
