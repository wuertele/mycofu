#!/usr/bin/env bash
# test_metrics_dual_target.sh — Verify configure-metrics.sh dual-target behavior.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

setup_fixture_repo() {
  local repo_dir="$1"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/site/apps/influxdb" \
    "${repo_dir}/site/sops"

  cp "${REPO_ROOT}/framework/scripts/configure-metrics.sh" "${repo_dir}/framework/scripts/configure-metrics.sh"

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
cicd:
  project_name: mycofu
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications:
  influxdb:
    enabled: true
    proxmox_metrics: true
    health_port: 8086
    environments:
      prod:
        ip: 172.27.10.55
      dev:
        ip: 172.27.60.55
EOF

  cat > "${repo_dir}/site/apps/influxdb/setup.json" <<'EOF'
{
  "org": "homelab",
  "bucket": "default"
}
EOF

  printf 'dummy: value\n' > "${repo_dir}/site/sops/secrets.yaml"
}

setup_shims() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'test-token\n'
EOF
  chmod +x "${shim_dir}/sops"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"
remote_cmd="${remote_cmd//$'\n'/ }"
remote_cmd="$(printf '%s' "${remote_cmd}" | tr -s ' ')"
state_dir="${STUB_METRICS_STATE_DIR}"
log_file="${STUB_METRICS_LOG}"
mkdir -p "${state_dir}"

suppress_output=0
if [[ "${remote_cmd}" == *">/dev/null"* ]]; then
  suppress_output=1
fi

extract_flag() {
  local flag="$1"
  local cmd="$2"
  printf '%s\n' "${cmd}" | sed -n "s/.*${flag} \\([^ ]*\\).*/\\1/p"
}

write_server_json() {
  local path="$1"
  local name="$2"
  local server="$3"
  local port="$4"
  local bucket="$5"
  local org="$6"
  local proto="$7"
  local verify="$8"

  python3 - "${path}" "${name}" "${server}" "${port}" "${bucket}" "${org}" "${proto}" "${verify}" <<'PY'
import json
import sys

path, name, server, port, bucket, org, proto, verify = sys.argv[1:]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(
        {
            "name": name,
            "server": server,
            "port": int(port),
            "bucket": bucket,
            "organization": org,
            "influxdbproto": proto,
            "verify-certificate": int(verify),
        },
        fh,
    )
PY
}

if [[ "${remote_cmd}" == *"curl -sk"*"/health"* ]]; then
  printf '{"status":"pass"}\n'
  exit 0
fi

if [[ "${remote_cmd}" =~ pvesh[[:space:]]+get[[:space:]]+/cluster/metrics/server[[:space:]]+--output-format[[:space:]]+json ]]; then
  python3 - "${state_dir}" <<'PY'
import json
import os
import sys

state_dir = sys.argv[1]
servers = []
for entry in sorted(os.listdir(state_dir)):
    if not entry.endswith(".json"):
        continue
    with open(os.path.join(state_dir, entry), "r", encoding="utf-8") as fh:
        servers.append(json.load(fh))
json.dump(servers, sys.stdout)
PY
  exit 0
fi

if [[ "${remote_cmd}" =~ pvesh[[:space:]]+get[[:space:]]+/cluster/metrics/server/([^[:space:]]+) ]]; then
  name="${BASH_REMATCH[1]}"
  path="${state_dir}/${name}.json"
  if [[ -f "${path}" ]]; then
    if [[ "${suppress_output}" -eq 0 ]]; then
      cat "${path}"
    fi
    exit 0
  fi
  exit 1
fi

if [[ "${remote_cmd}" =~ pvesh[[:space:]]+create[[:space:]]+/cluster/metrics/server/([^[:space:]]+) ]]; then
  name="${BASH_REMATCH[1]}"
  server="$(extract_flag --server "${remote_cmd}")"
  port="$(extract_flag --port "${remote_cmd}")"
  bucket="$(extract_flag --bucket "${remote_cmd}")"
  org="$(extract_flag --organization "${remote_cmd}")"
  proto="$(extract_flag --influxdbproto "${remote_cmd}")"
  verify="$(extract_flag --verify-certificate "${remote_cmd}")"
  write_server_json "${state_dir}/${name}.json" "${name}" "${server}" "${port}" "${bucket}" "${org}" "${proto}" "${verify}"
  printf 'create %s\n' "${name}" >> "${log_file}"
  exit 0
fi

if [[ "${remote_cmd}" =~ pvesh[[:space:]]+set[[:space:]]+/cluster/metrics/server/([^[:space:]]+) ]]; then
  name="${BASH_REMATCH[1]}"
  server="$(extract_flag --server "${remote_cmd}")"
  port="$(extract_flag --port "${remote_cmd}")"
  bucket="$(extract_flag --bucket "${remote_cmd}")"
  org="$(extract_flag --organization "${remote_cmd}")"
  proto="$(extract_flag --influxdbproto "${remote_cmd}")"
  verify="$(extract_flag --verify-certificate "${remote_cmd}")"
  write_server_json "${state_dir}/${name}.json" "${name}" "${server}" "${port}" "${bucket}" "${org}" "${proto}" "${verify}"
  printf 'set %s\n' "${name}" >> "${log_file}"
  exit 0
fi

if [[ "${remote_cmd}" =~ pvesh[[:space:]]+delete[[:space:]]+/cluster/metrics/server/([^[:space:]]+) ]]; then
  name="${BASH_REMATCH[1]}"
  rm -f "${state_dir}/${name}.json"
  printf 'delete %s\n' "${name}" >> "${log_file}"
  exit 0
fi

printf 'unexpected ssh command: %s\n' "${remote_cmd}" >&2
exit 1
EOF
  chmod +x "${shim_dir}/ssh"
}

seed_metric_server() {
  local state_dir="$1"
  local name="$2"
  local server="$3"

  mkdir -p "${state_dir}"
  python3 - "${state_dir}/${name}.json" "${name}" "${server}" <<'PY'
import json
import sys

path, name, server = sys.argv[1:]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(
        {
            "name": name,
            "server": server,
            "port": 8086,
            "bucket": "default",
            "organization": "homelab",
            "influxdbproto": "https",
            "verify-certificate": 0,
        },
        fh,
    )
PY
}

run_fixture() {
  local scenario="$1"
  local repo_dir="${TMP_DIR}/${scenario}-repo"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local state_dir="${TMP_DIR}/${scenario}-state"
  local log_file="${TMP_DIR}/${scenario}.log"
  local output_file="${TMP_DIR}/${scenario}.out"

  setup_fixture_repo "${repo_dir}"
  setup_shims "${shim_dir}"
  mkdir -p "${state_dir}"
  : > "${log_file}"

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_METRICS_STATE_DIR="${state_dir}"
    export STUB_METRICS_LOG="${log_file}"
    cd "${repo_dir}"
    framework/scripts/configure-metrics.sh
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n%s\n%s\n' "${status}" "${repo_dir}" "${state_dir}" "${log_file}"
}

read_run_result() {
  local run_output="$1"
  local __status_var="$2"
  local __repo_var="$3"
  local __state_var="$4"
  local __log_var="$5"

  local status repo_dir state_dir log_file
  status="$(printf '%s\n' "${run_output}" | sed -n '1p')"
  repo_dir="$(printf '%s\n' "${run_output}" | sed -n '2p')"
  state_dir="$(printf '%s\n' "${run_output}" | sed -n '3p')"
  log_file="$(printf '%s\n' "${run_output}" | sed -n '4p')"

  printf -v "${__status_var}" '%s' "${status}"
  printf -v "${__repo_var}" '%s' "${repo_dir}"
  printf -v "${__state_var}" '%s' "${state_dir}"
  printf -v "${__log_var}" '%s' "${log_file}"
}

test_start "22.0" "configure-metrics.sh stays executable for direct converge-lib invocation"
if [[ -x "${REPO_ROOT}/framework/scripts/configure-metrics.sh" ]]; then
  test_pass "configure-metrics.sh is executable"
else
  test_fail "configure-metrics.sh is not executable"
fi

test_start "22.1" "configure-metrics.sh creates dual targets and removes the legacy single-target entry"
RUN_OUTPUT="$(run_fixture create-dual)"
read_run_result "${RUN_OUTPUT}" STATUS REPO_DIR STATE_DIR LOG_FILE
seed_metric_server "${STATE_DIR}" "mycofu" "172.27.10.55"

set +e
(
  export PATH="${TMP_DIR}/create-dual-shims:${PATH}"
  export STUB_METRICS_STATE_DIR="${STATE_DIR}"
  export STUB_METRICS_LOG="${LOG_FILE}"
  cd "${REPO_DIR}"
  framework/scripts/configure-metrics.sh
) > "${TMP_DIR}/create-dual-second.out" 2>&1
STATUS=$?
set -e

if [[ "${STATUS}" -eq 0 ]]; then
  test_pass "configure-metrics.sh exits 0 for dual-target creation"
else
  test_fail "configure-metrics.sh exits 0 for dual-target creation"
fi

if [[ -f "${STATE_DIR}/influxdb-prod.json" && -f "${STATE_DIR}/influxdb-dev.json" ]]; then
  test_pass "dual metric server entries are created"
else
  test_fail "dual metric server entries are created"
fi

if [[ ! -f "${STATE_DIR}/mycofu.json" ]]; then
  test_pass "legacy single-target metric server is removed"
else
  test_fail "legacy single-target metric server is removed"
fi

if grep -qx 'create influxdb-prod' "${LOG_FILE}" && \
   grep -qx 'create influxdb-dev' "${LOG_FILE}" && \
   grep -qx 'delete mycofu' "${LOG_FILE}"; then
  test_pass "create/delete operations target the expected metric server names"
else
  test_fail "create/delete operations target the expected metric server names"
fi

test_start "22.2" "configure-metrics.sh is idempotent when both targets already match"
IDEMP_OUTPUT="$(run_fixture idempotent)"
read_run_result "${IDEMP_OUTPUT}" STATUS REPO_DIR STATE_DIR LOG_FILE
seed_metric_server "${STATE_DIR}" "influxdb-prod" "172.27.10.55"
seed_metric_server "${STATE_DIR}" "influxdb-dev" "172.27.60.55"
: > "${LOG_FILE}"

set +e
(
  export PATH="${TMP_DIR}/idempotent-shims:${PATH}"
  export STUB_METRICS_STATE_DIR="${STATE_DIR}"
  export STUB_METRICS_LOG="${LOG_FILE}"
  cd "${REPO_DIR}"
  framework/scripts/configure-metrics.sh
) > "${TMP_DIR}/idempotent.out" 2>&1
STATUS=$?
set -e

if [[ "${STATUS}" -eq 0 ]]; then
  test_pass "configure-metrics.sh exits 0 for idempotent rerun"
else
  test_fail "configure-metrics.sh exits 0 for idempotent rerun"
fi

if [[ ! -s "${LOG_FILE}" ]]; then
  test_pass "idempotent rerun makes no create/set/delete changes"
else
  test_fail "idempotent rerun makes no create/set/delete changes"
fi

test_start "22.3" "configure-metrics.sh updates drifted targets in place"
UPDATE_OUTPUT="$(run_fixture update-drift)"
read_run_result "${UPDATE_OUTPUT}" STATUS REPO_DIR STATE_DIR LOG_FILE
seed_metric_server "${STATE_DIR}" "influxdb-prod" "172.27.10.55"
seed_metric_server "${STATE_DIR}" "influxdb-dev" "172.27.60.99"
: > "${LOG_FILE}"

set +e
(
  export PATH="${TMP_DIR}/update-drift-shims:${PATH}"
  export STUB_METRICS_STATE_DIR="${STATE_DIR}"
  export STUB_METRICS_LOG="${LOG_FILE}"
  cd "${REPO_DIR}"
  framework/scripts/configure-metrics.sh
) > "${TMP_DIR}/update-drift.out" 2>&1
STATUS=$?
set -e

if [[ "${STATUS}" -eq 0 ]]; then
  test_pass "configure-metrics.sh exits 0 for drift repair"
else
  test_fail "configure-metrics.sh exits 0 for drift repair"
fi

if grep -qx 'set influxdb-dev' "${LOG_FILE}" && ! grep -q '^create ' "${LOG_FILE}"; then
  test_pass "drifted target is updated in place"
else
  test_fail "drifted target is updated in place"
fi

if python3 - "${STATE_DIR}/influxdb-dev.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    server = json.load(fh)["server"]
raise SystemExit(0 if server == "172.27.60.55" else 1)
PY
then
  test_pass "drift repair writes the expected dev target IP"
else
  test_fail "drift repair writes the expected dev target IP"
fi

runner_summary
