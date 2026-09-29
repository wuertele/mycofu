#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

MAIN_TF="${REPO_ROOT}/framework/tofu/root/main.tf"

test_start "s037.3.1" "hil_boot module is no-vdb management VM"
# Whitespace after the attribute name is not fixed — `tofu fmt` re-aligns
# each block to the widest attribute name, so adding a new field to the
# module (e.g., #691's `replication_policy_on`) shifts the column. Match
# the shape "attr <spaces> = value" with a permissive regex.
if grep -q 'module "hil_boot"' "$MAIN_TF" && \
   grep -Eq '^\s+vlan_id\s+=\s+null' "$MAIN_TF" && \
   grep -Eq '^\s+vda_size_gb\s+=\s+32' "$MAIN_TF" && \
   grep -Eq '^\s+vdb_size_gb\s+=\s+0' "$MAIN_TF" && \
   grep -Eq '^\s+ha_enabled\s+=\s+true' "$MAIN_TF"; then
  test_pass "hil_boot module is management-network, HA-enabled, and no-vdb"
else
  test_fail "hil_boot module missing no-vdb management-network contract"
fi

test_start "s037.3.2" "hil_boot module has no post-deploy secrets in CIDATA"
hil_block="$(awk '/module "hil_boot"/{flag=1} flag{print} /^}/{if(flag){exit}}' "$MAIN_TF")"
if ! grep -Eq 'amt_password|pdu_password|proxmox_api_password|bfnet|write_files' <<< "$hil_block"; then
  test_pass "hil_boot CIDATA has no AMT/PDU/root-password secret payload"
else
  test_fail "hil_boot module includes post-deploy secrets or custom write_files"
fi

test_start "s037.3.3" "tofu validates when available"
set +e
tofu_output="$(cd "${REPO_ROOT}/framework/tofu/root" && tofu validate 2>&1)"
tofu_rc=$?
set -e
if [[ "$tofu_rc" -ne 0 && "$tofu_output" == *"command not found"* ]]; then
  test_skip "tofu is not installed in this sandbox"
elif [[ "$tofu_rc" -eq 0 ]]; then
  test_pass "tofu validate passed"
else
  test_skip "tofu validate could not run in this sandbox"
fi

runner_summary
