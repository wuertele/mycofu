#!/usr/bin/env bash
# certbot-renewability.sh -- side-effect-free certbot lineage predicate.

set -euo pipefail

CERTBOT_BIN="${CERTBOT_BIN:-certbot}"
CERTBOT_CONFIG_DIR="${CERTBOT_CONFIG_DIR:-/etc/letsencrypt}"
CERTBOT_WORK_DIR="${CERTBOT_WORK_DIR:-/var/lib/letsencrypt}"
CERTBOT_LOGS_DIR="${CERTBOT_LOGS_DIR:-/var/log/letsencrypt}"

emit_field() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "$key" "$value"
}

bool_for_near_expiry() {
  local days_remaining="$1"
  if [[ "$days_remaining" =~ ^-?[0-9]+$ && "$days_remaining" -lt 14 ]]; then
    printf 'true\n'
  else
    printf 'false\n'
  fi
}

certbot_certificates_output() {
  set +e
  "${CERTBOT_BIN}" certificates \
    --config-dir "${CERTBOT_CONFIG_DIR}" \
    --work-dir "${CERTBOT_WORK_DIR}" \
    --logs-dir "${CERTBOT_LOGS_DIR}" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

extract_cert_block() {
  local cert_name="$1"
  awk -v cert_name="$cert_name" '
    /^  Certificate Name:[[:space:]]*/ {
      in_block = ($0 == "  Certificate Name: " cert_name)
    }
    in_block { print }
    in_block && /^$/ { exit }
  '
}

extract_days_remaining() {
  local expiry_line="$1"
  local days=""

  days="$(sed -nE 's/.*\((VALID|INVALID):[[:space:]]*(-?[0-9]+)[[:space:]]+days?\).*/\2/p' <<< "$expiry_line" | head -1)"
  if [[ -n "$days" ]]; then
    printf '%s\n' "$days"
    return 0
  fi

  if grep -Eiq '\(VALID:[[:space:]]*less than 1 day\)' <<< "$expiry_line"; then
    printf '0\n'
    return 0
  fi

  return 1
}

output_mentions_cert() {
  local cert_name="$1"
  grep -Fq "$cert_name"
}

certbot_renewability_probe() {
  local cert_name="${1:-}"
  local output=""
  local certbot_rc=0
  local block=""
  local expiry_line=""
  local days_remaining=""
  local near_expiry=""

  if [[ -z "$cert_name" ]]; then
    emit_field "reason" "missing-cert-name"
    return 3
  fi

  set +e
  output="$(certbot_certificates_output)"
  certbot_rc=$?
  set -e
  if [[ "$certbot_rc" -ne 0 ]]; then
    emit_field "reason" "certbot-command-failed"
    emit_field "certbot_exit" "$certbot_rc"
    return 3
  fi

  block="$(printf '%s\n' "$output" | extract_cert_block "$cert_name")"
  if [[ -n "$block" ]]; then
    expiry_line="$(grep -E '^[[:space:]]*Expiry Date:' <<< "$block" | head -1 || true)"
    if [[ -z "$expiry_line" ]]; then
      emit_field "reason" "expiry-unparseable"
      return 3
    fi
    if ! days_remaining="$(extract_days_remaining "$expiry_line")"; then
      emit_field "reason" "expiry-unparseable"
      return 3
    fi
    near_expiry="$(bool_for_near_expiry "$days_remaining")"
    emit_field "days_remaining" "$days_remaining"
    emit_field "near_expiry" "$near_expiry"
    return 0
  fi

  if printf '%s\n' "$output" | output_mentions_cert "$cert_name"; then
    if grep -Eiq 'skipp?ing|renewal configuration.*(invalid|broken)|parsefail|fullchain' <<< "$output"; then
      emit_field "reason" "cert-skipped"
      return 1
    fi
    if grep -Eiq 'errored|error processing|error while' <<< "$output"; then
      emit_field "reason" "cert-errored"
      return 1
    fi
  fi

  if grep -Eiq 'No certs found|No certificates found' <<< "$output"; then
    emit_field "reason" "cert-not-found"
    return 3
  fi

  emit_field "reason" "unrecognized-state"
  return 3
}

usage() {
  cat <<'EOF'
Usage:
  certbot-renewability.sh --cert-name NAME
  certbot-renewability.sh NAME

Exit codes:
  0  renewable
  1  unrenewable lineage
  3  unknowable
EOF
}

certbot_renewability_main() {
  local cert_name=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cert-name)
        cert_name="$2"
        shift 2
        ;;
      --config-dir)
        CERTBOT_CONFIG_DIR="$2"
        shift 2
        ;;
      --work-dir)
        CERTBOT_WORK_DIR="$2"
        shift 2
        ;;
      --logs-dir)
        CERTBOT_LOGS_DIR="$2"
        shift 2
        ;;
      --certbot-bin)
        CERTBOT_BIN="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        if [[ -z "$cert_name" ]]; then
          cert_name="$1"
          shift
        else
          echo "ERROR: unexpected argument: $1" >&2
          usage >&2
          exit 2
        fi
        ;;
    esac
  done

  certbot_renewability_probe "$cert_name"
}

if [[ "${CERTBOT_RENEWABILITY_SOURCED_ONLY:-0}" != "1" ]]; then
  certbot_renewability_main "$@"
fi
