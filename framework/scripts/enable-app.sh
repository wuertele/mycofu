#!/usr/bin/env bash
# enable-app.sh — Enable a catalog application for deployment.
#
# Usage:
#   framework/scripts/enable-app.sh <app-name>
#
# Generates site-side files from the catalog template:
#   - applications.<app> entry in site/applications.yaml
#   - site/nix/hosts/<app>.nix (from host.nix.template)
#   - site/apps/<app>/ (from config.example/, with .example suffix stripped)
#
# No interactive prompts — all values are derived from the catalog and
# existing allocations. The operator reviews and adjusts the generated
# applications.yaml entry directly.
#
# Prerequisites:
#   - framework/catalog/<app>/ exists
#
# Idempotent: if entry already exists in applications.yaml, prints status and exits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

if [[ $# -lt 1 ]]; then
  echo "Usage: $(basename "$0") <app-name>" >&2
  echo "" >&2
  echo "Available catalog applications:" >&2
  for d in "${REPO_DIR}/framework/catalog"/*/; do
    [[ -d "$d" ]] && echo "  $(basename "$d")" >&2
  done
  exit 2
fi

APP="$1"
CATALOG_DIR="${REPO_DIR}/framework/catalog/${APP}"
HOST_NIX="${REPO_DIR}/site/nix/hosts/${APP}.nix"
APP_DIR="${REPO_DIR}/site/apps/${APP}"

# Check catalog exists
if [[ ! -d "$CATALOG_DIR" ]]; then
  echo "ERROR: Catalog application '${APP}' not found at ${CATALOG_DIR}" >&2
  echo "" >&2
  echo "Available catalog applications:" >&2
  for d in "${REPO_DIR}/framework/catalog"/*/; do
    [[ -d "$d" ]] && echo "  $(basename "$d")" >&2
  done
  exit 1
fi

# Check host template exists (optional — boilerplate generated if missing)
HAS_HOST_TEMPLATE=0
if [[ -f "${CATALOG_DIR}/host.nix.template" ]]; then
  HAS_HOST_TEMPLATE=1
fi

# Check if already enabled — primary check: applications.yaml
if [[ -f "$APPS_CONFIG" ]]; then
  APP_IN_APPS=$(yq -r ".applications.${APP} // \"\"" "$APPS_CONFIG" 2>/dev/null)
  if [[ -n "$APP_IN_APPS" && "$APP_IN_APPS" != "null" ]]; then
    echo "Already enabled: ${APP}"
    echo "  Config:      site/applications.yaml applications.${APP}"
    echo "  Host config: ${HOST_NIX}"
    echo "  App config:  ${APP_DIR}/"
    exit 0
  fi
fi

# Secondary check: host .nix exists but no applications.yaml entry (migration case)
if [[ -f "$HOST_NIX" ]]; then
  APP_IN_OLD=$(yq -r ".applications.${APP} // \"\"" "$CONFIG" 2>/dev/null)
  if [[ -n "$APP_IN_OLD" && "$APP_IN_OLD" != "null" ]]; then
    echo "Already enabled: ${APP} (needs migration)"
    echo ""
    echo "  This app has an entry in site/config.yaml but not in site/applications.yaml."
    echo "  Migrate it manually:"
    echo "    1. Copy the .applications.${APP} block from site/config.yaml to site/applications.yaml"
    echo "    2. Remove the .applications.${APP} block from site/config.yaml"
    echo "    3. Run validate-site-config.sh to verify"
    exit 0
  fi
  echo "Already enabled: ${APP}"
  echo "  Host config: ${HOST_NIX}"
  echo "  WARNING: No entry in site/applications.yaml or site/config.yaml"
  exit 0
fi

# Validate config consistency before making changes
if [[ -x "${SCRIPT_DIR}/validate-site-config.sh" ]]; then
  "${SCRIPT_DIR}/validate-site-config.sh" || exit 1
fi

# Check required tools
for tool in yq; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: Required tool not found: ${tool}" >&2
    echo "Run 'nix develop' from the repo root to enter the dev shell." >&2
    exit 1
  fi
done

# --- Generate MAC addresses ---
generate_mac() {
  printf '02:%02x:%02x:%02x:%02x:%02x\n' \
    $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) \
    $((RANDOM % 256)) $((RANDOM % 256))
}

echo "Enabling catalog application: ${APP}"
echo ""

# Read environment list from config.yaml
ENVS=$(yq -r '.environments | keys | .[]' "$CONFIG")

# Generate MACs for each environment
# (uses eval for dynamic vars — macOS bash 3.2 lacks declare -A)
for ENV in $ENVS; do
  MAC=$(generate_mac)
  eval "ENV_MAC_${ENV}=\"${MAC}\""
done

# --- Read catalog defaults ---

DEFAULT_RAM=1024
DEFAULT_CORES=2
DEFAULT_DISK=4
DEFAULT_DATA_DISK=4

# Override from variables.tf defaults if present
if [[ -f "${CATALOG_DIR}/variables.tf" ]]; then
  _ram=$(grep -A2 'variable "ram_mb"' "${CATALOG_DIR}/variables.tf" | grep 'default' | grep -o '[0-9]*' | head -1 || true)
  [[ -n "$_ram" ]] && DEFAULT_RAM=$_ram
  _cores=$(grep -A2 'variable "cores"' "${CATALOG_DIR}/variables.tf" | grep 'default' | grep -o '[0-9]*' | head -1 || true)
  [[ -n "$_cores" ]] && DEFAULT_CORES=$_cores
  _vdb=$(grep -A2 'variable "vdb_size_gb"' "${CATALOG_DIR}/variables.tf" | grep 'default' | grep -o '[0-9]*' | head -1 || true)
  [[ -n "$_vdb" ]] && DEFAULT_DATA_DISK=$_vdb
fi

# Derive backup flag: true if the app has a data disk (vdb > 0)
if [[ "$DEFAULT_DATA_DISK" -gt 0 ]]; then
  DEFAULT_BACKUP=true
else
  DEFAULT_BACKUP=false
fi

# Health endpoint from catalog
HEALTH_PORT=""
HEALTH_PATH=""
if [[ -f "${CATALOG_DIR}/health.yaml" ]]; then
  HEALTH_PORT=$(yq -r '.port // ""' "${CATALOG_DIR}/health.yaml")
  HEALTH_PATH=$(yq -r '.path // ""' "${CATALOG_DIR}/health.yaml")
  DEFAULT_MONITOR=true
else
  DEFAULT_MONITOR=false
fi

# --- Node selection ---

find_best_node() {
  local node_names
  node_names=$(yq -r '.nodes[].name' "$CONFIG")

  local best_node=""
  local best_count=999999
  for node in $node_names; do
    local vms_count apps_count count
    vms_count=$(yq -r "[.vms // {} | to_entries[] | select(.value.node == \"${node}\")] | length" "$CONFIG" 2>/dev/null || echo 0)
    apps_count=$(yq -r "[.applications // {} | to_entries[] | select(.value.node == \"${node}\")] | length" "$APPS_CONFIG" 2>/dev/null || echo 0)
    count=$((vms_count + apps_count))
    if [[ "$count" -lt "$best_count" ]]; then
      best_count=$count
      best_node=$node
    fi
  done
  echo "$best_node"
}

# --- Allocate IPs ---
# Allocates a single fourth-octet value that is unused across ALL environment
# subnets. This keeps the fourth octet consistent between prod and dev
# (e.g., influxdb is .55 in both), making VMs easy to identify by IP.

find_next_octet() {
  # Collect all used fourth octets from all environments in both files
  local all_octets=""

  for env in $ENVS; do
    local subnet base
    subnet=$(yq -r ".environments.${env}.subnet" "$CONFIG")
    base=$(echo "$subnet" | sed 's/\.[0-9]*\/[0-9]*//')

    local vms_ips apps_ips
    vms_ips=$(yq -r '(.vms // {} | to_entries[].value.ip)' "$CONFIG" 2>/dev/null | grep "^${base}\." || true)
    apps_ips=$(yq -r ".applications // {} | to_entries[].value.environments.${env}.ip" "$APPS_CONFIG" 2>/dev/null | grep "^${base}\." || true)

    local ips
    ips=$(echo -e "${vms_ips}\n${apps_ips}" | grep -v '^$')
    while IFS= read -r ip; do
      [[ -z "$ip" ]] && continue
      all_octets="${all_octets} $(echo "$ip" | awk -F. '{print $4}')"
    done <<< "$ips"
  done

  # Also check management network IPs (shared VMs like gitlab, cicd, pbs)
  local mgmt_ips
  mgmt_ips=$(yq -r '.vms | to_entries[].value.ip' "$CONFIG" 2>/dev/null || true)
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    all_octets="${all_octets} $(echo "$ip" | awk -F. '{print $4}')"
  done <<< "$mgmt_ips"

  # Find the lowest unused octet starting from 55 (50-54 reserved for framework VMs)
  for octet in $(seq 55 99); do
    if ! echo "$all_octets" | tr ' ' '\n' | grep -qw "$octet"; then
      echo "$octet"
      return 0
    fi
  done

  echo "ERROR: No available IP octet in .55-.99 range" >&2
  return 1
}

# --- Allocate VMIDs ---

allocate_vmid() {
  # VMID scheme: 5xx = dev apps, 6xx = prod apps
  # Same role offset across dev/prod (e.g., offset 01 → 501 dev, 601 prod)

  # Collect all used VMIDs from both files
  local used_vmids
  used_vmids=$(yq -r '.vms | to_entries[].value.vmid' "$CONFIG" 2>/dev/null || true)
  local app_vmids
  app_vmids=$(yq -r '.applications // {} | to_entries[].value.environments[].vmid' "$APPS_CONFIG" 2>/dev/null || true)
  used_vmids=$(echo -e "${used_vmids}\n${app_vmids}" | grep -v '^$' | sort -n)

  # Find the next available offset (01-99) where neither 5xx nor 6xx is taken
  for offset in $(seq 1 99); do
    local dev_vmid=$((500 + offset))
    local prod_vmid=$((600 + offset))
    if ! echo "$used_vmids" | grep -qw "$dev_vmid" && ! echo "$used_vmids" | grep -qw "$prod_vmid"; then
      echo "${dev_vmid} ${prod_vmid}"
      return 0
    fi
  done

  echo "ERROR: No available VMID offset in 5xx/6xx range" >&2
  return 1
}

# --- Compute all values ---

NODE=$(find_best_node)

# Allocate a single fourth octet used in all environments
APP_OCTET=$(find_next_octet) || exit 1

for ENV in $ENVS; do
  SUBNET=$(yq -r ".environments.${ENV}.subnet" "$CONFIG")
  BASE=$(echo "$SUBNET" | sed 's/\.[0-9]*\/[0-9]*//')
  eval "ENV_IP_${ENV}=\"${BASE}.${APP_OCTET}\""
done

VMID_PAIR=$(allocate_vmid) || exit 1
DEV_VMID=$(echo "$VMID_PAIR" | awk '{print $1}')
PROD_VMID=$(echo "$VMID_PAIR" | awk '{print $2}')

# Read subnet ranges for inline comments
PROD_SUBNET=$(yq -r '.environments.prod.subnet' "$CONFIG")
DEV_SUBNET=$(yq -r '.environments.dev.subnet' "$CONFIG")
PROD_BASE=$(echo "$PROD_SUBNET" | sed 's/\.[0-9]*\/[0-9]*//')
DEV_BASE=$(echo "$DEV_SUBNET" | sed 's/\.[0-9]*\/[0-9]*//')

# --- Write to applications.yaml ---

if [[ ! -f "$APPS_CONFIG" ]]; then
  cat > "$APPS_CONFIG" << 'APPSEOF'
# site/applications.yaml — see enable-app.sh

applications: {}
APPSEOF
fi

TEMP_YAML=$(mktemp)
cat > "$TEMP_YAML" <<YAMLEOF
enabled: true
node: ${NODE}
ram: ${DEFAULT_RAM}
cores: ${DEFAULT_CORES}
disk_size: ${DEFAULT_DISK}
data_disk_size: ${DEFAULT_DATA_DISK}
backup: ${DEFAULT_BACKUP}
monitor: ${DEFAULT_MONITOR}
environments:
  prod:
    ip: $(eval echo \"\$ENV_IP_prod\")
    vmid: ${PROD_VMID}
    mac: "$(eval echo \"\$ENV_MAC_prod\")"
  dev:
    ip: $(eval echo \"\$ENV_IP_dev\")
    vmid: ${DEV_VMID}
    mac: "$(eval echo \"\$ENV_MAC_dev\")"
YAMLEOF

# Add health endpoint if catalog defines one
if [[ -n "$HEALTH_PORT" && "$HEALTH_PORT" != "null" ]]; then
  echo "health_port: ${HEALTH_PORT}" >> "$TEMP_YAML"
fi
if [[ -n "$HEALTH_PATH" && "$HEALTH_PATH" != "null" ]]; then
  echo "health_path: \"${HEALTH_PATH}\"" >> "$TEMP_YAML"
fi

yq -i ".applications.${APP} = load(\"${TEMP_YAML}\")" "$APPS_CONFIG"
rm -f "$TEMP_YAML"

# Add inline comments to the generated block using yq comments
# (yq doesn't support inline comments well, so we add key comments)
yq -i ".applications.${APP}.node line_comment = \"least-loaded node\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.ram line_comment = \"MB; catalog default\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.disk_size line_comment = \"GB; root disk (vda), rebuilt from Git\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.data_disk_size line_comment = \"GB; data disk (vdb), backed up if backup: true\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.backup line_comment = \"true = PBS backs up vdb; derived from data_disk_size > 0\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.monitor line_comment = \"true = Gatus health-checks this app\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.environments.prod.ip line_comment = \"range: ${PROD_BASE}.50-${PROD_BASE}.99; verify: grep ip: site/config.yaml site/applications.yaml\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.environments.prod.vmid line_comment = \"6xx = prod apps; verify: grep vmid: site/config.yaml site/applications.yaml\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.environments.prod.mac line_comment = \"stable across rebuilds — layer 2 identity\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.environments.dev.ip line_comment = \"range: ${DEV_BASE}.50-${DEV_BASE}.99; verify: grep ip: site/config.yaml site/applications.yaml\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.environments.dev.vmid line_comment = \"5xx = dev apps; verify: grep vmid: site/config.yaml site/applications.yaml\"" "$APPS_CONFIG"
yq -i ".applications.${APP}.environments.dev.mac line_comment = \"stable across rebuilds — layer 2 identity\"" "$APPS_CONFIG"

# --- Generate host config ---
echo "Creating ${HOST_NIX}..."
if [[ $HAS_HOST_TEMPLATE -eq 1 ]]; then
  cp "${CATALOG_DIR}/host.nix.template" "$HOST_NIX"
else
  cat > "$HOST_NIX" << NIXEOF
# ${APP}.nix — NixOS host configuration for ${APP} VMs.
#
# Generated by enable-app.sh. Edit for site-specific customizations.

{ ... }:

{
  imports = [
    ../../../framework/nix/modules/base.nix
    ../../../framework/catalog/${APP}/module.nix
  ];

  system.stateVersion = "24.11";
}
NIXEOF
fi

# --- Create app config directory and copy examples ---
mkdir -p "$APP_DIR"
CREATED_FILES=()
if [[ -d "${CATALOG_DIR}/config.example" ]]; then
  for example in "${CATALOG_DIR}/config.example"/*.example; do
    [[ -f "$example" ]] || continue
    dest_name="$(basename "$example" .example)"
    dest="${APP_DIR}/${dest_name}"
    if [[ ! -f "$dest" ]]; then
      echo "Creating ${dest}..."
      cp "$example" "$dest"
      CREATED_FILES+=("$dest")
    else
      echo "Skipping ${dest} (already exists)"
    fi
  done
fi

# --- Print summary ---
echo ""
echo "=========================================="
echo "Enabled: ${APP}"
echo "=========================================="
echo ""
echo "Files created:"
echo "  ${APPS_CONFIG} (applications.${APP} entry)"
echo "  ${HOST_NIX}"
for f in ${CREATED_FILES[@]+"${CREATED_FILES[@]}"}; do
  echo "  ${f}"
done
echo ""
echo "Allocated:"
echo "  prod: VMID ${PROD_VMID}, IP $(eval echo \"\$ENV_IP_prod\")"
echo "  dev:  VMID ${DEV_VMID}, IP $(eval echo \"\$ENV_IP_dev\")"
echo ""
echo "MAC addresses are stable across rebuilds — they preserve layer 2"
echo "identity on the network. IPs are static via CIDATA, not DHCP."
echo ""
echo "Next steps:"
echo "  1. Review and adjust site/applications.yaml if needed"

if [[ ${#CREATED_FILES[@]} -gt 0 ]]; then
  echo "  2. Edit config files (replace any CHANGEME values):"
  for f in ${CREATED_FILES[@]+"${CREATED_FILES[@]}"}; do
    echo "       ${f}"
  done
fi

echo "  3. Add any required secrets to SOPS"
echo "  4. Add the flake output to flake.nix:"
echo "       ${APP}-image = mkImage [ ./site/nix/hosts/${APP}.nix ];"
echo "  5. Add the OpenTofu module instantiation to framework/tofu/root/main.tf."
echo "     The module source for application VMs is always proxmox-vm — the"
echo "     pipeline's automated backup+restore envelope handles safety for"
echo "     stateful apps. proxmox-vm-precious is reserved for Tier 2"
echo "     control-plane VMs (gitlab, cicd) that the pipeline cannot deploy:"
echo "       source = \"../../tofu/modules/proxmox-vm\""
if [[ "$DEFAULT_BACKUP" == "true" ]]; then
  echo "  6. Add a data marker entry to framework/scripts/restore-after-deploy.sh"
  echo "     for this app (uptime-based detection handles most cases, but verify"
  echo "     the app name is recognized by the restore script)."
fi
echo "  7. Build the image and deploy via the pipeline"
echo ""

if [[ -f "${CATALOG_DIR}/README.md" ]]; then
  echo "See: framework/catalog/${APP}/README.md for full documentation"
fi
