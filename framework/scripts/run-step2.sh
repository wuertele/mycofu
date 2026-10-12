#!/usr/bin/env bash
# run-step2.sh — Run the full Step 2 pipeline: build → convert → upload → tofu init → tofu plan → validate.
#
# Idempotent: each step checks whether its work is already done and skips if so.
# Stops on first failure with the command needed to retry from that step.
#
# Usage:
#   framework/scripts/run-step2.sh
#   framework/scripts/run-step2.sh --image-version base-v0.2
#   framework/scripts/run-step2.sh --skip-build       # Skip Nix build (reuse existing image)
#   framework/scripts/run-step2.sh --force             # Re-run all steps even if already done
#   framework/scripts/run-step2.sh --help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Re-exec under nix develop if required tools are missing ---
# nix itself must be on PATH; everything else comes from the devShell.
REQUIRED_TOOLS=(qemu-img sops yq jq tofu)
MISSING=0
for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING=1
    break
  fi
done

if [[ "$MISSING" -eq 1 ]]; then
  # Ensure nix is on PATH (macOS may not have it in default bash PATH)
  for p in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin"; do
    if [[ -x "${p}/nix" ]] && [[ ":${PATH}:" != *":${p}:"* ]]; then
      export PATH="${p}:${PATH}"
    fi
  done
  if ! command -v nix &>/dev/null; then
    echo "ERROR: nix is not on PATH. Install Nix first." >&2
    exit 1
  fi
  echo "Required tools not on PATH — re-running inside nix develop..."
  exec nix develop "${REPO_DIR}" --command "$0" "$@"
fi

IMAGE_VERSION="base-v0.1"
SKIP_BUILD=0
FORCE=0

usage() {
  cat <<'EOF'
Usage: run-step2.sh [options]

Run the full Step 2 pipeline and validation. Idempotent — skips steps
whose outputs already exist.

Pipeline:
  1. Build NixOS base image (nix build)
  2. Convert qcow2 to raw (qemu-img)
  3. Upload raw image to first Proxmox node (SCP)
  4. OpenTofu init (backend + providers)
  5. OpenTofu plan (verify provider connection)
  6. Run validation gate checks (V2.1–V2.5)

Options:
  --image-version VER  Image name on Proxmox (default: base-v0.1)
  --skip-build         Skip step 1 (nix build), reuse existing qcow2
  --force              Re-run all steps even if already done
  --help               Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --image-version) IMAGE_VERSION="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --force) FORCE=1; shift ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

CONFIG="${REPO_DIR}/site/config.yaml"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 1
fi

# --- Helpers ---

STEP_NUM=0
TOTAL_STEPS=6

step() {
  STEP_NUM=$((STEP_NUM + 1))
  echo ""
  echo "========================================"
  echo "[${STEP_NUM}/${TOTAL_STEPS}] $1"
  echo "========================================"
}

skip() {
  echo "  -> Already done: $1"
}

fail() {
  local retry_cmd="$1"
  echo ""
  echo "----------------------------------------"
  echo "FAILED at step ${STEP_NUM}/${TOTAL_STEPS}"
  echo ""
  echo "To retry this step:"
  echo "  ${retry_cmd}"
  echo ""
  echo "To restart the full pipeline:"
  echo "  framework/scripts/run-step2.sh --image-version ${IMAGE_VERSION}"
  if [[ "$STEP_NUM" -gt 2 ]]; then
    echo ""
    echo "To skip the build and restart from upload:"
    echo "  framework/scripts/run-step2.sh --skip-build --image-version ${IMAGE_VERSION}"
  fi
  echo "----------------------------------------"
  exit 1
}

cd "${REPO_DIR}"

echo "Step 2 Pipeline: NixOS Base Image + OpenTofu Foundation"
echo "Image version: ${IMAGE_VERSION}"
echo ""

# --- Step 1: Build NixOS base image ---

step "Build NixOS base image"

if [[ "$SKIP_BUILD" -eq 1 ]]; then
  QCOW2_FILE=$(find -L result/ -name '*.qcow2' -type f 2>/dev/null | head -1)
  if [[ -n "$QCOW2_FILE" ]]; then
    skip "using existing ${QCOW2_FILE} (--skip-build)"
  else
    echo "ERROR: --skip-build specified but no qcow2 found in result/" >&2
    echo "Run without --skip-build to build the image first." >&2
    exit 1
  fi
else
  # nix build is already idempotent (cached), so always run it — it's fast when cached
  if ! "${SCRIPT_DIR}/build-image.sh" base; then
    fail "framework/scripts/build-image.sh base"
  fi
fi

# --- Step 2: Convert to raw ---

step "Convert qcow2 to raw"

QCOW2_FILE=$(find -L result/ -name '*.qcow2' -type f 2>/dev/null | head -1)
if [[ -z "$QCOW2_FILE" ]]; then
  echo "ERROR: No qcow2 file found in result/" >&2
  fail "framework/scripts/build-image.sh base"
fi

BUILD_DIR="${REPO_DIR}/build"
mkdir -p "$BUILD_DIR"
RAW_FILE="${BUILD_DIR}/base.raw"

# Skip if raw file exists and is newer than the qcow2 source
if [[ "$FORCE" -eq 0 ]] && [[ -f "$RAW_FILE" ]] && [[ "$RAW_FILE" -nt "$QCOW2_FILE" ]]; then
  skip "${RAW_FILE} ($(du -h "$RAW_FILE" | cut -f1)) is newer than ${QCOW2_FILE}"
else
  echo "Converting: ${QCOW2_FILE} -> ${RAW_FILE}"
  if ! qemu-img convert -f qcow2 -O raw "$QCOW2_FILE" "$RAW_FILE"; then
    fail "qemu-img convert -f qcow2 -O raw ${QCOW2_FILE} build/base.raw"
  fi
  echo "Raw image: ${RAW_FILE} ($(du -h "$RAW_FILE" | cut -f1))"
fi

# --- Step 3: Upload to Proxmox ---

step "Upload raw image to Proxmox"

NODE1_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
# Proxmox ISO storage only recognizes .iso and .img extensions
DEST_FILENAME="${IMAGE_VERSION}.img"
_IMG_PATH=$(yq -r '.proxmox.image_storage_path' "$CONFIG")
if [[ -z "$_IMG_PATH" || "$_IMG_PATH" == "null" ]]; then
  _IMG_PATH="/var/lib/vz/template/iso"
fi
REMOTE_PATH="${_IMG_PATH}/${DEST_FILENAME}"
LOCAL_FILE="${BUILD_DIR}/base.raw"
LOCAL_SIZE=$(stat -f%z "$LOCAL_FILE" 2>/dev/null || stat --format=%s "$LOCAL_FILE" 2>/dev/null)

# Skip if remote file exists with the same size
UPLOAD_NEEDED=1
if [[ "$FORCE" -eq 0 ]]; then
  REMOTE_SIZE=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE1_IP}" \
    "stat -c%s ${REMOTE_PATH} 2>/dev/null" 2>/dev/null || echo "0")
  if [[ "$REMOTE_SIZE" -eq "$LOCAL_SIZE" ]] && [[ "$LOCAL_SIZE" -gt 0 ]]; then
    skip "${DEST_FILENAME} on ${NODE1_IP} matches local file (${LOCAL_SIZE} bytes)"
    UPLOAD_NEEDED=0
  fi
fi

if [[ "$UPLOAD_NEEDED" -eq 1 ]]; then
  if ! "${SCRIPT_DIR}/upload-image.sh" "$LOCAL_FILE" "$IMAGE_VERSION"; then
    fail "framework/scripts/upload-image.sh build/base.raw ${IMAGE_VERSION}"
  fi
fi

# --- Step 4: OpenTofu init ---

step "OpenTofu init"

# Skip if .terraform dir exists with backend state and providers are present
TOFU_DIR="${REPO_DIR}/framework/tofu/root"
INIT_NEEDED=1
if [[ "$FORCE" -eq 1 ]]; then
  # Clean slate: remove cached backend state to avoid hash mismatches
  rm -rf "${TOFU_DIR}/.terraform"
elif [[ -f "${TOFU_DIR}/.terraform/terraform.tfstate" ]] \
  && [[ -d "${TOFU_DIR}/.terraform/providers" ]]; then
  skip ".terraform dir exists with backend state and providers"
  INIT_NEEDED=0
fi

if [[ "$INIT_NEEDED" -eq 1 ]]; then
  if ! "${SCRIPT_DIR}/tofu-wrapper.sh" init; then
    fail "framework/scripts/tofu-wrapper.sh init"
  fi
fi

# --- Step 5: OpenTofu plan ---

step "OpenTofu plan"
if ! "${SCRIPT_DIR}/tofu-wrapper.sh" plan -input=false; then
  fail "framework/scripts/tofu-wrapper.sh plan -input=false"
fi

# --- Step 6: Validation ---

step "Validation gate checks"
"${SCRIPT_DIR}/validate-step2.sh"
VALIDATE_RC=$?

echo ""
echo "========================================"
if [[ "$VALIDATE_RC" -eq 0 ]]; then
  echo "Step 2 pipeline complete. All automated checks passed."
else
  echo "Step 2 pipeline complete. Some validation checks failed — review output above."
fi
echo "========================================"

exit "$VALIDATE_RC"
