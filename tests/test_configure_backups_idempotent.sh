#!/usr/bin/env bash
# Sprint 038: exact spec match is idempotent and performs zero writes.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/pbs_backup_compliance_fixture.sh"

pbs_fixture_setup
trap pbs_fixture_teardown EXIT

test_start "idempotent" "managed job already matches the closed tracked spec"
pbs_fixture_write_jobs "$(pbs_fixture_expected_jobs)"
pbs_fixture_reset_invocations

pbs_fixture_run_configure

assert_exit_status 0 "converge exits successfully"
assert_output_has "matches spec" "idempotent output says the job matches spec"
assert_invocation_count "$(pbs_fixture_set_count)" 0 "no pvesh set call"
assert_invocation_count "$(pbs_fixture_create_count)" 0 "no pvesh create call"

runner_summary
