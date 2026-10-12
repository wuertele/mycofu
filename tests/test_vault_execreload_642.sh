#!/usr/bin/env bash
# test_vault_execreload_642.sh — #642 regression guard.
#
# vault.service runs as User=vault. systemd executes ExecReload control
# processes under the unit's credentials, so an ExecReload that shells out to
# `systemctl kill` asks PID 1 for a D-Bus KillUnit() operation it is not
# authorized to perform (root or polkit manage-units required; polkit is not
# installed on the Vault VMs). Every reload failed with "Access denied" and
# renewed certificates were never served.
#
# RCA: docs/reports/rca-2026-07-18-vault-execreload-access-denied.md

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
VAULT_NIX="${REPO_ROOT}/framework/nix/modules/vault.nix"
CERTBOT_NIX="${REPO_ROOT}/framework/nix/modules/certbot.nix"

source "${REPO_ROOT}/tests/lib/runner.sh"

test_start "642.1" "vault.nix source file is present"
if [[ -f "${VAULT_NIX}" ]]; then
  test_pass "found ${VAULT_NIX#"${REPO_ROOT}/"}"
else
  test_fail "missing ${VAULT_NIX#"${REPO_ROOT}/"}"
  runner_summary
fi

# The unit block we care about: serviceConfig of systemd.services.vault.
# Extract it so a stray ExecReload elsewhere in the file cannot satisfy the
# assertions below.
vault_service_block="$(awk '
  /systemd\.services\.vault = \{/ { in_block=1 }
  in_block { print }
  in_block && /^  \};$/ { exit }
' "${VAULT_NIX}")"

test_start "642.2" "vault.service ExecReload signals \$MAINPID directly"
if grep -Fq 'ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";' <<< "$vault_service_block"; then
  test_pass "ExecReload uses the canonical same-user kill -HUP \$MAINPID form"
else
  test_fail "vault.service ExecReload is not the kill -HUP \$MAINPID form"
fi

test_start "642.3" "nested-systemctl ExecReload form is absent from vault.service block"
# Scope to the extracted serviceConfig block AND strip comments — a future
# comment mentioning the old shape must not false-fail the guard.
vault_service_block_uncommented="$(sed 's/#.*//' <<< "$vault_service_block")"
if grep -Eq 'ExecReload[[:space:]]*=[^;]*systemctl' <<< "$vault_service_block_uncommented"; then
  test_fail "vault.service ExecReload still invokes systemctl"
else
  test_pass "no ExecReload in vault.service invokes systemctl"
fi

test_start "642.4" "vault.service is still a non-root unit (the reason this matters)"
# The #642 diagnosis rests on ExecReload running as User=vault. If someone
# removes User=, vault.service would run as root and the whole model changes
# — including the security posture. FAIL, not WARN.
if grep -Fq 'User = "vault";' <<< "$vault_service_block"; then
  test_pass "User = \"vault\" — unprivileged ExecReload semantics still apply"
else
  test_fail "vault.service no longer sets User = \"vault\"; #642 semantics no longer hold"
fi

test_start "642.5" "certbot deploy hook still uses the systemctl reload contract"
# The fix deliberately does NOT change the hook: `systemctl reload
# vault.service` is the correct external contract, and the unit owns how it
# reloads. A hook rewritten to signal Vault directly would be a regression.
if grep -Fq 'systemctl reload vault.service' "${CERTBOT_NIX}"; then
  test_pass "certbot vault reload hook unchanged"
else
  test_fail "certbot no longer calls 'systemctl reload vault.service'"
fi

runner_summary
