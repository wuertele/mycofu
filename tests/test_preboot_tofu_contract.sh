#!/usr/bin/env bash
# test_preboot_tofu_contract.sh — static checks for Sprint 031 Tofu controls.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

cd "$REPO_ROOT"

assert_variable_default_true() {
  local file="$1"
  local variable="$2"
  local block

  block="$(awk "/variable \"${variable}\"/,/^}/" "$file")"
  if grep -Fq "type        = bool" <<< "$block" &&
     grep -Fq "default     = true" <<< "$block"; then
    return 0
  fi
  return 1
}

test_start "1" "root variables default start_vms/register_ha to true"
if assert_variable_default_true "framework/tofu/root/variables.tf" "start_vms" &&
   assert_variable_default_true "framework/tofu/root/variables.tf" "register_ha"; then
  test_pass "root variables have safe direct-apply defaults"
else
  test_fail "root start_vms/register_ha variables must exist with default true"
fi

test_start "2" "reusable NixOS VM module variables default to true"
if assert_variable_default_true "framework/tofu/modules/proxmox-vm/variables.tf" "start_vms" &&
   assert_variable_default_true "framework/tofu/modules/proxmox-vm/variables.tf" "register_ha"; then
  test_pass "base module exposes start/HA variables"
else
  test_fail "base reusable VM module variables must exist with default true"
fi

test_start "3" "all reusable NixOS VM variants use var.start_vms"
missing_started=""
for file in \
  framework/tofu/modules/proxmox-vm/vm.tf \
  framework/tofu/modules/proxmox-vm-field-updatable/vm.tf \
  framework/tofu/modules/proxmox-vm-precious/vm.tf; do
  if ! grep -Fq "started = var.start_vms" "$file"; then
    missing_started+="${file} "
  fi
done

if [[ -z "$missing_started" ]]; then
  test_pass "all VM variants parameterize started"
else
  test_fail "VM variants missing started = var.start_vms: ${missing_started}"
fi

test_start "4" "base HA resource is gated by register_ha"
if grep -Fq "count = var.ha_enabled && var.register_ha ? 1 : 0" \
  framework/tofu/modules/proxmox-vm/ha.tf; then
  test_pass "HA resource creation is gated"
else
  test_fail "HA resource count must include var.register_ha"
fi

test_start "5" "role and catalog wrappers expose start_vms/register_ha"
missing_wrapper_vars=""
for file in \
  framework/tofu/modules/acme-dev/variables.tf \
  framework/tofu/modules/cicd/variables.tf \
  framework/tofu/modules/dns-pair/variables.tf \
  framework/tofu/modules/gatus/variables.tf \
  framework/tofu/modules/gitlab/variables.tf \
  framework/tofu/modules/testapp/variables.tf \
  framework/tofu/modules/vault/variables.tf \
  framework/catalog/grafana/variables.tf \
  framework/catalog/influxdb/variables.tf \
  framework/catalog/roon/variables.tf \
  framework/catalog/workstation/variables.tf; do
  if ! assert_variable_default_true "$file" "start_vms" ||
     ! assert_variable_default_true "$file" "register_ha"; then
    missing_wrapper_vars+="${file} "
  fi
done

if [[ -z "$missing_wrapper_vars" ]]; then
  test_pass "wrappers expose the controls"
else
  test_fail "wrappers missing start_vms/register_ha variables: ${missing_wrapper_vars}"
fi

test_start "6" "wrappers pass start_vms/register_ha to reusable modules"
missing_wrapper_pass=""
for file in \
  framework/tofu/modules/acme-dev/main.tf \
  framework/tofu/modules/cicd/main.tf \
  framework/tofu/modules/dns-pair/main.tf \
  framework/tofu/modules/gatus/main.tf \
  framework/tofu/modules/gitlab/main.tf \
  framework/tofu/modules/testapp/main.tf \
  framework/tofu/modules/vault/main.tf \
  framework/catalog/grafana/main.tf \
  framework/catalog/influxdb/main.tf \
  framework/catalog/roon/main.tf \
  framework/catalog/workstation/main.tf; do
  if ! grep -Fq "start_vms" "$file" ||
     ! grep -Fq "register_ha" "$file"; then
    missing_wrapper_pass+="${file} "
  fi
done

if [[ -z "$missing_wrapper_pass" ]]; then
  test_pass "wrappers pass controls through"
else
  test_fail "wrappers missing start/HA pass-through: ${missing_wrapper_pass}"
fi

test_start "7" "root passes controls to every non-PBS VM wrapper"
start_count="$(grep -Ec '^[[:space:]]+start_vms[[:space:]]+= var\.start_vms' framework/tofu/root/main.tf)"
ha_count="$(grep -Ec '^[[:space:]]+register_ha[[:space:]]+= var\.register_ha' framework/tofu/root/main.tf)"
if [[ "$start_count" -eq 18 && "$ha_count" -eq 18 ]]; then
  test_pass "root passes controls to 18 NixOS module instances"
else
  test_fail "root pass-through count mismatch: start_vms=${start_count}, register_ha=${ha_count}, want 18"
fi

test_start "8" "no reusable NixOS VM module keeps hardcoded started = true"
hardcoded="$(rg -n '^[[:space:]]*started[[:space:]]*=[[:space:]]*true' framework/tofu/modules framework/catalog | grep -v 'framework/tofu/modules/pbs/' || true)"
if [[ -z "$hardcoded" ]]; then
  test_pass "only PBS may keep started = true"
else
  test_fail "hardcoded started=true remains outside PBS: ${hardcoded}"
fi

test_start "9" "PBS is the explicit vendor-appliance exception"
if grep -Fq "vendor-appliance exception" framework/tofu/modules/pbs/main.tf &&
   grep -Fq "started = true" framework/tofu/modules/pbs/main.tf &&
   grep -Fq "count = var.ha_enabled ? 1 : 0" framework/tofu/modules/pbs/main.tf; then
  test_pass "PBS remains unchanged with explicit exception comment"
else
  test_fail "PBS exception comment or unchanged started/HA behavior missing"
fi

runner_summary
