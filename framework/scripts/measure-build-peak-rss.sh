#!/usr/bin/env bash
# measure-build-peak-rss.sh — measure a nix build's peak memory from cgroup v2.
#
# Usage:
#   measure-build-peak-rss.sh [--role <name>] [--interval <sec>] [--out <file.json>]
#                             [--min-delta-mib <n>] [--max-baseline-mib <n>]
#                             [--allow-missing-runner-cgroup]
#                             -- <cmd> [args...]
#
# WHY THIS EXISTS (Sprint 046 R2, Deviation D1). cicd runs Nix in multi-user
# DAEMON mode (framework/nix/modules/gitlab-runner.nix: `nix.enable` +
# `trusted-users`), so `nix build` in a CI job is a thin RPC client: the builders
# — and the memory — live in the cgroup `system.slice/nix-daemon.service`, not in
# the job's process tree. Wrapping the build with `/usr/bin/time -v` or
# `systemd-run --scope` measures `getrusage(RUSAGE_CHILDREN)` on the client and
# reports a few hundred MiB. That number is not small — it is WRONG, and a memory
# floor derived from it would OOM the runner. This script samples the DAEMON
# cgroup (plus the runner cgroup, where the nix evaluator lives) instead.
#
# `memory.current` is sampled, not `memory.peak`: peak-reset semantics vary by
# kernel version. In cgroup v2 `memory.current` is recursive over the subtree, so
# nix's per-build child cgroups are included.
#
# TWO NUMBERS ARE REPORTED, and they mean different things:
#   peak_mib      — peak of `memory.current` (daemon + runner). This charges page
#                   cache to the writing cgroup, so for a multi-GiB image build it
#                   is an UPPER BOUND, not a working set. Most of the excess is
#                   reclaimable under pressure.
#   peak_anon_mib — peak of anon (+ kernel, when the kernel exports it) from
#                   `memory.stat`. This is the reclaim-RESISTANT term — the memory
#                   that a MemoryMax cap actually has to accommodate.
# Choosing the floor (T2.4) is an operator decision made with BOTH numbers, plus
# the capability evidence from the `measure:build-at-floor` job. This script does
# not choose.
#
# FAIL-CLOSED (.claude/rules/destruction-safety.md — "cannot determine ⇒ FAIL,
# never SKIP"). A measurement that cannot see the daemon cgroup, cannot see the
# runner cgroup, or observes no build activity at all (a warm /nix/store turning
# `nix build` into a no-op) would UNDERSTATE the floor while looking like a
# success. All three exit non-zero.
#
# Environment overrides (for hermetic tests; see tests/test_measure_build_peak_rss.sh):
#   MEASURE_CGROUP_ROOT         default /sys/fs/cgroup
#   MEASURE_NIX_DAEMON_CGROUP   default ${MEASURE_CGROUP_ROOT}/system.slice/nix-daemon.service
#   MEASURE_RUNNER_CGROUP       default ${MEASURE_CGROUP_ROOT}/system.slice/gitlab-runner.service
# Provenance recorded in the JSON (set by the CI job, not by this script):
#   MEASURE_NIX_MAX_JOBS, MEASURE_NIX_CORES, MYCOFU_NIX_BUILD_EXTRA_FLAGS
#
# `--out -` writes the JSON to stdout. Without `--out`, only a human summary is
# printed (to stderr), so the script is safe to wrap around a build whose stdout
# matters.

set -euo pipefail

ROLE="unknown"
INTERVAL="1"
OUT=""
# The activity gate: the daemon's working set must rise by at least this much
# above its baseline, or the "build" did no work and the measurement is vacuous.
# 0 disables the gate.
MIN_DELTA_MIB="256"
# The idleness gate: refuse to measure when the daemon is already holding more
# than this at the start (another pipeline is building). 0 disables the gate.
MAX_BASELINE_MIB="0"
ALLOW_MISSING_RUNNER=0
# --preflight: take ONE sample, apply the idleness gate, exit. No command needed.
# Callers that are about to mutate shared state (measure:build-at-floor clamps
# nix-daemon's MemoryMax) use this to refuse BEFORE they touch anything.
PREFLIGHT=0

usage() {
  sed -n '2,/^$/{
    s/^# \{0,1\}//
    p
  }' "$0"
}

require_value() {
  local flag="$1"
  local value="${2-__missing__}"
  if [[ "$value" == "__missing__" ]]; then
    echo "ERROR: ${flag} requires a value" >&2
    exit 2
  fi
}

require_uint() {
  local flag="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || { echo "ERROR: ${flag} must be a non-negative integer; got '${value}'" >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)              require_value "$1" "${2-__missing__}"; ROLE="$2"; shift 2 ;;
    --interval)          require_value "$1" "${2-__missing__}"; INTERVAL="$2"; shift 2 ;;
    --out)               require_value "$1" "${2-__missing__}"; OUT="$2"; shift 2 ;;
    --min-delta-mib)     require_value "$1" "${2-__missing__}"; MIN_DELTA_MIB="$2"; shift 2 ;;
    --max-baseline-mib)  require_value "$1" "${2-__missing__}"; MAX_BASELINE_MIB="$2"; shift 2 ;;
    --allow-missing-runner-cgroup) ALLOW_MISSING_RUNNER=1; shift ;;
    --preflight)         PREFLIGHT=1; shift ;;
    --help|-h)           usage; exit 0 ;;
    --)                  shift; break ;;
    *)                   echo "ERROR: unknown argument before --: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ $# -eq 0 && "${PREFLIGHT}" == "0" ]]; then
  echo "ERROR: '--' is required, followed by the command to measure" >&2
  usage >&2
  exit 2
fi

# Strict numeric validation. A sloppy interval ('1abc') would pass an
# arithmetic-ish check, then make `sleep` fail every iteration and break the JSON
# encoding only AFTER the build had already run.
[[ "$INTERVAL" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
  && awk -v i="$INTERVAL" 'BEGIN { exit !(i + 0 > 0) }' \
  || { echo "ERROR: --interval must be a positive decimal number; got '${INTERVAL}'" >&2; exit 2; }
require_uint --min-delta-mib "$MIN_DELTA_MIB"
require_uint --max-baseline-mib "$MAX_BASELINE_MIB"

CGROUP_ROOT="${MEASURE_CGROUP_ROOT:-/sys/fs/cgroup}"
NIX_DAEMON_CGROUP="${MEASURE_NIX_DAEMON_CGROUP:-${CGROUP_ROOT}/system.slice/nix-daemon.service}"
RUNNER_CGROUP="${MEASURE_RUNNER_CGROUP:-${CGROUP_ROOT}/system.slice/gitlab-runner.service}"

if [[ ! -e "${CGROUP_ROOT}/cgroup.controllers" ]] && [[ ! -d "${NIX_DAEMON_CGROUP}" ]]; then
  echo "ERROR: no cgroup v2 unified hierarchy at ${CGROUP_ROOT} (no cgroup.controllers, no ${NIX_DAEMON_CGROUP})." >&2
  echo "ERROR: this sampler is cgroup-v2 only. On a cgroup v1 host or a non-Linux host it cannot measure the nix-daemon and must not guess." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/measure-build-peak-rss.XXXXXX")"
SAMPLES_FILE="${TMP_DIR}/samples.tsv"
STOP_FILE="${TMP_DIR}/stop"
: > "${SAMPLES_FILE}"

COMMAND_PID=""
SAMPLER_PID=""

cleanup() {
  touch "${STOP_FILE}" 2>/dev/null || true
  [[ -n "${COMMAND_PID}" ]] && kill "${COMMAND_PID}" 2>/dev/null || true
  [[ -n "${SAMPLER_PID}" ]] && kill "${SAMPLER_PID}" 2>/dev/null || true
  rm -rf "${TMP_DIR}" 2>/dev/null || true
}
trap cleanup EXIT
# On a cancelled CI job the shell is signalled; without these the sampler
# subshell outlives the script.
trap 'cleanup; exit 143' INT TERM HUP

# Every cgroup read is guarded: a transient read failure must not kill the
# sampler under `set -euo pipefail` (.claude/rules/platform.md).
read_current() {  # $1=cgroup dir; echoes bytes, returns 1 if unreadable/garbage
  local value
  value="$(cat "${1}/memory.current" 2>/dev/null || true)"
  [[ "${value}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${value}"
}

# The reclaim-resistant term: anon + kernel. `kernel` is absent on older kernels;
# treat it as 0 there rather than failing (anon dominates for a nix build).
read_anon() {  # $1=cgroup dir; echoes bytes, returns 1 if memory.stat unreadable
  local stat
  stat="$(cat "${1}/memory.stat" 2>/dev/null || true)"
  [[ -n "${stat}" ]] || return 1
  awk '
    $1 == "anon"   { anon = $2 }
    $1 == "kernel" { kern = $2 }
    END { if (anon == "") exit 1; printf "%d\n", anon + (kern == "" ? 0 : kern) }
  ' <<< "${stat}" 2>/dev/null || return 1
}

sample_once() {
  local d_cur="0" r_cur="0" d_anon="0" r_anon="0" d_ok="0" r_ok="0" anon_ok="0" r_anon_ok="0"

  if d_cur="$(read_current "${NIX_DAEMON_CGROUP}")"; then d_ok="1"; else d_cur="0"; fi
  if r_cur="$(read_current "${RUNNER_CGROUP}")";     then r_ok="1"; else r_cur="0"; fi

  if [[ "${d_ok}" == "1" ]]; then
    if d_anon="$(read_anon "${NIX_DAEMON_CGROUP}")"; then anon_ok="1"; else d_anon="0"; fi
  fi
  # The runner's anon term is tracked SEPARATELY. The evaluator runs there and is
  # several GiB; silently contributing 0 to the anon series — the series the floor
  # is chosen from — would understate the floor exactly the way a missing
  # memory.current would.
  if [[ "${r_ok}" == "1" ]]; then
    if r_anon="$(read_anon "${RUNNER_CGROUP}")"; then r_anon_ok="1"; else r_anon="0"; fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${d_cur}" "${r_cur}" "${d_anon}" "${r_anon}" "${d_ok}" "${r_ok}" "${anon_ok}" "${r_anon_ok}" \
    >> "${SAMPLES_FILE}"
}

sampler_loop() {
  while [[ ! -e "${STOP_FILE}" ]]; do
    sample_once
    sleep "${INTERVAL}" || true
  done
  sample_once
}

to_mib() { printf '%s\n' "$((($1 + 1048575) / 1048576))"; }

# Fold SAMPLES_FILE into the reported numbers. Called twice: once on the single
# pre-command baseline sample (so the idleness gate can refuse BEFORE the build
# runs, or before a caller mutates shared state), and once at the end.
accumulate() {
  samples=0; daemon_seen=0; runner_seen=0; anon_seen=0; runner_anon_seen=0
  peak_bytes=0; anon_peak_bytes=0; daemon_peak_bytes=0; runner_peak_bytes=0
  daemon_anon_peak_bytes=0
  daemon_baseline_bytes=-1; daemon_anon_baseline_bytes=-1; baseline_bytes=-1
  runner_baseline_bytes=-1; runner_anon_baseline_bytes=-1

  local d_cur r_cur d_anon r_anon d_ok r_ok anon_ok r_anon_ok
  while IFS=$'\t' read -r d_cur r_cur d_anon r_anon d_ok r_ok anon_ok r_anon_ok; do
    [[ -n "${d_ok:-}" ]] || continue
    samples=$((samples + 1))
    if [[ "${d_ok}" == "1" ]]; then
      daemon_seen=1
      (( d_cur > daemon_peak_bytes )) && daemon_peak_bytes="${d_cur}"
      (( daemon_baseline_bytes < 0 )) && daemon_baseline_bytes="${d_cur}"
      (( d_cur + r_cur > peak_bytes )) && peak_bytes=$((d_cur + r_cur))
      (( baseline_bytes < 0 )) && baseline_bytes=$((d_cur + r_cur))
    fi
    if [[ "${r_ok}" == "1" ]]; then
      runner_seen=1
      (( r_cur > runner_peak_bytes )) && runner_peak_bytes="${r_cur}"
      (( runner_baseline_bytes < 0 )) && runner_baseline_bytes="${r_cur}"
    fi
    if [[ "${r_anon_ok}" == "1" ]]; then
      runner_anon_seen=1
      (( runner_anon_baseline_bytes < 0 )) && runner_anon_baseline_bytes="${r_anon}"
    fi
    if [[ "${anon_ok}" == "1" ]]; then
      anon_seen=1
      (( d_anon > daemon_anon_peak_bytes )) && daemon_anon_peak_bytes="${d_anon}"
      (( daemon_anon_baseline_bytes < 0 )) && daemon_anon_baseline_bytes="${d_anon}"
      (( d_anon + r_anon > anon_peak_bytes )) && anon_peak_bytes=$((d_anon + r_anon))
    fi
  done < "${SAMPLES_FILE}"

  (( daemon_baseline_bytes < 0 )) && daemon_baseline_bytes=0
  (( daemon_anon_baseline_bytes < 0 )) && daemon_anon_baseline_bytes=0
  (( runner_baseline_bytes < 0 )) && runner_baseline_bytes=0
  (( runner_anon_baseline_bytes < 0 )) && runner_anon_baseline_bytes=0
  (( baseline_bytes < 0 )) && baseline_bytes=0
  if [[ "${daemon_seen}" == "0" ]]; then
    peak_bytes=0; daemon_peak_bytes=0; anon_peak_bytes=0; daemon_anon_peak_bytes=0
  fi

  peak_mib="$(to_mib "${peak_bytes}")"
  peak_anon_mib="$(to_mib "${anon_peak_bytes}")"
  nix_daemon_peak_mib="$(to_mib "${daemon_peak_bytes}")"
  runner_peak_mib="$(to_mib "${runner_peak_bytes}")"
  baseline_mib="$(to_mib "${baseline_bytes}")"
  nix_daemon_baseline_mib="$(to_mib "${daemon_baseline_bytes}")"

  # The gates key off the DAEMON's ANON series when the kernel exports it, and
  # fall back to `memory.current` only when it does not. This matters: page cache
  # from a PREVIOUS build stays charged to the daemon's cgroup, so
  # `memory.current` can be GiB-high at idle. An activity gate on `memory.current`
  # would then see a small delta on a real build and false-fail; an idleness gate
  # on it would refuse to run on a genuinely idle runner. `anon` has neither
  # problem.
  runner_baseline_mib="$(to_mib "${runner_baseline_bytes}")"
  runner_anon_baseline_mib="$(to_mib "${runner_anon_baseline_bytes}")"
  if [[ "${anon_seen}" == "1" ]]; then
    delta_basis="anon"
    gate_peak_mib="$(to_mib "${daemon_anon_peak_bytes}")"
    gate_baseline_mib="$(to_mib "${daemon_anon_baseline_bytes}")"
    runner_gate_baseline_mib="${runner_anon_baseline_mib}"
  else
    delta_basis="memory.current"
    gate_peak_mib="${nix_daemon_peak_mib}"
    gate_baseline_mib="${nix_daemon_baseline_mib}"
    runner_gate_baseline_mib="${runner_baseline_mib}"
  fi
  delta_mib=$(( gate_peak_mib - gate_baseline_mib ))
  (( delta_mib < 0 )) && delta_mib=0
  # Explicit: `(( ... )) && x=y` returns 1 when the test is false. As a FUNCTION's
  # last statement that becomes the function's exit status, and `set -e` would
  # kill the script — silently, since nothing has printed yet.
  return 0
}

fail_if_daemon_unseen() {
  [[ "${daemon_seen}" == "1" ]] && return 0
  echo "ERROR: never read ${NIX_DAEMON_CGROUP}/memory.current." >&2
  echo "ERROR: the nix builders live in that cgroup (D1). A measurement without it is vacuous and would UNDERSTATE the floor; refusing to report a runner-only peak." >&2
  echo "ERROR: if nix-daemon.service is socket-activated and currently inactive, start it first ('systemctl start nix-daemon.service')." >&2
  exit 1
}

fail_if_runner_unseen() {
  [[ "${ALLOW_MISSING_RUNNER}" == "1" ]] && return 0
  if [[ "${runner_seen}" == "0" ]]; then
    echo "ERROR: never read ${RUNNER_CGROUP}/memory.current." >&2
    echo "ERROR: the nix EVALUATOR runs in the job shell, in that cgroup, and is a first-class term of the floor. Dropping it silently understates the floor." >&2
    echo "ERROR: if the runner cgroup genuinely does not apply here, pass --allow-missing-runner-cgroup to say so explicitly." >&2
    exit 1
  fi
  # Same argument, one level down: if the floor is chosen from the anon series,
  # the runner's anon term must be in it. A daemon-only anon peak would drop the
  # evaluator's several GiB with no warning.
  if [[ "${anon_seen}" == "1" && "${runner_anon_seen}" == "0" ]]; then
    echo "ERROR: read the daemon's memory.stat but never the runner's (${RUNNER_CGROUP}/memory.stat)." >&2
    echo "ERROR: peak_anon_mib would then be daemon-only, silently dropping the evaluator's anon memory from the floor." >&2
    echo "ERROR: pass --allow-missing-runner-cgroup only if the runner cgroup genuinely does not apply here." >&2
    exit 1
  fi
  return 0
}

# The idleness gate. Evaluated on the BASELINE sample, before the command runs and
# before any caller mutates shared state: a contaminated measurement must be
# refused up front, not after burning a full rebuild.
#
# BOTH cgroups are gated, and the runner's is not a formality. The two heavy
# nix-EVAL jobs (validate:nix-checks, validate:per-role-isolation — the ~5 GiB
# "pigs" that `ci-heavy-nix-eval` exists to serialize) evaluate client-side, so
# they leave the DAEMON idle while charging GiB to the RUNNER cgroup. A
# daemon-only idleness check would sail straight past them and then add their
# memory to every sample: the peak job would report a floor several GiB too high
# (a phantom OQ1 conflict), and the at-floor job would reject a sound floor.
fail_if_not_idle() {
  (( MAX_BASELINE_MIB > 0 )) || return 0
  if (( gate_baseline_mib > MAX_BASELINE_MIB )); then
    echo "ERROR: nix-daemon is already holding ${gate_baseline_mib} MiB (${delta_basis}) before the build starts; --max-baseline-mib is ${MAX_BASELINE_MIB}." >&2
    echo "ERROR: the runner is NOT idle — another BUILD is in flight. A peak measured now is contaminated and would OVERSTATE the floor. Refusing to measure." >&2
    exit 1
  fi
  if (( runner_gate_baseline_mib > MAX_BASELINE_MIB )); then
    echo "ERROR: the gitlab-runner cgroup is already holding ${runner_gate_baseline_mib} MiB (${delta_basis}) before the build starts; --max-baseline-mib is ${MAX_BASELINE_MIB}." >&2
    echo "ERROR: another job is EVALUATING (a nix eval runs client-side, in the runner cgroup, and leaves the daemon idle). Its memory would be charged to this measurement. Refusing to measure." >&2
    exit 1
  fi
  return 0
}

command_string=""
for arg in "$@"; do
  printf -v quoted '%q' "${arg}"
  command_string="${command_string:+${command_string} }${quoted}"
done

# One sample BEFORE the command starts. This is the baseline that both gates are
# measured against.
sample_once
accumulate
# Everything knowable from the baseline is checked HERE, before the command runs.
# A 40-minute image build that ends in "sorry, I could not measure that" wastes a
# coordinated idle window; and for measure:build-at-floor, which clamps the shared
# nix-daemon, refusing late would already have OOM-killed someone else's build.
fail_if_daemon_unseen
fail_if_runner_unseen
fail_if_not_idle

if [[ "${PREFLIGHT}" == "1" ]]; then
  echo "PREFLIGHT OK: nix-daemon baseline ${gate_baseline_mib} MiB (${delta_basis}); the runner is idle enough to measure." >&2
  exit 0
fi

START_SECONDS=${SECONDS}
sampler_loop &
SAMPLER_PID=$!

set +e
"$@" &
COMMAND_PID=$!
wait "${COMMAND_PID}"
COMMAND_EXIT=$?
set -e
COMMAND_PID=""

touch "${STOP_FILE}"
wait "${SAMPLER_PID}" 2>/dev/null || true
SAMPLER_PID=""
DURATION_S=$((SECONDS - START_SECONDS))

accumulate

json="$(
  jq -n \
    --arg role "${ROLE}" \
    --arg command "${command_string}" \
    --argjson peak_mib "${peak_mib}" \
    --argjson peak_anon_mib "${peak_anon_mib}" \
    --argjson nix_daemon_peak_mib "${nix_daemon_peak_mib}" \
    --argjson runner_peak_mib "${runner_peak_mib}" \
    --argjson baseline_mib "${baseline_mib}" \
    --argjson nix_daemon_baseline_mib "${nix_daemon_baseline_mib}" \
    --argjson runner_baseline_mib "${runner_baseline_mib}" \
    --argjson runner_anon_baseline_mib "${runner_anon_baseline_mib}" \
    --argjson delta_mib "${delta_mib}" \
    --arg delta_basis "${delta_basis}" \
    --argjson samples "${samples}" \
    --arg interval_s "${INTERVAL}" \
    --argjson duration_s "${DURATION_S}" \
    --argjson anon_available "$( [[ "${anon_seen}" == "1" ]] && echo true || echo false )" \
    --argjson runner_anon_available "$( [[ "${runner_anon_seen}" == "1" ]] && echo true || echo false )" \
    --arg nix_max_jobs "${MEASURE_NIX_MAX_JOBS:-unset}" \
    --arg nix_cores "${MEASURE_NIX_CORES:-unset}" \
    --arg nix_build_extra_flags "${MYCOFU_NIX_BUILD_EXTRA_FLAGS:-unset}" \
    --argjson exit_code "${COMMAND_EXIT}" \
    '{role: $role, command: $command,
      peak_mib: $peak_mib, peak_anon_mib: $peak_anon_mib,
      anon_available: $anon_available, runner_anon_available: $runner_anon_available,
      nix_daemon_peak_mib: $nix_daemon_peak_mib, runner_peak_mib: $runner_peak_mib,
      baseline_mib: $baseline_mib, nix_daemon_baseline_mib: $nix_daemon_baseline_mib,
      runner_baseline_mib: $runner_baseline_mib, runner_anon_baseline_mib: $runner_anon_baseline_mib,
      delta_mib: $delta_mib, delta_basis: $delta_basis,
      samples: $samples, interval_s: $interval_s, duration_s: $duration_s,
      nix_max_jobs: $nix_max_jobs, nix_cores: $nix_cores,
      nix_build_extra_flags: $nix_build_extra_flags,
      valid: true,
      exit_code: $exit_code}'
)"

if [[ -n "${OUT}" ]]; then
  if [[ "${OUT}" == "-" ]]; then
    printf '%s\n' "${json}"
  else
    mkdir -p "$(dirname "${OUT}")"
    printf '%s\n' "${json}" > "${OUT}"
  fi
fi

summary="role=${ROLE} peak=${peak_mib}MiB peak_anon=${peak_anon_mib}MiB nix-daemon=${nix_daemon_peak_mib}MiB runner=${runner_peak_mib}MiB baseline=${baseline_mib}MiB delta=${delta_mib}MiB(${delta_basis}) samples=${samples} duration=${DURATION_S}s exit=${COMMAND_EXIT}"

# --- Fail-closed gates. Each one exists because the failure it catches would
# --- otherwise look exactly like a successful measurement.

# Re-checked after the run: a cgroup can disappear mid-build (a service restart),
# which would silently truncate the series the floor is chosen from.
if [[ "${daemon_seen}" == "0" ]] || [[ "${runner_seen}" == "0" && "${ALLOW_MISSING_RUNNER}" == "0" ]]; then
  echo "${summary}" >&2
fi
fail_if_daemon_unseen
fail_if_runner_unseen

# The warm-store trap: `nix build` on an already-valid output path returns in
# seconds without spawning a single builder. The daemon cgroup then reports its
# idle working set and the job looks green. The orchestrator forces a real build
# by EVICTING the output first (#571); this gate is the fail-closed backstop that
# catches the case where eviction was pinned (a GC root) and the build was a no-op.
# A gate-rejected run must not leave a plausible-looking number behind: the job's
# own failure message points the operator at the surviving per-role artifacts.
invalidate_json() {
  [[ -n "${OUT}" && "${OUT}" != "-" && -f "${OUT}" ]] || return 0
  local tmp="${OUT}.tmp"
  jq --arg r "$1" '.valid = false | .invalid_reason = $r' "${OUT}" > "${tmp}" 2>/dev/null \
    && mv "${tmp}" "${OUT}" || rm -f "${tmp}"
  return 0
}

if (( MIN_DELTA_MIB > 0 )) && [[ "${COMMAND_EXIT}" -eq 0 ]] && (( delta_mib < MIN_DELTA_MIB )); then
  invalidate_json "no-build-activity"
  echo "ERROR: the nix-daemon's working set rose by only ${delta_mib} MiB (${delta_basis}: baseline ${gate_baseline_mib} MiB → peak ${gate_peak_mib} MiB); --min-delta-mib is ${MIN_DELTA_MIB}." >&2
  echo "ERROR: no build activity was observed. The most likely cause is a WARM /nix/store: the output path was already valid, so nix built nothing and this 'peak' is the daemon at idle." >&2
  echo "ERROR: the output was not evicted before the build (a GC root likely pinned it). Evict it (nix store delete <outPath>) or build into a fresh store, then re-run. Refusing to report an idle-daemon number as a build peak." >&2
  echo "${summary}" >&2
  exit 1
fi

echo "${summary}" >&2
exit "${COMMAND_EXIT}"
