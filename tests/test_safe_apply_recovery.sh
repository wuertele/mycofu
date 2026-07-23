#!/usr/bin/env bash
# test_safe_apply_recovery.sh — verify Sprint 031 phase-aware #224 recovery.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# Sprint 039: use the real vm-scope.sh; fixture doesn't ship it.
export VM_SCOPE_SCRIPT="${REPO_ROOT}/framework/scripts/vm-scope.sh"
export VM_SCOPE_YQ_BIN="$(command -v yq)"  # SHIM_DIR yq override bypass for vm-scope.sh

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
LOG_FILE="${TMP_DIR}/safe-apply.log"
RECOVERY_LOG="${TMP_DIR}/recovery.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" \
         "${FIXTURE_REPO}/framework/scripts/lib" \
         "${FIXTURE_REPO}/framework/tofu/root" \
         "${FIXTURE_REPO}/site" \
         "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" \
   "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" \
   "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"

cat > "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
converge_incomplete_vm() {
  printf 'converge-incomplete-vm %s\n' "$*" >> "${RECOVERY_LOG}"
  return "${STUB_CONVERGE_INCOMPLETE_EXIT:-0}"
}
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh"

cat > "${FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'check-plan-images-present.sh %s\n' "$*" >> "${RECOVERY_LOG}"
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh"

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
# configure-backups.sh is stubbed here because #617's no-change path invokes it
# directly (bypassing post-deploy.sh). Tests can assert directly on whether the
# reconciler was called.
for s in restore-before-start.sh configure-replication.sh post-deploy.sh configure-backups.sh; do
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

# ssh shim — supports:
#   - verify_ha_resources (returns [])
#   - #617 no-change PBS-availability probe: `pvesm status | grep -q pbs-nas`
#     STUB_PBS_AVAILABLE=1 (default) reports pbs-nas registered.
#     STUB_PBS_AVAILABLE=0 reports it absent, so the no-change reconciler
#     takes the "PBS storage not available — skipping" branch.
cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
# ssh <ssh-flags...> user@host "<remote-cmd>"
# Matches both the legacy inline "pvesm status | grep -q pbs-nas" probe
# and the #620 run_configure_backups probe that runs "pvesm status" and
# greps the result in-shell (no pbs-nas in the SSH command line).
for arg in "$@"; do
  case "$arg" in
    *pvesm*status*)
      if [[ "${STUB_PBS_AVAILABLE:-1}" == "1" ]]; then
        echo "pbs-nas pbs 1 100 200"
        exit 0
      else
        # STUB_PBS_AVAILABLE=0: legacy inline "grep -q pbs-nas" callers
        # want a non-zero exit (grep found nothing). Post-#620 callers
        # want zero exit + empty output (pvesm status ran, no pbs-nas
        # row). Distinguish by whether the command literal contains
        # "pbs-nas" (the legacy inline grep) or not.
        if [[ "$arg" == *pbs-nas* ]]; then
          exit 1
        else
          exit 0
        fi
      fi
      ;;
  esac
done
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
export RECOVERY_LOG
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
        STUB_POST_DEPLOY_EXIT \
        STUB_CONFIGURE_BACKUPS_EXIT \
        STUB_PBS_AVAILABLE
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

test_start "1.2" "success path script counts are 1 restore, 1 replication, 1 post-deploy, 1 configure-backups"
# configure-backups.sh count is the #621 regression assertion: after
# extraction (#620) run_post_success invokes it directly, so this test
# fails loudly if a future refactor drops the call from the main path.
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${COUNTS}" == "1 1 1 1" ]]; then
  test_pass "phase-aware success counts are correct"
else
  test_fail "counts got ${COUNTS}, want 1 1 1 1"
  cat "${RECOVERY_LOG}" >&2
fi

test_start "1.3" "preboot restore runs between the two apply phases"
RESTORE_LINE="$(grep -n '^restore-before-start.sh' "${RECOVERY_LOG}" | cut -d: -f1)"
APPLY_COUNT="$(apply_count)"
if [[ -n "${RESTORE_LINE}" && "${APPLY_COUNT}" == "2" ]]; then
  test_pass "restore-before-start runs once and safe-apply performs two applies"
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
# Include configure-backups.sh count so this test fails loudly if
# --no-recovery ever stops suppressing the backups reconciler.
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${RC}" == "0" && "${COUNTS}" == "1 0 0 0" ]]; then
  test_pass "--no-recovery keeps preboot restore but skips post-success convergence (all three steps)"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=0 counts='1 0 0 0'"
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
test_start "5.1" "Phase 2 failure propagates apply rc and skips post-deploy AND configure-backups"
reset_logs
export STUB_APPLY_EXIT_2=11
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
# Include configure-backups.sh so a future refactor that runs backups
# unconditionally before Phase 2 (dangerous — no fresh VMIDs to reconcile)
# would be caught by this assertion.
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${RC}" == "11" && "${COUNTS}" == "1 0 0 0" ]]; then
  test_pass "Phase 2 rc propagated after successful preboot restore"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=11 counts='1 0 0 0'"
fi

# ============================================================
# Test 6: post-success convergence — three independent steps.
#
# run_post_success invokes, in order and unconditionally:
#   1. post-deploy.sh                (Vault, cert backfill, dashboard tokens)
#   2. configure-backups.sh          (managed vzdump job reconciliation,
#                                     extracted from post-deploy.sh per #620)
#   3. configure-replication.sh      (ZFS replication convergence)
#
# All three run even if an earlier one fails: the deploy path must
# reconcile backup-job drift after destructive VM recreation independently
# of Vault-init failures inside post-deploy.sh (#620) and replication
# convergence failures (#617). First non-zero rc wins in execution order
# so callers still see a real deploy failure.
#
# See #617, #620, and RCA
# docs/reports/2026-07-17-dev-precious-backup-jobs-missing-rca.md.
# ============================================================
test_start "6.1" "configure-replication failure still runs post-deploy AND configure-backups first"
reset_logs
export STUB_CONFIGURE_REPLICATION_EXIT=8
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
# configure-backups.sh count is the #621 assertion: replication failure
# must not skip backup-job reconciliation.
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${RC}" == "8" && "${COUNTS}" == "1 1 1 1" ]]; then
  test_pass "rc=8 propagated; post-deploy and configure-backups ran independently of replication failure"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=8 counts='1 1 1 1'"
  cat "${RECOVERY_LOG}" >&2
fi

test_start "6.1a" "post-deploy → configure-backups → configure-replication ordering (invariant)"
reset_logs
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
# Under-count would be a symptom of a future refactor accidentally deleting
# one of the calls; assert exactly one of each. The three-step ordering
# reflects the extraction in #620 — configure-backups.sh no longer runs
# inside post-deploy.sh, so its position in the recovery log is the
# structural evidence that the extraction is in place.
POST_COUNT="$(count_recovery post-deploy.sh)"
BACKUPS_COUNT="$(count_recovery configure-backups.sh)"
REPL_COUNT="$(count_recovery configure-replication.sh)"
# `|| true` keeps the suite alive if a line is missing (e.g., during a
# deliberate regression check). Under `set -euo pipefail` a failing grep
# in a pipe would otherwise kill the whole test file — the individual
# test would report as "not-run" instead of "failed", masking the bug.
POST_LINE="$(grep -n '^post-deploy.sh' "${RECOVERY_LOG}" | head -n1 | cut -d: -f1 || true)"
BACKUPS_LINE="$(grep -n '^configure-backups.sh' "${RECOVERY_LOG}" | head -n1 | cut -d: -f1 || true)"
REPL_LINE="$(grep -n '^configure-replication.sh' "${RECOVERY_LOG}" | head -n1 | cut -d: -f1 || true)"
if [[ "${RC}" == "0" \
      && "${POST_COUNT}" == "1" \
      && "${BACKUPS_COUNT}" == "1" \
      && "${REPL_COUNT}" == "1" ]] &&
   [[ -n "${POST_LINE}" && -n "${BACKUPS_LINE}" && -n "${REPL_LINE}" ]] &&
   [[ "${POST_LINE}" -lt "${BACKUPS_LINE}" && "${BACKUPS_LINE}" -lt "${REPL_LINE}" ]]; then
  test_pass "post-deploy(${POST_LINE}) < configure-backups(${BACKUPS_LINE}) < configure-replication(${REPL_LINE})"
else
  test_fail "ordering invariant broken: rc=${RC}, post_count=${POST_COUNT}, backups_count=${BACKUPS_COUNT}, repl_count=${REPL_COUNT}, post=${POST_LINE}, backups=${BACKUPS_LINE}, repl=${REPL_LINE}"
  cat "${RECOVERY_LOG}" >&2
fi

test_start "6.2" "post-deploy failure still runs configure-backups AND configure-replication (#620 core invariant)"
reset_logs
export STUB_POST_DEPLOY_EXIT=12
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
# #621 core assertion — this is the failure mode #620 fixes. Under the
# pre-#620 code, configure-backups.sh lived inside post-deploy.sh; a
# post-deploy failure that exited before the configure-backups.sh call
# would leave the backups count at 0 and the managed vzdump job drifted.
# With the extraction, configure-backups.sh runs in run_post_success
# regardless of post-deploy.sh's exit code, so count = 1.
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${RC}" == "12" && "${COUNTS}" == "1 1 1 1" ]]; then
  test_pass "post-deploy rc=12 propagated; configure-backups AND configure-replication still ran"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=12 counts='1 1 1 1'"
  cat "${RECOVERY_LOG}" >&2
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

test_start "6.4" "all three post-success steps fail; post-deploy rc wins (first non-zero)"
reset_logs
export STUB_POST_DEPLOY_EXIT=12 STUB_CONFIGURE_BACKUPS_EXIT=13 STUB_CONFIGURE_REPLICATION_EXIT=8
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${RC}" == "12" && "${COUNTS}" == "1 1 1 1" ]]; then
  test_pass "post-deploy rc=12 wins; all three steps still ran"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=12 counts='1 1 1 1'"
  cat "${RECOVERY_LOG}" >&2
fi

# ---- New tests for #621 (extraction regression assertions) ----
#
# These tests would FAIL under the pre-#620 code because configure-backups.sh
# lived inside post-deploy.sh — any early exit in post-deploy.sh (Vault
# uninitialized, sealed with no unseal key, or no root token available)
# skipped the backup-job reconciler entirely. They pass under #620's
# extraction because run_post_success invokes configure-backups.sh
# directly, decoupled from post-deploy.sh's Vault convergence.

test_start "6.5" "post-deploy Vault-uninit style exit rc=1 does not skip configure-backups (#620 regression)"
reset_logs
# rc=1 mirrors post-deploy.sh's exit code in each of the Vault-uninit /
# sealed-no-key / no-root-token branches at lines 62-64, 74-82, 91-95.
export STUB_POST_DEPLOY_EXIT=1
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${RC}" == "1" && "${COUNTS}" == "1 1 1 1" ]]; then
  test_pass "post-deploy rc=1 propagated; configure-backups still reconciled"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=1 counts='1 1 1 1' — a regression here means the #620 extraction was reverted"
  cat "${RECOVERY_LOG}" >&2
fi

test_start "6.6" "configure-backups failure (middle step) propagates rc and does not skip configure-replication"
reset_logs
export STUB_CONFIGURE_BACKUPS_EXIT=13
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
# Middle-step rc semantics: post-deploy passes, backups fails, repl runs
# anyway and propagates first non-zero (backups) since post-deploy was 0.
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${RC}" == "13" && "${COUNTS}" == "1 1 1 1" ]]; then
  test_pass "configure-backups rc=13 propagated; configure-replication still ran"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=13 counts='1 1 1 1'"
  cat "${RECOVERY_LOG}" >&2
fi

test_start "6.7" "post-deploy failure + configure-backups success + replication failure — post-deploy rc wins"
reset_logs
export STUB_POST_DEPLOY_EXIT=1 STUB_CONFIGURE_REPLICATION_EXIT=8
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
# Exercises the "first non-zero rc wins" ordering when the middle step
# (configure-backups) is successful — post-deploy rc should still take
# precedence over replication rc.
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${RC}" == "1" && "${COUNTS}" == "1 1 1 1" ]]; then
  test_pass "post-deploy rc=1 propagated over replication rc=8; all three steps ran"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=1 counts='1 1 1 1'"
  cat "${RECOVERY_LOG}" >&2
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
# Include configure-backups.sh count to prove --no-recovery still
# suppresses the reconciler after the #620 extraction.
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
if [[ "${RC}" == "0" && "${COUNTS}" == "1 0 0 0" ]] &&
   grep -Fq 'Skipping AppRole credential preflight' <<< "${OUT}" &&
   grep -Fq 'Skipping post-success convergence' <<< "${OUT}"; then
  test_pass "AppRole bypassed, post-success convergence skipped, preboot restore kept"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=0 counts='1 0 0 0' + bypass strings"
fi

test_start "8.2" "--help mentions --no-recovery"
HELP_OUT=$("${FIXTURE_REPO}/framework/scripts/safe-apply.sh" --help 2>&1 || true)
if [[ "${HELP_OUT}" == *"--no-recovery"* ]]; then
  test_pass "help text advertises --no-recovery"
else
  test_fail "help text missing --no-recovery"
  printf '    help: %s\n' "${HELP_OUT}" >&2
fi

# ============================================================
# Test 9: no-change retry path (#617)
#
# A previous deploy may have destructively recreated VMs and then
# failed before backup-job reconciliation ran. Proxmox purges destroyed
# VMIDs from the managed vzdump job during purge, so the retry — which
# sees no plan changes — must still reconcile backup-job drift.
#
# Scope of the no-change path (per RCA retry-scenario evidence):
# ONLY configure-backups.sh runs directly. post-deploy.sh (which
# probes Vault) and configure-replication.sh (which tears down
# transient first-syncs) do NOT run here — running them on every
# steady-state safe-apply would cause spurious side effects.
#
# End-to-end verification that the reconciler actually re-adds VMIDs
# is by pipeline observation (R6.1 in validate.sh); the seam-opening
# tests below prove the invocation happens.
# ============================================================
test_start "9.1" "no-change retry runs configure-backups.sh directly (RCA retry scenario)"
reset_logs
# Empty plan → TARGETS is empty → safe-apply hits the "No changes" branch.
SAVED_PLAN_JSON="${STUB_PLAN_JSON}"
export STUB_PLAN_JSON='{"resource_changes":[]}'
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
export STUB_PLAN_JSON="${SAVED_PLAN_JSON}"
if [[ "${RC}" == "0" && "${COUNTS}" == "0 0 0 1" ]] &&
   grep -Fq 'No changes for dev environment' <<< "${OUT}" &&
   grep -Fq 'Backup-job reconciliation (no-change path)' <<< "${OUT}"; then
  test_pass "no-change retry ran configure-backups.sh directly; post-deploy/replication NOT invoked"
else
  test_fail "got rc=${RC}, counts (restore repl post-deploy backups)=${COUNTS}; want rc=0 counts='0 0 0 1'"
  cat "${RECOVERY_LOG}" >&2
  printf 'out:\n%s\n' "${OUT}" >&2
fi

test_start "9.2" "no-change retry propagates configure-backups.sh failure"
reset_logs
SAVED_PLAN_JSON="${STUB_PLAN_JSON}"
export STUB_PLAN_JSON='{"resource_changes":[]}'
export STUB_CONFIGURE_BACKUPS_EXIT=9
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
export STUB_PLAN_JSON="${SAVED_PLAN_JSON}"
if [[ "${RC}" == "9" && "${COUNTS}" == "0 0 0 1" ]]; then
  test_pass "rc=9 propagated on no-change from configure-backups.sh"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=9 counts='0 0 0 1'"
  cat "${RECOVERY_LOG}" >&2
fi

test_start "9.3" "no-change retry with --no-recovery skips backup reconciliation"
reset_logs
SAVED_PLAN_JSON="${STUB_PLAN_JSON}"
export STUB_PLAN_JSON='{"resource_changes":[]}'
OUT="$(run_safe_apply dev --no-recovery)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
export STUB_PLAN_JSON="${SAVED_PLAN_JSON}"
if [[ "${RC}" == "0" && "${COUNTS}" == "0 0 0 0" ]] &&
   grep -Fq 'Skipping no-change backup-job reconciliation (--no-recovery)' <<< "${OUT}"; then
  test_pass "no-change + --no-recovery skips reconciliation"
else
  test_fail "got rc=${RC}, counts=${COUNTS}"
  cat "${RECOVERY_LOG}" >&2
  printf 'out:\n%s\n' "${OUT}" >&2
fi

test_start "9.4" "no-change + --dry-run is fully read-only (no reconciliation)"
reset_logs
SAVED_PLAN_JSON="${STUB_PLAN_JSON}"
export STUB_PLAN_JSON='{"resource_changes":[]}'
OUT="$(run_safe_apply dev --dry-run)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
export STUB_PLAN_JSON="${SAVED_PLAN_JSON}"
if [[ "${RC}" == "0" && "${COUNTS}" == "0 0 0 0" ]] &&
   grep -Fq '(dry-run — not applying)' <<< "${OUT}"; then
  test_pass "dry-run with no changes exits 0 without invoking any convergence step"
else
  test_fail "got rc=${RC}, counts=${COUNTS}; want rc=0 counts='0 0 0 0' with dry-run banner"
  cat "${RECOVERY_LOG}" >&2
  printf 'out:\n%s\n' "${OUT}" >&2
fi

test_start "9.5" "no-change retry with PBS unregistered skips reconciliation (first-deploy)"
reset_logs
SAVED_PLAN_JSON="${STUB_PLAN_JSON}"
export STUB_PLAN_JSON='{"resource_changes":[]}'
export STUB_PBS_AVAILABLE=0
OUT="$(run_safe_apply dev)"
RC="${OUT##*__EXITCODE__:}"
COUNTS="$(count_recovery restore-before-start.sh) $(count_recovery configure-replication.sh) $(count_recovery post-deploy.sh) $(count_recovery configure-backups.sh)"
export STUB_PLAN_JSON="${SAVED_PLAN_JSON}"
if [[ "${RC}" == "0" && "${COUNTS}" == "0 0 0 0" ]] &&
   grep -Fq 'PBS storage not available' <<< "${OUT}"; then
  test_pass "PBS-unavailable no-change exits 0 without invoking configure-backups.sh"
else
  test_fail "got rc=${RC}, counts=${COUNTS}"
  cat "${RECOVERY_LOG}" >&2
  printf 'out:\n%s\n' "${OUT}" >&2
fi

runner_summary
