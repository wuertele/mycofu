#!/usr/bin/env bash
# rotate-vault-credentials.sh — attended M4 Vault unseal/root rotation driver.
#
# Vault v1.21 API docs checked for request/response shapes:
# - Rekey API: https://developer.hashicorp.com/vault/api-docs/system/rekey
# - Generate-root API: https://developer.hashicorp.com/vault/api-docs/system/generate-root
# - Health API: https://developer.hashicorp.com/vault/api-docs/system/health
# - Token lookup/revoke API: https://developer.hashicorp.com/vault/api-docs/auth/token
#
# Plan citations:
# - A5 Vault API-only driver and DRT-004 SSH-proxy curl idiom: docs/sprints/SPRINT-049.md:390
# - A5 envelope steps 1-8, including restore-verify: docs/sprints/SPRINT-049.md:431
# - S2 restore-verify ruling: docs/sprints/drafts/SPRINT-049-REVIEW-MERGE-NOTES.md:45
# - V2.5 hermetic sequence/sentinel ratchet: docs/sprints/SPRINT-049.md:949
#
# The Vault curls run via the same SSH-proxy pattern used by DRT-004
# (framework/dr-tests/tests/DRT-004-vault-failover.sh:34-39). The proxy exists
# because macOS curl cannot complete TLS 1.3 against Vault's Go stack, which
# advertises X25519MLKEM768 (docs/prompts/report-vault-connectivity-investigation.md:78-98) —
# it is NOT a DNS workaround; the driver dials Vault by IP.
# The proxy MUST be the same environment's dns1: prod↔dev inter-VLAN traffic
# is intentionally blocked at the site gateway, so a prod proxy can never
# reach vault-dev (issue #947).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${ROTATE_VAULT_CONFIG:-${REPO_DIR}/site/config.yaml}"
SECRETS_FILE="${ROTATE_VAULT_SECRETS_FILE:-${REPO_DIR}/site/sops/secrets.yaml}"
ESCROW_BASE="${ROTATE_ESCROW_BASE:-${HOME}/.mycofu-escrow}"
UTC_STAMP="${ROTATE_UTC_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
EVIDENCE_DIR="${ROTATE_EVIDENCE_DIR:-${REPO_DIR}/build/drt/DRT-009/${UTC_STAMP}}"
CANONICAL_KEY_PATH="${ROTATE_SOPS_CANONICAL_KEY_PATH:-${REPO_DIR}/operator.age.key}"
BOOT_WAIT_CAP_SECONDS="${ROTATE_VAULT_BOOT_WAIT_SECONDS:-600}"
BOOT_WAIT_INTERVAL_SECONDS="${ROTATE_VAULT_BOOT_WAIT_INTERVAL_SECONDS:-10}"
ENV_NAME=""
I_MEAN_IT=0
REKEY_STARTED=0
GENROOT_STARTED=0
CLEANUP_ACTIVE=0
WORK_DIR=""
VAULT_STATUS_MARKER='__MYCOFU_HTTP_STATUS__'

# OPERATIVE_KEY: the age key file that the driver will pass to every sops
# invocation as an explicit SOPS_AGE_KEY_FILE=... prefix. Never inherited
# from the ambient environment (issue #802 defect 1). Resolved once at
# preflight; this driver does not move the key, so defect 2 does not apply.
OPERATIVE_KEY=""

usage() {
  awk 'NR<2 {next} !/^#/ {exit} {sub(/^# ?/, ""); print}' "$0"
  cat <<'EOF'

Usage:
  framework/scripts/rotate-vault-credentials.sh <dev|prod> --i-mean-it

Without --i-mean-it the script prints the mutation plan and exits 2.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    dev|prod)
      ENV_NAME="$1"
      shift
      ;;
    --i-mean-it)
      I_MEAN_IT=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

print_plan() {
  local env_display="${ENV_NAME:-<dev|prod>}"
  cat <<EOF
Plan: rotate Vault ${env_display} unseal key and root token.
  1. Take and verify a fresh pre-rotation PBS pin.
  2. Escrow current unseal/root token files and record path hashes.
  3. Run native sys/rekey/init + sys/rekey/update, deliver the new unseal key to /var/lib/vault/unseal-key, and verify health sealed=false.
  4. Run native sys/generate-root/attempt + update, decode and verify the new root token, then deliver it to /var/lib/vault/root-token.
  5. Perform one write-once SOPS overwrite stage for both Vault entries.
  6. Revoke/prove the old root token returns 403 with response body sent to /dev/null.
  7. Take and verify a fresh post-rotation PBS pin.
  8. Restore-verify from the post-rotation pin, wait up to ${BOOT_WAIT_CAP_SECONDS}s for the restored VM's Vault API to answer, then re-check health, new-token lookup-self, and the restored vdb root-token read-back.
EOF
}

if [[ ! "$BOOT_WAIT_CAP_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: ROTATE_VAULT_BOOT_WAIT_SECONDS must be a positive integer; got: ${BOOT_WAIT_CAP_SECONDS}" >&2
  exit 1
fi
if [[ ! "$BOOT_WAIT_INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: ROTATE_VAULT_BOOT_WAIT_INTERVAL_SECONDS must be a positive integer; got: ${BOOT_WAIT_INTERVAL_SECONDS}" >&2
  exit 1
fi

if [[ "$I_MEAN_IT" -ne 1 || -z "$ENV_NAME" ]]; then
  print_plan
  [[ -z "$ENV_NAME" ]] && usage >&2
  exit 2
fi

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: ${tool}" >&2
    exit 1
  fi
}

for tool in yq sops jq python3 ssh mkdir chmod sed tee; do
  require_tool "$tool"
done

ESCROW_DIR="${ESCROW_BASE}/${UTC_STAMP}/vault-${ENV_NAME}"
PRE_PIN="${ROTATE_VAULT_PRE_PIN:-${REPO_DIR}/build/restore-pin-${ENV_NAME}.json}"
POST_PIN="${ROTATE_VAULT_POST_PIN:-${REPO_DIR}/build/restore-pin-${ENV_NAME}-post-rotation.json}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rotate-vault-${ENV_NAME}.XXXXXX")"
mkdir -p "$ESCROW_DIR" "$EVIDENCE_DIR" "$(dirname "$PRE_PIN")" "$(dirname "$POST_PIN")"

CURRENT_UNSEAL_FILE="${ESCROW_DIR}/vault_${ENV_NAME}_unseal_key.current"
CURRENT_ROOT_FILE="${ESCROW_DIR}/vault_${ENV_NAME}_root_token.current"
NEW_UNSEAL_FILE="${ESCROW_DIR}/vault_${ENV_NAME}_unseal_key.new"
NEW_ROOT_FILE="${ESCROW_DIR}/vault_${ENV_NAME}_root_token.new"
GENROOT_ENCODED_FILE="${ESCROW_DIR}/vault_${ENV_NAME}_root_token.encoded"
GENROOT_OTP_FILE="${ESCROW_DIR}/vault_${ENV_NAME}_root_token.otp"
REKEY_NONCE_FILE="${WORK_DIR}/rekey-nonce"
GENROOT_NONCE_FILE="${WORK_DIR}/generate-root-nonce"

cleanup_attempts_on_abort() {
  local rc="$1"
  local stderr_file config_file payload_file
  if [[ "$CLEANUP_ACTIVE" -eq 1 ]]; then
    return 0
  fi
  CLEANUP_ACTIVE=1
  set +e
  if [[ "$REKEY_STARTED" -eq 1 || "$GENROOT_STARTED" -eq 1 ]]; then
    echo "ABORT CLEANUP: deleting any in-progress Vault rekey and generate-root attempts after operator approval gate."
  fi
  if [[ "$REKEY_STARTED" -eq 1 ]]; then
    stderr_file="${WORK_DIR}/rekey-delete.stderr"
    payload_file=""
    if [[ -s "$REKEY_NONCE_FILE" ]]; then
      payload_file="${WORK_DIR}/rekey-delete.json"
      jq -n --rawfile nonce "$REKEY_NONCE_FILE" '{nonce: ($nonce | rtrimstr("\n"))}' > "$payload_file"
    fi
    config_file="$(make_vault_config DELETE sys/rekey/init "" "$payload_file" 1 1)"
    vault_curl_config "$config_file" >/dev/null 2>"$stderr_file" || true
  fi
  if [[ "$GENROOT_STARTED" -eq 1 ]]; then
    stderr_file="${WORK_DIR}/generate-root-delete.stderr"
    config_file="$(make_vault_config DELETE sys/generate-root/attempt "" "" 1 1)"
    vault_curl_config "$config_file" >/dev/null 2>"$stderr_file" || true
  fi
  return 0
}

on_exit() {
  local rc=$?
  cleanup_attempts_on_abort "$rc"
  rm -rf "$WORK_DIR"
  exit "$rc"
}

on_signal() {
  local rc="$1"
  trap - INT TERM
  exit "$rc"
}

on_error() {
  local rc=$?
  trap - ERR
  cleanup_attempts_on_abort "$rc"
  exit "$rc"
}

trap on_exit EXIT
trap on_error ERR
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

VAULT_IP="$(yq -r ".vms.vault_${ENV_NAME}.ip" "$CONFIG_FILE")"
VAULT_VMID="$(yq -r ".vms.vault_${ENV_NAME}.vmid" "$CONFIG_FILE")"
# The SSH proxy MUST be the same environment's dns1 (issue #947): prod↔dev
# inter-VLAN traffic is intentionally blocked at the site gateway, so a
# prod proxy can never reach vault-dev. No cross-env fallback — an absent
# per-env key fails closed below rather than silently crossing VLANs.
DNS1_IP="$(yq -r ".vms.dns1_${ENV_NAME}.ip // \"\"" "$CONFIG_FILE")"
VAULT_URL="https://${VAULT_IP}:8200"

if [[ -z "$VAULT_IP" || "$VAULT_IP" == "null" || -z "$VAULT_VMID" || "$VAULT_VMID" == "null" ]]; then
  echo "ERROR: vault_${ENV_NAME} IP/VMID missing from ${CONFIG_FILE}" >&2
  exit 1
fi
if [[ -z "$DNS1_IP" || "$DNS1_IP" == "null" ]]; then
  echo "ERROR: .vms.dns1_${ENV_NAME}.ip missing from ${CONFIG_FILE} (SSH proxy for the ${ENV_NAME} Vault leg)" >&2
  exit 1
fi

hash_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

verify_pin_file() {
  local pin_file="$1"
  local vmid="$2"
  local volid=""
  if [[ ! -s "$pin_file" ]]; then
    echo "ERROR: missing or empty pin file: ${pin_file}" >&2
    exit 1
  fi
  volid="$(jq -r --arg vmid "$vmid" '(.pins[$vmid] // "") | if type == "object" then (.volid // "") else . end' "$pin_file")"
  if [[ ! "$volid" =~ ^pbs-nas:backup/vm/${vmid}/.+ ]]; then
    echo "ERROR: pin file ${pin_file} has no real Vault volid for VMID ${vmid}" >&2
    exit 1
  fi
  printf '%s\n' "$volid"
}

make_vault_config() {
  local method="$1"
  local api_path="$2"
  local token_file="$3"
  local data_file="$4"
  local output_null="$5"
  local write_out="$6"
  local config_file="${WORK_DIR}/curl-config.$(date +%s).$$.${RANDOM}"
  python3 - "$config_file" "$method" "${VAULT_URL}/v1/${api_path}" "$token_file" "$data_file" "$output_null" "$write_out" "$VAULT_STATUS_MARKER" <<'PY'
import json
import os
import sys

config_file, method, url, token_file, data_file, output_null, write_out, status_marker = sys.argv[1:9]

def line(fh, key, value):
    fh.write(f"{key} = {json.dumps(value)}\n")

with open(config_file, "w", encoding="utf-8") as fh:
    line(fh, "request", method)
    line(fh, "url", url)
    fh.write("silent\n")
    fh.write("show-error\n")
    fh.write("insecure\n")
    line(fh, "max-time", "20")
    if data_file:
        with open(data_file, "r", encoding="utf-8") as dfh:
            line(fh, "data", dfh.read())
        line(fh, "header", "Content-Type: application/json")
    if token_file:
        with open(token_file, "r", encoding="utf-8") as tfh:
            token = tfh.read().strip()
        line(fh, "header", f"X-Vault-Token: {token}")
    if output_null == "1":
        line(fh, "output", "/dev/null")
    if write_out == "1":
        line(fh, "write-out", "%{http_code}")
    elif write_out == "2":
        line(fh, "write-out", f"{status_marker}%{{http_code}}")
os.chmod(config_file, 0o400)
PY
  printf '%s\n' "$config_file"
}

vault_curl_config() {
  local config_file="$1"
  if command -v vault_curl >/dev/null 2>&1; then
    vault_curl --config "$config_file"
    return
  fi
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@${DNS1_IP}" \
    'tmp=$(mktemp /tmp/mycofu-vault-curl.XXXXXX); cat > "$tmp"; curl --config "$tmp"; rc=$?; rm -f "$tmp"; exit "$rc"' \
    < "$config_file"
}

record_vault_http_failure() {
  local method="$1"
  local api_path="$2"
  local http_status="$3"
  local body_file="$4"
  local evidence_file="${EVIDENCE_DIR}/vault-http-failure.txt"
  local response_shape vault_error_class body_bytes error_class_rc=0

  if jq -e 'type == "object"' "$body_file" >/dev/null 2>&1; then
    response_shape="object keys=$(jq -r 'keys_unsorted | join(",")' "$body_file")"
  elif jq -e 'true' "$body_file" >/dev/null 2>&1; then
    response_shape="JSON type=$(jq -r 'type' "$body_file")"
  else
    body_bytes="$(python3 - "$body_file" <<'PY'
import os
import sys

print(os.path.getsize(sys.argv[1]))
PY
)"
    response_shape="<non-JSON body, ${body_bytes} bytes>"
  fi

  trap - ERR
  set +e
  vault_error_class="$(
    jq -r '(.errors // []) | join("; ")' "$body_file" 2>/dev/null \
      | sed 's/[[:cntrl:]]//g' \
      | python3 -c '
import os
import sys

value = sys.stdin.read()
for path in sys.argv[1:]:
    if not path or not os.path.isfile(path) or os.path.getsize(path) == 0:
        continue
    try:
        with open(path, encoding="utf-8") as fh:
            secret = fh.read().strip()
    except OSError:
        continue
    if secret:
        value = value.replace(secret, "<redacted>")

suffix = "…<truncated>"
limit = 300
if len(value) > limit:
    value = value[:limit - len(suffix)] + suffix
sys.stdout.write(value)
' "${CURRENT_UNSEAL_FILE:-}" "${NEW_UNSEAL_FILE:-}" \
        "${CURRENT_ROOT_FILE:-}" "${NEW_ROOT_FILE:-}"
  )"
  error_class_rc=$?
  set -e
  trap on_error ERR
  if [[ "$error_class_rc" -eq 0 ]]; then
    [[ -n "$vault_error_class" ]] || vault_error_class="<none>"
  else
    vault_error_class="<unavailable>"
  fi

  if ! {
    printf 'ERROR: Vault request %s %s failed with HTTP %s\n' "$method" "$api_path" "$http_status"
    printf 'method=%s\n' "$method"
    printf 'api_path=%s\n' "$api_path"
    printf 'http_status=%s\n' "$http_status"
    printf 'response_shape=%s\n' "$response_shape"
    printf 'vault_error_class=%s\n' "$vault_error_class"
  } | (umask 077; tee -a "$evidence_file") >&2; then
    echo "WARNING: could not persist Vault HTTP failure evidence to ${evidence_file}" >&2
  fi
}

vault_request_json() {
  local method="$1"
  local api_path="$2"
  local token_file="$3"
  local data_file="$4"
  local output_file="$5"
  local status_mode="${6:-strict}"
  local config_file raw status body request_rc=0

  case "$status_mode" in
    strict|health) ;;
    *)
      echo "ERROR: invalid Vault JSON status mode: ${status_mode}" >&2
      exit 1
      ;;
  esac

  config_file="$(make_vault_config "$method" "$api_path" "$token_file" "$data_file" 0 2)"
  trap - ERR
  set +e
  raw="$(vault_curl_config "$config_file")"
  request_rc=$?
  set -e
  trap on_error ERR
  if [[ "$request_rc" -ne 0 ]]; then
    return "$request_rc"
  fi
  if [[ "$raw" != *"$VAULT_STATUS_MARKER"* ]]; then
    printf '%s' "$raw" > "$output_file"
    record_vault_http_failure "$method" "$api_path" "undetermined" "$output_file"
    exit 1
  fi

  status="${raw##*"$VAULT_STATUS_MARKER"}"
  body="${raw%"$VAULT_STATUS_MARKER"*}"
  printf '%s' "$body" > "$output_file"

  if [[ "$status_mode" == "strict" && ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    record_vault_http_failure "$method" "$api_path" "$status" "$output_file"
    exit 1
  fi
  if [[ "$status_mode" == "health" ]]; then
    case "$status" in
      200|429|472|473|474|501|503|530) ;;
      *)
        record_vault_http_failure "$method" "$api_path" "$status" "$output_file"
        exit 1
        ;;
    esac
    if ! jq -e 'true' "$output_file" >/dev/null 2>&1; then
      record_vault_http_failure "$method" "$api_path" "$status" "$output_file"
      exit 1
    fi
  fi
}

vault_request_status() {
  local method="$1"
  local api_path="$2"
  local token_file="$3"
  local data_file="$4"
  local stderr_file="$5"
  local config_file
  config_file="$(make_vault_config "$method" "$api_path" "$token_file" "$data_file" 1 1)"
  vault_curl_config "$config_file" 2>"$stderr_file"
}

payload_with_key_and_nonce() {
  local key_file="$1"
  local nonce_file="$2"
  local output_file="$3"
  jq -n --rawfile key "$key_file" --rawfile nonce "$nonce_file" \
    '{key: ($key | rtrimstr("\n")), nonce: ($nonce | rtrimstr("\n"))}' > "$output_file"
  chmod 0400 "$output_file"
}

decode_generate_root_token() {
  local encoded_file="$1"
  local otp_file="$2"
  local output_file="$3"
  if ! python3 - "$encoded_file" "$otp_file" "$output_file" <<'PY'
import base64
import sys

encoded_file, otp_file, output_file = sys.argv[1:4]
encoded_token = open(encoded_file, encoding="utf-8").read().strip()
otp_text = open(otp_file, encoding="utf-8").read().strip()
# Vault emits the encoded root token as UNPADDED base64
# (base64.RawStdEncoding); Python's b64decode requires padding. Restore it
# before decoding. validate=True turns a corrupted blob into a loud failure
# instead of a silent wrong-length decode (issue #970).
encoded = base64.b64decode(encoded_token + "=" * (-len(encoded_token) % 4),
                           validate=True)

otp_bytes = otp_text.encode("utf-8")
try:
    candidate = base64.b64decode(otp_text, validate=True)
    if len(candidate) == len(encoded):
        otp_bytes = candidate
except Exception:
    pass

if len(otp_bytes) != len(encoded):
    raise SystemExit("encoded_token and otp lengths differ")

token = bytes(a ^ b for a, b in zip(encoded, otp_bytes))
with open(output_file, "wb") as fh:
    fh.write(token)
PY
  then
    return 1
  fi
  chmod 0400 "$output_file"
}

deliver_unseal_key() {
  # /var/lib/vault is on vdb, which Step 7 captures and Step 8 restores; sync
  # the atomic rename and its data before the driver can proceed to that pin.
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@${VAULT_IP}" \
    "mkdir -p /var/lib/vault && tmp=\$(mktemp /var/lib/vault/unseal-key.XXXXXX) && trap 'rm -f \"\$tmp\"' EXIT && cat > \"\$tmp\" && chmod 400 \"\$tmp\" && mv \"\$tmp\" /var/lib/vault/unseal-key && sync" \
    < "$NEW_UNSEAL_FILE"
}

deliver_root_token() {
  # /var/lib/vault is on vdb, which Step 7 captures and Step 8 restores; sync
  # the atomic rename and its data before the driver can proceed to that pin.
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@${VAULT_IP}" \
    "mkdir -p /var/lib/vault && tmp=\$(mktemp /var/lib/vault/root-token.XXXXXX) && trap 'rm -f \"\$tmp\"' EXIT && cat > \"\$tmp\" && chmod 400 \"\$tmp\" && mv \"\$tmp\" /var/lib/vault/root-token && sync" \
    < "$NEW_ROOT_FILE"
}

require_operative_key() {
  local reason="$1"
  if [[ -z "${OPERATIVE_KEY:-}" || ! -s "$OPERATIVE_KEY" ]]; then
    echo "ERROR: operative age key missing (${reason}): ${OPERATIVE_KEY:-<unset>}" >&2
    exit 1
  fi
}

# Resolve OPERATIVE_KEY once: prefer the explicit ambient SOPS_AGE_KEY_FILE
# (the DRT export path), fall back to the repo's canonical operator.age.key.
# Then assert it decrypts the target SECRETS_FILE before any mutation.
resolve_operative_key() {
  if [[ -n "${SOPS_AGE_KEY_FILE:-}" && -s "${SOPS_AGE_KEY_FILE}" ]]; then
    OPERATIVE_KEY="${SOPS_AGE_KEY_FILE}"
  elif [[ -s "$CANONICAL_KEY_PATH" ]]; then
    OPERATIVE_KEY="$CANONICAL_KEY_PATH"
  else
    echo "ERROR: no operative age key found (SOPS_AGE_KEY_FILE unset and ${CANONICAL_KEY_PATH} missing)" >&2
    exit 1
  fi
  if ! SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" sops -d "$SECRETS_FILE" >/dev/null 2>&1; then
    echo "ERROR: operative age key ${OPERATIVE_KEY} cannot decrypt ${SECRETS_FILE}" >&2
    exit 1
  fi
}

sops_set_value_file_noerr() {
  local key="$1"
  local value_file="$2"
  local rc=0
  require_operative_key "sops set ${key}"
  trap - ERR
  set +e
  # SOPS's `set` requires the value to be a JSON-encoded string; raw file
  # content exits 7 with "Value for --set is not valid JSON" (issue #806).
  # `jq -Rs .` slurps the file as one JSON string, preserving newlines and
  # quotes losslessly. Piping into `--value-file /dev/stdin` keeps the value
  # out of process listings AND avoids writing a JSON-encoded intermediate
  # to disk; this form is portable to older sops that lack `--value-stdin`
  # (the newer flag was rejected by the CI runner's sops with "flag provided
  # but not defined: -value-stdin" — issue #806 pipeline #1926). With
  # `pipefail` (set at script top) `$?` returns the rightmost non-zero exit,
  # so the caller sees SOPS's exit code on SOPS failure (used by rollback
  # logic) and jq's exit code only if jq itself fails after SOPS succeeded
  # (impossible in practice).
  jq -Rs . < "$value_file" \
    | SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" sops set --value-file "$SECRETS_FILE" "$key" /dev/stdin >/dev/null
  rc=$?
  set -e
  trap on_error ERR
  return "$rc"
}

sops_set_vault_entries() {
  local rc=0 rollback_failed=0
  if [[ ! -s "$NEW_UNSEAL_FILE" || ! -s "$NEW_ROOT_FILE" ]]; then
    echo "ERROR: new Vault credential files are missing" >&2
    exit 1
  fi
  if sops_set_value_file_noerr "[\"vault_${ENV_NAME}_unseal_key\"]" "$NEW_UNSEAL_FILE"; then
    :
  else
    rc=$?
    echo "ERROR: SOPS write failed before vault_${ENV_NAME}_unseal_key landed; Vault state may be inconsistent — restore from pin ${PRE_VOLID}" >&2
    echo "Pre-rotation pin file: ${PRE_PIN}" >&2
    return "$rc"
  fi
  if sops_set_value_file_noerr "[\"vault_${ENV_NAME}_root_token\"]" "$NEW_ROOT_FILE"; then
    :
  else
    rc=$?
    echo "ERROR: SOPS write failed after vault_${ENV_NAME}_unseal_key landed; reverting both Vault SOPS entries from escrow." >&2
    if ! sops_set_value_file_noerr "[\"vault_${ENV_NAME}_unseal_key\"]" "$CURRENT_UNSEAL_FILE"; then
      rollback_failed=1
    fi
    if ! sops_set_value_file_noerr "[\"vault_${ENV_NAME}_root_token\"]" "$CURRENT_ROOT_FILE"; then
      rollback_failed=1
    fi
    if [[ "$rollback_failed" -eq 0 ]]; then
      echo "SOPS reverted; Vault state may be inconsistent — restore from pin ${PRE_VOLID}" >&2
    else
      echo "ERROR: SOPS revert failed; Vault state may be inconsistent — restore from pin ${PRE_VOLID}" >&2
    fi
    echo "Pre-rotation pin file: ${PRE_PIN}" >&2
    echo "Escrow paths: ${CURRENT_UNSEAL_FILE} ${CURRENT_ROOT_FILE}" >&2
    return "$rc"
  fi
}

resolve_operative_key

echo "=== Step 1: Fresh pre-rotation backup pin ==="
"${SCRIPT_DIR}/backup-now.sh" --env "$ENV_NAME" --pin-out "$PRE_PIN"
PRE_VOLID="$(verify_pin_file "$PRE_PIN" "$VAULT_VMID")"
echo "  Vault ${ENV_NAME} pre-rotation pin verified: ${PRE_VOLID}"
echo "  Abort point: no Vault state changed."

echo "=== Step 2: Escrow current Vault credentials ==="
SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" sops -d --extract "[\"vault_${ENV_NAME}_unseal_key\"]" "$SECRETS_FILE" > "$CURRENT_UNSEAL_FILE"
SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" sops -d --extract "[\"vault_${ENV_NAME}_root_token\"]" "$SECRETS_FILE" > "$CURRENT_ROOT_FILE"
chmod 0400 "$CURRENT_UNSEAL_FILE" "$CURRENT_ROOT_FILE"
{
  printf 'env=%s\n' "$ENV_NAME"
  printf 'unseal_key_path=%s\n' "$CURRENT_UNSEAL_FILE"
  printf 'unseal_key_sha256=%s\n' "$(hash_file "$CURRENT_UNSEAL_FILE")"
  printf 'root_token_path=%s\n' "$CURRENT_ROOT_FILE"
  printf 'root_token_sha256=%s\n' "$(hash_file "$CURRENT_ROOT_FILE")"
} > "${ESCROW_DIR}/escrow-record.txt"
chmod 0400 "${ESCROW_DIR}/escrow-record.txt"

HEALTH_JSON="${WORK_DIR}/health-pre.json"
# Vault's documented non-2xx health statuses are semantically meaningful
# (for example 429 standby, 501 uninitialized, and 503 sealed), so the health
# status allowlist accepts them and the typed body checks below decide health.
vault_request_json GET sys/health "" "" "$HEALTH_JSON" health
if ! jq -e '(.initialized | type) == "boolean" and (.sealed | type) == "boolean"' "$HEALTH_JSON" >/dev/null; then
  echo "ERROR: Vault sys/health response before rotation is missing or has malformed .initialized/.sealed JSON booleans" >&2
  exit 1
fi
INITIALIZED="$(jq -r '.initialized' "$HEALTH_JSON")"
SEALED="$(jq -r '.sealed' "$HEALTH_JSON")"
if [[ "$INITIALIZED" != "true" ]]; then
  echo "ERROR: Vault ${ENV_NAME} is uninitialized; rotation refuses initialization paths" >&2
  exit 1
fi
if [[ "$SEALED" != "false" ]]; then
  echo "ERROR: Vault ${ENV_NAME} is sealed before rotation" >&2
  exit 1
fi
OLD_LOOKUP_STDERR="${WORK_DIR}/old-token-precheck.stderr"
OLD_LOOKUP_STATUS="$(vault_request_status POST auth/token/lookup-self "$CURRENT_ROOT_FILE" "" "$OLD_LOOKUP_STDERR")"
if [[ "$OLD_LOOKUP_STATUS" != "200" ]]; then
  echo "ERROR: SOPS pre-state root token failed lookup-self with HTTP ${OLD_LOOKUP_STATUS}" >&2
  exit 1
fi
echo "  Escrow record written; pre-state token verified."
echo "  Abort point: no Vault credential rotation has started."

echo "=== Step 3: Native rekey and unseal-key delivery ==="
REKEY_INIT_PAYLOAD="${WORK_DIR}/rekey-init.json"
printf '%s\n' '{"secret_shares":1,"secret_threshold":1}' > "$REKEY_INIT_PAYLOAD"
REKEY_INIT_RESPONSE="${WORK_DIR}/rekey-init.response.json"
# Mark the attempt before the request: DELETE is idempotent if creation never
# reached Vault, while setting this afterward could orphan a server-side attempt.
REKEY_STARTED=1
vault_request_json PUT sys/rekey/init "" "$REKEY_INIT_PAYLOAD" "$REKEY_INIT_RESPONSE"
jq -r '.nonce // empty' "$REKEY_INIT_RESPONSE" > "$REKEY_NONCE_FILE"
if [[ ! -s "$REKEY_NONCE_FILE" ]]; then
  echo "ERROR: Vault rekey/init response did not include nonce" >&2
  exit 1
fi
REKEY_UPDATE_PAYLOAD="${WORK_DIR}/rekey-update.json"
payload_with_key_and_nonce "$CURRENT_UNSEAL_FILE" "$REKEY_NONCE_FILE" "$REKEY_UPDATE_PAYLOAD"
REKEY_UPDATE_RESPONSE="${WORK_DIR}/rekey-update.response.json"
vault_request_json PUT sys/rekey/update "" "$REKEY_UPDATE_PAYLOAD" "$REKEY_UPDATE_RESPONSE"
if ! jq -e '.complete == true' "$REKEY_UPDATE_RESPONSE" >/dev/null; then
  echo "ERROR: Vault rekey/update did not complete" >&2
  exit 1
fi
REKEY_STARTED=0
jq -r '(.keys[0] // .keys_base64[0] // empty)' "$REKEY_UPDATE_RESPONSE" > "$NEW_UNSEAL_FILE"
chmod 0400 "$NEW_UNSEAL_FILE"
if [[ ! -s "$NEW_UNSEAL_FILE" ]]; then
  echo "ERROR: Vault rekey/update response did not include a new unseal key" >&2
  exit 1
fi
deliver_unseal_key
HEALTH_AFTER_REKEY="${WORK_DIR}/health-after-rekey.json"
# Vault's documented non-2xx health statuses are semantically meaningful and
# are accepted only so these typed body checks can interpret the Vault state.
vault_request_json GET sys/health "" "" "$HEALTH_AFTER_REKEY" health
if ! jq -e '(.initialized | type) == "boolean" and (.sealed | type) == "boolean"' "$HEALTH_AFTER_REKEY" >/dev/null; then
  echo "ERROR: Vault sys/health response after unseal-key delivery is missing or has malformed .initialized/.sealed JSON booleans" >&2
  exit 1
fi
if ! jq -e '.initialized == true' "$HEALTH_AFTER_REKEY" >/dev/null; then
  echo "ERROR: Vault ${ENV_NAME} sys/health reports initialized=false after unseal-key delivery" >&2
  exit 1
fi
if ! jq -e '.sealed == false' "$HEALTH_AFTER_REKEY" >/dev/null; then
  echo "ERROR: Vault ${ENV_NAME} health is sealed after unseal-key delivery" >&2
  exit 1
fi
echo "  New unseal key delivered to /var/lib/vault/unseal-key; health sealed=false."
echo "  Abort point: old root token still valid; new unseal key has been delivered."

echo "=== Step 4: Native generate-root ==="
GENROOT_ATTEMPT_RESPONSE="${WORK_DIR}/generate-root-attempt.response.json"
# As with rekey, pre-mark the attempt so a missing curl write-out cannot leave
# a real server-side attempt orphaned; the cleanup DELETE is idempotent.
GENROOT_STARTED=1
vault_request_json PUT sys/generate-root/attempt "" "" "$GENROOT_ATTEMPT_RESPONSE"
jq -r '.nonce // empty' "$GENROOT_ATTEMPT_RESPONSE" > "$GENROOT_NONCE_FILE"
(umask 077; jq -r '.otp // empty' "$GENROOT_ATTEMPT_RESPONSE" > "$GENROOT_OTP_FILE")
if [[ ! -s "$GENROOT_NONCE_FILE" || ! -s "$GENROOT_OTP_FILE" ]]; then
  echo "ERROR: Vault generate-root/attempt response missing nonce or otp" >&2
  exit 1
fi
chmod 0400 "$GENROOT_OTP_FILE"
GENROOT_UPDATE_PAYLOAD="${WORK_DIR}/generate-root-update.json"
payload_with_key_and_nonce "$NEW_UNSEAL_FILE" "$GENROOT_NONCE_FILE" "$GENROOT_UPDATE_PAYLOAD"
GENROOT_UPDATE_RESPONSE="${WORK_DIR}/generate-root-update.response.json"
vault_request_json PUT sys/generate-root/update "" "$GENROOT_UPDATE_PAYLOAD" "$GENROOT_UPDATE_RESPONSE"
if ! jq -e '.complete == true and (.progress | type == "number") and (.required | type == "number") and .progress == .required' "$GENROOT_UPDATE_RESPONSE" >/dev/null; then
  GENROOT_PROGRESS="$(jq -r '.progress // "<missing>"' "$GENROOT_UPDATE_RESPONSE" 2>/dev/null || printf '<unavailable>')"
  GENROOT_REQUIRED="$(jq -r '.required // "<missing>"' "$GENROOT_UPDATE_RESPONSE" 2>/dev/null || printf '<unavailable>')"
  echo "ERROR: Vault sys/generate-root/update completion envelope invalid (progress=${GENROOT_PROGRESS}, required=${GENROOT_REQUIRED})" >&2
  exit 1
fi
# Persist at the mint boundary (#970): once completion passes, Vault has minted
# the root token, so persistence must precede every post-completion validation.
(umask 077; jq -r 'if (.encoded_token // "") != "" then .encoded_token elif (.encoded_root_token // "") != "" then .encoded_root_token else empty end' \
  "$GENROOT_UPDATE_RESPONSE" > "$GENROOT_ENCODED_FILE")
if [[ ! -s "$GENROOT_ENCODED_FILE" ]]; then
  echo "ERROR: Vault sys/generate-root/update response carried neither non-empty encoded_token nor encoded_root_token field" >&2
  exit 1
fi
chmod 0400 "$GENROOT_ENCODED_FILE"
if ! jq -e '(.encoded_token // "") as $token | (.encoded_root_token // "") as $root | $token == "" or $root == "" or $token == $root' "$GENROOT_UPDATE_RESPONSE" >/dev/null; then
  echo "ERROR: Vault sys/generate-root/update response encoded_token and encoded_root_token disagree" >&2
  echo "Vault has ALREADY minted a root token; the escrowed encoded blob (encoded_token) and OTP are its only recovery inputs:" >&2
  echo "  encoded token: ${GENROOT_ENCODED_FILE}" >&2
  echo "  one-time password: ${GENROOT_OTP_FILE}" >&2
  exit 1
fi
GENROOT_STARTED=0
if ! decode_generate_root_token "$GENROOT_ENCODED_FILE" "$GENROOT_OTP_FILE" "$NEW_ROOT_FILE"; then
  echo "ERROR: could not decode the Vault generate-root token; Vault has ALREADY minted a root token (completion is atomic with minting)." >&2
  echo "The minted token is recoverable from the escrowed encoded blob XOR the escrowed OTP:" >&2
  echo "  encoded token: ${GENROOT_ENCODED_FILE}" >&2
  echo "  one-time password: ${GENROOT_OTP_FILE}" >&2
  echo "No framework tool performs that decode-and-adopt today (see issue #971); the sanctioned path is the restore below." >&2
  echo "Restore from pin ${PRE_VOLID} if you choose to discard the minted token instead." >&2
  exit 1
fi
NEW_LOOKUP_STDERR="${WORK_DIR}/new-token-pre-sops.stderr"
NEW_LOOKUP_STATUS="$(vault_request_status POST auth/token/lookup-self "$NEW_ROOT_FILE" "" "$NEW_LOOKUP_STDERR")"
if [[ "$NEW_LOOKUP_STATUS" != "200" ]]; then
  echo "ERROR: new Vault root token failed lookup-self with HTTP ${NEW_LOOKUP_STATUS}" >&2
  exit 1
fi
if ! deliver_root_token; then
  echo "ERROR: root-token delivery to /var/lib/vault/root-token failed after Vault has already minted the new root token." >&2
  echo "The old root token is still valid because revoke-self has not run; the new token is escrowed at ${NEW_ROOT_FILE}." >&2
  echo "Restore anchor if recovery requires rollback: pre-rotation pin ${PRE_VOLID}." >&2
  exit 1
fi
echo "  New root token verified with lookup-self and delivered to /var/lib/vault/root-token."
echo "  Abort point: SOPS still contains the old Vault entries; both the old and new root tokens are currently valid."

echo "=== Step 5: One SOPS overwrite stage ==="
echo "APPROVAL: --i-mean-it accepted for write-once Vault SOPS breach; old values escrowed and pre-pin verified."
sops_set_vault_entries
echo "  SOPS entries vault_${ENV_NAME}_unseal_key and vault_${ENV_NAME}_root_token updated in one mutation stage."

echo "=== Step 6: Old-token revoke and prove-negative ==="
REVOKE_STDERR="${WORK_DIR}/old-token-revoke.stderr"
REVOKE_STATUS="$(vault_request_status PUT auth/token/revoke-self "$CURRENT_ROOT_FILE" "" "$REVOKE_STDERR")"
case "$REVOKE_STATUS" in
  200|204) ;;
  *)
    echo "ERROR: old Vault root token revoke-self returned HTTP ${REVOKE_STATUS}" >&2
    exit 1
    ;;
esac
OLD_PROOF_STDERR="${EVIDENCE_DIR}/rotate-vault-${ENV_NAME}-old-token.stderr"
OLD_PROOF_STATUS="$(vault_request_status POST auth/token/lookup-self "$CURRENT_ROOT_FILE" "" "$OLD_PROOF_STDERR")"
OLD_EVIDENCE="${EVIDENCE_DIR}/rotate-vault-${ENV_NAME}-prove-negative.txt"
{
  printf 'env=%s\n' "$ENV_NAME"
  printf 'old_root_token_path=%s\n' "$CURRENT_ROOT_FILE"
  printf 'old_root_token_sha256=%s\n' "$(hash_file "$CURRENT_ROOT_FILE")"
  printf 'http_status=%s\n' "$OLD_PROOF_STATUS"
  printf 'expected_http_status=403\n'
  printf 'stderr=\n'
  sed 's/[[:cntrl:]]//g' "$OLD_PROOF_STDERR"
} > "$OLD_EVIDENCE"
if [[ "$OLD_PROOF_STATUS" != "403" ]]; then
  echo "ERROR: old Vault root token did not prove 403; see ${OLD_EVIDENCE}" >&2
  exit 1
fi
echo "  Old-token prove-negative evidence: ${OLD_EVIDENCE}"

echo "=== Step 7: Fresh post-rotation backup pin ==="
"${SCRIPT_DIR}/backup-now.sh" --env "$ENV_NAME" --pin-out "$POST_PIN"
POST_VOLID="$(verify_pin_file "$POST_PIN" "$VAULT_VMID")"
echo "  Vault ${ENV_NAME} post-rotation pin verified: ${POST_VOLID}"

# Issue #978: framework/scripts/restore-from-pbs.sh:456-462 starts the restored
# VM and returns without a guest-boot wait, so the typed health check
# immediately below used to fire while the guest still had no listener and died
# on curl exit 7 before any Step-8 verification ran — including the vdb
# root-token read-back. This wait tests connectivity only; the
# typed health, new-token, and vdb read-back checks below remain unchanged and
# are still the sole judges of the answer. The 2026-08-30 00:54Z dev
# reproduction observed read-only verification succeeding about 60s after the
# restart; the 20:55Z closeout came about 20 minutes later and bounds readiness
# no tighter. The 600s default is a deliberately generous ~10x outer ceiling
# per .claude/rules/design-taste.md Principle 3 (theory sets generous ceilings,
# not starvation-tight ratchets): a slow restore-boot cannot turn a good
# rotation red, while "Vault never came up" still fails in bounded time. The
# cap bounds elapsed wall-clock measured across probes; the final in-flight
# probe may overrun it by curl's own 20s max-time.
wait_for_vault_api_after_restore() {
  local start_ts deadline now remaining rc=0 attempts=0 elapsed=0 config_file
  local last_rc="<none>"
  local probe_stderr="${EVIDENCE_DIR}/rotate-vault-${ENV_NAME}-boot-wait-probes.stderr"
  start_ts="$(date +%s)"
  deadline=$(( start_ts + BOOT_WAIT_CAP_SECONDS ))
  config_file="$(make_vault_config GET sys/health "" "" 1 1)"
  echo "  Waiting up to ${BOOT_WAIT_CAP_SECONDS}s for the restored VM's Vault API to answer."
  while :; do
    attempts=$(( attempts + 1 ))
    trap - ERR
    set +e
    vault_curl_config "$config_file" >/dev/null 2>>"$probe_stderr"
    rc=$?
    set -e
    trap on_error ERR
    now="$(date +%s)"
    elapsed=$(( now - start_ts ))
    if [[ "$rc" -eq 0 ]]; then
      echo "  Vault API answered ${elapsed}s after the restore-verify restart (${attempts} probe(s))."
      return 0
    fi
    last_rc="$rc"
    if [[ "$now" -ge "$deadline" ]]; then
      break
    fi
    # Clamping to the remaining budget makes every cap/interval pairing safe.
    remaining=$(( deadline - now ))
    if [[ "$remaining" -gt "$BOOT_WAIT_INTERVAL_SECONDS" ]]; then
      sleep "$BOOT_WAIT_INTERVAL_SECONDS"
    else
      sleep "$remaining"
    fi
  done

  echo "ERROR: Vault ${ENV_NAME} API never answered via the driver's Vault probe path (the vault_curl helper when one is on PATH, otherwise the SSH proxy root@${DNS1_IP}) within its ${BOOT_WAIT_CAP_SECONDS}s budget (plus the final in-flight probe, itself capped by curl max-time 20s) — ${elapsed}s elapsed, ${attempts} probes, last probe exit ${last_rc}; probe stderr: ${probe_stderr}" >&2
  echo "Probe exit 7 means the transport reached the host but nothing was listening on 8200; exit 255 means the transport itself failed, in which case the unreachable party may be the proxy rather than Vault. Read ${probe_stderr} to tell which." >&2
  echo "KNOWN: the rotation itself is complete — SOPS carries the new unseal key and new root token, the new token proved lookup-self HTTP 200 in Step 4, the old token proved HTTP 403 in Step 6, and the post-rotation pin ${POST_VOLID} was verified in Step 7. Step 8 ALREADY restored VMID ${VAULT_VMID}'s vdb from ${POST_VOLID} and issued a qm start for the VM, which restore-from-pbs.sh does not verify." >&2
  echo "NOT KNOWN: whether the VM booted, whether Vault is sealed or unsealed, or whether the restored vdb carries a durable copy of the new root token — none of the Step-8 verification (health, new-token lookup-self, vdb root-token read-back) ran. A connectivity timeout is NOT evidence that the restore was bad." >&2
  echo "Evidence paths:" >&2
  echo "  new token escrow: ${NEW_ROOT_FILE}" >&2
  echo "  old token escrow: ${CURRENT_ROOT_FILE}" >&2
  echo "  post-rotation pin: ${POST_PIN} (${POST_VOLID})" >&2
  echo "  evidence directory: ${EVIDENCE_DIR}" >&2
  echo "  pre-rotation pin: ${PRE_PIN} (${PRE_VOLID}) — EVIDENCE ONLY, DO NOT RESTORE: it predates the Step-6 revoke, so restoring it makes the OLD token live again while SOPS carries the NEW one" >&2
  echo "Legal forward paths (framework tooling only):" >&2
  echo "  1. Complete an RCA and establish the cause before acting; retry without one is barred by .claude/rules/process-discipline.md R-K." >&2
  echo "  2. Re-observe without mutation: framework/scripts/validate.sh ${ENV_NAME} — it reports Vault health and reads the same /var/lib/vault/root-token over the same SSH path that post-deploy.sh consumes, which is exactly the verification this driver did not reach." >&2
  echo "  3. If the RCA establishes the VM simply did not finish booting, re-run the path-2 observation once Vault answers; the restore itself does not need redoing." >&2
  echo "  4. Do NOT re-run this driver to \"finish\" Step 8 — a re-run rotates the credentials AGAIN from the top. Hand-placing the token file is barred by .claude/rules/no-manual-fixes.md Absolute 1; using an undocumented qm/ha-manager sequence to start or poke the VM is barred by Absolute 3." >&2
  exit 1
}

echo "=== Step 8: Restore-verify ==="
echo "APPROVAL: --i-mean-it accepted for restore-from-pbs.sh --force restore-verify of Vault ${ENV_NAME} from post-rotation pin."
"${SCRIPT_DIR}/restore-from-pbs.sh" --force --target "$VAULT_VMID" --backup-id "$POST_VOLID"
wait_for_vault_api_after_restore
HEALTH_AFTER_RESTORE="${WORK_DIR}/health-after-restore.json"
# Vault's documented non-2xx health statuses are semantically meaningful and
# are accepted only so these typed body checks can interpret the Vault state.
vault_request_json GET sys/health "" "" "$HEALTH_AFTER_RESTORE" health
if ! jq -e '(.initialized | type) == "boolean" and (.sealed | type) == "boolean"' "$HEALTH_AFTER_RESTORE" >/dev/null; then
  echo "ERROR: Vault sys/health response after restore-verify is missing or has malformed .initialized/.sealed JSON booleans" >&2
  exit 1
fi
if ! jq -e '.initialized == true' "$HEALTH_AFTER_RESTORE" >/dev/null; then
  echo "ERROR: Vault ${ENV_NAME} sys/health reports initialized=false after restore-verify" >&2
  exit 1
fi
if ! jq -e '.sealed == false' "$HEALTH_AFTER_RESTORE" >/dev/null; then
  echo "ERROR: Vault ${ENV_NAME} health is sealed after restore-verify" >&2
  exit 1
fi
RESTORE_LOOKUP_STDERR="${WORK_DIR}/new-token-after-restore.stderr"
RESTORE_LOOKUP_STATUS="$(vault_request_status POST auth/token/lookup-self "$NEW_ROOT_FILE" "" "$RESTORE_LOOKUP_STDERR")"
if [[ "$RESTORE_LOOKUP_STATUS" != "200" ]]; then
  echo "ERROR: new Vault root token failed lookup-self after restore-verify with HTTP ${RESTORE_LOOKUP_STATUS}" >&2
  exit 1
fi

fail_restored_vdb_readback() {
  local detail="$1"
  local transport_failure="${2:-0}"
  echo "ERROR: restored vdb root-token read-back failed: ${detail}" >&2
  echo "Step 8 ALREADY restored VMID ${VAULT_VMID}'s vdb from the post-rotation pin ${POST_VOLID}, overwriting /var/lib/vault on the VM with the pin's contents." >&2
  if [[ "$transport_failure" == "1" ]]; then
    echo "The content of /var/lib/vault/root-token on the restored vdb is UNKNOWN because SSH transport never returned a remote verdict; it is not known-bad." >&2
  else
    echo "If /var/lib/vault/root-token is absent — rather than merely unreadable — the Step-4 copy was not durable in the pin: this driver's Step-8 restore removed it, and the next post-deploy.sh run will fail to read it. Establish which condition applies under path 1 before acting." >&2
  fi
  echo "The new token escrowed at ${NEW_ROOT_FILE} was proved live by lookup-self HTTP 200 after the restore and is still the correct file value. SOPS already carries it, and the old root token is already revoked (proved HTTP 403 in Step 6)." >&2
  echo "Evidence paths:" >&2
  echo "  new token escrow: ${NEW_ROOT_FILE}" >&2
  echo "  old token escrow: ${CURRENT_ROOT_FILE}" >&2
  echo "  pre-rotation pin: ${PRE_PIN} (${PRE_VOLID}) — EVIDENCE ONLY, DO NOT RESTORE: it predates the Step-6 revoke, so restoring it makes the OLD token live again while SOPS carries the NEW one" >&2
  echo "  post-rotation pin: ${POST_PIN} (${POST_VOLID})" >&2
  echo "  evidence directory: ${EVIDENCE_DIR}" >&2
  echo "Legal forward paths (framework tooling only):" >&2
  echo "  1. Complete an RCA and establish the cause before acting; retry without one is barred by .claude/rules/process-discipline.md R-K." >&2
  echo "  2. Re-observe without mutation with framework/scripts/validate.sh ${ENV_NAME}; its vault-${ENV_NAME} vdb root token valid (lookup-self) check reads the same file over the same SSH path that post-deploy.sh consumes and reports PASS/WARN/FAIL." >&2
  echo "  3. Only after the RCA establishes a different POST-revoke pin containing a durable copy of the new token, use framework/scripts/restore-from-pbs.sh --force --target ${VAULT_VMID} --backup-id <post-revoke-pin>; ${POST_VOLID} has already been restored from and did not satisfy the read-back. Never restore the pre-rotation pin. If no such POST-revoke pin exists, use path 4. Run the validation in path 2 before and after." >&2
  echo "  4. If no pin has a durable copy, fix the durability cause established in step 1, then run framework/scripts/rotate-vault-credentials.sh ${ENV_NAME} --i-mean-it so the framework mints, delivers, re-pins, and re-verifies. Do not re-run it blindly." >&2
  echo "Hand-placing the token file is barred by .claude/rules/no-manual-fixes.md Absolute 1 (hand-placed artifact) and Absolute 3 (undocumented command sequence)." >&2
  exit 1
}

RESTORED_VDB_ROOT_FILE="${WORK_DIR}/root-token-from-vdb-after-restore"
read_back_restored_vdb_root_token() {
  local attempt rc=0
  local -r max_attempts=3
  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    rc=0
    (
      umask 077
      ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@${VAULT_IP}" \
        "cat /var/lib/vault/root-token 2>/dev/null" > "$RESTORED_VDB_ROOT_FILE"
    ) || rc=$?
    [[ "$rc" -eq 0 ]] && break
    [[ "$rc" -ne 255 ]] && break
    [[ "$attempt" -lt "$max_attempts" ]] && sleep 5
  done
  [[ -e "$RESTORED_VDB_ROOT_FILE" ]] && chmod 0400 "$RESTORED_VDB_ROOT_FILE"
  if [[ "$rc" -eq 0 ]]; then
    return 0
  fi
  if [[ "$rc" -eq 255 ]]; then
    fail_restored_vdb_readback \
      "SSH transport failure (exit 255) on all ${max_attempts} attempts; this is NOT evidence that the vdb token is wrong" 1
  fi
  fail_restored_vdb_readback \
    "the token file is absent or unreadable on the restored vdb (remote exit status ${rc})"
}

read_back_restored_vdb_root_token
if [[ ! -s "$RESTORED_VDB_ROOT_FILE" ]]; then
  fail_restored_vdb_readback "the restored token file is empty"
fi
RESTORED_VDB_ROOT_HASH="$(hash_file "$RESTORED_VDB_ROOT_FILE")"
NEW_ROOT_HASH="$(hash_file "$NEW_ROOT_FILE")"
if [[ "$RESTORED_VDB_ROOT_HASH" != "$NEW_ROOT_HASH" ]]; then
  fail_restored_vdb_readback \
    "SHA-256 mismatch (vdb=${RESTORED_VDB_ROOT_HASH:0:12} escrow=${NEW_ROOT_HASH:0:12})"
fi
RESTORED_VDB_LOOKUP_STDERR="${WORK_DIR}/vdb-token-after-restore.stderr"
RESTORED_VDB_LOOKUP_STATUS="$(vault_request_status POST auth/token/lookup-self "$RESTORED_VDB_ROOT_FILE" "" "$RESTORED_VDB_LOOKUP_STDERR")"
if [[ "$RESTORED_VDB_LOOKUP_STATUS" != "200" ]]; then
  fail_restored_vdb_readback \
    "the restored token failed lookup-self with HTTP ${RESTORED_VDB_LOOKUP_STATUS}"
fi
echo "  Restore-verify passed: health sealed=false, new-token lookup-self OK, and the restored vdb root-token read-back matches and authenticates."

echo "=== Vault ${ENV_NAME} credential rotation complete: restored vdb root-token read-back verified ==="
