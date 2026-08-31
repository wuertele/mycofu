#!/usr/bin/env bash
# Ratchet: workstation-DR scripts must NOT use floating nixpkgs sources.
#
# #564 was a latent time-bomb caused by a bare `nixpkgs#darwin.linux-builder`
# ref — that resolves through the global flake registry (nixpkgs-unstable),
# not flake.lock. Unstable dropped x86_64-darwin in 26.11 and DR broke.
# #566 filed the remaining floating refs (setup-nix-builder.sh
# test_linux_build's `import <nixpkgs>`, rebuild-cluster.sh's `nixpkgs#stdenv`
# and `<nixpkgs>` probes); this ratchet ensures they cannot regress.
#
# Two failure classes to catch:
#
# 1. `import <nixpkgs>` — the impure channel; floats even harder than the
#    global flake registry because the operator's NIX_PATH is undefined
#    for DR from a fresh workstation.
# 2. `nixpkgs#<attr>` (as a bare token, not inside a comment or string) —
#    indirect flake ref, floats on the global registry.
#
# Both classes are BENIGN when confined to comments explaining the fix, so
# the ratchet only inspects executable lines. It also skips this test file
# itself — the file mentions the patterns to document what it forbids.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

# Scripts on the workstation DR path that must not float.
SCOPED_SCRIPTS=(
  "framework/scripts/setup-nix-builder.sh"
  "framework/scripts/rebuild-cluster.sh"
  "framework/scripts/build-image.sh"
  "framework/scripts/build-all-images.sh"
)

# Strip comments and this-file lines; keep only "executable code lines".
# awk is deliberately simple: it removes leading whitespace + "# ..." lines
# and inline "# ..." trailing comments. That is imperfect for arbitrary bash
# (a `#` inside quotes is still not a comment), but the patterns we ratchet
# against never legitimately appear inside a bash-quoted string in these
# scripts.
strip_comments() {
  awk '
    { line = $0 }
    # Drop full-line comments (optionally leading whitespace).
    line ~ /^[[:space:]]*#/ { next }
    # Strip trailing comments after a bare " #" (space+hash) not preceded by
    # a backslash. This is over-approximate but safe for these scripts.
    { sub(/[[:space:]]+#[^"'"'"']*$/, "", line); print line }
  ' "$1"
}

for script in "${SCOPED_SCRIPTS[@]}"; do
  path="${REPO_ROOT}/${script}"
  [[ -f "$path" ]] || {
    test_start "566-missing" "${script}"
    test_fail "script does not exist: ${path}"
    continue
  }

  # Ratchet 1: `import <nixpkgs>` (executable lines only).
  test_start "566-a.${script}" "no 'import <nixpkgs>' in executable lines of ${script}"
  hits=$(strip_comments "$path" | grep -cE 'import[[:space:]]+<nixpkgs>' || true)
  if [[ "$hits" -eq 0 ]]; then
    test_pass "no floating <nixpkgs> impure-channel refs"
  else
    test_fail "${hits} occurrence(s) of 'import <nixpkgs>' — pin via BUILDER_NIXPKGS (#566)"
  fi

  # Ratchet 2: bare `nixpkgs#<attr>` (executable lines only). We allow
  # `"${BUILDER_NIXPKGS}#<attr>"` and similar interpolations — the check
  # matches the literal token `nixpkgs#` NOT preceded by `}` or `/`.
  test_start "566-b.${script}" "no bare 'nixpkgs#<attr>' in executable lines of ${script}"
  # POSIX ERE: assert not preceded by `}` (variable interpolation like
  # `${BUILDER_NIXPKGS}#hello`) or `/` (part of a concrete flake ref path
  # like `github:NixOS/nixpkgs/nixpkgs-26.05-darwin#stdenv` — a slash before
  # `nixpkgs` means we're inside a longer ref, not starting fresh).
  #
  # Do NOT exclude `"` or `'` — a bare `nixpkgs#foo` inside quotes
  # (`nix build "nixpkgs#hello"`) is still an executable floating ref
  # and must be caught. Codex P2 batch B review flagged the earlier
  # exclusion as a hole.
  #
  # bash grep -P is not portable across macOS/Linux, so use awk for the
  # negative-lookbehind.
  hits=$(strip_comments "$path" \
    | awk 'match($0, /nixpkgs#[A-Za-z0-9._-]+/) {
             c = substr($0, RSTART - 1, 1)
             if (c != "}" && c != "/") { print; next }
           }' \
    | wc -l | awk '{print $1}')
  if [[ "$hits" -eq 0 ]]; then
    test_pass "no bare 'nixpkgs#<attr>' floating flake refs"
  else
    test_fail "${hits} occurrence(s) of bare 'nixpkgs#<attr>' — use \${BUILDER_NIXPKGS}#<attr> (#566)"
    strip_comments "$path" | grep -nE 'nixpkgs#[A-Za-z0-9._-]+' | sed 's/^/    /' >&2 || true
  fi
done

runner_summary
