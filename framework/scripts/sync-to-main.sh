#!/usr/bin/env bash
# sync-to-main.sh — Publish the filtered prod tree to the github remote.
#
# Usage:
#   framework/scripts/sync-to-main.sh
#   framework/scripts/sync-to-main.sh --force-unvalidated

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SYNC_TO_MAIN_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
SYNC_TO_MAIN_GIT_BIN="${SYNC_TO_MAIN_GIT_BIN:-git}"
SYNC_TO_MAIN_CURL_BIN="${SYNC_TO_MAIN_CURL_BIN:-curl}"
SYNC_TO_MAIN_JQ_BIN="${SYNC_TO_MAIN_JQ_BIN:-jq}"
SYNC_TO_MAIN_YQ_BIN="${SYNC_TO_MAIN_YQ_BIN:-yq}"
SYNC_TO_MAIN_SOPS_BIN="${SYNC_TO_MAIN_SOPS_BIN:-sops}"
SYNC_TO_MAIN_CONFIG_FILE="${SYNC_TO_MAIN_CONFIG_FILE:-${REPO_DIR}/site/config.yaml}"
SYNC_TO_MAIN_SECRETS_FILE="${SYNC_TO_MAIN_SECRETS_FILE:-${REPO_DIR}/site/sops/secrets.yaml}"
SYNC_TO_MAIN_GITLAB_PROJECT_ID="${SYNC_TO_MAIN_GITLAB_PROJECT_ID:-1}"
FORCE_UNVALIDATED=0

PUBLISH_FILTER_REPO_DIR="${REPO_DIR}"
PUBLISH_FILTER_GIT_BIN="${SYNC_TO_MAIN_GIT_BIN}"
source "${SCRIPT_DIR}/publish-filter.sh"
source "${SCRIPT_DIR}/github-publish-lib.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--force-unvalidated]

Publishes the filtered contents of gitlab/prod to the github remote's main branch.
By default the script verifies that the prod HEAD commit has a passing GitLab
pipeline before publishing.

Options:
  --force-unvalidated  Publish even if GitLab pipeline verification fails
  -h, --help           Show this help text
EOF
}

require_tool() {
  local tool_path="$1"
  local tool_name="$2"

  if ! command -v "$tool_path" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: ${tool_name}" >&2
    exit 1
  fi
}

verify_prod_pipeline() {
  local prod_sha="$1"
  local gitlab_ip=""
  local gitlab_password=""
  local oauth_json=""
  local oauth_token=""
  local pipelines_json=""
  local success_pipeline_id=""

  require_tool "${SYNC_TO_MAIN_CURL_BIN}" "curl"
  require_tool "${SYNC_TO_MAIN_JQ_BIN}" "jq"
  require_tool "${SYNC_TO_MAIN_YQ_BIN}" "yq"
  require_tool "${SYNC_TO_MAIN_SOPS_BIN}" "sops"

  gitlab_ip="$("${SYNC_TO_MAIN_YQ_BIN}" -r '.vms.gitlab.ip // ""' "${SYNC_TO_MAIN_CONFIG_FILE}")"
  if [[ -z "${gitlab_ip}" || "${gitlab_ip}" == "null" ]]; then
    echo "ERROR: Could not read vms.gitlab.ip from ${SYNC_TO_MAIN_CONFIG_FILE}" >&2
    return 1
  fi

  gitlab_password="$("${SYNC_TO_MAIN_SOPS_BIN}" -d --extract '["gitlab_root_password"]' "${SYNC_TO_MAIN_SECRETS_FILE}" 2>/dev/null || true)"
  if [[ -z "${gitlab_password}" || "${gitlab_password}" == "null" ]]; then
    echo "ERROR: Could not read gitlab_root_password from ${SYNC_TO_MAIN_SECRETS_FILE}" >&2
    return 1
  fi

  oauth_json="$(
    "${SYNC_TO_MAIN_CURL_BIN}" -sk -X POST "https://${gitlab_ip}/oauth/token" \
      -d "grant_type=password&username=root&password=${gitlab_password}" 2>/dev/null || true
  )"
  oauth_token="$(printf '%s' "${oauth_json}" | "${SYNC_TO_MAIN_JQ_BIN}" -r '.access_token // ""' 2>/dev/null || true)"
  if [[ -z "${oauth_token}" ]]; then
    echo "ERROR: Could not authenticate to the GitLab API at https://${gitlab_ip}" >&2
    return 1
  fi

  pipelines_json="$(
    "${SYNC_TO_MAIN_CURL_BIN}" -sk \
      "https://${gitlab_ip}/api/v4/projects/${SYNC_TO_MAIN_GITLAB_PROJECT_ID}/pipelines?ref=prod&sha=${prod_sha}&per_page=50" \
      -H "Authorization: Bearer ${oauth_token}" 2>/dev/null || true
  )"
  success_pipeline_id="$(
    printf '%s' "${pipelines_json}" \
      | "${SYNC_TO_MAIN_JQ_BIN}" -r 'map(select(.status == "success")) | .[0].id // ""' 2>/dev/null || true
  )"

  if [[ -z "${success_pipeline_id}" ]]; then
    echo "ERROR: prod commit ${prod_sha} has no passing pipeline. Publishing unvalidated code to GitHub is not allowed." >&2
    return 1
  fi

  echo "Verified GitLab pipeline #${success_pipeline_id} for prod commit ${prod_sha}"
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-unvalidated)
      FORCE_UNVALIDATED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

require_tool "${SYNC_TO_MAIN_GIT_BIN}" "git"

if ! "${SYNC_TO_MAIN_GIT_BIN}" -C "${REPO_DIR}" remote get-url github >/dev/null 2>&1; then
  echo "ERROR: Git remote 'github' is not configured in ${REPO_DIR}" >&2
  exit 1
fi

echo "Fetching gitlab/prod..."
"${SYNC_TO_MAIN_GIT_BIN}" -C "${REPO_DIR}" fetch gitlab prod >/dev/null

PROD_REF="refs/remotes/gitlab/prod"
PROD_SHA_FULL="$("${SYNC_TO_MAIN_GIT_BIN}" -C "${REPO_DIR}" rev-parse --verify "${PROD_REF}")"
PROD_SHA="$("${SYNC_TO_MAIN_GIT_BIN}" -C "${REPO_DIR}" rev-parse --verify --short=12 "${PROD_REF}")"
PROD_SUBJECT="$("${SYNC_TO_MAIN_GIT_BIN}" -C "${REPO_DIR}" log -1 --format=%s "${PROD_REF}")"

if [[ "${FORCE_UNVALIDATED}" -eq 1 ]]; then
  echo "WARNING: Skipping GitLab pipeline verification for prod commit ${PROD_SHA} (--force-unvalidated)"
else
  verify_prod_pipeline "${PROD_SHA_FULL}"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sync-to-main.XXXXXX")"
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

publish_filter_archive "${PROD_REF}" "${TMP_DIR}"
publish_filter_verify "${TMP_DIR}"
github_publish_write_metadata "${TMP_DIR}" "${PROD_SHA_FULL}" "sync-to-main.sh"
publish_filter_verify "${TMP_DIR}"

"${SYNC_TO_MAIN_GIT_BIN}" -C "${TMP_DIR}" init >/dev/null
"${SYNC_TO_MAIN_GIT_BIN}" -C "${TMP_DIR}" config user.name "Mycofu Publish Bot"
"${SYNC_TO_MAIN_GIT_BIN}" -C "${TMP_DIR}" config user.email "publish@mycofu.invalid"
"${SYNC_TO_MAIN_GIT_BIN}" -C "${TMP_DIR}" add -A
"${SYNC_TO_MAIN_GIT_BIN}" -C "${TMP_DIR}" commit -m "publish: sync from prod ${PROD_SHA}" -m "${PROD_SUBJECT}" >/dev/null
"${SYNC_TO_MAIN_GIT_BIN}" -C "${TMP_DIR}" remote add github "$("${SYNC_TO_MAIN_GIT_BIN}" -C "${REPO_DIR}" remote get-url github)"

REMOTE_MAIN="$("${SYNC_TO_MAIN_GIT_BIN}" -C "${TMP_DIR}" ls-remote --heads github refs/heads/main)"
REMOTE_MAIN_OID="$(printf '%s\n' "${REMOTE_MAIN}" | awk 'NF { print $1; exit }')"

if [[ -n "${REMOTE_MAIN_OID}" ]]; then
  "${SYNC_TO_MAIN_GIT_BIN}" -C "${TMP_DIR}" fetch --depth=1 github refs/heads/main:refs/remotes/github/main >/dev/null
  if ! github_publish_metadata_present "${SYNC_TO_MAIN_GIT_BIN}" "${TMP_DIR}" "refs/remotes/github/main"; then
    github_publish_initial_rewrite_guard
  fi
else
  github_publish_initial_rewrite_guard
fi

echo "Pushing filtered prod tree to github/main..."
"${SYNC_TO_MAIN_GIT_BIN}" -C "${TMP_DIR}" push --force-with-lease=main:${REMOTE_MAIN_OID} github HEAD:main

echo "Published prod commit ${PROD_SHA} to github/main"
