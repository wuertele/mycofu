#!/usr/bin/env bash
# Step 0 Validation — tests all hardware and infrastructure prerequisites
# Usage: ./tests/step0.sh [path/to/config.yaml]
# Exit code: 0 if all tests pass, 1 if any fail, 2 if setup error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/runner.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"

CONFIG_PATH="${1:-${REPO_DIR}/site/config.yaml}"

echo "=== Step 0 Validation ==="
echo "Config: ${CONFIG_PATH}"

# --- Load and validate config ---
config_load "$CONFIG_PATH"
config_validate

# Track which nodes are reachable (indexed array, 0=unreachable 1=reachable)
REACHABLE_NODES=()

# --- V0.1: Management network ---
test_start "V0.1" "Management network"

for (( i=0; i<CFG_NODE_COUNT; i++ )); do
  local_name="${CFG_NODE_NAMES[$i]}"
  local_ip="${CFG_NODE_IPS[$i]}"
  if ping -c 1 -W 3 "$local_ip" &>/dev/null; then
    test_pass "Ping ${local_name} (${local_ip})"
    REACHABLE_NODES["$i"]=1
  else
    test_fail "Ping ${local_name} (${local_ip}) — timeout"
    REACHABLE_NODES["$i"]=0
  fi
done

if ping -c 1 -W 3 "$CFG_NAS_IP" &>/dev/null; then
  test_pass "Ping NAS (${CFG_NAS_IP})"
  NAS_REACHABLE=1
else
  test_fail "Ping NAS (${CFG_NAS_IP}) — timeout"
  NAS_REACHABLE=0
fi

# --- V0.2: Cluster health (SKIPPED) ---
test_start "V0.2" "Cluster health"
test_skip "Cluster not yet formed — run after all nodes are online and paired"

# --- V0.3: ZFS pools ---
test_start "V0.3" "ZFS pools"

for (( i=0; i<CFG_NODE_COUNT; i++ )); do
  local_name="${CFG_NODE_NAMES[$i]}"
  local_ip="${CFG_NODE_IPS[$i]}"
  if [[ "${REACHABLE_NODES[$i]}" != "1" ]]; then
    test_skip "${local_name} not reachable"
    continue
  fi
  zpool_output=$(ssh_node "$local_ip" "zpool status ${CFG_PVE_STORAGE_POOL}" 2>&1) || true
  if echo "$zpool_output" | grep -q "ONLINE" && ! echo "$zpool_output" | grep -qE "DEGRADED|FAULTED|UNAVAIL"; then
    test_pass "${local_name}: ${CFG_PVE_STORAGE_POOL} is ONLINE"
  else
    test_fail "${local_name}: ${CFG_PVE_STORAGE_POOL} — unexpected status"
  fi
done

# --- V0.4: VLAN connectivity (SKIPPED) ---
test_start "V0.4" "VLAN connectivity"
test_skip "Manual test — attach device to each VLAN and verify DHCP lease"

# --- V0.5: DHCP search domain (SKIPPED) ---
test_start "V0.5" "DHCP search domain"
test_skip "Manual test — verify search domain on DHCP clients"

# --- V0.6: NAS PostgreSQL ---
test_start "V0.6" "NAS PostgreSQL"

if (( NAS_REACHABLE )); then
  if nc -z -w 5 "$CFG_NAS_IP" "$CFG_NAS_PG_PORT" 2>/dev/null; then
    test_pass "TCP connection to ${CFG_NAS_IP}:${CFG_NAS_PG_PORT}"
  else
    test_fail "Cannot connect to PostgreSQL at ${CFG_NAS_IP}:${CFG_NAS_PG_PORT}"
  fi
else
  test_skip "NAS not reachable"
fi

# --- V0.7: NAS NFS ---
test_start "V0.7" "NAS NFS"

# Find a reachable node to run showmount from
nfs_tested=0
for (( i=0; i<CFG_NODE_COUNT; i++ )); do
  if [[ "${REACHABLE_NODES[$i]}" == "1" ]]; then
    local_ip="${CFG_NODE_IPS[$i]}"
    local_name="${CFG_NODE_NAMES[$i]}"
    showmount_output=$(ssh_node "$local_ip" "showmount -e ${CFG_NAS_IP}" 2>&1) || true
    if echo "$showmount_output" | grep -qF "$CFG_NAS_NFS_EXPORT"; then
      test_pass "NFS export ${CFG_NAS_NFS_EXPORT} visible from ${local_name}"
    else
      test_fail "NFS export ${CFG_NAS_NFS_EXPORT} not found from ${local_name}"
    fi
    nfs_tested=1
    break
  fi
done
if (( nfs_tested == 0 )); then
  test_skip "No reachable nodes to test NFS from"
fi

# --- V0.8: Firewall port 53 ---
test_start "V0.8" "Firewall port 53"

if command -v nmap &>/dev/null; then
  nmap_output=$(nmap -Pn -p 53 "$CFG_PUBLIC_IP" 2>&1) || true
  if echo "$nmap_output" | grep -qE "open|filtered"; then
    test_pass "Port 53 reachable at ${CFG_PUBLIC_IP}"
  else
    test_fail "Port 53 not reachable at ${CFG_PUBLIC_IP}"
  fi
else
  test_skip "nmap not installed"
fi

# --- V0.9: Proxmox VLAN awareness ---
test_start "V0.9" "Proxmox VLAN awareness"

for (( i=0; i<CFG_NODE_COUNT; i++ )); do
  local_name="${CFG_NODE_NAMES[$i]}"
  local_ip="${CFG_NODE_IPS[$i]}"
  if [[ "${REACHABLE_NODES[$i]}" != "1" ]]; then
    test_skip "${local_name} not reachable"
    continue
  fi
  iface_output=$(ssh_node "$local_ip" "cat /etc/network/interfaces" 2>&1) || true
  if echo "$iface_output" | grep -q "bridge-vlan-aware yes"; then
    test_pass "${local_name}: bridge is VLAN-aware"
  else
    test_fail "${local_name}: bridge-vlan-aware not found in /etc/network/interfaces"
  fi

  # Runtime check: verify environment VLANs are active on bridge port
  local_mgmt_iface=$(yq ".nodes[$i].mgmt_iface" "$CONFIG_FILE")
  vlan_output=$(ssh_node "$local_ip" "bridge vlan show dev ${local_mgmt_iface} 2>/dev/null") || vlan_output=""
  if [[ -n "$vlan_output" ]]; then
    for env_key in $(yq '.environments | keys | .[]' "$CONFIG_FILE"); do
      env_vlan=$(yq ".environments.${env_key}.vlan_id" "$CONFIG_FILE")
      if echo "$vlan_output" | grep -qw "$env_vlan"; then
        test_pass "${local_name}: VLAN ${env_vlan} (${env_key}) active on ${local_mgmt_iface}"
      else
        test_fail "${local_name}: VLAN ${env_vlan} (${env_key}) missing on ${local_mgmt_iface} — run configure-node-network.sh"
      fi
    done
  else
    test_skip "${local_name}: could not query bridge VLANs on ${local_mgmt_iface}"
  fi
done

# --- V0.10: Node-to-node connectivity ---
test_start "V0.10" "Node-to-node connectivity"

for (( i=0; i<CFG_NODE_COUNT; i++ )); do
  local_name="${CFG_NODE_NAMES[$i]}"
  local_ip="${CFG_NODE_IPS[$i]}"
  if [[ "${REACHABLE_NODES[$i]}" != "1" ]]; then
    test_skip "${local_name} not reachable — cannot test outbound pings"
    continue
  fi
  # Ping every other node's mgmt IP
  for (( j=0; j<CFG_NODE_COUNT; j++ )); do
    if (( i == j )); then continue; fi
    peer_name="${CFG_NODE_NAMES[$j]}"
    peer_ip="${CFG_NODE_IPS[$j]}"
    if ssh_node "$local_ip" "ping -c 1 -W 3 ${peer_ip}" &>/dev/null; then
      test_pass "${local_name} → ${peer_name} (${peer_ip})"
    else
      test_fail "${local_name} → ${peer_name} (${peer_ip}) — timeout"
    fi
  done

  # Replication peers (keys that match other node names)
  for (( j=0; j<CFG_NODE_COUNT; j++ )); do
    if (( i == j )); then continue; fi
    peer_name="${CFG_NODE_NAMES[$j]}"
    repl_addr=$(yq ".nodes[$i].${peer_name}" "$CONFIG_FILE")
    if [[ "$repl_addr" != "null" && -n "$repl_addr" ]]; then
      # repl_addr is like 10.10.2.1/30 — extract just the IP
      repl_ip="${repl_addr%/*}"
      if ssh_node "$local_ip" "ping -c 1 -W 3 ${repl_ip}" &>/dev/null; then
        test_pass "${local_name} → ${peer_name} replication (${repl_ip})"
      else
        test_fail "${local_name} → ${peer_name} replication (${repl_ip}) — timeout"
      fi
    fi
  done
done

# --- Summary ---
runner_summary
