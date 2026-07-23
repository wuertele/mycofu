#!/usr/bin/env bash
set -euo pipefail

MAX_CONCURRENT="${RUNNER_BUDGET_MAX_CONCURRENT:-8}"
LIGHT_JOB_MB="${RUNNER_BUDGET_LIGHT_JOB_MB:-2048}"
HEAVY_RESERVE_MB="${RUNNER_BUDGET_HEAVY_RESERVE_MB:-8192}"
OS_RESERVE_MB="${RUNNER_BUDGET_OS_RESERVE_MB:-1024}"
FLOOR_MB="${RUNNER_BUDGET_FLOOR_MB:-8192}"
MAX_NIX_JOBS="${RUNNER_BUDGET_MAX_NIX_JOBS:-4}"
FLOOR_CORES="${RUNNER_BUDGET_FLOOR_CORES:-4}"

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Config knobs come from NixOS options typed ints.positive, so in production they
# cannot be non-numeric. Validate anyway: a bad knob must fail CLOSED (serialize),
# never abort arithmetic under `set -e` and leave the runner at whatever concurrent
# it last had, nor emit invalid JSON.
knob_failsafe=""
for knob in MAX_CONCURRENT LIGHT_JOB_MB HEAVY_RESERVE_MB OS_RESERVE_MB FLOOR_MB MAX_NIX_JOBS FLOOR_CORES; do
  if ! is_uint "${!knob}"; then
    knob_failsafe="${knob} not a non-negative integer"
    break
  fi
done
# The "positive" knobs must be >= 1: LIGHT_JOB_MB and HEAVY_RESERVE_MB are divisors
# (a zero would divide-by-zero and crash before the fail-safe path), and a zero cap
# or floor is meaningless. OS_RESERVE_MB alone may be 0 (a zero reserve is valid),
# but FLOOR_MB must exceed it or the floor budget goes non-positive.
if [ -z "$knob_failsafe" ]; then
  for pk in MAX_CONCURRENT LIGHT_JOB_MB HEAVY_RESERVE_MB FLOOR_MB MAX_NIX_JOBS FLOOR_CORES; do
    if [ "${!pk}" -lt 1 ]; then
      knob_failsafe="${pk} must be >= 1"
      break
    fi
  done
fi
if [ -z "$knob_failsafe" ] && [ "$FLOOR_MB" -le "$OS_RESERVE_MB" ]; then
  knob_failsafe="FLOOR_MB (${FLOOR_MB}) must exceed OS_RESERVE_MB (${OS_RESERVE_MB})"
fi
if [ -n "$knob_failsafe" ]; then
  # Reset the divisors and cap to safe values so the fail-safe path below can still
  # compute a valid (serialized) report instead of dividing by zero.
  { is_uint "$LIGHT_JOB_MB" && [ "$LIGHT_JOB_MB" -ge 1 ]; } || LIGHT_JOB_MB=2048
  { is_uint "$HEAVY_RESERVE_MB" && [ "$HEAVY_RESERVE_MB" -ge 1 ]; } || HEAVY_RESERVE_MB=8192
  { is_uint "$MAX_CONCURRENT" && [ "$MAX_CONCURRENT" -ge 1 ]; } || MAX_CONCURRENT=1
  is_uint "$OS_RESERVE_MB" || OS_RESERVE_MB=1024
  { is_uint "$FLOOR_MB" && [ "$FLOOR_MB" -ge 1 ]; } || FLOOR_MB=8192
  { is_uint "$MAX_NIX_JOBS" && [ "$MAX_NIX_JOBS" -ge 1 ]; } || MAX_NIX_JOBS=1
  { is_uint "$FLOOR_CORES" && [ "$FLOOR_CORES" -ge 1 ]; } || FLOOR_CORES=1
  # A numerically-valid but inverted floor/reserve pair (floor <= reserve) would
  # make floor_budget_mb non-positive and drive the cgroup clamp to MemoryMax=0M
  # (which OOM-kills everything). Repair the relationship to known-good defaults so
  # the clamp math below stays positive even on the fail-safe path.
  if [ "$FLOOR_MB" -le "$OS_RESERVE_MB" ]; then
    FLOOR_MB=8192
    OS_RESERVE_MB=1024
  fi
fi
MEMINFO="${RUNNER_BUDGET_MEMINFO:-/proc/meminfo}"
STATE_FILE="${RUNNER_BUDGET_STATE_FILE:-/run/mycofu/runner-budget.state}"
STATUS_FILE="${RUNNER_BUDGET_STATUS_FILE:-/run/mycofu/runner-budget.json}"
NIX_CONF="${RUNNER_BUDGET_NIX_CONF:-/run/mycofu/nix-budget.conf}"
CONFIG_FILE="${GITLAB_RUNNER_CONFIG_FILE:-/etc/gitlab-runner/config.toml}"
PERSISTED_CONFIG="${GITLAB_RUNNER_PERSISTED_CONFIG:-/nix/persist/gitlab-runner/config.toml}"
APPLY="${RUNNER_BUDGET_APPLY:-1}"

TMP_FILES=()
cleanup() {
  if [ "${#TMP_FILES[@]}" -gt 0 ]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

max_int() {
  if [ "$1" -ge "$2" ]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$2"
  fi
}

clamp_int() {
  local value="$1" min_value="$2" max_value="$3"
  if [ "$value" -lt "$min_value" ]; then
    printf '%s\n' "$min_value"
  elif [ "$value" -gt "$max_value" ]; then
    printf '%s\n' "$max_value"
  else
    printf '%s\n' "$value"
  fi
}

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

make_tmp_in_dir() {
  local dir="$1" prefix="$2" tmp
  mkdir -p "$dir"
  tmp="$(mktemp "${dir}/${prefix}.XXXXXX")"
  TMP_FILES+=("$tmp")
  printf '%s\n' "$tmp"
}

state_get() {
  local key="$1" line
  if [ ! -f "$STATE_FILE" ]; then
    return 0
  fi
  line="$(grep -m1 "^${key}=" "$STATE_FILE" 2>/dev/null || true)"
  if [ -n "$line" ]; then
    printf '%s\n' "${line#*=}"
  fi
}

parse_meminfo_kb() {
  local field="$1" line value
  line="$(grep -m1 "^${field}:" "$MEMINFO" 2>/dev/null || true)"
  value="$(printf '%s\n' "$line" | sed -n "s/^${field}:[[:space:]]*\\([0-9][0-9]*\\)[[:space:]]*kB.*/\\1/p")"
  printf '%s\n' "$value"
}

failsafe=false
reason=""
mem_available_mb=0
mem_total_mb=0
avail_min3_mb=0

# A5.1 / R-9: the budget must never use MemTotal. Under virtio-balloon it
# stays pinned at the 60 GiB ceiling while the guest may only have the floor
# available on a survivor. MemAvailable already excludes ballooned-away pages.
if [ -n "$knob_failsafe" ]; then
  failsafe=true
  reason="$knob_failsafe"
elif [ ! -r "$MEMINFO" ]; then
  failsafe=true
  reason="meminfo unreadable"
else
  mem_available_line="$(grep -m1 '^MemAvailable:' "$MEMINFO" 2>/dev/null || true)"
  if [ -z "$mem_available_line" ]; then
    failsafe=true
    reason="MemAvailable absent"
  else
    mem_available_kb="$(printf '%s\n' "$mem_available_line" | sed -n 's/^MemAvailable:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*kB.*/\1/p')"
    if [ -z "$mem_available_kb" ]; then
      failsafe=true
      reason="MemAvailable unparseable"
    else
      mem_available_mb=$((mem_available_kb / 1024))
    fi
  fi

  # Telemetry only: MemTotal is reported so operators can see the balloon
  # ceiling trap, but it is never an input to admission, nix parallelism, or
  # the cgroup clamp.
  mem_total_kb="$(parse_meminfo_kb MemTotal)"
  if is_uint "$mem_total_kb"; then
    mem_total_mb=$((mem_total_kb / 1024))
  fi
fi

samples_out=""
last_target="$(state_get last_target)"
up_confirm="$(state_get up_confirm)"
state_high_mb="$(state_get memory_high_mb)"
state_max_mb="$(state_get memory_max_mb)"

# A corrupted state file must never drive `concurrent` out of the 1..max band.
# `is_uint` accepts 0, and the increase-hysteresis branch holds at last_target for
# one cycle — so an unclamped last_target=0 would write `concurrent = 0`. Discard
# any last_target that is not a positive value inside the current cap.
if ! is_uint "$last_target" || [ "$last_target" -lt 1 ] || [ "$last_target" -gt "$MAX_CONCURRENT" ]; then
  last_target=""
fi
if ! is_uint "$up_confirm"; then
  up_confirm=0
fi
if ! is_uint "$state_high_mb"; then
  state_high_mb=""
fi
if ! is_uint "$state_max_mb"; then
  state_max_mb=""
fi

budget_mb=$((avail_min3_mb - OS_RESERVE_MB))
slots=1
target_concurrent=1
applied_target=1

if [ "$failsafe" = false ]; then
  samples=()
  prior_samples="$(state_get samples)"
  for sample in $prior_samples; do
    if is_uint "$sample"; then
      samples+=("$sample")
    fi
  done
  samples+=("$mem_available_mb")
  while [ "${#samples[@]}" -gt 3 ]; do
    samples=("${samples[@]:1}")
  done

  avail_min3_mb="${samples[0]}"
  for sample in "${samples[@]}"; do
    if [ "$sample" -lt "$avail_min3_mb" ]; then
      avail_min3_mb="$sample"
    fi
  done
  samples_out="${samples[*]}"

  budget_mb=$((avail_min3_mb - OS_RESERVE_MB))
  if [ "$budget_mb" -le 0 ]; then
    failsafe=true
    reason="budget <= 0"
  fi
fi

if [ "$failsafe" = true ]; then
  samples_out=""
  slots=1
  target_concurrent=1
  applied_target=1
  up_confirm=0
  # Report a zero budget rather than a negative one. The clamp below floors on
  # FLOOR_MB - OS_RESERVE_MB regardless, so a zero budget is not a zero clamp.
  budget_mb=0
  echo "runner-budget: FAILSAFE ${reason}; serializing runner and nix parallelism" >&2
else
  remaining_mb=$((budget_mb - HEAVY_RESERVE_MB))
  if [ "$remaining_mb" -lt 0 ]; then
    remaining_mb=0
  fi
  slots=$((1 + remaining_mb / LIGHT_JOB_MB))
  target_concurrent="$(clamp_int "$slots" 1 "$MAX_CONCURRENT")"

  if [ -z "$last_target" ]; then
    applied_target="$target_concurrent"
    up_confirm=0
  elif [ "$target_concurrent" -lt "$last_target" ]; then
    applied_target="$target_concurrent"
    up_confirm=0
  elif [ "$target_concurrent" -gt "$last_target" ]; then
    up_confirm=$((up_confirm + 1))
    if [ "$up_confirm" -ge 2 ]; then
      applied_target="$target_concurrent"
      up_confirm=0
    else
      applied_target="$last_target"
    fi
  else
    applied_target="$last_target"
    up_confirm=0
  fi
fi

# Determine whether the runner is idle. This single predicate gates both
# mutations that can disturb an in-flight CI job:
#   (1) the concurrent-value reload below — a config.toml rewrite + SIGHUP; and
#   (2) a MemoryMax *lowering* in the cgroup clamp further down.
# The idle proof is the count of DIRECT CHILDREN of the runner MainPID (the shell
# executor spawns one shell per job) being zero — NOT TasksCurrent, which counts
# the runner daemon's own Go threads (~30 even when idle) and would make the runner
# "never idle", pinning a widened MemoryMax forever on a ballooned-down survivor.
# pgrep's EXIT CODE distinguishes the cases: 0 = children found (busy), 1 = none
# (genuinely idle), >=2 = pgrep error (unknown). An error must NOT collapse to
# "0 children" — that would fail OPEN and let a lowering/reload preempt a build we
# cannot see. Unknown (MainPID or pgrep unreadable ⇒ running_jobs_numeric empty) is
# treated as BUSY. Computed only under APPLY=1: in dry-run/test mode there is no live
# runner to disturb, so the reload/clamp idle guards below do not engage.
running_jobs_json="null"
running_jobs_summary="null"
running_jobs_numeric=""

if [ "$APPLY" = "1" ]; then
  main_pid="$(systemctl show -p MainPID --value gitlab-runner.service 2>/dev/null || true)"
  if is_uint "$main_pid" && [ "$main_pid" -gt 0 ]; then
    set +e
    children="$(pgrep -P "$main_pid" 2>/dev/null)"
    pgrep_rc=$?
    set -e
    if [ "$pgrep_rc" -eq 0 ]; then
      running_jobs_numeric="$(printf '%s\n' "$children" | grep -c . || true)"
    elif [ "$pgrep_rc" -eq 1 ]; then
      running_jobs_numeric=0
    fi
    if is_uint "$running_jobs_numeric"; then
      running_jobs_json="$running_jobs_numeric"
      running_jobs_summary="$running_jobs_numeric"
    fi
  fi
fi

free_slots="$applied_target"
if is_uint "$running_jobs_numeric"; then
  free_slots=$((applied_target - running_jobs_numeric))
  if [ "$free_slots" -lt 0 ]; then
    free_slots=0
  fi
fi

runner_idle=false
if is_uint "$running_jobs_numeric" && [ "$running_jobs_numeric" -eq 0 ]; then
  runner_idle=true
fi
# Is the runner process actually up? DISTINCT from idle: this service is ordered
# `before gitlab-runner.service`, so at first boot (and on a ballooned-down survivor's
# recovery boot) MainPID=0 and the runner is DOWN — not busy. A down runner has no
# jobs to disturb and MUST still get its boot-time config normalization, or a stale
# persisted/default `concurrent` leaks into the runner when it starts.
runner_up=false
if is_uint "${main_pid:-}" && [ "${main_pid:-0}" -gt 0 ]; then
  runner_up=true
fi

# Defense-in-depth: a concurrency change rewrites config.toml and reloads the
# runner. Even though the reload now targets ONLY the daemon main process (below),
# defer the whole write+reload while the runner is UP but not proven idle — the same
# runner_idle predicate that gates the MemoryMax lowering, but scoped to a running
# runner so a DOWN runner still normalizes config at boot. A deferred change is
# re-detected by the config-file compare on the next idle cycle, so no target is
# lost; the adaptive value simply applies when no job can be disturbed. In dry-run
# mode (APPLY=0) there is no live runner, so writes proceed unguarded.
config_changed=false
defer_reload=false
if [ "$APPLY" = "1" ] && [ "$runner_up" = true ] && [ "$runner_idle" != true ]; then
  defer_reload=true
fi
if [ "$defer_reload" = true ]; then
  echo "runner-budget: concurrent change to ${applied_target} deferred; gitlab-runner.service not proven idle (running_jobs='${running_jobs_numeric:-unknown}')" >&2
elif [ ! -e "$CONFIG_FILE" ]; then
  echo "runner-budget: runner config not present yet; skipping concurrent write" >&2
else
  config_dir="$(dirname "$CONFIG_FILE")"
  tmp_config="$(make_tmp_in_dir "$config_dir" ".runner-budget-config")"
  if sed '/^\[/q' "$CONFIG_FILE" | grep -qE '^concurrent[[:space:]]*='; then
    sed "1,/^\[/{s/^concurrent[[:space:]]*=.*/concurrent = ${applied_target}/;}" "$CONFIG_FILE" > "$tmp_config"
  else
    {
      printf 'concurrent = %s\n' "$applied_target"
      cat "$CONFIG_FILE"
    } > "$tmp_config"
  fi

  if ! cmp -s "$tmp_config" "$CONFIG_FILE"; then
    # Atomic replace: the tmp file is in the same dir, so mv is a rename and a
    # concurrent reader (gitlab-runner re-reading on HUP) never sees a partial file.
    persist_dir="$(dirname "$PERSISTED_CONFIG")"
    mkdir -p "$persist_dir"
    persist_tmp="$(make_tmp_in_dir "$persist_dir" ".runner-budget-persist")"
    cp "$tmp_config" "$persist_tmp"
    chmod 600 "$persist_tmp"
    mv -f "$persist_tmp" "$PERSISTED_CONFIG"
    chmod 600 "$tmp_config"
    mv -f "$tmp_config" "$CONFIG_FILE"
    config_changed=true
    echo "runner-budget: wrote concurrent = ${applied_target}" >&2
  fi
fi

if [ "$config_changed" = true ] && [ "$APPLY" = "1" ]; then
  if [ "$runner_up" = true ]; then
    # Reload the runner by signaling ONLY the daemon's main process. The unit runs
    # with KillMode=control-group (systemd default), so a bare `systemctl kill -s HUP`
    # (which defaults to --kill-whom=all) delivers SIGHUP to EVERY process in the
    # runner cgroup — the daemon AND every running job shell — killing in-flight jobs
    # (`signal: hangup`). gitlab-runner handles SIGHUP to its own PID as a graceful
    # config reload that keeps running jobs; --kill-whom=main restricts delivery to
    # the main PID so job shells are never signalled.
    if ! systemctl kill --kill-whom=main -s HUP gitlab-runner.service 2>/dev/null; then
      echo "runner-budget: gitlab-runner.service reload (SIGHUP to main) skipped or failed" >&2
    fi
  else
    # Runner is down (e.g. first boot before gitlab-runner.service starts). The
    # config was normalized above and will be read when the runner starts; there is
    # no main process to signal, so skip the reload.
    echo "runner-budget: gitlab-runner.service not running; concurrent written for next start, reload skipped" >&2
  fi
fi

if [ "$failsafe" = true ]; then
  nix_max_jobs=1
else
  nix_max_jobs="$(clamp_int $((budget_mb / HEAVY_RESERVE_MB)) 1 "$MAX_NIX_JOBS")"
fi
if [ "$applied_target" -gt 1 ]; then
  nix_cores=0
else
  nix_cores="$FLOOR_CORES"
fi

# T4.6 mechanism: the module adds `!include /run/mycofu/nix-budget.conf`
# to the store-managed /etc/nix/nix.conf. `!include` is optional, so boot is
# safe before this file exists. The nix client re-reads nix.conf on every
# invocation, and CI builds run as root through the local store in the runner
# cgroup, not the daemon, so the client enforces these knobs. No daemon
# reload/restart is needed; the plan's `systemctl reload nix-daemon` path does
# not exist (CanReload=no).
nix_dir="$(dirname "$NIX_CONF")"
tmp_nix="$(make_tmp_in_dir "$nix_dir" ".nix-budget")"
{
  printf 'max-jobs = %s\n' "$nix_max_jobs"
  printf 'cores = %s\n' "$nix_cores"
} > "$tmp_nix"
if [ ! -e "$NIX_CONF" ] || ! cmp -s "$tmp_nix" "$NIX_CONF"; then
  # Atomic: a nix client reading the include mid-write must never see it empty
  # (an empty include silently restores default max-jobs/cores).
  chmod 0644 "$tmp_nix"
  mv -f "$tmp_nix" "$NIX_CONF"
  echo "runner-budget: wrote nix max-jobs=${nix_max_jobs} cores=${nix_cores}" >&2
fi

# The clamp on gitlab-runner.service (NOT nix-daemon: shell-executor builds run
# as root through the local store, so the memory lives in the runner's cgroup).
# MemoryHigh is the soft, reclaim-first control at 90% of the budget; MemoryMax
# is the hard host-protection ceiling at the budget. Both floor on the balloon
# floor's budget, so they always match the unit's cold-start values (which nix
# derives with the same 90% rule) and never clamp below what the floor can hold.
floor_budget_mb=$((FLOOR_MB - OS_RESERVE_MB))
floor_high_mb=$((floor_budget_mb * 9 / 10))
high_from_budget=$((budget_mb * 9 / 10))
memory_high_mb="$(max_int "$floor_high_mb" "$high_from_budget")"
memory_max_mb="$(max_int "$floor_budget_mb" "$budget_mb")"

# The /run state cache records what we THINK is applied, but it can desync from
# systemd's ACTUAL clamp: if a prior cycle's set-property landed but the process was
# killed before the state write, systemd holds the newer value while the cache is
# stale. A cache-only compare would then skip the repair forever. Guard against that
# by ALWAYS re-applying the desired clamp when the runner is proven idle — the write
# is idempotent, so reconciling every idle cycle heals any drift (stale-low cache
# hiding a widened clamp, or an unbounded/"infinity" actual) with no risk of
# preempting a build. When busy, fall back to the cache-compare and NEVER lower
# MemoryMax (that would OOM the running build) — defer the lowering.
apply_high=false
if [ "$runner_idle" = true ] || [ -z "$state_high_mb" ] || [ "$memory_high_mb" -ne "$state_high_mb" ]; then
  apply_high=true
fi

apply_max_target="$memory_max_mb"
clamp_lower_deferred=false
apply_max=false
if [ "$runner_idle" = true ]; then
  apply_max=true                                   # idle: always reconcile to desired
elif [ -z "$state_max_mb" ]; then
  apply_max=true                                   # first set — safe
elif [ "$memory_max_mb" -gt "$state_max_mb" ]; then
  apply_max=true                                   # raising — safe
elif [ "$memory_max_mb" -lt "$state_max_mb" ]; then
  clamp_lower_deferred=true                         # lowering while busy/unknown — defer
  apply_max_target="$state_max_mb"
  echo "runner-budget: MemoryMax reduction ${state_max_mb}M->${memory_max_mb}M deferred; gitlab-runner.service not proven idle (running_jobs='${running_jobs_numeric:-unknown}')" >&2
fi

if { [ "$apply_high" = true ] || [ "$apply_max" = true ]; }; then
  if [ "$APPLY" = "1" ]; then
    if systemctl set-property --runtime gitlab-runner.service "MemoryHigh=${memory_high_mb}M" "MemoryMax=${apply_max_target}M"; then
      state_high_mb="$memory_high_mb"
      state_max_mb="$apply_max_target"
    else
      echo "runner-budget: failed to apply gitlab-runner.service memory clamp" >&2
    fi
  else
    state_high_mb="$memory_high_mb"
    state_max_mb="$apply_max_target"
  fi
fi

heavy_slots=0
if [ "$budget_mb" -ge "$HEAVY_RESERVE_MB" ]; then
  heavy_slots=1
fi
light_slots="$applied_target"

state_dir="$(dirname "$STATE_FILE")"
tmp_state="$(make_tmp_in_dir "$state_dir" ".runner-budget-state")"
{
  printf 'samples=%s\n' "$samples_out"
  printf 'last_target=%s\n' "$applied_target"
  printf 'up_confirm=%s\n' "$up_confirm"
  printf 'memory_high_mb=%s\n' "$state_high_mb"
  printf 'memory_max_mb=%s\n' "$state_max_mb"
} > "$tmp_state"
mv "$tmp_state" "$STATE_FILE"

status_dir="$(dirname "$STATUS_FILE")"
tmp_status="$(make_tmp_in_dir "$status_dir" ".runner-budget-json")"
escaped_reason="$(json_escape "$reason")"
queued_note="queued jobs are held server-side by GitLab resource_group or by the runner not acquiring work, so they are not observable at the runner"
escaped_queued_note="$(json_escape "$queued_note")"
{
  printf '{\n'
  printf '  "schema": 1,\n'
  printf '  "mem_available_mb": %s, "mem_total_mb": %s, "avail_min3_mb": %s,\n' "$mem_available_mb" "$mem_total_mb" "$avail_min3_mb"
  printf '  "os_reserve_mb": %s, "budget_mb": %s,\n' "$OS_RESERVE_MB" "$budget_mb"
  printf '  "light_job_mb": %s, "heavy_reserve_mb": %s,\n' "$LIGHT_JOB_MB" "$HEAVY_RESERVE_MB"
  printf '  "max_concurrent": %s, "target_concurrent": %s,\n' "$MAX_CONCURRENT" "$applied_target"
  printf '  "slots": { "heavy": %s, "light": %s },\n' "$heavy_slots" "$light_slots"
  printf '  "running_jobs": %s, "free_slots": %s,\n' "$running_jobs_json" "$free_slots"
  printf '  "concurrent_reload_deferred": %s,\n' "$defer_reload"
  printf '  "queued_jobs": null,\n'
  printf '  "queued_note": "%s",\n' "$escaped_queued_note"
  printf '  "nix_max_jobs": %s, "nix_cores": %s,\n' "$nix_max_jobs" "$nix_cores"
  printf '  "memory_high_mb": %s, "memory_max_mb": %s, "memory_max_applied_mb": %s, "clamp_lower_deferred": %s,\n' "$memory_high_mb" "$memory_max_mb" "${state_max_mb:-null}" "$clamp_lower_deferred"
  printf '  "failsafe": %s, "reason": "%s"\n' "$failsafe" "$escaped_reason"
  printf '}\n'
} > "$tmp_status"
mv "$tmp_status" "$STATUS_FILE"

summary_prefix=""
if [ "$failsafe" = true ]; then
  summary_prefix="FAILSAFE "
fi
echo "runner-budget: ${summary_prefix}avail=${mem_available_mb}MiB budget=${budget_mb}MiB -> concurrent=${applied_target}/${MAX_CONCURRENT} (heavy_slots=${heavy_slots}, light_slots=${light_slots}, running=${running_jobs_summary}) nix(max-jobs=${nix_max_jobs},cores=${nix_cores}) clamp(high=${memory_high_mb}M,max=${memory_max_mb}M)"
