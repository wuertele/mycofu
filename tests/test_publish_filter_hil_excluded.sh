#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REAL_GIT="$(command -v git)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

WORK_DIR="${TMP_DIR}/repo"
ARCHIVE_DIR="${TMP_DIR}/archive"

"$REAL_GIT" init "$WORK_DIR" >/dev/null
"$REAL_GIT" -C "$WORK_DIR" config user.name "Publish Filter Test"
"$REAL_GIT" -C "$WORK_DIR" config user.email "test@example.com"

mkdir -p \
  "${WORK_DIR}/framework/scripts" \
  "${WORK_DIR}/tests/hil/bfnet" \
  "${WORK_DIR}/tests/unit" \
  "${WORK_DIR}/docs/reviews"
printf 'framework\n' > "${WORK_DIR}/framework/scripts/tool.sh"
printf 'hil ci\n' > "${WORK_DIR}/tests/hil/.gitlab-ci-hil.yml"
printf 'private hil\n' > "${WORK_DIR}/tests/hil/bfnet/config.yaml"
printf 'regreening\n' > "${WORK_DIR}/tests/hil/bfnet/REGREENING.md"
printf 'public test\n' > "${WORK_DIR}/tests/unit/public.sh"
printf 'review\n' > "${WORK_DIR}/docs/reviews/public.md"
printf '# readme\n' > "${WORK_DIR}/README.md"
printf '{}\n' > "${WORK_DIR}/flake.nix"
printf 'lock\n' > "${WORK_DIR}/flake.lock"

"$REAL_GIT" -C "$WORK_DIR" add -A
"$REAL_GIT" -C "$WORK_DIR" commit -m "fixture" >/dev/null

PUBLISH_FILTER_REPO_DIR="$WORK_DIR"
PUBLISH_FILTER_GIT_BIN="$REAL_GIT"
source "${REPO_ROOT}/framework/scripts/publish-filter.sh"

test_start "s034.6.1" "publish path predicate rejects tests/hil"
if ! publish_filter_path_allowed "tests/hil/.gitlab-ci-hil.yml" && \
   ! publish_filter_path_allowed "tests/hil/bfnet/config.yaml" && \
   ! publish_filter_path_allowed "tests/hil/bfnet/REGREENING.md" && \
   publish_filter_path_allowed "tests/unit/public.sh"; then
  test_pass "tests/hil files denied while other tests stay allowed"
else
  test_fail "publish_filter_path_allowed did not handle tests/hil correctly"
fi

test_start "s034.6.2" "publish archive excludes tests/hil"
publish_filter_archive HEAD "$ARCHIVE_DIR"
if [[ ! -e "${ARCHIVE_DIR}/tests/hil" ]] && \
   [[ -e "${ARCHIVE_DIR}/tests/unit/public.sh" ]] && \
   publish_filter_verify "$ARCHIVE_DIR" >/dev/null 2>&1; then
  test_pass "archive excludes HIL CI/runbook files and keeps non-HIL tests"
else
  test_fail "archive leaked tests/hil or dropped public tests"
  find "$ARCHIVE_DIR" -maxdepth 4 -type f | sort >&2 || true
fi

runner_summary
