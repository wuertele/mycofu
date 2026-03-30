#!/usr/bin/env bash
# DRT-ID: DRT-007
# DRT-NAME: Backup Spot-Check
# DRT-TIME: ~15 min
# DRT-DESTRUCTIVE: no
# DRT-DESC: Non-destructive backup verification. Restores vdb from PBS
#           into a temporary VM (VMID 9999), boots it, checks for
#           app-specific state signals, then destroys the temp VM.
#           Does NOT touch the running production VM.
#           Default target: gitlab. Override with DRT_SPOT_VM env var.

set -euo pipefail

DRT_ID="DRT-007"
DRT_NAME="Backup Spot-Check"

source "$(dirname "$0")/../lib/common.sh"

drt_init

# ── Configuration ────────────────────────────────────────────────────

TARGET_VM="${DRT_SPOT_VM:-gitlab}"
TEMP_VMID=9999
DOMAIN=$(drt_domain)
STORAGE_POOL=$(drt_config '.proxmox.storage_pool // "vmstore"')

# ── Cleanup trap ─────────────────────────────────────────────────────
# Ensure temp VM is destroyed regardless of how the script exits.
# HOSTING_NODE_IP is set later; the trap reads it at execution time.
cleanup_temp_vm() {
  if [[ -n "${HOSTING_NODE_IP:-}" ]]; then
    echo ""
    echo "[CLEANUP] Destroying temp VM ${TEMP_VMID}..."
    ssh -n -o ConnectTimeout=10 -o BatchMode=yes "root@${HOSTING_NODE_IP}" \
      "qm stop ${TEMP_VMID} --skiplock 1 2>/dev/null; sleep 3; qm destroy ${TEMP_VMID} --purge 2>/dev/null" 2>/dev/null || true
  fi
}
trap cleanup_temp_vm EXIT

echo "  Target VM: ${TARGET_VM}"
echo "  Temp VMID: ${TEMP_VMID}"

# ── Resolve target VM identity ───────────────────────────────────────
# Try infrastructure VMs first (shared, no env suffix), then with prod suffix,
# then applications.

TARGET_VMID=""
TARGET_ENV="prod"

# Shared infra VMs (gitlab, pbs, cicd) — no env suffix in config key
TARGET_VMID=$(drt_vm_vmid "$TARGET_VM" "")
if [[ -z "$TARGET_VMID" ]]; then
  # Per-env infra VMs (vault, dns1, etc.) — try prod
  TARGET_VMID=$(drt_vm_vmid "$TARGET_VM" prod)
fi
if [[ -z "$TARGET_VMID" ]]; then
  # Application VMs — try prod
  TARGET_VMID=$(yq -r ".applications.${TARGET_VM}.environments.prod.vmid // empty" \
    site/applications.yaml 2>/dev/null)
fi

if [[ -z "$TARGET_VMID" ]]; then
  echo "ERROR: Could not resolve VMID for '${TARGET_VM}'" >&2
  exit 1
fi

echo "  Resolved VMID: ${TARGET_VMID}"

# ── Preconditions ────────────────────────────────────────────────────

FIRST_NODE_IP=$(drt_config '.nodes[0].mgmt_ip')
PBS_IP=$(drt_vm_ip pbs "")

drt_check "PBS reachable" bash -c "
  ssh -n -o ConnectTimeout=5 -o BatchMode=yes root@${PBS_IP} true 2>/dev/null
"

drt_check "PBS storage registered in Proxmox" bash -c "
  ssh -n -o ConnectTimeout=5 -o BatchMode=yes root@${FIRST_NODE_IP} \
    'pvesm status 2>/dev/null' | grep -q pbs-nas
"

# Query available backups for target VMID
BACKUP_JSON=$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes \
  "root@${FIRST_NODE_IP}" \
  "pvesh get /nodes/\$(hostname)/storage/pbs-nas/content --output-format json 2>/dev/null" || echo "[]")

LATEST_VOLID=$(echo "$BACKUP_JSON" | python3 -c "
import sys, json
backups = [b for b in json.loads(sys.stdin.read()) if b.get('vmid') == ${TARGET_VMID}]
if backups:
    latest = max(backups, key=lambda b: b.get('ctime', 0))
    print(latest['volid'])
" 2>/dev/null)

drt_check "at least one backup exists for ${TARGET_VM} (VMID ${TARGET_VMID})" \
  test -n "$LATEST_VOLID"

echo "  Latest backup: ${LATEST_VOLID}"

drt_check "temp VMID ${TEMP_VMID} is not in use" bash -c "
  ! ssh -n -o ConnectTimeout=5 -o BatchMode=yes root@${FIRST_NODE_IP} \
    'qm status ${TEMP_VMID}' 2>/dev/null | grep -q 'status:'
"

# ── Identify hosting node ────────────────────────────────────────────

drt_step "Identifying hosting node for ${TARGET_VM} (VMID ${TARGET_VMID})"

CLUSTER_RESOURCES=$(ssh -n -o ConnectTimeout=10 -o BatchMode=yes \
  "root@${FIRST_NODE_IP}" \
  "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null)

HOSTING_NODE=$(echo "$CLUSTER_RESOURCES" | python3 -c "
import sys, json
for v in json.loads(sys.stdin.read()):
    if v.get('vmid') == ${TARGET_VMID}:
        print(v['node']); break
" 2>/dev/null)

if [[ -z "$HOSTING_NODE" ]]; then
  # VM might be stopped; fall back to config.yaml node assignment
  HOSTING_NODE=$(drt_config ".vms.${TARGET_VM}.node // empty")
  if [[ -z "$HOSTING_NODE" ]]; then
    HOSTING_NODE=$(drt_config '.nodes[0].name')
  fi
  echo "  VM not running; using config node: ${HOSTING_NODE}"
else
  echo "  Hosting node: ${HOSTING_NODE}"
fi

HOSTING_NODE_IP=$(drt_node_ip "$HOSTING_NODE")
echo "  Hosting node IP: ${HOSTING_NODE_IP}"

# ── Restore backup to temp VM ────────────────────────────────────────

drt_step "Restoring backup to temp VM (VMID ${TEMP_VMID}) on ${HOSTING_NODE}"

drt_assert "qmrestore to temp VMID ${TEMP_VMID}" bash -c "
  ssh -n -o ConnectTimeout=30 -o BatchMode=yes root@${HOSTING_NODE_IP} \
    \"qmrestore '${LATEST_VOLID}' ${TEMP_VMID} --force --start 0\" 2>&1
"

# ── Start temp VM ────────────────────────────────────────────────────

drt_step "Starting temp VM ${TEMP_VMID}"

ssh -n -o ConnectTimeout=10 -o BatchMode=yes "root@${HOSTING_NODE_IP}" \
  "qm start ${TEMP_VMID}" 2>/dev/null || true

# Wait for VM to boot and be reachable. The temp VM gets the same disk
# content as the original, but may have a different network config or no
# DHCP. We try to find its IP from the Proxmox agent or by scanning the
# VM config.
echo "  Waiting for temp VM to boot (up to 120s)..."

TEMP_VM_IP=""
for (( W=0; W<=120; W+=10 )); do
  # Try the Proxmox QEMU agent for the IP
  set +e
  AGENT_DATA=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${HOSTING_NODE_IP}" \
    "qm agent ${TEMP_VMID} network-get-interfaces 2>/dev/null" 2>/dev/null)
  set -e

  if [[ -n "$AGENT_DATA" ]]; then
    TEMP_VM_IP=$(echo "$AGENT_DATA" | python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    result = data if isinstance(data, list) else data.get('result', data)
    for iface in result:
        for addr in iface.get('ip-addresses', []):
            ip = addr.get('ip-address', '')
            if ip and not ip.startswith('127.') and ':' not in ip:
                print(ip)
                raise SystemExit(0)
except Exception:
    pass
" 2>/dev/null)
  fi

  if [[ -n "$TEMP_VM_IP" ]]; then
    echo "  Temp VM IP: ${TEMP_VM_IP} (detected at ${W}s)"
    break
  fi
  sleep 10
done

# ── Verify app-specific state signal ─────────────────────────────────

drt_step "Verifying app-specific state signal for ${TARGET_VM}"

SSH_OPTS="-n -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

case "$TARGET_VM" in
  gitlab)
    # Four-layer verification stack. Each layer builds on the previous.
    # Failures at different layers point to different root causes.
    if [[ -z "$TEMP_VM_IP" ]]; then
      echo "  Could not detect temp VM IP — cannot verify GitLab state"
      drt_assert "temp VM IP detected for GitLab verification" false
    else
      # Wait for VM to be SSH-reachable (boot + vdb mount)
      echo "  Waiting for temp VM SSH (up to 60s)..."
      SSH_READY=false
      for (( W=0; W<=60; W+=5 )); do
        if ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" true 2>/dev/null; then
          SSH_READY=true
          break
        fi
        sleep 5
      done

      if [[ "$SSH_READY" != "true" ]]; then
        echo "  Temp VM not SSH-reachable after 60s"
        drt_assert "temp VM SSH reachable for GitLab verification" false
      else
        # ── Layer 1: Restore integrity (filesystem) ──
        echo ""
        echo "    Layer 1: Restore integrity"

        PG_BASE_EXISTS=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
          "test -d /var/lib/gitlab/postgresql/base/ && echo yes || echo no" 2>/dev/null || echo "no")
        echo "      PostgreSQL base/ exists: ${PG_BASE_EXISTS}"

        PG_VERSION=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
          "cat /var/lib/gitlab/postgresql/PG_VERSION 2>/dev/null" 2>/dev/null || echo "")
        echo "      PG_VERSION: ${PG_VERSION:-missing}"

        PG_BASE_MB=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
          "du -sm /var/lib/gitlab/postgresql/base/ 2>/dev/null | cut -f1" 2>/dev/null || echo "0")
        PG_BASE_SIZE=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
          "du -sh /var/lib/gitlab/postgresql/base/ 2>/dev/null | cut -f1" 2>/dev/null || echo "0")
        echo "      Data directory size: ${PG_BASE_SIZE}"

        drt_assert "PostgreSQL data directory present and non-trivial (${PG_BASE_SIZE} > 50MB)" \
          test "${PG_BASE_MB:-0}" -gt 50
        drt_assert "PG_VERSION file exists" \
          test -n "${PG_VERSION}"

        # ── Layer 2: Database connectivity (psql via postgres superuser) ──
        echo ""
        echo "    Layer 2: Database connectivity"

        PSQL_RESULT=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
          "su -s /bin/sh postgres -c \"psql -d gitlab -tAc 'SELECT 1;'\"" 2>&1 || echo "FAILED")
        echo "      psql connection test: SELECT 1 → ${PSQL_RESULT}"

        drt_assert "PostgreSQL accepts connections via postgres superuser" \
          test "${PSQL_RESULT}" = "1"

        # ── Layer 3: Application data integrity (psql project count) ──
        echo ""
        echo "    Layer 3: Application data integrity"

        PROJECT_COUNT=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
          "su -s /bin/sh postgres -c \"psql -d gitlab -tAc 'SELECT COUNT(*) FROM projects;'\"" 2>&1 || echo "0")
        echo "      GitLab project count (via psql): ${PROJECT_COUNT}"

        drt_assert "GitLab projects table contains real data (${PROJECT_COUNT} projects)" \
          test "${PROJECT_COUNT:-0}" -gt 0

        # ── Layer 4: API reachability (informational, not asserted) ──
        echo ""
        echo "    Layer 4: API reachability (informational)"

        API_COUNT=""
        HTTP_CODE=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
          "curl -sk --max-time 10 -o /dev/null -w '%{http_code}' https://127.0.0.1/api/v4/projects 2>/dev/null" 2>/dev/null || echo "000")
        if [[ "$HTTP_CODE" == "200" ]]; then
          API_COUNT=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
            "curl -sk --max-time 10 https://127.0.0.1/api/v4/projects 2>/dev/null" 2>/dev/null \
            | python3 -c "import sys,json; print(len(json.loads(sys.stdin.read())))" 2>/dev/null || echo "?")
        fi
        echo "      GitLab API HTTP: ${HTTP_CODE}"
        echo "      GitLab API project count: ${API_COUNT:-unavailable}"

        if [[ -n "$API_COUNT" && "$API_COUNT" != "?" && "$API_COUNT" -gt 0 ]] 2>/dev/null; then
          echo "[NOTE] API project count: ${API_COUNT} (API verification succeeded —"
          echo "       layers 1-3 confirmed and API also working)"
        else
          echo "[NOTE] API returned ${API_COUNT:-unavailable} — expected on temp VM due to peer auth"
          echo "       limitation. Layers 1-3 confirm backup integrity."
        fi
      fi
    fi
    ;;

  vault|vault_prod)
    if [[ -n "$TEMP_VM_IP" ]]; then
      echo "  Checking Vault initialized state..."
      # Vault auto-starts; check /v1/sys/health (unauthenticated)
      VAULT_READY=false
      for (( W=0; W<=60; W+=5 )); do
        set +e
        HEALTH=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
          "curl -sk --max-time 10 https://127.0.0.1:8200/v1/sys/health 2>/dev/null" 2>/dev/null)
        set -e
        if echo "$HEALTH" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); exit(0 if d.get('initialized') else 1)" 2>/dev/null; then
          VAULT_READY=true
          echo "  Vault reports initialized at ${W}s"
          break
        fi
        sleep 5
      done
      drt_assert "Vault is initialized in restored backup" test "$VAULT_READY" = "true"
    else
      echo "  Could not detect temp VM IP — cannot verify Vault state"
      drt_assert "temp VM IP detected for Vault verification" false
    fi
    ;;

  influxdb|influxdb_prod)
    if [[ -n "$TEMP_VM_IP" ]]; then
      echo "  Checking InfluxDB org exists..."
      INFLUX_TOKEN=$(drt_sops_value '.influxdb_admin_token')
      INFLUX_READY=false
      for (( W=0; W<=60; W+=5 )); do
        set +e
        ORG_NAME=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
          "curl -sk --max-time 10 'https://127.0.0.1:8086/api/v2/orgs' -H 'Authorization: Token ${INFLUX_TOKEN}' 2>/dev/null" 2>/dev/null \
          | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d.get('orgs',[{}])[0].get('name',''))" 2>/dev/null)
        set -e
        if [[ -n "$ORG_NAME" ]]; then
          INFLUX_READY=true
          echo "  InfluxDB org: ${ORG_NAME} (at ${W}s)"
          break
        fi
        sleep 5
      done
      drt_assert "InfluxDB org exists in restored backup" test "$INFLUX_READY" = "true"
    else
      echo "  Could not detect temp VM IP — cannot verify InfluxDB state"
      drt_assert "temp VM IP detected for InfluxDB verification" false
    fi
    ;;

  roon|roon_prod)
    if [[ -n "$TEMP_VM_IP" ]]; then
      echo "  Checking RoonServer directory..."
      set +e
      ROON_DIR_SIZE=$(ssh ${SSH_OPTS} "root@${TEMP_VM_IP}" \
        "du -sh /var/lib/roon-server/RoonServer/ 2>/dev/null | cut -f1" 2>/dev/null)
      set -e
      echo "  RoonServer dir size: ${ROON_DIR_SIZE:-empty/missing}"
      drt_assert "RoonServer directory non-empty" bash -c "
        [[ -n '${ROON_DIR_SIZE:-}' && '${ROON_DIR_SIZE:-}' != '0' ]]
      "
    else
      echo "  Could not detect temp VM IP — cannot verify Roon state"
      drt_assert "temp VM IP detected for Roon verification" false
    fi
    ;;

  *)
    echo "  No app-specific verification defined for '${TARGET_VM}'"
    echo "  Checking if temp VM is running as a basic sanity check"
    TEMP_STATUS=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${HOSTING_NODE_IP}" \
      "qm status ${TEMP_VMID} 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "unknown")
    drt_assert "temp VM is running" test "$TEMP_STATUS" = "running"
    ;;
esac

# ── Cleanup handled by EXIT trap (cleanup_temp_vm) ───────────────────

# ── Baseline ─────────────────────────────────────────────────────────

echo ""
echo "  Baseline: not yet established"

# ── Done ─────────────────────────────────────────────────────────────

drt_finish
