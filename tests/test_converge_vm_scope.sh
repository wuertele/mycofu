#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

make_logging_stub() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$(basename "$0")" >> "${STUB_LOG_FILE}"
exit 0
EOF
  chmod +x "${path}"
}

setup_fixture_repo() {
  local repo_dir="$1"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/framework/step-ca" \
    "${repo_dir}/site"

  cp "${REPO_ROOT}/framework/scripts/converge-lib.sh" "${repo_dir}/framework/scripts/converge-lib.sh"
  cp "${REPO_ROOT}/framework/scripts/converge-vm.sh" "${repo_dir}/framework/scripts/converge-vm.sh"
  chmod +x "${repo_dir}/framework/scripts/converge-lib.sh" "${repo_dir}/framework/scripts/converge-vm.sh"

  cat > "${repo_dir}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

certbot_cluster_staging_override_targets() { return 0; }
EOF
  chmod +x "${repo_dir}/framework/scripts/certbot-cluster.sh"

  for script_name in \
    init-vault.sh \
    configure-vault.sh \
    cert-storage-backfill.sh \
    configure-replication.sh \
    configure-gitlab.sh \
    register-runner.sh \
    configure-sentinel-gatus.sh \
    configure-backups.sh \
    configure-metrics.sh \
    configure-dashboard-tokens.sh \
    deploy-workstation-closure.sh
  do
    make_logging_stub "${repo_dir}/framework/scripts/${script_name}"
  done

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
domain: example.test
nas:
  ip: 10.0.0.50
  ssh_user: admin
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
vms:
  gitlab:
    ip: 10.0.0.31
  cicd:
    ip: 10.0.0.33
  gatus:
    ip: 10.0.0.32
  pbs:
    ip: 10.0.0.60
  vault_prod:
    ip: 10.0.0.21
  vault_dev:
    ip: 10.0.0.22
  testapp_dev:
    ip: 10.0.0.41
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  printf 'dummy ca\n' > "${repo_dir}/framework/step-ca/root-ca.crt"
}

prepare_target_wrapper_marker() {
  local repo_dir="$1"

  mv "${repo_dir}/framework/scripts/converge-vm.sh" "${repo_dir}/framework/scripts/converge-vm-real.sh"
  cat > "${repo_dir}/framework/scripts/converge-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'TARGET_WRAPPER_MARKER\n'
exec "$(cd "$(dirname "$0")" && pwd)/converge-vm-real.sh" "$@"
EOF
  chmod +x \
    "${repo_dir}/framework/scripts/converge-vm.sh" \
    "${repo_dir}/framework/scripts/converge-vm-real.sh"
}

setup_shims() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"

if [[ "${remote_cmd}" == *"cat /root/.ssh/id_rsa.pub"* || "${remote_cmd}" == *"cat /root/.ssh/id_ed25519.pub"* ]]; then
  printf 'ssh-ed25519 AAAATESTKEY nas@test\n'
  exit 0
fi

if [[ "${remote_cmd}" == "true" ]]; then
  exit 0
fi

exit 0
EOF
  chmod +x "${shim_dir}/ssh"

  cat > "${shim_dir}/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  s_client)
    cat >/dev/null
    printf 'certificate\n'
    exit 0
    ;;
  x509)
    cat >/dev/null
    exit 0
    ;;
esac

exit 0
EOF
  chmod +x "${shim_dir}/openssl"

  for shim_name in curl sleep; do
    cat > "${shim_dir}/${shim_name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
    chmod +x "${shim_dir}/${shim_name}"
  done
}

run_converge_fixture() {
  local scenario="$1"
  local targets="$2"
  local repo_dir="${TMP_DIR}/${scenario}-repo"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local output_file="${TMP_DIR}/${scenario}.out"
  local log_file="${TMP_DIR}/${scenario}.log"

  setup_fixture_repo "${repo_dir}"
  setup_shims "${shim_dir}"
  : > "${log_file}"

  local args=(
    --config "${repo_dir}/site/config.yaml"
    --apps-config "${repo_dir}/site/applications.yaml"
    --repo-dir "${repo_dir}"
  )
  if [[ -n "${targets}" ]]; then
    args+=(--targets "${targets}")
  fi

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_LOG_FILE="${log_file}"
    cd "${repo_dir}"
    framework/scripts/converge-vm.sh "${args[@]}"
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n%s\n' "${status}" "${output_file}" "${log_file}"
}

run_cross_checkout_fixture() {
  local scenario="$1"
  local launcher_repo="${TMP_DIR}/${scenario}-launcher"
  local target_repo="${TMP_DIR}/${scenario}-target"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local output_file="${TMP_DIR}/${scenario}.out"
  local log_file="${TMP_DIR}/${scenario}.log"

  setup_fixture_repo "${launcher_repo}"
  setup_fixture_repo "${target_repo}"
  setup_shims "${shim_dir}"
  prepare_target_wrapper_marker "${target_repo}"
  rm -rf "${launcher_repo}/site"
  : > "${log_file}"

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_LOG_FILE="${log_file}"
    cd "${launcher_repo}"
    framework/scripts/converge-vm.sh \
      --config "site/config.yaml" \
      --apps-config "site/applications.yaml" \
      --repo-dir "${target_repo}"
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

assert_output_contains() {
  local output="$1"
  local needle="$2"
  local label="$3"

  if [[ "${output}" == *"${needle}"* ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${output}" >&2
  fi
}

normalize_step_lines() {
  local file="$1"
  sed -n -E 's/^\[[^]]+\] //p' "${file}" \
    | sed -E 's/ in [0-9]+s$//' \
    | grep -E '^(=== Step|    Step )'
}

FULL_ARTIFACTS="$(run_converge_fixture full '')"
FULL_STATUS="$(artifact_status "${FULL_ARTIFACTS}")"
FULL_OUTPUT_FILE="$(artifact_output_file "${FULL_ARTIFACTS}")"
FULL_OUTPUT="$(cat "${FULL_OUTPUT_FILE}")"

test_start "5.1" "full scope runs every convergence step"
if [[ "${FULL_STATUS}" == "0" ]]; then
  test_pass "full-scope converge-vm fixture exited 0"
else
  test_fail "full-scope converge-vm fixture exited 0"
  printf '    output:\n%s\n' "${FULL_OUTPUT}" >&2
fi
for expected in \
  "Step 8 completed" \
  "Step 9 completed" \
  "Step 10 completed" \
  "Step 11 completed" \
  "Step 11.5 completed" \
  "Step 12 completed" \
  "Step 13 completed" \
  "Step 14 completed" \
  "Step 15 completed" \
  "Step 15.5 completed" \
  "Step 15.7 completed" \
  "Step 15.8 skipped" \
  "Step 15.9 skipped"
do
  assert_output_contains "${FULL_OUTPUT}" "${expected}" "full scope includes ${expected}"
done

VAULT_ARTIFACTS="$(run_converge_fixture vault '-target=module.vault_dev')"
VAULT_STATUS="$(artifact_status "${VAULT_ARTIFACTS}")"
VAULT_OUTPUT_FILE="$(artifact_output_file "${VAULT_ARTIFACTS}")"
VAULT_OUTPUT="$(cat "${VAULT_OUTPUT_FILE}")"

test_start "5.2" "vault target runs cert, vault, replication, and backups only"
if [[ "${VAULT_STATUS}" == "0" ]]; then
  test_pass "vault-scoped converge-vm fixture exited 0"
else
  test_fail "vault-scoped converge-vm fixture exited 0"
  printf '    output:\n%s\n' "${VAULT_OUTPUT}" >&2
fi
for expected in \
  "Step 8 skipped" \
  "Step 9 completed" \
  "Step 10 completed" \
  "Step 11 completed" \
  "Step 11.5 completed" \
  "Step 12 completed" \
  "Step 13 skipped" \
  "Step 14 skipped" \
  "Step 15 skipped" \
  "Step 15.5 completed" \
  "Step 15.7 skipped" \
  "Step 15.8 skipped" \
  "Step 15.9 skipped"
do
  assert_output_contains "${VAULT_OUTPUT}" "${expected}" "vault scope includes ${expected}"
done

GITLAB_ARTIFACTS="$(run_converge_fixture gitlab-runner '-target=module.gitlab -target=module.cicd')"
GITLAB_STATUS="$(artifact_status "${GITLAB_ARTIFACTS}")"
GITLAB_OUTPUT_FILE="$(artifact_output_file "${GITLAB_ARTIFACTS}")"
GITLAB_OUTPUT="$(cat "${GITLAB_OUTPUT_FILE}")"

test_start "5.3" "gitlab and cicd targets run cert, gitlab, runner, replication, and backups"
if [[ "${GITLAB_STATUS}" == "0" ]]; then
  test_pass "gitlab/cicd converge-vm fixture exited 0"
else
  test_fail "gitlab/cicd converge-vm fixture exited 0"
  printf '    output:\n%s\n' "${GITLAB_OUTPUT}" >&2
fi
for expected in \
  "Step 8 skipped" \
  "Step 9 completed" \
  "Step 10 skipped" \
  "Step 11 skipped" \
  "Step 11.5 completed" \
  "Step 12 completed" \
  "Step 13 completed" \
  "Step 14 completed" \
  "Step 15 skipped" \
  "Step 15.5 completed" \
  "Step 15.7 skipped" \
  "Step 15.8 skipped" \
  "Step 15.9 skipped"
do
  assert_output_contains "${GITLAB_OUTPUT}" "${expected}" "gitlab/cicd scope includes ${expected}"
done

APP_ARTIFACTS="$(run_converge_fixture app '-target=module.testapp_dev')"
APP_STATUS="$(artifact_status "${APP_ARTIFACTS}")"
APP_OUTPUT_FILE="$(artifact_output_file "${APP_ARTIFACTS}")"
APP_OUTPUT="$(cat "${APP_OUTPUT_FILE}")"

test_start "5.4" "infrastructure-only steps skip whenever any targets are provided"
if [[ "${APP_STATUS}" == "0" ]]; then
  test_pass "single-target converge-vm fixture exited 0"
else
  test_fail "single-target converge-vm fixture exited 0"
  printf '    output:\n%s\n' "${APP_OUTPUT}" >&2
fi
for expected in \
  "Step 8 skipped" \
  "Step 11.5 completed" \
  "Step 15 skipped" \
  "Step 15.7 skipped" \
  "Step 15.8 skipped" \
  "Step 15.9 skipped"
do
  assert_output_contains "${APP_OUTPUT}" "${expected}" "targeted run includes ${expected}"
done

IDEMPOTENT_FIRST_ARTIFACTS="$(run_converge_fixture idempotent-first '-target=module.testapp_dev')"
IDEMPOTENT_SECOND_ARTIFACTS="$(run_converge_fixture idempotent-second '-target=module.testapp_dev')"
IDEMPOTENT_FIRST_STATUS="$(artifact_status "${IDEMPOTENT_FIRST_ARTIFACTS}")"
IDEMPOTENT_SECOND_STATUS="$(artifact_status "${IDEMPOTENT_SECOND_ARTIFACTS}")"
IDEMPOTENT_FIRST_OUTPUT_FILE="$(artifact_output_file "${IDEMPOTENT_FIRST_ARTIFACTS}")"
IDEMPOTENT_SECOND_OUTPUT_FILE="$(artifact_output_file "${IDEMPOTENT_SECOND_ARTIFACTS}")"
IDEMPOTENT_FIRST_LOG_FILE="$(artifact_log_file "${IDEMPOTENT_FIRST_ARTIFACTS}")"
IDEMPOTENT_SECOND_LOG_FILE="$(artifact_log_file "${IDEMPOTENT_SECOND_ARTIFACTS}")"

test_start "5.5" "stubbed convergence is idempotent across repeated runs"
if [[ "${IDEMPOTENT_FIRST_STATUS}" == "0" && "${IDEMPOTENT_SECOND_STATUS}" == "0" ]]; then
  test_pass "both idempotency runs exited 0"
else
  test_fail "both idempotency runs exited 0"
fi

FIRST_STEPS="$(normalize_step_lines "${IDEMPOTENT_FIRST_OUTPUT_FILE}")"
SECOND_STEPS="$(normalize_step_lines "${IDEMPOTENT_SECOND_OUTPUT_FILE}")"
if [[ "${FIRST_STEPS}" == "${SECOND_STEPS}" ]]; then
  test_pass "repeated targeted runs produce identical step transitions"
else
  test_fail "repeated targeted runs produce identical step transitions"
  printf '    first:\n%s\n' "${FIRST_STEPS}" >&2
  printf '    second:\n%s\n' "${SECOND_STEPS}" >&2
fi

FIRST_INVOCATIONS="$(cat "${IDEMPOTENT_FIRST_LOG_FILE}")"
SECOND_INVOCATIONS="$(cat "${IDEMPOTENT_SECOND_LOG_FILE}")"
if [[ "${FIRST_INVOCATIONS}" == "${SECOND_INVOCATIONS}" ]]; then
  test_pass "repeated targeted runs invoke the same helper scripts"
else
  test_fail "repeated targeted runs invoke the same helper scripts"
  printf '    first:\n%s\n' "${FIRST_INVOCATIONS}" >&2
  printf '    second:\n%s\n' "${SECOND_INVOCATIONS}" >&2
fi

CROSS_CHECKOUT_ARTIFACTS="$(run_cross_checkout_fixture cross-checkout)"
CROSS_CHECKOUT_STATUS="$(artifact_status "${CROSS_CHECKOUT_ARTIFACTS}")"
CROSS_CHECKOUT_OUTPUT_FILE="$(artifact_output_file "${CROSS_CHECKOUT_ARTIFACTS}")"
CROSS_CHECKOUT_OUTPUT="$(cat "${CROSS_CHECKOUT_OUTPUT_FILE}")"

test_start "5.6" "--repo-dir re-execs the target checkout and resolves repo-relative config paths"
if [[ "${CROSS_CHECKOUT_STATUS}" == "0" ]]; then
  test_pass "cross-checkout converge-vm fixture exited 0"
else
  test_fail "cross-checkout converge-vm fixture exited 0"
  printf '    output:\n%s\n' "${CROSS_CHECKOUT_OUTPUT}" >&2
fi
assert_output_contains "${CROSS_CHECKOUT_OUTPUT}" "TARGET_WRAPPER_MARKER" "cross-checkout run uses target checkout wrapper"
assert_output_contains "${CROSS_CHECKOUT_OUTPUT}" "Step 15.5 completed" "cross-checkout run converges using target checkout config"

runner_summary
