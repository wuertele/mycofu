#!/usr/bin/env bash
# test_check_boot_integrity.sh — Hermetic tests for the R7.3 boot-chain
# probe script. Guards #339 by testing the remote-probe logic against
# synthetic filesystem fixtures. SSH iteration and host_ip resolution
# are tested separately via test_grub_fixup_shared.sh and by
# check-control-plane-drift.sh's own tests — this file focuses on the
# core "given a grub.cfg + filesystem, are all referenced paths there?"
# predicate that the fix depends on.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/framework/scripts/check-boot-integrity.sh"
PROBE_LIB="${REPO_ROOT}/framework/scripts/lib/boot-integrity-probe.sh"

source "${REPO_ROOT}/tests/lib/runner.sh"

# The remote probe lives in a standalone file. check-boot-integrity.sh
# reads it and pipes it over SSH to each guest; we read the same file
# here so hermetic tests and live runs exercise byte-identical code.
if [[ ! -f "$PROBE_LIB" ]]; then
  echo "FATAL: probe library not found: $PROBE_LIB" >&2
  exit 2
fi
PROBE=$(cat "$PROBE_LIB")

run_probe_in_root() {
  # $1: fixture root path
  # runs the probe with ROOT_PREFIX set so the byte-identical script
  # reads grub.cfg from the fixture and resolves referenced paths
  # against the fixture, not the host. No source rewriting — the
  # test exercises the exact code that runs remotely.
  local root="$1"
  ROOT_PREFIX="$root" bash "$PROBE_LIB"
}

# --- Fixture builder ----------------------------------------------
mk_fixture() {
  local root="$1" grub_cfg_content="$2"; shift 2
  # Remaining args: relative paths to create as files under $root
  mkdir -p "$root/boot/grub"
  printf '%s' "$grub_cfg_content" > "$root/boot/grub/grub.cfg"
  local p
  for p in "$@"; do
    mkdir -p "$root$(dirname "$p")"
    : > "$root$p"
  done
}

# =====================================================================
# Test PROBE.1 — Healthy grub.cfg: kernel + initrd present → exit 0
# =====================================================================
test_start "PROBE.1" "all referenced paths present → exit 0"
tmp=$(mktemp -d)
mk_fixture "$tmp" '
menuentry "NixOS" {
  linux ($drive2)/nix/store/aaa-linux-6.6/bzImage init=/nix/store/bbb-nixos-system/init console=ttyS0
  initrd ($drive2)/nix/store/ccc-initrd/initrd
}
' \
  "/nix/store/aaa-linux-6.6/bzImage" \
  "/nix/store/ccc-initrd/initrd"
set +e
out=$(run_probe_in_root "$tmp" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 && -z "$out" ]]; then
  test_pass "exit 0, no output"
else
  test_fail "expected exit 0 with no output; got rc=$rc, out='$out'"
fi
rm -rf "$tmp"

# =====================================================================
# Test PROBE.2 — Broken )/store/ path (the #339 signature) → exit 1
# =====================================================================
test_start "PROBE.2" "broken )/store/ path missing on disk → exit 1"
tmp=$(mktemp -d)
mk_fixture "$tmp" '
menuentry "NixOS" {
  linux ($drive2)/store/aaa-linux-6.6/bzImage init=/nix/store/bbb-nixos-system/init console=ttyS0
  initrd ($drive2)/nix/store/ccc-initrd/initrd
}
' \
  "/nix/store/aaa-linux-6.6/bzImage" \
  "/nix/store/ccc-initrd/initrd"
# note: fixture has /nix/store/aaa/bzImage but grub.cfg looks under
# /store/aaa/bzImage (the #339 bug signature) — that path is missing
set +e
out=$(run_probe_in_root "$tmp" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && echo "$out" | grep -q '^MISSING: (\$drive2)/store/aaa-linux-6.6/bzImage'; then
  test_pass "exit 1 + MISSING for the broken path"
else
  test_fail "expected exit 1 with MISSING line; got rc=$rc, out='$out'"
fi
rm -rf "$tmp"

# =====================================================================
# Test PROBE.3 — Both kernel and initrd broken → exit 1, both reported
# =====================================================================
test_start "PROBE.3" "both linux and initrd broken → exit 1, both reported"
tmp=$(mktemp -d)
mk_fixture "$tmp" '
menuentry "NixOS" {
  linux ($drive2)/store/aaa/bzImage init=/nix/store/x/init
  initrd ($drive2)/store/bbb/initrd
}
'
# No files created — everything missing.
set +e
out=$(run_probe_in_root "$tmp" 2>&1)
rc=$?
set -e
n=$(echo "$out" | grep -c '^MISSING:' || true)
if [[ "$rc" -eq 1 && "$n" -eq 2 ]]; then
  test_pass "exit 1 with 2 MISSING lines"
else
  test_fail "expected exit 1 with 2 MISSING; got rc=$rc, n=$n, out='$out'"
fi
rm -rf "$tmp"

# =====================================================================
# Test PROBE.4 — Missing grub.cfg (non-grub bootloader) → exit 0, SKIP
# =====================================================================
test_start "PROBE.4" "no grub.cfg (non-grub bootloader) → exit 0 with SKIP"
tmp=$(mktemp -d)
# Deliberately don't create grub.cfg
set +e
out=$(run_probe_in_root "$tmp" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && echo "$out" | grep -q '^SKIP:'; then
  test_pass "exit 0 with SKIP line"
else
  test_fail "expected exit 0 with SKIP; got rc=$rc, out='$out'"
fi
rm -rf "$tmp"

# =====================================================================
# Test PROBE.5 — Multiple menuentries reference same kernel; dedup works
# =====================================================================
test_start "PROBE.5" "duplicate references across menuentries dedupe"
tmp=$(mktemp -d)
mk_fixture "$tmp" '
menuentry "NixOS" {
  linux ($drive2)/nix/store/aaa/bzImage init=/nix/store/x/init
  initrd ($drive2)/nix/store/bbb/initrd
}
submenu "NixOS - Configuration 1" {
  menuentry "Config 1" {
    linux ($drive2)/nix/store/aaa/bzImage init=/nix/store/y/init
    initrd ($drive2)/nix/store/bbb/initrd
  }
}
' \
  "/nix/store/aaa/bzImage" \
  "/nix/store/bbb/initrd"
# Both menuentries reference the same paths → probe should not double-check
set +e
out=$(run_probe_in_root "$tmp" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 && -z "$out" ]]; then
  test_pass "exit 0, dedup succeeded"
else
  test_fail "expected exit 0 with no output; got rc=$rc, out='$out'"
fi
rm -rf "$tmp"

# =====================================================================
# Test PROBE.6 — Only linux/initrd checked; loadfont/background_image
# lines with missing paths are IGNORED (fallback-safe, not boot-critical)
# =====================================================================
test_start "PROBE.6" "loadfont/background_image missing → still exit 0"
tmp=$(mktemp -d)
mk_fixture "$tmp" '
insmod font
if loadfont ($drive1)//converted-font.pf2; then
  insmod gfxterm
  if background_image ($drive1)//background.png; then
    set gfxmode=auto
  fi
fi
menuentry "NixOS" {
  linux ($drive2)/nix/store/aaa/bzImage init=/nix/store/x/init
  initrd ($drive2)/nix/store/bbb/initrd
}
' \
  "/nix/store/aaa/bzImage" \
  "/nix/store/bbb/initrd"
# converted-font.pf2 and background.png are NOT created — the probe
# must ignore them because those `if loadfont; then ...` paths fall
# back gracefully and are not boot-critical.
set +e
out=$(run_probe_in_root "$tmp" 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 && -z "$out" ]]; then
  test_pass "exit 0 — optional decoration paths correctly ignored"
else
  test_fail "expected exit 0 (loadfont/background not boot-critical); got rc=$rc, out='$out'"
fi
rm -rf "$tmp"

# =====================================================================
# Test PROBE.7 — The exact 2026-07-06 cicd signature (kernel path with
# )/store/ instead of )/nix/store/ in both default entry and fallback)
# =====================================================================
test_start "PROBE.7" "exact cicd 2026-07-06 signature is caught"
tmp=$(mktemp -d)
mk_fixture "$tmp" '
menuentry "NixOS" --class nixos --unrestricted {
  linux ($drive2)/store/lysgvmrdhda4gi9i671nbagc1qkrbnnq-linux-6.6.94/bzImage init=/nix/store/vacj1hrg-nixos-system/init console=ttyS0 loglevel=4
  initrd ($drive2)/store/s6z75rv94qdizsw793kyd2l526pfmx9x-initrd-linux-6.6.94/initrd
}
submenu "NixOS - All configurations" --class submenu {
  menuentry "NixOS - Configuration 1" --class nixos {
    linux ($drive2)/store/lysgvmrdhda4gi9i671nbagc1qkrbnnq-linux-6.6.94/bzImage init=/nix/store/snwyfdyg-nixos-system/init console=ttyS0 loglevel=4
    initrd ($drive2)/store/h2agxhz85khfhqswnv6z8kja7c7wh9ph-initrd-linux-6.6.94/initrd
  }
}
' \
  "/nix/store/lysgvmrdhda4gi9i671nbagc1qkrbnnq-linux-6.6.94/bzImage" \
  "/nix/store/s6z75rv94qdizsw793kyd2l526pfmx9x-initrd-linux-6.6.94/initrd" \
  "/nix/store/h2agxhz85khfhqswnv6z8kja7c7wh9ph-initrd-linux-6.6.94/initrd"
# The kernels/initrds exist in /nix/store, but grub.cfg looks under
# /store — the exact incident signature.
set +e
out=$(run_probe_in_root "$tmp" 2>&1)
rc=$?
set -e
# The linux path is deduped (same across both menuentries), but the
# two initrd paths differ, so we should see 3 MISSING lines (1 linux + 2 initrd).
n=$(echo "$out" | grep -c '^MISSING:' || true)
if [[ "$rc" -eq 1 && "$n" -eq 3 ]]; then
  test_pass "exit 1 with 3 MISSING lines (1 shared linux + 2 initrd)"
else
  test_fail "expected exit 1 with 3 MISSING; got rc=$rc, n=$n, out='$out'"
fi
rm -rf "$tmp"

# =====================================================================
# Test SCRIPT.1 — Static: script exists, is executable, syntax valid
# =====================================================================
test_start "SCRIPT.1" "check-boot-integrity.sh exists + executable + bash -n"
if [[ ! -x "$SCRIPT" ]]; then
  test_fail "$SCRIPT missing or not executable"
elif bash -n "$SCRIPT" 2>/dev/null; then
  test_pass "exists, executable, syntax valid"
else
  test_fail "bash -n failed"
fi

# =====================================================================
# Test SCRIPT.2 — Static: validate.sh wires R7.3 → check-boot-integrity.sh
# =====================================================================
test_start "SCRIPT.2" "validate.sh R7.3 invokes check-boot-integrity.sh"
if grep -q 'R7.3.*boot-chain integrity' "${REPO_ROOT}/framework/scripts/validate.sh" \
   && grep -q 'check-boot-integrity.sh' "${REPO_ROOT}/framework/scripts/validate.sh"; then
  test_pass "R7.3 wired"
else
  test_fail "validate.sh does not wire R7.3 to check-boot-integrity.sh"
fi

# =====================================================================
# Test SCRIPT.3 — Static: the live probe delivery pins the interpreter
# and clears the ROOT_PREFIX test hook. Guards against reintroducing
# the R1 gap where sshd ran the probe body through the remote account's
# default shell (so the probe's bash shebang was not honored) and where
# an inherited ROOT_PREFIX could in principle redirect a live check
# away from /.
# =====================================================================
test_start "SCRIPT.3" "live probe pins bash + unsets ROOT_PREFIX"
if grep -qE 'unset ROOT_PREFIX; exec bash -s' "$SCRIPT" \
   && grep -qE '<<< "\$REMOTE_PROBE"' "$SCRIPT"; then
  test_pass "interpreter pinned via bash -s, env hook cleared"
else
  test_fail "expected 'unset ROOT_PREFIX; exec bash -s' and here-string in $SCRIPT"
fi

runner_summary
