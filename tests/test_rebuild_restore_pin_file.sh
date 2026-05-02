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
  local pin_mode="$2"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/framework/tofu/root" \
    "${repo_dir}/site/sops" \
    "${repo_dir}/build"

  cp "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" "${repo_dir}/framework/scripts/rebuild-cluster.sh"
  chmod +x "${repo_dir}/framework/scripts/rebuild-cluster.sh"

  cat > "${repo_dir}/framework/scripts/converge-lib.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

converge_run_all() { :; }
EOF
  chmod +x "${repo_dir}/framework/scripts/converge-lib.sh"

  cat > "${repo_dir}/framework/tofu/root/main.tf" <<'EOF'
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
  vault_dev:
    vmid: 302
    ip: 10.0.0.21
    backup: true
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  printf 'dummy: value\n' > "${repo_dir}/site/sops/secrets.yaml"
  printf 'age1dummy\n' > "${repo_dir}/operator.age.key"

  case "${pin_mode}" in
    valid)
      cat > "${repo_dir}/build/restore-pin-reset.json" <<'EOF'
{
  "version": 1,
  "captured_at": "2026-04-15T13:20:00Z",
  "pins": {
    "302": "pbs-nas:backup/vm/302/2026-04-12T18:30:00Z"
  }
}
EOF
      ;;
    missing)
      cat > "${repo_dir}/build/restore-pin-reset.json" <<'EOF'
{
  "version": 1,
  "captured_at": "2026-04-15T13:20:00Z",
  "pins": {}
}
EOF
      ;;
  esac

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
write_deploy_manifest() { :; }
print_post_dr_reconciliation_instructions() { :; }
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

case "${1:-}" in
  init)
    exit 0
    ;;
  state)
    if [[ "${2:-}" == "list" ]]; then
      exit 0
    fi
    if [[ "${2:-}" == "rm" || "${2:-}" == "show" ]]; then
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
  chmod +x "${repo_dir}/framework/scripts/tofu-wrapper.sh"

  cat > "${repo_dir}/framework/scripts/restore-before-start.sh" <<'EOF'
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

printf 'restore-before-start.sh %s\n' "${args[*]}" >> "${STUB_RESTORE_LOG}"
if [[ -n "$manifest" ]]; then
  printf 'manifest-begin\n' >> "${STUB_RESTORE_LOG}"
  cat "$manifest" >> "${STUB_RESTORE_LOG}"
  printf 'manifest-end\n' >> "${STUB_RESTORE_LOG}"
fi
exit 0
EOF
  chmod +x "${repo_dir}/framework/scripts/restore-before-start.sh"

  cat > "${repo_dir}/framework/scripts/restore-from-pbs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "restore-from-pbs.sh should not be called directly by rebuild-cluster.sh" >&2
exit 99
EOF
  chmod +x "${repo_dir}/framework/scripts/restore-from-pbs.sh"

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
    make_noop_script "${repo_dir}/framework/scripts/${script_name}"
  done

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

host=""
for arg in "$@"; do
  if [[ "$arg" == root@* ]]; then
    host="${arg#root@}"
  fi
done
remote_cmd="${*: -1}"

if [[ "${remote_cmd}" == "true" ]]; then
  exit 0
fi

if [[ "${remote_cmd}" == *"psql -U postgres"* ]]; then
  printf 'tofu_state\n'
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

if [[ "${remote_cmd}" == *"/storage/pbs-nas/content --output-format json"* ]]; then
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

exit 0
EOF
  chmod +x "${shim_dir}/ssh"

  cat > "${shim_dir}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -chdir=* ]] && shift
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  printf '%s\n' "${STUB_REBUILD_PLAN_JSON:-{\"resource_changes\":[]}}"
  exit 0
fi
exit 0
EOF
  chmod +x "${shim_dir}/tofu"

  for shim_name in curl dig scp sops nix openssl ssh-keygen ssh-keyscan sleep; do
    cat > "${shim_dir}/${shim_name}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
    chmod +x "${shim_dir}/${shim_name}"
  done
}

run_fixture() {
  local scenario="$1"
  local pin_mode="$2"
  local with_pin_flag="$3"
  local repo_dir="${TMP_DIR}/${scenario}-repo"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local output_file="${TMP_DIR}/${scenario}.out"
  local restore_log="${TMP_DIR}/${scenario}.restore.log"

  setup_fixture_repo "${repo_dir}" "${pin_mode}"
  setup_shims "${shim_dir}"

  local rebuild_args=(--override-branch-check)
  if [[ "${with_pin_flag}" == "yes" ]]; then
    rebuild_args+=(--restore-pin-file build/restore-pin-reset.json)
  fi

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_RESTORE_LOG="${restore_log}"
    export STUB_REBUILD_PLAN_JSON='{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true}}}]}'
    cd "${repo_dir}"
    framework/scripts/rebuild-cluster.sh "${rebuild_args[@]}"
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n%s\n' "${status}" "${output_file}" "${restore_log}"
}

assert_file_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"

  if grep -Fq -- "$needle" "$file"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    missing output: %s\n' "$needle" >&2
    printf '    file contents:\n%s\n' "$(cat "$file" 2>/dev/null)" >&2
  fi
}

PINNED_ARTIFACTS="$(
  run_fixture \
    pinned \
    valid \
    yes
)"
PINNED_STATUS="$(printf '%s\n' "${PINNED_ARTIFACTS}" | sed -n '1p')"
PINNED_OUTPUT_FILE="$(printf '%s\n' "${PINNED_ARTIFACTS}" | sed -n '2p')"
PINNED_RESTORE_LOG="$(printf '%s\n' "${PINNED_ARTIFACTS}" | sed -n '3p')"

test_start "16.1" "rebuild-cluster passes --restore-pin-file to restore-before-start"
if [[ "${PINNED_STATUS}" == "0" ]]; then
  test_pass "pinned restore fixture exits 0"
else
  test_fail "pinned restore fixture exits 0"
  printf '    output:\n%s\n' "$(cat "${PINNED_OUTPUT_FILE}")" >&2
fi
assert_file_contains \
  "${PINNED_RESTORE_LOG}" \
  'restore-before-start.sh all --manifest ' \
  "restore-before-start is invoked for the rebuild restore"
assert_file_contains \
  "${PINNED_RESTORE_LOG}" \
  "--pin-file ${TMP_DIR}/pinned-repo/build/restore-pin-reset.json" \
  "restore-before-start receives the absolute pin file path"
assert_file_contains \
  "${PINNED_RESTORE_LOG}" \
  '"pin": "pbs-nas:backup/vm/302/2026-04-12T18:30:00Z"' \
  "preboot manifest carries the pinned backup id"

MISSING_ARTIFACTS="$(
  run_fixture \
    missing \
    missing \
    yes
)"
MISSING_STATUS="$(printf '%s\n' "${MISSING_ARTIFACTS}" | sed -n '1p')"
MISSING_OUTPUT_FILE="$(printf '%s\n' "${MISSING_ARTIFACTS}" | sed -n '2p')"
MISSING_RESTORE_LOG="$(printf '%s\n' "${MISSING_ARTIFACTS}" | sed -n '3p')"

test_start "16.2" "rebuild-cluster preserves restore-before-start when a pin file omits the VMID"
if [[ "${MISSING_STATUS}" == "0" ]]; then
  test_pass "missing-pin fixture exits 0"
else
  test_fail "missing-pin fixture exits 0"
  printf '    output:\n%s\n' "$(cat "${MISSING_OUTPUT_FILE}")" >&2
fi
assert_file_contains \
  "${MISSING_RESTORE_LOG}" \
  'restore-before-start.sh all --manifest ' \
  "restore-before-start still owns restore decisions with an omitted pin"
assert_file_contains \
  "${MISSING_RESTORE_LOG}" \
  '"label": "vault_dev"' \
  "preboot manifest still includes the backup-backed VM"
if ! grep -Fq '"pin":' "${MISSING_RESTORE_LOG}"; then
  test_pass "missing pin is not injected into the manifest"
else
  test_fail "missing pin is not injected into the manifest"
  printf '    restore log:\n%s\n' "$(cat "${MISSING_RESTORE_LOG}")" >&2
fi

LEGACY_ARTIFACTS="$(
  run_fixture \
    legacy \
    valid \
    no
)"
LEGACY_STATUS="$(printf '%s\n' "${LEGACY_ARTIFACTS}" | sed -n '1p')"
LEGACY_OUTPUT_FILE="$(printf '%s\n' "${LEGACY_ARTIFACTS}" | sed -n '2p')"
LEGACY_RESTORE_LOG="$(printf '%s\n' "${LEGACY_ARTIFACTS}" | sed -n '3p')"

test_start "16.3" "rebuild-cluster preserves latest-backup fallback by omitting --pin-file"
if [[ "${LEGACY_STATUS}" == "0" ]]; then
  test_pass "legacy restore fixture exits 0"
else
  test_fail "legacy restore fixture exits 0"
  printf '    output:\n%s\n' "$(cat "${LEGACY_OUTPUT_FILE}")" >&2
fi
assert_file_contains \
  "${LEGACY_RESTORE_LOG}" \
  'restore-before-start.sh all --manifest ' \
  "restore-before-start still runs without a pin file"
if grep -Fq -- '--pin-file' "${LEGACY_RESTORE_LOG}"; then
  test_fail "legacy restore path omits --pin-file when no pin file is provided"
  printf '    restore log:\n%s\n' "$(cat "${LEGACY_RESTORE_LOG}")" >&2
else
  test_pass "legacy restore path omits --pin-file when no pin file is provided"
fi

runner_summary
