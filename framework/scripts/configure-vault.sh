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
# KV secrets are NOT written here (no vault-agent consumers yet).
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
    echo "WARNING: Policy file not found: ${POLICY_FILE}" >&2
    continue
  fi
  POLICY_CONTENT=$(cat "$POLICY_FILE")
  echo "Writing ${policy}-policy..."
  vault_api PUT "sys/policies/acl/${policy}-policy" \
    -d "$(jq -n --arg policy "$POLICY_CONTENT" '{policy: $policy}')"
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
echo "=== Vault ${ENV} configured ==="
