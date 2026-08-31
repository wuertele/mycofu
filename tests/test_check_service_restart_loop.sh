#!/usr/bin/env bash
# test_check_service_restart_loop.sh — hermetic test for #391's helper.
# No SSH, no cluster access required.
#
# Tier 1 (outer-helper logic): mocks ssh via SSH_CMD env var with a
# mock-ssh.sh that FAILS on empty stdin — this structurally catches the
# `-n` regression (per #391 round-1 review P1.1).
#
# Tier 2 (REMOTE_PROBE shell logic): exec the probe body directly against
# stubbed systemctl/journalctl binaries on PATH. This catches probe-side
# regressions the SSH mock cannot see (per #391 round-1 review P2.1).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
HELPER="${REPO_ROOT}/framework/scripts/check-service-restart-loop.sh"
PROBE="${REPO_ROOT}/framework/scripts/lib/restart-loop-probe.sh"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d -t check-srl-test.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ----- fixture: configs -----

cat > "${TMP_DIR}/config.yaml" <<'EOF'
vms:
  testapp_prod:
    vmid: 600
    ip: 172.27.10.54
    mac: "02:f2:be:a6:fd:fc"
    node: pve02
  dns2_prod:
    vmid: 402
    ip: 172.27.10.50
    mac: "02:11:22:33:44:55"
    node: pve02
  pbs:
    vmid: 190
    ip: 172.17.77.60
    mac: "02:11:22:33:44:99"
    node: pve03
  hil_boot:
    vmid: 170
    ip: 172.17.77.63
    mac: "02:33:44:55:66:77"
    node: pve02
EOF

cat > "${TMP_DIR}/applications.yaml" <<'EOF'
applications:
  influxdb:
    enabled: true
    environments:
      prod:
        ip: 172.27.10.55
      dev:
        ip: 172.27.60.55
  grafana:
    enabled: false
    environments:
      prod:
        ip: 172.27.10.56
EOF

# ----- fixture: mock SSH -----
# Reads stdin and FAILS LOUDLY if it is empty (structural P1.1 regression
# catch — if helper inadvertently uses ssh -n again, REMOTE_PROBE would
# arrive as empty stdin and this mock would fail).
#
# Parses argv for "root@<ip>", concatenates the canned stdout from
# ${TMP_DIR}/responses/<ip>.stdout (PROBE_OK appended automatically
# when .exit is 0), exits with code from ${TMP_DIR}/responses/<ip>.exit.
cat > "${TMP_DIR}/mock-ssh.sh" <<'MOCK'
#!/usr/bin/env bash
# Mock SSH. Argv: [opts...] root@<ip> "<remote command>". Stdin = REMOTE_PROBE.
#
# Emulate the relevant SSH option semantics so the mock catches regression
# classes that a passive shell would miss:
#   -n  → redirects ssh's own stdin from /dev/null (matches OpenSSH).
#         If a caller adds -n, the inner `cat` reads zero bytes — same as
#         the production no-op bug R1 P1.1.
target=""
has_n=0
for arg in "$@"; do
  case "$arg" in
    -n)     has_n=1 ;;
    root@*) target="${arg#root@}" ;;
  esac
done
if [[ "$has_n" == "1" ]]; then
  exec 0</dev/null
fi
stdin_content=$(cat)
if [[ -z "$stdin_content" ]]; then
  echo "MOCK-SSH-ERROR: empty stdin received (did caller use ssh -n?)" >&2
  exit 99
fi
fixture="${TMP_DIR_FOR_MOCK}/responses/${target}"
rc=0
if [[ -f "${fixture}.exit" ]]; then
  rc=$(cat "${fixture}.exit")
fi
if [[ -f "${fixture}.stdout" ]]; then
  cat "${fixture}.stdout"
fi
# Auto-append PROBE_OK on success unless fixture says NO_PROBE_OK
if [[ "$rc" == "0" && ! -f "${fixture}.no-probe-ok" ]]; then
  echo "PROBE_OK"
fi
if [[ -f "${fixture}.stderr" ]]; then
  cat "${fixture}.stderr" >&2
fi
exit "$rc"
MOCK
chmod +x "${TMP_DIR}/mock-ssh.sh"

mkdir -p "${TMP_DIR}/responses"

# ----- helper: set or clear a per-IP canned response -----
set_response() {
  local ip="$1" stdout="$2" rc="${3:-0}"
  printf '%s' "${stdout}" > "${TMP_DIR}/responses/${ip}.stdout"
  printf '%s\n' "${rc}" > "${TMP_DIR}/responses/${ip}.exit"
  rm -f "${TMP_DIR}/responses/${ip}.no-probe-ok" "${TMP_DIR}/responses/${ip}.stderr"
}

set_response_no_sentinel() {
  local ip="$1" stdout="$2"
  set_response "$ip" "$stdout" 0
  touch "${TMP_DIR}/responses/${ip}.no-probe-ok"
}

set_response_stderr() {
  local ip="$1" stderr="$2" rc="${3:-0}"
  printf '' > "${TMP_DIR}/responses/${ip}.stdout"
  printf '%s\n' "${rc}" > "${TMP_DIR}/responses/${ip}.exit"
  printf '%s' "${stderr}" > "${TMP_DIR}/responses/${ip}.stderr"
}

clear_responses() {
  rm -f "${TMP_DIR}/responses"/*
}

# ----- runner -----
run_capture() {
  set +e
  # SSH_OPTS_OVERRIDE="" lets the test mock receive non-empty stdin (mock
  # would fail with rc=99 if -n made it through). Real helper would use
  # SSH_OPTS_DEFAULT in absence of this override.
  OUTPUT="$(TMP_DIR_FOR_MOCK="${TMP_DIR}" \
            SSH_CMD="${TMP_DIR}/mock-ssh.sh" \
            SSH_OPTS_OVERRIDE="" \
            "$@" 2>&1)"
  STATUS=$?
  set -e
}

assert_exit() {
  local expected_status="$1"
  local label="$2"
  if [[ "${STATUS}" -eq "${expected_status}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected exit %s, got %s\n' "${expected_status}" "${STATUS}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_output_contains() {
  local needle="$1"
  local label="$2"
  # `--` guard: needles like "--help|-h" would otherwise be parsed as
  # grep's own --help flag.
  if grep -Fq -- "${needle}" <<< "${OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing output: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_output_not_contains() {
  local needle="$1"
  local label="$2"
  if ! grep -Fq -- "${needle}" <<< "${OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    unexpected match: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

# ----- shared helper-invocation wrapper -----
helper() {
  "${HELPER}" --config "${TMP_DIR}/config.yaml" \
              --apps-config "${TMP_DIR}/applications.yaml" "$@"
}

# =====================================================================
test_start "T1" "All VMs clean (PROBE_OK only) → exit 0"
# =====================================================================
clear_responses
set_response 172.27.10.54 "" 0
set_response 172.27.10.50 "" 0
set_response 172.17.77.63 "" 0
set_response 172.27.10.55 "" 0
set_response 172.27.60.55 "" 0
run_capture helper
assert_exit 0 "exit 0 when all VMs are clean"
assert_output_contains "checked 5 VM(s)" "checked count includes vms+apps minus pbs"
assert_output_contains "skipped 1" "pbs was skipped"
assert_output_contains "0 failed" "zero failures reported"

# =====================================================================
test_start "T2" "testapp-prod unit over NRestarts threshold → exit 1"
# =====================================================================
clear_responses
set_response 172.27.10.54 $'UNIT vault-agent.service NRestarts=1110 Result=oom-kill ActiveState=activating' 0
set_response 172.27.10.50 "" 0
set_response 172.17.77.63 "" 0
set_response 172.27.10.55 "" 0
set_response 172.27.60.55 "" 0
run_capture helper
assert_exit 1 "exit 1 when a unit is over threshold"
assert_output_contains "testapp_prod" "failed VM is named"
assert_output_contains "vault-agent.service NRestarts=1110" "unit detail surfaced"
assert_output_contains "1 failed" "failure count is 1"

# =====================================================================
test_start "T3" "PBS is skipped as vendor appliance — no SSH attempt"
# =====================================================================
clear_responses
set_response 172.27.10.54 "" 0
set_response 172.27.10.50 "" 0
set_response 172.17.77.63 "" 0
set_response 172.27.10.55 "" 0
set_response 172.27.60.55 "" 0
run_capture helper
assert_exit 0 "exit 0 with pbs skipped"
assert_output_contains "SKIP: pbs" "pbs skip line printed"
assert_output_not_contains "172.17.77.60" "no SSH attempt logged against pbs IP"

# =====================================================================
test_start "T4" "SSH failure on one VM → exit 1, others continue"
# =====================================================================
clear_responses
set_response 172.27.10.54 "" 0
set_response 172.27.10.50 "" 255
set_response 172.17.77.63 "" 0
set_response 172.27.10.55 "" 0
set_response 172.27.60.55 "" 0
run_capture helper
assert_exit 1 "exit 1 on SSH failure"
assert_output_contains "dns2_prod" "failing VM is named"
assert_output_contains "SSH/remote probe failed" "SSH error surfaced"

# =====================================================================
test_start "T5" "Kernel OOM total over threshold → exit 1"
# =====================================================================
clear_responses
set_response 172.27.10.54 $'KERNEL kernel_oom_total=15' 0
set_response 172.27.10.50 "" 0
set_response 172.17.77.63 "" 0
set_response 172.27.10.55 "" 0
set_response 172.27.60.55 "" 0
run_capture helper
assert_exit 1 "exit 1 when kernel_oom_total is over threshold"
assert_output_contains "kernel_oom_total=15" "kernel signal surfaced"

# =====================================================================
test_start "T6" "Multiple problematic VMs aggregate into single exit 1"
# =====================================================================
clear_responses
set_response 172.27.10.54 $'UNIT vault-agent.service NRestarts=500 Result=oom-kill ActiveState=activating' 0
set_response 172.27.10.50 $'UNIT pdns.service NRestarts=42 Result=signal ActiveState=failed' 0
set_response 172.17.77.63 "" 0
set_response 172.27.10.55 "" 0
set_response 172.27.60.55 "" 0
run_capture helper
assert_exit 1 "exit 1 when multiple VMs fail"
assert_output_contains "2 failed" "failure count is 2"
assert_output_contains "testapp_prod" "testapp_prod named"
assert_output_contains "dns2_prod" "dns2_prod named"

# =====================================================================
test_start "T7" "Missing PROBE_OK sentinel → fail closed (probe incomplete)"
# =====================================================================
clear_responses
# Helper expects PROBE_OK as last line; without it, probe is treated as
# failed-internally per .claude/rules/destruction-safety.md.
set_response_no_sentinel 172.27.10.54 ""
set_response 172.27.10.50 "" 0
set_response 172.17.77.63 "" 0
set_response 172.27.10.55 "" 0
set_response 172.27.60.55 "" 0
run_capture helper
assert_exit 1 "exit 1 when probe did not complete"
assert_output_contains "no PROBE_OK sentinel" "fail-closed message present"

# =====================================================================
test_start "T8" "Unexpected SSH stderr → fail closed (SSH chatter is not a finding)"
# =====================================================================
clear_responses
# Even with rc=0 and PROBE_OK, stderr noise must be reported as
# probe error, not silently merged with stdout (P1.3 fix).
set_response_stderr 172.27.10.54 "Warning: Permanently added host" 0
echo "PROBE_OK" >> "${TMP_DIR}/responses/172.27.10.54.stdout"
set_response 172.27.10.50 "" 0
set_response 172.17.77.63 "" 0
set_response 172.27.10.55 "" 0
set_response 172.27.60.55 "" 0
run_capture helper
assert_exit 1 "exit 1 on unexpected SSH stderr"
assert_output_contains "unexpected stderr" "unexpected-stderr message"
assert_output_contains "Warning: Permanently added" "actual stderr is shown"

# =====================================================================
test_start "T9" "--help works (sentinel-bounded usage block)"
# =====================================================================
run_capture "${HELPER}" --help
assert_exit 0 "--help exits 0"
assert_output_contains "Detect service crash loops" "help text shown"
assert_output_contains "--help|-h" "help mentions --help"
assert_output_not_contains "END_USAGE" "sentinel marker is not in the printed help"

# =====================================================================
test_start "T10" "Unknown argument → exit 2"
# =====================================================================
run_capture helper --not-a-real-flag
assert_exit 2 "exit 2 on usage error"
assert_output_contains "Unknown argument" "usage error message"

# =====================================================================
test_start "T11" "Missing config file → exit 2"
# =====================================================================
run_capture "${HELPER}" --config "${TMP_DIR}/does-not-exist.yaml"
assert_exit 2 "exit 2 when config missing"
assert_output_contains "Config not found" "config-missing message"

# =====================================================================
test_start "T12" "--nrestarts-max with non-integer → exit 2"
# =====================================================================
run_capture helper --nrestarts-max foo
assert_exit 2 "exit 2 on non-integer threshold"
assert_output_contains "non-negative integer" "validation message present"

# =====================================================================
test_start "T13" "--nrestarts-max with no value → exit 2"
# =====================================================================
run_capture helper --nrestarts-max
assert_exit 2 "exit 2 on missing value"
assert_output_contains "requires a value" "missing-value message"

# =====================================================================
# Tier 2: exercise REMOTE_PROBE shell body directly against stubs.
# These tests catch probe-side regressions the SSH mock cannot see.
# =====================================================================

probe_with_stubs() {
  # Run REMOTE_PROBE body with the supplied PATH (containing stubbed
  # systemctl and journalctl). Returns its stdout, captures exit code.
  local fixture_dir="$1"; shift
  set +e
  PROBE_OUTPUT="$(PATH="${fixture_dir}:${PATH}" NRESTARTS_MAX="${1:-10}" OOM_MAX="${2:-3}" \
    bash "${PROBE}" 2>&1)"
  PROBE_STATUS=$?
  set -e
}

make_probe_fixture() {
  local fixture_dir="$1"
  rm -rf "$fixture_dir"
  mkdir -p "$fixture_dir"
}

# Helper: write a stub binary that echoes content from a per-arg file.
# Use this so each tier-2 test can set up its own canned systemctl /
# journalctl responses without polluting global state.
make_stub_systemctl() {
  local fixture_dir="$1" list_units_out="$2"
  # Stub ASSERTS on the args it expects, so a future regression to
  # --state=active only (R1 P1.2) would fail tests, not silently pass.
  # Same for the show command's expected -p properties.
  cat > "${fixture_dir}/systemctl" <<STUB
#!/usr/bin/env bash
set -u
case "\$1" in
  list-units)
    args="\$*"
    if [[ "\$args" != *"--state=active,activating,failed"* ]]; then
      echo "STUB-ERROR: systemctl list-units called without --state=active,activating,failed (got: \$args)" >&2
      exit 99
    fi
    if [[ "\$args" != *"--type=service"* ]]; then
      echo "STUB-ERROR: systemctl list-units called without --type=service (got: \$args)" >&2
      exit 99
    fi
    if [[ "\$args" != *"--no-legend"* ]]; then
      echo "STUB-ERROR: systemctl list-units called without --no-legend (got: \$args)" >&2
      exit 99
    fi
    cat "${fixture_dir}/list-units.txt" 2>/dev/null
    ;;
  show)
    args="\$*"
    for prop in NRestarts Result ActiveState; do
      if [[ "\$args" != *"-p \${prop}"* ]]; then
        echo "STUB-ERROR: systemctl show missing -p \${prop} (got: \$args)" >&2
        exit 99
      fi
    done
    unit="\${@: -1}"
    if [[ -f "${fixture_dir}/show-\${unit}.txt" ]]; then
      cat "${fixture_dir}/show-\${unit}.txt"
    fi
    ;;
esac
STUB
  chmod +x "${fixture_dir}/systemctl"
  printf '%s' "$list_units_out" > "${fixture_dir}/list-units.txt"
}

make_stub_journalctl() {
  local fixture_dir="$1" oom_count="$2"
  cat > "${fixture_dir}/journalctl" <<STUB
#!/usr/bin/env bash
# Emit OOM_COUNT lines containing "Out of memory: Killed" so grep -c
# returns OOM_COUNT.
for i in \$(seq 1 ${oom_count}); do
  echo "[123.456] Out of memory: Killed process \$i (foo)"
done
STUB
  chmod +x "${fixture_dir}/journalctl"
}

# =====================================================================
test_start "T20" "Tier-2: clean VM → no UNIT/KERNEL lines, PROBE_OK emitted"
# =====================================================================
FIXTURE="${TMP_DIR}/probe-clean"
make_probe_fixture "$FIXTURE"
make_stub_systemctl "$FIXTURE" $'  sshd.service  loaded active running ssh\n  cron.service  loaded active running cron\n'
cat > "${FIXTURE}/show-sshd.service.txt" <<'EOF'
NRestarts=0
Result=success
ActiveState=active
EOF
cat > "${FIXTURE}/show-cron.service.txt" <<'EOF'
NRestarts=2
Result=success
ActiveState=active
EOF
make_stub_journalctl "$FIXTURE" 0
probe_with_stubs "$FIXTURE" 10 3
if [[ "$PROBE_STATUS" -eq 0 ]] && \
   grep -qx "PROBE_OK" <<<"$PROBE_OUTPUT" && \
   ! grep -qE "^(UNIT|KERNEL) " <<<"$PROBE_OUTPUT"; then
  test_pass "clean probe emits PROBE_OK only"
else
  test_fail "clean probe should emit PROBE_OK only"
  printf '    output:\n%s\n' "$PROBE_OUTPUT" >&2
fi

# =====================================================================
test_start "T21" "Tier-2: NRestarts > threshold → UNIT line + PROBE_OK"
# =====================================================================
FIXTURE="${TMP_DIR}/probe-nrestart"
make_probe_fixture "$FIXTURE"
make_stub_systemctl "$FIXTURE" $'  vault-agent.service  loaded active running vault\n'
cat > "${FIXTURE}/show-vault-agent.service.txt" <<'EOF'
NRestarts=1110
Result=oom-kill
ActiveState=activating
EOF
make_stub_journalctl "$FIXTURE" 0
probe_with_stubs "$FIXTURE" 10 3
if grep -qE "^UNIT vault-agent.service NRestarts=1110 Result=oom-kill ActiveState=activating$" <<<"$PROBE_OUTPUT" && \
   grep -qx "PROBE_OK" <<<"$PROBE_OUTPUT"; then
  test_pass "high-NRestarts unit emitted"
else
  test_fail "expected UNIT line + PROBE_OK"
  printf '    output:\n%s\n' "$PROBE_OUTPUT" >&2
fi

# =====================================================================
test_start "T22" "Tier-2: ActiveState=failed → UNIT line even with NRestarts=0"
# =====================================================================
# This is the P1.2 case: StartLimitBurst landed the unit in failed/dead
# with NRestarts reset to 0; the check must still flag.
FIXTURE="${TMP_DIR}/probe-failed"
make_probe_fixture "$FIXTURE"
make_stub_systemctl "$FIXTURE" $'  some-broken.service  loaded failed failed broken\n'
cat > "${FIXTURE}/show-some-broken.service.txt" <<'EOF'
NRestarts=0
Result=exit-code
ActiveState=failed
EOF
make_stub_journalctl "$FIXTURE" 0
probe_with_stubs "$FIXTURE" 10 3
if grep -qE "^UNIT some-broken.service NRestarts=0 Result=exit-code ActiveState=failed$" <<<"$PROBE_OUTPUT" && \
   grep -qx "PROBE_OK" <<<"$PROBE_OUTPUT"; then
  test_pass "failed-state unit emitted regardless of NRestarts"
else
  test_fail "expected UNIT line for failed-state unit"
  printf '    output:\n%s\n' "$PROBE_OUTPUT" >&2
fi

# =====================================================================
test_start "T23" "Tier-2: kernel OOM count >= threshold → KERNEL line + PROBE_OK"
# =====================================================================
FIXTURE="${TMP_DIR}/probe-kernel-oom"
make_probe_fixture "$FIXTURE"
make_stub_systemctl "$FIXTURE" $'  sshd.service  loaded active running ssh\n'
cat > "${FIXTURE}/show-sshd.service.txt" <<'EOF'
NRestarts=0
Result=success
ActiveState=active
EOF
make_stub_journalctl "$FIXTURE" 7
probe_with_stubs "$FIXTURE" 10 3
if grep -qE "^KERNEL kernel_oom_total=7$" <<<"$PROBE_OUTPUT" && \
   grep -qx "PROBE_OK" <<<"$PROBE_OUTPUT"; then
  test_pass "kernel OOM count emitted"
else
  test_fail "expected KERNEL line + PROBE_OK"
  printf '    output:\n%s\n' "$PROBE_OUTPUT" >&2
fi

# =====================================================================
test_start "T24" "Tier-2: threshold override actually flows into probe"
# =====================================================================
# Same NRestarts=15 fixture; with --nrestarts-max=10 it triggers, with
# --nrestarts-max=100 it doesn't. This tests what original T7 only
# pretended to test.
FIXTURE="${TMP_DIR}/probe-threshold"
make_probe_fixture "$FIXTURE"
make_stub_systemctl "$FIXTURE" $'  busy.service  loaded active running busy\n'
cat > "${FIXTURE}/show-busy.service.txt" <<'EOF'
NRestarts=15
Result=success
ActiveState=active
EOF
make_stub_journalctl "$FIXTURE" 0
probe_with_stubs "$FIXTURE" 10 3
if grep -qE "^UNIT busy.service NRestarts=15" <<<"$PROBE_OUTPUT"; then
  test_pass "threshold 10: NRestarts=15 triggers UNIT"
else
  test_fail "expected UNIT with threshold 10"
  printf '    output:\n%s\n' "$PROBE_OUTPUT" >&2
fi
probe_with_stubs "$FIXTURE" 100 3
if ! grep -qE "^UNIT busy.service" <<<"$PROBE_OUTPUT" && \
   grep -qx "PROBE_OK" <<<"$PROBE_OUTPUT"; then
  test_pass "threshold 100: NRestarts=15 does NOT trigger UNIT"
else
  test_fail "expected no UNIT with threshold 100"
  printf '    output:\n%s\n' "$PROBE_OUTPUT" >&2
fi

# =====================================================================
test_start "T25" "Tier-2: grep -c no-match returns 0 (not 1) — fail-closed sanitization"
# =====================================================================
# Stub journalctl that returns NO OOM lines. grep -c will exit 1.
# The probe must treat this as oom_total=0 (sanitization on line ~63
# of restart-loop-probe.sh) and not crash.
FIXTURE="${TMP_DIR}/probe-no-oom"
make_probe_fixture "$FIXTURE"
make_stub_systemctl "$FIXTURE" $'  sshd.service  loaded active running ssh\n'
cat > "${FIXTURE}/show-sshd.service.txt" <<'EOF'
NRestarts=0
Result=success
ActiveState=active
EOF
cat > "${FIXTURE}/journalctl" <<'STUB'
#!/usr/bin/env bash
# No output — no OOM events ever
true
STUB
chmod +x "${FIXTURE}/journalctl"
probe_with_stubs "$FIXTURE" 10 3
if [[ "$PROBE_STATUS" -eq 0 ]] && \
   grep -qx "PROBE_OK" <<<"$PROBE_OUTPUT" && \
   ! grep -qE "^(UNIT|KERNEL) " <<<"$PROBE_OUTPUT"; then
  test_pass "no-OOM journal: clean exit, PROBE_OK, no spurious findings"
else
  test_fail "expected clean PROBE_OK with no findings"
  printf '    status: %s\n    output:\n%s\n' "$PROBE_STATUS" "$PROBE_OUTPUT" >&2
fi

# =====================================================================
test_start "T26" "Tier-2: systemctl list-units fails → NO PROBE_OK (R2 P1.1 regression catch)"
# =====================================================================
# Stub systemctl that exits non-zero. The probe MUST NOT emit PROBE_OK.
# This was the R2-discovered fail-open: list_rc=$? after a pipeline
# captured awk's rc, not systemctl's.
FIXTURE="${TMP_DIR}/probe-systemctl-fail"
make_probe_fixture "$FIXTURE"
cat > "${FIXTURE}/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "Failed to connect to bus: No such file or directory" >&2
exit 1
STUB
chmod +x "${FIXTURE}/systemctl"
make_stub_journalctl "$FIXTURE" 0
probe_with_stubs "$FIXTURE" 10 3
if ! grep -qx "PROBE_OK" <<<"$PROBE_OUTPUT"; then
  test_pass "no PROBE_OK when systemctl fails"
else
  test_fail "PROBE_OK emitted despite systemctl failure (R2 P1.1 regression)"
  printf '    output:\n%s\n' "$PROBE_OUTPUT" >&2
fi

# =====================================================================
test_start "T27" "Tier-2: journalctl fails → NO PROBE_OK (R2 P1.1 regression catch)"
# =====================================================================
# Stub journalctl that exits non-zero. The probe MUST NOT emit PROBE_OK.
# Same class as T26 but for the journalctl path.
FIXTURE="${TMP_DIR}/probe-journalctl-fail"
make_probe_fixture "$FIXTURE"
make_stub_systemctl "$FIXTURE" $'  sshd.service  loaded active running ssh\n'
cat > "${FIXTURE}/show-sshd.service.txt" <<'EOF'
NRestarts=0
Result=success
ActiveState=active
EOF
cat > "${FIXTURE}/journalctl" <<'STUB'
#!/usr/bin/env bash
echo "No journal files were opened due to insufficient permissions." >&2
exit 1
STUB
chmod +x "${FIXTURE}/journalctl"
probe_with_stubs "$FIXTURE" 10 3
if ! grep -qx "PROBE_OK" <<<"$PROBE_OUTPUT"; then
  test_pass "no PROBE_OK when journalctl fails"
else
  test_fail "PROBE_OK emitted despite journalctl failure (R2 P1.1 regression)"
  printf '    output:\n%s\n' "$PROBE_OUTPUT" >&2
fi

# =====================================================================
test_start "T28" "Tier-2: systemctl show fails mid-loop → NO PROBE_OK"
# =====================================================================
# Models DBus going away after list-units succeeded but before all
# show calls complete (race condition under cluster stress).
FIXTURE="${TMP_DIR}/probe-show-fail"
make_probe_fixture "$FIXTURE"
make_stub_systemctl "$FIXTURE" $'  sshd.service  loaded active running ssh\n'
# Override systemctl to fail on `show` while succeeding on `list-units`:
cat > "${FIXTURE}/systemctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-units)
    echo "  sshd.service  loaded active running ssh"
    ;;
  show)
    echo "Failed to connect to bus" >&2
    exit 1
    ;;
esac
STUB
chmod +x "${FIXTURE}/systemctl"
make_stub_journalctl "$FIXTURE" 0
probe_with_stubs "$FIXTURE" 10 3
if ! grep -qx "PROBE_OK" <<<"$PROBE_OUTPUT"; then
  test_pass "no PROBE_OK when systemctl show fails mid-loop"
else
  test_fail "PROBE_OK emitted despite systemctl show failure"
  printf '    output:\n%s\n' "$PROBE_OUTPUT" >&2
fi

# =====================================================================
test_start "T29" "Static -n guard: helper exits 2 if SSH_OPTS contains -n"
# =====================================================================
# The mock-ssh.sh now honors -n (exec 0</dev/null), but defense-in-depth:
# the helper itself refuses to run if SSH_OPTS has -n. Catches a future
# operator who adds -n to SSH_OPTS_DEFAULT, or who exports an override
# with -n.
set +e
GUARD_OUT="$(SSH_OPTS_OVERRIDE="-n -o ConnectTimeout=5" \
             SSH_CMD="${TMP_DIR}/mock-ssh.sh" \
             TMP_DIR_FOR_MOCK="${TMP_DIR}" \
             "${HELPER}" --config "${TMP_DIR}/config.yaml" \
                         --apps-config "${TMP_DIR}/applications.yaml" 2>&1)"
GUARD_STATUS=$?
set -e
if [[ "$GUARD_STATUS" -eq 2 ]] && grep -Fq -- "-n. This breaks remote probe delivery" <<<"$GUARD_OUT"; then
  test_pass "helper exits 2 with -n guard message"
else
  test_fail "helper failed to refuse SSH_OPTS containing -n (status=$GUARD_STATUS)"
  printf '    output:\n%s\n' "$GUARD_OUT" >&2
fi

# =====================================================================
test_start "T30" "Tier-1 mock honors -n (catches future -n regression in defaults)"
# =====================================================================
# If a future change reintroduces -n into SSH_OPTS_DEFAULT (without
# tripping the T29 static guard, e.g., a quoted -n inside a longer
# value), the mock now exits 99 because exec 0</dev/null leaves stdin
# empty when -n is in argv. Verify the mock directly.
set +e
echo "should not be read" | "${TMP_DIR}/mock-ssh.sh" -n -o ConnectTimeout=5 root@1.2.3.4 "bash -s" >/dev/null 2>"${TMP_DIR}/mock-stderr.txt"
MOCK_RC=$?
set -e
if [[ "$MOCK_RC" -eq 99 ]] && grep -Fq "MOCK-SSH-ERROR: empty stdin received" "${TMP_DIR}/mock-stderr.txt"; then
  test_pass "mock-ssh exits 99 with -n in argv"
else
  test_fail "mock-ssh failed to detect -n (rc=$MOCK_RC)"
  printf '    stderr: %s\n' "$(cat "${TMP_DIR}/mock-stderr.txt")" >&2
fi

# =====================================================================
test_start "T31" "PROBE_OK must be LAST line, not anywhere"
# =====================================================================
# A canned response with PROBE_OK earlier in the output, followed by
# garbage on the last line, should fail (probe did not complete cleanly).
clear_responses
# Put PROBE_OK in the middle; trailing non-empty line means probe did
# not terminate properly.
set_response_no_sentinel 172.27.10.54 $'PROBE_OK\nUNIT garbage NRestarts=1 Result=success ActiveState=active'
set_response 172.27.10.50 "" 0
set_response 172.17.77.63 "" 0
set_response 172.27.10.55 "" 0
set_response 172.27.60.55 "" 0
run_capture helper
assert_exit 1 "exit 1 when PROBE_OK is not the last line"
assert_output_contains "no PROBE_OK sentinel" "treated as probe-incomplete"

# =====================================================================
runner_summary
