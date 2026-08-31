#!/usr/bin/env bash
# install-pbs.sh — Automated PBS installation via Proxmox answer file.
#
# Usage:
#   framework/scripts/install-pbs.sh              # Install PBS (idempotent)
#   framework/scripts/install-pbs.sh --dry-run    # Generate answer file only
#
# Generates an answer.toml from config.yaml and SOPS, packages it into
# an ISO with label "proxmox-ais", attaches it to the PBS VM, and boots
# from the installer ISO. The PBS installer detects the answer file and
# runs non-interactively.
#
# Idempotent: if PBS is already installed (SSH reachable), skips.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
SECRETS="${REPO_DIR}/site/sops/secrets.yaml"
TEMPLATE="${REPO_DIR}/framework/templates/pbs-answer.toml.tmpl"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# --- Read config ---
PBS_IP=$(yq -r '.vms.pbs.ip' "$CONFIG")
PBS_VMID=$(yq -r '.vms.pbs.vmid' "$CONFIG")
PBS_NODE=$(yq -r '.vms.pbs.node' "$CONFIG")
PBS_NODE_IP=$(yq -r ".nodes[] | select(.name == \"${PBS_NODE}\") | .mgmt_ip" "$CONFIG")
PBS_ISO=$(yq -r '.pbs.iso' "$CONFIG")
PBS_ISO_SHA256=$(yq -r '.pbs.iso_sha256 // ""' "$CONFIG")
DOMAIN=$(yq -r '.domain' "$CONFIG")
GATEWAY=$(yq -r '.management.gateway' "$CONFIG")
MGMT_PREFIX=$(yq -r '.management.subnet' "$CONFIG" | sed 's|.*/||')
TIMEZONE=$(yq -r '.timezone // "UTC"' "$CONFIG")
MAILTO=$(yq -r '.email.to // "root@localhost"' "$CONFIG")
NTP_SERVER=$(yq -r '.ntp_server // .management.gateway' "$CONFIG")

# --- SSH helper ---
ssh_node() {
  local ip="$1"; shift
  ssh -n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 -o BatchMode=yes -o LogLevel=ERROR \
      "root@${ip}" "$@" 2>/dev/null
}

# --- Cleanup trap ---
# Always detach IDE and remove remastered ISO on exit (even on error).
# A stale ide0 reference causes tofu apply to fail on next run.
cleanup_pbs_iso() {
  ssh_node "$PBS_NODE_IP" "qm set ${PBS_VMID} --delete ide0 2>/dev/null" || true
  ssh_node "$PBS_NODE_IP" "qm set ${PBS_VMID} --boot order=scsi0 2>/dev/null" || true
  ssh_node "$PBS_NODE_IP" "rm -f /var/lib/vz/template/iso/pbs-auto.iso" || true
}
trap cleanup_pbs_iso EXIT

# --- Idempotency check ---
if [[ $DRY_RUN -eq 0 ]]; then
  if curl -sk --max-time 5 "https://${PBS_IP}:8007/" -o /dev/null 2>/dev/null; then
    echo "PBS already installed (HTTPS responding at ${PBS_IP}:8007). Skipping."
    exit 0
  fi
fi

# --- Decrypt password ---
ROOT_PASSWORD=$(sops -d --extract '["proxmox_api_password"]' "$SECRETS" 2>/dev/null || true)
if [[ -z "$ROOT_PASSWORD" ]]; then
  echo "ERROR: Could not read proxmox_api_password from SOPS" >&2
  exit 1
fi

# --- Generate answer.toml ---
echo "=== Generating PBS answer file ==="
ANSWER_DIR=$(mktemp -d)
ANSWER_FILE="${ANSWER_DIR}/answer.toml"

PBS_FQDN="pbs.${DOMAIN}"
PBS_CIDR="${PBS_IP}/${MGMT_PREFIX}"

sed \
  -e "s|PBS_FQDN|${PBS_FQDN}|g" \
  -e "s|PBS_MAILTO|${MAILTO}|g" \
  -e "s|PBS_TIMEZONE|${TIMEZONE}|g" \
  -e "s|PBS_ROOT_PASSWORD|${ROOT_PASSWORD}|g" \
  -e "s|PBS_CIDR|${PBS_CIDR}|g" \
  -e "s|PBS_DNS|${GATEWAY}|g" \
  -e "s|PBS_GATEWAY|${GATEWAY}|g" \
  "$TEMPLATE" > "$ANSWER_FILE"

echo "  FQDN:     ${PBS_FQDN}"
echo "  CIDR:     ${PBS_CIDR}"
echo "  Gateway:  ${GATEWAY}"
echo "  Timezone: ${TIMEZONE}"
echo "  Disk:     sda (ext4)"

# Validate TOML syntax (best-effort — parser may not be available)
TOML_VALID=$(python3 -c "
import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print('skip')
        sys.exit(0)
tomllib.load(open(sys.argv[1], 'rb'))
print('valid')
" "$ANSWER_FILE" 2>/dev/null || echo "error")
case "$TOML_VALID" in
  valid) echo "  TOML syntax: valid" ;;
  skip)  echo "  TOML syntax: not checked (no Python TOML parser)" ;;
  *)     echo "  WARNING: TOML validation failed — check answer file manually" ;;
esac

if [[ $DRY_RUN -eq 1 ]]; then
  echo ""
  echo "=== Answer file (dry-run) ==="
  # Show file with password redacted
  sed 's/root-password = ".*"/root-password = "***REDACTED***"/' "$ANSWER_FILE"
  rm -rf "$ANSWER_DIR"
  exit 0
fi

# --- Ensure PBS installer ISO is on the node ---
if ! ssh_node "$PBS_NODE_IP" "test -s /var/lib/vz/template/iso/${PBS_ISO}"; then
  # Remove any zero-byte leftover from a failed download
  ssh_node "$PBS_NODE_IP" "rm -f /var/lib/vz/template/iso/${PBS_ISO}" 2>/dev/null || true
  echo ""
  echo "=== Downloading PBS ISO ==="
  PBS_ISO_URL="https://download.proxmox.com/iso/${PBS_ISO}"
  echo "  Downloading from ${PBS_ISO_URL}..."
  # Try downloading on the node first; fall back to downloading on the
  # workstation and uploading via scp (fresh nodes may lack DNS/internet).
  if ! ssh_node "$PBS_NODE_IP" "curl -sk -o /var/lib/vz/template/iso/${PBS_ISO} '${PBS_ISO_URL}'" 2>/dev/null; then
    echo "  Node download failed — downloading on workstation and uploading..."
    LOCAL_ISO="/tmp/${PBS_ISO}"
    if [[ ! -f "$LOCAL_ISO" ]] || [[ ! -s "$LOCAL_ISO" ]]; then
      rm -f "$LOCAL_ISO"
      curl -skL -o "$LOCAL_ISO" "$PBS_ISO_URL" \
        || { echo "ERROR: Could not download PBS ISO" >&2; rm -f "$LOCAL_ISO"; rm -rf "$ANSWER_DIR"; exit 1; }
    fi
    scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$LOCAL_ISO" "root@${PBS_NODE_IP}:/var/lib/vz/template/iso/${PBS_ISO}" 2>/dev/null \
      || { echo "ERROR: Could not upload PBS ISO to node" >&2; rm -rf "$ANSWER_DIR"; exit 1; }
  fi
  echo "  PBS ISO available on node"
fi

# --- Verify ISO checksum ---
if [[ -n "$PBS_ISO_SHA256" ]]; then
  echo ""
  echo "=== Verifying PBS ISO checksum ==="
  ACTUAL_SHA256=$(ssh_node "$PBS_NODE_IP" "sha256sum /var/lib/vz/template/iso/${PBS_ISO} | awk '{print \$1}'" || true)
  if [[ -z "$ACTUAL_SHA256" ]]; then
    echo "ERROR: Could not compute checksum — SSH to ${PBS_NODE} failed or sha256sum not available" >&2
    exit 1
  fi
  if [[ "$ACTUAL_SHA256" != "$PBS_ISO_SHA256" ]]; then
    echo "ERROR: PBS ISO checksum mismatch" >&2
    echo "  Expected: ${PBS_ISO_SHA256}" >&2
    echo "  Actual:   ${ACTUAL_SHA256}" >&2
    echo "  The ISO at /var/lib/vz/template/iso/${PBS_ISO} on ${PBS_NODE} does not match config.yaml pbs.iso_sha256." >&2
    echo "  Remove the ISO and re-run, or update the checksum in config.yaml." >&2
    exit 1
  fi
  echo "  Checksum verified: ${ACTUAL_SHA256}"
else
  echo ""
  echo "WARNING: No pbs.iso_sha256 in config.yaml — skipping checksum verification"
fi

# --- Create answer ISO ---
echo ""
echo "=== Creating answer ISO ==="
ANSWER_ISO="${ANSWER_DIR}/pbs-answer.img"

# Remaster the PBS installer ISO on the Proxmox node to include:
# - answer.toml (installation parameters)
# - auto-installer-mode.toml (tells GRUB to default to automated entry)
# This requires xorriso (or genisoimage) on the node.
# The remastered ISO is temporary — deleted after installation.
scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$ANSWER_FILE" "root@${PBS_NODE_IP}:/tmp/answer.toml" 2>/dev/null
ssh_node "$PBS_NODE_IP" "
  # Extract original ISO
  rm -rf /tmp/pbs-iso-extract
  mkdir -p /tmp/pbs-iso-extract /tmp/pbs-iso-mount
  mount -o loop /var/lib/vz/template/iso/${PBS_ISO} /tmp/pbs-iso-mount 2>/dev/null
  cp -a /tmp/pbs-iso-mount/. /tmp/pbs-iso-extract/
  umount /tmp/pbs-iso-mount
  rm -rf /tmp/pbs-iso-mount

  # Add answer file
  cp /tmp/answer.toml /tmp/pbs-iso-extract/answer.toml
  rm /tmp/answer.toml

  # Add auto-installer-mode.toml (tells GRUB to use automated entry)
  printf '[mode]\niso = {}\n' > /tmp/pbs-iso-extract/auto-installer-mode.toml

  # Rebuild ISO (BIOS boot via GRUB eltorito)
  genisoimage -o /var/lib/vz/template/iso/pbs-auto.iso \
    -r -J \
    -b boot/grub/i386-pc/eltorito.img \
    -c boot.cat \
    -no-emul-boot \
    -boot-load-size 4 \
    -boot-info-table \
    -V 'PBS' \
    /tmp/pbs-iso-extract/ 2>/dev/null
  rm -rf /tmp/pbs-iso-extract
" || { echo "ERROR: ISO remastering failed on node" >&2; rm -rf "$ANSWER_DIR"; exit 1; }
echo "  Remastered ISO created on ${PBS_NODE}"

# --- Attach ISOs and configure boot ---
echo ""
echo "=== Configuring PBS VM (VMID ${PBS_VMID}) ==="

# Disable HA and stop the VM so we can reconfigure it.
# The VM may be boot-looping (empty disk, no OS yet). HA keeps restarting it.
# We MUST verify it's actually stopped before attaching the ISO — otherwise
# the boot order change won't affect the running QEMU process.
ssh_node "$PBS_NODE_IP" "ha-manager remove vm:${PBS_VMID}" || true
sleep 3
ssh_node "$PBS_NODE_IP" "qm shutdown ${PBS_VMID} --timeout 10" || true
sleep 5
ssh_node "$PBS_NODE_IP" "qm stop ${PBS_VMID}" || true
sleep 2

# Verify the VM is actually stopped. If not, force-kill QEMU.
for STOP_ATTEMPT in $(seq 1 6); do
  VM_STATUS=$(ssh_node "$PBS_NODE_IP" "qm status ${PBS_VMID} 2>/dev/null | awk '{print \$2}'" || echo "unknown")
  if [[ "$VM_STATUS" == "stopped" ]]; then
    echo "  VM stopped"
    break
  fi
  echo "  VM still ${VM_STATUS}, retrying stop... (attempt ${STOP_ATTEMPT}/6)"
  ssh_node "$PBS_NODE_IP" "qm stop ${PBS_VMID} --skiplock 1" || true
  sleep 5
done
if [[ "$VM_STATUS" != "stopped" ]]; then
  echo "ERROR: Could not stop PBS VM (status: ${VM_STATUS})" >&2
  echo "Try: ssh root@${PBS_NODE_IP} 'qm stop ${PBS_VMID} --skiplock 1'" >&2
  rm -rf "$ANSWER_DIR"
  exit 1
fi

# Attach remastered ISO on ide0
ssh_node "$PBS_NODE_IP" "qm set ${PBS_VMID} --ide0 local:iso/pbs-auto.iso,media=cdrom" || true

# Boot from ISO first for installation
ssh_node "$PBS_NODE_IP" "qm set ${PBS_VMID} --boot 'order=ide0;scsi0'" || true

echo "  Remastered ISO: pbs-auto.iso (ide0)"
echo "  Boot order: ide0 (installer) → scsi0 (disk)"
echo "  Answer file has reboot-mode=power-off — VM will stop after install"

# --- Start the VM and wait for install + power-off ---
echo ""
echo "=== Starting unattended PBS installation ==="
ssh_node "$PBS_NODE_IP" "qm start ${PBS_VMID}" || true
echo "  VM started. Installer will run non-interactively then power off."

# Wait for the VM to actually be running before polling for it to stop.
# HA start is async — the VM may still be "stopped" for a few seconds.
echo "  Waiting for VM to enter running state..."
for STARTUP_WAIT in $(seq 1 12); do
  VM_STATUS=$(ssh_node "$PBS_NODE_IP" "qm status ${PBS_VMID} 2>/dev/null | awk '{print \$2}'" || echo "unknown")
  [[ "$VM_STATUS" == "running" ]] && break
  sleep 5
done
if [[ "$VM_STATUS" != "running" ]]; then
  echo "ERROR: VM did not start (status: ${VM_STATUS})" >&2
  rm -rf "$ANSWER_DIR"
  exit 1
fi
echo "  VM is running"

# Phase 1: Wait for the VM to power off (installer sets reboot-mode=power-off)
TIMEOUT=600
ELAPSED=0
INSTALL_DONE=0
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  VM_STATUS=$(ssh_node "$PBS_NODE_IP" "qm status ${PBS_VMID} 2>/dev/null | awk '{print \$2}'" || echo "unknown")
  if [[ "$VM_STATUS" == "stopped" ]]; then
    echo "  VM powered off — installation complete"
    INSTALL_DONE=1
    break
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  if (( ELAPSED % 30 == 0 )); then
    echo "  Installer running... (${ELAPSED}s / ${TIMEOUT}s)"
  fi
done

if [[ $INSTALL_DONE -eq 0 ]]; then
  echo "ERROR: PBS installation timed out after ${TIMEOUT}s" >&2
  echo "Check the PBS VM console in the Proxmox UI for errors." >&2
  rm -rf "$ANSWER_DIR"
  exit 1
fi

# Phase 2: Detach ISO, set disk boot, start from installed disk
echo ""
echo "=== Booting installed PBS ==="
ssh_node "$PBS_NODE_IP" "qm set ${PBS_VMID} --delete ide0" || true
ssh_node "$PBS_NODE_IP" "qm set ${PBS_VMID} --boot 'order=scsi0'" || true
ssh_node "$PBS_NODE_IP" "qm start ${PBS_VMID}" || true
echo "  ISO detached, booting from disk..."

# Phase 3: Wait for PBS HTTPS to respond
ELAPSED=0
while [[ $ELAPSED -lt 120 ]]; do
  if curl -sk --max-time 5 "https://${PBS_IP}:8007/" -o /dev/null 2>/dev/null; then
    echo "  PBS is reachable!"
    break
  fi
  sleep 10
  ELAPSED=$((ELAPSED + 10))
  if (( ELAPSED % 30 == 0 )); then
    echo "  Waiting for PBS to boot... (${ELAPSED}s / 120s)"
  fi
done

if [[ $ELAPSED -ge 120 ]]; then
  echo "ERROR: PBS not reachable after boot (120s)" >&2
  rm -rf "$ANSWER_DIR"
  exit 1
fi

# --- Clean up ---
echo ""
echo "=== Cleaning up ==="

# Remove remastered ISO from node (contains plaintext password in answer.toml)
ssh_node "$PBS_NODE_IP" "rm -f /var/lib/vz/template/iso/pbs-auto.iso"

# Remove any leftover answer disk
ssh_node "$PBS_NODE_IP" "rm -f /var/lib/vz/template/iso/pbs-answer.img"

# Re-add HA resource (we removed it before installation to prevent HA
# from restarting the VM during reconfiguration)
ssh_node "$PBS_NODE_IP" "ha-manager add vm:${PBS_VMID} --state started 2>/dev/null || ha-manager set vm:${PBS_VMID} --state started 2>/dev/null || true"

# Remove local temp files
rm -rf "$ANSWER_DIR"

echo "  Answer ISO removed from node"
echo "  HA re-enabled"
echo "  Local temp files cleaned"

# --- Configure NTP ---
echo ""
echo "=== Configuring NTP on PBS ==="
# Wait briefly for SSH to be ready
sleep 5
for attempt in $(seq 1 6); do
  if sshpass -p "$ROOT_PASSWORD" ssh -n -o StrictHostKeyChecking=accept-new \
       -o ConnectTimeout=5 "root@${PBS_IP}" "true" 2>/dev/null; then
    break
  fi
  sleep 5
done

sshpass -p "$ROOT_PASSWORD" ssh -n -o StrictHostKeyChecking=accept-new \
  -o ConnectTimeout=10 "root@${PBS_IP}" "
  mkdir -p /etc/systemd/timesyncd.conf.d
  cat > /etc/systemd/timesyncd.conf.d/mycofu.conf <<EOF
[Time]
NTP=${NTP_SERVER}
EOF
  systemctl restart systemd-timesyncd
" 2>/dev/null && echo "  NTP configured (server: ${NTP_SERVER})" \
  || echo "  WARNING: Could not configure NTP"

# --- Write-once: persist PBS root password to SOPS ---
# configure-pbs.sh reads pbs_root_password from SOPS. install-pbs.sh sets
# the PBS root password to match proxmox_api_password. Write pbs_root_password
# to SOPS so configure-pbs.sh can find it.
if ! sops -d --extract '["pbs_root_password"]' "$SECRETS" &>/dev/null; then
  echo "Writing pbs_root_password to SOPS..."
  sops --set "[\"pbs_root_password\"] \"${ROOT_PASSWORD}\"" "$SECRETS"
  echo "  pbs_root_password written to SOPS"
else
  echo "  pbs_root_password already in SOPS"
fi

echo ""
echo "=== PBS installation complete ==="
echo "  PBS IP:    ${PBS_IP}"
echo "  PBS VMID:  ${PBS_VMID}"
echo "  Next: framework/scripts/configure-pbs.sh"
