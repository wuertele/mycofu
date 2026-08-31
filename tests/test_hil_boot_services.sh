#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

MODULE="${REPO_ROOT}/framework/nix/modules/hil-boot-host.nix"

test_start "s037.2.1" "hil-boot configures static artifact service"
if grep -q 'systemd.services.hil-boot-artifacts' "$MODULE" && \
   grep -q 'ln -sfn .*linux26' "$MODULE" && \
   grep -q 'ln -sfn .*initrd.img' "$MODULE" && \
   grep -q 'ln -sfn .*ipxe.efi' "$MODULE" && \
   grep -q 'nodes/.*/proxmox.iso' "$MODULE"; then
  test_pass "artifact service links immutable boot artifacts under /var/lib/pxe-boot"
else
  test_fail "artifact service does not link expected boot artifacts"
fi

test_start "s037.2.2" "hil-boot configures dnsmasq and nginx without mutation selector"
if grep -q 'systemd.services.hil-boot-dnsmasq' "$MODULE" && \
   grep -q 'services.nginx' "$MODULE" && \
   grep -q 'limit_except GET HEAD' "$MODULE" && \
   ! grep -q 'select-node\\|hil-boot-select-node' "$MODULE"; then
  test_pass "dnsmasq and read-only nginx are configured without selector command"
else
  test_fail "service config missing dnsmasq/nginx or contains selector command"
fi

test_start "s037.2.3" "firewall opens only PXE/HTTP service ports"
if grep -Fq 'allowedTCPPorts = [ 80 ]' "$MODULE" && \
   grep -Fq 'allowedUDPPorts = [ 67 69 ]' "$MODULE" && \
   ! grep -q 'allowedTCPPorts = .*53' "$MODULE" && \
   ! grep -q 'allowedUDPPorts = .*53' "$MODULE"; then
  test_pass "firewall opens HTTP, DHCP, and TFTP without DNS"
else
  test_fail "firewall port set is not the expected PXE/HTTP surface"
fi

test_start "s037.2.4" "hil-boot-status helper exists"
if grep -q 'writeShellScriptBin "hil-boot-status"' "$MODULE" && \
   grep -q 'hil-boot-dnsmasq.service' "$MODULE" && \
   grep -q 'nginx.service' "$MODULE"; then
  test_pass "hil-boot-status reports artifacts and services"
else
  test_fail "hil-boot-status helper missing expected output"
fi

runner_summary
