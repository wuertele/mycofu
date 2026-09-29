#!/usr/bin/env bash
# test_rebuild_preboot_restore.sh — rebuild-cluster Phase 1 -> restore -> Phase 2.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# Sprint 039: fixture FIXTURE_REPO doesn't ship vm-scope.sh; use the real one.
# Pin yq too because tests can shim PATH later.
export VM_SCOPE_SCRIPT="${REPO_ROOT}/framework/scripts/vm-scope.sh"
export VM_SCOPE_YQ_BIN="$(command -v yq)"  # SHIM_DIR yq override bypass for vm-scope.sh

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/rebuild_fixture_helpers.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

REAL_GIT="$(command -v git)"
REAL_YQ="$(command -v yq)"

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
EVENT_LOG="${TMP_DIR}/events.log"
OUTPUT_FILE="${TMP_DIR}/rebuild.out"

mkdir -p \
  "${FIXTURE_REPO}/framework/scripts" \
  "${FIXTURE_REPO}/framework/scripts/lib" \
  "${FIXTURE_REPO}/framework/tofu/root" \
  "${FIXTURE_REPO}/site/sops" \
  "${FIXTURE_REPO}/build" \
  "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" "${FIXTURE_REPO}/framework/scripts/rebuild-cluster.sh"
# #701: rebuild-cluster.sh no longer sources github-publish-lib.sh or
# pre-resolves the gatus source commit — it defers to generate-gatus-config.sh,
# so no resolver stub is needed. That generator is stubbed with NON-EMPTY
# output because step 7 now fails closed on an empty gatus config (-s, #704).
cat > "${FIXTURE_REPO}/framework/scripts/generate-gatus-config.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo 'endpoints: []'
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/generate-gatus-config.sh"
cp "${REPO_ROOT}/framework/scripts/restore-before-start.sh" "${FIXTURE_REPO}/framework/scripts/restore-before-start.real.sh"
cp "${REPO_ROOT}/framework/scripts/vm-scope.sh" "${FIXTURE_REPO}/framework/scripts/vm-scope.sh"
cp "${REPO_ROOT}/framework/scripts/vm-topology-lib.sh" "${FIXTURE_REPO}/framework/scripts/vm-topology-lib.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
cp "${REPO_ROOT}/framework/scripts/aggregate-preboot-status.sh" "${FIXTURE_REPO}/framework/scripts/aggregate-preboot-status.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/aggregate-preboot-status.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/rebuild-cluster.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.real.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/vm-scope.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/vm-topology-lib.sh"

cat > "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
converge_incomplete_vm() {
  printf 'converge-incomplete-vm %s\n' "$*" >> "${EVENT_LOG}"
  return 0
}
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh"

cat > "${FIXTURE_REPO}/framework/images.yaml" <<'EOF'
roles:
  vault:
    category: nix
    host_config: site/nix/hosts/vault.nix
    scope: env-bound
    control_plane: false
  gitlab:
    category: nix
    host_config: site/nix/hosts/gitlab.nix
    scope: prod-only
    control_plane: true
  cicd:
    category: nix
    host_config: site/nix/hosts/cicd.nix
    scope: shared
    control_plane: true
non_built_roles:
  pbs:
    category: vendor
    scope: shared
    control_plane: true
EOF

cat > "${FIXTURE_REPO}/site/images.yaml" <<'EOF'
roles: {}
EOF

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
certbot_cluster_expected_mode() { echo "staging"; }
certbot_cluster_expected_url() { echo "https://staging.invalid/directory"; }
certbot_cluster_prod_shared_backup_certbot_records() { return 0; }
certbot_cluster_run_remote_helper() { return 0; }
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh"

cat > "${FIXTURE_REPO}/framework/scripts/known-hosts-scope-lib.sh" <<'EOF'
#!/usr/bin/env bash
# Test stub for #349's known-hosts scope helper.
vm_key_to_module_name() { printf '%s' "$1"; }
refresh_known_hosts_for_scope() { return 0; }
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/known-hosts-scope-lib.sh"

cat > "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tofu-wrapper %s\n' "$*" >> "${EVENT_LOG}"
case "${1:-}" in
  init)
    exit 0
    ;;
  state)
    if [[ "${2:-}" == list && -n "${STUB_REBUILD_STATE_FILE:-}" ]]; then
      [[ "${STUB_STATE_FAILURE:-0}" -eq 0 ]] || exit 31
      cat "$STUB_REBUILD_STATE_FILE"
      exit 0
    fi
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
    if [[ -n "${STUB_APPLY_MINT_VM:-}" && " $* " == *" -var=start_vms=false "* ]]; then
      # Bridged cases only (17.18/17.19): the stopped apply "recreates" the VM
      # stopped with a fresh, empty vdb — the target the adopt step must swap
      # for the parked volume. State lives in the shared vdb fixture tree.
      vmid="$STUB_APPLY_MINT_VM"
      zfs_root="${VDB_FIXTURE_STATE}/zfs/pve01/vmstore/data"
      mkdir -p "${VDB_FIXTURE_STATE}/qm/pve01" "${VDB_FIXTURE_STATE}/status/pve01" \
        "${zfs_root}/vm-${vmid}-disk-0/props" "${zfs_root}/vm-${vmid}-disk-1/props"
      printf 'scsi0: vmstore:vm-%s-disk-1,size=4G\nscsi1: vmstore:vm-%s-disk-0,size=50G,backup=1,replicate=1\n' \
        "$vmid" "$vmid" > "${VDB_FIXTURE_STATE}/qm/pve01/${vmid}.conf"
      printf 'stopped\n' > "${VDB_FIXTURE_STATE}/status/pve01/${vmid}"
      printf 'fresh-guid-%s-vdb\n' "$vmid" > "${zfs_root}/vm-${vmid}-disk-0/guid"
      printf '50G\n' > "${zfs_root}/vm-${vmid}-disk-0/volsize"
      printf 'fresh-guid-%s-vda\n' "$vmid" > "${zfs_root}/vm-${vmid}-disk-1/guid"
      printf '4G\n' > "${zfs_root}/vm-${vmid}-disk-1/volsize"
      printf 'fresh-hash-%s\n' "$vmid" > "${zfs_root}/vm-${vmid}-disk-0/sha256"
      printf 'fresh-hash-%s\n' "$vmid" > "${zfs_root}/vm-${vmid}-disk-1/sha256"
    fi
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
status_file=""
args=("$@")
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest)
      manifest="$2"
      shift 2
      ;;
    --status-file)
      status_file="$2"
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
if [[ "${STUB_RESTORE_INCOMPLETE:-0}" == "1" ]]; then
  if [[ -z "$manifest" || -z "$status_file" ]]; then
    echo "restore-before-start fixture missing manifest or status file" >&2
    exit 9
  fi
  mkdir -p "$(dirname "$status_file")"
  jq -n --slurpfile manifest "$manifest" '
    ($manifest[0].entries[0]) as $entry
    | {
        version: 1,
        scope: "all",
        entries: [{
          label: $entry.label,
          vmid: $entry.vmid,
          env: $entry.env,
          status: "incomplete",
          reason: $entry.reason,
          message: "missing scsi0",
          pin: ($entry.pin // null)
        }]
      }
  ' > "$status_file"
  exit 2
fi
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"

cat > "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '302\tvault_dev\tdev\n'
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh"

# DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS covers the shared base; the extras
# below are scripts this fixture noops but others handle specially.
# See tests/lib/rebuild_fixture_helpers.sh.
setup_rebuild_fixture_noops "${FIXTURE_REPO}" \
  recover-secrets.sh \
  install-pbs.sh \
  configure-pbs.sh \
  restore-from-pbs.sh \
  configure-backups.sh

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
if [[ "${remote_cmd}" == *"zfs list -H -o name,volsize -r "* ]]; then
  exit 0
fi
if [[ "${remote_cmd}" == *"zfs list -H -o name -r "* ]]; then
  exit 0
fi
if [[ "${remote_cmd}" == *"zfs list -H -o name "* ]]; then
  exit 1
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
ORDER="$(grep -E '^(tofu-wrapper apply|restore-before-start.sh)' "$EVENT_LOG" \
  | sed -E 's/ --manifest [^ ]+/ --manifest <manifest>/' \
  | sed -E 's/ --status-file [^ ]+//' \
  | sed -E 's/ --park-status [^ ]+//')"
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

test_start "17.9" "rebuild rc=2 convergence uses status env and exact restore pin"
: > "$EVENT_LOG"
set +e
(
  export PATH="${SHIM_DIR}:${PATH}"
  export EVENT_LOG
  export STUB_RESTORE_INCOMPLETE=1
  export STUB_REBUILD_PLAN_JSON='{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true}}}]}'
  cd "${FIXTURE_REPO}"
  framework/scripts/rebuild-cluster.sh \
    --scope vm=vault_dev \
    --restore-pin-file build/restore-pin-reset.json \
    --override-branch-check
) > "${TMP_DIR}/rebuild-incomplete-converge.out" 2>&1
INCOMPLETE_CONVERGE_RC=$?
set -e
if [[ "$INCOMPLETE_CONVERGE_RC" == "0" ]] &&
   grep -Fq 'converge-incomplete-vm dev 302 pbs-nas:backup/vm/302/2026-04-12T18:30:00Z' "$EVENT_LOG" &&
   grep -Fq 'tofu-wrapper apply -target=module.vault_dev -auto-approve -input=false -var=start_vms=true -var=register_ha=true' "$EVENT_LOG"; then
  test_pass "rc=2 rebuild convergence receives dev env and exact pin before Phase 2"
else
  test_fail "rc=2 rebuild convergence did not preserve env/pin contract"
  printf 'rc=%s\nlog:\n%s\noutput:\n%s\n' \
    "$INCOMPLETE_CONVERGE_RC" "$(cat "$EVENT_LOG")" "$(cat "${TMP_DIR}/rebuild-incomplete-converge.out")" >&2
fi

# Forced recreation uses the real rebuild orchestration through both applies.
# State includes nested and counted root modules, plus out-of-scope/control
# plane resources; selection must keep those last two groups out of -replace.
cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
module "vault_dev" {}
module "vault_prod" {}
module "dns_dev" {}
module "acme_dev" {}
module "gatus" {}
module "hil_boot" {}
module "gitlab" {}
module "cicd" {}
module "pbs" {}
EOF
cat > "${TMP_DIR}/recreate-state.txt" <<'EOF'
module.vault_dev.proxmox_virtual_environment_vm.vm
module.dns_dev.module.dns1.proxmox_virtual_environment_vm.vm
module.dns_dev.module.dns2.proxmox_virtual_environment_vm.vm
module.acme_dev[0].module.acme_dev.proxmox_virtual_environment_vm.vm
module.vault_prod.proxmox_virtual_environment_vm.vm
module.gatus.proxmox_virtual_environment_vm.vm
module.hil_boot.proxmox_virtual_environment_vm.vm
module.gitlab.module.gitlab.proxmox_virtual_environment_vm.vm
module.cicd.module.cicd.proxmox_virtual_environment_vm.vm
module.pbs.proxmox_virtual_environment_vm.vm
module.vault_dev.terraform_data.cidata_hash[0]
EOF
RECREATE_PLAN="$(python3 - "${TMP_DIR}/recreate-state.txt" <<'PY'
import json, sys
rows = []
for address in open(sys.argv[1]).read().splitlines():
    if address.endswith(".proxmox_virtual_environment_vm.vm"):
        rows.append({"address": address, "change": {"actions": ["delete", "create"], "before": {"started": True}, "after": {"started": True}}})
print(json.dumps({"resource_changes": rows}))
PY
)"

run_recreate_fixture() {
  local scope="$1" plan="$2" state="$3"
  shift 3
  : > "$EVENT_LOG"
  set +e
  # Each fixture invocation deliberately confines its shim environment.
  # shellcheck disable=SC2030,SC2031
  (
    export PATH="${SHIM_DIR}:${PATH}"
    export EVENT_LOG
    export STUB_REBUILD_STATE_FILE="$state"
    export STUB_REBUILD_PLAN_JSON="$plan"
    cd "$FIXTURE_REPO"
    framework/scripts/rebuild-cluster.sh --scope "$scope" --override-branch-check --allow-dirty "$@"
  ) > "$OUTPUT_FILE" 2>&1
  RECREATE_RC=$?
  set -e
}

test_start "17.10" "env=dev force flags appear on bulk plan and stopped apply only"
run_recreate_fixture env=dev "$RECREATE_PLAN" "${TMP_DIR}/recreate-state.txt" --recreate
if [[ "$RECREATE_RC" -eq 0 ]] && python3 - "$EVENT_LOG" "$FIXTURE_REPO" <<'PY'
import json, sys
from pathlib import Path
events = Path(sys.argv[1]).read_text().splitlines()
plan = next(s for s in events if s.startswith("tofu-wrapper plan") and "preboot-restore-plan-bulk.out" in s)
applies = [s for s in events if s.startswith("tofu-wrapper apply")]
assert len(applies) == 2, applies
stopped, started = applies
expected = {
    "module.vault_dev.proxmox_virtual_environment_vm.vm",
    "module.dns_dev.module.dns1.proxmox_virtual_environment_vm.vm",
    "module.dns_dev.module.dns2.proxmox_virtual_environment_vm.vm",
    "module.acme_dev[0].module.acme_dev.proxmox_virtual_environment_vm.vm",
}
for event in (plan, stopped):
    assert {s[len("-replace="):] for s in event.split() if s.startswith("-replace=")} == expected, event
    assert {s for s in event.split() if s.startswith("-target=")} == {
        "-target=module.vault_dev", "-target=module.dns_dev", "-target=module.acme_dev"
    }, event
assert "start_vms=false" in stopped and "start_vms=true" in started
assert "-replace=" not in started
restore = next(s for s in events if s.startswith("restore-before-start.sh"))
assert events.index(stopped) < events.index(restore) < events.index(started)
doc = json.loads((Path(sys.argv[2]) / "build/recreate-plan-assert-bulk.json").read_text())
assert doc == {"expected": 4, "replacing": 4, "addresses": sorted(expected)}, doc
PY
then
  test_pass "scoped replacements stop before restore and never reach the start apply"
else
  test_fail "forced recreation flags/scope/order were incorrect"
  cat "$OUTPUT_FILE" "$EVENT_LOG" >&2
fi

test_start "17.11" "forced no-op plan fails before any apply or park"
NOOP_PLAN='{"resource_changes":[{"address":"module.vault_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["no-op"]}}]}'
run_recreate_fixture env=dev "$NOOP_PLAN" "${TMP_DIR}/recreate-state.txt" --recreate
if [[ "$RECREATE_RC" -ne 0 ]] &&
   grep -Fq "module.vault_dev.proxmox_virtual_environment_vm.vm: ['no-op']" "$OUTPUT_FILE" &&
   ! grep -q '^tofu-wrapper apply' "$EVENT_LOG" &&
   ! grep -Fq 'vdb park bridge (bulk pre-destroy)' "$OUTPUT_FILE" &&
   [[ ! -e "${FIXTURE_REPO}/build/recreate-plan-assert-bulk.json" ]]; then
  test_pass "no-op is rejected by plan assertion with no downstream destruction"
else
  test_fail "forced no-op plan did not fail closed"
  cat "$OUTPUT_FILE" "$EVENT_LOG" >&2
fi

test_start "17.12" "cold state creates selected VMs without replacement flags"
: > "${TMP_DIR}/empty-state.txt"
CREATE_PLAN='{"resource_changes":[{"address":"module.vault_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"after":{"started":true}}}]}'
run_recreate_fixture vm=vault_dev "$CREATE_PLAN" "${TMP_DIR}/empty-state.txt" --recreate
if [[ "$RECREATE_RC" -eq 0 ]] && ! grep -q -- '-replace=' "$EVENT_LOG" &&
   grep -q 'start_vms=true' "$EVENT_LOG" &&
   jq -e '.expected == 1 and .replacing == 1' "${FIXTURE_REPO}/build/recreate-plan-assert-bulk.json" >/dev/null; then
  test_pass "cold recreation reaches restore/start without -replace"
else
  test_fail "cold-state recreation failed"
  cat "$OUTPUT_FILE" "$EVENT_LOG" >&2
fi

test_start "17.13" "env=prod selects prod-only plus prod environment modules"
run_recreate_fixture env=prod "$RECREATE_PLAN" "${TMP_DIR}/recreate-state.txt" --recreate
if [[ "$RECREATE_RC" -eq 0 ]] &&
   jq -e '.addresses == ["module.gatus.proxmox_virtual_environment_vm.vm", "module.vault_prod.proxmox_virtual_environment_vm.vm"]' \
     "${FIXTURE_REPO}/build/recreate-plan-assert-bulk.json" >/dev/null; then
  test_pass "prod environment excludes shared/control-plane/dev modules"
else
  test_fail "prod scope was incorrect"
  cat "$OUTPUT_FILE" "$EVENT_LOG" >&2
fi

test_start "17.14" "env scope without --recreate preserves drift-driven apply"
run_recreate_fixture env=dev "$NOOP_PLAN" "${TMP_DIR}/recreate-state.txt"
if [[ "$RECREATE_RC" -eq 0 ]] && ! grep -q -- '-replace=' "$EVENT_LOG" && grep -q 'start_vms=true' "$EVENT_LOG"; then
  test_pass "env scope works with normal phased apply"
else
  test_fail "normal env scope failed"
  cat "$OUTPUT_FILE" "$EVENT_LOG" >&2
fi

test_start "17.15" "data-plane recreate includes shared VMs but never control-plane/PBS"
run_recreate_fixture data-plane "$RECREATE_PLAN" "${TMP_DIR}/recreate-state.txt" --recreate
if [[ "$RECREATE_RC" -eq 0 ]] &&
   jq -e '.expected == 7 and any(.addresses[]; contains("module.hil_boot."))
     and all(.addresses[]; test("module\\.(pbs|cicd|gitlab)\\.") | not)' \
     "${FIXTURE_REPO}/build/recreate-plan-assert-bulk.json" >/dev/null; then
  test_pass "data-plane recreation excludes only control-plane modules"
else
  test_fail "data-plane recreation selected the wrong resources"
  cat "$OUTPUT_FILE" "$EVENT_LOG" >&2
fi

test_start "17.16" "unknown state fails before forced recreation"
STUB_STATE_FAILURE=1 run_recreate_fixture env=dev "$RECREATE_PLAN" "${TMP_DIR}/recreate-state.txt" --recreate
if [[ "$RECREATE_RC" -ne 0 ]] && grep -Fq 'tofu state list failed (exit 31)' "$OUTPUT_FILE" &&
   ! grep -q '^tofu-wrapper apply' "$EVENT_LOG"; then
  test_pass "state query failure cannot masquerade as a cold create"
else
  test_fail "state query failure did not fail closed"
  cat "$OUTPUT_FILE" "$EVENT_LOG" >&2
fi

test_start "17.17" "empty env=dev target set refuses an unscoped apply"
printf 'module "vault_prod" {}\nmodule "gitlab" {}\n' > "${FIXTURE_REPO}/framework/tofu/root/main.tf"
run_recreate_fixture env=dev "$RECREATE_PLAN" "${TMP_DIR}/recreate-state.txt" --recreate
if [[ "$RECREATE_RC" -ne 0 ]] && grep -Fq 'env=dev produced empty target list' "$OUTPUT_FILE" &&
   ! grep -q '^tofu-wrapper apply' "$EVENT_LOG"; then
  test_pass "empty env selection fails closed"
else
  test_fail "empty env selection reached apply or failed elsewhere"
  cat "$OUTPUT_FILE" "$EVENT_LOG" >&2
fi

# --- Bridged bulk path: the park is a real step, not a "bridge disabled" no-op ---
# 17.10 runs with the dev bridge disabled, so its park step is a no-op and the
# fixture cannot tell a run that parked from one that skipped parking. These
# cases enable the bridge (environments.dev.vdb_park_bridge: true, the live
# site/config.yaml shape) and drive the REAL vdb-park-lib.sh through the bulk
# phase. Its ssh traffic is answered by the shared Sprint 044 vdb fixture shim
# (tests/lib/vdb_park_fixture.sh); anything that shim does not handle falls
# through to this fixture's own ssh shim. Both shims log into EVENT_LOG, so
# park, stopped apply, adopt, restore and start apply form one timeline.
source "${REPO_ROOT}/tests/lib/vdb_park_fixture.sh"
vdb_fixture_make
BRIDGED_SHIM_DIR="${TMP_DIR}/bridged-shims"
mkdir -p "$BRIDGED_SHIM_DIR"
cat > "${BRIDGED_SHIM_DIR}/ssh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
out="\$(mktemp)"
err="\$(mktemp)"
set +e
"${VDB_FIXTURE_SHIMS}/ssh" "\$@" >"\$out" 2>"\$err"
rc=\$?
set -e
if [[ "\$rc" -ne 99 ]]; then
  cat "\$out"
  cat "\$err" >&2
  rm -f "\$out" "\$err"
  exit "\$rc"
fi
rm -f "\$out" "\$err"
exec "${SHIM_DIR}/ssh" "\$@"
EOF
chmod +x "${BRIDGED_SHIM_DIR}/ssh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
domain: example.test
acme: staging
nas:
  ip: 10.0.0.50
  ssh_user: admin
  postgres_port: 5432
environments:
  prod: {}
  dev:
    vdb_park_bridge: true
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
proxmox:
  storage_pool: vmstore
storage:
  pool_name: vmstore
vms:
  gitlab:
    vmid: 150
    ip: 10.0.0.20
    backup: true
  vault_dev:
    vmid: 302
    ip: 10.0.0.21
    node: pve01
    backup: true
EOF
printf 'module "vault_dev" {}\n' > "${FIXTURE_REPO}/framework/tofu/root/main.tf"
printf 'module.vault_dev.proxmox_virtual_environment_vm.vm\n' > "${TMP_DIR}/bridged-state.txt"
BRIDGED_PLAN='{"resource_changes":[{"address":"module.vault_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["delete","create"],"before":{"started":true},"after":{"started":true,"disk":[{"interface":"scsi0"},{"interface":"scsi1","size":50}],"cdrom":[{"interface":"ide2"}]}}}]}'
BRIDGED_PIN='pbs-nas:backup/vm/302/2026-04-12T18:30:00Z'

bridged_reset() {
  vdb_fixture_make
  vdb_fixture_set_vm pve01 302 running $'scsi0: vmstore:vm-302-disk-1,size=4G\nscsi1: vmstore:vm-302-disk-0,size=50G,backup=1,replicate=1'
  vdb_fixture_create_dataset pve01 vmstore/data/vm-302-disk-0 guid-data-302 50G
  vdb_fixture_create_dataset pve01 vmstore/data/vm-302-disk-1 guid-os-302 4G
  rm -f "${FIXTURE_REPO}/build/vdb-park-status-bulk.json" "${FIXTURE_REPO}/build/preboot-restore-bulk.json"
}

run_bridged_recreate_fixture() {
  bridged_reset
  : > "$EVENT_LOG"
  set +e
  # shellcheck disable=SC2030,SC2031
  (
    export PATH="${BRIDGED_SHIM_DIR}:${SHIM_DIR}:${PATH}"
    export EVENT_LOG
    export VDB_FIXTURE_STATE
    export VDB_EVENT_LOG="$EVENT_LOG"
    export STUB_APPLY_MINT_VM=302
    export STUB_REBUILD_STATE_FILE="${TMP_DIR}/bridged-state.txt"
    export STUB_REBUILD_PLAN_JSON="$BRIDGED_PLAN"
    cd "$FIXTURE_REPO"
    framework/scripts/rebuild-cluster.sh --scope env=dev --override-branch-check --allow-dirty --recreate "$@"
  ) > "$OUTPUT_FILE" 2>&1
  RECREATE_RC=$?
  set -e
}

test_start "17.18" "bridged --recreate without a restore pin fails closed before the stopped apply"
run_bridged_recreate_fixture
if [[ "$RECREATE_RC" -ne 0 ]] &&
   grep -Fq 'vault_dev: missing restore pin for VMID 302; aborting before any vdb park mutation' "$OUTPUT_FILE" &&
   grep -Fq 'vdb park bridge (bulk pre-destroy)' "$OUTPUT_FILE" &&
   ! grep -Fq 'vdb park bridge disabled' "$OUTPUT_FILE" &&
   grep -q '^tofu-wrapper plan' "$EVENT_LOG" &&
   ! grep -q '^tofu-wrapper apply' "$EVENT_LOG" &&
   ! grep -Eq '^(qm stop|qm delete|qm attach|zfs rename|zfs destroy|zfs set)' "$EVENT_LOG" &&
   ! grep -q '^restore-before-start.sh' "$EVENT_LOG"; then
  test_pass "missing pin stops the bridged bulk run after the plan and before any apply, destroy, or park mutation"
else
  test_fail "bridged run without a pin did not fail closed at the park step"
  printf 'rc=%s\noutput:\n%s\nevents:\n%s\n' "$RECREATE_RC" "$(cat "$OUTPUT_FILE")" "$(cat "$EVENT_LOG")" >&2
fi

test_start "17.19" "bridged --recreate with a pin parks before the stopped apply and adopts before restore"
run_bridged_recreate_fixture --restore-pin-file build/restore-pin-reset.json
if [[ "$RECREATE_RC" -eq 0 ]] &&
   grep -Fq 'vault_dev: parked 50G vdb (guid-data-302)' "$OUTPUT_FILE" &&
   grep -Fq 'vault_dev: adopted vm-302-disk-0' "$OUTPUT_FILE" &&
   ! grep -Fq 'vdb park bridge disabled' "$OUTPUT_FILE" &&
   ! grep -Fq 'No eligible vdb park entries' "$OUTPUT_FILE" &&
   python3 - "$EVENT_LOG" "$FIXTURE_REPO" "$BRIDGED_PIN" <<'PY'
import json, sys
from pathlib import Path
events = Path(sys.argv[1]).read_text().splitlines()
repo = Path(sys.argv[2])
pin = sys.argv[3]

def first(prefix):
    return next(i for i, line in enumerate(events) if line.startswith(prefix))

applies = [i for i, line in enumerate(events) if line.startswith("tofu-wrapper apply")]
assert len(applies) == 2, applies
stopped, started = applies
assert "-var=start_vms=false" in events[stopped] and "-var=start_vms=true" in events[started]
assert "-replace=module.vault_dev.proxmox_virtual_environment_vm.vm" in events[stopped]
assert "-replace=" not in events[started]
stop = first("qm stop 302")
park = first("zfs rename vmstore/data/vm-302-disk-0 vmstore/data/mycofu-park-302-vdb")
adopt = first("zfs rename vmstore/data/mycofu-park-302-vdb vmstore/data/vm-302-disk-0")
attach = first("qm attach 302 scsi1 vmstore:vm-302-disk-0")
restore = first("restore-before-start.sh all")
assert stop < park < stopped < adopt < attach < restore < started, (stop, park, stopped, adopt, attach, restore, started)
assert "--pin-file " + str(repo / "build/restore-pin-reset.json") in events[restore], events[restore]
assert "--park-status " + str(repo / "build/vdb-park-status-bulk.json") in events[restore], events[restore]
manifest = json.loads(next(line for line in events if line.startswith("manifest ")).split(" ", 1)[1])
(entry,) = manifest["entries"]
assert entry["vmid"] == 302 and entry["reason"] == "replace" and entry["pin"] == pin, entry
status = json.loads((repo / "build/vdb-park-status-bulk.json").read_text())
(row,) = [e for e in status["entries"] if e["vmid"] == 302]
assert row["status"] == "adopted" and row["pin"] == pin and row["guid"] == "guid-data-302", row
PY
then
  test_pass "pinned bridged run: park < stopped apply < adopt < restore < start apply, manifest and park status carry the pin"
else
  test_fail "pinned bridged run did not park/adopt in order with the pin"
  printf 'rc=%s\noutput:\n%s\nevents:\n%s\nstatus:\n%s\n' "$RECREATE_RC" "$(cat "$OUTPUT_FILE")" "$(cat "$EVENT_LOG")" \
    "$(cat "${FIXTURE_REPO}/build/vdb-park-status-bulk.json" 2>/dev/null || true)" >&2
fi

runner_summary
