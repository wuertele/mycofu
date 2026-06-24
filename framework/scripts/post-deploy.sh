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
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

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
    echo "ERROR: Vault ${ENV} is sealed and no unseal key on vdb." >&2
    echo "Operator must run: init-vault.sh ${ENV}" >&2
    exit 1
  fi
elif [[ "$INITIALIZED" == "false" ]]; then
  # Do NOT initialize Vault from the pipeline. Vault initialization
  # generates an unseal key and root token that MUST be stored in SOPS
  # atomically. The pipeline cannot commit to git, so initializing here
  # creates a SOPS drift time bomb: vdb has new tokens, SOPS has stale
  # ones. On the next PBS restore + init-vault.sh run, the mismatch
  # triggers auto-recovery which wipes all Vault data.
  echo ""
  echo "=================================================="
  echo "ACTION REQUIRED: Vault ${ENV} needs initialization"
  echo "=================================================="
  echo ""
  echo "Run from the workstation (where SOPS can be updated):"
  echo "  framework/scripts/init-vault.sh ${ENV}"
  echo "  framework/scripts/configure-vault.sh ${ENV}"
  echo ""
  exit 1
fi

# Always configure vault (idempotent) — read root token from vdb if needed
if [[ -z "$ROOT_TOKEN" ]]; then
  ROOT_TOKEN=$(ssh $SSH_OPTS "root@${VAULT_IP}" "cat /var/lib/vault/root-token 2>/dev/null" || true)
fi
if [[ -n "$ROOT_TOKEN" ]]; then
  VAULT_ROOT_TOKEN="$ROOT_TOKEN" "${SCRIPT_DIR}/configure-vault.sh" "${ENV}"
else
  echo "ERROR: No root token available for vault configuration." >&2
  echo "Operator must run: configure-vault.sh ${ENV}" >&2
  exit 1
fi

echo ""
echo "=== Cert storage backfill ==="
VAULT_ROOT_TOKEN="$ROOT_TOKEN" \
  "${SCRIPT_DIR}/cert-storage-backfill.sh" "${ENV}"

# Dashboard tokens live in Vault KV and are rendered by vault-agent on the
# InfluxDB VM, so they must be provisioned only after configure-vault.sh has
# ensured the secrets engine and policies exist for this environment.
echo ""
echo "=== Dashboard token provisioning ==="
INFLUX_ENABLED=$(yq -r '.applications.influxdb.enabled // false' "$APPS_CONFIG")
INFLUX_IP=$(yq -r ".applications.influxdb.environments.${ENV}.ip // \"\"" "$APPS_CONFIG")
if [[ "$INFLUX_ENABLED" == "true" && -n "$INFLUX_IP" && "$INFLUX_IP" != "null" ]]; then
  VAULT_ROOT_TOKEN="$ROOT_TOKEN" "${SCRIPT_DIR}/configure-dashboard-tokens.sh" "${ENV}"
else
  echo "  influxdb application not enabled for ${ENV} — skipping dashboard token provisioning"
fi

# --- PBS backup jobs ---
echo ""
echo "=== PBS backup jobs ==="
# Only configure backup jobs if PBS storage is registered in Proxmox.
# On first deploy, PBS hasn't been installed yet (install-pbs.sh runs later),
# so pbs-nas storage won't exist. Failing here would be a false error.
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
if ssh $SSH_OPTS "root@${FIRST_NODE_IP}" "pvesm status 2>/dev/null | grep -q pbs-nas" 2>/dev/null; then
  "${SCRIPT_DIR}/configure-backups.sh"
else
  echo "  PBS storage not available — skipping backup jobs"
fi

echo ""
echo "=== Post-deploy complete ==="
