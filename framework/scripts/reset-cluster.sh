#!/usr/bin/env bash
# reset-cluster.sh — Multi-level controlled teardown of the cluster.
#
# Usage:
#   framework/scripts/reset-cluster.sh --<level>              # dry-run
#   framework/scripts/reset-cluster.sh --<level> --confirm    # execute
#   framework/scripts/reset-cluster.sh --<level> --backup --confirm
#
# Options:
#   --backup    Back up all precious-state VMs to PBS before destruction
#   --node <n>  Limit to a single node (e.g., --node pve01)
#   --confirm   Execute (without this, dry-run only)
#
# Cluster track (cumulative):
#   --vms       Destroy VMs, HA, replication, snippets, tofu state
#   --storage   + ZFS data pools, data NVMe partition tables
#   --cluster   + Boot NVMe destruction, secrets.yaml erasure
#   --nas       + PostgreSQL state, PBS datastore, sentinel
#
# Workstation track (cumulative):
#   --builds    Remove build/, image-versions.auto.tfvars, result symlinks
#   --secrets   + Shred operator.age.key
#
# Combined:
#   --distclean Cluster --nas + workstation --secrets + --builds
#
# Terminal (deferred):
#   --forensic  Cryptographic erasure (not yet implemented)

set -euo pipefail

# Ensure nix-provided tools are on PATH (non-interactive shells like nohup)
if ! command -v yq &>/dev/null; then
  for p in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin"; do
    [[ -d "$p" ]] && export PATH="$p:$PATH"
  done
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

CONFIRM=0
LEVEL=""
SINGLE_NODE=""
BACKUP=0
COLD_BUILDS=0

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vms|--storage|--cluster|--nas|--builds|--secrets|--distclean|--forensic|--level5)
      [[ -n "$LEVEL" ]] && { echo "ERROR: Only one level flag allowed" >&2; exit 1; }
      LEVEL="${1#--}"
      shift ;;
    --cold-builds) COLD_BUILDS=1; shift ;;
    --node) SINGLE_NODE="$2"; shift 2 ;;
    --backup) BACKUP=1; shift ;;
    --confirm) CONFIRM=1; shift ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$LEVEL" ]]; then
  echo "Usage: $(basename "$0") --<level> [--confirm] [--backup] [--node <name>] [--cold-builds]" >&2
  echo "Levels: --vms --storage --cluster --nas --builds --secrets --distclean --level5 --forensic" >&2
  exit 1
fi

# --- Read config ---
if [[ -f "$CONFIG" ]]; then
  NODE_COUNT=$(yq -r '.nodes | length' "$CONFIG" 2>/dev/null || echo 0)
  NAS_IP=$(yq -r '.nas.ip' "$CONFIG" 2>/dev/null || echo "")
  NAS_SSH_USER=$(yq -r '.nas.ssh_user' "$CONFIG" 2>/dev/null || echo "root")
  NAS_PG_PORT=$(yq -r '.nas.postgres_port // 5432' "$CONFIG" 2>/dev/null || echo "5432")
  POOL_NAME=$(yq -r '.storage.pool_name // "vmstore"' "$CONFIG" 2>/dev/null || echo "vmstore")

  NODE_IPS=()
  NODE_NAMES=()
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_IPS+=($(yq -r ".nodes[$i].mgmt_ip" "$CONFIG"))
    NODE_NAMES+=($(yq -r ".nodes[$i].name" "$CONFIG"))
  done
else
  NODE_COUNT=0
  NODE_IPS=()
  NODE_NAMES=()
fi

# --- Apply --node filter ---
if [[ -n "$SINGLE_NODE" ]]; then
  FOUND=0
  for (( i=0; i<${#NODE_NAMES[@]}; i++ )); do
    if [[ "${NODE_NAMES[$i]}" == "$SINGLE_NODE" ]]; then
      NODE_IPS=("${NODE_IPS[$i]}")
      NODE_NAMES=("${NODE_NAMES[$i]}")
      NODE_COUNT=1
      FOUND=1
      break
    fi
  done
  if [[ $FOUND -eq 0 ]]; then
    echo "ERROR: node '${SINGLE_NODE}' not found in config.yaml" >&2
    echo "Available nodes: ${NODE_NAMES[*]}" >&2
    exit 1
  fi
fi

# --- SSH helper ---
# Try key auth first, fall back to sshpass with SOPS password.
# Fresh Proxmox installs only have password auth — key auth fails
# until configure-node-network.sh installs the operator's key.
SOPS_PASSWORD=""
ssh_node() {
  local ip="$1"; shift
  # Try key auth
  if ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null; then
    return 0
  fi
  # Fall back to sshpass
  if [[ -z "$SOPS_PASSWORD" ]]; then
    SOPS_PASSWORD=$(sops -d --extract '["proxmox_api_password"]' \
      "${REPO_DIR}/site/sops/secrets.yaml" 2>/dev/null || true)
  fi
  if [[ -n "$SOPS_PASSWORD" ]] && command -v sshpass &>/dev/null; then
    sshpass -p "$SOPS_PASSWORD" ssh -n -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 \
      -o LogLevel=ERROR "root@${ip}" "$@" 2>/dev/null
  else
    return 1
  fi
}

# =====================================================================
# Boot Disk Identification (SAFETY CRITICAL)
# =====================================================================
# Handles ext4 direct, LVM, and ZFS rpool boot configurations.
# Returns via stdout: BOOT_DEVICE=<name> and DATA_DEVICES=<names>
# Exits non-zero if identification fails or is ambiguous.

identify_disks() {
  local node_ip=$1
  ssh_node "${node_ip}" '
    set -euo pipefail

    ROOT_SOURCE=$(findmnt -n -o SOURCE /)
    BOOT_NVME=""

    if echo "$ROOT_SOURCE" | grep -q "^/dev/nvme"; then
      # ext4 direct: /dev/nvme0n1p3 → nvme0n1
      BOOT_NVME=$(echo "$ROOT_SOURCE" | sed "s|^/dev/||;s/p[0-9]*$//")

    elif echo "$ROOT_SOURCE" | grep -q "^/dev/mapper/"; then
      # LVM: walk device tree upward to find parent disk.
      # Uses lsblk -s instead of lvs/pvs which can fail if LVM metadata
      # is missing (e.g., after automated PVE install).
      BOOT_NVME=$(lsblk -nso NAME,TYPE "$ROOT_SOURCE" 2>/dev/null \
        | grep disk | awk "{print \$1}" | sed "s/[^a-zA-Z0-9]//g" | head -1)

    elif echo "$ROOT_SOURCE" | grep -q "^rpool"; then
      # ZFS rpool: find backing device
      POOL_DEV=$(zpool status rpool 2>/dev/null | grep -oP "nvme\S+" | head -1 | sed "s/p[0-9]*$//")
      BOOT_NVME="$POOL_DEV"
    fi

    # Validate: must be set and must be a real block device
    if [ -z "$BOOT_NVME" ] || [ ! -b "/dev/${BOOT_NVME}" ]; then
      echo "ERROR: Could not identify boot NVMe device"
      echo "ROOT_SOURCE=$ROOT_SOURCE"
      echo "BOOT_NVME=$BOOT_NVME"
      exit 1
    fi

    # Data devices: everything that is NOT the boot device
    DATA_NVMES=""
    for dev in /dev/nvme?n1; do
      devname=$(basename "$dev")
      if [ "$devname" != "$BOOT_NVME" ]; then
        DATA_NVMES="${DATA_NVMES} ${devname}"
      fi
    done

    # Cross-check: boot device must have partitions
    PART_COUNT=$(ls /dev/${BOOT_NVME}p* 2>/dev/null | wc -l)
    if [ "$PART_COUNT" -eq 0 ]; then
      echo "ERROR: Boot device ${BOOT_NVME} has no partitions — identification likely wrong"
      exit 1
    fi

    echo "BOOT_DEVICE=${BOOT_NVME}"
    echo "DATA_DEVICES=${DATA_NVMES}"
  '
}

# Collect disk info for all nodes
DISK_INFO=()
BOOT_DEVS=()
DATA_DEVS=()
collect_disk_info() {
  local skip_unreachable="${1:-0}"
  DISK_INFO=()
  BOOT_DEVS=()
  DATA_DEVS=()
  REACHABLE_IPS=()
  for ip in "${NODE_IPS[@]}"; do
    local info
    info=$(identify_disks "$ip") || {
      if [[ "$skip_unreachable" == "1" ]]; then
        echo "  WARNING: ${ip} unreachable — skipping (already wiped?)" >&2
        continue
      fi
      echo "FATAL: Boot disk identification failed on ${ip}" >&2
      echo "$info" >&2
      exit 1
    }
    DISK_INFO+=("$info")
    BOOT_DEVS+=($(echo "$info" | grep "^BOOT_DEVICE=" | cut -d= -f2))
    DATA_DEVS+=($(echo "$info" | grep "^DATA_DEVICES=" | cut -d= -f2 | tr -d ' '))
    REACHABLE_IPS+=("$ip")
  done
}

# =====================================================================
# Level implementations
# =====================================================================

do_reset_vms() {
  # --- Backup precious-state VMs before destruction ---
  if [[ $BACKUP -eq 1 ]]; then
    echo "--- Backing up precious-state VMs ---"
    # Check PBS is available
    PBS_AVAIL=""
    for ip in "${NODE_IPS[@]}"; do
      if ssh_node "$ip" "pvesm status 2>/dev/null | grep -q pbs-nas"; then
        PBS_AVAIL="$ip"
        break
      fi
    done
    if [[ -z "$PBS_AVAIL" ]]; then
      echo "  WARNING: PBS storage (pbs-nas) not registered — skipping backups"
    else
      # Infrastructure VMs with backup: true
      while IFS= read -r vm_key; do
        [[ -z "$vm_key" ]] && continue
        vmid=$(yq -r ".vms.${vm_key}.vmid" "$CONFIG")
        # Find hosting node
        for ip in "${NODE_IPS[@]}"; do
          if ssh_node "$ip" "qm status ${vmid}" >/dev/null 2>&1; then
            echo "  ${vm_key} (${vmid}) on ${ip}..."
            ssh_node "$ip" "vzdump ${vmid} --storage pbs-nas --mode snapshot --compress zstd --quiet 1" \
              && echo "    Done" || echo "    WARNING: backup failed"
            break
          fi
        done
      done < <(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG")

      # Application VMs with backup: true
      while IFS= read -r app_key; do
        [[ -z "$app_key" ]] && continue
        for env in $(yq -r ".applications.${app_key}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null); do
          vmid=$(yq -r ".applications.${app_key}.environments.${env}.vmid" "$APPS_CONFIG")
          for ip in "${NODE_IPS[@]}"; do
            if ssh_node "$ip" "qm status ${vmid}" >/dev/null 2>&1; then
              echo "  ${app_key}_${env} (${vmid}) on ${ip}..."
              ssh_node "$ip" "vzdump ${vmid} --storage pbs-nas --mode snapshot --compress zstd --quiet 1" \
                && echo "    Done" || echo "    WARNING: backup failed"
              break
            fi
          done
        done
      done < <(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null)
    fi
  fi

  # Release ZFS replication holds BEFORE destroying VMs.
  # If replication is active, snapshots have holds that prevent zvol removal.
  # qm destroy --purge removes the replication job config but cannot destroy
  # the underlying zvol if snapshots are held. This leaves orphan zvols that
  # cause replication failures when the VMID is reused by rebuild-cluster.sh.
  echo "--- Releasing ZFS replication holds ---"
  for ip in "${NODE_IPS[@]}"; do
    echo "  ${ip}:"
    ssh_node "$ip" '
      # Step 1: Delete all replication jobs (stops the scheduler)
      for job in $(pvesr list 2>/dev/null | tail -n +2 | awk "{print \$1}"); do
        pvesr delete ${job} 2>/dev/null && echo "    Removed replication job: ${job}"
      done

      # Step 2: Release all ZFS replication holds
      for snap in $(zfs list -t snapshot -o name -H 2>/dev/null | grep "__replicate"); do
        for hold in $(zfs holds -H "${snap}" 2>/dev/null | awk "{print \$2}"); do
          zfs release "${hold}" "${snap}" 2>/dev/null \
            && echo "    Released hold ${hold} on ${snap}"
        done
      done

      # Step 3: Destroy replication snapshots (now unheld)
      for snap in $(zfs list -t snapshot -o name -H 2>/dev/null | grep "__replicate"); do
        zfs destroy "${snap}" 2>/dev/null \
          && echo "    Destroyed snapshot: ${snap}"
      done
    ' || true
  done

  echo "--- Destroying VMs ---"
  for ip in "${NODE_IPS[@]}"; do
    echo "  ${ip}:"
    ssh_node "$ip" '
      for vmid in $(qm list 2>/dev/null | tail -n +2 | awk "{print \$1}"); do
        ha-manager remove vm:${vmid} 2>/dev/null || true
        qm unlock ${vmid} 2>/dev/null || true
        qm stop ${vmid} --skiplock 1 2>/dev/null || true
        qm destroy ${vmid} --destroy-unreferenced-disks 1 --purge 1 --skiplock 1 2>/dev/null \
          && echo "    Destroyed VM ${vmid}" || echo "    VM ${vmid} already gone"
      done
    ' || true
  done

  echo "--- Destroying orphan VM zvols ---"
  for ip in "${NODE_IPS[@]}"; do
    echo "  ${ip}:"
    ssh_node "$ip" '
      for zvol in $(zfs list -o name -H 2>/dev/null | grep "vmstore/data/vm-"); do
        zfs destroy -r "${zvol}" 2>/dev/null \
          && echo "    Destroyed: ${zvol}"
      done
    ' || true
  done

  echo "--- Cleaning cluster state (safety net) ---"
  for ip in "${NODE_IPS[@]}"; do
    ssh_node "$ip" '
      for res in $(ha-manager status 2>/dev/null | grep "^vm:" | awk "{print \$1}"); do
        ha-manager remove ${res} 2>/dev/null && echo "  Removed HA: ${res}"
      done
      for job in $(pvesr list 2>/dev/null | tail -n +2 | awk "{print \$1}"); do
        pvesr delete ${job} 2>/dev/null && echo "  Removed replication: ${job}"
      done
      rm -f /var/lib/vz/snippets/*.yaml 2>/dev/null && echo "  Snippets cleared"
    ' 2>/dev/null || true
  done

  if [[ -n "$SINGLE_NODE" ]]; then
    echo "--- Skipping cluster-wide cleanup (single-node mode) ---"
  else
    # Find a reachable node for cluster-wide operations (some may be wiped)
    CLUSTER_NODE=""
    for ip in "${NODE_IPS[@]}"; do
      if ssh_node "$ip" "true" 2>/dev/null; then
        CLUSTER_NODE="$ip"
        break
      fi
    done

    if [[ -n "$CLUSTER_NODE" ]]; then
      echo "--- Removing PBS storage entry (via ${CLUSTER_NODE}) ---"
      ssh_node "$CLUSTER_NODE" "pvesm remove pbs-nas 2>/dev/null && echo '  Removed pbs-nas' || echo '  No pbs-nas entry'"

      echo "--- Removing backup jobs ---"
      ssh_node "$CLUSTER_NODE" '
        for jobid in $(pvesh get /cluster/backup --output-format json 2>/dev/null | python3 -c "import sys,json; [print(j[\"id\"]) for j in json.loads(sys.stdin.read())]" 2>/dev/null); do
          pvesh delete /cluster/backup/${jobid} 2>/dev/null && echo "  Removed backup job ${jobid}"
        done
      ' || echo "  No backup jobs"

      echo "--- Removing metric server entries ---"
      ssh_node "$CLUSTER_NODE" '
        for name in $(pvesh get /cluster/metrics/server --output-format json 2>/dev/null | python3 -c "import sys,json; [print(s[\"name\"]) for s in json.loads(sys.stdin.read())]" 2>/dev/null); do
          pvesh delete /cluster/metrics/server/${name} 2>/dev/null && echo "  Removed metric server ${name}"
        done
      ' || echo "  No metric servers"
    else
      echo "--- Skipping cluster-wide cleanup (no reachable nodes) ---"
    fi
  fi

  echo "--- Clearing OpenTofu state ---"
  if [[ -n "$SINGLE_NODE" ]]; then
    echo "  Skipping (single-node mode)"
  elif [[ -n "$NAS_IP" ]]; then
    # Drop all schemas owned by the tofu user. The pg backend creates
    # schemas named after the workspace (prod, dev, etc.) — we don't
    # hardcode names, we enumerate and drop all tofu-owned schemas.
    # This leaves tofu_state as a blank slate for tofu init.
    TOFU_SCHEMAS=$(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "${NAS_SSH_USER}@${NAS_IP}" \
      "psql -U postgres -p ${NAS_PG_PORT} -t -A -d tofu_state -c \
        \"SELECT schema_name FROM information_schema.schemata WHERE schema_owner = 'tofu';\"" 2>/dev/null)
    for schema in $TOFU_SCHEMAS; do
      ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
        "${NAS_SSH_USER}@${NAS_IP}" \
        "psql -U postgres -p ${NAS_PG_PORT} -d tofu_state -c 'DROP SCHEMA IF EXISTS ${schema} CASCADE;'" 2>/dev/null \
        && echo "  Dropped schema: ${schema}" || echo "  WARNING: Could not drop schema ${schema}"
    done
    [[ -z "$TOFU_SCHEMAS" ]] && echo "  No tofu schemas to drop"

    # Recreate public schema (PostgreSQL requires it for basic operations)
    ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "${NAS_SSH_USER}@${NAS_IP}" \
      "psql -U postgres -p ${NAS_PG_PORT} -d tofu_state -c 'CREATE SCHEMA IF NOT EXISTS public AUTHORIZATION tofu; GRANT ALL ON SCHEMA public TO PUBLIC;'" 2>/dev/null \
      || true
  fi

  # --- Post-condition assertions ---
  # Verify the reset is complete. If any VM zvols, replication snapshots,
  # or HA resources remain, rebuild-cluster.sh will fail with stale state.
  # Fail hard here so the operator can investigate before rebuilding.
  echo "--- Verifying post-conditions ---"
  ASSERT_FAIL=0
  for ip in "${NODE_IPS[@]}"; do
    # Skip unreachable nodes (already wiped at --cluster level)
    if ! ssh_node "$ip" "true" 2>/dev/null; then
      echo "  ${ip}: unreachable (already wiped — skipping)"
      continue
    fi

    # grep -c exits 1 when count is 0; append "|| true" inside the ssh
    # command so the exit code doesn't trigger the fallback echo.
    ZVOL_COUNT=$(ssh_node "$ip" "zfs list -o name -H 2>/dev/null | grep -c 'vmstore/data/vm-' || true")
    SNAP_COUNT=$(ssh_node "$ip" "zfs list -t snapshot -o name -H 2>/dev/null | grep -c '__replicate' || true")
    HA_COUNT=$(ssh_node "$ip" "ha-manager status 2>/dev/null | grep -c '^vm:' || true")
    VM_COUNT=$(ssh_node "$ip" "qm list 2>/dev/null | tail -n +2 | wc -l || true")

    if [[ "$ZVOL_COUNT" -gt 0 || "$SNAP_COUNT" -gt 0 || "$HA_COUNT" -gt 0 || "$VM_COUNT" -gt 0 ]]; then
      echo "  FATAL: ${ip}: ${VM_COUNT} VMs, ${ZVOL_COUNT} zvols, ${SNAP_COUNT} repl snapshots, ${HA_COUNT} HA resources"
      ASSERT_FAIL=1
    else
      echo "  ${ip}: clean (0 VMs, 0 zvols, 0 snapshots, 0 HA)"
    fi
  done
  if [[ $ASSERT_FAIL -eq 1 ]]; then
    echo "FATAL: Post-condition check failed — stale state remains on one or more nodes." >&2
    echo "Investigate manually before running rebuild-cluster.sh." >&2
    exit 1
  fi
}

do_reset_storage() {
  do_reset_vms

  # At --cluster level, some nodes may already be wiped (e.g., Phase 4a
  # wiped pve01 before Phase 4c runs --cluster on all nodes). Use
  # SKIP_UNREACHABLE (set by do_reset_cluster) to handle this gracefully.
  collect_disk_info "${SKIP_UNREACHABLE:-0}"

  # Use REACHABLE_IPS (populated by collect_disk_info) — unreachable nodes
  # were skipped and have no entries in BOOT_DEVS/DATA_DEVS.
  echo ""
  echo "--- Destroying ZFS pools and wiping data NVMes ---"
  if [[ ${#REACHABLE_IPS[@]} -eq 0 ]]; then
    echo "  No reachable nodes — skipping"
  fi
  for (( i=0; i<${#REACHABLE_IPS[@]}; i++ )); do
    local ip="${REACHABLE_IPS[$i]}"
    local boot="${BOOT_DEVS[$i]}"
    local data="${DATA_DEVS[$i]}"

    echo "  ${ip}: boot=${boot} (PROTECTED)  data=${data}"

    ssh_node "$ip" "zpool list ${POOL_NAME} 2>/dev/null && zpool destroy -f ${POOL_NAME} && echo '    Pool destroyed' || echo '    No pool'"

    for dev in ${data}; do
      if [[ "$dev" == "$boot" ]]; then
        echo "  FATAL: About to wipe boot device ${dev}! Aborting."
        exit 1
      fi
      # Clear ZFS labels on all partitions (handles backup labels at end of vdev),
      # zero partition headers (LVM/filesystem signatures), then destroy GPT.
      ssh_node "$ip" "
        for part in /dev/${dev}p*; do
          zpool labelclear -f \"\${part}\" 2>/dev/null || true
          dd if=/dev/zero of=\"\${part}\" bs=1M count=10 2>/dev/null || true
        done
        zpool labelclear -f /dev/${dev} 2>/dev/null || true
        sgdisk --zap-all /dev/${dev} 2>/dev/null
        wipefs -a /dev/${dev} 2>/dev/null
        echo '    Wiped ${dev}'
      "
    done
  done

  # --- Post-condition assertions (storage level) ---
  # Check only reachable nodes — unreachable ones were already wiped.
  echo ""
  echo "--- Verifying storage post-conditions ---"
  ASSERT_FAIL=0
  for ip in "${REACHABLE_IPS[@]+"${REACHABLE_IPS[@]}"}"; do
    POOL_EXISTS=$(ssh_node "$ip" "zpool list ${POOL_NAME} 2>/dev/null && echo yes || echo no")
    BOOT_OK=$(ssh_node "$ip" "findmnt -n -o SOURCE / 2>/dev/null && echo yes || echo no")

    if [[ "$POOL_EXISTS" == *"yes"* ]]; then
      echo "  FATAL: ${ip}: pool ${POOL_NAME} still exists"
      ASSERT_FAIL=1
    elif [[ "$BOOT_OK" != *"yes"* ]]; then
      echo "  FATAL: ${ip}: boot filesystem missing"
      ASSERT_FAIL=1
    else
      echo "  ${ip}: pool gone, boot intact"
    fi
  done
  if [[ $ASSERT_FAIL -eq 1 ]]; then
    echo "FATAL: Storage post-condition check failed." >&2
    exit 1
  fi
}

do_reset_cluster() {
  # Some nodes may already be wiped from a prior single-node --cluster run
  # (Phase 4a before Phase 4c). Propagate to do_reset_storage/collect_disk_info.
  SKIP_UNREACHABLE=1
  do_reset_storage

  # collect_disk_info was already called by do_reset_storage; the results
  # (REACHABLE_IPS, BOOT_DEVS) are still set. No need to call again.

  echo ""
  echo "--- Destroying boot NVMes ---"
  if [[ ${#REACHABLE_IPS[@]} -eq 0 ]]; then
    echo "  No reachable nodes — skipping"
  fi
  for (( i=0; i<${#REACHABLE_IPS[@]}; i++ )); do
    local ip="${REACHABLE_IPS[$i]}"
    local boot="${BOOT_DEVS[$i]}"

    echo "  ${ip}: DESTROYING boot=${boot}"

    ssh_node "$ip" "
      for entry in \$(efibootmgr 2>/dev/null | grep '^Boot[0-9]' | grep -i 'proxmox\|debian\|UEFI\|nvme' | sed 's/Boot\([0-9A-F]*\).*/\1/'); do
        efibootmgr -b \${entry} -B 2>/dev/null && echo '    Removed EFI entry'
      done
      # Zero LVM/filesystem headers on each partition BEFORE destroying GPT.
      # wipefs -a cannot clear LVM signatures on active/mounted partitions.
      # dd to zero the first 10MB of each partition destroys the LVM PV header,
      # filesystem superblock, and any other magic bytes at partition offsets.
      # Without this, the Proxmox installer fails with 'unable to initialize
      # physical volume' because pvcreate finds stale LVM2_member signatures.
      for part in /dev/${boot}p*; do
        dd if=/dev/zero of=\"\${part}\" bs=1M count=10 2>/dev/null || true
      done
      sgdisk --zap-all /dev/${boot} 2>/dev/null
      wipefs -a /dev/${boot} 2>/dev/null
      echo '    Boot NVMe wiped: ${boot}'
    "
  done

  echo ""
  echo "--- Erasing secrets ---"
  if [[ -n "$SINGLE_NODE" ]]; then
    echo "  Skipping (single-node mode)"
  elif [[ -f "${REPO_DIR}/site/sops/secrets.yaml" ]]; then
    shred -u "${REPO_DIR}/site/sops/secrets.yaml" 2>/dev/null || rm -f "${REPO_DIR}/site/sops/secrets.yaml"
    git -C "$REPO_DIR" add site/sops/secrets.yaml 2>/dev/null || true
    git -C "$REPO_DIR" commit -m "reset-cluster --cluster: erase secrets" --allow-empty 2>/dev/null || true
    echo "  secrets.yaml erased"
  fi

  echo ""
  echo "=== NODES ARE NO LONGER BOOTABLE ==="
  echo "Next steps:"
  echo "  1. Reinstall Proxmox from USB on all nodes"
  echo "  2. framework/scripts/bootstrap-sops.sh"
  echo "  3. framework/scripts/rebuild-cluster.sh"
}

do_reset_nas() {
  do_reset_cluster

  echo ""
  echo "--- Cleaning NAS ---"
  if [[ -n "$NAS_IP" ]]; then
    echo "  Dropping tofu_state database..."
    ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "${NAS_SSH_USER}@${NAS_IP}" \
      "psql -U postgres -p ${NAS_PG_PORT} -c 'DROP DATABASE IF EXISTS tofu_state;' 2>/dev/null" \
      || echo "  WARNING: Could not drop database"

    echo "  Stopping sentinel Gatus..."
    ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "${NAS_SSH_USER}@${NAS_IP}" \
      "/volume1/@appstore/ContainerManager/usr/bin/docker stop gatus-sentinel 2>/dev/null; /volume1/@appstore/ContainerManager/usr/bin/docker rm gatus-sentinel 2>/dev/null" || true

    echo "  Stopping placement watchdog..."
    ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "${NAS_SSH_USER}@${NAS_IP}" \
      "PORT_PID=\$(netstat -tlnp 2>/dev/null | grep ':9200 ' | awk '{print \$7}' | cut -d/ -f1); [ -n \"\$PORT_PID\" ] && kill \$PORT_PID 2>/dev/null; true" || true
  fi

  echo ""
  echo "NOTE: PBS backup data on the NAS was NOT wiped."
  echo "To wipe (DESTRUCTIVE): ssh ${NAS_SSH_USER}@${NAS_IP} and remove the PBS datastore contents."
}

do_reset_builds() {
  echo "--- Removing build artifacts ---"
  [[ -d "${REPO_DIR}/build" ]] && rm -rf "${REPO_DIR}/build" && echo "  Removed build/"
  [[ -f "${REPO_DIR}/site/tofu/image-versions.auto.tfvars" ]] && rm -f "${REPO_DIR}/site/tofu/image-versions.auto.tfvars" && echo "  Removed image-versions.auto.tfvars"
  find "${REPO_DIR}" -maxdepth 2 -name "result" -type l -exec rm -f {} \; 2>/dev/null && echo "  Removed Nix result symlinks"
  echo "  Build artifacts removed."
}

do_reset_secrets() {
  do_reset_builds

  echo ""
  echo "--- Erasing operator age key ---"
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    shred -u "${REPO_DIR}/operator.age.key" 2>/dev/null || rm -f "${REPO_DIR}/operator.age.key"
    echo "  Erased operator.age.key"
  else
    echo "  No operator.age.key found"
  fi

  echo ""
  echo "WARNING: You can no longer decrypt site/sops/secrets.yaml."
  echo "To restore: framework/scripts/bootstrap-sops.sh"
}

do_reset_distclean() {
  do_reset_nas
  do_reset_secrets

  echo ""
  echo "=== DISTCLEAN COMPLETE ==="
  echo "Workspace is at fresh-clone state."
  echo "To rebuild:"
  echo "  1. framework/scripts/bootstrap-sops.sh"
  echo "  2. Reinstall Proxmox on all nodes"
  echo "  3. framework/scripts/rebuild-cluster.sh"
}

do_reset_workstation() {
  echo ""
  echo "--- Cleaning workstation build artifacts ---"

  # OpenTofu state directory
  if [[ -d "${REPO_DIR}/site/tofu/.terraform" ]]; then
    rm -rf "${REPO_DIR}/site/tofu/.terraform"
    echo "  Removed site/tofu/.terraform/"
  fi
  if [[ -f "${REPO_DIR}/site/tofu/.terraform.lock.hcl" ]]; then
    rm -f "${REPO_DIR}/site/tofu/.terraform.lock.hcl"
    echo "  Removed site/tofu/.terraform.lock.hcl"
  fi

  # Build directory
  if [[ -d "${REPO_DIR}/build" ]]; then
    rm -rf "${REPO_DIR}/build"
    echo "  Removed build/"
  fi

  # Nix builder overlay (macOS only)
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "  Resetting nix builder..."
    "${REPO_DIR}/framework/scripts/setup-nix-builder.sh" --stop 2>/dev/null || true
    rm -f "${HOME}/.nix-builder/store.img"
    echo "  Builder overlay removed (builder will restart on next build)"
  fi

  # Optional: cold builds (nix-collect-garbage -d)
  if [[ $COLD_BUILDS -eq 1 ]]; then
    echo ""
    echo "--- Cleaning nix store (cold build test) ---"
    echo "  This removes ALL nix store paths. Next build downloads everything."
    nix-collect-garbage -d 2>/dev/null || true
    echo "  Nix store cleaned"
  fi

  # SSH known_hosts for all node and VM IPs
  echo "  Cleaning SSH known_hosts..."
  local cleaned=0
  for ip in "${NODE_IPS[@]}"; do
    ssh-keygen -R "$ip" 2>/dev/null && cleaned=$((cleaned + 1)) || true
  done
  for vm_ip in $(yq -r '.vms[].ip' "$CONFIG" 2>/dev/null); do
    ssh-keygen -R "$vm_ip" 2>/dev/null && cleaned=$((cleaned + 1)) || true
  done
  for app_ip in $(yq -r '.applications[].environments[].ip // empty' "$APPS_CONFIG" 2>/dev/null); do
    ssh-keygen -R "$app_ip" 2>/dev/null && cleaned=$((cleaned + 1)) || true
  done
  for app_mgmt in $(yq -r '.applications[].environments[].mgmt_nic.ip // empty' "$APPS_CONFIG" 2>/dev/null); do
    ssh-keygen -R "$app_mgmt" 2>/dev/null && cleaned=$((cleaned + 1)) || true
  done
  echo "  Cleaned ${cleaned} SSH known_hosts entries"
}

do_reset_level5() {
  # Cluster destruction (VMs, pools, boot drives, secrets.yaml)
  do_reset_cluster

  # NAS cleanup
  echo ""
  echo "--- Cleaning NAS ---"
  if [[ -n "$NAS_IP" ]]; then
    local NFS_EXPORT
    NFS_EXPORT=$(yq -r '.nas.nfs_export' "$CONFIG" 2>/dev/null || echo "")

    # PBS datastore contents — may be irreplaceable
    if [[ -n "$NFS_EXPORT" && "$NFS_EXPORT" != "null" ]]; then
      local BACKUP_COUNT
      BACKUP_COUNT=$(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 -o BatchMode=yes \
        "${NAS_SSH_USER}@${NAS_IP}" \
        "find ${NFS_EXPORT} -name '*.fidx' -o -name '*.didx' 2>/dev/null | wc -l" 2>/dev/null || echo "0")

      if [[ "$BACKUP_COUNT" -gt 0 ]]; then
        echo ""
        echo "  WARNING: PBS datastore at ${NFS_EXPORT} contains ${BACKUP_COUNT} backup files."
        echo "  This may include IRREPLACEABLE data (GitLab history, Roon playlists, etc.)."
        echo "  Once deleted, this data CANNOT be recovered."
        echo ""
        local NFS_BASENAME
        NFS_BASENAME=$(basename "$NFS_EXPORT")
        read -rp "  Type '${NFS_BASENAME}' to proceed: " CONFIRM_PBS
        if [[ "$CONFIRM_PBS" != "$NFS_BASENAME" ]]; then
          echo "  Skipping PBS datastore cleanup."
        else
          # Remove backup content AND PBS metadata (.chunks, .lock).
          # configure-pbs.sh will recreate the datastore from scratch on
          # the next rebuild. Leave the directory itself (NFS mount point).
          ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "${NAS_SSH_USER}@${NAS_IP}" \
            "cd '${NFS_EXPORT}' && rm -rf .chunks .lock vm/ ct/ ns/ 2>/dev/null || true"
          echo "  PBS datastore cleared (configure-pbs.sh will recreate)"
        fi
      else
        echo "  PBS datastore is empty — nothing to protect"
      fi
    fi

    # Sentinel Gatus container
    echo "  Removing sentinel Gatus container..."
    ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 "${NAS_SSH_USER}@${NAS_IP}" \
      "docker rm -f gatus-sentinel 2>/dev/null || /volume1/@appstore/ContainerManager/usr/bin/docker rm -f gatus-sentinel 2>/dev/null" 2>/dev/null || true

    # Placement watchdog
    echo "  Stopping placement watchdog..."
    ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 "${NAS_SSH_USER}@${NAS_IP}" \
      "PORT_PID=\$(netstat -tlnp 2>/dev/null | grep ':9200 ' | awk '{print \$7}' | cut -d/ -f1); [ -n \"\$PORT_PID\" ] && kill \$PORT_PID 2>/dev/null; true" 2>/dev/null || true

    # PostgreSQL schemas
    echo "  Dropping OpenTofu state schemas..."
    ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 "${NAS_SSH_USER}@${NAS_IP}" \
      "sudo -u postgres psql -p ${NAS_PG_PORT} -c 'DROP DATABASE IF EXISTS tofu_state;' 2>/dev/null; \
       sudo -u postgres psql -p ${NAS_PG_PORT} -c 'CREATE DATABASE tofu_state;' 2>/dev/null; \
       sudo -u postgres psql -p ${NAS_PG_PORT} -c 'GRANT ALL ON DATABASE tofu_state TO tofu;' 2>/dev/null" \
      || echo "  WARNING: Could not reset database"
    echo "  NAS cleanup complete"
  fi

  # Secrets (age key) — requires interactive confirmation
  echo ""
  echo "--- Erasing operator age key ---"
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    echo ""
    echo "  WARNING: Deleting operator.age.key."
    echo "  This is the encryption root for all SOPS secrets."
    echo "  Without a backup, secrets.yaml CANNOT be decrypted."
    echo ""
    read -rp "  Type 'operator.age.key' to proceed: " CONFIRM_KEY
    if [[ "$CONFIRM_KEY" != "operator.age.key" ]]; then
      echo "  Skipping age key deletion."
    else
      shred -u "${REPO_DIR}/operator.age.key" 2>/dev/null || rm -f "${REPO_DIR}/operator.age.key"
      echo "  operator.age.key erased"
    fi
  else
    echo "  No operator.age.key found"
  fi

  # Workstation cleanup
  do_reset_workstation

  echo ""
  echo "=== LEVEL 5 CLEANUP COMPLETE ==="
  echo ""
  echo "Next steps:"
  echo "  1. Reinstall Proxmox on all nodes"
  echo "  2. framework/scripts/bootstrap-sops.sh"
  echo "  3. Edit config.yaml if needed (PBS path, acme mode)"
  echo "  4. framework/scripts/rebuild-cluster.sh"
}

do_reset_forensic() {
  # Cryptographic erasure of all drives and secrets.
  # Not yet implemented — requires hardware-specific testing of:
  #   - blkdiscard --secure (NVMe Secure Erase)
  #   - nvme sanitize (NVMe Sanitize command)
  #   - ATA Secure Erase for non-NVMe drives
  # Behavior varies across NVMe firmware. Some drives don't support
  # crypto erase at all. See architecture.md section 13.5.
  echo "ERROR: --forensic is not yet implemented."
  echo "See architecture.md section 13.5 for the design."
  echo "Implementation requires hardware-specific testing of NVMe Secure Erase."
  exit 1
}

# =====================================================================
# Dry-run helpers
# =====================================================================

needs_cluster() {
  [[ "$LEVEL" == "vms" || "$LEVEL" == "storage" || "$LEVEL" == "cluster" || "$LEVEL" == "nas" || "$LEVEL" == "distclean" || "$LEVEL" == "level5" ]]
}

needs_storage() {
  [[ "$LEVEL" == "storage" || "$LEVEL" == "cluster" || "$LEVEL" == "nas" || "$LEVEL" == "distclean" || "$LEVEL" == "level5" ]]
}

needs_boot_destroy() {
  [[ "$LEVEL" == "cluster" || "$LEVEL" == "nas" || "$LEVEL" == "distclean" || "$LEVEL" == "level5" ]]
}

print_dry_run() {
  if [[ -n "$SINGLE_NODE" ]]; then
    echo "=== reset-cluster.sh --${LEVEL} --node ${SINGLE_NODE} (DRY RUN) ==="
    echo ""
    echo "Scope: ${SINGLE_NODE} only (${NODE_IPS[0]})"
  else
    echo "=== reset-cluster.sh --${LEVEL} (DRY RUN) ==="
  fi
  echo ""
  echo "This will destroy:"

  if needs_cluster; then
    echo ""
    echo "  Level --vms:"
    echo "    VMs:            All VMs on ${NODE_IPS[*]:-no nodes configured}"
    echo "    HA resources:   All on targeted node(s)"
    echo "    Replication:    All jobs on targeted node(s)"
    echo "    Snippets:       All CIDATA files on targeted node(s)"
    if [[ -z "$SINGLE_NODE" ]]; then
      echo "    PBS storage:    pbs-nas entry removed"
      echo "    Backup jobs:    All PBS backup jobs removed"
      echo "    Metric servers: All metric server entries removed"
      echo "    Tofu state:     PostgreSQL on NAS (${NAS_IP:-unknown})"
    else
      echo "    PBS storage:    skipped (single-node mode)"
      echo "    Backup jobs:    skipped (single-node mode)"
      echo "    Metric servers: skipped (single-node mode)"
      echo "    Tofu state:     skipped (single-node mode)"
    fi
  fi

  if needs_storage; then
    echo ""
    echo "  Level --storage (adds to --vms):"
    echo "    ZFS pool:     '${POOL_NAME}' on ${NODE_IPS[*]}"
    echo "    Data NVMe:    Partition tables wiped on ${NODE_IPS[*]}"
  fi

  if needs_boot_destroy; then
    echo ""
    echo "  Level --cluster (adds to --storage):"
    echo "    Boot NVMe:    ENTIRE BOOT DRIVE WIPED on ${NODE_IPS[*]}"
    echo "    UEFI entries: Boot entries removed via efibootmgr"
    if [[ -z "$SINGLE_NODE" ]]; then
      echo "    Secrets:      site/sops/secrets.yaml erased"
    else
      echo "    Secrets:      skipped (single-node mode)"
    fi
    echo ""
    echo "  *** NODES WILL NOT BOOT AFTER THIS OPERATION ***"
    echo "  *** PROXMOX MUST BE REINSTALLED FROM USB ***"
  fi

  if [[ "$LEVEL" == "nas" || "$LEVEL" == "distclean" ]]; then
    echo ""
    echo "  Level --nas (adds to --cluster):"
    echo "    PostgreSQL:   tofu_state database dropped"
    echo "    Sentinel:     Gatus container stopped and removed"
    echo "    Watchdog:     Placement watchdog stopped"
  fi

  if [[ "$LEVEL" == "level5" ]]; then
    echo ""
    echo "  Level --level5 (adds to --cluster):"
    echo "    Secrets:      operator.age.key erased (IRREPLACEABLE without backup)"
    echo "                  → Will prompt: Type 'operator.age.key' to proceed"
    local NFS_EXP
    NFS_EXP=$(yq -r '.nas.nfs_export' "$CONFIG" 2>/dev/null || echo "unknown")
    echo "    PBS data:     ${NFS_EXP}/* emptied"
    local BKUP_CNT
    BKUP_CNT=$(ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=5 -o BatchMode=yes \
      "${NAS_SSH_USER}@${NAS_IP}" \
      "find ${NFS_EXP} -name '*.fidx' -o -name '*.didx' 2>/dev/null | wc -l" 2>/dev/null || echo "?")
    if [[ "$BKUP_CNT" != "0" && "$BKUP_CNT" != "?" ]]; then
      echo "                  Contains ${BKUP_CNT} backup files (IRREPLACEABLE)"
      echo "                  → Will prompt: Type '$(basename "$NFS_EXP")' to proceed"
    else
      echo "                  (empty — no backup data to protect)"
    fi
    echo "    NAS:          Sentinel container, watchdog, tofu_state DB"
    echo "    Workstation:  site/tofu/.terraform/, build/, nix builder overlay"
    echo "    SSH:          known_hosts cleaned for all node/VM IPs"
    if [[ $COLD_BUILDS -eq 1 ]]; then
      echo "    Nix store:    ALL paths removed (cold build test)"
    fi
    echo ""
    echo "  After cleanup:"
    echo "    1. Reinstall Proxmox on all nodes"
    echo "    2. framework/scripts/bootstrap-sops.sh"
    echo "    3. Edit config.yaml if needed (PBS path, acme mode)"
    echo "    4. framework/scripts/rebuild-cluster.sh"
  fi

  if [[ "$LEVEL" == "builds" || "$LEVEL" == "secrets" || "$LEVEL" == "distclean" ]]; then
    echo ""
    echo "  Level --builds:"
    echo "    build/ directory"
    echo "    site/tofu/image-versions.auto.tfvars"
    echo "    Nix result symlinks"
  fi

  if [[ "$LEVEL" == "secrets" || "$LEVEL" == "distclean" ]]; then
    echo ""
    echo "  Level --secrets (adds to --builds):"
    echo "    operator.age.key (shredded — SOPS decryption lost)"
  fi

  # Disk identification for storage+ levels
  if needs_storage && [[ ${#NODE_IPS[@]} -gt 0 ]]; then
    echo ""
    echo "  Disk identification:"
    collect_disk_info
    for (( i=0; i<${#NODE_IPS[@]}; i++ )); do
      local boot_label="PROTECTED"
      needs_boot_destroy && boot_label="DESTROY"
      printf "    %-6s (%s): boot=%-8s (%s)  data=%-8s (WIPE)\n" \
        "${NODE_NAMES[$i]}" "${NODE_IPS[$i]}" \
        "${BOOT_DEVS[$i]}" "$boot_label" \
        "${DATA_DEVS[$i]}"
    done
  fi

  echo ""
  echo "This will NOT destroy:"
  case "$LEVEL" in
    vms)       echo "    ZFS pools, boot filesystem, cluster, NAS, workstation" ;;
    storage)   echo "    Boot filesystem, cluster membership, NAS, workstation" ;;
    cluster)   echo "    NAS, workstation (operator.age.key, build artifacts), config.yaml" ;;
    level5)    echo "    Git repo, config.yaml, nix store (unless --cold-builds)" ;;
    nas)       echo "    Workstation (operator.age.key, build artifacts), config.yaml" ;;
    builds)    echo "    Source code, config, secrets, cluster, NAS" ;;
    secrets)   echo "    Source code, config.yaml, git repo, cluster" ;;
    distclean) echo "    Git repo, config.yaml" ;;
  esac

  echo ""
  local node_flag=""
  [[ -n "$SINGLE_NODE" ]] && node_flag=" --node ${SINGLE_NODE}"
  echo "To proceed: $(basename "$0") --${LEVEL}${node_flag} --confirm"
}

# =====================================================================
# Main
# =====================================================================

if [[ "$LEVEL" == "forensic" ]]; then
  do_reset_forensic
fi

if [[ $CONFIRM -eq 0 ]]; then
  print_dry_run
  exit 0
fi

if [[ -n "$SINGLE_NODE" ]]; then
  echo "=== reset-cluster.sh --${LEVEL} --node ${SINGLE_NODE} ==="
else
  echo "=== reset-cluster.sh --${LEVEL} ==="
fi
echo ""

case "$LEVEL" in
  vms)       do_reset_vms ;;
  storage)   do_reset_storage ;;
  cluster)   do_reset_cluster ;;
  level5)    do_reset_level5 ;;
  nas)       do_reset_nas ;;
  builds)    do_reset_builds ;;
  secrets)   do_reset_secrets ;;
  distclean) do_reset_distclean ;;
esac

echo ""
echo "=== Reset --${LEVEL} complete ==="
