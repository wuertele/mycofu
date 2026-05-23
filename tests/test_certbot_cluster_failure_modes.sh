#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_DIR="${TMP_DIR}/fixture"
SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "${FIXTURE_DIR}/site" "${SHIM_DIR}"

REAL_YQ="$(command -v yq)"

cat > "${FIXTURE_DIR}/site/config.yaml" <<'EOF'
domain: example.test
acme: production
vms:
  gitlab:
    ip: 10.0.0.31
    vmid: 150
    backup: true
  gatus:
    ip: 10.0.0.34
    vmid: 650
EOF

cat > "${FIXTURE_DIR}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

host=""
has_stdin=1
remote_helper=0
args=("$@")

for ((i=0; i<${#args[@]}; i++)); do
  arg="${args[i]}"
  if [[ "${arg}" == "root@"* ]]; then
    host="${arg#root@}"
  fi
  if [[ "${arg}" == "-n" ]]; then
    has_stdin=0
  fi
  if [[ "${arg}" == "bash" ]] && [[ $((i + 1)) -lt ${#args[@]} ]] && [[ "${args[i + 1]}" == "-s" ]]; then
    remote_helper=1
  fi
done

if [[ "${remote_helper}" -eq 1 ]]; then
  payload=""
  if [[ "${has_stdin}" -eq 1 ]]; then
    payload="$(cat)"
  fi

  if [[ -z "${payload}" ]]; then
    printf 'missing helper payload for %s\n' "${host}" >&2
    exit 97
  fi

  if [[ -n "${STUB_REMOTE_HELPER_EXIT:-}" ]]; then
    printf 'remote helper failed on %s\n' "${host}" >&2
    exit "${STUB_REMOTE_HELPER_EXIT}"
  fi
  exit 0
fi

remote_cmd="${*: -1}"
if [[ "${remote_cmd}" == *'find /etc/letsencrypt/renewal'* ]]; then
  case " ${STUB_UNINSPECTABLE_IPS:-} " in
    *" ${host} "*)
      printf 'ssh probe failed for %s\n' "${host}" >&2
      exit 255
      ;;
  esac

  case " ${STUB_CERTBOT_IPS:-} " in
    *" ${host} "*) exit 0 ;;
    *) exit 1 ;;
  esac
fi

printf 'unexpected ssh invocation: %s\n' "$*" >&2
exit 98
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"
export CERTBOT_CLUSTER_YQ_BIN="${REAL_YQ}"
export CERTBOT_CLUSTER_SSH_BIN="ssh"
export CERTBOT_CLUSTER_CONFIG="${FIXTURE_DIR}/site/config.yaml"
export CERTBOT_CLUSTER_APPS_CONFIG="${FIXTURE_DIR}/site/applications.yaml"

source "${REPO_ROOT}/framework/scripts/certbot-cluster.sh"

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

reset_stub_state() {
  export STUB_CERTBOT_IPS="10.0.0.31"
  export STUB_UNINSPECTABLE_IPS=""
  export STUB_REMOTE_HELPER_EXIT=""
}

simulate_backup_now_lineage_gate() {
  local records=""
  local lineage_failures=0
  local vm_label vm_ip fqdn

  if ! records="$(certbot_cluster_prod_shared_backup_certbot_records "${CERTBOT_CLUSTER_CONFIG}" "${CERTBOT_CLUSTER_APPS_CONFIG}")"; then
    return 1
  fi

  while IFS=$'\t' read -r vm_label _ vm_ip _ fqdn _ _; do
    [[ -z "${vm_label}" ]] && continue
    if ! certbot_cluster_run_remote_helper \
      "${vm_ip}" \
      --mode check \
      --expected-acme-url "https://acme-v02.api.letsencrypt.org/directory" \
      --expected-mode production \
      --fqdn "${fqdn}" \
      --label "${vm_label}"; then
      lineage_failures=$((lineage_failures + 1))
    fi
  done <<< "${records}"

  [[ "${lineage_failures}" -eq 0 ]]
}

simulate_validate_lineage_gate() {
  local records=""
  local fail_count=0
  local vm_label vm_ip fqdn

  if ! records="$(certbot_cluster_prod_shared_backup_certbot_records "${CERTBOT_CLUSTER_CONFIG}" "${CERTBOT_CLUSTER_APPS_CONFIG}")"; then
    return 1
  fi

  while IFS=$'\t' read -r vm_label _ vm_ip _ fqdn _ _; do
    [[ -z "${vm_label}" ]] && continue
    if ! certbot_cluster_run_remote_helper \
      "${vm_ip}" \
      --mode check \
      --expected-acme-url "https://acme-v02.api.letsencrypt.org/directory" \
      --expected-mode production \
      --fqdn "${fqdn}" \
      --label "${vm_label}"; then
      fail_count=$((fail_count + 1))
    fi
  done <<< "${records}"

  [[ "${fail_count}" -eq 0 ]]
}

simulate_drt003_lineage_gate() {
  local records=""
  local fail_count=0
  local vm_label vm_ip fqdn

  if ! records="$(certbot_cluster_prod_shared_backup_certbot_records "${CERTBOT_CLUSTER_CONFIG}" "${CERTBOT_CLUSTER_APPS_CONFIG}")"; then
    return 1
  fi

  while IFS=$'\t' read -r vm_label _ vm_ip _ fqdn _ _; do
    [[ -z "${vm_label}" ]] && continue
    if ! certbot_cluster_run_remote_helper \
      "${vm_ip}" \
      --mode check \
      --expected-acme-url "https://acme-v02.api.letsencrypt.org/directory" \
      --expected-mode production \
      --fqdn "${fqdn}" \
      --label "${vm_label}" \
      --fail-on-fake-leaf; then
      fail_count=$((fail_count + 1))
    fi
  done <<< "${records}"

  [[ "${fail_count}" -eq 0 ]]
}

reset_stub_state

test_start "3.1" "remote helper streams the helper payload to the VM and preserves the remote exit code"
export STUB_REMOTE_HELPER_EXIT="42"
run_capture \
  certbot_cluster_run_remote_helper \
  "10.0.0.31" \
  --mode check \
  --expected-acme-url "https://acme-v02.api.letsencrypt.org/directory" \
  --expected-mode production \
  --fqdn "gitlab.prod.example.test" \
  --label "gitlab"
assert_exit 42 "remote helper returns the remote VM exit code"
assert_output_contains "remote helper failed on 10.0.0.31" "remote helper execution reached the VM shim"

test_start "3.2" "backup-backed certbot inventory fails closed when SSH inspection fails"
reset_stub_state
export STUB_UNINSPECTABLE_IPS="10.0.0.31"
run_capture \
  certbot_cluster_prod_shared_backup_certbot_records \
  "${CERTBOT_CLUSTER_CONFIG}" \
  "${CERTBOT_CLUSTER_APPS_CONFIG}"
assert_exit 1 "backup-backed inventory refuses to skip an uninspectable VM"
assert_output_contains "refusing to proceed unchecked" "inventory explains the fail-closed decision"

test_start "3.3" "backup-now lineage gate treats a remote helper failure as fatal"
reset_stub_state
export STUB_REMOTE_HELPER_EXIT="42"
run_capture simulate_backup_now_lineage_gate
assert_exit 1 "backup-now style lineage gate fails when the remote helper fails"

test_start "3.4" "validate lineage gate treats a remote helper failure as fatal"
reset_stub_state
export STUB_REMOTE_HELPER_EXIT="42"
run_capture simulate_validate_lineage_gate
assert_exit 1 "validate.sh style lineage gate fails when the remote helper fails"

test_start "3.5" "DRT-003 lineage gate treats a remote helper failure as fatal"
reset_stub_state
export STUB_REMOTE_HELPER_EXIT="42"
run_capture simulate_drt003_lineage_gate
assert_exit 1 "DRT-003 style lineage gate fails when the remote helper fails"

runner_summary
