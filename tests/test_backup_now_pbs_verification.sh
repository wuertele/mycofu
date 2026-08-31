#!/usr/bin/env bash
# test_backup_now_pbs_verification.sh — #97 / FG-11 fail-closed post-vzdump gate.
#
# vzdump can exit 0 while the backup did not actually land in PBS (stale NFS,
# PBS disk full, cached content listing). The default backup-now.sh flow must
# now verify per-VM that a fresh, non-empty volid is present in the PBS
# content listing after vzdump — and fail non-zero if not.
#
# Each subtest tampers with the shim's PBS content listing to fake one of the
# named failure modes and asserts that backup-now.sh exits non-zero AND does
# not record a pin for the affected VMID. On pre-fix code, backup-now.sh would
# happily record the ghost pin and exit 0; the assertions below FAIL in that
# state, which is the G4 "teeth" property.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
STATE_DIR="${TMP_DIR}/state"
SSH_LOG="${TMP_DIR}/ssh.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${FIXTURE_REPO}/build" "$SHIM_DIR" "$STATE_DIR"
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
    echo "vault_dev"
    ;;
  ".vms.vault_dev.vmid")
    echo "303"
    ;;
  ".vms.vault_dev.ip")
    echo "10.0.0.303"
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

# The ssh shim reads STATE_DIR/mode to decide how to fake the *post-vzdump*
# PBS content listing. Modes cover the FG-11 failure classes:
#   healthy       — fresh volid with size>0 and current ctime  (post-fix passes)
#   size-zero     — fresh volid with size=0                    (must fail)
#   stale-ctime   — new-looking volid but ctime predates run   (must fail)
#   missing-ctime — new volid with size>0 but no ctime field   (must fail)
#   null-verify   — new volid with size>0 fresh ctime AND      (must pass —
#                   verification: null (unverified by PBS)      null is absent)
#   verify-failed — new volid, size>0, fresh ctime, verify=fail (must fail)
#   missing       — no new volid at all (ghost backup)         (must fail)
# The "before" listing contains a single historical backup for VMID 303 so
# has_history=1 fires (first-deploy skip does not trigger).
cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
printf '%s\n' "$cmd" >> "${SSH_LOG}"

mode="$(cat "${STATE_DIR}/mode" 2>/dev/null || echo healthy)"

# #591 marker capture — extract vzdump's --notes-template value on demand
# so the fresh entries emitted below carry the correct BACKUP_NOW_MARKER
# for the current script invocation.
read_notes_template_marker() {
  cat "${STATE_DIR}/marker" 2>/dev/null || printf '%s' ""
}

case "$cmd" in
  "pvesm status 2>/dev/null | grep -q pbs-nas")
    exit 0
    ;;
  "date -u +%s")
    # #547: backup-now.sh samples PBS's clock per VM immediately before
    # vzdump. #602 Option 2: it then sleeps 1 s so a real backup's ctime
    # is strictly > the anchor. Answer with the current runner clock so
    # the pre_vzdump_epoch gate is aligned with the "fresh_ctime = now
    # + 5" that later PBS content queries return in healthy modes; +5
    # remains strictly > anchor even without waiting for real sleep-1.
    date -u +%s
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    # The very first content query happens BEFORE any vzdump, so
    # capture_new_backup_volids can compute a diff. We track invocation count
    # in STATE_DIR/query_count. Query 1..N return "before" (with historical
    # backup so first-deploy skip does not fire); subsequent queries return
    # "after" shaped by mode.
    count_file="${STATE_DIR}/query_count"
    count=$(cat "$count_file" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"

    now="$(date -u +%s)"
    old_ctime=$((now - 30 * 86400))  # 30 days ago
    fresh_ctime=$((now + 5))         # slightly future to survive freshness cmp

    if [[ "$count" -le 2 ]]; then
      # Historical backup so has_history=1 and script does not skip as first
      # deploy. The "before" backup has a different volid than any "after".
      cat <<'JSON'
[
  {"vmid": 303, "volid": "pbs-nas:backup/vm/303/history", "ctime": 1700000000, "size": 12345, "format": "pbs-vm"}
]
JSON
    else
      marker="$(read_notes_template_marker)"
      case "$mode" in
        missing-ctime)
          jq -nc --argjson ct "$fresh_ctime" --arg n "$marker" '[
            {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
            {vmid: 303, volid: "pbs-nas:backup/vm/303/nocti",                 size: 67890, format: "pbs-vm", notes: $n}
          ]'
          ;;
        null-verify)
          jq -nc --argjson ct "$fresh_ctime" --arg n "$marker" '[
            {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
            {vmid: 303, volid: "pbs-nas:backup/vm/303/nullvf",  ctime: $ct,       size: 67890, format: "pbs-vm", verification: null, notes: $n}
          ]'
          ;;
        healthy)
          jq -nc --argjson ct "$fresh_ctime" --arg n "$marker" '[
            {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
            {vmid: 303, volid: "pbs-nas:backup/vm/303/fresh",   ctime: $ct,       size: 67890, format: "pbs-vm", notes: $n}
          ]'
          ;;
        size-zero)
          jq -nc --argjson ct "$fresh_ctime" --arg n "$marker" '[
            {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
            {vmid: 303, volid: "pbs-nas:backup/vm/303/empty",   ctime: $ct,       size: 0,     format: "pbs-vm", notes: $n}
          ]'
          ;;
        stale-ctime)
          jq -nc --argjson ct "$old_ctime" --arg n "$marker" '[
            {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
            {vmid: 303, volid: "pbs-nas:backup/vm/303/stale",   ctime: $ct,       size: 67890, format: "pbs-vm", notes: $n}
          ]'
          ;;
        verify-failed)
          jq -nc --argjson ct "$fresh_ctime" --arg n "$marker" '[
            {vmid: 303, volid: "pbs-nas:backup/vm/303/history", ctime: 1700000000, size: 12345, format: "pbs-vm"},
            {vmid: 303, volid: "pbs-nas:backup/vm/303/badver",  ctime: $ct,       size: 67890, format: "pbs-vm", verification: {state: "failed"}, notes: $n}
          ]'
          ;;
        missing)
          # No new volid: exact same set as before. capture_new_backup_volids
          # returns empty and the existing pin_count!=1 branch fires.
          cat <<'JSON'
[
  {"vmid": 303, "volid": "pbs-nas:backup/vm/303/history", "ctime": 1700000000, "size": 12345, "format": "pbs-vm"}
]
JSON
          ;;
        *)
          echo "unexpected mode: $mode" >&2
          exit 9
          ;;
      esac
    fi
    ;;
  "qm status 303")
    echo "status: running"
    ;;
  vzdump\ 303\ --storage\ pbs-nas*)
    # #591: capture --notes-template so the shim's AFTER content listings
    # can embed the run's marker on the fresh entry. Even in FG-11-style
    # modes where the backup is missing/broken, embedding the marker on
    # the fabricated fresh entry keeps this test focused on the specific
    # gate under test (size / ctime / verify) rather than piggy-backing
    # on the identity gate.
    printf '%s\n' "$cmd" \
      | sed -n "s/.*--notes-template '\([^']*\)'.*/\1/p" \
      > "${STATE_DIR}/marker" || true
    # vzdump exits 0 — the whole point of FG-11 is that exit code alone lies.
    :
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
  local mode="$2"
  shift 2
  : > "$SSH_LOG"
  rm -f "${STATE_DIR}/query_count" "${STATE_DIR}/marker"
  printf '%s\n' "$mode" > "${STATE_DIR}/mode"
  set +e
  OUT="$(PATH="${SHIM_DIR}:${PATH}" SSH_LOG="$SSH_LOG" STATE_DIR="$STATE_DIR" \
    bash -c 'name="$1"; shift; cd "$0" && framework/scripts/backup-now.sh --env dev --pin-out "build/${name}.json" "$@"' \
    "$FIXTURE_REPO" "$name" "$@" 2>&1)"
  RC=$?
  set -e
  PIN_FILE="${FIXTURE_REPO}/build/${name}.json"
}

pin_has_303() {
  # Returns 0 (true) if the pin file has an entry for VMID 303.
  [[ -f "$PIN_FILE" ]] || return 1
  jq -e '.pins["303"] // empty' "$PIN_FILE" >/dev/null 2>&1
}

test_start "PBSV.1" "healthy path: fresh size>0 volid records the pin and exits 0"
run_backup healthy healthy
if [[ "$RC" -eq 0 ]] \
   && grep -Fq 'vzdump 303 --storage pbs-nas' "$SSH_LOG" \
   && pin_has_303 \
   && [[ "$(jq -r '.pins["303"].volid' "$PIN_FILE")" == "pbs-nas:backup/vm/303/fresh" ]]; then
  test_pass "healthy backup landed and pinned"
else
  test_fail "healthy backup path did not record a fresh pin"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PBSV.2" "size-zero PBS entry fails closed and does NOT record a pin"
run_backup zero size-zero
# G4 teeth: pre-fix code does not check size and would exit 0 with a
# size-zero pin recorded. Post-fix must reject.
if [[ "$RC" -ne 0 ]] \
   && ! pin_has_303 \
   && grep -Fq 'reports size 0' <<< "$OUT" \
   && grep -Fq 'Check: PBS datastore free space' <<< "$OUT"; then
  test_pass "size-zero rejected with operator-facing PBS/NFS/disk diagnostic"
else
  test_fail "size-zero not rejected (pre-fix behavior)"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PBSV.3" "stale-ctime PBS entry fails closed on freshness anchor"
run_backup stale stale-ctime
if [[ "$RC" -ne 0 ]] \
   && ! pin_has_303 \
   && grep -Fq 'is not strictly after pre-vzdump anchor' <<< "$OUT" \
   && grep -Fq 'PBS-NFS mount health' <<< "$OUT"; then
  test_pass "stale-ctime rejected with operator-facing PBS-NFS diagnostic"
else
  test_fail "stale-ctime not rejected (pre-fix behavior)"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PBSV.4" "verification-failed entry fails closed on verify-state check"
run_backup verify verify-failed
if [[ "$RC" -ne 0 ]] \
   && ! pin_has_303 \
   && grep -Fq "verification state is 'failed'" <<< "$OUT" \
   && grep -Fq 'PBS verify job status' <<< "$OUT"; then
  test_pass "verify-failed rejected with verify-job diagnostic"
else
  test_fail "verify-failed not rejected"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PBSV.5" "ghost backup (vzdump 0 exit, no new PBS volid) fails closed"
run_backup ghost missing
# The pre-existing pin_count!=1 branch already handled this class; the test
# guarantees regression coverage while we are around the same code path.
if [[ "$RC" -ne 0 ]] \
   && ! pin_has_303 \
   && grep -Fq 'expected exactly one new PBS backup for VMID 303, found 0' <<< "$OUT"; then
  test_pass "ghost backup rejected by volid-diff branch"
else
  test_fail "ghost backup path regressed"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PBSV.6" "missing-ctime PBS entry fails closed on freshness anchor"
run_backup nocti missing-ctime
if [[ "$RC" -ne 0 ]] \
   && ! pin_has_303 \
   && grep -Fq 'missing ctime metadata' <<< "$OUT" \
   && grep -Fq 'PBS content listing integrity' <<< "$OUT"; then
  test_pass "missing-ctime rejected with content-listing diagnostic"
else
  test_fail "missing-ctime not rejected"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

test_start "PBSV.7" "null verification metadata records the pin (unverified is not failed)"
# PBS's verify sweep is asynchronous. Fresh backups often report
# verification: null before PBS gets to them. Treating null as "failed"
# would false-reject valid backups; this test locks in the correct
# behavior (post-review codex-P1).
run_backup nullvf null-verify
if [[ "$RC" -eq 0 ]] \
   && pin_has_303 \
   && [[ "$(jq -r '.pins["303"].volid' "$PIN_FILE")" == "pbs-nas:backup/vm/303/nullvf" ]]; then
  test_pass "null verification metadata treated as absent, pin recorded"
else
  test_fail "null verification metadata mishandled as failure"
  printf 'rc=%s\nout:\n%s\npin:\n%s\n' "$RC" "$OUT" "$(cat "$PIN_FILE" 2>/dev/null)" >&2
fi

runner_summary
