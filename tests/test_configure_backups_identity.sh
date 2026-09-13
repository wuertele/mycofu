#!/usr/bin/env bash
# Sprint 038: managed job identity is marker-first, with permanent legacy fallback.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/pbs_backup_compliance_fixture.sh"

pbs_fixture_setup
trap pbs_fixture_teardown EXIT

test_start "identity-storage-drift" "marker selects job even when storage drifted"
pbs_fixture_write_jobs "$(pbs_fixture_expected_jobs | jq '.[0].id = "marked-job" | .[0].storage = "local"')"
pbs_fixture_reset_invocations

pbs_fixture_run_configure

assert_exit_status 0 "storage drift is reconciled"
assert_invocation_count "$(pbs_fixture_set_count)" 1 "marked job updated in place"
assert_invocation_count "$(pbs_fixture_create_count)" 0 "no duplicate created for storage drift"
assert_invocations_have "pvesh set /cluster/backup/marked-job" "set targets the marked job id"
assert_invocations_have "--storage pbs-nas" "set restores expected storage"

test_start "identity-legacy-fallback" "single legacy pbs-nas job is adopted with marker"
pbs_fixture_write_jobs "$(pbs_fixture_expected_jobs | jq '.[0].id = "legacy-job" | .[0]."notes-template" = "old job"')"
pbs_fixture_reset_invocations

pbs_fixture_run_configure

assert_exit_status 0 "legacy fallback converges"
assert_invocation_count "$(pbs_fixture_set_count)" 1 "legacy job updated in place"
assert_invocation_count "$(pbs_fixture_create_count)" 0 "legacy job is not duplicated"
assert_invocations_have "pvesh set /cluster/backup/legacy-job" "set targets legacy job id"
assert_invocations_have "--notes-template 'Precious state -- automated by configure-backups.sh'" "legacy job receives marker"

test_start "identity-ambiguous" "multiple candidates fail closed"
pbs_fixture_write_jobs "$(pbs_fixture_expected_jobs | jq '. + [.[0] | .id = "job2"]')"
pbs_fixture_reset_invocations

pbs_fixture_run_configure

assert_exit_status 1 "duplicate managed jobs are fatal"
assert_output_has "ambiguous" "ambiguity error is explicit"
assert_invocation_count "$(pbs_fixture_set_count)" 0 "ambiguous state does not write"
assert_invocation_count "$(pbs_fixture_create_count)" 0 "ambiguous state does not create"

test_start "identity-marker-plus-legacy" "marker plus separate legacy candidate fails closed"
pbs_fixture_write_jobs "$(
  pbs_fixture_expected_jobs \
    | jq '. + [.[0] | .id = "legacy-job" | ."notes-template" = "old job" | .storage = "pbs-nas"]'
)"
pbs_fixture_reset_invocations

pbs_fixture_run_configure

assert_exit_status 1 "marker plus legacy candidate is fatal"
assert_output_has "ambiguous" "marker plus legacy ambiguity error is explicit"
assert_invocation_count "$(pbs_fixture_set_count)" 0 "marker plus legacy does not write"
assert_invocation_count "$(pbs_fixture_create_count)" 0 "marker plus legacy does not create"

runner_summary
