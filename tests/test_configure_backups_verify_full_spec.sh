#!/usr/bin/env bash
# Sprint 038: --verify fails closed on any tracked-field divergence.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/pbs_backup_compliance_fixture.sh"

pbs_fixture_setup
trap pbs_fixture_teardown EXIT

TRACKED_FIELDS=(enabled storage mode compress all exclude notes-template schedule vmid)

for field in "${TRACKED_FIELDS[@]}"; do
  test_start "verify-${field}" "--verify fails on ${field} drift"
  pbs_fixture_write_jobs "$(pbs_fixture_standard_job_with_drift "${field}")"
  pbs_fixture_reset_invocations

  pbs_fixture_run_configure --verify

  assert_exit_status 1 "${field}: verify exits non-zero"
  assert_output_has "${field}: expected=" "${field}: verify output names field"
  assert_invocation_count "$(pbs_fixture_set_count)" 0 "${field}: verify does not write"
  assert_invocation_count "$(pbs_fixture_create_count)" 0 "${field}: verify does not create"
done

runner_summary
