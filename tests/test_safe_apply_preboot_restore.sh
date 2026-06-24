#!/usr/bin/env bash
# test_safe_apply_preboot_restore.sh — safe-apply Phase 1 -> restore -> Phase 2.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
EVENT_LOG="${TMP_DIR}/events.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/framework/tofu/root" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
cp "${REPO_ROOT}/framework/scripts/restore-before-start.sh" "${FIXTURE_REPO}/framework/scripts/restore-before-start.real.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.real.sh"

for script in check-approle-creds.sh check-control-plane-drift.sh; do
  cat > "${FIXTURE_REPO}/framework/scripts/${script}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/${script}"
done

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
if [[ "${STUB_REAL_RESTORE_BEFORE_START:-0}" == "1" ]]; then
  exec "$(cd "$(dirname "$0")" && pwd)/restore-before-start.real.sh" "$@"
fi
exit "${STUB_RESTORE_EXIT:-0}"
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"

cat > "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-from-pbs.sh %s\n' "$*" >> "${EVENT_LOG}"
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh"

for script in configure-replication.sh post-deploy.sh; do
  cat > "${FIXTURE_REPO}/framework/scripts/${script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${script} %s\n' "\$*" >> "${EVENT_LOG}"
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/${script}"
done

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -chdir=* ]] && shift
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  printf '%s' "${STUB_PLAN_JSON}"
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
    printf '%s\n' '[]'
    ;;
  *'/cluster/resources --type vm --output-format json'*)
    printf '%s\n' '[{"vmid":303,"node":"pve01"}]'
    ;;
  *'qm status 303'*)
    printf '%s\n' 'stopped'
    ;;
  'ha-manager status')
    printf '%s\n' ''
    ;;
  'pvesm status 2>/dev/null')
    printf '%s\n' "${STUB_PVESM_STATUS:-pbs-nas active}"
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    printf '%s\n' "${STUB_PBS_CONTENT:-[]}"
    ;;
  *)
    printf '%s\n' '[]'
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${STUB_YQ_FAIL:-}" ]]; then
  echo "stub yq failure" >&2
  exit 31
fi
if [[ "${1:-}" == "-o=json" ]]; then
  cat <<'JSON'
{"nodes":[{"name":"pve01","mgmt_ip":"127.0.0.1"}],"vms":{"vault_dev":{"vmid":303,"backup":true}}}
JSON
  exit 0
fi
echo "127.0.0.1"
EOF
chmod +x "${SHIM_DIR}/yq"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
vms:
  vault_dev:
    vmid: 303
    backup: true
EOF

export PATH="${SHIM_DIR}:${PATH}"
export EVENT_LOG
export STUB_PLAN_JSON='{"resource_changes":[{"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"]}}]}'

run_safe_apply() {
  set +e
  cd "${FIXTURE_REPO}" && framework/scripts/safe-apply.sh dev 2>&1
  local rc=$?
  cd - >/dev/null
  echo "__EXITCODE__:${rc}"
  set -e
}

reset_fixture() {
  : > "$EVENT_LOG"
  rm -f "${EVENT_LOG}.applycount"
  rm -f "${FIXTURE_REPO}/build/preboot-restore-dev.json"
  rm -f "${FIXTURE_REPO}/build/preboot-restore-status-dev.json" "${FIXTURE_REPO}/build/first-deploy-allow-dev.json"
  unset STUB_APPLY_EXIT_1 STUB_APPLY_EXIT_2 STUB_RESTORE_EXIT STUB_YQ_FAIL
  unset STUB_REAL_RESTORE_BEFORE_START STUB_PVESM_STATUS STUB_PBS_CONTENT FIRST_DEPLOY_ALLOW_VMIDS
}

test_start "15.1" "success path orders Phase 1, restore, Phase 2"
reset_fixture
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"
ORDER="$(grep -E '^(tofu-wrapper apply|restore-before-start.sh)' "$EVENT_LOG" | sed 's/ --manifest.*//')"
EXPECTED=$'tofu-wrapper apply -target=module.vault_dev -var=start_vms=false -var=register_ha=false -auto-approve\nrestore-before-start.sh dev\ntofu-wrapper apply -target=module.vault_dev -var=start_vms=true -var=register_ha=true -auto-approve'
if [[ "$RC" == "0" && "$ORDER" == "$EXPECTED" ]]; then
  test_pass "safe-apply runs stopped apply, restore, start apply"
else
  test_fail "unexpected order or rc"
  printf 'rc=%s\norder:\n%s\nfull log:\n%s\noutput:\n%s\n' "$RC" "$ORDER" "$(cat "$EVENT_LOG")" "$OUT" >&2
fi
if [[ -s "${FIXTURE_REPO}/build/preboot-restore-dev.json" ]] &&
   grep -Fq -- "--manifest ${FIXTURE_REPO}/build/preboot-restore-dev.json" "$EVENT_LOG" &&
   jq -e '.entries[] | select(.label == "vault_dev" and .reason == "create")' \
     "${FIXTURE_REPO}/build/preboot-restore-dev.json" >/dev/null; then
  test_pass "safe-apply persists and passes the build/ preboot manifest"
else
  test_fail "safe-apply did not persist/pass the build/ preboot manifest"
  printf 'event log:\n%s\nmanifest:\n%s\n' \
    "$(cat "$EVENT_LOG")" \
    "$(cat "${FIXTURE_REPO}/build/preboot-restore-dev.json" 2>/dev/null || true)" >&2
fi

test_start "15.2" "restore failure skips Phase 2 and post-deploy"
reset_fixture
export STUB_RESTORE_EXIT=4
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"
if [[ "$RC" == "4" ]] &&
   [[ "$(grep -c 'start_vms=true' "$EVENT_LOG" || true)" == "0" ]] &&
   [[ "$(grep -c '^configure-replication.sh' "$EVENT_LOG" || true)" == "0" ]] &&
   [[ "$(grep -c '^post-deploy.sh' "$EVENT_LOG" || true)" == "0" ]] &&
   [[ -s "${FIXTURE_REPO}/build/preboot-restore-dev.json" ]]; then
  test_pass "restore failure fails closed before Phase 2"
else
  test_fail "restore failure did not fail closed"
  cat "$EVENT_LOG" >&2
fi

test_start "15.3" "Phase 1 failure runs recovery-mode restore and skips post-deploy"
reset_fixture
export STUB_APPLY_EXIT_1=7
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"
if [[ "$RC" == "7" ]] &&
   grep -Fq -- "--recovery-mode" "$EVENT_LOG" &&
   [[ "$(grep -c 'start_vms=true' "$EVENT_LOG" || true)" == "0" ]] &&
   [[ "$(grep -c '^post-deploy.sh' "$EVENT_LOG" || true)" == "0" ]]; then
  test_pass "Phase 1 failure recovery is restore-only"
else
  test_fail "Phase 1 recovery semantics changed"
  cat "$EVENT_LOG" >&2
fi

test_start "15.4" "manifest config parse failure aborts before stopped apply"
reset_fixture
export STUB_YQ_FAIL=1
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"
if [[ "$RC" != "0" ]] &&
   grep -Fq "failed to parse YAML config with yq" <<< "$OUT" &&
   [[ "$(grep -c '^tofu-wrapper apply' "$EVENT_LOG" || true)" == "0" ]]; then
  test_pass "safe-apply fails closed before apply on config parse errors"
else
  test_fail "safe-apply did not fail closed on config parse error"
  printf 'rc=%s\nlog:\n%s\noutput:\n%s\n' "$RC" "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

test_start "15.5" "no PBS storage plus first-deploy approval still reaches Phase 2"
reset_fixture
export STUB_REAL_RESTORE_BEFORE_START=1
export STUB_PVESM_STATUS='local active'
export FIRST_DEPLOY_ALLOW_VMIDS=303
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"
if [[ "$RC" == "0" ]] &&
   grep -Fq 'start_vms=true' "$EVENT_LOG" &&
   [[ "$(grep -c '^restore-from-pbs.sh' "$EVENT_LOG" || true)" == "0" ]] &&
   jq -e '.entries[] | select(.vmid == 303 and .status == "first-deploy-empty")' \
     "${FIXTURE_REPO}/build/preboot-restore-status-dev.json" >/dev/null; then
  test_pass "safe-apply Phase 2 proceeds when PBS is known absent and approval covers the manifest"
else
  test_fail "safe-apply should proceed through Phase 2 with known-absent PBS and approval"
  printf 'rc=%s\nlog:\n%s\nstatus:\n%s\noutput:\n%s\n' \
    "$RC" \
    "$(cat "$EVENT_LOG")" \
    "$(cat "${FIXTURE_REPO}/build/preboot-restore-status-dev.json" 2>/dev/null || true)" \
    "$OUT" >&2
fi

runner_summary
