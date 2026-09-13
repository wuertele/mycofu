#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

DOC="${REPO_ROOT}/tests/hil/bfnet/REGREENING.md"
TODO="${REPO_ROOT}/docs/reports/sprint-037-post-execute-verification-todo.md"

require_text() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -Fq "$pattern" "$file"; then
    test_pass "$label"
  else
    test_fail "$label missing pattern: $pattern"
  fi
}

test_start "s037.21.1" "runbook covers invocation surfaces"
require_text "$DOC" "framework/scripts/regreen-cluster.sh --config tests/hil/bfnet/config.yaml bpve02" "workstation single-node invocation documented"
require_text "$DOC" "framework/scripts/regreen-cluster.sh --config tests/hil/bfnet/config.yaml all" "workstation all-node invocation documented"
require_text "$DOC" "Run pipeline" "GitLab web trigger documented"
require_text "$DOC" "REGREEN_NODE=bpve02" "single-node GitLab variable documented"

test_start "s037.21.2" "runbook covers fail-fast and partial recovery"
require_text "$DOC" "stops on the first failure" "fail-fast semantics documented"
require_text "$DOC" "not-attempted" "not-attempted status documented"
require_text "$DOC" "Partial-Regreen Recovery" "partial recovery section present"
require_text "$DOC" "jq -r '.nodes" "status JSON triage command documented"

test_start "s037.21.3" "runbook covers recovery and update operations"
require_text "$DOC" "pdu-cycle.sh --config tests/hil/bfnet/config.yaml bpve02" "PDU fallback documented"
require_text "$DOC" "bpve05 the configured outlet is 18" "non-formula PDU mapping documented"
require_text "$DOC" "PVE Pin Update" "PVE pin update procedure documented"
require_text "$DOC" "nix-prefetch-url" "PVE hash workflow documented"
require_text "$DOC" "nix build --impure .#packages.x86_64-linux.hil-boot-image" "direct hil-boot image build impure flag documented"
require_text "$DOC" "In-flight conflicts" "in-flight conflict guidance documented"

test_start "s037.21.4" "runbook covers hil-boot persistence and security posture"
require_text "$DOC" "no vdb" "hil-boot no-vdb fact documented"
require_text "$DOC" "no SOPS age key" "no SOPS-on-hil-boot fact documented"
require_text "$DOC" "/nix/store" "store cleartext posture documented"
require_text "$DOC" "relaxed security posture" "security posture note documented"

test_start "s037.21.5" "post-execute TODO covers manual hardware checks"
require_text "$TODO" "M1" "manual DHCP check listed"
require_text "$TODO" "M8" "manual PVE update rehearsal listed"
require_text "$TODO" "M-USB" "USB unattended install non-regression listed"
require_text "$TODO" "DRT-001 and DRT-002 require rerun" "DR invalidation summary listed"

runner_summary
