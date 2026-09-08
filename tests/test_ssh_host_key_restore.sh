#!/usr/bin/env bash
# test_ssh_host_key_restore.sh — Verify ssh-host-key-restore NixOS service.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

cd "$REPO_ROOT"

test_start "1" "ssh-host-key-restore service exists"
if nix eval ".#nixosConfigurations.gitlab.config.systemd.services.ssh-host-key-restore" >/dev/null 2>&1; then
  test_pass "service exists"
else
  test_fail "service not found"
fi

test_start "2" "Service type is oneshot"
svc_type=$(nix eval --raw ".#nixosConfigurations.gitlab.config.systemd.services.ssh-host-key-restore.serviceConfig.Type" 2>/dev/null || echo "")
if [[ "$svc_type" == "oneshot" ]]; then
  test_pass "Type = oneshot"
else
  test_fail "Type = '${svc_type}', expected 'oneshot'"
fi

test_start "3" "Service runs before sshd.service"
before=$(nix eval --json ".#nixosConfigurations.gitlab.config.systemd.services.ssh-host-key-restore.before" 2>/dev/null || echo "[]")
if echo "$before" | grep -q "sshd.service"; then
  test_pass "before includes sshd.service"
else
  test_fail "before does not include sshd.service: ${before}"
fi

test_start "4" "Service runs after nocloud-init.service"
after=$(nix eval --json ".#nixosConfigurations.gitlab.config.systemd.services.ssh-host-key-restore.after" 2>/dev/null || echo "[]")
if echo "$after" | grep -q "nocloud-init.service"; then
  test_pass "after includes nocloud-init.service"
else
  test_fail "after does not include nocloud-init.service: ${after}"
fi

test_start "5" "ConditionPathExists references the CIDATA key path"
condition=$(nix eval --raw ".#nixosConfigurations.gitlab.config.systemd.services.ssh-host-key-restore.unitConfig.ConditionPathExists" 2>/dev/null || echo "")
if [[ "$condition" == "/run/secrets/ssh/ssh_host_ed25519_key" ]]; then
  test_pass "ConditionPathExists = /run/secrets/ssh/ssh_host_ed25519_key"
else
  test_fail "ConditionPathExists = '${condition}', expected /run/secrets/ssh/ssh_host_ed25519_key"
fi

test_start "6" "Service exists on data-plane VM too (dns)"
if nix eval ".#nixosConfigurations.dns_dev.config.systemd.services.ssh-host-key-restore" >/dev/null 2>&1; then
  test_pass "service exists on dns_dev (base module)"
else
  test_fail "service missing on dns_dev"
fi

runner_summary
