#!/usr/bin/env bash
# test_workstation_module.sh — Verify workstation catalog wiring and contracts.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

APPS_CONFIG="${REPO_ROOT}/site/applications.yaml"
HEALTH_FILE="${REPO_ROOT}/framework/catalog/workstation/health.yaml"
VAULT_REQUIREMENTS="${REPO_ROOT}/framework/catalog/workstation/vault-requirements.yaml"
ROOT_TF="${REPO_ROOT}/framework/tofu/root/main.tf"
WORKSTATION_TF="${REPO_ROOT}/framework/catalog/workstation/main.tf"
WORKSTATION_TF_VARS="${REPO_ROOT}/framework/catalog/workstation/variables.tf"
WORKSTATION_MODULE="${REPO_ROOT}/framework/catalog/workstation/module.nix"
CONFIGURE_VAULT="${REPO_ROOT}/framework/scripts/configure-vault.sh"
GENERATE_GATUS="${REPO_ROOT}/framework/scripts/generate-gatus-config.sh"
VALIDATE_SCRIPT="${REPO_ROOT}/framework/scripts/validate.sh"
VM_HEALTH_LIB="${REPO_ROOT}/framework/scripts/vm-health-lib.sh"
RESTORE_SCRIPT="${REPO_ROOT}/framework/scripts/restore-from-pbs.sh"
VDB_STATE_LIB="${REPO_ROOT}/framework/scripts/vdb-state-lib.sh"
REBUILD_SCRIPT="${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"
CERTBOT_CLUSTER="${REPO_ROOT}/framework/scripts/certbot-cluster.sh"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"
VDB_WORD="vdb"
LEGACY_VDB_VAR="${VDB_WORD}_restore_expected"
LEGACY_VDB_TARGET="${VDB_WORD}-ready.target"

source "${VDB_STATE_LIB}"

run_local_workstation_vdb_probe() {
  local fixture_root="$1"
  local username="$2"
  local probe_script=""
  local username_file="${fixture_root}/run/secrets/workstation/username"

  mkdir -p "${fixture_root}/run/secrets/workstation"
  printf '%s\n' "${username}" > "${username_file}"

  probe_script="$(vdb_state_probe_script_for_label workstation)"
  probe_script="$(
    printf '%s\n' "${probe_script}" \
      | sed "s|/run/secrets/workstation/username|${username_file}|g" \
      | sed "s|/home|${fixture_root}/home|g"
  )"

  set +e
  LOCAL_PROBE_OUTPUT="$(printf '%s\n' "${probe_script}" | bash 2>&1)"
  LOCAL_PROBE_STATUS=$?
  set -e
}

test_start "1" "workstation catalog files exist"
if [[ -s "${REPO_ROOT}/framework/catalog/workstation/module.nix" ]] && \
   [[ -s "${REPO_ROOT}/framework/catalog/workstation/main.tf" ]] && \
   [[ -s "${REPO_ROOT}/framework/catalog/workstation/variables.tf" ]] && \
   [[ -s "${REPO_ROOT}/framework/catalog/workstation/outputs.tf" ]] && \
   [[ -s "${REPO_ROOT}/framework/catalog/workstation/README.md" ]] && \
   [[ -s "${REPO_ROOT}/site/nix/hosts/workstation.nix" ]]; then
  test_pass "catalog module, Terraform wrapper, docs, and host config are present"
else
  test_fail "workstation catalog files are missing"
fi

test_start "2" "applications.yaml defines the workstation contract"
# Sprint 028: the 'enabled' field is operator policy (not a contract
# assertion). workstation can be disabled while Sprint 029 pre-boot-
# restore lands; the contract below asserts the shape of the fields
# that MUST be present when someone does re-enable it.
if [[ "$(yq -r '.applications.workstation.username // ""' "${APPS_CONFIG}")" == "kentaro" ]] && \
   [[ "$(yq -r '.applications.workstation.shell // ""' "${APPS_CONFIG}")" == "zsh" ]] && \
   [[ "$(yq -r '.applications.workstation.ram_prod // 0' "${APPS_CONFIG}")" == "16384" ]] && \
   [[ "$(yq -r '.applications.workstation.ram_dev // 0' "${APPS_CONFIG}")" == "4096" ]] && \
   [[ "$(yq -r '.applications.workstation.cpus_prod // 0' "${APPS_CONFIG}")" == "8" ]] && \
   [[ "$(yq -r '.applications.workstation.cpus_dev // 0' "${APPS_CONFIG}")" == "2" ]] && \
   [[ "$(yq -r '.applications.workstation.environments.prod.vmid // 0' "${APPS_CONFIG}")" == "801" ]] && \
   [[ "$(yq -r '.applications.workstation.environments.dev.vmid // 0' "${APPS_CONFIG}")" == "701" ]] && \
   [[ "$(yq -r '.applications.workstation.environments.dev.mgmt_nic.name // ""' "${APPS_CONFIG}")" == "workstation-mgmt" ]]; then
  test_pass "applications.yaml includes the required workstation fields"
else
  test_fail "applications.yaml is missing required workstation fields"
fi

test_start "3" "validate-site-config.sh accepts the workstation VMID ranges in the current repo"
if (
  cd "${REPO_ROOT}"
  bash framework/scripts/validate-site-config.sh
) >/dev/null 2>&1; then
  test_pass "config validation accepts the 7xx/8xx workstation entry"
else
  test_fail "config validation rejects the workstation entry"
fi

test_start "4" "health metadata publishes the workstation endpoint"
if [[ "$(yq -r '.port // ""' "${HEALTH_FILE}")" == "8443" ]] && \
   [[ "$(yq -r '.path // ""' "${HEALTH_FILE}")" == "/status" ]]; then
  test_pass "workstation health metadata points to :8443/status"
else
  test_fail "workstation health metadata is incorrect"
fi

test_start "5" "workstation AppRole manifest and root Terraform are wired"
if grep -Fq 'name_template: "workstation_${env}"' "${VAULT_REQUIREMENTS}" && \
   grep -Fq 'policy: "workstation-tailscale-policy"' "${VAULT_REQUIREMENTS}" && \
   grep -Fq 'variable "vault_approle_workstation_dev_role_id"' "${ROOT_TF}" && \
   grep -Fq 'variable "vault_approle_workstation_prod_role_id"' "${ROOT_TF}" && \
   grep -Fq 'module "workstation_dev"' "${ROOT_TF}" && \
   grep -Fq 'module "workstation_prod"' "${ROOT_TF}"; then
  test_pass "manifest, variables, and root modules are present"
else
  test_fail "workstation AppRole/root Terraform wiring is incomplete"
fi

test_start "6" "configure-vault and certbot inventory include workstation cert storage"
if grep -Fq 'Writing workstation-tailscale-policy...' "${CONFIGURE_VAULT}" && \
   grep -Fq 'path "secret/data/tailscale/nodes/${DOMAIN}/workstation-${ENV}"' "${CONFIGURE_VAULT}" && \
   grep -Fq 'dns1|dns2|gatus|gitlab|testapp|influxdb|grafana|workstation)' "${CONFIGURE_VAULT}" && \
   grep -Fq 'certbot_cluster_cert_storage_records() {' "${CERTBOT_CLUSTER}" && \
   grep -Fq 'cert-workstation-prod' "${CERTBOT_CLUSTER}" && \
   grep -Fq 'cert-workstation-dev' "${CERTBOT_CLUSTER}"; then
  test_pass "workstation Tailscale and cert-storage wiring are present"
else
  test_fail "workstation Tailscale or cert-storage wiring is incomplete"
fi

setup_wrapper_fixture() {
  local repo_dir="$1"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/framework/catalog/workstation" \
    "${repo_dir}/framework/tofu/root" \
    "${repo_dir}/site/sops" \
    "${repo_dir}/site/tofu"

  cp "${REPO_ROOT}/framework/scripts/tofu-wrapper.sh" \
    "${repo_dir}/framework/scripts/tofu-wrapper.sh"
  cp "${REPO_ROOT}/framework/scripts/vault-requirements-lib.sh" \
    "${repo_dir}/framework/scripts/vault-requirements-lib.sh"
  cp "${REPO_ROOT}/framework/catalog/workstation/vault-requirements.yaml" \
    "${repo_dir}/framework/catalog/workstation/vault-requirements.yaml"
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
  value = var.image_versions["workstation"]
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
  workstation:
    enabled: true
    environments:
      dev:
        vmid: 701
      prod:
        vmid: 801
EOF

  cat > "${repo_dir}/site/sops/secrets.yaml" <<'EOF'
{}
EOF

  cat > "${repo_dir}/site/tofu/image-versions.auto.tfvars" <<'EOF'
image_versions = {
  "workstation" = "workstation-deadbeef.img"
}
EOF

  cat > "${repo_dir}/operator.age.key" <<'EOF'
AGE-SECRET-KEY-FAKE
EOF
}

setup_shims() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/sops" <<'EOF'
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
  chmod +x "${shim_dir}/sops"

  cat > "${shim_dir}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${STUB_TOFU_MODE:-}" == "envdump" ]]; then
  env | grep '^TF_VAR_vault_approle_' | cut -d= -f1 | sort
  exit 0
fi

exit 0
EOF
  chmod +x "${shim_dir}/tofu"
}

test_start "7" "tofu-wrapper exports workstation AppRole variables for an enabled manifest-backed app"
WRAPPER_FIXTURE="${TMP_DIR}/wrapper-fixture"
SHIM_DIR="${TMP_DIR}/shims"
setup_wrapper_fixture "${WRAPPER_FIXTURE}"
setup_shims "${SHIM_DIR}"
WRAPPER_SOPS_JSON="$(cat <<'EOF'
{
  "proxmox_api_user": "user@pam",
  "proxmox_api_password": "pw",
  "tofu_db_password": "pw",
  "ssh_pubkey": "ssh-ed25519 AAAA test",
  "pdns_api_key": "pdns",
  "influxdb_admin_token": "",
  "grafana_admin_password": "",
  "grafana_influxdb_token": "",
  "tailscale_auth_key": "tskey",
  "ssh_privkey": "",
  "ssh_host_keys": {},
  "vault_approle_workstation_dev_role_id": "role-dev",
  "vault_approle_workstation_dev_secret_id": "secret-dev",
  "vault_approle_workstation_prod_role_id": "role-prod",
  "vault_approle_workstation_prod_secret_id": "secret-prod"
}
EOF
)"
EXPECTED_VARS="$(cat <<'EOF'
TF_VAR_vault_approle_workstation_dev_role_id
TF_VAR_vault_approle_workstation_dev_secret_id
TF_VAR_vault_approle_workstation_prod_role_id
TF_VAR_vault_approle_workstation_prod_secret_id
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
WRAPPER_ENV_LINES="$(printf '%s\n' "${WRAPPER_OUTPUT}" | grep '^TF_VAR_vault_approle_workstation_' || true)"
if [[ "${WRAPPER_STATUS}" -eq 0 ]] && [[ "${WRAPPER_ENV_LINES}" == "${EXPECTED_VARS}" ]]; then
  test_pass "wrapper exports the workstation AppRole TF_VAR set"
else
  test_fail "wrapper exports the workstation AppRole TF_VAR set"
  printf '    output:\n%s\n' "${WRAPPER_OUTPUT}" >&2
fi

test_start "8" "generate-gatus-config emits workstation health, cert, and SSH monitors"
# Sprint 028: only asserted when workstation is enabled. When
# disabled (e.g., Sprint 028 baseline pending Sprint 029 pre-boot-
# restore), the generator correctly omits workstation monitors.
WORKSTATION_ENABLED="$(yq -r '.applications.workstation.enabled' "${APPS_CONFIG}")"
if [[ "${WORKSTATION_ENABLED}" != "true" ]]; then
  test_pass "workstation disabled; Gatus monitor assertion is skipped by design"
else
  GATUS_OUTPUT="$("${GENERATE_GATUS}" 2>/dev/null)"
  if grep -Fq 'name: workstation-prod' <<< "${GATUS_OUTPUT}" && \
     grep -Fq 'name: workstation-dev' <<< "${GATUS_OUTPUT}" && \
     grep -Fq 'name: workstation-ssh-prod' <<< "${GATUS_OUTPUT}" && \
     grep -Fq 'name: workstation-ssh-dev' <<< "${GATUS_OUTPUT}" && \
     grep -Fq 'name: cert-workstation-prod' <<< "${GATUS_OUTPUT}" && \
     grep -Fq 'name: cert-workstation-dev' <<< "${GATUS_OUTPUT}"; then
    test_pass "Gatus generation covers prod and dev workstation monitors"
  else
    test_fail "Gatus generation is missing workstation monitors"
  fi
fi

test_start "9" "validate.sh contains the workstation functional health assertion"
if grep -Fq '${APP}-${ENV} health payload reports healthy' "${VALIDATE_SCRIPT}" && \
   grep -Fq '.home.mounted == true' "${VALIDATE_SCRIPT}" && \
   grep -Fq '.nix.shell_ok == true' "${VALIDATE_SCRIPT}" && \
   grep -Fq '.vault_agent_authenticated == true' "${VALIDATE_SCRIPT}"; then
  test_pass "validate.sh checks the workstation functional health payload"
else
  test_fail "validate.sh is missing the workstation health payload check"
fi

test_start "10" "CI builds and validates the workstation image"
if grep -Fq 'nix build .#packages.x86_64-linux.workstation-image --no-link' "${CI_FILE}" && \
   grep -Fq 'nix eval .#nixosConfigurations.workstation_dev.config.system.build.toplevel.drvPath' "${CI_FILE}" && \
   grep -Fq 'nix eval .#nixosConfigurations.workstation_prod.config.system.build.toplevel.drvPath' "${CI_FILE}" && \
   grep -Fq 'bash tests/test_workstation_module.sh' "${CI_FILE}"; then
  test_pass "CI wiring includes the workstation image, evals, and contract test"
else
  test_fail "CI wiring is missing workstation validation"
fi

test_start "11" "workstation precious-state wiring uses orchestration-owned restore"
if grep -Eq 'vdb_size_gb[[:space:]]*=[[:space:]]*var\.vdb_size_gb' "${WORKSTATION_TF}" && \
   grep -Eq 'vdb_size_gb[[:space:]]*=[[:space:]]*try\(local\.app_workstation\.data_disk_size_dev' "${ROOT_TF}" && \
   grep -Eq 'vdb_size_gb[[:space:]]*=[[:space:]]*try\(local\.app_workstation\.data_disk_size_prod' "${ROOT_TF}" && \
   ! grep -Fq "${LEGACY_VDB_VAR}" "${WORKSTATION_TF_VARS}" && \
   ! grep -Fq "${LEGACY_VDB_TARGET}" "${WORKSTATION_MODULE}"; then
  test_pass "workstation /home keeps a data disk without guest-side vdb gate wiring"
else
  test_fail "workstation /home orchestration-owned precious-state wiring is incomplete"
fi

test_start "12" "format-home treats blkid failures as fatal and only exit code 2 as blank"
if grep -Fq 'BLKID_RC=$?' "${WORKSTATION_MODULE}" && \
   grep -Fq 'blkid -o export "$HOME_DISK"' "${WORKSTATION_MODULE}" && \
   grep -Fq 'case "$BLKID_RC" in' "${WORKSTATION_MODULE}" && \
   grep -Fq 'wipefs failed with exit code' "${WORKSTATION_MODULE}"; then
  test_pass "format-home distinguishes blank disks from probe failures"
else
  test_fail "format-home blkid/wipefs handling is incomplete"
fi

test_start "13" "restore and health scripts recognize workstation /home state"
if grep -Fq 'workstation*)' "${VDB_STATE_LIB}" && \
   grep -Fq 'authorized_keys' "${VDB_STATE_LIB}" && \
   grep -Fq 'vm_health_workstation' "${VM_HEALTH_LIB}" && \
   grep -Fq 'vdb_state_probe_script_for_label' "${RESTORE_SCRIPT}"; then
  test_pass "restore and health code paths share the workstation /home probe"
else
  test_fail "workstation /home restore/health probes are not wired end-to-end"
fi

test_start "14" "CI deploys workstation closures after env deploys"
if grep -Fq 'framework/scripts/deploy-workstation-closure.sh dev' "${CI_FILE}" && \
   grep -Fq 'framework/scripts/deploy-workstation-closure.sh prod' "${CI_FILE}" && \
   grep -Fq 'bash -n framework/scripts/deploy-workstation-closure.sh' "${CI_FILE}"; then
  test_pass "CI deploy path includes workstation closure pushes"
else
  test_fail "CI deploy path is missing the workstation closure push"
fi

test_start "15" "workstation probe remains shared by script tooling"
if grep -Fq 'vdb_state_probe_script_for_label()' "${VDB_STATE_LIB}" && \
   grep -Fq 'workstation*)' "${VDB_STATE_LIB}" && \
   grep -Fq 'framework/scripts/vdb-state-lib.sh' "${REPO_ROOT}/flake.nix"; then
  test_pass "workstation /home probe is still shipped through nixSrc"
else
  test_fail "workstation probe wiring is incomplete"
fi

test_start "16" "bootstrap-only /home does not satisfy the workstation restore probe"
BOOTSTRAP_ONLY_FIXTURE="${TMP_DIR}/workstation-bootstrap-only"
mkdir -p \
  "${BOOTSTRAP_ONLY_FIXTURE}/home/lost+found" \
  "${BOOTSTRAP_ONLY_FIXTURE}/home/kentaro/.ssh"
printf '%s\n' 'ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQABAAABAQDb bootstrap@test' \
  > "${BOOTSTRAP_ONLY_FIXTURE}/home/kentaro/.ssh/authorized_keys"
run_local_workstation_vdb_probe "${BOOTSTRAP_ONLY_FIXTURE}" "kentaro"
if [[ "${LOCAL_PROBE_STATUS}" -eq 1 ]]; then
  test_pass "bootstrap-only /home is rejected by the workstation vdb probe"
else
  test_fail "bootstrap-only /home incorrectly satisfies the workstation vdb probe"
  printf '    output:\n%s\n' "${LOCAL_PROBE_OUTPUT}" >&2
fi

test_start "17" "real workstation /home satisfies the workstation restore probe"
REAL_STATE_FIXTURE="${TMP_DIR}/workstation-real-state"
mkdir -p \
  "${REAL_STATE_FIXTURE}/home/lost+found" \
  "${REAL_STATE_FIXTURE}/home/kentaro/.ssh"
printf '%s\n' 'ssh-ed25519 AAAAB3NzaC1yc2EAAAADAQABAAABAQDb bootstrap@test' \
  > "${REAL_STATE_FIXTURE}/home/kentaro/.ssh/authorized_keys"
printf '%s\n' 'export PATH="$HOME/bin:$PATH"' > "${REAL_STATE_FIXTURE}/home/kentaro/.zshrc"
run_local_workstation_vdb_probe "${REAL_STATE_FIXTURE}" "kentaro"
if [[ "${LOCAL_PROBE_STATUS}" -eq 0 ]]; then
  test_pass "real /home content satisfies the workstation vdb probe"
else
  test_fail "real /home content is rejected by the workstation vdb probe"
  printf '    output:\n%s\n' "${LOCAL_PROBE_OUTPUT}" >&2
fi

test_start "18" "workstation-health-check unit sets NIX_PATH"
# The health check runs nix-shell -p hello --run hello, which resolves
# <nixpkgs> via NIX_PATH. Login shells pick NIX_PATH up from /etc/profile,
# but systemd units don't. Without an explicit Environment entry, nix-shell
# fails with "file 'nixpkgs' was not found in the Nix search path" and
# the whole health check reports unhealthy even when every other sub-check
# passes.
if grep -Eq 'environment(\.NIX_PATH\s*=|\s*=\s*\{[^}]*NIX_PATH\s*=)' "${WORKSTATION_MODULE}" && \
   grep -Fq 'nixpkgs=flake:nixpkgs' "${WORKSTATION_MODULE}"; then
  test_pass "workstation-health-check sets NIX_PATH in its systemd environment"
else
  test_fail "workstation-health-check is missing the NIX_PATH environment entry"
fi

runner_summary
