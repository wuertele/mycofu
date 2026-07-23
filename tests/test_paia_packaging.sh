#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

NIX_UNAVAILABLE=0

test_start "s037.0.0" "paia package is documented as a local shim"
if grep -q 'mycofu-paia-compatible-shim' "${REPO_ROOT}/framework/nix/pkgs/paia/default.nix" && \
   grep -q 'not the upstream Proxmox' "${REPO_ROOT}/framework/nix/pkgs/paia/default.nix"; then
  test_pass "paia package source discloses local shim status"
else
  test_fail "paia package source still reads like an upstream binary package"
fi

test_start "s037.0.1" "paia package builds"
set +e
PAIA_BUILD_OUTPUT="$(cd "$REPO_ROOT" && nix build .#packages.x86_64-linux.paia --no-link --print-out-paths 2>&1)"
PAIA_BUILD_RC=$?
set -e
if [[ "$PAIA_BUILD_RC" -ne 0 && ( "$PAIA_BUILD_OUTPUT" == *"cannot connect to socket"*"Operation not permitted"* || "$PAIA_BUILD_OUTPUT" == *"unable to open database file"* ) ]]; then
  NIX_UNAVAILABLE=1
  test_skip "Nix daemon is not reachable from this sandbox"
elif [[ "$PAIA_BUILD_RC" -eq 0 ]] && PAIA_OUT="$(tail -1 <<< "$PAIA_BUILD_OUTPUT")" && \
   [[ -x "${PAIA_OUT}/bin/proxmox-auto-install-assistant" ]]; then
  test_pass "built ${PAIA_OUT}/bin/proxmox-auto-install-assistant"
else
  test_fail "nix build .#packages.x86_64-linux.paia failed or produced no executable"
fi

if [[ "$NIX_UNAVAILABLE" -eq 0 && -n "${PAIA_OUT:-}" && -x "${PAIA_OUT}/bin/proxmox-auto-install-assistant" ]]; then
  test_start "s037.0.2" "paia help surfaces prepare-iso"
  if "${PAIA_OUT}/bin/proxmox-auto-install-assistant" --help 2>&1 | grep -q 'prepare-iso' && \
     "${PAIA_OUT}/bin/proxmox-auto-install-assistant" prepare-iso --help 2>&1 | grep -q -- '--answer-file'; then
    test_pass "paia and prepare-iso help work"
  else
    test_fail "paia help output did not document prepare-iso"
  fi

  test_start "s037.0.3" "paia pin metadata visible"
  if [[ -f "${PAIA_OUT}/share/doc/paia/pin.json" ]] && \
     grep -q 'proxmox-auto-install-assistant_9.1.3_amd64.deb' "${PAIA_OUT}/share/doc/paia/pin.json" && \
     grep -q 'local paia-compatible prepare-iso shim' "${PAIA_OUT}/share/doc/paia/pin.json"; then
    test_pass "paia metadata records upstream compatibility and local shim status"
  else
    test_fail "paia metadata missing upstream package or local shim disclosure"
  fi

  test_start "s037.0.4" "paia shim prepare-iso output is deterministic"
  if ! command -v xorriso >/dev/null 2>&1; then
    test_skip "xorriso is not installed in this sandbox"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    test_skip "paia is platforms.linux; GNU coreutils from /nix/store cannot execute on Darwin, so prepare-iso falls through to BSD touch and rejects '-d @0'. Determinism is verified on Linux runners only."
  else
    work="$(mktemp -d)"
    cleanup_paia_work() {
      rm -rf "$work"
    }
    trap cleanup_paia_work EXIT
    mkdir -p "$work/src/boot/grub/i386-pc"
    truncate -s 1M "$work/src/boot/grub/i386-pc/eltorito.img"
    truncate -s 1M "$work/src/efi.img"
    printf 'kernel\n' > "$work/src/boot/linux26"
    printf 'initrd\n' > "$work/src/boot/initrd.img"
    # Symlink fixture is critical for catching the #402 P1 regression class.
    # `xorriso -osirrox -extract` assigns extraction-time mtimes to Rock
    # Ridge symlink entries (empirically verified during #402 review). A
    # recursive touch without `-h` dereferences and leaves the symlink's
    # own lstat-mtime drifting across runs, breaking ISO determinism even
    # when every regular-file mtime is pinned. Without this symlink the
    # determinism test passes on a buggy shim.
    ln -s linux26 "$work/src/boot/vmlinuz-default"
    printf '[global]\nfqdn = "node.example.test"\n' > "$work/answer.toml"
    xorriso_log="$work/source-xorriso.log"
    if ! xorriso -as mkisofs \
      -o "$work/source.iso" \
      -r -J -V "PVE" \
      -b boot/grub/i386-pc/eltorito.img \
      -c boot/boot.cat \
      -no-emul-boot -boot-load-size 4 \
      -boot-info-table --grub2-boot-info \
      -eltorito-alt-boot \
      -e efi.img \
      -no-emul-boot \
      -isohybrid-gpt-basdat \
      "$work/src" >"$xorriso_log" 2>&1; then
      test_skip "synthetic source ISO creation failed: $(tail -1 "$xorriso_log")"
      cleanup_paia_work
      trap - EXIT
      runner_summary
    fi
    "${PAIA_OUT}/bin/proxmox-auto-install-assistant" prepare-iso "$work/source.iso" \
      --fetch-from iso \
      --answer-file "$work/answer.toml" \
      --output "$work/out1.iso"
    "${PAIA_OUT}/bin/proxmox-auto-install-assistant" prepare-iso "$work/source.iso" \
      --fetch-from iso \
      --answer-file "$work/answer.toml" \
      --output "$work/out2.iso"
    if cmp -s "$work/out1.iso" "$work/out2.iso"; then
      test_pass "local paia-compatible shim produced byte-identical ISOs"
    else
      test_fail "local paia-compatible shim output was not deterministic"
    fi
    cleanup_paia_work
    trap - EXIT
  fi
fi

runner_summary
