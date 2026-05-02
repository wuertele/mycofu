#!/usr/bin/env bash
# tofu-wrapper.sh — Decrypt SOPS secrets, export env vars, exec tofu.
#
# Usage:
#   framework/scripts/tofu-wrapper.sh init
#   framework/scripts/tofu-wrapper.sh plan
#   framework/scripts/tofu-wrapper.sh apply
#   framework/scripts/tofu-wrapper.sh destroy
#   # Any tofu subcommand works — arguments are passed through.

set -euo pipefail

# --- Locate repo root (find directory containing flake.nix) ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "${dir}/flake.nix" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root (no flake.nix found)." >&2
  exit 1
}

REPO_DIR="$(find_repo_root)"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
export VAULT_REQUIREMENTS_REPO_DIR="${REPO_DIR}"
# Guard: vault-requirements-lib.sh may not exist in test fixture repos.
# Without it, manifest-based AppRole discovery is skipped (hardcoded list still works).
if [[ -f "${REPO_DIR}/framework/scripts/vault-requirements-lib.sh" ]]; then
  source "${REPO_DIR}/framework/scripts/vault-requirements-lib.sh"
fi

# --- Validate config consistency ---
VALIDATE_SCRIPT="${REPO_DIR}/framework/scripts/validate-site-config.sh"
if [[ -x "$VALIDATE_SCRIPT" ]]; then
  "$VALIDATE_SCRIPT" || exit 1
fi

# --- Check prerequisites ---

if [[ ! -f "$SECRETS_FILE" ]]; then
  echo "ERROR: SOPS secrets file not found: ${SECRETS_FILE}" >&2
  echo "Run framework/scripts/bootstrap-sops.sh first." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# Check for SOPS age key
if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
  elif [[ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
    export SOPS_AGE_KEY_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
  else
    echo "ERROR: No SOPS age key found." >&2
    echo "Set SOPS_AGE_KEY_FILE, or place your key at:" >&2
    echo "  ${REPO_DIR}/operator.age.key" >&2
    echo "  ${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" >&2
    exit 1
  fi
fi

# --- Check required tools ---
for tool in sops yq jq tofu; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: Required tool not found: ${tool}" >&2
    echo "Run 'nix develop' from the repo root to enter the dev shell." >&2
    exit 1
  fi
done

# --- Decrypt secrets (never written to disk) ---
echo "Decrypting secrets..."
SECRETS_JSON=$(sops -d --output-type json "$SECRETS_FILE")

PROXMOX_USER=$(echo "$SECRETS_JSON" | jq -r '.proxmox_api_user')
PROXMOX_PASSWORD=$(echo "$SECRETS_JSON" | jq -r '.proxmox_api_password')
TOFU_DB_PASSWORD=$(echo "$SECRETS_JSON" | jq -r '.tofu_db_password')
SSH_PUBKEY=$(echo "$SECRETS_JSON" | jq -r '.ssh_pubkey')
PDNS_API_KEY=$(echo "$SECRETS_JSON" | jq -r '.pdns_api_key')

# --- Read non-secret config values ---
NAS_IP=$(yq -r '.nas.ip' "$CONFIG_FILE")
NAS_PG_PORT=$(yq -r '.nas.postgres_port' "$CONFIG_FILE")
POSTGRES_SSL=$(yq -r '.nas.postgres_ssl // false' "$CONFIG_FILE")
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG_FILE")
GITHUB_REMOTE_URL=$(yq -r '.github.remote_url // ""' "$CONFIG_FILE")

# --- Export Proxmox provider env vars ---
export PROXMOX_VE_ENDPOINT="https://${FIRST_NODE_IP}:8006/"
export PROXMOX_VE_USERNAME="${PROXMOX_USER}"
export PROXMOX_VE_PASSWORD="${PROXMOX_PASSWORD}"
export PROXMOX_VE_INSECURE="true"

# --- Build PostgreSQL connection string ---
# Export as env var — the pg backend reads PG_CONN_STR at runtime.
# Do NOT use -backend-config: those values get baked into the stored hash
# but plan/apply compute the hash from HCL only, causing a permanent mismatch.
PG_CONN_STR="postgres://tofu:${TOFU_DB_PASSWORD}@${NAS_IP}:${NAS_PG_PORT}/tofu_state"
if [[ "$POSTGRES_SSL" != "true" ]]; then
  PG_CONN_STR="${PG_CONN_STR}?sslmode=disable"
fi
export PG_CONN_STR

# --- Export TF vars from secrets ---
export TF_VAR_ssh_pubkey="${SSH_PUBKEY}"
export TF_VAR_pdns_api_key="${PDNS_API_KEY}"
export TF_VAR_github_remote_url="${GITHUB_REMOTE_URL}"

# Application pre-deploy secrets (set by operator, stable across deploys)
INFLUXDB_ADMIN_TOKEN=$(echo "$SECRETS_JSON" | jq -r '.influxdb_admin_token // empty')
export TF_VAR_influxdb_admin_token="${INFLUXDB_ADMIN_TOKEN}"

GRAFANA_ADMIN_PASSWORD=$(echo "$SECRETS_JSON" | jq -r '.grafana_admin_password // empty')
export TF_VAR_grafana_admin_password="${GRAFANA_ADMIN_PASSWORD}"

GRAFANA_INFLUXDB_TOKEN=$(echo "$SECRETS_JSON" | jq -r '.grafana_influxdb_token // empty')
export TF_VAR_grafana_influxdb_token="${GRAFANA_INFLUXDB_TOKEN}"

TAILSCALE_AUTH_KEY=$(echo "$SECRETS_JSON" | jq -r '.tailscale_auth_key // empty')
export TF_VAR_tailscale_auth_key="${TAILSCALE_AUTH_KEY}"

# Vault AppRole credentials for vault-agent (generated by configure-vault.sh)
EXPORTED_APPROLE_ROLES=" dns1_prod dns2_prod dns1_dev dns2_dev gatus gitlab cicd influxdb_dev influxdb_prod testapp_dev testapp_prod grafana_dev grafana_prod "
for ROLE in dns1_prod dns2_prod dns1_dev dns2_dev gatus gitlab cicd influxdb_dev influxdb_prod testapp_dev testapp_prod grafana_dev grafana_prod; do
  ROLE_ID=$(echo "$SECRETS_JSON" | jq -r ".vault_approle_${ROLE}_role_id // empty")
  SECRET_ID=$(echo "$SECRETS_JSON" | jq -r ".vault_approle_${ROLE}_secret_id // empty")
  export "TF_VAR_vault_approle_${ROLE}_role_id=${ROLE_ID}"
  export "TF_VAR_vault_approle_${ROLE}_secret_id=${SECRET_ID}"
done

# Discover additional AppRoles from catalog manifests (if library is loaded)
if type list_enabled_catalog_apps_with_approle &>/dev/null; then
APP=""
APP_ENV=""
ROLE_KEY=""
SECRET_KEY=""
ROLE_NAME=""
MANIFEST_KEYS=""
while IFS= read -r APP; do
  [[ -z "$APP" ]] && continue
  while IFS= read -r APP_ENV; do
    [[ -z "$APP_ENV" || "$APP_ENV" == "null" ]] && continue
    MANIFEST_KEYS="$(resolve_sops_keys "$APP" "$APP_ENV")" || exit 1
    while IFS=$'\t' read -r ROLE_KEY SECRET_KEY; do
      ROLE_NAME="${ROLE_KEY#vault_approle_}"
      ROLE_NAME="${ROLE_NAME%_role_id}"
      case "$EXPORTED_APPROLE_ROLES" in
        *" ${ROLE_NAME} "*) continue ;;
      esac
      ROLE_ID=$(echo "$SECRETS_JSON" | jq -r ".[\"${ROLE_KEY}\"] // empty")
      SECRET_ID=$(echo "$SECRETS_JSON" | jq -r ".[\"${SECRET_KEY}\"] // empty")
      export "TF_VAR_${ROLE_KEY}=${ROLE_ID}"
      export "TF_VAR_${SECRET_KEY}=${SECRET_ID}"
      EXPORTED_APPROLE_ROLES+=" ${ROLE_NAME} "
    done <<< "$MANIFEST_KEYS"
  done < <(yq -r ".applications.${APP}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null || true)
done < <(list_enabled_catalog_apps_with_approle)
fi  # end manifest-based AppRole discovery

# SSH host keys from SOPS — per-VM ed25519 keys for deterministic host key
# fingerprints. Delivered via CIDATA write_files. Keys are pre-deploy secrets
# (generated once by new-site.sh, stable across deploys).
SSH_HOST_KEYS_JSON=$(echo "$SECRETS_JSON" | jq -c '.ssh_host_keys // {}')
export TF_VAR_ssh_host_keys_json="${SSH_HOST_KEYS_JSON}"

# Post-deploy secrets (vault unseal keys, runner registration token) are NOT
# exported as TF_VARs. They are delivered via SSH by init-vault.sh and
# register-runner.sh, not via CIDATA. This prevents the CIDATA recreation
# cycle where post-deploy secrets flow back into CIDATA and trigger VM
# recreation on the next apply.

# SOPS age key — read from the operator's age key file, not from SOPS
# (the age key is the one secret that isn't in SOPS because it decrypts SOPS)
if [[ -f "${SOPS_AGE_KEY_FILE}" ]]; then
  SOPS_AGE_KEY_CONTENT=$(cat "${SOPS_AGE_KEY_FILE}")
  export TF_VAR_sops_age_key="${SOPS_AGE_KEY_CONTENT}"
else
  export TF_VAR_sops_age_key=""
fi

# SSH private key for runner node access (may not exist)
SSH_PRIVKEY=$(echo "$SECRETS_JSON" | jq -r '.ssh_privkey // empty')
export TF_VAR_ssh_privkey="${SSH_PRIVKEY}"

# --- Change to framework/tofu/root/ working directory ---
cd "${REPO_DIR}/framework/tofu/root"

# --- Symlink site overrides if present ---
OVERRIDE_SRC="${REPO_DIR}/site/tofu/overrides.tf"
if [[ -f "$OVERRIDE_SRC" ]] && [[ ! -L "overrides.tf" ]]; then
  ln -sf "$OVERRIDE_SRC" overrides.tf
fi

# --- Check for image-versions file (build artifact in site/tofu/) ---
IMAGE_VERSIONS="${REPO_DIR}/site/tofu/image-versions.auto.tfvars"
if [[ ! -f "$IMAGE_VERSIONS" ]]; then
  echo "WARNING: image-versions.auto.tfvars not found — generating placeholder sentinels; tofu apply will be blocked until valid image filenames are present." >&2
  mkdir -p "${REPO_DIR}/site/tofu"
  ROLES=$(grep -o 'var\.image_versions\["[^"]*"' main.tf 2>/dev/null | sed 's/.*\["//;s/".*//' | sort -u)
  {
    echo '# Placeholder — generated by tofu-wrapper.sh (no build artifacts available)'
    echo 'image_versions = {'
    for role in $ROLES; do
      echo "  \"${role}\" = \"PLACEHOLDER_${role}\""
    done
    echo '}'
  } > "$IMAGE_VERSIONS"
fi

# --- Image filename validation ---
validate_image_versions_file() {
  local image_versions_file="$1"
  local tofu_command="$2"
  local allow_placeholder_images="$3"
  local IMAGE_FILENAME_PATTERN='^[a-z][a-z0-9]*(-[a-z0-9]+)*-[a-z0-9]{8}(-dev)?\.img$'
  local invalid_images=""
  local unparseable_lines=""
  local line=""
  local trimmed_line=""
  local role=""
  local value=""
  local in_image_versions_block=0
  local total_candidate_lines=0
  local validated_entries=0
  local parser_skipped_lines=0
  local issue_header=""
  local issue_details=""

  while IFS= read -r line; do
    trimmed_line="${line#"${line%%[![:space:]]*}"}"
    trimmed_line="${trimmed_line%"${trimmed_line##*[![:space:]]}"}"

    if [[ "$in_image_versions_block" -eq 0 ]]; then
      if [[ "$trimmed_line" =~ ^image_versions[[:space:]]*=[[:space:]]*\{[[:space:]]*$ ]]; then
        in_image_versions_block=1
      elif [[ "$trimmed_line" =~ ^image_versions[[:space:]]*=[[:space:]]*\{.*$ ]]; then
        in_image_versions_block=1
        total_candidate_lines=$((total_candidate_lines + 1))
        unparseable_lines+="  ${trimmed_line}"$'\n'
        [[ "$trimmed_line" == *"}"* ]] && in_image_versions_block=0
      fi
      continue
    fi

    if [[ -z "$trimmed_line" || "$trimmed_line" =~ ^# || "$trimmed_line" =~ ^// ]]; then
      continue
    fi

    if [[ "$trimmed_line" == "}" ]]; then
      in_image_versions_block=0
      continue
    fi

    total_candidate_lines=$((total_candidate_lines + 1))
    if [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*=[[:space:]]*\"([^\"]*)\"[[:space:]]*$ ]]; then
      validated_entries=$((validated_entries + 1))
      role="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      if [[ ! "$value" =~ $IMAGE_FILENAME_PATTERN ]]; then
        invalid_images+="  ${role}: ${value}"$'\n'
      fi
    else
      unparseable_lines+="  ${trimmed_line}"$'\n'
      [[ "$trimmed_line" == *"}"* ]] && in_image_versions_block=0
    fi
  done < "$image_versions_file"

  if [[ "$validated_entries" -ne "$total_candidate_lines" ]]; then
    parser_skipped_lines=1
    if [[ -z "$unparseable_lines" ]]; then
      unparseable_lines+="  <unable to identify skipped image_versions lines>"$'\n'
    fi
  fi

  if [[ -n "$invalid_images" ]]; then
    issue_details+="Invalid image values:"$'\n'
    issue_details+="${invalid_images}"
  fi

  if [[ "$parser_skipped_lines" -eq 1 ]]; then
    [[ -n "$issue_details" ]] && issue_details+=$'\n'
    issue_details+="Unparseable image_versions entries:"$'\n'
    issue_details+="${unparseable_lines}"
  fi

  if [[ -z "$invalid_images" && "$parser_skipped_lines" -eq 0 ]]; then
    return 0
  fi

  if [[ -n "$invalid_images" && "$parser_skipped_lines" -eq 1 ]]; then
    issue_header="Invalid or unparseable image values detected in image-versions.auto.tfvars"
  elif [[ -n "$invalid_images" ]]; then
    issue_header="Invalid image values detected in image-versions.auto.tfvars"
  else
    issue_header="Unparseable image_versions entries detected in image-versions.auto.tfvars"
  fi

  case "$tofu_command" in
    apply)
      if [[ "$allow_placeholder_images" -eq 1 ]]; then
        echo "WARNING: ${issue_header}, but proceeding due to --allow-placeholder-images:" >&2
        printf '%s' "$issue_details" >&2
        return 0
      fi
      echo "ERROR: ${issue_header}:" >&2
      printf '%s' "$issue_details" >&2
      echo "Run build-image.sh or build-all-images.sh to populate valid image filenames, or pass --allow-placeholder-images to bypass this guard." >&2
      return 1
      ;;
    plan)
      echo "WARNING: ${issue_header}; tofu plan will continue, but tofu apply will be blocked:" >&2
      printf '%s' "$issue_details" >&2
      return 0
      ;;
  esac

  return 0
}

# --- VMID change protection ---
# On apply, check if any VMIDs in config.yaml differ from the current state.
# A VMID change means the old VM is destroyed and a new one is created with
# a different ID, breaking PBS backup continuity.
ALLOW_VMID_CHANGE=0
ALLOW_PLACEHOLDER_IMAGES=0
for arg in "$@"; do
  case "$arg" in
    --allow-vmid-change) ALLOW_VMID_CHANGE=1 ;;
    --allow-placeholder-images) ALLOW_PLACEHOLDER_IMAGES=1 ;;
  esac
done

TOFU_COMMAND="${1:-}"

if [[ "$TOFU_COMMAND" == "apply" && $ALLOW_VMID_CHANGE -eq 0 ]]; then
  # Only check if state exists (not first deploy)
  if tofu state list 2>/dev/null | grep -q "proxmox_virtual_environment_vm"; then
    VMID_CHANGES=""
    # Check infrastructure VMs
    for vm_key in $(yq -r '.vms | keys | .[]' "$CONFIG_FILE"); do
      PLANNED_VMID=$(yq -r ".vms.${vm_key}.vmid" "$CONFIG_FILE")
      [[ -z "$PLANNED_VMID" || "$PLANNED_VMID" == "null" ]] && continue
      # Find the VM resource in state and get its current vm_id
      # The resource path varies by module — search state for this VM name
      CURRENT_VMID=$(tofu state show "$(tofu state list 2>/dev/null | grep "proxmox_virtual_environment_vm" | grep -i "$(echo "$vm_key" | tr '_' '-')" | head -1)" 2>/dev/null | grep "vm_id" | head -1 | awk '{print $3}' || echo "")
      if [[ -n "$CURRENT_VMID" && "$CURRENT_VMID" != "$PLANNED_VMID" ]]; then
        HAS_BACKUP=$(yq -r ".vms.${vm_key}.backup // false" "$CONFIG_FILE")
        VMID_CHANGES+="  ${vm_key}: ${CURRENT_VMID} → ${PLANNED_VMID}"
        [[ "$HAS_BACKUP" == "true" ]] && VMID_CHANGES+=" (HAS PRECIOUS STATE)"
        VMID_CHANGES+=$'\n'
      fi
    done
    # Check application VMs
    for app_key in $(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG" 2>/dev/null); do
      for env in $(yq -r ".applications.${app_key}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null); do
        PLANNED_VMID=$(yq -r ".applications.${app_key}.environments.${env}.vmid" "$APPS_CONFIG")
        [[ -z "$PLANNED_VMID" || "$PLANNED_VMID" == "null" ]] && continue
        APP_MODULE="${app_key}_${env}"
        CURRENT_VMID=$(tofu state show "$(tofu state list 2>/dev/null | grep "proxmox_virtual_environment_vm" | grep -i "$(echo "$APP_MODULE" | tr '_' '-')" | head -1)" 2>/dev/null | grep "vm_id" | head -1 | awk '{print $3}' || echo "")
        if [[ -n "$CURRENT_VMID" && "$CURRENT_VMID" != "$PLANNED_VMID" ]]; then
          HAS_BACKUP=$(yq -r ".applications.${app_key}.backup // false" "$APPS_CONFIG")
          VMID_CHANGES+="  ${APP_MODULE}: ${CURRENT_VMID} → ${PLANNED_VMID}"
          [[ "$HAS_BACKUP" == "true" ]] && VMID_CHANGES+=" (HAS PRECIOUS STATE)"
          VMID_CHANGES+=$'\n'
        fi
      done
    done
    if [[ -n "$VMID_CHANGES" ]]; then
      echo "ERROR: VMID changes detected:" >&2
      echo "$VMID_CHANGES" >&2
      echo "PBS backup continuity will break for affected VMs." >&2
      echo "Use --allow-vmid-change to proceed." >&2
      exit 1
    fi
  fi
fi

# --- Image value validation gate ---
if [[ "$TOFU_COMMAND" == "plan" || "$TOFU_COMMAND" == "apply" ]]; then
  if ! validate_image_versions_file "$IMAGE_VERSIONS" "$TOFU_COMMAND" "$ALLOW_PLACEHOLDER_IMAGES"; then
    exit 1
  fi
fi

# Strip wrapper-only flags before passing args to tofu
TOFU_ARGS=()
for arg in "$@"; do
  if [[ "$arg" != "--allow-vmid-change" && "$arg" != "--allow-placeholder-images" ]]; then
    TOFU_ARGS+=("$arg")
  fi
done

# --- Run tofu ---
# Pass image-versions from site/tofu/ for commands that accept -var-file
FIRST_ARG="${TOFU_ARGS[0]:-}"
if [[ -f "$IMAGE_VERSIONS" ]] && [[ "$FIRST_ARG" == "plan" || "$FIRST_ARG" == "apply" || "$FIRST_ARG" == "destroy" || "$FIRST_ARG" == "refresh" ]]; then
  exec tofu "${TOFU_ARGS[0]}" -var-file="$IMAGE_VERSIONS" "${TOFU_ARGS[@]:1}"
else
  exec tofu "${TOFU_ARGS[@]}"
fi
