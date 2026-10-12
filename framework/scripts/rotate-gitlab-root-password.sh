#!/usr/bin/env bash
# rotate-gitlab-root-password.sh — attended M4 GitLab root password driver.
#
# Plan citations:
# - A5 GitLab driver moved to MR-4 by S6: docs/sprints/SPRINT-049.md:471
# - T4.3 requires --i-mean-it, OAuth probes, and backup: docs/sprints/SPRINT-049.md:855
#   (T4.3's "configure-gitlab.sh scenario-2 reset" clause is superseded by the
#    operator ruling on issue #853, 2026-08-04: the driver's own Step 5 converge
#    replaces it, and the F3 premise it rested on was falsified by #848.)
# - Q-SPLIT-2 two-acts-one-window first live run: docs/sprints/SPRINT-049.md:1471
# - V2.4 stdout-redirection and sentinel ratchet: docs/sprints/SPRINT-049.md:948

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_FILE="${ROTATE_GITLAB_CONFIG:-${REPO_DIR}/site/config.yaml}"
SECRETS_FILE="${ROTATE_GITLAB_SECRETS_FILE:-${REPO_DIR}/site/sops/secrets.yaml}"
ESCROW_BASE="${ROTATE_ESCROW_BASE:-${HOME}/.mycofu-escrow}"
UTC_STAMP="${ROTATE_UTC_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
ESCROW_DIR="${ESCROW_BASE}/${UTC_STAMP}"
OLD_PASSWORD_ESCROW="${ESCROW_DIR}/gitlab_root_password"
NEW_PASSWORD_FILE="${ROTATE_GITLAB_NEW_PASSWORD_FILE:-${ESCROW_DIR}/gitlab_root_password.new}"
EVIDENCE_DIR="${ROTATE_EVIDENCE_DIR:-${REPO_DIR}/build/drt/DRT-009/${UTC_STAMP}}"
# Pin defaults are sink-tied so a fresh-shell rerun cannot overwrite an earlier
# run's pins while its proof/escrow persist under the earlier UTC sink. See
# Q-SPLIT-2 (docs/sprints/SPRINT-049.md:1471; "Both write into
# build/drt/DRT-009/<UTC>/" at :1475-1476); the G3 post-process reads pins from
# the same sink.
PRE_PIN="${ROTATE_GITLAB_PRE_PIN:-${EVIDENCE_DIR}/restore-pin-gitlab-pre-rotation.json}"
POST_PIN="${ROTATE_GITLAB_POST_PIN:-${EVIDENCE_DIR}/restore-pin-gitlab-post-rotation.json}"
CANONICAL_KEY_PATH="${ROTATE_SOPS_CANONICAL_KEY_PATH:-${REPO_DIR}/operator.age.key}"
I_MEAN_IT=0

# OPERATIVE_KEY: the age key file that the driver will pass to every sops
# invocation as an explicit SOPS_AGE_KEY_FILE=... prefix. Never inherited
# from the ambient environment (issue #802 defect 1). Resolved once at
# preflight; this driver does not move the key, so defect 2 does not apply.
OPERATIVE_KEY=""
CONVERGE_TEMP_FILES=()

cleanup_converge_temp_files() {
  if [[ "${#CONVERGE_TEMP_FILES[@]}" -gt 0 ]]; then
    rm -f "${CONVERGE_TEMP_FILES[@]}"
  fi
}

trap cleanup_converge_temp_files EXIT

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Usage:
  framework/scripts/rotate-gitlab-root-password.sh --i-mean-it

Without --i-mean-it the script prints the mutation plan and exits 2.
EOF
}

print_plan() {
  cat <<EOF
Plan: rotate gitlab_root_password.
  1. Take and verify a fresh pre-rotation PBS pin at: ${PRE_PIN}
  2. Escrow the old password to: ${OLD_PASSWORD_ESCROW}
  3. Generate the new password at: ${NEW_PASSWORD_FILE}
  4. Perform the one write-once SOPS overwrite gated by --i-mean-it.
  5. Converge the GitLab DB with the escrowed old password.
  6. Verify new OAuth password grant; prove old grant returns invalid_grant without an access token.
  7. Take and verify a fresh post-rotation PBS pin at: ${POST_PIN}
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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

if [[ "$I_MEAN_IT" -ne 1 ]]; then
  print_plan
  exit 2
fi

require_tool() {
  local tool="$1"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: ${tool}" >&2
    exit 1
  fi
}

for tool in yq sops curl jq openssl mkdir chmod sed tr; do
  require_tool "$tool"
done

mkdir -p "$ESCROW_DIR" "$EVIDENCE_DIR" "$(dirname "$PRE_PIN")" "$(dirname "$POST_PIN")"

GITLAB_IP="$(yq -r '.vms.gitlab.ip' "$CONFIG_FILE")"
GITLAB_VMID="$(yq -r '.vms.gitlab.vmid' "$CONFIG_FILE")"
DOMAIN="$(yq -r '.domain' "$CONFIG_FILE")"
GITLAB_URL="https://gitlab.prod.${DOMAIN}"

if [[ -z "$GITLAB_IP" || "$GITLAB_IP" == "null" || -z "$GITLAB_VMID" || "$GITLAB_VMID" == "null" ]]; then
  echo "ERROR: GitLab IP/VMID missing from ${CONFIG_FILE}" >&2
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
    echo "ERROR: pin file ${pin_file} has no real GitLab volid for VMID ${vmid}" >&2
    exit 1
  fi
  printf '%s\n' "$volid"
}

gitlab_grant_status() {
  local password_file="$1"
  local stderr_file="$2"
  local output_file="${3:-/dev/null}"
  curl -sk -X POST "${GITLAB_URL}/oauth/token" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=root" \
    --data-urlencode "password@${password_file}" \
    -o "$output_file" \
    -w '%{http_code}' \
    2>"$stderr_file"
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

sops_set_password_from_file() {
  local value_file="$1"
  require_operative_key "sops set gitlab_root_password"
  if [[ ! -s "$value_file" ]]; then
    echo "ERROR: new password file missing or empty: ${value_file}" >&2
    exit 1
  fi
  # SOPS's `set` requires the value to be a JSON-encoded string; raw file
  # content exits 7 with "Value for --set is not valid JSON" (issue #806).
  # `jq -Rs .` slurps the file as one JSON string, preserving newlines and
  # quotes losslessly. Piping into `--value-file /dev/stdin` keeps the value
  # out of process listings AND avoids writing a JSON-encoded intermediate
  # to disk; this form is portable to older sops that lack `--value-stdin`
  # (the newer flag was rejected by the CI runner's sops with "flag provided
  # but not defined: -value-stdin" — issue #806 pipeline #1926).
  jq -Rs . < "$value_file" \
    | SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" sops set --value-file "$SECRETS_FILE" '["gitlab_root_password"]' /dev/stdin >/dev/null
}

make_converge_temp_file() {
  local label="$1"
  local out_var="${2:-}"
  local path
  if [[ -z "$out_var" || ! "$out_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: invalid converge temp-file output variable name: ${out_var}" >&2
    exit 1
  fi
  path="$(mktemp "${ESCROW_DIR}/.${label}.XXXXXX")" || {
    echo "ERROR: cannot create secret temp file in ${ESCROW_DIR}" >&2
    exit 1
  }
  chmod 600 "$path" || {
    echo "ERROR: cannot chmod 0600 secret temp file ${path}" >&2
    exit 1
  }
  CONVERGE_TEMP_FILES+=("$path")
  printf -v "$out_var" '%s' "$path"
}

print_sops_revert_instruction() {
  echo "SOPS revert instruction: jq -Rs . < \"${OLD_PASSWORD_ESCROW}\" | SOPS_AGE_KEY_FILE=\"${OPERATIVE_KEY}\" sops set --value-file \"${SECRETS_FILE}\" '[\"gitlab_root_password\"]' /dev/stdin" >&2
}

print_converge_stderr_field() {
  local field="$1"
  local status="$2"
  local path="$3"
  if [[ "$status" == "not-run" ]]; then
    printf '%s=not-run\n' "$field"
  else
    printf '%s=%s\n' "$field" "$path"
  fi
}

write_gitlab_converge_evidence() {
  local evidence_file="$1"
  local old_status="$2"
  local put_status="$3"
  local new_status="$4"
  local old_stderr="$5"
  local put_stderr="$6"
  local new_stderr="$7"
  local old_after_put_status="${8:-not-run}"
  local old_after_put_stderr="${9:-}"
  local old_after_put_curl_rc="${10:-not-run}"
  local prev_umask

  prev_umask="$(umask)"
  umask 077
  mkdir -p "$(dirname "$evidence_file")" || {
    umask "$prev_umask"
    echo "ERROR: cannot create evidence dir for ${evidence_file}" >&2
    exit 1
  }
  if ! {
    printf 'old_grant_http_status=%s\n' "$old_status"
    printf 'put_http_status=%s\n' "$put_status"
    printf 'new_grant_http_status=%s\n' "$new_status"
    printf 'expected_new_grant_http_status=200\n'
    printf 'old_after_put_http_status=%s\n' "$old_after_put_status"
    printf 'old_after_put_curl_rc=%s\n' "$old_after_put_curl_rc"
    print_converge_stderr_field "old_grant_stderr_file" "$old_status" "$old_stderr"
    print_converge_stderr_field "put_stderr_file" "$put_status" "$put_stderr"
    print_converge_stderr_field "new_grant_stderr_file" "$new_status" "$new_stderr"
    print_converge_stderr_field "old_after_put_stderr_file" "$old_after_put_status" "$old_after_put_stderr"
  } > "$evidence_file"; then
    umask "$prev_umask"
    echo "ERROR: cannot write GitLab converge evidence ${evidence_file}" >&2
    exit 1
  fi
  chmod 600 "$evidence_file" || {
    umask "$prev_umask"
    echo "ERROR: cannot chmod 0600 GitLab converge evidence ${evidence_file}" >&2
    exit 1
  }
  umask "$prev_umask"
}

write_gitlab_prove_negative_evidence() {
  local evidence_file="$1"
  local old_password_path="$2"
  local old_hash="$3"
  local http_status="$4"
  local curl_rc="$5"
  local body_json="$6"
  local error_field="$7"
  local access_token_present="$8"
  local verdict="$9"
  local stderr_file="${10}"
  local stderr_text=""
  local prev_umask

  safe_scalar() {
    local value="$1"
    local safe
    safe="$(printf '%s' "$value" | LC_ALL=C tr '\r\n' '  ' | LC_ALL=C sed 's/[[:cntrl:]]/?/g; s/[^A-Za-z0-9._:@+=,\/\\ -]/?/g')"
    if [[ "$safe" != "$value" ]]; then
      printf '%s sanitized=true' "$safe"
    else
      printf '%s' "$safe"
    fi
  }
  [[ ! -f "$stderr_file" ]] || stderr_text="$(< "$stderr_file")"

  prev_umask="$(umask)"
  umask 077
  mkdir -p "$(dirname "$evidence_file")" || {
    umask "$prev_umask"
    echo "ERROR: cannot create evidence dir for ${evidence_file}" >&2
    exit 1
  }
  if ! {
    printf 'old_password_path=%s\n' "$old_password_path"
    printf 'old_password_sha256=%s\n' "$old_hash"
    printf 'http_status=%s\n' "$(safe_scalar "$http_status")"
    printf 'expected_http_status=400_or_401\n'
    printf 'curl_rc=%s\n' "$(safe_scalar "$curl_rc")"
    printf 'body_json=%s\n' "$(safe_scalar "$body_json")"
    printf 'error_field=%s\n' "$(safe_scalar "$error_field")"
    printf 'expected_error=invalid_grant\n'
    printf 'access_token_present=%s\n' "$(safe_scalar "$access_token_present")"
    printf 'expected_access_token_present=false\n'
    if [[ "$verdict" == "PASS" ]]; then
      printf 'old_password_prove_negative_verdict=PASS\n'
    fi
    printf 'stderr=%s\n' "$(safe_scalar "$stderr_text")"
  } > "$evidence_file"; then
    umask "$prev_umask"
    echo "ERROR: cannot write GitLab prove-negative evidence ${evidence_file}" >&2
    exit 1
  fi
  chmod 600 "$evidence_file" || {
    umask "$prev_umask"
    echo "ERROR: cannot chmod 0600 GitLab prove-negative evidence ${evidence_file}" >&2
    exit 1
  }
  umask "$prev_umask"
}

fail_after_sops_overwrite() {
  local message="$1"
  local evidence_file="$2"
  echo "ERROR: ${message}" >&2
  echo "See converge evidence: ${evidence_file}" >&2
  print_sops_revert_instruction
  exit 1
}

gitlab_converge_root_password() {
  local evidence_file="${EVIDENCE_DIR}/rotate-gitlab-converge.txt"
  local old_grant_stderr="${EVIDENCE_DIR}/rotate-gitlab-converge-old-grant.stderr"
  local put_stderr="${EVIDENCE_DIR}/rotate-gitlab-converge-put.stderr"
  local new_grant_stderr="${EVIDENCE_DIR}/rotate-gitlab-converge-new-grant.stderr"
  local old_after_put_stderr="${EVIDENCE_DIR}/rotate-gitlab-converge-old-after-put.stderr"
  local oauth_response auth_config put_response
  local old_status="not-run"
  local put_status="not-run"
  local new_status="not-run"
  local old_after_put_status="not-run"
  local old_curl_rc=0
  local put_curl_rc=0
  local new_curl_rc=0
  local old_after_put_curl_rc="not-run"
  local access_token=""
  local prev_umask

  make_converge_temp_file gitlab-oauth-response oauth_response
  make_converge_temp_file gitlab-auth-config auth_config
  make_converge_temp_file gitlab-put-response put_response

  prev_umask="$(umask)"
  umask 077
  set +e
  old_status="$(curl -sk -X POST "${GITLAB_URL}/oauth/token" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "username=root" \
    --data-urlencode "password@${OLD_PASSWORD_ESCROW}" \
    -o "$oauth_response" \
    -w '%{http_code}' \
    2>"$old_grant_stderr")"
  old_curl_rc=$?
  set -e
  umask "$prev_umask"

  if [[ "$old_curl_rc" -ne 0 || "$old_status" != "200" ]]; then
    write_gitlab_converge_evidence "$evidence_file" "$old_status" "$put_status" "$new_status" "$old_grant_stderr" "$put_stderr" "$new_grant_stderr"
    fail_after_sops_overwrite "escrowed old gitlab_root_password OAuth grant failed during converge (curl rc=${old_curl_rc}, HTTP ${old_status})" "$evidence_file"
  fi

  access_token="$(jq -r '.access_token // empty' "$oauth_response" 2>/dev/null || true)"
  if [[ -z "$access_token" ]]; then
    write_gitlab_converge_evidence "$evidence_file" "$old_status" "$put_status" "$new_status" "$old_grant_stderr" "$put_stderr" "$new_grant_stderr"
    fail_after_sops_overwrite "escrowed old gitlab_root_password OAuth response did not include an access token" "$evidence_file"
  fi
  if ! printf 'header = "Authorization: Bearer %s"\n' "$access_token" > "$auth_config"; then
    unset access_token
    write_gitlab_converge_evidence "$evidence_file" "$old_status" "$put_status" "$new_status" "$old_grant_stderr" "$put_stderr" "$new_grant_stderr"
    fail_after_sops_overwrite "could not write 0600 curl auth config for GitLab converge PUT" "$evidence_file"
  fi
  unset access_token

  prev_umask="$(umask)"
  umask 077
  set +e
  put_status="$(curl -sk -X PUT "${GITLAB_URL}/api/v4/users/1" \
    --config "$auth_config" \
    --data-urlencode "password@${NEW_PASSWORD_FILE}" \
    -o "$put_response" \
    -w '%{http_code}' \
    2>"$put_stderr")"
  put_curl_rc=$?
  set -e
  umask "$prev_umask"

  if [[ "$put_curl_rc" -ne 0 || ! "$put_status" =~ ^2[0-9][0-9]$ ]]; then
    write_gitlab_converge_evidence "$evidence_file" "$old_status" "$put_status" "$new_status" "$old_grant_stderr" "$put_stderr" "$new_grant_stderr"
    fail_after_sops_overwrite "GitLab root password converge PUT failed (curl rc=${put_curl_rc}, HTTP ${put_status})" "$evidence_file"
  fi

  prev_umask="$(umask)"
  umask 077
  set +e
  new_status="$(gitlab_grant_status "$NEW_PASSWORD_FILE" "$new_grant_stderr")"
  new_curl_rc=$?
  set -e
  umask "$prev_umask"
  write_gitlab_converge_evidence "$evidence_file" "$old_status" "$put_status" "$new_status" "$old_grant_stderr" "$put_stderr" "$new_grant_stderr"

  if [[ "$new_curl_rc" -ne 0 || "$new_status" != "200" ]]; then
    prev_umask="$(umask)"
    umask 077
    set +e
    old_after_put_status="$(gitlab_grant_status "$OLD_PASSWORD_ESCROW" "$old_after_put_stderr")"
    old_after_put_curl_rc=$?
    set -e
    umask "$prev_umask"
    write_gitlab_converge_evidence "$evidence_file" "$old_status" "$put_status" "$new_status" "$old_grant_stderr" "$put_stderr" "$new_grant_stderr" "$old_after_put_status" "$old_after_put_stderr" "$old_after_put_curl_rc"
    echo "ERROR: new gitlab_root_password OAuth grant failed immediately after converge PUT (curl rc=${new_curl_rc}, HTTP ${new_status})" >&2
    echo "See converge evidence: ${evidence_file}" >&2
    if [[ "$old_after_put_curl_rc" -eq 0 && "$old_after_put_status" == "200" ]]; then
      echo "Recovery: GitLab database still accepts the escrowed OLD password after the 2xx PUT; SOPS contains NEW." >&2
      print_sops_revert_instruction
    else
      echo "Recovery: GitLab database state is indeterminate after a 2xx password PUT: NEW grant HTTP ${new_status} (curl rc=${new_curl_rc}); OLD post-PUT probe HTTP ${old_after_put_status} (curl rc=${old_after_put_curl_rc})." >&2
      echo "Recovery: do not run a one-sided SOPS rollback unless DB==OLD is proven; keep SOPS, escrow, and evidence intact while diagnosing GitLab." >&2
    fi
    exit 1
  fi

  echo "  GitLab database accepted the new password; converge evidence: ${evidence_file} (0600)."
}

resolve_operative_key

echo "=== Step 1: Fresh pre-rotation backup pin ==="
"${SCRIPT_DIR}/backup-now.sh" --pin-out "$PRE_PIN"
PRE_VOLID="$(verify_pin_file "$PRE_PIN" "$GITLAB_VMID")"
echo "  GitLab pre-rotation pin verified: ${PRE_VOLID}"

echo "=== Step 2: Escrow old password before overwrite ==="
SOPS_AGE_KEY_FILE="$OPERATIVE_KEY" sops -d --extract '["gitlab_root_password"]' "$SECRETS_FILE" > "$OLD_PASSWORD_ESCROW"
chmod 0400 "$OLD_PASSWORD_ESCROW"
OLD_HASH="$(hash_file "$OLD_PASSWORD_ESCROW")"
{
  printf 'name=gitlab_root_password\n'
  printf 'path=%s\n' "$OLD_PASSWORD_ESCROW"
  printf 'sha256=%s\n' "$OLD_HASH"
} > "${OLD_PASSWORD_ESCROW}.record"
chmod 0400 "${OLD_PASSWORD_ESCROW}.record"
OLD_PRE_STDERR="${ESCROW_DIR}/gitlab-old-precheck.stderr"
OLD_PRE_STATUS="$(gitlab_grant_status "$OLD_PASSWORD_ESCROW" "$OLD_PRE_STDERR")"
if [[ "$OLD_PRE_STATUS" != "200" ]]; then
  echo "ERROR: pre-state gitlab_root_password OAuth grant failed with HTTP ${OLD_PRE_STATUS}" >&2
  exit 1
fi
echo "  Old password escrow path and hash recorded"

echo "=== Step 3: Generate new password ==="
if [[ -s "$NEW_PASSWORD_FILE" ]]; then
  echo "  Reusing existing new password path: ${NEW_PASSWORD_FILE}"
else
  # 32 random bytes as hex gives 256 bits using only [0-9a-f], safe for the repo's existing raw form-body OAuth callers.
  openssl rand -hex 32 | tr -d '\r\n' > "$NEW_PASSWORD_FILE"
  chmod 0400 "$NEW_PASSWORD_FILE"
  echo "  New password written to path: ${NEW_PASSWORD_FILE}"
fi

echo "=== Step 4: SOPS overwrite ==="
echo "APPROVAL: --i-mean-it accepted for write-once SOPS breach gitlab_root_password; old value escrowed and pre-pin verified."
sops_set_password_from_file "$NEW_PASSWORD_FILE"

echo "=== Step 5: Converge GitLab database password ==="
gitlab_converge_root_password

echo "=== Step 6: OAuth probes ==="
NEW_STDERR="${EVIDENCE_DIR}/rotate-gitlab-new-grant.stderr"
NEW_STATUS="$(gitlab_grant_status "$NEW_PASSWORD_FILE" "$NEW_STDERR")"
if [[ "$NEW_STATUS" != "200" ]]; then
  echo "ERROR: new gitlab_root_password OAuth grant failed with HTTP ${NEW_STATUS}" >&2
  exit 1
fi
OLD_STDERR="${EVIDENCE_DIR}/rotate-gitlab-old-prove-negative.stderr"
make_converge_temp_file gitlab-old-prove-negative-body OLD_BODY
set +e
OLD_STATUS="$(gitlab_grant_status "$OLD_PASSWORD_ESCROW" "$OLD_STDERR" "$OLD_BODY")"
OLD_CURL_RC=$?
set -e
OLD_BODY_JSON="empty"
OLD_ERROR_FIELD=""
OLD_ACCESS_TOKEN_PRESENT="unknown"
OLD_PROVE_NEGATIVE_VERDICT="FAIL"
OLD_PROVE_NEGATIVE_REASON=""
if [[ -s "$OLD_BODY" ]]; then
  set +e
  OLD_BODY_JSON="$(jq -s -r 'if length == 0 then "empty" elif length == 1 then "valid" else "multi-document" end' "$OLD_BODY")"
  OLD_BODY_JQ_RC=$?
  set -e
  if [[ "$OLD_BODY_JQ_RC" -eq 0 && -n "$OLD_BODY_JSON" ]]; then
    if [[ "$OLD_BODY_JSON" == "valid" ]]; then
      OLD_ERROR_FIELD="$(
        jq -s -r '.[0] | if type == "object" then (.error // "") else "" end | if type == "string" then (if test("^[A-Za-z0-9._:@+=,/-]+$") then . else @json end) else @json end' "$OLD_BODY"
      )"
      OLD_ACCESS_TOKEN_PRESENT="$(
        jq -s -r '.[0] | if ([.. | objects | select(has("access_token")) | .access_token | select(. != null and . != "")] | length) > 0 then "true" else "false" end' "$OLD_BODY"
      )"
    else
      OLD_ACCESS_TOKEN_PRESENT="$(
        jq -s -r 'if ([.. | objects | select(has("access_token")) | .access_token | select(. != null and . != "")] | length) > 0 then "true" else "false" end' "$OLD_BODY"
      )"
    fi
  else
    OLD_BODY_JSON="unparseable"
  fi
fi
if [[ "$OLD_STATUS" =~ ^2[0-9][0-9]$ || "$OLD_ACCESS_TOKEN_PRESENT" == "true" ]]; then
  OLD_PROVE_NEGATIVE_REASON="old gitlab_root_password STILL GRANTS (HTTP ${OLD_STATUS})"
elif [[ "$OLD_CURL_RC" -ne 0 ]]; then
  OLD_PROVE_NEGATIVE_REASON="old gitlab_root_password prove-negative indeterminate (curl rc=${OLD_CURL_RC}, HTTP ${OLD_STATUS})"
elif [[ "$OLD_BODY_JSON" != "valid" ]]; then
  OLD_PROVE_NEGATIVE_REASON="old gitlab_root_password prove-negative indeterminate (${OLD_BODY_JSON} response body, HTTP ${OLD_STATUS})"
elif [[ "$OLD_STATUS" =~ ^5[0-9][0-9]$ ]]; then
  OLD_PROVE_NEGATIVE_REASON="old gitlab_root_password prove-negative indeterminate (HTTP ${OLD_STATUS})"
elif [[ "$OLD_STATUS" != "400" && "$OLD_STATUS" != "401" ]]; then
  OLD_PROVE_NEGATIVE_REASON="old gitlab_root_password prove-negative returned unexpected HTTP ${OLD_STATUS}"
elif [[ "$OLD_ERROR_FIELD" != "invalid_grant" ]]; then
  OLD_PROVE_NEGATIVE_REASON="old gitlab_root_password prove-negative returned unexpected OAuth error '${OLD_ERROR_FIELD}'"
else
  OLD_PROVE_NEGATIVE_VERDICT="PASS"
fi
EVIDENCE_FILE="${EVIDENCE_DIR}/rotate-gitlab-prove-negative.txt"
write_gitlab_prove_negative_evidence \
  "$EVIDENCE_FILE" \
  "$OLD_PASSWORD_ESCROW" \
  "$OLD_HASH" \
  "$OLD_STATUS" \
  "$OLD_CURL_RC" \
  "$OLD_BODY_JSON" \
  "$OLD_ERROR_FIELD" \
  "$OLD_ACCESS_TOKEN_PRESENT" \
  "$OLD_PROVE_NEGATIVE_VERDICT" \
  "$OLD_STDERR"
if [[ "$OLD_PROVE_NEGATIVE_VERDICT" != "PASS" ]]; then
  echo "ERROR: ${OLD_PROVE_NEGATIVE_REASON}; see ${EVIDENCE_FILE}" >&2
  exit 1
fi
echo "  Prove-negative evidence: ${EVIDENCE_FILE}"

echo "=== Step 7: Fresh post-rotation backup pin ==="
"${SCRIPT_DIR}/backup-now.sh" --pin-out "$POST_PIN"
POST_VOLID="$(verify_pin_file "$POST_PIN" "$GITLAB_VMID")"
echo "  GitLab post-rotation pin verified: ${POST_VOLID}"

echo "=== GitLab root password rotation complete ==="
