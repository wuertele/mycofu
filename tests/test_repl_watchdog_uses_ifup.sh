#!/usr/bin/env bash
# Hermetic regression test for repl-watchdog.sh (issue #334).
#
# Background: on 2026-05-04, pve02's reboot triggered repl-watchdog's
# fence-and-recover cycle. The recovery step used `ip link set <iface>
# up` rather than `ifup <iface>`. `ip link set` does not invoke
# ifupdown2's post-up hooks, so the static mesh routes (metric-100
# direct + metric-200 fallback via that interface) installed by the
# post-up hooks in /etc/network/interfaces stayed gone after the
# interface came back up. The cluster ran in a silent broken state
# for five days. Full retrospective:
# docs/reports/2026-05-09-mesh-route-loss-after-peer-reboot-retrospective.md
#
# This test drives the script through every state transition and
# asserts: (a) the script invokes ifup/ifdown at every fence/recover
# call site, and (b) the script makes ZERO `ip link set` calls in
# any path. If a future change reintroduces `ip link set`, this test
# fails.
#
# COVERAGE LIMITATION (per review consensus, 2026-05-14):
#
# This is a hermetic test. The ifup/ifdown shims log their invocations
# but do not execute the real ifupdown2 post-up hooks. Consequently,
# this test does NOT verify that:
#
#   1. ifupdown2 actually runs the post-up hooks on `ifup` (could be a
#      no-op if /run/network/ifstate is out of sync — see T-config for
#      the static check that defends against this hidden-state class).
#   2. The post-up hooks themselves contain valid `ip route replace`
#      commands. T-config asserts the configure-node-network.sh source
#      still generates both metric-100 and metric-200 route lines, but
#      cannot verify the generator runs correctly.
#   3. The real kernel routing table converges after fence/recover.
#
# The metric-200 fallback invariant the issue body called out
# ("an implementation that only restores direct routes would pass")
# is closed structurally only by T-config below — a source-level
# ratchet on configure-node-network.sh. End-to-end route convergence
# coverage requires the SPRINT-036 (FRR) hermetic netns harness, or
# operator HIL validation after deploy. See retrospective §6 Option A
# Cons and §9 follow-up item 5.
#
# Strategy: per-command shims on PATH for ifup, ifdown, ip, ping,
# sleep, cat (to fake /sys/class/net carrier reads), logger. Each
# shim logs invocations to a per-scenario log file. Each test case
# resets state and asserts on the logged call set.
#
# The script under test is run with REPL_WATCHDOG_CONF_FILE and
# REPL_WATCHDOG_STATE_DIR env overrides (no source rewriting), so any
# refactor of those constants in the script doesn't silently neuter
# the test.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/repl-watchdog.sh"
CONFIGURE_NETWORK="${REPO_ROOT}/framework/scripts/configure-node-network.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "$SHIM_DIR"

# State-passing files. Each shim reads these to decide behavior.
SHIM_STATE="${TMP_DIR}/shim-state"
INVOCATIONS_LOG="${TMP_DIR}/invocations.log"

# ---- shim: ifup ----
cat > "${SHIM_DIR}/ifup" <<'SHIM'
#!/usr/bin/env bash
echo "ifup $*" >> "${INVOCATIONS_LOG}"
exit 0
SHIM

# ---- shim: ifdown ----
cat > "${SHIM_DIR}/ifdown" <<'SHIM'
#!/usr/bin/env bash
echo "ifdown $*" >> "${INVOCATIONS_LOG}"
exit 0
SHIM

# ---- shim: ip ----
# Must handle `ip -br link show <iface>` (returns "<iface> <state>")
# and flag any `ip link set` as a regression marker.
cat > "${SHIM_DIR}/ip" <<'SHIM'
#!/usr/bin/env bash
echo "ip $*" >> "${INVOCATIONS_LOG}"
if [[ "$*" == *"link set"* ]]; then
  echo "REGRESSION: ip link set called" >> "${INVOCATIONS_LOG}"
fi
if [[ "$1" == "-br" && "$2" == "link" && "$3" == "show" ]]; then
  iface="$4"
  if [[ -f "${SHIM_STATE}" ]]; then
    # shellcheck disable=SC1090
    source "${SHIM_STATE}"
  fi
  state="${IFACE_STATE:-UP}"
  echo "${iface}             ${state}"
fi
exit 0
SHIM

# ---- shim: ping ----
# Reads PING_RESULT from state file (0 = reachable, 1 = unreachable).
cat > "${SHIM_DIR}/ping" <<'SHIM'
#!/usr/bin/env bash
echo "ping $*" >> "${INVOCATIONS_LOG}"
if [[ -f "${SHIM_STATE}" ]]; then
  # shellcheck disable=SC1090
  source "${SHIM_STATE}"
fi
exit "${PING_RESULT:-0}"
SHIM

# ---- shim: sleep (no-op, keeps tests fast) ----
cat > "${SHIM_DIR}/sleep" <<'SHIM'
#!/usr/bin/env bash
exit 0
SHIM

# ---- shim: cat ----
# Intercepts only /sys/class/net/<iface>/carrier reads; everything else
# falls through to the real cat. Falls through via env after stripping
# the shim dir from PATH (to avoid recursion) so it works on any
# substrate (macOS, Debian, NixOS) without hardcoding /bin/cat.
cat > "${SHIM_DIR}/cat" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" =~ ^/sys/class/net/(.+)/carrier\$ ]]; then
  if [[ -f "\${SHIM_STATE}" ]]; then
    # shellcheck disable=SC1090
    source "\${SHIM_STATE}"
  fi
  echo "\${CARRIER:-1}"
  exit 0
fi
PATH="\${PATH#${SHIM_DIR}:}" exec env cat "\$@"
SHIM

# ---- shim: logger (quiet no-op) ----
cat > "${SHIM_DIR}/logger" <<'SHIM'
#!/usr/bin/env bash
# Drain stdin (the script pipes ifup/ifdown stderr through us). Without
# this, the pipe would block if the script's writer side fills before
# the reader exits.
if [[ ! -t 0 ]]; then
  cat >/dev/null
fi
exit 0
SHIM

chmod +x "${SHIM_DIR}"/*

# Faux config file for the script.
CONF_FILE="${TMP_DIR}/repl-watchdog.conf"
cat > "${CONF_FILE}" <<'EOF'
PEER_pve02_IP=10.10.1.2
PEER_pve02_IFACE=nic3
EOF

STATE_DIR="${TMP_DIR}/state"

# ---- helpers ----

reset_run() {
  : > "${INVOCATIONS_LOG}"
  rm -rf "${STATE_DIR}"
  mkdir -p "${STATE_DIR}"
  : > "${SHIM_STATE}"
}

set_shim_state() {
  : > "${SHIM_STATE}"
  for kv in "$@"; do
    echo "${kv}" >> "${SHIM_STATE}"
  done
}

run_script() {
  # Use env overrides supported by the production script directly — no
  # sed rewrite. If the script removes either override, the test will
  # fail noisily (the script will use real /etc/repl-watchdog.conf and
  # the test's invocations log will not reflect the expected scenario).
  #
  # PATH preserves the inherited PATH so bash, cat, env, etc. remain
  # findable on substrates where /bin and /usr/bin are not the canonical
  # location (NixOS uses /run/current-system/sw/bin and /nix/store/...).
  # The shim directory is prepended so shim binaries take precedence.
  INVOCATIONS_LOG="${INVOCATIONS_LOG}" \
  SHIM_STATE="${SHIM_STATE}" \
  REPL_WATCHDOG_CONF_FILE="${CONF_FILE}" \
  REPL_WATCHDOG_STATE_DIR="${STATE_DIR}" \
    PATH="${SHIM_DIR}:${PATH}" \
    bash "${SCRIPT}"
}

assert_no_ip_link_set() {
  local detail="$1"
  if grep -q "^REGRESSION: ip link set called" "${INVOCATIONS_LOG}" 2>/dev/null; then
    test_fail "${detail}: ip link set was called (regression to pre-#334 behavior)"
    echo "    --- invocations ---" >&2
    cat "${INVOCATIONS_LOG}" >&2
    echo "    --- end ---" >&2
    return 1
  fi
  test_pass "${detail}: no ip link set calls"
}

assert_invocation_count() {
  local cmd="$1" expected="$2" detail="$3"
  local actual
  actual=$(grep -c "^${cmd} " "${INVOCATIONS_LOG}" 2>/dev/null || true)
  actual=${actual:-0}
  if [[ "${actual}" -eq "${expected}" ]]; then
    test_pass "${detail}: ${cmd} called ${expected} time(s)"
  else
    test_fail "${detail}: expected ${cmd} ${expected} time(s), got ${actual}"
    echo "    --- invocations ---" >&2
    cat "${INVOCATIONS_LOG}" >&2
    echo "    --- end ---" >&2
    return 1
  fi
}

assert_file_content() {
  local file="$1" expected="$2" detail="$3"
  if [[ ! -f "${file}" ]]; then
    test_fail "${detail}: expected file ${file} to exist"
    return 1
  fi
  local actual
  actual=$(cat "${file}")
  if [[ "${actual}" == "${expected}" ]]; then
    test_pass "${detail}: ${file##*/} == ${expected}"
  else
    test_fail "${detail}: expected ${file##*/} == ${expected}, got '${actual}'"
    return 1
  fi
}

# ---- T1: normal monitoring, peer reachable, no fence ----
test_start "T1" "normal monitoring (UP + ping ok) — no fence, no recovery"
reset_run
set_shim_state 'IFACE_STATE=UP' 'CARRIER=1' 'PING_RESULT=0'
run_script
assert_no_ip_link_set "T1"
assert_invocation_count "ifup" 0 "T1"
assert_invocation_count "ifdown" 0 "T1"

# ---- T2: fence on no-carrier (threshold reached) + counter reset ----
test_start "T2" "fence on no-carrier: 3 cycles, then ifdown fires + counter resets to 0"
reset_run
echo "2" > "${STATE_DIR}/pve02.failures"
set_shim_state 'IFACE_STATE=DOWN' 'CARRIER=0'
run_script
assert_no_ip_link_set "T2"
assert_invocation_count "ifdown" 1 "T2"
assert_invocation_count "ifup" 0 "T2"
if [[ -f "${STATE_DIR}/pve02.down" ]]; then
  test_pass "T2: down_file marker created"
else
  test_fail "T2: down_file marker missing"
fi
assert_file_content "${STATE_DIR}/pve02.failures" "0" "T2 counter reset"

# ---- T3: fence on ping-fail (threshold reached) + counter reset ----
test_start "T3" "fence on ping-fail: UP + ping fails, threshold trips, ifdown fires + counter resets"
reset_run
echo "2" > "${STATE_DIR}/pve02.failures"
set_shim_state 'IFACE_STATE=UP' 'CARRIER=1' 'PING_RESULT=1'
run_script
assert_no_ip_link_set "T3"
assert_invocation_count "ifdown" 1 "T3"
assert_invocation_count "ifup" 0 "T3"
assert_file_content "${STATE_DIR}/pve02.failures" "0" "T3 counter reset"

# ---- T4: recovery, peer reachable: ifup, no ifdown after ----
test_start "T4" "recovery, peer reachable: ifup runs, down_file removed"
reset_run
touch "${STATE_DIR}/pve02.down"
echo "0" > "${STATE_DIR}/pve02.last_recovery"
set_shim_state 'PING_RESULT=0'
run_script
assert_no_ip_link_set "T4"
assert_invocation_count "ifup" 1 "T4"
assert_invocation_count "ifdown" 0 "T4"
if [[ ! -f "${STATE_DIR}/pve02.down" ]]; then
  test_pass "T4: down_file marker removed after successful recovery"
else
  test_fail "T4: down_file marker should have been removed"
fi

# ---- T5: recovery, peer still unreachable: ifup then ifdown ----
test_start "T5" "recovery, peer unreachable: ifup runs, then ifdown brings iface back down"
reset_run
touch "${STATE_DIR}/pve02.down"
echo "0" > "${STATE_DIR}/pve02.last_recovery"
set_shim_state 'PING_RESULT=1'
run_script
assert_no_ip_link_set "T5"
assert_invocation_count "ifup" 1 "T5"
assert_invocation_count "ifdown" 1 "T5"
if [[ -f "${STATE_DIR}/pve02.down" ]]; then
  test_pass "T5: down_file marker still present (peer didn't recover)"
else
  test_fail "T5: down_file marker should remain when peer still unreachable"
fi

# ---- T6: anti-regression source-level check ----
test_start "T6" "source code: zero remaining 'ip link set' calls in repl-watchdog.sh"
# Strip comments first so the explanatory text in the new header
# doesn't trip a false positive.
ip_link_set_lines=$(grep -nE 'ip[[:space:]]+link[[:space:]]+set' "${SCRIPT}" \
  | grep -vE '^[0-9]+:[[:space:]]*#' || true)
if [[ -n "${ip_link_set_lines}" ]]; then
  test_fail "T6: repl-watchdog.sh still contains executable 'ip link set' (regression)"
  echo "${ip_link_set_lines}" >&2
else
  test_pass "T6: no executable 'ip link set' lines in repl-watchdog.sh"
fi

# ---- T7: peer-reboot scenario end-to-end (May 4 incident class) ----
# Uses a single STATE_DIR across phases so phase 4 (recovery) consumes
# the exact state phase 3 (fence) wrote. Catches a future regression
# where the fence path writes different state than the recovery path
# reads.
test_start "T7" "May 4 incident class: peer-reboot fence/recover cycle uses ifup/ifdown only, state continuous"
reset_run

# Phase 1: peer becomes unreachable (cycle 1 of 3)
set_shim_state 'IFACE_STATE=UP' 'CARRIER=1' 'PING_RESULT=1'
run_script
# Phase 2: peer still unreachable (cycle 2 of 3) — invocations log
# is intentionally NOT reset; we want to see the full cycle.
run_script
# Phase 3: threshold tripped this cycle → ifdown
run_script
assert_no_ip_link_set "T7-fence"
assert_invocation_count "ifdown" 1 "T7-fence"
if [[ ! -f "${STATE_DIR}/pve02.down" ]]; then
  test_fail "T7-fence: down_file should exist after threshold tripped"
fi

# Phase 4: peer comes back. State is the EXACT down_file written in
# phase 3. We only clear the invocation log and update shim state.
: > "${INVOCATIONS_LOG}"
# last_recovery is not set by the fence path, so the recovery branch
# fires immediately on the next tick (this is current production
# behavior — see PE.1 in the claude review for a separate concern).
set_shim_state 'PING_RESULT=0'
run_script
assert_no_ip_link_set "T7-recover"
assert_invocation_count "ifup" 1 "T7-recover"
assert_invocation_count "ifdown" 0 "T7-recover"

if [[ ! -f "${STATE_DIR}/pve02.down" ]]; then
  test_pass "T7: cycle completed, down_file cleared, ifup was used (May 4 bug class structurally absent)"
else
  test_fail "T7: cycle did not clear down_file marker"
fi

# ---- T8: RECOVERY_INTERVAL gate (recent attempt skips recovery) ----
test_start "T8" "RECOVERY_INTERVAL gate: recent attempt skips this tick, no ifup call"
reset_run
touch "${STATE_DIR}/pve02.down"
# last_recovery just now → elapsed << 60s → recovery should be skipped.
date +%s > "${STATE_DIR}/pve02.last_recovery"
set_shim_state 'PING_RESULT=0'
run_script
assert_invocation_count "ifup" 0 "T8 (gate skips recovery)"
assert_invocation_count "ifdown" 0 "T8 (gate skips recovery)"

# ---- T-config: source-level guard on metric-200 fallback hook ----
# The hermetic test cannot verify ifupdown2 actually executes post-up
# hooks (see COVERAGE LIMITATION above). The defense against
# "configure-node-network.sh stops emitting metric-200 fallback route
# hooks" is a source-level ratchet: assert the generator still emits
# both metric-100 and metric-200 'ip route replace' lines.
#
# The metric-200 route is the fallback that transits the third node.
# Losing it was the silent half of the May 4 incident — corosync only
# validates the primary path, so the absence of metric-200 routes
# does not surface in cluster diagnostics until something else breaks
# the primary path. See retrospective §5 assumption (E) and §8 for
# the four-routes-not-two finding.
test_start "T-config" "configure-node-network.sh still generates metric-100 AND metric-200 mesh route hooks"
if grep -qE 'ip route replace[^|]*metric 100' "${CONFIGURE_NETWORK}"; then
  test_pass "T-config: metric-100 post-up route hook present in generator"
else
  test_fail "T-config: configure-node-network.sh no longer emits 'metric 100' route hooks"
fi
if grep -qE 'ip route replace[^|]*metric 200' "${CONFIGURE_NETWORK}"; then
  test_pass "T-config: metric-200 fallback post-up route hook present in generator"
else
  test_fail "T-config: configure-node-network.sh no longer emits 'metric 200' route hooks (May 4 hidden-half regression)"
fi

# Per peer-pair, both metrics must coexist for the dual-route
# invariant to hold. Count occurrences and assert metric-200 count
# matches metric-100 count (the existing topology has 4 of each in
# the generator: physical iface + dummy0, for two peers).
metric_100_count=$(grep -cE 'ip route replace[^|]*metric 100' "${CONFIGURE_NETWORK}" || true)
metric_200_count=$(grep -cE 'ip route replace[^|]*metric 200' "${CONFIGURE_NETWORK}" || true)
if [[ "${metric_100_count}" -eq "${metric_200_count}" && "${metric_100_count}" -gt 0 ]]; then
  test_pass "T-config: metric-100 and metric-200 counts match (${metric_100_count} each)"
else
  test_fail "T-config: count mismatch — metric 100=${metric_100_count}, metric 200=${metric_200_count}"
fi

runner_summary
