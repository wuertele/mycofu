#!/usr/bin/env bash
#
# Regression test for issue #434: tailscale.nix must tell
# systemd-networkd-wait-online to ignore tailscale0, AND must NOT weaken
# wait-online's "all interfaces required" semantic globally.
#
# Background: upstream NixOS services.tailscale creates a .network file for
# tailscale0 with Unmanaged=true but does NOT add RequiredForOnline=no, so
# networkd treats tailscale0 as "pending" forever. wait-online's default
# all-interfaces-must-be-configured criterion times out, producing a
# switch-to-configuration exit 4 false positive on every closure switch.
#
# This test asserts two complementary properties:
#   1. The fix IS in place: ignoredInterfaces contains "tailscale0".
#   2. The fix did NOT take the easy-but-wrong route of setting
#      anyInterface=true (which would weaken the semantic for every
#      managed interface, not just tailscale0).
#
# The second assertion is the principle guard: a future "simplification" to
# anyInterface=true would silently lose the gate signal for real managed
# interfaces. This test makes that regression visible.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

MODULE="${REPO_ROOT}/framework/nix/modules/tailscale.nix"

if [[ ! -f "${MODULE}" ]]; then
  echo "ERROR: ${MODULE} not found"
  exit 1
fi

test_start "1" "wait-online.ignoredInterfaces declares tailscale interface"

# Locate the assignment line, anchored to a non-comment start so a commented-
# out line doesn't false-pass. Tolerate multi-line list literals (find the
# closing bracket and check the span). Accept either the literal string
# "tailscale0" OR the upstream-tracked config.services.tailscale.interfaceName.
ASSIGN_LINE=$(grep -nE '^[[:space:]]*systemd\.network\.wait-online\.ignoredInterfaces[[:space:]]*=' "${MODULE}" | head -1 | cut -d: -f1)
if [[ -z "${ASSIGN_LINE}" ]]; then
  test_fail "framework/nix/modules/tailscale.nix must set systemd.network.wait-online.ignoredInterfaces (issue #434)"
else
  # Find the line of the closing ']' from the assignment line forward.
  CLOSE_LINE=$(awk -v start="${ASSIGN_LINE}" 'NR>=start && /\]/ {print NR; exit}' "${MODULE}")
  if [[ -z "${CLOSE_LINE}" ]]; then
    test_fail "could not find closing ']' of ignoredInterfaces list"
  else
    SPAN=$(sed -n "${ASSIGN_LINE},${CLOSE_LINE}p" "${MODULE}")
    if printf '%s\n' "${SPAN}" | grep -qE '"tailscale0"|config\.services\.tailscale\.interfaceName'; then
      test_pass "ignoredInterfaces declares tailscale interface (literal or config-tracked)"
    else
      test_fail "ignoredInterfaces list does not contain \"tailscale0\" or config.services.tailscale.interfaceName (issue #434)"
    fi
  fi
fi

test_start "2" "wait-online.anyInterface is NOT set to true (preserves all-interfaces semantic)"

# Match every form that would weaken the semantic. Anchored to non-comment
# start. Catches direct assignment, mkDefault/mkForce wrappers, and the
# `with lib;` short form. Permits `anyInterface = false` (and aliases).
if grep -nE '^[[:space:]]*([a-zA-Z._]*\.)?anyInterface[[:space:]]*=[[:space:]]*((lib\.)?mk(Default|Force|Override[[:space:]]+[0-9]+)[[:space:]]+)?true' "${MODULE}" >/dev/null; then
  test_fail "tailscale.nix sets anyInterface=true (or via mkDefault/mkForce) — weakens wait-online for ALL interfaces. Use ignoredInterfaces=[config.services.tailscale.interfaceName] instead (issue #434)."
else
  test_pass "anyInterface is not weakened (all-interfaces semantic preserved)"
fi

test_start "3" "rationale comment present (so future readers see why this is set)"

# Soft check: ensure the option line is accompanied by some explanation,
# not just dropped in cold. Look for a #-prefixed comment within 25 lines
# above the ignoredInterfaces line that mentions one of: 434, wait-online,
# pending, Unmanaged.
LINE=$(grep -nE 'systemd\.network\.wait-online\.ignoredInterfaces' "${MODULE}" | head -1 | cut -d: -f1)
if [[ -n "${LINE}" ]]; then
  START=$(( LINE > 25 ? LINE - 25 : 1 ))
  if sed -n "${START},${LINE}p" "${MODULE}" | grep -qE '#.*(434|wait-online|pending|Unmanaged)'; then
    test_pass "explanatory comment present near the option"
  else
    test_fail "no nearby comment explaining why ignoredInterfaces is set — add context referencing issue #434 or wait-online behavior"
  fi
else
  test_fail "could not locate the ignoredInterfaces line for context check"
fi

runner_summary
