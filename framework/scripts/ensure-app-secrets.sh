#!/usr/bin/env bash
# ensure-app-secrets.sh — Generate missing SOPS secrets for enabled applications.
#
# Checks config.yaml for enabled applications, checks SOPS for their required
# secrets, and generates any missing ones (write-once — never overwrites).
#
# Usage:
#   framework/scripts/ensure-app-secrets.sh
#
# Called by rebuild-cluster.sh before tofu apply, and can be run manually
# before any deploy to ensure application secrets exist.
#
# This handles "on-demand pre-deploy" secrets: tokens that must exist in SOPS
# before tofu apply (for CIDATA generation) but are only needed when an
# application is enabled. Unlike bootstrap-sops.sh (which runs once at initial
# setup), this runs before every deploy and generates secrets for newly
# enabled applications.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
SECRETS="${REPO_DIR}/site/sops/secrets.yaml"

# --- Find SOPS age key (same logic as tofu-wrapper.sh) ---
if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
  elif [[ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
    export SOPS_AGE_KEY_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
  else
    echo "ERROR: No SOPS age key found." >&2
    exit 1
  fi
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.yaml not found: $CONFIG" >&2
  exit 1
fi

if [[ ! -f "$SECRETS" ]]; then
  echo "ERROR: secrets.yaml not found: $SECRETS" >&2
  exit 1
fi

CHANGED=0

# --- Helper: generate a secret if it doesn't exist in SOPS ---
ensure_secret() {
  local key="$1"
  local description="$2"

  if sops -d --extract "[\"${key}\"]" "$SECRETS" &>/dev/null; then
    return 0  # already exists
  fi

  echo "  Generating ${key} (${description})..."
  local token
  token=$(openssl rand -hex 32)
  sops --set "[\"${key}\"] \"${token}\"" "$SECRETS"
  CHANGED=1
}

echo "Checking application secrets..."

# --- InfluxDB ---
if yq -e '.applications.influxdb.enabled == true' "$CONFIG" &>/dev/null; then
  ensure_secret "influxdb_admin_token" "InfluxDB admin API token"
fi

# --- Grafana ---
if yq -e '.applications.grafana.enabled == true' "$CONFIG" &>/dev/null; then
  ensure_secret "grafana_influxdb_token" "Grafana InfluxDB datasource token"
  # grafana_admin_password is also needed but may be prompted or
  # auto-generated differently — check if it exists
  ensure_secret "grafana_admin_password" "Grafana admin password"
fi

# --- Add new applications here as they're added to the catalog ---
# ensure_secret "myapp_api_key" "MyApp API key"

if [[ $CHANGED -eq 1 ]]; then
  echo "Application secrets written to SOPS."
else
  echo "  All application secrets present."
fi
