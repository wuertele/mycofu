#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

OPS_MD="${REPO_ROOT}/OPERATIONS.md"
BENCH_MD="${REPO_ROOT}/benchmarks/README.md"
SCRIPTS_MD="${REPO_ROOT}/framework/scripts/README.md"
CI_YAML="${REPO_ROOT}/.gitlab-ci.yml"

combined_contains() {
  local pattern="$1"
  grep -q "$pattern" "$OPS_MD" "$BENCH_MD" "$SCRIPTS_MD" "$CI_YAML"
}

test_start "1" "scheduled benchmark docs mention config and CI surfaces"
if combined_contains 'benchmarks.scheduled' && \
   combined_contains 'bench:scheduled' && \
   combined_contains 'BENCH_SCHEDULE_KEY'; then
  test_pass "docs cover benchmarks.scheduled, bench:scheduled, and BENCH_SCHEDULE_KEY"
else
  test_fail "scheduled benchmark docs are missing config or CI surface names"
fi

test_start "2" "docs state the opt-in field lives in site/config.yaml"
if grep -q 'site/config.yaml' "$OPS_MD" && \
   grep -q 'benchmarks.scheduled.enabled' "$OPS_MD" && \
   grep -q 'site/config.yaml' "$BENCH_MD"; then
  test_pass "docs identify site/config.yaml as the opt-in surface"
else
  test_fail "docs must point operators at site/config.yaml for the benchmarks.scheduled.enabled opt-in"
fi

test_start "3" "docs state failed scheduled benchmark jobs do not page"
if grep -q 'allow_failure: true' "$OPS_MD" && \
   grep -q 'does not page' "$OPS_MD" && \
   grep -q 'allow_failure: true' "$BENCH_MD" && \
   grep -q 'does not page' "$BENCH_MD"; then
  test_pass "non-paging allow_failure behavior is documented"
else
  test_fail "docs must explain allow_failure and non-paging scheduled benchmark failures"
fi

test_start "4" "docs record deferred Gatus and Grafana follow-ups"
if grep -q 'Gatus recent-run sentinel' "$OPS_MD" && \
   grep -q 'Gatus recent-run sentinel' "$BENCH_MD" && \
   grep -q 'Grafana #268' "$OPS_MD" && \
   grep -q 'Grafana #268' "$BENCH_MD"; then
  test_pass "Gatus sentinel and Grafana #268 follow-ups are documented"
else
  test_fail "docs must keep Gatus sentinel and Grafana #268 as follow-ups"
fi

runner_summary
