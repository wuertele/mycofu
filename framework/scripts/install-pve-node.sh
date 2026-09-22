#!/usr/bin/env bash
# install-pve-node.sh — Regreen one AMT-capable Proxmox node via hil-boot PXE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG=""
NODE=""
DRY_RUN=0
RUN_DIR="${MYCOFU_REGREENER_RUN_DIR:-${REPO_DIR}/build/regreen}"
LOG_FILE=""
KNOWN_HOSTS=""

usage() {
  cat <<'EOF'
Usage:
  install-pve-node.sh NODE [--config CONFIG] [--dry-run]
  install-pve-node.sh --node NODE [--config CONFIG] [--dry-run]

Exit codes:
  2 usage/config error
  3 missing dependency or hil-boot unavailable
  4 AMT auth/reachability/reset failure
  5 hil-boot artifact/service failure
  6 install timeout
  7 green predicate failure
EOF
}

exit_with() {
  local code="$1"; shift
  echo "ERROR: $*" >&2
  [[ -n "$LOG_FILE" ]] && echo "ERROR: $*" >> "$LOG_FILE"
  exit "$code"
}

log() {
  printf '[pxe-install] %s\n' "$*"
  [[ -n "$LOG_FILE" ]] && printf '[pxe-install] %s\n' "$*" >> "$LOG_FILE"
}

default_config() {
  find "${REPO_DIR}/tests/hil" -mindepth 2 -maxdepth 2 -name config.yaml 2>/dev/null | sort | head -1
}

cfg() {
  yq -r "$1" "$CONFIG"
}

node_cfg() {
  NODE="$NODE" yq -r ".nodes[] | select(.name == strenv(NODE)) | $1" "$CONFIG"
}

sops_path() {
  printf '%s/sops/secrets.yaml\n' "$(dirname "$CONFIG")"
}

read_sops_key() {
  local key="$1"
  local path
  path="$(sops_path)"
  [[ -f "$path" ]] || exit_with 2 "SOPS file not found: $path"
  local value
  value="$(sops -d --extract "[\"${key}\"]" "$path" 2>/dev/null || true)"
  [[ -n "$value" && "$value" != "null" ]] || return 1
  printf '%s\n' "$value"
}

require_tool() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1 || return 1
}

validate_site_config_for_regreener() {
  local apps_config
  apps_config="$(dirname "$CONFIG")/applications.yaml"
  VALIDATE_SITE_CONFIG_CONFIG="$CONFIG" \
  VALIDATE_SITE_CONFIG_APPS_CONFIG="$apps_config" \
    "${SCRIPT_DIR}/validate-site-config.sh"
}

quote_for_remote() {
  printf '%q' "$1"
}

ssh_hil_boot() {
  local hil_ssh="$1"; shift
  # hil-boot is rebuilt for this workflow, so trust first use in a per-run file.
  "${MYCOFU_SSH:-ssh}" -n \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o ConnectTimeout=10 \
    -o LogLevel=ERROR \
    "$hil_ssh" "$@"
}

tcp_probe() {
  local host="$1" port="$2" timeout_sec="${3:-3}"
  if [[ -n "${MYCOFU_TCP_PROBE:-}" ]]; then
    "$MYCOFU_TCP_PROBE" "$host" "$port" "$timeout_sec"
  else
    timeout "$timeout_sec" bash -c "</dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

http_head() {
  "${MYCOFU_CURL:-curl}" -fsI "$1" >/dev/null
}

ssh_probe() {
  local ip="$1"
  tcp_probe "$ip" 22 3
}

PVE_AUTH_COOKIE=""

# Proxmox API helpers. The regreen contract is "PVE installed per
# answer.toml"; verifying that does not need shell access — every
# property of interest (hostname, IP/CIDR, version, cluster state) is
# exposed by the Proxmox HTTPS API. Self-signed cert → -k. Tests inject
# a stub via MYCOFU_CURL.
pve_api_login() {
  local ip="$1" password="$2"
  local resp ticket
  resp="$("${MYCOFU_CURL:-curl}" -sk --max-time 10 -X POST \
    --data-urlencode "username=root@pam" \
    --data-urlencode "password=${password}" \
    "https://${ip}:8006/api2/json/access/ticket" 2>/dev/null)" || return 1
  ticket="$(jq -r '.data.ticket // empty' <<< "$resp" 2>/dev/null)" || return 1
  [[ -n "$ticket" ]] || return 1
  PVE_AUTH_COOKIE="PVEAuthCookie=${ticket}"
  return 0
}

pve_api_get() {
  local ip="$1" path="$2"
  [[ -n "$PVE_AUTH_COOKIE" ]] || return 1
  "${MYCOFU_CURL:-curl}" -sk --max-time 10 -b "$PVE_AUTH_COOKIE" \
    "https://${ip}:8006/api2/json${path}" 2>/dev/null
}

remote_meshcmd() {
  local hil_ssh="$1" amt_ip="$2" amt_user="$3" amt_password="$4"
  shift 4
  local quoted_password
  quoted_password="$(quote_for_remote "$amt_password")"
  ssh_hil_boot "$hil_ssh" "AMT_PASSWORD=${quoted_password}; export AMT_PASSWORD; meshcmd $* --host '${amt_ip}' --user '${amt_user}' --pass \"\$AMT_PASSWORD\""
}

parse_amt_power_state() {
  # Extract "Current power state: <STATE>\n" from meshcmd output. Strips
  # carriage returns because WS-MAN-bridging tools commonly emit CRLF.
  printf '%s\n' "$1" | tr -d '\r' | awk -F': ' '/[Pp]ower state/{print $NF; exit}'
}

# Poll AMT power state via `meshcmd amtpower --get` until it matches the
# expected literal state ("Power on", "Soft off") or the timeout elapses.
# Returns 0 on match, 1 on timeout, 2 on a remote_meshcmd transport error
# that recurred past a configurable transient tolerance.
#
# This polling replaces what was previously a single-shot --get (sub-claude
# P1 #2 + codex P1 #2 + gemini P1 #1). The poll closes the window in which a
# transient AMT/network hiccup could be misread as "transition didn't happen"
# AND the case where the AMT subsystem hasn't yet reflected the new state by
# the time we look.
wait_for_amt_state() {
  local hil_ssh="$1" amt_ip="$2" amt_user="$3" amt_password="$4"
  local expected_state="$5" timeout_sec="$6"
  local start now poll raw state transient
  poll="${MYCOFU_AMT_STATE_POLL_SEC:-3}"
  transient=0
  start="$(date +%s)"
  while true; do
    # Capture --get output without crashing the script if meshcmd or SSH
    # transiently fails (gemini P2 #2 + codex P2 #4): `set -e` would
    # otherwise kill the script at the command substitution.
    raw="$(remote_meshcmd "$hil_ssh" "$amt_ip" "$amt_user" "$amt_password" amtpower --get 2>&1 || true)"
    printf '%s\n' "$raw" >> "$LOG_FILE"
    state="$(parse_amt_power_state "$raw")"
    if [[ -n "$state" ]]; then
      transient=0
      if [[ "$state" == "$expected_state" ]]; then
        now="$(date +%s)"
        log "AMT reached '${expected_state}' after $((now - start))s"
        return 0
      fi
    else
      transient=$((transient + 1))
      log "AMT --get returned no parseable state (transient $transient)"
      if (( transient >= "${MYCOFU_AMT_TRANSIENT_LIMIT:-5}" )); then
        return 2
      fi
    fi
    now="$(date +%s)"
    (( now - start >= timeout_sec )) && return 1
    sleep "$poll"
  done
}

# Confirm the node actually PXE-booted by observing hil-boot's nginx access
# log serving /nodes/<NODE>/boot.ipxe to a User-Agent that contains iPXE.
# AMT's `--poweron --bootdevice pxe` is a one-shot override request; the
# `--get` post-state proves only that power transitioned, NOT that the
# boot device override actually took effect (sub-claude P1 #3 + codex P2
# #5). If `--bootdevice pxe` is silently dropped, the node powers on and
# boots from local disk; without this check we'd then wait the full
# install_timeout (1800s) for SSH that's not coming.
#
# We capture the byte offset of the access log BEFORE issuing --poweron
# and only consider entries past that offset, so a prior regreen attempt's
# nginx log line cannot be mistaken for fresh evidence.
wait_for_pxe_evidence() {
  local hil_ssh="$1" node="$2" timeout_sec="$3" pre_offset="$4"
  local start now poll
  poll="${MYCOFU_PXE_EVIDENCE_POLL_SEC:-5}"
  start="$(date +%s)"
  while true; do
    if ssh_hil_boot "$hil_ssh" "tail -c +$((pre_offset + 1)) /var/log/nginx/access.log 2>/dev/null | grep -qE 'GET /nodes/${node}/boot\.ipxe.*iPXE'"; then
      now="$(date +%s)"
      log "PXE evidence: hil-boot served /nodes/${node}/boot.ipxe to iPXE after $((now - start))s"
      return 0
    fi
    now="$(date +%s)"
    (( now - start >= timeout_sec )) && return 1
    sleep "$poll"
  done
}

wait_for_ssh_up() {
  local ip="$1" timeout_sec="$2"
  local start now poll
  poll="${MYCOFU_INSTALL_POLL_SEC:-10}"
  start="$(date +%s)"
  while true; do
    if ssh_probe "$ip"; then
      now="$(date +%s)"
      log "SSH :22 OPEN after $((now - start))s"
      return 0
    fi
    now="$(date +%s)"
    (( now - start >= timeout_sec )) && return 1
    sleep "$poll"
  done
}

wait_for_pve_web() {
  local ip="$1" timeout_sec="$2"
  local start now poll
  poll="${MYCOFU_PVE_WEB_POLL_SEC:-5}"
  start="$(date +%s)"
  while true; do
    if tcp_probe "$ip" 8006 3; then
      log "PVE web :8006 OPEN"
      return 0
    fi
    now="$(date +%s)"
    (( now - start >= timeout_sec )) && return 1
    sleep "$poll"
  done
}

verify_green() {
  local ip="$1" password="$2" node_name="$3" fqdn="$4" cidr="$5" expected_version="$6"
  local status_resp network_resp cluster_resp version cidr_match cluster_marker
  # fqdn is accepted but unused — the regreen contract does not promise an
  # FQDN check that the Proxmox HTTPS API cleanly exposes (hostname -f
  # reads /etc/hostname + resolv.conf inside the guest; the API surfaces
  # short name via /nodes/<name>). Keep the parameter so callers don't
  # change signatures; document the intentional skip.
  : "$fqdn"

  if ! pve_api_login "$ip" "$password"; then
    log "${node_name}: Proxmox API login failed at ${ip}:8006"
    return 1
  fi

  # Short hostname: a successful GET at /nodes/<name>/status confirms
  # PVE responds to the expected node name.
  status_resp="$(pve_api_get "$ip" "/nodes/${node_name}/status")"
  if ! jq -e '.data.pveversion' >/dev/null 2>&1 <<< "$status_resp"; then
    log "${node_name}: /nodes/${node_name}/status did not return expected data"
    return 1
  fi
  log "${node_name}: hostname via API: ${node_name}"

  # pveversion check.
  version="$(jq -r '.data.pveversion // empty' <<< "$status_resp" 2>/dev/null)"
  [[ "$version" == "$expected_version"* ]] || { log "${node_name}: pveversion mismatch: ${version}"; return 1; }
  log "${node_name}: pveversion: ${version}"

  # Management CIDR: list the node's network interfaces; any matching
  # cidr field is sufficient (typically vmbr0 holds the management IP).
  network_resp="$(pve_api_get "$ip" "/nodes/${node_name}/network")"
  cidr_match="$(jq -r --arg cidr "$cidr" '[.data[]? | select(.cidr == $cidr)] | length' <<< "$network_resp" 2>/dev/null || printf '0')"
  if [[ "$cidr_match" != "1" && "$cidr_match" != "2" && "$cidr_match" != "3" ]]; then
    log "${node_name}: missing management CIDR ${cidr}"
    return 1
  fi
  log "${node_name}: management CIDR: ${cidr}"

  # Cluster state: a fresh non-clustered install responds with a single
  # entry of type=node; a clustered install also returns a type=cluster
  # entry. Treat any type=cluster entry as "this is not green".
  cluster_resp="$(pve_api_get "$ip" "/cluster/status")"
  cluster_marker="$(jq -r '[.data[]? | select(.type == "cluster")] | length' <<< "$cluster_resp" 2>/dev/null || printf '0')"
  if [[ "$cluster_marker" != "0" ]]; then
    log "${node_name}: cluster membership detected"
    return 1
  fi
  log "${node_name}: cluster membership: none"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="$2"; shift 2 ;;
    --node) NODE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "$NODE" ]]; then
        NODE="$1"
        shift
      else
        echo "ERROR: unexpected argument: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

[[ -n "$CONFIG" ]] || CONFIG="$(default_config)"
[[ -n "$CONFIG" ]] || exit_with 2 "no default HIL config found under tests/hil"
[[ -n "$NODE" ]] || exit_with 2 "node is required"
[[ -f "$CONFIG" ]] || exit_with 2 "config not found: $CONFIG"

for tool in bash yq jq sops timeout; do
  require_tool "$tool" || exit_with 3 "required tool not found: $tool"
done

if ! validate_site_config_for_regreener; then
  exit_with 2 "config validation failed: $CONFIG"
fi
if ! NODE="$NODE" yq -e '.nodes[] | select(.name == strenv(NODE))' "$CONFIG" >/dev/null 2>&1; then
  exit_with 2 "node '${NODE}' not found in $CONFIG"
fi

mkdir -p "$RUN_DIR"
LOG_FILE="${RUN_DIR}/${NODE}.log"
KNOWN_HOSTS="${RUN_DIR}/known_hosts"
touch "$LOG_FILE" "$KNOWN_HOSTS"
chmod 0600 "$LOG_FILE" "$KNOWN_HOSTS" 2>/dev/null || true

REGREEN_ENABLED="$(node_cfg '.regreen_enabled // false')"
[[ "$REGREEN_ENABLED" == "true" ]] || exit_with 2 "node ${NODE} is not regreen_enabled"

DOMAIN="$(cfg '.domain')"
MGMT_IP="$(node_cfg '.mgmt_ip')"
MGMT_PREFIX="$(cfg '.management.subnet | split("/")[1]')"
MGMT_CIDR="${MGMT_IP}/${MGMT_PREFIX}"
AMT_IP="$(node_cfg '.amt_ip // ""')"
AMT_USER="$(node_cfg '.amt_user // "admin"')"
AMT_REF="$(node_cfg '.amt_password_ref // ""')"
EXPECTED_VERSION="$(cfg '.proxmox.installer.expected_version // "pve-manager"')"
SSH_TIMEOUT="$(cfg '.regreener.ssh_timeout_sec // 600')"
INSTALL_TIMEOUT="$(cfg '.regreener.install_timeout_sec // 1800')"
FQDN="${NODE}.${DOMAIN}"
HIL_BOOT_IP="$(yq -r '.vms.hil_boot.ip // ""' "${REPO_DIR}/site/config.yaml")"
HIL_BOOT_SSH="${MYCOFU_HIL_BOOT_SSH:-root@${HIL_BOOT_IP}}"
HIL_BOOT_HTTP="${MYCOFU_HIL_BOOT_HTTP:-http://${HIL_BOOT_IP}}"

[[ -n "$AMT_IP" && "$AMT_IP" != "null" ]] || exit_with 2 "node ${NODE} missing amt_ip"
[[ -n "$AMT_REF" && "$AMT_REF" != "null" ]] || exit_with 2 "node ${NODE} missing amt_password_ref"
[[ -n "$HIL_BOOT_IP" && "$HIL_BOOT_IP" != "null" ]] || exit_with 3 "site/config.yaml missing vms.hil_boot.ip"

AMT_PASSWORD="$(read_sops_key "$AMT_REF")" || exit_with 2 "SOPS key ${AMT_REF} missing or empty"
ROOT_PASSWORD="$(read_sops_key proxmox_api_password)" || exit_with 2 "SOPS key proxmox_api_password missing or empty"

log "[PASS] config: ${CONFIG}"
log "[PASS] node ${NODE} regreen_enabled"
log "[PASS] SOPS key ${AMT_REF} present"
log "[PASS] SOPS key proxmox_api_password present"

if ! ssh_hil_boot "$HIL_BOOT_SSH" "hil-boot-status" >> "$LOG_FILE" 2>&1; then
  exit_with 3 "hil-boot unavailable over SSH: ${HIL_BOOT_SSH}"
fi
log "[PASS] hil-boot SSH status OK"

amt_probe() {
  ssh_hil_boot "$HIL_BOOT_SSH" "timeout 5 bash -c '</dev/tcp/${AMT_IP}/16992'" >> "$LOG_FILE" 2>&1
}

if ! amt_probe; then
  # AMT/ME firmware sometimes wedges into a state where port 16992 stops
  # responding (observed on the M920q rack post-extended-uptime). The
  # sanctioned recovery is a hard power-cycle via the APC PDU: BIOS POST
  # reinitializes the ME firmware and AMT typically comes back. Try that
  # once before giving up.
  log "[WARN] AMT ${AMT_IP}:16992 unreachable from hil-boot; attempting PDU power-cycle recovery"
  PDU_RECOVER_WAIT="${MYCOFU_AMT_RECOVER_WAIT_SEC:-180}"
  PDU_HELPER="${MYCOFU_PDU_CYCLE:-${SCRIPT_DIR}/pdu-cycle.sh}"
  if "$PDU_HELPER" "$NODE" --config "$CONFIG" >> "$LOG_FILE" 2>&1; then
    log "[INFO] PDU cycle issued for ${NODE}; waiting ${PDU_RECOVER_WAIT}s for ME firmware to come up"
    sleep "$PDU_RECOVER_WAIT"
    if amt_probe; then
      log "[PASS] AMT ${AMT_IP} reachable from hil-boot (recovered via PDU cycle)"
    else
      exit_with 4 "AMT ${AMT_IP}:16992 still unreachable after PDU cycle of ${NODE}"
    fi
  else
    exit_with 4 "AMT ${AMT_IP}:16992 unreachable and PDU cycle failed for ${NODE}"
  fi
else
  log "[PASS] AMT ${AMT_IP} reachable from hil-boot"
fi

if ! http_head "${HIL_BOOT_HTTP}/nodes/${NODE}/boot.ipxe"; then
  exit_with 5 "hil-boot missing boot.ipxe for ${NODE}"
fi
if ! http_head "${HIL_BOOT_HTTP}/nodes/${NODE}/proxmox.iso"; then
  exit_with 5 "hil-boot missing proxmox.iso for ${NODE}"
fi
log "[PASS] hil-boot HTTP artifacts present for ${NODE}"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log "[DRY-RUN] would heal AMT redirection features"
  log "[DRY-RUN] would converge node via --poweroff, --poweron --bootdevice pxe, then poll for PXE evidence"
  log "[DRY-RUN] would wait for SSH up at ${MGMT_IP}"
  exit 0
fi

log "amtfeatures: redir 1, kvm 1"
if ! remote_meshcmd "$HIL_BOOT_SSH" "$AMT_IP" "$AMT_USER" "$AMT_PASSWORD" amtfeatures --redir 1 --kvm 1 >> "$LOG_FILE" 2>&1; then
  exit_with 4 "${NODE}: AMT feature heal failed"
fi

# Converge the node to "powered on, PXE-booting" regardless of starting
# state. The regreen contract is: a failed regreen leaving the node
# soft-off must NOT make the next regreen fail. The historical --reset
# path was history-dependent — silently no-op on soft-off nodes, AND
# on any node where the original AMT command was silently rejected
# (false-green via SSH probe finding old PVE).
#
# Convergent flow:
#   1. amtpower --get        (informational logging)
#   2. amtpower --poweroff   (idempotent — may exit non-zero if already off)
#   3. poll --get → "Soft off" with timeout — LOAD-BEARING. Without this,
#      a silently-failed --poweroff would leave the node running and the
#      subsequent --poweron would no-op, with verify_green then succeeding
#      against the OLD PVE install (false green).
#   4. amtpower --poweron --bootdevice pxe   (must succeed)
#   5. poll --get → "Power on" with timeout — LOAD-BEARING.
#   6. PXE evidence check — poll hil-boot nginx access log for a fetch of
#      /nodes/<NODE>/boot.ipxe by iPXE. Proves --bootdevice pxe actually
#      took effect; catches the case where --poweron is accepted but the
#      boot-device override is silently dropped, which would otherwise
#      manifest as the same 30-minute SSH timeout this rewrite targets.
#   7. wait_for_ssh_up                       (existing — install completion)
#
# wait_for_ssh_down (the old false-success guard) is intentionally removed:
# it was history-dependent (required the node to have had SSH up before
# the regreen). The "wait_for_amt_state Soft off" poll in step 3 plus the
# PXE evidence in step 6 together provide stronger evidence than the old
# SSH-down check ever did, without depending on prior history.
#
# Flag names: the meshcmd primitives on this hardware are `--poweron`,
# `--poweroff`, `--get`, and `--reset --bootdevice pxe`, per the
# m920q-amt-investigation report (line 372) and the sprint-034 retro.
# meshcmd's flag parser silently accepts unknown flags and degrades to
# `--get`; using `--on`/`--off` instead of `--poweron`/`--poweroff`
# (mistake caught by codex review of MR !291 commit 32ea213) would
# silently no-op and produce false-green on already-on nodes.

log "Querying AMT power state (informational)"
remote_meshcmd "$HIL_BOOT_SSH" "$AMT_IP" "$AMT_USER" "$AMT_PASSWORD" amtpower --get >> "$LOG_FILE" 2>&1 || \
  log "AMT --get returned non-zero; AMT may not be reachable"

# Capture nginx access log offset BEFORE --poweron so the PXE-evidence
# poll later doesn't false-positive on a previous regreen's log entry.
log "Capturing hil-boot nginx access log offset for PXE-evidence baseline"
pre_pxe_offset="$(ssh_hil_boot "$HIL_BOOT_SSH" "stat -c %s /var/log/nginx/access.log 2>/dev/null || echo 0" 2>/dev/null || echo 0)"
# Defensive: if the offset isn't a non-negative integer, fall back to 0
# (treat full log as fresh). Better to false-positive on a stale entry
# than to refuse to converge.
if ! [[ "$pre_pxe_offset" =~ ^[0-9]+$ ]]; then
  log "WARNING: could not read nginx access log offset (got: '${pre_pxe_offset}'); using 0"
  pre_pxe_offset=0
fi
log "PXE-evidence baseline offset: ${pre_pxe_offset}"

log "Issuing AMT --poweroff to converge to powered-off"
remote_meshcmd "$HIL_BOOT_SSH" "$AMT_IP" "$AMT_USER" "$AMT_PASSWORD" amtpower --poweroff >> "$LOG_FILE" 2>&1 || \
  log "AMT --poweroff returned non-zero (already off?), continuing — verifying state next"

log "Polling AMT --get until 'Soft off' (timeout: ${MYCOFU_AMT_OFF_TIMEOUT:-60}s)"
# Run wait_for_amt_state in normal command position so its log() output
# reaches the operator. Capture exit code via `|| rc=$?` rather than
# `if !` — under `if !`, `$?` inside the then-branch is the exit code
# of `!` (always 0 if the test was true), not the function's exit code.
rc_off=0
wait_for_amt_state "$HIL_BOOT_SSH" "$AMT_IP" "$AMT_USER" "$AMT_PASSWORD" "Soft off" "${MYCOFU_AMT_OFF_TIMEOUT:-60}" || rc_off=$?
case "$rc_off" in
  0) ;;
  1) exit_with 4 "${NODE}: AMT never reached 'Soft off' within ${MYCOFU_AMT_OFF_TIMEOUT:-60}s after --poweroff (--poweroff may have been silently dropped — would have produced false-green via SSH probe finding old PVE)" ;;
  2) exit_with 4 "${NODE}: AMT --get failed repeatedly during off-state poll (AMT unreachable?)" ;;
  *) exit_with 4 "${NODE}: off-state poll failed with unexpected rc=${rc_off}" ;;
esac

# Brief settle so the ME firmware fully clears the off transition before
# we issue --poweron. M920q AMT sometimes refuses --poweron immediately
# after --poweroff with "Error, status 600" until the OS-off transition
# is fully reflected internally.
sleep "${MYCOFU_AMT_OFF_TO_ON_SETTLE_SEC:-5}"

log "Issuing AMT --poweron --bootdevice pxe (load-bearing)"
if ! remote_meshcmd "$HIL_BOOT_SSH" "$AMT_IP" "$AMT_USER" "$AMT_PASSWORD" amtpower --poweron --bootdevice pxe >> "$LOG_FILE" 2>&1; then
  exit_with 4 "${NODE}: AMT --poweron --bootdevice pxe failed"
fi

log "Polling AMT --get until 'Power on' (timeout: ${MYCOFU_AMT_ON_TIMEOUT:-60}s)"
rc_on=0
wait_for_amt_state "$HIL_BOOT_SSH" "$AMT_IP" "$AMT_USER" "$AMT_PASSWORD" "Power on" "${MYCOFU_AMT_ON_TIMEOUT:-60}" || rc_on=$?
case "$rc_on" in
  0) ;;
  1) exit_with 4 "${NODE}: AMT never reached 'Power on' within ${MYCOFU_AMT_ON_TIMEOUT:-60}s after --poweron (--poweron may have been silently dropped, or hardware failed to power on)" ;;
  2) exit_with 4 "${NODE}: AMT --get failed repeatedly during on-state poll" ;;
  *) exit_with 4 "${NODE}: on-state poll failed with unexpected rc=${rc_on}" ;;
esac

log "Polling hil-boot nginx for /nodes/${NODE}/boot.ipxe fetch (timeout: ${MYCOFU_PXE_EVIDENCE_TIMEOUT:-300}s)"
if ! wait_for_pxe_evidence "$HIL_BOOT_SSH" "$NODE" "${MYCOFU_PXE_EVIDENCE_TIMEOUT:-300}" "$pre_pxe_offset"; then
  exit_with 6 "${NODE}: hil-boot never served /nodes/${NODE}/boot.ipxe to iPXE within ${MYCOFU_PXE_EVIDENCE_TIMEOUT:-300}s — PXE boot did not start (bootdevice override silently dropped, BIOS POST stuck, or PXE NIC misconfigured)"
fi

ssh-keygen -R "$MGMT_IP" >/dev/null 2>&1 || true

log "Polling SSH :22 on ${MGMT_IP}"
if ! wait_for_ssh_up "$MGMT_IP" "$INSTALL_TIMEOUT"; then
  exit_with 6 "${NODE}: SSH did not return before install timeout (${INSTALL_TIMEOUT}s)"
fi

log "Polling PVE web :8006 on ${MGMT_IP}"
if ! wait_for_pve_web "$MGMT_IP" 300; then
  exit_with 6 "${NODE}: PVE web did not open after SSH returned"
fi

if ! verify_green "$MGMT_IP" "$ROOT_PASSWORD" "$NODE" "$FQDN" "$MGMT_CIDR" "$EXPECTED_VERSION"; then
  exit_with 7 "${NODE}: green predicate failed"
fi

log "SUCCESS: ${NODE} installed via PXE."
