#!/usr/bin/env bash
# placement-watchdog.sh — Autonomous placement drift detection and recovery.
#
# Runs on the NAS via cron (every 5 minutes). Detects VMs on wrong nodes,
# waits for all nodes to be healthy, then calls rebalance-cluster.sh.
#
# If no drift: exits silently (exit 0).
# If drift but nodes down: logs and exits (retries on next run).
# If drift and all nodes healthy: runs rebalance and logs.
#
# Usage:
#   placement-watchdog.sh                     # Normal watchdog mode
#   placement-watchdog.sh --health-server [PORT]  # HTTP health endpoint (default 9200)
#   placement-watchdog.sh --detect-only       # JSON drift report (no rebalance)
#
# Configuration:
#   Set WATCHDOG_CONFIG_DIR to a directory containing config.yaml,
#   or REPO_DIR to the repo root (uses site/config.yaml).
#
# Deployed to NAS by configure-sentinel-gatus.sh.

set -euo pipefail

LOG_FILE="/var/log/placement-watchdog.log"
HEALTH_PORT=9200

# --- Health server mode (Python http.server — no socat dependency) ---
if [[ "${1:-}" == "--health-server" ]]; then
  [[ -n "${2:-}" ]] && HEALTH_PORT="$2"

  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  exec python3 -c "
import http.server, subprocess, json

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            r = subprocess.run(['${SCRIPT_PATH}', '--detect-only'],
                               capture_output=True, text=True, timeout=30)
            body = r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else \
                json.dumps({'placement_healthy': False, 'error': 'detection failed', 'all_nodes_up': False, 'drift': []})
        except Exception as e:
            body = json.dumps({'placement_healthy': False, 'error': str(e), 'all_nodes_up': False, 'drift': []})
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, fmt, *args):
        pass  # suppress per-request logs

http.server.HTTPServer(('', ${HEALTH_PORT}), Handler).serve_forever()
"
fi

# --- Locate config ---
# Supports both config.json (NAS deployment, parsed with jq) and
# config.yaml (local workstation, parsed with yq).
CONFIG=""
CONFIG_FORMAT=""
if [[ -n "${WATCHDOG_CONFIG_DIR:-}" ]]; then
  if [[ -f "${WATCHDOG_CONFIG_DIR}/config.json" ]]; then
    CONFIG="${WATCHDOG_CONFIG_DIR}/config.json"
    CONFIG_FORMAT="json"
  elif [[ -f "${WATCHDOG_CONFIG_DIR}/config.yaml" ]]; then
    CONFIG="${WATCHDOG_CONFIG_DIR}/config.yaml"
    CONFIG_FORMAT="yaml"
  fi
elif [[ -n "${REPO_DIR:-}" ]]; then
  CONFIG="${REPO_DIR}/site/config.yaml"
  CONFIG_FORMAT="yaml"
else
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "${dir}/flake.nix" ]]; then
      CONFIG="${dir}/site/config.yaml"
      CONFIG_FORMAT="yaml"
      REPO_DIR="$dir"
      break
    fi
    dir="$(dirname "$dir")"
  done
fi

if [[ ! -f "${CONFIG:-}" ]]; then
  echo "ERROR: config not found. Set REPO_DIR or WATCHDOG_CONFIG_DIR." >&2
  exit 1
fi

# Config query helper — uses jq for JSON, yq for YAML
cfg_query() {
  if [[ "$CONFIG_FORMAT" == "json" ]]; then
    jq -r "$1" "$CONFIG"
  else
    yq -r "$1" "$CONFIG"
  fi
}

DETECT_ONLY=false
[[ "${1:-}" == "--detect-only" ]] && DETECT_ONLY=true

# Temp files (bash 3.2 compatible — no associative arrays)
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

INTENDED_FILE="${TMPDIR_WORK}/intended"
ACTUAL_FILE="${TMPDIR_WORK}/actual"

# --- Read intended placement ---
# Infrastructure VMs (from vms section)
cfg_query '.vms | to_entries | .[] | select(.value | has("node")) | .key + "=" + .value.node' > "$INTENDED_FILE"
# Application VMs (from applications section — per-environment with shared node)
cfg_query '.applications // {} | to_entries[] | select(.value.enabled == true and (.value | has("node"))) | .key as $app | .value.node as $node | (.value.environments // {} | keys[]) as $env | ($app + "_" + $env) + "=" + $node' >> "$INTENDED_FILE" 2>/dev/null || true

# --- Check node health ---
NODE_COUNT=$(cfg_query '.nodes | length')
ALL_NODES_UP=true
FIRST_NODE_IP=""

for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_IP=$(cfg_query ".nodes[${i}].mgmt_ip")

  if ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_IP}" "true" 2>/dev/null; then
    [[ -z "$FIRST_NODE_IP" ]] && FIRST_NODE_IP="$NODE_IP"
  else
    ALL_NODES_UP=false
  fi
done

if [[ -z "$FIRST_NODE_IP" ]]; then
  if [[ "$DETECT_ONLY" == "true" ]]; then
    echo '{"placement_healthy": false, "error": "no nodes reachable", "all_nodes_up": false, "drift": []}'
  fi
  exit 1
fi

# --- Query actual placement (API resilience: try each node until non-empty) ---
CLUSTER_RESOURCES=""
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_IP=$(cfg_query ".nodes[${i}].mgmt_ip")
  RESULT=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_IP}" \
    "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null) || continue
  if echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); exit(0 if len(d)>0 else 1)" 2>/dev/null; then
    CLUSTER_RESOURCES="$RESULT"
    break
  fi
done

if [[ -z "$CLUSTER_RESOURCES" ]]; then
  if [[ "$DETECT_ONLY" == "true" ]]; then
    echo '{"placement_healthy": false, "error": "all nodes returned empty API data", "all_nodes_up": false, "drift": []}'
  fi
  exit 1
fi

echo "$CLUSTER_RESOURCES" | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    if vm.get('type') == 'qemu' and vm.get('status') == 'running':
        name = vm['name'].replace('-', '_')
        print(f'{name}={vm[\"node\"]}={vm[\"vmid\"]}')
" > "$ACTUAL_FILE"

# --- Detect drift ---
DRIFT_ENTRIES=""
DRIFT_COUNT=0

while IFS='=' read -r vm intended_node; do
  [[ -z "$vm" ]] && continue
  actual_line=$({ grep "^${vm}=" "$ACTUAL_FILE" 2>/dev/null || echo ""; } | head -1)
  [[ -z "$actual_line" ]] && continue

  actual_node=$(echo "$actual_line" | cut -d= -f2)
  vmid=$(echo "$actual_line" | cut -d= -f3)

  if [[ "$intended_node" != "$actual_node" ]]; then
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    DRIFT_ENTRIES="${DRIFT_ENTRIES}${vm}:${actual_node}:${intended_node}:${vmid}
"
  fi
done < "$INTENDED_FILE"

# --- Output for --detect-only (health endpoint) ---
if [[ "$DETECT_ONLY" == "true" ]]; then
  placement_healthy=true
  [[ "$DRIFT_COUNT" -gt 0 ]] && placement_healthy=false

  drift_json="["
  first=true
  while IFS=':' read -r vm actual intended vmid; do
    [[ -z "$vm" ]] && continue
    $first || drift_json+=", "
    first=false
    drift_json+="{\"vm\": \"${vm}\", \"actual\": \"${actual}\", \"intended\": \"${intended}\", \"vmid\": ${vmid}}"
  done <<< "$DRIFT_ENTRIES"
  drift_json+="]"

  echo "{\"placement_healthy\": ${placement_healthy}, \"all_nodes_up\": ${ALL_NODES_UP}, \"drift\": ${drift_json}}"
  exit 0
fi

# --- No drift: exit silently ---
if [[ "$DRIFT_COUNT" -eq 0 ]]; then
  exit 0
fi

# --- Drift detected ---
echo "$(date): Placement drift detected (${DRIFT_COUNT} VM(s) misplaced):" >> "$LOG_FILE"
while IFS=':' read -r vm actual intended vmid; do
  [[ -z "$vm" ]] && continue
  echo "  ${vm} (VMID ${vmid}): on ${actual}, should be ${intended}" >> "$LOG_FILE"
done <<< "$DRIFT_ENTRIES"

# If nodes are down, log and wait for next timer run
if [[ "$ALL_NODES_UP" != "true" ]]; then
  echo "$(date): Node(s) down — waiting for recovery before rebalancing." >> "$LOG_FILE"
  exit 0
fi

# All nodes healthy — run rebalance
echo "$(date): All nodes healthy. Running rebalance..." >> "$LOG_FILE"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBALANCE="${SCRIPT_DIR}/rebalance-cluster.sh"

if [[ -x "$REBALANCE" ]]; then
  "$REBALANCE" 2>&1 | tee -a "$LOG_FILE"
else
  echo "$(date): ERROR: rebalance-cluster.sh not found at ${REBALANCE}" >> "$LOG_FILE"
  exit 1
fi

echo "$(date): Rebalance complete." >> "$LOG_FILE"
