#!/usr/bin/env bash
# check-control-plane-drift.sh — Detect live closure drift on control-plane VMs.
#
# Default scope: shared control-plane NixOS VMs (gitlab, cicd).
# Optional scope: --all-nixos expands the host list to all NixOS VMs defined in
# config.yaml/applications.yaml. The flag exists for future rollout but is not
# enabled anywhere by default.
#
# Sprint 013 invariant: after a successful pipeline run, gitlab and cicd must
# already be at the flake closure. Any reported drift or incomplete check is a
# deployment bug and should fail the validation path.
#
# Usage:
#   framework/scripts/check-control-plane-drift.sh
#   framework/scripts/check-control-plane-drift.sh --all-nixos
#
# Exit codes:
#   0 — all checked VMs match the desired closure
#   1 — drift detected
#   2 — check could not be completed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

SSH_OPTS=(
  -n
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
)

usage() {
  cat <<'EOF'
Usage:
  framework/scripts/check-control-plane-drift.sh
  framework/scripts/check-control-plane-drift.sh --all-nixos
EOF
}

ALL_NIXOS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all-nixos)
      ALL_NIXOS=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for tool in nix ssh yq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: ${tool}" >&2
    exit 2
  fi
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 2
fi

host_ip() {
  local host="$1"
  local ip=""
  local app_key=""
  local env_name=""

  ip="$(yq -r ".vms.${host}.ip // \"\"" "$CONFIG" 2>/dev/null || true)"
  if [[ -n "$ip" && "$ip" != "null" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  app_key="${host%_*}"
  env_name="${host##*_}"
  if [[ "$app_key" == "$host" || "$env_name" == "$host" || ! -f "$APPS_CONFIG" ]]; then
    return 1
  fi

  ip="$(yq -r ".applications.${app_key}.environments.${env_name}.ip // \"\"" "$APPS_CONFIG" 2>/dev/null || true)"
  if [[ -n "$ip" && "$ip" != "null" ]]; then
    printf '%s\n' "$ip"
    return 0
  fi

  return 1
}

host_module_target() {
  local host="$1"

  case "$host" in
    dns1_dev|dns2_dev)
      printf '%s\n' 'module.dns_dev'
      ;;
    dns1_prod|dns2_prod)
      printf '%s\n' 'module.dns_prod'
      ;;
    *)
      printf 'module.%s\n' "$host"
      ;;
  esac
}

collect_all_nixos_hosts() {
  local hosts=()
  local app_hosts=()
  local host=""

  while IFS= read -r host; do
    [[ -z "$host" || "$host" == "pbs" ]] && continue
    hosts+=("$host")
  done < <(yq -r '.vms | keys | .[]' "$CONFIG" 2>/dev/null || true)

  if [[ -f "$APPS_CONFIG" ]]; then
    while IFS= read -r host; do
      [[ -z "$host" ]] && continue
      app_hosts+=("$host")
    done < <(yq -r '
      .applications // {}
      | to_entries[]
      | select(.value.enabled == true)
      | .key as $app
      | (.value.environments | keys | .[])
      | "\($app)_\(.)"
    ' "$APPS_CONFIG" 2>/dev/null || true)
  fi

  printf '%s\n' "${hosts[@]}" "${app_hosts[@]}" | awk 'NF' | sort -u
}

collect_hosts() {
  if [[ "$ALL_NIXOS" -eq 1 ]]; then
    collect_all_nixos_hosts
  else
    printf '%s\n' gitlab cicd
  fi
}

HOSTS=()
while IFS= read -r host; do
  [[ -z "$host" ]] && continue
  HOSTS+=("$host")
done < <(collect_hosts)

if [[ "${#HOSTS[@]}" -eq 0 ]]; then
  echo "ERROR: No hosts selected for drift check" >&2
  exit 2
fi

echo "=== Checking live NixOS closure drift ==="
if [[ "$ALL_NIXOS" -eq 1 ]]; then
  echo "Scope: all NixOS hosts"
else
  echo "Scope: control-plane hosts"
fi
echo ""

DRIFT=0
CHECK_ERROR=0

for host in "${HOSTS[@]}"; do
  desired=""
  live=""
  ip=""
  module_target=""

  if ! ip="$(host_ip "$host")"; then
    echo "ERROR: Could not resolve IP for ${host}" >&2
    CHECK_ERROR=1
    continue
  fi

  desired="$(nix eval --raw ".#nixosConfigurations.${host}.config.system.build.toplevel" 2>/dev/null || true)"
  if [[ -z "$desired" ]]; then
    echo "ERROR: nix eval failed for ${host}" >&2
    CHECK_ERROR=1
    continue
  fi

  live="$(ssh "${SSH_OPTS[@]}" "root@${ip}" "readlink -f /run/current-system" 2>/dev/null || true)"
  if [[ -z "$live" ]]; then
    echo "ERROR: Failed to read live closure for ${host} (${ip})" >&2
    CHECK_ERROR=1
    continue
  fi

  if [[ "$desired" == "$live" ]]; then
    echo "OK: ${host} (${ip}) ${desired}"
    continue
  fi

  module_target="$(host_module_target "$host")"
  echo "DRIFT: ${host} (${ip}) running ${live}, want ${desired}"
  echo "  Remediation: framework/scripts/converge-vm.sh --closure ${desired} --targets -target=${module_target}"
  DRIFT=1
done

echo ""

if [[ "$CHECK_ERROR" -ne 0 ]]; then
  echo "Drift check incomplete — resolve the errors above and retry." >&2
  exit 2
fi

if [[ "$DRIFT" -ne 0 ]]; then
  echo "Live closure drift detected."
  exit 1
fi

echo "Live closures match flake outputs."
