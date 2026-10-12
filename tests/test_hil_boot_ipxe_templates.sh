#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIG="${REPO_ROOT}/tests/hil/bfnet/config.yaml"
ARTIFACTS="${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix"
HIL_BOOT_IP="$(yq -r '.vms.hil_boot.ip' "${REPO_ROOT}/site/config.yaml")"

test_start "s037.2.8" "all boot.ipxe files contain required installer cmdline"
set +e
names_stderr="$(mktemp "${TMPDIR:-/tmp}/nix-eval-stderr.XXXXXX")"
names_output="$(cd "$REPO_ROOT" && nix eval .#packages.x86_64-linux --apply 'attrs: builtins.attrNames attrs' --json 2>"$names_stderr")"
names_rc=$?
set -e
names_err="$(cat "$names_stderr")"; rm -f "$names_stderr"
if [[ "$names_rc" -ne 0 && ( "$names_err" == *"cannot connect to socket"*"Operation not permitted"* || "$names_err" == *"unable to open database file"* ) ]]; then
  test_skip "Nix daemon is not reachable from this sandbox"
  buildable=0
elif [[ "$names_rc" -eq 0 ]]; then
  buildable=1
else
  test_fail "could not evaluate hil-boot boot.ipxe package names"
  buildable=0
fi

failures=0
while IFS= read -r node; do
  [[ -n "$node" ]] || continue
  if [[ "$buildable" -eq 1 ]]; then
    if path="$(cd "$REPO_ROOT" && nix build ".#packages.x86_64-linux.hil-boot-${node}-boot-ipxe" --no-link --print-out-paths 2>/dev/null | tail -1)" && [[ -f "$path" ]]; then
      grep -q 'proxmox-start-auto-installer' "$path" || failures=$((failures + 1))
      grep -q 'nomodeset' "$path" || failures=$((failures + 1))
      grep -q 'console=tty0' "$path" || failures=$((failures + 1))
      grep -q "http://${HIL_BOOT_IP}/nodes/${node}/proxmox.iso" "$path" || failures=$((failures + 1))
      ! grep -q 'http://hil-boot' "$path" || failures=$((failures + 1))
      ! grep -q 'proxmox-tui-mode\\|console=ttyS0' "$path" || failures=$((failures + 1))
    else
      failures=$((failures + 1))
    fi
  fi
done < <(yq -r '.nodes[] | select(.regreen_enabled == true) | .name' "$CONFIG")

if [[ "$buildable" -eq 0 ]]; then
  if grep -q 'proxmox-start-auto-installer' "$ARTIFACTS" && \
     grep -q 'nomodeset' "$ARTIFACTS" && \
     grep -q 'console=tty0' "$ARTIFACTS" && \
     grep -q 'http://${hilBootIp}/nodes/${nodeName}/proxmox.iso' "$ARTIFACTS" && \
     ! grep -q 'http://hil-boot' "$ARTIFACTS" && \
     ! grep -q 'proxmox-tui-mode\\|console=ttyS0' "$ARTIFACTS"; then
    test_pass "static boot.ipxe generator contains required cmdline, IP-literal URLs, and exclusions"
  else
    test_fail "static boot.ipxe generator missing required cmdline or contains forbidden mode"
  fi
elif [[ "$failures" -eq 0 ]]; then
  test_pass "all generated boot.ipxe files satisfy PXE installer contract with IP-literal URLs"
else
  test_fail "${failures} boot.ipxe assertion(s) failed"
fi

test_start "s037.2.9" "no answer-initrd overlay is generated"
if ! grep -R "answer-initrd\\|answer.cpio\\|auto-installer-mode.*initrd" "${REPO_ROOT}/site/nix" "${REPO_ROOT}/framework/nix/modules/hil-boot-host.nix" >/tmp/hil-ipxe-overlay.$$ 2>/dev/null; then
  test_pass "hil-boot uses per-node remastered ISO, not answer initrd overlay"
else
  test_fail "found answer-initrd overlay reference"
  sed 's/^/    /' /tmp/hil-ipxe-overlay.$$
fi
rm -f /tmp/hil-ipxe-overlay.$$

runner_summary
