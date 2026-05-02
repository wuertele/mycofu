#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

VARIABLES_FILE="${REPO_ROOT}/framework/tofu/modules/proxmox-vm/variables.tf"
BASE_SNIPPETS_FILE="${REPO_ROOT}/framework/tofu/modules/proxmox-vm/snippets.tf"
BASE_VM_FILE="${REPO_ROOT}/framework/tofu/modules/proxmox-vm/vm.tf"
PRECIOUS_VM_FILE="${REPO_ROOT}/framework/tofu/modules/proxmox-vm-precious/vm.tf"
PRECIOUS_VARIABLES_LINK="${REPO_ROOT}/framework/tofu/modules/proxmox-vm-precious/variables.tf"
FIELD_UPDATABLE_DIR="${REPO_ROOT}/framework/tofu/modules/proxmox-vm-field-updatable"
FIELD_UPDATABLE_VM_FILE="${FIELD_UPDATABLE_DIR}/vm.tf"
GITLAB_MODULE_FILE="${REPO_ROOT}/framework/tofu/modules/gitlab/main.tf"
CICD_MODULE_FILE="${REPO_ROOT}/framework/tofu/modules/cicd/main.tf"

test_start "5.1" "field_updatable variable exists in proxmox-vm/variables.tf"
if grep -q 'variable "field_updatable"' "${VARIABLES_FILE}"; then
  test_pass "field_updatable variable is declared in proxmox-vm/variables.tf"
else
  test_fail "field_updatable variable is declared in proxmox-vm/variables.tf"
fi

test_start "5.1a" "precious variables.tf remains a symlink to the base module"
if [[ -L "${PRECIOUS_VARIABLES_LINK}" ]] && [[ "$(readlink "${PRECIOUS_VARIABLES_LINK}")" == "../proxmox-vm/variables.tf" ]]; then
  test_pass "proxmox-vm-precious/variables.tf still points at ../proxmox-vm/variables.tf"
else
  test_fail "proxmox-vm-precious/variables.tf still points at ../proxmox-vm/variables.tf"
fi

test_start "5.1b" "field-updatable module directory exists with correct symlinks"
SYMLINKS_OK=true
for f in ha.tf outputs.tf snippets.tf templates variables.tf; do
  if [[ ! -L "${FIELD_UPDATABLE_DIR}/${f}" ]]; then
    SYMLINKS_OK=false
    break
  fi
  target=$(readlink "${FIELD_UPDATABLE_DIR}/${f}")
  if [[ "$target" != "../proxmox-vm/${f}" ]]; then
    SYMLINKS_OK=false
    break
  fi
done
if [[ "$SYMLINKS_OK" == "true" ]] && [[ -f "${FIELD_UPDATABLE_VM_FILE}" ]]; then
  test_pass "proxmox-vm-field-updatable has correct symlinks and unique vm.tf"
else
  test_fail "proxmox-vm-field-updatable has correct symlinks and unique vm.tf"
fi

test_start "5.1c" "cidata_hash is conditionalized in the shared snippets module"
if grep -q 'count = var\.field_updatable ? 0 : 1' "${BASE_SNIPPETS_FILE}"; then
  test_pass "proxmox-vm/snippets.tf disables cidata_hash when field_updatable is true"
else
  test_fail "proxmox-vm/snippets.tf disables cidata_hash when field_updatable is true"
fi

test_start "5.1d" "field-updatable vm.tf ignores disk and initialization changes"
if grep -q 'ignore_changes' "${FIELD_UPDATABLE_VM_FILE}" && \
   grep -q 'disk\[0\]\.file_id' "${FIELD_UPDATABLE_VM_FILE}" && \
   grep -q 'initialization' "${FIELD_UPDATABLE_VM_FILE}"; then
  test_pass "field-updatable vm.tf has ignore_changes for disk[0].file_id and initialization"
else
  test_fail "field-updatable vm.tf has ignore_changes for disk[0].file_id and initialization"
fi

test_start "5.1e" "field-updatable vm.tf has prevent_destroy"
if grep -q 'prevent_destroy *= *true' "${FIELD_UPDATABLE_VM_FILE}"; then
  test_pass "field-updatable vm.tf has prevent_destroy = true"
else
  test_fail "field-updatable vm.tf has prevent_destroy = true"
fi

test_start "5.1f" "field-updatable vm.tf has no replace_triggered_by"
if ! grep -v '^\s*#' "${FIELD_UPDATABLE_VM_FILE}" | grep -q 'replace_triggered_by'; then
  test_pass "field-updatable vm.tf has no replace_triggered_by (CIDATA changes absorbed)"
else
  test_fail "field-updatable vm.tf should not have replace_triggered_by"
fi

test_start "5.1g" "gitlab uses proxmox-vm-field-updatable module"
if grep -q 'source *= *"../proxmox-vm-field-updatable"' "${GITLAB_MODULE_FILE}"; then
  test_pass "gitlab module sources ../proxmox-vm-field-updatable"
else
  test_fail "gitlab module sources ../proxmox-vm-field-updatable"
fi

test_start "5.1h" "cicd uses proxmox-vm-field-updatable module"
if grep -q 'source *= *"../proxmox-vm-field-updatable"' "${CICD_MODULE_FILE}"; then
  test_pass "cicd module sources ../proxmox-vm-field-updatable"
else
  test_fail "cicd module sources ../proxmox-vm-field-updatable"
fi

test_start "5.1i" "precious and base modules use static lifecycle (no dynamic expressions)"
if ! grep -q 'var\.field_updatable' "${PRECIOUS_VM_FILE}" && \
   ! grep -q 'concat(' "${BASE_VM_FILE}"; then
  test_pass "precious and base vm.tf use static lifecycle blocks"
else
  test_fail "precious and base vm.tf should not have dynamic lifecycle expressions"
fi

runner_summary
