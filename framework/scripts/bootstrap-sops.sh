#!/bin/bash
# bootstrap-sops.sh — Generate age keypair, configure SOPS, create initial encrypted secrets
#
# Usage:
#   framework/scripts/bootstrap-sops.sh [path/to/config.yaml]
#   framework/scripts/bootstrap-sops.sh --force  (overwrite existing secrets)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG="${1:-${REPO_DIR}/site/config.yaml}"
SOPS_DIR="${REPO_DIR}/site/sops"
KEY_FILE="${REPO_DIR}/operator.age.key"
FORCE=0

# Parse args
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done
# Re-set CONFIG in case --force was the only arg
if [[ "$CONFIG" == "--force" ]]; then
  CONFIG="${REPO_DIR}/site/config.yaml"
fi

# --- Check required tools ---
MISSING=()
for tool in age age-keygen sops openssl; do
  if ! command -v "$tool" &>/dev/null; then
    MISSING+=("$tool")
  fi
done

# Check for yq, fall back to python yaml parsing
HAS_YQ=0
if command -v yq &>/dev/null; then
  HAS_YQ=1
elif ! command -v python3 &>/dev/null; then
  MISSING+=("yq or python3")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: Required tools not found: ${MISSING[*]}" >&2
  echo "Install them before running this script." >&2
  exit 2
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 2
fi

# --- Helper to read yaml values ---
yaml_read() {
  local key="$1" file="$2"
  if [[ $HAS_YQ -eq 1 ]]; then
    yq -r "$key" "$file"
  else
    python3 -c "import yaml,sys; d=yaml.safe_load(open('$file')); print(eval('d' + ''.join('[\"'+k+'\"]' for k in '$key'.strip('.').split('.'))))"
  fi
}

# --- 1. Generate age keypair ---
if [[ -f "$KEY_FILE" ]]; then
  echo "Age key already exists at $KEY_FILE — skipping generation."
  AGE_PUBLIC=$(grep "public key:" "$KEY_FILE" | awk '{print $NF}')
else
  echo "Generating age keypair..."
  age-keygen -o "$KEY_FILE" 2>&1 | tee /dev/stderr
  AGE_PUBLIC=$(grep "public key:" "$KEY_FILE" | awk '{print $NF}')
  echo ""
  echo "Age keypair generated."
  echo "  Private key: $KEY_FILE (NEVER commit this to Git)"
  echo "  Public key:  $AGE_PUBLIC"
fi

# --- 2. Write SOPS configuration ---
mkdir -p "$SOPS_DIR"
cat > "$SOPS_DIR/.sops.yaml" << EOF
creation_rules:
  - path_regex: \.yaml\$
    age: >-
      $AGE_PUBLIC
EOF
echo "SOPS configuration written to $SOPS_DIR/.sops.yaml"

# --- 3. Check for existing secrets ---
if [[ -f "$SOPS_DIR/secrets.yaml" && $FORCE -eq 0 ]]; then
  echo ""
  echo "WARNING: $SOPS_DIR/secrets.yaml already exists."
  read -p "Overwrite? (y/N) " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted. Use --force to skip this prompt."
    exit 1
  fi
fi

# --- 4. Gather secrets ---
echo ""
echo "=== Secrets Collection ==="
echo "Some secrets will be prompted, others auto-generated."
echo ""

# Prompted secrets
read -sp "Proxmox API password (root@pam): " PROXMOX_PASS
echo ""
read -sp "OpenTofu PostgreSQL password: " TF_DB_PASS
echo ""

# Auto-generated secrets
PDNS_API_KEY=$(openssl rand -hex 32)
echo "PowerDNS API key auto-generated."

# Generate CI SSH keypair (separate from operator's workstation key).
# The CI private key goes to the runner for node access.
# The CI public key is installed on nodes and VMs alongside the operator key.
CI_KEY_DIR=$(mktemp -d)
ssh-keygen -t ed25519 -N "" -C "ci-runner" -f "${CI_KEY_DIR}/ci_key" -q
SSH_PRIVKEY=$(cat "${CI_KEY_DIR}/ci_key")
SSH_PUBKEY=$(cat "${CI_KEY_DIR}/ci_key.pub")
rm -rf "$CI_KEY_DIR"
echo "CI SSH keypair auto-generated."

# Read operator public key from config.yaml
OPERATOR_SSH_PUBKEY=$(yaml_read '.operator_ssh_pubkey' "$CONFIG")
echo "Operator SSH public key read from config.yaml."

# --- 5. Create encrypted secrets file ---
export SOPS_AGE_KEY_FILE="$KEY_FILE"
export SOPS_AGE_RECIPIENTS="$AGE_PUBLIC"

cat << EOF | sops --input-type yaml --output-type yaml -e /dev/stdin > "$SOPS_DIR/secrets.yaml"
proxmox_api_user: root@pam
proxmox_api_password: $PROXMOX_PASS
pdns_api_key: $PDNS_API_KEY
tofu_db_password: $TF_DB_PASS
ssh_pubkey: $SSH_PUBKEY
ssh_privkey: |
$(echo "$SSH_PRIVKEY" | sed 's/^/  /')
operator_ssh_pubkey: $OPERATOR_SSH_PUBKEY
vault_unseal_keys: []
EOF

echo ""
echo "Encrypted secrets written to $SOPS_DIR/secrets.yaml"
echo ""

# --- 6. Verify ---
echo "=== Verification ==="
sops -d "$SOPS_DIR/secrets.yaml" > /dev/null
echo "✓ SOPS decryption succeeded"

# --- 7. Ensure .gitignore ---
GITIGNORE="${REPO_DIR}/.gitignore"
if [[ -f "$GITIGNORE" ]]; then
  if ! grep -qF "operator.age.key" "$GITIGNORE"; then
    # Ensure file ends with a newline before appending
    [[ -s "$GITIGNORE" && "$(tail -c 1 "$GITIGNORE")" != "" ]] && echo "" >> "$GITIGNORE"
    echo "operator.age.key" >> "$GITIGNORE"
    echo "Added operator.age.key to .gitignore"
  fi
else
  echo "operator.age.key" > "$GITIGNORE"
  echo "Created .gitignore with operator.age.key"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  IMPORTANT: Back up operator.age.key to a secure        ║"
echo "║  location. This is the root of trust for all encrypted  ║"
echo "║  secrets. If lost, secrets cannot be recovered.         ║"
echo "╚══════════════════════════════════════════════════════════╝"
