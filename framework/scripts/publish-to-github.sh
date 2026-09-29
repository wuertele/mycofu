#!/usr/bin/env bash
# publish-to-github.sh — Publish the framework mirror to GitHub main.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${PUBLISH_TO_GITHUB_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
PUBLISH_TO_GITHUB_GIT_BIN="${PUBLISH_TO_GITHUB_GIT_BIN:-git}"
PUBLISH_TO_GITHUB_DEPLOY_KEY_PATH="${PUBLISH_TO_GITHUB_DEPLOY_KEY_PATH:-/run/secrets/vault-agent/github-deploy-key}"
PUBLISH_TO_GITHUB_DEPLOY_KEY_FALLBACK_PATH="${PUBLISH_TO_GITHUB_DEPLOY_KEY_FALLBACK_PATH:-/run/secrets/github/deploy-key}"
PUBLISH_TO_GITHUB_REMOTE_URL_PATH="${PUBLISH_TO_GITHUB_REMOTE_URL_PATH:-/run/secrets/github/remote-url}"
STATUS_PATH="${PUBLISH_TO_GITHUB_STATUS_PATH:-${REPO_DIR}/build/github-publish-status.json}"

PUBLISH_FILTER_REPO_DIR="${REPO_DIR}"
PUBLISH_FILTER_GIT_BIN="${PUBLISH_TO_GITHUB_GIT_BIN}"
source "${SCRIPT_DIR}/publish-filter.sh"
source "${SCRIPT_DIR}/github-publish-lib.sh"

SOURCE_SHA="$("${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${REPO_DIR}" rev-parse HEAD)"
SOURCE_SHORT="${SOURCE_SHA:0:12}"
REMOTE_URL=""
REMOTE_MAIN_OID=""

write_status() {
  local status="$1"
  local classification="$2"
  local github_oid="${3:-${REMOTE_MAIN_OID}}"
  local timestamp=""

  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  mkdir -p "$(dirname "${STATUS_PATH}")"
  jq -n \
    --arg status "${status}" \
    --arg classification "${classification}" \
    --arg source_commit "${SOURCE_SHA}" \
    --arg remote_url "${REMOTE_URL}" \
    --arg github_oid "${github_oid}" \
    --arg timestamp "${timestamp}" \
    '{
      status: $status,
      classification: $classification,
      source_commit: $source_commit,
      remote_url: $remote_url,
      github_oid: ($github_oid | if length > 0 then . else null end),
      timestamp: $timestamp
    }' > "${STATUS_PATH}"
}

fail_publish() {
  local classification="$1"
  local message="$2"
  local detail="${3:-}"

  echo "${message}" >&2
  [[ -n "${detail}" ]] && printf '%s\n' "${detail}" >&2
  echo "PUBLISH_STATUS=${classification}" >&2
  write_status "failure" "${classification}"
  exit 1
}

outage_skip() {
  local detail="${1:-}"

  echo "WARNING: GitHub transport outage; prod deploy remains successful." >&2
  [[ -n "${detail}" ]] && printf '%s\n' "${detail}" >&2
  echo "PUBLISH_STATUS=outage_skip"
  write_status "outage_skip" "outage"
  exit 0
}

DEPLOY_KEY_PATH="$(github_publish_select_deploy_key "${PUBLISH_TO_GITHUB_DEPLOY_KEY_PATH}" "${PUBLISH_TO_GITHUB_DEPLOY_KEY_FALLBACK_PATH}" || true)"
if [[ -z "${DEPLOY_KEY_PATH}" ]]; then
  fail_publish "config_error" "ERROR: GitHub deploy key not found.
Run framework/scripts/seed-github-deploy-key.sh prod --key-file <path>."
fi

if [[ ! -s "${PUBLISH_TO_GITHUB_REMOTE_URL_PATH}" ]]; then
  fail_publish "config_error" "ERROR: GitHub remote URL not found."
fi

REMOTE_URL="$(tr -d '[:space:]' < "${PUBLISH_TO_GITHUB_REMOTE_URL_PATH}")"
if [[ -z "${REMOTE_URL}" ]]; then
  fail_publish "config_error" "ERROR: GitHub remote URL not found."
fi

if ! github_remote_validate "${REMOTE_URL}"; then
  fail_publish "config_error" "ERROR: GitHub remote URL must use SSH form git@github.com:<owner>/<repo>.git: ${REMOTE_URL}"
fi

set +e
PREFLIGHT_OUTPUT="$(github_publish_transport_preflight github.com 2>&1)"
PREFLIGHT_EXIT=$?
set -e
if [[ "${PREFLIGHT_EXIT}" -ne 0 ]]; then
  outage_skip "${PREFLIGHT_OUTPUT}"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/publish-github.XXXXXX")"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

publish_filter_archive "HEAD" "${TMP_DIR}"
publish_filter_verify "${TMP_DIR}"
github_publish_write_metadata "${TMP_DIR}" "${SOURCE_SHA}" "publish:github"
publish_filter_verify "${TMP_DIR}"

"${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" init >/dev/null
"${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" config user.name "Mycofu Publish Bot"
"${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" config user.email "publish@mycofu.invalid"
"${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" add -A
"${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" commit -m "publish: sync from prod ${SOURCE_SHORT}" >/dev/null
"${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" remote add github "${REMOTE_URL}"

export GIT_SSH_COMMAND="ssh -i ${DEPLOY_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR"

set +e
REMOTE_MAIN="$("${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" ls-remote --heads github refs/heads/main 2>&1)"
REMOTE_MAIN_EXIT=$?
set -e

if [[ "${REMOTE_MAIN_EXIT}" -ne 0 ]]; then
  CLASSIFICATION="$(github_publish_classify_git_error "${REMOTE_MAIN}")"
  if [[ "${CLASSIFICATION}" == "outage" ]]; then
    outage_skip "${REMOTE_MAIN}"
  fi
  fail_publish "${CLASSIFICATION}" "ERROR: GitHub ls-remote failed (${CLASSIFICATION})." "${REMOTE_MAIN}"
fi

REMOTE_MAIN_OID="$(github_publish_extract_remote_oid "${REMOTE_MAIN}")"

if [[ -n "${REMOTE_MAIN_OID}" ]]; then
  set +e
  FETCH_OUTPUT="$("${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" fetch --depth=1 github refs/heads/main:refs/remotes/github/main 2>&1)"
  FETCH_EXIT=$?
  set -e
  if [[ "${FETCH_EXIT}" -ne 0 ]]; then
    CLASSIFICATION="$(github_publish_classify_git_error "${FETCH_OUTPUT}")"
    if [[ "${CLASSIFICATION}" == "outage" ]]; then
      outage_skip "${FETCH_OUTPUT}"
    fi
    fail_publish "${CLASSIFICATION}" "ERROR: GitHub metadata fetch failed (${CLASSIFICATION})." "${FETCH_OUTPUT}"
  fi

  if ! github_publish_metadata_present "${PUBLISH_TO_GITHUB_GIT_BIN}" "${TMP_DIR}" "refs/remotes/github/main"; then
    if ! github_publish_initial_rewrite_guard; then
      fail_publish "config_error" "ERROR: Initial GitHub main rewrite acknowledgement is required."
    fi
  fi
else
  if ! github_publish_initial_rewrite_guard; then
    fail_publish "config_error" "ERROR: Initial GitHub main rewrite acknowledgement is required."
  fi
fi

push_once() {
  local expected_oid="$1"
  "${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" push --force-with-lease=main:${expected_oid} github HEAD:main 2>&1
}

set +e
PUSH_OUTPUT="$(push_once "${REMOTE_MAIN_OID}")"
PUSH_EXIT=$?
set -e

if [[ "${PUSH_EXIT}" -ne 0 ]]; then
  CLASSIFICATION="$(github_publish_classify_git_error "${PUSH_OUTPUT}")"
  if [[ "${CLASSIFICATION}" == "lease_conflict" ]]; then
    echo "WARNING: GitHub main changed before push; refetching once and retrying." >&2
    set +e
    REFRESH_OUTPUT="$("${PUBLISH_TO_GITHUB_GIT_BIN}" -C "${TMP_DIR}" ls-remote --heads github refs/heads/main 2>&1)"
    REFRESH_EXIT=$?
    set -e
    if [[ "${REFRESH_EXIT}" -ne 0 ]]; then
      CLASSIFICATION="$(github_publish_classify_git_error "${REFRESH_OUTPUT}")"
      if [[ "${CLASSIFICATION}" == "outage" ]]; then
        outage_skip "${REFRESH_OUTPUT}"
      fi
      fail_publish "${CLASSIFICATION}" "ERROR: GitHub lease refresh failed (${CLASSIFICATION})." "${REFRESH_OUTPUT}"
    fi
    REMOTE_MAIN_OID="$(github_publish_extract_remote_oid "${REFRESH_OUTPUT}")"
    set +e
    PUSH_OUTPUT="$(push_once "${REMOTE_MAIN_OID}")"
    PUSH_EXIT=$?
    set -e
    if [[ "${PUSH_EXIT}" -eq 0 ]]; then
      [[ -n "${PUSH_OUTPUT}" ]] && echo "${PUSH_OUTPUT}"
      echo "PUBLISH_STATUS=success"
      write_status "success" "lease_retry" "${REMOTE_MAIN_OID}"
      exit 0
    fi
    CLASSIFICATION="$(github_publish_classify_git_error "${PUSH_OUTPUT}")"
    [[ "${CLASSIFICATION}" == "lease_conflict" ]] || CLASSIFICATION="unknown_error"
    fail_publish "${CLASSIFICATION}" "ERROR: GitHub force-with-lease retry failed (${CLASSIFICATION})." "${PUSH_OUTPUT}"
  fi

  if [[ "${CLASSIFICATION}" == "outage" ]]; then
    outage_skip "${PUSH_OUTPUT}"
  fi
  fail_publish "${CLASSIFICATION}" "ERROR: GitHub publish failed (${CLASSIFICATION})." "${PUSH_OUTPUT}"
fi

[[ -n "${PUSH_OUTPUT}" ]] && echo "${PUSH_OUTPUT}"
echo "PUBLISH_STATUS=success"
write_status "success" "success" "${REMOTE_MAIN_OID}"
