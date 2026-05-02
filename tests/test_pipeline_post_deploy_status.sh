#!/usr/bin/env bash
# test_pipeline_post_deploy_status.sh — Verify post-deploy.sh unification status.
#
# Sprint 014 decided to DEFER unification. This test verifies the decision
# is documented and the script still exists in the pipeline.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

DEPLOY_WORD="deploy"
OLD_RESTORE_SCRIPT="restore-after-${DEPLOY_WORD}.sh"

first_non_comment_line() {
  local pattern="$1"
  local file="$2"

  grep -n "${pattern}" "${file}" |
    grep -Ev '^[0-9]+:[[:space:]]*#' |
    head -1 |
    cut -d: -f1 || true
}

test_start "1" "post-deploy.sh assessment document exists"
if [[ -s "${REPO_ROOT}/docs/reports/sprint-014-post-deploy-assessment.md" ]]; then
  test_pass "assessment document exists"
else
  test_fail "assessment document missing"
fi

test_start "2" "Assessment contains DEFER decision"
if grep -qi "defer" "${REPO_ROOT}/docs/reports/sprint-014-post-deploy-assessment.md"; then
  test_pass "DEFER decision documented"
else
  test_fail "DEFER decision not found in assessment"
fi

test_start "3" "post-deploy.sh still exists (defer path)"
if [[ -x "${REPO_ROOT}/framework/scripts/post-deploy.sh" ]]; then
  test_pass "post-deploy.sh exists and is executable"
else
  test_fail "post-deploy.sh missing or not executable"
fi

test_start "4" "deploy pipeline invokes post-deploy.sh via safe-apply.sh and no old restore caller"
# safe-apply.sh invokes post-deploy.sh after successful preboot restore and
# Phase 2 start. The deleted post-boot restore script must not appear in
# deploy jobs or safe-apply.sh.
if grep -q "framework/scripts/safe-apply.sh dev" "${REPO_ROOT}/.gitlab-ci.yml" \
   && grep -q "framework/scripts/safe-apply.sh prod" "${REPO_ROOT}/.gitlab-ci.yml" \
   && grep -q '"\${SCRIPT_DIR}/post-deploy.sh" "\$ENV"' "${REPO_ROOT}/framework/scripts/safe-apply.sh" \
   && ! grep -Fq "${OLD_RESTORE_SCRIPT}" "${REPO_ROOT}/.gitlab-ci.yml" \
   && ! grep -Fq "${OLD_RESTORE_SCRIPT}" "${REPO_ROOT}/framework/scripts/safe-apply.sh"; then
  test_pass "deploy jobs use safe-apply post-deploy ownership without post-boot restore"
else
  test_fail "post-deploy.sh ownership or old restore deletion is broken"
fi

test_start "5" "post-deploy.sh calls cert-storage-backfill.sh"
if grep -q "cert-storage-backfill.sh" "${REPO_ROOT}/framework/scripts/post-deploy.sh"; then
  test_pass "post-deploy.sh references cert-storage-backfill.sh"
else
  test_fail "post-deploy.sh references cert-storage-backfill.sh"
fi

test_start "6" "deploy artifacts include preboot restore manifests"
if grep -Fq "build/preboot-restore-*.json" "${REPO_ROOT}/.gitlab-ci.yml" &&
   grep -Fq 'PREBOOT_MANIFEST="${REPO_DIR}/build/preboot-restore-${ENV}.json"' \
     "${REPO_ROOT}/framework/scripts/safe-apply.sh"; then
  test_pass "safe-apply manifest is persisted and collected as a deploy artifact"
else
  test_fail "safe-apply manifest persistence/artifact wiring is missing"
fi

test_start "7" "cert backfill runs after configure-vault.sh and before configure-dashboard-tokens.sh"
vault_line="$(first_non_comment_line 'configure-vault.sh' "${REPO_ROOT}/framework/scripts/post-deploy.sh")"
backfill_line="$(first_non_comment_line 'cert-storage-backfill.sh' "${REPO_ROOT}/framework/scripts/post-deploy.sh")"
dashboard_line="$(first_non_comment_line 'configure-dashboard-tokens.sh' "${REPO_ROOT}/framework/scripts/post-deploy.sh")"
if [[ -n "${vault_line}" && -n "${backfill_line}" && -n "${dashboard_line}" ]] &&
   (( vault_line < backfill_line && backfill_line < dashboard_line )); then
  test_pass "cert backfill placement is after Vault and before dashboard tokens"
else
  test_fail "cert backfill placement is after Vault and before dashboard tokens"
  printf '    configure-vault.sh line: %s\n' "${vault_line:-missing}" >&2
  printf '    cert-storage-backfill.sh line: %s\n' "${backfill_line:-missing}" >&2
  printf '    configure-dashboard-tokens.sh line: %s\n' "${dashboard_line:-missing}" >&2
fi

test_start "8" "cert backfill invocation is a bare command"
if [[ -n "${backfill_line}" ]]; then
  backfill_text="$(sed -n "${backfill_line}p" "${REPO_ROOT}/framework/scripts/post-deploy.sh")"
  preceding_text="$(sed -n "$(( backfill_line > 5 ? backfill_line - 5 : 1 )),${backfill_line}p" "${REPO_ROOT}/framework/scripts/post-deploy.sh")"
  if [[ "${backfill_text}" =~ \|\| ]] ||
     grep -Eq 'if .*cert-storage-backfill|set \+e' <<< "${preceding_text}"; then
    test_fail "post-deploy.sh softens the cert-backfill failure (line ${backfill_line}); per Sprint 029 Decision 12 it must be a bare command"
  else
    test_pass "cert backfill invocation has no local softener"
  fi
else
  test_fail "cert backfill invocation has no local softener"
fi

test_start "9" "post-deploy.sh propagates cert backfill failure"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
mkdir -p "${TMP_DIR}/framework/scripts" "${TMP_DIR}/site" "${TMP_DIR}/shims"
cp "${REPO_ROOT}/framework/scripts/post-deploy.sh" "${TMP_DIR}/framework/scripts/post-deploy.sh"
chmod +x "${TMP_DIR}/framework/scripts/post-deploy.sh"
cat > "${TMP_DIR}/site/config.yaml" <<'EOF'
nodes:
  - mgmt_ip: 10.0.0.11
vms:
  vault_dev:
    ip: 10.0.0.21
EOF
cat > "${TMP_DIR}/site/applications.yaml" <<'EOF'
applications:
  influxdb:
    enabled: false
EOF
cat > "${TMP_DIR}/framework/scripts/configure-vault.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
cat > "${TMP_DIR}/framework/scripts/cert-storage-backfill.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
cat > "${TMP_DIR}/framework/scripts/configure-dashboard-tokens.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
cat > "${TMP_DIR}/framework/scripts/configure-backups.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "${TMP_DIR}/framework/scripts/"*.sh
cat > "${TMP_DIR}/shims/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"initialized":true,"sealed":false}\n'
EOF
cat > "${TMP_DIR}/shims/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
remote_cmd="${*: -1}"
case "${remote_cmd}" in
  *root-token*) printf 'root-token\n'; exit 0 ;;
  *pvesm*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${TMP_DIR}/shims/"*

set +e
(
  export PATH="${TMP_DIR}/shims:${PATH}"
  cd "${TMP_DIR}"
  framework/scripts/post-deploy.sh dev
) > "${TMP_DIR}/post-deploy.out" 2>&1
fixture_status=$?
set -e
if [[ "${fixture_status}" -ne 0 ]]; then
  test_pass "failing cert-storage-backfill.sh makes post-deploy.sh exit non-zero"
else
  test_fail "failing cert-storage-backfill.sh makes post-deploy.sh exit non-zero"
  sed 's/^/    /' "${TMP_DIR}/post-deploy.out" >&2
fi

test_start "10" "publish:github stage is after test-prod"
test_prod_stage_line="$(grep -n '^  - test-prod$' "${REPO_ROOT}/.gitlab-ci.yml" | head -1 | cut -d: -f1 || true)"
publish_stage_line="$(grep -n '^  - publish-github$' "${REPO_ROOT}/.gitlab-ci.yml" | head -1 | cut -d: -f1 || true)"
if [[ -n "${test_prod_stage_line}" && -n "${publish_stage_line}" ]] && (( test_prod_stage_line < publish_stage_line )); then
  test_pass "publish-github stage follows test-prod"
else
  test_fail "publish-github stage does not follow test-prod"
fi

PUBLISH_JOB_BLOCK="$(sed -n '/^publish:github:/,$p' "${REPO_ROOT}/.gitlab-ci.yml")"

test_start "11" "publish:github is prod-only"
if grep -Fq 'stage: publish-github' <<< "${PUBLISH_JOB_BLOCK}" && \
   grep -Fq 'if: $CI_COMMIT_BRANCH == "prod"' <<< "${PUBLISH_JOB_BLOCK}"; then
  test_pass "publish:github job is scoped to prod"
else
  test_fail "publish:github job is not prod-only"
fi

test_start "12" "publish:github calls publish-to-github.sh"
if grep -Fq 'framework/scripts/publish-to-github.sh' <<< "${PUBLISH_JOB_BLOCK}"; then
  test_pass "publish:github invokes the publisher script"
else
  test_fail "publish:github does not invoke publish-to-github.sh"
fi

test_start "13" "publish:github preserves status artifact"
if grep -Fq 'when: always' <<< "${PUBLISH_JOB_BLOCK}" && \
   grep -Fq 'build/github-publish-status.json' <<< "${PUBLISH_JOB_BLOCK}" && \
   grep -Fq 'expire_in: 1 month' <<< "${PUBLISH_JOB_BLOCK}"; then
  test_pass "publish status artifact is collected with when: always"
else
  test_fail "publish status artifact wiring is missing"
fi

runner_summary
