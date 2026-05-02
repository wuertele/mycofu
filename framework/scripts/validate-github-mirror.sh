#!/usr/bin/env bash
# validate-github-mirror.sh — Compare public GitHub mirror metadata to prod SHA.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${VALIDATE_GITHUB_MIRROR_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
CONFIG_FILE="${VALIDATE_GITHUB_MIRROR_CONFIG_FILE:-${REPO_DIR}/site/config.yaml}"
GATUS_CONFIG_PATH="${VALIDATE_GITHUB_MIRROR_GATUS_CONFIG_PATH:-/run/secrets/gatus/config.yaml}"
CURL_BIN="${VALIDATE_GITHUB_MIRROR_CURL_BIN:-curl}"
GIT_BIN="${VALIDATE_GITHUB_MIRROR_GIT_BIN:-git}"
JQ_BIN="${VALIDATE_GITHUB_MIRROR_JQ_BIN:-jq}"
YQ_BIN="${VALIDATE_GITHUB_MIRROR_YQ_BIN:-yq}"
SSH_BIN="${VALIDATE_GITHUB_MIRROR_SSH_BIN:-ssh}"

source "${SCRIPT_DIR}/github-publish-lib.sh"

CHECK_GATUS_CONFIG=0
EXPECTED_SHA=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--expected-sha <sha>] [--check-gatus-config]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --expected-sha)
      EXPECTED_SHA="${2:-}"
      [[ -n "${EXPECTED_SHA}" ]] || { echo "ERROR: --expected-sha requires a value" >&2; exit 1; }
      shift 2
      ;;
    --check-gatus-config)
      CHECK_GATUS_CONFIG=1
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

resolve_expected_sha() {
  if [[ -n "${EXPECTED_SHA}" ]]; then
    printf '%s\n' "${EXPECTED_SHA}"
  elif [[ -n "${CI_COMMIT_SHA:-}" ]]; then
    printf '%s\n' "${CI_COMMIT_SHA}"
  else
    "${GIT_BIN}" -C "${REPO_DIR}" rev-parse refs/remotes/gitlab/prod
  fi
}

extract_gatus_expected_sha() {
  # Issue #301: a quoted RHS literal (`source_commit == "abc..."`) makes
  # Gatus 5.x compare the quoted string against the unquoted jsonpath
  # result, which can never match. The validator's job is to catch drift,
  # so we detect that form explicitly and exit 12 — the caller surfaces
  # a #301 diagnostic instead of silently accepting a deployed config
  # whose check will stay red forever. The unquoted form is parsed by
  # trimming the YAML closing quote (and anything after) from the bare
  # 40-char hex SHA.
  awk '
    $0 ~ /^[[:space:]]*-[[:space:]]*name:[[:space:]]*github-mirror-main[[:space:]]*$/ { in_endpoint=1; next }
    in_endpoint && $0 ~ /^[[:space:]]*-[[:space:]]*name:/ { in_endpoint=0 }
    in_endpoint && $0 ~ /\[BODY\]\.source_commit[[:space:]]*==/ {
      line=$0
      sub(/^.*==[[:space:]]*/, "", line)
      if (line ~ /^["\\]/) { legacy_quoted=1; exit }
      sub(/[^0-9a-fA-F].*$/, "", line)
      if (length(line) == 40) {
        print line
        found=1
        exit
      }
    }
    END {
      if (legacy_quoted) exit 12
      if (!found) exit 11
    }
  '
}

PUBLISH_GITHUB_ENABLED="$("${YQ_BIN}" -r '.publish.github.enabled // false' "${CONFIG_FILE}")"
if [[ "${PUBLISH_GITHUB_ENABLED}" != "true" ]]; then
  # Issue #294: when publish.github.enabled is false, the framework does not
  # publish a public mirror, the Gatus config does not emit github-mirror-main,
  # and there is nothing to compare against. Exit cleanly so callers
  # (validate.sh, manual operator runs) treat publish-disabled sites as a
  # pass rather than a missing-endpoint warning.
  echo "publish.github.enabled is not true in ${CONFIG_FILE}; skipping mirror check." >&2
  exit 0
fi

EXPECTED_SHA="$(resolve_expected_sha)"
if [[ -z "${EXPECTED_SHA}" || ! "${EXPECTED_SHA}" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "ERROR: expected SHA must be a full 40-character commit SHA: ${EXPECTED_SHA}" >&2
  exit 1
fi

REMOTE_URL="$("${YQ_BIN}" -r '.github.remote_url // ""' "${CONFIG_FILE}")"
RAW_METADATA_URL="$(github_remote_to_raw_metadata_url "${REMOTE_URL}")"

if [[ "${CHECK_GATUS_CONFIG}" -eq 1 ]]; then
  GATUS_IP="$("${YQ_BIN}" -r '.vms.gatus.ip // ""' "${CONFIG_FILE}")"
  if [[ -z "${GATUS_IP}" || "${GATUS_IP}" == "null" ]]; then
    echo "ERROR: vms.gatus.ip missing from ${CONFIG_FILE}" >&2
    exit 1
  fi

  set +e
  GATUS_CONFIG="$("${SSH_BIN}" -n -o BatchMode=yes -o ConnectTimeout=5 "root@${GATUS_IP}" "cat ${GATUS_CONFIG_PATH}" 2>&1)"
  SSH_EXIT=$?
  set -e
  if [[ "${SSH_EXIT}" -ne 0 ]]; then
    echo "ERROR: failed to read deployed Gatus config at ${GATUS_CONFIG_PATH}: ${GATUS_CONFIG}" >&2
    exit 1
  fi

  set +e
  GATUS_EXPECTED_SHA="$(printf '%s\n' "${GATUS_CONFIG}" | extract_gatus_expected_sha 2>/dev/null)"
  PARSE_EXIT=$?
  set -e
  if [[ "${PARSE_EXIT}" -eq 11 ]]; then
    echo "ERROR: Gatus config has no github-mirror-main endpoint; generate-gatus-config.sh did not emit one (was GATUS_GITHUB_EXPECTED_SOURCE_COMMIT set?)." >&2
    exit 11
  elif [[ "${PARSE_EXIT}" -eq 12 ]]; then
    echo "ERROR: Gatus config has a quoted RHS literal in the github-mirror-main condition (issue #301). Gatus 5.x keeps quotes as part of the literal so the comparison can never match — the deployed check will stay red. Regenerate with the current generate-gatus-config.sh." >&2
    exit 12
  elif [[ "${PARSE_EXIT}" -ne 0 || -z "${GATUS_EXPECTED_SHA}" ]]; then
    echo "ERROR: could not parse github-mirror-main source_commit from Gatus config." >&2
    exit 1
  fi

  if [[ "${GATUS_EXPECTED_SHA}" == "${EXPECTED_SHA}" ]]; then
    echo "Gatus publishing endpoint config matches prod tip ${EXPECTED_SHA}"
    exit 0
  fi

  echo "WARN: Gatus expected_sha is ${GATUS_EXPECTED_SHA} but prod tip is ${EXPECTED_SHA}; Gatus recreation may have lagged. Distinct from publish failure." >&2
  exit 10
fi

set +e
METADATA="$("${CURL_BIN}" -fsSL "${RAW_METADATA_URL}" 2>&1)"
CURL_EXIT=$?
set -e
if [[ "${CURL_EXIT}" -ne 0 ]]; then
  echo "ERROR: failed to fetch GitHub publish metadata from ${RAW_METADATA_URL}: ${METADATA}" >&2
  exit 1
fi

if ! printf '%s' "${METADATA}" | "${JQ_BIN}" -e '.schema == 1 and (.source_commit | type == "string")' >/dev/null 2>&1; then
  echo "ERROR: GitHub publish metadata is missing or invalid JSON." >&2
  exit 1
fi

MIRROR_SHA="$(printf '%s' "${METADATA}" | "${JQ_BIN}" -r '.source_commit')"
if [[ "${MIRROR_SHA}" == "${EXPECTED_SHA}" ]]; then
  echo "GitHub mirror matches expected source_commit ${EXPECTED_SHA}"
  exit 0
fi

echo "ERROR: GitHub mirror source_commit ${MIRROR_SHA} does not match expected prod SHA ${EXPECTED_SHA}." >&2
exit 1
