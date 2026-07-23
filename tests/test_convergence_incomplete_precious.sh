#!/usr/bin/env bash
# test_convergence_incomplete_precious.sh — shared incomplete-VM convergence routing.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

make_safe_apply_fixture() {
  SAFE_REPO="${TMP_DIR}/safe-repo"
  SAFE_SHIMS="${TMP_DIR}/safe-shims"
  SAFE_LOG="${TMP_DIR}/safe.log"
  SAFE_SCOPE="${TMP_DIR}/safe-vm-scope.sh"
  rm -rf "$SAFE_REPO" "$SAFE_SHIMS"
  mkdir -p "${SAFE_REPO}/framework/scripts/lib" "${SAFE_REPO}/framework/tofu/root" "${SAFE_REPO}/site" "$SAFE_SHIMS"
  cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" "${SAFE_REPO}/framework/scripts/safe-apply.sh"
  cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${SAFE_REPO}/framework/scripts/vdb-park-lib.sh"
  chmod +x "${SAFE_REPO}/framework/scripts/safe-apply.sh"

  cat > "${SAFE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
converge_incomplete_vm() {
  printf 'converge %s\n' "$*" >> "${SAFE_LOG}"
  return "${STUB_CONVERGE_EXIT:-0}"
}
EOF
  chmod +x "${SAFE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh"

  for script in check-approle-creds.sh check-control-plane-drift.sh check-plan-images-present.sh configure-replication.sh post-deploy.sh configure-backups.sh; do
    cat > "${SAFE_REPO}/framework/scripts/${script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${script} %s\n' "\$*" >> "${SAFE_LOG}"
exit 0
EOF
    chmod +x "${SAFE_REPO}/framework/scripts/${script}"
  done

  cat > "${SAFE_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tofu-wrapper %s\n' "$*" >> "${SAFE_LOG}"
case "${1:-}" in
  plan)
    for arg in "$@"; do
      [[ "$arg" == -out=* ]] && : > "${arg#-out=}"
    done
    ;;
  apply)
    APPLY_NUM_FILE="${SAFE_LOG}.applycount"
    PREV="$(cat "${APPLY_NUM_FILE}" 2>/dev/null || echo 0)"
    NEXT=$((PREV + 1))
    echo "$NEXT" > "${APPLY_NUM_FILE}"
    case "$NEXT" in
      1) exit "${STUB_APPLY_EXIT_1:-0}" ;;
      2) exit "${STUB_APPLY_EXIT_2:-0}" ;;
      *) exit 0 ;;
    esac
    ;;
  state)
    [[ "${2:-}" == "list" ]] && exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${SAFE_REPO}/framework/scripts/tofu-wrapper.sh"

  cat > "${SAFE_REPO}/framework/scripts/restore-before-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-before-start.sh %s\n' "$*" >> "${SAFE_LOG}"
mkdir -p build
if [[ "${STUB_MULTI_RECOVERY_STATUS:-0}" == "1" ]]; then
  cat > build/preboot-restore-status-dev.json <<'JSON'
{"version":1,"scope":"dev","entries":[{"label":"vault_dev","vmid":303,"status":"incomplete","reason":"replace","message":"missing scsi0"},{"label":"influxdb_dev","vmid":305,"status":"not-created-yet","reason":"replace","message":"VM 305 from module.influxdb_dev not found in cluster"}]}
JSON
else
  cat > build/preboot-restore-status-dev.json <<'JSON'
{"version":1,"scope":"dev","entries":[{"label":"vault_dev","vmid":303,"status":"incomplete","reason":"replace","message":"missing scsi0"}]}
JSON
fi
exit 2
EOF
  chmod +x "${SAFE_REPO}/framework/scripts/restore-before-start.sh"

  cat > "${SAFE_REPO}/framework/scripts/list-backup-backed-vmids.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${STUB_NON_PRECIOUS:-0}" == "1" ]]; then
  exit 0
fi
printf '303\tvault_dev\tdev\n'
EOF
  chmod +x "${SAFE_REPO}/framework/scripts/list-backup-backed-vmids.sh"

  cat > "$SAFE_SCOPE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  control-plane-modules) ;;
  deployable-modules)
    echo "module.vault_dev"
    if [[ "${STUB_MULTI_TARGETS:-0}" == "1" ]]; then
      echo "module.influxdb_dev"
    fi
    ;;
  classes) echo '{"vault":{"category":"nix"}}' ;;
  *) echo "unexpected vm-scope invocation: $*" >&2; exit 9 ;;
esac
EOF
  chmod +x "$SAFE_SCOPE"

  cat > "${SAFE_SHIMS}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -chdir=* ]] && shift
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  cat <<'JSON'
{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"after":{"disk":[{"interface":"scsi0"},{"interface":"scsi1"}],"initialization":[{"type":"nocloud"}]}}}]}
JSON
  exit 0
fi
exit 2
EOF
  chmod +x "${SAFE_SHIMS}/tofu"

  cat > "${SAFE_SHIMS}/ssh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
  chmod +x "${SAFE_SHIMS}/ssh"

  cat > "${SAFE_SHIMS}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-o=json" ]]; then
  echo '{"nodes":[{"name":"pve01","mgmt_ip":"127.0.0.1"}],"vms":{"vault_dev":{"vmid":303,"backup":true}}}'
  exit 0
fi
echo "127.0.0.1"
EOF
  chmod +x "${SAFE_SHIMS}/yq"

  cat > "${SAFE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
vms:
  vault_dev:
    vmid: 303
    backup: true
EOF
  mkdir -p "${SAFE_REPO}/build"
  cat > "${SAFE_REPO}/build/restore-pin-dev.json" <<'EOF'
{"version":1,"pins":{"303":"pbs-nas:backup/vm/303/2026-06-26T02:27:40Z"}}
EOF
  : > "$SAFE_LOG"
  rm -f "${SAFE_LOG}.applycount"
}

run_safe_apply_fixture() {
  set +e
  OUT="$(PATH="${SAFE_SHIMS}:${PATH}" VM_SCOPE_SCRIPT="$SAFE_SCOPE" SAFE_LOG="$SAFE_LOG" \
    STUB_NON_PRECIOUS="${STUB_NON_PRECIOUS:-0}" STUB_CONVERGE_EXIT="${STUB_CONVERGE_EXIT:-0}" \
    STUB_MULTI_RECOVERY_STATUS="${STUB_MULTI_RECOVERY_STATUS:-0}" STUB_MULTI_TARGETS="${STUB_MULTI_TARGETS:-0}" \
    STUB_APPLY_EXIT_1="${STUB_APPLY_EXIT_1:-0}" STUB_APPLY_EXIT_2="${STUB_APPLY_EXIT_2:-0}" \
    bash -c 'cd "$0" && framework/scripts/safe-apply.sh dev' "$SAFE_REPO" 2>&1)"
  RC=$?
  set -e
}

make_gate_fixture() {
  GATE_REPO="${TMP_DIR}/gate-repo"
  GATE_LOG="${TMP_DIR}/gate.log"
  rm -rf "$GATE_REPO"
  mkdir -p "${GATE_REPO}/framework/scripts/lib" "${GATE_REPO}/build"
  cp "${REPO_ROOT}/framework/scripts/pre-deploy-vm-completeness-gate.sh" "${GATE_REPO}/framework/scripts/pre-deploy-vm-completeness-gate.sh"
  chmod +x "${GATE_REPO}/framework/scripts/pre-deploy-vm-completeness-gate.sh"

  cat > "${GATE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
converge_incomplete_vm() {
  printf 'converge %s\n' "$*" >> "${GATE_LOG}"
  return "${STUB_GATE_CONVERGE_EXIT:-0}"
}
EOF
  chmod +x "${GATE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh"

  cat > "${GATE_REPO}/framework/scripts/list-backup-backed-vmids.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '303\tvault_dev\tdev\n'
EOF
  chmod +x "${GATE_REPO}/framework/scripts/list-backup-backed-vmids.sh"

  cat > "${GATE_REPO}/framework/scripts/vm-is-complete.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${STUB_VM_COMPLETE_OUTPUT:-}" ]]; then
  echo "${STUB_VM_COMPLETE_OUTPUT}" >&2
fi
exit "${STUB_VM_COMPLETE_EXIT:-1}"
EOF
  chmod +x "${GATE_REPO}/framework/scripts/vm-is-complete.sh"

  cat > "${GATE_REPO}/build/repair-pin-dev.json" <<'EOF'
{"version":1,"pins":{"303":"pbs-nas:backup/vm/303/2026-06-26T02:27:40Z"}}
EOF
  : > "$GATE_LOG"
}

run_gate_fixture() {
  set +e
  OUT="$(GATE_LOG="$GATE_LOG" STUB_GATE_CONVERGE_EXIT="${STUB_GATE_CONVERGE_EXIT:-0}" STUB_VM_COMPLETE_EXIT="${STUB_VM_COMPLETE_EXIT:-2}" STUB_VM_COMPLETE_OUTPUT="${STUB_VM_COMPLETE_OUTPUT:-}" \
    bash -c 'cd "$0" && framework/scripts/pre-deploy-vm-completeness-gate.sh --env dev --repair-pin build/repair-pin-dev.json' "$GATE_REPO" 2>&1)"
  RC=$?
  set -e
}

make_real_converge_fixture() {
  REAL_REPO="${TMP_DIR}/real-converge-repo"
  REAL_SHIMS="${TMP_DIR}/real-converge-shims"
  REAL_LOG="${TMP_DIR}/real-converge.log"
  rm -rf "$REAL_REPO" "$REAL_SHIMS"
  mkdir -p "${REAL_REPO}/framework/scripts/lib" "${REAL_REPO}/site" "${REAL_REPO}/build" "$REAL_SHIMS"
  cp "${REPO_ROOT}/framework/scripts/lib/converge-incomplete-vm.sh" "${REAL_REPO}/framework/scripts/lib/converge-incomplete-vm.sh"
  cp "${REPO_ROOT}/framework/scripts/vm-topology-lib.sh" "${REAL_REPO}/framework/scripts/vm-topology-lib.sh"

  cat > "${REAL_REPO}/framework/scripts/vm-scope.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "classes" && "${2:-}" == "--format" && "${3:-}" == "json" ]]; then
  echo '{"vault":{"category":"nix"}}'
  exit 0
fi
echo "unexpected vm-scope invocation: $*" >&2
exit 9
EOF
  chmod +x "${REAL_REPO}/framework/scripts/vm-scope.sh"

  for script in backup-now.sh restore-before-start.sh vm-is-complete.sh; do
    cat > "${REAL_REPO}/framework/scripts/${script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${script} %s\n' "\$*" >> "${REAL_LOG}"
exit 0
EOF
    chmod +x "${REAL_REPO}/framework/scripts/${script}"
  done

  cat > "${REAL_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tofu-wrapper.sh %s\n' "$*" >> "${REAL_LOG}"
case "${1:-}" in
  plan)
    for arg in "$@"; do
      [[ "$arg" == -out=* ]] && : > "${arg#-out=}"
    done
    ;;
esac
exit 0
EOF
  chmod +x "${REAL_REPO}/framework/scripts/tofu-wrapper.sh"

  cat > "${REAL_REPO}/framework/scripts/check-plan-images-present.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'check-plan-images-present.sh %s\n' "$*" >> "${REAL_LOG}"
exit "${STUB_IMAGE_CHECK_EXIT:-0}"
EOF
  chmod +x "${REAL_REPO}/framework/scripts/check-plan-images-present.sh"

  cat > "${REAL_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
vms:
  vault_dev:
    vmid: 303
    backup: true
EOF
  cat > "${REAL_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  cat > "${REAL_SHIMS}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-o=json" ]]; then
  case "${4:-${3:-}}" in
    *config.yaml)
      echo '{"nodes":[{"name":"pve01","mgmt_ip":"127.0.0.1"}],"vms":{"vault_dev":{"vmid":303,"backup":true}}}'
      ;;
    *applications.yaml)
      echo '{"applications":{}}'
      ;;
    *)
      echo "unexpected yq json file: $*" >&2
      exit 9
      ;;
  esac
  exit 0
fi
echo "unexpected yq invocation: $*" >&2
exit 9
EOF
  chmod +x "${REAL_SHIMS}/yq"

  cat > "${REAL_SHIMS}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -chdir=* ]] && shift
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  cat <<'JSON'
{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"],"after":{"disk":[{"file_id":"local:iso/vault-aa000001.img"}]}}}]}
JSON
  exit 0
fi
echo "unexpected tofu invocation: $*" >&2
exit 9
EOF
  chmod +x "${REAL_SHIMS}/tofu"
  : > "$REAL_LOG"
}

run_real_converge_fixture() {
  set +e
  OUT="$(PATH="${REAL_SHIMS}:${PATH}" REAL_LOG="$REAL_LOG" STUB_IMAGE_CHECK_EXIT="${STUB_IMAGE_CHECK_EXIT:-0}" \
    bash -c 'cd "$0" && source framework/scripts/lib/converge-incomplete-vm.sh && converge_incomplete_vm dev 303 "pbs-nas:backup/vm/303/2026-06-26T02:27:40Z"' "$REAL_REPO" 2>&1)"
  RC=$?
  set -e
}

test_start "CIP.1" "safe-apply rc=2 path uses restore-pin-dev.json and shared routine"
make_safe_apply_fixture
unset STUB_NON_PRECIOUS STUB_CONVERGE_EXIT
run_safe_apply_fixture
if [[ "$RC" -eq 0 ]] &&
   grep -Fq 'converge dev 303 pbs-nas:backup/vm/303/2026-06-26T02:27:40Z' "$SAFE_LOG" &&
   grep -Fq 'start_vms=true' "$SAFE_LOG"; then
  test_pass "safe-apply converges precious incomplete VM and continues"
else
  test_fail "safe-apply did not invoke shared convergence from restore pin"
  printf 'rc=%s\nout:\n%s\nlog:\n%s\n' "$RC" "$OUT" "$(cat "$SAFE_LOG")" >&2
fi

test_start "CIP.2" "safe-apply refuses non-precious incomplete VM without convergence"
make_safe_apply_fixture
export STUB_NON_PRECIOUS=1
run_safe_apply_fixture
if [[ "$RC" -eq 2 ]] &&
   ! grep -q '^converge ' "$SAFE_LOG" &&
   grep -Fq 'non-precious VM needs full recreate' <<< "$OUT"; then
  test_pass "non-precious rc=2 refuses without convergence"
else
  test_fail "non-precious rc=2 routing changed"
  printf 'rc=%s\nout:\n%s\nlog:\n%s\n' "$RC" "$OUT" "$(cat "$SAFE_LOG")" >&2
fi
unset STUB_NON_PRECIOUS

test_start "CIP.3" "deploy pre-gate uses repair-pin-dev.json and shared routine"
make_gate_fixture
unset STUB_GATE_CONVERGE_EXIT STUB_VM_COMPLETE_EXIT
run_gate_fixture
if [[ "$RC" -eq 0 ]] &&
   grep -Fq 'INCOMPLETE: vault_dev (VMID 303)' <<< "$OUT" &&
   grep -Fq 'CONVERGED: vault_dev (VMID 303)' <<< "$OUT" &&
   grep -Fq 'converge dev 303 pbs-nas:backup/vm/303/2026-06-26T02:27:40Z' "$GATE_LOG"; then
  test_pass "pre-deploy gate converges from repair pin"
else
  test_fail "pre-deploy gate did not use repair-pin convergence"
  printf 'rc=%s\nout:\n%s\nlog:\n%s\n' "$RC" "$OUT" "$(cat "$GATE_LOG")" >&2
fi

test_start "CIP.4" "deploy pre-gate refuses incomplete VM when repair pin is absent"
make_gate_fixture
rm -f "${GATE_REPO}/build/repair-pin-dev.json"
run_gate_fixture
if [[ "$RC" -ne 0 ]] &&
   ! grep -q '^converge ' "$GATE_LOG" &&
   grep -Fq 'no exact repair pin available' <<< "$OUT" &&
   grep -Fq 'needs full recreate because vdb-only restore cannot repair missing boot topology' <<< "$OUT"; then
  test_pass "pre-deploy gate fails closed without repair pin"
else
  test_fail "pre-deploy gate no-pin routing changed"
  printf 'rc=%s\nout:\n%s\nlog:\n%s\n' "$RC" "$OUT" "$(cat "$GATE_LOG")" >&2
fi

test_start "CIP.5" "Phase 1 failure convergence skips duplicate restore and runs Phase 2"
make_safe_apply_fixture
export STUB_APPLY_EXIT_1=7
unset STUB_NON_PRECIOUS STUB_CONVERGE_EXIT
run_safe_apply_fixture
RESTORE_COUNT="$(grep -c '^restore-before-start.sh ' "$SAFE_LOG" || true)"
APPLY_COUNT="$(grep -c '^tofu-wrapper apply' "$SAFE_LOG" || true)"
unset STUB_APPLY_EXIT_1
if [[ "$RC" -eq 0 ]] &&
   [[ "$RESTORE_COUNT" == "1" ]] &&
   [[ "$APPLY_COUNT" == "2" ]] &&
   grep -Fq 'Recovery-mode restore/convergence already processed this manifest' <<< "$OUT" &&
   grep -Fq 'converge dev 303 pbs-nas:backup/vm/303/2026-06-26T02:27:40Z' "$SAFE_LOG"; then
  test_pass "Phase 1 failure convergence avoids the second restore and reaches Phase 2"
else
  test_fail "Phase 1 failure convergence path did not avoid duplicate restore"
  printf 'rc=%s restore_count=%s apply_count=%s\nout:\n%s\nlog:\n%s\n' "$RC" "$RESTORE_COUNT" "$APPLY_COUNT" "$OUT" "$(cat "$SAFE_LOG")" >&2
fi

test_start "CIP.5b" "Phase 1 failure convergence refuses Phase 2 when another manifest entry is unsafe"
make_safe_apply_fixture
export STUB_APPLY_EXIT_1=7
export STUB_MULTI_RECOVERY_STATUS=1
export STUB_MULTI_TARGETS=1
unset STUB_NON_PRECIOUS STUB_CONVERGE_EXIT
run_safe_apply_fixture
RESTORE_COUNT="$(grep -c '^restore-before-start.sh ' "$SAFE_LOG" || true)"
APPLY_COUNT="$(grep -c '^tofu-wrapper apply' "$SAFE_LOG" || true)"
unset STUB_APPLY_EXIT_1 STUB_MULTI_RECOVERY_STATUS STUB_MULTI_TARGETS
if [[ "$RC" -eq 7 ]] &&
   [[ "$RESTORE_COUNT" == "1" ]] &&
   [[ "$APPLY_COUNT" == "1" ]] &&
   grep -Fq 'converge dev 303 pbs-nas:backup/vm/303/2026-06-26T02:27:40Z' "$SAFE_LOG" &&
   grep -Fq 'status for influxdb_dev (VMID 305) is not-created-yet; refusing Phase 2' <<< "$OUT" &&
   ! grep -Fq 'start_vms=true' "$SAFE_LOG"; then
  test_pass "unsafe second manifest entry preserves original Phase 1 failure"
else
  test_fail "unsafe second manifest entry did not block Phase 2"
  printf 'rc=%s restore_count=%s apply_count=%s\nout:\n%s\nlog:\n%s\n' "$RC" "$RESTORE_COUNT" "$APPLY_COUNT" "$OUT" "$(cat "$SAFE_LOG")" >&2
fi

test_start "CIP.6" "deploy pre-gate fails unverifiable topology without convergence"
UNVERIFIABLE_OK=1
for cause in vm-scope-broken ssh-failure vm-missing malformed-class-output; do
  make_gate_fixture
  export STUB_VM_COMPLETE_EXIT=3
  export STUB_VM_COMPLETE_OUTPUT="ERROR: topology unverifiable: ${cause}"
  run_gate_fixture
  if [[ "$RC" -eq 0 ]] ||
     grep -q '^converge ' "$GATE_LOG" ||
     ! grep -Fq "UNVERIFIABLE: vault_dev (VMID 303)" <<< "$OUT" ||
     ! grep -Fq "$cause" <<< "$OUT"; then
    UNVERIFIABLE_OK=0
    printf 'cause=%s rc=%s\nout:\n%s\nlog:\n%s\n' "$cause" "$RC" "$OUT" "$(cat "$GATE_LOG")" >&2
  fi
  unset STUB_VM_COMPLETE_EXIT STUB_VM_COMPLETE_OUTPUT
done
if [[ "$UNVERIFIABLE_OK" -eq 1 ]]; then
  test_pass "unverifiable topology causes never call convergence"
else
  test_fail "an unverifiable topology cause reached convergence"
fi

test_start "CIP.7" "real convergence helper uses exact pin and skip-vmid sequence"
make_real_converge_fixture
unset STUB_IMAGE_CHECK_EXIT
run_real_converge_fixture
if [[ "$RC" -eq 0 ]] &&
   grep -Fq 'tofu-wrapper.sh plan -target=module.vault_dev -var=start_vms=false -var=register_ha=false -out=' "$REAL_LOG" &&
   grep -Fq 'check-plan-images-present.sh --plan-json' "$REAL_LOG" &&
   grep -Fq 'tofu-wrapper.sh apply -target=module.vault_dev -var=start_vms=false -var=register_ha=false -auto-approve -input=false' "$REAL_LOG" &&
   grep -Fq 'backup-now.sh --env dev --skip-vmid 303 --pin-out' "$REAL_LOG" &&
   grep -Fq 'restore-before-start.sh dev --manifest' "$REAL_LOG" &&
   grep -Fq -- '--backup-id pbs-nas:backup/vm/303/2026-06-26T02:27:40Z' "$REAL_LOG" &&
   grep -Fq 'vm-is-complete.sh 303 --expected-disks scsi0,ide2,scsi1' "$REAL_LOG" &&
   grep -Fq 'tofu-wrapper.sh apply -target=module.vault_dev -var=start_vms=true -var=register_ha=true -auto-approve -input=false' "$REAL_LOG" &&
   ! grep -Eq 'latest|--pin-file' "$REAL_LOG"; then
  test_pass "real helper preserves exact-pin restore and skip-vmid backup"
else
  test_fail "real helper sequence did not preserve exact pin/skip behavior"
  printf 'rc=%s\nout:\n%s\nlog:\n%s\n' "$RC" "$OUT" "$(cat "$REAL_LOG")" >&2
fi

test_start "CIP.8" "real convergence helper refuses missing target image before apply"
make_real_converge_fixture
export STUB_IMAGE_CHECK_EXIT=13
run_real_converge_fixture
unset STUB_IMAGE_CHECK_EXIT
if [[ "$RC" -eq 13 ]] &&
   grep -Fq 'tofu-wrapper.sh plan -target=module.vault_dev -var=start_vms=false -var=register_ha=false -out=' "$REAL_LOG" &&
   grep -Fq 'check-plan-images-present.sh --plan-json' "$REAL_LOG" &&
   ! grep -Fq 'tofu-wrapper.sh apply' "$REAL_LOG" &&
   ! grep -Fq 'backup-now.sh' "$REAL_LOG"; then
  test_pass "image precondition failure stops convergence before targeted apply"
else
  test_fail "image precondition failure did not stop convergence before apply"
  printf 'rc=%s\nout:\n%s\nlog:\n%s\n' "$RC" "$OUT" "$(cat "$REAL_LOG")" >&2
fi

runner_summary
