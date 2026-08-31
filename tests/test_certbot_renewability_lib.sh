#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
HELPER="${REPO_ROOT}/framework/scripts/certbot-renewability.sh"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

STUB_CERTBOT="${TMP_DIR}/certbot"
cat > "${STUB_CERTBOT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${STUB_CERTBOT_CASE:-valid}" in
  valid|stale_hook)
    cat <<'OUT'
Found the following certs:
  Certificate Name: vault.prod.example.test
    Domains: vault.prod.example.test
    Expiry Date: 2026-10-01 00:00:00+00:00 (VALID: 87 days)
    Certificate Path: /etc/letsencrypt/live/vault.prod.example.test/fullchain.pem
OUT
    ;;
  near)
    cat <<'OUT'
Found the following certs:
  Certificate Name: vault.prod.example.test
    Domains: vault.prod.example.test
    Expiry Date: 2026-07-18 00:00:00+00:00 (VALID: 13 days)
    Certificate Path: /etc/letsencrypt/live/vault.prod.example.test/fullchain.pem
OUT
    ;;
  skipped)
    cat <<'OUT'
Renewal configuration file /etc/letsencrypt/renewal/vault.prod.example.test.conf is broken. The error was: fullchain mismatch. Skipping.
OUT
    ;;
  errored)
    cat <<'OUT'
vault.prod.example.test lineage errored while parsing renewal configuration
OUT
    ;;
  failed)
    echo "certbot internal failure" >&2
    exit 42
    ;;
  not_found)
    echo "No certs found."
    ;;
  *)
    echo "unknown STUB_CERTBOT_CASE=${STUB_CERTBOT_CASE:-}" >&2
    exit 99
    ;;
esac
EOF
chmod +x "${STUB_CERTBOT}"

run_probe() {
  local cert_name="${1:-vault.prod.example.test}"
  set +e
  OUTPUT="$(CERTBOT_BIN="${STUB_CERTBOT}" bash "${HELPER}" --cert-name "${cert_name}" 2>&1)"
  STATUS=$?
  set -e
}

assert_exit() {
  local expected="$1"
  local label="$2"
  if [[ "$STATUS" -eq "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected exit %s, got %s\n%s\n' "$expected" "$STATUS" "$OUTPUT" >&2
  fi
}

assert_output_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq "$needle" <<< "$OUTPUT"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    missing output: %s\n%s\n' "$needle" "$OUTPUT" >&2
  fi
}

test_start "A1.1" "valid lineage returns rc=0 with days_remaining and near_expiry=false"
export STUB_CERTBOT_CASE=valid
run_probe
assert_exit 0 "valid lineage is renewable"
assert_output_contains "days_remaining=87" "valid lineage emits days_remaining"
assert_output_contains "near_expiry=false" "valid lineage emits near_expiry=false"

test_start "A1.2" "near_expiry toggles below the 14-day boundary"
export STUB_CERTBOT_CASE=near
run_probe
assert_exit 0 "near-expiry lineage is still renewable"
assert_output_contains "days_remaining=13" "near-expiry fixture emits days_remaining"
assert_output_contains "near_expiry=true" "near-expiry fixture emits near_expiry=true"

test_start "A1.3" "broken fullchain/skipped lineage returns rc=1 reason=cert-skipped"
export STUB_CERTBOT_CASE=skipped
run_probe
assert_exit 1 "skipped lineage is unrenewable"
assert_output_contains "reason=cert-skipped" "skipped lineage reason is surfaced"

test_start "A1.4" "errored lineage returns rc=1 reason=cert-errored"
export STUB_CERTBOT_CASE=errored
run_probe
assert_exit 1 "errored lineage is unrenewable"
assert_output_contains "reason=cert-errored" "errored lineage reason is surfaced"

test_start "A1.5" "certbot command failure returns rc=3 without leaking subprocess rc"
export STUB_CERTBOT_CASE=failed
run_probe
assert_exit 3 "certbot command failure is unknowable"
assert_output_contains "reason=certbot-command-failed" "certbot failure reason is surfaced"
assert_output_contains "certbot_exit=42" "original certbot rc is diagnostic stdout only"

test_start "A1.6" "unknown/no certs state returns rc=3"
export STUB_CERTBOT_CASE=not_found
run_probe
assert_exit 3 "missing cert is unknowable"
assert_output_contains "reason=cert-not-found" "missing cert reason is surfaced"

test_start "A1.7" "stale persisted hook fields are ignored by the predicate"
export STUB_CERTBOT_CASE=stale_hook
run_probe
assert_exit 0 "healthy lineage stays renewable regardless of stale renewal.conf hook fields"

test_start "A1.8" "zero-match diagnostic greps do not leak rc=1 under set -euo pipefail"
export STUB_CERTBOT_CASE=valid
run_probe
assert_exit 0 "valid fixture with no error markers remains rc=0"

runner_summary
