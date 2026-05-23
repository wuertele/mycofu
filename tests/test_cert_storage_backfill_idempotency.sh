#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FP_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
FP_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
VALID_NOT_AFTER="2099-01-01T00:00:00Z"
EXPIRED_NOT_AFTER="2000-01-01T00:00:00Z"

CASE_DIR=""
CASE_RECORDS=""
CASE_STATE=""
CASE_PEMS=""
CASE_LOG=""
CASE_SSH_LOG=""
CASE_OUTPUT=""
CASE_STATUS=""
CASE_FAIL_DATA_POST_FOR=""

setup_case() {
  local name="$1"

  CASE_DIR="${TMP_DIR}/${name}"
  CASE_RECORDS="${CASE_DIR}/records.tsv"
  CASE_STATE="${CASE_DIR}/vault-state"
  CASE_PEMS="${CASE_DIR}/pems"
  CASE_LOG="${CASE_DIR}/vault-writes.log"
  CASE_SSH_LOG="${CASE_DIR}/ssh-reads.log"
  CASE_OUTPUT="${CASE_DIR}/output.log"
  CASE_FAIL_DATA_POST_FOR=""

  mkdir -p \
    "${CASE_DIR}/framework/scripts" \
    "${CASE_DIR}/site" \
    "${CASE_DIR}/shims" \
    "${CASE_STATE}" \
    "${CASE_PEMS}"

  : > "${CASE_RECORDS}"
  : > "${CASE_LOG}"
  : > "${CASE_SSH_LOG}"
  printf 'fixture\n' > "${CASE_DIR}/flake.nix"

  cp "${REPO_ROOT}/framework/scripts/cert-storage-backfill.sh" \
    "${CASE_DIR}/framework/scripts/cert-storage-backfill.sh"
  chmod +x "${CASE_DIR}/framework/scripts/cert-storage-backfill.sh"

  cat > "${CASE_DIR}/site/config.yaml" <<'EOF'
vms:
  vault_dev:
    ip: 10.0.0.10
EOF
  cat > "${CASE_DIR}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  cat > "${CASE_DIR}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

certbot_cluster_cert_storage_records() {
  cat "${CERT_BACKFILL_RECORDS}"
}
EOF
  chmod +x "${CASE_DIR}/framework/scripts/certbot-cluster.sh"

  cat > "${CASE_DIR}/shims/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'root-token\n'
EOF
  chmod +x "${CASE_DIR}/shims/sops"

  cat > "${CASE_DIR}/shims/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"
if [[ "${remote_cmd}" =~ /etc/letsencrypt/live/([^/]+)/([^/]+\.pem) ]]; then
  if [[ -n "${SSH_READ_LOG:-}" ]]; then
    printf '%s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" >> "${SSH_READ_LOG}"
  fi
  pem_file="${PEM_DIR}/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  [[ -s "${pem_file}" ]] || exit 1
  cat "${pem_file}"
  exit 0
fi

exit 1
EOF
  chmod +x "${CASE_DIR}/shims/ssh"

  cat > "${CASE_DIR}/shims/openssl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

in_file=""
want_enddate=0
want_fingerprint=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -in)
      in_file="$2"
      shift 2
      ;;
    -enddate)
      want_enddate=1
      shift
      ;;
    -fingerprint)
      want_fingerprint=1
      shift
      ;;
    *)
      shift
      ;;
  esac
done

content=""
if [[ -n "${in_file}" && -f "${in_file}" ]]; then
  content="$(cat "${in_file}")"
fi

if [[ "${want_enddate}" -eq 1 ]]; then
  printf 'notAfter=Jan  1 00:00:00 2099 GMT\n'
  exit 0
fi

if [[ "${want_fingerprint}" -eq 1 ]]; then
  if [[ "${content}" == *"CERT_B"* ]]; then
    printf 'sha256 Fingerprint=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB\n'
  else
    printf 'sha256 Fingerprint=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n'
  fi
  exit 0
fi

exit 0
EOF
  chmod +x "${CASE_DIR}/shims/openssl"

  cat > "${CASE_DIR}/shims/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method="GET"
data=""
write_code=0
url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -X)
      method="$2"
      shift 2
      ;;
    -d)
      data="$2"
      shift 2
      ;;
    -w)
      write_code=1
      shift 2
      ;;
    -o|-H)
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

fqdn="${url##*/certs/}"
state_file="${VAULT_STATE_DIR}/${fqdn}.json"

if [[ "${method}" == "POST" && "${url}" == *"/mycofu/data/certs/"* ]]; then
  printf 'DATA %s\n' "${fqdn}" >> "${VAULT_WRITE_LOG}"
  if [[ "${FAIL_DATA_POST_FOR:-}" == "${fqdn}" || "${FAIL_DATA_POST_FOR:-}" == "*" ]]; then
    [[ "${write_code}" -eq 1 ]] && printf '500'
    exit 0
  fi
  [[ "${write_code}" -eq 1 ]] && printf '200'
  exit 0
fi

if [[ "${method}" == "POST" && "${url}" == *"/mycofu/metadata/certs/"* ]]; then
  printf 'METADATA %s\n' "${fqdn}" >> "${VAULT_WRITE_LOG}"
  version=1
  if [[ -f "${state_file}" ]]; then
    current="$(jq -r '.data.current_version // 0' "${state_file}")"
    version=$((current + 1))
  fi
  custom="$(printf '%s' "${data}" | jq -c '.custom_metadata')"
  jq -n --argjson custom "${custom}" --argjson version "${version}" \
    '{data: {custom_metadata: $custom, current_version: $version}}' > "${state_file}"
  [[ "${write_code}" -eq 1 ]] && printf '200'
  exit 0
fi

if [[ "${method}" == "GET" && "${url}" == *"/mycofu/metadata/certs/"* ]]; then
  if [[ -f "${state_file}" ]]; then
    cat "${state_file}"
  else
    printf '{"data":{}}\n'
  fi
  exit 0
fi

printf '{}\n'
EOF
  chmod +x "${CASE_DIR}/shims/curl"

  cat > "${CASE_DIR}/shims/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "${CASE_DIR}/shims/sleep"
}

add_record() {
  local fqdn="$1"
  printf 'vm\tmodule\t10.0.0.20\t101\t%s\tinfra\n' "${fqdn}" >> "${CASE_RECORDS}"
}

add_pems() {
  local fqdn="$1"
  local marker="$2"
  local pem_dir="${CASE_PEMS}/${fqdn}"

  mkdir -p "${pem_dir}"
  printf '%s\n' "${marker}" > "${pem_dir}/cert.pem"
  printf '%s\n' "${marker}" > "${pem_dir}/fullchain.pem"
  printf 'PRIVATE KEY %s\n' "${marker}" > "${pem_dir}/privkey.pem"
  printf 'CHAIN %s\n' "${marker}" > "${pem_dir}/chain.pem"
}

prepopulate_metadata() {
  local fqdn="$1"
  local fingerprint="$2"
  local not_after="$3"
  local version="${4:-1}"

  jq -n \
    --arg fingerprint "${fingerprint}" \
    --arg not_after "${not_after}" \
    --argjson version "${version}" \
    '{data: {custom_metadata: {fingerprint: $fingerprint, not_after: $not_after}, current_version: $version}}' \
    > "${CASE_STATE}/${fqdn}.json"
}

run_backfill() {
  set +e
  (
    export PATH="${CASE_DIR}/shims:${PATH}"
    export CERT_BACKFILL_RECORDS="${CASE_RECORDS}"
    export VAULT_STATE_DIR="${CASE_STATE}"
    export PEM_DIR="${CASE_PEMS}"
    export VAULT_WRITE_LOG="${CASE_LOG}"
    export SSH_READ_LOG="${CASE_SSH_LOG}"
    export FAIL_DATA_POST_FOR="${CASE_FAIL_DATA_POST_FOR}"
    export VAULT_ROOT_TOKEN="root-token"
    export CERT_BACKFILL_WAIT_SECONDS=0
    export CERT_BACKFILL_WAIT_INTERVAL_SECONDS=0
    cd "${CASE_DIR}"
    framework/scripts/cert-storage-backfill.sh dev
  ) > "${CASE_OUTPUT}" 2>&1
  CASE_STATUS=$?
  set -e
}

count_data_writes() {
  grep -c '^DATA ' "${CASE_LOG}" 2>/dev/null || true
}

count_metadata_writes() {
  grep -c '^METADATA ' "${CASE_LOG}" 2>/dev/null || true
}

count_ssh_reads() {
  local fqdn="$1"
  local pem_name="$2"

  grep -c "^${fqdn} ${pem_name}$" "${CASE_SSH_LOG}" 2>/dev/null || true
}

assert_output_has() {
  local needle="$1"
  local label="$2"

  if grep -qF "${needle}" "${CASE_OUTPUT}"; then
    test_pass "${label}"
  else
    test_fail "${label}"
    sed 's/^/    /' "${CASE_OUTPUT}" >&2
  fi
}

test_start "C1" "missing metadata writes one FQDN"
setup_case "c1"
add_record "one.dev.example.test"
add_pems "one.dev.example.test" "CERT_A"
run_backfill
[[ "${CASE_STATUS}" -eq 0 ]] && test_pass "missing metadata exits 0" || test_fail "missing metadata exits 0"
[[ "$(count_data_writes)" == "1" ]] && test_pass "missing metadata writes exactly one data version" || test_fail "missing metadata writes exactly one data version"
assert_output_has "seeded 1, skipped 0, failures 0" "missing metadata summary"

test_start "C2" "matching fingerprint and valid not_after skips"
setup_case "c2"
add_record "current.dev.example.test"
add_pems "current.dev.example.test" "CERT_A"
prepopulate_metadata "current.dev.example.test" "${FP_A}" "${VALID_NOT_AFTER}"
run_backfill
[[ "${CASE_STATUS}" -eq 0 ]] && test_pass "matching metadata exits 0" || test_fail "matching metadata exits 0"
[[ "$(count_data_writes)" == "0" ]] && test_pass "matching metadata performs no data write" || test_fail "matching metadata performs no data write"
assert_output_has "seeded 0, skipped 1, failures 0" "matching metadata summary"

test_start "C3" "different fingerprint updates"
setup_case "c3"
add_record "changed.dev.example.test"
add_pems "changed.dev.example.test" "CERT_A"
prepopulate_metadata "changed.dev.example.test" "${FP_B}" "${VALID_NOT_AFTER}"
run_backfill
[[ "${CASE_STATUS}" -eq 0 ]] && test_pass "different fingerprint exits 0" || test_fail "different fingerprint exits 0"
[[ "$(count_data_writes)" == "1" ]] && test_pass "different fingerprint writes a new version" || test_fail "different fingerprint writes a new version"

test_start "C4" "expired not_after updates"
setup_case "c4"
add_record "expired.dev.example.test"
add_pems "expired.dev.example.test" "CERT_A"
prepopulate_metadata "expired.dev.example.test" "${FP_A}" "${EXPIRED_NOT_AFTER}"
run_backfill
[[ "${CASE_STATUS}" -eq 0 ]] && test_pass "expired metadata exits 0" || test_fail "expired metadata exits 0"
[[ "$(count_data_writes)" == "1" ]] && test_pass "expired metadata writes a new version" || test_fail "expired metadata writes a new version"

test_start "C5" "partial population skips present entries and seeds missing entries"
setup_case "c5"
for i in 1 2 3 4 5 6 7 8 9; do
  fqdn="partial-${i}.dev.example.test"
  add_record "${fqdn}"
  add_pems "${fqdn}" "CERT_A"
  if [[ "${i}" -le 4 ]]; then
    prepopulate_metadata "${fqdn}" "${FP_A}" "${VALID_NOT_AFTER}"
  fi
done
run_backfill
[[ "${CASE_STATUS}" -eq 0 ]] && test_pass "partial population exits 0" || test_fail "partial population exits 0"
[[ "$(count_data_writes)" == "5" ]] && test_pass "partial population seeds exactly five missing entries" || test_fail "partial population seeds exactly five missing entries"
assert_output_has "seeded 5, skipped 4, failures 0" "partial population summary"

test_start "C6" "partial PEM lineage failure is bounded per FQDN and continues"
setup_case "c6"
add_record "partial-lineage.dev.example.test"
add_record "good.dev.example.test"
add_pems "partial-lineage.dev.example.test" "CERT_A"
rm -f "${CASE_PEMS}/partial-lineage.dev.example.test/fullchain.pem"
add_pems "good.dev.example.test" "CERT_A"
run_backfill
[[ "${CASE_STATUS}" -ne 0 ]] && test_pass "partial lineage exits non-zero overall" || test_fail "partial lineage exits non-zero overall"
[[ "$(count_data_writes)" == "1" ]] && test_pass "partial lineage continues to next FQDN" || test_fail "partial lineage continues to next FQDN"
[[ "$(count_ssh_reads "partial-lineage.dev.example.test" "cert.pem")" == "1" ]] && test_pass "partial lineage reads cert.pem once" || test_fail "partial lineage reads cert.pem once"
[[ "$(count_ssh_reads "partial-lineage.dev.example.test" "fullchain.pem")" == "1" ]] && test_pass "partial lineage attempts first missing PEM once" || test_fail "partial lineage attempts first missing PEM once"
[[ "$(count_ssh_reads "partial-lineage.dev.example.test" "privkey.pem")" == "0" ]] && test_pass "partial lineage does not spend another wait on privkey.pem" || test_fail "partial lineage does not spend another wait on privkey.pem"
[[ "$(count_ssh_reads "partial-lineage.dev.example.test" "chain.pem")" == "0" ]] && test_pass "partial lineage does not spend another wait on chain.pem" || test_fail "partial lineage does not spend another wait on chain.pem"
assert_output_has "seeded 1, skipped 0, failures 1" "partial lineage summary"

test_start "C7" "cert-storage-backfill.sh does not invoke certbot"
backfill_src="$(
  sed 's/#.*//' "${REPO_ROOT}/framework/scripts/cert-storage-backfill.sh" |
    grep -Ev '^[[:space:]]*source[[:space:]]+".*/certbot-cluster\.sh"[[:space:]]*$' || true
)"
# The only allowed "certbot" token is the sourced inventory helper filename;
# strip that declaration and comments before rejecting certbot/ACME execution.
if ! grep -E '\bcertbot\b' <<< "${backfill_src}" >/dev/null; then
  test_pass "no certbot token on executable backfill lines"
else
  test_fail "no certbot token on executable backfill lines"
fi
if ! grep -iE 'acme-v0[12]\.api\.|/directory' <<< "${backfill_src}" >/dev/null; then
  test_pass "no direct ACME directory calls"
else
  test_fail "no direct ACME directory calls"
fi

test_start "C8" "stale threshold uses named constant"
if grep -q '^STALE_THRESHOLD_DAYS=' "${REPO_ROOT}/framework/scripts/cert-storage-backfill.sh"; then
  test_pass "STALE_THRESHOLD_DAYS constant present"
else
  test_fail "STALE_THRESHOLD_DAYS constant present"
fi
if ! grep -E 'validity_days_remaining .* -gt 30\b|remaining_days > 30\b' "${REPO_ROOT}/framework/scripts/cert-storage-backfill.sh" >/dev/null; then
  test_pass "comparison does not inline literal 30"
else
  test_fail "comparison does not inline literal 30"
fi

test_start "C9" "data POST failure does not write metadata or poison later runs"
setup_case "c9"
add_record "partial-write.dev.example.test"
add_pems "partial-write.dev.example.test" "CERT_A"
CASE_FAIL_DATA_POST_FOR="partial-write.dev.example.test"
run_backfill
[[ "${CASE_STATUS}" -ne 0 ]] && test_pass "data POST failure exits non-zero" || test_fail "data POST failure exits non-zero"
[[ "$(count_data_writes)" == "1" ]] && test_pass "data POST failure attempts one data write" || test_fail "data POST failure attempts one data write"
[[ "$(count_metadata_writes)" == "0" ]] && test_pass "data POST failure does not write metadata" || test_fail "data POST failure does not write metadata"
CASE_FAIL_DATA_POST_FOR=""
run_backfill
[[ "${CASE_STATUS}" -eq 0 ]] && test_pass "subsequent run exits 0 after data write recovers" || test_fail "subsequent run exits 0 after data write recovers"
[[ "$(count_data_writes)" == "2" ]] && test_pass "subsequent run retries data instead of skipping" || test_fail "subsequent run retries data instead of skipping"
[[ "$(count_metadata_writes)" == "1" ]] && test_pass "subsequent run writes metadata only after data succeeds" || test_fail "subsequent run writes metadata only after data succeeds"
assert_output_has "seeded 1, skipped 0, failures 0" "subsequent run seeds instead of skipping"

runner_summary
