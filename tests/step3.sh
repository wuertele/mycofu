#!/usr/bin/env bash
# Step 3 Validation — DNS VM deployment checks
# Usage: ./tests/step3.sh [path/to/config.yaml]
# Exit code: 0 if all tests pass, 1 if any fail, 2 if setup error

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${SCRIPT_DIR}/lib/runner.sh"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/ssh.sh"

CONFIG_PATH="${1:-${REPO_DIR}/site/config.yaml}"

echo "=== Step 3 Validation ==="
echo "Config: ${CONFIG_PATH}"

# --- Load and validate config ---
config_load "$CONFIG_PATH"

# SSH helper for VMs (same options, different user)
ssh_vm() {
  local ip="$1"
  shift
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

# --- V3.0: Node VLAN readiness ---
test_start "V3.0" "Node VLAN readiness"

for (( i=0; i<CFG_NODE_COUNT; i++ )); do
  local_name="${CFG_NODE_NAMES[$i]}"
  local_ip="${CFG_NODE_IPS[$i]}"
  local_mgmt_iface=$(yq ".nodes[$i].mgmt_iface" "$CONFIG_FILE")

  if ! ping -c 1 -W 3 "$local_ip" &>/dev/null; then
    test_fail "${local_name} (${local_ip}) unreachable"
    continue
  fi

  vlan_output=$(ssh_node "$local_ip" "bridge vlan show dev ${local_mgmt_iface} 2>/dev/null") || vlan_output=""
  if [[ -z "$vlan_output" ]]; then
    test_fail "${local_name}: could not query bridge VLANs on ${local_mgmt_iface}"
    continue
  fi

  for env_key in $(yq '.environments | keys | .[]' "$CONFIG_FILE"); do
    env_vlan=$(yq ".environments.${env_key}.vlan_id" "$CONFIG_FILE")
    if echo "$vlan_output" | grep -qw "$env_vlan"; then
      test_pass "${local_name}: VLAN ${env_vlan} (${env_key}) active on ${local_mgmt_iface}"
    else
      test_fail "${local_name}: VLAN ${env_vlan} (${env_key}) missing on ${local_mgmt_iface} — run configure-node-network.sh"
    fi
  done
done

# --- Collect DNS VM info ---
# DNS VMs: dns1_prod, dns2_prod, dns1_dev, dns2_dev
DNS_VMS=()
DNS_IPS=()
DNS_HOSTNAMES=()
DNS_ENVS=()

for env_key in $(yq '.environments | keys | .[]' "$CONFIG_FILE"); do
  for idx in 1 2; do
    vm_key="dns${idx}_${env_key}"
    vm_ip=$(yq ".vms.${vm_key}.ip" "$CONFIG_FILE")
    if [[ "$vm_ip" != "null" && -n "$vm_ip" ]]; then
      DNS_VMS+=("$vm_key")
      DNS_IPS+=("$vm_ip")
      DNS_HOSTNAMES+=("dns${idx}-${env_key}")
      DNS_ENVS+=("$env_key")
    fi
  done
done

# Track which VMs are reachable
REACHABLE_VMS=()

# --- V3.1: DNS VMs running ---
test_start "V3.1" "DNS VMs running"

for (( v=0; v<${#DNS_VMS[@]}; v++ )); do
  vm="${DNS_VMS[$v]}"
  ip="${DNS_IPS[$v]}"
  if ssh_vm "$ip" "true" 2>/dev/null; then
    test_pass "${vm} (${ip}) reachable via SSH"
    REACHABLE_VMS[$v]=1
  else
    test_fail "${vm} (${ip}) not reachable via SSH"
    REACHABLE_VMS[$v]=0
  fi
done

# --- V3.2: nocloud-init ran ---
test_start "V3.2" "nocloud-init ran"

for (( v=0; v<${#DNS_VMS[@]}; v++ )); do
  vm="${DNS_VMS[$v]}"
  ip="${DNS_IPS[$v]}"
  if [[ "${REACHABLE_VMS[$v]}" != "1" ]]; then
    test_skip "${vm} not reachable"
    continue
  fi
  nc_status=$(ssh_vm "$ip" "systemctl is-active nocloud-init 2>/dev/null" || true)
  if [[ "$nc_status" == "active" ]]; then
    test_pass "${vm}: nocloud-init is active"
  elif [[ -z "$nc_status" ]]; then
    test_fail "${vm}: nocloud-init status unknown (SSH failed?)"
  else
    test_fail "${vm}: nocloud-init is ${nc_status}"
  fi
done

# --- V3.3: Hostname set ---
test_start "V3.3" "Hostname set"

for (( v=0; v<${#DNS_VMS[@]}; v++ )); do
  vm="${DNS_VMS[$v]}"
  ip="${DNS_IPS[$v]}"
  expected="${DNS_HOSTNAMES[$v]}"
  if [[ "${REACHABLE_VMS[$v]}" != "1" ]]; then
    test_skip "${vm} not reachable"
    continue
  fi
  actual=$(ssh_vm "$ip" "hostname") || actual=""
  if [[ "$actual" == "$expected" ]]; then
    test_pass "${vm}: hostname is ${actual}"
  else
    test_fail "${vm}: hostname is '${actual}', expected '${expected}'"
  fi
done

# --- V3.4: PowerDNS API key delivered ---
test_start "V3.4" "PowerDNS API key delivered"

for (( v=0; v<${#DNS_VMS[@]}; v++ )); do
  vm="${DNS_VMS[$v]}"
  ip="${DNS_IPS[$v]}"
  if [[ "${REACHABLE_VMS[$v]}" != "1" ]]; then
    test_skip "${vm} not reachable"
    continue
  fi
  key_check=$(ssh_vm "$ip" "test -f /run/secrets/pdns-api-key && stat -c '%a' /run/secrets/pdns-api-key 2>/dev/null") || key_check=""
  if [[ "$key_check" == "400" ]]; then
    test_pass "${vm}: /run/secrets/pdns-api-key exists with mode 0400"
  elif [[ -z "$key_check" ]]; then
    test_fail "${vm}: /run/secrets/pdns-api-key not found"
  else
    test_fail "${vm}: /run/secrets/pdns-api-key has mode ${key_check}, expected 0400"
  fi
done

# --- V3.5: PowerDNS running ---
test_start "V3.5" "PowerDNS running"

for (( v=0; v<${#DNS_VMS[@]}; v++ )); do
  vm="${DNS_VMS[$v]}"
  ip="${DNS_IPS[$v]}"
  if [[ "${REACHABLE_VMS[$v]}" != "1" ]]; then
    test_skip "${vm} not reachable"
    continue
  fi
  pdns_status=$(ssh_vm "$ip" "systemctl is-active pdns 2>/dev/null" || true)
  if [[ "$pdns_status" == "active" ]]; then
    test_pass "${vm}: pdns is active"
  elif [[ -z "$pdns_status" ]]; then
    test_fail "${vm}: pdns status unknown (SSH failed?)"
  else
    test_fail "${vm}: pdns is ${pdns_status}"
  fi
done

# --- V3.6: Root filesystem expanded ---
test_start "V3.6" "Root filesystem expanded"

for (( v=0; v<${#DNS_VMS[@]}; v++ )); do
  vm="${DNS_VMS[$v]}"
  ip="${DNS_IPS[$v]}"
  if [[ "${REACHABLE_VMS[$v]}" != "1" ]]; then
    test_skip "${vm} not reachable"
    continue
  fi
  # Get root filesystem size in 1K blocks, convert to GB
  root_size_kb=$(ssh_vm "$ip" "df --output=size / 2>/dev/null | tail -1 | tr -d ' '") || root_size_kb=0
  root_size_gb=$(( root_size_kb / 1024 / 1024 ))
  if (( root_size_gb >= 3 )); then
    test_pass "${vm}: root filesystem is ${root_size_gb}G"
  else
    test_fail "${vm}: root filesystem is ${root_size_gb}G (expected >= 3G, image may not have expanded)"
  fi
done

# --- V3.7: Anti-affinity ---
test_start "V3.7" "Anti-affinity"

# For each environment, check that dns1 and dns2 are on different nodes
for env_key in $(yq '.environments | keys | .[]' "$CONFIG_FILE"); do
  dns1_vm="dns1_${env_key}"
  dns2_vm="dns2_${env_key}"
  dns1_hostname="dns1-${env_key}"
  dns2_hostname="dns2-${env_key}"

  dns1_node=""
  dns2_node=""

  for (( i=0; i<CFG_NODE_COUNT; i++ )); do
    local_ip="${CFG_NODE_IPS[$i]}"
    local_name="${CFG_NODE_NAMES[$i]}"
    if ! ping -c 1 -W 3 "$local_ip" &>/dev/null; then
      continue
    fi
    qm_output=$(ssh_node "$local_ip" "qm list 2>/dev/null") || continue
    if echo "$qm_output" | grep -q "$dns1_hostname"; then
      dns1_node="$local_name"
    fi
    if echo "$qm_output" | grep -q "$dns2_hostname"; then
      dns2_node="$local_name"
    fi
  done

  if [[ -z "$dns1_node" ]]; then
    test_fail "${env_key}: could not find ${dns1_hostname} on any node"
  elif [[ -z "$dns2_node" ]]; then
    test_fail "${env_key}: could not find ${dns2_hostname} on any node"
  elif [[ "$dns1_node" != "$dns2_node" ]]; then
    test_pass "${env_key}: ${dns1_hostname} on ${dns1_node}, ${dns2_hostname} on ${dns2_node} (different nodes)"
  else
    test_fail "${env_key}: ${dns1_hostname} and ${dns2_hostname} both on ${dns1_node} (same node)"
  fi
done

# --- Summary ---
runner_summary
