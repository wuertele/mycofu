#!/usr/bin/env bash
# Sprint 038 R1: wholly absent envs are skipped while live VMs are reconciled.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/pbs_backup_compliance_fixture.sh"

pbs_fixture_setup
trap pbs_fixture_teardown EXIT

test_start "partial-env" "prod-absent staged cluster still reconciles shared and dev VMIDs"
pbs_fixture_write_resources '[
  {"type":"qemu","vmid":150,"name":"gitlab","node":"pve01"},
  {"type":"qemu","vmid":303,"name":"vault-dev","node":"pve02"}
]'
pbs_fixture_write_jobs "$(pbs_fixture_expected_jobs)"
pbs_fixture_reset_invocations

pbs_fixture_run_configure

assert_exit_status 0 "partial cluster converges successfully"
assert_output_has "Skipping backup VMID(s) for envs not yet present" "skipped absent env is explicit"
assert_output_has "403(vault-prod/prod)" "skipped output names absent prod VMID"
assert_output_has "vmid: expected=150,303 actual=150,303,403" "drift report narrows to live VMIDs"
assert_invocation_count "$(pbs_fixture_set_count)" 1 "partial cluster updates the managed job"
assert_invocation_count "$(pbs_fixture_create_count)" 0 "partial cluster does not create a duplicate job"
assert_invocations_have "--vmid '150,303'" "write covers live shared/dev VMIDs"
assert_invocations_lack "--vmid '150,303,403'" "write omits wholly absent prod VMID"

pbs_fixture_reset_invocations
pbs_fixture_run_configure --verify

assert_exit_status 0 "partial cluster verify passes after live-scope reconciliation"
assert_invocation_count "$(pbs_fixture_set_count)" 0 "partial verify does not write"
assert_invocation_count "$(pbs_fixture_create_count)" 0 "partial verify does not create"

runner_summary
