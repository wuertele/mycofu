#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"
HIL_FILE="${REPO_ROOT}/tests/hil/.gitlab-ci-hil.yml"

render_without_hil_include() {
  yq -o=json '.' "$CI_FILE" | jq '
    del(.include)
    | with_entries(
        select(
          (.value | type) != "object"
          or (((.value.rules // []) | tostring | contains("tests/hil/.gitlab-ci-hil.yml")) | not)
        )
      )
  '
}

test_start "s037.17.1" "root pipeline conditionally includes HIL fragment"
if yq -e '.include[] | select(.local == "tests/hil/.gitlab-ci-hil.yml") | .rules[] | select(.exists[] == "tests/hil/.gitlab-ci-hil.yml")' "$CI_FILE" >/dev/null; then
  test_pass "conditional include is scoped to tests/hil/.gitlab-ci-hil.yml"
else
  test_fail "conditional HIL include missing or unconditional"
fi

test_start "s037.17.2" "workflow allows web pipelines only when HIL fragment exists"
web_rule_count="$(yq -r '[.workflow.rules[] | select(.if == "$CI_PIPELINE_SOURCE == \"web\"")] | length' "$CI_FILE")"
if [[ "$web_rule_count" == "1" ]] && \
   [[ "$(yq -r '.workflow.rules[0].if' "$CI_FILE")" == '$CI_PIPELINE_SOURCE == "web"' ]] && \
   yq -e '.workflow.rules[] | select(.if == "$CI_PIPELINE_SOURCE == \"web\"") | select(.exists[] == "tests/hil/.gitlab-ci-hil.yml")' "$CI_FILE" >/dev/null && \
   ! grep -Eq 'if: \$CI_COMMIT_BRANCH == "(dev|prod)"$' "$CI_FILE"; then
  test_pass "web workflow rule is first, HIL-guarded, and ordinary branch job rules exclude web"
else
  test_fail "web workflow rule is missing, duplicated, unguarded, or branch rules can match web"
fi

test_start "s037.17.3" "regreen-bfnet job is isolated and web-triggered"
if yq -e '."regreen-bfnet".stage == "deploy-dev"' "$HIL_FILE" >/dev/null && \
   yq -e '."regreen-bfnet".needs | length == 0' "$HIL_FILE" >/dev/null && \
   yq -e '."regreen-bfnet".dependencies | length == 0' "$HIL_FILE" >/dev/null && \
   yq -e '."regreen-bfnet".rules[] | select(.if == "$CI_PIPELINE_SOURCE == \"web\"")' "$HIL_FILE" >/dev/null && \
   yq -e '."regreen-bfnet".script[] | select(. == "framework/scripts/regreen-cluster.sh \"${REGREEN_NODE:-all}\"")' "$HIL_FILE" >/dev/null; then
  test_pass "regreen-bfnet has deploy-dev stage, no dependencies, and web-only rule"
else
  test_fail "regreen-bfnet job shape is wrong"
fi

test_start "s037.17.4" "rendered root pipeline without HIL include has no HIL jobs"
rendered="$(render_without_hil_include)"
if ! jq -e 'has("regreen-bfnet")' <<< "$rendered" >/dev/null && \
   ! jq -e 'has("validate:hil-boot-source-filter") or has("validate:install-pve-node") or has("validate:pdu-cycle") or has("validate:regreener-host-module")' <<< "$rendered" >/dev/null && \
   yq -e '.include[] | select(.local == "tests/hil/.gitlab-ci-hil.yml") | .rules[] | select(.exists[] == "tests/hil/.gitlab-ci-hil.yml")' "$CI_FILE" >/dev/null; then
  test_pass "rendered root-only pipeline has no HIL jobs"
else
  test_fail "root-only rendered pipeline still contains HIL jobs or include is not conditional"
fi

test_start "s037.17.7" "HIL validation jobs require HIL fragment existence"
if grep -Fq 'tests/hil/.gitlab-ci-hil.yml' "$CI_FILE" && \
   [[ "$(yq -r '."validate:hil-boot-source-filter".rules' "$CI_FILE")" == '*hil_configured_rules' ]] && \
   [[ "$(yq -r '."validate:install-pve-node".rules' "$CI_FILE")" == '*hil_configured_rules' ]] && \
   [[ "$(yq -r '."validate:pdu-cycle".rules' "$CI_FILE")" == '*hil_configured_rules' ]] && \
   [[ "$(yq -r '."validate:regreener-host-module".rules' "$CI_FILE")" == '*hil_configured_rules' ]]; then
  test_pass "HIL validation jobs share the HIL exists rules"
else
  test_fail "one or more HIL validation jobs are not gated by the HIL exists rules"
fi

test_start "s037.17.8" "hil-boot image matrix entry is conditional in script"
if yq -e '."build:image".parallel.matrix[].ROLE[] | select(. == "hil-boot")' "$CI_FILE" >/dev/null && \
   yq -e '."build:image".script[] | select(. | contains("HIL config absent; skipping hil-boot image build"))' "$CI_FILE" >/dev/null; then
  test_pass "hil-boot matrix entry skips when HIL config is absent"
else
  test_fail "hil-boot image build is not guarded for non-HIL sites"
fi

test_start "s037.17.5" "HIL trigger does not use HIL_REGREEN variable"
if ! rg -n 'HIL_REGREEN' "$CI_FILE" "$HIL_FILE" >/tmp/hil-regreen-var.$$ 2>&1; then
  test_pass "web pipeline source is the HIL regreen signal"
else
  test_fail "HIL_REGREEN variable found"
  cat /tmp/hil-regreen-var.$$ >&2
fi
rm -f /tmp/hil-regreen-var.$$

test_start "s037.17.6" "malformed HIL include fails YAML parsing clearly"
bad="${TMPDIR:-/tmp}/bad-hil-ci.$$.yml"
printf 'regreen-bfnet:\n  script: [unterminated\n' > "$bad"
if yq e '.' "$bad" >/tmp/hil-bad-yaml.$$ 2>&1; then
  test_fail "malformed HIL include unexpectedly parsed"
else
  test_pass "malformed HIL include produces parser error"
fi
rm -f "$bad" /tmp/hil-bad-yaml.$$

runner_summary
