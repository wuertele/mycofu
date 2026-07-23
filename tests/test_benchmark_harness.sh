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
if grep -q "root@192.0.2.10 cd '/tmp/benchmarks-direct-ip-test' && ./bench.sh direct-ip-test --trigger manual --no-push --synthetic-only" "${RUN_ON_HOST_SSH_LOG}"; then
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
  grep -q "root@192.0.2.10 cd '/tmp/benchmarks-full-mode-test' && ./bench.sh full-mode-test --trigger manual --no-push --sustained" "${RUN_ON_HOST_SSH_LOG}" && \
  ! grep -q "full-mode-test --trigger manual --no-push --synthetic-only" "${RUN_ON_HOST_SSH_LOG}"; then
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
  grep -q "root@192.0.2.10 cd '/tmp/benchmarks-full-fallback-test' && ./bench.sh full-fallback-test --trigger manual --no-push --synthetic-only" "${RUN_ON_HOST_SSH_LOG}"; then
  pass "run-on-host.sh warns and falls back to synthetic-only when nix is absent"
else
  fail "run-on-host.sh did not warn or fall back correctly when nix was absent"
fi
rm -f /tmp/run-on-host-fallback.out
: > "${RUN_ON_HOST_RSYNC_LOG}"
: > "${RUN_ON_HOST_SSH_LOG}"
: > "${RUN_ON_HOST_PUSH_LOG}"

# ----------------------------------------------------------------------
# #329 ratchets: BOTH the nix probe (run-on-host.sh:218) and the remote
# bench invocation (:254) must pass `ssh -n`. The tests above already
# exercise both code paths (--full triggers the nix probe; every run
# hits the bench.sh call). Without an explicit `-n` ratchet, a future
# edit that drops `-n` from either would silently pass the greps above,
# which only match on the trailing argv substrings. The shim's `$*`
# format renders argv with spaces, so `-n` appears as `-n ` at the
# start of the recorded line whenever ssh -n is invoked with any
# following args.
: > "${RUN_ON_HOST_SSH_LOG}"
PATH="${RUN_ON_HOST_SHIMS}:${PATH}" \
  RUN_ON_HOST_RSYNC_LOG="${RUN_ON_HOST_RSYNC_LOG}" \
  RUN_ON_HOST_SSH_LOG="${RUN_ON_HOST_SSH_LOG}" \
  RUN_ON_HOST_NIX_PRESENT=1 \
  "${RUN_ON_HOST_FIXTURE}/run-on-host.sh" 192.0.2.10 dash-n-ratchet-test --full >/tmp/run-on-host-dash-n.out 2>&1 || true

# Every ssh line recorded by the shim must start with `-n ` (since we
# put `-n` first in the ssh argv for both invocations). If ANY ssh line
# lacks `-n ` at its start, some ssh call was made without -n.
non_dash_n="$(grep -v '^-n ' "${RUN_ON_HOST_SSH_LOG}" || true)"
if [[ -z "${non_dash_n}" ]]; then
  pass "run-on-host.sh #329 ratchet: every recorded ssh call starts with -n"
else
  fail "run-on-host.sh #329 ratchet: found ssh call(s) without -n:
${non_dash_n}"
fi

# And there must be BOTH a nix probe AND a bench.sh remote invocation
# in the recorded log — proving the ratchet actually exercised the
# two code paths this MR added -n to.
if grep -q "root@192.0.2.10 command -v nix >/dev/null 2>&1" "${RUN_ON_HOST_SSH_LOG}" \
   && grep -q "root@192.0.2.10 cd '/tmp/benchmarks-dash-n-ratchet-test' && ./bench.sh dash-n-ratchet-test " "${RUN_ON_HOST_SSH_LOG}"; then
  pass "run-on-host.sh #329 ratchet: exercised both nix probe and remote bench.sh invocation"
else
  fail "run-on-host.sh #329 ratchet: did not exercise both code paths — log: $(cat "${RUN_ON_HOST_SSH_LOG}")"
fi
rm -f /tmp/run-on-host-dash-n.out
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
printf 'unexpected curl invocation: %s\n' "$*" >&2
exit 1
EOF
chmod +x "${BASELINE_FIXTURE_ROOT}/benchmarks/run-on-host.sh" \
  "${BASELINE_FIXTURE_ROOT}/benchmarks/run-baseline.sh" \
  "${BASELINE_FIXTURE_ROOT}/benchmarks/lib/stddev-validate.py" \
  "${BASELINE_SHIMS}/ssh" \
  "${BASELINE_SHIMS}/curl"

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
    BENCH_SKIP_GIT_ADD=1 \
    bash "${BASELINE_FIXTURE_ROOT}/benchmarks/run-baseline.sh" --label "${label}" "$@"
}

reset_baseline_fixture_state
if run_baseline_fixture test-epoch-quiet >/tmp/run-baseline-quiet.out 2>&1; then
  pass "run-baseline.sh proceeds through the full orchestration"
else
  fail "run-baseline.sh should have proceeded with no preflight"
fi
if [[ "$(wc -l < "${RUN_BASELINE_CALL_LOG}")" -eq 12 ]] && \
  grep -q 'Baseline complete. Commit results with:' /tmp/run-baseline-quiet.out; then
  pass "run-baseline.sh runs every benchmark slot"
else
  fail "run-baseline.sh did not execute the expected full baseline"
fi
rm -f /tmp/run-baseline-quiet.out

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

if grep -q 'extraDashboardPaths' framework/catalog/grafana/module.nix && \
  grep -q '\.\./\.\./\.\./benchmarks/grafana/dashboard.json' site/nix/hosts/grafana.nix; then
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

# ----------------------------------------------------------------------
# G4B ratchets: dashboard structural validation (#285), label-filter
# coverage (#283), and Virtualization Tax join tightening (#284).
# ----------------------------------------------------------------------

# Static ratchet: dashboard.json declares a schemaVersion. Grafana uses
# schemaVersion to migrate dashboard payloads across releases; omitting it
# causes Grafana to import the dashboard with an implicit legacy version
# and silently drop fields that were added later. This ratchet catches
# accidental removal.
if jq -e '(.schemaVersion | type == "number") and (.schemaVersion >= 30)' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "dashboard.json declares a modern schemaVersion (>= 30)"
else
  fail "dashboard.json is missing schemaVersion or has an outdated version"
fi

# Static ratchet: dashboard.json has no duplicate panel IDs. Grafana
# indexes panels by ID for permalinks, dashboard-links, and alert rules;
# duplicates cause silent shadowing where one panel overwrites another
# on save. jq compares `length` of the raw ids array against `length`
# of the deduped array.
# Recursive descent: Grafana row panels can nest a `.panels[]` array of
# children, so a duplicate id between a top-level panel and a nested one
# would slip past a top-level-only check. gemini adversarial-review on
# MR !416.
if jq -e '
  ([.. | objects | .id? | numbers]) as $ids
  | ($ids | length) == ($ids | unique | length)
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "dashboard.json panel IDs are all unique (including any nested-row children)"
else
  fail "dashboard.json has duplicate panel IDs (Grafana will silently shadow one)"
fi

# Static ratchet: every panel has a numeric id, a title, a type, and at
# least one target. A panel without these is a Grafana import error or a
# blank tile. Catches accidental panel-tree corruption during hand edits.
if jq -e '
  # Assert .panels is a non-empty array first — a malformed shape that jq
  # can still iterate must not slip through. Then require id/title/type on
  # every panel, and require a non-empty .targets array on data panels.
  # Row and text panels are structural containers and legitimately have no
  # targets; exempt them so adding one later does not break the ratchet.
  # gemini + codex adversarial-review on MR !416.
  (.panels | type == "array" and length > 0) and
  (
    .panels
    | all(
        (.id | type == "number") and
        (.title | type == "string" and length > 0) and
        (.type  | type == "string" and length > 0) and
        (
          if (.type == "row" or .type == "text") then true
          else (.targets | type == "array" and length > 0)
          end
        )
      )
  )
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "dashboard panels array is populated; every data panel has id/title/type/targets"
else
  fail "dashboard panels array is malformed or a data panel is missing id/title/type/targets"
fi

# Static ratchet: the `label` template variable is defined. It scopes
# every time-series and stat panel to the run's environment label, so
# comparing (e.g.) a bare-metal host run to a nested-VM run does not
# average unrelated data.
if jq -e '.templating.list | map(.name) | index("label") != null' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "dashboard.json declares a label template variable"
else
  fail "dashboard.json is missing the label template variable"
fi

# Static ratchet (#553): the `label` template variable must NOT default
# to the wildcard escape hatch. With `includeAll:true, allValue:".*",
# current:{text:"All", value:".*"}`, a fresh view of the dashboard
# selects "All" — `r.label =~ /^${label}$/` expands to `/^.*$/`,
# matching every label and silently defeating the #283 per-label
# scoping added in MR !416.
#
# Path taken here: match the pre-existing virt_host / virt_host_label /
# virt_guest_label pattern in this same dashboard: empty current +
# includeAll:false + allValue:null. Grafana picks the first query
# result on load, so the default view is per-label meaningful.
#
# Kept-considered-but-rejected: empty current with includeAll:true
# would let Grafana's initialization code fall back to the topmost
# option, which is "All" when includeAll:true. Adversarial review
# (sub-claude on Batch C) flagged this as a silent-fix regression
# risk. The virt_* variables in the same file already use the
# `includeAll:false + empty current` pattern successfully, so this
# ratchet aligns the `label` variable with the codebase's existing
# working pattern.
#
# The ratchet asserts three properties, any one of which is
# sufficient to eliminate the bug: current.value != ".*",
# current.text != "All", and includeAll == false. All three must
# hold — a partial regression (e.g., someone re-enables includeAll
# without touching current) is caught.
if jq -e '
  .templating.list[]
  | select(.name == "label")
  | (.current.value != ".*")
    and (.current.text != "All")
    and (.includeAll == false)
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "label template variable default is not the .*/All wildcard (empty current + includeAll:false)"
else
  fail "label template variable default is the .*/All wildcard OR includeAll:true; a fresh dashboard view then averages every label, silently defeating the #283 per-label filter"
fi

# Static ratchet (#283): every panel that already filters by host must
# also filter by label. Without this, panels average measurements from
# different `label` values (e.g., mixing scratch-labeled runs into a
# rebuild-labeled dashboard cell), silently biasing the chart. Panel 6
# (Scratch Vs Rebuild Comparison) uses a standalone label filter line;
# the others must include the inline form
# `r.label =~ /^${label}$/` in the same filter() as the host predicate.
# Virtualization Tax (id 8) uses its own dedicated
# virt_host_label/virt_guest_label filters and is exempt from this
# ratchet.
# Dynamic: every panel whose Flux query references the `${host}` template
# variable MUST also reference `${label}`. Scales to newly-added panels
# without editing the ratchet, and correctly exempts panel 8 (which uses
# `${virt_host}` / `${virt_host_label}` / `${virt_guest_label}` — no
# literal `${host}` substring). Panel 6's standalone
# `|> filter(fn: (r) => r.label =~ /^${label}$/)` line is caught by
# `contains("${label}")`. gemini + codex + sub-claude adversarial-review
# on MR !416.
missing=$(jq -r '
  .panels[]
  | select((.targets // []) | length > 0)
  | select(((.targets[0].query // "") | contains("${host}")))
  | select(((.targets[0].query // "") | contains("${label}")) | not)
  | "\(.id) \(.title)"
' benchmarks/grafana/dashboard.json)
if [[ -z "${missing}" ]]; then
  pass "every panel that references \${host} also references \${label}"
else
  while IFS= read -r line; do
    fail "panel ${line} references \${host} but not \${label}"
  done <<< "${missing}"
fi

# Static ratchet (#284): the Virtualization Tax panel's host_series and
# guest_series each collapse to exactly one row per (threads, subtest)
# before the join. Without the extra
# `|> group(columns:["threads","subtest"]) |> last()` pair before rename,
# a template var that matches multiple hosts or labels (e.g. a
# guest_label shared across guests) leaves N > 1 rows on that side, and
# the join on ["threads","subtest"] Cartesian-multiplies the pairs — the
# stat reduction then picks an arbitrary host/guest match. The extra
# collapse forces a single well-defined pair per (threads, subtest).
#
# The check enforces, per side, that between the `keep(columns:...)` and
# `rename(...)` calls there is a `group(columns:["threads","subtest"])`
# followed by `last()`. That fragment is what turns an N-row-per-side
# situation into 1 row per (threads, subtest), guaranteeing the join is
# 1:1.
if jq -e '
  # Exact ordered block: the initial group+last on
  # (host,label,threads,subtest) is IMMEDIATELY followed by the collapse
  # group+last on (threads,subtest). Same 2-space indentation as the rest
  # of the panel query. Adjacency + order + _time-availability are all
  # enforced by matching the multi-line block verbatim.
  #
  # Placement rule: the ordered block must appear BEFORE the `|> keep(...)`
  # projection, because `keep(...)` drops `_time` and Flux `last()` needs
  # `_time` for deterministic row selection (gemini + codex + sub-claude
  # adversarial-review on MR !416).
  def side_ok:
    contains("|> group(columns:[\"host\",\"label\",\"threads\",\"subtest\"])\n  |> last()\n  |> group(columns:[\"threads\",\"subtest\"])\n  |> last()")
    and (
      split("|> group(columns:[\"threads\",\"subtest\"])\n  |> last()")[0]
      | contains("|> keep(columns:") | not
    );
  .panels[]
  | select(.title == "Virtualization Tax")
  | .targets[0].query
  | (split("host_series")[1] | split("guest_series")[0] | side_ok)
    and (split("guest_series")[1] | split("join")[0] | side_ok)
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Virtualization Tax runs an ordered group->last->group->last collapse before keep on each side"
else
  fail "Virtualization Tax is missing the per-side ordered collapse (or placed it after keep, which loses _time)"
fi

# Static ratchet (#554): Virtualization Tax must emit a single row for
# the stat panel regardless of the `threads` template variable. Without
# a final aggregation the map() output has one row per (threads, subtest)
# — with threads=All (allValue=".*") that's N rows, and Grafana's
# `lastNotNull` stat reduction then picks an arbitrary row to display as
# the single number. Collapsing to `|> group() |> mean(column: "_value")`
# after the join+map produces one deterministic row (mean of the joined
# taxes) regardless of viewer selection.
if jq -e '
  .panels[]
  | select(.title == "Virtualization Tax")
  | .targets[0].query
  | contains("|> group()\n  |> mean(column: \"_value\")")
' benchmarks/grafana/dashboard.json >/dev/null; then
  pass "Virtualization Tax aggregates to a single deterministic row (group() + mean on _value)"
else
  fail "Virtualization Tax must end its query with '|> group() |> mean(column: \"_value\")' so threads=All does not leave the stat picking an arbitrary row"
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

# Static ratchet (#555): hyperfine command strings must single-quote
# ${SCRIPT_DIR}/run-target.sh so the child shell that hyperfine spawns
# tokenizes the path as a single argument even when SCRIPT_DIR contains
# spaces. Without the single quotes, a path like "/path with spaces/..."
# is re-split by `sh -c` into three args. Check both the --prepare arg
# and the trailing measure command.
if grep -qE "^[[:space:]]*--prepare[[:space:]]+\"'\\\$\{SCRIPT_DIR\}/run-target\.sh'" benchmarks/application/run-target.sh \
   && grep -qE "^[[:space:]]+\"'\\\$\{SCRIPT_DIR\}/run-target\.sh'[[:space:]]+--internal-measure" benchmarks/application/run-target.sh; then
  pass "run-target.sh single-quotes \${SCRIPT_DIR}/run-target.sh in both hyperfine --prepare and measure argv"
else
  fail "run-target.sh hyperfine command strings must single-quote \${SCRIPT_DIR}/run-target.sh so a path with spaces survives sh -c splitting"
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

# ----------------------------------------------------------------------
# benchmarks/application/run-target.sh: top-level hyperfine wiring (#263)
# ----------------------------------------------------------------------
# Coverage above exercises --internal-prepare / --internal-measure paths.
# The top-level orchestration (L173-178 of run-target.sh) invokes
# hyperfine with --runs / --warmup / --prepare / --export-json / measure
# argv. If that argv is ever re-shuffled — e.g., --prepare's inner script
# path drifts from run-target.sh's SCRIPT_DIR — the whole benchmark
# silently reports 0-run "success" or errors deep inside hyperfine.
# Shim hyperfine so we can assert the exact argv construction.

HYPERFINE_WIRING_DIR="${TMP_DIR}/run-target-hyperfine-wiring"
HYPERFINE_LOG="${HYPERFINE_WIRING_DIR}/hyperfine-invocations.log"
mkdir -p "${HYPERFINE_WIRING_DIR}/bin"

# Nix shim (needed for require_command nix + BENCH_TEST_SKIP_CACHE_DROP=1
# means the shim won't be reached inside prepare/measure — but nix must
# be on PATH for the pre-hyperfine `require_command nix` check).
cat > "${HYPERFINE_WIRING_DIR}/bin/nix" <<'NIX_STUB'
#!/usr/bin/env bash
# Never reached in wiring test — hyperfine is shimmed and doesn't
# actually exec --prepare or measure. Present only to satisfy
# `require_command nix` in run-target.sh.
exit 0
NIX_STUB
chmod +x "${HYPERFINE_WIRING_DIR}/bin/nix"

# hyperfine shim — records full argv, writes a minimal but valid
# hyperfine JSON at --export-json so the downstream jq call succeeds.
cat > "${HYPERFINE_WIRING_DIR}/bin/hyperfine" <<'HF_STUB'
#!/usr/bin/env bash
set -euo pipefail
export_json=""
# Log argv one arg per line so quoted strings with spaces survive the
# round-trip (unlike a flat $* dump which collapses them).
{
  printf 'ARGC=%d\n' "$#"
  i=1
  for arg in "$@"; do
    printf 'ARGV[%d]=%s\n' "$i" "$arg"
    i=$((i + 1))
  done
} >> "${HYPERFINE_LOG}"
# Parse --export-json <path> so we can populate it
while [[ $# -gt 0 ]]; do
  case "$1" in
    --export-json)
      shift
      export_json="${1:-}"
      ;;
  esac
  shift 2>/dev/null || true
done
# hyperfine JSON minimum shape jq expects: { "results": [ ... ] }
if [[ -n "${export_json}" ]]; then
  printf '%s\n' '{"results":[{"command":"stub","mean":0.1,"stddev":0.0,"median":0.1,"min":0.1,"max":0.1,"times":[0.1]}]}' \
    > "${export_json}"
fi
exit 0
HF_STUB
chmod +x "${HYPERFINE_WIRING_DIR}/bin/hyperfine"

run_hyperfine_wiring() {
  local mode="$1" target="$2" runs="$3"
  : > "${HYPERFINE_LOG}"
  HYPERFINE_LOG="${HYPERFINE_LOG}" \
    PATH="${HYPERFINE_WIRING_DIR}/bin:${PATH}" \
    BENCH_UNAME_S=Linux \
    BENCH_TEST_SKIP_CACHE_DROP=1 \
    ./benchmarks/application/run-target.sh \
      --mode "${mode}" \
      --target "${target}" \
      --runs "${runs}" \
      --output "${HYPERFINE_WIRING_DIR}/out-${mode}.json"
}

RUN_TARGET_ABS_PATH="$(cd benchmarks/application && pwd)/run-target.sh"

# --- scratch mode wiring ---
run_hyperfine_wiring scratch bench-fake 5
if grep -qxF 'ARGV[1]=--runs' "${HYPERFINE_LOG}" \
   && grep -qxF 'ARGV[2]=5' "${HYPERFINE_LOG}" \
   && grep -qxF 'ARGV[3]=--warmup' "${HYPERFINE_LOG}" \
   && grep -qxF 'ARGV[4]=1' "${HYPERFINE_LOG}" \
   && grep -qxF 'ARGV[5]=--prepare' "${HYPERFINE_LOG}" \
   && grep -qxF "ARGV[6]='${RUN_TARGET_ABS_PATH}' --internal-prepare scratch bench-fake" "${HYPERFINE_LOG}" \
   && grep -qxF 'ARGV[7]=--export-json' "${HYPERFINE_LOG}" \
   && grep -qxF "ARGV[9]='${RUN_TARGET_ABS_PATH}' --internal-measure scratch bench-fake" "${HYPERFINE_LOG}"; then
  pass "run-target.sh top-level hyperfine wiring: scratch mode argv is correct"
else
  fail "run-target.sh top-level hyperfine wiring is wrong for scratch: $(cat "${HYPERFINE_LOG}")"
fi

# --- rebuild mode wiring ---
run_hyperfine_wiring rebuild bench-fake 3
if grep -qxF 'ARGV[2]=3' "${HYPERFINE_LOG}" \
   && grep -qxF "ARGV[6]='${RUN_TARGET_ABS_PATH}' --internal-prepare rebuild bench-fake" "${HYPERFINE_LOG}" \
   && grep -qxF "ARGV[9]='${RUN_TARGET_ABS_PATH}' --internal-measure rebuild bench-fake" "${HYPERFINE_LOG}"; then
  pass "run-target.sh top-level hyperfine wiring: rebuild mode argv threads --mode/--target through"
else
  fail "run-target.sh rebuild mode wiring wrong: $(cat "${HYPERFINE_LOG}")"
fi

# --- ARGC sanity: exactly 9 args (no rogue extras from a future edit) ---
if grep -qxF 'ARGC=9' "${HYPERFINE_LOG}"; then
  pass "run-target.sh top-level hyperfine wiring: exactly 9 argv (no accidental extras)"
else
  fail "run-target.sh hyperfine ARGC != 9: $(grep '^ARGC=' "${HYPERFINE_LOG}")"
fi

# ----------------------------------------------------------------------
# benchmarks/run-on-host.sh: EXIT trap remote cleanup on failure (#273)
# ----------------------------------------------------------------------
# The EXIT trap at ~L202-208 SSHes to the remote to `rm -rf` the staging
# dir on both success AND failure. Without it, a bench.sh crash leaves
# /tmp/benchmarks-${LABEL}/ with partial results, and the NEXT rsync
# preserves that partial subtree, at which point bench.sh's
# "refusing to overwrite" halts the whole pipeline.
#
# Verify: when the remote bench.sh fails, run-on-host.sh still fires the
# EXIT trap's `rm -rf` ssh, using `ssh -n` (defense-in-depth per #329).
TRAP_FIXTURE_DIR="${TMP_DIR}/run-on-host-trap"
TRAP_SHIMS="${TMP_DIR}/run-on-host-trap-shims"
TRAP_SSH_LOG="${TMP_DIR}/run-on-host-trap-ssh.log"
mkdir -p "${TRAP_SHIMS}"
cp -R benchmarks "${TRAP_FIXTURE_DIR}"

# rsync shim: no-op, just records that it ran.
cat > "${TRAP_SHIMS}/rsync" <<'RS'
#!/usr/bin/env bash
# quiet no-op — the failure surfaces from the ssh shim below, not rsync
last_arg=""
for arg in "$@"; do last_arg="${arg}"; done
# Emulate rsync's post-pull side effect: create env.json so the
# "results are incomplete" die does not fire before the trap runs.
if [[ "${last_arg}" != *:* ]]; then
  mkdir -p "${last_arg%/}"
  printf '{"label":"trap-fixture"}\n' > "${last_arg%/}/env.json"
fi
RS

# ssh shim: nix probe succeeds (only relevant to --full, which we
# don't pass); bench.sh call fails (exit 1); cleanup rm -rf must
# succeed AND must be recorded with `-n` present.
cat > "${TRAP_SHIMS}/ssh" <<'SSH_STUB'
#!/usr/bin/env bash
set -euo pipefail
# Log full argv, one arg per line, for the trap-cleanup assertion.
{
  printf 'CALL: %d\n' "$#"
  for arg in "$@"; do printf 'ARG=%s\n' "$arg"; done
  printf '---\n'
} >> "${TRAP_SSH_LOG}"

# Reconstruct joined argv for pattern matching (compat with pre-existing
# ssh shims in this file that use $*).
joined="$*"

if [[ "$joined" == *"command -v nix"* ]]; then
  # nix probe: succeed silently
  exit 0
fi

if [[ "$joined" == *"./bench.sh "* ]]; then
  # The bench.sh invocation — simulate a crash on the remote.
  exit 1
fi

if [[ "$joined" == *"rm -rf -- "* ]]; then
  # The EXIT trap's cleanup call — succeed silently.
  exit 0
fi

printf 'unexpected ssh invocation: %s\n' "$joined" >&2
exit 2
SSH_STUB

chmod +x "${TRAP_SHIMS}/rsync" "${TRAP_SHIMS}/ssh"

set +e
TRAP_SSH_LOG="${TRAP_SSH_LOG}" \
  PATH="${TRAP_SHIMS}:${PATH}" \
  "${TRAP_FIXTURE_DIR}/run-on-host.sh" 192.0.2.99 trap-fixture \
  >/tmp/run-on-host-trap.out 2>&1
TRAP_RC=$?
set -e

if [[ "${TRAP_RC}" -eq 0 ]]; then
  fail "run-on-host.sh should have propagated the remote bench.sh failure (got rc=0)"
else
  pass "run-on-host.sh propagates the remote bench.sh non-zero exit"
fi

# The EXIT trap must have invoked the cleanup ssh with `-n` AND rm -rf
# targeting the EXACT remote staging dir. Walk each CALL block and
# assert at least one had -n and an rm -rf whose argument is
# /tmp/benchmarks-trap-fixture (not "some path", so a regression that
# rm -rf's the wrong path also fails this test).
EXPECTED_STAGING="/tmp/benchmarks-trap-fixture"
if awk -v expected="ARG=rm -rf -- \"${EXPECTED_STAGING}\"" '
  function check_call() {
    if (in_call && has_n && has_rm) { found = 1 }
    in_call = 0; has_n = 0; has_rm = 0
  }
  /^CALL:/ { check_call(); in_call = 1; next }
  in_call && $0 == "ARG=-n" { has_n = 1 }
  in_call && $0 == expected { has_rm = 1 }
  END { check_call(); if (!found) exit 1 }
' "${TRAP_SSH_LOG}"; then
  pass "run-on-host.sh EXIT trap fires a cleanup ssh -n with rm -rf on failure"
else
  fail "run-on-host.sh EXIT trap did NOT fire the cleanup ssh with -n and rm -rf: $(cat "${TRAP_SSH_LOG}")"
fi

# ----------------------------------------------------------------------
# benchmarks/run-scheduled-bench.sh: fail-closed on host-loop short count (#330)
# ----------------------------------------------------------------------
# Pipeline 922 silently dropped 2 of 3 hosts and reported status=ok
# because the pre-#330 classifier only checked hosts_failed. The
# fail-closed guard treats hosts_processed != hosts_total as `partial`
# with a non-zero exit — which the CI dashboard surfaces.
#
# Simulate the short-count path by patching a fixture copy of
# run-scheduled-bench.sh to skip the run-on-host call for one host,
# incrementing neither hosts_ok nor hosts_failed. This is the exact
# failure mode #330 was filed against (the historical incident is
# consumed-stdin from a nested ssh; the newer guard catches ANY
# short-count regardless of cause).

SCHED_FIXTURE_DIR="${TMP_DIR}/run-scheduled-bench-fixture"
SCHED_STATUS_ROOT="${TMP_DIR}/run-scheduled-bench-status"
mkdir -p "${SCHED_FIXTURE_DIR}/site"
cp -R benchmarks "${SCHED_FIXTURE_DIR}/benchmarks"
printf 'test-epoch\n' > "${SCHED_FIXTURE_DIR}/benchmarks/epoch.conf"

cat > "${SCHED_FIXTURE_DIR}/site/config.yaml" <<'EOF_CFG'
timezone: UTC
benchmarks:
  scheduled:
    enabled: true
    label: scheduled
    suite: synthetic
    host_timeout_sec: 60
    hosts:
      - pve01
      - pve02
      - pve03
EOF_CFG

# Stub RUN_ON_HOST_BIN to record ok for the first host, "silently skip"
# the second (increment neither counter), and record ok for the third.
# This directly simulates the pipeline 922 pattern: hosts_processed <
# hosts_total but hosts_failed == 0.
SCHED_RUN_ON_HOST="${SCHED_FIXTURE_DIR}/fake-run-on-host.sh"
cat > "${SCHED_RUN_ON_HOST}" <<'RUN_STUB'
#!/usr/bin/env bash
# The stub is invoked by run-scheduled-bench.sh's host loop.
# Args: $1=host, $2=label, then flags.
# Record the invocation; behavior varies by host.
host="$1"
case "${host}" in
  pve02)
    # simulate a silent drop: exit 0 as ok BUT set an env var so the
    # patched run-scheduled-bench SKIPS incrementing counters for this
    # host. See fixture patch below.
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
RUN_STUB
chmod +x "${SCHED_RUN_ON_HOST}"

# Patch a copy of run-scheduled-bench.sh so that pve02 goes through
# a code path that increments NEITHER hosts_ok NOR hosts_failed —
# a synthetic reproduction of the pipeline 922 silent-drop. The real
# fix (fail-closed classifier) is unchanged; the patch only bypasses
# counter updates to reach the classifier from a short-count state.
#
# ANCHOR NOTE: the python `assert old in src` below is intentionally
# strict. If a future refactor renames variables or reshapes the
# counter-increment block in run-scheduled-bench.sh (e.g., factoring
# into an update_host_status() helper), this test's setup will fail
# loudly during `python3 <<PY_PATCH`. To recover: (a) update the
# `old` string to match the new source, keeping the semantic — bypass
# counter increments for BENCH_SCHEDULE_SILENT_DROP_HOST — intact;
# or (b) redesign the fixture so run-scheduled-bench.sh accepts a
# directly-mockable classifier hook and drop the source patch entirely.
SCHED_FIXTURE="${SCHED_FIXTURE_DIR}/benchmarks/run-scheduled-bench.sh"

python3 <<PY_PATCH
import re
p = "${SCHED_FIXTURE}"
with open(p) as f: src = f.read()
old = '''  if [[ "\$host_rc" -eq 0 ]]; then
    hosts_ok=\$((hosts_ok + 1))
    host_status=ok
    log "\${host}: scheduled benchmark ok"
  else
    hosts_failed=\$((hosts_failed + 1))
    host_status=failed
    log "\${host}: scheduled benchmark failed"
  fi'''
new = '''  if [[ "\${host}" == "\${BENCH_SCHEDULE_SILENT_DROP_HOST:-}" ]]; then
    # Fixture-only: simulate the pipeline 922 silent-drop path.
    host_status=dropped
    log "\${host}: scheduled benchmark silently dropped (fixture)"
  elif [[ "\$host_rc" -eq 0 ]]; then
    hosts_ok=\$((hosts_ok + 1))
    host_status=ok
    log "\${host}: scheduled benchmark ok"
  else
    hosts_failed=\$((hosts_failed + 1))
    host_status=failed
    log "\${host}: scheduled benchmark failed"
  fi'''
assert old in src, "sched fixture: counter-increment anchor not found"
src = src.replace(old, new, 1)
with open(p, "w") as f: f.write(src)
PY_PATCH

# Runner-contention: run-scheduled-bench.sh sources
# benchmarks/lib/runner-contention.sh (line ~9) which defines
# gitlab_active_non_self_pipelines_json. Replace the library file in
# the fixture copy with a zero-contention stub so the fixture bypass
# survives the re-source (a preload + export -f is defeated by it).
# Fixture-only, mirroring other library-swap patterns in this file.
cat > "${SCHED_FIXTURE_DIR}/benchmarks/lib/runner-contention.sh" <<'RC_STUB'
#!/usr/bin/env bash
# Fixture stub for #330 test — always report zero-contention.
gitlab_active_non_self_pipelines_json() {
  printf '%s\n' '{"count":0}'
}
RC_STUB

set +e
BENCH_CONFIG_FILE="${SCHED_FIXTURE_DIR}/site/config.yaml" \
  BENCH_RUN_ON_HOST_BIN="${SCHED_RUN_ON_HOST}" \
  BENCH_SCHEDULE_STATUS_ROOT="${SCHED_STATUS_ROOT}" \
  BENCH_SCHEDULE_RUN_ID=sched-330-test \
  BENCH_SCHEDULE_LOCKFILE="${TMP_DIR}/sched-330.lock" \
  BENCH_SCHEDULE_KEEP_RUN_DIR=1 \
  BENCH_SCHEDULE_SILENT_DROP_HOST=pve02 \
  bash "${SCHED_FIXTURE}" \
  >/tmp/sched-330.out 2>&1
SCHED_RC=$?
set -e

if [[ "${SCHED_RC}" -eq 0 ]]; then
  fail "run-scheduled-bench.sh short-count case should have exited non-zero (fail-closed); got rc=0. log: $(cat /tmp/sched-330.out)"
else
  pass "run-scheduled-bench.sh short-count case exits non-zero (fail-closed guard)"
fi

if [[ -f "${SCHED_STATUS_ROOT}/status.json" ]] \
   && jq -e '.status == "partial"' "${SCHED_STATUS_ROOT}/status.json" >/dev/null; then
  pass "run-scheduled-bench.sh short-count case marks status=partial (not ok)"
else
  fail "run-scheduled-bench.sh short-count case did not mark status=partial: $(cat "${SCHED_STATUS_ROOT}/status.json" 2>/dev/null || echo missing)"
fi

# Positive control: a full 3-of-3 pass (no silent drop) must still be ok.
set +e
BENCH_CONFIG_FILE="${SCHED_FIXTURE_DIR}/site/config.yaml" \
  BENCH_RUN_ON_HOST_BIN="${SCHED_RUN_ON_HOST}" \
  BENCH_SCHEDULE_STATUS_ROOT="${SCHED_STATUS_ROOT}" \
  BENCH_SCHEDULE_RUN_ID=sched-330-test-ok \
  BENCH_SCHEDULE_LOCKFILE="${TMP_DIR}/sched-330-ok.lock" \
  BENCH_SCHEDULE_KEEP_RUN_DIR=1 \
  bash "${SCHED_FIXTURE}" \
  >/tmp/sched-330-ok.out 2>&1
SCHED_OK_RC=$?
set -e
if [[ "${SCHED_OK_RC}" -eq 0 ]] \
   && [[ -f "${SCHED_STATUS_ROOT}/status.json" ]] \
   && jq -e '.status == "ok"' "${SCHED_STATUS_ROOT}/status.json" >/dev/null; then
  pass "run-scheduled-bench.sh happy path (3/3 ok) still reports status=ok (no false-positive from #330 guard)"
else
  fail "run-scheduled-bench.sh 3/3 ok case regressed: rc=${SCHED_OK_RC}, status=$(cat "${SCHED_STATUS_ROOT}/status.json" 2>/dev/null)"
fi
