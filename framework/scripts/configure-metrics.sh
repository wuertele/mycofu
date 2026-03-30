#!/usr/bin/env bash
# configure-metrics.sh — Configure Proxmox to send metrics to InfluxDB.
#
# Reads connection details from config.yaml and SOPS, then writes
# /etc/pve/status.cfg on a cluster node (it's cluster-wide via pmxcfs).
#
# Idempotent: updates existing entry if changed, skips if identical.
#
# Usage:
#   framework/scripts/configure-metrics.sh
#
# Prerequisites:
#   - At least one Proxmox node reachable via SSH
#   - InfluxDB application with proxmox_metrics: true in config.yaml
#   - InfluxDB admin token in SOPS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
SETUP_JSON="${REPO_DIR}/site/apps/influxdb/setup.json"

SSH_OPTS="-n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
# SSH without -n for commands that need stdin (heredocs)
SSH_OPTS_STDIN="-o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# --- Check if any application has proxmox_metrics: true ---
METRICS_APP=$(yq -r '.applications // {} | to_entries[] | select(.value.proxmox_metrics == true) | .key' "$APPS_CONFIG" | head -1)
if [[ -z "$METRICS_APP" ]]; then
  echo "No application has proxmox_metrics: true — skipping metrics configuration"
  exit 0
fi

echo "Configuring Proxmox metrics → ${METRICS_APP}"

# --- Read connection details ---
# Prefer prod IP (Proxmox nodes are on management VLAN, management → prod is
# allowed per zone policy). Fall back to dev if prod isn't reachable yet
# (e.g., influxdb-prod not yet deployed).
INFLUXDB_PORT=$(yq -r ".applications.${METRICS_APP}.health_port" "$APPS_CONFIG")
PROD_IP=$(yq -r ".applications.${METRICS_APP}.environments.prod.ip" "$APPS_CONFIG")
DEV_IP=$(yq -r ".applications.${METRICS_APP}.environments.dev.ip" "$APPS_CONFIG")

INFLUXDB_IP=""
if [[ -n "$PROD_IP" && "$PROD_IP" != "null" ]]; then
  # Check if prod InfluxDB is reachable from first node
  if ssh $SSH_OPTS "root@$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")" \
    "curl -sk --connect-timeout 3 https://${PROD_IP}:${INFLUXDB_PORT}/health" 2>/dev/null | grep -q '"status"'; then
    INFLUXDB_IP="$PROD_IP"
    echo "  Using prod InfluxDB (${INFLUXDB_IP})"
  fi
fi

if [[ -z "$INFLUXDB_IP" && -n "$DEV_IP" && "$DEV_IP" != "null" ]]; then
  if ssh $SSH_OPTS "root@$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")" \
    "curl -sk --connect-timeout 3 https://${DEV_IP}:${INFLUXDB_PORT}/health" 2>/dev/null | grep -q '"status"'; then
    INFLUXDB_IP="$DEV_IP"
    echo "  Using dev InfluxDB (${INFLUXDB_IP}) — prod not yet reachable"
    echo "  Re-run after deploying ${METRICS_APP}-prod to switch to prod."
  fi
fi

if [[ -z "$INFLUXDB_IP" ]]; then
  echo "ERROR: Neither prod (${PROD_IP}) nor dev (${DEV_IP}) InfluxDB is reachable from Proxmox nodes" >&2
  echo "  Deploy InfluxDB and ensure management → InfluxDB routing works." >&2
  exit 1
fi

# Read org and bucket from setup.json
if [[ ! -f "$SETUP_JSON" ]]; then
  echo "ERROR: ${SETUP_JSON} not found" >&2
  exit 1
fi
INFLUXDB_ORG=$(python3 -c "import json; print(json.load(open('${SETUP_JSON}'))['org'])")
INFLUXDB_BUCKET=$(python3 -c "import json; print(json.load(open('${SETUP_JSON}'))['bucket'])")

# Read token from SOPS
INFLUXDB_TOKEN=$(sops -d --extract '["influxdb_admin_token"]' "${REPO_DIR}/site/sops/secrets.yaml")

# --- Determine cluster node to write to ---
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")

# --- Proxmox metric server entry name ---
METRIC_NAME=$(yq -r '.cicd.project_name // "metrics"' "$CONFIG")

# --- Idempotent write via pvesh API ---
# Using pvesh (not direct status.cfg write) because Proxmox stores the token
# in a separate credentials file (/etc/pve/priv/metricserver/<id>.pw), not in
# status.cfg. Writing status.cfg directly results in 401 Unauthorized.
EXISTING_SERVER=$(ssh $SSH_OPTS "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/metrics/server/${METRIC_NAME} --output-format json 2>/dev/null" || echo "")

if [[ -n "$EXISTING_SERVER" && "$EXISTING_SERVER" != "" ]]; then
  # Entry exists — check if config matches
  EXISTING_IP=$(echo "$EXISTING_SERVER" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('server',''))" 2>/dev/null)
  if [[ "$EXISTING_IP" == "$INFLUXDB_IP" ]]; then
    echo "  Metric server already configured correctly — no changes needed"
  else
    echo "  Metric server config changed (${EXISTING_IP} → ${INFLUXDB_IP}) — updating..."
    ssh $SSH_OPTS "root@${FIRST_NODE_IP}" \
      "pvesh set /cluster/metrics/server/${METRIC_NAME} \
        --server ${INFLUXDB_IP} \
        --port ${INFLUXDB_PORT} \
        --bucket ${INFLUXDB_BUCKET} \
        --organization ${INFLUXDB_ORG} \
        --token ${INFLUXDB_TOKEN} \
        --influxdbproto https \
        --verify-certificate 0"
  fi
else
  echo "  Adding InfluxDB metric server to Proxmox..."
  ssh $SSH_OPTS "root@${FIRST_NODE_IP}" \
    "pvesh create /cluster/metrics/server/${METRIC_NAME} --type influxdb \
      --server ${INFLUXDB_IP} \
      --port ${INFLUXDB_PORT} \
      --bucket ${INFLUXDB_BUCKET} \
      --organization ${INFLUXDB_ORG} \
      --token ${INFLUXDB_TOKEN} \
      --influxdbproto https \
      --verify-certificate 0"
fi

echo "  Metric server configured on cluster (via ${FIRST_NODE_IP})"

# --- Verify connectivity ---
echo "  Verifying InfluxDB reachability from Proxmox nodes..."
NODE_COUNT=$(yq -r '.nodes | length' "$CONFIG")
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
  NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
  if ssh $SSH_OPTS "root@${NODE_IP}" \
    "curl -sk --connect-timeout 5 https://${INFLUXDB_IP}:${INFLUXDB_PORT}/health" 2>/dev/null | grep -q '"status"'; then
    echo "    ${NODE_NAME}: can reach InfluxDB at ${INFLUXDB_IP}:${INFLUXDB_PORT}"
  else
    echo "    ${NODE_NAME}: CANNOT reach InfluxDB at ${INFLUXDB_IP}:${INFLUXDB_PORT}"
    echo "      Check firewall: management → prod must be allowed"
    echo "      Check gateway zones: from_management: allow for prod zone"
  fi
done

echo ""
echo "Proxmox will begin sending metrics within 30 seconds."
echo "Verify with: curl -sk https://${INFLUXDB_IP}:${INFLUXDB_PORT}/api/v2/query?org=${INFLUXDB_ORG} \\"
echo "  -H 'Authorization: Token <token>' -H 'Content-Type: application/vnd.flux' \\"
echo "  --data 'from(bucket: \"${INFLUXDB_BUCKET}\") |> range(start: -5m) |> filter(fn: (r) => r._measurement == \"cpustat\") |> limit(n: 3)'"
