#!/usr/bin/env bash
# V2.5: rotate-vault-credentials.sh full-driver hermetic fixture.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

ROTATE_SCRIPT="${REPO_ROOT}/framework/scripts/rotate-vault-credentials.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

RUN_OUTPUT=""
RUN_STATUS=0
UTC_STAMP="20260726T122000Z"
OLD_UNSEAL="SENTINEL_VAULT_OLD_UNSEAL"
NEW_UNSEAL="SENTINEL_VAULT_NEW_UNSEAL"
OLD_ROOT="SENTINEL_VAULT_OLD_ROOT_TOKEN"
NEW_ROOT="SENTINEL_VAULT_NEW_ROOT_TOKEN"
CONSUMER_REMOTE_COMMAND='cat /var/lib/vault/root-token 2>/dev/null'

first_line_number() {
  local pattern="$1"
  local file="$2"
  grep -Fn "$pattern" "$file" | head -1 | cut -d: -f1 || true
}

fixture_leaks_sentinel() {
  local fixture="$1"
  local output="$2"
  local sentinel
  for sentinel in "$OLD_UNSEAL" "$NEW_UNSEAL" "$OLD_ROOT" "$NEW_ROOT"; do
    if grep -Fq "$sentinel" <<< "$output" ||
       grep -Fq "$sentinel" "${fixture}/events.log" ||
       grep -FRq "$sentinel" "${fixture}/evidence"; then
      return 0
    fi
  done
  return 1
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
    "${fixture}/state" \
    "${fixture}/remote"

  cp "$ROTATE_SCRIPT" "${repo}/framework/scripts/rotate-vault-credentials.sh"
  chmod +x "${repo}/framework/scripts/rotate-vault-credentials.sh"
  printf '%s\n' 'fixture flake' > "${repo}/flake.nix"
  printf '%s\n' 'sops: fixture' > "${repo}/site/sops/secrets.yaml"
  printf '%s\n' "$OLD_UNSEAL" > "${fixture}/state/sops_unseal_dev"
  printf '%s\n' "$OLD_ROOT" > "${fixture}/state/sops_root_dev"
  printf '%s\n' "$OLD_UNSEAL" > "${fixture}/state/sops_unseal_prod"
  printf '%s\n' "$OLD_ROOT" > "${fixture}/state/sops_root_prod"
  printf '%s\n' "$OLD_UNSEAL" > "${fixture}/state/valid_share"
  # Issue #802 fix: resolve_operative_key requires either an ambient
  # SOPS_AGE_KEY_FILE or a canonical operator.age.key, and asserts the key
  # decrypts SECRETS_FILE before any mutation. The sops shim ignores key
  # contents; a placeholder is enough to satisfy the resolver's existence
  # and decrypt-probe checks.
  printf '%s\n' 'STUB_AGE_KEY' > "${repo}/operator.age.key"
  chmod 0400 "${repo}/operator.age.key"

  cat > "${repo}/site/config.yaml" <<'EOF'
vms:
  vault_dev:
    vmid: 141
    ip: 10.0.60.41
  vault_prod:
    vmid: 241
    ip: 10.0.10.41
  dns1_dev:
    ip: 10.0.60.10
  dns1_prod:
    ip: 10.0.10.10
EOF

  cat > "${repo}/framework/scripts/backup-now.sh" <<'EOF'
#!/usr/bin/env bash
pin_out=""
env_name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) env_name="$2"; shift 2 ;;
    --pin-out) pin_out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$pin_out" ]] || { echo "backup-now shim: missing --pin-out" >&2; exit 1; }
case "$env_name" in
  dev) vmid=141 ;;
  prod) vmid=241 ;;
  *) echo "backup-now shim: unexpected env: $env_name" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$pin_out")"
if [[ "${FAKE_INVALID_PIN:-0}" == "1" ]]; then
  printf '{"pins":{"%s":"placeholder"}}\n' "$vmid" > "$pin_out"
else
  printf '{"pins":{"%s":"pbs-nas:backup/vm/%s/2026-07-26T12:20:00Z"}}\n' "$vmid" "$vmid" > "$pin_out"
fi
case "$pin_out" in
  *post-rotation*) printf 'backup-post|%s\n' "$pin_out" >> "$EVENT_LOG" ;;
  *) printf 'backup-pre|%s\n' "$pin_out" >> "$EVENT_LOG" ;;
esac
snapshot_dir="${STATE_DIR}/pin-${vmid}"
rm -rf "$snapshot_dir"
mkdir -p "$snapshot_dir"
if [[ -d "${REMOTE_ROOT}/var/lib/vault" ]]; then
  cp -R "${REMOTE_ROOT}/var/lib/vault/." "$snapshot_dir/"
fi
if [[ -f "${STATE_DIR}/undurable" ]]; then
  while IFS= read -r undurable_path; do
    case "$undurable_path" in
      /var/lib/vault/*)
        rm -f "${snapshot_dir}/${undurable_path#/var/lib/vault/}"
        ;;
    esac
  done < "${STATE_DIR}/undurable"
fi
EOF
  chmod +x "${repo}/framework/scripts/backup-now.sh"

  cat > "${repo}/framework/scripts/restore-from-pbs.sh" <<'EOF'
#!/usr/bin/env bash
original_args="$*"
target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$target" ]] || { echo "restore-from-pbs shim: missing --target" >&2; exit 1; }
printf 'restore-from-pbs|%s\n' "$original_args" >> "$EVENT_LOG"
snapshot_dir="${STATE_DIR}/pin-${target}"
rm -rf "${REMOTE_ROOT}/var/lib/vault"
mkdir -p "${REMOTE_ROOT}/var/lib/vault"
if [[ -d "$snapshot_dir" ]]; then
  cp -R "${snapshot_dir}/." "${REMOTE_ROOT}/var/lib/vault/"
fi
if [[ -n "${FAKE_POST_RESTORE_DEAD_PROBES:-}" && "${FAKE_POST_RESTORE_DEAD_PROBES}" != "0" ]]; then
  printf '%s\n' "$FAKE_POST_RESTORE_DEAD_PROBES" > "${STATE_DIR}/dead_probes"
fi
exit 0
EOF
  chmod +x "${repo}/framework/scripts/restore-from-pbs.sh"

  cat > "${shims}/yq" <<'EOF'
#!/usr/bin/env bash
yaml_value() {
  local key="$1"
  local field="$2"
  local config_file="$3"
  awk -v key="$key" -v field="$field" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      match($0, /^[[:space:]]*/)
      indent = RLENGTH
      content = trim(substr($0, indent + 1))
      if (!in_block) {
        if (content == key ":") {
          in_block = 1
          block_indent = indent
        }
        next
      }
      if (indent <= block_indent) {
        exit
      }
      if (substr(content, 1, length(field) + 1) == field ":") {
        value = substr(content, length(field) + 2)
        sub(/[[:space:]]+#.*/, "", value)
        value = trim(value)
        if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
          value = substr(value, 2, length(value) - 2)
        }
        print value
        exit
      }
    }
  ' "$config_file"
}
expr="${2:-}"
pattern='^[[:space:]]*\.vms\.([[:alnum:]_]+)\.([[:alnum:]_]+)([[:space:]]*//[[:space:]]*"")?[[:space:]]*$'
if [[ "$expr" =~ $pattern ]]; then
  yaml_value "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${3:-}"
  exit 0
fi
echo "yq shim: unexpected expression: $expr" >&2
exit 1
EOF
  chmod +x "${shims}/yq"

  cat > "${shims}/sops" <<'EOF'
#!/usr/bin/env bash
# Issue #802 fixture requirement: every sops call must carry an explicit,
# existing SOPS_AGE_KEY_FILE. Rejecting an unset/stale value here matches
# the failure signature the fix is preventing.
set -euo pipefail
require_key() {
  local key="${SOPS_AGE_KEY_FILE:-}"
  [[ -n "$key" && -s "$key" ]] || { echo "sops shim: SOPS_AGE_KEY_FILE unset or stale: '${key}'" >&2; exit 1; }
}
if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" ]]; then
  require_key
  key="${3:-}"
  pattern='^\["vault_([[:alnum:]_]+)_(unseal_key|root_token)"\]$'
  if [[ ! "$key" =~ $pattern ]]; then
    echo "sops shim: unexpected extract key: $key" >&2
    exit 1
  fi
  env_name="${BASH_REMATCH[1]}"
  credential="${BASH_REMATCH[2]}"
  case "$credential" in
    unseal_key) state_file="${STATE_DIR}/sops_unseal_${env_name}" ;;
    root_token) state_file="${STATE_DIR}/sops_root_${env_name}" ;;
  esac
  printf 'sops-decrypt|vault_%s_%s\n' "$env_name" "$credential" >> "$EVENT_LOG"
  cat "$state_file"
  exit 0
fi
if [[ "${1:-}" == "-d" ]]; then
  # Whole-file decrypt for resolve_operative_key's probe.
  require_key
  printf 'sops-decrypt|whole-file\n' >> "$EVENT_LOG"
  printf '%s\n' 'STUB_DECRYPTED_YAML'
  exit 0
fi
if [[ "${1:-}" == "set" && "${2:-}" == "--value-file" ]]; then
  require_key
  key="${4:-}"
  # Issue #806 contract: SOPS requires a JSON-encoded string on stdin.
  # The r3 form is `--value-file <secrets> <index> /dev/stdin`, portable
  # to older sops that lacks `--value-stdin`. The shim requires the
  # positional /dev/stdin, JSON-parses the fed stdin, exits 7 with SOPS's
  # exact stderr on non-JSON. A driver regression to a raw value FILE
  # fails here with `sops shim: set value must be /dev/stdin`. Decode via
  # `jq -j .` and materialise into the state file so downstream state
  # assertions still see the sentinel string.
  if [[ "${5:-}" != "/dev/stdin" ]]; then
    echo "sops shim: set value must be /dev/stdin (issue #806 — jq -Rs pipe)" >&2
    exit 1
  fi
  stdin_bytes="$(cat)"
  if ! printf '%s' "$stdin_bytes" | jq empty >/dev/null 2>&1; then
    echo "Value for --set is not valid JSON" >&2
    exit 7
  fi
  decoded_file="$(mktemp)"
  printf '%s' "$stdin_bytes" | jq -j . > "$decoded_file"
  pattern='^\["vault_([[:alnum:]_]+)_(unseal_key|root_token)"\]$'
  if [[ ! "$key" =~ $pattern ]]; then
    rm -f "$decoded_file"
    echo "sops shim: unexpected set key: $key" >&2
    exit 1
  fi
  env_name="${BASH_REMATCH[1]}"
  credential="${BASH_REMATCH[2]}"
  case "$credential" in
    unseal_key)
      state_file="${STATE_DIR}/sops_unseal_${env_name}"
      ;;
    root_token)
      if [[ "${FAKE_SOPS_ROOT_SET_FAIL_NEW:-0}" == "1" ]] && grep -Fq "$NEW_ROOT_TOKEN" "$decoded_file"; then
        printf 'sops-set-fail|%s|/dev/stdin\n' "$key" >> "$EVENT_LOG"
        rm -f "$decoded_file"
        echo "sops shim injected second-write failure" >&2
        exit 61
      fi
      state_file="${STATE_DIR}/sops_root_${env_name}"
      ;;
  esac
  printf 'sops-set|%s|/dev/stdin\n' "$key" >> "$EVENT_LOG"
  mv "$decoded_file" "$state_file"
  exit 0
fi
echo "sops shim: unexpected args: $*" >&2
exit 1
EOF
  chmod +x "${shims}/sops"

  cat > "${shims}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd=""
destination=""
for arg in "$@"; do
  cmd="$arg"
  if [[ "$arg" == root@* ]]; then
    destination="$arg"
  fi
done
execute_delivery() {
  local remote_path="$1"
  local rewritten_cmd rc
  rewritten_cmd="${cmd//\/var\/lib\/vault/${REMOTE_ROOT}\/var\/lib\/vault}"
  set +e
  bash -c "$rewritten_cmd"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    printf 'ssh-deliver|%s|%s\n' "$destination" "$remote_path" >> "$EVENT_LOG"
    if [[ "$remote_path" == "/var/lib/vault/root-token" && "${FAKE_UNDURABLE_ROOT_DELIVERY:-0}" == "1" ]]; then
      printf '%s\n' "$remote_path" > "${STATE_DIR}/undurable"
    fi
  fi
  return "$rc"
}
if [[ "$cmd" == *'/var/lib/vault/unseal-key'* && "$cmd" == *'mktemp'* ]]; then
  if execute_delivery "/var/lib/vault/unseal-key"; then exit 0; else exit $?; fi
fi
if [[ "$cmd" == *'/var/lib/vault/root-token'* && "$cmd" == *'mktemp'* ]]; then
  if execute_delivery "/var/lib/vault/root-token"; then exit 0; else exit $?; fi
fi
if [[ "$cmd" == "$CONSUMER_REMOTE_COMMAND" ]]; then
  printf 'ssh-read|%s|/var/lib/vault/root-token\n' "$destination" >> "$EVENT_LOG"
  readback_count="$(grep -c '^ssh-read|' "$EVENT_LOG" || true)"
  if [[ "$readback_count" -le "${FAKE_READBACK_TRANSPORT_FAIL_TIMES:-0}" ]]; then
    exit 255
  fi
  rewritten_cmd="${cmd//\/var\/lib\/vault/${REMOTE_ROOT}\/var\/lib\/vault}"
  bash -c "$rewritten_cmd"
  exit $?
fi
if [[ "$cmd" == *'curl --config'* ]]; then
  config="$(mktemp)"
  trap 'rm -f "$config"' EXIT
  cat > "$config"
  printf 'ssh-proxy|%s\n' "$destination" >> "$EVENT_LOG"
  "$(dirname "$0")/_vault_curl_impl" --config "$config"
  exit $?
fi
echo "ssh shim: unexpected command: $cmd" >&2
exit 1
EOF
  chmod +x "${shims}/ssh"

  cat > "${shims}/_vault_curl_impl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == "--config" && -n "${2:-}" ]] || { echo "vault_curl shim: expected --config" >&2; exit 1; }
config="$2"
VAULT_STATUS_MARKER='__MYCOFU_HTTP_STATUS__'
method="$(awk -F'"' '/^request =/ {print $2; exit}' "$config")"
url="$(awk -F'"' '/^url =/ {print $2; exit}' "$config")"
path="${url#*/v1/}"
if [[ -f "${STATE_DIR}/dead_probes" ]]; then
  dead_probes="$(< "${STATE_DIR}/dead_probes")"
  if [[ "$dead_probes" == "never" ]]; then
    printf 'vault-unreachable|%s|%s\n' "$method" "$path" >> "$EVENT_LOG"
    echo "curl: (7) Failed to connect to Vault port 8200: Connection refused" >&2
    exit 7
  fi
  if [[ "$dead_probes" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$(( dead_probes - 1 ))" > "${STATE_DIR}/dead_probes"
    printf 'vault-unreachable|%s|%s\n' "$method" "$path" >> "$EVENT_LOG"
    echo "curl: (7) Failed to connect to Vault port 8200: Connection refused" >&2
    exit 7
  fi
fi
output_null=0
write_out=0
grep -Fq 'output = "/dev/null"' "$config" && output_null=1
grep -Fq 'write-out = "%{http_code}"' "$config" && write_out=1
grep -Fq 'write-out = "__MYCOFU_HTTP_STATUS__%{http_code}"' "$config" && write_out=2
submitted_key="$(python3 - "$config" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        if line.startswith("data = "):
            payload_text = json.loads(line.split(" = ", 1)[1])
            payload = json.loads(payload_text)
            print(payload.get("key", ""))
            break
PY
)"
token_kind="none"
if grep -Fq "$OLD_ROOT_TOKEN" "$config"; then
  token_kind="old"
elif grep -Fq "$NEW_ROOT_TOKEN" "$config"; then
  token_kind="new"
fi
old_revoked=0
[[ -f "${STATE_DIR}/old_revoked" ]] && old_revoked=1
printf 'vault|%s|%s|token=%s|null=%s|revoked=%s\n' "$method" "$path" "$token_kind" "$output_null" "$old_revoked" >> "$EVENT_LOG"

emit_status() {
  local status="$1"
  case "$write_out" in
    0) ;;
    1) printf '%s' "$status" ;;
    2) printf '%s%s' "$VAULT_STATUS_MARKER" "$status" ;;
  esac
}

case "${method}:${path}" in
  GET:sys/health)
    if [[ "${FAKE_VAULT_UNINIT:-0}" == "1" ]]; then
      printf '%s\n' '{"initialized":false,"sealed":false}'
      emit_status 501
    else
      printf '%s\n' '{"initialized":true,"sealed":false}'
      emit_status 200
    fi
    ;;
  POST:auth/token/lookup-self)
    if [[ "$token_kind" == "new" ]]; then
      emit_status 200
    elif [[ "$token_kind" == "old" && "${FAKE_OLD_TOKEN_BAD:-0}" != "1" && "$old_revoked" -eq 0 ]]; then
      emit_status 200
    else
      echo "permission denied" >&2
      emit_status 403
    fi
    ;;
  PUT:sys/rekey/init)
    if [[ "${FAKE_REKEY_INIT_BAD_RESPONSE:-0}" == "1" ]]; then
      printf '%s\n' '{}'
      emit_status 200
      exit 0
    fi
    printf '%s\n' '{"nonce":"rekey-nonce"}'
    emit_status 200
    ;;
  PUT:sys/rekey/update)
    valid_share="$(cat "${STATE_DIR}/valid_share")"
    if [[ "$submitted_key" != "$valid_share" ]]; then
      printf '%s\n' '{"errors":["rekey aborted: unable to authenticate: invalid key: failed to decrypt keys from storage: error decrypting seal wrapped value; cipher: message authentication failed"]}'
      emit_status 400
      exit 0
    fi
    printf '%s\n' "$NEW_UNSEAL" > "${STATE_DIR}/valid_share"
    printf '{"complete":true,"keys":["%s"]}\n' "$NEW_UNSEAL"
    emit_status 200
    ;;
  PUT:sys/generate-root/attempt)
    if [[ "${FAKE_GENROOT_ATTEMPT_BAD_RESPONSE:-0}" == "1" ]]; then
      printf '%s\n' '{}'
      emit_status 200
      exit 0
    fi
    python3 - <<'PY'
import json
import os
import string

token = os.environ["NEW_ROOT_TOKEN"].encode()
alphabet = string.ascii_letters + string.digits
otp = "".join(alphabet[(i * 17) % len(alphabet)] for i in range(len(token))).encode()
print(json.dumps({
    "started": True,
    "nonce": "genroot-nonce",
    "otp": otp.decode(),
    "progress": 0,
    "required": 1,
    "complete": False,
    "encoded_token": "",
    "encoded_root_token": "",
}))
PY
    emit_status 200
    ;;
  PUT:sys/generate-root/update)
    if [[ "${FAKE_GENROOT_UPDATE_FAIL:-0}" == "1" ]]; then
      echo "generate-root update injected failure" >&2
      exit 58
    fi
    valid_share="$(cat "${STATE_DIR}/valid_share")"
    if [[ "${FAKE_FORCE_STALE_GENROOT_SHARE:-0}" == "1" || "$submitted_key" != "$valid_share" ]]; then
      error_message='root generation aborted: unable to authenticate: unable to retrieve stored keys: invalid key: failed to decrypt keys from storage: error decrypting seal wrapped value; error decrypting using seal shamir: cipher: message authentication failed'
      if [[ "${FAKE_GENROOT_ERROR_ECHO_SHARE:-0}" == "1" ]]; then
        error_message="${error_message}: ${NEW_UNSEAL}"
      fi
      printf '{"errors":["%s"]}\n' "$error_message"
      emit_status 400
      exit 0
    fi
    if [[ "${FAKE_GENROOT_INCOMPLETE:-0}" == "1" ]]; then
      printf '%s\n' '{"complete":false,"progress":0,"required":1,"nonce":"genroot-nonce","started":true,"encoded_token":"","encoded_root_token":""}'
      emit_status 200
      exit 0
    fi
    python3 - <<'PY'
import base64
import json
import os
import string

token = os.environ["NEW_ROOT_TOKEN"].encode()
alphabet = string.ascii_letters + string.digits
otp = "".join(alphabet[(i * 17) % len(alphabet)] for i in range(len(token))).encode()
encoded = bytes(a ^ b for a, b in zip(token, otp))
encoded_text = base64.b64encode(encoded).decode().rstrip("=")
if len(encoded_text) % 4 == 0:
    raise SystemExit(
        "fixture regression: encoded_token decodes without padding repair; "
        "it no longer models Vault's unpadded RawStdEncoding contract (#970); "
        "NEW_ROOT must be a sentinel whose byte length is not a multiple of 3, so the unpadded encoding is not already a multiple of 4.")
if os.environ.get("FAKE_GENROOT_UNDECODABLE", "0") == "1":
    encoded_text = "!!" + encoded_text
encoded_root_text = encoded_text
if os.environ.get("FAKE_GENROOT_FIELDS_DISAGREE", "0") == "1":
    encoded_root_text = encoded_text + "A"
print(json.dumps({
    "complete": True,
    "progress": 1,
    "required": 1,
    "nonce": "genroot-nonce",
    "started": True,
    "encoded_token": encoded_text,
    "encoded_root_token": encoded_root_text,
}))
PY
    emit_status 200
    ;;
  PUT:auth/token/revoke-self)
    touch "${STATE_DIR}/old_revoked"
    emit_status 204
    ;;
  DELETE:sys/rekey/init)
    printf '%s\n' 'delete-rekey' >> "$EVENT_LOG"
    emit_status 204
    ;;
  DELETE:sys/generate-root/attempt)
    printf '%s\n' 'delete-generate-root' >> "$EVENT_LOG"
    emit_status 204
    ;;
  *)
    echo "vault_curl shim: unexpected ${method}:${path}" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${shims}/_vault_curl_impl"

  : > "${fixture}/events.log"
  printf '%s\n' "$fixture"
}

run_rotate() {
  local fixture="$1"
  local args="${2:-dev --i-mean-it}"
  local fake_uninit="${3:-0}"
  local old_token_bad="${4:-0}"
  local invalid_pin="${5:-0}"
  local genroot_fail="${6:-0}"
  local rekey_init_bad_response="${7:-0}"
  local genroot_attempt_bad_response="${8:-0}"
  local sops_root_set_fail_new="${9:-0}"
  local repo="${fixture}/repo"
  local force_stale_genroot_share="${FAKE_FORCE_STALE_GENROOT_SHARE:-0}"
  local genroot_fields_disagree="${FAKE_GENROOT_FIELDS_DISAGREE:-0}"
  local genroot_incomplete="${FAKE_GENROOT_INCOMPLETE:-0}"
  local genroot_undecodable="${FAKE_GENROOT_UNDECODABLE:-0}"
  local genroot_error_echo_share="${FAKE_GENROOT_ERROR_ECHO_SHARE:-0}"
  local undurable_root_delivery="${FAKE_UNDURABLE_ROOT_DELIVERY:-0}"
  local readback_transport_fail_times="${FAKE_READBACK_TRANSPORT_FAIL_TIMES:-0}"
  local post_restore_dead_probes="${FAKE_POST_RESTORE_DEAD_PROBES:-0}"
  local boot_wait_cap_seconds="${ROTATE_VAULT_BOOT_WAIT_SECONDS:-30}"
  local boot_wait_interval_seconds="${ROTATE_VAULT_BOOT_WAIT_INTERVAL_SECONDS:-1}"

  # Consume every one-shot injection explicitly so it cannot bleed into a
  # subsequent fixture through the calling shell's function environment.
  FAKE_FORCE_STALE_GENROOT_SHARE=0
  FAKE_GENROOT_FIELDS_DISAGREE=0
  FAKE_GENROOT_INCOMPLETE=0
  FAKE_GENROOT_UNDECODABLE=0
  FAKE_GENROOT_ERROR_ECHO_SHARE=0
  FAKE_UNDURABLE_ROOT_DELIVERY=0
  FAKE_READBACK_TRANSPORT_FAIL_TIMES=0
  FAKE_POST_RESTORE_DEAD_PROBES=0
  # bash keeps `VAR=x run_rotate ...` prefix assignments set (and exported)
  # after a FUNCTION returns, so the boot-wait seams are consumed here too —
  # otherwise a per-case cap/interval override silently governs every later
  # fixture, which is the same bleed class the block above guards against.
  ROTATE_VAULT_BOOT_WAIT_SECONDS=30
  ROTATE_VAULT_BOOT_WAIT_INTERVAL_SECONDS=1

  : > "${fixture}/events.log"
  rm -f "${fixture}/state/old_revoked"
  rm -f "${fixture}/state/undurable"
  rm -f "${fixture}/state/dead_probes"
  printf '%s\n' "${FAKE_INITIAL_VALID_SHARE:-$OLD_UNSEAL}" > "${fixture}/state/valid_share"
  set +e
  RUN_OUTPUT="$(
    env \
      PATH="${fixture}/shims:${PATH}" \
      HOME="${fixture}/home" \
      EVENT_LOG="${fixture}/events.log" \
      STATE_DIR="${fixture}/state" \
      REMOTE_ROOT="${fixture}/remote" \
      CONSUMER_REMOTE_COMMAND="$CONSUMER_REMOTE_COMMAND" \
      OLD_UNSEAL="$OLD_UNSEAL" \
      NEW_UNSEAL="$NEW_UNSEAL" \
      OLD_ROOT_TOKEN="$OLD_ROOT" \
      NEW_ROOT_TOKEN="$NEW_ROOT" \
      FAKE_VAULT_UNINIT="$fake_uninit" \
      FAKE_OLD_TOKEN_BAD="$old_token_bad" \
      FAKE_INVALID_PIN="$invalid_pin" \
      FAKE_GENROOT_UPDATE_FAIL="$genroot_fail" \
      FAKE_REKEY_INIT_BAD_RESPONSE="$rekey_init_bad_response" \
      FAKE_GENROOT_ATTEMPT_BAD_RESPONSE="$genroot_attempt_bad_response" \
      FAKE_SOPS_ROOT_SET_FAIL_NEW="$sops_root_set_fail_new" \
      FAKE_FORCE_STALE_GENROOT_SHARE="$force_stale_genroot_share" \
      FAKE_GENROOT_FIELDS_DISAGREE="$genroot_fields_disagree" \
      FAKE_GENROOT_INCOMPLETE="$genroot_incomplete" \
      FAKE_GENROOT_UNDECODABLE="$genroot_undecodable" \
      FAKE_GENROOT_ERROR_ECHO_SHARE="$genroot_error_echo_share" \
      FAKE_UNDURABLE_ROOT_DELIVERY="$undurable_root_delivery" \
      FAKE_READBACK_TRANSPORT_FAIL_TIMES="$readback_transport_fail_times" \
      FAKE_POST_RESTORE_DEAD_PROBES="$post_restore_dead_probes" \
      ROTATE_ESCROW_BASE="${fixture}/escrow" \
      ROTATE_UTC_STAMP="$UTC_STAMP" \
      ROTATE_EVIDENCE_DIR="${fixture}/evidence" \
      ROTATE_VAULT_BOOT_WAIT_SECONDS="$boot_wait_cap_seconds" \
      ROTATE_VAULT_BOOT_WAIT_INTERVAL_SECONDS="$boot_wait_interval_seconds" \
      bash -c 'cd "$1" && framework/scripts/rotate-vault-credentials.sh $2' bash "$repo" "$args" 2>&1
  )"
  RUN_STATUS=$?
  set -e
}

CONSUMER_READ_TOKEN=""
CONSUMER_NEW_STATUS=""
CONSUMER_OLD_STATUS=""
CONSUMER_OUTPUT=""
CONSUMER_STATUS=0
CONSUMER_MODELS_REAL=0

file_mode() {
  local path="$1" mode
  if mode="$(stat -f '%OLp' "$path" 2>/dev/null)"; then
    printf '%s\n' "$mode"
  else
    stat -c '%a' "$path"
  fi
}

consumer_fixture_models_post_deploy() {
  grep -Fq "$CONSUMER_REMOTE_COMMAND" "${REPO_ROOT}/framework/scripts/post-deploy.sh" &&
    grep -Fq 'VAULT_ROOT_TOKEN="$ROOT_TOKEN"' \
      "${REPO_ROOT}/framework/scripts/post-deploy.sh"
}

# Exercise the post-deploy consumer boundary through the same fixture shims as
# the driver: remote file read first, then lookup-self with that exact value.
run_root_token_consumer_contract() {
  local fixture="$1"
  local env_name="$2"
  local vault_ip="$3"
  local old_token_file="$4"
  local read_stderr new_stderr old_stderr new_config old_config old_token
  local read_rc=0 new_rc=0 old_rc=0
  local -a shim_env=(
    env
    "PATH=${fixture}/shims:${PATH}"
    "EVENT_LOG=${fixture}/events.log"
    "STATE_DIR=${fixture}/state"
    "REMOTE_ROOT=${fixture}/remote"
    "CONSUMER_REMOTE_COMMAND=${CONSUMER_REMOTE_COMMAND}"
    "OLD_ROOT_TOKEN=${OLD_ROOT}"
    "NEW_ROOT_TOKEN=${NEW_ROOT}"
    "OLD_UNSEAL=${OLD_UNSEAL}"
    "NEW_UNSEAL=${NEW_UNSEAL}"
  )

  read_stderr="${fixture}/state/consumer-read.stderr"
  new_stderr="${fixture}/state/consumer-new.stderr"
  old_stderr="${fixture}/state/consumer-old.stderr"
  new_config="${fixture}/state/consumer-new.curl-config"
  old_config="${fixture}/state/consumer-old.curl-config"

  set +e
  CONSUMER_READ_TOKEN="$("${shim_env[@]}" ssh -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new "root@${vault_ip}" \
    "$CONSUMER_REMOTE_COMMAND" 2>"$read_stderr")"
  read_rc=$?
  set -e

  old_token="$(< "$old_token_file")"
  printf 'request = "POST"\nurl = "https://%s:8200/v1/auth/token/lookup-self"\nheader = "X-Vault-Token: %s"\nwrite-out = "%%{http_code}"\n' \
    "$vault_ip" "$CONSUMER_READ_TOKEN" > "$new_config"
  printf 'request = "POST"\nurl = "https://%s:8200/v1/auth/token/lookup-self"\nheader = "X-Vault-Token: %s"\nwrite-out = "%%{http_code}"\n' \
    "$vault_ip" "$old_token" > "$old_config"

  set +e
  CONSUMER_NEW_STATUS="$("${shim_env[@]}" "${fixture}/shims/_vault_curl_impl" \
    --config "$new_config" 2>"$new_stderr")"
  new_rc=$?
  CONSUMER_OLD_STATUS="$("${shim_env[@]}" "${fixture}/shims/_vault_curl_impl" \
    --config "$old_config" 2>"$old_stderr")"
  old_rc=$?
  set -e

  CONSUMER_OUTPUT="$(printf 'read_rc=%s new_rc=%s new_http=%s old_rc=%s old_http=%s\n' \
    "$read_rc" "$new_rc" "$CONSUMER_NEW_STATUS" "$old_rc" "$CONSUMER_OLD_STATUS"; \
    cat "$read_stderr" "$new_stderr" "$old_stderr")"
  rm -f "$new_config" "$old_config"
  CONSUMER_STATUS=0
  CONSUMER_MODELS_REAL=0
  [[ "$read_rc" -eq 0 && "$new_rc" -eq 0 && "$old_rc" -eq 0 ]] || CONSUMER_STATUS=1
  [[ "$env_name" == "dev" || "$env_name" == "prod" ]] || CONSUMER_STATUS=1
  if consumer_fixture_models_post_deploy; then
    CONSUMER_MODELS_REAL=1
  else
    CONSUMER_STATUS=1
    CONSUMER_OUTPUT+=$'fixture no longer models the real consumer\n'
  fi
}

NO_FLAG_FIXTURE="$(make_fixture no-flag)"
run_rotate "$NO_FLAG_FIXTURE" "dev"

test_start "V2.5-i-mean-it" "--i-mean-it is required before Vault mutation"
if [[ "$RUN_STATUS" -eq 2 ]] &&
   grep -Fq 'Plan: rotate Vault dev unseal key and root token' <<< "$RUN_OUTPUT" &&
   [[ ! -s "${NO_FLAG_FIXTURE}/events.log" ]]; then
  test_pass "missing --i-mean-it prints plan and mutates nothing"
else
  test_fail "missing --i-mean-it did not fail closed"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

SUCCESS_FIXTURE="$(make_fixture success)"
run_rotate "$SUCCESS_FIXTURE"

test_start "V2.5-success-sequence" "Vault driver follows the API, delivery, SOPS, proof, backup, restore order"
EVENTS="${SUCCESS_FIXTURE}/events.log"
REKEY_INIT_LINE="$(first_line_number 'vault|PUT|sys/rekey/init' "$EVENTS")"
REKEY_UPDATE_LINE="$(first_line_number 'vault|PUT|sys/rekey/update' "$EVENTS")"
DELIVER_LINE="$(first_line_number 'ssh-deliver|root@10.0.60.41|/var/lib/vault/unseal-key' "$EVENTS")"
GEN_ATTEMPT_LINE="$(first_line_number 'vault|PUT|sys/generate-root/attempt' "$EVENTS")"
GEN_UPDATE_LINE="$(first_line_number 'vault|PUT|sys/generate-root/update' "$EVENTS")"
NEW_LOOKUP_LINE="$(first_line_number 'vault|POST|auth/token/lookup-self|token=new' "$EVENTS")"
ROOT_DELIVER_LINE="$(first_line_number 'ssh-deliver|root@10.0.60.41|/var/lib/vault/root-token' "$EVENTS")"
SOPS_UNSEAL_LINE="$(first_line_number 'sops-set|["vault_dev_unseal_key"]' "$EVENTS")"
SOPS_ROOT_LINE="$(first_line_number 'sops-set|["vault_dev_root_token"]' "$EVENTS")"
OLD_PROOF_LINE="$(first_line_number 'vault|POST|auth/token/lookup-self|token=old|null=1|revoked=1' "$EVENTS")"
POST_BACKUP_LINE="$(first_line_number 'backup-post|' "$EVENTS")"
RESTORE_LINE="$(first_line_number 'restore-from-pbs|--force --target 141 --backup-id pbs-nas:backup/vm/141/2026-07-26T12:20:00Z' "$EVENTS")"
RESTORE_NEW_LOOKUP_LINE="$(grep -Fn 'vault|POST|auth/token/lookup-self|token=new' "$EVENTS" | tail -1 | cut -d: -f1 || true)"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ -n "$REKEY_INIT_LINE" && -n "$REKEY_UPDATE_LINE" && -n "$DELIVER_LINE" && -n "$GEN_ATTEMPT_LINE" && -n "$GEN_UPDATE_LINE" ]] &&
   [[ -n "$NEW_LOOKUP_LINE" && -n "$ROOT_DELIVER_LINE" && -n "$SOPS_UNSEAL_LINE" && -n "$SOPS_ROOT_LINE" && -n "$OLD_PROOF_LINE" && -n "$POST_BACKUP_LINE" && -n "$RESTORE_LINE" && -n "$RESTORE_NEW_LOOKUP_LINE" ]] &&
   [[ "$REKEY_INIT_LINE" -lt "$REKEY_UPDATE_LINE" ]] &&
   [[ "$REKEY_UPDATE_LINE" -lt "$DELIVER_LINE" ]] &&
   [[ "$DELIVER_LINE" -lt "$GEN_ATTEMPT_LINE" ]] &&
   [[ "$GEN_ATTEMPT_LINE" -lt "$GEN_UPDATE_LINE" ]] &&
   [[ "$GEN_UPDATE_LINE" -lt "$NEW_LOOKUP_LINE" ]] &&
   [[ "$NEW_LOOKUP_LINE" -lt "$ROOT_DELIVER_LINE" ]] &&
   [[ "$ROOT_DELIVER_LINE" -lt "$SOPS_UNSEAL_LINE" ]] &&
   [[ "$ROOT_DELIVER_LINE" -lt "$OLD_PROOF_LINE" ]] &&
   [[ "$ROOT_DELIVER_LINE" -lt "$POST_BACKUP_LINE" ]] &&
   [[ "$SOPS_UNSEAL_LINE" -lt "$SOPS_ROOT_LINE" ]] &&
   [[ "$SOPS_ROOT_LINE" -lt "$OLD_PROOF_LINE" ]] &&
   [[ "$OLD_PROOF_LINE" -lt "$POST_BACKUP_LINE" ]] &&
   [[ "$POST_BACKUP_LINE" -lt "$RESTORE_LINE" ]] &&
   [[ "$RESTORE_LINE" -lt "$RESTORE_NEW_LOOKUP_LINE" ]]; then
  test_pass "event log proves the full M4 Vault ladder through restore-verify"
else
  test_fail "Vault success path order did not match V2.5"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$EVENTS" >&2
fi

test_start "V2.5-pin-captures-root-token" "post-rotation pin snapshot contains the delivered root token"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ -f "${SUCCESS_FIXTURE}/state/pin-141/root-token" ]] &&
   [[ "$(< "${SUCCESS_FIXTURE}/state/pin-141/root-token")" == "$(< "${SUCCESS_FIXTURE}/state/sops_root_dev")" ]]; then
  test_pass "the dev post-rotation pin contains the same root token as SOPS"
else
  test_fail "the dev post-rotation pin did not contain the delivered SOPS root token"
fi

run_root_token_consumer_contract "$SUCCESS_FIXTURE" dev 10.0.60.41 \
  "${SUCCESS_FIXTURE}/escrow/${UTC_STAMP}/vault-dev/vault_dev_root_token.current"

test_start "V2.5-root-token-consumer-dev" "post-deploy-shaped vdb read authenticates after the old token is revoked"
if [[ "$CONSUMER_STATUS" -eq 0 ]] &&
   [[ "$CONSUMER_MODELS_REAL" -eq 1 ]] &&
   [[ -n "$CONSUMER_READ_TOKEN" ]] &&
   [[ "$CONSUMER_READ_TOKEN" == "$(< "${SUCCESS_FIXTURE}/state/sops_root_dev")" ]] &&
   [[ "$(file_mode "${SUCCESS_FIXTURE}/remote/var/lib/vault/root-token")" == "400" ]] &&
   [[ "$CONSUMER_NEW_STATUS" == "200" ]] &&
   [[ "$CONSUMER_OLD_STATUS" == "403" ]] &&
   grep -Fxq 'ssh-read|root@10.0.60.41|/var/lib/vault/root-token' "$EVENTS" &&
   ! grep -Fq "$OLD_ROOT" <<< "$CONSUMER_OUTPUT" &&
   ! grep -Fq "$NEW_ROOT" <<< "$CONSUMER_OUTPUT"; then
  test_pass "the delivered dev token matches SOPS and authenticates while the escrowed old token proves 403"
else
  if [[ "$CONSUMER_MODELS_REAL" -ne 1 ]]; then
    test_fail "fixture no longer models the real consumer"
  else
    test_fail "the dev vdb token did not satisfy the post-deploy consumer contract (including mode 400)"
  fi
  printf '%s\n' "$CONSUMER_OUTPUT" >&2
fi

test_start "V2.5-sops-proof-and-static" "SOPS overwrite covers both entries and old-token proof discards body"
EVIDENCE="${SUCCESS_FIXTURE}/evidence/rotate-vault-dev-prove-negative.txt"
if [[ $((SOPS_UNSEAL_LINE + 1)) -eq "$SOPS_ROOT_LINE" ]] &&
   grep -Fq 'http_status=403' "$EVIDENCE" &&
   grep -Fq 'expected_http_status=403' "$EVIDENCE" &&
   grep -Fq 'vault|POST|auth/token/lookup-self|token=old|null=1|revoked=1' "$EVENTS" &&
   ! grep -Eq 'init-vault|--force-init' "$ROTATE_SCRIPT"; then
  test_pass "both Vault SOPS entries are written in one stage, proof uses /dev/null, and init-vault is absent"
else
  test_fail "SOPS/proof/static Vault assertions failed"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$EVENTS" >&2
  [[ -f "$EVIDENCE" ]] && cat "$EVIDENCE" >&2
fi

test_start "V2.5-sentinel-leak" "sentinel Vault bytes never appear in captured output or logs"
if ! grep -Fq "$OLD_UNSEAL" <<< "$RUN_OUTPUT" &&
   ! grep -Fq "$NEW_UNSEAL" <<< "$RUN_OUTPUT" &&
   ! grep -Fq "$OLD_ROOT" <<< "$RUN_OUTPUT" &&
   ! grep -Fq "$NEW_ROOT" <<< "$RUN_OUTPUT" &&
   ! grep -Fq "$OLD_UNSEAL" "$EVENTS" &&
   ! grep -Fq "$NEW_UNSEAL" "$EVENTS" &&
   ! grep -Fq "$OLD_ROOT" "$EVENTS" &&
   ! grep -Fq "$NEW_ROOT" "$EVENTS"; then
  test_pass "driver stdout/stderr and fixture logs contain no sentinel Vault values"
else
  test_fail "sentinel Vault material leaked to captured output or logs"
fi

DELAYED_BOOT_FIXTURE="$(make_fixture delayed-post-restore-boot)"
FAKE_POST_RESTORE_DEAD_PROBES=2 run_rotate "$DELAYED_BOOT_FIXTURE"
DELAYED_BOOT_EVENTS="${DELAYED_BOOT_FIXTURE}/events.log"
DELAYED_RESTORE_LINE="$(first_line_number 'restore-from-pbs|--force --target 141 --backup-id pbs-nas:backup/vm/141/2026-07-26T12:20:00Z' "$DELAYED_BOOT_EVENTS")"
DELAYED_UNREACHABLE_COUNT="$(awk -v after="$DELAYED_RESTORE_LINE" 'NR > after && $0 == "vault-unreachable|GET|sys/health" { count++ } END { print count + 0 }' "$DELAYED_BOOT_EVENTS")"
DELAYED_READINESS_LINE="$(awk -v after="$DELAYED_RESTORE_LINE" 'NR > after && index($0, "vault|GET|sys/health|") == 1 && index($0, "|null=1|") > 0 { print NR; exit }' "$DELAYED_BOOT_EVENTS")"
DELAYED_HEALTH_LINE="$(awk -v after="$DELAYED_READINESS_LINE" 'NR > after && index($0, "vault|GET|sys/health|") == 1 && index($0, "|null=0|") > 0 { print NR; exit }' "$DELAYED_BOOT_EVENTS")"
DELAYED_LOOKUP_LINE="$(awk -v after="$DELAYED_HEALTH_LINE" 'NR > after && index($0, "vault|POST|auth/token/lookup-self|token=new|") == 1 { print NR; exit }' "$DELAYED_BOOT_EVENTS")"
DELAYED_READBACK_LINE="$(awk -v after="$DELAYED_LOOKUP_LINE" 'NR > after && index($0, "ssh-read|") == 1 && index($0, "|/var/lib/vault/root-token") > 0 { print NR; exit }' "$DELAYED_BOOT_EVENTS")"

test_start "V2.5-post-restore-boot-wait-recovers" "two refused probes are retried before the full Step-8 verification chain"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ -n "$DELAYED_RESTORE_LINE" && "$DELAYED_UNREACHABLE_COUNT" -ge 2 ]] &&
   grep -Fq 'Vault API answered' <<< "$RUN_OUTPUT" &&
   [[ -n "$DELAYED_READINESS_LINE" && "$DELAYED_READINESS_LINE" -gt "$DELAYED_RESTORE_LINE" ]] &&
   [[ -n "$DELAYED_HEALTH_LINE" && "$DELAYED_HEALTH_LINE" -gt "$DELAYED_READINESS_LINE" ]] &&
   [[ -n "$DELAYED_LOOKUP_LINE" && "$DELAYED_LOOKUP_LINE" -gt "$DELAYED_HEALTH_LINE" ]] &&
   [[ -n "$DELAYED_READBACK_LINE" && "$DELAYED_READBACK_LINE" -gt "$DELAYED_LOOKUP_LINE" ]] &&
   grep -Fq 'Restore-verify passed:' <<< "$RUN_OUTPUT" &&
   ! fixture_leaks_sentinel "$DELAYED_BOOT_FIXTURE" "$RUN_OUTPUT"; then
  test_pass "the readiness wait rode through the dead window and the full restore verification ran"
else
  test_fail "the readiness wait did not preserve the full Step-8 verification chain"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$DELAYED_BOOT_EVENTS" >&2
fi

NEVER_READY_FIXTURE="$(make_fixture never-ready-after-restore)"
# cap 4s / interval 1s: long enough that the "it retried" assertion below
# cannot flake if one probe is slow on a loaded runner, short enough to keep
# the exhausted case a ~4s test.
ROTATE_VAULT_BOOT_WAIT_SECONDS=4 ROTATE_VAULT_BOOT_WAIT_INTERVAL_SECONDS=1 \
  FAKE_POST_RESTORE_DEAD_PROBES=never run_rotate "$NEVER_READY_FIXTURE"
NEVER_READY_EVENTS="${NEVER_READY_FIXTURE}/events.log"
NEVER_READY_UNREACHABLE_COUNT="$(grep -c '^vault-unreachable|GET|sys/health$' "$NEVER_READY_EVENTS" || true)"
NEVER_READY_RESTORE_LINE="$(first_line_number 'restore-from-pbs|--force --target 141 --backup-id pbs-nas:backup/vm/141/2026-07-26T12:20:00Z' "$NEVER_READY_EVENTS")"
NEVER_READY_READBACK_LINE="$(awk -v after="$NEVER_READY_RESTORE_LINE" 'NR > after && index($0, "ssh-read|") == 1 { print NR; exit }' "$NEVER_READY_EVENTS")"

test_start "V2.5-post-restore-boot-wait-exhausted" "a never-answering Vault exhausts the cap and fails closed with recovery guidance"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$NEVER_READY_UNREACHABLE_COUNT" -gt 1 ]] &&
   [[ -n "$NEVER_READY_RESTORE_LINE" && -z "$NEVER_READY_READBACK_LINE" ]] &&
   grep -Fq 'API never answered' <<< "$RUN_OUTPUT" &&
   grep -Fq 'Step 8 ALREADY restored' <<< "$RUN_OUTPUT" &&
   grep -Fq 'none of the Step-8 verification (health, new-token lookup-self, vdb root-token read-back) ran' <<< "$RUN_OUTPUT" &&
   grep -Fq '.claude/rules/process-discipline.md R-K' <<< "$RUN_OUTPUT" &&
   grep -Fq 'framework/scripts/validate.sh dev' <<< "$RUN_OUTPUT" &&
   grep -Fq 'EVIDENCE ONLY, DO NOT RESTORE' <<< "$RUN_OUTPUT" &&
   [[ -f "${NEVER_READY_FIXTURE}/evidence/rotate-vault-dev-boot-wait-probes.stderr" ]] &&
   ! grep -Fq 'Restore-verify passed:' <<< "$RUN_OUTPUT" &&
   ! fixture_leaks_sentinel "$NEVER_READY_FIXTURE" "$RUN_OUTPUT"; then
  test_pass "the bounded wait retries and reports the unknown restore-verification state honestly"
else
  test_fail "the never-answering fixture did not fail closed at the readiness boundary"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$NEVER_READY_EVENTS" >&2
fi

READBACK_RECOVERS_FIXTURE="$(make_fixture readback-transport-recovers)"
FAKE_READBACK_TRANSPORT_FAIL_TIMES=2 run_rotate "$READBACK_RECOVERS_FIXTURE"
READBACK_RECOVERS_OUTPUT="$RUN_OUTPUT"

test_start "V2.5-readback-transport-retry-recovers" "two read-back transport failures recover on the bounded third attempt"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   grep -Fq 'Restore-verify passed:' <<< "$RUN_OUTPUT" &&
   [[ "$(grep -c '^ssh-read|' "${READBACK_RECOVERS_FIXTURE}/events.log")" -eq 3 ]] &&
   ! fixture_leaks_sentinel "$READBACK_RECOVERS_FIXTURE" "$RUN_OUTPUT"; then
  test_pass "read-only vdb read-back recovered after exactly two transport retries"
else
  test_fail "vdb read-back did not recover on the bounded third attempt"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${READBACK_RECOVERS_FIXTURE}/events.log" >&2
fi

READBACK_EXHAUSTED_FIXTURE="$(make_fixture readback-transport-exhausted)"
FAKE_READBACK_TRANSPORT_FAIL_TIMES=3 run_rotate "$READBACK_EXHAUSTED_FIXTURE"
READBACK_EXHAUSTED_OUTPUT="$RUN_OUTPUT"

test_start "V2.5-readback-transport-exhausted" "three read-back transport failures fail closed as unknown, not wrong-token evidence"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$(grep -c '^ssh-read|' "${READBACK_EXHAUSTED_FIXTURE}/events.log")" -eq 3 ]] &&
   grep -Fq 'SSH transport failure (exit 255) on all 3 attempts' <<< "$RUN_OUTPUT" &&
   grep -Fq 'NOT evidence that the vdb token is wrong' <<< "$RUN_OUTPUT" &&
   ! fixture_leaks_sentinel "$READBACK_EXHAUSTED_FIXTURE" "$RUN_OUTPUT"; then
  test_pass "exhausted transport retries report unknown vdb content without leaking token material"
else
  test_fail "exhausted transport retries did not fail closed with the transport distinction"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${READBACK_EXHAUSTED_FIXTURE}/events.log" >&2
fi

UNDURABLE_FIXTURE="$(make_fixture undurable-root-delivery)"
FAKE_UNDURABLE_ROOT_DELIVERY=1 run_rotate "$UNDURABLE_FIXTURE"
UNDURABLE_OUTPUT="$RUN_OUTPUT"

test_start "V2.5-undurable-delivery-fails-closed" "a visible root token omitted from the pin is rejected after restore"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   [[ "$(grep -c '^ssh-read|' "${UNDURABLE_FIXTURE}/events.log")" -eq 1 ]] &&
   grep -Fq 'vdb root-token read-back' <<< "$RUN_OUTPUT" &&
   grep -Fq "Step 8 ALREADY restored VMID 141's vdb" <<< "$RUN_OUTPUT" &&
   grep -Fq "this driver's Step-8 restore removed it" <<< "$RUN_OUTPUT" &&
   grep -Fq 'was proved live by lookup-self HTTP 200 after the restore' <<< "$RUN_OUTPUT" &&
   grep -Fq 'restore-from-pbs.sh --force --target 141' <<< "$RUN_OUTPUT" &&
   grep -Fq 'validate.sh dev' <<< "$RUN_OUTPUT" &&
   grep -Fq '.claude/rules/process-discipline.md R-K' <<< "$RUN_OUTPUT" &&
   ! fixture_leaks_sentinel "$UNDURABLE_FIXTURE" "$RUN_OUTPUT"; then
  test_pass "post-restore vdb read-back fails closed without leaking token material"
else
  test_fail "undurable root-token delivery did not fail closed at the vdb read-back"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${UNDURABLE_FIXTURE}/events.log" >&2
fi

UNINIT_FIXTURE="$(make_fixture uninitialized)"
run_rotate "$UNINIT_FIXTURE" "dev --i-mean-it" 1

test_start "V2.5-refuse-uninitialized" "Vault rotation refuses uninitialized Vault"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'is uninitialized' <<< "$RUN_OUTPUT"; then
  test_pass "uninitialized health response fails closed"
else
  test_fail "uninitialized Vault was not rejected"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

BAD_TOKEN_FIXTURE="$(make_fixture bad-old-token)"
run_rotate "$BAD_TOKEN_FIXTURE" "dev --i-mean-it" 0 1

test_start "V2.5-refuse-bad-old-token" "Vault rotation refuses when pre-state root token fails lookup-self"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'pre-state root token failed lookup-self' <<< "$RUN_OUTPUT"; then
  test_pass "bad old root token fails closed before rotation starts"
else
  test_fail "bad old root token was not rejected"
  printf '%s\n' "$RUN_OUTPUT" >&2
fi

BAD_PIN_FIXTURE="$(make_fixture invalid-pin)"
run_rotate "$BAD_PIN_FIXTURE" "dev --i-mean-it" 0 0 1

test_start "V2.5-invalid-pin" "missing or placeholder PBS pin fails closed before mutation"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'has no real Vault volid' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'sys/rekey/init' "${BAD_PIN_FIXTURE}/events.log"; then
  test_pass "invalid pre-pin fails before any Vault rekey endpoint"
else
  test_fail "invalid pre-pin did not fail before mutation"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${BAD_PIN_FIXTURE}/events.log" >&2
fi

ABORT_FIXTURE="$(make_fixture abort-cleanup)"
run_rotate "$ABORT_FIXTURE" "dev --i-mean-it" 0 0 0 1

test_start "V2.5-abort-cleanup" "abort mid-flow deletes active generate-root attempt"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'generate-root update injected failure' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'delete-rekey' "${ABORT_FIXTURE}/events.log" &&
   [[ "$(grep -c '^delete-generate-root$' "${ABORT_FIXTURE}/events.log")" -eq 1 ]]; then
  test_pass "mid-flow abort invokes only the active generate-root cleanup DELETE endpoint"
else
  test_fail "abort cleanup did not target only the active generate-root attempt"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${ABORT_FIXTURE}/events.log" >&2
fi

STALE_SHARE_FIXTURE="$(make_fixture stale-genroot-share)"
FAKE_FORCE_STALE_GENROOT_SHARE=1 run_rotate "$STALE_SHARE_FIXTURE"
STALE_SHARE_OUTPUT="$RUN_OUTPUT"
STALE_SHARE_STATUS="$RUN_STATUS"

test_start "V2.5-stale-share-http-failure" "generate-root stale-share rejection reports HTTP/auth failure"
STALE_SHARE_EVIDENCE="${STALE_SHARE_FIXTURE}/evidence/vault-http-failure.txt"
if [[ "$STALE_SHARE_STATUS" -ne 0 ]] &&
   grep -Fq 'Vault request PUT sys/generate-root/update failed with HTTP 400' <<< "$STALE_SHARE_OUTPUT" &&
   grep -Fq 'message authentication failed' <<< "$STALE_SHARE_OUTPUT" &&
   grep -Fq 'response_shape=object keys=errors' "$STALE_SHARE_EVIDENCE" &&
   ! grep -Fq 'missing encoded_token' <<< "$STALE_SHARE_OUTPUT"; then
  test_pass "stale generate-root share is reported as the HTTP 400 authentication failure"
else
  test_fail "stale generate-root share produced a misleading or incomplete failure"
  printf '%s\n' "$STALE_SHARE_OUTPUT" >&2
  cat "${STALE_SHARE_FIXTURE}/events.log" >&2
  [[ -f "$STALE_SHARE_EVIDENCE" ]] && cat "$STALE_SHARE_EVIDENCE" >&2
fi

REDACTION_FIXTURE="$(make_fixture echoed-share-redaction)"
FAKE_FORCE_STALE_GENROOT_SHARE=1 FAKE_GENROOT_ERROR_ECHO_SHARE=1 run_rotate "$REDACTION_FIXTURE"
REDACTION_OUTPUT="$RUN_OUTPUT"
REDACTION_STATUS="$RUN_STATUS"
REDACTION_EVIDENCE="${REDACTION_FIXTURE}/evidence/vault-http-failure.txt"

test_start "V2.5-http-error-secret-redaction" "Vault error envelopes redact echoed credential values"
if [[ "$REDACTION_STATUS" -ne 0 ]] &&
   [[ -s "$REDACTION_EVIDENCE" ]] &&
   grep -Fq 'vault_error_class=' "$REDACTION_EVIDENCE" &&
   grep -Fq '<redacted>' "$REDACTION_EVIDENCE" &&
   ! grep -Fq "$NEW_UNSEAL" <<< "$REDACTION_OUTPUT" &&
   ! grep -Fq "$NEW_UNSEAL" "$REDACTION_EVIDENCE"; then
  test_pass "server-echoed unseal share is redacted from operator output and evidence"
else
  test_fail "Vault HTTP failure evidence leaked or failed to record an echoed share"
  printf '%s\n' "$REDACTION_OUTPUT" >&2
  [[ -f "$REDACTION_EVIDENCE" ]] && cat "$REDACTION_EVIDENCE" >&2
fi

test_start "V2.5-stale-share-abort-cleanup" "HTTP 400 leaves generate-root cleanup active"
if [[ "$STALE_SHARE_STATUS" -ne 0 ]] &&
   grep -Fq 'delete-generate-root' "${STALE_SHARE_FIXTURE}/events.log" &&
   ! grep -Fq 'delete-rekey' "${STALE_SHARE_FIXTURE}/events.log"; then
  test_pass "stale-share HTTP failure cancels only the orphaned generate-root attempt"
else
  test_fail "stale-share HTTP failure did not preserve generate-root abort cleanup"
  printf '%s\n' "$STALE_SHARE_OUTPUT" >&2
  cat "${STALE_SHARE_FIXTURE}/events.log" >&2
fi

REKEY_INIT_ABORT_FIXTURE="$(make_fixture rekey-init-validation-abort)"
run_rotate "$REKEY_INIT_ABORT_FIXTURE" "dev --i-mean-it" 0 0 0 0 1

test_start "V2.5-rekey-init-exit-cleanup" "explicit validation exit after rekey/init deletes active rekey attempt"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Vault rekey/init response did not include nonce' <<< "$RUN_OUTPUT" &&
   grep -Fq 'delete-rekey' "${REKEY_INIT_ABORT_FIXTURE}/events.log" &&
   ! grep -Fq 'delete-generate-root' "${REKEY_INIT_ABORT_FIXTURE}/events.log"; then
  test_pass "EXIT cleanup catches explicit post-rekey/init validation exit"
else
  test_fail "explicit rekey/init validation exit did not clean up the active attempt"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${REKEY_INIT_ABORT_FIXTURE}/events.log" >&2
fi

RECOVERY_STATE_FIXTURE="$(make_fixture recovery-state)"
FAKE_INITIAL_VALID_SHARE="$NEW_UNSEAL" run_rotate "$RECOVERY_STATE_FIXTURE"
RECOVERY_STATE_OUTPUT="$RUN_OUTPUT"

test_start "V2.5-recovery-state-stale-sops-share" "SOPS-old/Raft-new state fails during rekey authorization"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Vault request PUT sys/rekey/update failed with HTTP 400' <<< "$RUN_OUTPUT" &&
   grep -Fq 'message authentication failed' <<< "$RUN_OUTPUT" &&
   grep -Fq 'delete-rekey' "${RECOVERY_STATE_FIXTURE}/events.log" &&
   ! grep -Fq 'sys/generate-root/attempt' "${RECOVERY_STATE_FIXTURE}/events.log" &&
   ! grep -Fq 'delete-generate-root' "${RECOVERY_STATE_FIXTURE}/events.log" &&
   ! grep -Fq 'sops-set|' "${RECOVERY_STATE_FIXTURE}/events.log"; then
  test_pass "divergent recovery state fails in Step 3 and cancels only the rekey attempt"
else
  test_fail "divergent recovery state did not fail closed at rekey/update"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${RECOVERY_STATE_FIXTURE}/events.log" >&2
fi

INCOMPLETE_FIXTURE="$(make_fixture genroot-incomplete)"
FAKE_GENROOT_INCOMPLETE=1 run_rotate "$INCOMPLETE_FIXTURE"
INCOMPLETE_OUTPUT="$RUN_OUTPUT"

test_start "V2.5-generate-root-incomplete" "HTTP 200 generate-root response must carry a completed envelope"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'completion envelope invalid (progress=0, required=1)' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'sops-set|' "${INCOMPLETE_FIXTURE}/events.log" &&
   grep -Fq 'delete-generate-root' "${INCOMPLETE_FIXTURE}/events.log"; then
  test_pass "incomplete HTTP 200 generate-root response fails closed and cancels the attempt"
else
  test_fail "incomplete generate-root completion envelope was accepted or not cleaned up"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${INCOMPLETE_FIXTURE}/events.log" >&2
fi

GENROOT_ATTEMPT_ABORT_FIXTURE="$(make_fixture genroot-attempt-validation-abort)"
run_rotate "$GENROOT_ATTEMPT_ABORT_FIXTURE" "dev --i-mean-it" 0 0 0 0 0 1

test_start "V2.5-generate-root-attempt-exit-cleanup" "explicit validation exit after generate-root/attempt deletes active attempt"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Vault generate-root/attempt response missing nonce or otp' <<< "$RUN_OUTPUT" &&
   ! grep -Fq 'delete-rekey' "${GENROOT_ATTEMPT_ABORT_FIXTURE}/events.log" &&
   grep -Fq 'delete-generate-root' "${GENROOT_ATTEMPT_ABORT_FIXTURE}/events.log"; then
  test_pass "EXIT cleanup catches explicit post-generate-root/attempt validation exit"
else
  test_fail "explicit generate-root/attempt validation exit did not clean up the active attempt"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${GENROOT_ATTEMPT_ABORT_FIXTURE}/events.log" >&2
fi

DISAGREE_FIXTURE="$(make_fixture genroot-fields-disagree)"
FAKE_GENROOT_FIELDS_DISAGREE=1 run_rotate "$DISAGREE_FIXTURE"
DISAGREE_OUTPUT="$RUN_OUTPUT"

test_start "V2.5-generate-root-fields-disagree" "generate-root aliases must agree when both are populated"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'encoded_token and encoded_root_token disagree' <<< "$RUN_OUTPUT" &&
   [[ -s "${DISAGREE_FIXTURE}/escrow/${UTC_STAMP}/vault-dev/vault_dev_root_token.encoded" &&
      -s "${DISAGREE_FIXTURE}/escrow/${UTC_STAMP}/vault-dev/vault_dev_root_token.otp" ]] &&
   ! grep -Fq 'sops-set|' "${DISAGREE_FIXTURE}/events.log" &&
   grep -Fq 'delete-generate-root' "${DISAGREE_FIXTURE}/events.log"; then
  test_pass "different non-empty generate-root token fields fail closed"
else
  test_fail "driver selected one of two disagreeing generate-root token fields"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${DISAGREE_FIXTURE}/events.log" >&2
fi

DECODE_FAILURE_FIXTURE="$(make_fixture genroot-decode-failure-escrow)"
FAKE_GENROOT_UNDECODABLE=1 run_rotate "$DECODE_FAILURE_FIXTURE"
DECODE_FAILURE_OUTPUT="$RUN_OUTPUT"
DECODE_FAILURE_ENCODED="${DECODE_FAILURE_FIXTURE}/escrow/${UTC_STAMP}/vault-dev/vault_dev_root_token.encoded"
DECODE_FAILURE_OTP="${DECODE_FAILURE_FIXTURE}/escrow/${UTC_STAMP}/vault-dev/vault_dev_root_token.otp"

test_start "V2.5-genroot-decode-failure-escrow" \
  "a decode failure escrows the encoded token and OTP for recovery"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'Vault has ALREADY minted a root token' <<< "$RUN_OUTPUT" &&
   grep -Fq "  encoded token: ${DECODE_FAILURE_ENCODED}" <<< "$RUN_OUTPUT" &&
   grep -Fq "  one-time password: ${DECODE_FAILURE_OTP}" <<< "$RUN_OUTPUT" &&
   [[ -s "$DECODE_FAILURE_ENCODED" ]] &&
   [[ -s "$DECODE_FAILURE_OTP" ]] &&
   ! grep -Fq 'sops-set|' "${DECODE_FAILURE_FIXTURE}/events.log" &&
   ! grep -Fq 'backup-post|' "${DECODE_FAILURE_FIXTURE}/events.log"; then
  test_pass "decode failure preserves recovery inputs before any SOPS mutation or post-rotation backup"
else
  test_fail "decode failure did not preserve and name both recovery inputs"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${DECODE_FAILURE_FIXTURE}/events.log" >&2
fi

test_start "V2.5-new-fixtures-sentinel-leak" "new failure fixtures never expose sentinel Vault bytes"
if ! fixture_leaks_sentinel "$STALE_SHARE_FIXTURE" "$STALE_SHARE_OUTPUT" &&
   ! fixture_leaks_sentinel "$REDACTION_FIXTURE" "$REDACTION_OUTPUT" &&
   ! fixture_leaks_sentinel "$RECOVERY_STATE_FIXTURE" "$RECOVERY_STATE_OUTPUT" &&
   ! fixture_leaks_sentinel "$INCOMPLETE_FIXTURE" "$INCOMPLETE_OUTPUT" &&
   ! fixture_leaks_sentinel "$DISAGREE_FIXTURE" "$DISAGREE_OUTPUT" &&
   ! fixture_leaks_sentinel "$DECODE_FAILURE_FIXTURE" "$DECODE_FAILURE_OUTPUT" &&
   ! fixture_leaks_sentinel "$READBACK_RECOVERS_FIXTURE" "$READBACK_RECOVERS_OUTPUT" &&
   ! fixture_leaks_sentinel "$READBACK_EXHAUSTED_FIXTURE" "$READBACK_EXHAUSTED_OUTPUT" &&
   ! fixture_leaks_sentinel "$UNDURABLE_FIXTURE" "$UNDURABLE_OUTPUT"; then
  test_pass "new fixture output, event logs, and persistent evidence contain no sentinel Vault values"
else
  test_fail "failure fixtures leaked sentinel Vault material"
fi

PARTIAL_SOPS_FIXTURE="$(make_fixture partial-sops-write)"
run_rotate "$PARTIAL_SOPS_FIXTURE" "dev --i-mean-it" 0 0 0 0 0 0 1

test_start "V2.5-partial-sops-rollback" "second SOPS write failure reverts both Vault entries from escrow"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq 'sops shim injected second-write failure' <<< "$RUN_OUTPUT" &&
   grep -Fq 'SOPS reverted; Vault state may be inconsistent — restore from pin pbs-nas:backup/vm/141/2026-07-26T12:20:00Z' <<< "$RUN_OUTPUT" &&
   grep -Fq 'Escrow paths:' <<< "$RUN_OUTPUT" &&
   grep -Fq 'sops-set|["vault_dev_unseal_key"]' "${PARTIAL_SOPS_FIXTURE}/events.log" &&
   grep -Fq 'sops-set-fail|["vault_dev_root_token"]' "${PARTIAL_SOPS_FIXTURE}/events.log" &&
   [[ "$(cat "${PARTIAL_SOPS_FIXTURE}/state/sops_unseal_dev")" == "$OLD_UNSEAL" ]] &&
   [[ "$(cat "${PARTIAL_SOPS_FIXTURE}/state/sops_root_dev")" == "$OLD_ROOT" ]]; then
  test_pass "partial SOPS overwrite rolls back both entries and prints restore guidance"
else
  test_fail "partial SOPS overwrite did not roll back to escrowed values"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${PARTIAL_SOPS_FIXTURE}/events.log" >&2
fi

PROXY_FIXTURE="$(make_fixture proxy-binding)"
run_rotate "$PROXY_FIXTURE" "dev --i-mean-it"

test_start "V2.5-proxy-binding-dev" "no SSH in the dev leg reaches a prod address"
PROXY_EVENTS="${PROXY_FIXTURE}/events.log"
PROXY_COUNT="$(grep -c '^ssh-proxy|' "$PROXY_EVENTS" || true)"
DEV_PROXY_COUNT="$(grep -c '^ssh-proxy|root@10\.0\.60\.10$' "$PROXY_EVENTS" || true)"
VAULT_COUNT="$(grep -c '^vault|' "$PROXY_EVENTS" || true)"
RESTORE_PROXY_LINE="$(first_line_number 'restore-from-pbs|--force --target 141 --backup-id pbs-nas:backup/vm/141/2026-07-26T12:20:00Z' "$PROXY_EVENTS")"
LAST_VAULT_LINE="$(grep -n '^vault|' "$PROXY_EVENTS" | tail -1 | cut -d: -f1 || true)"
LAST_VAULT_EVENT="$(grep '^vault|' "$PROXY_EVENTS" | tail -1 || true)"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ "$PROXY_COUNT" -gt 0 && "$PROXY_COUNT" -eq "$DEV_PROXY_COUNT" ]] &&
   grep -Fxq 'ssh-deliver|root@10.0.60.41|/var/lib/vault/unseal-key' "$PROXY_EVENTS" &&
   grep -Fxq 'ssh-deliver|root@10.0.60.41|/var/lib/vault/root-token' "$PROXY_EVENTS" &&
   ! grep -Fq '10.0.10.10' "$PROXY_EVENTS" &&
   ! grep -Fq '10.0.10.41' "$PROXY_EVENTS" &&
   [[ "$VAULT_COUNT" -gt 0 && "$PROXY_COUNT" -eq "$VAULT_COUNT" ]] &&
   [[ -n "$RESTORE_PROXY_LINE" && -n "$LAST_VAULT_LINE" ]] &&
   [[ "$RESTORE_PROXY_LINE" -lt "$LAST_VAULT_LINE" ]] &&
   [[ "$LAST_VAULT_EVENT" == vault\|POST\|auth/token/lookup-self\|token=new\|* ]]; then
  test_pass "the full dev Vault ladder uses dns1_dev and its final call is the post-restore new-token lookup"
else
  test_fail "dev Vault requests did not remain bound to dns1_dev through restore-verify"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$PROXY_EVENTS" >&2
fi

PROD_PROXY_FIXTURE="$(make_fixture proxy-binding-prod)"
run_rotate "$PROD_PROXY_FIXTURE" "prod --i-mean-it"

test_start "V2.5-proxy-binding-prod" "no SSH in the prod leg reaches a dev address"
PROD_PROXY_EVENTS="${PROD_PROXY_FIXTURE}/events.log"
PROD_PROXY_COUNT="$(grep -c '^ssh-proxy|' "$PROD_PROXY_EVENTS" || true)"
PROD_DNS1_COUNT="$(grep -c '^ssh-proxy|root@10\.0\.10\.10$' "$PROD_PROXY_EVENTS" || true)"
PROD_VAULT_COUNT="$(grep -c '^vault|' "$PROD_PROXY_EVENTS" || true)"
PROD_RESTORE_PROXY_LINE="$(first_line_number 'restore-from-pbs|--force --target 241 --backup-id pbs-nas:backup/vm/241/2026-07-26T12:20:00Z' "$PROD_PROXY_EVENTS")"
PROD_LAST_VAULT_LINE="$(grep -n '^vault|' "$PROD_PROXY_EVENTS" | tail -1 | cut -d: -f1 || true)"
PROD_LAST_VAULT_EVENT="$(grep '^vault|' "$PROD_PROXY_EVENTS" | tail -1 || true)"
if [[ "$RUN_STATUS" -eq 0 ]] &&
   [[ "$PROD_PROXY_COUNT" -gt 0 && "$PROD_PROXY_COUNT" -eq "$PROD_DNS1_COUNT" ]] &&
   grep -Fxq 'ssh-deliver|root@10.0.10.41|/var/lib/vault/unseal-key' "$PROD_PROXY_EVENTS" &&
   grep -Fxq 'ssh-deliver|root@10.0.10.41|/var/lib/vault/root-token' "$PROD_PROXY_EVENTS" &&
   ! grep -Fq '10.0.60.10' "$PROD_PROXY_EVENTS" &&
   ! grep -Fq '10.0.60.41' "$PROD_PROXY_EVENTS" &&
   [[ "$PROD_VAULT_COUNT" -gt 0 && "$PROD_PROXY_COUNT" -eq "$PROD_VAULT_COUNT" ]] &&
   [[ -n "$PROD_RESTORE_PROXY_LINE" && -n "$PROD_LAST_VAULT_LINE" ]] &&
   [[ "$PROD_RESTORE_PROXY_LINE" -lt "$PROD_LAST_VAULT_LINE" ]] &&
   [[ "$PROD_LAST_VAULT_EVENT" == vault\|POST\|auth/token/lookup-self\|token=new\|* ]]; then
  test_pass "the full prod Vault ladder uses dns1_prod and its final call is the post-restore new-token lookup"
else
  test_fail "prod Vault requests did not remain bound to dns1_prod through restore-verify"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "$PROD_PROXY_EVENTS" >&2
fi

run_root_token_consumer_contract "$PROD_PROXY_FIXTURE" prod 10.0.10.41 \
  "${PROD_PROXY_FIXTURE}/escrow/${UTC_STAMP}/vault-prod/vault_prod_root_token.current"

test_start "V2.5-root-token-consumer-prod" "post-deploy-shaped prod vdb read authenticates after the old token is revoked"
if [[ "$CONSUMER_STATUS" -eq 0 ]] &&
   [[ "$CONSUMER_MODELS_REAL" -eq 1 ]] &&
   [[ -n "$CONSUMER_READ_TOKEN" ]] &&
   [[ "$CONSUMER_READ_TOKEN" == "$(< "${PROD_PROXY_FIXTURE}/state/sops_root_prod")" ]] &&
   [[ "$(file_mode "${PROD_PROXY_FIXTURE}/remote/var/lib/vault/root-token")" == "400" ]] &&
   [[ "$CONSUMER_NEW_STATUS" == "200" ]] &&
   [[ "$CONSUMER_OLD_STATUS" == "403" ]] &&
   grep -Fxq 'ssh-read|root@10.0.10.41|/var/lib/vault/root-token' "$PROD_PROXY_EVENTS" &&
   ! grep -Fq "$OLD_ROOT" <<< "$CONSUMER_OUTPUT" &&
   ! grep -Fq "$NEW_ROOT" <<< "$CONSUMER_OUTPUT"; then
  test_pass "the delivered prod token matches SOPS and authenticates while the escrowed old token proves 403"
else
  if [[ "$CONSUMER_MODELS_REAL" -ne 1 ]]; then
    test_fail "fixture no longer models the real consumer"
  else
    test_fail "the prod vdb token did not satisfy the post-deploy consumer contract (including mode 400)"
  fi
  printf '%s\n' "$CONSUMER_OUTPUT" >&2
fi

MISSING_PROXY_FIXTURE="$(make_fixture proxy-binding-missing-dev)"
sed -i.bak -e '/^  dns1_dev:$/ { N; d; }' "${MISSING_PROXY_FIXTURE}/repo/site/config.yaml"
run_rotate "$MISSING_PROXY_FIXTURE" "dev --i-mean-it"

test_start "V2.5-proxy-binding-missing-dev" "missing dns1_dev fails closed before any Vault contact"
if [[ "$RUN_STATUS" -ne 0 ]] &&
   grep -Fq '.vms.dns1_dev.ip missing' <<< "$RUN_OUTPUT" &&
   ! grep -q '^vault|' "${MISSING_PROXY_FIXTURE}/events.log" &&
   ! grep -q '^ssh-proxy|' "${MISSING_PROXY_FIXTURE}/events.log"; then
  test_pass "missing dns1_dev is named explicitly and no Vault request is attempted"
else
  test_fail "missing dns1_dev did not fail closed before Vault contact"
  printf '%s\n' "$RUN_OUTPUT" >&2
  cat "${MISSING_PROXY_FIXTURE}/events.log" >&2
fi

runner_summary
