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
   ! jq -e 'has("build:image:hil-boot") or has("build:hil-boot-iso-real") or has("validate:hil-boot-source-filter") or has("validate:install-pve-node") or has("validate:pdu-cycle") or has("validate:regreener-host-module")' <<< "$rendered" >/dev/null && \
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

test_start "s037.17.8" "hil-boot image build is serialized outside ordinary matrix"
build_stage_idx=""
prepare_heavy_stage_idx=""
build_heavy_stage_idx=""
build_merge_stage_idx=""
stage_idx=0
while IFS= read -r stage_name; do
  case "$stage_name" in
    build) build_stage_idx="$stage_idx" ;;
    prepare-heavy) prepare_heavy_stage_idx="$stage_idx" ;;
    build-heavy) build_heavy_stage_idx="$stage_idx" ;;
    build-merge) build_merge_stage_idx="$stage_idx" ;;
  esac
  stage_idx=$((stage_idx + 1))
done < <(yq -r '.stages[]' "$CI_FILE")
hil_boot_nix_config="$(yq -r '."build:image:hil-boot".variables.NIX_CONFIG // ""' "$CI_FILE")"

if ! yq -e '."build:image".parallel.matrix[].ROLE[] | select(. == "hil-boot")' "$CI_FILE" >/dev/null 2>&1 && \
   [[ -n "$build_stage_idx" && -n "$prepare_heavy_stage_idx" && -n "$build_heavy_stage_idx" && -n "$build_merge_stage_idx" ]] && \
   [[ "$build_stage_idx" -lt "$prepare_heavy_stage_idx" ]] && \
   [[ "$prepare_heavy_stage_idx" -lt "$build_heavy_stage_idx" ]] && \
   [[ "$build_heavy_stage_idx" -lt "$build_merge_stage_idx" ]] && \
   [[ "$(yq -r '."prepare:cicd-storage".stage' "$CI_FILE")" == "prepare-heavy" ]] && \
   [[ "$(yq -r '."build:image:hil-boot".stage' "$CI_FILE")" == "build-heavy" ]] && \
   [[ "$(yq -r '."build:merge".stage' "$CI_FILE")" == "build-merge" ]] && \
   [[ "$(yq -r '."build:hil-boot-iso-real".stage' "$CI_FILE")" == "build-merge" ]] && \
   [[ "$(yq -r '."build:image:hil-boot".rules' "$CI_FILE")" == '*hil_configured_rules' ]] && \
   [[ "$(yq -r '."build:image:hil-boot".variables.ROLE' "$CI_FILE")" == "hil-boot" ]] && \
   grep -q 'build-dir = /nix/tmp' <<< "$hil_boot_nix_config" && \
   grep -q 'min-free = 8589934592' <<< "$hil_boot_nix_config" && \
   grep -q 'max-free = 34359738368' <<< "$hil_boot_nix_config" && \
   yq -e '."build:image:hil-boot".dependencies == null' "$CI_FILE" >/dev/null && \
   yq -e '."build:image:hil-boot".needs[] | select(.job == "build:image" and .artifacts == false)' "$CI_FILE" >/dev/null && \
   yq -e '."build:image:hil-boot".needs[] | select(.job == "prepare:cicd-storage" and .artifacts == false and .optional == true)' "$CI_FILE" >/dev/null && \
   yq -e '."build:image:hil-boot".script[] | select(. == "rm -rf build/image-versions")' "$CI_FILE" >/dev/null && \
   yq -e '."build:image:hil-boot".script[] | select(. | contains("framework/scripts/build-image.sh"))' "$CI_FILE" >/dev/null && \
   yq -e '."build:merge".needs[] | select(.job == "prepare:cicd-storage" and .artifacts == false and .optional == true)' "$CI_FILE" >/dev/null && \
   yq -e '."build:merge".needs[] | select(.job == "build:image:hil-boot" and .artifacts == true and .optional == true)' "$CI_FILE" >/dev/null && \
   yq -e '."build:hil-boot-iso-real".needs[] | select(.job == "build:image:hil-boot" and .artifacts == false)' "$CI_FILE" >/dev/null; then
  test_pass "hil-boot image build runs after ordinary images and feeds build:merge"
else
  test_fail "hil-boot image build is not serialized outside the ordinary image matrix"
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
