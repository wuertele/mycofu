#!/usr/bin/env bash
# DRT-ID: DRT-004
# DRT-NAME: Vault HA Failover
# DRT-TIME: ~5 min
# DRT-DESTRUCTIVE: yes
# DRT-DESC: Kill the Vault VM's QEMU process to simulate a sudden crash.
#           Verify that Proxmox HA restarts the VM and Vault auto-unseals
#           within an acceptable RTO. Uses HTTP API only (no vault CLI).
#           All Vault curls run via SSH from dns1-prod to avoid macOS
#           TLS 1.3 incompatibility with Go's post-quantum key exchange.

set -euo pipefail

DRT_ID="DRT-004"
DRT_NAME="Vault HA Failover"

source "$(dirname "$0")/../lib/common.sh"

drt_init

# ── Resolve identities ──────────────────────────────────────────────

VAULT_VMID=$(drt_vm_vmid vault prod)
VAULT_NODE=$(drt_config '.vms.vault_prod.node')
VAULT_NODE_IP=$(drt_node_ip "$VAULT_NODE")
DNS1_IP=$(drt_vm_ip dns1 prod)
DOMAIN=$(drt_domain)
VAULT_URL="https://vault.prod.${DOMAIN}:8200"

echo "  Vault VMID:   ${VAULT_VMID}"
echo "  Vault node:   ${VAULT_NODE} (${VAULT_NODE_IP})"
echo "  SSH proxy:    dns1-prod (${DNS1_IP})"
echo ""

# Helper: curl Vault via SSH from dns1-prod
vault_curl() {
  ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "root@${DNS1_IP}" \
    "curl -sk --max-time 10 $*" 2>/dev/null
}

# ── Preconditions ────────────────────────────────────────────────────

drt_check "validate.sh is green" framework/scripts/validate.sh

drt_step "Checking Vault health before failover"
HEALTH_JSON=$(vault_curl "'${VAULT_URL}/v1/sys/health'" || echo "{}")
VAULT_INIT=$(echo "$HEALTH_JSON" | jq -r 'if .initialized == null then "UNKNOWN" else (.initialized | tostring) end')
VAULT_SEALED=$(echo "$HEALTH_JSON" | jq -r 'if .sealed == null then "UNKNOWN" else (.sealed | tostring) end')
echo "  Vault initialized: ${VAULT_INIT}"
echo "  Vault sealed:      ${VAULT_SEALED}"

drt_check "Vault prod is healthy" \
  test "$VAULT_INIT" = "true" -a "$VAULT_SEALED" = "false"

# ── Pre-test ─────────────────────────────────────────────────────────

drt_step "Verifying SOPS root token against Vault"
VAULT_TOKEN=$(drt_sops_value '.vault_prod_root_token')
TOKEN_LOOKUP=$(vault_curl "-H 'X-Vault-Token: ${VAULT_TOKEN}' '${VAULT_URL}/v1/auth/token/lookup-self'" || echo "{}")
TOKEN_ERRORS=$(echo "$TOKEN_LOOKUP" | jq -r '.errors // empty')
if [[ -n "$TOKEN_ERRORS" ]]; then
  echo "  Token lookup failed: ${TOKEN_ERRORS}"
  echo "  SOPS root token may be stale (vault was reinitialized?)"
  echo "  Run init-vault.sh prod to sync SOPS with current Vault instance"
fi
TOKEN_ID=$(echo "$TOKEN_LOOKUP" | jq -r '.data.id // empty')
drt_check "SOPS root token is valid against Vault" \
  test -n "$TOKEN_ID"

# ── Test ─────────────────────────────────────────────────────────────

drt_step "Killing Vault QEMU process on ${VAULT_NODE}"
echo "  Simulating VM crash via: kill -9 \$(cat /run/qemu-server/${VAULT_VMID}.pid)"
ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
  "root@${VAULT_NODE_IP}" \
  "kill -9 \$(cat /run/qemu-server/${VAULT_VMID}.pid)"

KILL_EPOCH=$(date +%s)
echo "  QEMU process killed at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Verification ─────────────────────────────────────────────────────

drt_step "Polling Vault health (timeout 60s, target RTO 30s)"
HEALTHY=0
WAIT=0
MAX_WAIT=60
RTO_TARGET=30

while [[ $WAIT -lt $MAX_WAIT ]]; do
  sleep 2
  WAIT=$((WAIT + 2))

  POLL_JSON=$(vault_curl "'${VAULT_URL}/v1/sys/health'" || echo "{}")
  POLL_INIT=$(echo "$POLL_JSON" | jq -r 'if .initialized == null then empty else (.initialized | tostring) end')
  POLL_SEALED=$(echo "$POLL_JSON" | jq -r 'if .sealed == null then empty else (.sealed | tostring) end')

  if [[ "$POLL_INIT" == "true" && "$POLL_SEALED" == "false" ]]; then
    RECOVERY_EPOCH=$(date +%s)
    RTO=$((RECOVERY_EPOCH - KILL_EPOCH))
    HEALTHY=1
    echo "  Vault healthy after ${RTO}s (polled at +${WAIT}s)"
    break
  fi

  printf "  +%ds: init=%s sealed=%s\n" "$WAIT" "${POLL_INIT:-?}" "${POLL_SEALED:-?}"
done

if [[ $HEALTHY -eq 1 ]]; then
  echo ""
  echo "  Recovery Time: ${RTO}s"
  echo "  Baseline:      ~15s RTO (2026-03-23)"
  echo ""

  drt_assert "Vault recovered within RTO target (${RTO_TARGET}s)" \
    test "$RTO" -le "$RTO_TARGET"
else
  echo ""
  echo "  [FAIL] Vault did not become healthy within ${MAX_WAIT}s"
  RTO="TIMEOUT"
  DRT_FAILURES=$((DRT_FAILURES + 1))
  DRT_FAILURE_LIST+=("Vault failed to recover within ${MAX_WAIT}s")
fi

drt_step "Verifying Vault root token works after failover"
TOKEN_LOOKUP=$(vault_curl "-H 'X-Vault-Token: ${VAULT_TOKEN}' '${VAULT_URL}/v1/auth/token/lookup-self'" || echo "{}")
TOKEN_ID=$(echo "$TOKEN_LOOKUP" | jq -r '.data.id // empty')
drt_assert "Vault root token is valid (post-failover)" \
  test -n "$TOKEN_ID"

drt_step "Running validate.sh vault checks"
drt_assert "validate.sh passes after vault failover" framework/scripts/validate.sh

# ── Finish ───────────────────────────────────────────────────────────

drt_finish
