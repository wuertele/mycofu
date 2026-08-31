#!/usr/bin/env bash
# Drift guard: ensure the bpg/proxmox provider version is consistent
# across the three places it's referenced.
#
#   1. framework/nix/lib/bpg-proxmox-provider.nix   (vendored binary)
#   2. framework/tofu/root/versions.tf              (constraint)
#   3. framework/tofu/root/.terraform.lock.hcl      (locked version)
#
# A future bump that updates only one or two of these would still
# evaluate locally (Nix builds the vendored binary; tofu reads the
# lock file; the constraint accepts a range) — but `tofu init`
# against the vendored mirror would fail with a checksum or version
# mismatch in a way that's harder to diagnose than this drift check.
#
# Companion test: tests/test_sovereign_tofu_init.sh — that exercises
# the full init path; this one catches drift before that runs.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NIX_DRV="$REPO_DIR/framework/nix/lib/bpg-proxmox-provider.nix"
VERSIONS_TF="$REPO_DIR/framework/tofu/root/versions.tf"
LOCK_HCL="$REPO_DIR/framework/tofu/root/.terraform.lock.hcl"

fail() { echo "[test] FAIL: $*" >&2; exit 1; }

# --- Vendored version (Nix derivation) ---
nix_version="$(awk -F'"' '/^[[:space:]]+version[[:space:]]*=/{print $2; exit}' "$NIX_DRV")"
[[ -n "$nix_version" ]] || fail "could not parse version from $NIX_DRV"
echo "[test] nix derivation version:  $nix_version"

# --- Lock file version ---
lock_version="$(awk -F'"' '/^[[:space:]]+version[[:space:]]*=/{print $2; exit}' "$LOCK_HCL")"
[[ -n "$lock_version" ]] || fail "could not parse version from $LOCK_HCL"
echo "[test] lock file version:       $lock_version"

if [[ "$nix_version" != "$lock_version" ]]; then
  fail "version drift: nix derivation has $nix_version, lock has $lock_version"
fi

# --- versions.tf constraint must accept the vendored version ---
# The constraint format is `~> N.M.0` which means ">= N.M.0, < N.(M+1).0".
# We check that the vendored major.minor matches the constraint's
# major.minor (a precise SemVer evaluator would be over-engineering
# for this guard).
constraint="$(awk -F'"' '/version[[:space:]]*=[[:space:]]*"~>/{print $2; exit}' "$VERSIONS_TF")"
[[ -n "$constraint" ]] || fail "could not parse ~> constraint from $VERSIONS_TF"
echo "[test] versions.tf constraint:  $constraint"

# Strip "~> " and trailing ".0"; compare major.minor with vendored version.
constraint_base="${constraint#~> }"
constraint_major_minor="${constraint_base%.*}"
nix_major_minor="${nix_version%.*}"
if [[ "$constraint_major_minor" != "$nix_major_minor" ]]; then
  fail "constraint major.minor ($constraint_major_minor) does not match nix version major.minor ($nix_major_minor)"
fi

echo "[test] PASS: bpg/proxmox version is consistent across the three sources."
