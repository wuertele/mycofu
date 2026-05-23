#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

cd "$REPO_ROOT"

test_start "s034.0.6" "flake.nix has an explicit host-tool package exclusion"
if grep -q 'isHostToolPackage' flake.nix && grep -q 'framework/nix/pkgs' flake.nix; then
  test_pass "nixSrc filter names framework/nix/pkgs as excluded host tooling"
else
  test_fail "flake.nix does not visibly exclude framework/nix/pkgs from nixSrc"
fi

test_start "s034.0.7" "source-filter Nix check excludes MeshCmd package files"
if nix build .#checks.x86_64-linux.source-filter --no-link >/dev/null 2>&1; then
  test_pass "source-filter check passed, including MeshCmd package exclusion"
else
  test_fail "nix build .#checks.x86_64-linux.source-filter failed"
fi

test_start "s034.0.8" "check-source-filter.sh still passes"
if framework/scripts/check-source-filter.sh >/dev/null 2>&1; then
  test_pass "framework/scripts/check-source-filter.sh passed"
else
  test_fail "framework/scripts/check-source-filter.sh failed"
fi

runner_summary
