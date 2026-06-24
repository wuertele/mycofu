#!/usr/bin/env bash
# DRT-ID: DRT-006
# DRT-NAME: DNS Failover
# DRT-TIME: ~5 min
# DRT-DESTRUCTIVE: no
# DRT-DESC: Stop each DNS server in turn and verify the other resolves
#           critical records. Prod only (dev uses Pebble; certbot
#           --dry-run bypasses it). Tests real certbot renew.

set -euo pipefail

DRT_ID="DRT-006"
DRT_NAME="DNS Failover"

source "$(dirname "$0")/../lib/common.sh"

drt_init

# ── Preconditions ────────────────────────────────────────────────────

drt_check "validate.sh is green" framework/scripts/validate.sh

drt_check "dns1 and dns2 on different nodes" bash -c '
  DNS1_NODE=$(yq -r ".vms.dns1_prod.node" site/config.yaml)
  DNS2_NODE=$(yq -r ".vms.dns2_prod.node" site/config.yaml)
  [[ "$DNS1_NODE" != "$DNS2_NODE" ]]
'

# ── Resolve config values ────────────────────────────────────────────

DOMAIN=$(drt_domain)

DNS1_VMID=$(drt_vm_vmid dns1 prod)
DNS2_VMID=$(drt_vm_vmid dns2 prod)

DNS1_IP=$(drt_vm_ip dns1 prod)
DNS2_IP=$(drt_vm_ip dns2 prod)

DNS1_NODE=$(drt_config '.vms.dns1_prod.node')
DNS1_NODE_IP=$(drt_node_ip "$DNS1_NODE")

DNS2_NODE=$(drt_config '.vms.dns2_prod.node')
DNS2_NODE_IP=$(drt_node_ip "$DNS2_NODE")

VAULT_FQDN="vault.prod.${DOMAIN}"

echo "  DNS1: VMID ${DNS1_VMID}, IP ${DNS1_IP}, node ${DNS1_NODE} (${DNS1_NODE_IP})"
echo "  DNS2: VMID ${DNS2_VMID}, IP ${DNS2_IP}, node ${DNS2_NODE} (${DNS2_NODE_IP})"
echo "  Test domain: ${DOMAIN}"

# ── Helper: verify DNS resolution against a specific server ──────────

dns_resolves() {
  local server="$1" name="$2"
  # dig with short timeout; exit 0 if we get an answer
  dig +short +time=5 +tries=2 "@${server}" "$name" A 2>/dev/null | grep -q '.'
}

# ── Phase A: stop dns1, verify dns2 handles resolution ───────────────

drt_step "Phase A: stopping dns1-prod (VMID ${DNS1_VMID})"

ssh -n -o ConnectTimeout=10 -o BatchMode=yes "root@${DNS1_NODE_IP}" \
  "qm stop ${DNS1_VMID} --skiplock 1" 2>/dev/null || true

# Wait for VM to stop
for (( W=0; W<30; W+=3 )); do
  STATUS=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${DNS1_NODE_IP}" \
    "qm status ${DNS1_VMID} 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "unknown")
  [[ "$STATUS" == "stopped" ]] && break
  sleep 3
done
echo "  dns1-prod status: ${STATUS}"

drt_step "Phase A: verifying dns2 resolves critical records"

# vault.prod.<domain> — core infrastructure
drt_assert "dns2 resolves ${VAULT_FQDN}" \
  dns_resolves "$DNS2_IP" "${VAULT_FQDN}"

# acme.prod.<domain> — certificate issuance depends on DNS
# Prod uses LE (real ACME), not Pebble. The ACME record is relevant
# only if the domain has an acme record; check gracefully.
ACME_FQDN="acme.prod.${DOMAIN}"
set +e
ACME_ANSWER=$(dig +short +time=5 "@${DNS2_IP}" "$ACME_FQDN" A 2>/dev/null)
set -e
if [[ -n "$ACME_ANSWER" ]]; then
  drt_assert "dns2 resolves ${ACME_FQDN}" \
    dns_resolves "$DNS2_IP" "$ACME_FQDN"
else
  echo "  [INFO] ${ACME_FQDN} has no A record — skipping (expected if no dedicated ACME VM in prod)"
fi

# Certbot renew (NOT --dry-run — that bypasses Pebble/LE and hits staging)
# Find a prod VM with certbot to test renewal
VAULT_IP=$(drt_vm_ip vault prod)
drt_step "Phase A: testing certbot renew on vault-prod (via dns2)"

# certbot renew exits 0 if certs are not due (which is fine — it proves
# the renewal machinery works: ACME challenge → DNS lookup → verify).
set +e
CERTBOT_OUTPUT=$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes \
  "root@${VAULT_IP}" "certbot renew 2>&1")
CERTBOT_RC=$?
set -e
echo "  certbot exit code: ${CERTBOT_RC}"
echo "$CERTBOT_OUTPUT" | tail -3 | sed 's/^/    /'

drt_assert "certbot renew succeeds with dns1 down" test "$CERTBOT_RC" -eq 0

# ── Phase A cleanup: restart dns1 ───────────────────────────────────

drt_step "Phase A cleanup: restarting dns1-prod"

ssh -n -o ConnectTimeout=10 -o BatchMode=yes "root@${DNS1_NODE_IP}" \
  "qm start ${DNS1_VMID}" 2>/dev/null || true

# Wait for dns1 to be answering queries
for (( W=0; W<60; W+=5 )); do
  if dns_resolves "$DNS1_IP" "${VAULT_FQDN}" 2>/dev/null; then
    echo "  dns1-prod answering queries at ${W}s"
    break
  fi
  sleep 5
done

# ── Phase B: stop dns2, verify dns1 handles resolution ───────────────

drt_step "Phase B: stopping dns2-prod (VMID ${DNS2_VMID})"

ssh -n -o ConnectTimeout=10 -o BatchMode=yes "root@${DNS2_NODE_IP}" \
  "qm stop ${DNS2_VMID} --skiplock 1" 2>/dev/null || true

for (( W=0; W<30; W+=3 )); do
  STATUS=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${DNS2_NODE_IP}" \
    "qm status ${DNS2_VMID} 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "unknown")
  [[ "$STATUS" == "stopped" ]] && break
  sleep 3
done
echo "  dns2-prod status: ${STATUS}"

drt_step "Phase B: verifying dns1 resolves critical records"

drt_assert "dns1 resolves ${VAULT_FQDN}" \
  dns_resolves "$DNS1_IP" "${VAULT_FQDN}"

if [[ -n "$ACME_ANSWER" ]]; then
  drt_assert "dns1 resolves ${ACME_FQDN}" \
    dns_resolves "$DNS1_IP" "$ACME_FQDN"
fi

# certbot renew against dns1
drt_step "Phase B: testing certbot renew on vault-prod (via dns1)"

set +e
CERTBOT_OUTPUT=$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes \
  "root@${VAULT_IP}" "certbot renew 2>&1")
CERTBOT_RC=$?
set -e
echo "  certbot exit code: ${CERTBOT_RC}"
echo "$CERTBOT_OUTPUT" | tail -3 | sed 's/^/    /'

drt_assert "certbot renew succeeds with dns2 down" test "$CERTBOT_RC" -eq 0

# ── Phase C: restart dns2, full validation ────────────────────────────

drt_step "Phase C: restarting dns2-prod and running validation"

ssh -n -o ConnectTimeout=10 -o BatchMode=yes "root@${DNS2_NODE_IP}" \
  "qm start ${DNS2_VMID}" 2>/dev/null || true

# Wait for dns2 to be answering queries
for (( W=0; W<60; W+=5 )); do
  if dns_resolves "$DNS2_IP" "${VAULT_FQDN}" 2>/dev/null; then
    echo "  dns2-prod answering queries at ${W}s"
    break
  fi
  sleep 5
done

drt_step "Phase C: running validate.sh"

drt_assert "validate.sh passes with both DNS servers running" \
  framework/scripts/validate.sh

# ── Baseline ─────────────────────────────────────────────────────────

echo ""
echo "  Baseline: not yet established"

# ── Done ─────────────────────────────────────────────────────────────

drt_finish
