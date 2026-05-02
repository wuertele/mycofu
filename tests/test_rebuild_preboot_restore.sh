#!/usr/bin/env bash
# test_rebuild_preboot_restore.sh — rebuild-cluster Phase 1 -> restore -> Phase 2.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

REAL_GIT="$(command -v git)"
REAL_YQ="$(command -v yq)"

make_noop_script() {
  local path="$1"
  cat > "${path}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${path}"
}

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
EVENT_LOG="${TMP_DIR}/events.log"
OUTPUT_FILE="${TMP_DIR}/rebuild.out"

mkdir -p \
  "${FIXTURE_REPO}/framework/scripts" \
  "${FIXTURE_REPO}/framework/tofu/root" \
  "${FIXTURE_REPO}/site/sops" \
  "${FIXTURE_REPO}/build" \
  "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" "${FIXTURE_REPO}/framework/scripts/rebuild-cluster.sh"
cp "${REPO_ROOT}/framework/scripts/restore-before-start.sh" "${FIXTURE_REPO}/framework/scripts/restore-before-start.real.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/rebuild-cluster.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.real.sh"

cat > "${FIXTURE_REPO}/framework/scripts/converge-lib.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
converge_run_all() { :; }
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/converge-lib.sh"

cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
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
    backup: true
  vault_dev:
    vmid: 302
    ip: 10.0.0.21
    backup: true
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${FIXTURE_REPO}/build/restore-pin-reset.json" <<'EOF'
{
  "version": 1,
  "captured_at": "2026-04-15T13:20:00Z",
  "pins": {
    "302": "pbs-nas:backup/vm/302/2026-04-12T18:30:00Z"
  }
}
EOF

printf 'dummy: value\n' > "${FIXTURE_REPO}/site/sops/secrets.yaml"
printf 'age1dummy\n' > "${FIXTURE_REPO}/operator.age.key"

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
printf 'tofu-wrapper %s\n' "$*" >> "${EVENT_LOG}"
case "${1:-}" in
  init)
    exit 0
    ;;
  state)
    if [[ "${2:-}" == "list" || "${2:-}" == "rm" || "${2:-}" == "show" ]]; then
      exit 0
    fi
    ;;
  plan)
    if [[ " $* " == *" -detailed-exitcode "* ]] &&
       [[ -n "${STUB_PREVENT_DESTROY_MODULE:-}" ]] &&
       [[ " $* " == *" -target=${STUB_PREVENT_DESTROY_MODULE} "* ]]; then
      echo "Instance cannot be destroyed" >&2
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
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

cat > "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
manifest=""
args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      manifest="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'restore-before-start.sh %s\n' "${args[*]}" >> "${EVENT_LOG}"
if [[ -n "$manifest" ]]; then
  printf 'manifest %s\n' "$(jq -c . "$manifest")" >> "${EVENT_LOG}"
fi
if [[ "${STUB_REAL_RESTORE_BEFORE_START:-0}" == "1" ]]; then
  exec "$(cd "$(dirname "$0")" && pwd)/restore-before-start.real.sh" "${args[@]}"
fi
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
  install-pbs.sh \
  configure-pbs.sh \
  restore-from-pbs.sh \
  init-vault.sh \
  configure-vault.sh \
  configure-replication.sh \
  configure-gitlab.sh \
  register-runner.sh \
  configure-sentinel-gatus.sh \
  configure-backups.sh \
  configure-metrics.sh \
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
if [[ "${remote_cmd}" == *"/cluster/resources --type vm"* ]]; then
  printf '%s\n' '[{"vmid":150,"node":"pve01"},{"vmid":302,"node":"pve01"}]'
  exit 0
fi
if [[ "${remote_cmd}" == "pvesm status 2>/dev/null" ]]; then
  printf '%s\n' "${STUB_PVESM_STATUS:-pbs-nas active}"
  exit 0
fi
if [[ "${remote_cmd}" == *"/cluster/resources"* || "${remote_cmd}" == *"/cluster/ha/resources"* ]]; then
  printf '[]\n'
  exit 0
fi
if [[ "${remote_cmd}" == *"/storage/pbs-nas/content"* ]]; then
  printf '[]\n'
  exit 0
fi
if [[ "${remote_cmd}" == *"cat /run/secrets/network/search-domain"* ]]; then
  printf 'dev.example.test\n'
  exit 0
fi
if [[ "${remote_cmd}" == *"/var/lib/vault"* && "${remote_cmd}" == *"lost+found"* ]]; then
  exit 1
fi
if [[ "${remote_cmd}" == *"qm status "* && "${remote_cmd}" == *"awk '{print \$2}'"* ]]; then
  printf 'stopped\n'
  exit 0
fi
if [[ "${remote_cmd}" == *"qm status "* ]]; then
  printf 'status: running\n'
  exit 0
fi
if [[ "${remote_cmd}" == *"vzdump 302 --storage pbs-nas --mode snapshot --compress zstd"* ]]; then
  printf 'TASK OK\n'
  exit 0
fi
if [[ "${remote_cmd}" == *"vzdump 150 --storage pbs-nas --mode snapshot --compress zstd"* ]]; then
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
  printf '%s\n' "${STUB_REBUILD_PLAN_JSON:-{\"resource_changes\":[]}}"
  exit 0
fi
exit 0
EOF
chmod +x "${SHIM_DIR}/tofu"

cat > "${SHIM_DIR}/yq" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "\${STUB_YQ_FAIL:-}" ]]; then
  echo "stub yq failure" >&2
  exit 32
fi
exec "${REAL_YQ}" "\$@"
EOF
chmod +x "${SHIM_DIR}/yq"

for shim_name in curl dig scp sops nix openssl ssh-keygen ssh-keyscan sleep; do
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
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true}}}]}'
  cd "${FIXTURE_REPO}"
  framework/scripts/rebuild-cluster.sh \
    --scope vm=vault_dev \
    --restore-pin-file build/restore-pin-reset.json \
    --override-branch-check
) > "${OUTPUT_FILE}" 2>&1
RC=$?
set -e

test_start "17.1" "rebuild fixture exits successfully"
if [[ "$RC" == "0" ]]; then
  test_pass "rebuild-cluster fixture exited 0"
else
  test_fail "rebuild-cluster fixture exited 0"
  printf 'output:\n%s\n' "$(cat "$OUTPUT_FILE")" >&2
fi

test_start "17.2" "scoped rebuild orders stopped apply, preboot restore, start apply"
ORDER="$(grep -E '^(tofu-wrapper apply|restore-before-start.sh)' "$EVENT_LOG" | sed -E 's/ --manifest [^ ]+/ --manifest <manifest>/')"
EXPECTED=$'tofu-wrapper apply -target=module.vault_dev -auto-approve -input=false -var=start_vms=false -var=register_ha=false\nrestore-before-start.sh all --manifest <manifest> --pin-file '"${FIXTURE_REPO}"$'/build/restore-pin-reset.json\ntofu-wrapper apply -target=module.vault_dev -auto-approve -input=false -var=start_vms=true -var=register_ha=true'
if [[ "$ORDER" == "$EXPECTED" ]]; then
  test_pass "rebuild-cluster runs Phase 1, restore-before-start, Phase 2"
else
  test_fail "unexpected rebuild preboot order"
  printf 'order:\n%s\nfull log:\n%s\noutput:\n%s\n' "$ORDER" "$(cat "$EVENT_LOG")" "$(cat "$OUTPUT_FILE")" >&2
fi

test_start "17.3" "restore manifest uses all scope and includes the scoped VM pin"
if grep -Fq '"scope":"all"' "$EVENT_LOG" &&
   grep -Fq '"label":"vault_dev"' "$EVENT_LOG" &&
   grep -Fq '"pin":"pbs-nas:backup/vm/302/2026-04-12T18:30:00Z"' "$EVENT_LOG"; then
  test_pass "rebuild manifest carries all scope, label, and pin"
else
  test_fail "rebuild manifest missing expected scope, label, or pin"
  cat "$EVENT_LOG" >&2
fi

test_start "17.4" "no-op plan emits no restore entries for healthy selected VM"
: > "$EVENT_LOG"
set +e
(
  export PATH="${SHIM_DIR}:${PATH}"
  export EVENT_LOG
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"started":true},"after":{"started":true}}}]}'
  cd "${FIXTURE_REPO}"
  framework/scripts/rebuild-cluster.sh \
    --scope vm=vault_dev \
    --restore-pin-file build/restore-pin-reset.json \
    --override-branch-check
) > "${TMP_DIR}/rebuild-noop.out" 2>&1
NOOP_RC=$?
set -e
if [[ "$NOOP_RC" == "0" ]] &&
   grep -Fq '"entries":[]' "$EVENT_LOG" &&
   ! grep -Fq '"label":"vault_dev"' "$EVENT_LOG"; then
  test_pass "plan-derived rebuild manifest excludes in-place updates"
else
  test_fail "no-op/in-place plan should not request vdb restore"
  printf 'rc=%s\nlog:\n%s\noutput:\n%s\n' "$NOOP_RC" "$(cat "$EVENT_LOG")" "$(cat "${TMP_DIR}/rebuild-noop.out")" >&2
fi

test_start "17.5" "config parse failure exits before stopped apply"
: > "$EVENT_LOG"
set +e
(
  export PATH="${SHIM_DIR}:${PATH}"
  export EVENT_LOG
  export STUB_YQ_FAIL=1
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"]}}]}'
  cd "${FIXTURE_REPO}"
  framework/scripts/rebuild-cluster.sh \
    --scope vm=vault_dev \
    --restore-pin-file build/restore-pin-reset.json \
    --override-branch-check
) > "${TMP_DIR}/rebuild-yq-fail.out" 2>&1
YQ_FAIL_RC=$?
set -e
if [[ "$YQ_FAIL_RC" != "0" ]] &&
   [[ "$(grep -c '^tofu-wrapper apply' "$EVENT_LOG" || true)" == "0" ]]; then
  test_pass "rebuild-cluster fails before stopped apply on config parse errors"
else
  test_fail "rebuild-cluster did not fail closed on config parse error"
  printf 'rc=%s\nlog:\n%s\noutput:\n%s\n' "$YQ_FAIL_RC" "$(cat "$EVENT_LOG")" "$(cat "${TMP_DIR}/rebuild-yq-fail.out")" >&2
fi

test_start "17.6" "rebuild proceeds to start apply when PBS is absent and first-deploy approval covers manifest"
: > "$EVENT_LOG"
set +e
(
  export PATH="${SHIM_DIR}:${PATH}"
  export EVENT_LOG
  export STUB_REAL_RESTORE_BEFORE_START=1
  export STUB_PVESM_STATUS='local active'
  export FIRST_DEPLOY_ALLOW_VMIDS=302
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true}}}]}'
  cd "${FIXTURE_REPO}"
  framework/scripts/rebuild-cluster.sh \
    --scope vm=vault_dev \
    --override-branch-check
) > "${TMP_DIR}/rebuild-no-pbs-approved.out" 2>&1
NO_PBS_RC=$?
set -e
if [[ "$NO_PBS_RC" == "0" ]] &&
   grep -Fq 'start_vms=true' "$EVENT_LOG" &&
   ! grep -Fq 'restore-from-pbs.sh' "$EVENT_LOG" &&
   grep -Fq '"label":"vault_dev"' "$EVENT_LOG"; then
  test_pass "rebuild preboot restore allows explicit first deploy when PBS is known absent"
else
  test_fail "rebuild should reach start apply with known-absent PBS and approval"
  printf 'rc=%s\nlog:\n%s\noutput:\n%s\n' \
    "$NO_PBS_RC" "$(cat "$EVENT_LOG")" "$(cat "${TMP_DIR}/rebuild-no-pbs-approved.out")" >&2
fi

test_start "17.7" "atomic rebuild manifest includes create after state removal"
: > "$EVENT_LOG"
set +e
(
  export PATH="${SHIM_DIR}:${PATH}"
  export EVENT_LOG
  export STUB_PREVENT_DESTROY_MODULE=module.gitlab
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[{"address":"module.gitlab.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true}}},{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"started":true},"after":{"started":true}}}]}'
  cd "${FIXTURE_REPO}"
  framework/scripts/rebuild-cluster.sh \
    --scope vm=gitlab \
    --override-branch-check
) > "${TMP_DIR}/rebuild-atomic-create.out" 2>&1
ATOMIC_CREATE_RC=$?
set -e
if [[ "$ATOMIC_CREATE_RC" == "0" ]] &&
   grep -Fq 'preboot-restore-atomic-gitlab.json' "$EVENT_LOG" &&
   grep -Fq '"label":"gitlab"' "$EVENT_LOG" &&
   grep -Fq '"reason":"create"' "$EVENT_LOG" &&
   ! grep -Fq '"label":"vault_dev"' "$EVENT_LOG"; then
  test_pass "atomic manifest includes selected create and excludes unrelated in-place plan entries"
else
  test_fail "atomic create manifest membership is wrong"
  printf 'rc=%s\nlog:\n%s\noutput:\n%s\n' \
    "$ATOMIC_CREATE_RC" "$(cat "$EVENT_LOG")" "$(cat "${TMP_DIR}/rebuild-atomic-create.out")" >&2
fi

test_start "17.8" "atomic rebuild manifest excludes in-place actions"
: > "$EVENT_LOG"
set +e
(
  export PATH="${SHIM_DIR}:${PATH}"
  export EVENT_LOG
  export STUB_PREVENT_DESTROY_MODULE=module.gitlab
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[{"address":"module.gitlab.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"started":true},"after":{"started":true}}}]}'
  cd "${FIXTURE_REPO}"
  framework/scripts/rebuild-cluster.sh \
    --scope vm=gitlab \
    --override-branch-check
) > "${TMP_DIR}/rebuild-atomic-inplace.out" 2>&1
ATOMIC_INPLACE_RC=$?
set -e
if [[ "$ATOMIC_INPLACE_RC" == "0" ]] &&
   grep -Fq '"entries":[]' "$EVENT_LOG" &&
   ! grep -Fq '"label":"gitlab"' "$EVENT_LOG"; then
  test_pass "atomic manifest excludes in-place update actions"
else
  test_fail "atomic in-place plan should not request vdb restore"
  printf 'rc=%s\nlog:\n%s\noutput:\n%s\n' \
    "$ATOMIC_INPLACE_RC" "$(cat "$EVENT_LOG")" "$(cat "${TMP_DIR}/rebuild-atomic-inplace.out")" >&2
fi

runner_summary
