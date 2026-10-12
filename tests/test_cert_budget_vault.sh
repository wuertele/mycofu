#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
CURL_LOG="${TMP_DIR}/curl.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site/sops" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/check-cert-budget.sh" "${FIXTURE_REPO}/framework/scripts/check-cert-budget.sh"
cp "${REPO_ROOT}/framework/scripts/certbot-cluster.sh" "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/check-cert-budget.sh" "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh"

cat > "${FIXTURE_REPO}/flake.nix" <<'EOF'
{
  description = "fixture";
}
EOF

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
domain: example.com
vms:
  vault_prod:
    ip: 127.0.0.1
  testapp_prod:
    vmid: 600
    ip: 192.0.2.10
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${FIXTURE_REPO}/site/sops/secrets.yaml" <<'EOF'
{}
EOF

cat > "${FIXTURE_REPO}/operator.age.key" <<'EOF'
AGE-SECRET-KEY-FAKE
EOF

cat > "${SHIM_DIR}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *'vault_prod_root_token'* ]]; then
  printf 'root-token\n'
  exit 0
fi

printf '{}\n'
EOF
chmod +x "${SHIM_DIR}/sops"

# curl shim writes the body to the -o file, prints the http_code on stdout
# (matching curl -w '%{http_code}' -o file behavior).
#
# Behavior is selected per FQDN by env vars:
#   STUB_<HOST>_HTTP   — http code (default: 200)
#   STUB_<HOST>_BODY   — JSON body to write
# where HOST is upper-cased, dot/dash replaced with underscore.
cat > "${SHIM_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${CURL_LOG}"

OUT_FILE=""
URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      OUT_FILE="$2"; shift 2
      ;;
    -w)
      shift 2
      ;;
    -H|-X|-d|--data|--data-raw|--connect-timeout|--max-time)
      shift 2
      ;;
    -sk|-s|-k|--fail-with-body|-f)
      shift 1
      ;;
    -*)
      shift 1
      ;;
    *)
      URL="$1"; shift 1
      ;;
  esac
done

# Extract FQDN from URL: .../v1/mycofu/metadata/certs/<fqdn>
FQDN="${URL##*/v1/mycofu/metadata/certs/}"
HOST_VAR="$(printf '%s' "${FQDN}" | tr '[:lower:].-' '[:upper:]__')"

HTTP_VAR="STUB_${HOST_VAR}_HTTP"
BODY_VAR="STUB_${HOST_VAR}_BODY"
HTTP="${!HTTP_VAR:-200}"
BODY="${!BODY_VAR:-}"

if [[ -n "${OUT_FILE}" ]]; then
  printf '%s' "${BODY}" > "${OUT_FILE}"
fi
printf '%s' "${HTTP}"
EOF
chmod +x "${SHIM_DIR}/curl"

iso_after_days() {
  python3 - "$1" <<'PY'
import datetime, sys
days = int(sys.argv[1])
ts = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)
print(ts.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# Default created_time format: nanosecond-precision RFC3339Nano (matches
# what real Vault KV v2 metadata returns). Tests that need a different
# format use iso_hours_ago_format.
iso_hours_ago() {
  python3 - "$1" <<'PY'
import datetime, sys
hours = int(sys.argv[1])
ts = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)
# Mimic Go's time.RFC3339Nano (nanosecond precision, Z suffix).
print(ts.strftime("%Y-%m-%dT%H:%M:%S.123456789Z"))
PY
}

# Variant that produces second-precision timestamps (what older Vault
# versions or non-Go clients might emit). Used by Test 7's "mixed format"
# regression case.
iso_hours_ago_seconds() {
  python3 - "$1" <<'PY'
import datetime, sys
hours = int(sys.argv[1])
ts = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)
print(ts.strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
}

# Construct a Vault metadata response with the given not_after,
# fingerprint, and a list of "hours-ago" timestamps for version
# creation. Defaults to nanosecond-precision created_time strings.
vault_response() {
  local not_after="$1"
  shift
  local versions="{}"
  local i=1
  for hours in "$@"; do
    local ct
    ct="$(iso_hours_ago "${hours}")"
    versions="$(printf '%s' "${versions}" | jq --arg k "${i}" --arg t "${ct}" '. + {($k): {created_time: $t, deletion_time: "", destroyed: false}}')"
    i=$((i+1))
  done
  jq -n --arg na "${not_after}" --argjson v "${versions}" \
    '{data: {custom_metadata: {not_after: $na, fingerprint: "abc123"}, versions: $v}}'
}

run_budget() {
  (
    cd "${FIXTURE_REPO}"
    PATH="${SHIM_DIR}:${PATH}" \
    CURL_LOG="${CURL_LOG}" \
    framework/scripts/check-cert-budget.sh "$@"
  )
}

# Test 1: fresh Vault cert with 0 versions in window — passes the budget.
# Note: previously a fresh not_after caused the check to skip version
# counting entirely. Per #303 acceptance criteria, the version count is
# the authoritative budget regardless of cert freshness — the fresh
# cert just means count=0 (or low), so the gate still passes.
test_start "1" "Fresh Vault cert (60d), 0 recent versions = OK"
rm -f "${CURL_LOG}"
NA="$(iso_after_days 60)"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=200
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}")"
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=200
export STUB_VAULT_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}")"
set +e
FRESH_OUTPUT="$(run_budget prod 2>&1)"
FRESH_STATUS=$?
set -e
if [[ "${FRESH_STATUS}" -eq 0 ]] && \
   grep -Fq '0/5 Vault versions in last 168h — OK' <<< "${FRESH_OUTPUT}" && \
   grep -Fq 'cert-budget: PASS' <<< "${FRESH_OUTPUT}"; then
  test_pass "fresh Vault cert with 0 versions correctly passes the budget"
else
  test_fail "fresh Vault cert with 0 versions should pass the budget"
  printf '    output:\n%s\n' "${FRESH_OUTPUT}" >&2
fi

# Test 2: missing Vault entry fails closed (replaces old SSH-fallback path).
test_start "2" "missing Vault entry fails closed, never falls back to SSH file count"
rm -f "${CURL_LOG}"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=404
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY='{"errors":[]}'
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=404
export STUB_VAULT_PROD_EXAMPLE_COM_BODY='{"errors":[]}'
set +e
MISSING_OUTPUT="$(run_budget prod 2>&1)"
MISSING_STATUS=$?
set -e
if [[ "${MISSING_STATUS}" -eq 1 ]] && \
   grep -Fq 'Vault has no entry for this FQDN — failing closed' <<< "${MISSING_OUTPUT}" && \
   grep -Fq 'cert-budget: FAILED' <<< "${MISSING_OUTPUT}"; then
  test_pass "missing Vault entry fails the check (no SSH fallback)"
else
  test_fail "missing Vault entry must fail closed; SSH fallback removed"
  printf '    output:\n%s\n' "${MISSING_OUTPUT}" >&2
fi

# Test 3: stale Vault entry — count versions in 168h window. Two recent versions = OK.
test_start "3" "Vault metadata stale + 2 recent versions = OK"
rm -f "${CURL_LOG}"
NA="$(iso_after_days 20)"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=200
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 5 30)"
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=200
export STUB_VAULT_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 5 30)"
set +e
STALE_OUTPUT="$(run_budget prod 2>&1)"
STALE_STATUS=$?
set -e
if [[ "${STALE_STATUS}" -eq 0 ]] && \
   grep -Fq '2/5 Vault versions in last 168h — OK' <<< "${STALE_OUTPUT}" && \
   grep -Fq '2 FQDN(s) checked against LE budget' <<< "${STALE_OUTPUT}"; then
  test_pass "stale entry with 2 recent versions reads as OK from Vault metadata"
else
  test_fail "stale Vault entry should consult Vault version count, not SSH"
  printf '    output:\n%s\n' "${STALE_OUTPUT}" >&2
fi

# Test 4: --no-vault now skips with warning (synonym for --ignore-cert-budget).
test_start "4" "--no-vault skips the check with warning, exits 0"
rm -f "${CURL_LOG}"
set +e
NO_VAULT_OUTPUT="$(run_budget --no-vault prod 2>&1)"
NO_VAULT_STATUS=$?
set -e
if [[ "${NO_VAULT_STATUS}" -eq 0 ]] && \
   grep -Fq 'cert budget check skipped (--no-vault)' <<< "${NO_VAULT_OUTPUT}" && \
   [[ ! -e "${CURL_LOG}" ]]; then
  test_pass "--no-vault is now a synonym for --ignore-cert-budget; no Vault calls made"
else
  test_fail "--no-vault should skip the check with warning and not call Vault"
  printf '    output:\n%s\n' "${NO_VAULT_OUTPUT}" >&2
fi

# Test 5: regression test — the wrong-oracle scenario the issue describes.
# Vault has 5 versions in window (LE quota exhausted). Old SSH oracle
# would have said OK (zero files on a freshly recreated VM). New Vault
# oracle MUST say FAILED.
test_start "5" "regression: 5 Vault versions = RATE LIMIT EXHAUSTED (the 2026-05-01 incident shape)"
rm -f "${CURL_LOG}"
NA="$(iso_after_days 5)"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=200
# 5 versions in window: 6h, 24h, 48h, 96h, 144h — all within 168h
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 6 24 48 96 144)"
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=200
export STUB_VAULT_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 6 24 48 96 144)"
set +e
EXHAUST_OUTPUT="$(run_budget prod 2>&1)"
EXHAUST_STATUS=$?
set -e
if [[ "${EXHAUST_STATUS}" -eq 1 ]] && \
   grep -Fq '5/5 Vault versions in last 168h — RATE LIMIT EXHAUSTED' <<< "${EXHAUST_OUTPUT}" && \
   grep -Fq 'cert-budget: FAILED' <<< "${EXHAUST_OUTPUT}"; then
  test_pass "5 versions in window correctly reports RATE LIMIT EXHAUSTED"
else
  test_fail "5 versions in window must FAIL the check (not WARN, not PASS)"
  printf '    output:\n%s\n' "${EXHAUST_OUTPUT}" >&2
fi

# Test 6: 4 versions in window — fail, no emergency headroom.
test_start "6" "4 Vault versions in window = FAILED (preserves 1-slot emergency headroom)"
rm -f "${CURL_LOG}"
NA="$(iso_after_days 5)"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=200
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 12 36 72 120)"
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=200
export STUB_VAULT_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 12 36 72 120)"
set +e
FOUR_OUTPUT="$(run_budget prod 2>&1)"
FOUR_STATUS=$?
set -e
if [[ "${FOUR_STATUS}" -eq 1 ]] && \
   grep -Fq '4/5 Vault versions in last 168h — FAILED' <<< "${FOUR_OUTPUT}"; then
  test_pass "4 versions in window correctly fails to preserve emergency headroom"
else
  test_fail "4 versions should fail (no emergency headroom)"
  printf '    output:\n%s\n' "${FOUR_OUTPUT}" >&2
fi

# Test 7: versions outside the window do NOT count toward budget.
test_start "7" "versions older than 168h do not count toward budget"
rm -f "${CURL_LOG}"
NA="$(iso_after_days 5)"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=200
# 7 ancient versions (>168h) + 1 recent → only the recent one counts → 1/5 OK
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 200 300 400 500 600 700 800 24)"
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=200
export STUB_VAULT_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 200 300 400 500 600 700 800 24)"
set +e
WINDOW_OUTPUT="$(run_budget prod 2>&1)"
WINDOW_STATUS=$?
set -e
if [[ "${WINDOW_STATUS}" -eq 0 ]] && \
   grep -Fq '1/5 Vault versions in last 168h — OK' <<< "${WINDOW_OUTPUT}"; then
  test_pass "ancient versions correctly excluded from rate-limit window"
else
  test_fail "only versions within 168h should count toward the budget"
  printf '    output:\n%s\n' "${WINDOW_OUTPUT}" >&2
fi

# Test 8: Vault unreachable (HTTP 000 / curl error) fails closed.
test_start "8" "Vault unreachable fails closed"
rm -f "${CURL_LOG}"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=000
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY=''
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=000
export STUB_VAULT_PROD_EXAMPLE_COM_BODY=''
set +e
UNREACHABLE_OUTPUT="$(run_budget prod 2>&1)"
UNREACHABLE_STATUS=$?
set -e
if [[ "${UNREACHABLE_STATUS}" -eq 1 ]] && \
   grep -Fq 'Vault unreachable or returned error — failing closed' <<< "${UNREACHABLE_OUTPUT}"; then
  test_pass "Vault unreachable correctly fails closed"
else
  test_fail "Vault unreachable must fail closed per destruction-safety doctrine"
  printf '    output:\n%s\n' "${UNREACHABLE_OUTPUT}" >&2
fi

# Test 9: Vault token invalid (HTTP 403) fails closed.
test_start "9" "Vault token invalid (403) fails closed"
rm -f "${CURL_LOG}"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=403
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY='{"errors":["permission denied"]}'
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=403
export STUB_VAULT_PROD_EXAMPLE_COM_BODY='{"errors":["permission denied"]}'
set +e
FORBIDDEN_OUTPUT="$(run_budget prod 2>&1)"
FORBIDDEN_STATUS=$?
set -e
if [[ "${FORBIDDEN_STATUS}" -eq 1 ]] && \
   grep -Fq 'Vault unreachable or returned error — failing closed' <<< "${FORBIDDEN_OUTPUT}"; then
  test_pass "Vault 403 correctly fails closed"
else
  test_fail "Vault 403 must fail closed (cannot determine state)"
  printf '    output:\n%s\n' "${FORBIDDEN_OUTPUT}" >&2
fi

# Test 10: regression — fresh cert + 5 versions still fails.
# Pre-fix code had a fast-path: not_after > 30d → "covered by Vault",
# skip version counting. That violated the issue's acceptance criterion
# ("fail at 4 or 5 versions in window"). The fix removes the bypass —
# the version count is authoritative regardless of cert freshness.
test_start "10" "regression: fresh cert (60d) + 5 versions in window = RATE LIMIT EXHAUSTED"
rm -f "${CURL_LOG}"
NA="$(iso_after_days 60)"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=200
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 6 24 48 96 144)"
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=200
export STUB_VAULT_PROD_EXAMPLE_COM_BODY="$(vault_response "${NA}" 6 24 48 96 144)"
set +e
FRESH_HIGH_OUTPUT="$(run_budget prod 2>&1)"
FRESH_HIGH_STATUS=$?
set -e
if [[ "${FRESH_HIGH_STATUS}" -eq 1 ]] && \
   grep -Fq '5/5 Vault versions in last 168h — RATE LIMIT EXHAUSTED' <<< "${FRESH_HIGH_OUTPUT}" && \
   ! grep -Fq 'covered by Vault' <<< "${FRESH_HIGH_OUTPUT}"; then
  test_pass "fresh-not_after fast-path is gone; version count is always checked"
else
  test_fail "fresh cert with 5 versions must still fail; the not_after bypass must not exist"
  printf '    output:\n%s\n' "${FRESH_HIGH_OUTPUT}" >&2
fi

# Test 11: regression — nanosecond-precision timestamps must parse.
# Real Vault KV v2 emits time.RFC3339Nano. jq's `fromdate` rejects
# fractional seconds; the fix strips them before parsing. All previous
# tests use nanosecond timestamps via the default vault_response shape,
# but this test asserts the exact 5-version count under that shape.
test_start "11" "regression: nanosecond-precision Vault created_time parses correctly"
rm -f "${CURL_LOG}"
NA="$(iso_after_days 5)"
# Build a body with hand-rolled nanosecond timestamps to be explicit.
NANO_BODY="$(jq -n \
  --arg na "${NA}" \
  --arg t1 "$(iso_hours_ago 1)" \
  --arg t2 "$(iso_hours_ago 12)" \
  --arg t3 "$(iso_hours_ago 36)" \
  --arg t4 "$(iso_hours_ago 80)" \
  --arg t5 "$(iso_hours_ago 160)" \
  '{data: {custom_metadata: {not_after: $na, fingerprint: "abc"}, versions: {
      "1": {created_time: $t1, deletion_time: "", destroyed: false},
      "2": {created_time: $t2, deletion_time: "", destroyed: false},
      "3": {created_time: $t3, deletion_time: "", destroyed: false},
      "4": {created_time: $t4, deletion_time: "", destroyed: false},
      "5": {created_time: $t5, deletion_time: "", destroyed: false}
    }}}')"
# Sanity: confirm the timestamps actually contain fractional seconds.
if ! grep -Fq '.123456789Z' <<< "${NANO_BODY}"; then
  test_fail "test fixture is supposed to use nanosecond timestamps"
  printf '    body:\n%s\n' "${NANO_BODY}" >&2
else
  export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=200
  export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY="${NANO_BODY}"
  export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=200
  export STUB_VAULT_PROD_EXAMPLE_COM_BODY="${NANO_BODY}"
  set +e
  NANO_OUTPUT="$(run_budget prod 2>&1)"
  NANO_STATUS=$?
  set -e
  if [[ "${NANO_STATUS}" -eq 1 ]] && \
     grep -Fq '5/5 Vault versions in last 168h — RATE LIMIT EXHAUSTED' <<< "${NANO_OUTPUT}"; then
    test_pass "nanosecond-precision created_time correctly counted (jq fromdate fix works)"
  else
    test_fail "nanosecond timestamps must parse — jq fromdate would otherwise reject fractional seconds"
    printf '    output:\n%s\n' "${NANO_OUTPUT}" >&2
  fi
fi

# Test 12: regression — versions with malformed/missing created_time
# fail closed (counted as in-window rather than silently dropped).
test_start "12" "regression: malformed created_time is counted (fail closed under uncertainty)"
rm -f "${CURL_LOG}"
NA="$(iso_after_days 5)"
# 4 well-formed in-window + 1 malformed (would silently drop in old code).
# THRESHOLD=4 trips: 4 valid + 1 malformed-treated-as-in-window = 5 total.
MAL_BODY="$(jq -n \
  --arg na "${NA}" \
  --arg t1 "$(iso_hours_ago 6)" \
  --arg t2 "$(iso_hours_ago 24)" \
  --arg t3 "$(iso_hours_ago 48)" \
  --arg t4 "$(iso_hours_ago 96)" \
  '{data: {custom_metadata: {not_after: $na, fingerprint: "abc"}, versions: {
      "1": {created_time: $t1, deletion_time: "", destroyed: false},
      "2": {created_time: $t2, deletion_time: "", destroyed: false},
      "3": {created_time: $t3, deletion_time: "", destroyed: false},
      "4": {created_time: $t4, deletion_time: "", destroyed: false},
      "5": {created_time: "garbage-not-a-timestamp", deletion_time: "", destroyed: false}
    }}}')"
export STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP=200
export STUB_TESTAPP_PROD_EXAMPLE_COM_BODY="${MAL_BODY}"
export STUB_VAULT_PROD_EXAMPLE_COM_HTTP=200
export STUB_VAULT_PROD_EXAMPLE_COM_BODY="${MAL_BODY}"
set +e
MAL_OUTPUT="$(run_budget prod 2>&1)"
MAL_STATUS=$?
set -e
if [[ "${MAL_STATUS}" -eq 1 ]] && \
   grep -Fq '5/5 Vault versions in last 168h — RATE LIMIT EXHAUSTED' <<< "${MAL_OUTPUT}"; then
  test_pass "malformed created_time is counted (fail-closed: unknown timestamp = in window)"
else
  test_fail "malformed timestamps must be counted, not silently dropped"
  printf '    output:\n%s\n' "${MAL_OUTPUT}" >&2
fi

unset STUB_TESTAPP_PROD_EXAMPLE_COM_HTTP STUB_TESTAPP_PROD_EXAMPLE_COM_BODY \
      STUB_VAULT_PROD_EXAMPLE_COM_HTTP  STUB_VAULT_PROD_EXAMPLE_COM_BODY

runner_summary
