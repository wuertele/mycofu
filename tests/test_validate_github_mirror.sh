#!/usr/bin/env bash
# test_validate_github_mirror.sh — Verify validate-github-mirror.sh modes.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REAL_YQ="$(command -v yq)"
REAL_JQ="$(command -v jq)"
REAL_GIT="$(command -v git)"

source "${REPO_ROOT}/tests/lib/runner.sh"

EXPECTED_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
RAW_URL="https://raw.githubusercontent.com/example/mycofu/main/.mycofu-publish.json"

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
  path="$(mktemp -d "${TMPDIR:-/tmp}/validate-github-mirror-test.XXXXXX")"
  TEMP_PATHS+=("${path}")
  printf -v "${target_var}" '%s' "${path}"
}

make_config() {
  local path="$1"
  cat > "${path}" <<'EOF'
github:
  remote_url: git@github.com:example/mycofu.git
publish:
  github:
    enabled: true
vms:
  gatus:
    ip: 127.0.0.3
EOF
}

create_fake_curl() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
printf '%s\n' "${url}" > "${VALIDATE_MIRROR_STATE_DIR:?}/curl-url"
case "${VALIDATE_MIRROR_MODE:?}" in
  match)
    jq -n --arg sha "${VALIDATE_MIRROR_EXPECTED_SHA:?}" '{schema:1, source_commit:$sha}'
    ;;
  mismatch)
    jq -n --arg sha "${VALIDATE_MIRROR_OTHER_SHA:?}" '{schema:1, source_commit:$sha}'
    ;;
  missing)
    echo "404 Not Found" >&2
    exit 22
    ;;
  invalid-json)
    printf '{not-json}\n'
    ;;
  *)
    printf '{}\n'
    ;;
esac
EOF
  chmod +x "${path}"
}

create_fake_ssh() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
printf '%s\n' "${cmd}" > "${VALIDATE_MIRROR_STATE_DIR:?}/ssh-command"
if [[ "${VALIDATE_MIRROR_MODE:?}" == "ssh-fail" ]]; then
  echo "ssh failure" >&2
  exit 255
fi
cat "${VALIDATE_MIRROR_GATUS_CONFIG:?}"
EOF
  chmod +x "${path}"
}

setup_fixture() {
  local target_var="$1"
  make_temp_dir fixture
  make_config "${fixture}/config.yaml"
  create_fake_curl "${fixture}/fake-curl.sh"
  create_fake_ssh "${fixture}/fake-ssh.sh"
  printf -v "${target_var}" '%s' "${fixture}"
}

run_mirror() {
  local fixture="$1"
  local mode="$2"
  shift 2
  set +e
  OUTPUT="$(
    VALIDATE_MIRROR_MODE="${mode}" \
    VALIDATE_MIRROR_EXPECTED_SHA="${EXPECTED_SHA}" \
    VALIDATE_MIRROR_OTHER_SHA="${OTHER_SHA}" \
    VALIDATE_MIRROR_STATE_DIR="${fixture}" \
    VALIDATE_MIRROR_GATUS_CONFIG="${VALIDATE_MIRROR_GATUS_CONFIG:-}" \
    VALIDATE_GITHUB_MIRROR_CONFIG_FILE="${fixture}/config.yaml" \
    VALIDATE_GITHUB_MIRROR_CURL_BIN="${fixture}/fake-curl.sh" \
    VALIDATE_GITHUB_MIRROR_SSH_BIN="${fixture}/fake-ssh.sh" \
    VALIDATE_GITHUB_MIRROR_YQ_BIN="${REAL_YQ}" \
    VALIDATE_GITHUB_MIRROR_JQ_BIN="${REAL_JQ}" \
    VALIDATE_GITHUB_MIRROR_GIT_BIN="${REAL_GIT}" \
    "$@" 2>&1
  )"
  STATUS=$?
  set -e
  printf '%s' "${OUTPUT}" > "${fixture}/output.txt"
  printf '%s' "${STATUS}" > "${fixture}/exit.txt"
}

write_gatus_config() {
  local path="$1"
  local sha="$2"
  # Issue #301: matches the unquoted RHS literal that
  # generate-gatus-config.sh now emits. Gatus 5.x keeps quotes as part
  # of the literal, so a quoted RHS would never match the gjson-resolved
  # LHS.
  cat > "${path}" <<EOF
endpoints:
  - name: github-mirror-main
    group: publishing
    url: "${RAW_URL}"
    conditions:
      - "[STATUS] == 200"
      - "[BODY].source_commit == ${sha}"
EOF
}

write_gatus_config_legacy_quoted() {
  # Pre-#301 quoted form. Used to verify that the extractor surfaces
  # the broken syntax with a #301 diagnostic instead of silently
  # accepting a deployed config whose Gatus check can never go green.
  local path="$1"
  local sha="$2"
  cat > "${path}" <<EOF
endpoints:
  - name: github-mirror-main
    group: publishing
    url: "${RAW_URL}"
    conditions:
      - "[STATUS] == 200"
      - "[BODY].source_commit == \"${sha}\""
EOF
}

test_start "1" "default mode matching metadata exits 0"
setup_fixture MATCH_FIXTURE
run_mirror "${MATCH_FIXTURE}" match "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" --expected-sha "${EXPECTED_SHA}"
if [[ "$(cat "${MATCH_FIXTURE}/exit.txt")" -eq 0 ]] && grep -q "matches expected source_commit" "${MATCH_FIXTURE}/output.txt"; then
  test_pass "matching metadata passes"
else
  test_fail "matching metadata did not pass"
fi

test_start "2" "default mode mismatch exits non-zero and names both SHAs"
setup_fixture MISMATCH_FIXTURE
run_mirror "${MISMATCH_FIXTURE}" mismatch "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" --expected-sha "${EXPECTED_SHA}"
if [[ "$(cat "${MISMATCH_FIXTURE}/exit.txt")" -ne 0 ]] && \
   grep -q "${OTHER_SHA}" "${MISMATCH_FIXTURE}/output.txt" && \
   grep -q "${EXPECTED_SHA}" "${MISMATCH_FIXTURE}/output.txt"; then
  test_pass "mismatched metadata reports mirror and expected SHAs"
else
  test_fail "mismatched metadata did not report both SHAs"
fi

test_start "3" "default mode missing metadata exits non-zero"
setup_fixture MISSING_FIXTURE
run_mirror "${MISSING_FIXTURE}" missing "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" --expected-sha "${EXPECTED_SHA}"
if [[ "$(cat "${MISSING_FIXTURE}/exit.txt")" -ne 0 ]] && grep -q 'failed to fetch' "${MISSING_FIXTURE}/output.txt"; then
  test_pass "missing metadata fails"
else
  test_fail "missing metadata did not fail"
fi

test_start "4" "default mode invalid JSON exits non-zero"
setup_fixture INVALID_FIXTURE
run_mirror "${INVALID_FIXTURE}" invalid-json "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" --expected-sha "${EXPECTED_SHA}"
if [[ "$(cat "${INVALID_FIXTURE}/exit.txt")" -ne 0 ]] && grep -q 'invalid JSON' "${INVALID_FIXTURE}/output.txt"; then
  test_pass "invalid metadata fails"
else
  test_fail "invalid metadata did not fail"
fi

test_start "5" "SSH remote converts to raw GitHub metadata URL"
if [[ "$(cat "${MATCH_FIXTURE}/curl-url")" == "${RAW_URL}" ]]; then
  test_pass "raw metadata URL derived from git@github.com remote"
else
  test_fail "raw metadata URL conversion is wrong"
fi

test_start "6" "--check-gatus-config matching SHA exits 0"
setup_fixture GATUS_MATCH_FIXTURE
write_gatus_config "${GATUS_MATCH_FIXTURE}/gatus.yaml" "${EXPECTED_SHA}"
VALIDATE_MIRROR_GATUS_CONFIG="${GATUS_MATCH_FIXTURE}/gatus.yaml" \
  run_mirror "${GATUS_MATCH_FIXTURE}" match "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" --check-gatus-config --expected-sha "${EXPECTED_SHA}"
if [[ "$(cat "${GATUS_MATCH_FIXTURE}/exit.txt")" -eq 0 ]] && grep -q 'matches prod tip' "${GATUS_MATCH_FIXTURE}/output.txt"; then
  test_pass "matching deployed Gatus config passes"
else
  test_fail "matching deployed Gatus config did not pass"
fi

test_start "7" "--check-gatus-config stale SHA exits 10 with diagnostic"
setup_fixture GATUS_STALE_FIXTURE
write_gatus_config "${GATUS_STALE_FIXTURE}/gatus.yaml" "${OTHER_SHA}"
VALIDATE_MIRROR_GATUS_CONFIG="${GATUS_STALE_FIXTURE}/gatus.yaml" \
  run_mirror "${GATUS_STALE_FIXTURE}" match "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" --check-gatus-config --expected-sha "${EXPECTED_SHA}"
if [[ "$(cat "${GATUS_STALE_FIXTURE}/exit.txt")" -eq 10 ]] && \
   grep -q "${OTHER_SHA}" "${GATUS_STALE_FIXTURE}/output.txt" && \
   grep -q "${EXPECTED_SHA}" "${GATUS_STALE_FIXTURE}/output.txt"; then
  test_pass "stale deployed Gatus config exits 10 and names both SHAs"
else
  test_fail "stale deployed Gatus config did not return exit 10"
fi

test_start "8" "--check-gatus-config missing endpoint exits 11"
setup_fixture GATUS_MISSING_FIXTURE
cat > "${GATUS_MISSING_FIXTURE}/gatus.yaml" <<'EOF'
endpoints:
  - name: gitlab
    group: services
EOF
VALIDATE_MIRROR_GATUS_CONFIG="${GATUS_MISSING_FIXTURE}/gatus.yaml" \
  run_mirror "${GATUS_MISSING_FIXTURE}" match "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" --check-gatus-config --expected-sha "${EXPECTED_SHA}"
if [[ "$(cat "${GATUS_MISSING_FIXTURE}/exit.txt")" -eq 11 ]] && grep -q 'no github-mirror-main endpoint' "${GATUS_MISSING_FIXTURE}/output.txt"; then
  test_pass "missing deployed endpoint exits 11"
else
  test_fail "missing deployed endpoint did not exit 11"
fi

test_start "9" "--check-gatus-config SSH failure exits 1"
setup_fixture GATUS_SSH_FAIL_FIXTURE
write_gatus_config "${GATUS_SSH_FAIL_FIXTURE}/gatus.yaml" "${EXPECTED_SHA}"
VALIDATE_MIRROR_GATUS_CONFIG="${GATUS_SSH_FAIL_FIXTURE}/gatus.yaml" \
  run_mirror "${GATUS_SSH_FAIL_FIXTURE}" ssh-fail "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" --check-gatus-config --expected-sha "${EXPECTED_SHA}"
if [[ "$(cat "${GATUS_SSH_FAIL_FIXTURE}/exit.txt")" -eq 1 ]] && grep -q 'failed to read deployed Gatus config' "${GATUS_SSH_FAIL_FIXTURE}/output.txt"; then
  test_pass "SSH failure exits 1"
else
  test_fail "SSH failure did not exit 1"
fi

test_start "11" "--check-gatus-config rejects legacy quoted RHS literal with issue #301 diagnostic"
setup_fixture GATUS_LEGACY_QUOTED_FIXTURE
write_gatus_config_legacy_quoted "${GATUS_LEGACY_QUOTED_FIXTURE}/gatus.yaml" "${EXPECTED_SHA}"
VALIDATE_MIRROR_GATUS_CONFIG="${GATUS_LEGACY_QUOTED_FIXTURE}/gatus.yaml" \
  run_mirror "${GATUS_LEGACY_QUOTED_FIXTURE}" match "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" --check-gatus-config --expected-sha "${EXPECTED_SHA}"
if [[ "$(cat "${GATUS_LEGACY_QUOTED_FIXTURE}/exit.txt")" -eq 12 ]] && grep -q 'issue #301' "${GATUS_LEGACY_QUOTED_FIXTURE}/output.txt"; then
  test_pass "legacy quoted RHS literal exits 12 with #301 diagnostic"
else
  test_fail "legacy quoted RHS literal did not exit 12 with #301 diagnostic"
fi

test_start "10" "--check-gatus-config pins the deployed Gatus module config path"
if grep -q 'cat /run/secrets/gatus/config.yaml' "${GATUS_MATCH_FIXTURE}/ssh-command" && \
   grep -q 'GATUS_CONFIG_PATH=/run/secrets/gatus/config.yaml' "${REPO_ROOT}/framework/nix/modules/gatus.nix" && \
   grep -q 'ConditionPathExists = "/run/secrets/gatus/config.yaml"' "${REPO_ROOT}/framework/nix/modules/gatus.nix"; then
  test_pass "default deployed Gatus config path matches framework/nix/modules/gatus.nix"
else
  test_fail "deployed Gatus config path does not match framework/nix/modules/gatus.nix"
fi

runner_summary
