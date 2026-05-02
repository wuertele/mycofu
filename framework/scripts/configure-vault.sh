#!/usr/bin/env bash
# configure-vault.sh — Load Vault policies and enable KV-v2 secrets engine.
#
# Usage: framework/scripts/configure-vault.sh <prod|dev> [--app <name>] [--dry-run]
#
# Run after init-vault.sh. Configures:
#   - KV-v2 secrets engines at secret/ and mycofu/
#   - Policies from framework/vault/policies/
#
# Cert auth is NOT configured here (deferred — Vault cert auth is
# incompatible with ACME-issued certificates due to empty CN).
#
# Idempotent: checks before enabling/creating, safe to re-run.

set -euo pipefail

# --- Locate repo root ---
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
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"
export VAULT_REQUIREMENTS_REPO_DIR="${REPO_DIR}"
source "${REPO_DIR}/framework/scripts/vault-requirements-lib.sh"

# --- Parse arguments ---
if [[ $# -lt 1 ]] || [[ "$1" != "prod" && "$1" != "dev" ]]; then
  echo "Usage: $0 <prod|dev> [--app <name>] [--dry-run]" >&2
  exit 1
fi
ENV="$1"
shift
TARGET_APP=""
AUTO_COMMIT=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      TARGET_APP="${2:-}"
      [[ -n "$TARGET_APP" ]] || {
        echo "ERROR: --app requires an application name" >&2
        exit 1
      }
      AUTO_COMMIT=0
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      AUTO_COMMIT=0
      shift
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      echo "Usage: $0 <prod|dev> [--app <name>] [--dry-run]" >&2
      exit 1
      ;;
  esac
done

# Validate --app target has a vault-requirements manifest (catalog or fixed-role)
if [[ -n "$TARGET_APP" ]] && ! vault_requirements_manifest_path "$TARGET_APP" >/dev/null 2>&1; then
  echo "ERROR: '${TARGET_APP}' has no vault-requirements.yaml manifest" >&2
  echo "Expected at: $(catalog_app_manifest_path "$TARGET_APP")" >&2
  echo "         or: $(fixed_role_manifest_path "$TARGET_APP")" >&2
  exit 1
fi

# --- Check prerequisites ---
REQUIRED_TOOLS="yq"
if [[ "$DRY_RUN" -eq 0 ]]; then
  REQUIRED_TOOLS="sops yq jq curl"
fi

for tool in $REQUIRED_TOOLS; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: Required tool not found: $tool" >&2
    exit 1
  fi
done

# --- Read config ---
VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG_FILE")
if [[ -z "$VAULT_IP" || "$VAULT_IP" == "null" ]]; then
  echo "ERROR: No vault_${ENV} IP found in config.yaml" >&2
  exit 1
fi
DOMAIN=$(yq -r '.domain' "$CONFIG_FILE")
if [[ -z "$DOMAIN" || "$DOMAIN" == "null" ]]; then
  echo "ERROR: No domain found in config.yaml" >&2
  exit 1
fi
VAULT_ADDR="https://${VAULT_IP}:8200"

vm_key_fqdn() {
  local vm_key="$1"
  local host_name env_name

  case "$vm_key" in
    *_prod)
      host_name="${vm_key%_prod}"
      env_name="prod"
      ;;
    *_dev)
      host_name="${vm_key%_dev}"
      env_name="dev"
      ;;
    gatus|gitlab)
      host_name="${vm_key}"
      env_name="prod"
      ;;
    *)
      host_name="${vm_key}"
      env_name="${ENV}"
      ;;
  esac

  printf '%s.%s.%s\n' "${host_name}" "${env_name}" "${DOMAIN}"
}

cert_storage_policy_name_for_vm_key() {
  local vm_key="$1"
  printf '%s-cert-storage-policy\n' "${vm_key}"
}

vm_key_has_cert_storage() {
  local base_role
  base_role="$(echo "$1" | sed 's/_prod$//;s/_dev$//')"
  case "$base_role" in
    dns1|dns2|gatus|gitlab|testapp|influxdb|grafana|workstation)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

cert_storage_policy_content_for_vm_key() {
  local vm_key="$1"
  local fqdn
  fqdn="$(vm_key_fqdn "$vm_key")"

  cat <<EOF
path "mycofu/data/certs/${fqdn}" {
  capabilities = ["create", "update", "read"]
}
path "mycofu/metadata/certs/${fqdn}" {
  capabilities = ["create", "update", "read"]
}
EOF
}

build_approle_vm_list() {
  local roles=""
  local app=""
  local manifest_roles=""
  local role_name=""
  local role_policy=""
  local sops_role_key=""
  local sops_secret_key=""

  if [[ -n "$TARGET_APP" ]]; then
    manifest_roles="$(list_manifest_approles "$TARGET_APP" "$ENV")" || return 1
    while IFS=$'\t' read -r role_name role_policy sops_role_key sops_secret_key; do
      [[ -z "$role_name" ]] && continue
      case " ${roles} " in
        *" ${role_name} "*) continue ;;
      esac
      roles="${roles} ${role_name}"
    done <<< "$manifest_roles"
    printf '%s\n' "${roles# }"
    return 0
  fi

  case "$ENV" in
    prod) roles="dns1_prod dns2_prod gatus gitlab cicd influxdb_prod testapp_prod" ;;
    dev)  roles="dns1_dev dns2_dev influxdb_dev testapp_dev" ;;
  esac

  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    manifest_roles="$(list_manifest_approles "$app" "$ENV")" || return 1
    while IFS=$'\t' read -r role_name role_policy sops_role_key sops_secret_key; do
      [[ -z "$role_name" ]] && continue
      case " ${roles} " in
        *" ${role_name} "*) continue ;;
      esac
      roles="${roles} ${role_name}"
    done <<< "$manifest_roles"
  done < <(list_enabled_catalog_apps_with_approle)

  printf '%s\n' "${roles# }"
}

APPROLE_VMS="$(build_approle_vm_list)"

role_policies_for_vm_key() {
  local vm_key="$1"
  local base_role
  local manifest_roles=""
  local role_name=""
  local manifest_policy=""
  local role_key=""
  local secret_key=""
  local role_policies=""

  # Strip environment suffix to get the base role (dns1_prod → dns1, gatus → gatus)
  base_role="$(echo "$vm_key" | sed 's/_prod$//;s/_dev$//')"
  case "$base_role" in
    dns1|dns2) role_policies="default-policy,dns-policy" ;;
    gatus)     role_policies="default-policy" ;;
    gitlab)    role_policies="default-policy,gitlab-tailscale-policy" ;;
    cicd)      role_policies="default-policy,github-publish-policy" ;;
    influxdb)  role_policies="default-policy,dashboard-policy" ;;
    *)
      if catalog_app_has_approle_manifest "$base_role"; then
        manifest_roles="$(list_manifest_approles "$base_role" "$ENV")" || return 1
        while IFS=$'\t' read -r role_name manifest_policy role_key secret_key; do
          if [[ "$role_name" == "$vm_key" ]]; then
            if [[ -n "$manifest_policy" && "$manifest_policy" != "default-policy" ]]; then
              role_policies="default-policy,${manifest_policy}"
            else
              role_policies="default-policy"
            fi
            break
          fi
        done <<< "$manifest_roles"
      fi
      if [[ -z "${role_policies:-}" ]]; then
        role_policies="default-policy"
      fi
      ;;
  esac

  if vm_key_has_cert_storage "$vm_key"; then
    role_policies="${role_policies},$(cert_storage_policy_name_for_vm_key "$vm_key")"
  fi

  echo "$role_policies"
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "configure-vault: dry-run for ${ENV}"
  if [[ -n "$TARGET_APP" ]]; then
    echo "Target app: ${TARGET_APP}"
  fi
  echo ""
  echo "=== AppRole Roles ==="
  for vm_key in $APPROLE_VMS; do
    echo "${vm_key}: $(role_policies_for_vm_key "$vm_key")"
  done
  echo ""
  echo "=== Cert Storage Policies ==="
  for vm_key in $APPROLE_VMS; do
    if ! vm_key_has_cert_storage "$vm_key"; then
      continue
    fi
    echo "--- $(cert_storage_policy_name_for_vm_key "$vm_key") ---"
    cert_storage_policy_content_for_vm_key "$vm_key"
    echo ""
  done
  exit 0
fi

# --- Authenticate with root token ---
# Prefer VAULT_ROOT_TOKEN env var (set by post-deploy.sh after fresh init)
# Fall back to SOPS (normal workstation usage)
if [[ -n "${VAULT_ROOT_TOKEN:-}" ]]; then
  ROOT_TOKEN="$VAULT_ROOT_TOKEN"
else
  ROOT_TOKEN=$(sops -d --extract "[\"vault_${ENV}_root_token\"]" "$SECRETS_FILE")
fi

echo "Configuring Vault ${ENV} at ${VAULT_ADDR}"

# --- Helper: authenticated curl to Vault ---
vault_api() {
  local method="$1" path="$2"
  local response=""
  local curl_exit=0
  shift 2

  set +e
  response="$(curl -fSsk -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -X "$method" "${VAULT_ADDR}/v1/${path}" "$@" 2>&1)"
  curl_exit=$?
  set -e
  if [[ "${curl_exit}" -ne 0 ]]; then
    printf '%s\n' "${response}" >&2
    return "${curl_exit}"
  fi
  if printf '%s' "${response}" | jq -e '((.errors // []) | length) > 0' >/dev/null 2>&1; then
    echo "ERROR: Vault API ${method} ${path} returned errors:" >&2
    printf '%s\n' "${response}" >&2
    return 1
  fi
  printf '%s\n' "${response}"
}

# --- Verify Vault is accessible and unsealed ---
echo "Checking Vault health..."
HEALTH=$(vault_api GET sys/health)
SEALED=$(echo "$HEALTH" | jq -r '.sealed')
INITIALIZED=$(echo "$HEALTH" | jq -r '.initialized')

if [[ "$INITIALIZED" != "true" ]]; then
  echo "ERROR: Vault is not initialized. Run init-vault.sh first." >&2
  exit 1
fi
if [[ "$SEALED" == "true" ]]; then
  echo "ERROR: Vault is sealed. Run init-vault.sh first." >&2
  exit 1
fi
echo "Vault is initialized and unsealed."

# --- Enable KV-v2 secrets engines ---
echo ""
echo "=== KV-v2 Secrets Engines ==="
MOUNTS=$(vault_api GET sys/mounts)
for mount_name in secret mycofu; do
  if echo "$MOUNTS" | jq -e ".[\"${mount_name}/\"]" > /dev/null 2>&1; then
    echo "${mount_name}/ engine already enabled"
  else
    echo "Enabling kv-v2 at ${mount_name}/..."
    vault_api POST "sys/mounts/${mount_name}" -d '{"type": "kv", "options": {"version": "2"}}'
    echo "${mount_name}/ enabled."
  fi
done

# --- Load policies ---
echo ""
echo "=== Policies ==="
for policy in dns vault-self default github-publish dashboard; do
  POLICY_FILE="${REPO_DIR}/framework/vault/policies/${policy}.hcl"
  if [[ ! -f "$POLICY_FILE" ]]; then
    echo "ERROR: Policy file not found: ${POLICY_FILE}" >&2
    exit 1
  fi
  POLICY_CONTENT=$(cat "$POLICY_FILE")
  echo "Writing ${policy}-policy..."
  vault_api PUT "sys/policies/acl/${policy}-policy" \
    -d "$(jq -n --arg policy "$POLICY_CONTENT" '{policy: $policy}')"
done

TAILSCALE_POLICY_CONTENT=$(cat <<EOF
path "secret/data/tailscale/nodes/${DOMAIN}/gitlab" {
  capabilities = ["create", "update", "read"]
}
EOF
)
echo "Writing gitlab-tailscale-policy..."
vault_api PUT "sys/policies/acl/gitlab-tailscale-policy" \
  -d "$(jq -n --arg policy "$TAILSCALE_POLICY_CONTENT" '{policy: $policy}')"

WORKSTATION_TAILSCALE_POLICY_CONTENT=$(cat <<EOF
path "secret/data/tailscale/nodes/${DOMAIN}/workstation-${ENV}" {
  capabilities = ["create", "update", "read"]
}
EOF
)
echo "Writing workstation-tailscale-policy..."
vault_api PUT "sys/policies/acl/workstation-tailscale-policy" \
  -d "$(jq -n --arg policy "$WORKSTATION_TAILSCALE_POLICY_CONTENT" '{policy: $policy}')"

for vm_key in $APPROLE_VMS; do
  if ! vm_key_has_cert_storage "$vm_key"; then
    continue
  fi
  POLICY_NAME="$(cert_storage_policy_name_for_vm_key "$vm_key")"
  POLICY_CONTENT="$(cert_storage_policy_content_for_vm_key "$vm_key")"
  echo "Writing ${POLICY_NAME}..."
  vault_api PUT "sys/policies/acl/${POLICY_NAME}" \
    -d "$(jq -n --arg policy "$POLICY_CONTENT" '{policy: $policy}')"
done

# --- Enable AppRole auth ---
echo ""
echo "=== AppRole Auth ==="
AUTH_MOUNTS=$(vault_api GET sys/auth)
if echo "$AUTH_MOUNTS" | jq -e '.data["approle/"] // .["approle/"]' > /dev/null 2>&1; then
  echo "approle/ auth already enabled"
else
  echo "Enabling AppRole auth..."
  vault_api POST sys/auth/approle -d '{"type": "approle"}'
  echo "AppRole auth enabled."
fi

# --- Create AppRole roles for vault-agent VMs ---
echo ""
echo "=== AppRole Roles ==="

configure_approle_role() {
  local vm_key="$1"
  local role_policies="$2"
  local sops_role_key="${3:-vault_approle_${vm_key}_role_id}"
  local sops_secret_key="${4:-vault_approle_${vm_key}_secret_id}"

  ROLE_CONFIG=$(jq -n \
    --arg policies "$role_policies" \
    '{
      bind_secret_id: true,
      secret_id_num_uses: 0,
      token_ttl: "24h",
      token_max_ttl: "720h",
      token_policies: ($policies | split(","))
    }')

  # Write-once check: skip only if BOTH credentials exist in SOPS AND
  # the role exists in Vault. After a PBS restore, Vault may have lost
  # the AppRole roles even though SOPS still has credentials. In that
  # case, recreate the role and generate fresh credentials.
  EXISTING_ROLE=$(sops -d --extract "[\"${sops_role_key}\"]" "$SECRETS_FILE" 2>/dev/null || true)
  EXISTING_SECRET=$(sops -d --extract "[\"${sops_secret_key}\"]" "$SECRETS_FILE" 2>/dev/null || true)

  SOPS_HAS_BOTH=false
  if [[ -n "$EXISTING_ROLE" && "$EXISTING_ROLE" != "null" && -n "$EXISTING_SECRET" && "$EXISTING_SECRET" != "null" ]]; then
    SOPS_HAS_BOTH=true
  fi

  VAULT_ROLE_CHECK=$(vault_api GET "auth/approle/role/${vm_key}" 2>/dev/null || echo "")
  VAULT_ROLE_EXISTS=false
  if echo "$VAULT_ROLE_CHECK" | jq -e '.data.token_ttl' > /dev/null 2>&1; then
    VAULT_ROLE_EXISTS=true
  fi

  PRESERVE_CREDENTIALS=false
  if [[ "$SOPS_HAS_BOTH" == "true" ]]; then
    if [[ "$VAULT_ROLE_EXISTS" == "true" ]]; then
      PRESERVE_CREDENTIALS=true
      echo "  ${vm_key}: SOPS credentials and Vault role both exist — reconciling policies without rotating credentials"
    else
      echo "  ${vm_key}: SOPS has credentials but role missing from Vault (PBS restore?) — recreating"
    fi
  elif [[ -n "$EXISTING_ROLE" || -n "$EXISTING_SECRET" ]]; then
    echo "  ${vm_key}: partial SOPS state (role_id=${EXISTING_ROLE:+present}${EXISTING_ROLE:-missing}, secret_id=${EXISTING_SECRET:+present}${EXISTING_SECRET:-missing}) — recreating both"
  elif [[ "$VAULT_ROLE_EXISTS" == "true" ]]; then
    echo "  ${vm_key}: Vault role exists but SOPS credentials are missing — regenerating SOPS entries"
  fi

  # Trade-off: always reapply the role config so new policies reach
  # existing clusters, but preserve working credentials when Vault and
  # SOPS already agree so reruns do not rotate write-once AppRole state.
  echo "  ${vm_key}: applying AppRole role config (policies: ${role_policies})..."
  vault_api POST "auth/approle/role/${vm_key}" -d "$ROLE_CONFIG" > /dev/null

  if [[ "$PRESERVE_CREDENTIALS" == "true" ]]; then
    echo "  ${vm_key}: role config reconciled; keeping existing role_id and secret_id"
    return 0
  fi

  # Read role_id
  ROLE_ID=$(vault_api GET "auth/approle/role/${vm_key}/role-id" | jq -r '.data.role_id')
  if [[ -z "$ROLE_ID" || "$ROLE_ID" == "null" ]]; then
    echo "  ERROR: Failed to read role_id for ${vm_key}" >&2
    exit 1
  fi

  # Generate secret_id
  SECRET_ID=$(vault_api POST "auth/approle/role/${vm_key}/secret-id" | jq -r '.data.secret_id')
  if [[ -z "$SECRET_ID" || "$SECRET_ID" == "null" ]]; then
    echo "  ERROR: Failed to generate secret_id for ${vm_key}" >&2
    exit 1
  fi

  # Store in SOPS (write-once)
  sops --set "[\"${sops_role_key}\"] \"${ROLE_ID}\"" "$SECRETS_FILE"
  sops --set "[\"${sops_secret_key}\"] \"${SECRET_ID}\"" "$SECRETS_FILE"
  echo "  ${vm_key}: role_id and secret_id stored in SOPS"
}

if [[ -n "$TARGET_APP" ]]; then
  MANIFEST_ROLES="$(list_manifest_approles "$TARGET_APP" "$ENV")" || exit 1
  ROLE_NAME=""
  ROLE_POLICY=""
  SOPS_ROLE_KEY=""
  SOPS_SECRET_KEY=""
  while IFS=$'\t' read -r ROLE_NAME ROLE_POLICY SOPS_ROLE_KEY SOPS_SECRET_KEY; do
    ROLE_POLICIES="default-policy"
    if [[ -n "$ROLE_POLICY" && "$ROLE_POLICY" != "default-policy" ]]; then
      ROLE_POLICIES="${ROLE_POLICIES},${ROLE_POLICY}"
    fi
    configure_approle_role "$ROLE_NAME" "$ROLE_POLICIES" "$SOPS_ROLE_KEY" "$SOPS_SECRET_KEY"
  done <<< "$MANIFEST_ROLES"
else
  for vm_key in $APPROLE_VMS; do
    ROLE_POLICIES="$(role_policies_for_vm_key "$vm_key")"
    configure_approle_role "$vm_key" "$ROLE_POLICIES"
  done
fi

# --- Commit SOPS changes if any ---
cd "$REPO_DIR"
if [[ $AUTO_COMMIT -eq 1 ]] && ! git diff --quiet site/sops/secrets.yaml 2>/dev/null; then
  echo ""
  echo "Committing AppRole credentials to SOPS..."
  # Ensure git identity is set (CI runner may not have one configured)
  if ! git config user.email >/dev/null 2>&1; then
    git config user.email "ci@mycofu.local"
    git config user.name "Mycofu CI"
  fi
  git add site/sops/secrets.yaml
  git commit -m "vault: add AppRole credentials for ${ENV} vault-agent VMs

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
  echo "SOPS committed."
fi

# --- Seed KV secrets from SOPS ---
# vault-agent templates on VMs read secrets from Vault KV. These secrets
# originate in SOPS and must be written to Vault so vault-agent can retrieve
# them. This is idempotent: existing values are overwritten with the current
# SOPS value (KV-v2 keeps versions).
echo ""
echo "=== KV Secrets ==="

# Map: KV path → SOPS key
# Add entries here when new vault-agent templates are added to NixOS modules.
KV_SECRETS="
secret/data/dns/pdns-api-key=pdns_api_key
"

if [[ "$ENV" == "prod" ]]; then
  if sops -d --extract '["github_deploy_key"]' "$SECRETS_FILE" >/dev/null 2>&1; then
    KV_SECRETS="${KV_SECRETS}
secret/data/github/deploy-key=github_deploy_key
"
  else
    echo "  secret/data/github/deploy-key: SOPS key 'github_deploy_key' not found — run framework/scripts/seed-github-deploy-key.sh prod --key-file <path> first"
  fi
fi

for entry in $KV_SECRETS; do
  kv_path="${entry%%=*}"
  sops_key="${entry##*=}"

  set +e
  secret_value=$(sops -d --extract "[\"${sops_key}\"]" "$SECRETS_FILE" 2>/dev/null)
  sops_exit=$?
  set -e

  if [[ $sops_exit -ne 0 || -z "$secret_value" || "$secret_value" == "null" ]]; then
    echo "  ${kv_path}: SOPS key '${sops_key}' not found — skipping"
    continue
  fi

  vault_api POST "$kv_path" \
    -d "$(jq -n --arg value "$secret_value" '{data: {value: $value}}')" > /dev/null
  echo "  ${kv_path}: written from SOPS key '${sops_key}'"
done

# --- Verify ---
echo ""
echo "=== Verification ==="
echo "Policies loaded:"
vault_api LIST sys/policies/acl | jq -r '.data.keys[]' | grep -v '^root$' | sort
echo ""
echo "Secrets engines:"
vault_api GET sys/mounts | jq -r '.data // . | to_entries[] | select(.value.type == "kv") | .key'
echo ""
echo "Auth methods:"
vault_api GET sys/auth | jq -r '.data // . | to_entries[] | .key' | sort
echo ""
echo "AppRole roles:"
vault_api LIST auth/approle/role 2>/dev/null | jq -r '.data.keys[] // empty' 2>/dev/null || echo "  (none)"
echo ""
echo "=== Vault ${ENV} configured ==="
