#!/usr/bin/env bash
# configure-vault.sh — Load Vault policies and enable KV-v2 secrets engine.
#
# Usage: framework/scripts/configure-vault.sh <prod|dev>
#
# Run after init-vault.sh. Configures:
#   - KV-v2 secrets engine at secret/
#   - Policies from framework/vault/policies/
#
# Cert auth is NOT configured here (deferred — Vault cert auth is
# incompatible with ACME-issued certificates due to empty CN).
#
# Idempotent: checks before enabling/creating, safe to re-run.

set -euo pipefail

# --- Locate repo root ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2
  exit 1
}

REPO_DIR="$(find_repo_root)"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"

# --- Parse arguments ---
if [[ $# -ne 1 ]] || [[ "$1" != "prod" && "$1" != "dev" ]]; then
  echo "Usage: $0 <prod|dev>" >&2
  exit 1
fi
ENV="$1"

# --- Check prerequisites ---
for tool in sops yq jq curl; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: Required tool not found: $tool" >&2
    exit 1
  fi
done

# --- Read config ---
VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG_FILE")
if [[ -z "$VAULT_IP" || "$VAULT_IP" == "null" ]]; then
  echo "ERROR: No vault_${ENV} IP found in config.yaml" >&2
  exit 1
fi
VAULT_ADDR="https://${VAULT_IP}:8200"

# --- Authenticate with root token ---
# Prefer VAULT_ROOT_TOKEN env var (set by post-deploy.sh after fresh init)
# Fall back to SOPS (normal workstation usage)
if [[ -n "${VAULT_ROOT_TOKEN:-}" ]]; then
  ROOT_TOKEN="$VAULT_ROOT_TOKEN"
else
  ROOT_TOKEN=$(sops -d --extract "[\"vault_${ENV}_root_token\"]" "$SECRETS_FILE")
fi

echo "Configuring Vault ${ENV} at ${VAULT_ADDR}"

# --- Helper: authenticated curl to Vault ---
vault_api() {
  local method="$1" path="$2"
  shift 2
  curl -sk -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -X "$method" "${VAULT_ADDR}/v1/${path}" "$@"
}

# --- Verify Vault is accessible and unsealed ---
echo "Checking Vault health..."
HEALTH=$(vault_api GET sys/health)
SEALED=$(echo "$HEALTH" | jq -r '.sealed')
INITIALIZED=$(echo "$HEALTH" | jq -r '.initialized')

if [[ "$INITIALIZED" != "true" ]]; then
  echo "ERROR: Vault is not initialized. Run init-vault.sh first." >&2
  exit 1
fi
if [[ "$SEALED" == "true" ]]; then
  echo "ERROR: Vault is sealed. Run init-vault.sh first." >&2
  exit 1
fi
echo "Vault is initialized and unsealed."

# --- Enable KV-v2 secrets engine ---
echo ""
echo "=== KV-v2 Secrets Engine ==="
MOUNTS=$(vault_api GET sys/mounts)
if echo "$MOUNTS" | jq -e '."secret/"' > /dev/null 2>&1; then
  echo "secret/ engine already enabled"
else
  echo "Enabling kv-v2 at secret/..."
  vault_api POST sys/mounts/secret -d '{"type": "kv", "options": {"version": "2"}}'
  echo "KV-v2 enabled."
fi

# --- Load policies ---
echo ""
echo "=== Policies ==="
for policy in dns vault-self default; do
  POLICY_FILE="${REPO_DIR}/framework/vault/policies/${policy}.hcl"
  if [[ ! -f "$POLICY_FILE" ]]; then
    echo "ERROR: Policy file not found: ${POLICY_FILE}" >&2
    exit 1
  fi
  POLICY_CONTENT=$(cat "$POLICY_FILE")
  echo "Writing ${policy}-policy..."
  vault_api PUT "sys/policies/acl/${policy}-policy" \
    -d "$(jq -n --arg policy "$POLICY_CONTENT" '{policy: $policy}')"
done

# --- Enable AppRole auth ---
echo ""
echo "=== AppRole Auth ==="
AUTH_MOUNTS=$(vault_api GET sys/auth)
if echo "$AUTH_MOUNTS" | jq -e '.data["approle/"] // .["approle/"]' > /dev/null 2>&1; then
  echo "approle/ auth already enabled"
else
  echo "Enabling AppRole auth..."
  vault_api POST sys/auth/approle -d '{"type": "approle"}'
  echo "AppRole auth enabled."
fi

# --- Create AppRole roles for vault-agent VMs ---
echo ""
echo "=== AppRole Roles ==="

# Determine which VMs use vault-agent in this environment
APPROLE_VMS=""
case "$ENV" in
  prod) APPROLE_VMS="dns1_prod dns2_prod gatus gitlab" ;;
  dev)  APPROLE_VMS="dns1_dev dns2_dev" ;;
esac

for vm_key in $APPROLE_VMS; do
  # Write-once check: skip only if BOTH credentials exist in SOPS AND
  # the role exists in Vault. After a PBS restore, Vault may have lost
  # the AppRole roles even though SOPS still has credentials. In that
  # case, recreate the role and generate fresh credentials.
  SOPS_ROLE_KEY="vault_approle_${vm_key}_role_id"
  SOPS_SECRET_KEY="vault_approle_${vm_key}_secret_id"
  EXISTING_ROLE=$(sops -d --extract "[\"${SOPS_ROLE_KEY}\"]" "$SECRETS_FILE" 2>/dev/null || true)
  EXISTING_SECRET=$(sops -d --extract "[\"${SOPS_SECRET_KEY}\"]" "$SECRETS_FILE" 2>/dev/null || true)

  SOPS_HAS_BOTH=false
  if [[ -n "$EXISTING_ROLE" && "$EXISTING_ROLE" != "null" && -n "$EXISTING_SECRET" && "$EXISTING_SECRET" != "null" ]]; then
    SOPS_HAS_BOTH=true
  fi

  if [[ "$SOPS_HAS_BOTH" == "true" ]]; then
    # SOPS has credentials — verify the role still exists in Vault
    VAULT_ROLE_CHECK=$(vault_api GET "auth/approle/role/${vm_key}" 2>/dev/null || echo "")
    if echo "$VAULT_ROLE_CHECK" | jq -e '.data.token_ttl' > /dev/null 2>&1; then
      echo "  ${vm_key}: SOPS and Vault consistent — skipping"
      continue
    else
      echo "  ${vm_key}: SOPS has credentials but role missing from Vault (PBS restore?) — recreating"
    fi
  elif [[ -n "$EXISTING_ROLE" || -n "$EXISTING_SECRET" ]]; then
    echo "  ${vm_key}: partial SOPS state (role_id=${EXISTING_ROLE:+present}${EXISTING_ROLE:-missing}, secret_id=${EXISTING_SECRET:+present}${EXISTING_SECRET:-missing}) — recreating both"
  fi

  # Determine the policy for this VM role
  # Strip environment suffix to get the base role (dns1_prod → dns1, gatus → gatus)
  base_role=$(echo "$vm_key" | sed 's/_prod$//;s/_dev$//')
  case "$base_role" in
    dns1|dns2) ROLE_POLICIES="default-policy,dns-policy" ;;
    gatus)     ROLE_POLICIES="default-policy" ;;
    gitlab)    ROLE_POLICIES="default-policy" ;;
    *)         ROLE_POLICIES="default-policy" ;;
  esac

  echo "  ${vm_key}: creating AppRole role (policies: ${ROLE_POLICIES})..."

  # Create the role
  vault_api POST "auth/approle/role/${vm_key}" \
    -d "$(jq -n \
      --arg policies "$ROLE_POLICIES" \
      '{
        bind_secret_id: true,
        secret_id_num_uses: 0,
        token_ttl: "24h",
        token_max_ttl: "720h",
        token_policies: ($policies | split(","))
      }')" > /dev/null

  # Read role_id
  ROLE_ID=$(vault_api GET "auth/approle/role/${vm_key}/role-id" | jq -r '.data.role_id')
  if [[ -z "$ROLE_ID" || "$ROLE_ID" == "null" ]]; then
    echo "  ERROR: Failed to read role_id for ${vm_key}" >&2
    exit 1
  fi

  # Generate secret_id
  SECRET_ID=$(vault_api POST "auth/approle/role/${vm_key}/secret-id" | jq -r '.data.secret_id')
  if [[ -z "$SECRET_ID" || "$SECRET_ID" == "null" ]]; then
    echo "  ERROR: Failed to generate secret_id for ${vm_key}" >&2
    exit 1
  fi

  # Store in SOPS (write-once)
  sops --set "[\"${SOPS_ROLE_KEY}\"] \"${ROLE_ID}\"" "$SECRETS_FILE"
  sops --set "[\"${SOPS_SECRET_KEY}\"] \"${SECRET_ID}\"" "$SECRETS_FILE"
  echo "  ${vm_key}: role_id and secret_id stored in SOPS"
done

# --- Commit SOPS changes if any ---
cd "$REPO_DIR"
if ! git diff --quiet site/sops/secrets.yaml 2>/dev/null; then
  echo ""
  echo "Committing AppRole credentials to SOPS..."
  git add site/sops/secrets.yaml
  git commit -m "vault: add AppRole credentials for ${ENV} vault-agent VMs

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
  echo "SOPS committed."
fi

# --- Seed KV secrets from SOPS ---
# vault-agent templates on VMs read secrets from Vault KV. These secrets
# originate in SOPS and must be written to Vault so vault-agent can retrieve
# them. This is idempotent: existing values are overwritten with the current
# SOPS value (KV-v2 keeps versions).
echo ""
echo "=== KV Secrets ==="

# Map: KV path → SOPS key
# Add entries here when new vault-agent templates are added to NixOS modules.
KV_SECRETS="
secret/data/dns/pdns-api-key=pdns_api_key
"

for entry in $KV_SECRETS; do
  kv_path="${entry%%=*}"
  sops_key="${entry##*=}"

  set +e
  secret_value=$(sops -d --extract "[\"${sops_key}\"]" "$SECRETS_FILE" 2>/dev/null)
  sops_exit=$?
  set -e

  if [[ $sops_exit -ne 0 || -z "$secret_value" || "$secret_value" == "null" ]]; then
    echo "  ${kv_path}: SOPS key '${sops_key}' not found — skipping"
    continue
  fi

  vault_api POST "$kv_path" \
    -d "$(jq -n --arg value "$secret_value" '{data: {value: $value}}')" > /dev/null
  echo "  ${kv_path}: written from SOPS key '${sops_key}'"
done

# --- Verify ---
echo ""
echo "=== Verification ==="
echo "Policies loaded:"
vault_api LIST sys/policies/acl | jq -r '.data.keys[]' | grep -v '^root$' | sort
echo ""
echo "Secrets engines:"
vault_api GET sys/mounts | jq -r '.data // . | to_entries[] | select(.value.type == "kv") | .key'
echo ""
echo "Auth methods:"
vault_api GET sys/auth | jq -r '.data // . | to_entries[] | .key' | sort
echo ""
echo "AppRole roles:"
vault_api LIST auth/approle/role 2>/dev/null | jq -r '.data.keys[] // empty' 2>/dev/null || echo "  (none)"
echo ""
echo "=== Vault ${ENV} configured ==="
