#!/usr/bin/env bash
# rebalance-cluster.sh — Migrate VMs back to their intended Proxmox nodes.
#
# After an HA failover, VMs run on surviving nodes — not their intended
# placement from config.yaml. This script detects drift and migrates VMs
# back using ha-manager migrate.
#
# Usage:
#   framework/scripts/rebalance-cluster.sh [--dry-run]
#
# Prerequisites: all nodes must be healthy and reachable.
# Idempotent: exits with "no drift" if all VMs are correctly placed.
#
# Reads: site/config.yaml (vms.<name>.node for intended placement)
# Queries: Proxmox API via pvesh on any reachable node

set -euo pipefail

# --- Locate repo root ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2; exit 1
}

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# --- Locate config ---
# Supports config.json (NAS, parsed with jq) and config.yaml (workstation, parsed with yq).
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
fi
if [[ -z "$CONFIG" ]]; then
  REPO_DIR="$(find_repo_root)"
  CONFIG="${REPO_DIR}/site/config.yaml"
  CONFIG_FORMAT="yaml"
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: $CONFIG" >&2
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

# Temp files for lookups (bash 3.2 has no associative arrays)
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

INTENDED_FILE="${TMPDIR_WORK}/intended"
ACTUAL_FILE="${TMPDIR_WORK}/actual"

# --- Read intended placement from config ---
# Produces lines like: dns1_prod=pve01
# Infrastructure VMs (from vms section)
cfg_query '.vms | to_entries | .[] | select(.value | has("node")) | .key + "=" + .value.node' > "$INTENDED_FILE"
# Application VMs (from applications section — per-environment with shared node)
cfg_query '.applications // {} | to_entries[] | select(.value.enabled == true and (.value | has("node"))) | .key as $app | .value.node as $node | (.value.environments // {} | keys[]) as $env | ($app + "_" + $env) + "=" + $node' >> "$INTENDED_FILE" 2>/dev/null || true

if [[ ! -s "$INTENDED_FILE" ]]; then
  echo "ERROR: No VMs with 'node' field found in config.yaml" >&2
  exit 1
fi

# --- Check all nodes are healthy ---
echo "Checking node health..."
NODE_COUNT=$(cfg_query '.nodes | length')
FIRST_NODE_IP=""
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAME=$(cfg_query ".nodes[${i}].name")
  NODE_IP=$(cfg_query ".nodes[${i}].mgmt_ip")
  [[ -z "$FIRST_NODE_IP" ]] && FIRST_NODE_IP="$NODE_IP"

  if ! ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_IP}" "true" 2>/dev/null; then
    echo "ERROR: Node ${NODE_NAME} (${NODE_IP}) is not reachable via SSH." >&2
    echo "All nodes must be healthy before rebalancing." >&2
    exit 1
  fi
  echo "  ${NODE_NAME}: reachable"
done
echo ""

# --- Query actual VM placement from Proxmox API ---
# Proxmox VM names use hyphens (dns1-prod), config.yaml uses underscores (dns1_prod).
# API resilience: try each node until we get non-empty results (pvesh can return
# empty JSON during cluster state transitions like a node departing).
echo "Querying actual VM placement..."
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
  echo "ERROR: All nodes returned empty API data. Cannot determine VM placement." >&2
  exit 1
fi

echo "$CLUSTER_RESOURCES" | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    if vm.get('type') == 'qemu' and vm.get('status') == 'running':
        name = vm['name'].replace('-', '_')
        print(f'{name}={vm[\"node\"]}={vm[\"vmid\"]}')
" > "$ACTUAL_FILE"

# --- Lookup helpers ---
get_actual_node() {
  local vm="$1"
  { grep "^${vm}=" "$ACTUAL_FILE" 2>/dev/null || echo ""; } | head -1 | cut -d= -f2
}

get_vmid() {
  local vm="$1"
  { grep "^${vm}=" "$ACTUAL_FILE" 2>/dev/null || echo ""; } | head -1 | cut -d= -f3
}

# --- Compare and migrate ---
DRIFT=0
MIGRATED=0

while IFS='=' read -r vm intended_node; do
  [[ -z "$vm" ]] && continue
  actual_node=$(get_actual_node "$vm")
  vmid=$(get_vmid "$vm")

  if [[ -z "$actual_node" ]]; then
    echo "  WARNING: ${vm} not found in cluster (may be stopped or missing)"
    continue
  fi

  if [[ "$intended_node" != "$actual_node" ]]; then
    DRIFT=1
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  Would migrate ${vm} (VMID ${vmid}): ${actual_node} -> ${intended_node}"
    else
      echo "  Migrating ${vm} (VMID ${vmid}): ${actual_node} -> ${intended_node}"
      ssh -n "root@${FIRST_NODE_IP}" "ha-manager migrate vm:${vmid} ${intended_node}" 2>/dev/null

      # Wait for migration to complete (up to 5 minutes)
      for i in $(seq 1 60); do
        current=$(ssh -n "root@${FIRST_NODE_IP}" \
          "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null | \
          python3 -c "
import sys, json
for v in json.loads(sys.stdin.read()):
    if v.get('vmid') == ${vmid}:
        print(v['node'])
        break
")
        if [[ "$current" == "$intended_node" ]]; then
          echo "    OK: ${vm} now on ${intended_node}"
          MIGRATED=$((MIGRATED + 1))
          break
        fi
        if [[ "$i" -eq 60 ]]; then
          echo "    WARNING: ${vm} migration timed out (5 min). Check manually."
        fi
        sleep 5
      done
    fi
  fi
done < "$INTENDED_FILE"

if [[ "$DRIFT" -eq 0 ]]; then
  echo "No placement drift detected. All VMs on intended nodes."
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo "Dry run complete. Use without --dry-run to migrate."
  exit 0
fi

echo ""
echo "Rebalance complete. Migrated ${MIGRATED} VM(s)."
