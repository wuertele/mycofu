#!/usr/bin/env bash
# test_generation_cleanup.sh — Verify generation cleanup timer configuration.
#
# Uses nix eval to check that the timer is present on field-updatable VMs
# (gitlab, cicd) and absent on data-plane VMs (dns).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

cd "$REPO_ROOT"

# Helper: check if a nix attribute exists
nix_attr_exists() {
  local attr="$1"
  nix eval "$attr" 2>/dev/null && return 0
  return 1
}

test_start "1" "gitlab has mycofu-generation-cleanup timer"
if nix_attr_exists ".#nixosConfigurations.gitlab.config.systemd.timers.mycofu-generation-cleanup" >/dev/null; then
  test_pass "timer exists on gitlab"
else
  test_fail "timer missing on gitlab"
fi

test_start "2" "cicd has mycofu-generation-cleanup timer"
if nix_attr_exists ".#nixosConfigurations.cicd.config.systemd.timers.mycofu-generation-cleanup" >/dev/null; then
  test_pass "timer exists on cicd"
else
  test_fail "timer missing on cicd"
fi

test_start "3" "dns_dev does NOT have mycofu-generation-cleanup timer"
if nix_attr_exists ".#nixosConfigurations.dns_dev.config.systemd.timers.mycofu-generation-cleanup" >/dev/null 2>&1; then
  test_fail "timer should not exist on dns_dev"
else
  test_pass "timer correctly absent on dns_dev"
fi

test_start "4" "Timer OnCalendar is weekly"
calendar=$(nix eval --raw ".#nixosConfigurations.gitlab.config.systemd.timers.mycofu-generation-cleanup.timerConfig.OnCalendar" 2>/dev/null || echo "")
if [[ "$calendar" == "weekly" ]]; then
  test_pass "OnCalendar = weekly"
else
  test_fail "OnCalendar = '${calendar}', expected 'weekly'"
fi

test_start "5" "Service ExecStart script contains generation cleanup commands"
exec_start=$(nix eval --raw ".#nixosConfigurations.gitlab.config.systemd.services.mycofu-generation-cleanup.serviceConfig.ExecStart" 2>/dev/null || echo "")
# ExecStart is a nix store path to a script — read its content
if [[ -f "$exec_start" ]]; then
  script_content="$(cat "$exec_start")"
  if echo "$script_content" | grep -q "delete-generations.*14d" && echo "$script_content" | grep -q "nix-collect-garbage"; then
    test_pass "script contains delete-generations 14d and nix-collect-garbage"
  else
    test_fail "script does not contain expected commands"
  fi
else
  # Store path not locally available (expected on macOS cross-eval)
  # Check via the nix store path name as a fallback
  if [[ "$exec_start" == *"generation-cleanup"* ]]; then
    test_pass "ExecStart points to generation-cleanup script (store path not locally readable)"
  else
    test_fail "ExecStart does not reference generation-cleanup: ${exec_start}"
  fi
fi

runner_summary
