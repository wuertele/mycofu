#!/usr/bin/env bash
# Sprint 046 R2 / Deviation D1.
#
# The sampler exists because cicd runs Nix in multi-user DAEMON mode: an image
# build's memory lives in system.slice/nix-daemon.service, not in the CI job's
# cgroup. Every case below is written so that a WRONG implementation fails it:
#
#   - samples the job/runner cgroup only          -> case 1 (peak would be ~256 MiB)
#   - reports the first or the last sample        -> case 1 (peak would be 1 or 2 GiB)
#   - reads the decoy cgroup                      -> case 1 (peak would be 99 GiB)
#   - fails OPEN when a cgroup is missing         -> cases 2 and 3
#   - reports the daemon at idle as a build peak  -> case 4 (the warm-store trap)
#   - measures page cache and calls it RSS        -> case 5 (anon is reported apart)
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/framework/scripts/measure-build-peak-rss.sh"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"
# The CI-side orchestration (clamp / restore / heal / preflight) moved OUT of
# .gitlab-ci.yml into this script, so the ratchets below follow it there. The jobs
# are now thin callers; tests/test_measure_build_orchestrate.sh exercises the moved
# logic behaviorally, and these are the static guards on it.
ORCH="${REPO_ROOT}/framework/scripts/measure-build-orchestrate.sh"

# The body of one shell function, comments stripped — so a ratchet cannot be
# satisfied by a comment that merely mentions the thing it demands.
fn_body() {  # $1=function name
  awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\) \\{" { inside = 1; next }
    inside && /^}/ { exit }
    inside { print }
  ' "${ORCH}" | grep -vE '^[[:space:]]*#'
}

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/measure-rss-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

mib() { printf '%s\n' "$(( $1 * 1024 * 1024 ))"; }

# A fixture cgroup: memory.current always; memory.stat (with anon) only when a
# fourth argument is given, so the memory.stat-absent fallback is also exercised.
make_cgroup() {  # $1=root $2=service $3=current_mib [$4=anon_mib]
  local dir="$1/system.slice/$2"
  mkdir -p "${dir}"
  mib "$3" > "${dir}/memory.current"
  if [[ -n "${4:-}" ]]; then
    { echo "anon $(mib "$4")"; echo "file $(mib "$3")"; echo "kernel 0"; } > "${dir}/memory.stat"
  fi
}

run_capture() {  # $1=stdout $2=stderr ...cmd; sets STATUS
  local out="$1" err="$2"; shift 2
  set +e
  "$@" >"${out}" 2>"${err}"
  STATUS=$?
  set -e
}

yq '.' "${CI_FILE}" >/dev/null 2>&1 || fail ".gitlab-ci.yml failed yq parse"

# --- Case 1: the peak is the MAX over samples, from the DAEMON cgroup ----------
test_peak_is_daemon_max() {
  local fix="${TMP_DIR}/case1" out="${TMP_DIR}/case1.json"
  make_cgroup "${fix}" nix-daemon.service 1024
  make_cgroup "${fix}" gitlab-runner.service 256
  make_cgroup "${fix}" some-other.service $((99 * 1024))   # decoy: must never be read

  # The daemon's memory.current rises to 9 GiB mid-run, then falls back to 2 GiB.
  # The plateau is held ~2s so a scheduling stall on a loaded runner cannot make
  # the sampler skip it (0.1s interval => ~20 samples across the plateau).
  MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" \
    --role gitlab --interval 0.1 --out "${out}" -- \
    bash -c '
      d="${1}/system.slice/nix-daemon.service/memory.current"
      printf "%s\n" "$((1 * 1024 * 1024 * 1024))" > "$d"; sleep 0.5
      printf "%s\n" "$((9 * 1024 * 1024 * 1024))" > "$d"; sleep 2
      printf "%s\n" "$((2 * 1024 * 1024 * 1024))" > "$d"; sleep 0.5
    ' bash "${fix}" >/dev/null

  local peak nix_peak runner_peak samples
  peak="$(jq -r .peak_mib "${out}")"
  nix_peak="$(jq -r .nix_daemon_peak_mib "${out}")"
  runner_peak="$(jq -r .runner_peak_mib "${out}")"
  samples="$(jq -r .samples "${out}")"

  (( samples >= 5 )) || fail "only ${samples} samples taken; the sampler is not sampling"
  (( nix_peak >= 9216 )) || fail "nix-daemon peak ${nix_peak} MiB missed the 9 GiB plateau (first/last-sample bug?)"
  (( nix_peak < 99 * 1024 )) || fail "nix-daemon peak ${nix_peak} MiB includes the decoy cgroup"
  (( runner_peak >= 256 )) || fail "runner peak ${runner_peak} MiB did not see the runner cgroup"
  (( peak >= 9216 + 256 )) || fail "sum peak ${peak} MiB is not daemon+runner"
  (( peak > 4096 )) || fail "sum peak ${peak} MiB looks like a runner-only or single-sample measurement"
  (( peak < 99 * 1024 )) || fail "sum peak ${peak} MiB includes the decoy cgroup"
  ok "peak is max-over-samples of nix-daemon + runner, and ignores unrelated cgroups"
}

# --- Case 2: no daemon cgroup => FAIL CLOSED (never a runner-only floor) -------
test_fail_closed_without_daemon() {
  local fix="${TMP_DIR}/case2" out="${TMP_DIR}/case2.json"
  make_cgroup "${fix}" gitlab-runner.service 256
  mkdir -p "${fix}"; : > "${fix}/cgroup.controllers"

  local marker="${TMP_DIR}/case2.ran"
  run_capture "${TMP_DIR}/c2.out" "${TMP_DIR}/c2.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --role gitlab --interval 0.05 --out "${out}" -- bash -c "touch '${marker}'"

  (( STATUS != 0 )) || fail "sampler exited 0 with no nix-daemon cgroup"
  grep -qi 'nix-daemon' "${TMP_DIR}/c2.err" || fail "fail-closed message does not name the nix-daemon cgroup"
  [[ ! -e "${marker}" ]] || fail "the build RAN even though it could never have been measured — refuse up front, do not burn the idle window"
  [[ ! -f "${out}" ]] || fail "sampler wrote a JSON result for a measurement it could not make"
  ok "missing nix-daemon cgroup fails closed, before the build runs"
}

# --- Case 3: no runner cgroup => FAIL CLOSED unless explicitly allowed ---------
# The nix EVALUATOR runs in the job shell (runner cgroup) and is a real term of
# the floor. Dropping it silently would understate the floor.
test_fail_closed_without_runner() {
  local fix="${TMP_DIR}/case3" out="${TMP_DIR}/case3.json"
  make_cgroup "${fix}" nix-daemon.service 1024
  local cmd='d="'"${fix}"'/system.slice/nix-daemon.service/memory.current"; printf "%s\n" "$((6 * 1024 * 1024 * 1024))" > "$d"; sleep 0.3'

  run_capture "${TMP_DIR}/c3.out" "${TMP_DIR}/c3.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --role gitlab --interval 0.05 --out "${out}" -- bash -c "${cmd}"
  (( STATUS != 0 )) || fail "sampler exited 0 with no runner cgroup (runner term silently 0)"
  grep -qi 'runner' "${TMP_DIR}/c3.err" || fail "fail-closed message does not name the runner cgroup"
  [[ ! -f "${out}" ]] || fail "sampler wrote a JSON result despite refusing the measurement"

  # Reset the fixture: the first run left memory.current at 6 GiB, which would be
  # read as the baseline of the second run (and trip the activity gate).
  make_cgroup "${fix}" nix-daemon.service 1024
  run_capture "${TMP_DIR}/c3b.out" "${TMP_DIR}/c3b.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --role gitlab --interval 0.05 --allow-missing-runner-cgroup \
      --out "${out}" -- bash -c "${cmd}"
  (( STATUS == 0 )) || fail "--allow-missing-runner-cgroup did not permit the run (rc=${STATUS}): $(cat "${TMP_DIR}/c3b.err")"
  ok "missing runner cgroup fails closed, and the opt-out is explicit"
}

# --- Case 4: THE WARM-STORE TRAP ----------------------------------------------
# A `nix build` against a warm store spawns no builder and returns in seconds.
# The daemon then sits at its idle working set. A sampler that reports THAT as
# the build's peak hands back a floor several GiB too low, and looks green doing
# it. The activity gate must refuse.
test_fail_closed_on_no_build_activity() {
  local fix="${TMP_DIR}/case4" out="${TMP_DIR}/case4.json"
  make_cgroup "${fix}" nix-daemon.service 1024 300     # flat: no build happens
  make_cgroup "${fix}" gitlab-runner.service 256 128

  run_capture "${TMP_DIR}/c4.out" "${TMP_DIR}/c4.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --role gitlab --interval 0.05 --out "${out}" -- bash -c 'sleep 0.3'

  (( STATUS != 0 )) || fail "sampler reported an idle daemon as a build peak (warm-store no-op accepted)"
  grep -qi 'no build activity' "${TMP_DIR}/c4.err" || fail "activity-gate message does not explain the warm-store no-op"
  grep -qi 'evict' "${TMP_DIR}/c4.err" || fail "activity-gate message does not point at output eviction (#571 — the fix is to evict, not --rebuild)"
  [[ "$(jq -r .delta_mib "${out}")" -eq 0 ]] || fail "delta_mib should be 0 when nothing was built"
  # The job's own failure message invites the operator to use the surviving
  # per-role artifacts. A rejected run must therefore be marked in the file, or an
  # idle-daemon number could be mined out of it later and used as the floor.
  [[ "$(jq -r .valid "${out}")" == "false" ]] || fail "a gate-rejected JSON must be marked valid:false"
  [[ "$(jq -r .invalid_reason "${out}")" == "no-build-activity" ]] || fail "a gate-rejected JSON must record why"
  ok "a no-op build fails closed instead of reporting the daemon at idle, and its JSON is marked invalid"
}

# --- Case 4b: an EVALUATING neighbour contaminates the runner cgroup ------------
# The two heavy nix-eval jobs (validate:nix-checks, validate:per-role-isolation)
# evaluate client-side: they leave the DAEMON idle while charging GiB to the
# RUNNER cgroup. A daemon-only idleness check sails past them, and their memory is
# then charged to every sample — overstating the floor (a phantom OQ1 conflict) or
# falsely rejecting a sound one at the floor test.
test_idleness_gate_sees_a_busy_runner() {
  local fix="${TMP_DIR}/case4b" out="${TMP_DIR}/case4b.json" marker="${TMP_DIR}/case4b.ran"
  make_cgroup "${fix}" nix-daemon.service 200 100         # daemon: idle
  make_cgroup "${fix}" gitlab-runner.service 6000 5000    # runner: a nix eval is running

  run_capture "${TMP_DIR}/c4b.out" "${TMP_DIR}/c4b.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --role gitlab --interval 0.05 \
      --max-baseline-mib 1024 --out "${out}" -- bash -c "touch '${marker}'"

  (( STATUS != 0 )) || fail "an idle daemon with a 5 GiB EVALUATOR next door was accepted as an idle runner"
  grep -qi 'evaluating\|gitlab-runner cgroup' "${TMP_DIR}/c4b.err" \
    || fail "the gate did not explain that a neighbouring nix EVAL contaminates the measurement"
  [[ ! -e "${marker}" ]] || fail "the build ran before the runner-baseline gate refused"
  ok "a busy runner cgroup (client-side nix eval) is refused, not just a busy daemon"
}

# --- Case 5: anon is reported separately from page-cache-inclusive current -----
# memory.current charges page cache to the writing cgroup; an image build writes
# GiB of it. peak_mib is therefore an upper bound and peak_anon_mib is the
# reclaim-resistant term. Both must be present and distinguishable.
test_anon_reported_apart_from_page_cache() {
  local fix="${TMP_DIR}/case5" out="${TMP_DIR}/case5.json"
  make_cgroup "${fix}" nix-daemon.service 1024 256
  make_cgroup "${fix}" gitlab-runner.service 512 128

  MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --role gitlab --interval 0.05 --min-delta-mib 0 --out "${out}" -- \
    bash -c '
      d="${1}/system.slice/nix-daemon.service"
      printf "%s\n" "$((12 * 1024 * 1024 * 1024))" > "$d/memory.current"
      { echo "anon $((5 * 1024 * 1024 * 1024))"; echo "file $((7 * 1024 * 1024 * 1024))"; echo "kernel 0"; } > "$d/memory.stat"
      sleep 0.3
    ' bash "${fix}" >/dev/null

  local peak anon basis
  peak="$(jq -r .peak_mib "${out}")"
  anon="$(jq -r .peak_anon_mib "${out}")"
  basis="$(jq -r .delta_basis "${out}")"
  (( peak >= 12288 )) || fail "peak_mib ${peak} MiB did not track memory.current"
  (( anon >= 5120 && anon < 12288 )) || fail "peak_anon_mib ${anon} MiB is not the anon term (page cache leaked in, or anon not read)"
  [[ "${basis}" == "anon" ]] || fail "delta_basis is '${basis}', expected anon when memory.stat is available"
  [[ "$(jq -r .anon_available "${out}")" == "true" ]] || fail "anon_available should be true"
  ok "page-cache-inclusive peak and reclaim-resistant anon peak are reported apart"
}

# --- Case 5b: the idleness gate refuses BEFORE the command runs ----------------
# A contaminated peak must be refused up front. If the gate only fired afterwards,
# it would burn a full rebuild in a coordinated idle window before saying no — and
# measure:build-at-floor would already have clamped the SHARED nix-daemon,
# OOM-killing whatever else was building.
test_idleness_gate_refuses_before_running() {
  local fix="${TMP_DIR}/case5b" out="${TMP_DIR}/case5b.json" marker="${TMP_DIR}/case5b.ran"
  make_cgroup "${fix}" nix-daemon.service 9000 8000     # busy: another build in flight
  make_cgroup "${fix}" gitlab-runner.service 256 128

  run_capture "${TMP_DIR}/c5b.out" "${TMP_DIR}/c5b.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --role gitlab --interval 0.05 \
      --max-baseline-mib 1024 --out "${out}" -- bash -c "touch '${marker}'"

  (( STATUS != 0 )) || fail "sampler measured a contaminated (non-idle) baseline"
  grep -qi 'not idle' "${TMP_DIR}/c5b.err" || fail "idleness-gate message does not say the runner is not idle"
  [[ ! -e "${marker}" ]] || fail "the command RAN before the idleness gate refused — the gate fires too late to protect a shared-service mutation"
  ok "a non-idle runner is refused before the build (or a shared-service clamp) starts"

  # --preflight: the same gate, with no command at all — what measure:build-at-floor
  # calls before it touches nix-daemon's MemoryMax.
  run_capture "${TMP_DIR}/c5c.out" "${TMP_DIR}/c5c.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --preflight --max-baseline-mib 1024
  (( STATUS != 0 )) || fail "--preflight passed on a busy daemon"

  make_cgroup "${fix}" nix-daemon.service 200 100       # idle
  run_capture "${TMP_DIR}/c5d.out" "${TMP_DIR}/c5d.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --preflight --max-baseline-mib 1024
  (( STATUS == 0 )) || fail "--preflight failed on an idle daemon: $(cat "${TMP_DIR}/c5d.err")"
  ok "--preflight passes when idle and refuses when busy, with no command run"
}

# --- Case 5e: the runner's ANON term cannot be silently dropped ----------------
# peak_anon_mib is the series the floor is chosen from. The evaluator's several GiB
# live in the runner cgroup. A daemon-only anon peak would understate the floor.
test_fail_closed_without_runner_anon() {
  local fix="${TMP_DIR}/case5e" out="${TMP_DIR}/case5e.json"
  make_cgroup "${fix}" nix-daemon.service 1024 256        # daemon HAS memory.stat
  make_cgroup "${fix}" gitlab-runner.service 512          # runner has NO memory.stat

  run_capture "${TMP_DIR}/c5e.out" "${TMP_DIR}/c5e.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --role gitlab --interval 0.05 --min-delta-mib 0 \
      --out "${out}" -- bash -c 'sleep 0.2'

  (( STATUS != 0 )) || fail "sampler reported a daemon-only anon peak as if it were the floor"
  grep -qi 'memory.stat' "${TMP_DIR}/c5e.err" || fail "fail-closed message does not name the runner's memory.stat"
  [[ ! -f "${out}" ]] || fail "sampler wrote a JSON result despite refusing the measurement"
  ok "a missing runner memory.stat fails closed instead of dropping the evaluator's anon memory"
}

# --- Case 6: the wrapped command's exit code propagates ------------------------
test_command_exit_propagates() {
  local fix="${TMP_DIR}/case6" out="${TMP_DIR}/case6.json"
  make_cgroup "${fix}" nix-daemon.service 1024
  make_cgroup "${fix}" gitlab-runner.service 128

  run_capture "${TMP_DIR}/c6.out" "${TMP_DIR}/c6.err" \
    env MEASURE_CGROUP_ROOT="${fix}" "${SCRIPT}" --role cicd --interval 0.05 --out "${out}" -- bash -c 'exit 7'

  (( STATUS == 7 )) || fail "sampler exit ${STATUS}, expected the wrapped command's 7"
  [[ "$(jq -r .exit_code "${out}")" -eq 7 ]] || fail "JSON did not record exit_code 7"
  ok "a failed build fails the job, and its exit code is recorded"
}

# --- Case 7: static D1 ratchets on the sampler ---------------------------------
test_static_script_ratchets() {
  # Ratchets apply to CODE, not to the header comments (which explain precisely
  # why these mechanisms are wrong — D1 — and must be allowed to name them).
  local code
  code="$(grep -vE '^[[:space:]]*#' "${SCRIPT}")"

  grep -qF 'system.slice/nix-daemon.service' <<< "${code}" \
    || fail "sampler no longer targets system.slice/nix-daemon.service"
  ! grep -qF '/usr/bin/time' <<< "${code}" || fail "sampler must not wrap with /usr/bin/time (D1: that measures the RPC client, not the builders)"
  ! grep -qF 'systemd-run'   <<< "${code}" || fail "sampler must not wrap with systemd-run (D1)"
  ! grep -qF 'getrusage'     <<< "${code}" || fail "sampler must not use getrusage-based wrapping (D1)"
  # memory.peak has kernel-version-dependent reset semantics; T2.1 mandates
  # sampling memory.current.
  ! grep -qF 'memory.peak'   <<< "${code}" || fail "sampler must sample memory.current, not memory.peak"
  ok "sampler static D1 ratchets hold"
}

# --- Case 8: a real build is forced, and NOTHING is uploaded to the cluster -----
# build-image.sh ends by calling upload-image.sh, which SCPs the image to every
# Proxmox node. These jobs are runner-local by contract ("no cluster mutation, no
# live experiment"), and an SSH/storage error there would fail the measurement for
# a reason that has nothing to do with memory — while holding the at-floor clamp on
# the shared daemon for the whole upload.
test_measurement_is_runner_local_and_forces_a_real_build() {
  local job flags fn body
  # The orchestrator, not the job, now issues the measured build.
  for fn in cmd_peak_rss cmd_at_floor; do
    body="$(fn_body "${fn}")"
    ! grep -qF 'build-image.sh' <<< "${body}" \
      || fail "${fn} must not run build-image.sh — it uploads the image to every Proxmox node (cluster I/O in a runner-local measurement)"
    grep -qF 'build ${MEASURE_NIX_FLAGS:-}' <<< "${body}" \
      || fail "${fn} must measure a bare 'nix build' (the peak lives in the daemon; everything build-image.sh adds afterwards runs outside it)"
    # #571: the real build is forced by EVICTING the output, not by --rebuild.
    grep -qF 'evict_output' <<< "${body}" \
      || fail "${fn} must evict the cached output first so a plain 'nix build' is forced to build for real (#571)"
  done
  for job in "measure:build-peak-rss" "measure:build-at-floor"; do
    flags="$(J="${job}" yq -r '.[strenv(J)].variables.MEASURE_NIX_FLAGS' "${CI_FILE}")"
    [[ "${flags}" != *"--rebuild"* ]] \
      || fail "${job} must NOT use --rebuild (#571: it fails the determinism check on the non-reproducible image); eviction forces the real build instead"
  done
  ok "the measurement forces a real build (via output eviction, #571) and never touches the cluster"
}

# --- Case 8b: a stranded MemoryMax clamp cannot survive into an ordinary build --
# A SIGKILLed at-floor job runs neither its trap nor its after_script. The clamp on
# the SHARED nix-daemon would then OOM every later build until reboot.
test_stranded_clamp_is_healed() {
  local marker heal job
  marker="$(yq -r '.["measure:build-at-floor"].variables.PRIOR_MEMORY_MAX_FILE' "${CI_FILE}")"
  [[ "${marker}" == /run/* ]] || fail "the clamp marker must live under /run (volatile: a reboot clears both it and the --runtime clamp)"
  grep -qF "${marker}" "${ORCH}" \
    || fail "the orchestrator and the job must agree on the clamp-marker path"

  # Every job that builds THROUGH the daemon heals a stranded clamp first.
  for job in "build:image" "build:image:hil-boot" "measure:build-at-floor"; do
    heal="$(J="${job}" yq -r '.[strenv(J)].before_script[]?' "${CI_FILE}")"
    grep -qF 'measure-build-orchestrate.sh heal' <<< "${heal}" \
      || fail "${job} must heal a stranded nix-daemon clamp before building through the daemon"
  done

  # The marker is the ONLY record of the pre-clamp value: deleting it on a FAILED
  # restore would strand the clamp and destroy the means to undo it. Each restore
  # path must therefore delete it only INSIDE the success branch.
  local at_floor heal_body backstop
  at_floor="$(fn_body cmd_at_floor)"
  heal_body="$(fn_body cmd_heal)"
  backstop="$(fn_body cmd_restore_backstop)"
  grep -qE 'if .*set-property --runtime nix-daemon.service "MemoryMax=\$\{PRIOR_MEMORY_MAX\}"; then' <<< "${at_floor}" \
    || fail "the trap must delete the marker only after the restore SUCCEEDS"
  grep -qE 'if .*set-property --runtime nix-daemon.service "MemoryMax=\$\{prior\}"; then' <<< "${backstop}" \
    || fail "the after_script backstop must delete the marker only after the restore SUCCEEDS"
  grep -qE 'if .*set-property --runtime nix-daemon.service "MemoryMax=\$\{prior\}"; then' <<< "${heal_body}" \
    || fail "the heal prelude must delete the marker only after the restore SUCCEEDS"

  # Capturing MemoryMax while a stale clamp is live would record the CLAMP as the
  # "prior" value and make it permanent.
  grep -qF 'would record the CLAMPED value' <<< "${at_floor}" \
    || fail "at-floor must refuse to capture a 'prior' MemoryMax while a stranded clamp marker survives"
  ok "a stranded MemoryMax clamp is healed, never deepened, and never made permanent"
}

# --- Case 9: the CI jobs cannot auto-run, and cannot strand a memory clamp -----
require_manual_rules() {
  local job="$1" manual disabled
  manual="$(J="${job}" yq -r '
    .[strenv(J)].rules[]
    | select(.if == "$CI_PIPELINE_SOURCE == \"merge_request_event\""
          or .if == "$CI_PIPELINE_SOURCE != \"web\" && $CI_COMMIT_BRANCH == \"dev\""
          or .if == "$CI_PIPELINE_SOURCE != \"web\" && $CI_COMMIT_BRANCH == \"prod\"")
    | .when' "${CI_FILE}" | grep -cx 'manual' || true)"
  (( manual == 3 )) || fail "${job}: MR/dev/prod rules must all be when:manual (found ${manual}) — the heavy run is operator-coordinated, never automatic"
  disabled="$(J="${job}" yq -r '
    .[strenv(J)].rules[]
    | select(.if == "$CI_PIPELINE_SOURCE == \"schedule\" && $RECLAIM_IMAGE_STORE == \"1\"" or .if == "$BENCH_SCHEDULE_KEY")
    | .when' "${CI_FILE}" | grep -cx 'never' || true)"
  (( disabled == 2 )) || fail "${job} must stay disabled on reclaim/benchmark schedules"
}

test_static_ci_ratchets() {
  local job
  for job in "measure:build-peak-rss" "measure:build-at-floor"; do
    [[ "$(J="${job}" yq -r '.[strenv(J)] | tag' "${CI_FILE}")" == "!!map" ]] || fail "${job} is missing"
    require_manual_rules "${job}"
    [[ "$(J="${job}" yq -r '.[strenv(J)].interruptible // "absent"' "${CI_FILE}")" == "absent" ]] \
      || fail "${job} must not set interruptible (auto-cancel mid-build is exactly when the restore is least likely to run)"
  done

  # Its own group, NOT ci-heavy-nix-eval: joining that group would widen the
  # confinement assertion in tests/test_ci_memory_safety_rules.sh, which R5 must
  # still pass unchanged.
  [[ "$(yq -r '.["measure:build-peak-rss"].resource_group' "${CI_FILE}")" == "measure-build-peak-rss" ]] \
    || fail "measure:build-peak-rss must carry its own resource_group"
  [[ "$(yq -r '.["measure:build-at-floor"].resource_group' "${CI_FILE}")" == "measure-build-at-floor" ]] \
    || fail "measure:build-at-floor must carry its own resource_group"

  # The peak job must not pre-judge which role is heaviest — that is its output.
  local roles
  roles="$(yq -r '.["measure:build-peak-rss"].variables.MEASURE_ROLES' "${CI_FILE}")"
  local r
  for r in dns vault gitlab cicd acme-dev gatus testapp influxdb grafana roon; do
    [[ " ${roles} " == *" ${r} "* ]] || fail "MEASURE_ROLES omits '${r}': the heaviest image could go unmeasured and the floor would be set too low"
  done

  # Idleness gate: a contaminated measurement must fail, not silently overstate.
  [[ "$(yq -r '.["measure:build-peak-rss"].variables.MEASURE_MAX_BASELINE_MIB' "${CI_FILE}")" =~ ^[1-9][0-9]*$ ]] \
    || fail "measure:build-peak-rss must set a positive MEASURE_MAX_BASELINE_MIB (the not-idle-runner gate)"

  # The at-floor job mutates a SHARED service. The restore must write back the
  # CAPTURED prior value on EVERY path.
  # These now live in the orchestrator (the jobs are thin callers), so the ratchets
  # follow them there. The at-floor job's after_script still must not carry a
  # hardcoded infinity, and neither may the backstop it calls.
  local floor_script after_script peak_script
  floor_script="$(fn_body cmd_at_floor)"
  after_script="$(fn_body cmd_restore_backstop)"
  peak_script="$(fn_body cmd_peak_rss)"

  grep -qE 'trap [A-Za-z_]+ EXIT' <<< "${floor_script}" \
    || fail "measure:build-at-floor must restore MemoryMax from an in-script trap, not from after_script alone (after_script does not run on every cancel path)"
  grep -qE "trap '.*' INT TERM HUP" <<< "${floor_script}" \
    || fail "measure:build-at-floor must trap INT TERM HUP — a cancelled job is exactly when a clamp gets stranded"
  grep -qE 'PRIOR_MEMORY_MAX="\$\(.*show -p MemoryMax --value nix-daemon.service' <<< "${floor_script}" \
    || fail "measure:build-at-floor must CAPTURE the prior MemoryMax"
  grep -qF 'MemoryMax=${PRIOR_MEMORY_MAX}' <<< "${floor_script}" \
    || fail "measure:build-at-floor's trap must write back the captured value"

  # THE TRAP THAT BIT THE FIRST REWORK: after_script ran a hardcoded
  # `MemoryMax=infinity` on the SUCCESS path, silently undoing the captured-value
  # restore. (R5's PRODUCTION backstop is on gitlab-runner.service, not the daemon —
  # Deviation D1's measured correction; this at-floor daemon clamp is a manual,
  # deferred measurement clamp. A blind infinity could still clobber a future
  # daemon-level setting and always undoes the captured-value restore.)
  ! grep -qF 'MemoryMax=infinity' <<< "${after_script}" \
    || fail "the after_script backstop must not write a hardcoded MemoryMax=infinity — it would undo the captured-value restore"
  ! grep -qF 'MemoryMax=infinity' <<< "$(yq -r '.["measure:build-at-floor"].after_script[]' "${CI_FILE}")" \
    || fail "measure:build-at-floor's after_script must not write a hardcoded MemoryMax=infinity"
  grep -qF 'MemoryMax=${prior}' <<< "${after_script}" \
    || fail "the after_script backstop must restore the CAPTURED value"
  # A RESTORE PATH MUST NOT ITSELF FAIL. This ratchet moved with the logic: the
  # backstop runs as after_script, and heal runs as before_script on every
  # build:image job — a heal that exits non-zero on a stranded clamp would turn a
  # degraded runner into a fully blocked one.
  grep -qE '^[[:space:]]*return 0[[:space:]]*$' <<< "${after_script}" \
    || fail "the after_script backstop must end 'return 0' — it must not fail the job"
  grep -qE 'rm -f .*\|\| true' <<< "${after_script}" \
    || fail "the backstop's marker delete must not fail the job"
  grep -qE '^[[:space:]]*return 0[[:space:]]*$' <<< "$(fn_body cmd_heal)" \
    || fail "the heal prelude must end 'return 0' — it is a before_script on every build:image job"

  # Preflight BEFORE the shared-service mutation: clamping the daemon while
  # another pipeline is building would OOM-kill that build.
  grep -qF -- '--preflight' <<< "${floor_script}" \
    || fail "measure:build-at-floor must preflight the idle check BEFORE it clamps the shared nix-daemon"
  [[ "$(printf '%s' "${floor_script}" | grep -n -- '--preflight' | head -1 | cut -d: -f1)" -lt \
     "$(printf '%s' "${floor_script}" | grep -n 'set-property --runtime nix-daemon.service "MemoryMax=\${daemon_max_mb}M"' | head -1 | cut -d: -f1)" ]] \
    || fail "the preflight must come BEFORE the clamp, not after"

  # A completed build under a DAEMON-only clamp does not prove the floor: the
  # evaluator's memory lives in the runner cgroup and is unbounded by it.
  grep -qF 'peak_anon > budget' <<< "${floor_script}" \
    || fail "measure:build-at-floor must assert the measured daemon+runner peak fits the floor budget, not just that the build completed"
  # An unrelated build failure must not be reported as an OOM verdict (and vice versa).
  grep -qiF 'oom-kill' <<< "${floor_script}" \
    || fail "measure:build-at-floor must distinguish an OOM from an unrelated build failure before pronouncing on the floor"

  # #571: --rebuild makes nix REBUILD AND COMPARE, and image derivations
  # (make-disk-image → qcow2) are non-bit-reproducible, so the compare fails the run
  # for a non-memory reason (in at-floor, indistinguishable from the OOM it hunts) —
  # even with `enforce-determinism false`, which does not reliably downgrade it. The
  # fix is to force the real build by EVICTING the output, not by --rebuild. Neither
  # flag may reappear in the job variables.
  local job_vars
  for job in "measure:build-peak-rss" "measure:build-at-floor"; do
    job_vars="$(J="${job}" yq -r '.[strenv(J)].variables.MEASURE_NIX_FLAGS' "${CI_FILE}")"
    [[ "${job_vars}" != *"--rebuild"* && "${job_vars}" != *"enforce-determinism"* ]] \
      || fail "${job}: MEASURE_NIX_FLAGS must not carry --rebuild/enforce-determinism (#571); the build is forced real by output eviction"
  done

  # One role's stumble must not abandon the remaining roles: the run happens in a
  # coordinated idle window that is expensive to re-open.
  grep -qF 'continuing with the remaining roles' <<< "${peak_script}" \
    || fail "measure:build-peak-rss must continue past a failed role and fail at the end, not abort the loop"
  grep -qF 'start_nix_daemon' <<< "${peak_script}" \
    || fail "measure:build-peak-rss must start the socket-activated nix-daemon so the baseline sample is readable"
  grep -qE 'start nix-daemon.service' <<< "$(fn_body start_nix_daemon)" \
    || fail "start_nix_daemon must actually start nix-daemon.service"

  # peak_anon_mib is the number the floor is chosen from. On a kernel without
  # `anon` in memory.stat the sampler still succeeds but reports 0 — and a ranking
  # of ten zeros looks like a ranking. Both jobs must refuse to consume it.
  grep -qF 'anon_available == true' <<< "${peak_script}" \
    || fail "measure:build-peak-rss must refuse to publish a peak_anon_mib ranking when anon is unavailable (it would be all zeros)"
  grep -qF 'anon_available == true' <<< "${floor_script}" \
    || fail "measure:build-at-floor must refuse to certify a floor on a vacuous (0 MiB) anon peak"

  # #571: the real build is forced by EVICTING the cached output, so a plain
  # 'nix build' has to rebuild it (no --rebuild, no determinism compare). Both jobs
  # must evict, or a warm store returns an idle-daemon no-op that the sampler gate
  # then rejects.
  grep -qF 'evict_output' <<< "${peak_script}" \
    || fail "measure:build-peak-rss must evict the cached output before the measured build (#571)"
  grep -qF 'evict_output' <<< "${floor_script}" \
    || fail "measure:build-at-floor must evict the cached output before the measured build (#571)"
  grep -qF 'store delete' <<< "$(fn_body evict_output)" \
    || fail "evict_output must delete the resolved output path from the store"

  # The OOM probe decides whether a floor is rejected. An unscoped window would
  # match an OOM from an earlier job in the same pipeline and reject a sound floor.
  ! grep -qF -- '--since "-30 min"' <<< "${floor_script}" \
    || fail "measure:build-at-floor's OOM probe must not use an unscoped time window — it would match an earlier job's OOM"
  grep -qF 'oom_since="$(date -u' <<< "${floor_script}" \
    || fail "measure:build-at-floor must scope its OOM probe to a timestamp captured at the clamp"
  ok "the measurement jobs are manual, non-interruptible, isolated, and cannot strand a MemoryMax clamp"
}

# --- Case 0: every CI script entry is a STRING -------------------------------
# `yq` happily parses `- echo "NOTE: something"` as a MAP (the `": "` makes it a
# key/value pair), so a local yq-parses-fine check passes while GitLab rejects the
# whole config with "script config should be a string or a nested array of
# strings" — and the pipeline fails with ZERO jobs, which is a confusing way to
# find out. This caught exactly that on pipeline 1494. Repo-wide, not just the new
# jobs: any job can acquire the bug.
test_ci_script_entries_are_strings() {
  local offenders
  offenders="$(yq -o=json '.' "${CI_FILE}" | jq -r '
    to_entries[] | select(.value | type == "object") | .key as $job
    | .value | to_entries[]
    | select(.key | test("^(script|before_script|after_script)$"))
    | select(.value | type == "array") | .key as $k
    | .value | to_entries[]
    | select(.value | type != "string")
    | "\($job).\($k)[\(.key)]"')"
  [[ -z "${offenders}" ]] || fail "these CI script entries are not strings (a ': ' in an unquoted scalar makes YAML parse it as a map; GitLab rejects the config): ${offenders//$'\n'/ }"
  ok "every job's script/before_script/after_script entry is a string"
}

test_ci_script_entries_are_strings
test_peak_is_daemon_max
test_fail_closed_without_daemon
test_fail_closed_without_runner
test_fail_closed_on_no_build_activity
test_idleness_gate_sees_a_busy_runner
test_anon_reported_apart_from_page_cache
test_idleness_gate_refuses_before_running
test_fail_closed_without_runner_anon
test_command_exit_propagates
test_static_script_ratchets
test_measurement_is_runner_local_and_forces_a_real_build
test_stranded_clamp_is_healed
test_static_ci_ratchets
