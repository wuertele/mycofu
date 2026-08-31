#!/usr/bin/env bash
# test_github_remote_config.sh — Verify GitHub remote URL config validation.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REAL_YQ="$(command -v yq)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TEMP_PATHS=()

cleanup() {
  set +u
  local path=""
  for path in "${TEMP_PATHS[@]}"; do
    rm -rf "${path}"
  done
}
trap cleanup EXIT

make_temp_dir() {
  local target_var="$1"
  local path
  path="$(mktemp -d "${TMPDIR:-/tmp}/github-remote-config-test.XXXXXX")"
  TEMP_PATHS+=("${path}")
  printf -v "${target_var}" '%s' "${path}"
}

make_fixture() {
  local target_var="$1"
  local remote_url="$2"
  make_temp_dir fixture
  cp "${REPO_ROOT}/site/config.yaml" "${fixture}/config.yaml"
  cp "${REPO_ROOT}/site/applications.yaml" "${fixture}/applications.yaml"
  "${REAL_YQ}" -i ".github.remote_url = \"${remote_url}\"" "${fixture}/config.yaml"
  printf -v "${target_var}" '%s' "${fixture}"
}

run_validator() {
  local fixture="$1"
  set +e
  OUTPUT="$(
    VALIDATE_SITE_CONFIG_CONFIG="${fixture}/config.yaml" \
    VALIDATE_SITE_CONFIG_APPS_CONFIG="${fixture}/applications.yaml" \
    "${REPO_ROOT}/framework/scripts/validate-site-config.sh" 2>&1
  )"
  STATUS=$?
  set -e
  printf '%s' "${OUTPUT}" > "${fixture}/output.txt"
  printf '%s' "${STATUS}" > "${fixture}/exit.txt"
}

test_start "1" "current site/config.yaml has the corrected GitHub URL"
CURRENT_REMOTE="$("${REAL_YQ}" -r '.github.remote_url' "${REPO_ROOT}/site/config.yaml")"
if [[ "${CURRENT_REMOTE}" == "git@github.com:wuertele/mycofu.git" ]]; then
  test_pass "site/config.yaml points at wuertele/mycofu"
else
  test_fail "site/config.yaml has unexpected GitHub remote: ${CURRENT_REMOTE}"
fi

test_start "2" "empty github.remote_url fails validation"
make_fixture EMPTY_FIXTURE ""
run_validator "${EMPTY_FIXTURE}"
if [[ "$(cat "${EMPTY_FIXTURE}/exit.txt")" -ne 0 ]] && grep -q 'github.remote_url is required' "${EMPTY_FIXTURE}/output.txt"; then
  test_pass "empty remote URL is rejected"
else
  test_fail "empty remote URL was not rejected"
fi

test_start "3" "HTTPS github.remote_url fails validation"
make_fixture HTTPS_FIXTURE "https://github.com/wuertele/mycofu.git"
run_validator "${HTTPS_FIXTURE}"
if [[ "$(cat "${HTTPS_FIXTURE}/exit.txt")" -ne 0 ]] && grep -q 'must use SSH form' "${HTTPS_FIXTURE}/output.txt"; then
  test_pass "HTTPS remote URL is rejected"
else
  test_fail "HTTPS remote URL was not rejected"
fi

test_start "4" "arbitrary SSH owner/repo passes shape validation"
make_fixture WRONG_OWNER_FIXTURE "git@github.com:wrong-owner/wrong-repo.git"
run_validator "${WRONG_OWNER_FIXTURE}"
if [[ "$(cat "${WRONG_OWNER_FIXTURE}/exit.txt")" -eq 0 ]]; then
  test_pass "shape validation allows arbitrary owner/repo"
else
  test_fail "validator appears to blacklist a specific owner/repo"
  sed 's/^/    /' "${WRONG_OWNER_FIXTURE}/output.txt" >&2
fi

test_start "5" "validator has no known-bad blacklist"
if ! grep -Fq 'mycofu/mycofu' "${REPO_ROOT}/framework/scripts/validate-site-config.sh"; then
  test_pass "validator checks shape instead of a historical bad value"
else
  test_fail "validator contains a known-bad remote blacklist"
fi

runner_summary

