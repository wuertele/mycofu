#!/usr/bin/env bash
set -euo pipefail

# Real ISO build test for the bpve02 per-node hil-boot ISO. Split out of
# tests/test_hil_boot_iso_derivation_contract.sh so the slow path (1.4 GB
# fetchurl + xorriso extract + xorriso repack, cold-cache ~5-10 min) runs
# after build:image:hil-boot where it can share /nix/store with that
# heavier image build. The validate-stage iso-contract test now keeps only
# the fast eval/static checks.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIG="${REPO_ROOT}/tests/hil/bfnet/config.yaml"
HELPER="${REPO_ROOT}/framework/scripts/hil-boot-secret-env.sh"

test_start "s037.0.8" "bpve02 ISO derivation invokes paia and embeds canonical files"
if [[ -z "${SOPS_AGE_KEY_FILE:-}" || ! -r "${SOPS_AGE_KEY_FILE:-}" ]]; then
  test_skip "SOPS_AGE_KEY_FILE is not set; real ISO build requires secret injection"
elif ! command -v xorriso >/dev/null 2>&1; then
  test_skip "xorriso is not installed in this environment (post-build ISO inspection requires it)"
else
  root_password="$("$HELPER" "$CONFIG" proxmox_api_password)"
  set +e
  build_output="$(cd "$REPO_ROOT" && MYCOFU_HIL_BOOT_ROOT_PASSWORD="$root_password" nix build --impure .#packages.x86_64-linux.hil-boot-bpve02-iso --no-link --print-out-paths 2>&1)"
  build_rc=$?
  set -e
  if [[ "$build_rc" -ne 0 && ( "$build_output" == *"cannot connect to socket"*"Operation not permitted"* || "$build_output" == *"unable to open database file"* ) ]]; then
    test_skip "Nix daemon is not reachable from this sandbox"
  elif [[ "$build_rc" -eq 0 ]] && ISO="$(tail -1 <<< "$build_output")" && \
     [[ -s "$ISO" ]]; then
    found="$(xorriso -indev "$ISO" -find / -name answer.toml -or -name auto-installer-mode.toml 2>/dev/null || true)"
    mode_tmp="$(mktemp "${TMPDIR:-/tmp}/hil-mode.XXXXXX")"
    trap 'rm -f "$mode_tmp"' EXIT
    xorriso -indev "$ISO" -osirrox on -extract /auto-installer-mode.toml "$mode_tmp" >/dev/null 2>&1
    if grep -q "'/answer.toml'" <<< "$found" && grep -q "'/auto-installer-mode.toml'" <<< "$found" && \
       diff -u <(printf 'mode = "iso"\npartition_label = "proxmox-ais"\n\n[http]\n') "$mode_tmp" >/dev/null; then
      test_pass "bpve02 ISO contains answer.toml and canonical mode TOML"
    else
      test_fail "bpve02 ISO missing answer.toml or canonical mode TOML"
    fi
  else
    test_fail "bpve02 ISO derivation failed to build"
  fi
fi

runner_summary
