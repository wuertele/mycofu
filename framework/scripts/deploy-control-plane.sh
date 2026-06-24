#!/usr/bin/env bash
# deploy-control-plane.sh - Deploy control-plane closures built by build:image / merged by build:merge.
#
# Usage:
#   framework/scripts/deploy-control-plane.sh dev
#   framework/scripts/deploy-control-plane.sh prod
#   framework/scripts/deploy-control-plane.sh dev gitlab
#   framework/scripts/deploy-control-plane.sh dev cicd
#   framework/scripts/deploy-control-plane.sh dev --ensure-cicd-storage-only
#
# Exit codes:
#   0 - closures already current or deployed successfully
#   1 - deployment refused or failed
#   2 - usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
CLOSURE_PATHS_FILE="${REPO_DIR}/build/closure-paths.json"

SSH_OPTS=(
  -n
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

ROOT_DISK_RESIZED=0
ROOT_DISK_DESIRED_GB=0

log() {
  printf '%s\n' "$*"
}

die() {
  log "FATAL: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  framework/scripts/deploy-control-plane.sh dev
  framework/scripts/deploy-control-plane.sh prod
  framework/scripts/deploy-control-plane.sh dev gitlab
  framework/scripts/deploy-control-plane.sh dev cicd
  framework/scripts/deploy-control-plane.sh dev --ensure-cicd-storage-only
EOF
}

require_tools() {
  local tool=""

  for tool in jq ssh yq; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
      die "Required tool not found: ${tool}"
    fi
  done
}

require_common_files() {
  [[ -f "${CONFIG}" ]] || die "Config file not found: ${CONFIG}"
}

require_deploy_files() {
  require_common_files
  [[ -f "${APPS_CONFIG}" ]] || die "Applications config file not found: ${APPS_CONFIG}"
  [[ -f "${CLOSURE_PATHS_FILE}" ]] || die "Closure artifact not found: ${CLOSURE_PATHS_FILE}"
  [[ -x "${SCRIPT_DIR}/converge-vm.sh" ]] || die "converge-vm.sh not found or not executable"
}

host_ip() {
  local host="$1"
  local ip=""

  ip="$(yq -r ".vms.${host}.ip // \"\"" "${CONFIG}" 2>/dev/null || true)"
  if [[ -z "${ip}" || "${ip}" == "null" ]]; then
    return 1
  fi

  printf '%s\n' "${ip}"
}

closure_path_for_host() {
  local host="$1"
  local path=""

  path="$(jq -r --arg host "${host}" '.[$host] // empty' "${CLOSURE_PATHS_FILE}" 2>/dev/null || true)"
  if [[ -z "${path}" || "${path}" == "null" ]]; then
    return 1
  fi

  printf '%s\n' "${path}"
}

read_live_closure() {
  local ip="$1"
  local live=""

  set +e
  live="$(ssh "${SSH_OPTS[@]}" "root@${ip}" "readlink -f /run/current-system" 2>/dev/null)"
  local rc=$?
  set -e

  if [[ ${rc} -ne 0 || -z "${live}" ]]; then
    return 1
  fi

  printf '%s\n' "${live}"
}

host_vmid() {
  local host="$1"
  local vmid=""

  vmid="$(yq -r ".vms.${host}.vmid // \"\"" "${CONFIG}" 2>/dev/null || true)"
  if [[ -z "${vmid}" || "${vmid}" == "null" ]]; then
    return 1
  fi

  printf '%s\n' "${vmid}"
}

node_ip_for_name() {
  local node_name="$1"
  local node_ip=""

  node_ip="$(NODE="${node_name}" yq -r '.nodes[] | select(.name == strenv(NODE)) | .mgmt_ip // ""' "${CONFIG}" 2>/dev/null || true)"
  if [[ -z "${node_ip}" || "${node_ip}" == "null" ]]; then
    return 1
  fi

  printf '%s\n' "${node_ip}"
}

desired_cicd_root_disk_gb() {
  local desired=""

  desired="$(yq -r '.cicd.runner_disk_gb // 256' "${CONFIG}" 2>/dev/null || true)"
  if ! [[ "${desired}" =~ ^[0-9]+$ ]] || [[ "${desired}" -le 0 ]]; then
    printf 'ERROR: cicd: invalid cicd.runner_disk_gb in %s: %s\n' "${CONFIG}" "${desired}" >&2
    return 1
  elif [[ "${desired}" -lt 256 ]]; then
    printf 'ERROR: cicd: cicd.runner_disk_gb in %s must be at least 256: %s\n' "${CONFIG}" "${desired}" >&2
    return 1
  fi

  printf '%s\n' "${desired}"
}

cluster_resources_json() {
  local node_count=""
  local node_ip=""
  local result=""
  local rc=0
  local i=0

  node_count="$(yq -r '.nodes | length // 0' "${CONFIG}" 2>/dev/null || true)"
  if ! [[ "${node_count}" =~ ^[0-9]+$ ]] || [[ "${node_count}" -le 0 ]]; then
    return 1
  fi

  for (( i=0; i<node_count; i++ )); do
    node_ip="$(yq -r ".nodes[${i}].mgmt_ip // \"\"" "${CONFIG}" 2>/dev/null || true)"
    [[ -n "${node_ip}" && "${node_ip}" != "null" ]] || continue

    set +e
    result="$(ssh "${SSH_OPTS[@]}" "root@${node_ip}" \
      "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null)"
    rc=$?
    set -e

    if [[ ${rc} -eq 0 ]] && jq -e 'type == "array" and length > 0' <<< "${result}" >/dev/null 2>&1; then
      printf '%s\n' "${result}"
      return 0
    fi
  done

  return 1
}

hosting_node_for_vmid() {
  local resources="$1"
  local vmid="$2"

  jq -r --argjson vmid "${vmid}" \
    'first(.[]? | select((.type // "") == "qemu" and .vmid == $vmid) | .node) // empty' \
    <<< "${resources}"
}

read_root_disk_size() {
  local node_ip="$1"
  local vmid="$2"
  local size=""
  local rc=0

  set +e
  size="$(ssh "${SSH_OPTS[@]}" "root@${node_ip}" \
    "qm config ${vmid} 2>/dev/null | awk -F 'size=' '/^scsi0:/{split(\$2,a,\",\"); print a[1]; exit}'" 2>/dev/null)"
  rc=$?
  set -e

  if [[ ${rc} -ne 0 || -z "${size}" ]]; then
    return 1
  fi

  printf '%s\n' "${size}"
}

read_guest_nix_size_gb() {
  local ip="$1"
  local size=""
  local rc=0

  set +e
  size="$(ssh "${SSH_OPTS[@]}" "root@${ip}" \
    "df -BG /nix 2>/dev/null | awk 'NR==2 {gsub(/G/,\"\",\$2); print \$2}'" 2>/dev/null)"
  rc=$?
  set -e

  if [[ ${rc} -ne 0 || -z "${size}" ]]; then
    return 1
  fi
  if ! [[ "${size}" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  printf '%s\n' "${size}"
}

read_boot_id() {
  local ip="$1"
  local boot_id=""
  local rc=0

  set +e
  boot_id="$(ssh "${SSH_OPTS[@]}" "root@${ip}" "cat /proc/sys/kernel/random/boot_id" 2>/dev/null)"
  rc=$?
  set -e

  if [[ ${rc} -ne 0 || -z "${boot_id}" ]]; then
    return 1
  fi

  printf '%s\n' "${boot_id}"
}

disk_size_to_gb() {
  local size="$1"

  awk -v size="${size}" '
    BEGIN {
      unit = substr(size, length(size), 1)
      if (unit ~ /[KMGTP]/) {
        value = substr(size, 1, length(size) - 1)
      } else {
        unit = "G"
        value = size
      }
      if (value !~ /^[0-9]+([.][0-9]+)?$/) {
        exit 1
      }
      if (unit == "K") {
        gb = value / 1024 / 1024
      } else if (unit == "M") {
        gb = value / 1024
      } else if (unit == "G") {
        gb = value
      } else if (unit == "T") {
        gb = value * 1024
      } else if (unit == "P") {
        gb = value * 1024 * 1024
      } else {
        exit 1
      }
      printf "%.6f\n", gb
    }
  '
}

size_less_than() {
  local current_gb="$1"
  local desired_gb="$2"

  awk -v current="${current_gb}" -v desired="${desired_gb}" \
    'BEGIN { exit((current + 0) < (desired + 0) ? 0 : 1) }'
}

guest_nix_smaller_than_desired() {
  local current_gb="$1"
  local desired_gb="$2"

  awk -v current="${current_gb}" -v desired="${desired_gb}" \
    'BEGIN { exit((current + 8) < desired ? 0 : 1) }'
}

resize_root_disk() {
  local node_ip="$1"
  local vmid="$2"
  local desired_gb="$3"

  ssh "${SSH_OPTS[@]}" "root@${node_ip}" "qm resize ${vmid} scsi0 ${desired_gb}G"
}

wait_for_live_closure() {
  local ip="$1"
  local expected="$2"
  local previous_boot_id="$3"
  local timeout="${ROOT_DISK_REBOOT_TIMEOUT:-300}"
  local interval="${ROOT_DISK_REBOOT_INTERVAL:-5}"
  local elapsed=0
  local boot_id=""
  local live=""

  while [[ ${elapsed} -lt ${timeout} ]]; do
    if boot_id="$(read_boot_id "${ip}" 2>/dev/null)" && \
       [[ "${boot_id}" != "${previous_boot_id}" ]] && \
       live="$(read_live_closure "${ip}" 2>/dev/null)" && \
       [[ "${live}" == "${expected}" ]]; then
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  return 1
}

wait_for_boot_id_change() {
  local ip="$1"
  local previous_boot_id="$2"
  local timeout="${ROOT_DISK_REBOOT_TIMEOUT:-300}"
  local interval="${ROOT_DISK_REBOOT_INTERVAL:-5}"
  local elapsed=0
  local boot_id=""

  while [[ ${elapsed} -lt ${timeout} ]]; do
    if boot_id="$(read_boot_id "${ip}" 2>/dev/null)" && \
       [[ "${boot_id}" != "${previous_boot_id}" ]]; then
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  return 1
}

reboot_after_root_disk_resize() {
  local host="$1"
  local ip="$2"
  local built="$3"
  local desired_gb="$4"
  local previous_boot_id=""

  log "${host}: live closure matches built, rebooting after root disk resize"
  previous_boot_id="$(read_boot_id "${ip}")" \
    || die "${host}: failed to read boot ID before root disk resize reboot"
  ssh "${SSH_OPTS[@]}" "root@${ip}" "reboot" >/dev/null 2>&1 || true
  sleep 5
  wait_for_live_closure "${ip}" "${built}" "${previous_boot_id}" \
    || die "${host}: failed to verify live closure after root disk resize reboot"
  verify_guest_nix_after_root_disk_resize "${host}" "${ip}" "${desired_gb}"
  log "${host}: reboot after root disk resize completed"
}

reboot_after_root_disk_resize_storage_only() {
  local host="$1"
  local ip="$2"
  local desired_gb="$3"
  local previous_boot_id=""

  log "${host}: rebooting after root disk resize so growfs-root can expand /nix before heavy builds"
  previous_boot_id="$(read_boot_id "${ip}")" \
    || die "${host}: failed to read boot ID before root disk resize reboot"
  ssh "${SSH_OPTS[@]}" "root@${ip}" "reboot" >/dev/null 2>&1 || true
  sleep 5
  wait_for_boot_id_change "${ip}" "${previous_boot_id}" \
    || die "${host}: failed to verify reboot after root disk resize"
  verify_guest_nix_after_root_disk_resize "${host}" "${ip}" "${desired_gb}"
  log "${host}: storage-only root disk resize reboot completed"
}

verify_guest_nix_after_root_disk_resize() {
  local host="$1"
  local ip="$2"
  local desired_gb="$3"
  local guest_nix_gb=""

  guest_nix_gb="$(read_guest_nix_size_gb "${ip}")" \
    || die "${host}: failed to read guest /nix filesystem size after root disk resize reboot"
  if guest_nix_smaller_than_desired "${guest_nix_gb}" "${desired_gb}"; then
    die "${host}: guest /nix filesystem is still ${guest_nix_gb}G after root disk resize reboot, below desired ${desired_gb}G"
  fi
  log "${host}: guest /nix filesystem is ${guest_nix_gb}G after root disk resize reboot"
}

ensure_cicd_storage_only() {
  local env_name="$1"
  local ip=""

  ip="$(host_ip cicd)" || die "cicd: failed to resolve IP from ${CONFIG}"
  ensure_root_disk_size "${env_name}" cicd "${ip}" || return 1
  if [[ "${ROOT_DISK_RESIZED}" -eq 1 ]]; then
    reboot_after_root_disk_resize_storage_only cicd "${ip}" "${ROOT_DISK_DESIRED_GB}"
  else
    log "cicd: storage already satisfies desired root disk size"
  fi
}

ensure_root_disk_size() {
  local env_name="$1"
  local host="$2"
  local ip="$3"
  local desired_gb=""
  local vmid=""
  local resources=""
  local hosting_node=""
  local node_ip=""
  local current_size=""
  local current_gb=""
  local guest_nix_gb=""

  ROOT_DISK_RESIZED=0
  ROOT_DISK_DESIRED_GB=0
  [[ "${host}" == "cicd" ]] || return 0

  desired_gb="$(desired_cicd_root_disk_gb)" \
    || die "${host}: failed to resolve desired root disk size"
  ROOT_DISK_DESIRED_GB="${desired_gb}"
  vmid="$(host_vmid "${host}")" || die "${host}: failed to resolve VMID from ${CONFIG}"
  if ! [[ "${vmid}" =~ ^[0-9]+$ ]]; then
    die "${host}: invalid VMID in ${CONFIG}: ${vmid}"
  fi

  resources="$(cluster_resources_json)" \
    || die "${host}: failed to query Proxmox cluster resources for root disk sizing"
  hosting_node="$(hosting_node_for_vmid "${resources}" "${vmid}")"
  [[ -n "${hosting_node}" ]] || die "${host}: VMID ${vmid} not found in Proxmox cluster resources"
  node_ip="$(node_ip_for_name "${hosting_node}")" \
    || die "${host}: failed to resolve current Proxmox node ${hosting_node} from ${CONFIG}"
  current_size="$(read_root_disk_size "${node_ip}" "${vmid}")" \
    || die "${host}: failed to read scsi0 size for VMID ${vmid} on ${hosting_node}"
  current_gb="$(disk_size_to_gb "${current_size}")" \
    || die "${host}: unsupported scsi0 size '${current_size}' for VMID ${vmid}"

  if size_less_than "${current_gb}" "${desired_gb}"; then
    if [[ "${env_name}" == "prod" ]]; then
      log "${host}: refusing: root disk is ${current_size}, below desired ${desired_gb}G"
      log "${host}: dev pipeline should have resized the runner before prod promotion"
      return 1
    fi

    log "${host}: root disk is ${current_size} on ${hosting_node}, resizing to ${desired_gb}G"
    resize_root_disk "${node_ip}" "${vmid}" "${desired_gb}" \
      || die "${host}: qm resize failed for VMID ${vmid} on ${hosting_node}"
    ROOT_DISK_RESIZED=1
    log "${host}: root disk resize requested; deploy will reboot so growfs-root can expand the filesystem"
  else
    guest_nix_gb="$(read_guest_nix_size_gb "${ip}")" \
      || die "${host}: failed to read guest /nix filesystem size from ${ip}"
    if guest_nix_smaller_than_desired "${guest_nix_gb}" "${desired_gb}"; then
      if [[ "${env_name}" == "prod" ]]; then
        log "${host}: refusing: guest /nix filesystem is ${guest_nix_gb}G, below desired ${desired_gb}G"
        log "${host}: dev pipeline should have rebooted the runner after root disk resize before prod promotion"
        return 1
      fi

      ROOT_DISK_RESIZED=1
      log "${host}: root disk ${current_size} on ${hosting_node} satisfies desired ${desired_gb}G"
      log "${host}: guest /nix filesystem is ${guest_nix_gb}G; deploy will reboot so growfs-root can expand it"
    else
      log "${host}: root disk ${current_size} on ${hosting_node} and guest /nix ${guest_nix_gb}G satisfy desired ${desired_gb}G"
    fi
  fi
}

validate_closure_artifact() {
  jq -e '
    type == "object"
    and has("gitlab")
    and has("cicd")
    and (.gitlab | type == "string" and length > 0)
    and (.cicd | type == "string" and length > 0)
  ' "${CLOSURE_PATHS_FILE}" >/dev/null 2>&1 \
    || die "Invalid closure artifact: ${CLOSURE_PATHS_FILE}"
}

deploy_host() {
  local env_name="$1"
  local host="$2"
  local ip=""
  local built=""
  local live=""

  built="$(closure_path_for_host "${host}")" \
    || die "${host}: closure path missing from ${CLOSURE_PATHS_FILE}"
  [[ -e "${built}" ]] || die "${host}: built closure missing from local store: ${built}"

  ip="$(host_ip "${host}")" || die "${host}: failed to resolve IP from ${CONFIG}"
  live="$(read_live_closure "${ip}")" || die "${host}: failed to read live closure from ${ip}"
  ensure_root_disk_size "${env_name}" "${host}" "${ip}" || return 1

  if [[ "${live}" == "${built}" && "${ROOT_DISK_RESIZED}" -eq 0 ]]; then
    log "${host}: live closure matches built, skipping"
    return 0
  fi

  if [[ "${live}" == "${built}" && "${ROOT_DISK_RESIZED}" -eq 1 ]]; then
    reboot_after_root_disk_resize "${host}" "${ip}" "${built}" "${ROOT_DISK_DESIRED_GB}"
    return 0
  fi

  if [[ "${env_name}" == "prod" ]]; then
    log "${host}: refusing: dev pipeline should have deployed first"
    log "${host}: live=${live}"
    log "${host}: built=${built}"
    return 1
  fi

  log "${host}: live closure differs from built, deploying"
  log "${host}: live=${live}"
  log "${host}: built=${built}"

  # --closure-only: push closure + reboot + verify, no Steps 8-15.
  # Full convergence is handled by post-deploy.sh for data-plane and is
  # not needed for control-plane closure pushes. Running converge_run_all
  # here would restart the runner (Step 14) and kill this pipeline job.
  set +e
  "${SCRIPT_DIR}/converge-vm.sh" \
    --repo-dir "${REPO_DIR}" \
    --config "${CONFIG}" \
    --apps-config "${APPS_CONFIG}" \
    --closure "${built}" \
    --closure-only \
    --targets "-target=module.${host}"
  local rc=$?
  set -e

  if [[ ${rc} -ne 0 ]]; then
    log "${host}: converge-vm.sh failed with exit ${rc}"
    return 1
  fi

  log "${host}: converge-vm.sh completed"
  if [[ "${host}" == "cicd" && "${ROOT_DISK_RESIZED}" -eq 1 ]]; then
    verify_guest_nix_after_root_disk_resize "${host}" "${ip}" "${ROOT_DISK_DESIRED_GB}"
  fi
}

verify_final_state() {
  local host=""
  local ip=""
  local built=""
  local live=""

  for host in "$@"; do
    built="$(closure_path_for_host "${host}")" \
      || die "${host}: closure path missing during final verification"
    ip="$(host_ip "${host}")" || die "${host}: failed to resolve IP during final verification"
    live="$(read_live_closure "${ip}")" || die "${host}: failed to read live closure during final verification"

    if [[ "${live}" != "${built}" ]]; then
      die "${host}: final verification mismatch: live=${live} built=${built}"
    fi

    log "${host}: final verification OK"
  done
}

main() {
  local env_name="${1:-}"
  shift || true
  local host=""
  local storage_only=0
  local selected_hosts=()

  case "${env_name}" in
    dev|prod) ;;
    --help|-h)
      usage
      exit 0
      ;;
    "")
      usage >&2
      exit 2
      ;;
    *)
      printf 'ERROR: Unknown environment: %s\n' "${env_name}" >&2
      usage >&2
      exit 2
      ;;
  esac

  require_tools
  if [[ "${1:-}" == "--ensure-cicd-storage-only" ]]; then
    storage_only=1
    shift
  fi
  if [[ "${storage_only}" -eq 1 && $# -gt 0 ]]; then
    printf 'ERROR: --ensure-cicd-storage-only does not accept host arguments\n' >&2
    usage >&2
    exit 2
  fi

  if [[ "${storage_only}" -eq 1 ]]; then
    require_common_files
    ensure_cicd_storage_only "${env_name}"
    return 0
  fi

  require_deploy_files
  validate_closure_artifact

  if [[ $# -eq 0 ]]; then
    selected_hosts=(gitlab cicd)
  else
    for host in "$@"; do
      case "${host}" in
        gitlab|cicd)
          selected_hosts+=("${host}")
          ;;
        *)
          printf 'ERROR: Unknown control-plane host: %s\n' "${host}" >&2
          usage >&2
          exit 2
          ;;
      esac
    done
  fi

  for host in "${selected_hosts[@]}"; do
    deploy_host "${env_name}" "${host}"
  done

  verify_final_state "${selected_hosts[@]}"
}

main "$@"
