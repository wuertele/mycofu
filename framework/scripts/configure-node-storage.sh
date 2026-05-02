#!/usr/bin/env bash
# configure-node-storage.sh — Create/import ZFS data pool on Proxmox nodes
#
# Usage:
#   configure-node-storage.sh <node-name>
#   configure-node-storage.sh --all
#   configure-node-storage.sh --verify
#   configure-node-storage.sh --dry-run <node-name>
#   configure-node-storage.sh <node-name> --device /dev/nvme1n1
#
# Identifies the data NVMe by exclusion (the NVMe that does NOT host the
# root filesystem). The boot drive can be any filesystem (ext4, ZFS, LVM) —
# only the data pool requires ZFS. Creates or imports the ZFS data pool,
# creates the data dataset, configures Proxmox storage, and sets cachefile
# for auto-import.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$REPO_ROOT/site/config.yaml"

DRY_RUN=false
ALL_NODES=false
VERIFY_MODE=false
TARGET_NODE=""
EXPLICIT_DEVICE=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --all) ALL_NODES=true; shift ;;
    --verify) VERIFY_MODE=true; shift ;;
    --device) EXPLICIT_DEVICE="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: configure-node-storage.sh [--dry-run] [--all | --verify | <node-name>] [--device /dev/nvmeXn1]"
      exit 0
      ;;
    -*) echo "ERROR: Unknown option: $1" >&2; exit 2 ;;
    *) TARGET_NODE="$1"; shift ;;
  esac
done

# --- Validate ---
if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not installed" >&2
  exit 2
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 2
fi

POOL_NAME=$(yq -r '.proxmox.storage_pool' "$CONFIG_FILE")
if [[ -z "$POOL_NAME" || "$POOL_NAME" == "null" ]]; then
  echo "ERROR: proxmox.storage_pool not set in config.yaml" >&2
  exit 2
fi

NODE_COUNT=$(yq -r '.nodes | length' "$CONFIG_FILE")

if [[ "$ALL_NODES" == false && "$VERIFY_MODE" == false && -z "$TARGET_NODE" ]]; then
  echo "ERROR: Specify a node name, --all, or --verify" >&2
  exit 2
fi

# --- SSH helper ---
ssh_node() {
  local ip="$1"
  shift
  ssh -n -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 \
    "root@${ip}" "$@"
}

# --- Find data NVMe by excluding the boot device ---
# Works regardless of boot filesystem (ext4, ZFS, LVM, etc.)
find_data_device() {
  local mgmt_ip="$1"

  # Find which disk hosts the root filesystem.
  # Handles ext4-on-partition, ZFS rpool, and LVM-on-partition.
  local boot_disk
  boot_disk=$(ssh_node "$mgmt_ip" '
    root_source=$(findmnt -no SOURCE /)

    if echo "$root_source" | grep -q "^rpool"; then
      # ZFS: findmnt returns dataset name, resolve via zpool status
      vdev=$(zpool status rpool 2>/dev/null | grep -oP "nvme\\S+" | head -1)
      if [ -n "$vdev" ]; then
        resolved=$(readlink -f /dev/disk/by-id/$vdev 2>/dev/null || echo /dev/$vdev)
        basename "$resolved" | sed "s/p[0-9]*$//"
      fi
    elif echo "$root_source" | grep -q "/dev/mapper/"; then
      # LVM: walk the device tree upward to find the parent disk.
      # Uses lsblk -s (reverse tree) instead of lvs/pvs which can fail
      # if LVM metadata is missing (e.g., after automated PVE install).
      lsblk -nso NAME,TYPE "$root_source" 2>/dev/null \
        | grep disk | awk "{print \$1}" | sed "s/[^a-zA-Z0-9]//g" | head -1
    else
      # Direct partition (ext4, etc.)
      lsblk -no PKNAME "$root_source" 2>/dev/null | tail -1
    fi
  ' 2>/dev/null)

  if [[ -z "$boot_disk" ]]; then
    echo "ERROR: Could not determine boot disk." >&2
    echo "       On the node, check: findmnt -no SOURCE /" >&2
    return 1
  fi

  # Boot disk info printed by caller, not here (stdout is the return value)

  # All NVMe block devices
  local all_nvme
  all_nvme=$(ssh_node "$mgmt_ip" "lsblk -d -n -o NAME,TYPE | grep disk | grep nvme | awk '{print \$1}'")

  if [[ -z "$all_nvme" ]]; then
    echo "ERROR: No NVMe block devices found" >&2
    return 1
  fi

  # The data NVMe is the one that is NOT the boot disk
  local data_dev=""
  local candidates=0
  while IFS= read -r dev; do
    if [[ "$dev" != "$boot_disk" ]]; then
      data_dev="/dev/$dev"
      (( candidates++ ))
    fi
  done <<< "$all_nvme"

  if [[ $candidates -eq 0 ]]; then
    echo "ERROR: No NVMe device found besides boot disk (${boot_disk})" >&2
    return 1
  fi

  if [[ $candidates -gt 1 ]]; then
    echo "ERROR: Multiple non-boot NVMe devices found. Use --device to specify." >&2
    return 1
  fi

  echo "$data_dev"
}

# --- Configure storage on a single node ---
configure_node() {
  local node_name="$1"
  local mgmt_ip="$2"

  echo "--- ${node_name} (${mgmt_ip}) ---"

  # Check SSH connectivity
  if ! ssh_node "$mgmt_ip" "true" 2>/dev/null; then
    echo "  ERROR: Cannot SSH to ${node_name} at ${mgmt_ip}" >&2
    return 1
  fi

  # Count NVMe devices
  local nvme_count
  nvme_count=$(ssh_node "$mgmt_ip" "lsblk -d -n -o NAME,TYPE | grep disk | grep nvme | wc -l")

  # Single-drive node: cannot create a separate data pool
  if [[ "$nvme_count" -lt 2 && -z "$EXPLICIT_DEVICE" ]]; then
    echo "  ERROR: Only one NVMe device found on ${node_name}." >&2
    echo "         config.yaml requires storage pool '${POOL_NAME}' on a" >&2
    echo "         separate data drive, but no second NVMe is present." >&2
    echo "         Check that the data NVMe is installed and visible to the OS." >&2
    return 1
  fi

  # Determine the data device
  local device="$EXPLICIT_DEVICE"
  if [[ -z "$device" ]]; then
    device=$(find_data_device "$mgmt_ip") || {
      return 1
    }
  fi
  echo "  Data drive: ${device}"

  # --- Case A: Pool with target name already exists ---
  if ssh_node "$mgmt_ip" "zpool list ${POOL_NAME}" &>/dev/null; then
    local health
    health=$(ssh_node "$mgmt_ip" "zpool status -x ${POOL_NAME}" 2>&1)
    if echo "$health" | grep -q "is healthy"; then
      echo "  Pool '${POOL_NAME}' already exists and is healthy — skipping creation"
    else
      echo "  ERROR: Pool '${POOL_NAME}' exists but is NOT healthy:" >&2
      echo "$health" | sed 's/^/    /' >&2
      return 1
    fi
  else
    # --- Case B: Check for already-imported pool with a different name on the data device ---
    local data_base existing_active=""
    data_base=$(basename "$device")
    # Find any active (imported) pool on the data device that isn't rpool.
    # Pool vdevs may use /dev/disk/by-id/ names, so resolve to block device.
    existing_active=$(ssh_node "$mgmt_ip" "
      for pool in \$(zpool list -H -o name 2>/dev/null); do
        [[ \"\$pool\" == \"rpool\" ]] && continue
        pool_vdev=\$(zpool status \"\$pool\" | grep -oP 'nvme\\S+' | head -1)
        [[ -z \"\$pool_vdev\" ]] && continue
        resolved=\$(readlink -f /dev/disk/by-id/\$pool_vdev 2>/dev/null || echo /dev/\$pool_vdev)
        resolved_base=\$(basename \"\$resolved\" | sed 's/p[0-9]*\$//')
        if [[ \"\$resolved_base\" == \"${data_base}\" ]]; then
          echo \"\$pool\"
          break
        fi
      done
    " 2>/dev/null)

    if [[ -n "$existing_active" ]]; then
      echo "  Found active pool '${existing_active}' on data device — renaming to '${POOL_NAME}'..."
      if [[ "$DRY_RUN" == true ]]; then
        echo "  (dry-run) Would run: zpool export ${existing_active} && zpool import -f ${existing_active} ${POOL_NAME}"
      else
        ssh_node "$mgmt_ip" "zpool export ${existing_active}" || {
          echo "  ERROR: zpool export ${existing_active} failed" >&2; return 1
        }
        ssh_node "$mgmt_ip" "zpool import -f ${existing_active} ${POOL_NAME}" || {
          echo "  ERROR: zpool import/rename failed" >&2; return 1
        }
      fi
    else
      # --- Case C: Check for importable (not yet imported) pool ---
      local existing_importable=""
      existing_importable=$(ssh_node "$mgmt_ip" "zpool import 2>/dev/null | grep 'pool:' | awk '{print \$2}'" 2>/dev/null)

      if [[ -n "$existing_importable" ]]; then
        echo "  Found importable pool: ${existing_importable}"
        if [[ "$existing_importable" == "$POOL_NAME" ]]; then
          echo "  Importing pool '${POOL_NAME}'..."
          if [[ "$DRY_RUN" == true ]]; then
            echo "  (dry-run) Would run: zpool import -f ${POOL_NAME}"
          else
            ssh_node "$mgmt_ip" "zpool import -f ${POOL_NAME}" || {
              echo "  ERROR: zpool import failed" >&2; return 1
            }
          fi
        else
          echo "  Renaming pool '${existing_importable}' → '${POOL_NAME}'..."
          if [[ "$DRY_RUN" == true ]]; then
            echo "  (dry-run) Would run: zpool import -f ${existing_importable} ${POOL_NAME}"
          else
            ssh_node "$mgmt_ip" "zpool import -f ${existing_importable} ${POOL_NAME}" || {
              echo "  ERROR: zpool import/rename failed" >&2; return 1
            }
          fi
        fi
      else
        # --- Case D: No pool at all — create fresh ---
        echo "  No existing pool found. Creating '${POOL_NAME}' on ${device}..."
        if [[ "$DRY_RUN" == true ]]; then
          echo "  (dry-run) Would run: zpool create -f ${POOL_NAME} ${device}"
        else
          # -f: force creation even if the device has stale partition tables
          # or labels from a previous installation. Safe here because we've
          # already verified this is the data NVMe, not the boot drive.
          ssh_node "$mgmt_ip" "zpool create -f ${POOL_NAME} ${device}" || {
            echo "  ERROR: zpool create failed" >&2; return 1
          }
        fi
      fi
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "  (dry-run) Would create dataset ${POOL_NAME}/data"
    echo "  (dry-run) Would set cachefile"
    echo "  (dry-run) Would add Proxmox storage entry"
    return 0
  fi

  # --- Create data dataset ---
  if ! ssh_node "$mgmt_ip" "zfs list ${POOL_NAME}/data" &>/dev/null; then
    echo "  Creating dataset ${POOL_NAME}/data..."
    ssh_node "$mgmt_ip" "zfs create ${POOL_NAME}/data" || {
      echo "  ERROR: zfs create ${POOL_NAME}/data failed" >&2; return 1
    }
  else
    echo "  Dataset ${POOL_NAME}/data already exists"
  fi

  # --- Set cachefile for auto-import ---
  echo "  Setting cachefile for auto-import..."
  ssh_node "$mgmt_ip" "zpool set cachefile=/etc/zfs/zpool.cache '${POOL_NAME}'"

  # --- Configure Proxmox storage (cluster-wide, only needs to run once) ---
  if ! ssh_node "$mgmt_ip" "grep -q '^zfspool: ${POOL_NAME}' /etc/pve/storage.cfg" 2>/dev/null; then
    echo "  Adding Proxmox storage entry '${POOL_NAME}'..."
    ssh_node "$mgmt_ip" "printf '\nzfspool: ${POOL_NAME}\n    pool ${POOL_NAME}/data\n    content images,rootdir\n    sparse 1\n' >> /etc/pve/storage.cfg"
  else
    echo "  Proxmox storage entry '${POOL_NAME}' already exists"
  fi

  # --- Verify ---
  local status
  status=$(ssh_node "$mgmt_ip" "zpool status -x ${POOL_NAME}" 2>&1)
  if echo "$status" | grep -q "is healthy"; then
    echo "  Pool '${POOL_NAME}' — ONLINE and healthy"
  else
    echo "  WARNING: Pool status:" >&2
    echo "$status" | sed 's/^/    /' >&2
  fi

  return 0
}

# --- Verify storage on a single node ---
verify_node() {
  local node_name="$1"
  local mgmt_ip="$2"
  local errors=0

  echo "--- ${node_name} (${mgmt_ip}) ---"

  # Check SSH
  if ! ssh_node "$mgmt_ip" "true" 2>/dev/null; then
    echo "  FAIL: Cannot SSH to ${node_name}" >&2
    return 1
  fi

  # Check NVMe device count
  local nvme_count
  nvme_count=$(ssh_node "$mgmt_ip" "lsblk -d -n -o NAME,TYPE | grep disk | grep nvme | wc -l")

  # Single-drive node: skip data pool checks entirely
  if [[ "$nvme_count" -lt 2 ]]; then
    echo "  INFO: Single-drive node — VMs on rpool/data (no fault isolation)"
    # Just verify the storage entry is active in Proxmox
    local pvesm_status
    pvesm_status=$(ssh_node "$mgmt_ip" "pvesm status 2>/dev/null | grep -E '(local-zfs|${POOL_NAME})'")
    if echo "$pvesm_status" | grep -q "active"; then
      local active_store
      active_store=$(echo "$pvesm_status" | grep "active" | awk '{print $1}' | head -1)
      echo "  PASS: Proxmox storage '${active_store}' is active"
    else
      echo "  FAIL: No active Proxmox ZFS storage found"
      (( errors++ ))
    fi
    return "$errors"
  fi

  echo "  PASS: ${nvme_count} NVMe devices present"

  # Check: data pool exists and is ONLINE
  if ssh_node "$mgmt_ip" "zpool list ${POOL_NAME}" &>/dev/null; then
    local health
    health=$(ssh_node "$mgmt_ip" "zpool status -x ${POOL_NAME}" 2>&1)
    if echo "$health" | grep -q "is healthy"; then
      echo "  PASS: Pool '${POOL_NAME}' exists and is healthy"
    else
      echo "  FAIL: Pool '${POOL_NAME}' exists but is NOT healthy"
      echo "$health" | sed 's/^/    /'
      (( errors++ ))
    fi
  else
    echo "  FAIL: Pool '${POOL_NAME}' does not exist"
    (( errors++ ))
    return "$errors"
  fi

  # Check: pool is on the data NVMe (not the boot NVMe)
  # Find boot disk (filesystem-agnostic: ext4, ZFS, LVM)
  local boot_disk pool_vdev
  boot_disk=$(ssh_node "$mgmt_ip" '
    root_source=$(findmnt -no SOURCE /)
    if echo "$root_source" | grep -q "^rpool"; then
      vdev=$(zpool status rpool 2>/dev/null | grep -oP "nvme\\S+" | head -1)
      if [ -n "$vdev" ]; then
        resolved=$(readlink -f /dev/disk/by-id/$vdev 2>/dev/null || echo /dev/$vdev)
        basename "$resolved" | sed "s/p[0-9]*$//"
      fi
    elif echo "$root_source" | grep -q "/dev/mapper/"; then
      vg_name=$(lvs --noheadings -o vg_name "$root_source" 2>/dev/null | tr -d " ")
      pv_dev=$(pvs --noheadings -o pv_name -S "vg_name=$vg_name" 2>/dev/null | tr -d " " | head -1)
      lsblk -no PKNAME "$pv_dev" 2>/dev/null | tail -1
    else
      lsblk -no PKNAME "$root_source" 2>/dev/null | tail -1
    fi
  ' 2>/dev/null)
  pool_vdev=$(ssh_node "$mgmt_ip" "zpool status ${POOL_NAME} | grep -oP 'nvme\S+' | head -1 | xargs -I{} readlink -f /dev/disk/by-id/{} 2>/dev/null | xargs basename | sed 's/p[0-9]*$//'")
  if [[ -z "$pool_vdev" ]]; then
    # Pool vdev might use raw device names instead of by-id
    pool_vdev=$(ssh_node "$mgmt_ip" "zpool status ${POOL_NAME} | awk '/ONLINE/{found=1} found && /nvme/{print \$1; exit}' | sed 's/p[0-9]*$//'")
  fi
  if [[ -n "$pool_vdev" && -n "$boot_disk" && "$pool_vdev" != "$boot_disk" ]]; then
    echo "  PASS: Pool on data NVMe (${pool_vdev}), boot on ${boot_disk}"
  elif [[ -n "$pool_vdev" && "$pool_vdev" == "$boot_disk" ]]; then
    echo "  FAIL: Pool is on the SAME device as boot disk (${boot_disk})"
    (( errors++ ))
  else
    echo "  WARN: Could not determine pool or boot device"
  fi

  # Check: data dataset exists
  if ssh_node "$mgmt_ip" "zfs list ${POOL_NAME}/data" &>/dev/null; then
    echo "  PASS: Dataset ${POOL_NAME}/data exists"
  else
    echo "  FAIL: Dataset ${POOL_NAME}/data missing"
    (( errors++ ))
  fi

  # Check: cachefile is set (- means default = /etc/zfs/zpool.cache, which is correct)
  local cachefile
  cachefile=$(ssh_node "$mgmt_ip" "zpool get -H -o value cachefile ${POOL_NAME}" 2>/dev/null)
  if [[ "$cachefile" == "/etc/zfs/zpool.cache" || "$cachefile" == "-" ]]; then
    # Verify the pool is actually in the cache file
    if ssh_node "$mgmt_ip" "strings /etc/zfs/zpool.cache 2>/dev/null | grep -q '${POOL_NAME}'"; then
      echo "  PASS: Pool in /etc/zfs/zpool.cache (auto-import on reboot)"
    else
      echo "  FAIL: Pool not found in /etc/zfs/zpool.cache"
      (( errors++ ))
    fi
  else
    echo "  FAIL: Cachefile set to '${cachefile}' (expected default or /etc/zfs/zpool.cache)"
    (( errors++ ))
  fi

  # Check: Proxmox storage entry exists and is active
  local pvesm_status
  pvesm_status=$(ssh_node "$mgmt_ip" "pvesm status 2>/dev/null | grep '${POOL_NAME}'")
  if echo "$pvesm_status" | grep -q "active"; then
    echo "  PASS: Proxmox storage '${POOL_NAME}' is active"
  else
    echo "  FAIL: Proxmox storage '${POOL_NAME}' not active"
    (( errors++ ))
  fi

  # Info: pool capacity
  local pool_size
  pool_size=$(ssh_node "$mgmt_ip" "zpool list -H -o size ${POOL_NAME}" 2>/dev/null)
  echo "  INFO: Data pool size=${pool_size}"

  return "$errors"
}

# --- Main ---
failures=0

get_nodes() {
  for (( i=0; i<NODE_COUNT; i++ )); do
    local name ip
    name=$(yq -r ".nodes[$i].name" "$CONFIG_FILE")
    ip=$(yq -r ".nodes[$i].mgmt_ip" "$CONFIG_FILE")
    echo "$name $ip"
  done
}

if [[ "$VERIFY_MODE" == true ]]; then
  echo "Verifying ZFS data pool '${POOL_NAME}' on all nodes..."
  echo
  while read -r name ip; do
    if ! verify_node "$name" "$ip"; then
      (( failures++ ))
    fi
    echo
  done < <(get_nodes)
elif [[ "$ALL_NODES" == true ]]; then
  while read -r name ip; do
    if ! configure_node "$name" "$ip"; then
      (( failures++ ))
    fi
    echo
  done < <(get_nodes)
else
  # Find the target node
  found=false
  while read -r name ip; do
    if [[ "$name" == "$TARGET_NODE" ]]; then
      if ! configure_node "$name" "$ip"; then
        (( failures++ ))
      fi
      found=true
      break
    fi
  done < <(get_nodes)
  if [[ "$found" == false ]]; then
    echo "ERROR: Node '${TARGET_NODE}' not found in config.yaml" >&2
    exit 2
  fi
fi

if (( failures > 0 )); then
  echo "FAILED: ${failures} node(s) had errors"
  exit 1
fi

echo "Done."
exit 0
