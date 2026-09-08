#!/usr/bin/env bash
# deploy-workstation-closure.sh — Push the desired closure to the workstation VM.
#
# Usage:
#   framework/scripts/deploy-workstation-closure.sh dev
#   framework/scripts/deploy-workstation-closure.sh prod

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
CONFIG="${REPO_DIR}/site/config.yaml"

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
  framework/scripts/deploy-workstation-closure.sh dev
  framework/scripts/deploy-workstation-closure.sh prod
EOF
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

main() {
  local env_name="${1:-}"
  local host="workstation_${env_name}"
  local ip=""
  local built=""
  local live=""

  case "${env_name}" in
    dev|prod) ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac

  [[ -f "${APPS_CONFIG}" ]] || die "Applications config file not found: ${APPS_CONFIG}"
  [[ -f "${CONFIG}" ]] || die "Config file not found: ${CONFIG}"
  [[ -x "${SCRIPT_DIR}/converge-vm.sh" ]] || die "converge-vm.sh not found or not executable"

  if [[ "$(yq -r '.applications.workstation.enabled // false' "${APPS_CONFIG}" 2>/dev/null || true)" != "true" ]]; then
    log "workstation disabled in applications.yaml, skipping"
    exit 0
  fi

  ip="$(yq -r ".applications.workstation.environments.${env_name}.mgmt_nic.ip // .applications.workstation.environments.${env_name}.ip // \"\"" "${APPS_CONFIG}" 2>/dev/null || true)"
  [[ -n "${ip}" && "${ip}" != "null" ]] || die "workstation_${env_name}: failed to resolve IP from ${APPS_CONFIG}"

  mkdir -p "${REPO_DIR}/build"

  # Trade-off: build the workstation closure in the env deploy job instead of
  # extending the shared control-plane closure artifact. That duplicates one
  # nix build, but it keeps env-scoped workstation convergence coupled to the
  # env deploy path without broadening the gitlab/cicd artifact contract.
  built="$(
    nix build \
      --print-out-paths \
      --out-link "${REPO_DIR}/build/closure-${host}" \
      ".#nixosConfigurations.${host}.config.system.build.toplevel"
  )"
  [[ -n "${built}" ]] || die "${host}: nix build did not return a closure path"
  [[ -e "${built}" ]] || die "${host}: built closure missing from local store: ${built}"

  live="$(read_live_closure "${ip}")" || die "${host}: failed to read live closure from ${ip}"
  if [[ "${live}" == "${built}" ]]; then
    log "${host}: live closure matches built, skipping"
    return 0
  fi

  log "${host}: live closure differs from built, deploying"
  log "${host}: live=${live}"
  log "${host}: built=${built}"

  "${SCRIPT_DIR}/converge-vm.sh" \
    --repo-dir "${REPO_DIR}" \
    --config "${CONFIG}" \
    --apps-config "${APPS_CONFIG}" \
    --closure "${built}" \
    --closure-only \
    --targets "-target=module.${host}"

  live="$(read_live_closure "${ip}")" || die "${host}: failed to read live closure during final verification"
  [[ "${live}" == "${built}" ]] || die "${host}: final verification mismatch: live=${live} built=${built}"
  log "${host}: final verification OK"
}

main "$@"
