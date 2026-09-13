#!/usr/bin/env bash
# repl-health-server.sh — Lightweight HTTP server for repl-health.sh
#
# Serves the output of repl-health.sh as JSON on an HTTP port.
# Uses socat for a minimal dependency footprint (socat is standard on Proxmox).
#
# Deployed to /usr/local/bin/repl-health-server.sh by configure-node-network.sh.
# Run as a systemd service (repl-health.service).
#
# Configuration: /etc/repl-health.conf (reads HEALTH_PORT)

set -uo pipefail

# When invoked with --handle, serve a single HTTP request on stdin/stdout
if [[ "${1:-}" == "--handle" ]]; then
  # Read the HTTP request (consume headers)
  while IFS= read -r line; do
    line=$(echo "$line" | tr -d '\r')
    [[ -z "$line" ]] && break
  done

  # Generate health JSON
  body=$(/usr/local/bin/repl-health.sh 2>/dev/null) || body='{"error": "health check failed", "healthy": false}'
  len=${#body}

  # Send HTTP response
  printf "HTTP/1.1 200 OK\r\n"
  printf "Content-Type: application/json\r\n"
  printf "Content-Length: %d\r\n" "$len"
  printf "Connection: close\r\n"
  printf "\r\n"
  printf "%s" "$body"
  exit 0
fi

# Main: start the listener
CONF_FILE="/etc/repl-health.conf"
HEALTH_PORT=9100

if [[ -f "$CONF_FILE" ]]; then
  while IFS='=' read -r key val; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    [[ "$key" == "HEALTH_PORT" ]] && HEALTH_PORT="$val"
  done < "$CONF_FILE"
fi

if ! command -v socat &>/dev/null; then
  echo "ERROR: socat is required but not installed" >&2
  echo "Install with: apt-get install -y socat" >&2
  exit 1
fi

exec socat TCP-LISTEN:"${HEALTH_PORT}",reuseaddr,fork SYSTEM:"/usr/local/bin/repl-health-server.sh --handle"
