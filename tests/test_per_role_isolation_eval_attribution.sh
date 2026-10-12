#!/usr/bin/env bash
# test_per_role_isolation_eval_attribution.sh — issue #464 refinement 3.
#
# The #464 optimization collapses test_per_role_source_isolation.sh's per-role
# `nix eval` loop into a single batched `nix eval --json --apply`. Batching must
# NOT lose the prior loop's fail-loud per-role attribution: a role that fails to
# evaluate must still fail the test naming ITSELF, not vanish into an opaque
# batch error. This test exercises eval_all's failure-attribution paths against
# a tiny fixture flake (real `nix eval`, no builds), sourcing the isolation
# script in library mode (MYCOFU_ISO_LIB_ONLY=1) so eval_all runs standalone.
#
# Two failure classes are covered:
#   * catchable throw (throw / assert / NixOS module-system assertion — how
#     grafana/influxdb under-inclusion actually surfaces): tryEval inside the
#     apply yields a per-role sentinel; the batch succeeds and eval_all names
#     the sentinel'd role via jq.
#   * uncatchable abort (builtins.abort / infinite recursion): tryEval cannot
#     catch it, so the single invocation dies; eval_all's fallback replays the
#     per-role --raw loop and names the specific role.
# Plus the success path (correct TSV, non-image packages filtered out).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# Source the isolation script in library mode: it defines eval_all + nix_eval
# (and re-sources tests/lib/runner.sh), then returns before any probe runs.
export MYCOFU_ISO_LIB_ONLY=1
# shellcheck source=tests/test_per_role_source_isolation.sh
source "${REPO_ROOT}/tests/test_per_role_source_isolation.sh"
unset MYCOFU_ISO_LIB_ONLY
# The sourced script created its own TMP_DIR + installed an EXIT trap; capture
# that dir so our trap cleans it too (we override both below).
_SOURCED_TMP="${TMP_DIR:-}"

FIX="$(mktemp -d)"
# Override the sourced script's globals + EXIT trap with our own fixture state.
TMP_DIR="${FIX}/tmp"
mkdir -p "${TMP_DIR}"
trap 'rm -rf "${FIX}" "${_SOURCED_TMP}"' EXIT

# Build a fixture flake whose packages.x86_64-linux is a plain attrset of
# `{ outPath = ...; }` values (no derivations, so `nix eval` never builds).
# `somehosttool` is a NON-image package whose outPath THROWS: eval_all maps over
# the -image roles only, so forcing it would be a bug — the throw makes the
# "non-image not forced" assertion non-vacuous. ${broken_expr} injects the
# deliberately-broken image role (or nothing, e.g. for the missing-role case).
make_flake() {
  local dir="$1" broken_expr="$2"
  rm -rf "$dir"; mkdir -p "$dir"
  cat > "${dir}/flake.nix" <<NIX
{
  outputs = { self }: {
    packages.x86_64-linux = {
      "dns-image" = { outPath = "/nix/store/00000000000000000000000000000000-dns-image"; };
      "vault-image" = { outPath = "/nix/store/11111111111111111111111111111111-vault-image"; };
      ${broken_expr}
      "somehosttool" = { outPath = throw "non-image package must never be forced"; };
    };
  };
}
NIX
  git -C "$dir" init -q
  git -C "$dir" add flake.nix
}

# Drive the real eval_all against a fixture. $2 is the discovered role set the
# batch enumerates (mirrors $ALL_ROLES from discover_roles).
run_eval_all() {
  # WORK / ALL_ROLES are read by the sourced eval_all (shellcheck can't see it).
  # shellcheck disable=SC2034
  WORK="$1"
  # shellcheck disable=SC2034
  ALL_ROLES="$2"
  MAP="${TMP_DIR}/map.tsv"
  ERRF="${TMP_DIR}/eval.err"
  : > "$MAP"
  # eval_all toggles `set -e` internally, so a plain `set +e` wrapper is
  # defeated when it returns non-zero. `|| RC=$?` captures the exit code
  # without letting errexit abort this test regardless of eval_all's state.
  RC=0
  eval_all "$MAP" 2> "$ERRF" || RC=$?
  ERRTXT="$(cat "$ERRF")"
}

# ---------------------------------------------------------------------------
test_start "iso.attr.success" "batched eval: all-valid roles => rc0, correct TSV, non-image never forced"
make_flake "${FIX}/ok" ""
run_eval_all "${FIX}/ok" "dns vault"
if [[ "$RC" -eq 0 ]] &&
   [[ -n "$(awk -F'\t' '$1=="dns"   && $2 ~ /^\/nix\/store\/0+-dns-image$/'   "$MAP")" ]] &&
   [[ -n "$(awk -F'\t' '$1=="vault" && $2 ~ /^\/nix\/store\/1+-vault-image$/' "$MAP")" ]] &&
   ! grep -q 'somehosttool' "$MAP"; then
  test_pass "outPath TSV emitted for dns+vault; the throwing non-image package is never forced"
else
  test_fail "success path wrong (rc=$RC)"
  printf 'map:\n%s\nerr:\n%s\n' "$(cat "$MAP")" "$ERRTXT" >&2
fi

# ---------------------------------------------------------------------------
test_start "iso.attr.missing" "a discovered role that vanished from the flake => rc!=0 naming that role"
# Parity with the old per-role loop: the old `nix eval --raw ...broken-image`
# hard-failed on a missing attr. Enumerating $ALL_ROLES (not attrNames p) keeps
# that — attribute-missing is uncatchable, so it drops to the fallback.
make_flake "${FIX}/missing" ""
run_eval_all "${FIX}/missing" "dns vault broken"
if [[ "$RC" -ne 0 ]] &&
   grep -q 'single nix eval of image roles failed' <<< "$ERRTXT" &&
   grep -q 'failing role: broken' <<< "$ERRTXT" &&
   ! grep -q 'failing role: dns' <<< "$ERRTXT" &&
   ! grep -q 'failing role: vault' <<< "$ERRTXT"; then
  test_pass "a vanished role hard-fails and is named (strict parity, not silently dropped)"
else
  test_fail "missing-role parity wrong (rc=$RC)"
  printf 'err:\n%s\n' "$ERRTXT" >&2
fi

# ---------------------------------------------------------------------------
test_start "iso.attr.catchable" "a role whose outPath throws => rc!=0 naming ONLY that role"
make_flake "${FIX}/throw" '"broken-image" = { outPath = throw "deliberate #464 attribution break"; };'
run_eval_all "${FIX}/throw" "dns vault broken"
if [[ "$RC" -ne 0 ]] &&
   grep -q 'failed to eval image derivation for role' <<< "$ERRTXT" &&
   grep -qx '  broken' <<< "$ERRTXT" &&
   ! grep -qx '  dns' <<< "$ERRTXT" &&
   ! grep -qx '  vault' <<< "$ERRTXT"; then
  test_pass "tryEval sentinel attributes the failure to 'broken'; healthy roles are not named"
else
  test_fail "catchable attribution wrong (rc=$RC)"
  printf 'err:\n%s\n' "$ERRTXT" >&2
fi

# ---------------------------------------------------------------------------
test_start "iso.attr.uncatchable" "a role whose outPath aborts => fallback names that role"
make_flake "${FIX}/abort" '"broken-image" = { outPath = builtins.abort "uncatchable #464 boom"; };'
run_eval_all "${FIX}/abort" "dns vault broken"
if [[ "$RC" -ne 0 ]] &&
   grep -q 'single nix eval of image roles failed' <<< "$ERRTXT" &&
   grep -q 'failing role: broken' <<< "$ERRTXT" &&
   ! grep -q 'failing role: dns' <<< "$ERRTXT" &&
   ! grep -q 'failing role: vault' <<< "$ERRTXT"; then
  test_pass "uncatchable-abort fallback replays per-role --raw and names 'broken' only"
else
  test_fail "uncatchable attribution wrong (rc=$RC)"
  printf 'err:\n%s\n' "$ERRTXT" >&2
fi

runner_summary
