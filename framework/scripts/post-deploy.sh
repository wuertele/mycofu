#!/usr/bin/env bash
# post-deploy.sh — Run after tofu apply to handle VM recreation side effects.
#
# Handles:
#   - Vault initialization (if VM was recreated and is uninitialized)
#   - Vault configuration (policies, secrets engines)
#   - PBS backup job verification
#
# Usage:
#   framework/scripts/post-deploy.sh <dev|prod>
#
# Safe to run on every deploy — idempotent. Does nothing if VMs are healthy.
#
# NOTE: When vault is initialized by the pipeline, the unseal key is written
# to vdb but NOT to SOPS (the pipeline cannot commit). The operator should
# run init-vault.sh from the workstation to update SOPS with the backup copy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

if [[ $# -ne 1 ]] || [[ "$1" != "dev" && "$1" != "prod" ]]; then
  echo "Usage: $0 <dev|prod>" >&2
  exit 1
fi
ENV="$1"

SSH_OPTS="-n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# --- Vault post-deploy ---
VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")
echo "=== Vault ${ENV} post-deploy (${VAULT_IP}) ==="

# Wait for vault to be reachable (may have just been recreated)
for i in $(seq 1 30); do
  if curl -sk "https://${VAULT_IP}:8200/v1/sys/health" >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for vault-${ENV} to be reachable... ($i/30)"
  sleep 10
done

HEALTH=$(curl -sk "https://${VAULT_IP}:8200/v1/sys/health" 2>/dev/null || echo '{}')
INITIALIZED=$(echo "$HEALTH" | jq -r '.initialized // false')
SEALED=$(echo "$HEALTH" | jq -r '.sealed // true')

ROOT_TOKEN=""

if [[ "$INITIALIZED" == "true" && "$SEALED" == "false" ]]; then
  echo "Vault ${ENV} is initialized and unsealed."
elif [[ "$INITIALIZED" == "true" && "$SEALED" == "true" ]]; then
  echo "Vault ${ENV} is sealed — attempting unseal from vdb..."
  UNSEAL_KEY=$(ssh $SSH_OPTS "root@${VAULT_IP}" "cat /var/lib/vault/unseal-key 2>/dev/null" || true)
  if [[ -n "$UNSEAL_KEY" ]]; then
    curl -sk -X PUT "https://${VAULT_IP}:8200/v1/sys/unseal" \
      -d "{\"key\": \"${UNSEAL_KEY}\"}" >/dev/null
    echo "Vault ${ENV} unsealed."
  else
    echo "WARNING: Vault ${ENV} is sealed and no unseal key on vdb." >&2
    echo "Operator must run: init-vault.sh ${ENV}" >&2
  fi
elif [[ "$INITIALIZED" == "false" ]]; then
  echo "Vault ${ENV} is uninitialized — initializing..."

  # Wait for TLS cert (certbot runs at boot)
  for i in $(seq 1 30); do
    if curl -sk "https://${VAULT_IP}:8200/" -o /dev/null 2>&1; then
      break
    fi
    echo "Waiting for vault-${ENV} TLS cert... ($i/30)"
    sleep 10
  done

  # Initialize
  INIT_OUTPUT=$(curl -sk -X PUT "https://${VAULT_IP}:8200/v1/sys/init" \
    -d '{"secret_shares": 1, "secret_threshold": 1}')
  UNSEAL_KEY=$(echo "$INIT_OUTPUT" | jq -r '.keys_base64[0]')
  ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')

  if [[ -z "$UNSEAL_KEY" || "$UNSEAL_KEY" == "null" ]]; then
    echo "ERROR: Vault ${ENV} initialization failed" >&2
    echo "$INIT_OUTPUT" >&2
    exit 1
  fi

  # Unseal
  curl -sk -X PUT "https://${VAULT_IP}:8200/v1/sys/unseal" \
    -d "{\"key\": \"${UNSEAL_KEY}\"}" >/dev/null
  echo "Vault ${ENV} initialized and unsealed."

  # Write keys to vdb (persistent across reboots)
  ssh $SSH_OPTS "root@${VAULT_IP}" \
    "mkdir -p /var/lib/vault && printf '%s' '${UNSEAL_KEY}' > /var/lib/vault/unseal-key && chmod 400 /var/lib/vault/unseal-key"
  ssh $SSH_OPTS "root@${VAULT_IP}" \
    "printf '%s' '${ROOT_TOKEN}' > /var/lib/vault/root-token && chmod 400 /var/lib/vault/root-token"
  echo "Unseal key and root token written to vdb."

  echo "WARNING: SOPS not updated — operator must run init-vault.sh ${ENV} to backup keys to SOPS." >&2
fi

# Always configure vault (idempotent) — read root token from vdb if needed
if [[ -z "$ROOT_TOKEN" ]]; then
  ROOT_TOKEN=$(ssh $SSH_OPTS "root@${VAULT_IP}" "cat /var/lib/vault/root-token 2>/dev/null" || true)
fi
if [[ -n "$ROOT_TOKEN" ]]; then
  VAULT_ROOT_TOKEN="$ROOT_TOKEN" "${SCRIPT_DIR}/configure-vault.sh" "${ENV}"
else
  echo "Skipping vault configuration — no root token available."
  echo "Operator must run: configure-vault.sh ${ENV}" >&2
fi

# --- PBS backup jobs ---
echo ""
echo "=== PBS backup jobs ==="
"${SCRIPT_DIR}/configure-backups.sh" || true

echo ""
echo "=== Post-deploy complete ==="
