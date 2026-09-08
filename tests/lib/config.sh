#!/usr/bin/env bash
# Config loader and validator — reads site/config.yaml via yq

CONFIG_FILE=""

config_load() {
  local config_path="$1"
  CONFIG_FILE="$config_path"

  if [[ ! -f "$config_path" ]]; then
    echo "ERROR: Config file not found: ${config_path}" >&2
    exit 2
  fi

  if ! command -v yq &>/dev/null; then
    echo "ERROR: yq is required but not installed" >&2
    exit 2
  fi

  # Domain
  CFG_DOMAIN=$(yq '.domain' "$config_path")
  CFG_REGISTRAR=$(yq '.registrar' "$config_path")

  # Environments
  CFG_PROD_VLAN_ID=$(yq '.environments.prod.vlan_id' "$config_path")
  CFG_PROD_SUBNET=$(yq '.environments.prod.subnet' "$config_path")
  CFG_PROD_GATEWAY=$(yq '.environments.prod.gateway' "$config_path")
  CFG_PROD_DNS_DOMAIN="prod.${CFG_DOMAIN}"

  CFG_DEV_VLAN_ID=$(yq '.environments.dev.vlan_id' "$config_path")
  CFG_DEV_SUBNET=$(yq '.environments.dev.subnet' "$config_path")
  CFG_DEV_GATEWAY=$(yq '.environments.dev.gateway' "$config_path")
  CFG_DEV_DNS_DOMAIN="dev.${CFG_DOMAIN}"

  # Management
  CFG_MGMT_VLAN_ID=$(yq '.management.vlan_id' "$config_path")
  CFG_MGMT_SUBNET=$(yq '.management.subnet' "$config_path")
  CFG_MGMT_GATEWAY=$(yq '.management.gateway' "$config_path")

  # Nodes
  CFG_NODE_COUNT=$(yq '.nodes | length' "$config_path")
  CFG_NODE_NAMES=()
  CFG_NODE_IPS=()
  CFG_NODE_RAM=()
  for (( i=0; i<CFG_NODE_COUNT; i++ )); do
    CFG_NODE_NAMES+=("$(yq ".nodes[$i].name" "$config_path")")
    CFG_NODE_IPS+=("$(yq ".nodes[$i].mgmt_ip" "$config_path")")
    CFG_NODE_RAM+=("$(yq ".nodes[$i].ram_gb" "$config_path")")
  done

  # NAS
  CFG_NAS_HOSTNAME=$(yq '.nas.hostname' "$config_path")
  CFG_NAS_IP=$(yq '.nas.ip' "$config_path")
  CFG_NAS_NFS_EXPORT=$(yq '.nas.nfs_export' "$config_path")
  CFG_NAS_PG_PORT=$(yq '.nas.postgres_port' "$config_path")

  # Proxmox
  CFG_PVE_IMAGE_PATH=$(yq '.proxmox.image_storage_path' "$config_path")
  CFG_PVE_STORAGE_POOL=$(yq '.proxmox.storage_pool' "$config_path")

  # VMs
  CFG_VM_NAMES=($(yq '.vms | keys | .[]' "$config_path"))

  # Public IP
  CFG_PUBLIC_IP=$(yq '.public_ip' "$config_path")

  # Email
  CFG_EMAIL_SMTP_HOST=$(yq '.email.smtp_host' "$config_path")

  # SSH
  CFG_SSH_PUBKEY=$(yq '.operator_ssh_pubkey' "$config_path")

  # Hardware
  CFG_HW_NODE_COUNT=$(yq '.hardware.node_count' "$config_path")
  CFG_HW_TOTAL_RAM=$(yq '.hardware.total_ram_gb' "$config_path")
  CFG_HW_N1_BUDGET=$(yq '.hardware.n_plus_1_budget_gb' "$config_path")
}

# --- Validation helpers ---

_valid_ip() {
  local ip="$1"
  local IFS='.'
  read -ra octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

_valid_cidr() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local prefix="${cidr#*/}"
  _valid_ip "$ip" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 )) || return 1
  return 0
}

_valid_mac() {
  local mac="$1"
  [[ "$mac" =~ ^02:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}$ ]]
}

# Check if an IP falls within a CIDR subnet
_ip_in_subnet() {
  local ip="$1" cidr="$2"
  local net_ip="${cidr%/*}"
  local prefix="${cidr#*/}"

  # Convert IPs to 32-bit integers
  local IFS='.'
  read -ra ip_parts <<< "$ip"
  read -ra net_parts <<< "$net_ip"

  local ip_int=$(( (ip_parts[0] << 24) + (ip_parts[1] << 16) + (ip_parts[2] << 8) + ip_parts[3] ))
  local net_int=$(( (net_parts[0] << 24) + (net_parts[1] << 16) + (net_parts[2] << 8) + net_parts[3] ))

  local mask=$(( 0xFFFFFFFF << (32 - prefix) ))
  # Bash uses signed 64-bit, so mask with 0xFFFFFFFF
  mask=$(( mask & 0xFFFFFFFF ))

  (( (ip_int & mask) == (net_int & mask) ))
}

config_validate() {
  test_start "Config" "Configuration validation"

  # Required top-level keys
  local required_keys=(domain environments management nodes nas proxmox vms public_ip email operator_ssh_pubkey hardware)
  local missing=0
  for key in "${required_keys[@]}"; do
    local val
    val=$(yq ".${key}" "$CONFIG_FILE")
    if [[ "$val" == "null" || -z "$val" ]]; then
      test_fail "Required key missing: ${key}"
      missing=1
    fi
  done
  if (( missing == 0 )); then
    test_pass "All required top-level keys present"
  fi

  # VLAN IDs distinct
  if [[ "$CFG_PROD_VLAN_ID" == "$CFG_DEV_VLAN_ID" ]]; then
    test_fail "Prod and dev VLAN IDs are the same (${CFG_PROD_VLAN_ID})"
  else
    test_pass "Prod and dev VLAN IDs are distinct (${CFG_PROD_VLAN_ID} vs ${CFG_DEV_VLAN_ID})"
  fi

  # Management VLAN distinct from prod/dev
  if [[ "$CFG_MGMT_VLAN_ID" == "$CFG_PROD_VLAN_ID" || "$CFG_MGMT_VLAN_ID" == "$CFG_DEV_VLAN_ID" ]]; then
    test_fail "Management VLAN ID (${CFG_MGMT_VLAN_ID}) conflicts with prod or dev"
  else
    test_pass "Management VLAN ID (${CFG_MGMT_VLAN_ID}) distinct from prod/dev"
  fi

  # IP validation — collect all IPs to check
  local all_ips=("$CFG_PROD_GATEWAY" "$CFG_DEV_GATEWAY" "$CFG_MGMT_GATEWAY" "$CFG_NAS_IP" "$CFG_PUBLIC_IP")
  for ip in "${CFG_NODE_IPS[@]}"; do all_ips+=("$ip"); done
  local ip_fail=0
  for ip in "${all_ips[@]}"; do
    if ! _valid_ip "$ip"; then
      test_fail "Invalid IP: ${ip}"
      ip_fail=1
    fi
  done
  # Also check VM IPs
  for vm in "${CFG_VM_NAMES[@]}"; do
    local vm_ip
    vm_ip=$(yq ".vms.${vm}.ip" "$CONFIG_FILE")
    if ! _valid_ip "$vm_ip"; then
      test_fail "Invalid VM IP for ${vm}: ${vm_ip}"
      ip_fail=1
    fi
  done
  if (( ip_fail == 0 )); then
    test_pass "All IP addresses are valid format"
  fi

  # Subnet CIDR validation
  local cidr_fail=0
  for cidr in "$CFG_PROD_SUBNET" "$CFG_DEV_SUBNET" "$CFG_MGMT_SUBNET"; do
    if ! _valid_cidr "$cidr"; then
      test_fail "Invalid CIDR: ${cidr}"
      cidr_fail=1
    fi
  done
  if (( cidr_fail == 0 )); then
    test_pass "All subnets are valid CIDR"
  fi

  # MAC address validation
  local mac_fail=0
  for vm in "${CFG_VM_NAMES[@]}"; do
    local mac
    mac=$(yq ".vms.${vm}.mac" "$CONFIG_FILE")
    if ! _valid_mac "$mac"; then
      test_fail "Invalid MAC for ${vm}: ${mac} (must be 02:xx:xx:xx:xx:xx)"
      mac_fail=1
    fi
  done
  if (( mac_fail == 0 )); then
    test_pass "All MAC addresses use locally administered prefix (02:)"
  fi

  # dns_domain must NOT exist in config (derived from domain)
  local has_dns_domain
  has_dns_domain=$(yq '.environments.prod.dns_domain // ""' "$CONFIG_FILE")
  if [[ -n "$has_dns_domain" && "$has_dns_domain" != "null" ]]; then
    test_fail "environments.prod.dns_domain should not exist (derived from domain:)"
  else
    test_pass "No derived dns_domain fields in config (correctly derived from domain:)"
  fi

  # hardware.node_count matches actual nodes length
  if (( CFG_HW_NODE_COUNT != CFG_NODE_COUNT )); then
    test_fail "hardware.node_count (${CFG_HW_NODE_COUNT}) != actual node count (${CFG_NODE_COUNT})"
  else
    test_pass "hardware.node_count matches nodes list (${CFG_NODE_COUNT})"
  fi

  # Node count >= 2
  if (( CFG_NODE_COUNT < 2 )); then
    test_fail "Node count (${CFG_NODE_COUNT}) < 2 minimum"
  else
    test_pass "Node count >= 2 (${CFG_NODE_COUNT})"
  fi

  # hardware.total_ram_gb check
  local computed_total=0
  for ram in "${CFG_NODE_RAM[@]}"; do
    (( computed_total += ram ))
  done
  if (( CFG_HW_TOTAL_RAM != computed_total )); then
    test_fail "hardware.total_ram_gb (${CFG_HW_TOTAL_RAM}) != sum of node RAM (${computed_total})"
  else
    test_pass "hardware.total_ram_gb matches sum of node RAM (${computed_total})"
  fi

  # N+1 budget: operator-chosen VM commitment limit.
  # Warn if it exceeds min survivor RAM (would overcommit during node failure).
  local min_survivor=999999
  for (( i=0; i<CFG_NODE_COUNT; i++ )); do
    local survivor_ram=$(( computed_total - CFG_NODE_RAM[i] ))
    if (( survivor_ram < min_survivor )); then
      min_survivor=$survivor_ram
    fi
  done
  if (( CFG_HW_N1_BUDGET > min_survivor )); then
    test_warn "n_plus_1_budget_gb (${CFG_HW_N1_BUDGET}) exceeds min survivor RAM (${min_survivor}) — VMs would overcommit during a node failure"
  else
    test_pass "n_plus_1_budget_gb (${CFG_HW_N1_BUDGET}) within min survivor RAM (${min_survivor})"
  fi

  # Gateway IPs in their own subnets
  local gw_fail=0
  if ! _ip_in_subnet "$CFG_PROD_GATEWAY" "$CFG_PROD_SUBNET"; then
    test_fail "Prod gateway (${CFG_PROD_GATEWAY}) not in prod subnet (${CFG_PROD_SUBNET})"
    gw_fail=1
  fi
  if ! _ip_in_subnet "$CFG_DEV_GATEWAY" "$CFG_DEV_SUBNET"; then
    test_fail "Dev gateway (${CFG_DEV_GATEWAY}) not in dev subnet (${CFG_DEV_SUBNET})"
    gw_fail=1
  fi
  if ! _ip_in_subnet "$CFG_MGMT_GATEWAY" "$CFG_MGMT_SUBNET"; then
    test_fail "Mgmt gateway (${CFG_MGMT_GATEWAY}) not in mgmt subnet (${CFG_MGMT_SUBNET})"
    gw_fail=1
  fi
  if (( gw_fail == 0 )); then
    test_pass "All gateway IPs within their subnets"
  fi

  # Node and NAS IPs in management subnet
  local mgmt_fail=0
  for (( i=0; i<CFG_NODE_COUNT; i++ )); do
    if ! _ip_in_subnet "${CFG_NODE_IPS[$i]}" "$CFG_MGMT_SUBNET"; then
      test_fail "Node ${CFG_NODE_NAMES[$i]} (${CFG_NODE_IPS[$i]}) not in mgmt subnet (${CFG_MGMT_SUBNET})"
      mgmt_fail=1
    fi
  done
  if ! _ip_in_subnet "$CFG_NAS_IP" "$CFG_MGMT_SUBNET"; then
    test_fail "NAS (${CFG_NAS_IP}) not in mgmt subnet (${CFG_MGMT_SUBNET})"
    mgmt_fail=1
  fi
  if (( mgmt_fail == 0 )); then
    test_pass "All node and NAS IPs within management subnet (${CFG_MGMT_SUBNET})"
  fi

  # VM IPs in correct subnets
  local prod_vms=(dns1_prod dns2_prod vault_prod pbs cicd gatus)
  local dev_vms=(dns1_dev dns2_dev vault_dev pebble)
  local subnet_fail=0

  for vm in "${prod_vms[@]}"; do
    local vm_ip
    vm_ip=$(yq ".vms.${vm}.ip" "$CONFIG_FILE")
    if [[ "$vm_ip" != "null" ]] && ! _ip_in_subnet "$vm_ip" "$CFG_PROD_SUBNET"; then
      test_fail "VM ${vm} IP (${vm_ip}) not in prod subnet (${CFG_PROD_SUBNET})"
      subnet_fail=1
    fi
  done
  for vm in "${dev_vms[@]}"; do
    local vm_ip
    vm_ip=$(yq ".vms.${vm}.ip" "$CONFIG_FILE")
    if [[ "$vm_ip" != "null" ]] && ! _ip_in_subnet "$vm_ip" "$CFG_DEV_SUBNET"; then
      test_fail "VM ${vm} IP (${vm_ip}) not in dev subnet (${CFG_DEV_SUBNET})"
      subnet_fail=1
    fi
  done
  if (( subnet_fail == 0 )); then
    test_pass "All VM IPs in correct environment subnets"
  fi

  # SSH pubkey
  if [[ -z "$CFG_SSH_PUBKEY" || "$CFG_SSH_PUBKEY" == "null" ]]; then
    test_fail "operator_ssh_pubkey is empty"
  elif [[ "$CFG_SSH_PUBKEY" != ssh-* ]]; then
    test_fail "operator_ssh_pubkey doesn't start with 'ssh-'"
  else
    test_pass "operator_ssh_pubkey present and starts with 'ssh-'"
  fi
}
