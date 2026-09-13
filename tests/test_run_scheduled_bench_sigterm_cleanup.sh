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
LOCKFILE="${TMP_DIR}/scheduled.lock"

cat > "$CONFIG" <<'EOF'
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
printf 'e0-test\n' > "$EPOCH"
cat > "$RUN_ON_HOST" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$RUN_ON_HOST"

test_start "1" "SIGTERM removes stale lock"
set +e
BENCH_CONFIG_FILE="$CONFIG" \
BENCH_EPOCH_FILE="$EPOCH" \
BENCH_RUN_ON_HOST_BIN="$RUN_ON_HOST" \
BENCH_SCHEDULE_LOCKFILE="$LOCKFILE" \
BENCH_SCHEDULE_STATUS_ROOT="${TMP_DIR}/status" \
BENCH_SCHEDULE_STATUS_NO_PUSH=1 \
BENCH_GITLAB_PIPELINES_JSON='[]' \
"${REPO_ROOT}/benchmarks/run-scheduled-bench.sh" >/tmp/sigterm.out 2>&1 &
pid=$!
set -e
sleep 1
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
if [[ ! -e "$LOCKFILE" && ! -d "${LOCKFILE}.dir" ]]; then
  test_pass "SIGTERM cleanup removed lock"
else
  test_fail "lock remained after SIGTERM"
fi

runner_summary
