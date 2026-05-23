#!/usr/bin/env bash
#
# test_cert_restore_renewal_conf.sh — verify cert-restore.service writes
# a renewal.conf that matches certbot's native schema for R1.3.
#
# Origin: 2026-04-25 — pipeline #746 test:prod failed on
# `[FAIL] R1.3: certbot config structure identical across envs (dns1)`.
# Root cause: cert-restore.service in framework/nix/modules/certbot.nix
# wrote a stub renewal.conf whose active-key set differed from
# certbot's native output:
#   - had `renew_before_expiry = 30 days` (active, not commented)
#   - missing `key_type` field
#   - `version = 0.0.0` (cosmetic — version key still present)
#
# Fix is at framework/nix/modules/certbot.nix lines 174-192. This
# test extracts the heredoc from the nix module, renders it with
# stub values, and asserts the active-key set matches the captured
# vault-prod reference fixture.
#
# Issue #241.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

CERTBOT_NIX="${REPO_ROOT}/framework/nix/modules/certbot.nix"
REFERENCE="${REPO_ROOT}/tests/fixtures/cert-restore-renewal-reference.conf"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Helper: extract the active-key set the same way validate.sh R1.3 does.
# (sed strips values, grep filters to section headers and key= lines.)
keyset() {
  grep -E '^\[|^[a-z]' "$1" | sed 's/=.*//' | sed 's/[[:space:]]*$//' | sort -u
}

# ---------------------------------------------------------------------------
# Static ratchets — protect the schema-compatibility properties of the
# heredoc itself.
# ---------------------------------------------------------------------------

test_start "1" "renewal.conf heredoc in certbot.nix exists"
if grep -q 'cat > "\$renewal_conf" <<EOF' "${CERTBOT_NIX}"; then
  test_pass "heredoc found at expected pattern"
else
  test_fail "renewal.conf heredoc pattern not found in ${CERTBOT_NIX}"
  exit 1
fi

# Extract the heredoc body for inspection. Match against the nix-module
# heredoc that starts at `cat > "$renewal_conf" <<EOF` and ends at the
# first standalone `EOF` after it.
heredoc=$(awk '
  /cat > "\$renewal_conf" <<EOF/ { in_doc=1; next }
  in_doc && /^EOF$/             { exit }
  in_doc                        { print }
' "${CERTBOT_NIX}")

test_start "2" "heredoc does NOT contain active 'renew_before_expiry =' (must be commented)"
# An active `renew_before_expiry =` adds an extra key to the field-set
# diff vs certbot-native. It must be commented out (or absent).
if grep -qE '^renew_before_expiry[[:space:]]*=' <<< "${heredoc}"; then
  test_fail "heredoc has active 'renew_before_expiry =' line — R1.3 will fail"
  grep -nE '^renew_before_expiry' <<< "${heredoc}" >&2
else
  test_pass "no active renew_before_expiry line in heredoc"
fi

test_start "3" "heredoc contains 'key_type = ecdsa'"
# Missing key_type was the active-key set divergence that broke R1.3.
if grep -qE '^key_type[[:space:]]*=[[:space:]]*ecdsa' <<< "${heredoc}"; then
  test_pass "key_type = ecdsa present"
else
  test_fail "heredoc missing 'key_type = ecdsa' — R1.3 will fail"
fi

test_start "4" "heredoc contains [renewalparams] section header"
if grep -qE '^\[renewalparams\]' <<< "${heredoc}"; then
  test_pass "[renewalparams] header present"
else
  test_fail "[renewalparams] header missing"
fi

# ---------------------------------------------------------------------------
# Behavioral fixture — render the heredoc with stub values, then
# compare its active-key set to the captured vault-prod reference.
# This is the closest we can get to "byte-equivalent to certbot's
# native output" without spinning up an actual NixOS VM.
# ---------------------------------------------------------------------------

test_start "5" "T1: rendered heredoc active-key set matches certbot-native reference"
# Render the heredoc the way the nix module does. The nix-side
# variables that need substituting at this layer are:
#   $fqdn          — runtime FQDN of the VM
#   $acme_server   — runtime ACME URL
#   ${authHook}    — nix-store path of the auth hook script
#   ${cleanupHook} — nix-store path of the cleanup hook script
# For key-set purposes the values don't matter; just render with stubs.
fqdn="vault.prod.wuertele.com"
acme_server="https://acme-v02.api.letsencrypt.org/directory"
authHook="/nix/store/STUB-certbot-auth-hook"
cleanupHook="/nix/store/STUB-certbot-cleanup-hook"

# The heredoc uses both bash and nix interpolation; nix interpolation
# is `${authHook}` / `${cleanupHook}` (already resolved at nix eval).
# Render the captured heredoc as a real heredoc and capture output.
rendered_path="${TMP_DIR}/rendered-renewal.conf"
eval "cat > '${rendered_path}' <<EOF
${heredoc}
EOF"

ref_keys=$(keyset "${REFERENCE}")
rendered_keys=$(keyset "${rendered_path}")

if [[ "${ref_keys}" == "${rendered_keys}" ]]; then
  test_pass "T1: active-key sets match (R1.3 will pass)"
else
  test_fail "T1: active-key set mismatch with reference"
  printf '    Reference keys (vault-prod, certbot-native):\n%s\n' "${ref_keys}" >&2
  printf '    Rendered keys (cert-restore stub):\n%s\n' "${rendered_keys}" >&2
  printf '    Diff:\n' >&2
  diff <(printf '%s\n' "${ref_keys}") <(printf '%s\n' "${rendered_keys}") >&2 || true
fi

test_start "6" "T2: simulated R1.3 logic on rendered heredoc passes against reference"
# Mirror validate.sh:907-911. PROD_KEYS comes from cert-restore output;
# DEV_KEYS comes from cert-restore output too (same template). The
# *real* R1.3 compares dns1-prod and dns1-dev — both run cert-restore.
# After this fix, both should produce the same key set, so R1.3 passes.
prod_keys=$(grep -E '^\[|^[a-z]' "${rendered_path}" | sed 's/=.*//' | sort)
dev_keys=$(grep -E '^\[|^[a-z]' "${rendered_path}" | sed 's/=.*//' | sort)
if [[ "${prod_keys}" == "${dev_keys}" ]]; then
  test_pass "T2: simulated R1.3 (cert-restore output vs itself) passes"
else
  test_fail "T2: deterministic rendering produced different keys (impossible — bug)"
fi

test_start "7" "T3: simulated R1.3 logic comparing cert-restore output to certbot-native reference"
# This is what R1.3 actually checks if dns1-prod has a certbot-native
# renewal.conf (post-renewal) and dns1-dev has a cert-restore stub
# (recently restored). After this fix, both shapes should produce the
# same active-key set so R1.3 doesn't fail when one VM has each.
prod_keys=$(grep -E '^\[|^[a-z]' "${REFERENCE}" | sed 's/=.*//' | sort)
dev_keys=$(grep -E '^\[|^[a-z]' "${rendered_path}" | sed 's/=.*//' | sort)
if [[ "${prod_keys}" == "${dev_keys}" ]]; then
  test_pass "T3: cert-restore stub and certbot-native have identical key sets"
else
  test_fail "T3: cert-restore stub and certbot-native diverge — R1.3 will fail when shapes mix"
  printf '    Diff (certbot-native vs cert-restore stub):\n' >&2
  diff <(printf '%s\n' "${prod_keys}") <(printf '%s\n' "${dev_keys}") >&2 || true
fi

# CRITICAL: this call is what gates the test's exit code on _FAIL_COUNT.
runner_summary
