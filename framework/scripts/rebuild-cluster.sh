#!/usr/bin/env bash
# rebuild-cluster.sh — Rebuild the full cluster from bare Proxmox nodes.
#
# One command, one config file, one key. This is the capstone script.
#
# Usage:
#   framework/scripts/rebuild-cluster.sh                           # full rebuild
#   framework/scripts/rebuild-cluster.sh --scope control-plane     # GitLab, CI runner, PBS only
#   framework/scripts/rebuild-cluster.sh --scope data-plane        # everything except control-plane
#   framework/scripts/rebuild-cluster.sh --scope vm=gitlab,cicd    # specific VMs
#   framework/scripts/rebuild-cluster.sh --scope onboard-app=name  # create catalog AppRole creds only
#   framework/scripts/rebuild-cluster.sh --restore-pin-file build/restore-pin-reset.json
#   framework/scripts/rebuild-cluster.sh --allow-dirty             # proceed with dirty git tree
#   framework/scripts/rebuild-cluster.sh --override-branch-check   # allow prod/shared DR from non-prod
#
# Prerequisites:
#   - operator.age.key on the workstation
#   - site/config.yaml exists
#   - All node management IPs reachable via SSH
#   - NAS reachable (PostgreSQL state backend)
#
# Every step is idempotent. If interrupted, re-run to resume.
# Logs to build/rebuild.log.

set -euo pipefail

# Ensure nix is on PATH (non-interactive shells like nohup may not source profiles)
if ! command -v nix &>/dev/null; then
  for p in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin"; do
    [[ -d "$p" ]] && export PATH="$p:$PATH"
  done
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
TOFU_DIR="${REPO_DIR}/framework/tofu/root"
LOG_DIR="${REPO_DIR}/build"
LOG_FILE="${LOG_DIR}/rebuild.log"
BUILD_MARKER="${LOG_DIR}/.build-complete"

ALLOW_DIRTY=0
OVERRIDE_BRANCH_CHECK=0
STAGING_CERTS=0
SCOPE=""
RESTORE_PIN_FILE=""
source "${SCRIPT_DIR}/git-deploy-context.sh"
source "${SCRIPT_DIR}/certbot-cluster.sh"
source "${SCRIPT_DIR}/converge-lib.sh"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --override-branch-check) OVERRIDE_BRANCH_CHECK=1; shift ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --restore-pin-file)
      RESTORE_PIN_FILE="$2"
      shift 2
      ;;
    --staging-certs) echo "NOTE: --staging-certs is deprecated. Set 'acme: staging' in site/config.yaml instead."; shift ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$RESTORE_PIN_FILE" ]]; then
  RESTORE_PIN_DIR="$(dirname "$RESTORE_PIN_FILE")"
  if RESTORE_PIN_DIR_ABS="$(cd "$RESTORE_PIN_DIR" 2>/dev/null && pwd)"; then
    RESTORE_PIN_FILE="${RESTORE_PIN_DIR_ABS}/$(basename "$RESTORE_PIN_FILE")"
  fi
fi

# --- Scope definitions ---
TOFU_TARGETS=""
CONTROL_PLANE_MODULES="module.gitlab module.cicd module.pbs"

if [[ -n "$SCOPE" ]]; then
  case "$SCOPE" in
    onboard-app=*)
      ;;
    control-plane)
      for mod in $CONTROL_PLANE_MODULES; do
        TOFU_TARGETS="$TOFU_TARGETS -target=$mod"
      done
      ;;
    data-plane)
      # All modules except control-plane — computed after config is loaded
      # (deferred to step 7)
      TOFU_TARGETS="DATA_PLANE_DEFERRED"
      ;;
    vm=*)
      IFS=',' read -ra VM_LIST <<< "${SCOPE#vm=}"
      for vm in "${VM_LIST[@]}"; do
        TOFU_TARGETS="$TOFU_TARGETS -target=module.${vm}"
      done
      ;;
    *)
      echo "ERROR: Unknown scope: $SCOPE" >&2
      echo "Valid: control-plane, data-plane, vm=name1,name2, onboard-app=name" >&2
      exit 1
      ;;
  esac
fi

# Returns 0 if the step should run for the current scope
step_in_scope() {
  local step="$1"
  [[ -z "$SCOPE" ]] && return 0  # full rebuild — all steps run

  case "$step" in
    networking|storage|cluster|snippets|sentinel|metrics|pipeline)
      return 1  # infrastructure steps — skip in scoped mode
      ;;
    pbs_install)
      [[ "$TOFU_TARGETS" == *"module.pbs"* ]] && return 0 || return 1
      ;;
    dns)
      [[ "$TOFU_TARGETS" == *"module.dns"* ]] && return 0 || return 1
      ;;
    certs)
      return 0  # certs needed for any recreated VM
      ;;
    vault)
      [[ "$TOFU_TARGETS" == *"module.vault"* ]] && return 0 || return 1
      ;;
    gitlab)
      [[ "$TOFU_TARGETS" == *"module.gitlab"* ]] && return 0 || return 1
      ;;
    runner)
      [[ "$TOFU_TARGETS" == *"module.gitlab"* || "$TOFU_TARGETS" == *"module.cicd"* ]] && return 0 || return 1
      ;;
    push)
      [[ "$TOFU_TARGETS" == *"module.gitlab"* ]] && return 0 || return 1
      ;;
    backups)
      return 0  # always reconfigure backup jobs after any VM recreation
      ;;
    *)
      return 0  # default: run
      ;;
  esac
}

# ACME mode is now set via config.yaml acme field (staging/production).
# The --staging-certs flag is deprecated.

# --- Logging ---
mkdir -p "$LOG_DIR"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}
step_start() { log "=== Step $1: $2 ==="; STEP_START=$(date +%s); }
step_done() {
  local elapsed=$(( $(date +%s) - STEP_START ))
  log "    Step $1 completed in ${elapsed}s"
  STEP_RESULTS+=("$1: $2 (${elapsed}s)")
}
step_skip() {
  log "    Step $1 skipped: $2"
  STEP_RESULTS+=("$1: SKIPPED — $2")
}
die() { log "FATAL: $*"; exit 1; }

resolve_gatus_expected_source_commit() {
  local ref=""
  local sha=""
  local rc=0

  for ref in \
    "refs/remotes/gitlab/prod^{commit}" \
    "refs/heads/prod^{commit}" \
    "HEAD^{commit}"
  do
    set +e
    sha="$(git -C "${REPO_DIR}" rev-parse --verify "${ref}" 2>/dev/null)"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 && "${sha}" =~ ^[0-9a-fA-F]{40}$ ]]; then
      printf '%s\n' "${sha}"
      return 0
    fi
  done

  return 1
}

# Discover root modules by parsing framework/tofu/root/*.tf. The configuration
# files are the source of truth for which modules exist; using them avoids the
# trap door where `tofu state list` returns empty (cold rebuild, prior state
# cleanup, fresh workspace) and the caller silently degenerates to "no -target
# flags" → apply the whole world. Defined here (before any caller) so the
# DATA_PLANE_DEFERRED resolver in step 7 can use it.
collect_configured_root_modules() {
  local tf_files=()
  local tf_file
  local modules

  # `-L` follows symlinks. framework/tofu/root/overrides.tf is a symlink
  # to site/tofu/overrides.tf, where sites declare custom modules. Without
  # `-L`, BSD/GNU `find -type f` skips the symlink and any modules declared
  # in site overrides are silently absent from the resolved targets.
  while IFS= read -r tf_file; do
    tf_files+=("$tf_file")
  done < <(find -L "$TOFU_DIR" -maxdepth 1 -type f -name '*.tf' | sort)

  [[ "${#tf_files[@]}" -gt 0 ]] \
    || die "Cannot discover root modules: no OpenTofu *.tf files found in ${TOFU_DIR}."

  if ! modules="$(
    grep -hE '^[[:space:]]*module[[:space:]]+"[^"]+"' "${tf_files[@]}" \
      | sed -E 's/^[[:space:]]*module[[:space:]]+"([^"]+)".*/module.\1/' \
      | sort -u
  )"; then
    die "Cannot discover root modules from configuration. Refusing to derive bulk apply targets."
  fi

  [[ -n "$modules" ]] \
    || die "Cannot discover root modules from configuration. Refusing to derive bulk apply targets."

  printf '%s\n' "$modules"
}

log_function_output() {
  local fn="$1"
  shift || true
  while IFS= read -r line; do
    log "$line"
  done < <("$fn" "$@")
}

ensure_onboarding_age_key() {
  local age_key="${SOPS_AGE_KEY_FILE:-}"
  if [[ -z "$age_key" ]]; then
    if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
      age_key="${REPO_DIR}/operator.age.key"
    elif [[ -f "${REPO_DIR}/operator.age.key.production" ]]; then
      age_key="${REPO_DIR}/operator.age.key.production"
    elif [[ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
      age_key="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
    fi
  fi

  if [[ -z "$age_key" || ! -f "$age_key" ]]; then
    die "operator.age.key not found — place it at ${REPO_DIR}/operator.age.key or set SOPS_AGE_KEY_FILE"
  fi

  export SOPS_AGE_KEY_FILE="$age_key"
}

ensure_git_identity_for_onboarding() {
  if ! git -C "$REPO_DIR" config user.email >/dev/null 2>&1; then
    git -C "$REPO_DIR" config user.email "ci@mycofu.local"
    git -C "$REPO_DIR" config user.name "Mycofu CI"
  fi
}

onboard_catalog_app_scope() {
  local app="${SCOPE#onboard-app=}"
  local enabled=""
  local env=""
  local role_key=""
  local secret_key=""
  local missing=0
  local resolved_keys=""

  [[ -n "$app" ]] || die "onboard-app scope requires a catalog app name"

  step_start onboard "Onboard AppRole credentials for ${app}"

  for tool in yq jq sops git curl; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: ${tool}"
  done

  [[ -f "$APPS_CONFIG" ]] || die "applications.yaml not found: ${APPS_CONFIG}"
  [[ -f "${REPO_DIR}/site/sops/secrets.yaml" ]] || die "SOPS secrets file not found: ${REPO_DIR}/site/sops/secrets.yaml"

  ensure_onboarding_age_key

  if ! git -C "$REPO_DIR" diff --quiet -- site/sops/secrets.yaml 2>/dev/null || \
     ! git -C "$REPO_DIR" diff --cached --quiet -- site/sops/secrets.yaml 2>/dev/null; then
    die "site/sops/secrets.yaml has uncommitted changes; refuse to mix onboarding commits with existing edits"
  fi

  export VAULT_REQUIREMENTS_REPO_DIR="${REPO_DIR}"
  source "${SCRIPT_DIR}/vault-requirements-lib.sh"

  # Check for a vault-requirements manifest in either catalog or fixed-role paths
  if ! vault_requirements_manifest_path "$app" >/dev/null 2>&1; then
    die "'${app}' has no vault-requirements.yaml manifest (checked catalog and fixed-role paths)"
  fi

  # Catalog apps must be enabled in applications.yaml; fixed roles (in
  # framework/tofu/modules/) are always eligible since they exist in config.yaml
  if catalog_app_has_approle_manifest "$app"; then
    enabled="$(yq -r ".applications.${app}.enabled // false" "$APPS_CONFIG" 2>/dev/null || true)"
    [[ "$enabled" == "true" ]] || die "Catalog app '${app}' is not enabled in site/applications.yaml"
  else
    # Fixed role — verify it exists in config.yaml (e.g., testapp_dev, testapp_prod)
    local vm_count=""
    vm_count="$(yq -r '.vms | keys[]' "$CONFIG" 2>/dev/null | grep -c "^${app}" || echo "0")"
    [[ "$vm_count" -gt 0 ]] || die "Fixed role '${app}' has no VMs in config.yaml"
  fi

  for env in dev prod; do
    log "    ${env}: configuring AppRole credentials for ${app}"
    "${SCRIPT_DIR}/configure-vault.sh" "$env" --app "$app"

    missing=0
    resolved_keys="$(resolve_sops_keys "$app" "$env")" || die "Failed to resolve SOPS keys for ${app} (${env})"
    while IFS=$'\t' read -r role_key secret_key; do
      if ! check_sops_key_exists "$role_key" || ! check_sops_key_exists "$secret_key"; then
        log "    ERROR: ${env}: missing expected SOPS keys ${role_key} / ${secret_key} after configure-vault"
        missing=1
        break
      fi
    done <<< "$resolved_keys"
    [[ $missing -eq 0 ]] || die "Failed to verify SOPS credentials for ${app} (${env})"

    if git -C "$REPO_DIR" diff --quiet -- site/sops/secrets.yaml 2>/dev/null; then
      log "    ${env}: credentials already present — no SOPS changes to commit"
      continue
    fi

    ensure_git_identity_for_onboarding
    git -C "$REPO_DIR" add site/sops/secrets.yaml
    git -C "$REPO_DIR" commit -m "onboard: AppRole credentials for ${app} (${env})" >/dev/null
    log "    ${env}: committed AppRole credentials to SOPS"
  done

  log "    Onboarding completed. Review the local commits and push manually when ready."
  step_done onboard "Catalog app ${app} onboarded"
  exit 0
}

STEP_RESULTS=()
REBUILD_START=$(date +%s)

log "rebuild-cluster.sh started"
log "Config: ${CONFIG}"
if [[ -n "$SCOPE" ]]; then
  log "Scope: ${SCOPE}"
  log "Targets: ${TOFU_TARGETS}"
fi
log "Override branch check: ${OVERRIDE_BRANCH_CHECK}"
if [[ -n "$RESTORE_PIN_FILE" ]]; then
  log "Restore pin file: ${RESTORE_PIN_FILE}"
fi
log ""

if [[ "$SCOPE" == onboard-app=* ]]; then
  onboard_catalog_app_scope
fi

restore_pin_validate() {
  [[ -n "$RESTORE_PIN_FILE" ]] || return 0

  if [[ ! -f "$RESTORE_PIN_FILE" ]]; then
    echo "restore pin file not found: ${RESTORE_PIN_FILE}" >&2
    return 1
  fi

  if ! jq -e '
    (.version // null) != null
    and (.pins | type) == "object"
    and all(.pins | to_entries[]?; (.key | test("^[0-9]+$")) and (.value | type == "string") and (.value | length > 0))
  ' "$RESTORE_PIN_FILE" >/dev/null 2>&1; then
    echo "restore pin file is not valid JSON pin schema: ${RESTORE_PIN_FILE}" >&2
    return 1
  fi

  return 0
}

# =====================================================================
# Step 0: Verify ALL prerequisites before touching anything
# =====================================================================
step_start 0 "Verify prerequisites"

PREREQ_FAIL=0
prereq_ok()   { echo "  ✓ $*"; }
prereq_fail() { echo "  ✗ $*"; PREREQ_FAIL=$((PREREQ_FAIL + 1)); }

# --- Files ---
AGE_KEY="${SOPS_AGE_KEY_FILE:-}"
if [[ -z "$AGE_KEY" ]]; then
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    AGE_KEY="${REPO_DIR}/operator.age.key"
  elif [[ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
    AGE_KEY="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
  fi
fi
if [[ -n "$AGE_KEY" && -f "$AGE_KEY" ]]; then
  prereq_ok "operator.age.key found"
  export SOPS_AGE_KEY_FILE="$AGE_KEY"
else
  prereq_fail "operator.age.key not found — place at ${REPO_DIR}/operator.age.key or set SOPS_AGE_KEY_FILE"
fi

# --- Recover secrets.yaml if missing (Level 2-3 rebuild) ---
if [[ ! -f "${REPO_DIR}/site/sops/secrets.yaml" ]]; then
  if [[ -n "$AGE_KEY" && -f "$AGE_KEY" ]]; then
    echo "  secrets.yaml missing — attempting recovery from git history..."
    "${SCRIPT_DIR}/recover-secrets.sh" || {
      prereq_fail "secrets.yaml recovery failed"
    }
    prereq_ok "secrets.yaml recovered from git history"
  else
    prereq_fail "secrets.yaml missing and no age key to recover it"
  fi
else
  prereq_ok "secrets.yaml found"
fi

if [[ -f "$CONFIG" ]]; then
  prereq_ok "site/config.yaml found"
else
  prereq_fail "site/config.yaml not found at ${CONFIG}"
fi

if [[ -n "$RESTORE_PIN_FILE" ]]; then
  if restore_pin_validate; then
    prereq_ok "restore pin file valid"
  else
    prereq_fail "restore pin file invalid: ${RESTORE_PIN_FILE}"
  fi
fi

# --- Required tools ---
for cmd in yq jq ssh scp curl dig openssl sops tofu nix git; do
  if command -v "$cmd" &>/dev/null; then
    prereq_ok "${cmd} available"
  else
    prereq_fail "${cmd} not found in PATH"
  fi
done

# --- Nix linux-builder (macOS only) ---
if [[ -f "$CONFIG" ]]; then
  BUILDER_TYPE=$(yq -r '.nix_builder.type' "$CONFIG")
  if [[ "$BUILDER_TYPE" == "linux-builder" ]] && [[ "$(uname)" == "Darwin" ]]; then
    if pgrep -f "qemu.*nixos.qcow2" &>/dev/null; then
      # Builder process exists — verify it's actually responsive via port probe
      if nc -z localhost 31022 2>/dev/null; then
        prereq_ok "Nix linux-builder running (port 31022 responding)"
      else
        # Builder process exists but is unresponsive (suspended from a
        # previous failed run). Kill it and restart fresh.
        echo "  ⚠ Builder process exists but is unresponsive — restarting..."
        pkill -9 -f "qemu.*nixos.qcow2" 2>/dev/null || true
        sleep 3
        BUILDER_START="${HOME}/.nix-builder/start-builder.sh"
        if [ -x "$BUILDER_START" ]; then
          bash "$BUILDER_START"
          for i in $(seq 1 24); do
            nc -z localhost 31022 2>/dev/null && break
            sleep 5
          done
        fi
        if nc -z localhost 31022 2>/dev/null; then
          prereq_ok "Nix linux-builder restarted and responsive"
        else
          prereq_fail "Nix linux-builder not responding after restart"
        fi
      fi
      # Functional test: verify the builder can actually build something
      if nix build --log-format raw --impure --expr '(import <nixpkgs> { system = "x86_64-linux"; }).hello' \
           --no-link --timeout 120 2>/dev/null; then
        prereq_ok "Nix builder: functional (can build x86_64-linux)"
      else
        prereq_fail "Nix linux-builder cannot build x86_64-linux derivations"
        echo "    Ensure the builder has sufficient disk space and resources."
        echo "    See the bringup guide for recommended nix-darwin configuration."
      fi
      # If host store appears GC'd, pre-fetch the largest image closure
      # to avoid builder overlay exhaustion during the build step.
      if ! nix path-info --log-format raw nixpkgs#stdenv --system x86_64-linux 2>/dev/null | grep -q '/nix/store'; then
        echo "  ⚠ Host nix store appears garbage-collected — pre-fetching gitlab closure..."
        nix build --log-format raw .#packages.x86_64-linux.gitlab-image --no-link 2>/dev/null && \
          prereq_ok "gitlab closure pre-fetched into host store" || \
          echo "  ⚠ Pre-fetch failed — build-image.sh will auto-recover if needed"
      fi
    else
      prereq_fail "Nix linux-builder not running — start with: framework/scripts/setup-nix-builder.sh --start"
    fi
  fi
fi

# --- Git working directory ---
# Exclude site/sops/secrets.yaml from the dirty check — it is updated
# by init-vault.sh and configure-gitlab.sh as an expected side effect
# of the rebuild. SOPS changes don't affect image builds.
if [[ -f "$CONFIG" ]]; then
  if git -C "$REPO_DIR" diff --quiet HEAD -- ':!site/sops/secrets.yaml' 2>/dev/null; then
    prereq_ok "Git working directory clean"
    BUILD_FLAGS=""
  elif [[ "$ALLOW_DIRTY" -eq 1 ]]; then
    echo "  ⚠ Git working directory dirty — --allow-dirty specified, using --dev"
    BUILD_FLAGS="--dev"
  else
    echo "  ✗ Git working directory is dirty"
    echo ""
    echo "    A dirty tree produces -dev image filenames that do not match"
    echo "    the deployed state. Running tofu apply with -dev images against"
    echo "    a cluster deployed from clean builds will RECREATE every VM"
    echo "    whose image filename changed."
    echo ""
    echo "    Options:"
    echo "      1. Commit or stash your changes, then re-run"
    echo "      2. Run with --allow-dirty to proceed (DESTRUCTIVE)"
    PREREQ_FAIL=$((PREREQ_FAIL + 1))
  fi
fi

# --- SSH reachability (only if config exists) ---
if [[ -f "$CONFIG" ]]; then
  NODE_COUNT=$(yq -r '.nodes | length' "$CONFIG")
  NAS_IP=$(yq -r '.nas.ip' "$CONFIG")

  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    if ping -c 1 -W 3 "$NODE_IP" &>/dev/null; then
      # Check SSH — key auth may not be set up yet on fresh installs;
      # configure-node-network.sh (step 1) handles SSH key installation.
      if ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o BatchMode=yes -o LogLevel=ERROR "root@${NODE_IP}" "true" 2>/dev/null; then
        prereq_ok "${NODE_NAME} (${NODE_IP}) reachable via SSH"
      else
        prereq_ok "${NODE_NAME} (${NODE_IP}) pingable (SSH key will be installed in step 1)"
      fi
    else
      prereq_fail "${NODE_NAME} (${NODE_IP}) not reachable (not pingable)"
    fi
  done

  NAS_SSH_USER=$(yq -r '.nas.ssh_user' "$CONFIG")
  if ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
       "${NAS_SSH_USER}@${NAS_IP}" "true" 2>/dev/null; then
    prereq_ok "NAS (${NAS_IP}) reachable"

    # Check PostgreSQL is running and tofu database exists (Gap 3)
    NAS_PG_PORT=$(yq -r '.nas.postgres_port' "$CONFIG")
    if ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         "${NAS_SSH_USER}@${NAS_IP}" "psql -U postgres -p ${NAS_PG_PORT} -c '\\l' 2>/dev/null" 2>/dev/null | grep -q tofu_state; then
      prereq_ok "NAS PostgreSQL: tofu_state database exists"
    else
      prereq_fail "NAS PostgreSQL: tofu_state database not found. Run configure-nas.sh first."
    fi
  else
    prereq_fail "NAS (${NAS_IP}) not reachable via SSH"
  fi

  # Validate all NAS prerequisites (NFS export, permissions, PostgreSQL, Docker)
  # --fix auto-corrects issues the framework can handle (e.g., Synology ACL mode 000)
  NAS_PREREQ_OUT=$("${SCRIPT_DIR}/verify-nas-prereqs.sh" --fix 2>&1) && NAS_PREREQ_OK=1 || NAS_PREREQ_OK=0
  echo "$NAS_PREREQ_OUT" | sed 's/^/  /'
  if [[ $NAS_PREREQ_OK -eq 1 ]]; then
    prereq_ok "NAS prerequisites verified"
  else
    prereq_fail "NAS prerequisites not met (see details above)"
  fi

  # PBS reachability check (Gap 4 — PBS is optional, don't fail)
  # Use HTTPS port 8007 (PBS web API), not SSH — PBS is a vendor appliance
  # that may not have the operator's SSH key until configure-pbs.sh runs.
  PBS_IP=$(yq -r '.vms.pbs.ip // ""' "$CONFIG")
  if [[ -n "$PBS_IP" && "$PBS_IP" != "null" ]]; then
    if curl -sk --max-time 5 "https://${PBS_IP}:8007/" -o /dev/null 2>/dev/null; then
      prereq_ok "PBS (${PBS_IP}) reachable"
    else
      echo "  ⚠ PBS (${PBS_IP}) is not reachable." >&2
      echo "    PBS will be installed automatically at step 7.5 (answer file)." >&2
    fi
  fi
fi

# --- Fail if any prerequisite is missing ---
if [[ "$PREREQ_FAIL" -gt 0 ]]; then
  echo ""
  die "FAILED: ${PREREQ_FAIL} prerequisite(s) not met. Fix and re-run."
fi

resolve_git_context
if ! classify_scope_impact; then
  log_function_output print_scope_classification_failure
  die "Unsupported scope for branch-safety classification."
fi

detect_initial_deploy
if [[ "${INITIAL_DEPLOY}" -eq 0 ]]; then
  refresh_gitlab_prod_ref
fi

if ! check_branch_safety; then
  log_function_output print_branch_safety_refusal
  die "Branch safety refused this rebuild before any build or apply steps."
fi

if [[ "${INITIAL_DEPLOY}" -eq 0 ]]; then
  resolve_last_known_prod_context
  detect_config_yaml_divergence
else
  GITLAB_FETCH_ATTEMPTED=0
  GITLAB_FETCH_SUCCEEDED=0
  GITLAB_FETCH_DETAIL="not attempted (initial deploy)"
  LAST_KNOWN_PROD_AVAILABLE=0
  LAST_KNOWN_PROD_COMMIT=""
  LAST_KNOWN_PROD_COMMIT_SHORT=""
  LAST_KNOWN_PROD_DATE=""
  LAST_KNOWN_PROD_DIFFERS_FROM_CURRENT=0
  CONFIG_YAML_DIFF=0
  log "No existing deployment detected - treating as initial deploy. Branch check skipped."
fi

log_function_output print_deploy_banner
if [[ "${OVERRIDE_BRANCH_CHECK}" -eq 1 ]] && scope_requires_prod_branch; then
  log_function_output print_last_known_prod_comparison
fi
log_function_output write_deploy_manifest

step_done 0 "Prerequisites verified and deploy context recorded"

# =====================================================================
# Step 1: Configure node networking
# =====================================================================
if step_in_scope networking; then
  step_start 1 "Configure node networking"
  # configure-node-network.sh handles its own reboot-and-retry cycle
  # when NIC pinning needs to change. It exits 0 on success, 1 on error.
  "${SCRIPT_DIR}/configure-node-network.sh" --all --force
  step_done 1 "Node networking configured"
else
  step_skip 1 "Networking (not in scope)"
fi

# =====================================================================
# Step 2: Configure node storage
# =====================================================================
if step_in_scope storage; then
  step_start 2 "Configure node storage"
  "${SCRIPT_DIR}/configure-node-storage.sh" --all
  step_done 2 "Node storage configured"
else
  step_skip 2 "Storage (not in scope)"
fi

# =====================================================================
# Step 3: Form Proxmox cluster
# =====================================================================
if step_in_scope cluster; then
  step_start 3 "Form Proxmox cluster"
  FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
  CLUSTER_STATUS=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${FIRST_NODE_IP}" "pvecm status 2>/dev/null | grep -c 'Cluster Name:' || echo 0" | tail -1)
  if [[ "$CLUSTER_STATUS" -gt 0 ]]; then
    step_skip 3 "Cluster already formed"
  else
    "${SCRIPT_DIR}/form-cluster.sh"
    step_done 3 "Cluster formed"
  fi
else
  step_skip 3 "Cluster (not in scope)"
fi

# =====================================================================
# Step 4: Configure storage (snippets on local)
# =====================================================================
if step_in_scope snippets; then
  step_start 4 "Configure storage (snippets)"
  "${SCRIPT_DIR}/configure-storage.sh"
  step_done 4 "Storage snippets configured"
else
  step_skip 4 "Snippets (not in scope)"
fi

# =====================================================================
# Step 5: Build VM images
# =====================================================================
step_start 5 "Build VM images"
rm -f "$BUILD_MARKER"
# build-all-images.sh builds every role and uploads each after building.
# For scoped deploys, we still build all to keep image-versions.auto.tfvars
# complete (tofu needs all entries), but nix caching makes unchanged
# roles fast (seconds each).
"${SCRIPT_DIR}/build-all-images.sh" $BUILD_FLAGS
touch "$BUILD_MARKER"
step_done 5 "All images built"

# Step 6 (upload) is handled by build-image.sh — each image is uploaded
# to all nodes immediately after building. No separate upload step needed.

# --- Pre-apply: ensure application secrets exist in SOPS ---
# On-demand pre-deploy secrets: generate missing tokens for enabled
# applications before tofu apply needs them for CIDATA generation.
log "    Ensuring application secrets..."
"${SCRIPT_DIR}/ensure-app-secrets.sh"

# =====================================================================
# Step 7: OpenTofu init + apply
# =====================================================================
step_start 7 "OpenTofu init and apply"
if [[ ! -f "$BUILD_MARKER" ]]; then
  die "Build step did not complete. Cannot deploy with stale images. Re-run rebuild-cluster.sh from the beginning."
fi
# Regenerate Gatus config from config.yaml before tofu reads it.
# The config is consumed by tofu (write_files on the Gatus VM).
if ! GATUS_EXPECTED_SOURCE_COMMIT="$(resolve_gatus_expected_source_commit)"; then
  die "Could not resolve a source commit SHA for the Gatus GitHub mirror endpoint."
fi
log "    Generating Gatus config for GitHub mirror source ${GATUS_EXPECTED_SOURCE_COMMIT:0:12}..."
mkdir -p "${REPO_DIR}/site/gatus"
GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${GATUS_EXPECTED_SOURCE_COMMIT}" \
  "${SCRIPT_DIR}/generate-gatus-config.sh" > "${REPO_DIR}/site/gatus/config.yaml"
cd "$TOFU_DIR"
"${SCRIPT_DIR}/tofu-wrapper.sh" init -input=false
# Clear any HA resources in error state before applying.
# This can happen when a VM was stopped/started outside HA (e.g., PBS ISO install).
# The fix is to cycle through disabled → started to clear the error.
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
HA_ERRORS=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "root@${FIRST_NODE_IP}" "ha-manager status 2>/dev/null | grep error | awk '{print \$2}'" 2>/dev/null || true)
if [[ -n "$HA_ERRORS" ]]; then
  for HA_SID in $HA_ERRORS; do
    log "    Clearing HA error state on ${HA_SID}..."
    ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${FIRST_NODE_IP}" "ha-manager set ${HA_SID} --state disabled 2>/dev/null; sleep 2; ha-manager set ${HA_SID} --state started 2>/dev/null" || true
  done
  sleep 5
fi
# Compute data-plane targets if deferred. Enumerate from configuration
# (framework/tofu/root/*.tf), not from `tofu state list` — state may be
# empty (cold rebuild, prior state cleanup, fresh workspace) which would
# silently leave TOFU_TARGETS empty and let the bulk apply target the
# whole config including control-plane (#270).
if [[ "$TOFU_TARGETS" == "DATA_PLANE_DEFERRED" ]]; then
  # Capture stdout in a variable AND check exit status outside the read
  # loop. With `< <(collect_configured_root_modules)` the helper's stdout
  # is the loop's input — if the helper writes a FATAL log to stdout via
  # die() and exits, the FATAL string gets read as a $mod and silently
  # appended as `-target=FATAL: ...`, defeating the empty-list guard.
  if ! CONFIGURED_MODULES="$(collect_configured_root_modules)"; then
    die "--scope data-plane could not discover root modules from ${TOFU_DIR}."
  fi
  TOFU_TARGETS=""
  while IFS= read -r mod; do
    [[ -z "$mod" ]] && continue
    IS_CP=false
    for cp in $CONTROL_PLANE_MODULES; do
      [[ "$mod" == "$cp" ]] && IS_CP=true
    done
    if [[ "$IS_CP" == "false" ]]; then
      TOFU_TARGETS="$TOFU_TARGETS -target=$mod"
    fi
  done <<< "$CONFIGURED_MODULES"
  if [[ -z "$TOFU_TARGETS" ]]; then
    die "--scope data-plane produced empty target list (no non-control-plane modules in ${TOFU_DIR}). Refusing to apply the whole configuration."
  fi
  log "    Data-plane targets: $TOFU_TARGETS"
fi

# Pre-apply: check if PBS VM is in tofu state but missing from Proxmox.
# This happens after a stale NFS recovery (previous run destroyed the VM
# and partially cleaned state). prevent_destroy blocks tofu from handling
# this — we must clean the orphaned state entries before applying.
PBS_VMID_CHECK=$(yq -r '.vms.pbs.vmid // ""' "$CONFIG")
if [[ -n "$PBS_VMID_CHECK" && "$PBS_VMID_CHECK" != "null" ]]; then
  PBS_IN_STATE=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null | grep -c '^module\.pbs\.' || echo "0")
  if [[ "$PBS_IN_STATE" -gt 0 ]]; then
    # Check if the VM actually exists on Proxmox
    PBS_EXISTS=false
    for node_ip in $(yq -r '.nodes[].mgmt_ip' "$CONFIG"); do
      if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "root@${node_ip}" "qm status ${PBS_VMID_CHECK}" >/dev/null 2>&1; then
        PBS_EXISTS=true
        break
      fi
    done
    if [[ "$PBS_EXISTS" == "false" ]]; then
      log "    PBS VM ${PBS_VMID_CHECK} in tofu state but not on Proxmox — cleaning state..."
      for res in $("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null | grep '^module\.pbs\.' || true); do
        "${SCRIPT_DIR}/tofu-wrapper.sh" state rm "$res" 2>/dev/null || true
      done
    fi
  fi
fi

# Clean PBS HA resource from Proxmox if tofu doesn't know about it.
# install-pbs.sh adds HA via ha-manager (outside tofu). If tofu then
# tries to create the HA resource, it fails with "already defined."
# Remove it from Proxmox so tofu can manage it cleanly.
#
# Tighten the trigger: only fire when state has a PBS VM resource AND
# no PBS haresource entry. That matches the documented install-pbs.sh
# handoff scenario. Empty state (cold rebuild, prior cleanup, fresh
# workspace — the #270 hazard class) does NOT match, so we no longer
# silently deregister the live PBS HA when state is wiped. (#270 /
# codex P2-2)
if [[ -n "$PBS_VMID_CHECK" && "$PBS_VMID_CHECK" != "null" ]]; then
  PBS_STATE_LIST=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null || true)
  PBS_HA_IN_STATE=$(echo "$PBS_STATE_LIST" | grep -c 'module\.pbs.*haresource' || true)
  PBS_VM_IN_STATE=$(echo "$PBS_STATE_LIST" | grep -c 'module\.pbs.*proxmox_virtual_environment_vm' || true)
  if [[ "$PBS_HA_IN_STATE" -eq 0 && "$PBS_VM_IN_STATE" -gt 0 ]]; then
    FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
    PBS_HA_IN_PROXMOX=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${FIRST_NODE_IP}" "ha-manager status 2>/dev/null | grep -c 'vm:${PBS_VMID_CHECK}'" 2>/dev/null || echo "0")
    if [[ "$PBS_HA_IN_PROXMOX" -gt 0 ]]; then
      log "    PBS HA resource exists in Proxmox but not in tofu state — removing from Proxmox..."
      ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${FIRST_NODE_IP}" "ha-manager remove vm:${PBS_VMID_CHECK}" 2>/dev/null || true
    fi
  fi
fi

# Pre-apply backup: back up all precious-state VMs before tofu apply destroys
# and recreates them. This ensures the backup is fresh regardless of the PBS
# schedule. If PBS is unreachable (e.g., PBS itself is being rebuilt), warn
# but proceed — the operator accepted this risk by running rebuild-cluster.sh.
if [[ -x "${SCRIPT_DIR}/backup-now.sh" ]]; then
  log "    Taking pre-deploy backup of precious-state VMs..."
  if "${SCRIPT_DIR}/backup-now.sh" 2>&1 | sed 's/^/    /'; then
    log "    Pre-deploy backup complete"
  else
    log "    WARNING: Pre-deploy backup failed — proceeding with existing backups"
    log "    If this is a full rebuild (PBS not yet deployed), this is expected."
  fi
else
  log "    WARNING: backup-now.sh not found — skipping pre-deploy backup"
fi

# --- Verify HA resources against Proxmox before apply ---
# The bpg provider's Read function does not detect HA resources that are
# missing from Proxmox but present in tofu state (verified broken on
# v0.99.0, v0.100.0, v0.101.0). Query Proxmox directly via SSH to detect
# and remove stale HA state entries before the apply encounters them.
# See: docs/reports/report-v0101-ha-read-still-broken-2026-04-09.md
# Verify HA resources: remove stale state entries and orphan Proxmox HA
# resources left by killed applies. See issues #20, #158, #190.
verify_ha_resources() {
  local node_ip="$1"

  # Distinguish "state list succeeded with zero HA entries" from "state list
  # failed." A failed state list with || true produces empty ha_resources,
  # which would cause Phase 1b to treat every Proxmox HA resource as an
  # orphan and remove it. Fail closed on state list failure. (#190)
  local all_state=""
  local ha_resources=""
  set +e
  all_state=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null)
  local state_list_exit=$?
  set -e
  if [[ $state_list_exit -ne 0 ]]; then
    log "    ERROR: tofu state list failed (exit ${state_list_exit}) — cannot determine HA state"
    log "    ERROR: Failing closed — refusing to proceed without reliable state"
    return 1
  fi
  ha_resources=$(echo "$all_state" | grep 'haresource' || true)

  local proxmox_ha
  proxmox_ha=$(ssh -n -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${node_ip}" \
    "pvesh get /cluster/ha/resources --output-format json" 2>/dev/null)

  if [[ -z "$proxmox_ha" || "$proxmox_ha" == "null" ]]; then
    log "    ERROR: Cannot query HA resources from ${node_ip}"
    log "    ERROR: Failing closed — refusing to proceed without HA verification"
    return 1
  fi

  local proxmox_vmids
  proxmox_vmids=$(echo "$proxmox_ha" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    for r in data:
        sid = r.get('sid', '')
        if sid.startswith('vm:'):
            print(sid.split(':')[1])
except:
    pass
  ")

  # Phase 1: Remove stale state entries (in state but not in Proxmox)
  # Also collect state VMIDs for the reverse check in Phase 1b.
  local stale_count=0
  local state_vmids=""
  local state_extract_failures=0
  if [[ -n "$ha_resources" ]]; then
    while IFS= read -r resource_addr; do
      [[ -z "$resource_addr" ]] && continue
      local vmid
      vmid=$("${SCRIPT_DIR}/tofu-wrapper.sh" state show "$resource_addr" \
        2>/dev/null | grep 'resource_id' | grep -o '[0-9]*' || true)

      if [[ -z "$vmid" ]]; then
        log "    WARNING: Could not extract VMID from ${resource_addr} — skipping"
        state_extract_failures=$((state_extract_failures + 1))
        continue
      fi

      state_vmids="${state_vmids}${vmid}"$'\n'

      if ! echo "$proxmox_vmids" | grep -q "^${vmid}$"; then
        log "    HA resource vm:${vmid} in state but NOT in Proxmox — removing stale entry"
        log "      State address: ${resource_addr}"
        "${SCRIPT_DIR}/tofu-wrapper.sh" state rm "$resource_addr" >/dev/null 2>&1
        stale_count=$((stale_count + 1))
      fi
    done <<< "$ha_resources"

    if [[ $stale_count -gt 0 ]]; then
      log "    Removed ${stale_count} stale HA resource(s) from state"
    fi
  fi

  # Phase 1b: Remove orphan Proxmox HA resources (in Proxmox but not in state).
  # These are left behind by killed tofu apply runs that created the HA resource
  # in Proxmox but were killed before tofu finished writing the state entry.
  # Without this, the next tofu apply plans CREATE for the HA resource, and
  # Proxmox rejects with "resource ID already defined." (#190)
  #
  # Safety 1: skip Phase 1b if any state extraction failed in Phase 1.
  # An incomplete state_vmids list would cause legitimate HA resources to
  # be removed. Fail closed — leave orphans rather than destroy good state.
  #
  # Safety 2: never remove HA for any VMID present in site/config.yaml or
  # site/applications.yaml. State can be empty (cold rebuild, --scope
  # data-plane on a fresh workspace, prior tofu state rm cleanup) while
  # Proxmox still has live HA registrations for framework-managed VMs.
  # Without this guard, an empty state silently deregisters every
  # framework-managed HA resource on the way through Phase 1b. The
  # configured-VMID set is the source of truth for "this VMID belongs
  # to the framework"; only VMIDs absent from both config files are
  # genuine orphans (e.g., manually-added HA, abandoned VMIDs from a
  # previous cluster). (#270 / codex P2-2)
  local configured_vmids=""
  configured_vmids=$(yq '.vms[].vmid' "$CONFIG" 2>/dev/null | grep -v '^null$' || true)
  if [[ -f "$APPS_CONFIG" ]]; then
    local app_vmids
    app_vmids=$(yq '.applications | to_entries[] | .value.environments | to_entries[] | .value.vmid' \
      "$APPS_CONFIG" 2>/dev/null | grep -v '^null$' || true)
    if [[ -n "$app_vmids" ]]; then
      configured_vmids="${configured_vmids}"$'\n'"${app_vmids}"
    fi
  fi
  local orphan_count=0
  local orphan_remove_failures=0
  local preserved_count=0
  if [[ $state_extract_failures -gt 0 ]]; then
    log "    WARNING: ${state_extract_failures} state extraction(s) failed — skipping orphan cleanup"
    log "    Phase 1b cannot safely identify orphans without a complete state VMID list"
  else
  while IFS= read -r proxmox_vmid; do
    [[ -z "$proxmox_vmid" ]] && continue
    if ! echo "$state_vmids" | grep -q "^${proxmox_vmid}$"; then
      if echo "$configured_vmids" | grep -q "^${proxmox_vmid}$"; then
        log "    HA resource vm:${proxmox_vmid} not in state but IS in config — preserving (framework-managed)"
        preserved_count=$((preserved_count + 1))
        continue
      fi
      log "    HA resource vm:${proxmox_vmid} in Proxmox but NOT in state or config — removing orphan"
      if ssh -n -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${node_ip}" \
        "ha-manager remove vm:${proxmox_vmid}" 2>/dev/null; then
        orphan_count=$((orphan_count + 1))
      else
        log "    ERROR: ha-manager remove failed for vm:${proxmox_vmid} — orphan remains"
        orphan_remove_failures=$((orphan_remove_failures + 1))
      fi
    fi
  done <<< "$proxmox_vmids"

  if [[ $preserved_count -gt 0 ]]; then
    log "    Preserved ${preserved_count} framework-managed HA resource(s) absent from state"
  fi

  if [[ $orphan_count -gt 0 ]]; then
    log "    Removed ${orphan_count} orphan HA resource(s) from Proxmox"
  fi
  fi  # end state_extract_failures guard

  if [[ $orphan_remove_failures -gt 0 ]]; then
    log "    WARNING: ${orphan_remove_failures} orphan removal(s) failed — next apply may encounter 'already defined'"
  elif [[ $stale_count -eq 0 && $orphan_count -eq 0 ]]; then
    log "    All HA resources verified"
  fi

  return 0
}

log "    Verifying HA resources against Proxmox..."
if ! verify_ha_resources "$FIRST_NODE_IP"; then
  die "HA resource verification failed — cannot proceed with apply"
fi

# With the bpg/proxmox ~> 0.101 baseline, apply-time planning detects
# missing HA resources once the VM exists, and CREATE sets the HA
# attributes. Keep a second apply as a conservative convergence pass
# after VM recreation. The explicit refresh and third apply are no
# longer needed.
ATOMIC_RECREATED_MODULES=()

collect_bulk_apply_modules() {
  if [[ -n "$TOFU_TARGETS" ]]; then
    for target in $TOFU_TARGETS; do
      printf '%s\n' "${target#-target=}"
    done
  else
    # Trade-off: in a mixed full rebuild, configuration is the source of truth
    # for the later bulk pass. That keeps atomically recreated control-plane
    # modules out of the final two applies without letting incomplete state hide
    # config-defined modules that still need convergence.
    collect_configured_root_modules
  fi
}

build_filtered_targets() {
  local modules=()
  local candidate
  local excluded
  local skip

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    skip=0
    for excluded in "${ATOMIC_RECREATED_MODULES[@]}"; do
      if [[ "$candidate" == "$excluded" ]]; then
        skip=1
        break
      fi
    done
    [[ $skip -eq 0 ]] && modules+=("$candidate")
  done < <(collect_bulk_apply_modules)

  if [[ "${#modules[@]}" -eq 0 ]]; then
    return 0
  fi

  local rendered=""
  for candidate in "${modules[@]}"; do
    rendered+=" -target=${candidate}"
  done
  printf '%s' "$rendered"
}

build_rebuild_default_plan_json() {
  local label="$1"
  local target_flags="${2:-}"
  local plan_json_out="$3"
  local plan_out="${LOG_DIR}/preboot-restore-plan-${label}.out"
  local show_raw="${LOG_DIR}/preboot-restore-plan-${label}.raw"

  log "    Planning default VM start/HA state for preboot manifest (${label})..."
  "${SCRIPT_DIR}/tofu-wrapper.sh" plan $target_flags \
    -out="$plan_out" \
    -no-color
  tofu -chdir="$TOFU_DIR" show -json "$plan_out" > "$show_raw"
PLAN_RAW="$show_raw" PLAN_JSON_OUT="$plan_json_out" python3 - <<'PY'
import json
import os
import sys

raw_path = os.environ["PLAN_RAW"]
out_path = os.environ["PLAN_JSON_OUT"]
with open(raw_path) as f:
    data = f.read()
start = data.find("{")
if start < 0:
    print(f"ERROR: no JSON object in tofu show output: {raw_path}", file=sys.stderr)
    sys.exit(1)
decoder = json.JSONDecoder()
obj, _ = decoder.raw_decode(data[start:])
os.makedirs(os.path.dirname(out_path), exist_ok=True)
with open(out_path, "w") as f:
    json.dump(obj, f)
    f.write("\n")
PY
}

write_preboot_manifest_for_modules() {
  local manifest_out="$1"
  local target_flags="${2:-}"
  local plan_json="$3"

  TARGET_FLAGS="$target_flags" \
  PLAN_JSON="$plan_json" \
  CONFIG_FILE="$CONFIG" \
  APPS_CONFIG_FILE="$APPS_CONFIG" \
  RESTORE_PIN_FILE="$RESTORE_PIN_FILE" \
  MANIFEST_OUT="$manifest_out" \
  python3 - <<'PY'
import json
import os
import re
import subprocess
import sys


def load_yaml_json(path, default, required=False):
    if not os.path.exists(path):
        if required:
            print(f"ERROR: required config file not found: {path}", file=sys.stderr)
            sys.exit(1)
        return default
    try:
        raw = subprocess.check_output(
            ["yq", "-o=json", ".", path],
            stderr=subprocess.PIPE,
            text=True,
        )
        return json.loads(raw)
    except subprocess.CalledProcessError as exc:
        stderr = (exc.stderr or "").strip()
        print(f"ERROR: failed to parse YAML config with yq: {path}", file=sys.stderr)
        if stderr:
            print(stderr, file=sys.stderr)
        sys.exit(1)
    except json.JSONDecodeError as exc:
        print(f"ERROR: yq produced invalid JSON for {path}: {exc}", file=sys.stderr)
        sys.exit(1)


def root_module(address):
    parts = address.split(".")
    if len(parts) < 2 or parts[0] != "module":
        return ""
    label = re.sub(r"\[.*\]$", "", parts[1])
    return f"module.{label}"


def label_env(label):
    if label.endswith("_dev"):
        return "dev"
    if label.endswith("_prod"):
        return "prod"
    return "shared"


def add_backup_module(backups, label, vmid, kind):
    if vmid in (None, ""):
        return
    try:
        vmid_int = int(vmid)
    except Exception:
        return
    backups[f"module.{label}"] = {
        "label": label,
        "module": f"module.{label}",
        "vmid": vmid_int,
        "env": label_env(label),
        "kind": kind,
    }


config = load_yaml_json(os.environ["CONFIG_FILE"], {}, required=True)
apps = load_yaml_json(os.environ["APPS_CONFIG_FILE"], {"applications": {}})
backups = {}

for label, vm in (config.get("vms") or {}).items():
    if isinstance(vm, dict) and vm.get("backup") is True:
        kind = "control-plane" if label in {"gitlab", "cicd", "pbs"} else "infrastructure"
        add_backup_module(backups, label, vm.get("vmid"), kind)

for app, app_cfg in (apps.get("applications") or {}).items():
    if not isinstance(app_cfg, dict):
        continue
    if app_cfg.get("enabled") is not True or app_cfg.get("backup") is not True:
        continue
    for app_env, env_cfg in (app_cfg.get("environments") or {}).items():
        if isinstance(env_cfg, dict):
            add_backup_module(backups, f"{app}_{app_env}", env_cfg.get("vmid"), "application")

target_flags = os.environ.get("TARGET_FLAGS", "")
targets = {
    match.group(1)
    for match in re.finditer(r"-target=(module\.[^\s]+)", target_flags)
}

pins = {}
pin_file = os.environ.get("RESTORE_PIN_FILE", "")
if pin_file and os.path.exists(pin_file):
    try:
        with open(pin_file) as f:
            pins = (json.load(f).get("pins") or {})
    except Exception:
        pins = {}

with open(os.environ["PLAN_JSON"]) as f:
    plan = json.load(f)

entries_by_module = {}
for rc in plan.get("resource_changes", []):
    address = rc.get("address", "")
    if "proxmox_virtual_environment_vm.vm" not in address:
        continue

    module = root_module(address)
    if targets and module not in targets:
        continue

    backup = backups.get(module)
    if not backup:
        continue

    change = rc.get("change") or {}
    actions = change.get("actions") or []
    before = change.get("before") or {}
    after = change.get("after") or {}

    reason = ""
    if actions == ["create"]:
        reason = "create"
    elif "create" in actions and "delete" in actions:
        reason = "replace"
    elif before.get("started") is False and after.get("started") is True:
        reason = "started-false-resume"

    if not reason:
        continue

    entry = dict(backup)
    entry["reason"] = reason
    pin = pins.get(str(entry["vmid"]))
    if pin:
        entry["pin"] = pin
    entries_by_module[module] = entry

manifest = {
    "version": 1,
    "scope": "all",
    "source": "rebuild-default-plan",
    "entries": [entries_by_module[key] for key in sorted(entries_by_module)],
}
os.makedirs(os.path.dirname(os.environ["MANIFEST_OUT"]), exist_ok=True)
with open(os.environ["MANIFEST_OUT"], "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
}

run_preboot_restore_for_modules() {
  local label="$1"
  local target_flags="${2:-}"
  local plan_json="$3"
  local manifest="${LOG_DIR}/preboot-restore-${label}.json"
  local args=(all --manifest "$manifest")

  write_preboot_manifest_for_modules "$manifest" "$target_flags" "$plan_json"
  log "    restore-before-start manifest (${label}): ${manifest}"
  if [[ -n "$RESTORE_PIN_FILE" ]]; then
    args+=(--pin-file "$RESTORE_PIN_FILE")
  fi

  "${SCRIPT_DIR}/restore-before-start.sh" "${args[@]}"
}

ensure_pbs_installed_and_configured() {
  if [[ -z "${PBS_VMID_CHECK:-}" || "${PBS_VMID_CHECK}" == "null" ]]; then
    log "    No PBS configured in config.yaml"
    return 0
  fi

  local original_dir="$PWD"
  local pbs_exit

  # install-pbs.sh is idempotent: skips if PBS is already installed (HTTPS responding).
  "${SCRIPT_DIR}/install-pbs.sh"

  # configure-pbs.sh is idempotent: sets up SSH keys, NFS mount, datastore,
  # API token, Proxmox storage entry. Backup jobs are deferred to step 15.5
  # (after restore verification) to prevent overwriting good backups with
  # empty state if the restore fails.
  # Exit code 10 = stale NFS mount, need to recreate the PBS VM.
  set +e
  "${SCRIPT_DIR}/configure-pbs.sh" --skip-backup-jobs
  pbs_exit=$?
  set -e
  if [[ $pbs_exit -eq 10 ]]; then
    log "    Stale NFS mount — recreating PBS VM..."
    local pbs_vmid
    local pbs_host=""
    local node_ip
    pbs_vmid=$(yq -r '.vms.pbs.vmid' "$CONFIG")
    # Find hosting node
    for node_ip in $(yq -r '.nodes[].mgmt_ip' "$CONFIG"); do
      if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "root@${node_ip}" "qm status ${pbs_vmid}" >/dev/null 2>&1; then
        pbs_host="$node_ip"
        break
      fi
    done
    if [[ -n "$pbs_host" ]]; then
      # Destroy via Proxmox API (bypasses tofu's prevent_destroy)
      log "    Destroying PBS VM ${pbs_vmid} on ${pbs_host}..."
      ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${pbs_host}" "ha-manager remove vm:${pbs_vmid} 2>/dev/null; qm stop ${pbs_vmid} --skiplock 2>/dev/null; sleep 5; qm destroy ${pbs_vmid} --purge --skiplock 2>/dev/null" || true
    fi
    # Remove ALL PBS resources from tofu state so apply creates them fresh.
    # Surgical removal misses dependent resources (HA, snippets) that
    # trigger prevent_destroy via the dependency chain.
    cd "$TOFU_DIR"
    for res in $("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null | grep '^module\.pbs\.' || true); do
      "${SCRIPT_DIR}/tofu-wrapper.sh" state rm "$res" 2>/dev/null || true
    done
    # Clean stale zvols
    if [[ -n "$pbs_host" ]]; then
      ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${pbs_host}" "zfs destroy -r vmstore/data/vm-${pbs_vmid}-disk-0 2>/dev/null; zfs destroy -r vmstore/data/vm-${pbs_vmid}-disk-1 2>/dev/null; zfs destroy -r vmstore/data/vm-${pbs_vmid}-cloudinit 2>/dev/null" || true
    fi
    "${SCRIPT_DIR}/tofu-wrapper.sh" apply -target=module.pbs -auto-approve -input=false
    cd "$original_dir"
    log "    PBS VM recreated. Re-running install and configure..."
    "${SCRIPT_DIR}/install-pbs.sh"
    # Wait for PBS SSH to be ready (HTTPS may be up before SSH)
    local pbs_ip_wait
    pbs_ip_wait=$(yq -r '.vms.pbs.ip' "$CONFIG")
    for i in $(seq 1 30); do
      if sshpass -p "$(sops -d --extract '["pbs_root_password"]' "${REPO_DIR}/site/sops/secrets.yaml" 2>/dev/null)" \
          ssh -n -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "root@${pbs_ip_wait}" "true" 2>/dev/null; then
        break
      fi
      sleep 5
    done
    "${SCRIPT_DIR}/configure-pbs.sh" --skip-backup-jobs
  elif [[ $pbs_exit -ne 0 ]]; then
    die "configure-pbs.sh failed (exit $pbs_exit)"
  fi
}

APPLY_ARGS="-auto-approve -input=false"

# Control-plane VMs (gitlab, cicd) use proxmox-vm-precious with prevent_destroy.
# -replace= does NOT override prevent_destroy — tofu rejects the plan.
# The authorized override: destroy via Proxmox API, remove from tofu state,
# then apply creates the VM fresh. Only done when tofu plan shows pending
# changes (image, CIDATA, or config). tofu plan is the authoritative source
# of truth — it catches all forms of drift, not just image hash changes.
STATE_OUTPUT=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>&1) || true
for mod in $CONTROL_PLANE_MODULES; do
  if [[ "$TOFU_TARGETS" == *"$mod"* || -z "$TOFU_TARGETS" ]]; then
    mod_name=$(echo "$mod" | sed 's/module\.//')

    # Check if this module has any pending changes via tofu plan
    log "    ${mod_name}: checking for pending changes..."
    plan_stderr="/tmp/rebuild-cp-plan-stderr-${mod_name}.txt"
    rm -f "$plan_stderr"
    set +e
    "${SCRIPT_DIR}/tofu-wrapper.sh" plan \
      -target="${mod}" \
      -detailed-exitcode \
      -no-color \
      2>"$plan_stderr" >/dev/null
    PLAN_EXIT=$?
    set -e

    if [[ "$PLAN_EXIT" -eq 0 ]]; then
      log "    ${mod_name}: no pending changes — skipping"
      rm -f "$plan_stderr"
      continue
    elif [[ "$PLAN_EXIT" -eq 2 ]]; then
      # Changes detected, prevent_destroy did NOT fire.
      # For gitlab/pbs: exit 2 means the change does NOT require VM destruction
      # (if it did, prevent_destroy would have fired → exit 1). Safe for tofu apply.
      # For cicd: exit 2 may include VM replacement (no prevent_destroy). Also safe
      # for tofu apply since cicd has no prevent_destroy — tofu handles it directly.
      log "    ${mod_name}: pending changes detected (deployable by tofu apply)"
      rm -f "$plan_stderr"
      continue
    elif [[ "$PLAN_EXIT" -eq 1 ]]; then
      # Check for prevent_destroy signal (gitlab, pbs image/CIDATA changes)
      if grep -q "Instance cannot be destroyed" "$plan_stderr" 2>/dev/null; then
        log "    ${mod_name}: pending changes BLOCKED by prevent_destroy — will destroy and recreate"
        rm -f "$plan_stderr"
      else
        # Genuine infrastructure error — cannot determine state
        log "    ERROR: tofu plan failed for ${mod_name}:"
        tail -10 "$plan_stderr" >&2 || true
        rm -f "$plan_stderr"
        die "Cannot determine state for ${mod_name}. Fix the infrastructure error and retry."
      fi
    fi

    # Only reach here when prevent_destroy blocked a change (exit 1).
    # Atomic per-VM rebuild: destroy → state rm → apply → restore.
    # Each VM is fully rebuilt before touching the next one. If this VM's
    # rebuild fails, previous VMs are already recovered and subsequent VMs
    # are untouched. (#149)

    # Find VMID and hosting node
    VMID=$(yq -r ".vms.${mod_name}.vmid // \"\"" "$CONFIG")
    if [[ -z "$VMID" || "$VMID" == "null" ]]; then
      log "    WARNING: No VMID found for ${mod_name} in config.yaml — skipping"
      continue
    fi
    HOSTING_IP=""
    for node_ip in $(yq -r '.nodes[].mgmt_ip' "$CONFIG"); do
      if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "root@${node_ip}" "qm status ${VMID}" >/dev/null 2>&1; then
        HOSTING_IP="$node_ip"
        break
      fi
    done

    if [[ -n "$HOSTING_IP" ]]; then
      log "    Destroying ${mod_name} (VMID ${VMID}) on ${HOSTING_IP} for recreation..."
      ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${HOSTING_IP}" "ha-manager remove vm:${VMID} 2>/dev/null || true"
      ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${HOSTING_IP}" "qm stop ${VMID} --skiplock 1 2>/dev/null || true"
      # Poll for stopped status (gitlab may take 30+ seconds to shut down)
      STOP_WAIT=0
      while [[ $STOP_WAIT -lt 30 ]]; do
        VM_STATUS=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "root@${HOSTING_IP}" "qm status ${VMID} 2>/dev/null | awk '{print \$2}'" || echo "unknown")
        [[ "$VM_STATUS" == "stopped" ]] && break
        sleep 2
        STOP_WAIT=$((STOP_WAIT + 2))
        ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "root@${HOSTING_IP}" "qm stop ${VMID} --skiplock 1 2>/dev/null || true"
      done
      ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${HOSTING_IP}" "qm destroy ${VMID} --purge --skiplock 1 2>/dev/null || true"
      # Clean stale zvols — explicit names only, fail on unexpected errors
      for zvol_suffix in disk-0 disk-1 cloudinit; do
        ZVOL="vmstore/data/vm-${VMID}-${zvol_suffix}"
        ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "root@${HOSTING_IP}" "zfs destroy -r ${ZVOL} 2>&1 | grep -v 'dataset does not exist' || true"
      done
    fi

    # Remove all resources for this module from tofu state
    REMOVED=0
    RM_FAILURES=0
    for res in $(echo "$STATE_OUTPUT" | grep "^${mod}\."); do
      if "${SCRIPT_DIR}/tofu-wrapper.sh" state rm "$res" >/dev/null 2>&1; then
        REMOVED=$((REMOVED + 1))
      else
        log "    ERROR: failed to remove ${res} from state"
        RM_FAILURES=$((RM_FAILURES + 1))
      fi
    done
    log "    Removed ${REMOVED} resources from tofu state for ${mod_name}"
    if [[ $RM_FAILURES -gt 0 ]]; then
      die "Failed to remove ${RM_FAILURES} resource(s) from state for ${mod_name}. Cannot proceed — tofu apply would hit prevent_destroy."
    fi

    ATOMIC_PLAN_JSON="${LOG_DIR}/preboot-restore-plan-atomic-${mod_name}.json"
    build_rebuild_default_plan_json "atomic-${mod_name}" "-target=${mod}" "$ATOMIC_PLAN_JSON"

    # --- Atomic recreate: apply stopped, restore, then start/register ---
    log "    Recreating ${mod_name} stopped with HA disabled..."
    "${SCRIPT_DIR}/tofu-wrapper.sh" apply -target="${mod}" \
      -var=start_vms=false \
      -var=register_ha=false \
      -auto-approve -input=false

    log "    Restoring ${mod_name} before start..."
    run_preboot_restore_for_modules "atomic-${mod_name}" "-target=${mod}" "$ATOMIC_PLAN_JSON" \
      || die "Preboot restore failed for ${mod_name}; VM remains stopped."

    log "    Starting ${mod_name} and registering HA..."
    "${SCRIPT_DIR}/tofu-wrapper.sh" apply -target="${mod}" \
      -var=start_vms=true \
      -var=register_ha=true \
      -auto-approve -input=false
    ATOMIC_RECREATED_MODULES+=("${mod}")

    # Refresh SSH host key for the recreated VM
    VM_IP=$(yq -r ".vms.${mod_name}.ip // \"\"" "$CONFIG")
    if [[ -n "$VM_IP" && "$VM_IP" != "null" ]]; then
      ssh-keygen -R "$VM_IP" 2>/dev/null || true
    fi

    # --- PBS post-install (if this is the PBS module) ---
    if [[ "$mod_name" == "pbs" ]]; then
      log "    Running PBS install and configure..."
      "${SCRIPT_DIR}/install-pbs.sh"
      "${SCRIPT_DIR}/configure-pbs.sh" --skip-backup-jobs
    fi

    log "    ${mod_name}: atomic rebuild complete"
  fi
done

BULK_TARGETS="$TOFU_TARGETS"
if [[ "${#ATOMIC_RECREATED_MODULES[@]}" -gt 0 ]]; then
  BULK_TARGETS="$(build_filtered_targets)"
fi

if [[ -n "$BULK_TARGETS" ]]; then
  log "    Scoped apply targets: $BULK_TARGETS"
  APPLY_ARGS="$BULK_TARGETS $APPLY_ARGS"
fi

if [[ -z "$BULK_TARGETS" && -n "$TOFU_TARGETS" ]]; then
  log "    All scoped targets were recreated atomically; skipping bulk apply."
else
  BULK_PLAN_JSON="${LOG_DIR}/preboot-restore-plan-bulk.json"
  build_rebuild_default_plan_json "bulk" "$BULK_TARGETS" "$BULK_PLAN_JSON"

  echo "=== OpenTofu stopped apply ==="
  "${SCRIPT_DIR}/tofu-wrapper.sh" apply $APPLY_ARGS \
    -var=start_vms=false \
    -var=register_ha=false

  echo ""
  echo "=== PBS install/configure ==="
  ensure_pbs_installed_and_configured

  echo ""
  echo "=== restore-before-start.sh all ==="
  run_preboot_restore_for_modules "bulk" "$BULK_TARGETS" "$BULK_PLAN_JSON"

  echo ""
  echo "=== OpenTofu start apply ==="
  "${SCRIPT_DIR}/tofu-wrapper.sh" apply $APPLY_ARGS \
    -var=start_vms=true \
    -var=register_ha=true
fi

# Final HA verification: clean up stale/orphan entries from
# the applies. Runs once after ALL applies complete.
# Runs once after ALL applies are done — catches every HA resource created
# by any apply, regardless of which one created it. (#20, #158)
log "    Final HA verification..."
if ! verify_ha_resources "$FIRST_NODE_IP"; then
  log "    WARNING: Final HA verification failed"
fi
cd "$REPO_DIR"
# Refresh SSH host keys for all VMs (they may have been recreated)
log "    Refreshing SSH host keys for all VMs..."
for vm_key in $(yq -r '.vms | keys | .[]' "$CONFIG"); do
  VM_IP=$(yq -r ".vms.${vm_key}.ip" "$CONFIG")
  if [[ -n "$VM_IP" && "$VM_IP" != "null" ]]; then
    ssh-keygen -R "$VM_IP" 2>/dev/null || true
  fi
done
step_done 7 "All VMs created"

# --- Post-apply safety check: verify CIDATA is current ---
# Detect VMs running with stale CIDATA (e.g., wrong search domain after
# a domain change where the VM was not recreated).
EXPECTED_DOMAIN=$(yq -r '.domain' "$CONFIG")
STALE_VMS=""
log "    Verifying VM search domains match config.yaml (${EXPECTED_DOMAIN})..."
for ENV_CHECK in prod dev; do
  for VM_KEY in $(yq -r ".vms | to_entries[] | select(.key | test(\"_${ENV_CHECK}$\")) | .key" "$CONFIG" 2>/dev/null); do
    VM_IP=$(yq -r ".vms.${VM_KEY}.ip" "$CONFIG")
    HOSTNAME_PART=$(echo "$VM_KEY" | sed "s/_${ENV_CHECK}$//")
    EXPECTED_SD="${ENV_CHECK}.${EXPECTED_DOMAIN}"
    ACTUAL_SD=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${VM_IP}" "cat /run/secrets/network/search-domain 2>/dev/null" 2>/dev/null | tr -d '[:space:]' || true)
    if [[ -n "$ACTUAL_SD" && "$ACTUAL_SD" != "$EXPECTED_SD" ]]; then
      log "    STALE: ${VM_KEY} (${VM_IP}) has '${ACTUAL_SD}', expected '${EXPECTED_SD}'"
      STALE_VMS="${STALE_VMS} ${VM_KEY}"
    fi
  done
done
if [[ -n "$STALE_VMS" ]]; then
  log ""
  log "ERROR: VMs with stale CIDATA detected:${STALE_VMS}"
  log "These VMs were not recreated when config.yaml changed."
  log "Fix: taint the affected VMs and re-run rebuild-cluster.sh:"
  log "  cd site/tofu"
  for sv in $STALE_VMS; do
    # Determine the module path — may be nested (dns_dev → module.dns_dev.module.dns1)
    # For simplicity, use the direct module name
    log "  tofu taint 'module.${sv}.module.*.proxmox_virtual_environment_vm.vm'"
  done
  log "  Then re-run: framework/scripts/rebuild-cluster.sh"
  die "Stale CIDATA detected — VMs need recreation. See above."
fi
log "    All VMs have correct search domain"

# =====================================================================
# Step 7.5: Install and configure PBS
# =====================================================================
if step_in_scope pbs_install; then
  step_start 7.5 "Install and configure PBS"
  if [[ -z "${PBS_VMID_CHECK:-}" || "${PBS_VMID_CHECK}" == "null" ]]; then
    step_skip 7.5 "No PBS configured in config.yaml"
  else
    ensure_pbs_installed_and_configured
    step_done 7.5 "PBS installed and configured"
  fi
else
  step_skip 7.5 "PBS install (not in scope)"
fi

# =====================================================================
# Step 7.6: Restore precious state from PBS
# =====================================================================
step_start 7.6 "Restore precious state from PBS"
log "    Restore decisions were handled preboot between the stopped apply and start apply."
log "    No post-boot restore is run in Sprint 031."
step_done 7.6 "PBS restore handled preboot"

# =====================================================================
# Steps 8-15.7 (excluding 14.5): Shared convergence flow
# =====================================================================
converge_run_all

# =====================================================================
# Step 14.5: Push repository to GitLab
# =====================================================================
if step_in_scope push; then
step_start 14.5 "Push repository to GitLab"
if should_skip_gitlab_handoff; then
  step_skip 14.5 "Override branch check active for prod/shared impact - skipping GitLab push intentionally"
else
  GITLAB_IP=$(yq -r '.vms.gitlab.ip' "$CONFIG")
  PROJECT_NAME=$(yq -r '.cicd.project_name' "$CONFIG")

  # Ensure gitlab remote exists and points to the right place (SSH transport)
  if git -C "$REPO_DIR" remote get-url gitlab &>/dev/null; then
    git -C "$REPO_DIR" remote set-url gitlab "gitlab@${GITLAB_IP}:root/${PROJECT_NAME}.git"
  else
    git -C "$REPO_DIR" remote add gitlab "gitlab@${GITLAB_IP}:root/${PROJECT_NAME}.git"
  fi

  # Clear stale host key for GitLab
  ssh-keygen -R "$GITLAB_IP" 2>/dev/null || true
  ssh-keyscan -H "$GITLAB_IP" >> ~/.ssh/known_hosts 2>/dev/null

  # Push the current branch (handle detached HEAD for initial deploy)
  CURRENT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
  if [[ -z "$CURRENT_BRANCH" ]]; then
    # Detached HEAD — push to dev as the initial branch
    # --no-verify bypasses the pre-push hook (blocks direct pushes to
    # dev/prod/main). This push is intentional — part of the rebuild.
    git -C "$REPO_DIR" push --no-verify gitlab HEAD:dev --force
    CURRENT_BRANCH="dev"
    log "    Detached HEAD — pushed to GitLab as 'dev'"
  else
    git -C "$REPO_DIR" push --no-verify gitlab "$CURRENT_BRANCH" --force
    log "    Pushed branch '${CURRENT_BRANCH}' to GitLab"
  fi

  # Trigger a fresh pipeline via API. The push above may say "up-to-date"
  # if configure-gitlab.sh already pushed the same commit. We need a pipeline
  # that runs AFTER the runner is registered and all config is done.
  PUSH_PW=$(sops -d --extract '["gitlab_root_password"]' "${REPO_DIR}/site/sops/secrets.yaml" 2>/dev/null || true)
  if [[ -n "$PUSH_PW" && "$PUSH_PW" != "null" ]]; then
    PUSH_TOKEN=$(curl -sk -X POST "https://${GITLAB_IP}/oauth/token" \
      -d "grant_type=password&username=root&password=${PUSH_PW}" 2>/dev/null | jq -r '.access_token // empty')
    if [[ -n "$PUSH_TOKEN" ]]; then
      TRIGGER_RESULT=$(curl -sk -X POST "https://${GITLAB_IP}/api/v4/projects/1/pipeline" \
        -H "Authorization: Bearer ${PUSH_TOKEN}" \
        -d "ref=${CURRENT_BRANCH}" 2>/dev/null | jq -r '.id // empty')
      if [[ -n "$TRIGGER_RESULT" ]]; then
        log "    Triggered pipeline #${TRIGGER_RESULT} on ${CURRENT_BRANCH}"
      else
        log "    WARNING: Could not trigger pipeline via API"
      fi
    else
      log "    WARNING: Could not authenticate to GitLab API for pipeline trigger"
    fi
  fi
  step_done 14.5 "Repository pushed to GitLab"
fi
else
  step_skip 14.5 "Push to GitLab (not in scope)"
fi

# =====================================================================
# Step 16: Final validation
# =====================================================================
step_start 16 "Final validation"

# validate.sh handles replication and Gatus settle waits internally
# (retries for up to 2 minutes on each replication check).

# Run validate.sh with retries — Gatus needs ~60-90s for a full health
# cycle after services come up. If the first attempt fails, wait and retry.
VALIDATE_PASS=0
for VALIDATE_ATTEMPT in 1 2 3; do
  if "${SCRIPT_DIR}/validate.sh"; then
    VALIDATE_PASS=1
    break
  fi
  if [[ $VALIDATE_ATTEMPT -lt 3 ]]; then
    log "    Validation attempt ${VALIDATE_ATTEMPT} failed — waiting 60s for Gatus cycle..."
    sleep 60
  fi
done
if [[ $VALIDATE_PASS -eq 0 ]]; then
  log "    FATAL: Validation failed after 3 attempts"
  exit 1
fi
step_done 16 "Validation passed"

if should_skip_gitlab_handoff && ! step_in_scope pipeline; then
  log_function_output print_post_dr_reconciliation_instructions
fi

# =====================================================================
# Step 17: Wait for pipeline
# =====================================================================
if step_in_scope pipeline; then
step_start 17 "Wait for pipeline"
if should_skip_gitlab_handoff; then
  step_skip 17 "Override branch check active for prod/shared impact - skipping pipeline wait intentionally"
  log_function_output print_post_dr_reconciliation_instructions
else
  GITLAB_IP=$(yq -r '.vms.gitlab.ip' "$CONFIG")
  GITLAB_PW=$(sops -d --extract '["gitlab_root_password"]' "${REPO_DIR}/site/sops/secrets.yaml" 2>/dev/null || true)
  if [[ -n "$GITLAB_PW" && "$GITLAB_PW" != "null" ]]; then
    PIPELINE_TOKEN=$(curl -sk -X POST "https://${GITLAB_IP}/oauth/token" \
      -d "grant_type=password&username=root&password=${GITLAB_PW}" 2>/dev/null | jq -r '.access_token // empty')
    if [[ -n "$PIPELINE_TOKEN" ]]; then
      # Find the most recent pipeline on the current branch (dev)
      CURRENT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
      PIPELINE_ID=$(curl -sk "https://${GITLAB_IP}/api/v4/projects/1/pipelines?ref=${CURRENT_BRANCH}&per_page=1" \
        -H "Authorization: Bearer ${PIPELINE_TOKEN}" 2>/dev/null | jq -r '.[0].id // empty')
      if [[ -n "$PIPELINE_ID" ]]; then
        log "    Waiting for pipeline #${PIPELINE_ID}..."
        PIPELINE_WAIT=0
        LAST_JOBS_HASH=""
        STALE_COUNT=0
        while true; do
          PIPELINE_JSON=$(curl -sk "https://${GITLAB_IP}/api/v4/projects/1/pipelines/${PIPELINE_ID}" \
            -H "Authorization: Bearer ${PIPELINE_TOKEN}" 2>/dev/null)
          PIPELINE_STATUS=$(echo "$PIPELINE_JSON" | jq -r '.status')

          case "$PIPELINE_STATUS" in
            success)
              log "    Pipeline #${PIPELINE_ID}: success"
              break ;;
            failed)
              log "    Pipeline #${PIPELINE_ID}: FAILED"
              curl -sk "https://${GITLAB_IP}/api/v4/projects/1/pipelines/${PIPELINE_ID}/jobs" \
                -H "Authorization: Bearer ${PIPELINE_TOKEN}" 2>/dev/null | \
                jq -r '.[] | select(.status == "failed") | "      FAILED: \(.name) (\(.stage))"' 2>/dev/null
              die "Pipeline failed. Check GitLab UI for details." ;;
            canceled|skipped)
              log "    Pipeline #${PIPELINE_ID}: ${PIPELINE_STATUS}"
              log "    WARNING: Pipeline did not complete normally"
              break ;;
          esac

          # Detect truly stuck pipelines — distinguish from runner-busy queue.
          # A pipeline is stuck only if it's in a non-terminal state AND no job
          # is running or pending (everything is "created" = no runner picked it up).
          JOBS_JSON=$(curl -sk "https://${GITLAB_IP}/api/v4/projects/1/pipelines/${PIPELINE_ID}/jobs" \
            -H "Authorization: Bearer ${PIPELINE_TOKEN}" 2>/dev/null)
          JOBS_HASH=$(echo "$JOBS_JSON" | jq -r '[.[] | "\(.name):\(.status)"] | sort | join(",")' 2>/dev/null)
          ACTIVE_JOBS=$(echo "$JOBS_JSON" | jq -r '[.[] | select(.status == "running" or .status == "pending")] | length' 2>/dev/null)

          if [[ "$JOBS_HASH" == "$LAST_JOBS_HASH" ]]; then
            STALE_COUNT=$((STALE_COUNT + 1))
          else
            STALE_COUNT=0
            LAST_JOBS_HASH="$JOBS_HASH"
          fi

          # Stuck = no progress for 3 minutes AND no jobs running or pending
          if [[ $STALE_COUNT -ge 12 && "${ACTIVE_JOBS:-0}" -eq 0 ]]; then
            log "    Pipeline #${PIPELINE_ID} appears stuck (no progress, no active jobs)"
            log "    Status: ${PIPELINE_STATUS}"
            log "    Jobs: ${JOBS_HASH}"
            die "Pipeline hung. Check runner status and GitLab UI."
          fi

          # Hard timeout: 20 minutes (image builds can take 5-10 minutes)
          PIPELINE_WAIT=$((PIPELINE_WAIT + 1))
          if [[ $PIPELINE_WAIT -ge 80 ]]; then
            log "    Pipeline #${PIPELINE_ID} still running after 20 minutes (status: ${PIPELINE_STATUS})"
            die "Pipeline timed out. Check GitLab UI."
          fi

          if (( PIPELINE_WAIT % 4 == 0 && PIPELINE_WAIT > 0 )); then
            # Show which jobs are running/pending
            RUNNING_JOBS=$(echo "$JOBS_JSON" | jq -r '[.[] | select(.status == "running") | .name] | join(", ")' 2>/dev/null)
            PENDING_JOBS=$(echo "$JOBS_JSON" | jq -r '[.[] | select(.status == "pending") | .name] | join(", ")' 2>/dev/null)
            PROGRESS_MSG="($((PIPELINE_WAIT * 15))s / $((80 * 15))s)"
            [[ -n "$RUNNING_JOBS" ]] && PROGRESS_MSG+=" running: ${RUNNING_JOBS}"
            [[ -n "$PENDING_JOBS" ]] && PROGRESS_MSG+=" pending: ${PENDING_JOBS}"
            log "    Waiting for pipeline #${PIPELINE_ID}... ${PROGRESS_MSG}"
          fi
          sleep 15
        done
      else
        log "    No pipelines found — skipping"
      fi
    else
      log "    WARNING: Could not authenticate to GitLab API — skipping pipeline check"
    fi
  else
    log "    WARNING: No GitLab password in SOPS — skipping pipeline check"
  fi
  step_done 17 "Pipeline verified"
fi
else
  step_skip 17 "Pipeline wait (not in scope)"
fi

# =====================================================================
# Step 18: Immediate backup of precious-state VMs
# =====================================================================
# Create a known-good backup immediately so the next rebuild (or reset)
# has something to restore from. The backup runs AFTER validation and
# pipeline pass — so the backed-up state is verified good.
step_start 18 "Immediate backup of precious-state VMs"

# --- Data protection check ---
# If PBS has existing backups for a VMID but the VM appears fresh/empty,
# do NOT take a new backup — it would overwrite good data with empty state.
# This catches failed vdb restores (stale certs, token mismatch, NFS issue).
log "    Data protection check: verifying VMs have expected state..."
DATA_PROTECT_FAIL=0
PBS_IP_CHECK=$(yq -r '.vms.pbs.ip // ""' "$CONFIG")
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
if [[ -n "$PBS_IP_CHECK" && "$PBS_IP_CHECK" != "null" ]]; then
  # Check if PBS has any backups at all
  PBS_HAS_BACKUPS=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${FIRST_NODE_IP}" \
    "pvesh get /nodes/\$(hostname)/storage/pbs-nas/content --output-format json 2>/dev/null" 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if len(d)>0 else 'no')" 2>/dev/null || echo "unknown")

  if [[ "$PBS_HAS_BACKUPS" == "yes" ]]; then
    # Check GitLab: does the project exist?
    # This catches failed vdb restores where GitLab is empty but PBS
    # has backups from a previous deployment. Skip if GitLab is not
    # reachable (it may still be starting up).
    GITLAB_IP=$(yq -r '.vms.gitlab.ip' "$CONFIG")
    GITLAB_PW=$(sops -d --extract '["gitlab_root_password"]' "${REPO_DIR}/site/sops/secrets.yaml" 2>/dev/null || true)
    if [[ -n "$GITLAB_PW" && "$GITLAB_PW" != "null" ]]; then
      GL_TOKEN=$(curl -sk --max-time 10 -X POST "https://${GITLAB_IP}/oauth/token" \
        -d "grant_type=password&username=root&password=${GITLAB_PW}" 2>/dev/null \
        | jq -r '.access_token // empty' || true)
      if [[ -n "$GL_TOKEN" ]]; then
        GL_PROJECTS=$(curl -sk --max-time 10 -H "Authorization: Bearer ${GL_TOKEN}" \
          "https://${GITLAB_IP}/api/v4/projects" 2>/dev/null \
          | jq -r 'length // 0' || echo "unknown")
        if [[ "$GL_PROJECTS" == "0" ]]; then
          log "    ERROR: GitLab has no projects but PBS has existing backups."
          log "    The vdb restore likely failed. Taking a new backup would"
          log "    overwrite the good backup with empty state."
          DATA_PROTECT_FAIL=1
        else
          log "    GitLab has projects (${GL_PROJECTS}) — data protection OK"
        fi
      else
        log "    Could not authenticate to GitLab — skipping data protection check"
      fi
    fi
  else
    log "    PBS has no existing backups — fresh cluster, proceeding"
  fi
fi
if [[ $DATA_PROTECT_FAIL -gt 0 ]]; then
  die "Data protection check failed. Fix the restore issue and re-run, or delete existing PBS backups to start fresh."
fi

SITE_ACME_MODE="$(certbot_cluster_expected_mode "$CONFIG")"
if [[ "${SITE_ACME_MODE}" == "production" ]]; then
  EXPECTED_ACME_URL="$(certbot_cluster_expected_url "$CONFIG")"
  LINEAGE_FAILURES=0
  LINEAGE_CHECKED=0
  BACKUP_CERTBOT_RECORDS=""
  BACKUP_CERTBOT_RECORDS_STATUS=0

  log "    Certbot lineage check: verifying backup-backed prod/shared certbot VMs..."
  set +e
  BACKUP_CERTBOT_RECORDS="$(certbot_cluster_prod_shared_backup_certbot_records "$CONFIG" "$APPS_CONFIG" 2>&1)"
  BACKUP_CERTBOT_RECORDS_STATUS=$?
  set -e

  if [[ "${BACKUP_CERTBOT_RECORDS_STATUS}" -ne 0 ]]; then
    while IFS= read -r inventory_line; do
      [[ -z "${inventory_line}" ]] && continue
      log "      ${inventory_line}"
    done <<< "${BACKUP_CERTBOT_RECORDS}"
    die "Step 18 could not inspect every backup-backed prod/shared certbot VM before backup."
  fi

  while IFS=$'\t' read -r vm_label _ vm_ip _ fqdn _ _; do
    [[ -z "${vm_label}" ]] && continue
    LINEAGE_CHECKED=$((LINEAGE_CHECKED + 1))

    set +e
    HELPER_OUTPUT="$(certbot_cluster_run_remote_helper \
      "${vm_ip}" \
      --mode check \
      --expected-acme-url "${EXPECTED_ACME_URL}" \
      --expected-mode production \
      --fqdn "${fqdn}" \
      --label "${vm_label}" 2>&1)"
    HELPER_EXIT=$?
    set -e

    if [[ -n "${HELPER_OUTPUT}" ]]; then
      while IFS= read -r helper_line; do
        [[ -z "${helper_line}" ]] && continue
        log "      ${helper_line}"
      done <<< "${HELPER_OUTPUT}"
    fi

    if [[ "${HELPER_EXIT}" -eq 0 ]]; then
      log "    ${vm_label} (${fqdn}): lineage OK"
    else
      log "    ${vm_label} (${fqdn}): lineage FAILED"
      LINEAGE_FAILURES=$((LINEAGE_FAILURES + 1))
    fi
  done <<< "${BACKUP_CERTBOT_RECORDS}"

  if [[ "${LINEAGE_CHECKED}" -eq 0 ]]; then
    log "    No backup-backed prod/shared certbot VMs detected"
  fi

  if [[ "${LINEAGE_FAILURES}" -gt 0 ]]; then
    die "Step 18 refused to back up ${LINEAGE_FAILURES} backup-backed prod/shared certbot VM(s) with bad persisted lineage."
  fi
fi

# Get precious-state VMIDs (same source as configure-backups.sh / restore-from-pbs.sh)
PRECIOUS_INFRA=$(yq -r '.vms | to_entries[] | select(.value.backup == true) | .value.vmid' "$CONFIG" 2>/dev/null)
PRECIOUS_APPS=""
for BACKUP_APP in $(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null); do
  for BACKUP_ENV in $(yq -r ".applications.${BACKUP_APP}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null); do
    PRECIOUS_APPS+=" $(yq -r ".applications.${BACKUP_APP}.environments.${BACKUP_ENV}.vmid" "$APPS_CONFIG")"
  done
done
ALL_PRECIOUS="${PRECIOUS_INFRA} ${PRECIOUS_APPS}"
BACKUP_FAILURES=0
for BKUP_VMID in $ALL_PRECIOUS; do
  [[ -z "$BKUP_VMID" || "$BKUP_VMID" == "null" ]] && continue
  # Find hosting node
  BKUP_NODE=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${FIRST_NODE_IP}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" 2>/dev/null | \
    python3 -c "import sys,json; [print(v['node']) for v in json.loads(sys.stdin.read()) if v.get('vmid')==${BKUP_VMID}]" 2>/dev/null | head -1)
  BKUP_NODE_IP=$(yq -r ".nodes[] | select(.name == \"${BKUP_NODE}\") | .mgmt_ip" "$CONFIG")
  if [[ -n "$BKUP_NODE_IP" ]]; then
    log "    Backing up VMID ${BKUP_VMID} on ${BKUP_NODE}..."
    VZDUMP_OUTPUT=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${BKUP_NODE_IP}" \
      "vzdump ${BKUP_VMID} --storage pbs-nas --mode snapshot --compress zstd 2>&1") || true
    if echo "$VZDUMP_OUTPUT" | grep -q "Backup job finished successfully\|TASK OK"; then
      log "    ✓ VMID ${BKUP_VMID} backed up"
    else
      log "    ✗ VMID ${BKUP_VMID} backup FAILED:"
      echo "$VZDUMP_OUTPUT" | while IFS= read -r line; do log "      $line"; done
      BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
    fi
  else
    log "    ✗ VMID ${BKUP_VMID}: could not find hosting node"
    BACKUP_FAILURES=$((BACKUP_FAILURES + 1))
  fi
done
if [[ $BACKUP_FAILURES -gt 0 ]]; then
  die "Step 18 failed: ${BACKUP_FAILURES} backup(s) failed. A cluster without working backups is not production-ready."
fi
step_done 18 "Immediate backups complete"

# =====================================================================
# Summary
# =====================================================================
TOTAL_ELAPSED=$(( $(date +%s) - REBUILD_START ))
MINUTES=$(( TOTAL_ELAPSED / 60 ))
SECONDS_REMAIN=$(( TOTAL_ELAPSED % 60 ))

echo ""
echo "========================================"
echo "  Rebuild complete (${MINUTES}m ${SECONDS_REMAIN}s)"
echo "========================================"
echo ""
for result in "${STEP_RESULTS[@]}"; do
  echo "  ${result}"
done
echo ""
if [[ ${VALIDATE_EXIT:-0} -ne 0 ]]; then
  log "rebuild-cluster.sh finished with validation failures (exit ${VALIDATE_EXIT})"
  exit 1
else
  log "rebuild-cluster.sh finished successfully"
fi
