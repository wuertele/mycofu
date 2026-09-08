#!/usr/bin/env bash
# cleanup-orphan-cidata.sh — Destroy orphan cidata zvols on Proxmox nodes.
#
# Background: Proxmox VM migrations can leave orphan cidata zvols on
# source nodes. When a VM later migrates back to a node holding an
# orphan, Proxmox auto-renames the imported cidata to
# `vm-<vmid>-disk-N` to avoid the name collision. The non-canonical
# name breaks Proxmox's regeneration code at
# /usr/share/perl5/PVE/QemuServer/Cloudinit.pm:692 (regex filter
# `vm-<vmid>-cloudinit`), so subsequent `qm cloudinit update <vmid>`
# (or bpg-mediated regeneration during tofu apply) silently skips
# the rename-victim. The cidata then stays frozen at the content it
# had at the moment of the rename, indefinitely. See issue #417 and
# docs/research/2026-06-10-A2-cicd-cidata-propagation-trace.md.
#
# This script enumerates cidata-shaped zvols on every Proxmox node
# from config.yaml, cross-references each against the cluster-wide set
# of attached disks (read from /etc/pve/nodes/*/qemu-server/*.conf via
# any cluster member — pmxcfs is corosync-shared), and destroys any
# zvol that is not attached anywhere in the cluster. Two-layer safety:
# (1) only zvols matching the cidata naming pattern (vm-<vmid>-cloudinit
# or vm-<vmid>-disk-<N>) are eligible at all; (2) only zvols with
# refer <= 1 MiB are eligible — boot/data disks are never at risk
# even when their names accidentally match.
#
# The cluster-wide attached-set check (rather than per-node qm config)
# is what protects ZFS replication targets: replicated boot/data zvols
# (vm-<vmid>-disk-N) exist on non-owner nodes, where qm config <vmid>
# errors with "Configuration file ... does not exist" — a per-node
# check would falsely classify them as orphan.
#
# Usage:
#   cleanup-orphan-cidata.sh [--dry-run] [--verbose] [--node <ip|name>] [--vmid <id>]
#
# Options:
#   --node <val>  Restrict scan to one node (by mgmt_ip or hostname).
#   --vmid <id>    Filter to orphans for one specific VMID only.
#
# Operator-invoked tool. Intentionally NOT called automatically from
# configure-replication.sh — the auto-invocation case requires a
# node-aware attachment check (see codex R2 P1 in
# docs/reports/mycofu-fix-issue-417-*review-codex-r2.md). For now, the
# operator runs this manually after realigning any rename-victim
# cidata zvol back to the canonical name. See
# .claude/rules/replication.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

# Upper bound (in KiB) for a zvol to be considered cidata-shaped.
# Real cidata refer is ~18.5K. Boot/data disks are >>1M. The threshold
# gives slack for future Proxmox version differences without ever
# overlapping a real disk.
MAX_CIDATA_REFER_KIB=1024

DRY_RUN=0
VERBOSE=0
FILTER_NODE=""
FILTER_VMID=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run] [--verbose] [--node <ip|name>] [--vmid <id>]

Sweep Proxmox nodes listed in config.yaml for orphan cidata zvols
and destroy them. A zvol is "orphan" when it (a) matches the cidata
naming pattern \`vm-<vmid>-(cloudinit|disk-<N>)\`, (b) is below the
cidata size threshold (refer <= ${MAX_CIDATA_REFER_KIB} KiB), and
(c) does not appear in any \`/etc/pve/nodes/*/qemu-server/*.conf\` file
cluster-wide — i.e. is not attached to any VM on any node, including
ZFS replication targets.

Options:
  --dry-run      list orphans that would be destroyed, do nothing
  --verbose      show every candidate considered and the decision
  --node <val>   restrict scan to one node (by mgmt_ip or hostname)
  --vmid <id>    filter to orphans for one specific VMID only
  --help         this message

Exit codes:
  0 — no orphans, or all orphans destroyed successfully
  1 — at least one destroy attempt failed
  2 — usage error
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose|-v) VERBOSE=1; shift ;;
    --node) FILTER_NODE="$2"; shift 2 ;;
    --vmid) FILTER_VMID="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -f "${CONFIG}" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 1
fi

# Allow tests to substitute these tools via $PATH shims.
YQ="${YQ:-yq}"
SSH="${SSH:-ssh}"

# Read node mgmt IPs and names. Keep an unfiltered inventory for the
# cluster-wide attached-set safety envelope; --node only scopes the per-node
# zvol scan below.
ALL_NODE_IPS=()
ALL_NODE_NAMES=()
NODE_IPS=()
NODE_NAMES=()
while read -r name ip; do
  [[ -z "${name}" || -z "${ip}" ]] && continue

  ALL_NODE_IPS+=("${ip}")
  ALL_NODE_NAMES+=("${name}")

  if [[ -z "${FILTER_NODE}" || "${FILTER_NODE}" == "${name}" || "${FILTER_NODE}" == "${ip}" ]]; then
    NODE_IPS+=("${ip}")
    NODE_NAMES+=("${name}")
  fi
done < <("${YQ}" -r '.nodes[] | .name + " " + .mgmt_ip' "${CONFIG}")

if [[ "${#ALL_NODE_IPS[@]}" -eq 0 ]]; then
  echo "ERROR: No nodes found in ${CONFIG} (.nodes[])" >&2
  exit 1
fi

if [[ "${#NODE_IPS[@]}" -eq 0 ]]; then
  if [[ -n "${FILTER_NODE}" ]]; then
    echo "ERROR: Node not found: ${FILTER_NODE}" >&2
  else
    echo "ERROR: No nodes found in ${CONFIG} (.nodes[])" >&2
  fi
  exit 1
fi

# Storage pool — same key configure-replication.sh uses.
STORAGE_POOL="$("${YQ}" -r '.proxmox.storage_pool // "vmstore"' "${CONFIG}")"

# Pattern matching: `vmstore/data/vm-160-cloudinit`, `vmstore/data/vm-160-disk-1`, etc.
# vmstore is configurable; data is the standard Proxmox zfs convention.
CIDATA_PATTERN_REGEX='vm-([0-9]+)-(cloudinit|disk-[0-9]+)$'

# Parse a `refer` value like "18.5K" or "0" into KiB (rounded).
# Returns the integer KiB on stdout. Returns the input unchanged if it
# already exceeds the threshold (avoids float parsing for clearly large
# zvols).
refer_to_kib() {
  local value="$1"
  if [[ "${value}" == "0" || "${value}" == "0B" ]]; then
    echo 0
    return
  fi
  if [[ "${value}" =~ ^([0-9]+(\.[0-9]+)?)K$ ]]; then
    # Floor; bash arithmetic does integer truncation. 18.5K -> 18.
    awk -v v="${BASH_REMATCH[1]}" 'BEGIN { printf "%d\n", v }'
    return
  fi
  # Anything not in K (M, G, T) is way above our threshold. Return a
  # sentinel large value.
  echo "$((MAX_CIDATA_REFER_KIB + 1))"
}

TOTAL_FOUND=0
TOTAL_DESTROYED=0
TOTAL_FAILED=0
# Per-node zfs list failures. Tracked separately from destroy failures
# because a scan failure means the cluster state on that node is unknown
# — we cannot truthfully claim "0 orphans" for a node we never saw.
# See issue #419 codex R1 P2.
SCAN_FAILURES=0

ssh_node() {
  local node_ip="$1"
  shift
  "${SSH}" -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    "root@${node_ip}" "$@"
}

# Build the cluster-wide set of currently-attached zvols by reading every VM
# config in /etc/pve/nodes/*/qemu-server/*.conf. /etc/pve is a corosync-shared
# filesystem (pmxcfs) so any node sees the same content — we only need to ask
# one node.
#
# Node-aware logic (Sprint 045 Vaccine):
# A zvol `vm-<vmid>-<name>` on `node-X` is NOT an orphan if:
#   1. It is referenced by the config for VM `<vmid>` WHICH IS OWNED BY `node-X`.
#   2. It is referenced by the config for VM `<vmid>` owned by `node-Y`, AND
#      it is a ZFS replication target to `node-X`.
#
# CIDATA-class zvols (cloudinit) are NEVER replicated. Therefore, a CIDATA
# zvol on `node-X` is an orphan if `node-X` does not own the VM.
# Rename-victim zvols (named `disk-N` but cidata-sized) are also unreplicated.
#
# This node-aware check allows the sweep to clear orphans on a destination
# node before migration, even while the VM is still active on the source node
# (where the canonical zvol is attached).

# Try each node until one read succeeds.
ATTACHED_RAW=""
ATTACHED_READ_OK=0
for try_node in "${ALL_NODE_IPS[@]}"; do
  set +e
  # Capture filename (which includes node name) along with the line.
  ATTACHED_RAW=$(ssh_node "${try_node}" \
    "grep -r '${STORAGE_POOL}:vm-' /etc/pve/nodes/*/qemu-server/*.conf 2>/dev/null")
  try_rc=$?
  set -e
  if [[ "${try_rc}" -eq 0 || "${try_rc}" -eq 1 ]]; then
    ATTACHED_READ_OK=1
    break
  fi
  echo "  WARNING: could not read /etc/pve on ${try_node} (rc=${try_rc}); trying next node" >&2
done

if [[ "${ATTACHED_READ_OK}" -eq 0 ]]; then
  echo "ERROR: could not read /etc/pve from any node — refusing to proceed without a verified attached set" >&2
  exit 1
fi

# Parse replication jobs to identify legitimate replicas.
REPL_RAW=""
for try_node in "${ALL_NODE_IPS[@]}"; do
  set +e
  REPL_RAW=$(ssh_node "${try_node}" "cat /etc/pve/replication.cfg 2>/dev/null")
  try_rc=$?
  set -e
  if [[ "${try_rc}" -eq 0 || "${try_rc}" -eq 1 ]]; then
    break
  fi
done

for node_ip in "${NODE_IPS[@]}"; do
  # Resolve mgmt_ip back to node name for config matching.
  node_name=""
  for i in "${!NODE_IPS[@]}"; do
    if [[ "${NODE_IPS[$i]}" == "${node_ip}" ]]; then
      node_name="${NODE_NAMES[$i]}"
      break
    fi
  done

  echo "==> ${node_name} (${node_ip})"

  # Build the set of zvols that are LEGITIMATE on THIS node.
  # 1. Actually attached to a VM owned by this node.
  node_attached=$(printf '%s\n' "${ATTACHED_RAW}" \
    | grep "/etc/pve/nodes/${node_name}/" \
    | grep -oE "${STORAGE_POOL}:vm-[0-9]+-(cloudinit|disk-[0-9]+)" \
    | sort -u || true)

  # 2. Replicated to this node (only relevant for data disks).
  # Replication line: "target: <node>", "guest: <vmid>" in a block.
  # We look for any job targeting this node.
  node_replicated_vmids=$(printf '%s\n' "${REPL_RAW}" \
    | awk -v target="${node_name}" '
        /^replication:/ { guest="" }
        /^[[:space:]]*guest:/ { guest=$2 }
        /^[[:space:]]*target:/ { if ($2 == target) print guest }
      ' | sort -u || true)

  node_legitimate="${node_attached}"
  for rvmid in ${node_replicated_vmids}; do
    # Any disk for a replicated VMID is legitimate on this node.
    # We add all possible disk names for that VMID to the legitimate set.
    # (Safe because we only destroy things that exist on disk anyway).
    legit_matches=$(printf '%s\n' "${ATTACHED_RAW}" \
      | grep -oE "${STORAGE_POOL}:vm-${rvmid}-(cloudinit|disk-[0-9]+)" || true)
    if [[ -n "${legit_matches}" ]]; then
      node_legitimate="${node_legitimate}"$'\n'"${legit_matches}"
    fi
  done
  node_legitimate=$(echo "${node_legitimate}" | sort -u || true)

  # ... (rest of the per-node zvol loop)

  # List zvols under the storage pool. `-t volume <path>` requires <path>
  # to be a volume; passing `vmstore/data` (a filesystem) makes zfs error
  # with "operation not applicable to datasets of this type" and rc=1.
  # `-r ${STORAGE_POOL}/data` recurses from the data dataset and matches
  # all volumes under it. Matches the convention used in 5 callsites in
  # configure-replication.sh. See issue #419.
  #
  # zfs list -H -o name,refer outputs tab-separated; we filter to the
  # cidata naming pattern client-side so unusual names don't slip through
  # the awk filter.
  set +e
  zfs_out=$(ssh_node "${node_ip}" "zfs list -t volume -H -o name,refer -r ${STORAGE_POOL}/data 2>/dev/null")
  zfs_rc=$?
  set -e

  if [[ ${zfs_rc} -ne 0 ]]; then
    echo "  WARNING: could not list zvols on ${node_ip} (zfs list rc=${zfs_rc})" >&2
    SCAN_FAILURES=$((SCAN_FAILURES + 1))
    continue
  fi

  while IFS=$'\t' read -r zvol refer; do
    [[ -z "${zvol}" ]] && continue

    short_name="${zvol##*/}"

    # Filter to cidata naming pattern.
    if [[ ! "${short_name}" =~ ${CIDATA_PATTERN_REGEX} ]]; then
      [[ "${VERBOSE}" -eq 1 ]] && echo "  skip name: ${short_name}"
      continue
    fi
    vmid="${BASH_REMATCH[1]}"

    # Apply --vmid filter if set.
    if [[ -n "${FILTER_VMID}" && "${FILTER_VMID}" != "${vmid}" ]]; then
      [[ "${VERBOSE}" -eq 1 ]] && echo "  skip vmid mismatch: ${short_name} (target=${FILTER_VMID})"
      continue
    fi

    # Size safety filter — never touch anything bigger than ~1 MiB refer.
    # This is the backstop in case the cluster-wide check misses something
    # (e.g., a config file format we don't grep for); we should never
    # destroy a real data disk regardless of the attached-set lookup.
    refer_kib=$(refer_to_kib "${refer}")
    if (( refer_kib > MAX_CIDATA_REFER_KIB )); then
      [[ "${VERBOSE}" -eq 1 ]] && echo "  skip size: ${short_name} (refer=${refer})"
      continue
    fi

    # Node-aware attached check — protects ZFS replication targets on this
    # node and verified attached zvols on this node.
    zvol_full="${STORAGE_POOL}:${short_name}"
    if grep -qxF "${zvol_full}" <<< "${node_legitimate}"; then
      [[ "${VERBOSE}" -eq 1 ]] && echo "  attached/replica on this node: ${short_name}"
      continue
    fi

    # Orphan: small zvol matching the cidata pattern, not attached anywhere on this node.
    echo "  orphan: ${zvol} (refer=${refer}, vmid=${vmid})"
    TOTAL_FOUND=$((TOTAL_FOUND + 1))

    if [[ "${DRY_RUN}" -eq 1 ]]; then
      continue
    fi

    # -r removes migration snapshots (vm-<vmid>-...@__migration__) that
    # Proxmox leaves on the orphan source after a migration. Without -r,
    # `zfs destroy` errors with "filesystem has children" and the orphan
    # stays. Matches the pattern in configure-replication.sh's other
    # zvol-cleanup paths.
    set +e
    ssh_node "${node_ip}" "zfs destroy -r ${zvol}" 2>&1
    destroy_rc=$?
    set -e

    if [[ ${destroy_rc} -eq 0 ]]; then
      echo "    destroyed"
      TOTAL_DESTROYED=$((TOTAL_DESTROYED + 1))
    else
      echo "    DESTROY FAILED (rc=${destroy_rc})"
      TOTAL_FAILED=$((TOTAL_FAILED + 1))
    fi
  done <<< "${zfs_out}"
done

echo ""
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "Summary (dry-run): ${TOTAL_FOUND} orphan(s) found, 0 destroyed, ${SCAN_FAILURES} scan failure(s)"
else
  echo "Summary: ${TOTAL_FOUND} orphan(s) found, ${TOTAL_DESTROYED} destroyed, ${TOTAL_FAILED} failed, ${SCAN_FAILURES} scan failure(s)"
fi

# Fail closed when any per-node scan failed: a "0 orphan(s) found" result
# is only meaningful if we actually saw every node. Without this guard,
# the very failure mode that produced this issue (#419: silent zfs list
# rc=1) could recur in a different form and still report success.
if [[ "${TOTAL_FAILED}" -gt 0 || "${SCAN_FAILURES}" -gt 0 ]]; then
  exit 1
fi
