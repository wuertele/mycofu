#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
HELPER="${REPO_ROOT}/framework/scripts/certbot-persisted-state.sh"
RENEWABILITY_HELPER="${REPO_ROOT}/framework/scripts/certbot-renewability.sh"

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
manual_auth_hook = /nix/store/current-certbot-auth-hook
manual_cleanup_hook = /nix/store/current-certbot-cleanup-hook
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

test_start "2.7" "fresh canonical renewal.conf passes check mode without repair"
FIXTURE_CANONICAL="${TMP_DIR}/canonical"
make_account "${FIXTURE_CANONICAL}" "${PROD_URL}" "prod-account"
make_lineage "${FIXTURE_CANONICAL}" "vault.prod.example.test" "${PROD_URL}" "prod-account" "R3"
run_helper "${FIXTURE_CANONICAL}" \
  --mode check \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production
assert_exit 0 "check mode accepts canonical renewal.conf"

test_start "2.8" "stale generation-specific hook values are advisory under CLI override"
FIXTURE_STALE_HOOK="${TMP_DIR}/stale-hook"
make_account "${FIXTURE_STALE_HOOK}" "${PROD_URL}" "prod-account"
make_lineage "${FIXTURE_STALE_HOOK}" "vault.prod.example.test" "${PROD_URL}" "prod-account" "R3"
sed -i.bak 's#/nix/store/current-certbot-auth-hook#/nix/store/deadbeef-certbot-auth-hook#' \
  "${FIXTURE_STALE_HOOK}/renewal/vault.prod.example.test.conf"
sed -i.bak 's#/nix/store/current-certbot-cleanup-hook#/nix/store/deadbeef-certbot-cleanup-hook#' \
  "${FIXTURE_STALE_HOOK}/renewal/vault.prod.example.test.conf"
run_helper "${FIXTURE_STALE_HOOK}" \
  --mode check \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production
assert_exit 0 "persisted-state gate does not fail stale manual hook fields"

test_start "2.9" "renewability predicate returns rc=0 for healthy lineage despite stale hook values"
STUB_RENEW_CERTBOT="${TMP_DIR}/stub-renew-certbot.sh"
cat > "${STUB_RENEW_CERTBOT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat <<'OUT'
Found the following certs:
  Certificate Name: vault.prod.example.test
    Domains: vault.prod.example.test
    Expiry Date: 2026-10-01 00:00:00+00:00 (VALID: 87 days)
    Certificate Path: /etc/letsencrypt/live/vault.prod.example.test/fullchain.pem
OUT
EOF
chmod +x "${STUB_RENEW_CERTBOT}"
set +e
OUTPUT="$(CERTBOT_BIN="${STUB_RENEW_CERTBOT}" bash "${RENEWABILITY_HELPER}" --cert-name vault.prod.example.test 2>&1)"
STATUS=$?
set -e
assert_exit 0 "D2 predicate ignores persisted hook fields and accepts healthy lineage"
assert_output_contains "days_remaining=87" "D2 predicate emits days_remaining for healthy lineage"

test_start "2.10" "check mode preserves equals-containing config values while reading"
FIXTURE_EQUALS="${TMP_DIR}/equals"
make_account "${FIXTURE_EQUALS}" "${PROD_URL}" "account=id=with=equals"
make_lineage "${FIXTURE_EQUALS}" "vault.prod.example.test" "${PROD_URL}" "account=id=with=equals" "R3"
run_helper "${FIXTURE_EQUALS}" \
  --mode check \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production
assert_exit 0 "check mode accepts account values containing equals signs"

# ---------------------------------------------------------------------------
# Account-liveness probe (#525): a stateless ACME server (Pebble) recreation
# leaves vault-dev's persisted account dangling server-side. The on-disk
# account_exists check passes, but every renewal fails accountDoesNotExist.
# The --probe-account-liveness repair path validates the persisted account
# against the LIVE server and self-heals a dead account, while staying a
# strict no-op for a live account and failing closed when the server cannot
# be reached.
# ---------------------------------------------------------------------------

# Stub certbot with a controllable server-side verdict for `show_account`
# and a working `register` that mints a fresh account directory. The verdict
# is selected via the STUB_ACME_STATE environment variable.
STUB_LIVENESS_CERTBOT="${TMP_DIR}/stub-liveness-certbot.sh"
cat > "${STUB_LIVENESS_CERTBOT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SUBCMD="${1:-}"
shift || true
CONFIG_DIR=""
SERVER_URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config-dir) CONFIG_DIR="$2"; shift 2 ;;
    --server) SERVER_URL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

case "${SUBCMD}" in
  show_account)
    # A sentinel any test can flip to prove the probe was never called.
    [[ -n "${STUB_PROBE_MARKER:-}" ]] && printf 'called\n' > "${STUB_PROBE_MARKER}"
    case "${STUB_ACME_STATE:-live}" in
      live)
        printf 'Account details for %s:\n  Account URL: %s/acme/acct/live123\n' \
          "${SERVER_URL}" "${SERVER_URL%/directory}"
        exit 0
        ;;
      dead)
        # certbot's acme.messages.Error string embeds the RFC 8555 urn.
        printf 'An unexpected error occurred:\nError: urn:ietf:params:acme:error:accountDoesNotExist :: Account does not exist\n' >&2
        exit 1
        ;;
      dead_plaintext)
        # The #610 incident: `certbot show_account` rendered ONLY the plain-text
        # CLI form with no accountDoesNotExist URN token in stdout/stderr. The
        # classifier must still treat this as dead.
        printf 'An unexpected error occurred:\nAccount does not exist\n' >&2
        exit 1
        ;;
      unreachable)
        printf 'Could not connect to %s: [Errno 111] Connection refused\n' "${SERVER_URL}" >&2
        exit 1
        ;;
    esac
    ;;
  register)
    ACCOUNT_DIR="${CONFIG_DIR}/accounts/${SERVER_URL#https://}/regenerated-account"
    mkdir -p "${ACCOUNT_DIR}"
    printf '{}\n' > "${ACCOUNT_DIR}/meta.json"
    printf '{"status":"valid"}\n' > "${ACCOUNT_DIR}/regr.json"
    printf '{}\n' > "${ACCOUNT_DIR}/private_key.json"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${STUB_LIVENESS_CERTBOT}"

test_start "2.11" "repair re-registers a persisted account the live ACME server rejects"
FIXTURE_DEAD="${TMP_DIR}/dead-account"
DEAD_ACCT="bc8cb0b50200fbfa7da41a6019bdf2b3"
make_account "${FIXTURE_DEAD}" "${PROD_URL}" "${DEAD_ACCT}"
make_lineage "${FIXTURE_DEAD}" "vault.dev.example.test" "${PROD_URL}" "${DEAD_ACCT}" "R3"
STUB_ACME_STATE=dead run_helper "${FIXTURE_DEAD}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --probe-account-liveness \
  --certbot-bin "${STUB_LIVENESS_CERTBOT}"
assert_exit 0 "repair heals a server-rejected account"
assert_output_contains "accountDoesNotExist" "repair reports the server-side rejection"
assert_output_contains "re-registering" "repair announces re-registration"
assert_file_contains "${FIXTURE_DEAD}/renewal/vault.dev.example.test.conf" "account = regenerated-account" "repair rewrites account to the freshly registered one"
if [[ ! -d "${FIXTURE_DEAD}/accounts/$(server_path "${PROD_URL}")/${DEAD_ACCT}" ]]; then
  test_pass "repair removes the dangling on-disk account directory"
else
  test_fail "repair removes the dangling on-disk account directory"
fi

# #610 regression: certbot's plain-text `Account does not exist` (no URN token)
# must also classify dead. The old classifier matched only accountDoesNotExist,
# so this output returned "no verdict" and the repair failed closed, leaving
# vault-dev's dead account un-repaired and every renewal failing.
test_start "2.11-610" "repair re-registers when the server rejects with ONLY plain-text 'Account does not exist'"
FIXTURE_DEAD_PT="${TMP_DIR}/dead-account-plaintext"
make_account "${FIXTURE_DEAD_PT}" "${PROD_URL}" "${DEAD_ACCT}"
make_lineage "${FIXTURE_DEAD_PT}" "vault.dev.example.test" "${PROD_URL}" "${DEAD_ACCT}" "R3"
STUB_ACME_STATE=dead_plaintext run_helper "${FIXTURE_DEAD_PT}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --probe-account-liveness \
  --certbot-bin "${STUB_LIVENESS_CERTBOT}"
assert_exit 0 "repair heals a plain-text-rejected account"
assert_output_contains "re-registering" "repair announces re-registration for the plain-text rejection"
assert_file_contains "${FIXTURE_DEAD_PT}/renewal/vault.dev.example.test.conf" "account = regenerated-account" "repair rewrites account to the freshly registered one"
if [[ ! -d "${FIXTURE_DEAD_PT}/accounts/$(server_path "${PROD_URL}")/${DEAD_ACCT}" ]]; then
  test_pass "repair removes the dangling on-disk account directory (plain-text path)"
else
  test_fail "repair removes the dangling on-disk account directory (plain-text path)"
fi

test_start "2.11a" "repair leaves a live account byte-for-byte untouched"
FIXTURE_LIVE="${TMP_DIR}/live-account"
make_account "${FIXTURE_LIVE}" "${PROD_URL}" "live-prod-account"
make_lineage "${FIXTURE_LIVE}" "vault.prod.example.test" "${PROD_URL}" "live-prod-account" "R3"
LIVE_CONF="${FIXTURE_LIVE}/renewal/vault.prod.example.test.conf"
BEFORE_LIVE="$(cat "${LIVE_CONF}")"
STUB_ACME_STATE=live run_helper "${FIXTURE_LIVE}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --probe-account-liveness \
  --certbot-bin "${STUB_LIVENESS_CERTBOT}"
assert_exit 0 "repair succeeds for a live account"
AFTER_LIVE="$(cat "${LIVE_CONF}")"
if [[ "${BEFORE_LIVE}" == "${AFTER_LIVE}" ]]; then
  test_pass "repair is byte-for-byte no-op when the account is live (prod safety)"
else
  test_fail "repair is byte-for-byte no-op when the account is live (prod safety)"
  printf '    before:\n%s\n    after:\n%s\n' "${BEFORE_LIVE}" "${AFTER_LIVE}" >&2
fi
if grep -Fq "re-registering" <<< "${OUTPUT}"; then
  test_fail "repair does not re-register a live account"
else
  test_pass "repair does not re-register a live account"
fi

test_start "2.11b" "repair fails closed when the ACME server is unreachable"
FIXTURE_UNREACH="${TMP_DIR}/unreachable"
make_account "${FIXTURE_UNREACH}" "${PROD_URL}" "${DEAD_ACCT}"
make_lineage "${FIXTURE_UNREACH}" "vault.prod.example.test" "${PROD_URL}" "${DEAD_ACCT}" "R3"
UNREACH_CONF="${FIXTURE_UNREACH}/renewal/vault.prod.example.test.conf"
BEFORE_UNREACH="$(cat "${UNREACH_CONF}")"
STUB_ACME_STATE=unreachable run_helper "${FIXTURE_UNREACH}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --probe-account-liveness \
  --certbot-bin "${STUB_LIVENESS_CERTBOT}"
assert_exit 1 "repair fails closed on an unreachable ACME server"
assert_output_contains "failing closed" "repair reports the fail-closed decision"
AFTER_UNREACH="$(cat "${UNREACH_CONF}")"
if [[ "${BEFORE_UNREACH}" == "${AFTER_UNREACH}" ]]; then
  test_pass "repair does not mutate the renewal config on an unreachable server"
else
  test_fail "repair does not mutate the renewal config on an unreachable server"
fi
if [[ -d "${FIXTURE_UNREACH}/accounts/$(server_path "${PROD_URL}")/${DEAD_ACCT}" ]] && \
   [[ ! -d "${FIXTURE_UNREACH}/accounts/$(server_path "${PROD_URL}")/regenerated-account" ]]; then
  test_pass "repair does not re-register blind when the server cannot be reached (G4)"
else
  test_fail "repair does not re-register blind when the server cannot be reached (G4)"
fi

test_start "2.11c" "re-running repair after a heal is idempotent (no churn)"
# Reuse the healed dead-account fixture: its account is now regenerated-account,
# which the live server confirms. A second boot repair must be a strict no-op.
HEALED_CONF="${FIXTURE_DEAD}/renewal/vault.dev.example.test.conf"
BEFORE_IDEMPOTENT="$(cat "${HEALED_CONF}")"
STUB_ACME_STATE=live run_helper "${FIXTURE_DEAD}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --probe-account-liveness \
  --certbot-bin "${STUB_LIVENESS_CERTBOT}"
assert_exit 0 "second repair run succeeds"
AFTER_IDEMPOTENT="$(cat "${HEALED_CONF}")"
if [[ "${BEFORE_IDEMPOTENT}" == "${AFTER_IDEMPOTENT}" ]]; then
  test_pass "second repair run leaves the healed renewal config unchanged"
else
  test_fail "second repair run leaves the healed renewal config unchanged"
fi
if grep -Fq "re-registering" <<< "${OUTPUT}"; then
  test_fail "second repair run does not re-register the healed account"
else
  test_pass "second repair run does not re-register the healed account"
fi

test_start "2.11d" "the liveness probe is opt-in — absent the flag it never runs"
FIXTURE_OPTIN="${TMP_DIR}/optin"
make_account "${FIXTURE_OPTIN}" "${PROD_URL}" "prod-account"
make_lineage "${FIXTURE_OPTIN}" "gatus.prod.example.test" "${PROD_URL}" "prod-account" "R3"
PROBE_MARKER="${TMP_DIR}/optin-probe-marker"
rm -f "${PROBE_MARKER}"
# STUB_ACME_STATE=dead would fail loudly IF the probe ran; without the flag it must not.
STUB_ACME_STATE=dead STUB_PROBE_MARKER="${PROBE_MARKER}" run_helper "${FIXTURE_OPTIN}" \
  --mode repair \
  --expected-acme-url "${PROD_URL}" \
  --expected-mode production \
  --certbot-bin "${STUB_LIVENESS_CERTBOT}"
assert_exit 0 "repair without --probe-account-liveness ignores server-side liveness"
if [[ ! -e "${PROBE_MARKER}" ]]; then
  test_pass "show_account is never invoked without --probe-account-liveness"
else
  test_fail "show_account is never invoked without --probe-account-liveness"
fi

runner_summary
