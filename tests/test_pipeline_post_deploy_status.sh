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
  test_pass "safe-apply manifest is collected as deploy artifact"
else
  test_fail "safe-apply manifest artifact wiring is missing"
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

# --- post-deploy.sh fixture harness ------------------------------------
#
# Builds a self-contained temp repo so post-deploy.sh's
# REPO_DIR ("${SCRIPT_DIR}/../..") resolves inside the fixture rather than
# the real checkout. curl/ssh are shimmed; the children are recording stubs.
#
# The fixture deliberately neutralizes HOME/XDG_CONFIG_HOME and unsets
# SOPS_AGE_KEY_FILE (#862): post-deploy.sh now resolves that variable itself,
# so a test that inherited the runner's ambient value would prove nothing
# about the resolution and — worse — would let the no-key case silently pass
# on a workstation that happens to have a key.
POST_DEPLOY_FIXTURES=()
cleanup_post_deploy_fixtures() {
  set +u
  local path=""
  for path in "${POST_DEPLOY_FIXTURES[@]}"; do
    [[ -n "${path}" ]] && rm -rf "${path}"
  done
}
trap cleanup_post_deploy_fixtures EXIT

# make_post_deploy_fixture <out_var> <backfill_exit_code> <place_repo_key:yes|no>
make_post_deploy_fixture() {
  local out_var="$1" backfill_rc="$2" place_key="$3"
  local dir
  dir="$(mktemp -d "${TMPDIR:-/tmp}/post-deploy-fixture.XXXXXX")"
  # Canonicalize: post-deploy.sh derives REPO_DIR with `cd ... && pwd`, which
  # resolves symlinks. On macOS mktemp hands back /var/... while the script
  # reports /private/var/..., so an uncanonicalized path breaks the
  # exported-value comparisons below.
  dir="$(cd "${dir}" && pwd -P)"
  POST_DEPLOY_FIXTURES+=("${dir}")
  mkdir -p "${dir}/framework/scripts" "${dir}/site" "${dir}/shims"
  cp "${REPO_ROOT}/framework/scripts/post-deploy.sh" "${dir}/framework/scripts/post-deploy.sh"

  cat > "${dir}/site/config.yaml" <<'EOF'
nodes:
  - mgmt_ip: 10.0.0.11
vms:
  vault_dev:
    ip: 10.0.0.21
EOF
  # influxdb is ENABLED so post-deploy.sh takes the branch that invokes
  # configure-dashboard-tokens.sh. That child is a SOPS consumer too, so
  # leaving influxdb disabled would let the fixture claim child coverage it
  # never exercised.
  cat > "${dir}/site/applications.yaml" <<'EOF'
applications:
  influxdb:
    enabled: true
    environments:
      dev:
        ip: 10.0.0.31
EOF

  # Recording stub: reports the SOPS_AGE_KEY_FILE it inherited, which is the
  # whole point of resolving the key in the parent (post-deploy.sh does not
  # call sops itself — its children do).
  cat > "${dir}/framework/scripts/configure-vault.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'CONFIGURE_VAULT_SAW_KEY=[%s]\n' "${SOPS_AGE_KEY_FILE:-<unset>}"
exit 0
EOF
  cat > "${dir}/framework/scripts/cert-storage-backfill.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'CERT_BACKFILL_SAW_KEY=[%s]\n' "\${SOPS_AGE_KEY_FILE:-<unset>}"
exit ${backfill_rc}
EOF
  cat > "${dir}/framework/scripts/configure-dashboard-tokens.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'DASHBOARD_TOKENS_SAW_KEY=[%s]\n' "${SOPS_AGE_KEY_FILE:-<unset>}"
exit 0
EOF
  cat > "${dir}/framework/scripts/configure-backups.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${dir}/framework/scripts/"*.sh

  cat > "${dir}/shims/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '{"initialized":true,"sealed":false}\n'
EOF
  cat > "${dir}/shims/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
remote_cmd="${*: -1}"
case "${remote_cmd}" in
  *root-token*) printf 'root-token\n'; exit 0 ;;
  *unseal-key*) printf 'unseal-key\n'; exit 0 ;;
  *pvesm*) exit 1 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${dir}/shims/"*

  if [[ "${place_key}" == "yes" ]]; then
    printf 'AGE-SECRET-KEY-FIXTURE\n' > "${dir}/operator.age.key"
  fi
  printf -v "${out_var}" '%s' "${dir}"
}

# run_post_deploy_fixture <dir> [preset SOPS_AGE_KEY_FILE value]
# Writes combined output to <dir>/post-deploy.out; echoes the exit status.
run_post_deploy_fixture() {
  local dir="$1" preset="${2:-}"
  local rc=0
  set +e
  if [[ -n "${preset}" ]]; then
    (
      export PATH="${dir}/shims:${PATH}"
      export HOME="${dir}/nonexistent-home"
      export XDG_CONFIG_HOME="${dir}/nonexistent-xdg"
      export SOPS_AGE_KEY_FILE="${preset}"
      cd "${dir}"
      framework/scripts/post-deploy.sh dev
    ) > "${dir}/post-deploy.out" 2>&1
    rc=$?
  else
    (
      export PATH="${dir}/shims:${PATH}"
      export HOME="${dir}/nonexistent-home"
      export XDG_CONFIG_HOME="${dir}/nonexistent-xdg"
      unset SOPS_AGE_KEY_FILE
      cd "${dir}"
      framework/scripts/post-deploy.sh dev
    ) > "${dir}/post-deploy.out" 2>&1
    rc=$?
  fi
  set -e
  printf '%s' "${rc}"
}

test_start "9" "post-deploy.sh propagates cert backfill failure"
make_post_deploy_fixture TMP_DIR 1 yes
fixture_status="$(run_post_deploy_fixture "${TMP_DIR}")"
fixture_out="$(cat "${TMP_DIR}/post-deploy.out")"
# The fixture supplies a repo-root key, so a non-zero exit must come from
# cert-storage-backfill.sh — not from the #862 key guard. Asserting the
# reason keeps this test faithful to what it claims to prove.
if [[ "${fixture_status}" -ne 0 && "${fixture_out}" != *"No SOPS age key found"* ]]; then
  test_pass "failing cert-storage-backfill.sh makes post-deploy.sh exit non-zero"
else
  test_fail "failing cert-storage-backfill.sh makes post-deploy.sh exit non-zero"
  sed 's/^/    /' "${TMP_DIR}/post-deploy.out" >&2
fi

test_start "14" "post-deploy.sh self-resolves SOPS_AGE_KEY_FILE and exports it to children (#862)"
make_post_deploy_fixture RESOLVE_DIR 0 yes
resolve_status="$(run_post_deploy_fixture "${RESOLVE_DIR}")"
resolve_out="$(cat "${RESOLVE_DIR}/post-deploy.out")"
if [[ "${resolve_status}" -eq 0 \
      && "${resolve_out}" == *"CONFIGURE_VAULT_SAW_KEY=[${RESOLVE_DIR}/operator.age.key]"* \
      && "${resolve_out}" == *"CERT_BACKFILL_SAW_KEY=[${RESOLVE_DIR}/operator.age.key]"* \
      && "${resolve_out}" == *"DASHBOARD_TOKENS_SAW_KEY=[${RESOLVE_DIR}/operator.age.key]"* ]]; then
  test_pass "unset SOPS_AGE_KEY_FILE resolves to repo-root operator.age.key and reaches every child"
else
  test_fail "post-deploy.sh did not export a resolved SOPS_AGE_KEY_FILE to its children"
  sed 's/^/    /' "${RESOLVE_DIR}/post-deploy.out" >&2
fi

test_start "15" "post-deploy.sh fails closed when no SOPS age key exists anywhere (#862)"
make_post_deploy_fixture NOKEY_DIR 0 no
nokey_status="$(run_post_deploy_fixture "${NOKEY_DIR}")"
nokey_out="$(cat "${NOKEY_DIR}/post-deploy.out")"
# Fails closed (G4) with both candidate paths named, and does so BEFORE any
# side effect — the "=== Vault ... post-deploy" banner is printed by the
# first step after the guard, so its absence proves nothing was contacted.
if [[ "${nokey_status}" -ne 0 \
      && "${nokey_out}" == *"No SOPS age key found"* \
      && "${nokey_out}" == *"operator.age.key"* \
      && "${nokey_out}" == *"sops/age/keys.txt"* \
      && "${nokey_out}" != *"post-deploy ("* \
      && "${nokey_out}" != *"CONFIGURE_VAULT_SAW_KEY"* ]]; then
  test_pass "missing key exits non-zero with named candidates before contacting Vault"
else
  test_fail "post-deploy.sh did not fail closed on a missing SOPS age key"
  sed 's/^/    /' "${NOKEY_DIR}/post-deploy.out" >&2
fi

test_start "16" "post-deploy.sh does not overwrite an already-set SOPS_AGE_KEY_FILE (#862)"
make_post_deploy_fixture PRESET_DIR 0 yes
preset_status="$(run_post_deploy_fixture "${PRESET_DIR}" "${PRESET_DIR}/preset.age.key")"
preset_out="$(cat "${PRESET_DIR}/post-deploy.out")"
if [[ "${preset_status}" -eq 0 \
      && "${preset_out}" == *"CONFIGURE_VAULT_SAW_KEY=[${PRESET_DIR}/preset.age.key]"* ]]; then
  test_pass "a caller-supplied SOPS_AGE_KEY_FILE survives (runner service env case)"
else
  test_fail "post-deploy.sh overwrote a caller-supplied SOPS_AGE_KEY_FILE"
  sed 's/^/    /' "${PRESET_DIR}/post-deploy.out" >&2
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
   grep -Fq '$CI_COMMIT_BRANCH == "prod"' <<< "${PUBLISH_JOB_BLOCK}"; then
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
