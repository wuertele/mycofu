#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/framework/nix/modules/gitlab-runner-budget.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/runner-budget-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

write_meminfo() {
  local path="$1" avail_mb="$2"
  {
    printf 'MemTotal:       62914560 kB\n'
    printf 'MemAvailable:  %s kB\n' "$((avail_mb * 1024))"
  } > "$path"
}

init_config() {
  local root="$1"
  mkdir -p "$root/persist"
  {
    printf '[[runners]]\n'
    printf '  name = "fixture"\n'
  } > "$root/config.toml"
}

run_budget() {
  local root="$1" meminfo="$2"
  RUNNER_BUDGET_APPLY=0 \
    RUNNER_BUDGET_MEMINFO="$meminfo" \
    RUNNER_BUDGET_STATE_FILE="$root/state" \
    RUNNER_BUDGET_STATUS_FILE="$root/status.json" \
    RUNNER_BUDGET_NIX_CONF="$root/nix-budget.conf" \
    GITLAB_RUNNER_CONFIG_FILE="$root/config.toml" \
    GITLAB_RUNNER_PERSISTED_CONFIG="$root/persist/config.toml" \
    bash "$SCRIPT" > "$root/stdout" 2> "$root/stderr"
}

target_for() {
  jq -r '.target_concurrent' "$1/status.json"
}

first_concurrent() {
  sed -n 's/^concurrent = \([0-9][0-9]*\)$/\1/p;q' "$1/config.toml"
}

warm_fixture() {
  local root="$1" avail_mb="$2"
  init_config "$root"
  write_meminfo "$root/meminfo" "$avail_mb"
  run_budget "$root" "$root/meminfo"
  run_budget "$root" "$root/meminfo"
  run_budget "$root" "$root/meminfo"
}

# V5.1: MemTotal is the trap. Every fixture advertises a fixed 60 GiB
# MemTotal while MemAvailable varies; reading MemTotal for admission would
# produce the same target in all three cases.
high_root="$TMP_ROOT/memtotal-high"
mkdir -p "$high_root"
warm_fixture "$high_root" 56320
[[ "$(target_for "$high_root")" == "8" ]] || fail "55 GiB available should hit maxConcurrent=8"
[[ "$(first_concurrent "$high_root")" == "8" ]] || fail "high fixture config did not converge to 8"

floor_root="$TMP_ROOT/memtotal-floor"
mkdir -p "$floor_root"
warm_fixture "$floor_root" 8192
[[ "$(target_for "$floor_root")" == "1" ]] || fail "8 GiB available should serialize to 1"
[[ "$(first_concurrent "$floor_root")" == "1" ]] || fail "floor fixture config did not converge to 1"

middle_root="$TMP_ROOT/memtotal-middle"
mkdir -p "$middle_root"
warm_fixture "$middle_root" 20480
[[ "$(target_for "$middle_root")" == "6" ]] || fail "20 GiB available should produce target 6"
[[ "$(first_concurrent "$middle_root")" == "6" ]] || fail "middle fixture config did not converge to 6"
ok "V5.1 MemAvailable drives admission while fixed MemTotal is ignored"

transition_root="$TMP_ROOT/up-confirm"
mkdir -p "$transition_root"
warm_fixture "$transition_root" 8192
write_meminfo "$transition_root/meminfo" 20480
run_budget "$transition_root" "$transition_root/meminfo"
run_budget "$transition_root" "$transition_root/meminfo"
run_budget "$transition_root" "$transition_root/meminfo"
[[ "$(target_for "$transition_root")" == "1" ]] || fail "first higher proposal after min-of-3 warmup must still hold at 1"
run_budget "$transition_root" "$transition_root/meminfo"
[[ "$(target_for "$transition_root")" == "6" ]] || fail "second consecutive higher proposal should apply target 6"
ok "increase hysteresis requires two confirmed higher proposals"

# V5.2: a 100 MiB sawtooth around the 1/2 slot boundary should only write the
# config once, on the immediate safety-direction decrease.
thrash_root="$TMP_ROOT/anti-thrash"
mkdir -p "$thrash_root"
warm_fixture "$thrash_root" 11280
[[ "$(target_for "$thrash_root")" == "2" ]] || fail "anti-thrash warmup should start at target 2"
before_sum="$(cksum < "$thrash_root/config.toml")"
write_count=0
for avail in 11180 11280 11180 11280 11180 11280 11180 11280; do
  write_meminfo "$thrash_root/meminfo" "$avail"
  run_budget "$thrash_root" "$thrash_root/meminfo"
  after_sum="$(cksum < "$thrash_root/config.toml")"
  if [[ "$after_sum" != "$before_sum" ]]; then
    write_count=$((write_count + 1))
    before_sum="$after_sum"
  fi
done
[[ "$write_count" -le 1 ]] || fail "100 MiB sawtooth caused ${write_count} config writes; expected at most one"
ok "V5.2 anti-thrash sawtooth produces at most one config write"

# V5.3: all bad inputs fail closed to target=1, with JSON and stderr evidence.
check_failsafe() {
  local name="$1" meminfo="$2"
  local root="$TMP_ROOT/failsafe-${name}"
  mkdir -p "$root"
  init_config "$root"
  run_budget "$root" "$meminfo"
  [[ "$(target_for "$root")" == "1" ]] || fail "${name}: failsafe target is not 1"
  jq -e '.failsafe == true' "$root/status.json" >/dev/null || fail "${name}: status does not mark failsafe"
  grep -q 'FAILSAFE' "$root/stderr" || fail "${name}: stderr lacks loud FAILSAFE marker"
}

missing_path="$TMP_ROOT/does-not-exist"
check_failsafe "unreadable" "$missing_path"

absent_root="$TMP_ROOT/memavailable-absent"
mkdir -p "$absent_root"
printf 'MemTotal:       62914560 kB\n' > "$absent_root/meminfo"
check_failsafe "absent" "$absent_root/meminfo"

abc_root="$TMP_ROOT/memavailable-abc"
mkdir -p "$abc_root"
{
  printf 'MemTotal:       62914560 kB\n'
  printf 'MemAvailable:  abc kB\n'
} > "$abc_root/meminfo"
check_failsafe "abc" "$abc_root/meminfo"

zero_root="$TMP_ROOT/budget-zero"
mkdir -p "$zero_root"
write_meminfo "$zero_root/meminfo" 512
check_failsafe "budget-zero" "$zero_root/meminfo"
ok "V5.3 fail-safe inputs serialize and log loudly"

# Operator parallelism report: JSON is parseable and includes the observable
# fields, with queued jobs explicitly null because GitLab holds them server-side.
report_root="$TMP_ROOT/report"
mkdir -p "$report_root"
warm_fixture "$report_root" 20480
jq -e '
  .schema == 1
  and (.target_concurrent | type == "number")
  and (.slots.heavy | type == "number")
  and (.slots.light | type == "number")
  and (.nix_max_jobs | type == "number")
  and (.memory_high_mb | type == "number")
  and (.memory_max_mb | type == "number")
  and .queued_jobs == null
  and (.queued_note | test("server-side"))
' "$report_root/status.json" >/dev/null || fail "status JSON is missing required report fields"
grep -q '^runner-budget: avail=' "$report_root/stdout" || fail "summary line missing from stdout"
ok "parallelism report JSON and summary line are emitted"

# Nix lever: the runtime include serializes at the floor and caps at maxNixJobs
# for large budgets.
nix_floor_root="$TMP_ROOT/nix-floor"
mkdir -p "$nix_floor_root"
warm_fixture "$nix_floor_root" 8192
grep -qx 'max-jobs = 1' "$nix_floor_root/nix-budget.conf" || fail "floor nix budget did not set max-jobs = 1"
# At the floor (serialized, target=1) cores are LIMITED to floorCores=4, not 0/all.
grep -qx 'cores = 4' "$nix_floor_root/nix-budget.conf" || fail "floor nix budget did not limit cores to floorCores=4"

nix_large_root="$TMP_ROOT/nix-large"
mkdir -p "$nix_large_root"
warm_fixture "$nix_large_root" 56320
grep -qx 'max-jobs = 4' "$nix_large_root/nix-budget.conf" || fail "large nix budget did not clamp max-jobs to maxNixJobs=4"
# With wide admission (target>1) cores are unbounded (0 = all cores per build).
grep -qx 'cores = 0' "$nix_large_root/nix-budget.conf" || fail "large nix budget did not set cores = 0 (all cores) at wide admission"
ok "nix max-jobs/cores lever tracks floor (max-jobs=1, cores=4) and large budgets (max-jobs=4, cores=0)"

# Corrupted state must never drive `concurrent` out of the 1..max band. A
# last_target=0 (from a truncated/garbled /run state file) would otherwise be
# held by the increase-hysteresis branch and written as `concurrent = 0`.
corrupt_root="$TMP_ROOT/corrupt-state"
mkdir -p "$corrupt_root"
init_config "$corrupt_root"
write_meminfo "$corrupt_root/meminfo" 56320
printf 'samples=56320 56320 56320\nlast_target=0\nup_confirm=9\nmemory_high_mb=0\nmemory_max_mb=0\n' > "$corrupt_root/state"
run_budget "$corrupt_root" "$corrupt_root/meminfo"
observed="$(target_for "$corrupt_root")"
[[ "$observed" -ge 1 ]] || fail "corrupted last_target=0 produced target ${observed} (< 1)"
[[ "$(first_concurrent "$corrupt_root")" -ge 1 ]] || fail "corrupted state wrote concurrent < 1"
# An out-of-band last_target (above the cap) must likewise be discarded, not held.
printf 'samples=56320 56320 56320\nlast_target=99\nup_confirm=0\nmemory_high_mb=0\nmemory_max_mb=0\n' > "$corrupt_root/state"
run_budget "$corrupt_root" "$corrupt_root/meminfo"
[[ "$(target_for "$corrupt_root")" -le 8 ]] || fail "corrupted last_target=99 was not clamped to the cap"
ok "corrupted state file cannot drive concurrent outside 1..maxConcurrent"

# A non-numeric config knob must fail CLOSED (serialize), not abort arithmetic
# under set -e nor emit invalid JSON.
knob_root="$TMP_ROOT/bad-knob"
mkdir -p "$knob_root"
init_config "$knob_root"
write_meminfo "$knob_root/meminfo" 56320
RUNNER_BUDGET_APPLY=0 \
  RUNNER_BUDGET_MAX_CONCURRENT=abc \
  RUNNER_BUDGET_MEMINFO="$knob_root/meminfo" \
  RUNNER_BUDGET_STATE_FILE="$knob_root/state" \
  RUNNER_BUDGET_STATUS_FILE="$knob_root/status.json" \
  RUNNER_BUDGET_NIX_CONF="$knob_root/nix-budget.conf" \
  GITLAB_RUNNER_CONFIG_FILE="$knob_root/config.toml" \
  GITLAB_RUNNER_PERSISTED_CONFIG="$knob_root/persist/config.toml" \
  bash "$SCRIPT" > "$knob_root/stdout" 2> "$knob_root/stderr" || fail "bad knob crashed the script instead of failing safe"
[[ "$(target_for "$knob_root")" == "1" ]] || fail "bad knob did not serialize to 1"
jq -e '.failsafe == true' "$knob_root/status.json" >/dev/null || fail "bad knob produced invalid or non-failsafe JSON"
ok "non-numeric config knob fails closed with valid JSON"

# A ZERO divisor knob (HEAVY_RESERVE_MB=0) would divide-by-zero and crash before the
# fail-safe path. It must instead be caught as an invalid knob and serialize with
# valid JSON. Also covers FLOOR_MB <= OS_RESERVE_MB.
for badenv in "RUNNER_BUDGET_HEAVY_RESERVE_MB=0" "RUNNER_BUDGET_LIGHT_JOB_MB=0" "RUNNER_BUDGET_FLOOR_MB=1024 RUNNER_BUDGET_OS_RESERVE_MB=2048"; do
  zk_root="$TMP_ROOT/zero-knob-$(echo "$badenv" | tr ' =' '__')"
  mkdir -p "$zk_root"
  init_config "$zk_root"
  write_meminfo "$zk_root/meminfo" 56320
  # shellcheck disable=SC2086
  env $badenv RUNNER_BUDGET_APPLY=0 \
    RUNNER_BUDGET_MEMINFO="$zk_root/meminfo" \
    RUNNER_BUDGET_STATE_FILE="$zk_root/state" \
    RUNNER_BUDGET_STATUS_FILE="$zk_root/status.json" \
    RUNNER_BUDGET_NIX_CONF="$zk_root/nix-budget.conf" \
    GITLAB_RUNNER_CONFIG_FILE="$zk_root/config.toml" \
    GITLAB_RUNNER_PERSISTED_CONFIG="$zk_root/persist/config.toml" \
    bash "$SCRIPT" > "$zk_root/stdout" 2> "$zk_root/stderr" || fail "zero/invalid knob ($badenv) crashed instead of failing safe"
  [[ "$(target_for "$zk_root")" == "1" ]] || fail "invalid knob ($badenv) did not serialize to 1"
  jq -e '.failsafe == true' "$zk_root/status.json" >/dev/null || fail "invalid knob ($badenv) produced invalid or non-failsafe JSON"
  # The cgroup clamp must never collapse to 0M (which would OOM-kill everything): even
  # under an inverted floor/reserve pair, the repaired defaults keep it positive.
  jq -e '.memory_max_mb > 0 and .memory_high_mb > 0' "$zk_root/status.json" >/dev/null \
    || fail "invalid knob ($badenv) drove the cgroup clamp to a non-positive MemoryMax/MemoryHigh"
done
ok "zero divisor / floor<=reserve knobs fail closed with valid JSON, positive clamp, no crash"

# Clamp reductions must NOT preempt a running build. The idle proof is the count of
# DIRECT JOB CHILDREN of the runner MainPID (pgrep -P) being zero — NOT TasksCurrent,
# which counts the runner daemon's own Go threads (~30 even when idle) and would pin a
# widened MemoryMax forever. The fakes below drive MainPID + pgrep children directly.
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
# $1 = MainPID ("" => unreadable, i.e. runner down / unknown)
# $2 = running job children: a number (pgrep -P output), or "err" => pgrep exits 2
# $3 = TasksCurrent (a high value here proves the idle decision ignores it)
# $4 = file to record set-property calls
make_fake_runner() {
  local main_pid="$1" jobs="$2" tasks="$3" applied_file="$4"
  cat > "$FAKEBIN/systemctl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"set-property"*) printf '%s\n' "\$*" >> "$applied_file" ;;
  *"-p MainPID"*) printf '%s\n' "$main_pid" ;;
  *"-p TasksCurrent"*) printf '%s\n' "$tasks" ;;
  *"kill"*) printf '%s\n' "\$*" >> "${applied_file}.kill" ;;
  *) : ;;
esac
exit 0
EOF
  chmod +x "$FAKEBIN/systemctl"
  cat > "$FAKEBIN/pgrep" <<EOF
#!/usr/bin/env bash
# pgrep -P <mainpid>: emit \$jobs fake child pids (exit 1 when none, exit 0 when some,
# exit 2 on "err" to simulate a pgrep failure — which must be read as UNKNOWN/busy).
if [ "$jobs" = "err" ]; then exit 2; fi
n=$jobs
i=0
while [ \$i -lt \$n ]; do echo \$((5000 + i)); i=\$((i + 1)); done
[ \$n -gt 0 ]
EOF
  chmod +x "$FAKEBIN/pgrep"
}

run_budget_apply() {
  local root="$1" meminfo="$2"
  PATH="$FAKEBIN:$PATH" RUNNER_BUDGET_APPLY=1 \
    RUNNER_BUDGET_MEMINFO="$meminfo" \
    RUNNER_BUDGET_STATE_FILE="$root/state" \
    RUNNER_BUDGET_STATUS_FILE="$root/status.json" \
    RUNNER_BUDGET_NIX_CONF="$root/nix-budget.conf" \
    GITLAB_RUNNER_CONFIG_FILE="$root/config.toml" \
    GITLAB_RUNNER_PERSISTED_CONFIG="$root/persist/config.toml" \
    bash "$SCRIPT" > "$root/stdout" 2> "$root/stderr"
}

defer_root="$TMP_ROOT/clamp-defer"
mkdir -p "$defer_root"
init_config "$defer_root"
applied="$defer_root/applied"
# Warm high while idle (no job children): the clamp is set to a high MemoryMax.
make_fake_runner 4242 0 30 "$applied"
write_meminfo "$defer_root/meminfo" 56320
run_budget_apply "$defer_root" "$defer_root/meminfo"
high_max="$(jq -r '.memory_max_mb' "$defer_root/status.json")"
# Now the VM balloons down and a job IS running (2 children): the lowering defers.
make_fake_runner 4242 2 30 "$applied"
write_meminfo "$defer_root/meminfo" 8192
run_budget_apply "$defer_root" "$defer_root/meminfo"
jq -e '.clamp_lower_deferred == true' "$defer_root/status.json" >/dev/null \
  || fail "busy runner (2 job children) did not defer the MemoryMax reduction"
last_applied_max="$(grep -oE 'MemoryMax=[0-9]+M' "$applied" | tail -1 | grep -oE '[0-9]+')"
[[ "$last_applied_max" -ge "$high_max" ]] || fail "MemoryMax was lowered to ${last_applied_max}M while a build was running (prior ${high_max}M)"
# memory_max_applied_mb must report the still-high applied value, not the desired one.
[[ "$(jq -r '.memory_max_applied_mb' "$defer_root/status.json")" -ge "$high_max" ]] \
  || fail "memory_max_applied_mb dropped while the reduction was deferred"
# Unknown state (MainPID unreadable) must also fail closed and defer.
make_fake_runner "" 0 30 "$applied"
run_budget_apply "$defer_root" "$defer_root/meminfo"
jq -e '.clamp_lower_deferred == true' "$defer_root/status.json" >/dev/null \
  || fail "unreadable MainPID did not fail closed (defer) on a MemoryMax reduction"
# A pgrep ERROR (exit >=2) on a valid MainPID is UNKNOWN, not "0 children" — it must
# fail closed (defer), never map to idle and preempt a build we cannot enumerate.
make_fake_runner 4242 err 30 "$applied"
run_budget_apply "$defer_root" "$defer_root/meminfo"
jq -e '.clamp_lower_deferred == true' "$defer_root/status.json" >/dev/null \
  || fail "a pgrep error was treated as idle (fail-open) instead of deferring the MemoryMax reduction"
jq -e '.running_jobs == null' "$defer_root/status.json" >/dev/null \
  || fail "a pgrep error should leave running_jobs unknown (null), not 0"
# Idle with a HIGH TasksCurrent (30) but ZERO job children: the reduction MUST apply.
# This is the exact bug both reviewers caught — an idle-proof on TasksCurrent<=1 would
# wrongly keep deferring here and pin the clamp wide forever.
make_fake_runner 4242 0 30 "$applied"
run_budget_apply "$defer_root" "$defer_root/meminfo"
jq -e '.clamp_lower_deferred == false' "$defer_root/status.json" >/dev/null \
  || fail "idle runner (0 job children, TasksCurrent=30) still deferred the MemoryMax reduction"
final_applied_max="$(grep -oE 'MemoryMax=[0-9]+M' "$applied" | tail -1 | grep -oE '[0-9]+')"
[[ "$final_applied_max" -lt "$high_max" ]] || fail "idle runner did not apply the MemoryMax reduction"
# Drift-heal: an IDLE runner RE-applies the clamp every cycle even when the desired
# value already equals the cached state, so a stale /run cache can never hide a
# widened actual clamp left by an interrupted prior apply (set-property landed but the
# state write did not). Re-run idle at the same budget: a fresh set-property must fire.
before_n="$(grep -c 'set-property' "$applied")"
make_fake_runner 4242 0 30 "$applied"
run_budget_apply "$defer_root" "$defer_root/meminfo"
after_n="$(grep -c 'set-property' "$applied")"
[[ "$after_n" -gt "$before_n" ]] \
  || fail "idle runner did not re-apply (reconcile) the clamp when desired==cached state; a stale cache could hide a widened actual clamp"
ok "MemoryMax reduction defers while a job runs / state unknown, applies when idle, and idle reconciles every cycle (drift-heal)"

# #578: a concurrent-value reload must target ONLY the runner main process
# (systemctl kill --kill-whom=main), never the whole cgroup. gitlab-runner.service
# runs with KillMode=control-group, so a bare cgroup-wide SIGHUP reaches every job
# shell and kills running jobs (`signal: hangup`). Assert the reload command shape.
reload_root="$TMP_ROOT/reload-main-only"
mkdir -p "$reload_root"
init_config "$reload_root"
applied_r="$reload_root/applied"
# Idle (0 job children): a fresh concurrency value writes config and reloads.
make_fake_runner 4242 0 30 "$applied_r"
write_meminfo "$reload_root/meminfo" 56320
run_budget_apply "$reload_root" "$reload_root/meminfo"
[[ "$(first_concurrent "$reload_root")" == "8" ]] || fail "idle apply did not write concurrent=8"
[[ -f "${applied_r}.kill" ]] || fail "idle concurrency change did not reload the runner"
grep -q -- '--kill-whom=main' "${applied_r}.kill" \
  || fail "runner reload did not restrict SIGHUP to the main process (--kill-whom=main)"
ok "#578 concurrent reload signals only the runner main process, not the cgroup"

# Defense-in-depth (#578): while a job runs, a concurrency change is deferred
# (config not rewritten, no reload) and applies on the next idle cycle.
bd_root="$TMP_ROOT/reload-defer-busy"
mkdir -p "$bd_root"
init_config "$bd_root"
applied_bd="$bd_root/applied"
# Converge to 8 while idle.
make_fake_runner 4242 0 30 "$applied_bd"
write_meminfo "$bd_root/meminfo" 56320
run_budget_apply "$bd_root" "$bd_root/meminfo"
[[ "$(first_concurrent "$bd_root")" == "8" ]] || fail "idle warmup did not converge config to 8"
rm -f "${applied_bd}.kill"
# A job is now running (2 children) and the budget collapses to the floor: defer.
make_fake_runner 4242 2 30 "$applied_bd"
write_meminfo "$bd_root/meminfo" 8192
run_budget_apply "$bd_root" "$bd_root/meminfo"
[[ "$(first_concurrent "$bd_root")" == "8" ]] || fail "busy runner rewrote concurrent (must defer to next idle cycle)"
[[ ! -f "${applied_bd}.kill" ]] || fail "busy runner issued a reload (must defer while a job runs)"
grep -q 'deferred' "$bd_root/stderr" || fail "busy runner did not log the concurrency-change deferral"
jq -e '.concurrent_reload_deferred == true' "$bd_root/status.json" >/dev/null \
  || fail "busy runner did not report concurrent_reload_deferred=true in status JSON"
# Job finishes (idle again): the deferred change now applies and reloads main-only.
make_fake_runner 4242 0 30 "$applied_bd"
run_budget_apply "$bd_root" "$bd_root/meminfo"
[[ "$(first_concurrent "$bd_root")" == "1" ]] || fail "idle cycle did not apply the deferred concurrent=1"
grep -q -- '--kill-whom=main' "${applied_bd}.kill" \
  || fail "deferred reload did not fire main-only on the next idle cycle"
jq -e '.concurrent_reload_deferred == false' "$bd_root/status.json" >/dev/null \
  || fail "idle cycle still reported concurrent_reload_deferred=true"
ok "#578 concurrency change defers while a job runs, applies main-only on next idle cycle"

# #578 P1 (boot ordering): mycofu-runner-budget.service is ordered BEFORE
# gitlab-runner.service, so at first boot MainPID=0 and the runner is DOWN — not
# busy. Config normalization MUST still happen (else a stale/default concurrent
# leaks into the runner on start); only the reload is skipped (no main process to
# signal). A "down = not idle = defer" gate would wrongly skip the boot write.
boot_root="$TMP_ROOT/boot-runner-down"
mkdir -p "$boot_root"
init_config "$boot_root"
applied_boot="$boot_root/applied"
make_fake_runner "" 0 30 "$applied_boot"   # MainPID unreadable => runner down
write_meminfo "$boot_root/meminfo" 56320
run_budget_apply "$boot_root" "$boot_root/meminfo"
[[ "$(first_concurrent "$boot_root")" == "8" ]] \
  || fail "down runner (boot) did not normalize concurrent; config write must not defer when no runner is up"
[[ ! -f "${applied_boot}.kill" ]] || fail "down runner issued a reload (there is no main process to signal)"
grep -q 'reload skipped' "$boot_root/stderr" || fail "down runner did not log that the reload was skipped"
jq -e '.concurrent_reload_deferred == false' "$boot_root/status.json" >/dev/null \
  || fail "down runner reported a deferral instead of writing config for the next start"
ok "#578 boot: config normalizes while the runner is down; reload skipped (no MainPID)"

if command -v nix >/dev/null 2>&1; then
  # Corrected-D1 ratchet: the memory backstop is on gitlab-runner.service,
  # because shell-executor nix builds live in that cgroup, not nix-daemon.
  runner_service_config="$(nix eval --json '.#nixosConfigurations.cicd.config.systemd.services.gitlab-runner.serviceConfig')"
  echo "$runner_service_config" | jq -e '
    .MemoryAccounting == true
    and (.MemoryHigh | test("^[0-9]+M$"))
    and (.MemoryMax | test("^[0-9]+M$"))
    and .OOMPolicy == "continue"
  ' >/dev/null || fail "gitlab-runner.service lacks the corrected memory backstop"

  nix_daemon_service_config="$(nix eval --json '.#nixosConfigurations.cicd.config.systemd.services.nix-daemon.serviceConfig')"
  echo "$nix_daemon_service_config" | jq -e 'has("MemoryMax") | not' >/dev/null \
    || fail "nix-daemon.service must not carry MemoryMax; clamp belongs on gitlab-runner.service"
  ok "V5.5 corrected backstop is on gitlab-runner.service, not nix-daemon.service"
else
  ok "nix not available; skipped V5.5 nix eval backstop ratchet"
fi
