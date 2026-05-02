#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PRECHECK_FIXTURE="${TMP_DIR}/precheck-fixture"
WRAPPER_FIXTURE="${TMP_DIR}/wrapper-fixture"
SHIM_DIR="${TMP_DIR}/shims"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"

mkdir -p "${SHIM_DIR}"

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

EXTRACT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--decrypt)
      shift
      ;;
    --output-type)
      shift 2
      ;;
    --extract)
      EXTRACT="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

PAYLOAD="${STUB_SOPS_JSON:-}"
if [[ -z "$PAYLOAD" ]]; then
  PAYLOAD='{}'
fi

if [[ -n "$EXTRACT" ]]; then
  python3 - "$EXTRACT" "$PAYLOAD" <<'PY'
import json
import sys

extract = sys.argv[1]
payload = json.loads(sys.argv[2])

if not (extract.startswith('["') and extract.endswith('"]')):
    raise SystemExit(2)

key = extract[2:-2]
if key not in payload:
    raise SystemExit(1)

value = payload[key]
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
  exit 0
fi

printf '%s\n' "$PAYLOAD"
EOF
chmod +x "${SHIM_DIR}/sops"

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${STUB_TOFU_MODE:-}" == "envdump" ]]; then
  env | grep '^TF_VAR_vault_approle_' | cut -d= -f1 | sort
  exit 0
fi

exit 0
EOF
chmod +x "${SHIM_DIR}/tofu"

setup_precheck_fixture() {
  local repo_dir="$1"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/framework/catalog/widget" \
    "${repo_dir}/framework/catalog/roon" \
    "${repo_dir}/framework/tofu/modules/testapp" \
    "${repo_dir}/site/sops"

  cp "${REPO_ROOT}/framework/scripts/check-approle-creds.sh" \
    "${repo_dir}/framework/scripts/check-approle-creds.sh"
  cp "${REPO_ROOT}/framework/scripts/vault-requirements-lib.sh" \
    "${repo_dir}/framework/scripts/vault-requirements-lib.sh"
  chmod +x \
    "${repo_dir}/framework/scripts/check-approle-creds.sh" \
    "${repo_dir}/framework/scripts/vault-requirements-lib.sh"

  cat > "${repo_dir}/framework/catalog/widget/vault-requirements.yaml" <<'EOF'
approles:
  - name_template: "widget_${env}"
    policy: "widget-policy"
    sops_keys:
      role_id: "vault_approle_widget_${env}_role_id"
      secret_id: "vault_approle_widget_${env}_secret_id"
EOF

  cat > "${repo_dir}/framework/tofu/modules/testapp/vault-requirements.yaml" <<'EOF'
approles:
  - name_template: "testapp_${env}"
    policy: "default-policy"
    sops_keys:
      role_id: "vault_approle_testapp_${env}_role_id"
      secret_id: "vault_approle_testapp_${env}_secret_id"
EOF

  cat > "${repo_dir}/flake.nix" <<'EOF'
{
  description = "fixture";
}
EOF

  cat > "${repo_dir}/site/sops/secrets.yaml" <<'EOF'
{}
EOF

  cat > "${repo_dir}/operator.age.key" <<'EOF'
AGE-SECRET-KEY-FAKE
EOF
}

setup_wrapper_fixture() {
  local repo_dir="$1"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/framework/catalog/influxdb" \
    "${repo_dir}/framework/tofu/root" \
    "${repo_dir}/site/sops" \
    "${repo_dir}/site/tofu"

  cp "${REPO_ROOT}/framework/scripts/tofu-wrapper.sh" \
    "${repo_dir}/framework/scripts/tofu-wrapper.sh"
  cp "${REPO_ROOT}/framework/scripts/vault-requirements-lib.sh" \
    "${repo_dir}/framework/scripts/vault-requirements-lib.sh"
  cp "${REPO_ROOT}/framework/catalog/influxdb/vault-requirements.yaml" \
    "${repo_dir}/framework/catalog/influxdb/vault-requirements.yaml"
  chmod +x \
    "${repo_dir}/framework/scripts/tofu-wrapper.sh" \
    "${repo_dir}/framework/scripts/vault-requirements-lib.sh"

  cat > "${repo_dir}/framework/scripts/validate-site-config.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${repo_dir}/framework/scripts/validate-site-config.sh"

  cat > "${repo_dir}/framework/tofu/root/main.tf" <<'EOF'
variable "image_versions" {
  type = map(string)
}

output "example" {
  value = var.image_versions["dns"]
}
EOF

  cat > "${repo_dir}/flake.nix" <<'EOF'
{
  description = "fixture";
}
EOF

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
nas:
  ip: 127.0.0.1
  postgres_port: 5432
  postgres_ssl: false
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
github:
  remote_url: git@example.invalid:repo.git
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications:
  influxdb:
    enabled: true
    environments:
      dev:
        vmid: 501
      prod:
        vmid: 601
EOF

  cat > "${repo_dir}/site/sops/secrets.yaml" <<'EOF'
{}
EOF

  cat > "${repo_dir}/site/tofu/image-versions.auto.tfvars" <<'EOF'
image_versions = {
  "dns" = "dns-deadbeef.img"
}
EOF

  cat > "${repo_dir}/operator.age.key" <<'EOF'
AGE-SECRET-KEY-FAKE
EOF
}

job_value() {
  local job_name="$1"
  local expr="$2"

  yq -r ".\"${job_name}\"${expr}" "${CI_FILE}" 2>/dev/null || true
}

setup_precheck_fixture "${PRECHECK_FIXTURE}"
setup_wrapper_fixture "${WRAPPER_FIXTURE}"

cat > "${PRECHECK_FIXTURE}/site/config.yaml" <<'EOF'
nas:
  ip: 127.0.0.1
  postgres_port: 5432
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
EOF

test_start "1" "preflight fails for an enabled manifest-backed app with missing creds"
cat > "${PRECHECK_FIXTURE}/site/applications.yaml" <<'EOF'
applications:
  widget:
    enabled: true
    environments:
      dev: {}
      prod: {}
EOF
set +e
# unset CI_COMMIT_BRANCH so FORCE_ENV controls env resolution. On the GitLab
# runner CI_COMMIT_BRANCH is set to the runner's checkout branch and would
# otherwise win precedence in check-approle-creds.sh. (See e552ea1 for the
# original incident in sub-test 4 and the report at
# docs/reports/sprint-029-mr-198-validate-approle-onboarding-failure.md for
# the broader pattern.)
MISSING_OUTPUT="$(
  cd "${PRECHECK_FIXTURE}" &&
  unset CI_COMMIT_BRANCH &&
  PATH="${SHIM_DIR}:${PATH}" \
  STUB_SOPS_JSON='{}' \
  FORCE_ENV=dev \
  framework/scripts/check-approle-creds.sh 2>&1
)"
MISSING_STATUS=$?
set -e
if [[ "${MISSING_STATUS}" -eq 1 ]] && \
   grep -Fq 'widget is enabled in applications.yaml but has no AppRole' <<< "${MISSING_OUTPUT}" && \
   grep -Fq 'rebuild-cluster.sh --scope onboard-app=widget' <<< "${MISSING_OUTPUT}" && \
   grep -Fq 'git push' <<< "${MISSING_OUTPUT}"; then
  test_pass "missing creds fail fast with the app name and remediation command"
else
  test_fail "missing creds fail fast with the app name and remediation command"
  printf '    output:\n%s\n' "${MISSING_OUTPUT}" >&2
fi

test_start "2" "preflight ignores enabled apps that do not ship a manifest"
cat > "${PRECHECK_FIXTURE}/site/applications.yaml" <<'EOF'
applications:
  roon:
    enabled: true
    environments:
      dev: {}
      prod: {}
EOF
set +e
NO_MANIFEST_OUTPUT="$(
  cd "${PRECHECK_FIXTURE}" &&
  unset CI_COMMIT_BRANCH &&
  PATH="${SHIM_DIR}:${PATH}" \
  STUB_SOPS_JSON='{}' \
  FORCE_ENV=dev \
  framework/scripts/check-approle-creds.sh 2>&1
)"
NO_MANIFEST_STATUS=$?
set -e
if [[ "${NO_MANIFEST_STATUS}" -eq 0 ]] && \
   grep -Fq 'AppRole credential preflight passed for dev.' <<< "${NO_MANIFEST_OUTPUT}"; then
  test_pass "manifestless apps are not blocked by the preflight"
else
  test_fail "manifestless apps are not blocked by the preflight"
  printf '    output:\n%s\n' "${NO_MANIFEST_OUTPUT}" >&2
fi

test_start "3" "already-onboarded app passes preflight"
cat > "${PRECHECK_FIXTURE}/site/applications.yaml" <<'EOF'
applications:
  widget:
    enabled: true
    environments:
      dev: {}
      prod: {}
EOF
WIDGET_DEV_JSON='{"vault_approle_widget_dev_role_id":"role-dev","vault_approle_widget_dev_secret_id":"secret-dev"}'
set +e
ONBOARDED_OUTPUT="$(
  cd "${PRECHECK_FIXTURE}" &&
  unset CI_COMMIT_BRANCH &&
  PATH="${SHIM_DIR}:${PATH}" \
  STUB_SOPS_JSON="${WIDGET_DEV_JSON}" \
  FORCE_ENV=dev \
  framework/scripts/check-approle-creds.sh 2>&1
)"
ONBOARDED_STATUS=$?
set -e
if [[ "${ONBOARDED_STATUS}" -eq 0 ]] && \
   grep -Fq 'AppRole credential preflight passed for dev.' <<< "${ONBOARDED_OUTPUT}"; then
  test_pass "existing SOPS credentials satisfy the preflight"
else
  test_fail "existing SOPS credentials satisfy the preflight"
  printf '    output:\n%s\n' "${ONBOARDED_OUTPUT}" >&2
fi

test_start "4" "CI_MERGE_REQUEST_TARGET_BRANCH_NAME is no longer consumed by check-approle-creds.sh"
# Dead-branch ratchet. The script previously honored
# CI_MERGE_REQUEST_TARGET_BRANCH_NAME at higher precedence than FORCE_ENV. That
# branch became dead code in production after commit 16f0179 removed
# validate:approle-creds from MR pipelines, and surfaced as a latent test bug
# the first time a dev->prod MR pipeline ran the fixture (pipeline 736 for
# MR !198, 2026-04-25 — see
# docs/reports/sprint-029-mr-198-validate-approle-onboarding-failure.md).
# The branch was deleted; this test prevents accidental re-introduction.
#
# If the live preflight is re-enabled on dev->prod MRs (follow-up: "Re-enable
# approle-creds live preflight on dev->prod MRs"), this test will need to be
# rewritten to assert whatever resolution semantics that work decides on.
SCRIPT_PATH="${REPO_ROOT}/framework/scripts/check-approle-creds.sh"

# 4a: static check — the script source (excluding comments) must not reference
# the dead branch. We strip `# ...` comments first so a forward-pointing comment
# in the script that explains why the branch was removed (and what to do if the
# follow-up re-enables it) does not falsely trip this check.
if ! sed 's/#.*//' "${SCRIPT_PATH}" | grep -q 'CI_MERGE_REQUEST_TARGET_BRANCH_NAME'; then
  test_pass "static: check-approle-creds.sh has no executable reference to CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
else
  test_fail "static: check-approle-creds.sh has no executable reference to CI_MERGE_REQUEST_TARGET_BRANCH_NAME"
  sed 's/#.*//' "${SCRIPT_PATH}" | grep -n 'CI_MERGE_REQUEST_TARGET_BRANCH_NAME' >&2
fi

# 4b: runtime check — setting only CI_MERGE_REQUEST_TARGET_BRANCH_NAME (with
# CI_COMMIT_BRANCH and FORCE_ENV unset) must NOT resolve the env. The script
# must exit non-zero with the "Cannot determine target environment" message.
WIDGET_PROD_ONLY_JSON='{"vault_approle_widget_prod_role_id":"role-prod","vault_approle_widget_prod_secret_id":"secret-prod"}'
set +e
MR_OUTPUT="$(
  cd "${PRECHECK_FIXTURE}" &&
  unset CI_COMMIT_BRANCH FORCE_ENV &&
  PATH="${SHIM_DIR}:${PATH}" \
  STUB_SOPS_JSON="${WIDGET_PROD_ONLY_JSON}" \
  CI_MERGE_REQUEST_TARGET_BRANCH_NAME=prod \
  framework/scripts/check-approle-creds.sh 2>&1
)"
MR_STATUS=$?
set -e
if [[ "${MR_STATUS}" -ne 0 ]] && \
   grep -Fq 'Cannot determine target environment' <<< "${MR_OUTPUT}"; then
  test_pass "runtime: CI_MERGE_REQUEST_TARGET_BRANCH_NAME alone does not resolve env"
else
  test_fail "runtime: CI_MERGE_REQUEST_TARGET_BRANCH_NAME alone does not resolve env"
  printf '    status: %s\n' "${MR_STATUS}" >&2
  printf '    output:\n%s\n' "${MR_OUTPUT}" >&2
fi

test_start "4.1" "preflight fails for fixed-role manifests with missing creds"
cat > "${PRECHECK_FIXTURE}/site/applications.yaml" <<'EOF'
applications: {}
EOF
cat > "${PRECHECK_FIXTURE}/site/config.yaml" <<'EOF'
vms:
  testapp_dev:
    vmid: 501
  testapp_prod:
    vmid: 601
EOF
set +e
FIXED_ROLE_OUTPUT="$(
  cd "${PRECHECK_FIXTURE}" &&
  unset CI_COMMIT_BRANCH &&
  PATH="${SHIM_DIR}:${PATH}" \
  STUB_SOPS_JSON='{}' \
  FORCE_ENV=dev \
  framework/scripts/check-approle-creds.sh 2>&1
)"
FIXED_ROLE_STATUS=$?
set -e
if [[ "${FIXED_ROLE_STATUS}" -eq 1 ]] && \
   grep -Fq 'testapp is defined in site/config.yaml for dev but has no AppRole' <<< "${FIXED_ROLE_OUTPUT}" && \
   grep -Fq 'vault_approle_testapp_dev_role_id' <<< "${FIXED_ROLE_OUTPUT}" && \
   grep -Fq 'Commit the SOPS change and retry the deploy.' <<< "${FIXED_ROLE_OUTPUT}"; then
  test_pass "fixed-role manifests fail fast with the missing testapp credential names"
else
  test_fail "fixed-role manifests fail fast with the missing testapp credential names"
  printf '    output:\n%s\n' "${FIXED_ROLE_OUTPUT}" >&2
fi

test_start "4.2" "fixed-role manifests pass once credentials exist"
FIXED_ROLE_JSON='{"vault_approle_testapp_dev_role_id":"role-dev","vault_approle_testapp_dev_secret_id":"secret-dev"}'
set +e
FIXED_ROLE_OK_OUTPUT="$(
  cd "${PRECHECK_FIXTURE}" &&
  unset CI_COMMIT_BRANCH &&
  PATH="${SHIM_DIR}:${PATH}" \
  STUB_SOPS_JSON="${FIXED_ROLE_JSON}" \
  FORCE_ENV=dev \
  framework/scripts/check-approle-creds.sh 2>&1
)"
FIXED_ROLE_OK_STATUS=$?
set -e
if [[ "${FIXED_ROLE_OK_STATUS}" -eq 0 ]] && \
   grep -Fq 'AppRole credential preflight passed for dev.' <<< "${FIXED_ROLE_OK_OUTPUT}"; then
  test_pass "fixed-role manifests accept existing testapp credentials"
else
  test_fail "fixed-role manifests accept existing testapp credentials"
  printf '    output:\n%s\n' "${FIXED_ROLE_OK_OUTPUT}" >&2
fi

test_start "5" "validate:approle-creds runs on deploy pipelines only (not MR)"
APPROLE_JOB_STAGE="$(job_value 'validate:approle-creds' '.stage')"
APPROLE_JOB_SCRIPT="$(job_value 'validate:approle-creds' '.script[]')"
APPROLE_JOB_RULES="$(job_value 'validate:approle-creds' '.rules[].if')"
if [[ "${APPROLE_JOB_STAGE}" == "validate" ]] && \
   grep -q 'framework/scripts/check-approle-creds.sh' <<< "${APPROLE_JOB_SCRIPT}" && \
   ! grep -qx '\$CI_PIPELINE_SOURCE == "merge_request_event"' <<< "${APPROLE_JOB_RULES}" && \
   grep -qx '\$CI_COMMIT_BRANCH == "dev"' <<< "${APPROLE_JOB_RULES}" && \
   grep -qx '\$CI_COMMIT_BRANCH == "prod"' <<< "${APPROLE_JOB_RULES}"; then
  test_pass "CI preflight job runs on dev/prod push only, not MR pipelines"
else
  test_fail "CI preflight job runs on dev/prod push only, not MR pipelines"
fi

test_start "6" "tofu-wrapper exports the expanded AppRole TF_VAR set"
WRAPPER_SOPS_JSON="$(cat <<'EOF'
{
  "proxmox_api_user": "user@pam",
  "proxmox_api_password": "pw",
  "tofu_db_password": "pw",
  "ssh_pubkey": "ssh-ed25519 AAAA test",
  "pdns_api_key": "pdns",
  "influxdb_admin_token": "influxdb-admin",
  "grafana_admin_password": "grafana-admin",
  "grafana_influxdb_token": "grafana-influxdb",
  "tailscale_auth_key": "tskey",
  "ssh_privkey": "",
  "ssh_host_keys": {},
  "vault_approle_dns1_prod_role_id": "x",
  "vault_approle_dns1_prod_secret_id": "x",
  "vault_approle_dns2_prod_role_id": "x",
  "vault_approle_dns2_prod_secret_id": "x",
  "vault_approle_dns1_dev_role_id": "x",
  "vault_approle_dns1_dev_secret_id": "x",
  "vault_approle_dns2_dev_role_id": "x",
  "vault_approle_dns2_dev_secret_id": "x",
  "vault_approle_gatus_role_id": "x",
  "vault_approle_gatus_secret_id": "x",
  "vault_approle_gitlab_role_id": "x",
  "vault_approle_gitlab_secret_id": "x",
  "vault_approle_cicd_role_id": "x",
  "vault_approle_cicd_secret_id": "x",
  "vault_approle_influxdb_dev_role_id": "x",
  "vault_approle_influxdb_dev_secret_id": "x",
  "vault_approle_influxdb_prod_role_id": "x",
  "vault_approle_influxdb_prod_secret_id": "x",
  "vault_approle_testapp_dev_role_id": "x",
  "vault_approle_testapp_dev_secret_id": "x",
  "vault_approle_testapp_prod_role_id": "x",
  "vault_approle_testapp_prod_secret_id": "x",
  "vault_approle_grafana_dev_role_id": "x",
  "vault_approle_grafana_dev_secret_id": "x",
  "vault_approle_grafana_prod_role_id": "x",
  "vault_approle_grafana_prod_secret_id": "x"
}
EOF
)"
EXPECTED_TF_VARS="$(cat <<'EOF'
TF_VAR_vault_approle_cicd_role_id
TF_VAR_vault_approle_cicd_secret_id
TF_VAR_vault_approle_dns1_dev_role_id
TF_VAR_vault_approle_dns1_dev_secret_id
TF_VAR_vault_approle_dns1_prod_role_id
TF_VAR_vault_approle_dns1_prod_secret_id
TF_VAR_vault_approle_dns2_dev_role_id
TF_VAR_vault_approle_dns2_dev_secret_id
TF_VAR_vault_approle_dns2_prod_role_id
TF_VAR_vault_approle_dns2_prod_secret_id
TF_VAR_vault_approle_gatus_role_id
TF_VAR_vault_approle_gatus_secret_id
TF_VAR_vault_approle_gitlab_role_id
TF_VAR_vault_approle_gitlab_secret_id
TF_VAR_vault_approle_grafana_dev_role_id
TF_VAR_vault_approle_grafana_dev_secret_id
TF_VAR_vault_approle_grafana_prod_role_id
TF_VAR_vault_approle_grafana_prod_secret_id
TF_VAR_vault_approle_influxdb_dev_role_id
TF_VAR_vault_approle_influxdb_dev_secret_id
TF_VAR_vault_approle_influxdb_prod_role_id
TF_VAR_vault_approle_influxdb_prod_secret_id
TF_VAR_vault_approle_testapp_dev_role_id
TF_VAR_vault_approle_testapp_dev_secret_id
TF_VAR_vault_approle_testapp_prod_role_id
TF_VAR_vault_approle_testapp_prod_secret_id
EOF
)"
set +e
WRAPPER_OUTPUT="$(
  cd "${WRAPPER_FIXTURE}" &&
  PATH="${SHIM_DIR}:${PATH}" \
  STUB_SOPS_JSON="${WRAPPER_SOPS_JSON}" \
  STUB_TOFU_MODE=envdump \
  framework/scripts/tofu-wrapper.sh state list 2>&1
)"
WRAPPER_STATUS=$?
set -e
WRAPPER_ENV_LINES="$(printf '%s\n' "${WRAPPER_OUTPUT}" | grep '^TF_VAR_vault_approle_' || true)"
if [[ "${WRAPPER_STATUS}" -eq 0 ]] && [[ "${WRAPPER_ENV_LINES}" == "${EXPECTED_TF_VARS}" ]]; then
  test_pass "wrapper exports the expanded AppRole TF_VAR set"
else
  test_fail "wrapper exports the expanded AppRole TF_VAR set"
  printf '    output:\n%s\n' "${WRAPPER_OUTPUT}" >&2
fi

runner_summary
