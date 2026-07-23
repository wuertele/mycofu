#!/usr/bin/env bash
# test_systemd_fd_leak_version.sh - Guard the systemd BPF FD leak fix and boot-safe package selection.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

cd "$REPO_ROOT"

BACKPORT_PATCH_NAME="systemd-256-bpf-firewall-close-cgroup-runtime.patch"

version_major() {
  local version="$1"
  version="${version%%[!0-9.]*}"
  printf '%s\n' "${version%%.*}"
}

eval_raw() {
  local output_var="$1"
  local label="$2"
  shift 2
  local stderr_log
  local output
  local rc
  local stderr

  stderr_log="$(mktemp "${TMPDIR:-/tmp}/systemd-eval-stderr.XXXXXX")"
  set +e
  output="$(nix eval --raw "$@" 2>"$stderr_log")"
  rc=$?
  set -e
  stderr="$(tr '\n' ' ' < "$stderr_log")"
  rm -f "$stderr_log"

  if [[ "$rc" -ne 0 ]]; then
    test_fail "${label}: ${stderr}"
    return 1
  fi

  printf -v "$output_var" '%s' "$output"
  return 0
}

assert_fixed_systemd() {
  local config_name="$1"
  local attr=".#nixosConfigurations.${config_name}.config.systemd.package"
  local initrd_attr=".#nixosConfigurations.${config_name}.config.boot.initrd.systemd.package"
  local release_attr=".#nixosConfigurations.${config_name}.config.system.nixos.release"
  local version
  local release
  local systemd_drv
  local initrd_systemd_drv
  local backported
  local patches
  local major

  eval_raw release "${config_name} failed to evaluate NixOS release" "${release_attr}" || return
  eval_raw version "${config_name} failed to evaluate systemd package version" "${attr}.version" || return
  eval_raw systemd_drv "${config_name} failed to evaluate systemd package derivation" "${attr}.drvPath" || return
  eval_raw initrd_systemd_drv "${config_name} failed to evaluate initrd systemd package derivation" "${initrd_attr}.drvPath" || return
  eval_raw backported "${config_name} failed to evaluate systemd BPF FD leak backport marker" \
    "${attr}" \
    --apply 'pkg: if (pkg.mycofuBpfFdLeakFix or false) then "true" else "false"' || return
  eval_raw patches "${config_name} failed to evaluate systemd patch list" \
    "${attr}" \
    --apply 'pkg: builtins.concatStringsSep "\n" (map (p: baseNameOf (toString p)) (pkg.patches or []))' || return

  if [[ "$systemd_drv" != "$initrd_systemd_drv" ]]; then
    test_fail "${config_name} uses different systemd derivations for stage 1 and stage 2"
    return
  fi

  major="$(version_major "$version")"

  if [[ "$release" == "24.11" ]]; then
    # Keep this branch stricter than version >=257. The failed #422 rollout
    # used a new-enough unstable systemd, but it crashed in NixOS 24.11 stage 1.
    # Revisit when the pinned base channel itself moves past 24.11.
    if [[ "$backported" == "true" ]] && grep -Fxq "$BACKPORT_PATCH_NAME" <<< "$patches"; then
      test_pass "${config_name} uses NixOS ${release} systemd ${version} with Mycofu BPF FD leak backport"
    else
      test_fail "${config_name} uses NixOS ${release} systemd ${version} without ${BACKPORT_PATCH_NAME}"
    fi
    return
  fi

  if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 257 )); then
    test_pass "${config_name} uses NixOS ${release} systemd ${version} with upstream BPF FD leak fix"
  elif [[ "$backported" == "true" ]] && grep -Fxq "$BACKPORT_PATCH_NAME" <<< "$patches"; then
    test_pass "${config_name} uses NixOS ${release} systemd ${version} with Mycofu BPF FD leak backport"
  else
    test_fail "${config_name} uses NixOS ${release} systemd ${version} without root/mycofu#422 fix"
  fi
}

test_start "1" "all NixOS configurations use a boot-safe systemd with the BPF FD leak fix"
configs_stderr_log="$(mktemp "${TMPDIR:-/tmp}/systemd-configs-stderr.XXXXXX")"
set +e
configs="$(nix eval --raw ".#nixosConfigurations" \
  --apply 'attrs: builtins.concatStringsSep "\n" (builtins.attrNames attrs)' \
  2>"$configs_stderr_log")"
configs_rc=$?
set -e
configs_stderr="$(tr '\n' ' ' < "$configs_stderr_log")"
rm -f "$configs_stderr_log"

if [[ "$configs_rc" -ne 0 ]]; then
  test_fail "failed to enumerate nixosConfigurations: ${configs_stderr}"
elif [[ -z "$configs" ]]; then
  test_fail "flake exposes no nixosConfigurations"
else
  while IFS= read -r config_name; do
    [[ -n "$config_name" ]] || continue
    assert_fixed_systemd "$config_name"
  done <<< "$configs"
fi

runner_summary
