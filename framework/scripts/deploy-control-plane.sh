#!/usr/bin/env bash
# deploy-control-plane.sh - Deploy control-plane closures built by build:image / merged by build:merge.
#
# Usage:
#   framework/scripts/deploy-control-plane.sh dev
#   framework/scripts/deploy-control-plane.sh prod
#   framework/scripts/deploy-control-plane.sh dev gitlab
#   framework/scripts/deploy-control-plane.sh dev cicd
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

require_files() {
  [[ -f "${CONFIG}" ]] || die "Config file not found: ${CONFIG}"
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

  if [[ "${live}" == "${built}" ]]; then
    log "${host}: live closure matches built, skipping"
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
  require_files
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
