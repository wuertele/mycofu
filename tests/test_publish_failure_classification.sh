#!/usr/bin/env bash
# test_publish_failure_classification.sh — Verify publish:github failure taxonomy.

set -euo pipefail

# The first prod-publish run sets GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE=1 as a
# per-run CI variable. That variable propagates to every stage including
# validate; without this unset, refusal cases would inherit it and bypass the
# guard they verify.
unset GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REAL_GIT="$(command -v git)"

source "${REPO_ROOT}/tests/lib/runner.sh"

REQUESTED_CASE=""
if [[ $# -gt 0 ]]; then
  case "$1" in
    --case)
      REQUESTED_CASE="${2:-}"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 2
      ;;
  esac
fi

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
  path="$(mktemp -d "${TMPDIR:-/tmp}/publish-classifier-test.XXXXXX")"
  TEMP_PATHS+=("${path}")
  printf -v "${target_var}" '%s' "${path}"
}

create_fixture_repo() {
  local work_dir="$1"

  "${REAL_GIT}" init "${work_dir}" >/dev/null
  "${REAL_GIT}" -C "${work_dir}" config user.name "Test Publisher"
  "${REAL_GIT}" -C "${work_dir}" config user.email "test@example.com"
  mkdir -p "${work_dir}/framework/scripts" "${work_dir}/tests" "${work_dir}/docs/prompts" "${work_dir}/site"
  printf 'echo public\n' > "${work_dir}/framework/scripts/public.sh"
  printf 'echo test\n' > "${work_dir}/tests/public.sh"
  printf '# readme\n' > "${work_dir}/README.md"
  printf '{}\n' > "${work_dir}/flake.nix"
  printf 'lock\n' > "${work_dir}/flake.lock"
  printf 'private\n' > "${work_dir}/site/private.txt"
  printf 'prompt\n' > "${work_dir}/docs/prompts/private.md"
  "${REAL_GIT}" -C "${work_dir}" add -A
  "${REAL_GIT}" -C "${work_dir}" commit -m "fixture source" >/dev/null
}

create_fake_git() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REAL_GIT="${PUBLISH_CLASSIFIER_REAL_GIT:?}"
CASE="${PUBLISH_CLASSIFIER_CASE:?}"
STATE_DIR="${PUBLISH_CLASSIFIER_STATE_DIR:?}"

if [[ "${1:-}" == "-C" ]]; then
  workdir="$2"
  shift 2
  cmd="${1:-}"
  case "${cmd}" in
    ls-remote)
      case "${CASE}" in
        repo-not-found)
          echo "ERROR: Repository not found." >&2
          exit 128
          ;;
        permission-denied)
          echo "git@github.com: Permission denied (publickey)." >&2
          echo "fatal: Could not read from remote repository." >&2
          exit 128
          ;;
        handshake)
          echo "kex_exchange_identification: banner exchange: invalid SSH identification string" >&2
          exit 255
          ;;
        *)
          printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\trefs/heads/main\n'
          exit 0
          ;;
      esac
      ;;
    fetch)
      exit 0
      ;;
    cat-file)
      if [[ "${2:-}" == "-p" && "${3:-}" == "refs/remotes/github/main:.mycofu-publish.json" ]]; then
        case "${CASE}" in
          initial-rewrite-no-ack|initial-rewrite-ack)
            echo "fatal: path '.mycofu-publish.json' does not exist in 'refs/remotes/github/main'" >&2
            exit 128
            ;;
          metadata-empty)
            exit 0
            ;;
          metadata-garbage)
            printf 'not-json-at-all\n'
            exit 0
            ;;
          metadata-wrong-schema)
            printf '{"schema":99,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'
            exit 0
            ;;
          metadata-bad-sha)
            printf '{"schema":1,"source_commit":"deadbeef"}\n'
            exit 0
            ;;
          metadata-nul-prefix)
            # NUL byte before otherwise-valid JSON. Bash command
            # substitution would strip the NUL and accept it as valid;
            # the helper must reject by streaming directly into jq.
            printf '\0{"schema":1,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'
            exit 0
            ;;
          metadata-multi-doc)
            # Two top-level JSON documents. jq without -s would test
            # only the last and accept; the helper must require
            # exactly one document.
            printf '{"schema":99,"source_commit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}\n{"schema":1,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'
            exit 0
            ;;
          metadata-sha-trailing-newline)
            # source_commit has 40 hex chars followed by an embedded
            # newline. jq's regex `$` would match before the newline;
            # the helper must enforce exact length.
            printf '{"schema":1,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\n"}\n'
            exit 0
            ;;
          *)
            printf '{"schema":1,"source_commit":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n'
            exit 0
            ;;
        esac
      fi
      exec "${REAL_GIT}" -C "${workdir}" "$@"
      ;;
    push)
      count_file="${STATE_DIR}/push-count"
      count=0
      [[ -f "${count_file}" ]] && count="$(cat "${count_file}")"
      count=$((count + 1))
      printf '%s' "${count}" > "${count_file}"
      case "${CASE}" in
        lease-retry)
          if [[ "${count}" -eq 1 ]]; then
            echo "! [rejected] HEAD -> main (stale info)" >&2
            exit 1
          fi
          echo "To github.com:example/mycofu.git"
          exit 0
          ;;
        lease-conflict)
          echo "! [rejected] HEAD -> main (stale info)" >&2
          exit 1
          ;;
        unknown-git-failure)
          echo "fatal: unexpected remote failure" >&2
          exit 1
          ;;
        *)
          echo "To github.com:example/mycofu.git"
          exit 0
          ;;
      esac
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

create_probe() {
  local path="$1"
  local mode="$2"
  cat > "${path}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${PUBLISH_CLASSIFIER_CASE:?}" in
  dns-failure)
    if [[ "${mode}" == "dns" ]]; then
      echo "github.com: Name or service not known" >&2
      exit 2
    fi
    ;;
  tcp-timeout)
    if [[ "${mode}" == "tcp" ]]; then
      echo "github.com:22: Connection timed out" >&2
      exit 124
    fi
    ;;
esac
exit 0
EOF
  chmod +x "${path}"
}

run_publish_case() {
  local case_name="$1"
  local fixture_dir="$2"
  local extra_env="${3:-}"
  local repo_dir="${fixture_dir}/repo"
  local key_file="${fixture_dir}/deploy-key"
  local remote_file="${fixture_dir}/remote-url"
  local status_file="${fixture_dir}/status.json"
  local fake_git="${fixture_dir}/fake-git.sh"
  local dns_probe="${fixture_dir}/dns-probe.sh"
  local tcp_probe="${fixture_dir}/tcp-probe.sh"

  create_fixture_repo "${repo_dir}"
  create_fake_git "${fake_git}"
  create_probe "${dns_probe}" dns
  create_probe "${tcp_probe}" tcp
  printf 'not-a-real-key\n' > "${key_file}"
  printf 'git@github.com:example/mycofu.git\n' > "${remote_file}"

  case "${case_name}" in
    missing-key)
      rm -f "${key_file}"
      ;;
    missing-remote)
      rm -f "${remote_file}"
      ;;
  esac

  set +e
  if [[ "${extra_env}" == "ack" ]]; then
    OUTPUT="$(
      PUBLISH_CLASSIFIER_REAL_GIT="${REAL_GIT}" \
      PUBLISH_CLASSIFIER_CASE="${case_name}" \
      PUBLISH_CLASSIFIER_STATE_DIR="${fixture_dir}" \
      PUBLISH_TO_GITHUB_REPO_DIR="${repo_dir}" \
      PUBLISH_TO_GITHUB_GIT_BIN="${fake_git}" \
      PUBLISH_TO_GITHUB_DEPLOY_KEY_PATH="${key_file}" \
      PUBLISH_TO_GITHUB_DEPLOY_KEY_FALLBACK_PATH="${key_file}" \
      PUBLISH_TO_GITHUB_REMOTE_URL_PATH="${remote_file}" \
      PUBLISH_TO_GITHUB_STATUS_PATH="${status_file}" \
      GITHUB_PUBLISH_DNS_PROBE_BIN="${dns_probe}" \
      GITHUB_PUBLISH_TCP_PROBE_BIN="${tcp_probe}" \
      GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE=1 \
      "${REPO_ROOT}/framework/scripts/publish-to-github.sh" 2>&1
    )"
  else
    OUTPUT="$(
      PUBLISH_CLASSIFIER_REAL_GIT="${REAL_GIT}" \
      PUBLISH_CLASSIFIER_CASE="${case_name}" \
      PUBLISH_CLASSIFIER_STATE_DIR="${fixture_dir}" \
      PUBLISH_TO_GITHUB_REPO_DIR="${repo_dir}" \
      PUBLISH_TO_GITHUB_GIT_BIN="${fake_git}" \
      PUBLISH_TO_GITHUB_DEPLOY_KEY_PATH="${key_file}" \
      PUBLISH_TO_GITHUB_DEPLOY_KEY_FALLBACK_PATH="${key_file}" \
      PUBLISH_TO_GITHUB_REMOTE_URL_PATH="${remote_file}" \
      PUBLISH_TO_GITHUB_STATUS_PATH="${status_file}" \
      GITHUB_PUBLISH_DNS_PROBE_BIN="${dns_probe}" \
      GITHUB_PUBLISH_TCP_PROBE_BIN="${tcp_probe}" \
      "${REPO_ROOT}/framework/scripts/publish-to-github.sh" 2>&1
    )"
  fi
  STATUS=$?
  set -e
  printf '%s' "${OUTPUT}" > "${fixture_dir}/output.txt"
  printf '%s' "${STATUS}" > "${fixture_dir}/exit.txt"
}

case_enabled() {
  local slug="$1"
  [[ -z "${REQUESTED_CASE}" || "${REQUESTED_CASE}" == "${slug}" ]]
}

assert_status() {
  local fixture_dir="$1"
  local expected_exit="$2"
  local expected_status="$3"
  local expected_classification="$4"
  local output_pattern="${5:-}"
  local actual_exit
  actual_exit="$(cat "${fixture_dir}/exit.txt")"

  if [[ "${actual_exit}" != "${expected_exit}" ]]; then
    return 1
  fi
  if ! jq -e --arg status "${expected_status}" --arg classification "${expected_classification}" \
    '.status == $status and .classification == $classification' "${fixture_dir}/status.json" >/dev/null; then
    return 1
  fi
  if [[ -n "${output_pattern}" ]] && ! grep -q "${output_pattern}" "${fixture_dir}/output.txt"; then
    return 1
  fi
  return 0
}

run_matrix_case() {
  local id="$1"
  local slug="$2"
  local desc="$3"
  local expected_exit="$4"
  local expected_status="$5"
  local expected_classification="$6"
  local output_pattern="${7:-}"
  local extra_env="${8:-}"

  case_enabled "${slug}" || return 0
  test_start "${id}" "${desc}"
  make_temp_dir FIXTURE
  run_publish_case "${slug}" "${FIXTURE}" "${extra_env}"
  if assert_status "${FIXTURE}" "${expected_exit}" "${expected_status}" "${expected_classification}" "${output_pattern}"; then
    test_pass "${desc}"
  else
    test_fail "${desc}"
    sed 's/^/    /' "${FIXTURE}/output.txt" >&2
  fi
}

run_matrix_case "C1" "missing-key" "missing key -> non-zero config_error" 1 failure config_error "GitHub deploy key not found"
run_matrix_case "C2" "missing-remote" "missing remote -> non-zero config_error" 1 failure config_error "GitHub remote URL not found"
run_matrix_case "C3" "repo-not-found" "Repository not found -> non-zero config_error" 1 failure config_error "Repository not found"
run_matrix_case "C4" "permission-denied" "Permission denied -> non-zero auth_error" 1 failure auth_error "Permission denied"
run_matrix_case "C5" "dns-failure" "DNS failure -> exit 0 outage_skip" 0 outage_skip outage "PUBLISH_STATUS=outage_skip"
run_matrix_case "C6" "tcp-timeout" "TCP timeout -> exit 0 outage_skip" 0 outage_skip outage "PUBLISH_STATUS=outage_skip"
run_matrix_case "C7" "handshake" "generic SSH handshake after DNS/TCP success -> non-zero auth_error" 1 failure auth_error "kex_exchange_identification"
run_matrix_case "C8" "lease-retry" "lease miss once -> refetch/retry/succeed" 0 success lease_retry "PUBLISH_STATUS=success"
run_matrix_case "C9" "lease-conflict" "lease miss twice -> non-zero lease_conflict" 1 failure lease_conflict "stale info"
run_matrix_case "C10" "unknown-git-failure" "unknown git failure -> non-zero unknown_error" 1 failure unknown_error "unexpected remote failure"
run_matrix_case "C11" "initial-rewrite-no-ack" "initial-rewrite-no-ack -> non-zero before push" 1 failure config_error "Initial GitHub main rewrite acknowledgement"
run_matrix_case "C12" "initial-rewrite-ack" "initial-rewrite-ack -> proceeds" 0 success success "PUBLISH_STATUS=success" ack
run_matrix_case "C13" "metadata-empty" "empty metadata file -> non-zero before push (treated as missing)" 1 failure config_error "Initial GitHub main rewrite acknowledgement"
run_matrix_case "C14" "metadata-garbage" "garbage metadata file -> non-zero before push (treated as missing)" 1 failure config_error "Initial GitHub main rewrite acknowledgement"
run_matrix_case "C15" "metadata-wrong-schema" "wrong-schema metadata -> non-zero before push (treated as missing)" 1 failure config_error "Initial GitHub main rewrite acknowledgement"
run_matrix_case "C16" "metadata-bad-sha" "bad-SHA metadata -> non-zero before push (treated as missing)" 1 failure config_error "Initial GitHub main rewrite acknowledgement"
run_matrix_case "C17" "metadata-nul-prefix" "NUL-prefixed metadata -> non-zero before push (no command-substitution NUL stripping)" 1 failure config_error "Initial GitHub main rewrite acknowledgement"
run_matrix_case "C18" "metadata-multi-doc" "multi-document JSON metadata -> non-zero before push (single document required)" 1 failure config_error "Initial GitHub main rewrite acknowledgement"
run_matrix_case "C19" "metadata-sha-trailing-newline" "source_commit with embedded newline -> non-zero before push (exact length required)" 1 failure config_error "Initial GitHub main rewrite acknowledgement"

if [[ -n "${REQUESTED_CASE}" && "${_PASS_COUNT}" -eq 0 && "${_FAIL_COUNT}" -eq 0 ]]; then
  test_start "case" "requested case exists"
  test_fail "unknown case: ${REQUESTED_CASE}"
fi

runner_summary

