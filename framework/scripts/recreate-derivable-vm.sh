#!/usr/bin/env bash
# recreate-derivable-vm.sh — recovery tool for disk-loss + explicit-
# override VMs. Not the recovery path for ordinary failover.
#
# Under universal replication, every shipped VM has a replica and
# recovers via HA §6A/§6B ladders after node failure. This script's
# remaining fleet roles are:
#   (a) Disk-loss / data-corruption recovery on any VM (rare).
#   (b) Recovery of an explicit-override VM (explicit false, an
#       empty set on the shipped site) after failover — contract:
#       max_restart=0 / max_relocate=0 → terminal HA `error`.
#
# All guards (precious refusal, park-aware refusal, §6A ladder,
# stop-and-print-deploy) are enforced regardless of use-case.
#
# Contract:
#   1. REFUSE any VMID that appears in `list-backup-backed-vmids.sh all`
#      (precious guard, fail-closed).
#   2. REFUSE if a `mycofu-park-*` dataset exists for the VMID (Sprint 044
#      parked vdb — its release requires operator approval via
#      `parked-vdb.sh release`, which has its own precious-writes-check).
#   3. Clear HA `error` via the sanctioned `--state disabled` ladder from
#      `.claude/rules/storage-failure-fence.md` §6A. NEVER `ha-manager remove`,
#      NEVER bare `qm stop` on a healthy VM.
#   4. Destroy the VM shell and its stale `vm-<vmid>-*` zvols on ALL nodes
#      via the selective-pattern (Sprint 044 park-namespace preservation +
#      `.claude/rules/proxmox-tofu.md`'s "dataset already exists" prevention).
#   5. STOP and print the deploy command the operator should run next
#      (`safe-apply.sh <env>` for Tier-1; `rebuild-cluster.sh --scope
#      control-plane` + `register-runner.sh` for cicd). NEVER apply.
#
# Rationale: `.claude/rules/no-manual-fixes.md` → Recovery Operations
# demands framework mechanism over an operator-typed `qm destroy` +
# `ha-manager` runbook.
#
# Usage:
#   framework/scripts/recreate-derivable-vm.sh [--dry-run] <vmid>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

DRY_RUN=false
VMID=""

usage() {
  cat >&2 <<'EOF'
Usage: recreate-derivable-vm.sh [--dry-run] <vmid>

Recreate a VM by clearing HA error state, destroying the VM shell
and its stale zvols cluster-wide, then STOPPING with instructions
for the operator to run the deploy.

This tool has two roles under universal replication:
  (a) Disk-loss / data-corruption recovery on any VM (rare).
  (b) Recovery of an explicit-override VM (explicit false, empty
      set on the shipped site) after failover; contract:
      max_restart=0 / max_relocate=0 → terminal HA `error`.

For every other VM, ordinary failover is handled by the
storage-failure-fence §6A/§6B ladder from a replicated zvol; this
tool is NOT the recovery path.

Fail-closed on precious VMs (per list-backup-backed-vmids.sh) and on
parked vdb datasets (Sprint 044).

Options:
  --dry-run    Show what would happen; make ZERO mutations.
  --help       Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "ERROR: unknown option $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$VMID" ]]; then
        VMID="$1"
      else
        echo "ERROR: unexpected extra argument: $1" >&2
        usage
        exit 2
      fi
      shift
      ;;
  esac
done

if [[ -z "$VMID" ]]; then
  echo "ERROR: VMID required." >&2
  usage
  exit 2
fi

if ! [[ "$VMID" =~ ^[0-9]+$ ]] || [[ "$VMID" -le 0 ]]; then
  echo "ERROR: VMID must be a positive integer: '$VMID'" >&2
  exit 2
fi
# Sprint 047 review-round P1 (agy): normalize away leading zeros. Otherwise
# `[[ "$pvmid" == "$VMID" ]]` string comparison in the precious guard misses
# `0150` while `qm destroy 0150` interprets it as VMID 150 and destroys the
# precious VM.
VMID=$((10#$VMID))

log() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*"
  else
    echo "$*"
  fi
}

do_ssh() {
  local target="$1"; shift
  if [[ "$DRY_RUN" == "true" ]]; then
    log "ssh root@${target} '$*'"
    return 0
  fi
  # BatchMode=yes so a mis-configured key fails FAST rather than hanging on
  # a keyboard-interactive prompt (sub-claude adversarial review P2).
  ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${target}" "$*"
}

echo "==> recreate-derivable-vm.sh VMID=${VMID} (dry-run=${DRY_RUN})"

# ---------------------------------------------------------------------------
# Guard 1: precious refusal
# ---------------------------------------------------------------------------
BACKUP_HELPER="${SCRIPT_DIR}/list-backup-backed-vmids.sh"
if [[ ! -x "$BACKUP_HELPER" ]]; then
  echo "ERROR: precious guard helper not found: $BACKUP_HELPER" >&2
  exit 1
fi

if precious_list="$("$BACKUP_HELPER" --format csv all 2>/dev/null)"; then
  IFS=',' read -ra PRECIOUS_ARR <<< "$precious_list"
  for pvmid in "${PRECIOUS_ARR[@]}"; do
    if [[ "$pvmid" == "$VMID" ]]; then
      echo "REFUSE: VMID ${VMID} is in list-backup-backed-vmids.sh (precious)." >&2
      echo "  Precious VMs are recovered via PBS restore, NOT recreation." >&2
      echo "  See .claude/rules/pbs-restore.md for the correct sequence." >&2
      exit 3
    fi
  done
else
  echo "ERROR: precious guard helper failed; refusing to proceed (fail-closed)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard 1b: explicit-override membership requirement
#
# The precious guard alone would let any non-precious VM through — but
# under universal replication most non-precious VMs ARE replicated
# (default-dev 24h, default-prod/shared 1m) and recover from replica via
# HA §6A/§6B, NOT via destroy+recreate. Running this script on a
# replicated VM would destroy its vdb, defeating the exact reason it
# has a replica.
#
# Also: an unknown-to-config VMID (typo, manually created VM) is
# semantically ambiguous — fail-closed and refuse to touch.
#
# Consult list-replicated-vmids.sh --mode policy-off all: the VMID MUST
# be on this list (i.e., known-to-config AND explicitly overridden via
# `explicit override`). On the shipped site this list is EMPTY, so this
# guard blocks every VMID by default — the guarded path is machinery
# preserved for a future explicit-override plus disk-loss recovery.
# (The disk-loss recovery use-case is a special operator-attended
# invocation with prior operator judgment that the VM has no recoverable
# replica — same fail-closed refusal without policy-off membership
# applies; operator uses PBS restore or a fixture-provided override
# to invoke this path.)
# ---------------------------------------------------------------------------
POLICY_HELPER="${SCRIPT_DIR}/list-replicated-vmids.sh"
if [[ ! -x "$POLICY_HELPER" ]]; then
  echo "ERROR: policy helper not found: $POLICY_HELPER" >&2
  exit 1
fi

if policy_off_list="$("$POLICY_HELPER" --format csv --mode policy-off all 2>/dev/null)"; then
  policy_off_match=false
  IFS=',' read -ra POLICY_OFF_ARR <<< "$policy_off_list"
  for pvmid in ${POLICY_OFF_ARR[@]+"${POLICY_OFF_ARR[@]}"}; do
    if [[ "$pvmid" == "$VMID" ]]; then
      policy_off_match=true
      break
    fi
  done
  if [[ "$policy_off_match" != "true" ]]; then
    echo "REFUSE: VMID ${VMID} is NOT on list-replicated-vmids.sh --mode policy-off all." >&2
    echo "  Either the VMID is POLICY-ON (opt-in or precious — recovered via HA" >&2
    echo "  restart-from-replica, see storage-failure-fence.md §6A/§6B) or it is" >&2
    echo "  unknown to config (a manually-created VM has ambiguous state class)." >&2
    echo "  Under Sprint 048 doctrine this script only recreates VMs the site's" >&2
    echo "  policy has classified as explicit-override (explicit override), which" >&2
    echo "  is an empty set on the shipped site. For disk-loss recovery on any" >&2
    echo "  VM, prefer PBS restore (restore-from-pbs.sh) or introduce a" >&2
    echo "  fixture-provided override before invoking this script." >&2
    exit 3
  fi
else
  echo "ERROR: policy helper failed; refusing to proceed (fail-closed)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Read cluster nodes
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config file not found: $CONFIG" >&2
  exit 1
fi

NODE_NAMES=$(yq -r '.nodes[].name' "$CONFIG")
FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
STORAGE_POOL=$(yq -r '.proxmox.storage_pool // "vmstore"' "$CONFIG")

if [[ -z "$NODE_NAMES" || -z "$FIRST_NODE_IP" ]]; then
  echo "ERROR: could not resolve node names / first-node IP from $CONFIG" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard 2: parked vdb refusal (Sprint 044)
# ---------------------------------------------------------------------------
PARK_HITS=""
for NODE in $NODE_NAMES; do
  NODE_IP=$(yq -r ".nodes[] | select(.name == \"${NODE}\") | .mgmt_ip" "$CONFIG")
  [[ -z "$NODE_IP" || "$NODE_IP" == "null" ]] && continue
  # Look for mycofu-park-<vmid>-* on this node
  set +e
  hit=$(ssh -n -o ConnectTimeout=5 "root@${NODE_IP}" \
    "zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep -E 'mycofu-park-${VMID}-'" 2>/dev/null)
  set -e
  if [[ -n "$hit" ]]; then
    PARK_HITS+="${NODE}:${hit}"$'\n'
  fi
done

if [[ -n "$PARK_HITS" ]]; then
  echo "REFUSE: parked vdb dataset(s) exist for VMID ${VMID}:" >&2
  echo "$PARK_HITS" >&2
  echo "  Parked datasets may contain writes newer than any PBS pin." >&2
  echo "  Inspect first: framework/scripts/parked-vdb.sh inspect ${VMID}" >&2
  echo "  Then EITHER adopt the park via recovery-mode restore OR — only after" >&2
  echo "  explicit operator approval to discard those writes — run" >&2
  echo "  framework/scripts/parked-vdb.sh release ${VMID}, and then re-run" >&2
  echo "  this recreate script." >&2
  exit 4
fi

# ---------------------------------------------------------------------------
# Step 3: Clear HA error via --state disabled ladder (storage-failure-fence.md §6A)
#
# HA state is read from TWO valid JSON sources (issue #688):
#   1. `pvesh get /cluster/ha/resources --output-format json` → registration +
#      requested state (started/stopped/disabled/ignored).
#   2. `/etc/pve/ha/manager_status` (JSON written by the CRM) → the SERVICE-
#      INTERNAL runtime state we branch on: error, starting, started, freeze,
#      migrate, recovery, request_stop, etc.
#
# The previous implementation used `ha-manager status --output-format json`,
# which is NOT a valid command on PVE 9.1.1 (the `--output-format` option
# does not apply to `ha-manager status`). It exited non-zero, the JSON
# capture was empty, and `HA_STATE=""` was treated as "not registered in HA"
# — fail-OPEN. `qm destroy` would then follow while HA still owned the
# service. See docs/reports/rca-2026-07-20-drt005-policyoff-start-hang.md
# (RCA Q5 test-code defects: recreate-derivable-vm.sh).
#
# Fail-closed: any failure to read either source aborts here. That is
# stricter than the pre-#688 behavior — the safety property is the whole
# point of the guard.
# ---------------------------------------------------------------------------
echo ""
echo "==> Clearing HA state (never remove, never bare qm stop) for vm:${VMID}"

# ── Source 1: HA registration + requested state ────────────────────────────
# Agy P2: capture stderr SEPARATELY so an SSH transient produces a useful
# diagnostic instead of a silent empty capture. Use -o BatchMode=yes to
# make the SSH fail fast (no password prompt) — matches the pattern the
# adjacent DRT-005 blocks already use.
HA_RES_STDERR=$(mktemp)
set +e
HA_RESOURCES_JSON=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/ha/resources --output-format json" 2>"$HA_RES_STDERR")
HA_RES_RC=$?
set -e

if [[ $HA_RES_RC -ne 0 || -z "${HA_RESOURCES_JSON// /}" ]]; then
  echo "ERROR: could not read /cluster/ha/resources from ${FIRST_NODE_IP} (rc=${HA_RES_RC})" >&2
  echo "  (fail-closed per issue #688 — HA state cannot be determined)." >&2
  echo "  stderr:" >&2
  sed 's/^/    /' "$HA_RES_STDERR" >&2 || true
  rm -f "$HA_RES_STDERR"
  exit 1
fi
rm -f "$HA_RES_STDERR"
if ! echo "$HA_RESOURCES_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "ERROR: /cluster/ha/resources did not parse as a JSON array" >&2
  echo "  first 5 lines:" >&2
  echo "$HA_RESOURCES_JSON" | head -5 | sed 's/^/    /' >&2
  exit 1
fi

# PVE 9's /cluster/ha/resources returns objects with `sid` (e.g. "vm:150")
# and `state` (the REQUESTED state; internal state comes from manager_status).
# Agy adversarial review: match against BOTH `.sid` and `.id` so a future
# PVE minor-release naming shift cannot silently regress this to fail-OPEN.
# On PVE 9.1.1, `.sid` is authoritative; matching `.id` too is belt-and-
# suspenders for the safety-critical registration check.
HA_REGISTERED=$(echo "$HA_RESOURCES_JSON" | \
  jq -r --arg sid "vm:${VMID}" '[.[] | select(.sid == $sid or .id == $sid)] | length')

HA_STATE=""
if [[ "$HA_REGISTERED" == "0" ]]; then
  log "  vm:${VMID} not registered in HA — nothing to clear."
else
  # ── Source 2: service-internal runtime state ─────────────────────────────
  # /etc/pve/ha/manager_status is written by the active CRM every cycle and
  # is the authoritative source for internal states (error, starting, freeze,
  # migrate, recovery, ...) that /cluster/ha/resources does not expose.
  MGR_STDERR=$(mktemp)
  set +e
  MANAGER_STATUS_JSON=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${FIRST_NODE_IP}" \
    "cat /etc/pve/ha/manager_status" 2>"$MGR_STDERR")
  MGR_RC=$?
  set -e

  if [[ $MGR_RC -ne 0 || -z "${MANAGER_STATUS_JSON// /}" ]]; then
    echo "ERROR: could not read /etc/pve/ha/manager_status from ${FIRST_NODE_IP} (rc=${MGR_RC})" >&2
    echo "  (fail-closed per issue #688 — vm:${VMID} is HA-registered but its" >&2
    echo "  internal state is undeterminable; refusing to touch a live service)." >&2
    echo "  stderr:" >&2
    sed 's/^/    /' "$MGR_STDERR" >&2 || true
    rm -f "$MGR_STDERR"
    exit 1
  fi
  rm -f "$MGR_STDERR"
  if ! echo "$MANAGER_STATUS_JSON" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "ERROR: /etc/pve/ha/manager_status did not parse as a JSON object" >&2
    echo "  first 5 lines:" >&2
    echo "$MANAGER_STATUS_JSON" | head -5 | sed 's/^/    /' >&2
    exit 1
  fi

  HA_STATE=$(echo "$MANAGER_STATUS_JSON" | \
    jq -r --arg sid "vm:${VMID}" '.service_status[$sid].state // empty' 2>/dev/null || echo "")

  if [[ -z "$HA_STATE" ]]; then
    echo "ERROR: vm:${VMID} is HA-registered but manager_status has no state entry" >&2
    echo "  (fail-closed per issue #688 — indeterminate runtime state)." >&2
    exit 1
  fi

  log "  Current HA state: ${HA_STATE}"

  # Any state that is NOT stopped/disabled means HA is actively managing the
  # service; go through the §6A ladder before destroy so the CRM releases the
  # service cleanly. Under PVE 9.1, live-service states we may see include
  # error / starting / started / freeze / migrate / recovery / request_stop.
  # Only stopped and disabled are safe to destroy under.
  case "$HA_STATE" in
    stopped|disabled)
      log "  vm:${VMID} is already ${HA_STATE} — no §6A ladder step needed."
      ;;
    *)
      log "  Applying §6A ladder: ha-manager set vm:${VMID} --state disabled  (from state=${HA_STATE})"
      do_ssh "$FIRST_NODE_IP" "ha-manager set vm:${VMID} --state disabled"
      log "  Waiting for CRM to transition ${HA_STATE} -> stopped..."
      if [[ "$DRY_RUN" != "true" ]]; then
        sleep 20
      fi
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Step 4a: Ensure VM is stopped (needed before qm destroy) via
#   the sanctioned framework path — never bare qm stop --skiplock.
# ---------------------------------------------------------------------------
VM_STATUS=$(ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" 2>/dev/null | \
  jq -r --argjson vmid "$VMID" '.[] | select(.vmid == $vmid) | .status' 2>/dev/null || echo "")

if [[ -n "$VM_STATUS" ]]; then
  log "  Current VM status: ${VM_STATUS}"
  if [[ "$VM_STATUS" == "running" ]]; then
    # Route through HA if still HA-registered (safer than a bare qm stop).
    if [[ -n "$HA_STATE" ]]; then
      log "  Applying: ha-manager set vm:${VMID} --state stopped"
      do_ssh "$FIRST_NODE_IP" "ha-manager set vm:${VMID} --state stopped"
      if [[ "$DRY_RUN" != "true" ]]; then
        sleep 15
      fi
    else
      # Not in HA. Use qm stop scoped to the actual owner.
      OWNER=$(ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" | \
        jq -r --argjson vmid "$VMID" '.[] | select(.vmid == $vmid) | .node')
      OWNER_IP=$(yq -r ".nodes[] | select(.name == \"${OWNER}\") | .mgmt_ip" "$CONFIG")
      log "  Applying: qm stop ${VMID} on ${OWNER}"
      do_ssh "$OWNER_IP" "qm stop ${VMID}"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 4b: Destroy VM shell (qm destroy) — first from the current owner if known
# ---------------------------------------------------------------------------
echo ""
echo "==> Destroying VM shell for VMID ${VMID}"

OWNER=$(ssh -n -o ConnectTimeout=5 "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" 2>/dev/null | \
  jq -r --argjson vmid "$VMID" '.[] | select(.vmid == $vmid) | .node' 2>/dev/null || echo "")

if [[ -n "$OWNER" && "$OWNER" != "null" ]]; then
  OWNER_IP=$(yq -r ".nodes[] | select(.name == \"${OWNER}\") | .mgmt_ip" "$CONFIG")
  log "  Owner is ${OWNER} (${OWNER_IP})"
  # `--purge` also removes replication jobs; this ensures no stragglers
  # if configure-replication.sh has not already deleted them.
  log "  Applying: qm destroy ${VMID} --purge on ${OWNER}"
  if [[ "$DRY_RUN" != "true" ]]; then
    set +e
    do_ssh "$OWNER_IP" "qm destroy ${VMID} --purge" 2>&1
    set -e
  fi
else
  log "  VM ${VMID} has no owner in cluster resources — likely already destroyed."
fi

# Also remove HA config in case it lingers (post-destroy):
if [[ -n "$HA_STATE" ]]; then
  log "  Applying: ha-manager remove vm:${VMID}  (post-destroy cleanup)"
  if [[ "$DRY_RUN" != "true" ]]; then
    set +e
    do_ssh "$FIRST_NODE_IP" "ha-manager remove vm:${VMID}" 2>&1 || true
    set -e
  fi
fi

# ---------------------------------------------------------------------------
# Step 4c: Destroy stale vm-<vmid>-* zvols on ALL nodes (selective pattern)
# ---------------------------------------------------------------------------
echo ""
echo "==> Cleaning stale zvols cluster-wide for VMID ${VMID}"

for NODE in $NODE_NAMES; do
  NODE_IP=$(yq -r ".nodes[] | select(.name == \"${NODE}\") | .mgmt_ip" "$CONFIG")
  [[ -z "$NODE_IP" || "$NODE_IP" == "null" ]] && continue

  # List candidates
  set +e
  STALE=$(ssh -n -o ConnectTimeout=5 "root@${NODE_IP}" \
    "zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null | grep -E 'vm-${VMID}-'" 2>/dev/null)
  set -e

  if [[ -z "$STALE" ]]; then
    log "  ${NODE}: no vm-${VMID}-* zvols found"
    continue
  fi

  # Selective destroy — the vm-<vmid>-<disk> pattern is safe under
  # Sprint 044 because we already refused if mycofu-park-<vmid>-* exists,
  # so any remaining vm-<vmid>-* dataset is stale post-destroy.
  while IFS= read -r zvol; do
    [[ -z "$zvol" ]] && continue
    log "  ${NODE}: destroying ${zvol}"
    if [[ "$DRY_RUN" != "true" ]]; then
      set +e
      ssh -n -o ConnectTimeout=5 "root@${NODE_IP}" "zfs destroy -r '${zvol}'" 2>&1 || true
      set -e
    fi
  done <<< "$STALE"
done

# ---------------------------------------------------------------------------
# Step 5: STOP with deploy instructions — never `tofu apply` here.
# ---------------------------------------------------------------------------
echo ""
echo "==> Recreate helper complete. VM shell + zvols cleaned for VMID ${VMID}."
echo ""

# Determine which class this VMID is (control plane vs tier-1) via config.yaml
# scan. If VMID belongs to cicd, gitlab, pbs, or hil_boot → control plane
# (workstation-only deploy path). Everything else → Tier-1 pipeline path.
CONTROL_PLANE=false
for KEY in cicd gitlab pbs hil_boot; do
  key_vmid=$(yq -r ".vms.${KEY}.vmid // \"\"" "$CONFIG" 2>/dev/null)
  if [[ "$key_vmid" == "$VMID" ]]; then
    CONTROL_PLANE=true
    break
  fi
done

if [[ "$CONTROL_PLANE" == "true" ]]; then
  cat <<EOF
Next steps (operator, from workstation):

  1. Deploy this VM via the workstation control-plane path:
       framework/scripts/rebuild-cluster.sh --scope control-plane

  2. If this VM is cicd (VMID 160), re-register the GitLab runner AFTER
     the deploy completes:
       framework/scripts/register-runner.sh

  3. Verify:
       framework/scripts/validate.sh

This script has intentionally STOPPED short of any \`tofu apply\`. Per
.claude/rules/destructive-operations.md, apply is operator-attended.
EOF
else
  # Determine env (dev/prod) from VMID's name suffix or pool
  ENV=""
  for KEY in $(yq -r '.vms | keys | .[]' "$CONFIG" 2>/dev/null); do
    key_vmid=$(yq -r ".vms.${KEY}.vmid // \"\"" "$CONFIG" 2>/dev/null)
    if [[ "$key_vmid" == "$VMID" ]]; then
      case "$KEY" in
        *_dev) ENV=dev ;;
        *_prod) ENV=prod ;;
      esac
      break
    fi
  done
  # For app VMs
  if [[ -z "$ENV" ]]; then
    APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
    if [[ -f "$APPS_CONFIG" ]]; then
      for APP in $(yq -r '.applications | keys | .[]' "$APPS_CONFIG" 2>/dev/null); do
        for E in $(yq -r ".applications.${APP}.environments | keys | .[]" "$APPS_CONFIG" 2>/dev/null); do
          key_vmid=$(yq -r ".applications.${APP}.environments.${E}.vmid // \"\"" "$APPS_CONFIG" 2>/dev/null)
          if [[ "$key_vmid" == "$VMID" ]]; then
            ENV="$E"
            break 2
          fi
        done
      done
    fi
  fi
  [[ -z "$ENV" ]] && ENV="<env>"

  cat <<EOF
Next steps (operator, from workstation):

  1. Deploy this VM via safe-apply:
       framework/scripts/safe-apply.sh ${ENV}

  2. Verify:
       framework/scripts/validate.sh ${ENV}

This script has intentionally STOPPED short of any \`tofu apply\`. Per
.claude/rules/destructive-operations.md, apply is operator-attended.
EOF
fi
