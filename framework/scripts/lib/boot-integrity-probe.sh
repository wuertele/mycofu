#!/usr/bin/env bash
# boot-integrity-probe.sh — Guest-side probe for the R7.3 boot-chain check.
#
# Read /boot/grub/grub.cfg on the running VM and assert every
# ($drive*)/PATH referenced by `linux` and `initrd` directives points
# at a file that exists on disk. Emits one `MISSING:` line per broken
# reference. Silent on success.
#
# Runs remotely via check-boot-integrity.sh's SSH loop and is also
# exercised locally by tests/test_check_boot_integrity.sh against
# synthetic filesystem fixtures.
#
# Exit codes:
#   0 — every referenced path resolves, OR grub.cfg absent (non-grub bootloader)
#   1 — at least one referenced path missing on disk
#
# Scope note: we check only `linux` and `initrd` because those are the
# paths whose absence bricks the boot. Optional decoration paths
# (loadfont, background_image) are inside `if ... then` guards and
# their absence causes a graphics fallback, not a boot failure — so
# scanning them would produce false FAILs on VMs where the fallback
# is intentional.
#
# Environment:
#   ROOT_PREFIX — testing hook. When set, the probe reads grub.cfg
#     from "$ROOT_PREFIX/boot/grub/grub.cfg" and resolves every path
#     against "$ROOT_PREFIX$path". Unset in production so the probe
#     runs against the real / filesystem. Tests set this so hermetic
#     fixtures don't need to sed-rewrite the probe body — the
#     byte-identical script runs against a rooted fixture.
#
# See #339, #497, #496, and converge_fix_grub_paths() in
# framework/scripts/converge-lib.sh.

set -e

: "${ROOT_PREFIX:=}"
GRUB_CFG="${ROOT_PREFIX}/boot/grub/grub.cfg"

if [ ! -f "$GRUB_CFG" ]; then
  echo "SKIP: no /boot/grub/grub.cfg (non-grub bootloader?)"
  exit 0
fi

missing=0
# Regex requires a `/` immediately after the `)`, tightening the match
# to only GRUB-drive-prefixed absolute paths and rejecting stray
# tokens like `root=(hd0,1)` that could otherwise sneak through.
# [^[:space:]] instead of [^ ] guards against tabs in grub.cfg.
for entry in $(grep -E '^[[:space:]]*(linux|initrd)[[:space:]]+\(' "$GRUB_CFG" | grep -oE '\([^)]+\)/[^[:space:]]+' | sort -u); do
  # entry looks like ($drive2)/nix/store/HASH-linux/bzImage.
  # Strip up to first close-paren to get the path on the root fs.
  # On overlay-root NixOS VMs, $drive resolves to the root ext4.
  path=${entry#*)}
  if [ ! -e "${ROOT_PREFIX}${path}" ]; then
    echo "MISSING: $entry -> $path"
    missing=1
  fi
done

exit $missing
