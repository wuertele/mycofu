#!/usr/bin/env bash
# measure-build-orchestrate.sh — the CI-side orchestration for Sprint 046 R2.
#
# Usage:
#   measure-build-orchestrate.sh heal              # clear a stranded nix-daemon clamp
#   measure-build-orchestrate.sh peak-rss          # measure every MEASURE_ROLES role
#   measure-build-orchestrate.sh at-floor          # the capability check (clamps the daemon)
#   measure-build-orchestrate.sh restore-backstop  # after_script backstop for at-floor
#
# WHY THIS FILE EXISTS. The measurement itself lives in measure-build-peak-rss.sh
# (it samples nix-daemon's cgroup — Deviation D1). What lives HERE is the
# orchestration around it: starting the socket-activated daemon, EVICTING the
# image's cached output so the measured `nix build` has to build for real (#571 —
# see evict_output), clamping the SHARED nix-daemon.service MemoryMax and
# guaranteeing its restore, and healing a clamp stranded by a job that was
# SIGKILLed. That is privileged, failure-mode-dense logic, and it does not belong
# inline in .gitlab-ci.yml where it cannot be syntax-checked, unit-tested, or read.
#
# The .gitlab-ci.yml jobs are thin callers. Everything they used to do inline is
# here, unchanged.
#
# Configuration is by environment (the CI jobs set these as `variables:`):
#   MEASURE_ROLES             roles to measure (peak-rss)
#   MEASURE_ROLE              the single role to test (at-floor)
#   MEASURE_NIX_FLAGS         extra flags for the MEASURED nix build (normally
#                             empty; the build is forced real by output eviction,
#                             NOT by --rebuild — see evict_output / #571)
#   MEASURE_MAX_BASELINE_MIB  the not-idle-runner gate
#   MEASURE_NIX_MAX_JOBS      nix parallelism (peak-rss; empty = nix default)
#   MEASURE_NIX_CORES         nix parallelism (peak-rss; empty = nix default)
#   MEASURE_FLOOR_MB          candidate floor (at-floor)
#   MEASURE_OS_RESERVE_MB     OS reserve subtracted from the floor (at-floor)
#   PRIOR_MEMORY_MAX_FILE     where the pre-clamp MemoryMax is recorded
#
# Test seams (defaulted to the real tools; overridden only by the hermetic tests
# in tests/test_measure_build_orchestrate.sh, which cannot clamp a real daemon):
#   MYCOFU_SYSTEMCTL  MYCOFU_JOURNALCTL  MYCOFU_NIX  MYCOFU_SAMPLER  MYCOFU_OUT_DIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYSTEMCTL="${MYCOFU_SYSTEMCTL:-systemctl}"
JOURNALCTL="${MYCOFU_JOURNALCTL:-journalctl}"
NIX="${MYCOFU_NIX:-nix}"
SAMPLER="${MYCOFU_SAMPLER:-${SCRIPT_DIR}/measure-build-peak-rss.sh}"
OUT_DIR="${MYCOFU_OUT_DIR:-build/peak-rss}"

PRIOR_MEMORY_MAX_FILE="${PRIOR_MEMORY_MAX_FILE:-/run/mycofu-measure-prior-memory-max}"

# --- heal -------------------------------------------------------------------
# A SIGKILLed at-floor run executes neither its trap nor its after_script, so a
# `--runtime` MemoryMax clamp on the SHARED nix-daemon can outlive it (until the
# next reboot). Every job that builds THROUGH that daemon heals it first. The
# marker file exists only while a clamp is outstanding, so this is a no-op on
# every ordinary run.
cmd_heal() {
  if [ -f "${PRIOR_MEMORY_MAX_FILE}" ]; then
    local prior
    prior="$(cat "${PRIOR_MEMORY_MAX_FILE}")"
    echo "WARNING: a measurement job left nix-daemon.service clamped; restoring MemoryMax=${prior}"
    if "${SYSTEMCTL}" set-property --runtime nix-daemon.service "MemoryMax=${prior}"; then
      rm -f "${PRIOR_MEMORY_MAX_FILE}" || true
    else
      echo "ERROR: could not restore nix-daemon MemoryMax — this build may OOM under a stranded clamp" >&2
    fi
  fi
  return 0
}

# --- restore-backstop -------------------------------------------------------
# after_script backstop for at-floor. The in-script trap is the PRIMARY restore;
# this covers the paths where the trap did not fire. It writes back the CAPTURED
# value, never a hardcoded `infinity`. (NB: R5's PRODUCTION backstop is on
# `gitlab-runner.service`, not the daemon — see Deviation D1's measured correction.
# This at-floor clamp on `nix-daemon.service` is a MANUAL, DEFERRED measurement
# clamp only; restoring the captured value keeps it from leaking past the job, and a
# blind `infinity` could clobber a future daemon-level setting if one is ever added.)
cmd_restore_backstop() {
  local prior
  prior="$(cat "${PRIOR_MEMORY_MAX_FILE}" 2>/dev/null || true)"
  if [[ -n "${prior}" ]]; then
    echo "after_script backstop: the trap did not restore; writing back MemoryMax=${prior}"
    if "${SYSTEMCTL}" set-property --runtime nix-daemon.service "MemoryMax=${prior}"; then
      rm -f "${PRIOR_MEMORY_MAX_FILE}" || true
    else
      echo "ERROR: backstop restore FAILED. nix-daemon.service may still be clamped. ${PRIOR_MEMORY_MAX_FILE} is retained; the next build job's prelude will retry, and a reboot clears the --runtime property." >&2
    fi
  fi
  return 0
}

# nix-daemon is socket-activated: if it is inactive, its cgroup does not exist and
# the sampler's pre-command baseline would be unreadable, biasing the activity
# gate. Starting it is idempotent.
start_nix_daemon() {
  "${SYSTEMCTL}" start nix-daemon.service
}

# Force the measured build to be REAL by EVICTING the cached output (#571).
#
# The old approach — `nix build --rebuild` — is check-mode: it rebuilds the
# derivation and COMPARES the two outputs for reproducibility. `nixos-disk-image`
# is not bit-reproducible (timestamps, filesystem layout), so on a warm store
# --rebuild fails the determinism check and the job errors before producing a
# single number — even with `enforce-determinism false`, which does not reliably
# downgrade the `--check`/`--rebuild` mismatch to a warning for this derivation.
#
# Instead: resolve the image's output path (a pure eval — no build) and delete it
# from the store, so a subsequent PLAIN `nix build` has nothing valid to short-
# circuit on and must build for real — with NO reproducibility comparison. If the
# path cannot be evicted (a GC root pins it), we log it and continue: the sampler's
# --min-delta-mib gate then fails closed on the resulting idle-daemon no-op, so we
# never report an idle number as a peak.
evict_output() {  # $1=role
  local attr=".#packages.x86_64-linux.${1}-image"
  local outpath
  outpath="$("${NIX}" eval --raw "${attr}.outPath" 2>/dev/null || true)"
  if [[ -z "${outpath}" ]]; then
    echo "NOTE: could not resolve the output path for ${1}; a cold store builds for real anyway, and the --min-delta-mib gate catches a warm-store no-op."
    return 0
  fi
  if [[ ! -e "${outpath}" ]]; then
    echo "Output for ${1} is already absent (${outpath}); the measured build will be real."
    return 0
  fi
  echo "Evicting cached output for ${1}: ${outpath}"
  "${NIX}" store delete "${outpath}" 2>/dev/null \
    || "${NIX}" store delete --ignore-liveness "${outpath}" 2>/dev/null \
    || echo "NOTE: could not evict ${outpath} (likely a GC root or in use). The sampler's --min-delta-mib gate will fail closed if the measured build turns out to be a no-op."
}

# --- peak-rss ---------------------------------------------------------------
cmd_peak_rss() {
  mkdir -p "${OUT_DIR}"
  start_nix_daemon

  if [[ -n "${MEASURE_NIX_MAX_JOBS:-}" ]]; then
    NIX_CONFIG="${NIX_CONFIG:-}${NIX_CONFIG:+$'\n'}max-jobs = ${MEASURE_NIX_MAX_JOBS}"
  fi
  if [[ -n "${MEASURE_NIX_CORES:-}" ]]; then
    NIX_CONFIG="${NIX_CONFIG:-}${NIX_CONFIG:+$'\n'}cores = ${MEASURE_NIX_CORES}"
  fi
  [[ -n "${NIX_CONFIG:-}" ]] && export NIX_CONFIG

  # A per-role failure must NOT abandon the remaining roles: this runs in a
  # coordinated idle window, and losing roles 2..10 to a stumble on role 1 costs
  # another whole window. Collect failures, fail at the end.
  local failed="" role rc
  for role in ${MEASURE_ROLES}; do
    echo "=== Measuring peak RSS: ${role} (max-jobs='${MEASURE_NIX_MAX_JOBS:-}' cores='${MEASURE_NIX_CORES:-}') ==="
    evict_output "${role}"
    rc=0
    "${SAMPLER}" \
      --role "${role}" \
      --max-baseline-mib "${MEASURE_MAX_BASELINE_MIB}" \
      --out "${OUT_DIR}/${role}.json" \
      -- \
      "${NIX}" build ${MEASURE_NIX_FLAGS:-} --no-link --print-build-logs \
        ".#packages.x86_64-linux.${role}-image" || rc=$?
    if (( rc != 0 )); then
      echo "!!! ${role} FAILED to measure (rc=${rc}); continuing with the remaining roles"
      failed="${failed} ${role}"
    fi
  done

  if [[ -n "${failed}" ]]; then
    echo "ERROR: roles failed to measure:${failed}" >&2
    echo "ERROR: the surviving per-role JSONs are still in the artifacts; re-run the failed roles with MEASURE_ROLES='${failed# }'." >&2
    exit 1
  fi

  # Derived from OUT_DIR, not hardcoded: the two must not drift apart, or an
  # overridden OUT_DIR would scatter the per-role JSONs and the ranking.
  local ranking
  ranking="$(dirname "${OUT_DIR}")/peak-rss.json"
  mkdir -p "$(dirname "${ranking}")"
  jq -s 'sort_by(-.peak_anon_mib)' "${OUT_DIR}"/*.json > "${ranking}"
  cat "${ranking}"

  # peak_anon_mib is the number the floor is chosen from. On a kernel that does not
  # export `anon` in memory.stat the sampler still succeeds (it falls back to
  # memory.current for its gates) but reports peak_anon_mib = 0 — and a ranking of
  # ten zeros looks exactly like a ranking. Fail loudly instead.
  if ! jq -e 'all(.[]; .anon_available == true and .valid == true)' "${ranking}" >/dev/null; then
    echo "ERROR: at least one role reported anon_available=false or valid=false." >&2
    echo "ERROR: peak_anon_mib is then meaningless (0), and the floor must NOT be chosen from this artifact." >&2
    exit 1
  fi

  # SCOPE LIMIT, stated so the number is not over-read: evicting the top-level
  # output rebuilds the TOP-LEVEL derivation (the image assembly — the single
  # heaviest step). It does not reproduce a cold-store event (e.g. a flake.lock
  # bump rebuilding many dependencies in parallel), which A5.4 notes can be
  # heavier still.
  echo "NOTE: peak_mib includes reclaimable page cache (an UPPER BOUND); peak_anon_mib is the reclaim-resistant term. Choose the floor with BOTH, and confirm with measure:build-at-floor."
}

# --- at-floor ---------------------------------------------------------------
# THIS MUTATES A SHARED SERVICE (nix-daemon.service). Read the restore contract
# before changing anything here:
#   - The restore is owned by an in-script `trap ... EXIT INT TERM HUP` that writes
#     back the value CAPTURED at start, NOT a hardcoded `infinity`.
#   - The captured value is persisted to PRIOR_MEMORY_MAX_FILE, so the after_script
#     backstop and the next job's `heal` prelude restore the SAME value.
#   - The marker is deleted ONLY after a restore actually succeeds: it is the sole
#     record of the pre-clamp value.
#   - A `--runtime` property is dropped at reboot, so the worst-case blast radius
#     is bounded by the next cicd reboot — but a stranded clamp would OOM every
#     build until then, hence the belt and braces.
cmd_at_floor() {
  [[ "${MEASURE_FLOOR_MB}" =~ ^[1-9][0-9]*$ ]] || { echo "ERROR: MEASURE_FLOOR_MB must be a positive integer" >&2; exit 2; }
  [[ "${MEASURE_OS_RESERVE_MB}" =~ ^[0-9]+$ ]] || { echo "ERROR: MEASURE_OS_RESERVE_MB must be a non-negative integer" >&2; exit 2; }
  if (( MEASURE_FLOOR_MB <= MEASURE_OS_RESERVE_MB )); then
    echo "ERROR: MEASURE_FLOOR_MB (${MEASURE_FLOOR_MB}) must exceed MEASURE_OS_RESERVE_MB (${MEASURE_OS_RESERVE_MB})" >&2
    exit 2
  fi

  start_nix_daemon
  mkdir -p "${OUT_DIR}"

  # PREFLIGHT: refuse BEFORE touching the shared service. Clamping the daemon while
  # another pipeline is mid-build would OOM-kill that build — this job's mutation is
  # not confined by its resource_group (ordinary build:image jobs sit in per-role
  # groups and run freely).
  "${SAMPLER}" --preflight --max-baseline-mib "${MEASURE_MAX_BASELINE_MIB}"

  # If the heal prelude could not clear a stranded clamp, the "prior" value we are
  # about to capture IS that clamp — and restoring it later would make the clamp
  # permanent. Refuse.
  if [[ -f "${PRIOR_MEMORY_MAX_FILE}" ]]; then
    echo "ERROR: ${PRIOR_MEMORY_MAX_FILE} still exists — a previous clamp was not cleared." >&2
    echo "ERROR: capturing MemoryMax now would record the CLAMPED value as the 'prior' and make it permanent. Fix the daemon state first." >&2
    exit 1
  fi

  PRIOR_MEMORY_MAX="$("${SYSTEMCTL}" show -p MemoryMax --value nix-daemon.service 2>/dev/null || true)"
  [[ -n "${PRIOR_MEMORY_MAX}" ]] || PRIOR_MEMORY_MAX="infinity"
  printf '%s\n' "${PRIOR_MEMORY_MAX}" > "${PRIOR_MEMORY_MAX_FILE}"
  echo "nix-daemon.service MemoryMax before this job: ${PRIOR_MEMORY_MAX}"

  restore_memory_max() {
    local rc=$?
    if "${SYSTEMCTL}" set-property --runtime nix-daemon.service "MemoryMax=${PRIOR_MEMORY_MAX}"; then
      # Only now is the marker safe to drop: it is the sole record of the pre-clamp
      # value, and after_script/the next run's heal retry from it.
      rm -f "${PRIOR_MEMORY_MAX_FILE}" || true
      echo "nix-daemon.service MemoryMax restored to: $("${SYSTEMCTL}" show -p MemoryMax --value nix-daemon.service 2>/dev/null || echo UNKNOWN)"
    else
      echo "ERROR: FAILED to restore nix-daemon.service MemoryMax. Leaving ${PRIOR_MEMORY_MAX_FILE} in place; after_script (and the next run's heal prelude) will retry from it." >&2
    fi
    return $rc
  }
  trap restore_memory_max EXIT
  trap 'restore_memory_max; exit 143' INT TERM HUP

  local daemon_max_mb=$((MEASURE_FLOOR_MB - MEASURE_OS_RESERVE_MB))
  evict_output "${MEASURE_ROLE}"

  # Scope the OOM probe to THIS job's window. An unscoped `--since -30min` would
  # match an OOM from an earlier job in the same pipeline — the very phenomenon this
  # sprint exists to fix — and reject a sound floor on someone else's kill.
  local oom_since
  oom_since="$(date -u '+%Y-%m-%d %H:%M:%S')"
  echo "=== Clamping nix-daemon.service to MemoryMax=${daemon_max_mb}M and rebuilding ${MEASURE_ROLE} ==="
  "${SYSTEMCTL}" set-property --runtime nix-daemon.service "MemoryMax=${daemon_max_mb}M"

  local rc=0
  "${SAMPLER}" \
    --role "${MEASURE_ROLE}" \
    --out "${OUT_DIR}/${MEASURE_ROLE}-at-floor.json" \
    -- \
    "${NIX}" build ${MEASURE_NIX_FLAGS:-} --no-link --print-build-logs \
      ".#packages.x86_64-linux.${MEASURE_ROLE}-image" || rc=$?

  if (( rc != 0 )); then
    echo "=== ${MEASURE_ROLE} did NOT complete under the clamp (rc=${rc}) ==="
    # Distinguish "OOM ⇒ the candidate is not a capability floor" from "the build
    # broke for an unrelated reason". Conflating them would reject a sound floor, or
    # accept an unsound one.
    if "${JOURNALCTL}" -k --since "${oom_since}" --utc 2>/dev/null | grep -qi 'out of memory\|oom-kill'; then
      echo "VERDICT: OOM observed in the kernel log ⇒ ${MEASURE_FLOOR_MB}M is NOT a capability floor for ${MEASURE_ROLE} (OQ1: escalate per SPRINT-046 Phase 2)." >&2
    else
      echo "VERDICT: NO OOM in the kernel log — the build failed for an unrelated reason. Do NOT reject the floor on this evidence; fix the build and re-run." >&2
    fi
    exit "${rc}"
  fi

  # A completed build is necessary but NOT sufficient: the clamp bounds the DAEMON
  # only, while the floor must also cover the evaluator in the runner cgroup. Assert
  # the measured daemon+runner peak actually fits the budget.
  local result="${OUT_DIR}/${MEASURE_ROLE}-at-floor.json"
  if ! jq -e '.anon_available == true and .valid == true' "${result}" >/dev/null; then
    echo "ERROR: the run reported anon_available=false or valid=false; peak_anon_mib is not a real number." >&2
    echo "ERROR: refusing to certify a capability floor on it — a vacuous 0 would pass any budget check." >&2
    exit 1
  fi
  local peak_anon budget
  peak_anon="$(jq -r '.peak_anon_mib' "${result}")"
  budget=$((MEASURE_FLOOR_MB - MEASURE_OS_RESERVE_MB))
  echo "daemon+runner anon peak: ${peak_anon} MiB; budget (floor - reserve): ${budget} MiB"
  [[ "${peak_anon}" =~ ^[0-9]+$ ]] || { echo "ERROR: peak_anon_mib is not an integer: '${peak_anon}'" >&2; exit 1; }
  if (( peak_anon > budget )); then
    echo "VERDICT: the build completed, but daemon+runner anon peak ${peak_anon} MiB EXCEEDS the ${budget} MiB budget." >&2
    echo "VERDICT: the clamp bounded only the daemon; the evaluator's memory in the runner cgroup is not covered. ${MEASURE_FLOOR_MB}M is NOT a capability floor." >&2
    exit 1
  fi
  echo "PASS: ${MEASURE_ROLE} completed with nix-daemon clamped to ${daemon_max_mb}M, and daemon+runner anon peak ${peak_anon} MiB fits the ${budget} MiB budget ⇒ ${MEASURE_FLOOR_MB}M is a capability floor."

  cat "${result}"
}

case "${1:-}" in
  heal)             cmd_heal ;;
  restore-backstop) cmd_restore_backstop ;;
  peak-rss)         cmd_peak_rss ;;
  at-floor)         cmd_at_floor ;;
  *)
    echo "ERROR: unknown subcommand '${1:-}'" >&2
    sed -n '2,12p' "$0" >&2
    exit 2
    ;;
esac
