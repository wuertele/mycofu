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
#   framework/scripts/setup-nix-builder.sh                  # Converge builder to configured state
#   framework/scripts/setup-nix-builder.sh --dry-run         # Show what would be done
#   framework/scripts/setup-nix-builder.sh --verify          # Converge, then run test build
#   framework/scripts/setup-nix-builder.sh --start           # Converge to running state
#   framework/scripts/setup-nix-builder.sh --stop            # Stop the builder VM
#
# Convergence: every entrypoint (default, --start, --verify) detects drift
# between site/config.yaml and the on-disk builder state, fixes it
# automatically, then proceeds. There is no "remember to run the right
# combination of commands" — re-running setup-nix-builder.sh after a pull
# is always sufficient. See converge_builder() for the invariants enforced.

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
STORE_GB=$(yq '.nix_builder.store_gb // 40' "$CONFIG_PATH")

# nixpkgs ref used to resolve the builder VM derivation. This must never be a
# bare `nixpkgs#` indirect ref: that resolves through the global flake registry
# (floating nixpkgs-unstable), not flake.lock. Unstable dropped x86_64-darwin
# in 26.11, which broke the builder on Intel Macs and disabled DR (#564).
# The default below matches site/config.yaml; it is a pin, never unstable.
BUILDER_NIXPKGS=$(yq '.nix_builder.nixpkgs_ref // "github:NixOS/nixpkgs/nixpkgs-26.05-darwin"' "$CONFIG_PATH")
# BUILDER_NIXPKGS is consumed by (a) the generated launcher for linux-builder
# and (b) test_linux_build() below, which runs during --verify regardless of
# BUILDER_TYPE. Codex P2 (batch B review of the initial #566 fix) flagged
# that the linux-builder-only guard let a `remote` or `local` config with
# `nix_builder.nixpkgs_ref: nixpkgs` bypass validation and reintroduce a
# floating ref via test_linux_build. Lift the validation so any caller
# using BUILDER_NIXPKGS gets a validated value.
if [[ -z "$BUILDER_NIXPKGS" || "$BUILDER_NIXPKGS" == "null" ]]; then
  echo "ERROR: nix_builder.nixpkgs_ref is present but empty in ${CONFIG_PATH}" >&2
  echo "       Set it to a release ref, e.g. github:NixOS/nixpkgs/nixpkgs-26.05-darwin" >&2
  echo "       (Remove the key entirely to accept the built-in default.)" >&2
  exit 2
fi
# The ref is interpolated into the generated launcher as a shell assignment,
# so restrict it to flakeref-safe characters: config content must not be able
# to inject shell. This also rejects a '#attr' suffix — the attribute belongs
# to the call site, not the ref.
# Held in a variable: an unquoted '&' inside [[ =~ ]] is a bash syntax error.
BUILDER_NIXPKGS_SAFE_RE='^[A-Za-z0-9:/._+=?&%-]+$'
if [[ ! "$BUILDER_NIXPKGS" =~ $BUILDER_NIXPKGS_SAFE_RE ]]; then
  echo "ERROR: nix_builder.nixpkgs_ref contains unsupported characters: ${BUILDER_NIXPKGS}" >&2
  echo "       Give the flake ref only, with no '#attribute' suffix and no shell metacharacters." >&2
  exit 2
fi
# A bare/registry ref floats on nixpkgs-unstable — the #564 failure mode.
if [[ "$BUILDER_NIXPKGS" =~ ^(flake:)?nixpkgs(/|$) ]]; then
  echo "ERROR: nix_builder.nixpkgs_ref is an indirect registry ref: ${BUILDER_NIXPKGS}" >&2
  echo "       Indirect refs resolve through the global registry (floating unstable)," >&2
  echo "       not flake.lock. Use an explicit ref, e.g." >&2
  echo "       github:NixOS/nixpkgs/nixpkgs-26.05-darwin" >&2
  exit 2
fi

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
QCOW2_FILE="${BUILDER_DIR}/nixos.qcow2"
STORE_IMG_FILE="${BUILDER_DIR}/store.img"
PATCHED_VM_FILE="${BUILDER_DIR}/run-nixos-vm-patched"
BUILDER_PORT=31022

# --- Convergence: detect drift, fix it, no manual choreography ---
#
# Every entrypoint (default, --start, --verify) calls converge_builder()
# first. It walks the invariants the operator used to enforce by hand
# (config matches start-builder.sh, qcow2 size matches store_gb, launcher
# line has the right DISK_MB, VM is running) and fixes drift inline.
#
# Why this exists: every previous "fix" in this corner of the code has
# left a manual postcondition the operator had to remember. Forgetting
# any of them produced a confusing failure (silent 40 GiB qcow2 when
# config asked for 80, etc.). The script always has enough information
# to verify those postconditions itself; it just didn't.

# Resolve a qemu-img binary path. Prefers $PATH, falls back to nix shell.
# Echoes the path on stdout; non-zero return means qemu-img is unavailable.
# Cached after first resolution to avoid re-running nix per call.
QEMU_IMG_CACHED=""
resolve_qemu_img() {
  if [[ -n "$QEMU_IMG_CACHED" ]] && [[ -x "$QEMU_IMG_CACHED" ]]; then
    echo "$QEMU_IMG_CACHED"; return 0
  fi
  local path
  if path=$(command -v qemu-img 2>/dev/null); then
    QEMU_IMG_CACHED="$path"
    echo "$path"; return 0
  fi
  # nix-store fallback: look for any qemu-img already in the local store.
  # We avoid `nix shell <ref>#qemu-utils` here because that downloads on
  # first call; the store-only path is fast and offline-safe.
  if path=$(ls /nix/store/*qemu*/bin/qemu-img 2>/dev/null | head -1); then
    if [[ -x "$path" ]]; then
      QEMU_IMG_CACHED="$path"
      echo "$path"; return 0
    fi
  fi
  # Last resort: nix shell. This is needed on a fresh workstation where
  # the host store has no qemu yet. Errors are silent here; the caller
  # treats failure as "qcow2 size unverifiable".
  if path=$(nix shell "${BUILDER_NIXPKGS}#qemu-utils" --command sh -c 'command -v qemu-img' 2>/dev/null); then
    if [[ -n "$path" ]] && [[ -x "$path" ]]; then
      QEMU_IMG_CACHED="$path"
      echo "$path"; return 0
    fi
  fi
  return 1
}

# Check whether the existing qcow2 has the configured virtual size.
# Echoes "ok", "missing", or "wrong-size:ACTUAL_MB:EXPECTED_MB".
#
# If qemu-img cannot be resolved at all (neither on PATH nor in the
# local nix store), we treat that as "wrong-size:unknown:EXPECTED" so
# the caller's convergence path purges and recreates the qcow2 rather
# than silently accepting whatever size happens to be on disk. The
# qcow2 has no precious state, so the cost of an unnecessary purge is
# bounded (rebuilds the writable store from cache.nixos.org); the cost
# of silently accepting drift is unbounded (the exact failure mode this
# fix exists to prevent).
qcow2_size_status() {
  if [[ ! -f "$QCOW2_FILE" ]]; then
    echo missing; return 0
  fi
  local expected_mb=$((STORE_GB * 1024))
  local qemu_img
  if ! qemu_img=$(resolve_qemu_img); then
    echo "wrong-size:unknown:${expected_mb}"
    return 0
  fi
  # Use python3 (always present on macOS) to parse the JSON safely
  # rather than awk, which mishandles compact JSON (codex/gemini P1).
  # Falls back to awk if python3 is also unavailable.
  local actual_bytes actual_mb
  if command -v python3 &>/dev/null; then
    actual_bytes=$("$qemu_img" info --force-share --output=json "$QCOW2_FILE" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("virtual-size",0))' 2>/dev/null)
  else
    actual_bytes=$("$qemu_img" info --force-share --output=json "$QCOW2_FILE" 2>/dev/null \
      | awk -F'[ ,:]+' '/"virtual-size"/ { gsub(/[^0-9]/, "", $3); print $3; exit }')
  fi
  if [[ -z "$actual_bytes" || "$actual_bytes" == "0" ]]; then
    echo "wrong-size:unknown:${expected_mb}"
    return 0
  fi
  actual_mb=$(( actual_bytes / 1048576 ))
  if [[ "$actual_mb" -eq "$expected_mb" ]]; then
    echo ok
  else
    echo "wrong-size:${actual_mb}:${expected_mb}"
  fi
}

# Check whether start-builder.sh matches the config from config.yaml.
# Echoes "ok", "missing", or "wrong-<field>" naming the first mismatch.
#
# Checks STORE_GB (export line), QEMU_OPTS (cpus + memory), AND the
# embedded comments that record cpus/memory_gb/store_gb. If ANY field
# drifts, regen — otherwise a `cpus: 8 -> 16` config change ships a
# stale start-builder.sh and the operator gets the resource setting
# they didn't ask for.
start_script_status() {
  if [[ ! -f "$START_SCRIPT" ]]; then
    echo missing; return 0
  fi
  # STORE_GB export (commit 8b89600 invariant)
  if ! grep -qF "export STORE_GB=${STORE_GB}" "$START_SCRIPT"; then
    echo wrong-store-gb-export; return 0
  fi
  # QEMU_OPTS (cpus + memory) — write_start_script always emits this
  # line; if config changes, the literal contents must change too.
  local expected_qemu="-smp ${CPUS} -m ${MEMORY_MB}"
  if ! grep -qF -- "$expected_qemu" "$START_SCRIPT"; then
    echo wrong-qemu-opts; return 0
  fi
  # Builder nixpkgs ref (#564). A launcher generated before the pin landed
  # still resolves the bare `nixpkgs#darwin.linux-builder`, which throws on
  # x86_64-darwin. Without this check the launcher looks "ok" on every other
  # axis and is never regenerated, so the pin would silently never apply.
  # -x (whole-line) so a comment or a suffixed line mentioning the ref cannot
  # make a stale launcher look current.
  if ! grep -qxF "export BUILDER_NIXPKGS=\"${BUILDER_NIXPKGS}\"" "$START_SCRIPT"; then
    echo wrong-nixpkgs-ref; return 0
  fi
  echo ok
}

# Check whether run-nixos-vm-patched has the expected DISK_MB line.
# Echoes "ok", "missing", or "wrong-size".
patched_vm_status() {
  if [[ ! -f "$PATCHED_VM_FILE" ]]; then
    echo missing; return 0
  fi
  local expected_mb=$((STORE_GB * 1024))
  if grep -qF "createEmptyFilesystemImage \"\$NIX_DISK_IMAGE\" \"${expected_mb}M\"" \
       "$PATCHED_VM_FILE"; then
    echo ok
  else
    echo wrong-size
  fi
}

# Idempotent stop: kill all matching VM processes, leave it alone if none.
# Does not error if there's nothing to stop.
#
# pgrep pattern is anchored to BUILDER_DIR (~/.nix-builder/) so a separate
# nixos.qcow2 from an unrelated project isn't accidentally killed. We kill
# ALL matching PIDs (not just head -1) because the loop's wait condition is
# "any matching process exists"; killing only the first PID and waiting on
# all of them would deadlock for the full timeout.
ensure_builder_stopped() {
  local pids pid
  pids=$(pgrep -f "qemu.*${BUILDER_DIR}/nixos.qcow2" 2>/dev/null || true)
  if [[ -z "$pids" ]]; then
    return 0
  fi
  echo "  Stopping builder VM (pids: $(echo "$pids" | tr '\n' ' ')) for re-converge..."
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  local waited=0
  while pids=$(pgrep -f "qemu.*${BUILDER_DIR}/nixos.qcow2" 2>/dev/null) && [[ -n "$pids" ]]; do
    if (( waited >= 15 )); then
      for pid in $pids; do
        kill -9 "$pid" 2>/dev/null || true
      done
      sleep 1
      break
    fi
    sleep 1
    (( waited++ ))
  done
  # Also stop the launchd-managed launcher if nix-darwin is the one running it.
  # stop_builder_vm() handles this path and is idempotent.
  if command -v launchctl &>/dev/null; then
    sudo launchctl bootout system/org.nixos.linux-builder 2>/dev/null || true
  fi
}

# Delete the qcow2 and store.img. Build artifacts only — qcow2 has no
# precious state (the writable nix store overlay rebuilds from cache).
purge_builder_disks() {
  rm -f "$QCOW2_FILE" "$STORE_IMG_FILE" "$PATCHED_VM_FILE"
}

# Re-launch the builder and wait until it accepts SSH on BUILDER_PORT.
# Returns 0 if the VM comes up, 1 if it times out.
start_and_wait() {
  if [[ ! -x "$START_SCRIPT" ]]; then
    echo "  ERROR: ${START_SCRIPT} missing or not executable" >&2
    return 1
  fi
  bash "$START_SCRIPT"
  local attempts=0
  while (( attempts < 60 )); do
    if nc -z localhost "$BUILDER_PORT" 2>/dev/null; then
      return 0
    fi
    (( attempts++ ))
    sleep 2
  done
  echo "  ERROR: builder VM did not come up on port ${BUILDER_PORT} after 120s" >&2
  echo "  Check ${BUILDER_DIR}/builder.log" >&2
  return 1
}

# Converge the linux-builder to the state declared in config.yaml.
# Idempotent: calling this on an already-correct setup is a no-op
# (other than two grep checks). Called by the default path, --start,
# and --verify on macOS linux-builder.
#
# Returns 0 if the builder is correctly configured and running.
# Returns non-zero if convergence failed; prints diagnostics on stderr.
converge_builder() {
  [[ "$BUILDER_TYPE" == "linux-builder" && "$OS_TYPE" == "Darwin" ]] || return 0
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "  [DRY RUN] Would converge builder to (store_gb=${STORE_GB})"
    return 0
  fi

  mkdir -p "$BUILDER_DIR"

  local launcher_state qcow2_state vm_running need_regen=0 need_purge=0

  launcher_state=$(start_script_status)
  qcow2_state=$(qcow2_size_status)
  if pgrep -f "qemu.*nixos.qcow2" >/dev/null 2>&1 && \
     nc -z localhost "$BUILDER_PORT" 2>/dev/null; then
    vm_running=1
  else
    vm_running=0
  fi

  case "$launcher_state" in
    ok)
      echo "  ✓ start-builder.sh matches config (cpus=${CPUS}, memory=${MEMORY_GB}GB, store_gb=${STORE_GB})"
      ;;
    missing)
      echo "  ! start-builder.sh missing — regenerating"
      need_regen=1
      ;;
    wrong-store-gb-export)
      echo "  ! start-builder.sh missing/stale 'export STORE_GB=${STORE_GB}' — regenerating"
      need_regen=1
      ;;
    wrong-qemu-opts)
      echo "  ! start-builder.sh has stale QEMU_OPTS (expected: -smp ${CPUS} -m ${MEMORY_MB}) — regenerating"
      need_regen=1
      ;;
    wrong-nixpkgs-ref)
      echo "  ! start-builder.sh has a stale/unpinned builder nixpkgs ref (expected: ${BUILDER_NIXPKGS}) — regenerating"
      need_regen=1
      ;;
  esac

  case "$qcow2_state" in
    ok)
      echo "  ✓ nixos.qcow2 virtual size matches config (${STORE_GB} GiB)"
      ;;
    missing)
      # No qcow2 yet. Launcher will create it at the right size on first
      # boot — provided the launcher itself is correct.
      :
      ;;
    wrong-size:unknown:*)
      # qemu-img couldn't be resolved (not on PATH, not in /nix/store, no
      # net for nix shell). Treat as drift — purge and let the launcher
      # recreate at the correct size. Cost is bounded: rebuild from cache.
      local expected_mb
      expected_mb=$(echo "$qcow2_state" | cut -d: -f3)
      echo "  ! qemu-img unavailable — cannot verify nixos.qcow2 size; purging conservatively"
      echo "    (expected ${expected_mb} MB; will recreate)"
      need_purge=1
      need_regen=1
      ;;
    wrong-size:*)
      local actual_mb expected_mb
      actual_mb=$(echo "$qcow2_state" | cut -d: -f2)
      expected_mb=$(echo "$qcow2_state" | cut -d: -f3)
      echo "  ! nixos.qcow2 size mismatch: actual=${actual_mb} MB, expected=${expected_mb} MB"
      echo "    Will stop VM, purge build disks, regenerate launcher, restart."
      need_purge=1
      need_regen=1
      ;;
  esac

  if (( need_regen )) || (( need_purge )); then
    ensure_builder_stopped
    if (( need_purge )); then
      purge_builder_disks
      echo "  ✓ removed stale nixos.qcow2 / store.img / run-nixos-vm-patched"
    fi
    write_start_script
    vm_running=0
  fi

  if (( vm_running == 0 )); then
    echo "  Starting builder VM..."
    if ! start_and_wait; then
      return 1
    fi
    echo "  ✓ builder VM is up"
  fi

  # Postcondition check #2: the line that the launcher wrote at boot
  # has the configured DISK_MB. (Only verifiable after start_and_wait
  # because the launcher creates run-nixos-vm-patched at boot time.)
  #
  # On stale patched-vm we regen-and-retry once (the file could be left
  # over from a previous run with the wrong size, even though the
  # launcher we just wrote is correct). If retry also produces the
  # wrong size, upstream really has changed the line shape and the
  # operator needs to update setup-nix-builder.sh.
  local pvm_state
  pvm_state=$(patched_vm_status)
  if [[ "$pvm_state" == "wrong-size" ]] || [[ "$pvm_state" == "missing" ]]; then
    echo "  ! run-nixos-vm-patched is ${pvm_state}; stopping VM, removing it, restarting once."
    ensure_builder_stopped
    rm -f "$PATCHED_VM_FILE"
    if ! start_and_wait; then
      return 1
    fi
    pvm_state=$(patched_vm_status)
  fi
  case "$pvm_state" in
    ok)
      echo "  ✓ run-nixos-vm-patched declares disk size $((STORE_GB * 1024))M"
      ;;
    missing)
      echo "  ! run-nixos-vm-patched not found after restart — the launcher did not produce it" >&2
      echo "    This usually means start-builder.sh failed silently. See ${BUILDER_DIR}/builder.log" >&2
      return 1
      ;;
    wrong-size)
      echo "  ! run-nixos-vm-patched does NOT declare the configured disk size after retry" >&2
      echo "    Expected line: createEmptyFilesystemImage \"\$NIX_DISK_IMAGE\" \"$((STORE_GB * 1024))M\"" >&2
      echo "    Actual:" >&2
      grep -n 'createEmptyFilesystemImage' "$PATCHED_VM_FILE" >&2 || true
      echo "    Upstream nixpkgs has likely changed run-nixos-vm's line shape;" >&2
      echo "    update the sed pattern in setup-nix-builder.sh's write_start_script." >&2
      return 1
      ;;
  esac

  # Postcondition #3: post-start qcow2 size now matches.
  # qcow2_size_status never emits a bare 'unknown' — an unverifiable qcow2
  # (qemu-img missing or resolvable-but-unusable) becomes
  # 'wrong-size:unknown:<expected>'. Match that specific pattern before the
  # generic 'wrong-size:*' arm; the old 'ok|unknown) : ;;' arm was dead
  # (see #567) and its unintended consequence was routing unverifiable
  # qcow2s into the "size is still wrong post-start" failure below with a
  # misleading message. Treat unverifiable as pass-through: re-running
  # converge without qemu-img cannot change the answer.
  qcow2_state=$(qcow2_size_status)
  case "$qcow2_state" in
    ok|wrong-size:unknown:*) : ;;
    missing)
      echo "  ! nixos.qcow2 still missing post-start — start-builder.sh did not create the disk" >&2
      return 1
      ;;
    wrong-size:*)
      echo "  ! nixos.qcow2 size is still wrong post-start: ${qcow2_state}" >&2
      echo "    The launcher may have a corrupt sed pattern; check ${PATCHED_VM_FILE}." >&2
      return 1
      ;;
  esac

  return 0
}

# --- Common helpers ---

# Wrap `echo <content> | sudo tee <dest>` so a failed write surfaces
# non-zero to the caller. Under `set -uo pipefail` (this file's mode —
# note: no -e), an unchecked pipe silently succeeds even when tee
# fails, leaving /etc/nix in a broken state and this script reporting
# success. #413.
#
# Usage:
#   sudo_tee_write "<content>" "<dest>"      # overwrite dest
#   sudo_tee_append "<content>" "<dest>"     # append to dest
#
# Content is emitted verbatim followed by a single newline. Multi-line
# content works fine (embed `\n` in the string), but heredoc call sites
# use an inline `if !` wrapper instead for source-readability, not
# because the helper cannot handle multi-line content.
sudo_tee_write() {
  local content="$1" dest="$2"
  if ! printf '%s\n' "$content" | sudo tee "$dest" > /dev/null; then
    echo "  ERROR: failed to write ${dest} via sudo tee" >&2
    return 1
  fi
}

sudo_tee_append() {
  local content="$1" dest="$2"
  if ! printf '%s\n' "$content" | sudo tee -a "$dest" > /dev/null; then
    echo "  ERROR: failed to append to ${dest} via sudo tee" >&2
    return 1
  fi
}

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
  sudo_tee_append "$needed" "$NIX_CONF" || return 1

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
  # Use the pinned nix_builder.nixpkgs_ref, not the impure `<nixpkgs>` channel
  # or a bare `nixpkgs#` ref. Both float on the global registry (nixpkgs-unstable)
  # and were the failure class behind #564 — the ratchet in
  # tests/test_setup_nix_builder_patching.sh did not cover this probe. #566.
  if nix build "${BUILDER_NIXPKGS}#hello" --system x86_64-linux --no-link 2>&1; then
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
  ensure_experimental_features || return 1

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
  ensure_experimental_features || return 1

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
  sudo_tee_write "$expected_line" "$MACHINES_FILE" || return 1
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

  cat > "$START_SCRIPT" <<'STARTEOF'
#!/bin/bash
# Generated by setup-nix-builder.sh — do not edit manually
STARTEOF
  cat >> "$START_SCRIPT" <<STARTEOF
# Resource settings from site/config.yaml (${timestamp})
#   cpus: ${CPUS}
#   memory_gb: ${MEMORY_GB} (${MEMORY_MB}MB)
#   store_gb: ${STORE_GB}
export TMPDIR=~/.nix-builder
export USE_TMPDIR=1
export QEMU_OPTS="-smp ${CPUS} -m ${MEMORY_MB}"
# Pass the configured store_gb through to the run-nixos-vm patching block
# below. That block lives in a single-quoted heredoc (variables not expanded
# at generation time), so it reads STORE_GB from this environment at boot.
export STORE_GB=${STORE_GB}
# Same mechanism for the builder's nixpkgs ref: the resolution below lives in
# the single-quoted heredoc and reads this at boot. Pinned, never 'nixpkgs#'
# (an indirect ref floats on unstable, which dropped x86_64-darwin — #564).
export BUILDER_NIXPKGS="${BUILDER_NIXPKGS}"
STARTEOF
  cat >> "$START_SCRIPT" <<'STARTEOF'

# Source nix profile to get nix on PATH (needed for non-interactive shells)
for p in /nix/var/nix/profiles/default/bin "$HOME/.nix-profile/bin"; do
  [[ -d "$p" ]] && export PATH="$p:$PATH"
done

# Ensure certs directory is writable. run-nixos-vm copies the SSL cert
# file here on every start. If a previous run left it read-only, the
# copy fails and the builder can't start.
mkdir -p ~/.nix-builder/certs
chmod 755 ~/.nix-builder/certs
chmod 644 ~/.nix-builder/certs/ca-certificates.crt 2>/dev/null || true

# Resolve the linux-builder derivation and extract script paths.
# stderr is deliberately NOT suppressed: the upstream nixpkgs error is
# self-explanatory (it names the platform it dropped), and swallowing it is
# what made #564 masquerade as the generic disk-full failure class.
: "${BUILDER_NIXPKGS:?BUILDER_NIXPKGS not set — regenerate this script with setup-nix-builder.sh}"
BUILDER_DRV=$(nix build "${BUILDER_NIXPKGS}#darwin.linux-builder" --no-link --print-out-paths | head -1)
if [[ -z "$BUILDER_DRV" ]]; then
  echo "ERROR: Failed to resolve ${BUILDER_NIXPKGS}#darwin.linux-builder" >&2
  exit 1
fi
CREATE_SCRIPT="${BUILDER_DRV}/bin/create-builder"
ADD_KEYS=$(grep -o '/nix/store/[^ ]*add-keys/bin/add-keys' "$CREATE_SCRIPT" | head -1)
RUN_BUILDER=$(grep -o '/nix/store/[^ ]*run-builder/bin/run-builder' "$CREATE_SCRIPT" | head -1)
RUN_VM=$(grep -o '/nix/store/[^ ]*run-nixos-vm' "$RUN_BUILDER" | head -1)

# Pin disk image to ~/.nix-builder/ so it doesn't land in CWD.
export NIX_DISK_IMAGE=~/.nix-builder/nixos.qcow2

# Patch run-nixos-vm to use the configured disk size instead of the
# upstream default. The builder's writable disk accumulates build
# outputs; the upstream default (historically 20GB, currently 40GB)
# fills after a handful of images on a cold host store.
#
# Match by line context, not by literal size, because the upstream
# default has changed at least once (20480M -> 40960M) and a literal-
# only match silently no-ops when upstream changes, leaving the operator
# with whatever upstream ships. Verify the substitution afterwards and
# fail loudly if it didn't take.
PATCHED_VM=~/.nix-builder/run-nixos-vm-patched
if [[ -x "$RUN_VM" ]]; then
  rm -f "$PATCHED_VM"
  cp "$RUN_VM" "$PATCHED_VM"
  DISK_MB=$(( ${STORE_GB:-40} * 1024 ))
  sed -i '' -E "s/(createEmptyFilesystemImage \"\\\$NIX_DISK_IMAGE\" \")[0-9]+M/\\1${DISK_MB}M/" "$PATCHED_VM"
  if ! grep -qF "createEmptyFilesystemImage \"\$NIX_DISK_IMAGE\" \"${DISK_MB}M\"" "$PATCHED_VM"; then
    echo "ERROR: failed to patch builder VM disk size in ${PATCHED_VM}" >&2
    echo "  Expected to find: createEmptyFilesystemImage \"\$NIX_DISK_IMAGE\" \"${DISK_MB}M\"" >&2
    echo "  Actual createEmptyFilesystemImage line(s):" >&2
    grep -n 'createEmptyFilesystemImage' "$PATCHED_VM" >&2 || echo "    (no createEmptyFilesystemImage line found)" >&2
    echo "  The upstream run-nixos-vm script likely changed; update the sed" >&2
    echo "  pattern in framework/scripts/setup-nix-builder.sh to match the new line shape." >&2
    exit 1
  fi
  chmod +x "$PATCHED_VM"
fi

# Create a patched run-builder that uses our patched run-nixos-vm.
PATCHED_BUILDER=~/.nix-builder/run-builder-patched
rm -f "$PATCHED_BUILDER"
cp "$RUN_BUILDER" "$PATCHED_BUILDER"
sed -i '' "s|$RUN_VM|$PATCHED_VM|" "$PATCHED_BUILDER"
chmod +x "$PATCHED_BUILDER"

# Run add-keys (checks for existing keys, skips sudo if they match
# /etc/nix/) then start the patched builder. This is the same sequence
# as create-builder but with the patched run-builder.
export KEYS=~/.nix-builder/keys
cd ~/.nix-builder
"$ADD_KEYS"
"$PATCHED_BUILDER" >> ~/.nix-builder/builder.log 2>&1 &
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
      return 0
    fi
    (( attempts++ ))
    sleep 2
  done

  echo "  ✗ Timed out waiting for linux-builder VM (120s)"
  echo "  Check ${BUILDER_DIR}/builder.log for errors"
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
  ensure_experimental_features || return 1

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
  echo ""
  echo "--- Convergence ---"

  # converge_builder is idempotent: it regenerates start-builder.sh if it
  # is missing or stale relative to config.yaml, deletes the qcow2 if its
  # virtual size doesn't match the configured store_gb, ensures the VM
  # is running, and self-verifies the post-start invariants.
  write_machines_file || return 1
  if ! converge_builder; then
    return 1
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo ""
    echo "  [DRY RUN] Would verify a test build of x86_64-linux derivation"
    return 0
  fi

  # converge_builder already started the VM; verify it accepts builds.
  if test_linux_build; then
    return 0
  fi

  echo ""
  echo "  Builder VM is running but test build failed. Diagnostics:"
  echo "    nc -z localhost ${BUILDER_PORT}"
  echo "    cat ${BUILDER_DIR}/builder.log"
  echo ""
  echo "  If this is a first-time bringup, ensure nix-darwin has linux-builder enabled:"
  echo "    nix.linux-builder = {"
  echo "      enable = true;"
  echo "      maxJobs = ${CPUS};"
  echo "    };"
  echo "  then run darwin-rebuild switch and re-run this script."
  return 1
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
      # Heredoc site — cannot use sudo_tee_write helper (multi-line
      # content). Wrap the pipe directly so a failed tee returns
      # non-zero per #413.
      if ! cat <<'SSHEOF' | sudo tee "$BUILDER_SSH_CONFIG" > /dev/null
Host linux-builder
  Hostname localhost
  HostKeyAlias linux-builder
  Port 31022
  User builder
  IdentityFile /etc/nix/builder_ed25519
  StrictHostKeyChecking no
SSHEOF
      then
        echo "  ERROR: failed to write ${BUILDER_SSH_CONFIG} via sudo tee" >&2
        return 1
      fi
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
  # converge_builder runs write_start_script internally and only when
  # regen is needed; call write_machines_file unconditionally because it
  # affects /etc/nix/machines, which sits outside the BUILDER_DIR scope
  # that converge_builder owns.
  write_machines_file || return 1

  local need_nix_conf=0
  if [[ ! -f "$NIX_CONF" ]] || ! grep -qF "builders = @/etc/nix/machines" "$NIX_CONF" 2>/dev/null; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  [DRY RUN] Would add builders directive to ${NIX_CONF}"
    else
      sudo_tee_append "builders = @/etc/nix/machines" "$NIX_CONF" || return 1
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
      sudo_tee_append "builders-use-substitutes = true" "$NIX_CONF" || return 1
      echo "  ✓ ${NIX_CONF}: builders-use-substitutes"
      need_nix_conf=1
    fi
  else
    echo "  ✓ ${NIX_CONF}: builders-use-substitutes (already present)"
  fi

  # --- Step 3: Converge the linux-builder VM ---
  echo ""
  echo "--- linux-builder VM ---"

  # converge_builder regenerates start-builder.sh as needed (which
  # includes the SSH-key install via add-keys), stops the VM and purges
  # disks if the qcow2 has the wrong size, and starts the VM. Idempotent.
  if ! converge_builder; then
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
    echo "  Resources: ${CPUS} CPUs, ${MEMORY_GB}GB RAM, ${STORE_GB}GB disk"
    echo ""
    echo "  Re-run this script any time. It converges to the configured state."
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
  ensure_experimental_features || return 1

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

  # Check start-builder.sh matches config. Without the STORE_GB export, the
  # patching block at boot defaults DISK_MB to 40960 regardless of config
  # (see commit 8b89600). Without the pinned nixpkgs ref, the launcher
  # resolves the builder through the floating registry and throws (#564).
  #
  # The drift arm matches every wrong-* state: an arm that enumerates states
  # by name silently passes any state added later (the dead 'wrong-export'
  # label this replaces never matched anything, so a stale launcher reported
  # clean here).
  case "$(start_script_status)" in
    ok) echo "  ✓ ${START_SCRIPT} matches config (STORE_GB=${STORE_GB}, nixpkgs_ref=${BUILDER_NIXPKGS})" ;;
    missing|wrong-*)
      echo "  ✗ ${START_SCRIPT} is missing or does not match config"
      echo "    Re-run setup-nix-builder.sh (no flags) to regenerate"
      (( errors++ ))
      ;;
  esac

  # Check the patched run-nixos-vm has the configured disk size.
  case "$(patched_vm_status)" in
    ok) echo "  ✓ ${PATCHED_VM_FILE} declares disk size $((STORE_GB * 1024))M" ;;
    missing)
      echo "  ! ${PATCHED_VM_FILE} not present (will be created on next start)"
      ;;
    wrong-size)
      echo "  ✗ ${PATCHED_VM_FILE} declares wrong disk size"
      echo "    Re-run setup-nix-builder.sh to regenerate"
      (( errors++ ))
      ;;
  esac

  # Check the qcow2 virtual size matches config.
  case "$(qcow2_size_status)" in
    ok) echo "  ✓ ${QCOW2_FILE} virtual size matches config (${STORE_GB} GiB)" ;;
    missing)
      echo "  ! ${QCOW2_FILE} not present (will be created on next start)"
      ;;
    wrong-size:unknown:*)
      # qcow2_size_status emits 'wrong-size:unknown:<expected>' when qemu-img
      # cannot resolve; the old bare-'unknown' arm was dead (#567) and the
      # unverifiable state fell into wrong-size:* below with the misleading
      # "virtual size does not match config" — exactly the situation where the
      # operator is already debugging.
      echo "  ! qemu-img not on PATH or not runnable — skipping qcow2 size check"
      ;;
    wrong-size:*)
      echo "  ✗ ${QCOW2_FILE} virtual size does not match config"
      echo "    Re-run setup-nix-builder.sh to converge"
      (( errors++ ))
      ;;
  esac

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
  ensure_experimental_features || return 1

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
      sudo_tee_append "$builder_line" "$MACHINES_FILE" || return 1
      echo "  ✓ Added ${REMOTE_HOST} to ${MACHINES_FILE}"
      need_restart=1
    fi
  fi

  if [[ ! -f "$NIX_CONF" ]] || ! grep -qF "builders = @/etc/nix/machines" "$NIX_CONF" 2>/dev/null; then
    sudo_tee_append "builders = @/etc/nix/machines" "$NIX_CONF" || return 1
    echo "  ✓ ${NIX_CONF}: builders directive"
    need_restart=1
  else
    echo "  ✓ ${NIX_CONF}: builders directive (already present)"
  fi

  if [[ ! -f "$NIX_CONF" ]] || ! grep -qF "builders-use-substitutes = true" "$NIX_CONF" 2>/dev/null; then
    sudo_tee_append "builders-use-substitutes = true" "$NIX_CONF" || return 1
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
  ensure_experimental_features || return 1

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
# Converge first: if the launcher is stale, the qcow2 is the wrong size,
# or the VM isn't running, converge_builder fixes that before returning.
# A correctly-configured running builder is a no-op for converge_builder.
if [[ $START_ONLY -eq 1 ]]; then
  if [[ "$BUILDER_TYPE" != "linux-builder" ]]; then
    echo "ERROR: --start only applies to linux-builder type" >&2
    exit 1
  fi
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    converge_builder
    exit $?
  fi
  start_builder_vm
  exit $?
fi

# --- Verify mode ---
# Same convergence as --start. Verification that the builder matches
# config is meaningless if the script will accept stale state — so we
# converge to "correct and running" first, then run the deeper test
# build that verify_linux_builder performs.
if [[ $VERIFY_ONLY -eq 1 ]]; then
  case "$BUILDER_TYPE" in
    local)          verify_local ;;
    linux-builder)
      if [[ "$OS_TYPE" == "Darwin" ]]; then
        converge_builder || exit $?
      fi
      verify_linux_builder
      ;;
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
