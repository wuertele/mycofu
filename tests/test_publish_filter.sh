#!/usr/bin/env bash
# test_publish_filter.sh — Verify GitHub publishing filter and wrappers.

set -euo pipefail

# The first prod-publish run sets GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE=1 as a
# per-run CI variable. That variable propagates to every stage including
# validate; without this unset, refusal cases would inherit it and bypass the
# guard they verify.
unset GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REAL_GIT="$(command -v git)"
REAL_JQ="$(command -v jq)"
REAL_YQ="$(command -v yq)"

source "${REPO_ROOT}/tests/lib/runner.sh"

PUBLISH_FILTER_REPO_DIR="${REPO_ROOT}"
PUBLISH_FILTER_GIT_BIN="${REAL_GIT}"
source "${REPO_ROOT}/framework/scripts/publish-filter.sh"

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
  # Use printf -v instead of command substitution so TEMP_PATHS is updated
  # in the parent shell and the EXIT trap can remove everything we create.
  local target_var="$1"
  local path
  path="$(mktemp -d "${TMPDIR:-/tmp}/publish-filter-test.XXXXXX")"
  TEMP_PATHS+=("${path}")
  printf -v "${target_var}" '%s' "${path}"
}

create_sync_fixture() {
  local fixture_dir="$1"
  local gitlab_remote="${fixture_dir}/gitlab.git"
  local github_remote="${fixture_dir}/github.git"
  local work_dir="${fixture_dir}/work"

  "${REAL_GIT}" init --bare "${gitlab_remote}" >/dev/null
  "${REAL_GIT}" init --bare "${github_remote}" >/dev/null
  "${REAL_GIT}" init "${work_dir}" >/dev/null
  "${REAL_GIT}" -C "${work_dir}" config user.name "Test Publisher"
  "${REAL_GIT}" -C "${work_dir}" config user.email "test@example.com"

  mkdir -p \
    "${work_dir}/framework/scripts" \
    "${work_dir}/tests" \
    "${work_dir}/site/sops" \
    "${work_dir}/docs/prompts" \
    "${work_dir}/docs/reports" \
    "${work_dir}/docs/sprints" \
    "${work_dir}/docs/reviews"

  printf 'echo public\n' > "${work_dir}/framework/scripts/public.sh"
  printf 'echo test\n' > "${work_dir}/tests/public.sh"
  printf '# readme\n' > "${work_dir}/README.md"
  printf '{}\n' > "${work_dir}/flake.nix"
  printf 'lock\n' > "${work_dir}/flake.lock"
  printf 'private\n' > "${work_dir}/site/private.txt"
  printf 'prompt\n' > "${work_dir}/docs/prompts/private.md"
  printf 'report\n' > "${work_dir}/docs/reports/private.md"
  printf 'sprint\n' > "${work_dir}/docs/sprints/private.md"
  printf 'review\n' > "${work_dir}/docs/reviews/public.md"
  cat > "${work_dir}/site/config.yaml" <<'EOF'
vms:
  gitlab:
    ip: 127.0.0.1
EOF
  : > "${work_dir}/site/sops/secrets.yaml"

  "${REAL_GIT}" -C "${work_dir}" add -A
  "${REAL_GIT}" -C "${work_dir}" commit -m "fixture publish source" >/dev/null
  "${REAL_GIT}" -C "${work_dir}" branch -M feature
  "${REAL_GIT}" -C "${work_dir}" remote add gitlab "${gitlab_remote}"
  "${REAL_GIT}" -C "${work_dir}" remote add github "${github_remote}"
  "${REAL_GIT}" -C "${work_dir}" push gitlab HEAD:prod >/dev/null
}

create_success_probe() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${path}"
}

create_fake_publish_git() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REAL_GIT="${FAKE_PUBLISH_REAL_GIT:?}"

if [[ "${1:-}" == "-C" ]]; then
  workdir="$2"
  shift 2
  cmd="${1:-}"
  case "${cmd}" in
    ls-remote)
      printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/main\n'
      exit 0
      ;;
    fetch)
      exit 0
      ;;
    cat-file)
      if [[ "${2:-}" == "-p" && "${3:-}" == "refs/remotes/github/main:.mycofu-publish.json" ]]; then
        printf '{"schema":1,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'
        exit 0
      fi
      exec "${REAL_GIT}" -C "${workdir}" "$@"
      ;;
    push)
      capture_dir="${FAKE_PUBLISH_CAPTURE_DIR:?}"
      mkdir -p "${capture_dir}"
      "${REAL_GIT}" -C "${workdir}" show HEAD:.mycofu-publish.json > "${capture_dir}/metadata.json"
      "${REAL_GIT}" -C "${workdir}" ls-tree -r --name-only HEAD > "${capture_dir}/tree.txt"
      exit 0
      ;;
    *)
      exec "${REAL_GIT}" -C "${workdir}" "$@"
      ;;
  esac
fi

exec "${REAL_GIT}" "$@"
EOF
  chmod +x "${path}"
}

create_fake_curl() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if printf '%s\n' "$*" | grep -q '/oauth/token'; then
  printf '{"access_token":"fixture-token"}\n'
  exit 0
fi

if printf '%s\n' "$*" | grep -q '/api/v4/projects/'; then
  case "${FAKE_SYNC_PIPELINE_STATUS:-failed}" in
    success)
      printf '[{"id":42,"status":"success"}]\n'
      ;;
    *)
      printf '[{"id":42,"status":"failed"}]\n'
      ;;
  esac
  exit 0
fi

printf '{}\n'
EOF
  chmod +x "${path}"
}

create_fake_sops() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fixture-password\n'
EOF
  chmod +x "${path}"
}

make_temp_dir ARCHIVE_DIR
publish_filter_archive HEAD "${ARCHIVE_DIR}"

test_start "1" "publish_filter_archive includes allowlisted framework paths"
if [[ -e "${ARCHIVE_DIR}/framework" ]] && \
   [[ -e "${ARCHIVE_DIR}/tests" ]] && \
   [[ -e "${ARCHIVE_DIR}/README.md" ]] && \
   [[ -e "${ARCHIVE_DIR}/flake.nix" ]]; then
  test_pass "framework/, tests/, README.md, and flake.nix are present"
else
  test_fail "publish_filter_archive missed required allowlisted content"
fi

test_start "2" "publish_filter_archive excludes private paths"
if [[ ! -e "${ARCHIVE_DIR}/site" ]] && \
   [[ ! -e "${ARCHIVE_DIR}/docs/prompts" ]] && \
   [[ ! -e "${ARCHIVE_DIR}/docs/reports" ]] && \
   [[ ! -e "${ARCHIVE_DIR}/docs/sprints" ]]; then
  test_pass "site/ and excluded docs subtrees are absent"
else
  test_fail "publish_filter_archive leaked a private path"
fi

test_start "3" "publish_filter_verify passes on allowlisted output"
if publish_filter_verify "${ARCHIVE_DIR}" >/dev/null 2>&1; then
  test_pass "verify accepted the filtered archive"
else
  test_fail "publish_filter_verify rejected valid filtered output"
fi

test_start "4" "publish_filter_verify fails on non-allowlisted output"
mkdir -p "${ARCHIVE_DIR}/site"
printf 'leak\n' > "${ARCHIVE_DIR}/site/private.txt"
set +e
VERIFY_OUTPUT="$(publish_filter_verify "${ARCHIVE_DIR}" 2>&1)"
VERIFY_EXIT=$?
set -e
if [[ "${VERIFY_EXIT}" -ne 0 ]] && grep -q 'site/private.txt' <<< "${VERIFY_OUTPUT}"; then
  test_pass "verify rejected the injected private path"
else
  test_fail "publish_filter_verify did not catch an unexpected path"
fi

test_start "5" "publish-to-github.sh fails when deploy key is missing"
make_temp_dir REMOTE_URL_DIR
REMOTE_URL_FILE="${REMOTE_URL_DIR}/remote-url"
printf 'git@github.com:example/mycofu.git\n' > "${REMOTE_URL_FILE}"
STATUS_MISSING_KEY="${REMOTE_URL_DIR}/status.json"
set +e
PUBLISH_MISSING_KEY_OUTPUT="$(
  PUBLISH_TO_GITHUB_REPO_DIR="${REPO_ROOT}" \
  PUBLISH_TO_GITHUB_GIT_BIN="${REAL_GIT}" \
  PUBLISH_TO_GITHUB_DEPLOY_KEY_PATH="${REPO_ROOT}/.missing-github-key" \
  PUBLISH_TO_GITHUB_DEPLOY_KEY_FALLBACK_PATH="${REPO_ROOT}/.missing-github-key-legacy" \
  PUBLISH_TO_GITHUB_REMOTE_URL_PATH="${REMOTE_URL_FILE}" \
  PUBLISH_TO_GITHUB_STATUS_PATH="${STATUS_MISSING_KEY}" \
  "${REPO_ROOT}/framework/scripts/publish-to-github.sh" 2>&1
)"
PUBLISH_MISSING_KEY_EXIT=$?
set -e
if [[ "${PUBLISH_MISSING_KEY_EXIT}" -ne 0 ]] && \
   grep -q 'ERROR: GitHub deploy key not found' <<< "${PUBLISH_MISSING_KEY_OUTPUT}" && \
   grep -q 'seed-github-deploy-key.sh prod' <<< "${PUBLISH_MISSING_KEY_OUTPUT}" && \
   jq -e '.status == "failure" and .classification == "config_error"' "${STATUS_MISSING_KEY}" >/dev/null; then
  test_pass "missing deploy key exits non-zero with config_error status"
else
  test_fail "missing deploy key did not fail loud with config_error"
fi

test_start "6" "publish-to-github.sh fails when remote URL is missing"
make_temp_dir DEPLOY_KEY_DIR
DEPLOY_KEY_FILE="${DEPLOY_KEY_DIR}/deploy-key"
printf 'not-a-real-key\n' > "${DEPLOY_KEY_FILE}"
STATUS_MISSING_REMOTE="${DEPLOY_KEY_DIR}/status.json"
set +e
PUBLISH_MISSING_REMOTE_OUTPUT="$(
  PUBLISH_TO_GITHUB_REPO_DIR="${REPO_ROOT}" \
  PUBLISH_TO_GITHUB_GIT_BIN="${REAL_GIT}" \
  PUBLISH_TO_GITHUB_DEPLOY_KEY_PATH="${DEPLOY_KEY_FILE}" \
  PUBLISH_TO_GITHUB_DEPLOY_KEY_FALLBACK_PATH="${DEPLOY_KEY_FILE}" \
  PUBLISH_TO_GITHUB_REMOTE_URL_PATH="${REPO_ROOT}/.missing-github-remote" \
  PUBLISH_TO_GITHUB_STATUS_PATH="${STATUS_MISSING_REMOTE}" \
  "${REPO_ROOT}/framework/scripts/publish-to-github.sh" 2>&1
)"
PUBLISH_MISSING_REMOTE_EXIT=$?
set -e
if [[ "${PUBLISH_MISSING_REMOTE_EXIT}" -ne 0 ]] && \
   grep -q 'ERROR: GitHub remote URL not found' <<< "${PUBLISH_MISSING_REMOTE_OUTPUT}" && \
   jq -e '.status == "failure" and .classification == "config_error"' "${STATUS_MISSING_REMOTE}" >/dev/null; then
  test_pass "missing remote URL exits non-zero with config_error status"
else
  test_fail "missing remote URL did not fail loud with config_error"
fi

make_temp_dir FIXTURE_DIR
create_sync_fixture "${FIXTURE_DIR}"
FAKE_CURL="${FIXTURE_DIR}/fake-curl.sh"
FAKE_SOPS="${FIXTURE_DIR}/fake-sops.sh"
create_fake_curl "${FAKE_CURL}"
create_fake_sops "${FAKE_SOPS}"

test_start "7" "sync-to-main.sh refuses without a passing prod pipeline"
set +e
SYNC_REFUSE_OUTPUT="$(
  FAKE_SYNC_PIPELINE_STATUS=failed \
  SYNC_TO_MAIN_REPO_DIR="${FIXTURE_DIR}/work" \
  SYNC_TO_MAIN_GIT_BIN="${REAL_GIT}" \
  SYNC_TO_MAIN_CURL_BIN="${FAKE_CURL}" \
  SYNC_TO_MAIN_JQ_BIN="${REAL_JQ}" \
  SYNC_TO_MAIN_YQ_BIN="${REAL_YQ}" \
  SYNC_TO_MAIN_SOPS_BIN="${FAKE_SOPS}" \
  SYNC_TO_MAIN_SECRETS_FILE="${FIXTURE_DIR}/work/site/sops/secrets.yaml" \
  "${REPO_ROOT}/framework/scripts/sync-to-main.sh" 2>&1
)"
SYNC_REFUSE_EXIT=$?
set -e
if [[ "${SYNC_REFUSE_EXIT}" -ne 0 ]] && grep -q 'has no passing pipeline' <<< "${SYNC_REFUSE_OUTPUT}"; then
  test_pass "sync-to-main.sh blocked an unvalidated prod commit"
else
  test_fail "sync-to-main.sh did not refuse the unvalidated prod commit"
fi

test_start "8" "sync-to-main.sh --force-unvalidated publishes with warning and initial rewrite ack"
set +e
SYNC_FORCE_OUTPUT="$(
  FAKE_SYNC_PIPELINE_STATUS=failed \
  GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE=1 \
  SYNC_TO_MAIN_REPO_DIR="${FIXTURE_DIR}/work" \
  SYNC_TO_MAIN_GIT_BIN="${REAL_GIT}" \
  SYNC_TO_MAIN_CURL_BIN="${FAKE_CURL}" \
  SYNC_TO_MAIN_JQ_BIN="${REAL_JQ}" \
  SYNC_TO_MAIN_YQ_BIN="${REAL_YQ}" \
  SYNC_TO_MAIN_SOPS_BIN="${FAKE_SOPS}" \
  SYNC_TO_MAIN_SECRETS_FILE="${FIXTURE_DIR}/work/site/sops/secrets.yaml" \
  "${REPO_ROOT}/framework/scripts/sync-to-main.sh" --force-unvalidated 2>&1
)"
SYNC_FORCE_EXIT=$?
set -e
SYNC_TREE="$("${REAL_GIT}" --git-dir "${FIXTURE_DIR}/github.git" ls-tree -r --name-only main 2>/dev/null || true)"
SYNC_METADATA="$("${REAL_GIT}" --git-dir "${FIXTURE_DIR}/github.git" show main:.mycofu-publish.json 2>/dev/null || true)"
SYNC_SOURCE_SHA="$("${REAL_GIT}" -C "${FIXTURE_DIR}/work" rev-parse refs/remotes/gitlab/prod)"
if [[ "${SYNC_FORCE_EXIT}" -eq 0 ]] && \
   grep -q 'WARNING: Skipping GitLab pipeline verification' <<< "${SYNC_FORCE_OUTPUT}" && \
   grep -qx 'README.md' <<< "${SYNC_TREE}" && \
   grep -qx '.mycofu-publish.json' <<< "${SYNC_TREE}" && \
   ! grep -q '^site/' <<< "${SYNC_TREE}" && \
   ! grep -q '^docs/prompts/' <<< "${SYNC_TREE}" && \
   ! grep -q '^docs/reports/' <<< "${SYNC_TREE}" && \
   ! grep -q '^docs/sprints/' <<< "${SYNC_TREE}" && \
   jq -e --arg sha "${SYNC_SOURCE_SHA}" '.schema == 1 and .source_commit == $sha and .publisher == "sync-to-main.sh" and (.source_commit | length == 40)' <<< "${SYNC_METADATA}" >/dev/null && \
   ! grep -Eiq 'deploy[_-]?key|private[_-]?key|token|password|secret' <<< "${SYNC_METADATA}"; then
  test_pass "forced publish warned, wrote metadata, and pushed only filtered content"
else
  test_fail "forced publish did not complete with the expected filtered result"
fi

test_start "9" "publish-to-github.sh writes metadata without leaking private paths"
make_temp_dir PUBLISH_FIXTURE
PUBLISH_REMOTE_FILE="${PUBLISH_FIXTURE}/remote-url"
PUBLISH_KEY_FILE="${PUBLISH_FIXTURE}/deploy-key"
PUBLISH_STATUS_FILE="${PUBLISH_FIXTURE}/status.json"
PUBLISH_CAPTURE_DIR="${PUBLISH_FIXTURE}/capture"
FAKE_PUBLISH_GIT="${PUBLISH_FIXTURE}/fake-git.sh"
SUCCESS_PROBE="${PUBLISH_FIXTURE}/success-probe.sh"
printf 'git@github.com:example/mycofu.git\n' > "${PUBLISH_REMOTE_FILE}"
printf 'not-a-real-key\n' > "${PUBLISH_KEY_FILE}"
create_fake_publish_git "${FAKE_PUBLISH_GIT}"
create_success_probe "${SUCCESS_PROBE}"

set +e
PUBLISH_SUCCESS_OUTPUT="$(
  FAKE_PUBLISH_REAL_GIT="${REAL_GIT}" \
  FAKE_PUBLISH_CAPTURE_DIR="${PUBLISH_CAPTURE_DIR}" \
  PUBLISH_TO_GITHUB_REPO_DIR="${REPO_ROOT}" \
  PUBLISH_TO_GITHUB_GIT_BIN="${FAKE_PUBLISH_GIT}" \
  PUBLISH_TO_GITHUB_DEPLOY_KEY_PATH="${PUBLISH_KEY_FILE}" \
  PUBLISH_TO_GITHUB_DEPLOY_KEY_FALLBACK_PATH="${PUBLISH_KEY_FILE}" \
  PUBLISH_TO_GITHUB_REMOTE_URL_PATH="${PUBLISH_REMOTE_FILE}" \
  PUBLISH_TO_GITHUB_STATUS_PATH="${PUBLISH_STATUS_FILE}" \
  GITHUB_PUBLISH_DNS_PROBE_BIN="${SUCCESS_PROBE}" \
  GITHUB_PUBLISH_TCP_PROBE_BIN="${SUCCESS_PROBE}" \
  "${REPO_ROOT}/framework/scripts/publish-to-github.sh" 2>&1
)"
PUBLISH_SUCCESS_EXIT=$?
set -e
PUBLISH_SOURCE_SHA="$("${REAL_GIT}" -C "${REPO_ROOT}" rev-parse HEAD)"
if [[ "${PUBLISH_SUCCESS_EXIT}" -eq 0 ]] && \
   grep -q 'PUBLISH_STATUS=success' <<< "${PUBLISH_SUCCESS_OUTPUT}" && \
   jq -e --arg sha "${PUBLISH_SOURCE_SHA}" '.schema == 1 and .source_commit == $sha and .publisher == "publish:github" and (.source_commit | length == 40)' "${PUBLISH_CAPTURE_DIR}/metadata.json" >/dev/null && \
   jq -e '.status == "success" and .classification == "success"' "${PUBLISH_STATUS_FILE}" >/dev/null && \
   grep -qx '.mycofu-publish.json' "${PUBLISH_CAPTURE_DIR}/tree.txt" && \
   ! grep -q '^site/' "${PUBLISH_CAPTURE_DIR}/tree.txt" && \
   ! grep -q '^docs/prompts/' "${PUBLISH_CAPTURE_DIR}/tree.txt" && \
   ! grep -q '^docs/reports/' "${PUBLISH_CAPTURE_DIR}/tree.txt" && \
   ! grep -q '^docs/sprints/' "${PUBLISH_CAPTURE_DIR}/tree.txt" && \
   ! grep -Eiq 'deploy[_-]?key|private[_-]?key|token|password|secret' "${PUBLISH_CAPTURE_DIR}/metadata.json"; then
  test_pass "pipeline publisher wrote valid metadata and preserved private path exclusions"
else
  test_fail "pipeline publisher metadata or filter output was not valid"
fi

test_start "10" "sync-to-main.sh refuses initial GitHub main rewrite without ack"
make_temp_dir SYNC_REWRITE_FIXTURE
create_sync_fixture "${SYNC_REWRITE_FIXTURE}"
SYNC_REWRITE_CURL="${SYNC_REWRITE_FIXTURE}/fake-curl.sh"
SYNC_REWRITE_SOPS="${SYNC_REWRITE_FIXTURE}/fake-sops.sh"
create_fake_curl "${SYNC_REWRITE_CURL}"
create_fake_sops "${SYNC_REWRITE_SOPS}"
set +e
SYNC_REWRITE_OUTPUT="$(
  FAKE_SYNC_PIPELINE_STATUS=failed \
  SYNC_TO_MAIN_REPO_DIR="${SYNC_REWRITE_FIXTURE}/work" \
  SYNC_TO_MAIN_GIT_BIN="${REAL_GIT}" \
  SYNC_TO_MAIN_CURL_BIN="${SYNC_REWRITE_CURL}" \
  SYNC_TO_MAIN_JQ_BIN="${REAL_JQ}" \
  SYNC_TO_MAIN_YQ_BIN="${REAL_YQ}" \
  SYNC_TO_MAIN_SOPS_BIN="${SYNC_REWRITE_SOPS}" \
  SYNC_TO_MAIN_SECRETS_FILE="${SYNC_REWRITE_FIXTURE}/work/site/sops/secrets.yaml" \
  "${REPO_ROOT}/framework/scripts/sync-to-main.sh" --force-unvalidated 2>&1
)"
SYNC_REWRITE_EXIT=$?
set -e
if [[ "${SYNC_REWRITE_EXIT}" -ne 0 ]] && \
   grep -q 'refusing initial history rewrite' <<< "${SYNC_REWRITE_OUTPUT}" && \
   ! "${REAL_GIT}" --git-dir "${SYNC_REWRITE_FIXTURE}/github.git" show-ref --verify --quiet refs/heads/main; then
  test_pass "sync-to-main.sh requires GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE before first publish"
else
  test_fail "sync-to-main.sh allowed an unacknowledged initial rewrite"
fi

test_start "11" "sync-to-main.sh refuses when GitHub main has malformed .mycofu-publish.json"
make_temp_dir SYNC_MALFORMED_FIXTURE
create_sync_fixture "${SYNC_MALFORMED_FIXTURE}"
SYNC_MALFORMED_CURL="${SYNC_MALFORMED_FIXTURE}/fake-curl.sh"
SYNC_MALFORMED_SOPS="${SYNC_MALFORMED_FIXTURE}/fake-sops.sh"
create_fake_curl "${SYNC_MALFORMED_CURL}"
create_fake_sops "${SYNC_MALFORMED_SOPS}"
# Seed github.git with a main commit whose .mycofu-publish.json is
# wrong-schema (not the new shape). The blob exists, so the
# pre-fix `cat-file -e` check would have skipped the guard. The new
# helper must reject the schema and trigger the guard.
SYNC_MALFORMED_SEED="${SYNC_MALFORMED_FIXTURE}/seed"
"${REAL_GIT}" init "${SYNC_MALFORMED_SEED}" >/dev/null
"${REAL_GIT}" -C "${SYNC_MALFORMED_SEED}" config user.name "Mycofu Publish Bot"
"${REAL_GIT}" -C "${SYNC_MALFORMED_SEED}" config user.email "publish@mycofu.invalid"
printf '{"schema":99,"source_commit":"deadbeef"}\n' > "${SYNC_MALFORMED_SEED}/.mycofu-publish.json"
"${REAL_GIT}" -C "${SYNC_MALFORMED_SEED}" add .mycofu-publish.json
"${REAL_GIT}" -C "${SYNC_MALFORMED_SEED}" commit -m "malformed seed" >/dev/null
"${REAL_GIT}" -C "${SYNC_MALFORMED_SEED}" push "${SYNC_MALFORMED_FIXTURE}/github.git" HEAD:refs/heads/main >/dev/null 2>&1
SEED_OID="$("${REAL_GIT}" --git-dir "${SYNC_MALFORMED_FIXTURE}/github.git" rev-parse refs/heads/main)"

set +e
SYNC_MALFORMED_OUTPUT="$(
  FAKE_SYNC_PIPELINE_STATUS=failed \
  SYNC_TO_MAIN_REPO_DIR="${SYNC_MALFORMED_FIXTURE}/work" \
  SYNC_TO_MAIN_GIT_BIN="${REAL_GIT}" \
  SYNC_TO_MAIN_CURL_BIN="${SYNC_MALFORMED_CURL}" \
  SYNC_TO_MAIN_JQ_BIN="${REAL_JQ}" \
  SYNC_TO_MAIN_YQ_BIN="${REAL_YQ}" \
  SYNC_TO_MAIN_SOPS_BIN="${SYNC_MALFORMED_SOPS}" \
  SYNC_TO_MAIN_SECRETS_FILE="${SYNC_MALFORMED_FIXTURE}/work/site/sops/secrets.yaml" \
  "${REPO_ROOT}/framework/scripts/sync-to-main.sh" --force-unvalidated 2>&1
)"
SYNC_MALFORMED_EXIT=$?
set -e

POST_OID="$("${REAL_GIT}" --git-dir "${SYNC_MALFORMED_FIXTURE}/github.git" rev-parse refs/heads/main)"
if [[ "${SYNC_MALFORMED_EXIT}" -ne 0 ]] && \
   grep -q 'refusing initial history rewrite' <<< "${SYNC_MALFORMED_OUTPUT}" && \
   [[ "${POST_OID}" == "${SEED_OID}" ]]; then
  test_pass "sync-to-main.sh treats malformed .mycofu-publish.json as missing and refuses without ack"
else
  test_fail "sync-to-main.sh accepted malformed metadata or moved github main without acknowledgement"
fi

runner_summary
