#!/usr/bin/env bash
# configure-storage.sh — Enable snippet storage on Proxmox local storage
#
# OpenTofu uploads cloud-init user-data and meta-data as "snippets" to Proxmox.
# The local storage must have the snippets content type enabled in
# /etc/pve/storage.cfg (cluster-synced — changing on one node applies to all).
#
# Usage:
#   framework/scripts/configure-storage.sh                  # Enable snippets
#   framework/scripts/configure-storage.sh --dry-run         # Show what would change
#   framework/scripts/configure-storage.sh --verify          # Check current state

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_PATH="${REPO_DIR}/site/config.yaml"
DRY_RUN=0
VERIFY_ONLY=0

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)    CONFIG_PATH="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --verify)    VERIFY_ONLY=1; shift ;;
    -*)          echo "Unknown option: $1" >&2; exit 2 ;;
    *)           echo "Unexpected argument: $1" >&2; exit 2 ;;
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
FIRST_NODE_IP=$(yq '.nodes[0].mgmt_ip' "$CONFIG_PATH")
FIRST_NODE_NAME=$(yq '.nodes[0].name' "$CONFIG_PATH")

# Collect all node IPs for verification
NODE_IPS=()
NODE_NAMES=()
while IFS= read -r ip; do
  NODE_IPS+=("$ip")
done < <(yq '.nodes[].mgmt_ip' "$CONFIG_PATH")
while IFS= read -r name; do
  NODE_NAMES+=("$name")
done < <(yq '.nodes[].name' "$CONFIG_PATH")

# --- SSH helper ---
ssh_node() {
  local ip="$1"; shift
  ssh -n -x -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

# --- Check connectivity ---
check_connectivity() {
  if ! ping -c 1 -W 3 "$FIRST_NODE_IP" &>/dev/null; then
    echo "  ERROR: ${FIRST_NODE_NAME} (${FIRST_NODE_IP}) is not reachable" >&2
    return 1
  fi
  if ! ssh_node "$FIRST_NODE_IP" "echo ok" &>/dev/null; then
    echo "  ERROR: SSH to root@${FIRST_NODE_IP} failed" >&2
    return 1
  fi
  return 0
}

# --- Read storage.cfg and check for snippets ---
check_snippets() {
  local ip="$1"

  # Check storage.cfg exists (indicates node is in a cluster)
  if ! ssh_node "$ip" "test -f /etc/pve/storage.cfg"; then
    echo "  ERROR: /etc/pve/storage.cfg not found on ${ip}." >&2
    echo "         Is the node part of a Proxmox cluster?" >&2
    return 2
  fi

  # Check if local storage entry exists
  if ! ssh_node "$ip" "grep -q '^dir: local' /etc/pve/storage.cfg"; then
    echo "  ERROR: No 'dir: local' entry found in /etc/pve/storage.cfg" >&2
    return 2
  fi

  # Check if snippets is already in the content line for the local block.
  # Extract the content line from the dir: local block.
  local content_line
  content_line=$(ssh_node "$ip" "awk '/^dir: local/{found=1} found && /content/{print; exit}' /etc/pve/storage.cfg")

  if echo "$content_line" | grep -q 'snippets'; then
    return 0  # snippets already enabled
  else
    return 1  # snippets not enabled
  fi
}

# --- Verify mode ---
verify() {
  echo ""
  echo "=== Snippet Storage Verification ==="
  local fail=0

  for i in "${!NODE_IPS[@]}"; do
    local ip="${NODE_IPS[$i]}"
    local name="${NODE_NAMES[$i]}"

    # Check snippets in storage.cfg (only need to check one node since it's cluster-synced)
    if [[ $i -eq 0 ]]; then
      local result
      check_snippets "$ip"
      result=$?
      if [[ $result -eq 0 ]]; then
        echo "  ✓ snippets content type enabled in /etc/pve/storage.cfg"
      elif [[ $result -eq 2 ]]; then
        fail=1
        continue
      else
        echo "  ✗ snippets content type NOT enabled in /etc/pve/storage.cfg"
        fail=1
      fi
    fi

    # Check snippets directory exists on each node
    if ssh_node "$ip" "test -d /var/lib/vz/snippets"; then
      echo "  ✓ ${name}: /var/lib/vz/snippets/ exists"
    else
      echo "  ✗ ${name}: /var/lib/vz/snippets/ does not exist"
      fail=1
    fi
  done

  return $fail
}

# ============================================================
# Main
# ============================================================

echo ""
echo "=== Proxmox Snippet Storage ==="
echo "Target: local storage on cluster (${FIRST_NODE_NAME})"
echo ""

# --- Verify-only mode ---
if [[ $VERIFY_ONLY -eq 1 ]]; then
  if ! check_connectivity; then
    exit 1
  fi
  if verify; then
    echo ""
    echo "All checks passed."
    exit 0
  else
    echo ""
    echo "Some checks failed. See above."
    exit 1
  fi
fi

# --- Check connectivity ---
echo "--- Connectivity ---"
if ! check_connectivity; then
  exit 1
fi
echo "  ✓ ${FIRST_NODE_NAME} (${FIRST_NODE_IP}) reachable via SSH"

# --- Check current state ---
echo ""
echo "--- Storage configuration ---"
check_snippets "$FIRST_NODE_IP"
SNIPPET_STATUS=$?

if [[ $SNIPPET_STATUS -eq 2 ]]; then
  exit 1
fi

if [[ $SNIPPET_STATUS -eq 0 ]]; then
  echo "  ✓ snippets already enabled in /etc/pve/storage.cfg"
else
  echo "  snippets not yet enabled in /etc/pve/storage.cfg"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo "  [DRY RUN] Would append ',snippets' to the content line of the dir: local block"
    echo "  [DRY RUN] in /etc/pve/storage.cfg on ${FIRST_NODE_NAME}"
    echo "  [DRY RUN] (cluster-synced — applies to all nodes automatically)"
  else
    # Append ,snippets to the content line within the dir: local block
    # Use awk: when we see "dir: local", set a flag. Then when we see a "content"
    # line while the flag is set, append ",snippets" and clear the flag.
    ssh_node "$FIRST_NODE_IP" "
      awk '
        /^dir: local/ { in_local=1 }
        in_local && /^[[:space:]]*content / {
          sub(/\$/, \",snippets\")
          in_local=0
        }
        /^(dir|lvm|zfs|nfs|cifs|gluster|iscsi):/ && !/^dir: local/ { in_local=0 }
        { print }
      ' /etc/pve/storage.cfg > /tmp/storage.cfg.new && \
      cp /tmp/storage.cfg.new /etc/pve/storage.cfg && \
      rm /tmp/storage.cfg.new
    "
    echo "  ✓ Added snippets to local storage content types"
  fi
fi

# --- Ensure snippets directory exists on each node ---
echo ""
# /var/lib/vz/snippets/ is Proxmox's fixed path for the 'local' storage
# snippets content type. Unlike image_storage_path (which is configurable per
# storage pool), snippets always live under the built-in 'local' storage.
# This path is not operator-configurable — it is a Proxmox internal.
echo "--- Snippets directory ---"
for i in "${!NODE_IPS[@]}"; do
  local_ip="${NODE_IPS[$i]}"
  local_name="${NODE_NAMES[$i]}"

  if ssh_node "$local_ip" "test -d /var/lib/vz/snippets"; then
    echo "  ✓ ${local_name}: /var/lib/vz/snippets/ already exists"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would create /var/lib/vz/snippets/ on ${local_name}"
    else
      ssh_node "$local_ip" "mkdir -p /var/lib/vz/snippets"
      echo "  ✓ ${local_name}: created /var/lib/vz/snippets/"
    fi
  fi
done

# --- Post-deploy verification (skip if dry-run) ---
if [[ $DRY_RUN -eq 0 ]]; then
  echo ""
  echo "=== Post-Deploy Verification ==="
  if verify; then
    echo ""
    echo "Done."
    exit 0
  else
    echo ""
    echo "FAILED: Some checks did not pass."
    exit 1
  fi
else
  echo ""
  echo "Dry run complete."
  exit 0
fi
