#!/usr/bin/env bash
# Regression test for #567: dead 'unknown' case arms in setup-nix-builder.sh.
#
# qcow2_size_status() never emits a bare 'unknown' — an unverifiable qcow2
# (qemu-img missing or unusable) is emitted as 'wrong-size:unknown:<expected>'.
# Two consumer case blocks previously had a dead 'unknown)' arm, so an
# unverifiable qcow2 fell into the generic 'wrong-size:*' arm with a
# misleading "virtual size does not match config" message.
#
# Both reviewers of the initial batch-B fix (codex P2, sub-claude P2)
# flagged that a whole-file grep for the ordering check could accidentally
# match the first (converge_builder post-start) block instead of the
# verify_linux_builder block. This test now scopes the extraction to each
# function individually.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

SETUP="${REPO_ROOT}/framework/scripts/setup-nix-builder.sh"

# extract_function_body <function_name> — echoes the lines inside the named
# top-level function body (between the `funcname() {` opener and its matching
# closing `}` at column 0). Scoped extraction eliminates whole-file grep
# accidentally matching the wrong block.
extract_function_body() {
  local func="$1"
  awk -v fn="$func" '
    $0 ~ "^" fn "\\(\\) \\{" { inside = 1; next }
    inside && $0 ~ /^\}/ { exit }
    inside { print }
  ' "$SETUP"
}

# assert_arm_order_in_function <function_name>
# Asserts the wrong-size:unknown:* arm appears BEFORE the wrong-size:* arm
# inside the named function. Order matters in `case` — the specific pattern
# must win.
assert_arm_order_in_function() {
  local func="$1" body unknown_line generic_line
  body=$(extract_function_body "$func")
  # awk over the extracted body — line numbers are relative to the body,
  # which is fine for ordering (line-N < line-M implies before).
  unknown_line=$(echo "$body" | awk '/wrong-size:unknown:\*\)/{ print NR; exit }')
  generic_line=$(echo "$body" | awk '/^[[:space:]]*wrong-size:\*\)[[:space:]]*$/{ print NR; exit }')
  if [[ -n "$unknown_line" && -n "$generic_line" && "$unknown_line" -lt "$generic_line" ]]; then
    return 0
  fi
  echo "FUNCTION=${func} unknown_line=${unknown_line:-none} generic_line=${generic_line:-none}" >&2
  return 1
}

# --- Test 1: converge_builder's post-start check has the dedicated arm.
test_start "567.1" "converge_builder post-start qcow2 check has wrong-size:unknown:* arm"
if assert_arm_order_in_function converge_builder; then
  test_pass "wrong-size:unknown:* arm scoped inside converge_builder precedes wrong-size:*"
else
  test_fail "converge_builder is missing wrong-size:unknown:* arm or ordering is wrong"
fi

# --- Test 2: verify_linux_builder has the dedicated arm.
# The whole-file grep the earlier version used matched converge_builder's
# arm and passed for the wrong reason. Function-scoped extraction is the
# real teeth.
test_start "567.2" "verify_linux_builder has wrong-size:unknown:* arm (scoped)"
if assert_arm_order_in_function verify_linux_builder; then
  test_pass "wrong-size:unknown:* arm scoped inside verify_linux_builder precedes wrong-size:*"
else
  test_fail "verify_linux_builder is missing wrong-size:unknown:* arm or ordering is wrong"
fi

# --- Test 3: no dead bare 'unknown)' arm ANYWHERE in the file.
# Structural ratchet: any future edit that re-introduces the dead arm fails.
test_start "567.3" "no dead bare 'unknown)' arm remains in setup-nix-builder.sh"
# A leading whitespace ensures we do not match 'wrong-size:unknown:*)'.
bare_unknown_count=$(grep -Ec '^[[:space:]]+unknown\)[[:space:]]*$' "$SETUP" || true)
if [[ "$bare_unknown_count" -eq 0 ]]; then
  test_pass "no dead 'unknown)' arm; qcow2_size_status contract preserved"
else
  test_fail "found $bare_unknown_count dead 'unknown)' arm(s) — qcow2_size_status never emits bare 'unknown'"
fi

# --- Test 4: verify_linux_builder's arm emits a "could not verify" message
# distinct from "size does not match" — the failure mode that motivated the
# fix. Message drift is caught here.
test_start "567.4" "verify_linux_builder unverifiable message is distinct from drift message"
verify_body=$(extract_function_body verify_linux_builder)
# Extract the block that follows wrong-size:unknown:*).
unknown_block=$(echo "$verify_body" | awk '
  /wrong-size:unknown:\*\)/ { inside = 1; next }
  inside && /;;/ { exit }
  inside { print }
')
drift_block=$(echo "$verify_body" | awk '
  /^[[:space:]]*wrong-size:\*\)[[:space:]]*$/ { inside = 1; next }
  inside && /;;/ { exit }
  inside { print }
')
# Strip comment lines from unknown_block — the comment legitimately
# references the drift wording to explain what the fix routes around.
# What we care about is that no `echo`d output (executable line) crosses
# messages.
unknown_exec=$(echo "$unknown_block" | grep -v '^\s*#')
if echo "$unknown_exec" | grep -q 'qemu-img' \
   && ! echo "$unknown_exec" | grep -q 'does not match' \
   && echo "$drift_block" | grep -q 'does not match'; then
  test_pass "unverifiable message mentions qemu-img and NOT drift; drift message intact"
else
  test_fail "message dispositions crossed — unverifiable and drift blocks overlap"
  echo "unknown_block:" >&2; echo "$unknown_block" | sed 's/^/    /' >&2
  echo "drift_block:" >&2; echo "$drift_block" | sed 's/^/    /' >&2
fi

runner_summary
