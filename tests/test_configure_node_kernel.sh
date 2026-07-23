#!/usr/bin/env bash
# Hermetic tests for configure-node-kernel.sh.
#
# Strategy: an ssh shim on PATH intercepts ssh invocations. The remote
# command is now a single rendered bash script (script writes it via
# build_remote_script with base64-encoded literals). The shim identifies
# it by the embedded mode="verify"/mode="apply" sentinel, reads simulated
# state from environment-variable-backed files, and emits the same
# protocol the real remote would: BOOTLOADER=, RUNTIME=, PERSISTENT=,
# REFRESH=, STATUS=.
#
# State variables used by tests (set per-test, exported for shim):
#   BOOTLOADER_FAKE         "grub" or "systemd-boot"
#   RUNTIME_HAS_PARAMS      1 (params in /proc/cmdline) or 0
#   PERSISTENT_HAS_PARAMS   1 (drop-in or cmdline file correct) or 0
#   REFRESH_FAILS           1 (simulate update-grub or pbt refresh failure) or 0
#
# Apply mode side effects (modeled by shim):
#   - Always runs refresh (the script's design after round-2 fixes).
#   - If PERSISTENT=0, writes persistent (becomes 1) and emits PERSISTENT=written.
#   - Runs refresh; if REFRESH_FAILS=1, emits STATUS=error_refresh_failed.
#   - If RUNTIME=1 at start AND persistent ends up correct, STATUS=ok (no reboot).
#   - Else STATUS=applied (reboot required).
#
# NOTE on coverage: the shim does NOT execute the rendered remote bash.
# The actual remote logic (detect_bootloader, runtime/persistent checks,
# write_persistent, refresh_bootloader) is exercised only by integration
# testing on a real or sandboxed node. This is documented as a known
# coverage gap; the hermetic tests cover the local-side logic, exit-code
# contract, and shim-protocol parsing.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "$SHIM_DIR"

# Faux config.yaml so the script discovers nodes.
CONFIG="${TMP_DIR}/config.yaml"
cat > "$CONFIG" <<'EOF'
domain: example.test
management:
  subnet: 192.0.2.0/24
  gateway: 192.0.2.1
nodes:
  - name: node1
    mgmt_ip: 192.0.2.11
  - name: node2
    mgmt_ip: 192.0.2.12
EOF

EMPTY_CONFIG="${TMP_DIR}/empty-config.yaml"
cat > "$EMPTY_CONFIG" <<'EOF'
domain: example.test
nodes: []
EOF

SSH_LOG="${TMP_DIR}/ssh.log"
STATE_FILE="${TMP_DIR}/state"

# Shim. Receives full ssh argv. Logs the host + mode, then dispatches.
cat > "${SHIM_DIR}/ssh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
host=""
for arg in "$@"; do
  if [[ "$arg" == root@* ]]; then
    host="${arg#root@}"
  fi
done
cmd="${@: -1}"

# Optional simulation of pure SSH transport failure (before any remote
# execution): if SSH_TRANSPORT_FAILS=1, exit non-zero with a stderr
# diagnostic that does NOT include "STATUS=" (mimics ssh: connect to host
# ... port 22: Connection refused).
if [[ "${SSH_TRANSPORT_FAILS:-0}" == "1" ]]; then
  echo "ssh: connect to host ${host} port 22: Connection refused" >&2
  exit 255
fi

if [[ -f "${STATE_FILE:?}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
fi

BOOTLOADER_FAKE="${BOOTLOADER_FAKE:-grub}"
RUNTIME_HAS_PARAMS="${RUNTIME_HAS_PARAMS:-0}"
PERSISTENT_HAS_PARAMS="${PERSISTENT_HAS_PARAMS:-0}"
REFRESH_FAILS="${REFRESH_FAILS:-0}"

# Identify the mode by grepping the rendered blob.
mode=""
if grep -q '^mode="verify"$' <<<"$cmd"; then
  mode=verify
elif grep -q '^mode="apply"$' <<<"$cmd"; then
  mode=apply
else
  echo "shim: did not recognize remote command (no mode= sentinel)" >&2
  exit 99
fi

echo "host=${host} mode=${mode}" >> "${SSH_LOG:?}"

emit_status() {
  echo "BOOTLOADER=${BOOTLOADER_FAKE}"
  case "$mode" in
    verify)
      echo "RUNTIME=${RUNTIME_HAS_PARAMS}"
      echo "PERSISTENT=${PERSISTENT_HAS_PARAMS}"
      if [[ "$RUNTIME_HAS_PARAMS" == "1" && "$PERSISTENT_HAS_PARAMS" == "1" ]]; then
        echo "STATUS=ok"
      elif [[ "$PERSISTENT_HAS_PARAMS" == "1" ]]; then
        echo "STATUS=reboot"
      else
        echo "STATUS=missing"
      fi
      ;;
    apply)
      echo "RUNTIME_BEFORE=${RUNTIME_HAS_PARAMS}"
      # Step 1: persistent.
      if [[ "$PERSISTENT_HAS_PARAMS" == "1" ]]; then
        echo "PERSISTENT=already_correct"
      else
        echo "PERSISTENT=written"
        # Persist the new state for later ssh calls in this test.
        sed -i.bak '/^PERSISTENT_HAS_PARAMS=/d' "${STATE_FILE}" 2>/dev/null || true
        echo "PERSISTENT_HAS_PARAMS=1" >> "${STATE_FILE}"
        rm -f "${STATE_FILE}.bak"
      fi
      # Step 2: ALWAYS refresh.
      if [[ "$REFRESH_FAILS" == "1" ]]; then
        echo "STATUS=error_refresh_failed"
        return 1
      fi
      echo "REFRESH=ok"
      # Step 3: runtime check + report.
      if [[ "$RUNTIME_HAS_PARAMS" == "1" ]]; then
        echo "STATUS=ok"
      else
        echo "STATUS=applied"
      fi
      ;;
  esac
}

emit_status
SHIM
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"
export SSH_LOG STATE_FILE

set_state() {
  : > "$STATE_FILE"
  for kv in "$@"; do
    echo "$kv" >> "$STATE_FILE"
  done
}

run_script() {
  local cfg_arg=(--config "$CONFIG")
  set +e
  output="$("${REPO_ROOT}/framework/scripts/configure-node-kernel.sh" "${cfg_arg[@]}" "$@" 2>&1)"
  rc=$?
  set -e
  SCRIPT_OUTPUT="$output"
  return "$rc"
}

run_script_with_config() {
  local cfg="$1"; shift
  set +e
  output="$("${REPO_ROOT}/framework/scripts/configure-node-kernel.sh" --config "$cfg" "$@" 2>&1)"
  rc=$?
  set -e
  SCRIPT_OUTPUT="$output"
  return "$rc"
}

# ---------------------------------------------------------------------------
test_start "kernel.usage.no-args" "no node and no --all -> exit 2"
: > "$SSH_LOG"; set_state
if run_script; then
  test_fail "expected non-zero, got 0"
elif [[ "$rc" -ne 2 ]]; then
  test_fail "expected exit 2, got ${rc}"
elif ! grep -Fq "Usage:" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'Usage:'; got: $SCRIPT_OUTPUT"
elif [[ -s "$SSH_LOG" ]]; then
  test_fail "ssh was called despite usage error"
else
  test_pass "usage error before any ssh"
fi

# ---------------------------------------------------------------------------
test_start "kernel.usage.all-and-node" "--all combined with a node name -> exit 2"
: > "$SSH_LOG"; set_state
if run_script --all node1; then
  test_fail "mutex violation accepted"
elif [[ "$rc" -ne 2 ]]; then
  test_fail "expected exit 2, got ${rc}"
elif ! grep -Fq "mutually exclusive" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'mutually exclusive'; got: $SCRIPT_OUTPUT"
else
  test_pass "--all + node rejected"
fi

# ---------------------------------------------------------------------------
test_start "kernel.usage.dry-run-verify-mutex" "--dry-run + --verify -> exit 2 (new in round-2 fixes)"
: > "$SSH_LOG"; set_state
if run_script --dry-run --verify --all; then
  test_fail "mutex violation accepted"
elif [[ "$rc" -ne 2 ]]; then
  test_fail "expected exit 2, got ${rc}; output: $SCRIPT_OUTPUT"
elif ! grep -Fq "mutually exclusive" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'mutually exclusive'; got: $SCRIPT_OUTPUT"
elif [[ -s "$SSH_LOG" ]]; then
  test_fail "ssh was called despite usage error"
else
  test_pass "--dry-run + --verify rejected"
fi

# ---------------------------------------------------------------------------
test_start "kernel.usage.config-without-value" "--config without value -> exit 2"
: > "$SSH_LOG"; set_state
set +e
output="$("${REPO_ROOT}/framework/scripts/configure-node-kernel.sh" --config 2>&1)"
rc=$?
set -e
SCRIPT_OUTPUT="$output"
if [[ "$rc" -ne 2 ]]; then
  test_fail "expected exit 2, got ${rc}"
elif ! grep -Fq "requires a path" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'requires a path'; got: $SCRIPT_OUTPUT"
else
  test_pass "missing --config value rejected"
fi

# ---------------------------------------------------------------------------
test_start "kernel.usage.unknown-node" "unknown node -> exit 2"
: > "$SSH_LOG"; set_state
if run_script does-not-exist; then
  test_fail "unknown node accepted"
elif [[ "$rc" -ne 2 ]]; then
  test_fail "expected exit 2, got ${rc}"
elif ! grep -Fq "not found" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'not found'; got: $SCRIPT_OUTPUT"
else
  test_pass "unknown node rejected"
fi

# ---------------------------------------------------------------------------
test_start "kernel.usage.empty-nodes-all" "--all with empty nodes list -> exit 2"
: > "$SSH_LOG"; set_state
if run_script_with_config "$EMPTY_CONFIG" --all; then
  test_fail "empty nodes list accepted"
elif [[ "$rc" -ne 2 ]]; then
  test_fail "expected exit 2, got ${rc}"
elif ! grep -Fq "no nodes found" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'no nodes found'; got: $SCRIPT_OUTPUT"
elif [[ -s "$SSH_LOG" ]]; then
  test_fail "ssh was called despite empty list"
else
  test_pass "empty nodes list fails loudly"
fi

# ---------------------------------------------------------------------------
test_start "kernel.dryrun.does-not-ssh" "--dry-run --all does not ssh"
: > "$SSH_LOG"; set_state
if ! run_script --dry-run --all; then
  test_fail "dry-run failed (rc=${rc}); output: $SCRIPT_OUTPUT"
elif ! grep -Fq "DRY-RUN" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'DRY-RUN' in output; got: $SCRIPT_OUTPUT"
elif ! grep -Fq "node1" <<<"$SCRIPT_OUTPUT" || ! grep -Fq "node2" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected both nodes in output; got: $SCRIPT_OUTPUT"
elif [[ -s "$SSH_LOG" ]]; then
  test_fail "ssh was called during dry-run"
else
  test_pass "dry-run plan printed without ssh"
fi

# ---------------------------------------------------------------------------
test_start "kernel.verify.runtime-and-persistent" "--verify, both runtime + persistent OK -> exit 0"
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=grub" \
  "RUNTIME_HAS_PARAMS=1" \
  "PERSISTENT_HAS_PARAMS=1"
if ! run_script --verify --all; then
  test_fail "verify failed (rc=${rc}); output: $SCRIPT_OUTPUT"
elif ! grep -Fq "OK (grub)" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'OK (grub)'; got: $SCRIPT_OUTPUT"
else
  test_pass "verify with runtime+persistent reports OK"
fi

# ---------------------------------------------------------------------------
test_start "kernel.verify.runtime-only-no-persistent" "--verify, runtime OK but persistent missing -> NOT ok (regression test)"
# This is the round-2 codex P1 fix: a node with /proc/cmdline patched but
# no persistent config must NOT report ok, because the workaround is not
# durable -- it would be lost on next reboot.
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=grub" \
  "RUNTIME_HAS_PARAMS=1" \
  "PERSISTENT_HAS_PARAMS=0"
if run_script --verify --all; then
  test_fail "verify reported success when persistence missing -- runtime-only false success bug"
elif grep -Fq "OK (grub)" <<<"$SCRIPT_OUTPUT"; then
  test_fail "verify reported OK when persistence missing; got: $SCRIPT_OUTPUT"
elif ! grep -Fq "MISSING" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'MISSING' (persistent absent); got: $SCRIPT_OUTPUT"
else
  test_pass "runtime-only without persistence is NOT ok (P1 fix)"
fi

# ---------------------------------------------------------------------------
test_start "kernel.verify.persistent-only-runtime-stale" "--verify, persistent OK but runtime stale -> REBOOT REQUIRED"
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=grub" \
  "RUNTIME_HAS_PARAMS=0" \
  "PERSISTENT_HAS_PARAMS=1"
if run_script --verify --all; then
  test_fail "expected non-zero, got 0"
elif ! grep -Fq "REBOOT REQUIRED" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'REBOOT REQUIRED'; got: $SCRIPT_OUTPUT"
else
  test_pass "verify with persistent-only reports reboot required"
fi

# ---------------------------------------------------------------------------
test_start "kernel.verify.systemd-boot.label" "--verify on systemd-boot reports correct bootloader label"
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=systemd-boot" \
  "RUNTIME_HAS_PARAMS=0" \
  "PERSISTENT_HAS_PARAMS=1"
if run_script --verify --all; then
  test_fail "expected non-zero, got 0"
elif ! grep -Fq "REBOOT REQUIRED (systemd-boot)" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'REBOOT REQUIRED (systemd-boot)'; got: $SCRIPT_OUTPUT"
else
  test_pass "systemd-boot label propagated correctly"
fi

# ---------------------------------------------------------------------------
test_start "kernel.apply.fresh-grub" "apply, GRUB, nothing in place -> exit 10, persistent written, refresh ran"
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=grub" \
  "RUNTIME_HAS_PARAMS=0" \
  "PERSISTENT_HAS_PARAMS=0"
if run_script node1; then
  test_fail "expected exit 10, got 0; output: $SCRIPT_OUTPUT"
elif [[ "$rc" -ne 10 ]]; then
  test_fail "expected exit 10, got ${rc}; output: $SCRIPT_OUTPUT"
elif ! grep -Fq "APPLIED (grub)" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'APPLIED (grub)'; got: $SCRIPT_OUTPUT"
elif ! grep -Fq "persistent=written" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'persistent=written'; got: $SCRIPT_OUTPUT"
elif ! grep -Fq "refresh=ok" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'refresh=ok'; got: $SCRIPT_OUTPUT"
else
  test_pass "fresh GRUB apply writes + refreshes"
fi

# ---------------------------------------------------------------------------
test_start "kernel.apply.runtime-only-makes-durable" "apply, runtime OK but persistent missing -> writes persistent, refreshes, exit 0 (regression test)"
# This is the round-2 codex P1 fix: apply must NOT short-circuit on
# runtime alone. It must ensure persistence too. After the apply, exit 0
# because runtime is already effective -- but only after we've made it
# durable.
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=grub" \
  "RUNTIME_HAS_PARAMS=1" \
  "PERSISTENT_HAS_PARAMS=0"
if ! run_script node1; then
  test_fail "expected exit 0 when runtime OK and we make persistence durable; got rc=${rc}"
elif ! grep -Fq "OK (grub)" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'OK (grub)'; got: $SCRIPT_OUTPUT"
elif ! grep -Fq "persistent=written" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'persistent=written' even when runtime OK; got: $SCRIPT_OUTPUT"
elif ! grep -Fq "refresh=ok" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'refresh=ok'; got: $SCRIPT_OUTPUT"
else
  test_pass "apply makes persistence durable even when runtime already effective"
fi

# ---------------------------------------------------------------------------
test_start "kernel.apply.idempotent-effective" "apply --all, runtime + persistent both OK -> exit 0, refresh STILL ran (always-refresh)"
# Round-2 design: refresh is always run in apply mode. If runtime AND
# persistent are both already correct, the apply is a quick no-op write
# (skipped because persistent is already correct) plus an idempotent
# refresh. STATUS=ok signals no reboot needed.
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=grub" \
  "RUNTIME_HAS_PARAMS=1" \
  "PERSISTENT_HAS_PARAMS=1"
if ! run_script --all; then
  test_fail "expected exit 0; got rc=${rc}; output: $SCRIPT_OUTPUT"
elif ! grep -Fq "OK (grub)" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'OK (grub)'; got: $SCRIPT_OUTPUT"
elif ! grep -Fq "already_correct" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'already_correct'; got: $SCRIPT_OUTPUT"
elif ! grep -Fq "host=192.0.2.11" "$SSH_LOG" || ! grep -Fq "host=192.0.2.12" "$SSH_LOG"; then
  test_fail "expected ssh to both nodes; got: $(cat $SSH_LOG)"
else
  test_pass "--all idempotent when already effective"
fi

# ---------------------------------------------------------------------------
test_start "kernel.apply.refresh-failure" "apply: refresh fails -> exit 1 (NOT exit 10)"
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=grub" \
  "RUNTIME_HAS_PARAMS=0" \
  "PERSISTENT_HAS_PARAMS=0" \
  "REFRESH_FAILS=1"
if run_script node1; then
  test_fail "expected non-zero; got 0"
elif [[ "$rc" -eq 10 ]]; then
  test_fail "refresh failure must NOT report reboot-required; got: $SCRIPT_OUTPUT"
elif [[ "$rc" -ne 1 ]]; then
  test_fail "expected exit 1, got ${rc}; output: $SCRIPT_OUTPUT"
elif ! grep -Fq "error_refresh_failed" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'error_refresh_failed'; got: $SCRIPT_OUTPUT"
else
  test_pass "refresh failure surfaces as exit 1"
fi

# ---------------------------------------------------------------------------
test_start "kernel.apply.systemdboot.fresh" "apply on systemd-boot, nothing in place -> exit 10"
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=systemd-boot" \
  "RUNTIME_HAS_PARAMS=0" \
  "PERSISTENT_HAS_PARAMS=0"
if run_script node1; then
  test_fail "expected exit 10, got 0"
elif [[ "$rc" -ne 10 ]]; then
  test_fail "expected exit 10, got ${rc}"
elif ! grep -Fq "APPLIED (systemd-boot)" <<<"$SCRIPT_OUTPUT"; then
  test_fail "expected 'APPLIED (systemd-boot)'; got: $SCRIPT_OUTPUT"
else
  test_pass "fresh systemd-boot apply"
fi

# ---------------------------------------------------------------------------
test_start "kernel.apply.idempotent-second-run" "apply twice: first writes+refreshes (exit 10), second is no-op (exit 10) without re-writing"
# Round-2 P3 (sub-claude): the script must be idempotent on rerun. The
# shim mutates state on first apply (PERSISTENT_HAS_PARAMS becomes 1);
# the second run should see persistent=already_correct.
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=grub" \
  "RUNTIME_HAS_PARAMS=0" \
  "PERSISTENT_HAS_PARAMS=0"
if run_script node1; then
  test_fail "first apply: expected exit 10, got 0"
elif [[ "$rc" -ne 10 ]]; then
  test_fail "first apply: expected exit 10, got ${rc}"
elif ! grep -Fq "persistent=written" <<<"$SCRIPT_OUTPUT"; then
  test_fail "first apply: expected 'persistent=written'; got: $SCRIPT_OUTPUT"
else
  # Second run -- shim has updated state to PERSISTENT_HAS_PARAMS=1.
  if run_script node1; then
    test_fail "second apply: expected exit 10, got 0"
  elif [[ "$rc" -ne 10 ]]; then
    test_fail "second apply: expected exit 10, got ${rc}; output: $SCRIPT_OUTPUT"
  elif ! grep -Fq "already_correct" <<<"$SCRIPT_OUTPUT"; then
    test_fail "second apply: expected 'already_correct'; got: $SCRIPT_OUTPUT"
  elif ! grep -Fq "refresh=ok" <<<"$SCRIPT_OUTPUT"; then
    test_fail "second apply: refresh should still run (always-refresh); got: $SCRIPT_OUTPUT"
  else
    test_pass "apply is idempotent on rerun (no re-write, refresh still runs)"
  fi
fi

# ---------------------------------------------------------------------------
test_start "kernel.apply.all-nodes-refresh-fail" "apply --all where every node's refresh fails -> overall exit 1"
# Renamed from "partial-failure" -- the shim has no per-host fixture so
# both nodes fail identically. This is still a useful test: it confirms
# that refresh failures from any node fail the overall run.
: > "$SSH_LOG"
set_state \
  "BOOTLOADER_FAKE=grub" \
  "RUNTIME_HAS_PARAMS=0" \
  "PERSISTENT_HAS_PARAMS=0" \
  "REFRESH_FAILS=1"
if run_script --all; then
  test_fail "expected non-zero, got 0"
elif [[ "$rc" -ne 1 ]]; then
  test_fail "expected exit 1, got ${rc}; output: $SCRIPT_OUTPUT"
else
  test_pass "all-node refresh failure -> exit 1"
fi

# ---------------------------------------------------------------------------
test_start "kernel.ssh.transport-failure-stderr" "SSH transport failure surfaces a diagnostic to stderr (sub-claude P1 fix)"
# Round-2 sub-claude P1: previously, SSH failures produced exit 1 with NO
# diagnostic output -- the error message was echoed to stdout, captured
# into $out by verify_node/apply_node, and discarded on the error path.
# This test runs the verify path with the shim simulating SSH transport
# failure, captures stderr separately, and asserts the operator sees the
# host name + diagnostic.
: > "$SSH_LOG"
set_state
set +e
output_stdout="$(SSH_TRANSPORT_FAILS=1 \
  "${REPO_ROOT}/framework/scripts/configure-node-kernel.sh" \
  --config "$CONFIG" --verify node1 \
  2>"${TMP_DIR}/stderr.out")"
rc=$?
output_stderr="$(cat "${TMP_DIR}/stderr.out")"
set -e
if [[ "$rc" -eq 0 ]]; then
  test_fail "expected non-zero on SSH failure, got 0"
elif [[ -z "$output_stderr" ]]; then
  test_fail "expected diagnostic on stderr, got empty stderr; stdout: $output_stdout"
elif ! grep -Fq "ERROR" <<<"$output_stderr"; then
  test_fail "expected 'ERROR' on stderr; stderr: $output_stderr"
elif ! grep -Fq "node1" <<<"$output_stderr"; then
  test_fail "expected node name 'node1' on stderr; stderr: $output_stderr"
else
  test_pass "SSH transport failure surfaces stderr diagnostic"
fi

runner_summary
