#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass() {
  printf '[PASS] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

cd "${REPO_DIR}"

find benchmarks -type f -name '*.sh' -print0 | xargs -0 -n 1 bash -n
pass "benchmark shell scripts pass bash -n"

if ./benchmarks/bench.sh --help | grep -q 'Usage:'; then
  pass "bench.sh --help prints usage"
else
  fail "bench.sh --help did not print usage"
fi

if ./benchmarks/bench.sh 'bad!label' >/tmp/bench-invalid.out 2>&1; then
  fail "bench.sh accepted an invalid label"
fi
if grep -q 'Label must match' /tmp/bench-invalid.out; then
  pass "bench.sh rejects invalid labels"
else
  fail "bench.sh invalid-label error message missing"
fi
rm -f /tmp/bench-invalid.out

cp -R benchmarks "${TMP_DIR}/benchmarks"
: > "${TMP_DIR}/benchmarks/epoch.conf"
if "${TMP_DIR}/benchmarks/bench.sh" missing-epoch >/tmp/bench-epoch.out 2>&1; then
  fail "bench.sh ran with an empty epoch.conf"
fi
if grep -q 'epoch.conf' /tmp/bench-epoch.out; then
  pass "bench.sh rejects empty epoch.conf"
else
  fail "bench.sh empty-epoch error message missing"
fi
rm -f /tmp/bench-epoch.out

RUN_ON_HOST_FIXTURE="${TMP_DIR}/benchmarks-run-on-host"
RUN_ON_HOST_SHIMS="${TMP_DIR}/benchmarks-run-on-host-shims"
RUN_ON_HOST_RSYNC_LOG="${TMP_DIR}/run-on-host-rsync.log"
RUN_ON_HOST_SSH_LOG="${TMP_DIR}/run-on-host-ssh.log"
RUN_ON_HOST_PUSH_LOG="${TMP_DIR}/run-on-host-push.log"
cp -R benchmarks "${RUN_ON_HOST_FIXTURE}"
mkdir -p "${RUN_ON_HOST_SHIMS}"

cat > "${RUN_ON_HOST_FIXTURE}/influx-push.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "${RUN_ON_HOST_PUSH_LOG}"
EOF

cat > "${RUN_ON_HOST_SHIMS}/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RUN_ON_HOST_RSYNC_LOG}"
last_arg=""
for arg in "$@"; do
  last_arg="${arg}"
done
if [[ "${last_arg}" != *:* ]]; then
  mkdir -p "${last_arg%/}"
  printf '{"label":"fixture"}\n' > "${last_arg%/}/env.json"
fi
EOF

cat > "${RUN_ON_HOST_SHIMS}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${RUN_ON_HOST_SSH_LOG}"
if [[ "$*" == *"command -v nix >/dev/null 2>&1"* ]]; then
  if [[ "${RUN_ON_HOST_NIX_PRESENT:-0}" == "1" ]]; then
    printf '/nix/store/fake/bin/nix\n'
    exit 0
  fi
  exit 1
fi
EOF

cat > "${RUN_ON_HOST_SHIMS}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'yq should not be called for direct IP resolution\n' >&2
exit 99
EOF

chmod +x "${RUN_ON_HOST_FIXTURE}/influx-push.sh" \
  "${RUN_ON_HOST_SHIMS}/rsync" \
  "${RUN_ON_HOST_SHIMS}/ssh" \
  "${RUN_ON_HOST_SHIMS}/yq"
if PATH="${RUN_ON_HOST_SHIMS}:${PATH}" \
  RUN_ON_HOST_RSYNC_LOG="${RUN_ON_HOST_RSYNC_LOG}" \
  RUN_ON_HOST_SSH_LOG="${RUN_ON_HOST_SSH_LOG}" \
  "${RUN_ON_HOST_FIXTURE}/run-on-host.sh" 192.0.2.10 direct-ip-test >/tmp/run-on-host.out 2>&1; then
  pass "run-on-host.sh accepts a direct IP without yq or site/config.yaml"
else
  fail "run-on-host.sh direct IP mode failed without yq/site/config.yaml"
fi
if grep -q "root@192.0.2.10 cd '/tmp/benchmarks-direct-ip-test' && ./bench.sh direct-ip-test --no-push --synthetic-only" "${RUN_ON_HOST_SSH_LOG}"; then
  pass "run-on-host.sh builds the expected remote bench command for direct IP mode"
else
  fail "run-on-host.sh direct IP remote command was not logged as expected"
fi
rm -f /tmp/run-on-host.out
: > "${RUN_ON_HOST_RSYNC_LOG}"
: > "${RUN_ON_HOST_SSH_LOG}"

if PATH="${RUN_ON_HOST_SHIMS}:${PATH}" \
  RUN_ON_HOST_RSYNC_LOG="${RUN_ON_HOST_RSYNC_LOG}" \
  RUN_ON_HOST_SSH_LOG="${RUN_ON_HOST_SSH_LOG}" \
  RUN_ON_HOST_NIX_PRESENT=1 \
  "${RUN_ON_HOST_FIXTURE}/run-on-host.sh" 192.0.2.10 full-mode-test --full --sustained >/tmp/run-on-host-full.out 2>&1; then
  pass "run-on-host.sh supports --full when the remote target has nix"
else
  fail "run-on-host.sh --full failed even though the remote target reported nix"
fi
if grep -q "root@192.0.2.10 command -v nix >/dev/null 2>&1" "${RUN_ON_HOST_SSH_LOG}" && \
  grep -q "root@192.0.2.10 cd '/tmp/benchmarks-full-mode-test' && ./bench.sh full-mode-test --no-push --sustained" "${RUN_ON_HOST_SSH_LOG}" && \
  ! grep -q "full-mode-test --no-push --synthetic-only" "${RUN_ON_HOST_SSH_LOG}"; then
  pass "run-on-host.sh uses full mode when nix is available remotely"
else
  fail "run-on-host.sh did not build the expected --full remote command"
fi
rm -f /tmp/run-on-host-full.out
: > "${RUN_ON_HOST_RSYNC_LOG}"
: > "${RUN_ON_HOST_SSH_LOG}"

if PATH="${RUN_ON_HOST_SHIMS}:${PATH}" \
  RUN_ON_HOST_RSYNC_LOG="${RUN_ON_HOST_RSYNC_LOG}" \
  RUN_ON_HOST_SSH_LOG="${RUN_ON_HOST_SSH_LOG}" \
  RUN_ON_HOST_NIX_PRESENT=0 \
  "${RUN_ON_HOST_FIXTURE}/run-on-host.sh" 192.0.2.10 full-fallback-test --full >/tmp/run-on-host-fallback.out 2>&1; then
  pass "run-on-host.sh falls back cleanly when --full targets a host without nix"
else
  fail "run-on-host.sh --full should have fallen back to synthetic-only"
fi
if grep -q 'falling back to --synthetic-only' /tmp/run-on-host-fallback.out && \
  grep -q "root@192.0.2.10 cd '/tmp/benchmarks-full-fallback-test' && ./bench.sh full-fallback-test --no-push --synthetic-only" "${RUN_ON_HOST_SSH_LOG}"; then
  pass "run-on-host.sh warns and falls back to synthetic-only when nix is absent"
else
  fail "run-on-host.sh did not warn or fall back correctly when nix was absent"
fi
rm -f /tmp/run-on-host-fallback.out
: > "${RUN_ON_HOST_RSYNC_LOG}"
: > "${RUN_ON_HOST_SSH_LOG}"
: > "${RUN_ON_HOST_PUSH_LOG}"

RUN_ON_HOST_REPUSH_DIR="${RUN_ON_HOST_FIXTURE}/results/repush-only-test"
mkdir -p "${RUN_ON_HOST_REPUSH_DIR}/synthetic"
cat > "${RUN_ON_HOST_REPUSH_DIR}/env.json" <<'EOF'
{"label":"repush-only-test","host":"fixture","trigger":"manual","config_epoch":"test-epoch","context":"proxmox-host","timestamp":"2026-04-17T00:00:00Z","timestamp_ns":1}
EOF
cat > "${RUN_ON_HOST_REPUSH_DIR}/synthetic/stream.json" <<'EOF'
{"test":"stream","results":[{"threads":1,"cpu_list":"0","triad_gbps":1.0},{"threads":8,"cpu_list":"0,1,2,3,4,5,6,7","triad_gbps":8.0}]}
EOF
cat > "${RUN_ON_HOST_REPUSH_DIR}/synthetic/sysbench-cpu.json" <<'EOF'
{"test":"sysbench_cpu","threads":8,"events_per_second":100.0}
EOF
cat > "${RUN_ON_HOST_REPUSH_DIR}/synthetic/fio.json" <<'EOF'
{"test":"fio","workloads":[{"backend":"nvme","seq_read_mbps":1000.0,"seq_write_mbps":900.0,"rand_read_iops":50000.0,"rand_write_iops":40000.0}]}
EOF
printf '# fixture summary\n' > "${RUN_ON_HOST_REPUSH_DIR}/summary.md"

if PATH="${RUN_ON_HOST_SHIMS}:${PATH}" \
  RUN_ON_HOST_RSYNC_LOG="${RUN_ON_HOST_RSYNC_LOG}" \
  RUN_ON_HOST_SSH_LOG="${RUN_ON_HOST_SSH_LOG}" \
  RUN_ON_HOST_PUSH_LOG="${RUN_ON_HOST_PUSH_LOG}" \
  INFLUX_TOKEN=test-token \
  "${RUN_ON_HOST_FIXTURE}/run-on-host.sh" 192.0.2.10 repush-only-test >/tmp/run-on-host-repush.out 2>&1; then
  pass "run-on-host.sh re-pushes completed local results when the push marker is missing"
else
  fail "run-on-host.sh did not re-push an existing completed result set"
fi
if grep -q 'retrying InfluxDB push only' /tmp/run-on-host-repush.out && \
  [[ -f "${RUN_ON_HOST_REPUSH_DIR}/.push-ok" ]] && \
  [[ ! -s "${RUN_ON_HOST_RSYNC_LOG}" ]] && \
  [[ ! -s "${RUN_ON_HOST_SSH_LOG}" ]] && \
  grep -q "^${RUN_ON_HOST_REPUSH_DIR}\$" "${RUN_ON_HOST_PUSH_LOG}"; then
  pass "run-on-host.sh records the push marker without re-running or re-copying the benchmark"
else
  fail "run-on-host.sh did not preserve the existing results while retrying the push"
fi
rm -f /tmp/run-on-host-repush.out
: > "${RUN_ON_HOST_RSYNC_LOG}"
: > "${RUN_ON_HOST_SSH_LOG}"
: > "${RUN_ON_HOST_PUSH_LOG}"

RUN_ON_HOST_INCOMPLETE_FULL_DIR="${RUN_ON_HOST_FIXTURE}/results/full-incomplete-test"
mkdir -p "${RUN_ON_HOST_INCOMPLETE_FULL_DIR}/synthetic"
cat > "${RUN_ON_HOST_INCOMPLETE_FULL_DIR}/env.json" <<'EOF'
{"label":"full-incomplete-test","host":"fixture","trigger":"manual","config_epoch":"test-epoch","context":"cicd-guest","timestamp":"2026-04-17T00:00:00Z","timestamp_ns":1}
EOF
cat > "${RUN_ON_HOST_INCOMPLETE_FULL_DIR}/synthetic/stream.json" <<'EOF'
{"test":"stream","results":[{"threads":1,"cpu_list":"0","triad_gbps":1.0},{"threads":8,"cpu_list":"0,1,2,3,4,5,6,7","triad_gbps":8.0}]}
EOF
cat > "${RUN_ON_HOST_INCOMPLETE_FULL_DIR}/synthetic/sysbench-cpu.json" <<'EOF'
{"test":"sysbench_cpu","threads":8,"events_per_second":100.0}
EOF
cat > "${RUN_ON_HOST_INCOMPLETE_FULL_DIR}/synthetic/fio.json" <<'EOF'
{"test":"fio","workloads":[{"backend":"nvme","seq_read_mbps":1000.0,"seq_write_mbps":900.0,"rand_read_iops":50000.0,"rand_write_iops":40000.0}]}
EOF
printf '# fixture summary\n' > "${RUN_ON_HOST_INCOMPLETE_FULL_DIR}/summary.md"

if PATH="${RUN_ON_HOST_SHIMS}:${PATH}" \
  RUN_ON_HOST_RSYNC_LOG="${RUN_ON_HOST_RSYNC_LOG}" \
  RUN_ON_HOST_SSH_LOG="${RUN_ON_HOST_SSH_LOG}" \
  RUN_ON_HOST_PUSH_LOG="${RUN_ON_HOST_PUSH_LOG}" \
  INFLUX_TOKEN=test-token \
  "${RUN_ON_HOST_FIXTURE}/run-on-host.sh" 192.0.2.10 full-incomplete-test --full >/tmp/run-on-host-full-incomplete.out 2>&1; then
  fail "run-on-host.sh accepted synthetic-only local results for --full reuse"
fi
if grep -q 'Local results directory already exists and is incomplete' /tmp/run-on-host-full-incomplete.out && \
  [[ ! -f "${RUN_ON_HOST_INCOMPLETE_FULL_DIR}/.push-ok" ]] && \
  [[ ! -s "${RUN_ON_HOST_RSYNC_LOG}" ]] && \
  [[ ! -s "${RUN_ON_HOST_SSH_LOG}" ]] && \
  [[ ! -s "${RUN_ON_HOST_PUSH_LOG}" ]]; then
  pass "run-on-host.sh rejects incomplete --full local results instead of re-pushing them"
else
  fail "run-on-host.sh did not fail closed for incomplete --full local results"
fi
rm -f /tmp/run-on-host-full-incomplete.out

CPU_TOPOLOGY_FIXTURE="${TMP_DIR}/cpu-topology"
mkdir -p "${CPU_TOPOLOGY_FIXTURE}/sys/devices/system/cpu"
cat > "${CPU_TOPOLOGY_FIXTURE}/proc.cpuinfo" <<'EOF'
processor   : 0
model name  : Intel(R) Core(TM) Ultra 9 285HX
EOF
printf '0-23\n' > "${CPU_TOPOLOGY_FIXTURE}/sys/devices/system/cpu/online"
if BENCH_UNAME_S=Linux \
  BENCH_SYS_CPU_DIR="${CPU_TOPOLOGY_FIXTURE}/sys/devices/system/cpu" \
  BENCH_CPUINFO_FILE="${CPU_TOPOLOGY_FIXTURE}/proc.cpuinfo" \
  bash -c '
    set -euo pipefail
    source "'"${REPO_DIR}"'/benchmarks/lib/cpu-topology.sh"
    load_cpu_topology
    [[ "${TOPOLOGY_STREAM_CPUS}" == "0,1,2,3,4,5,6,7" ]]
    [[ "${TOPOLOGY_STREAM_THREADS}" == "8" ]]
    [[ "${TOPOLOGY_IS_HYBRID}" == "1" ]]
  '; then
  pass "cpu-topology lookup fallback pins STREAM to the 285HX P-cores"
else
  fail "cpu-topology lookup fallback did not produce the expected 285HX P-core list"
fi

CAPTURE_ENV_SHIMS="${TMP_DIR}/capture-env-shims"
mkdir -p "${CAPTURE_ENV_SHIMS}"
cat > "${CAPTURE_ENV_SHIMS}/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-n" ]]; then
  shift
fi
exec "$@"
EOF
cat > "${CAPTURE_ENV_SHIMS}/dmidecode" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'OUT'
Handle 0x0040, DMI type 17, 92 bytes
Memory Device
	Size: 32 GB
	Locator: DIMM A
	Speed: 5600 MT/s
	Configured Memory Speed: 5600 MT/s
	Manufacturer: ExampleCorp
	Part Number: ABC123

OUT
EOF
chmod +x "${CAPTURE_ENV_SHIMS}/sudo" "${CAPTURE_ENV_SHIMS}/dmidecode"
PATH="${CAPTURE_ENV_SHIMS}:${PATH}" \
  ./benchmarks/capture-env.sh \
  --label dmidecode-fixture \
  --trigger manual \
  --epoch e0-test \
  --output "${TMP_DIR}/env-dmidecode.json"
if jq -e '
  .dmidecode_summary == [
    "Size: 32 GB",
    "Locator: DIMM A",
    "Speed: 5600 MT/s",
    "Configured Memory Speed: 5600 MT/s",
    "Manufacturer: ExampleCorp",
    "Part Number: ABC123"
  ]
' "${TMP_DIR}/env-dmidecode.json" >/dev/null; then
  pass "capture-env.sh parses tab-indented dmidecode fields"
else
  fail "capture-env.sh did not preserve dmidecode summary fields"
fi

./benchmarks/capture-env.sh --label test-env --trigger manual --epoch e0-test --output "${TMP_DIR}/env.json"
if jq -e '
  .label == "test-env" and
  .trigger == "manual" and
  .config_epoch == "e0-test" and
  (.cpu_flags | type) == "array" and
  (.mounts | type) == "array" and
  (.notes | type) == "array"
' "${TMP_DIR}/env.json" >/dev/null; then
  pass "capture-env.sh writes the required JSON structure"
else
  fail "capture-env.sh JSON structure is missing required fields"
fi

STDDEV_FIXTURE_DIR="${TMP_DIR}/stddev-fixture"
mkdir -p "${STDDEV_FIXTURE_DIR}"
cat > "${STDDEV_FIXTURE_DIR}/run1.json" <<'EOF'
{"target":"bench-opentofu","mode":"scratch","results":[{"median":10.0}]}
EOF
cat > "${STDDEV_FIXTURE_DIR}/run2.json" <<'EOF'
{"target":"bench-opentofu","mode":"scratch","results":[{"median":10.2}]}
EOF
cat > "${STDDEV_FIXTURE_DIR}/run3.json" <<'EOF'
{"target":"bench-opentofu","mode":"scratch","results":[{"median":9.8}]}
EOF
if python3 ./benchmarks/lib/stddev-validate.py \
  "${STDDEV_FIXTURE_DIR}/run1.json" \
  "${STDDEV_FIXTURE_DIR}/run2.json" \
  "${STDDEV_FIXTURE_DIR}/run3.json" \
  | jq -e '.pass == true and .target == "bench-opentofu" and .mode == "scratch" and (.stddev_pct < 8)' >/dev/null; then
  pass "stddev-validate.py accepts stable cicd application timings"
else
  fail "stddev-validate.py should have accepted the low-variance fixture"
fi
cat > "${STDDEV_FIXTURE_DIR}/run2.json" <<'EOF'
{"target":"bench-opentofu","mode":"scratch","results":[{"median":20.0}]}
EOF
cat > "${STDDEV_FIXTURE_DIR}/run3.json" <<'EOF'
{"target":"bench-opentofu","mode":"scratch","results":[{"median":30.0}]}
EOF
if python3 ./benchmarks/lib/stddev-validate.py \
  "${STDDEV_FIXTURE_DIR}/run1.json" \
  "${STDDEV_FIXTURE_DIR}/run2.json" \
  "${STDDEV_FIXTURE_DIR}/run3.json" \
  | jq -e '.pass == false and (.stddev_pct > 8)' >/dev/null; then
  pass "stddev-validate.py rejects high-variance cicd application timings"
else
  fail "stddev-validate.py should have rejected the high-variance fixture"
fi

create_baseline_fixture_result() {
  local dir="$1"
  local label="$2"
  local context="$3"
  local with_application="$4"
  local scratch_median="$5"
  local rebuild_median="$6"

  mkdir -p "${dir}/synthetic"
  cat > "${dir}/env.json" <<EOF
{"label":"${label}","host":"fixture","trigger":"manual","config_epoch":"test-epoch","context":"${context}","timestamp":"2026-04-17T00:00:00Z","timestamp_ns":1}
EOF
  cat > "${dir}/synthetic/stream.json" <<'EOF'
{"test":"stream","results":[{"threads":1,"cpu_list":"0","triad_gbps":1.0},{"threads":8,"cpu_list":"0,1,2,3,4,5,6,7","triad_gbps":8.0}]}
EOF
  cat > "${dir}/synthetic/sysbench-cpu.json" <<'EOF'
{"test":"sysbench_cpu","threads":8,"events_per_second":100.0}
EOF
  cat > "${dir}/synthetic/sysbench-cpu-sustained.json" <<'EOF'
{"test":"sysbench_cpu_sustained","threads":8,"events_per_second":99.0,"sample_stats":{"min":98.0,"max":100.0,"mean":99.0,"stddev":1.0}}
EOF
  cat > "${dir}/synthetic/fio.json" <<'EOF'
{"test":"fio","workloads":[{"backend":"nvme","seq_read_mbps":1000.0,"seq_write_mbps":900.0,"rand_read_iops":50000.0,"rand_write_iops":40000.0}]}
EOF
  if [[ "${with_application}" == "1" ]]; then
    mkdir -p "${dir}/application/scratch" "${dir}/application/rebuild"
    cat > "${dir}/application/scratch/bench-opentofu.json" <<EOF
{"target":"bench-opentofu","mode":"scratch","results":[{"median":${scratch_median},"mean":${scratch_median},"stddev":0.1,"min":${scratch_median},"max":${scratch_median},"times":[${scratch_median},${scratch_median},${scratch_median}]}]}
EOF
    cat > "${dir}/application/rebuild/bench-opentofu.json" <<EOF
{"target":"bench-opentofu","mode":"rebuild","results":[{"median":${rebuild_median},"mean":${rebuild_median},"stddev":0.1,"min":${rebuild_median},"max":${rebuild_median},"times":[${rebuild_median},${rebuild_median},${rebuild_median}]}]}
EOF
  fi
  printf '# fixture summary\n' > "${dir}/summary.md"
}

mark_push_ok_fixture_result() {
  local dir="$1"
  printf '2026-04-17T00:00:00Z\n' > "${dir}/.push-ok"
}

BASELINE_FIXTURE_ROOT="${TMP_DIR}/baseline-fixture"
BASELINE_SHIMS="${TMP_DIR}/baseline-shims"
RUN_BASELINE_CALL_LOG="${TMP_DIR}/run-baseline-calls.log"
RUN_BASELINE_SSH_COUNTER="${TMP_DIR}/run-baseline-ssh-counter"
mkdir -p "${BASELINE_FIXTURE_ROOT}" "${BASELINE_SHIMS}" "${BASELINE_FIXTURE_ROOT}/site"
cp -R benchmarks "${BASELINE_FIXTURE_ROOT}/benchmarks"
cat > "${BASELINE_FIXTURE_ROOT}/site/config.yaml" <<'EOF'
domain: example.com
nodes:
  - name: pve01
    mgmt_ip: 192.0.2.11
  - name: pve02
    mgmt_ip: 192.0.2.12
  - name: pve03
    mgmt_ip: 192.0.2.13
vms:
  pbs:
    ip: 192.0.2.21
  gitlab:
    ip: 192.0.2.22
  cicd:
    ip: 192.0.2.23
    vmid: 160
    node: pve01
  gatus:
    ip: 192.0.2.24
cicd:
  project_name: mycofu
EOF
cat > "${BASELINE_FIXTURE_ROOT}/site/applications.yaml" <<'EOF'
applications: {}
EOF
printf 'test-epoch\n' > "${BASELINE_FIXTURE_ROOT}/benchmarks/epoch.conf"
cat > "${BASELINE_FIXTURE_ROOT}/benchmarks/run-on-host.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
host="$1"
label="$2"
shift 2
results_dir=""
full=0
marker_name="${BENCH_PUSH_OK_MARKER_NAME:-.push-ok}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --results-dir)
      shift
      results_dir="${1:-}"
      ;;
    --full)
      full=1
      ;;
  esac
  shift
done
push_marker="${results_dir}/${marker_name}"
if [[ -f "${results_dir}/env.json" && -f "${results_dir}/summary.md" && ! -f "${push_marker}" ]]; then
  printf 'repush:%s\n' "${label}" >> "${RUN_BASELINE_CALL_LOG}"
  printf '2026-04-17T00:00:00Z\n' > "${push_marker}"
  exit 0
fi
printf 'run:%s\n' "${label}" >> "${RUN_BASELINE_CALL_LOG}"
mkdir -p "${results_dir}/synthetic"
cat > "${results_dir}/env.json" <<JSON
{"label":"${label}","host":"${host}","trigger":"manual","config_epoch":"test-epoch","context":"$( [[ "${full}" -eq 1 ]] && printf 'cicd-guest' || printf 'proxmox-host' )","timestamp":"2026-04-17T00:00:00Z","timestamp_ns":1}
JSON
cat > "${results_dir}/synthetic/stream.json" <<'JSON'
{"test":"stream","results":[{"threads":1,"cpu_list":"0","triad_gbps":1.0},{"threads":8,"cpu_list":"0,1,2,3,4,5,6,7","triad_gbps":8.0}]}
JSON
cat > "${results_dir}/synthetic/sysbench-cpu.json" <<'JSON'
{"test":"sysbench_cpu","threads":8,"events_per_second":100.0}
JSON
cat > "${results_dir}/synthetic/sysbench-cpu-sustained.json" <<'JSON'
{"test":"sysbench_cpu_sustained","threads":8,"events_per_second":99.0,"sample_stats":{"min":98.0,"max":100.0,"mean":99.0,"stddev":1.0}}
JSON
cat > "${results_dir}/synthetic/fio.json" <<'JSON'
{"test":"fio","workloads":[{"backend":"nvme","seq_read_mbps":1000.0,"seq_write_mbps":900.0,"rand_read_iops":50000.0,"rand_write_iops":40000.0}]}
JSON
if [[ "${full}" -eq 1 ]]; then
  mkdir -p "${results_dir}/application/scratch" "${results_dir}/application/rebuild"
  scratch_median=10.0
  rebuild_median=5.0
  case "${label}" in
    *run2)
      scratch_median=10.2
      rebuild_median=5.1
      ;;
    *run3)
      scratch_median=9.8
      rebuild_median=4.9
      ;;
  esac
  cat > "${results_dir}/application/scratch/bench-opentofu.json" <<JSON
{"target":"bench-opentofu","mode":"scratch","results":[{"median":${scratch_median},"mean":${scratch_median},"stddev":0.1,"min":${scratch_median},"max":${scratch_median},"times":[${scratch_median},${scratch_median},${scratch_median}]}]}
JSON
  cat > "${results_dir}/application/rebuild/bench-opentofu.json" <<JSON
{"target":"bench-opentofu","mode":"rebuild","results":[{"median":${rebuild_median},"mean":${rebuild_median},"stddev":0.1,"min":${rebuild_median},"max":${rebuild_median},"times":[${rebuild_median},${rebuild_median},${rebuild_median}]}]}
JSON
fi
printf '# stub summary\n' > "${results_dir}/summary.md"
printf '2026-04-17T00:00:00Z\n' > "${push_marker}"
EOF
cat > "${BASELINE_SHIMS}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
last_arg=""
for arg in "$@"; do
  last_arg="${arg}"
done
if [[ "${last_arg}" == *"/cluster/tasks"*"--output-format json"* ]]; then
  printf '%s\n' "${RUN_BASELINE_PROXMOX_TASKS_JSON:-[]}"
  exit 0
fi
if [[ "${last_arg}" == *"proxmox-backup-manager task list --output-format json"* ]]; then
  printf '%s\n' "${RUN_BASELINE_PBS_TASKS_JSON:-[]}"
  exit 0
fi
if [[ "${last_arg}" == *"/cluster/resources --type vm --output-format json"* ]]; then
  counter=0
  if [[ -f "${RUN_BASELINE_SSH_COUNTER}" ]]; then
    counter="$(cat "${RUN_BASELINE_SSH_COUNTER}")"
  fi
  counter=$((counter + 1))
  printf '%s\n' "${counter}" > "${RUN_BASELINE_SSH_COUNTER}"
  node="pve01"
  if [[ "${counter}" -ge 3 ]]; then
    node="pve02"
  fi
  printf '[{"vmid":160,"node":"%s"}]\n' "${node}"
  exit 0
fi
printf 'unexpected ssh invocation: %s\n' "$*" >&2
exit 1
EOF
cat > "${BASELINE_SHIMS}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
last_arg=""
for arg in "$@"; do
  last_arg="${arg}"
done
if [[ "${last_arg}" == *"/api/v4/projects?search="* ]]; then
  printf '%s\n' "${RUN_BASELINE_GITLAB_PROJECTS_JSON:-[]}"
  exit 0
fi
if [[ "${last_arg}" == *"/pipelines?per_page=20"* ]]; then
  printf '%s\n' "${RUN_BASELINE_GITLAB_PIPELINES_JSON:-[]}"
  exit 0
fi
if [[ "${last_arg}" == "http://"*"/api/v1/endpoints/statuses?page=1" ]]; then
  printf '%s\n' "${RUN_BASELINE_GATUS_STATUSES_JSON:-[]}"
  exit 0
fi
printf 'unexpected curl invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${BASELINE_FIXTURE_ROOT}/benchmarks/run-on-host.sh" \
  "${BASELINE_FIXTURE_ROOT}/benchmarks/run-baseline.sh" \
  "${BASELINE_FIXTURE_ROOT}/benchmarks/lib/stddev-validate.py" \
  "${BASELINE_SHIMS}/ssh" \
  "${BASELINE_SHIMS}/curl"

BASELINE_GITLAB_PROJECTS_DEFAULT='[{"id":123,"path":"mycofu"}]'
BASELINE_GATUS_STATUSES_HEALTHY='[{"name":"gitlab","results":[{"success":true}]}]'

reset_baseline_fixture_state() {
  : > "${RUN_BASELINE_CALL_LOG}"
  printf '0\n' > "${RUN_BASELINE_SSH_COUNTER}"
}

run_baseline_fixture() {
  local label="$1"
  shift
  PATH="${BASELINE_SHIMS}:${PATH}" \
    RUN_BASELINE_CALL_LOG="${RUN_BASELINE_CALL_LOG}" \
    RUN_BASELINE_SSH_COUNTER="${RUN_BASELINE_SSH_COUNTER}" \
    RUN_BASELINE_PROXMOX_TASKS_JSON="${RUN_BASELINE_PROXMOX_TASKS_JSON:-[]}" \
    RUN_BASELINE_PBS_TASKS_JSON="${RUN_BASELINE_PBS_TASKS_JSON:-[]}" \
    RUN_BASELINE_GITLAB_PROJECTS_JSON="${RUN_BASELINE_GITLAB_PROJECTS_JSON:-${BASELINE_GITLAB_PROJECTS_DEFAULT}}" \
    RUN_BASELINE_GITLAB_PIPELINES_JSON="${RUN_BASELINE_GITLAB_PIPELINES_JSON:-[]}" \
    RUN_BASELINE_GATUS_STATUSES_JSON="${RUN_BASELINE_GATUS_STATUSES_JSON:-${BASELINE_GATUS_STATUSES_HEALTHY}}" \
    BENCH_GITLAB_TOKEN=test-token \
    BENCH_SKIP_GIT_ADD=1 \
    bash "${BASELINE_FIXTURE_ROOT}/benchmarks/run-baseline.sh" --label "${label}" "$@"
}

reset_baseline_fixture_state
if RUN_BASELINE_PROXMOX_TASKS_JSON='[{"node":"pve01","type":"qmigrate","upid":"UPID:test-active"}]' \
  run_baseline_fixture test-epoch-preflight-active >/tmp/run-baseline-active.out 2>&1; then
  fail "run-baseline.sh should block when cluster activity is detected"
fi
if grep -q 'Proxmox running tasks:' /tmp/run-baseline-active.out && \
  [[ ! -s "${RUN_BASELINE_CALL_LOG}" ]]; then
  pass "activity detected blocks run-baseline.sh before any benchmark runs start"
else
  fail "run-baseline.sh did not block on the stubbed activity preflight"
fi
rm -f /tmp/run-baseline-active.out

reset_baseline_fixture_state
if run_baseline_fixture test-epoch-preflight-quiet >/tmp/run-baseline-quiet.out 2>&1; then
  pass "cluster quiet allows run-baseline.sh to proceed through the full orchestration"
else
  fail "run-baseline.sh should have proceeded when the stubbed cluster was quiet"
fi
if [[ "$(wc -l < "${RUN_BASELINE_CALL_LOG}")" -eq 12 ]] && \
  grep -q 'Baseline complete. Commit results with:' /tmp/run-baseline-quiet.out; then
  pass "run-baseline.sh runs every benchmark slot when preflight checks stay quiet"
else
  fail "run-baseline.sh did not execute the expected full baseline after a quiet preflight"
fi
rm -f /tmp/run-baseline-quiet.out

reset_baseline_fixture_state
if RUN_BASELINE_PROXMOX_TASKS_JSON='[{"node":"pve01","type":"qmigrate","upid":"UPID:test-active"}]' \
  RUN_BASELINE_GITLAB_PIPELINES_JSON='[{"id":42,"status":"running"}]' \
  RUN_BASELINE_GATUS_STATUSES_JSON='[{"name":"gitlab","results":[{"success":false}]}]' \
  run_baseline_fixture test-epoch-preflight-ignore --ignore-activity >/tmp/run-baseline-ignore.out 2>&1; then
  pass "--ignore-activity lets run-baseline.sh proceed despite stubbed activity"
else
  fail "run-baseline.sh should have ignored the stubbed activity with --ignore-activity"
fi
if grep -q 'Skipping cluster activity preflight (--ignore-activity)' /tmp/run-baseline-ignore.out && \
  [[ "$(wc -l < "${RUN_BASELINE_CALL_LOG}")" -eq 12 ]]; then
  pass "--ignore-activity bypasses the activity gates while still running the full fixture"
else
  fail "run-baseline.sh did not bypass the activity gate as expected"
fi
rm -f /tmp/run-baseline-ignore.out

mkdir -p "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch"
create_baseline_fixture_result \
  "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch/pve01-synthetic-run1" \
  "test-epoch-pve01-synthetic-run1" \
  "proxmox-host" \
  "0" \
  "0" \
  "0"
create_baseline_fixture_result \
  "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch/pve02-synthetic-run1" \
  "test-epoch-pve02-synthetic-run1" \
  "proxmox-host" \
  "0" \
  "0" \
  "0"
mark_push_ok_fixture_result "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch/pve02-synthetic-run1"
reset_baseline_fixture_state
if run_baseline_fixture test-epoch >/tmp/run-baseline.out 2>&1; then
  pass "run-baseline.sh completes an end-to-end orchestration fixture"
else
  fail "run-baseline.sh orchestration fixture failed"
fi
if [[ "$(wc -l < "${RUN_BASELINE_CALL_LOG}")" -eq 11 ]] && \
  grep -q '^repush:test-epoch-pve01-synthetic-run1$' "${RUN_BASELINE_CALL_LOG}" && \
  ! grep -q '^run:test-epoch-pve02-synthetic-run1$' "${RUN_BASELINE_CALL_LOG}" && \
  grep -q '^run:test-epoch-pve02-synthetic-run2$' "${RUN_BASELINE_CALL_LOG}" && \
  [[ -f "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch/pve01-synthetic-run1/.push-ok" ]] && \
  grep -q '^run:test-epoch-cicd-full-run3$' "${RUN_BASELINE_CALL_LOG}"; then
  pass "run-baseline.sh resumes by retrying missing pushes and skipping runs with a push marker"
else
  fail "run-baseline.sh did not resume the fixture baseline as expected"
fi
if grep -q 'cicd migrated from pve01 to pve02 during baseline' "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch/summary.md" && \
  grep -q '| scratch | bench-opentofu |' "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch/summary.md" && \
  grep -q 'Baseline complete. Commit results with:' /tmp/run-baseline.out; then
  pass "run-baseline.sh writes stddev validation and cicd migration details into the summary"
else
  fail "run-baseline.sh summary is missing the expected validation or migration details"
fi
rm -f /tmp/run-baseline.out

# Regression: run-baseline.sh used to compute BASELINE_DIR before resolving
# EPOCH_LABEL from epoch.conf. The default no-`--label` path produced
# BASELINE_DIR=results/ (no epoch suffix), so subsequent epochs collided on
# the same dirs and silently skipped after a hardware change. (Issue #271.)
# Verify the no-`--label` path now nests results under the epoch-conf value
# AND the actual reported failure mode — epoch change with stale on-disk
# state — produces fresh runs, not silent skips.
run_baseline_fixture_no_label() {
  PATH="${BASELINE_SHIMS}:${PATH}" \
    RUN_BASELINE_CALL_LOG="${RUN_BASELINE_CALL_LOG}" \
    RUN_BASELINE_SSH_COUNTER="${RUN_BASELINE_SSH_COUNTER}" \
    RUN_BASELINE_PROXMOX_TASKS_JSON="${RUN_BASELINE_PROXMOX_TASKS_JSON:-[]}" \
    RUN_BASELINE_PBS_TASKS_JSON="${RUN_BASELINE_PBS_TASKS_JSON:-[]}" \
    RUN_BASELINE_GITLAB_PROJECTS_JSON="${RUN_BASELINE_GITLAB_PROJECTS_JSON:-${BASELINE_GITLAB_PROJECTS_DEFAULT}}" \
    RUN_BASELINE_GITLAB_PIPELINES_JSON="${RUN_BASELINE_GITLAB_PIPELINES_JSON:-[]}" \
    RUN_BASELINE_GATUS_STATUSES_JSON="${RUN_BASELINE_GATUS_STATUSES_JSON:-${BASELINE_GATUS_STATUSES_HEALTHY}}" \
    BENCH_GITLAB_TOKEN=test-token \
    BENCH_SKIP_GIT_ADD=1 \
    bash "${BASELINE_FIXTURE_ROOT}/benchmarks/run-baseline.sh"
}

# Defensive: the fixture is `cp -R`'d from the operator's benchmarks/ tree,
# which (pre-fix) may contain stale flat results dirs at results/<host>-runN
# directly. Wipe the whole results tree so the test starts clean.
rm -rf "${BASELINE_FIXTURE_ROOT}/benchmarks/results"
mkdir -p "${BASELINE_FIXTURE_ROOT}/benchmarks/results"
printf 'test-epoch\n' > "${BASELINE_FIXTURE_ROOT}/benchmarks/epoch.conf"
reset_baseline_fixture_state
if run_baseline_fixture_no_label >/tmp/run-baseline-no-label.out 2>&1; then
  pass "run-baseline.sh resolves epoch.conf when --label is omitted"
else
  fail "run-baseline.sh failed when --label was omitted (epoch.conf path)"
fi
if [[ -d "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch/pve01-synthetic-run1" ]] && \
  [[ ! -d "${BASELINE_FIXTURE_ROOT}/benchmarks/results/pve01-synthetic-run1" ]] && \
  [[ -f "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch/summary.md" ]] && \
  [[ ! -f "${BASELINE_FIXTURE_ROOT}/benchmarks/results/summary.md" ]]; then
  pass "run-baseline.sh nests results under the epoch.conf value, not RESULTS_ROOT"
else
  fail "run-baseline.sh did not nest results under the epoch when --label was omitted"
fi
rm -f /tmp/run-baseline-no-label.out

# The actual reported failure mode of #271: operator captures baseline at
# epoch A, bumps epoch.conf to B, re-runs run-baseline.sh, expects a fresh
# capture under results/B/. Pre-fix, BASELINE_DIR was results/, so all
# results/A/* dirs existed at the namespace the new run wanted to write —
# prepare_run_slot saw "completed" and skipped every run. Verify the new
# epoch's runs actually execute and the prior epoch's data is preserved.
printf 'epoch-B\n' > "${BASELINE_FIXTURE_ROOT}/benchmarks/epoch.conf"
reset_baseline_fixture_state
if run_baseline_fixture_no_label >/tmp/run-baseline-epoch-change.out 2>&1; then
  pass "run-baseline.sh handles an epoch.conf bump after a prior baseline"
else
  fail "run-baseline.sh failed after an epoch.conf bump"
fi
# The prior epoch's data is still there, AND the new epoch has fresh data,
# AND no skip occurred (call log shows runs, not just push markers).
if [[ -d "${BASELINE_FIXTURE_ROOT}/benchmarks/results/test-epoch/pve01-synthetic-run1" ]] && \
  [[ -d "${BASELINE_FIXTURE_ROOT}/benchmarks/results/epoch-B/pve01-synthetic-run1" ]] && \
  grep -q '^run:epoch-B-pve01-synthetic-run1$' "${RUN_BASELINE_CALL_LOG}"; then
  pass "epoch.conf bump triggers fresh runs without colliding with prior epoch's data"
else
  fail "epoch.conf bump did not produce a fresh capture under the new epoch"
fi
rm -f /tmp/run-baseline-epoch-change.out

if jq -e '.uid == "mycofu-benchmarks"' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Grafana dashboard JSON is present"
else
  fail "Grafana dashboard JSON is missing expected uid"
fi

if yq -e '.datasources[] | select(.name == "InfluxDB") | .jsonData.defaultBucket == "mycofu_benchmarks"' site/apps/grafana/datasources.yaml >/dev/null; then
  pass "Grafana datasource provisioning targets the benchmark bucket"
else
  fail "Grafana datasource provisioning is not pointing at mycofu_benchmarks"
fi

if rg -q 'extraDashboardPaths' framework/catalog/grafana/module.nix && \
  rg -q '\.\./\.\./\.\./benchmarks/grafana/dashboard.json' site/nix/hosts/grafana.nix; then
  pass "Grafana NixOS config provisions the benchmark dashboard from the repo"
else
  fail "Grafana NixOS config is not provisioning the benchmark dashboard"
fi

if jq -e '
  (.templating.list | map(.name) | index("virt_host")) != null and
  (.templating.list | map(.name) | index("virt_host_label")) != null and
  (.templating.list | map(.name) | index("virt_guest_label")) != null
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Grafana dashboard exposes dedicated virtualization filters"
else
  fail "Grafana dashboard is missing virtualization filter variables"
fi

if jq -e '
  .panels[]
  | select(.title == "Virtualization Tax")
  | .targets[0].query
  | contains("${virt_host}") and contains("${virt_host_label}") and contains("${virt_guest_label}")
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Virtualization Tax query uses the dedicated virtualization filters"
else
  fail "Virtualization Tax query is missing the dedicated virtualization filters"
fi

# Static ratchet: `threads` template variable exists with All=.* so the
# All-case regex expansion (/^.*$/) matches every threads tag value.
if jq -e '
  .templating.list[]
  | select(.name == "threads")
  | .includeAll == true and .allValue == ".*"
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Grafana dashboard has a threads template variable with All=.*"
else
  fail "Grafana dashboard threads variable is missing or has wrong All-value"
fi

# Static ratchet: Memory Bandwidth + CPU Throughput panels filter by threads.
# These are the panels whose underlying tests (stream, sysbench_cpu) actually
# vary by thread count, so the threads filter is meaningful.
for title in "Memory Bandwidth Over Time" "CPU Throughput Over Time"; do
  if jq -e --arg t "${title}" '
    .panels[]
    | select(.title == $t)
    | .targets[0].query
    | contains("r.threads =~ /^${threads}$/")
  ' benchmarks/grafana/dashboard.json >/dev/null; then
    pass "${title} filters by the threads variable"
  else
    fail "${title} is missing the threads filter"
  fi
done

# Static ratchet: Memory Bandwidth panel uses the GB/s unit.
if jq -e '
  .panels[]
  | select(.title == "Memory Bandwidth Over Time")
  | .fieldConfig.defaults.unit == "GB/s"
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Memory Bandwidth panel uses GB/s unit"
else
  fail "Memory Bandwidth panel is missing GB/s unit"
fi

# Static ratchet: Disk I/O is split into Disk Throughput (MB/s) and Disk IOPS
# (Grafana standard `iops` unit, autoscales). Each query restricts to its
# subtests and drops the threads column so historical fio rows (no threads
# tag) and current rows (threads=1) render as a single continuous series.
if jq -e '
  .panels[]
  | select(.title == "Disk Throughput")
  | (.fieldConfig.defaults.unit == "MB/s")
    and (.targets[0].query | contains("seq_read_mbps") and contains("seq_write_mbps"))
    and (.targets[0].query | contains("drop(columns: [\"threads\"])"))
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Disk Throughput panel uses MB/s, scopes to seq subtests, drops threads"
else
  fail "Disk Throughput panel is misconfigured"
fi

if jq -e '
  .panels[]
  | select(.title == "Disk IOPS")
  | (.fieldConfig.defaults.unit == "iops")
    and (.targets[0].query | contains("rand_read_iops") and contains("rand_write_iops"))
    and (.targets[0].query | contains("drop(columns: [\"threads\"])"))
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Disk IOPS panel uses iops unit, scopes to rand subtests, drops threads"
else
  fail "Disk IOPS panel is misconfigured"
fi

# Static ratchet: Virtualization Tax filters both host_series and guest_series
# by the threads variable. Without this, multi-thread data in the time range
# yields multiple tables and the lastNotNull stat reduction picks an arbitrary
# thread count that may not match the panel's selected threads value.
if jq -e '
  .panels[]
  | select(.title == "Virtualization Tax")
  | .targets[0].query
  | (split("host_series")[1] | split("guest_series")[0] | contains("r.threads =~ /^${threads}$/"))
    and (split("guest_series")[1] | split("join")[0] | contains("r.threads =~ /^${threads}$/"))
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Virtualization Tax filters both host_series and guest_series by threads"
else
  fail "Virtualization Tax host_series and/or guest_series is missing the threads filter"
fi

# Static ratchet: influx-push.sh emits threads=... on fio rows. fio is
# single-threaded today, but emitting the tag now means a future numjobs
# variation can land without a schema migration. The dashboard's disk panels
# drop the column to keep historical (no-tag) rows continuous with new rows.
if grep -nE 'test=fio,.*threads=' benchmarks/influx-push.sh >/dev/null; then
  pass "influx-push.sh emits a threads tag on fio bench_synthetic rows"
else
  fail "influx-push.sh fio row is missing the threads tag (forward-compat half-measure)"
fi

grep -q '^bench-nixos-closure$' benchmarks/application/targets.txt
pass "application target list contains bench-nixos-closure"

# Static ratchet: benchmark targets that wrap upstream packages MUST
# override `pname` so the derivation has a unique store hash. A bare
# reference (e.g., `bench-ffmpeg = pkgs.ffmpeg`) shares hashes with
# anything else on the host that uses the same package, which (1) makes
# scratch deletion fail because external paths reference the outputs,
# and (2) lets cache.nixos.org satisfy the build instead of measuring
# a real local rebuild. See benchmarks/flake.nix for the full reasoning.
# The regex covers versioned attrs (`pkgs.ffmpeg_7`), dotted attrs
# (`pkgs.python3Packages.foo`), and hyphenated attrs (`pkgs.ffmpeg-full`,
# `pkgs.haskellPackages.text-icu`) — any bare passthrough is a regression.
for target in bench-opentofu bench-ffmpeg; do
  if grep -qE "${target}[[:space:]]*=[[:space:]]*pkgs\.[a-zA-Z_][a-zA-Z0-9_.-]*[[:space:]]*;" benchmarks/flake.nix; then
    fail "benchmarks/flake.nix sets ${target} to a bare upstream package; wrap with overrideAttrs (old: { pname = \"${target}\"; }) so the derivation has a unique store hash"
  else
    pass "benchmarks/flake.nix ${target} is not a bare upstream package reference"
  fi
done

# ----------------------------------------------------------------------
# benchmarks/application/run-target.sh: ratchets + functional shim tests
# ----------------------------------------------------------------------

# Static ratchet: `--eval-cache <bool>` (with or without `=`) is invalid
# nix CLI. Nix parses the boolean as a positional flake reference,
# producing "cannot find flake 'flake:false'". Use --no-eval-cache.
if grep -nE '\-\-eval-cache[[:space:]=]+(true|false)\b' benchmarks/application/run-target.sh >/dev/null; then
  fail "run-target.sh uses invalid '--eval-cache <bool>' syntax; use --no-eval-cache"
else
  pass "run-target.sh does not use invalid --eval-cache <bool> syntax"
fi

# Static ratchet: `nix build --rebuild` is nix's reproducibility-
# verification flag, not "force from-scratch build". It exits non-zero
# when the path is not already in the store. Scratch mode must instead
# delete the target's output paths in prepare_target and run a plain
# `nix build` in measure_target. Anchored to skip comment lines so a
# future explanatory note about the historical bug doesn't false-trigger.
if grep -nE '^[[:space:]]*[^#].*nix build .* --rebuild' benchmarks/application/run-target.sh >/dev/null; then
  fail "run-target.sh invokes 'nix build --rebuild'; that flag verifies an existing build, it does not force a from-scratch one. Delete target outputs in prepare instead."
else
  pass "run-target.sh does not misuse 'nix build --rebuild' for scratch mode"
fi

# Static ratchet: scratch mode must enumerate ALL outputs (the "^*"
# selector) when calling nix path-info. Without it, multi-output
# derivations (ffmpeg has out/bin/dev/doc/lib/man) keep their non-
# default outputs in store and the next build substitutes the missing
# default from cache.nixos.org instead of rebuilding locally.
if grep -qE 'nix path-info[[:space:]]+["'\'']?\.#\$\{target\}\^\*' benchmarks/application/run-target.sh; then
  pass "run-target.sh enumerates all target outputs via the ^* installable selector"
else
  fail "run-target.sh scratch prepare must use 'nix path-info \".#\${target}^*\"' to enumerate all outputs of multi-output derivations; otherwise scratch substitutes from cache instead of rebuilding"
fi

# Static ratchet: the prebuild must also use the ^* selector so all
# outputs of multi-output derivations are realized. Otherwise the
# subsequent `nix path-info ".#${target}^*"` errors out because the
# non-default output paths are not yet valid in the store.
if grep -qE 'nix build[[:space:]]+["'\'']?\.#\$\{target\}\^\*' benchmarks/application/run-target.sh; then
  pass "run-target.sh prebuild realizes all outputs via the ^* installable selector"
else
  fail "run-target.sh prebuild must use 'nix build \".#\${target}^*\"' so all outputs of multi-output derivations are realized before path-info"
fi

# Static ratchet: scratch measure must disable substituters so deleted
# target outputs are rebuilt from source, not fetched from a public
# binary cache. Per benchmarks/README.md, scratch measures compile/
# link/disk/memory-bandwidth — substituting from cache would make it
# measure network throughput instead.
if grep -qE 'nix build.*--option substituters ""|nix build.*--substituters ""' benchmarks/application/run-target.sh; then
  pass "run-target.sh scratch measure disables substituters"
else
  fail "run-target.sh scratch measure must pass --option substituters \"\" so deleted outputs are rebuilt locally rather than fetched from a binary cache"
fi

# Static ratchet: prebuild stderr must NOT be redirected. A failed
# flake-fetch or build is otherwise invisible to the operator
# (hyperfine wraps its child's output, so the original error never
# reaches the log).
if grep -qE 'nix build .* --no-link[[:space:]]*>[[:space:]]*/dev/null[[:space:]]+2>&1' benchmarks/application/run-target.sh; then
  fail "run-target.sh prebuild redirects stderr to /dev/null; flake-fetch failures will be invisible to the operator"
else
  pass "run-target.sh prebuild keeps stderr visible"
fi

# Functional shim test: invoke run-target.sh with a fake nix in PATH
# and verify the constructed command lines for both prepare and
# measure, in both modes. Catches the original bug class
# (--eval-cache false, --rebuild) at the level of "what does nix
# actually receive" rather than the level of "what does the source
# happen to look like".
RUN_TARGET_TEST_DIR="${TMP_DIR}/run-target-shim"
RUN_TARGET_NIX_LOG="${RUN_TARGET_TEST_DIR}/nix-invocations.log"
mkdir -p "${RUN_TARGET_TEST_DIR}/bin"

cat > "${RUN_TARGET_TEST_DIR}/bin/nix" <<'NIX_SHIM'
#!/usr/bin/env bash
# Append the full argv (one line per call) to the invocation log.
printf '%s\n' "$*" >> "${RUN_TARGET_NIX_LOG}"
case "$1" in
  path-info)
    # Simulate a multi-output derivation by emitting two paths.
    echo "/nix/store/00000000000000000000000000000000-fake-out"
    echo "/nix/store/11111111111111111111111111111111-fake-bin"
    ;;
esac
exit 0
NIX_SHIM
chmod +x "${RUN_TARGET_TEST_DIR}/bin/nix"

run_with_nix_shim() {
  : > "${RUN_TARGET_NIX_LOG}"
  PATH="${RUN_TARGET_TEST_DIR}/bin:${PATH}" \
    RUN_TARGET_NIX_LOG="${RUN_TARGET_NIX_LOG}" \
    BENCH_TEST_SKIP_CACHE_DROP=1 \
    ./benchmarks/application/run-target.sh "$@"
}

# --- measure rebuild ---
run_with_nix_shim --internal-measure rebuild fake-target
if grep -qF 'build .#fake-target --no-link --no-eval-cache' "${RUN_TARGET_NIX_LOG}" \
   && ! grep -- '--rebuild' "${RUN_TARGET_NIX_LOG}" >/dev/null \
   && ! grep -- '--eval-cache false' "${RUN_TARGET_NIX_LOG}" >/dev/null \
   && ! grep -- 'substituters' "${RUN_TARGET_NIX_LOG}" >/dev/null; then
  pass "run-target.sh measure rebuild invokes nix build with --no-eval-cache (no --rebuild, no substituter override)"
else
  fail "run-target.sh measure rebuild produced unexpected nix invocation: $(cat ${RUN_TARGET_NIX_LOG})"
fi

# --- measure scratch ---
run_with_nix_shim --internal-measure scratch fake-target
if grep -qF 'build .#fake-target --no-link --no-eval-cache --option substituters' "${RUN_TARGET_NIX_LOG}" \
   && ! grep -- '--rebuild' "${RUN_TARGET_NIX_LOG}" >/dev/null \
   && ! grep -- '--eval-cache false' "${RUN_TARGET_NIX_LOG}" >/dev/null; then
  pass "run-target.sh measure scratch invokes nix build with --no-eval-cache and disables substituters"
else
  fail "run-target.sh measure scratch produced unexpected nix invocation: $(cat ${RUN_TARGET_NIX_LOG})"
fi

# --- prepare rebuild: should call `nix build` once with ^*, NO path-info, NO store delete ---
run_with_nix_shim --internal-prepare rebuild fake-target
if grep -qF 'build .#fake-target^* --no-link' "${RUN_TARGET_NIX_LOG}" \
   && ! grep -- 'path-info' "${RUN_TARGET_NIX_LOG}" >/dev/null \
   && ! grep -- 'store delete' "${RUN_TARGET_NIX_LOG}" >/dev/null; then
  pass "run-target.sh prepare rebuild pre-builds the target with ^* and skips deletion"
else
  fail "run-target.sh prepare rebuild produced unexpected nix invocations: $(cat ${RUN_TARGET_NIX_LOG})"
fi

# --- prepare scratch: nix build ^*, then nix path-info ^*, then nix store delete --ignore-liveness with two paths ---
# Capture line numbers so we assert the OPERATIONAL ORDER (build →
# path-info → delete), not just presence. A regression that reordered
# the calls (e.g., deleted before path-info) would silently pass a
# presence-only check. See round-2 sub-claude review P2-2.
run_with_nix_shim --internal-prepare scratch fake-target
build_line="$(grep -nF 'build .#fake-target^* --no-link' "${RUN_TARGET_NIX_LOG}" | head -1 | cut -d: -f1)"
pathinfo_line="$(grep -nF 'path-info .#fake-target^*' "${RUN_TARGET_NIX_LOG}" | head -1 | cut -d: -f1)"
delete_line="$(grep -nE 'store delete --ignore-liveness .*fake-out.*fake-bin' "${RUN_TARGET_NIX_LOG}" | head -1 | cut -d: -f1)"
if [[ -n "${build_line}" && -n "${pathinfo_line}" && -n "${delete_line}" \
   && "${build_line}" -lt "${pathinfo_line}" \
   && "${pathinfo_line}" -lt "${delete_line}" ]]; then
  pass "run-target.sh prepare scratch enumerates all outputs (^*) and deletes them in the correct order (build < path-info < delete)"
else
  fail "run-target.sh prepare scratch produced unexpected/out-of-order nix invocations: build=${build_line} path-info=${pathinfo_line} delete=${delete_line}; log: $(cat ${RUN_TARGET_NIX_LOG})"
fi

# --- prepare scratch: a nix store delete failure must propagate (no silent no-op) ---
cat > "${RUN_TARGET_TEST_DIR}/bin/nix" <<'NIX_SHIM_FAIL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RUN_TARGET_NIX_LOG}"
case "$1" in
  path-info)
    echo "/nix/store/00000000000000000000000000000000-fake-out"
    ;;
  store)
    # Simulate a delete failure (e.g., concurrent process, ACL, etc.)
    echo "fake error: store path is locked" >&2
    exit 1
    ;;
esac
exit 0
NIX_SHIM_FAIL
chmod +x "${RUN_TARGET_TEST_DIR}/bin/nix"

if run_with_nix_shim --internal-prepare scratch fake-target >/dev/null 2>&1; then
  fail "run-target.sh prepare scratch did NOT propagate nix store delete failure (silent no-op risk)"
else
  pass "run-target.sh prepare scratch propagates nix store delete failure with non-zero exit"
fi

# --- prepare scratch: an empty `nix path-info` output must die, not silently skip ---
# A target with no realized outputs is pathological (and the prebuild
# above should have realized them), but if path-info ever returns
# empty stdout, the round-2 fix must NOT silently skip deletion.
# Otherwise measure runs against a populated store and produces a
# mode=scratch result that is actually a no-op build — exactly the
# silent failure mode the round-2 rework is designed to eliminate.
cat > "${RUN_TARGET_TEST_DIR}/bin/nix" <<'NIX_SHIM_EMPTY'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RUN_TARGET_NIX_LOG}"
case "$1" in
  path-info)
    # Simulate empty (but successful) path-info output.
    exit 0
    ;;
esac
exit 0
NIX_SHIM_EMPTY
chmod +x "${RUN_TARGET_TEST_DIR}/bin/nix"

if run_with_nix_shim --internal-prepare scratch fake-target >/dev/null 2>&1; then
  fail "run-target.sh prepare scratch did NOT die on empty path-info output (silent no-op risk)"
else
  pass "run-target.sh prepare scratch dies loudly when path-info returns no outputs"
fi

# --- internal subcommands must validate mode is scratch or rebuild ---
# A typo like `--internal-prepare scrach foo` would otherwise silently
# take the rebuild branch (no deletion) and produce a "successful"
# prepare that is actually rebuild-prepare, then a measure that is
# also wrong-mode. Restore a passing nix shim first.
cat > "${RUN_TARGET_TEST_DIR}/bin/nix" <<'NIX_SHIM_OK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${RUN_TARGET_NIX_LOG}"
exit 0
NIX_SHIM_OK
chmod +x "${RUN_TARGET_TEST_DIR}/bin/nix"

if run_with_nix_shim --internal-prepare scrach fake-target >/dev/null 2>&1; then
  fail "run-target.sh --internal-prepare with invalid mode did NOT die"
else
  pass "run-target.sh --internal-prepare validates mode is scratch or rebuild"
fi

if run_with_nix_shim --internal-measure scrach fake-target >/dev/null 2>&1; then
  fail "run-target.sh --internal-measure with invalid mode did NOT die"
else
  pass "run-target.sh --internal-measure validates mode is scratch or rebuild"
fi
