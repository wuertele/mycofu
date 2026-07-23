#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

FIXTURE_DIR="${REPO_ROOT}/tests/fixtures/vm-scope-golden"
CAPTURE=0
if [[ "${1:-}" == "--capture" ]]; then
  CAPTURE=1
  shift
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

record_or_compare() {
  local name="$1"
  local content="$2"
  local path="${FIXTURE_DIR}/${name}"

  if [[ "$CAPTURE" -eq 1 ]]; then
    mkdir -p "$FIXTURE_DIR"
    printf '%s\n' "$content" > "$path"
    test_pass "captured ${name}"
    return 0
  fi

  if [[ ! -f "$path" ]]; then
    test_fail "missing golden fixture ${path}; run ${BASH_SOURCE[0]} --capture on a clean pre-migration state"
    return 0
  fi

  local actual_file="${TMP_DIR}/${name}.actual"
  printf '%s\n' "$content" > "$actual_file"
  if diff -u "$path" "$actual_file" >/dev/null; then
    test_pass "${name} matches golden"
  else
    test_fail "${name} differs from golden"
    diff -u "$path" "$actual_file" >&2 || true
  fi
}

assert_contains_text() {
  local content="$1"
  local needle="$2"
  local message="$3"

  if [[ "$content" == *"$needle"* ]]; then
    test_pass "$message"
  else
    test_fail "$message (missing '${needle}')"
  fi
}

setup_fixture_repo() {
  local repo_dir="$1"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/framework/scripts/lib" \
    "${repo_dir}/framework/tofu/root" \
    "${repo_dir}/framework" \
    "${repo_dir}/site" \
    "${repo_dir}/build"

  for script in converge-lib.sh git-deploy-context.sh safe-apply.sh vdb-park-lib.sh vm-scope.sh; do
    cp "${REPO_ROOT}/framework/scripts/${script}" "${repo_dir}/framework/scripts/${script}"
    chmod +x "${repo_dir}/framework/scripts/${script}"
  done
  cp "${REPO_ROOT}/framework/scripts/vm-topology-lib.sh" \
    "${repo_dir}/framework/scripts/vm-topology-lib.sh"
  cp "${REPO_ROOT}/framework/scripts/lib/converge-incomplete-vm.sh" \
    "${repo_dir}/framework/scripts/lib/converge-incomplete-vm.sh"

  cat > "${repo_dir}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
certbot_cluster_staging_override_targets() { return 0; }
EOF
  chmod +x "${repo_dir}/framework/scripts/certbot-cluster.sh"

  cat > "${repo_dir}/framework/images.yaml" <<'EOF'
roles:
  dns:
    category: nix
    host_config: site/nix/hosts/dns.nix
    scope: env-bound
    control_plane: false
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
  acme-dev:
    category: nix
    host_config: site/nix/hosts/acme-dev.nix
    scope: dev-only
    control_plane: false
  gatus:
    category: nix
    host_config: site/nix/hosts/gatus.nix
    scope: prod-only
    control_plane: false
  cpnix:
    category: nix
    host_config: site/nix/hosts/cpnix.nix
    scope: env-bound
    control_plane: true
non_built_roles:
  pbs:
    category: vendor
    scope: shared
    control_plane: true
  cpvendor:
    category: vendor
    scope: env-bound
    control_plane: true
EOF

  cat > "${repo_dir}/site/images.yaml" <<'EOF'
roles:
  testapp:
    category: nix
    host_config: site/nix/hosts/testapp.nix
    scope: env-bound
    control_plane: false
  hil-boot:
    category: nix
    host_config: site/nix/hosts/hil-boot.nix
    scope: shared
    control_plane: false
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications:
  grafana:
    enabled: true
    backup: true
    environments:
      dev: { vmid: 501 }
      prod: { vmid: 601 }
  disabled_app:
    enabled: false
EOF

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
vms:
  dns_dev: { vmid: 301, backup: false }
  dns_prod: { vmid: 401, backup: false }
  vault_dev: { vmid: 303, backup: true }
  vault_prod: { vmid: 403, backup: true }
  gitlab: { vmid: 150, backup: true }
  cicd: { vmid: 160, backup: true }
  pbs: { vmid: 190, backup: true }
  cpnix_dev: { vmid: 191, backup: true }
  cpvendor_dev: { vmid: 192, backup: true }
  hil_boot: { vmid: 170, backup: false }
  gatus: { vmid: 460, backup: false }
EOF

  cat > "${repo_dir}/framework/tofu/root/main.tf" <<'EOF'
module "dns_dev" {}
module "dns_prod" {}
module "vault_dev" {}
module "vault_prod" {}
module "gitlab" {}
module "cicd" {}
module "pbs" {}
module "cpnix_dev" {}
module "cpvendor_dev" {}
module "hil_boot" {}
module "acme_dev" {}
module "gatus" {}
module "grafana_dev" {}
module "grafana_prod" {}
EOF
}

run_converge_corpus() {
  local repo_dir="$1"
  local output=""
  local target rc value
  local cases=(
    ""
    "-target=module.dns_dev"
    "-target=module.vault_prod"
    "-target=module.gitlab"
    "-target=module.gatus"
    "-target=module.cicd"
    "-target=module.pbs"
    "-target=module.hil_boot"
    "-target=module.vault_dev -target=module.gatus"
    "badtoken"
    "-target=module.unknownrole"
  )

  for target in "${cases[@]}"; do
    set +e
    value="$(
      SCRIPT_DIR="${repo_dir}/framework/scripts" \
      REPO_DIR="$repo_dir" \
      CONFIG="${repo_dir}/site/config.yaml" \
      APPS_CONFIG="${repo_dir}/site/applications.yaml" \
      TOFU_TARGETS="$target" \
      bash -c 'log() { printf "%s\n" "$*"; }; source "${SCRIPT_DIR}/converge-lib.sh"; converge_target_envs' 2>&1
    )"
    rc=$?
    set -e
    output+=$'TARGETS='"${target}"$'\n'
    output+=$'RC='"${rc}"$'\n'
    output+="${value}"$'\n---\n'
  done
  printf '%s' "$output"
}

run_scope_corpus() {
  local repo_dir="$1"
  local output=""
  local scope rc value
  local cases=(
    ""
    "control-plane"
    "data-plane"
    "vm=gitlab"
    "vm=hil_boot"
    "vm=gatus"
    "vm=acme_dev"
    "vm=dns_prod"
    "vm=cicd,pbs"
    "vm=unknownrole"
    "nonsense"
  )

  for scope in "${cases[@]}"; do
    set +e
    value="$(
      SCRIPT_DIR="${repo_dir}/framework/scripts" \
      REPO_DIR="$repo_dir" \
      SCOPE="$scope" \
      bash -c 'source "${SCRIPT_DIR}/git-deploy-context.sh"; classify_scope_impact; rc=$?; printf "RC=%s\nIMPACT=%s\nREASON=%s\nUNKNOWN=%s\n" "$rc" "${SCOPE_IMPACT:-}" "${SCOPE_IMPACT_REASON:-}" "${SCOPE_UNKNOWN_TARGETS:-}"; exit 0' 2>&1
    )"
    rc=$?
    set -e
    output+=$'SCOPE='"${scope}"$'\n'
    output+=$'SHELL_RC='"${rc}"$'\n'
    output+="${value}"$'\n---\n'
  done
  printf '%s' "$output"
}

setup_safe_apply_shims() {
  local shim_dir="$1"
  local plan_json="$2"
  local wrapper_log="$3"
  mkdir -p "$shim_dir"

  cat > "${shim_dir}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -chdir=* && "${2:-}" == "show" && "${3:-}" == "-json" ]]; then
  cat "${FIXTURE_PLAN_JSON:?}"
  exit 0
fi
exit 99
EOF
  chmod +x "${shim_dir}/tofu"

  cat > "${shim_dir}/tofu-wrapper-shim" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${WRAPPER_LOG:?}"
if [[ "${1:-}" == "plan" ]]; then
  out=""
  for arg in "$@"; do
    case "$arg" in
      -out=*) out="${arg#-out=}" ;;
    esac
  done
  [[ -n "$out" ]] || exit 98
  printf 'stub plan\n' > "$out"
  exit 0
fi
exit 99
EOF
  chmod +x "${shim_dir}/tofu-wrapper-shim"

  cat > "${shim_dir}/true-shim" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${shim_dir}/true-shim"

  cat > "$plan_json" <<'JSON'
{
  "format_version": "1.2",
  "resource_changes": [
    {"address":"module.dns_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"started":true},"after":{"started":true}}},
    {"address":"module.cpnix_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true,"disk":[{"interface":"scsi0"},{"interface":"scsi1"}],"initialization":[{}]}}},
    {"address":"module.cpvendor_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true,"disk":[{"interface":"scsi0"}]}}},
    {"address":"module.vault_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true,"disk":[{"interface":"scsi0"},{"interface":"scsi1"}],"initialization":[{}]}}},
    {"address":"module.hil_boot.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"started":true},"after":{"started":true}}},
    {"address":"module.gatus.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"started":true},"after":{"started":true}}},
    {"address":"module.gitlab.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true}}},
    {"address":"module.pbs.proxmox_virtual_environment_vm.vm","change":{"actions":["update"],"before":{"started":true},"after":{"started":true}}},
    {"address":"module.grafana_dev[0].proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true,"disk":[{"interface":"scsi0"},{"interface":"scsi1"}],"initialization":[{}]}}},
    {"address":"module.grafana_prod.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"before":null,"after":{"started":true,"disk":[{"interface":"scsi0"},{"interface":"scsi1"}],"initialization":[{}]}}}
  ]
}
JSON
  : > "$wrapper_log"
}

run_safe_apply_corpus() {
  local repo_dir="$1"
  local shim_dir="${TMP_DIR}/safe-shims"
  local plan_json="${TMP_DIR}/safe-plan.json"
  local wrapper_log="${TMP_DIR}/safe-wrapper.log"
  local output=""
  local env rc raw

  setup_safe_apply_shims "$shim_dir" "$plan_json" "$wrapper_log"

  for env in dev prod; do
    : > "$wrapper_log"
    set +e
    raw="$(
      cd "$repo_dir" && \
      PATH="${shim_dir}:${PATH}" \
      FIXTURE_PLAN_JSON="$plan_json" \
      WRAPPER_LOG="$wrapper_log" \
      MYCOFU_TOFU_WRAPPER="${shim_dir}/tofu-wrapper-shim" \
      MYCOFU_APPROLE_CHECK="${shim_dir}/true-shim" \
      MYCOFU_DRIFT_CHECK="${shim_dir}/true-shim" \
        framework/scripts/safe-apply.sh "$env" --dry-run 2>&1
    )"
    rc=$?
    set -e

    output+=$'ENV='"${env}"$'\n'
    output+=$'RC='"${rc}"$'\n'
    output+="$(
      printf '%s\n' "$raw" | grep -E '^(Restore entries:|Targets:|WARNING: module|\(dry-run|No changes)' || true
    )"$'\n'
    if [[ -f "${repo_dir}/build/preboot-restore-${env}.json" ]]; then
      output+="$(
        jq -S '[.entries[] | {env, expected_disks, kind, module, reason}]' "${repo_dir}/build/preboot-restore-${env}.json"
      )"$'\n'
    fi
    output+=$'WRAPPER_LOG\n'
    output+="$(
      sed -E \
        -e 's#-out=[^ ]*/safe-apply\.[^ ]*/plan\.out#-out=<tmp>/plan.out#g' \
        -e 's#plan (-exclude=module\.[^ ]+ ?)+-out=<tmp>/plan\.out#plan <control-plane-excludes> -out=<tmp>/plan.out#g' \
        "$wrapper_log"
    )"$'\n---\n'
  done
  printf '%s' "$output"
}

test_start "GM1" "converge_target_envs golden corpus"
fixture="${TMP_DIR}/fixture"
setup_fixture_repo "$fixture"
record_or_compare "converge-target-envs.txt" "$(run_converge_corpus "$fixture")"

test_start "GM2" "classify_scope_impact golden corpus"
record_or_compare "scope-impact.txt" "$(run_scope_corpus "$fixture")"

test_start "GM3" "safe-apply target and preboot manifest golden corpus"
safe_apply_output="$(run_safe_apply_corpus "$fixture")"
record_or_compare "safe-apply.txt" "$safe_apply_output"

test_start "GM3a" "safe-apply golden exposes all four preboot kind branches"
assert_contains_text "$safe_apply_output" '"module": "module.cpnix_dev"' "control-plane Nix fixture appears in preboot golden"
assert_contains_text "$safe_apply_output" '"module": "module.cpvendor_dev"' "control-plane vendor fixture appears in preboot golden"
assert_contains_text "$safe_apply_output" '"module": "module.vault_dev"' "infrastructure fixture appears in preboot golden"
assert_contains_text "$safe_apply_output" '"module": "module.grafana_dev"' "application fixture appears in preboot golden"
assert_contains_text "$safe_apply_output" 'WARNING: module module.pbs does not match any environment -- skipping' "module.pbs is present in the plan fixture and classified as control-plane"

runner_summary
