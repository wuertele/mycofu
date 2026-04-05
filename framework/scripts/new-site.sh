#!/usr/bin/env bash
# new-site.sh — Initialize a new site from framework templates.
#
# This is the entry point for third-party operators. Run it once in a fresh
# clone to generate site/config.yaml, site/images.yaml, and site/sops/.
#
# Usage:
#   framework/scripts/new-site.sh
#
# Reads:  framework/templates/config.yaml.example
#         framework/templates/images.yaml.example
# Creates: site/config.yaml, site/images.yaml, site/sops/.sops.yaml
# Idempotent: exits with a warning if site/config.yaml already exists.

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

# --- Check prerequisites ---
if [[ -f "${SITE_DIR}/config.yaml" ]]; then
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
