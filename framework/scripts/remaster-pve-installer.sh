#!/usr/bin/env bash
# remaster-pve-installer.sh — Build a remastered Proxmox VE installer ISO
# with an embedded answer file for unattended bare-metal install.

set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TEMPLATE="${REPO_DIR}/framework/templates/pve-answer.toml.tmpl"

KEYBOARD="en-us"
COUNTRY="us"
TIMEZONE="UTC"
MAILTO="root@localhost"
REBOOT_MODE="reboot"
FILESYSTEM="ext4"

CONFIG=""
NODE=""
DRY_RUN=0
PRINT_OUTPUT_ISO=0
INPUT_ISO=""
INPUT_ISO_SHA256=""
OUTPUT_ISO=""
FQDN=""
CIDR=""
GATEWAY=""
DNS=""
ROOT_PASSWORD=""
ROOT_PASSWORD_FILE=""
NIC_DRIVER=""
DISK_PCI_PATH=""
CONFIG_MODE=0
BUILDING_OUTPUT=0

usage() {
  cat <<'EOF'
Usage:
  remaster-pve-installer.sh --config CONFIG --node NAME [--dry-run] [--print-output-iso]
  remaster-pve-installer.sh --input-iso PATH --output-iso PATH --fqdn FQDN --cidr CIDR \
    --gateway IP --dns IP --nic-driver NAME --disk-pci-path PATH \
    (--root-password STRING | --root-password-file PATH) [options]

Config mode:
  --config PATH           Site config.yaml
  --node NAME             Node name from config
  --dry-run               Render and TOML-validate answer file; do not write an ISO
  --print-output-iso      Print the content-addressed ISO path and exit

Standalone mode required options:
  --input-iso PATH        Stock Proxmox VE installer ISO
  --output-iso PATH       Path to write remastered ISO
  --fqdn FQDN             Node FQDN
  --cidr CIDR             Node IP/prefix
  --gateway IP            Default gateway
  --dns IP                DNS resolver
  --nic-driver NAME       Linux driver for management NIC
  --disk-pci-path PATH    udev ID_PATH of the install disk

Password in standalone mode:
  --root-password STRING
  --root-password-file PATH

Optional:
  --filesystem TYPE       ext4 (default) | zfs
  --timezone TZ           default: UTC
  --mailto ADDR           default: root@localhost
  --keyboard LAYOUT       default: en-us
  --country CODE          default: us
  --reboot-mode MODE      reboot (default) | power-off
  -h, --help              Show this help
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 2
}

sha256_file() {
  python3 - "$1" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
}

sha256_text() {
  python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

render_query() {
  local query="$1"
  yq -r "$query" "$CONFIG"
}

sops_path_for_config() {
  dirname "$CONFIG"
}

# Where stock and remastered ISOs live. The canonical location is
# /nix/var/regreener-cache, provisioned on the hil-boot regreener path.
# MYCOFU_REGREENER_CACHE_DIR is the supported override for workstation or test
# runs where the canonical path is not present. If neither path is available,
# fail with a pointer to the override instead of silently choosing /tmp.
#
# Resolved once at startup into $CACHE_ROOT_DIR (see resolve_canonical_paths).
# Helpers like resolve_input_iso() and ensure_cache_disk_room() use the global
# directly so a failure to resolve cannot be swallowed inside $(...) capture.
CACHE_ROOT_DIR=""
WORK_ROOT_DIR=""

resolve_cache_root() {
  if [[ -n "${MYCOFU_REGREENER_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$MYCOFU_REGREENER_CACHE_DIR"
    return 0
  fi
  if [[ -d /nix/var/regreener-cache && -w /nix/var/regreener-cache ]]; then
    printf '%s\n' /nix/var/regreener-cache
    return 0
  fi
  echo "ERROR: /nix/var/regreener-cache not present or not writable." >&2
  echo "  For Sprint 037, PXE regreening executes through hil-boot." >&2
  echo "  Set MYCOFU_REGREENER_CACHE_DIR to an absolute writable path" >&2
  echo "  when running this legacy remaster helper outside that path." >&2
  return 2
}

# Trigger nix-collect-garbage if /nix free space is below threshold.
# Defaults sized for a multi-cluster regreen pass: stock ISO + N node ISOs +
# working room. Override with REGREENER_MIN_FREE_GB or set
# MYCOFU_REGREENER_SKIP_GC=1 to disable entirely (used by tests).
ensure_cache_disk_room() {
  local target="${1:-$CACHE_ROOT_DIR}"
  local min_free_gb="${REGREENER_MIN_FREE_GB:-30}"
  if [[ "${MYCOFU_REGREENER_SKIP_GC:-0}" == "1" ]]; then
    return 0
  fi
  local free_kb free_gb
  free_kb="$(df -P "$target" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ -n "$free_kb" ]] || return 0
  free_gb=$((free_kb / 1024 / 1024))
  if (( free_gb >= min_free_gb )); then
    return 0
  fi
  echo "=== Low disk on ${target}: ${free_gb}GB free, need ${min_free_gb}GB; running nix-collect-garbage ==="
  if command -v nix-collect-garbage >/dev/null 2>&1; then
    nix-collect-garbage 2>&1 | tail -5 || true
    free_kb="$(df -P "$target" 2>/dev/null | awk 'NR==2 {print $4}')"
    free_gb=$((free_kb / 1024 / 1024))
    echo "  post-GC free on ${target}: ${free_gb}GB"
  else
    echo "  nix-collect-garbage not available; auto-GC skipped"
  fi
}

# Where xorriso stages its ~3.5 GB working set during extract+rebuild.
# Canonical location is /nix/tmp on the hil-boot regreener path.
# MYCOFU_REGREENER_WORK_ROOT is the supported override for workstation or test
# runs. If /nix/tmp is missing, fail with a pointer to the override rather
# than silently choosing a small /tmp.
#
# Resolved once at startup into $WORK_ROOT_DIR (see resolve_canonical_paths).
resolve_work_root() {
  if [[ -n "${MYCOFU_REGREENER_WORK_ROOT:-}" ]]; then
    printf '%s\n' "$MYCOFU_REGREENER_WORK_ROOT"
    return 0
  fi
  if [[ -d /nix/tmp && -w /nix/tmp ]]; then
    printf '%s\n' /nix/tmp
    return 0
  fi
  echo "ERROR: /nix/tmp not present or not writable." >&2
  echo "  For Sprint 037, PXE regreening executes through hil-boot." >&2
  echo "  Set MYCOFU_REGREENER_WORK_ROOT to an absolute writable path" >&2
  echo "  with ~5 GB free when running this legacy remaster helper elsewhere." >&2
  return 2
}

# Resolve both canonical paths once at startup so resolution errors propagate
# through `if !` (which neutralizes set -e) instead of being swallowed by
# subshell $(...) capture in callers like resolve_input_iso.
resolve_canonical_paths() {
  if ! CACHE_ROOT_DIR="$(resolve_cache_root)"; then
    exit 2
  fi
  if ! WORK_ROOT_DIR="$(resolve_work_root)"; then
    exit 2
  fi
}

read_sops_key() {
  local key="$1"
  local sops_path
  sops_path="$(sops_path_for_config)/sops/secrets.yaml"
  if [[ ! -f "$sops_path" ]]; then
    echo "ERROR: SOPS file not found: ${sops_path}" >&2
    exit 2
  fi
  sops -d --extract "[\"${key}\"]" "$sops_path" 2>/dev/null || true
}

config_node_value() {
  local expr="$1"
  NODE="$NODE" yq -r ".nodes[] | select(.name == strenv(NODE)) | ${expr}" "$CONFIG"
}

load_config_mode() {
  [[ -f "$CONFIG" ]] || die "--config not found: $CONFIG"
  [[ -n "$NODE" ]] || die "--node is required with --config"

  if ! NODE="$NODE" yq -e '.nodes[] | select(.name == strenv(NODE))' "$CONFIG" >/dev/null 2>&1; then
    die "node '${NODE}' not found in $CONFIG"
  fi

  local domain mgmt_ip mgmt_prefix root_password node_filesystem
  domain="$(render_query '.domain')"
  mgmt_ip="$(config_node_value '.mgmt_ip')"
  mgmt_prefix="$(render_query '.management.subnet | split("/")[1]')"

  INPUT_ISO="$(render_query '.proxmox.installer.iso // ""')"
  INPUT_ISO_SHA256="$(render_query '.proxmox.installer.iso_sha256 // ""')"
  FQDN="${NODE}.${domain}"
  CIDR="${mgmt_ip}/${mgmt_prefix}"
  GATEWAY="$(render_query '.management.gateway')"
  DNS="$(render_query '.management.dns // .management.gateway')"
  NIC_DRIVER="$(config_node_value '.install_nic_driver // ""')"
  DISK_PCI_PATH="$(config_node_value '.install_disk_id_path // ""')"
  node_filesystem="$(config_node_value '.install_filesystem // ""')"
  if [[ -n "$node_filesystem" && "$node_filesystem" != "null" ]]; then
    FILESYSTEM="$node_filesystem"
  else
    FILESYSTEM="$(render_query '.proxmox.installer.filesystem // "ext4"')"
  fi
  TIMEZONE="$(render_query '.timezone // "UTC"')"
  MAILTO="$(render_query '.email.to // "root@localhost"')"
  REBOOT_MODE="$(render_query '.proxmox.installer.reboot_mode // "reboot"')"

  root_password="$(read_sops_key proxmox_api_password)"
  if [[ -z "$root_password" || "$root_password" == "null" ]]; then
    echo "ERROR: Could not read proxmox_api_password from $(sops_path_for_config)/sops/secrets.yaml" >&2
    exit 2
  fi
  ROOT_PASSWORD="$root_password"
}

validate_common() {
  local missing=()
  [[ -z "$INPUT_ISO" || "$INPUT_ISO" == "null" ]] && missing+=("--input-iso/proxmox.installer.iso")
  [[ -z "$FQDN" || "$FQDN" == "null" ]] && missing+=("--fqdn")
  [[ -z "$CIDR" || "$CIDR" == "null" ]] && missing+=("--cidr")
  [[ -z "$GATEWAY" || "$GATEWAY" == "null" ]] && missing+=("--gateway")
  [[ -z "$DNS" || "$DNS" == "null" ]] && missing+=("--dns")
  [[ -z "$NIC_DRIVER" || "$NIC_DRIVER" == "null" ]] && missing+=("--nic-driver/install_nic_driver")
  [[ -z "$DISK_PCI_PATH" || "$DISK_PCI_PATH" == "null" ]] && missing+=("--disk-pci-path/install_disk_id_path")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing required arguments: ${missing[*]}" >&2
    exit 2
  fi

  if [[ -z "$ROOT_PASSWORD" && -z "$ROOT_PASSWORD_FILE" ]]; then
    echo "ERROR: must provide root password via SOPS, --root-password, or --root-password-file" >&2
    exit 2
  fi
  if [[ -n "$ROOT_PASSWORD" && -n "$ROOT_PASSWORD_FILE" ]]; then
    echo "ERROR: --root-password and --root-password-file are mutually exclusive" >&2
    exit 2
  fi
  if [[ -n "$ROOT_PASSWORD_FILE" ]]; then
    [[ -s "$ROOT_PASSWORD_FILE" ]] || die "--root-password-file does not exist or is empty: $ROOT_PASSWORD_FILE"
    ROOT_PASSWORD="$(head -n 1 "$ROOT_PASSWORD_FILE")"
  fi

  case "$FILESYSTEM" in
    ext4|zfs) ;;
    *) echo "ERROR: --filesystem/install_filesystem must be ext4 or zfs (got: $FILESYSTEM)" >&2; exit 2 ;;
  esac
  case "$REBOOT_MODE" in
    reboot|power-off) ;;
    *) echo "ERROR: --reboot-mode must be reboot or power-off (got: $REBOOT_MODE)" >&2; exit 2 ;;
  esac
  [[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"
}

render_answer() {
  local output="$1"
  local disk_setup_extra=""
  [[ "$FILESYSTEM" == "zfs" ]] && disk_setup_extra='zfs.raid = "single"'

  PVE_ROOT_PASSWORD="$ROOT_PASSWORD" \
  PVE_FQDN="$FQDN" \
  PVE_CIDR="$CIDR" \
  PVE_GATEWAY="$GATEWAY" \
  PVE_DNS="$DNS" \
  PVE_NIC_DRIVER="$NIC_DRIVER" \
  PVE_DISK_PCI_PATH="$DISK_PCI_PATH" \
  PVE_FILESYSTEM="$FILESYSTEM" \
  PVE_DISK_SETUP_EXTRA="$disk_setup_extra" \
  PVE_TIMEZONE="$TIMEZONE" \
  PVE_MAILTO="$MAILTO" \
  PVE_KEYBOARD="$KEYBOARD" \
  PVE_COUNTRY="$COUNTRY" \
  PVE_REBOOT_MODE="$REBOOT_MODE" \
  python3 - "$TEMPLATE" > "$output" <<'PY'
import os, re, sys
src = open(sys.argv[1]).read()
keys = ['PVE_ROOT_PASSWORD','PVE_FQDN','PVE_CIDR','PVE_GATEWAY','PVE_DNS',
        'PVE_NIC_DRIVER','PVE_DISK_PCI_PATH','PVE_FILESYSTEM',
        'PVE_DISK_SETUP_EXTRA','PVE_TIMEZONE','PVE_MAILTO','PVE_KEYBOARD',
        'PVE_COUNTRY','PVE_REBOOT_MODE']
for key in keys:
    src = src.replace(key, os.environ[key])
src = re.sub(r'\n[ \t]*\n', '\n\n', src)
src = re.sub(r'\n\n\n+', '\n\n', src)
sys.stdout.write(src)
PY
  chmod 0600 "$output"
}

validate_answer_toml() {
  local answer="$1"
  local status
  status=$(python3 - "$answer" 2>&1 <<'PY'
import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("skip")
        sys.exit(0)
tomllib.load(open(sys.argv[1], "rb"))
print("valid")
PY
  ) || status="error"
  case "$status" in
    valid) echo "  TOML syntax: valid" ;;
    skip) echo "  TOML syntax: not checked (no Python TOML parser)" ;;
    *)
      echo "ERROR: generated answer.toml failed TOML validation" >&2
      sed 's/root-password = ".*"/root-password = "***REDACTED***"/' "$answer" >&2
      exit 1
      ;;
  esac
}

redacted_answer() {
  sed 's/root-password = ".*"/root-password = "***REDACTED***"/'
}

compute_config_output_iso() {
  local answer="$1"
  local redacted_answer_text secret_hash script_hash template_hash cache_hash
  redacted_answer_text="$(sed "s|root-password = \".*\"|root-password-secret-sha256 = \"$(printf '%s' "$ROOT_PASSWORD" | sha256_text)\"|" "$answer")"
  secret_hash="$(printf '%s' "$ROOT_PASSWORD" | sha256_text)"
  script_hash="$(sha256_file "$0")"
  template_hash="$(sha256_file "$TEMPLATE")"
  cache_hash="$(printf '%s\n%s\n%s\n%s\n%s\n' \
    "${INPUT_ISO_SHA256:-no-stock-sha}" \
    "$redacted_answer_text" \
    "$secret_hash" \
    "$script_hash" \
    "$template_hash" | sha256_text | cut -c1-16)"

  local iso_dir
  iso_dir="${CACHE_ROOT_DIR}/isos"
  mkdir -p "$iso_dir"
  printf '%s/pve-%s-%s.iso\n' "$iso_dir" "$NODE" "$cache_hash"
}

resolve_input_iso() {
  if [[ -s "$INPUT_ISO" ]]; then
    printf '%s\n' "$INPUT_ISO"
    return 0
  fi

  local cache_dir cached url
  cache_dir="${CACHE_ROOT_DIR}/stock"
  cached="${cache_dir}/$(basename "$INPUT_ISO")"
  if [[ -s "$cached" ]]; then
    printf '%s\n' "$cached"
    return 0
  fi

  ensure_cache_disk_room "$CACHE_ROOT_DIR" >&2
  mkdir -p "$cache_dir"
  # Plain HTTP: download.proxmox.com presents a TLS cert for enterprise.proxmox.com
  # only (no SAN match), so HTTPS validation fails. Proxmox themselves serve plain
  # HTTP without redirect for this CDN. Integrity is enforced by verify_input_iso()
  # below against proxmox.installer.iso_sha256, not by TLS.
  url="http://download.proxmox.com/iso/$(basename "$INPUT_ISO")"
  # Progress goes to stderr so callers can capture stdout (the resolved path).
  echo "=== Downloading stock Proxmox ISO ===" >&2
  echo "  URL: ${url}" >&2
  if ! curl -fL --retry 3 -o "${cached}.partial" "$url" >&2; then
    rm -f "${cached}.partial"
    echo "ERROR: failed to download ${url}" >&2
    exit 1
  fi
  mv "${cached}.partial" "$cached"
  printf '%s\n' "$cached"
}

verify_input_iso() {
  local iso="$1"
  [[ -s "$iso" ]] || { echo "ERROR: stock ISO does not exist or is empty: $iso" >&2; exit 1; }
  if [[ -n "$INPUT_ISO_SHA256" && "$INPUT_ISO_SHA256" != "null" ]]; then
    local actual
    actual="$(sha256_file "$iso")"
    if [[ "$actual" != "$INPUT_ISO_SHA256" ]]; then
      echo "ERROR: stock ISO checksum mismatch" >&2
      echo "  Expected: ${INPUT_ISO_SHA256}" >&2
      echo "  Actual:   ${actual}" >&2
      exit 1
    fi
    echo "  Checksum: ${actual}"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; CONFIG_MODE=1; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --print-output-iso) PRINT_OUTPUT_ISO=1; shift ;;
    --input-iso) INPUT_ISO="$2"; shift 2 ;;
    --input-iso-sha256) INPUT_ISO_SHA256="$2"; shift 2 ;;
    --output-iso) OUTPUT_ISO="$2"; shift 2 ;;
    --fqdn) FQDN="$2"; shift 2 ;;
    --cidr) CIDR="$2"; shift 2 ;;
    --gateway) GATEWAY="$2"; shift 2 ;;
    --dns) DNS="$2"; shift 2 ;;
    --root-password) ROOT_PASSWORD="$2"; shift 2 ;;
    --root-password-file) ROOT_PASSWORD_FILE="$2"; shift 2 ;;
    --nic-driver) NIC_DRIVER="$2"; shift 2 ;;
    --disk-pci-path) DISK_PCI_PATH="$2"; shift 2 ;;
    --filesystem) FILESYSTEM="$2"; shift 2 ;;
    --timezone) TIMEZONE="$2"; shift 2 ;;
    --mailto) MAILTO="$2"; shift 2 ;;
    --keyboard) KEYBOARD="$2"; shift 2 ;;
    --country) COUNTRY="$2"; shift 2 ;;
    --reboot-mode) REBOOT_MODE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$CONFIG_MODE" -eq 1 ]]; then
  load_config_mode
elif [[ -n "$CONFIG" || -n "$NODE" ]]; then
  die "--config and --node must be used together"
else
  [[ -n "$OUTPUT_ISO" ]] || die "--output-iso is required in standalone mode"
fi

validate_common
resolve_canonical_paths

WORK_DIR="$(mktemp -d -p "$WORK_ROOT_DIR")"
cleanup() {
  local rc=$?
  rm -rf "$WORK_DIR"
  if [[ "$rc" -ne 0 && "$BUILDING_OUTPUT" -eq 1 && -n "$OUTPUT_ISO" ]]; then
    rm -f "$OUTPUT_ISO"
  fi
}
trap cleanup EXIT

TMP_ANSWER="${WORK_DIR}/answer.toml"
render_answer "$TMP_ANSWER"

if [[ "$CONFIG_MODE" -eq 1 && -z "$OUTPUT_ISO" ]]; then
  OUTPUT_ISO="$(compute_config_output_iso "$TMP_ANSWER")"
fi

if [[ "$PRINT_OUTPUT_ISO" -eq 1 ]]; then
  printf '%s\n' "$OUTPUT_ISO"
  exit 0
fi

echo "=== Generating Proxmox answer file ==="
validate_answer_toml "$TMP_ANSWER"
echo "  FQDN:        ${FQDN}"
echo "  CIDR:        ${CIDR}"
echo "  Gateway:     ${GATEWAY}"
echo "  DNS:         ${DNS}"
echo "  NIC driver:  ${NIC_DRIVER}"
echo "  Disk path:   ${DISK_PCI_PATH}"
echo "  Filesystem:  ${FILESYSTEM}"
echo "  Timezone:    ${TIMEZONE}"
echo "  Reboot mode: ${REBOOT_MODE}"
echo "  Output ISO:  ${OUTPUT_ISO}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo ""
  echo "=== Answer file (dry-run, redacted) ==="
  redacted_answer < "$TMP_ANSWER"
  if [[ -s "$INPUT_ISO" ]]; then
    echo ""
    echo "=== Stock ISO checksum (dry-run) ==="
    verify_input_iso "$INPUT_ISO"
  fi
  exit 0
fi

if [[ -e "$OUTPUT_ISO" ]]; then
  if [[ "$CONFIG_MODE" -eq 1 && -s "$OUTPUT_ISO" ]]; then
    echo "  Cached ISO exists; reusing ${OUTPUT_ISO}"
    exit 0
  fi
  echo "ERROR: --output-iso already exists: $OUTPUT_ISO" >&2
  exit 1
fi

if ! command -v xorriso >/dev/null 2>&1; then
  echo "ERROR: xorriso not found on PATH." >&2
  exit 1
fi

# Output ISO write below is ~1.8 GB. Make sure /nix has room before we start.
ensure_cache_disk_room "$(dirname "$OUTPUT_ISO")"

RESOLVED_INPUT_ISO="$(resolve_input_iso)"
echo ""
echo "=== Verifying stock ISO ==="
echo "  Source: ${RESOLVED_INPUT_ISO}"
verify_input_iso "$RESOLVED_INPUT_ISO"

EXTRACT_DIR="${WORK_DIR}/iso-extract"
ANSWER_FILE="${EXTRACT_DIR}/answer.toml"
MODE_FILE="${EXTRACT_DIR}/auto-installer-mode.toml"

echo ""
echo "=== Extracting stock ISO ==="
mkdir -p "$EXTRACT_DIR"
xorriso -osirrox on -indev "$RESOLVED_INPUT_ISO" -extract / "$EXTRACT_DIR" 2>&1 \
  | grep -E '^(xorriso|libisoburn|drive)' | tail -5 || true

if [[ ! -d "$EXTRACT_DIR/boot/grub" ]]; then
  echo "ERROR: extracted ISO does not contain expected /boot/grub directory." >&2
  exit 1
fi

echo ""
echo "=== Embedding answer files ==="
chmod -R u+w "$EXTRACT_DIR" 2>/dev/null || true
cp "$TMP_ANSWER" "$ANSWER_FILE"
chmod 0600 "$ANSWER_FILE"
printf 'mode = "iso"\npartition_label = "proxmox-ais"\n\n[http]\n' > "$MODE_FILE"
chmod 0600 "$MODE_FILE"
echo "  answer.toml:              embedded"
echo "  auto-installer-mode.toml: embedded"

if [[ ! -f "$EXTRACT_DIR/efi.img" ]]; then
  echo "ERROR: stock ISO does not contain /efi.img — UEFI boot will fail." >&2
  exit 1
fi

echo ""
echo "=== Rebuilding ISO ==="
echo "  Output: ${OUTPUT_ISO}"
mkdir -p "$(dirname "$OUTPUT_ISO")"
BUILDING_OUTPUT=1
xorriso -as mkisofs \
  -o "$OUTPUT_ISO" \
  -r -J -V "PVE" \
  -b boot/grub/i386-pc/eltorito.img \
  -c boot/boot.cat \
  -no-emul-boot -boot-load-size 4 \
  -boot-info-table --grub2-boot-info \
  -eltorito-alt-boot \
  -e efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$EXTRACT_DIR" 2>&1 | tail -10
BUILDING_OUTPUT=0

if [[ ! -s "$OUTPUT_ISO" ]]; then
  echo "ERROR: xorriso did not produce ${OUTPUT_ISO}" >&2
  exit 1
fi
chmod 0600 "$OUTPUT_ISO" 2>/dev/null || true

OUT_SIZE=$(wc -c < "$OUTPUT_ISO" | tr -d ' ')
echo "  Wrote: ${OUTPUT_ISO} (${OUT_SIZE} bytes)"
echo ""
echo "=== Done ==="
echo "  WARNING: ${OUTPUT_ISO} contains the root password in plaintext."
