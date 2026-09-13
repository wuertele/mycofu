#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
STATE_FILE="${TMP_DIR}/pbs-state.txt"
# #591: shim-scoped capture of vzdump's --notes-template value.
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

cat > "${FIXTURE_REPO}/framework/scripts/vm-health-lib.sh" <<'EOF'
#!/usr/bin/env bash
VM_HEALTH_LAST_REASON=""
vm_health_check() { VM_HEALTH_LAST_REASON="ok"; return 0; }
EOF

cat > "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
certbot_cluster_cert_storage_records() {
  printf 'vault_dev\tvault_dev\t10.0.0.303\t303\tvault.dev.example.test\tinfra\n'
}
certbot_cluster_run_remote_renewability_probe() {
  case "${STUB_PROBE_RC:-0}" in
    0)
      printf 'days_remaining=87\nnear_expiry=false\n'
      return 0
      ;;
    1)
      printf 'reason=cert-skipped\n'
      return 1
      ;;
    3)
      printf 'reason=certbot-command-failed\n'
      return 3
      ;;
    255)
      printf 'ssh: connect failed\n' >&2
      return 255
      ;;
  esac
}
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
EOF
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
query="${2:-}"
case "$query" in
  ".nodes[].mgmt_ip") echo "127.0.0.1" ;;
  ".proxmox.storage_pool // \"vmstore\"") echo "vmstore" ;;
  ".vms | to_entries[] | select(.value.backup == true) | .key") echo "vault_dev" ;;
  ".vms.vault_dev.vmid") echo "303" ;;
  ".vms.vault_dev.ip") echo "10.0.0.303" ;;
  ".applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key") ;;
  *) echo "unexpected yq query: $*" >&2; exit 9 ;;
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
                # #591: embed BACKUP_NOW_MARKER on fresh entries so
                # verify_backup_landed_in_pbs's identity gate accepts.
                entries.append({"vmid": int(vmid), "volid": f"pbs-nas:backup/vm/{vmid}/new", "size": 1, "ctime": int(time.time()) + 5, "notes": marker})
print(json.dumps(entries))
PY
    ;;
  "qm status 303")
    echo "status: running"
    ;;
  vzdump\ 303\ --storage\ pbs-nas*)
    printf '%s\n' "$cmd" \
      | sed -n "s/.*--notes-template '\([^']*\)'.*/\1/p" \
      > "${MARKER_FILE}" || true
    echo "303" >> "$STATE_FILE"
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

run_backup() {
  local rc="$1"
  local pin_name="$2"
  : > "$STATE_FILE"
  : > "$MARKER_FILE"
  : > "$SSH_LOG"
  set +e
  OUT="$(PATH="${SHIM_DIR}:${PATH}" STATE_FILE="$STATE_FILE" MARKER_FILE="$MARKER_FILE" SSH_LOG="$SSH_LOG" STUB_PROBE_RC="$rc" \
    bash -c 'cd "$0" && framework/scripts/backup-now.sh --env dev --pin-out "build/$1"' "$FIXTURE_REPO" "$pin_name" 2>&1)"
  RC=$?
  set -e
}

assert_pin() {
  local pin_name="$1"
  local jq_expr="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(jq -r "$jq_expr" "${FIXTURE_REPO}/build/${pin_name}")"
  if [[ "$actual" == "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected %s, got %s\n' "$expected" "$actual" >&2
    jq . "${FIXTURE_REPO}/build/${pin_name}" >&2
  fi
}

test_start "A4.1" "predicate rc=0 records trusted pin metadata"
run_backup 0 trusted.json
[[ "$RC" -eq 0 ]] && test_pass "backup exits 0 for trusted predicate" || test_fail "backup exits 0 for trusted predicate"
assert_pin trusted.json '.pins["303"].volid' 'pbs-nas:backup/vm/303/new' "pin object records volid"
assert_pin trusted.json '.pins["303"].trust' 'trusted' "rc=0 maps to trust=trusted"
assert_pin trusted.json '.pins["303"].days_remaining' '87' "days_remaining is recorded"
assert_pin trusted.json '.pins["303"].near_expiry' 'false' "near_expiry is recorded"

test_start "A4.2" "predicate rc=1 records untrusted and never blocks capture"
run_backup 1 untrusted.json
[[ "$RC" -eq 0 ]] && test_pass "backup exits 0 for untrusted predicate" || test_fail "backup exits 0 for untrusted predicate"
assert_pin untrusted.json '.pins["303"].trust' 'untrusted' "rc=1 maps to trust=untrusted"
assert_pin untrusted.json '.pins["303"].reason' 'cert-skipped' "untrusted reason is recorded"

test_start "A4.3" "predicate rc=3 records unknown and never blocks capture"
run_backup 3 unknown.json
[[ "$RC" -eq 0 ]] && test_pass "backup exits 0 for unknown predicate" || test_fail "backup exits 0 for unknown predicate"
assert_pin unknown.json '.pins["303"].trust' 'unknown' "rc=3 maps to trust=unknown"
assert_pin unknown.json '.pins["303"].reason' 'certbot-command-failed' "unknown reason is recorded"

test_start "A4.4" "unreachable VM predicate records unknown/vm-unreachable and capture exits 0"
run_backup 255 unreachable.json
[[ "$RC" -eq 0 ]] && test_pass "backup exits 0 when predicate SSH is unreachable" || test_fail "backup exits 0 when predicate SSH is unreachable"
assert_pin unreachable.json '.pins["303"].trust' 'unknown' "ssh failure maps to trust=unknown"
assert_pin unreachable.json '.pins["303"].reason' 'vm-unreachable' "ssh failure records vm-unreachable"

runner_summary
