#!/usr/bin/env bash
# test_gatus_github_mirror.sh — Verify Gatus GitHub mirror endpoint and validate.sh exclusion.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

EXPECTED_SHA="0123456789abcdef0123456789abcdef01234567"

test_start "1" "generated config contains GitHub mirror endpoint shape"
GATUS_OUTPUT="$(
  GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${EXPECTED_SHA}" \
  "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh"
)"
if grep -q 'name: github-mirror-main' <<< "${GATUS_OUTPUT}" && \
   grep -q 'group: publishing' <<< "${GATUS_OUTPUT}" && \
   grep -q 'https://raw.githubusercontent.com/wuertele/mycofu/main/.mycofu-publish.json' <<< "${GATUS_OUTPUT}" && \
   grep -Fq "[BODY].source_commit == ${EXPECTED_SHA}" <<< "${GATUS_OUTPUT}" && \
   grep -q 'interval: 10m' <<< "${GATUS_OUTPUT}" && \
   grep -q 'failure-threshold: 3' <<< "${GATUS_OUTPUT}" && \
   grep -q 'success-threshold: 2' <<< "${GATUS_OUTPUT}"; then
  test_pass "endpoint URL, condition, group, interval, and thresholds are correct"
else
  test_fail "generated GitHub mirror endpoint shape is wrong"
fi

test_start "1b" "RHS literal is unquoted (issue #301 regression ratchet)"
# Gatus 5.x condition parser keeps quotes as part of the literal value, so a
# quoted RHS would never match the gjson-resolved LHS. If a future change
# re-quotes the SHA, this assertion fires.
if grep -Fq "[BODY].source_commit == \\\"${EXPECTED_SHA}\\\"" <<< "${GATUS_OUTPUT}"; then
  test_fail "RHS literal is quoted — Gatus comparison can never succeed (#301)"
else
  test_pass "RHS literal is unquoted"
fi

test_start "2" "no GitHub mirror endpoint is emitted without expected SHA"
GATUS_NO_SHA_OUTPUT="$("${REPO_ROOT}/framework/scripts/generate-gatus-config.sh")"
if ! grep -q 'github-mirror-main' <<< "${GATUS_NO_SHA_OUTPUT}"; then
  test_pass "endpoint is omitted when GATUS_GITHUB_EXPECTED_SOURCE_COMMIT is absent"
else
  test_fail "endpoint was emitted without an expected source commit"
fi

test_start "3" "validate.sh aggregate excludes publishing group"
if grep -Fq '!= \"publishing\"' "${REPO_ROOT}/framework/scripts/validate.sh" && \
   grep -Fq '[SKIP] Gatus publishing endpoints in aggregate - checked by GitHub mirror telemetry after publish' "${REPO_ROOT}/framework/scripts/validate.sh"; then
  test_pass "validate.sh excludes publishing and emits the informational skip"
else
  test_fail "validate.sh does not exclude publishing endpoints from aggregate"
fi

test_start "4" "failed publishing endpoint does not fail aggregate fixture"
FIXTURE_JSON='[
  {"name":"github-mirror-main","group":"publishing","results":[{"success":false}]},
  {"name":"gitlab","group":"services","results":[{"success":true}]},
  {"name":"vault-prod","group":"secrets","results":[{"success":true}]}
]'
TOTAL="$(jq '[.[] | select((.group // "") != "certificates" and (.group // "") != "publishing")] | length' <<< "${FIXTURE_JSON}")"
HEALTHY="$(jq '[.[] | select((.group // "") != "certificates" and (.group // "") != "publishing" and .results[-1].success == true)] | length' <<< "${FIXTURE_JSON}")"
if [[ "${TOTAL}" == "2" && "${HEALTHY}" == "2" ]]; then
  test_pass "unhealthy publishing endpoint is ignored by aggregate math"
else
  test_fail "publishing endpoint affected aggregate health math"
fi

test_start "5" "ordinary failed endpoint still fails aggregate fixture"
ORDINARY_FAIL_JSON='[
  {"name":"github-mirror-main","group":"publishing","results":[{"success":false}]},
  {"name":"gitlab","group":"services","results":[{"success":false}]},
  {"name":"vault-prod","group":"secrets","results":[{"success":true}]}
]'
TOTAL="$(jq '[.[] | select((.group // "") != "certificates" and (.group // "") != "publishing")] | length' <<< "${ORDINARY_FAIL_JSON}")"
HEALTHY="$(jq '[.[] | select((.group // "") != "certificates" and (.group // "") != "publishing" and .results[-1].success == true)] | length' <<< "${ORDINARY_FAIL_JSON}")"
if [[ "${TOTAL}" == "2" && "${HEALTHY}" == "1" ]]; then
  test_pass "ordinary unhealthy groups still affect aggregate health"
else
  test_fail "ordinary unhealthy endpoint was incorrectly excluded"
fi

test_start "6" "rebuild-cluster.sh preserves GitHub mirror endpoint during prod Gatus regeneration"
if grep -Fq 'resolve_gatus_expected_source_commit' "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" && \
   grep -Fq 'refs/remotes/gitlab/prod^{commit}' "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" && \
   grep -Fq 'GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${GATUS_EXPECTED_SOURCE_COMMIT}"' "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" && \
   grep -Fq 'generate-gatus-config.sh" > "${REPO_DIR}/site/gatus/config.yaml"' "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"; then
  test_pass "workstation rebuild supplies a source SHA when regenerating Gatus config"
else
  test_fail "workstation rebuild can regenerate Gatus without the GitHub mirror source SHA"
fi

runner_summary
