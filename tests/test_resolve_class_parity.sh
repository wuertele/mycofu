#!/usr/bin/env bash
# test_resolve_class_parity.sh — assert the resolve_class Python function
# body is byte-identical across the three shell heredocs that embed it.
#
# Why: prior to #452 the three copies in vm-topology-lib.sh, rebuild-cluster.sh,
# and safe-apply.sh had drifted from each other (one was missing the digit-strip
# branch). The drift was the root cause of #452. Until #456 consolidates the
# four implementations into a shared library, this parity check alarms on any
# future drift cheaply.
#
# It does NOT check vm-scope.sh:resolve_label because that copy uses a different
# signature (returns a tuple) and slightly different regex spelling. The parity
# check here is scoped to the three sibling functions named resolve_class.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

# Extract the function body of `def resolve_class(...)` from each file. We
# take everything from the line `def resolve_class` through the next blank
# line (which marks the end of the function in each of these heredocs).
extract_resolve_class() {
  # Extract the function body and normalize away the pre-existing cosmetic
  # difference between vm-topology-lib.sh (uses `normalize`) and the
  # deployment scripts (use `normalize_label`). Both behave identically; the
  # name difference is tracked separately as a tech-debt follow-up (#456).
  local file="$1"
  awk '
    /^def resolve_class\(/ { capture=1 }
    capture { print }
    capture && /^$/ { exit }
  # Note: BSD sed (macOS) does not support \b word boundaries. The substitution
  # is safe without one because no identifier in these heredocs contains
  # "normalize_label" as a substring.
  ' "$file" | sed -E 's/normalize_label/normalize/g'
}

VTL="${REPO_ROOT}/framework/scripts/vm-topology-lib.sh"
RCS="${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"
SAS="${REPO_ROOT}/framework/scripts/safe-apply.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

extract_resolve_class "$VTL" > "${TMP}/vm-topology-lib.txt"
extract_resolve_class "$RCS" > "${TMP}/rebuild-cluster.txt"
extract_resolve_class "$SAS" > "${TMP}/safe-apply.txt"

test_start "RCP.1" "all three resolve_class blocks are non-empty"
if [[ -s "${TMP}/vm-topology-lib.txt" && \
      -s "${TMP}/rebuild-cluster.txt" && \
      -s "${TMP}/safe-apply.txt" ]]; then
  test_pass "all three resolve_class blocks extracted"
else
  test_fail "one or more resolve_class blocks could not be extracted"
  wc -l "${TMP}"/*.txt >&2
fi

test_start "RCP.2" "vm-topology-lib resolve_class is byte-identical to rebuild-cluster"
if diff -q "${TMP}/vm-topology-lib.txt" "${TMP}/rebuild-cluster.txt" >/dev/null; then
  test_pass "vm-topology-lib == rebuild-cluster"
else
  test_fail "DRIFT: vm-topology-lib.sh and rebuild-cluster.sh have divergent resolve_class blocks"
  diff -u "${TMP}/vm-topology-lib.txt" "${TMP}/rebuild-cluster.txt" >&2
fi

test_start "RCP.3" "vm-topology-lib resolve_class is byte-identical to safe-apply"
if diff -q "${TMP}/vm-topology-lib.txt" "${TMP}/safe-apply.txt" >/dev/null; then
  test_pass "vm-topology-lib == safe-apply"
else
  test_fail "DRIFT: vm-topology-lib.sh and safe-apply.sh have divergent resolve_class blocks"
  diff -u "${TMP}/vm-topology-lib.txt" "${TMP}/safe-apply.txt" >&2
fi

test_start "RCP.4" "rebuild-cluster resolve_class is byte-identical to safe-apply"
if diff -q "${TMP}/rebuild-cluster.txt" "${TMP}/safe-apply.txt" >/dev/null; then
  test_pass "rebuild-cluster == safe-apply"
else
  test_fail "DRIFT: rebuild-cluster.sh and safe-apply.sh have divergent resolve_class blocks"
  diff -u "${TMP}/rebuild-cluster.txt" "${TMP}/safe-apply.txt" >&2
fi

test_start "RCP.5" "the multi-instance digit-strip branch is present (#452 regression guard)"
# Match the digit-strip pattern itself, not a specific variable name. The
# implementations on dev use either `stripped = re.sub(r"[0-9]+$", ...)` or
# `numbered_base = re.sub(r"[0-9]+$", ...)`. Either form is acceptable as
# long as all three copies contain it.
if grep -Eq 're\.sub\(r"\[0-9\]\+\$"' "${TMP}/vm-topology-lib.txt" && \
   grep -Eq 're\.sub\(r"\[0-9\]\+\$"' "${TMP}/rebuild-cluster.txt" && \
   grep -Eq 're\.sub\(r"\[0-9\]\+\$"' "${TMP}/safe-apply.txt"; then
  test_pass "all three copies have the digit-strip fallback"
else
  test_fail "REGRESSION: one or more copies missing the #452 digit-strip fallback"
fi

runner_summary
