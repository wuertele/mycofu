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

# Application pre-deploy secrets (set by operator, stable across deploys)
INFLUXDB_ADMIN_TOKEN=$(echo "$SECRETS_JSON" | jq -r '.influxdb_admin_token // empty')
export TF_VAR_influxdb_admin_token="${INFLUXDB_ADMIN_TOKEN}"

GRAFANA_ADMIN_PASSWORD=$(echo "$SECRETS_JSON" | jq -r '.grafana_admin_password // empty')
export TF_VAR_grafana_admin_password="${GRAFANA_ADMIN_PASSWORD}"

GRAFANA_INFLUXDB_TOKEN=$(echo "$SECRETS_JSON" | jq -r '.grafana_influxdb_token // empty')
export TF_VAR_grafana_influxdb_token="${GRAFANA_INFLUXDB_TOKEN}"

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
  echo "WARNING: image-versions.auto.tfvars not found — generating placeholder." >&2
  mkdir -p "${REPO_DIR}/site/tofu"
  ROLES=$(grep -o 'var\.image_versions\["[^"]*"' main.tf 2>/dev/null | sed 's/.*\["//;s/".*//' | sort -u)
  {
    echo '# Placeholder — generated by tofu-wrapper.sh (no build artifacts available)'
    echo 'image_versions = {'
    for role in $ROLES; do
      echo "  \"${role}\" = \"\""
    done
    echo '}'
  } > "$IMAGE_VERSIONS"
fi

# --- VMID change protection ---
# On apply, check if any VMIDs in config.yaml differ from the current state.
# A VMID change means the old VM is destroyed and a new one is created with
# a different ID, breaking PBS backup continuity.
ALLOW_VMID_CHANGE=0
for arg in "$@"; do
  [[ "$arg" == "--allow-vmid-change" ]] && ALLOW_VMID_CHANGE=1
done

if [[ "$1" == "apply" && $ALLOW_VMID_CHANGE -eq 0 ]]; then
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

# Strip --allow-vmid-change from args before passing to tofu
TOFU_ARGS=()
for arg in "$@"; do
  [[ "$arg" != "--allow-vmid-change" ]] && TOFU_ARGS+=("$arg")
done

# --- Run tofu ---
# Pass image-versions from site/tofu/ for commands that accept -var-file
FIRST_ARG="${TOFU_ARGS[0]:-}"
if [[ -f "$IMAGE_VERSIONS" ]] && [[ "$FIRST_ARG" == "plan" || "$FIRST_ARG" == "apply" || "$FIRST_ARG" == "destroy" || "$FIRST_ARG" == "refresh" ]]; then
  exec tofu "${TOFU_ARGS[0]}" -var-file="$IMAGE_VERSIONS" "${TOFU_ARGS[@]:1}"
else
  exec tofu "${TOFU_ARGS[@]}"
fi
