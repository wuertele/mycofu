#!/usr/bin/env bash
# test_sprint_028_revert_baseline.sh -- Guard against reintroducing Sprint 027 surface.

set -euo pipefail
shopt -s nullglob

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

VDB_WORD="vdb"
DEPLOY_WORD="deploy"
LEGACY_GATE_FILE="wait-for-${VDB_WORD}.nix"
LEGACY_READY_TARGET="${VDB_WORD}-ready.target"
LEGACY_RESTORE_SCRIPT="restore-after-${DEPLOY_WORD}.sh"

test_start "1" "repo contains no maybe_accept_first_deploy_marker symbol"
if git -C "${REPO_ROOT}" grep -q --fixed-strings \
  "maybe_accept_first_deploy_marker" \
  -- ':!docs' ':!tests/test_sprint_028_revert_baseline.sh'
then
  test_fail "maybe_accept_first_deploy_marker is present"
else
  test_pass "maybe_accept_first_deploy_marker is absent"
fi

test_start "2" "no tests/test_first_deploy_*.sh files exist"
first_deploy_tests=("${REPO_ROOT}"/tests/test_first_deploy_*.sh)
if [[ ${#first_deploy_tests[@]} -eq 0 ]]; then
  test_pass "no first-deploy test scripts exist"
else
  test_fail "unexpected first-deploy test scripts exist"
fi

test_start "3" "no first-deploy helper scripts exist"
missing_helpers=0
for path in \
  "${REPO_ROOT}/framework/scripts/confirm-first-deploy.sh" \
  "${REPO_ROOT}/framework/scripts/check-first-deploy-marker.sh" \
  "${REPO_ROOT}/framework/scripts/check-first-deploy-deadlocks.sh" \
  "${REPO_ROOT}/framework/scripts/first-deploy-lib.sh"
do
  if [[ -e "${path}" ]]; then
    missing_helpers=1
  fi
done
if [[ "${missing_helpers}" -eq 0 ]]; then
  test_pass "first-deploy helper scripts are absent"
else
  test_fail "one or more first-deploy helper scripts still exist"
fi

test_start "4" "legacy vdb gate module is absent"
if [[ -e "${REPO_ROOT}/framework/nix/modules/${LEGACY_GATE_FILE}" ]]; then
  test_fail "${LEGACY_GATE_FILE} still exists"
else
  test_pass "${LEGACY_GATE_FILE} is absent"
fi

test_start "5" "base.nix no longer imports the legacy vdb gate"
if grep -Fq "./${LEGACY_GATE_FILE}" "${REPO_ROOT}/framework/nix/modules/base.nix"; then
  test_fail "base.nix still imports ${LEGACY_GATE_FILE}"
else
  test_pass "base.nix does not import ${LEGACY_GATE_FILE}"
fi

test_start "6" "configure-vault.sh contains no cicd-first-deploy-policy reference"
if grep -q 'cicd-first-deploy-policy' "${REPO_ROOT}/framework/scripts/configure-vault.sh"; then
  test_fail "configure-vault.sh still references cicd-first-deploy-policy"
else
  test_pass "configure-vault.sh has no cicd-first-deploy-policy reference"
fi

test_start "7" "old post-boot restore script is absent"
if [[ -e "${REPO_ROOT}/framework/scripts/${LEGACY_RESTORE_SCRIPT}" ]]; then
  test_fail "${LEGACY_RESTORE_SCRIPT} still exists"
else
  test_pass "${LEGACY_RESTORE_SCRIPT} is absent"
fi

test_start "8" ".claude/rules/first-deploy.md does not exist"
if [[ -e "${REPO_ROOT}/.claude/rules/first-deploy.md" ]]; then
  test_fail ".claude/rules/first-deploy.md still exists"
else
  test_pass ".claude/rules/first-deploy.md is absent"
fi

test_start "9" ".gitlab-ci.yml contains no legacy vdb gate validation stage"
if grep -q "^validate:wait-for-${VDB_WORD}-module:" "${REPO_ROOT}/.gitlab-ci.yml"; then
  test_fail ".gitlab-ci.yml still defines the legacy vdb gate validation stage"
else
  test_pass ".gitlab-ci.yml has no legacy vdb gate validation stage"
fi

test_start "10" ".gitlab-ci.yml contains no validate:first-deploy-* stages"
if grep -Eq '^validate:first-deploy-[^:]+' "${REPO_ROOT}/.gitlab-ci.yml"; then
  test_fail ".gitlab-ci.yml still defines validate:first-deploy-* stages"
else
  test_pass ".gitlab-ci.yml has no validate:first-deploy-* stages"
fi

runner_summary
