#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CONFIG="${TMP_DIR}/config.yaml"
EPOCH="${TMP_DIR}/epoch.conf"
RUN_ON_HOST="${TMP_DIR}/run-on-host.sh"
FAILING_RUN_ON_HOST="${TMP_DIR}/run-on-host-fails-pve02.sh"
LIVE_GITLAB_CURL="${TMP_DIR}/curl-live-gitlab"
STATUS_ROOT="${TMP_DIR}/status"
LOCKFILE="${TMP_DIR}/scheduled.lock"
RUN_LOG="${TMP_DIR}/run-on-host.log"
export RUN_LOG

cat > "$CONFIG" <<'EOF'
benchmarks:
  scheduled:
    enabled: true
    label: scheduled
    hosts: [pve01, pve02, pve03]
    suite: synthetic
    host_timeout_sec: 3600
nodes:
  - name: pve01
  - name: pve02
  - name: pve03
cicd:
  project_name: mycofu
vms:
  gitlab:
    ip: 192.0.2.62
EOF
printf 'e0-test\n' > "$EPOCH"
cat > "$RUN_ON_HOST" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Simulate ssh's stdin consumption: drain whatever is on stdin. A
# regression of the </dev/null guard in run-scheduled-bench.sh would
# cause this drain to steal hosts from the orchestrator's while-read
# loop, and Test 1 would observe hosts_ok < hosts_total.
cat >/dev/null || true
printf '%s\n' "$*" >> "$RUN_LOG"
exit 0
EOF
chmod +x "$RUN_ON_HOST"
cat > "$FAILING_RUN_ON_HOST" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Same stdin-drain pattern as the success fixture above.
cat >/dev/null || true
printf '%s\n' "$*" >> "$RUN_LOG"
if [[ "${1:-}" == "pve02" ]]; then
  exit 1
fi
exit 0
EOF
chmod +x "$FAILING_RUN_ON_HOST"
cat > "$LIVE_GITLAB_CURL" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*) url="$arg" ;;
  esac
done
path="${url#*/api/v4}"
case "$path" in
  /projects?search=*)
    printf '[{"id":42,"path":"mycofu","path_with_namespace":"root/mycofu"}]\n'
    ;;
  /projects/42/pipelines?per_page=20)
    printf '[{"id":111,"status":"running","source":"schedule","ref":"dev"}]\n'
    ;;
  /projects/42/pipelines/111/jobs?per_page=100)
    printf '[{"name":"bench:scheduled","status":"running"}]\n'
    ;;
  *)
    printf 'unexpected GitLab curl path: %s\n' "$path" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$LIVE_GITLAB_CURL"

idle_env() {
  export BENCH_CONFIG_FILE="$CONFIG"
  export BENCH_EPOCH_FILE="$EPOCH"
  export BENCH_RUN_ON_HOST_BIN="$RUN_ON_HOST"
  export BENCH_SCHEDULE_STATUS_ROOT="$STATUS_ROOT"
  export BENCH_SCHEDULE_LOCKFILE="$LOCKFILE"
  export BENCH_SCHEDULE_STATUS_NO_PUSH=1
  export BENCH_GITLAB_PIPELINES_JSON='[]'
  # Drop any ambient CI_PIPELINE_ID so the bench scheduler's self-pipeline
  # filter does not accidentally match a hardcoded id in this test's
  # synthetic pipeline JSON. Surfaced when pipeline #999 ran test 2 (which
  # uses id:999) and matched CI_PIPELINE_ID=999 from the actual job.
  # Tests that need a specific CI_PIPELINE_ID export it explicitly (see
  # test 2b).
  unset CI_PIPELINE_ID
}

test_start "1" "idle runner runs all hosts serially"
idle_env
: > "$RUN_LOG"
if "${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled.out 2>&1 &&
   [[ "$(wc -l < "$RUN_LOG" | tr -d ' ')" == "3" ]] &&
   jq -e '.status == "ok" and (.hosts | length) == 3' "${STATUS_ROOT}/status.json" >/dev/null; then
  test_pass "idle runner runs all hosts"
else
  test_fail "idle scheduled bench failed"
  sed 's/^/    /' /tmp/run-scheduled.out >&2
fi

test_start "2" "GitLab active non-self pipeline skips"
idle_env
export BENCH_GITLAB_PIPELINES_JSON='[{"id":999,"status":"running","source":"push","ref":"dev","jobs":[{"name":"deploy:dev","status":"running"}]}]'
if "${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled.out 2>&1 &&
   jq -e '.status == "skipped" and .skip_reason == "other-pipeline-active"' "${STATUS_ROOT}/status.json" >/dev/null; then
  test_pass "GitLab active pipeline skips"
else
  test_fail "GitLab active pipeline skip failed"
  sed 's/^/    /' /tmp/run-scheduled.out >&2
fi

test_start "2b" "active pipeline that matches CI_PIPELINE_ID is filtered out (self)"
idle_env
: > "$RUN_LOG"
export BENCH_GITLAB_PIPELINES_JSON='[{"id":555,"status":"running","source":"schedule","ref":"dev","jobs":[{"name":"bench:scheduled","status":"running"}]}]'
export CI_PIPELINE_ID=555
if "${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled.out 2>&1 &&
   [[ "$(wc -l < "$RUN_LOG" | tr -d ' ')" == "3" ]] &&
   jq -e '.status == "ok"' "${STATUS_ROOT}/status.json" >/dev/null; then
  test_pass "self pipeline does not block its own run"
else
  test_fail "self pipeline incorrectly blocked the orchestrator"
  sed 's/^/    /' /tmp/run-scheduled.out >&2
fi
unset CI_PIPELINE_ID

test_start "3" "one host failure records partial and exits non-zero"
idle_env
export BENCH_SCHEDULE_FIXTURE=one-host-fails
set +e
"${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled.out 2>&1
rc=$?
set -e
unset BENCH_SCHEDULE_FIXTURE
if [[ "$rc" -ne 0 ]] &&
   jq -e '.status == "partial" and .hosts.pve02.status == "failed"' "${STATUS_ROOT}/status.json" >/dev/null; then
  test_pass "one host failure records partial"
else
  test_fail "host failure behavior wrong"
fi

test_start "4" "run-on-host command failure continues to later hosts"
idle_env
export BENCH_RUN_ON_HOST_BIN="$FAILING_RUN_ON_HOST"
: > "$RUN_LOG"
set +e
"${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled.out 2>&1
rc=$?
set -e
if [[ "$rc" -ne 0 ]] &&
   [[ "$(wc -l < "$RUN_LOG" | tr -d ' ')" == "3" ]] &&
   jq -e '.status == "partial" and .hosts.pve02.status == "failed" and .hosts.pve03.status == "ok"' "${STATUS_ROOT}/status.json" >/dev/null; then
  test_pass "run-on-host failure records partial and continues"
else
  test_fail "run-on-host failure did not continue correctly"
  sed 's/^/    /' /tmp/run-scheduled.out >&2
fi
export BENCH_RUN_ON_HOST_BIN="$RUN_ON_HOST"

test_start "5" "live GitLab preflight fetches jobs when pipeline list omits them"
idle_env
unset BENCH_GITLAB_PIPELINES_JSON
set +e
BENCH_CURL_BIN="$LIVE_GITLAB_CURL" \
BENCH_GITLAB_TOKEN=test-token \
BENCH_GITLAB_URL=http://gitlab.example \
"${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" --preflight-only >/tmp/run-scheduled.out 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]] &&
   jq -e '.status == "ok"' "${STATUS_ROOT}/status.json" >/dev/null; then
  test_pass "live GitLab preflight treats bench-only scheduled pipeline as idle"
else
  test_fail "live GitLab preflight failed without BENCH_GITLAB_PIPELINES_JSON"
  sed 's/^/    /' /tmp/run-scheduled.out >&2
fi

test_start "6" "suite=full passes --full to run-on-host"
idle_env
yq -i '.benchmarks.scheduled.suite = "full"' "$CONFIG"
: > "$RUN_LOG"
full_count=0
if "${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled.out 2>&1 &&
   full_count="$(grep -c -- '--full' "$RUN_LOG" || true)" &&
   [[ "$full_count" == "3" ]]; then
  test_pass "suite=full runs full host command"
else
  test_fail "suite=full did not pass --full"
  sed 's/^/    /' /tmp/run-scheduled.out >&2
fi
yq -i '.benchmarks.scheduled.suite = "synthetic"' "$CONFIG"

test_start "7" "synthetic-weekly-full passes --full only on configured day"
idle_env
yq -i '.benchmarks.scheduled.suite = "synthetic-weekly-full" | .benchmarks.scheduled.full_day = "monday"' "$CONFIG"
: > "$RUN_LOG"
full_count=0
if BENCH_SCHEDULE_WEEKDAY=monday "${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled.out 2>&1 &&
   full_count="$(grep -c -- '--full' "$RUN_LOG" || true)" &&
   [[ "$full_count" == "3" ]]; then
  test_pass "synthetic-weekly-full runs full on configured day"
else
  test_fail "synthetic-weekly-full did not pass --full on configured day"
  sed 's/^/    /' /tmp/run-scheduled.out >&2
fi
: > "$RUN_LOG"
if BENCH_SCHEDULE_WEEKDAY=tuesday "${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled.out 2>&1 &&
   ! grep -q -- '--full' "$RUN_LOG"; then
  test_pass "synthetic-weekly-full stays synthetic on other days"
else
  test_fail "synthetic-weekly-full passed --full on a non-configured day"
fi
yq -i '.benchmarks.scheduled.suite = "synthetic" | .benchmarks.scheduled.full_day = "sunday"' "$CONFIG"

test_start "8" "lock loser cleanup does not release active owner"
LOCK_CONFIG="${TMP_DIR}/config-lock.yaml"
LOCK_STATUS_ROOT="${TMP_DIR}/status-lock"
LOCK_OWNER_RUN="${TMP_DIR}/run-on-host-blocking.sh"
LOCK_OWNER_READY="${TMP_DIR}/lock-owner-ready"
LOCK_OWNER_RELEASE="${TMP_DIR}/lock-owner-release"
LOCKFILE_OWNER="${TMP_DIR}/scheduled-owner.lock"
cat > "$LOCK_CONFIG" <<'EOF'
benchmarks:
  scheduled:
    enabled: true
    label: scheduled
    hosts: [pve01]
    suite: synthetic
    host_timeout_sec: 3600
nodes:
  - name: pve01
cicd:
  project_name: mycofu
vms:
  gitlab:
    ip: 192.0.2.62
EOF
cat > "$LOCK_OWNER_RUN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ready\n' > "$LOCK_OWNER_READY"
while [[ ! -f "$LOCK_OWNER_RELEASE" ]]; do
  sleep 0.1
done
printf '%s\n' "$*" >> "$RUN_LOG"
EOF
chmod +x "$LOCK_OWNER_RUN"
set +e
BENCH_CONFIG_FILE="$LOCK_CONFIG" \
BENCH_EPOCH_FILE="$EPOCH" \
BENCH_RUN_ON_HOST_BIN="$LOCK_OWNER_RUN" \
BENCH_SCHEDULE_STATUS_ROOT="$LOCK_STATUS_ROOT" \
BENCH_SCHEDULE_LOCKFILE="$LOCKFILE_OWNER" \
BENCH_SCHEDULE_RUN_ID=owner \
BENCH_SCHEDULE_STATUS_NO_PUSH=1 \
BENCH_GITLAB_PIPELINES_JSON='[]' \
LOCK_OWNER_READY="$LOCK_OWNER_READY" \
LOCK_OWNER_RELEASE="$LOCK_OWNER_RELEASE" \
"${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled-owner.out 2>&1 &
owner_pid=$!
set -e
for _ in {1..50}; do
  [[ -f "$LOCK_OWNER_READY" ]] && break
  sleep 0.1
done
owner_ready=0
[[ -f "$LOCK_OWNER_READY" ]] && owner_ready=1
if [[ "$owner_ready" -eq 1 ]] &&
   BENCH_CONFIG_FILE="$LOCK_CONFIG" BENCH_EPOCH_FILE="$EPOCH" BENCH_RUN_ON_HOST_BIN="$RUN_ON_HOST" BENCH_SCHEDULE_STATUS_ROOT="$LOCK_STATUS_ROOT" BENCH_SCHEDULE_LOCKFILE="$LOCKFILE_OWNER" BENCH_SCHEDULE_RUN_ID=loser1 BENCH_SCHEDULE_STATUS_NO_PUSH=1 BENCH_GITLAB_PIPELINES_JSON='[]' "${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled-loser1.out 2>&1 &&
   jq -e '.status == "skipped" and .skip_reason == "concurrent-run"' "${LOCK_STATUS_ROOT}/status.json" >/dev/null &&
   BENCH_CONFIG_FILE="$LOCK_CONFIG" BENCH_EPOCH_FILE="$EPOCH" BENCH_RUN_ON_HOST_BIN="$RUN_ON_HOST" BENCH_SCHEDULE_STATUS_ROOT="$LOCK_STATUS_ROOT" BENCH_SCHEDULE_LOCKFILE="$LOCKFILE_OWNER" BENCH_SCHEDULE_RUN_ID=loser2 BENCH_SCHEDULE_STATUS_NO_PUSH=1 BENCH_GITLAB_PIPELINES_JSON='[]' "${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/run-scheduled-loser2.out 2>&1 &&
   jq -e '.status == "skipped" and .skip_reason == "concurrent-run"' "${LOCK_STATUS_ROOT}/status.json" >/dev/null; then
  printf 'release\n' > "$LOCK_OWNER_RELEASE"
  wait "$owner_pid"
  test_pass "second and third invocations both skip while owner holds lock"
else
  printf 'release\n' > "$LOCK_OWNER_RELEASE"
  wait "$owner_pid" 2>/dev/null || true
  test_fail "lock loser cleanup released or disturbed active owner"
  sed 's/^/    /' /tmp/run-scheduled-loser1.out >&2 || true
  sed 's/^/    /' /tmp/run-scheduled-loser2.out >&2 || true
fi

runner_summary
