#!/usr/bin/env bash
# configure-gitlab.sh — Post-deploy GitLab configuration.
#
# Waits for GitLab to become accessible, retrieves the initial root password,
# creates the infrastructure project, generates a runner registration token,
# registers the operator's SSH key, pushes the repo, and writes secrets to SOPS.
#
# Usage:
#   framework/scripts/configure-gitlab.sh              # Full setup
#   framework/scripts/configure-gitlab.sh --verify     # Check configuration
#
# Idempotent: safe to re-run. Skips creation if project/token already exists.

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
for tool in yq sops curl jq ssh; do
  command -v "$tool" &>/dev/null || { echo "ERROR: $tool not found" >&2; exit 1; }
done

# --- Read config ---
GITLAB_IP=$(yq -r '.vms.gitlab.ip' "$CONFIG_FILE")
DOMAIN=$(yq -r '.domain' "$CONFIG_FILE")
GITLAB_URL="https://gitlab.prod.${DOMAIN}"
PROJECT_NAME=$(yq -r '.cicd.project_name' "$CONFIG_FILE")
if [[ -z "$PROJECT_NAME" || "$PROJECT_NAME" == "null" ]]; then
  PROJECT_NAME="infra"
fi

echo "GitLab IP:  $GITLAB_IP"
echo "GitLab URL: $GITLAB_URL"

# --- SSH helper ---
gitlab_ssh() {
  ssh -n -o StrictHostKeyChecking=accept-new "root@${GITLAB_IP}" "$@"
}

MODE="configure"
[[ "${1:-}" == "--verify" ]] && MODE="verify"

# --- Verify mode ---
if [[ "$MODE" == "verify" ]]; then
  echo ""
  echo "=== Verification ==="
  PASS=0; FAIL=0

  # 1. GitLab accessible
  echo -n "  GitLab web UI accessible: "
  if curl -sk --max-time 10 "${GITLAB_URL}/users/sign_in" 2>/dev/null | grep -q 'Sign in'; then
    echo "PASS"; ((PASS++))
  else
    echo "FAIL"; ((FAIL++))
  fi

  # 2. TLS certificate valid (Let's Encrypt)
  echo -n "  TLS certificate valid: "
  if echo | openssl s_client -connect "${GITLAB_IP}:443" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null | grep -qi "let's encrypt\|R3\|R10\|E5\|E6"; then
    echo "PASS (Let's Encrypt)"; ((PASS++))
  else
    echo "FAIL (not Let's Encrypt)"; ((FAIL++))
  fi

  # 3. SSH accessible
  echo -n "  GitLab SSH accessible: "
  if gitlab_ssh "true" 2>/dev/null; then
    echo "PASS"; ((PASS++))
  else
    echo "FAIL"; ((FAIL++))
  fi

  # 4. Project exists
  echo -n "  Infrastructure project: "
  if curl -sk --max-time 10 "${GITLAB_URL}/api/v4/projects?search=${PROJECT_NAME}" | jq -e --arg name "$PROJECT_NAME" '.[] | select(.path == $name) | .name' &>/dev/null; then
    echo "PASS (${PROJECT_NAME})"; ((PASS++))
  else
    echo "FAIL (project '${PROJECT_NAME}' not found)"; ((FAIL++))
  fi

  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

# --- Configure mode ---

# Step 1: Wait for GitLab to be accessible
echo ""
echo "=== Step 1: Wait for GitLab ==="
MAX_WAIT=600
WAITED=0
while true; do
  if curl -sk --max-time 10 "${GITLAB_URL}/users/sign_in" 2>/dev/null | grep -q 'Sign in'; then
    echo "  GitLab is up"
    break
  fi
  if [[ $WAITED -ge $MAX_WAIT ]]; then
    echo "ERROR: GitLab did not become accessible within ${MAX_WAIT}s" >&2
    exit 1
  fi
  echo "  Waiting for GitLab... (${WAITED}/${MAX_WAIT}s)"
  sleep 15
  WAITED=$((WAITED + 15))
done

# Step 2: Retrieve root password
# Priority: SOPS password is authoritative when it exists.
# Three scenarios:
#   1. SOPS matches database → use it (normal case, PBS restore)
#   2. SOPS exists but doesn't match → reset database to SOPS password
#      (VM was recreated but secrets.yaml preserved)
#   3. No SOPS entry → read initial password from VM, store in SOPS
#      (first deploy ever)
echo ""
echo "=== Step 2: Retrieve root password ==="
ROOT_PASSWORD=""
SOPS_PASSWORD=$(sops -d --extract '["gitlab_root_password"]' "$SECRETS_FILE" 2>/dev/null || true)

if [[ -n "$SOPS_PASSWORD" && "$SOPS_PASSWORD" != "null" ]]; then
  # Try the SOPS password first
  TEST_TOKEN=$(curl -sk -X POST "${GITLAB_URL}/oauth/token" \
    -d "grant_type=password&username=root&password=${SOPS_PASSWORD}" 2>/dev/null | jq -r '.access_token // empty')
  if [[ -n "$TEST_TOKEN" ]]; then
    echo "  SOPS password verified against GitLab"
    ROOT_PASSWORD="$SOPS_PASSWORD"
  else
    # SOPS has a password but it doesn't match the database.
    # This happens after --vms reset + rebuild (fresh database, preserved secrets).
    # Reset the database password to match SOPS — SOPS is authoritative.
    echo "  SOPS password does not match GitLab — resetting database password to match SOPS..."
    INIT_PASSWORD=$(gitlab_ssh "cat /var/lib/gitlab/initial_root_password 2>/dev/null" || true)
    if [[ -n "$INIT_PASSWORD" ]]; then
      # Authenticate with the initial password, then change to SOPS password
      INIT_TOKEN=$(curl -sk -X POST "${GITLAB_URL}/oauth/token" \
        -d "grant_type=password&username=root&password=${INIT_PASSWORD}" 2>/dev/null | jq -r '.access_token // empty')
      if [[ -n "$INIT_TOKEN" ]]; then
        # Change password via API
        curl -sk -X PUT "${GITLAB_URL}/api/v4/users/1" \
          -H "Authorization: Bearer ${INIT_TOKEN}" \
          -d "password=${SOPS_PASSWORD}" 2>/dev/null | jq -r '.id // empty' > /dev/null
        echo "  Database password reset to match SOPS"
        ROOT_PASSWORD="$SOPS_PASSWORD"
      else
        echo "  WARNING: Could not authenticate with initial password either"
        echo "  Falling back to initial password"
        ROOT_PASSWORD="$INIT_PASSWORD"
        echo "  Updating SOPS..."
        sops --set "[\"gitlab_root_password\"] \"${ROOT_PASSWORD}\"" "$SECRETS_FILE"
      fi
    else
      echo "ERROR: Cannot determine root password (SOPS mismatch, no initial_root_password on VM)" >&2
      exit 1
    fi
  fi
else
  # No SOPS entry — first deploy. Read from VM and store.
  INIT_PASSWORD=$(gitlab_ssh "cat /var/lib/gitlab/initial_root_password 2>/dev/null" || true)
  if [[ -z "$INIT_PASSWORD" ]]; then
    echo "ERROR: Cannot determine root password (not in SOPS or on VM)" >&2
    exit 1
  fi
  echo "  Initial root password retrieved from VM"
  ROOT_PASSWORD="$INIT_PASSWORD"
  echo "  Storing in SOPS (first-time write)..."
  sops --set "[\"gitlab_root_password\"] \"${ROOT_PASSWORD}\"" "$SECRETS_FILE"
fi

# Step 2b: Get an OAuth token (GitLab API requires a token, not the password)
echo ""
echo "=== Step 2b: Obtain API access token ==="
OAUTH_RESPONSE=$(curl -sk -X POST "${GITLAB_URL}/oauth/token" \
  -d "grant_type=password&username=root&password=${ROOT_PASSWORD}" 2>/dev/null)
ACCESS_TOKEN=$(echo "$OAUTH_RESPONSE" | jq -r '.access_token // empty')
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "ERROR: Could not obtain OAuth token. Response:" >&2
  echo "$OAUTH_RESPONSE" | jq . >&2
  exit 1
fi
echo "  OAuth access token obtained"

# Use the OAuth token for all subsequent API calls
AUTH_HEADER="Authorization: Bearer ${ACCESS_TOKEN}"

# Check version
VERSION=$(curl -sk -H "$AUTH_HEADER" "${GITLAB_URL}/api/v4/version" 2>/dev/null | jq -r '.version // empty')
echo "  GitLab version: ${VERSION:-unknown}"

# Step 3: Create infrastructure project
echo ""
echo "=== Step 3: Create infrastructure project ==="
EXISTING=$(curl -sk -H "$AUTH_HEADER" \
  "${GITLAB_URL}/api/v4/projects?search=${PROJECT_NAME}" 2>/dev/null | jq -r --arg name "$PROJECT_NAME" '.[] | select(.path == $name) | .name // empty')
if [[ "$EXISTING" == "$PROJECT_NAME" ]]; then
  echo "  Project '${PROJECT_NAME}' already exists — skipping"
else
  echo "  Creating project '${PROJECT_NAME}'..."
  curl -sk -X POST -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"${PROJECT_NAME}\", \"visibility\": \"private\", \"default_branch\": \"main\"}" \
    "${GITLAB_URL}/api/v4/projects" | jq -r '.web_url'
  echo "  Project created"
fi

# Step 4: Create runner registration token
echo ""
echo "=== Step 4: Create runner token ==="
# Check if a runner already exists
EXISTING_RUNNER=$(curl -sk -H "$AUTH_HEADER" \
  "${GITLAB_URL}/api/v4/runners/all" 2>/dev/null | jq -r '.[0].id // empty')
if [[ -n "$EXISTING_RUNNER" ]]; then
  echo "  Runner already registered (ID: ${EXISTING_RUNNER}) — skipping token creation"
else
  echo "  Creating a new runner via the API..."
  RUNNER_RESPONSE=$(curl -sk -X POST -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d '{"runner_type": "instance_type", "tag_list": ["infra", "deploy"], "description": "Infrastructure runner"}' \
    "${GITLAB_URL}/api/v4/user/runners" 2>/dev/null)

  RUNNER_TOKEN=$(echo "$RUNNER_RESPONSE" | jq -r '.token // empty')
  if [[ -z "$RUNNER_TOKEN" ]]; then
    echo "  ERROR: Could not create runner token via API. Response:" >&2
    echo "$RUNNER_RESPONSE" | jq . >&2
    echo "  register-runner.sh will fail without this token." >&2
    exit 1
  else
    echo "  Runner token obtained"
    echo "  Storing in SOPS..."
    sops --set "[\"gitlab_runner_registration_token\"] \"${RUNNER_TOKEN}\"" "$SECRETS_FILE"
    echo "  Token stored in SOPS"
  fi
fi

# Step 5: Register SSH keys for git push
# Register both the SOPS CI key (for pipeline pushes) and the operator's
# workstation key (for interactive pushes). On Level 5, these are different keys.
echo ""
echo "=== Step 5: Register SSH keys ==="

register_gitlab_key() {
  local key_value="$1" key_title="$2"
  if [[ -z "$key_value" ]]; then
    echo "  WARNING: No ${key_title} key available — skipping"
    return
  fi
  # Check if this key is already registered
  local existing
  existing=$(curl -sk -H "$AUTH_HEADER" \
    "${GITLAB_URL}/api/v4/user/keys" 2>/dev/null | jq -r --arg key "$key_value" \
    '.[] | select(.key == $key) | .title // empty')
  if [[ -n "$existing" ]]; then
    echo "  ${key_title} key already registered — skipping"
  else
    echo "  Registering ${key_title} key..."
    local response
    response=$(curl -sk -X POST -H "$AUTH_HEADER" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg key "$key_value" --arg title "$key_title" '{title: $title, key: $key}')" \
      "${GITLAB_URL}/api/v4/user/keys" 2>/dev/null)
    local kid
    kid=$(echo "$response" | jq -r '.id // empty')
    if [[ -n "$kid" ]]; then
      echo "  ${key_title} key registered (ID: ${kid})"
    else
      echo "  WARNING: Could not register ${key_title} key. Response:"
      echo "$response" | jq .
    fi
  fi
}

# SOPS CI key (for pipeline/runner git pushes)
SOPS_SSH_PUBKEY=$(sops -d --extract '["ssh_pubkey"]' "$SECRETS_FILE" 2>/dev/null || true)
register_gitlab_key "$SOPS_SSH_PUBKEY" "ci-runner"

# Operator workstation key (for interactive git pushes)
OPERATOR_PUBKEY=""
for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
  if [[ -f "$keyfile" ]]; then
    OPERATOR_PUBKEY=$(cat "$keyfile")
    break
  fi
done
register_gitlab_key "$OPERATOR_PUBKEY" "operator"

# Step 6: Push repository to GitLab
echo ""
echo "=== Step 6: Push repository to GitLab ==="
# Use SSH transport via the operator's key (avoids TLS cert issues)
if git remote get-url gitlab &>/dev/null; then
  git remote set-url gitlab "gitlab@${GITLAB_IP}:root/${PROJECT_NAME}.git"
else
  git remote add gitlab "gitlab@${GITLAB_IP}:root/${PROJECT_NAME}.git"
fi

# Accept GitLab's SSH host key for git operations (port 22)
ssh-keygen -R "$GITLAB_IP" 2>/dev/null || true
ssh-keyscan -H "$GITLAB_IP" >> ~/.ssh/known_hosts 2>/dev/null

CURRENT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
if [[ -n "$CURRENT_BRANCH" ]]; then
  echo "  Pushing branch '${CURRENT_BRANCH}' to GitLab..."
  if git -C "$REPO_DIR" push gitlab "$CURRENT_BRANCH" --force 2>&1; then
    echo "  Push successful"
  else
    echo "  ERROR: Push failed — check SSH key registration and GitLab SSH config" >&2
    exit 1
  fi
else
  echo "  WARNING: Not on a branch — skipping push"
fi

# Step 6b: Create dev and prod branches
echo ""
echo "=== Step 6b: Create branches ==="
PROJECT_ID=$(curl -sk -H "$AUTH_HEADER" \
  "${GITLAB_URL}/api/v4/projects?search=${PROJECT_NAME}" 2>/dev/null | jq -r '.[0].id')
DEFAULT_BRANCH=$(curl -sk -H "$AUTH_HEADER" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" 2>/dev/null | jq -r '.default_branch')
echo "  Project ID: ${PROJECT_ID}, default branch: ${DEFAULT_BRANCH}"

for BRANCH in dev prod; do
  BRANCH_EXISTS=$(curl -sk -H "$AUTH_HEADER" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/branches/${BRANCH}" 2>/dev/null | jq -r '.name // empty')
  if [[ "$BRANCH_EXISTS" == "$BRANCH" ]]; then
    echo "  Branch '${BRANCH}' already exists"
  else
    # Create from whatever branch has commits (dev from current, prod from dev)
    REF="${DEFAULT_BRANCH}"
    [[ "$BRANCH" == "prod" ]] && REF="dev"
    RESULT=$(curl -sk -X POST -H "$AUTH_HEADER" \
      "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/repository/branches?branch=${BRANCH}&ref=${REF}" 2>/dev/null | jq -r '.name // empty')
    if [[ "$RESULT" == "$BRANCH" ]]; then
      echo "  Created branch '${BRANCH}' from '${REF}'"
    else
      echo "  ERROR: Could not create branch '${BRANCH}'" >&2
      exit 1
    fi
  fi
done

# Step 6c: Protect prod branch (MR-only, no direct push)
echo ""
echo "=== Step 6c: Protect prod branch ==="
PROD_PROTECTED=$(curl -sk -H "$AUTH_HEADER" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/protected_branches/prod" 2>/dev/null | jq -r '.name // empty')
if [[ "$PROD_PROTECTED" == "prod" ]]; then
  echo "  Branch 'prod' already protected"
else
  curl -sk -X POST -H "$AUTH_HEADER" \
    "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/protected_branches" \
    --data "name=prod&push_access_level=0&merge_access_level=40" 2>/dev/null | jq -r '.name // empty' > /dev/null
  echo "  Branch 'prod' protected (push=no one, merge=maintainers)"
fi

# Step 6c2: Require pipeline success for merging
# Without this, the guard:control-plane CI job can fail but the MR
# can still be merged — defeating the purpose of the guard.
echo ""
echo "=== Step 6c2: Require pipeline success for merging ==="
curl -sk -X PUT -H "$AUTH_HEADER" \
  "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}" \
  --data "only_allow_merge_if_pipeline_succeeds=true" 2>/dev/null | jq -r '.only_allow_merge_if_pipeline_succeeds' > /dev/null
echo "  Merge requires passing pipeline"

# Step 6d: Create issue labels from site/gitlab.yaml
echo ""
echo "=== Step 6d: Create labels ==="
GITLAB_YAML="${REPO_DIR}/site/gitlab.yaml"
if [[ -f "$GITLAB_YAML" ]]; then
  LABEL_COUNT=$(yq '.labels | length' "$GITLAB_YAML" 2>/dev/null || echo 0)
  if [[ "$LABEL_COUNT" -gt 0 ]]; then
    for i in $(seq 0 $((LABEL_COUNT - 1))); do
      LABEL_NAME=$(yq ".labels[$i].name" "$GITLAB_YAML")
      LABEL_COLOR=$(yq ".labels[$i].color" "$GITLAB_YAML")
      LABEL_DESC=$(yq ".labels[$i].description" "$GITLAB_YAML")
      result=$(curl -sk -w "%{http_code}" -o /dev/null -X POST \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/labels" \
        -H "$AUTH_HEADER" \
        --data-urlencode "name=${LABEL_NAME}" \
        --data-urlencode "color=${LABEL_COLOR}" \
        --data-urlencode "description=${LABEL_DESC}" 2>/dev/null)
      if [[ "$result" == "201" ]]; then
        echo "  Created: ${LABEL_NAME}"
      elif [[ "$result" == "409" ]]; then
        echo "  Exists:  ${LABEL_NAME}"
      else
        echo "  Warning: ${LABEL_NAME} (HTTP ${result})"
      fi
    done
    echo "  ${LABEL_COUNT} labels processed"
  else
    echo "  No labels defined in ${GITLAB_YAML}"
  fi
else
  echo "  No site/gitlab.yaml — skipping label creation"
fi

# Step 6e: Create milestones from site/gitlab.yaml
echo ""
echo "=== Step 6e: Create milestones ==="
if [[ -f "$GITLAB_YAML" ]]; then
  MILESTONE_COUNT=$(yq '.milestones | length' "$GITLAB_YAML" 2>/dev/null || echo 0)
  if [[ "$MILESTONE_COUNT" -gt 0 ]]; then
    for i in $(seq 0 $((MILESTONE_COUNT - 1))); do
      MS_TITLE=$(yq ".milestones[$i].title" "$GITLAB_YAML")
      MS_DESC=$(yq ".milestones[$i].description" "$GITLAB_YAML")
      response=$(curl -sk -w "\n%{http_code}" -X POST \
        "${GITLAB_URL}/api/v4/projects/${PROJECT_ID}/milestones" \
        -H "$AUTH_HEADER" \
        --data-urlencode "title=${MS_TITLE}" \
        --data-urlencode "description=${MS_DESC}" 2>/dev/null)
      http_code=$(echo "$response" | tail -1)
      if [[ "$http_code" == "201" ]]; then
        echo "  Created: ${MS_TITLE}"
      elif [[ "$http_code" == "400" ]] && echo "$response" | grep -q "already"; then
        echo "  Exists:  ${MS_TITLE}"
      else
        echo "  Warning: ${MS_TITLE} (HTTP ${http_code})"
      fi
    done
    echo "  ${MILESTONE_COUNT} milestones processed"
  else
    echo "  No milestones defined in ${GITLAB_YAML}"
  fi
else
  echo "  No site/gitlab.yaml — skipping milestone creation"
fi

# Step 7: Disable telemetry and outbound data collection
echo ""
echo "=== Step 7: Disable telemetry ==="
# Service Ping (weekly usage payload to GitLab Inc.)
# Version check (phones home to check for updates)
# Product usage data (event-level data collection, new in 17.11/18.0)
# Optional metrics in service ping
TELEMETRY_RESPONSE=$(curl -sk --request PUT "${GITLAB_URL}/api/v4/application/settings" \
  -H "$AUTH_HEADER" \
  --data "usage_ping_enabled=false&version_check_enabled=false&gitlab_product_usage_data_enabled=false&include_optional_metrics_in_service_ping=false" 2>/dev/null)
TELEMETRY_CHECK=$(echo "$TELEMETRY_RESPONSE" | jq '{usage_ping_enabled, version_check_enabled, gitlab_product_usage_data_enabled, include_optional_metrics_in_service_ping}' 2>/dev/null)
echo "  Telemetry settings:"
echo "$TELEMETRY_CHECK" | sed 's/^/    /'
# Verify all are false
if echo "$TELEMETRY_CHECK" | jq -e 'to_entries | all(.value == false)' &>/dev/null; then
  echo "  All telemetry disabled."
else
  echo "  WARNING: Some telemetry settings could not be disabled." >&2
fi

# MANUAL GATEWAY STEP (not automated — gateway config is a declared non-goal):
#
# On the UniFi gateway, create a firewall rule:
#   Name: Block GitLab WAN egress
#   Action: Drop
#   Source: <gitlab-vm-ip> (GitLab VM IP, from config.yaml)
#   Destination: Any (WAN)
#   Protocol: All
#
# This prevents GitLab from reaching the internet regardless of application
# settings. GitLab does not need internet access for normal operations —
# git pushes come from the operator and CI runner (both on management network).
#
# NOTE: Do NOT apply this rule to the CI runner (<cicd-vm-ip>). The runner
# needs internet access to download nix dependencies from cache.nixos.org
# and Go modules during builds.

# Step 8: Summary
echo ""
echo "=== Configuration Complete ==="
echo ""
echo "GitLab URL:     $GITLAB_URL"
echo "Root password:  $(sops -d --extract '["gitlab_root_password"]' "$SECRETS_FILE" 2>/dev/null || echo '(check SOPS)')"
echo ""
echo "Next steps:"
echo "  1. Log into GitLab at $GITLAB_URL and change the root password"
echo "  2. Update SOPS: sops --set '[\"gitlab_root_password\"] \"<new-password>\"' site/sops/secrets.yaml"
echo "  3. Build and deploy the runner: build-image.sh site/nix/hosts/cicd.nix cicd"
echo "  4. Register the runner: framework/scripts/register-runner.sh"
