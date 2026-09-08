#!/usr/bin/env bash
# test_restore_spared_status.sh — Sprint 044 restore-side spared/orphan behavior.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
STATE_DIR="${TMP_DIR}/state"
SSH_LOG="${TMP_DIR}/ssh.log"
RESTORE_LOG="${TMP_DIR}/restore.log"
MANIFEST_FILE="${TMP_DIR}/manifest.json"
PIN_FILE="${TMP_DIR}/pin.json"
STATUS_FILE="${TMP_DIR}/restore-status.json"
PARK_STATUS_FILE="${TMP_DIR}/park-status.json"

setup_fixture() {
  rm -rf "$FIXTURE_REPO" "$SHIM_DIR" "$STATE_DIR"
  mkdir -p \
    "${FIXTURE_REPO}/framework/scripts" \
    "${FIXTURE_REPO}/site" \
    "$SHIM_DIR" \
    "${STATE_DIR}/qm/pve01" \
    "${STATE_DIR}/status/pve01" \
    "${STATE_DIR}/zfs/pve01"

  cp "${REPO_ROOT}/framework/scripts/restore-before-start.sh" "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"
  cp "${REPO_ROOT}/framework/scripts/vm-topology-lib.sh" "${FIXTURE_REPO}/framework/scripts/vm-topology-lib.sh"
  cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
  chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"

  cat > "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-from-pbs.sh %s\n' "$*" >> "${RESTORE_LOG}"
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh"

  cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
proxmox:
  storage_pool: vmstore
storage:
  pool_name: vmstore
EOF

  cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${*: -1}"
clean_cmd="${cmd//\'/}"
state="${RESTORE_SPARED_STATE}"
node="pve01"

case "$clean_cmd" in
  *'/cluster/resources --type vm --output-format json'*)
    python3 - <<'PY'
import glob, json, os
state = os.environ["RESTORE_SPARED_STATE"]
rows = []
for path in sorted(glob.glob(os.path.join(state, "qm", "pve01", "*.conf"))):
    vmid = int(os.path.basename(path).split(".")[0])
    rows.append({"vmid": vmid, "node": "pve01"})
print(json.dumps(rows))
PY
    ;;
  *'qm status '*)
    vmid="$(sed -n 's/.*qm status \([0-9][0-9]*\).*/\1/p' <<< "$clean_cmd")"
    cat "${state}/status/pve01/${vmid}"
    ;;
  'ha-manager status')
    ;;
  'pvesm status 2>/dev/null')
    printf '%s\n' 'pbs-nas active'
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    printf '%s\n' "${STUB_PBS_CONTENT:-[]}"
    ;;
  *'qm config '*)
    vmid="$(sed -n 's/.*qm config \([0-9][0-9]*\).*/\1/p' <<< "$clean_cmd")"
    cat "${state}/qm/pve01/${vmid}.conf"
    ;;
  *'zfs list -H -o name,volsize -r '*)
    parent="$(sed -n 's/.*zfs list -H -o name,volsize -r \([^ ]*\).*/\1/p' <<< "$clean_cmd")"
    base="${state}/zfs/${node}/${parent}"
    if [[ -d "$base" ]]; then
      find "$base" -mindepth 1 -maxdepth 1 -type d | sort | while read -r path; do
        name="${parent}/$(basename "$path")"
        case "$name" in
          */mycofu-park-*-vdb)
            printf '%s\t%s\n' "$name" "$(cat "$path/volsize" 2>/dev/null || echo 50G)"
            ;;
        esac
      done
    fi
    ;;
  *'zfs list -H -o name -r '*)
    ;;
  *'zfs list -H -o name '*)
    dataset="$(sed -n 's/.*zfs list -H -o name \([^ >]*\).*/\1/p' <<< "$clean_cmd")"
    if [[ -f "${state}/zfs-exists-fail-${node}" ]]; then
      exit 8
    fi
    if [[ -d "${state}/zfs/${node}/${dataset}" ]]; then
      [[ "$clean_cmd" == *">/dev/null"* ]] || printf '%s\n' "$dataset"
      exit 0
    fi
    exit 1
    ;;
  *'zfs get -H -o value guid '*)
    dataset="$(sed -n 's/.*zfs get -H -o value guid \([^ ]*\).*/\1/p' <<< "$clean_cmd")"
    cat "${state}/zfs/${node}/${dataset}/guid"
    ;;
  *'zfs get -H -o property,value all '*)
    dataset="$(sed -n 's/.*zfs get -H -o property,value all \([^ ]*\).*/\1/p' <<< "$clean_cmd")"
    prop_dir="${state}/zfs/${node}/${dataset}/props"
    if [[ -d "$prop_dir" ]]; then
      for prop in "$prop_dir"/*; do
        [[ -f "$prop" ]] || continue
        printf '%s\t%s\n' "$(basename "$prop")" "$(cat "$prop")"
      done
    fi
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 98
    ;;
esac
EOF
  chmod +x "${SHIM_DIR}/ssh"

  export PATH="${SHIM_DIR}:${PATH}"
  export RESTORE_LOG RESTORE_SPARED_STATE="$STATE_DIR"
}

reset_state() {
  rm -rf "${STATE_DIR}/qm/pve01" "${STATE_DIR}/status/pve01" "${STATE_DIR}/zfs/pve01"
  mkdir -p "${STATE_DIR}/qm/pve01" "${STATE_DIR}/status/pve01" "${STATE_DIR}/zfs/pve01"
  : > "$SSH_LOG"
  : > "$RESTORE_LOG"
  rm -f "$MANIFEST_FILE" "$PIN_FILE" "$STATUS_FILE" "$PARK_STATUS_FILE"
  rm -f "${STATE_DIR}"/zfs-exists-fail-*
  unset STUB_PBS_CONTENT FIRST_DEPLOY_ALLOW_VMIDS
}

dataset_path() {
  printf '%s/zfs/pve01/%s\n' "$STATE_DIR" "$1"
}

create_dataset() {
  local dataset="$1" size="${2:-50G}"
  local guid="${3:-guid-$(basename "$dataset")}"
  mkdir -p "$(dataset_path "$dataset")/props"
  printf '%s\n' "$size" > "$(dataset_path "$dataset")/volsize"
  printf '%s\n' "$guid" > "$(dataset_path "$dataset")/guid"
}

set_prop() {
  local dataset="$1" prop="$2" value="$3"
  mkdir -p "$(dataset_path "$dataset")/props"
  printf '%s\n' "$value" > "$(dataset_path "$dataset")/props/${prop}"
}

set_vm() {
  local vmid="$1" status="$2" config="$3"
  printf '%s\n' "$status" > "${STATE_DIR}/status/pve01/${vmid}"
  printf '%s\n' "$config" > "${STATE_DIR}/qm/pve01/${vmid}.conf"
}

write_manifest() {
  local entries_json="$1"
  printf '{"version":1,"entries":%s}\n' "$entries_json" > "$MANIFEST_FILE"
}

entry_json() {
  local label="$1" vmid="$2"
  jq -n \
    --arg label "$label" \
    --argjson vmid "$vmid" \
    '{label: $label, module: ("module." + $label), vmid: $vmid, env: "dev", kind: "infrastructure", reason: "replace", expected_disks: ["scsi0", "scsi1"]}'
}

write_pin_file() {
  local vmid pin first=1
  {
    printf '{"version":1,"pins":{'
    for vmid in "$@"; do
      [[ "$first" -eq 0 ]] && printf ','
      first=0
      pin="pbs-nas:backup/vm/${vmid}/2026-07-05T00:00:00Z"
      printf '"%s":"%s"' "$vmid" "$pin"
    done
    printf '}}\n'
  } > "$PIN_FILE"
}

write_park_status() {
  local entries_json="$1"
  ENTRIES_JSON="$entries_json" python3 - <<'PY' > "$PARK_STATUS_FILE"
import json
import os

entries = json.loads(os.environ["ENTRIES_JSON"])
for entry in entries:
    entry.setdefault("run_id", "test-run")
print(json.dumps({"version": 1, "scope": "dev", "generated_at": "2026-07-05T00:00:00Z", "run_id": "test-run", "entries": entries}))
PY
}

park_entry_json() {
  local vmid="$1" status="$2"
  jq -n \
    --argjson vmid "$vmid" \
    --arg status "$status" \
    --arg pin "pbs-nas:backup/vm/${vmid}/2026-07-05T00:00:00Z" \
    --arg guid "guid-vm-${vmid}-disk-0" \
    '{label: ("vm" + ($vmid|tostring)), vmid: $vmid, env: "dev", status: $status, node: "pve01", storage: "vmstore", dataset_parent: "vmstore/data", volname: ("vm-" + ($vmid|tostring) + "-disk-0"), slot: "scsi1", drive_options: "backup=1,replicate=1", guid: $guid, pin: $pin}'
}

run_restore() {
  local use_park_status="${1:-yes}"
  local output

  set +e
  if [[ "$use_park_status" == "yes" ]]; then
    output="$(
      cd "$FIXTURE_REPO" &&
      framework/scripts/restore-before-start.sh dev \
        --manifest "$MANIFEST_FILE" \
        --pin-file "$PIN_FILE" \
        --status-file "$STATUS_FILE" \
        --park-status "$PARK_STATUS_FILE" 2>&1
    )"
  else
    output="$(
      cd "$FIXTURE_REPO" &&
      framework/scripts/restore-before-start.sh dev \
        --manifest "$MANIFEST_FILE" \
        --pin-file "$PIN_FILE" \
        --status-file "$STATUS_FILE" 2>&1
    )"
  fi
  RC=$?
  set -e
  OUT="$output"
}

setup_fixture

test_start "A3.a/e" "adopted park-status records spared and does not invoke PBS restore"
reset_state
set_vm 303 stopped $'scsi0: vmstore:vm-303-disk-1,size=10G\nscsi1: vmstore:vm-303-disk-0,backup=1,replicate=1'
create_dataset vmstore/data/vm-303-disk-0 50G
write_manifest "[$(entry_json vault_dev 303)]"
write_pin_file 303
write_park_status "[$(park_entry_json 303 adopted)]"
run_restore yes
if [[ "$RC" -eq 0 ]] &&
   jq -e '.entries[] | select(.vmid == 303 and .status == "spared" and .pin == "pbs-nas:backup/vm/303/2026-07-05T00:00:00Z")' "$STATUS_FILE" >/dev/null &&
   [[ ! -s "$RESTORE_LOG" ]]; then
  test_pass "spared status is success and restore-from-pbs is skipped"
else
  test_fail "adopted park-status did not produce spared success"
  printf 'rc=%s\nout=%s\nrestore=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$RESTORE_LOG")" "$(cat "$STATUS_FILE" 2>/dev/null || true)" >&2
fi

test_start "A3.b" "adopt-failed with retained park falls through to pinned restore"
reset_state
set_vm 303 stopped $'scsi0: vmstore:vm-303-disk-1,size=10G\nscsi1: vmstore:vm-303-disk-0,backup=1,replicate=1'
create_dataset vmstore/data/vm-303-disk-0 50G
create_dataset vmstore/data/mycofu-park-303-vdb 50G
set_prop vmstore/data/mycofu-park-303-vdb mycofu:pin-volid pbs-nas:backup/vm/303/2026-07-05T00:00:00Z
write_manifest "[$(entry_json vault_dev 303)]"
write_pin_file 303
write_park_status "[$(park_entry_json 303 adopt-failed)]"
run_restore yes
if [[ "$RC" -eq 0 ]] &&
   grep -Fq -- "--target 303 --force --backup-id pbs-nas:backup/vm/303/2026-07-05T00:00:00Z --leave-stopped" "$RESTORE_LOG" &&
   jq -e '.entries[] | select(.vmid == 303 and .status == "restored")' "$STATUS_FILE" >/dev/null; then
  test_pass "adopt-failed routes to pinned PBS fallback"
else
  test_fail "adopt-failed did not fall through to pinned restore"
  printf 'rc=%s\nout=%s\nrestore=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$RESTORE_LOG")" "$(cat "$STATUS_FILE" 2>/dev/null || true)" >&2
fi

test_start "A3.b2" "adopt-cleanup-failed survives normal re-init and refuses PBS restore"
reset_state
set_vm 303 stopped $'scsi0: vmstore:vm-303-disk-1,size=10G\nscsi1: vmstore:vm-303-disk-0,backup=1,replicate=1'
create_dataset vmstore/data/vm-303-disk-0 50G
write_manifest "[$(entry_json vault_dev 303)]"
write_pin_file 303
write_park_status "[$(park_entry_json 303 adopt-cleanup-failed)]"
(
  cd "$FIXTURE_REPO"
  # shellcheck source=/dev/null
  source framework/scripts/vdb-park-lib.sh
  vdb_park_status_init "$PARK_STATUS_FILE" dev
)
if ! jq -e '.entries[] | select(.vmid == 303 and .status == "adopt-cleanup-failed")' "$PARK_STATUS_FILE" >/dev/null; then
  test_fail "normal status init pruned adopt-cleanup-failed"
  printf 'park_status=%s\n' "$(cat "$PARK_STATUS_FILE" 2>/dev/null || true)" >&2
else
  run_restore yes
  if [[ "$RC" -eq 1 ]] &&
   [[ ! -s "$RESTORE_LOG" ]] &&
   jq -e '.entries[] | select(.vmid == 303 and .status == "failed" and .reason == "adopt-cleanup-failed")' "$STATUS_FILE" >/dev/null &&
   grep -Fq "adopt cleanup failed" <<< "$OUT" &&
   grep -Fq "parked-vdb.sh inspect 303" <<< "$OUT" &&
   grep -Fq "restore-before-start.sh dev --manifest ${MANIFEST_FILE} --park-status ${PARK_STATUS_FILE} --recovery-mode" <<< "$OUT"; then
    test_pass "cleanup-failed status remains sticky and blocks restore over uncertain freshest data"
  else
    test_fail "adopt-cleanup-failed did not fail closed"
    printf 'rc=%s\nout=%s\nrestore=%s\nstatus=%s\npark_status=%s\n' "$RC" "$OUT" "$(cat "$RESTORE_LOG")" "$(cat "$STATUS_FILE" 2>/dev/null || true)" "$(cat "$PARK_STATUS_FILE" 2>/dev/null || true)" >&2
  fi
fi

test_start "A3.c" "adopted claim without the recorded slot falls through to pinned restore"
reset_state
set_vm 303 stopped $'scsi0: vmstore:vm-303-disk-1,size=10G\nscsi1: vmstore:vm-303-disk-0,backup=1,replicate=1'
create_dataset vmstore/data/vm-303-disk-0 50G
write_manifest "[$(entry_json vault_dev 303)]"
write_pin_file 303
write_park_status "[$(park_entry_json 303 adopted | jq '.slot = "scsi2"')]"
run_restore yes
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "not attached at scsi2" <<< "$OUT" &&
   grep -Fq -- "--target 303 --force --backup-id pbs-nas:backup/vm/303/2026-07-05T00:00:00Z --leave-stopped" "$RESTORE_LOG" &&
   jq -e '.entries[] | select(.vmid == 303 and .status == "restored")' "$STATUS_FILE" >/dev/null; then
  test_pass "unverified adopted claim is not trusted"
else
  test_fail "unverified adopted claim did not fall back to restore"
  printf 'rc=%s\nout=%s\nrestore=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$RESTORE_LOG")" "$(cat "$STATUS_FILE" 2>/dev/null || true)" >&2
fi

test_start "A3.c2" "stale adopted park-status is not spared evidence"
reset_state
set_vm 303 stopped $'scsi0: vmstore:vm-303-disk-1,size=10G\nscsi1: vmstore:vm-303-disk-0,backup=1,replicate=1'
create_dataset vmstore/data/vm-303-disk-0 50G
write_manifest "[$(entry_json vault_dev 303)]"
write_pin_file 303
stale_entry="$(park_entry_json 303 adopted | jq '.run_id = "old-run"')"
printf '{"version":1,"scope":"dev","generated_at":"2026-07-05T00:00:00Z","run_id":"current-run","entries":[%s]}\n' "$stale_entry" > "$PARK_STATUS_FILE"
run_restore yes
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "not current-run evidence" <<< "$OUT" &&
   grep -Fq -- "--target 303 --force --backup-id pbs-nas:backup/vm/303/2026-07-05T00:00:00Z --leave-stopped" "$RESTORE_LOG" &&
   jq -e '.entries[] | select(.vmid == 303 and .status == "restored")' "$STATUS_FILE" >/dev/null &&
   ! jq -e '.entries[] | select(.vmid == 303 and .status == "spared")' "$STATUS_FILE" >/dev/null; then
  test_pass "stale adopted evidence falls through to pinned restore"
else
  test_fail "stale adopted evidence produced spared or skipped restore"
  printf 'rc=%s\nout=%s\nrestore=%s\nstatus=%s\npark_status=%s\n' "$RC" "$OUT" "$(cat "$RESTORE_LOG")" "$(cat "$STATUS_FILE" 2>/dev/null || true)" "$(cat "$PARK_STATUS_FILE")" >&2
fi

test_start "A3.c3" "adopted canonical zvol query failure fails closed"
reset_state
set_vm 303 stopped $'scsi0: vmstore:vm-303-disk-1,size=10G\nscsi1: vmstore:vm-303-disk-0,backup=1,replicate=1'
create_dataset vmstore/data/vm-303-disk-0 50G
touch "${STATE_DIR}/zfs-exists-fail-pve01"
write_manifest "[$(entry_json vault_dev 303)]"
write_pin_file 303
write_park_status "[$(park_entry_json 303 adopted)]"
run_restore yes
if [[ "$RC" -eq 1 ]] &&
   [[ ! -s "$RESTORE_LOG" ]] &&
   jq -e '.entries[] | select(.vmid == 303 and .status == "failed" and .reason == "adopted-zvol-verification-failed")' "$STATUS_FILE" >/dev/null &&
   grep -Fq "could not verify adopted vdb" <<< "$OUT"; then
  test_pass "zfs query failure blocks PBS restore over possibly adopted vdb"
else
  test_fail "zfs query failure fell through to restore"
  printf 'rc=%s\nout=%s\nrestore=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$RESTORE_LOG")" "$(cat "$STATUS_FILE" 2>/dev/null || true)" >&2
fi

test_start "A3.d" "first-deploy without park-status preserves empty-vdb behavior"
reset_state
set_vm 303 stopped $'scsi0: vmstore:vm-303-disk-1,size=10G\nscsi1: vmstore:vm-303-disk-0,backup=1,replicate=1'
write_manifest "[$(entry_json vault_dev 303)]"
printf '{"version":1,"pins":{}}\n' > "$PIN_FILE"
export FIRST_DEPLOY_ALLOW_VMIDS=303
run_restore no
generated_at="$(jq -r '.generated_at' "$STATUS_FILE")"
expected_status="${TMP_DIR}/expected-first-deploy-status.json"
jq -n \
  --arg generated_at "$generated_at" \
  '{version: 1, scope: "dev", generated_at: $generated_at, recovery_mode: false, entries: [{label: "vault_dev", vmid: 303, env: "dev", status: "first-deploy-empty", reason: "replace", message: "no PBS backup found; first-deploy approval present", pin: null}]}' \
  > "$expected_status"
if [[ "$RC" -eq 0 ]] &&
   cmp -s "$STATUS_FILE" "$expected_status" &&
   [[ ! -s "$RESTORE_LOG" ]]; then
  test_pass "first-deploy empty-vdb status remains byte-identical to the control shape"
else
  test_fail "first-deploy empty-vdb behavior changed unexpectedly"
  printf 'rc=%s\nout=%s\nstatus=%s\nexpected=%s\nrestore=%s\n' "$RC" "$OUT" "$(cat "$STATUS_FILE" 2>/dev/null || true)" "$(cat "$expected_status")" "$(cat "$RESTORE_LOG")" >&2
fi

test_start "A3.e" "mixed spared plus incomplete exits rc=2"
reset_state
set_vm 303 stopped $'scsi0: vmstore:vm-303-disk-1,size=10G\nscsi1: vmstore:vm-303-disk-0,backup=1,replicate=1'
set_vm 304 stopped 'scsi0: vmstore:vm-304-disk-1,size=10G'
create_dataset vmstore/data/vm-303-disk-0 50G
write_manifest "[$(entry_json vault_dev 303),$(entry_json influxdb_dev 304)]"
write_pin_file 303 304
write_park_status "[$(park_entry_json 303 adopted)]"
run_restore yes
if [[ "$RC" -eq 2 ]] &&
   jq -e '.entries[] | select(.vmid == 303 and .status == "spared")' "$STATUS_FILE" >/dev/null &&
   jq -e '.entries[] | select(.vmid == 304 and .status == "incomplete")' "$STATUS_FILE" >/dev/null; then
  test_pass "spared is success while incomplete still drives rc=2"
else
  test_fail "mixed spared/incomplete batch did not preserve rc=2 protocol"
  printf 'rc=%s\nout=%s\nstatus=%s\nrestore=%s\n' "$RC" "$OUT" "$(cat "$STATUS_FILE" 2>/dev/null || true)" "$(cat "$RESTORE_LOG")" >&2
fi

test_start "A3.f" "orphaned park refuses restore with sanctioned remediation only"
reset_state
set_vm 303 stopped $'scsi0: vmstore:vm-303-disk-1,size=10G\nscsi1: vmstore:vm-303-disk-0,backup=1,replicate=1'
create_dataset vmstore/data/mycofu-park-303-vdb 50G
set_prop vmstore/data/mycofu-park-303-vdb mycofu:pin-volid pbs-nas:backup/vm/303/orphan-pin
write_manifest "[$(entry_json vault_dev 303)]"
write_pin_file 303
run_restore no
if [[ "$RC" -eq 1 ]] &&
   [[ ! -s "$RESTORE_LOG" ]] &&
   jq -e '.entries[] | select(.vmid == 303 and .status == "failed" and .reason == "orphaned-park-present")' "$STATUS_FILE" >/dev/null &&
   grep -Fq "parked-vdb.sh inspect 303" <<< "$OUT" &&
   grep -Fq "restore-before-start.sh dev --manifest ${MANIFEST_FILE} --park-status build/vdb-park-status-dev.json --recovery-mode" <<< "$OUT" &&
   grep -Fq "parked-vdb.sh release 303" <<< "$OUT" &&
   grep -Fq "Accept loss of all writes newer than pin pbs-nas:backup/vm/303/orphan-pin" <<< "$OUT" &&
   ! grep -Eq '(^|[[:space:]])(zfs|qm)[[:space:]]' <<< "$OUT"; then
  test_pass "orphaned park fails closed with only sanctioned commands"
else
  test_fail "orphaned park refusal did not satisfy G7"
  printf 'rc=%s\nout=%s\nrestore=%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$RESTORE_LOG")" "$(cat "$STATUS_FILE" 2>/dev/null || true)" >&2
fi

runner_summary
