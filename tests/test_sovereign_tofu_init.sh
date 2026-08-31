#!/usr/bin/env bash
# Sovereignty regression test for OpenTofu provider acquisition.
#
# Verifies that `tofu init` succeeds with all outbound HTTP/HTTPS
# blocked, using the real framework/tofu/root/versions.tf and
# .terraform.lock.hcl (not a synthetic minimal test root). If init
# succeeds while every external host is unreachable AND the installed
# provider's binary resolves into /nix/store, the bpg/proxmox
# provider is being served entirely from the local nix-store via the
# filesystem_mirror config produced by
# framework/nix/lib/bpg-proxmox-provider.nix — the cluster is
# sovereign on that dependency.
#
# Self-contained: builds the provider derivation via `nix build`
# rather than depending on TF_CLI_CONFIG_FILE being pre-set by the
# host's NixOS module. This lets the test run on the MR pipeline's
# OLD cicd runner (before the new image is deployed) and on the
# operator workstation in `nix develop`, without divergent setup.
#
# We block outbound calls by pointing HTTPS_PROXY / HTTP_PROXY at a
# port with no listener; any attempt to reach github.com or
# registry.opentofu.org will fail immediately. `tofu init` should
# never try because filesystem_mirror in TF_CLI_CONFIG_FILE serves
# the provider locally. We also exercise `tofu init -upgrade=true`
# explicitly: that's the path that would normally reach the registry
# for version discovery, and it must stay sovereign too.
#
# Run via:
#   bash tests/test_sovereign_tofu_init.sh

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOFU_ROOT="$REPO_DIR/framework/tofu/root"

fail() { echo "[test] FAIL: $*" >&2; exit 1; }

# --- Build provider derivation locally -----------------------------
# `nix build .#bpg-proxmox-provider` produces the same nix-store path
# that the cicd image's TF_CLI_CONFIG_FILE points at. Building it
# explicitly here decouples the test from the cicd image deploy state.
echo "[test] building bpg-proxmox-provider derivation..."
PROVIDER_OUT="$(nix build --no-link --print-out-paths "$REPO_DIR#bpg-proxmox-provider" 2>&1 | tail -1)"
[[ -n "$PROVIDER_OUT" ]] || fail "nix build produced empty output path"
[[ -d "$PROVIDER_OUT/libexec/terraform-providers" ]] \
  || fail "provider derivation missing libexec/terraform-providers (got: $PROVIDER_OUT)"
[[ -f "$PROVIDER_OUT/etc/terraformrc" ]] \
  || fail "provider derivation missing etc/terraformrc (got: $PROVIDER_OUT)"

export TF_CLI_CONFIG_FILE="$PROVIDER_OUT/etc/terraformrc"

# Defense-in-depth: ensure no stale plugin cache leaks through.
unset TF_PLUGIN_CACHE_DIR

# Hard block on outbound HTTP/HTTPS: 127.0.0.1:9 is the discard port,
# nothing listens there. NO_PROXY emptied so the proxy applies even
# to loopback names.
export HTTP_PROXY="http://127.0.0.1:9"
export HTTPS_PROXY="http://127.0.0.1:9"
export http_proxy="http://127.0.0.1:9"
export https_proxy="http://127.0.0.1:9"
export NO_PROXY=""
export no_proxy=""

# --- Run init against the REAL repo root (lock file + versions.tf) --
TEST_DIR="$(mktemp -d -t sovereign-tofu-init.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

# Copy the real versions.tf and lock file so we exercise the production
# pin (~> 0.101.0) and the production .terraform.lock.hcl with its
# multi-platform h1: hashes — not a synthetic minimal root.
cp "$TOFU_ROOT/versions.tf" "$TEST_DIR/versions.tf"
cp "$TOFU_ROOT/.terraform.lock.hcl" "$TEST_DIR/.terraform.lock.hcl"
cd "$TEST_DIR"

run_init() {
  local label="$1"; shift
  echo "[test] tofu init $label (proxy=$HTTPS_PROXY)..."
  if ! tofu init -input=false -backend=false "$@" >"$TEST_DIR/$label.out" 2>&1; then
    echo "--- $label output ---" >&2
    cat "$TEST_DIR/$label.out" >&2
    fail "tofu init $label failed; check whether init tried the registry"
  fi
}

# Case 1: install from the lock file (the normal pipeline path).
run_init lock-respecting

# Verify the installed provider resolves into the expected nix-store
# derivation. Without this positive assertion, the test would still
# pass if any default plugin cache (TF_PLUGIN_CACHE_DIR fallback,
# host-installed providers, etc.) happened to contain a working copy.
INSTALLED_PROVIDER_DIR=".terraform/providers/registry.opentofu.org/bpg/proxmox"
[[ -d "$INSTALLED_PROVIDER_DIR" ]] \
  || fail "tofu init succeeded but $INSTALLED_PROVIDER_DIR is missing"

# Tofu installs from a filesystem_mirror by symlinking the platform
# directory directly into /nix/store. Walk the version subtree and
# find anything that's a symlink — its target must resolve under
# $PROVIDER_OUT to prove provenance. Without this positive check the
# test would still pass if any default plugin cache (e.g. a stale
# host-installed copy) happened to satisfy the lock.
sovereign_link=""
while IFS= read -r path; do
  resolved="$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$path")"
  case "$resolved" in
    "$PROVIDER_OUT"/*)
      sovereign_link="$path -> $resolved"
      break
      ;;
  esac
done < <(find "$INSTALLED_PROVIDER_DIR" -type l)

if [[ -z "$sovereign_link" ]]; then
  echo "[test] DEBUG: installed provider tree:" >&2
  find "$INSTALLED_PROVIDER_DIR" -maxdepth 5 -printf '%p -> %l\n' 2>/dev/null \
    || ls -laR "$INSTALLED_PROVIDER_DIR" >&2
  fail "no symlink under $INSTALLED_PROVIDER_DIR resolves into $PROVIDER_OUT — provider came from somewhere else"
fi
echo "[test] provenance OK: $sovereign_link"

# Case 2: re-run with -upgrade=true to prove discovery is also
# sovereign. -upgrade normally consults the registry for newer
# matching versions; with our filesystem_mirror as the ONLY
# installation method, it must stay offline.
rm -rf .terraform .terraform.lock.hcl
cp "$TOFU_ROOT/versions.tf" "$TEST_DIR/versions.tf"
run_init upgrade -upgrade=true

echo "[test] PASS: tofu init is sovereign (lock + upgrade paths)."
echo "[test]       Provider served from $PROVIDER_OUT"
echo "[test]       via TF_CLI_CONFIG_FILE filesystem_mirror."
