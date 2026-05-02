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
  local recognized_envless=(cicd pbs)
  local prod_only=(gitlab gatus)
  local envs=()
  local tok=""
  local module=""
  local matched=0
  local entry=""

  if [[ -z "${TOFU_TARGETS:-}" ]]; then
    printf '%s\n' "dev prod"
    return 0
  fi

  for tok in ${TOFU_TARGETS}; do
    module="${tok#-target=module.}"
    if [[ "${module}" == "${tok}" ]]; then
      converge_target_envs_error "converge_target_envs: malformed target token '${tok}' (expected -target=module.NAME)"
      return 1
    fi

    case "${module}" in
      *_dev)
        envs+=(dev)
        ;;
      *_prod)
        envs+=(prod)
        ;;
      *)
        matched=0
        for entry in "${prod_only[@]}"; do
          if [[ "${module}" == "${entry}" ]]; then
            envs+=(prod)
            matched=1
            break
          fi
        done
        if [[ "${matched}" -eq 0 ]]; then
          for entry in "${recognized_envless[@]}"; do
            if [[ "${module}" == "${entry}" ]]; then
              matched=1
              break
            fi
          done
        fi
        if [[ "${matched}" -eq 0 ]]; then
          converge_target_envs_error "converge_target_envs: unrecognized module '${module}' in TOFU_TARGETS"
          converge_target_envs_error "  recognized patterns: *_dev, *_prod, ${prod_only[*]}, ${recognized_envless[*]}"
          converge_target_envs_error "  if this is a new module class, add it to converge_target_envs allowlist"
          return 1
        fi
        ;;
    esac
  done

  if [[ "${#envs[@]}" -eq 0 ]]; then
    return 0
  fi

  printf '%s\n' "${envs[@]}" | awk '!seen[$0]++' | tr '\n' ' ' | sed 's/ $//'
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
# Called by converge_step_closure.
converge_fix_grub_paths() {
  local vm_ip="$1"
  cert_ssh "$vm_ip" "if [ -f /boot/grub/grub.cfg ]; then sed -i 's|)/store/|)/nix/store/|g' /boot/grub/grub.cfg; fi" \
    || die "Failed to fix grub paths on ${vm_ip}"
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
  local switch_poll=0
  local switch_max=600
  local switch_state=""
  while [[ $switch_poll -lt $switch_max ]]; do
    set +e
    switch_state=$(cert_ssh "$vm_ip" "systemctl show -p ActiveState -p SubState -p Result ${switch_unit} 2>/dev/null" || true)
    set -e
    if echo "$switch_state" | grep -qE "ActiveState=(inactive|failed)|SubState=exited"; then
      break
    fi
    sleep 3
    switch_poll=$((switch_poll + 3))
  done

  # Check result — fail closed on anything other than explicit success.
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
  # (e.g., live/gitlab -> gitlab.prod.wuertele.com created by
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
  step_start 12 "Configure ZFS replication"
  "${SCRIPT_DIR}/configure-replication.sh" "*"
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
