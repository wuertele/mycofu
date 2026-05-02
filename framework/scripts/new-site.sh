#!/usr/bin/env bash
# new-site.sh — Initialize a new site from framework templates.
#
# This is the entry point for third-party operators. Run it once in a fresh
# clone to generate site/config.yaml, site/images.yaml, and site/sops/.
#
# Usage:
#   framework/scripts/new-site.sh                # initialize a new site
#   framework/scripts/new-site.sh --fill-ssh-keys # generate SSH host keys for all VMs
#
# Reads:  framework/templates/config.yaml.example
#         framework/templates/images.yaml.example
# Creates: site/config.yaml, site/images.yaml, site/sops/.sops.yaml
# Idempotent: exits with a warning if site/config.yaml already exists.
#
# --fill-ssh-keys: generates ed25519 SSH host keys for every VM in
# config.yaml and applications.yaml, stores them in SOPS (write-once:
# existing keys are never overwritten). Run this once after initial
# site setup, then tofu apply to deploy the keys via CIDATA.

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
TEMPLATE_DIR="${REPO_DIR}/framework/templates"
SITE_DIR="${REPO_DIR}/site"
CONFIG="${SITE_DIR}/config.yaml"
APPS_CONFIG="${SITE_DIR}/applications.yaml"
SECRETS="${SITE_DIR}/sops/secrets.yaml"

# --- --fill-ssh-keys mode ---
if [[ "${1:-}" == "--fill-ssh-keys" ]]; then
  echo "=== Generating SSH host keys for all VMs ==="

  for tool in sops yq ssh-keygen jq; do
    command -v "$tool" &>/dev/null || { echo "ERROR: $tool not found" >&2; exit 1; }
  done
  [[ -f "$CONFIG" ]] || { echo "ERROR: $CONFIG not found" >&2; exit 1; }
  [[ -f "$SECRETS" ]] || { echo "ERROR: $SECRETS not found. Run bootstrap-sops.sh first." >&2; exit 1; }

  # Auto-detect SOPS age key (same logic as tofu-wrapper.sh)
  if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
    if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
      export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
    elif [[ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
      export SOPS_AGE_KEY_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
    else
      echo "ERROR: SOPS age key not found." >&2
      echo "  Set SOPS_AGE_KEY_FILE, or place your key at:" >&2
      echo "    ${REPO_DIR}/operator.age.key" >&2
      exit 1
    fi
  fi

  DOMAIN=$(yq -r '.domain' "$CONFIG")
  TMPDIR_KEYS=$(mktemp -d)
  # Ensure private key material is cleaned up on any exit (Ctrl-C, error, etc.)
  trap 'rm -rf "$TMPDIR_KEYS"' EXIT
  GENERATED=0
  SKIPPED=0

  fill_ssh_key() {
    local vm_key="$1"
    # Write-once: if the key already exists in SOPS, do nothing.
    local existing
    existing=$(sops -d --extract "[\"ssh_host_keys\"][\"${vm_key}\"][\"private\"]" "$SECRETS" 2>/dev/null || true)
    if [[ -n "$existing" && "$existing" != "null" ]]; then
      echo "  ${vm_key}: exists — skipping (write-once)"
      SKIPPED=$((SKIPPED + 1))
      return 0
    fi

    ssh-keygen -t ed25519 -N '' -C "${vm_key}@${DOMAIN}" \
      -f "${TMPDIR_KEYS}/${vm_key}" -q

    # sops --set requires JSON-encoded string values. SSH private keys
    # contain newlines which must be escaped as \n in JSON. jq -Rs
    # reads raw input and produces a properly quoted/escaped JSON string.
    local private_json public_json
    private_json=$(jq -Rs . < "${TMPDIR_KEYS}/${vm_key}")
    public_json=$(jq -Rs . < "${TMPDIR_KEYS}/${vm_key}.pub")

    sops --set "[\"ssh_host_keys\"][\"${vm_key}\"][\"private\"] ${private_json}" "$SECRETS"
    sops --set "[\"ssh_host_keys\"][\"${vm_key}\"][\"public\"] ${public_json}" "$SECRETS"
    echo "  ${vm_key}: generated"
    GENERATED=$((GENERATED + 1))
  }

  # Infrastructure VMs from config.yaml.
  # Skip PBS — it's a vendor appliance (not NixOS) with no SSH key consumer.
  for vm_key in $(yq -r '.vms | keys | .[]' "$CONFIG"); do
    [[ "$vm_key" == "pbs" ]] && { echo "  pbs: skipped (vendor appliance, not NixOS)"; continue; }
    fill_ssh_key "$vm_key"
  done

  # Application VMs from applications.yaml
  if [[ -f "$APPS_CONFIG" ]]; then
    for app_key in $(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG" 2>/dev/null); do
      for env in $(yq -r ".applications.${app_key}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null); do
        fill_ssh_key "${app_key}_${env}"
      done
    done
  fi

  rm -rf "$TMPDIR_KEYS"
  trap - EXIT  # clear the trap since we cleaned up manually
  echo ""
  echo "=== Done: ${GENERATED} generated, ${SKIPPED} skipped (already existed) ==="
  echo ""
  echo "Next steps:"
  echo "  1. Commit the updated site/sops/secrets.yaml"
  echo "  2. Run tofu apply — CIDATA will change for all data-plane VMs,"
  echo "     triggering recreation. Run backup-now.sh first."
  exit 0
fi

# --- Check prerequisites (init mode) ---
if [[ -f "${CONFIG}" ]]; then
  echo "WARNING: site/config.yaml already exists."
  echo "If you want to reinitialize, remove it first:"
  echo "  rm site/config.yaml"
  exit 1
fi

if [[ ! -f "${TEMPLATE_DIR}/config.yaml.example" ]]; then
  echo "ERROR: Template not found: ${TEMPLATE_DIR}/config.yaml.example" >&2
  exit 1
fi

# --- Generate MAC addresses ---
# Locally administered range: 02:xx:xx:xx:xx:xx
generate_mac() {
  printf '02:%02x:%02x:%02x:%02x:%02x\n' \
    $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) \
    $((RANDOM % 256)) $((RANDOM % 256))
}

echo "=== Initializing new site ==="
echo ""

# --- Prompt for domain ---
read -rp "Domain name [example.com]: " DOMAIN
DOMAIN="${DOMAIN:-example.com}"

# --- Create site directory structure ---
mkdir -p "${SITE_DIR}/sops"
mkdir -p "${SITE_DIR}/tofu"

# Generate empty overrides.tf for operator extensions
cat > "${SITE_DIR}/tofu/overrides.tf" << 'OVERRIDE_EOF'
# Site-specific OpenTofu overrides.
#
# Add resources here that config.yaml cannot express: custom Proxmox
# resources, additional disks, firewall rules, non-catalog applications
# with custom modules, etc.
#
# OpenTofu merges this file into the framework's root module via a
# symlink managed by tofu-wrapper.sh. Leave empty if you have no
# site-specific overrides.
OVERRIDE_EOF
mkdir -p "${SITE_DIR}/nix/hosts"
mkdir -p "${SITE_DIR}/zones"

# --- Copy and customize config.yaml ---
echo ""
echo "Generating site/config.yaml..."
cp "${TEMPLATE_DIR}/config.yaml.example" "${SITE_DIR}/config.yaml"

# Replace example.com with the operator's domain
if [[ "$DOMAIN" != "example.com" ]]; then
  sed -i '' "s/example\.com/${DOMAIN}/g" "${SITE_DIR}/config.yaml"
fi

# Generate unique MAC addresses for all infrastructure VMs
for vm in dns1_prod dns2_prod vault_prod dns1_dev dns2_dev vault_dev acme_dev pbs gitlab cicd testapp_dev testapp_prod gatus; do
  MAC=$(generate_mac)
  yq -i ".vms.${vm}.mac = \"${MAC}\"" "${SITE_DIR}/config.yaml"
done

# Create empty applications.yaml for future app enablement via enable-app.sh
APPS_YAML="${SITE_DIR}/applications.yaml"
if [[ ! -f "$APPS_YAML" ]]; then
  cat > "$APPS_YAML" << 'APPSEOF'
# site/applications.yaml
#
# Application VM specifications. Each entry describes one application VM
# that the framework manages on your cluster.
#
# This file is generated and maintained by the operator. Use enable-app.sh
# to add a new application — it will append a complete, pre-filled entry
# that you can review and adjust. After generation, this file is yours.
#
# DEPENDENCY: IP ranges and VMID ranges here are constrained by values in
# site/config.yaml (subnets, VMID scheme). If you change subnets or VMID
# ranges in config.yaml, update the inline range comments in this file.
#
# Framework VM configuration (DNS, Vault, PBS, GitLab, etc.) lives in
# site/config.yaml, not here.

applications: {}
APPSEOF
  echo "  Created ${APPS_YAML}"
fi

# Generate MAC addresses for application VMs (from applications.yaml)
for app in $(yq -r '.applications // {} | keys[]' "$APPS_YAML" 2>/dev/null); do
  for env in $(yq -r ".applications.${app}.environments // {} | keys[]" "$APPS_YAML" 2>/dev/null); do
    if yq -e ".applications.${app}.environments.${env}.mac" "$APPS_YAML" &>/dev/null; then
      MAC=$(generate_mac)
      yq -i ".applications.${app}.environments.${env}.mac = \"${MAC}\"" "$APPS_YAML"
    fi
    # Also handle mgmt_nic MAC if present
    if yq -e ".applications.${app}.environments.${env}.mgmt_nic.mac" "$APPS_YAML" &>/dev/null; then
      MAC=$(generate_mac)
      yq -i ".applications.${app}.environments.${env}.mgmt_nic.mac = \"${MAC}\"" "$APPS_YAML"
    fi
  done
done

# Detect and install the operator's SSH public key
OPERATOR_KEY=""
for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
  if [[ -f "$keyfile" ]]; then
    OPERATOR_KEY=$(cat "$keyfile")
    break
  fi
done
if [[ -n "$OPERATOR_KEY" ]]; then
  yq -i ".operator_ssh_pubkey = \"${OPERATOR_KEY}\"" "${SITE_DIR}/config.yaml"
  echo "  Operator SSH key: detected from $(basename "$keyfile")"
else
  echo "  Operator SSH key: NOT FOUND — fill in operator_ssh_pubkey manually"
fi

echo "  Domain: ${DOMAIN}"
echo "  MAC addresses: generated (locally administered range)"

# --- Copy GitLab settings template ---
echo ""
echo "Generating site/gitlab.yaml..."
if [[ ! -f "${SITE_DIR}/gitlab.yaml" ]]; then
  cp "${TEMPLATE_DIR}/gitlab.yaml.example" "${SITE_DIR}/gitlab.yaml"
  echo "  Copied from template (customize labels as needed)"
else
  echo "  Already exists — skipping"
fi

# --- Generate images.yaml ---
echo ""
echo "Generating site/images.yaml..."
cat > "${SITE_DIR}/images.yaml" << 'IMGYAML'
# Site image manifest — application roles specific to this deployment.
#
# Framework infrastructure roles (dns, vault, gitlab, etc.) are in
# framework/images.yaml. Only site-specific roles go here.
# Catalog applications are built automatically from config.yaml.

roles:
  testapp:
    category: nix
    host_config: site/nix/hosts/testapp.nix
    flake_output: testapp-image
IMGYAML

# --- Generate NixOS host configs ---
# Infrastructure roles: simple boilerplate importing base.nix + role module.
# Catalog application host configs are generated by enable-app.sh.
echo ""
echo "Generating site/nix/hosts/ (infrastructure roles)..."

# role:module pairs (module name when different from role name)
for entry in dns:dns vault:vault gitlab:gitlab cicd:gitlab-runner acme-dev:step-ca gatus:gatus testapp:testapp; do
  role="${entry%%:*}"
  module="${entry##*:}"
  host_file="${SITE_DIR}/nix/hosts/${role}.nix"
  if [[ ! -f "$host_file" ]]; then
    cat > "$host_file" << NIXEOF
# ${role}.nix — NixOS host configuration for ${role} VMs.
#
# Generated by new-site.sh. Edit for site-specific customizations.

{ ... }:

{
  imports = [
    ../../../framework/nix/modules/base.nix
    ../../../framework/nix/modules/${module}.nix
  ];

  system.stateVersion = "24.11";
}
NIXEOF
    echo "  Created ${role}.nix"
  fi
done

# --- Create SOPS template ---
echo ""
echo "Generating site/sops/.sops.yaml..."
cat > "${SITE_DIR}/sops/.sops.yaml" << 'SOPS_EOF'
# SOPS configuration — age encryption.
#
# Replace the age public key below with your own.
# Generate a key pair:
#   age-keygen -o site/sops/age-key.txt
#   cat site/sops/age-key.txt  # shows the public key
#
# Then encrypt secrets:
#   sops -e -i site/sops/secrets.yaml
creation_rules:
  - path_regex: \.yaml$
    age: "age1REPLACE_WITH_YOUR_AGE_PUBLIC_KEY"
SOPS_EOF

# --- Secrets created by bootstrap-sops.sh (not here) ---

# Fail during generation if the template and generated files have drifted away
# from the current config contract (for example, a newly required pool field).
if [[ -x "${SCRIPT_DIR}/validate-site-config.sh" ]]; then
  echo ""
  echo "Validating generated site config..."
  "${SCRIPT_DIR}/validate-site-config.sh"
  echo "  site/config.yaml and site/applications.yaml passed validation"
fi

# --- Summary ---
echo ""
echo "=== Site initialized ==="
echo ""
echo "Generated files:"
echo "  site/config.yaml          — edit with your IPs, subnets, and node details"
echo "  site/images.yaml          — add site-specific VM roles here"
echo "  site/nix/hosts/*.nix      — NixOS host configurations"
echo "  site/tofu/overrides.tf    — site-specific OpenTofu overrides"
echo ""
echo "Next steps:"
echo "  1. Edit site/config.yaml with your network configuration"
echo "  2. Configure VLANs and DHCP search domains on your gateway"
echo "     (VMs use static IPs from CIDATA — no DHCP reservations needed)"
echo "  3. Run: framework/scripts/bootstrap-sops.sh"
echo "     (generates age key, SSH keys, and encrypts secrets)"
echo "  4. Run: framework/bringup/generate-bringup.sh"
echo "     (generates a site-specific step-by-step setup checklist)"
echo "  5. Follow the bringup guide, then run: framework/scripts/rebuild-cluster.sh"
