#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

VERSIONS_FILE="${REPO_ROOT}/framework/tofu/root/versions.tf"
LOCK_FILE="${REPO_ROOT}/framework/tofu/root/.terraform.lock.hcl"

provider_lock_block() {
  awk '/provider "registry.opentofu.org\/bpg\/proxmox"/,/^}/' "${LOCK_FILE}"
}

test_start "0.1" "versions.tf constrains bpg/proxmox to ~> 0.101.0"
if grep -Eq 'version[[:space:]]*=[[:space:]]*"~> 0\.101\.0"' "${VERSIONS_FILE}"; then
  test_pass "versions.tf constrains bpg/proxmox with ~> 0.101.0"
else
  test_fail "versions.tf does not constrain bpg/proxmox with ~> 0.101.0"
fi

test_start "0.2" "lockfile is committed (exists in repo)"
if [[ -f "${LOCK_FILE}" ]] && grep -Fq 'provider "registry.opentofu.org/bpg/proxmox"' "${LOCK_FILE}"; then
  test_pass "lockfile exists and contains bpg/proxmox provider block"
else
  test_fail "lockfile missing or does not contain bpg/proxmox provider block"
fi

test_start "0.3" "lockfile pins bpg/proxmox to a 0.101.x version"
LOCK_BLOCK="$(provider_lock_block)"
if grep -Eq 'version[[:space:]]*=[[:space:]]*"0\.101\.[0-9]+"' <<< "${LOCK_BLOCK}"; then
  test_pass "lockfile pins bpg/proxmox to a 0.101.x version"
else
  test_fail "lockfile does not pin bpg/proxmox to 0.101.x"
fi

test_start "0.4" "lockfile constraint matches versions.tf"
if grep -Eq 'constraints[[:space:]]*=[[:space:]]*"~> 0\.101\.0"' <<< "${LOCK_BLOCK}"; then
  test_pass "lockfile constraint matches versions.tf (~> 0.101.0)"
else
  test_fail "lockfile constraint does not match versions.tf"
fi

test_start "0.5" ".gitignore does NOT exclude .terraform.lock.hcl"
if grep -q '^\.terraform\.lock\.hcl$' "${REPO_ROOT}/.gitignore"; then
  test_fail ".terraform.lock.hcl is gitignored — provider version is not pinned"
else
  test_pass ".terraform.lock.hcl is not gitignored"
fi

runner_summary
