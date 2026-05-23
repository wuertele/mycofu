#!/usr/bin/env bash
# certbot-cleanup-hook.sh — DNS-01 cleanup hook for certbot.
#
# Called by certbot via --manual-cleanup-hook. Deletes the ACME challenge
# TXT record from all DNS servers via the PowerDNS HTTP API.
#
# Environment variables set by certbot:
#   CERTBOT_DOMAIN     — the domain being validated (e.g., dns1.dev.example.com)
#   CERTBOT_VALIDATION — the challenge token value
set -euo pipefail

API_KEY=$(cat /run/secrets/certbot/pdns-api-key)

# Read DNS server IPs from config (injected by nocloud-init write_files)
SERVERS_FILE="/run/secrets/certbot/pdns-api-servers"
if [ ! -f "$SERVERS_FILE" ]; then
  echo "ERROR: $SERVERS_FILE not found" >&2
  exit 1
fi

# Derive zone: strip the first label from CERTBOT_DOMAIN
ZONE="${CERTBOT_DOMAIN#*.}"

RECORD_NAME="_acme-challenge.${CERTBOT_DOMAIN}."

PAYLOAD=$(cat <<EOF
{
  "rrsets": [{
    "name": "${RECORD_NAME}",
    "type": "TXT",
    "changetype": "DELETE"
  }]
}
EOF
)

while IFS= read -r server; do
  [ -z "$server" ] && continue
  echo "Deleting TXT record on ${server}: ${RECORD_NAME}"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PATCH \
    -H "X-API-Key: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    "http://${server}:8081/api/v1/servers/localhost/zones/${ZONE}.")

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "WARNING: Failed to delete TXT record on ${server} (HTTP ${HTTP_CODE})" >&2
    # Don't exit on cleanup failure — best effort
  fi
done < "$SERVERS_FILE"
