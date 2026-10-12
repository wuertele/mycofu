#!/usr/bin/env bash
# Sprint 038: each tracked-field drift triggers a full-spec write plus read-back.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/pbs_backup_compliance_fixture.sh"

pbs_fixture_setup
trap pbs_fixture_teardown EXIT

TRACKED_FIELDS=(enabled storage mode compress all exclude notes-template schedule vmid)

for field in "${TRACKED_FIELDS[@]}"; do
  test_start "spec-${field}" "drift in ${field} is reconciled with full spec"
  pbs_fixture_write_jobs "$(pbs_fixture_standard_job_with_drift "${field}")"
  pbs_fixture_reset_invocations

  pbs_fixture_run_configure

  assert_exit_status 0 "${field}: converge exits successfully after read-back"
  assert_output_has "${field}: expected=" "${field}: drift report names the field"
  if [[ "${field}" == "exclude" ]]; then
    assert_invocation_count "$(pbs_fixture_set_count)" 2 "${field}: exclude clear plus full-spec pvesh set"
    assert_invocations_have "pvesh set /cluster/backup/job1 --delete exclude" "${field}: live exclude is cleared with --delete"
  else
    assert_invocation_count "$(pbs_fixture_set_count)" 1 "${field}: exactly one pvesh set"
    assert_invocations_lack "--delete exclude" "${field}: unrelated drift does not delete exclude"
  fi
  assert_invocation_count "$(pbs_fixture_create_count)" 0 "${field}: no duplicate job is created"
  assert_invocations_have "--enabled 1" "${field}: full spec includes enabled"
  assert_invocations_have "--storage pbs-nas" "${field}: full spec includes storage"
  assert_invocations_have "--mode snapshot" "${field}: full spec includes mode"
  assert_invocations_have "--compress zstd" "${field}: full spec includes compression"
  assert_invocations_have "--all 0" "${field}: full spec includes all=0"
  assert_invocations_lack "--exclude ''" "${field}: full spec omits invalid empty exclude"
  assert_invocations_have "--notes-template 'Precious state -- automated by configure-backups.sh'" "${field}: full spec includes marker"
  assert_invocations_have "--schedule '02:00'" "${field}: full spec includes schedule"
  assert_invocations_have "--vmid '150,303,403'" "${field}: full spec includes sorted VMIDs"
done

test_start "create-omits-empty-exclude" "new managed job creation omits invalid empty exclude"
pbs_fixture_write_jobs '[]'
pbs_fixture_reset_invocations

pbs_fixture_run_configure

assert_exit_status 0 "create exits successfully after read-back"
assert_invocation_count "$(pbs_fixture_create_count)" 1 "create path writes one job"
assert_invocation_count "$(pbs_fixture_set_count)" 0 "create path does not need a clearing set"
assert_invocations_lack "--exclude ''" "create path omits invalid empty exclude"
assert_invocations_lack "--delete exclude" "create path does not delete absent exclude"
assert_invocations_have "--vmid '150,303,403'" "create path includes sorted VMIDs"

test_start "read-back-mismatch" "write success followed by unchanged state fails closed"
pbs_fixture_write_jobs "$(pbs_fixture_standard_job_with_drift enabled)"
pbs_fixture_reset_invocations
export STUB_DISABLE_STATE_UPDATE=1
pbs_fixture_run_configure
unset STUB_DISABLE_STATE_UPDATE

assert_exit_status 1 "read-back mismatch exits non-zero"
assert_output_has "still diverges after write" "read-back failure is explicit"
assert_invocation_count "$(pbs_fixture_set_count)" 1 "read-back mismatch still attempted one write"

runner_summary
