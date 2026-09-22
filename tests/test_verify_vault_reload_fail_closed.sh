#!/usr/bin/env bash
# test_verify_vault_reload_fail_closed.sh — #679 regression guard.
#
# verify-vault-reload.sh drives a forced DNS-01 renewal on a Vault VM and then
# verifies the #642 SIGHUP reload actually served the new cert. Issue #679
# found two defects, both observed live:
#
#   1. A miscalibrated blocking timeout killed the (multi-minute) DNS-01
#      renewal mid-flight on every realistic run.
#   2. When an early-exit path fired (the timeout, or the VM going unreachable
#      mid-run), the script trailed off with NO verdict. Whether that surfaced
#      as exit 0 or exit 124 was environment-dependent (GNU vs BSD vs absent
#      `timeout`, whether set -e fired) — i.e. a silent false-success hazard.
#      .claude/rules/destruction-safety.md requires the opposite: a check that
#      cannot determine the answer FAILs loudly, never SKIPs.
#
# This test is fully hermetic: it stands up a fixture repo, shims ssh/timeout/
# ssh-keygen on PATH, and drives the real script through four scenarios,
# asserting that:
#   - PASS prints "VERDICT: PASS" and exits 0
#   - the #642 failure mode (served cert never reloads) prints "VERDICT: FAIL"
#     and exits non-zero
#   - a VM that goes unreachable mid-trigger prints "VERDICT: INCOMPLETE" and
#     exits non-zero (the core #679 fail-closed guarantee)
#   - a renewal that never completes within --renewal-timeout prints
#     "VERDICT: INCOMPLETE" and exits non-zero
#
# It then MUTATES the script (reintroduces the silent-success defect: an EXIT
# trap that swallows the exit code to 0 without a verdict) and asserts the
# mutant DOES silently succeed — proving the guard above is load-bearing and
# this test would catch a regression that removed it.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_SRC="${REPO_ROOT}/framework/scripts/verify-vault-reload.sh"

source "${REPO_ROOT}/tests/lib/runner.sh"

# --- Preconditions on the workstation running the test -----------------------
for tool in yq jq openssl awk sed bash perl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    test_start "679.pre" "required test tool present: ${tool}"
    test_fail "missing ${tool}; cannot run hermetic verify-vault-reload test"
    runner_summary
  fi
done

# --- Build a hermetic sandbox: fixture repo + PATH shims ---------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/vvr-679.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

REPO="${WORK}/repo"
BIN="${WORK}/bin"
STATE="${WORK}/state"
mkdir -p "${REPO}/site" "${REPO}/framework/scripts" "${BIN}" "${STATE}"

# find_repo_root walks up for flake.nix; give the fixture one plus a config.
: > "${REPO}/flake.nix"
cat > "${REPO}/site/config.yaml" <<'YAML'
domain: example.test
vms:
  vault_dev:
    ip: 10.99.99.99
YAML

cp "${SCRIPT_SRC}" "${REPO}/framework/scripts/verify-vault-reload.sh"
chmod +x "${REPO}/framework/scripts/verify-vault-reload.sh"

# timeout shim: drop the duration, exec the rest. The script's own timeouts are
# exercised via the ssh shim, not the real `timeout` binary (which may be BSD/
# absent on the operator's macOS box — precisely the ambiguity #679 removes).
cat > "${BIN}/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH

cat > "${BIN}/ssh-keygen" <<'SH'
#!/usr/bin/env bash
exit 0
SH

# ssh shim: the last arg is the remote command string. Behavior is driven by
# $VVR_SCENARIO and a trigger marker so cert serials advance post-renewal.
cat > "${BIN}/ssh" <<'SH'
#!/usr/bin/env bash
remote="${!#}"
state="${VVR_STATE}"
scenario="${VVR_SCENARIO:-pass}"
triggered() { [[ -e "${state}/triggered" ]]; }

case "$remote" in
  true) exit 0 ;;

  *"install -m 0600 /dev/stdin"*) cat >/dev/null 2>&1; exit 0 ;;
  *"rm -f /run/certbot-force-renewal.env"*) exit 0 ;;
  *"test -e /run/certbot-force-renewal.env"*) exit 1 ;;   # no stale file
  *"systemctl stop certbot-renew.timer"*) exit 0 ;;
  *"systemctl start --quiet certbot-renew.timer"*) exit 0 ;;
  *"systemctl reset-failed"*) exit 0 ;;
  *journalctl*) echo "(fake journal)"; exit 0 ;;

  *"systemctl start --no-block certbot-renew.service"*)
    # The kick that begins the renewal.
    if [[ "$scenario" == "unreachable" ]]; then
      # VM drops right here — the exact silent-abort window from #679.
      exit 255
    fi
    : > "${state}/triggered"
    exit 0
    ;;

  *ExecReload*)
    echo 'ExecReload={ path=/nix/store/x/bin/kill ; argv[]=/nix/store/x/bin/kill -HUP $MAINPID ; ignore_errors=no ; start_time=0 }'
    exit 0 ;;
  *MainPID*) echo '12345'; exit 0 ;;
  *sys/health*) echo 'unsealed'; exit 0 ;;

  *fullchain.pem*)
    if triggered; then echo 'BB:NEW'; else echo 'AA:OLD'; fi
    exit 0 ;;

  *s_client*)
    # Served serial. For the #642 failure mode it never advances past baseline.
    if triggered && [[ "$scenario" != "reload_broken" ]]; then
      echo 'BB:NEW'
    else
      echo 'AA:OLD'
    fi
    exit 0 ;;

  *"-p ActiveState"*)
    # The multi-property completion query used by certbot_renew_result.
    if triggered && [[ "$scenario" != "renewal_timeout" ]]; then
      printf 'ActiveState=inactive\nResult=success\nExecMainStatus=0\nInvocationID=inv-new\n'
    else
      # Not triggered, or renewal never completes: still activating on the
      # baseline invocation.
      printf 'ActiveState=activating\nResult=success\nExecMainStatus=0\nInvocationID=inv-base\n'
    fi
    exit 0 ;;

  *"certbot-renew.service -p InvocationID"*) echo 'inv-base'; exit 0 ;;

  *) echo "UNHANDLED REMOTE: $remote" >&2; exit 1 ;;
esac
SH
chmod +x "${BIN}/ssh" "${BIN}/timeout" "${BIN}/ssh-keygen"

# run_case <scenario> [extra-args...] -> sets CASE_OUT / CASE_RC
run_case() {
  local scenario="$1"; shift
  rm -f "${STATE}/triggered"
  # ${@+"$@"} is the bash 3.2 / set -u safe way to forward possibly-empty args.
  CASE_OUT="$(
    cd "${REPO}" && \
    PATH="${BIN}:${PATH}" VVR_SCENARIO="${scenario}" VVR_STATE="${STATE}" \
      bash framework/scripts/verify-vault-reload.sh --env dev ${@+"$@"} 2>&1
  )"
  CASE_RC=$?
}

# --- Scenario 1: happy path -> PASS, exit 0 ----------------------------------
test_start "679.1" "happy path prints VERDICT: PASS and exits 0"
run_case pass --poll-timeout 10 --renewal-timeout 30
if [[ "$CASE_RC" -eq 0 ]] && grep -q 'VERDICT: PASS' <<< "$CASE_OUT"; then
  test_pass "PASS verdict on stdout, exit 0"
else
  test_fail "expected PASS/exit0; got rc=${CASE_RC}, out:
${CASE_OUT}"
fi

# --- Scenario 2: #642 reload failure -> FAIL, non-zero -----------------------
test_start "679.2" "reload-never-served prints VERDICT: FAIL and exits non-zero"
run_case reload_broken --poll-timeout 10 --renewal-timeout 30
if [[ "$CASE_RC" -ne 0 ]] && grep -q 'VERDICT: FAIL' <<< "$CASE_OUT"; then
  test_pass "FAIL verdict on stdout, exit ${CASE_RC}"
else
  test_fail "expected FAIL/non-zero; got rc=${CASE_RC}, out:
${CASE_OUT}"
fi

# --- Scenario 3: VM unreachable mid-trigger -> INCOMPLETE, non-zero ----------
# This is the core #679 case: the script aborts partway with no deliberate
# verdict. The fail-closed trap MUST convert that into a loud INCOMPLETE.
test_start "679.3" "unreachable-mid-trigger prints VERDICT: INCOMPLETE and exits non-zero"
run_case unreachable --poll-timeout 10 --renewal-timeout 30
if [[ "$CASE_RC" -ne 0 ]] && grep -q 'VERDICT: INCOMPLETE' <<< "$CASE_OUT"; then
  test_pass "INCOMPLETE verdict on stdout, exit ${CASE_RC}"
else
  test_fail "expected INCOMPLETE/non-zero; got rc=${CASE_RC}, out:
${CASE_OUT}"
fi

# The same case must NEVER print a PASS verdict (silent false-success guard).
test_start "679.4" "unreachable path never emits a PASS verdict"
if grep -q 'VERDICT: PASS' <<< "$CASE_OUT"; then
  test_fail "unreachable path emitted VERDICT: PASS — silent false-success!"
else
  test_pass "no PASS verdict on the aborted path"
fi

# --- Scenario 4: renewal never completes within budget -> INCOMPLETE ---------
test_start "679.5" "renewal exceeding --renewal-timeout prints VERDICT: INCOMPLETE, non-zero"
run_case renewal_timeout --poll-timeout 10 --renewal-timeout 30
if [[ "$CASE_RC" -ne 0 ]] && grep -q 'VERDICT: INCOMPLETE' <<< "$CASE_OUT"; then
  test_pass "INCOMPLETE verdict on stdout, exit ${CASE_RC}"
else
  test_fail "expected INCOMPLETE/non-zero; got rc=${CASE_RC}, out:
${CASE_OUT}"
fi

# --- Mutation check: reintroduce the silent-success defect --------------------
# Reproduce the pre-fix masking behavior by replacing the fail-closed EXIT trap
# with one that swallows the exit code to 0 and prints nothing — the exact
# shape of the original defect (an EXIT trap that masked the failure and left
# no verdict). If this test is doing its job, the mutant now silently
# "succeeds" on the aborted path (the scenario 679.3 catches on the real
# script). We assert the mutant IS broken, proving the guard is load-bearing.
#
# Anchoring on the single, stable `trap cleanup_and_verdict EXIT` line (rather
# than the internal multi-line trap body) keeps this robust across refactors of
# the trap function, and we assert the substitution actually applied so a
# future rename fails loudly instead of silently no-op'ing the mutation.
test_start "679.6" "mutation check: a code-swallowing EXIT trap resurrects the silent false-success"
MUT="${REPO}/framework/scripts/verify-vault-reload-mut.sh"
cp "${SCRIPT_SRC}" "$MUT"
sed "s/^trap cleanup_and_verdict EXIT\$/trap 'exit 0' EXIT/" "$MUT" > "${MUT}.tmp" && mv "${MUT}.tmp" "$MUT"

if ! grep -q "^trap 'exit 0' EXIT\$" "$MUT"; then
  test_fail "mutation did not apply: the 'trap cleanup_and_verdict EXIT' anchor was not found — update this test to match the renamed/moved trap install line"
  runner_summary
fi

rm -f "${STATE}/triggered"
MUT_OUT="$(
  cd "${REPO}" && \
  PATH="${BIN}:${PATH}" VVR_SCENARIO=unreachable VVR_STATE="${STATE}" \
    bash framework/scripts/verify-vault-reload-mut.sh --env dev \
      --poll-timeout 10 --renewal-timeout 30 2>&1
)"
MUT_RC=$?
if [[ "$MUT_RC" -eq 0 ]] && ! grep -q 'VERDICT:' <<< "$MUT_OUT"; then
  test_pass "mutant silently exits 0 with no verdict — the fail-closed guard this test protects is real and necessary"
else
  test_fail "mutant should have silently exited 0 with no verdict but did not (rc=${MUT_RC}); the real script's guard may have changed shape:
${MUT_OUT}"
fi

runner_summary
