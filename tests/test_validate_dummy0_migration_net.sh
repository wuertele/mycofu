#!/usr/bin/env bash
# test_validate_dummy0_migration_net.sh — #697 P3 ratchet.
#
# validate.sh gains R2.7: a per-node, fail-closed check that dummy0
# carries the expected 10.10.0.x/32 (the corosync ring-0 / Proxmox
# migration-network address). Derived from site/config.yaml, never
# hardcoded. Regression risk: a future edit could downgrade the FAIL
# to a WARN/SKIP or drop the check entirely.
#
# The check is intentionally independent of the R2.6 health-endpoint
# gate: R2.6 gates on `.healthy` from repl-health.sh; R2.7 hits
# `ip addr show dummy0` directly so a broken health server cannot mask
# a missing migration address (#697 root cause on pve02).
#
# Coverage:
#   1. R2.7 check exists in the validate.sh source.
#   2. Expected /32 is derived from .nodes[i].repl_ip (no hardcode).
#   3. On absence or unreadable state, the check FAILs (never SKIPs).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

VALIDATE="${REPO_ROOT}/framework/scripts/validate.sh"

test_start "r27.a" "R2.7 migration-net address check exists"
if grep -Fq 'R2.7' "$VALIDATE" && grep -Fq 'dummy0 carries' "$VALIDATE"; then
  test_pass "R2.7 header + description present"
else
  test_fail "R2.7 dummy0 migration-net check missing from validate.sh"
fi

test_start "r27.b" "expected /32 derived from config.yaml (.nodes[].repl_ip)"
# Ratchet: the check must derive the expected IP from
# .nodes[i].repl_ip. A raw 10.10.0.x/32 literal in the check body would
# be a hardcode regression (violates config-yaml single-source rule).
r27_block=$(awk '/# R2\.7 /,/^  # =====================================================================/' "$VALIDATE")
# Executable lines only (drop comments) — a comment mentioning the
# 10.10.0.0/24 subnet family is not a hardcode; a value used at runtime is.
r27_exec=$(printf '%s\n' "$r27_block" | grep -vE '^\s*#')
if [[ -z "$r27_block" ]]; then
  test_fail "could not extract R2.7 block from validate.sh"
elif ! grep -Fq '.nodes[${i}].repl_ip' <<< "$r27_block"; then
  test_fail "R2.7 does not derive expected /32 from .nodes[].repl_ip"
elif grep -qE '10\.10\.0\.[0-9]+' <<< "$r27_exec"; then
  test_fail "R2.7 has a hardcoded 10.10.0.x literal on an executable line"
else
  test_pass "R2.7 derives expected /32 from .nodes[].repl_ip; no runtime hardcode"
fi

test_start "r27.c2" "R2.7 skips nodes with no repl_ip (non-mesh) via early continue"
# A single-node or non-mesh deployment lacks .nodes[i].repl_ip; the check
# must skip cleanly rather than false-fail. The gate is the `continue`
# guarded by [[ -z "$NODE_REPL_IP" || "$NODE_REPL_IP" == "null" ]].
if grep -Fq '[[ -z "$NODE_REPL_IP" || "$NODE_REPL_IP" == "null" ]]' <<< "$r27_block" && \
   grep -A1 -F '[[ -z "$NODE_REPL_IP"' <<< "$r27_block" | grep -Fq continue; then
  test_pass "R2.7 skips nodes without repl_ip"
else
  test_fail "R2.7 lacks null-repl_ip skip guard — will false-fail on non-mesh nodes"
fi

test_start "r27.c1" "R2.7 has three exit 1 branches (ssh err, empty addr, mismatch — sub-claude P3-3)"
# A mutation that swapped `exit 1` for `exit 0` on any branch would still
# pass the fail-closed check below because that only greps for absence of
# check_skip. Ratchet the exit-1 count so a covert downgrade is caught.
exit1_count=$(grep -c 'exit 1' <<< "$r27_block" || echo 0)
if [[ "${exit1_count:-0}" -ge 3 ]]; then
  test_pass "R2.7 has ${exit1_count} exit 1 branches"
else
  test_fail "R2.7 only has ${exit1_count:-0} exit 1 branches — expected at least 3"
fi

test_start "r27.c" "R2.7 fails closed on unreadable state (never SKIP)"
# Ratchet: the check body must not use test_skip / continue-on-error
# semantics that would swallow SSH failures. It uses `check` (which
# fails on nonzero exit), and its inner shell explicitly exits 1
# when ssh fails, when ADDR is empty, or when ADDR differs from the
# expected /32. A future edit that switched to `check_skip` or `|| true`
# would be a fail-closed regression.
if grep -Fq 'check_skip "R2.7' "$VALIDATE"; then
  test_fail "R2.7 uses check_skip — fail-closed rule violated"
elif ! grep -Fq 'ssh to' <<< "$r27_block" || ! grep -Fq 'cannot verify dummy0' <<< "$r27_block"; then
  test_fail "R2.7 lacks explicit ssh-failure FAIL branch"
else
  test_pass "R2.7 fails closed on ssh failure, empty addr, and mismatched addr"
fi

runner_summary
