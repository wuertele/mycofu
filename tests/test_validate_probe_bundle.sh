#!/usr/bin/env bash
# Hermetic validate.sh fixtures for the consolidated probe bundle:
#   - SOPS and vdb Vault root-token validity via lookup-self (#34/#67/#983)
#   - GitLab runner functional health via the runners API (#35/#68/#139)
#
# Both probes are exercised through their early ONLY-gates
# (MYCOFU_VALIDATE_ONLY_VAULT_TOKEN / MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE), which
# run before any live network/storage checks. PATH shims stand in for yq, ssh,
# curl, and sops; each case drives shim behaviour through environment variables.
#
# The shims deliberately exercise the REAL code paths that adversarial review
# flagged: the ssh shim runs the probe's actual grep|sed token extraction
# against a fixture config.toml (not a canned token), and the curl OAuth shim
# only authenticates when the request used --data-urlencode with the exact
# password (so a raw-concatenation regression fails the test). Retry-recover
# cases (fail N-1 times, then succeed) verify the bounded retries that keep a
# transient blip from reddening a healthy pipeline.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

YQ_REAL_BIN="$(command -v yq || true)"
if [[ -z "${YQ_REAL_BIN}" ]]; then
  echo "test requires yq on PATH" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_CONFIG="${TMP_DIR}/config.yaml"
SHIMS_DIR="${TMP_DIR}/shims"
mkdir -p "${SHIMS_DIR}"

cat > "${FIXTURE_CONFIG}" <<'EOF'
domain: example.test
vms:
  cicd:
    ip: 10.0.0.60
  gitlab:
    ip: 10.0.0.50
  vault_dev:
    ip: 10.0.0.53
  vault_prod:
    ip: 10.0.0.54
EOF

# --- yq shim: fixed answers for the probes' expressions, real yq otherwise ---
cat > "${SHIMS_DIR}/yq" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-r" ]]; then expr="$2"; else expr="$1"; fi
case "${expr}" in
  '.vms.cicd.ip')       echo "10.0.0.60" ;;
  '.vms.gitlab.ip')     echo "10.0.0.50" ;;
  '.vms.vault_dev.ip')  echo "10.0.0.53" ;;
  '.vms.vault_prod.ip') echo "10.0.0.54" ;;
  *) exec "${YQ_REAL_BIN}" "$@" ;;
esac
SHIM
chmod +x "${SHIMS_DIR}/yq"

# --- ssh shim: serves the vdb root-token consumer path and runs the runner
#     probe's REAL extraction command against a fixture config.toml.
cat > "${SHIMS_DIR}/ssh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
remote_cmd="${@: -1}"
if [[ "$remote_cmd" == 'cat /var/lib/vault/root-token 2>/dev/null' ]]; then
  [[ "${VDB_SSH_FAIL:-0}" == "1" ]] && exit 255
  touch "${COUNTER_DIR}/vdb_read"
  printf '%s' "${VDB_ROOT_TOKEN-hvs.fixture-vdb}"
  exit 0
fi
if [[ "${SSH_FAIL:-0}" == "1" ]]; then exit 255; fi
cfg="$(mktemp)"
printf '%s\n' "${CONFIG_TOML_CONTENT:-}" > "$cfg"
out_cmd="${remote_cmd//\/etc\/gitlab-runner\/config.toml/$cfg}"
bash -c "$out_cmd"
rc=$?
rm -f "$cfg"
exit $rc
SHIM
chmod +x "${SHIMS_DIR}/ssh"

# --- sops shim: returns seeded secrets by extract key -------------------------
cat > "${SHIMS_DIR}/sops" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
key=""
for a in "$@"; do
  case "$a" in
    '["vault_dev_root_token"]')   key="vault_dev" ;;
    '["vault_prod_root_token"]')  key="vault_prod" ;;
    '["gitlab_root_password"]')   key="gitlab_pw" ;;
  esac
done
case "$key" in
  vault_dev)  printf '%s\n' "${SOPS_VAULT_DEV_TOKEN-}" ;;
  vault_prod) printf '%s\n' "${SOPS_VAULT_PROD_TOKEN-}" ;;
  gitlab_pw)  printf '%s\n' "${SOPS_GITLAB_PW-}" ;;
  *) exit 1 ;;
esac
SHIM
chmod +x "${SHIMS_DIR}/sops"

# --- curl shim: dispatch on URL substring; supports transient-recover counters
#     (COUNTER_DIR) and asserts OAuth used --data-urlencode with the exact pw.
cat > "${SHIMS_DIR}/curl" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
url=""; has_w=0
args=("$@")
vault_token=""
vdb_root_token="${VDB_ROOT_TOKEN-hvs.fixture-vdb}"
config_stdin=0
argv_has_vault_token=0
for a in "$@"; do
  case "$a" in
    https://*) url="$a" ;;
    -w) has_w=1 ;;
    "X-Vault-Token: "*) vault_token="${a#X-Vault-Token: }" ;;
    --config) ;;
    -) config_stdin=1 ;;
  esac
  [[ "$a" == *"X-Vault-Token"* ]] && argv_has_vault_token=1
done
if [[ "$config_stdin" == "1" ]]; then
  stdin_config="$(cat)"
  vault_token="$(printf '%s\n' "$stdin_config" | sed -n 's/^header = "X-Vault-Token: \(.*\)"$/\1/p' | head -1)"
fi

# nth call counter for an endpoint key (transient-recover simulation)
bump() {
  local n=1 f="${COUNTER_DIR:-/tmp}/count.$1"
  [[ -f "$f" ]] && n=$(( $(cat "$f") + 1 ))
  printf '%s' "$n" > "$f"
  printf '%s' "$n"
}

emit_code_body() {   # $1=body $2=http_code — honour -w body\ncode contract
  if [[ "$has_w" == "1" ]]; then printf '%s\n%s' "$1" "$2"; else printf '%s' "$1"; fi
}

case "$url" in
  *"/v1/auth/token/lookup-self"*)
    if [[ -f "${COUNTER_DIR}/vdb_read" ]]; then
      printf '%s' "$argv_has_vault_token" > "${COUNTER_DIR}/vdb_token_in_argv"
      if [[ "$config_stdin" == "1" && "$vault_token" == "$vdb_root_token" ]]; then
        printf '1' > "${COUNTER_DIR}/vdb_token_from_stdin_config"
      else
        printf '0' > "${COUNTER_DIR}/vdb_token_from_stdin_config"
      fi
      n="$(bump vault_vdb)"
      if [[ -n "${VDB_VAULT_FAIL_TIMES:-}" && "$n" -le "${VDB_VAULT_FAIL_TIMES}" ]]; then exit 7; fi
      if [[ "${VDB_VAULT_HTTP_CODE:-200}" == "000" ]]; then exit 7; fi
      vdb_body="${VDB_VAULT_BODY-}"
      [[ -n "$vdb_body" ]] || vdb_body='{"data":{"id":"hvs.fixture-vdb"}}'
      emit_code_body "$vdb_body" "${VDB_VAULT_HTTP_CODE:-200}"
    else
      n="$(bump vault_sops)"
      if [[ -n "${VAULT_FAIL_TIMES:-}" && "$n" -le "${VAULT_FAIL_TIMES}" ]]; then exit 7; fi
      if [[ "${VAULT_HTTP_CODE:-200}" == "000" ]]; then exit 7; fi
      emit_code_body "${VAULT_BODY:-}" "${VAULT_HTTP_CODE:-200}"
    fi ;;
  *"/oauth/token"*)
    if [[ "${OAUTH_OK:-1}" != "1" ]]; then echo '{}'; exit 0; fi
    # Require --data-urlencode AND the exact password field — a raw
    # -d "grant_type=...&password=..." regression fails this.
    have_enc=0; have_pw=0
    for a in "${args[@]}"; do
      [[ "$a" == "--data-urlencode" ]] && have_enc=1
      [[ "$a" == "password=${SOPS_GITLAB_PW-}" ]] && have_pw=1
    done
    if [[ "$have_enc" == "1" && "$have_pw" == "1" ]]; then
      echo '{"access_token":"test-oauth-token"}'
    else
      echo '{}'
    fi ;;
  *"/api/v4/runners/verify"*)
    n="$(bump verify)"
    if [[ -n "${VERIFY_FAIL_TIMES:-}" && "$n" -le "${VERIFY_FAIL_TIMES}" ]]; then exit 7; fi
    if [[ "${VERIFY_OK:-1}" == "1" ]]; then emit_code_body '{"id":2}' '200'
    else emit_code_body '{"message":"403 Forbidden"}' '403'; fi ;;
  *"/api/v4/runners/"*)
    printf '{"id":2,"status":"%s","paused":%s,"active":%s}\n' \
      "${RUNNER_STATUS:-online}" "${RUNNER_PAUSED:-false}" "${RUNNER_ACTIVE:-true}" ;;
  *) echo "curl shim: unhandled url: ${url}" >&2; exit 1 ;;
esac
SHIM
chmod +x "${SHIMS_DIR}/curl"

# run_case <only-gate-var> <env-arg> <expected-rc> <expected-substring> [KEY=VAL ...]
RUN_CASE_OUTPUT=""
RUN_CASE_VDB_ARGV_TOKEN=""
RUN_CASE_VDB_STDIN_CONFIG=""
run_case() {
  local gate="$1" envarg="$2" expected_rc="$3" expected_msg="$4"; shift 4
  local output rc cdir
  cdir="$(mktemp -d)"
  set +e
  output="$(env \
    PATH="${SHIMS_DIR}:${PATH}" \
    YQ_REAL_BIN="${YQ_REAL_BIN}" \
    SOPS_AGE_KEY_FILE="/dev/null" \
    MYCOFU_VALIDATE_CONFIG="${FIXTURE_CONFIG}" \
    COUNTER_DIR="${cdir}" \
    VDB_ROOT_TOKEN="hvs.fixture-vdb" \
    VDB_VAULT_HTTP_CODE=200 \
    VDB_VAULT_BODY='{"data":{"id":"hvs.fixture-vdb"}}' \
    "${gate}=1" \
    "$@" \
    bash "${REPO_ROOT}/framework/scripts/validate.sh" "${envarg}" 2>&1)"
  rc=$?
  set -e
  RUN_CASE_OUTPUT="$output"
  RUN_CASE_VDB_ARGV_TOKEN="$(cat "${cdir}/vdb_token_in_argv" 2>/dev/null || true)"
  RUN_CASE_VDB_STDIN_CONFIG="$(cat "${cdir}/vdb_token_from_stdin_config" 2>/dev/null || true)"
  rm -rf "${cdir}"
  if [[ "$rc" -ne "$expected_rc" ]]; then
    printf '    expected rc=%s got rc=%s\n%s\n' "$expected_rc" "$rc" "$output" >&2
    return 1
  fi
  if [[ -n "$expected_msg" && "$output" != *"$expected_msg"* ]]; then
    printf '    expected output to contain: %s\n%s\n' "$expected_msg" "$output" >&2
    return 1
  fi
  return 0
}

# Healthy config.toml the ssh shim serves; the probe's real grep|sed runs on it.
GOOD_TOML=$'[[runners]]\n  name = "cicd"\n  token = "glrt-good"\n  token_obtained_at = 2026-01-01T00:00:00Z'
# A single-quoted / oddly-spaced variant proves the hardened extraction.
ODD_TOML=$'[[runners]]\n  token =   \'glrt-oddquote\''
# config.toml present but with no token line (runner unregistered).
NOTOKEN_TOML=$'[[runners]]\n  name = "cicd"'

# ============================ Vault token probe ==============================

test_start "vt.1" "valid SOPS root token passes (lookup-self HTTP 200)"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 0 \
  "[PASS] vault-dev root token valid (lookup-self)" \
  SOPS_VAULT_DEV_TOKEN="hvs.valid" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.valid"}}'; then
  test_pass "valid token accepted"
else
  test_fail "valid token was not accepted"
fi

test_start "vt.2" "divergent token fails closed (lookup-self HTTP 403)"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "SOPS/Vault token divergence" \
  SOPS_VAULT_DEV_TOKEN="hvs.stale" VAULT_HTTP_CODE=403 VAULT_BODY=''; then
  test_pass "403 divergence is a FAIL, not a false pass"
else
  test_fail "403 divergence did not fail closed"
fi

test_start "vt.3" "HTTP 200 without .data.id is treated as invalid"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "no .data.id" \
  SOPS_VAULT_DEV_TOKEN="hvs.x" VAULT_HTTP_CODE=200 VAULT_BODY='{"errors":[]}'; then
  test_pass "proxy-style bare 200 is rejected"
else
  test_fail "bare 200 was accepted"
fi

test_start "vt.4" "missing SOPS token fails closed (not skipped)"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "could not decrypt vault_dev_root_token" \
  SOPS_VAULT_DEV_TOKEN="" VAULT_HTTP_CODE=200; then
  test_pass "undecryptable token FAILs per destruction-safety doctrine"
else
  test_fail "missing SOPS token did not fail closed"
fi

test_start "vt.5" "unreachable Vault fails closed after bounded retry"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "no definitive result after 3 attempts" \
  SOPS_VAULT_DEV_TOKEN="hvs.valid" VAULT_HTTP_CODE=000; then
  test_pass "transient/unreachable Vault FAILs, does not hang or false-pass"
else
  test_fail "unreachable Vault did not fail closed"
fi

test_start "vt.6" "transient blip then 200 recovers (bounded retry succeeds)"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 0 \
  "[PASS] vault-dev root token valid (lookup-self)" \
  SOPS_VAULT_DEV_TOKEN="hvs.valid" VAULT_FAIL_TIMES=2 VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.valid"}}'; then
  test_pass "retry recovers a healthy Vault from a transient blip (no false red)"
else
  test_fail "retry did not recover from a transient blip"
fi

# ============================= vdb token probe ==============================

test_start "vdb.1" "coupled SOPS and vdb root token passes lookup-self"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 0 \
  "[PASS] vault-dev vdb root token valid (lookup-self)" \
  SOPS_VAULT_DEV_TOKEN="hvs.coupled" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.coupled"}}' \
  VDB_ROOT_TOKEN="hvs.coupled" VDB_VAULT_HTTP_CODE=200 VDB_VAULT_BODY='{"data":{"id":"hvs.coupled"}}' &&
   [[ "$RUN_CASE_OUTPUT" == *"match=yes"* ]]; then
  test_pass "coupled vdb token accepted with matching fingerprint evidence"
else
  test_fail "coupled vdb token was not accepted as a fingerprint match"
fi

# Regression for the pipeline-2172 state: SOPS is live while vdb still holds
# the revoked token consumed preferentially by post-deploy/configure-vault.
test_start "vdb.2" "SOPS token valid but stale vdb token rejected (pipeline 2172)"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "token file /var/lib/vault/root-token on vdb is REJECTED by live Vault" \
  SOPS_VAULT_DEV_TOKEN="hvs.sops-valid" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.sops-valid"}}' \
  VDB_ROOT_TOKEN="hvs.vdb-revoked" VDB_VAULT_HTTP_CODE=403 VDB_VAULT_BODY=''; then
  test_pass "pipeline-2172 stale vdb state is a FAIL"
else
  test_fail "rejected vdb token did not fail closed"
fi

test_start "vdb.3" "absent or empty vdb token file fails closed"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "/var/lib/vault/root-token is absent or empty" \
  SOPS_VAULT_DEV_TOKEN="hvs.sops-valid" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.sops-valid"}}' \
  VDB_ROOT_TOKEN="" &&
   [[ "$RUN_CASE_OUTPUT" == *"[FAIL] vault-dev vdb root token valid (lookup-self)"* ]] &&
   [[ "$RUN_CASE_OUTPUT" != *"[SKIP] vault-dev vdb root token valid (lookup-self)"* ]]; then
  test_pass "missing vdb token file is a FAIL, never a SKIP"
else
  test_fail "missing vdb token file did not fail closed"
fi

test_start "vdb.4" "vdb root-token ssh read failure fails closed"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "could not read /var/lib/vault/root-token" \
  SOPS_VAULT_DEV_TOKEN="hvs.sops-valid" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.sops-valid"}}' \
  VDB_ROOT_TOKEN="hvs.vdb-valid" VDB_SSH_FAIL=1; then
  test_pass "unreadable vdb token file is a FAIL"
else
  test_fail "vdb ssh read failure did not fail closed"
fi

test_start "vdb.5" "transient vdb lookup blip then 200 recovers"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 0 \
  "[PASS] vault-dev vdb root token valid (lookup-self)" \
  SOPS_VAULT_DEV_TOKEN="hvs.coupled" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.coupled"}}' \
  VDB_ROOT_TOKEN="hvs.coupled" VDB_VAULT_FAIL_TIMES=2 \
  VDB_VAULT_HTTP_CODE=200 VDB_VAULT_BODY='{"data":{"id":"hvs.coupled"}}'; then
  test_pass "bounded retry recovers a healthy vdb token probe"
else
  test_fail "vdb token probe did not recover from transient failures"
fi

VDB_SENTINEL="SENTINEL_VDB_ROOT_TOKEN_MUST_NOT_LEAK"
test_start "vdb.6" "vdb token output exposes only 12-hex fingerprints"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 0 \
  "SHA-256 prefixes: vdb=" \
  SOPS_VAULT_DEV_TOKEN="$VDB_SENTINEL" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"valid-sops"}}' \
  VDB_ROOT_TOKEN="$VDB_SENTINEL" VDB_VAULT_HTTP_CODE=200 VDB_VAULT_BODY='{"data":{"id":"valid-vdb"}}' &&
   ! grep -Fq "$VDB_SENTINEL" <<< "$RUN_CASE_OUTPUT" &&
   grep -Eq 'vdb=[0-9a-f]{12} sops=[0-9a-f]{12} match=(yes|no)' <<< "$RUN_CASE_OUTPUT"; then
  test_pass "validate output contains fingerprint evidence and no vdb token material"
else
  test_fail "vdb token leaked or 12-hex fingerprint evidence was absent"
fi

test_start "vdb.7" "distinct authenticated SOPS and vdb tokens warn about interrupted rotation"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 0 \
  "[WARN] vault-dev vdb root token valid (lookup-self)" \
  SOPS_VAULT_DEV_TOKEN="hvs.sops-live" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.sops-live"}}' \
  VDB_ROOT_TOKEN="hvs.vdb-live" VDB_VAULT_HTTP_CODE=200 VDB_VAULT_BODY='{"data":{"id":"hvs.vdb-live"}}' &&
   [[ "$RUN_CASE_OUTPUT" != *"[FAIL] vault-dev vdb root token valid (lookup-self)"* ]] &&
   [[ "$RUN_CASE_OUTPUT" == *"rotation interrupted between vdb delivery and old-token revoke"* ]]; then
  test_pass "two live divergent tokens produce a WARN with the interrupted-rotation cause"
else
  test_fail "authenticated fingerprint divergence did not produce the required WARN"
fi

test_start "vdb.8" "vdb root token is carried through curl stdin config, never argv"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 0 \
  "[PASS] vault-dev vdb root token valid (lookup-self)" \
  SOPS_VAULT_DEV_TOKEN="hvs.stdin-only" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.stdin-only"}}' \
  VDB_ROOT_TOKEN="hvs.stdin-only" VDB_VAULT_HTTP_CODE=200 VDB_VAULT_BODY='{"data":{"id":"hvs.stdin-only"}}' &&
   [[ "$RUN_CASE_VDB_STDIN_CONFIG" == "1" ]] &&
   [[ "$RUN_CASE_VDB_ARGV_TOKEN" == "0" ]]; then
  test_pass "vdb lookup header came from --config stdin and no argv element contained X-Vault-Token"
else
  test_fail "vdb lookup token was absent from stdin config or exposed in argv"
fi

VDB_MULTILINE_HOSTILE=$'hvs.evil"\noutput = "/tmp/pwned"\nurl = "https://attacker.test/"\n'
# Once vdb_read exists, the curl shim writes vdb_token_in_argv unconditionally
# on entering the vdb lookup branch, so an empty value proves curl was not run.
test_start "vdb.9" "multiline VM token is rejected before curl-config interpretation"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "failed the token charset/length allowlist" \
  SOPS_VAULT_DEV_TOKEN="hvs.sops-valid" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.sops-valid"}}' \
  VDB_ROOT_TOKEN="$VDB_MULTILINE_HOSTILE" &&
   [[ "$RUN_CASE_OUTPUT" == *"[FAIL] vault-dev vdb root token valid (lookup-self)"* ]] &&
   ! grep -Fq 'output = "/tmp/pwned"' <<< "$RUN_CASE_OUTPUT" &&
   [[ -z "$RUN_CASE_VDB_ARGV_TOKEN" ]]; then
  test_pass "multiline hostile token failed closed before the vdb curl branch"
else
  test_fail "multiline hostile token reached curl or leaked into validate output"
fi

test_start "vdb.10" "single-line out-of-charset VM token is rejected before curl"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "failed the token charset/length allowlist" \
  SOPS_VAULT_DEV_TOKEN="hvs.sops-valid" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.sops-valid"}}' \
  VDB_ROOT_TOKEN='hvs.evil"token' &&
   [[ "$RUN_CASE_OUTPUT" == *"[FAIL] vault-dev vdb root token valid (lookup-self)"* ]] &&
   ! grep -Fq 'hvs.evil"token' <<< "$RUN_CASE_OUTPUT" &&
   [[ -z "$RUN_CASE_VDB_ARGV_TOKEN" ]]; then
  test_pass "single-line hostile token failed the charset guard before curl"
else
  test_fail "single-line hostile token was not rejected by the charset guard"
fi

VDB_OVERLONG_TOKEN="hvs.$(printf '%509s' '' | tr ' ' 'a')"
test_start "vdb.11" "513-byte legal-charset VM token is rejected before curl"
if run_case MYCOFU_VALIDATE_ONLY_VAULT_TOKEN dev 1 \
  "failed the token charset/length allowlist" \
  SOPS_VAULT_DEV_TOKEN="hvs.sops-valid" VAULT_HTTP_CODE=200 VAULT_BODY='{"data":{"id":"hvs.sops-valid"}}' \
  VDB_ROOT_TOKEN="$VDB_OVERLONG_TOKEN" &&
   [[ "$RUN_CASE_OUTPUT" == *"[FAIL] vault-dev vdb root token valid (lookup-self)"* ]] &&
   [[ -z "$RUN_CASE_VDB_ARGV_TOKEN" ]]; then
  test_pass "513-byte legal-charset token failed the length guard before curl"
else
  test_fail "513-byte legal-charset token was not rejected by the length guard"
fi

# =========================== Runner online probe =============================

test_start "ro.1" "registered + online + not paused passes (real token extraction)"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 0 \
  "[PASS] GitLab runner registered and online (API)" \
  CONFIG_TOML_CONTENT="${GOOD_TOML}" SOPS_GITLAB_PW="pw" OAUTH_OK=1 VERIFY_OK=1 \
  RUNNER_STATUS=online RUNNER_PAUSED=false RUNNER_ACTIVE=true; then
  test_pass "healthy runner accepted"
else
  test_fail "healthy runner was not accepted"
fi

test_start "ro.1b" "hardened extraction handles single-quoted / odd-spaced token"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 0 \
  "[PASS] GitLab runner registered and online (API)" \
  CONFIG_TOML_CONTENT="${ODD_TOML}" SOPS_GITLAB_PW="pw" OAUTH_OK=1 VERIFY_OK=1; then
  test_pass "single-quoted token parsed and verified"
else
  test_fail "hardened extraction failed on single-quoted token"
fi

test_start "ro.1c" "OAuth password with special chars authenticates (urlencode)"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 0 \
  "[PASS] GitLab runner registered and online (API)" \
  CONFIG_TOML_CONTENT="${GOOD_TOML}" SOPS_GITLAB_PW='p@ss&w+rd=x%y' OAUTH_OK=1 VERIFY_OK=1; then
  test_pass "special-character root password round-trips via --data-urlencode"
else
  test_fail "special-character password broke OAuth (urlencode regression)"
fi

test_start "ro.2" "stale token (verify 403) fails closed — the 2026-03-30 case"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 1 \
  "token REJECTED by GitLab" \
  CONFIG_TOML_CONTENT="${GOOD_TOML}" SOPS_GITLAB_PW="pw" OAUTH_OK=1 VERIFY_OK=0; then
  test_pass "active-but-403 runner is a FAIL, not 52/52 PASS"
else
  test_fail "stale runner token did not fail closed"
fi

test_start "ro.3" "valid token but offline fails closed"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 1 \
  "not online" \
  CONFIG_TOML_CONTENT="${GOOD_TOML}" SOPS_GITLAB_PW="pw" OAUTH_OK=1 VERIFY_OK=1 RUNNER_STATUS=offline; then
  test_pass "offline runner is rejected"
else
  test_fail "offline runner was not rejected"
fi

test_start "ro.4a" "online but paused=true fails closed"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 1 \
  "PAUSED" \
  CONFIG_TOML_CONTENT="${GOOD_TOML}" SOPS_GITLAB_PW="pw" OAUTH_OK=1 VERIFY_OK=1 \
  RUNNER_STATUS=online RUNNER_PAUSED=true RUNNER_ACTIVE=true; then
  test_pass "paused=true runner is rejected"
else
  test_fail "paused runner was not rejected"
fi

test_start "ro.4b" "online, paused=false, active=false fails closed (jq boolean guard)"
# Pins the active==false half independently: proves jq did not collapse the
# boolean false to empty (review P1). A regression here re-opens the lie state.
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 1 \
  "PAUSED" \
  CONFIG_TOML_CONTENT="${GOOD_TOML}" SOPS_GITLAB_PW="pw" OAUTH_OK=1 VERIFY_OK=1 \
  RUNNER_STATUS=online RUNNER_PAUSED=false RUNNER_ACTIVE=false; then
  test_pass "deactivated (active=false) runner is rejected even when paused=false"
else
  test_fail "active=false runner was not rejected (jq // empty regression?)"
fi

test_start "ro.5" "unreachable cicd (ssh fails) fails closed"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 1 \
  "could not read runner auth token" \
  SSH_FAIL=1 SOPS_GITLAB_PW="pw"; then
  test_pass "cicd-unreachable FAILs, does not skip"
else
  test_fail "unreachable cicd did not fail closed"
fi

test_start "ro.5b" "config.toml present but unregistered (no token) fails closed"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 1 \
  "could not read runner auth token" \
  CONFIG_TOML_CONTENT="${NOTOKEN_TOML}" SOPS_GITLAB_PW="pw"; then
  test_pass "unregistered runner (no token line) FAILs"
else
  test_fail "missing token line did not fail closed"
fi

test_start "ro.6" "GitLab unreachable (no OAuth token) fails closed"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 1 \
  "could not obtain GitLab OAuth token" \
  CONFIG_TOML_CONTENT="${GOOD_TOML}" SOPS_GITLAB_PW="pw" OAUTH_OK=0; then
  test_pass "GitLab-unreachable FAILs closed"
else
  test_fail "unreachable GitLab did not fail closed"
fi

test_start "ro.7" "verify transient blip then 200 recovers (bounded retry succeeds)"
if run_case MYCOFU_VALIDATE_ONLY_RUNNER_ONLINE dev 0 \
  "[PASS] GitLab runner registered and online (API)" \
  CONFIG_TOML_CONTENT="${GOOD_TOML}" SOPS_GITLAB_PW="pw" OAUTH_OK=1 VERIFY_OK=1 VERIFY_FAIL_TIMES=2; then
  test_pass "verify retry recovers a healthy runner from a transient blip (no false red)"
else
  test_fail "verify did not retry through a transient blip"
fi

runner_summary
