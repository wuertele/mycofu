#!/usr/bin/env bash
# init-vault.sh — Initialize a fresh Vault instance, capture unseal key and root
# token, write them to SOPS, and commit.
#
# Usage: framework/scripts/init-vault.sh <prod|dev>
#
# Run ONCE per environment, after the Vault VM has a TLS cert but before
# auto-unseal can work (unseal key doesn't exist in SOPS yet).
#
# Idempotent: if Vault is already initialized, skips to unseal.
#
# Uses curl for Vault API calls (vault CLI has BSL license, not in dev shell).

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
FORCE_INIT=false
ENV=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-init) FORCE_INIT=true; shift ;;
    prod|dev) ENV="$1"; shift ;;
    *) echo "Usage: $0 [--force-init] <prod|dev>" >&2; exit 1 ;;
  esac
done
if [[ -z "$ENV" ]]; then
  echo "Usage: $0 [--force-init] <prod|dev>" >&2
  exit 1
fi

# --- Check prerequisites ---
for tool in sops yq jq curl; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: Required tool not found: $tool" >&2
    echo "Run 'nix develop' from the repo root." >&2
    exit 1
  fi
done

# --- Determine Vault address ---
VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG_FILE")
if [[ -z "$VAULT_IP" || "$VAULT_IP" == "null" ]]; then
  echo "ERROR: No vault_${ENV} IP found in config.yaml" >&2
  exit 1
fi
VAULT_ADDR="https://${VAULT_IP}:8200"

echo "Vault address: $VAULT_ADDR"

# --- Helper: curl to Vault API (skip TLS verify — Pebble or self-signed) ---
vault_api() {
  local method="$1" path="$2"
  shift 2
  curl -sk -X "$method" "${VAULT_ADDR}/v1/${path}" "$@"
}

# --- Check initialization status ---
echo "Checking Vault status..."
HEALTH=$(vault_api GET sys/health)
INITIALIZED=$(echo "$HEALTH" | jq -r '.initialized // false')
SEALED=$(echo "$HEALTH" | jq -r '.sealed // true')

echo "  initialized: $INITIALIZED"
echo "  sealed: $SEALED"

# --- Check if unseal key already exists in SOPS ---
SOPS_KEY="vault_${ENV}_unseal_key"
EXISTING_KEY=""
if [[ -f "$SECRETS_FILE" ]]; then
  EXISTING_KEY=$(sops -d --extract "[\"${SOPS_KEY}\"]" "$SECRETS_FILE" 2>/dev/null || true)
fi

if [[ "$INITIALIZED" == "true" ]]; then
  echo "Vault is already initialized."

  # --- Unseal if sealed ---
  if [[ "$SEALED" == "true" ]]; then
    if [[ -n "$EXISTING_KEY" ]]; then
      echo "Unsealing with key from SOPS..."
      UNSEAL_RESULT=$(vault_api PUT sys/unseal -d "{\"key\": \"${EXISTING_KEY}\"}")
      STILL_SEALED=$(echo "$UNSEAL_RESULT" | jq -r '.sealed')
      if [[ "$STILL_SEALED" == "false" ]]; then
        echo "Vault unsealed."
      else
        echo "ERROR: Unseal failed." >&2
        echo "$UNSEAL_RESULT" | jq . >&2
        exit 1
      fi
    else
      echo "ERROR: Vault is sealed but no unseal key found in SOPS." >&2
      echo "The unseal key may have been lost. Manual recovery required." >&2
      exit 1
    fi
  else
    echo "Vault is already unsealed."
  fi

  # --- Verify SOPS root token works ---
  # Write-once invariant: both unseal key and root token in SOPS were written
  # by the same `vault operator init` that produced the Raft data. After PBS
  # restore, SOPS values match the restored data. Do NOT overwrite SOPS here.
  SOPS_TOKEN_KEY="vault_${ENV}_root_token"
  EXISTING_TOKEN=""
  if [[ -f "$SECRETS_FILE" ]]; then
    EXISTING_TOKEN=$(sops -d --extract "[\"${SOPS_TOKEN_KEY}\"]" "$SECRETS_FILE" 2>/dev/null || true)
  fi

  if [[ -n "$EXISTING_TOKEN" ]]; then
    echo "Verifying SOPS root token..."
    # Use auth/token/lookup-self — this is an authenticated endpoint that
    # will fail with 403 if the token is invalid. /v1/sys/health is NOT
    # authenticated and always succeeds regardless of token.
    VERIFY=$(curl -sk -o /dev/null -w '%{http_code}' \
      -H "X-Vault-Token: ${EXISTING_TOKEN}" \
      "${VAULT_ADDR}/v1/auth/token/lookup-self" 2>/dev/null)
    if [[ "$VERIFY" == "200" ]]; then
      echo "SOPS root token verified."
    else
      echo "ERROR: SOPS root token is invalid (HTTP ${VERIFY})." >&2
      echo "" >&2
      echo "The SOPS root token does not match Vault's Raft data." >&2
      echo "This means SOPS and the running Vault were produced by different" >&2
      echo "vault operator init events. Possible causes:" >&2
      echo "  - Vault vdb was not restored from PBS after a rebuild" >&2
      echo "  - SOPS was overwritten by a stale init (write-once violation)" >&2
      echo "" >&2
      echo "Recovery options:" >&2
      echo "  1. Restore Vault vdb from PBS backup (SOPS keys will match):" >&2
      echo "     framework/scripts/restore-from-pbs.sh --target \$(yq '.vms.vault_${ENV}.vmid' site/config.yaml) --force" >&2
      echo "  2. If no backup exists, reinitialize (destroys all Vault data):" >&2
      echo "     $0 --force-init ${ENV}" >&2
      exit 1
    fi
  else
    echo "ERROR: No root token found in SOPS for ${ENV}." >&2
    echo "configure-vault.sh will fail. Re-initialize Vault if needed." >&2
    exit 1
  fi

  echo ""
  echo "=== Vault ${ENV} is ready ==="
  echo "Next step: framework/scripts/configure-vault.sh ${ENV}"
  exit 0
fi

# --- Check for existing SOPS keys before initializing ---
# Write-once safety: if SOPS already has vault keys for this environment,
# a fresh init will overwrite them — breaking correspondence with PBS backups.
if [[ -n "$EXISTING_KEY" ]]; then
  if [[ "$FORCE_INIT" == "true" ]]; then
    echo "WARNING: SOPS already contains vault keys for ${ENV}."
    echo "  --force-init specified — proceeding with fresh initialization."
    echo "  The new keys will NOT match any existing PBS backups."
  else
    echo "ERROR: SOPS already contains vault keys for ${ENV}." >&2
    echo "" >&2
    echo "Vault is not initialized, but SOPS has keys from a previous init." >&2
    echo "This usually means Vault's vdb needs to be restored from PBS backup." >&2
    echo "" >&2
    echo "Recovery options:" >&2
    echo "  1. Restore Vault vdb from PBS backup (recommended):" >&2
    echo "     framework/scripts/restore-from-pbs.sh --target \$(yq '.vms.vault_${ENV}.vmid' site/config.yaml) --force" >&2
    echo "     Then re-run: $0 ${ENV}" >&2
    echo "  2. If no backup exists, reinitialize (generates new keys, overwrites SOPS):" >&2
    echo "     $0 --force-init ${ENV}" >&2
    exit 1
  fi
fi

# --- Initialize Vault ---
echo "Initializing Vault (key-shares=1, key-threshold=1)..."
INIT_OUTPUT=$(vault_api PUT sys/init \
  -d '{"secret_shares": 1, "secret_threshold": 1}')

UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.keys_base64[0]')
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

if [[ -z "$UNSEAL_KEY" || "$UNSEAL_KEY" == "null" || -z "$ROOT_TOKEN" || "$ROOT_TOKEN" == "null" ]]; then
  echo "ERROR: Failed to extract unseal key or root token from init output" >&2
  echo "$INIT_OUTPUT" | jq . >&2
  exit 1
fi

echo "Vault initialized successfully."

# --- Write to SOPS ---
echo "Writing unseal key and root token to SOPS..."
sops --set "[\"vault_${ENV}_unseal_key\"] \"${UNSEAL_KEY}\"" "$SECRETS_FILE"
sops --set "[\"vault_${ENV}_root_token\"] \"${ROOT_TOKEN}\"" "$SECRETS_FILE"
echo "SOPS updated."

# --- Unseal ---
echo "Unsealing Vault..."
UNSEAL_RESULT=$(vault_api PUT sys/unseal -d "{\"key\": \"${UNSEAL_KEY}\"}")
STILL_SEALED=$(echo "$UNSEAL_RESULT" | jq -r '.sealed')
if [[ "$STILL_SEALED" == "false" ]]; then
  echo "Vault unsealed."
else
  echo "ERROR: Unseal failed after init." >&2
  echo "$UNSEAL_RESULT" | jq . >&2
  exit 1
fi

# --- Write unseal key to VM persistent storage ---
# This allows auto-unseal to work on reboot without needing a tofu apply
# to update CIDATA (which would recreate the VM and wipe Raft).
echo "Writing unseal key and root token to VM persistent storage..."
ssh -n -o StrictHostKeyChecking=accept-new "root@${VAULT_IP}" \
  "mkdir -p /var/lib/vault && printf '%s' '${UNSEAL_KEY}' > /var/lib/vault/unseal-key && chmod 400 /var/lib/vault/unseal-key"
ssh -n -o StrictHostKeyChecking=accept-new "root@${VAULT_IP}" \
  "printf '%s' '${ROOT_TOKEN}' > /var/lib/vault/root-token && chmod 400 /var/lib/vault/root-token"
echo "Unseal key and root token written to VM persistent storage."

# --- Commit ---
echo "Committing SOPS changes..."
cd "$REPO_DIR"
git add site/sops/secrets.yaml
git commit -m "vault: add ${ENV} unseal key and root token

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"

echo ""
echo "=== Vault ${ENV} initialized and unsealed ==="
echo ""
echo "Unseal key and root token are stored in site/sops/secrets.yaml"
echo "The unseal key is NEVER written to disk unencrypted."
echo ""
echo "Next step: framework/scripts/configure-vault.sh ${ENV}"
