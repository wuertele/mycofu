#!/usr/bin/env bash
# configure-dashboard-tokens.sh — Provision dashboard read-only API tokens and sync them to Vault.
#
# Usage:
#   framework/scripts/configure-dashboard-tokens.sh <prod|dev>

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
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"
SETUP_JSON="${REPO_DIR}/site/apps/influxdb/setup.json"

if [[ $# -ne 1 ]] || [[ "$1" != "prod" && "$1" != "dev" ]]; then
  echo "Usage: $0 <prod|dev>" >&2
  exit 1
fi
ENV="$1"

for tool in curl jq sops yq ssh; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: $tool" >&2
    exit 1
  fi
done

FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG_FILE")
VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG_FILE")
INFLUX_IP=$(yq -r ".applications.influxdb.environments.${ENV}.ip" "$APPS_CONFIG")
INFLUX_ORG=$(jq -r '.org' "$SETUP_JSON")
INFLUX_BUCKET=$(jq -r '.bucket' "$SETUP_JSON")
INFLUX_ADMIN_TOKEN=$(sops -d --extract '["influxdb_admin_token"]' "$SECRETS_FILE")

if [[ -n "${VAULT_ROOT_TOKEN:-}" ]]; then
  ROOT_TOKEN="$VAULT_ROOT_TOKEN"
else
  ROOT_TOKEN=$(sops -d --extract "[\"vault_${ENV}_root_token\"]" "$SECRETS_FILE")
fi

if [[ -z "$INFLUX_IP" || "$INFLUX_IP" == "null" ]]; then
  echo "ERROR: applications.influxdb.environments.${ENV}.ip is not configured" >&2
  exit 1
fi

VAULT_ADDR="https://${VAULT_IP}:8200"
SSH_OPTS="-n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

vault_api() {
  local method="$1"
  local path="$2"
  shift 2
  curl -sk -H "X-Vault-Token: ${ROOT_TOKEN}" -X "$method" "${VAULT_ADDR}/v1/${path}" "$@"
}

pve_ssh() {
  local remote_cmd="$1"
  ssh ${SSH_OPTS} "root@${FIRST_NODE_IP}" "${remote_cmd}"
}

vault_kv_read_value() {
  local path="$1"
  local key="$2"
  set +e
  local response
  response=$(vault_api GET "$path" 2>/dev/null)
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    return 1
  fi
  printf '%s' "$response" | jq -r --arg key "$key" '.data.data[$key] // empty'
}

vault_kv_write_value() {
  local path="$1"
  local key="$2"
  local value="$3"
  vault_api POST "$path" -d "$(jq -n --arg key "$key" --arg value "$value" '{data: {($key): $value}}')" >/dev/null
}

ensure_proxmox_token() {
  local user="dashboard-${ENV}@pve"
  local token_name="cluster-dashboard"
  local vault_path="secret/data/dashboard/${ENV}/proxmox-api-token"

  # Parse pveum output locally — Proxmox nodes do not have jq installed
  if ! pve_ssh "pveum user list --output-format json" | jq -e ".[] | select(.userid == \"${user}\")" >/dev/null 2>&1; then
    pve_ssh "pveum user add ${user} --comment 'Cluster dashboard ${ENV} read-only user'"
  fi

  # Trade-off: Proxmox ACLs are scoped to inventory objects, not individual
  # HTTP routes. Keep the token read-only with PVEAuditor, then let nginx's
  # explicit route allowlist enforce the dashboard's narrower API surface.
  pve_ssh "pveum aclmod / --users ${user} --roles PVEAuditor >/dev/null 2>&1 || pveum aclmod / --users ${user} --roles PVEAuditor"

  local vault_value=""
  local token_exists=0

  vault_value="$(vault_kv_read_value "${vault_path}" value || true)"
  # Parse pveum output locally — Proxmox nodes do not have jq installed
  if pve_ssh "pveum user token list ${user} --output-format json" | jq -e ".[] | select(.tokenid == \"${token_name}\")" >/dev/null 2>&1; then
    token_exists=1
  fi

  if [[ -n "$vault_value" && "$token_exists" -eq 1 ]]; then
    echo "Proxmox dashboard token (${ENV}) already present in Vault and Proxmox"
    return
  fi

  if [[ "$token_exists" -eq 1 ]]; then
    pve_ssh "pveum user token remove ${user} ${token_name}"
  fi

  local token_json
  token_json="$(pve_ssh "pveum user token add ${user} ${token_name} --privsep 0 --output-format json")"
  local secret
  secret="$(printf '%s' "$token_json" | jq -r '.value')"
  if [[ -z "$secret" || "$secret" == "null" ]]; then
    echo "ERROR: Failed to create Proxmox token secret" >&2
    exit 1
  fi

  vault_kv_write_value "${vault_path}" value "PVEAPIToken=${user}!${token_name}=${secret}"
  echo "Proxmox dashboard token (${ENV}) written to Vault"
}

ensure_influxdb_token() {
  local description="cluster-dashboard-${ENV}"
  local vault_path="secret/data/dashboard/${ENV}/influxdb-token"

  local existing_vault_token=""
  existing_vault_token="$(vault_kv_read_value "${vault_path}" value || true)"

  local org_id
  org_id="$(curl -sk "https://${INFLUX_IP}:8086/api/v2/orgs?org=${INFLUX_ORG}" \
    -H "Authorization: Token ${INFLUX_ADMIN_TOKEN}" \
    | jq -r '.orgs[0].id // empty')"
  local bucket_id
  bucket_id="$(curl -sk "https://${INFLUX_IP}:8086/api/v2/buckets?name=${INFLUX_BUCKET}" \
    -H "Authorization: Token ${INFLUX_ADMIN_TOKEN}" \
    | jq -r --arg org_id "$org_id" '.buckets[] | select(.orgID == $org_id) | .id' | head -1)"

  if [[ -z "$org_id" || -z "$bucket_id" ]]; then
    echo "ERROR: Unable to resolve InfluxDB org/bucket IDs for dashboard token" >&2
    exit 1
  fi

  local auth_list auth_id=""
  auth_list="$(curl -sk "https://${INFLUX_IP}:8086/api/v2/authorizations?orgID=${org_id}" \
    -H "Authorization: Token ${INFLUX_ADMIN_TOKEN}")"
  auth_id="$(printf '%s' "$auth_list" | jq -r --arg desc "$description" '.authorizations[] | select(.description == $desc) | .id' | head -1)"

  if [[ -n "$existing_vault_token" && -n "$auth_id" ]]; then
    echo "InfluxDB dashboard token (${ENV}) already present in Vault and InfluxDB"
    return
  fi

  if [[ -n "$auth_id" ]]; then
    curl -sk -X DELETE "https://${INFLUX_IP}:8086/api/v2/authorizations/${auth_id}" \
      -H "Authorization: Token ${INFLUX_ADMIN_TOKEN}" >/dev/null
  fi

  local create_payload
  # InfluxDB 2.x authorization permissions use resource types like "buckets",
  # "orgs", etc. — not "query" or "authorizations" (those are invalid).
  # Read on a specific bucket is sufficient for dashboard Flux queries.
  create_payload="$(jq -n \
    --arg desc "$description" \
    --arg org_id "$org_id" \
    --arg bucket_id "$bucket_id" \
    '{
      description: $desc,
      orgID: $org_id,
      permissions: [
        { action: "read", resource: { type: "buckets", id: $bucket_id, orgID: $org_id } }
      ]
    }')"

  local created_auth
  created_auth="$(curl -sk -X POST "https://${INFLUX_IP}:8086/api/v2/authorizations" \
    -H "Authorization: Token ${INFLUX_ADMIN_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$create_payload")"

  local token
  token="$(printf '%s' "$created_auth" | jq -r '.token // empty')"
  if [[ -z "$token" ]]; then
    echo "ERROR: Failed to create InfluxDB dashboard token" >&2
    exit 1
  fi

  vault_kv_write_value "${vault_path}" value "$token"
  echo "InfluxDB dashboard token (${ENV}) written to Vault"
}

wait_for_influxdb() {
  local waited=0
  while true; do
    if curl -sk "https://${INFLUX_IP}:8086/health" | jq -e '.status == "pass"' >/dev/null 2>&1; then
      return 0
    fi
    if [[ $waited -ge 300 ]]; then
      echo "ERROR: InfluxDB ${ENV} did not become healthy on :8086 within 300s" >&2
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

echo "Configuring dashboard tokens for ${ENV}"
ensure_proxmox_token
wait_for_influxdb
ensure_influxdb_token
echo "Dashboard token provisioning complete for ${ENV}"
