#!/usr/bin/env bash
# configure-influxdb-tokens.sh - reconcile site-declared InfluxDB client tokens.
#
# Token definitions live in site/apps/influxdb/tokens.json. This script creates
# or verifies the corresponding InfluxDB authorizations, then stores generated
# token values in SOPS for operator delivery to the consuming application.
# It is intentionally operator-run; it is not part of OpenTofu/CIDATA.

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  framework/scripts/configure-influxdb-tokens.sh <prod|dev> [--token NAME] [--rotate]

Options:
  --token NAME  Reconcile only the named token definition. By default all
                configured tokens are reconciled.
  --rotate      Replace existing matching authorization(s) and SOPS value(s).
  --help        Show this help.

Environment overrides for tests/operators:
  MYCOFU_INFLUXDB_TOKENS_JSON     Token config file (default: site/apps/influxdb/tokens.json)
  MYCOFU_INFLUXDB_BASE_URL        InfluxDB base URL (default: https://<env-ip>:8086)
  MYCOFU_INFLUXDB_INSECURE        Pass -k to curl when 1 (default: 1)
  MYCOFU_INFLUXDB_WAIT_TIMEOUT    Seconds to wait for /health (default: 300)
  MYCOFU_INFLUXDB_AUTH_PAGE_LIMIT Authorization page size (default: 100)
  MYCOFU_INFLUXDB_AUTH_MAX_COUNT  Authorization listing guardrail (default: 1000)
EOF
}

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "${dir}/flake.nix" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  die "Could not find repo root (no flake.nix found)."
}

[[ $# -ge 1 ]] || { usage >&2; exit 2; }
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

ENVIRONMENT="$1"
shift
case "$ENVIRONMENT" in
  prod|dev) ;;
  *) die "environment must be 'prod' or 'dev'" ;;
esac

ROTATE=0
SELECTED_TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rotate)
      ROTATE=1
      shift
      ;;
    --token)
      [[ $# -ge 2 ]] || die "--token requires a value"
      SELECTED_TOKEN="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

REPO_DIR="$(find_repo_root)"
APPS_CONFIG="${MYCOFU_APPS_CONFIG:-${REPO_DIR}/site/applications.yaml}"
SETUP_JSON="${MYCOFU_INFLUXDB_SETUP_JSON:-${REPO_DIR}/site/apps/influxdb/setup.json}"
TOKENS_JSON="${MYCOFU_INFLUXDB_TOKENS_JSON:-${REPO_DIR}/site/apps/influxdb/tokens.json}"
SECRETS_FILE="${MYCOFU_SECRETS_FILE:-${REPO_DIR}/site/sops/secrets.yaml}"

for tool in curl jq sops yq; do
  command -v "$tool" >/dev/null 2>&1 || die "Required tool not found: ${tool}"
done

[[ -f "$APPS_CONFIG" ]] || die "applications config not found: $APPS_CONFIG"
[[ -f "$SETUP_JSON" ]] || die "InfluxDB setup.json not found: $SETUP_JSON"
[[ -f "$TOKENS_JSON" ]] || die "InfluxDB tokens config not found: $TOKENS_JSON"
[[ -f "$SECRETS_FILE" ]] || die "SOPS secrets file not found: $SECRETS_FILE"

validate_tokens_json() {
  local duplicate_names duplicate_descriptions

  jq -e --arg env "$ENVIRONMENT" '
    type == "array"
    and all(.[]; (
      type == "object"
      and (.name | type == "string" and length > 0)
      and (.bucket | type == "string" and length > 0)
      and (.permissions | type == "array" and length > 0)
      and (all(.permissions[]; . == "read" or . == "write"))
      and ((.permissions | unique | length) == (.permissions | length))
      and (.description | type == "object")
      and (.description[$env] | type == "string" and length > 0)
      and (.sops_key | type == "object")
      and (.sops_key[$env] | type == "string" and length > 0)
    ))
  ' "$TOKENS_JSON" >/dev/null \
    || die "InfluxDB tokens config must be an array of token objects with name, bucket, permissions, description.${ENVIRONMENT}, and sops_key.${ENVIRONMENT}"

  duplicate_names="$(jq -r '
    [.[].name] | group_by(.)[] | select(length > 1) | .[0]
  ' "$TOKENS_JSON" | paste -sd ', ' -)"
  [[ -z "$duplicate_names" ]] || die "duplicate InfluxDB token name(s): ${duplicate_names}"

  duplicate_descriptions="$(jq -r --arg env "$ENVIRONMENT" '
    [.[].description[$env]] | group_by(.)[] | select(length > 1) | .[0]
  ' "$TOKENS_JSON" | paste -sd ', ' -)"
  [[ -z "$duplicate_descriptions" ]] \
    || die "duplicate InfluxDB authorization description(s) for ${ENVIRONMENT}: ${duplicate_descriptions}"
}

validate_tokens_json

TOKEN_DEFS=()
if [[ -n "$SELECTED_TOKEN" ]]; then
  while IFS= read -r token_def; do
    TOKEN_DEFS+=( "$token_def" )
  done < <(jq -c --arg name "$SELECTED_TOKEN" '.[] | select(.name == $name)' "$TOKENS_JSON")
  (( ${#TOKEN_DEFS[@]} > 0 )) || die "InfluxDB token '${SELECTED_TOKEN}' not found in ${TOKENS_JSON}"
else
  while IFS= read -r token_def; do
    TOKEN_DEFS+=( "$token_def" )
  done < <(jq -c '.[]' "$TOKENS_JSON")
fi

if (( ${#TOKEN_DEFS[@]} == 0 )); then
  log "No InfluxDB tokens declared in ${TOKENS_JSON}; nothing to do"
  exit 0
fi

INFLUX_ORG="$(jq -r '.org // empty' "$SETUP_JSON")"
[[ -n "$INFLUX_ORG" ]] || die "org not found in $SETUP_JSON"

INFLUX_IP="$(yq -r ".applications.influxdb.environments.${ENVIRONMENT}.ip // \"\"" "$APPS_CONFIG")"
[[ -n "$INFLUX_IP" && "$INFLUX_IP" != "null" ]] || die "influxdb ${ENVIRONMENT} IP not found in $APPS_CONFIG"

INFLUX_URL="${MYCOFU_INFLUXDB_BASE_URL:-https://${INFLUX_IP}:8086}"
INFLUX_INSECURE="${MYCOFU_INFLUXDB_INSECURE:-1}"
WAIT_TIMEOUT="${MYCOFU_INFLUXDB_WAIT_TIMEOUT:-300}"
AUTH_PAGE_LIMIT="${MYCOFU_INFLUXDB_AUTH_PAGE_LIMIT:-100}"
AUTH_MAX_COUNT="${MYCOFU_INFLUXDB_AUTH_MAX_COUNT:-1000}"

curl_args=( -sS )
if [[ "$INFLUX_INSECURE" == "1" ]]; then
  curl_args+=( -k )
fi

SECRETS_JSON="$(sops -d --output-type json "$SECRETS_FILE" 2>/dev/null)" \
  || die "failed to decrypt SOPS secrets file: $SECRETS_FILE"

sops_get_optional_secret() {
  local key="$1" value
  value="$(printf '%s' "$SECRETS_JSON" | jq -r --arg key "$key" '.[$key] // empty')"
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  [[ "$value" == "null" ]] && value=""
  printf '%s' "$value"
}

sops_get_required_secret() {
  local key="$1" value
  value="$(sops_get_optional_secret "$key")"
  [[ -n "$value" && "$value" != "null" ]] || die "SOPS secret '${key}' is missing or empty in $SECRETS_FILE"
  printf '%s' "$value"
}

sops_set_secret() {
  local key="$1" value="$2" encoded
  encoded="$(jq -Rn --arg value "$value" '$value')"
  sops --set "[\"${key}\"] ${encoded}" "$SECRETS_FILE" >/dev/null
}

sops_unset_secret() {
  local key="$1"
  sops unset --idempotent "$SECRETS_FILE" "[\"${key}\"]" >/dev/null
}

INFLUX_ADMIN_TOKEN="$(sops_get_required_secret "influxdb_admin_token")"
INFLUX_AUTH=""  # set after /health succeeds

api_call() {
  local method="$1" url="$2"; shift 2
  local tmpfile status body auth_args=()
  [[ -n "$INFLUX_AUTH" ]] && auth_args=( -H "Authorization: Token ${INFLUX_AUTH}" )
  tmpfile="$(mktemp)"
  status="$(curl "${curl_args[@]}" \
    -o "$tmpfile" -w '%{http_code}' \
    "${auth_args[@]}" \
    -X "$method" "$@" \
    "$url" || true)"
  body="$(cat "$tmpfile")"
  rm -f "$tmpfile"
  if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
    printf '%s' "$body"
    return 0
  fi
  printf 'API error: %s %s -> HTTP %s\n' "$method" "$url" "${status:-?}" >&2
  printf 'response body: %s\n' "$body" >&2
  return 1
}

wait_for_influxdb() {
  local elapsed=0
  log "Waiting for InfluxDB at ${INFLUX_URL} (timeout ${WAIT_TIMEOUT}s)..."
  while (( elapsed < WAIT_TIMEOUT )); do
    if curl "${curl_args[@]}" "${INFLUX_URL}/health" 2>/dev/null \
        | jq -e '.status == "pass"' >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
    elapsed=$(( elapsed + 2 ))
  done
  die "InfluxDB /health did not report pass within ${WAIT_TIMEOUT}s"
}

expected_permissions_json() {
  local org_id="$1" bucket_id="$2" permissions_json="$3"
  jq -nc \
    --arg orgID "$org_id" \
    --arg bucketID "$bucket_id" \
    --argjson actions "$permissions_json" '
      $actions
      | map({
          action: .,
          resource: {type: "buckets", id: $bucketID, orgID: $orgID}
        })
      | sort_by(.action, .resource.type, .resource.id, .resource.orgID)
    '
}

auth_permissions_json() {
  local auths_json="$1" auth_id="$2"
  printf '%s' "$auths_json" | jq -c --arg id "$auth_id" '
    [
      .authorizations[]
      | select(.id == $id)
      | .permissions[]?
      | {
          action: .action,
          resource: {
            type: (.resource.type // ""),
            id: (.resource.id // ""),
            orgID: (.resource.orgID // "")
          }
        }
    ]
    | sort_by(.action, .resource.type, .resource.id, .resource.orgID)
  '
}

permissions_match() {
  local auths_json="$1" auth_id="$2" expected="$3" actual
  actual="$(auth_permissions_json "$auths_json" "$auth_id")"
  [[ "$actual" == "$expected" ]]
}

auth_status_for_id() {
  local auths_json="$1" auth_id="$2"
  printf '%s' "$auths_json" | jq -r --arg id "$auth_id" '
    [.authorizations[] | select(.id == $id) | (.status // "active")][0] // "missing"
  '
}

auth_token_for_id() {
  local auths_json="$1" auth_id="$2"
  printf '%s' "$auths_json" | jq -r --arg id "$auth_id" '
    [.authorizations[] | select(.id == $id) | (.token // "")][0] // ""
  '
}

auth_is_active() {
  local auths_json="$1" auth_id="$2" status
  status="$(auth_status_for_id "$auths_json" "$auth_id")"
  [[ "$status" == "active" ]]
}

count_lines() {
  sed '/^$/d' | wc -l | tr -d ' '
}

delete_auth_ids() {
  local auth_id failed=0
  while IFS= read -r auth_id; do
    [[ -n "$auth_id" ]] || continue
    log "Deleting existing InfluxDB auth ${auth_id} (${TOKEN_DESCRIPTION})"
    if ! api_call DELETE "${INFLUX_URL}/api/v2/authorizations/${auth_id}" >/dev/null; then
      failed=1
    fi
  done
  return "$failed"
}

list_authorizations_json() {
  local org_id="$1" offset=0 collected='[]' page count

  if ! [[ "$AUTH_PAGE_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
    die "MYCOFU_INFLUXDB_AUTH_PAGE_LIMIT must be a positive integer"
  fi
  if ! [[ "$AUTH_MAX_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    die "MYCOFU_INFLUXDB_AUTH_MAX_COUNT must be a positive integer"
  fi

  while true; do
    if (( offset >= AUTH_MAX_COUNT )); then
      die "authorization listing exceeded ${AUTH_MAX_COUNT} entries; increase MYCOFU_INFLUXDB_AUTH_MAX_COUNT or investigate duplicate auths"
    fi

    page="$(api_call GET "${INFLUX_URL}/api/v2/authorizations" \
      --data-urlencode "orgID=${org_id}" \
      --data-urlencode "limit=${AUTH_PAGE_LIMIT}" \
      --data-urlencode "offset=${offset}" -G)"
    count="$(printf '%s' "$page" | jq '(.authorizations // []) | length')"
    collected="$(jq -nc \
      --argjson collected "$collected" \
      --argjson page "$page" \
      '$collected + ($page.authorizations // [])')"

    if (( count < AUTH_PAGE_LIMIT )); then
      break
    fi
    offset=$(( offset + AUTH_PAGE_LIMIT ))
  done

  jq -nc --argjson authorizations "$collected" '{authorizations: $authorizations}'
}

TOKEN_NAME=""
TOKEN_DESCRIPTION=""
SOPS_TOKEN_KEY=""
CREATED_AUTH_ID=""

create_token() {
  local org_id="$1" expected_permissions="$2" payload response token new_auth_id
  payload="$(jq -nc \
    --arg orgID "$org_id" \
    --arg description "$TOKEN_DESCRIPTION" \
    --argjson permissions "$expected_permissions" \
    '{orgID: $orgID, description: $description, permissions: $permissions}')"

  response="$(api_call POST "${INFLUX_URL}/api/v2/authorizations" \
    -H "Content-Type: application/json" -d "$payload")"
  token="$(printf '%s' "$response" | jq -r '.token // empty')"
  [[ -n "$token" ]] || die "InfluxDB authorization response did not include a token"
  new_auth_id="$(printf '%s' "$response" | jq -r '.id // empty')"
  [[ -n "$new_auth_id" ]] || die "InfluxDB authorization response did not include an id"

  if ! sops_set_secret "$SOPS_TOKEN_KEY" "$token"; then
    log "Failed to store token in SOPS; deleting newly-created auth ${new_auth_id}"
    api_call DELETE "${INFLUX_URL}/api/v2/authorizations/${new_auth_id}" >/dev/null || true
    die "failed to store InfluxDB token '${TOKEN_NAME}' in SOPS key '${SOPS_TOKEN_KEY}'"
  fi
  CREATED_AUTH_ID="$new_auth_id"
  log "Stored InfluxDB token '${TOKEN_NAME}' in SOPS key '${SOPS_TOKEN_KEY}'"
}

reconcile_token() {
  local token_json="$1"
  local target_bucket permissions_json bucket_id expected_permissions sops_token
  local auths_json matching_auth_ids auth_count auth_id auth_token previous_sops_token

  TOKEN_NAME="$(printf '%s' "$token_json" | jq -r '.name')"
  target_bucket="$(printf '%s' "$token_json" | jq -r '.bucket')"
  permissions_json="$(printf '%s' "$token_json" | jq -c '.permissions')"
  TOKEN_DESCRIPTION="$(printf '%s' "$token_json" | jq -r --arg env "$ENVIRONMENT" '.description[$env]')"
  SOPS_TOKEN_KEY="$(printf '%s' "$token_json" | jq -r --arg env "$ENVIRONMENT" '.sops_key[$env]')"
  CREATED_AUTH_ID=""

  log "Reconciling InfluxDB token '${TOKEN_NAME}' (${TOKEN_DESCRIPTION})"

  bucket_id="$(api_call GET "${INFLUX_URL}/api/v2/buckets" \
    --data-urlencode "orgID=${ORG_ID}" \
    --data-urlencode "name=${target_bucket}" \
    --data-urlencode "limit=100" -G \
    | jq -r --arg name "$target_bucket" '.buckets[]? | select(.name == $name) | .id' \
    | head -n1)"
  [[ -n "$bucket_id" ]] || die "could not resolve bucket '${target_bucket}' in org '${INFLUX_ORG}'"

  expected_permissions="$(expected_permissions_json "$ORG_ID" "$bucket_id" "$permissions_json")"
  sops_token="$(sops_get_optional_secret "$SOPS_TOKEN_KEY")"
  auths_json="$(list_authorizations_json "$ORG_ID")"
  matching_auth_ids="$(printf '%s' "$auths_json" \
    | jq -r --arg desc "$TOKEN_DESCRIPTION" '.authorizations[]? | select(.description == $desc) | .id')"
  auth_count="$(printf '%s\n' "$matching_auth_ids" | count_lines)"

  if (( ROTATE == 0 )); then
    if (( auth_count == 0 )) && [[ -z "$sops_token" ]]; then
      log "Creating InfluxDB token '${TOKEN_NAME}' for bucket '${target_bucket}' in org '${INFLUX_ORG}'"
      create_token "$ORG_ID" "$expected_permissions"
      return 0
    fi

    if (( auth_count == 1 )) && [[ -n "$sops_token" ]]; then
      auth_id="$(printf '%s\n' "$matching_auth_ids" | sed '/^$/d' | head -n1)"
      if ! auth_is_active "$auths_json" "$auth_id"; then
        die "existing auth '${TOKEN_DESCRIPTION}' is not active; rerun with --rotate to replace it"
      fi
      if ! permissions_match "$auths_json" "$auth_id" "$expected_permissions"; then
        die "existing auth '${TOKEN_DESCRIPTION}' permissions do not match requested scope; rerun with --rotate to replace it"
      fi
      auth_token="$(auth_token_for_id "$auths_json" "$auth_id")"
      if [[ -z "$auth_token" ]]; then
        log "InfluxDB auth already present and scoped correctly (${TOKEN_DESCRIPTION}); InfluxDB did not expose a token value for SOPS comparison"
        return 0
      elif [[ "$auth_token" == "$sops_token" ]]; then
        log "InfluxDB token '${TOKEN_NAME}' already present and scoped correctly (${TOKEN_DESCRIPTION})"
        return 0
      fi
      die "SOPS key '${SOPS_TOKEN_KEY}' does not match existing auth '${TOKEN_DESCRIPTION}'; rerun with --rotate to replace it"
    fi

    if (( auth_count > 1 )); then
      die "found ${auth_count} matching auths for '${TOKEN_DESCRIPTION}'; rerun with --rotate to replace them"
    fi
    if (( auth_count == 0 )) && [[ -n "$sops_token" ]]; then
      die "SOPS key '${SOPS_TOKEN_KEY}' exists but InfluxDB auth '${TOKEN_DESCRIPTION}' is missing; rerun with --rotate to create a new token and update the consuming client"
    fi
    if (( auth_count == 1 )) && [[ -z "$sops_token" ]]; then
      auth_id="$(printf '%s\n' "$matching_auth_ids" | sed '/^$/d' | head -n1)"
      if ! auth_is_active "$auths_json" "$auth_id"; then
        die "InfluxDB auth '${TOKEN_DESCRIPTION}' exists but is not active; rerun with --rotate to create a retrievable token"
      fi
      if ! permissions_match "$auths_json" "$auth_id" "$expected_permissions"; then
        die "InfluxDB auth '${TOKEN_DESCRIPTION}' exists but permissions do not match requested scope; rerun with --rotate to replace it"
      fi
      auth_token="$(auth_token_for_id "$auths_json" "$auth_id")"
      [[ -n "$auth_token" ]] || die "InfluxDB auth '${TOKEN_DESCRIPTION}' exists but SOPS key '${SOPS_TOKEN_KEY}' is missing and the token is not retrievable; rerun with --rotate"
      sops_set_secret "$SOPS_TOKEN_KEY" "$auth_token" \
        || die "failed to store existing InfluxDB token '${TOKEN_NAME}' in SOPS key '${SOPS_TOKEN_KEY}'"
      log "Restored existing InfluxDB auth token to SOPS key '${SOPS_TOKEN_KEY}'"
      return 0
    fi
  fi

  log "Creating replacement InfluxDB token '${TOKEN_NAME}' for bucket '${target_bucket}' in org '${INFLUX_ORG}'"
  previous_sops_token="$sops_token"
  create_token "$ORG_ID" "$expected_permissions"

  if (( auth_count > 0 )); then
    if ! printf '%s\n' "$matching_auth_ids" | delete_auth_ids; then
      log "Old auth cleanup failed after creating replacement token; rolling back SOPS state"
      if [[ -n "$previous_sops_token" ]]; then
        sops_set_secret "$SOPS_TOKEN_KEY" "$previous_sops_token" \
          || log "Failed to restore previous SOPS key '${SOPS_TOKEN_KEY}'"
      else
        sops_unset_secret "$SOPS_TOKEN_KEY" \
          || log "Failed to unset SOPS key '${SOPS_TOKEN_KEY}' during rollback"
      fi
      if [[ -n "$CREATED_AUTH_ID" ]]; then
        log "Deleting replacement InfluxDB auth ${CREATED_AUTH_ID} after rollback"
        api_call DELETE "${INFLUX_URL}/api/v2/authorizations/${CREATED_AUTH_ID}" >/dev/null || true
      fi
      die "failed to delete existing InfluxDB auth(s); previous token state was restored where possible"
    fi
  fi
}

wait_for_influxdb
INFLUX_AUTH="$INFLUX_ADMIN_TOKEN"

ORG_ID="$(api_call GET "${INFLUX_URL}/api/v2/orgs" \
  --data-urlencode "org=${INFLUX_ORG}" -G \
  | jq -r '.orgs[0].id // empty')"
[[ -n "$ORG_ID" ]] || die "could not resolve org ID for '${INFLUX_ORG}'"

for token_def in "${TOKEN_DEFS[@]}"; do
  reconcile_token "$token_def"
done
