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
#   framework/scripts/rebuild-cluster.sh --allow-dirty             # proceed with dirty git tree
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
TOFU_DIR="${REPO_DIR}/framework/tofu/root"
LOG_DIR="${REPO_DIR}/build"
LOG_FILE="${LOG_DIR}/rebuild.log"
BUILD_MARKER="${LOG_DIR}/.build-complete"

ALLOW_DIRTY=0
STAGING_CERTS=0
SCOPE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --scope) SCOPE="$2"; shift 2 ;;
    --staging-certs) echo "NOTE: --staging-certs is deprecated. Set 'acme: staging' in site/config.yaml instead."; shift ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# --- Scope definitions ---
TOFU_TARGETS=""
CONTROL_PLANE_MODULES="module.gitlab module.cicd module.pbs"
if [[ -n "$SCOPE" ]]; then
  case "$SCOPE" in
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
      echo "Valid: control-plane, data-plane, vm=name1,name2" >&2
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

STEP_RESULTS=()
REBUILD_START=$(date +%s)

log "rebuild-cluster.sh started"
log "Config: ${CONFIG}"
if [[ -n "$SCOPE" ]]; then
  log "Scope: ${SCOPE}"
  log "Targets: ${TOFU_TARGETS}"
fi
log ""

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

step_done 0 "Prerequisites verified"

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
log "    Generating Gatus config..."
mkdir -p "${REPO_DIR}/site/gatus"
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
# Compute data-plane targets if deferred
if [[ "$TOFU_TARGETS" == "DATA_PLANE_DEFERRED" ]]; then
  TOFU_TARGETS=""
  # Get all tofu modules from state, exclude control-plane
  ALL_MODULES=$(tofu state list 2>/dev/null | grep -o '^module\.[^.]*' | sort -u || true)
  for mod in $ALL_MODULES; do
    IS_CP=false
    for cp in $CONTROL_PLANE_MODULES; do
      [[ "$mod" == "$cp" ]] && IS_CP=true
    done
    if [[ "$IS_CP" == "false" ]]; then
      TOFU_TARGETS="$TOFU_TARGETS -target=$mod"
    fi
  done
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
if [[ -n "$PBS_VMID_CHECK" && "$PBS_VMID_CHECK" != "null" ]]; then
  PBS_HA_IN_STATE=$("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null | grep -c 'module\.pbs.*haresource' || echo "0")
  if [[ "$PBS_HA_IN_STATE" -eq 0 ]]; then
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

# HA double-apply: when VMs are recreated with new VMIDs, Proxmox removes the
# HA resource. The first apply may fail on HA resource updates. A second apply
# creates the fresh HA resources. This is a known provider limitation.
APPLY_ARGS="-auto-approve -input=false"
if [[ -n "$TOFU_TARGETS" ]]; then
  log "    Scoped apply targets: $TOFU_TARGETS"
  APPLY_ARGS="$TOFU_TARGETS $APPLY_ARGS"
fi
if ! "${SCRIPT_DIR}/tofu-wrapper.sh" apply $APPLY_ARGS; then
  log "    First apply had errors (likely HA resources) — running second apply..."
  "${SCRIPT_DIR}/tofu-wrapper.sh" apply $APPLY_ARGS
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
  PBS_IP=$(yq -r '.vms.pbs.ip // ""' "$CONFIG")

  if [[ -z "$PBS_IP" || "$PBS_IP" == "null" ]]; then
    step_skip 7.5 "No PBS configured in config.yaml"
  else
    # install-pbs.sh is idempotent: skips if PBS is already installed (HTTPS responding)
    "${SCRIPT_DIR}/install-pbs.sh"

    # configure-pbs.sh is idempotent: sets up SSH keys, NFS mount, datastore,
    # API token, Proxmox storage entry, and backup jobs.
    # Exit code 10 = stale NFS mount, need to recreate the PBS VM.
    set +e
    "${SCRIPT_DIR}/configure-pbs.sh"
    PBS_EXIT=$?
    set -e
    if [[ $PBS_EXIT -eq 10 ]]; then
      log "    Stale NFS mount — recreating PBS VM..."
      PBS_VMID=$(yq -r '.vms.pbs.vmid' "$CONFIG")
      # Find hosting node
      PBS_HOST=""
      for node_ip in $(yq -r '.nodes[].mgmt_ip' "$CONFIG"); do
        if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "root@${node_ip}" "qm status ${PBS_VMID}" >/dev/null 2>&1; then
          PBS_HOST="$node_ip"
          break
        fi
      done
      if [[ -n "$PBS_HOST" ]]; then
        # Destroy via Proxmox API (bypasses tofu's prevent_destroy)
        log "    Destroying PBS VM ${PBS_VMID} on ${PBS_HOST}..."
        ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "root@${PBS_HOST}" "ha-manager remove vm:${PBS_VMID} 2>/dev/null; qm stop ${PBS_VMID} --skiplock 2>/dev/null; sleep 5; qm destroy ${PBS_VMID} --purge --skiplock 2>/dev/null" || true
      fi
      # Remove ALL PBS resources from tofu state so apply creates them fresh.
      # Surgical removal misses dependent resources (HA, snippets) that
      # trigger prevent_destroy via the dependency chain.
      cd "$TOFU_DIR"
      for res in $("${SCRIPT_DIR}/tofu-wrapper.sh" state list 2>/dev/null | grep '^module\.pbs\.' || true); do
        "${SCRIPT_DIR}/tofu-wrapper.sh" state rm "$res" 2>/dev/null || true
      done
      # Clean stale zvols
      if [[ -n "$PBS_HOST" ]]; then
        ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "root@${PBS_HOST}" "zfs destroy -r vmstore/data/vm-${PBS_VMID}-disk-0 2>/dev/null; zfs destroy -r vmstore/data/vm-${PBS_VMID}-disk-1 2>/dev/null; zfs destroy -r vmstore/data/vm-${PBS_VMID}-cloudinit 2>/dev/null" || true
      fi
      "${SCRIPT_DIR}/tofu-wrapper.sh" apply -target=module.pbs -auto-approve -input=false
      cd "$REPO_DIR"
      log "    PBS VM recreated. Re-running install and configure..."
      "${SCRIPT_DIR}/install-pbs.sh"
      # Wait for PBS SSH to be ready (HTTPS may be up before SSH)
      PBS_IP_WAIT=$(yq -r '.vms.pbs.ip' "$CONFIG")
      for i in $(seq 1 30); do
        if sshpass -p "$(sops -d --extract '["pbs_root_password"]' "${REPO_DIR}/site/sops/secrets.yaml" 2>/dev/null)" \
            ssh -n -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "root@${PBS_IP_WAIT}" "true" 2>/dev/null; then
          break
        fi
        sleep 5
      done
      "${SCRIPT_DIR}/configure-pbs.sh"
    elif [[ $PBS_EXIT -ne 0 ]]; then
      die "configure-pbs.sh failed (exit $PBS_EXIT)"
    fi

    step_done 7.5 "PBS installed and configured"
  fi
else
  step_skip 7.5 "PBS install (not in scope)"
fi

# =====================================================================
# Step 7.6: Restore precious state from PBS
# =====================================================================
step_start 7.6 "Restore precious state from PBS"
if [[ -n "$SCOPE" ]]; then
  # Scoped restore: only restore VMs that are in the target list
  RESTORED_ANY=false
  # Collect VMIDs for scoped VMs that have backup: true
  for vm_key in $(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG"); do
    VMID=$(yq -r ".vms.${vm_key}.vmid" "$CONFIG")
    if [[ "$TOFU_TARGETS" == *"module.${vm_key}"* || "$TOFU_TARGETS" == *"module.$(echo "$vm_key" | sed 's/_[^_]*$//')"* ]]; then
      log "    Restoring vdb for ${vm_key} (VMID ${VMID})..."
      "${SCRIPT_DIR}/restore-from-pbs.sh" --target "$VMID" || log "    WARNING: restore failed for ${vm_key}"
      RESTORED_ANY=true
    fi
  done
  # Application VMs
  for app_key in $(yq -r '.applications | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$CONFIG" 2>/dev/null); do
    for env in prod dev; do
      VMID=$(yq -r ".applications.${app_key}.environments.${env}.vmid // \"\"" "$CONFIG")
      [[ -z "$VMID" ]] && continue
      MOD_NAME="${app_key}_${env}"
      if [[ "$TOFU_TARGETS" == *"module.${MOD_NAME}"* ]]; then
        log "    Restoring vdb for ${MOD_NAME} (VMID ${VMID})..."
        "${SCRIPT_DIR}/restore-from-pbs.sh" --target "$VMID" || log "    WARNING: restore failed for ${MOD_NAME}"
        RESTORED_ANY=true
      fi
    done
  done
  if [[ "$RESTORED_ANY" == "false" ]]; then
    log "    No scoped VMs need PBS restore"
  fi
else
  "${SCRIPT_DIR}/restore-from-pbs.sh"
fi
step_done 7.6 "PBS restore complete"

# =====================================================================
# Step 8: DNS zones
# =====================================================================
if step_in_scope dns; then
  step_start 8 "DNS zones (loaded at boot via CIDATA)"
  # Zone data is generated by OpenTofu and delivered via write_files.
  # The pdns-zone-load systemd service loads it into PowerDNS at boot.
  # No separate zone-deploy.sh step is needed.
  sleep 30  # Wait for DNS VMs to finish zone loading
  step_done 8 "DNS zones loaded at boot"
else
  step_skip 8 "DNS zones (not in scope)"
fi

# =====================================================================
# Step 9: Wait for certificates
# =====================================================================
step_start 9 "Wait for certificates"

# Helper: SSH to a VM
cert_ssh() {
  ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$1" "$2" 2>/dev/null
}

# Pre-flight: clean up empty cert files on all VMs that use ACME.
# Certbot can leave empty PEM files after an ACME server outage. The
# ExecCondition then skips re-acquisition because the directory exists.
# Deleting the empty live/ directory forces certbot to re-run.
log "    Checking for stale/empty cert files..."
for ENV in prod dev; do
  for VM_KEY in $(yq -r ".vms | to_entries[] | select(.key | test(\"_${ENV}$\")) | .key" "$CONFIG" 2>/dev/null); do
    VM_IP=$(yq -r ".vms.${VM_KEY}.ip" "$CONFIG")
    EMPTY_CERT=$(cert_ssh "$VM_IP" '
      for d in /etc/letsencrypt/live/*/; do
        cert="${d}fullchain.pem"
        [ -e "$cert" ] && [ ! -s "$cert" ] && echo "$d"
      done; true
    ' || true)
    if [[ -n "$EMPTY_CERT" ]]; then
      log "    ${VM_KEY}: found empty cert files — cleaning up and restarting certbot"
      cert_ssh "$VM_IP" 'rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal; systemctl restart certbot-initial 2>/dev/null || true'
    fi
  done
  # Also check shared VMs (gitlab, gatus)
  for VM_KEY in gitlab gatus; do
    VM_IP=$(yq -r ".vms.${VM_KEY}.ip // \"\"" "$CONFIG")
    [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue
    EMPTY_CERT=$(cert_ssh "$VM_IP" '
      for d in /etc/letsencrypt/live/*/; do
        cert="${d}fullchain.pem"
        [ -e "$cert" ] && [ ! -s "$cert" ] && echo "$d"
      done; true
    ' || true)
    if [[ -n "$EMPTY_CERT" ]]; then
      log "    ${VM_KEY}: found empty cert files — cleaning up and restarting certbot"
      cert_ssh "$VM_IP" 'rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal; systemctl restart certbot-initial 2>/dev/null || true'
    fi
  done
  # Application VMs
  for APP_KEY in $(yq -r '.applications | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG" 2>/dev/null); do
    VM_IP=$(yq -r ".applications.${APP_KEY}.environments.${ENV}.ip // \"\"" "$CONFIG")
    [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue
    EMPTY_CERT=$(cert_ssh "$VM_IP" '
      for d in /etc/letsencrypt/live/*/; do
        cert="${d}fullchain.pem"
        [ -e "$cert" ] && [ ! -s "$cert" ] && echo "$d"
      done; true
    ' || true)
    if [[ -n "$EMPTY_CERT" ]]; then
      log "    ${APP_KEY}_${ENV}: found empty cert files — cleaning up and restarting certbot"
      cert_ssh "$VM_IP" 'rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal; systemctl restart certbot-initial 2>/dev/null || true'
    fi
  done
done

# Pre-flight 2: detect wrong-domain certs from PBS restore.
# After a domain change, PBS restores certs for the old domain. Certbot's
# ExecCondition sees the existing live/ directory and skips re-acquisition.
# Compare cert directory names against the expected FQDN and clean mismatches.
DOMAIN=$(yq -r '.domain' "$CONFIG")
log "    Checking for wrong-domain certs (expected domain: ${DOMAIN})..."

check_cert_domain() {
  local vm_ip="$1" expected_fqdn="$2" vm_label="$3"
  local cert_dirs
  cert_dirs=$(cert_ssh "$vm_ip" \
    'for d in /etc/letsencrypt/live/*/; do basename "$d"; done 2>/dev/null' || true)
  for dir in $cert_dirs; do
    [[ "$dir" == "README" || "$dir" == "*" ]] && continue
    if [[ "$dir" != "$expected_fqdn" ]]; then
      log "    ${vm_label}: stale cert for '${dir}' (expected: ${expected_fqdn})"
      log "    Cleaning stale certs — certbot will re-acquire for the correct domain."
      cert_ssh "$vm_ip" 'rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal; systemctl restart certbot-initial 2>/dev/null || true'
      return 0
    fi
  done
}

for ENV in prod dev; do
  # Per-environment VMs: vault_prod → vault.prod.<domain>
  for VM_KEY in $(yq -r ".vms | to_entries[] | select(.key | test(\"_${ENV}$\")) | .key" "$CONFIG" 2>/dev/null); do
    VM_IP=$(yq -r ".vms.${VM_KEY}.ip" "$CONFIG")
    # Extract hostname: vault_prod → vault, dns1_dev → dns1
    HOSTNAME=$(echo "$VM_KEY" | sed "s/_${ENV}$//")
    EXPECTED_FQDN="${HOSTNAME}.${ENV}.${DOMAIN}"
    check_cert_domain "$VM_IP" "$EXPECTED_FQDN" "$VM_KEY"
  done
  # Shared VMs (gitlab, gatus) — use prod domain
  for VM_KEY in gitlab gatus; do
    VM_IP=$(yq -r ".vms.${VM_KEY}.ip // \"\"" "$CONFIG")
    [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue
    EXPECTED_FQDN="${VM_KEY}.prod.${DOMAIN}"
    check_cert_domain "$VM_IP" "$EXPECTED_FQDN" "$VM_KEY"
  done
  # Application VMs
  for APP_KEY in $(yq -r '.applications | to_entries[] | select(.value.enabled == true) | .key' "$CONFIG" 2>/dev/null); do
    VM_IP=$(yq -r ".applications.${APP_KEY}.environments.${ENV}.ip // \"\"" "$CONFIG")
    [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue
    EXPECTED_FQDN="${APP_KEY}.${ENV}.${DOMAIN}"
    check_cert_domain "$VM_IP" "$EXPECTED_FQDN" "${APP_KEY}_${ENV}"
  done
done

CERT_TIMEOUT=600
CERT_INTERVAL=15
CERT_RECOVER_ATTEMPTED=0
for ENV in prod dev; do
  VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")
  elapsed=0
  while true; do
    if echo | openssl s_client -connect "${VAULT_IP}:8200" 2>/dev/null | openssl x509 -noout 2>/dev/null; then
      log "    vault-${ENV} has a TLS certificate"
      break
    fi

    # At 2 minutes, diagnose and attempt recovery
    if (( elapsed == 120 && CERT_RECOVER_ATTEMPTED == 0 )); then
      CERT_RECOVER_ATTEMPTED=1
      log "    vault-${ENV} cert not ready after 2m — diagnosing..."

      # Check ACME server
      ACME_URL=$(cert_ssh "$VAULT_IP" "cat /run/secrets/certbot/acme-server-url 2>/dev/null" || true)
      if [[ -n "$ACME_URL" ]]; then
        ACME_HTTP=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$ACME_URL" 2>/dev/null || echo "000")
        if [[ "$ACME_HTTP" != "200" ]]; then
          log "    ACME server (${ACME_URL}) returned HTTP ${ACME_HTTP}"
          log "    The ACME server may be down. Cert acquisition will retry automatically."
          log "    Extending timeout to wait for recovery..."
        fi
      fi

      # Check if certbot is stuck (inactive/skipped)
      CB_ACTIVE=$(cert_ssh "$VAULT_IP" "systemctl is-active certbot-initial 2>/dev/null" || true)
      if [[ "$CB_ACTIVE" == "inactive" ]]; then
        log "    certbot-initial is inactive — restarting..."
        cert_ssh "$VAULT_IP" "rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal; systemctl restart certbot-initial" || true
      fi

      # Check for empty certs (may have appeared since pre-flight)
      EMPTY=$(cert_ssh "$VAULT_IP" 'for d in /etc/letsencrypt/live/*/; do c="${d}fullchain.pem"; [ -e "$c" ] && [ ! -s "$c" ] && echo empty; done; true' || true)
      if [[ -n "$EMPTY" ]]; then
        log "    Empty cert files detected — cleaning up and restarting certbot..."
        cert_ssh "$VAULT_IP" "rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal; systemctl restart certbot-initial" || true
      fi
    fi

    if (( elapsed >= CERT_TIMEOUT )); then
      log "    FATAL: Timed out waiting for vault-${ENV} TLS certificate (${CERT_TIMEOUT}s)"
      log "    --- Diagnostics for vault-${ENV} (${VAULT_IP}) ---"
      DIAG=$(cert_ssh "$VAULT_IP" "
        echo 'certbot-initial:'; systemctl is-active certbot-initial 2>/dev/null || true
        echo '---'
        journalctl -u certbot-initial --no-pager -n 5 2>/dev/null || true
        echo '---'
        echo 'vault:'; systemctl is-active vault 2>/dev/null || true
        journalctl -u vault --no-pager -n 3 2>/dev/null || true
        echo '---'
        echo 'cert files:'
        ls -la /etc/letsencrypt/live/*/fullchain.pem 2>/dev/null || echo 'none'
        wc -c /etc/letsencrypt/archive/*/fullchain*.pem 2>/dev/null || echo 'no archive'
      " || echo "  VM unreachable")
      echo "$DIAG" | while IFS= read -r line; do log "      $line"; done
      ACME_URL=$(cert_ssh "$VAULT_IP" "cat /run/secrets/certbot/acme-server-url 2>/dev/null" || true)
      if [[ -n "$ACME_URL" ]]; then
        ACME_STATUS=$(curl -sk --max-time 5 "$ACME_URL" 2>/dev/null | head -3)
        log "    ACME server (${ACME_URL}):"
        echo "$ACME_STATUS" | while IFS= read -r line; do log "      $line"; done
      fi
      die "Certificate acquisition failed — see diagnostics above"
    fi
    if (( elapsed > 0 && elapsed % 60 == 0 )); then
      log "    Still waiting for vault-${ENV} certificate... (${elapsed}s / ${CERT_TIMEOUT}s)"
    fi
    sleep "$CERT_INTERVAL"
    elapsed=$(( elapsed + CERT_INTERVAL ))
  done
done
step_done 9 "Certificates ready"

# =====================================================================
# Step 10: Initialize Vault
# =====================================================================
if step_in_scope vault; then
  step_start 10 "Initialize Vault"
  for ENV in prod dev; do
    "${SCRIPT_DIR}/init-vault.sh" "$ENV"
  done
  step_done 10 "Vault initialized"

  # =====================================================================
  # Step 11: Configure Vault
  # =====================================================================
  step_start 11 "Configure Vault"
  for ENV in prod dev; do
    "${SCRIPT_DIR}/configure-vault.sh" "$ENV"
  done
  step_done 11 "Vault configured"
else
  step_skip 10 "Vault init (not in scope)"
  step_skip 11 "Vault config (not in scope)"
fi

# =====================================================================
# Step 12: Configure ZFS replication
# =====================================================================
step_start 12 "Configure ZFS replication"
"${SCRIPT_DIR}/configure-replication.sh" "*"
step_done 12 "ZFS replication configured"

# =====================================================================
# Step 13: Configure GitLab
# =====================================================================
if step_in_scope gitlab; then
  step_start 13 "Configure GitLab"
  "${SCRIPT_DIR}/configure-gitlab.sh"
  step_done 13 "GitLab configured"
else
  step_skip 13 "GitLab config (not in scope)"
fi

# =====================================================================
# Step 14: Register runner
# =====================================================================
if step_in_scope runner; then
step_start 14 "Register runner"
"${SCRIPT_DIR}/register-runner.sh"

# CI runner SSH key is now installed on nodes during step 1
# (configure-node-network.sh installs both operator and SOPS keys).
# The runner's ssh config sets StrictHostKeyChecking=accept-new, so
# known_hosts is populated automatically on first connection.
step_done 14 "Runner registered"
else
  step_skip 14 "Runner registration (not in scope)"
fi

# =====================================================================
# Step 14.5: Push repository to GitLab
# =====================================================================
if step_in_scope push; then
step_start 14.5 "Push repository to GitLab"
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

# Push the current branch
CURRENT_BRANCH=$(git -C "$REPO_DIR" branch --show-current)
git -C "$REPO_DIR" push gitlab "$CURRENT_BRANCH" --force
log "    Pushed branch '${CURRENT_BRANCH}' to GitLab"

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
  fi
fi
step_done 14.5 "Repository pushed to GitLab"
else
  step_skip 14.5 "Push to GitLab (not in scope)"
fi

# =====================================================================
# Step 15: Configure sentinel Gatus
# =====================================================================
if step_in_scope sentinel; then
step_start 15 "Configure sentinel Gatus"
# The NAS placement watchdog needs SSH access to Proxmox nodes.
# Install the NAS SSH public key on all nodes.
NAS_IP=$(yq -r '.nas.ip' "$CONFIG")
NAS_SSH_USER=$(yq -r '.nas.ssh_user' "$CONFIG")
NAS_PUBKEY=$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "${NAS_SSH_USER}@${NAS_IP}" "cat /root/.ssh/id_rsa.pub 2>/dev/null || cat /root/.ssh/id_ed25519.pub 2>/dev/null" 2>/dev/null)
if [[ -n "$NAS_PUBKEY" ]]; then
  NAS_KEY_ID=$(echo "$NAS_PUBKEY" | awk '{print $NF}')
  log "    Installing NAS SSH key (${NAS_KEY_ID}) on Proxmox nodes..."
  for (( ni=0; ni<$(yq '.nodes | length' "$CONFIG"); ni++ )); do
    NI_IP=$(yq -r ".nodes[$ni].mgmt_ip" "$CONFIG")
    ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${NI_IP}" \
      "grep -qF '${NAS_KEY_ID}' /root/.ssh/authorized_keys 2>/dev/null || echo '${NAS_PUBKEY}' >> /root/.ssh/authorized_keys" 2>/dev/null
  done
fi
# Clear stale host keys on NAS for all Proxmox nodes (nodes may have been reinstalled)
log "    Clearing stale host keys on NAS for Proxmox nodes..."
for (( ni=0; ni<$(yq '.nodes | length' "$CONFIG"); ni++ )); do
  NI_IP=$(yq -r ".nodes[$ni].mgmt_ip" "$CONFIG")
  ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${NAS_SSH_USER}@${NAS_IP}" \
    "ssh-keygen -R ${NI_IP} 2>/dev/null; ssh -n -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 root@${NI_IP} true 2>/dev/null" || true
done
"${SCRIPT_DIR}/configure-sentinel-gatus.sh"
step_done 15 "Sentinel Gatus configured"
else
  step_skip 15 "Sentinel Gatus (not in scope)"
fi

# =====================================================================
# Step 15.5: Configure backup jobs
# =====================================================================
if step_in_scope backups; then
step_start 15.5 "Configure backup jobs"
PBS_IP=$(yq -r '.vms.pbs.ip // ""' "$CONFIG")
if [[ -n "$PBS_IP" && "$PBS_IP" != "null" ]] && \
   ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
     "root@${PBS_IP}" "true" 2>/dev/null; then
  "${SCRIPT_DIR}/configure-backups.sh"
  step_done 15.5 "Backup jobs configured"
else
  step_skip 15.5 "PBS not reachable — backups not configured"
fi
else
  step_skip 15.5 "Backup jobs (not in scope)"
fi

# =====================================================================
# Step 15.7: Configure Proxmox metrics
# =====================================================================
if step_in_scope metrics; then
  step_start 15.7 "Configure metrics"
  "${SCRIPT_DIR}/configure-metrics.sh"
  step_done 15.7 "Metrics configured"
else
  step_skip 15.7 "Metrics (not in scope)"
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

# =====================================================================
# Step 17: Wait for pipeline
# =====================================================================
if step_in_scope pipeline; then
step_start 17 "Wait for pipeline"
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

# Get precious-state VMIDs (same source as configure-backups.sh / restore-from-pbs.sh)
PRECIOUS_INFRA=$(yq -r '.vms | to_entries[] | select(.value.backup == true) | .value.vmid' "$CONFIG" 2>/dev/null)
PRECIOUS_APPS=""
for BACKUP_APP in $(yq -r '.applications | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$CONFIG" 2>/dev/null); do
  for BACKUP_ENV in $(yq -r ".applications.${BACKUP_APP}.environments | keys | .[]" "$CONFIG" 2>/dev/null); do
    PRECIOUS_APPS+=" $(yq -r ".applications.${BACKUP_APP}.environments.${BACKUP_ENV}.vmid" "$CONFIG")"
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
