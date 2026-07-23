#!/usr/bin/env bash
# test_safe_apply_park_adopt.sh — Sprint 044 safe-apply park/adopt choreography.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"
# shellcheck source=tests/lib/vdb_park_fixture.sh
source "${REPO_ROOT}/tests/lib/vdb_park_fixture.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
EVENT_LOG="${TMP_DIR}/events.log"
VM_SCOPE="${TMP_DIR}/vm-scope.sh"

setup_fixture() {
  rm -rf "$FIXTURE_REPO" "$SHIM_DIR"
  mkdir -p "${FIXTURE_REPO}/framework/scripts/lib" "${FIXTURE_REPO}/framework/tofu/root" "${FIXTURE_REPO}/site" "${FIXTURE_REPO}/build" "$SHIM_DIR"

  cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
  chmod +x "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"

  cat > "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

vdb_bridge_enabled() {
  grep -Eq '^[[:space:]]*vdb_park_bridge:[[:space:]]*true[[:space:]]*$' site/config.yaml
}

vdb_park_batch() {
  local manifest="$1" status_file="$2"
  mkdir -p "$(dirname "$status_file")"
  if ! vdb_bridge_enabled; then
    jq -n '{version:1, scope:"dev", entries:[]}' > "$status_file"
    return 0
  fi
  printf 'vdb_park_batch %s\n' "$*" >> "${EVENT_LOG}"
  if [[ -n "${STUB_VDB_PARK_EXIT:-}" ]]; then
    return "$STUB_VDB_PARK_EXIT"
  fi
  jq -n --slurpfile manifest "$manifest" '
    {version: 1, scope: "dev", entries: [($manifest[0].entries[0] + {status: "parked"})]}
  ' > "$status_file"
}

vdb_adopt_batch() {
  local status_file="$1"
  shift || true
  if [[ -f "$status_file" ]] && jq -e 'any(.entries[]?; .status == "parked" or .status == "adopted")' "$status_file" >/dev/null; then
    printf 'vdb_adopt_batch %s %s\n' "$status_file" "$*" >> "${EVENT_LOG}"
  fi
  if [[ -n "${STUB_VDB_ADOPT_EXIT:-}" ]]; then
    return "$STUB_VDB_ADOPT_EXIT"
  fi
}

vdb_park_preview_batch() {
  printf 'vdb_park_preview_batch %s\n' "$*" >> "${EVENT_LOG}"
  echo "WOULD park vdb for vault_dev (VMID 303) using fallback pin pbs-nas:backup/vm/303/pin (trust=trusted)"
}
EOF

  cat > "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
converge_incomplete_vm() { return 0; }
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh"

  for script in check-approle-creds.sh check-control-plane-drift.sh; do
    cat > "${FIXTURE_REPO}/framework/scripts/${script}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
    chmod +x "${FIXTURE_REPO}/framework/scripts/${script}"
  done

  cat > "${FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'check-plan-images-present.sh %s\n' "$*" >> "${EVENT_LOG}"
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh"

  cat > "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tofu-wrapper %s\n' "$*" >> "${EVENT_LOG}"
case "${1:-}" in
  plan)
    for arg in "$@"; do
      [[ "$arg" == -out=* ]] && : > "${arg#-out=}"
    done
    ;;
  apply)
    count_file="${EVENT_LOG}.applycount"
    prev="$(cat "$count_file" 2>/dev/null || echo 0)"
    next=$((prev + 1))
    echo "$next" > "$count_file"
    case "$next" in
      1) exit "${STUB_APPLY_EXIT_1:-0}" ;;
      2) exit "${STUB_APPLY_EXIT_2:-0}" ;;
    esac
    ;;
  state)
    [[ "${2:-}" == "list" ]] && exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

  cat > "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-before-start.sh %s\n' "$*" >> "${EVENT_LOG}"
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"

  for script in configure-replication.sh post-deploy.sh configure-backups.sh; do
    cat > "${FIXTURE_REPO}/framework/scripts/${script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${script} %s\n' "\$*" >> "${EVENT_LOG}"
exit 0
EOF
    chmod +x "${FIXTURE_REPO}/framework/scripts/${script}"
  done

  cat > "$VM_SCOPE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  control-plane-modules)
    ;;
  deployable-modules)
    echo "module.vault_dev"
    ;;
  classes)
    cat <<'JSON'
{"vault": {"category": "nix", "control_plane": false}}
JSON
    ;;
  *)
    echo "unexpected vm-scope invocation: $*" >&2
    exit 9
    ;;
esac
EOF
  chmod +x "$VM_SCOPE"

  cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -chdir=* ]] && shift
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  printf '%s\n' "${STUB_PLAN_JSON}"
  exit 0
fi
exit 2
EOF
  chmod +x "${SHIM_DIR}/tofu"

  cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
case "$cmd" in
  *'/cluster/ha/resources --output-format json'*)
    printf 'ssh ha-resources\n' >> "${EVENT_LOG}"
    printf '%s\n' '[]'
    ;;
  *)
    printf '%s\n' '[]'
    ;;
esac
EOF
  chmod +x "${SHIM_DIR}/ssh"

  cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
environments:
  dev:
    vdb_park_bridge: true
proxmox:
  storage_pool: vmstore
vms:
  vault_dev:
    vmid: 303
    backup: true
EOF
  cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF
  cat > "${FIXTURE_REPO}/build/restore-pin-dev.json" <<'EOF'
{
  "version": 1,
  "pins": {
    "303": {
      "volid": "pbs-nas:backup/vm/303/pin",
      "trust": "trusted"
    }
  }
}
EOF

  export PATH="${SHIM_DIR}:${PATH}"
  export VM_SCOPE_SCRIPT="$VM_SCOPE"
  export EVENT_LOG
  export STUB_PLAN_JSON='{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["delete","create"],"before":{"started":true},"after":{"started":true,"disk":[{"interface":"scsi0"},{"interface":"scsi1","size":50}],"cdrom":[{"interface":"ide2"}]}}}]}'
}

setup_real_lib_fixture() {
  vdb_fixture_make
  mkdir -p "${VDB_FIXTURE_REPO}/framework/scripts/lib" "${VDB_FIXTURE_REPO}/framework/tofu/root" "${VDB_FIXTURE_REPO}/build"
  cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" "${VDB_FIXTURE_REPO}/framework/scripts/safe-apply.sh"
  chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/safe-apply.sh"

  cat > "${VDB_FIXTURE_REPO}/framework/scripts/vm-scope.sh" <<'REAL_VM_SCOPE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  control-plane-modules)
    ;;
  deployable-modules)
    echo "module.app_dev"
    ;;
  classes)
    cat <<'JSON'
{
  "app": {"category": "nix", "control_plane": false},
  "app2": {"category": "nix", "control_plane": false},
  "shared_app": {"category": "nix", "control_plane": false},
  "vendor": {"category": "vendor", "control_plane": false}
}
JSON
    ;;
  *)
    echo "unexpected vm-scope invocation: $*" >&2
    exit 9
    ;;
esac
REAL_VM_SCOPE
  chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/vm-scope.sh"

  cat > "${VDB_FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh" <<'REAL_CONVERGE'
#!/usr/bin/env bash
set -euo pipefail
converge_incomplete_vm() { return 0; }
REAL_CONVERGE
  chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh"

  for script in check-approle-creds.sh check-control-plane-drift.sh; do
    cat > "${VDB_FIXTURE_REPO}/framework/scripts/${script}" <<'REAL_ZERO'
#!/usr/bin/env bash
set -euo pipefail
exit 0
REAL_ZERO
    chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/${script}"
  done

  cat > "${VDB_FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh" <<'REAL_CHECK_IMAGES'
#!/usr/bin/env bash
set -euo pipefail
printf 'check-plan-images-present.sh %s\n' "$*" >> "${EVENT_LOG}"
exit 0
REAL_CHECK_IMAGES
  chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh"

  cat > "${VDB_FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh" <<'REAL_TOFU_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf 'tofu-wrapper %s\n' "$*" >> "${EVENT_LOG}"
case "${1:-}" in
  plan)
    for arg in "$@"; do
      [[ "$arg" == -out=* ]] && : > "${arg#-out=}"
    done
    ;;
  apply)
    count_file="${EVENT_LOG}.applycount"
    prev="$(cat "$count_file" 2>/dev/null || echo 0)"
    next=$((prev + 1))
    echo "$next" > "$count_file"
    if [[ "$next" -eq 1 ]]; then
      mkdir -p "${VDB_FIXTURE_STATE}/qm/pve01" "${VDB_FIXTURE_STATE}/status/pve01" "${VDB_FIXTURE_STATE}/zfs/pve01/vmstore/data/vm-101-disk-0/props"
      printf '%s\n' 'scsi1: vmstore:vm-101-disk-0,size=50G,backup=1,replicate=1' > "${VDB_FIXTURE_STATE}/qm/pve01/101.conf"
      printf '%s\n' stopped > "${VDB_FIXTURE_STATE}/status/pve01/101"
      printf '%s\n' fresh-guid-101 > "${VDB_FIXTURE_STATE}/zfs/pve01/vmstore/data/vm-101-disk-0/guid"
      printf '%s\n' 50G > "${VDB_FIXTURE_STATE}/zfs/pve01/vmstore/data/vm-101-disk-0/volsize"
      printf '%s\n' fresh-hash-101 > "${VDB_FIXTURE_STATE}/zfs/pve01/vmstore/data/vm-101-disk-0/sha256"
    fi
    ;;
  state)
    [[ "${2:-}" == "list" ]] && exit 0
    ;;
esac
exit 0
REAL_TOFU_WRAPPER
  chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

  cat > "${VDB_FIXTURE_REPO}/framework/scripts/restore-before-start.sh" <<'REAL_RESTORE'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-before-start.sh %s\n' "$*" >> "${EVENT_LOG}"
exit 0
REAL_RESTORE
  chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/restore-before-start.sh"

  for script in configure-replication.sh post-deploy.sh configure-backups.sh; do
    cat > "${VDB_FIXTURE_REPO}/framework/scripts/${script}" <<REAL_POST
#!/usr/bin/env bash
set -euo pipefail
printf '${script} %s\n' "\$*" >> "\${EVENT_LOG}"
exit 0
REAL_POST
    chmod +x "${VDB_FIXTURE_REPO}/framework/scripts/${script}"
  done

  cat > "${VDB_FIXTURE_SHIMS}/tofu" <<'REAL_TOFU'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -chdir=* ]] && shift
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  printf '%s\n' "${STUB_PLAN_JSON}"
  exit 0
fi
exit 2
REAL_TOFU
  chmod +x "${VDB_FIXTURE_SHIMS}/tofu"

  cat > "${VDB_FIXTURE_REPO}/build/restore-pin-dev.json" <<'REAL_PIN'
{
  "version": 1,
  "pins": {
    "101": {
      "volid": "pbs-nas:backup/vm/101/pin",
      "trust": "trusted"
    }
  }
}
REAL_PIN

  export PATH="${VDB_FIXTURE_SHIMS}:${PATH}"
  export EVENT_LOG="$VDB_EVENT_LOG"
  export REAL_YQ_BIN
  export VDB_FIXTURE_STATE VDB_EVENT_LOG
  export VM_SCOPE_SCRIPT="${VDB_FIXTURE_REPO}/framework/scripts/vm-scope.sh"
  export STUB_PLAN_JSON='{"resource_changes":[{"address":"module.app_dev.module.app.proxmox_virtual_environment_vm.vm","change":{"actions":["delete","create"],"before":{"started":true},"after":{"started":true,"disk":[{"interface":"scsi0"},{"interface":"scsi1","size":50}],"cdrom":[{"interface":"ide2"}]}}}]}'
}

reset_fixture() {
  : > "$EVENT_LOG"
  rm -f "${EVENT_LOG}.applycount"
  rm -f "${FIXTURE_REPO}/build/preboot-restore-dev.json" \
        "${FIXTURE_REPO}/build/preboot-restore-status-dev.json" \
        "${FIXTURE_REPO}/build/vdb-park-status-dev.json"
  unset STUB_VDB_PARK_EXIT STUB_VDB_ADOPT_EXIT STUB_APPLY_EXIT_1 STUB_APPLY_EXIT_2
}

run_safe_apply() {
  set +e
  OUT="$(cd "$FIXTURE_REPO" && framework/scripts/safe-apply.sh "$@" 2>&1)"
  RC=$?
  set -e
}

line_of() {
  local pattern="$1"
  grep -nF "$pattern" "$EVENT_LOG" | head -n1 | cut -d: -f1
}

setup_fixture

test_start "A4.a" "safe-apply parks before Phase 1 and adopts before restore"
reset_fixture
run_safe_apply dev
park_line="$(line_of "vdb_park_batch")"
phase1_line="$(line_of "tofu-wrapper apply -target=module.vault_dev -var=start_vms=false")"
adopt_line="$(line_of "vdb_adopt_batch")"
restore_line="$(line_of "restore-before-start.sh dev")"
repl_line="$(line_of "configure-replication.sh * --park-status")"
if [[ "$RC" -eq 0 ]] &&
   [[ -n "$park_line" && -n "$phase1_line" && "$park_line" -lt "$phase1_line" ]] &&
   [[ -n "$adopt_line" && -n "$restore_line" && "$adopt_line" -lt "$restore_line" ]] &&
   jq -e '.entries[0].data_disk_slot == "scsi1" and .entries[0].data_disk_size_gb == "50" and .entries[0].pin_trust == "trusted"' "${FIXTURE_REPO}/build/preboot-restore-dev.json" >/dev/null &&
   grep -Fq -- "--park-status ${FIXTURE_REPO}/build/vdb-park-status-dev.json" "$EVENT_LOG" &&
   [[ -n "$repl_line" ]]; then
  test_pass "park/adopt ordering and park-status propagation are correct"
else
  test_fail "safe-apply choreography ordering was wrong"
  printf 'rc=%s\nlog:\n%s\nout:\n%s\n' "$RC" "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

test_start "A4.b" "park abort prevents Phase 1 apply"
reset_fixture
export STUB_VDB_PARK_EXIT=42
run_safe_apply dev
if [[ "$RC" -ne 0 ]] &&
   grep -Fq "vdb_park_batch" "$EVENT_LOG" &&
   ! grep -Fq "tofu-wrapper apply" "$EVENT_LOG"; then
  test_pass "park abort stops before any apply"
else
  test_fail "park abort did not stop before apply"
  printf 'rc=%s\nlog:\n%s\nout:\n%s\n' "$RC" "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

test_start "A4.c" "Phase 1 failure adopts in recovery before recovery restore"
reset_fixture
export STUB_APPLY_EXIT_1=7
run_safe_apply dev
recovery_adopt_line="$(grep -nF -- "vdb_adopt_batch ${FIXTURE_REPO}/build/vdb-park-status-dev.json --recovery-mode" "$EVENT_LOG" | head -n1 | cut -d: -f1)"
recovery_restore_line="$(grep -nF -- "restore-before-start.sh dev --manifest ${FIXTURE_REPO}/build/preboot-restore-dev.json --pin-file ${FIXTURE_REPO}/build/restore-pin-dev.json --park-status ${FIXTURE_REPO}/build/vdb-park-status-dev.json --recovery-mode" "$EVENT_LOG" | head -n1 | cut -d: -f1)"
if [[ "$RC" -eq 7 ]] &&
   [[ -n "$recovery_adopt_line" && -n "$recovery_restore_line" && "$recovery_adopt_line" -lt "$recovery_restore_line" ]]; then
  test_pass "recovery adopt precedes recovery restore"
else
  test_fail "recovery adopt ordering was wrong"
  printf 'rc=%s\nlog:\n%s\nout:\n%s\n' "$RC" "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

test_start "A4.c2" "adopt failure continues into restore-before-start fallback"
reset_fixture
export STUB_VDB_ADOPT_EXIT=9
run_safe_apply dev
adopt_line="$(line_of "vdb_adopt_batch")"
restore_line="$(line_of "restore-before-start.sh dev")"
if [[ "$RC" -eq 0 ]] &&
   [[ -n "$adopt_line" && -n "$restore_line" && "$adopt_line" -lt "$restore_line" ]] &&
   grep -Fq "vdb_adopt_batch returned rc=9" <<< "$OUT" &&
   grep -Fq -- "--park-status ${FIXTURE_REPO}/build/vdb-park-status-dev.json" "$EVENT_LOG"; then
  test_pass "adopt failure is delegated to restore/status gate instead of aborting early"
else
  test_fail "adopt failure did not continue to restore fallback"
  printf 'rc=%s\nlog:\n%s\nout:\n%s\n' "$RC" "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

test_start "A4.c3" "real vdb lib adopt failure continues into restore-before-start fallback"
saved_path="$PATH"
saved_event_log="$EVENT_LOG"
saved_vm_scope_script="$VM_SCOPE_SCRIPT"
setup_real_lib_fixture
vdb_fixture_set_vm pve01 101 running $'scsi0: vmstore:vm-101-disk-1,size=4G\nscsi1: vmstore:vm-101-disk-0,size=50G,backup=1,replicate=1'
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-0 guid-data-101 50G
vdb_fixture_create_dataset pve01 vmstore/data/vm-101-disk-1 guid-os-101 4G
touch "${VDB_FIXTURE_STATE}/attach-fail-once-101"
set +e
OUT="$(cd "$VDB_FIXTURE_REPO" && framework/scripts/safe-apply.sh dev 2>&1)"
RC=$?
set -e
real_adopt_line="$(grep -nF -- "app_dev: renaming parked vdb back to vm-101-disk-0" <<< "$OUT" | head -n1 | cut -d: -f1 || true)"
real_restore_line="$(grep -nF -- "restore-before-start.sh dev" "$VDB_EVENT_LOG" | head -n1 | cut -d: -f1 || true)"
if [[ "$RC" -eq 0 ]] &&
   [[ -n "$real_adopt_line" && -n "$real_restore_line" ]] &&
   grep -Fq "vdb_adopt_batch returned rc=1" <<< "$OUT" &&
   grep -Fq "restore-before-start.sh dev --manifest ${VDB_FIXTURE_REPO}/build/preboot-restore-dev.json --pin-file ${VDB_FIXTURE_REPO}/build/restore-pin-dev.json --park-status ${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" "$VDB_EVENT_LOG" &&
   jq -e '.entries[0].status == "adopt-failed"' "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" >/dev/null; then
  test_pass "safe-apply delegates real adopt failure to restore/status fallback"
else
  test_fail "safe-apply real-lib adopt failure did not continue to restore"
  printf 'rc=%s\nout=%s\nevents=\n%s\nstatus=%s\n' "$RC" "$OUT" "$(cat "$VDB_EVENT_LOG")" "$(cat "${VDB_FIXTURE_REPO}/build/vdb-park-status-dev.json" 2>/dev/null || true)" >&2
fi
PATH="$saved_path"
EVENT_LOG="$saved_event_log"
VM_SCOPE_SCRIPT="$saved_vm_scope_script"
export PATH EVENT_LOG VM_SCOPE_SCRIPT

test_start "A4.d" "bridge-disabled path matches pre-sprint event shape"
reset_fixture
cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
vms:
  vault_dev:
    vmid: 303
    backup: true
EOF
run_safe_apply dev
expected_log="${TMP_DIR}/a4d-expected.log"
cat > "$expected_log" <<EOF
tofu-wrapper plan -out=${TMP_DIR}/repo/build-placeholder -no-color
EOF
grep -Ev '^(tofu-wrapper plan|tofu-wrapper state|ssh ha-resources|check-plan-images-present|tofu-wrapper apply|restore-before-start.sh|configure-replication.sh|post-deploy.sh|configure-backups.sh)' "$EVENT_LOG" > "${TMP_DIR}/a4d-extra.log" || true
if [[ "$RC" -eq 0 ]] &&
   ! grep -Fq "vdb_park_batch" "$EVENT_LOG" &&
   ! grep -Fq "vdb_adopt_batch" "$EVENT_LOG" &&
   [[ ! -s "${TMP_DIR}/a4d-extra.log" ]]; then
  test_pass "disabled bridge adds no vdb choreography events"
else
  test_fail "disabled bridge produced unexpected vdb events"
  printf 'rc=%s\nlog:\n%s\nextra:\n%s\nout:\n%s\n' "$RC" "$(cat "$EVENT_LOG")" "$(cat "${TMP_DIR}/a4d-extra.log")" "$OUT" >&2
fi

test_start "A4.e" "dry-run previews park candidates and performs no mutations"
reset_fixture
cat >> "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
environments:
  dev:
    vdb_park_bridge: true
proxmox:
  storage_pool: vmstore
EOF
run_safe_apply dev --dry-run
if [[ "$RC" -eq 0 ]] &&
   grep -Fq "WOULD park vdb for vault_dev" <<< "$OUT" &&
   grep -Fq "vdb_park_preview_batch" "$EVENT_LOG" &&
   ! grep -Fq "vdb_park_batch" "$EVENT_LOG" &&
   ! grep -Fq "vdb_adopt_batch" "$EVENT_LOG" &&
   ! grep -Fq "tofu-wrapper apply" "$EVENT_LOG" &&
   ! grep -Fq "restore-before-start.sh" "$EVENT_LOG"; then
  test_pass "dry-run previews only and mutates nothing"
else
  test_fail "dry-run did not preserve the no-mutation contract"
  printf 'rc=%s\nlog:\n%s\nout:\n%s\n' "$RC" "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

runner_summary
