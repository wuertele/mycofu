#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

make_delegate_stub() {
  local path="$1"

  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s %s\n' "$(basename "$0")" "${1:-}" >> "${STUB_LOG_FILE}"
EOF
  chmod +x "${path}"
}

setup_fixture_repo() {
  local repo_dir="$1"
  local workstation_enabled="$2"

  mkdir -p "${repo_dir}/framework/scripts" "${repo_dir}/site"
  cp "${REPO_ROOT}/framework/scripts/converge-lib.sh" "${repo_dir}/framework/scripts/converge-lib.sh"
  chmod +x "${repo_dir}/framework/scripts/converge-lib.sh"

  cat > "${repo_dir}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
certbot_cluster_staging_override_targets() { return 0; }
EOF
  chmod +x "${repo_dir}/framework/scripts/certbot-cluster.sh"

  make_delegate_stub "${repo_dir}/framework/scripts/cert-storage-backfill.sh"
  make_delegate_stub "${repo_dir}/framework/scripts/configure-dashboard-tokens.sh"
  make_delegate_stub "${repo_dir}/framework/scripts/deploy-workstation-closure.sh"

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
domain: example.test
vms:
  gitlab:
    ip: 10.0.0.31
  gatus:
    ip: 10.0.0.32
  cicd:
    ip: 10.0.0.33
  pbs:
    ip: 10.0.0.60
  vault_prod:
    ip: 10.0.0.21
  vault_dev:
    ip: 10.0.0.22
EOF

  cat > "${repo_dir}/site/applications.yaml" <<EOF
applications:
  influxdb:
    enabled: true
  workstation:
    enabled: ${workstation_enabled}
EOF
}

run_steps() {
  local scenario="$1"
  local targets="$2"
  local workstation_enabled="${3:-true}"
  local steps="${4:-cert dashboard workstation}"
  local repo_dir="${TMP_DIR}/${scenario}-repo"
  local log_file="${TMP_DIR}/${scenario}.log"
  local output_file="${TMP_DIR}/${scenario}.out"

  setup_fixture_repo "${repo_dir}" "${workstation_enabled}"
  : > "${log_file}"

  set +e
  (
    export STUB_LOG_FILE="${log_file}"
    export SCRIPT_DIR="${repo_dir}/framework/scripts"
    export REPO_DIR="${repo_dir}"
    export CONFIG="${repo_dir}/site/config.yaml"
    export APPS_CONFIG="${repo_dir}/site/applications.yaml"
    export TOFU_TARGETS="${targets}"
    cd "${repo_dir}"
    source framework/scripts/converge-lib.sh
    for step in ${steps}; do
      case "${step}" in
        cert) converge_step_cert_backfill ;;
        dashboard) converge_step_dashboard_tokens ;;
        workstation) converge_step_workstation_closure ;;
        helper) converge_target_envs ;;
      esac
    done
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n%s\n' "${status}" "${output_file}" "${log_file}"
}

artifact_status() {
  printf '%s\n' "$1" | sed -n '1p'
}

artifact_output_file() {
  printf '%s\n' "$1" | sed -n '2p'
}

artifact_log_file() {
  printf '%s\n' "$1" | sed -n '3p'
}

assert_log_equals() {
  local log_file="$1"
  local expected="$2"
  local label="$3"
  local actual=""

  actual="$(cat "${log_file}")"
  if [[ "${actual}" == "${expected}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected:\n%s\n' "${expected}" >&2
    printf '    actual:\n%s\n' "${actual}" >&2
  fi
}

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -qF "${needle}" "${file}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    sed 's/^/    /' "${file}" >&2
  fi
}

S1="$(run_steps s1 '' true)"
S1_STATUS="$(artifact_status "${S1}")"
S1_LOG="$(artifact_log_file "${S1}")"
test_start "S1" "full target runs dev and prod for each new step"
[[ "${S1_STATUS}" == "0" ]] && test_pass "full target exits 0" || test_fail "full target exits 0"
assert_log_equals "${S1_LOG}" $'cert-storage-backfill.sh dev\ncert-storage-backfill.sh prod\nconfigure-dashboard-tokens.sh dev\nconfigure-dashboard-tokens.sh prod\ndeploy-workstation-closure.sh dev\ndeploy-workstation-closure.sh prod' "full target delegates dev then prod"

S2="$(run_steps s2 '-target=module.influxdb_prod' false)"
S2_STATUS="$(artifact_status "${S2}")"
S2_LOG="$(artifact_log_file "${S2}")"
test_start "S2" "module.influxdb_prod targets prod and skips disabled workstation"
[[ "${S2_STATUS}" == "0" ]] && test_pass "prod app target exits 0" || test_fail "prod app target exits 0"
assert_log_equals "${S2_LOG}" $'cert-storage-backfill.sh prod\nconfigure-dashboard-tokens.sh prod' "prod app target delegates prod only"

S3="$(run_steps s3 '-target=module.influxdb_dev' true)"
S3_STATUS="$(artifact_status "${S3}")"
S3_LOG="$(artifact_log_file "${S3}")"
test_start "S3" "module.influxdb_dev targets dev only"
[[ "${S3_STATUS}" == "0" ]] && test_pass "dev app target exits 0" || test_fail "dev app target exits 0"
assert_log_equals "${S3_LOG}" $'cert-storage-backfill.sh dev\nconfigure-dashboard-tokens.sh dev\ndeploy-workstation-closure.sh dev' "dev app target delegates dev only"

S4="$(run_steps s4 '-target=module.workstation_prod' false workstation)"
S4_STATUS="$(artifact_status "${S4}")"
S4_LOG="$(artifact_log_file "${S4}")"
S4_OUTPUT="$(artifact_output_file "${S4}")"
test_start "S4" "workstation target skips cleanly when disabled"
[[ "${S4_STATUS}" == "0" ]] && test_pass "disabled workstation target exits 0" || test_fail "disabled workstation target exits 0"
assert_log_equals "${S4_LOG}" "" "disabled workstation delegates nothing"
assert_contains "${S4_OUTPUT}" "workstation disabled" "disabled workstation logs skip"

S5="$(run_steps s5 '-target=module.workstation_prod' true workstation)"
S5_STATUS="$(artifact_status "${S5}")"
S5_LOG="$(artifact_log_file "${S5}")"
test_start "S5" "enabled workstation target runs prod closure"
[[ "${S5_STATUS}" == "0" ]] && test_pass "enabled workstation target exits 0" || test_fail "enabled workstation target exits 0"
assert_log_equals "${S5_LOG}" "deploy-workstation-closure.sh prod" "enabled workstation delegates prod closure"

S6="$(run_steps s6 '-target=module.gitlab' true)"
S6_STATUS="$(artifact_status "${S6}")"
S6_LOG="$(artifact_log_file "${S6}")"
test_start "S6" "module.gitlab is prod-only for new env-scoped steps"
[[ "${S6_STATUS}" == "0" ]] && test_pass "gitlab target exits 0" || test_fail "gitlab target exits 0"
assert_log_equals "${S6_LOG}" $'cert-storage-backfill.sh prod\nconfigure-dashboard-tokens.sh prod\ndeploy-workstation-closure.sh prod' "gitlab target delegates prod only"

test_start "S7" "converge_run_all ordering places workstation closure last"
run_all_steps="$(
  awk '
    /^converge_run_all\(\)/ { in_fn=1; next }
    in_fn && /^}/ { exit }
    in_fn && /^[[:space:]]*converge_step_/ {
      gsub(/^[[:space:]]+/, "", $0)
      print $1
    }
  ' "${REPO_ROOT}/framework/scripts/converge-lib.sh"
)"
cert_pos="$(printf '%s\n' "${run_all_steps}" | grep -n '^converge_step_cert_backfill$' | cut -d: -f1)"
dash_pos="$(printf '%s\n' "${run_all_steps}" | grep -n '^converge_step_dashboard_tokens$' | cut -d: -f1)"
work_pos="$(printf '%s\n' "${run_all_steps}" | grep -n '^converge_step_workstation_closure$' | cut -d: -f1)"
last_step="$(printf '%s\n' "${run_all_steps}" | tail -1)"
if [[ -n "${cert_pos}" && -n "${dash_pos}" && -n "${work_pos}" ]] &&
   (( cert_pos < dash_pos && dash_pos < work_pos )) &&
   [[ "${last_step}" == "converge_step_workstation_closure" ]]; then
  test_pass "new steps are ordered cert_backfill before dashboard_tokens before final workstation_closure"
else
  test_fail "new steps are ordered cert_backfill before dashboard_tokens before final workstation_closure"
  printf '    run_all steps:\n%s\n' "${run_all_steps}" >&2
fi

test_start "S8" "unrecognized scope fails loudly per Goal 10"
S8_HELPER="$(run_steps s8-helper '-target=module.foobarbaz' true helper)"
S8_HELPER_STATUS="$(artifact_status "${S8_HELPER}")"
S8_HELPER_OUTPUT="$(artifact_output_file "${S8_HELPER}")"
[[ "${S8_HELPER_STATUS}" != "0" ]] && test_pass "converge_target_envs exits non-zero for unknown module" || test_fail "converge_target_envs exits non-zero for unknown module"
assert_contains "${S8_HELPER_OUTPUT}" "foobarbaz" "helper error names unknown module"
for step_name in cert dashboard workstation; do
  artifact="$(run_steps "s8-${step_name}" '-target=module.foobarbaz' true "${step_name}")"
  status="$(artifact_status "${artifact}")"
  output_file="$(artifact_output_file "${artifact}")"
  [[ "${status}" != "0" ]] && test_pass "${step_name} step propagates unknown-scope failure" || test_fail "${step_name} step propagates unknown-scope failure"
  assert_contains "${output_file}" "foobarbaz" "${step_name} error names unknown module"
  if grep -Eq 'Goal 10|refusing to skip silently' "${output_file}"; then
    test_pass "${step_name} error names Goal 10 propagation pattern"
  else
    test_fail "${step_name} error names Goal 10 propagation pattern"
    sed 's/^/    /' "${output_file}" >&2
  fi
done

S9="$(run_steps s9 '-target=module.cicd -target=module.influxdb_prod' true)"
S9_STATUS="$(artifact_status "${S9}")"
S9_LOG="$(artifact_log_file "${S9}")"
test_start "S9" "mixed envless and prod target resolves to prod"
[[ "${S9_STATUS}" == "0" ]] && test_pass "mixed target exits 0" || test_fail "mixed target exits 0"
assert_log_equals "${S9_LOG}" $'cert-storage-backfill.sh prod\nconfigure-dashboard-tokens.sh prod\ndeploy-workstation-closure.sh prod' "mixed target delegates prod only"

S10="$(run_steps s10 '-target=module.cicd -target=module.pbs' true)"
S10_STATUS="$(artifact_status "${S10}")"
S10_LOG="$(artifact_log_file "${S10}")"
S10_OUTPUT="$(artifact_output_file "${S10}")"
test_start "S10" "all envless targets skip without failure"
[[ "${S10_STATUS}" == "0" ]] && test_pass "all envless target exits 0" || test_fail "all envless target exits 0"
assert_log_equals "${S10_LOG}" "" "all envless target delegates nothing"
assert_contains "${S10_OUTPUT}" "no env-specific work in scope" "all envless target logs legitimate skip"

runner_summary
