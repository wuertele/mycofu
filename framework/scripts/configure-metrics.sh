#!/usr/bin/env bash
# configure-metrics.sh — Configure Proxmox to send metrics to InfluxDB.
#
# Reads InfluxDB targets from site/applications.yaml and manages named
# Proxmox metric server entries via pvesh. This updates cluster-wide state
# in Proxmox's pmxcfs and never writes /etc/pve/status.cfg directly.
#
# Usage:
#   framework/scripts/configure-metrics.sh
#
# Prerequisites:
#   - At least one Proxmox node reachable via SSH
#   - InfluxDB application with enabled: true and proxmox_metrics: true
#   - InfluxDB admin token in SOPS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
SETUP_JSON="${REPO_DIR}/site/apps/influxdb/setup.json"

SSH_OPTS="-n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

METRICS_APP=$(
  yq -r '
    .applications // {}
    | to_entries[]
    | select(.value.enabled == true and .value.proxmox_metrics == true)
    | .key
  ' "${APPS_CONFIG}" | head -1
)

if [[ -z "${METRICS_APP}" ]]; then
  echo "No enabled application has proxmox_metrics: true — skipping metrics configuration"
  exit 0
fi

INFLUXDB_PORT=$(yq -r ".applications.${METRICS_APP}.health_port // \"\"" "${APPS_CONFIG}")
if [[ -z "${INFLUXDB_PORT}" ]]; then
  echo "ERROR: ${METRICS_APP}.health_port is not set in ${APPS_CONFIG}" >&2
  exit 1
fi

if [[ ! -f "${SETUP_JSON}" ]]; then
  echo "ERROR: ${SETUP_JSON} not found" >&2
  exit 1
fi

INFLUXDB_ORG=$(python3 -c "import json; print(json.load(open('${SETUP_JSON}'))['org'])")
INFLUXDB_BUCKET=$(python3 -c "import json; print(json.load(open('${SETUP_JSON}'))['bucket'])")
INFLUXDB_TOKEN=$(sops -d --extract '["influxdb_admin_token"]' "${REPO_DIR}/site/sops/secrets.yaml")

FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "${CONFIG}")
LEGACY_METRIC_NAME=$(yq -r '.cicd.project_name // ""' "${CONFIG}")

TARGETS=()
for env in prod dev; do
  target_ip=$(yq -r ".applications.${METRICS_APP}.environments.${env}.ip // \"\"" "${APPS_CONFIG}")
  if [[ -n "${target_ip}" && "${target_ip}" != "null" ]]; then
    TARGETS+=("${env}:${target_ip}")
  fi
done

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "ERROR: ${METRICS_APP} has proxmox_metrics: true but no environment IPs to target" >&2
  exit 1
fi

ssh_first_node() {
  local remote_cmd="$1"
  ssh ${SSH_OPTS} "root@${FIRST_NODE_IP}" "${remote_cmd}"
}

target_healthy() {
  local target_ip="$1"
  ssh_first_node "curl -sk --connect-timeout 5 https://${target_ip}:${INFLUXDB_PORT}/health" \
    | grep -q '"status"'
}

metric_server_matches() {
  local server_json="$1"
  local expected_ip="$2"

  printf '%s' "${server_json}" | python3 -c '
import json
import sys

cfg = json.load(sys.stdin)
expected_server, expected_port, expected_bucket, expected_org = sys.argv[1:5]
verify = str(cfg.get("verify-certificate", cfg.get("verify_certificate", ""))).lower()

matches = (
    cfg.get("server") == expected_server
    and str(cfg.get("port", "")) == expected_port
    and cfg.get("bucket") == expected_bucket
    and cfg.get("organization") == expected_org
    and cfg.get("influxdbproto") == "https"
    and verify in {"0", "false"}
)

raise SystemExit(0 if matches else 1)
' "${expected_ip}" "${INFLUXDB_PORT}" "${INFLUXDB_BUCKET}" "${INFLUXDB_ORG}"
}

ensure_metric_server() {
  local metric_name="$1"
  local target_ip="$2"

  echo "Configuring Proxmox metrics -> ${metric_name} (${target_ip}:${INFLUXDB_PORT})"

  if target_healthy "${target_ip}"; then
    echo "  Target is reachable from ${FIRST_NODE_IP}"
  else
    echo "ERROR: ${metric_name} target ${target_ip}:${INFLUXDB_PORT} is not reachable from ${FIRST_NODE_IP}" >&2
    exit 1
  fi

  local existing_server
  existing_server="$(ssh_first_node "pvesh get /cluster/metrics/server/${metric_name} --output-format json" 2>/dev/null || true)"

  if [[ -n "${existing_server}" ]]; then
    if metric_server_matches "${existing_server}" "${target_ip}"; then
      echo "  ${metric_name}: already configured correctly"
      return
    fi

    echo "  ${metric_name}: updating existing entry"
    ssh_first_node "pvesh set /cluster/metrics/server/${metric_name} \
      --server ${target_ip} \
      --port ${INFLUXDB_PORT} \
      --bucket ${INFLUXDB_BUCKET} \
      --organization ${INFLUXDB_ORG} \
      --token ${INFLUXDB_TOKEN} \
      --influxdbproto https \
      --verify-certificate 0"
    return
  fi

  echo "  ${metric_name}: creating new entry"
  ssh_first_node "pvesh create /cluster/metrics/server/${metric_name} --type influxdb \
    --server ${target_ip} \
    --port ${INFLUXDB_PORT} \
    --bucket ${INFLUXDB_BUCKET} \
    --organization ${INFLUXDB_ORG} \
    --token ${INFLUXDB_TOKEN} \
    --influxdbproto https \
    --verify-certificate 0"
}

cleanup_legacy_metric_server() {
  local legacy_name="$1"
  shift
  local managed_name

  if [[ -z "${legacy_name}" ]]; then
    return
  fi

  for managed_name in "$@"; do
    if [[ "${legacy_name}" == "${managed_name}" ]]; then
      return
    fi
  done

  if ssh_first_node "pvesh get /cluster/metrics/server/${legacy_name} --output-format json >/dev/null 2>&1"; then
    echo "Removing legacy single-target metric server ${legacy_name}"
    ssh_first_node "pvesh delete /cluster/metrics/server/${legacy_name}"
  fi
}

MANAGED_NAMES=()
for target in "${TARGETS[@]}"; do
  IFS=":" read -r env target_ip <<< "${target}"
  metric_name="${METRICS_APP}-${env}"
  MANAGED_NAMES+=("${metric_name}")
  ensure_metric_server "${metric_name}" "${target_ip}"
done

cleanup_legacy_metric_server "${LEGACY_METRIC_NAME}" "${MANAGED_NAMES[@]}"

echo ""
echo "Managed metric servers:"
ssh_first_node "pvesh get /cluster/metrics/server --output-format json" | python3 -c '
import json
import sys

servers = json.load(sys.stdin)
for server in sorted(servers, key=lambda item: item.get("name", "")):
    print(
        "  {}: {}:{} bucket={} org={}".format(
            server.get("name", "<unknown>"),
            server.get("server", "<missing>"),
            server.get("port", "<missing>"),
            server.get("bucket", "<missing>"),
            server.get("organization", "<missing>"),
        )
    )
'

echo ""
echo "Verify recent VM metrics on each target with:"
for target in "${TARGETS[@]}"; do
  IFS=":" read -r env target_ip <<< "${target}"
  echo "  ${METRICS_APP}-${env}: curl -sk https://${target_ip}:${INFLUXDB_PORT}/api/v2/query?org=${INFLUXDB_ORG} \\"
  echo "    -H 'Authorization: Token <token>' -H 'Content-Type: application/vnd.flux' \\"
  echo "    --data 'from(bucket: \"${INFLUXDB_BUCKET}\") |> range(start: -5m) |> filter(fn: (r) => r._measurement == \"cpustat\") |> limit(n: 3)'"
done
