#!/usr/bin/env bash
# verify-nas-prereqs.sh — Validate all NAS prerequisites for Mycofu.
#
# Checks NFS export settings, POSIX permissions, PostgreSQL, and Docker.
# Each check prints PASS or FAIL with specific remediation instructions.
#
# Usage:
#   framework/scripts/verify-nas-prereqs.sh
#
# Called by rebuild-cluster.sh step 0. Can also be run independently
# after following bringup.md to verify NAS setup is correct.
#
# Exit codes:
#   0 — all checks passed (or fixed with --fix)
#   1 — one or more checks failed
#
# Options:
#   --fix  Auto-fix issues that the framework can handle (e.g., Synology
#          ACL mode 000). Operator-only prerequisites (e.g., wrong squash
#          setting) still require manual action.

set -euo pipefail

FIX=0
for arg in "$@"; do
  [[ "$arg" == "--fix" ]] && FIX=1
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config.yaml not found: $CONFIG" >&2
  exit 1
fi

NAS_IP=$(yq -r '.nas.ip' "$CONFIG")
NAS_SSH_USER=$(yq -r '.nas.ssh_user' "$CONFIG")
NAS_PG_PORT=$(yq -r '.nas.postgres_port // 5432' "$CONFIG")
NFS_EXPORT=$(yq -r '.nas.nfs_export' "$CONFIG")

PASS=0
FAIL=0

check_pass() { echo "[PASS] $*"; PASS=$((PASS + 1)); }
check_fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

nas_ssh() {
  ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
    -o LogLevel=ERROR "${NAS_SSH_USER}@${NAS_IP}" "$@" 2>/dev/null
}

echo "=== NAS Prerequisite Checks ==="
echo "NAS: ${NAS_SSH_USER}@${NAS_IP}"
echo ""

# --- NAS reachability ---
if nas_ssh "true"; then
  check_pass "NAS (${NAS_IP}) reachable via SSH"
else
  check_fail "NAS (${NAS_IP}) not reachable via SSH"
  echo "       Verify the NAS is running and SSH is enabled."
  echo "       Test: ssh ${NAS_SSH_USER}@${NAS_IP}"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1  # Can't check anything else without SSH
fi

# --- PostgreSQL ---
echo ""
echo "--- PostgreSQL ---"
if nas_ssh "psql -U postgres -p ${NAS_PG_PORT} -c '\\l' 2>/dev/null" | grep -q tofu_state; then
  check_pass "PostgreSQL: tofu_state database exists"
else
  check_fail "PostgreSQL: tofu_state database not found"
  echo "       See bringup.md PostgreSQL section for setup instructions."
fi

# --- NFS export ---
echo ""
echo "--- NFS Export (${NFS_EXPORT}) ---"

# Check export exists
NFS_EXPORTS=$(nas_ssh "cat /etc/exports 2>/dev/null" || true)
NFS_LINE=$(echo "$NFS_EXPORTS" | grep "^${NFS_EXPORT}[[:space:]]" || true)

if [[ -n "$NFS_LINE" ]]; then
  check_pass "NFS export ${NFS_EXPORT} exists"
else
  check_fail "NFS export ${NFS_EXPORT} not found in /etc/exports"
  echo "       Create the shared folder and NFS permissions in the NAS UI."
  echo "       See bringup.md 'NFS Export (for PBS Backups)' section."
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1  # Can't check settings without the export
fi

# Check squash setting
if echo "$NFS_LINE" | grep -q "no_root_squash"; then
  check_pass "NFS squash: no_root_squash"
elif echo "$NFS_LINE" | grep -q "all_squash"; then
  check_fail "NFS squash: all_squash (PBS needs no_root_squash)"
  echo ""
  echo "       Synology DSM squash labels:"
  echo "         'No mapping'              = no_root_squash  (CORRECT)"
  echo "         'Map root to admin'       = root_squash     (WRONG)"
  echo "         'Map all users to admin'  = all_squash      (WRONG)"
  echo ""
  echo "       Fix: NAS UI → Control Panel → Shared Folder →"
  echo "       $(basename "$NFS_EXPORT") → Edit → NFS Permissions →"
  echo "       Edit rule → Squash: 'No mapping'"
elif echo "$NFS_LINE" | grep -q "root_squash"; then
  check_fail "NFS squash: root_squash (PBS needs no_root_squash)"
  echo "       Fix: NAS UI → Shared Folder → $(basename "$NFS_EXPORT") →"
  echo "       NFS Permissions → Squash: 'No mapping'"
else
  echo "  ? Could not determine squash setting from exports line"
fi

# Check POSIX permissions on NAS
NAS_DIR_PERMS=$(nas_ssh "stat -c '%a' '${NFS_EXPORT}' 2>/dev/null" || echo "unknown")
if [[ "$NAS_DIR_PERMS" == "unknown" ]]; then
  echo "  ? Could not check NAS directory permissions"
elif [[ "$NAS_DIR_PERMS" == "0" || "$NAS_DIR_PERMS" == "000" ]]; then
  if [[ $FIX -eq 1 ]]; then
    echo "[FIX]  NAS directory ${NFS_EXPORT}: POSIX mode ${NAS_DIR_PERMS} — fixing..."
    nas_ssh "chmod 777 '${NFS_EXPORT}'" 2>/dev/null
    NAS_DIR_PERMS=$(nas_ssh "stat -c '%a' '${NFS_EXPORT}' 2>/dev/null" || echo "unknown")
    if [[ "$NAS_DIR_PERMS" != "0" && "$NAS_DIR_PERMS" != "000" ]]; then
      check_pass "NAS directory ${NFS_EXPORT}: fixed permissions to ${NAS_DIR_PERMS}"
    else
      check_fail "NAS directory ${NFS_EXPORT}: could not fix (still mode ${NAS_DIR_PERMS})"
    fi
  else
    check_fail "NAS directory ${NFS_EXPORT}: POSIX mode ${NAS_DIR_PERMS}"
    echo ""
    echo "       Synology DSM creates shared folders with mode 000 and ACLs."
    echo "       NFS doesn't understand Synology ACLs — non-root users (like"
    echo "       the PBS backup user, uid 34) are blocked by mode 000."
    echo ""
    echo "       Fix: re-run with --fix, or manually:"
    echo "       ssh ${NAS_SSH_USER}@${NAS_IP} \"chmod 777 ${NFS_EXPORT}\""
  fi
else
  check_pass "NAS directory ${NFS_EXPORT}: permissions ${NAS_DIR_PERMS}"
fi

# --- Docker ---
echo ""
echo "--- Docker ---"
if nas_ssh "docker info >/dev/null 2>&1" || \
   nas_ssh "/volume1/@appstore/ContainerManager/usr/bin/docker info >/dev/null 2>&1"; then
  check_pass "Docker available on NAS"
else
  check_fail "Docker not available on NAS"
  echo "       Install Docker or Container Manager from the NAS package manager."
fi

# --- Summary ---
echo ""
echo "==========================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
  echo ""
  echo "Fix the failures above, then re-run:"
  echo "  framework/scripts/verify-nas-prereqs.sh"
  exit 1
fi
