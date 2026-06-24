#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIG="${REPO_ROOT}/tests/hil/bfnet/config.yaml"

nix_unavailable() {
  [[ "$1" == *"cannot connect to socket"*"Operation not permitted"* || "$1" == *"unable to open database file"* ]]
}

eval_drv() {
  local attr="$1"
  local stderr_log
  local output
  local rc

  stderr_log="$(mktemp "${TMPDIR:-/tmp}/nix-eval-stderr.XXXXXX")"
  output="$(cd "$REPO_ROOT" && nix eval --impure --raw "${REPO_ROOT}#${attr}" 2>"$stderr_log")"
  rc=$?

  printf '%s' "$output"
  if [[ "$rc" -ne 0 && -s "$stderr_log" ]]; then
    [[ -z "$output" ]] || printf '\n'
    cat "$stderr_log"
  fi
  rm -f "$stderr_log"
  return "$rc"
}

test_start "s037.0.10" "normal nixSrc excludes HIL fixtures"
if grep -q 'hilNixSrc = mkNixSrc true' "${REPO_ROOT}/flake.nix" && \
   grep -q 'nixSrc = mkNixSrc false' "${REPO_ROOT}/flake.nix" && \
   grep -q '(includeHil && nixpkgs.lib.hasPrefix "tests/hil/" relPath)' "${REPO_ROOT}/flake.nix"; then
  test_pass "flake has a HIL-only source filter"
else
  test_fail "flake does not split HIL fixtures out of normal nixSrc"
fi

test_start "s037.0.11" "hil-boot config is referenced only through the HIL source filter"
if grep -q '\${nixSrc}/tests/hil/bfnet/config.yaml' "${REPO_ROOT}/site/nix/lib/hil-boot-artifacts.nix" && \
   grep -q 'nixSrc = hilNixSrc' "${REPO_ROOT}/flake.nix" && \
   ! grep -q 'tests/hil/bfnet' "${REPO_ROOT}/framework/nix/"*.nix "${REPO_ROOT}/framework/nix/modules/"*.nix 2>/dev/null; then
  test_pass "HIL config is consumed by hil-boot artifacts only"
else
  test_fail "HIL config reference bypasses the HIL source filter or leaks into framework Nix"
fi

test_start "s037.0.12" "HIL config perturbation changes only hil_boot toplevel"
set +e
hil_before="$(eval_drv 'nixosConfigurations.hil_boot.config.system.build.toplevel.drvPath')"
hil_before_rc=$?
dns_before="$(eval_drv 'nixosConfigurations.dns_dev.config.system.build.toplevel.drvPath')"
dns_before_rc=$?
set -e

if [[ "$hil_before_rc" -ne 0 ]] && nix_unavailable "$hil_before"; then
  test_skip "Nix daemon is not reachable from this sandbox"
elif [[ "$dns_before_rc" -ne 0 ]] && nix_unavailable "$dns_before"; then
  test_skip "Nix daemon is not reachable from this sandbox"
elif [[ "$hil_before_rc" -ne 0 || "$dns_before_rc" -ne 0 ]]; then
  test_fail "initial toplevel evaluation failed"
  printf '%s\n%s\n' "$hil_before" "$dns_before" >&2
else
  backup="$(mktemp "${TMPDIR:-/tmp}/hil-config.XXXXXX.yaml")"
  cp "$CONFIG" "$backup"
  restore_config() {
    cp "$backup" "$CONFIG"
    rm -f "$backup"
  }
  trap restore_config EXIT

  yq -i '.nodes[0].mgmt_ip = "192.0.2.250"' "$CONFIG"

  set +e
  hil_after="$(eval_drv 'nixosConfigurations.hil_boot.config.system.build.toplevel.drvPath')"
  hil_after_rc=$?
  dns_after="$(eval_drv 'nixosConfigurations.dns_dev.config.system.build.toplevel.drvPath')"
  dns_after_rc=$?
  set -e

  restore_config
  trap - EXIT

  if [[ "$hil_after_rc" -ne 0 || "$dns_after_rc" -ne 0 ]]; then
    test_fail "post-perturbation toplevel evaluation failed"
    printf '%s\n%s\n' "$hil_after" "$dns_after" >&2
  elif [[ "$hil_before" != "$hil_after" && "$dns_before" == "$dns_after" ]]; then
    test_pass "HIL config perturbation changes hil_boot and leaves dns_dev unchanged"
  else
    test_fail "unexpected perturbation result: hil_boot changed=$([[ "$hil_before" != "$hil_after" ]] && echo yes || echo no), dns_dev changed=$([[ "$dns_before" != "$dns_after" ]] && echo yes || echo no)"
  fi
fi

runner_summary
