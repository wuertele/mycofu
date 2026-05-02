#!/usr/bin/env bash
# test_dashboard_secret_plumbing.sh — Verify Vault/AppRole plumbing for the dashboard.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

POLICY_FILE="${REPO_ROOT}/framework/vault/policies/dashboard.hcl"
TOFU_WRAPPER="${REPO_ROOT}/framework/scripts/tofu-wrapper.sh"
CONFIGURE_VAULT="${REPO_ROOT}/framework/scripts/configure-vault.sh"
CONFIGURE_TOKENS="${REPO_ROOT}/framework/scripts/configure-dashboard-tokens.sh"
POST_DEPLOY="${REPO_ROOT}/framework/scripts/post-deploy.sh"
ROOT_TF="${REPO_ROOT}/framework/tofu/root/main.tf"
INFLUXDB_TF="${REPO_ROOT}/framework/catalog/influxdb/main.tf"
INFLUXDB_MODULE="${REPO_ROOT}/framework/catalog/influxdb/module.nix"

test_start "1" "dashboard Vault policy grants read access to dashboard KV paths"
if grep -Fq 'path "secret/data/dashboard/*"' "${POLICY_FILE}" && \
   grep -Fq 'capabilities = ["read"]' "${POLICY_FILE}"; then
  test_pass "dashboard policy is scoped to read-only dashboard secrets"
else
  test_fail "dashboard Vault policy is missing or overly broad"
fi

test_start "2" "tofu-wrapper exports dashboard AppRole credentials"
if grep -Fq 'EXPORTED_APPROLE_ROLES=' "${TOFU_WRAPPER}" && \
   grep -Fq 'influxdb_dev influxdb_prod testapp_dev testapp_prod grafana_dev grafana_prod' "${TOFU_WRAPPER}" && \
   grep -Fq 'TF_VAR_vault_approle_${ROLE}_role_id' "${TOFU_WRAPPER}" && \
   grep -Fq 'TF_VAR_vault_approle_${ROLE}_secret_id' "${TOFU_WRAPPER}"; then
  test_pass "tofu-wrapper exports the influxdb dashboard AppRole variables"
else
  test_fail "tofu-wrapper is not exporting the dashboard AppRole variables"
fi

test_start "3" "configure-vault wires the dashboard policy onto influxdb roles"
if grep -Fq 'for policy in dns vault-self default github-publish dashboard; do' "${CONFIGURE_VAULT}" && \
   grep -Fq 'role_policies_for_vm_key() {' "${CONFIGURE_VAULT}" && \
   grep -Fq 'prod) roles="dns1_prod dns2_prod gatus gitlab cicd influxdb_prod testapp_prod" ;;' "${CONFIGURE_VAULT}" && \
   grep -Fq 'dev)  roles="dns1_dev dns2_dev influxdb_dev testapp_dev" ;;' "${CONFIGURE_VAULT}" && \
   grep -Fq 'influxdb)  role_policies="default-policy,dashboard-policy" ;;' "${CONFIGURE_VAULT}" && \
   grep -Fq 'role_policies="${role_policies},$(cert_storage_policy_name_for_vm_key "$vm_key")"' "${CONFIGURE_VAULT}"; then
  test_pass "configure-vault adds dashboard policy and includes both influxdb roles"
else
  test_fail "configure-vault does not fully wire the dashboard AppRoles"
fi

test_start "4" "root Terraform declares and passes the new AppRole variables"
if grep -Fq 'variable "vault_approle_influxdb_dev_role_id"' "${ROOT_TF}" && \
   grep -Fq 'variable "vault_approle_influxdb_dev_secret_id"' "${ROOT_TF}" && \
   grep -Fq 'variable "vault_approle_influxdb_prod_role_id"' "${ROOT_TF}" && \
   grep -Fq 'variable "vault_approle_influxdb_prod_secret_id"' "${ROOT_TF}" && \
   grep -Fq 'vault_approle_role_id   = var.vault_approle_role_id' "${INFLUXDB_TF}" && \
   grep -Fq 'vault_approle_secret_id = var.vault_approle_secret_id' "${INFLUXDB_TF}"; then
  test_pass "Terraform surface includes the dashboard AppRole credential plumbing"
else
  test_fail "Terraform is missing the dashboard AppRole credential plumbing"
fi

test_start "5" "influxdb module renders both dashboard runtime tokens via vault-agent"
if grep -Fq 'destination = "/run/secrets/proxmox-api-token"' "${INFLUXDB_MODULE}" && \
   grep -Fq 'destination = "/run/secrets/dashboard-influxdb-token"' "${INFLUXDB_MODULE}" && \
   grep -Fq 'secret/data/dashboard/%s/proxmox-api-token' "${INFLUXDB_MODULE}" && \
   grep -Fq 'secret/data/dashboard/%s/influxdb-token' "${INFLUXDB_MODULE}"; then
  test_pass "influxdb module renders both dashboard secrets from Vault"
else
  test_fail "influxdb module does not render both dashboard secrets from Vault"
fi

test_start "6" "configure-dashboard-tokens provisions and stores both scoped tokens"
if grep -Fq 'secret/data/dashboard/${ENV}/proxmox-api-token' "${CONFIGURE_TOKENS}" && \
   grep -Fq 'secret/data/dashboard/${ENV}/influxdb-token' "${CONFIGURE_TOKENS}" && \
   grep -Fq 'PVEAPIToken=${user}!${token_name}=${secret}' "${CONFIGURE_TOKENS}" && \
   grep -Fq '/api/v2/authorizations' "${CONFIGURE_TOKENS}" && \
   grep -Fq 'cluster-dashboard-${ENV}' "${CONFIGURE_TOKENS}"; then
  test_pass "dashboard token provisioning covers Proxmox and scoped InfluxDB tokens"
else
  test_fail "configure-dashboard-tokens is missing required token provisioning steps"
fi

test_start "7" "post-deploy provisions dashboard tokens after Vault configuration"
VAULT_LINE="$(grep -Fn '"${SCRIPT_DIR}/configure-vault.sh"' "${POST_DEPLOY}" | head -1 | cut -d: -f1 || true)"
TOKENS_LINE="$(grep -Fn '"${SCRIPT_DIR}/configure-dashboard-tokens.sh"' "${POST_DEPLOY}" | head -1 | cut -d: -f1 || true)"
if [[ -n "${VAULT_LINE}" && -n "${TOKENS_LINE}" && "${TOKENS_LINE}" -gt "${VAULT_LINE}" ]]; then
  test_pass "post-deploy calls dashboard token provisioning after Vault configuration"
else
  test_fail "post-deploy does not provision dashboard tokens after Vault configuration"
fi

runner_summary
