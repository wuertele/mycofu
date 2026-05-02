#!/usr/bin/env bash
# test_safe_apply_recovery.sh — verify Sprint 031 phase-aware #224 recovery.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
LOG_FILE="${TMP_DIR}/safe-apply.log"
RECOVERY_LOG="${TMP_DIR}/recovery.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" \
         "${FIXTURE_REPO}/framework/tofu/root" \
         "${FIXTURE_REPO}/site" \
         "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" \
   "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"

# Stub: no-op approle preflight
cat > "${FIXTURE_REPO}/framework/scripts/check-approle-creds.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/check-approle-creds.sh"

# Stub: no-op control-plane drift check
cat > "${FIXTURE_REPO}/framework/scripts/check-control-plane-drift.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/check-control-plane-drift.sh"

# Stub: tofu-wrapper.sh — controllable apply exit code via STUB_APPLY_EXIT.
# Successive applies use STUB_APPLY_EXIT_1 (pass 1) and STUB_APPLY_EXIT_2
# (pass 2). Default to 0 if not set.
cat > "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${STUB_LOG_FILE}"

case "${1:-}" in
  plan)
    for arg in "$@"; do
      if [[ "${arg}" == -out=* ]]; then
        : > "${arg#-out=}"
      fi
    done
    exit 0
    ;;
  apply)
    APPLY_NUM_FILE="${STUB_LOG_FILE}.applycount"
    PREV=$(cat "${APPLY_NUM_FILE}" 2>/dev/null || echo 0)
    NEXT=$((PREV + 1))
    echo "$NEXT" > "${APPLY_NUM_FILE}"
    case "$NEXT" in
      1) exit "${STUB_APPLY_EXIT_1:-0}" ;;
      2) exit "${STUB_APPLY_EXIT_2:-0}" ;;
      *) exit 0 ;;
    esac
    ;;
  init|state)
    exit 0
    ;;
esac

echo "unexpected tofu-wrapper invocation: $*" >&2
exit 2
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

# Recovery/convergence script stubs — log invocation; exit code controllable via env.
for s in restore-before-start.sh configure-replication.sh post-deploy.sh; do
  var_suffix=$(echo "${s%.sh}" | tr 'a-z-' 'A-Z_')
  cat > "${FIXTURE_REPO}/framework/scripts/${s}" <<EOF
#!/usr/bin/env bash
printf '${s} %s\n' "\$*" >> "${RECOVERY_LOG}"
exit "\${STUB_${var_suffix}_EXIT:-0}"
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/${s}"
done

# tofu shim (for `tofu show -json`)
cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -chdir=* ]]; then shift; fi
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  printf '%s' "${STUB_PLAN_JSON}"
  exit 0
fi
exit 2
EOF
chmod +x "${SHIM_DIR}/tofu"

# ssh shim (for verify_ha_resources)
cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
exit 0
EOF
chmod +x "${SHIM_DIR}/ssh"

# yq shim — config.yaml lookups plus manifest-builder JSON conversion.
cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-o=json" ]]; then
  cat <<'JSON'
{
  "nodes": [{"name": "pve01", "mgmt_ip": "127.0.0.1"}],
  "vms": {
    "vault_dev": {"vmid": 303, "backup": true},
    "testapp_dev": {"vmid": 500, "backup": true}
  }
}
JSON
  exit 0
fi
if [[ "${1:-}" == "-r" && "${2:-}" == ".nodes[0].mgmt_ip" ]]; then
  echo "127.0.0.1"
  exit 0
fi
echo "127.0.0.1"
exit 0
EOF
chmod +x "${SHIM_DIR}/yq"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
EOF

export PATH="${SHIM_DIR}:${PATH}"
export STUB_LOG_FILE="${LOG_FILE}"
export STUB_PLAN_JSON='{"resource_changes":[
  {"address":"module.testapp_dev.module.testapp.proxmox_virtual_environment_vm.vm","change":{"actions":["create"]}},
  {"address":"module.vault_dev.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"]}}
]}'

reset_logs() {
  : > "${LOG_FILE}"
  : > "${RECOVERY_LOG}"
  rm -f "${LOG_FILE}.applycount"
  unset STUB_APPLY_EXIT_1 STUB_APPLY_EXIT_2 \
        STUB_RESTORE_BEFORE_START_EXIT \
        STUB_CONFIGURE_REPLICATION_EXIT \
        STUB_POST_DEPLOY_EXIT
}

run_safe_apply() {
  set +e
  cd "${FIXTURE_REPO}" && framework/scripts/safe-apply.sh "$@" 2>&1
  local rc=$?
  cd - >/dev/null
  echo "__EXITCODE__:${rc}"
  set -e
}

# Helpers for assertions over phase-aware recovery log.
count_recovery() {
  local prefix="$1"
  grep -c "^${prefix}" "${RECOVERY_LOG}" || true
}

apply_count() {
  grep -c '^apply ' "${LOG_FILE}" || true
}

# ============================================================
# Test 1: success path
# ============================================================
test_start "1.1" "success path runs preboot restore, replication, and post-deploy"
reset_logs
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
if [[ "${RC}" == "0" ]]; then
  test_pass "safe-apply exited 0"
else
  test_fail "safe-apply exited 0 (got ${RC})"
  printf '%s\n' "${OUT}" >&2
fi

test_start "1.2" "success path script counts are 1 restore, 1 replication, 1 post-deploy"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh)"
if [[ "${COUNTS}" == "1 1 1" ]]; then
  test_pass "phase-aware success counts are correct"
else
  test_fail "counts got ${COUNTS}, want 1 1 1"
  cat "${RECOVERY_LOG}" >&2
fi

test_start "1.3" "preboot restore runs before Phase 2 apply"
RESTORE_LINE="$(grep -n '^restore-before-start.sh' "${RECOVERY_LOG}" | cut -d: -f1)"
APPLY_COUNT="$(apply_count)"
if [[ "${RESTORE_LINE}" == "1" && "${APPLY_COUNT}" == "2" ]]; then
  test_pass "restore-before-start runs once between two applies"
else
  test_fail "unexpected restore/apply shape: restore_line=${RESTORE_LINE}, apply_count=${APPLY_COUNT}"
fi

# ============================================================
# Test 2: --no-recovery suppresses post-success convergence only
# ============================================================
test_start "2.1" "--no-recovery still runs preboot restore after successful Phase 1"
reset_logs
OUT="$(run_safe_apply dev --no-recovery)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh)"
if [[ "${RC}" == "0" && "${COUNTS}" == "1 0 0" ]]; then
  test_pass "--no-recovery keeps preboot restore but skips post-success convergence"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=0 counts='1 0 0'"
fi

# ============================================================
# Test 3: Phase 1 failure
# ============================================================
test_start "3.1" "Phase 1 apply failure triggers recovery-mode restore and exits with apply rc"
reset_logs
export STUB_APPLY_EXIT_1=7
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh)"
if [[ "${RC}" == "7" && "${COUNTS}" == "1 0 0" ]] &&
   grep -Fq -- "--recovery-mode" "${RECOVERY_LOG}"; then
  test_pass "Phase 1 failure runs recovery-mode restore only and propagates apply rc"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; recovery log:"
  cat "${RECOVERY_LOG}" >&2
fi

test_start "3.2" "Phase 2 is not attempted after Phase 1 failure"
if [[ "$(apply_count)" == "1" ]]; then
  test_pass "only Phase 1 apply ran"
else
  test_fail "apply count got $(apply_count), want 1"
fi

test_start "3.3" "Phase 1 failure + --no-recovery skips recovery and propagates rc"
reset_logs
export STUB_APPLY_EXIT_1=9
OUT="$(run_safe_apply dev --no-recovery)"
RC="${OUT##*__EXITCODE__:}"
if [[ "${RC}" == "9" && "$(count_recovery restore-before-start.sh)" == "0" ]]; then
  test_pass "rc=9 propagated, run_recovery suppressed"
else
  test_fail "got rc=${RC}, restore_count=$(count_recovery restore-before-start.sh)"
fi

# ============================================================
# Test 4: restore failure after Phase 1
# ============================================================
test_start "4.1" "preboot restore failure skips Phase 2 and exits with restore rc"
reset_logs
export STUB_RESTORE_BEFORE_START_EXIT=5
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
if [[ "${RC}" == "5" && "$(apply_count)" == "1" ]]; then
  test_pass "restore rc=5 propagated and Phase 2 skipped"
else
  test_fail "got rc=${RC}, apply_count=$(apply_count); output:"
  printf '%s\n' "${OUT}" >&2
fi

# ============================================================
# Test 5: Phase 2 failure
# ============================================================
test_start "5.1" "Phase 2 failure propagates apply rc and skips post-deploy"
reset_logs
export STUB_APPLY_EXIT_2=11
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh)"
if [[ "${RC}" == "11" && "${COUNTS}" == "1 0 0" ]]; then
  test_pass "Phase 2 rc propagated after successful preboot restore"
else
  test_fail "got rc=${RC}, counts=${COUNTS}"
fi

# ============================================================
# Test 6: post-success convergence failures
# ============================================================
test_start "6.1" "configure-replication failure skips post-deploy and propagates rc"
reset_logs
export STUB_CONFIGURE_REPLICATION_EXIT=8
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh)"
if [[ "${RC}" == "8" && "${COUNTS}" == "1 1 0" ]]; then
  test_pass "rc=8 propagated, post-deploy skipped"
else
  test_fail "got rc=${RC}, counts=${COUNTS}"
fi

test_start "6.2" "post-deploy failure propagates rc"
reset_logs
export STUB_POST_DEPLOY_EXIT=12
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
if [[ "${RC}" == "12" ]]; then
  test_pass "post-deploy rc=12 propagated"
else
  test_fail "got rc=${RC}, want 12"
fi

test_start "6.3" "apply rc takes precedence over recovery rc on Phase 1 failure"
reset_logs
export STUB_APPLY_EXIT_1=3 STUB_RESTORE_BEFORE_START_EXIT=99
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
if [[ "${RC}" == "3" ]]; then
  test_pass "Phase 1 apply rc=3 takes precedence over recovery rc=99"
else
  test_fail "got rc=${RC}, want 3"
fi

# ============================================================
# Test 7: --dry-run
# ============================================================
test_start "7.1" "--dry-run does not invoke apply or restore"
reset_logs
OUT="$(run_safe_apply dev --dry-run)"
RC="${OUT##*__EXITCODE__:}"
LINES=$(wc -l < "${RECOVERY_LOG}" | tr -d ' ')
if [[ "${RC}" == "0" && "${LINES}" == "0" && "$(apply_count)" == "0" ]]; then
  test_pass "dry-run: rc=0, no apply, no restore"
else
  test_fail "dry-run unexpected: rc=${RC}, recovery_lines=${LINES}, apply_count=$(apply_count)"
fi

# ============================================================
# Test 8: flag combinations and help
# ============================================================
test_start "8.1" "--ignore-approle-creds --no-recovery"
reset_logs
OUT="$(run_safe_apply dev --ignore-approle-creds --no-recovery)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh)"
if [[ "${RC}" == "0" && "${COUNTS}" == "1 0 0" ]] &&
   grep -Fq 'Skipping AppRole credential preflight' <<< "${OUT}" &&
   grep -Fq 'Skipping post-success convergence' <<< "${OUT}"; then
  test_pass "AppRole bypassed, post-success convergence skipped, preboot restore kept"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; flag bypass strings missing"
fi

test_start "8.2" "--help mentions --no-recovery"
HELP_OUT=$("${FIXTURE_REPO}/framework/scripts/safe-apply.sh" --help 2>&1 || true)
if [[ "${HELP_OUT}" == *"--no-recovery"* ]]; then
  test_pass "help text advertises --no-recovery"
else
  test_fail "help text missing --no-recovery"
  printf '    help: %s\n' "${HELP_OUT}" >&2
fi

runner_summary
