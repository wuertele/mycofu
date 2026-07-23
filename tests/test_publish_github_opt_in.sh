#!/usr/bin/env bash
# test_publish_github_opt_in.sh — Verify publish:github opt-in gating.
#
# Sprint 033 made publish:github load-bearing for prod pipelines. Issue #294
# scopes that requirement to publish.github.enabled = true so downstream
# adopters who clone Mycofu without a public mirror can run prod pipelines.
#
# This test covers three classes:
#   1. Disabled (or absent enabled flag): validate-site-config passes with
#      empty/absent github.remote_url, and publish:github script self-skips.
#   2. Enabled with valid config: Sprint 033 behavior preserved.
#   3. Enabled with invalid config: Sprint 033 failure modes preserved.
#
# It also asserts the scaffolded default in framework/templates/config.yaml.example
# is false (downstream-adopter ergonomics).

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
  path="$(mktemp -d "${TMPDIR:-/tmp}/publish-github-opt-in-test.XXXXXX")"
  TEMP_PATHS+=("${path}")
  printf -v "${target_var}" '%s' "${path}"
}

make_fixture() {
  local target_var="$1"
  make_temp_dir fixture
  cp "${REPO_ROOT}/site/config.yaml" "${fixture}/config.yaml"
  cp "${REPO_ROOT}/site/applications.yaml" "${fixture}/applications.yaml"
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

# --- Case A: this site's config has publish.github.enabled = true ---

test_start "1" "this site's config.yaml opts in (publish.github.enabled = true)"
SITE_ENABLED="$("${REAL_YQ}" -r '.publish.github.enabled // false' "${REPO_ROOT}/site/config.yaml")"
if [[ "${SITE_ENABLED}" == "true" ]]; then
  test_pass "site/config.yaml has publish.github.enabled: true"
else
  test_fail "site/config.yaml does not opt in (got '${SITE_ENABLED}')"
fi

# --- Case B: scaffold default is false (downstream-adopter ergonomics) ---

test_start "2" "scaffold default is publish.github.enabled = false"
# Note: yq's // operator treats `false` as null-ish and returns the alternative,
# so we cannot use `// null` here to distinguish "absent" from "false". Read the
# raw value (which is "false" when set, "null" when absent) and check explicitly.
SCAFFOLD_ENABLED="$("${REAL_YQ}" -r '.publish.github.enabled' \
  "${REPO_ROOT}/framework/templates/config.yaml.example")"
if [[ "${SCAFFOLD_ENABLED}" == "false" ]]; then
  test_pass "config.yaml.example scaffolds publish.github.enabled: false"
else
  test_fail "scaffold has unexpected value: '${SCAFFOLD_ENABLED}'"
fi

# --- Case C: disabled + empty URL → validation passes ---

test_start "3" "disabled + empty github.remote_url passes validation"
make_fixture DISABLED_EMPTY_FIXTURE
"${REAL_YQ}" -i '.publish.github.enabled = false' "${DISABLED_EMPTY_FIXTURE}/config.yaml"
"${REAL_YQ}" -i '.github.remote_url = ""' "${DISABLED_EMPTY_FIXTURE}/config.yaml"
run_validator "${DISABLED_EMPTY_FIXTURE}"
if [[ "$(cat "${DISABLED_EMPTY_FIXTURE}/exit.txt")" -eq 0 ]]; then
  test_pass "empty github.remote_url is accepted when publish is disabled"
else
  test_fail "validator rejected empty URL with publish disabled"
  sed 's/^/    /' "${DISABLED_EMPTY_FIXTURE}/output.txt" >&2
fi

# --- Case D: disabled + entire github key absent → validation passes ---

test_start "4" "disabled + absent github key passes validation"
make_fixture DISABLED_ABSENT_FIXTURE
"${REAL_YQ}" -i '.publish.github.enabled = false' "${DISABLED_ABSENT_FIXTURE}/config.yaml"
"${REAL_YQ}" -i 'del(.github)' "${DISABLED_ABSENT_FIXTURE}/config.yaml"
run_validator "${DISABLED_ABSENT_FIXTURE}"
if [[ "$(cat "${DISABLED_ABSENT_FIXTURE}/exit.txt")" -eq 0 ]]; then
  test_pass "absent github key is accepted when publish is disabled"
else
  test_fail "validator rejected absent github key with publish disabled"
  sed 's/^/    /' "${DISABLED_ABSENT_FIXTURE}/output.txt" >&2
fi

# --- Case E: disabled + malformed URL → validation passes (URL unchecked) ---

test_start "5" "disabled + malformed github.remote_url passes validation"
make_fixture DISABLED_MALFORMED_FIXTURE
"${REAL_YQ}" -i '.publish.github.enabled = false' "${DISABLED_MALFORMED_FIXTURE}/config.yaml"
"${REAL_YQ}" -i '.github.remote_url = "https://github.com/wuertele/mycofu.git"' \
  "${DISABLED_MALFORMED_FIXTURE}/config.yaml"
run_validator "${DISABLED_MALFORMED_FIXTURE}"
if [[ "$(cat "${DISABLED_MALFORMED_FIXTURE}/exit.txt")" -eq 0 ]]; then
  test_pass "malformed URL is accepted when publish is disabled"
else
  test_fail "validator rejected malformed URL with publish disabled"
  sed 's/^/    /' "${DISABLED_MALFORMED_FIXTURE}/output.txt" >&2
fi

# --- Case F: absent enabled flag → defaults to false, validation passes ---

test_start "6" "absent publish.github.enabled defaults to disabled"
make_fixture ABSENT_FLAG_FIXTURE
"${REAL_YQ}" -i 'del(.publish)' "${ABSENT_FLAG_FIXTURE}/config.yaml"
"${REAL_YQ}" -i '.github.remote_url = ""' "${ABSENT_FLAG_FIXTURE}/config.yaml"
run_validator "${ABSENT_FLAG_FIXTURE}"
if [[ "$(cat "${ABSENT_FLAG_FIXTURE}/exit.txt")" -eq 0 ]]; then
  test_pass "absent flag defaults to disabled and accepts empty URL"
else
  test_fail "absent flag did not default to disabled"
  sed 's/^/    /' "${ABSENT_FLAG_FIXTURE}/output.txt" >&2
fi

# --- Case G: enabled + empty URL → validation fails (Sprint 033 behavior) ---

test_start "7" "enabled + empty github.remote_url fails validation"
make_fixture ENABLED_EMPTY_FIXTURE
"${REAL_YQ}" -i '.publish.github.enabled = true' "${ENABLED_EMPTY_FIXTURE}/config.yaml"
"${REAL_YQ}" -i '.github.remote_url = ""' "${ENABLED_EMPTY_FIXTURE}/config.yaml"
run_validator "${ENABLED_EMPTY_FIXTURE}"
if [[ "$(cat "${ENABLED_EMPTY_FIXTURE}/exit.txt")" -ne 0 ]] && \
   grep -q 'github.remote_url is required' "${ENABLED_EMPTY_FIXTURE}/output.txt"; then
  test_pass "empty URL is rejected when publish is enabled"
else
  test_fail "empty URL was not rejected when publish is enabled"
  sed 's/^/    /' "${ENABLED_EMPTY_FIXTURE}/output.txt" >&2
fi

# --- Case H: enabled + malformed URL → validation fails (Sprint 033 behavior) ---

test_start "8" "enabled + malformed github.remote_url fails validation"
make_fixture ENABLED_MALFORMED_FIXTURE
"${REAL_YQ}" -i '.publish.github.enabled = true' "${ENABLED_MALFORMED_FIXTURE}/config.yaml"
"${REAL_YQ}" -i '.github.remote_url = "https://github.com/wuertele/mycofu.git"' \
  "${ENABLED_MALFORMED_FIXTURE}/config.yaml"
run_validator "${ENABLED_MALFORMED_FIXTURE}"
if [[ "$(cat "${ENABLED_MALFORMED_FIXTURE}/exit.txt")" -ne 0 ]] && \
   grep -q 'must use SSH form' "${ENABLED_MALFORMED_FIXTURE}/output.txt"; then
  test_pass "malformed URL is rejected when publish is enabled"
else
  test_fail "malformed URL was not rejected when publish is enabled"
  sed 's/^/    /' "${ENABLED_MALFORMED_FIXTURE}/output.txt" >&2
fi

# --- Case I: generate-gatus-config.sh handles disabled-publish ---
#
# Adversarial review (codex, gemini) found that build:merge in CI sets
# GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${CI_COMMIT_SHA:-}" unconditionally,
# and rebuild-cluster.sh does the same on the workstation. Without gating
# the github-mirror block on publish.github.enabled, downstream adopters
# with publish disabled would crash generate-gatus-config.sh under set -e
# (github_remote_to_raw_metadata_url fails on empty URL).

test_start "9" "generate-gatus-config.sh skips github-mirror block when disabled, even with GATUS env var set"
make_fixture GATUS_DISABLED_FIXTURE
"${REAL_YQ}" -i '.publish.github.enabled = false' "${GATUS_DISABLED_FIXTURE}/config.yaml"
"${REAL_YQ}" -i 'del(.github)' "${GATUS_DISABLED_FIXTURE}/config.yaml"
set +e
GATUS_OUTPUT="$(
  GATUS_GITHUB_EXPECTED_SOURCE_COMMIT=abcdef0123456789abcdef0123456789abcdef01 \
  "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" \
  "${GATUS_DISABLED_FIXTURE}/config.yaml" 2>&1
)"
GATUS_EXIT=$?
set -e
if [[ ${GATUS_EXIT} -eq 0 ]] && ! grep -q 'github-mirror-main' <<< "${GATUS_OUTPUT}"; then
  test_pass "generate-gatus-config exits 0 and omits github-mirror endpoint when disabled"
else
  test_fail "generate-gatus-config did not handle disabled-publish cleanly (exit=${GATUS_EXIT})"
  sed 's/^/    /' <<< "${GATUS_OUTPUT}" >&2
fi

# --- Case J: validate-github-mirror.sh handles disabled-publish ---

test_start "10" "validate-github-mirror.sh exits 0 with skip message when disabled"
make_fixture VALIDATE_MIRROR_DISABLED_FIXTURE
"${REAL_YQ}" -i '.publish.github.enabled = false' "${VALIDATE_MIRROR_DISABLED_FIXTURE}/config.yaml"
"${REAL_YQ}" -i 'del(.github)' "${VALIDATE_MIRROR_DISABLED_FIXTURE}/config.yaml"
set +e
VALIDATE_OUTPUT="$(
  VALIDATE_GITHUB_MIRROR_CONFIG_FILE="${VALIDATE_MIRROR_DISABLED_FIXTURE}/config.yaml" \
  VALIDATE_GITHUB_MIRROR_REPO_DIR="${REPO_ROOT}" \
  "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" \
  --check-gatus-config \
  --expected-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 2>&1
)"
VALIDATE_EXIT=$?
set -e
if [[ ${VALIDATE_EXIT} -eq 0 ]] && grep -q 'publish.github.enabled is not true' <<< "${VALIDATE_OUTPUT}"; then
  test_pass "validate-github-mirror skips cleanly when publish is disabled"
else
  test_fail "validate-github-mirror did not skip cleanly (exit=${VALIDATE_EXIT})"
  sed 's/^/    /' <<< "${VALIDATE_OUTPUT}" >&2
fi

# --- Case K: .gitlab-ci.yml publish:github script gates on the flag ---

test_start "11" ".gitlab-ci.yml publish:github script reads publish.github.enabled"
# publish:github is the last job in the file; capture from its declaration to EOF.
PUBLISH_BLOCK="$(sed -n '/^publish:github:$/,$p' "${REPO_ROOT}/.gitlab-ci.yml")"
if grep -Fq 'yq -r' <<< "${PUBLISH_BLOCK}" && \
   grep -Fq '.publish.github.enabled' <<< "${PUBLISH_BLOCK}" && \
   grep -Fq 'skipping publish:github' <<< "${PUBLISH_BLOCK}"; then
  test_pass "publish:github reads the flag and self-skips when disabled"
else
  test_fail "publish:github script does not gate on publish.github.enabled"
  sed 's/^/    /' <<< "${PUBLISH_BLOCK}" >&2
fi

runner_summary
