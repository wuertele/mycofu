#!/usr/bin/env bash
# get-deployed-image-hashes.sh — Print image filenames referenced by the latest
# successful build:image jobs on dev and prod branches.
#
# Used by off-hot-path image reclaim so a scheduled cleanup cannot delete
# images that are still referenced by a deployed environment.
#
# Usage:
#   get-deployed-image-hashes.sh --role <role> [--ref <ref>]... [--job <name>] [--strict]
#
# Output: one filename per line (e.g., dns-a3f82c1d.img). Empty if no
# successful pipeline yet exists for any requested ref.
#
# Job name resolution:
#   --job <name>                          — explicit job name (highest)
#   MYCOFU_UPLOAD_HELPER_JOB_NAME env var — caller-set default
#   "build:image: [<role>]"               — fallback for parallel:matrix
#   "build:image:<role>"                  — fallback for standalone jobs
#                                           (e.g., hil-boot)
#
# The fallback path tries the matrix form first, then the standalone form
# if the matrix form returns 404. This means callers normally don't need
# to set --job at all; setting it just skips the fallback ladder.
#
# Authentication (in order of preference):
#   1. CI_JOB_TOKEN  (set automatically in GitLab CI jobs)
#   2. GITLAB_TOKEN  (workstation: export from a personal access token)
#
# If no auth is available the script prints a warning to stderr and exits 0
# with empty output unless --strict is set.
#
# Environment overrides (mostly for tests):
#   CI_PROJECT_ID                — GitLab numeric project id
#   MYCOFU_GITLAB_PROJECT_ID     — workstation fallback for project id
#   MYCOFU_GITLAB_URL            — override the GitLab base URL
#   MYCOFU_GITLAB_CURL           — alternate curl-shaped command (for tests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${MYCOFU_CONFIG_YAML:-${REPO_DIR}/site/config.yaml}"

ROLE=""
REFS=()
JOB_NAME_OVERRIDE="${MYCOFU_UPLOAD_HELPER_JOB_NAME:-}"
STRICT=0

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE="$2"; shift 2 ;;
    --ref)  REFS+=("$2"); shift 2 ;;
    --job)  JOB_NAME_OVERRIDE="$2"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ROLE" ]]; then
  echo "ERROR: --role is required" >&2
  exit 2
fi

if [[ ${#REFS[@]} -eq 0 ]]; then
  REFS=(dev prod)
fi

# --- authentication ---
AUTH_HEADER=""
if [[ -n "${CI_JOB_TOKEN:-}" ]]; then
  AUTH_HEADER="Job-Token: ${CI_JOB_TOKEN}"
elif [[ -n "${GITLAB_TOKEN:-}" ]]; then
  AUTH_HEADER="Private-Token: ${GITLAB_TOKEN}"
else
  if [[ "$STRICT" -eq 1 ]]; then
    echo "ERROR: No GitLab auth (CI_JOB_TOKEN/GITLAB_TOKEN); deployed image set cannot be verified" >&2
    exit 1
  else
    echo "WARN: No GitLab auth (CI_JOB_TOKEN/GITLAB_TOKEN); deployed-hash whitelist disabled" >&2
    exit 0
  fi
fi

# --- target endpoint ---
if [[ -n "${MYCOFU_GITLAB_URL:-}" ]]; then
  GITLAB_URL="${MYCOFU_GITLAB_URL}"
else
  if [[ ! -f "$CONFIG" ]]; then
    if [[ "$STRICT" -eq 1 ]]; then
      echo "ERROR: config not found at ${CONFIG}; deployed image set cannot be verified" >&2
      exit 1
    else
      echo "WARN: config not found at ${CONFIG}; whitelist disabled" >&2
      exit 0
    fi
  fi
  BASE_DOMAIN=$(yq -r '.domain' "$CONFIG")
  if [[ -z "$BASE_DOMAIN" || "$BASE_DOMAIN" == "null" ]]; then
    if [[ "$STRICT" -eq 1 ]]; then
      echo "ERROR: domain not set in ${CONFIG}; deployed image set cannot be verified" >&2
      exit 1
    else
      echo "WARN: domain not set in ${CONFIG}; whitelist disabled" >&2
      exit 0
    fi
  fi
  GITLAB_URL="https://gitlab.prod.${BASE_DOMAIN}"
fi

PROJECT_ID="${CI_PROJECT_ID:-${MYCOFU_GITLAB_PROJECT_ID:-}}"
if [[ -z "$PROJECT_ID" ]]; then
  if [[ "$STRICT" -eq 1 ]]; then
    echo "ERROR: CI_PROJECT_ID / MYCOFU_GITLAB_PROJECT_ID not set; deployed image set cannot be verified" >&2
    exit 1
  else
    echo "WARN: CI_PROJECT_ID / MYCOFU_GITLAB_PROJECT_ID not set; whitelist disabled" >&2
    exit 0
  fi
fi

CURL="${MYCOFU_GITLAB_CURL:-curl}"

# URL-encode a string (used for parallel:matrix job names like "build:image: [acme-dev]").
url_encode() {
  printf '%s' "$1" | jq -sRr @uri
}

ARTIFACT_PATH="build/image-versions/${ROLE}.tfvars-fragment"

# Print only "<role>-<hash>.img" filenames from $1. Anchored to ROLE so a
# future fragment-format change cannot inject unrelated filenames.
extract_filenames() {
  grep -oE "\"${ROLE}-[a-z0-9]+\.img\"" "$1" | tr -d '"'
}

# Job name candidates to try (in order). First HTTP 200 wins.
if [[ -n "$JOB_NAME_OVERRIDE" ]]; then
  JOB_CANDIDATES=("$JOB_NAME_OVERRIDE")
else
  JOB_CANDIDATES=(
    "build:image: [${ROLE}]"
    "build:image:${ROLE}"
  )
fi

fetch_one_ref() {
  local ref="$1" tmp http_code job
  for job in "${JOB_CANDIDATES[@]}"; do
    tmp=$(mktemp)
    local encoded url
    encoded=$(url_encode "$job")
    url="${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/jobs/artifacts/${ref}/raw/${ARTIFACT_PATH}?job=${encoded}"
    http_code=$("$CURL" -sk -o "$tmp" -w '%{http_code}' \
      -H "${AUTH_HEADER}" "$url" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" && -s "$tmp" ]]; then
      extract_filenames "$tmp" || true
      rm -f "$tmp"
      return 0
    fi
    rm -f "$tmp"
  done
  echo "INFO: No artifact for ${ROLE} on ref ${ref} (tried jobs: ${JOB_CANDIDATES[*]})" >&2
  return 1
}

RESULT_TMP="$(mktemp)"
FETCH_FAILURES=0
for REF in "${REFS[@]}"; do
  if ! fetch_one_ref "$REF" >> "$RESULT_TMP"; then
    FETCH_FAILURES=$((FETCH_FAILURES + 1))
  fi
done

if [[ "$STRICT" -eq 1 && "$FETCH_FAILURES" -gt 0 ]]; then
  rm -f "$RESULT_TMP"
  echo "ERROR: failed to fetch deployed image artifact for ${FETCH_FAILURES} ref(s)" >&2
  exit 1
fi

sort -u "$RESULT_TMP"
RESULT_COUNT="$(sed '/^$/d' "$RESULT_TMP" | wc -l | tr -d ' ')"
rm -f "$RESULT_TMP"

if [[ "$STRICT" -eq 1 && "$RESULT_COUNT" -eq 0 ]]; then
  echo "ERROR: strict deployed image query returned no filenames for role ${ROLE}" >&2
  exit 1
fi
