#!/usr/bin/env bash
# F-1: PBS/restore failure mid-batch fails closed.

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
      "label": "vault_dev",
      "module": "module.vault_dev",
      "vmid": 303,
      "env": "dev",
      "kind": "infrastructure",
      "reason": "replace"
    },
    {
      "label": "grafana_dev",
      "module": "module.grafana_dev",
      "vmid": 304,
      "env": "dev",
      "kind": "application",
      "reason": "replace"
    }
  ]
}
EOF

cat > "$PIN_FILE" <<'EOF'
{
  "version": 1,
  "pins": {
    "303": "pbs-nas:backup/vm/303/2026-04-12T18:30:00Z",
    "304": "pbs-nas:backup/vm/304/2026-04-12T18:35:00Z"
  }
}
EOF

export STUB_RESTORE_FAIL_TARGET=304
preboot_run_capture

test_start "F-1.1" "mid-batch restore failure exits non-zero"
preboot_assert_exit 1 "restore-before-start fails the batch"
preboot_assert_output_contains "restore failed for grafana_dev" "failed VM label is reported"

test_start "F-1.2" "status JSON records success before failure and failed VMID"
preboot_assert_entry_status 303 "restored" "first VM remains recorded as restored"
preboot_assert_entry_status 304 "failed" "failed VM is recorded as failed"

test_start "F-1.3" "no VM start or HA add occurs after restore failure"
preboot_assert_no_start "restore failure leaves the batch stopped and HA absent"

test_start "F-1.4" "both restore attempts used leave-stopped"
if grep -Fq -- '--target 303 --force --backup-id pbs-nas:backup/vm/303/2026-04-12T18:30:00Z --leave-stopped' "$RESTORE_LOG" &&
   grep -Fq -- '--target 304 --force --backup-id pbs-nas:backup/vm/304/2026-04-12T18:35:00Z --leave-stopped' "$RESTORE_LOG"; then
  test_pass "restore-from-pbs was invoked with --leave-stopped for both VMIDs"
else
  test_fail "restore invocations missing --leave-stopped"
  cat "$RESTORE_LOG" >&2
fi

runner_summary
