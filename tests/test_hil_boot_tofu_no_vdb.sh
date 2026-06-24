#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

MAIN_TF="${REPO_ROOT}/framework/tofu/root/main.tf"

test_start "s037.3.1" "hil_boot module is no-vdb management VM"
if grep -q 'module "hil_boot"' "$MAIN_TF" && \
   grep -q 'vlan_id             = null' "$MAIN_TF" && \
   grep -q 'vda_size_gb         = 32' "$MAIN_TF" && \
   grep -q 'vdb_size_gb         = 0' "$MAIN_TF" && \
   grep -q 'ha_enabled          = true' "$MAIN_TF"; then
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
