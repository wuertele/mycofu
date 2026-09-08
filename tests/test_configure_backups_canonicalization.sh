#!/usr/bin/env bash
# Sprint 038: defaults and VMID ordering are canonicalized before comparison.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/pbs_backup_compliance_fixture.sh"

pbs_fixture_setup
trap pbs_fixture_teardown EXIT

test_start "canonicalization" "absent defaults and unsorted numeric VMIDs do not cause false drift"
pbs_fixture_write_jobs "$(
  pbs_fixture_expected_jobs \
    | jq '.[0] |= del(.enabled, .all, .exclude) | .[0].vmid = "403,150,303"'
)"
pbs_fixture_reset_invocations

pbs_fixture_run_configure

assert_exit_status 0 "canonicalized equivalent spec exits successfully"
assert_output_has "matches spec" "output reports no drift"
assert_invocation_count "$(pbs_fixture_set_count)" 0 "no pvesh set call"
assert_invocation_count "$(pbs_fixture_create_count)" 0 "no pvesh create call"

runner_summary
