#!/usr/bin/env bash
# validate.sh — Comprehensive infrastructure validation suite.
#
# Usage:
#   framework/scripts/validate.sh              # Run all checks (prod + dev)
#   framework/scripts/validate.sh prod         # Run prod checks only
#   framework/scripts/validate.sh dev          # Run dev checks only
#   framework/scripts/validate.sh --quick dev  # Skip slow checks, dev only
#   framework/scripts/validate.sh --regression-safe dev   # Non-destructive regression, dev + cluster-wide
#   framework/scripts/validate.sh --regression-safe prod  # Non-destructive regression, prod + cluster-wide
#   framework/scripts/validate.sh --regression dev        # Full regression incl. destructive (dev ONLY)
#   framework/scripts/validate.sh --regression prod       # REFUSED — destructive tests cannot target prod
#   framework/scripts/validate.sh --regression-deploy dev # Destroy+redeploy dev VMs, then full regression (dev→prod gate)
#
# Regression test scopes:
#   cluster    — tests cluster-wide properties, run regardless of env arg
#   cross-env  — tests spanning both environments, always query both
#   env        — tests for the specified environment only
#   destructive — modifies state, dev ONLY (requires --regression dev)
#
# Exit code 0 if all checks pass, 1 if any fail, 2 on usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"

ENVS=()
QUICK=0
REGRESSION=0
REGRESSION_SAFE=0
REGRESSION_DEPLOY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; shift ;;
    --regression) REGRESSION=1; shift ;;
    --regression-safe) REGRESSION_SAFE=1; shift ;;
    --regression-deploy) REGRESSION_DEPLOY=1; REGRESSION=1; shift ;;
    prod|dev) ENVS+=("$1"); shift ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ${#ENVS[@]} -eq 0 ]]; then
  ENVS=(prod dev)
fi

# Refuse --regression/--regression-deploy when prod is in scope
if [[ "$REGRESSION" -eq 1 ]]; then
  for _env in "${ENVS[@]}"; do
    if [[ "$_env" == "prod" ]]; then
      echo "ERROR: Destructive regression tests cannot target prod." >&2
      echo "Destructive tests only run against dev VMs." >&2
      echo "Use --regression-safe prod for non-destructive regression tests against prod." >&2
      exit 1
    fi
  done
fi

# --regression-deploy requires exactly "dev" as the environment
if [[ "$REGRESSION_DEPLOY" -eq 1 ]]; then
  if [[ ${#ENVS[@]} -ne 1 || "${ENVS[0]}" != "dev" ]]; then
    echo "ERROR: --regression-deploy requires exactly 'dev' as the environment." >&2
    exit 2
  fi
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 2
fi

# --- Counters ---
PASS=0
FAIL=0
SKIP=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "[PASS] ${label}"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${label}"
    FAIL=$((FAIL + 1))
  fi
}

check_skip() {
  local label="$1"
  local reason="$2"
  echo "[SKIP] ${label} — ${reason}"
  SKIP=$((SKIP + 1))
}

# SSH options used throughout (direct calls and subshells)
export SSH_OPTS="-n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# SSH helper for regression tests (direct calls only — not available in bash -c)
ssh_node() {
  ssh $SSH_OPTS "$@"
}

# --- Read common config ---
DOMAIN=$(yq -r '.domain' "$CONFIG")
NODE_COUNT=$(yq -r '.nodes | length' "$CONFIG")
NAS_IP=$(yq -r '.nas.ip' "$CONFIG")
GATUS_IP=$(yq -r '.vms.gatus.ip' "$CONFIG")
GITLAB_IP=$(yq -r '.vms.gitlab.ip' "$CONFIG")
PBS_IP=$(yq -r '.vms.pbs.ip' "$CONFIG")
HEALTH_PORT=$(yq -r '.replication.health_port' "$CONFIG")
STORAGE_POOL=$(yq -r '.proxmox.storage_pool' "$CONFIG")

# =====================================================================
# Regression Deploy: destroy dev VMs and redeploy before validation
# =====================================================================
if [[ "$REGRESSION_DEPLOY" -eq 1 ]]; then
  echo ""
  echo "=== Regression Deploy: Destroy + Redeploy Dev VMs ==="
  echo ""
  echo "This test destroys selected dev VMs and redeploys them from the"
  echo "current code to verify the deploy path works end-to-end."
  echo ""

  FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
  # dns-pair module manages both dns1 and dns2 together — must destroy both
  DEPLOY_TARGETS="testapp_dev dns1_dev dns2_dev vault_dev"

  # Destroy selected dev VMs
  for vm in $DEPLOY_TARGETS; do
    VMID=$(yq -r ".vms.${vm}.vmid" "$CONFIG")
    VM_IP=$(yq -r ".vms.${vm}.ip" "$CONFIG")
    echo "  Destroying ${vm} (VMID ${VMID})..."
    # Find hosting node
    HOSTING_NODE=$(ssh -n ${SSH_OPTS} "root@${FIRST_NODE_IP}" \
      "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
      | python3 -c "
import sys,json
for v in json.loads(sys.stdin.read()):
    if v.get('vmid') == ${VMID}: print(v['node']); break
" 2>/dev/null || true)
    if [[ -z "$HOSTING_NODE" ]]; then
      echo "    WARNING: VM ${vm} not found in cluster — skipping destroy"
      continue
    fi
    HOSTING_IP=$(yq -r ".nodes[] | select(.name == \"${HOSTING_NODE}\") | .mgmt_ip" "$CONFIG")
    # Remove HA, stop, destroy
    ssh -n ${SSH_OPTS} "root@${HOSTING_IP}" "ha-manager remove vm:${VMID}" 2>/dev/null || true
    ssh -n ${SSH_OPTS} "root@${HOSTING_IP}" "qm stop ${VMID} --skiplock" 2>/dev/null || true
    sleep 3
    ssh -n ${SSH_OPTS} "root@${HOSTING_IP}" "qm destroy ${VMID} --skiplock --purge" 2>/dev/null || true
    echo "    Destroyed ${vm}"
    ssh-keygen -R "$VM_IP" 2>/dev/null || true
  done

  # Remove destroyed VMs from tofu state so tofu recreates them
  echo ""
  echo "  Removing destroyed VMs from tofu state..."
  cd "${REPO_DIR}"
  SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key" "${SCRIPT_DIR}/tofu-wrapper.sh" init -input=false >/dev/null 2>&1 || \
    SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key.production" "${SCRIPT_DIR}/tofu-wrapper.sh" init -input=false >/dev/null 2>&1
  for vm in $DEPLOY_TARGETS; do
    # Map config key to tofu module name
    case "$vm" in
      dns1_dev|dns2_dev) MODULE="module.dns_dev" ;;
      vault_dev)         MODULE="module.vault_dev" ;;
      testapp_dev)       MODULE="module.testapp_dev" ;;
      *)                 MODULE="module.${vm}" ;;
    esac
    "${SCRIPT_DIR}/tofu-wrapper.sh" state rm "${MODULE}" 2>/dev/null || true
    echo "    Removed ${MODULE} from state"
  done

  # Redeploy with tofu apply (targeted)
  echo ""
  echo "  Redeploying destroyed VMs..."
  TARGETS=""
  for vm in $DEPLOY_TARGETS; do
    case "$vm" in
      dns1_dev|dns2_dev) TARGETS="$TARGETS -target=module.dns_dev" ;;
      vault_dev)         TARGETS="$TARGETS -target=module.vault_dev" ;;
      testapp_dev)       TARGETS="$TARGETS -target=module.testapp_dev" ;;
      *)                 TARGETS="$TARGETS -target=module.${vm}" ;;
    esac
  done
  # Deduplicate targets
  TARGETS=$(echo "$TARGETS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
  "${SCRIPT_DIR}/tofu-wrapper.sh" apply $TARGETS -auto-approve -input=false
  echo "  Tofu apply complete"

  # Wait for VMs to boot and initialize
  echo ""
  echo "  Waiting for VMs to initialize..."
  for vm in $DEPLOY_TARGETS; do
    VM_IP=$(yq -r ".vms.${vm}.ip" "$CONFIG")
    echo -n "    ${vm} (${VM_IP}): "
    for attempt in $(seq 1 30); do
      if ssh -n -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
           -o BatchMode=yes "root@${VM_IP}" "true" 2>/dev/null; then
        echo "up (${attempt}0s)"
        break
      fi
      sleep 10
    done
  done

  # Wait for certificates (vault and dns need certs before being fully functional)
  echo "  Waiting for certificates..."
  sleep 30

  # Initialize and configure Vault if it was recreated.
  # Detect the SOPS age key — operator may use either filename.
  if echo "$DEPLOY_TARGETS" | grep -q "vault_dev"; then
    echo "  Initializing vault-dev..."
    if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
      if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
        export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
      elif [[ -f "${REPO_DIR}/operator.age.key.production" ]]; then
        export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key.production"
      fi
    fi
    "${SCRIPT_DIR}/init-vault.sh" dev 2>&1 | tail -1
    "${SCRIPT_DIR}/configure-vault.sh" dev 2>&1 | tail -1
  fi

  # Configure replication for recreated VMs
  echo "  Configuring replication..."
  "${SCRIPT_DIR}/configure-replication.sh" "*" >/dev/null 2>&1 || true

  echo ""
  echo "  Deploy phase complete. Proceeding with validation..."
  echo ""
fi

# =====================================================================
echo "=== Network ==="
# =====================================================================

# Node SSH reachability
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
  NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
  check "${NODE_NAME} reachable via SSH" \
    ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${NODE_IP}" "true"
done

# Environment gateway ping
for ENV in "${ENVS[@]}"; do
  GW=$(yq -r ".environments.${ENV}.gateway" "$CONFIG")
  check "${ENV} gateway (${GW}) pingable" ping -c 1 -W 3 "$GW"
done

# =====================================================================
echo ""
echo "=== Storage ==="
# =====================================================================

check "configure-node-storage.sh --verify" \
  "${SCRIPT_DIR}/configure-node-storage.sh" --verify --all

# ZFS replication health (via repl-health endpoints)
# Replication may still be syncing after a deploy that recreated VMs.
# Retry for up to 2 minutes before declaring stale.
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
  NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
  check "${NODE_NAME} replication not stale" \
    bash -c "
      for attempt in \$(seq 1 12); do
        if curl -sf http://${NODE_IP}:${HEALTH_PORT}/ | jq -e '.replication_stale == false' >/dev/null 2>&1; then
          exit 0
        fi
        [ \$attempt -lt 12 ] && sleep 10
      done
      echo 'Still stale after 2 minutes' >&2
      exit 1
    "
  # Data pool is required; rpool is optional (ext4/LVM boot drives don't have it)
  check "${NODE_NAME} ZFS pools healthy" \
    bash -c "curl -sf http://${NODE_IP}:${HEALTH_PORT}/ | jq -e --arg pool '${STORAGE_POOL}' '.zfs_pools[\$pool] == \"healthy\" and (.zfs_pools.rpool == null or .zfs_pools.rpool == \"healthy\")'"
done

# =====================================================================
echo ""
echo "=== DNS ==="
# =====================================================================

for ENV in "${ENVS[@]}"; do
  DNS_DOMAIN="${ENV}.$(yq -r '.domain' "$CONFIG")"
  DNS1_IP=$(yq -r ".vms.dns1_${ENV}.ip" "$CONFIG")
  DNS2_IP=$(yq -r ".vms.dns2_${ENV}.ip" "$CONFIG")
  VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")

  check "dns1-${ENV} responds to queries" \
    dig +short +time=3 "vault.${DNS_DOMAIN}" "@${DNS1_IP}"
  check "dns2-${ENV} responds to queries" \
    dig +short +time=3 "vault.${DNS_DOMAIN}" "@${DNS2_IP}"
  check "vault.${DNS_DOMAIN} resolves to correct IP via dns1" \
    bash -c "[[ \$(dig +short +time=3 vault.${DNS_DOMAIN} @${DNS1_IP}) == '${VAULT_IP}' ]]"
done

# =====================================================================
echo ""
echo "=== Certificates ==="
# =====================================================================

if [[ "$QUICK" -eq 0 ]]; then
  # Prod TLS services: check cert valid and >7 days remaining
  for ENV in "${ENVS[@]}"; do
    VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")
    check "vault-${ENV} cert valid (>7d remaining)" \
      bash -c "echo | openssl s_client -connect ${VAULT_IP}:8200 2>/dev/null | openssl x509 -noout -checkend 604800 2>/dev/null"
  done

  # GitLab cert (management network, LE cert)
  check "gitlab cert valid (>7d remaining)" \
    bash -c "echo | openssl s_client -connect ${GITLAB_IP}:443 2>/dev/null | openssl x509 -noout -checkend 604800 2>/dev/null"
else
  echo "[SKIP] Certificate expiry checks (--quick mode)"
fi

# =====================================================================
echo ""
echo "=== Vault ==="
# =====================================================================

for ENV in "${ENVS[@]}"; do
  VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")
  check "vault-${ENV} initialized and unsealed" \
    bash -c "curl -sk https://${VAULT_IP}:8200/v1/sys/health | jq -e '.initialized == true and .sealed == false'"
done

# =====================================================================
echo ""
echo "=== PBS ==="
# =====================================================================

check "PBS API responds" \
  bash -c "curl -sk https://${PBS_IP}:8007/ -o /dev/null -w '%{http_code}' | grep -qv '5[0-9][0-9]'"

# Check that backup jobs exist for all VMs with backup: true (infrastructure + applications)
BACKUP_VMS=$(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG")
BACKUP_APPS=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)
if [[ -n "$BACKUP_VMS" || -n "$BACKUP_APPS" ]]; then
  check "Backup jobs configured for VMs with precious state" \
    "${SCRIPT_DIR}/configure-backups.sh" --verify
fi

if [[ "$QUICK" -eq 0 ]]; then
  # Check PBS storage is accessible from first node
  FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
  FIRST_NODE_NAME=$(yq -r '.nodes[0].name' "$CONFIG")
  check "PBS storage (pbs-nas) accessible from ${FIRST_NODE_NAME}" \
    ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${FIRST_NODE_IP}" "pvesm status 2>/dev/null | grep -q 'pbs-nas.*active'"
  # Check most recent backup is <36h old. Skip if no backups exist yet
  # (fresh cluster hasn't had time for its first scheduled backup).
  BACKUP_LATEST=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${FIRST_NODE_IP}" \
    "pvesh get /nodes/${FIRST_NODE_NAME}/storage/pbs-nas/content --output-format json 2>/dev/null" \
    | jq -r '[.[].ctime] | sort | last // 0' 2>/dev/null || echo "0")
  if [[ "$BACKUP_LATEST" == "null" || "$BACKUP_LATEST" == "0" || -z "$BACKUP_LATEST" ]]; then
    echo "[SKIP] PBS backup freshness — no backups exist yet (fresh cluster)"
  else
    check "PBS backup freshness (<36h for VMs with precious state)" \
      bash -c "now=\$(date +%s); (( now - ${BACKUP_LATEST} < 129600 ))"
  fi
else
  echo "[SKIP] PBS backup freshness check (--quick mode)"
fi

# =====================================================================
echo ""
echo "=== CI/CD ==="
# =====================================================================

check "GitLab responds" \
  bash -c "code=\$(curl -sk -o /dev/null -w '%{http_code}' https://${GITLAB_IP}/); [[ \$code -lt 500 ]]"

# Check runner service is active on the runner VM
CICD_IP=$(yq -r '.vms.cicd.ip' "$CONFIG")
check "GitLab runner online" \
  ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${CICD_IP}" "systemctl is-active gitlab-runner.service"

# =====================================================================
echo ""
echo "=== Monitoring ==="
# =====================================================================

check "Gatus (primary) responds" \
  curl -sf "http://${GATUS_IP}:8080/api/v1/endpoints/statuses?page=1"

check "Sentinel Gatus (NAS) responds" \
  curl -sf "http://${NAS_IP}:8080/api/v1/endpoints/statuses"

# Parse Gatus API for all-healthy (retry — Gatus needs time to cycle checks after recreation)
check "All Gatus endpoints healthy" \
  bash -c "
    for attempt in 1 2 3 4 5 6; do
      data=\$(curl -sf 'http://${GATUS_IP}:8080/api/v1/endpoints/statuses?page=1')
      total=\$(echo \"\$data\" | jq 'length')
      healthy=\$(echo \"\$data\" | jq '[.[] | select(.results[-1].success == true)] | length')
      if [[ \$healthy -eq \$total && \$total -gt 0 ]]; then
        echo \"Gatus: \${healthy}/\${total} endpoints healthy\" >&2
        exit 0
      fi
      echo \"Gatus: \${healthy}/\${total} healthy, retrying in 30s... (\${attempt}/6)\" >&2
      sleep 30
    done
    echo \"Gatus: \${healthy}/\${total} endpoints healthy (gave up after 3 min)\" >&2
    exit 1
  "

# =====================================================================
echo ""
echo "=== Applications ==="
# =====================================================================

for ENV in "${ENVS[@]}"; do
  TESTAPP_IP=$(yq -r ".vms.testapp_${ENV}.ip // \"\"" "$CONFIG")
  if [[ -n "$TESTAPP_IP" && "$TESTAPP_IP" != "null" ]]; then
    check "testapp-${ENV} healthy (status=healthy, count>0)" \
      bash -c "curl -sf http://${TESTAPP_IP}:8080/ | jq -e '.status == \"healthy\" and .count > 0'"
  fi

  # Catalog applications (from applications.yaml)
  # Health port/path come from the catalog module's metadata.yaml, not config.yaml.
  APP_NAMES=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.monitor == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)
  for APP in $APP_NAMES; do
    APP_IP=$(yq -r ".applications.${APP}.environments.${ENV}.ip // \"\"" "$APPS_CONFIG")
    HEALTH_FILE="${REPO_DIR}/framework/catalog/${APP}/health.yaml"
    if [[ ! -f "$HEALTH_FILE" ]]; then
      continue
    fi
    HEALTH_PORT_APP=$(yq -r '.port // ""' "$HEALTH_FILE")
    HEALTH_PATH_APP=$(yq -r '.path // ""' "$HEALTH_FILE")
    if [[ -n "$APP_IP" && "$APP_IP" != "null" && -n "$HEALTH_PORT_APP" && "$HEALTH_PORT_APP" != "null" ]]; then
      check "${APP}-${ENV} healthy (${HEALTH_PATH_APP})" \
        bash -c "curl -sfk https://${APP_IP}:${HEALTH_PORT_APP}${HEALTH_PATH_APP} >/dev/null"
    fi
  done
done

# =====================================================================
echo ""
echo "=== Dual-NIC (mgmt_nic) Connectivity ==="
# =====================================================================
# For VMs with mgmt_nic in config.yaml, verify all connectivity paths.

for ENV in "${ENVS[@]}"; do
  APP_NAMES=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)
  for APP in $APP_NAMES; do
    MGMT_IP=$(yq -r ".applications.${APP}.environments.${ENV}.mgmt_nic.ip // \"\"" "$APPS_CONFIG")
    [[ -z "$MGMT_IP" || "$MGMT_IP" == "null" ]] && continue

    VLAN_IP=$(yq -r ".applications.${APP}.environments.${ENV}.ip" "$APPS_CONFIG")
    VM_NODE=$(yq -r ".applications.${APP}.environments.${ENV}.node" "$APPS_CONFIG")
    VM_LABEL="${APP}-${ENV}"

    # Find a same-VLAN peer on a different node
    PEER_DIFF_NODE=""
    PEER_SAME_NODE=""
    for PEER_KEY in $(yq -r ".vms | to_entries[] | select(.key | test(\"_${ENV}$\")) | .key" "$CONFIG" 2>/dev/null); do
      PEER_IP=$(yq -r ".vms.${PEER_KEY}.ip" "$CONFIG")
      PEER_NODE=$(yq -r ".vms.${PEER_KEY}.node" "$CONFIG")
      [[ "$PEER_IP" == "$VLAN_IP" ]] && continue
      if [[ "$PEER_NODE" == "$VM_NODE" && -z "$PEER_SAME_NODE" ]]; then
        PEER_SAME_NODE="$PEER_IP"
      elif [[ "$PEER_NODE" != "$VM_NODE" && -z "$PEER_DIFF_NODE" ]]; then
        PEER_DIFF_NODE="$PEER_IP"
      fi
      [[ -n "$PEER_SAME_NODE" && -n "$PEER_DIFF_NODE" ]] && break
    done

    # Test 1: SSH via management IP
    check "${VM_LABEL} mgmt NIC reachable (${MGMT_IP})" \
      bash -c "ssh ${SSH_OPTS} root@${MGMT_IP} true"

    # Test 2: SSH via VLAN IP
    check "${VM_LABEL} VLAN NIC reachable (${VLAN_IP})" \
      bash -c "ssh ${SSH_OPTS} root@${VLAN_IP} true"

    # Test 3: Same VLAN, different node → VM
    if [[ -n "$PEER_DIFF_NODE" ]]; then
      check "${VM_LABEL} reachable from same-VLAN different-node peer" \
        bash -c "ssh ${SSH_OPTS} root@${PEER_DIFF_NODE} 'ping -c1 -W2 ${VLAN_IP}' >/dev/null 2>&1"
    fi

    # Test 4: Same VLAN, same node → VM
    if [[ -n "$PEER_SAME_NODE" ]]; then
      check "${VM_LABEL} reachable from same-VLAN same-node peer" \
        bash -c "ssh ${SSH_OPTS} root@${PEER_SAME_NODE} 'ping -c1 -W2 ${VLAN_IP}' >/dev/null 2>&1"
    fi

    # Test 5: VM → same-VLAN peer (different node)
    if [[ -n "$PEER_DIFF_NODE" ]]; then
      check "${VM_LABEL} can reach same-VLAN different-node peer" \
        bash -c "ssh ${SSH_OPTS} root@${VLAN_IP} 'ping -c1 -W2 ${PEER_DIFF_NODE}' >/dev/null 2>&1"
    fi

    # Test 6: DNS resolution from the VM
    check "${VM_LABEL} DNS resolution works" \
      bash -c "ssh ${SSH_OPTS} root@${MGMT_IP} 'getent hosts ${APP}.${ENV}.${DOMAIN}' >/dev/null 2>&1"

    # Test 7: Correct interface separation (VLAN IP on primary, mgmt IP on secondary)
    check "${VM_LABEL} interfaces correctly separated" \
      bash -c "
        IFACES=\$(ssh ${SSH_OPTS} root@${MGMT_IP} 'ip -br addr show | grep -v lo')
        echo \"\$IFACES\" | grep -q '${VLAN_IP}' && echo \"\$IFACES\" | grep -q '${MGMT_IP}'
      "
  done
done

# =====================================================================
# Regression Tests
# =====================================================================

if [[ "$REGRESSION" -eq 1 || "$REGRESSION_SAFE" -eq 1 ]]; then

  DESTRUCTIVE=0
  if [[ "$REGRESSION" -eq 1 && "$REGRESSION_SAFE" -eq 0 ]]; then
    DESTRUCTIVE=1
  fi

  # Helper: determine if destructive tests should run (dev only)
  can_run_destructive() {
    [[ "$DESTRUCTIVE" -eq 1 ]]
  }

  # =====================================================================
  echo ""
  echo "=== Regression: Environment Ignorance ==="
  # =====================================================================

  # Cross-env tests always read both environments (they verify cross-env properties)
  DNS1_PROD_IP=$(yq -r '.vms.dns1_prod.ip' "$CONFIG")
  DNS1_DEV_IP=$(yq -r '.vms.dns1_dev.ip' "$CONFIG")
  VAULT_PROD_IP=$(yq -r '.vms.vault_prod.ip' "$CONFIG")
  VAULT_DEV_IP=$(yq -r '.vms.vault_dev.ip' "$CONFIG")
  BASE_DOMAIN=$(yq -r '.domain' "$CONFIG")
  PROD_DNS_DOMAIN="prod.${BASE_DOMAIN}"
  DEV_DNS_DOMAIN="dev.${BASE_DOMAIN}"

  # R1.1 — Same image hash in dev and prod (per role) [cross-env]
  # After a full pipeline build, both environments deploy the same image per role.
  # Skip when running single-env regression — after a dev-only or prod-only deploy,
  # image hashes will differ until the other env is also deployed.
  if [[ ${#ENVS[@]} -ge 2 ]]; then
    for role_info in "dns:dns1" "vault:vault"; do
      role="${role_info%%:*}"
      vm="${role_info##*:}"
      DEV_IP=$(yq -r ".vms.${vm}_dev.ip" "$CONFIG")
      PROD_IP=$(yq -r ".vms.${vm}_prod.ip" "$CONFIG")
      check "R1.1: Same image hash in dev and prod (${role})" \
        bash -c "
          DEV_HASH=\$(ssh ${SSH_OPTS} root@${DEV_IP} 'cat /etc/image-hash 2>/dev/null || echo MISSING')
          PROD_HASH=\$(ssh ${SSH_OPTS} root@${PROD_IP} 'cat /etc/image-hash 2>/dev/null || echo MISSING')
          [[ \"\$DEV_HASH\" == \"\$PROD_HASH\" && \"\$DEV_HASH\" != 'MISSING' ]]
        "
    done
  else
    for role_info in "dns:dns1" "vault:vault"; do
      role="${role_info%%:*}"
      check_skip "R1.1: Same image hash in dev and prod (${role})" \
        "single-env mode — cross-env comparison requires both envs"
    done
  fi

  # R1.2 — Unqualified hostname resolves differently per environment [cross-env]
  check "R1.2: Unqualified 'vault' resolves differently per environment" \
    bash -c "
      PROD_RESULT=\$(dig +short +time=3 vault.${PROD_DNS_DOMAIN} @${DNS1_PROD_IP})
      DEV_RESULT=\$(dig +short +time=3 vault.${DEV_DNS_DOMAIN} @${DNS1_DEV_IP})
      [[ -n \"\$PROD_RESULT\" && -n \"\$DEV_RESULT\" && \"\$PROD_RESULT\" != \"\$DEV_RESULT\" ]]
    "

  check "R1.2a: vault resolves to correct prod IP" \
    bash -c "[[ \$(dig +short +time=3 vault.${PROD_DNS_DOMAIN} @${DNS1_PROD_IP}) == '${VAULT_PROD_IP}' ]]"

  check "R1.2b: vault resolves to correct dev IP" \
    bash -c "[[ \$(dig +short +time=3 vault.${DEV_DNS_DOMAIN} @${DNS1_DEV_IP}) == '${VAULT_DEV_IP}' ]]"

  # R1.2c — In-VM unqualified resolution (tests full DHCP → search domain → DNS chain) [cross-env]
  # This is the real environment ignorance test — it catches gateway DNS misconfigurations
  # that zone-data-only tests (R1.2/R1.2a/R1.2b) cannot detect.
  check "R1.2c: In-VM 'vault' resolves to prod IP from dns2-prod" \
    bash -c "
      RESOLVED=\$(ssh ${SSH_OPTS} root@$(yq -r '.vms.dns2_prod.ip' "$CONFIG") 'getent hosts vault 2>/dev/null' | awk '{print \$1}')
      [[ \"\$RESOLVED\" == '${VAULT_PROD_IP}' ]]
    "

  check "R1.2c: In-VM 'vault' resolves to dev IP from dns2-dev" \
    bash -c "
      RESOLVED=\$(ssh ${SSH_OPTS} root@$(yq -r '.vms.dns2_dev.ip' "$CONFIG") 'getent hosts vault 2>/dev/null' | awk '{print \$1}')
      [[ \"\$RESOLVED\" == '${VAULT_DEV_IP}' ]]
    "

  # R1.2d — VM DNS server verification (VMs use per-env DNS servers, not the gateway) [cross-env]
  check "R1.2d: dns2-prod uses prod DNS servers (not gateway)" \
    bash -c "
      DNS_INFO=\$(ssh ${SSH_OPTS} root@$(yq -r '.vms.dns2_prod.ip' "$CONFIG") 'networkctl status 2>/dev/null' | grep 'DNS:')
      echo \"\$DNS_INFO\" | grep -q '${DNS1_PROD_IP}'
    "

  check "R1.2d: dns2-dev uses dev DNS servers (not gateway)" \
    bash -c "
      DNS_INFO=\$(ssh ${SSH_OPTS} root@$(yq -r '.vms.dns2_dev.ip' "$CONFIG") 'networkctl status 2>/dev/null' | grep 'DNS:')
      echo \"\$DNS_INFO\" | grep -q '${DNS1_DEV_IP}'
    "

  # R1.3 — certbot config identical across environments [cross-env]
  check "R1.3: certbot config structure identical across envs (dns1)" \
    bash -c "
      PROD_KEYS=\$(ssh ${SSH_OPTS} root@${DNS1_PROD_IP} 'cat /etc/letsencrypt/renewal/*.conf 2>/dev/null' | grep -E '^\[|^[a-z]' | sed 's/=.*//' | sort)
      DEV_KEYS=\$(ssh ${SSH_OPTS} root@${DNS1_DEV_IP} 'cat /etc/letsencrypt/renewal/*.conf 2>/dev/null' | grep -E '^\[|^[a-z]' | sed 's/=.*//' | sort)
      [[ \"\$PROD_KEYS\" == \"\$DEV_KEYS\" ]]
    "

  # =====================================================================
  echo ""
  echo "=== Regression: HA Readiness ==="
  # =====================================================================

  # R2.1 — CIDATA snippets on all nodes (equal count, >0) [cluster]
  check "R2.1: CIDATA snippets replicated to all nodes (equal count)" \
    bash -c "
      COUNTS=''
      for i in \$(seq 0 $((NODE_COUNT - 1))); do
        NODE_IP=\$(yq -r \".nodes[\${i}].mgmt_ip\" '$CONFIG')
        COUNT=\$(ssh ${SSH_OPTS} root@\${NODE_IP} 'ls /var/lib/vz/snippets/*.yaml 2>/dev/null | wc -l')
        COUNTS=\"\${COUNTS} \${COUNT}\"
      done
      UNIQUE=\$(echo \$COUNTS | tr ' ' '\n' | sort -u | wc -l)
      FIRST=\$(echo \$COUNTS | awk '{print \$1}')
      [[ \$UNIQUE -eq 1 && \$FIRST -gt 0 ]]
    "

  # R2.2 — Snippet content matches across nodes [cluster]
  # Spot-check: dns1-prod user-data must have identical hash on all nodes
  check "R2.2: dns1-prod user-data identical across all nodes" \
    bash -c "
      HASHES=''
      for i in \$(seq 0 $((NODE_COUNT - 1))); do
        NODE_IP=\$(yq -r \".nodes[\${i}].mgmt_ip\" '$CONFIG')
        HASH=\$(ssh ${SSH_OPTS} root@\${NODE_IP} 'md5sum /var/lib/vz/snippets/dns1-prod-user-data.yaml 2>/dev/null' | awk '{print \$1}')
        HASHES=\"\${HASHES} \${HASH}\"
      done
      UNIQUE=\$(echo \$HASHES | tr ' ' '\n' | sort -u | wc -l)
      [[ \$UNIQUE -eq 1 ]]
    "

  # R2.3 — Anti-affinity: dns1 and dns2 on different nodes [env]
  for ENV in "${ENVS[@]}"; do
    DNS1_NODE_INTENDED=$(yq -r ".vms.dns1_${ENV}.node" "$CONFIG")
    DNS2_NODE_INTENDED=$(yq -r ".vms.dns2_${ENV}.node" "$CONFIG")
    check "R2.3: Anti-affinity — dns1 and dns2 on different nodes (${ENV})" \
      bash -c "[[ '${DNS1_NODE_INTENDED}' != '${DNS2_NODE_INTENDED}' ]]"
  done

  # R2.4 — VM placement matches config.yaml [cluster]
  FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
  check "R2.4: VM placement matches config.yaml" \
    bash -c "
      RESOURCES=\$(ssh ${SSH_OPTS} root@${FIRST_NODE_IP} 'pvesh get /cluster/resources --type vm --output-format json 2>/dev/null')
      FAIL=0
      # Infrastructure VMs
      for vm in \$(yq -r '.vms | keys | .[]' '$CONFIG'); do
        INTENDED=\$(yq -r \".vms.\${vm}.node\" '$CONFIG')
        VM_NAME=\$(echo \"\$vm\" | tr '_' '-')
        ACTUAL=\$(echo \"\$RESOURCES\" | jq -r \".[] | select(.name==\\\"\${VM_NAME}\\\") | .node\" 2>/dev/null)
        if [[ -n \"\$ACTUAL\" && \"\$INTENDED\" != \"\$ACTUAL\" ]]; then
          echo \"DRIFT: \$vm intended=\$INTENDED actual=\$ACTUAL\" >&2
          FAIL=1
        fi
      done
      # Catalog applications
      for app in \$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' '$APPS_CONFIG' 2>/dev/null); do
        for env in \$(yq -r \".applications.\${app}.environments | keys | .[]\" '$APPS_CONFIG' 2>/dev/null); do
          # Node can be per-environment or shared at the app level
          INTENDED=\$(yq -r \".applications.\${app}.environments.\${env}.node // .applications.\${app}.node\" '$APPS_CONFIG')
          VM_NAME=\"\${app}-\${env}\"
          ACTUAL=\$(echo \"\$RESOURCES\" | jq -r \".[] | select(.name==\\\"\${VM_NAME}\\\") | .node\" 2>/dev/null)
          if [[ -n \"\$ACTUAL\" && \"\$INTENDED\" != \"null\" && \"\$INTENDED\" != \"\$ACTUAL\" ]]; then
            echo \"DRIFT: \${app}_\${env} intended=\$INTENDED actual=\$ACTUAL\" >&2
            FAIL=1
          fi
        done
      done
      [[ \$FAIL -eq 0 ]]
    "

  # R2.5 — Cross-node migration [destructive — dev only]
  if can_run_destructive; then
    check_skip "R2.5: Cross-node migration works (dns1-dev)" \
      "destructive test — run manually with care"
  else
    check_skip "R2.5: Cross-node migration works (dns1-dev)" \
      "destructive test, requires --regression dev"
  fi

  # R2.6 — Replication network healthy [cluster]
  # Retry for up to 2 minutes (replication may still be syncing after deploy)
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    check "R2.6: ${NODE_NAME} healthy and replication not stale" \
      bash -c "
        for attempt in \$(seq 1 12); do
          HEALTH=\$(curl -sf http://${NODE_IP}:${HEALTH_PORT}/ 2>/dev/null || true)
          HEALTHY=\$(echo \"\$HEALTH\" | jq -r '.healthy' 2>/dev/null)
          STALE=\$(echo \"\$HEALTH\" | jq -r '.replication_stale' 2>/dev/null)
          if [[ \"\$HEALTHY\" == \"true\" && \"\$STALE\" == \"false\" ]]; then
            exit 0
          fi
          [ \$attempt -lt 12 ] && sleep 10
        done
        echo 'Still unhealthy/stale after 2 minutes' >&2
        exit 1
      "
  done

  # =====================================================================
  echo ""
  echo "=== Regression: Secrets Architecture ==="
  # =====================================================================

  # R3.1 — No post-deploy secrets in TF_VARs [cluster]
  TOFU_WRAPPER="${SCRIPT_DIR}/tofu-wrapper.sh"
  check "R3.1: No post-deploy secrets in TF_VARs" \
    bash -c "
      # Should NOT find unseal, runner_token, or registration in TF_VAR exports
      ! grep -E 'TF_VAR.*(unseal|runner.*token|registration)' '${TOFU_WRAPPER}' | grep -v '^#'
    "

  # R3.2 — Vault unseal key on vdb, not in CIDATA [env]
  for ENV in "${ENVS[@]}"; do
    VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")
    check "R3.2: vault-${ENV} unseal key exists on vdb" \
      ssh_node "root@${VAULT_IP}" "test -f /var/lib/vault/unseal-key"
  done

  # R3.2a [cluster]
  check "R3.2a: No unseal key reference in CIDATA snippets" \
    bash -c "
      FIRST_NODE_IP=\$(yq -r '.nodes[0].mgmt_ip' '$CONFIG')
      ! ssh ${SSH_OPTS} root@\${FIRST_NODE_IP} 'grep -l unseal /var/lib/vz/snippets/vault-*-user-data.yaml 2>/dev/null' | grep -q .
    "

  # R3.3 — SOPS post-deploy section not consumed by TF_VAR [cluster]
  check "R3.3: tofu-wrapper.sh only exports pre-deploy secrets" \
    bash -c "
      # List all TF_VAR exports (non-comment lines)
      EXPORTS=\$(grep 'export TF_VAR_' '${TOFU_WRAPPER}' | grep -v '^#' | grep -v '^ *#')
      # Should only see: ssh_pubkey, pdns_api_key, sops_age_key, ssh_privkey, app pre-deploy secrets
      # Should NOT see: unseal_key, runner_token, root_password
      ! echo \"\$EXPORTS\" | grep -iE 'unseal|runner_token|root_password'
    "

  # =====================================================================
  echo ""
  echo "=== Regression: Storage Integrity ==="
  # =====================================================================

  # R4.1 — All VMs on vmstore, not rpool [cluster]
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    check "R4.1: ${NODE_NAME} — no VM zvols on rpool" \
      bash -c "
        RPOOL_VMS=\$(ssh ${SSH_OPTS} root@${NODE_IP} 'zfs list -r rpool/data 2>/dev/null | grep vm- | wc -l')
        [[ \$RPOOL_VMS -eq 0 ]]
      "
  done

  # R4.2 — vmstore cachefile set for auto-import [cluster]
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    check "R4.2: ${NODE_NAME} — ${STORAGE_POOL} cachefile set" \
      bash -c "
        CACHEFILE=\$(ssh ${SSH_OPTS} root@${NODE_IP} 'zpool get -H -o value cachefile ${STORAGE_POOL}')
        [[ \"\$CACHEFILE\" == '/etc/zfs/zpool.cache' || \"\$CACHEFILE\" == '-' ]]
      "
  done

  # R4.3 — No orphan zvols [cluster]
  r4_3_check_orphans() {
    local node_ip="$1"
    local pool="$2"
    local orphans
    orphans=$(ssh $SSH_OPTS "root@${node_ip}" \
      "for zvol in \$(zfs list -H -o name -r ${pool}/data 2>/dev/null | grep vm-); do vmid=\$(echo \$zvol | grep -oP 'vm-\K[0-9]+'); if ! qm status \$vmid &>/dev/null 2>&1; then if ! pvesr list 2>/dev/null | grep -q \"\$vmid\"; then echo ORPHAN:\$zvol; fi; fi; done" \
      2>/dev/null) || true
    [[ -z "$orphans" ]]
  }
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    check "R4.3: ${NODE_NAME} — no orphan zvols" \
      r4_3_check_orphans "${NODE_IP}" "${STORAGE_POOL}"
  done

  # =====================================================================
  echo ""
  echo "=== Regression: DNS Integrity ==="
  # =====================================================================

  # R5.1 — Both DNS servers return identical zone data [env]
  for ENV in "${ENVS[@]}"; do
    DNS1_IP=$(yq -r ".vms.dns1_${ENV}.ip" "$CONFIG")
    DNS2_IP=$(yq -r ".vms.dns2_${ENV}.ip" "$CONFIG")
    DNS_DOMAIN="${ENV}.$(yq -r '.domain' "$CONFIG")"
    VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")

    check "R5.1: DNS servers return identical data (${ENV})" \
      bash -c "
        RESULT1=\$(dig +short +time=3 vault.${DNS_DOMAIN} @${DNS1_IP})
        RESULT2=\$(dig +short +time=3 vault.${DNS_DOMAIN} @${DNS2_IP})
        [[ -n \"\$RESULT1\" && \"\$RESULT1\" == \"\$RESULT2\" ]]
      "
  done

  # R5.2 — DNS failover [destructive — dev only]
  if can_run_destructive; then
    check_skip "R5.2: DNS failover works (dns1-dev)" \
      "destructive test — run manually with care"
  else
    check_skip "R5.2: DNS failover works (dns1-dev)" \
      "destructive test, requires --regression dev"
  fi

  # =====================================================================
  echo ""
  echo "=== Regression: Backup Integrity ==="
  # =====================================================================

  # R6.1 — Backup jobs exist for precious-state VMs [cluster]
  BACKUP_VMS_REG=$(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG")
  BACKUP_APPS_REG=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)
  if [[ -n "$BACKUP_VMS_REG" || -n "$BACKUP_APPS_REG" ]]; then
    check "R6.1: Backup jobs exist for precious-state VMs" \
      "${SCRIPT_DIR}/configure-backups.sh" --verify
  else
    check_skip "R6.1: Backup jobs exist for precious-state VMs" \
      "no VMs with backup: true in config.yaml"
  fi

  # R6.2 — PBS backup/restore cycle [destructive — dev only]
  if can_run_destructive; then
    check_skip "R6.2: PBS backup/restore cycle (testapp-dev)" \
      "destructive test — run manually with care"
  else
    check_skip "R6.2: PBS backup/restore cycle (testapp-dev)" \
      "destructive test, requires --regression dev"
  fi

  # =====================================================================
  echo ""
  echo "=== Regression: Tofu State Consistency ==="
  # =====================================================================

  # R7.1 — tofu plan shows only known drift [cluster]
  # Requires SOPS age key for tofu-wrapper.sh. Available on workstation and
  # CI/CD runner (both have /run/secrets/sops/age-key or operator.age.key).
  #
  # When running --regression-safe with a single env, uses -target flags to
  # check only the modules the pipeline deployed (Tier 1 data-plane VMs for
  # that env). This avoids false positives from Tier 2 control-plane VMs
  # whose images were built but not deployed by the pipeline.
  r7_1_tofu_drift() {
    local wrapper="${SCRIPT_DIR}/tofu-wrapper.sh"
    if [[ ! -f "${REPO_DIR}/site/tofu/image-versions.auto.tfvars" ]]; then
      echo "image-versions.auto.tfvars not found — skipping" >&2
      return 2  # signal skip
    fi
    if [[ ! -f "$wrapper" ]]; then
      echo "tofu-wrapper.sh not found" >&2
      return 2
    fi
    # Check for SOPS age key availability
    if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]] \
       && [[ ! -f "${REPO_DIR}/operator.age.key" ]] \
       && [[ ! -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
      echo "No SOPS age key available — skipping" >&2
      return 2
    fi

    # Build -target flags matching the pipeline deploy scope
    local targets=()
    if [[ "$REGRESSION_SAFE" -eq 1 && ${#ENVS[@]} -eq 1 ]]; then
      local env="${ENVS[0]}"
      if [[ "$env" == "dev" ]]; then
        targets=(-target=module.dns_dev -target=module.vault_dev -target=module.acme_dev -target=module.testapp_dev -target=module.influxdb_dev -target=module.grafana_dev)
      elif [[ "$env" == "prod" ]]; then
        targets=(-target=module.dns_prod -target=module.vault_prod -target=module.gatus -target=module.testapp_prod -target=module.influxdb_prod -target=module.grafana_prod)
      fi
    fi

    # Ensure tofu is initialized (test stage may start with clean .terraform/)
    # tofu-wrapper.sh does cd to framework/tofu/root/ — that's where .terraform/ lives
    if [[ ! -d "${REPO_DIR}/framework/tofu/root/.terraform" ]]; then
      "$wrapper" init -input=false >/dev/null 2>&1 || {
        echo "  tofu init failed — skipping" >&2
        return 2
      }
    fi

    local plan_output exitcode
    exitcode=0
    plan_output=$("$wrapper" plan -detailed-exitcode -no-color ${targets[@]+"${targets[@]}"} 2>&1) || exitcode=$?

    if [[ "$exitcode" -eq 0 ]]; then
      # No changes — ideal state
      echo "  tofu plan: no changes" >&2
      return 0
    elif [[ "$exitcode" -eq 2 ]]; then
      # Changes detected — check if they match known drift
      local adds changes destroys
      adds=$(echo "$plan_output" | sed -n 's/.*\([0-9][0-9]*\) to add.*/\1/p' | tail -1)
      changes=$(echo "$plan_output" | sed -n 's/.*\([0-9][0-9]*\) to change.*/\1/p' | tail -1)
      destroys=$(echo "$plan_output" | sed -n 's/.*\([0-9][0-9]*\) to destroy.*/\1/p' | tail -1)

      # Known drift thresholds — set to 0 when all VMs have current images
      local known_adds=0
      local known_changes=0
      local known_destroys=0

      if [[ "${adds:-0}" -le "$known_adds" ]] \
         && [[ "${changes:-0}" -le "$known_changes" ]] \
         && [[ "${destroys:-0}" -le "$known_destroys" ]]; then
        echo "  Known drift only: ${adds:-0} adds, ${changes:-0} changes, ${destroys:-0} destroys" >&2
        return 0
      else
        echo "  UNEXPECTED drift: ${adds:-0} adds, ${changes:-0} changes, ${destroys:-0} destroys" >&2
        return 1
      fi
    else
      echo "  tofu plan failed with exit code ${exitcode}" >&2
      echo "$plan_output" | tail -20 >&2
      return 1
    fi
  }

  # Capture function output and exit code. set +e prevents set -e from killing
  # the subshell (and the outer script) when the function returns non-zero.
  set +e
  R7_RESULT=$(r7_1_tofu_drift 2>&1; echo "EXIT:$?")
  set -e
  R7_EXIT=$(echo "$R7_RESULT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p' | tail -1)
  R7_MSG=$(echo "$R7_RESULT" | grep -v '^EXIT:')
  if [[ "$R7_EXIT" -eq 2 ]]; then
    check_skip "R7.1: tofu plan shows only known drift" \
      "${R7_MSG}"
  elif [[ "$R7_EXIT" -eq 0 ]]; then
    echo "[PASS] R7.1: tofu plan shows only known drift"
    [[ -n "$R7_MSG" ]] && echo "$R7_MSG"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] R7.1: tofu plan shows only known drift"
    [[ -n "$R7_MSG" ]] && echo "$R7_MSG"
    FAIL=$((FAIL + 1))
  fi

  # R7.2 — Control-plane VMs have no pending changes [cluster]
  #
  # The pipeline cannot deploy control-plane VMs (gitlab has prevent_destroy,
  # cicd is the runner itself, pbs is workstation-managed). If any of them
  # have image or CIDATA drift, the operator must deploy from the workstation.
  #
  # This check detects BOTH image drift AND CIDATA drift (unlike the pre-plan
  # warning in safe-apply.sh which only catches image drift via nix-eval).
  #
  # IMPORTANT: if you add a control-plane module here, also update
  # CONTROL_PLANE_MODULES in framework/scripts/safe-apply.sh.
  CONTROL_PLANE_MODULES="module.gitlab module.cicd module.pbs"

  r7_2_control_plane_drift() {
    local wrapper="${SCRIPT_DIR}/tofu-wrapper.sh"
    local tfvars="${REPO_DIR}/site/tofu/image-versions.auto.tfvars"
    local stderr_file="/tmp/r7_2_plan_stderr.txt"

    # Check for image-versions.auto.tfvars (needed for accurate image comparison)
    if [[ ! -f "$tfvars" ]] || grep -q "Placeholder" "$tfvars" 2>/dev/null; then
      if [[ "${CI:-}" == "true" ]]; then
        # R7.2 only runs in --regression-safe mode, which is called from test:dev/test:prod
        # — always after build:images. If tfvars is missing here, either the build artifact
        # expired (pipeline took >1h) or something is genuinely broken. FAIL, not SKIP.
        echo "  image-versions.auto.tfvars not available in test stage." >&2
        echo "  The build:images artifact may have expired (>1h pipeline)." >&2
        echo "  Retry the pipeline, or check build:images job output." >&2
        return 1  # FAIL — should never happen in normal operation
      else
        echo "  image-versions.auto.tfvars not found or contains placeholders." >&2
        echo "  Run framework/scripts/build-all-images.sh before validating." >&2
        return 1  # FAIL on workstation
      fi
    fi

    if [[ ! -f "$wrapper" ]]; then
      echo "  tofu-wrapper.sh not found" >&2
      return 2
    fi

    # Check for SOPS age key availability (same check as R7.1)
    if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]] \
       && [[ ! -f "${REPO_DIR}/operator.age.key" ]] \
       && [[ ! -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
      echo "  No SOPS age key available — skipping" >&2
      return 2
    fi

    # Ensure tofu is initialized (reuse .terraform/ if R7.1 already initialized)
    if [[ ! -d "${REPO_DIR}/framework/tofu/root/.terraform" ]]; then
      "$wrapper" init -input=false >/dev/null 2>&1 || {
        echo "  tofu init failed — cannot run R7.2" >&2
        return 2
      }
    fi

    # Build -target flags from the control-plane module list
    local targets=()
    for mod in $CONTROL_PLANE_MODULES; do
      targets+=("-target=$mod")
    done

    # Run tofu plan against control-plane modules only
    local plan_output plan_exit
    rm -f "$stderr_file"
    # Use || to capture exit code without set +e/set -e, which would
    # re-enable set -e in the subshell and kill it on function return.
    local plan_exit=0
    plan_output=$("$wrapper" plan \
      -detailed-exitcode -no-color \
      "${targets[@]}" \
      2>"$stderr_file") || plan_exit=$?

    if [[ "$plan_exit" -eq 0 ]]; then
      echo "  Control-plane: no pending changes" >&2
      rm -f "$stderr_file"
      return 0  # PASS

    elif [[ "$plan_exit" -eq 2 ]]; then
      # Deployable changes detected (exit 2 = prevent_destroy did NOT fire).
      # This catches: cicd image changes (no prevent_destroy), PBS config changes.
      local affected
      affected=$(echo "$plan_output" | grep -oE 'module\.(gitlab|cicd|pbs)' | sort -u)
      echo "  Control-plane drift detected:" >&2
      echo "$plan_output" | grep -E '^\s+#.*will be|^\s+#.*must be' | head -10 >&2
      echo "" >&2
      echo "  Remediation:" >&2
      if echo "$affected" | grep -q 'module\.gitlab'; then
        echo "    gitlab changed:" >&2
        echo "      1. framework/scripts/backup-now.sh   (verify: exits 0)" >&2
        echo "      2. framework/scripts/rebuild-cluster.sh --scope control-plane" >&2
        echo "         (verify: exits 0, validate.sh passes)" >&2
      fi
      if echo "$affected" | grep -q 'module\.cicd'; then
        echo "    cicd changed:" >&2
        echo "      1. framework/scripts/backup-now.sh   (verify: exits 0)" >&2
        echo "      2. framework/scripts/rebuild-cluster.sh --scope vm=cicd" >&2
        echo "         (verify: exits 0)" >&2
        echo "      3. framework/scripts/register-runner.sh" >&2
        echo "         (verify: runner shows online in GitLab)" >&2
      fi
      if echo "$affected" | grep -q 'module\.pbs'; then
        echo "    pbs config changed (in-place, no VM recreation):" >&2
        echo "      framework/scripts/tofu-wrapper.sh apply -target=module.pbs -auto-approve" >&2
      fi
      if [[ -z "$affected" ]]; then
        echo "    Could not identify specific modules. General remediation:" >&2
        echo "      1. framework/scripts/backup-now.sh   (verify: exits 0)" >&2
        echo "      2. framework/scripts/rebuild-cluster.sh --scope control-plane" >&2
        echo "         (verify: exits 0, validate.sh passes)" >&2
      fi
      rm -f "$stderr_file"
      return 1  # FAIL

    elif [[ "$plan_exit" -eq 1 ]]; then
      # Check stderr for prevent_destroy signal
      if grep -q "Instance cannot be destroyed" "$stderr_file" 2>/dev/null; then
        # prevent_destroy fired: image or CIDATA changed on a protected VM.
        # This is the most critical drift case — the pipeline skipped these VMs.
        local affected
        affected=$(cat "$stderr_file" | grep -oE 'module\.(gitlab|pbs)' | sort -u || true)
        echo "  Control-plane drift BLOCKED by prevent_destroy:" >&2
        echo "  Image or CIDATA changed on: ${affected:-unknown}" >&2
        grep "Instance cannot be destroyed" "$stderr_file" >&2
        echo "" >&2
        echo "  Remediation:" >&2
        echo "    1. framework/scripts/backup-now.sh   (verify: exits 0)" >&2
        echo "    2. framework/scripts/rebuild-cluster.sh --scope control-plane" >&2
        echo "       (verify: exits 0, validate.sh passes)" >&2
        echo "    3. If cicd was also rebuilt: framework/scripts/register-runner.sh" >&2
        echo "       (verify: runner shows online in GitLab)" >&2
        # Show any additional errors beyond prevent_destroy
        local other_errors
        other_errors=$(grep -v "Instance cannot be destroyed" "$stderr_file" \
          | grep -iE "error|failed" || true)
        if [[ -n "$other_errors" ]]; then
          echo "" >&2
          echo "  Additional errors in plan output:" >&2
          echo "$other_errors" | head -5 >&2
        fi
        rm -f "$stderr_file"
        return 1  # FAIL
      else
        # Genuine infrastructure error (backend issue, provider error, etc.)
        # Cannot determine whether control-plane drift exists. The safe answer
        # is FAIL — an unknowable state must not silently pass.
        echo "  tofu plan failed (exit 1) — infrastructure error." >&2
        echo "  Cannot determine control-plane state. Investigate before proceeding." >&2
        tail -10 "$stderr_file" >&2 2>/dev/null || true
        rm -f "$stderr_file"
        return 1  # FAIL — cannot determine state, assume unsafe
      fi
    else
      echo "  tofu plan exited with unexpected code: ${plan_exit}" >&2
      rm -f "$stderr_file"
      return 2  # SKIP
    fi
  }

  # Capture function output and exit code. set +e prevents set -e from killing
  # the subshell (and the outer script) when the function returns non-zero.
  set +e
  R7_2_RESULT=$(r7_2_control_plane_drift 2>&1; echo "EXIT:$?")
  set -e
  R7_2_EXIT=$(echo "$R7_2_RESULT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p' | tail -1)
  R7_2_MSG=$(echo "$R7_2_RESULT" | grep -v '^EXIT:')
  if [[ "$R7_2_EXIT" -eq 2 ]]; then
    check_skip "R7.2: control-plane VMs have no pending changes" \
      "${R7_2_MSG}"
  elif [[ "$R7_2_EXIT" -eq 0 ]]; then
    echo "[PASS] R7.2: control-plane VMs have no pending changes"
    [[ -n "$R7_2_MSG" ]] && echo "$R7_2_MSG"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] R7.2: control-plane VMs have no pending changes"
    [[ -n "$R7_2_MSG" ]] && echo "$R7_2_MSG"
    FAIL=$((FAIL + 1))
  fi

fi  # end regression

# =====================================================================
echo ""
RESULT_LINE="Results: ${PASS} passed, ${FAIL} failed"
if [[ "$SKIP" -gt 0 ]]; then
  RESULT_LINE="${RESULT_LINE} (${SKIP} skipped)"
fi
echo "========================================="
echo "$RESULT_LINE"
echo "========================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
