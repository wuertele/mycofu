#!/usr/bin/env bash
# V2.1: tofu-wrapper no longer exports runner key material as TF_VARs.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

WRAPPER="${REPO_ROOT}/framework/scripts/tofu-wrapper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
ENV_DUMP="${TMP_DIR}/tofu-env.txt"
AGE_KEY_FILE="${TMP_DIR}/synthetic.age.key"

mkdir -p \
  "${FIXTURE_REPO}/framework/scripts" \
  "${FIXTURE_REPO}/framework/tofu/root" \
  "${FIXTURE_REPO}/site/sops" \
  "${FIXTURE_REPO}/site/tofu" \
  "${SHIM_DIR}" \
  "${TMP_DIR}/home"

cp "$WRAPPER" "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

printf 'fixture flake\n' > "${FIXTURE_REPO}/flake.nix"
printf 'SYNTHETIC-AGE-KEY-SENTINEL\n' > "$AGE_KEY_FILE"
printf 'SYNTHETIC-SOPS-CIPHERTEXT-SENTINEL\n' > "${FIXTURE_REPO}/site/sops/secrets.yaml"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nas:
  ip: 10.0.0.10
  postgres_port: 5432
nodes:
  - mgmt_ip: 10.0.0.11
github:
  remote_url: git@example.invalid:root/mycofu.git
vms: {}
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
# No image_versions references are needed for this wrapper env-export fixture.
EOF

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{
  "proxmox_api_user": "synthetic-user@pam",
  "proxmox_api_password": "SYNTHETIC-PVE-PASSWORD",
  "tofu_db_password": "SYNTHETIC-TOFU-DB-PASSWORD",
  "ssh_pubkey": "ssh-ed25519 SYNTHETIC-PUBLIC-KEY fixture",
  "pdns_api_key": "SYNTHETIC-PDNS-API-KEY",
  "influxdb_admin_token": "SYNTHETIC-INFLUXDB-ADMIN-TOKEN",
  "grafana_admin_password": "SYNTHETIC-GRAFANA-PASSWORD",
  "grafana_influxdb_token": "SYNTHETIC-GRAFANA-INFLUXDB-TOKEN",
  "tailscale_auth_key": "SYNTHETIC-TAILSCALE-AUTH-KEY",
  "ssh_host_keys": {},
  "vault_approle_dns1_prod_role_id": "synthetic",
  "vault_approle_dns1_prod_secret_id": "synthetic",
  "vault_approle_dns2_prod_role_id": "synthetic",
  "vault_approle_dns2_prod_secret_id": "synthetic",
  "vault_approle_dns1_dev_role_id": "synthetic",
  "vault_approle_dns1_dev_secret_id": "synthetic",
  "vault_approle_dns2_dev_role_id": "synthetic",
  "vault_approle_dns2_dev_secret_id": "synthetic",
  "vault_approle_gatus_role_id": "synthetic",
  "vault_approle_gatus_secret_id": "synthetic",
  "vault_approle_gitlab_role_id": "synthetic",
  "vault_approle_gitlab_secret_id": "synthetic",
  "vault_approle_cicd_role_id": "synthetic",
  "vault_approle_cicd_secret_id": "synthetic",
  "vault_approle_influxdb_dev_role_id": "synthetic",
  "vault_approle_influxdb_dev_secret_id": "synthetic",
  "vault_approle_influxdb_prod_role_id": "synthetic",
  "vault_approle_influxdb_prod_secret_id": "synthetic",
  "vault_approle_testapp_dev_role_id": "synthetic",
  "vault_approle_testapp_dev_secret_id": "synthetic",
  "vault_approle_testapp_prod_role_id": "synthetic",
  "vault_approle_testapp_prod_secret_id": "synthetic",
  "vault_approle_grafana_dev_role_id": "synthetic",
  "vault_approle_grafana_dev_secret_id": "synthetic",
  "vault_approle_grafana_prod_role_id": "synthetic",
  "vault_approle_grafana_prod_secret_id": "synthetic"
}
JSON
EOF
chmod +x "${SHIM_DIR}/sops"

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
env | sed -n 's/^\(TF_VAR_[^=]*\)=.*/\1/p' | sort > "${STUB_TOFU_ENV_DUMP}"
exit 0
EOF
chmod +x "${SHIM_DIR}/tofu"

cat > "${SHIM_DIR}/nix" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${SHIM_DIR}/nix"

EXPECTED_TF_VARS="$(cat <<'EOF'
TF_VAR_github_remote_url
TF_VAR_grafana_admin_password
TF_VAR_grafana_influxdb_token
TF_VAR_influxdb_admin_token
TF_VAR_pdns_api_key
TF_VAR_ssh_host_keys_json
TF_VAR_ssh_pubkey
TF_VAR_tailscale_auth_key
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

test_start "V2.1-static" "removed runner key TF_VAR names are absent from tofu-wrapper.sh"
if ! grep -Fq 'TF_VAR_sops_age_key' "$WRAPPER" &&
   ! grep -Fq 'TF_VAR_ssh_privkey' "$WRAPPER"; then
  test_pass "tofu-wrapper.sh contains neither removed TF_VAR export"
else
  test_fail "tofu-wrapper.sh still references a removed runner-key TF_VAR"
fi

test_start "V2.1-env" "child tofu process does not receive removed runner key TF_VARs"
set +e
WRAPPER_OUTPUT="$(
  env -i \
    PATH="${SHIM_DIR}:${PATH}" \
    HOME="${TMP_DIR}/home" \
    SOPS_AGE_KEY_FILE="$AGE_KEY_FILE" \
    STUB_TOFU_ENV_DUMP="$ENV_DUMP" \
    bash -c 'cd "$1" && framework/scripts/tofu-wrapper.sh state list' bash "$FIXTURE_REPO" 2>&1
)"
WRAPPER_STATUS=$?
set -e
if [[ "$WRAPPER_STATUS" -eq 0 ]] &&
   [[ -s "$ENV_DUMP" ]] &&
   ! grep -Fxq 'TF_VAR_sops_age_key' "$ENV_DUMP" &&
   ! grep -Fxq 'TF_VAR_ssh_privkey' "$ENV_DUMP"; then
  test_pass "stub tofu env dump excludes TF_VAR_sops_age_key and TF_VAR_ssh_privkey"
else
  test_fail "stub tofu env dump includes a removed TF_VAR or wrapper failed"
  printf '%s\n' "$WRAPPER_OUTPUT" >&2
  [[ -f "$ENV_DUMP" ]] && cat "$ENV_DUMP" >&2
fi

test_start "V2.1-regression" "all remaining wrapper TF_VAR exports are preserved"
if diff -u <(printf '%s\n' "$EXPECTED_TF_VARS") "$ENV_DUMP" >/dev/null; then
  test_pass "remaining TF_VAR export list matches the MR-3 baseline"
else
  test_fail "remaining TF_VAR export list changed"
  diff -u <(printf '%s\n' "$EXPECTED_TF_VARS") "$ENV_DUMP" >&2 || true
fi

test_start "V2.1-missing-key" "wrapper still fails closed when no age key path is available"
set +e
MISSING_KEY_OUTPUT="$(
  env -i \
    PATH="${SHIM_DIR}:${PATH}" \
    HOME="${TMP_DIR}/missing-home" \
    STUB_TOFU_ENV_DUMP="${TMP_DIR}/missing-env.txt" \
    bash -c 'cd "$1" && framework/scripts/tofu-wrapper.sh state list' bash "$FIXTURE_REPO" 2>&1
)"
MISSING_KEY_STATUS=$?
set -e
if [[ "$MISSING_KEY_STATUS" -ne 0 ]] &&
   grep -Fq 'ERROR: No SOPS age key found.' <<< "$MISSING_KEY_OUTPUT"; then
  test_pass "missing age key fails before wrapper decryption"
else
  test_fail "missing age key did not fail closed"
  printf '%s\n' "$MISSING_KEY_OUTPUT" >&2
fi

runner_summary
