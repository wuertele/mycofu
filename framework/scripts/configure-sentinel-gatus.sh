#!/usr/bin/env bash
# configure-sentinel-gatus.sh — Deploy sentinel Gatus on the NAS (Docker).
#
# Usage: configure-sentinel-gatus.sh
#
# Reads config.yaml for NAS SSH credentials and generates a minimal Gatus
# config that monitors the primary Gatus and critical cluster endpoints.
# Uses direct IPs (not DNS) — must work when cluster DNS is down.

set -euo pipefail

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
CONFIG="${REPO_DIR}/site/config.yaml"

NAS_IP=$(yq -r '.nas.ip' "$CONFIG")
NAS_USER=$(yq -r '.nas.ssh_user' "$CONFIG")
GATUS_IP=$(yq -r '.vms.gatus.ip' "$CONFIG")
DNS1_IP=$(yq -r '.vms.dns1_prod.ip' "$CONFIG")
DNS2_IP=$(yq -r '.vms.dns2_prod.ip' "$CONFIG")
DNS_DOMAIN="prod.$(yq -r '.domain' "$CONFIG")"

SMTP_HOST=$(yq -r '.email.smtp_host' "$CONFIG")
SMTP_PORT=$(yq -r '.email.smtp_port' "$CONFIG")
EMAIL_FROM="gatus@$(yq -r '.domain' "$CONFIG")"
EMAIL_TO=$(yq -r '.email.to' "$CONFIG")

# Read first node IP for Proxmox API check
NODE1_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")

echo "Deploying sentinel Gatus to NAS at ${NAS_IP}..."

# Generate sentinel config
SENTINEL_CONFIG=$(cat <<EOF
# Sentinel Gatus — minimal watchdog on NAS.
# Monitors the primary Gatus and critical cluster endpoints.
# Uses direct IPs, not DNS. Must work when cluster DNS is down.

alerting:
  email:
    from: "${EMAIL_FROM}"
    host: "${SMTP_HOST}"
    port: ${SMTP_PORT}
    to: "${EMAIL_TO}"
    default-alert:
      enabled: true
      send-on-resolved: true
      failure-threshold: 3
      success-threshold: 2

endpoints:
  - name: primary-gatus
    group: cluster
    url: "http://${GATUS_IP}:8080/api/v1/endpoints/statuses"
    conditions:
      - "[STATUS] == 200"
    interval: 30s
    alerts:
      - type: email

  - name: proxmox-api
    group: cluster
    url: "https://${NODE1_IP}:8006"
    client:
      insecure: true
    conditions:
      - "[STATUS] < 500"
    interval: 30s
    alerts:
      - type: email

  - name: dns1-prod
    group: dns
    url: "${DNS1_IP}"
    dns:
      query-name: "dns1.${DNS_DOMAIN}"
      query-type: "A"
    conditions:
      - "[DNS_RCODE] == NOERROR"
    interval: 30s
    alerts:
      - type: email

  - name: dns2-prod
    group: dns
    url: "${DNS2_IP}"
    dns:
      query-name: "dns1.${DNS_DOMAIN}"
      query-type: "A"
    conditions:
      - "[DNS_RCODE] == NOERROR"
    interval: 30s
    alerts:
      - type: email
EOF
)

# Create config directory on NAS
ssh -n "${NAS_USER}@${NAS_IP}" "mkdir -p /volume1/docker/gatus-sentinel"

# Write config to NAS
echo "$SENTINEL_CONFIG" | ssh "${NAS_USER}@${NAS_IP}" "cat > /volume1/docker/gatus-sentinel/config.yaml"

# Stop existing container if running
ssh -n "${NAS_USER}@${NAS_IP}" "/usr/local/bin/docker stop gatus-sentinel 2>/dev/null || true"
ssh -n "${NAS_USER}@${NAS_IP}" "/usr/local/bin/docker rm gatus-sentinel 2>/dev/null || true"

# Start sentinel container
ssh -n "${NAS_USER}@${NAS_IP}" "/usr/local/bin/docker run -d \
  --name gatus-sentinel \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /volume1/docker/gatus-sentinel/config.yaml:/config/config.yaml:ro \
  twinproduction/gatus:latest"

# --- Deploy placement watchdog ---
echo ""
echo "Deploying placement watchdog to NAS..."

# Copy scripts and config needed for drift detection
ssh -n "${NAS_USER}@${NAS_IP}" "mkdir -p /volume1/docker/placement-watchdog"
scp -O -q "${REPO_DIR}/framework/scripts/placement-watchdog.sh" "${NAS_USER}@${NAS_IP}:/volume1/docker/placement-watchdog/"
scp -O -q "${REPO_DIR}/framework/scripts/rebalance-cluster.sh" "${NAS_USER}@${NAS_IP}:/volume1/docker/placement-watchdog/"

# Convert config.yaml + applications.yaml to merged JSON for the NAS (NAS has jq but not yq).
# The NAS scripts use cfg_query() which reads from this merged JSON.
# Applications live in a separate file but the NAS scripts expect a single combined view.
APPS_YAML="${REPO_DIR}/site/applications.yaml"
CONFIG_JSON=$(yq -o json "${REPO_DIR}/site/config.yaml")
if [[ -f "$APPS_YAML" ]]; then
  APPS_JSON=$(yq -o json '.applications // {}' "$APPS_YAML")
else
  APPS_JSON='{}'
fi
echo "$CONFIG_JSON" "$APPS_JSON" | jq -s '(.[0] | del(.applications)) + {applications: .[1]}' | \
  ssh "${NAS_USER}@${NAS_IP}" "cat > /volume1/docker/placement-watchdog/config.json"

# Make scripts executable on NAS
ssh -n "${NAS_USER}@${NAS_IP}" "chmod +x /volume1/docker/placement-watchdog/*.sh"

# Set up the health server (runs as a background process)
# Kill existing instance and wait for port to free up
ssh -n "${NAS_USER}@${NAS_IP}" "
  # Kill any process holding port 9200 (old or new health server)
  PORT_PID=\$(netstat -tlnp 2>/dev/null | grep ':9200 ' | awk '{print \$7}' | cut -d/ -f1)
  if [ -n \"\$PORT_PID\" ]; then
    kill \$PORT_PID 2>/dev/null || true
    sleep 2
  fi
  # Also kill by name pattern in case it's not yet listening
  pkill -f 'placement-watchdog.sh --health-server' 2>/dev/null || true
  # Wait for port to free
  for i in 1 2 3 4 5; do
    if ! netstat -tlnp 2>/dev/null | grep -q ':9200 '; then
      break
    fi
    sleep 1
  done
" || true

# Start health server (port 9200)
ssh -n "${NAS_USER}@${NAS_IP}" "
  export WATCHDOG_CONFIG_DIR=/volume1/docker/placement-watchdog
  nohup /volume1/docker/placement-watchdog/placement-watchdog.sh --health-server 9200 \
    >> /var/log/placement-watchdog.log 2>&1 &
" || true

# Set up periodic watchdog via Synology Task Scheduler (cron)
# Add crontab entry if not already present
CRON_CMD="WATCHDOG_CONFIG_DIR=/volume1/docker/placement-watchdog /volume1/docker/placement-watchdog/placement-watchdog.sh"
ssh -n "${NAS_USER}@${NAS_IP}" "
  if ! crontab -l 2>/dev/null | grep -qF 'placement-watchdog.sh'; then
    (crontab -l 2>/dev/null; echo '*/5 * * * * ${CRON_CMD} >> /var/log/placement-watchdog.log 2>&1') | crontab -
    echo 'Added placement-watchdog to crontab (every 5 minutes)'
  else
    echo 'Placement watchdog cron entry already exists'
  fi
"

echo ""
echo "Sentinel Gatus deployed to NAS at ${NAS_IP}:8080"
echo "Placement watchdog health endpoint at ${NAS_IP}:9200"
echo "Verify: ssh ${NAS_USER}@${NAS_IP} docker logs gatus-sentinel --tail 20"
echo "Verify watchdog: curl -s http://${NAS_IP}:9200/ | python3 -m json.tool"
