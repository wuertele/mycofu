#!/usr/bin/env bash
# test_validate_github_mirror.sh — Verify validate-github-mirror.sh modes.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REAL_YQ="$(command -v yq)"
REAL_JQ="$(command -v jq)"

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

# Issue #619: on a dev pipeline, CI_COMMIT_SHA is the dev tip, but the
# github-mirror probe must compare against the *published* (prod-tip)
# SHA — the public mirror tracks prod. The old resolver preferred
# CI_COMMIT_SHA over refs/remotes/gitlab/prod, producing a false
# staleness signal ("expected X but public Y") on every dev pipeline
# whose dev tip diverged from prod.
test_start "12" "resolver ignores CI_COMMIT_SHA dev tip, walks to prod ref (#619)"
setup_fixture RESOLVER_FIXTURE
FIXTURE_REPO="${RESOLVER_FIXTURE}/repo"
mkdir -p "${FIXTURE_REPO}"
(
  cd "${FIXTURE_REPO}"
  git init -q -b main
  git config user.email "test@example.com"
  git config user.name "Test"
  # Prod tip: what the public mirror tracks and Gatus asserts against.
  echo "prod" > file.txt
  git add file.txt
  git commit -qm "prod tip"
  PROD_SHA_FIXTURE="$(git rev-parse HEAD)"
  git update-ref refs/heads/prod "${PROD_SHA_FIXTURE}"
  # Dev tip: a later commit that CI_COMMIT_SHA will point at on a dev
  # pipeline. The buggy resolver would return this and produce a
  # spurious mismatch.
  echo "dev" > file.txt
  git add file.txt
  git commit -qm "dev tip"
  DEV_SHA_FIXTURE="$(git rev-parse HEAD)"
  printf '%s' "${PROD_SHA_FIXTURE}" > "${RESOLVER_FIXTURE}/prod-sha"
  printf '%s' "${DEV_SHA_FIXTURE}" > "${RESOLVER_FIXTURE}/dev-sha"
)
PROD_SHA="$(cat "${RESOLVER_FIXTURE}/prod-sha")"
DEV_SHA="$(cat "${RESOLVER_FIXTURE}/dev-sha")"
set +e
OUTPUT="$(
  CI_COMMIT_SHA="${DEV_SHA}" \
  VALIDATE_MIRROR_MODE="match" \
  VALIDATE_MIRROR_EXPECTED_SHA="${PROD_SHA}" \
  VALIDATE_MIRROR_STATE_DIR="${RESOLVER_FIXTURE}" \
  VALIDATE_GITHUB_MIRROR_REPO_DIR="${FIXTURE_REPO}" \
  VALIDATE_GITHUB_MIRROR_CONFIG_FILE="${RESOLVER_FIXTURE}/config.yaml" \
  VALIDATE_GITHUB_MIRROR_CURL_BIN="${RESOLVER_FIXTURE}/fake-curl.sh" \
  VALIDATE_GITHUB_MIRROR_SSH_BIN="${RESOLVER_FIXTURE}/fake-ssh.sh" \
  VALIDATE_GITHUB_MIRROR_YQ_BIN="${REAL_YQ}" \
  VALIDATE_GITHUB_MIRROR_JQ_BIN="${REAL_JQ}" \
  "${REPO_ROOT}/framework/scripts/validate-github-mirror.sh" 2>&1
)"
STATUS=$?
set -e
printf '%s' "${OUTPUT}" > "${RESOLVER_FIXTURE}/output.txt"
printf '%s' "${STATUS}" > "${RESOLVER_FIXTURE}/exit.txt"
if [[ "${STATUS}" -eq 0 ]] && \
   grep -q "${PROD_SHA}" "${RESOLVER_FIXTURE}/output.txt" && \
   ! grep -q "${DEV_SHA}" "${RESOLVER_FIXTURE}/output.txt"; then
  test_pass "resolver walked to refs/heads/prod (${PROD_SHA:0:12}) instead of CI_COMMIT_SHA (${DEV_SHA:0:12})"
else
  test_fail "resolver did not walk to prod ref: exit=${STATUS} output=${OUTPUT}"
fi

# Issue #619 structural ratchet: validate.sh has two positions where
# it could regress into sourcing the Gatus expected SHA from
# CI_COMMIT_SHA. The runtime resolver test above (#12) exercises the
# sub-script directly. This test ratchets the caller so a rewrite of
# the probe block that reintroduces the defect does not silently
# pass because it does not go through validate-github-mirror.sh.
test_start "13" "validate.sh does not source Gatus expected SHA from CI_COMMIT_SHA (#619)"
VALIDATE_SH="${REPO_ROOT}/framework/scripts/validate.sh"
if grep -nE 'GATUS_EXPECTED_SHA=.*CI_COMMIT_SHA' "${VALIDATE_SH}" >/dev/null; then
  BAD_LINE="$(grep -nE 'GATUS_EXPECTED_SHA=.*CI_COMMIT_SHA' "${VALIDATE_SH}" | head -1)"
  test_fail "validate.sh assigns GATUS_EXPECTED_SHA from CI_COMMIT_SHA: ${BAD_LINE}"
elif ! grep -nE 'GATUS_EXPECTED_SHA=.*resolve_gatus_expected_source_commit' "${VALIDATE_SH}" >/dev/null; then
  test_fail "validate.sh does not assign GATUS_EXPECTED_SHA via resolve_gatus_expected_source_commit"
else
  test_pass "validate.sh sources GATUS_EXPECTED_SHA via the shared prod-tip resolver"
fi

test_start "10" "--check-gatus-config pins the deployed Gatus module config path"
if grep -q 'cat /run/secrets/gatus/config.yaml' "${GATUS_MATCH_FIXTURE}/ssh-command" && \
   grep -q 'GATUS_CONFIG_PATH=/run/secrets/gatus/config.yaml' "${REPO_ROOT}/framework/nix/modules/gatus.nix" && \
   grep -q 'ConditionPathExists = "/run/secrets/gatus/config.yaml"' "${REPO_ROOT}/framework/nix/modules/gatus.nix"; then
  test_pass "default deployed Gatus config path matches framework/nix/modules/gatus.nix"
else
  test_fail "deployed Gatus config path does not match framework/nix/modules/gatus.nix"
fi

# Issue #629: validate.sh reads MYCOFU_VALIDATE_CONFIG into CONFIG but
# used to invoke validate-github-mirror.sh without forwarding CONFIG,
# so the child fell back to REPO_DIR/site/config.yaml and ignored the
# operator's override. Ratchet the caller so any rewrite of the probe
# invocation that drops the env-forward gets caught here rather than
# in production. The invocation must set VALIDATE_GITHUB_MIRROR_CONFIG_FILE
# to ${CONFIG} on the same command as the sub-script call.
test_start "14" "validate.sh forwards MYCOFU_VALIDATE_CONFIG (as CONFIG) to validate-github-mirror.sh (#629)"
VALIDATE_SH="${REPO_ROOT}/framework/scripts/validate.sh"
if ! grep -nE 'VALIDATE_GITHUB_MIRROR_CONFIG_FILE="\$\{CONFIG\}"[[:space:]]+"\$\{SCRIPT_DIR\}/validate-github-mirror\.sh"' "${VALIDATE_SH}" >/dev/null; then
  test_fail "validate.sh does not forward CONFIG (from MYCOFU_VALIDATE_CONFIG) as VALIDATE_GITHUB_MIRROR_CONFIG_FILE when invoking validate-github-mirror.sh"
else
  test_pass "validate.sh sets VALIDATE_GITHUB_MIRROR_CONFIG_FILE=\${CONFIG} on the child invocation"
fi

runner_summary
