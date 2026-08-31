#!/usr/bin/env bash
# Sprint 038: active-scope backup VMIDs missing from the live cluster fail closed.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/pbs_backup_compliance_fixture.sh"

pbs_fixture_setup
trap pbs_fixture_teardown EXIT

test_start "missing-active-vm" "backup:true VMID absent from an active environment is fatal"
yq -i '.vms.influx_dev = {"vmid": 501, "backup": true}' "${FIXTURE_REPO}/site/config.yaml"
pbs_fixture_write_resources '[
  {"type":"qemu","vmid":150,"name":"gitlab","node":"pve01"},
  {"type":"qemu","vmid":403,"name":"vault-prod","node":"pve03"},
  {"type":"qemu","vmid":501,"name":"influx-dev","node":"pve02"}
]'
pbs_fixture_write_jobs "$(pbs_fixture_expected_jobs)"
pbs_fixture_reset_invocations

pbs_fixture_run_configure

assert_exit_status 1 "missing expected VMID exits non-zero"
assert_output_has "configured backup VMID(s) missing from active live scope" "error names active live scope"
assert_output_has "303" "error names missing VMID"
assert_invocation_count "$(pbs_fixture_set_count)" 0 "missing VM does not write"
assert_invocation_count "$(pbs_fixture_create_count)" 0 "missing VM does not create"

runner_summary
