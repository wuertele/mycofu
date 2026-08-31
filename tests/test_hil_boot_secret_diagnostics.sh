#!/usr/bin/env bash
set -euo pipefail

# Hermetic tests for the s037.0.6 failure-path diagnostic emitter (#414).
#
# The real else branch in test_hil_boot_secret_injection.sh only runs when the
# hil-boot ISO assertion flips, so without these tests the emitter would be the
# same class of untested failure-only code that hid #414 in the first place.
# These run with no Nix daemon and no secrets — the emitter is exercised
# directly under `set -euo pipefail`.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/tests/lib/hil_boot_diagnostics.sh"

# s037d.1: emitter surfaces eval_rc and captured output, and returns control
# (does not abort) under `set -euo pipefail` even though `head` closes the pipe
# early and pipefail surfaces SIGPIPE (141) from the upstream printf.
test_start "s037d.1" "emitter surfaces eval_rc + output without aborting under set -e"
big_output="$(seq 1 500 | sed 's/^/nixline /')"
reached_after=0
out="$(emit_s037_diagnostics 7 "$big_output" "$REPO_ROOT" 2>&1)"
reached_after=1
if [[ "$reached_after" -eq 1 \
      && "$out" == *"eval_rc=7"* \
      && "$out" == *"nixline 1"* \
      && "$out" == *"nixline 500"* \
      && "$out" == *"first 40 lines"* \
      && "$out" == *"last 40 lines"* ]]; then
  test_pass "surfaced eval_rc, first+last output, and returned control"
else
  test_fail "emitter did not surface expected diagnostics or aborted"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# s037d.2: empty eval_output is labelled (empty), not the misleading phantom
# "line count: 1" that `printf '%s\n' ""` would otherwise produce.
test_start "s037d.2" "empty eval_output reported as (empty)"
out="$(emit_s037_diagnostics 1 "" "$REPO_ROOT" 2>&1)"
if [[ "$out" == *"eval_output: (empty)"* && "$out" != *"line count: 1"* ]]; then
  test_pass "empty output labelled (empty) with no phantom line count"
else
  test_fail "empty output not labelled (empty)"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# s037d.3: output that fits the window is printed once (no first/last
# duplication of the same lines).
test_start "s037d.3" "short output printed once, not duplicated"
out="$(emit_s037_diagnostics 1 "$(printf 'only-line-a\nonly-line-b')" "$REPO_ROOT" 2>&1)"
if [[ "$out" == *"all 2 lines"* && "$out" != *"first 40 lines"* && "$out" != *"last 40 lines"* ]]; then
  test_pass "short output printed once"
else
  test_fail "short output was duplicated or mislabelled"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

# s037d.4: a huge single-line output is per-line length-bounded so it cannot
# explode the CI log (the "bound the output" requirement in #414).
test_start "s037d.4" "huge single-line output is length-bounded"
huge_line="$(head -c 50000 /dev/zero | tr '\0' x)"
out="$(emit_s037_diagnostics 1 "$huge_line" "$REPO_ROOT" 2>&1)"
longest="$(printf '%s\n' "$out" | awk '{ if (length > m) m = length } END { print m }')"
if [[ "$longest" -lt 5000 ]]; then
  test_pass "no emitted line exceeds the per-line cap (longest=${longest})"
else
  test_fail "per-line cap not enforced (longest=${longest})"
fi

# s037d.5: when no selected nix config keys are available, an explicit
# (unavailable) line is emitted rather than a silent gap that could be confused
# with a swallowed command failure. Shim nix to produce no matching keys.
test_start "s037d.5" "nix config fallback line emitted when no keys match"
shim_dir="$(mktemp -d)"
cat > "$shim_dir/nix" <<'SHIM'
#!/usr/bin/env bash
# Emulate a nix whose `config show` yields none of the selected keys.
echo "cores = 0"
SHIM
chmod +x "$shim_dir/nix"
out="$(PATH="$shim_dir:$PATH" emit_s037_diagnostics 1 "some output" "$REPO_ROOT" 2>&1)"
rm -rf "$shim_dir"
if [[ "$out" == *"nix config (selected keys): (unavailable)"* ]]; then
  test_pass "explicit (unavailable) fallback emitted"
else
  test_fail "no explicit nix-config fallback line"
  printf '%s\n' "$out" | sed 's/^/    /'
fi

runner_summary
