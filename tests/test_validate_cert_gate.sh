#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

REAL_YQ="$(command -v yq)"
REAL_JQ="$(command -v jq)"

run_capture() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  STATUS=$?
  set -e
}

assert_exit() {
  local expected_status="$1"
  local label="$2"

  if [[ "${STATUS}" -eq "${expected_status}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected exit %s, got %s\n' "${expected_status}" "${STATUS}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_output_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq "${needle}" <<< "${OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing output: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_file_contains() {
  local file_path="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq "${needle}" "${file_path}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing in %s: %s\n' "${file_path}" "${needle}" >&2
    if [[ -f "${file_path}" ]]; then
      printf '    file contents:\n%s\n' "$(cat "${file_path}")" >&2
    fi
  fi
}

assert_file_not_contains() {
  local file_path="$1"
  local needle="$2"
  local label="$3"

  if [[ ! -f "${file_path}" ]] || ! grep -Fq "${needle}" "${file_path}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    unexpected match in %s: %s\n' "${file_path}" "${needle}" >&2
    printf '    file contents:\n%s\n' "$(cat "${file_path}")" >&2
  fi
}

make_fixture_repo() {
  local fixture_root="$1"
  local shim_dir="$2"

  mkdir -p \
    "${fixture_root}/framework/scripts" \
    "${fixture_root}/framework/catalog/widget" \
    "${fixture_root}/site" \
    "${shim_dir}"

  cp "${REPO_ROOT}/framework/scripts/validate.sh" "${fixture_root}/framework/scripts/validate.sh"
  cp "${REPO_ROOT}/framework/scripts/certbot-cluster.sh" "${fixture_root}/framework/scripts/certbot-cluster.sh"
  cp "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" "${fixture_root}/framework/scripts/generate-gatus-config.sh"
  chmod +x \
    "${fixture_root}/framework/scripts/validate.sh" \
    "${fixture_root}/framework/scripts/certbot-cluster.sh" \
    "${fixture_root}/framework/scripts/generate-gatus-config.sh"

  cat > "${fixture_root}/framework/scripts/configure-node-storage.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "${fixture_root}/framework/scripts/register-runner.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "${fixture_root}/framework/scripts/configure-backups.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x \
    "${fixture_root}/framework/scripts/configure-node-storage.sh" \
    "${fixture_root}/framework/scripts/register-runner.sh" \
    "${fixture_root}/framework/scripts/configure-backups.sh"

  cat > "${fixture_root}/framework/catalog/widget/health.yaml" <<'EOF'
port: 9443
path: /health
EOF

  cat > "${fixture_root}/site/config.yaml" <<'EOF'
domain: example.test
acme: production
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
environments:
  prod:
    gateway: 10.0.0.254
nas:
  ip: 10.0.0.18
replication:
  health_port: 9090
proxmox:
  storage_pool: tank
email:
  smtp_host: smtp.example.test
  smtp_port: 25
  to: ops@example.test
vms:
  dns1_prod:
    ip: 10.0.0.11
    backup: false
  dns2_prod:
    ip: 10.0.0.12
    backup: false
  vault_prod:
    ip: 10.0.0.13
    backup: false
  pbs:
    ip: 10.0.0.14
    backup: false
  gitlab:
    ip: 10.0.0.15
    backup: false
  gatus:
    ip: 10.0.0.16
    backup: false
  cicd:
    ip: 10.0.0.17
    backup: false
EOF

  cat > "${fixture_root}/site/applications.yaml" <<'EOF'
applications:
  widget:
    enabled: true
    monitor: true
    backup: false
    environments:
      prod:
        vmid: 601
        ip: 10.0.0.19
EOF

  cat > "${fixture_root}/flake.nix" <<'EOF'
{
  description = "validate cert gate fixture";
}
EOF

  cat > "${shim_dir}/ping" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "${shim_dir}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "${shim_dir}/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '10.0.0.13'
EOF

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"

case "${remote_cmd}" in
  true)
    exit 0
    ;;
  "systemctl is-active gitlab-runner.service")
    printf '%s\n' 'active'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  cat > "${shim_dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=""
want_code=0
for arg in "$@"; do
  case "${arg}" in
    http://*|https://*)
      url="${arg}"
      ;;
  esac
done

case " $* " in
  *" -w "*)
    want_code=1
    ;;
esac

if [[ "${want_code}" -eq 1 ]]; then
  printf '%s' '200'
  exit 0
fi

case "${url}" in
  http://10.0.0.1:9090/)
    printf '%s\n' '{"replication_stale":false,"zfs_pools":{"tank":"healthy"}}'
    ;;
  https://10.0.0.13:8200/v1/sys/health)
    printf '%s\n' '{"initialized":true,"sealed":false}'
    ;;
  http://10.0.0.16:8080/api/v1/endpoints/statuses?page=1|http://10.0.0.18:8080/api/v1/endpoints/statuses)
    printf '%s\n' "${GATUS_STATUS_JSON}"
    ;;
  https://10.0.0.19:9443/health)
    printf '%s\n' '{"status":"ok"}'
    ;;
  *)
    printf '%s\n' "unexpected curl url: ${url}" >&2
    exit 98
    ;;
esac
EOF

  cat > "${shim_dir}/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

subcommand="${1:-}"
shift || true

endpoint_ready() {
  local endpoint="$1"
  local probe_count="$2"

  case "${OPENSSL_MODE:-success}" in
    success)
      case "${endpoint}" in
        10.0.0.13:8200|10.0.0.15:443|10.0.0.19:9443)
          return 0
          ;;
      esac
      ;;
    timeout)
      case "${endpoint}" in
        10.0.0.19:9443)
          return 0
          ;;
        10.0.0.13:8200)
          [[ "${probe_count}" -ge 2 ]]
          return
          ;;
        10.0.0.15:443)
          return 1
          ;;
      esac
      ;;
  esac

  return 1
}

case "${subcommand}" in
  s_client)
    endpoint=""
    servername=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -connect)
          endpoint="$2"
          shift 2
          ;;
        -servername)
          servername="$2"
          shift 2
          ;;
        -*)
          printf 'unexpected s_client flag: %s\n' "$1" >&2
          exit 97
          ;;
        *)
          shift
          ;;
      esac
    done
    printf '%s\t%s\n' "${endpoint}" "${servername}" >> "${OPENSSL_LOG}"
    printf 'endpoint=%s servername=%s\n' "${endpoint}" "${servername}"
    ;;
  x509)
    payload="$(cat)"
    endpoint="$(printf '%s' "${payload}" | sed -n 's/.*endpoint=\([^ ]*\).*/\1/p')"
    key="$(printf '%s' "${endpoint}" | tr ':/' '__')"
    count_file="${OPENSSL_STATE_DIR}/${key}.count"
    probe_count=1
    if [[ -f "${count_file}" ]]; then
      probe_count=$(( $(cat "${count_file}") + 1 ))
    fi
    printf '%s\n' "${probe_count}" > "${count_file}"

    if ! endpoint_ready "${endpoint}" "${probe_count}"; then
      exit 1
    fi

    case " $* " in
      *" -issuer "*)
        printf '%s\n' 'issuer=CN = Let'\''s Encrypt'
        ;;
    esac
    ;;
  *)
    printf 'unexpected openssl subcommand: %s\n' "${subcommand}" >&2
    exit 99
    ;;
esac
EOF

  chmod +x \
    "${shim_dir}/ping" \
    "${shim_dir}/sleep" \
    "${shim_dir}/dig" \
    "${shim_dir}/ssh" \
    "${shim_dir}/curl" \
    "${shim_dir}/openssl"
}

test_start "21.1" "generate-gatus-config and validate.sh share the cert-monitor inventory"
FIXTURE_ONE="${TMP_DIR}/fixture-success"
SHIMS_ONE="${TMP_DIR}/shims-success"
STATE_ONE="${TMP_DIR}/state-success"
mkdir -p "${STATE_ONE}"
make_fixture_repo "${FIXTURE_ONE}" "${SHIMS_ONE}"
GATUS_CONFIG_OUTPUT="$(PATH="${SHIMS_ONE}:${PATH}" "${FIXTURE_ONE}/framework/scripts/generate-gatus-config.sh" "${FIXTURE_ONE}/site/config.yaml")"
if grep -Fq 'url: "https://10.0.0.19:9443"' <<< "${GATUS_CONFIG_OUTPUT}"; then
  test_pass "generate-gatus-config emits the widget cert monitor port from shared metadata"
else
  test_fail "generate-gatus-config emits the widget cert monitor port from shared metadata"
  printf '    output:\n%s\n' "${GATUS_CONFIG_OUTPUT}" >&2
fi

export GATUS_STATUS_JSON='[{"group":"services","results":[{"success":true}]},{"group":"certificates","results":[{"success":false}]}]'
export OPENSSL_MODE="success"
export OPENSSL_STATE_DIR="${STATE_ONE}"
export OPENSSL_LOG="${STATE_ONE}/openssl.log"
run_capture bash -lc "cd '${FIXTURE_ONE}' && export PATH='${SHIMS_ONE}:${REAL_YQ%/*}:${REAL_JQ%/*}':\"\$PATH\" && framework/scripts/validate.sh --quick prod"
assert_exit 0 "validate.sh succeeds when only the Gatus certificate group is unhealthy"
assert_file_contains "${OPENSSL_LOG}" $'10.0.0.13:8200\tvault.prod.example.test' "cert gate probes vault on the shared metadata port"
assert_file_contains "${OPENSSL_LOG}" $'10.0.0.15:443\tgitlab.prod.example.test' "cert gate probes gitlab on the shared metadata port"
assert_file_contains "${OPENSSL_LOG}" $'10.0.0.19:9443\twidget.prod.example.test' "cert gate probes monitored app ports from catalog metadata"
assert_file_not_contains "${OPENSSL_LOG}" '10.0.0.14:8007' "cert gate excludes non-certificate endpoints such as PBS"
assert_file_not_contains "${OPENSSL_LOG}" '10.0.0.11' "cert gate excludes VMs without Gatus cert monitors"

test_start "21.2" "validate.sh timeout distinguishes late certs from certs that never appeared"
FIXTURE_TWO="${TMP_DIR}/fixture-timeout"
SHIMS_TWO="${TMP_DIR}/shims-timeout"
STATE_TWO="${TMP_DIR}/state-timeout"
mkdir -p "${STATE_TWO}"
make_fixture_repo "${FIXTURE_TWO}" "${SHIMS_TWO}"
export GATUS_STATUS_JSON='[{"group":"services","results":[{"success":true}]},{"group":"certificates","results":[{"success":false}]}]'
export OPENSSL_MODE="timeout"
export OPENSSL_STATE_DIR="${STATE_TWO}"
export OPENSSL_LOG="${STATE_TWO}/openssl.log"
run_capture bash -lc "cd '${FIXTURE_TWO}' && export PATH='${SHIMS_TWO}:${REAL_YQ%/*}:${REAL_JQ%/*}':\"\$PATH\" && CERT_WAIT_TIMEOUT=0 framework/scripts/validate.sh --quick prod"
assert_exit 1 "validate.sh fails closed when the cert gate times out"
assert_output_contains "cert appeared on vault_prod (10.0.0.13:8200, vault.prod.example.test) but took" "timeout path identifies certs that appeared after the deadline"
assert_output_contains "raise CERT_WAIT_TIMEOUT" "late-cert diagnostic explains the remediation"
assert_output_contains "cert never appeared on gitlab (10.0.0.15:443, gitlab.prod.example.test)" "timeout path identifies certs that never appeared"

runner_summary
