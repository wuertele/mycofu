#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

capture_probe_cmd() {
  local cmd_file="$1"

  (
    set -euo pipefail

    log() { :; }
    die() { exit 0; }
    ssh() {
      printf '%s' "${*: -1}" > "${cmd_file}"
      exit 99
    }

    source "${REPO_ROOT}/framework/scripts/converge-lib.sh"
    converge_repair_root_disk_labels "probe-capture.invalid" || true
  )

  # Guard: the capture relies on the probe being the FIRST ssh
  # inside converge_repair_root_disk_labels. If a future edit adds a
  # preliminary ssh (e.g. a version probe), this file would contain
  # the wrong command text and the local mocks would exercise the
  # wrong script. Fail loudly here instead of silently passing later.
  if ! grep -q '^raw_root_source=\$(findmnt -n -o SOURCE /' "${cmd_file}"; then
    printf 'FATAL: captured ssh command does not look like the root-label probe_cmd — a preliminary ssh was likely inserted; update capture_probe_cmd.\n' >&2
    printf '%s\n' 'Captured content follows:' '---' >&2
    cat "${cmd_file}" >&2
    printf '%s\n' '---' >&2
    exit 1
  fi
}

setup_mocks() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'findmnt:%s\n' "$*" >> "${STUB_LOG_FILE}"

case "$*" in
  "-n -o SOURCE /")
    printf '%s\n' "${STUB_ROOT_SOURCE:-overlay}"
    ;;
  "-n -o SOURCE --nofsroot /mnt-real-root")
    printf '%s\n' "/dev/disk/by-label/nixos"
    ;;
  "-n -o SOURCE --nofsroot /mnt-real-root-rw")
    printf '%s\n' "/dev/disk/by-label/nixos"
    ;;
  "-n -o MAJ:MIN --nofsroot /"|"-n -o MAJ:MIN --nofsroot /mnt-real-root"|"-n -o MAJ:MIN --nofsroot /mnt-real-root-rw")
    case "${STUB_MAJMIN_MODE:-ok}" in
      fail)
        printf '%s\n' "mock findmnt MAJ:MIN failure" >&2
        exit 1
        ;;
      empty)
        exit 0
        ;;
      *)
        # Mirrors real findmnt right-aligned MAJ:MIN column padding observed on
        # cicd 2026-07-27: findmnt emits "  8:1  \n" for this single-row probe.
        printf '  8:1  \n'
        ;;
    esac
    ;;
  *)
    printf 'unexpected findmnt args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "${shim_dir}/findmnt"

  cat > "${shim_dir}/mountpoint" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'mountpoint:%s\n' "$*" >> "${STUB_LOG_FILE}"

case "$*" in
  "-q /mnt-real-root-rw")
    exit 1
    ;;
  "-q /mnt-real-root")
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
  chmod +x "${shim_dir}/mountpoint"

  cat > "${shim_dir}/readlink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'readlink:%s\n' "$*" >> "${STUB_LOG_FILE}"

case "$*" in
  "-f /dev/block/8:1")
    case "${STUB_BLOCK_READLINK_MODE:-ok}" in
      empty)
        exit 0
        ;;
      fail)
        printf '%s\n' "mock /dev/block/8:1 failure" >&2
        exit 1
        ;;
      *)
        printf '%s\n' "/dev/sda1"
        ;;
    esac
    ;;
  "-f /dev/disk/by-label/nixos")
    if [[ -f "${STUB_STATE_DIR}/label-present" ]]; then
      printf '%s\n' "/dev/sda1"
    else
      printf '%s\n' "/dev/disk/by-label/nixos"
    fi
    ;;
  *)
    printf 'unexpected readlink args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "${shim_dir}/readlink"

  cat > "${shim_dir}/blkid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'blkid:%s\n' "$*" >> "${STUB_LOG_FILE}"

case "$*" in
  "-p -o export /dev/sda1")
    case "${STUB_BLKID_MODE:-healthy}" in
      missing-label)
        printf '%s\n' "UUID=00000000-0000-0000-0000-000000000777"
        printf '%s\n' "TYPE=ext4"
        ;;
      fail)
        printf '%s\n' "mock blkid failure" >&2
        exit 2
        ;;
      *)
        printf '%s\n' "DEVNAME=/dev/sda1"
        printf '%s\n' "LABEL=nixos"
        printf '%s\n' "UUID=00000000-0000-0000-0000-000000000777"
        printf '%s\n' "TYPE=ext4"
        ;;
    esac
    ;;
  *)
    printf 'mock blkid: no such device for args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "${shim_dir}/blkid"

  cat > "${shim_dir}/udevadm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'udevadm:%s\n' "$*" >> "${STUB_LOG_FILE}"

case "$*" in
  "trigger --settle --action=change /dev/sda1")
    printf '%s\n' "1" > "${STUB_STATE_DIR}/label-present"
    exit 0
    ;;
  *)
    printf 'unexpected udevadm args: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "${shim_dir}/udevadm"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"

case "${remote_cmd}" in
  *"findmnt -n -o SOURCE /"*)
    printf '%s\n' "ssh:probe" >> "${STUB_LOG_FILE}"
    ;;
  *"blkid -p -o export"*)
    printf '%s\n' "ssh:blkid" >> "${STUB_LOG_FILE}"
    ;;
  *"udevadm trigger --settle --action=change"*)
    printf '%s\n' "ssh:udevadm" >> "${STUB_LOG_FILE}"
    ;;
  *)
    printf 'unexpected ssh remote command: %s\n' "${remote_cmd}" >&2
    exit 2
    ;;
esac

test() {
  if [[ "$#" -eq 2 && "$1" == "-b" ]]; then
    [[ "$2" == "/dev/sda1" ]]
    return
  fi
  # Symmetric intercept with `[` so a future refactor from `[ -L ... ]` to
  # `test -L ...` in probe_cmd still models the udev-label state transition.
  if [[ "$#" -eq 2 && "$1" == "-L" && "$2" == "/dev/disk/by-label/nixos" ]]; then
    [[ -f "${STUB_STATE_DIR}/label-present" ]]
    return
  fi
  builtin test "$@"
}

[() {
  if [[ "$#" -eq 3 && "$1" == "-L" && "$2" == "/dev/disk/by-label/nixos" && "$3" == "]" ]]; then
    [[ -f "${STUB_STATE_DIR}/label-present" ]]
    return
  fi
  # Note: "$@" already contains the closing ']' — every well-formed `[ ... ]`
  # includes it as the last positional argument. Do not add another `]` here.
  builtin [ "$@"
}

eval "${remote_cmd}"
EOF
  chmod +x "${shim_dir}/ssh"
}

new_fixture_paths() {
  local scenario="$1"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local state_dir="${TMP_DIR}/${scenario}-state"
  local output_file="${TMP_DIR}/${scenario}.out"
  local log_file="${TMP_DIR}/${scenario}.log"

  rm -rf "${shim_dir}" "${state_dir}" "${output_file}" "${log_file}"
  mkdir -p "${state_dir}"
  : > "${log_file}"
  setup_mocks "${shim_dir}"

  printf '%s\n%s\n%s\n%s\n' "${shim_dir}" "${state_dir}" "${output_file}" "${log_file}"
}

artifact_field() {
  printf '%s\n' "$1" | sed -n "${2}p"
}

run_probe_locally() {
  local scenario="$1"
  local probe_cmd="$2"
  local paths shim_dir state_dir output_file log_file status

  paths="$(new_fixture_paths "${scenario}")"
  shim_dir="$(artifact_field "${paths}" 1)"
  state_dir="$(artifact_field "${paths}" 2)"
  output_file="$(artifact_field "${paths}" 3)"
  log_file="$(artifact_field "${paths}" 4)"

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_LOG_FILE="${log_file}"
    export STUB_STATE_DIR="${state_dir}"
    export STUB_ROOT_SOURCE="${STUB_ROOT_SOURCE:-}"
    export STUB_MAJMIN_MODE="${STUB_MAJMIN_MODE:-}"
    export STUB_BLOCK_READLINK_MODE="${STUB_BLOCK_READLINK_MODE:-}"
    export STUB_BLKID_MODE="${STUB_BLKID_MODE:-}"
    "${shim_dir}/ssh" "root@probe.invalid" "${probe_cmd}"
  ) > "${output_file}" 2>&1
  status=$?
  set -e

  printf '%s\n%s\n%s\n' "${status}" "${output_file}" "${log_file}"
}

run_repair_function() {
  local scenario="$1"
  local paths shim_dir state_dir output_file log_file status

  paths="$(new_fixture_paths "${scenario}")"
  shim_dir="$(artifact_field "${paths}" 1)"
  state_dir="$(artifact_field "${paths}" 2)"
  output_file="$(artifact_field "${paths}" 3)"
  log_file="$(artifact_field "${paths}" 4)"

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_LOG_FILE="${log_file}"
    export STUB_STATE_DIR="${state_dir}"
    export STUB_ROOT_SOURCE="${STUB_ROOT_SOURCE:-}"
    export STUB_MAJMIN_MODE="${STUB_MAJMIN_MODE:-}"
    export STUB_BLOCK_READLINK_MODE="${STUB_BLOCK_READLINK_MODE:-}"
    export STUB_BLKID_MODE="${STUB_BLKID_MODE:-}"

    log() { printf '%s\n' "$*"; }
    die() { printf 'FATAL: %s\n' "$*"; exit 1; }

    source "${REPO_ROOT}/framework/scripts/converge-lib.sh"
    converge_repair_root_disk_labels "root-label-fixture.invalid"
  ) > "${output_file}" 2>&1
  status=$?
  set -e

  printf '%s\n%s\n%s\n' "${status}" "${output_file}" "${log_file}"
}

artifact_status() {
  artifact_field "$1" 1
}

artifact_output_file() {
  artifact_field "$1" 2
}

artifact_log_file() {
  artifact_field "$1" 3
}

PROBE_CMD_FILE="${TMP_DIR}/probe-command.sh"
capture_probe_cmd "${PROBE_CMD_FILE}"
PROBE_CMD="$(cat "${PROBE_CMD_FILE}")"

test_start "777a" "probe resolves overlay real root by MAJ:MIN while by-label symlink is absent"
PROBE_ARTIFACTS="$(run_probe_locally overlay-probe "${PROBE_CMD}")"
PROBE_STATUS="$(artifact_status "${PROBE_ARTIFACTS}")"
PROBE_OUTPUT_FILE="$(artifact_output_file "${PROBE_ARTIFACTS}")"
PROBE_LOG_FILE="$(artifact_log_file "${PROBE_ARTIFACTS}")"
if [[ "${PROBE_STATUS}" == "0" ]] && \
   grep -qx 'probe_status=ok' "${PROBE_OUTPUT_FILE}" && \
   grep -qx 'root_dev=/dev/sda1' "${PROBE_OUTPUT_FILE}" && \
   ! grep -qx 'root_dev=/dev/disk/by-label/nixos' "${PROBE_OUTPUT_FILE}"; then
  test_pass "local probe returns ok with root_dev=/dev/sda1"
else
  test_fail "local probe must identify /dev/sda1, not /dev/disk/by-label/nixos"
  cat "${PROBE_OUTPUT_FILE}" >&2
fi
if grep -qx 'findmnt:-n -o MAJ:MIN --nofsroot /mnt-real-root' "${PROBE_LOG_FILE}" && \
   ! grep -qx 'findmnt:-n -o SOURCE --nofsroot /mnt-real-root' "${PROBE_LOG_FILE}" && \
   ! grep -qx 'readlink:-f /dev/disk/by-label/nixos' "${PROBE_LOG_FILE}"; then
  test_pass "overlay probe uses MAJ:MIN and never consumes the by-label trap"
else
  test_fail "overlay probe must avoid SOURCE/readlink by-label as a device input"
  cat "${PROBE_LOG_FILE}" >&2
fi

test_start "777b" "probe resolves direct root by MAJ:MIN even when SOURCE is by-label"
DIRECT_PROBE_ARTIFACTS="$(STUB_ROOT_SOURCE=/dev/disk/by-label/nixos run_probe_locally direct-probe "${PROBE_CMD}")"
DIRECT_PROBE_STATUS="$(artifact_status "${DIRECT_PROBE_ARTIFACTS}")"
DIRECT_PROBE_OUTPUT_FILE="$(artifact_output_file "${DIRECT_PROBE_ARTIFACTS}")"
DIRECT_PROBE_LOG_FILE="$(artifact_log_file "${DIRECT_PROBE_ARTIFACTS}")"
if [[ "${DIRECT_PROBE_STATUS}" == "0" ]] && \
   grep -qx 'probe_status=ok' "${DIRECT_PROBE_OUTPUT_FILE}" && \
   grep -qx 'real_root=/' "${DIRECT_PROBE_OUTPUT_FILE}" && \
   grep -qx 'root_dev=/dev/sda1' "${DIRECT_PROBE_OUTPUT_FILE}"; then
  test_pass "direct-root probe canonicalizes / through /dev/block/8:1"
else
  test_fail "direct-root probe must not trust by-label SOURCE"
  cat "${DIRECT_PROBE_OUTPUT_FILE}" >&2
fi
if grep -qx 'findmnt:-n -o MAJ:MIN --nofsroot /' "${DIRECT_PROBE_LOG_FILE}" && \
   ! grep -qx 'readlink:-f /dev/disk/by-label/nixos' "${DIRECT_PROBE_LOG_FILE}"; then
  test_pass "direct-root probe avoids by-label readlink while symlink is absent"
else
  test_fail "direct-root probe must avoid by-label readlink as a device input"
  cat "${DIRECT_PROBE_LOG_FILE}" >&2
fi

test_start "777c" "repair path reaches udev when symlink is absent but filesystem label is healthy"
REPAIR_ARTIFACTS="$(run_repair_function repairable)"
REPAIR_STATUS="$(artifact_status "${REPAIR_ARTIFACTS}")"
REPAIR_OUTPUT_FILE="$(artifact_output_file "${REPAIR_ARTIFACTS}")"
REPAIR_LOG_FILE="$(artifact_log_file "${REPAIR_ARTIFACTS}")"
if [[ "${REPAIR_STATUS}" == "0" ]] && \
   grep -q 'repaired /dev/disk/by-label/nixos on root-label-fixture.invalid by retriggering udev for /dev/sda1' "${REPAIR_OUTPUT_FILE}"; then
  test_pass "outer preflight repairs the absent symlink and returns 0"
else
  test_fail "outer preflight must repair the absent symlink and return 0"
  cat "${REPAIR_OUTPUT_FILE}" >&2
fi
if grep -qx 'udevadm:trigger --settle --action=change /dev/sda1' "${REPAIR_LOG_FILE}" && \
   [[ "$(grep -c '^ssh:probe$' "${REPAIR_LOG_FILE}")" == "2" ]] && \
   grep -qx 'readlink:-f /dev/disk/by-label/nixos' "${REPAIR_LOG_FILE}"; then
  test_pass "udevadm is invoked for /dev/sda1 and the re-probe verifies the recreated symlink"
else
  test_fail "repair fixture must trigger udev for /dev/sda1 and verify the symlink on re-probe"
  cat "${REPAIR_LOG_FILE}" >&2
fi

test_start "777d" "probe failure reports cannot-probe-device, not filesystem label damage"
CANNOT_PROBE_ARTIFACTS="$(STUB_BLOCK_READLINK_MODE=empty run_repair_function cannot-probe)"
CANNOT_PROBE_STATUS="$(artifact_status "${CANNOT_PROBE_ARTIFACTS}")"
CANNOT_PROBE_OUTPUT_FILE="$(artifact_output_file "${CANNOT_PROBE_ARTIFACTS}")"
if [[ "${CANNOT_PROBE_STATUS}" != "0" ]] && \
   grep -q 'cannot-probe-device: could not identify the real root device' "${CANNOT_PROBE_OUTPUT_FILE}" && \
   grep -q 'stage=root-device-readlink' "${CANNOT_PROBE_OUTPUT_FILE}" && \
   grep -q 'real_root=/mnt-real-root' "${CANNOT_PROBE_OUTPUT_FILE}" && \
   grep -q 'root_majmin=8:1' "${CANNOT_PROBE_OUTPUT_FILE}" && \
   ! grep -q 'filesystem label missing' "${CANNOT_PROBE_OUTPUT_FILE}"; then
  test_pass "device-probe failure has the cannot-probe-device taxonomy with stage"
else
  test_fail "device-probe failure must not be reported as a filesystem label problem and must include probe stage"
  cat "${CANNOT_PROBE_OUTPUT_FILE}" >&2
fi

test_start "777e" "missing superblock label reports the label taxonomy, not probe failure"
MISSING_LABEL_ARTIFACTS="$(STUB_BLKID_MODE=missing-label run_repair_function missing-superblock-label)"
MISSING_LABEL_STATUS="$(artifact_status "${MISSING_LABEL_ARTIFACTS}")"
MISSING_LABEL_OUTPUT_FILE="$(artifact_output_file "${MISSING_LABEL_ARTIFACTS}")"
if [[ "${MISSING_LABEL_STATUS}" != "0" ]] && \
   grep -q 'on-disk filesystem label missing on superblock or wrong for /dev/sda1' "${MISSING_LABEL_OUTPUT_FILE}" && \
   grep -q 'blkid_output=.*UUID=00000000-0000-0000-0000-000000000777' "${MISSING_LABEL_OUTPUT_FILE}" && \
   ! grep -q 'cannot-probe-device' "${MISSING_LABEL_OUTPUT_FILE}"; then
  test_pass "superblock label absence has the filesystem-label taxonomy"
else
  test_fail "superblock label absence must not be reported as device-probe failure"
  cat "${MISSING_LABEL_OUTPUT_FILE}" >&2
fi

test_start "779a" "probe trims padded MAJ:MIN before resolving /dev/block"
PADDED_MAJMIN_ARTIFACTS="$(run_probe_locally padded-majmin "${PROBE_CMD}")"
PADDED_MAJMIN_STATUS="$(artifact_status "${PADDED_MAJMIN_ARTIFACTS}")"
PADDED_MAJMIN_OUTPUT_FILE="$(artifact_output_file "${PADDED_MAJMIN_ARTIFACTS}")"
PADDED_MAJMIN_LOG_FILE="$(artifact_log_file "${PADDED_MAJMIN_ARTIFACTS}")"
if [[ "${PADDED_MAJMIN_STATUS}" == "0" ]] && \
   grep -qx 'probe_status=ok' "${PADDED_MAJMIN_OUTPUT_FILE}" && \
   grep -qx 'root_majmin=8:1' "${PADDED_MAJMIN_OUTPUT_FILE}" && \
   grep -qx 'root_dev=/dev/sda1' "${PADDED_MAJMIN_OUTPUT_FILE}"; then
  test_pass "local probe prints trimmed root_majmin and resolves /dev/sda1"
else
  test_fail "local probe must print root_majmin=8:1 and root_dev=/dev/sda1"
  cat "${PADDED_MAJMIN_OUTPUT_FILE}" >&2
fi
if grep -qx 'readlink:-f /dev/block/8:1' "${PADDED_MAJMIN_LOG_FILE}" && \
   ! grep -q 'readlink:-f /dev/block/.*[[:space:]].*8:1' "${PADDED_MAJMIN_LOG_FILE}"; then
  test_pass "readlink receives whitespace-free /dev/block/8:1"
else
  test_fail "readlink must only be called with -f /dev/block/8:1"
  cat "${PADDED_MAJMIN_LOG_FILE}" >&2
fi

runner_summary
