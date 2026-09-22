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
      cat <<'USAGE'
Usage: configure-node-storage.sh [--dry-run] [--all | --verify | <node-name>] [--device /dev/nvmeXn1]

What this script does (per node):
  1. Creates ZFS data pool '<pool>' on the data NVMe (vmstore by default)
  2. Creates '<pool>/data' dataset for VM disks
  3. Registers 'zfspool: <pool>' in /etc/pve/storage.cfg for VM content
  4. Creates '<pool>/iso' dataset and migrates ISO storage off pve-root
     (replaces /var/lib/vz/template/iso with symlink to /<pool>/iso)

OPERATOR PREREQUISITE for production nodes (step 4 specifically):
  STOP OR PAUSE THE CI RUNNER before running on a node that already
  holds ISO files. Step 4 does a cross-filesystem migration of ~80GB
  of role-image .img files; it does not coordinate with concurrent
  upload-image.sh writes. A pipeline writing to /var/lib/vz/template/
  iso/ mid-migration can leave a corrupt partial image at the new
  location.

  On a fresh/empty node this prerequisite is moot (nothing to migrate).
  Use --dry-run first to see what each node would do.
USAGE
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
    # Include the ISO-storage dry-run output too — without this the
    # operator's dry-run review would miss the production storage
    # migration entirely (P2.1).
    configure_iso_storage "$mgmt_ip" || true
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

  # --- Configure ISO storage on ZFS ---
  # pve-root is typically 96GB (Proxmox installer default). VM images
  # can easily exceed that, especially hil-boot at ~13GB. Move ISO
  # storage to the data pool's ZFS dataset (~1.5TB free) so
  # multi-pipeline accumulation is bounded by the data drive, not the
  # boot LV. Approach: create ${POOL_NAME}/iso with explicit mountpoint
  # /${POOL_NAME}/iso, migrate any existing files from
  # /var/lib/vz/template/iso, replace that path with a symlink. The
  # Proxmox 'local' storage definition stays unchanged; file_id format
  # stays 'local:iso/<file>'; no tofu state change required.
  configure_iso_storage "$mgmt_ip" || return 1

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

# --- Configure ISO storage on ZFS (instead of pve-root) ---
# pve-root is typically 96GB (Proxmox installer default). VM images can
# easily exceed that, especially hil-boot at ~13GB each. Move ISO storage
# to the data pool's ZFS dataset (~1.5TB free) so multi-pipeline
# accumulation is bounded by the data drive, not the boot LV.
#
# Approach: create ${POOL_NAME}/iso with explicit mountpoint
# /${POOL_NAME}/iso, migrate any existing files from
# /var/lib/vz/template/iso, replace that path with a symlink. Proxmox's
# 'local' storage definition stays unchanged (path /var/lib/vz); file_id
# format stays 'local:iso/<file>'; no tofu state change required.
#
# IMPORTANT — operator prerequisite for production runs:
#   Stop or pause the CI runner before invoking this on production
#   nodes. The ~80GB cross-filesystem migration can race against any
#   concurrent upload-image.sh writing to /var/lib/vz/template/iso/
#   and corrupt the migrating .img file (cp+rm with no shared lock).
#   For an empty/fresh node this prerequisite is moot.
#
# Pattern: CLASSIFY current state with NO mutations → dispatch handler
# → VERIFY post-condition (always, even on the fast-path) before
# returning success. Fail closed on any unknowable or unexpected state.
#
# Idempotent: a node that is already in the final state goes through
# classify=DONE → verify post-condition → return 0 without mutation.

# Post-condition verifier — shared by both configure_iso_storage's
# success path AND verify_node. The node ends in the "ready" state iff
# all four conditions hold. Any failure is reported with the specific
# missing condition.
_iso_storage_state_ok() {
  local mgmt_ip="$1"
  local iso_dataset="${POOL_NAME}/iso"
  local iso_mountpoint="/${POOL_NAME}/iso"
  local pve_iso_dir="/var/lib/vz/template/iso"
  # Single remote check, returns a structured pass/fail summary so the
  # caller can decide what to report. Exits 0 if all conditions hold;
  # exits 1 with a one-line reason otherwise.
  ssh_node "$mgmt_ip" "
    err() { echo \"\$1\"; exit 1; }
    # 1. Symlink at expected source path
    [ -L ${pve_iso_dir} ] || err 'symlink missing at ${pve_iso_dir}'
    target=\$(readlink ${pve_iso_dir})
    [ \"\$target\" = '${iso_mountpoint}' ] || err \"symlink target is '\$target', expected '${iso_mountpoint}'\"
    # 2. Dataset exists
    zfs list ${iso_dataset} >/dev/null 2>&1 || err 'dataset ${iso_dataset} does not exist'
    # 3. Dataset mountpoint property is the expected path
    mp=\$(zfs get -H -o value mountpoint ${iso_dataset})
    [ \"\$mp\" = '${iso_mountpoint}' ] || err \"dataset mountpoint='\$mp', expected '${iso_mountpoint}'\"
    # 4. Dataset is actually mounted (not just configured)
    mounted=\$(zfs get -H -o value mounted ${iso_dataset})
    [ \"\$mounted\" = 'yes' ] || err 'dataset ${iso_dataset} is not mounted'
    echo OK
  "
}

# Classify the current state at pve_iso_dir into one of:
#   DONE              all post-conditions satisfied; safe fast-path
#   FRESH             pve_iso_dir does not exist; install from scratch
#   MIGRATE_FROM_DIR  pve_iso_dir is a real dir; only .img/.iso allowed
#   ERR_SYMLINK_WRONG          symlink to wrong target
#   ERR_SYMLINK_DANGLING       symlink target right but dataset/mount missing
#   ERR_PATH_NOT_DIR_OR_LINK   regular file, FIFO, block dev, etc.
#   ERR_DIR_FOREIGN_ENTRIES    real dir with non-img/non-iso entries of any type
#   ERR_MOUNTPOINT_OCCUPIED    /vmstore/iso exists as non-ZFS dir with content
#   ERR_DATASET_WRONG_MP       dataset exists with wrong mountpoint
# Output: STATE\n[detail-message]
_iso_storage_classify() {
  local mgmt_ip="$1"
  local iso_dataset="${POOL_NAME}/iso"
  local iso_mountpoint="/${POOL_NAME}/iso"
  local pve_iso_dir="/var/lib/vz/template/iso"

  # First check post-condition for the DONE fast-path.
  if _iso_storage_state_ok "$mgmt_ip" >/dev/null 2>&1; then
    echo "DONE"
    return 0
  fi

  ssh_node "$mgmt_ip" "
    iso_dataset='${iso_dataset}'
    iso_mountpoint='${iso_mountpoint}'
    pve_iso_dir='${pve_iso_dir}'

    # If a dataset exists, verify its mountpoint is correct; otherwise
    # report the discrepancy upfront.
    if zfs list \"\$iso_dataset\" >/dev/null 2>&1; then
      mp=\$(zfs get -H -o value mountpoint \"\$iso_dataset\")
      if [ \"\$mp\" != \"\$iso_mountpoint\" ]; then
        echo ERR_DATASET_WRONG_MP
        echo \"dataset \$iso_dataset has mountpoint='\$mp', expected '\$iso_mountpoint'\"
        exit 0
      fi
    fi

    # Inspect pve_iso_dir type. -L wins over -e for symlinks.
    if [ -L \"\$pve_iso_dir\" ]; then
      target=\$(readlink \"\$pve_iso_dir\")
      if [ \"\$target\" != \"\$iso_mountpoint\" ]; then
        echo ERR_SYMLINK_WRONG
        echo \"symlink target='\$target', expected '\$iso_mountpoint'\"
      else
        # Right target — but post-condition already failed above, so
        # the dataset/mount must be missing.
        echo ERR_SYMLINK_DANGLING
        echo \"symlink correct but dataset/mount not ready\"
      fi
      exit 0
    fi

    if [ ! -e \"\$pve_iso_dir\" ]; then
      echo FRESH
      exit 0
    fi

    if [ ! -d \"\$pve_iso_dir\" ]; then
      echo ERR_PATH_NOT_DIR_OR_LINK
      echo \"path exists but is not a directory or symlink (type=\$(stat -c %F \"\$pve_iso_dir\"))\"
      exit 0
    fi

    # It's a real directory. Catch any non-img/non-iso entry of any
    # type (files, subdirs, sockets, FIFOs, broken symlinks) AND any
    # non-regular-file entries even with allowed names (codex R2 P2.2).
    # Two passes:
    #   1. Bad name (covers subdirs/symlinks/etc. named anything)
    #   2. Allowed name (*.img/*.iso) but non-regular-file
    foreign_name=\$(find \"\$pve_iso_dir\" -mindepth 1 -maxdepth 1 \\
      ! -name '*.img' ! -name '*.iso' 2>/dev/null)
    foreign_type=\$(find \"\$pve_iso_dir\" -mindepth 1 -maxdepth 1 \\
      \\( -name '*.img' -o -name '*.iso' \\) ! -type f 2>/dev/null)
    if [ -n \"\$foreign_name\$foreign_type\" ]; then
      echo ERR_DIR_FOREIGN_ENTRIES
      [ -n \"\$foreign_name\" ] && echo \"\$foreign_name\"
      [ -n \"\$foreign_type\" ] && echo \"(non-regular-file with allowed name:) \$foreign_type\"
      exit 0
    fi

    # If /vmstore/iso already exists (any type — directory, regular
    # file, symlink) and the dataset is missing, refuse upfront. ZFS
    # would either fail or silently mount over (hiding the content).
    # Codex R2 P2.3: -e (any kind of path), not just -d.
    if [ -e \"\$iso_mountpoint\" ] && [ ! -L \"\$iso_mountpoint\" ]; then
      if ! zfs list \"\$iso_dataset\" >/dev/null 2>&1; then
        # Empty directory is the one safe case (ZFS mounts over it cleanly).
        if [ -d \"\$iso_mountpoint\" ] && [ -z \"\$(ls -A \"\$iso_mountpoint\" 2>/dev/null)\" ]; then
          : # fall through to MIGRATE_FROM_DIR
        else
          echo ERR_MOUNTPOINT_OCCUPIED
          echo \"\$iso_mountpoint exists (type=\$(stat -c %F \"\$iso_mountpoint\")); refusing to create dataset here\"
          exit 0
        fi
      fi
    fi

    echo MIGRATE_FROM_DIR
  "
}

# Migrate one file safely. Cross-filesystem mv is cp+rm. On a partial
# pre-existing dest, we verify content (cmp -s) before deleting source.
# Caller passes the file basename; we operate inside ${pve_iso_dir}.
_iso_storage_migrate_one() {
  local mgmt_ip="$1" file="$2"
  local iso_mountpoint="/${POOL_NAME}/iso"
  local pve_iso_dir="/var/lib/vz/template/iso"
  ssh_node "$mgmt_ip" "
    src='${pve_iso_dir}/${file}'
    dst='${iso_mountpoint}/${file}'
    if [ -e \"\$dst\" ]; then
      # Both present from a prior partial run. Verify byte-identical
      # before deleting source; never trust size alone.
      if cmp -s \"\$src\" \"\$dst\"; then
        rm -f \"\$src\"
      else
        echo 'CONFLICT' >&2
        echo \"src=\$src dst=\$dst differ; refusing to delete source\" >&2
        exit 1
      fi
    else
      mv -n \"\$src\" \"\$dst\"
    fi
  "
}

configure_iso_storage() {
  local mgmt_ip="$1"
  local iso_dataset="${POOL_NAME}/iso"
  local iso_mountpoint="/${POOL_NAME}/iso"
  local pve_iso_dir="/var/lib/vz/template/iso"

  echo "  Ensuring ISO storage on ZFS dataset ${iso_dataset}..."

  # === 1. Classify (no mutations) ===
  local classify_out state detail
  classify_out=$(_iso_storage_classify "$mgmt_ip" 2>/dev/null) || {
    echo "  ERROR: state classification failed (SSH or remote shell error)" >&2
    return 1
  }
  state=$(echo "$classify_out" | head -1)
  detail=$(echo "$classify_out" | tail -n +2)

  case "$state" in
    DONE)
      echo "  ${pve_iso_dir} already on ZFS dataset ${iso_dataset} (verified)"
      return 0
      ;;
    ERR_SYMLINK_WRONG)
      echo "  ERROR: ${detail}" >&2
      echo "         Refusing to overwrite. Recovery: inspect the wrong" >&2
      echo "         target, move its content to a non-iso path (e.g." >&2
      echo "         /tmp or /vmstore/iso-quarantine-\$(date +%F)) if you" >&2
      echo "         care about it, then remove the symlink:" >&2
      echo "             rm ${pve_iso_dir}" >&2
      echo "         and re-run configure-node-storage.sh. (Do NOT stage" >&2
      echo "         content at ${iso_mountpoint} first; ZFS will refuse" >&2
      echo "         to mount over an occupied path.)" >&2
      return 1
      ;;
    ERR_SYMLINK_DANGLING)
      echo "  ERROR: ${pve_iso_dir} symlinks to ${iso_mountpoint} but the ZFS" >&2
      echo "         dataset ${iso_dataset} does not exist or is not mounted." >&2
      echo "         (${detail})" >&2
      echo "         Recovery: remove the dangling symlink and re-run this" >&2
      echo "         script — it will create the dataset and reinstall the" >&2
      echo "         symlink under the framework's full preflight checks." >&2
      echo "             rm ${pve_iso_dir}" >&2
      echo "             framework/scripts/configure-node-storage.sh <node>" >&2
      return 1
      ;;
    ERR_PATH_NOT_DIR_OR_LINK)
      echo "  ERROR: ${detail}" >&2
      echo "         Refusing to touch ${pve_iso_dir} — remove or rename" >&2
      echo "         this unexpected entry manually before re-running." >&2
      return 1
      ;;
    ERR_DIR_FOREIGN_ENTRIES)
      echo "  ERROR: ${pve_iso_dir} contains entries that are NOT *.img/*.iso:" >&2
      echo "${detail}" | sed 's/^/    /' >&2
      echo "         Refusing to proceed — move these to a non-ISO location" >&2
      echo "         (e.g., /var/lib/vz/dump for backups) and re-run." >&2
      return 1
      ;;
    ERR_MOUNTPOINT_OCCUPIED)
      echo "  ERROR: ${detail}" >&2
      echo "         Refusing to silently mount over existing content. Inspect" >&2
      echo "         ${iso_mountpoint}, relocate its content, then re-run." >&2
      return 1
      ;;
    ERR_DATASET_WRONG_MP)
      echo "  ERROR: ${detail}" >&2
      echo "         The ZFS dataset is already configured but mounted at the" >&2
      echo "         wrong path. Inspect with: zfs get all ${iso_dataset}" >&2
      echo "         then either:" >&2
      echo "         (a) zfs set mountpoint=${iso_mountpoint} ${iso_dataset}" >&2
      echo "         (b) destroy the dataset if empty and re-run" >&2
      return 1
      ;;
    FRESH|MIGRATE_FROM_DIR)
      : # fall through to install
      ;;
    *)
      echo "  ERROR: unexpected classification result: '${state}'" >&2
      echo "         classify output:" >&2
      echo "$classify_out" | sed 's/^/    /' >&2
      return 1
      ;;
  esac

  if [[ "$DRY_RUN" == true ]]; then
    case "$state" in
      FRESH)
        echo "  (dry-run) Would create dataset ${iso_dataset} mounted at ${iso_mountpoint}"
        echo "  (dry-run) Would install symlink ${pve_iso_dir} → ${iso_mountpoint}"
        ;;
      MIGRATE_FROM_DIR)
        echo "  (dry-run) Would create dataset ${iso_dataset} mounted at ${iso_mountpoint}"
        echo "  (dry-run) Would migrate *.img/*.iso from ${pve_iso_dir} into ${iso_mountpoint}"
        echo "            (cp+rm via cmp-verified mv; refuses to overwrite on content mismatch)"
        echo "  (dry-run) Would replace ${pve_iso_dir} with symlink to ${iso_mountpoint}"
        ;;
    esac
    return 0
  fi

  # === 2. Install dataset (idempotent: skip if it already exists with the
  #         correct mountpoint AND is mounted — partial-prior-run recovery).
  #
  # Reviewer-flagged regression (R2 gemini P1.1, codex P1.1): an earlier
  # refactor unconditionally ran `zfs create`, which fails on retry of a
  # half-completed install. classify catches the "wrong mountpoint" case
  # as ERR_DATASET_WRONG_MP upstream; here we additionally tolerate the
  # benign "right mountpoint, just needs symlink" case. ===
  local need_create=1
  if ssh_node "$mgmt_ip" "zfs list ${iso_dataset}" &>/dev/null; then
    local existing_mp existing_mounted
    existing_mp=$(ssh_node "$mgmt_ip" "zfs get -H -o value mountpoint ${iso_dataset}" 2>/dev/null || echo "")
    existing_mounted=$(ssh_node "$mgmt_ip" "zfs get -H -o value mounted ${iso_dataset}" 2>/dev/null || echo "")
    if [[ "$existing_mp" == "$iso_mountpoint" ]]; then
      need_create=0
      if [[ "$existing_mounted" != "yes" ]]; then
        echo "  Dataset ${iso_dataset} exists but unmounted — mounting..."
        ssh_node "$mgmt_ip" "zfs mount ${iso_dataset}" || {
          echo "  ERROR: zfs mount ${iso_dataset} failed" >&2
          return 1
        }
      else
        echo "  Dataset ${iso_dataset} already exists with correct mountpoint — reusing"
      fi
    else
      echo "  ERROR: dataset ${iso_dataset} exists with mountpoint='${existing_mp}', expected '${iso_mountpoint}'" >&2
      echo "         (classify should have caught this — please report as a bug)" >&2
      return 1
    fi
  fi
  if [[ "$need_create" -eq 1 ]]; then
    echo "  Creating dataset ${iso_dataset} (mountpoint=${iso_mountpoint})..."
    ssh_node "$mgmt_ip" "zfs create -o mountpoint=${iso_mountpoint} ${iso_dataset}" || {
      echo "  ERROR: zfs create -o mountpoint=${iso_mountpoint} ${iso_dataset} failed" >&2
      return 1
    }
  fi

  # === 3. Migrate (if needed) ===
  if [[ "$state" == "MIGRATE_FROM_DIR" ]]; then
    echo "  Migrating *.img/*.iso from ${pve_iso_dir} → ${iso_mountpoint}..."
    local migrate_failed=0
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      if ! _iso_storage_migrate_one "$mgmt_ip" "$f"; then
        echo "  ERROR: migration failed for ${f} (content mismatch with destination)" >&2
        echo "         Inspect manually: diff ${pve_iso_dir}/${f} ${iso_mountpoint}/${f}" >&2
        echo "         Then either remove the bad copy or align contents, and re-run." >&2
        migrate_failed=1
        break
      fi
    done < <(ssh_node "$mgmt_ip" "cd ${pve_iso_dir} && ls *.img *.iso 2>/dev/null || true")
    [[ $migrate_failed -eq 1 ]] && return 1
  fi

  # === 4. Install symlink (replace the now-empty real dir) ===
  echo "  Replacing ${pve_iso_dir} with symlink to ${iso_mountpoint}..."
  ssh_node "$mgmt_ip" "
    if [ -d ${pve_iso_dir} ] && [ ! -L ${pve_iso_dir} ]; then
      residual=\$(ls -A ${pve_iso_dir} 2>/dev/null || true)
      if [ -n \"\$residual\" ]; then
        echo 'ERROR: ${pve_iso_dir} not empty after migration:' >&2
        echo \"\$residual\" | sed 's/^/    /' >&2
        exit 1
      fi
      rmdir ${pve_iso_dir} && ln -s ${iso_mountpoint} ${pve_iso_dir}
    elif [ ! -e ${pve_iso_dir} ]; then
      mkdir -p \$(dirname ${pve_iso_dir})
      ln -s ${iso_mountpoint} ${pve_iso_dir}
    fi
  " || {
    echo "  ERROR: Failed to install symlink at ${pve_iso_dir}" >&2
    return 1
  }

  # === 5. Post-condition verify (mandatory; no silent success) ===
  local verify_out
  verify_out=$(_iso_storage_state_ok "$mgmt_ip" 2>&1) || {
    echo "  ERROR: post-install verification failed: ${verify_out}" >&2
    return 1
  }
  echo "  PASS: ${pve_iso_dir} → ${iso_mountpoint} (ZFS, verified)"
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

  # Check: ISO storage is on ZFS (symlink + dataset + mount, all together).
  # Uses the same helper as configure_iso_storage's post-install check so
  # the verify report matches the configure-time assertion exactly.
  # Drives off exit code, not stdout — SSH banners (e.g. "Warning:
  # Permanently added...") would otherwise sneak into the captured output
  # and fail a literal-string match. (Gemini R2 P2.2)
  local iso_verify
  if iso_verify=$(_iso_storage_state_ok "$mgmt_ip" 2>&1); then
    echo "  PASS: ISO storage on ZFS dataset ${POOL_NAME}/iso (mounted)"
  else
    echo "  FAIL: ISO storage state — ${iso_verify}"
    echo "        Recovery: configure-node-storage.sh ${node_name} (single node)"
    echo "                  or: configure-node-storage.sh --all"
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
