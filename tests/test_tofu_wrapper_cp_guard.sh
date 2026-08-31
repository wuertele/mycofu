#!/usr/bin/env bash
# test_tofu_wrapper_cp_guard.sh — hermetic coverage for the tofu-wrapper.sh
# control-plane converge-vs-recreate guard (G7 safety fence).
#
# The guard's plan classification is unit-tested in
# test_vm_scope_control_plane_recreate.sh. This test covers the wrapper's
# CONTEXT behavior: enforced in the pipeline (CI set), advisory on the
# workstation (CI unset), and fail-closed when the plan cannot be inspected.
#
# It extracts guard_control_plane_recreate() from the wrapper and sources it
# with a stub `tofu` (TOFU_BIN) so no real cluster/backend is touched. The
# real vm-scope.sh + repo manifests are used for classification.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

WRAPPER="${REPO_ROOT}/framework/scripts/tofu-wrapper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Structural assertions on the shipped wrapper ------------------------
test_start "S1" "guard is gated on apply and defined"
if grep -q '^guard_control_plane_recreate()' "$WRAPPER" \
   && grep -q 'guard_control_plane_recreate "\$@"' "$WRAPPER"; then
  test_pass "guard defined and invoked"
else
  test_fail "guard function/gate missing from wrapper"
fi

test_start "S2" "guard is CI-context aware (advisory on workstation)"
if grep -q 'if \[\[ -z "\${CI:-}" \]\]' "$WRAPPER"; then
  test_pass "CI env var gates enforcement"
else
  test_fail "guard does not gate on CI env var"
fi

test_start "S3" "recreate branch carries the R13/R14 seam comment"
if grep -q 'R13/R14 seam' "$WRAPPER" && grep -q 'enqueue' "$WRAPPER"; then
  test_pass "R13/R14 executor seam annotated"
else
  test_fail "R13/R14 seam comment missing"
fi

# --- Extract the guard function for behavioral tests ---------------------
GUARD_LIB="${TMP_DIR}/guard.sh"
awk '
  /^guard_control_plane_recreate\(\) \{/ { f=1 }
  f { print }
  f && /^\}$/ { exit }
' "$WRAPPER" > "$GUARD_LIB"

if ! grep -q '^guard_control_plane_recreate()' "$GUARD_LIB"; then
  test_start "X" "extract guard function"
  test_fail "could not extract guard_control_plane_recreate from wrapper"
  runner_summary
fi

# Stub tofu: `plan ... -out=FILE` writes a marker; `show -json FILE` prints
# whichever fixture JSON the test selected via STUB_PLAN_JSON. STUB_PLAN_FAIL
# forces the plan step to fail (unreadable-plan path).
STUB_TOFU="${TMP_DIR}/tofu"
cat > "$STUB_TOFU" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"
if [[ "$sub" == "state" ]]; then
  # STUB_STATE_FAIL=1 simulates a backend outage (postgres unreachable,
  # network partition, state lock). The pre-#538 code was
  # `tofu state list 2>/dev/null | grep -q ...` which swallowed this exit
  # code and treated it identically to "first deploy" — Case 6 asserts the
  # fix now discriminates the two.
  if [[ "${STUB_STATE_FAIL:-0}" == "1" ]]; then
    echo "Error: Failed to load state: pq: connection refused" >&2
    exit 1
  fi
  # Non-empty VM state so the guard's state-exists precondition passes
  # (a recreate destroys an existing VM; first-deploy has nothing to fence).
  # STUB_EMPTY_STATE=1 simulates a first deploy (no VMs in state).
  if [[ "${STUB_EMPTY_STATE:-0}" != "1" ]]; then
    echo "module.gitlab.module.gitlab.proxmox_virtual_environment_vm.vm"
  fi
  exit 0
elif [[ "$sub" == "plan" ]]; then
  if [[ "${STUB_PLAN_FAIL:-0}" == "1" ]]; then
    exit 7
  fi
  out=""
  for a in "$@"; do
    case "$a" in -out=*) out="${a#-out=}" ;; esac
  done
  [[ -n "$out" ]] && printf 'planned\n' > "$out"
  exit 0
elif [[ "$sub" == "show" ]]; then
  cat "${STUB_PLAN_JSON}"
  exit 0
fi
exit 0
EOF
chmod +x "$STUB_TOFU"

# Minimal context the guard closes over.
TOFU_BIN="$STUB_TOFU"
REPO_DIR="$REPO_ROOT"
IMAGE_VERSIONS="${TMP_DIR}/nonexistent-image-versions.tfvars"  # skip -var-file
export STUB_PLAN_JSON STUB_PLAN_FAIL STUB_EMPTY_STATE STUB_STATE_FAIL
STUB_EMPTY_STATE=0
STUB_STATE_FAIL=0
# shellcheck disable=SC1090
source "$GUARD_LIB"

CP_REPLACE_JSON="${TMP_DIR}/cp-replace.json"
cat > "$CP_REPLACE_JSON" <<'JSON'
{"resource_changes":[
 {"address":"module.gitlab.module.gitlab.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["delete","create"]}}
]}
JSON

CP_UPDATE_JSON="${TMP_DIR}/cp-update.json"
cat > "$CP_UPDATE_JSON" <<'JSON'
{"resource_changes":[
 {"address":"module.cicd.module.cicd.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["update"]}}
]}
JSON

run_guard() {
  set +e
  GUARD_OUT="$(guard_control_plane_recreate "$@" 2>&1)"
  GUARD_RC=$?
  set -e
}

# --- Case 1: workstation (CI unset) is advisory, never blocks ------------
test_start "1" "workstation context is advisory, does not block"
STUB_PLAN_JSON="$CP_REPLACE_JSON"; STUB_PLAN_FAIL=0
( unset CI; run_guard apply -target=module.gitlab -auto-approve; \
  printf '%s\n' "$GUARD_RC" > "${TMP_DIR}/rc"; printf '%s' "$GUARD_OUT" > "${TMP_DIR}/out" )
rc="$(cat "${TMP_DIR}/rc")"; out="$(cat "${TMP_DIR}/out")"
if [[ "$rc" -eq 0 ]] && grep -qi 'advisory' <<< "$out"; then
  test_pass "advisory pass even with a control-plane replace in the plan"
else
  test_fail "expected rc 0 + advisory note, got rc=$rc out=[$out]"
fi

# --- Case 2: pipeline + control-plane replace -> BLOCK (rc 1) ------------
test_start "2" "pipeline blocks a control-plane replace"
STUB_PLAN_JSON="$CP_REPLACE_JSON"; STUB_PLAN_FAIL=0
( export CI=1; run_guard apply -target=module.gitlab -auto-approve; \
  printf '%s\n' "$GUARD_RC" > "${TMP_DIR}/rc"; printf '%s' "$GUARD_OUT" > "${TMP_DIR}/out" )
rc="$(cat "${TMP_DIR}/rc")"; out="$(cat "${TMP_DIR}/out")"
if [[ "$rc" -eq 1 ]] && grep -q 'G7' <<< "$out" && grep -q 'rebuild-cluster.sh --scope control-plane' <<< "$out"; then
  test_pass "control-plane replace fenced with workstation guidance"
else
  test_fail "expected rc 1 + G7 message, got rc=$rc out=[$out]"
fi

# --- Case 3: pipeline + control-plane in-place update -> PROCEED (rc 0) --
test_start "3" "pipeline proceeds on in-place control-plane update"
STUB_PLAN_JSON="$CP_UPDATE_JSON"; STUB_PLAN_FAIL=0
( export CI=1; run_guard apply -target=module.cicd -auto-approve; \
  printf '%s\n' "$GUARD_RC" > "${TMP_DIR}/rc"; printf '%s' "$GUARD_OUT" > "${TMP_DIR}/out" )
rc="$(cat "${TMP_DIR}/rc")"
if [[ "$rc" -eq 0 ]]; then
  test_pass "in-place convergence allowed in the pipeline"
else
  test_fail "expected rc 0, got rc=$rc out=[$(cat "${TMP_DIR}/out")]"
fi

# --- Case 4: pipeline + plan cannot be produced -> FAIL CLOSED (rc 1) ----
test_start "4" "pipeline fails closed when the plan cannot be inspected"
STUB_PLAN_JSON="$CP_UPDATE_JSON"; STUB_PLAN_FAIL=1
( export CI=1; run_guard apply -target=module.cicd -auto-approve; \
  printf '%s\n' "$GUARD_RC" > "${TMP_DIR}/rc"; printf '%s' "$GUARD_OUT" > "${TMP_DIR}/out" )
rc="$(cat "${TMP_DIR}/rc")"; out="$(cat "${TMP_DIR}/out")"
if [[ "$rc" -eq 1 ]] && grep -q 'Failing closed' <<< "$out"; then
  test_pass "unprovable plan blocks the apply"
else
  test_fail "expected rc 1 + fail-closed, got rc=$rc out=[$out]"
fi

# --- Case 5: pipeline + empty VM state (first deploy) -> PROCEED (rc 0) ---
# A recreate destroys an existing VM; with no VM in state there is nothing to
# fence, and the guard must not block a first deploy that only creates.
test_start "5" "pipeline first deploy (empty state) is not fenced"
STUB_PLAN_JSON="$CP_REPLACE_JSON"; STUB_PLAN_FAIL=0
( export CI=1 STUB_EMPTY_STATE=1; run_guard apply -target=module.gitlab -auto-approve; \
  printf '%s\n' "$GUARD_RC" > "${TMP_DIR}/rc"; printf '%s' "$GUARD_OUT" > "${TMP_DIR}/out" )
rc="$(cat "${TMP_DIR}/rc")"
if [[ "$rc" -eq 0 ]]; then
  test_pass "empty-state first deploy proceeds"
else
  test_fail "expected rc 0, got rc=$rc out=[$(cat "${TMP_DIR}/out")]"
fi

# --- Case 6: pipeline + tofu state list errors -> FAIL CLOSED (rc 1) ------
# Regression test for #538. Pre-fix code:
#   if ! "$TOFU_BIN" state list 2>/dev/null | grep -q "..."; then return 0
# The `2>/dev/null` swallowed the exit code — a postgres backend outage or
# state lock would produce identical stdout to a legitimate first-deploy
# (empty), silently disabling the fence. Per
# .claude/rules/destruction-safety.md "When a Safety Check Cannot Determine
# State", the correct default is FAIL, not SKIP. Under the pre-fix code this
# test FAILS: the guard silently returns rc=0 with empty output, but Case 6
# expects rc=1 with the G7 diagnostic. Under the fix it PASSES because the
# guard now distinguishes "state list errored" (indeterminate → fail closed)
# from "state list returned empty" (legitimate first deploy → proceed).
test_start "6" "pipeline fails closed when tofu state list errors"
STUB_PLAN_JSON="$CP_REPLACE_JSON"; STUB_PLAN_FAIL=0
( export CI=1 STUB_STATE_FAIL=1; run_guard apply -target=module.gitlab -auto-approve; \
  printf '%s\n' "$GUARD_RC" > "${TMP_DIR}/rc"; printf '%s' "$GUARD_OUT" > "${TMP_DIR}/out" )
rc="$(cat "${TMP_DIR}/rc")"; out="$(cat "${TMP_DIR}/out")"
# Also assert the tofu stderr ("pq: connection refused" from the stub) is
# surfaced — the fix captures stderr into a tmpfile and prints it under
# "tofu state list stderr:" so the operator gets the actual cause in one
# round trip, not just an exit code.
if [[ "$rc" -eq 1 ]] \
   && grep -q 'G7' <<< "$out" \
   && grep -qi 'failing closed' <<< "$out" \
   && grep -qi 'determine tofu state' <<< "$out" \
   && grep -q 'pq: connection refused' <<< "$out"; then
  test_pass "state-list error fails closed with G7 diagnostic + captured stderr"
else
  test_fail "expected rc 1 + G7 fail-closed + determine-tofu-state + stub stderr, got rc=$rc out=[$out]"
fi

runner_summary
