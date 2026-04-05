#!/usr/bin/env bash
# configure-pbs.sh — Configure Proxmox Backup Server after ISO installation.
#
# Reads config from site/config.yaml and secrets from SOPS. Performs all
# post-install configuration: SSH key setup, NFS mount, datastore creation,
# retention policy, API token, Proxmox storage, and backup jobs.
#
# Usage:
#   framework/scripts/configure-pbs.sh                       # Full configuration
#   framework/scripts/configure-pbs.sh --verify              # Check configuration only
#   framework/scripts/configure-pbs.sh --dry-run             # Show what would be done
#   framework/scripts/configure-pbs.sh --skip-backup-jobs    # Skip backup job creation
#
# Idempotent: safe to re-run. Skips steps that are already completed.
#
# Prerequisites:
#   - PBS installed from ISO and reachable at the IP in config.yaml
#   - PBS root password stored in SOPS (pbs_root_password)
#   - NAS NFS export accessible from PBS

set -euo pipefail

# --- Locate repo root ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2
  exit 1
}

REPO_DIR="$(find_repo_root)"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"
SECRETS_FILE="${REPO_DIR}/site/sops/secrets.yaml"

# --- Parse arguments ---
MODE="configure"  # configure | verify | dry-run
SKIP_BACKUP_JOBS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)  MODE="verify"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    --skip-backup-jobs) SKIP_BACKUP_JOBS=true; shift ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--verify|--dry-run|--skip-backup-jobs|--help]"
      echo ""
      echo "Configure Proxmox Backup Server after ISO installation."
      echo ""
      echo "Options:"
      echo "  --verify            Check configuration without making changes"
      echo "  --dry-run           Show what would be done without executing"
      echo "  --skip-backup-jobs  Skip backup job creation (used by rebuild-cluster.sh)"
      echo "  --help              Show this help message"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --- Check prerequisites ---
for tool in sops yq jq curl ssh sshpass; do
  if ! command -v "$tool" &>/dev/null; then
    echo "ERROR: Required tool not found: $tool" >&2
    if [[ "$tool" == "sshpass" ]]; then
      echo "Install with: brew install sshpass  (or: nix-env -iA nixpkgs.sshpass)" >&2
    fi
    exit 1
  fi
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# --- Read config ---
PBS_IP=$(yq -r '.vms.pbs.ip' "$CONFIG_FILE")
NAS_IP=$(yq -r '.nas.ip' "$CONFIG_FILE")
NFS_EXPORT=$(yq -r '.nas.nfs_export' "$CONFIG_FILE")
DATASTORE_NAME=$(yq -r '.pbs.datastore_name' "$CONFIG_FILE")
DATASTORE_MOUNT=$(yq -r '.pbs.datastore_mount' "$CONFIG_FILE")
KEEP_DAILY=$(yq -r '.pbs.keep_daily' "$CONFIG_FILE")
KEEP_WEEKLY=$(yq -r '.pbs.keep_weekly' "$CONFIG_FILE")
KEEP_MONTHLY=$(yq -r '.pbs.keep_monthly' "$CONFIG_FILE")
BACKUP_SCHEDULE=$(yq -r '.pbs.backup_schedule' "$CONFIG_FILE")
PVE_NODE1_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG_FILE")

echo "=== PBS Configuration ==="
echo "PBS IP:          $PBS_IP"
echo "NAS IP:          $NAS_IP"
echo "NFS Export:      $NFS_EXPORT"
echo "Datastore:       $DATASTORE_NAME at $DATASTORE_MOUNT"
echo "Retention:       ${KEEP_DAILY}d / ${KEEP_WEEKLY}w / ${KEEP_MONTHLY}m"
echo "Backup schedule: $BACKUP_SCHEDULE"
echo "Mode:            $MODE"
echo ""

# --- Read secrets ---
PBS_PASSWORD=$(sops -d --extract '["pbs_root_password"]' "$SECRETS_FILE" 2>/dev/null) || {
  echo "ERROR: PBS root password not found in SOPS." >&2
  echo "Add it with: sops --set '[\"pbs_root_password\"] \"<password>\"' site/sops/secrets.yaml" >&2
  exit 1
}

# Operator's workstation SSH key — same approach as configure-node-network.sh.
# This is the key used for workstation → PBS SSH after initial setup.
OPERATOR_PUBKEY=""
for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
  if [[ -f "$keyfile" ]]; then
    OPERATOR_PUBKEY=$(cat "$keyfile")
    break
  fi
done
if [[ -z "$OPERATOR_PUBKEY" ]]; then
  echo "ERROR: No SSH public key found (~/.ssh/id_*.pub)" >&2
  echo "Generate one with: ssh-keygen -t ed25519" >&2
  exit 1
fi

# SOPS SSH key — installed for CI runner access (separate from operator key)
SOPS_PUBKEY=$(sops -d --extract '["ssh_pubkey"]' "$SECRETS_FILE" 2>/dev/null || true)

# --- Helper: SSH to PBS ---
# Try operator's key first, fall back to sshpass with PBS password.
# After step A installs the operator's key, key auth will work.
pbs_ssh() {
  ssh -n -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    -o BatchMode=yes "root@${PBS_IP}" "$@" 2>/dev/null \
  || sshpass -p "$PBS_PASSWORD" ssh -n -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 "root@${PBS_IP}" "$@"
}

# --- Helper: SSH to Proxmox node ---
pve_ssh() {
  ssh -n -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "root@${PVE_NODE1_IP}" "$@"
}

# --- Check PBS reachability ---
echo "Checking PBS reachability..."
# PBS version endpoint requires auth, so just check if the HTTPS port responds
if ! curl -sk --max-time 5 "https://${PBS_IP}:8007/" -o /dev/null; then
  echo "ERROR: PBS is not reachable at https://${PBS_IP}:8007" >&2
  echo "Complete the PBS ISO installation via the Proxmox console first." >&2
  exit 1
fi
echo "  PBS HTTPS port responding"

if [[ "$MODE" == "verify" ]]; then
  echo ""
  echo "=== Verification ==="
  PASS=0
  FAIL=0

  # V1: PBS reachable
  echo -n "  PBS HTTPS reachable: "
  if curl -sk --max-time 5 "https://${PBS_IP}:8007/" -o /dev/null 2>/dev/null; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi

  # V2: SSH access
  echo -n "  SSH key access: "
  if ssh -n -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 \
    "root@${PBS_IP}" "echo ok" &>/dev/null; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL (key auth not set up)"
    ((FAIL++))
  fi

  # V3: NFS mounted
  echo -n "  NFS datastore mounted: "
  if pbs_ssh "mount | grep -q '${DATASTORE_MOUNT}'" 2>/dev/null; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi

  # V4: Datastore exists
  echo -n "  PBS datastore '${DATASTORE_NAME}': "
  if pbs_ssh "proxmox-backup-manager datastore list --output-format json" 2>/dev/null \
    | jq -e ".[] | select(.name == \"${DATASTORE_NAME}\")" &>/dev/null; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi

  # V5: API token exists
  echo -n "  API token 'proxmox-backup': "
  if pbs_ssh "proxmox-backup-manager user list-tokens root@pam --output-format json" 2>/dev/null \
    | jq -e '.[] | select(."token-name" == "proxmox-backup")' &>/dev/null; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi

  # V6: Proxmox storage exists
  echo -n "  Proxmox storage 'pbs-nas': "
  if pve_ssh "pvesh get /storage/pbs-nas --output-format json" &>/dev/null; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi

  # V7: Backup job exists
  echo -n "  Backup job for precious-state VMs: "
  if pve_ssh "pvesh get /cluster/backup --output-format json" 2>/dev/null \
    | jq -e '.[] | select(.storage == "pbs-nas")' &>/dev/null; then
    echo "PASS"
    ((PASS++))
  else
    echo "FAIL"
    ((FAIL++))
  fi

  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  [[ $FAIL -eq 0 ]] && exit 0 || exit 1
fi

if [[ "$MODE" == "dry-run" ]]; then
  echo "=== Dry Run ==="
  echo "Would perform the following steps:"
  echo "  A. Set up SSH key access to PBS"
  echo "  B. Configure NFS mount: ${NAS_IP}:${NFS_EXPORT} → ${DATASTORE_MOUNT}"
  echo "  C. Create PBS datastore: ${DATASTORE_NAME}"
  echo "  D. Set retention: ${KEEP_DAILY}d / ${KEEP_WEEKLY}w / ${KEEP_MONTHLY}m"
  echo "  E. Create API token: root@pam!proxmox-backup"
  echo "  F. Get PBS fingerprint"
  echo "  G. Add PBS storage to Proxmox cluster"
  echo "  H. Create backup jobs for Vault VMs"
  exit 0
fi

# ==========================================================================
# CONFIGURATION MODE
# ==========================================================================

# --- A. Set up SSH key access ---
echo ""
echo "--- A. Setting up SSH key access ---"
# Install the operator's workstation key (for workstation → PBS SSH)
# and the SOPS key (for CI runner → PBS SSH). Same approach as
# configure-node-network.sh uses for Proxmox nodes.
sshpass -p "$PBS_PASSWORD" ssh -n -o StrictHostKeyChecking=accept-new \
  "root@${PBS_IP}" "mkdir -p /root/.ssh && chmod 700 /root/.ssh" 2>/dev/null

# Install operator key
OPERATOR_KEY_ID=$(echo "$OPERATOR_PUBKEY" | awk '{print $NF}')
if sshpass -p "$PBS_PASSWORD" ssh -n -o StrictHostKeyChecking=accept-new \
    "root@${PBS_IP}" "grep -qF '${OPERATOR_KEY_ID}' /root/.ssh/authorized_keys 2>/dev/null"; then
  echo "  Operator key already installed"
else
  echo "  Installing operator workstation key..."
  echo "$OPERATOR_PUBKEY" | sshpass -p "$PBS_PASSWORD" ssh \
    -o StrictHostKeyChecking=accept-new \
    "root@${PBS_IP}" "cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
  echo "  Operator key installed"
fi

# Install SOPS key (for CI runner)
if [[ -n "$SOPS_PUBKEY" ]]; then
  SOPS_KEY_ID=$(echo "$SOPS_PUBKEY" | awk '{print $NF}')
  if sshpass -p "$PBS_PASSWORD" ssh -n -o StrictHostKeyChecking=accept-new \
      "root@${PBS_IP}" "grep -qF '${SOPS_KEY_ID}' /root/.ssh/authorized_keys 2>/dev/null"; then
    echo "  SOPS key already installed"
  else
    echo "  Installing SOPS key (CI runner access)..."
    echo "$SOPS_PUBKEY" | sshpass -p "$PBS_PASSWORD" ssh \
      -o StrictHostKeyChecking=accept-new \
      "root@${PBS_IP}" "cat >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
    echo "  SOPS key installed"
  fi
fi

# Verify operator key auth works
if ssh -n -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=5 \
  "root@${PBS_IP}" "echo ok" &>/dev/null; then
  echo "  SSH key auth verified"
else
  echo "ERROR: SSH key auth not working after install" >&2
  exit 1
fi

# From here on, use key-based SSH (operator's key)
pbs_ssh_key() {
  ssh -n -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
    "root@${PBS_IP}" "$@"
}

# --- B. Configure NFS mount ---
echo ""
echo "--- B. Configuring NFS mount ---"
FSTAB_ENTRY="${NAS_IP}:${NFS_EXPORT} ${DATASTORE_MOUNT} nfs defaults,_netdev 0 0"

if pbs_ssh_key "mount | grep -q '${DATASTORE_MOUNT}'" && \
   pbs_ssh_key "df '${DATASTORE_MOUNT}' >/dev/null 2>&1"; then
  echo "  NFS already mounted at ${DATASTORE_MOUNT} — verified functional"
elif pbs_ssh_key "mount | grep -q '${DATASTORE_MOUNT}'"; then
  # Mount exists but is stale (NAS share was deleted/recreated while PBS
  # had an active mount). Stale NFS handles are stuck in the kernel —
  # the only reliable fix is to recreate the PBS VM.
  # Exit with code 10 to signal rebuild-cluster.sh to taint and recreate.
  echo "ERROR: Stale NFS mount at ${DATASTORE_MOUNT}" >&2
  echo "  The NAS share was likely deleted or recreated while PBS was running." >&2
  echo "  The PBS VM must be recreated to clear the stale NFS handle." >&2
  exit 10
else
  echo "  Creating mount point..."
  pbs_ssh_key "mkdir -p ${DATASTORE_MOUNT}"

  # Add fstab entry if not present
  if pbs_ssh_key "grep -q '${DATASTORE_MOUNT}' /etc/fstab"; then
    echo "  fstab entry already exists"
  else
    echo "  Adding fstab entry..."
    pbs_ssh_key "echo '${FSTAB_ENTRY}' >> /etc/fstab"
  fi

  echo "  Mounting NFS..."
  pbs_ssh_key "mount ${DATASTORE_MOUNT}" || {
    echo "ERROR: NFS mount failed. Check that the NAS export is accessible:" >&2
    echo "  NAS IP: ${NAS_IP}" >&2
    echo "  Export: ${NFS_EXPORT}" >&2
    echo "  Verify: showmount -e ${NAS_IP}" >&2
    exit 1
  }
  echo "  NFS mounted"
fi

# Verify NFS mount has space
NFS_SIZE=$(pbs_ssh_key "df -h ${DATASTORE_MOUNT}" | tail -1 | awk '{print $2}')
echo "  NFS capacity: ${NFS_SIZE}"

  # NAS directory permissions are validated by verify-nas-prereqs.sh in step 0.
  # If we got here, prerequisites passed — no auto-fix needed.

# --- C. Create PBS datastore ---
echo ""
echo "--- C. Creating PBS datastore ---"
if pbs_ssh_key "proxmox-backup-manager datastore list --output-format json" \
  | jq -e ".[] | select(.name == \"${DATASTORE_NAME}\")" &>/dev/null; then
  # Verify the datastore is functional (not just configured).
  # If the underlying .chunks directory was deleted (e.g., by --level5 cleanup),
  # the datastore config exists but backups fail. Remove and recreate.
  if pbs_ssh_key "test -d ${DATASTORE_MOUNT}/.chunks" 2>/dev/null; then
    echo "  Datastore '${DATASTORE_NAME}' already exists — verified functional"
  else
    echo "  Datastore '${DATASTORE_NAME}' is configured but .chunks is missing — recreating..."
    # Check if the mount point has backup data that would be destroyed
    BACKUP_FILES=$(pbs_ssh_key "find ${DATASTORE_MOUNT} -name '*.fidx' -o -name '*.didx' 2>/dev/null | wc -l" 2>/dev/null || echo "0")
    if [[ "$BACKUP_FILES" -gt 0 ]]; then
      echo "  ERROR: ${DATASTORE_MOUNT} contains ${BACKUP_FILES} backup files but .chunks is missing." >&2
      echo "  This may indicate a corrupted datastore. Refusing to delete backup data." >&2
      echo "  To force recreation, manually remove the contents:" >&2
      echo "    ssh root@<pbs-ip> 'rm -rf ${DATASTORE_MOUNT}/.chunks ${DATASTORE_MOUNT}/vm ${DATASTORE_MOUNT}/ct'" >&2
      exit 1
    fi
    pbs_ssh_key "proxmox-backup-manager datastore remove ${DATASTORE_NAME}" 2>/dev/null || true
    sleep 2
    # Clean the mount point (Synology leaves #recycle and @eaDir — no backup data at this point)
    pbs_ssh_key "find ${DATASTORE_MOUNT} -mindepth 1 -delete 2>/dev/null || true"
    pbs_ssh_key "proxmox-backup-manager datastore create ${DATASTORE_NAME} ${DATASTORE_MOUNT}" 2>&1
    if pbs_ssh_key "test -d ${DATASTORE_MOUNT}/.chunks" 2>/dev/null; then
      echo "  Datastore recreated successfully"
    else
      echo "  ERROR: Failed to recreate datastore" >&2
      exit 1
    fi
  fi
else
  echo "  Creating datastore '${DATASTORE_NAME}' at ${DATASTORE_MOUNT}..."
  if pbs_ssh_key "proxmox-backup-manager datastore create ${DATASTORE_NAME} ${DATASTORE_MOUNT}" 2>&1; then
    echo "  Datastore created"
  else
    # If the path is non-empty (e.g., restoring from NAS with existing backup data),
    # PBS refuses to create the datastore via the API. Write the config directly
    # and restart PBS to adopt the existing data.
    echo "  Path not empty — adopting existing datastore data..."
    pbs_ssh_key "grep -q 'datastore: ${DATASTORE_NAME}' /etc/proxmox-backup/datastore.cfg 2>/dev/null \
      || printf '\ndatastore: ${DATASTORE_NAME}\n\tpath ${DATASTORE_MOUNT}\n\n' >> /etc/proxmox-backup/datastore.cfg"
    pbs_ssh_key "systemctl restart proxmox-backup-proxy proxmox-backup"
    sleep 3
    # Verify
    if pbs_ssh_key "proxmox-backup-manager datastore list --output-format json" \
      | jq -e ".[] | select(.name == \"${DATASTORE_NAME}\")" &>/dev/null; then
      echo "  Datastore adopted successfully"
    else
      echo "ERROR: Failed to create or adopt datastore" >&2
      exit 1
    fi
  fi
fi

# --- D. Configure retention via prune job ---
echo ""
echo "--- D. Setting retention policy (prune job) ---"
echo "  Retention: keep-daily=${KEEP_DAILY}, keep-weekly=${KEEP_WEEKLY}, keep-monthly=${KEEP_MONTHLY}"

# PBS 4.x uses prune jobs instead of datastore-level retention settings
PRUNE_JOB_ID="${DATASTORE_NAME}-daily"
if pbs_ssh_key "proxmox-backup-manager prune-job list --output-format json" 2>/dev/null \
  | jq -e ".[] | select(.id == \"${PRUNE_JOB_ID}\")" &>/dev/null; then
  echo "  Prune job '${PRUNE_JOB_ID}' already exists — updating retention"
  pbs_ssh_key "proxmox-backup-manager prune-job update ${PRUNE_JOB_ID} \
    --keep-daily ${KEEP_DAILY} \
    --keep-weekly ${KEEP_WEEKLY} \
    --keep-monthly ${KEEP_MONTHLY}"
else
  echo "  Creating prune job..."
  pbs_ssh_key "proxmox-backup-manager prune-job create ${PRUNE_JOB_ID} \
    --store ${DATASTORE_NAME} \
    --keep-daily ${KEEP_DAILY} \
    --keep-weekly ${KEEP_WEEKLY} \
    --keep-monthly ${KEEP_MONTHLY} \
    --schedule 'daily'"
fi
echo "  Prune job configured"

# --- E. Create API token ---
echo ""
echo "--- E. Creating API token ---"
TOKEN_EXISTS=false
if pbs_ssh_key "proxmox-backup-manager user list-tokens root@pam --output-format json" 2>/dev/null \
  | jq -e '.[] | select(.tokenid == "proxmox-backup" or .["token-name"] == "proxmox-backup")' &>/dev/null; then
  TOKEN_EXISTS=true
  echo "  API token 'proxmox-backup' already exists — skipping creation"
fi

if [[ "$TOKEN_EXISTS" == "false" ]]; then
  echo "  Generating API token..."
  TOKEN_OUTPUT=$(pbs_ssh_key "proxmox-backup-manager user generate-token root@pam proxmox-backup")
  # Extract the token value — output format is typically:
  # "value": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' || true)

  if [[ -z "$TOKEN_SECRET" ]]; then
    # Try another format — PBS may output it differently
    TOKEN_SECRET=$(echo "$TOKEN_OUTPUT" | tail -1 | awk '{print $NF}')
  fi

  if [[ -n "$TOKEN_SECRET" ]]; then
    echo "  Token created. Writing to SOPS..."
    sops --set "[\"pbs_api_token\"] \"${TOKEN_SECRET}\"" "$SECRETS_FILE"
    echo "  Token stored in SOPS"
  else
    echo "ERROR: Could not extract token secret from output:" >&2
    echo "$TOKEN_OUTPUT" >&2
    echo "Cannot configure Proxmox storage or backup jobs without the token." >&2
    exit 1
  fi
fi

# Read the API token from SOPS (whether just created or pre-existing)
PBS_API_TOKEN=$(sops -d --extract '["pbs_api_token"]' "$SECRETS_FILE" 2>/dev/null || true)

# Grant the token Admin ACL (PBS 4.x tokens don't inherit superuser privileges)
# The CLI rejects token auth-ids (! in the ID), so write acl.cfg directly.
echo "  Ensuring token has Admin ACL..."
ACL_LINE='acl:1:/:root@pam!proxmox-backup:Admin'
if pbs_ssh_key "grep -qF 'root@pam!proxmox-backup' /etc/proxmox-backup/acl.cfg 2>/dev/null"; then
  echo "  Token ACL already set"
else
  pbs_ssh_key "echo '${ACL_LINE}' >> /etc/proxmox-backup/acl.cfg && systemctl restart proxmox-backup-proxy"
  echo "  Token ACL set and proxy restarted"
fi

# --- F. Get PBS fingerprint ---
echo ""
echo "--- F. Getting PBS certificate fingerprint ---"
PBS_FINGERPRINT=$(pbs_ssh_key "proxmox-backup-manager cert info 2>/dev/null" \
  | grep -i fingerprint | head -1 | awk '{print $NF}' || true)

if [[ -z "$PBS_FINGERPRINT" ]]; then
  # Alternative: get fingerprint from the HTTPS certificate directly
  PBS_FINGERPRINT=$(echo | openssl s_client -connect "${PBS_IP}:8007" 2>/dev/null \
    | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
    | sed 's/.*=//; s/://g' || true)
fi

if [[ -n "$PBS_FINGERPRINT" ]]; then
  echo "  Fingerprint: ${PBS_FINGERPRINT}"
else
  echo "  WARNING: Could not extract fingerprint"
fi

# --- G. Add PBS storage to Proxmox ---
echo ""
echo "--- G. Adding PBS storage to Proxmox ---"
if pve_ssh "pvesh get /storage/pbs-nas --output-format json" &>/dev/null; then
  # Storage exists — verify fingerprint matches (PBS may have been reinstalled)
  EXISTING_FP=$(pve_ssh "pvesh get /storage/pbs-nas --output-format json" 2>/dev/null \
    | jq -r '.fingerprint // empty' || true)
  if [[ -n "$PBS_FINGERPRINT" && -n "$EXISTING_FP" && "$EXISTING_FP" != "$PBS_FINGERPRINT" ]]; then
    echo "  Storage 'pbs-nas' exists but fingerprint is stale — updating..."
    echo "    Old: ${EXISTING_FP}"
    echo "    New: ${PBS_FINGERPRINT}"
    # PBS was reinstalled — fingerprint AND API token have changed.
    # Remove and recreate the storage entry with current credentials.
    pve_ssh "pvesm remove pbs-nas" 2>/dev/null || true
    pve_ssh "pvesh create /storage \
      --storage pbs-nas \
      --type pbs \
      --server ${PBS_IP} \
      --username 'root@pam!proxmox-backup' \
      --password '${PBS_API_TOKEN}' \
      --datastore ${DATASTORE_NAME} \
      --fingerprint '${PBS_FINGERPRINT}' \
      --content backup" 2>/dev/null \
      && echo "  Storage entry recreated with current fingerprint and token" \
      || {
        # Fallback to direct storage.cfg write
        pve_ssh "cat >> /etc/pve/storage.cfg << STOREOF

pbs: pbs-nas
	datastore ${DATASTORE_NAME}
	server ${PBS_IP}
	content backup
	fingerprint ${PBS_FINGERPRINT}
	username root@pam!proxmox-backup
STOREOF
echo '${PBS_API_TOKEN}' > /etc/pve/priv/storage/pbs-nas.pw
chmod 600 /etc/pve/priv/storage/pbs-nas.pw"
        echo "  Storage entry recreated via storage.cfg"
      }
  else
    echo "  Storage 'pbs-nas' already exists — fingerprint OK"
  fi
else
  if [[ -z "$PBS_API_TOKEN" ]]; then
    echo "  ERROR: No API token in SOPS — cannot configure Proxmox storage" >&2
    exit 1
  elif [[ -z "$PBS_FINGERPRINT" ]]; then
    echo "  ERROR: No fingerprint — cannot configure Proxmox storage" >&2
    exit 1
  else
    echo "  Adding PBS storage to Proxmox..."
    if pve_ssh "pvesh create /storage \
      --storage pbs-nas \
      --type pbs \
      --server ${PBS_IP} \
      --username 'root@pam!proxmox-backup' \
      --password '${PBS_API_TOKEN}' \
      --datastore ${DATASTORE_NAME} \
      --fingerprint '${PBS_FINGERPRINT}' \
      --content backup" 2>/dev/null; then
      echo "  PBS storage added via pvesh"
    else
      echo "  pvesh failed (validation issue) — writing storage.cfg directly..."
      pve_ssh "cat >> /etc/pve/storage.cfg << EOF

pbs: pbs-nas
	datastore ${DATASTORE_NAME}
	server ${PBS_IP}
	content backup
	fingerprint ${PBS_FINGERPRINT}
	username root@pam!proxmox-backup
EOF
echo '${PBS_API_TOKEN}' > /etc/pve/priv/storage/pbs-nas.pw
chmod 600 /etc/pve/priv/storage/pbs-nas.pw"
      echo "  PBS storage added via storage.cfg"
    fi
  fi
fi

# --- G.2 Verify PBS storage connectivity ---
echo ""
echo "--- G.2 Verifying PBS storage connectivity ---"
PBS_STATUS=$(pve_ssh "pvesm status 2>/dev/null" | grep pbs-nas || true)
if echo "$PBS_STATUS" | grep -q "active"; then
  echo "  pbs-nas is active"

  # Datastore ownership is set by PBS during datastore create.
  # NAS POSIX permissions are validated by verify-nas-prereqs.sh in step 0.
else
  echo "  ERROR: pbs-nas is not active. Status:"
  echo "  $PBS_STATUS"
  echo ""
  echo "  This means Proxmox cannot connect to PBS. Common causes:"
  echo "  - Fingerprint mismatch (PBS reinstalled, old fingerprint in storage.cfg)"
  echo "  - API token invalid (PBS reinstalled, old token in credentials file)"
  echo "  - PBS not reachable on port 8007"
  echo ""
  echo "  Backups will fail until this is resolved."
  exit 1
fi

# --- H. Create backup jobs ---
echo ""
if [[ "$SKIP_BACKUP_JOBS" == "true" ]]; then
  echo "--- H. Skipping backup job creation (--skip-backup-jobs) ---"
else
echo "--- H. Creating backup jobs for precious-state VMs ---"

# VMs with precious state: Vault (Raft storage) and GitLab (repos, CI/CD data)
BACKUP_VMIDS=""
for vm_name in vault-prod vault-dev gitlab; do
  VMID=$(pve_ssh "pvesh get /cluster/resources --type vm --output-format json" \
    | jq -r ".[] | select(.name == \"${vm_name}\") | .vmid" 2>/dev/null || true)
  if [[ -n "$VMID" ]]; then
    echo "  ${vm_name}: VMID ${VMID}"
    if [[ -n "$BACKUP_VMIDS" ]]; then
      BACKUP_VMIDS="${BACKUP_VMIDS},${VMID}"
    else
      BACKUP_VMIDS="$VMID"
    fi
  else
    echo "  WARNING: Could not find VMID for ${vm_name}"
  fi
done

if [[ -z "$BACKUP_VMIDS" ]]; then
  echo "  ERROR: No VMIDs found — cannot create backup jobs for precious-state VMs" >&2
  exit 1
else
  # Check if a backup job already exists for pbs-nas
  EXISTING_JOB=$(pve_ssh "pvesh get /cluster/backup --output-format json" 2>/dev/null \
    | jq -r '.[] | select(.storage == "pbs-nas") | .id' 2>/dev/null || true)

  if [[ -n "$EXISTING_JOB" ]]; then
    echo "  Backup job already exists (id: ${EXISTING_JOB}) — updating VMIDs..."
    pve_ssh "pvesh set /cluster/backup/${EXISTING_JOB} \
      --vmid '${BACKUP_VMIDS}'"
    echo "  Backup job updated with VMIDs: ${BACKUP_VMIDS}"
  else
    echo "  Creating backup job for VMIDs: ${BACKUP_VMIDS}..."
    pve_ssh "pvesh create /cluster/backup \
      --storage pbs-nas \
      --schedule '${BACKUP_SCHEDULE}' \
      --vmid '${BACKUP_VMIDS}' \
      --mode snapshot \
      --compress zstd \
      --enabled 1 \
      --notes-template 'Precious state — Vault Raft + GitLab repos'"
    echo "  Backup job created"
  fi
fi
fi  # end --skip-backup-jobs check

# --- I. Commit SOPS changes ---
echo ""
echo "--- I. Checking for SOPS changes ---"
cd "$REPO_DIR"
if git diff --name-only site/sops/secrets.yaml | grep -q secrets.yaml; then
  echo "  SOPS secrets modified — committing..."
  git add site/sops/secrets.yaml
  git commit -m "sops: add PBS API token

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
  echo "  Committed"
else
  echo "  No SOPS changes to commit"
fi

# --- Summary ---
echo ""
echo "=== PBS Configuration Complete ==="
echo ""
echo "To verify: framework/scripts/configure-pbs.sh --verify"
echo ""
echo "Next steps:"
echo "  1. Rebuild Vault image with Raft snapshot timer:"
echo "     framework/scripts/build-image.sh site/nix/hosts/vault.nix vault"
echo "  2. Configure ZFS replication for PBS:"
echo "     framework/scripts/configure-replication.sh pbs"
echo "  3. Run a manual backup test:"
echo "     vzdump <vault-dev-vmid> --storage pbs-nas --mode snapshot --compress zstd"
