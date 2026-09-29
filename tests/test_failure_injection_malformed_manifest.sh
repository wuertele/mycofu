#!/usr/bin/env bash
# F-4: malformed manifests abort before touching Proxmox.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/preboot_restore_fixture.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

preboot_fixture_setup

test_start "F-4.1" "invalid JSON manifest aborts before Proxmox access"
preboot_reset_fixture
printf '%s\n' 'not-json' > "$MANIFEST_FILE"
preboot_run_capture
preboot_assert_exit 1 "invalid JSON is fatal"
preboot_assert_output_contains "malformed manifest JSON" "JSON parse error is explicit"
preboot_assert_file_empty "$SSH_LOG" "no Proxmox SSH command runs for invalid JSON"
preboot_assert_file_empty "$RESTORE_LOG" "restore primitive is not called for invalid JSON"

test_start "F-4.2" "missing vmid manifest aborts before Proxmox access"
preboot_reset_fixture
cat > "$MANIFEST_FILE" <<'EOF'
{
  "version": 1,
  "entries": [
    {
      "label": "vault_dev",
      "module": "module.vault_dev",
      "env": "dev",
      "kind": "infrastructure",
      "reason": "replace"
    }
  ]
}
EOF
preboot_run_capture
preboot_assert_exit 1 "missing vmid is fatal"
preboot_assert_output_contains "manifest schema invalid" "schema error is explicit"
preboot_assert_file_empty "$SSH_LOG" "no Proxmox SSH command runs for schema errors"
preboot_assert_file_empty "$RESTORE_LOG" "restore primitive is not called for schema errors"

runner_summary
