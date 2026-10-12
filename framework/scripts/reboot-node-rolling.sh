#!/usr/bin/env bash
# reboot-node-rolling.sh — workstation-side wrapper for an HA-aware
# rolling reboot of one Proxmox node.
#
# Usage:
#   framework/scripts/reboot-node-rolling.sh <target-node> [<surviving-node>]
#
# Workflow:
#   1. Resolve <surviving-node>: if not given, pick any node in
#      site/config.yaml that is not <target-node> and is currently
#      reachable + quorate.
#   2. SCP framework/scripts/rolling-reboot-node-inner.sh and
#      framework/scripts/lib/cidata-guard.sh to <surviving-node>:/tmp/
#      (under pid-suffixed names to avoid collisions if two operators
#      run concurrently for different targets).
#   3. ssh root@<surviving-node> bash /tmp/<staged>.sh
#      <target-node> <surviving-node> <pool> <lib-path> <name=ip>...
#   4. Propagate the inner script's exit code to the operator.
#
# The wrapper is intentionally thin. ALL safety logic
# (HA-maintenance enable/disable, drain wait, reboot, quorum poll,
# cleanup-on-exit trap, signal handling) lives in the inner script,
# which has been through 9 rounds of adversarial review (#338 trap
# fix + the earlier R1 kernel rollout rounds). The wrapper handles
# the workstation→node transport and the auto-pick-surviving-node
# convenience.
#
# After this command returns rc=0 on each node in turn, run
# `framework/scripts/rebalance-cluster.sh` separately to migrate VMs
# back to their config.yaml-intended placements. The wrapper does NOT
# auto-rebalance: operators often reboot multiple nodes in sequence
# and a single rebalance at the end is cheaper than rebalancing
# between every reboot.
#
# This is the script `rebuild-cluster.sh` Step 1.5 points at when it
# declines to auto-reboot because non-stopped VMs are present.
#
# History:
#   - #345 — extract from OPERATIONS.md inline template.
#   - #338 — cleanup-on-die trap fix, applied to the inner script.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_ROOT}/site/config.yaml"
INNER_SCRIPT="${SCRIPT_DIR}/rolling-reboot-node-inner.sh"
GUARD_LIB="${SCRIPT_DIR}/lib/cidata-guard.sh"
STEP_Z_REFUSAL_RC=3

die() { echo "ERROR: $*" >&2; exit 1; }

# Strict hostname regex (RFC1123 style: letters, digits, hyphens; must
# start with a letter or digit; not end with a hyphen; 1-63 chars).
# Proxmox node names are constrained to this shape; validating against
# this regex defends against shell-injection if a malicious or corrupt
# site/config.yaml ever introduces a node name with shell metacharacters
# (we eventually interpolate node names into a remote shell command via
# `ssh root@<host> "bash '<path>' '<target>' '<surviving>'"`). Treat
# config.yaml as a trust boundary even though it is operator-edited via
# MR — defense in depth is cheap here.
HOSTNAME_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
IPV4_REGEX='^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$'

validate_hostname() {
  local what="$1" name="$2"
  if [[ ! "$name" =~ $HOSTNAME_REGEX ]]; then
    die "$what '$name' does not match strict hostname regex ${HOSTNAME_REGEX}. Refusing to proceed (shell-injection guard)."
  fi
}

validate_ipv4() {
  local what="$1" ip="$2"
  if [[ ! "$ip" =~ $IPV4_REGEX ]]; then
    die "$what '$ip' does not match strict IPv4 regex. Refusing to proceed (shell-injection guard)."
  fi
}

shell_quote() {
  local value=${1//\'/\'\\\'\'}
  printf "'%s'" "$value"
}

usage() {
  cat <<'EOF'
Usage: framework/scripts/reboot-node-rolling.sh <target-node> [<surviving-node>]

  <target-node>      Proxmox node to reboot (must match a name in
                     site/config.yaml's nodes[]).
  <surviving-node>   Optional. Cluster member to orchestrate from.
                     If omitted, the wrapper picks the first node
                     in config.yaml that is not <target-node> and is
                     currently reachable + quorate.

After this returns rc=0 for each node in turn, run
framework/scripts/rebalance-cluster.sh to migrate VMs back to their
intended placements.
EOF
}

if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage >&2
  exit 1
fi

TARGET="$1"
SURVIVING="${2:-}"

# Shell-injection guard: validate the args against the strict hostname
# regex BEFORE any further use. The args may end up interpolated into a
# remote shell command later; reject anything outside RFC1123 hostname
# shape now.
validate_hostname "<target-node>" "$TARGET"
if [[ -n "$SURVIVING" ]]; then
  validate_hostname "<surviving-node>" "$SURVIVING"
fi

# Validate target is in config.yaml. Fail loudly if not — silent
# wrong-target is the worst failure mode (you'd put the wrong node
# in maintenance).
if [[ ! -f "$CONFIG" ]]; then
  die "config.yaml not found at $CONFIG"
fi

STORAGE_POOL="$(yq -r '.proxmox.storage_pool // "vmstore"' "$CONFIG" 2>/dev/null)" \
  || die "failed to read proxmox.storage_pool from $CONFIG"
if [[ -z "$STORAGE_POOL" || "$STORAGE_POOL" == "null" ]]; then
  die "proxmox.storage_pool in $CONFIG resolved to an empty value"
fi

NODE_INVENTORY_RAW="$(yq -r '.nodes[] | [.name, .mgmt_ip] | @tsv' "$CONFIG" 2>/dev/null)" \
  || die "failed to read nodes[] inventory from $CONFIG"
NODE_NAMES=()
NODE_IPS=()
NODE_INVENTORY=()
while IFS=$'\t' read -r n ip; do
  [[ -z "$n" && -z "${ip:-}" ]] && continue
  # Reject any config.yaml node name that doesn't match the hostname
  # regex — even if the operator-supplied $TARGET passed, a malformed
  # entry could be picked as $SURVIVING during auto-pick and become
  # the right-hand side of a remote shell interpolation.
  validate_hostname "config.yaml nodes[].name" "$n"
  validate_ipv4 "config.yaml nodes[].mgmt_ip for $n" "$ip"
  # ${arr[@]+…} guard: under `set -u`, expanding an empty array with "${arr[@]}"
  # is an unbound-variable error on bash 3.2 (the macOS system bash).
  for existing in ${NODE_NAMES[@]+"${NODE_NAMES[@]}"}; do
    if [[ "$existing" == "$n" ]]; then
      die "duplicate config.yaml nodes[].name '$n'"
    fi
  done
  NODE_NAMES+=("$n")
  NODE_IPS+=("$ip")
  NODE_INVENTORY+=("${n}=${ip}")
done <<< "$NODE_INVENTORY_RAW"

if [[ ${#NODE_NAMES[@]} -eq 0 ]]; then
  die "no nodes found in $CONFIG nodes[]"
fi

target_in_config=0
for n in "${NODE_NAMES[@]}"; do
  if [[ "$n" == "$TARGET" ]]; then
    target_in_config=1
    break
  fi
done
if [[ $target_in_config -eq 0 ]]; then
  die "<target-node> '$TARGET' not found in config.yaml nodes[] (known: ${NODE_NAMES[*]})"
fi

# Resolve a node's IP from the validated config.yaml inventory.
ip_for_node() {
  local name="$1" i
  for ((i = 0; i < ${#NODE_NAMES[@]}; i++)); do
    if [[ "${NODE_NAMES[$i]}" == "$name" ]]; then
      printf '%s' "${NODE_IPS[$i]}"
      return 0
    fi
  done
  echo "node '$name' not found in validated config.yaml inventory" >&2
  return 1
}

# Test reachability + quorum for a candidate surviving node.
# Reachability: ssh connect within 5s. Quorum: pvecm reports
# Quorate: Yes. A node that is reachable but not quorate would not
# accept ha-manager commands — useless for orchestration.
is_reachable_and_quorate() {
  local ip="$1"
  ssh -n -o ConnectTimeout=5 -o BatchMode=yes -o LogLevel=ERROR \
      -o StrictHostKeyChecking=accept-new \
      "root@${ip}" "pvecm status | grep -q 'Quorate: *Yes'" 2>/dev/null
}

if [[ -z "$SURVIVING" ]]; then
  # Auto-pick: first node != TARGET that is reachable + quorate.
  echo "Auto-picking surviving node (excluding target '$TARGET')..."
  for candidate in "${NODE_NAMES[@]}"; do
    [[ "$candidate" == "$TARGET" ]] && continue
    candidate_ip="$(ip_for_node "$candidate")" \
      || die "internal error resolving mgmt_ip for $candidate"
    if [[ -z "$candidate_ip" || "$candidate_ip" == "null" ]]; then
      echo "  $candidate: mgmt_ip missing in config.yaml; skipping" >&2
      continue
    fi
    if is_reachable_and_quorate "$candidate_ip"; then
      SURVIVING="$candidate"
      echo "  picked $SURVIVING (${candidate_ip}): reachable + quorate"
      break
    else
      echo "  $candidate (${candidate_ip}): not reachable or not quorate; skipping" >&2
    fi
  done
  if [[ -z "$SURVIVING" ]]; then
    die "no reachable+quorate surviving node found in config.yaml. Investigate cluster health before retrying."
  fi
else
  # Operator-specified surviving node. Validate it's in config and
  # not the target.
  if [[ "$SURVIVING" == "$TARGET" ]]; then
    die "<surviving-node> must be different from <target-node>"
  fi
  surviving_in_config=0
  for n in "${NODE_NAMES[@]}"; do
    if [[ "$n" == "$SURVIVING" ]]; then
      surviving_in_config=1
      break
    fi
  done
  if [[ $surviving_in_config -eq 0 ]]; then
    die "<surviving-node> '$SURVIVING' not found in config.yaml nodes[] (known: ${NODE_NAMES[*]})"
  fi
fi

SURVIVING_IP="$(ip_for_node "$SURVIVING")" \
  || die "could not resolve mgmt_ip for surviving node '$SURVIVING'"
if [[ -z "$SURVIVING_IP" || "$SURVIVING_IP" == "null" ]]; then
  die "could not resolve mgmt_ip for surviving node '$SURVIVING'"
fi

# Verify the inner script exists locally. A missing file here is a
# repo-shape error (someone moved or renamed the inner script
# without updating this wrapper) -- fail with a clear pointer.
if [[ ! -f "$INNER_SCRIPT" ]]; then
  die "inner script not found at $INNER_SCRIPT (repo layout issue)"
fi
if [[ ! -f "$GUARD_LIB" ]]; then
  die "cidata guard library not found at $GUARD_LIB (repo layout issue)"
fi

# Stage with pid-suffixed names so concurrent invocations of this
# wrapper (different targets, same surviving node) don't clobber each
# other's staged copies. The remote /tmp filenames also embed the
# target name for debug clarity in `ps` output on the surviving node.
REMOTE_INNER="/tmp/rolling-reboot-${TARGET}-$$.sh"
REMOTE_GUARD_LIB="/tmp/cidata-guard-${TARGET}-$$.sh"

# Remove the staged copies on exit, regardless of inner script outcome.
# Without this, /tmp accumulates one pair per invocation; harmless but
# untidy. Use `|| true` so cleanup failure does not mask the inner
# script's exit code.
#
# ConnectTimeout=5 is critical: BatchMode prevents auth prompts but
# does NOT prevent TCP connect hangs. Without ConnectTimeout, if the
# surviving node became unreachable between the inner-script ssh and
# this cleanup ssh, the trap could stall wrapper exit for the OS's
# default TCP timeout (often ~75s).
cleanup_remote() {
  ssh -n -o BatchMode=yes -o LogLevel=ERROR \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      "root@${SURVIVING_IP}" "rm -f $(shell_quote "$REMOTE_INNER") $(shell_quote "$REMOTE_GUARD_LIB")" 2>/dev/null \
    || true
}
trap cleanup_remote EXIT

echo "Staging inner script to ${SURVIVING}:${REMOTE_INNER} ..."
scp -O -o BatchMode=yes -o LogLevel=ERROR \
    -o StrictHostKeyChecking=accept-new \
    "$INNER_SCRIPT" "root@${SURVIVING_IP}:${REMOTE_INNER}" \
  || die "scp of inner script to ${SURVIVING} (${SURVIVING_IP}) failed"

echo "Staging cidata guard library to ${SURVIVING}:${REMOTE_GUARD_LIB} ..."
scp -O -o BatchMode=yes -o LogLevel=ERROR \
    -o StrictHostKeyChecking=accept-new \
    "$GUARD_LIB" "root@${SURVIVING_IP}:${REMOTE_GUARD_LIB}" \
  || die "scp of cidata guard library to ${SURVIVING} (${SURVIVING_IP}) failed"

echo "Running rolling reboot of ${TARGET} via ${SURVIVING} (${SURVIVING_IP}) ..."
echo "  This will:"
echo "    a0. Guard the pre-maintenance drain and relocate ballooned VMs if needed"
echo "    a.  Enable HA maintenance on ${TARGET}"
echo "    b.  Wait for VMs to drain (HA migrates managed VMs off)"
echo "    c.  Reboot ${TARGET}"
echo "    d.  Wait for ${TARGET} to return + rejoin quorum"
echo "    z.  Guard the HA failback destination before disabling maintenance"
echo "    e.  Disable HA maintenance"
echo
echo "Streaming inner script output:"
echo "----------------------------------------------------------------"
# No `-t` flag: the inner script doesn't read stdin and a TTY would
# allocate a remote pseudo-terminal we don't need. The interrupt
# semantics worth knowing:
#   - Operator Ctrl-C on this wrapper sends SIGINT to the wrapper's
#     process group, which includes the local ssh. The local ssh
#     reacts by sending SIGHUP over the connection on tear-down; the
#     remote bash inner sees that as SIGHUP, not SIGINT. The inner
#     script traps HUP/INT/TERM and exits with a signal-encoded rc;
#     the inner's EXIT trap then runs cleanup (auto-disables
#     maintenance).
#   - To interrupt cleanly without a TTY: send SIGTERM to the local
#     ssh PID. ssh tears down the channel, remote bash sees SIGHUP,
#     same trap fires.
# In both cases, by the time this wrapper resumes after ssh exits,
# the inner script has already attempted auto-disable.
REMOTE_CMD="bash $(shell_quote "$REMOTE_INNER") $(shell_quote "$TARGET") $(shell_quote "$SURVIVING") $(shell_quote "$STORAGE_POOL") $(shell_quote "$REMOTE_GUARD_LIB")"
for inventory_entry in "${NODE_INVENTORY[@]}"; do
  REMOTE_CMD+=" $(shell_quote "$inventory_entry")"
done
ssh -n -o BatchMode=yes -o LogLevel=ERROR \
    -o StrictHostKeyChecking=accept-new \
    "root@${SURVIVING_IP}" "$REMOTE_CMD"
INNER_RC=$?
echo "----------------------------------------------------------------"

if [[ $INNER_RC -eq 0 ]]; then
  echo
  echo "${TARGET} rebooted cleanly. To migrate VMs back to their"
  echo "intended placements, run from this workstation:"
  echo "    framework/scripts/rebalance-cluster.sh"
  echo "If you have more nodes to reboot, you can run rebalance once"
  echo "after the last node returns -- not between each."
elif [[ $INNER_RC -eq $STEP_Z_REFUSAL_RC ]]; then
  echo
  echo "Inner script exited rc=${INNER_RC}: Step z refused to disable"
  echo "HA maintenance because the failback destination was not proven safe."
  echo "Do not blanket-disable maintenance; that would trigger the"
  echo "unguarded failback Step z refused."
  echo
  echo "Remediation:"
  echo "  1. Inspect cidata orphans:"
  echo "       framework/scripts/cleanup-orphan-cidata.sh --dry-run"
  echo "  2. If a rename victim already exists, inspect and repair it:"
  echo "       framework/scripts/realign-cidata.sh --dry-run --vmid <vmid>"
  echo "       framework/scripts/realign-cidata.sh --vmid <vmid>"
  echo "  3. Only after the failback destination is safe, disable maintenance:"
  echo "       ssh root@${SURVIVING_IP} ha-manager crm-command \\"
  echo "         node-maintenance disable ${TARGET}"
  echo "  4. Re-run validation:"
  echo "       framework/scripts/validate.sh"
else
  echo
  echo "Inner script exited rc=${INNER_RC}. If the inner ran far enough"
  echo "to install its cleanup trap (past the early arg-parse die at"
  echo "lines 48-52 of the inner), HA maintenance on ${TARGET} should"
  echo "have been auto-disabled (look for 'Auto-disabling maintenance'"
  echo "in the trace above). If the trace shows 'WARNING: auto-disable"
  echo "failed', or if rc is in the 255 range (ssh transport failed"
  echo "before the inner was reached), verify by hand:"
  echo "    ssh root@${SURVIVING_IP} ha-manager status"
  echo "If ${TARGET} is shown in maintenance, run:"
  echo "    ssh root@${SURVIVING_IP} ha-manager crm-command \\"
  echo "      node-maintenance disable ${TARGET}"
  echo "Then investigate the failure and re-run when resolved."
fi

exit "$INNER_RC"
