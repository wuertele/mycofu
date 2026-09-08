#!/usr/bin/env bash
# F-2: qmrestore-to-9999 failure aborts restore-before-start batch.

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

export STUB_RESTORE_FAIL_TARGET=303
export STUB_RESTORE_EXIT=17
preboot_run_capture

test_start "F-2.1" "restore-before-start exits non-zero on qmrestore failure"
preboot_assert_exit 1 "qmrestore failure fails the batch"
preboot_assert_output_contains "restore failed for vault_dev" "failed VM label is reported"

test_start "F-2.2" "status JSON records qmrestore failure"
preboot_assert_entry_status 303 "failed" "failed VM is recorded"
if jq -e '.entries[] | select(.vmid == 303 and (.message | contains("rc=17")))' "$STATUS_FILE" >/dev/null; then
  test_pass "status JSON records primitive failure rc"
else
  test_fail "status JSON missing primitive failure rc"
  cat "$STATUS_FILE" >&2
fi

test_start "F-2.3" "batch aborts before later VM restore"
if grep -Fq -- '--target 303 ' "$RESTORE_LOG" &&
   ! grep -Fq -- '--target 304 ' "$RESTORE_LOG"; then
  test_pass "restore-before-start did not continue after qmrestore failure"
else
  test_fail "restore-before-start continued after qmrestore failure"
  cat "$RESTORE_LOG" >&2
fi

test_start "F-2.4" "no VM start or HA add occurs after qmrestore failure"
preboot_assert_no_start "qmrestore failure leaves the batch stopped and HA absent"

runner_summary
