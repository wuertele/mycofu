#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"

source "${REPO_ROOT}/tests/lib/runner.sh"

job_value() {
  local job_name="$1"
  local expr="$2"

  yq -r ".\"${job_name}\"${expr}" "${CI_FILE}" 2>/dev/null || true
}

test_start "3.4" "control-plane stages are present in the pipeline"
STAGES_OUTPUT="$(yq -r '.stages[]' "${CI_FILE}" 2>/dev/null || true)"
if grep -qx 'prepare-heavy' <<< "${STAGES_OUTPUT}" && \
   grep -qx 'deploy-control-plane-dev' <<< "${STAGES_OUTPUT}" && \
   grep -qx 'deploy-control-plane-prod' <<< "${STAGES_OUTPUT}"; then
  test_pass "prepare-heavy and deploy-control-plane stages are present"
else
  test_fail "prepare-heavy and deploy-control-plane stages are present"
fi

test_start "3.4pre" "cicd storage preparation runs before heavy HIL builds"
PREP_SCRIPT="$(job_value 'prepare:cicd-storage' '.script[]')"
PREP_RULES="$(job_value 'prepare:cicd-storage' '.rules[].if')"
PREP_RETRY="$(job_value 'prepare:cicd-storage' '.retry.when[]')"
HIL_PREP_NEED="$(job_value 'build:image:hil-boot' '.needs[] | select(.job == "prepare:cicd-storage") | [.artifacts, .optional] | @tsv')"
MERGE_PREP_NEED="$(job_value 'build:merge' '.needs[] | select(.job == "prepare:cicd-storage") | [.artifacts, .optional] | @tsv')"
if [[ "$(job_value 'prepare:cicd-storage' '.stage')" == "prepare-heavy" ]] && \
   [[ "$(job_value 'prepare:cicd-storage' '.dependencies | length')" == "0" ]] && \
   grep -q 'deploy-control-plane.sh dev --ensure-cicd-storage-only' <<< "${PREP_SCRIPT}" && \
   grep -q 'deploy-control-plane.sh prod --ensure-cicd-storage-only' <<< "${PREP_SCRIPT}" && \
   grep -qx '$CI_PIPELINE_SOURCE != "web" && $CI_COMMIT_BRANCH == "dev"' <<< "${PREP_RULES}" && \
   grep -qx '$CI_PIPELINE_SOURCE != "web" && $CI_COMMIT_BRANCH == "prod"' <<< "${PREP_RULES}" && \
   grep -qx 'runner_system_failure' <<< "${PREP_RETRY}" && \
   grep -qx 'stuck_or_timeout_failure' <<< "${PREP_RETRY}" && \
   grep -qx 'job_execution_timeout' <<< "${PREP_RETRY}" && \
   [[ "${HIL_PREP_NEED}" == $'false\ttrue' ]] && \
   [[ "${MERGE_PREP_NEED}" == $'false\ttrue' ]]; then
  test_pass "cicd storage preparation is branch-scoped, retryable, and in the build DAG"
else
  test_fail "cicd storage preparation job is not wired correctly"
fi

test_start "3.4a" "dev control-plane jobs are wired to gitlab then cicd"
DEV_GITLAB_SCRIPT="$(job_value 'deploy:control-plane:gitlab:dev' '.script[]')"
DEV_CICD_SCRIPT="$(job_value 'deploy:control-plane:cicd:dev' '.script[]')"
DEV_CICD_NEEDS="$(job_value 'deploy:control-plane:cicd:dev' '.needs[].job')"
if [[ "$(job_value 'deploy:control-plane:gitlab:dev' '.stage')" == "deploy-control-plane-dev" ]] && \
   [[ "$(job_value 'deploy:control-plane:cicd:dev' '.stage')" == "deploy-control-plane-dev" ]] && \
   grep -q 'framework/scripts/deploy-control-plane.sh dev gitlab' <<< "${DEV_GITLAB_SCRIPT}" && \
   grep -q 'framework/scripts/deploy-control-plane.sh dev cicd' <<< "${DEV_CICD_SCRIPT}" && \
   grep -qx 'deploy:control-plane:gitlab:dev' <<< "${DEV_CICD_NEEDS}"; then
  test_pass "dev control-plane jobs use the new stage, host-scoped scripts, and gitlab->cicd ordering"
else
  test_fail "dev control-plane jobs use the new stage, host-scoped scripts, and gitlab->cicd ordering"
fi

test_start "3.4b" "prod control-plane jobs are wired to gitlab then cicd"
PROD_GITLAB_SCRIPT="$(job_value 'deploy:control-plane:gitlab:prod' '.script[]')"
PROD_CICD_SCRIPT="$(job_value 'deploy:control-plane:cicd:prod' '.script[]')"
PROD_CICD_NEEDS="$(job_value 'deploy:control-plane:cicd:prod' '.needs[].job')"
if [[ "$(job_value 'deploy:control-plane:gitlab:prod' '.stage')" == "deploy-control-plane-prod" ]] && \
   [[ "$(job_value 'deploy:control-plane:cicd:prod' '.stage')" == "deploy-control-plane-prod" ]] && \
   grep -q 'framework/scripts/deploy-control-plane.sh prod gitlab' <<< "${PROD_GITLAB_SCRIPT}" && \
   grep -q 'framework/scripts/deploy-control-plane.sh prod cicd' <<< "${PROD_CICD_SCRIPT}" && \
   grep -qx 'deploy:control-plane:gitlab:prod' <<< "${PROD_CICD_NEEDS}"; then
  test_pass "prod control-plane jobs use the new stage, host-scoped scripts, and gitlab->cicd ordering"
else
  test_fail "prod control-plane jobs use the new stage, host-scoped scripts, and gitlab->cicd ordering"
fi

test_start "3.4c" "build:merge artifacts preserve closure paths and GC-root symlinks"
BUILD_MERGE_ARTIFACTS="$(job_value 'build:merge' '.artifacts.paths[]')"
if grep -qx 'build/closure-paths.json' <<< "${BUILD_MERGE_ARTIFACTS}" && \
   grep -qx 'build/closure-gitlab' <<< "${BUILD_MERGE_ARTIFACTS}" && \
   grep -qx 'build/closure-cicd' <<< "${BUILD_MERGE_ARTIFACTS}"; then
  test_pass "build:merge artifacts include closure-paths.json and both closure out-links"
else
  test_fail "build:merge artifacts include closure-paths.json and both closure out-links"
fi

test_start "3.4c1" "image artifacts survive the serialized HIL build gap"
if [[ "$(job_value 'build:image' '.artifacts.expire_in')" == "4 hours" ]] && \
   [[ "$(job_value 'build:image:hil-boot' '.artifacts.expire_in')" == "4 hours" ]] && \
   [[ "$(job_value 'build:merge' '.artifacts.expire_in')" == "4 hours" ]]; then
  test_pass "build:image, build:image:hil-boot, and build:merge artifacts keep a 4 hour TTL"
else
  test_fail "image and merge artifact TTLs must account for the serialized HIL build"
fi

test_start "3.4d" "cicd jobs pull build:merge via needs and do not use dependencies"
DEV_CICD_BUILD_NEEDS_ARTIFACTS="$(
  job_value 'deploy:control-plane:cicd:dev' \
    '.needs[] | select(.job == "build:merge") | .artifacts'
)"
PROD_CICD_BUILD_NEEDS_ARTIFACTS="$(
  job_value 'deploy:control-plane:cicd:prod' \
    '.needs[] | select(.job == "build:merge") | .artifacts'
)"
DEV_CICD_GITLAB_NEEDS_ARTIFACTS="$(
  job_value 'deploy:control-plane:cicd:dev' \
    '.needs[] | select(.job == "deploy:control-plane:gitlab:dev") | .artifacts'
)"
PROD_CICD_GITLAB_NEEDS_ARTIFACTS="$(
  job_value 'deploy:control-plane:cicd:prod' \
    '.needs[] | select(.job == "deploy:control-plane:gitlab:prod") | .artifacts'
)"
DEV_CICD_DEPENDENCIES="$(job_value 'deploy:control-plane:cicd:dev' '.dependencies // "null"')"
PROD_CICD_DEPENDENCIES="$(job_value 'deploy:control-plane:cicd:prod' '.dependencies // "null"')"
if [[ "${DEV_CICD_BUILD_NEEDS_ARTIFACTS}" == "true" ]] && \
   [[ "${PROD_CICD_BUILD_NEEDS_ARTIFACTS}" == "true" ]] && \
   [[ "${DEV_CICD_GITLAB_NEEDS_ARTIFACTS}" == "false" ]] && \
   [[ "${PROD_CICD_GITLAB_NEEDS_ARTIFACTS}" == "false" ]] && \
   [[ "${DEV_CICD_DEPENDENCIES}" == "null" ]] && \
   [[ "${PROD_CICD_DEPENDENCIES}" == "null" ]]; then
  test_pass "cicd jobs fetch build:merge artifacts via needs and omit dependencies"
else
  test_fail "cicd jobs fetch build:merge artifacts via needs and omit dependencies"
fi

test_start "3.4e" "cicd jobs declare the retry allow-list for runner restarts"
DEV_CICD_RETRY="$(job_value 'deploy:control-plane:cicd:dev' '.retry.when[]')"
PROD_CICD_RETRY="$(job_value 'deploy:control-plane:cicd:prod' '.retry.when[]')"
if grep -qx 'runner_system_failure' <<< "${DEV_CICD_RETRY}" && \
   grep -qx 'stuck_or_timeout_failure' <<< "${DEV_CICD_RETRY}" && \
   grep -qx 'job_execution_timeout' <<< "${DEV_CICD_RETRY}" && \
   grep -qx 'runner_system_failure' <<< "${PROD_CICD_RETRY}" && \
   grep -qx 'stuck_or_timeout_failure' <<< "${PROD_CICD_RETRY}" && \
   grep -qx 'job_execution_timeout' <<< "${PROD_CICD_RETRY}"; then
  test_pass "cicd jobs include the typed retry.when allow-list"
else
  test_fail "cicd jobs include the typed retry.when allow-list"
fi

test_start "3.4f" "gitlab jobs do not declare retry"
DEV_GITLAB_RETRY="$(job_value 'deploy:control-plane:gitlab:dev' '.retry // "null"')"
PROD_GITLAB_RETRY="$(job_value 'deploy:control-plane:gitlab:prod' '.retry // "null"')"
if [[ "${DEV_GITLAB_RETRY}" == "null" ]] && \
   [[ "${PROD_GITLAB_RETRY}" == "null" ]]; then
  test_pass "gitlab jobs have no retry block"
else
  test_fail "gitlab jobs have no retry block"
fi

test_start "3.4g" "guard:control-plane was removed"
if ! grep -q '^guard:control-plane:' "${CI_FILE}"; then
  test_pass "guard:control-plane is absent"
else
  test_fail "guard:control-plane is absent"
fi

# #510's per-job TMPDIR assertion (3.4h) was retired in #537. The class
# fix moves TMPDIR=/nix/tmp to the gitlab-runner systemd service
# environment (framework/nix/modules/gitlab-runner.nix), so every CI job
# inherits it via child-process env — no per-job override needed. The
# negation of the old assertion (no per-job TMPDIR: override permitted)
# is enforced by tests/test_runner_tmpdir_class_fix.sh (assertion 5),
# together with a positive check that the runner service and system-wide
# env both set TMPDIR=/nix/tmp and that the /nix/tmp/tmp.* sweep rule is
# present. Re-adding a per-job TMPDIR block here would fail that test.

runner_summary
