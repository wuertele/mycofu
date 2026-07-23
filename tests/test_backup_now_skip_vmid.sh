#!/usr/bin/env bash
# test_backup_now_skip_vmid.sh — --skip-vmid is narrow and absent flag is inert.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
STATE_FILE="${TMP_DIR}/pbs-state.txt"
# #591: shim-scoped file for capturing the vzdump --notes-template
# value so subsequent content-listing responses can echo the marker.
MARKER_FILE="${TMP_DIR}/marker.txt"
SSH_LOG="${TMP_DIR}/ssh.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${FIXTURE_REPO}/build" "$SHIM_DIR"
cp "${REPO_ROOT}/framework/scripts/backup-now.sh" "${FIXTURE_REPO}/framework/scripts/backup-now.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/backup-now.sh"

cat > "${FIXTURE_REPO}/framework/scripts/vm-scope.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  control-plane-modules) ;;
  *) exit 0 ;;
esac
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/vm-scope.sh"

cat > "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
certbot_cluster_expected_mode() { echo "staging"; }
EOF
cat > "${FIXTURE_REPO}/framework/scripts/vm-health-lib.sh" <<'EOF'
#!/usr/bin/env bash
VM_HEALTH_LAST_REASON=""
vm_health_check() { VM_HEALTH_LAST_REASON="ok"; return 0; }
EOF

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
proxmox:
  storage_pool: vmstore
vms:
  vault_dev:
    vmid: 303
    ip: 10.0.0.303
    backup: true
  acme_dev:
    vmid: 305
    ip: 10.0.0.305
    backup: true
EOF
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
query="${2:-}"
case "$query" in
  ".nodes[].mgmt_ip")
    echo "127.0.0.1"
    ;;
  ".proxmox.storage_pool // \"vmstore\"")
    echo "vmstore"
    ;;
  ".vms | to_entries[] | select(.value.backup == true) | .key")
    printf 'vault_dev\nacme_dev\n'
    ;;
  ".vms.vault_dev.vmid")
    echo "303"
    ;;
  ".vms.vault_dev.ip")
    echo "10.0.0.303"
    ;;
  ".vms.acme_dev.vmid")
    echo "305"
    ;;
  ".vms.acme_dev.ip")
    echo "10.0.0.305"
    ;;
  ".applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key")
    ;;
  *)
    echo "unexpected yq query: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/yq"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
printf '%s\n' "$cmd" >> "${SSH_LOG}"
case "$cmd" in
  "pvesm status 2>/dev/null | grep -q pbs-nas")
    exit 0
    ;;
  "date -u +%s")
    # sample_pbs_epoch() probe (#547 per-VM freshness anchor + #602
    # Option 2). Return a value 10 s in the past so subsequent ctimes
    # (int(time.time()) + 5 in the content listing) are strictly
    # greater than pre_vzdump_epoch under strict >.
    printf '%s\n' "$(( $(date -u +%s) - 10 ))"
    exit 0
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    python3 - <<'PY'
import json, os, time
state = os.environ["STATE_FILE"]
marker_file = os.environ.get("MARKER_FILE", "")
marker = ""
if marker_file and os.path.exists(marker_file):
    with open(marker_file) as f:
        marker = f.read().strip()
entries = []
if os.path.exists(state):
    with open(state) as f:
        for line in f:
            vmid = line.strip()
            if vmid:
                # #591: embed the captured BACKUP_NOW_MARKER in fresh
                # entries so the identity gate in verify_backup_landed_in_pbs
                # accepts our legitimate backups.
                entries.append({"vmid": int(vmid), "volid": f"pbs-nas:backup/vm/{vmid}/new", "size": 1, "ctime": int(time.time()) + 5, "notes": marker})
print(json.dumps(entries))
PY
    ;;
  "qm status 303"|"qm status 305")
    echo "status: running"
    ;;
  vzdump\ 303\ --storage\ pbs-nas*)
    printf '%s\n' "$cmd" \
      | sed -n "s/.*--notes-template '\([^']*\)'.*/\1/p" \
      > "${MARKER_FILE}" || true
    echo "303" >> "$STATE_FILE"
    ;;
  vzdump\ 305\ --storage\ pbs-nas*)
    printf '%s\n' "$cmd" \
      | sed -n "s/.*--notes-template '\([^']*\)'.*/\1/p" \
      > "${MARKER_FILE}" || true
    echo "305" >> "$STATE_FILE"
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

run_backup() {
  local name="$1"
  shift
  : > "$STATE_FILE"
  : > "$MARKER_FILE"
  : > "$SSH_LOG"
  set +e
  OUT="$(PATH="${SHIM_DIR}:${PATH}" STATE_FILE="$STATE_FILE" MARKER_FILE="$MARKER_FILE" SSH_LOG="$SSH_LOG" \
    bash -c 'name="$1"; shift; cd "$0" && framework/scripts/backup-now.sh --env dev --pin-out "build/${name}.json" "$@"' "$FIXTURE_REPO" "$name" "$@" 2>&1)"
  RC=$?
  set -e
}

test_start "BNS.1" "backup-now without --skip-vmid backs up every selected VM"
run_backup normal
if [[ "$RC" -eq 0 ]] &&
   grep -Fq 'vzdump 303 --storage pbs-nas' "$SSH_LOG" &&
   grep -Fq 'vzdump 305 --storage pbs-nas' "$SSH_LOG" &&
   ! grep -Fq 'exact-pin incomplete-VM convergence exception' <<< "$OUT"; then
  test_pass "absent skip flag preserves normal backup path"
else
  test_fail "normal backup path changed"
  printf 'rc=%s\nout:\n%s\nssh:\n%s\n' "$RC" "$OUT" "$(cat "$SSH_LOG")" >&2
fi

test_start "BNS.2" "--skip-vmid skips only the named VMID"
run_backup skip --skip-vmid 303
if [[ "$RC" -eq 0 ]] &&
   ! grep -Fq 'vzdump 303 --storage pbs-nas' "$SSH_LOG" &&
   grep -Fq 'vzdump 305 --storage pbs-nas' "$SSH_LOG" &&
   grep -Fq 'SKIP: vault_dev' <<< "$OUT" &&
   grep -Fq 'exact-pin incomplete-VM convergence exception' <<< "$OUT"; then
  test_pass "skip flag skips only VMID 303"
else
  test_fail "skip flag did not stay scoped to one VMID"
  printf 'rc=%s\nout:\n%s\nssh:\n%s\n' "$RC" "$OUT" "$(cat "$SSH_LOG")" >&2
fi

test_start "BNS.3" "--skip-vmid unknown VMID warns and continues"
run_backup unknown --skip-vmid 999
if [[ "$RC" -eq 0 ]] &&
   grep -Fq 'WARNING: --skip-vmid 999 did not match any selected backup-backed VM' <<< "$OUT" &&
   grep -Fq 'vzdump 303 --storage pbs-nas' "$SSH_LOG" &&
   grep -Fq 'vzdump 305 --storage pbs-nas' "$SSH_LOG"; then
  test_pass "unknown skip VMID is warning-only and backs up selected VMs"
else
  test_fail "unknown skip VMID behavior changed"
  printf 'rc=%s\nout:\n%s\nssh:\n%s\n' "$RC" "$OUT" "$(cat "$SSH_LOG")" >&2
fi

runner_summary
