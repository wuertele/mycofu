#!/usr/bin/env bash
# Sprint 046 R2 — the ORCHESTRATION around the sampler.
#
# This is the privileged half: it clamps `MemoryMax` on the SHARED
# nix-daemon.service. A stranded clamp OOMs every later build on the runner until
# reboot, so the restore contract is what these cases pin:
#
#   - the CAPTURED prior value is restored, never a hardcoded `infinity` (which
#     would clobber any future daemon-level setting; note R5's PRODUCTION backstop
#     is on gitlab-runner.service, not the daemon — this at-floor daemon clamp is a
#     manual, deferred measurement clamp per Deviation D1's measured correction)
#   - the marker file is deleted ONLY after a restore actually succeeds — it is the
#     sole record of the pre-clamp value
#   - a failed restore leaves the marker so the backstop and the next job's heal
#     prelude can retry
#   - the clamp is restored on a SIGNAL, not just on a clean exit
#   - `at-floor` refuses to capture a "prior" while a stranded clamp survives
#     (it would record the CLAMP as the prior and make it permanent)
#
# Everything is driven through systemctl/nix/journalctl shims, so no daemon is
# touched.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
ORCH="${REPO_ROOT}/framework/scripts/measure-build-orchestrate.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/measure-orch.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
cd "${TMP}"

# --- shims -------------------------------------------------------------------
# systemctl: records every call, serves `show -p MemoryMax` from a state file, and
# fails set-property when FAIL_SET_PROPERTY is set (the transient-systemd case).
mk_systemctl() {
  cat > "${TMP}/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${SHIM_LOG}"
case "$1" in
  show)
    cat "${SHIM_STATE}" 2>/dev/null || echo infinity
    ;;
  set-property)
    if [[ -n "${FAIL_SET_PROPERTY:-}" ]]; then exit 1; fi
    for a in "$@"; do
      case "$a" in MemoryMax=*) printf '%s\n' "${a#MemoryMax=}" > "${SHIM_STATE}" ;; esac
    done
    ;;
esac
exit 0
EOF
  chmod +x "${TMP}/systemctl"
}

mk_nix() {  # $1: exit code for the MEASURED build ("0" = success)
  cat > "${TMP}/nix" <<EOF
#!/usr/bin/env bash
echo "nix \$*" >> "\${SHIM_LOG}"
case "\$1" in
  # evict_output resolves the output path with a pure eval, then deletes it. Print
  # a REAL temp file so evict_output sees it exists and proceeds to 'store delete'.
  eval)  p="\$(mktemp)"; printf '%s\n' "\$p"; exit 0 ;;
  store) exit 0 ;;
esac
# the measured build carries --print-build-logs (evict/eval/store do not)
for a in "\$@"; do [[ "\$a" == "--print-build-logs" ]] && exit ${1}; done
exit 0
EOF
  chmod +x "${TMP}/nix"
}

mk_journalctl() {  # $1: text the kernel log should contain
  cat > "${TMP}/journalctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "${1}"
EOF
  chmod +x "${TMP}/journalctl"
}

# sampler: writes the JSON the orchestrator consumes, honours --preflight
mk_sampler() {  # $1=peak_anon_mib  $2=preflight exit code  $3=sampler exit code
  cat > "${TMP}/sampler" <<EOF
#!/usr/bin/env bash
echo "sampler \$*" >> "\${SHIM_LOG}"
for a in "\$@"; do [[ "\$a" == "--preflight" ]] && exit ${2}; done
out=""
while [[ \$# -gt 0 ]]; do
  [[ "\$1" == "--out" ]] && out="\$2"
  shift
done
[[ -n "\$out" ]] && printf '%s' '{"peak_anon_mib": ${1}, "anon_available": true, "valid": true}' > "\$out"
exit ${3}
EOF
  chmod +x "${TMP}/sampler"
}

run_at_floor() {  # sets STATUS; args are env overrides already exported
  set +e
  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" \
  MYCOFU_SYSTEMCTL="${TMP}/systemctl" MYCOFU_NIX="${TMP}/nix" \
  MYCOFU_JOURNALCTL="${TMP}/journalctl" MYCOFU_SAMPLER="${TMP}/sampler" \
  MYCOFU_OUT_DIR="${TMP}/out" PRIOR_MEMORY_MAX_FILE="${MARKER}" \
  MEASURE_FLOOR_MB="${FLOOR:-8192}" MEASURE_OS_RESERVE_MB="1024" \
  MEASURE_ROLE="gitlab" MEASURE_MAX_BASELINE_MIB="1024" \
  MEASURE_NIX_FLAGS="" \
  FAIL_SET_PROPERTY="${FAIL_SET_PROPERTY:-}" \
    bash "${ORCH}" at-floor > "${OUT}" 2> "${ERR}"
  STATUS=$?
  set -e
}

reset() {
  LOG="${TMP}/log"; STATE="${TMP}/state"; MARKER="${TMP}/marker"
  OUT="${TMP}/out.txt"; ERR="${TMP}/err.txt"
  rm -rf "${TMP}/out" "${LOG}" "${STATE}" "${MARKER}" "${OUT}" "${ERR}"
  mkdir -p "${TMP}/out" build
  printf 'infinity\n' > "${STATE}"
  unset FAIL_SET_PROPERTY
}

# --- 1. happy path: clamp applied, then the CAPTURED prior restored ------------
test_clamp_and_restore() {
  reset; mk_systemctl; mk_nix 0; mk_journalctl ""; mk_sampler 4096 0 0
  printf '8G\n' > "${STATE}"     # a pre-existing daemon MemoryMax is captured as the prior (R5's real backstop is on gitlab-runner.service)
  run_at_floor
  (( STATUS == 0 )) || fail "at-floor failed on the happy path (rc=${STATUS}): $(cat "${ERR}")"
  grep -qF 'set-property --runtime nix-daemon.service MemoryMax=7168M' "${LOG}" \
    || fail "the daemon was never clamped to floor-reserve"
  grep -qF 'set-property --runtime nix-daemon.service MemoryMax=8G' "${LOG}" \
    || fail "the CAPTURED prior (8G) was not restored"
  ! grep -qF 'MemoryMax=infinity' "${LOG}" \
    || fail "a hardcoded 'infinity' was written — that undoes the captured-value restore (and could clobber a future daemon setting)"
  [[ "$(cat "${STATE}")" == "8G" ]] || fail "final MemoryMax is '$(cat "${STATE}")', expected the pre-job 8G"
  [[ ! -f "${MARKER}" ]] || fail "the marker survived a successful restore"
  grep -q 'PASS:' "${OUT}" || fail "no PASS verdict on a build that fit the budget"
  # #571: the measured build is forced real by EVICTING the output, not by
  # --rebuild (which fails the determinism check on the non-reproducible image).
  grep -q 'nix store delete' "${LOG}" \
    || fail "evict_output did not delete the cached output before the measured build"
  ! grep -q 'build --rebuild' "${LOG}" \
    || fail "the measured build still uses --rebuild — #571 requires eviction + a plain build"
  ok "the clamp is applied and the CAPTURED prior MemoryMax is restored (never a blind 'infinity')"
  ok "#571: the measured build is forced real by output eviction, not --rebuild"
}

# --- 2. a FAILED restore keeps the marker (it is the only record) --------------
test_failed_restore_keeps_marker() {
  reset; mk_systemctl; mk_nix 0; mk_journalctl ""; mk_sampler 4096 0 0
  printf '8G\n' > "${STATE}"
  # set-property fails everywhere: the clamp never lands, and the restore cannot
  # either — the marker must survive so the backstop/next heal can retry.
  FAIL_SET_PROPERTY=1 run_at_floor
  [[ -f "${MARKER}" ]] \
    || fail "a FAILED restore deleted the marker — the pre-clamp value is now unrecoverable and the daemon may stay clamped"
  [[ "$(cat "${MARKER}")" == "8G" ]] || fail "the marker does not hold the captured prior"
  grep -qi 'FAILED to restore' "${ERR}" || fail "a failed restore was not reported loudly"
  ok "a failed restore keeps the marker so the backstop and the next heal can retry"
}

# --- 3. the restore fires on a SIGNAL, not only on a clean exit ----------------
# A cancelled CI job is exactly when a clamp gets stranded.
test_restore_on_signal() {
  reset; mk_systemctl; mk_journalctl ""; mk_sampler 4096 0 0
  printf '8G\n' > "${STATE}"
  # the measured build hangs; we TERM the orchestrator mid-clamp
  cat > "${TMP}/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix $*" >> "${SHIM_LOG}"
for a in "$@"; do [[ "$a" == "--print-build-logs" ]] && sleep 30; done
exit 0
EOF
  chmod +x "${TMP}/nix"
  cat > "${TMP}/sampler" <<'EOF'
#!/usr/bin/env bash
echo "sampler $*" >> "${SHIM_LOG}"
for a in "$@"; do [[ "$a" == "--preflight" ]] && exit 0; done
exec "${MYCOFU_NIX}" build --print-build-logs
EOF
  chmod +x "${TMP}/sampler"

  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" \
  MYCOFU_SYSTEMCTL="${TMP}/systemctl" MYCOFU_NIX="${TMP}/nix" \
  MYCOFU_JOURNALCTL="${TMP}/journalctl" MYCOFU_SAMPLER="${TMP}/sampler" \
  MYCOFU_OUT_DIR="${TMP}/out" PRIOR_MEMORY_MAX_FILE="${MARKER}" \
  MEASURE_FLOOR_MB=8192 MEASURE_OS_RESERVE_MB=1024 MEASURE_ROLE=gitlab \
  MEASURE_MAX_BASELINE_MIB=1024 MEASURE_NIX_FLAGS="" \
    bash "${ORCH}" at-floor > "${OUT}" 2> "${ERR}" &
  local pid=$!
  # wait for the clamp to land, then signal
  for _ in $(seq 1 50); do grep -q 'MemoryMax=7168M' "${LOG}" 2>/dev/null && break; sleep 0.1; done
  grep -q 'MemoryMax=7168M' "${LOG}" || { kill "${pid}" 2>/dev/null; fail "the clamp never landed; cannot test the signal path"; }
  kill -TERM "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true

  [[ "$(cat "${STATE}")" == "8G" ]] \
    || fail "after SIGTERM the daemon is left at '$(cat "${STATE}")' — a stranded clamp OOMs every later build"
  [[ ! -f "${MARKER}" ]] || fail "the marker survived a successful signal-path restore"
  ok "a SIGTERM (a cancelled job) still restores the clamp"
}

# --- 4. heal: clears a clamp stranded by a SIGKILLed run -----------------------
test_heal() {
  reset; mk_systemctl
  printf '7168M\n' > "${STATE}"   # daemon is still clamped
  printf '8G\n' > "${MARKER}"     # ... and the pre-clamp value survives here
  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" MYCOFU_SYSTEMCTL="${TMP}/systemctl" \
    PRIOR_MEMORY_MAX_FILE="${MARKER}" bash "${ORCH}" heal > "${OUT}" 2>&1
  [[ "$(cat "${STATE}")" == "8G" ]] || fail "heal did not restore the stranded clamp (state=$(cat "${STATE}"))"
  [[ ! -f "${MARKER}" ]] || fail "heal did not clear the marker after a successful restore"
  ok "heal clears a clamp stranded by a SIGKILLed run"

  # no marker => strict no-op (this runs before every ordinary build:image job)
  reset; mk_systemctl
  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" MYCOFU_SYSTEMCTL="${TMP}/systemctl" \
    PRIOR_MEMORY_MAX_FILE="${MARKER}" bash "${ORCH}" heal >/dev/null 2>&1
  [[ ! -s "${LOG}" ]] || fail "heal touched systemctl with no clamp outstanding: $(cat "${LOG}")"
  ok "heal is a strict no-op on an ordinary build (no marker => no systemctl call)"

  # A failed heal must NOT delete the marker, and must NOT fail the job: heal is a
  # before_script on EVERY build:image job. If it exited non-zero on the exact
  # runner state it exists to survive (a clamp set-property cannot clear), it would
  # turn a degraded-but-working runner into a fully blocked one — every build red
  # before it builds anything.
  reset; mk_systemctl
  printf '7168M\n' > "${STATE}"; printf '8G\n' > "${MARKER}"
  set +e
  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" MYCOFU_SYSTEMCTL="${TMP}/systemctl" \
    FAIL_SET_PROPERTY=1 PRIOR_MEMORY_MAX_FILE="${MARKER}" bash "${ORCH}" heal >/dev/null 2>&1
  local rc=$?
  set -e
  (( rc == 0 )) || fail "a failed heal exited ${rc} — it is a before_script on every build:image job, so it must never fail the job"
  [[ -f "${MARKER}" ]] || fail "a FAILED heal deleted the marker — the pre-clamp value is lost"
  ok "a failed heal keeps the marker and does not fail the job"
}

# --- 4c. peak-rss: one role's stumble must not abandon the rest ----------------
# The run happens in a coordinated idle window that is expensive to re-open.
test_peak_rss_continues_past_a_failed_role() {
  reset; mk_systemctl; mk_nix 0; mk_journalctl ""
  # sampler: fails for 'vault', succeeds otherwise
  cat > "${TMP}/sampler" <<'EOF'
#!/usr/bin/env bash
echo "sampler $*" >> "${SHIM_LOG}"
role=""; out=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--role" ]] && role="$2"
  [[ "$1" == "--out" ]] && out="$2"
  shift
done
[[ "$role" == "vault" ]] && exit 1
[[ -n "$out" ]] && printf '%s' '{"peak_anon_mib": 4096, "anon_available": true, "valid": true}' > "$out"
exit 0
EOF
  chmod +x "${TMP}/sampler"

  set +e
  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" MYCOFU_SYSTEMCTL="${TMP}/systemctl" \
  MYCOFU_NIX="${TMP}/nix" MYCOFU_SAMPLER="${TMP}/sampler" MYCOFU_OUT_DIR="${TMP}/out" \
  MEASURE_ROLES="dns vault gitlab" MEASURE_NIX_FLAGS="" \
  MEASURE_MAX_BASELINE_MIB=1024 PRIOR_MEMORY_MAX_FILE="${MARKER}" \
    bash "${ORCH}" peak-rss > "${OUT}" 2> "${ERR}"
  local rc=$?
  set -e

  (( rc != 0 )) || fail "peak-rss reported success despite a role that failed to measure"
  local attempted
  attempted="$(grep -c -- '--role' "${LOG}")"
  (( attempted == 3 )) || fail "only ${attempted}/3 roles were attempted — one role's stumble abandoned the rest of the idle window"
  grep -qF "MEASURE_ROLES='vault'" "${ERR}" || fail "the re-run hint must name exactly the failed role(s)"
  [[ -f "${TMP}/out/dns.json" && -f "${TMP}/out/gitlab.json" ]] \
    || fail "the surviving per-role JSONs were not written"
  ok "peak-rss attempts every role and fails at the end, naming the roles to re-run"
}

# --- 4d. peak-rss refuses to publish a ranking of vacuous zeros ----------------
test_peak_rss_refuses_vacuous_anon() {
  reset; mk_systemctl; mk_nix 0; mk_journalctl ""
  cat > "${TMP}/sampler" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do [[ "$1" == "--out" ]] && out="$2"; shift; done
# the kernel does not export `anon`: the sampler still succeeds, but peak_anon_mib is 0
[[ -n "$out" ]] && printf '%s' '{"peak_anon_mib": 0, "anon_available": false, "valid": true}' > "$out"
exit 0
EOF
  chmod +x "${TMP}/sampler"

  set +e
  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" MYCOFU_SYSTEMCTL="${TMP}/systemctl" \
  MYCOFU_NIX="${TMP}/nix" MYCOFU_SAMPLER="${TMP}/sampler" MYCOFU_OUT_DIR="${TMP}/out" \
  MEASURE_ROLES="dns" MEASURE_NIX_FLAGS="" MEASURE_MAX_BASELINE_MIB=1024 \
  PRIOR_MEMORY_MAX_FILE="${MARKER}" \
    bash "${ORCH}" peak-rss > "${OUT}" 2> "${ERR}"
  local rc=$?
  set -e

  (( rc != 0 )) || fail "peak-rss published a ranking of zeros as if it were a ranking"
  grep -qF 'must NOT be chosen from this artifact' "${ERR}" \
    || fail "the refusal does not warn that the floor cannot be chosen from this artifact"
  ok "peak-rss refuses to publish a peak_anon_mib ranking when anon is unavailable"
}

# --- 4b. restore-backstop: the after_script path, exercised for real -----------
# The trap is the PRIMARY restore; this is the backstop for the paths where the
# trap did not fire. A static grep cannot tell whether `rm -f marker` sits inside
# the success branch or after the `fi` — and outside it, a FAILED backstop restore
# would delete the sole record of the pre-clamp value while the daemon stays
# clamped. So drive it.
test_restore_backstop() {
  reset; mk_systemctl
  printf '7168M\n' > "${STATE}"   # the trap never ran: daemon still clamped
  printf '8G\n' > "${MARKER}"     # ... and the captured prior survives here
  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" MYCOFU_SYSTEMCTL="${TMP}/systemctl" \
    PRIOR_MEMORY_MAX_FILE="${MARKER}" bash "${ORCH}" restore-backstop > "${OUT}" 2>&1
  [[ "$(cat "${STATE}")" == "8G" ]] \
    || fail "the backstop did not restore the captured prior (state=$(cat "${STATE}"))"
  ! grep -qF 'MemoryMax=infinity' "${LOG}" \
    || fail "the backstop wrote a hardcoded 'infinity' — that undoes the captured-value restore (and could clobber a future daemon setting)"
  [[ ! -f "${MARKER}" ]] || fail "the backstop did not clear the marker after a successful restore"

  # No marker => nothing outstanding => strict no-op (it runs on EVERY at-floor run,
  # including the ones where the trap already restored).
  reset; mk_systemctl
  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" MYCOFU_SYSTEMCTL="${TMP}/systemctl" \
    PRIOR_MEMORY_MAX_FILE="${MARKER}" bash "${ORCH}" restore-backstop >/dev/null 2>&1
  [[ ! -s "${LOG}" ]] || fail "the backstop touched systemctl with no clamp outstanding: $(cat "${LOG}")"

  # A FAILED backstop restore must KEEP the marker (the next heal retries from it)
  # and must not fail the job (it runs as after_script).
  reset; mk_systemctl
  printf '7168M\n' > "${STATE}"; printf '8G\n' > "${MARKER}"
  set +e
  SHIM_LOG="${LOG}" SHIM_STATE="${STATE}" MYCOFU_SYSTEMCTL="${TMP}/systemctl" \
    FAIL_SET_PROPERTY=1 PRIOR_MEMORY_MAX_FILE="${MARKER}" bash "${ORCH}" restore-backstop > "${OUT}" 2> "${ERR}"
  local rc=$?
  set -e
  (( rc == 0 )) || fail "a failed backstop restore must not fail the job (it is an after_script), rc=${rc}"
  [[ -f "${MARKER}" ]] \
    || fail "a FAILED backstop restore deleted the marker — the pre-clamp value is now unrecoverable and the daemon stays clamped"
  [[ "$(cat "${MARKER}")" == "8G" ]] || fail "the retained marker no longer holds the captured prior"
  grep -qi 'backstop restore FAILED' "${ERR}" || fail "a failed backstop restore was not reported loudly"
  ok "restore-backstop restores the captured value, no-ops when nothing is outstanding, and keeps the marker when it fails"
}

# --- 5. at-floor refuses to capture a 'prior' while a clamp is stranded --------
# Capturing now would record the CLAMPED value as the prior and make it permanent.
test_refuses_to_capture_a_clamped_prior() {
  reset; mk_systemctl; mk_nix 0; mk_journalctl ""; mk_sampler 4096 0 0
  printf '7168M\n' > "${STATE}"
  printf '8G\n' > "${MARKER}"     # heal could not clear it
  run_at_floor
  (( STATUS != 0 )) || fail "at-floor ran with a stranded clamp — it would record the CLAMP as the prior"
  grep -qi 'would record the CLAMPED value' "${ERR}" || fail "the refusal does not explain itself"
  [[ "$(cat "${MARKER}")" == "8G" ]] || fail "the refusal clobbered the surviving prior value"
  ok "at-floor refuses to capture a 'prior' while a stranded clamp survives"
}

# --- 6. the idle preflight runs BEFORE the clamp ------------------------------
test_preflight_before_clamp() {
  reset; mk_systemctl; mk_nix 0; mk_journalctl ""; mk_sampler 4096 1 0   # preflight FAILS
  run_at_floor
  (( STATUS != 0 )) || fail "at-floor proceeded despite a failed idle preflight"
  ! grep -q 'MemoryMax=7168M' "${LOG}" \
    || fail "the SHARED daemon was clamped before the idle preflight passed — that OOM-kills a concurrent build"
  [[ ! -f "${MARKER}" ]] || fail "a marker was written even though no clamp was applied"
  ok "the idle preflight refuses BEFORE the shared daemon is touched"
}

# --- 7. OOM vs unrelated build failure: the verdicts must not be conflated -----
test_oom_verdict() {
  reset; mk_systemctl; mk_nix 0; mk_sampler 4096 0 1   # the measured build FAILS
  mk_journalctl "kernel: Out of memory: Killed process 123 (nix)"
  run_at_floor
  (( STATUS != 0 )) || fail "a failed build under the clamp reported success"
  grep -qi 'is NOT a capability floor' "${ERR}" || fail "an OOM did not produce the not-a-floor verdict"
  [[ "$(cat "${STATE}")" == "infinity" ]] || fail "the clamp was not restored after a failed build"

  reset; mk_systemctl; mk_nix 0; mk_sampler 4096 0 1
  mk_journalctl "kernel: nothing interesting here"
  run_at_floor
  (( STATUS != 0 )) || fail "a failed build reported success"
  grep -qi 'NO OOM in the kernel log' "${ERR}" \
    || fail "an unrelated build failure was not distinguished from an OOM — it would reject a sound floor"
  ok "an OOM and an unrelated build failure produce different verdicts, and both restore the clamp"
}

# --- 8. a build that fits the daemon clamp but busts the BUDGET fails ----------
# The clamp bounds the daemon only; the evaluator's memory lives in the runner cgroup.
test_budget_assertion() {
  reset; mk_systemctl; mk_nix 0; mk_journalctl ""; mk_sampler 9000 0 0   # peak > 7168 budget
  run_at_floor
  (( STATUS != 0 )) || fail "a daemon+runner peak above the budget was certified as a capability floor"
  grep -qi 'EXCEEDS the 7168 MiB budget' "${ERR}" || fail "the budget verdict does not name the overage"
  [[ "$(cat "${STATE}")" == "infinity" ]] || fail "the clamp was not restored after the budget failure"
  ok "a completed build whose daemon+runner peak busts the budget is NOT certified"
}

# --- 9. the CI jobs are thin: the orchestration is not inline any more ---------
test_ci_jobs_are_thin() {
  local ci="${REPO_ROOT}/.gitlab-ci.yml" job body
  for job in "measure:build-peak-rss" "measure:build-at-floor"; do
    body="$(J="${job}" yq -r '.[strenv(J)].script[]' "${ci}")"
    grep -qF 'measure-build-orchestrate.sh' <<< "${body}" \
      || fail "${job} does not call the orchestrator"
    ! grep -qF 'systemctl set-property' <<< "${body}" \
      || fail "${job} still clamps the daemon inline — the privileged logic belongs in the script, where it is testable"
    (( $(grep -vcE '^\s*(#|$)' <<< "${body}") <= 2 )) \
      || fail "${job}'s script is not thin: $(grep -cvE '^\s*(#|$)' <<< "${body}") code lines"
  done
  grep -qF 'measure-build-orchestrate.sh restore-backstop' \
    <<< "$(yq -r '.["measure:build-at-floor"].after_script[]' "${ci}")" \
    || fail "the after_script backstop must call the orchestrator"
  ok "both measure: jobs are thin callers; the orchestration lives in the script"
}

test_clamp_and_restore
test_failed_restore_keeps_marker
test_restore_on_signal
test_heal
test_peak_rss_continues_past_a_failed_role
test_peak_rss_refuses_vacuous_anon
test_restore_backstop
test_refuses_to_capture_a_clamped_prior
test_preflight_before_clamp
test_oom_verdict
test_budget_assertion
test_ci_jobs_are_thin
