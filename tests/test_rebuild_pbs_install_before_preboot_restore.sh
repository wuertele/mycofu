#!/usr/bin/env bash
# test_rebuild_pbs_install_before_preboot_restore.sh — full rebuild configures PBS before preboot restore.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

REAL_GIT="$(command -v git)"
REAL_YQ="$(command -v yq)"

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
EVENT_LOG="${TMP_DIR}/events.log"
OUTPUT_FILE="${TMP_DIR}/rebuild.out"

make_noop_script() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${path}"
}

mkdir -p \
  "${FIXTURE_REPO}/framework/scripts" \
  "${FIXTURE_REPO}/framework/tofu/root" \
  "${FIXTURE_REPO}/site/sops" \
  "${FIXTURE_REPO}/build" \
  "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" \
  "${FIXTURE_REPO}/framework/scripts/rebuild-cluster.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/rebuild-cluster.sh"

cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
module "pbs" {
  source = "../modules/pbs"
}

module "vault_dev" {
  source = "../modules/vault"
}
EOF

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
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
    ip: 10.0.0.20
    backup: false
  pbs:
    vmid: 100
    ip: 10.0.0.30
    backup: false
  vault_dev:
    vmid: 302
    ip: 10.0.0.21
    backup: true
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

printf 'dummy: value\n' > "${FIXTURE_REPO}/site/sops/secrets.yaml"
printf 'age1dummy\n' > "${FIXTURE_REPO}/operator.age.key"

cat > "${FIXTURE_REPO}/framework/scripts/converge-lib.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
converge_run_all() { :; }
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/converge-lib.sh"

cat > "${FIXTURE_REPO}/framework/scripts/git-deploy-context.sh" <<'EOF'
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
write_deploy_manifest() { :; }
print_post_dr_reconciliation_instructions() { :; }
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/git-deploy-context.sh"

cat > "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
certbot_cluster_staging_override_targets() { return 0; }
certbot_cluster_expected_mode() { echo "staging"; }
certbot_cluster_expected_url() { echo "https://staging.invalid/directory"; }
certbot_cluster_prod_shared_backup_certbot_records() { return 0; }
certbot_cluster_run_remote_helper() { return 0; }
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh"

cat > "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${EVENT_LOG}"
case "${1:-}" in
  init)
    exit 0
  ;;
  state)
    if [[ "${2:-}" == "list" ]]; then
      printf '%s\n' \
        'module.pbs.proxmox_virtual_environment_vm.vm' \
        'module.pbs.proxmox_virtual_environment_haresource.ha[0]'
      exit 0
    fi
    if [[ "${2:-}" == "show" ]]; then
      printf 'resource_id = "vm:100"\n'
      exit 0
    fi
    if [[ "${2:-}" == "rm" ]]; then
      exit 0
    fi
    ;;
  plan)
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
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

cat > "${FIXTURE_REPO}/framework/scripts/install-pbs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install-pbs.sh\n' >> "${EVENT_LOG}"
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/install-pbs.sh"

cat > "${FIXTURE_REPO}/framework/scripts/configure-pbs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'configure-pbs.sh %s\n' "$*" >> "${EVENT_LOG}"
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/configure-pbs.sh"

cat > "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-before-start.sh %s\n' "$*" >> "${EVENT_LOG}"
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"

for script_name in \
  recover-secrets.sh \
  verify-nas-prereqs.sh \
  configure-node-network.sh \
  configure-node-storage.sh \
  form-cluster.sh \
  configure-storage.sh \
  build-all-images.sh \
  ensure-app-secrets.sh \
  generate-gatus-config.sh \
  backup-now.sh \
  init-vault.sh \
  configure-vault.sh \
  cert-storage-backfill.sh \
  configure-replication.sh \
  configure-gitlab.sh \
  register-runner.sh \
  configure-sentinel-gatus.sh \
  configure-backups.sh \
  configure-metrics.sh \
  configure-dashboard-tokens.sh \
  deploy-workstation-closure.sh \
  validate.sh
do
  make_noop_script "${FIXTURE_REPO}/framework/scripts/${script_name}"
done

cat > "${SHIM_DIR}/ping" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "${SHIM_DIR}/ping"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
remote_cmd="${*: -1}"

if [[ "${remote_cmd}" == "true" ]]; then
  exit 0
fi
if [[ "${remote_cmd}" == *"psql -U postgres"* ]]; then
  printf 'tofu_state\n'
  exit 0
fi
if [[ "${remote_cmd}" == *"ha-manager status"* && "${remote_cmd}" == *"grep -c"* ]]; then
  printf '0\n'
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
if [[ "${remote_cmd}" == *"/cluster/resources --type vm"* ]]; then
  printf '%s\n' '[{"vmid":302,"node":"pve01"}]'
  exit 0
fi
if [[ "${remote_cmd}" == *"/cluster/resources"* || "${remote_cmd}" == *"/cluster/ha/resources"* ]]; then
  printf '[]\n'
  exit 0
fi
if [[ "${remote_cmd}" == *"cat /run/secrets/network/search-domain"* ]]; then
  printf 'dev.example.test\n'
  exit 0
fi
if [[ "${remote_cmd}" == *"vzdump 302 --storage pbs-nas --mode snapshot --compress zstd"* ]]; then
  printf 'TASK OK\n'
  exit 0
fi
exit 0
EOF
chmod +x "${SHIM_DIR}/ssh"

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -chdir=* ]] && shift
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  printf '%s\n' '{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true}}}]}'
  exit 0
fi
exit 0
EOF
chmod +x "${SHIM_DIR}/tofu"

cat > "${SHIM_DIR}/yq" <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec "${REAL_YQ}" "\$@"
EOF
chmod +x "${SHIM_DIR}/yq"

for shim_name in curl dig scp sops nix openssl ssh-keygen ssh-keyscan sshpass sleep; do
  make_noop_script "${SHIM_DIR}/${shim_name}"
done

"${REAL_GIT}" -C "${FIXTURE_REPO}" init -b dev >/dev/null
"${REAL_GIT}" -C "${FIXTURE_REPO}" config user.name "Test Runner"
"${REAL_GIT}" -C "${FIXTURE_REPO}" config user.email "tests@example.invalid"
"${REAL_GIT}" -C "${FIXTURE_REPO}" add .
"${REAL_GIT}" -C "${FIXTURE_REPO}" commit -m "fixture" >/dev/null

set +e
(
  export PATH="${SHIM_DIR}:${PATH}"
  export EVENT_LOG
  cd "${FIXTURE_REPO}"
  framework/scripts/rebuild-cluster.sh --override-branch-check
) >"${OUTPUT_FILE}" 2>&1
RC=$?
set -e

test_start "31.B.1" "full rebuild fixture exits successfully"
if [[ "${RC}" == "0" ]]; then
  test_pass "full rebuild fixture exited 0"
else
  test_fail "full rebuild fixture exited 0"
  printf 'output:\n%s\nlog:\n%s\n' "$(cat "${OUTPUT_FILE}")" "$(cat "${EVENT_LOG}" 2>/dev/null || true)" >&2
fi

ORDER="$(grep -E '^(apply |install-pbs\.sh|configure-pbs\.sh|restore-before-start\.sh)' "${EVENT_LOG}" \
  | sed -E 's/ --manifest [^ ]+/ --manifest <manifest>/' \
  | sed -n '1,5p')"
EXPECTED=$'apply -auto-approve -input=false -var=start_vms=false -var=register_ha=false\ninstall-pbs.sh\nconfigure-pbs.sh --skip-backup-jobs\nrestore-before-start.sh all --manifest <manifest>\napply -auto-approve -input=false -var=start_vms=true -var=register_ha=true'

test_start "31.B.2" "PBS install/configure runs between stopped apply and preboot restore"
if [[ "${ORDER}" == "${EXPECTED}" ]]; then
  test_pass "full rebuild orders Phase 1, PBS configure, preboot restore, Phase 2"
else
  test_fail "unexpected full rebuild PBS/preboot ordering"
  printf 'expected:\n%s\nactual:\n%s\nfull log:\n%s\noutput:\n%s\n' \
    "${EXPECTED}" "${ORDER}" "$(cat "${EVENT_LOG}")" "$(cat "${OUTPUT_FILE}")" >&2
fi

runner_summary
