#!/usr/bin/env bash
# test_rebuild_fixture_noop_helper.sh — drift guard for the shared
# rebuild-fixture noop-script helper (#320).
#
# The full-rebuild hermetic fixtures used to inline an identical base
# noop-script loop four times; adding a new rebuild-cluster.sh dependency
# (MR !263's configure-node-kernel.sh) meant editing all four, and missing
# one turned the pipeline red (903/904). tests/lib/rebuild_fixture_helpers.sh
# now owns the shared base list. This test fails if any fixture stops
# sourcing the helper, stops calling it, or re-inlines the base list; it
# also functionally exercises the helper so a broken helper is caught here
# rather than only in the heavyweight rebuild suites.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

HELPER="${REPO_ROOT}/tests/lib/rebuild_fixture_helpers.sh"

FIXTURES=(
  test_rebuild_ha_flow.sh
  test_rebuild_pbs_install_before_preboot_restore.sh
  test_rebuild_preboot_restore.sh
  test_rebuild_restore_pin_file.sh
)

# Base-only sentinels: scripts that live in the shared base and must never
# appear in a fixture again. If any of these is found in a fixture, someone
# re-inlined the base list (regardless of loop syntax). These are pure
# noops that no fixture stubs specially.
BASE_SENTINELS=(
  configure-node-storage.sh
  form-cluster.sh
  verify-nas-prereqs.sh
)

# Special scripts: at least one fixture stubs each of these specially (a
# logged stub, an exit-99 guard, or an assertion target). They must stay
# OUT of the shared base — putting one in the base would clobber a
# fixture's special stub with a silent noop and may not fail happy-path
# tests. This is the union of the four fixtures' extra-script arguments.
SPECIAL_SCRIPTS=(
  recover-secrets.sh
  install-pbs.sh
  configure-pbs.sh
  restore-from-pbs.sh
  cert-storage-backfill.sh
  configure-backups.sh
  configure-dashboard-tokens.sh
  deploy-workstation-closure.sh
)

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- Test 1: the helper is syntactically valid --------------------------
test_start "1" "helper passes bash -n"
if [[ ! -f "${HELPER}" ]]; then
  test_fail "helper not found at ${HELPER}"
elif bash -n "${HELPER}"; then
  test_pass "bash -n clean"
else
  test_fail "helper fails bash -n"
fi

# Source only after the syntax check so a broken helper reports cleanly.
# shellcheck source=/dev/null
source "${HELPER}"

# --- Test 2: helper defines the expected public API ---------------------
test_start "2" "helper exposes setup_rebuild_fixture_noops, make_noop_script, base list"
api_ok=1
[[ "$(type -t setup_rebuild_fixture_noops)" == "function" ]] || { test_fail "setup_rebuild_fixture_noops undefined"; api_ok=0; }
[[ "$(type -t make_noop_script)" == "function" ]] || { test_fail "make_noop_script undefined"; api_ok=0; }
[[ "${#DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS[@]}" -gt 0 ]] || { test_fail "DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS empty"; api_ok=0; }
[[ "${api_ok}" -eq 1 ]] && test_pass "public API present (${#DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS[@]}-script base)"

# --- Test 3: the MR !263 regression script is in the shared base --------
test_start "3" "configure-node-kernel.sh (MR !263) lives in the shared base"
found_kernel=0
for s in "${DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS[@]}"; do
  [[ "${s}" == "configure-node-kernel.sh" ]] && found_kernel=1
done
if [[ "${found_kernel}" -eq 1 ]]; then
  test_pass "present in DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS"
else
  test_fail "configure-node-kernel.sh missing from the shared base"
fi

# --- Test 4: the helper actually creates the shims it promises ----------
# Functional check: exercise base + a couple of dummy extras and assert
# each produces an executable, silently-succeeding shim. Guards the helper
# mechanism itself (not just that fixtures wire it up).
test_start "4" "setup_rebuild_fixture_noops materializes executable exit-0 shims"
setup_rebuild_fixture_noops "${WORK}/repo" __probe_extra_a.sh __probe_extra_b.sh
func_ok=1
for s in "${DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS[@]}" __probe_extra_a.sh __probe_extra_b.sh; do
  shim="${WORK}/repo/framework/scripts/${s}"
  if [[ ! -x "${shim}" ]]; then
    test_fail "expected executable shim missing: ${s}"; func_ok=0; break
  fi
  if ! "${shim}"; then
    test_fail "shim did not exit 0: ${s}"; func_ok=0; break
  fi
done
[[ "${func_ok}" -eq 1 ]] && test_pass "all base + extra shims created, executable, exit 0"

# --- Test 5: setup_rebuild_fixture_noops fails closed on missing repo_dir --
test_start "5" "setup_rebuild_fixture_noops rejects an empty repo_dir"
if setup_rebuild_fixture_noops "" 2>/dev/null; then
  test_fail "accepted empty repo_dir (would write to /framework/scripts)"
else
  test_pass "returned non-zero on empty repo_dir"
fi

# --- Test 6: known special scripts stay OUT of the shared base ----------
# Guards the "special stubs excluded from the default" contract: putting a
# specially-stubbed script into the base would silently clobber a fixture's
# logged/exit-99/assertion stub.
test_start "6" "special-cased scripts are absent from the shared base"
base_leak=""
for special in "${SPECIAL_SCRIPTS[@]}"; do
  for s in "${DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS[@]}"; do
    [[ "${s}" == "${special}" ]] && base_leak="${special}"
  done
done
if [[ -z "${base_leak}" ]]; then
  test_pass "no special script present in DEFAULT_REBUILD_FIXTURE_NOOP_SCRIPTS"
else
  test_fail "special script '${base_leak}' leaked into the shared base (would clobber a special stub)"
fi

# --- Test 7: each fixture sources the helper (real command, not comment) --
for fixture in "${FIXTURES[@]}"; do
  test_start "7:${fixture}" "sources rebuild_fixture_helpers.sh"
  path="${REPO_ROOT}/tests/${fixture}"
  # Anchor to an actual `source` line — the fixtures also NAME the helper
  # path in explanatory comments, which a loose grep would match.
  if [[ -f "${path}" ]] && grep -Eq '^[[:space:]]*source[[:space:]].*tests/lib/rebuild_fixture_helpers\.sh' "${path}"; then
    test_pass "sources helper"
  else
    test_fail "does not source rebuild_fixture_helpers.sh via a real source line"
  fi
done

# --- Test 8: each fixture calls the helper (real command, not comment) ---
for fixture in "${FIXTURES[@]}"; do
  test_start "8:${fixture}" "calls setup_rebuild_fixture_noops"
  path="${REPO_ROOT}/tests/${fixture}"
  if [[ -f "${path}" ]] && grep -Eq '^[[:space:]]*setup_rebuild_fixture_noops[[:space:]]' "${path}"; then
    test_pass "calls setup_rebuild_fixture_noops"
  else
    test_fail "does not call setup_rebuild_fixture_noops as a command"
  fi
done

# --- Test 9: no fixture re-inlines the base list ------------------------
# Loop-syntax-agnostic: a re-inlined base loop (any variable name, any
# construct) would name a base-only sentinel script. Assert none appear.
for fixture in "${FIXTURES[@]}"; do
  test_start "9:${fixture}" "does not re-inline the shared base list"
  path="${REPO_ROOT}/tests/${fixture}"
  hit=""
  for sentinel in "${BASE_SENTINELS[@]}"; do
    if [[ -f "${path}" ]] && grep -q "${sentinel}" "${path}"; then
      hit="${sentinel}"; break
    fi
  done
  if [[ -z "${hit}" ]]; then
    test_pass "no base-only script names present"
  else
    test_fail "base script '${hit}' named in fixture — base list re-inlined?"
  fi
done

runner_summary
