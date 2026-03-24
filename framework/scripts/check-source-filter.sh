#!/usr/bin/env bash
set -euo pipefail

ERRORS=0

echo "=== Check 1: No 'self' references in image-contributing nix files ==="
# Nix self references that bypass the source filter:
# - self.outPath, self + "/", ${self}, inherit (self)
# We search for nix-specific patterns to avoid false positives from
# embedded Python/shell 'self' (e.g., Python's self.send_response()).
HITS=$(grep -rn -E '\bself\.(outPath|rev|sourceInfo)|self \+ |"\$\{self\}"|inherit.*\(.*self' \
  framework/nix/ site/nix/ --include='*.nix' \
  | grep -v 'nixSrc' | grep -v '^\s*#' || true)
if [ -n "$HITS" ]; then
  echo "FAIL: Found 'self' references in image-contributing nix files:"
  echo "$HITS"
  ERRORS=$((ERRORS + 1))
else
  echo "PASS"
fi

echo ""
echo "=== Check 2: flake.nix module entry points use nixSrc ==="
# Module lists in flake.nix must use ${nixSrc}/..., not ./ or self
HITS=$(grep -n 'modules\s*=' flake.nix | grep -v nixSrc | grep -v '^\s*#' || true)
if [ -n "$HITS" ]; then
  echo "FAIL: Module entry points bypass nixSrc:"
  echo "$HITS"
  ERRORS=$((ERRORS + 1))
else
  echo "PASS"
fi

echo ""
echo "=== Check 3: No bare ./ paths to framework or site in flake.nix ==="
# Top-level ./framework/... or ./site/... in flake.nix bypass the filter.
# Note: ./flake.lock, ./. (in builtins.path), and nixSrc references are OK.
HITS=$(grep -n '"\./framework\|"\./site\| \./framework\| \./site' flake.nix \
  | grep -v nixSrc | grep -v 'builtins.path' | grep -v '^\s*#' || true)
if [ -n "$HITS" ]; then
  echo "FAIL: Bare ./ paths in flake.nix bypass source filter:"
  echo "$HITS"
  ERRORS=$((ERRORS + 1))
else
  echo "PASS"
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
  echo "FAILED: $ERRORS source filter violation(s) found."
  echo "Image hashes will change on every commit. Fix before merging."
  exit 1
else
  echo "All source filter checks passed."
fi
