# shellcheck shell=bash
# cidata-guard.sh — the shared cidata rename-victim vaccine (Sprint 046 R3).
#
# Hoisted verbatim-in-behavior out of rebalance-cluster.sh, where it was a
# private function guarding the single `ha-manager migrate` call site. It is a
# library now because THREE node-change paths mint rename-victims by the
# identical mechanism, and only one of them was guarded:
#
#   1. rebalance          — `ha-manager migrate` / `crm-command relocate`
#   2. node-maintenance enable  — HA drains every VM off the node (drain-OUT)
#   3. node-maintenance disable — HA fails every drained VM back ON to it (leg 3)
#
# A relocate is NOT safer than a migrate with respect to cidata: QemuMigrate.pm
# gives the cidata volume migration_mode 'offline' in both cases and calls
# storage_migrate with allow_rename => 1, which is exactly what lets the
# destination rename a colliding vm-<vmid>-cloudinit to vm-<vmid>-disk-N.
#
# The library runs in three contexts with incompatible toolchains — the operator
# workstation, a Synology NAS (no yq, no jq), and a Proxmox node (no yq, no jq,
# no repo checkout) — so it is CONFIG-FREE and PARSER-FREE. It reads no YAML, no
# JSON, no config.yaml. Callers pass exec targets and the storage pool as opaque
# parameters. Body is bash + ssh only.
#
# It is sourced, so it must be safe under both `set -euo pipefail`
# (rebalance-cluster.sh) and `set -uo pipefail` (rolling-reboot-node-inner.sh).
# It never calls `set`, and every rc-as-value call site uses the
# `x=$(f) && rc=0 || rc=$?` form rather than `x=$(f); rc=$?`.
#
# Fail-closed everywhere (.claude/rules/destruction-safety.md): any state we
# cannot read aborts the caller BEFORE the node change, never after.

# CIDATA_GUARD_LIB_VERSION -- bump on any behavior change. configure-sentinel-gatus.sh
# records it in the deploy log and asserts the NAS copy is byte-identical to the repo
# copy: the NAS gets this file by scp, not by git, so a stale copy is a real hazard.
CIDATA_GUARD_LIB_VERSION="3"

CIDATA_MAX_REFER_BYTES=1048576   # 1 MiB - real cidata refer is ~18.5K

cidata_guard_exec() {
  local target="$1"
  shift

  # Both arms redirect stdin from /dev/null. The guard is called from inside
  # `while read` loops (rolling-reboot Step a0 walks `ha-manager status` line by
  # line); a child that inherits stdin would eat the loop's input and only the
  # first VM would ever be guarded. That is the `ssh -n` rule in
  # .claude/rules/ssh.md, applied to the local arm too.
  if [[ "$target" == "local" ]]; then
    bash -c "$*" < /dev/null
  else
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new "$target" "$*"
  fi
}

cidata_guard_lib_version() {
  printf '%s\n' "$CIDATA_GUARD_LIB_VERSION"
}

cidata_zvol_name() {
  printf 'vm-%s-cloudinit' "$1"
}

# Probe a zvol on a target. On exists, prints its refer in bytes. Returns:
#   0 = exists (refer printed)   1 = absent   2 = unknown (ssh/other failure)
cidata_zvol_probe() {
  local target="$1" pool="$2" zvol="$3" out zfs_rc refer
  out=$(cidata_guard_exec "$target" \
    "zfs list -Hp -o refer '${pool}/data/${zvol}' 2>/dev/null; echo \"__rc=\$?\"" 2>/dev/null) \
    || return 2
  zfs_rc=$(printf '%s\n' "$out" | sed -n 's/^__rc=//p' | tail -1)
  refer=$(printf '%s\n' "$out" | sed '/^__rc=/d' | sed -n '1p')
  case "$zfs_rc" in
    0) [[ -n "$refer" ]] && { printf '%s\n' "$refer"; return 0; }; return 2 ;;
    1) return 1 ;; # zfs: dataset does not exist
    *) return 2 ;; # any other zfs error -> unknown, fail-closed
  esac
}

cidata_zvol_destroy() {
  local target="$1" pool="$2" zvol="$3"
  cidata_guard_exec "$target" "zfs destroy '${pool}/data/${zvol}'"
}

# HA service state for a vmid. Prints the state word, "" if the VM is not
# HA-managed, or "UNKNOWN" if HA status is unreadable.
cidata_ha_service_state() {
  local ha_target="$1" vmid="$2" out
  out=$(cidata_guard_exec "$ha_target" "ha-manager status 2>/dev/null") || { printf 'UNKNOWN\n'; return; }
  if ! printf '%s\n' "$out" | grep -q '^service '; then
    printf 'UNKNOWN\n'
    return
  fi
  printf '%s\n' "$out" \
    | sed -n "s/^service vm:${vmid} (\([^,]*\), \([^)]*\)).*/\2/p" | head -1
}

# HA service node for a vmid. Prints the node, "" if the VM is not HA-managed,
# or "UNKNOWN" if HA status is unreadable.
cidata_ha_service_node() {
  local ha_target="$1" vmid="$2" out
  out=$(cidata_guard_exec "$ha_target" "ha-manager status 2>/dev/null") || { printf 'UNKNOWN\n'; return; }
  if ! printf '%s\n' "$out" | grep -q '^service '; then
    printf 'UNKNOWN\n'
    return
  fi
  printf '%s\n' "$out" \
    | sed -n "s/^service vm:${vmid} (\([^,]*\), \([^)]*\)).*/\1/p" | head -1
}

# Return 0 when qm config has a positive balloon floor, 1 when fixed, 2 unknown.
# Contract: target MUST be the VM's owning node. `qm config <vmid>` is
# node-local in Proxmox and fails on non-owner nodes.
vm_is_ballooned() {
  local target="$1" vmid="$2" out rc line value
  out=$(cidata_guard_exec "$target" "qm config '${vmid}' 2>/dev/null") && rc=0 || rc=$?
  if [[ "$rc" -ne 0 || -z "$out" ]]; then
    return 2
  fi

  while IFS= read -r line; do
    case "$line" in
      balloon:*)
        value="${line#balloon:}"
        while [[ "$value" == [[:space:]]* ]]; do
          value="${value#?}"
        done
        while [[ "$value" == *[[:space:]] ]]; do
          value="${value%?}"
        done
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
          return 2
        fi
        [[ "$value" =~ ^0+$ ]] && return 1
        return 0
        ;;
    esac
  done <<< "$out"

  return 1
}

cidata_guard_node_change() {
  local vmid="$1" owner_node="$2" ha_target="$3" pool="$4" dry_run="$5"
  shift 5

  if [[ "$dry_run" != "true" && "$dry_run" != "false" ]]; then
    echo "    ERROR: invalid dry_run value '${dry_run}'; aborting node-change guard (fail-closed)." >&2
    return 1
  fi
  if [[ "$#" -eq 0 ]]; then
    echo "    ERROR: no cidata guard destinations provided; aborting node-change guard (fail-closed)." >&2
    return 1
  fi

  local zvol
  zvol="$(cidata_zvol_name "$vmid")"

  local ha_state
  ha_state=$(cidata_ha_service_state "$ha_target" "$vmid") || ha_state="UNKNOWN"
  if [[ "$ha_state" == "UNKNOWN" ]]; then
    echo "    ERROR: cannot read HA state for vm:${vmid}; aborting node-change guard (fail-closed)." >&2
    echo "      Safe next step: framework/scripts/validate.sh; retry when the cluster is reachable." >&2
    return 1
  fi
  if [[ "$ha_state" == "error" ]]; then
    echo "    ERROR: vm:${vmid} is in HA 'error' state; refusing to migrate (a referenced rename-victim is not swept)." >&2
    echo "      Safe next step: framework/scripts/realign-cidata.sh --dry-run --vmid ${vmid}; then framework/scripts/realign-cidata.sh --vmid ${vmid}." >&2
    return 1
  fi

  local live_owner
  live_owner=$(cidata_ha_service_node "$ha_target" "$vmid") || live_owner="UNKNOWN"
  if [[ "$live_owner" == "UNKNOWN" ]]; then
    echo "    ERROR: cannot read live HA owner for vm:${vmid}; aborting node-change guard (fail-closed)." >&2
    echo "      Safe next step: framework/scripts/validate.sh; retry when the cluster is reachable." >&2
    return 1
  fi
  if [[ -n "$live_owner" && "$live_owner" != "$owner_node" ]]; then
    echo "    ERROR: live HA owner for vm:${vmid} is ${live_owner}, but caller snapshot owner was ${owner_node}; aborting node-change guard (fail-closed)." >&2
    echo "      HA moved the VM after the caller's snapshot. Re-run the operation with fresh placement state." >&2
    return 1
  fi

  local dest name target refer_bytes rc
  for dest in "$@"; do
    name="${dest%%=*}"
    target="${dest#*=}"

    if [[ "$name" == "$dest" || -z "$name" || -z "$target" ]]; then
      echo "    ERROR: invalid cidata guard destination '${dest}'; aborting node-change guard (fail-closed)." >&2
      return 1
    fi

    # Never touch the current owner's canonical cidata — this is the ownership rule the
    # whole guard rests on.
    [[ "$name" == "$owner_node" ]] && continue
    # Redundant by construction today: owner drift already aborted above, so live_owner
    # can only equal owner_node here. Kept deliberately — it is the last line of defense
    # against destroying a LIVE owner's cidata, and it must survive any future edit that
    # relaxes the drift abort.
    [[ -n "$live_owner" && "$name" == "$live_owner" ]] && continue

    refer_bytes=$(cidata_zvol_probe "$target" "$pool" "$zvol") && rc=0 || rc=$?
    if [[ "$rc" -eq 2 ]]; then
      echo "    ERROR: cannot determine whether ${zvol} exists on ${name} (${target}); aborting node-change guard (fail-closed)." >&2
      echo "      Safe next step: framework/scripts/validate.sh; retry when the node is reachable." >&2
      return 1
    fi
    [[ "$rc" -eq 1 ]] && continue

    if ! [[ "$refer_bytes" =~ ^[0-9]+$ ]] || [[ "$refer_bytes" -gt "$CIDATA_MAX_REFER_BYTES" ]]; then
      echo "    ERROR: ${pool}/data/${zvol} on ${name} is '${refer_bytes}' bytes (> ${CIDATA_MAX_REFER_BYTES}); not cidata-shaped. Aborting node-change guard (fail-closed)." >&2
      echo "      Safe next step: inspect on ${name}; framework/scripts/realign-cidata.sh --dry-run --vmid ${vmid}." >&2
      return 1
    fi

    if [[ "$dry_run" == "true" ]]; then
      echo "    Would sweep stale orphan cidata ${pool}/data/${zvol} on ${name} (${refer_bytes}B) before node change."
      continue
    fi

    echo "    Sweeping stale orphan cidata ${pool}/data/${zvol} on ${name} (${refer_bytes}B) before node change..."
    # The live-owner read above is still a snapshot. If HA moves the VM in the
    # tiny window before this destroy, ZFS's own EBUSY on an in-use zvol is the
    # backstop: destroy fails, and the guard aborts fail-closed below.
    if ! cidata_zvol_destroy "$target" "$pool" "$zvol"; then
      echo "    ERROR: failed to destroy ${pool}/data/${zvol} on ${name}; aborting node-change guard (fail-closed)." >&2
      echo "      Safe next step: framework/scripts/cleanup-orphan-cidata.sh --dry-run." >&2
      return 1
    fi
  done

  return 0
}
