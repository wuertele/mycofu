#!/usr/bin/env bash
# Verify the built hil-boot qcow2 virtual size fits the Terraform runtime disk.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${MYCOFU_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
ROOT_TF="${REPO_DIR}/framework/tofu/root/main.tf"
GIB=1073741824
MIN_MARGIN_GIB=1

usage() {
  echo "Usage: $(basename "$0") <hil-boot-qcow2>" >&2
}

resolve_qemu_img() {
  local path

  if path="$(command -v qemu-img 2>/dev/null)"; then
    printf '%s\n' "$path"
    return 0
  fi

  path="$(find /nix/store -path '*/bin/qemu-img' -type f 2>/dev/null | head -1 || true)"
  if [[ -n "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  return 1
}

hil_boot_runtime_disk_gb() {
  awk '
    /^module "hil_boot" \{/ { in_module = 1; next }
    in_module && /^[[:space:]]*vda_size_gb[[:space:]]*=/ { print $3; exit }
    in_module && /^\}/ { in_module = 0 }
  ' "$ROOT_TF"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

QCOW2_FILE="$1"
if [[ ! -f "$QCOW2_FILE" ]]; then
  echo "ERROR: hil-boot image not found: ${QCOW2_FILE}" >&2
  exit 1
fi

if [[ ! -f "$ROOT_TF" ]]; then
  echo "ERROR: Terraform root module not found: ${ROOT_TF}" >&2
  exit 1
fi

RUNTIME_GB="$(hil_boot_runtime_disk_gb)"
if [[ ! "$RUNTIME_GB" =~ ^[0-9]+$ || "$RUNTIME_GB" -le "$MIN_MARGIN_GIB" ]]; then
  echo "ERROR: could not resolve hil_boot.vda_size_gb as a safe integer from ${ROOT_TF}" >&2
  exit 1
fi

if ! QEMU_IMG="$(resolve_qemu_img)"; then
  echo "ERROR: qemu-img is required to verify hil-boot image virtual size" >&2
  exit 1
fi

INFO_JSON="$("$QEMU_IMG" info --output=json "$QCOW2_FILE")"
VIRTUAL_SIZE_BYTES="$(jq -r '."virtual-size" // empty' <<< "$INFO_JSON")"
if [[ ! "$VIRTUAL_SIZE_BYTES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: qemu-img did not report a numeric virtual-size for ${QCOW2_FILE}" >&2
  exit 1
fi

RUNTIME_BYTES=$((RUNTIME_GB * GIB))
LIMIT_BYTES=$(((RUNTIME_GB - MIN_MARGIN_GIB) * GIB))

if (( VIRTUAL_SIZE_BYTES > LIMIT_BYTES )); then
  echo "ERROR: hil-boot image virtual size (${VIRTUAL_SIZE_BYTES} bytes) exceeds safe limit (${LIMIT_BYTES} bytes)" >&2
  echo "       Increase module.hil_boot.vda_size_gb above ${RUNTIME_GB}G or reduce image contents." >&2
  exit 1
fi

echo "hil-boot image virtual size (${VIRTUAL_SIZE_BYTES} bytes) fits ${RUNTIME_GB}G runtime disk with ${MIN_MARGIN_GIB}G margin"
