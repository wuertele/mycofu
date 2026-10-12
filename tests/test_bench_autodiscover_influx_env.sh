#!/usr/bin/env bash
set -euo pipefail

# Regression coverage for #331: autodiscover_influx_credentials must export
# INFLUX_ORG (from site/apps/influxdb/setup.json) and INFLUX_BUCKET (the
# benchmark-domain constant) as a single source of truth. The pre-existing
# test_bench_scheduled_status_metrics.sh test 3 sets INFLUX_TOKEN, which trips
# the token guard and only exercises the caller backstop — so it does NOT
# validate the export. This test drives autodiscover directly.

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/benchmarks/lib/common.sh"

# Capture the org/bucket that autodiscover exports for a given pre-environment.
# Runs in a subshell so exports never leak between cases. The pre-env is passed
# as NAME=VALUE args; unset anything not passed so each case starts clean.
run_case() {
  (
    unset INFLUX_TOKEN INFLUX_ORG INFLUX_BUCKET INFLUX_DB INFLUX_HOST
    for kv in "$@"; do export "${kv?}"; done
    autodiscover_influx_credentials >/dev/null 2>&1 || true
    printf '%s|%s' "${INFLUX_ORG:-<unset>}" "${INFLUX_BUCKET:-<unset>}"
  )
}

test_start "1" "exports INFLUX_ORG=homelab and INFLUX_BUCKET=mycofu_benchmarks from the repo"
got="$(run_case)"
if [[ "${got}" == "homelab|mycofu_benchmarks" ]]; then
  test_pass "org from setup.json, bucket is the benchmark constant"
else
  test_fail "expected 'homelab|mycofu_benchmarks', got '${got}'"
fi

test_start "2" "bucket is NOT setup.json's 'default' (the #331 premise trap)"
got="$(run_case)"
bucket="${got##*|}"
if [[ "${bucket}" == "mycofu_benchmarks" && "${bucket}" != "default" ]]; then
  test_pass "benchmark writes are not misrouted to the instance's default bucket"
else
  test_fail "bucket resolved to '${bucket}', expected 'mycofu_benchmarks'"
fi

test_start "3" "export is independent of the token guard (INFLUX_TOKEN preset)"
got="$(run_case INFLUX_TOKEN=preset-token)"
if [[ "${got}" == "homelab|mycofu_benchmarks" ]]; then
  test_pass "org/bucket still exported when a token is already present"
else
  test_fail "expected 'homelab|mycofu_benchmarks', got '${got}'"
fi

test_start "4" "INFLUX_DB remains a supported bucket alias"
got="$(run_case INFLUX_DB=custom_db)"
if [[ "${got}" == "homelab|custom_db" ]]; then
  test_pass "INFLUX_DB override is honored, not shadowed by the constant"
else
  test_fail "expected 'homelab|custom_db', got '${got}'"
fi

test_start "5" "explicit INFLUX_ORG/INFLUX_BUCKET overrides are respected"
got="$(run_case INFLUX_ORG=myorg INFLUX_BUCKET=mybucket)"
if [[ "${got}" == "myorg|mybucket" ]]; then
  test_pass "explicit values are not overwritten"
else
  test_fail "expected 'myorg|mybucket', got '${got}'"
fi

runner_summary
