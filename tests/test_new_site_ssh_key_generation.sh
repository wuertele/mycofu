#!/usr/bin/env bash
# test_new_site_ssh_key_generation.sh — Verify --fill-ssh-keys flag on new-site.sh.
#
# Tests the flag parsing and help text. Cannot test actual key generation
# without a real SOPS setup, but verifies the flag is recognized and the
# script structure is correct.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/new-site.sh"

test_start "14.20" "new-site.sh contains --fill-ssh-keys handler"
if grep -q 'fill-ssh-keys' "$SCRIPT"; then
  test_pass "--fill-ssh-keys handler present"
else
  test_fail "--fill-ssh-keys handler missing"
fi

test_start "14.21" "new-site.sh --fill-ssh-keys checks for config.yaml"
if grep -q 'CONFIG.*not found\|config.yaml.*not found' "$SCRIPT"; then
  test_pass "prerequisite check for config.yaml present"
else
  test_fail "no prerequisite check for config.yaml"
fi

test_start "14.22" "new-site.sh --fill-ssh-keys uses write-once guard"
if grep -q 'exists.*skipping.*write-once\|existing.*skip' "$SCRIPT"; then
  test_pass "write-once guard present in script"
else
  test_fail "write-once guard missing"
fi

test_start "14.23" "new-site.sh --fill-ssh-keys generates ed25519 keys"
if grep -q 'ssh-keygen -t ed25519' "$SCRIPT"; then
  test_pass "uses ed25519 key type"
else
  test_fail "does not use ed25519"
fi

test_start "14.23b" "new-site.sh --fill-ssh-keys JSON-encodes keys for sops"
if grep -q 'jq -Rs' "$SCRIPT"; then
  test_pass "uses jq -Rs for JSON encoding of multi-line keys"
else
  test_fail "does not JSON-encode keys (multi-line SSH keys will break sops --set)"
fi

test_start "14.23c" "new-site.sh --fill-ssh-keys has tmpdir cleanup trap"
if grep -q "trap.*EXIT" "$SCRIPT"; then
  test_pass "EXIT trap for tmpdir cleanup"
else
  test_fail "no EXIT trap — key material leaks on abnormal exit"
fi

test_start "14.23d" "new-site.sh --fill-ssh-keys skips PBS (vendor appliance)"
if grep -q 'pbs.*vendor\|pbs.*skip' "$SCRIPT"; then
  test_pass "PBS skipped"
else
  test_fail "PBS not skipped"
fi

test_start "14.24" "new-site.sh --fill-ssh-keys iterates both infra and app VMs"
if grep -q 'vms.*keys' "$SCRIPT" && grep -q 'applications' "$SCRIPT"; then
  test_pass "iterates infrastructure and application VMs"
else
  test_fail "does not iterate both VM types"
fi

test_start "14.25" "enable-app.sh mentions --fill-ssh-keys in next steps"
if grep -q 'fill-ssh-keys' "${REPO_ROOT}/framework/scripts/enable-app.sh"; then
  test_pass "enable-app.sh references --fill-ssh-keys"
else
  test_fail "enable-app.sh does not reference --fill-ssh-keys"
fi

test_start "14.26" "new-site.sh validates the generated config before returning"
if grep -q 'validate-site-config.sh' "$SCRIPT"; then
  test_pass "new-site.sh calls validate-site-config.sh"
else
  test_fail "new-site.sh does not validate generated config"
fi

runner_summary
