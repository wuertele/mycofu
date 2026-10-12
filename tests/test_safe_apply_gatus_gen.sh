#!/usr/bin/env bash
# test_safe_apply_gatus_gen.sh — safe-apply generates the Gatus monitoring
# config in-path and FAILS CLOSED when generation fails (#690).
#
# Incident (DRT-005, 2026-07-21): `safe-apply.sh prod` from a fresh workstation
# checkout deployed gatus with an EMPTY monitoring config because safe-apply —
# unlike the pipeline (build:merge) and rebuild-cluster.sh — never generated
# site/gatus/config.yaml. Gatus crash-looped ("configuration should contain at
# least 1 endpoint") and prod monitoring was down until diagnosed.
#
# This harness asserts the two properties of the fix:
#   G.1 success  — safe-apply invokes generate-gatus-config.sh BEFORE any tofu
#                  plan/apply and writes a non-empty site/gatus/config.yaml.
#   G.2 fail-closed — when generation fails, safe-apply aborts loudly with a
#                  non-zero exit and runs NO tofu plan/apply (never deploys an
#                  empty monitoring config). Same doctrine as
#                  destruction-safety's FAIL-not-SKIP.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# Use the real vm-scope.sh; fixture doesn't ship it.
export VM_SCOPE_SCRIPT="${REPO_ROOT}/framework/scripts/vm-scope.sh"
export VM_SCOPE_YQ_BIN="$(command -v yq)"  # SHIM_DIR yq override bypass for vm-scope.sh

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
EVENT_LOG="${TMP_DIR}/events.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts/lib" "${FIXTURE_REPO}/framework/tofu/root" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
cp "${REPO_ROOT}/framework/scripts/restore-before-start.sh" "${FIXTURE_REPO}/framework/scripts/restore-before-start.real.sh"
cp "${REPO_ROOT}/framework/scripts/vm-topology-lib.sh" "${FIXTURE_REPO}/framework/scripts/vm-topology-lib.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.real.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/vm-topology-lib.sh"

# Controllable Gatus generator stub. Logs its invocation, then either emits a
# minimal valid config (endpoints) to stdout — which safe-apply captures into a
# temp file and atomically mv's into site/gatus/config.yaml — or:
#   GATUS_STUB_FAIL=1  → non-zero exit (the generation-failure fail-closed case)
#   GATUS_STUB_EMPTY=1 → exit 0 with EMPTY stdout (#704: a generator that
#                        succeeds but produces nothing must still fail closed)
install_controllable_gatus_stub() {
  cat > "${FIXTURE_REPO}/framework/scripts/generate-gatus-config.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'generate-gatus-config.sh %s\n' "\$*" >> "${EVENT_LOG}"
if [[ -n "\${GATUS_STUB_FAIL:-}" ]]; then
  echo "stub gatus generation failure" >&2
  exit 1
fi
if [[ -n "\${GATUS_STUB_EMPTY:-}" ]]; then
  exit 0
fi
printf 'endpoints:\n  - name: stub\n    url: https://stub\n'
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/generate-gatus-config.sh"
}
install_controllable_gatus_stub

cat > "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
converge_incomplete_vm() {
  printf 'converge-incomplete-vm %s\n' "$*" >> "${EVENT_LOG}"
  return "${STUB_CONVERGE_INCOMPLETE_EXIT:-0}"
}
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh"

cat > "${FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'check-plan-images-present.sh %s\n' "$*" >> "${EVENT_LOG}"
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/check-plan-images-present.sh"

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

cat > "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-from-pbs.sh %s\n' "$*" >> "${EVENT_LOG}"
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh"

for script in configure-replication.sh post-deploy.sh configure-backups.sh; do
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
  *'/cluster/ha/resources --output-format json'*) printf '%s\n' '[]' ;;
  *'/cluster/resources --type vm --output-format json'*) printf '%s\n' '[{"vmid":303,"node":"pve01"}]' ;;
  *'qm status 303'*) printf '%s\n' 'stopped' ;;
  'ha-manager status') printf '%s\n' '' ;;
  'pvesm status 2>/dev/null') printf '%s\n' "${STUB_PVESM_STATUS:-pbs-nas active}" ;;
  *'/storage/pbs-nas/content --output-format json'*) printf '%s\n' "${STUB_PBS_CONTENT:-[]}" ;;
  *'zfs list -H -o name,volsize -r '*) ;;
  *'zfs list -H -o name -r '*) ;;
  *'zfs list -H -o name '*) exit 1 ;;
  *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
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
  cd "${FIXTURE_REPO}" && framework/scripts/safe-apply.sh dev "$@" 2>&1
  local rc=$?
  cd - >/dev/null
  echo "__EXITCODE__:${rc}"
  set -e
}

reset_fixture() {
  : > "$EVENT_LOG"
  rm -f "${FIXTURE_REPO}/build/preboot-restore-dev.json"
  rm -f "${FIXTURE_REPO}/site/gatus/config.yaml"
  unset GATUS_STUB_FAIL
  unset GATUS_STUB_EMPTY
}

# ---------------------------------------------------------------------------
test_start "SAG.1" "safe-apply generates the Gatus config in-path before any tofu plan/apply"
reset_fixture
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"

# Line number of the generator vs the first tofu-wrapper call (plan/apply).
GEN_LINE="$(grep -n '^generate-gatus-config.sh' "$EVENT_LOG" | head -1 | cut -d: -f1)"
FIRST_TOFU_LINE="$(grep -n '^tofu-wrapper ' "$EVENT_LOG" | head -1 | cut -d: -f1)"

if [[ "$RC" == "0" ]] &&
   [[ -n "$GEN_LINE" ]] &&
   [[ -n "$FIRST_TOFU_LINE" ]] &&
   (( GEN_LINE < FIRST_TOFU_LINE )) &&
   [[ -s "${FIXTURE_REPO}/site/gatus/config.yaml" ]] &&
   grep -Fq 'endpoints:' "${FIXTURE_REPO}/site/gatus/config.yaml"; then
  test_pass "generate-gatus-config.sh runs first and writes a non-empty endpoints config"
else
  test_fail "safe-apply did not generate the Gatus config before tofu, or wrote an empty config"
  printf 'rc=%s gen_line=%s first_tofu_line=%s\nlog:\n%s\ngatus config:\n%s\noutput:\n%s\n' \
    "$RC" "$GEN_LINE" "$FIRST_TOFU_LINE" "$(cat "$EVENT_LOG")" \
    "$(cat "${FIXTURE_REPO}/site/gatus/config.yaml" 2>/dev/null || echo '<absent>')" "$OUT" >&2
fi

# ---------------------------------------------------------------------------
test_start "SAG.2" "generation failure fails closed — non-zero exit, NO tofu plan/apply"
reset_fixture
export GATUS_STUB_FAIL=1
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"

if [[ "$RC" != "0" ]] &&
   [[ "$(grep -c '^tofu-wrapper ' "$EVENT_LOG" || true)" == "0" ]] &&
   grep -Fq 'generate-gatus-config.sh failed' <<< "$OUT" &&
   grep -Fq '#690' <<< "$OUT"; then
  test_pass "safe-apply aborts loudly before any tofu action when generation fails"
else
  test_fail "safe-apply did not fail closed on Gatus generation failure"
  printf 'rc=%s\nlog:\n%s\noutput:\n%s\n' "$RC" "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

# ---------------------------------------------------------------------------
test_start "SAG.3" "missing generator script fails closed (the CI-fixture teeth case)"
# The gate's teeth: a checkout/fixture that lacks generate-gatus-config.sh
# entirely must refuse the deploy with the #690 error and run NO tofu action —
# never silently proceed to apply an empty monitoring config. (This is the exact
# condition that surfaced when CI fixtures omitted the new dependency.)
reset_fixture
rm -f "${FIXTURE_REPO}/framework/scripts/generate-gatus-config.sh"
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"
if [[ "$RC" != "0" ]] &&
   [[ "$(grep -c '^tofu-wrapper ' "$EVENT_LOG" || true)" == "0" ]] &&
   grep -Fq 'generate-gatus-config.sh failed' <<< "$OUT" &&
   grep -Fq '#690' <<< "$OUT"; then
  test_pass "safe-apply refuses to deploy when the generator script is absent"
else
  test_fail "safe-apply did not fail closed when generate-gatus-config.sh is absent"
  printf 'rc=%s\nlog:\n%s\noutput:\n%s\n' "$RC" "$(cat "$EVENT_LOG")" "$OUT" >&2
fi
# Restore the controllable stub for the later cases.
install_controllable_gatus_stub

# ---------------------------------------------------------------------------
test_start "SAG.4" "generation failure leaves a prior-good config UNTOUCHED (atomic write, #706)"
# #706 defect 1: the old `>` redirect truncated site/gatus/config.yaml to 0 bytes
# BEFORE the generator ran, so a transient generation failure DESTROYED a
# previously-good config (then rm -f'd it). The temp-file + atomic mv must leave
# the prior-good config bit-for-bit intact on any failure.
reset_fixture
mkdir -p "${FIXTURE_REPO}/site/gatus"
printf 'endpoints:\n  - name: prior-good\n    url: https://prior-good\n' \
  > "${FIXTURE_REPO}/site/gatus/config.yaml"
SHA_BEFORE="$(shasum "${FIXTURE_REPO}/site/gatus/config.yaml" | awk '{print $1}')"
export GATUS_STUB_FAIL=1
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"
unset GATUS_STUB_FAIL
SHA_AFTER="$(shasum "${FIXTURE_REPO}/site/gatus/config.yaml" 2>/dev/null | awk '{print $1}' || echo MISSING)"
if [[ "$RC" != "0" ]] && [[ "$SHA_BEFORE" == "$SHA_AFTER" ]] &&
   [[ "$(grep -c '^tofu-wrapper ' "$EVENT_LOG" || true)" == "0" ]]; then
  test_pass "a transient generation failure did not truncate or delete the prior-good config"
else
  test_fail "generation failure mutated the prior-good config (before=${SHA_BEFORE} after=${SHA_AFTER} rc=${RC})"
  printf 'log:\n%s\noutput:\n%s\n' "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

# ---------------------------------------------------------------------------
test_start "SAG.5" "empty generator output fails closed — exit 0 + no stdout still aborts (#704)"
# safe-apply's fail-closed check must key on OUTPUT, not just the exit code: a
# generator that exits 0 with empty stdout must not leave a 0-byte config that
# reaches tofu. A prior-good config must also survive this failure untouched.
reset_fixture
mkdir -p "${FIXTURE_REPO}/site/gatus"
printf 'endpoints:\n  - name: prior-good\n    url: https://prior-good\n' \
  > "${FIXTURE_REPO}/site/gatus/config.yaml"
SHA_BEFORE="$(shasum "${FIXTURE_REPO}/site/gatus/config.yaml" | awk '{print $1}')"
export GATUS_STUB_EMPTY=1
OUT="$(run_safe_apply)"
RC="${OUT##*__EXITCODE__:}"
unset GATUS_STUB_EMPTY
SHA_AFTER="$(shasum "${FIXTURE_REPO}/site/gatus/config.yaml" 2>/dev/null | awk '{print $1}' || echo MISSING)"
if [[ "$RC" != "0" ]] && [[ "$SHA_BEFORE" == "$SHA_AFTER" ]] &&
   [[ "$(grep -c '^tofu-wrapper ' "$EVENT_LOG" || true)" == "0" ]] &&
   grep -Fq 'empty Gatus config' <<< "$OUT"; then
  test_pass "safe-apply aborts on empty generator output and preserves the prior-good config"
else
  test_fail "safe-apply did not fail closed on empty generator output (before=${SHA_BEFORE} after=${SHA_AFTER} rc=${RC})"
  printf 'log:\n%s\noutput:\n%s\n' "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

# ---------------------------------------------------------------------------
test_start "SAG.6" "--dry-run is read-only — generator NOT invoked, config UNTOUCHED (#706)"
# #706 defect 2: the pre-fix code generated (and overwrote) the config even on a
# dry run. A dry run must not invoke the generator at all and must leave the
# operator's real config.yaml exactly as it found it.
reset_fixture
mkdir -p "${FIXTURE_REPO}/site/gatus"
printf 'endpoints:\n  - name: prior-good\n    url: https://prior-good\n' \
  > "${FIXTURE_REPO}/site/gatus/config.yaml"
SHA_BEFORE="$(shasum "${FIXTURE_REPO}/site/gatus/config.yaml" | awk '{print $1}')"
OUT="$(run_safe_apply --dry-run)"
RC="${OUT##*__EXITCODE__:}"
SHA_AFTER="$(shasum "${FIXTURE_REPO}/site/gatus/config.yaml" 2>/dev/null | awk '{print $1}' || echo MISSING)"
if [[ "$RC" == "0" ]] && [[ "$SHA_BEFORE" == "$SHA_AFTER" ]] &&
   [[ "$(grep -c '^generate-gatus-config.sh' "$EVENT_LOG" || true)" == "0" ]] &&
   grep -Fq 'dry-run is read-only' <<< "$OUT"; then
  test_pass "dry-run skipped generation entirely and left the config untouched"
else
  test_fail "dry-run invoked the generator or mutated the config (before=${SHA_BEFORE} after=${SHA_AFTER} rc=${RC})"
  printf 'log:\n%s\noutput:\n%s\n' "$(cat "$EVENT_LOG")" "$OUT" >&2
fi

runner_summary
