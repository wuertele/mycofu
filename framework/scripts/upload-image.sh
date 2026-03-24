#!/usr/bin/env bash
# upload-image.sh — Upload a built VM image to all Proxmox nodes.
#
# Usage:
#   framework/scripts/upload-image.sh build/dns-a3f82c1d.img dns
#   framework/scripts/upload-image.sh --dry-run build/dns-a3f82c1d.img dns
#
# After uploading, old images for the same role are pruned automatically.
# Images referenced by running VMs are never removed (safe for dev/prod
# sharing the same image).
#
# The destination filename is the basename of <source-file>.
# Always uploads to every node in site/config.yaml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG="${REPO_DIR}/site/config.yaml"
DRY_RUN=0
PRUNE=0
SOURCE_FILE=""
ROLE=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <source-file> <role>

Upload a VM image to all Proxmox nodes via SCP.

Arguments:
  <source-file>   Path to the image file (e.g., build/dns-a3f82c1d.img)
  <role>          Role name (e.g., dns, vault) — used for pruning

Options:
  --prune         (deprecated — pruning is now automatic)
  --dry-run       Show commands without running them
  --config <path> Path to config.yaml (default: site/config.yaml)
  --help          Show this help message
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --prune) PRUNE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --config) CONFIG="$2"; shift 2 ;;
    -*) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -z "$SOURCE_FILE" ]]; then
        SOURCE_FILE="$1"
      elif [[ -z "$ROLE" ]]; then
        ROLE="$1"
      else
        echo "ERROR: Unexpected argument: $1" >&2; usage >&2; exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$SOURCE_FILE" || -z "$ROLE" ]]; then
  echo "ERROR: Both <source-file> and <role> are required." >&2
  usage >&2
  exit 2
fi

if [[ ! -f "$SOURCE_FILE" ]]; then
  echo "ERROR: Source file not found: $SOURCE_FILE" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: $CONFIG" >&2
  exit 1
fi

# Read image storage path from config.yaml
IMAGE_STORAGE_PATH=$(yq -r '.proxmox.image_storage_path' "$CONFIG")
if [[ -z "$IMAGE_STORAGE_PATH" || "$IMAGE_STORAGE_PATH" == "null" ]]; then
  echo "ERROR: proxmox.image_storage_path not set in site/config.yaml" >&2
  echo "Add:   proxmox.image_storage_path: /var/lib/vz/template/iso" >&2
  exit 1
fi

# Destination filename = basename of source file (already has .img extension)
DEST_FILENAME="$(basename "$SOURCE_FILE")"

SOURCE_SIZE=$(du -h "$SOURCE_FILE" | cut -f1)
echo "Uploading: ${DEST_FILENAME} (${SOURCE_SIZE})"

while IFS= read -r NODE_IP; do
  NODE_NAME=$(yq -r ".nodes[] | select(.mgmt_ip == \"${NODE_IP}\") | .name" "$CONFIG")
  DEST_PATH="${IMAGE_STORAGE_PATH}/${DEST_FILENAME}"

  echo ""
  echo "==> ${NODE_NAME} (${NODE_IP}): ${DEST_PATH}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] ssh root@${NODE_IP} mkdir -p ${IMAGE_STORAGE_PATH}"
    echo "  [dry-run] scp ${SOURCE_FILE} root@${NODE_IP}:${DEST_PATH}"
  else
    # SHA-stamped filenames mean a name match guarantees content match
    if ssh -n "root@${NODE_IP}" "test -f ${DEST_PATH}" 2>/dev/null; then
      echo "  ${DEST_FILENAME} already exists on ${NODE_NAME}, skipping"
    else
      echo "  Ensuring directory exists..."
      # -n: prevent SSH from consuming loop stdin (see scripts/README.md)
      ssh -n "root@${NODE_IP}" "mkdir -p ${IMAGE_STORAGE_PATH}"

      echo "  Uploading..."
      scp "$SOURCE_FILE" "root@${NODE_IP}:${DEST_PATH}"

      echo "  Verifying..."
      ssh -n "root@${NODE_IP}" "ls -lh ${DEST_PATH}"
    fi
  fi
done < <(yq -r '.nodes[].mgmt_ip' "$CONFIG")

echo ""
echo "Upload complete."

# --- Prune old images ---

# Always prune old images for this role after upload.
# Protected: any image referenced by a running VM on that node.
# A dev deploy may share an image with a prod VM — the running-VM
# check catches this regardless of which environment deployed it.
echo ""
echo "Pruning old ${ROLE} images..."

while IFS= read -r NODE_IP; do
  NODE_NAME=$(yq -r ".nodes[] | select(.mgmt_ip == \"${NODE_IP}\") | .name" "$CONFIG")

  # Collect images referenced by ALL running VMs on this node
  USED_IMAGES=$(ssh -n "root@${NODE_IP}" '
    for vmid in $(qm list 2>/dev/null | tail -n +2 | awk "{print \$1}"); do
      qm config $vmid 2>/dev/null | grep "file=" | sed "s/.*iso\///" | sed "s/,.*//"
    done
  ' 2>/dev/null | sort -u)

  while IFS= read -r OLD_IMG; do
    [[ -z "$OLD_IMG" ]] && continue
    OLD_BASENAME=$(basename "$OLD_IMG")

    # Also protect the image we just uploaded
    [[ "$OLD_BASENAME" == "$DEST_FILENAME" ]] && continue

    # Only prune images for this role
    echo "$OLD_BASENAME" | grep -q "^${ROLE}-" || continue

    # Check if any running VM uses this image
    if echo "$USED_IMAGES" | grep -qx "$OLD_BASENAME"; then
      if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [dry-run] Keep ${NODE_NAME}:${OLD_BASENAME} (in use by running VM)"
      fi
      continue
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "  [dry-run] Prune ${NODE_NAME}:${OLD_BASENAME}"
    else
      echo "  Pruning ${NODE_NAME}:${OLD_BASENAME}"
      ssh -n "root@${NODE_IP}" "rm -f ${IMAGE_STORAGE_PATH}/${OLD_BASENAME}"
    fi
  done < <(ssh -n "root@${NODE_IP}" \
             "ls ${IMAGE_STORAGE_PATH}/${ROLE}-*.img 2>/dev/null" || true)
done < <(yq -r '.nodes[].mgmt_ip' "$CONFIG")

echo "Prune complete."
