#!/usr/bin/env bash
# setup-nix-builder.sh — Configure a Nix Linux builder for NixOS image builds
#
# Building NixOS VM images requires a Linux execution environment. This script
# configures the builder based on nix_builder.type in site/config.yaml:
#
#   local          - Workstation is Linux; verify Nix works, nothing to set up
#   linux-builder  - Nix-managed NixOS VM on macOS (nix-darwin or standalone)
#   remote         - Delegate builds to a Linux host over SSH
#
# Usage:
#   framework/scripts/setup-nix-builder.sh                  # Configure builder
#   framework/scripts/setup-nix-builder.sh --dry-run         # Show what would be done
#   framework/scripts/setup-nix-builder.sh --verify          # Check existing setup
#   framework/scripts/setup-nix-builder.sh --start           # Start the builder VM
#   framework/scripts/setup-nix-builder.sh --stop            # Stop the builder VM

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_PATH="${REPO_DIR}/site/config.yaml"
DRY_RUN=0
VERIFY_ONLY=0
START_ONLY=0
STOP_ONLY=0

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)    CONFIG_PATH="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    --verify)    VERIFY_ONLY=1; shift ;;
    --start)     START_ONLY=1; shift ;;
    --stop)      STOP_ONLY=1; shift ;;
    -*)          echo "Unknown option: $1" >&2; exit 2 ;;
    *)           echo "Unexpected argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_PATH}" >&2
  exit 2
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not installed" >&2
  exit 2
fi

# --- Read config ---
BUILDER_TYPE=$(yq '.nix_builder.type // "linux-builder"' "$CONFIG_PATH")

# Resource settings for linux-builder
CPUS=$(yq '.nix_builder.cpus // 8' "$CONFIG_PATH")
MEMORY_GB=$(yq '.nix_builder.memory_gb // 24' "$CONFIG_PATH")
MEMORY_MB=$((MEMORY_GB * 1024))
STORE_GB=$(yq '.nix_builder.store_gb // 20' "$CONFIG_PATH")

# Remote builder settings (only used when type: remote)
REMOTE_HOST=$(yq '.nix_builder.remote_host // ""' "$CONFIG_PATH")
REMOTE_USER=$(yq '.nix_builder.remote_user // "root"' "$CONFIG_PATH")
REMOTE_SSH_KEY=$(yq '.nix_builder.remote_ssh_key // "~/.ssh/id_ed25519"' "$CONFIG_PATH")
MAX_JOBS=$(yq '.nix_builder.max_jobs // 4' "$CONFIG_PATH")
SPEED_FACTOR=$(yq '.nix_builder.speed_factor // 1' "$CONFIG_PATH")

# Expand tilde in SSH key path
REMOTE_SSH_KEY="${REMOTE_SSH_KEY/#\~/$HOME}"

OS_TYPE=$(uname -s)
MACHINES_FILE="/etc/nix/machines"
NIX_CONF="/etc/nix/nix.conf"
BUILDER_DIR="${HOME}/.nix-builder"
START_SCRIPT="${BUILDER_DIR}/start-builder.sh"

# --- Common helpers ---
check_nix_installed() {
  if ! command -v nix &>/dev/null; then
    echo "  ERROR: Nix is not installed on this workstation." >&2
    echo "" >&2
    echo "  Install Nix:" >&2
    echo "    curl -L https://nixos.org/nix/install | sh" >&2
    return 1
  fi
  local nix_ver
  nix_ver=$(nix --version 2>/dev/null)
  echo "  ✓ Nix installed: ${nix_ver}"
  return 0
}

# The new-style nix CLI (nix build, nix run, nix store) and flake references
# (nixpkgs#...) require experimental features to be enabled in nix.conf.
# This is needed for all NixOS image-building workflows.
ensure_experimental_features() {
  local needed="experimental-features = nix-command flakes"

  # Check if already enabled
  if [[ -f "$NIX_CONF" ]] && grep -q 'nix-command' "$NIX_CONF" 2>/dev/null && \
     grep -q 'flakes' "$NIX_CONF" 2>/dev/null; then
    echo "  ✓ nix-command and flakes already enabled in ${NIX_CONF}"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would enable nix-command and flakes in ${NIX_CONF}"
    return 0
  fi

  echo "  Enabling nix-command and flakes in ${NIX_CONF}..."
  echo "$needed" | sudo tee -a "$NIX_CONF" > /dev/null

  # Restart nix-daemon so it picks up the new config
  echo "  Restarting nix-daemon to apply..."
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    sudo launchctl kickstart -k system/org.nixos.nix-daemon 2>/dev/null
  else
    sudo systemctl restart nix-daemon 2>/dev/null
  fi
  sleep 2
  echo "  ✓ nix-command and flakes enabled"
}

test_linux_build() {
  echo ""
  echo "--- Test build (x86_64-linux) ---"
  echo "  Building nixpkgs.hello for x86_64-linux (this may take a moment)..."
  if nix build --impure --expr '(import <nixpkgs> { system = "x86_64-linux"; }).hello' --no-link 2>&1; then
    echo "  ✓ Test build succeeded"
    return 0
  else
    echo "  ✗ Test build failed"
    return 1
  fi
}

restart_nix_daemon() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would restart nix-daemon"
    return 0
  fi

  echo "  Restarting nix-daemon..."
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    sudo launchctl kickstart -k system/org.nixos.nix-daemon 2>/dev/null
  else
    sudo systemctl restart nix-daemon 2>/dev/null
  fi
  echo "  ✓ nix-daemon restarted"
}

# --- SSH helper for remote builder ---
ssh_remote() {
  ssh -n -x -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      -i "$REMOTE_SSH_KEY" "${REMOTE_USER}@${REMOTE_HOST}" "$@" 2>/dev/null
}

# ============================================================
# Type: local (Linux workstation)
# ============================================================

setup_local() {
  echo ""
  echo "=== Nix Builder: local (Linux workstation) ==="
  echo ""

  if [[ "$OS_TYPE" != "Linux" ]]; then
    echo "  ERROR: nix_builder.type is 'local' but workstation is ${OS_TYPE}." >&2
    echo "         Linux is required for local builds. Use 'linux-builder' for macOS." >&2
    return 1
  fi

  echo "--- Prerequisites ---"
  if ! check_nix_installed; then
    return 1
  fi
  ensure_experimental_features

  if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo "  [DRY RUN] Would verify a test build of x86_64-linux derivation"
    echo ""
    echo "Nix builder: local (Linux workstation). No setup needed."
    return 0
  fi

  if test_linux_build; then
    echo ""
    echo "Nix builder: local (Linux workstation). No setup needed."
    return 0
  else
    echo ""
    echo "  Test build failed. Check that Nix is configured correctly."
    return 1
  fi
}

verify_local() {
  echo ""
  echo "--- Nix builder verification (local) ---"

  if [[ "$OS_TYPE" != "Linux" ]]; then
    echo "  ✗ Workstation is ${OS_TYPE}, not Linux"
    return 1
  fi
  echo "  ✓ Workstation is Linux"

  if ! check_nix_installed; then
    return 1
  fi
  ensure_experimental_features

  if test_linux_build; then
    echo ""
    echo "Nix builder: local. No setup needed."
    return 0
  fi
  return 1
}

# ============================================================
# Type: linux-builder (Nix-managed VM on macOS)
# ============================================================

detect_nix_darwin() {
  if [[ -x /run/current-system/sw/bin/darwin-rebuild ]]; then
    return 0
  fi
  if command -v darwin-rebuild &>/dev/null; then
    return 0
  fi
  return 1
}

BUILDER_SSH_CONFIG="/etc/ssh/ssh_config.d/100-linux-builder.conf"
BUILDER_SSH_KEY="/etc/nix/builder_ed25519"
BUILDER_PORT=31022

check_builder_running() {
  # Check if the builder VM's SSH port is responding.
  if nc -z localhost "$BUILDER_PORT" 2>/dev/null; then
    return 0
  fi
  return 1
}

find_builder_pid() {
  # Find an existing QEMU process running the linux-builder
  pgrep -f "qemu-system.*hostfwd=tcp::${BUILDER_PORT}-:22" 2>/dev/null | head -1
}

# Write /etc/nix/machines with correct maxJobs matching configured CPUs.
# Checks current content first to avoid unnecessary sudo prompts.
write_machines_file() {
  local expected_line="ssh-ng://linux-builder x86_64-linux ${BUILDER_SSH_KEY} ${CPUS} 1 nixos-test,benchmark,big-parallel,kvm -"

  if [[ -f "$MACHINES_FILE" ]] && grep -qF "$expected_line" "$MACHINES_FILE" 2>/dev/null; then
    echo "  ✓ ${MACHINES_FILE}: maxJobs=${CPUS} (matches config)"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would write ${MACHINES_FILE} with maxJobs=${CPUS}"
    return 0
  fi

  echo "  Writing ${MACHINES_FILE} (maxJobs=${CPUS})..."
  echo "$expected_line" | sudo tee "$MACHINES_FILE" > /dev/null
  echo "  ✓ ${MACHINES_FILE} updated"
}

# Generate ~/.nix-builder/start-builder.sh with correct QEMU_OPTS.
write_start_script() {
  mkdir -p "$BUILDER_DIR"

  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would write ${START_SCRIPT} (cpus=${CPUS}, memory=${MEMORY_MB}MB)"
    return 0
  fi

  cat > "$START_SCRIPT" <<STARTEOF
#!/bin/bash
# Generated by setup-nix-builder.sh — do not edit manually
# Resource settings from site/config.yaml (${timestamp})
#   cpus: ${CPUS}
#   memory_gb: ${MEMORY_GB} (${MEMORY_MB}MB)
#   store_gb: ${STORE_GB}
export TMPDIR=~/.nix-builder
export USE_TMPDIR=1
export QEMU_OPTS="-smp ${CPUS} -m ${MEMORY_MB}"

# Source nix profile to get nix on PATH (needed for non-interactive shells)
for p in /nix/var/nix/profiles/default/bin "\$HOME/.nix-profile/bin"; do
  [[ -d "\$p" ]] && export PATH="\$p:\$PATH"
done

nix run nixpkgs#darwin.linux-builder >> ~/.nix-builder/builder.log 2>&1 &
disown
STARTEOF
  chmod +x "$START_SCRIPT"
  echo "  ✓ ${START_SCRIPT} written (cpus=${CPUS}, memory=${MEMORY_GB}GB)"
}

start_builder_vm() {
  if check_builder_running; then
    local pid
    pid=$(find_builder_pid)
    echo "  ✓ linux-builder VM is already running (pid ${pid:-unknown})"
    return 0
  fi

  if [[ ! -f "$START_SCRIPT" ]]; then
    echo "  ERROR: ${START_SCRIPT} does not exist." >&2
    echo "  Run 'setup-nix-builder.sh' first (without flags) to generate it." >&2
    return 1
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would start builder VM via ${START_SCRIPT}"
    return 0
  fi

  echo "  Starting builder VM via ${START_SCRIPT}..."
  echo "  (First run downloads the VM image — this may take a few minutes)"
  bash "$START_SCRIPT"

  # Wait for SSH on the builder port (up to 120s)
  echo "  Waiting for VM to boot (checking localhost:${BUILDER_PORT})..."
  local attempts=0
  while (( attempts < 60 )); do
    if check_builder_running; then
      local pid
      pid=$(find_builder_pid)
      echo "  ✓ linux-builder VM is running (pid ${pid:-unknown})"
      # Check if store overlay needs resizing. The linux-builder creates a
      # default ~800MB store.img which is too small for large closures.
      # Resize offline: stop builder, expand file, resize2fs, restart.
      ensure_store_overlay_size
      return 0
    fi
    (( attempts++ ))
    sleep 2
  done

  echo "  ✗ Timed out waiting for linux-builder VM (120s)"
  echo "  Check ${BUILDER_DIR}/builder.log for errors"
  return 1
}

# Ensure store overlay is at the configured size. If undersized, stop the
# builder, expand the raw file, resize the ext4 filesystem offline (no SSH
# needed), and restart. This handles both first-boot (builder creates default
# ~800MB) and overlay reset (build-all-images.sh deletes and recreates).
ensure_store_overlay_size() {
  local store_img="${BUILDER_DIR}/store.img"
  if [[ ! -f "$store_img" ]]; then
    return 0
  fi

  local want_bytes=$(( STORE_GB * 1024 * 1024 * 1024 ))
  local cur_bytes
  cur_bytes=$(stat -f%z "$store_img" 2>/dev/null || echo 0)

  if [[ "$cur_bytes" -ge "$want_bytes" ]]; then
    return 0
  fi

  echo "  Store overlay is $(( cur_bytes / 1024 / 1024 ))MB, need ${STORE_GB}GB"
  echo "  Stopping builder for offline resize..."
  stop_builder_vm

  # Expand the raw file
  echo "  Expanding raw file to ${STORE_GB}GB..."
  dd if=/dev/zero of="$store_img" bs=1 count=0 seek=$want_bytes 2>/dev/null

  # Resize the ext4 filesystem offline using e2fsprogs from nix.
  # This runs on the host — no SSH, no permissions issues.
  echo "  Resizing ext4 filesystem..."
  if nix run nixpkgs#e2fsprogs -- e2fsck -fy "$store_img" 2>/dev/null && \
     nix run nixpkgs#e2fsprogs -- resize2fs "$store_img" 2>/dev/null; then
    echo "  ✓ Store overlay resized to ${STORE_GB}GB"
  else
    echo "  ⚠ resize2fs failed — deleting store.img for fresh creation"
    rm -f "$store_img"
  fi

  # Restart the builder
  echo "  Restarting builder..."
  bash "$START_SCRIPT"
  local restart_attempts=0
  while (( restart_attempts < 60 )); do
    if check_builder_running; then
      local pid
      pid=$(find_builder_pid)
      echo "  ✓ Builder restarted (pid ${pid:-unknown})"

      # If we deleted store.img above, the builder recreated it at default
      # size. Recurse once to resize the new file.
      local new_bytes
      new_bytes=$(stat -f%z "$store_img" 2>/dev/null || echo 0)
      if [[ "$new_bytes" -lt "$want_bytes" ]]; then
        ensure_store_overlay_size
      fi
      return 0
    fi
    (( restart_attempts++ ))
    sleep 2
  done
  echo "  ✗ Builder failed to restart after resize"
  return 1
}

stop_builder_vm() {
  # Try launchctl first (nix-darwin managed)
  sudo launchctl bootout system/org.nixos.linux-builder 2>/dev/null || true

  # Kill the nohup'd QEMU process
  local pid
  pid=$(find_builder_pid)
  if [[ -n "$pid" ]]; then
    echo "  Stopping builder VM (pid ${pid})..."
    kill "$pid" 2>/dev/null
    sleep 2
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null
    fi
    echo "  ✓ Builder VM stopped"
  else
    echo "  Builder VM is not running"
  fi
}

setup_linux_builder() {
  echo ""
  echo "=== Nix Builder: linux-builder (local VM on macOS) ==="
  echo "  Resources: ${CPUS} CPUs, ${MEMORY_GB}GB RAM (${MEMORY_MB}MB)"
  echo ""

  if [[ "$OS_TYPE" == "Linux" ]]; then
    echo "  WARNING: nix_builder.type is 'linux-builder' but workstation is Linux."
    echo "           You probably want 'local' instead. Continuing anyway..."
    echo ""
  fi

  echo "--- Prerequisites ---"
  if ! check_nix_installed; then
    return 1
  fi
  ensure_experimental_features

  if detect_nix_darwin; then
    echo "  ✓ nix-darwin detected"
    setup_linux_builder_darwin
  else
    echo "  nix-darwin not detected (standalone Nix on macOS)"
    setup_linux_builder_standalone
  fi
}

setup_linux_builder_darwin() {
  echo ""
  echo "--- nix-darwin linux-builder configuration ---"

  # Write start script and machines file regardless of running state
  echo ""
  echo "--- Resource configuration ---"
  write_start_script
  write_machines_file

  if check_builder_running; then
    echo "  ✓ linux-builder is already configured and accessible"

    if [[ $DRY_RUN -eq 1 ]]; then
      echo ""
      echo "  [DRY RUN] Would verify a test build of x86_64-linux derivation"
      return 0
    fi

    test_linux_build
    return $?
  fi

  # nix-darwin manages the builder declaratively — we can't edit the user's
  # flake.nix or configuration.nix programmatically, so instructions are
  # genuinely appropriate here.
  echo "  linux-builder is not yet configured."
  echo ""
  echo "  Add the following to your nix-darwin configuration (e.g., flake.nix):"
  echo ""
  echo "    nix.linux-builder = {"
  echo "      enable = true;"
  echo "      maxJobs = ${CPUS};"
  echo "      config = {"
  echo "        virtualisation.cores = ${CPUS};"
  echo "        virtualisation.memorySize = ${MEMORY_MB};  # ${MEMORY_GB}GB"
  echo "        virtualisation.diskSize = 40960;   # 40GB for Nix store"
  echo "      };"
  echo "    };"
  echo ""
  echo "  Then apply:"
  echo "    darwin-rebuild switch"
  echo ""
  echo "  After applying, re-run this script to verify the builder works."
  return 0
}

setup_linux_builder_standalone() {
  echo ""
  echo "--- Standalone Nix linux-builder configuration ---"

  # Check Nix version
  local nix_ver
  nix_ver=$(nix --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
  local nix_major nix_minor
  nix_major=$(echo "$nix_ver" | cut -d. -f1)
  nix_minor=$(echo "$nix_ver" | cut -d. -f2)

  if [[ "$nix_major" -lt 2 ]] || { [[ "$nix_major" -eq 2 ]] && [[ "$nix_minor" -lt 19 ]]; }; then
    echo "  WARNING: Nix version ${nix_ver} detected. linux-builder support requires Nix 2.19+."
    echo "           Consider upgrading Nix: nix upgrade-nix"
  else
    echo "  ✓ Nix version ${nix_ver} (≥ 2.19)"
  fi

  # --- Step 1: Configure SSH so "linux-builder" resolves to the local VM ---
  echo ""
  echo "--- SSH configuration ---"

  if [[ -f "$BUILDER_SSH_CONFIG" ]]; then
    echo "  ✓ ${BUILDER_SSH_CONFIG} already exists"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would create ${BUILDER_SSH_CONFIG}"
    else
      echo "  Creating ${BUILDER_SSH_CONFIG}..."
      sudo mkdir -p /etc/ssh/ssh_config.d
      cat <<'SSHEOF' | sudo tee "$BUILDER_SSH_CONFIG" > /dev/null
Host linux-builder
  Hostname localhost
  HostKeyAlias linux-builder
  Port 31022
  User builder
  IdentityFile /etc/nix/builder_ed25519
  StrictHostKeyChecking no
SSHEOF
      echo "  ✓ SSH config for linux-builder created"
    fi
  fi

  # Check builder SSH key exists (created by a previous 'nix run' invocation)
  if [[ -f "$BUILDER_SSH_KEY" ]]; then
    echo "  ✓ Builder SSH key exists at ${BUILDER_SSH_KEY}"
  else
    echo "  Builder SSH key not found at ${BUILDER_SSH_KEY}."
    echo "  It will be created when the builder VM starts for the first time."
  fi

  # --- Step 2: Write resource configuration ---
  echo ""
  echo "--- Resource configuration ---"
  write_start_script
  write_machines_file

  local need_nix_conf=0
  if [[ ! -f "$NIX_CONF" ]] || ! grep -qF "builders = @/etc/nix/machines" "$NIX_CONF" 2>/dev/null; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would add builders directive to ${NIX_CONF}"
    else
      echo "builders = @/etc/nix/machines" | sudo tee -a "$NIX_CONF" > /dev/null
      echo "  ✓ ${NIX_CONF}: builders directive"
      need_nix_conf=1
    fi
  else
    echo "  ✓ ${NIX_CONF}: builders directive (already present)"
  fi

  if [[ ! -f "$NIX_CONF" ]] || ! grep -qF "builders-use-substitutes = true" "$NIX_CONF" 2>/dev/null; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would add builders-use-substitutes to ${NIX_CONF}"
    else
      echo "builders-use-substitutes = true" | sudo tee -a "$NIX_CONF" > /dev/null
      echo "  ✓ ${NIX_CONF}: builders-use-substitutes"
      need_nix_conf=1
    fi
  else
    echo "  ✓ ${NIX_CONF}: builders-use-substitutes (already present)"
  fi

  # --- Step 3: Start the builder VM ---
  echo ""
  echo "--- linux-builder VM ---"

  if ! start_builder_vm; then
    return 1
  fi

  # --- Step 4: Restart nix-daemon to pick up the new machines config ---
  echo ""
  restart_nix_daemon
  sleep 2

  # --- Step 5: Test build ---
  if test_linux_build; then
    echo ""
    echo "  linux-builder is configured and working."
    echo "  Resources: ${CPUS} CPUs, ${MEMORY_GB}GB RAM"
    echo ""
    echo "  To restart the builder:"
    echo "    framework/scripts/setup-nix-builder.sh --stop"
    echo "    framework/scripts/setup-nix-builder.sh --start"
    return 0
  else
    echo ""
    echo "  Builder VM is running but test build failed."
    echo "  Diagnostics:"
    echo "    nc -z localhost ${BUILDER_PORT}  (port check)"
    echo "    cat ${MACHINES_FILE}"
    echo "    cat ${NIX_CONF}"
    return 1
  fi
}

verify_linux_builder() {
  echo ""
  echo "--- Nix builder verification (linux-builder) ---"
  echo "  Expected: ${CPUS} CPUs, ${MEMORY_GB}GB RAM"
  echo ""

  local errors=0

  if ! check_nix_installed; then
    return 1
  fi
  ensure_experimental_features

  # Check start script
  if [[ -f "$START_SCRIPT" ]]; then
    local expected_qemu="-smp ${CPUS} -m ${MEMORY_MB}"
    if grep -qF -- "$expected_qemu" "$START_SCRIPT" 2>/dev/null; then
      echo "  ✓ ${START_SCRIPT} has correct QEMU_OPTS (cpus=${CPUS}, memory=${MEMORY_MB}MB)"
    else
      echo "  ✗ ${START_SCRIPT} has wrong QEMU_OPTS (expected: ${expected_qemu})"
      echo "    Re-run setup-nix-builder.sh to regenerate"
      (( errors++ ))
    fi
  else
    echo "  ✗ ${START_SCRIPT} does not exist"
    echo "    Run setup-nix-builder.sh to generate it"
    (( errors++ ))
  fi

  # Check /etc/nix/machines
  if [[ -f "$MACHINES_FILE" ]]; then
    local expected_jobs=" ${CPUS} "
    if grep -q "linux-builder" "$MACHINES_FILE" 2>/dev/null; then
      # Extract the maxJobs field (4th field)
      local current_jobs
      current_jobs=$(awk '/linux-builder/ { print $4 }' "$MACHINES_FILE")
      if [[ "$current_jobs" == "$CPUS" ]]; then
        echo "  ✓ ${MACHINES_FILE} maxJobs=${CPUS} (matches config)"
      else
        echo "  ✗ ${MACHINES_FILE} maxJobs=${current_jobs} (expected ${CPUS})"
        (( errors++ ))
      fi
    else
      echo "  ✗ ${MACHINES_FILE} has no linux-builder entry"
      (( errors++ ))
    fi
  else
    echo "  ✗ ${MACHINES_FILE} does not exist"
    (( errors++ ))
  fi

  # Check builder is running
  if check_builder_running; then
    echo "  ✓ linux-builder VM is accessible"
  else
    echo "  ✗ linux-builder VM is not accessible"
    echo "    Start it: framework/scripts/setup-nix-builder.sh --start"
    (( errors++ ))
  fi

  # Test build
  test_linux_build || (( errors++ ))

  return $errors
}

# ============================================================
# Type: remote (SSH to separate Linux host)
# ============================================================

setup_remote() {
  echo ""
  echo "=== Nix Builder: remote (SSH to ${REMOTE_USER}@${REMOTE_HOST}) ==="
  echo ""

  if [[ -z "$REMOTE_HOST" ]]; then
    echo "  ERROR: nix_builder.remote_host is not set in config.yaml" >&2
    return 1
  fi

  echo "--- Prerequisites ---"
  if ! check_nix_installed; then
    return 1
  fi
  ensure_experimental_features

  # Check SSH connectivity
  echo ""
  echo "--- SSH connectivity ---"
  if [[ ! -f "$REMOTE_SSH_KEY" ]]; then
    echo "  ERROR: SSH key not found: ${REMOTE_SSH_KEY}" >&2
    return 1
  fi
  echo "  ✓ SSH key exists: ${REMOTE_SSH_KEY}"

  local remote_os
  remote_os=$(ssh_remote "uname -s" 2>/dev/null) || remote_os=""
  if [[ -z "$remote_os" ]]; then
    echo "  ✗ SSH to ${REMOTE_USER}@${REMOTE_HOST} failed"
    echo "    Verify SSH access: ssh -i ${REMOTE_SSH_KEY} ${REMOTE_USER}@${REMOTE_HOST}"
    return 1
  fi
  echo "  ✓ SSH to ${REMOTE_USER}@${REMOTE_HOST} succeeded"

  if [[ "$remote_os" != "Linux" ]]; then
    echo "  ERROR: Remote host is ${remote_os}, not Linux" >&2
    return 1
  fi
  echo "  ✓ Remote host is Linux"

  # Check Nix on remote
  echo ""
  echo "--- Nix on remote host ---"
  local remote_nix
  remote_nix=$(ssh_remote "nix --version" 2>/dev/null) || remote_nix=""
  if [[ -z "$remote_nix" ]]; then
    echo "  ✗ Nix is not installed on ${REMOTE_HOST}"
    echo ""
    echo "  Install Nix on the remote host:"
    echo "    ssh ${REMOTE_USER}@${REMOTE_HOST}"
    echo "    curl -L https://nixos.org/nix/install | sh --daemon"
    echo ""
    echo "  Note: This installs the Nix *package manager* on the existing OS"
    echo "  (e.g., Debian on a Proxmox node). It does NOT convert the host to NixOS."
    echo "  Nix installs entirely under /nix/ and does not modify system packages."
    echo ""
    echo "  After installing Nix, re-run this script."
    return 1
  fi
  echo "  ✓ Remote Nix: ${remote_nix}"

  # Configure local workstation
  echo ""
  echo "--- Local builder configuration ---"

  # Use cpus from config for remote maxJobs too
  local remote_jobs="${CPUS}"
  local builder_line="ssh://${REMOTE_USER}@${REMOTE_HOST} x86_64-linux ${REMOTE_SSH_KEY} ${remote_jobs} ${SPEED_FACTOR} - - nixos-test,benchmark,big-parallel,kvm"
  local need_restart=0

  # Check if already configured
  if [[ -f "$MACHINES_FILE" ]] && grep -qF "${REMOTE_HOST}" "$MACHINES_FILE" 2>/dev/null; then
    echo "  ✓ ${MACHINES_FILE} already has entry for ${REMOTE_HOST}"
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would add to ${MACHINES_FILE}: ${builder_line}"
    else
      echo "$builder_line" | sudo tee -a "$MACHINES_FILE" > /dev/null
      echo "  ✓ Added ${REMOTE_HOST} to ${MACHINES_FILE}"
      need_restart=1
    fi
  fi

  if [[ ! -f "$NIX_CONF" ]] || ! grep -qF "builders = @/etc/nix/machines" "$NIX_CONF" 2>/dev/null; then
    echo "builders = @/etc/nix/machines" | sudo tee -a "$NIX_CONF" > /dev/null
    echo "  ✓ ${NIX_CONF}: builders directive"
    need_restart=1
  else
    echo "  ✓ ${NIX_CONF}: builders directive (already present)"
  fi

  if [[ ! -f "$NIX_CONF" ]] || ! grep -qF "builders-use-substitutes = true" "$NIX_CONF" 2>/dev/null; then
    echo "builders-use-substitutes = true" | sudo tee -a "$NIX_CONF" > /dev/null
    echo "  ✓ ${NIX_CONF}: builders-use-substitutes"
    need_restart=1
  else
    echo "  ✓ ${NIX_CONF}: builders-use-substitutes (already present)"
  fi

  # Restart nix-daemon if we changed anything
  if [[ $need_restart -eq 1 ]]; then
    echo ""
    restart_nix_daemon
    sleep 2
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo "  [DRY RUN] Would restart nix-daemon and run test build"
    return 0
  fi

  # Test build
  if test_linux_build; then
    echo ""
    echo "  Remote builder is configured and working."
    echo ""
    echo "  Cleanup (for later): Once CI/CD handles image builds, the remote"
    echo "  builder is no longer needed. To remove Nix from the remote host:"
    echo "    ssh ${REMOTE_USER}@${REMOTE_HOST} \"rm -rf /nix && rm -rf /etc/nix\""
    return 0
  else
    echo ""
    echo "  Builder configuration written but test build failed."
    echo "  Diagnostics:"
    echo "    ssh -i ${REMOTE_SSH_KEY} ${REMOTE_USER}@${REMOTE_HOST} nix --version"
    echo "    cat ${MACHINES_FILE}"
    echo "    cat ${NIX_CONF}"
    return 1
  fi
}

verify_remote() {
  echo ""
  echo "--- Nix builder verification (remote) ---"

  if [[ -z "$REMOTE_HOST" ]]; then
    echo "  ✗ nix_builder.remote_host is not set in config.yaml"
    return 1
  fi

  if ! check_nix_installed; then
    return 1
  fi
  ensure_experimental_features

  # SSH check
  local remote_os
  remote_os=$(ssh_remote "uname -s" 2>/dev/null) || remote_os=""
  if [[ -n "$remote_os" ]]; then
    echo "  ✓ SSH to ${REMOTE_USER}@${REMOTE_HOST} succeeded"
  else
    echo "  ✗ SSH to ${REMOTE_USER}@${REMOTE_HOST} failed"
    return 1
  fi

  # Remote Nix check
  local remote_nix
  remote_nix=$(ssh_remote "nix --version" 2>/dev/null) || remote_nix=""
  if [[ -n "$remote_nix" ]]; then
    echo "  ✓ Remote Nix: ${remote_nix}"
  else
    echo "  ✗ Nix not installed on remote host"
    return 1
  fi

  # Local machines file check
  if [[ -f "$MACHINES_FILE" ]] && grep -q "${REMOTE_HOST}" "$MACHINES_FILE" 2>/dev/null; then
    echo "  ✓ ${MACHINES_FILE} has entry for ${REMOTE_HOST}"
  else
    echo "  ✗ ${MACHINES_FILE} missing entry for ${REMOTE_HOST}"
    return 1
  fi

  test_linux_build
}

# ============================================================
# Main
# ============================================================

echo ""
echo "=== Nix Builder Setup ==="
echo "Builder type: ${BUILDER_TYPE}"
echo "Workstation:  ${OS_TYPE}"

# OS/type sanity checks
if [[ "$OS_TYPE" == "Darwin" && "$BUILDER_TYPE" == "local" ]]; then
  echo ""
  echo "ERROR: nix_builder.type is 'local' but workstation is macOS." >&2
  echo "       macOS cannot build Linux images natively." >&2
  echo "       Set nix_builder.type to 'linux-builder' or 'remote' in config.yaml." >&2
  exit 1
fi

if [[ "$OS_TYPE" == "Linux" && "$BUILDER_TYPE" != "local" ]]; then
  echo ""
  echo "  NOTE: Workstation is Linux but nix_builder.type is '${BUILDER_TYPE}'."
  echo "        You may want to use 'local' instead (no builder setup needed)."
fi

# --- Stop mode ---
if [[ $STOP_ONLY -eq 1 ]]; then
  if [[ "$BUILDER_TYPE" != "linux-builder" ]]; then
    echo "ERROR: --stop only applies to linux-builder type" >&2
    exit 1
  fi
  stop_builder_vm
  exit $?
fi

# --- Start mode ---
if [[ $START_ONLY -eq 1 ]]; then
  if [[ "$BUILDER_TYPE" != "linux-builder" ]]; then
    echo "ERROR: --start only applies to linux-builder type" >&2
    exit 1
  fi
  start_builder_vm
  exit $?
fi

# --- Verify mode ---
if [[ $VERIFY_ONLY -eq 1 ]]; then
  case "$BUILDER_TYPE" in
    local)          verify_local ;;
    linux-builder)  verify_linux_builder ;;
    remote)         verify_remote ;;
    *)
      echo "ERROR: Unknown nix_builder.type: ${BUILDER_TYPE}" >&2
      echo "Valid values: local, linux-builder, remote" >&2
      exit 2
      ;;
  esac
  exit $?
fi

# --- Setup mode ---
case "$BUILDER_TYPE" in
  local)          setup_local ;;
  linux-builder)  setup_linux_builder ;;
  remote)         setup_remote ;;
  *)
    echo "ERROR: Unknown nix_builder.type: ${BUILDER_TYPE}" >&2
    echo "Valid values: local, linux-builder, remote" >&2
    exit 2
    ;;
esac
exit $?
