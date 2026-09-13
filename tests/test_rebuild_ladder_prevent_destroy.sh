#!/usr/bin/env bash
# test_rebuild_ladder_prevent_destroy.sh - #743 full atomic ladder fixture.

set -euo pipefail

unset SOPS_AGE_KEY_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/rebuild_fixture_helpers.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"

line_of() {
  local pattern="$1"
  local file="$2"
  grep -nF "$pattern" "$file" | head -1 | cut -d: -f1 || true
}

setup_fixture() {
  local fixture_repo="$1"
  local shim_dir="$2"
  local trace_log="$3"
  local state_removed_marker="$4"

  mkdir -p "${fixture_repo}/framework/scripts/lib" \
           "${fixture_repo}/framework/tofu/root" \
           "${fixture_repo}/site/sops" \
           "${fixture_repo}/site/gatus" \
           "${fixture_repo}/site/tofu" \
           "${fixture_repo}/build" \
           "$shim_dir"

  cp "$SCRIPT" "${fixture_repo}/framework/scripts/rebuild-cluster.sh"
  chmod +x "${fixture_repo}/framework/scripts/rebuild-cluster.sh"

  touch "${fixture_repo}/operator.age.key"
  printf 'dummy: value\n' > "${fixture_repo}/site/sops/secrets.yaml"
  printf 'placeholder flake\n' > "${fixture_repo}/flake.nix"

  cat > "${fixture_repo}/site/config.yaml" <<'EOF'
domain: example.test
nix_builder:
  type: none
nas:
  ip: 127.0.0.2
  ssh_user: root
  postgres_port: 5432
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
vms:
  cicd:
    vmid: 150
    ip: 10.0.0.150
    backup: true
cicd:
  runner_disk_gb: 256
EOF

  cat > "${fixture_repo}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  cat > "${fixture_repo}/site/tofu/image-versions.auto.tfvars" <<'EOF'
image_versions = {
  "cicd" = "cicd-4ypjgkci.img"
}
EOF

  cat > "${fixture_repo}/framework/scripts/git-deploy-context.sh" <<'EOF'
#!/usr/bin/env bash
resolve_git_context() { :; }
classify_scope_impact() { return 0; }
detect_initial_deploy() { INITIAL_DEPLOY=1; }
refresh_gitlab_prod_ref() { :; }
check_branch_safety() { return 0; }
resolve_last_known_prod_context() { :; }
detect_config_yaml_divergence() { :; }
print_deploy_banner() { :; }
write_deploy_manifest() { :; }
scope_requires_prod_branch() { return 0; }
should_skip_gitlab_handoff() { return 0; }
print_last_known_prod_comparison() { :; }
print_post_dr_reconciliation_instructions() { :; }
EOF
  chmod +x "${fixture_repo}/framework/scripts/git-deploy-context.sh"

  cat > "${fixture_repo}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
certbot_cluster_expected_mode() { echo "staging"; }
certbot_cluster_prod_shared_backup_certbot_records() { :; }
EOF
  chmod +x "${fixture_repo}/framework/scripts/certbot-cluster.sh"

  cat > "${fixture_repo}/framework/scripts/converge-lib.sh" <<'EOF'
#!/usr/bin/env bash
converge_run_all() { printf 'converge_run_all\n' >> "${TRACE_LOG}"; }
EOF
  chmod +x "${fixture_repo}/framework/scripts/converge-lib.sh"

  cat > "${fixture_repo}/framework/scripts/known-hosts-scope-lib.sh" <<'EOF'
#!/usr/bin/env bash
refresh_known_hosts_for_scope() { printf 'refresh_known_hosts_for_scope\n' >> "${TRACE_LOG}"; }
EOF
  chmod +x "${fixture_repo}/framework/scripts/known-hosts-scope-lib.sh"

  cat > "${fixture_repo}/framework/scripts/lib/converge-incomplete-vm.sh" <<'EOF'
#!/usr/bin/env bash
converge_incomplete_vm() { printf 'converge_incomplete_vm %s\n' "$*" >> "${TRACE_LOG}"; }
EOF
  chmod +x "${fixture_repo}/framework/scripts/lib/converge-incomplete-vm.sh"

  cat > "${fixture_repo}/framework/scripts/vdb-park-lib.sh" <<'EOF'
#!/usr/bin/env bash
vdb_park_batch() { printf 'vdb_park_batch %s\n' "$*" >> "${TRACE_LOG}"; }
vdb_adopt_batch() { printf 'vdb_adopt_batch %s\n' "$*" >> "${TRACE_LOG}"; }
EOF
  chmod +x "${fixture_repo}/framework/scripts/vdb-park-lib.sh"

  setup_rebuild_fixture_noops "${fixture_repo}" \
    recover-secrets.sh \
    install-pbs.sh \
    configure-pbs.sh \
    restore-from-pbs.sh \
    configure-backups.sh

  cat > "${fixture_repo}/framework/scripts/generate-gatus-config.sh" <<'EOF'
#!/usr/bin/env bash
echo 'endpoints: []'
EOF
  chmod +x "${fixture_repo}/framework/scripts/generate-gatus-config.sh"

  cat > "${fixture_repo}/framework/scripts/check-plan-images-present.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'check-plan-images-present.sh %s\n' "$*" >> "${TRACE_LOG}"
plan_json=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-json)
      plan_json="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
[[ -n "$plan_json" && -f "$plan_json" ]]
jq -e '.resource_changes[]?.change.after.disk[]?.file_id == "local:iso/cicd-4ypjgkci.img"' "$plan_json" >/dev/null
EOF
  chmod +x "${fixture_repo}/framework/scripts/check-plan-images-present.sh"

  cat > "${fixture_repo}/framework/scripts/restore-before-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-before-start.sh %s\n' "$*" >> "${TRACE_LOG}"
exit 0
EOF
  chmod +x "${fixture_repo}/framework/scripts/restore-before-start.sh"

  make_noop_script "${fixture_repo}/framework/scripts/aggregate-preboot-status.sh"
  make_noop_script "${fixture_repo}/framework/scripts/list-backup-backed-vmids.sh"

  cat > "${fixture_repo}/framework/scripts/vm-scope.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  control-plane-modules)
    echo "module.cicd"
    ;;
  classes)
    echo '{"cicd":{"category":"nix","control_plane":true}}'
    ;;
  *)
    ;;
esac
EOF
  chmod +x "${fixture_repo}/framework/scripts/vm-scope.sh"

  cat > "${fixture_repo}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tofu-wrapper %s\n' "$*" >> "${TRACE_LOG}"

prevent_destroy_stderr() {
  case "${STUB_PLAN_ERROR_KIND:-current}" in
    old)
      cat >&2 <<'ERR'
Error: Instance cannot be destroyed

Resource module.cicd.module.cicd.proxmox_virtual_environment_vm.vm has
lifecycle.prevent_destroy set, but the plan calls for this resource
to be destroyed.
ERR
      ;;
    current)
      cat >&2 <<'ERR'
Error: Resource cannot be destroyed

Resource module.cicd.module.cicd.proxmox_virtual_environment_vm.vm has
lifecycle.prevent_destroy set, but the plan calls for this resource
to be destroyed. If you do want to destroy this resource, either
change or disable the lifecycle.prevent_destroy argument, or remove
the resource from the configuration.
ERR
      ;;
    infra)
      cat >&2 <<'ERR'
Error: Failed to load state: connection to backend refused

The tofu backend could not open the state file. This is a transient
infrastructure error unrelated to any resource lifecycle.
ERR
      ;;
  esac
}

case "${1:-}" in
  init)
    exit 0
    ;;
  state)
    case "${2:-}" in
      list)
        printf '%s\n' \
          'module.cicd.module.cicd.proxmox_virtual_environment_vm.vm' \
          'module.cicd.module.cicd.proxmox_virtual_environment_file.user_data["pve01"]'
        exit 0
        ;;
      rm)
        touch "${STATE_REMOVED_MARKER}"
        exit 0
        ;;
    esac
    ;;
  plan)
    if [[ " $* " == *" -target=module.cicd "* ]] && [[ ! -f "${STATE_REMOVED_MARKER}" ]]; then
      prevent_destroy_stderr
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
exit 0
EOF
  chmod +x "${fixture_repo}/framework/scripts/tofu-wrapper.sh"

  cat > "${shim_dir}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-o=json" ]]; then
  case "${4:-${3:-}}" in
    *config.yaml)
      echo '{"domain":"example.test","nix_builder":{"type":"none"},"nas":{"ip":"127.0.0.2","ssh_user":"root","postgres_port":5432},"nodes":[{"name":"pve01","mgmt_ip":"127.0.0.1"}],"vms":{"cicd":{"vmid":150,"ip":"10.0.0.150","backup":true}},"cicd":{"runner_disk_gb":256}}'
      ;;
    *applications.yaml)
      echo '{"applications":{}}'
      ;;
    *)
      echo "unexpected yq json file: $*" >&2
      exit 9
      ;;
  esac
  exit 0
fi
if [[ "${1:-}" == "-r" ]]; then
  query="${2:-}"
else
  query="${1:-}"
fi
case "$query" in
  ".nix_builder.type") echo "none" ;;
  '.nix_builder.nixpkgs_ref // "github:NixOS/nixpkgs/nixpkgs-26.05-darwin"')
    echo "github:NixOS/nixpkgs/nixpkgs-26.05-darwin" ;;
  ".nodes | length") echo "1" ;;
  ".nodes[0].name") echo "pve01" ;;
  ".nodes[0].mgmt_ip"|".nodes[].mgmt_ip") echo "127.0.0.1" ;;
  ".nas.ip") echo "127.0.0.2" ;;
  ".nas.ssh_user") echo "root" ;;
  ".nas.postgres_port") echo "5432" ;;
  ".vms.pbs.ip // \"\""|".vms.pbs.vmid // \"\"") ;;
  ".vms.cicd.vmid // \"\"") echo "150" ;;
  ".vms.cicd.ip // \"\"") echo "10.0.0.150" ;;
  ".domain") echo "example.test" ;;
  ".vms | to_entries[] | select(.key | test(\"_prod$\")) | .key"|".vms | to_entries[] | select(.key | test(\"_dev$\")) | .key") ;;
  ".vms | to_entries[] | select(.value.backup == true) | .value.vmid") ;;
  ".applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key") ;;
  ".applications | to_entries[] | .value.environments | to_entries[] | .value.vmid") ;;
  ".vms[].vmid") echo "150" ;;
  *) echo "unexpected yq query: $*" >&2; exit 9 ;;
esac
EOF
  chmod +x "${shim_dir}/yq"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
printf 'ssh %s\n' "$cmd" >> "${TRACE_LOG}"
case "$cmd" in
  "true") exit 0 ;;
  *"psql -U postgres"*) echo "tofu_state"; exit 0 ;;
  *"ha-manager status 2>/dev/null | grep error"*) exit 0 ;;
  *"pvesh get /cluster/ha/resources --output-format json"*) echo "[]"; exit 0 ;;
  *"pvesh get /cluster/resources --type vm"*) echo "[]"; exit 0 ;;
  *"qm status 150 2>/dev/null | awk"*) echo "stopped"; exit 0 ;;
  "qm status 150"|*"qm status 150"*) echo "status: running"; exit 0 ;;
  *"ha-manager remove vm:150"*|*"qm stop 150"*|*"qm destroy 150"*|*"zfs destroy -r vmstore/data/vm-150-"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "${shim_dir}/ssh"

  cat > "${shim_dir}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -chdir=* ]]; then shift; fi
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  echo '{"resource_changes":[]}'
  exit 0
fi
exit 0
EOF
  chmod +x "${shim_dir}/tofu"

  cat > "${shim_dir}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"rev-parse"*) echo "0123456789abcdef0123456789abcdef01234567" ;;
  *"branch --show-current"*) echo "dev" ;;
esac
exit 0
EOF
  chmod +x "${shim_dir}/git"

  for cmd in ping curl scp dig openssl sops nix ssh-keygen ssh-keyscan sleep; do
    make_noop_script "${shim_dir}/${cmd}"
  done

  : > "$trace_log"
  rm -f "$state_removed_marker"
}

run_fixture_case() {
  local fixture_repo="$1"
  local shim_dir="$2"
  local trace_log="$3"
  local state_removed_marker="$4"
  local kind="$5"

  : > "$trace_log"
  rm -f "$state_removed_marker"
  rm -f "${fixture_repo}/build/preboot-restore-atomic-cicd.json" \
        "${fixture_repo}/build/preboot-restore-plan-atomic-precheck-cicd.json"

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export TRACE_LOG="$trace_log"
    export STATE_REMOVED_MARKER="$state_removed_marker"
    export STUB_PLAN_ERROR_KIND="$kind"
    cd "$fixture_repo"
    framework/scripts/rebuild-cluster.sh --scope vm=cicd --override-branch-check
  ) >> "$trace_log" 2>&1
  local rc=$?
  return "$rc"
}

assert_positive_case() {
  local fixture_repo="$1"
  local trace_log="$2"
  local rc="$3"
  local label="$4"
  local manifest="${fixture_repo}/build/preboot-restore-atomic-cicd.json"
  local plan_json="${fixture_repo}/build/preboot-restore-plan-atomic-precheck-cicd.json"
  local detection_line check_line destroy_line state_rm_line stopped_apply_line start_apply_line

  detection_line="$(line_of "pending changes BLOCKED by prevent_destroy" "$trace_log")"
  check_line="$(line_of "check-plan-images-present.sh --plan-json" "$trace_log")"
  destroy_line="$(line_of "qm destroy 150" "$trace_log")"
  state_rm_line="$(line_of "tofu-wrapper state rm module.cicd.module.cicd.proxmox_virtual_environment_vm.vm" "$trace_log")"
  stopped_apply_line="$(line_of "tofu-wrapper apply -target=module.cicd -var=start_vms=false -var=register_ha=false -auto-approve -input=false" "$trace_log")"
  start_apply_line="$(line_of "tofu-wrapper apply -target=module.cicd -var=start_vms=true -var=register_ha=true -auto-approve -input=false" "$trace_log")"

  if [[ "$rc" -eq 0 &&
        -n "$detection_line" &&
        -n "$check_line" &&
        -n "$destroy_line" &&
        -n "$state_rm_line" &&
        -n "$stopped_apply_line" &&
        -n "$start_apply_line" &&
        "$detection_line" -lt "$check_line" &&
        "$check_line" -lt "$destroy_line" &&
        "$destroy_line" -lt "$state_rm_line" &&
        "$state_rm_line" -lt "$stopped_apply_line" &&
        "$stopped_apply_line" -lt "$start_apply_line" &&
        -f "$manifest" &&
        -f "$plan_json" ]] &&
     jq -e '.entries[]? | select(.module == "module.cicd" and .reason == "replace" and .vmid == 150)' "$manifest" >/dev/null &&
     jq -e '.resource_changes[]?.change.after.disk[]?.file_id == "local:iso/cicd-4ypjgkci.img"' "$plan_json" >/dev/null; then
    test_pass "${label}: prevent_destroy ladder completed destroy -> state rm -> apply with image check and manifest"
  else
    test_fail "${label}: prevent_destroy ladder did not complete safely"
    printf 'rc=%s detection=%s check=%s destroy=%s state_rm=%s stopped_apply=%s start_apply=%s\ntrace:\n%s\nmanifest:\n' \
      "$rc" "$detection_line" "$check_line" "$destroy_line" "$state_rm_line" "$stopped_apply_line" "$start_apply_line" "$(cat "$trace_log")" >&2
    [[ -f "$manifest" ]] && cat "$manifest" >&2 || printf '<missing>\n' >&2
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
TRACE_LOG="${TMP_DIR}/trace.log"
STATE_REMOVED_MARKER="${TMP_DIR}/state-removed"

setup_fixture "$FIXTURE_REPO" "$SHIM_DIR" "$TRACE_LOG" "$STATE_REMOVED_MARKER"

test_start "743.1" "old prevent_destroy wording runs the full atomic ladder"
set +e
run_fixture_case "$FIXTURE_REPO" "$SHIM_DIR" "$TRACE_LOG" "$STATE_REMOVED_MARKER" old
OLD_RC=$?
set -e
assert_positive_case "$FIXTURE_REPO" "$TRACE_LOG" "$OLD_RC" "old wording"

test_start "743.2" "current prevent_destroy wording runs the full atomic ladder"
set +e
run_fixture_case "$FIXTURE_REPO" "$SHIM_DIR" "$TRACE_LOG" "$STATE_REMOVED_MARKER" current
CURRENT_RC=$?
set -e
assert_positive_case "$FIXTURE_REPO" "$TRACE_LOG" "$CURRENT_RC" "current wording"

test_start "743.3" "unrelated tofu infra error still fails closed"
set +e
run_fixture_case "$FIXTURE_REPO" "$SHIM_DIR" "$TRACE_LOG" "$STATE_REMOVED_MARKER" infra
INFRA_RC=$?
set -e
if [[ "$INFRA_RC" -ne 0 ]] &&
   grep -Fq "Cannot determine state for cicd" "$TRACE_LOG" &&
   ! grep -Fq "qm destroy 150" "$TRACE_LOG" &&
   ! grep -Fq "tofu-wrapper state rm module.cicd" "$TRACE_LOG"; then
  test_pass "unrelated tofu plan error dies before destroy/state rm"
else
  test_fail "unrelated tofu error did not fail closed"
  printf 'rc=%s\ntrace:\n%s\n' "$INFRA_RC" "$(cat "$TRACE_LOG")" >&2
fi

runner_summary
