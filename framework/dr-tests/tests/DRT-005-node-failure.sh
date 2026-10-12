#!/usr/bin/env bash
# DRT-ID: DRT-005
# DRT-NAME: Node Failure Recovery
# DRT-TIME: ~25-35 min
# DRT-DESTRUCTIVE: yes
# DRT-DESC: Power off the node hosting the most VMs, verify every VM from
#           that node reaches qemu status=running and HA state=started on a
#           survivor under the DRT-005 clock (membership_loss_t0 →
#           recovery_end), keep the permanent #691 qmstart hang tripwire,
#           confirm anti-affinity pairs remain separated, conditionally walk
#           the policy-off override recovery contract only when explicit
#           replicate:false overrides exist, then power the node back on,
#           rebalance, and validate.

set -euo pipefail

DRT_ID="DRT-005"
DRT_NAME="Node Failure Recovery"

# ── Recovery budget (Sprint 048 MR-7 — measured bands from M4) ────────
# Universal replication means every VM has a replica by default. The failover
# predicate is therefore universal: EVERY VM that was running on the failed
# node before power-off must reach qemu status=running AND HA state=started on
# a survivor. There are no state-class exemptions in the recovery wait loop.
#
# `t0` is not the operator prompt, power-command time, fence-trigger time, or
# an HA manager state transition. It is corosync membership loss as observed
# from a survivor's `journalctl -u corosync`, using the idiomatic messages:
# "A processor failed, forming new configuration" OR "A new membership".
# The budget gates on:
#
#   recovery_end - membership_loss_t0
#
# Measured baseline B=136s (M4 attempt-3 PASS 2026-07-23T09:06:02Z, commit
# b9fc097 — first fully unassisted full cycle). Three-run series: 146/146/136.
# Bands set from B per the Sprint 048 recipe:
#   WARN = max(B + 30, ceil(1.15 * B)) = max(166, 157) = 166s
#   FAIL = ceil(1.85 * B) = ceil(1.85 * 136) = 252s
#
# The pre-M4 mode selector (first-run analytic 600s ceiling vs a placeholder
# budget mode) was one-time machinery whose event (the M4 first observed
# clean cycle) has completed. Per design-taste principle 4 (no permanent
# machinery for one-time events), the selector and its 600s path are
# retired here; the measured WARN/FAIL bands above are the only ceiling.
#
# BASELINE_VM_COUNT stays as a documentary literal for the 2026-07 cluster
# shape. It is not a gating input; the shape self-signal fires drt_warn if
# the live migrated-VM count differs.
BASELINE_MIGRATION_SECONDS=136
BASELINE_VM_COUNT=9
DRT005_WARN_SECONDS=166
DRT005_FAIL_SECONDS=252

DRT_PREDICATE_LIST=(
  "EVERY VM from failed node reaches qemu status=running and HA state=started on a survivor"
  "recovery_end - membership_loss_t0 stays below the measured DRT005 hard ceiling (252s)"
  "no HA qmstart wall time reaches 60s for any recovered VM (#691 permanent tripwire)"
  "no VM is in HA error after the recovery window"
  "anti-affinity pairs are not co-located after recovery"
)

source "$(dirname "$0")/../lib/common.sh"

_drt005_epoch_utc() {
  local epoch="$1"
  python3 -c '
import datetime
import sys
epoch = int(sys.argv[1])
print(datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
' "$epoch"
}

_drt005_get_policy_off_all() {
  local helper_err csv
  helper_err=$(mktemp "${TMPDIR:-/tmp}/list-repl-vmids-err.XXXXXX")
  if ! csv=$(framework/scripts/list-replicated-vmids.sh --format csv --mode policy-off all 2>"$helper_err"); then
    echo "FAIL: list-replicated-vmids.sh helper failed (POLICY-OFF): $(cat "$helper_err")" >&2
    rm -f "$helper_err"
    return 1
  fi
  rm -f "$helper_err"
  printf '%s\n' "$csv"
}

_drt005_read_membership_loss_t0() {
  local survivor_ip="$1"
  local start_epoch="${2:-$DRT_START_EPOCH}"
  local lookback_start=$((start_epoch - 60))
  local journal_err journal_out journal_rc matching_lines t0 parse_rc

  journal_err=$(mktemp "${TMPDIR:-/tmp}/drt005-corosync-journal-err.XXXXXX")
  set +e
  journal_out=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${survivor_ip}" \
    "journalctl -u corosync --since '@${lookback_start}' -o short-unix --no-pager" 2>"$journal_err")
  journal_rc=$?
  set -e

  if [[ $journal_rc -ne 0 || -z "${journal_out// /}" ]]; then
    echo "FAIL: could not read corosync journal from survivor ${survivor_ip} (rc=${journal_rc})" >&2
    echo "  Searched with a 60s lookback from DRT_START_EPOCH=${start_epoch}." >&2
    echo "  stderr:" >&2
    sed 's/^/    /' "$journal_err" >&2 || true
    rm -f "$journal_err"
    return 1
  fi
  rm -f "$journal_err"

  matching_lines=$(printf '%s\n' "$journal_out" | \
    grep -E 'A processor failed, forming new configuration|A new membership' || true)

  set +e
  t0=$(printf '%s\n' "$matching_lines" | START_EPOCH="$start_epoch" python3 -c '
import os
import sys
start = int(os.environ["START_EPOCH"])
for line in sys.stdin:
    parts = line.split(None, 1)
    if not parts:
        continue
    try:
        epoch = int(float(parts[0]))
    except Exception:
        continue
    if epoch >= start:
        print(epoch)
        sys.exit(0)
sys.exit(1)
')
  parse_rc=$?
  set -e

  if [[ $parse_rc -ne 0 || -z "${t0// /}" ]]; then
    echo "FAIL: no corosync membership-loss line found on survivor ${survivor_ip}" >&2
    echo "  Required at or after DRT_START_EPOCH=${start_epoch}; journal query used --since @${lookback_start}." >&2
    echo "  Matched messages: A processor failed, forming new configuration | A new membership" >&2
    return 1
  fi

  printf '%s\n' "$t0"
}

drt_init

# ── Preconditions ────────────────────────────────────────────────────

drt_check "validate.sh is green" framework/scripts/validate.sh

drt_check "cluster has 3 nodes" bash -c '
  NODE_COUNT=$(yq -r ".nodes | length" site/config.yaml)
  [[ "$NODE_COUNT" -eq 3 ]]
'

drt_check "anti-affinity pairs on different nodes" bash -c '
  for ENV in prod dev; do
    DNS1_NODE=$(yq -r ".vms.dns1_${ENV}.node" site/config.yaml)
    DNS2_NODE=$(yq -r ".vms.dns2_${ENV}.node" site/config.yaml)
    if [[ "$DNS1_NODE" == "$DNS2_NODE" ]]; then
      echo "dns1_${ENV} and dns2_${ENV} both on $DNS1_NODE"
      exit 1
    fi
  done
'

# Mechanism-present pre-check (Sprint 045 / #513 A2). The tofu-declared negative
# resource-affinity harule (dns-pair module, "dns-<env>-antiaffinity") must
# actually exist in the live HA rule set before the destructive test runs —
# otherwise a green DRT would be measuring un-steered placement and silently
# certify a half-landed A2. Fail-closed: unreadable rules = fatal precondition,
# not a pass.
drt_check "anti-affinity harule present in live HA config (#513/A2)" bash -c '
  NODE_COUNT=$(yq -r ".nodes | length" site/config.yaml)
  RULES=""
  for (( i=0; i<NODE_COUNT; i++ )); do
    NIP=$(yq -r ".nodes[${i}].mgmt_ip" site/config.yaml)
    RULES=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${NIP}" \
      "pvesh get /cluster/ha/rules --output-format json" 2>/dev/null) || RULES=""
    [[ -n "$RULES" ]] && break
  done
  if [[ -z "$RULES" ]]; then
    echo "fail-closed: could not read /cluster/ha/rules from any node"
    exit 1
  fi
  for ENV in prod dev; do
    DNS1_VMID=$(yq -r ".vms.dns1_${ENV}.vmid" site/config.yaml)
    DNS2_VMID=$(yq -r ".vms.dns2_${ENV}.vmid" site/config.yaml)
    echo "$RULES" | DNS1="$DNS1_VMID" DNS2="$DNS2_VMID" ENVN="$ENV" python3 -c "
import sys, json, os
rules = json.loads(sys.stdin.read())
d1 = \"vm:\" + os.environ[\"DNS1\"]
d2 = \"vm:\" + os.environ[\"DNS2\"]
for r in rules:
    if str(r.get(\"type\", \"\")) != \"resource-affinity\":
        continue
    if str(r.get(\"affinity\", \"\")) != \"negative\":
        continue
    res = r.get(\"resources\")
    # /cluster/ha/rules may return resources as a list or a comma-joined string.
    if isinstance(res, str):
        res = [x.strip() for x in res.split(\",\") if x.strip()]
    res = set(res or [])
    if d1 in res and d2 in res:
        sys.exit(0)
sys.stderr.write(
    \"no negative resource-affinity harule covering %s + %s (env %s) — A2 half-landed?\n\"
    % (d1, d2, os.environ[\"ENVN\"]))
sys.exit(1)
" || exit 1
  done
'

# ── Identify target node ────────────────────────────────────────────
# Pick the node hosting the most VMs, but exclude the PBS node
# (powering it off loses backup access).

drt_step "Identifying target node (most VMs, excluding PBS node)"

PBS_NODE=$(drt_config '.vms.pbs.node')
FIRST_NODE_IP=$(drt_config '.nodes[0].mgmt_ip')

# Query actual VM placement from the cluster API
CLUSTER_RESOURCES=$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes \
  "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null)

# Count running VMs per node, excluding the PBS node
TARGET_NODE=$(echo "$CLUSTER_RESOURCES" | python3 -c "
import sys, json, collections
vms = json.loads(sys.stdin.read())
counts = collections.Counter()
for vm in vms:
    if vm.get('type') == 'qemu' and vm.get('status') == 'running':
        counts[vm['node']] += 1
# Remove PBS node from candidates
counts.pop('${PBS_NODE}', None)
if counts:
    print(counts.most_common(1)[0][0])
")

if [[ -z "$TARGET_NODE" ]]; then
  echo "ERROR: Could not identify a target node" >&2
  exit 1
fi

TARGET_NODE_IP=$(drt_node_ip "$TARGET_NODE")
echo "  Target node: ${TARGET_NODE} (${TARGET_NODE_IP})"
echo "  PBS node (excluded): ${PBS_NODE}"

# Record which VMs are on the target node before failure
VMS_ON_TARGET=$(echo "$CLUSTER_RESOURCES" | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    if vm.get('type') == 'qemu' and vm.get('node') == '${TARGET_NODE}' and vm.get('status') == 'running':
        print(f'{vm[\"vmid\"]}  {vm[\"name\"]}')
")
echo "  VMs on target node (all types):"
echo "$VMS_ON_TARGET" | sed 's/^/    /'

# Universal predicate target set: every VM that was running on the failed node
# before power-off is waited on. This is intentionally not filtered by policy
# state; universal replication makes the recovery predicate state-class neutral.
TARGET_VMIDS_CSV=$(echo "$VMS_ON_TARGET" | \
  awk 'NF { print $1 }' | grep -E '^[0-9]+$' | paste -sd, - || true)
echo "  Target-node VMIDs to track through failover: ${TARGET_VMIDS_CSV:-<none>}"
if [[ -z "${TARGET_VMIDS_CSV// /}" ]]; then
  echo "FAIL: no running VMs on target node — DRT-005 has no recovery predicate to measure" >&2
  exit 1
fi

MIGRATED_VM_COUNT=$(printf '%s\n' "$VMS_ON_TARGET" | grep -c '[^[:space:]]' || true)
echo "  Target-node VM count: ${MIGRATED_VM_COUNT}"
echo "  BASELINE_VM_COUNT=${BASELINE_VM_COUNT} is documentary only; it does not gate this run."
echo "  Measured baseline B=${BASELINE_MIGRATION_SECONDS}s (M4 attempt-3 PASS, series 146/146/136)."
echo "  WARN band=${DRT005_WARN_SECONDS}s; hard FAIL ceiling=${DRT005_FAIL_SECONDS}s"

if ! POLICY_OFF_ALL_VMIDS=$(_drt005_get_policy_off_all); then
  exit 1
fi
if [[ -z "${POLICY_OFF_ALL_VMIDS// /}" ]]; then
  DRT005_POLICY_OFF_LEG_ENABLED=false
else
  DRT005_POLICY_OFF_LEG_ENABLED=true
  echo "  Policy-off override VMIDs present: ${POLICY_OFF_ALL_VMIDS}"
fi

# ── Pre-test state ──────────────────────────────────────────────────

drt_fingerprint_state

# ── Node power-off ──────────────────────────────────────────────────

drt_step "Powering off target node: ${TARGET_NODE}"

# TODO: automate AMT power control
drt_expect "Power off node ${TARGET_NODE} (${TARGET_NODE_IP}) now. Use IPMI/AMT/BMC or physical power button."

# ── Verify HA recovery ──────────────────────────────────────────────

drt_step "Waiting for every failed-node VM to recover on survivors (polling every 10s)"

# Identify a surviving node to query
SURVIVING_NODE_IP=""
NODE_COUNT=$(drt_config '.nodes | length')
for (( i=0; i<NODE_COUNT; i++ )); do
  N_NAME=$(drt_config ".nodes[${i}].name")
  N_IP=$(drt_config ".nodes[${i}].mgmt_ip")
  if [[ "$N_NAME" != "$TARGET_NODE" ]]; then
    if ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${N_IP}" true 2>/dev/null; then
      SURVIVING_NODE_IP="$N_IP"
      break
    fi
  fi
done

if [[ -z "$SURVIVING_NODE_IP" ]]; then
  echo "ERROR: No surviving node reachable" >&2
  exit 1
fi
echo "  Using surviving node at ${SURVIVING_NODE_IP} for API queries"

MEMBERSHIP_T0_ERR=$(mktemp "${TMPDIR:-/tmp}/drt005-membership-t0-err.XXXXXX")
MEMBERSHIP_LOSS_T0=""
for (( LOOKUP_WAIT=0; LOOKUP_WAIT<=60; LOOKUP_WAIT+=5 )); do
  set +e
  MEMBERSHIP_LOSS_T0=$(_drt005_read_membership_loss_t0 "$SURVIVING_NODE_IP" "$DRT_START_EPOCH" 2>"$MEMBERSHIP_T0_ERR")
  MEMBERSHIP_T0_RC=$?
  set -e
  if [[ $MEMBERSHIP_T0_RC -eq 0 && -n "${MEMBERSHIP_LOSS_T0// /}" ]]; then
    break
  fi
  sleep 5
done
if [[ -z "${MEMBERSHIP_LOSS_T0// /}" ]]; then
  sed 's/^/  /' "$MEMBERSHIP_T0_ERR" >&2 || true
  rm -f "$MEMBERSHIP_T0_ERR"
  exit 1
fi
rm -f "$MEMBERSHIP_T0_ERR"
echo "  membership_loss_t0=${MEMBERSHIP_LOSS_T0} ($(_drt005_epoch_utc "$MEMBERSHIP_LOSS_T0"))"

VALIDATE_OK=false
RECOVERY_END_EPOCH=""
RECOVERY_SECONDS=""
CURRENT_RESOURCES="[]"
BUDGET_MANAGER_STATUS=""

while true; do
  NOW_EPOCH=$(date +%s)
  WAIT=$((NOW_EPOCH - MEMBERSHIP_LOSS_T0))
  if [[ "$WAIT" -ge "$DRT005_FAIL_SECONDS" ]]; then
    echo "  [${WAIT}s since membership_loss_t0] Measured hard ceiling (${DRT005_FAIL_SECONDS}s) reached before universal recovery predicate converged"
    break
  fi

  echo "  [${WAIT}s since membership_loss_t0] Polling cluster state..."

  set +e
  CURRENT_RESOURCES=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
    "root@${SURVIVING_NODE_IP}" \
    "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null)
  RC=$?
  set -e

  if [[ $RC -ne 0 || -z "$CURRENT_RESOURCES" ]]; then
    echo "    API not available yet"
    sleep 10
    continue
  fi

  # Universal recovery predicate (Sprint 048 / #688 extended):
  # for each VMID captured on the failed node pre-power-off, is it now
  #   (a) qemu status=running on a survivor node, AND
  #   (b) HA state=started per /etc/pve/ha/manager_status?
  # Both are required. A qemu `running` VM whose HA state is still
  # `starting`/`migrate`/`freeze`/`recovery` is not settled.
  BUDGET_MANAGER_STATUS=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
    "root@${SURVIVING_NODE_IP}" "cat /etc/pve/ha/manager_status" 2>/dev/null || echo "")
  if [[ -z "${BUDGET_MANAGER_STATUS// /}" ]] || \
     ! echo "$BUDGET_MANAGER_STATUS" | jq -e 'type == "object" and has("service_status")' >/dev/null 2>&1; then
    echo "    manager_status read transient (empty or non-object) — retrying"
    sleep 10
    continue
  fi

  PENDING_JSON=$(echo "$CURRENT_RESOURCES" | \
    TARGET_VMIDS_CSV="$TARGET_VMIDS_CSV" \
    TARGET="${TARGET_NODE}" \
    MANAGER_STATUS_JSON="$BUDGET_MANAGER_STATUS" \
    python3 -c '
import sys, json, os
target = os.environ["TARGET"]
expected = [int(x) for x in os.environ.get("TARGET_VMIDS_CSV", "").split(",") if x.strip()]
try:
    mgr = json.loads(os.environ["MANAGER_STATUS_JSON"])
except Exception:
    mgr = {}
services = mgr.get("service_status") or {}
by_vmid = {}
for vm in json.loads(sys.stdin.read()):
    if vm.get("type") != "qemu":
        continue
    try:
        by_vmid[int(vm.get("vmid", 0))] = vm
    except Exception:
        continue
pending = []
for vmid in expected:
    vm = by_vmid.get(vmid)
    if vm is None:
        pending.append({"vmid": vmid, "reason": "absent from /cluster/resources"})
        continue
    status = vm.get("status")
    node = vm.get("node")
    if status != "running":
        pending.append({"vmid": vmid, "reason": "qemu status=" + str(status)})
        continue
    if node == target:
        pending.append({"vmid": vmid, "reason": "still on " + str(target)})
        continue
    ha_state = str(services.get("vm:" + str(vmid), {}).get("state", ""))
    if ha_state != "started":
        pending.append({"vmid": vmid, "reason": "HA state=" + (ha_state or "<absent>") + " (need started)"})
        continue
print(json.dumps(pending))
' 2>/dev/null || echo "unknown")

  if [[ "$PENDING_JSON" == "unknown" ]] || ! echo "$PENDING_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "    predicate evaluation transient — retrying"
    sleep 10
    continue
  fi

  PENDING_COUNT=$(echo "$PENDING_JSON" | jq 'length')

  if [[ "$PENDING_COUNT" == "0" ]]; then
    RECOVERY_END_EPOCH=$(date +%s)
    RECOVERY_SECONDS=$((RECOVERY_END_EPOCH - MEMBERSHIP_LOSS_T0))
    echo "    Every VM from ${TARGET_NODE} is qemu running and HA started on survivors in ${RECOVERY_SECONDS}s"
    echo "    recovery_end=${RECOVERY_END_EPOCH} ($(_drt005_epoch_utc "$RECOVERY_END_EPOCH"))"
    VALIDATE_OK=true
    break
  else
    # Emit a compact per-VMID progress line so the operator can see WHY the
    # predicate hasn't cleared (queued qmstart vs still-on-target etc).
    echo "    ${PENDING_COUNT} VM(s) not yet recovered on a survivor:"
    echo "$PENDING_JSON" | jq -r '.[] | "      vmid:\(.vmid) \(.reason)"'
  fi

  sleep 10
done

if [[ "$VALIDATE_OK" != "true" ]]; then
  RECOVERY_END_EPOCH=$(date +%s)
  RECOVERY_SECONDS=$((RECOVERY_END_EPOCH - MEMBERSHIP_LOSS_T0))
  echo "  membership_loss_t0=${MEMBERSHIP_LOSS_T0} ($(_drt005_epoch_utc "$MEMBERSHIP_LOSS_T0"))"
  echo "  recovery_end=<not reached>; last_observed=${RECOVERY_END_EPOCH} ($(_drt005_epoch_utc "$RECOVERY_END_EPOCH"))"
fi

drt_assert "EVERY VM from failed node reaches qemu status=running and HA state=started on a survivor before ${DRT005_FAIL_SECONDS}s ceiling" \
  test "$VALIDATE_OK" = "true"

if [[ "$DRT005_POLICY_OFF_LEG_ENABLED" != "true" ]]; then
  drt_step "Policy-off override contract"
  echo "  SKIP (policy-off set empty — override contract not exercised)"
  echo "  Note: the override contract is exercised only when replicate: false overrides exist; with none, the policy-off-specific ladder is a no-op."
else
  POLICY_OFF_VMIDS="$POLICY_OFF_ALL_VMIDS"
  # Explicit replicate:false overrides remain a special contract. When that
  # set is non-empty, keep the legacy policy-off leg so the override behavior
  # is still exercised instead of silently disappearing.
  drt_step "Policy-off override VMs on dead node are in expected error/stopped state"

# Issue #688 defect 2: `ha-manager status --output-format json` is not a
# valid PVE 9.1.1 command; it exited non-zero, python got empty stdin,
# json.loads("") raised, and the old code path down-graded that to
# `drt_warn` (WARN, not FAIL). Per destruction-safety doctrine
# (.claude/rules/destruction-safety.md — "When a Safety Check Cannot
# Determine State"), a safety check that cannot determine its input is
# a FAIL, not a WARN.
#
# Read the SERVICE-INTERNAL HA state from /etc/pve/ha/manager_status
# (JSON written by the active CRM) — the only PVE 9.1.1 JSON source that
# exposes states like error/starting/started/freeze/migrate/recovery.
# The pvesh /cluster/ha/resources endpoint exposes only REQUESTED state,
# which is not enough here.
POLICY_OFF_HA_STDERR=$(mktemp)
set +e
MANAGER_STATUS_JSON=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
  "root@${SURVIVING_NODE_IP}" "cat /etc/pve/ha/manager_status" 2>"$POLICY_OFF_HA_STDERR")
MANAGER_STATUS_RC=$?
set -e
if [[ $MANAGER_STATUS_RC -ne 0 || -z "${MANAGER_STATUS_JSON// /}" ]]; then
  echo "FAIL: could not read /etc/pve/ha/manager_status from ${SURVIVING_NODE_IP} (rc=${MANAGER_STATUS_RC})" >&2
  echo "  This is a hard FAIL per destruction-safety.md — a policy-off contract" >&2
  echo "  check whose HA-state input is undeterminable is a false-pass surface." >&2
  echo "  stderr:" >&2
  sed 's/^/    /' "$POLICY_OFF_HA_STDERR" >&2 || true
  rm -f "$POLICY_OFF_HA_STDERR"
  exit 1
fi
rm -f "$POLICY_OFF_HA_STDERR"
if ! echo "$MANAGER_STATUS_JSON" | jq -e 'type == "object" and has("service_status")' >/dev/null 2>&1; then
  echo "FAIL: manager_status did not parse as a JSON object with service_status" >&2
  echo "  first 5 lines:" >&2
  echo "$MANAGER_STATUS_JSON" | head -5 | sed 's/^/    /' >&2
  exit 1
fi

# Codex/agy review-round P1: under `set -euo pipefail`, `VAR=$(cmd)` where the
# command exits non-zero causes the outer script to terminate BEFORE `$?` can
# be captured. Wrap the assignment in `set +e ... set -e` (the pattern
# .claude/rules/platform.md documents for "capture the exit code, branch
# on it").
set +e
# Sprint 048 T6.6 codex adversarial review: intersect POLICY-OFF with the
# pre-power-off failed-node VMID set (TARGET_VMIDS_CSV, captured before
# the outage). A `replicate: false` VM that was already at home on a
# SURVIVOR before the outage should stay `started` on that survivor —
# that is normal operation, not a replica surprise. Only policy-off VMs
# that WERE on the failed node contribute to this assertion.
UNEXPECTED_POLICY_OFF_STATE=$(echo "$MANAGER_STATUS_JSON" | \
  POLICY_OFF_CSV="$POLICY_OFF_VMIDS" TARGET_NODE="$TARGET_NODE" \
  FAILED_NODE_VMIDS_CSV="$TARGET_VMIDS_CSV" python3 -c '
import sys, json, os
policy_off = set(int(x) for x in os.environ.get("POLICY_OFF_CSV", "").split(",") if x.strip())
failed_node_vmids = set(int(x) for x in os.environ.get("FAILED_NODE_VMIDS_CSV", "").split(",") if x.strip())
# Restrict the assertion set to POLICY-OFF VMs that were actually on the
# failed node pre-power-off. Others are out of scope for this failover.
scope = policy_off & failed_node_vmids
target = os.environ["TARGET_NODE"]
unexpected = []
try:
    doc = json.loads(sys.stdin.read())
except Exception as ex:
    # Any parse failure here is a hard FAIL for the DRT (return rc=2,
    # printed on stderr). Caller checks rc after `set +e`.
    print("failed to parse manager_status: " + str(ex), file=sys.stderr)
    sys.exit(2)
services = doc.get("service_status") or {}
for sid, e in services.items():
    if not sid.startswith("vm:"):
        continue
    try:
        vmid = int(sid.split(":", 1)[1])
    except Exception:
        continue
    if vmid not in scope:
        continue
    st = str(e.get("state", ""))
    nd = str(e.get("node", ""))
    # Whose HA state is on the target node OR has home on target?
    if nd not in ("", target):
        # HA has already re-placed the service on a survivor (running from
        # replica) — but POLICY-OFF VMs (that were on the failed node)
        # should not have a replica. If we see a running policy-off
        # elsewhere, that is an override-contract violation — either the
        # policy is wrong or a replica somehow existed.
        if st in ("started", "running"):
            unexpected.append("POLICY-OFF vm:" + str(vmid) + " state=" + st + " on " + nd + " — should not have replicated")
        continue
    if st not in ("error", "stopped", "disabled", "request_stop"):
        unexpected.append("POLICY-OFF vm:" + str(vmid) + " state=" + st + " on " + target + " — expected error/stopped/disabled/request_stop")
for u in unexpected:
    print(u, file=sys.stderr)
sys.exit(0 if not unexpected else 1)
' 2>&1)
POLICY_OFF_PY_RC=$?
set -e

# rc=2 (parse error) is a hard FAIL — safety check cannot determine state.
if [[ $POLICY_OFF_PY_RC -eq 2 ]]; then
  echo "FAIL: policy-off state checker parse error" >&2
  echo "$UNEXPECTED_POLICY_OFF_STATE" >&2
  exit 1
fi

# rc=1 (observed unexpected state) is now a hard FAIL, not a WARN.
# Codex adversarial review: the RCA remediation §3 says "Make unexpected
# policy-off behavior a hard DRT failure during acceptance, not a warning.
# A policy-off service that is `starting`, `started`, or consuming HA
# workers is not the expected A6 terminal outcome." A `started` policy-off
# VM on a survivor means either the policy is wrong or a replica exists —
# both are Sprint 047 contract violations, not decisions the operator
# should acknowledge and skip past.
if [[ -n "$UNEXPECTED_POLICY_OFF_STATE" ]]; then
  echo "FAIL: unexpected POLICY-OFF state(s) observed on dead node — see stderr" >&2
  echo "$UNEXPECTED_POLICY_OFF_STATE" >&2
  drt_assert "POLICY-OFF VMs on dead node in expected error/stopped state (issue #688 defect 4)" false
else
  drt_assert "POLICY-OFF VMs on dead node in expected error/stopped state" true
fi
fi

# ── Issue #691 permanent qmstart tripwire ─────────────────────────────
# The #691 haresource damage-limiter (max_restart=0, max_relocate=0 for
# explicit policy-off overrides) prevents the historical ~300s policy-off
# qmstart hang. Keep this detector permanently: every VM recovered from the
# failed node must have qmstart wall time <60s. A task at >=60s is a hard FAIL.
drt_step "Issue #691: detect qmstart wall time >=60s on recovered VMIDs (permanent tripwire)"
NOW_EPOCH=$(date +%s)
LONG_QMSTARTS=""
NODE_COUNT_FOR_TASKS=$(drt_config '.nodes | length')
for (( i=0; i<NODE_COUNT_FOR_TASKS; i++ )); do
  N_NAME=$(drt_config ".nodes[${i}].name")
  N_IP=$(drt_config ".nodes[${i}].mgmt_ip")
  # Skip the failed node — it is offline, no active tasks to query, and a
  # blocked-SSH here should not mask a real hung task on a survivor.
  [[ "$N_NAME" == "$TARGET_NODE" ]] && continue
  # Codex P1: a SURVIVOR node's task-query failure MUST NOT be treated as
  # "no active qmstarts" — that false-passes the detector precisely when
  # the failing node is the one holding a hung LRM worker. Fail closed.
  set +e
  TASKS_JSON=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${N_IP}" \
    "pvesh get /nodes/${N_NAME}/tasks --source active --output-format json" 2>/dev/null)
  TASKS_RC=$?
  set -e
  if [[ $TASKS_RC -ne 0 || -z "${TASKS_JSON// /}" ]]; then
    echo "FAIL: could not query active tasks on survivor ${N_NAME} (rc=${TASKS_RC})" >&2
    echo "  This is fail-closed: a survivor with an unreachable task API could" >&2
    echo "  be the very node holding a hung qmstart worker; treating" >&2
    echo "  the query failure as 'no active qmstarts' would false-pass the" >&2
    echo "  permanent #691 tripwire." >&2
    exit 1
  fi
  if ! echo "$TASKS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "FAIL: /nodes/${N_NAME}/tasks did not parse as JSON array" >&2
    exit 1
  fi
  # Codex/agy P1: `VAR=$(cmd)` under `set -euo pipefail` exits before rc
  # capture when the command inside fails. The python here can raise
  # (uncaught exceptions on unexpected task shapes) — capture rc explicitly.
  HITS_STDERR=$(mktemp)
  set +e
  HITS=$(echo "$TASKS_JSON" | \
    TARGET_VMIDS_CSV="$TARGET_VMIDS_CSV" NOW_EPOCH="$NOW_EPOCH" python3 -c '
import sys, json, os
target_vmids = set(int(x) for x in os.environ.get("TARGET_VMIDS_CSV", "").split(",") if x.strip())
now = int(os.environ["NOW_EPOCH"])
tasks = json.loads(sys.stdin.read())

def parse_vmid(t):
    # PVE exposes the task VMID either as an "id" field (string VMID) or
    # inside the "upid" string. Both are authoritative on some endpoints/
    # PVE versions; try both.
    raw_id = t.get("id")
    if raw_id is not None:
        try:
            return int(str(raw_id))
        except Exception:
            pass
    # UPID shape: "UPID:<node>:<pid>:<pstart>:<starttime>:<type>:<id>:<user>:"
    upid = t.get("upid")
    if upid:
        parts = str(upid).split(":")
        if len(parts) >= 7:
            try:
                return int(parts[6])
            except Exception:
                pass
    return None

hits = []
for t in tasks:
    ttype = str(t.get("type", ""))
    if ttype != "qmstart":
        continue
    vmid = parse_vmid(t)
    if vmid is None or vmid not in target_vmids:
        continue
    try:
        start = int(t.get("starttime", 0))
    except Exception:
        start = 0
    if start == 0:
        continue
    elapsed = now - start
    if elapsed >= 60:
        hits.append({"vmid": vmid, "elapsed_s": elapsed, "upid": t.get("upid", "")})
for h in hits:
    print("qmstart vmid=" + str(h["vmid"]) + " elapsed=" + str(h["elapsed_s"]) + "s upid=" + str(h["upid"]))
' 2>"$HITS_STDERR")
  HITS_RC=$?
  set -e
  if [[ $HITS_RC -ne 0 ]]; then
    # Python raised — a python traceback is not a task hit. Fail closed.
    echo "FAIL: qmstart detector python crashed on ${N_NAME} (rc=${HITS_RC})" >&2
    sed 's/^/    /' "$HITS_STDERR" >&2 || true
    rm -f "$HITS_STDERR"
    exit 1
  fi
  rm -f "$HITS_STDERR"
  if [[ -n "${HITS// /}" ]]; then
    LONG_QMSTARTS+="${N_NAME}:"$'\n'"${HITS}"$'\n'
  fi
done

if [[ -n "${LONG_QMSTARTS// /}" ]]; then
  echo "FAIL: HA qmstart tasks for recovered VMIDs have been running >=60s:" >&2
  echo "$LONG_QMSTARTS" | sed 's/^/    /' >&2
  echo "" >&2
  echo "  This is the permanent #691 qmstart tripwire. The historical failure" >&2
  echo "  mode was the 300-second ZFS zvol-link worker-timeout mechanism in" >&2
  echo "  docs/reports/rca-2026-07-20-drt005-policyoff-start-hang.md." >&2
  echo "" >&2
  echo "  Every recovered failed-node VM must have qmstart wall time <60s." >&2
  drt_assert "no HA qmstart >=60s on recovered VMIDs (#691 permanent tripwire)" false
else
  drt_assert "no HA qmstart >=60s on recovered VMIDs (#691 permanent tripwire)" true
fi

if [[ "$VALIDATE_OK" == "true" ]]; then
  drt_assert "recovery below measured hard ceiling ${DRT005_FAIL_SECONDS}s (actual: ${RECOVERY_SECONDS}s; recovery_end - membership_loss_t0)" \
    test "$RECOVERY_SECONDS" -lt "$DRT005_FAIL_SECONDS"
  if [[ "$RECOVERY_SECONDS" -ge "$DRT005_WARN_SECONDS" ]]; then
    drt_warn "recovery ${RECOVERY_SECONDS}s reached the ${DRT005_WARN_SECONDS}s WARN band (hard FAIL at >=${DRT005_FAIL_SECONDS}s)"
  fi
  echo "  WARN band: >=${DRT005_WARN_SECONDS}s   hard FAIL: >=${DRT005_FAIL_SECONDS}s"
  echo "  membership_loss_t0=${MEMBERSHIP_LOSS_T0} ($(_drt005_epoch_utc "$MEMBERSHIP_LOSS_T0"))"
  echo "  recovery_end=${RECOVERY_END_EPOCH} ($(_drt005_epoch_utc "$RECOVERY_END_EPOCH"))"
  echo "  Actual recovery duration: ${RECOVERY_SECONDS}s"
  echo "  Measured baseline B=${BASELINE_MIGRATION_SECONDS}s (M4 attempt-3 PASS, series 146/146/136); BASELINE_VM_COUNT=${BASELINE_VM_COUNT} documentary."
else
  echo "  Universal recovery predicate never converged — the ceiling failure is recorded above."
fi

# Non-timing hard FAIL: no HA service may be in `error` after the recovery
# window. Undeterminable manager_status is a FAIL, never a SKIP.
drt_step "Checking for HA error states after recovery window"
HA_ERROR_STDERR=$(mktemp)
set +e
HA_ERROR_JSON=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
  "root@${SURVIVING_NODE_IP}" "cat /etc/pve/ha/manager_status" 2>"$HA_ERROR_STDERR")
HA_ERROR_RC=$?
set -e
if [[ $HA_ERROR_RC -ne 0 || -z "${HA_ERROR_JSON// /}" ]]; then
  echo "FAIL: could not read /etc/pve/ha/manager_status for HA error scan (rc=${HA_ERROR_RC})" >&2
  sed 's/^/    /' "$HA_ERROR_STDERR" >&2 || true
  rm -f "$HA_ERROR_STDERR"
  drt_assert "no VM in HA error after recovery window" false
else
  rm -f "$HA_ERROR_STDERR"
  if ! echo "$HA_ERROR_JSON" | jq -e 'type == "object" and has("service_status")' >/dev/null 2>&1; then
    echo "FAIL: /etc/pve/ha/manager_status did not parse for HA error scan" >&2
    drt_assert "no VM in HA error after recovery window" false
  else
    HA_ERROR_SERVICES=$(echo "$HA_ERROR_JSON" | python3 -c '
import json
import sys
doc = json.loads(sys.stdin.read())
services = doc.get("service_status") or {}
for sid, e in sorted(services.items()):
    if str(e.get("state", "")) == "error":
        print(sid + " node=" + str(e.get("node", "")))
')
    if [[ -n "${HA_ERROR_SERVICES// /}" ]]; then
      echo "FAIL: HA service(s) in error after recovery window:" >&2
      echo "$HA_ERROR_SERVICES" | sed 's/^/    /' >&2
      drt_assert "no VM in HA error after recovery window" false
    else
      drt_assert "no VM in HA error after recovery window" true
    fi
  fi
fi

# ── Anti-affinity check on survivors ─────────────────────────────────

drt_step "Checking anti-affinity pairs on surviving nodes"

for ENV in prod dev; do
  DNS1_VMID=$(drt_vm_vmid dns1 "$ENV")
  DNS2_VMID=$(drt_vm_vmid dns2 "$ENV")

  DNS1_ACTUAL=$(echo "$CURRENT_RESOURCES" | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    if vm.get('vmid') == ${DNS1_VMID}:
        print(vm['node']); break
" 2>/dev/null || echo "unknown")

  DNS2_ACTUAL=$(echo "$CURRENT_RESOURCES" | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    if vm.get('vmid') == ${DNS2_VMID}:
        print(vm['node']); break
" 2>/dev/null || echo "unknown")

  echo "  ${ENV}: dns1 on ${DNS1_ACTUAL}, dns2 on ${DNS2_ACTUAL}"
  drt_assert "anti-affinity: dns1_${ENV} and dns2_${ENV} on different nodes" \
    test "$DNS1_ACTUAL" != "$DNS2_ACTUAL"
done

# ── Recovery: power node back on ─────────────────────────────────────

drt_step "Recovery: power node ${TARGET_NODE} back on"

# TODO: automate AMT power control
drt_expect "Power on node ${TARGET_NODE} (${TARGET_NODE_IP}) now."

drt_step "Waiting for node ${TARGET_NODE} to rejoin cluster (up to 120s)"

NODE_REJOINED=false
for (( WAIT=0; WAIT<=120; WAIT+=5 )); do
  if ssh -n -o ConnectTimeout=3 -o BatchMode=yes "root@${TARGET_NODE_IP}" true 2>/dev/null; then
    echo "  Node ${TARGET_NODE} reachable via SSH at ${WAIT}s"

    # Verify it appears in the cluster
    set +e
    CLUSTER_STATUS=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
      "root@${SURVIVING_NODE_IP}" \
      "pvesh get /cluster/status --output-format json" 2>/dev/null)
    RC=$?
    set -e

    if [[ $RC -eq 0 ]]; then
      NODE_ONLINE=$(echo "$CLUSTER_STATUS" | python3 -c "
import sys, json
for n in json.loads(sys.stdin.read()):
    if n.get('type') == 'node' and n.get('name') == '${TARGET_NODE}' and n.get('online') == 1:
        print('yes'); break
" 2>/dev/null || echo "no")

      if [[ "$NODE_ONLINE" == "yes" ]]; then
        echo "  Node ${TARGET_NODE} rejoined cluster at ${WAIT}s"
        NODE_REJOINED=true
        break
      fi
    fi
  fi
  sleep 5
done

drt_assert "node ${TARGET_NODE} rejoined within 120s" test "$NODE_REJOINED" = "true"

if [[ "$DRT005_POLICY_OFF_LEG_ENABLED" != "true" ]]; then
  drt_step "Policy-off recreate/cleanup override contract"
  echo "  Policy-off set empty; no recreate-derivable-vm.sh exercise or §6A ladder to run."
else
# ── Sprint 047 A6 recreate-exercise leg (issue #668) ─────────────────
# Walk the operator-facing recovery contract for a policy-off (derivable)
# VM that landed in terminal HA `error` during the failover: dry-run
# (guards + printed deploy assertion), then the real destroy, then the
# printed deploy (safe-apply.sh dev), then verify the VM is back. After
# the exercise, clear any RESIDUAL policy-off HA `error` states on the
# dead node via the storage-failure-fence §6A ladder so rebalance can
# succeed.
#
# Why here (before rebalance, after node rejoin):
#   - rebalance-cluster.sh FAILs on any HA `error` — the exercise plus
#     the residual cleanup must clear every policy-off error state
#     before rebalance runs. Operator ruling (#668, 2026-07-19) is
#     explicit on this ordering.
#   - recreate-derivable-vm.sh routes HA mutations through the first
#     configured node (nodes[0].mgmt_ip). If the DRT target was pve01
#     (nodes[0]), we need it back online before the exercise. Deferring
#     until node rejoin is the safe sequence for every possible target.
#
# Target selection (operator ruling: testapp-dev or acme-dev, NOT cicd;
# vendor appliances 170/190 are excluded from recreate-derivable-vm.sh
# by its own policy-off-membership + precious guards):
#   1. Prefer testapp_dev — cheapest dev-side policy-off VM, the name
#      the DR-REGISTRY Sprint 047 note carries.
#   2. Fall back to acme_dev — the ruling's named alternative
#      (structurally rare because acme_dev homes on pve03, typically
#      the PBS-excluded target).
#   3. If neither is in HA `error` on this run, drt_assert FAILS — an
#      M4 acceptance run without the recreate contract walked is not
#      certifiable. (Codex/sub-claude round-2 P1: skip-with-WARN plus
#      drt_finish's PASS-with-warnings was a false-pass surface on the
#      acceptance gate.)
#
# Candidate VMIDs come from config.yaml via drt_vm_vmid — no hardcoded
# framework VMIDs (.claude/rules/config-yaml.md).
drt_step "Sprint 047 A6 / issue #668: walk the recreate-derivable-vm.sh contract + clear residual policy-off HA errors"

# Give HA daemons on the just-rejoined node a moment to settle.
# `pvesh get /cluster/status` reports `online=1` slightly before
# pve-ha-crm/pve-ha-lrm are fully leader-elected and heartbeating; the
# recreate helper queries and mutates HA state so racing here can
# produce transient failures (agy round-2 P2).
echo "  [settle] sleeping 15s for HA daemons on rejoined node to stabilize"
sleep 15

RECREATE_TARGET_VMID=""
RECREATE_TARGET_NAME=""
# Read the live HA state once; fail-closed on empty/unparseable output
# (MR-6 P1 lesson: silent-empty capture converts a helper failure into
# a false pass). Capture stderr SEPARATELY so an SSH banner cannot
# corrupt the JSON payload (sub-claude round-2 P2).
#
# Issue #688 defect 2: source is /etc/pve/ha/manager_status (JSON written
# by the active CRM). The previous `ha-manager status --output-format json`
# call is NOT a valid PVE 9.1.1 command; live it exited non-zero and this
# block hard-failed the DRT (Step 8 crash observed 2026-07-20).
HA_STATUS_STDERR=$(mktemp)
set +e
MANAGER_STATUS_JSON=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
  "root@${SURVIVING_NODE_IP}" \
  "cat /etc/pve/ha/manager_status" 2>"$HA_STATUS_STDERR")
HA_STATUS_RC=$?
set -e
if [[ $HA_STATUS_RC -ne 0 || -z "${MANAGER_STATUS_JSON// /}" ]]; then
  echo "FAIL: /etc/pve/ha/manager_status read failed or returned empty output (rc=${HA_STATUS_RC})" >&2
  echo "  stderr:" >&2
  sed 's/^/    /' "$HA_STATUS_STDERR" >&2 || true
  rm -f "$HA_STATUS_STDERR"
  exit 1
fi
if ! echo "$MANAGER_STATUS_JSON" | jq -e 'type == "object" and has("service_status")' >/dev/null 2>&1; then
  echo "FAIL: /etc/pve/ha/manager_status did not parse as a JSON object with service_status" >&2
  echo "  first 5 lines of output:" >&2
  echo "${MANAGER_STATUS_JSON}" | head -5 | sed 's/^/    /' >&2
  rm -f "$HA_STATUS_STDERR"
  exit 1
fi
rm -f "$HA_STATUS_STDERR"

# Reuse the single helper result captured before power-off. The policy-off
# override leg is conditional, so an empty set has already routed around this
# block instead of re-calling the helper or manufacturing a failure.
POLICY_OFF_CSV="$POLICY_OFF_ALL_VMIDS"

# All policy-off VMIDs currently in HA `error` — the residual set the
# recreate exercise + §6A ladder must clear before rebalance.
POLICY_OFF_ERRORS=$(echo "$MANAGER_STATUS_JSON" | \
  POLICY_OFF_CSV="$POLICY_OFF_CSV" python3 -c '
import sys, json, os
policy_off = set(int(x) for x in os.environ.get("POLICY_OFF_CSV", "").split(",") if x.strip())
doc = json.loads(sys.stdin.read())
services = doc.get("service_status") or {}
for sid, e in services.items():
    if not sid.startswith("vm:"): continue
    try:
        vmid = int(sid.split(":", 1)[1])
    except Exception:
        continue
    if vmid in policy_off and str(e.get("state", "")) == "error":
        print(vmid)
')
echo "  policy-off VMIDs in HA \`error\` on this run: ${POLICY_OFF_ERRORS:-<none>}"

# Resolve candidate VMIDs from config.yaml — no hardcoded framework VMIDs
# (agy/sub-claude round-2 P2, .claude/rules/config-yaml.md).
EXERCISE_TESTAPP_VMID=$(drt_vm_vmid testapp dev)
EXERCISE_ACME_VMID=$(drt_vm_vmid acme dev)
echo "  candidates from config: testapp_dev=${EXERCISE_TESTAPP_VMID:-<unset>} acme_dev=${EXERCISE_ACME_VMID:-<unset>}"

for CAND in "${EXERCISE_TESTAPP_VMID}:testapp_dev" "${EXERCISE_ACME_VMID}:acme_dev"; do
  CAND_VMID="${CAND%%:*}"
  CAND_NAME="${CAND##*:}"
  [[ -z "$CAND_VMID" || "$CAND_VMID" == "null" ]] && continue
  if printf '%s\n' "$POLICY_OFF_ERRORS" | grep -qE "^${CAND_VMID}$"; then
    RECREATE_TARGET_VMID="$CAND_VMID"
    RECREATE_TARGET_NAME="$CAND_NAME"
    echo "  Selected exercise target: ${CAND_NAME} (vm:${CAND_VMID})"
    break
  fi
  echo "  skip: ${CAND_NAME} (vm:${CAND_VMID}) not in HA \`error\`"
done

# HARD assertion: an M4 acceptance run without the recreate exercise
# walked is not certifiable. See registry Sprint 047 A6 (3): the leg IS
# the acceptance proof, not an optional decoration.
drt_assert "recreate-exercise target present in HA \`error\` (testapp_dev=${EXERCISE_TESTAPP_VMID} or acme_dev=${EXERCISE_ACME_VMID})" \
  test -n "$RECREATE_TARGET_VMID"

# Track destructive-chain state so a failed dry-run does not cascade
# into the real destroy, and a failed real does not cascade into
# safe-apply (codex round-2 P1: drt_assert is record-and-continue, so
# the chain must gate itself explicitly).
DRY_OK=false
REAL_OK=false

if [[ -n "$RECREATE_TARGET_VMID" ]]; then
  # ── Dry-run leg: guards + printed deploy ────────────────────────
  drt_step "Recreate-exercise dry-run: framework/scripts/recreate-derivable-vm.sh --dry-run ${RECREATE_TARGET_VMID}"
  RECREATE_DRY_OUT=$(mktemp)
  set +e
  framework/scripts/recreate-derivable-vm.sh --dry-run "$RECREATE_TARGET_VMID" > "$RECREATE_DRY_OUT" 2>&1
  RECREATE_DRY_RC=$?
  set -e
  echo "  dry-run exit: ${RECREATE_DRY_RC}"
  # Pipe-safe preview (codex round-2 P3): `sed | head -60` under
  # `set -o pipefail` can SIGPIPE the script; awk with an in-place cap
  # never breaks a pipe.
  awk 'NR<=60 {print "  " $0} NR==61 {print "  [...truncated after 60 lines...]"}' \
    "$RECREATE_DRY_OUT" || true
  drt_assert "recreate-derivable-vm.sh --dry-run ${RECREATE_TARGET_VMID} exits 0 (guards passed)" \
    test "$RECREATE_DRY_RC" -eq 0
  drt_assert "recreate-derivable-vm.sh dry-run announces [DRY-RUN] mutations" \
    grep -qF -- "[DRY-RUN]" "$RECREATE_DRY_OUT"
  drt_assert "recreate-derivable-vm.sh dry-run prints \`safe-apply.sh dev\` as the deploy contract" \
    grep -qE 'safe-apply\.sh dev' "$RECREATE_DRY_OUT"

  if [[ "$RECREATE_DRY_RC" -eq 0 ]] \
     && grep -qF -- "[DRY-RUN]" "$RECREATE_DRY_OUT" \
     && grep -qE 'safe-apply\.sh dev' "$RECREATE_DRY_OUT"; then
    DRY_OK=true
  fi
  rm -f "$RECREATE_DRY_OUT"

  if [[ "$DRY_OK" == "true" ]]; then
    # ── Real leg: destroy VM shell + stale zvols ──────────────────
    drt_step "Recreate-exercise real: framework/scripts/recreate-derivable-vm.sh ${RECREATE_TARGET_VMID}"
    set +e
    framework/scripts/recreate-derivable-vm.sh "$RECREATE_TARGET_VMID"
    RECREATE_REAL_RC=$?
    set -e
    drt_assert "recreate-derivable-vm.sh ${RECREATE_TARGET_VMID} (real) exits 0" \
      test "$RECREATE_REAL_RC" -eq 0

    # Fail-closed VM-absence check (agy round-2 P1, codex round-2 P2).
    # The pre-round-2 version silenced SSH stderr and let `jq` process
    # empty input; jq turns "" into length 0 with exit 0, which
    # false-passes even if the cluster API is dead. This version fails
    # on empty output and on non-array JSON.
    drt_assert "vm:${RECREATE_TARGET_VMID} no longer present in cluster resources after recreate helper" \
      bash -c '
        set -euo pipefail
        RES=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
          "root@'"${SURVIVING_NODE_IP}"'" \
          "pvesh get /cluster/resources --type vm --output-format json")
        [[ -n "${RES// /}" ]] || { echo "empty cluster-resources output" >&2; exit 1; }
        echo "$RES" | jq -e "type == \"array\"" >/dev/null \
          || { echo "cluster-resources output not a JSON array" >&2; exit 1; }
        COUNT=$(echo "$RES" | jq --argjson v '"${RECREATE_TARGET_VMID}"' \
          "[.[] | select(.vmid == \$v)] | length")
        [[ "$COUNT" == "0" ]]
      '
    [[ "$RECREATE_REAL_RC" -eq 0 ]] && REAL_OK=true
  else
    echo "  Skipping real invocation — dry-run rejected the target (dry-run rc=${RECREATE_DRY_RC})"
  fi
fi

# ── Residual §6A ladder cleanup (issue #668 round-2) ─────────────────
# Round-1 covered a single VM. Round-2 reviewers (unanimous) flagged
# that safe-apply.sh dev only touches dev modules, so any OTHER policy-
# off VM on the dead node (302, 404, 600, 602 depending on target) stays
# in HA `error`. rebalance-cluster.sh's verify_recovery FAILs on any
# residual error — the exact BLOCKS-M4 symptom this MR must resolve.
#
# For each residual: apply the storage-failure-fence.md §6A ladder
# (`--state disabled → --state started`). The home node has just come
# back, its local zvols are intact, and without home-preference groups
# HA's `select_service_node` picks the least-loaded online node — the
# just-returned node — restarting the VM in place.
#
# hil_boot and cicd are shared/vendor-adjacent VMs whose recovery
# contract is different (rebuild-cluster.sh --scope control-plane);
# leave them in error with a WARN, do not attempt §6A.
if [[ -n "$POLICY_OFF_ERRORS" ]]; then
  CICD_VMID=$(drt_vm_vmid cicd '')
  HIL_VMID=$(drt_vm_vmid hil_boot '')
  echo ""
  echo "  Clearing residual policy-off HA \`error\` states via §6A ladder"
  echo "  (skips exercise target ${RECREATE_TARGET_VMID:-<none>}, cicd ${CICD_VMID:-<n/a>}, hil_boot ${HIL_VMID:-<n/a>})"
  for VMID_ERR in $POLICY_OFF_ERRORS; do
    if [[ "$VMID_ERR" == "$RECREATE_TARGET_VMID" ]] \
       || [[ -n "$CICD_VMID" && "$VMID_ERR" == "$CICD_VMID" ]] \
       || [[ -n "$HIL_VMID"  && "$VMID_ERR" == "$HIL_VMID"  ]]; then
      echo "  vm:${VMID_ERR}: skipped (exercise target or control-plane/vendor-adjacent)"
      continue
    fi
    echo "  vm:${VMID_ERR}: §6A step 1 — ha-manager set --state disabled"
    ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${SURVIVING_NODE_IP}" \
      "ha-manager set vm:${VMID_ERR} --state disabled" 2>&1 | sed 's/^/    /' || true
    sleep 15
    echo "  vm:${VMID_ERR}: §6A step 2 — ha-manager set --state started"
    ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${SURVIVING_NODE_IP}" \
      "ha-manager set vm:${VMID_ERR} --state started" 2>&1 | sed 's/^/    /' || true
  done
  echo "  [settle] sleeping 45s for CRM to place restarted services"
  sleep 45

  # Verify §6A cleared the residuals; hil_boot/cicd remainders are a
  # documented WARN (they need a different recovery path).
  #
  # Issue #688 defect 2: source is /etc/pve/ha/manager_status (JSON written
  # by the active CRM). The previous `ha-manager status --output-format json`
  # is not a valid PVE 9.1.1 command; live it exited non-zero and the WARN
  # branch below was always taken.
  set +e
  POST_LADDER_JSON=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
    "root@${SURVIVING_NODE_IP}" \
    "cat /etc/pve/ha/manager_status" 2>/dev/null)
  POST_LADDER_RC=$?
  set -e
  if [[ $POST_LADDER_RC -eq 0 && -n "${POST_LADDER_JSON// /}" ]] \
     && echo "$POST_LADDER_JSON" | jq -e 'type == "object" and has("service_status")' >/dev/null 2>&1; then
    STILL_ERR=$(echo "$POST_LADDER_JSON" | \
      POLICY_OFF_CSV="$POLICY_OFF_CSV" python3 -c '
import sys, json, os
policy_off = set(int(x) for x in os.environ.get("POLICY_OFF_CSV", "").split(",") if x.strip())
doc = json.loads(sys.stdin.read())
services = doc.get("service_status") or {}
for sid, e in services.items():
    if not sid.startswith("vm:"): continue
    try:
        vmid = int(sid.split(":", 1)[1])
    except Exception:
        continue
    if vmid in policy_off and str(e.get("state", "")) == "error":
        print(vmid)
')
    if [[ -n "$STILL_ERR" ]]; then
      # Any remaining error is either the exercise target (safe-apply
      # about to redeploy it) or a hil_boot/cicd deliberately skipped.
      # Any OTHER lingering error will break rebalance downstream; WARN
      # so the operator sees the reason in the registry paste block.
      REMAINING=""
      for V in $STILL_ERR; do
        if [[ "$V" != "$RECREATE_TARGET_VMID" ]] \
           && [[ -z "$CICD_VMID" || "$V" != "$CICD_VMID" ]] \
           && [[ -z "$HIL_VMID"  || "$V" != "$HIL_VMID"  ]]; then
          REMAINING="${REMAINING}${V} "
        fi
      done
      if [[ -n "${REMAINING// /}" ]]; then
        drt_warn "§6A cleanup did NOT clear these policy-off HA errors: ${REMAINING}(rebalance may FAIL — investigate before certifying M4)"
      fi
    fi
  else
    # Fail-loud: post-ladder HA-state probe failed, so we cannot verify
    # residual errors cleared. Per destruction-safety.md, a check that
    # cannot determine its answer FAILs (not warns) — a WARN here would
    # let rebalance downstream trip over an uncleared error.
    drt_assert "§6A post-ladder /etc/pve/ha/manager_status probe returns valid JSON (residual-errors clearability determinable)" false
  fi
fi

if [[ "$REAL_OK" == "true" ]]; then
  # ── Printed-deploy leg: safe-apply.sh dev recreates the VM ────
  # The DRT is already an operator-attended destructive envelope, so
  # the `.claude/rules/destructive-operations.md` "no tofu apply" rule
  # does not gate this call — it is the sanctioned deploy printed by
  # the recreate helper (Sprint 047 A6 recovery contract).
  #
  # Invoke directly (NOT through drt_assert) so the operator can watch
  # the 10-15 minute apply's live output rather than staring at a
  # captured-in-variable silence for the whole run (agy round-2 P1).
  drt_step "Recreate-exercise deploy: framework/scripts/safe-apply.sh dev (as printed by helper)"
  set +e
  framework/scripts/safe-apply.sh dev
  SAFE_APPLY_RC=$?
  set -e
  echo "  safe-apply.sh dev exit: ${SAFE_APPLY_RC}"
  drt_assert "safe-apply.sh dev succeeds (recreates ${RECREATE_TARGET_NAME})" \
    test "$SAFE_APPLY_RC" -eq 0

  # ── Verify the VM is back and running (fail-closed poll) ──────
  # Round-2: the pre-fix poll swallowed ssh + jq errors via
  # `2>/dev/null || echo ""`, which is the same silent-empty pattern
  # the MR-6 P1 lesson names. Fail-closed instead — on cluster-API
  # failure the poll surfaces the error rather than spinning silently.
  drt_step "Verifying vm:${RECREATE_TARGET_VMID} is running again (poll up to 180s)"
  drt_assert "vm:${RECREATE_TARGET_VMID} is running after safe-apply.sh dev" \
    bash -c '
      for (( W=0; W<=180; W+=10 )); do
        set +e
        RES=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
          "root@'"${SURVIVING_NODE_IP}"'" \
          "pvesh get /cluster/resources --type vm --output-format json" 2>/tmp/drt005-poll.err)
        RC=$?
        set -e
        if [[ $RC -ne 0 || -z "${RES// /}" ]]; then
          echo "  [${W}s] pvesh failed (rc=$RC) or empty output; stderr:" >&2
          sed "s/^/    /" /tmp/drt005-poll.err >&2 || true
          rm -f /tmp/drt005-poll.err
          sleep 10
          continue
        fi
        rm -f /tmp/drt005-poll.err
        if ! echo "$RES" | jq -e "type == \"array\"" >/dev/null 2>&1; then
          echo "  [${W}s] pvesh output not a JSON array — treating as transient" >&2
          sleep 10
          continue
        fi
        STATUS=$(echo "$RES" | jq -r --argjson v '"${RECREATE_TARGET_VMID}"' \
          "(.[] | select(.vmid == \$v) | .status) // \"absent\"")
        if [[ "$STATUS" == "running" ]]; then
          echo "  vm:'"${RECREATE_TARGET_VMID}"' running at ~${W}s"
          exit 0
        fi
        echo "  [${W}s] vm:'"${RECREATE_TARGET_VMID}"' status=${STATUS}"
        sleep 10
      done
      echo "  vm:'"${RECREATE_TARGET_VMID}"' did not reach status=running within 180s" >&2
      exit 1
    '
fi
fi

# ── Rebalance ────────────────────────────────────────────────────────

drt_step "Running rebalance-cluster.sh"

drt_assert "rebalance-cluster.sh succeeds" framework/scripts/rebalance-cluster.sh

# Allow migrations to settle
sleep 10

# ── Post-rebalance validation ────────────────────────────────────────

# BEGIN issue #696 step 12 retry block
#
# The M4 attempt 1 attended DRT-005 run (2026-07-22, commit 236b09b) passed
# every failover-acceptance criterion but printed RESULT: FAIL on this single
# assertion: `validate.sh` ran IMMEDIATELY after nine failback relocations and
# returned 85/1/2. An identical `validate.sh` minutes later returned 88/0/0.
# The failing inner-check's name was lost because drt_assert only captures a
# 10-line output tail — the specific check was anonymous.
#
# Both defects are harness timing/reporting honesty, not oracle changes. Fix
# per the issue #696 four-item scope:
#   1. Give ONE 75s replication-cycle worth of settle, retry ONCE, and take
#      the second result as final. This mirrors validate.sh's own documented
#      Gatus retry idiom (a bounded second look after a well-understood
#      convergence window). NOT a general retry mechanism — no loops, no
#      configurability, bounded to exactly one retry. Flagged for reviewer
#      scrutiny against the no-systematized-retries doctrine: this is
#      justified by the post-failback replication-cycle window, not by
#      normalized deviance around a flaky check.
#   2. Persist each attempt's COMPLETE output to a per-run log directory as
#      separate files (validate-attempt-N.log) and reference them by name
#      from the main log so a failing inner check is never anonymous again.
#
# The second-attempt failure path is drt_assert (hard DRT FAIL), not
# drt_warn — operator ruling per issue #696.
drt_step "Running validate.sh after rebalance (issue #696: settle-then-retry, bounded once)"

DRT005_LOGDIR="logs/DRT-005-${DRT_COMMIT}-${DRT_START_EPOCH}"
mkdir -p "$DRT005_LOGDIR"
VALIDATE_ATTEMPT_1_LOG="${DRT005_LOGDIR}/validate-attempt-1.log"
VALIDATE_ATTEMPT_2_LOG="${DRT005_LOGDIR}/validate-attempt-2.log"

echo "  attempt 1 full output → ${VALIDATE_ATTEMPT_1_LOG}"
set +e
framework/scripts/validate.sh > "$VALIDATE_ATTEMPT_1_LOG" 2>&1
VALIDATE_ATTEMPT_1_RC=$?
set -e

if [[ $VALIDATE_ATTEMPT_1_RC -eq 0 ]]; then
  drt_assert "validate.sh passes after rebalance (attempt 1; full output ${VALIDATE_ATTEMPT_1_LOG})" true
else
  echo "  post-churn attempt 1 failed (rc=${VALIDATE_ATTEMPT_1_RC}); settling 75s for one replication cycle"
  echo "  attempt 1 tail (full output at ${VALIDATE_ATTEMPT_1_LOG}):"
  # `|| true` guards against a path-write failure (mkdir raced, disk full,
  # read-only mount) turning a diagnostic tail into a `set -e` abort that
  # would strip the terminal drt_assert verdict. The full output is the
  # authoritative record; the tail is a scrollback convenience.
  tail -20 "$VALIDATE_ATTEMPT_1_LOG" 2>/dev/null | sed 's/^/    /' || true
  sleep 75
  echo "  attempt 2 full output → ${VALIDATE_ATTEMPT_2_LOG}"
  set +e
  framework/scripts/validate.sh > "$VALIDATE_ATTEMPT_2_LOG" 2>&1
  VALIDATE_ATTEMPT_2_RC=$?
  set -e
  if [[ $VALIDATE_ATTEMPT_2_RC -ne 0 ]]; then
    echo "  attempt 2 tail (full output at ${VALIDATE_ATTEMPT_2_LOG}):"
    tail -20 "$VALIDATE_ATTEMPT_2_LOG" 2>/dev/null | sed 's/^/    /' || true
  fi
  # Second result is final. Failure here is a hard DRT FAIL (not drt_warn) —
  # a 75s settle covers 60s replication cadence + ~15s job execution and
  # propagation. If the next clean attempted rerun's attempt-1 log does NOT
  # implicate a replication-cycle-sensitive check, this settle should be
  # RETIRED or replaced with a check-specific wait rather than left in place
  # as a general retry mechanism (design-taste principles 3, 5).
  drt_assert "validate.sh passes after rebalance (attempt 2 of 2 after 75s settle; outputs: ${VALIDATE_ATTEMPT_1_LOG}, ${VALIDATE_ATTEMPT_2_LOG})" \
    test "$VALIDATE_ATTEMPT_2_RC" -eq 0
fi
# END issue #696 step 12 retry block

# ── Post-recovery hardening assertions (Sprint 045 / #515, A4) ───────

drt_step "Post-recovery assertions (#514 verify + vaccine soak + anti-affinity re-separation)"

# (1) #514: rebalance's own recovery verifier must be green — no HA service left
#     in error, every config-enabled VM running. verify-only mode is read-only.
drt_assert "MYCOFU_REBALANCE_ONLY_VERIFY=1 rebalance-cluster.sh exits 0 (#514)" \
  env MYCOFU_REBALANCE_ONLY_VERIFY=1 framework/scripts/rebalance-cluster.sh

# (2) Vaccine soak (#512/A3): the full failover→rebalance cycle must mint zero
#     rename-victim cidata. The #511 detector, scoped to the rename check, is the
#     oracle (MYCOFU_VALIDATE_ONLY_CIDATA_RENAME).
drt_assert "MYCOFU_VALIDATE_ONLY_CIDATA_RENAME=1 validate.sh exits 0 (vaccine soak)" \
  env MYCOFU_VALIDATE_ONLY_CIDATA_RENAME=1 framework/scripts/validate.sh

# (3) M1 side-finding (#513): PVE 9.1.1 HA honors resource-affinity rules for LIVE
#     placement — when the downed node recovers the negative rule ACTIVELY
#     re-separates the DNS pair (~30s live migration observed in M1). With >=2
#     healthy nodes the pair MUST be on distinct nodes again (UC7); under a single
#     survivor co-location is correct (strict=false) and this assertion is skipped.
POST_RESOURCES=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes \
  "root@${SURVIVING_NODE_IP}" \
  "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null || echo "")

HEALTHY_NODES=0
for (( i=0; i<NODE_COUNT; i++ )); do
  N_IP=$(drt_config ".nodes[${i}].mgmt_ip")
  if ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${N_IP}" true 2>/dev/null; then
    HEALTHY_NODES=$((HEALTHY_NODES + 1))
  fi
done
echo "  Healthy nodes: ${HEALTHY_NODES}"

if [[ "$HEALTHY_NODES" -lt 2 ]]; then
  echo "  <2 healthy nodes — skipping re-separation assertion"
  echo "  (single-survivor co-location is correct; strict=false yields, UC7)"
elif [[ -z "$POST_RESOURCES" ]]; then
  # Fail-loud: we HAVE ≥2 healthy nodes but could not read
  # /cluster/resources on the survivor. Cannot determine placement, so
  # cannot certify re-separation. Per destruction-safety.md, this is
  # FAIL (not SKIP): a check that cannot determine its answer fails.
  drt_assert "post-recovery anti-affinity re-separation determinable (pvesh /cluster/resources readable on survivor)" false
else
  for ENV in prod dev; do
    DNS1_VMID=$(drt_vm_vmid dns1 "$ENV")
    DNS2_VMID=$(drt_vm_vmid dns2 "$ENV")

    DNS1_ACTUAL=$(echo "$POST_RESOURCES" | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    if vm.get('vmid') == ${DNS1_VMID}:
        print(vm['node']); break
" 2>/dev/null || echo "unknown")

    DNS2_ACTUAL=$(echo "$POST_RESOURCES" | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    if vm.get('vmid') == ${DNS2_VMID}:
        print(vm['node']); break
" 2>/dev/null || echo "unknown")

    echo "  post-recovery ${ENV}: dns1 on ${DNS1_ACTUAL}, dns2 on ${DNS2_ACTUAL}"
    drt_assert "post-recovery anti-affinity: dns1_${ENV}/dns2_${ENV} re-separated (>=2 healthy)" \
      test "$DNS1_ACTUAL" != "$DNS2_ACTUAL"
  done
fi

# ── Verify state preserved ───────────────────────────────────────────

drt_step "Verifying application state preserved"

drt_verify_state_fingerprint

# ── Done ─────────────────────────────────────────────────────────────

drt_finish
