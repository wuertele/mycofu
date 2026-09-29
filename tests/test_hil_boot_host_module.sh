#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

test_start "s037.1.1" "hil-boot host imports base and hil-boot module"
if [[ -f "${REPO_ROOT}/site/nix/hosts/hil-boot.nix" ]] && \
   grep -q 'modules/base.nix' "${REPO_ROOT}/site/nix/hosts/hil-boot.nix" && \
   grep -q 'modules/hil-boot-host.nix' "${REPO_ROOT}/site/nix/hosts/hil-boot.nix"; then
  test_pass "site/nix/hosts/hil-boot.nix imports expected modules"
else
  test_fail "hil-boot host config missing expected imports"
fi

test_start "s037.1.2" "hil-boot module installs runtime tools and artifact links"
MODULE="${REPO_ROOT}/framework/nix/modules/hil-boot-host.nix"
if [[ -f "$MODULE" ]] && \
   grep -q 'meshcmdPackage' "$MODULE" && \
   grep -q 'paiaPackage' "$MODULE" && \
   grep -q 'pkgs.dnsmasq' "$MODULE" && \
   grep -q 'services.nginx' "$MODULE" && \
   grep -q 'hil-boot-status' "$MODULE" && \
   grep -q '/var/lib/pxe-boot' "$MODULE"; then
  test_pass "hil-boot module has required tools and immutable artifact tree"
else
  test_fail "hil-boot module missing required tools or artifact links"
fi

test_start "s037.1.3" "flake exposes hil-boot system and image"
if grep -q 'hil_boot = "hil-boot"' "${REPO_ROOT}/flake.nix" && \
   grep -q 'hil-boot-image = "hil-boot"' "${REPO_ROOT}/flake.nix"; then
  test_pass "flake exposes hil-boot nixosConfiguration and image"
else
  test_fail "flake missing hil-boot system or image output"
fi

test_start "s037.1.4" "hil-boot closure check when Nix is available"
set +e
nix_stderr="$(mktemp "${TMPDIR:-/tmp}/nix-eval-stderr.XXXXXX")"
nix_output="$(cd "$REPO_ROOT" && nix eval --impure .#nixosConfigurations.hil_boot.config.system.build.toplevel.drvPath 2>"$nix_stderr")"
nix_rc=$?
set -e
nix_err="$(cat "$nix_stderr")"; rm -f "$nix_stderr"
if [[ "$nix_rc" -ne 0 && ( "$nix_err" == *"cannot connect to socket"*"Operation not permitted"* || "$nix_err" == *"unable to open database file"* ) ]]; then
  test_skip "Nix daemon is not reachable from this sandbox"
elif [[ "$nix_rc" -eq 0 ]]; then
  test_pass "hil-boot NixOS system evaluates"
else
  test_fail "hil-boot NixOS system did not evaluate"
fi

test_start "s037.1.8" "hil-boot closure contains PXE runtime tools and artifacts"
if [[ -z "${MYCOFU_HIL_BOOT_ROOT_PASSWORD:-}" ]]; then
  test_skip "MYCOFU_HIL_BOOT_ROOT_PASSWORD is not set; closure build requires ISO secret input"
else
  set +e
  build_output="$(cd "$REPO_ROOT" && nix build --impure --no-link --print-out-paths .#nixosConfigurations.hil_boot.config.system.build.toplevel 2>&1)"
  build_rc=$?
  set -e
  if [[ "$build_rc" -ne 0 && ( "$build_output" == *"cannot connect to socket"*"Operation not permitted"* || "$build_output" == *"unable to open database file"* ) ]]; then
    test_skip "Nix daemon is not reachable from this sandbox"
  elif [[ "$build_rc" -ne 0 ]]; then
    test_fail "hil-boot closure build failed"
    printf '%s\n' "$build_output" >&2
  else
    toplevel="$(tail -1 <<< "$build_output")"
    closure="$(nix-store -qR "$toplevel" 2>/dev/null || true)"
    missing=0
    for pattern in meshcmd dnsmasq nginx ipxe hil-boot-bpve01.iso hil-boot-bpve06.iso; do
      grep -Fq "$pattern" <<< "$closure" || missing=$((missing + 1))
    done
    if [[ "$missing" -eq 0 ]]; then
      test_pass "hil-boot closure contains meshcmd, dnsmasq, nginx, ipxe, and per-node ISOs"
    else
      test_fail "hil-boot closure is missing ${missing} expected runtime artifact(s)"
    fi
  fi
fi

runner_summary
