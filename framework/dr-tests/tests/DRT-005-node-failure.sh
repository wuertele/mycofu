#!/usr/bin/env bash
# DRT-ID: DRT-005
# DRT-NAME: Node Failure Recovery
# DRT-TIME: ~10 min
# DRT-DESTRUCTIVE: yes
# DRT-DESC: Power off the node hosting the most VMs, verify HA migrates
#           VMs to survivors within 120s, confirm anti-affinity pairs
#           remain separated, then power the node back on and rebalance.

set -euo pipefail

DRT_ID="DRT-005"
DRT_NAME="Node Failure Recovery"

source "$(dirname "$0")/../lib/common.sh"

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
echo "  VMs on target node:"
echo "$VMS_ON_TARGET" | sed 's/^/    /'

# ── Pre-test state ──────────────────────────────────────────────────

drt_fingerprint_state

# ── Node power-off ──────────────────────────────────────────────────

drt_step "Powering off target node: ${TARGET_NODE}"

# TODO: automate AMT power control
drt_expect "Power off node ${TARGET_NODE} (${TARGET_NODE_IP}) now. Use IPMI/AMT/BMC or physical power button."

POWEROFF_EPOCH=$(date +%s)

# ── Verify HA migration ────────────────────────────────────────────

drt_step "Waiting for HA to migrate VMs (polling every 10s, up to 180s)"

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

VALIDATE_OK=false
ELAPSED_AT_PASS=0

for (( WAIT=0; WAIT<=180; WAIT+=10 )); do
  echo "  [${WAIT}s] Polling cluster state..."

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

  # Check: no running VMs on the target node
  VMS_STILL_ON_TARGET=$(echo "$CURRENT_RESOURCES" | python3 -c "
import sys, json
count = 0
for vm in json.loads(sys.stdin.read()):
    if vm.get('type') == 'qemu' and vm.get('node') == '${TARGET_NODE}' and vm.get('status') == 'running':
        count += 1
print(count)
" 2>/dev/null || echo "unknown")

  if [[ "$VMS_STILL_ON_TARGET" == "0" ]]; then
    NOW_EPOCH=$(date +%s)
    ELAPSED_AT_PASS=$((NOW_EPOCH - POWEROFF_EPOCH))
    echo "    All VMs migrated off ${TARGET_NODE} in ~${ELAPSED_AT_PASS}s"
    VALIDATE_OK=true
    break
  else
    echo "    ${VMS_STILL_ON_TARGET} VM(s) still on ${TARGET_NODE}"
  fi

  sleep 10
done

drt_assert "VMs migrated off failed node" test "$VALIDATE_OK" = "true"
drt_assert "migration completed within 120s (actual: ${ELAPSED_AT_PASS}s)" \
  test "$ELAPSED_AT_PASS" -le 120
echo "  Baseline: <120s migration (2026-03-23)"
echo "  Actual:   ${ELAPSED_AT_PASS}s"

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

# ── Rebalance ────────────────────────────────────────────────────────

drt_step "Running rebalance-cluster.sh"

drt_assert "rebalance-cluster.sh succeeds" framework/scripts/rebalance-cluster.sh

# Allow migrations to settle
sleep 10

# ── Post-rebalance validation ────────────────────────────────────────

drt_step "Running validate.sh after rebalance"

drt_assert "validate.sh passes after rebalance" framework/scripts/validate.sh

# ── Verify state preserved ───────────────────────────────────────────

drt_step "Verifying application state preserved"

drt_verify_state_fingerprint

# ── Done ─────────────────────────────────────────────────────────────

drt_finish
