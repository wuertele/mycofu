#!/usr/bin/env bash
# build-image.sh — Build a VM image and name it with a content-addressed hash.
#
# For NixOS images (category: nix): the hash comes from the nix derivation
# output path. Same nix inputs → same hash → same filename → no VM recreation.
#
# For external images (category: external): the hash comes from SHA256 of the
# built image file. Same file content → same hash → same filename.
#
# Usage:
#   framework/scripts/build-image.sh [--dev] <host-nix-file> <role>
#   framework/scripts/build-image.sh [--dev] --external <build-script> <role>
#
# Examples:
#   framework/scripts/build-image.sh site/nix/hosts/dns.nix dns
#   # Produces: build/dns-a3f82c1d.img (content-addressed, stable across commits)
#
#   framework/scripts/build-image.sh --dev site/nix/hosts/dns.nix dns
#   # Produces: build/dns-a3f82c1d-dev.img (dirty tree OK)
#
#   framework/scripts/build-image.sh --external site/images/myapp/build.sh myapp
#   # Produces: build/myapp-<sha256-8>.img
#
# Builder types (from site/config.yaml nix_builder.type):
#   local          - Build locally (requires x86_64-linux)
#   linux-builder  - Build via nix-daemon linux-builder (macOS transparent)
#   remote         - Delegate to a remote builder via SSH (requires
#                    nix_builder.remote_user and remote_host in config)

set -euo pipefail

# Ensure nix is on PATH (macOS default bash may not have it)
for p in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin"; do
  if [[ -x "${p}/nix" ]] && [[ ":${PATH}:" != *":${p}:"* ]]; then
    export PATH="${p}:${PATH}"
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
NIX_BUILD_FLAGS=()

# Portable in-place sed (BSD vs GNU)
sed_i() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dev] <host-nix-file> <role>
       $(basename "$0") [--dev] --external <build-script> <role>
       $(basename "$0") --list
       $(basename "$0") --help

Build a VM image with content-addressed naming.

Arguments:
  <host-nix-file>  Path to the NixOS host config (e.g., site/nix/hosts/dns.nix)
  <role>           Role name (e.g., dns, vault)
                   The flake output <role>-image must exist in flake.nix.

Options:
  --dev          Build from dirty working tree (image name gets -dev suffix).
  --external     Build using an external script instead of nix.
  --list         List available image targets from the flake
  --help         Show this help message

Examples:
  $(basename "$0") site/nix/hosts/dns.nix dns
  $(basename "$0") --dev site/nix/hosts/dns.nix dns
  $(basename "$0") --external site/images/myapp/build.sh myapp
EOF
}

list_targets() {
  echo "Available image targets:"
  cd "${REPO_DIR}"
  nix eval .#packages.x86_64-linux --apply 'attrs: builtins.attrNames attrs' --json 2>/dev/null \
    | jq -r '.[]' \
    | grep -- '-image$' \
    | sed 's/-image$//' \
    | while read -r name; do
        echo "  ${name}"
      done
}

# --- Helper: update image_versions map in a tfvars file ---
_update_versions_map() {
  local file="$1"
  local role="$2"
  local image_name="$3"

  # If file doesn't exist or has no map yet, create it from scratch
  if [[ ! -f "$file" ]] || ! grep -q 'image_versions' "$file"; then
    cat >> "$file" <<EOF
image_versions = {
  "${role}" = "${image_name}"
}
EOF
    return
  fi

  # File exists with a map — update existing entry or insert new one
  # Keys are quoted ("role") to match HCL map literal syntax.
  if grep -q "^[[:space:]]*\"${role}\"[[:space:]]*=" "$file"; then
    sed_i "s|^\\([[:space:]]*\\)\"${role}\"[[:space:]]*=.*|\\1\"${role}\" = \"${image_name}\"|" "$file"
  else
    # Insert before closing brace — portable across BSD/GNU sed
    sed_i "/^}/i\\
\\  \"${role}\" = \"${image_name}\"
" "$file"
  fi
}

# --- Parse arguments ---
DEV_MODE=0
EXTERNAL_MODE=0
HOST_FILE=""
ROLE=""

for arg in "$@"; do
  case "$arg" in
    --help|-h) usage; exit 0 ;;
    --list) list_targets; exit 0 ;;
    --dev) DEV_MODE=1 ;;
    --external) EXTERNAL_MODE=1 ;;
    -*)
      echo "ERROR: Unknown option: $arg" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$HOST_FILE" ]]; then
        HOST_FILE="$arg"
      elif [[ -z "$ROLE" ]]; then
        ROLE="$arg"
      else
        echo "ERROR: Unexpected argument: $arg" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "$HOST_FILE" || -z "$ROLE" ]]; then
  echo "ERROR: Both <host-nix-file/build-script> and <role> are required." >&2
  usage >&2
  exit 2
fi

if [[ ! -f "${REPO_DIR}/${HOST_FILE}" ]]; then
  echo "ERROR: File not found: ${HOST_FILE}" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 1
fi

load_role_secret_input() {
  local role="$1"
  local manifest config_path secret_ref

  for manifest in "${REPO_DIR}/site/images.yaml" "${REPO_DIR}/framework/images.yaml"; do
    [[ -f "$manifest" ]] || continue
    config_path="$(ROLE="$role" yq -r '.roles[strenv(ROLE)].build_secret_config // ""' "$manifest" 2>/dev/null || true)"
    secret_ref="$(ROLE="$role" yq -r '.roles[strenv(ROLE)].build_secret_ref // ""' "$manifest" 2>/dev/null || true)"
    if [[ -n "$config_path" && "$config_path" != "null" ]]; then
      [[ -n "$secret_ref" && "$secret_ref" != "null" ]] || {
        echo "ERROR: ${manifest}: roles.${role}.build_secret_ref is required with build_secret_config" >&2
        exit 1
      }
      if [[ "$config_path" != /* ]]; then
        config_path="${REPO_DIR}/${config_path}"
      fi
      export MYCOFU_HIL_BOOT_ROOT_PASSWORD="$("${SCRIPT_DIR}/hil-boot-secret-env.sh" "$config_path" "$secret_ref")"
      NIX_BUILD_FLAGS+=(--impure)
      return 0
    fi
  done
}

cd "${REPO_DIR}"

# --- Git dirty-tree check (non-dev builds require clean tree for traceability) ---
# Exclude site/sops/secrets.yaml — it is updated by init-vault.sh and
# configure-gitlab.sh during rebuild, and does not affect image builds.
if [[ $DEV_MODE -eq 0 ]]; then
  if ! git diff --quiet HEAD -- ':!site/sops/secrets.yaml'; then
    echo "ERROR: Working tree has uncommitted changes." >&2
    echo "Commit your changes first, or use --dev to build and deploy from a dirty tree." >&2
    exit 1
  fi
fi

mkdir -p "${REPO_DIR}/build"

if [[ $EXTERNAL_MODE -eq 1 ]]; then
  # --- External (Category B) build ---
  BUILD_SCRIPT="${HOST_FILE}"
  BUILD_OUTPUT_DIR="${REPO_DIR}/build/.external-${ROLE}"

  echo "External build: ${BUILD_SCRIPT}"
  echo "Role:           ${ROLE}"
  echo ""

  rm -rf "$BUILD_OUTPUT_DIR"
  mkdir -p "$BUILD_OUTPUT_DIR"

  # Run the user-provided build script
  "${REPO_DIR}/${BUILD_SCRIPT}" "$BUILD_OUTPUT_DIR"

  # The script must produce exactly one .img file
  IMG_FILES=("$BUILD_OUTPUT_DIR"/*.img)
  if [[ ${#IMG_FILES[@]} -ne 1 ]] || [[ ! -f "${IMG_FILES[0]}" ]]; then
    echo "ERROR: Build script must produce exactly one .img file in the output directory" >&2
    echo "Found: ${IMG_FILES[*]}" >&2
    exit 1
  fi

  # Hash the file content (SHA256, first 8 chars)
  FILE_HASH=$(shasum -a 256 "${IMG_FILES[0]}" | cut -c1-8)

  if [[ $DEV_MODE -eq 1 ]]; then
    OUTPUT_NAME="${ROLE}-${FILE_HASH}-dev.img"
  else
    OUTPUT_NAME="${ROLE}-${FILE_HASH}.img"
  fi

  OUTPUT_PATH="build/${OUTPUT_NAME}"
  rm -f "$OUTPUT_PATH"
  mv "${IMG_FILES[0]}" "$OUTPUT_PATH"
  chmod 644 "$OUTPUT_PATH"
  rm -rf "$BUILD_OUTPUT_DIR"

else
  # --- NixOS (Category A) build ---
  FLAKE_ATTR="${ROLE}-image"
  BUILDER_TYPE=$(yq -r '.nix_builder.type' "$CONFIG")
  load_role_secret_input "$ROLE"

  echo "Host config:  ${HOST_FILE}"
  echo "Flake output: ${FLAKE_ATTR}"
  echo "Builder type: ${BUILDER_TYPE}"
  echo ""

  case "$BUILDER_TYPE" in
    local|linux-builder)
      echo "Building ${FLAKE_ATTR}..."
      BUILD_LOG=$(mktemp)
      if ! nix build ${NIX_BUILD_FLAGS[@]+"${NIX_BUILD_FLAGS[@]}"} --log-format raw ".#packages.x86_64-linux.${FLAKE_ATTR}" --print-build-logs 2>&1 | tee "$BUILD_LOG"; then
        if grep -q "Segmentation fault" "$BUILD_LOG" || grep -q "exit code 139" "$BUILD_LOG" || grep -q "No space left on device" "$BUILD_LOG" || grep -q "Assertion.*failed" "$BUILD_LOG" || grep -q "exit code 134" "$BUILD_LOG" || grep -q "Aborted" "$BUILD_LOG"; then
          echo "" >&2
          echo "Build disk space exhausted." >&2
          echo "Auto-recovering..." >&2

          # Recovery strategy depends on the underlying builder.
          #
          # macOS workstation (linux-builder VM): kill the QEMU process,
          # delete the overlay store.img, restart via the operator's
          # start-builder.sh. Each restart caches more of the closure in
          # the HOST nix store (the overlay's read-only lower layer), so
          # the fresh overlay needs progressively less space.
          #
          # Linux runner (native build, no QEMU): there is no separate
          # builder process or overlay. Recovery means freeing space in
          # /nix/store by running nix-collect-garbage. Active GC roots
          # (current build's .gc-roots/) are preserved — only orphan
          # paths from prior pipeline runs are removed.
          BUILD_RECOVERED=0
          for RECOVERY_ATTEMPT in 1 2 3; do
            if [[ "$(uname)" == "Darwin" ]]; then
              echo "  Recovery attempt ${RECOVERY_ATTEMPT}/3: restarting macOS linux-builder..."
              # Kill the builder QEMU process directly — no sudo needed
              # (owned by current user). setup-nix-builder.sh --stop uses
              # sudo launchctl which hangs under nohup/non-interactive shells.
              pkill -f "qemu.*nixos.qcow2" 2>/dev/null || true
              for i in $(seq 1 15); do
                pgrep -f "qemu.*nixos.qcow2" >/dev/null 2>&1 || break
                sleep 1
              done
              # Delete the store overlay so the builder starts with a fresh one.
              # The overlay accumulates built paths across restarts — killing
              # QEMU alone doesn't free space.
              STORE_OVERLAY="${HOME}/.nix-builder/store.img"
              if [ -f "$STORE_OVERLAY" ]; then
                echo "  Removing stale store overlay ($(du -h "$STORE_OVERLAY" | cut -f1))..."
                rm -f "$STORE_OVERLAY"
              fi
              sleep 2
              # Start the builder using the operator's start script directly.
              # Do NOT use setup-nix-builder.sh — it calls sudo which hangs
              # under nohup/non-interactive shells. The start script at
              # ~/.nix-builder/start-builder.sh is sudo-free and already
              # handles overlay cleanup (rm store.img, nixos.qcow2).
              BUILDER_START="${HOME}/.nix-builder/start-builder.sh"
              if [ -x "$BUILDER_START" ]; then
                echo "  Starting builder via ${BUILDER_START}..."
                bash "$BUILDER_START"
              else
                echo "ERROR: Builder start script not found at ${BUILDER_START}" >&2
                rm -f "$BUILD_LOG"
                exit 1
              fi
              # Wait for builder to be responsive
              for i in $(seq 1 24); do
                nc -z localhost 31022 2>/dev/null && break
                sleep 5
              done
              echo "  Builder restarted. Retrying build..."
            else
              echo "  Recovery attempt ${RECOVERY_ATTEMPT}/3: running nix-collect-garbage on Linux runner..."
              # Native Linux build: no separate builder. Free /nix/store
              # space directly. nix-collect-garbage preserves anything
              # reachable from a GC root, including the current build's
              # .gc-roots/ symlinks (created by build-all-images.sh).
              # Only orphan paths from prior pipeline runs are removed.
              df -h /nix 2>&1 | tail -2 >&2 || true
              if ! nix-collect-garbage 2>&1 | tail -5 >&2; then
                echo "  nix-collect-garbage returned non-zero; continuing anyway" >&2
              fi
              df -h /nix 2>&1 | tail -2 >&2 || true
              echo "  GC complete. Retrying build..."
            fi
            rm -f "$BUILD_LOG"
            if nix build ${NIX_BUILD_FLAGS[@]+"${NIX_BUILD_FLAGS[@]}"} --log-format raw ".#packages.x86_64-linux.${FLAKE_ATTR}" --print-build-logs 2>&1 | tee "$BUILD_LOG"; then
              BUILD_RECOVERED=1
              break
            fi
            echo "  Attempt ${RECOVERY_ATTEMPT} failed"
          done
          if [[ $BUILD_RECOVERED -eq 0 ]]; then
            echo "ERROR: Build failed after 3 recovery attempts." >&2
            if [[ "$(uname)" == "Darwin" ]]; then
              echo "The macOS builder's disk may be too small for this image." >&2
              echo "Increase diskSize in nix-darwin config, or run:" >&2
              echo "  nix-collect-garbage on the builder (NOT the host)" >&2
            else
              echo "The Linux runner's /nix may be too full even after GC." >&2
              echo "Check the busy-aware nix-gc heuristic — pipelines running at" >&2
              echo "midnight cause it to skip the nightly GC, accumulating orphan" >&2
              echo "paths until /nix fills up." >&2
            fi
            rm -f "$BUILD_LOG"
            exit 1
          fi
        else
          rm -f "$BUILD_LOG"
          exit 1
        fi
      fi
      rm -f "$BUILD_LOG"
      ;;
    remote)
      REMOTE_USER=$(yq -r '.nix_builder.remote_user' "$CONFIG")
      REMOTE_HOST=$(yq -r '.nix_builder.remote_host' "$CONFIG")
      if [[ -z "$REMOTE_USER" || -z "$REMOTE_HOST" || "$REMOTE_USER" == "null" || "$REMOTE_HOST" == "null" ]]; then
        echo "ERROR: nix_builder.remote_user and remote_host must be set for remote builds" >&2
        exit 1
      fi
      echo "Building ${FLAKE_ATTR} on remote builder ${REMOTE_USER}@${REMOTE_HOST}..."
      nix build ${NIX_BUILD_FLAGS[@]+"${NIX_BUILD_FLAGS[@]}"} --log-format raw ".#packages.x86_64-linux.${FLAKE_ATTR}" --print-build-logs \
        --builders "ssh://${REMOTE_USER}@${REMOTE_HOST} x86_64-linux"
      ;;
    *)
      echo "ERROR: Unknown nix_builder.type: ${BUILDER_TYPE}" >&2
      echo "Expected: local, linux-builder, or remote" >&2
      exit 1
      ;;
  esac

  # --- Extract content-addressed hash from nix output path ---
  # Use --out-link to create a GC root that keeps the image closure alive.
  # Without this, nix-collect-garbage removes the closure and the next
  # build re-downloads everything (gitlab: ~6.4GB).
  GC_ROOT_DIR="${REPO_DIR}/build/.gc-roots"
  mkdir -p "$GC_ROOT_DIR"
  OUT_PATH=$(nix build ${NIX_BUILD_FLAGS[@]+"${NIX_BUILD_FLAGS[@]}"} --log-format raw ".#packages.x86_64-linux.${FLAKE_ATTR}" \
    --print-out-paths --out-link "${GC_ROOT_DIR}/${ROLE}")
  NIX_HASH=$(basename "$OUT_PATH" | cut -c1-8)

  if [[ $DEV_MODE -eq 1 ]]; then
    OUTPUT_NAME="${ROLE}-${NIX_HASH}-dev.img"
  else
    OUTPUT_NAME="${ROLE}-${NIX_HASH}.img"
  fi

  OUTPUT_PATH="build/${OUTPUT_NAME}"

  # --- Copy qcow2 from nix store to versioned build output ---
  # The .img extension is required — Proxmox ISO storage only recognizes .iso and .img
  # Note: `result` is a nix store symlink (read-only), so we copy to build/ instead.
  QCOW2_FILE=$(find -L "${OUT_PATH}" -name '*.qcow2' -type f 2>/dev/null | head -1)

  if [[ -z "$QCOW2_FILE" ]]; then
    echo "ERROR: No qcow2 file found in nix output: ${OUT_PATH}" >&2
    exit 1
  fi

  if [[ "$ROLE" == "hil-boot" ]]; then
    "${SCRIPT_DIR}/check-hil-boot-image-size.sh" "$QCOW2_FILE"
  fi

  rm -f "$OUTPUT_PATH"
  cp "$QCOW2_FILE" "$OUTPUT_PATH"
  chmod 644 "$OUTPUT_PATH"
fi

FILE_SIZE=$(du -h "$OUTPUT_PATH" | cut -f1)
echo ""
echo "Build complete: ${OUTPUT_NAME} (${FILE_SIZE})"

# --- Upload to all nodes ---
echo ""
"${SCRIPT_DIR}/upload-image.sh" "$OUTPUT_PATH" "$ROLE"

# --- Update image versions file ---
# image-versions.auto.tfvars is gitignored — it is a build artifact,
# not a committed file. Both clean and --dev builds write to it.
VERSIONS_FILE="${REPO_DIR}/site/tofu/image-versions.auto.tfvars"

if [[ ! -f "$VERSIONS_FILE" ]]; then
  printf '# Auto-generated by build-image.sh — not committed to git.\n' > "$VERSIONS_FILE"
  printf '# Run build-image.sh or build-all-images.sh to populate.\n' >> "$VERSIONS_FILE"
fi

_update_versions_map "$VERSIONS_FILE" "$ROLE" "$OUTPUT_NAME"

# --- Build log (traceability) ---
BUILD_LOG="${REPO_DIR}/build/build.log"
echo "${ROLE} ${OUTPUT_NAME} built from $(git rev-parse HEAD) at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$BUILD_LOG"

# --- Summary ---
echo ""
echo "========================================"
echo "Built:   ${OUTPUT_NAME} (${FILE_SIZE})"
NODES=$(yq -r '.nodes[].name' "$CONFIG" | tr '\n' ' ')
echo "Nodes:   ${NODES}"
if [[ $DEV_MODE -eq 1 ]]; then
  echo "Mode:    dev (dirty tree)"
else
  echo "Mode:    clean"
fi
echo "========================================"
