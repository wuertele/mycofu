#!/usr/bin/env bash
# V2.4: rotate-gitlab-root-password.sh full-driver hermetic fixture.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

ROTATE_SCRIPT="${REPO_ROOT}/framework/scripts/rotate-gitlab-root-password.sh"
CONFIGURE_SCRIPT="${REPO_ROOT}/framework/scripts/configure-gitlab.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

RUN_OUTPUT=""
RUN_STATUS=0
CONFIGURE_OUTPUT=""
CONFIGURE_STATUS=0
UTC_STAMP="20260726T121000Z"
OLD_PASSWORD="SENTINEL_GITLAB_OLD_PASSWORD"
LEGACY_NEW_PASSWORD="SENTINEL+GITLAB+NEW+PASSWORD"
NEW_PASSWORD="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
OLD_TOKEN="SENTINEL_GITLAB_OLD_TOKEN"

first_line_number() {
  local pattern="$1"
  local file="$2"
  grep -Fn "$pattern" "$file" | head -1 | cut -d: -f1 || true
}

last_line_number() {
  local pattern="$1"
  local file="$2"
  grep -Fn "$pattern" "$file" | tail -1 | cut -d: -f1 || true
}

tree_contains() {
  local needle="$1"
  local dir="$2"
  grep -R -Fq "$needle" "$dir" 2>/dev/null
}

runbook_prove_negative_guard_passes() {
  local evidence="$1"
  grep -Fxq 'old_password_prove_negative_verdict=PASS' "$evidence" &&
    grep -Fxq 'expected_http_status=400_or_401' "$evidence"
}

gitlab_temp_files_remaining() {
  local fixture="$1"
  find "${fixture}/escrow" -type f -name '.gitlab-*' -print 2>/dev/null | sort
}

make_fixture() {
  local name="$1"
  local fixture="${TMP_DIR}/${name}"
  local repo="${fixture}/repo"
  local shims="${fixture}/shims"

  mkdir -p \
    "${repo}/framework/scripts" \
    "${repo}/site/sops" \
    "$shims" \
    "${fixture}/home" \
    "${fixture}/escrow" \
    "${fixture}/state"

  cp "$ROTATE_SCRIPT" "${repo}/framework/scripts/rotate-gitlab-root-password.sh"
  chmod +x "${repo}/framework/scripts/rotate-gitlab-root-password.sh"
  printf '%s\n' 'fixture flake' > "${repo}/flake.nix"
  printf '%s\n' 'sops: fixture' > "${repo}/site/sops/secrets.yaml"
  printf '%s' "$OLD_PASSWORD" > "${fixture}/state/old_password"
  printf '%s' "$OLD_PASSWORD" > "${fixture}/state/sops_password"
  printf '%s' "$OLD_PASSWORD" > "${fixture}/state/db_password"
  printf '%s' 'SENTINEL_GITLAB_INITIAL_PASSWORD' > "${fixture}/state/initial_password"
  printf '%s\n' "$LEGACY_NEW_PASSWORD" > "${fixture}/state/new_password_base64"
  printf '%s' "$NEW_PASSWORD" > "${fixture}/state/new_password_hex"
  # Issue #802 fix: resolve_operative_key requires either an ambient
  # SOPS_AGE_KEY_FILE or a canonical operator.age.key in the repo, and
  # asserts the key decrypts SECRETS_FILE before any mutation. The sops
  # shim ignores the key contents, so a placeholder key file is sufficient
  # for the fixture — its purpose is to satisfy the resolver's fail-closed
  # existence + decrypt-probe checks.
  printf '%s\n' 'STUB_AGE_KEY' > "${repo}/operator.age.key"
  chmod 0400 "${repo}/operator.age.key"

  cat > "${repo}/site/config.yaml" <<'EOF'
domain: example.invalid
vms:
  gitlab:
    ip: 10.0.0.50
    vmid: 150
cicd:
  project_name: infra
EOF

  cat > "${repo}/framework/scripts/backup-now.sh" <<'EOF'
#!/usr/bin/env bash
pin_out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pin-out) pin_out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$pin_out" ]] || { echo "backup-now shim: missing --pin-out" >&2; exit 1; }
mkdir -p "$(dirname "$pin_out")"
printf 'backup-now|%s\n' "$pin_out" >> "$EVENT_LOG"
printf '{"pins":{"150":"pbs-nas:backup/vm/150/2026-07-26T12:10:00Z"}}\n' > "$pin_out"
EOF
  chmod +x "${repo}/framework/scripts/backup-now.sh"

  cat > "${shims}/yq" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
  .vms.gitlab.ip) printf '%s\n' '10.0.0.50' ;;
  .vms.gitlab.vmid) printf '%s\n' '150' ;;
  .domain) printf '%s\n' 'example.invalid' ;;
  .cicd.project_name) printf '%s\n' 'infra' ;;
  *) echo "yq shim: unexpected expression: ${2:-}" >&2; exit 1 ;;
esac
EOF
  chmod +x "${shims}/yq"

  cat > "${shims}/sops" <<'EOF'
#!/usr/bin/env bash
# Issue #802 fixture requirement: every sops call must carry an explicit
# SOPS_AGE_KEY_FILE=<existing file>. Reject any invocation whose ambient
# env is missing or stale — that reproduces the mid-run failure signature.
set -euo pipefail
require_key() {
  key="${SOPS_AGE_KEY_FILE:-}"
  [[ -n "$key" && -s "$key" ]] || { echo "sops shim: SOPS_AGE_KEY_FILE unset or stale: '${key}'" >&2; exit 1; }
}
if [[ "${1:-}" == "-d" ]]; then
  require_key
  if [[ "${2:-}" == "--extract" && "${3:-}" == '["gitlab_root_password"]' ]]; then
    printf '%s\n' 'sops-decrypt|gitlab_root_password' >> "$EVENT_LOG"
    cat "${STATE_DIR}/sops_password"
    exit 0
  fi
  # Whole-file decrypt used by resolve_operative_key's key-material probe.
  printf 'sops-decrypt|whole-file\n' >> "$EVENT_LOG"
  printf '%s\n' 'STUB_DECRYPTED_YAML'
  exit 0
fi
if [[ "${1:-}" == "set" && "${2:-}" == "--value-file" && "${4:-}" == '["gitlab_root_password"]' && "${5:-}" == "/dev/stdin" ]]; then
  require_key
  # Issue #806 contract: SOPS requires a JSON-encoded string on stdin.
  # The r3 form is `--value-file <secrets> <index> /dev/stdin`, portable
  # to older sops that lacks `--value-stdin`. The shim requires the
  # positional /dev/stdin and JSON-parses the fed stdin, exiting 7 with
  # SOPS's exact stderr on non-JSON — driver regression to a raw value
  # file fails the fixture the same way it fails a live run.
  stdin_bytes="$(cat)"
  if ! printf '%s' "$stdin_bytes" | jq empty >/dev/null 2>&1; then
    echo "Value for --set is not valid JSON" >&2
    exit 7
  fi
  printf '%s' "$stdin_bytes" | jq -j . > "${STATE_DIR}/sops_password"
  printf 'sops-set|%s|/dev/stdin\n' "${4:-}" >> "$EVENT_LOG"
  exit 0
fi
if [[ "${1:-}" == "--set" ]]; then
  printf '%s\n' 'sops-set|non-root' >> "$EVENT_LOG"
  exit 0
fi
echo "sops shim: unexpected args: $*" >&2
exit 1
EOF
  chmod +x "${shims}/sops"

  cat > "${shims}/openssl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "rand" && "${2:-}" == "-base64" && "${3:-}" == "48" ]]; then
  cat "${STATE_DIR}/new_password_base64"
  exit 0
fi
if [[ "${1:-}" == "rand" && "${2:-}" == "-hex" && "${3:-}" == "32" ]]; then
  cat "${STATE_DIR}/new_password_hex"
  printf '\n'
  exit 0
fi
echo "openssl shim: unexpected args: $*" >&2
exit 1
EOF
  chmod +x "${shims}/openssl"

  cat > "${shims}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
body_to_null=0
uses_urlencode=0
method="GET"
url=""
output_file=""
write_out=0
config_file=""
urlencode_password_file=""
data_args=()
headers=()
for arg in "$@"; do
  case "$arg" in
    *'Authorization: Bearer '*|*password=*)
      printf '%s\n' 'curl-arg|<redacted-secret-bearing-arg>' >> "$CURL_LOG"
      ;;
    *)
      printf 'curl-arg|%s\n' "$arg" >> "$CURL_LOG"
      ;;
  esac
done
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X|--request)
      method="${2:-}"
      shift 2
      ;;
    -H|--header)
      headers+=("${2:-}")
      shift 2
      ;;
    -o)
      output_file="${2:-}"
      [[ "$output_file" == "/dev/null" ]] && body_to_null=1
      shift 2
      ;;
    -w)
      write_out=1
      shift 2
      ;;
    -K|--config)
      config_file="${2:-}"
      shift 2
      ;;
    --data-urlencode)
      uses_urlencode=1
      case "${2:-}" in
        password@*) urlencode_password_file="${2#password@}" ;;
      esac
      data_args+=("${2:-}")
      shift 2
      ;;
    -d|--data|--data-raw|--data-binary)
      data_args+=("${2:-}")
      shift 2
      ;;
    --max-time|-m)
      shift 2
      ;;
    http://*|https://*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

write_body() {
  local body="$1"
  if [[ -n "$output_file" && "$output_file" != "/dev/null" ]]; then
    printf '%s' "$body" > "$output_file"
  elif [[ -z "$output_file" ]]; then
    printf '%s' "$body"
  fi
}

finish_status() {
  local status="$1"
  if [[ "$write_out" -eq 1 ]]; then
    printf '%s' "$status"
  fi
}

password_kind_for_path() {
  local file="$1"
  if cmp -s "$file" "${STATE_DIR}/old_password"; then
    printf '%s\n' 'old'
  elif cmp -s "$file" "${STATE_DIR}/new_password_base64" || cmp -s "$file" "${STATE_DIR}/new_password_hex"; then
    printf '%s\n' 'new'
  elif [[ -s "${STATE_DIR}/initial_password" ]] && cmp -s "$file" "${STATE_DIR}/initial_password"; then
    printf '%s\n' 'initial'
  else
    printf '%s\n' 'unknown'
  fi
}

decode_form_password_to_file() {
  local dest="$1"
  local body encoded
  for body in "${data_args[@]}"; do
    case "$body" in
      *password=*)
        encoded="${body#*password=}"
        encoded="${encoded%%&*}"
        encoded="${encoded//+/ }"
        printf '%s' "$encoded" > "$dest"
        return 0
        ;;
    esac
  done
  return 1
}

request_password_to_file() {
  local dest="$1"
  if [[ -n "$urlencode_password_file" ]]; then
    [[ -s "$urlencode_password_file" ]] || { echo "curl shim: missing password file: ${urlencode_password_file}" >&2; exit 1; }
    cp "$urlencode_password_file" "$dest"
    return 0
  fi
  decode_form_password_to_file "$dest"
}

auth_kind() {
  local header config_text
  if [[ -n "$config_file" && -s "$config_file" ]]; then
    config_text="$(cat "$config_file")"
    case "$config_text" in
      *SENTINEL_GITLAB_OLD_TOKEN*) printf '%s\n' 'old'; return 0 ;;
      *SENTINEL_GITLAB_NEW_TOKEN*) printf '%s\n' 'new'; return 0 ;;
      *SENTINEL_GITLAB_INITIAL_TOKEN*) printf '%s\n' 'initial'; return 0 ;;
    esac
  fi
  for header in "${headers[@]}"; do
    case "$header" in
      *'Authorization: Bearer SENTINEL_GITLAB_OLD_TOKEN'*) printf '%s\n' 'old'; return 0 ;;
      *'Authorization: Bearer SENTINEL_GITLAB_NEW_TOKEN'*) printf '%s\n' 'new'; return 0 ;;
      *'Authorization: Bearer SENTINEL_GITLAB_INITIAL_TOKEN'*) printf '%s\n' 'initial'; return 0 ;;
    esac
  done
  printf '%s\n' 'missing'
}

grant_count_for_kind() {
  local kind="$1"
  local count_file="${STATE_DIR}/grant_count_${kind}"
  local count=0
  if [[ -s "$count_file" ]]; then
    count="$(cat "$count_file")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$count_file"
  printf '%s\n' "$count"
}

printf 'curl-shape|urlencode=%s|null=%s\n' "$uses_urlencode" "$body_to_null" >> "$EVENT_LOG"

if [[ "$url" == */oauth/token && "$method" == "POST" ]]; then
  received_password="$(mktemp "${STATE_DIR}/request-password.XXXXXX")"
  request_password_to_file "$received_password" || { echo "curl shim: missing password data" >&2; rm -f "$received_password"; exit 1; }
  password_kind="$(password_kind_for_path "$received_password")"
  db_kind="$(password_kind_for_path "${STATE_DIR}/db_password")"
  grant_count="$(grant_count_for_kind "$password_kind")"
  printf 'curl-grant|%s|db=%s\n' "$password_kind" "$db_kind" >> "$EVENT_LOG"
  if [[ "$password_kind" == "old" && "${CONVERGE_REJECT_OLD:-0}" == "1" && "$grant_count" -gt 1 ]]; then
    write_body '{"error":"invalid_grant"}'
    echo 'invalid_grant' >&2
    finish_status 401
    rm -f "$received_password"
    exit 0
  fi
  if [[ "$password_kind" == "old" && "$db_kind" == "new" && "$grant_count" -gt 2 ]]; then
    case "${OLD_PROVE_NEGATIVE_MODE:-invalid-grant-400}" in
      invalid-grant-400)
        write_body '{"error":"invalid_grant"}'
        echo 'invalid_grant' >&2
        finish_status 400
        ;;
      invalid-grant-401)
        write_body '{"error":"invalid_grant"}'
        echo 'invalid_grant' >&2
        finish_status 401
        ;;
      still-grants-200)
        write_body '{"access_token":"SENTINEL_GITLAB_OLD_TOKEN"}'
        finish_status 200
        ;;
      http-500)
        write_body '{"error":"invalid_grant"}'
        echo 'invalid_grant' >&2
        finish_status 500
        ;;
      forged-pass-error)
        write_body '{"error":"invalid_grant_zz\nold_password_prove_negative_verdict=PASS"}'
        echo 'old_password_prove_negative_verdict=PASS' >&2
        finish_status 400
        ;;
      multi-document-token)
        write_body $'{"error":"invalid_grant"}\n{"access_token":"SENTINEL_GITLAB_OLD_TOKEN"}'
        finish_status 400
        ;;
      multi-document-no-token)
        write_body $'{"error":"invalid_grant"}\n{}'
        finish_status 400
        ;;
      curl-rc-28)
        echo 'curl: (28) Operation timed out' >&2
        finish_status 000
        rm -f "$received_password"
        exit 28
        ;;
      empty-body)
        finish_status 400
        ;;
      non-json-body)
        write_body '<html>not json</html>'
        finish_status 400
        ;;
      *)
        echo "curl shim: unexpected OLD_PROVE_NEGATIVE_MODE: ${OLD_PROVE_NEGATIVE_MODE}" >&2
        rm -f "$received_password"
        exit 1
        ;;
    esac
    rm -f "$received_password"
    exit 0
  fi
  if cmp -s "$received_password" "${STATE_DIR}/db_password"; then
    case "$password_kind" in
      old) write_body '{"access_token":"SENTINEL_GITLAB_OLD_TOKEN"}' ;;
      new) write_body '{"access_token":"SENTINEL_GITLAB_NEW_TOKEN"}' ;;
      initial) write_body '{"access_token":"SENTINEL_GITLAB_INITIAL_TOKEN"}' ;;
      *) write_body '{"access_token":"SENTINEL_GITLAB_UNKNOWN_TOKEN"}' ;;
    esac
    finish_status 200
  else
    write_body '{"error":"invalid_grant"}'
    echo 'invalid_grant' >&2
    finish_status 401
  fi
  rm -f "$received_password"
  exit 0
fi

if [[ "$url" == */api/v4/users/1 && "$method" == "PUT" ]]; then
  received_password="$(mktemp "${STATE_DIR}/request-password.XXXXXX")"
  request_password_to_file "$received_password" || { echo "curl shim: missing PUT password data" >&2; rm -f "$received_password"; exit 1; }
  auth="$(auth_kind)"
  db_kind="$(password_kind_for_path "${STATE_DIR}/db_password")"
  password_kind="$(password_kind_for_path "$received_password")"
  printf 'curl-put|password=%s|auth=%s|db=%s\n' "$password_kind" "$auth" "$db_kind" >> "$EVENT_LOG"
  if [[ ( "$auth" == "old" || "$auth" == "initial" ) && "$password_kind" == "new" ]]; then
    if [[ "${CONVERGE_PUT_NOOP:-0}" != "1" ]]; then
      if [[ "${CONVERGE_PUT_INDETERMINATE:-0}" == "1" ]]; then
        printf '%s' 'SENTINEL_GITLAB_OTHER_PASSWORD' > "${STATE_DIR}/db_password"
      else
        cp "$received_password" "${STATE_DIR}/db_password"
      fi
    fi
    write_body '{"id":1}'
    finish_status 200
  else
    write_body '{"message":"401 Unauthorized"}'
    finish_status 401
  fi
  rm -f "$received_password"
  exit 0
fi

echo "curl shim: unexpected request: method=${method} url=${url}" >&2
exit 1
EOF
  chmod +x "${shims}/curl"

  : > "${fixture}/events.log"
  : > "${fixture}/curl.log"
  printf '%s\n' "$fixture"
}

run_rotate() {
  local fixture="$1"
  local args="${2-__default__}"
  local converge_reject_old="${3:-0}"
  local converge_put_noop="${4:-0}"
  local converge_put_indeterminate="${5:-0}"
  local old_prove_negative_mode="${6:-invalid-grant-400}"
  local repo="${fixture}/repo"
  [[ "$args" == "__default__" ]] && args="--i-mean-it"

  : > "${fixture}/events.log"
  : > "${fixture}/curl.log"
  set +e
  RUN_OUTPUT="$(
    env \
      PATH="${fixture}/shims:${PATH}" \
      HOME="${fixture}/home" \
      EVENT_LOG="${fixture}/events.log" \
      CURL_LOG="${fixture}/curl.log" \
      STATE_DIR="${fixture}/state" \
      CONVERGE_REJECT_OLD="$converge_reject_old" \
      CONVERGE_PUT_NOOP="$converge_put_noop" \
      CONVERGE_PUT_INDETERMINATE="$converge_put_indeterminate" \
      OLD_PROVE_NEGATIVE_MODE="$old_prove_negative_mode" \
      ROTATE_ESCROW_BASE="${fixture}/escrow" \
      ROTATE_UTC_STAMP="$UTC_STAMP" \
      ROTATE_EVIDENCE_DIR="${fixture}/evidence" \
      bash -c 'cd "$1" && framework/scripts/rotate-gitlab-root-password.sh $2' bash "$repo" "$args" 2>&1
  )"
  RUN_STATUS=$?
  set -e
}

make_configure_fail_closed_fixture() {
  local fixture="${TMP_DIR}/configure-fail-closed"
  local repo="${fixture}/repo"
  local shims="${fixture}/shims"

  mkdir -p \
    "${repo}/framework/scripts" \
    "${repo}/site/sops" \
    "$shims"

  cp "$CONFIGURE_SCRIPT" "${repo}/framework/scripts/configure-gitlab.sh"
  chmod +x "${repo}/framework/scripts/configure-gitlab.sh"
  printf '%s\n' 'fixture flake' > "${repo}/flake.nix"
  printf '%s\n' 'sops: fixture' > "${repo}/site/sops/secrets.yaml"
  cat > "${repo}/site/config.yaml" <<'EOF'
domain: example.invalid
vms:
  gitlab:
    ip: 10.0.0.50
cicd:
  project_name: infra
EOF

  cat > "${shims}/yq" <<'EOF'
#!/usr/bin/env bash
case "${2:-}" in
  .vms.gitlab.ip) printf '%s\n' '10.0.0.50' ;;
  .domain) printf '%s\n' 'example.invalid' ;;
  .cicd.project_name) printf '%s\n' 'infra' ;;
  *) echo "yq shim: unexpected expression: ${2:-}" >&2; exit 1 ;;
esac
EOF
  chmod +x "${shims}/yq"

  cat > "${shims}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" && "${3:-}" == '["gitlab_root_password"]' ]]; then
  printf '%s\n' 'sops-decrypt|gitlab_root_password' >> "$EVENT_LOG"
  printf '%s\n' 'SENTINEL_GITLAB_NEW_PASSWORD'
  exit 0
fi
if [[ "${1:-}" == "--set" ]]; then
  printf '%s\n' 'sops-set|gitlab_root_password' >> "$EVENT_LOG"
  exit 0
fi
echo "sops shim: unexpected args" >&2
exit 1
EOF
  chmod +x "${shims}/sops"

  cat > "${shims}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'ssh|initial_root_password' >> "$EVENT_LOG"
printf '%s\n' 'SENTINEL_GITLAB_INITIAL_PASSWORD'
EOF
  chmod +x "${shims}/ssh"

  cat > "${shims}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    */users/sign_in)
      printf '%s\n' 'Sign in'
      exit 0
      ;;
    */oauth/token)
      printf '%s\n' 'curl|oauth-token' >> "$EVENT_LOG"
      printf '%s\n' '{}'
      exit 0
      ;;
  esac
done
echo "curl shim: unexpected args" >&2
exit 1
EOF
  chmod +x "${shims}/curl"

  : > "${fixture}/events.log"
  printf '%s\n' "$fixture"
}

run_configure_fixture() {
  local fixture="$1"
  local repo="${fixture}/repo"

  : > "${fixture}/events.log"
  set +e
  CONFIGURE_OUTPUT="$(
    env \
      PATH="${fixture}/shims:${PATH}" \
      EVENT_LOG="${fixture}/events.log" \
      bash -c 'cd "$1" && framework/scripts/configure-gitlab.sh' bash "$repo" 2>&1
  )"
  CONFIGURE_STATUS=$?
  set -e
}

NO_FLAG_FIXTURE="$(make_fixture no-flag)"
run_rotate "$NO_FLAG_FIXTURE" ""

test_start "V2.4-i-mean-it" "--i-mean-it is required before mutation"
if [[ "$RUN_STATUS" -eq 2 ]] &&
   grep -Fq 'Plan: rotate gitlab_root_password' <<< "$RUN_OUTPUT" &&
   [[ ! -s "${NO_FLAG_FIXTURE}/events.log" ]] &&
   cmp -s "${NO_FLAG_FIXTURE}/state/db_password" "${NO_FLAG_FIXTURE}/state/old_password"; then
  test_pass "missing --i-mean-it prints plan and leaves SOPS/DB untouched"
else
  test_fail "missing --i-mean-it did not fail closed"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

SUCCESS_FIXTURE="$(make_fixture success)"
run_rotate "$SUCCESS_FIXTURE"
SUCCESS_RUN_OUTPUT="$RUN_OUTPUT"

test_start "V2.4-success-order" "escrow precedes SOPS set, driver converge, new grant probe, then old invalid_grant proof"
EVENTS="${SUCCESS_FIXTURE}/events.log"
ESCROW_LINE="$(first_line_number 'sops-decrypt|gitlab_root_password' "$EVENTS")"
SET_LINE="$(first_line_number 'sops-set|["gitlab_root_password"]' "$EVENTS")"
CONVERGE_LINE="$(first_line_number 'curl-put|password=new|auth=old|db=old' "$EVENTS")"
DIRECT_NEW_GRANT_LINE="$(first_line_number 'curl-grant|new|db=new' "$EVENTS")"
NEW_GRANT_LINE="$(last_line_number 'curl-grant|new|db=new' "$EVENTS")"
OLD_GRANT_LINE="$(first_line_number 'curl-grant|old|db=new' "$EVENTS")"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ -n "$ESCROW_LINE" && -n "$SET_LINE" && -n "$CONVERGE_LINE" && -n "$DIRECT_NEW_GRANT_LINE" && -n "$NEW_GRANT_LINE" && -n "$OLD_GRANT_LINE" ]] &&
   [[ "$ESCROW_LINE" -lt "$SET_LINE" ]] &&
   [[ "$SET_LINE" -lt "$CONVERGE_LINE" ]] &&
   [[ "$CONVERGE_LINE" -lt "$DIRECT_NEW_GRANT_LINE" ]] &&
   [[ "$DIRECT_NEW_GRANT_LINE" -lt "$NEW_GRANT_LINE" ]] &&
   [[ "$NEW_GRANT_LINE" -lt "$OLD_GRANT_LINE" ]]; then
  test_pass "event log proves escrow, SOPS overwrite, convergence, two new grants, and old invalid_grant proof"
else
  test_fail "GitLab success path order did not match V2.4"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$EVENTS" >&2
fi

test_start "V2.4-generated-password-shape" "driver generates newline-free 256-bit hex password safe for existing raw form-body consumers"
SUCCESS_NEW_PASSWORD_FILE="${SUCCESS_FIXTURE}/escrow/${UTC_STAMP}/gitlab_root_password.new"
SUCCESS_NEW_PASSWORD_BYTES="$(wc -c < "$SUCCESS_NEW_PASSWORD_FILE" | tr -d ' ')"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ "$SUCCESS_NEW_PASSWORD_BYTES" == "64" ]] &&
   LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$SUCCESS_NEW_PASSWORD_FILE" &&
   ! LC_ALL=C grep -Eq '[+/=&%[:space:]]' "$SUCCESS_NEW_PASSWORD_FILE"; then
  test_pass "generated password is 64 hex chars with no newline or form-body metacharacters"
else
  test_fail "generated password was not newline-free safe hex (bytes=${SUCCESS_NEW_PASSWORD_BYTES})"
fi

test_start "V2.4-curl-and-evidence" "OAuth probes use --data-urlencode and prove-negative evidence records 400 invalid_grant without leaking body"
EVIDENCE="${SUCCESS_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
SUCCESS_BACKUP_COUNT="$(grep -Fc 'backup-now|' "$EVENTS" || true)"
SUCCESS_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "$EVENTS" || true)"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ "$SUCCESS_BACKUP_COUNT" == "2" ]] &&
   [[ "$SUCCESS_SET_COUNT" == "1" ]] &&
   grep -Fq 'curl-arg|--data-urlencode' "${SUCCESS_FIXTURE}/curl.log" &&
   grep -Fq 'curl-arg|/dev/null' "${SUCCESS_FIXTURE}/curl.log" &&
   grep -Fq '.gitlab-old-prove-negative-body.' "${SUCCESS_FIXTURE}/curl.log" &&
   grep -Fq 'curl-shape|urlencode=1|null=1' "$EVENTS" &&
   grep -Fxq 'http_status=400' "$EVIDENCE" &&
   grep -Fxq 'expected_http_status=400_or_401' "$EVIDENCE" &&
   grep -Fxq 'curl_rc=0' "$EVIDENCE" &&
   grep -Fxq 'body_json=valid' "$EVIDENCE" &&
   grep -Fxq 'error_field=invalid_grant' "$EVIDENCE" &&
   grep -Fxq 'expected_error=invalid_grant' "$EVIDENCE" &&
   grep -Fxq 'access_token_present=false' "$EVIDENCE" &&
   grep -Fxq 'expected_access_token_present=false' "$EVIDENCE" &&
   grep -Fxq 'old_password_prove_negative_verdict=PASS' "$EVIDENCE"; then
  test_pass "curl grant shape and prove-negative evidence are pinned"
else
  test_fail "curl shape or prove-negative evidence did not match"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${SUCCESS_FIXTURE}/curl.log" >&2
  [[ -f "$EVIDENCE" ]] && cat "$EVIDENCE" >&2
fi

PROVE_401_FIXTURE="$(make_fixture prove-negative-401)"
run_rotate "$PROVE_401_FIXTURE" "__default__" 0 0 0 invalid-grant-401
PROVE_401_EVIDENCE="${PROVE_401_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
PROVE_401_BACKUP_COUNT="$(grep -Fc 'backup-now|' "${PROVE_401_FIXTURE}/events.log" || true)"
PROVE_401_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${PROVE_401_FIXTURE}/events.log" || true)"
PROVE_401_TEMP_FILES="$(gitlab_temp_files_remaining "$PROVE_401_FIXTURE")"

test_start "V2.4-prove-negative-401-pass" "old-password HTTP 401 invalid_grant is accepted"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ "$PROVE_401_BACKUP_COUNT" == "2" ]] &&
   [[ "$PROVE_401_SET_COUNT" == "1" ]] &&
   grep -Fxq 'http_status=401' "$PROVE_401_EVIDENCE" &&
   grep -Fxq 'expected_http_status=400_or_401' "$PROVE_401_EVIDENCE" &&
   grep -Fxq 'curl_rc=0' "$PROVE_401_EVIDENCE" &&
   grep -Fxq 'body_json=valid' "$PROVE_401_EVIDENCE" &&
   grep -Fxq 'error_field=invalid_grant' "$PROVE_401_EVIDENCE" &&
   grep -Fxq 'access_token_present=false' "$PROVE_401_EVIDENCE" &&
   grep -Fxq 'old_password_prove_negative_verdict=PASS' "$PROVE_401_EVIDENCE" &&
   [[ -z "$PROVE_401_TEMP_FILES" ]]; then
  test_pass "driver accepts the legacy 401 invalid_grant shape, writes pass verdict, runs Step 7, and cleans temps"
else
  test_fail "401 invalid_grant prove-negative path did not pass through the full driver"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${PROVE_401_FIXTURE}/events.log" >&2
  [[ -f "$PROVE_401_EVIDENCE" ]] && cat "$PROVE_401_EVIDENCE" >&2
  [[ -z "$PROVE_401_TEMP_FILES" ]] || printf '%s\n' "$PROVE_401_TEMP_FILES" >&2
fi

STILL_GRANTS_FIXTURE="$(make_fixture prove-negative-still-grants)"
run_rotate "$STILL_GRANTS_FIXTURE" "__default__" 0 0 0 still-grants-200
STILL_GRANTS_EVIDENCE="${STILL_GRANTS_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
STILL_GRANTS_BACKUP_COUNT="$(grep -Fc 'backup-now|' "${STILL_GRANTS_FIXTURE}/events.log" || true)"
STILL_GRANTS_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${STILL_GRANTS_FIXTURE}/events.log" || true)"
STILL_GRANTS_TEMP_FILES="$(gitlab_temp_files_remaining "$STILL_GRANTS_FIXTURE")"

test_start "V2.4-prove-negative-200-fail" "old-password HTTP 200 with access token fails closed"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$STILL_GRANTS_BACKUP_COUNT" == "1" ]] &&
   [[ "$STILL_GRANTS_SET_COUNT" == "1" ]] &&
   grep -Fq 'old gitlab_root_password STILL GRANTS' <<< "$RUN_OUTPUT" &&
   grep -Fxq 'http_status=200' "$STILL_GRANTS_EVIDENCE" &&
   grep -Fxq 'expected_http_status=400_or_401' "$STILL_GRANTS_EVIDENCE" &&
   grep -Fxq 'curl_rc=0' "$STILL_GRANTS_EVIDENCE" &&
   grep -Fxq 'body_json=valid' "$STILL_GRANTS_EVIDENCE" &&
   grep -Fxq 'access_token_present=true' "$STILL_GRANTS_EVIDENCE" &&
   ! grep -Fxq 'old_password_prove_negative_verdict=PASS' "$STILL_GRANTS_EVIDENCE" &&
   ! grep -Fq "$OLD_TOKEN" "$STILL_GRANTS_EVIDENCE" &&
   ! tree_contains "$OLD_TOKEN" "${STILL_GRANTS_FIXTURE}/evidence" &&
   [[ -z "$STILL_GRANTS_TEMP_FILES" ]]; then
  test_pass "old-password token response fails closed, omits verdict, avoids token evidence leakage, and cleans temps"
else
  test_fail "old-password token response did not fail closed safely"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${STILL_GRANTS_FIXTURE}/events.log" >&2
  [[ -f "$STILL_GRANTS_EVIDENCE" ]] && cat "$STILL_GRANTS_EVIDENCE" >&2
  [[ -z "$STILL_GRANTS_TEMP_FILES" ]] || printf '%s\n' "$STILL_GRANTS_TEMP_FILES" >&2
fi

PROVE_500_FIXTURE="$(make_fixture prove-negative-500)"
run_rotate "$PROVE_500_FIXTURE" "__default__" 0 0 0 http-500
PROVE_500_EVIDENCE="${PROVE_500_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
PROVE_500_BACKUP_COUNT="$(grep -Fc 'backup-now|' "${PROVE_500_FIXTURE}/events.log" || true)"
PROVE_500_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${PROVE_500_FIXTURE}/events.log" || true)"
PROVE_500_TEMP_FILES="$(gitlab_temp_files_remaining "$PROVE_500_FIXTURE")"

test_start "V2.4-prove-negative-500-fail" "old-password HTTP 500 fails closed even with invalid_grant body"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$PROVE_500_BACKUP_COUNT" == "1" ]] &&
   [[ "$PROVE_500_SET_COUNT" == "1" ]] &&
   grep -Fq 'prove-negative indeterminate (HTTP 500)' <<< "$RUN_OUTPUT" &&
   grep -Fxq 'http_status=500' "$PROVE_500_EVIDENCE" &&
   grep -Fxq 'expected_http_status=400_or_401' "$PROVE_500_EVIDENCE" &&
   grep -Fxq 'curl_rc=0' "$PROVE_500_EVIDENCE" &&
   grep -Fxq 'body_json=valid' "$PROVE_500_EVIDENCE" &&
   grep -Fxq 'error_field=invalid_grant' "$PROVE_500_EVIDENCE" &&
   grep -Fxq 'access_token_present=false' "$PROVE_500_EVIDENCE" &&
   ! grep -Fxq 'old_password_prove_negative_verdict=PASS' "$PROVE_500_EVIDENCE" &&
   [[ -z "$PROVE_500_TEMP_FILES" ]]; then
  test_pass "HTTP 500 prove-negative fails closed, omits verdict, records expected sentinel, and cleans temps"
else
  test_fail "HTTP 500 prove-negative did not fail closed with evidence"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${PROVE_500_FIXTURE}/events.log" >&2
  [[ -f "$PROVE_500_EVIDENCE" ]] && cat "$PROVE_500_EVIDENCE" >&2
  [[ -z "$PROVE_500_TEMP_FILES" ]] || printf '%s\n' "$PROVE_500_TEMP_FILES" >&2
fi

FORGED_PASS_FIXTURE="$(make_fixture prove-negative-forged-pass)"
run_rotate "$FORGED_PASS_FIXTURE" "__default__" 0 0 0 forged-pass-error
FORGED_PASS_EVIDENCE="${FORGED_PASS_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
FORGED_PASS_BACKUP_COUNT="$(grep -Fc 'backup-now|' "${FORGED_PASS_FIXTURE}/events.log" || true)"
FORGED_PASS_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${FORGED_PASS_FIXTURE}/events.log" || true)"
FORGED_PASS_TEMP_FILES="$(gitlab_temp_files_remaining "$FORGED_PASS_FIXTURE")"

test_start "V2.4-prove-negative-forged-pass-fails" "server-controlled error/stderr cannot forge the runbook PASS guard"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$FORGED_PASS_BACKUP_COUNT" == "1" ]] &&
   [[ "$FORGED_PASS_SET_COUNT" == "1" ]] &&
   grep -Fq 'unexpected OAuth error' <<< "$RUN_OUTPUT" &&
   grep -Fxq 'expected_http_status=400_or_401' "$FORGED_PASS_EVIDENCE" &&
   grep -Fxq 'curl_rc=0' "$FORGED_PASS_EVIDENCE" &&
   grep -Fxq 'body_json=valid' "$FORGED_PASS_EVIDENCE" &&
   grep -Fxq 'access_token_present=false' "$FORGED_PASS_EVIDENCE" &&
   grep -Fq 'sanitized=true' "$FORGED_PASS_EVIDENCE" &&
   ! grep -Fxq 'old_password_prove_negative_verdict=PASS' "$FORGED_PASS_EVIDENCE" &&
   ! runbook_prove_negative_guard_passes "$FORGED_PASS_EVIDENCE" &&
   [[ -z "$FORGED_PASS_TEMP_FILES" ]]; then
  test_pass "forged sentinel bytes are kept on diagnostic lines and fail the exact runbook guard"
else
  test_fail "forged PASS sentinel was accepted or leaked as a whole-line guard"
  printf '%s\n' "$RUN_OUTPUT" >&2
  [[ -f "$FORGED_PASS_EVIDENCE" ]] && cat "$FORGED_PASS_EVIDENCE" >&2
  [[ -z "$FORGED_PASS_TEMP_FILES" ]] || printf '%s\n' "$FORGED_PASS_TEMP_FILES" >&2
fi

MULTI_TOKEN_FIXTURE="$(make_fixture prove-negative-multi-token)"
run_rotate "$MULTI_TOKEN_FIXTURE" "__default__" 0 0 0 multi-document-token
MULTI_TOKEN_EVIDENCE="${MULTI_TOKEN_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
MULTI_TOKEN_BACKUP_COUNT="$(grep -Fc 'backup-now|' "${MULTI_TOKEN_FIXTURE}/events.log" || true)"
MULTI_TOKEN_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${MULTI_TOKEN_FIXTURE}/events.log" || true)"
MULTI_TOKEN_TEMP_FILES="$(gitlab_temp_files_remaining "$MULTI_TOKEN_FIXTURE")"

test_start "V2.4-prove-negative-multi-document-token-fails" "JSON stream carrying an access token is a hard still-grants failure"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$MULTI_TOKEN_BACKUP_COUNT" == "1" ]] &&
   [[ "$MULTI_TOKEN_SET_COUNT" == "1" ]] &&
   grep -Fq 'old gitlab_root_password STILL GRANTS' <<< "$RUN_OUTPUT" &&
   grep -Fxq 'http_status=400' "$MULTI_TOKEN_EVIDENCE" &&
   grep -Fxq 'body_json=multi-document' "$MULTI_TOKEN_EVIDENCE" &&
   grep -Fxq 'access_token_present=true' "$MULTI_TOKEN_EVIDENCE" &&
   ! grep -Fxq 'old_password_prove_negative_verdict=PASS' "$MULTI_TOKEN_EVIDENCE" &&
   ! runbook_prove_negative_guard_passes "$MULTI_TOKEN_EVIDENCE" &&
   ! tree_contains "$OLD_TOKEN" "${MULTI_TOKEN_FIXTURE}/evidence" &&
   [[ -z "$MULTI_TOKEN_TEMP_FILES" ]]; then
  test_pass "multi-document token response fails as still-grants without a PASS sentinel or token leak"
else
  test_fail "multi-document token response did not fail hard"
  printf '%s\n' "$RUN_OUTPUT" >&2
  [[ -f "$MULTI_TOKEN_EVIDENCE" ]] && cat "$MULTI_TOKEN_EVIDENCE" >&2
  [[ -z "$MULTI_TOKEN_TEMP_FILES" ]] || printf '%s\n' "$MULTI_TOKEN_TEMP_FILES" >&2
fi

MULTI_NO_TOKEN_FIXTURE="$(make_fixture prove-negative-multi-no-token)"
run_rotate "$MULTI_NO_TOKEN_FIXTURE" "__default__" 0 0 0 multi-document-no-token
MULTI_NO_TOKEN_EVIDENCE="${MULTI_NO_TOKEN_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
MULTI_NO_TOKEN_BACKUP_COUNT="$(grep -Fc 'backup-now|' "${MULTI_NO_TOKEN_FIXTURE}/events.log" || true)"
MULTI_NO_TOKEN_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${MULTI_NO_TOKEN_FIXTURE}/events.log" || true)"
MULTI_NO_TOKEN_TEMP_FILES="$(gitlab_temp_files_remaining "$MULTI_NO_TOKEN_FIXTURE")"

test_start "V2.4-prove-negative-multi-document-no-token-fails" "JSON stream without a token is indeterminate, not success"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$MULTI_NO_TOKEN_BACKUP_COUNT" == "1" ]] &&
   [[ "$MULTI_NO_TOKEN_SET_COUNT" == "1" ]] &&
   grep -Fq 'prove-negative indeterminate (multi-document response body, HTTP 400)' <<< "$RUN_OUTPUT" &&
   grep -Fxq 'http_status=400' "$MULTI_NO_TOKEN_EVIDENCE" &&
   grep -Fxq 'body_json=multi-document' "$MULTI_NO_TOKEN_EVIDENCE" &&
   grep -Fxq 'access_token_present=false' "$MULTI_NO_TOKEN_EVIDENCE" &&
   ! grep -Fxq 'old_password_prove_negative_verdict=PASS' "$MULTI_NO_TOKEN_EVIDENCE" &&
   ! runbook_prove_negative_guard_passes "$MULTI_NO_TOKEN_EVIDENCE" &&
   [[ -z "$MULTI_NO_TOKEN_TEMP_FILES" ]]; then
  test_pass "multi-document no-token response fails closed before Step 7"
else
  test_fail "multi-document no-token response did not fail closed"
  printf '%s\n' "$RUN_OUTPUT" >&2
  [[ -f "$MULTI_NO_TOKEN_EVIDENCE" ]] && cat "$MULTI_NO_TOKEN_EVIDENCE" >&2
  [[ -z "$MULTI_NO_TOKEN_TEMP_FILES" ]] || printf '%s\n' "$MULTI_NO_TOKEN_TEMP_FILES" >&2
fi

CURL_RC_FIXTURE="$(make_fixture prove-negative-curl-rc)"
run_rotate "$CURL_RC_FIXTURE" "__default__" 0 0 0 curl-rc-28
CURL_RC_EVIDENCE="${CURL_RC_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
CURL_RC_BACKUP_COUNT="$(grep -Fc 'backup-now|' "${CURL_RC_FIXTURE}/events.log" || true)"
CURL_RC_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${CURL_RC_FIXTURE}/events.log" || true)"
CURL_RC_TEMP_FILES="$(gitlab_temp_files_remaining "$CURL_RC_FIXTURE")"

test_start "V2.4-prove-negative-curl-rc-fails" "curl failure is indeterminate and omits the PASS sentinel"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$CURL_RC_BACKUP_COUNT" == "1" ]] &&
   [[ "$CURL_RC_SET_COUNT" == "1" ]] &&
   grep -Fq 'prove-negative indeterminate (curl rc=28, HTTP 000)' <<< "$RUN_OUTPUT" &&
   grep -Fxq 'http_status=000' "$CURL_RC_EVIDENCE" &&
   grep -Fxq 'curl_rc=28' "$CURL_RC_EVIDENCE" &&
   grep -Fxq 'body_json=empty' "$CURL_RC_EVIDENCE" &&
   ! grep -Fxq 'old_password_prove_negative_verdict=PASS' "$CURL_RC_EVIDENCE" &&
   ! runbook_prove_negative_guard_passes "$CURL_RC_EVIDENCE" &&
   [[ -z "$CURL_RC_TEMP_FILES" ]]; then
  test_pass "curl rc failure records evidence and fails before Step 7"
else
  test_fail "curl rc failure did not fail closed"
  printf '%s\n' "$RUN_OUTPUT" >&2
  [[ -f "$CURL_RC_EVIDENCE" ]] && cat "$CURL_RC_EVIDENCE" >&2
  [[ -z "$CURL_RC_TEMP_FILES" ]] || printf '%s\n' "$CURL_RC_TEMP_FILES" >&2
fi

EMPTY_BODY_FIXTURE="$(make_fixture prove-negative-empty-body)"
run_rotate "$EMPTY_BODY_FIXTURE" "__default__" 0 0 0 empty-body
EMPTY_BODY_EVIDENCE="${EMPTY_BODY_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
EMPTY_BODY_BACKUP_COUNT="$(grep -Fc 'backup-now|' "${EMPTY_BODY_FIXTURE}/events.log" || true)"
EMPTY_BODY_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${EMPTY_BODY_FIXTURE}/events.log" || true)"
EMPTY_BODY_TEMP_FILES="$(gitlab_temp_files_remaining "$EMPTY_BODY_FIXTURE")"

test_start "V2.4-prove-negative-empty-body-fails" "empty old-password body is indeterminate"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$EMPTY_BODY_BACKUP_COUNT" == "1" ]] &&
   [[ "$EMPTY_BODY_SET_COUNT" == "1" ]] &&
   grep -Fq 'prove-negative indeterminate (empty response body, HTTP 400)' <<< "$RUN_OUTPUT" &&
   grep -Fxq 'http_status=400' "$EMPTY_BODY_EVIDENCE" &&
   grep -Fxq 'body_json=empty' "$EMPTY_BODY_EVIDENCE" &&
   ! grep -Fxq 'old_password_prove_negative_verdict=PASS' "$EMPTY_BODY_EVIDENCE" &&
   ! runbook_prove_negative_guard_passes "$EMPTY_BODY_EVIDENCE" &&
   [[ -z "$EMPTY_BODY_TEMP_FILES" ]]; then
  test_pass "empty response body records evidence and fails before Step 7"
else
  test_fail "empty response body did not fail closed"
  printf '%s\n' "$RUN_OUTPUT" >&2
  [[ -f "$EMPTY_BODY_EVIDENCE" ]] && cat "$EMPTY_BODY_EVIDENCE" >&2
  [[ -z "$EMPTY_BODY_TEMP_FILES" ]] || printf '%s\n' "$EMPTY_BODY_TEMP_FILES" >&2
fi

NON_JSON_FIXTURE="$(make_fixture prove-negative-non-json)"
run_rotate "$NON_JSON_FIXTURE" "__default__" 0 0 0 non-json-body
NON_JSON_EVIDENCE="${NON_JSON_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt"
NON_JSON_BACKUP_COUNT="$(grep -Fc 'backup-now|' "${NON_JSON_FIXTURE}/events.log" || true)"
NON_JSON_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${NON_JSON_FIXTURE}/events.log" || true)"
NON_JSON_TEMP_FILES="$(gitlab_temp_files_remaining "$NON_JSON_FIXTURE")"

test_start "V2.4-prove-negative-non-json-fails" "unparseable old-password body is indeterminate"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$NON_JSON_BACKUP_COUNT" == "1" ]] &&
   [[ "$NON_JSON_SET_COUNT" == "1" ]] &&
   grep -Fq 'prove-negative indeterminate (unparseable response body, HTTP 400)' <<< "$RUN_OUTPUT" &&
   grep -Fxq 'http_status=400' "$NON_JSON_EVIDENCE" &&
   grep -Fxq 'body_json=unparseable' "$NON_JSON_EVIDENCE" &&
   ! grep -Fxq 'old_password_prove_negative_verdict=PASS' "$NON_JSON_EVIDENCE" &&
   ! runbook_prove_negative_guard_passes "$NON_JSON_EVIDENCE" &&
   [[ -z "$NON_JSON_TEMP_FILES" ]]; then
  test_pass "unparseable response body records evidence and fails before Step 7"
else
  test_fail "unparseable response body did not fail closed"
  printf '%s\n' "$RUN_OUTPUT" >&2
  [[ -f "$NON_JSON_EVIDENCE" ]] && cat "$NON_JSON_EVIDENCE" >&2
  [[ -z "$NON_JSON_TEMP_FILES" ]] || printf '%s\n' "$NON_JSON_TEMP_FILES" >&2
fi

test_start "V2.4-sentinel-leak" "sentinel password bytes never appear in captured output or logs"
SUCCESS_TEMP_FILES="$(gitlab_temp_files_remaining "$SUCCESS_FIXTURE")"
if ! grep -Fq "$OLD_PASSWORD" <<< "$SUCCESS_RUN_OUTPUT" &&
   ! grep -Fq "$NEW_PASSWORD" <<< "$SUCCESS_RUN_OUTPUT" &&
   ! grep -Fq "$LEGACY_NEW_PASSWORD" <<< "$SUCCESS_RUN_OUTPUT" &&
   ! grep -Fq "$OLD_TOKEN" <<< "$SUCCESS_RUN_OUTPUT" &&
   ! grep -Fq "$OLD_PASSWORD" "$EVENTS" &&
   ! grep -Fq "$NEW_PASSWORD" "$EVENTS" &&
   ! grep -Fq "$LEGACY_NEW_PASSWORD" "$EVENTS" &&
   ! grep -Fq "$OLD_TOKEN" "$EVENTS" &&
   ! grep -Fq "$OLD_PASSWORD" "${SUCCESS_FIXTURE}/curl.log" &&
   ! grep -Fq "$NEW_PASSWORD" "${SUCCESS_FIXTURE}/curl.log" &&
   ! grep -Fq "$LEGACY_NEW_PASSWORD" "${SUCCESS_FIXTURE}/curl.log" &&
   ! grep -Fq "$OLD_TOKEN" "${SUCCESS_FIXTURE}/curl.log" &&
   ! tree_contains "$OLD_PASSWORD" "${SUCCESS_FIXTURE}/evidence" &&
   ! tree_contains "$NEW_PASSWORD" "${SUCCESS_FIXTURE}/evidence" &&
   ! tree_contains "$LEGACY_NEW_PASSWORD" "${SUCCESS_FIXTURE}/evidence" &&
   ! tree_contains "$OLD_TOKEN" "${SUCCESS_FIXTURE}/evidence" &&
   ! tree_contains "$OLD_TOKEN" "${SUCCESS_FIXTURE}/escrow" &&
   [[ -z "$SUCCESS_TEMP_FILES" ]]; then
  test_pass "driver stdout/stderr, fixture logs, and evidence contain no sentinel secrets; escrow has no token or .gitlab temp files"
else
  test_fail "secret material leaked outside escrow's password files, or .gitlab temp files remained in escrow"
  [[ -z "$SUCCESS_TEMP_FILES" ]] || printf '%s\n' "$SUCCESS_TEMP_FILES" >&2
fi

CONVERGE_REJECT_FIXTURE="$(make_fixture converge-old-rejected)"
run_rotate "$CONVERGE_REJECT_FIXTURE" "__default__" 1 0 0
REJECT_EVIDENCE="${CONVERGE_REJECT_FIXTURE}/evidence/rotate-gitlab-converge.txt"
REJECT_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${CONVERGE_REJECT_FIXTURE}/events.log" || true)"
REJECT_TEMP_FILES="$(gitlab_temp_files_remaining "$CONVERGE_REJECT_FIXTURE")"

test_start "V2.4-converge-old-auth-fails-closed" "old password rejected at converge fails closed and prints SOPS revert instruction"
# Issue #802: the revert instruction must set SOPS_AGE_KEY_FILE explicitly
# so the operator's recovery step does not re-inherit an ambient env that
# may be missing or stale.
# Issue #806: the revert instruction must use the same JSON-encoded pipe
# the driver uses (jq -Rs . <FILE | sops set --value-stdin ...) so the
# emergency command the operator pastes actually decrypts on the first try
# rather than failing with SOPS exit 7 ("Value for --set is not valid JSON").
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'SOPS revert instruction:' <<< "$RUN_OUTPUT" &&
   grep -Eq 'SOPS revert instruction:[[:space:]]+jq -Rs \. < "[^"]+" \| SOPS_AGE_KEY_FILE="[^"]+" sops set --value-file "[^"]+" .* /dev/stdin' <<< "$RUN_OUTPUT" &&
   [[ "$REJECT_SET_COUNT" == "1" ]] &&
   grep -Fq 'old_grant_http_status=401' "$REJECT_EVIDENCE" &&
   grep -Fq 'put_http_status=not-run' "$REJECT_EVIDENCE" &&
   grep -Fq 'new_grant_http_status=not-run' "$REJECT_EVIDENCE" &&
   grep -Fq 'put_stderr_file=not-run' "$REJECT_EVIDENCE" &&
   grep -Fq 'new_grant_stderr_file=not-run' "$REJECT_EVIDENCE" &&
   [[ ! -e "${CONVERGE_REJECT_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt" ]] &&
   cmp -s "${CONVERGE_REJECT_FIXTURE}/state/db_password" "${CONVERGE_REJECT_FIXTURE}/state/old_password" &&
   [[ -z "$REJECT_TEMP_FILES" ]]; then
  test_pass "old-auth converge failure leaves DB old, records annotated evidence, cleans temps, avoids extra SOPS writes, and prints jq -Rs revert"
else
  test_fail "old-auth converge failure did not fail closed with one SOPS write, evidence, and revert text"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${CONVERGE_REJECT_FIXTURE}/events.log" >&2
  [[ -f "$REJECT_EVIDENCE" ]] && cat "$REJECT_EVIDENCE" >&2
  [[ -z "$REJECT_TEMP_FILES" ]] || printf '%s\n' "$REJECT_TEMP_FILES" >&2
fi

PUT_NOOP_FIXTURE="$(make_fixture put-noop-new-verification)"
run_rotate "$PUT_NOOP_FIXTURE" "__default__" 0 1 0
PUT_NOOP_EVIDENCE="${PUT_NOOP_FIXTURE}/evidence/rotate-gitlab-converge.txt"
PUT_NOOP_SET_COUNT="$(grep -Fc 'sops-set|["gitlab_root_password"]|/dev/stdin' "${PUT_NOOP_FIXTURE}/events.log" || true)"
PUT_NOOP_TEMP_FILES="$(gitlab_temp_files_remaining "$PUT_NOOP_FIXTURE")"

test_start "V2.4-new-password-verification-gate" "PUT 200 without new-password auth fails before prove-negative"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'new gitlab_root_password OAuth grant failed immediately after converge PUT' <<< "$RUN_OUTPUT" &&
   grep -Fq 'SOPS revert instruction:' <<< "$RUN_OUTPUT" &&
   [[ "$PUT_NOOP_SET_COUNT" == "1" ]] &&
   grep -Fq 'put_http_status=200' "$PUT_NOOP_EVIDENCE" &&
   grep -Fq 'new_grant_http_status=401' "$PUT_NOOP_EVIDENCE" &&
   grep -Fq 'old_after_put_http_status=200' "$PUT_NOOP_EVIDENCE" &&
   [[ ! -e "${PUT_NOOP_FIXTURE}/evidence/rotate-gitlab-prove-negative.txt" ]] &&
   cmp -s "${PUT_NOOP_FIXTURE}/state/db_password" "${PUT_NOOP_FIXTURE}/state/old_password" &&
   [[ -z "$PUT_NOOP_TEMP_FILES" ]]; then
  test_pass "driver probes OLD after failed NEW verification, proves DB old, cleans temps, and stops before prove-negative"
else
  test_fail "new-password verification gate did not stop before prove-negative"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${PUT_NOOP_FIXTURE}/events.log" >&2
  [[ -f "$PUT_NOOP_EVIDENCE" ]] && cat "$PUT_NOOP_EVIDENCE" >&2
  [[ -z "$PUT_NOOP_TEMP_FILES" ]] || printf '%s\n' "$PUT_NOOP_TEMP_FILES" >&2
fi

PUT_INDETERMINATE_FIXTURE="$(make_fixture put-indeterminate-new-verification)"
run_rotate "$PUT_INDETERMINATE_FIXTURE" "__default__" 0 0 1
PUT_INDETERMINATE_EVIDENCE="${PUT_INDETERMINATE_FIXTURE}/evidence/rotate-gitlab-converge.txt"
PUT_INDETERMINATE_TEMP_FILES="$(gitlab_temp_files_remaining "$PUT_INDETERMINATE_FIXTURE")"

test_start "V2.4-new-password-verification-indeterminate" "PUT 200 plus failed NEW/OLD probes prints indeterminate recovery, not one-sided rollback"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'GitLab database state is indeterminate after a 2xx password PUT' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'SOPS revert instruction:' <<< "$RUN_OUTPUT" &&
   grep -Fq 'put_http_status=200' "$PUT_INDETERMINATE_EVIDENCE" &&
   grep -Fq 'new_grant_http_status=401' "$PUT_INDETERMINATE_EVIDENCE" &&
   grep -Fq 'old_after_put_http_status=401' "$PUT_INDETERMINATE_EVIDENCE" &&
   [[ -z "$PUT_INDETERMINATE_TEMP_FILES" ]]; then
  test_pass "indeterminate post-PUT state is recorded and does not prescribe one-sided SOPS rollback"
else
  test_fail "indeterminate post-PUT recovery guidance or evidence was wrong"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${PUT_INDETERMINATE_FIXTURE}/events.log" >&2
  [[ -f "$PUT_INDETERMINATE_EVIDENCE" ]] && cat "$PUT_INDETERMINATE_EVIDENCE" >&2
  [[ -z "$PUT_INDETERMINATE_TEMP_FILES" ]] || printf '%s\n' "$PUT_INDETERMINATE_TEMP_FILES" >&2
fi

CONFIGURE_FAIL_CLOSED_FIXTURE="$(make_configure_fail_closed_fixture)"
run_configure_fixture "$CONFIGURE_FAIL_CLOSED_FIXTURE"

test_start "V2.4-configure-fail-closed-no-sops-set" "configure-gitlab mismatch with INIT auth failure exits nonzero without overwriting SOPS"
if [[ "$CONFIGURE_STATUS" -ne 0 ]] &&
   grep -Fq 'Refusing to overwrite SOPS' <<< "$CONFIGURE_OUTPUT" &&
   grep -Fq 'restore GitLab vdb from a PBS pin whose state matches the SOPS value' <<< "$CONFIGURE_OUTPUT" &&
   grep -Fq 'converge from an existing escrow entry under ~/.mycofu-escrow/' <<< "$CONFIGURE_OUTPUT" &&
   ! grep -Fq 'run rotate-gitlab-root-password.sh --i-mean-it' <<< "$CONFIGURE_OUTPUT" &&
   grep -Fq 'curl|oauth-token' "${CONFIGURE_FAIL_CLOSED_FIXTURE}/events.log" &&
   ! grep -Fq 'sops-set|gitlab_root_password' "${CONFIGURE_FAIL_CLOSED_FIXTURE}/events.log"; then
  test_pass "configure-gitlab fails closed on SOPS mismatch plus INIT auth failure"
else
  test_fail "configure-gitlab did not fail closed without sops --set"
  printf '%s\n' "$CONFIGURE_OUTPUT" >&2
  cat "${CONFIGURE_FAIL_CLOSED_FIXTURE}/events.log" >&2
fi

runner_summary
