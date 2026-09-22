#!/usr/bin/env bash
# backup-now.sh — Immediately back up all precious-state VMs to PBS.
#
# Usage:
#   framework/scripts/backup-now.sh
#   framework/scripts/backup-now.sh --env dev
#   framework/scripts/backup-now.sh --env all --verify
#   framework/scripts/backup-now.sh --env prod --pin-out build/restore-pin-prod.json
#   framework/scripts/backup-now.sh --env dev --skip-vmid 303
#
# Reads config.yaml for all VMs with backup: true (infrastructure and
# applications), checks that each selected VM is healthy enough to snapshot,
# then runs vzdump and records the exact PBS volid in a pin file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
VM_SCOPE_SCRIPT="${SCRIPT_DIR}/vm-scope.sh"
CONTROL_PLANE_MODULES="$("${VM_SCOPE_SCRIPT}" control-plane-modules)"
source "${SCRIPT_DIR}/certbot-cluster.sh"
source "${SCRIPT_DIR}/vm-health-lib.sh"

BACKUP_ENV="all"
PIN_OUT="${REPO_DIR}/build/restore-pin.json"
VERIFY=0
SKIP_VMIDS=""
PIN_MAP_FILE="$(mktemp "${TMPDIR:-/tmp}/backup-now-pins.XXXXXX")"
trap 'rm -f "${PIN_MAP_FILE}"' EXIT
CERTBOT_TRUST_RECORDS=""
# Ghost-backup rejection layers stacked in this script:
#
#   1. Per-VM freshness anchor (#547, refined by #602).
#      `backup_vm()` samples a per-VM epoch from the PBS_AVAIL SSH hop
#      (a Proxmox node — see #592 and the sample_pbs_epoch docstring for
#      why it is NOT the PBS server itself) immediately before invoking
#      vzdump for that VM, then sleeps 1 s so any real backup's ctime
#      lands in a strictly later PBS-second than the anchor. Every
#      newly-recorded PBS snapshot's ctime must be
#      STRICTLY > its VM's pre-vzdump epoch. This closes the CROSS-VM
#      race: a concurrent PBS-scheduled backup for VM C that landed while
#      backup-now.sh was still working on an earlier VM has ctime <= the
#      per-C anchor and is rejected. NEVER relax the strict > check to >=
#      — doing so reopens the silent-drop + same-second ghost window (#97
#      / FG-11 / #602). The pre-vzdump epoch is threaded into the pin map
#      (7th column) so `verify_backup_pins` (--verify pass) re-uses the
#      same per-VM anchor rather than falling back to a run-wide value.
#
#   2. Per-run identity marker (#591 — closes the residual SAME-VM window).
#      The anchor alone cannot catch the case where a PBS-scheduled backup
#      for the SAME VM X fires during our vzdump-in-flight interval and
#      lands with ctime > pre_vzdump_epoch. If our vzdump is silently
#      dropped (FG-11) but the scheduled snapshot landed, the volid-diff
#      picks up exactly one new volid whose ctime satisfies the freshness
#      gate — but which is not ours. The identity marker fixes this by
#      switching the gate from freshness alone to freshness AND ownership:
#      backup_vm() invokes vzdump with `--notes-template '${BACKUP_NOW_MARKER}'`
#      where BACKUP_NOW_MARKER embeds a per-run BACKUP_NOW_RUN_ID. The
#      post-vzdump gate then requires the newly-recorded volid's PBS
#      `notes` field to contain BACKUP_NOW_MARKER — proving OWNERSHIP,
#      not just freshness. The MANAGED_MARKER used by the scheduled
#      vzdump job (configure-backups.sh) is deliberately a different
#      string, so scheduled snapshots that land during our window are
#      rejected by the identity gate rather than pinned as ours.
#      BACKUP_NOW_RUN_ID is 32 hex chars (128 bits of entropy) so the
#      marker cannot collide with any prior run's marker either.
#
# The two layers are independent: layer 1 catches the freshness class,
# layer 2 catches the ownership class. Removing either reopens a
# ghost-backup window.
BACKUP_NOW_RUN_ID="$(openssl rand -hex 16 2>/dev/null || od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
# Fail closed if entropy sourcing failed (openssl AND /dev/urandom both
# unavailable — jails, container escape from urandom, virtio-rng blocked).
# An empty BACKUP_NOW_RUN_ID collapses BACKUP_NOW_MARKER to a stable
# literal prefix that every backup-now.sh run would share, defeating
# the ownership check: two concurrent runs would false-pass each other's
# backups, and any leftover snapshot from a prior empty-marker run
# would be silently pinned. Assert we have real entropy instead of
# quietly degrading the safety gate. The regex requires exactly 32 hex
# chars — matches `openssl rand -hex 16` / od output length — so a
# partial-write truncation (e.g. tr consumed some bytes but not all)
# also fails.
if [[ ! "$BACKUP_NOW_RUN_ID" =~ ^[0-9a-f]{32}$ ]]; then
  echo "ERROR: failed to generate BACKUP_NOW_RUN_ID (openssl and /dev/urandom both unavailable, or output truncated); refusing to run without a per-run identity marker" >&2
  exit 1
fi
# The marker embedded in vzdump --notes-template. Format mirrors
# configure-backups.sh's MANAGED_MARKER for grep-ability from PBS-side
# tooling ("automated by backup-now.sh" points an operator at the right
# script; "run=<hex>" makes the specific invocation identifiable). ASCII
# only — see the MANAGED_MARKER comment in configure-backups.sh for the
# Wide-character round-trip defect that motivates the ASCII-only rule.
BACKUP_NOW_MARKER="Ad-hoc capture -- automated by backup-now.sh run=${BACKUP_NOW_RUN_ID}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      BACKUP_ENV="$2"
      shift 2
      ;;
    --verify)
      VERIFY=1
      shift
      ;;
    --pin-out)
      PIN_OUT="$2"
      shift 2
      ;;
    --skip-vmid)
      SKIP_VMIDS="${SKIP_VMIDS} $2"
      shift 2
      ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$BACKUP_ENV" != "dev" && "$BACKUP_ENV" != "prod" && "$BACKUP_ENV" != "all" ]]; then
  echo "ERROR: --env must be one of: dev, prod, all" >&2
  exit 1
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.yaml not found: $CONFIG" >&2
  exit 1
fi

mkdir -p "$(dirname "$PIN_OUT")"
jq -n --arg captured_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{version: 1, captured_at: $captured_at, pins: {}}' > "$PIN_OUT"

NODE_IPS=$(yq -r '.nodes[].mgmt_ip' "$CONFIG")
STORAGE_POOL=$(yq -r '.proxmox.storage_pool // "vmstore"' "$CONFIG")
export VM_HEALTH_STORAGE_POOL="$STORAGE_POOL"
FIRST_DEPLOY_SKIP_VMIDS=""

backup_env_matches_label() {
  local label="$1"

  case "$BACKUP_ENV" in
    all)
      return 0
      ;;
  esac

  # Env-scoped CI backups intentionally stop at the Tier 1/Tier 2 boundary.
  # The pipeline cannot recreate gitlab/cicd/pbs, so letting their health
  # block a dev/prod data-plane deploy adds coupling without a restore path.
  # `--env all` remains the workstation flow for full-cluster backups.
  if printf '%s\n' "$CONTROL_PLANE_MODULES" | grep -Fxq "module.${label}"; then
    return 1
  fi

  case "$BACKUP_ENV" in
    dev)
      [[ "$label" != *_prod ]]
      ;;
    prod)
      [[ "$label" != *_dev ]]
      ;;
  esac
}

mark_first_deploy_skip() {
  local vmid="$1"

  case " ${FIRST_DEPLOY_SKIP_VMIDS} " in
    *" ${vmid} "*)
      ;;
    *)
      FIRST_DEPLOY_SKIP_VMIDS="${FIRST_DEPLOY_SKIP_VMIDS} ${vmid}"
      ;;
  esac
}

first_deploy_skip_marked() {
  local vmid="$1"

  case " ${FIRST_DEPLOY_SKIP_VMIDS} " in
    *" ${vmid} "*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

skip_vmid_marked() {
  local vmid="$1"

  case " ${SKIP_VMIDS} " in
    *" ${vmid} "*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

find_host_ip_for_vmid() {
  local vmid="$1"
  local ip=""

  for ip in $NODE_IPS; do
    if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${ip}" "qm status ${vmid}" >/dev/null 2>&1; then
      echo "$ip"
      return 0
    fi
  done

  return 1
}

collect_backup_records() {
  local vm_key=""
  local app_key=""
  local env_key=""
  local vmid=""
  local vm_ip=""
  local label=""

  while IFS= read -r vm_key; do
    [[ -z "$vm_key" ]] && continue
    label="$vm_key"
    backup_env_matches_label "$label" || continue
    vmid=$(yq -r ".vms.${vm_key}.vmid" "$CONFIG")
    vm_ip=$(yq -r ".vms.${vm_key}.ip" "$CONFIG")
    printf '%s\t%s\t%s\t%s\n' "$vm_key" "$label" "$vmid" "$vm_ip"
  done < <(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG")

  while IFS= read -r app_key; do
    [[ -z "$app_key" ]] && continue
    while IFS= read -r env_key; do
      [[ -z "$env_key" ]] && continue
      label="${app_key}_${env_key}"
      backup_env_matches_label "$label" || continue
      vmid=$(yq -r ".applications.${app_key}.environments.${env_key}.vmid // \"\"" "$APPS_CONFIG")
      # Prefer the management NIC when present: backup health checks run from
      # the management network, and some apps intentionally expose SSH there.
      vm_ip=$(yq -r ".applications.${app_key}.environments.${env_key}.mgmt_nic.ip // .applications.${app_key}.environments.${env_key}.ip // \"\"" "$APPS_CONFIG")
      [[ -z "$vmid" || "$vmid" == "null" || -z "$vm_ip" || "$vm_ip" == "null" ]] && continue
      printf '%s\t%s\t%s\t%s\n' "$label" "$label" "$vmid" "$vm_ip"
    done < <(yq -r ".applications.${app_key}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null)
  done < <(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null)
}

warn_unknown_skip_vmids() {
  local skip_vmid=""
  local vm_key label vmid vm_ip
  local matched=0

  for skip_vmid in $SKIP_VMIDS; do
    [[ -z "$skip_vmid" ]] && continue
    matched=0
    while IFS=$'\t' read -r vm_key label vmid vm_ip; do
      [[ -z "$label" ]] && continue
      if [[ "$vmid" == "$skip_vmid" ]]; then
        matched=1
        break
      fi
    done < <(collect_backup_records)

    if [[ "$matched" -eq 0 ]]; then
      echo "WARNING: --skip-vmid ${skip_vmid} did not match any selected backup-backed VM for --env ${BACKUP_ENV}; continuing" >&2
    fi
  done
}

# Query the PBS content listing via `pvesh` on a Proxmox node.
#
# The remote command is a `pvesh get /nodes/<hostname>/storage/pbs-nas/
# content` call resolved to the local host on the receiving side. Because
# pveproxy on any pbs-nas-carrying node can serve this endpoint, we don't
# need SSH access to the PBS appliance itself; PBS_AVAIL is a PROXMOX
# NODE (see the PBS_AVAIL assignment block for the discovery loop, and
# #592 for why this distinction matters — the freshness anchor sampled
# from this same hop depends on Proxmox↔PBS NTP alignment).
pbs_content_json() {
  ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${PBS_AVAIL}" \
    "pvesh get /nodes/\$(hostname)/storage/pbs-nas/content --output-format json 2>/dev/null"
}

pbs_historical_backup_exists() {
  local vmid="$1"
  local json="$2"

  if jq -e --arg vmid "$vmid" 'any(.[]?; (.vmid | tostring) == $vmid)' >/dev/null 2>&1 <<< "$json"; then
    return 0
  fi

  if jq empty >/dev/null 2>&1 <<< "$json"; then
    return 1
  fi

  echo "ERROR: Could not parse PBS content JSON while checking VMID ${vmid}" >&2
  exit 1
}

capture_new_backup_volids() {
  local before_json="$1"
  local after_json="$2"
  local vmid="$3"

  BEFORE_JSON="$before_json" AFTER_JSON="$after_json" TARGET_VMID="$vmid" python3 - <<'PY'
import json
import os

vmid = int(os.environ["TARGET_VMID"])
before = {
    entry.get("volid")
    for entry in json.loads(os.environ["BEFORE_JSON"])
    if entry.get("vmid") == vmid and entry.get("volid")
}
after = sorted(
    {
        entry.get("volid")
        for entry in json.loads(os.environ["AFTER_JSON"])
        if entry.get("vmid") == vmid and entry.get("volid")
    }
    - before
)
for volid in after:
    print(volid)
PY
}

pin_file_set() {
  local vmid="$1"
  local volid="$2"
  local trust="$3"
  local days_remaining="$4"
  local near_expiry="$5"
  local reason="$6"
  local tmp_file=""

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/restore-pin.XXXXXX")"
  jq \
    --arg vmid "$vmid" \
    --arg volid "$volid" \
    --arg trust "$trust" \
    --argjson days_remaining "$days_remaining" \
    --argjson near_expiry "$near_expiry" \
    --arg reason "$reason" \
    '.pins[$vmid] = ({
      volid: $volid,
      trust: $trust,
      days_remaining: $days_remaining,
      near_expiry: $near_expiry
    } + if $reason == "" then {} else {reason: $reason} end)' \
    "$PIN_OUT" > "$tmp_file"
  mv "$tmp_file" "$PIN_OUT"
}

pin_map_set() {
  local vmid="$1"
  local volid="$2"
  local trust="$3"
  local days_remaining="$4"
  local near_expiry="$5"
  local reason="$6"
  # #547: per-VM freshness anchor threaded through the pin map so the
  # --verify second pass can gate on the same lower bound as the initial
  # capture-time check.
  local pre_vzdump_epoch="$7"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$vmid" "$volid" "$trust" "$days_remaining" "$near_expiry" "$reason" "$pre_vzdump_epoch" >> "$PIN_MAP_FILE"
}

pin_file_write_from_map() {
  local vmid=""
  local volid=""
  local trust=""
  local days_remaining=""
  local near_expiry=""
  local reason=""
  local pre_vzdump_epoch=""
  local tmp_file=""

  # Read 7 columns (7th is the #547 per-VM freshness anchor). This helper
  # only writes to the JSON pin file; it does not re-verify freshness, so
  # the epoch is read to advance the field cursor and then discarded.
  while IFS=$'\t' read -r vmid volid trust days_remaining near_expiry reason pre_vzdump_epoch; do
    [[ -z "$vmid" || -z "$volid" ]] && continue
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/restore-pin.XXXXXX")"
    jq \
      --arg vmid "$vmid" \
      --arg volid "$volid" \
      --arg trust "$trust" \
      --argjson days_remaining "$days_remaining" \
      --argjson near_expiry "$near_expiry" \
      --arg reason "$reason" \
      '.pins[$vmid] = ({
        volid: $volid,
        trust: $trust,
        days_remaining: $days_remaining,
        near_expiry: $near_expiry
      } + if $reason == "" then {} else {reason: $reason} end)' \
      "$PIN_OUT" > "$tmp_file"
    mv "$tmp_file" "$PIN_OUT"
  done < "$PIN_MAP_FILE"
}

field_from_probe_output() {
  local output="$1"
  local key="$2"
  awk -F '=' -v key="$key" '$1 == key { sub(/^[^=]*=/, "", $0); print; exit }' <<< "$output"
}

certbot_record_for_label() {
  local label="$1"
  local record_label module_name ip_addr vmid fqdn kind

  while IFS=$'\t' read -r record_label module_name ip_addr vmid fqdn kind; do
    [[ -z "$record_label" ]] && continue
    if [[ "$record_label" == "$label" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$record_label" "$module_name" "$ip_addr" "$vmid" "$fqdn" "$kind"
      return 0
    fi
  done <<< "$CERTBOT_TRUST_RECORDS"

  return 1
}

collect_certbot_trust_marker() {
  local label="$1"
  local vm_ip="$2"
  local record=""
  local fqdn=""
  local output=""
  local rc=0
  local reason=""
  local days_remaining=""
  local near_expiry=""

  PIN_TRUST="unknown"
  PIN_DAYS_REMAINING="null"
  PIN_NEAR_EXPIRY="false"
  PIN_REASON="no-certbot-runtime"

  if ! record="$(certbot_record_for_label "$label")"; then
    return 0
  fi
  fqdn="$(awk -F '\t' '{print $5}' <<< "$record")"

  if ! declare -F certbot_cluster_run_remote_renewability_probe >/dev/null; then
    PIN_REASON="renewability-helper-unavailable"
    return 0
  fi

  set +e
  output="$(certbot_cluster_run_remote_renewability_probe "$vm_ip" "$fqdn" 2>&1)"
  rc=$?
  set -e

  reason="$(field_from_probe_output "$output" "reason")"
  days_remaining="$(field_from_probe_output "$output" "days_remaining")"
  near_expiry="$(field_from_probe_output "$output" "near_expiry")"

  case "$rc" in
    0)
      PIN_TRUST="trusted"
      PIN_DAYS_REMAINING="${days_remaining:-null}"
      PIN_NEAR_EXPIRY="${near_expiry:-false}"
      PIN_REASON=""
      ;;
    1)
      PIN_TRUST="untrusted"
      PIN_DAYS_REMAINING="${days_remaining:-null}"
      PIN_NEAR_EXPIRY="${near_expiry:-false}"
      PIN_REASON="${reason:-cert-unrenewable}"
      ;;
    3)
      PIN_TRUST="unknown"
      PIN_DAYS_REMAINING="${days_remaining:-null}"
      PIN_NEAR_EXPIRY="${near_expiry:-false}"
      PIN_REASON="${reason:-probe-unknowable}"
      ;;
    255)
      PIN_TRUST="unknown"
      PIN_REASON="vm-unreachable"
      ;;
    *)
      PIN_TRUST="unknown"
      PIN_REASON="predicate-rc-${rc}"
      ;;
  esac

  if [[ ! "$PIN_DAYS_REMAINING" =~ ^-?[0-9]+$ ]]; then
    PIN_DAYS_REMAINING="null"
  fi
  case "$PIN_NEAR_EXPIRY" in
    true|false)
      ;;
    *)
      PIN_NEAR_EXPIRY="false"
      ;;
  esac
}

pbs_backup_record_for_volid() {
  local json="$1"
  local volid="$2"

  jq -c --arg volid "$volid" 'first(.[]? | select(.volid == $volid)) // empty' <<< "$json"
}

pbs_backup_verify_state() {
  local record_json="$1"

  # Return "" (absent) for any null/missing metadata. Only surface an
  # explicit non-null state. A freshly landed PBS backup often reports
  # `"verification": null` (or the field absent) because PBS's verify
  # sweep is asynchronous; treating that as a "failed" state would
  # false-reject valid backups (#97 review, codex-P1).
  jq -r '
    if has("verification") and (.verification != null) then
      if (.verification | type) == "object" then
        (.verification.state // .verification.status // "")
      else
        (.verification | tostring)
      end
    elif has("verify-state") and (.["verify-state"] != null) then
      .["verify-state"] | tostring
    elif has("verify_status") and (.verify_status != null) then
      .verify_status | tostring
    elif has("verified") and (.verified != null) then
      if .verified == true then "ok" else "failed" end
    else
      ""
    end
  ' <<< "$record_json"
}

# Human-readable UTC formatter that works on both BSD (macOS workstation)
# and GNU (NixOS runner) date. Returns the input epoch as an ISO-8601-ish
# UTC string. Falls back to the raw epoch if both syntaxes fail so an
# unexpected date binary never crashes a diagnostic message.
format_epoch_utc() {
  local epoch="$1"
  local formatted=""

  formatted="$(date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  if [[ -z "$formatted" ]]; then
    formatted="$(date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)"
  fi
  if [[ -z "$formatted" ]]; then
    formatted="epoch=${epoch}"
  fi
  printf '%s\n' "$formatted"
}

# Sample the per-VM freshness anchor for the ctime gate (#547).
#
# Callers use the returned integer epoch as a per-VM lower bound on the
# ctime of any newly recorded PBS snapshot for that VM.
#
# Note on "PBS clock" (#592). The SSH hop below is `root@${PBS_AVAIL}`
# but PBS_AVAIL is a PROXMOX NODE — the first node in NODE_IPS where
# `pvesm status | grep pbs-nas` succeeds — NOT the proxmox-backup-server
# host. See the PBS_AVAIL assignment block near the bottom of this script
# for the discovery loop. The anchor is therefore sampled from a Proxmox
# node's clock, not from the PBS server's clock. The ctimes we compare
# against are written by proxmox-backup-server itself when it materialises
# the snapshot on the datastore.
#
# The freshness gate is safe if and only if the Proxmox node clock we
# sample here and PBS's own clock are in sync. On this cluster every
# Proxmox node and the PBS appliance NTP-sync to `config.yaml.ntp_server`
# (default: the management gateway), so drift stays well under 1 s in
# practice and the strict > gate is preserved. If NTP breaks and node ↔
# PBS drift approaches the 1 s ctime resolution, this gate's guarantees
# degrade proportionally. If a future change requires stricter clock
# alignment, sample from PBS itself via
# `ssh <pbs-host> 'date -u +%s'` or a PBS API endpoint — the current
# behaviour is a deliberate simplification (no SSH-to-PBS credentials on
# the workstation/runner) rather than an accidental one.
#
# Called by `backup_vm()` immediately before the 1-second sleep (Option 2
# / #602) and the vzdump call that follows — so the anchor is captured
# first, the sleep guarantees any real backup's ctime lands in a strictly
# later PBS-second, and then vzdump runs.
#
# Any snapshot landed by a *concurrent* PBS-scheduled backup for a
# *different* VM that started BEFORE this call has a ctime < this value
# and is rejected — that is the cross-VM race #547 closes. A concurrent
# scheduled backup for the SAME VM that lands during our vzdump-in-flight
# interval is caught by the per-run identity marker (#591); see the
# layered ghost-rejection docs at the top of this script.
#
# Fail-closed on SSH failure: signal failure via empty stdout with exit 0
# rather than non-zero, so `x="$(sample_pbs_epoch)"` under `set -e` does
# not kill the entire run (see .claude/rules/platform.md — `set -e` kills
# before you can capture the exit code). The caller's numeric-regex check
# catches the empty return and fails only the single VM.
sample_pbs_epoch() {
  local epoch=""

  # Sampled from a Proxmox node (see the docstring on this function and
  # the PBS_AVAIL assignment block). Depends on cluster-wide NTP sync
  # between Proxmox nodes and the PBS appliance for the ctime comparison
  # against this value to hold to sub-second precision.
  epoch="$(ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${PBS_AVAIL}" 'date -u +%s' 2>/dev/null || true)"
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  # Fail-closed on SSH failure. The workstation-clock fallback the pre-#547
  # code used could silently degrade the freshness gate (if the workstation
  # clock lags PBS, a ghost with ctime < workstation-now but > PBS-now
  # would be accepted). The correct default for a safety gate is FAIL, not
  # SKIP — matches .claude/rules/destruction-safety.md.
  echo "WARNING: could not sample the freshness-anchor clock from the Proxmox pbs-nas SSH hop (PBS_AVAIL); failing this VM closed" >&2
  return 0
}

pbs_backup_ctime() {
  local record_json="$1"

  # Return an integer epoch (0 if absent/unparseable). `tonumber?` guards
  # against missing or malformed input; `floor` guarantees an integer even
  # if PBS ever surfaces a fractional ctime, so downstream bash arithmetic
  # (`(( ... ))`) cannot crash with a float parse error (#97 review,
  # codex-P2).
  jq -r '((.ctime // 0) | (tonumber? // 0) | floor)' <<< "$record_json"
}

# #591 identity gate. Return 0 if this PBS record's notes field contains
# our per-run marker (proving OWNERSHIP), 1 otherwise.
#
# Proxmox has surfaced backup notes under two different keys across
# storage-plugin versions: `.notes` and `.comment`. Instead of the
# `.notes // .comment` short-circuit (which false-rejects a record whose
# `.notes` is present but empty and whose `.comment` carries the marker
# — a shape Proxmox has been observed to emit during storage-plugin
# transitions, and one the review of this MR flagged as a real API-drift
# risk), check both keys independently and accept when either carries
# the marker.
#
# Sub-string containment (rather than equality) lets vzdump prepend/append
# other content to the notes without breaking the gate — the marker's
# high-entropy suffix (128 bits of hex) makes false-positive matches
# astronomically improbable.
pbs_backup_notes_carry_our_marker() {
  local record_json="$1"

  jq -e --arg marker "$BACKUP_NOW_MARKER" \
    '((.notes    // "" | tostring) | contains($marker))
      or
     ((.comment  // "" | tostring) | contains($marker))' \
    >/dev/null 2>&1 <<< "$record_json"
}

# Human-safe rendering of a record's notes field(s) for diagnostic
# output. If both `.notes` and `.comment` are present the display
# concatenates them (space-separated, each labelled) so the operator can
# tell which key carried what content when neither matched. Empty
# renders as the literal token `<empty>` so "no notes at all" is
# distinguishable from "notes present but wrong". Newlines collapse to
# `\n` so the diagnostic stays on one line even if a future vzdump ships
# multi-line notes.
pbs_backup_notes_display() {
  local record_json="$1"

  jq -r '
    def clean: tostring | gsub("\n"; "\\n");
    (.notes    // "") as $n
    | (.comment // "") as $c
    | if ($n | tostring) == "" and ($c | tostring) == "" then "<empty>"
      elif ($c | tostring) == "" then ($n | clean)
      elif ($n | tostring) == "" then "comment=" + ($c | clean)
      else ($n | clean) + " (comment=" + ($c | clean) + ")"
      end
  ' <<< "$record_json"
}

# Fail-closed post-vzdump check (#97, FG-11; #547 per-VM anchor; #602
# strict > with sleep-1 gap; #591 per-run identity marker).
#
# vzdump can exit 0 even when the backup did not actually land in PBS
# (stale NFS mount returning cached content, PBS disk full so only the
# manifest header persists, transient index corruption). Without a
# structural post-vzdump check the operator sees "success" and proceeds
# with destructive operations against a ghost backup — the failure mode
# named in report-foot-gun-audit-v2.md FG-11 (RPN 400).
#
# The check requires the newly recorded volid to satisfy ALL of:
#   * present in the current PBS content listing (structural existence)
#   * size > 0 (rules out zero-byte manifests on out-of-space PBS)
#   * ctime > pre_vzdump_epoch (this VM's own pre-vzdump anchor sampled
#     via the pbs-nas SSH hop — see `sample_pbs_epoch`; rules out stale/
#     cached listings AND rules out a snapshot produced by a concurrent
#     PBS-scheduled backup that landed BEFORE — or in the same PBS-second
#     as — our anchor sample #547/#602). backup_vm() sleeps 1 s between
#     sample_pbs_epoch and vzdump so a real backup's ctime is guaranteed
#     to land strictly after the anchor; strict > catches CROSS-VM ghosts
#     without false-rejecting real work.
#   * notes carries our per-run identity marker (#591; closes the SAME-VM
#     residual window where a scheduled backup for the same VMID lands
#     during our vzdump-in-flight interval with ctime > anchor. The
#     scheduled job's notes marker differs from ours, so its snapshots
#     are rejected here even when the freshness gate would accept them).
#   * verification state (if PBS reports one) is one of ok/success/verified
#
# Any failure emits an operator-facing diagnostic naming what to check
# (PBS datastore health, NFS mount, disk space) and returns non-zero so
# the caller marks the VM as FAILED and does not write the pin entry.
# G7: the message points at conditions, not at raw manual commands.
#
# Args: vmid volid content_json pre_vzdump_epoch
verify_backup_landed_in_pbs() {
  local vmid="$1"
  local volid="$2"
  local content_json="$3"
  local pre_vzdump_epoch="$4"
  local record_json=""
  local ctime_epoch=""
  local verify_state=""
  local verify_state_lc=""

  record_json="$(pbs_backup_record_for_volid "$content_json" "$volid")"
  if [[ -z "$record_json" ]]; then
    echo "    FAILED: VMID ${vmid} — vzdump reported success but PBS content list has no entry for ${volid}"
    echo "    Check: PBS datastore health, PBS-NFS mount status, and PBS disk space; the vzdump may have been silently dropped"
    return 1
  fi

  if ! jq -e '(.size // 0 | tonumber? // 0) > 0' >/dev/null 2>&1 <<< "$record_json"; then
    echo "    FAILED: VMID ${vmid} — ${volid} present in PBS content list but reports size 0 or missing size"
    echo "    Check: PBS datastore free space and NFS export; a size-0 backup is unrestorable"
    return 1
  fi

  ctime_epoch="$(pbs_backup_ctime "$record_json")"
  if [[ -z "$ctime_epoch" || "$ctime_epoch" == "0" ]]; then
    echo "    FAILED: VMID ${vmid} — ${volid} missing ctime metadata; cannot verify this backup is fresh"
    echo "    Check: PBS content listing integrity on the storage node"
    return 1
  fi
  # Strict > (not >=). #602: backup_vm() sleeps 1 s after
  # sample_pbs_epoch() and before vzdump, so a real backup's ctime is
  # guaranteed to be at least pre_vzdump_epoch + 1. A ghost with
  # ctime == pre_vzdump_epoch is a concurrent same-second landing (we
  # cannot tell "landed just before the sample" from "landed strictly
  # after" at 1-second PBS resolution) and must be rejected. NEVER
  # relax this to >= — doing so reopens the silent-drop + same-second
  # ghost misattribution window (#97 / FG-11).
  if (( ctime_epoch <= pre_vzdump_epoch )); then
    local human_ctime human_start
    human_ctime="$(format_epoch_utc "$ctime_epoch")"
    human_start="$(format_epoch_utc "$pre_vzdump_epoch")"
    echo "    FAILED: VMID ${vmid} — ${volid} ctime=${human_ctime} is not strictly after pre-vzdump anchor ${human_start} (epochs ${ctime_epoch} <= ${pre_vzdump_epoch}); PBS listing may be stale or a concurrent scheduled backup ran before or during this vzdump"
    echo "    Check: PBS-NFS mount health, PBS content cache, and whether a scheduled PBS backup job overlapped this run; a fresh vzdump would have a newer ctime"
    return 1
  fi
  # #591: identity gate. This VMID's freshness anchor passed, but a PBS-
  # scheduled backup for the SAME VMID that fired during our vzdump-in-
  # flight interval can land with ctime > anchor and still not be ours.
  # The scheduled job's notes-template (configure-backups.sh's
  # MANAGED_MARKER) differs from ours, so a mismatch here almost always
  # means either our vzdump was silently dropped and a scheduled snapshot
  # landed instead (#591 canonical case), or a third party wrote a
  # backup we should not attribute to this run.
  if ! pbs_backup_notes_carry_our_marker "$record_json"; then
    local notes_display
    notes_display="$(pbs_backup_notes_display "$record_json")"
    echo "    FAILED: VMID ${vmid} — ${volid} does not carry this run's identity marker (expected notes to contain 'run=${BACKUP_NOW_RUN_ID}'; got '${notes_display}')"
    echo "    Check: whether a scheduled PBS backup job for VMID ${vmid} landed during this vzdump; our vzdump may have been silently dropped while the scheduled backup landed with different notes (#591)"
    return 1
  fi

  verify_state="$(pbs_backup_verify_state "$record_json")"
  if [[ -n "$verify_state" ]]; then
    verify_state_lc="$(printf '%s' "$verify_state" | tr '[:upper:]' '[:lower:]')"
    case "$verify_state_lc" in
      ok|success|successful|passed|verified)
        ;;
      *)
        echo "    FAILED: VMID ${vmid} — ${volid} verification state is '${verify_state}'"
        echo "    Check: PBS verify job status for this datastore; the backup chunks may be corrupt"
        return 1
        ;;
    esac
  fi

  return 0
}

verify_backup_pins() {
  local content_json="$1"
  local vmid=""
  local volid=""
  local trust=""
  local days_remaining=""
  local near_expiry=""
  local reason=""
  # #547: per-VM freshness anchor read from the pin map's 7th column.
  local pre_vzdump_epoch=""
  local record_json=""
  local ctime_epoch=""
  local verify_state=""
  local verify_state_lc=""
  local failures=0
  local verified=0

  echo "=== Verifying PBS metadata for new backups ==="
  while IFS=$'\t' read -r vmid volid trust days_remaining near_expiry reason pre_vzdump_epoch; do
    [[ -z "$vmid" || -z "$volid" ]] && continue
    # A missing / non-numeric per-VM anchor means the pin map is
    # malformed (some earlier writer skipped column 7). Fail closed —
    # this second pass exists to double-check freshness, not to guess.
    if [[ ! "$pre_vzdump_epoch" =~ ^[0-9]+$ ]]; then
      echo "  FAILED: VMID ${vmid} — pin map missing per-VM freshness anchor (column 7)"
      failures=$((failures + 1))
      continue
    fi
    verified=$((verified + 1))
    record_json="$(pbs_backup_record_for_volid "$content_json" "$volid")"
    if [[ -z "$record_json" ]]; then
      echo "  FAILED: VMID ${vmid} — ${volid} not found in PBS content list"
      failures=$((failures + 1))
      continue
    fi

    if ! jq -e '(.size // 0 | tonumber? // 0) > 0' >/dev/null 2>&1 <<< "$record_json"; then
      echo "  FAILED: VMID ${vmid} — ${volid} has size 0 or missing size metadata"
      failures=$((failures + 1))
      continue
    fi

    ctime_epoch="$(pbs_backup_ctime "$record_json")"
    if [[ -z "$ctime_epoch" || "$ctime_epoch" == "0" ]]; then
      echo "  FAILED: VMID ${vmid} — ${volid} missing ctime metadata"
      failures=$((failures + 1))
      continue
    fi
    # Strict > — see verify_backup_landed_in_pbs for the sleep-1 rationale.
    if (( ctime_epoch <= pre_vzdump_epoch )); then
      local human_ctime human_start
      human_ctime="$(format_epoch_utc "$ctime_epoch")"
      human_start="$(format_epoch_utc "$pre_vzdump_epoch")"
      echo "  FAILED: VMID ${vmid} — ${volid} ctime=${human_ctime} is not strictly after pre-vzdump anchor ${human_start} (epochs ${ctime_epoch} <= ${pre_vzdump_epoch}); PBS listing may be stale or a concurrent scheduled backup ran before or during this vzdump"
      echo "  Check: PBS-NFS mount health, PBS content cache, and whether a scheduled PBS backup job overlapped this run"
      failures=$((failures + 1))
      continue
    fi
    # #591: identity gate re-verified at --verify time. If the final PBS
    # listing shows a record for the pinned volid whose notes no longer
    # carry our run marker, either a listing regression rewrote the
    # record between capture and verify, or a scheduled backup replaced
    # the pinned volid entry — either way the pin is not trustworthy and
    # the run must fail closed rather than proceed to write the JSON.
    if ! pbs_backup_notes_carry_our_marker "$record_json"; then
      local notes_display
      notes_display="$(pbs_backup_notes_display "$record_json")"
      echo "  FAILED: VMID ${vmid} — ${volid} does not carry this run's identity marker (expected notes to contain 'run=${BACKUP_NOW_RUN_ID}'; got '${notes_display}')"
      echo "  Check: whether a scheduled PBS backup job for VMID ${vmid} landed during or after this run; see #591"
      failures=$((failures + 1))
      continue
    fi

    verify_state="$(pbs_backup_verify_state "$record_json")"
    if [[ -n "$verify_state" ]]; then
      verify_state_lc="$(printf '%s' "$verify_state" | tr '[:upper:]' '[:lower:]')"
      case "$verify_state_lc" in
        ok|success|successful|passed|verified)
          ;;
        *)
          echo "  FAILED: VMID ${vmid} — ${volid} verification state is '${verify_state}'"
          failures=$((failures + 1))
          continue
          ;;
      esac
    fi

    echo "  OK: VMID ${vmid} — ${volid}"
  done < "$PIN_MAP_FILE"

  if [[ "$verified" -eq 0 ]]; then
    echo "  No new backup pins to verify"
    return 0
  fi

  if [[ "$failures" -gt 0 ]]; then
    echo "ERROR: PBS metadata verification failed for ${failures} backup(s)." >&2
    return 1
  fi

  echo "=== Verified ${verified} backup(s) in PBS metadata ==="
  return 0
}

backup_vm() {
  local vm_key="$1"
  local label="$2"
  local vmid="$3"
  local vm_ip="$4"
  local host_ip=""
  local before_json=""
  local after_json=""
  local backup_output=""
  local new_volids=""
  local pin_count=""
  local volid=""
  local trust=""
  local days_remaining=""
  local near_expiry=""
  local reason=""

  if skip_vmid_marked "$vmid"; then
    echo "  SKIP: ${label} (VMID ${vmid}) — exact-pin incomplete-VM convergence exception"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  if first_deploy_skip_marked "$vmid"; then
    echo "  SKIP: ${label} (VMID ${vmid}) — first deploy (no historical PBS backup)"
    SKIPPED=$((SKIPPED + 1))
    return
  fi

  if host_ip="$(find_host_ip_for_vmid "$vmid")"; then
    :
  else
    if pbs_historical_backup_exists "$vmid" "$EXISTING_PBS_JSON"; then
      echo "  FAILED: ${label} (VMID ${vmid}) — not found on any node but historical PBS backups exist"
      FAILED=$((FAILED + 1))
    else
      echo "  SKIP: ${label} (VMID ${vmid}) — first deploy (no historical PBS backup)"
      SKIPPED=$((SKIPPED + 1))
    fi
    return
  fi

  if before_json="$(pbs_content_json)"; then
    :
  else
    echo "  FAILED: ${label} (VMID ${vmid}) — could not query PBS content before backup"
    FAILED=$((FAILED + 1))
    return
  fi

  TOTAL=$((TOTAL + 1))
  echo "  ${label} (VMID ${vmid}) on ${host_ip}..."
  # #547: sample the per-VM freshness anchor from the pbs-nas SSH hop
  # (a Proxmox node — see the sample_pbs_epoch docstring and #592 for
  # why "PBS clock" is a misnomer) immediately before invoking vzdump.
  # Any PBS snapshot for this VMID that lands with ctime <=
  # pre_vzdump_epoch was either stale in the content cache or was
  # produced by a concurrent PBS-scheduled backup that started BEFORE
  # this vzdump — both are ghost backups from our perspective and must
  # be rejected. Sampling AFTER the pre-vzdump PBS content query (which
  # is used only for the volid-diff, not freshness) keeps the anchor as
  # tight as possible.
  local pre_vzdump_epoch=""
  pre_vzdump_epoch="$(sample_pbs_epoch)"
  # sample_pbs_epoch signals failure via empty stdout (see its docstring
  # for the set -e interaction). A safety gate must fail closed when its
  # anchor cannot be established.
  if [[ ! "$pre_vzdump_epoch" =~ ^[0-9]+$ ]]; then
    echo "    FAILED: ${label} (VMID ${vmid}) — could not obtain a per-VM freshness anchor via the pbs-nas SSH hop (${PBS_AVAIL}); refusing to record a pin without it"
    echo "    Check: SSH to ${PBS_AVAIL} (a Proxmox node, not PBS itself), plus Proxmox↔PBS NTP alignment; the anchor is required for #547 ghost-backup rejection"
    FAILED=$((FAILED + 1))
    return
  fi
  # #602 Option 2: guarantee ≥1 s gap between the anchor sample and the
  # start of vzdump. PBS records ctime at 1-second resolution. Without
  # this gap, a small VM's vzdump can complete within the same wall-
  # clock second as sample_pbs_epoch's response, producing
  # ctime == pre_vzdump_epoch. The strict > gate then false-rejects the
  # legitimate backup — this is exactly the failure that broke every
  # dev deploy between #547 landing and the 2026-07-16 rollback (#602).
  #
  # A fixed sleep is simpler than polling sample_pbs_epoch for a
  # different value, adds a bounded 1 s per VM (10 s total for 10
  # backup-backed VMs — negligible next to vzdump itself), and cannot
  # regress against the strict > invariant.
  #
  # NEVER remove or shorten this sleep without also revisiting the
  # strict > check in verify_backup_landed_in_pbs / verify_backup_pins.
  # The two live together as a single safety invariant: real backups'
  # ctime is guaranteed strictly > the anchor because we waited ≥1 s
  # after sampling.
  sleep 1
  # #591: --notes-template embeds this run's identity marker in the
  # resulting backup's PBS notes. The post-vzdump gate uses that marker
  # to prove OWNERSHIP (not just freshness) of the newly-recorded volid,
  # closing the residual same-VM window where a scheduled backup for
  # the same VMID could land during our vzdump-in-flight interval with
  # ctime > our anchor. Single-quoting the marker on the remote shell
  # is safe because BACKUP_NOW_MARKER is ASCII (no single-quotes, no
  # backslashes, no newlines) by construction.
  if backup_output="$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${host_ip}" \
      "vzdump ${vmid} --storage pbs-nas --mode snapshot --compress zstd --notes-template '${BACKUP_NOW_MARKER}' --quiet 1" 2>&1)"; then
    :
  else
    echo "    WARNING: backup failed"
    if [[ -n "$backup_output" ]]; then
      printf '%s\n' "$backup_output" | sed 's/^/      /'
    fi
    FAILED=$((FAILED + 1))
    return
  fi

  if after_json="$(pbs_content_json)"; then
    :
  else
    echo "    WARNING: backup completed but PBS content could not be queried afterwards"
    FAILED=$((FAILED + 1))
    return
  fi

  if new_volids="$(capture_new_backup_volids "$before_json" "$after_json" "$vmid")"; then
    :
  else
    echo "    WARNING: backup completed but pin extraction failed"
    FAILED=$((FAILED + 1))
    return
  fi
  pin_count=$(printf '%s\n' "$new_volids" | sed '/^$/d' | wc -l | tr -d ' ')

  if [[ "$pin_count" != "1" ]]; then
    echo "    WARNING: expected exactly one new PBS backup for VMID ${vmid}, found ${pin_count}"
    if [[ -n "$new_volids" ]]; then
      printf '%s\n' "$new_volids" | sed 's/^/      /'
    fi
    FAILED=$((FAILED + 1))
    return
  fi

  volid="$(printf '%s\n' "$new_volids" | sed -n '1p')"
  # Structural post-vzdump gate (#97, FG-11; #547 per-VM anchor; #602
  # strict > with sleep-1 gap; #591 identity marker). vzdump's exit code
  # alone is not sufficient evidence that a usable backup landed in PBS;
  # the freshness anchor must be per-VM and the ownership marker must
  # be per-run (see the layered ghost-rejection docs at the top of this
  # script and on verify_backup_landed_in_pbs).
  if ! verify_backup_landed_in_pbs "$vmid" "$volid" "$after_json" "$pre_vzdump_epoch"; then
    FAILED=$((FAILED + 1))
    return
  fi
  collect_certbot_trust_marker "$label" "$vm_ip"
  trust="$PIN_TRUST"
  days_remaining="$PIN_DAYS_REMAINING"
  near_expiry="$PIN_NEAR_EXPIRY"
  reason="$PIN_REASON"
  if [[ "$VERIFY" -eq 1 ]]; then
    if pin_map_set "$vmid" "$volid" "$trust" "$days_remaining" "$near_expiry" "$reason" "$pre_vzdump_epoch"; then
      echo "    Done"
      echo "    Pin: ${volid}"
      echo "    Trust: ${trust}${reason:+ (${reason})}"
    else
      echo "    WARNING: backup succeeded but pin map update failed"
      FAILED=$((FAILED + 1))
    fi
  else
    if pin_file_set "$vmid" "$volid" "$trust" "$days_remaining" "$near_expiry" "$reason"; then
      echo "    Done"
      echo "    Pin: ${volid}"
      echo "    Trust: ${trust}${reason:+ (${reason})}"
    else
      echo "    WARNING: backup succeeded but pin file update failed"
      FAILED=$((FAILED + 1))
    fi
  fi
}

# Discover a Proxmox node that will serve as the SSH hop for pveproxy
# storage-content queries against pbs-nas (#592 clarification).
#
# PBS_AVAIL is a PROXMOX NODE — the first entry in NODE_IPS whose
# `pvesm status` lists pbs-nas — NOT the proxmox-backup-server host. All
# subsequent SSH invocations that reference PBS_AVAIL
# (`pbs_content_json`, `sample_pbs_epoch`) SSH to that Proxmox node and
# ask the local pveproxy to talk to PBS. This choice reflects three
# facts:
#   * Every Proxmox node with pbs-nas registered can serve
#     `pvesh get /nodes/<hostname>/storage/pbs-nas/content` — we don't
#     need SSH credentials to the PBS appliance itself.
#   * The workstation/runner already has SSH to the Proxmox nodes for
#     `qm status` / vzdump, so no new credential surface is introduced.
#   * Proxmox nodes and the PBS appliance NTP-sync to
#     `config.yaml.ntp_server` (default: management gateway), so the
#     ctime freshness gate (#547) treats the Proxmox-node clock we sample
#     in `sample_pbs_epoch` as a close-enough proxy for PBS's own clock.
#     If NTP breaks and drift approaches the 1 s ctime resolution, the
#     gate's guarantee degrades; that's a documented dependency, not an
#     accidental one. See the `sample_pbs_epoch` docstring for the
#     rationale and the ceiling on drift.
PBS_AVAIL=""
for ip in $NODE_IPS; do
  if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${ip}" "pvesm status 2>/dev/null | grep -q pbs-nas" 2>/dev/null; then
    PBS_AVAIL="$ip"
    break
  fi
done

if [[ -z "$PBS_AVAIL" ]]; then
  echo "ERROR: PBS storage (pbs-nas) not registered on any node" >&2
  exit 1
fi

# Note: the freshness anchor is now per-VM (#547), sampled inside
# backup_vm() immediately before each vzdump via sample_pbs_epoch().
# The run-wide BACKUP_RUN_START_EPOCH that used to be re-anchored here
# is removed — its only consumers were the freshness comparisons, which
# are now per-VM.

if EXISTING_PBS_JSON="$(pbs_content_json)"; then
  :
else
  echo "ERROR: Could not query PBS content to verify historical backups" >&2
  exit 1
fi

warn_unknown_skip_vmids

HEALTH_FAILURES=0
HEALTH_CHECKED=0
echo "=== Checking VM health on backup-backed VMs ==="
while IFS=$'\t' read -r vm_key label vmid vm_ip; do
  [[ -z "$label" ]] && continue
  HEALTH_CHECKED=$((HEALTH_CHECKED + 1))

  if skip_vmid_marked "$vmid"; then
    echo "  SKIP: ${label} — exact-pin incomplete-VM convergence exception"
    continue
  fi

  HAS_HISTORY=0
  if pbs_historical_backup_exists "$vmid" "$EXISTING_PBS_JSON"; then
    HAS_HISTORY=1
  fi

  host_ip=""
  if host_ip="$(find_host_ip_for_vmid "$vmid")"; then
    :
  else
    if [[ "$HAS_HISTORY" -eq 1 ]]; then
      echo "  FAILED: ${label} (not found on any node; historical PBS backups exist)"
      HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
    else
      mark_first_deploy_skip "$vmid"
      echo "  SKIP: ${label} — first deploy (unreachable and no historical PBS backup)"
    fi
    continue
  fi

  if vm_health_check "$vm_key" "$label" "$vm_ip" "$host_ip" "$vmid"; then
    echo "  OK: ${label}"
  else
    if [[ "$HAS_HISTORY" -eq 0 ]]; then
      mark_first_deploy_skip "$vmid"
      echo "  SKIP: ${label} — first deploy (${VM_HEALTH_LAST_REASON})"
    else
      echo "  FAILED: ${label} (${VM_HEALTH_LAST_REASON})"
      HEALTH_FAILURES=$((HEALTH_FAILURES + 1))
    fi
  fi
done < <(collect_backup_records)

if [[ "$HEALTH_CHECKED" -eq 0 ]]; then
  echo "  No backup-backed VMs matched --env ${BACKUP_ENV}"
fi

if [[ "$HEALTH_FAILURES" -gt 0 ]]; then
  echo "ERROR: Refusing backup while ${HEALTH_FAILURES} VM(s) failed health check." >&2
  exit 1
fi
echo ""

if declare -F certbot_cluster_cert_storage_records >/dev/null; then
  CERTBOT_TRUST_RECORDS="$(certbot_cluster_cert_storage_records "${CONFIG}" "${APPS_CONFIG}" 2>/dev/null || true)"
fi

TOTAL=0
FAILED=0
SKIPPED=0

echo "=== Backing up precious-state VMs ==="
echo ""
while IFS=$'\t' read -r vm_key label vmid vm_ip; do
  [[ -z "$label" ]] && continue
  backup_vm "$vm_key" "$label" "$vmid" "$vm_ip"
done < <(collect_backup_records)

echo ""
if [[ $FAILED -eq 0 ]]; then
  if [[ "$VERIFY" -eq 1 ]]; then
    if FINAL_PBS_JSON="$(pbs_content_json)"; then
      :
    else
      echo "ERROR: Could not query PBS content to verify new backups" >&2
      exit 1
    fi

    verify_backup_pins "$FINAL_PBS_JSON"
    pin_file_write_from_map
  fi
  echo "=== All ${TOTAL} backups complete (${SKIPPED} skipped) ==="
else
  echo "=== ${TOTAL} attempted, ${FAILED} failed, ${SKIPPED} skipped ==="
  exit 1
fi
