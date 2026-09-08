#!/usr/bin/env bash
# bucket-reconcile.sh — Idempotent declarative bucket reconciliation for InfluxDB 2.x.
#
# Reads desired buckets from a JSON array file and ensures each one exists
# in InfluxDB with the requested retention. Creates missing buckets, updates
# retention on existing ones. NEVER deletes buckets — removing an entry from
# the file has no effect on InfluxDB.
#
# Setup is a separate concern (handled by influxdb-setup.service on first
# boot). This script runs AFTER setup is complete and only manages buckets.
#
# Designed to be run as a oneshot systemd service every boot, but also
# safe to invoke manually for in-life reconciliation after editing
# buckets.json (operator runs `systemctl start influxdb-reconcile-buckets`).
#
# Environment variables (all optional, defaults shown):
#   INFLUXDB_HOST          https://localhost:8086
#   INFLUXDB_TOKEN_FILE    /run/secrets/influxdb/admin-token
#   INFLUXDB_BUCKETS_FILE  /etc/influxdb2/buckets.json
#   INFLUXDB_SETUP_FILE    /var/lib/influxdb2/setup.json
#   INFLUXDB_INSECURE      1   (pass -k to curl; default for localhost)
#   INFLUXDB_WAIT_TIMEOUT  60  (seconds to wait for InfluxDB /health)
#
# Exit codes:
#   0   success (including: buckets.json absent — nothing to do)
#   1   hard error (missing token, org not found, malformed JSON, API error)

set -euo pipefail

INFLUXDB_HOST="${INFLUXDB_HOST:-https://localhost:8086}"
INFLUXDB_TOKEN_FILE="${INFLUXDB_TOKEN_FILE:-/run/secrets/influxdb/admin-token}"
INFLUXDB_BUCKETS_FILE="${INFLUXDB_BUCKETS_FILE:-/etc/influxdb2/buckets.json}"
INFLUXDB_SETUP_FILE="${INFLUXDB_SETUP_FILE:-/var/lib/influxdb2/setup.json}"
INFLUXDB_INSECURE="${INFLUXDB_INSECURE:-1}"
INFLUXDB_WAIT_TIMEOUT="${INFLUXDB_WAIT_TIMEOUT:-60}"

log() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

curl_args=( -sS )
if [[ "$INFLUXDB_INSECURE" == "1" ]]; then
  curl_args+=( -k )
fi

# api_call <method> <url> [curl-extras...] — emits response body to stdout
# on 2xx. On non-2xx, prints status + body to stderr and exits 1. Use this
# instead of curl directly so a rotated admin token (401) or InfluxDB 5xx
# surfaces with the operation, endpoint, status, and full response body.
INFLUXDB_AUTH=""  # set after token load; api_call may run before then
                  # for /health probing (no auth needed)
api_call() {
  local method="$1" url="$2"; shift 2
  local body status auth_args=()
  [[ -n "$INFLUXDB_AUTH" ]] && auth_args=( -H "Authorization: Token ${INFLUXDB_AUTH}" )
  # -w writes HTTP status to stderr separator; we split on the marker
  local tmpfile
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

# --- Skip if buckets.json is absent ---
if [[ ! -f "$INFLUXDB_BUCKETS_FILE" ]]; then
  log "buckets.json not present at $INFLUXDB_BUCKETS_FILE — skipping bucket reconciliation"
  exit 0
fi

# --- Parse retention string to seconds ---
# "0" or "" → 0 (infinite). Otherwise a non-negative integer optionally
# followed by d/h/s. Anything else (negative, decimal, leading zero,
# whitespace, non-integer-with-suffix like "1.5h") is rejected by the
# regex below before any shell arithmetic runs.
parse_retention_seconds() {
  local r="$1"
  if [[ -z "$r" || "$r" == "0" ]]; then
    printf '0'
    return 0
  fi
  # Strict shape: ^[1-9][0-9]*(d|h|s)?$ — no leading zero (avoids bash
  # octal), no sign, no decimal, no whitespace. Bare digits are seconds.
  if [[ ! "$r" =~ ^[1-9][0-9]*[dhs]?$ ]]; then
    die "Invalid retention string: '$r' (use 0, an integer, or N{d,h,s} with N>=1)"
  fi
  case "$r" in
    *d) printf '%d' $(( ${r%d} * 86400 )) ;;
    *h) printf '%d' $(( ${r%h} * 3600 )) ;;
    *s) printf '%d' "${r%s}" ;;
    *)  printf '%d' "$r" ;;
  esac
}

# --- Validate inputs ---
[[ -f "$INFLUXDB_TOKEN_FILE" ]] || die "admin token file not found: $INFLUXDB_TOKEN_FILE"
[[ -f "$INFLUXDB_SETUP_FILE" ]] || die "setup.json not found: $INFLUXDB_SETUP_FILE"
command -v jq >/dev/null || die "jq is required"
command -v curl >/dev/null || die "curl is required"

ADMIN_TOKEN="$(tr -d '[:space:]' < "$INFLUXDB_TOKEN_FILE")"
[[ -n "$ADMIN_TOKEN" ]] || die "admin token is empty"

ORG="$(jq -r '.org' "$INFLUXDB_SETUP_FILE")"
[[ -n "$ORG" && "$ORG" != "null" ]] || die "org not found in $INFLUXDB_SETUP_FILE"

# Validate buckets.json shape: must be an array of objects with .name
if ! jq -e 'type == "array"' "$INFLUXDB_BUCKETS_FILE" >/dev/null 2>&1; then
  die "$INFLUXDB_BUCKETS_FILE must contain a JSON array"
fi
if ! jq -e 'all(.[]; type == "object" and has("name") and (.name | type) == "string" and .name != "")' \
    "$INFLUXDB_BUCKETS_FILE" >/dev/null 2>&1; then
  die "$INFLUXDB_BUCKETS_FILE entries must be objects with a non-empty 'name' string"
fi

# The list-existing-buckets call uses a single page of limit=100. If the
# operator ever declares more buckets than that, the reconciler would treat
# beyond-page entries as missing and POST duplicates. Fail loudly instead.
desired_count="$(jq 'length' "$INFLUXDB_BUCKETS_FILE")"
if (( desired_count > 100 )); then
  die "$INFLUXDB_BUCKETS_FILE has $desired_count entries; reconciler supports at most 100. Paginate or split."
fi

# Validate every retention value at entry time, before any API call. This
# makes an unrecoverable typo fail immediately, not after waiting for
# /health and resolving the org.
while IFS=$'\t' read -r _name retention_raw; do
  parse_retention_seconds "$retention_raw" >/dev/null
done < <(jq -r '.[] | [.name, (.retention // "0")] | @tsv' "$INFLUXDB_BUCKETS_FILE")

# --- Wait for InfluxDB /health to report pass ---
log "Waiting for InfluxDB at $INFLUXDB_HOST (timeout ${INFLUXDB_WAIT_TIMEOUT}s)..."
elapsed=0
while (( elapsed < INFLUXDB_WAIT_TIMEOUT )); do
  if curl "${curl_args[@]}" "${INFLUXDB_HOST}/health" 2>/dev/null \
      | jq -e '.status == "pass"' >/dev/null 2>&1; then
    break
  fi
  sleep 2
  elapsed=$(( elapsed + 2 ))
done
if (( elapsed >= INFLUXDB_WAIT_TIMEOUT )); then
  die "InfluxDB /health did not report pass within ${INFLUXDB_WAIT_TIMEOUT}s"
fi

# Switch on auth for subsequent api_call invocations.
INFLUXDB_AUTH="$ADMIN_TOKEN"

# --- Resolve org ID ---
org_id="$(api_call GET "${INFLUXDB_HOST}/api/v2/orgs" \
  --data-urlencode "org=${ORG}" -G \
  | jq -r '.orgs[0].id // empty')"
[[ -n "$org_id" ]] || die "could not resolve org ID for '$ORG' (token may be unauthorized; check /run/secrets/influxdb/admin-token)"
log "Reconciling buckets in org '$ORG' (id=$org_id)"

# --- Fetch existing buckets for this org ---
# Single page of limit=100 — the build-time guard above rejects buckets.json
# files with more than 100 entries, so this can list all desired buckets in
# a single request. retentionRules[] is empty when retention is infinite.
existing_json="$(api_call GET "${INFLUXDB_HOST}/api/v2/buckets" \
  --data-urlencode "orgID=${org_id}" --data-urlencode "limit=100" -G)"

bucket_id_for_name() {
  printf '%s' "$existing_json" \
    | jq -r --arg n "$1" '.buckets[] | select(.name == $n) | .id'
}

bucket_retention_seconds() {
  printf '%s' "$existing_json" \
    | jq -r --arg n "$1" '
      .buckets[]
      | select(.name == $n)
      | (.retentionRules[0].everySeconds // 0)'
}

# --- Build POST/PATCH payloads ---
# retentionRules: empty array means infinite; otherwise [{type:expire, everySeconds:N}]
retention_rules_json() {
  local secs="$1"
  if (( secs == 0 )); then
    printf '[]'
  else
    jq -nc --argjson s "$secs" '[{type: "expire", everySeconds: $s}]'
  fi
}

# --- Reconcile loop ---
created=0
updated=0
unchanged=0

# Read each desired bucket. Use a process-substitution to keep counters
# in the parent shell (a pipeline would put `while read` in a subshell).
while IFS=$'\t' read -r name retention_raw; do
  desired_secs="$(parse_retention_seconds "$retention_raw")"
  existing_id="$(bucket_id_for_name "$name")"

  if [[ -z "$existing_id" ]]; then
    # Create
    log "  + creating bucket '$name' (retention ${retention_raw:-0} = ${desired_secs}s)"
    payload="$(jq -nc \
      --arg name "$name" \
      --arg orgID "$org_id" \
      --argjson rules "$(retention_rules_json "$desired_secs")" \
      '{name: $name, orgID: $orgID, retentionRules: $rules}')"
    api_call POST "${INFLUXDB_HOST}/api/v2/buckets" \
      -H "Content-Type: application/json" -d "$payload" >/dev/null
    created=$(( created + 1 ))
    continue
  fi

  current_secs="$(bucket_retention_seconds "$name")"
  if (( current_secs == desired_secs )); then
    log "  = bucket '$name' already at retention ${desired_secs}s"
    unchanged=$(( unchanged + 1 ))
    continue
  fi

  # Update retention
  log "  ~ updating bucket '$name' retention ${current_secs}s -> ${desired_secs}s"
  payload="$(jq -nc \
    --argjson rules "$(retention_rules_json "$desired_secs")" \
    '{retentionRules: $rules}')"
  api_call PATCH "${INFLUXDB_HOST}/api/v2/buckets/${existing_id}" \
    -H "Content-Type: application/json" -d "$payload" >/dev/null
  updated=$(( updated + 1 ))
done < <(jq -r '.[] | [.name, (.retention // "0")] | @tsv' "$INFLUXDB_BUCKETS_FILE")

log "Reconciliation complete: ${created} created, ${updated} updated, ${unchanged} unchanged"
