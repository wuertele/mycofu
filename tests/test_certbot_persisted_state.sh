#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
HELPER="${REPO_ROOT}/framework/scripts/certbot-persisted-state.sh"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PROD_URL="https://acme-v02.api.letsencrypt.org/directory"
STAGING_URL="https://acme-staging-v02.api.letsencrypt.org/directory"

server_path() {
  printf '%s' "${1#https://}"
}

make_account() {
  local root_dir="$1"
  local server_url="$2"
  local account_id="$3"
  local account_dir="${root_dir}/accounts/$(server_path "${server_url}")/${account_id}"

  mkdir -p "${account_dir}"
  printf '{}\n' > "${account_dir}/meta.json"
  printf '{"status":"valid"}\n' > "${account_dir}/regr.json"
  printf '{}\n' > "${account_dir}/private_key.json"
}

make_fake_cert() {
  local cert_path="$1"
  local key_path="$2"
  local issuer_cn="$3"

  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "${key_path}" \
    -out "${cert_path}" \
    -days 7 \
    -subj "/CN=${issuer_cn}" >/dev/null 2>&1
}

make_lineage() {
  local root_dir="$1"
  local fqdn="$2"
  local server_url="$3"
  local account_id="$4"
  local issuer_cn="$5"
  local live_dir="${root_dir}/live/${fqdn}"
  local renewal_file="${root_dir}/renewal/${fqdn}.conf"

  mkdir -p "${root_dir}/renewal" "${live_dir}" "${root_dir}/archive/${fqdn}"

  cat > "${renewal_file}" <<EOF
version = 2.10.0
archive_dir = ${root_dir}/archive/${fqdn}
cert = ${live_dir}/cert.pem
privkey = ${live_dir}/privkey.pem
chain = ${live_dir}/chain.pem
fullchain = ${live_dir}/fullchain.pem
server = ${server_url}
account = ${account_id}
EOF

  make_fake_cert "${live_dir}/fullchain.pem" "${live_dir}/privkey.pem" "${issuer_cn}"
  cp "${live_dir}/fullchain.pem" "${live_dir}/cert.pem"
  cp "${live_dir}/fullchain.pem" "${live_dir}/chain.pem"
}

run_helper() {
  local fixture_dir="$1"
  shift

  set +e
  OUTPUT="$(bash "${HELPER}" \
    --letsencrypt-dir "${fixture_dir}" \
    --work-dir "${fixture_dir}/work" \
    --logs-dir "${fixture_dir}/logs" \
    "$@" 2>&1)"
  STATUS=$?
  set -e
}

assert_exit() {
  local expected_status="$1"
  local label="$2"

  if [[ "${STATUS}" -eq "${expected_status}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected exit %s, got %s\n' "${expected_status}" "${STATUS}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_output_contains() {
  local needle="$1"
  local label="$2"
  if grep -Fq "${needle}" <<< "${OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    missing output: %s\n' "${needle}" >&2
    printf '    output:\n%s\n' "${OUTPUT}" >&2
  fi
}

assert_file_contains() {
  local file_path="$1"
  local needle="$2"
  local label="$3"
  if grep -Fq "${needle}" "${file_path}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected %s in %s\n' "${needle}" "${file_path}" >&2
  fi
}

test_start "2.1" "check mode flags staging lineage and Fake LE on a production fixture"
FIXTURE_CHECK="${TMP_DIR}/check"
make_account "${FIXTURE_CHECK}" "${STAGING_URL}" "staging-account"
make_lineage "${FIXTURE_CHECK}" "gitlab.prod.example.test" "${STAGING_URL}" "staging-account" "Fake LE Intermediate X1"
run_helper "${FIXTURE_CHECK}" \
  --mode check \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --fail-on-fake-leaf
assert_exit 1 "check mode fails on staging renewal lineage in production mode"
assert_output_contains "server = ${STAGING_URL}" "check mode reports the bad renewal server"
assert_output_contains "Fake LE" "check mode reports the Fake LE issuer when requested"

test_start "2.2" "repair mode rewrites renewal lineage to an existing production account"
FIXTURE_REPAIR="${TMP_DIR}/repair"
make_account "${FIXTURE_REPAIR}" "${STAGING_URL}" "staging-account"
make_account "${FIXTURE_REPAIR}" "${PROD_URL}" "prod-account"
make_lineage "${FIXTURE_REPAIR}" "vault.prod.example.test" "${STAGING_URL}" "staging-account" "Fake LE Intermediate X1"
run_helper "${FIXTURE_REPAIR}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production
assert_exit 0 "repair mode succeeds when a production account already exists"
assert_output_contains "rewrote server to ${PROD_URL}" "repair mode rewrites the renewal server"
assert_output_contains "rewrote account to prod-account" "repair mode rewrites the renewal account"
assert_output_contains "Fake LE" "repair mode warns about a Fake LE leaf but does not fail"
assert_file_contains "${FIXTURE_REPAIR}/renewal/vault.prod.example.test.conf" "server = ${PROD_URL}" "repair mode persists the production server"
assert_file_contains "${FIXTURE_REPAIR}/renewal/vault.prod.example.test.conf" "account = prod-account" "repair mode persists the production account"
run_helper "${FIXTURE_REPAIR}" \
  --mode check \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production
assert_exit 0 "check mode passes after repair when Fake LE leafs are warn-only"

test_start "2.3" "repair mode can create a missing expected account before rewriting"
FIXTURE_REGISTER="${TMP_DIR}/register"
STUB_CERTBOT="${TMP_DIR}/stub-certbot.sh"
make_account "${FIXTURE_REGISTER}" "${STAGING_URL}" "staging-account"
make_lineage "${FIXTURE_REGISTER}" "influxdb.prod.example.test" "${STAGING_URL}" "staging-account" "Fake LE Intermediate X1"
cat > "${STUB_CERTBOT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR=""
SERVER_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir)
      CONFIG_DIR="$2"
      shift 2
      ;;
    --server)
      SERVER_URL="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

ACCOUNT_DIR="${CONFIG_DIR}/accounts/${SERVER_URL#https://}/generated-prod-account"
mkdir -p "${ACCOUNT_DIR}"
printf '{}\n' > "${ACCOUNT_DIR}/meta.json"
printf '{"status":"valid"}\n' > "${ACCOUNT_DIR}/regr.json"
printf '{}\n' > "${ACCOUNT_DIR}/private_key.json"
EOF
chmod +x "${STUB_CERTBOT}"
run_helper "${FIXTURE_REGISTER}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --certbot-bin "${STUB_CERTBOT}"
assert_exit 0 "repair mode succeeds after creating the expected account"
assert_file_contains "${FIXTURE_REGISTER}/renewal/influxdb.prod.example.test.conf" "account = generated-prod-account" "repair mode uses the newly-created production account"
assert_file_contains "${FIXTURE_REGISTER}/renewal/influxdb.prod.example.test.conf" "server = ${PROD_URL}" "repair mode rewrites the server after account creation"

test_start "2.3a" "repair mode rewrites a blank account created by a restored lineage"
FIXTURE_BLANK_ACCOUNT="${TMP_DIR}/blank-account"
make_lineage "${FIXTURE_BLANK_ACCOUNT}" "testapp.prod.example.test" "${PROD_URL}" "" "R3"
run_helper "${FIXTURE_BLANK_ACCOUNT}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --certbot-bin "${STUB_CERTBOT}"
assert_exit 0 "repair mode succeeds when the renewal config has account = blank"
assert_output_contains "rewrote account to generated-prod-account" "repair mode reports the repaired blank account"
assert_file_contains "${FIXTURE_BLANK_ACCOUNT}/renewal/testapp.prod.example.test.conf" "account = generated-prod-account" "repair mode persists the generated account for a restored lineage"
run_helper "${FIXTURE_BLANK_ACCOUNT}" \
  --mode check \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production
assert_exit 0 "check mode passes after repairing a blank account"

test_start "2.4" "intentionally staging fixtures stay untouched"
FIXTURE_STAGING="${TMP_DIR}/staging"
make_account "${FIXTURE_STAGING}" "${STAGING_URL}" "staging-account"
make_lineage "${FIXTURE_STAGING}" "gitlab.prod.example.test" "${STAGING_URL}" "staging-account" "Fake LE Intermediate X1"
BEFORE_CONTENT="$(cat "${FIXTURE_STAGING}/renewal/gitlab.prod.example.test.conf")"
run_helper "${FIXTURE_STAGING}" \
  --mode repair \
  --expected-acme-url "${STAGING_URL}" \
  --expected-mode staging
assert_exit 0 "repair mode is a no-op for intentionally staging lineages"
AFTER_CONTENT="$(cat "${FIXTURE_STAGING}/renewal/gitlab.prod.example.test.conf")"
if [[ "${BEFORE_CONTENT}" == "${AFTER_CONTENT}" ]]; then
  test_pass "repair mode leaves intentionally staging renewal files untouched"
else
  test_fail "repair mode leaves intentionally staging renewal files untouched"
fi
run_helper "${FIXTURE_STAGING}" \
  --mode check \
  --expected-acme-url "${STAGING_URL}" \
  --expected-mode staging
assert_exit 0 "check mode passes for intentionally staging fixtures"

test_start "2.5" "check mode detects empty PEM files"
FIXTURE_EMPTY="${TMP_DIR}/empty-pems"
make_account "${FIXTURE_EMPTY}" "${PROD_URL}" "prod-account"
make_lineage "${FIXTURE_EMPTY}" "influxdb.prod.example.test" "${PROD_URL}" "prod-account" "R3"
# Replace the real cert with a 0-byte file
: > "${FIXTURE_EMPTY}/live/influxdb.prod.example.test/fullchain.pem"
run_helper "${FIXTURE_EMPTY}" \
  --mode check \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production
assert_exit 1 "check mode fails on empty PEM files"
assert_output_contains "EMPTY PEM FILES" "check mode reports empty PEM detection"

test_start "2.6" "repair mode removes lineage with empty PEM files"
FIXTURE_REPAIR_EMPTY="${TMP_DIR}/repair-empty"
make_account "${FIXTURE_REPAIR_EMPTY}" "${PROD_URL}" "prod-account"
make_lineage "${FIXTURE_REPAIR_EMPTY}" "influxdb.prod.example.test" "${PROD_URL}" "prod-account" "R3"
: > "${FIXTURE_REPAIR_EMPTY}/live/influxdb.prod.example.test/fullchain.pem"
: > "${FIXTURE_REPAIR_EMPTY}/archive/influxdb.prod.example.test/cert1.pem"
run_helper "${FIXTURE_REPAIR_EMPTY}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production
assert_exit 0 "repair mode succeeds when removing empty PEM lineage"
assert_output_contains "EMPTY PEM FILES" "repair mode reports empty PEM detection"
if [[ ! -d "${FIXTURE_REPAIR_EMPTY}/live/influxdb.prod.example.test" ]] && \
   [[ ! -d "${FIXTURE_REPAIR_EMPTY}/archive/influxdb.prod.example.test" ]] && \
   [[ ! -f "${FIXTURE_REPAIR_EMPTY}/renewal/influxdb.prod.example.test.conf" ]]; then
  test_pass "repair mode removes live/, archive/, and renewal config for empty PEM lineage"
else
  test_fail "repair mode removes live/, archive/, and renewal config for empty PEM lineage"
fi

runner_summary
