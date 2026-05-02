#!/usr/bin/env bash
# converge-vm.sh - Run shared post-deploy convergence without rebuild orchestration.
#
# Usage:
#   framework/scripts/converge-vm.sh \
#     --config site/config.yaml \
#     --apps-config site/applications.yaml \
#     [--closure ./result] \
#     [--closure-only] \
#     [--targets "-target=module.testapp_dev ..."] \
#     [--override-branch-check] \
#     [--repo-dir /path/to/repo]
#
# Preconditions:
#   - The target cluster/VMs already exist and are reachable over SSH
#   - The operator environment can read any required SOPS secrets
#   - SOPS_AGE_KEY_FILE should point at a valid Age key when Vault/GitLab steps need it
#
# Exit codes:
#   0 - convergence completed successfully
#   1 - runtime error, invalid target set, or unsupported PBS scope
#   2 - usage error
#
# Not covered here:
#   - PBS install or PBS convergence (Phase 1 rejects module.pbs targets)
#   - validate.sh
#   - Git push / pipeline trigger (rebuild-cluster.sh Step 14.5)
#   - Pre-deploy or post-deploy backup snapshot orchestration

set -euo pipefail

CURRENT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_REPO_DIR="$(cd "${CURRENT_SCRIPT_DIR}/../.." && pwd)"
SCRIPT_DIR=""
REPO_DIR="${CURRENT_REPO_DIR}"
CONFIG=""
APPS_CONFIG=""
TOFU_TARGETS=""
CLOSURE=""
CLOSURE_ONLY=0
OVERRIDE_BRANCH_CHECK=0
SHOW_HELP=0
CONVERGE_VM_TARGETS=()
CONVERGE_VM_KNOWN_MODULES=()
CONVERGE_VM_REEXEC_GUARD="${CONVERGE_VM_REEXEC_GUARD:-}"

converge_vm_usage() {
  awk '
    NR < 2 { next }
    /^#/ {
      sub(/^# ?/, "")
      print
      next
    }
    { exit }
  ' "$0"
}

converge_vm_log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

converge_vm_die() {
  converge_vm_log "FATAL: $*"
  exit 1
}

converge_vm_step_start() {
  converge_vm_log "=== Step $1: $2 ==="
  STEP_START=$(date +%s)
}

converge_vm_step_done() {
  local elapsed=0
  if [[ -n "${STEP_START:-}" ]]; then
    elapsed=$(( $(date +%s) - STEP_START ))
  fi
  converge_vm_log "    Step $1 completed in ${elapsed}s"
}

converge_vm_step_skip() {
  converge_vm_log "    Step $1 skipped: $2"
}

converge_vm_join_by() {
  local delimiter="$1"
  shift
  local out=""
  local item=""

  for item in "$@"; do
    [[ -z "$item" ]] && continue
    if [[ -n "$out" ]]; then
      out+="${delimiter}"
    fi
    out+="${item}"
  done

  printf '%s\n' "$out"
}

converge_vm_require_option_value() {
  local option="$1"

  if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
    printf 'ERROR: %s requires a value\n' "$option" >&2
    converge_vm_usage >&2
    exit 2
  fi
}

converge_vm_resolve_repo_path() {
  local path="$1"

  if [[ "$path" = /* ]]; then
    printf '%s\n' "$path"
  else
    printf '%s\n' "${REPO_DIR}/${path#./}"
  fi
}

converge_vm_resolve_closure_path() {
  local path="$1"
  local resolved=""

  if ! resolved="$(
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path" 2>/dev/null
  )"; then
    converge_vm_die "Failed to resolve closure path: ${path}"
  fi

  [[ -e "$resolved" ]] || converge_vm_die "Closure path not found: ${path}"
  printf '%s\n' "$resolved"
}

converge_vm_add_known_module() {
  local module_name="$1"
  local known_module=""

  for known_module in "${CONVERGE_VM_KNOWN_MODULES[@]:-}"; do
    [[ "$known_module" == "$module_name" ]] && return 0
  done

  CONVERGE_VM_KNOWN_MODULES+=("$module_name")
}

converge_vm_module_known() {
  local module_name="$1"
  local known_module=""

  for known_module in "${CONVERGE_VM_KNOWN_MODULES[@]:-}"; do
    [[ "$known_module" == "$module_name" ]] && return 0
  done

  return 1
}

converge_vm_add_selected_target() {
  local module_name="$1"
  local selected_target=""

  for selected_target in "${CONVERGE_VM_TARGETS[@]:-}"; do
    [[ "$selected_target" == "$module_name" ]] && return 0
  done

  CONVERGE_VM_TARGETS+=("$module_name")
}

converge_vm_target_selected() {
  local module_name="$1"
  local selected_target=""

  for selected_target in "${CONVERGE_VM_TARGETS[@]:-}"; do
    [[ "$selected_target" == "$module_name" ]] && return 0
  done

  return 1
}

converge_vm_step_in_scope() {
  local step="$1"

  [[ "${#CONVERGE_VM_TARGETS[@]}" -eq 0 ]] && return 0

  case "$step" in
    networking|storage|cluster|snippets|sentinel|metrics|pipeline)
      return 1
      ;;
    pbs_install)
      converge_vm_target_selected "module.pbs"
      return $?
      ;;
    dns)
      converge_vm_target_selected "module.dns_dev" || converge_vm_target_selected "module.dns_prod"
      return $?
      ;;
    certs)
      return 0
      ;;
    vault)
      converge_vm_target_selected "module.vault_dev" || converge_vm_target_selected "module.vault_prod"
      return $?
      ;;
    gitlab)
      converge_vm_target_selected "module.gitlab"
      return $?
      ;;
    runner)
      converge_vm_target_selected "module.gitlab" || converge_vm_target_selected "module.cicd"
      return $?
      ;;
    push)
      converge_vm_target_selected "module.gitlab"
      return $?
      ;;
    backups)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

converge_vm_load_known_modules() {
  local vm_keys_output=""
  local app_keys_output=""
  local env_keys_output=""
  local vm_key=""
  local app_key=""
  local env_name=""
  local env_suffix=""

  CONVERGE_VM_KNOWN_MODULES=()

  if ! vm_keys_output="$(yq -r '.vms | keys | .[]' "$CONFIG" | sort)"; then
    converge_vm_die "Failed to read VM inventory from ${CONFIG}"
  fi

  while IFS= read -r vm_key; do
    [[ -z "$vm_key" || "$vm_key" == "null" ]] && continue
    case "$vm_key" in
      dns1_*|dns2_*)
        env_suffix="${vm_key##*_}"
        converge_vm_add_known_module "module.dns_${env_suffix}"
        ;;
      *)
        converge_vm_add_known_module "module.${vm_key}"
        ;;
    esac
  done <<< "$vm_keys_output"

  # Trade-off: derive allowed app targets from enabled site inventory instead of
  # raw module blocks. Disabled app modules still exist in main.tf with count=0,
  # but converge-vm should fail closed unless this checkout's config enables them.
  if ! app_keys_output="$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG" | sort)"; then
    converge_vm_die "Failed to read application inventory from ${APPS_CONFIG}"
  fi

  while IFS= read -r app_key; do
    [[ -z "$app_key" || "$app_key" == "null" ]] && continue
    if ! env_keys_output="$(yq -r ".applications.${app_key}.environments // {} | keys | .[]" "$APPS_CONFIG" | sort)"; then
      converge_vm_die "Failed to read enabled environments for application ${app_key} from ${APPS_CONFIG}"
    fi
    while IFS= read -r env_name; do
      [[ -z "$env_name" || "$env_name" == "null" ]] && continue
      converge_vm_add_known_module "module.${app_key}_${env_name}"
    done <<< "$env_keys_output"
  done <<< "$app_keys_output"
}

converge_vm_reexec_from_repo_dir() {
  local target_script=""

  [[ "$REPO_DIR" != "$CURRENT_REPO_DIR" ]] || return 0

  target_script="${REPO_DIR}/framework/scripts/converge-vm.sh"
  [[ -f "$target_script" ]] || converge_vm_die "converge-vm.sh not found in repo-dir: ${REPO_DIR}"
  [[ -x "$target_script" ]] || converge_vm_die "converge-vm.sh is not executable in repo-dir: ${REPO_DIR}"

  if [[ "$CONVERGE_VM_REEXEC_GUARD" == "$REPO_DIR" ]]; then
    converge_vm_die "Refusing recursive --repo-dir re-exec for ${REPO_DIR}"
  fi

  # Trade-off: make --repo-dir authoritative for the wrapper and all helper code.
  # Re-execing is stricter than mixing checkout A's script with checkout B's
  # config, but fail-closed is safer than converging the wrong revision.
  export CONVERGE_VM_REEXEC_GUARD="${REPO_DIR}"
  exec "$target_script" "$@"
}

converge_vm_resolve_age_key() {
  if [[ -n "${SOPS_AGE_KEY_FILE:-}" && -f "${SOPS_AGE_KEY_FILE}" ]]; then
    return 0
  fi

  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
  elif [[ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
    export SOPS_AGE_KEY_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
  fi
}

converge_vm_normalize_targets() {
  local raw_targets=()
  local target=""
  local module_name=""
  local normalized=()
  local unknown_modules=()

  CONVERGE_VM_TARGETS=()
  [[ -z "$TOFU_TARGETS" ]] && return 0

  converge_vm_load_known_modules
  read -r -a raw_targets <<< "$TOFU_TARGETS"
  for target in "${raw_targets[@]}"; do
    [[ -z "$target" ]] && continue
    case "$target" in
      -target=module.*)
        module_name="${target#-target=}"
        ;;
      module.*)
        module_name="${target}"
        ;;
      *)
        converge_vm_die "Invalid target syntax: ${target}. Use --targets \"-target=module.NAME ...\""
        ;;
    esac

    if [[ "$module_name" == "module.pbs" ]]; then
      converge_vm_die "PBS convergence is not supported in Phase 1. Remove module.pbs from --targets."
    fi

    if ! converge_vm_module_known "$module_name"; then
      unknown_modules+=("$module_name")
      continue
    fi

    converge_vm_add_selected_target "$module_name"
  done

  if [[ "${#unknown_modules[@]}" -gt 0 ]]; then
    converge_vm_die \
      "Unknown target module(s): $(converge_vm_join_by ', ' "${unknown_modules[@]}"). Known modules: $(converge_vm_join_by ', ' "${CONVERGE_VM_KNOWN_MODULES[@]}")"
  fi

  if [[ "${#CONVERGE_VM_TARGETS[@]}" -eq 0 ]]; then
    converge_vm_die "--targets did not resolve to any supported modules"
  fi

  for module_name in "${CONVERGE_VM_TARGETS[@]}"; do
    normalized+=("-target=${module_name}")
  done

  TOFU_TARGETS="${normalized[*]}"
}

converge_vm_parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        converge_vm_require_option_value "$@"
        CONFIG="$2"
        shift 2
        ;;
      --apps-config)
        converge_vm_require_option_value "$@"
        APPS_CONFIG="$2"
        shift 2
        ;;
      --targets)
        converge_vm_require_option_value "$@"
        TOFU_TARGETS="$2"
        shift 2
        ;;
      --closure)
        converge_vm_require_option_value "$@"
        CLOSURE="$2"
        shift 2
        ;;
      --closure-only)
        CLOSURE_ONLY=1
        shift
        ;;
      --override-branch-check)
        OVERRIDE_BRANCH_CHECK=1
        shift
        ;;
      --repo-dir)
        converge_vm_require_option_value "$@"
        REPO_DIR="$2"
        shift 2
        ;;
      --help|-h)
        SHOW_HELP=1
        shift
        ;;
      *)
        printf 'ERROR: Unknown argument: %s\n' "$1" >&2
        converge_vm_usage >&2
        exit 2
        ;;
    esac
  done
}

converge_vm_validate_args() {
  [[ -n "$CONFIG" ]] || {
    printf 'ERROR: --config is required\n' >&2
    converge_vm_usage >&2
    exit 2
  }
  [[ -n "$APPS_CONFIG" ]] || {
    printf 'ERROR: --apps-config is required\n' >&2
    converge_vm_usage >&2
    exit 2
  }
  [[ -d "$REPO_DIR" ]] || converge_vm_die "Repo directory not found: ${REPO_DIR}"
  REPO_DIR="$(cd "$REPO_DIR" && pwd)"
  CONFIG="$(converge_vm_resolve_repo_path "$CONFIG")"
  APPS_CONFIG="$(converge_vm_resolve_repo_path "$APPS_CONFIG")"
  if [[ -n "$CLOSURE" ]]; then
    CLOSURE="$(converge_vm_resolve_closure_path "$CLOSURE")"
  fi
  SCRIPT_DIR="${REPO_DIR}/framework/scripts"
  [[ -d "$SCRIPT_DIR" ]] || converge_vm_die "Script directory not found in repo-dir: ${SCRIPT_DIR}"
  [[ -f "${SCRIPT_DIR}/converge-lib.sh" ]] || converge_vm_die "converge-lib.sh not found in repo-dir: ${SCRIPT_DIR}"
  [[ -f "$CONFIG" ]] || converge_vm_die "Config file not found: ${CONFIG}"
  [[ -f "$APPS_CONFIG" ]] || converge_vm_die "Applications config file not found: ${APPS_CONFIG}"
}

converge_vm_main() {
  converge_vm_parse_args "$@"
  if [[ "$SHOW_HELP" -eq 1 ]]; then
    converge_vm_usage
    exit 0
  fi
  converge_vm_validate_args
  converge_vm_reexec_from_repo_dir "$@"
  source "${SCRIPT_DIR}/converge-lib.sh"
  converge_vm_resolve_age_key
  converge_vm_normalize_targets

  log() { converge_vm_log "$@"; }
  die() { converge_vm_die "$@"; }
  step_start() { converge_vm_step_start "$@"; }
  step_done() { converge_vm_step_done "$@"; }
  step_skip() { converge_vm_step_skip "$@"; }
  step_in_scope() { converge_vm_step_in_scope "$@"; }

  if [[ "$CLOSURE_ONLY" -eq 1 ]]; then
    # Pipeline mode: push the closure, reboot, verify — no Steps 8-15.
    # The pipeline's post-deploy.sh handles data-plane convergence.
    # Running converge_run_all from the control-plane deploy job would
    # restart the runner (Step 14) and kill the running pipeline job.
    converge_step_closure
  else
    # Workstation mode: push closure + run full convergence (Steps 8-15).
    converge_run_all
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  converge_vm_main "$@"
fi
