#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
CERTBOT_NIX="${REPO_ROOT}/framework/nix/modules/certbot.nix"

source "${REPO_ROOT}/tests/lib/runner.sh"

renew_block="$(awk '
  /certbotRenewScript = pkgs.writeShellScript "certbot-renew"/ { in_block=1 }
  in_block { print }
  in_block && /^  '\'''\'';$/ { exit }
' "${CERTBOT_NIX}")"

test_start "A5.1" "certbotRenewScript passes current-generation manual auth hook on CLI"
if grep -Fq -- '--manual-auth-hook "${authHook}"' <<< "$renew_block"; then
  test_pass "renew script contains --manual-auth-hook from authHook"
else
  test_fail "renew script missing --manual-auth-hook from authHook"
fi

test_start "A5.2" "certbotRenewScript passes current-generation manual cleanup hook on CLI"
if grep -Fq -- '--manual-cleanup-hook "${cleanupHook}"' <<< "$renew_block"; then
  test_pass "renew script contains --manual-cleanup-hook from cleanupHook"
else
  test_fail "renew script missing --manual-cleanup-hook from cleanupHook"
fi

test_start "A5.3" "vault-backed clients still pass cert-sync deploy hook"
if grep -Fq -- '--deploy-hook \"${certSyncTool}/bin/cert-sync\"' <<< "$renew_block"; then
  test_pass "cert-sync deploy hook branch is preserved"
else
  test_fail "cert-sync deploy hook branch is missing"
fi

test_start "A5.4" "vdb-persisted Vault branch passes Vault reload deploy hook"
if grep -Fq -- '--deploy-hook \"${vaultReloadHook}\"' <<< "$renew_block" &&
   grep -Fq 'systemctl reload vault.service' "${CERTBOT_NIX}"; then
  test_pass "Vault reload deploy hook branch is present"
else
  test_fail "Vault reload deploy hook branch is missing"
fi

test_start "A5.5" "old renew_hook boot-repair normalization is removed"
if ! grep -Eq 'EXPECTED_RENEW_HOOK|repair_renew_hook' "${CERTBOT_NIX}"; then
  test_pass "old renew_hook rewrite path is absent"
else
  test_fail "old renew_hook rewrite path is still present"
fi

runner_summary
