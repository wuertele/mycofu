#!/usr/bin/env bash
# configure-node-kernel.sh -- Apply NVMe-firmware-quirk kernel parameters to
# Proxmox host nodes, supporting both GRUB and systemd-boot bootloaders.
#
# Usage:
#   configure-node-kernel.sh <node-name>
#   configure-node-kernel.sh --all
#   configure-node-kernel.sh --verify [<node-name>|--all]
#   configure-node-kernel.sh --dry-run [<node-name>|--all]
#
# Why this exists:
#   On 2026-05-03, pve02's NVMe controller hit a power-state firmware bug
#   (D3cold->D0 transition failed, ZFS pool suspended, 8 VMs zombified).
#   The kernel itself printed the workaround:
#     "Try nvme_core.default_ps_max_latency_us=0 pcie_aspm=off pcie_port_pm=off"
#   This script applies that workaround persistently. See
#   docs/reports/2026-05-03-pve02-storage-failure-and-ha-recovery-retrospective.md
#   for the full incident analysis.
#
# Mechanism:
#   Detects the active bootloader on each node from `efibootmgr -v` (the
#   ground truth: the active EFI variable points at either grubx64/shimx64
#   or systemd-bootx64), with a `proxmox-boot-tool status` fallback for
#   legacy installs and a final BIOS-GRUB fallback.
#
#   Then writes the kernel parameters to the appropriate persistent
#   location and refreshes the bootloader config:
#
#     - GRUB (BIOS or UEFI): writes a drop-in cfg file to
#       /etc/default/grub.d/99-mycofu-nvme-quirk.cfg and runs `update-grub`.
#       (For UEFI ZFS+SecureBoot installs that use GRUB through
#       proxmox-boot-tool, `update-grub` regenerates the GRUB config and
#       proxmox-boot-tool's hooks propagate it to the configured ESPs.)
#     - systemd-boot (UEFI ZFS-on-root, no Secure Boot): adds the params
#       to /etc/kernel/cmdline (idempotent -- only adds tokens not already
#       present) and runs `proxmox-boot-tool refresh` to propagate to all
#       configured ESPs. proxmox-boot-tool mounts the ESPs in its own
#       private mount namespace, so we trust its exit code rather than
#       inspecting /boot/efi directly.
#
#   The kernel parameters do NOT take effect until reboot. This script
#   does NOT reboot the node -- that is an operator decision (rolling
#   reboot must be coordinated using the standard Proxmox maintenance
#   procedure: evacuate VMs, reboot, verify rejoin, rebalance, repeat;
#   see OPERATIONS.md "Applying Kernel Parameters").
#
# Closing the round-1 false-success retry loop:
#   In apply mode, the script ALWAYS runs the bootloader refresh (even
#   when the persistent config already matches). update-grub and
#   proxmox-boot-tool refresh are both idempotent and cheap; running
#   them every time eliminates the failure mode where a previous run
#   wrote persistent config but failed at refresh, leaving boot config
#   stale, and a second run skipped refresh and reported "just reboot"
#   when rebooting would not have helped.
#
# Exit codes:
#   0  success -- params already applied AND effective in /proc/cmdline
#   1  one or more nodes failed (SSH error, refresh error, etc.)
#   2  usage / config error
#   10 reboot required -- params written and propagated to boot config,
#      but not yet effective on this node's running kernel

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_PATH="${REPO_DIR}/site/config.yaml"
DRY_RUN=0
VERIFY_ONLY=0
TARGET_NODE=""
ALL_NODES=0

# The kernel parameters to add. Order is irrelevant; the kernel parses each
# independently. Each parameter and its rationale:
#
#   nvme_core.default_ps_max_latency_us=0
#     Disables NVMe APST (Autonomous Power State Transitions). Drives that
#     advertise low-latency power states they cannot actually exit cleanly
#     get stuck. Setting max-latency to 0 forbids the kernel from selecting
#     any non-active power state. Cost: ~0.5W extra idle power per drive.
#
#   pcie_aspm=off
#     Disables PCIe Active State Power Management cluster-wide. ASPM lets
#     PCIe links idle into L1/L1.1/L1.2 states; some NVMe controllers
#     (notably consumer Lexar/Crucial drives with certain firmware) latch
#     in deep states and require a hardware reset to recover. Cost: ~1-2W
#     extra idle power per active PCIe link.
#
#   pcie_port_pm=off
#     Disables runtime power management of PCIe ports. Belt-and-braces
#     pairing with pcie_aspm=off; some PCIe root complexes will independently
#     idle ports even with ASPM disabled. Cost: negligible.
KERNEL_PARAMS=(
  "nvme_core.default_ps_max_latency_us=0"
  "pcie_aspm=off"
  "pcie_port_pm=off"
)
KERNEL_PARAMS_STR="${KERNEL_PARAMS[*]}"

GRUB_DROPIN_PATH="/etc/default/grub.d/99-mycofu-nvme-quirk.cfg"
GRUB_DROPIN_CONTENT="# Managed by framework/scripts/configure-node-kernel.sh -- do not edit by hand.
# NVMe firmware power-state quirk workaround. See:
#   docs/reports/2026-05-03-pve02-storage-failure-and-ha-recovery-retrospective.md
GRUB_CMDLINE_LINUX=\"\${GRUB_CMDLINE_LINUX:-} ${KERNEL_PARAMS_STR}\""

SDBOOT_CMDLINE_PATH="/etc/kernel/cmdline"

EXIT_REBOOT_NEEDED=10

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || { echo "ERROR: --config requires a path argument" >&2; exit 2; }
      CONFIG_PATH="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --verify)   VERIFY_ONLY=1; shift ;;
    --all)      ALL_NODES=1; shift ;;
    -h|--help)
      # Skip the shebang on line 1 so output doesn't start with "!/usr/bin/env bash".
      sed -n '2,55p' "$0" | sed 's|^# ||;s|^#||'
      exit 0
      ;;
    -*) echo "ERROR: Unknown option: $1" >&2; exit 2 ;;
    *)
      [[ -n "$TARGET_NODE" ]] && { echo "ERROR: multiple node names: $TARGET_NODE $1" >&2; exit 2; }
      TARGET_NODE="$1"; shift
      ;;
  esac
done

if [[ $ALL_NODES -eq 1 && -n "$TARGET_NODE" ]]; then
  echo "ERROR: --all and a node name are mutually exclusive" >&2
  exit 2
fi

if [[ $DRY_RUN -eq 1 && $VERIFY_ONLY -eq 1 ]]; then
  echo "ERROR: --dry-run and --verify are mutually exclusive (--verify is already non-mutating)" >&2
  exit 2
fi

if [[ $ALL_NODES -eq 0 && -z "$TARGET_NODE" ]]; then
  echo "Usage: $(basename "$0") [--dry-run] [--verify] [--config path] <node-name|--all>" >&2
  exit 2
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_PATH}" >&2
  exit 2
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq is required but not installed" >&2
  exit 2
fi

if ! command -v base64 &>/dev/null; then
  echo "ERROR: base64 is required but not installed" >&2
  exit 2
fi

# --- Build node list ---
# Explicit `=()` initialization is required: under `set -u`, bash <= 4.3
# treats `declare -a` without an assignment as unbound, and `${#NODE_NAMES[@]}`
# below errors out before the empty-list check fires (observed on cicd).
NODE_NAMES=()
NODE_IPS=()
if [[ $ALL_NODES -eq 1 ]]; then
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    NODE_NAMES+=("${entry%%=*}")
    NODE_IPS+=("${entry#*=}")
  done < <(yq -r '.nodes[] | .name + "=" + .mgmt_ip' "$CONFIG_PATH")
  if [[ ${#NODE_NAMES[@]} -eq 0 ]]; then
    echo "ERROR: --all selected but no nodes found in ${CONFIG_PATH}" >&2
    exit 2
  fi
else
  ip="$(NODE="$TARGET_NODE" yq -r '.nodes[] | select(.name == strenv(NODE)) | .mgmt_ip' "$CONFIG_PATH")"
  if [[ -z "$ip" || "$ip" == "null" ]]; then
    echo "ERROR: node '${TARGET_NODE}' not found in ${CONFIG_PATH}" >&2
    exit 2
  fi
  NODE_NAMES+=("$TARGET_NODE")
  NODE_IPS+=("$ip")
fi

# --- SSH helper (always uses -n per .claude/rules/ssh.md) ---
ssh_node() {
  local ip="$1"; shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@"
}

# --- Remote operations bash blob ---
#
# The same blob handles detection + verify + apply, dispatched by the MODE
# substitution.
#
# Output protocol: a series of "key=value" lines on stdout, terminated by a
# "STATUS=<code>" line. STATUS codes:
#   STATUS=ok              params present in /proc/cmdline AND persistent
#                          config is correct (no work needed; no reboot needed)
#   STATUS=reboot          persistent config correct, /proc/cmdline stale
#                          (verify mode only -- apply mode would fix it)
#   STATUS=missing         persistent config absent or stale (verify mode)
#   STATUS=applied         this run wrote/refreshed persistent config and
#                          the running kernel still lacks the params
#                          (caller treats as reboot-required, exit 10)
#   STATUS=error_<reason>  failure with diagnostic
#
# Other lines surface diagnostics for the operator (BOOTLOADER=, persistent
# config state, refresh outcome, etc.).
#
# CONTENT INJECTION SAFETY:
#   The drop-in content and other bytes are passed in as base64-encoded
#   environment variables, then decoded inside the remote blob. This avoids
#   the failure mode where a future change to GRUB_DROPIN_CONTENT introduces
#   characters (single quotes, backslashes) that would break a string
#   substitution into a quoted bash literal.
remote_blob() {
  cat <<'REMOTE'
set -euo pipefail
mode="__MODE__"

# --- Decode injected literals (base64 from local invocation) ---
PARAMS="$(printf '%s' "$MYCOFU_PARAMS_B64" | base64 -d)"
GRUB_DROPIN_PATH="$(printf '%s' "$MYCOFU_GRUB_DROPIN_PATH_B64" | base64 -d)"
GRUB_DROPIN_CONTENT="$(printf '%s' "$MYCOFU_GRUB_DROPIN_CONTENT_B64" | base64 -d)"
SDBOOT_CMDLINE_PATH="/etc/kernel/cmdline"

# --- Bootloader detection ---
# Ground truth: the active EFI Boot#### variable's loader path. shim or
# grubx64 means GRUB; systemd-bootx64 means systemd-boot. If efibootmgr
# isn't present (e.g., container, BIOS), fall back to proxmox-boot-tool
# status's per-ESP "configured with:" line. Final fallback for non-PVE
# boxes is BIOS GRUB.
detect_bootloader() {
  local active_loader=""
  if command -v efibootmgr >/dev/null 2>&1 && [ -d /sys/firmware/efi ]; then
    # efibootmgr -v output format includes lines like:
    #   Boot0001* proxmox HD(...)/File(\EFI\proxmox\shimx64.efi)
    #   Boot0002* Linux Boot Manager HD(...)/File(\EFI\systemd\systemd-bootx64.efi)
    # We want the entry whose number matches BootCurrent.
    local current
    current="$(efibootmgr 2>/dev/null | awk '/^BootCurrent:/ {print $2}')"
    if [ -n "$current" ]; then
      active_loader="$(efibootmgr -v 2>/dev/null \
                       | awk -v cur="$current" '$0 ~ "^Boot" cur "[* ]" { print; exit }')"
    fi
  fi
  # Tighten case patterns to actual EFI loader filenames. Bash case is
  # case-sensitive; Proxmox installs use lowercase by convention but
  # operators with manually-maintained EFI entries might not, so accept
  # both. Avoid loose `*shim*`/`*grub*` patterns that would match
  # unrelated descriptions.
  shopt -s nocasematch
  case "$active_loader" in
    *systemd-bootx64.efi*|*systemd_boot*) shopt -u nocasematch; echo "systemd-boot"; return ;;
    *shimx64.efi*|*shimia32.efi*|*grubx64.efi*|*grubia32.efi*) shopt -u nocasematch; echo "grub"; return ;;
  esac
  shopt -u nocasematch

  # Fallback 1: proxmox-boot-tool's per-ESP "configured with:" line
  # (NOT the "System currently booted with uefi" header, which appears
  # on every UEFI host regardless of bootloader).
  #
  # If different ESPs disagree (one configured with uefi, another with
  # grub) we cannot safely pick a branch from a regex; fail closed by
  # falling through to the legacy heuristic. This is a deliberately
  # conservative choice: getting the bootloader wrong writes the
  # kernel params to a file the active bootloader doesn't read, which
  # would silently miss the workaround on next boot.
  if command -v proxmox-boot-tool >/dev/null 2>&1; then
    local pbt_status saw_uefi saw_grub
    pbt_status="$(proxmox-boot-tool status 2>/dev/null || echo '')"
    saw_uefi=0
    saw_grub=0
    printf '%s\n' "$pbt_status" \
      | grep -qE '[Cc]onfigured with:[[:space:]]*uefi' && saw_uefi=1
    printf '%s\n' "$pbt_status" \
      | grep -qE '[Cc]onfigured with:[[:space:]]*grub' && saw_grub=1
    if [ $saw_uefi -eq 1 ] && [ $saw_grub -eq 0 ]; then
      echo "systemd-boot"
      return
    fi
    if [ $saw_grub -eq 1 ] && [ $saw_uefi -eq 0 ]; then
      echo "grub"
      return
    fi
    # Mixed or absent -- fall through to the legacy heuristic.
  fi

  # Fallback 2: legacy heuristic. /etc/kernel/cmdline + /sys/firmware/efi
  # without a clear EFI loader path -> systemd-boot. Otherwise GRUB.
  if [ -d /sys/firmware/efi ] && [ -s "$SDBOOT_CMDLINE_PATH" ]; then
    echo "systemd-boot"
  else
    echo "grub"
  fi
}

BOOTLOADER="$(detect_bootloader)"
echo "BOOTLOADER=${BOOTLOADER}"

# --- /proc/cmdline tokenization (exact-token match, no substring false-positive) ---
# Linux accepts both spaces and tabs as cmdline separators; normalize tabs
# to spaces before tokenizing so a tab-separated cmdline (rare but legal)
# doesn't produce a false-negative.
runtime_has_all_params() {
  local cmdline param
  cmdline="$(cat /proc/cmdline 2>/dev/null || echo '')"
  cmdline="${cmdline//$'\t'/ }"
  for param in $PARAMS; do
    case " $cmdline " in
      *" $param "*) ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# --- Persistent config check ---
# Returns 0 if persistent config (drop-in or cmdline file) has all params.
persistent_has_all_params() {
  case "$BOOTLOADER" in
    grub)
      [ -f "$GRUB_DROPIN_PATH" ] || return 1
      local current
      current="$(cat "$GRUB_DROPIN_PATH" 2>/dev/null || echo '')"
      [ "$current" = "$GRUB_DROPIN_CONTENT" ]
      ;;
    systemd-boot)
      [ -s "$SDBOOT_CMDLINE_PATH" ] || return 1
      local cmdline param
      cmdline="$(cat "$SDBOOT_CMDLINE_PATH")"
      cmdline="${cmdline//$'\t'/ }"
      for param in $PARAMS; do
        case " $cmdline " in
          *" $param "*) ;;
          *) return 1 ;;
        esac
      done
      return 0
      ;;
  esac
}

# --- Write persistent config (idempotent: only writes if would change) ---
write_persistent() {
  case "$BOOTLOADER" in
    grub)
      mkdir -p /etc/default/grub.d
      local tmp
      tmp="$(mktemp)"
      printf '%s\n' "$GRUB_DROPIN_CONTENT" > "$tmp"
      install -m 0644 "$tmp" "$GRUB_DROPIN_PATH"
      rm -f "$tmp"
      ;;
    systemd-boot)
      # Append our params to existing cmdline if not already present.
      # Preserve everything already on the line; deduplicate per-token.
      local current new param
      current="$(cat "$SDBOOT_CMDLINE_PATH" 2>/dev/null || echo '')"
      new="$current"
      for param in $PARAMS; do
        case " $new " in
          *" $param "*) ;;
          *) new="$new $param" ;;
        esac
      done
      # Strip leading whitespace introduced when current was empty.
      new="$(printf '%s' "$new" | sed 's/^ *//')"
      printf '%s\n' "$new" > "$SDBOOT_CMDLINE_PATH"
      ;;
  esac
}

# --- Refresh bootloader (always idempotent) ---
# Uses pipefail-safe pattern: capture exit code from PIPESTATUS.
refresh_bootloader() {
  local rc
  case "$BOOTLOADER" in
    grub)
      update-grub 2>&1 | sed 's/^/UPDATE_GRUB_OUT: /'
      rc=${PIPESTATUS[0]}
      ;;
    systemd-boot)
      proxmox-boot-tool refresh 2>&1 | sed 's/^/PBT_REFRESH_OUT: /'
      rc=${PIPESTATUS[0]}
      ;;
    *)
      echo "PBT_REFRESH_OUT: unknown bootloader: $BOOTLOADER"
      rc=1
      ;;
  esac
  return "$rc"
}

# --- Mode dispatch ---
case "$mode" in
  verify)
    # Both effective AND durable required for STATUS=ok. A node with
    # /proc/cmdline patched but no persistent config is NOT ok -- the
    # workaround would be lost on next reboot.
    runtime_ok=0
    persistent_ok=0
    runtime_has_all_params && runtime_ok=1
    persistent_has_all_params && persistent_ok=1
    echo "RUNTIME=${runtime_ok}"
    echo "PERSISTENT=${persistent_ok}"
    if [ $runtime_ok -eq 1 ] && [ $persistent_ok -eq 1 ]; then
      echo "STATUS=ok"
    elif [ $persistent_ok -eq 1 ]; then
      echo "STATUS=reboot"
    else
      echo "STATUS=missing"
    fi
    exit 0
    ;;
  apply)
    runtime_ok=0
    persistent_ok=0
    runtime_has_all_params && runtime_ok=1
    persistent_has_all_params && persistent_ok=1
    echo "RUNTIME_BEFORE=${runtime_ok}"

    # Step 1: ensure persistent config is correct.
    if [ $persistent_ok -eq 0 ]; then
      write_persistent
      echo "PERSISTENT=written"
    else
      echo "PERSISTENT=already_correct"
    fi

    # Step 2: ALWAYS run refresh. update-grub and proxmox-boot-tool
    # refresh are idempotent and cheap; running every apply eliminates
    # the round-1 false-success retry loop where a previous failed
    # refresh left boot config stale while persistent matched.
    if refresh_bootloader; then
      echo "REFRESH=ok"
    else
      echo "STATUS=error_refresh_failed"
      exit 1
    fi

    # Step 3: report. Re-check runtime in case /proc/cmdline already
    # had the params (rare: e.g., previously applied by a different
    # mechanism, or kernel was already booted with these flags). If
    # runtime is now good AND persistent is now good, no reboot is
    # needed -- both effective and durable.
    if [ $runtime_ok -eq 1 ]; then
      echo "STATUS=ok"
    else
      echo "STATUS=applied"
    fi
    exit 0
    ;;
  *)
    echo "STATUS=error_bad_mode"
    exit 2
    ;;
esac
REMOTE
}

# Render the remote blob. Mode is substituted via __MODE__ (a fixed-form
# token), all variable-content fields are passed via base64-encoded env vars
# read inside the remote blob. This avoids any escaping/quoting concerns
# regardless of what bytes the literals contain.
render_remote_blob() {
  local mode="$1"
  MODE="$mode" python3 -c '
import sys, os
blob = sys.stdin.read()
blob = blob.replace("__MODE__", os.environ["MODE"])
sys.stdout.write(blob)
' <<<"$(remote_blob)"
}

# Build the prelude that exports the base64 env vars BEFORE the rendered
# blob runs. Returns a wrapped script: prelude + blob.
build_remote_script() {
  local mode="$1" blob_body params_b64 path_b64 content_b64
  blob_body="$(render_remote_blob "$mode")"
  params_b64="$(printf '%s' "$KERNEL_PARAMS_STR" | base64 | tr -d '\n')"
  path_b64="$(printf '%s' "$GRUB_DROPIN_PATH" | base64 | tr -d '\n')"
  content_b64="$(printf '%s' "$GRUB_DROPIN_CONTENT" | base64 | tr -d '\n')"
  cat <<PRELUDE
export MYCOFU_PARAMS_B64="${params_b64}"
export MYCOFU_GRUB_DROPIN_PATH_B64="${path_b64}"
export MYCOFU_GRUB_DROPIN_CONTENT_B64="${content_b64}"
${blob_body}
PRELUDE
}

run_remote() {
  local node="$1" ip="$2" mode="$3"
  local rendered result rc
  rendered="$(build_remote_script "$mode")"
  set +e
  # Pass the rendered script as the remote command. ssh -n is preserved
  # because we are NOT in a while-read loop; the script-via-arg pattern
  # works without piping stdin.
  result="$(ssh_node "$ip" "$rendered" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]] && ! grep -q "^STATUS=" <<<"$result"; then
    # Send to stderr so the operator sees it; printing to stdout would let
    # callers (verify_node, apply_node) capture it into $out and discard.
    echo "[${node}] ERROR: ssh/remote failure (rc=${rc}):" >&2
    printf '%s\n' "$result" | sed 's/^/    /' >&2
    return 1
  fi
  echo "$result"
  return 0
}

# Returns:
#   0 -- runtime + persistent both OK (no reboot needed)
#   1 -- persistent OK but runtime stale (reboot would make effective)
#   2 -- persistent missing/stale (or SSH/remote failure)
verify_node() {
  local node="$1" ip="$2"
  local out
  if ! out="$(run_remote "$node" "$ip" verify)"; then
    return 2
  fi
  local status bootloader runtime persistent
  status="$(grep '^STATUS=' <<<"$out" | tail -1 | cut -d= -f2-)"
  bootloader="$(grep '^BOOTLOADER=' <<<"$out" | tail -1 | cut -d= -f2-)"
  runtime="$(grep '^RUNTIME=' <<<"$out" | tail -1 | cut -d= -f2-)"
  persistent="$(grep '^PERSISTENT=' <<<"$out" | tail -1 | cut -d= -f2-)"
  case "$status" in
    ok)
      echo "[${node}] OK (${bootloader}): runtime + persistent both effective"
      return 0
      ;;
    reboot)
      echo "[${node}] REBOOT REQUIRED (${bootloader}): persistent config has params, /proc/cmdline does not"
      return 1
      ;;
    missing)
      echo "[${node}] MISSING (${bootloader}): persistent config absent or stale (runtime=${runtime}, persistent=${persistent})"
      return 2
      ;;
    error_*)
      echo "[${node}] ERROR (${bootloader:-unknown}): ${status}" >&2
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      return 2
      ;;
    *)
      echo "[${node}] ERROR: unrecognized verify status '${status}'" >&2
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      return 2
      ;;
  esac
}

# Returns:
#   0 -- already applied + effective (no reboot needed) OR dry-run
#   $EXIT_REBOOT_NEEDED -- applied/refreshed, reboot pending
#   1 -- failure (SSH error, refresh failure, etc.)
apply_node() {
  local node="$1" ip="$2"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[${node}] DRY-RUN: would detect bootloader, write persistent config if missing, run refresh"
    return 0
  fi

  local out
  if ! out="$(run_remote "$node" "$ip" apply)"; then
    return 1
  fi

  local status bootloader persistent refresh runtime_before
  status="$(grep '^STATUS=' <<<"$out" | tail -1 | cut -d= -f2-)"
  bootloader="$(grep '^BOOTLOADER=' <<<"$out" | tail -1 | cut -d= -f2-)"
  persistent="$(grep '^PERSISTENT=' <<<"$out" | tail -1 | cut -d= -f2-)"
  refresh="$(grep '^REFRESH=' <<<"$out" | tail -1 | cut -d= -f2-)"
  runtime_before="$(grep '^RUNTIME_BEFORE=' <<<"$out" | tail -1 | cut -d= -f2-)"

  case "$status" in
    ok)
      local detail=""
      [[ -n "$persistent" ]] && detail="${detail}persistent=${persistent} "
      [[ -n "$refresh" ]] && detail="${detail}refresh=${refresh} "
      echo "[${node}] OK (${bootloader}): runtime already effective, persistent ensured. ${detail}"
      return 0
      ;;
    applied)
      local detail=""
      [[ -n "$persistent" ]] && detail="${detail}persistent=${persistent} "
      [[ -n "$refresh" ]] && detail="${detail}refresh=${refresh} "
      echo "[${node}] APPLIED (${bootloader}): ${detail}-- reboot required to take effect"
      return $EXIT_REBOOT_NEEDED
      ;;
    error_refresh_failed)
      echo "[${node}] ERROR (${bootloader}): bootloader refresh failed" >&2
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      return 1
      ;;
    error_*)
      echo "[${node}] ERROR (${bootloader:-unknown}): ${status}" >&2
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      return 1
      ;;
    *)
      echo "[${node}] ERROR: unrecognized apply status '${status}'" >&2
      printf '%s\n' "$out" | sed 's/^/    /' >&2
      return 1
      ;;
  esac
}

# --- Main loop ---
overall_rc=0
reboot_needed_count=0
for i in "${!NODE_NAMES[@]}"; do
  node="${NODE_NAMES[$i]}"
  ip="${NODE_IPS[$i]}"
  if [[ $VERIFY_ONLY -eq 1 ]]; then
    set +e
    verify_node "$node" "$ip"
    rc=$?
    set -e
    [[ $rc -ne 0 ]] && overall_rc=1
  else
    set +e
    apply_node "$node" "$ip"
    rc=$?
    set -e
    if [[ $rc -eq $EXIT_REBOOT_NEEDED ]]; then
      reboot_needed_count=$((reboot_needed_count + 1))
    elif [[ $rc -ne 0 ]]; then
      overall_rc=1
    fi
  fi
done

if [[ $VERIFY_ONLY -eq 0 && $reboot_needed_count -gt 0 && $overall_rc -eq 0 ]]; then
  echo
  echo "==> ${reboot_needed_count} node(s) need reboot to load new kernel parameters."
  echo "==> See OPERATIONS.md 'Applying Kernel Parameters' for the full"
  echo "    HA-aware rolling reboot procedure. The procedure is a self-"
  echo "    contained bash script you save and run as:"
  echo "      bash /tmp/maint.sh <N> <other-node>"
  echo "    from a SURVIVING cluster node (NOT the workstation -- qm and"
  echo "    ha-manager are Proxmox-host commands; NOT the target node"
  echo "    either, since it's about to reboot). Repeat for each node."
  echo "    Precondition: all running VMs on the target node must be HA-"
  echo "    managed; manually migrate any non-HA running VM first."
  echo "==> After the per-node procedure completes for ALL nodes, run from"
  echo "    your operator workstation:"
  echo "      framework/scripts/rebalance-cluster.sh"
  echo "    to migrate VMs back to their intended placements (config.yaml"
  echo "    is workstation-side, so this step CANNOT run from a Proxmox"
  echo "    node)."
  echo "==> Do NOT use 'systemctl stop corosync' for a planned reboot --"
  echo "    that procedure is reserved for the storage-failure incident path"
  echo "    documented in .claude/rules/storage-failure-fence.md and triggers"
  echo "    a watchdog fence rather than a graceful shutdown."
  exit $EXIT_REBOOT_NEEDED
fi

exit $overall_rc
