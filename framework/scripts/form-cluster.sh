#!/usr/bin/env bash
# form-cluster.sh — Automate Proxmox cluster creation and node joining
#
# Usage:
#   framework/scripts/form-cluster.sh
#   framework/scripts/form-cluster.sh --dry-run
#   framework/scripts/form-cluster.sh --force

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_PATH="${REPO_DIR}/site/config.yaml"
DRY_RUN=0
FORCE=0
ERRORS=0

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   CONFIG_PATH="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --force)    FORCE=1; shift ;;
    -*)         echo "Unknown option: $1" >&2; exit 2 ;;
    *)          echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_PATH}" >&2
  exit 2
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not installed" >&2
  exit 2
fi

# --- Read config ---
DOMAIN=$(yq '.domain' "$CONFIG_PATH")
NODE_COUNT=$(yq '.nodes | length' "$CONFIG_PATH")

# Build node arrays
NODE_NAMES=()
NODE_IPS=()
NODE_REPL_IPS=()
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAMES+=("$(yq ".nodes[$i].name" "$CONFIG_PATH")")
  NODE_IPS+=("$(yq ".nodes[$i].mgmt_ip" "$CONFIG_PATH")")
  NODE_REPL_IPS+=("$(yq ".nodes[$i].repl_ip // \"\"" "$CONFIG_PATH")")
done

# Determine if replication network is configured (nodes have repl_ip)
HAS_REPL=0
for (( i=0; i<NODE_COUNT; i++ )); do
  if [[ -n "${NODE_REPL_IPS[$i]}" && "${NODE_REPL_IPS[$i]}" != "null" ]]; then
    HAS_REPL=1
    break
  fi
done

# --- Resolve cluster name ---
CLUSTER_NAME_SETTING=$(yq '.cluster.name // "AUTO"' "$CONFIG_PATH")

if [[ "$CLUSTER_NAME_SETTING" == "AUTO" ]]; then
  # Extract part before first dot, lowercase, replace invalid chars with hyphen
  CLUSTER_NAME="${DOMAIN%%.*}"
  CLUSTER_NAME=$(echo "$CLUSTER_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/^-*//; s/-*$//')
else
  CLUSTER_NAME="$CLUSTER_NAME_SETTING"
fi

# Validate cluster name
CLUSTER_NAME_ERROR=""
if [[ ${#CLUSTER_NAME} -gt 15 ]]; then
  CLUSTER_NAME_ERROR="name is ${#CLUSTER_NAME} characters (max 15)"
elif [[ ${#CLUSTER_NAME} -eq 0 ]]; then
  CLUSTER_NAME_ERROR="name is empty"
elif [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ && ${#CLUSTER_NAME} -gt 1 ]]; then
  CLUSTER_NAME_ERROR="contains invalid characters or starts/ends with hyphen"
elif [[ ${#CLUSTER_NAME} -eq 1 && ! "$CLUSTER_NAME" =~ ^[a-z0-9]$ ]]; then
  CLUSTER_NAME_ERROR="contains invalid characters"
fi

if [[ -n "$CLUSTER_NAME_ERROR" ]]; then
  cat >&2 <<EOF
ERROR: Cluster name "${CLUSTER_NAME}" is invalid (${CLUSTER_NAME_ERROR}).

Proxmox/corosync cluster names must be:
  - 15 characters or fewer
  - Contain only lowercase letters, digits, and hyphens
  - Not start or end with a hyphen

The auto-generated name from domain "${DOMAIN}" does not meet these constraints.
Please set 'cluster.name' in site/config.yaml to a valid short name.

Example:
  cluster:
    name: homelab
EOF
  exit 2
fi

# --- SSH helper ---
ssh_node() {
  local ip="$1"; shift
  ssh -n -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@"
}

# --- Corosync link addressing ---
# Each node's repl_ip (dummy0 /32) is used as corosync link0 (primary).
# The management IP is used as link1 (fallback).
# The repl_ip is routable by all nodes via dual-metric static routes
# configured by configure-node-network.sh.

# --- Banner ---
echo "=== Proxmox Cluster Formation ==="
echo "Cluster name: ${CLUSTER_NAME}"
echo "Nodes: ${NODE_NAMES[*]}"
if [[ $HAS_REPL -eq 1 ]]; then
  echo "Corosync link0 (replication): ${NODE_REPL_IPS[*]}"
  echo "Corosync link1 (management):  ${NODE_IPS[*]}"
fi
echo ""

# --- Pre-flight checks ---
echo "--- Pre-flight checks ---"
for (( i=0; i<NODE_COUNT; i++ )); do
  if ! ping -c 1 -W 3 "${NODE_IPS[$i]}" &>/dev/null; then
    echo "  ✗ ${NODE_NAMES[$i]} (${NODE_IPS[$i]}) — not reachable"
    echo "ERROR: All nodes must be reachable. Aborting." >&2
    exit 1
  fi
  echo "  ✓ ${NODE_NAMES[$i]} (${NODE_IPS[$i]}) — reachable"
done

# Check each node's cluster state
FIRST_NODE_HAS_CLUSTER=0
NODES_NEEDING_JOIN=()
for (( i=0; i<NODE_COUNT; i++ )); do
  local_status=$(ssh_node "${NODE_IPS[$i]}" "pvecm status 2>/dev/null" || true)
  if echo "$local_status" | grep -q "Cluster information"; then
    existing_name=$(echo "$local_status" | awk '/^Name:/{print $2}')
    if [[ "$existing_name" == "$CLUSTER_NAME" ]]; then
      echo "  ✓ ${NODE_NAMES[$i]} — already in cluster '${CLUSTER_NAME}'"
      if [[ $i -eq 0 ]]; then
        FIRST_NODE_HAS_CLUSTER=1
      fi
    else
      echo "  ✗ ${NODE_NAMES[$i]} — in different cluster: '${existing_name}'"
      echo "ERROR: Node is in a different cluster. Resolve manually." >&2
      exit 1
    fi
  else
    if [[ $i -eq 0 ]]; then
      echo "  ○ ${NODE_NAMES[$i]} — not clustered (will create)"
    else
      echo "  ○ ${NODE_NAMES[$i]} — not clustered (will join)"
    fi
    NODES_NEEDING_JOIN+=($i)
  fi
done
echo ""

# --- SSH key pre-distribution ---
# pvecm add --use_ssh requires the joining node to SSH into the cluster node.
# After join, Proxmox merges all keys into /etc/pve/priv/authorized_keys.
# We pre-distribute keys so --use_ssh works non-interactively.
echo "--- SSH key distribution ---"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "  SSH key distribution plan:"
  echo "    Collect id_rsa.pub from: ${NODE_NAMES[*]}"
  for (( i=0; i<NODE_COUNT; i++ )); do
    others=""
    for (( j=0; j<NODE_COUNT; j++ )); do
      if [[ $j -ne $i ]]; then
        others="${others:+${others}, }${NODE_NAMES[$j]}"
      fi
    done
    echo "    Deploy to ${NODE_NAMES[$i]}: keys from ${others}"
  done
  echo ""
else
  # Collect public keys from all nodes
  NODE_PUBKEYS=()
  for (( i=0; i<NODE_COUNT; i++ )); do
    pubkey=$(ssh_node "${NODE_IPS[$i]}" "cat /root/.ssh/id_rsa.pub 2>/dev/null") || true
    if [[ -z "$pubkey" ]]; then
      echo "  ✗ Could not read /root/.ssh/id_rsa.pub from ${NODE_NAMES[$i]}"
      exit 1
    fi
    NODE_PUBKEYS+=("$pubkey")
    echo "  ✓ Collected public key from ${NODE_NAMES[$i]}"
  done

  # Collect host keys via ssh-keyscan
  NODE_HOSTKEYS=()
  for (( i=0; i<NODE_COUNT; i++ )); do
    hostkeys=$(ssh-keyscan -H "${NODE_IPS[$i]}" 2>/dev/null) || true
    # Also scan by hostname
    hostkeys_name=$(ssh-keyscan -H "${NODE_NAMES[$i]}" 2>/dev/null) || true
    NODE_HOSTKEYS+=("${hostkeys}"$'\n'"${hostkeys_name}")
    echo "  ✓ Scanned host keys from ${NODE_NAMES[$i]} (${NODE_IPS[$i]})"
  done

  # Deploy keys to each node
  for (( i=0; i<NODE_COUNT; i++ )); do
    for (( j=0; j<NODE_COUNT; j++ )); do
      if [[ $j -ne $i ]]; then
        # Append public key if not already present
        ssh_node "${NODE_IPS[$i]}" \
          "grep -qF '${NODE_PUBKEYS[$j]}' /root/.ssh/authorized_keys 2>/dev/null || echo '${NODE_PUBKEYS[$j]}' >> /root/.ssh/authorized_keys"

        # Append host keys if not already present
        while IFS= read -r hk_line; do
          [[ -z "$hk_line" ]] && continue
          ssh_node "${NODE_IPS[$i]}" \
            "grep -qF '$hk_line' /root/.ssh/known_hosts 2>/dev/null || echo '$hk_line' >> /root/.ssh/known_hosts"
        done <<< "${NODE_HOSTKEYS[$j]}"
      fi
    done
    echo "  ✓ Deployed keys to ${NODE_NAMES[$i]}"
  done

  # Verify bidirectional SSH for every pair
  echo ""
  echo "  Verifying inter-node SSH..."
  SSH_FAIL=0
  for (( i=0; i<NODE_COUNT; i++ )); do
    for (( j=0; j<NODE_COUNT; j++ )); do
      if [[ $j -ne $i ]]; then
        result=$(ssh_node "${NODE_IPS[$i]}" \
          "ssh -n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10 root@${NODE_IPS[$j]} hostname 2>/dev/null") || result=""
        if [[ "$result" == "${NODE_NAMES[$j]}" ]]; then
          echo "  ✓ ${NODE_NAMES[$i]} → ${NODE_NAMES[$j]}: SSH OK"
        else
          echo "  ✗ ${NODE_NAMES[$i]} → ${NODE_NAMES[$j]}: SSH FAILED (got: '${result}')"
          SSH_FAIL=1
        fi
      fi
    done
  done

  if [[ $SSH_FAIL -eq 1 ]]; then
    echo ""
    echo "ERROR: Inter-node SSH verification failed. Cannot proceed with cluster formation." >&2
    exit 1
  fi
fi
echo ""

# --- Create cluster on first node ---
CREATE_CMD="pvecm create ${CLUSTER_NAME}"
if [[ $HAS_REPL -eq 1 ]]; then
  CREATE_CMD="${CREATE_CMD} --link0 ${NODE_REPL_IPS[0]} --link1 ${NODE_IPS[0]}"
fi

echo "--- Creating cluster on ${NODE_NAMES[0]} ---"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "  Command: ssh root@${NODE_IPS[0]} ${CREATE_CMD}"
  echo "  [DRY RUN] Skipping execution"
  FINGERPRINT="<fingerprint-read-after-cluster-creation>"
else
  if [[ $FIRST_NODE_HAS_CLUSTER -eq 1 ]]; then
    echo "  ✓ Cluster '${CLUSTER_NAME}' already exists on ${NODE_NAMES[0]} — skipping creation"
  else
    echo "  Command: ssh root@${NODE_IPS[0]} ${CREATE_CMD}"
    if ssh_node "${NODE_IPS[0]}" "${CREATE_CMD}"; then
      echo "  ✓ Cluster created on ${NODE_NAMES[0]}"
    else
      echo "  ✗ Cluster creation failed on ${NODE_NAMES[0]}"
      exit 1
    fi

    # Wait for cluster filesystem (pmxcfs) quorum before proceeding to joins.
    # Corosync quorum establishes quickly, but /etc/pve (the FUSE-mounted
    # cluster filesystem) takes several more seconds to become writable.
    # pvecm addnode writes to /etc/pve, so it fails with "cluster not ready
    # - no quorum?" if CFS isn't ready yet.
    echo "  Waiting for cluster filesystem to become ready..."
    quorum_attempts=0
    while (( quorum_attempts < 30 )); do
      if ssh_node "${NODE_IPS[0]}" "touch /etc/pve/.quorum_test && rm -f /etc/pve/.quorum_test" 2>/dev/null; then
        echo "  ✓ Cluster filesystem ready"
        break
      fi
      (( quorum_attempts++ ))
      sleep 2
    done
    if (( quorum_attempts >= 30 )); then
      echo "  ✗ Timed out waiting for cluster filesystem on ${NODE_NAMES[0]}"
      exit 1
    fi
  fi

  # Get the cluster certificate fingerprint for non-interactive joins
  echo "  Reading cluster certificate fingerprint..."
  FINGERPRINT=$(ssh_node "${NODE_IPS[0]}" \
    "openssl x509 -in /etc/pve/pve-root-ca.pem -noout -fingerprint -sha256 2>/dev/null" \
    | sed 's/.*=//')
  if [[ -z "$FINGERPRINT" ]]; then
    echo "  ✗ Could not read certificate fingerprint from ${NODE_NAMES[0]}"
    exit 1
  fi
  echo "  ✓ Fingerprint: ${FINGERPRINT}"
fi
echo ""

# --- Join remaining nodes ---
for (( i=1; i<NODE_COUNT; i++ )); do
  # Skip nodes already in the cluster
  needs_join=0
  for idx in "${NODES_NEEDING_JOIN[@]+"${NODES_NEEDING_JOIN[@]}"}"; do
    if [[ $idx -eq $i ]]; then needs_join=1; break; fi
  done
  if [[ $needs_join -eq 0 ]]; then
    echo "--- ${NODE_NAMES[$i]} already in cluster — skipping join ---"
    echo ""
    continue
  fi

  JOIN_CMD="pvecm add ${NODE_IPS[0]} --use_ssh --fingerprint ${FINGERPRINT}"
  if [[ $HAS_REPL -eq 1 ]]; then
    JOIN_CMD="${JOIN_CMD} --link0 ${NODE_REPL_IPS[$i]} --link1 ${NODE_IPS[$i]}"
  fi

  echo "--- Joining ${NODE_NAMES[$i]} to cluster ---"
  echo "  Command: ssh root@${NODE_IPS[$i]} ${JOIN_CMD}"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Skipping execution"
  else
    # Capture both stdout and stderr — pvecm add can return 0 on failure
    join_output=$(ssh_node "${NODE_IPS[$i]}" "${JOIN_CMD}" 2>&1) || true
    if echo "$join_output" | grep -q "successfully added node"; then
      echo "  ✓ ${NODE_NAMES[$i]} joined cluster"
    else
      echo "  ✗ ${NODE_NAMES[$i]} failed to join cluster:"
      echo "$join_output" | sed 's/^/    /'
      exit 1
    fi

    # Wait for node to appear in pvecm status
    # When using replication network, pvecm status shows repl_ip not hostname
    if [[ $HAS_REPL -eq 1 ]]; then
      search_str="${NODE_REPL_IPS[$i]}"
    else
      search_str="${NODE_NAMES[$i]}"
    fi
    echo "  Waiting for ${NODE_NAMES[$i]} to appear in cluster status..."
    local_attempts=0
    while (( local_attempts < 30 )); do
      status=$(ssh_node "${NODE_IPS[0]}" "pvecm status 2>/dev/null" || true)
      if echo "$status" | grep -q "${search_str}"; then
        echo "  ✓ ${NODE_NAMES[$i]} visible in cluster"
        break
      fi
      (( local_attempts++ ))
      sleep 2
    done
    if (( local_attempts >= 30 )); then
      echo "  ✗ Timed out waiting for ${NODE_NAMES[$i]} to appear in cluster status"
      (( ERRORS++ ))
    fi
  fi
  echo ""
done

# --- Restart pveproxy on non-initiator nodes ---
# After joining, pveproxy on joined nodes may not reflect the cluster state
# in the web UI until restarted.
echo "--- Restarting pveproxy on joined nodes ---"
for (( i=1; i<NODE_COUNT; i++ )); do
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would restart pveproxy on ${NODE_NAMES[$i]}"
  else
    if ssh_node "${NODE_IPS[$i]}" "systemctl restart pveproxy" 2>/dev/null; then
      echo "  ✓ ${NODE_NAMES[$i]}: pveproxy restarted"
    else
      echo "  ✗ ${NODE_NAMES[$i]}: pveproxy restart failed"
      (( ERRORS++ ))
    fi
  fi
done
echo ""

# --- Final status ---
echo "--- Cluster Status ---"
if [[ $DRY_RUN -eq 1 ]]; then
  echo "  [DRY RUN] Would run: ssh root@${NODE_IPS[0]} pvecm status"
  if [[ $HAS_REPL -eq 1 ]]; then
    echo "  [DRY RUN] Would run: ssh root@${NODE_IPS[0]} corosync-cfgtool -s"
  fi
else
  echo ""
  ssh_node "${NODE_IPS[0]}" "pvecm status" || true
  echo ""
  if [[ $HAS_REPL -eq 1 ]]; then
    echo "--- Corosync Links ---"
    echo ""
    ssh_node "${NODE_IPS[0]}" "corosync-cfgtool -s" || true
    echo ""
  fi
fi

if [[ $ERRORS -gt 0 ]]; then
  echo "FAILED: ${ERRORS} error(s) encountered."
  exit 1
fi

echo "Done."
exit 0
