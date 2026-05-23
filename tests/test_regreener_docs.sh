#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

README="${REPO_ROOT}/framework/scripts/README.md"
GETTING="${REPO_ROOT}/GETTING-STARTED.md"

test_start "s034.5.1" "operator docs mention all three regreener primitives"
missing=0
for script in remaster-pve-installer.sh install-pve-node.sh regreen-cluster.sh; do
  if ! grep -q "$script" "$README"; then
    test_fail "${script} missing from framework/scripts/README.md"
    missing=1
  fi
done
if [[ "$missing" -eq 0 ]]; then
  test_pass "README names remaster, install, and cluster primitives"
fi

test_start "s034.5.2" "getting started keeps AMT automation optional"
if grep -qi 'generic default.*manual Proxmox' "$GETTING" && \
   grep -qi 'AMT-equipped sites can automate' "$GETTING" && \
   grep -q 'regreen-cluster.sh --config site/config.yaml --dry-run' "$GETTING"; then
  test_pass "manual install remains default and AMT regreen is documented as optional"
else
  test_fail "GETTING-STARTED.md does not document the optional AMT alternative correctly"
fi

test_start "s034.5.3" "docs state SOPS/root-password ordering for regreener"
if grep -q 'generate SOPS before running the regreener' "$GETTING" && \
   grep -q 'proxmox_api_password' "$GETTING"; then
  test_pass "SOPS before regreener is documented"
else
  test_fail "SOPS/root-password regreener contract missing"
fi

test_start "s034.5.4" "docs keep MeshCmd on executor, not PVE nodes"
if grep -q 'MeshCmd runs on that executor' "$GETTING" && \
   grep -q 'not installed by hand on Proxmox nodes' "$GETTING" && \
   grep -q 'pinned Nix host tool' "$README"; then
  test_pass "MeshCmd placement is executor-side"
else
  test_fail "MeshCmd executor-side placement missing"
fi

test_start "s034.5.5" "docs do not prescribe rejected regreener runtimes"
if rg -n 'regreen.*(Docker|OrbStack|Colima)|(Docker|OrbStack|Colima).*regreen|manual.*MeshCmd.*Proxmox|MeshCmd.*manual.*Proxmox' \
    "$README" "$GETTING" >/tmp/regreener-docs-rejected.$$ 2>/dev/null; then
  test_fail "docs mention a rejected regreener execution path"
  cat /tmp/regreener-docs-rejected.$$ >&2
else
  test_pass "no rejected regreener runtime or manual PVE MeshCmd placement found"
fi
rm -f /tmp/regreener-docs-rejected.$$

runner_summary
