#!/usr/bin/env bash
# Diagnostic emitter for the s037.0.6 "unexpected branch" of
# tests/test_hil_boot_secret_injection.sh (#414).
#
# The s037.0.6 else branch conflates two materially different failures:
#   - eval_rc=0  : `nix build` unexpectedly succeeded, and
#   - eval_rc!=0 : it failed for some reason whose output never mentions the
#                  secret.
# On pipeline #1091 that branch fired but discarded the captured `nix build`
# output, so neither case was distinguishable from the retained CI trace. This
# emitter surfaces bounded diagnostics so a future pass->fail flip is
# investigable from the job log alone.
#
# The emitter is extracted into a library so the failure path — which by nature
# never runs while the assertion passes — is unit-testable (see
# tests/test_hil_boot_secret_diagnostics.sh). An untested failure-only path is
# exactly the class of code that hid #414.
#
# Every internal command is self-guarded (`|| true`, `2>/dev/null`, and a
# GNU/BSD `stat` fallback) so the emitter cannot abort a `set -euo pipefail`
# caller before it records the failure. Callers should still wrap the call in
# `set +e ... set -e` as defence in depth. See .claude/rules/platform.md.
#
# Usage: emit_s037_diagnostics <eval_rc> <eval_output> <repo_root>

emit_s037_diagnostics() {
  local eval_rc="$1" eval_output="$2" repo_root="$3"
  local head_n=40 tail_n=40 max_line=2000 total nix_cfg

  echo "  --- s037.0.6 diagnostics (#414) ---"
  echo "  eval_rc=${eval_rc}"

  if [[ -z "$eval_output" ]]; then
    echo "  eval_output: (empty)"
  else
    total=$(printf '%s\n' "$eval_output" | wc -l | tr -d ' ' || true)
    echo "  eval_output line count: ${total}"
    # Bound the log: at most head_n+tail_n lines, and cap each emitted line at
    # max_line chars so a huge single-line / carriage-return-delimited nix
    # message cannot explode the trace. Print once when the whole output
    # already fits within the window (no first/last duplication).
    if (( total <= head_n + tail_n )); then
      echo "  eval_output (all ${total} lines):"
      { printf '%s\n' "$eval_output" | cut -c "1-${max_line}" | sed 's/^/    /'; } || true
    else
      echo "  eval_output (first ${head_n} lines):"
      { printf '%s\n' "$eval_output" | head -n "$head_n" | cut -c "1-${max_line}" | sed 's/^/    /'; } || true
      echo "  eval_output (last ${tail_n} lines):"
      { printf '%s\n' "$eval_output" | tail -n "$tail_n" | cut -c "1-${max_line}" | sed 's/^/    /'; } || true
    fi
  fi

  echo "  current user: $(id -un 2>/dev/null)"
  echo "  REPO_ROOT ownership: $(stat -c '%U:%G %n' "$repo_root" 2>/dev/null \
    || stat -f '%Su:%Sg %N' "$repo_root" 2>/dev/null)"

  # Distinguish "no selected keys / nix unavailable" from a swallowed command
  # failure by emitting an explicit fallback line when nothing matched.
  nix_cfg="$({ nix config show 2>/dev/null || nix show-config 2>/dev/null; } \
    | grep -E 'accept-flake-config|pure-eval|substituters|builders|build-dir' || true)"
  if [[ -n "$nix_cfg" ]]; then
    echo "  nix config (selected keys):"
    printf '%s\n' "$nix_cfg" | sed 's/^/    /'
  else
    echo "  nix config (selected keys): (unavailable)"
  fi

  echo "  --- end s037.0.6 diagnostics ---"
}
