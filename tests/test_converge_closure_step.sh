#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

setup_fixture_repo() {
  local repo_dir="$1"

  mkdir -p "${repo_dir}/framework/scripts" "${repo_dir}/site"

  cp "${REPO_ROOT}/framework/scripts/converge-lib.sh" "${repo_dir}/framework/scripts/converge-lib.sh"
  chmod +x "${repo_dir}/framework/scripts/converge-lib.sh"

  cat > "${repo_dir}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

certbot_cluster_staging_override_targets() { return 0; }
EOF
  chmod +x "${repo_dir}/framework/scripts/certbot-cluster.sh"

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
vms:
  testapp_dev:
    ip: 10.0.0.41
EOF

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  cat > "${repo_dir}/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/framework/scripts"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
TOFU_TARGETS="${TEST_TARGETS:-}"
CLOSURE="${TEST_CLOSURE:-}"
CLOSURE_SSH_TIMEOUT="${TEST_SSH_TIMEOUT:-10}"
CLOSURE_SSH_INTERVAL="${TEST_SSH_INTERVAL:-1}"

log() { printf '%s\n' "$*"; }
die() { printf 'FATAL: %s\n' "$*"; exit 1; }
step_start() { printf 'STEP-START %s %s\n' "$1" "$2"; }
step_done() { printf 'STEP-DONE %s\n' "$1"; }

source "${SCRIPT_DIR}/converge-lib.sh"
converge_require_context
converge_step_closure
EOF
  chmod +x "${repo_dir}/run.sh"
}

setup_shims() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "nix-copy" >> "${STUB_LOG_FILE}"
exit "${STUB_NIX_EXIT_CODE:-0}"
EOF
  chmod +x "${shim_dir}/nix"

  cat > "${shim_dir}/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${shim_dir}/sleep"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"
state_dir="${STUB_STATE_DIR}"

case "${remote_cmd}" in
  "readlink -f /run/current-system")
    count_file="${state_dir}/readlink-count"
    count=0
    if [[ -f "${count_file}" ]]; then
      count="$(cat "${count_file}")"
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" > "${count_file}"
    case "${count}" in
      1)
        printf '%s\n' "ssh:readlink-before" >> "${STUB_LOG_FILE}"
        printf '%s\n' "${STUB_SYSTEM_BEFORE:-/nix/store/system-before}"
        ;;
      2)
        printf '%s\n' "ssh:readlink-after" >> "${STUB_LOG_FILE}"
        printf '%s\n' "${STUB_SYSTEM_AFTER:-${STUB_REQUESTED_CLOSURE:-/nix/store/system-after}}"
        ;;
      *)
        printf '%s\n' "ssh:readlink-reboot" >> "${STUB_LOG_FILE}"
        printf '%s\n' "${STUB_SYSTEM_REBOOT:-${STUB_SYSTEM_AFTER:-${STUB_REQUESTED_CLOSURE:-/nix/store/system-after}}}"
        ;;
    esac
    ;;
  "true")
    count_file="${state_dir}/wait-count"
    count=0
    if [[ -f "${count_file}" ]]; then
      count="$(cat "${count_file}")"
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" > "${count_file}"
    printf '%s\n' "ssh:wait" >> "${STUB_LOG_FILE}"
    printf 'ssh:wait-argv:%s\n' "$*" >> "${STUB_LOG_FILE}"
    if [[ "${count}" -ge "${STUB_SSH_SUCCEED_AFTER:-1}" ]]; then
      exit 0
    fi
    exit 1
    ;;
  *"/bin/switch-to-configuration switch")
    printf '%s\n' "ssh:switch" >> "${STUB_LOG_FILE}"
    exit "${STUB_SWITCH_EXIT_CODE:-0}"
    ;;
  *"systemctl reset-failed"*)
    printf '%s\n' "ssh:reset-failed" >> "${STUB_LOG_FILE}"
    exit 0
    ;;
  *"systemctl show -p ActiveState"*"${STUB_SWITCH_UNIT_NAME:-nixos-switch-closure}"*)
    show_count_file="${state_dir}/systemctl-show-count"
    show_count=0
    if [[ -f "${show_count_file}" ]]; then
      show_count="$(cat "${show_count_file}")"
    fi
    show_count=$((show_count + 1))
    printf '%s\n' "${show_count}" > "${show_count_file}"
    printf 'ssh:systemctl-show:%s\n' "${show_count}" >> "${STUB_LOG_FILE}"
    # Replay a configurable sequence of (ActiveState/SubState/Result)
    # triples so tests can model "still running, then terminal."
    # STUB_SWITCH_SHOW_SEQUENCE entries are separated by '|' and each
    # entry is a multi-line "ActiveState=...\nSubState=...\nResult=..."
    # block. If unset, the legacy single-shot defaults are returned.
    if [[ -n "${STUB_SWITCH_SHOW_SEQUENCE:-}" ]]; then
      IFS='|' read -ra _stub_show_seq <<< "${STUB_SWITCH_SHOW_SEQUENCE}"
      idx=$(( show_count - 1 ))
      if (( idx >= ${#_stub_show_seq[@]} )); then
        idx=$(( ${#_stub_show_seq[@]} - 1 ))
      fi
      printf '%b\n' "${_stub_show_seq[$idx]}"
    else
      printf '%s\n' "${STUB_SWITCH_ACTIVE_STATE:-ActiveState=inactive}"
      printf '%s\n' "${STUB_SWITCH_SUB_STATE:-SubState=exited}"
      printf '%s\n' "${STUB_SWITCH_RESULT:-Result=success}"
    fi
    exit 0
    ;;
  *"sed -i "*"/boot/grub/grub.cfg"*)
    printf '%s\n' "ssh:sed" >> "${STUB_LOG_FILE}"
    exit "${STUB_SED_EXIT_CODE:-0}"
    ;;
  "reboot")
    printf '%s\n' "ssh:reboot" >> "${STUB_LOG_FILE}"
    exit 0
    ;;
  *)
    printf '%s\n' "ssh:other:${remote_cmd}" >> "${STUB_LOG_FILE}"
    exit 0
    ;;
esac
EOF
  chmod +x "${shim_dir}/ssh"
}

run_closure_fixture() {
  local scenario="$1"
  local targets="$2"
  local closure="$3"
  local repo_dir="${TMP_DIR}/${scenario}-repo"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local state_dir="${TMP_DIR}/${scenario}-state"
  local output_file="${TMP_DIR}/${scenario}.out"
  local log_file="${TMP_DIR}/${scenario}.log"

  setup_fixture_repo "${repo_dir}"
  setup_shims "${shim_dir}"
  mkdir -p "${state_dir}"
  : > "${log_file}"

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_LOG_FILE="${log_file}"
    export STUB_STATE_DIR="${state_dir}"
    export STUB_REQUESTED_CLOSURE="${closure}"
    export TEST_TARGETS="${targets}"
    export TEST_CLOSURE="${closure}"
    "${repo_dir}/run.sh"
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n%s\n' "${status}" "${output_file}" "${log_file}"
}

artifact_status() {
  printf '%s\n' "$1" | sed -n '1p'
}

artifact_output_file() {
  printf '%s\n' "$1" | sed -n '2p'
}

artifact_log_file() {
  printf '%s\n' "$1" | sed -n '3p'
}

assert_in_order() {
  local log_file="$1"
  shift
  local last_line=0
  local needle=""
  local current_line=""

  for needle in "$@"; do
    current_line="$(grep -n -F "${needle}" "${log_file}" | head -1 | cut -d: -f1 || true)"
    if [[ -z "${current_line}" || "${current_line}" -le "${last_line}" ]]; then
      return 1
    fi
    last_line="${current_line}"
  done
}

test_start "4.2" "closure step copies, switches, fixes grub, reboots, and waits in order"
CHANGED_ARTIFACTS="$(run_closure_fixture changed '-target=module.testapp_dev' '/nix/store/test-closure')"
CHANGED_STATUS="$(artifact_status "${CHANGED_ARTIFACTS}")"
CHANGED_OUTPUT_FILE="$(artifact_output_file "${CHANGED_ARTIFACTS}")"
CHANGED_LOG_FILE="$(artifact_log_file "${CHANGED_ARTIFACTS}")"
if [[ "${CHANGED_STATUS}" == "0" ]]; then
  test_pass "closure step exits 0 when the target system changes"
else
  test_fail "closure step exits 0 when the target system changes"
  cat "${CHANGED_OUTPUT_FILE}" >&2
fi
if assert_in_order \
  "${CHANGED_LOG_FILE}" \
  "nix-copy" \
  "ssh:readlink-before" \
  "ssh:switch" \
  "ssh:readlink-after" \
  "ssh:sed" \
  "ssh:reboot" \
  "ssh:readlink-reboot"; then
  test_pass "copy, activation, reboot, and post-boot closure verification occur in order"
else
  test_fail "copy, activation, reboot, and post-boot closure verification occur in order"
  cat "${CHANGED_LOG_FILE}" >&2
fi
if grep -q 'ssh:wait-argv:.*-n .*StrictHostKeyChecking=no .*UserKnownHostsFile=/dev/null .*root@10.0.0.41 true' "${CHANGED_LOG_FILE}"; then
  test_pass "SSH reconnect probe uses host-key-bypass options after reboot"
else
  test_fail "SSH reconnect probe uses host-key-bypass options after reboot"
  cat "${CHANGED_LOG_FILE}" >&2
fi

test_start "4.2a" "grub fixup sed uses safe pattern that won't corrupt /nix/store/ paths"
CONVERGE_LIB="${REPO_ROOT}/framework/scripts/converge-lib.sh"
# The sed must match )/store/ (after GRUB drive prefix), NOT bare /store/
# which would corrupt /nix/store/ → /nix/nix/store/
if grep -q "s|)/store/|)/nix/store/|g" "${CONVERGE_LIB}"; then
  test_pass "converge-lib.sh uses safe sed pattern s|)/store/|)/nix/store/|g"
else
  test_fail "converge-lib.sh must use s|)/store/|)/nix/store/|g (not the unsafe s|/store/|/nix/store/|g)"
fi
if grep -q "s|/store/|/nix/store/|g" "${CONVERGE_LIB}"; then
  test_fail "converge-lib.sh contains the unsafe sed pattern s|/store/|/nix/store/|g"
else
  test_pass "converge-lib.sh does not contain the unsafe sed pattern"
fi

test_start "4.2b" "closure step is skipped entirely when no --closure is set"
SKIP_ARTIFACTS="$(run_closure_fixture skip '-target=module.testapp_dev' '')"
SKIP_STATUS="$(artifact_status "${SKIP_ARTIFACTS}")"
SKIP_LOG_FILE="$(artifact_log_file "${SKIP_ARTIFACTS}")"
if [[ "${SKIP_STATUS}" == "0" ]]; then
  test_pass "closure step skip path exits 0"
else
  test_fail "closure step skip path exits 0"
fi
if [[ ! -s "${SKIP_LOG_FILE}" ]]; then
  test_pass "no nix or ssh commands run when closure is omitted"
else
  test_fail "no nix or ssh commands run when closure is omitted"
  cat "${SKIP_LOG_FILE}" >&2
fi

test_start "4.2c" "no-op closure activation skips the reboot"
NOOP_ARTIFACTS="$(
  STUB_SYSTEM_BEFORE="/nix/store/test-closure" run_closure_fixture noop '-target=module.testapp_dev' '/nix/store/test-closure'
)"
NOOP_STATUS="$(artifact_status "${NOOP_ARTIFACTS}")"
NOOP_OUTPUT_FILE="$(artifact_output_file "${NOOP_ARTIFACTS}")"
NOOP_LOG_FILE="$(artifact_log_file "${NOOP_ARTIFACTS}")"
if [[ "${NOOP_STATUS}" == "0" ]]; then
  test_pass "no-op closure step exits 0"
else
  test_fail "no-op closure step exits 0"
  cat "${NOOP_OUTPUT_FILE}" >&2
fi
if grep -q 'closure already active, no reboot needed' "${NOOP_OUTPUT_FILE}"; then
  test_pass "no-op closure step reports that no reboot is needed"
else
  test_fail "no-op closure step reports that no reboot is needed"
  cat "${NOOP_OUTPUT_FILE}" >&2
fi
if ! grep -q '^ssh:reboot$' "${NOOP_LOG_FILE}"; then
  test_pass "no reboot occurs when the closure is already active"
else
  test_fail "no reboot occurs when the closure is already active"
  cat "${NOOP_LOG_FILE}" >&2
fi

test_start "4.2d" "SSH wait timeout fails closed after reboot"
TIMEOUT_ARTIFACTS="$(
  STUB_SSH_SUCCEED_AFTER=99 TEST_SSH_TIMEOUT=2 run_closure_fixture timeout '-target=module.testapp_dev' '/nix/store/test-closure'
)"
TIMEOUT_STATUS="$(artifact_status "${TIMEOUT_ARTIFACTS}")"
TIMEOUT_OUTPUT_FILE="$(artifact_output_file "${TIMEOUT_ARTIFACTS}")"
if [[ "${TIMEOUT_STATUS}" != "0" ]]; then
  test_pass "timeout path exits non-zero"
else
  test_fail "timeout path exits non-zero"
  cat "${TIMEOUT_OUTPUT_FILE}" >&2
fi
if grep -q 'Timed out waiting.*for SSH' "${TIMEOUT_OUTPUT_FILE}"; then
  test_pass "timeout path reports the SSH wait failure clearly"
else
  test_fail "timeout path reports the SSH wait failure clearly"
  cat "${TIMEOUT_OUTPUT_FILE}" >&2
fi

test_start "4.2e" "closure step fails if the VM reboots into the wrong generation"
MISMATCH_ARTIFACTS="$(
  STUB_SYSTEM_REBOOT="/nix/store/system-rollback" run_closure_fixture mismatch '-target=module.testapp_dev' '/nix/store/test-closure'
)"
MISMATCH_STATUS="$(artifact_status "${MISMATCH_ARTIFACTS}")"
MISMATCH_OUTPUT_FILE="$(artifact_output_file "${MISMATCH_ARTIFACTS}")"
MISMATCH_LOG_FILE="$(artifact_log_file "${MISMATCH_ARTIFACTS}")"
if [[ "${MISMATCH_STATUS}" != "0" ]]; then
  test_pass "post-reboot closure mismatch exits non-zero"
else
  test_fail "post-reboot closure mismatch exits non-zero"
  cat "${MISMATCH_OUTPUT_FILE}" >&2
fi
if grep -q 'Closure mismatch after reboot on 10.0.0.41: expected /nix/store/test-closure, got /nix/store/system-rollback' "${MISMATCH_OUTPUT_FILE}"; then
  test_pass "post-reboot closure mismatch reports the unexpected generation"
else
  test_fail "post-reboot closure mismatch reports the unexpected generation"
  cat "${MISMATCH_OUTPUT_FILE}" >&2
fi
if assert_in_order "${MISMATCH_LOG_FILE}" "ssh:reboot" "ssh:readlink-reboot"; then
  test_pass "post-reboot mismatch is detected after SSH returns"
else
  test_fail "post-reboot mismatch is detected after SSH returns"
  cat "${MISMATCH_LOG_FILE}" >&2
fi

test_start "4.2f" "closure switch failure is detected and fails closed"
SWITCH_FAIL_ARTIFACTS="$(
  STUB_SWITCH_RESULT="Result=exit-code" run_closure_fixture switch-fail '-target=module.testapp_dev' '/nix/store/test-closure'
)"
SWITCH_FAIL_STATUS="$(artifact_status "${SWITCH_FAIL_ARTIFACTS}")"
SWITCH_FAIL_OUTPUT_FILE="$(artifact_output_file "${SWITCH_FAIL_ARTIFACTS}")"
if [[ "${SWITCH_FAIL_STATUS}" != "0" ]]; then
  test_pass "switch failure exits non-zero"
else
  test_fail "switch failure exits non-zero"
  cat "${SWITCH_FAIL_OUTPUT_FILE}" >&2
fi
if grep -q 'Closure switch failed' "${SWITCH_FAIL_OUTPUT_FILE}"; then
  test_pass "switch failure reports the error"
else
  test_fail "switch failure reports the error"
  cat "${SWITCH_FAIL_OUTPUT_FILE}" >&2
fi

test_start "4.2g" "closure switch success is verified via systemctl show"
SUCCESS_ARTIFACTS="$(
  STUB_SWITCH_RESULT="Result=success" run_closure_fixture switch-ok '-target=module.testapp_dev' '/nix/store/test-closure'
)"
SUCCESS_STATUS="$(artifact_status "${SUCCESS_ARTIFACTS}")"
SUCCESS_OUTPUT_FILE="$(artifact_output_file "${SUCCESS_ARTIFACTS}")"
SUCCESS_LOG_FILE="$(artifact_log_file "${SUCCESS_ARTIFACTS}")"
if [[ "${SUCCESS_STATUS}" == "0" ]]; then
  test_pass "switch success exits 0"
else
  test_fail "switch success exits 0"
  cat "${SUCCESS_OUTPUT_FILE}" >&2
fi
if grep -q 'closure switch completed successfully' "${SUCCESS_OUTPUT_FILE}"; then
  test_pass "switch success is logged"
else
  test_fail "switch success is logged"
  cat "${SUCCESS_OUTPUT_FILE}" >&2
fi
if grep -q 'ssh:systemctl-show' "${SUCCESS_LOG_FILE}"; then
  test_pass "systemctl show is called to verify switch result"
else
  test_fail "systemctl show is called to verify switch result"
  cat "${SUCCESS_LOG_FILE}" >&2
fi

test_start "4.2h" "successful switch triggers reboot and SSH returns (services restart)"
# The full changed-closure path (test 4.2) already exercises this:
# switch succeeds → closure changed → reboot → wait_for_ssh → readlink.
# This test verifies that the specific sequence proves service recovery:
# 1. systemd-run switch completes with Result=success
# 2. reboot is issued (old services are dead, new activation didn't run them)
# 3. SSH returns after reboot (proves sshd started → multi-user.target reached)
# 4. readlink confirms the new closure is active
# If all four happen in order, gitlab-runner (wantedBy multi-user.target)
# must also be running — there's no mechanism in NixOS for multi-user.target
# to be reached without starting all wantedBy services.
# Uses CHANGED_LOG_FILE from test 4.2 (the full changed-closure run)
if assert_in_order "${CHANGED_LOG_FILE}" \
  "ssh:switch" \
  "ssh:systemctl-show" \
  "ssh:reboot" \
  "ssh:readlink-reboot"; then
  test_pass "switch → verify → reboot → post-reboot readlink proves service recovery"
else
  test_fail "switch → verify → reboot → post-reboot readlink proves service recovery"
  cat "${CHANGED_LOG_FILE}" >&2
fi
# The reboot is the mechanism that guarantees gitlab-runner restarts.
# Without it, the switch activates the new config but the runner was
# killed during the switch (it was the SSH client's ancestor). The
# reboot starts everything fresh from the new closure.
if grep -q 'ssh:reboot' "${CHANGED_LOG_FILE}"; then
  test_pass "reboot occurs after successful switch (ensures clean service start)"
else
  test_fail "reboot occurs after successful switch (ensures clean service start)"
  cat "${CHANGED_LOG_FILE}" >&2
fi

# Regression: the polling loop must not break on Result=success while the
# unit is still running. systemctl returns Result=success as the default
# value during execution; only ActiveState terminal values (inactive,
# failed) and SubState=exited indicate the unit has actually finished.
# Pre-fix behavior (matching Result=success in the break grep) caused the
# loop to exit on the first probe, the post-loop check to misreport
# "completed successfully," and the verifier to die on the still-old
# /run/current-system. See gitlab issue for details.
test_start "4.2i" "polling waits for terminal state, not Result=success default"
RUNNING_TRIPLE="ActiveState=activating\nSubState=start\nResult=success"
TERMINAL_TRIPLE="ActiveState=active\nSubState=exited\nResult=success"
RUNNING_ARTIFACTS="$(
  STUB_SWITCH_SHOW_SEQUENCE="${RUNNING_TRIPLE}|${RUNNING_TRIPLE}|${RUNNING_TRIPLE}|${TERMINAL_TRIPLE}" \
    run_closure_fixture polling-waits '-target=module.testapp_dev' '/nix/store/test-closure'
)"
RUNNING_STATUS="$(artifact_status "${RUNNING_ARTIFACTS}")"
RUNNING_OUTPUT_FILE="$(artifact_output_file "${RUNNING_ARTIFACTS}")"
RUNNING_LOG_FILE="$(artifact_log_file "${RUNNING_ARTIFACTS}")"
if [[ "${RUNNING_STATUS}" == "0" ]]; then
  test_pass "still-running unit eventually transitions to terminal success and exit 0"
else
  test_fail "still-running unit eventually transitions to terminal success and exit 0"
  cat "${RUNNING_OUTPUT_FILE}" >&2
fi
SHOW_COUNT="$(grep -c '^ssh:systemctl-show:' "${RUNNING_LOG_FILE}" || true)"
if [[ "${SHOW_COUNT}" -ge 4 ]]; then
  test_pass "polling did not break out on the first Result=success default (calls=${SHOW_COUNT})"
else
  test_fail "polling broke out before reaching terminal state (calls=${SHOW_COUNT}, expected ≥4)"
  cat "${RUNNING_LOG_FILE}" >&2
fi

# Regression: the post-loop result check must distinguish "exited
# successfully" from "exited with failure." A unit that finishes with
# Result=exit-code (e.g., switch-to-configuration exit 4 after
# gitlab-gen-secrets fails during activation) must fail-closed, not be
# misreported as "completed successfully."
test_start "4.2j" "switch failure after running phase is detected as failure"
TERMINAL_FAILURE="ActiveState=failed\nSubState=failed\nResult=exit-code"
FAIL_LATE_ARTIFACTS="$(
  STUB_SWITCH_SHOW_SEQUENCE="${RUNNING_TRIPLE}|${RUNNING_TRIPLE}|${TERMINAL_FAILURE}" \
    run_closure_fixture polling-fail-late '-target=module.testapp_dev' '/nix/store/test-closure'
)"
FAIL_LATE_STATUS="$(artifact_status "${FAIL_LATE_ARTIFACTS}")"
FAIL_LATE_OUTPUT_FILE="$(artifact_output_file "${FAIL_LATE_ARTIFACTS}")"
if [[ "${FAIL_LATE_STATUS}" != "0" ]]; then
  test_pass "late-failing switch exits non-zero"
else
  test_fail "late-failing switch exits non-zero"
  cat "${FAIL_LATE_OUTPUT_FILE}" >&2
fi
if grep -q 'Closure switch failed' "${FAIL_LATE_OUTPUT_FILE}"; then
  test_pass "late-failing switch produces explicit failure message"
else
  test_fail "late-failing switch produces explicit failure message"
  cat "${FAIL_LATE_OUTPUT_FILE}" >&2
fi

runner_summary
