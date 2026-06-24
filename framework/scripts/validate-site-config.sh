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

valid_positive_int() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

valid_ipv4() {
  local ip="${1:-}" part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a parts <<< "$ip"
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]+$ ]] || return 1
    (( part >= 0 && part <= 255 )) || return 1
  done
}

valid_sops_key_name() {
  [[ "${1:-}" =~ ^[A-Za-z0-9_.-]+$ ]]
}

valid_boolean_text() {
  [[ "${1:-}" == "true" || "${1:-}" == "false" ]]
}

valid_nonempty_text() {
  [[ -n "${1:-}" && "${1:-}" != "null" ]]
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

# --- CI/CD runner sizing schema ---
CICD_RUNNER_DISK_GB="$(yq -r '.cicd.runner_disk_gb // ""' "$CONFIG" 2>/dev/null || true)"
if [[ -n "$CICD_RUNNER_DISK_GB" && "$CICD_RUNNER_DISK_GB" != "null" ]] && ! valid_positive_int "$CICD_RUNNER_DISK_GB"; then
  err "${CONFIG}: cicd.runner_disk_gb must be a positive integer"
elif [[ -n "$CICD_RUNNER_DISK_GB" && "$CICD_RUNNER_DISK_GB" != "null" && "$CICD_RUNNER_DISK_GB" -lt 256 ]]; then
  err "${CONFIG}: cicd.runner_disk_gb must be at least 256"
fi

# --- Scheduled benchmark schema ---
# The GitLab schedule is configured in GitLab UI (clickops) per OPERATIONS.md.
# This validator only enforces site-level opt-in and the orchestrator's runtime
# configuration. The bench:scheduled job's in-script gate enforces the opt-in
# at CI execution time.
BENCH_SCHEDULED_ENABLED="$(yq -r '.benchmarks.scheduled.enabled // false' "$CONFIG" 2>/dev/null || true)"
SCHEDULE_VALID_NODES="$(yq -r '.nodes[].name' "$CONFIG" 2>/dev/null || true)"

if ! valid_boolean_text "$BENCH_SCHEDULED_ENABLED"; then
  err "${CONFIG}: benchmarks.scheduled.enabled must be a boolean"
fi

if [[ "$BENCH_SCHEDULED_ENABLED" == "true" ]]; then
  BENCH_HOSTS_TAG="$(yq -r '(.benchmarks.scheduled.hosts // []) | tag' "$CONFIG" 2>/dev/null || true)"
  if [[ "$BENCH_HOSTS_TAG" != "!!seq" ]]; then
    err "${CONFIG}: benchmarks.scheduled.hosts must be a list"
  fi
  BENCH_HOST_COUNT="$(yq -r '.benchmarks.scheduled.hosts // [] | length' "$CONFIG" 2>/dev/null || echo 0)"
  if [[ "$BENCH_HOST_COUNT" -lt 1 ]]; then
    err "${CONFIG}: benchmarks.scheduled.hosts must be non-empty when scheduled benchmarks are enabled"
  fi
  while IFS= read -r bench_host; do
    [[ -n "$bench_host" ]] || continue
    if ! grep -Fxq "$bench_host" <<< "$SCHEDULE_VALID_NODES"; then
      err "${CONFIG}: benchmarks.scheduled.hosts entry '${bench_host}' is not a valid nodes[].name"
    fi
  done < <(yq -r '.benchmarks.scheduled.hosts // [] | .[]' "$CONFIG" 2>/dev/null || true)
fi

BENCH_SUITE="$(yq -r '.benchmarks.scheduled.suite // "synthetic"' "$CONFIG" 2>/dev/null || true)"
case "$BENCH_SUITE" in
  synthetic|full|synthetic-weekly-full) ;;
  *) err "${CONFIG}: benchmarks.scheduled.suite must be synthetic, full, or synthetic-weekly-full" ;;
esac
BENCH_FULL_DAY="$(yq -r '.benchmarks.scheduled.full_day // "sunday"' "$CONFIG" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
case "$BENCH_FULL_DAY" in
  monday|tuesday|wednesday|thursday|friday|saturday|sunday) ;;
  *) err "${CONFIG}: benchmarks.scheduled.full_day must be a weekday name" ;;
esac

timeout_value="$(yq -r '.benchmarks.scheduled.host_timeout_sec // ""' "$CONFIG" 2>/dev/null || true)"
if [[ -n "$timeout_value" && "$timeout_value" != "null" ]] && ! valid_positive_int "$timeout_value"; then
  err "${CONFIG}: benchmarks.scheduled.host_timeout_sec must be a positive integer"
fi

# --- Regreener schema ---
REGREENER_INSTALL_TIMEOUT="$(yq -r '.regreener.install_timeout_sec // ""' "$CONFIG" 2>/dev/null || true)"
REGREENER_SSH_TIMEOUT="$(yq -r '.regreener.ssh_timeout_sec // ""' "$CONFIG" 2>/dev/null || true)"
if [[ -n "$REGREENER_INSTALL_TIMEOUT" && "$REGREENER_INSTALL_TIMEOUT" != "null" ]] && ! valid_positive_int "$REGREENER_INSTALL_TIMEOUT"; then
  err "${CONFIG}: regreener.install_timeout_sec must be a positive integer"
fi
if [[ -n "$REGREENER_SSH_TIMEOUT" && "$REGREENER_SSH_TIMEOUT" != "null" ]] && ! valid_positive_int "$REGREENER_SSH_TIMEOUT"; then
  err "${CONFIG}: regreener.ssh_timeout_sec must be a positive integer"
fi

HIL_BOOT_PRESENT="$(yq -r 'has("vms") and (.vms | has("hil_boot"))' "$CONFIG" 2>/dev/null || true)"
if [[ "$HIL_BOOT_PRESENT" == "true" ]]; then
  HIL_BOOT_VMID="$(yq -r '.vms.hil_boot.vmid // ""' "$CONFIG" 2>/dev/null || true)"
  HIL_BOOT_IP="$(yq -r '.vms.hil_boot.ip // ""' "$CONFIG" 2>/dev/null || true)"
  HIL_BOOT_MAC="$(yq -r '.vms.hil_boot.mac // ""' "$CONFIG" 2>/dev/null || true)"
  HIL_BOOT_POOL="$(yq -r '.vms.hil_boot.pool // ""' "$CONFIG" 2>/dev/null || true)"
  HIL_BOOT_BACKUP="$(yq -r '.vms.hil_boot.backup // false' "$CONFIG" 2>/dev/null || true)"

  if ! valid_positive_int "$HIL_BOOT_VMID"; then
    err "${CONFIG}: vms.hil_boot.vmid must be a positive integer"
  fi
  if ! valid_ipv4 "$HIL_BOOT_IP"; then
    err "${CONFIG}: vms.hil_boot.ip must be a valid IPv4 address"
  fi
  if [[ ! "$HIL_BOOT_MAC" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]]; then
    err "${CONFIG}: vms.hil_boot.mac must be a MAC address"
  fi
  if [[ "$HIL_BOOT_POOL" != "control-plane" ]]; then
    err "${CONFIG}: vms.hil_boot.pool must be control-plane"
  fi
  if [[ "$HIL_BOOT_BACKUP" == "true" ]]; then
    err "${CONFIG}: vms.hil_boot must not set backup: true"
  fi
fi

INSTALLER_SHA="$(yq -r '.proxmox.installer.iso_sha256 // ""' "$CONFIG" 2>/dev/null || true)"
if [[ -n "$INSTALLER_SHA" && "$INSTALLER_SHA" != "null" && ! "$INSTALLER_SHA" =~ ^[A-Fa-f0-9]{64}$ ]]; then
  err "${CONFIG}: proxmox.installer.iso_sha256 must be a 64-character hex string"
fi

DEFAULT_INSTALL_FS="$(yq -r '.proxmox.installer.filesystem // "ext4"' "$CONFIG" 2>/dev/null || true)"
case "$DEFAULT_INSTALL_FS" in
  ext4|zfs) ;;
  *) err "${CONFIG}: proxmox.installer.filesystem must be ext4 or zfs" ;;
esac

AMT_REFS=""
while IFS=$'\t' read -r node_idx node_name enabled amt_ip amt_user amt_ref nic_driver disk_path node_fs; do
  [[ -z "$node_idx" ]] && continue
  node_label="nodes[${node_idx}]"
  [[ -n "$node_name" && "$node_name" != "null" ]] && node_label="node ${node_name}"

  if [[ -n "$node_fs" && "$node_fs" != "null" ]]; then
    case "$node_fs" in
      ext4|zfs) ;;
      *) err "${CONFIG}: ${node_label} install_filesystem must be ext4 or zfs" ;;
    esac
  fi

  [[ "$enabled" == "true" ]] || continue

  if [[ -z "$amt_ip" || "$amt_ip" == "null" ]]; then
    err "${CONFIG}: ${node_label} has regreen_enabled=true but missing amt_ip"
  elif ! valid_ipv4 "$amt_ip"; then
    err "${CONFIG}: ${node_label} amt_ip '${amt_ip}' is not a valid IPv4 address"
  fi

  if [[ -z "$amt_user" || "$amt_user" == "null" ]]; then
    err "${CONFIG}: ${node_label} has regreen_enabled=true but missing amt_user"
  fi

  if [[ -z "$amt_ref" || "$amt_ref" == "null" ]]; then
    err "${CONFIG}: ${node_label} has regreen_enabled=true but missing amt_password_ref"
  elif ! valid_sops_key_name "$amt_ref"; then
    err "${CONFIG}: ${node_label} amt_password_ref '${amt_ref}' is not a safe SOPS key name"
  else
    AMT_REFS="${AMT_REFS}${amt_ref}"$'\n'
  fi

  if [[ -z "$nic_driver" || "$nic_driver" == "null" ]]; then
    err "${CONFIG}: ${node_label} has regreen_enabled=true but missing install_nic_driver"
  fi

  if [[ -z "$disk_path" || "$disk_path" == "null" ]]; then
    err "${CONFIG}: ${node_label} has regreen_enabled=true but missing install_disk_id_path"
  fi
done < <(yq -r '.nodes // [] | to_entries[] |
  [
    .key,
    (.value.name // ""),
    (.value.regreen_enabled // false),
    (.value.amt_ip // ""),
    (.value.amt_user // "admin"),
    (.value.amt_password_ref // ""),
    (.value.install_nic_driver // ""),
    (.value.install_disk_id_path // ""),
    (.value.install_filesystem // "")
  ] | @tsv' "$CONFIG" 2>/dev/null || true)

SOPS_PATH="$(dirname "$CONFIG")/sops/secrets.yaml"
if [[ -n "$AMT_REFS" && -f "$SOPS_PATH" && "$(command -v sops || true)" != "" ]]; then
  if sops -d "$SOPS_PATH" >/dev/null 2>&1; then
    while IFS= read -r amt_ref; do
      [[ -z "$amt_ref" ]] && continue
      if ! value="$(sops -d --extract "[\"${amt_ref}\"]" "$SOPS_PATH" 2>/dev/null)" || [[ -z "$value" || "$value" == "null" ]]; then
        err "${CONFIG}: referenced AMT SOPS key '${amt_ref}' is missing or empty in ${SOPS_PATH}"
      fi
    done < <(printf '%s' "$AMT_REFS" | sort -u)
  fi
fi

# --- HIL PDU schema ---
PDU_PRESENT="$(yq -r 'has("pdu")' "$CONFIG" 2>/dev/null || true)"
PDU_REF=""
if [[ "$PDU_PRESENT" == "true" ]]; then
  PDU_HOST="$(yq -r '.pdu.host // ""' "$CONFIG" 2>/dev/null || true)"
  PDU_USER="$(yq -r '.pdu.user // ""' "$CONFIG" 2>/dev/null || true)"
  PDU_REF="$(yq -r '.pdu.password_ref // ""' "$CONFIG" 2>/dev/null || true)"

  if ! valid_nonempty_text "$PDU_HOST"; then
    err "${CONFIG}: pdu.host is required when pdu is configured"
  fi
  if ! valid_nonempty_text "$PDU_USER"; then
    err "${CONFIG}: pdu.user is required when pdu is configured"
  fi
  if ! valid_nonempty_text "$PDU_REF"; then
    err "${CONFIG}: pdu.password_ref is required when pdu is configured"
  elif ! valid_sops_key_name "$PDU_REF"; then
    err "${CONFIG}: pdu.password_ref '${PDU_REF}' is not a safe SOPS key name"
  fi

  PDU_OUTLETS=""
  while IFS=$'\t' read -r node_idx node_name enabled outlet; do
    [[ -z "$node_idx" ]] && continue
    node_label="nodes[${node_idx}]"
    [[ -n "$node_name" && "$node_name" != "null" ]] && node_label="node ${node_name}"

    if [[ "$enabled" == "true" ]]; then
      if [[ -z "$outlet" || "$outlet" == "null" ]]; then
        err "${CONFIG}: ${node_label} has regreen_enabled=true but missing pdu_outlet"
        continue
      fi
    fi

    [[ -z "$outlet" || "$outlet" == "null" ]] && continue
    if ! valid_positive_int "$outlet"; then
      err "${CONFIG}: ${node_label} pdu_outlet must be a positive integer"
      continue
    fi
    PDU_OUTLETS="${PDU_OUTLETS}${node_label} ${outlet}"$'\n'
  done < <(yq -r '.nodes // [] | to_entries[] |
    [
      .key,
      (.value.name // ""),
      (.value.regreen_enabled // false),
      (.value.pdu_outlet // "")
    ] | @tsv' "$CONFIG" 2>/dev/null || true)

  DUP_PDU_OUTLETS="$(printf '%s' "$PDU_OUTLETS" | awk 'NF{print $NF}' | sort | uniq -d || true)"
  while IFS= read -r dup; do
    [[ -z "$dup" ]] && continue
    owners="$(printf '%s' "$PDU_OUTLETS" | awk -v outlet="$dup" '$NF == outlet {sub(/[[:space:]][^[:space:]]+$/, ""); print}' | paste -sd ', ' -)"
    err "${CONFIG}: duplicate pdu_outlet ${dup}: ${owners}"
  done <<< "$DUP_PDU_OUTLETS"

  if [[ -n "$PDU_REF" && -f "$SOPS_PATH" && "$(command -v sops || true)" != "" ]]; then
    if sops -d "$SOPS_PATH" >/dev/null 2>&1; then
      if ! value="$(sops -d --extract "[\"${PDU_REF}\"]" "$SOPS_PATH" 2>/dev/null)" || [[ -z "$value" || "$value" == "null" ]]; then
        err "${CONFIG}: referenced PDU SOPS key '${PDU_REF}' is missing or empty in ${SOPS_PATH}"
      fi
    fi
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
