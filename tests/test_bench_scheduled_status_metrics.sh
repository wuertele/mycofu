#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/benchmarks/lib/scheduled-status.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
export BENCH_SCHEDULE_STATUS_LOG="${TMP_DIR}/metrics.log"
export BENCH_SCHEDULE_STATUS_NO_PUSH=1
export BENCH_SCHEDULE_KEY=bench-nightly
export BENCH_SCHEDULE_LABEL=scheduled

test_start "1" "run metric line protocol shape"
emit_bench_scheduled_run ok 3 3 0 900 >/tmp/status-metric.out
if grep -Eq '^bench_scheduled_run,schedule_key=bench-nightly,trigger=scheduled,label=scheduled,status=ok hosts_total=3i,hosts_ok=3i,hosts_failed=0i,elapsed_sec=900i [0-9]+$' /tmp/status-metric.out; then
  test_pass "run metric line protocol has expected tags and fields"
else
  test_fail "run metric line protocol shape wrong"
fi

test_start "2" "skip metric line protocol shape"
emit_bench_scheduled_skip other-pipeline-active 0 >/tmp/status-metric.out
if grep -Eq '^bench_scheduled_skip,schedule_key=bench-nightly,trigger=scheduled,label=scheduled,reason=other-pipeline-active waited_sec=0i [0-9]+$' /tmp/status-metric.out; then
  test_pass "skip metric line protocol has expected tags and fields"
else
  test_fail "skip metric line protocol shape wrong"
fi

# Regression test for #328: the status push was constructing the URL with
# the wrong default org (mycofu instead of homelab), so InfluxDB returned
# 404 and the metric never landed. Exercise the push path with a curl shim
# and assert org=homelab.
test_start "3" "push URL uses org=homelab default (regression for #328)"
SHIM_DIR="${TMP_DIR}/shims"
CURL_LOG="${TMP_DIR}/curl.log"
mkdir -p "$SHIM_DIR"
cat > "${SHIM_DIR}/curl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" > "${CURL_LOG}"
exit 0
EOF
chmod +x "${SHIM_DIR}/curl"
unset BENCH_SCHEDULE_STATUS_NO_PUSH
PATH="${SHIM_DIR}:${PATH}" \
  INFLUX_TOKEN=test-token \
  INFLUX_HOST=http://influxdb.example \
  emit_bench_scheduled_run ok 3 3 0 900 >/dev/null
export BENCH_SCHEDULE_STATUS_NO_PUSH=1
if grep -Eq '/api/v2/write\?[^[:space:]]*org=homelab\b' "${CURL_LOG}" && \
   grep -Eq '/api/v2/write\?[^[:space:]]*bucket=mycofu_benchmarks\b' "${CURL_LOG}"; then
  test_pass "status push targets org=homelab/bucket=mycofu_benchmarks on /api/v2/write"
else
  test_fail "status push URL is wrong"
  sed 's/^/    /' "${CURL_LOG}" >&2
fi

runner_summary
