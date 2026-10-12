#!/usr/bin/env bash
# certbot-auth-hook.sh — DNS-01 auth hook for certbot.
#
# Called by certbot via --manual-auth-hook. Creates a TXT record for the
# ACME challenge on all DNS servers via the PowerDNS HTTP API.
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
# dns1.dev.example.com → dev.example.com
ZONE="${CERTBOT_DOMAIN#*.}"

RECORD_NAME="_acme-challenge.${CERTBOT_DOMAIN}."

PAYLOAD=$(cat <<EOF
{
  "rrsets": [{
    "name": "${RECORD_NAME}",
    "type": "TXT",
    "ttl": 60,
    "changetype": "REPLACE",
    "records": [{ "content": "\"${CERTBOT_VALIDATION}\"", "disabled": false }]
  }]
}
EOF
)

while IFS= read -r server; do
  [ -z "$server" ] && continue

  # Ensure the zone exists (auto-create on first use)
  ZONE_CHECK=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-API-Key: ${API_KEY}" \
    "http://${server}:8081/api/v1/servers/localhost/zones/${ZONE}.")

  if [ "$ZONE_CHECK" = "404" ]; then
    echo "Zone ${ZONE} not found on ${server}, creating it..."
    ZONE_PAYLOAD=$(cat <<ZEOF
{
  "name": "${ZONE}.",
  "kind": "Native",
  "nameservers": ["ns1.${ZONE}.", "ns2.${ZONE}."]
}
ZEOF
    )
    CREATE_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST \
      -H "X-API-Key: ${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "${ZONE_PAYLOAD}" \
      "http://${server}:8081/api/v1/servers/localhost/zones")

    if [ "$CREATE_CODE" -lt 200 ] || [ "$CREATE_CODE" -ge 300 ]; then
      echo "ERROR: Failed to create zone ${ZONE} on ${server} (HTTP ${CREATE_CODE})" >&2
      exit 1
    fi
    echo "Zone ${ZONE} created on ${server}"
  fi

  echo "Creating TXT record on ${server}: ${RECORD_NAME} = ${CERTBOT_VALIDATION}"
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X PATCH \
    -H "X-API-Key: ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    "http://${server}:8081/api/v1/servers/localhost/zones/${ZONE}.")

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "ERROR: Failed to create TXT record on ${server} (HTTP ${HTTP_CODE})" >&2
    exit 1
  fi
done < "$SERVERS_FILE"

# Brief wait for DNS propagation between independent servers
sleep 3
