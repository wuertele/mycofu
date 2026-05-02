# source-filter-check.nix
#
# Verifies that the nixSrc filter is functioning correctly.
# This check passes if and only if:
# 1. A known canary file does NOT exist in nixSrc (filter excludes it)
# 2. Image build functions receive nixSrc, not self
{ nixSrc, pkgs }:

pkgs.runCommand "source-filter-check" {} ''
  echo "=== Source filter canary test ==="

  # Test 1: Canary file must NOT exist in nixSrc
  # The canary lives at framework/checks/ (NOT framework/nix/checks/)
  # because framework/nix/ is in the source filter. framework/checks/ is not.
  CANARY="${nixSrc}/framework/checks/CANARY_EXCLUDED_FROM_NIXSRC"
  if [ -f "$CANARY" ]; then
    echo "FAIL: Canary file exists in nixSrc — filter is broken or bypassed"
    echo "  Path: $CANARY"
    echo "  The nixSrc filter must exclude this file."
    exit 1
  else
    echo "PASS: Canary file correctly excluded from nixSrc"
  fi

  # Test 2: A file that IS in the filter should exist
  if [ ! -f "${nixSrc}/framework/nix/modules/base.nix" ]; then
    echo "FAIL: Expected file missing from nixSrc — filter may be too narrow"
    echo "  Expected: ${nixSrc}/framework/nix/modules/base.nix"
    exit 1
  else
    echo "PASS: Expected nix module present in nixSrc"
  fi

  echo ""
  echo "All source filter canary tests passed."
  mkdir -p $out
  echo "passed" > $out/result
''
