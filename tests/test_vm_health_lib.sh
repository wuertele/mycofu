#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/framework/scripts/vm-health-lib.sh"

STUB_SCENARIO=""

vm_health_ssh() {
  local ip="$1"
  shift
  local cmd="$*"
  local _unused_ip="$ip"

  case "${STUB_SCENARIO}:${cmd}" in
    vault-healthy:*'curl -sk https://127.0.0.1:8200/v1/sys/health')
      printf '%s' '{"initialized":true,"sealed":false}'
      return 0
      ;;
    vault-empty:*'curl -sk https://127.0.0.1:8200/v1/sys/health')
      printf '%s' '{"initialized":true,"sealed":false}'
      return 0
      ;;
    vault-sealed:*'curl -sk https://127.0.0.1:8200/v1/sys/health')
      printf '%s' '{"initialized":true,"sealed":true}'
      return 0
      ;;
    vault-healthy:'test -s /var/lib/vault/data/vault.db')
      return 0
      ;;
    vault-empty:'test -s /var/lib/vault/data/vault.db')
      return 1
      ;;
    gitlab-503:'curl -fsSk https://127.0.0.1/-/readiness >/dev/null')
      return 22
      ;;
    workstation-empty:*'authorized_keys'*)
      return 1
      ;;
    workstation-populated:*'authorized_keys'*)
      return 0
      ;;
    generic-empty:'find /var/lib -mindepth 1 ! -name lost+found -print -quit | grep -q .')
      return 1
      ;;
    generic-populated:'find /var/lib -mindepth 1 ! -name lost+found -print -quit | grep -q .')
      return 0
      ;;
    *)
      echo "unexpected vm_health_ssh scenario=${STUB_SCENARIO} cmd=${cmd}" >&2
      return 98
      ;;
  esac
}

vm_health_node_ssh() {
  local ip="$1"
  shift
  local cmd="$*"
  local _unused_ip="$ip"

  case "${STUB_SCENARIO}:${cmd}" in
    generic-empty:*"qm config 900"*)
      printf '%s\n' 'vm-900-disk-1'
      return 0
      ;;
    generic-populated:*"qm config 900"*)
      printf '%s\n' 'vm-900-disk-1'
      return 0
      ;;
    workstation-empty:*"qm config 701"*)
      printf '%s\n' 'vm-701-disk-1'
      return 0
      ;;
    workstation-populated:*"qm config 701"*)
      printf '%s\n' 'vm-701-disk-1'
      return 0
      ;;
    generic-empty:*'blkid /dev/zvol/vmstore/data/vm-900-disk-1 2>/dev/null')
      printf '%s\n' '/dev/zvol/vmstore/data/vm-900-disk-1: UUID="x" TYPE="ext4"'
      return 0
      ;;
    generic-populated:*'blkid /dev/zvol/vmstore/data/vm-900-disk-1 2>/dev/null')
      printf '%s\n' '/dev/zvol/vmstore/data/vm-900-disk-1: UUID="x" TYPE="ext4"'
      return 0
      ;;
    workstation-empty:*'blkid /dev/zvol/vmstore/data/vm-701-disk-1 2>/dev/null')
      printf '%s\n' '/dev/zvol/vmstore/data/vm-701-disk-1: UUID="x" TYPE="ext4"'
      return 0
      ;;
    workstation-populated:*'blkid /dev/zvol/vmstore/data/vm-701-disk-1 2>/dev/null')
      printf '%s\n' '/dev/zvol/vmstore/data/vm-701-disk-1: UUID="x" TYPE="ext4"'
      return 0
      ;;
    *)
      echo "unexpected vm_health_node_ssh scenario=${STUB_SCENARIO} cmd=${cmd}" >&2
      return 98
      ;;
  esac
}

run_capture() {
  local output=""
  set +e
  output="$("$@" 2>&1)"
  STATUS=$?
  set -e
  OUTPUT="$output"
}

assert_exit() {
  local expected="$1"
  local label="$2"

  if [[ "$STATUS" -eq "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected exit %s, got %s\n' "$expected" "$STATUS" >&2
    printf '    output:\n%s\n' "$OUTPUT" >&2
  fi
}

assert_output_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq "$needle" <<< "$OUTPUT"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    missing output: %s\n' "$needle" >&2
    printf '    output:\n%s\n' "$OUTPUT" >&2
  fi
}

test_start "12.1" "vault health check passes on healthy state"
STUB_SCENARIO="vault-healthy"
run_capture vm_health_vault vault_dev 172.27.60.52
assert_exit 0 "vm_health_vault returns 0 for healthy vault"

test_start "12.2" "vault health check catches missing barrier (vault.db)"
STUB_SCENARIO="vault-empty"
run_capture vm_health_vault vault_dev 172.27.60.52
assert_exit 1 "vm_health_vault returns non-zero for missing barrier"
assert_output_contains "vault.db (barrier) missing or empty" "missing barrier reason is reported"

test_start "12.3" "vault health check rejects sealed vault"
STUB_SCENARIO="vault-sealed"
run_capture vm_health_vault vault_dev 172.27.60.52
assert_exit 1 "vm_health_vault returns non-zero for sealed vault"
assert_output_contains "vault is sealed" "sealed reason is reported"

test_start "12.4" "gitlab readiness failure is unhealthy"
STUB_SCENARIO="gitlab-503"
run_capture vm_health_gitlab gitlab 172.17.77.62
assert_exit 1 "vm_health_gitlab returns non-zero for readiness failure"
assert_output_contains "gitlab readiness probe failed" "gitlab readiness reason is reported"

test_start "12.5" "generic fallback fails on empty ext4 volume"
STUB_SCENARIO="generic-empty"
run_capture vm_health_generic future_app 172.27.60.80 172.17.77.51 900
assert_exit 1 "vm_health_generic returns non-zero for empty /var/lib"
assert_output_contains "/var/lib is empty" "generic empty reason is reported"

test_start "12.6" "generic fallback passes on populated ext4 volume"
STUB_SCENARIO="generic-populated"
run_capture vm_health_generic future_app 172.27.60.80 172.17.77.51 900
assert_exit 0 "vm_health_generic returns 0 for populated ext4"

test_start "12.7" "workstation health ignores bootstrap-only /home state"
STUB_SCENARIO="workstation-empty"
run_capture vm_health_workstation workstation_dev 172.17.77.68 172.17.77.51 701
assert_exit 1 "vm_health_workstation returns non-zero for bootstrap-only /home"
assert_output_contains "/home has no real state beyond bootstrap" "workstation empty reason is reported"

test_start "12.8" "workstation health passes once /home has real state"
STUB_SCENARIO="workstation-populated"
run_capture vm_health_workstation workstation_dev 172.17.77.68 172.17.77.51 701
assert_exit 0 "vm_health_workstation returns 0 for populated /home"

runner_summary
