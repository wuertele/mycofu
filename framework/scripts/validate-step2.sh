#!/usr/bin/env bash
# validate-step2.sh — Step 2 validation gate checks.
#
# Runs V2.1–V2.4 automatically and prints V2.5 manual instructions.
#
# Usage:
#   framework/scripts/validate-step2.sh
#   framework/scripts/validate-step2.sh --config path/to/config.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG="${REPO_DIR}/site/config.yaml"
WRAPPER="${SCRIPT_DIR}/tofu-wrapper.sh"

# Parse args
for arg in "$@"; do
  case "$arg" in
    --config) shift; CONFIG="$1"; shift ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--config path/to/config.yaml]"
      exit 0
      ;;
    -*) echo "ERROR: Unknown option: $arg" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 1
fi

PASS=0
FAIL=0
MANUAL=0

result() {
  local label="$1" status="$2" detail="${3:-}"
  local pad
  pad=$(printf '%*s' $((35 - ${#label})) '')
  if [[ "$status" == "PASS" ]]; then
    echo "${label}${pad}PASS  ${detail}"
    PASS=$((PASS + 1))
  elif [[ "$status" == "FAIL" ]]; then
    echo "${label}${pad}FAIL  ${detail}"
    FAIL=$((FAIL + 1))
  elif [[ "$status" == "MANUAL" ]]; then
    echo "${label}${pad}MANUAL ${detail}"
    MANUAL=$((MANUAL + 1))
  fi
}

echo ""
echo "Step 2 Validation"
echo "================="
echo ""

# --- V2.1 — NixOS image builds ---
V21_DETAIL=""
# Use -L to follow symlinks (result/ is a nix store symlink, files inside may also be symlinks)
if [[ -d "${REPO_DIR}/result" ]] && find -L "${REPO_DIR}/result" -name '*.qcow2' -size +500M 2>/dev/null | grep -q .; then
  # Recent build exists
  QCOW2_FILE=$(find -L "${REPO_DIR}/result" -name '*.qcow2' -type f | head -1)
  SIZE=$(du -h "$QCOW2_FILE" | cut -f1)
  V21_DETAIL="(${QCOW2_FILE##*/}: ${SIZE})"
  result "V2.1 — NixOS image builds:" "PASS" "$V21_DETAIL"
else
  echo "V2.1: No recent build found, building..."
  cd "${REPO_DIR}"
  if nix build --log-format raw .#packages.x86_64-linux.base-image --print-build-logs 2>&1; then
    QCOW2_FILE=$(find -L "${REPO_DIR}/result" -name '*.qcow2' -type f 2>/dev/null | head -1)
    if [[ -n "$QCOW2_FILE" ]]; then
      FILE_SIZE=$(stat -f%z "$QCOW2_FILE" 2>/dev/null || stat --format=%s "$QCOW2_FILE" 2>/dev/null)
      if [[ "$FILE_SIZE" -gt 524288000 ]]; then
        SIZE=$(du -h "$QCOW2_FILE" | cut -f1)
        V21_DETAIL="(${QCOW2_FILE##*/}: ${SIZE})"
        result "V2.1 — NixOS image builds:" "PASS" "$V21_DETAIL"
      else
        result "V2.1 — NixOS image builds:" "FAIL" "(image too small: $(du -h "$QCOW2_FILE" | cut -f1))"
      fi
    else
      result "V2.1 — NixOS image builds:" "FAIL" "(no qcow2 file in result/)"
    fi
  else
    result "V2.1 — NixOS image builds:" "FAIL" "(nix build failed)"
  fi
fi

# --- V2.2 — Image is on Proxmox ---
# Images are uploaded to the Proxmox ISO content directory for storage system visibility
ISO_PATH=$(yq -r '.proxmox.image_storage_path' "$CONFIG")
if [[ -z "$ISO_PATH" || "$ISO_PATH" == "null" ]]; then
  ISO_PATH="/var/lib/vz/template/iso"  # fallback for pre-config.yaml setups
fi
NODE1_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
NODE1_NAME=$(yq -r '.nodes[0].name' "$CONFIG")

if ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE1_IP}" "ls ${ISO_PATH}/base-v*.img" &>/dev/null; then
  REMOTE_FILE=$(ssh "root@${NODE1_IP}" "ls -1 ${ISO_PATH}/base-v*.img | head -1")
  result "V2.2 — Image on Proxmox:" "PASS" "(${NODE1_NAME}:${REMOTE_FILE})"
else
  result "V2.2 — Image on Proxmox:" "FAIL" "(no base image found on ${NODE1_NAME}:${ISO_PATH}/)"
fi

# --- V2.3 — OpenTofu initializes ---
V23_OK=true
echo ""
echo "V2.3: Running tofu init..."
if "${WRAPPER}" init 2>&1 | tail -5; then
  echo ""
else
  V23_OK=false
fi

if $V23_OK; then
  echo "V2.3: Running tofu plan..."
  if "${WRAPPER}" plan -input=false 2>&1 | tail -5; then
    echo ""
    result "V2.3 — OpenTofu initializes:" "PASS" "(init + plan both succeeded)"
  else
    result "V2.3 — OpenTofu initializes:" "FAIL" "(plan failed)"
  fi
else
  result "V2.3 — OpenTofu initializes:" "FAIL" "(init failed)"
fi

# --- V2.4 — OpenTofu state backend ---
# Extract PG connection details from SOPS
if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
  fi
fi

SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"
NAS_IP=$(yq -r '.nas.ip' "$CONFIG")
NAS_PG_PORT=$(yq -r '.nas.postgres_port' "$CONFIG")

if [[ -f "$SECRETS_FILE" ]] && command -v sops &>/dev/null; then
  TOFU_DB_PASSWORD=$(sops -d --output-type json "$SECRETS_FILE" | jq -r '.tofu_db_password')
  SCHEMA_CHECK=$(PGPASSWORD="$TOFU_DB_PASSWORD" psql -h "$NAS_IP" -p "$NAS_PG_PORT" -U tofu -d tofu_state \
    -tAc "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'prod';" 2>/dev/null || echo "0")
  if [[ "$SCHEMA_CHECK" -ge 1 ]]; then
    result "V2.4 — State backend:" "PASS" "(prod schema exists in tofu_state)"
  else
    result "V2.4 — State backend:" "FAIL" "(prod schema not found in tofu_state)"
  fi
else
  result "V2.4 — State backend:" "FAIL" "(cannot decrypt secrets or sops not found)"
fi

# --- V2.5 — Test VM boot (manual) ---
result "V2.5 — Test VM boot:" "MANUAL" "(see instructions below)"

# --- Summary ---
echo ""
echo "---"
echo "Results: ${PASS} passed, ${FAIL} failed, ${MANUAL} manual"
echo ""

if [[ "$MANUAL" -gt 0 ]]; then
  PROD_VLAN=$(yq -r '.environments.prod.vlan_id' "$CONFIG")
  PROD_DOMAIN="prod.$(yq -r '.domain' "$CONFIG")"

  cat <<EOF
V2.5 Instructions:
  1. Edit site/tofu/main.tf — uncomment the test_vm module block
  2. Run: framework/scripts/tofu-wrapper.sh plan
     Verify: plan shows 1 VM to create
  3. Run: framework/scripts/tofu-wrapper.sh apply
  4. SSH to the test VM: ssh root@<dhcp-assigned-ip>
     (Find IP in Proxmox UI → test-step2 → Summary, or via arp-scan on prod VLAN)
  5. Verify: hostname -d  →  should show "${PROD_DOMAIN}"
  6. Verify: cloud-init status  →  should show "done"
  7. Cleanup: framework/scripts/tofu-wrapper.sh destroy
  8. Re-comment the test_vm block in site/tofu/main.tf
EOF
fi

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
