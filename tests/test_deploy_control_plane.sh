#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

setup_fixture_repo() {
  local repo_dir="$1"
  local runner_disk_gb="$2"

  mkdir -p "${repo_dir}/framework/scripts" "${repo_dir}/site" "${repo_dir}/build"

  cp "${REPO_ROOT}/framework/scripts/deploy-control-plane.sh" \
    "${repo_dir}/framework/scripts/deploy-control-plane.sh"
  chmod +x "${repo_dir}/framework/scripts/deploy-control-plane.sh"

  cat > "${repo_dir}/framework/scripts/converge-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

closure=""
targets=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --closure)
      closure="$2"
      shift 2
      ;;
    --targets)
      targets="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf 'converge:%s:%s\n' "${targets}" "${closure}" >> "${STUB_LOG_FILE}"

target="${targets#-target=module.}"
if [[ "${STUB_FAIL_TARGET:-}" == "${target}" ]]; then
  exit "${STUB_FAIL_EXIT_CODE:-1}"
fi

if [[ "${STUB_SKIP_STATE_UPDATE:-0}" != "1" ]]; then
  printf '%s\n' "${closure}" > "${STUB_STATE_DIR}/live-${target}"
fi
EOF
  chmod +x "${repo_dir}/framework/scripts/converge-vm.sh"

  cat > "${repo_dir}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
  - name: pve02
    mgmt_ip: 10.0.0.2
vms:
  gitlab:
    vmid: 150
    ip: 10.0.0.10
    node: pve01
  cicd:
    vmid: 160
    ip: 10.0.0.20
    node: pve01
cicd:
EOF
  if [[ "${STUB_OMIT_RUNNER_DISK_GB:-0}" != "1" ]]; then
    printf '  runner_disk_gb: %s\n' "${runner_disk_gb}" >> "${repo_dir}/site/config.yaml"
  fi

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications: {}
EOF
}

setup_shims() {
  local shim_dir="$1"

  mkdir -p "${shim_dir}"

  cat > "${shim_dir}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=""
for arg in "$@"; do
  if [[ "${arg}" == root@* ]]; then
    target="${arg#root@}"
  fi
done

remote_cmd="${*: -1}"
printf 'ssh:%s:%s\n' "${target}" "${remote_cmd}" >> "${STUB_LOG_FILE}"

if [[ "${remote_cmd}" == "readlink -f /run/current-system" ]]; then
  case "${target}" in
    10.0.0.10)
      cat "${STUB_STATE_DIR}/live-gitlab"
      ;;
    10.0.0.20)
      cat "${STUB_STATE_DIR}/live-cicd"
      ;;
    *)
      exit 1
      ;;
  esac
  exit 0
fi

if [[ "${remote_cmd}" == "cat /proc/sys/kernel/random/boot_id" ]]; then
  case "${target}" in
    10.0.0.20)
      if [[ -f "${STUB_STATE_DIR}/boot-cicd" ]]; then
        cat "${STUB_STATE_DIR}/boot-cicd"
      else
        printf 'boot-before\n'
      fi
      ;;
    *)
      printf 'boot-static\n'
      ;;
  esac
  exit 0
fi

if [[ "${remote_cmd}" == "pvesh get /cluster/resources --type vm --output-format json" ]]; then
  if [[ "${STUB_CLUSTER_RESOURCES_FAIL:-0}" == "1" ]]; then
    exit 44
  fi
  cat <<JSON
[
  {"type":"qemu","vmid":150,"name":"gitlab","node":"pve01","status":"running"},
  {"type":"qemu","vmid":160,"name":"cicd","node":"${STUB_CICD_NODE:-pve01}","status":"running"}
]
JSON
  exit 0
fi

if [[ "${remote_cmd}" == *"qm config 160"* ]]; then
  printf '%s\n' "${STUB_CICD_DISK_SIZE:-256G}"
  exit 0
fi

if [[ "${remote_cmd}" == *"df -BG /nix"* ]]; then
  if [[ -f "${STUB_STATE_DIR}/guest-nix-cicd" ]]; then
    cat "${STUB_STATE_DIR}/guest-nix-cicd"
  else
    printf '%s\n' "${STUB_CICD_GUEST_NIX_SIZE_GB:-252}"
  fi
  exit 0
fi

if [[ "${remote_cmd}" == "qm resize 160 scsi0 256G" ]]; then
  printf 'resize:160:scsi0:256G:%s\n' "${target}" >> "${STUB_LOG_FILE}"
  exit 0
fi

if [[ "${remote_cmd}" == "reboot" ]]; then
  printf 'reboot:%s\n' "${target}" >> "${STUB_LOG_FILE}"
  if [[ "${target}" == "10.0.0.20" ]]; then
    if [[ "${STUB_REBOOT_CHANGES_BOOT:-1}" == "1" ]]; then
      printf 'boot-after\n' > "${STUB_STATE_DIR}/boot-cicd"
    fi
    printf '%s\n' "${STUB_CICD_GUEST_NIX_SIZE_AFTER_REBOOT:-252}" > "${STUB_STATE_DIR}/guest-nix-cicd"
  fi
  exit 0
fi

exit 1
EOF
  chmod +x "${shim_dir}/ssh"
}

run_fixture() {
  local scenario="$1"
  local env_name="$2"
  shift 2
  local runner_disk_gb="${STUB_RUNNER_DISK_GB:-256}"
  if [[ "${1:-}" == "--runner-disk-gb" ]]; then
    runner_disk_gb="$2"
    shift 2
  fi
  local repo_dir="${TMP_DIR}/${scenario}-repo"
  local shim_dir="${TMP_DIR}/${scenario}-shims"
  local state_dir="${TMP_DIR}/${scenario}-state"
  local output_file="${TMP_DIR}/${scenario}.out"
  local log_file="${TMP_DIR}/${scenario}.log"
  local gitlab_built="${state_dir}/gitlab-built"
  local cicd_built="${state_dir}/cicd-built"
  local gitlab_old="${state_dir}/gitlab-live-old"
  local cicd_old="${state_dir}/cicd-live-old"
  local gitlab_live_mode="${STUB_GITLAB_MODE:-match}"
  local cicd_live_mode="${STUB_CICD_MODE:-match}"
  local closure_artifact_mode="${STUB_CLOSURE_ARTIFACT_MODE:-valid}"

  setup_fixture_repo "${repo_dir}" "${runner_disk_gb}"
  setup_shims "${shim_dir}"
  mkdir -p "${state_dir}"
  : > "${log_file}"
  : > "${gitlab_built}"
  : > "${cicd_built}"
  : > "${gitlab_old}"
  : > "${cicd_old}"

  case "${gitlab_live_mode}" in
    match) printf '%s\n' "${gitlab_built}" > "${state_dir}/live-gitlab" ;;
    old) printf '%s\n' "${gitlab_old}" > "${state_dir}/live-gitlab" ;;
    *) return 1 ;;
  esac

  case "${cicd_live_mode}" in
    match) printf '%s\n' "${cicd_built}" > "${state_dir}/live-cicd" ;;
    old) printf '%s\n' "${cicd_old}" > "${state_dir}/live-cicd" ;;
    *) return 1 ;;
  esac

  case "${closure_artifact_mode}" in
    valid)
      cat > "${repo_dir}/build/closure-paths.json" <<EOF
{
  "gitlab": "${gitlab_built}",
  "cicd": "${cicd_built}"
}
EOF
      ;;
    missing)
      rm -f "${repo_dir}/build/closure-paths.json"
      ;;
    malformed)
      printf '{\n  "gitlab":\n' > "${repo_dir}/build/closure-paths.json"
      ;;
    *)
      return 1
      ;;
  esac

  set +e
  (
    export PATH="${shim_dir}:${PATH}"
    export STUB_LOG_FILE="${log_file}"
    export STUB_STATE_DIR="${state_dir}"
    export STUB_FAIL_TARGET="${STUB_FAIL_TARGET:-}"
    export STUB_FAIL_EXIT_CODE="${STUB_FAIL_EXIT_CODE:-1}"
    export STUB_SKIP_STATE_UPDATE="${STUB_SKIP_STATE_UPDATE:-0}"
    export STUB_CICD_DISK_SIZE="${STUB_CICD_DISK_SIZE:-256G}"
    export STUB_CICD_GUEST_NIX_SIZE_GB="${STUB_CICD_GUEST_NIX_SIZE_GB:-252}"
    export STUB_CICD_GUEST_NIX_SIZE_AFTER_REBOOT="${STUB_CICD_GUEST_NIX_SIZE_AFTER_REBOOT:-252}"
    export STUB_REBOOT_CHANGES_BOOT="${STUB_REBOOT_CHANGES_BOOT:-1}"
    export STUB_CICD_NODE="${STUB_CICD_NODE:-pve01}"
    export STUB_CLUSTER_RESOURCES_FAIL="${STUB_CLUSTER_RESOURCES_FAIL:-0}"
    export STUB_OMIT_RUNNER_DISK_GB="${STUB_OMIT_RUNNER_DISK_GB:-0}"
    export STUB_RUNNER_DISK_GB="${STUB_RUNNER_DISK_GB:-256}"
    export ROOT_DISK_REBOOT_TIMEOUT="${ROOT_DISK_REBOOT_TIMEOUT:-}"
    export ROOT_DISK_REBOOT_INTERVAL="${ROOT_DISK_REBOOT_INTERVAL:-}"
    cd "${repo_dir}"
    framework/scripts/deploy-control-plane.sh "${env_name}" "$@"
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\n%s\n%s\n%s\n%s\n' \
    "${status}" \
    "${output_file}" \
    "${log_file}" \
    "${gitlab_built}" \
    "${cicd_built}"
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

artifact_gitlab_built() {
  printf '%s\n' "$1" | sed -n '4p'
}

artifact_cicd_built() {
  printf '%s\n' "$1" | sed -n '5p'
}

test_start "2.3" "matching live closures skip converge-vm.sh and exit 0"
MATCH_ARTIFACTS="$(run_fixture match dev)"
MATCH_STATUS="$(artifact_status "${MATCH_ARTIFACTS}")"
MATCH_OUTPUT_FILE="$(artifact_output_file "${MATCH_ARTIFACTS}")"
MATCH_LOG_FILE="$(artifact_log_file "${MATCH_ARTIFACTS}")"
if [[ "${MATCH_STATUS}" == "0" ]]; then
  test_pass "matching closures exit 0"
else
  test_fail "matching closures exit 0"
  cat "${MATCH_OUTPUT_FILE}" >&2
fi
if grep -q 'gitlab: live closure matches built, skipping' "${MATCH_OUTPUT_FILE}" && \
   grep -q 'cicd: live closure matches built, skipping' "${MATCH_OUTPUT_FILE}" && \
   ! grep -q '^converge:' "${MATCH_LOG_FILE}"; then
  test_pass "matching closures do not invoke converge-vm.sh"
else
  test_fail "matching closures do not invoke converge-vm.sh"
  cat "${MATCH_OUTPUT_FILE}" >&2
  cat "${MATCH_LOG_FILE}" >&2
fi

test_start "2.3a" "dev mismatch invokes converge-vm.sh with the built closure and target"
DEV_MISMATCH_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  run_fixture dev-mismatch dev
)"
DEV_MISMATCH_STATUS="$(artifact_status "${DEV_MISMATCH_ARTIFACTS}")"
DEV_MISMATCH_OUTPUT_FILE="$(artifact_output_file "${DEV_MISMATCH_ARTIFACTS}")"
DEV_MISMATCH_LOG_FILE="$(artifact_log_file "${DEV_MISMATCH_ARTIFACTS}")"
DEV_MISMATCH_GITLAB_BUILT="$(artifact_gitlab_built "${DEV_MISMATCH_ARTIFACTS}")"
if [[ "${DEV_MISMATCH_STATUS}" == "0" ]]; then
  test_pass "dev mismatch exits 0 after converge succeeds"
else
  test_fail "dev mismatch exits 0 after converge succeeds"
  cat "${DEV_MISMATCH_OUTPUT_FILE}" >&2
fi
if grep -q "converge:-target=module.gitlab:${DEV_MISMATCH_GITLAB_BUILT}" "${DEV_MISMATCH_LOG_FILE}"; then
  test_pass "dev mismatch passes the expected --closure and --targets values"
else
  test_fail "dev mismatch passes the expected --closure and --targets values"
  cat "${DEV_MISMATCH_LOG_FILE}" >&2
fi

test_start "2.3b" "prod mismatch refuses without invoking converge-vm.sh"
PROD_MISMATCH_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  run_fixture prod-mismatch prod
)"
PROD_MISMATCH_STATUS="$(artifact_status "${PROD_MISMATCH_ARTIFACTS}")"
PROD_MISMATCH_OUTPUT_FILE="$(artifact_output_file "${PROD_MISMATCH_ARTIFACTS}")"
PROD_MISMATCH_LOG_FILE="$(artifact_log_file "${PROD_MISMATCH_ARTIFACTS}")"
if [[ "${PROD_MISMATCH_STATUS}" == "1" ]]; then
  test_pass "prod mismatch exits non-zero"
else
  test_fail "prod mismatch exits non-zero"
  cat "${PROD_MISMATCH_OUTPUT_FILE}" >&2
fi
if grep -q 'refusing: dev pipeline should have deployed first' "${PROD_MISMATCH_OUTPUT_FILE}" && \
   ! grep -q '^converge:' "${PROD_MISMATCH_LOG_FILE}"; then
  test_pass "prod mismatch refuses before converge-vm.sh runs"
else
  test_fail "prod mismatch refuses before converge-vm.sh runs"
  cat "${PROD_MISMATCH_OUTPUT_FILE}" >&2
  cat "${PROD_MISMATCH_LOG_FILE}" >&2
fi

test_start "2.3c" "gitlab converge failure stops before cicd is attempted"
GITLAB_FAIL_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  STUB_CICD_MODE=old \
  STUB_FAIL_TARGET=gitlab \
  run_fixture gitlab-fails dev
)"
GITLAB_FAIL_STATUS="$(artifact_status "${GITLAB_FAIL_ARTIFACTS}")"
GITLAB_FAIL_OUTPUT_FILE="$(artifact_output_file "${GITLAB_FAIL_ARTIFACTS}")"
GITLAB_FAIL_LOG_FILE="$(artifact_log_file "${GITLAB_FAIL_ARTIFACTS}")"
if [[ "${GITLAB_FAIL_STATUS}" == "1" ]]; then
  test_pass "gitlab converge failure exits non-zero"
else
  test_fail "gitlab converge failure exits non-zero"
  cat "${GITLAB_FAIL_OUTPUT_FILE}" >&2
fi
if grep -q '^converge:-target=module.gitlab:' "${GITLAB_FAIL_LOG_FILE}" && \
   ! grep -q '^converge:-target=module.cicd:' "${GITLAB_FAIL_LOG_FILE}"; then
  test_pass "cicd converge is not invoked after a gitlab failure"
else
  test_fail "cicd converge is not invoked after a gitlab failure"
  cat "${GITLAB_FAIL_LOG_FILE}" >&2
fi

test_start "2.3c1" "dev cicd deploy resizes an undersized root disk and reboots"
CICD_RESIZE_ARTIFACTS="$(
  STUB_CICD_DISK_SIZE=192G \
  run_fixture cicd-resize dev cicd
)"
CICD_RESIZE_STATUS="$(artifact_status "${CICD_RESIZE_ARTIFACTS}")"
CICD_RESIZE_OUTPUT_FILE="$(artifact_output_file "${CICD_RESIZE_ARTIFACTS}")"
CICD_RESIZE_LOG_FILE="$(artifact_log_file "${CICD_RESIZE_ARTIFACTS}")"
CICD_RESIZE_BUILT="$(artifact_cicd_built "${CICD_RESIZE_ARTIFACTS}")"
if [[ "${CICD_RESIZE_STATUS}" == "0" ]]; then
  test_pass "dev cicd root disk resize exits 0"
else
  test_fail "dev cicd root disk resize exits 0"
  cat "${CICD_RESIZE_OUTPUT_FILE}" >&2
fi
if grep -q 'cicd: root disk is 192G on pve01, resizing to 256G' "${CICD_RESIZE_OUTPUT_FILE}" && \
   grep -q '^resize:160:scsi0:256G:10.0.0.1' "${CICD_RESIZE_LOG_FILE}" && \
   grep -q '^reboot:10.0.0.20' "${CICD_RESIZE_LOG_FILE}" && \
   grep -q '^ssh:10.0.0.20:cat /proc/sys/kernel/random/boot_id' "${CICD_RESIZE_LOG_FILE}" && \
   grep -q 'cicd: guest /nix filesystem is 252G after root disk resize reboot' "${CICD_RESIZE_OUTPUT_FILE}" && \
   ! grep -q '^converge:-target=module.cicd:' "${CICD_RESIZE_LOG_FILE}"; then
  test_pass "dev cicd resize runs qm resize and proves the already-current VM rebooted"
else
  test_fail "dev cicd resize did not run and verify the expected direct reboot path"
  cat "${CICD_RESIZE_OUTPUT_FILE}" >&2
  cat "${CICD_RESIZE_LOG_FILE}" >&2
fi

test_start "2.3c1a" "dev cicd deploy reboots when disk is resized but guest /nix is still small"
CICD_GROWFS_RETRY_ARTIFACTS="$(
  STUB_CICD_DISK_SIZE=256G \
  STUB_CICD_GUEST_NIX_SIZE_GB=190 \
  run_fixture cicd-growfs-retry dev cicd
)"
CICD_GROWFS_RETRY_STATUS="$(artifact_status "${CICD_GROWFS_RETRY_ARTIFACTS}")"
CICD_GROWFS_RETRY_OUTPUT_FILE="$(artifact_output_file "${CICD_GROWFS_RETRY_ARTIFACTS}")"
CICD_GROWFS_RETRY_LOG_FILE="$(artifact_log_file "${CICD_GROWFS_RETRY_ARTIFACTS}")"
if [[ "${CICD_GROWFS_RETRY_STATUS}" == "0" ]]; then
  test_pass "dev cicd growfs retry exits 0"
else
  test_fail "dev cicd growfs retry exits 0"
  cat "${CICD_GROWFS_RETRY_OUTPUT_FILE}" >&2
fi
if grep -q 'guest /nix filesystem is 190G; deploy will reboot so growfs-root can expand it' "${CICD_GROWFS_RETRY_OUTPUT_FILE}" && \
   ! grep -q '^resize:' "${CICD_GROWFS_RETRY_LOG_FILE}" && \
   grep -q '^reboot:10.0.0.20' "${CICD_GROWFS_RETRY_LOG_FILE}" && \
   grep -q 'cicd: guest /nix filesystem is 252G after root disk resize reboot' "${CICD_GROWFS_RETRY_OUTPUT_FILE}"; then
  test_pass "dev cicd growfs retry reboots and verifies guest /nix"
else
  test_fail "dev cicd growfs retry did not reboot and verify guest /nix"
  cat "${CICD_GROWFS_RETRY_OUTPUT_FILE}" >&2
  cat "${CICD_GROWFS_RETRY_LOG_FILE}" >&2
fi

test_start "2.3c1b" "dev cicd resize fails if reboot does not produce a new boot ID"
CICD_REBOOT_STALE_ARTIFACTS="$(
  STUB_CICD_DISK_SIZE=192G \
  STUB_REBOOT_CHANGES_BOOT=0 \
  ROOT_DISK_REBOOT_TIMEOUT=1 \
  ROOT_DISK_REBOOT_INTERVAL=1 \
  run_fixture cicd-reboot-stale dev cicd
)"
CICD_REBOOT_STALE_STATUS="$(artifact_status "${CICD_REBOOT_STALE_ARTIFACTS}")"
CICD_REBOOT_STALE_OUTPUT_FILE="$(artifact_output_file "${CICD_REBOOT_STALE_ARTIFACTS}")"
CICD_REBOOT_STALE_LOG_FILE="$(artifact_log_file "${CICD_REBOOT_STALE_ARTIFACTS}")"
if [[ "${CICD_REBOOT_STALE_STATUS}" == "1" ]]; then
  test_pass "dev cicd stale reboot exits non-zero"
else
  test_fail "dev cicd stale reboot exits non-zero"
  cat "${CICD_REBOOT_STALE_OUTPUT_FILE}" >&2
fi
if grep -q '^reboot:10.0.0.20' "${CICD_REBOOT_STALE_LOG_FILE}" && \
   grep -q 'failed to verify live closure after root disk resize reboot' "${CICD_REBOOT_STALE_OUTPUT_FILE}"; then
  test_pass "dev cicd stale reboot is rejected before filesystem verification"
else
  test_fail "dev cicd stale reboot was not rejected clearly"
  cat "${CICD_REBOOT_STALE_OUTPUT_FILE}" >&2
  cat "${CICD_REBOOT_STALE_LOG_FILE}" >&2
fi

test_start "2.3c1c" "dev cicd resize fails if guest /nix remains small after reboot"
CICD_GROWFS_STILL_SMALL_ARTIFACTS="$(
  STUB_CICD_DISK_SIZE=192G \
  STUB_CICD_GUEST_NIX_SIZE_AFTER_REBOOT=190 \
  run_fixture cicd-growfs-still-small dev cicd
)"
CICD_GROWFS_STILL_SMALL_STATUS="$(artifact_status "${CICD_GROWFS_STILL_SMALL_ARTIFACTS}")"
CICD_GROWFS_STILL_SMALL_OUTPUT_FILE="$(artifact_output_file "${CICD_GROWFS_STILL_SMALL_ARTIFACTS}")"
CICD_GROWFS_STILL_SMALL_LOG_FILE="$(artifact_log_file "${CICD_GROWFS_STILL_SMALL_ARTIFACTS}")"
if [[ "${CICD_GROWFS_STILL_SMALL_STATUS}" == "1" ]]; then
  test_pass "dev cicd post-reboot small /nix exits non-zero"
else
  test_fail "dev cicd post-reboot small /nix exits non-zero"
  cat "${CICD_GROWFS_STILL_SMALL_OUTPUT_FILE}" >&2
fi
if grep -q '^resize:160:scsi0:256G:10.0.0.1' "${CICD_GROWFS_STILL_SMALL_LOG_FILE}" && \
   grep -q '^reboot:10.0.0.20' "${CICD_GROWFS_STILL_SMALL_LOG_FILE}" && \
   grep -q 'guest /nix filesystem is still 190G after root disk resize reboot, below desired 256G' "${CICD_GROWFS_STILL_SMALL_OUTPUT_FILE}"; then
  test_pass "dev cicd post-reboot small /nix fails after resize and reboot proof"
else
  test_fail "dev cicd post-reboot small /nix was not rejected clearly"
  cat "${CICD_GROWFS_STILL_SMALL_OUTPUT_FILE}" >&2
  cat "${CICD_GROWFS_STILL_SMALL_LOG_FILE}" >&2
fi

test_start "2.3c1d" "dev cicd resize verifies guest /nix after converge when closure changes too"
CICD_RESIZE_CONVERGE_ARTIFACTS="$(
  STUB_CICD_MODE=old \
  STUB_CICD_DISK_SIZE=192G \
  run_fixture cicd-resize-converge dev cicd
)"
CICD_RESIZE_CONVERGE_STATUS="$(artifact_status "${CICD_RESIZE_CONVERGE_ARTIFACTS}")"
CICD_RESIZE_CONVERGE_OUTPUT_FILE="$(artifact_output_file "${CICD_RESIZE_CONVERGE_ARTIFACTS}")"
CICD_RESIZE_CONVERGE_LOG_FILE="$(artifact_log_file "${CICD_RESIZE_CONVERGE_ARTIFACTS}")"
CICD_RESIZE_CONVERGE_BUILT="$(artifact_cicd_built "${CICD_RESIZE_CONVERGE_ARTIFACTS}")"
if [[ "${CICD_RESIZE_CONVERGE_STATUS}" == "0" ]]; then
  test_pass "dev cicd resize plus converge exits 0"
else
  test_fail "dev cicd resize plus converge exits 0"
  cat "${CICD_RESIZE_CONVERGE_OUTPUT_FILE}" >&2
fi
if grep -q '^resize:160:scsi0:256G:10.0.0.1' "${CICD_RESIZE_CONVERGE_LOG_FILE}" && \
   grep -q "converge:-target=module.cicd:${CICD_RESIZE_CONVERGE_BUILT}" "${CICD_RESIZE_CONVERGE_LOG_FILE}" && \
   ! grep -q '^reboot:10.0.0.20' "${CICD_RESIZE_CONVERGE_LOG_FILE}" && \
   grep -q 'cicd: guest /nix filesystem is 252G after root disk resize reboot' "${CICD_RESIZE_CONVERGE_OUTPUT_FILE}"; then
  test_pass "dev cicd resize plus converge verifies guest /nix after converge"
else
  test_fail "dev cicd resize plus converge did not verify guest /nix after converge"
  cat "${CICD_RESIZE_CONVERGE_OUTPUT_FILE}" >&2
  cat "${CICD_RESIZE_CONVERGE_LOG_FILE}" >&2
fi

test_start "2.3c1e" "dev cicd resize plus converge fails if guest /nix remains small"
CICD_CONVERGE_GROWFS_SMALL_ARTIFACTS="$(
  STUB_CICD_MODE=old \
  STUB_CICD_DISK_SIZE=192G \
  STUB_CICD_GUEST_NIX_SIZE_GB=190 \
  run_fixture cicd-converge-growfs-small dev cicd
)"
CICD_CONVERGE_GROWFS_SMALL_STATUS="$(artifact_status "${CICD_CONVERGE_GROWFS_SMALL_ARTIFACTS}")"
CICD_CONVERGE_GROWFS_SMALL_OUTPUT_FILE="$(artifact_output_file "${CICD_CONVERGE_GROWFS_SMALL_ARTIFACTS}")"
CICD_CONVERGE_GROWFS_SMALL_LOG_FILE="$(artifact_log_file "${CICD_CONVERGE_GROWFS_SMALL_ARTIFACTS}")"
if [[ "${CICD_CONVERGE_GROWFS_SMALL_STATUS}" == "1" ]]; then
  test_pass "dev cicd resize plus converge small /nix exits non-zero"
else
  test_fail "dev cicd resize plus converge small /nix exits non-zero"
  cat "${CICD_CONVERGE_GROWFS_SMALL_OUTPUT_FILE}" >&2
fi
if grep -q '^resize:160:scsi0:256G:10.0.0.1' "${CICD_CONVERGE_GROWFS_SMALL_LOG_FILE}" && \
   grep -q '^converge:-target=module.cicd:' "${CICD_CONVERGE_GROWFS_SMALL_LOG_FILE}" && \
   grep -q 'guest /nix filesystem is still 190G after root disk resize reboot, below desired 256G' "${CICD_CONVERGE_GROWFS_SMALL_OUTPUT_FILE}"; then
  test_pass "dev cicd resize plus converge rejects small guest /nix"
else
  test_fail "dev cicd resize plus converge did not reject small guest /nix"
  cat "${CICD_CONVERGE_GROWFS_SMALL_OUTPUT_FILE}" >&2
  cat "${CICD_CONVERGE_GROWFS_SMALL_LOG_FILE}" >&2
fi

test_start "2.3c2" "cicd resize runs on the current hosting node from cluster resources"
CICD_HOSTING_ARTIFACTS="$(
  STUB_CICD_DISK_SIZE=192G \
  STUB_CICD_NODE=pve02 \
  run_fixture cicd-hosting-node dev cicd
)"
CICD_HOSTING_STATUS="$(artifact_status "${CICD_HOSTING_ARTIFACTS}")"
CICD_HOSTING_OUTPUT_FILE="$(artifact_output_file "${CICD_HOSTING_ARTIFACTS}")"
CICD_HOSTING_LOG_FILE="$(artifact_log_file "${CICD_HOSTING_ARTIFACTS}")"
if [[ "${CICD_HOSTING_STATUS}" == "0" ]]; then
  test_pass "dev cicd resize succeeds when cluster resources report pve02"
else
  test_fail "dev cicd resize succeeds when cluster resources report pve02"
  cat "${CICD_HOSTING_OUTPUT_FILE}" >&2
fi
if grep -q 'cicd: root disk is 192G on pve02, resizing to 256G' "${CICD_HOSTING_OUTPUT_FILE}" && \
   grep -q '^resize:160:scsi0:256G:10.0.0.2' "${CICD_HOSTING_LOG_FILE}" && \
   grep -q '^reboot:10.0.0.20' "${CICD_HOSTING_LOG_FILE}"; then
  test_pass "dev cicd resize targets the hosting node rather than the configured node"
else
  test_fail "dev cicd resize did not target the hosting node from cluster resources"
  cat "${CICD_HOSTING_OUTPUT_FILE}" >&2
  cat "${CICD_HOSTING_LOG_FILE}" >&2
fi

test_start "2.3c2a" "cicd root disk resize uses the compatibility default when config omits runner_disk_gb"
CICD_DEFAULT_DISK_ARTIFACTS="$(
  STUB_CICD_DISK_SIZE=192G \
  STUB_OMIT_RUNNER_DISK_GB=1 \
  run_fixture cicd-default-disk dev cicd
)"
CICD_DEFAULT_DISK_STATUS="$(artifact_status "${CICD_DEFAULT_DISK_ARTIFACTS}")"
CICD_DEFAULT_DISK_OUTPUT_FILE="$(artifact_output_file "${CICD_DEFAULT_DISK_ARTIFACTS}")"
CICD_DEFAULT_DISK_LOG_FILE="$(artifact_log_file "${CICD_DEFAULT_DISK_ARTIFACTS}")"
if [[ "${CICD_DEFAULT_DISK_STATUS}" == "0" ]]; then
  test_pass "missing runner_disk_gb uses the 256G compatibility default"
else
  test_fail "missing runner_disk_gb uses the 256G compatibility default"
  cat "${CICD_DEFAULT_DISK_OUTPUT_FILE}" >&2
fi
if grep -q 'cicd: root disk is 192G on pve01, resizing to 256G' "${CICD_DEFAULT_DISK_OUTPUT_FILE}" && \
   grep -q '^resize:160:scsi0:256G:10.0.0.1' "${CICD_DEFAULT_DISK_LOG_FILE}" && \
   grep -q '^reboot:10.0.0.20' "${CICD_DEFAULT_DISK_LOG_FILE}"; then
  test_pass "missing runner_disk_gb still drives the live resize path"
else
  test_fail "missing runner_disk_gb did not drive the expected resize path"
  cat "${CICD_DEFAULT_DISK_OUTPUT_FILE}" >&2
  cat "${CICD_DEFAULT_DISK_LOG_FILE}" >&2
fi

test_start "2.3c2b" "cicd root disk resize refuses runner_disk_gb below the floor"
CICD_LOW_DISK_CONFIG_ARTIFACTS="$(
  run_fixture cicd-low-disk-config dev --runner-disk-gb 32 cicd
)"
CICD_LOW_DISK_CONFIG_STATUS="$(artifact_status "${CICD_LOW_DISK_CONFIG_ARTIFACTS}")"
CICD_LOW_DISK_CONFIG_OUTPUT_FILE="$(artifact_output_file "${CICD_LOW_DISK_CONFIG_ARTIFACTS}")"
CICD_LOW_DISK_CONFIG_LOG_FILE="$(artifact_log_file "${CICD_LOW_DISK_CONFIG_ARTIFACTS}")"
if [[ "${CICD_LOW_DISK_CONFIG_STATUS}" == "1" ]]; then
  test_pass "low runner_disk_gb exits non-zero"
else
  test_fail "low runner_disk_gb exits non-zero"
  cat "${CICD_LOW_DISK_CONFIG_OUTPUT_FILE}" >&2
fi
if grep -q 'cicd.runner_disk_gb .* must be at least 256: 32' "${CICD_LOW_DISK_CONFIG_OUTPUT_FILE}" && \
   ! grep -q '^resize:' "${CICD_LOW_DISK_CONFIG_LOG_FILE}" && \
   ! grep -q '^reboot:' "${CICD_LOW_DISK_CONFIG_LOG_FILE}" && \
   ! grep -q '^converge:' "${CICD_LOW_DISK_CONFIG_LOG_FILE}"; then
  test_pass "low runner_disk_gb fails before mutation"
else
  test_fail "low runner_disk_gb did not fail before mutation"
  cat "${CICD_LOW_DISK_CONFIG_OUTPUT_FILE}" >&2
  cat "${CICD_LOW_DISK_CONFIG_LOG_FILE}" >&2
fi

test_start "2.3c2c" "storage-only cicd preparation does not require closure artifacts"
CICD_STORAGE_ONLY_ARTIFACTS="$(
  STUB_CLOSURE_ARTIFACT_MODE=missing \
  STUB_CICD_DISK_SIZE=192G \
  run_fixture cicd-storage-only dev --ensure-cicd-storage-only
)"
CICD_STORAGE_ONLY_STATUS="$(artifact_status "${CICD_STORAGE_ONLY_ARTIFACTS}")"
CICD_STORAGE_ONLY_OUTPUT_FILE="$(artifact_output_file "${CICD_STORAGE_ONLY_ARTIFACTS}")"
CICD_STORAGE_ONLY_LOG_FILE="$(artifact_log_file "${CICD_STORAGE_ONLY_ARTIFACTS}")"
if [[ "${CICD_STORAGE_ONLY_STATUS}" == "0" ]]; then
  test_pass "storage-only cicd preparation exits 0 without closure artifact"
else
  test_fail "storage-only cicd preparation exits 0 without closure artifact"
  cat "${CICD_STORAGE_ONLY_OUTPUT_FILE}" >&2
fi
if grep -q 'cicd: root disk is 192G on pve01, resizing to 256G' "${CICD_STORAGE_ONLY_OUTPUT_FILE}" && \
   grep -q 'cicd: storage-only root disk resize reboot completed' "${CICD_STORAGE_ONLY_OUTPUT_FILE}" && \
   grep -q '^resize:160:scsi0:256G:10.0.0.1' "${CICD_STORAGE_ONLY_LOG_FILE}" && \
   grep -q '^reboot:10.0.0.20' "${CICD_STORAGE_ONLY_LOG_FILE}" && \
   ! grep -q 'Closure artifact not found' "${CICD_STORAGE_ONLY_OUTPUT_FILE}" && \
   ! grep -q '^converge:' "${CICD_STORAGE_ONLY_LOG_FILE}"; then
  test_pass "storage-only cicd preparation resizes and reboots without closure deploy"
else
  test_fail "storage-only cicd preparation did not use the expected resize-only path"
  cat "${CICD_STORAGE_ONLY_OUTPUT_FILE}" >&2
  cat "${CICD_STORAGE_ONLY_LOG_FILE}" >&2
fi

test_start "2.3c2d" "prod storage-only cicd preparation refuses undersized runner"
PROD_STORAGE_ONLY_UNDERSIZED_ARTIFACTS="$(
  STUB_CLOSURE_ARTIFACT_MODE=missing \
  STUB_CICD_DISK_SIZE=192G \
  run_fixture prod-storage-only-undersized prod --ensure-cicd-storage-only
)"
PROD_STORAGE_ONLY_UNDERSIZED_STATUS="$(artifact_status "${PROD_STORAGE_ONLY_UNDERSIZED_ARTIFACTS}")"
PROD_STORAGE_ONLY_UNDERSIZED_OUTPUT_FILE="$(artifact_output_file "${PROD_STORAGE_ONLY_UNDERSIZED_ARTIFACTS}")"
PROD_STORAGE_ONLY_UNDERSIZED_LOG_FILE="$(artifact_log_file "${PROD_STORAGE_ONLY_UNDERSIZED_ARTIFACTS}")"
if [[ "${PROD_STORAGE_ONLY_UNDERSIZED_STATUS}" == "1" ]]; then
  test_pass "prod storage-only undersized cicd exits non-zero"
else
  test_fail "prod storage-only undersized cicd exits non-zero"
  cat "${PROD_STORAGE_ONLY_UNDERSIZED_OUTPUT_FILE}" >&2
fi
if grep -q 'cicd: refusing: root disk is 192G, below desired 256G' "${PROD_STORAGE_ONLY_UNDERSIZED_OUTPUT_FILE}" && \
   ! grep -q '^resize:' "${PROD_STORAGE_ONLY_UNDERSIZED_LOG_FILE}" && \
   ! grep -q '^reboot:' "${PROD_STORAGE_ONLY_UNDERSIZED_LOG_FILE}" && \
   ! grep -q '^converge:' "${PROD_STORAGE_ONLY_UNDERSIZED_LOG_FILE}"; then
  test_pass "prod storage-only undersized cicd fails before mutation"
else
  test_fail "prod storage-only undersized cicd did not fail before mutation"
  cat "${PROD_STORAGE_ONLY_UNDERSIZED_OUTPUT_FILE}" >&2
  cat "${PROD_STORAGE_ONLY_UNDERSIZED_LOG_FILE}" >&2
fi

test_start "2.3c3" "prod cicd deploy refuses an undersized root disk"
PROD_CICD_UNDERSIZED_ARTIFACTS="$(
  STUB_CICD_DISK_SIZE=192G \
  run_fixture prod-cicd-undersized prod cicd
)"
PROD_CICD_UNDERSIZED_STATUS="$(artifact_status "${PROD_CICD_UNDERSIZED_ARTIFACTS}")"
PROD_CICD_UNDERSIZED_OUTPUT_FILE="$(artifact_output_file "${PROD_CICD_UNDERSIZED_ARTIFACTS}")"
PROD_CICD_UNDERSIZED_LOG_FILE="$(artifact_log_file "${PROD_CICD_UNDERSIZED_ARTIFACTS}")"
if [[ "${PROD_CICD_UNDERSIZED_STATUS}" == "1" ]]; then
  test_pass "prod undersized cicd root disk exits non-zero"
else
  test_fail "prod undersized cicd root disk exits non-zero"
  cat "${PROD_CICD_UNDERSIZED_OUTPUT_FILE}" >&2
fi
if grep -q 'cicd: refusing: root disk is 192G, below desired 256G' "${PROD_CICD_UNDERSIZED_OUTPUT_FILE}" && \
   ! grep -q '^resize:' "${PROD_CICD_UNDERSIZED_LOG_FILE}" && \
   ! grep -q '^converge:' "${PROD_CICD_UNDERSIZED_LOG_FILE}"; then
  test_pass "prod undersized cicd root disk refuses before resize or converge"
else
  test_fail "prod undersized cicd root disk did not fail closed before mutation"
  cat "${PROD_CICD_UNDERSIZED_OUTPUT_FILE}" >&2
  cat "${PROD_CICD_UNDERSIZED_LOG_FILE}" >&2
fi

test_start "2.3c4" "prod cicd deploy refuses an undersized guest filesystem"
PROD_CICD_GUEST_UNDERSIZED_ARTIFACTS="$(
  STUB_CICD_DISK_SIZE=256G \
  STUB_CICD_GUEST_NIX_SIZE_GB=190 \
  run_fixture prod-cicd-guest-undersized prod cicd
)"
PROD_CICD_GUEST_UNDERSIZED_STATUS="$(artifact_status "${PROD_CICD_GUEST_UNDERSIZED_ARTIFACTS}")"
PROD_CICD_GUEST_UNDERSIZED_OUTPUT_FILE="$(artifact_output_file "${PROD_CICD_GUEST_UNDERSIZED_ARTIFACTS}")"
PROD_CICD_GUEST_UNDERSIZED_LOG_FILE="$(artifact_log_file "${PROD_CICD_GUEST_UNDERSIZED_ARTIFACTS}")"
if [[ "${PROD_CICD_GUEST_UNDERSIZED_STATUS}" == "1" ]]; then
  test_pass "prod undersized cicd guest filesystem exits non-zero"
else
  test_fail "prod undersized cicd guest filesystem exits non-zero"
  cat "${PROD_CICD_GUEST_UNDERSIZED_OUTPUT_FILE}" >&2
fi
if grep -q 'cicd: refusing: guest /nix filesystem is 190G, below desired 256G' "${PROD_CICD_GUEST_UNDERSIZED_OUTPUT_FILE}" && \
   ! grep -q '^resize:' "${PROD_CICD_GUEST_UNDERSIZED_LOG_FILE}" && \
   ! grep -q '^reboot:' "${PROD_CICD_GUEST_UNDERSIZED_LOG_FILE}" && \
   ! grep -q '^converge:' "${PROD_CICD_GUEST_UNDERSIZED_LOG_FILE}"; then
  test_pass "prod undersized cicd guest filesystem refuses before mutation"
else
  test_fail "prod undersized cicd guest filesystem did not fail closed before mutation"
  cat "${PROD_CICD_GUEST_UNDERSIZED_OUTPUT_FILE}" >&2
  cat "${PROD_CICD_GUEST_UNDERSIZED_LOG_FILE}" >&2
fi

test_start "2.3d" "final verification fails when live closure still mismatches after converge"
VERIFY_FAIL_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  STUB_SKIP_STATE_UPDATE=1 \
  run_fixture verify-fails dev
)"
VERIFY_FAIL_STATUS="$(artifact_status "${VERIFY_FAIL_ARTIFACTS}")"
VERIFY_FAIL_OUTPUT_FILE="$(artifact_output_file "${VERIFY_FAIL_ARTIFACTS}")"
if [[ "${VERIFY_FAIL_STATUS}" == "1" ]]; then
  test_pass "post-converge verification mismatch exits non-zero"
else
  test_fail "post-converge verification mismatch exits non-zero"
  cat "${VERIFY_FAIL_OUTPUT_FILE}" >&2
fi
if grep -q 'final verification mismatch' "${VERIFY_FAIL_OUTPUT_FILE}"; then
  test_pass "post-converge verification mismatch is reported clearly"
else
  test_fail "post-converge verification mismatch is reported clearly"
  cat "${VERIFY_FAIL_OUTPUT_FILE}" >&2
fi

test_start "2.3e" "host filtering deploys and verifies only the requested control-plane host"
FILTERED_ARTIFACTS="$(
  STUB_GITLAB_MODE=old \
  STUB_CICD_MODE=old \
  run_fixture filtered dev gitlab
)"
FILTERED_STATUS="$(artifact_status "${FILTERED_ARTIFACTS}")"
FILTERED_LOG_FILE="$(artifact_log_file "${FILTERED_ARTIFACTS}")"
FILTERED_OUTPUT_FILE="$(artifact_output_file "${FILTERED_ARTIFACTS}")"
if [[ "${FILTERED_STATUS}" == "0" ]]; then
  test_pass "single-host run exits 0 when the selected host converges"
else
  test_fail "single-host run exits 0 when the selected host converges"
  cat "${FILTERED_OUTPUT_FILE}" >&2
fi
if grep -q '^converge:-target=module.gitlab:' "${FILTERED_LOG_FILE}" && \
   ! grep -q '^converge:-target=module.cicd:' "${FILTERED_LOG_FILE}" && \
   ! grep -q 'ssh:10.0.0.20:readlink -f /run/current-system' "${FILTERED_LOG_FILE}"; then
  test_pass "single-host run does not touch cicd"
else
  test_fail "single-host run does not touch cicd"
  cat "${FILTERED_LOG_FILE}" >&2
fi

test_start "2.3f" "missing closure-paths.json fails closed before any deploy work"
MISSING_ARTIFACTS="$(
  STUB_CLOSURE_ARTIFACT_MODE=missing \
  run_fixture missing-artifact dev
)"
MISSING_STATUS="$(artifact_status "${MISSING_ARTIFACTS}")"
MISSING_OUTPUT_FILE="$(artifact_output_file "${MISSING_ARTIFACTS}")"
MISSING_LOG_FILE="$(artifact_log_file "${MISSING_ARTIFACTS}")"
if [[ "${MISSING_STATUS}" == "1" ]]; then
  test_pass "missing closure artifact exits non-zero"
else
  test_fail "missing closure artifact exits non-zero"
  cat "${MISSING_OUTPUT_FILE}" >&2
fi
if grep -q 'Closure artifact not found' "${MISSING_OUTPUT_FILE}" && \
   ! grep -q '^ssh:' "${MISSING_LOG_FILE}" && \
   ! grep -q '^converge:' "${MISSING_LOG_FILE}"; then
  test_pass "missing closure artifact aborts before ssh or converge-vm.sh"
else
  test_fail "missing closure artifact aborts before ssh or converge-vm.sh"
  cat "${MISSING_OUTPUT_FILE}" >&2
  cat "${MISSING_LOG_FILE}" >&2
fi

test_start "2.3g" "malformed closure-paths.json fails closed before any deploy work"
MALFORMED_ARTIFACTS="$(
  STUB_CLOSURE_ARTIFACT_MODE=malformed \
  run_fixture malformed-artifact dev
)"
MALFORMED_STATUS="$(artifact_status "${MALFORMED_ARTIFACTS}")"
MALFORMED_OUTPUT_FILE="$(artifact_output_file "${MALFORMED_ARTIFACTS}")"
MALFORMED_LOG_FILE="$(artifact_log_file "${MALFORMED_ARTIFACTS}")"
if [[ "${MALFORMED_STATUS}" == "1" ]]; then
  test_pass "malformed closure artifact exits non-zero"
else
  test_fail "malformed closure artifact exits non-zero"
  cat "${MALFORMED_OUTPUT_FILE}" >&2
fi
if grep -q 'Invalid closure artifact' "${MALFORMED_OUTPUT_FILE}" && \
   ! grep -q '^ssh:' "${MALFORMED_LOG_FILE}" && \
   ! grep -q '^converge:' "${MALFORMED_LOG_FILE}"; then
  test_pass "malformed closure artifact aborts before ssh or converge-vm.sh"
else
  test_fail "malformed closure artifact aborts before ssh or converge-vm.sh"
  cat "${MALFORMED_OUTPUT_FILE}" >&2
  cat "${MALFORMED_LOG_FILE}" >&2
fi

runner_summary
