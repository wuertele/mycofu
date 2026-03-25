#!/usr/bin/env bash
# build-all-images.sh — Build every role from image manifests.
#
# Reads roles from framework/images.yaml (infrastructure) and site/images.yaml
# (site-specific applications), merges them (erroring on duplicates), and builds
# each role via build-image.sh.
#
# Sequential builds share the nix store dependency tree: the first role builds
# the shared closure (base.nix, nixpkgs), subsequent roles find those derivations
# cached and only build role-specific packages.
#
# Usage:
#   framework/scripts/build-all-images.sh [--dev]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FRAMEWORK_MANIFEST="${REPO_DIR}/framework/images.yaml"
SITE_MANIFEST="${REPO_DIR}/site/images.yaml"

DEV_FLAG=""
for arg in "$@"; do
  case "$arg" in
    --dev) DEV_FLAG="--dev" ;;
    *)
      echo "ERROR: Unknown argument: $arg" >&2
      echo "Usage: $(basename "$0") [--dev]" >&2
      exit 2
      ;;
  esac
done

# --- Read roles from both manifests ---
FRAMEWORK_ROLES=""
if [[ -f "$FRAMEWORK_MANIFEST" ]]; then
  FRAMEWORK_ROLES=$(yq -r '.roles | keys | .[]' "$FRAMEWORK_MANIFEST" 2>/dev/null || true)
fi

SITE_ROLES=""
if [[ -f "$SITE_MANIFEST" ]]; then
  SITE_ROLES=$(yq -r '.roles | keys | .[]' "$SITE_MANIFEST" 2>/dev/null || true)
fi

# --- Check for duplicate role names across manifests ---
for role in $SITE_ROLES; do
  if echo "$FRAMEWORK_ROLES" | grep -qx "$role"; then
    echo "ERROR: role '$role' exists in both framework and site manifests" >&2
    exit 1
  fi
done

ALL_ROLES="$FRAMEWORK_ROLES $SITE_ROLES"

# --- Read catalog application roles from config.yaml ---
SITE_CONFIG="${REPO_DIR}/site/config.yaml"
APP_ROLES=""
if [[ -f "$SITE_CONFIG" ]]; then
  APP_ROLES=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$SITE_CONFIG" 2>/dev/null || true)
fi

# Check for duplicate role names (catalog apps vs manifests)
for role in $APP_ROLES; do
  if echo "$FRAMEWORK_ROLES $SITE_ROLES" | tr ' ' '\n' | grep -qx "$role"; then
    echo "ERROR: catalog application '$role' conflicts with a role in image manifests" >&2
    exit 1
  fi
done

ALL_ROLES="$ALL_ROLES $APP_ROLES"

if [[ -z "${ALL_ROLES// /}" ]]; then
  echo "ERROR: No roles found in manifests or config.yaml applications" >&2
  exit 1
fi

# --- Pre-build nix store space check ---
# When base.nix changes, every image gets a new hash. The host store
# accumulates both old and new closures. Check free space and GC if needed.

check_store_space() {
  local label="${1:-Pre-build}"
  local min_free_gb="${2:-${NIX_MIN_FREE_GB:-20}}"
  local free_kb
  free_kb=$(df -P /nix/store 2>/dev/null | tail -1 | awk '{print $4}')
  local free_gb=$((free_kb / 1024 / 1024))

  if [[ "$free_gb" -lt "$min_free_gb" ]]; then
    echo ""
    echo "=== ${label}: host nix store low on space (${free_gb}GB free, need ${min_free_gb}GB) ==="
    echo "Running garbage collection and resetting builder..."

    # Root-aware GC: removes paths not reachable from any GC root.
    # Current images (via build/.gc-roots/ symlinks from --out-link)
    # and their shared closures are preserved.
    echo "  Collecting garbage..."
    nix-collect-garbage 2>/dev/null

    if [[ "$(uname)" == "Darwin" ]]; then
      # macOS: restart builder with fresh overlay
      echo "  Restarting builder with fresh overlay..."
      pkill -f "qemu.*nixos.qcow2" 2>/dev/null || true
      for i in $(seq 1 15); do
        pgrep -f "qemu.*nixos.qcow2" >/dev/null 2>&1 || break
        sleep 1
      done
      rm -f "${HOME}/.nix-builder/store.img" 2>/dev/null || true
      BUILDER_START="${HOME}/.nix-builder/start-builder.sh"
      if [[ -x "$BUILDER_START" ]]; then
        bash "$BUILDER_START"
        for i in $(seq 1 24); do
          nc -z localhost 31022 2>/dev/null && break
          sleep 5
        done
      fi
    fi

    free_kb=$(df -P /nix/store 2>/dev/null | tail -1 | awk '{print $4}')
    free_gb=$((free_kb / 1024 / 1024))
    echo "  After GC: ${free_gb}GB free"

    if [[ "$free_gb" -lt "$min_free_gb" ]]; then
      echo "WARNING: Still low on space after GC (${free_gb}GB)."
      echo "The host disk may be too small for the full build set."
    fi
  else
    echo "${label}: ${free_gb}GB free (threshold: ${min_free_gb}GB) — OK"
  fi
}

# Reset the builder overlay between builds on macOS. Each build populates the
# overlay with paths not in the host store. After a large build (gitlab ~6.6G),
# the overlay may be full. Resetting between builds ensures each build starts
# with a fresh overlay. The host store caches successful build outputs, so
# subsequent builds of the same role are instant (nix cache hit).
reset_builder_overlay() {
  if [[ "$(uname)" != "Darwin" ]]; then
    return 0
  fi
  local overlay="${HOME}/.nix-builder/store.img"
  if [[ ! -f "$overlay" ]]; then
    return 0
  fi
  local overlay_size
  overlay_size=$(du -m "$overlay" 2>/dev/null | cut -f1)
  # Only reset if overlay > 200MB (skip if small — saves restart time)
  if [[ "$overlay_size" -gt 200 ]]; then
    echo "  Resetting builder overlay (${overlay_size}MB)..."
    pkill -f "qemu.*nixos.qcow2" 2>/dev/null || true
    for i in $(seq 1 15); do
      pgrep -f "qemu.*nixos.qcow2" >/dev/null 2>&1 || break
      sleep 1
    done
    rm -f "$overlay"
    BUILDER_START="${HOME}/.nix-builder/start-builder.sh"
    if [[ -x "$BUILDER_START" ]]; then
      bash "$BUILDER_START"
      for i in $(seq 1 24); do
        nc -z localhost 31022 2>/dev/null && break
        sleep 5
      done
      # Expand store overlay after builder recreates it at default size
      local store_gb
      store_gb=$(yq '.nix_builder.store_gb // 20' "${REPO_DIR}/site/config.yaml" 2>/dev/null || echo 20)
      local want_bytes=$(( store_gb * 1024 * 1024 * 1024 ))
      local cur_bytes
      cur_bytes=$(stat -f%z "$overlay" 2>/dev/null || echo 0)
      if [[ "$cur_bytes" -lt "$want_bytes" ]]; then
        dd if=/dev/zero of="$overlay" bs=1 count=0 seek=$want_bytes 2>/dev/null
        sudo ssh -n -i /etc/nix/builder_ed25519 \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          -p 31022 builder@localhost "sudo resize2fs /dev/vdb" 2>/dev/null || true
      fi
    fi
  fi
}

check_store_space "Pre-build"

# --- Build each role ---
for ROLE in $ALL_ROLES; do
  # Per-image space check (lower threshold — only triggers if space
  # got tight during the build cycle from intermediate products)
  check_store_space "Before ${ROLE}" 8

  # Check if this is a catalog application (from config.yaml)
  if echo "$APP_ROLES" | tr ' ' '\n' | grep -qx "$ROLE"; then
    # Catalog application — host config is at site/nix/hosts/<app>.nix
    HOST_CONFIG="site/nix/hosts/${ROLE}.nix"
    if [[ ! -f "${REPO_DIR}/${HOST_CONFIG}" ]]; then
      echo "ERROR: Host config not found for catalog app '${ROLE}': ${HOST_CONFIG}" >&2
      echo "Run 'enable-app.sh ${ROLE}' to generate it." >&2
      exit 1
    fi

    echo ""
    echo "=========================================="
    echo "Building: ${ROLE} (catalog application)"
    echo "=========================================="

    "${SCRIPT_DIR}/build-image.sh" $DEV_FLAG "$HOST_CONFIG" "$ROLE"
    reset_builder_overlay
    continue
  fi

  # Determine which manifest contains this role
  if yq -e ".roles.${ROLE}" "$FRAMEWORK_MANIFEST" >/dev/null 2>&1; then
    MANIFEST="$FRAMEWORK_MANIFEST"
  else
    MANIFEST="$SITE_MANIFEST"
  fi

  CATEGORY=$(yq -r ".roles.${ROLE}.category" "$MANIFEST")

  echo ""
  echo "=========================================="
  echo "Building: ${ROLE} (${CATEGORY})"
  echo "=========================================="

  case "$CATEGORY" in
    nix)
      HOST_CONFIG=$(yq -r ".roles.${ROLE}.host_config" "$MANIFEST")
      "${SCRIPT_DIR}/build-image.sh" $DEV_FLAG "$HOST_CONFIG" "$ROLE"
      ;;
    external)
      BUILD_SCRIPT=$(yq -r ".roles.${ROLE}.build_script" "$MANIFEST")
      "${SCRIPT_DIR}/build-image.sh" $DEV_FLAG --external "$BUILD_SCRIPT" "$ROLE"
      ;;
    *)
      echo "ERROR: Unknown category '$CATEGORY' for role '$ROLE'" >&2
      exit 1
      ;;
  esac
  reset_builder_overlay
done

echo ""
echo "All images built. image-versions.auto.tfvars:"
cat "${REPO_DIR}/site/tofu/image-versions.auto.tfvars"
