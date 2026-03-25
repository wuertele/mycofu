#!/usr/bin/env bash
# enable-app.sh — Enable a catalog application for deployment.
#
# Usage:
#   framework/scripts/enable-app.sh <app-name>
#
# Generates site-side files from the catalog template:
#   - site/nix/hosts/<app>.nix (from host.nix.template)
#   - site/apps/<app>/ (from config.example/, with .example suffix stripped)
#   - applications.<app> entry in site/config.yaml
#
# Prerequisites:
#   - framework/catalog/<app>/ exists
#
# Idempotent: if files already exist, prints "already enabled" and exits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

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

# Check host template exists
if [[ ! -f "${CATALOG_DIR}/host.nix.template" ]]; then
  echo "ERROR: ${CATALOG_DIR}/host.nix.template not found" >&2
  exit 1
fi

# Check if already enabled
if [[ -f "$HOST_NIX" ]]; then
  echo "Already enabled: ${APP}"
  echo "  Host config: ${HOST_NIX}"
  echo "  App config:  ${APP_DIR}/"
  # Check if in config.yaml
  APP_IN_CONFIG=$(yq -r ".applications.${APP} // \"\"" "$CONFIG" 2>/dev/null)
  if [[ -n "$APP_IN_CONFIG" && "$APP_IN_CONFIG" != "null" ]]; then
    echo "  Config:      site/config.yaml applications.${APP}"
  else
    echo "  WARNING: Not in site/config.yaml applications block"
  fi
  exit 0
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
echo "Generated MAC addresses:"
for ENV in $ENVS; do
  MAC=$(generate_mac)
  eval "ENV_MAC_${ENV}=\"${MAC}\""
  echo "  ${ENV}: ${MAC}"
done
echo ""

# --- Smart defaults ---

# Find the next available IP in each environment subnet
find_next_ip() {
  local env="$1"
  local subnet
  subnet=$(yq -r ".environments.${env}.subnet" "$CONFIG")
  # Extract base (e.g., 172.27.10) from subnet like 172.27.10.0/24
  local base
  base=$(echo "$subnet" | sed 's/\.[0-9]*\/[0-9]*//')

  # Collect all used IPs in this subnet from vms and applications
  local used_ips
  used_ips=$(yq -r "
    [
      (.vms // {} | to_entries[].value.ip),
      (.applications // {} | to_entries[].value.environments.${env}.ip // empty)
    ] | flatten | .[]
  " "$CONFIG" 2>/dev/null | grep "^${base}\." | sort -t. -k4 -n)

  # Find the highest used IP in range 50-254 and offer next
  local highest=54
  while IFS= read -r ip; do
    local last_octet
    last_octet=$(echo "$ip" | awk -F. '{print $4}')
    if [[ "$last_octet" -gt "$highest" && "$last_octet" -lt 255 ]]; then
      highest=$last_octet
    fi
  done <<< "$used_ips"

  echo "${base}.$((highest + 1))"
}

# Round-robin node selection based on current VM count
find_best_node() {
  local node_names
  node_names=$(yq -r '.nodes[].name' "$CONFIG")

  # Count VMs per node from vms + applications
  local best_node=""
  local best_count=999999
  for node in $node_names; do
    local count
    count=$(yq -r "
      [
        (.vms // {} | to_entries[] | select(.value.node == \"${node}\") | .key),
        (.applications // {} | to_entries[] | select(.value.node == \"${node}\") | .key)
      ] | flatten | length
    " "$CONFIG" 2>/dev/null || echo 0)
    if [[ "$count" -lt "$best_count" ]]; then
      best_count=$count
      best_node=$node
    fi
  done
  echo "$best_node"
}

# Read catalog defaults if metadata exists
DEFAULT_RAM=1024
DEFAULT_DISK=4
DEFAULT_DATA_DISK=4
DEFAULT_HEALTH_PORT=80
DEFAULT_HEALTH_PATH="/"
DEFAULT_BACKUP=false
DEFAULT_MONITOR=true

# Override from variables.tf defaults if present
if [[ -f "${CATALOG_DIR}/variables.tf" ]]; then
  _ram=$(grep -A2 'variable "ram_mb"' "${CATALOG_DIR}/variables.tf" | grep 'default' | grep -o '[0-9]*' | head -1 || true)
  [[ -n "$_ram" ]] && DEFAULT_RAM=$_ram
  _vdb=$(grep -A2 'variable "vdb_size_gb"' "${CATALOG_DIR}/variables.tf" | grep 'default' | grep -o '[0-9]*' | head -1 || true)
  [[ -n "$_vdb" ]] && DEFAULT_DATA_DISK=$_vdb
fi

# Prompt with defaults
DEFAULT_NODE=$(find_best_node)
read -rp "Node [${DEFAULT_NODE}]: " INPUT_NODE
NODE="${INPUT_NODE:-${DEFAULT_NODE}}"

for ENV in $ENVS; do
  DEFAULT_IP=$(find_next_ip "$ENV")
  SUBNET=$(yq -r ".environments.${ENV}.subnet" "$CONFIG")
  ENV_LABEL=$(echo "$ENV" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  read -rp "${ENV_LABEL} IP (${SUBNET}) [${DEFAULT_IP}]: " INPUT_IP
  eval "ENV_IP_${ENV}=\"${INPUT_IP:-${DEFAULT_IP}}\""
done

read -rp "RAM (MB) [${DEFAULT_RAM}]: " INPUT_RAM
RAM="${INPUT_RAM:-${DEFAULT_RAM}}"

read -rp "Data disk (GB) [${DEFAULT_DATA_DISK}]: " INPUT_DISK
DATA_DISK="${INPUT_DISK:-${DEFAULT_DATA_DISK}}"

echo ""

# --- Add to config.yaml ---
# Build the YAML block to append
APP_YAML="  ${APP}:
    enabled: true
    node: ${NODE}
    ram: ${RAM}
    disk_size: ${DEFAULT_DISK}
    data_disk_size: ${DATA_DISK}
    backup: ${DEFAULT_BACKUP}
    monitor: ${DEFAULT_MONITOR}
    health_port: ${DEFAULT_HEALTH_PORT}
    health_path: \"${DEFAULT_HEALTH_PATH}\"
    environments:"

for ENV in $ENVS; do
  APP_YAML="${APP_YAML}
      ${ENV}:
        ip: $(eval echo \"\$ENV_IP_${ENV}\")
        mac: \"$(eval echo \"\$ENV_MAC_${ENV}\")\""
done

# Check if applications: block exists
if yq -e '.applications' "$CONFIG" >/dev/null 2>&1; then
  # Append to existing applications block using yq
  # Create a temp file with the new app entry
  TEMP_YAML=$(mktemp)
  cat > "$TEMP_YAML" <<YAMLEOF
enabled: true
node: ${NODE}
ram: ${RAM}
disk_size: ${DEFAULT_DISK}
data_disk_size: ${DATA_DISK}
backup: ${DEFAULT_BACKUP}
monitor: ${DEFAULT_MONITOR}
health_port: ${DEFAULT_HEALTH_PORT}
health_path: "${DEFAULT_HEALTH_PATH}"
environments:
YAMLEOF
  for ENV in $ENVS; do
    cat >> "$TEMP_YAML" <<YAMLEOF
  ${ENV}:
    ip: $(eval echo \"\$ENV_IP_${ENV}\")
    mac: "$(eval echo \"\$ENV_MAC_${ENV}\")"
YAMLEOF
  done

  yq -i ".applications.${APP} = load(\"${TEMP_YAML}\")" "$CONFIG"
  rm -f "$TEMP_YAML"
else
  echo "" >> "$CONFIG"
  echo "applications:" >> "$CONFIG"
  echo "$APP_YAML" >> "$CONFIG"
fi

echo "Added to site/config.yaml:"
echo "  applications.${APP}"
for ENV in $ENVS; do
  echo "    ${ENV}: IP $(eval echo \"\$ENV_IP_${ENV}\"), MAC $(eval echo \"\$ENV_MAC_${ENV}\")"
done
echo ""

# --- Generate host config ---
echo "Creating ${HOST_NIX}..."
cp "${CATALOG_DIR}/host.nix.template" "$HOST_NIX"

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
echo "Enabled: ${APP}"
echo ""
echo "Created:"
echo "  ${HOST_NIX}"
for f in "${CREATED_FILES[@]}"; do
  echo "  ${f}"
done

# --- DHCP reservation instructions ---
echo ""
echo "DHCP reservations needed (configure on your gateway):"
for ENV in $ENVS; do
  VLAN_ID=$(yq -r ".environments.${ENV}.vlan_id" "$CONFIG")
  echo "  VLAN ${VLAN_ID} (${ENV}): MAC $(eval echo \"\$ENV_MAC_${ENV}\") → IP $(eval echo \"\$ENV_IP_${ENV}\")"
done

# --- Next steps ---
echo ""
echo "DNS A records are auto-derived from config.yaml — no manual zone edits needed."
echo ""
echo "Next steps:"
echo "  1. Configure DHCP reservations on your gateway (see above)"

# App-specific config editing
for f in "${CREATED_FILES[@]}"; do
  fname="$(basename "$f")"
  echo "  3. Edit ${f} (replace CHANGEME values)"
done

echo "  4. Add secrets to SOPS:"
echo "     sops --set '[\"${APP}_admin_password\"] \"your-password\"' site/sops/secrets.yaml"

echo "  5. Add the flake output to flake.nix:"
echo "     ${APP}-image = mkImage [ ./site/nix/hosts/${APP}.nix ];"
echo "  6. Build: framework/scripts/build-image.sh site/nix/hosts/${APP}.nix ${APP}"
echo "  7. Deploy: framework/scripts/tofu-wrapper.sh apply -target=module.${APP}_dev"
echo ""

if [[ -f "${CATALOG_DIR}/README.md" ]]; then
  echo "See: framework/catalog/${APP}/README.md for full documentation"
fi
