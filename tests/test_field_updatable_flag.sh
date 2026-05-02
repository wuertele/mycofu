#!/usr/bin/env bash
# test_field_updatable_flag.sh — Verify the allowed field-updatable host set.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

cd "$REPO_ROOT"

test_start "1" "gitlab.nix sets mycofu.fieldUpdatable = true"
if grep -q "mycofu.fieldUpdatable = true" site/nix/hosts/gitlab.nix; then
  test_pass "gitlab sets fieldUpdatable"
else
  test_fail "gitlab does not set fieldUpdatable"
fi

test_start "2" "cicd.nix sets mycofu.fieldUpdatable = true"
if grep -q "mycofu.fieldUpdatable = true" site/nix/hosts/cicd.nix; then
  test_pass "cicd sets fieldUpdatable"
else
  test_fail "cicd does not set fieldUpdatable"
fi

test_start "3" "workstation.nix sets mycofu.fieldUpdatable = true"
if grep -q "mycofu.fieldUpdatable = true" site/nix/hosts/workstation.nix; then
  test_pass "workstation sets fieldUpdatable"
else
  test_fail "workstation does not set fieldUpdatable"
fi

test_start "4" "No other host sets mycofu.fieldUpdatable"
other_hosts=$(grep -rl "mycofu.fieldUpdatable = true" site/nix/hosts/ | grep -v gitlab.nix | grep -v cicd.nix | grep -v workstation.nix || true)
if [[ -z "$other_hosts" ]]; then
  test_pass "no other host sets fieldUpdatable"
else
  test_fail "unexpected hosts set fieldUpdatable: ${other_hosts}"
fi

runner_summary
