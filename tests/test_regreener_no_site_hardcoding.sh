#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

test_start "s034.6.3" "framework contains no regreener site literals"
set +e
MATCHES="$(
  cd "$REPO_ROOT" && \
    grep -RnE --include='*.sh' --include='*.exp' --include='*.nix' --include='*.yaml' --include='*.tmpl' \
      'bfnet|wuertele|172\.17\.77|bpve|apc-pdu|pdu_password' \
      framework/scripts framework/nix framework/templates
)"
RC=$?
set -e

if [[ "$RC" -eq 1 ]]; then
  test_pass "no HIL site or PDU literals under framework"
elif [[ "$RC" -eq 0 ]]; then
  test_fail "site-specific literals found under framework"
  printf '%s\n' "$MATCHES" >&2
else
  test_fail "grep failed while scanning framework (rc=${RC})"
fi

runner_summary
