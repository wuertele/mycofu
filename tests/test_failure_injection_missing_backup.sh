#!/usr/bin/env bash
# F-5: missing PBS backup without first-deploy approval fails closed.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/preboot_restore_fixture.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

preboot_fixture_setup
preboot_reset_fixture

cat > "$MANIFEST_FILE" <<'EOF'
{
  "version": 1,
  "entries": [
    {
      "label": "vault_prod",
      "module": "module.vault_prod",
      "vmid": 403,
      "env": "dev",
      "kind": "infrastructure",
      "reason": "replace"
    }
  ]
}
EOF
printf '{"version":1,"pins":{}}\n' > "$PIN_FILE"
export STUB_PBS_CONTENT='[]'

preboot_run_capture

test_start "F-5.1" "missing backup without approval exits non-zero"
preboot_assert_exit 1 "missing backup is fatal"
preboot_assert_output_contains "FIRST_DEPLOY_ALLOW_VMIDS=403" "error instructs the first-deploy approval rerun"

test_start "F-5.2" "status JSON marks the VM failed and no restore occurs"
preboot_assert_entry_status 403 "failed" "missing-backup VM is recorded as failed"
preboot_assert_file_empty "$RESTORE_LOG" "restore primitive is not called without backup or approval"

test_start "F-5.3" "missing backup leaves VM stopped"
preboot_assert_no_start "no start or HA add occurs for missing backup"

runner_summary
