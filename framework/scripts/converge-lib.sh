#!/usr/bin/env bash
# converge-lib.sh - Shared convergence steps for rebuild-cluster.sh and converge-vm.sh.
#
# Caller contract:
#   Required vars:
#     SCRIPT_DIR - framework/scripts path
#     REPO_DIR - repository root
#     CONFIG - site/config.yaml path
#     APPS_CONFIG - site/applications.yaml path
#   Optional vars:
#     TOFU_TARGETS - space-separated -target=module.X flags
#     CLOSURE - resolved store path or symlink target to push before convergence
#     OVERRIDE_BRANCH_CHECK - 0 or 1
#   Optional hooks:
#     log, die, step_start, step_done, step_skip, step_in_scope
#
# This library preserves rebuild-cluster.sh Steps 8-15.7, excluding Step 14.5.

set -euo pipefail

_CONVERGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_CONVERGE_LIB_DIR}/certbot-cluster.sh"

if ! declare -F log >/dev/null; then
  log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  }
fi

if ! declare -F die >/dev/null; then
  die() {
    log "FATAL: $*"
    exit 1
  }
fi

if ! declare -F step_start >/dev/null; then
  step_start() {
    log "=== Step $1: $2 ==="
    STEP_START=$(date +%s)
  }
fi

if ! declare -F step_done >/dev/null; then
  step_done() {
    local elapsed=0
    if [[ -n "${STEP_START:-}" ]]; then
      elapsed=$(( $(date +%s) - STEP_START ))
    fi
    log "    Step $1 completed in ${elapsed}s"
  }
fi

if ! declare -F step_skip >/dev/null; then
  step_skip() {
    log "    Step $1 skipped: $2"
  }
fi

if ! declare -F step_in_scope >/dev/null; then
  step_in_scope() {
    return 0
  }
fi

CONVERGE_SSH_OPTS=(
  -n
  -o ConnectTimeout=5
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  # Keepalives (#710): a control-plane switch can silently drop an in-flight
  # poll connection (sshd restarted mid-activation, network blip). Without
  # keepalives the poll cert_ssh would block indefinitely on the dead socket,
  # making a dropped connection indistinguishable from a hung switch. Probe
  # every 5s and give up after 3 unanswered probes (~15s) so the SSH fails
  # fast and the caller reconnects on the next poll iteration. These apply to
  # every converge SSH that uses CONVERGE_SSH_OPTS (cert_ssh, wait_for_ssh,
  # the grub-fixup ssh), not just the poll loop — benign and desirable for all.
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=3
)

converge_require_context() {
  local required_vars=(
    SCRIPT_DIR
    REPO_DIR
    CONFIG
    APPS_CONFIG
  )
  local var_name
  local missing=()

  for var_name in "${required_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
      missing+=("${var_name}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "converge_run_all requires: ${missing[*]}"
  fi

  [[ -d "${SCRIPT_DIR}" ]] || die "SCRIPT_DIR does not exist: ${SCRIPT_DIR}"
  [[ -f "${CONFIG}" ]] || die "CONFIG file not found: ${CONFIG}"
  [[ -f "${APPS_CONFIG}" ]] || die "APPS_CONFIG file not found: ${APPS_CONFIG}"

  TOFU_TARGETS="${TOFU_TARGETS:-}"
  OVERRIDE_BRANCH_CHECK="${OVERRIDE_BRANCH_CHECK:-0}"
}

converge_target_envs_error() {
  log "ERROR: $*" >&2
}

converge_target_envs() {
  "${VM_SCOPE_SCRIPT:-${SCRIPT_DIR}/vm-scope.sh}" target-envs --targets "${TOFU_TARGETS:-}"
}

# Helper: SSH to a VM (used by staging override and cert checks below)
cert_ssh() {
  ssh "${CONVERGE_SSH_OPTS[@]}" "root@$1" "$2" 2>/dev/null
}

wait_for_ssh() {
  local vm_ip="$1"
  local timeout="${2:-180}"
  local interval="${3:-5}"
  local elapsed=0

  while true; do
    if ssh "${CONVERGE_SSH_OPTS[@]}" "root@${vm_ip}" "true" 2>/dev/null; then
      return 0
    fi

    if (( elapsed >= timeout )); then
      die "Timed out waiting ${timeout}s for SSH on ${vm_ip}"
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
}

converge_closure_target_module() {
  local raw_targets=()
  local target=""
  local modules=()
  local module_name=""

  CLOSURE_TARGET_MODULE=""

  read -r -a raw_targets <<< "${TOFU_TARGETS:-}"
  if [[ "${#raw_targets[@]}" -eq 0 ]]; then
    die "--closure requires exactly one --targets module"
  fi

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
        die "Invalid target syntax while resolving --closure target: ${target}"
        ;;
    esac
    modules+=("${module_name}")
  done

  if [[ "${#modules[@]}" -ne 1 ]]; then
    die "--closure requires exactly one target module"
  fi

  CLOSURE_TARGET_MODULE="${modules[0]}"
}

converge_closure_target_ip() {
  local module_name="$1"
  local target_name="${module_name#module.}"
  local vm_ip=""
  local app_key=""
  local env_name=""

  CLOSURE_TARGET_IP=""

  case "$module_name" in
    module.dns_dev|module.dns_prod)
      die "--closure does not support ${module_name}: dns targets manage multiple VMs"
      ;;
  esac

  vm_ip=$(yq -r ".vms.${target_name}.ip // \"\"" "$CONFIG" 2>/dev/null || true)
  if [[ -n "$vm_ip" && "$vm_ip" != "null" ]]; then
    CLOSURE_TARGET_IP="$vm_ip"
    return 0
  fi

  app_key="${target_name%_*}"
  env_name="${target_name##*_}"
  if [[ "$app_key" == "$target_name" || "$env_name" == "$target_name" ]]; then
    die "Unable to resolve a VM IP for ${module_name}"
  fi

  vm_ip=$(yq -r ".applications.${app_key}.environments.${env_name}.ip // \"\"" "$APPS_CONFIG" 2>/dev/null || true)
  if [[ -n "$vm_ip" && "$vm_ip" != "null" ]]; then
    CLOSURE_TARGET_IP="$vm_ip"
    return 0
  fi

  die "Unable to resolve a VM IP for ${module_name}"
}

# Fix grub paths on an overlay-root VM after switch-to-configuration.
# install-grub.pl generates )/store/... instead of )/nix/store/... on
# overlay-root VMs. Only match )/store/ (after GRUB drive prefix) to
# avoid corrupting paths that already have /nix/store/.
#
# After the sed, VERIFY: re-read grub.cfg and assert no )/store/ paths
# remain. This catches the class of failure that bricked cicd on
# 2026-07-06 (#496 recovered by hand-applying this same sed), which
# reveals that the sed alone can silently fail to take effect:
#   (a) a variant of the path the sed regex didn't match,
#   (b) an install-grub race that re-wrote grub.cfg after the sed,
#   (c) the sed never ran (control-flow bug).
# Fail loudly on any of these; the caller must not reboot the VM.
#
# NOTE on ssh: cert_ssh at line 111 swallows stderr with 2>/dev/null,
# so we use a direct ssh here instead — the verify's diagnostic
# (which lines are still broken) must be visible for the operator to
# know what to fix. Behavior is otherwise identical to cert_ssh.
#
# See #339 (this issue), #497 (retire the sed workaround entirely at
# the install-grub source), #496 (the incident that surfaced the gap).
# Called by converge_step_closure.
converge_fix_grub_paths() {
  local vm_ip="$1"
  ssh "${CONVERGE_SSH_OPTS[@]}" "root@${vm_ip}" \
    "if [ -f /boot/grub/grub.cfg ]; then sed -i 's|)/store/|)/nix/store/|g' /boot/grub/grub.cfg; if grep -qF ')/store/' /boot/grub/grub.cfg; then echo 'converge_fix_grub_paths: verify-after-write FAILED — grub.cfg still references )/store/ paths after sed:' >&2; grep -nF ')/store/' /boot/grub/grub.cfg >&2; exit 1; fi; fi" \
    || die "converge_fix_grub_paths: failed on ${vm_ip} (see ssh stderr above). Structural fix: framework/scripts/check-boot-integrity.sh --host <name> pinpoints broken paths cluster-wide; then re-run converge to redeploy the closure through converge_step_closure."
}

converge_repair_root_disk_labels() {
  local vm_ip="$1"
  local probe_cmd=$'set -u
raw_root_source=$(findmnt -n -o SOURCE / 2>&1)
root_status=$?
root_source=$(printf \'%s\' "$raw_root_source" | awk \'NR==1{print $1; exit}\')
if [ "$root_status" -ne 0 ] || [ -z "$root_source" ]; then
  printf "probe_status=cannot-probe-device\\n"
  printf "probe_stage=root-source\\n"
  printf "root_source=%s\\n" "$root_source"
  printf "real_root=\\n"
  printf "root_majmin=\\n"
  printf "root_error=%s\\n" "$raw_root_source"
  exit 0
fi
real_root=/
if [ "$root_source" = "overlay" ]; then
  if mountpoint -q /mnt-real-root-rw 2>/dev/null; then
    real_root=/mnt-real-root-rw
  else
    real_root=/mnt-real-root
  fi
fi

# SOURCE may itself be /dev/disk/by-label/nixos, which is the symlink this
# preflight repairs. Use the mount table MAJ:MIN and /dev/block to identify
# the real block device without depending on any by-label path.
raw_root_majmin=$(findmnt -n -o MAJ:MIN --nofsroot "$real_root" 2>&1)
root_status=$?
root_majmin=$(printf \'%s\' "$raw_root_majmin" | awk \'NR==1{print $1; exit}\')
if [ "$root_status" -ne 0 ] || [ -z "$root_majmin" ]; then
  printf "probe_status=cannot-probe-device\\n"
  printf "probe_stage=root-majmin\\n"
  printf "root_source=%s\\n" "$root_source"
  printf "real_root=%s\\n" "$real_root"
  printf "root_majmin=%s\\n" "$root_majmin"
  printf "root_error=%s\\n" "$raw_root_majmin"
  exit 0
fi

root_dev=$(readlink -f "/dev/block/${root_majmin}" 2>&1)
root_status=$?
if [ "$root_status" -ne 0 ] || [ -z "$root_dev" ]; then
  printf "probe_status=cannot-probe-device\\n"
  printf "probe_stage=root-device-readlink\\n"
  printf "root_source=%s\\n" "$root_source"
  printf "real_root=%s\\n" "$real_root"
  printf "root_majmin=%s\\n" "$root_majmin"
  printf "root_error=%s\\n" "$root_dev"
  exit 0
fi
if ! test -b "$root_dev"; then
  printf "probe_status=cannot-probe-device\\n"
  printf "probe_stage=root-device-not-block\\n"
  printf "root_source=%s\\n" "$root_source"
  printf "real_root=%s\\n" "$real_root"
  printf "root_majmin=%s\\n" "$root_majmin"
  printf "root_dev=%s\\n" "$root_dev"
  printf "root_error=resolved /dev/block/%s to %s, but it is not a block device\\n" "$root_majmin" "$root_dev"
  exit 0
fi
printf "probe_status=ok\\n"
printf "root_source=%s\\n" "$root_source"
printf "real_root=%s\\n" "$real_root"
printf "root_majmin=%s\\n" "$root_majmin"
printf "root_dev=%s\\n" "$root_dev"
if [ -L /dev/disk/by-label/nixos ]; then
  label_target=$(readlink -f /dev/disk/by-label/nixos 2>&1)
  label_status=$?
  printf "label_present=1\\n"
  if [ "$label_status" -eq 0 ]; then
    printf "label_target=%s\\n" "$label_target"
  else
    printf "label_target=\\n"
    printf "label_error=%s\\n" "$label_target"
  fi
else
  printf "label_present=0\\n"
  printf "label_target=\\n"
fi
'
  local probe_output=""
  local ssh_exit=0
  local probe_state=""
  local probe_stage=""
  local root_dev=""
  local label_present=""
  local label_target=""
  local symlink_before=""
  local root_dev_q=""
  local blkid_cmd=""
  local blkid_output=""
  local blkid_exit=""
  local blkid_body=""
  local trigger_cmd=""
  local trigger_output=""
  local trigger_exit=""
  local reprobe_output=""
  local reprobe_state=""
  local root_dev_after=""
  local label_present_after=""
  local label_target_after=""
  local symlink_after=""

  set +e
  probe_output=$(ssh "${CONVERGE_SSH_OPTS[@]}" "root@${vm_ip}" "$probe_cmd" 2>&1)
  ssh_exit=$?
  set -e
  if [[ $ssh_exit -ne 0 ]]; then
    die "Root disk label preflight SSH failure on ${vm_ip} while probing real root device and /dev/disk/by-label/nixos (root_device=unknown, symlink_before=unknown, ssh_exit=${ssh_exit}). Output: ${probe_output:-<empty>}"
  fi

  probe_state="$(printf '%s\n' "$probe_output" | sed -n 's/^probe_status=//p' | tail -1)"
  probe_stage="$(printf '%s\n' "$probe_output" | sed -n 's/^probe_stage=//p' | tail -1)"
  root_dev="$(printf '%s\n' "$probe_output" | sed -n 's/^root_dev=//p' | tail -1)"
  label_present="$(printf '%s\n' "$probe_output" | sed -n 's/^label_present=//p' | tail -1)"
  label_target="$(printf '%s\n' "$probe_output" | sed -n 's/^label_target=//p' | tail -1)"

  if [[ "$probe_state" != "ok" || -z "$root_dev" ]]; then
    die "Root disk label preflight failed on ${vm_ip}: cannot-probe-device: could not identify the real root device before closure push (stage=${probe_stage:-unknown}, root_device=${root_dev:-unknown}, symlink_before=unknown). Probe output: ${probe_output:-<empty>}"
  fi

  if [[ "$label_present" == "1" ]]; then
    symlink_before="present target=${label_target:-unresolved}"
  else
    symlink_before="absent"
  fi

  printf -v root_dev_q '%q' "$root_dev"
  blkid_cmd="set +e
blkid_output=\$(blkid -p -o export ${root_dev_q} 2>&1)
blkid_status=\$?
printf \"%s\\n\" \"\$blkid_output\"
printf \"__BLKID_STATUS=%s\\n\" \"\$blkid_status\"
exit 0"

  set +e
  blkid_output=$(ssh "${CONVERGE_SSH_OPTS[@]}" "root@${vm_ip}" "$blkid_cmd" 2>&1)
  ssh_exit=$?
  set -e
  if [[ $ssh_exit -ne 0 ]]; then
    die "Root disk label preflight SSH failure on ${vm_ip} while running blkid on ${root_dev} (symlink_before=${symlink_before}, ssh_exit=${ssh_exit}). Output: ${blkid_output:-<empty>}"
  fi

  blkid_exit="$(printf '%s\n' "$blkid_output" | sed -n 's/^__BLKID_STATUS=//p' | tail -1)"
  blkid_body="$(printf '%s\n' "$blkid_output" | sed '/^__BLKID_STATUS=/d')"
  if [[ -z "$blkid_exit" || "$blkid_exit" != "0" ]]; then
    die "Root disk label preflight failed on ${vm_ip}: blkid could not read filesystem metadata on ${root_dev}; refusing closure push before nix copy or switch (symlink_before=${symlink_before}, blkid_exit=${blkid_exit:-missing}, blkid_output=${blkid_body:-<empty>})."
  fi
  if ! printf '%s\n' "$blkid_body" | grep -qx 'LABEL=nixos'; then
    die "Root disk label preflight failed on ${vm_ip}: on-disk filesystem label missing on superblock or wrong for ${root_dev}; refusing closure push before nix copy or switch (symlink_before=${symlink_before}, blkid_exit=${blkid_exit}, blkid_output=${blkid_body:-<empty>})."
  fi

  if [[ "$label_present" == "1" && "$label_target" == "$root_dev" ]]; then
    log "    /dev/disk/by-label/nixos already resolves to ${root_dev} on ${vm_ip}; LABEL=nixos verified"
    return 0
  fi

  trigger_cmd="set +e
udevadm_output=\$(udevadm trigger --settle --action=change ${root_dev_q} 2>&1)
udevadm_status=\$?
printf \"%s\\n\" \"\$udevadm_output\"
printf \"__UDEVADM_STATUS=%s\\n\" \"\$udevadm_status\"
exit 0"

  set +e
  trigger_output=$(ssh "${CONVERGE_SSH_OPTS[@]}" "root@${vm_ip}" "$trigger_cmd" 2>&1)
  ssh_exit=$?
  set -e
  if [[ $ssh_exit -ne 0 ]]; then
    die "Root disk label preflight SSH failure on ${vm_ip} while retriggering udev for ${root_dev} (symlink_before=${symlink_before}, blkid_exit=${blkid_exit}, blkid_output=${blkid_body:-<empty>}, ssh_exit=${ssh_exit}). Output: ${trigger_output:-<empty>}"
  fi

  trigger_exit="$(printf '%s\n' "$trigger_output" | sed -n 's/^__UDEVADM_STATUS=//p' | tail -1)"
  if [[ -z "$trigger_exit" || "$trigger_exit" != "0" ]]; then
    die "Root disk label preflight failed on ${vm_ip}: udev retrigger command failed for ${root_dev}; refusing closure push before nix copy or switch (symlink_before=${symlink_before}, blkid_exit=${blkid_exit}, blkid_output=${blkid_body:-<empty>}, udevadm_exit=${trigger_exit:-missing}, udevadm_output=${trigger_output:-<empty>})."
  fi

  set +e
  reprobe_output=$(ssh "${CONVERGE_SSH_OPTS[@]}" "root@${vm_ip}" "$probe_cmd" 2>&1)
  ssh_exit=$?
  set -e
  if [[ $ssh_exit -ne 0 ]]; then
    die "Root disk label preflight SSH failure on ${vm_ip} while re-probing /dev/disk/by-label/nixos after udev retrigger for ${root_dev} (symlink_before=${symlink_before}, blkid_exit=${blkid_exit}, blkid_output=${blkid_body:-<empty>}, ssh_exit=${ssh_exit}). Output: ${reprobe_output:-<empty>}"
  fi

  reprobe_state="$(printf '%s\n' "$reprobe_output" | sed -n 's/^probe_status=//p' | tail -1)"
  root_dev_after="$(printf '%s\n' "$reprobe_output" | sed -n 's/^root_dev=//p' | tail -1)"
  label_present_after="$(printf '%s\n' "$reprobe_output" | sed -n 's/^label_present=//p' | tail -1)"
  label_target_after="$(printf '%s\n' "$reprobe_output" | sed -n 's/^label_target=//p' | tail -1)"

  if [[ "$label_present_after" == "1" ]]; then
    symlink_after="present target=${label_target_after:-unresolved}"
  else
    symlink_after="absent"
  fi

  if [[ "$reprobe_state" == "ok" && "$root_dev_after" == "$root_dev" && "$label_present_after" == "1" && "$label_target_after" == "$root_dev" ]]; then
    log "    repaired /dev/disk/by-label/nixos on ${vm_ip} by retriggering udev for ${root_dev}"
    return 0
  fi

  die "Root disk label preflight failed on ${vm_ip}: udev retrigger did not recreate /dev/disk/by-label/nixos for ${root_dev}; refusing closure push before nix copy or switch (symlink_before=${symlink_before}, symlink_after=${symlink_after}, root_device_after=${root_dev_after:-unknown}, blkid_exit=${blkid_exit}, blkid_output=${blkid_body:-<empty>})."
}

converge_step_closure() {
  local module_name=""
  local vm_ip=""
  local requested_closure="${CLOSURE:-}"
  local current_before=""
  local current_after=""
  local current_rebooted=""
  local ssh_timeout="${CLOSURE_SSH_TIMEOUT:-180}"
  local ssh_interval="${CLOSURE_SSH_INTERVAL:-5}"

  [[ -n "${CLOSURE:-}" ]] || return 0

  converge_closure_target_module
  module_name="${CLOSURE_TARGET_MODULE}"
  converge_closure_target_ip "$module_name"
  vm_ip="${CLOSURE_TARGET_IP}"
  converge_repair_root_disk_labels "$vm_ip"

  step_start 7.8 "Push NixOS closure"

  NIX_SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" \
    nix copy --to "ssh://root@${vm_ip}" "${CLOSURE}" \
    || die "Failed to copy closure ${CLOSURE} to ${vm_ip}"

  current_before="$(cert_ssh "$vm_ip" "readlink -f /run/current-system" || true)"
  [[ -n "$current_before" ]] || die "Failed to read /run/current-system before switch on ${vm_ip}"

  # Run switch-to-configuration via systemd-run so it survives SSH
  # disconnection. When the cicd deploy job runs on the runner itself,
  # the process tree is: runner → job → SSH client → SSH session →
  # switch. The switch stops the runner as part of NixOS activation,
  # which kills the entire tree including the switch itself (#206).
  # systemd-run creates a transient unit independent of the SSH session
  # so the switch completes even after the runner is stopped.
  #
  # --remain-after-exit: keeps the unit queryable after completion so
  # we can check Result=success vs Result=exit-code.
  local switch_unit="nixos-switch-closure"
  # Refuse to stomp a switch that is still running (#711 retry safety). A
  # retried deploy:control-plane:*:dev/prod job (or a re-run rebuild) can land
  # here while the PREVIOUS attempt's detached switch is still activating: the
  # switch survives job death via systemd-run, so the unit can be mid-switch.
  # `systemctl stop` on a running unit would SIGTERM switch-to-configuration
  # mid-activation — exactly the unbounded/partial-activation hazard #707
  # warns about. Fail loudly and let the operator (or a later idempotent
  # live==built retry, once the switch finishes) proceed, rather than
  # interrupt an in-flight activation.
  local existing_sub
  existing_sub=$(cert_ssh "$vm_ip" "systemctl show -p SubState --value ${switch_unit} 2>/dev/null" || true)
  # Fail closed if we cannot read the state at all. An absent unit returns a
  # concrete "dead" (verified live: `systemctl show -p SubState --value` on a
  # non-existent unit prints "dead"), so an EMPTY result means the probe
  # itself failed — we cannot rule out an in-flight switch, and per the
  # destruction-safety FAIL-not-SKIP doctrine an indeterminate safety check
  # must fail rather than fall through to `systemctl stop` (#709 review, P2).
  if [[ -z "$existing_sub" ]]; then
    die "Could not read ${switch_unit} SubState on ${vm_ip} before switch (empty probe result) — refusing to proceed; cannot rule out an in-flight switch. Retry once the VM is reachable."
  fi
  if [[ "$existing_sub" == "running" || "$existing_sub" == "start" ]]; then
    die "A ${switch_unit} unit is already running on ${vm_ip} (SubState=${existing_sub}); refusing to stop it mid-activation. A prior converge attempt's switch is still in progress (it runs detached via systemd-run) — wait for it to finish, then retry."
  fi
  # Clean up any previous transient unit. reset-failed clears failed
  # units; stop clears active/exited units (from --remain-after-exit).
  cert_ssh "$vm_ip" "systemctl stop ${switch_unit} 2>/dev/null; systemctl reset-failed ${switch_unit} 2>/dev/null; true" || true
  cert_ssh "$vm_ip" \
    "systemd-run --unit=${switch_unit} --remain-after-exit \
      --description='Closure switch' \
      ${CLOSURE}/bin/switch-to-configuration switch" \
    || die "Failed to start closure switch on ${vm_ip}"

  # Wait for SSH to come back — the switch may drop the connection.
  sleep 3
  wait_for_ssh "$vm_ip" "$ssh_timeout" "$ssh_interval"

  # Poll the transient unit until it reaches a terminal state.
  #
  # `systemctl show -p Result` returns Result=success as the default while a
  # unit is still running — Result is meaningful only after the unit exits.
  # Polling on Result alone breaks the loop on the very first probe and the
  # post-loop check then misreports a still-running switch as "completed
  # successfully". Use the more specific terminal signals instead:
  #   - ActiveState=failed: oneshot or simple unit failed
  #   - ActiveState=inactive: unit completed without --remain-after-exit
  #   - SubState=exited: unit completed with --remain-after-exit (our case;
  #     ActiveState stays "active" but SubState transitions running → exited)
  # Job-side observation deadline (#709). This bounds only how long the
  # observer waits for the transient switch unit to reach a terminal state;
  # the switch itself runs detached via systemd-run and is unaffected by this
  # budget. Sized to sit meaningfully below GitLab's 1h stuck-build reaper
  # (Ci::StuckBuilds::DropRunningService, BUILD_RUNNING_OUTDATED_TIMEOUT=1h)
  # and far below the 2h job timeout, so a genuinely wedged switch produces a
  # fast, explicit, reportable verdict here rather than being swept later as a
  # zombie with an empty trace (RCA #707 note 6376). 1500s (25m) also clears
  # any healthy switch — a #707-bounded gitlab drain plus service churn and
  # reboot — with wide margin, so a legitimately slow switch (long service
  # stop, migration) is observed to completion instead of false-failed.
  # Override with CLOSURE_SWITCH_MAX for an exceptional VM.
  local switch_max="${CLOSURE_SWITCH_MAX:-1500}"
  # Fail closed on a non-numeric override rather than letting `set -e` kill the
  # deploy with an opaque "integer expression expected" (#709 review, P3).
  if ! [[ "$switch_max" =~ ^[1-9][0-9]*$ ]]; then
    die "CLOSURE_SWITCH_MAX must be a positive integer number of seconds (got: '${switch_max}')"
  fi
  # The deadline is measured in WALL-CLOCK seconds via `date +%s`, not by a
  # per-iteration counter. A counter that assumed each pass costs exactly the
  # sleep interval would undercount the cert_ssh round-trip — and with the
  # #710 keepalives a degraded probe can take ~15s — so real elapsed time
  # could run several multiples past switch_max and blow through the 1h reaper
  # the budget is sized against (#709 review, three-reviewer P1).
  local switch_state=""
  local switch_terminal=0
  local switch_deadline=$(( $(date +%s) + switch_max ))
  local probe_state
  while [[ $(date +%s) -lt $switch_deadline ]]; do
    set +e
    probe_state=$(cert_ssh "$vm_ip" "systemctl show -p ActiveState -p SubState -p Result ${switch_unit} 2>/dev/null" || true)
    set -e
    # Keep the last non-empty observation so the budget-expiry verdict below
    # reports a real state even if the final probe failed (SSH drop → empty).
    # A carried-over value is always a previously-seen NON-terminal state (a
    # terminal one would have broken the loop), so it cannot cause a false
    # terminal break here (#709 review, P2).
    [[ -n "$probe_state" ]] && switch_state="$probe_state"
    # Break ONLY on a real terminal state. `Result` is meaningless while the
    # unit runs (systemd reports Result=success by default before exit), so it
    # must never appear in the break condition (#709).
    if echo "$switch_state" | grep -qE "ActiveState=(inactive|failed)|SubState=exited"; then
      switch_terminal=1
      break
    fi
    sleep 3
  done

  # Poll-budget expiry is its own explicit verdict (#709) — NOT a completion
  # and NOT a closure mismatch. The switch never reached a terminal state, so
  # `Result` is still the running-default `success`; reading it here would
  # false-positive and misreport a still-running switch as "completed
  # successfully" (the exact 2026-07-24 incident). Fail loudly instead (G4).
  if [[ $switch_terminal -eq 0 ]]; then
    die "Closure switch still running on ${vm_ip} after ${switch_max}s — not a completion, not a mismatch. Last observed state: ${switch_state}"
  fi

  # Terminal state reached — `Result` is now meaningful. Fail closed on
  # anything other than explicit success.
  if echo "$switch_state" | grep -q "Result=success"; then
    log "    closure switch completed successfully"
  else
    die "Closure switch failed on ${vm_ip}: ${switch_state}"
  fi

  current_after="$(cert_ssh "$vm_ip" "readlink -f /run/current-system" || true)"
  [[ -n "$current_after" ]] || die "Failed to read /run/current-system after switch on ${vm_ip}"
  [[ "$current_after" == "$requested_closure" ]] \
    || die "Activated closure mismatch on ${vm_ip}: expected ${requested_closure}, got ${current_after}"

  # Fix grub paths: install-grub.pl on an overlay-root VM generates
  # )/store/... instead of )/nix/store/... (strips the /nix mount prefix).
  # Only match )/store/ (after GRUB drive prefix) to avoid corrupting
  # paths that already have /nix/store/.
  converge_fix_grub_paths "$vm_ip"

  if [[ "$current_before" == "$current_after" ]]; then
    log "    closure already active, no reboot needed"
    step_done 7.8
    return 0
  fi

  cert_ssh "$vm_ip" "reboot" >/dev/null 2>&1 || true

  # Wait for the VM to go down before probing for SSH. Without this,
  # wait_for_ssh may catch the OLD sshd still running before the reboot
  # takes effect, return immediately, and then the post-reboot readlink
  # fails because the VM is actually rebooting.
  sleep 5
  wait_for_ssh "$vm_ip" "$ssh_timeout" "$ssh_interval"

  # Give services a moment to settle after SSH first responds.
  # The overlay VM may accept SSH connections during early boot before
  # all services (including NixOS activation) have completed.
  sleep 3

  # Re-read the booted system instead of trusting SSH alone; a firmware or
  # GRUB fallback can bring the VM back on an older generation while SSH works.
  current_rebooted="$(cert_ssh "$vm_ip" "readlink -f /run/current-system" || true)"
  [[ -n "$current_rebooted" ]] || die "Failed to read /run/current-system after reboot on ${vm_ip}"
  [[ "$current_rebooted" == "$requested_closure" ]] \
    || die "Closure mismatch after reboot on ${vm_ip}: expected ${requested_closure}, got ${current_rebooted}"

  step_done 7.8
}

# Helper: check a single VM for empty cert files
check_empty_certs() {
  local vm_ip="$1" vm_label="$2"
  local empty_cert

  empty_cert=$(cert_ssh "$vm_ip" '
    for d in /etc/letsencrypt/live/*/; do
      [ -d "$d" ] || continue
      cert="${d}fullchain.pem"
      [ -e "$cert" ] && [ ! -s "$cert" ] && echo "$d"
    done; true
  ' || true)

  if [[ -n "$empty_cert" ]]; then
    log "    ${vm_label}: found empty cert files - cleaning up and restarting certbot"
    cert_ssh "$vm_ip" 'rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal; systemctl restart certbot-initial 2>/dev/null || true'
  fi
}

check_cert_domain() {
  local vm_ip="$1" expected_fqdn="$2" vm_label="$3"
  local cert_dirs
  local dir

  # Only report cert directories that contain a non-empty fullchain.pem.
  # An empty or missing cert is not "stale" - it's just not yet issued.
  # List certbot-managed cert directories in live/. Exclude symlinks
  # (e.g., live/gitlab -> gitlab.prod.example.com created by
  # gitlab-cert-link.service) - those are application-level convenience
  # symlinks, not certbot-managed directories.
  cert_dirs=$(cert_ssh "$vm_ip" \
    'for d in /etc/letsencrypt/live/*/; do
       [ -d "$d" ] || continue
       [ -L "${d%/}" ] && continue
       name=$(basename "$d")
       [ "$name" = "README" ] && continue
       cert="${d}fullchain.pem"
       [ -f "$cert" ] && [ -s "$cert" ] && echo "$name"
     done 2>/dev/null' || true)

  for dir in $cert_dirs; do
    [[ -z "$dir" || "$dir" == "*" ]] && continue
    if [[ "$dir" != "$expected_fqdn" ]]; then
      log "    ${vm_label}: stale cert for '${dir}' (expected: ${expected_fqdn})"
      log "    Cleaning stale certs - certbot will re-acquire for the correct domain."
      cert_ssh "$vm_ip" 'rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal; systemctl restart certbot-initial 2>/dev/null || true'
      return 0
    fi
  done
}

converge_step_dns() {
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
}

converge_step_certs() {
  local ACME_DEV_IP=""
  local ACME_DEV_URL=""
  local ACME_DEV_CA=""
  local ACME_DEV_TIMEOUT=300
  local ACME_DEV_INTERVAL=10
  local CERT_TIMEOUT=600
  local CERT_INTERVAL=15
  local CERT_RECOVER_ATTEMPTED=0
  local LE_STAGING_URL=""
  local ACME_URL=""
  local ACME_HTTP=""
  local ACME_STATUS=""
  local CURRENT_URL=""
  local DIAG=""
  local DOMAIN=""
  local EMPTY=""
  local CB_ACTIVE=""
  local ENV=""
  local VM_KEY=""
  local VM_IP=""
  local APP_KEY=""
  local EXPECTED_FQDN=""
  local HOSTNAME=""
  local VAULT_IP=""
  local PBS_IP=""
  local elapsed=0
  local target_record

  step_start 9 "Wait for certificates"

  # When --override-branch-check is active (DR/development rebuilds),
  # override only stateless prod/shared certbot VMs to LE staging.
  # Any backup-backed certbot VM keeps the configured long-term ACME
  # lineage from site/config.yaml so persisted /etc/letsencrypt state
  # stays aligned with the site ACME mode.
  if [[ "$OVERRIDE_BRANCH_CHECK" -eq 1 ]]; then
    LE_STAGING_URL="https://acme-staging-v02.api.letsencrypt.org/directory"
    log ""
    log "    ╔══════════════════════════════════════════════════════════════╗"
    log "    ║  NOTE: Using Let's Encrypt STAGING on stateless VMs only   ║"
    log "    ║  (--override-branch-check active)                           ║"
    log "    ║                                                             ║"
    log "    ║  Backup-backed certbot VMs keep the configured long-term    ║"
    log "    ║  ACME lineage from site/config.yaml. Only stateless         ║"
    log "    ║  prod/shared certbot VMs are switched to staging.           ║"
    log "    ╚══════════════════════════════════════════════════════════════╝"
    log ""

    local OVERRIDE_TARGETS=()
    while IFS= read -r target_record; do
      [[ -z "$target_record" ]] && continue
      OVERRIDE_TARGETS+=("$target_record")
    done < <(certbot_cluster_staging_override_targets "$CONFIG" "$APPS_CONFIG" "$TOFU_TARGETS")

    if [[ "${#OVERRIDE_TARGETS[@]}" -eq 0 ]]; then
      log "    No stateless prod/shared certbot VMs in scope for staging override"
    else
      for target_record in "${OVERRIDE_TARGETS[@]}"; do
        IFS=$'\t' read -r VM_KEY _ VM_IP _ _ _ _ <<< "${target_record}"
        CURRENT_URL=$(cert_ssh "$VM_IP" "cat /run/secrets/certbot/acme-server-url 2>/dev/null" || true)
        if [[ "$CURRENT_URL" == *"acme-v02.api.letsencrypt.org"* ]]; then
          cert_ssh "$VM_IP" "echo '${LE_STAGING_URL}' > /run/secrets/certbot/acme-server-url" || true
          log "    ${VM_KEY}: ACME URL overridden to LE staging"
        fi
      done
    fi
  fi

  ACME_DEV_IP=$(yq -r '.vms.acme_dev.ip // ""' "$CONFIG" 2>/dev/null || true)
  if [[ -n "$ACME_DEV_IP" && "$ACME_DEV_IP" != "null" ]]; then
    ACME_DEV_URL="https://acme:14000/acme/acme/directory"
    ACME_DEV_CA="${REPO_DIR}/framework/step-ca/root-ca.crt"
    elapsed=0
    while true; do
      if curl --silent --show-error --max-time 5 \
        --cacert "$ACME_DEV_CA" \
        --resolve "acme:14000:${ACME_DEV_IP}" \
        "$ACME_DEV_URL" >/dev/null 2>&1; then
        log "    acme-dev is serving ACME"
        break
      fi

      if (( elapsed >= ACME_DEV_TIMEOUT )); then
        log "    FATAL: Timed out waiting for acme-dev ACME endpoint (${ACME_DEV_TIMEOUT}s)"
        DIAG=$(cert_ssh "$ACME_DEV_IP" "
          echo 'step-ca:'; systemctl is-active step-ca 2>/dev/null || true
          echo '---'
          journalctl -u step-ca --no-pager -n 10 2>/dev/null || true
          echo '---'
          echo 'step-ca-dns-forwarder:'; systemctl is-active step-ca-dns-forwarder 2>/dev/null || true
          journalctl -u step-ca-dns-forwarder --no-pager -n 5 2>/dev/null || true
        " || echo "  VM unreachable")
        echo "$DIAG" | while IFS= read -r line; do log "      $line"; done
        die "Dev ACME endpoint failed to become healthy"
      fi

      if (( elapsed > 0 && elapsed % 60 == 0 )); then
        log "    Still waiting for acme-dev ACME endpoint... (${elapsed}s / ${ACME_DEV_TIMEOUT}s)"
      fi

      sleep "$ACME_DEV_INTERVAL"
      elapsed=$(( elapsed + ACME_DEV_INTERVAL ))
    done
  fi

  # Pre-flight: clean up empty cert files on all VMs that use ACME.
  # Certbot can leave empty PEM files after an ACME server outage. The
  # ExecCondition then skips re-acquisition because the directory exists.
  # Deleting the empty live/ directory forces certbot to re-run.
  log "    Checking for stale/empty cert files..."

  # Per-environment VMs and application VMs
  for ENV in prod dev; do
    for VM_KEY in $(yq -r ".vms | to_entries[] | select(.key | test(\"_${ENV}$\")) | .key" "$CONFIG" 2>/dev/null); do
      VM_IP=$(yq -r ".vms.${VM_KEY}.ip" "$CONFIG")
      check_empty_certs "$VM_IP" "$VM_KEY"
    done
    for APP_KEY in $(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG" 2>/dev/null); do
      VM_IP=$(yq -r ".applications.${APP_KEY}.environments.${ENV}.ip // \"\"" "$APPS_CONFIG")
      [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue
      check_empty_certs "$VM_IP" "${APP_KEY}_${ENV}"
    done
  done

  # Shared VMs (gitlab, gatus) - checked ONCE, not per-ENV
  for VM_KEY in gitlab gatus; do
    VM_IP=$(yq -r ".vms.${VM_KEY}.ip // \"\"" "$CONFIG")
    [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue
    check_empty_certs "$VM_IP" "$VM_KEY"
  done

  # Pre-flight 2: detect wrong-domain certs from PBS restore.
  # After a domain change, PBS restores certs for the old domain. Certbot's
  # ExecCondition sees the existing live/ directory and skips re-acquisition.
  # Compare cert directory names against the expected FQDN and clean mismatches.
  DOMAIN=$(yq -r '.domain' "$CONFIG")
  log "    Checking for wrong-domain certs (expected domain: ${DOMAIN})..."

  # Per-environment VMs and application VMs
  for ENV in prod dev; do
    for VM_KEY in $(yq -r ".vms | to_entries[] | select(.key | test(\"_${ENV}$\")) | .key" "$CONFIG" 2>/dev/null); do
      VM_IP=$(yq -r ".vms.${VM_KEY}.ip" "$CONFIG")
      # Extract hostname: vault_prod -> vault, dns1_dev -> dns1
      HOSTNAME=$(echo "$VM_KEY" | sed "s/_${ENV}$//")
      EXPECTED_FQDN="${HOSTNAME}.${ENV}.${DOMAIN}"
      check_cert_domain "$VM_IP" "$EXPECTED_FQDN" "$VM_KEY"
    done
    # Application VMs
    for APP_KEY in $(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG" 2>/dev/null); do
      VM_IP=$(yq -r ".applications.${APP_KEY}.environments.${ENV}.ip // \"\"" "$APPS_CONFIG")
      [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue
      EXPECTED_FQDN="${APP_KEY}.${ENV}.${DOMAIN}"
      check_cert_domain "$VM_IP" "$EXPECTED_FQDN" "${APP_KEY}_${ENV}"
    done
  done

  # Shared VMs (gitlab, gatus) - use prod domain, checked ONCE (not per-ENV)
  for VM_KEY in gitlab gatus; do
    VM_IP=$(yq -r ".vms.${VM_KEY}.ip // \"\"" "$CONFIG")
    [[ -z "$VM_IP" || "$VM_IP" == "null" ]] && continue
    EXPECTED_FQDN="${VM_KEY}.prod.${DOMAIN}"
    check_cert_domain "$VM_IP" "$EXPECTED_FQDN" "$VM_KEY"
  done

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
        log "    vault-${ENV} cert not ready after 2m - diagnosing..."

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
          log "    certbot-initial is inactive - restarting..."
          cert_ssh "$VAULT_IP" "rm -rf /etc/letsencrypt/live /etc/letsencrypt/archive /etc/letsencrypt/renewal; systemctl restart certbot-initial" || true
        fi

        # Check for empty certs (may have appeared since pre-flight)
        EMPTY=$(cert_ssh "$VAULT_IP" 'for d in /etc/letsencrypt/live/*/; do c="${d}fullchain.pem"; [ -e "$c" ] && [ ! -s "$c" ] && echo empty; done; true' || true)
        if [[ -n "$EMPTY" ]]; then
          log "    Empty cert files detected - cleaning up and restarting certbot..."
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
        die "Certificate acquisition failed - see diagnostics above"
      fi
      if (( elapsed > 0 && elapsed % 60 == 0 )); then
        log "    Still waiting for vault-${ENV} certificate... (${elapsed}s / ${CERT_TIMEOUT}s)"
      fi
      sleep "$CERT_INTERVAL"
      elapsed=$(( elapsed + CERT_INTERVAL ))
    done
  done

  step_done 9 "Certificates ready"
}

converge_step_vault() {
  local ENV=""

  if step_in_scope vault; then
    step_start 10 "Initialize Vault"
    for ENV in prod dev; do
      "${SCRIPT_DIR}/init-vault.sh" "$ENV"
    done
    step_done 10 "Vault initialized"

    step_start 11 "Configure Vault"
    for ENV in prod dev; do
      "${SCRIPT_DIR}/configure-vault.sh" "$ENV"
    done
    step_done 11 "Vault configured"
  else
    step_skip 10 "Vault init (not in scope)"
    step_skip 11 "Vault config (not in scope)"
  fi
}

converge_step_cert_backfill() {
  local env=""
  local target_envs=""

  converge_require_context

  if ! step_in_scope cert_backfill; then
    step_skip 11.5 "Cert storage backfill (not in scope)"
    return 0
  fi

  step_start 11.5 "Cert storage backfill"

  if ! target_envs="$(converge_target_envs)"; then
    log "ERROR: converge_step_cert_backfill: converge_target_envs failed (unrecognized scope token in TOFU_TARGETS=\"${TOFU_TARGETS:-}\"); refusing to skip silently per Goal 10" >&2
    return 1
  fi
  if [[ -z "${target_envs}" ]]; then
    step_skip 11.5 "cert_backfill: no env-specific work in scope (TOFU_TARGETS=\"${TOFU_TARGETS:-}\")"
    return 0
  fi

  for env in ${target_envs}; do
    log "    cert-storage backfill: ${env}"
    VAULT_ROOT_TOKEN="${VAULT_ROOT_TOKEN:-}" \
      "${SCRIPT_DIR}/cert-storage-backfill.sh" "${env}"
  done

  step_done 11.5 "Cert storage backfill complete"
}

converge_step_replication() {
  local park_status_file="${CONVERGE_PARK_STATUS_FILE:-}"
  local merged
  step_start 12 "Configure ZFS replication"

  if [[ -z "$park_status_file" && -n "${LOG_DIR:-}" ]]; then
    merged="${LOG_DIR}/vdb-park-status-converge.json"
    python3 - "$merged" "${LOG_DIR}"/vdb-park-status-*.json <<'PY'
import glob
import json
import os
import sys
from datetime import datetime, timezone

out = sys.argv[1]
entries = []
versions = {}
seen = set()
for pattern in sys.argv[2:]:
    for path in glob.glob(pattern):
        if os.path.basename(path) == os.path.basename(out):
            continue
        try:
            with open(path) as f:
                data = json.load(f)
        except Exception:
            continue
        for key, value in (data.get("qemu_server_versions") or {}).items():
            versions[key] = value
        for entry in data.get("entries") or []:
            vmid = entry.get("vmid")
            if vmid is None:
                continue
            # Later files from the same run replace earlier evidence for a VMID.
            if vmid in seen:
                entries = [e for e in entries if e.get("vmid") != vmid]
            seen.add(vmid)
            entries.append(entry)
if entries:
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump({
            "version": 1,
            "scope": "converge",
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "qemu_server_versions": versions,
            "entries": entries,
        }, f, indent=2)
        f.write("\n")
PY
    if [[ -s "$merged" ]]; then
      park_status_file="$merged"
    fi
  fi

  if [[ -n "$park_status_file" && -s "$park_status_file" ]]; then
    "${SCRIPT_DIR}/configure-replication.sh" "*" --park-status "$park_status_file"
  else
    "${SCRIPT_DIR}/configure-replication.sh" "*"
  fi
  step_done 12 "ZFS replication configured"
}

converge_step_gitlab() {
  if step_in_scope gitlab; then
    step_start 13 "Configure GitLab"
    "${SCRIPT_DIR}/configure-gitlab.sh"
    step_done 13 "GitLab configured"
  else
    step_skip 13 "GitLab config (not in scope)"
  fi
}

converge_step_runner() {
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
}

converge_step_sentinel() {
  local NAS_IP=""
  local NAS_SSH_USER=""
  local NAS_PUBKEY=""
  local NAS_KEY_ID=""
  local NI_IP=""
  local ni=0

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
}

converge_step_backups() {
  local PBS_IP=""

  if step_in_scope backups; then
    step_start 15.5 "Configure backup jobs"
    PBS_IP=$(yq -r '.vms.pbs.ip // ""' "$CONFIG")
    if [[ -n "$PBS_IP" && "$PBS_IP" != "null" ]] && \
       ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
         "root@${PBS_IP}" "true" 2>/dev/null; then
      "${SCRIPT_DIR}/configure-backups.sh"
      step_done 15.5 "Backup jobs configured"
    else
      step_skip 15.5 "PBS not reachable - backups not configured"
    fi
  else
    step_skip 15.5 "Backup jobs (not in scope)"
  fi
}

converge_step_metrics() {
  if step_in_scope metrics; then
    step_start 15.7 "Configure metrics"
    "${SCRIPT_DIR}/configure-metrics.sh"
    step_done 15.7 "Metrics configured"
  else
    step_skip 15.7 "Metrics (not in scope)"
  fi
}

converge_step_dashboard_tokens() {
  local env=""
  local target_envs=""
  local influx_enabled=""

  converge_require_context

  if ! step_in_scope dashboard_tokens; then
    step_skip 15.8 "Dashboard token provisioning (not in scope)"
    return 0
  fi

  step_start 15.8 "Dashboard token provisioning"

  influx_enabled="$(yq -r '.applications.influxdb.enabled // false' "${APPS_CONFIG}" 2>/dev/null || echo false)"
  if [[ "${influx_enabled}" != "true" ]]; then
    step_skip 15.8 "influxdb disabled in applications.yaml"
    return 0
  fi

  if ! target_envs="$(converge_target_envs)"; then
    log "ERROR: converge_step_dashboard_tokens: converge_target_envs failed (unrecognized scope token in TOFU_TARGETS=\"${TOFU_TARGETS:-}\"); refusing to skip silently per Goal 10" >&2
    return 1
  fi
  if [[ -z "${target_envs}" ]]; then
    step_skip 15.8 "dashboard_tokens: no env-specific work in scope (TOFU_TARGETS=\"${TOFU_TARGETS:-}\")"
    return 0
  fi

  for env in ${target_envs}; do
    "${SCRIPT_DIR}/configure-dashboard-tokens.sh" "${env}"
  done

  step_done 15.8 "Dashboard tokens provisioned"
}

converge_step_workstation_closure() {
  local env=""
  local target_envs=""
  local workstation_enabled=""

  converge_require_context

  if ! step_in_scope workstation_closure; then
    step_skip 15.9 "Workstation closure push (not in scope)"
    return 0
  fi

  step_start 15.9 "Workstation closure push"

  workstation_enabled="$(yq -r '.applications.workstation.enabled // false' "${APPS_CONFIG}" 2>/dev/null || echo false)"
  if [[ "${workstation_enabled}" != "true" ]]; then
    step_skip 15.9 "workstation disabled in applications.yaml"
    return 0
  fi

  if ! target_envs="$(converge_target_envs)"; then
    log "ERROR: converge_step_workstation_closure: converge_target_envs failed (unrecognized scope token in TOFU_TARGETS=\"${TOFU_TARGETS:-}\"); refusing to skip silently per Goal 10" >&2
    return 1
  fi
  if [[ -z "${target_envs}" ]]; then
    step_skip 15.9 "workstation_closure: no env-specific work in scope (TOFU_TARGETS=\"${TOFU_TARGETS:-}\")"
    return 0
  fi

  for env in ${target_envs}; do
    "${SCRIPT_DIR}/deploy-workstation-closure.sh" "${env}"
  done

  step_done 15.9 "Workstation closure pushed"
}

converge_run_all() {
  converge_require_context
  converge_step_closure
  converge_step_dns
  converge_step_certs
  converge_step_vault
  converge_step_cert_backfill
  converge_step_replication
  converge_step_gitlab
  converge_step_runner
  converge_step_sentinel
  converge_step_backups
  converge_step_metrics
  converge_step_dashboard_tokens
  converge_step_workstation_closure
}
