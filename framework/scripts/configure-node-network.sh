#!/usr/bin/env bash
# configure-node-network.sh — Generate and deploy /etc/network/interfaces for Proxmox nodes
#
# Usage:
#   framework/scripts/configure-node-network.sh <node-name>
#   framework/scripts/configure-node-network.sh --all
#   framework/scripts/configure-node-network.sh --dry-run <node-name>
#   framework/scripts/configure-node-network.sh --dry-run --all
#   framework/scripts/configure-node-network.sh --verify [<node-name>|--all]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_PATH="${REPO_DIR}/site/config.yaml"
DRY_RUN=0
FORCE=0
VERIFY_ONLY=0
TARGET_NODE=""
ALL_NODES=0

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   CONFIG_PATH="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    --verify)   VERIFY_ONLY=1; shift ;;
    --all)      ALL_NODES=1; shift ;;
    -*)         echo "Unknown option: $1" >&2; exit 2 ;;
    *)          TARGET_NODE="$1"; shift ;;
  esac
done

if [[ $ALL_NODES -eq 0 && -z "$TARGET_NODE" ]]; then
  echo "Usage: $(basename "$0") [--dry-run] [--force] [--verify] [--config path] <node-name|--all>" >&2
  exit 2
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_PATH}" >&2
  exit 2
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not installed" >&2
  exit 2
fi

# --- Read global config ---
DOMAIN=$(yq '.domain' "$CONFIG_PATH")
MGMT_GATEWAY=$(yq '.management.gateway' "$CONFIG_PATH")
MGMT_PREFIX=$(yq '.management.subnet' "$CONFIG_PATH" | sed 's|.*/||')
NODE_COUNT=$(yq '.nodes | length' "$CONFIG_PATH")
REPL_TOPOLOGY=$(yq '.replication.topology // "mesh"' "$CONFIG_PATH")
REPL_HEALTH_PORT=$(yq '.replication.health_port // 9100' "$CONFIG_PATH")

# --- SSH helper ---
ssh_node() {
  local ip="$1"; shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

# --- NIC Auto-Discovery and Pinning ---
# Exit code 10 = reboot required (udev rules written, re-run after reboot)
EXIT_REBOOT_NEEDED=10
REBOOT_NEEDED=0
REBOOT_NODES=()

# Global discovery state — flat arrays for bash 3 compatibility
# Per-node physical NIC inventory
PHYS_NIC_NODES=()    # node name
PHYS_NIC_NAMES=()    # current kernel name
PHYS_NIC_MACS=()     # MAC address
PHYS_NIC_DRIVERS=()  # driver name

# Management NIC per node
MGMT_NIC_NODE=()     # node name
MGMT_NIC_MAC=()      # MAC address
MGMT_NIC_NAME=()     # current kernel name

# Candidate NICs (physical minus management)
CAND_NODES=()        # node name
CAND_NAMES=()        # current kernel name
CAND_MACS=()         # MAC address
CAND_ASSIGNED=()     # 0=available, 1=assigned

# Discovered mapping: MAC → config.yaml interface name
DISC_NODES=()        # node name
DISC_IFACE_NAMES=()  # config.yaml interface name (e.g., nic0, nic2, nic3)
DISC_MACS=()         # MAC that should be pinned to this name

# --- Phase 1: Inventory physical NICs on a node ---
inventory_physical_nics() {
  local idx="$1"
  local node_name mgmt_ip
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")

  echo "  ${node_name}: scanning physical NICs..."
  local nic_lines
  nic_lines=$(ssh_node "$mgmt_ip" '
    for iface_path in /sys/class/net/*/device/driver; do
      [ -e "$iface_path" ] || continue
      name=$(basename $(dirname $(dirname "$iface_path")))
      mac=$(cat /sys/class/net/$name/address)
      driver=$(basename $(readlink $iface_path))
      echo "$name $mac $driver"
    done
  ') || {
    echo ""
    echo "  ERROR: Could not reach ${node_name} at ${mgmt_ip} via SSH."
    echo "         Verify that:"
    echo "           - The node is powered on and booted"
    echo "           - The management IP (${mgmt_ip}) is correct in config.yaml"
    echo "           - The correct NIC is bridged in /etc/network/interfaces"
    echo "             (check 'bridge-ports' on the node's console)"
    echo "           - Your SSH key is installed on the node"
    return 1
  }

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name mac driver
    name=$(echo "$line" | awk '{print $1}')
    mac=$(echo "$line" | awk '{print $2}')
    driver=$(echo "$line" | awk '{print $3}')
    PHYS_NIC_NODES+=("$node_name")
    PHYS_NIC_NAMES+=("$name")
    PHYS_NIC_MACS+=("$mac")
    PHYS_NIC_DRIVERS+=("$driver")
    echo "    ${name}  mac=${mac}  driver=${driver}"
  done <<< "$nic_lines"
}

# --- Phase 2: Identify management NIC ---
identify_mgmt_nic() {
  local idx="$1"
  local node_name mgmt_ip
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")

  # Find which interface currently holds the management IP
  local mgmt_current_name
  mgmt_current_name=$(ssh_node "$mgmt_ip" "ip -o addr show | grep '${mgmt_ip}/' | awk '{print \$2}' | head -1")

  # If it's a bridge (vmbr0), find the bridge port instead
  if [[ "$mgmt_current_name" == vmbr* ]]; then
    mgmt_current_name=$(ssh_node "$mgmt_ip" "bridge link show dev ${mgmt_current_name} 2>/dev/null | head -1 | awk -F': ' '{print \$2}' | awk '{print \$1}'") || true
    # Fallback: check bridge-ports in interfaces file
    if [[ -z "$mgmt_current_name" || "$mgmt_current_name" == vmbr* ]]; then
      mgmt_current_name=$(ssh_node "$mgmt_ip" "grep 'bridge-ports' /etc/network/interfaces | awk '{print \$2}' | head -1") || true
    fi
  fi

  if [[ -z "$mgmt_current_name" ]]; then
    echo "  ERROR: Could not identify management NIC on ${node_name} (IP: ${mgmt_ip})"
    return 1
  fi

  # Look up the MAC in our inventory
  local mgmt_mac=""
  for (( i=0; i<${#PHYS_NIC_NODES[@]}; i++ )); do
    if [[ "${PHYS_NIC_NODES[$i]}" == "$node_name" && "${PHYS_NIC_NAMES[$i]}" == "$mgmt_current_name" ]]; then
      mgmt_mac="${PHYS_NIC_MACS[$i]}"
      break
    fi
  done

  if [[ -z "$mgmt_mac" ]]; then
    echo "  ERROR: Management NIC ${mgmt_current_name} on ${node_name} not found in physical NIC inventory"
    return 1
  fi

  MGMT_NIC_NODE+=("$node_name")
  MGMT_NIC_MAC+=("$mgmt_mac")
  MGMT_NIC_NAME+=("$mgmt_current_name")
  echo "  Management NIC on ${node_name}: ${mgmt_current_name} (mac=${mgmt_mac})"

  # Add to discovered mapping
  local mgmt_iface
  mgmt_iface=$(yq ".nodes[$idx].mgmt_iface" "$CONFIG_PATH")
  DISC_NODES+=("$node_name")
  DISC_IFACE_NAMES+=("$mgmt_iface")
  DISC_MACS+=("$mgmt_mac")
}

# --- Phase 3: Build candidate set ---
build_candidates() {
  local idx="$1"
  local node_name mgmt_ip
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")

  # Find management NIC MAC for this node
  local mgmt_mac=""
  for (( i=0; i<${#MGMT_NIC_NODE[@]}; i++ )); do
    if [[ "${MGMT_NIC_NODE[$i]}" == "$node_name" ]]; then
      mgmt_mac="${MGMT_NIC_MAC[$i]}"
      break
    fi
  done

  local cand_count=0
  for (( i=0; i<${#PHYS_NIC_NODES[@]}; i++ )); do
    if [[ "${PHYS_NIC_NODES[$i]}" == "$node_name" && "${PHYS_NIC_MACS[$i]}" != "$mgmt_mac" ]]; then
      CAND_NODES+=("$node_name")
      CAND_NAMES+=("${PHYS_NIC_NAMES[$i]}")
      CAND_MACS+=("${PHYS_NIC_MACS[$i]}")
      CAND_ASSIGNED+=(0)
      cand_count=$((cand_count + 1))
    fi
  done

  # Validate candidate count against required replication peers
  local peer_count
  peer_count=$(yq ".nodes[$idx].repl_peers | length" "$CONFIG_PATH")
  if [[ "$peer_count" != "0" && "$peer_count" != "null" && $cand_count -lt $peer_count ]]; then
    echo "  ERROR: ${node_name} has ${cand_count} candidate NIC(s) but config.yaml requires ${peer_count} replication interface(s)"
    return 1
  fi

  echo "  ${node_name}: ${cand_count} candidate NIC(s) for replication"
}

# --- Pre-probe safety: irdma blacklist and bring up candidates ---
pre_probe_safety() {
  local mgmt_ip="$1"
  local node_name="$2"

  # Deploy irdma blacklist and unload module
  ssh_node "$mgmt_ip" 'echo "blacklist irdma" > /etc/modprobe.d/no-irdma.conf; lsmod | grep -q irdma && rmmod irdma 2>/dev/null; true'

  # Bring up all candidate NICs for link detection
  for (( i=0; i<${#CAND_NODES[@]}; i++ )); do
    if [[ "${CAND_NODES[$i]}" == "$node_name" ]]; then
      ssh_node "$mgmt_ip" "ip link set dev ${CAND_NAMES[$i]} up 2>/dev/null" || true
    fi
  done
}

# --- Get candidate index for a node ---
# Returns indices into CAND_* arrays for unassigned candidates on this node
get_unassigned_candidates() {
  local node_name="$1"
  local result=()
  for (( i=0; i<${#CAND_NODES[@]}; i++ )); do
    if [[ "${CAND_NODES[$i]}" == "$node_name" && "${CAND_ASSIGNED[$i]}" == "0" ]]; then
      result+=("$i")
    fi
  done
  echo "${result[@]}"
}

# --- Phase 4a: Mesh link discovery ---
discover_mesh_links() {
  echo ""
  echo "--- Mesh Link Discovery ---"

  if [[ $NODE_COUNT -gt 4 ]]; then
    echo "  WARNING: ${NODE_COUNT} nodes with mesh topology. Consider switched topology for 5+ nodes."
  fi

  # Build list of unique node pairs from repl_peers
  # Process pairs where A < B (alphabetical) to avoid duplicates
  local pair_id=0
  local PAIR_A_IDX=()
  local PAIR_B_IDX=()
  local PAIR_A_IFACE=()  # config.yaml iface name on A for this link
  local PAIR_B_IFACE=()  # config.yaml iface name on B for this link

  for (( a=0; a<NODE_COUNT; a++ )); do
    local a_name
    a_name=$(yq ".nodes[$a].name" "$CONFIG_PATH")
    local peers
    peers=$(yq ".nodes[$a].repl_peers | keys | .[]" "$CONFIG_PATH" 2>/dev/null) || continue
    for peer_name in $peers; do
      local b_idx
      b_idx=$(find_node_index "$peer_name") || continue
      local b_name
      b_name=$(yq ".nodes[$b_idx].name" "$CONFIG_PATH")
      # Only process if A < B (alphabetical) to avoid duplicate pairs
      if [[ "$a_name" < "$b_name" ]]; then
        local a_iface b_iface
        a_iface=$(yq ".nodes[$a].repl_peers.${peer_name}.iface" "$CONFIG_PATH")
        b_iface=$(yq ".nodes[$b_idx].repl_peers.${a_name}.iface" "$CONFIG_PATH")
        pair_id=$((pair_id + 1))
        PAIR_A_IDX+=("$a")
        PAIR_B_IDX+=("$b_idx")
        PAIR_A_IFACE+=("$a_iface")
        PAIR_B_IFACE+=("$b_iface")
        echo "  Pair ${pair_id}: ${a_name} (${a_iface}) <-> ${b_name} (${b_iface})"
      fi
    done
  done

  local total_pairs=${#PAIR_A_IDX[@]}
  if [[ $total_pairs -eq 0 ]]; then
    echo "  No replication pairs declared in config.yaml"
    return 0
  fi

  # Probe each pair
  for (( p=0; p<total_pairs; p++ )); do
    local a_idx=${PAIR_A_IDX[$p]}
    local b_idx=${PAIR_B_IDX[$p]}
    local a_name a_ip b_name b_ip
    a_name=$(yq ".nodes[$a_idx].name" "$CONFIG_PATH")
    a_ip=$(yq ".nodes[$a_idx].mgmt_ip" "$CONFIG_PATH")
    b_name=$(yq ".nodes[$b_idx].name" "$CONFIG_PATH")
    b_ip=$(yq ".nodes[$b_idx].mgmt_ip" "$CONFIG_PATH")
    local pid=$((p + 1))
    local a_probe_ip="169.254.${pid}.1"
    local b_probe_ip="169.254.${pid}.2"

    echo ""
    echo "  Probing pair ${pid}: ${a_name} <-> ${b_name}..."

    # Get unassigned candidates for both nodes
    local a_cands b_cands
    read -ra a_cands <<< "$(get_unassigned_candidates "$a_name")"
    read -ra b_cands <<< "$(get_unassigned_candidates "$b_name")"

    if [[ ${#a_cands[@]} -eq 0 ]]; then
      echo "  ERROR: No unassigned candidate NICs on ${a_name} for link to ${b_name}"
      return 1
    fi
    if [[ ${#b_cands[@]} -eq 0 ]]; then
      echo "  ERROR: No unassigned candidate NICs on ${b_name} for link to ${a_name}"
      return 1
    fi

    local found=0
    for a_ci in "${a_cands[@]}"; do
      for b_ci in "${b_cands[@]}"; do
        local a_cand_name="${CAND_NAMES[$a_ci]}"
        local b_cand_name="${CAND_NAMES[$b_ci]}"
        # Probe silently — only report success

        # Assign temp IPs
        ssh_node "$a_ip" "ip addr add ${a_probe_ip}/30 dev ${a_cand_name} 2>/dev/null" || true
        ssh_node "$b_ip" "ip addr add ${b_probe_ip}/30 dev ${b_cand_name} 2>/dev/null" || true

        # Wait for link (DAC cables are usually instant, but allow settling)
        sleep 2

        # Probe
        if ssh_node "$a_ip" "ping -c 1 -W 2 ${b_probe_ip}" &>/dev/null; then
          echo "    Found: ${a_name}:${a_cand_name} <-> ${b_name}:${b_cand_name}"
          found=1

          # Record mappings
          DISC_NODES+=("$a_name")
          DISC_IFACE_NAMES+=("${PAIR_A_IFACE[$p]}")
          DISC_MACS+=("${CAND_MACS[$a_ci]}")

          DISC_NODES+=("$b_name")
          DISC_IFACE_NAMES+=("${PAIR_B_IFACE[$p]}")
          DISC_MACS+=("${CAND_MACS[$b_ci]}")

          # Mark as assigned
          CAND_ASSIGNED[$a_ci]=1
          CAND_ASSIGNED[$b_ci]=1

          # Clean up temp IPs
          ssh_node "$a_ip" "ip addr del ${a_probe_ip}/30 dev ${a_cand_name} 2>/dev/null" || true
          ssh_node "$b_ip" "ip addr del ${b_probe_ip}/30 dev ${b_cand_name} 2>/dev/null" || true
          break 2
        fi

        # Clean up temp IPs for failed probe
        ssh_node "$a_ip" "ip addr del ${a_probe_ip}/30 dev ${a_cand_name} 2>/dev/null" || true
        ssh_node "$b_ip" "ip addr del ${b_probe_ip}/30 dev ${b_cand_name} 2>/dev/null" || true
      done
    done

    if [[ $found -eq 0 ]]; then
      echo ""
      echo "  ERROR: No link detected between ${a_name} and ${b_name}."
      echo "         Verify that a DAC cable connects an SFP+ port on ${a_name}"
      echo "         to an SFP+ port on ${b_name}, and that both ports have link."
      return 1
    fi
  done

  echo ""
  echo "  All ${total_pairs} mesh link(s) discovered successfully"
}

# --- Phase 4b: Switched link discovery (stub) ---
discover_switched_links() {
  echo ""
  echo "  ERROR: Switched topology NIC discovery is not yet implemented."
  echo "  The config.yaml schema for switched topology has not been defined."
  echo "  Use mesh topology, or manually configure udev rules for switched."
  return 1
}

# --- Phase 5: Check existing NIC pinning ---
# Checks systemd .link files (Proxmox's naming mechanism) and
# installer-created files at /usr/local/lib/systemd/network/.
# Returns via stdout: CORRECT, INCORRECT, or MISSING
check_existing_pinning() {
  local idx="$1"
  local node_name mgmt_ip
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")

  # Build expected mapping for this node from DISC_* arrays
  local expected_names=()
  local expected_macs=()
  for (( i=0; i<${#DISC_NODES[@]}; i++ )); do
    if [[ "${DISC_NODES[$i]}" == "$node_name" ]]; then
      expected_names+=("${DISC_IFACE_NAMES[$i]}")
      expected_macs+=("${DISC_MACS[$i]}")
    fi
  done

  if [[ ${#expected_names[@]} -eq 0 ]]; then
    echo "CORRECT"  # No interfaces to pin
    return 0
  fi

  # Check each expected mapping against .link files
  # Search both /etc/systemd/network/ (our files) and
  # /usr/local/lib/systemd/network/ (installer files)
  local all_correct=1
  local has_any=0
  for (( i=0; i<${#expected_names[@]}; i++ )); do
    local mac="${expected_macs[$i]}"
    local name="${expected_names[$i]}"
    # Check if any .link file maps this MAC to this name
    local found
    found=$(ssh_node "$mgmt_ip" "
      for f in /etc/systemd/network/*.link /usr/local/lib/systemd/network/*.link; do
        [ -f \"\$f\" ] || continue
        if grep -qi '${mac}' \"\$f\" 2>/dev/null; then
          link_name=\$(grep -A1 '\\[Link\\]' \"\$f\" | grep 'Name=' | cut -d= -f2 | tr -d '[:space:]')
          if [ \"\$link_name\" = '${name}' ]; then
            echo 'MATCH'
            exit 0
          else
            echo 'WRONG'
            exit 0
          fi
        fi
      done
      echo 'NONE'
    ") || found="NONE"

    case "$found" in
      MATCH) has_any=1 ;;
      WRONG) has_any=1; all_correct=0 ;;
      NONE)  all_correct=0 ;;
    esac
  done

  if [[ $all_correct -eq 1 ]]; then
    echo "CORRECT"
  elif [[ $has_any -eq 1 ]]; then
    echo "INCORRECT"
  else
    echo "MISSING"
  fi
}

# --- Phase 5: Write systemd .link files for NIC pinning ---
# Proxmox uses systemd .link files (via 80-net-setup-link.rules) for
# interface naming. The installer creates them at
# /usr/local/lib/systemd/network/50-pmx-*.link. We write ours to
# /etc/systemd/network/ which takes precedence.
write_nic_pinning() {
  local idx="$1"
  local node_name mgmt_ip
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")

  echo "  Writing systemd .link files on ${node_name}..."

  # Ensure directory exists
  ssh_node "$mgmt_ip" "mkdir -p /etc/systemd/network"

  # Remove ALL installer .link files to prevent conflicts.
  # The installer creates /usr/local/lib/systemd/network/50-pmx-*.link
  # which may map different MACs to the same names we need.
  ssh_node "$mgmt_ip" "rm -f /usr/local/lib/systemd/network/50-pmx-*.link" || true

  for (( i=0; i<${#DISC_NODES[@]}; i++ )); do
    if [[ "${DISC_NODES[$i]}" == "$node_name" ]]; then
      local iface_name="${DISC_IFACE_NAMES[$i]}"
      local mac="${DISC_MACS[$i]}"
      local link_content="# Auto-generated by configure-node-network.sh
[Match]
MACAddress=${mac}
Type=ether

[Link]
Name=${iface_name}
"
      echo "$link_content" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
          "root@${mgmt_ip}" "cat > /etc/systemd/network/10-pmx-${iface_name}.link" 2>/dev/null
      echo "    ${iface_name} -> ${mac}"
    fi
  done

  # .link files must be in the initramfs to take effect during early boot
  echo "  Updating initramfs on ${node_name} (this takes a moment)..."
  ssh_node "$mgmt_ip" "update-initramfs -u >/dev/null 2>&1" || true

  echo "  .link files written on ${node_name}"
}

# --- Check pinning without discovery (uses config.yaml interface names) ---
# Used for the quick pre-check before full discovery.
# Verifies both that config.yaml interface names exist AND that the
# management NIC name matches the interface carrying the management IP.
check_pinning_from_config() {
  local idx="$1"
  local node_name mgmt_ip mgmt_iface
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")
  mgmt_iface=$(yq ".nodes[$idx].mgmt_iface" "$CONFIG_PATH")

  # Check if mgmt_iface exists
  if ! ssh_node "$mgmt_ip" "ip link show ${mgmt_iface}" &>/dev/null; then
    echo "NEEDS_DISCOVERY"
    return 0
  fi

  # Verify mgmt_iface is actually the NIC carrying the management IP.
  # Find the physical NIC behind vmbr0 and check its MAC matches mgmt_iface's MAC.
  local mgmt_carrier
  mgmt_carrier=$(ssh_node "$mgmt_ip" "ip -o addr show | grep '${mgmt_ip}/' | awk '{print \$2}' | head -1") || true
  if [[ "$mgmt_carrier" == vmbr* ]]; then
    # Get the MAC of the physical NIC behind the bridge
    local phys_mac
    phys_mac=$(ssh_node "$mgmt_ip" "ip -o link show master ${mgmt_carrier} 2>/dev/null | head -1 | sed 's/.*link\/ether //' | awk '{print \$1}'") || true
    # Get the MAC of mgmt_iface
    local iface_mac
    iface_mac=$(ssh_node "$mgmt_ip" "cat /sys/class/net/${mgmt_iface}/address 2>/dev/null") || true
    if [[ -n "$phys_mac" && -n "$iface_mac" && "$phys_mac" != "$iface_mac" ]]; then
      echo "NEEDS_DISCOVERY"
      return 0
    fi
  fi

  # Check replication interfaces exist
  local peer_count
  peer_count=$(yq ".nodes[$idx].repl_peers | length" "$CONFIG_PATH")
  if [[ "$peer_count" != "0" && "$peer_count" != "null" ]]; then
    local peers
    peers=$(yq ".nodes[$idx].repl_peers | keys | .[]" "$CONFIG_PATH")
    for peer_name in $peers; do
      local iface
      iface=$(yq ".nodes[$idx].repl_peers.${peer_name}.iface" "$CONFIG_PATH")
      if ! ssh_node "$mgmt_ip" "ip link show ${iface}" &>/dev/null; then
        echo "NEEDS_DISCOVERY"
        return 0
      fi
    done
  fi

  echo "OK"
}

# --- Ensure SSH key auth works on all nodes ---
# On fresh Proxmox installs, only password auth is available.
# Use sshpass with the SOPS password to install SSH keys on Proxmox nodes.
# Installs both the operator's workstation key (for interactive SSH) and the
# SOPS framework key (for CI runner access). This ensures both identities
# work regardless of which was generated first.
ensure_ssh_keys() {
  echo ""
  echo "=== Verifying SSH access ==="

  # Find operator's SSH public key
  local operator_pubkey=""
  for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
    if [[ -f "$keyfile" ]]; then
      operator_pubkey=$(cat "$keyfile")
      break
    fi
  done
  if [[ -z "$operator_pubkey" ]]; then
    echo "  ERROR: No SSH public key found (~/.ssh/id_*.pub)"
    echo "         Generate one with: ssh-keygen -t ed25519"
    return 1
  fi

  # Get SOPS framework key (for CI runner access)
  local sops_pubkey=""
  sops_pubkey=$(sops -d --extract '["ssh_pubkey"]' "${REPO_DIR}/site/sops/secrets.yaml" 2>/dev/null || true)

  local all_ok=1
  for idx in "${INDICES[@]}"; do
    local node_name mgmt_ip
    node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
    mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")

    # Test if key auth already works
    if ssh_node "$mgmt_ip" "true" 2>/dev/null; then
      echo "  ${node_name} (${mgmt_ip}): SSH key auth OK"
      # Even if operator key works, ensure SOPS key is also installed
      if [[ -n "$sops_pubkey" ]]; then
        local sops_key_id
        sops_key_id=$(echo "$sops_pubkey" | awk '{print $NF}')
        if ! ssh_node "$mgmt_ip" "grep -qF '${sops_key_id}' /root/.ssh/authorized_keys 2>/dev/null"; then
          ssh_node "$mgmt_ip" "echo '${sops_pubkey}' >> /root/.ssh/authorized_keys"
          echo "  ${node_name} (${mgmt_ip}): SOPS key added"
        fi
      fi
      continue
    fi

    # Key auth failed — try password auth to install the key
    echo "  ${node_name} (${mgmt_ip}): SSH key auth failed, installing keys via password..."

    if ! command -v sshpass &>/dev/null; then
      echo ""
      echo "  ERROR: sshpass is required to install SSH keys on fresh nodes."
      echo "         Install it with: brew install sshpass"
      echo "         Or manually run: ssh-copy-id root@${mgmt_ip}"
      all_ok=0
      continue
    fi

    # Get password from SOPS
    local sops_password
    sops_password=$(sops -d "${REPO_DIR}/site/sops/secrets.yaml" 2>/dev/null | yq '.proxmox_api_password') || {
      echo "  ERROR: Could not decrypt SOPS secrets. Check your age key."
      return 1
    }

    # Clear stale host keys from previous installs
    ssh-keygen -R "$mgmt_ip" 2>/dev/null || true

    # Build combined authorized_keys content
    local keys_to_install="$operator_pubkey"
    if [[ -n "$sops_pubkey" ]]; then
      keys_to_install="${keys_to_install}
${sops_pubkey}"
    fi

    if sshpass -p "$sops_password" ssh -o StrictHostKeyChecking=accept-new \
         -o ConnectTimeout=10 -o LogLevel=ERROR "root@${mgmt_ip}" \
         "mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo '${keys_to_install}' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys" 2>&1; then
      echo "  ${node_name} (${mgmt_ip}): SSH keys installed"
    else
      echo ""
      echo "  ERROR: Could not install SSH key on ${node_name} (${mgmt_ip})."
      echo "         Verify the node is reachable and the SOPS password matches"
      echo "         the Proxmox root password set during installation."
      all_ok=0
    fi
  done

  if [[ $all_ok -eq 0 ]]; then
    return 1
  fi
}

# Switch Proxmox nodes from enterprise to no-subscription repos.
# Only runs if proxmox.no_subscription_repo is true in config.yaml.
# Enterprise repos require a paid subscription and fail with 401.
# Idempotent: skips if already configured.
configure_repos() {
  local no_sub
  no_sub=$(yq '.proxmox.no_subscription_repo // false' "$CONFIG_PATH")
  if [[ "$no_sub" != "true" ]]; then
    return 0
  fi

  echo ""
  echo "=== Configuring APT repositories (no-subscription) ==="
  for idx in "${INDICES[@]}"; do
    local node_name mgmt_ip
    node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
    mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")

    # Check if no-subscription repo is already configured
    if ssh_node "$mgmt_ip" "test -f /etc/apt/sources.list.d/pve-no-subscription.list" 2>/dev/null; then
      echo "  ${node_name}: repos already configured"
      continue
    fi

    echo "  ${node_name}: switching to no-subscription repos..."
    ssh_node "$mgmt_ip" "
      rm -f /etc/apt/sources.list.d/pve-enterprise.list
      rm -f /etc/apt/sources.list.d/ceph.list
      echo 'deb http://download.proxmox.com/debian/pve trixie pve-no-subscription' > /etc/apt/sources.list.d/pve-no-subscription.list
    " 2>/dev/null && echo "  ${node_name}: repos configured" \
      || echo "  ${node_name}: WARNING: could not configure repos"
  done
}

# --- Top-level discovery orchestrator ---
run_discovery() {
  # Ensure SSH key auth works on all nodes (installs key if needed)
  ensure_ssh_keys || return 1

  # Switch to no-subscription repos (idempotent)
  configure_repos

  echo ""
  echo "=== NIC Discovery and Pinning ==="

  # Quick check: do all config.yaml interface names already exist?
  local needs_discovery=0
  for idx in "${INDICES[@]}"; do
    local node_name
    node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
    local status
    status=$(check_pinning_from_config "$idx")
    if [[ "$status" == "NEEDS_DISCOVERY" ]]; then
      echo "  ${node_name}: interface names not yet pinned — discovery needed"
      needs_discovery=1
    else
      echo "  ${node_name}: all config.yaml interface names present"
    fi
  done

  if [[ $needs_discovery -eq 0 ]]; then
    echo "  All interface pinning verified. Skipping discovery."
    return 0
  fi

  # Full discovery
  echo ""
  echo "--- Scanning NICs on all nodes ---"
  for idx in "${INDICES[@]}"; do
    inventory_physical_nics "$idx" || return 1
    identify_mgmt_nic "$idx" || return 1
    build_candidates "$idx" || return 1
  done

  # Pre-probe safety on all nodes
  echo ""
  echo "--- Preparing NICs for link probing ---"
  for idx in "${INDICES[@]}"; do
    local node_name mgmt_ip
    node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
    mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")
    pre_probe_safety "$mgmt_ip" "$node_name"
    echo "  ${node_name}: irdma blacklisted, candidate NICs brought up"
  done

  # Wait for link state to settle after bringing up interfaces
  echo "  Waiting 5s for link state to settle..."
  sleep 5

  # Topology-specific discovery
  local peer_count_total=0
  for idx in "${INDICES[@]}"; do
    local pc
    pc=$(yq ".nodes[$idx].repl_peers | length" "$CONFIG_PATH")
    if [[ "$pc" != "null" ]]; then
      peer_count_total=$((peer_count_total + pc))
    fi
  done

  if [[ $peer_count_total -gt 0 ]]; then
    if [[ "$REPL_TOPOLOGY" == "mesh" ]]; then
      discover_mesh_links || return 1
    elif [[ "$REPL_TOPOLOGY" == "switched" ]]; then
      discover_switched_links || return 1
    else
      echo "  ERROR: Unknown replication topology: ${REPL_TOPOLOGY}"
      return 1
    fi
  fi

  # Check existing pinning against discovered mapping and write rules if needed
  echo ""
  echo "--- Applying NIC name pinning ---"
  for idx in "${INDICES[@]}"; do
    local node_name mgmt_ip
    node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
    mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")
    local pinning_status
    pinning_status=$(check_existing_pinning "$idx")
    case "$pinning_status" in
      CORRECT)
        echo "  ${node_name}: .link files correct"
        # Also verify runtime names match — udev rules may be correct but
        # not yet applied (e.g., wrong priority on previous run, or no reboot)
        local runtime_ok=1
        for (( di=0; di<${#DISC_NODES[@]}; di++ )); do
          if [[ "${DISC_NODES[$di]}" == "$node_name" ]]; then
            local expected_name="${DISC_IFACE_NAMES[$di]}"
            local expected_mac="${DISC_MACS[$di]}"
            local actual_mac
            actual_mac=$(ssh_node "$mgmt_ip" "cat /sys/class/net/${expected_name}/address 2>/dev/null") || actual_mac=""
            if [[ "$actual_mac" != "$expected_mac" ]]; then
              echo "  ${node_name}: runtime name '${expected_name}' has wrong MAC (expected ${expected_mac}, got ${actual_mac:-missing})"
              runtime_ok=0
            fi
          fi
        done
        if [[ $runtime_ok -eq 1 ]]; then
          echo "  ${node_name}: runtime names verified"
        else
          echo "  ${node_name}: .link files correct but not applied — reboot needed"
          write_nic_pinning "$idx"
          REBOOT_NEEDED=1
          REBOOT_NODES+=("$node_name")
        fi
        ;;
      INCORRECT|MISSING)
        echo "  ${node_name}: pinning ${pinning_status} — writing .link files"
        write_nic_pinning "$idx"
        REBOOT_NEEDED=1
        REBOOT_NODES+=("$node_name")
        ;;
    esac
  done

  return 0
}

# --- Build a lookup table of node MAC addresses ---
# MAC_BY_NODE_IFACE["pve02:nic3"] = "38:05:25:37:31:05"
# Populated once during verify so we can identify peers by MAC.
declare_mac_table() {
  # On bash 3 (macOS) we can't use associative arrays, so use a flat list
  # and a lookup function instead.
  MAC_TABLE_KEYS=()
  MAC_TABLE_VALS=()
  for (( i=0; i<NODE_COUNT; i++ )); do
    local name mgmt_ip
    name=$(yq ".nodes[$i].name" "$CONFIG_PATH")
    mgmt_ip=$(yq ".nodes[$i].mgmt_ip" "$CONFIG_PATH")
    if ! ping -c 1 -W 2 "$mgmt_ip" &>/dev/null; then
      continue
    fi
    local mac_lines
    mac_lines=$(ssh_node "$mgmt_ip" "ip -br link show | grep -E '^nic' | awk '{print \$1, \$3}'") || continue
    while IFS= read -r line; do
      local iface mac
      iface=$(echo "$line" | awk '{print $1}')
      mac=$(echo "$line" | awk '{print $2}')
      MAC_TABLE_KEYS+=("${name}:${iface}")
      MAC_TABLE_VALS+=("$mac")
    done <<< "$mac_lines"
  done
}

# Look up which node:iface owns a given MAC address
mac_to_node_iface() {
  local target_mac="$1"
  for (( i=0; i<${#MAC_TABLE_KEYS[@]}; i++ )); do
    if [[ "${MAC_TABLE_VALS[$i]}" == "$target_mac" ]]; then
      echo "${MAC_TABLE_KEYS[$i]}"
      return 0
    fi
  done
  echo "unknown"
  return 1
}

# --- Generate /etc/network/interfaces for a node ---
generate_interfaces() {
  local idx="$1"
  local node_name mgmt_ip mgmt_iface
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")
  mgmt_iface=$(yq ".nodes[$idx].mgmt_iface" "$CONFIG_PATH")

  local timestamp
  timestamp=$(date -u '+%Y-%m-%d %H:%M UTC')

  # Collect VLAN IDs from all environments for bridge-vlans
  local vlan_ids
  vlan_ids=$(yq '.environments[].vlan_id' "$CONFIG_PATH" | sort -n | tr '\n' ' ' | sed 's/ $//')

  cat <<EOF
# Auto-generated by configure-node-network.sh from site/config.yaml
# Manual edits will be overwritten. Edit config.yaml instead.
# Generated: ${timestamp}

auto lo
iface lo inet loopback

auto ${mgmt_iface}
iface ${mgmt_iface} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${mgmt_ip}/${MGMT_PREFIX}
    gateway ${MGMT_GATEWAY}
    bridge-ports ${mgmt_iface}
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vlans ${vlan_ids}
EOF

  # bridge-vlans only applies VLANs to the bridge device (vmbr0 self), not
  # to the physical bridge port. Without explicit post-up hooks, VLAN-tagged
  # frames from VMs cannot exit through nic0 to the switch. This is lost on
  # every reboot because ifupdown2 does not propagate bridge-vlans to ports.
  for vid in $vlan_ids; do
    echo "    post-up bridge vlan add vid ${vid} dev ${mgmt_iface}"
  done

  # vmbr1: management bridge for VMs that need a NIC on the management
  # network (e.g., Roon for RAAT multicast). Uses a veth pair to bridge
  # untagged management traffic from vmbr0 to vmbr1. This avoids putting
  # two NICs on the same VLAN-aware bridge which causes MAC learning issues.
  cat <<'VMBR1_EOF'

auto veth-mgmt
iface veth-mgmt inet manual
    pre-up ip link add veth-mgmt type veth peer name veth-mgmt-br1 || true
    post-up ip link set veth-mgmt master vmbr0
    post-up ip link set veth-mgmt up
    post-up ip link set veth-mgmt-br1 up
    post-up bridge vlan add vid 1 pvid untagged dev veth-mgmt

auto vmbr1
iface vmbr1 inet manual
    bridge-ports veth-mgmt-br1
    bridge-stp off
    bridge-fd 0
VMBR1_EOF

  # Replication peers
  local peer_count
  peer_count=$(yq ".nodes[$idx].repl_peers | length" "$CONFIG_PATH")
  if [[ "$peer_count" != "0" && "$peer_count" != "null" ]]; then
    local repl_mtu
    repl_mtu=$(yq '.replication.mtu // 9000' "$CONFIG_PATH")

    local peers
    peers=$(yq ".nodes[$idx].repl_peers | keys | .[]" "$CONFIG_PATH")

    # Pre-compute route data (needed for both physical interfaces and dummy0)
    local repl_ip
    repl_ip=$(yq ".nodes[$idx].repl_ip" "$CONFIG_PATH")
    local peer_names=()
    local peer_ips=()       # peer_ip on point-to-point link
    local peer_ifaces=()    # local interface to that peer
    local peer_repl_ips=()  # peer's corosync /32 address

    if [[ -n "$repl_ip" && "$repl_ip" != "null" ]]; then
      for peer_name in $peers; do
        local p_ip p_iface p_repl_ip p_idx
        p_iface=$(yq ".nodes[$idx].repl_peers.${peer_name}.iface" "$CONFIG_PATH")
        p_ip=$(yq ".nodes[$idx].repl_peers.${peer_name}.peer_ip" "$CONFIG_PATH")
        p_idx=$(find_node_index "$peer_name") || true
        if [[ -n "$p_idx" ]]; then
          p_repl_ip=$(yq ".nodes[$p_idx].repl_ip" "$CONFIG_PATH")
        else
          p_repl_ip=""
        fi
        peer_names+=("$peer_name")
        peer_ips+=("$p_ip")
        peer_ifaces+=("$p_iface")
        peer_repl_ips+=("$p_repl_ip")
      done
    fi

    # Generate physical interface stanzas
    for peer_name in $peers; do
      local iface local_ip
      iface=$(yq ".nodes[$idx].repl_peers.${peer_name}.iface" "$CONFIG_PATH")
      local_ip=$(yq ".nodes[$idx].repl_peers.${peer_name}.local_ip" "$CONFIG_PATH")
      cat <<EOF

# Replication: ${node_name} <-> ${peer_name}
auto ${iface}
iface ${iface} inet static
    address ${local_ip}
    mtu ${repl_mtu}
EOF
      # Add post-up routes that use this interface — restores corosync routes
      # on link-up after a peer node reboot (kernel removes routes when link
      # goes down; without this, they are never re-added until ifreload/reboot)
      if [[ -n "$repl_ip" && "$repl_ip" != "null" ]]; then
        for (( p=0; p<${#peer_names[@]}; p++ )); do
          [[ -z "${peer_repl_ips[$p]}" || "${peer_repl_ips[$p]}" == "null" ]] && continue
          # Direct route (metric 100) via this interface
          if [[ "${peer_ifaces[$p]}" == "$iface" ]]; then
            echo "    post-up ip route replace ${peer_repl_ips[$p]}/32 via ${peer_ips[$p]} dev ${iface} metric 100 || true"
          fi
          # Fallback route (metric 200) via this interface
          for (( q=0; q<${#peer_names[@]}; q++ )); do
            if [[ $q -ne $p && "${peer_ifaces[$q]}" == "$iface" ]]; then
              echo "    post-up ip route replace ${peer_repl_ips[$p]}/32 via ${peer_ips[$q]} dev ${iface} metric 200 || true"
            fi
          done
        done
      fi
    done

    # dummy0 interface for corosync-routable address
    if [[ -n "$repl_ip" && "$repl_ip" != "null" ]]; then
      cat <<EOF

# Corosync-routable address (reachable by all nodes via dual-metric routes)
auto dummy0
iface dummy0 inet static
    address ${repl_ip}/32
    pre-up ip link add dummy0 type dummy || true
EOF

      # Dual-metric static routes to each peer's repl_ip
      # For each peer: direct route (metric 100) via point-to-point link,
      # fallback route (metric 200) via the other peer (third node relays)
      for (( p=0; p<${#peer_names[@]}; p++ )); do
        if [[ -z "${peer_repl_ips[$p]}" || "${peer_repl_ips[$p]}" == "null" ]]; then
          continue
        fi
        echo "    # Routes to ${peer_names[$p]}'s corosync address (${peer_repl_ips[$p]})"
        echo "    post-up ip route replace ${peer_repl_ips[$p]}/32 via ${peer_ips[$p]} dev ${peer_ifaces[$p]} metric 100 || true"

        # Fallback route via the other peer
        for (( q=0; q<${#peer_names[@]}; q++ )); do
          if [[ $q -ne $p ]]; then
            echo "    post-up ip route replace ${peer_repl_ips[$p]}/32 via ${peer_ips[$q]} dev ${peer_ifaces[$q]} metric 200 || true"
          fi
        done
      done
    fi
  fi
}

# --- Verify a single node ---
verify_node() {
  local idx="$1"
  local node_name mgmt_ip mgmt_iface
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")
  mgmt_iface=$(yq ".nodes[$idx].mgmt_iface" "$CONFIG_PATH")
  local fail=0

  echo ""
  echo "--- ${node_name} (${mgmt_ip}) ---"

  # Management reachability
  if ! ping -c 1 -W 3 "$mgmt_ip" &>/dev/null; then
    echo "  ✗ Management IP (${mgmt_ip}) UNREACHABLE"
    return 1
  fi
  echo "  ✓ Management IP (${mgmt_ip}) reachable"

  # Interface inventory: driver, PCI bus, speed, link state
  echo ""
  echo "  Interface details:"
  local iface_info
  iface_info=$(ssh_node "$mgmt_ip" "for nic in nic0 nic1 nic2 nic3; do
    if ip link show \$nic &>/dev/null; then
      driver=\$(ethtool -i \$nic 2>/dev/null | awk '/^driver:/{print \$2}')
      bus=\$(ethtool -i \$nic 2>/dev/null | awk '/^bus-info:/{print \$2}')
      speed=\$(ethtool \$nic 2>/dev/null | awk '/Speed:/{print \$2}')
      link=\$(ethtool \$nic 2>/dev/null | awk '/Link detected:/{print \$3}')
      state=\$(ip -br link show \$nic | awk '{print \$2}')
      addr=\$(ip -4 -br addr show \$nic 2>/dev/null | awk '{print \$3}')
      mac=\$(ip -br link show \$nic | awk '{print \$3}')
      printf '    %-5s  %-6s  %-14s  %10s  link=%-3s  state=%-4s  mac=%s  ip=%s\n' \
        \$nic \$driver \$bus \$speed \$link \$state \$mac \"\$addr\"
    fi
  done")
  echo "$iface_info"

  # Bridge VLAN awareness
  echo ""
  local vlan_aware
  vlan_aware=$(ssh_node "$mgmt_ip" "grep -c 'bridge-vlan-aware yes' /etc/network/interfaces 2>/dev/null") || vlan_aware=0
  if [[ "$vlan_aware" -ge 1 ]]; then
    echo "  ✓ bridge-vlan-aware yes in /etc/network/interfaces"
  else
    echo "  ✗ bridge-vlan-aware yes NOT found in /etc/network/interfaces"
    fail=1
  fi

  # Runtime VLAN check: verify each environment VLAN is active on the bridge port
  local vlan_output
  vlan_output=$(ssh_node "$mgmt_ip" "bridge vlan show dev ${mgmt_iface} 2>/dev/null") || vlan_output=""
  if [[ -n "$vlan_output" ]]; then
    local env_count vlan_fail=0
    env_count=$(yq '.environments | length' "$CONFIG_PATH")
    for (( e=0; e<env_count; e++ )); do
      local env_name vlan_id
      env_name=$(yq ".environments | keys | .[$e]" "$CONFIG_PATH")
      vlan_id=$(yq ".environments.${env_name}.vlan_id" "$CONFIG_PATH")
      if echo "$vlan_output" | grep -qw "$vlan_id"; then
        echo "  ✓ VLAN ${vlan_id} (${env_name}) active on ${mgmt_iface}"
      else
        echo "  ✗ VLAN ${vlan_id} (${env_name}) missing on ${mgmt_iface} — run configure-node-network.sh"
        vlan_fail=1
        fail=1
      fi
    done
  else
    echo "  ⊘ Could not query bridge VLANs on ${mgmt_iface}"
  fi

  # /etc/hosts entry
  local hosts_ok
  hosts_ok=$(ssh_node "$mgmt_ip" "grep -c '${node_name}' /etc/hosts 2>/dev/null") || hosts_ok=0
  if [[ "$hosts_ok" -ge 1 ]]; then
    echo "  ✓ /etc/hosts contains ${node_name}"
  else
    echo "  ✗ /etc/hosts missing ${node_name}"
    fail=1
  fi

  # /etc/resolv.conf
  local resolv_ok
  resolv_ok=$(ssh_node "$mgmt_ip" "grep -c 'nameserver ${MGMT_GATEWAY}' /etc/resolv.conf 2>/dev/null") || resolv_ok=0
  if [[ "$resolv_ok" -ge 1 ]]; then
    echo "  ✓ /etc/resolv.conf nameserver is ${MGMT_GATEWAY}"
  else
    echo "  ⊘ /etc/resolv.conf does not have nameserver ${MGMT_GATEWAY}"
  fi

  # Replication peers
  local peer_count
  peer_count=$(yq ".nodes[$idx].repl_peers | length" "$CONFIG_PATH")
  if [[ "$peer_count" != "0" && "$peer_count" != "null" ]]; then
    echo ""
    echo "  Replication links:"
    local peers
    peers=$(yq ".nodes[$idx].repl_peers | keys | .[]" "$CONFIG_PATH")
    for peer_name in $peers; do
      local iface peer_ip local_ip
      iface=$(yq ".nodes[$idx].repl_peers.${peer_name}.iface" "$CONFIG_PATH")
      peer_ip=$(yq ".nodes[$idx].repl_peers.${peer_name}.peer_ip" "$CONFIG_PATH")
      local_ip=$(yq ".nodes[$idx].repl_peers.${peer_name}.local_ip" "$CONFIG_PATH")

      # Check interface state
      local link_state
      link_state=$(ssh_node "$mgmt_ip" "ip -br link show ${iface} 2>/dev/null | awk '{print \$2}'" || echo "UNKNOWN")

      # Check physical link
      local link_detected
      link_detected=$(ssh_node "$mgmt_ip" "ethtool ${iface} 2>/dev/null | awk '/Link detected:/{print \$3}'" || echo "unknown")

      # Check IP assigned
      local assigned_ip
      assigned_ip=$(ssh_node "$mgmt_ip" "ip -4 -br addr show ${iface} 2>/dev/null | awk '{print \$3}'" || echo "")

      if [[ "$link_state" == "UP" ]]; then
        echo "  ✓ ${iface} is UP (link detected: ${link_detected})"
      else
        echo "  ✗ ${iface} is ${link_state} (link detected: ${link_detected})"
        fail=1
      fi

      if [[ "$assigned_ip" == "$local_ip" ]]; then
        echo "  ✓ ${iface} has correct IP: ${assigned_ip}"
      elif [[ -z "$assigned_ip" ]]; then
        echo "  ✗ ${iface} has no IP assigned (expected ${local_ip})"
        fail=1
      else
        echo "  ✗ ${iface} has wrong IP: ${assigned_ip} (expected ${local_ip})"
        fail=1
      fi

      # Ping peer
      if ssh_node "$mgmt_ip" "ping -c 1 -W 3 ${peer_ip}" &>/dev/null; then
        echo "  ✓ ${node_name} → ${peer_name} (${peer_ip}) reachable"
      else
        echo "  ✗ ${node_name} → ${peer_name} (${peer_ip}) NOT reachable"
        fail=1
      fi

      # Identify actual peer via IPv6 neighbor discovery
      local neighbor_mac
      neighbor_mac=$(ssh_node "$mgmt_ip" \
        "ping6 -c 1 -w 2 -I ${iface} ff02::1 >/dev/null 2>&1; ip -6 neigh show dev ${iface} 2>/dev/null" \
        | grep -v FAILED | head -1 | awk '{print $3}')
      if [[ -n "$neighbor_mac" ]]; then
        local actual_peer
        actual_peer=$(mac_to_node_iface "$neighbor_mac")
        local expected_peer_iface
        # Find what interface the peer uses for this node
        local peer_idx
        peer_idx=$(find_node_index "$peer_name") || true
        if [[ -n "$peer_idx" ]]; then
          expected_peer_iface=$(yq ".nodes[$peer_idx].repl_peers.${node_name}.iface" "$CONFIG_PATH" 2>/dev/null)
        fi
        if [[ "$actual_peer" == "${peer_name}:"* ]]; then
          local actual_iface="${actual_peer#*:}"
          if [[ -n "$expected_peer_iface" && "$actual_iface" == "$expected_peer_iface" ]]; then
            echo "  ✓ ${iface} physically connected to ${actual_peer} (matches config)"
          else
            echo "  ⊘ ${iface} physically connected to ${actual_peer} (config expects ${peer_name}:${expected_peer_iface})"
            fail=1
          fi
        else
          echo "  ⊘ ${iface} neighbor MAC ${neighbor_mac} → ${actual_peer} (expected ${peer_name})"
          fail=1
        fi
      else
        echo "  ⊘ ${iface} could not identify peer via IPv6 neighbor discovery"
      fi
    done

    # Corosync dummy0 interface
    local repl_ip
    repl_ip=$(yq ".nodes[$idx].repl_ip" "$CONFIG_PATH")
    if [[ -n "$repl_ip" && "$repl_ip" != "null" ]]; then
      echo ""
      echo "  Corosync address (dummy0):"
      local dummy_ip
      dummy_ip=$(ssh_node "$mgmt_ip" "ip -4 -br addr show dummy0 2>/dev/null | awk '{print \$3}'" || echo "")
      if [[ "$dummy_ip" == "${repl_ip}/32" ]]; then
        echo "  ✓ dummy0 has correct IP: ${dummy_ip}"
      elif [[ -z "$dummy_ip" ]]; then
        echo "  ✗ dummy0 has no IP (expected ${repl_ip}/32)"
        fail=1
      else
        echo "  ✗ dummy0 has wrong IP: ${dummy_ip} (expected ${repl_ip}/32)"
        fail=1
      fi

      # Check routes to each peer's repl_ip
      echo ""
      echo "  Static routes:"
      for peer_name in $peers; do
        local p_idx p_repl_ip
        p_idx=$(find_node_index "$peer_name") || true
        if [[ -n "$p_idx" ]]; then
          p_repl_ip=$(yq ".nodes[$p_idx].repl_ip" "$CONFIG_PATH")
          if [[ -n "$p_repl_ip" && "$p_repl_ip" != "null" ]]; then
            local route_count
            route_count=$(ssh_node "$mgmt_ip" "ip route show ${p_repl_ip}/32 2>/dev/null | wc -l" || echo "0")
            if [[ "$route_count" -ge 2 ]]; then
              echo "  ✓ Routes to ${peer_name} (${p_repl_ip}): ${route_count} entries (direct + fallback)"
            elif [[ "$route_count" -eq 1 ]]; then
              echo "  ⊘ Routes to ${peer_name} (${p_repl_ip}): only 1 entry (missing fallback?)"
              fail=1
            else
              echo "  ✗ No routes to ${peer_name} (${p_repl_ip})"
              fail=1
            fi
          fi
        fi
      done

      # Ping each peer's repl_ip
      echo ""
      echo "  Corosync reachability:"
      for peer_name in $peers; do
        local p_idx p_repl_ip
        p_idx=$(find_node_index "$peer_name") || true
        if [[ -n "$p_idx" ]]; then
          p_repl_ip=$(yq ".nodes[$p_idx].repl_ip" "$CONFIG_PATH")
          if [[ -n "$p_repl_ip" && "$p_repl_ip" != "null" ]]; then
            if ssh_node "$mgmt_ip" "ping -c 1 -W 3 ${p_repl_ip}" &>/dev/null; then
              echo "  ✓ ${node_name} → ${peer_name} corosync (${p_repl_ip}) reachable"
            else
              echo "  ✗ ${node_name} → ${peer_name} corosync (${p_repl_ip}) NOT reachable"
              fail=1
            fi
          fi
        fi
      done

      # ip_forward
      echo ""
      local ip_fwd
      ip_fwd=$(ssh_node "$mgmt_ip" "sysctl -n net.ipv4.ip_forward 2>/dev/null" || echo "0")
      if [[ "$ip_fwd" == "1" ]]; then
        echo "  ✓ ip_forward is enabled"
      else
        echo "  ✗ ip_forward is disabled (needed for cable failover relay)"
        fail=1
      fi
    fi

    # Monitoring services
    echo ""
    echo "  Monitoring:"

    if [[ "$REPL_TOPOLOGY" == "mesh" ]]; then
      local wd_active
      wd_active=$(ssh_node "$mgmt_ip" "systemctl is-active repl-watchdog.timer 2>/dev/null" || echo "unknown")
      if [[ "$wd_active" == "active" ]]; then
        echo "  ✓ repl-watchdog.timer is active"
      else
        echo "  ✗ repl-watchdog.timer is ${wd_active}"
        fail=1
      fi
    fi

    local health_active
    health_active=$(ssh_node "$mgmt_ip" "systemctl is-active repl-health.service 2>/dev/null" || echo "unknown")
    if [[ "$health_active" == "active" ]]; then
      echo "  ✓ repl-health.service is active"
    else
      echo "  ✗ repl-health.service is ${health_active}"
      fail=1
    fi

    local health_json
    health_json=$(ssh_node "$mgmt_ip" "curl -s http://localhost:${REPL_HEALTH_PORT}/health 2>/dev/null" || echo "")
    if [[ -n "$health_json" ]]; then
      local health_status
      health_status=$(echo "$health_json" | grep -o '"healthy": *[a-z]*' | head -1 | awk '{print $2}')
      if [[ "$health_status" == "true" ]]; then
        echo "  ✓ Health endpoint reports healthy"
      else
        echo "  ✗ Health endpoint reports unhealthy"
        fail=1
      fi
    else
      echo "  ✗ Health endpoint not responding on port ${REPL_HEALTH_PORT}"
      fail=1
    fi

    # iRDMA blacklist
    local irdma_loaded
    irdma_loaded=$(ssh_node "$mgmt_ip" "lsmod | grep -c irdma || true")
    if [[ "$irdma_loaded" -eq 0 ]]; then
      echo "  ✓ irdma module not loaded"
    else
      echo "  ⊘ irdma module still loaded (will be blocked on next reboot)"
    fi
  fi

  return $fail
}

# --- Deploy monitoring components to a node ---
deploy_monitoring() {
  local idx="$1"
  local node_name mgmt_ip
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")

  local peer_count
  peer_count=$(yq ".nodes[$idx].repl_peers | length" "$CONFIG_PATH")
  if [[ "$peer_count" == "0" || "$peer_count" == "null" ]]; then
    return 0  # No replication network — nothing to deploy
  fi

  local repl_ip
  repl_ip=$(yq ".nodes[$idx].repl_ip" "$CONFIG_PATH" 2>/dev/null)

  echo ""
  echo "  --- Monitoring components ---"

  # --- Clean up old watchdog artifacts if topology is not mesh ---
  if [[ "$REPL_TOPOLOGY" != "mesh" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would remove any old mesh watchdog units/files"
    else
      ssh_node "$mgmt_ip" "systemctl disable --now repl-watchdog.timer 2>/dev/null || true"
      ssh_node "$mgmt_ip" "rm -f /etc/systemd/system/repl-watchdog.service /etc/systemd/system/repl-watchdog.timer /usr/local/bin/repl-watchdog.sh /etc/repl-watchdog.conf 2>/dev/null || true"
      ssh_node "$mgmt_ip" "systemctl daemon-reload 2>/dev/null || true"
    fi
  fi

  # --- Generate /etc/repl-watchdog.conf (mesh only) ---
  if [[ "$REPL_TOPOLOGY" == "mesh" ]]; then
    local watchdog_conf="# Deployed by configure-node-network.sh — do not edit manually"$'\n'
    local peers
    peers=$(yq ".nodes[$idx].repl_peers | keys | .[]" "$CONFIG_PATH")
    for peer_name in $peers; do
      local peer_ip iface
      peer_ip=$(yq ".nodes[$idx].repl_peers.${peer_name}.peer_ip" "$CONFIG_PATH")
      iface=$(yq ".nodes[$idx].repl_peers.${peer_name}.iface" "$CONFIG_PATH")
      watchdog_conf+="PEER_${peer_name}_IP=${peer_ip}"$'\n'
      watchdog_conf+="PEER_${peer_name}_IFACE=${iface}"$'\n'
    done

    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would deploy /etc/repl-watchdog.conf:"
      echo "$watchdog_conf" | sed 's/^/    /'
    else
      echo "$watchdog_conf" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
          "root@${mgmt_ip}" "cat > /etc/repl-watchdog.conf" 2>/dev/null
      echo "  ✓ Deployed /etc/repl-watchdog.conf"
    fi
  fi

  # --- Generate /etc/repl-health.conf (both topologies) ---
  local health_conf="# Deployed by configure-node-network.sh — do not edit manually"$'\n'
  health_conf+="NODE_NAME=${node_name}"$'\n'
  health_conf+="NODE_REPL_IP=${repl_ip}"$'\n'
  health_conf+="HEALTH_PORT=${REPL_HEALTH_PORT}"$'\n'
  health_conf+="TOPOLOGY=${REPL_TOPOLOGY}"$'\n'

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would deploy /etc/repl-health.conf:"
    echo "$health_conf" | sed 's/^/    /'
  else
    echo "$health_conf" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
        "root@${mgmt_ip}" "cat > /etc/repl-health.conf" 2>/dev/null
    echo "  ✓ Deployed /etc/repl-health.conf"
  fi

  # --- Deploy scripts ---
  local scripts_to_deploy=("repl-health.sh" "repl-health-server.sh")
  if [[ "$REPL_TOPOLOGY" == "mesh" ]]; then
    scripts_to_deploy+=("repl-watchdog.sh")
  fi

  for script in "${scripts_to_deploy[@]}"; do
    local src="${SCRIPT_DIR}/${script}"
    if [[ ! -f "$src" ]]; then
      echo "  WARNING: ${src} not found — skipping"
      continue
    fi
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would deploy /usr/local/bin/${script}"
    else
      ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
          "root@${mgmt_ip}" "cat > /usr/local/bin/${script} && chmod +x /usr/local/bin/${script}" \
          < "$src" 2>/dev/null
      echo "  ✓ Deployed /usr/local/bin/${script}"
    fi
  done

  # --- Deploy systemd units ---

  # repl-health.service (both topologies)
  local health_service
  health_service=$(cat <<'UNIT'
[Unit]
Description=Replication health HTTP endpoint
After=network-online.target

[Service]
ExecStart=/usr/local/bin/repl-health-server.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
)

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would deploy repl-health.service"
  else
    echo "$health_service" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
        "root@${mgmt_ip}" "cat > /etc/systemd/system/repl-health.service" 2>/dev/null
    echo "  ✓ Deployed repl-health.service"
  fi

  # repl-watchdog.service and .timer (mesh only)
  if [[ "$REPL_TOPOLOGY" == "mesh" ]]; then
    local watchdog_service
    watchdog_service=$(cat <<'UNIT'
[Unit]
Description=Replication link watchdog
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/repl-watchdog.sh
UNIT
)
    local watchdog_timer
    watchdog_timer=$(cat <<'UNIT'
[Unit]
Description=Run replication link watchdog every 10s

[Timer]
OnBootSec=30s
OnUnitActiveSec=10s
AccuracySec=1s

[Install]
WantedBy=timers.target
UNIT
)

    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would deploy repl-watchdog.service and repl-watchdog.timer"
    else
      echo "$watchdog_service" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
          "root@${mgmt_ip}" "cat > /etc/systemd/system/repl-watchdog.service" 2>/dev/null
      echo "  ✓ Deployed repl-watchdog.service"

      echo "$watchdog_timer" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
          "root@${mgmt_ip}" "cat > /etc/systemd/system/repl-watchdog.timer" 2>/dev/null
      echo "  ✓ Deployed repl-watchdog.timer"
    fi
  fi

  # --- Enable and start services ---
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would daemon-reload and enable/start services"
  else
    ssh_node "$mgmt_ip" "systemctl daemon-reload"

    # Ensure socat is installed (needed by repl-health-server.sh)
    if ! ssh_node "$mgmt_ip" "command -v socat" &>/dev/null; then
      echo "  Installing socat..."
      ssh_node "$mgmt_ip" "apt-get install -y socat" &>/dev/null || true
    fi

    ssh_node "$mgmt_ip" "systemctl enable --now repl-health.service" &>/dev/null
    echo "  ✓ repl-health.service enabled and started"

    if [[ "$REPL_TOPOLOGY" == "mesh" ]]; then
      ssh_node "$mgmt_ip" "systemctl enable --now repl-watchdog.timer" &>/dev/null
      echo "  ✓ repl-watchdog.timer enabled and started"
    fi
  fi
}

# --- Deploy to a node ---
deploy_node() {
  local idx="$1"
  local node_name mgmt_ip
  node_name=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
  mgmt_ip=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")

  echo ""
  echo "=== ${node_name} (${mgmt_ip}) ==="

  # Check reachability
  if ! ping -c 1 -W 3 "$mgmt_ip" &>/dev/null; then
    echo "  ERROR: ${node_name} (${mgmt_ip}) is not reachable"
    return 1
  fi

  # Check if node is already in a cluster
  if [[ $FORCE -eq 0 ]]; then
    local cluster_status
    cluster_status=$(ssh_node "$mgmt_ip" "pvecm status 2>/dev/null" || true)
    if echo "$cluster_status" | grep -q "Cluster information"; then
      echo "  ERROR: ${node_name} is already in a cluster. Use --force to override."
      return 1
    fi
  fi

  # Generate interfaces file
  local interfaces_content
  interfaces_content=$(generate_interfaces "$idx")

  # Determine if this node needs ip_forward (has replication peers with repl_ip)
  local needs_forward=0
  local repl_ip
  repl_ip=$(yq ".nodes[$idx].repl_ip" "$CONFIG_PATH" 2>/dev/null)
  local peer_count_for_fwd
  peer_count_for_fwd=$(yq ".nodes[$idx].repl_peers | length" "$CONFIG_PATH")
  if [[ -n "$repl_ip" && "$repl_ip" != "null" && "$peer_count_for_fwd" != "0" && "$peer_count_for_fwd" != "null" ]]; then
    needs_forward=1
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would deploy /etc/network/interfaces:"
    echo "$interfaces_content" | sed 's/^/    /'
    echo ""
    if [[ $needs_forward -eq 1 ]]; then
      echo "  [DRY RUN] Would deploy /etc/sysctl.d/90-repl-forward.conf: net.ipv4.ip_forward=1"
    fi
    echo "  [DRY RUN] Would deploy /etc/modprobe.d/no-irdma.conf (blacklist irdma)"
    echo "  [DRY RUN] Would update /etc/hosts with: ${mgmt_ip} ${node_name}.admin.${DOMAIN} ${node_name}"
    echo "  [DRY RUN] Would set /etc/resolv.conf nameserver to: ${MGMT_GATEWAY}"
    echo "  [DRY RUN] Would set /etc/issue URL to: https://${mgmt_ip}:8006/"
    deploy_monitoring "$idx"
    return 0
  fi

  # Validate interface names exist on the target
  local mgmt_iface
  mgmt_iface=$(yq ".nodes[$idx].mgmt_iface" "$CONFIG_PATH")
  if ! ssh_node "$mgmt_ip" "ip link show ${mgmt_iface}" &>/dev/null; then
    echo "  WARNING: Interface ${mgmt_iface} not found on ${node_name}"
  fi

  local peer_count
  peer_count=$(yq ".nodes[$idx].repl_peers | length" "$CONFIG_PATH")
  if [[ "$peer_count" != "0" && "$peer_count" != "null" ]]; then
    local peers
    peers=$(yq ".nodes[$idx].repl_peers | keys | .[]" "$CONFIG_PATH")
    for peer_name in $peers; do
      local iface
      iface=$(yq ".nodes[$idx].repl_peers.${peer_name}.iface" "$CONFIG_PATH")
      if ! ssh_node "$mgmt_ip" "ip link show ${iface}" &>/dev/null; then
        echo "  WARNING: Interface ${iface} (for ${peer_name} link) not found on ${node_name}"
      fi
    done
  fi

  # Backup existing interfaces
  local timestamp
  timestamp=$(date -u '+%Y%m%d%H%M%S')
  echo "  Backing up /etc/network/interfaces → /etc/network/interfaces.bak.${timestamp}"
  ssh_node "$mgmt_ip" "cp /etc/network/interfaces /etc/network/interfaces.bak.${timestamp}"

  # Deploy new interfaces file
  echo "  Deploying /etc/network/interfaces"
  # Use ssh directly (without -n) because we need to pipe content via stdin.
  # ssh_node uses -n to prevent stdin consumption in loops, but here we
  # intentionally pipe the interfaces content.
  echo "$interfaces_content" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${mgmt_ip}" "cat > /etc/network/interfaces" 2>/dev/null

  # Deploy ip_forward sysctl if needed
  if [[ $needs_forward -eq 1 ]]; then
    echo "  Deploying /etc/sysctl.d/90-repl-forward.conf (ip_forward=1)"
    ssh_node "$mgmt_ip" "echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/90-repl-forward.conf"
    ssh_node "$mgmt_ip" "sysctl -p /etc/sysctl.d/90-repl-forward.conf" || true
  fi

  # Deploy irdma blacklist (both topologies)
  echo "  Deploying /etc/modprobe.d/no-irdma.conf"
  ssh_node "$mgmt_ip" "cat > /etc/modprobe.d/no-irdma.conf << 'IRDMA'
# Deployed by configure-node-network.sh
# Intel irdma module causes silent link failures on E810 NICs when idle.
# Remove this file only if RDMA workloads are needed — use Intel's
# out-of-tree driver instead of the upstream kernel module.
blacklist irdma
IRDMA"
  # Unload from running kernel if currently loaded
  ssh_node "$mgmt_ip" "rmmod irdma 2>/dev/null || true"

  # Update /etc/hosts
  echo "  Updating /etc/hosts"
  ssh_node "$mgmt_ip" "sed -i '/${node_name}/d' /etc/hosts; echo '${mgmt_ip} ${node_name}.admin.${DOMAIN} ${node_name}' >> /etc/hosts"

  # Update /etc/resolv.conf
  echo "  Updating /etc/resolv.conf"
  ssh_node "$mgmt_ip" "echo 'nameserver ${MGMT_GATEWAY}' > /etc/resolv.conf"

  # Update /etc/issue
  echo "  Updating /etc/issue"
  ssh_node "$mgmt_ip" "echo 'https://${mgmt_ip}:8006/' > /etc/issue"

  # Reload networking
  echo "  Running ifreload -a"
  ssh_node "$mgmt_ip" "ifreload -a" || true

  # ifreload -a applies bridge-vlans to vmbr0 (self) but not to the physical
  # bridge port. Without this, VLAN-tagged frames can't exit the bridge to the
  # switch. A full reboot handles it, but live reload needs explicit fixup.
  local vlan_ids_apply
  vlan_ids_apply=$(yq '.environments[].vlan_id' "$CONFIG_PATH" | sort -n)
  for vid in $vlan_ids_apply; do
    echo "  Adding VLAN $vid to bridge port ${mgmt_iface}"
    ssh_node "$mgmt_ip" "bridge vlan add vid $vid dev ${mgmt_iface}" || true
  done

  echo "  Waiting 5 seconds..."
  sleep 5

  # Quick reachability check before full verify
  if ! ping -c 1 -W 5 "$mgmt_ip" &>/dev/null; then
    echo "  ✗ Management IP (${mgmt_ip}) UNREACHABLE after deploy!"
    echo ""
    echo "  RECOVERY: Access the console and restore from backup:"
    echo "    cp /etc/network/interfaces.bak.${timestamp} /etc/network/interfaces"
    echo "    ifreload -a"
    return 1
  fi

  echo "  Deploy complete."
  return 0
}

# --- Find node index by name ---
find_node_index() {
  local name="$1"
  for (( i=0; i<NODE_COUNT; i++ )); do
    local n
    n=$(yq ".nodes[$i].name" "$CONFIG_PATH")
    if [[ "$n" == "$name" ]]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

# --- Collect node indices to operate on ---
collect_indices() {
  INDICES=()
  if [[ $ALL_NODES -eq 1 ]]; then
    for (( i=0; i<NODE_COUNT; i++ )); do
      INDICES+=("$i")
    done
  else
    local idx
    idx=$(find_node_index "$TARGET_NODE")
    if [[ $? -ne 0 ]]; then
      echo "ERROR: Node '${TARGET_NODE}' not found in config" >&2
      exit 2
    fi
    INDICES+=("$idx")
  fi
}

# --- Main ---
collect_indices

if [[ $VERIFY_ONLY -eq 1 ]]; then
  echo ""
  echo "=== Network Verification ==="
  echo "  Building MAC address table across all nodes..."
  declare_mac_table
  FAILED=0
  for idx in "${INDICES[@]}"; do
    verify_node "$idx" || FAILED=1
  done
  echo ""
  if [[ $FAILED -eq 0 ]]; then
    echo "All checks passed."
    exit 0
  else
    echo "Some checks failed. See above."
    exit 1
  fi
fi

# NIC Discovery and Pinning (before deploy)
if [[ $DRY_RUN -eq 0 ]]; then
  if ! run_discovery; then
    echo ""
    echo "NIC discovery failed. See errors above."
    exit 1
  fi
  if [[ $REBOOT_NEEDED -eq 1 ]]; then
    echo ""
    echo "=== Rebooting nodes to apply NIC name changes ==="
    echo ""
    echo "  NIC names have been configured. A reboot is required for the"
    echo "  new names to take effect. The script will reboot the affected"
    echo "  nodes, wait for them to come back, and then continue."
    echo ""
    echo "  Nodes to reboot:"
    for node in "${REBOOT_NODES[@]}"; do
      echo "    - $node"
    done

    # Before rebooting, deploy a minimal /etc/network/interfaces using
    # the NEW interface names so networking works after reboot.
    for idx in "${INDICES[@]}"; do
      REBOOT_NODE_NAME=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
      REBOOT_MGMT_IP=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")
      for rn in "${REBOOT_NODES[@]}"; do
        if [[ "$rn" == "$REBOOT_NODE_NAME" ]]; then
          REBOOT_MGMT_IFACE=$(yq ".nodes[$idx].mgmt_iface" "$CONFIG_PATH")
          echo "  Pre-deploying network config on ${REBOOT_NODE_NAME} (using new name: ${REBOOT_MGMT_IFACE})..."
          REBOOT_IFACES_CONTENT=$(generate_interfaces "$idx")
          echo "$REBOOT_IFACES_CONTENT" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
              "root@${REBOOT_MGMT_IP}" "cat > /etc/network/interfaces" 2>/dev/null
        fi
      done
    done

    # Reboot affected nodes
    for idx in "${INDICES[@]}"; do
      REBOOT_NODE_NAME=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
      REBOOT_MGMT_IP=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")
      for rn in "${REBOOT_NODES[@]}"; do
        if [[ "$rn" == "$REBOOT_NODE_NAME" ]]; then
          echo "  Rebooting ${REBOOT_NODE_NAME} (${REBOOT_MGMT_IP})..."
          ssh_node "$REBOOT_MGMT_IP" "reboot" || true
        fi
      done
    done

    echo "  Waiting 30s for nodes to shut down..."
    sleep 30

    # Wait for SSH on all rebooted nodes
    for idx in "${INDICES[@]}"; do
      REBOOT_NODE_NAME=$(yq ".nodes[$idx].name" "$CONFIG_PATH")
      REBOOT_MGMT_IP=$(yq ".nodes[$idx].mgmt_ip" "$CONFIG_PATH")
      for rn in "${REBOOT_NODES[@]}"; do
        if [[ "$rn" == "$REBOOT_NODE_NAME" ]]; then
          echo -n "  Waiting for ${REBOOT_NODE_NAME} (${REBOOT_MGMT_IP})..."
          REBOOT_WAIT=0
          while [[ $REBOOT_WAIT -lt 30 ]]; do
            if ssh_node "$REBOOT_MGMT_IP" "true" 2>/dev/null; then
              echo " up"
              break
            fi
            sleep 10
            REBOOT_WAIT=$((REBOOT_WAIT + 1))
            echo -n "."
          done
          if [[ $REBOOT_WAIT -ge 30 ]]; then
            echo " TIMEOUT"
            echo "ERROR: ${REBOOT_NODE_NAME} did not come back after reboot (waited 5 minutes)"
            exit 1
          fi
        fi
      done
    done

    # Re-run discovery to verify pinning applied correctly
    echo ""
    echo "=== Verifying NIC names after reboot ==="
    REBOOT_NEEDED=0
    REBOOT_NODES=()
    # Clear discovery state for re-run
    DISC_NODES=()
    DISC_IFACE_NAMES=()
    DISC_MACS=()
    PHYS_NIC_NODES=()
    PHYS_NIC_NAMES=()
    PHYS_NIC_MACS=()
    PHYS_NIC_DRIVERS=()
    MGMT_NIC_NODE=()
    MGMT_NIC_MAC=()
    MGMT_NIC_NAME=()
    CAND_NODES=()
    CAND_NAMES=()
    CAND_MACS=()
    CAND_ASSIGNED=()

    if ! run_discovery; then
      echo ""
      echo "NIC discovery failed after reboot. See errors above."
      exit 1
    fi
    if [[ $REBOOT_NEEDED -eq 1 ]]; then
      echo ""
      echo "ERROR: NIC names still incorrect after reboot."
      echo ""
      echo "  Affected nodes: ${REBOOT_NODES[*]}"
      echo ""
      echo "  This usually means the .link files were not included in the"
      echo "  initramfs. On each affected node, try:"
      echo "    update-initramfs -u"
      echo "    reboot"
      echo ""
      echo "  Then re-run this script."
      exit 1
    fi
  fi
fi

# Deploy mode
FAILED=0
for idx in "${INDICES[@]}"; do
  deploy_node "$idx" || FAILED=1
done

if [[ $FAILED -ne 0 ]]; then
  echo ""
  echo "Some nodes failed during deploy. See errors above."
  exit 1
fi

# Deploy monitoring components (after all network deploys succeed)
echo ""
echo "=== Monitoring Deployment ==="
for idx in "${INDICES[@]}"; do
  deploy_monitoring "$idx" || true
done

# After all deploys succeed, run full verification
echo ""
echo "=== Post-Deploy Verification ==="
echo "  Building MAC address table across all nodes..."
declare_mac_table

VERIFY_FAILED=0
for idx in "${INDICES[@]}"; do
  verify_node "$idx" || VERIFY_FAILED=1
done

echo ""
if [[ $VERIFY_FAILED -eq 0 ]]; then
  echo "All nodes configured and verified successfully."
  exit 0
else
  echo "Deploy succeeded but some verification checks failed. See above."
  exit 1
fi
