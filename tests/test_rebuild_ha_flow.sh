#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

REAL_GIT="$(command -v git)"

make_noop_script() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${path}"
}

setup_fixture_repo() {
  local repo_dir="$1"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/framework/step-ca" \
    "${repo_dir}/framework/tofu/root" \
    "${repo_dir}/site/sops" \
    "${repo_dir}/site/gatus" \
    "${repo_dir}/build"

  cp "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" "${repo_dir}/framework/scripts/rebuild-cluster.sh"
  cp "${REPO_ROOT}/framework/scripts/converge-lib.sh" "${repo_dir}/framework/scripts/converge-lib.sh"
  chmod +x "${repo_dir}/framework/scripts/rebuild-cluster.sh"
  chmod +x "${repo_dir}/framework/scripts/converge-lib.sh"

  cat > "${repo_dir}/framework/tofu/root/main.tf" <<'EOF'
module "cicd" {
  source = "../modules/cicd"
}

module "gitlab" {
  source = "../modules/gitlab"
}

module "pbs" {
  source = "../modules/pbs"
}

module "testapp_dev" {
  source = "../modules/testapp"
}

module "vault_dev" {
  source = "../modules/vault"
}
EOF

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
domain: example.test
acme: staging
nas:
  ip: 10.0.0.50
  ssh_user: admin
  postgres_port: 5432
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
vms:
  gitlab:
    vmid: 150
    ip: 10.0.0.31
    backup: false
  cicd:
    vmid: 160
    ip: 10.0.0.32
    backup: false
  pbs:
    vmid: 190
    ip: 10.0.0.33
    backup: false
  testapp_dev:
    vmid: 500
    ip: 10.0.0.41
    backup: false
  vault_dev:
    vmid: 302
    ip: 10.0.0.21
    backup: false
  vault_prod:
    vmid: 402
    ip: 10.0.0.22
    backup: false
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  printf 'dummy: value\n' > "${repo_dir}/site/sops/secrets.yaml"
  printf 'age1dummy\n' > "${repo_dir}/operator.age.key"
  printf 'dummy ca\n' > "${repo_dir}/framework/step-ca/root-ca.crt"

  cat > "${repo_dir}/framework/scripts/git-deploy-context.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

resolve_git_context() { CURRENT_BRANCH="dev"; }
classify_scope_impact() { return 0; }
print_scope_classification_failure() { :; }
detect_initial_deploy() { INITIAL_DEPLOY=1; }
refresh_gitlab_prod_ref() { :; }
check_branch_safety() { return 0; }
print_branch_safety_refusal() { :; }
resolve_last_known_prod_context() { :; }
detect_config_yaml_divergence() { :; }
print_deploy_banner() { echo "deploy banner"; }
scope_requires_prod_branch() { return 1; }
should_skip_gitlab_handoff() { return 0; }
print_last_known_prod_comparison() { :; }
write_deploy_manifest() { echo "deploy manifest"; }
EOF
  chmod +x "${repo_dir}/framework/scripts/git-deploy-context.sh"

  cat > "${repo_dir}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

certbot_cluster_staging_override_targets() { return 0; }
certbot_cluster_expected_mode() { echo "staging"; }
certbot_cluster_expected_url() { echo "https://staging.invalid/directory"; }
certbot_cluster_prod_shared_backup_certbot_records() { return 0; }
certbot_cluster_run_remote_helper() { return 0; }
EOF
  chmod +x "${repo_dir}/framework/scripts/certbot-cluster.sh"

  cat > "${repo_dir}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${STUB_LOG_FILE}"

case "${1:-}" in
  init)
    exit 0
    ;;
  state)
    if [[ "${2:-}" == "list" ]]; then
      printf '%s' "${STUB_TOFU_STATE_OUTPUT:-}"
      exit 0
    fi
    if [[ "${2:-}" == "rm" ]]; then
      exit 0
    fi
    if [[ "${2:-}" == "show" ]]; then
      exit 0
    fi
    ;;
  plan)
    if [[ "$*" == *"-target=module.gitlab"* && "$*" != *"-out="* && "${STUB_GITLAB_PLAN_MODE:-}" == "prevent_destroy" ]]; then
      printf '%s\n' "Instance cannot be destroyed" >&2
      exit 1
    fi
    for arg in "$@"; do
      [[ "$arg" == -out=* ]] && : > "${arg#-out=}"
    done
    exit 0
    ;;
  apply)
    exit 0
    ;;
esac

echo "unexpected tofu-wrapper invocation: $*" >&2
exit 2
EOF
  chmod +x "${repo_dir}/framework/scripts/tofu-wrapper.sh"

  cat > "${repo_dir}/framework/scripts/restore-before-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-before-start.sh %s\n' "$*" >> "${STUB_LOG_FILE}"
exit 0
EOF
  chmod +x "${repo_dir}/framework/scripts/restore-before-start.sh"

  for script_name in \
    verify-nas-prereqs.sh \
    configure-node-network.sh \
    configure-node-storage.sh \
    form-cluster.sh \
    configure-storage.sh \
    build-all-images.sh \
    ensure-app-secrets.sh \
    generate-gatus-config.sh \
    backup-now.sh \
    install-pbs.sh \
    init-vault.sh \
    configure-vault.sh \
    cert-storage-backfill.sh \
    configure-replication.sh \
    configure-gitlab.sh \
    register-runner.sh \
    configure-sentinel-gatus.sh \
    configure-metrics.sh \
    configure-dashboard-tokens.sh \
    deploy-workstation-closure.sh \
    validate.sh
  do
    make_noop_script "${repo_dir}/framework/scripts/${script_name}"
  done

  # configure-pbs.sh and configure-backups.sh are LOGGED, not silent.
  # The #132 regression test 3.22 asserts that no backup-job
  # configuration command appears in the log before any
  # restore-before-start.sh line. configure-pbs.sh accepts
  # --skip-backup-jobs to bypass the backup-job creation path; calls
  # before restore must always carry that flag, and configure-backups.sh
  # must never appear before restore at all.
  cat > "${repo_dir}/framework/scripts/configure-pbs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'configure-pbs.sh %s\n' "$*" >> "${STUB_LOG_FILE}"
exit 0
EOF
  chmod +x "${repo_dir}/framework/scripts/configure-pbs.sh"

  cat > "${repo_dir}/framework/scripts/configure-backups.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'configure-backups.sh %s\n' "$*" >> "${STUB_LOG_FILE}"
exit 0
EOF
  chmod +x "${repo_dir}/framework/scripts/configure-backups.sh"

  "${REAL_GIT}" -C "${repo_dir}" init -b dev >/dev/null
  "${REAL_GIT}" -C "${repo_dir}" config user.name "Test Runner"
  "${REAL_GIT}" -C "${repo_dir}" config user.email "tests@example.invalid"
  "${REAL_GIT}" -C "${repo_dir}" add .
  "${REAL_GIT}" -C "${repo_dir}" commit -m "fixture" >/dev/null
}

setup_shims() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/ping" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${shim_dir}/ping"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"

# Log ha-manager invocations so tests can assert which VMIDs the rebuild
# script attempted to deregister. Used by #270 regression tests 3.17/3.18.
if [[ -n "${STUB_LOG_FILE:-}" && "${remote_cmd}" == *"ha-manager"* ]]; then
  printf 'ssh-ha %s\n' "${remote_cmd}" >> "${STUB_LOG_FILE}"
fi

if [[ "${remote_cmd}" == "true" ]]; then
  exit 0
fi

if [[ "${remote_cmd}" == *"psql -U postgres"* ]]; then
  printf 'tofu_state\n'
  exit 0
fi

if [[ "${remote_cmd}" == *"qm status "* && "${remote_cmd}" == *"awk '{print \$2}'"* ]]; then
  printf 'stopped\n'
  exit 0
fi

if [[ "${remote_cmd}" == *"qm status "* ]]; then
  printf 'status: running\n'
  exit 0
fi

if [[ "${remote_cmd}" == *"/storage/pbs-nas/content"* ]]; then
  printf '[]\n'
  exit 0
fi

if [[ "${remote_cmd}" == *"/cluster/resources"* ]]; then
  printf '[]\n'
  exit 0
fi

if [[ "${remote_cmd}" == *"/cluster/ha/resources"* ]]; then
  printf '%s\n' "${STUB_PROXMOX_HA_RESOURCES:-[]}"
  exit 0
fi

# rebuild-cluster.sh: ssh ... "ha-manager status 2>/dev/null | grep -c 'vm:<id>'"
# The whole pipeline runs remotely; the shim must produce the count directly.
if [[ "${remote_cmd}" == *"ha-manager status"* && "${remote_cmd}" == *"grep -c"* ]]; then
  printf '%s\n' "${STUB_PBS_HA_COUNT:-0}"
  exit 0
fi

if [[ "${remote_cmd}" == *"ha-manager remove"* ]]; then
  exit 0
fi

if [[ "${remote_cmd}" == *"vzdump "* ]]; then
  printf 'TASK OK\n'
  exit 0
fi

exit 0
EOF
  chmod +x "${shim_dir}/ssh"

cat > "${shim_dir}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == -chdir=* ]]; then
  shift
fi

if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  printf '%s\n' "${STUB_REBUILD_PLAN_JSON:-{\"resource_changes\":[]}}"
  exit 0
fi

if [[ "${1:-}" == "state" && "${2:-}" == "list" ]]; then
  printf '%s' "${STUB_DIRECT_TOFU_STATE_OUTPUT:-}"
  exit 0
fi

exit 0
EOF
  chmod +x "${shim_dir}/tofu"

  cat > "${shim_dir}/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  s_client)
    cat >/dev/null
    printf 'certificate\n'
    exit 0
    ;;
  x509)
    cat >/dev/null
    exit 0
    ;;
esac

exit 0
EOF
  chmod +x "${shim_dir}/openssl"

  for shim_name in curl dig scp sops nix ssh-keygen ssh-keyscan; do
    cat > "${shim_dir}/${shim_name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
    chmod +x "${shim_dir}/${shim_name}"
  done

  cat > "${shim_dir}/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${shim_dir}/sleep"
}

run_rebuild_fixture() {
  local scenario="$1"
  local scope="$2"
  local gitlab_plan_mode="$3"
  local tofu_state_output="$4"
  local repo_dir="${TMP_DIR}/${scenario}-repo"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local output_file="${TMP_DIR}/${scenario}.out"
  local log_file="${TMP_DIR}/${scenario}.log"

  setup_fixture_repo "${repo_dir}"
  setup_shims "${shim_dir}"
  local rebuild_args=(--override-branch-check)

  if [[ -n "${scope}" ]]; then
    rebuild_args=(--scope "${scope}" "${rebuild_args[@]}")
  fi

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_LOG_FILE="${log_file}"
    export STUB_GITLAB_PLAN_MODE="${gitlab_plan_mode}"
    export STUB_TOFU_STATE_OUTPUT="${tofu_state_output}"
    export STUB_DIRECT_TOFU_STATE_OUTPUT="${tofu_state_output}"
    export STUB_REBUILD_PLAN_JSON='{"resource_changes":[]}'
    cd "${repo_dir}"
    framework/scripts/rebuild-cluster.sh "${rebuild_args[@]}"
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n%s\n' "${status}" "${output_file}" "${log_file}"
}

count_lines() {
  local pattern="$1"
  local file="$2"
  local matches
  matches="$(grep "${pattern}" "${file}" 2>/dev/null || true)"
  printf '%s\n' "${matches}" | sed '/^$/d' | wc -l | tr -d ' '
}

line_at() {
  local pattern="$1"
  local file="$2"
  local index="$3"
  local matches
  matches="$(grep "${pattern}" "${file}" 2>/dev/null || true)"
  printf '%s\n' "${matches}" | sed -n "${index}p"
}

matching_lines() {
  local pattern="$1"
  local file="$2"
  grep "${pattern}" "${file}" 2>/dev/null || true
}

BULK_ARTIFACTS="$(
  run_rebuild_fixture \
    bulk \
    'vm=testapp_dev' \
    none \
    ''
)"
BULK_STATUS="$(printf '%s\n' "${BULK_ARTIFACTS}" | sed -n '1p')"
BULK_OUTPUT_FILE="$(printf '%s\n' "${BULK_ARTIFACTS}" | sed -n '2p')"
BULK_LOG_FILE="$(printf '%s\n' "${BULK_ARTIFACTS}" | sed -n '3p')"

test_start "3.3" "bulk rebuild path completes with the HA shim fixture"
if [[ "${BULK_STATUS}" == "0" ]]; then
  test_pass "bulk rebuild fixture run exited 0"
else
  test_fail "bulk rebuild fixture run exited 0"
  printf '    output:\n%s\n' "$(cat "${BULK_OUTPUT_FILE}")" >&2
fi

BULK_APPLY_COUNT="$(count_lines '^apply ' "${BULK_LOG_FILE}")"
BULK_REFRESH_COUNT="$(count_lines '^refresh ' "${BULK_LOG_FILE}")"
BULK_FIRST_APPLY="$(line_at '^apply ' "${BULK_LOG_FILE}" 1)"
BULK_SECOND_APPLY="$(line_at '^apply ' "${BULK_LOG_FILE}" 2)"

test_start "3.4" "bulk apply path performs exactly two applies and no refresh"
if [[ "${BULK_APPLY_COUNT}" == "2" ]]; then
  test_pass "bulk rebuild path performs exactly two apply calls"
else
  test_fail "bulk rebuild path performs exactly two apply calls"
  printf '    apply log:\n%s\n' "$(matching_lines '^apply ' "${BULK_LOG_FILE}")" >&2
fi
if [[ "${BULK_REFRESH_COUNT}" == "0" ]]; then
  test_pass "bulk rebuild path does not run a standalone refresh"
else
  test_fail "bulk rebuild path does not run a standalone refresh"
  printf '    refresh log:\n%s\n' "$(matching_lines '^refresh ' "${BULK_LOG_FILE}")" >&2
fi

EXPECTED_BULK_APPLY_PHASE_1='apply -target=module.testapp_dev -auto-approve -input=false -var=start_vms=false -var=register_ha=false'
EXPECTED_BULK_APPLY_PHASE_2='apply -target=module.testapp_dev -auto-approve -input=false -var=start_vms=true -var=register_ha=true'
test_start "3.5" "bulk apply path reuses the same target set twice"
if [[ "${BULK_APPLY_COUNT}" == "2" ]] \
  && [[ "${BULK_FIRST_APPLY}" == "${EXPECTED_BULK_APPLY_PHASE_1}" ]] \
  && [[ "${BULK_SECOND_APPLY}" == "${EXPECTED_BULK_APPLY_PHASE_2}" ]]; then
  test_pass "bulk rebuild path reuses the same target set for both apply passes"
else
  test_fail "bulk rebuild path reuses the same target set for both apply passes"
  printf '    apply log:\n%s\n' "$(matching_lines '^apply ' "${BULK_LOG_FILE}")" >&2
fi

ATOMIC_ARTIFACTS="$(
  run_rebuild_fixture \
    atomic \
    'vm=gitlab' \
    prevent_destroy \
    $'module.gitlab.module.gitlab.proxmox_virtual_environment_vm.vm\nmodule.gitlab.module.gitlab.proxmox_virtual_environment_haresource.ha[0]\n'
)"
ATOMIC_STATUS="$(printf '%s\n' "${ATOMIC_ARTIFACTS}" | sed -n '1p')"
ATOMIC_OUTPUT_FILE="$(printf '%s\n' "${ATOMIC_ARTIFACTS}" | sed -n '2p')"
ATOMIC_LOG_FILE="$(printf '%s\n' "${ATOMIC_ARTIFACTS}" | sed -n '3p')"

test_start "3.6" "atomic control-plane recreate path completes with the HA shim fixture"
if [[ "${ATOMIC_STATUS}" == "0" ]]; then
  test_pass "atomic rebuild fixture run exited 0"
else
  test_fail "atomic rebuild fixture run exited 0"
  printf '    output:\n%s\n' "$(cat "${ATOMIC_OUTPUT_FILE}")" >&2
fi

ATOMIC_APPLY_COUNT="$(count_lines '^apply ' "${ATOMIC_LOG_FILE}")"
ATOMIC_REFRESH_COUNT="$(count_lines '^refresh ' "${ATOMIC_LOG_FILE}")"
ATOMIC_FIRST_APPLY="$(line_at '^apply ' "${ATOMIC_LOG_FILE}" 1)"
ATOMIC_SECOND_APPLY="$(line_at '^apply ' "${ATOMIC_LOG_FILE}" 2)"

test_start "3.7" "atomic control-plane recreate path performs exactly two applies and no refresh"
if [[ "${ATOMIC_APPLY_COUNT}" == "2" ]]; then
  test_pass "atomic rebuild path performs exactly two apply calls"
else
  test_fail "atomic rebuild path performs exactly two apply calls"
  printf '    apply log:\n%s\n' "$(matching_lines '^apply ' "${ATOMIC_LOG_FILE}")" >&2
fi
if [[ "${ATOMIC_REFRESH_COUNT}" == "0" ]]; then
  test_pass "atomic rebuild path does not run a standalone refresh"
else
  test_fail "atomic rebuild path does not run a standalone refresh"
  printf '    refresh log:\n%s\n' "$(matching_lines '^refresh ' "${ATOMIC_LOG_FILE}")" >&2
fi

EXPECTED_ATOMIC_APPLY_PHASE_1='apply -target=module.gitlab -var=start_vms=false -var=register_ha=false -auto-approve -input=false'
EXPECTED_ATOMIC_APPLY_PHASE_2='apply -target=module.gitlab -var=start_vms=true -var=register_ha=true -auto-approve -input=false'
test_start "3.8" "atomic control-plane recreate path does not hide a later third apply"
if [[ "${ATOMIC_APPLY_COUNT}" == "2" ]] \
  && [[ "${ATOMIC_FIRST_APPLY}" == "${EXPECTED_ATOMIC_APPLY_PHASE_1}" ]] \
  && [[ "${ATOMIC_SECOND_APPLY}" == "${EXPECTED_ATOMIC_APPLY_PHASE_2}" ]]; then
  test_pass "atomic rebuild path applies the gitlab target exactly twice"
else
  test_fail "atomic rebuild path applies the gitlab target exactly twice"
  printf '    apply log:\n%s\n' "$(matching_lines '^apply ' "${ATOMIC_LOG_FILE}")" >&2
fi

MIXED_FULL_ARTIFACTS="$(
  run_rebuild_fixture \
    mixed-full \
    '' \
    prevent_destroy \
    $'module.gitlab.module.gitlab.proxmox_virtual_environment_vm.vm\nmodule.gitlab.module.gitlab.proxmox_virtual_environment_haresource.ha[0]\nmodule.vault_dev.module.vault.proxmox_virtual_environment_vm.vm\n'
)"
MIXED_FULL_STATUS="$(printf '%s\n' "${MIXED_FULL_ARTIFACTS}" | sed -n '1p')"
MIXED_FULL_OUTPUT_FILE="$(printf '%s\n' "${MIXED_FULL_ARTIFACTS}" | sed -n '2p')"
MIXED_FULL_LOG_FILE="$(printf '%s\n' "${MIXED_FULL_ARTIFACTS}" | sed -n '3p')"

test_start "3.9" "mixed full rebuild path completes with one atomic control-plane recreate"
if [[ "${MIXED_FULL_STATUS}" == "0" ]]; then
  test_pass "mixed full rebuild fixture run exited 0"
else
  test_fail "mixed full rebuild fixture run exited 0"
  printf '    output:\n%s\n' "$(cat "${MIXED_FULL_OUTPUT_FILE}")" >&2
fi

MIXED_FULL_APPLY_COUNT="$(count_lines '^apply ' "${MIXED_FULL_LOG_FILE}")"
MIXED_FULL_REFRESH_COUNT="$(count_lines '^refresh ' "${MIXED_FULL_LOG_FILE}")"
MIXED_FULL_FIRST_APPLY="$(line_at '^apply ' "${MIXED_FULL_LOG_FILE}" 1)"
MIXED_FULL_SECOND_APPLY="$(line_at '^apply ' "${MIXED_FULL_LOG_FILE}" 2)"
MIXED_FULL_THIRD_APPLY="$(line_at '^apply ' "${MIXED_FULL_LOG_FILE}" 3)"
MIXED_FULL_FOURTH_APPLY="$(line_at '^apply ' "${MIXED_FULL_LOG_FILE}" 4)"

test_start "3.10" "mixed full rebuild uses two atomic applies and two filtered bulk applies"
if [[ "${MIXED_FULL_APPLY_COUNT}" == "4" ]] \
  && [[ "${MIXED_FULL_FIRST_APPLY}" == "${EXPECTED_ATOMIC_APPLY_PHASE_1}" ]] \
  && [[ "${MIXED_FULL_SECOND_APPLY}" == "${EXPECTED_ATOMIC_APPLY_PHASE_2}" ]]; then
  test_pass "mixed full rebuild keeps the atomic recreate at exactly two gitlab applies"
else
  test_fail "mixed full rebuild keeps the atomic recreate at exactly two gitlab applies"
  printf '    apply log:\n%s\n' "$(matching_lines '^apply ' "${MIXED_FULL_LOG_FILE}")" >&2
fi
if [[ "${MIXED_FULL_REFRESH_COUNT}" == "0" ]]; then
  test_pass "mixed full rebuild path does not run a standalone refresh"
else
  test_fail "mixed full rebuild path does not run a standalone refresh"
  printf '    refresh log:\n%s\n' "$(matching_lines '^refresh ' "${MIXED_FULL_LOG_FILE}")" >&2
fi

EXPECTED_MIXED_FULL_BULK_APPLY_PHASE_1='apply -target=module.cicd -target=module.pbs -target=module.testapp_dev -target=module.vault_dev -auto-approve -input=false -var=start_vms=false -var=register_ha=false'
EXPECTED_MIXED_FULL_BULK_APPLY_PHASE_2='apply -target=module.cicd -target=module.pbs -target=module.testapp_dev -target=module.vault_dev -auto-approve -input=false -var=start_vms=true -var=register_ha=true'
test_start "3.11" "mixed full rebuild derives later bulk targets from config and excludes the atomic module"
if [[ "${MIXED_FULL_THIRD_APPLY}" == "${EXPECTED_MIXED_FULL_BULK_APPLY_PHASE_1}" ]] \
  && [[ "${MIXED_FULL_FOURTH_APPLY}" == "${EXPECTED_MIXED_FULL_BULK_APPLY_PHASE_2}" ]]; then
  test_pass "mixed full rebuild bulk applies keep testapp_dev from config and exclude gitlab after atomic recreate"
else
  test_fail "mixed full rebuild bulk applies keep testapp_dev from config and exclude gitlab after atomic recreate"
  printf '    apply log:\n%s\n' "$(matching_lines '^apply ' "${MIXED_FULL_LOG_FILE}")" >&2
fi

# --- #270 regression: --scope data-plane must not silently expand to the
# whole cluster when tofu state list is empty. The resolver enumerates
# modules from configuration (framework/tofu/root/*.tf), excludes
# CONTROL_PLANE_MODULES (gitlab, cicd, pbs), and fails closed on empty
# result. Empty state is the trap-door scenario that produced #270.
DATA_PLANE_EMPTY_ARTIFACTS="$(
  run_rebuild_fixture \
    data-plane-empty \
    'data-plane' \
    none \
    ''
)"
DATA_PLANE_EMPTY_STATUS="$(printf '%s\n' "${DATA_PLANE_EMPTY_ARTIFACTS}" | sed -n '1p')"
DATA_PLANE_EMPTY_OUTPUT_FILE="$(printf '%s\n' "${DATA_PLANE_EMPTY_ARTIFACTS}" | sed -n '2p')"
DATA_PLANE_EMPTY_LOG_FILE="$(printf '%s\n' "${DATA_PLANE_EMPTY_ARTIFACTS}" | sed -n '3p')"

test_start "3.12" "--scope data-plane with empty state produces config-derived targets (#270)"
if [[ "${DATA_PLANE_EMPTY_STATUS}" == "0" ]]; then
  test_pass "--scope data-plane fixture run exited 0"
else
  test_fail "--scope data-plane fixture run exited 0"
  printf '    output:\n%s\n' "$(cat "${DATA_PLANE_EMPTY_OUTPUT_FILE}")" >&2
fi

DATA_PLANE_APPLY_COUNT="$(count_lines '^apply ' "${DATA_PLANE_EMPTY_LOG_FILE}")"
DATA_PLANE_FIRST_APPLY="$(line_at '^apply ' "${DATA_PLANE_EMPTY_LOG_FILE}" 1)"
DATA_PLANE_SECOND_APPLY="$(line_at '^apply ' "${DATA_PLANE_EMPTY_LOG_FILE}" 2)"

EXPECTED_DATA_PLANE_PHASE_1='apply -target=module.testapp_dev -target=module.vault_dev -auto-approve -input=false -var=start_vms=false -var=register_ha=false'
EXPECTED_DATA_PLANE_PHASE_2='apply -target=module.testapp_dev -target=module.vault_dev -auto-approve -input=false -var=start_vms=true -var=register_ha=true'

test_start "3.13" "--scope data-plane targets data-plane modules only and excludes control-plane"
if [[ "${DATA_PLANE_APPLY_COUNT}" == "2" ]] \
  && [[ "${DATA_PLANE_FIRST_APPLY}" == "${EXPECTED_DATA_PLANE_PHASE_1}" ]] \
  && [[ "${DATA_PLANE_SECOND_APPLY}" == "${EXPECTED_DATA_PLANE_PHASE_2}" ]]; then
  test_pass "--scope data-plane both applies target only testapp_dev + vault_dev"
else
  test_fail "--scope data-plane both applies target only testapp_dev + vault_dev"
  printf '    apply log:\n%s\n' "$(matching_lines '^apply ' "${DATA_PLANE_EMPTY_LOG_FILE}")" >&2
fi

# Belt-and-suspenders against two regression classes:
#   (a) The original #270 symptom: zero `-target` flags produces an apply
#       that targets the whole config. Asserts every apply line carries
#       `-target=` to catch that.
#   (b) Apply lines must never reference control-plane modules under
#       --scope data-plane. Catches a hypothetical regression that
#       targets the wrong modules instead of zero modules.
test_start "3.14" "--scope data-plane every apply has -target= (#270 regression class)"
DP_TARGETLESS_APPLIES="$(grep '^apply ' "${DATA_PLANE_EMPTY_LOG_FILE}" | grep -v -- '-target=' || true)"
if [[ -z "${DP_TARGETLESS_APPLIES}" ]]; then
  test_pass "--scope data-plane every apply line carries at least one -target= flag"
else
  test_fail "--scope data-plane every apply line carries at least one -target= flag"
  printf '    targetless apply lines (would apply whole config):\n%s\n' "${DP_TARGETLESS_APPLIES}" >&2
fi

DP_BAD_APPLIES=""
for cp_mod in module.gitlab module.cicd module.pbs; do
  bad="$(grep "^apply " "${DATA_PLANE_EMPTY_LOG_FILE}" | grep -- "-target=${cp_mod} \|-target=${cp_mod}$" || true)"
  if [[ -n "${bad}" ]]; then
    DP_BAD_APPLIES+="${bad}"$'\n'
  fi
done
if [[ -z "${DP_BAD_APPLIES}" ]]; then
  test_pass "--scope data-plane apply lines never carry -target=module.{gitlab,cicd,pbs}"
else
  test_fail "--scope data-plane apply lines never carry -target=module.{gitlab,cicd,pbs}"
  printf '    offending apply lines:\n%s\n' "${DP_BAD_APPLIES}" >&2
fi

# Empty-post-exclusion fail-closed path: when no .tf files declare any
# non-control-plane modules, the resolver must die rather than apply
# nothing or apply something unexpected. Build a fixture with only
# control-plane modules in main.tf and verify the run exits non-zero
# with the expected error message in the output.
DATA_PLANE_CP_ONLY_REPO="${TMP_DIR}/data-plane-cp-only-repo"
DATA_PLANE_CP_ONLY_SHIMS="${TMP_DIR}/data-plane-cp-only-shims"
DATA_PLANE_CP_ONLY_OUT="${TMP_DIR}/data-plane-cp-only.out"
DATA_PLANE_CP_ONLY_LOG="${TMP_DIR}/data-plane-cp-only.log"

setup_fixture_repo "${DATA_PLANE_CP_ONLY_REPO}"
setup_shims "${DATA_PLANE_CP_ONLY_SHIMS}"
# Overwrite main.tf with only control-plane module declarations.
cat > "${DATA_PLANE_CP_ONLY_REPO}/framework/tofu/root/main.tf" <<'EOF'
module "cicd" {
  source = "../modules/cicd"
}

module "gitlab" {
  source = "../modules/gitlab"
}

module "pbs" {
  source = "../modules/pbs"
}
EOF
"${REAL_GIT}" -C "${DATA_PLANE_CP_ONLY_REPO}" add framework/tofu/root/main.tf
"${REAL_GIT}" -C "${DATA_PLANE_CP_ONLY_REPO}" commit -m "fixture: only control-plane modules" >/dev/null

set +e
(
  export PATH="${DATA_PLANE_CP_ONLY_SHIMS}:${PATH}"
  export STUB_LOG_FILE="${DATA_PLANE_CP_ONLY_LOG}"
  export STUB_GITLAB_PLAN_MODE="none"
  export STUB_TOFU_STATE_OUTPUT=""
  export STUB_DIRECT_TOFU_STATE_OUTPUT=""
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[]}'
  cd "${DATA_PLANE_CP_ONLY_REPO}"
  framework/scripts/rebuild-cluster.sh --scope data-plane --override-branch-check
) > "${DATA_PLANE_CP_ONLY_OUT}" 2>&1
DATA_PLANE_CP_ONLY_STATUS=$?
set -e

test_start "3.15" "--scope data-plane fails closed when no non-control-plane modules exist"
if [[ "${DATA_PLANE_CP_ONLY_STATUS}" != "0" ]] \
  && grep -q 'empty target list' "${DATA_PLANE_CP_ONLY_OUT}"; then
  test_pass "--scope data-plane refuses to apply when only control-plane modules are configured"
else
  test_fail "--scope data-plane refuses to apply when only control-plane modules are configured"
  printf '    exit status: %s\n    last 20 lines of output:\n%s\n' \
    "${DATA_PLANE_CP_ONLY_STATUS}" \
    "$(tail -20 "${DATA_PLANE_CP_ONLY_OUT}")" >&2
fi

# Symlinked overrides.tf must be discovered (#270 review: sub-claude P2-1).
# `find -type f` excludes symlinks; `find -L -type f` follows them.
DATA_PLANE_SYMLINK_REPO="${TMP_DIR}/data-plane-symlink-repo"
DATA_PLANE_SYMLINK_SHIMS="${TMP_DIR}/data-plane-symlink-shims"
DATA_PLANE_SYMLINK_OUT="${TMP_DIR}/data-plane-symlink.out"
DATA_PLANE_SYMLINK_LOG="${TMP_DIR}/data-plane-symlink.log"

setup_fixture_repo "${DATA_PLANE_SYMLINK_REPO}"
setup_shims "${DATA_PLANE_SYMLINK_SHIMS}"
# Add a site overrides file with a module declaration, symlink it into
# the framework root tree (matching the real repo's overrides.tf layout).
mkdir -p "${DATA_PLANE_SYMLINK_REPO}/site/tofu"
cat > "${DATA_PLANE_SYMLINK_REPO}/site/tofu/overrides.tf" <<'EOF'
module "site_extra_dev" {
  source = "../modules/site_extra"
}
EOF
ln -s "../../../site/tofu/overrides.tf" \
  "${DATA_PLANE_SYMLINK_REPO}/framework/tofu/root/overrides.tf"
"${REAL_GIT}" -C "${DATA_PLANE_SYMLINK_REPO}" add site/tofu/overrides.tf framework/tofu/root/overrides.tf
"${REAL_GIT}" -C "${DATA_PLANE_SYMLINK_REPO}" commit -m "fixture: symlinked site overrides" >/dev/null

set +e
(
  export PATH="${DATA_PLANE_SYMLINK_SHIMS}:${PATH}"
  export STUB_LOG_FILE="${DATA_PLANE_SYMLINK_LOG}"
  export STUB_GITLAB_PLAN_MODE="none"
  export STUB_TOFU_STATE_OUTPUT=""
  export STUB_DIRECT_TOFU_STATE_OUTPUT=""
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[]}'
  cd "${DATA_PLANE_SYMLINK_REPO}"
  framework/scripts/rebuild-cluster.sh --scope data-plane --override-branch-check
) > "${DATA_PLANE_SYMLINK_OUT}" 2>&1
DATA_PLANE_SYMLINK_STATUS=$?
set -e

test_start "3.16" "--scope data-plane discovers modules via symlinked overrides.tf"
DP_SYMLINK_FIRST_APPLY="$(grep '^apply ' "${DATA_PLANE_SYMLINK_LOG}" | sed -n '1p')"
if [[ "${DATA_PLANE_SYMLINK_STATUS}" == "0" ]] \
  && [[ "${DP_SYMLINK_FIRST_APPLY}" == *"-target=module.site_extra_dev"* ]]; then
  test_pass "--scope data-plane resolves modules from symlinked overrides.tf"
else
  test_fail "--scope data-plane resolves modules from symlinked overrides.tf"
  printf '    exit status: %s\n    apply log:\n%s\n' \
    "${DATA_PLANE_SYMLINK_STATUS}" \
    "$(matching_lines '^apply ' "${DATA_PLANE_SYMLINK_LOG}")" >&2
fi

# --- #270 codex P2-2 regression: empty state must not silently deregister
# framework-managed Proxmox HA resources. Two distinct hazards:
#   (3.17) verify_ha_resources Phase 1b: with empty state, every Proxmox
#          HA VMID looked like an orphan and was removed. The fix
#          preserves any VMID listed in site/config.yaml or
#          site/applications.yaml; only true orphans (manually-added HA,
#          abandoned VMIDs) are removed.
#   (3.18) Pre-apply PBS HA cleanup (line ~777): with empty state,
#          PBS_HA_IN_STATE was 0 unconditionally, so the cleanup fired
#          and deregistered live PBS HA. The fix tightens the trigger
#          to require PBS_VM_IN_STATE > 0 — the documented
#          install-pbs.sh handoff scenario, never the empty-state case.
HA_PRESERVE_REPO="${TMP_DIR}/ha-preserve-repo"
HA_PRESERVE_SHIMS="${TMP_DIR}/ha-preserve-shims"
HA_PRESERVE_OUT="${TMP_DIR}/ha-preserve.out"
HA_PRESERVE_LOG="${TMP_DIR}/ha-preserve.log"

setup_fixture_repo "${HA_PRESERVE_REPO}"
setup_shims "${HA_PRESERVE_SHIMS}"

# Proxmox reports HA for three framework-managed VMIDs (gitlab=150,
# testapp_dev=500, vault_dev=302) plus one truly orphaned VMID (999)
# left over from a manual ha-manager add or a deleted VM.
HA_PRESERVE_PROXMOX_HA='[{"sid":"vm:150","state":"started","node":"pve01"},{"sid":"vm:500","state":"started","node":"pve01"},{"sid":"vm:302","state":"started","node":"pve01"},{"sid":"vm:999","state":"started","node":"pve01"}]'

set +e
(
  export PATH="${HA_PRESERVE_SHIMS}:${PATH}"
  export STUB_LOG_FILE="${HA_PRESERVE_LOG}"
  export STUB_GITLAB_PLAN_MODE="none"
  export STUB_TOFU_STATE_OUTPUT=""
  export STUB_DIRECT_TOFU_STATE_OUTPUT=""
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[]}'
  export STUB_PROXMOX_HA_RESOURCES="${HA_PRESERVE_PROXMOX_HA}"
  export STUB_PBS_HA_COUNT="0"
  cd "${HA_PRESERVE_REPO}"
  framework/scripts/rebuild-cluster.sh --scope data-plane --override-branch-check
) > "${HA_PRESERVE_OUT}" 2>&1
HA_PRESERVE_STATUS=$?
set -e

test_start "3.17" "verify_ha_resources Phase 1b preserves config-managed VMIDs when state is empty (#270 codex P2-2)"
HA_REMOVES="$(grep '^ssh-ha ' "${HA_PRESERVE_LOG}" | grep -- 'ha-manager remove vm:' || true)"

# Configured VMIDs (gitlab=150, testapp_dev=500, vault_dev=302) must NOT
# be removed even though state is empty.
HA_BAD_REMOVES=""
for protected_vmid in 150 500 302; do
  if echo "${HA_REMOVES}" | grep -q "ha-manager remove vm:${protected_vmid}\b"; then
    HA_BAD_REMOVES+="vm:${protected_vmid} "
  fi
done

# True orphan (999, not in config) must be removed.
HA_ORPHAN_REMOVED="false"
if echo "${HA_REMOVES}" | grep -q 'ha-manager remove vm:999\b'; then
  HA_ORPHAN_REMOVED="true"
fi

if [[ "${HA_PRESERVE_STATUS}" == "0" && -z "${HA_BAD_REMOVES}" && "${HA_ORPHAN_REMOVED}" == "true" ]]; then
  test_pass "Phase 1b preserves config-managed VMIDs and removes only the true orphan"
else
  test_fail "Phase 1b preserves config-managed VMIDs and removes only the true orphan"
  printf '    exit status: %s\n    bad removes (config-managed VMIDs that should have been preserved): %s\n    orphan removed: %s\n    full ha-manager log:\n%s\n' \
    "${HA_PRESERVE_STATUS}" \
    "${HA_BAD_REMOVES:-(none)}" \
    "${HA_ORPHAN_REMOVED}" \
    "${HA_REMOVES}" >&2
fi

# Test 3.18: PBS HA cleanup must NOT fire when state is empty.
PBS_PRESERVE_REPO="${TMP_DIR}/pbs-preserve-repo"
PBS_PRESERVE_SHIMS="${TMP_DIR}/pbs-preserve-shims"
PBS_PRESERVE_OUT="${TMP_DIR}/pbs-preserve.out"
PBS_PRESERVE_LOG="${TMP_DIR}/pbs-preserve.log"

setup_fixture_repo "${PBS_PRESERVE_REPO}"
setup_shims "${PBS_PRESERVE_SHIMS}"

set +e
(
  export PATH="${PBS_PRESERVE_SHIMS}:${PATH}"
  export STUB_LOG_FILE="${PBS_PRESERVE_LOG}"
  export STUB_GITLAB_PLAN_MODE="none"
  # Empty tofu state is the #270 hazard: PBS_VM_IN_STATE = 0.
  export STUB_TOFU_STATE_OUTPUT=""
  export STUB_DIRECT_TOFU_STATE_OUTPUT=""
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[]}'
  # Proxmox HA list does not include PBS — keep Phase 1b out of the way
  # so this test isolates the pre-apply PBS HA cleanup block.
  export STUB_PROXMOX_HA_RESOURCES='[]'
  # PBS is registered in Proxmox HA — without the empty-state guard, the
  # cleanup would fire and ha-manager remove vm:190 would be issued.
  export STUB_PBS_HA_COUNT="1"
  cd "${PBS_PRESERVE_REPO}"
  framework/scripts/rebuild-cluster.sh --scope data-plane --override-branch-check
) > "${PBS_PRESERVE_OUT}" 2>&1
PBS_PRESERVE_STATUS=$?
set -e

test_start "3.18" "Pre-apply PBS HA cleanup is skipped when state is empty (#270 codex P2-2)"
PBS_REMOVES="$(grep '^ssh-ha ' "${PBS_PRESERVE_LOG}" | grep -- 'ha-manager remove vm:190' || true)"
if [[ "${PBS_PRESERVE_STATUS}" == "0" && -z "${PBS_REMOVES}" ]]; then
  test_pass "PBS HA cleanup does not deregister vm:190 when state is wiped"
else
  test_fail "PBS HA cleanup does not deregister vm:190 when state is wiped"
  printf '    exit status: %s\n    unexpected ha-manager remove vm:190 calls:\n%s\n' \
    "${PBS_PRESERVE_STATUS}" \
    "${PBS_REMOVES}" >&2
fi

# --- #132 regression: rebuild ordering invariant (test-only MR).
# restore-before-start.sh must run between every stopped apply
# (-var=start_vms=false) and every subsequent start-capable apply.
# #132 was the pre-Sprint-031 hazard: the full rebuild started VMs
# (which formatted empty vdb) before any restore happened, then
# scheduled PBS backups captured the empty state and overwrote the
# previous good "latest" backup. Sprint 031 fixed it by inserting
# restore-before-start.sh between Phase 1 and Phase 2 in both atomic
# and bulk recreate paths. tests/test_rebuild_preboot_restore.sh
# (17.2) and tests/test_rebuild_pbs_install_before_preboot_restore.sh
# (31.B.2) already pin the same invariant on the scoped and full
# rebuild paths via strict-equality matching. The assertions below
# add coverage on the HA-flow fixtures (mixed scope, control-plane
# prevent_destroy, full mixed) using a flexible per-pair matcher
# robust to future flag/format drift.
#
# Per-pair invariant: walking the log in order, every start-capable
# apply (anything matching `^apply ` whose argv does NOT contain
# `-var=start_vms=false`) must be preceded by at least one
# `^restore-before-start.sh ` line since the most recent
# `-var=start_vms=false` apply. This catches a regression in any
# recreate pair, not just the first one — a sequence like
# `atomic-stopped → atomic-restore → atomic-start → bulk-stopped →
# bulk-start` (bulk restore missing) would fail at bulk-start.

assert_rebuild_restore_pairs() {
  local label="$1"
  local log_file="$2"
  local last_stopped="" restore_since_stopped=0
  local violations=()
  local lineno content

  while IFS=: read -r lineno content; do
    [[ -z "${lineno}" ]] && continue
    if [[ "${content}" == "apply "* ]]; then
      if [[ "${content}" == *"-var=start_vms=false"* ]]; then
        last_stopped="${lineno}"
        restore_since_stopped=0
      else
        if (( restore_since_stopped == 0 )); then
          if [[ -n "${last_stopped}" ]]; then
            violations+=("start-capable apply at line ${lineno} not preceded by restore-before-start.sh since stopped apply at line ${last_stopped}")
          else
            violations+=("start-capable apply at line ${lineno} appears before any stopped apply / restore")
          fi
        fi
      fi
    elif [[ "${content}" == "restore-before-start.sh "* ]]; then
      restore_since_stopped=1
    fi
  done < <(grep -nE '^(apply |restore-before-start\.sh )' "${log_file}" 2>/dev/null)

  if (( ${#violations[@]} == 0 )); then
    # Count how many apply pairs we actually verified, for visibility.
    local stopped_count start_count restore_count
    stopped_count="$(grep -c -- '^apply .*-var=start_vms=false' "${log_file}" 2>/dev/null || echo 0)"
    start_count="$(grep -E '^apply ' "${log_file}" 2>/dev/null | grep -vc -- '-var=start_vms=false' || echo 0)"
    restore_count="$(grep -c '^restore-before-start.sh ' "${log_file}" 2>/dev/null || echo 0)"
    test_pass "${label}: ${start_count} start-capable apply(s) all preceded by restore (stopped=${stopped_count}, restore=${restore_count})"
    return 0
  fi
  test_fail "${label}: ${#violations[@]} ordering violation(s)"
  for v in "${violations[@]}"; do
    printf '    %s\n' "${v}" >&2
  done
  printf '    relevant log lines:\n' >&2
  grep -nE '^(apply |restore-before-start\.sh )' "${log_file}" 2>/dev/null \
    | sed 's/^/      /' >&2
  return 1
}

test_start "3.19" "bulk path: every start-capable apply preceded by restore (#132)"
assert_rebuild_restore_pairs "bulk" "${BULK_LOG_FILE}" || true

test_start "3.20" "atomic path: every start-capable apply preceded by restore (#132)"
assert_rebuild_restore_pairs "atomic" "${ATOMIC_LOG_FILE}" || true

# Mixed-full produces two recreate pairs (atomic + bulk). The per-pair
# matcher catches a regression confined to either pair — including the
# bulk pair, which the original first-occurrence helper missed.
test_start "3.21" "mixed-full path: every start-capable apply preceded by restore (#132)"
assert_rebuild_restore_pairs "mixed-full" "${MIXED_FULL_LOG_FILE}" || true

# --- #132 failure mode #2: backup-job configuration ordering.
# The original incident chain: backup jobs were created/refreshed for
# empty-vdb VMs during the rebuild, then scheduled jobs ran on the
# stopped/empty VMs and overwrote the previous good "latest" backups
# with empty-state captures. Sprint 031 + the existing converge order
# put `configure-backups.sh` (and any non-skipped `configure-pbs.sh`)
# AFTER the preboot restore. This test pins that ordering: no
# backup-job-creating command may appear in the log before the first
# restore-before-start.sh invocation. Calls to `configure-pbs.sh
# --skip-backup-jobs` are allowed before restore (they install/
# configure PBS without touching the backup schedule).

assert_no_backup_config_before_restore() {
  local label="$1"
  local log_file="$2"
  local first_restore
  first_restore="$(grep -n '^restore-before-start.sh ' "${log_file}" 2>/dev/null \
    | head -1 | cut -d: -f1)"
  if [[ -z "${first_restore}" ]]; then
    test_fail "${label}: no restore-before-start.sh invocation found"
    return 1
  fi

  local violations=()
  local lineno content
  while IFS=: read -r lineno content; do
    [[ -z "${lineno}" ]] && continue
    (( lineno >= first_restore )) && continue
    if [[ "${content}" == "configure-backups.sh "* ]]; then
      violations+=("configure-backups.sh at line ${lineno} appears before first restore at line ${first_restore}")
    elif [[ "${content}" == "configure-pbs.sh "* ]]; then
      if [[ "${content}" != *"--skip-backup-jobs"* ]]; then
        violations+=("configure-pbs.sh at line ${lineno} (no --skip-backup-jobs) appears before first restore at line ${first_restore}")
      fi
    fi
  done < <(grep -nE '^(configure-backups\.sh |configure-pbs\.sh )' "${log_file}" 2>/dev/null)

  if (( ${#violations[@]} == 0 )); then
    test_pass "${label}: no backup-job configuration before first restore (line ${first_restore})"
    return 0
  fi
  test_fail "${label}: ${#violations[@]} backup-config-before-restore violation(s)"
  for v in "${violations[@]}"; do
    printf '    %s\n' "${v}" >&2
  done
  printf '    relevant log lines:\n' >&2
  grep -nE '^(restore-before-start\.sh |configure-backups\.sh |configure-pbs\.sh )' "${log_file}" 2>/dev/null \
    | sed 's/^/      /' >&2
  return 1
}

test_start "3.22" "no configure-backups / non-skip configure-pbs before restore (#132 failure mode #2)"
assert_no_backup_config_before_restore "bulk" "${BULK_LOG_FILE}" || true
assert_no_backup_config_before_restore "atomic" "${ATOMIC_LOG_FILE}" || true
assert_no_backup_config_before_restore "mixed-full" "${MIXED_FULL_LOG_FILE}" || true

runner_summary
