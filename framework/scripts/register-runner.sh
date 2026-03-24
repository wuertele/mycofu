#!/usr/bin/env bash
# register-runner.sh — Register the GitLab Runner with GitLab.
#
# Reads the runner token from SOPS, SSHs to the runner VM, and registers
# with GitLab. Verifies the runner appears online.
#
# Usage:
#   framework/scripts/register-runner.sh
#   framework/scripts/register-runner.sh --verify
#
# Idempotent: skips registration if runner is already configured.

set -euo pipefail

# --- Locate repo root ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2; exit 1
}

REPO_DIR="$(find_repo_root)"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"

# --- Check prerequisites ---
for tool in yq sops ssh curl jq; do
  command -v "$tool" &>/dev/null || { echo "ERROR: $tool not found" >&2; exit 1; }
done

# --- Read config ---
CICD_IP=$(yq -r '.vms.cicd.ip' "$CONFIG_FILE")
GITLAB_IP=$(yq -r '.vms.gitlab.ip' "$CONFIG_FILE")
BASE_DOMAIN=$(yq -r '.domain' "$CONFIG_FILE")
GITLAB_URL="https://gitlab.prod.${BASE_DOMAIN}"

echo "Runner IP:  $CICD_IP"
echo "GitLab URL: $GITLAB_URL"

# --- SSH helper ---
runner_ssh() {
  ssh -n -o StrictHostKeyChecking=accept-new "root@${CICD_IP}" "$@"
}

MODE="register"
[[ "${1:-}" == "--verify" ]] && MODE="verify"

if [[ "$MODE" == "verify" ]]; then
  echo ""
  echo "=== Verification ==="
  PASS=0; FAIL=0

  # 1. Runner VM accessible
  echo -n "  Runner SSH accessible: "
  if runner_ssh "true" 2>/dev/null; then
    echo "PASS"; ((PASS++))
  else
    echo "FAIL"; ((FAIL++))
  fi

  # 2. Runner registered
  echo -n "  Runner config exists:  "
  if runner_ssh "test -f /etc/gitlab-runner/config.toml" 2>/dev/null; then
    echo "PASS"; ((PASS++))
  else
    echo "FAIL"; ((FAIL++))
  fi

  # 3. Runner service running
  echo -n "  Runner service active: "
  if runner_ssh "systemctl is-active gitlab-runner" 2>/dev/null | grep -q active; then
    echo "PASS"; ((PASS++))
  else
    echo "FAIL"; ((FAIL++))
  fi

  # 4. Tools available
  echo -n "  Build tools present:   "
  if runner_ssh "nix --version && tofu version && sops --version" &>/dev/null; then
    echo "PASS"; ((PASS++))
  else
    echo "FAIL"; ((FAIL++))
  fi

  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

# --- Register mode ---

# --- GitLab API helper ---
gitlab_api_token() {
  local root_pw
  root_pw=$(sops -d --extract '["gitlab_root_password"]' "$SECRETS_FILE" 2>/dev/null || true)
  [[ -z "$root_pw" ]] && return 1
  curl -sk -X POST "${GITLAB_URL}/oauth/token" \
    -d "grant_type=password&username=root&password=${root_pw}" 2>/dev/null \
    | jq -r '.access_token // empty'
}

# Read runner token from SOPS
RUNNER_TOKEN=$(sops -d --extract '["gitlab_runner_registration_token"]' "$SECRETS_FILE" 2>/dev/null || true)
if [[ -z "$RUNNER_TOKEN" ]]; then
  echo "ERROR: No runner registration token in SOPS" >&2
  echo "Run configure-gitlab.sh first to generate the token." >&2
  exit 1
fi

# Check if already registered
echo ""
echo "=== Step 1: Check registration ==="
if runner_ssh "test -f /etc/gitlab-runner/config.toml && grep -q token /etc/gitlab-runner/config.toml" 2>/dev/null; then
  echo "  Runner already registered — skipping"
else
  echo "  Registering runner..."

  # Extract GitLab CA cert (needed for staging LE / Pebble certs).
  # Use the IP directly — DNS may not be ready on a freshly rebuilt runner.
  echo "  Extracting GitLab CA cert..."
  runner_ssh "mkdir -p /etc/gitlab-runner && \
    echo | openssl s_client -connect ${GITLAB_IP}:443 -showcerts 2>/dev/null | \
    awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > /etc/gitlab-runner/gitlab-ca.pem" 2>/dev/null || true

  # Verify the cert was actually extracted
  if ! runner_ssh "test -s /etc/gitlab-runner/gitlab-ca.pem" 2>/dev/null; then
    echo "ERROR: Failed to extract GitLab CA certificate" >&2
    echo "GitLab may not be accessible from the runner at ${GITLAB_IP}:443" >&2
    exit 1
  fi
  echo "  CA cert extracted"

  # Build registration command helper
  build_register_cmd() {
    local token="$1"
    echo "GITLAB_RUNNER=\$(which gitlab-runner 2>/dev/null || find /nix/store -maxdepth 3 -name gitlab-runner -type f 2>/dev/null | head -1) && \
      \$GITLAB_RUNNER register \
      --non-interactive \
      --url '${GITLAB_URL}' \
      --token '${token}' \
      --executor shell \
      --tls-ca-file /etc/gitlab-runner/gitlab-ca.pem"
  }

  REGISTER_OUTPUT=$(runner_ssh "$(build_register_cmd "$RUNNER_TOKEN")" 2>&1) || true
  echo "$REGISTER_OUTPUT"

  if echo "$REGISTER_OUTPUT" | grep -q "is valid"; then
    : # Success — fall through to "Runner registered"
  elif echo "$REGISTER_OUTPUT" | grep -q "is not valid"; then
    # Token rejected by GitLab — stale token (PBS restore or already consumed).
    # Delete stale runners, create fresh registration, retry.
    echo "  SOPS token rejected by GitLab — recovering..."
    ACCESS_TOKEN=$(gitlab_api_token)
    if [[ -z "$ACCESS_TOKEN" ]]; then
      echo "ERROR: Cannot authenticate to GitLab API for runner recovery" >&2
      exit 1
    fi

    # Delete all existing runners (stale from PBS restore)
    STALE_IDS=$(curl -sk -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "${GITLAB_URL}/api/v4/runners/all" 2>/dev/null | jq -r '.[].id')
    for rid in $STALE_IDS; do
      echo "  Deleting stale runner ID ${rid}..."
      curl -sk -X DELETE -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "${GITLAB_URL}/api/v4/runners/${rid}" 2>/dev/null
    done

    # Create a fresh runner registration token
    echo "  Creating fresh runner registration..."
    RUNNER_RESPONSE=$(curl -sk -X POST \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -d '{"runner_type": "instance_type", "tag_list": ["infra", "deploy"], "description": "Infrastructure runner"}' \
      "${GITLAB_URL}/api/v4/user/runners" 2>/dev/null)
    RUNNER_TOKEN=$(echo "$RUNNER_RESPONSE" | jq -r '.token // empty')
    if [[ -z "$RUNNER_TOKEN" ]]; then
      echo "ERROR: Failed to create runner. Response:" >&2
      echo "$RUNNER_RESPONSE" | jq . >&2
      exit 1
    fi

    # Update SOPS with the new token
    sops --set "[\"gitlab_runner_registration_token\"] \"${RUNNER_TOKEN}\"" "$SECRETS_FILE"
    echo "  Fresh token stored in SOPS"

    # Retry registration with the new token
    if ! runner_ssh "$(build_register_cmd "$RUNNER_TOKEN")" 2>&1; then
      echo "ERROR: Registration failed even with fresh token" >&2
      exit 1
    fi
  else
    # Unknown failure (not a token issue)
    echo "ERROR: Runner registration failed unexpectedly" >&2
    echo "$REGISTER_OUTPUT" >&2
    exit 1
  fi
  echo "  Runner registered"
fi

# Ensure the runner trusts GitLab's TLS certificate.
# With LE staging certs (or any non-standard CA), the runner needs
# the CA cert to verify the connection for ongoing job polling.
echo ""
echo "=== Step 1b: Configure TLS trust ==="
runner_ssh "echo | openssl s_client -connect ${GITLAB_IP}:443 -showcerts 2>/dev/null | \
  awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > /etc/gitlab-runner/gitlab-ca.pem"
if runner_ssh "test -s /etc/gitlab-runner/gitlab-ca.pem" 2>/dev/null; then
  # Add tls-ca-file to config.toml if not already present
  if ! runner_ssh "grep -q 'tls-ca-file' /etc/gitlab-runner/config.toml" 2>/dev/null; then
    runner_ssh "sed -i '/^\[\[runners\]\]/a\\  tls-ca-file = \"/etc/gitlab-runner/gitlab-ca.pem\"' /etc/gitlab-runner/config.toml"
  fi
  echo "  GitLab CA cert configured for runner"
else
  echo "  WARNING: Could not extract GitLab CA cert"
fi

# Start/restart the runner service
echo ""
echo "=== Step 2: Start runner service ==="
runner_ssh "systemctl restart gitlab-runner" 2>/dev/null || true
sleep 2

if runner_ssh "systemctl is-active gitlab-runner" 2>/dev/null | grep -q active; then
  echo "  Runner service is active"
else
  echo "  WARNING: Runner service is not active"
  runner_ssh "journalctl -u gitlab-runner --no-pager -n 20" 2>/dev/null || true
fi

# Verify runner is online in GitLab
echo ""
echo "=== Step 3: Verify runner in GitLab ==="
ROOT_PASSWORD=$(sops -d --extract '["gitlab_root_password"]' "$SECRETS_FILE" 2>/dev/null || true)
if [[ -n "$ROOT_PASSWORD" ]]; then
  # Obtain OAuth token (GitLab API requires token auth, not raw password)
  OAUTH_RESPONSE=$(curl -sk -X POST "${GITLAB_URL}/oauth/token" \
    -d "grant_type=password&username=root&password=${ROOT_PASSWORD}" 2>/dev/null)
  ACCESS_TOKEN=$(echo "$OAUTH_RESPONSE" | jq -r '.access_token // empty')
  if [[ -n "$ACCESS_TOKEN" ]]; then
    RUNNERS=$(curl -sk -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "${GITLAB_URL}/api/v4/runners/all" 2>/dev/null)
    ONLINE=$(echo "$RUNNERS" | jq -r '[.[] | select(.status == "online")] | length')
    echo "  Online runners: $ONLINE"
    echo "$RUNNERS" | jq -r '.[] | "  - ID: \(.id), Status: \(.status), Tags: \(.tag_list // [] | join(","))"'
  else
    echo "  Cannot verify (OAuth token request failed)"
  fi
else
  echo "  Cannot verify (no root password in SOPS)"
fi

echo ""
echo "=== Registration Complete ==="
