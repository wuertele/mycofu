#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

BASE_MODULE="${REPO_ROOT}/framework/nix/modules/base.nix"
DNS_MODULE="${REPO_ROOT}/framework/nix/modules/dns.nix"

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"

  if grep -qF "$pattern" "$file"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    missing pattern: %s\n' "$pattern" >&2
  fi
}

test_start "4.1" "base.nix enables overlay root prerequisites"
assert_file_contains "${BASE_MODULE}" 'boot.initrd.kernelModules = [ "overlay" ];' \
  "base.nix loads the overlay kernel module in initrd"
assert_file_contains "${BASE_MODULE}" 'boot.readOnlyNixStore = false;' \
  "base.nix keeps /nix writable under the overlay root"

test_start "4.2" "base.nix configures the initrd overlay root and early persisted mounts"
assert_file_contains "${BASE_MODULE}" 'boot.initrd.postMountCommands = lib.mkAfter' \
  "base.nix defines initrd postMountCommands"
assert_file_contains "${BASE_MODULE}" 'mount --bind /mnt-root /mnt-root-ro' \
  "base.nix creates a ro bind-mount of root for overlay lowerdir"
assert_file_contains "${BASE_MODULE}" 'mount -o remount,ro,bind /mnt-root-ro' \
  "base.nix makes the overlay lowerdir bind-mount read-only"
assert_file_contains "${BASE_MODULE}" 'lowerdir=/mnt-root-ro' \
  "base.nix uses the ro bind-mount as overlay lowerdir (not the rw ext4)"
assert_file_contains "${BASE_MODULE}" 'mount --bind /mnt-root/nix /mnt-overlay-combined/nix' \
  "base.nix bind-mounts /nix from the real rw ext4"
assert_file_contains "${BASE_MODULE}" 'mount --bind /mnt-root/boot /mnt-overlay-combined/boot' \
  "base.nix bind-mounts /boot from the real rw ext4"
assert_file_contains "${BASE_MODULE}" 'mount --bind /mnt-overlay-combined/nix/persist/letsencrypt /mnt-overlay-combined/etc/letsencrypt' \
  "base.nix bind-mounts persisted certbot state before stage-2"

test_start "4.3" "base.nix persists supporting state under /nix; grub fixup is NOT an activation script"
assert_file_contains "${BASE_MODULE}" '"d /nix/persist 0755 root root -"' \
  "base.nix creates the /nix/persist directory convention"
assert_file_contains "${BASE_MODULE}" '"d /nix/persist/gitlab-runner 0700 root root -"' \
  "base.nix creates the runner persistence directory"
assert_file_contains "${BASE_MODULE}" '"d /nix/persist/letsencrypt 0700 root root -"' \
  "base.nix creates the certbot persistence directory"
# Reject ANY activation script that edits /boot/grub/grub.cfg — not just
# fixGrubPaths. A boot-time grub rewrite corrupts correct factory paths.
# The fixup belongs only in converge-lib.sh's closure step.
if grep -q 'activationScripts.*grub\|grub.*activationScripts\|/boot/grub/grub.cfg' "${BASE_MODULE}" | grep -q 'activationScripts'; then
  test_fail "base.nix must NOT have an activation script that edits grub.cfg (corrupts correct paths on boot)"
elif grep -q 'activationScripts' "${BASE_MODULE}" && grep -A5 'activationScripts' "${BASE_MODULE}" | grep -q '/boot/grub'; then
  test_fail "base.nix must NOT have an activation script that edits grub.cfg (corrupts correct paths on boot)"
else
  test_pass "no activation script edits grub.cfg (fixup lives in converge-lib.sh closure step only)"
fi

test_start "4.4" "overlay root sizing is configurable and DNS defaults stay small"
assert_file_contains "${BASE_MODULE}" 'options.mycofu.overlayTmpfsSize = lib.mkOption {' \
  "base.nix defines the overlay tmpfs size option"
assert_file_contains "${BASE_MODULE}" 'default = "256M";' \
  "overlay tmpfs defaults to 256M"
assert_file_contains "${DNS_MODULE}" 'mycofu.overlayTmpfsSize = lib.mkDefault "64M";' \
  "DNS VMs default the overlay tmpfs to 64M"

test_start "4.5" "overlay-safe root device detection is shared and unprotected findmnt calls are gone"
if grep -lF 'getRealRootDevice = import' \
  "${REPO_ROOT}/framework/nix/modules/base.nix" \
  "${REPO_ROOT}/framework/nix/modules/gitlab.nix" \
  "${REPO_ROOT}/framework/nix/modules/vault.nix" \
  "${REPO_ROOT}/framework/catalog/influxdb/module.nix" \
  "${REPO_ROOT}/framework/catalog/grafana/module.nix" \
  "${REPO_ROOT}/framework/catalog/roon/module.nix" >/dev/null 2>&1; then
  test_pass "affected modules import the shared real-root-device helper"
else
  test_fail "affected modules import the shared real-root-device helper"
fi

UNPROTECTED_FINDMNT="$(
  grep -rn 'findmnt -n -o SOURCE /' \
    "${REPO_ROOT}/framework/nix/modules" \
    "${REPO_ROOT}/framework/catalog" \
    --include='*.nix' || true
)"
if [[ -z "${UNPROTECTED_FINDMNT}" ]]; then
  test_pass "no unprotected findmnt / usages remain in NixOS VM modules"
else
  test_fail "no unprotected findmnt / usages remain in NixOS VM modules"
  printf '    remaining matches:\n%s\n' "${UNPROTECTED_FINDMNT}" >&2
fi

runner_summary
