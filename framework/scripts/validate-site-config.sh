#!/usr/bin/env bash
# validate-site-config.sh — Check site/config.yaml and site/applications.yaml for consistency.
#
# Validates:
#   - YAML syntax
#   - VMID uniqueness (across both files)
#   - IP uniqueness per environment (across both files)
#   - MAC uniqueness (across both files)
#   - Required pool presence and allowed values
#   - VMID range (5xx/6xx catalog apps, 7xx/8xx workstations)
#   - IPs within declared subnet
#   - Node references exist
#
# Usage:
#   framework/scripts/validate-site-config.sh
#
# Exit codes:
#   0 — all checks pass (no output)
#   1 — one or more checks failed (errors printed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${VALIDATE_SITE_CONFIG_CONFIG:-${REPO_DIR}/site/config.yaml}"
APPS_CONFIG="${VALIDATE_SITE_CONFIG_APPS_CONFIG:-${REPO_DIR}/site/applications.yaml}"

ERRORS=0

err() {
  echo "ERROR: $*" >&2
  ERRORS=$((ERRORS + 1))
}

valid_pool() {
  case "$1" in
    control-plane|prod|dev) return 0 ;;
    *) return 1 ;;
  esac
}

check_pool_stream() {
  local source_file="$1"
  local path pool

  while IFS=$'\t' read -r path pool; do
    [[ -z "$path" ]] && continue

    if [[ -z "$pool" || "$pool" == "null" ]]; then
      err "${source_file}: ${path} is missing required pool (expected control-plane, prod, or dev)"
      continue
    fi

    if ! valid_pool "$pool"; then
      err "${source_file}: ${path} has invalid pool '${pool}' (expected control-plane, prod, or dev)"
    fi
  done
}

# --- YAML syntax ---
if ! yq e '.' "$CONFIG" >/dev/null 2>&1; then
  err "site/config.yaml is not valid YAML"
  exit 1  # can't continue if config is unparseable
fi

if [[ -f "$APPS_CONFIG" ]]; then
  if ! yq e '.' "$APPS_CONFIG" >/dev/null 2>&1; then
    err "site/applications.yaml is not valid YAML"
    exit 1
  fi
fi

# --- GitHub remote URL (only required when publish.github.enabled is true) ---
PUBLISH_GITHUB_ENABLED="$(yq -r '.publish.github.enabled // false' "$CONFIG" 2>/dev/null || true)"
GITHUB_REMOTE_URL="$(yq -r '.github.remote_url // ""' "$CONFIG" 2>/dev/null || true)"
if [[ "$PUBLISH_GITHUB_ENABLED" == "true" ]]; then
  if [[ -z "$GITHUB_REMOTE_URL" || "$GITHUB_REMOTE_URL" == "null" ]]; then
    err "${CONFIG}: github.remote_url is required when publish.github.enabled is true"
  elif [[ ! "$GITHUB_REMOTE_URL" =~ ^git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]]; then
    err "${CONFIG}: github.remote_url must use SSH form git@github.com:<owner>/<repo>.git"
  fi
fi

# --- Collect all VMIDs, IPs, MACs from both files ---

# Infrastructure VMs from config.yaml
INFRA_VMIDS=$(yq -r '.vms | to_entries[] | "\(.key) \(.value.vmid)"' "$CONFIG" 2>/dev/null || true)
INFRA_IPS=$(yq -r '.vms | to_entries[] | "\(.key) \(.value.ip)"' "$CONFIG" 2>/dev/null || true)
INFRA_MACS=$(yq -r '.vms | to_entries[] | "\(.key) \(.value.mac)"' "$CONFIG" 2>/dev/null || true)

# Application VMs from applications.yaml
APP_DATA=""
if [[ -f "$APPS_CONFIG" ]]; then
  APP_DATA=$(yq -r '.applications // {} | to_entries[] | .key as $app |
    .value.environments // {} | to_entries[] |
    "\($app)_\(.key) \(.value.vmid // "null") \(.value.ip // "null") \(.value.mac // "null")"' "$APPS_CONFIG" 2>/dev/null || true)
fi

# Also check config.yaml for legacy app entries (migration period)
LEGACY_APP_DATA=""
LEGACY_APP_DATA=$(yq -r '.applications // {} | to_entries[] | .key as $app |
  .value.environments // {} | to_entries[] |
  "\($app)_\(.key) \(.value.vmid // "null") \(.value.ip // "null") \(.value.mac // "null")"' "$CONFIG" 2>/dev/null || true)

# --- Node references ---
VALID_NODES=$(yq -r '.nodes[].name' "$CONFIG" 2>/dev/null || true)

# Check infrastructure VM nodes
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  vm_key=$(echo "$line" | awk '{print $1}')
  node=$(echo "$line" | awk '{print $2}')
  [[ "$node" == "null" || -z "$node" ]] && continue
  if ! echo "$VALID_NODES" | grep -qw "$node"; then
    err "site/config.yaml: vms.${vm_key}.node '${node}' is not a valid node"
  fi
done < <(yq -r '.vms | to_entries[] | "\(.key) \(.value.node // "null")"' "$CONFIG" 2>/dev/null || true)

# Check application VM nodes
if [[ -f "$APPS_CONFIG" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    app_key=$(echo "$line" | awk '{print $1}')
    node=$(echo "$line" | awk '{print $2}')
    [[ "$node" == "null" || -z "$node" ]] && continue
    if ! echo "$VALID_NODES" | grep -qw "$node"; then
      err "site/applications.yaml: applications.${app_key}.node '${node}' is not a valid node"
    fi
  done < <(yq -r '.applications // {} | to_entries[] | "\(.key) \(.value.node // "null")"' "$APPS_CONFIG" 2>/dev/null || true)
fi

# --- Required pool values ---
check_pool_stream "site/config.yaml" < <(
  yq -r '.vms // {} | to_entries[] | [("vms." + .key + ".pool"), (.value.pool // "")] | @tsv' "$CONFIG" 2>/dev/null || true
)

if [[ -f "$APPS_CONFIG" ]]; then
  check_pool_stream "site/applications.yaml" < <(
    yq -r '.applications // {} | to_entries[] | .key as $app |
      (.value.environments // {}) | to_entries[] |
      [("applications." + $app + ".environments." + .key + ".pool"), (.value.pool // "")] | @tsv' "$APPS_CONFIG" 2>/dev/null || true
  )
fi

check_pool_stream "site/config.yaml (legacy applications)" < <(
  yq -r '.applications // {} | to_entries[] | .key as $app |
    (.value.environments // {}) | to_entries[] |
    [("applications." + $app + ".environments." + .key + ".pool"), (.value.pool // "")] | @tsv' "$CONFIG" 2>/dev/null || true
)

# --- VMID uniqueness ---
ALL_VMIDS=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  vmid=$(echo "$line" | awk '{print $2}')
  [[ "$vmid" == "null" || -z "$vmid" ]] && continue
  ALL_VMIDS="${ALL_VMIDS}${name} ${vmid} config.yaml\n"
done <<< "$INFRA_VMIDS"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  vmid=$(echo "$line" | awk '{print $2}')
  [[ "$vmid" == "null" || -z "$vmid" ]] && continue
  ALL_VMIDS="${ALL_VMIDS}${name} ${vmid} applications.yaml\n"
done <<< "$APP_DATA"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  vmid=$(echo "$line" | awk '{print $2}')
  [[ "$vmid" == "null" || -z "$vmid" ]] && continue
  ALL_VMIDS="${ALL_VMIDS}${name} ${vmid} config.yaml(legacy)\n"
done <<< "$LEGACY_APP_DATA"

# Check for duplicate VMIDs
DUP_VMIDS=$(echo -e "$ALL_VMIDS" | awk 'NF{print $2}' | sort | uniq -d || true)
while IFS= read -r dup; do
  [[ -z "$dup" ]] && continue
  owners=$(echo -e "$ALL_VMIDS" | grep " ${dup} " | awk '{print $1 "(" $3 ")"}' | tr '\n' ', ' | sed 's/,$//')
  err "Duplicate VMID ${dup}: ${owners}"
done <<< "$DUP_VMIDS"

# --- VMID range checks for application VMs ---
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  vmid=$(echo "$line" | awk '{print $2}')
  [[ "$vmid" == "null" || -z "$vmid" ]] && continue
  app_name=$(echo "$name" | sed 's/_[^_]*$//')
  env=$(echo "$name" | sed 's/.*_//')
  if [[ "$app_name" == "workstation" ]]; then
    if [[ "$env" == "prod" && ( "$vmid" -lt 800 || "$vmid" -gt 899 ) ]]; then
      err "site/applications.yaml: ${name} VMID ${vmid} not in prod workstation range (800-899)"
    elif [[ "$env" == "dev" && ( "$vmid" -lt 700 || "$vmid" -gt 799 ) ]]; then
      err "site/applications.yaml: ${name} VMID ${vmid} not in dev workstation range (700-799)"
    fi
  elif [[ "$env" == "prod" && ( "$vmid" -lt 600 || "$vmid" -gt 699 ) ]]; then
    err "site/applications.yaml: ${name} VMID ${vmid} not in prod app range (600-699)"
  elif [[ "$env" == "dev" && ( "$vmid" -lt 500 || "$vmid" -gt 599 ) ]]; then
    err "site/applications.yaml: ${name} VMID ${vmid} not in dev app range (500-599)"
  fi
done <<< "$APP_DATA"

# --- IP uniqueness per environment ---
# Collect all IPs with their environment
ALL_IPS=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  ip=$(echo "$line" | awk '{print $2}')
  [[ "$ip" == "null" || -z "$ip" ]] && continue
  # Determine environment from VM name
  if [[ "$name" == *_prod ]]; then env="prod"
  elif [[ "$name" == *_dev ]]; then env="dev"
  else env="shared"; fi
  ALL_IPS="${ALL_IPS}${name} ${ip} ${env} config.yaml\n"
done <<< "$INFRA_IPS"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  vmid=$(echo "$line" | awk '{print $2}')
  ip=$(echo "$line" | awk '{print $3}')
  [[ "$ip" == "null" || -z "$ip" ]] && continue
  env=$(echo "$name" | sed 's/.*_//')
  ALL_IPS="${ALL_IPS}${name} ${ip} ${env} applications.yaml\n"
done <<< "$APP_DATA"

# Check duplicates within each environment
for check_env in prod dev shared; do
  DUP_IPS=$(echo -e "$ALL_IPS" | grep " ${check_env} " | awk '{print $2}' | sort | uniq -d || true)
  while IFS= read -r dup; do
    [[ -z "$dup" ]] && continue
    owners=$(echo -e "$ALL_IPS" | grep " ${dup} ${check_env} " | awk '{print $1 "(" $4 ")"}' | tr '\n' ', ' | sed 's/,$//')
    err "Duplicate IP ${dup} in ${check_env}: ${owners}"
  done <<< "$DUP_IPS"
done

# --- MAC uniqueness ---
ALL_MACS=""
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  mac=$(echo "$line" | awk '{print $2}')
  [[ "$mac" == "null" || -z "$mac" ]] && continue
  ALL_MACS="${ALL_MACS}${name} ${mac} config.yaml\n"
done <<< "$INFRA_MACS"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  name=$(echo "$line" | awk '{print $1}')
  mac=$(echo "$line" | awk '{print $4}')
  [[ "$mac" == "null" || -z "$mac" ]] && continue
  ALL_MACS="${ALL_MACS}${name} ${mac} applications.yaml\n"
done <<< "$APP_DATA"

DUP_MACS=$(echo -e "$ALL_MACS" | awk 'NF{print $2}' | sort | uniq -d || true)
while IFS= read -r dup; do
  [[ -z "$dup" ]] && continue
  owners=$(echo -e "$ALL_MACS" | grep " ${dup} " | awk '{print $1 "(" $3 ")"}' | tr '\n' ', ' | sed 's/,$//')
  err "Duplicate MAC ${dup}: ${owners}"
done <<< "$DUP_MACS"

# --- IP subnet membership ---
if [[ -f "$APPS_CONFIG" ]]; then
  for env_name in $(yq -r '.environments | keys | .[]' "$CONFIG" 2>/dev/null); do
    SUBNET=$(yq -r ".environments.${env_name}.subnet" "$CONFIG")
    [[ "$SUBNET" == "null" || -z "$SUBNET" ]] && continue
    SUBNET_BASE=$(echo "$SUBNET" | sed 's/\.[0-9]*\/[0-9]*//')

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      name=$(echo "$line" | awk '{print $1}')
      ip=$(echo "$line" | awk '{print $3}')
      [[ "$ip" == "null" || -z "$ip" ]] && continue
      app_env=$(echo "$name" | sed 's/.*_//')
      [[ "$app_env" != "$env_name" ]] && continue
      ip_base=$(echo "$ip" | sed 's/\.[0-9]*$//')
      if [[ "$ip_base" != "$SUBNET_BASE" ]]; then
        err "site/applications.yaml: ${name} IP ${ip} not in ${env_name} subnet ${SUBNET}"
      fi
    done <<< "$APP_DATA"
  done
fi

# --- Result ---
if [[ $ERRORS -gt 0 ]]; then
  echo "${ERRORS} error(s) found" >&2
  exit 1
fi
