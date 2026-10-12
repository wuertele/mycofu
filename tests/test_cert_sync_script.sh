#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

LE_DIR="${TMP_DIR}/letsencrypt"
LIVE_DIR="${LE_DIR}/live/testapp.dev.example.com"
BIN_DIR="${TMP_DIR}/bin"
TOKEN_FILE="${TMP_DIR}/vault-token"
DATA_PAYLOAD_FILE="${TMP_DIR}/data-payload.json"
METADATA_PAYLOAD_FILE="${TMP_DIR}/metadata-payload.json"
CURL_LOG="${TMP_DIR}/curl.log"
SYSTEMCTL_LOG="${TMP_DIR}/systemctl.log"

mkdir -p "${LIVE_DIR}" "${BIN_DIR}"

openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "${LIVE_DIR}/privkey.pem" \
  -out "${LIVE_DIR}/cert.pem" \
  -days 90 \
  -subj '/CN=testapp.dev.example.com' >/dev/null 2>&1
cp "${LIVE_DIR}/cert.pem" "${LIVE_DIR}/chain.pem"
cp "${LIVE_DIR}/cert.pem" "${LIVE_DIR}/fullchain.pem"

cat > "${BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

body=""
url=""
out_file=""
write_format=""
method=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)
      body="${2:-}"
      shift 2
      ;;
    -X)
      method="${2:-}"
      shift 2
      ;;
    -o)
      out_file="${2:-}"
      shift 2
      ;;
    -w)
      write_format="${2:-}"
      shift 2
      ;;
    -H|--max-time|--connect-timeout)
      shift 2
      ;;
    -s|-k|-sk)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

printf '%s\n' "${url}" >> "${CURL_LOG}"

# Determine the response body and http_code based on URL + method.
http_code=""
resp_body=""
if [[ "${url}" == *"/v1/mycofu/data/certs/"* ]]; then
  http_code="${CURL_DATA_HTTP_CODE:-200}"
  if [[ -n "${body}" ]]; then
    printf '%s' "${body}" > "${DATA_PAYLOAD_FILE}"
  fi
elif [[ "${url}" == *"/v1/mycofu/metadata/certs/"* ]]; then
  http_code="${CURL_METADATA_HTTP_CODE:-200}"
  if [[ "${method}" == "POST" ]]; then
    # POST — capture the request body that cert-sync sent.
    if [[ -n "${body}" ]]; then
      printf '%s' "${body}" > "${METADATA_PAYLOAD_FILE}"
    fi
  else
    # GET — return a synthetic response body (used by fingerprint-skip).
    resp_body="${CURL_METADATA_GET_RESPONSE:-}"
  fi
else
  http_code="${CURL_DEFAULT_HTTP_CODE:-500}"
fi

# Emit response body. If -o was supplied, write it there. Otherwise emit
# to stdout so the caller can pipe it to jq (the GET-and-parse pattern
# used by cert-sync's fingerprint-skip).
if [[ -n "${out_file}" ]]; then
  if [[ "${out_file}" != "/dev/null" ]]; then
    printf '%s' "${resp_body}" > "${out_file}"
  fi
else
  printf '%s' "${resp_body}"
fi

# When -w '%{http_code}' is requested, emit it (after any body — curl's
# real behavior is body-then-http_code on stdout when -w is used).
if [[ "${write_format}" == '%{http_code}' ]]; then
  printf '%s' "${http_code}"
fi
EOF
chmod +x "${BIN_DIR}/curl"

cat > "${BIN_DIR}/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
EOF
chmod +x "${BIN_DIR}/systemctl"

run_sync() {
  PATH="${BIN_DIR}:${PATH}" \
  CERTBOT_LETSENCRYPT_DIR="${LE_DIR}" \
  CERTBOT_FQDN="testapp.dev.example.com" \
  VAULT_ADDR="https://vault.dev.example.com:8200" \
  VAULT_TOKEN_FILE="${TOKEN_FILE}" \
  CURL_LOG="${CURL_LOG}" \
  DATA_PAYLOAD_FILE="${DATA_PAYLOAD_FILE}" \
  METADATA_PAYLOAD_FILE="${METADATA_PAYLOAD_FILE}" \
  SYSTEMCTL_LOG="${SYSTEMCTL_LOG}" \
  CURL_DATA_HTTP_CODE="${CURL_DATA_HTTP_CODE:-200}" \
  CURL_METADATA_HTTP_CODE="${CURL_METADATA_HTTP_CODE:-200}" \
  CURL_METADATA_GET_RESPONSE="${CURL_METADATA_GET_RESPONSE:-}" \
  "${REPO_ROOT}/framework/scripts/cert-sync.sh"
}

test_start "1" "successful sync posts all seven data fields and the computed fingerprint"
printf 'vault-token\n' > "${TOKEN_FILE}"
: > "${CURL_LOG}"
: > "${SYSTEMCTL_LOG}"
run_sync >/dev/null
EXPECTED_FINGERPRINT="$(
  openssl x509 -in "${LIVE_DIR}/fullchain.pem" -noout -fingerprint -sha256 \
    | sed 's/^.*=//' \
    | tr -d ':' \
    | tr '[:upper:]' '[:lower:]'
)"
DATA_FIELDS="$(
  jq -r '.data | keys[]' "${DATA_PAYLOAD_FILE}" | sort
)"
EXPECTED_FIELDS="$(cat <<'EOF'
cert
chain
fingerprint
fullchain
issued_at
not_after
privkey
EOF
)"
if [[ "${DATA_FIELDS}" == "${EXPECTED_FIELDS}" ]] && \
   [[ "$(jq -r '.data.fingerprint' "${DATA_PAYLOAD_FILE}")" == "${EXPECTED_FINGERPRINT}" ]] && \
   [[ "$(jq -r '.custom_metadata.fingerprint' "${METADATA_PAYLOAD_FILE}")" == "${EXPECTED_FINGERPRINT}" ]]; then
  test_pass "sync payload contains all required fields and the live fingerprint"
else
  test_fail "sync payload is missing fields or fingerprint data"
fi

test_start "2" "missing token exits 0 with a warning and does not hit Vault"
rm -f "${TOKEN_FILE}"
: > "${CURL_LOG}"
set +e
MISSING_OUTPUT="$(
  run_sync 2>&1
)"
MISSING_STATUS=$?
set -e
if [[ "${MISSING_STATUS}" -eq 0 ]] && \
   grep -Fq 'Vault token not available' <<< "${MISSING_OUTPUT}" && \
   [[ ! -s "${CURL_LOG}" ]]; then
  test_pass "missing token is treated as a non-fatal skip"
else
  test_fail "missing token should skip without contacting Vault"
  printf '    output:\n%s\n' "${MISSING_OUTPUT}" >&2
fi

test_start "3" "HTTP 500 exits 0 and enables the retry timer"
printf 'vault-token\n' > "${TOKEN_FILE}"
: > "${CURL_LOG}"
: > "${SYSTEMCTL_LOG}"
export CURL_DATA_HTTP_CODE=500
set +e
HTTP500_OUTPUT="$(
  run_sync 2>&1
)"
HTTP500_STATUS=$?
set -e
unset CURL_DATA_HTTP_CODE
if [[ "${HTTP500_STATUS}" -eq 0 ]] && \
   grep -Fq 'Vault sync failed' <<< "${HTTP500_OUTPUT}" && \
   grep -Fq 'enable --now cert-sync-retry.timer' "${SYSTEMCTL_LOG}"; then
  test_pass "HTTP errors trigger the retry timer without failing the hook"
else
  test_fail "HTTP 500 should enable the retry timer and exit 0"
  printf '    output:\n%s\n' "${HTTP500_OUTPUT}" >&2
fi

# Test 4: fingerprint-skip — when Vault already has the same cert, no
# data POST is performed. This is the fix for #303 follow-on: spurious
# Vault writes from the retry timer / boot path would over-count
# versions and trip check-cert-budget.sh's gate.
test_start "4" "fingerprint-skip: matching Vault fingerprint triggers no data POST"
printf 'vault-token\n' > "${TOKEN_FILE}"
: > "${CURL_LOG}"
: > "${SYSTEMCTL_LOG}"
rm -f "${DATA_PAYLOAD_FILE}" "${METADATA_PAYLOAD_FILE}"

EXPECTED_FINGERPRINT="$(
  openssl x509 -in "${LIVE_DIR}/fullchain.pem" -noout -fingerprint -sha256 \
    | sed 's/^.*=//' \
    | tr -d ':' \
    | tr '[:upper:]' '[:lower:]'
)"

# Vault returns metadata with a fingerprint matching the local cert.
export CURL_METADATA_GET_RESPONSE="$(jq -n --arg fp "${EXPECTED_FINGERPRINT}" \
  '{data: {custom_metadata: {fingerprint: $fp, not_after: "2026-12-31T00:00:00Z"}, versions: {}}}')"
set +e
SKIP_OUTPUT="$(run_sync 2>&1)"
SKIP_STATUS=$?
set -e
unset CURL_METADATA_GET_RESPONSE
if [[ "${SKIP_STATUS}" -eq 0 ]] && \
   grep -Fq 'Vault already has fingerprint' <<< "${SKIP_OUTPUT}" && \
   [[ ! -e "${DATA_PAYLOAD_FILE}" ]] && \
   [[ ! -e "${METADATA_PAYLOAD_FILE}" ]] && \
   grep -Fq 'stop cert-sync-retry.timer' "${SYSTEMCTL_LOG}"; then
  test_pass "matching fingerprint causes the script to skip both POSTs"
else
  test_fail "matching fingerprint should skip the data POST entirely"
  printf '    output:\n%s\n' "${SKIP_OUTPUT}" >&2
  printf '    DATA_PAYLOAD_FILE exists: %s\n' "$([[ -e ${DATA_PAYLOAD_FILE} ]] && echo yes || echo no)" >&2
  printf '    METADATA_PAYLOAD_FILE exists: %s\n' "$([[ -e ${METADATA_PAYLOAD_FILE} ]] && echo yes || echo no)" >&2
fi

# Test 5: fingerprint-mismatch — when Vault has a different fingerprint,
# the data POST proceeds normally (this is the genuine LE issuance
# path).
test_start "5" "fingerprint-mismatch: differing Vault fingerprint triggers normal POST"
printf 'vault-token\n' > "${TOKEN_FILE}"
: > "${CURL_LOG}"
: > "${SYSTEMCTL_LOG}"
rm -f "${DATA_PAYLOAD_FILE}" "${METADATA_PAYLOAD_FILE}"

# Vault returns a different fingerprint — fix should write the fresh cert.
export CURL_METADATA_GET_RESPONSE='{"data": {"custom_metadata": {"fingerprint": "0000000000000000000000000000000000000000000000000000000000000000", "not_after": "2026-12-31T00:00:00Z"}, "versions": {}}}'
set +e
MISMATCH_OUTPUT="$(run_sync 2>&1)"
MISMATCH_STATUS=$?
set -e
unset CURL_METADATA_GET_RESPONSE
if [[ "${MISMATCH_STATUS}" -eq 0 ]] && \
   grep -Fq 'synced testapp.dev.example.com to Vault' <<< "${MISMATCH_OUTPUT}" && \
   [[ -e "${DATA_PAYLOAD_FILE}" ]] && \
   [[ "$(jq -r '.data.fingerprint' "${DATA_PAYLOAD_FILE}")" == "${EXPECTED_FINGERPRINT}" ]]; then
  test_pass "differing fingerprint triggers data POST with new fingerprint"
else
  test_fail "differing fingerprint should still post the new cert"
  printf '    output:\n%s\n' "${MISMATCH_OUTPUT}" >&2
fi

# Test 6: fingerprint-skip — no Vault entry yet (empty metadata) means
# we still POST. This is the first-issuance / cert-storage-backfill
# path.
test_start "6" "no Vault fingerprint yet: data POST proceeds (first-issuance path)"
printf 'vault-token\n' > "${TOKEN_FILE}"
: > "${CURL_LOG}"
: > "${SYSTEMCTL_LOG}"
rm -f "${DATA_PAYLOAD_FILE}" "${METADATA_PAYLOAD_FILE}"

# Vault returns empty body (no metadata at all yet).
export CURL_METADATA_GET_RESPONSE=''
set +e
FIRST_OUTPUT="$(run_sync 2>&1)"
FIRST_STATUS=$?
set -e
unset CURL_METADATA_GET_RESPONSE
if [[ "${FIRST_STATUS}" -eq 0 ]] && \
   grep -Fq 'synced testapp.dev.example.com to Vault' <<< "${FIRST_OUTPUT}" && \
   [[ -e "${DATA_PAYLOAD_FILE}" ]]; then
  test_pass "missing Vault fingerprint correctly triggers a fresh POST"
else
  test_fail "no Vault entry should still result in a POST (first-issuance)"
  printf '    output:\n%s\n' "${FIRST_OUTPUT}" >&2
fi

runner_summary
