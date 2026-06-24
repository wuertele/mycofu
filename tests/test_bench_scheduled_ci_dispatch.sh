#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

CI_YML="${REPO_ROOT}/.gitlab-ci.yml"

job_names() {
  yq -r 'to_entries[] | select((.value | tag) == "!!map" and (.value.script != null)) | .key' "$CI_YML"
}

job_matches() {
  local job="$1" source="$2" branch="$3" bench_key="$4"
  local idx=0 rule_if when
  while true; do
    rule_if="$(yq -r ".\"${job}\".rules[${idx}].if // \"\"" "$CI_YML")"
    when="$(yq -r ".\"${job}\".rules[${idx}].when // \"on_success\"" "$CI_YML")"
    [[ -n "$rule_if" ]] || return 1
    case "$rule_if" in
      '$BENCH_SCHEDULE_KEY')
        if [[ -n "$bench_key" ]]; then
          [[ "$when" == "never" ]] && return 1
          return 0
        fi
        ;;
      '$CI_PIPELINE_SOURCE == "schedule" && $BENCH_SCHEDULE_KEY == "bench-nightly"')
        if [[ "$source" == "schedule" && "$bench_key" == "bench-nightly" ]]; then
          [[ "$when" == "never" ]] && return 1
          return 0
        fi
        ;;
      '$CI_PIPELINE_SOURCE == "schedule"')
        if [[ "$source" == "schedule" ]]; then
          [[ "$when" == "never" ]] && return 1
          return 0
        fi
        ;;
      '$CI_PIPELINE_SOURCE == "merge_request_event"')
        if [[ "$source" == "merge_request_event" ]]; then
          [[ "$when" == "never" ]] && return 1
          return 0
        fi
        ;;
      '$CI_COMMIT_BRANCH == "dev"' | '$CI_PIPELINE_SOURCE != "web" && $CI_COMMIT_BRANCH == "dev"')
        if [[ "$branch" == "dev" && "$source" != "web" ]]; then
          [[ "$when" == "never" ]] && return 1
          return 0
        fi
        ;;
      '$CI_COMMIT_BRANCH == "prod"' | '$CI_PIPELINE_SOURCE != "web" && $CI_COMMIT_BRANCH == "prod"')
        if [[ "$branch" == "prod" && "$source" != "web" ]]; then
          [[ "$when" == "never" ]] && return 1
          return 0
        fi
        ;;
    esac
    idx=$((idx + 1))
  done
}

matching_jobs() {
  local source="$1" branch="$2" bench_key="$3"
  while IFS= read -r job; do
    [[ -n "$job" ]] || continue
    if job_matches "$job" "$source" "$branch" "$bench_key"; then
      printf '%s\n' "$job"
    fi
  done < <(job_names)
}

test_start "1" "bench:scheduled job shape"
if [[ "$(yq -r '."bench:scheduled".allow_failure' "$CI_YML")" == "true" ]] &&
   yq -e '."bench:scheduled".script[] | select(. == "benchmarks/run-scheduled-bench.sh")' "$CI_YML" >/dev/null &&
   yq -e '."bench:scheduled".artifacts.when == "always"' "$CI_YML" >/dev/null &&
   yq -e '."bench:scheduled".artifacts.paths[] | select(. == "build/bench-scheduled/status.json")' "$CI_YML" >/dev/null &&
   [[ "$(yq -r '."bench:scheduled".rules[0].if' "$CI_YML")" == '$CI_PIPELINE_SOURCE == "schedule" && $BENCH_SCHEDULE_KEY == "bench-nightly"' ]]; then
  test_pass "bench:scheduled has the expected rule, script, allow_failure, and artifacts"
else
  test_fail "bench:scheduled job shape is wrong"
fi

test_start "2" "every non-bench job short-circuits on BENCH_SCHEDULE_KEY"
missing=()
while IFS= read -r job; do
  [[ "$job" == "bench:scheduled" ]] && continue
  first_if="$(yq -r ".\"${job}\".rules[0].if // \"\"" "$CI_YML")"
  first_when="$(yq -r ".\"${job}\".rules[0].when // \"\"" "$CI_YML")"
  if [[ "$first_if" != '$BENCH_SCHEDULE_KEY' || "$first_when" != "never" ]]; then
    missing+=("$job")
  fi
done < <(job_names)
if [[ "${#missing[@]}" -eq 0 ]]; then
  test_pass "all non-bench jobs have the universal short-circuit"
else
  test_fail "jobs missing BENCH_SCHEDULE_KEY short-circuit: ${missing[*]}"
fi

test_start "3" "bench schedule runs only bench:scheduled"
matches="$(matching_jobs schedule dev bench-nightly | sort | tr '\n' ' ')"
if [[ "$matches" == "bench:scheduled " ]]; then
  test_pass "bench schedule matches only bench:scheduled"
else
  test_fail "bench schedule matched unexpected jobs: $matches"
fi

test_start "4" "regression schedule without BENCH_SCHEDULE_KEY still matches regression"
matches="$(matching_jobs schedule "" "" | sort | tr '\n' ' ')"
if [[ "$matches" == "regression " ]]; then
  test_pass "clickops regression schedule still matches regression only in source-only simulation"
else
  test_fail "regression schedule match set changed: $matches"
fi

test_start "5" "branch push to dev does not run bench or regression"
matches="$(matching_jobs push dev "" | sort | tr '\n' ' ')"
if grep -qw 'deploy:dev' <<< "$matches" &&
   ! grep -qw 'bench:scheduled' <<< "$matches" &&
   ! grep -qw 'regression' <<< "$matches"; then
  test_pass "dev branch push includes deploy:dev and excludes scheduled jobs"
else
  test_fail "dev branch push dispatch wrong: $matches"
fi

test_start "6" "MR pipeline includes validate/build jobs and excludes deploy/bench"
matches="$(matching_jobs merge_request_event feature "" | sort | tr '\n' ' ')"
if grep -qw 'validate:plan' <<< "$matches" &&
   grep -qw 'build:image' <<< "$matches" &&
   ! grep -qw 'deploy:dev' <<< "$matches" &&
   ! grep -qw 'bench:scheduled' <<< "$matches"; then
  test_pass "MR dispatch remains validation/build only"
else
  test_fail "MR dispatch wrong: $matches"
fi

test_start "7" "wrong BENCH_SCHEDULE_KEY fails closed"
matches="$(matching_jobs schedule dev foo | sort | tr '\n' ' ')"
if [[ -z "$matches" ]]; then
  test_pass "wrong BENCH_SCHEDULE_KEY runs no jobs"
else
  test_fail "wrong BENCH_SCHEDULE_KEY matched: $matches"
fi

# ---------------------------------------------------------------------------
# In-script opt-in gate (matches publish:github pattern)
#
# The bench:scheduled job's rule lets it enter the pipeline whenever a
# scheduled pipeline fires with BENCH_SCHEDULE_KEY=bench-nightly. The
# in-script gate then reads `benchmarks.scheduled.enabled` from
# site/config.yaml and exits 0 if the site has not opted in. This
# preserves downstream protection: a freshly cloned Mycofu site that
# accidentally creates the schedule before opting in does not actually
# run any benchmark.
# ---------------------------------------------------------------------------

# Extract the gate's shell snippet from .gitlab-ci.yml so the test
# exercises exactly what runs in CI. We pull lines from the first
# script entry of bench:scheduled.
GATE_SNIPPET="$(yq -r '."bench:scheduled".script[0]' "$CI_YML")"

run_gate() {
  local config_yaml="$1"
  local sandbox stderr_path exit_code
  sandbox="$(mktemp -d)"
  trap 'rm -rf "${sandbox}"' RETURN
  mkdir -p "${sandbox}/site"
  printf '%s' "$config_yaml" > "${sandbox}/site/config.yaml"
  stderr_path="${sandbox}/stderr"
  (
    cd "${sandbox}"
    set +e
    bash -c "${GATE_SNIPPET}" 2>"${stderr_path}"
    echo "EXIT:$?"
  )
  cat "${stderr_path}"
}

test_start "8" "in-script gate: enabled=false exits 0 and logs skip"
GATE_OUT="$(run_gate $'benchmarks:\n  scheduled:\n    enabled: false\n')"
GATE_EXIT="$(printf '%s' "$GATE_OUT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p' | tail -1)"
GATE_LOG="$(printf '%s' "$GATE_OUT" | grep -v '^EXIT:' || true)"
if [[ "$GATE_EXIT" == "0" ]] && grep -q 'skipping' <<< "$GATE_LOG"; then
  test_pass "enabled=false: gate exits 0 with 'skipping' log"
else
  test_fail "enabled=false gate behavior wrong: exit=$GATE_EXIT log=$GATE_LOG"
fi

test_start "9" "in-script gate: enabled=true passes through to orchestrator"
GATE_OUT="$(run_gate $'benchmarks:\n  scheduled:\n    enabled: true\n')"
GATE_EXIT="$(printf '%s' "$GATE_OUT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p' | tail -1)"
GATE_LOG="$(printf '%s' "$GATE_OUT" | grep -v '^EXIT:' || true)"
if [[ "$GATE_EXIT" == "0" ]] && ! grep -q 'skipping' <<< "$GATE_LOG"; then
  test_pass "enabled=true: gate exits 0 without skip log (orchestrator would run next)"
else
  test_fail "enabled=true gate behavior wrong: exit=$GATE_EXIT log=$GATE_LOG"
fi

test_start "10" "in-script gate: field missing entirely falls back to false (fail-safe)"
GATE_OUT="$(run_gate $'some_unrelated_key: value\n')"
GATE_EXIT="$(printf '%s' "$GATE_OUT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p' | tail -1)"
GATE_LOG="$(printf '%s' "$GATE_OUT" | grep -v '^EXIT:' || true)"
if [[ "$GATE_EXIT" == "0" ]] && grep -q 'skipping' <<< "$GATE_LOG"; then
  test_pass "field missing: gate exits 0 with 'skipping' log via // false default"
else
  test_fail "field-missing gate behavior wrong: exit=$GATE_EXIT log=$GATE_LOG"
fi

runner_summary
