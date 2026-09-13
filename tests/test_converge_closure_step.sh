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

  # `date +%s` shim: the poll loop uses a WALL-CLOCK deadline. With sleep
  # shimmed to instant, a real clock would make the budget-expiry test spin
  # for switch_max real seconds. Model the passage of time deterministically
  # instead: each `date +%s` advances a per-scenario counter by STUB_DATE_STEP
  # (default 3, matching the loop's `sleep 3`), so the loop reaches its
  # deadline in ~switch_max/step iterations and terminal-state tests still
  # break well before it. Any other `date` invocation passes through.
  cat > "${shim_dir}/date" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "+%s" ]]; then
  f="${STUB_STATE_DIR}/date-epoch"
  n=0
  [[ -f "${f}" ]] && n="$(cat "${f}")"
  n=$(( n + ${STUB_DATE_STEP:-3} ))
  printf '%s\n' "${n}" > "${f}"
  printf '%s\n' "${n}"
  exit 0
fi
exec /bin/date "$@"
EOF
  chmod +x "${shim_dir}/date"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"
state_dir="${STUB_STATE_DIR}"

case "${remote_cmd}" in
  *"findmnt -n -o SOURCE /"*"/dev/disk/by-label/nixos"*)
    count_file="${state_dir}/root-label-probe-count"
    count=0
    if [[ -f "${count_file}" ]]; then
      count="$(cat "${count_file}")"
    fi
    count=$((count + 1))
    printf '%s\n' "${count}" > "${count_file}"
    root_dev="${STUB_ROOT_DEV:-/dev/sda1}"
    if [[ "${count}" -eq 1 ]]; then
      printf '%s\n' "ssh:root-label-probe" >> "${STUB_LOG_FILE}"
      probe_status="${STUB_ROOT_PROBE_STATUS:-ok}"
      label_present="${STUB_ROOT_LABEL_PRESENT_BEFORE:-1}"
      label_target="${STUB_ROOT_LABEL_TARGET_BEFORE:-${root_dev}}"
    else
      printf '%s\n' "ssh:root-label-reprobe" >> "${STUB_LOG_FILE}"
      probe_status="${STUB_ROOT_REPROBE_STATUS:-${STUB_ROOT_PROBE_STATUS:-ok}}"
      label_present="${STUB_ROOT_LABEL_PRESENT_AFTER:-${STUB_ROOT_LABEL_PRESENT_BEFORE:-1}}"
      label_target="${STUB_ROOT_LABEL_TARGET_AFTER:-${STUB_ROOT_LABEL_TARGET_BEFORE:-${root_dev}}}"
    fi
    printf 'probe_status=%s\n' "${probe_status}"
    if [[ "${probe_status}" == "ok" ]]; then
      printf 'root_dev=%s\n' "${root_dev}"
      printf 'label_present=%s\n' "${label_present}"
      if [[ "${label_present}" == "1" ]]; then
        printf 'label_target=%s\n' "${label_target}"
      else
        printf 'label_target=\n'
      fi
    fi
    exit 0
    ;;
  *"blkid -p -o export"*)
    printf '%s\n' "ssh:root-label-blkid" >> "${STUB_LOG_FILE}"
    blkid_label="${STUB_BLKID_LABEL-nixos}"
    if [[ -n "${STUB_BLKID_OUTPUT+x}" ]]; then
      printf '%b\n' "${STUB_BLKID_OUTPUT}"
    else
      if [[ -n "${blkid_label}" ]]; then
        printf 'LABEL=%s\n' "${blkid_label}"
      fi
      printf '%s\n' "UUID=00000000-0000-0000-0000-000000000756"
      printf '%s\n' "TYPE=ext4"
    fi
    printf '__BLKID_STATUS=%s\n' "${STUB_BLKID_EXIT_CODE:-0}"
    exit 0
    ;;
  *"udevadm trigger --settle --action=change"*)
    printf '%s\n' "ssh:root-label-udevadm" >> "${STUB_LOG_FILE}"
    if [[ -n "${STUB_UDEVADM_OUTPUT:-}" ]]; then
      printf '%b\n' "${STUB_UDEVADM_OUTPUT}"
    fi
    printf '__UDEVADM_STATUS=%s\n' "${STUB_UDEVADM_EXIT_CODE:-0}"
    exit 0
    ;;
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
  *"systemctl show -p SubState --value"*)
    # Pre-start stomp guard (#711 retry safety) probes the existing unit's
    # SubState before cleaning up. Model a real systemd: an ABSENT unit prints
    # a concrete "dead" (verified live), so the unset default is "dead" (guard
    # proceeds). A test may set STUB_EXISTING_SUBSTATE to "running"/"start" (a
    # live switch → guard dies) or to the empty string (probe failure → guard
    # fails closed). Use ${VAR-default} so a set-but-empty value stays empty.
    printf '%s\n' "ssh:substate-probe" >> "${STUB_LOG_FILE}"
    printf '%s\n' "${STUB_EXISTING_SUBSTATE-dead}"
    exit 0
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
CHANGED_ARTIFACTS="$(
  STUB_BLKID_LABEL=nixos run_closure_fixture changed '-target=module.testapp_dev' '/nix/store/test-closure'
)"
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
  "ssh:root-label-probe" \
  "ssh:root-label-blkid" \
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

test_start "4.2p" "root label preflight healthy path proceeds without udev retrigger"
if [[ "${CHANGED_STATUS}" == "0" ]]; then
  test_pass "healthy root-label preflight exits 0"
else
  test_fail "healthy root-label preflight exits 0"
  cat "${CHANGED_OUTPUT_FILE}" >&2
fi
if assert_in_order "${CHANGED_LOG_FILE}" "ssh:root-label-probe" "ssh:root-label-blkid" "nix-copy" "ssh:switch"; then
  test_pass "healthy preflight blkid-verifies before nix copy and the switch proceeds"
else
  test_fail "healthy preflight must blkid-verify before nix copy and allow the switch"
  cat "${CHANGED_LOG_FILE}" >&2
fi
if ! grep -q '^ssh:root-label-udevadm$' "${CHANGED_LOG_FILE}"; then
  test_pass "healthy preflight does not run udevadm trigger"
else
  test_fail "healthy preflight must not run udevadm trigger"
  cat "${CHANGED_LOG_FILE}" >&2
fi

test_start "4.2q" "root label preflight repairs missing udev symlink and proceeds"
REPAIR_ARTIFACTS="$(
  STUB_ROOT_LABEL_PRESENT_BEFORE=0 \
  STUB_ROOT_LABEL_PRESENT_AFTER=1 \
  STUB_BLKID_LABEL=nixos \
    run_closure_fixture root-label-repairable '-target=module.testapp_dev' '/nix/store/test-closure'
)"
REPAIR_STATUS="$(artifact_status "${REPAIR_ARTIFACTS}")"
REPAIR_OUTPUT_FILE="$(artifact_output_file "${REPAIR_ARTIFACTS}")"
REPAIR_LOG_FILE="$(artifact_log_file "${REPAIR_ARTIFACTS}")"
if [[ "${REPAIR_STATUS}" == "0" ]]; then
  test_pass "repairable root-label preflight exits 0"
else
  test_fail "repairable root-label preflight exits 0"
  cat "${REPAIR_OUTPUT_FILE}" >&2
fi
if grep -q 'repaired /dev/disk/by-label/nixos on 10.0.0.41 by retriggering udev for /dev/sda1' "${REPAIR_OUTPUT_FILE}"; then
  test_pass "repairable preflight logs the udev repair"
else
  test_fail "repairable preflight must log the udev repair"
  cat "${REPAIR_OUTPUT_FILE}" >&2
fi
if assert_in_order "${REPAIR_LOG_FILE}" \
  "ssh:root-label-probe" \
  "ssh:root-label-blkid" \
  "ssh:root-label-udevadm" \
  "ssh:root-label-reprobe" \
  "nix-copy" \
  "ssh:switch"; then
  test_pass "repairable preflight probes, verifies LABEL=nixos, retriggers udev, re-probes, then switches"
else
  test_fail "repairable preflight sequence must reach copy and switch only after successful repair"
  cat "${REPAIR_LOG_FILE}" >&2
fi

test_start "4.2r" "root label preflight fails closed when the filesystem label is missing"
BROKEN_LABEL_ARTIFACTS="$(
  STUB_ROOT_LABEL_PRESENT_BEFORE=0 \
  STUB_BLKID_LABEL= \
    run_closure_fixture root-label-broken '-target=module.testapp_dev' '/nix/store/test-closure'
)"
BROKEN_LABEL_STATUS="$(artifact_status "${BROKEN_LABEL_ARTIFACTS}")"
BROKEN_LABEL_OUTPUT_FILE="$(artifact_output_file "${BROKEN_LABEL_ARTIFACTS}")"
BROKEN_LABEL_LOG_FILE="$(artifact_log_file "${BROKEN_LABEL_ARTIFACTS}")"
if [[ "${BROKEN_LABEL_STATUS}" != "0" ]]; then
  test_pass "missing filesystem label exits non-zero"
else
  test_fail "missing filesystem label exits non-zero"
  cat "${BROKEN_LABEL_OUTPUT_FILE}" >&2
fi
if grep -q 'on-disk filesystem label missing on superblock or wrong for /dev/sda1' "${BROKEN_LABEL_OUTPUT_FILE}" && \
   grep -q 'symlink_before=absent' "${BROKEN_LABEL_OUTPUT_FILE}" && \
   grep -q 'blkid_output=' "${BROKEN_LABEL_OUTPUT_FILE}"; then
  test_pass "missing-label diagnostic names root device, symlink state, and blkid output"
else
  test_fail "missing-label diagnostic must name root device, symlink state, and blkid output"
  cat "${BROKEN_LABEL_OUTPUT_FILE}" >&2
fi
if assert_in_order "${BROKEN_LABEL_LOG_FILE}" "ssh:root-label-probe" "ssh:root-label-blkid"; then
  test_pass "missing-label preflight probes symlink then blkid"
else
  test_fail "missing-label preflight must probe symlink then blkid"
  cat "${BROKEN_LABEL_LOG_FILE}" >&2
fi
if ! grep -qE '^(nix-copy|ssh:switch|ssh:reset-failed|ssh:reboot)$' "${BROKEN_LABEL_LOG_FILE}"; then
  test_pass "missing-label preflight prevents nix copy, switch, reset, and reboot"
else
  test_fail "missing-label preflight must prevent all downstream closure actions"
  cat "${BROKEN_LABEL_LOG_FILE}" >&2
fi

test_start "4.2r2" "root label preflight fails closed when symlink is present but filesystem label is wrong"
STALE_SYMLINK_LABEL_ARTIFACTS="$(
  STUB_ROOT_LABEL_PRESENT_BEFORE=1 \
  STUB_ROOT_LABEL_TARGET_BEFORE=/dev/sda1 \
  STUB_BLKID_LABEL=stale \
    run_closure_fixture root-label-present-broken '-target=module.testapp_dev' '/nix/store/test-closure'
)"
STALE_SYMLINK_LABEL_STATUS="$(artifact_status "${STALE_SYMLINK_LABEL_ARTIFACTS}")"
STALE_SYMLINK_LABEL_OUTPUT_FILE="$(artifact_output_file "${STALE_SYMLINK_LABEL_ARTIFACTS}")"
STALE_SYMLINK_LABEL_LOG_FILE="$(artifact_log_file "${STALE_SYMLINK_LABEL_ARTIFACTS}")"
if [[ "${STALE_SYMLINK_LABEL_STATUS}" != "0" ]]; then
  test_pass "present symlink with wrong filesystem label exits non-zero"
else
  test_fail "present symlink with wrong filesystem label exits non-zero"
  cat "${STALE_SYMLINK_LABEL_OUTPUT_FILE}" >&2
fi
if grep -q 'on-disk filesystem label missing on superblock or wrong for /dev/sda1' "${STALE_SYMLINK_LABEL_OUTPUT_FILE}" && \
   grep -q 'symlink_before=present target=/dev/sda1' "${STALE_SYMLINK_LABEL_OUTPUT_FILE}" && \
   grep -q 'blkid_output=.*LABEL=stale' "${STALE_SYMLINK_LABEL_OUTPUT_FILE}"; then
  test_pass "present-symlink wrong-label diagnostic names root device, symlink state, and blkid output"
else
  test_fail "present-symlink wrong-label diagnostic must name root device, symlink state, and blkid output"
  cat "${STALE_SYMLINK_LABEL_OUTPUT_FILE}" >&2
fi
if assert_in_order "${STALE_SYMLINK_LABEL_LOG_FILE}" "ssh:root-label-probe" "ssh:root-label-blkid"; then
  test_pass "present-symlink wrong-label preflight probes symlink then blkid"
else
  test_fail "present-symlink wrong-label preflight must probe symlink then blkid"
  cat "${STALE_SYMLINK_LABEL_LOG_FILE}" >&2
fi
if ! grep -qE '^(nix-copy|ssh:switch)$' "${STALE_SYMLINK_LABEL_LOG_FILE}"; then
  test_pass "present-symlink wrong-label preflight prevents nix copy and switch"
else
  test_fail "present-symlink wrong-label preflight must prevent nix copy and switch"
  cat "${STALE_SYMLINK_LABEL_LOG_FILE}" >&2
fi

test_start "4.2s" "root label preflight fails closed when udev retrigger does not recreate the symlink"
UDEV_STILL_BROKEN_ARTIFACTS="$(
  STUB_ROOT_LABEL_PRESENT_BEFORE=0 \
  STUB_ROOT_LABEL_PRESENT_AFTER=0 \
  STUB_BLKID_LABEL=nixos \
    run_closure_fixture root-label-udev-still-broken '-target=module.testapp_dev' '/nix/store/test-closure'
)"
UDEV_STILL_BROKEN_STATUS="$(artifact_status "${UDEV_STILL_BROKEN_ARTIFACTS}")"
UDEV_STILL_BROKEN_OUTPUT_FILE="$(artifact_output_file "${UDEV_STILL_BROKEN_ARTIFACTS}")"
UDEV_STILL_BROKEN_LOG_FILE="$(artifact_log_file "${UDEV_STILL_BROKEN_ARTIFACTS}")"
if [[ "${UDEV_STILL_BROKEN_STATUS}" != "0" ]]; then
  test_pass "unrepaired udev state exits non-zero"
else
  test_fail "unrepaired udev state exits non-zero"
  cat "${UDEV_STILL_BROKEN_OUTPUT_FILE}" >&2
fi
if grep -q 'udev retrigger did not recreate /dev/disk/by-label/nixos for /dev/sda1' "${UDEV_STILL_BROKEN_OUTPUT_FILE}" && \
   grep -q 'symlink_before=absent' "${UDEV_STILL_BROKEN_OUTPUT_FILE}" && \
   grep -q 'symlink_after=absent' "${UDEV_STILL_BROKEN_OUTPUT_FILE}" && \
   grep -q 'blkid_output=.*LABEL=nixos' "${UDEV_STILL_BROKEN_OUTPUT_FILE}"; then
  test_pass "unrepaired-udev diagnostic names root device, before/after symlink state, and blkid LABEL=nixos"
else
  test_fail "unrepaired-udev diagnostic must name root device, before/after symlink state, and blkid LABEL=nixos"
  cat "${UDEV_STILL_BROKEN_OUTPUT_FILE}" >&2
fi
if assert_in_order "${UDEV_STILL_BROKEN_LOG_FILE}" \
  "ssh:root-label-probe" \
  "ssh:root-label-blkid" \
  "ssh:root-label-udevadm" \
  "ssh:root-label-reprobe"; then
  test_pass "unrepaired-udev preflight probes, verifies LABEL=nixos, retriggers, then re-probes"
else
  test_fail "unrepaired-udev preflight sequence must include probe, blkid, trigger, and re-probe"
  cat "${UDEV_STILL_BROKEN_LOG_FILE}" >&2
fi
if ! grep -qE '^(nix-copy|ssh:switch|ssh:reset-failed|ssh:reboot)$' "${UDEV_STILL_BROKEN_LOG_FILE}"; then
  test_pass "unrepaired-udev preflight prevents nix copy, switch, reset, and reboot"
else
  test_fail "unrepaired-udev preflight must prevent all downstream closure actions"
  cat "${UDEV_STILL_BROKEN_LOG_FILE}" >&2
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

# Regression (#709): when the switch NEVER reaches a terminal state and the
# poll budget expires, the observer must emit an explicit "still running"
# verdict — NOT false-positive on the running-default Result=success and NOT
# die with a bogus "Activated closure mismatch". This is the exact 2026-07-24
# incident (job 146319 died 44m before its wedged switch actually finished).
#
# The fixture models a wedged switch: the unit stays in a non-terminal state
# for every probe, and /run/current-system still points at the OLD closure
# (STUB_SYSTEM_AFTER == STUB_SYSTEM_BEFORE). A budget of 30s (10 probes) keeps
# the test fast. Mutation check: deleting the switch_terminal budget-expiry
# guard makes this case fall through to the Result=success check, which then
# logs "completed successfully" and dies on "Activated closure mismatch" —
# both of which the assertions below reject.
test_start "4.2k" "poll-budget expiry on a still-running switch is a loud explicit verdict, not a false success"
STILL_RUNNING_TRIPLE="ActiveState=activating\nSubState=start\nResult=success"
BUDGET_ARTIFACTS="$(
  CLOSURE_SWITCH_MAX=30 \
  STUB_SWITCH_SHOW_SEQUENCE="${STILL_RUNNING_TRIPLE}" \
  STUB_SYSTEM_BEFORE="/nix/store/system-old" \
  STUB_SYSTEM_AFTER="/nix/store/system-old" \
    run_closure_fixture budget-expiry '-target=module.testapp_dev' '/nix/store/test-closure'
)"
BUDGET_STATUS="$(artifact_status "${BUDGET_ARTIFACTS}")"
BUDGET_OUTPUT_FILE="$(artifact_output_file "${BUDGET_ARTIFACTS}")"
if [[ "${BUDGET_STATUS}" != "0" ]]; then
  test_pass "budget-expiry on a still-running switch exits non-zero"
else
  test_fail "budget-expiry on a still-running switch exits non-zero"
  cat "${BUDGET_OUTPUT_FILE}" >&2
fi
if grep -q 'still running on 10.0.0.41 after 30s' "${BUDGET_OUTPUT_FILE}"; then
  test_pass "budget-expiry reports the explicit still-running verdict with the deadline"
else
  test_fail "budget-expiry reports the explicit still-running verdict with the deadline"
  cat "${BUDGET_OUTPUT_FILE}" >&2
fi
if grep -q 'completed successfully' "${BUDGET_OUTPUT_FILE}"; then
  test_fail "budget-expiry must NOT false-positive as a completed switch (#709 regression)"
  cat "${BUDGET_OUTPUT_FILE}" >&2
else
  test_pass "budget-expiry does not misreport the still-running switch as completed"
fi
if grep -q 'Activated closure mismatch' "${BUDGET_OUTPUT_FILE}"; then
  test_fail "budget-expiry must NOT die on a bogus closure mismatch (#709 regression)"
  cat "${BUDGET_OUTPUT_FILE}" >&2
else
  test_pass "budget-expiry does not degrade into a bogus closure-mismatch verdict"
fi

# #710 (behavioral): the keepalives must actually reach the ssh command line,
# not merely appear somewhere in the source. The ssh shim logs the full argv
# of the wait_for_ssh probe as `ssh:wait-argv:`; assert the live invocation
# from the changed-closure run (4.2) carries ServerAliveInterval=5 and
# ServerAliveCountMax=3. This proves CONVERGE_SSH_OPTS is passed to ssh with
# the intended values — a comment-out or wrong value would fail here.
test_start "4.2l" "SSH keepalives (#710) are passed to the live ssh invocation"
if grep -q 'ssh:wait-argv:.*ServerAliveInterval=5 .*ServerAliveCountMax=3' "${CHANGED_LOG_FILE}"; then
  test_pass "wait_for_ssh ssh argv carries ServerAliveInterval=5 and ServerAliveCountMax=3"
else
  test_fail "wait_for_ssh ssh argv must carry ServerAliveInterval=5 and ServerAliveCountMax=3"
  grep 'ssh:wait-argv:' "${CHANGED_LOG_FILE}" >&2 || true
fi

# Regression (#711 retry safety, review P1): a retried control-plane job can
# land here while the PREVIOUS attempt's detached switch is still activating.
# The pre-start cleanup must NOT stop a running unit (that would SIGTERM
# switch-to-configuration mid-activation); it must fail loudly and leave the
# in-flight switch alone. The shim reports the existing unit as still running.
test_start "4.2m" "an already-running switch is not stomped on retry; the job fails loudly"
STOMP_ARTIFACTS="$(
  STUB_EXISTING_SUBSTATE="running" \
    run_closure_fixture stomp-guard '-target=module.testapp_dev' '/nix/store/test-closure'
)"
STOMP_STATUS="$(artifact_status "${STOMP_ARTIFACTS}")"
STOMP_OUTPUT_FILE="$(artifact_output_file "${STOMP_ARTIFACTS}")"
STOMP_LOG_FILE="$(artifact_log_file "${STOMP_ARTIFACTS}")"
if [[ "${STOMP_STATUS}" != "0" ]]; then
  test_pass "already-running switch causes a non-zero exit"
else
  test_fail "already-running switch causes a non-zero exit"
  cat "${STOMP_OUTPUT_FILE}" >&2
fi
if grep -q 'already running on 10.0.0.41.*refusing to stop it mid-activation' "${STOMP_OUTPUT_FILE}"; then
  test_pass "the refusal names the running unit and the reason"
else
  test_fail "the refusal names the running unit and the reason"
  cat "${STOMP_OUTPUT_FILE}" >&2
fi
# The guard must fire BEFORE any stop/reset/systemd-run — the running switch
# must be left untouched.
if ! grep -q '^ssh:switch$' "${STOMP_LOG_FILE}" && ! grep -q '^ssh:reset-failed$' "${STOMP_LOG_FILE}"; then
  test_pass "no stop/reset-failed or new switch is issued against the running unit"
else
  test_fail "the running switch must not be stopped, reset, or restarted"
  cat "${STOMP_LOG_FILE}" >&2
fi

# Regression (#709 review, P2): the stomp guard must FAIL CLOSED when it cannot
# read the unit state. An absent unit returns a concrete "dead"; an empty probe
# result therefore signals a probe/transport failure, not "no unit running".
# Proceeding to `systemctl stop` on an indeterminate state violates the
# FAIL-not-SKIP doctrine. STUB_EXISTING_SUBSTATE="" models the failed probe.
test_start "4.2n" "stomp guard fails closed when the SubState probe returns empty"
EMPTYPROBE_ARTIFACTS="$(
  STUB_EXISTING_SUBSTATE="" \
    run_closure_fixture empty-probe '-target=module.testapp_dev' '/nix/store/test-closure'
)"
EMPTYPROBE_STATUS="$(artifact_status "${EMPTYPROBE_ARTIFACTS}")"
EMPTYPROBE_OUTPUT_FILE="$(artifact_output_file "${EMPTYPROBE_ARTIFACTS}")"
EMPTYPROBE_LOG_FILE="$(artifact_log_file "${EMPTYPROBE_ARTIFACTS}")"
if [[ "${EMPTYPROBE_STATUS}" != "0" ]]; then
  test_pass "unreadable SubState probe causes a non-zero exit"
else
  test_fail "unreadable SubState probe causes a non-zero exit"
  cat "${EMPTYPROBE_OUTPUT_FILE}" >&2
fi
if grep -q 'empty probe result.*refusing to proceed' "${EMPTYPROBE_OUTPUT_FILE}"; then
  test_pass "the refusal names the indeterminate probe and fails closed"
else
  test_fail "the refusal names the indeterminate probe and fails closed"
  cat "${EMPTYPROBE_OUTPUT_FILE}" >&2
fi
if ! grep -q '^ssh:reset-failed$' "${EMPTYPROBE_LOG_FILE}" && ! grep -q '^ssh:switch$' "${EMPTYPROBE_LOG_FILE}"; then
  test_pass "no stop/reset-failed or switch is issued on an indeterminate probe"
else
  test_fail "must not stop/reset or switch when the state is indeterminate"
  cat "${EMPTYPROBE_LOG_FILE}" >&2
fi

# Regression (#709 review, P3): pin the WALL-CLOCK mechanism, not just the
# verdict. If the deadline honors real elapsed time (date +%s), a large modeled
# per-tick step exhausts the budget in few iterations; the reverted
# per-iteration counter (switch_poll += 3) would ignore the clock and run
# switch_max/3 (=10) probes regardless. Asserting a small probe count fails on
# that counter revert. STUB_DATE_STEP=10 with a 30s budget → ~2 iterations.
test_start "4.2o" "the observation budget is wall-clock, not a fixed iteration count"
WALLCLOCK_ARTIFACTS="$(
  CLOSURE_SWITCH_MAX=30 \
  STUB_DATE_STEP=10 \
  STUB_SWITCH_SHOW_SEQUENCE="${STILL_RUNNING_TRIPLE}" \
  STUB_SYSTEM_BEFORE="/nix/store/system-old" \
  STUB_SYSTEM_AFTER="/nix/store/system-old" \
    run_closure_fixture wallclock '-target=module.testapp_dev' '/nix/store/test-closure'
)"
WALLCLOCK_STATUS="$(artifact_status "${WALLCLOCK_ARTIFACTS}")"
WALLCLOCK_OUTPUT_FILE="$(artifact_output_file "${WALLCLOCK_ARTIFACTS}")"
WALLCLOCK_LOG_FILE="$(artifact_log_file "${WALLCLOCK_ARTIFACTS}")"
if grep -q 'still running on 10.0.0.41 after 30s' "${WALLCLOCK_OUTPUT_FILE}"; then
  test_pass "wall-clock budget still emits the explicit still-running verdict"
else
  test_fail "wall-clock budget still emits the explicit still-running verdict"
  cat "${WALLCLOCK_OUTPUT_FILE}" >&2
fi
WALLCLOCK_SHOWS="$(grep -c '^ssh:systemctl-show:' "${WALLCLOCK_LOG_FILE}" || true)"
if [[ "${WALLCLOCK_SHOWS}" -le 4 ]]; then
  test_pass "budget honored wall-clock: ${WALLCLOCK_SHOWS} probes (a fixed-count loop would run ~10)"
else
  test_fail "budget ran ${WALLCLOCK_SHOWS} probes — the loop is ignoring the wall clock (reverted to a counter?)"
  cat "${WALLCLOCK_LOG_FILE}" >&2
fi

runner_summary
