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
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d)
      body="${2:-}"
      shift 2
      ;;
    -H|-X|-o|-w|--max-time)
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

if [[ "${url}" == *"/v1/mycofu/data/certs/"* ]]; then
  printf '%s' "${body}" > "${DATA_PAYLOAD_FILE}"
  printf '%s' "${CURL_DATA_HTTP_CODE:-200}"
  exit 0
fi

if [[ "${url}" == *"/v1/mycofu/metadata/certs/"* ]]; then
  printf '%s' "${body}" > "${METADATA_PAYLOAD_FILE}"
  printf '%s' "${CURL_METADATA_HTTP_CODE:-200}"
  exit 0
fi

printf '%s' "${CURL_DEFAULT_HTTP_CODE:-500}"
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

runner_summary
