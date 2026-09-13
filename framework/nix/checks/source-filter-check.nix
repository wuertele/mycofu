# source-filter-check.nix
#
# Verifies that the shared source filter is functioning correctly.
# This check passes if and only if:
# 1. A known canary file does NOT exist in sharedSrc (filter excludes it)
# 2. Shared image inputs remain present
# 3. Host-tool package sources remain excluded
{ sharedSrc, pkgs }:

pkgs.runCommand "source-filter-check" {} ''
  echo "=== Source filter canary test ==="

  # Test 1: Canary file must NOT exist in sharedSrc
  # The canary lives at framework/checks/ (NOT framework/nix/checks/)
  # because framework/nix/ is in the source filter. framework/checks/ is not.
  CANARY="${sharedSrc}/framework/checks/CANARY_EXCLUDED_FROM_NIXSRC"
  if [ -f "$CANARY" ]; then
    echo "FAIL: Canary file exists in sharedSrc — filter is broken or bypassed"
    echo "  Path: $CANARY"
    echo "  The shared source filter must exclude this file."
    exit 1
  else
    echo "PASS: Canary file correctly excluded from sharedSrc"
  fi

  # Test 2: A file that IS in the filter should exist
  if [ ! -f "${sharedSrc}/framework/nix/modules/base.nix" ]; then
    echo "FAIL: Expected file missing from sharedSrc — filter may be too narrow"
    echo "  Expected: ${sharedSrc}/framework/nix/modules/base.nix"
    exit 1
  else
    echo "PASS: Expected nix module present in sharedSrc"
  fi

  # Test 3: Host-tool package sources are intentionally outside sharedSrc.
  # MeshCmd is installed only on opt-in executor hosts; changing its package
  # recipe must not perturb unrelated VM image source hashes.
  if [ -e "${sharedSrc}/framework/nix/pkgs/meshcmd/default.nix" ]; then
    echo "FAIL: MeshCmd host-tool package leaked into sharedSrc"
    echo "  Path: ${sharedSrc}/framework/nix/pkgs/meshcmd/default.nix"
    exit 1
  else
    echo "PASS: MeshCmd host-tool package correctly excluded from sharedSrc"
  fi

  if [ -e "${sharedSrc}/framework/nix/lib/bpg-proxmox-provider.nix" ]; then
    echo "FAIL: bpg/proxmox provider host-tool file leaked into sharedSrc"
    echo "  Path: ${sharedSrc}/framework/nix/lib/bpg-proxmox-provider.nix"
    exit 1
  else
    echo "PASS: bpg/proxmox provider host-tool file correctly excluded from sharedSrc"
  fi

  echo ""
  echo "All source filter canary tests passed."
  mkdir -p $out
  echo "passed" > $out/result
''
