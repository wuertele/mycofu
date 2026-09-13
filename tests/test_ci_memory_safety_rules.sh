#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# Fail-closed: a malformed .gitlab-ci.yml must fail the test, not silently pass.
yq '.' "${CI_FILE}" >/dev/null 2>&1 || fail ".gitlab-ci.yml failed yq parse"

GROUP="ci-heavy-nix-eval"
PIGS=("validate:per-role-isolation" "validate:nix-checks")

# 1. Both pigs carry the exact shared resource_group (pinned literal; a rename
#    would silently split the cross-pipeline serialization pool).
for job in "${PIGS[@]}"; do
  rg="$(J="$job" yq -r '.[strenv(J)].resource_group' "${CI_FILE}")"
  [[ "$rg" == "$GROUP" ]] || fail "$job resource_group is '$rg', expected '$GROUP'"
  ok "$job carries resource_group $GROUP"
done

# 2. Group confinement: EXACTLY the two pigs carry the group and no other job
#    (an accidental application to a light job over-serializes silently).
actual="$(G="$GROUP" yq -r 'to_entries | map(select((.value | tag == "!!map") and (.value.resource_group == strenv(G)))) | .[].key' "${CI_FILE}" | sort | tr '\n' ' ' | sed 's/ *$//')"
expected="validate:nix-checks validate:per-role-isolation"
[[ "$actual" == "$expected" ]] || fail "jobs with $GROUP are [$actual], expected exactly [$expected]"
ok "resource_group $GROUP confined to exactly the two pig jobs"

# 3. build-image group regression guard (Plan R-6): existing per-role build
#    serialization must be untouched.
count_group() { G="$1" yq -r '[to_entries[] | select((.value | tag == "!!map") and (.value.resource_group == strenv(G)))] | length' "${CI_FILE}"; }
[[ "$(count_group 'build-image-${ROLE}')" == "2" ]] || fail "build-image-\${ROLE} resource_group count changed (expected 2)"
[[ "$(count_group 'build-image-hil-boot')" == "1" ]] || fail "build-image-hil-boot resource_group count changed (expected 1)"
ok "build-image resource_groups intact (\${ROLE}x2, hil-bootx1)"

# 4. Rule retention, structural + when:never-resilient. For each guarded job and
#    each enabling condition (MR / dev / prod): a matching rule must exist AND no
#    matching rule may be disabled with when: never. A bare substring grep would
#    miss a disabling clause; this inspects .when on the matching rule entries.
rule_enabled() {  # $1=job  $2=token(regex)  $3=label
  local whens
  whens="$(J="$1" T="$2" yq -r '.[strenv(J)].rules[] | select(.if != null and (.if | test(strenv(T)))) | (.when // "on_success")' "${CI_FILE}")"
  [[ -n "$whens" ]] || fail "$1: no rule matches the $3 condition (removed?)"
  if grep -qx 'never' <<< "$whens"; then fail "$1: the $3 rule is disabled with when: never"; fi
  ok "$1: $3 rule present and enabled"
}
GUARDED=("${PIGS[@]}" "validate:cicd-memory-safety")
for job in "${GUARDED[@]}"; do
  rule_enabled "$job" 'merge_request_event' 'merge-request'
  rule_enabled "$job" 'dev"'                'dev-branch'
  rule_enabled "$job" 'prod"'               'prod-branch'
done

# 5. Wiring: the guard job must exist and actually run this test (an unwired
#    ratchet is the exact P1 defect this rework fixes).
if ! yq -r '.["validate:cicd-memory-safety"].script[]' "${CI_FILE}" | grep -qx 'bash tests/test_ci_memory_safety_rules.sh'; then
  fail "validate:cicd-memory-safety is not wired to run tests/test_ci_memory_safety_rules.sh"
fi
ok "validate:cicd-memory-safety is wired to run this test"

exit 0
