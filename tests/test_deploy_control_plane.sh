#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

setup_fixture_repo() {
  local repo_dir="$1"

  mkdir -p "${repo_dir}/framework/scripts" "${repo_dir}/site" "${repo_dir}/build"

  cp "${REPO_ROOT}/framework/scripts/deploy-control-plane.sh" \
    "${repo_dir}/framework/scripts/deploy-control-plane.sh"
  chmod +x "${repo_dir}/framework/scripts/deploy-control-plane.sh"

  cat > "${repo_dir}/framework/scripts/converge-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

closure=""
targets=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --closure)
      closure="$2"
      shift 2
      ;;
    --targets)
      targets="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'converge:%s:%s\n' "${targets}" "${closure}" >> "${STUB_LOG_FILE}"

target="${targets#-target=module.}"
if [[ "${STUB_FAIL_TARGET:-}" == "${target}" ]]; then
  exit "${STUB_FAIL_EXIT_CODE:-1}"
fi

if [[ "${STUB_SKIP_STATE_UPDATE:-0}" != "1" ]]; then
  printf '%s\n' "${closure}" > "${STUB_STATE_DIR}/live-${target}"
fi
EOF
  chmod +x "${repo_dir}/framework/scripts/converge-vm.sh"

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
vms:
  gitlab:
    ip: 10.0.0.10
  cicd:
    ip: 10.0.0.20
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications: {}
EOF
}

setup_shims() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=""
for arg in "$@"; do
  if [[ "${arg}" == root@* ]]; then
    target="${arg#root@}"
  fi
done

remote_cmd="${*: -1}"
printf 'ssh:%s:%s\n' "${target}" "${remote_cmd}" >> "${STUB_LOG_FILE}"

if [[ "${remote_cmd}" != "readlink -f /run/current-system" ]]; then
  exit 1
fi

case "${target}" in
  10.0.0.10)
    cat "${STUB_STATE_DIR}/live-gitlab"
    ;;
  10.0.0.20)
    cat "${STUB_STATE_DIR}/live-cicd"
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${shim_dir}/ssh"
}

run_fixture() {
  local scenario="$1"
  local env_name="$2"
  shift 2
  local repo_dir="${TMP_DIR}/${scenario}-repo"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local state_dir="${TMP_DIR}/${scenario}-state"
  local output_file="${TMP_DIR}/${scenario}.out"
  local log_file="${TMP_DIR}/${scenario}.log"
  local gitlab_built="${state_dir}/gitlab-built"
  local cicd_built="${state_dir}/cicd-built"
  local gitlab_old="${state_dir}/gitlab-live-old"
  local cicd_old="${state_dir}/cicd-live-old"
  local gitlab_live_mode="${STUB_GITLAB_MODE:-match}"
  local cicd_live_mode="${STUB_CICD_MODE:-match}"
  local closure_artifact_mode="${STUB_CLOSURE_ARTIFACT_MODE:-valid}"

  setup_fixture_repo "${repo_dir}"
  setup_shims "${shim_dir}"
  mkdir -p "${state_dir}"
  : > "${log_file}"
  : > "${gitlab_built}"
  : > "${cicd_built}"
  : > "${gitlab_old}"
  : > "${cicd_old}"

  case "${gitlab_live_mode}" in
    match) printf '%s\n' "${gitlab_built}" > "${state_dir}/live-gitlab" ;;
    old) printf '%s\n' "${gitlab_old}" > "${state_dir}/live-gitlab" ;;
    *) return 1 ;;
  esac

  case "${cicd_live_mode}" in
    match) printf '%s\n' "${cicd_built}" > "${state_dir}/live-cicd" ;;
    old) printf '%s\n' "${cicd_old}" > "${state_dir}/live-cicd" ;;
    *) return 1 ;;
  esac

  case "${closure_artifact_mode}" in
    valid)
      cat > "${repo_dir}/build/closure-paths.json" <<EOF
{
  "gitlab": "${gitlab_built}",
  "cicd": "${cicd_built}"
}
EOF
      ;;
    missing)
      rm -f "${repo_dir}/build/closure-paths.json"
      ;;
    malformed)
      printf '{\n  "gitlab":\n' > "${repo_dir}/build/closure-paths.json"
      ;;
    *)
      return 1
      ;;
  esac

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_LOG_FILE="${log_file}"
    export STUB_STATE_DIR="${state_dir}"
    export STUB_FAIL_TARGET="${STUB_FAIL_TARGET:-}"
    export STUB_FAIL_EXIT_CODE="${STUB_FAIL_EXIT_CODE:-1}"
    export STUB_SKIP_STATE_UPDATE="${STUB_SKIP_STATE_UPDATE:-0}"
    cd "${repo_dir}"
    framework/scripts/deploy-control-plane.sh "${env_name}" "$@"
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n%s\n%s\n%s\n' \
    "${status}" \
    "${output_file}" \
    "${log_file}" \
    "${gitlab_built}" \
    "${cicd_built}"
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

artifact_gitlab_built() {
  printf '%s\n' "$1" | sed -n '4p'
}

artifact_cicd_built() {
  printf '%s\n' "$1" | sed -n '5p'
}

test_start "2.3" "matching live closures skip converge-vm.sh and exit 0"
MATCH_ARTIFACTS="$(run_fixture match dev)"
MATCH_STATUS="$(artifact_status "${MATCH_ARTIFACTS}")"
MATCH_OUTPUT_FILE="$(artifact_output_file "${MATCH_ARTIFACTS}")"
MATCH_LOG_FILE="$(artifact_log_file "${MATCH_ARTIFACTS}")"
if [[ "${MATCH_STATUS}" == "0" ]]; then
  test_pass "matching closures exit 0"
else
  test_fail "matching closures exit 0"
  cat "${MATCH_OUTPUT_FILE}" >&2
fi
if grep -q 'gitlab: live closure matches built, skipping' "${MATCH_OUTPUT_FILE}" && \
   grep -q 'cicd: live closure matches built, skipping' "${MATCH_OUTPUT_FILE}" && \
   ! grep -q '^converge:' "${MATCH_LOG_FILE}"; then
  test_pass "matching closures do not invoke converge-vm.sh"
else
  test_fail "matching closures do not invoke converge-vm.sh"
  cat "${MATCH_OUTPUT_FILE}" >&2
  cat "${MATCH_LOG_FILE}" >&2
fi

test_start "2.3a" "dev mismatch invokes converge-vm.sh with the built closure and target"
DEV_MISMATCH_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  run_fixture dev-mismatch dev
)"
DEV_MISMATCH_STATUS="$(artifact_status "${DEV_MISMATCH_ARTIFACTS}")"
DEV_MISMATCH_OUTPUT_FILE="$(artifact_output_file "${DEV_MISMATCH_ARTIFACTS}")"
DEV_MISMATCH_LOG_FILE="$(artifact_log_file "${DEV_MISMATCH_ARTIFACTS}")"
DEV_MISMATCH_GITLAB_BUILT="$(artifact_gitlab_built "${DEV_MISMATCH_ARTIFACTS}")"
if [[ "${DEV_MISMATCH_STATUS}" == "0" ]]; then
  test_pass "dev mismatch exits 0 after converge succeeds"
else
  test_fail "dev mismatch exits 0 after converge succeeds"
  cat "${DEV_MISMATCH_OUTPUT_FILE}" >&2
fi
if grep -q "converge:-target=module.gitlab:${DEV_MISMATCH_GITLAB_BUILT}" "${DEV_MISMATCH_LOG_FILE}"; then
  test_pass "dev mismatch passes the expected --closure and --targets values"
else
  test_fail "dev mismatch passes the expected --closure and --targets values"
  cat "${DEV_MISMATCH_LOG_FILE}" >&2
fi

test_start "2.3b" "prod mismatch refuses without invoking converge-vm.sh"
PROD_MISMATCH_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  run_fixture prod-mismatch prod
)"
PROD_MISMATCH_STATUS="$(artifact_status "${PROD_MISMATCH_ARTIFACTS}")"
PROD_MISMATCH_OUTPUT_FILE="$(artifact_output_file "${PROD_MISMATCH_ARTIFACTS}")"
PROD_MISMATCH_LOG_FILE="$(artifact_log_file "${PROD_MISMATCH_ARTIFACTS}")"
if [[ "${PROD_MISMATCH_STATUS}" == "1" ]]; then
  test_pass "prod mismatch exits non-zero"
else
  test_fail "prod mismatch exits non-zero"
  cat "${PROD_MISMATCH_OUTPUT_FILE}" >&2
fi
if grep -q 'refusing: dev pipeline should have deployed first' "${PROD_MISMATCH_OUTPUT_FILE}" && \
   ! grep -q '^converge:' "${PROD_MISMATCH_LOG_FILE}"; then
  test_pass "prod mismatch refuses before converge-vm.sh runs"
else
  test_fail "prod mismatch refuses before converge-vm.sh runs"
  cat "${PROD_MISMATCH_OUTPUT_FILE}" >&2
  cat "${PROD_MISMATCH_LOG_FILE}" >&2
fi

test_start "2.3c" "gitlab converge failure stops before cicd is attempted"
GITLAB_FAIL_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  STUB_CICD_MODE=old \
  STUB_FAIL_TARGET=gitlab \
  run_fixture gitlab-fails dev
)"
GITLAB_FAIL_STATUS="$(artifact_status "${GITLAB_FAIL_ARTIFACTS}")"
GITLAB_FAIL_OUTPUT_FILE="$(artifact_output_file "${GITLAB_FAIL_ARTIFACTS}")"
GITLAB_FAIL_LOG_FILE="$(artifact_log_file "${GITLAB_FAIL_ARTIFACTS}")"
if [[ "${GITLAB_FAIL_STATUS}" == "1" ]]; then
  test_pass "gitlab converge failure exits non-zero"
else
  test_fail "gitlab converge failure exits non-zero"
  cat "${GITLAB_FAIL_OUTPUT_FILE}" >&2
fi
if grep -q '^converge:-target=module.gitlab:' "${GITLAB_FAIL_LOG_FILE}" && \
   ! grep -q '^converge:-target=module.cicd:' "${GITLAB_FAIL_LOG_FILE}"; then
  test_pass "cicd converge is not invoked after a gitlab failure"
else
  test_fail "cicd converge is not invoked after a gitlab failure"
  cat "${GITLAB_FAIL_LOG_FILE}" >&2
fi

test_start "2.3d" "final verification fails when live closure still mismatches after converge"
VERIFY_FAIL_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  STUB_SKIP_STATE_UPDATE=1 \
  run_fixture verify-fails dev
)"
VERIFY_FAIL_STATUS="$(artifact_status "${VERIFY_FAIL_ARTIFACTS}")"
VERIFY_FAIL_OUTPUT_FILE="$(artifact_output_file "${VERIFY_FAIL_ARTIFACTS}")"
if [[ "${VERIFY_FAIL_STATUS}" == "1" ]]; then
  test_pass "post-converge verification mismatch exits non-zero"
else
  test_fail "post-converge verification mismatch exits non-zero"
  cat "${VERIFY_FAIL_OUTPUT_FILE}" >&2
fi
if grep -q 'final verification mismatch' "${VERIFY_FAIL_OUTPUT_FILE}"; then
  test_pass "post-converge verification mismatch is reported clearly"
else
  test_fail "post-converge verification mismatch is reported clearly"
  cat "${VERIFY_FAIL_OUTPUT_FILE}" >&2
fi

test_start "2.3e" "host filtering deploys and verifies only the requested control-plane host"
FILTERED_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  STUB_CICD_MODE=old \
  run_fixture filtered dev gitlab
)"
FILTERED_STATUS="$(artifact_status "${FILTERED_ARTIFACTS}")"
FILTERED_LOG_FILE="$(artifact_log_file "${FILTERED_ARTIFACTS}")"
FILTERED_OUTPUT_FILE="$(artifact_output_file "${FILTERED_ARTIFACTS}")"
if [[ "${FILTERED_STATUS}" == "0" ]]; then
  test_pass "single-host run exits 0 when the selected host converges"
else
  test_fail "single-host run exits 0 when the selected host converges"
  cat "${FILTERED_OUTPUT_FILE}" >&2
fi
if grep -q '^converge:-target=module.gitlab:' "${FILTERED_LOG_FILE}" && \
   ! grep -q '^converge:-target=module.cicd:' "${FILTERED_LOG_FILE}" && \
   ! grep -q 'ssh:10.0.0.20:readlink -f /run/current-system' "${FILTERED_LOG_FILE}"; then
  test_pass "single-host run does not touch cicd"
else
  test_fail "single-host run does not touch cicd"
  cat "${FILTERED_LOG_FILE}" >&2
fi

test_start "2.3f" "missing closure-paths.json fails closed before any deploy work"
MISSING_ARTIFACTS="$(
  STUB_CLOSURE_ARTIFACT_MODE=missing \
  run_fixture missing-artifact dev
)"
MISSING_STATUS="$(artifact_status "${MISSING_ARTIFACTS}")"
MISSING_OUTPUT_FILE="$(artifact_output_file "${MISSING_ARTIFACTS}")"
MISSING_LOG_FILE="$(artifact_log_file "${MISSING_ARTIFACTS}")"
if [[ "${MISSING_STATUS}" == "1" ]]; then
  test_pass "missing closure artifact exits non-zero"
else
  test_fail "missing closure artifact exits non-zero"
  cat "${MISSING_OUTPUT_FILE}" >&2
fi
if grep -q 'Closure artifact not found' "${MISSING_OUTPUT_FILE}" && \
   ! grep -q '^ssh:' "${MISSING_LOG_FILE}" && \
   ! grep -q '^converge:' "${MISSING_LOG_FILE}"; then
  test_pass "missing closure artifact aborts before ssh or converge-vm.sh"
else
  test_fail "missing closure artifact aborts before ssh or converge-vm.sh"
  cat "${MISSING_OUTPUT_FILE}" >&2
  cat "${MISSING_LOG_FILE}" >&2
fi

test_start "2.3g" "malformed closure-paths.json fails closed before any deploy work"
MALFORMED_ARTIFACTS="$(
  STUB_CLOSURE_ARTIFACT_MODE=malformed \
  run_fixture malformed-artifact dev
)"
MALFORMED_STATUS="$(artifact_status "${MALFORMED_ARTIFACTS}")"
MALFORMED_OUTPUT_FILE="$(artifact_output_file "${MALFORMED_ARTIFACTS}")"
MALFORMED_LOG_FILE="$(artifact_log_file "${MALFORMED_ARTIFACTS}")"
if [[ "${MALFORMED_STATUS}" == "1" ]]; then
  test_pass "malformed closure artifact exits non-zero"
else
  test_fail "malformed closure artifact exits non-zero"
  cat "${MALFORMED_OUTPUT_FILE}" >&2
fi
if grep -q 'Invalid closure artifact' "${MALFORMED_OUTPUT_FILE}" && \
   ! grep -q '^ssh:' "${MALFORMED_LOG_FILE}" && \
   ! grep -q '^converge:' "${MALFORMED_LOG_FILE}"; then
  test_pass "malformed closure artifact aborts before ssh or converge-vm.sh"
else
  test_fail "malformed closure artifact aborts before ssh or converge-vm.sh"
  cat "${MALFORMED_OUTPUT_FILE}" >&2
  cat "${MALFORMED_LOG_FILE}" >&2
fi

runner_summary
