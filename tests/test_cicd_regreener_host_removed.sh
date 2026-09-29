#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

test_start "s037.1.5" "cicd no longer imports regreener-host"
if ! grep -q 'regreener-host.nix' "${REPO_ROOT}/site/nix/hosts/cicd.nix" && \
   [[ ! -e "${REPO_ROOT}/framework/nix/modules/regreener-host.nix" ]]; then
  test_pass "cicd import removed and old module deleted"
else
  test_fail "cicd still imports regreener-host or old module remains"
fi

test_start "s037.1.6" "hil-boot is the only site host importing hil-boot-host"
matches="$(grep -rn 'hil-boot-host.nix' "${REPO_ROOT}/site/nix/hosts" 2>/dev/null || true)"
if [[ "$matches" == *"site/nix/hosts/hil-boot.nix"* ]] && \
   [[ "$(wc -l <<< "$matches" | tr -d ' ')" == "1" ]]; then
  test_pass "hil-boot-host import is scoped to hil-boot"
else
  test_fail "unexpected hil-boot-host import pattern"
fi

test_start "s037.1.7" "cicd closure check when Nix is available"
set +e
nix_stderr="$(mktemp "${TMPDIR:-/tmp}/nix-eval-stderr.XXXXXX")"
nix_output="$(cd "$REPO_ROOT" && nix eval .#nixosConfigurations.cicd.config.system.build.toplevel.drvPath 2>"$nix_stderr")"
nix_rc=$?
set -e
nix_err="$(cat "$nix_stderr")"; rm -f "$nix_stderr"
if [[ "$nix_rc" -ne 0 && ( "$nix_err" == *"cannot connect to socket"*"Operation not permitted"* || "$nix_err" == *"unable to open database file"* ) ]]; then
  test_skip "Nix daemon is not reachable from this sandbox"
elif [[ "$nix_rc" -eq 0 ]]; then
  test_pass "cicd NixOS system still evaluates after regreener removal"
else
  test_fail "cicd NixOS system did not evaluate"
fi

test_start "s037.1.9" "cicd closure excludes meshcmd when Nix is available"
set +e
build_stderr="$(mktemp "${TMPDIR:-/tmp}/nix-build-stderr.XXXXXX")"
build_output="$(cd "$REPO_ROOT" && nix build --no-link --print-out-paths .#nixosConfigurations.cicd.config.system.build.toplevel 2>"$build_stderr")"
build_rc=$?
set -e
build_err="$(cat "$build_stderr")"; rm -f "$build_stderr"
if [[ "$build_rc" -ne 0 && ( "$build_err" == *"cannot connect to socket"*"Operation not permitted"* || "$build_err" == *"unable to open database file"* ) ]]; then
  test_skip "Nix daemon is not reachable from this sandbox"
elif [[ "$build_rc" -ne 0 ]]; then
  test_fail "cicd closure build failed"
  printf '%s\n' "$build_err" >&2
else
  toplevel="$(tail -1 <<< "$build_output")"
  closure="$(nix-store -qR "$toplevel" 2>/dev/null || true)"
  if ! grep -Fq 'meshcmd' <<< "$closure"; then
    test_pass "cicd closure does not contain meshcmd"
  else
    test_fail "cicd closure still contains meshcmd"
  fi
fi

runner_summary
