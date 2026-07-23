#!/usr/bin/env bash
# test_rebuild_atomic_path_precondition.sh — atomic rebuild checks images before destroy.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"

line_no() {
  local pattern="$1"
  grep -n "$pattern" "$SCRIPT" | head -1 | cut -d: -f1 || true
}

test_start "RAP.1" "atomic path builds a pre-destroy plan"
PLAN_LINE="$(line_no 'preboot-restore-plan-atomic-precheck')"
CHECK_LINE="$(line_no 'check_plan_images_present "atomic-')"
DESTROY_LINE="$(line_no 'qm destroy ${VMID} --purge')"
if [[ -n "$PLAN_LINE" && -n "$CHECK_LINE" && -n "$DESTROY_LINE" &&
      "$PLAN_LINE" -lt "$CHECK_LINE" && "$CHECK_LINE" -lt "$DESTROY_LINE" ]]; then
  test_pass "atomic precheck plan and image-present check precede qm destroy"
else
  test_fail "atomic image-present precondition is not before qm destroy"
  printf 'plan=%s check=%s destroy=%s\n' "$PLAN_LINE" "$CHECK_LINE" "$DESTROY_LINE" >&2
fi

test_start "RAP.2" "bulk path checks images before stopped apply"
BULK_CHECK_LINE="$(line_no 'check_plan_images_present "bulk"')"
BULK_APPLY_LINE="$(line_no 'OpenTofu stopped apply')"
if [[ -n "$BULK_CHECK_LINE" && -n "$BULK_APPLY_LINE" && "$BULK_CHECK_LINE" -lt "$BULK_APPLY_LINE" ]]; then
  test_pass "bulk image-present check precedes bulk stopped apply"
else
  test_fail "bulk image-present precondition is not before stopped apply"
  printf 'bulk_check=%s bulk_apply=%s\n' "$BULK_CHECK_LINE" "$BULK_APPLY_LINE" >&2
fi

test_start "RAP.3" "rebuild rc=2 handler has full-recreate guidance"
if grep -Fq "needs full recreate because vdb-only restore cannot repair missing boot topology" "$SCRIPT" &&
   grep -Fq "converge_incomplete_vm" "$SCRIPT"; then
  test_pass "rebuild rc=2 path has convergence plus full-recreate fallback guidance"
else
  test_fail "rebuild rc=2 guidance/convergence wiring missing"
fi

test_start "RAP.4" "rebuild restore passes the status file consumed by rc=2 handler"
if grep -Fq 'args+=(--status-file "$status_file")' "$SCRIPT" &&
   grep -Fq 'handle_rebuild_incomplete_restore_rc2 "$status_file"' "$SCRIPT"; then
  test_pass "restore-before-start status path is shared with rc=2 handler"
else
  test_fail "rebuild rc=2 status-file wiring missing"
fi

test_start "RAP.5" "atomic path execution checks images before qm destroy"
TMP_DIR="$(mktemp -d)"
FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
TRACE_LOG="${TMP_DIR}/trace.log"
mkdir -p "${FIXTURE_REPO}/framework/scripts/lib" \
         "${FIXTURE_REPO}/framework/tofu/root" \
         "${FIXTURE_REPO}/site/sops" \
         "${FIXTURE_REPO}/site/gatus" \
         "${FIXTURE_REPO}/build" \
         "$SHIM_DIR"
cp "$SCRIPT" "${FIXTURE_REPO}/framework/scripts/rebuild-cluster.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/rebuild-cluster.sh"
touch "${FIXTURE_REPO}/operator.age.key" "${FIXTURE_REPO}/site/sops/secrets.yaml"
cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
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
  gitlab:
    vmid: 150
    ip: 10.0.0.150
    backup: false
EOF
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${FIXTURE_REPO}/framework/scripts/git-deploy-context.sh" <<'EOF'
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
cat > "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
certbot_cluster_expected_mode() { echo "staging"; }
certbot_cluster_prod_shared_backup_certbot_records() { :; }
EOF
cat > "${FIXTURE_REPO}/framework/scripts/converge-lib.sh" <<'EOF'
#!/usr/bin/env bash
converge_run_all() { printf 'converge_run_all\n' >> "${TRACE_LOG}"; }
EOF
cat > "${FIXTURE_REPO}/framework/scripts/known-hosts-scope-lib.sh" <<'EOF'
#!/usr/bin/env bash
refresh_known_hosts_for_scope() { printf 'refresh_known_hosts_for_scope\n' >> "${TRACE_LOG}"; }
EOF
cat > "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh" <<'EOF'
#!/usr/bin/env bash
converge_incomplete_vm() { printf 'converge_incomplete_vm %s\n' "$*" >> "${TRACE_LOG}"; }
EOF
cat > "${FIXTURE_REPO}/framework/scripts/github-publish-lib.sh" <<'EOF'
#!/usr/bin/env bash
resolve_gatus_expected_source_commit() {
  # Issue #528: real resolver reads git refs; the atomic-path fixture is
  # not a real repo, so return a fixed valid-shape SHA to keep set -e happy.
  printf '%s\n' 0000000000000000000000000000000000000000
}
EOF

for script in build-all-images.sh ensure-app-secrets.sh backup-now.sh install-pbs.sh configure-pbs.sh validate.sh verify-nas-prereqs.sh; do
  cat > "${FIXTURE_REPO}/framework/scripts/${script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${script} %s\n' "\$*" >> "${TRACE_LOG}"
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/${script}"
done
cat > "${FIXTURE_REPO}/framework/scripts/generate-gatus-config.sh" <<'EOF'
#!/usr/bin/env bash
echo 'endpoints: []'
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/generate-gatus-config.sh"
cat > "${FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
ssh -n root@127.0.0.1 "check-plan-images-present $*"
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh"
cat > "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-before-start.sh %s\n' "$*" >> "${TRACE_LOG}"
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"
cat > "${FIXTURE_REPO}/framework/scripts/vm-scope.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  control-plane-modules) echo "module.gitlab" ;;
  classes) echo '{"gitlab":{"category":"nix","control_plane":true}}' ;;
  *) ;;
esac
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/vm-scope.sh"
cat > "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tofu-wrapper %s\n' "$*" >> "${TRACE_LOG}"
case "${1:-}" in
  init)
    exit 0
    ;;
  state)
    case "${2:-}" in
      list) exit 0 ;;
      rm) exit 0 ;;
    esac
    ;;
  plan)
    if printf '%s\n' "$*" | grep -Fq -- '-detailed-exitcode'; then
      echo "Error: Instance cannot be destroyed" >&2
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
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-o=json" ]]; then
  case "${4:-${3:-}}" in
    *config.yaml)
      echo '{"domain":"example.test","nix_builder":{"type":"none"},"nas":{"ip":"127.0.0.2","ssh_user":"root","postgres_port":5432},"nodes":[{"name":"pve01","mgmt_ip":"127.0.0.1"}],"vms":{"gitlab":{"vmid":150,"ip":"10.0.0.150","backup":false}}}'
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
  # #566 (batch B): rebuild-cluster.sh now reads .nix_builder.nixpkgs_ref
  # to pin the preflight probes. The mock returns the same default the
  # real yq // operator would produce for an absent key.
  '.nix_builder.nixpkgs_ref // "github:NixOS/nixpkgs/nixpkgs-26.05-darwin"')
    echo "github:NixOS/nixpkgs/nixpkgs-26.05-darwin" ;;
  ".nodes | length") echo "1" ;;
  ".nodes[0].name") echo "pve01" ;;
  ".nodes[0].mgmt_ip"|".nodes[].mgmt_ip") echo "127.0.0.1" ;;
  ".nas.ip") echo "127.0.0.2" ;;
  ".nas.ssh_user") echo "root" ;;
  ".nas.postgres_port") echo "5432" ;;
  ".vms.pbs.ip // \"\""|".vms.pbs.vmid // \"\"") ;;
  ".vms.gitlab.vmid // \"\"") echo "150" ;;
  ".vms.gitlab.ip // \"\"") echo "10.0.0.150" ;;
  ".domain") echo "example.test" ;;
  ".vms | to_entries[] | select(.key | test(\"_prod$\")) | .key"|".vms | to_entries[] | select(.key | test(\"_dev$\")) | .key") ;;
  ".vms | to_entries[] | select(.value.backup == true) | .value.vmid") ;;
  ".applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key") ;;
  ".applications | to_entries[] | .value.environments | to_entries[] | .value.vmid") ;;
  ".vms[].vmid") echo "150" ;;
  *) echo "unexpected yq query: $*" >&2; exit 9 ;;
esac
EOF
chmod +x "${SHIM_DIR}/yq"
cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
printf 'ssh %s\n' "$cmd" >> "${TRACE_LOG}"
case "$cmd" in
  "true") exit 0 ;;
  *"psql -U postgres"*) echo "tofu_state"; exit 0 ;;
  "check-plan-images-present "*) exit 0 ;;
  *"ha-manager status 2>/dev/null | grep error"*) exit 0 ;;
  *"pvesh get /cluster/ha/resources --output-format json"*) echo "[]"; exit 0 ;;
  "qm status 150"|*"qm status 150"*) echo "status: stopped"; exit 0 ;;
  *"qm status 150 2>/dev/null | awk"*) echo "stopped"; exit 0 ;;
  *"ha-manager remove vm:150"*|*"qm stop 150"*|*"qm destroy 150"*|*"zfs destroy -r vmstore/data/vm-150-"*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"
cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -chdir=* ]]; then shift; fi
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  echo '{"resource_changes":[]}'
  exit 0
fi
exit 0
EOF
chmod +x "${SHIM_DIR}/tofu"
cat > "${SHIM_DIR}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"rev-parse"*) echo "0123456789abcdef0123456789abcdef01234567" ;;
  *"branch --show-current"*) echo "dev" ;;
esac
exit 0
EOF
chmod +x "${SHIM_DIR}/git"
for cmd in ping curl scp dig openssl sops nix ssh-keygen ssh-keyscan sleep; do
  cat > "${SHIM_DIR}/${cmd}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${SHIM_DIR}/${cmd}"
done

: > "$TRACE_LOG"
set +e
OUT="$(PATH="${SHIM_DIR}:${PATH}" TRACE_LOG="$TRACE_LOG" bash -c 'cd "$0" && framework/scripts/rebuild-cluster.sh --scope vm=gitlab --override-branch-check' "$FIXTURE_REPO" 2>&1)"
RC=$?
set -e
CHECK_LINE="$(grep -n 'ssh check-plan-images-present' "$TRACE_LOG" | head -1 | cut -d: -f1 || true)"
DESTROY_LINE="$(grep -n 'qm destroy 150' "$TRACE_LOG" | head -1 | cut -d: -f1 || true)"
rm -rf "$TMP_DIR"
if [[ "$RC" -eq 0 && -n "$CHECK_LINE" && -n "$DESTROY_LINE" && "$CHECK_LINE" -lt "$DESTROY_LINE" ]]; then
  test_pass "execution trace checks image availability before qm destroy"
else
  test_fail "execution trace did not prove image-present check precedes qm destroy"
  printf 'rc=%s check_line=%s destroy_line=%s\nout:\n%s\n' "$RC" "$CHECK_LINE" "$DESTROY_LINE" "$OUT" >&2
fi

runner_summary
