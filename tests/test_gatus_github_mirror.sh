#!/usr/bin/env bash
# test_gatus_github_mirror.sh — Verify Gatus GitHub mirror endpoint and validate.sh exclusion.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

EXPECTED_SHA="0123456789abcdef0123456789abcdef01234567"

test_start "1" "generated config contains GitHub mirror endpoint shape"
# #718: the SHA-injection seam is now reachable only behind --allow-test-seams.
# This case needs a known SHA to assert the endpoint's shape, so it declares the
# seam explicitly at the call site.
GATUS_OUTPUT="$(
  GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${EXPECTED_SHA}" \
  "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" --allow-test-seams
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

test_start "2" "auto-resolves prod tip when env var is absent (issue #528)"
# Before #528: callers set GATUS_GITHUB_EXPECTED_SOURCE_COMMIT explicitly
# and the endpoint was omitted when they didn't. That's why CI leaked
# $CI_COMMIT_SHA — the env var was load-bearing. Post-fix: when publish
# is opted in, generate-gatus-config.sh derives the SHA via the shared
# resolver (github-publish-lib.sh:resolve_gatus_expected_source_commit),
# and the endpoint is emitted with the prod tip.
GATUS_AUTO_OUTPUT="$("${REPO_ROOT}/framework/scripts/generate-gatus-config.sh")"
EXPECTED_PROD_SHA="$(git -C "${REPO_ROOT}" rev-parse refs/remotes/gitlab/prod 2>/dev/null \
  || git -C "${REPO_ROOT}" rev-parse refs/remotes/origin/prod 2>/dev/null \
  || git -C "${REPO_ROOT}" ls-remote origin refs/heads/prod 2>/dev/null | awk '{print $1; exit}')"
if grep -q 'name: github-mirror-main' <<< "${GATUS_AUTO_OUTPUT}" && \
   [[ -n "${EXPECTED_PROD_SHA}" ]] && \
   grep -Fq "[BODY].source_commit == ${EXPECTED_PROD_SHA}" <<< "${GATUS_AUTO_OUTPUT}"; then
  test_pass "endpoint is emitted with the auto-resolved prod tip"
else
  test_fail "auto-resolver did not embed the prod tip in the endpoint"
fi

test_start "2b" "empty SHA plus disabled publish: endpoint omitted (downstream-adopter shape)"
# Independent of #528 — downstream adopters may disable publishing.
# The endpoint must not appear in that case, even though the resolver
# would otherwise be exercised by the auto-derive path.
DISABLED_CFG="$(mktemp -d "${TMPDIR:-/tmp}/gatus-mirror-disabled.XXXXXX")"
trap 'rm -rf "${DISABLED_CFG}"' EXIT
cp "${REPO_ROOT}/site/config.yaml" "${DISABLED_CFG}/config.yaml"
yq -i '.publish.github.enabled = false' "${DISABLED_CFG}/config.yaml"
yq -i 'del(.github)' "${DISABLED_CFG}/config.yaml"
GATUS_DISABLED_OUTPUT="$("${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" "${DISABLED_CFG}/config.yaml")"
if ! grep -q 'github-mirror-main' <<< "${GATUS_DISABLED_OUTPUT}"; then
  test_pass "endpoint omitted when publish is disabled"
else
  test_fail "endpoint emitted when publish is disabled"
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
# Issue #528 + #701: the resolver lives in github-publish-lib.sh and is called
# in exactly ONE place — generate-gatus-config.sh's internal opt-in path.
# rebuild-cluster.sh defers resolution to that single authority (like the CI
# build:merge job and safe-apply.sh). #701 removed the earlier unconditional
# pre-resolve here, which died on a downstream cluster with
# publish.github.enabled=false even though no github-mirror endpoint is
# emitted. The github-mirror endpoint is still produced whenever publishing is
# opted in, because generate-gatus-config.sh resolves prod's tip itself.
#
# rebuild-cluster.sh is a workstation path, so it follows safe-apply.sh's
# write safety rather than CI build:merge's bare redirect:
#   - env-scrubs the resolver's test-only seams. #718 NOTE: this call-site
#     scrub is no longer what carries that property — generate-gatus-config.sh
#     clears the seams itself unless invoked with --allow-test-seams, for every
#     caller. The `env -u` here is redundant defence-in-depth on the DR path,
#     and the grep below pins it only so it is not dropped silently; a new
#     caller does not need to copy it (see #913),
#   - generates to a same-dir temp and atomically mv's on success (#706),
#   - fails closed on empty output via -s (#704).
# The negative greps keep the #528/#701 teeth: no injected SHA assignment
# (`GATUS_GITHUB_EXPECTED_SOURCE_COMMIT=`) — the `env -u` scrub has no `=`, so
# it is permitted — and no local pre-resolve/redefinition of the resolver.
REBUILD="${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"
if grep -Fq 'refs/remotes/gitlab/prod^{commit}' "${REPO_ROOT}/framework/scripts/github-publish-lib.sh" && \
   grep -Fq 'env -u GATUS_GITHUB_EXPECTED_SOURCE_COMMIT' "${REBUILD}" && \
   grep -Fq '"${SCRIPT_DIR}/generate-gatus-config.sh" > "${GATUS_CONFIG_TMP}"' "${REBUILD}" && \
   grep -Fq 'mv -f "${GATUS_CONFIG_TMP}" "${REPO_DIR}/site/gatus/config.yaml"' "${REBUILD}" && \
   grep -Fq '[[ ! -s "${GATUS_CONFIG_TMP}" ]]' "${REBUILD}" && \
   ! grep -Fq 'GATUS_GITHUB_EXPECTED_SOURCE_COMMIT=' "${REBUILD}" && \
   ! grep -Fq 'resolve_gatus_expected_source_commit' "${REBUILD}"; then
  test_pass "workstation rebuild defers to the single resolver and writes the config atomically + fail-closed"
else
  test_fail "workstation rebuild does not use the env-scrubbed, atomic, fail-closed generate-gatus-config.sh invocation"
fi

runner_summary
