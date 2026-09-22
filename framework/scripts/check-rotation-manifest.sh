#!/usr/bin/env bash
# check-rotation-manifest.sh — fail-closed admission ratchet for rotation rows.
#
# Reads only cleartext YAML structure: SOPS key names, .sops.yaml creation-rule
# path regexes, and the site rotation manifest. It never decrypts secret values.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ROTATION_MANIFEST_REPO_DIR:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
SOPS_CONFIG="${ROTATION_MANIFEST_SOPS_CONFIG:-${REPO_DIR}/.sops.yaml}"
MANIFEST="${ROTATION_MANIFEST_FILE:-${REPO_DIR}/site/rotation-manifest.yaml}"
APPS_CONFIG="${ROTATION_MANIFEST_APPS_CONFIG:-${REPO_DIR}/site/applications.yaml}"
ENSURE_APP_SECRETS="${ROTATION_MANIFEST_ENSURE_APP_SECRETS:-${REPO_DIR}/framework/scripts/ensure-app-secrets.sh}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rotation-manifest.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

LIVE_KEYS="${TMP_DIR}/live-keys.tsv"
CLASS_ROWS="${TMP_DIR}/class-rows.tsv"
EXCLUDED_ROWS="${TMP_DIR}/excluded-rows.tsv"
EXTERNAL_ROWS="${TMP_DIR}/external-rows.tsv"
ERRORS="${TMP_DIR}/errors.txt"

: > "${LIVE_KEYS}"
: > "${CLASS_ROWS}"
: > "${EXCLUDED_ROWS}"
: > "${EXTERNAL_ROWS}"
: > "${ERRORS}"

fail() {
  printf 'ERROR: %s\n' "$*" >> "${ERRORS}"
}

require_readable() {
  local label="$1" path="$2"
  if [[ ! -r "${path}" ]]; then
    fail "${label} missing or unreadable: ${path}"
    return 1
  fi
  return 0
}

finish() {
  if [[ -s "${ERRORS}" ]]; then
    cat "${ERRORS}" >&2
    exit 1
  fi
  echo "rotation manifest OK"
}

line_count() {
  sed '/^$/d' | wc -l | tr -d ' '
}

row_has() {
  local idx="$1" field="$2"
  yq -e ".[${idx}] | has(\"${field}\")" "${MANIFEST}" >/dev/null 2>&1
}

row_value() {
  local idx="$1" field="$2"
  yq -r ".[${idx}].${field} // \"\"" "${MANIFEST}" 2>/dev/null
}

valid_class() {
  case "$1" in
    M1|M2|M3|M4|M5-automated|MANUAL) return 0 ;;
    *) return 1 ;;
  esac
}

valid_m1_holders() {
  local idx="$1" row_num="$2" match_value="$3"
  local holders_tag holder_count holder_idx name delivery

  if ! holders_tag="$(yq -r ".[${idx}].holders | tag" "${MANIFEST}" 2>&1)"; then
    fail "manifest row ${row_num} (${match_value}) has unreadable holders: ${holders_tag}"
    return 0
  fi
  if [[ "${holders_tag}" != "!!seq" ]]; then
    fail "manifest row ${row_num} (${match_value}) holders must be a sequence"
    return 0
  fi
  if ! holder_count="$(yq -r ".[${idx}].holders | length" "${MANIFEST}" 2>&1)"; then
    fail "manifest row ${row_num} (${match_value}) holders count failed: ${holder_count}"
    return 0
  fi
  if [[ "${holder_count}" -lt 1 ]]; then
    fail "manifest row ${row_num} (${match_value}) holders must not be empty"
    return 0
  fi

  holder_idx=0
  while (( holder_idx < holder_count )); do
    name="$(yq -r ".[${idx}].holders[${holder_idx}].name // \"\"" "${MANIFEST}" 2>/dev/null || true)"
    delivery="$(yq -r ".[${idx}].holders[${holder_idx}].delivery // \"\"" "${MANIFEST}" 2>/dev/null || true)"
    if [[ -z "${name}" || -z "${delivery}" ]]; then
      fail "manifest row ${row_num} (${match_value}) holder $((holder_idx + 1)) must set name and delivery"
    fi
    case "${name}:${delivery}" in
      workstation:local-file|cicd:register-runner) ;;
      *) fail "manifest row ${row_num} (${match_value}) has unsupported holder ${name}:${delivery}" ;;
    esac
    holder_idx=$((holder_idx + 1))
  done
}

pattern_matches() {
  local pattern="$1" identity="$2" key_path="$3"
  # Manifest match values are intentionally shell glob patterns.
  # shellcheck disable=SC2254
  case "${identity}" in
    ${pattern}) return 0 ;;
  esac
  # shellcheck disable=SC2254
  case "${key_path}" in
    ${pattern}) return 0 ;;
  esac
  return 1
}

append_live_key() {
  local identity="$1" key_path="$2" origin="$3"
  if ! awk -F '\t' -v identity="${identity}" '$1 == identity {found=1} END {exit found ? 0 : 1}' "${LIVE_KEYS}"; then
    printf '%s\t%s\t%s\n' "${identity}" "${key_path}" "${origin}" >> "${LIVE_KEYS}"
  fi
}

enumerate_sops_file() {
  local rel_path="$1"
  local abs_path="${REPO_DIR}/${rel_path}"
  local keys_output key tag child_output child

  require_readable "SOPS file" "${abs_path}" || return 0

  if ! keys_output="$(yq -r 'keys | .[]' "${abs_path}" 2>&1)"; then
    fail "failed to enumerate top-level keys in ${rel_path}: ${keys_output}"
    return 0
  fi

  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    [[ "${key}" == "sops" ]] && continue

    if ! tag="$(KEY="${key}" yq -r '.[strenv(KEY)] | tag' "${abs_path}" 2>&1)"; then
      fail "failed to inspect ${rel_path}:${key}: ${tag}"
      continue
    fi

    if [[ "${tag}" == "!!map" ]]; then
      if ! child_output="$(KEY="${key}" yq -r '.[strenv(KEY)] | keys | .[]' "${abs_path}" 2>&1)"; then
        fail "failed to enumerate nested keys in ${rel_path}:${key}: ${child_output}"
        continue
      fi
      if [[ -z "${child_output}" ]]; then
        append_live_key "${rel_path}:${key}" "${key}" "${rel_path}:${key}"
        continue
      fi
      while IFS= read -r child; do
        [[ -n "${child}" ]] || continue
        append_live_key "${rel_path}:${key}.${child}" "${key}.${child}" "${rel_path}:${key}.${child}"
      done <<< "${child_output}"
    else
      append_live_key "${rel_path}:${key}" "${key}" "${rel_path}:${key}"
    fi
  done <<< "${keys_output}"
}

enumerate_sops_files() {
  local regexes regex matched sops_matched rel abs_path all_files

  require_readable ".sops.yaml" "${SOPS_CONFIG}" || return 0
  if ! regexes="$(yq -r '.creation_rules[] | .path_regex // ""' "${SOPS_CONFIG}" 2>&1)"; then
    fail "failed to read .sops.yaml creation_rules: ${regexes}"
    return 0
  fi
  if [[ -z "${regexes}" ]]; then
    fail ".sops.yaml has no creation_rules[].path_regex entries"
    return 0
  fi

  all_files="${TMP_DIR}/tracked-files"
  if ! (cd "${REPO_DIR}" && git ls-files) > "${all_files}" 2>/dev/null; then
    fail "failed to enumerate tracked files via git ls-files in ${REPO_DIR}; is this a git checkout?"
    return 0
  fi

  while IFS= read -r regex; do
    [[ -n "${regex}" ]] || continue
    matched="${TMP_DIR}/matched-files"
    sops_matched="${TMP_DIR}/matched-sops-files"
    : > "${matched}"
    : > "${sops_matched}"

    grep -E "${regex}" "${all_files}" > "${matched}" || true

    while IFS= read -r rel; do
      [[ -n "${rel}" ]] || continue
      abs_path="${REPO_DIR}/${rel}"
      if [[ ! -r "${abs_path}" ]]; then
        fail "SOPS rule candidate missing or unreadable: ${rel}"
        continue
      fi
      if yq -e 'has("sops")' "${abs_path}" >/dev/null 2>&1; then
        printf '%s\n' "${rel}" >> "${sops_matched}"
      fi
    done < "${matched}"

    if [[ ! -s "${matched}" ]]; then
      fail ".sops.yaml creation rule matched no files: ${regex}"
      continue
    fi
    if [[ ! -s "${sops_matched}" ]]; then
      fail ".sops.yaml creation rule matched no files with SOPS metadata: ${regex}"
      continue
    fi

    sort -u "${sops_matched}" | while IFS= read -r rel; do
      enumerate_sops_file "${rel}"
    done
  done <<< "${regexes}"
}

enumerate_ensure_app_secrets() {
  local declarations app key enabled

  [[ -r "${APPS_CONFIG}" && -r "${ENSURE_APP_SECRETS}" ]] || return 0

  declarations="$(
    awk '
      /[.]applications[.][A-Za-z0-9_-]+[.]enabled[[:space:]]*==[[:space:]]*true/ {
        line=$0
        sub(/^.*[.]applications[.]/, "", line)
        sub(/[.]enabled.*$/, "", line)
        app=line
        next
      }
      /^[[:space:]]*fi[[:space:]]*$/ {
        app=""
        next
      }
      app != "" && /ensure_secret[[:space:]]+"/ {
        line=$0
        sub(/^.*ensure_secret[[:space:]]+"/, "", line)
        sub(/".*$/, "", line)
        print app "\t" line
      }
    ' "${ENSURE_APP_SECRETS}"
  )"

  while IFS=$'\t' read -r app key; do
    [[ -n "${app}" && -n "${key}" ]] || continue
    enabled="$(APP="${app}" yq -r '.applications[strenv(APP)].enabled // false' "${APPS_CONFIG}" 2>/dev/null || true)"
    if [[ "${enabled}" == "true" ]]; then
      append_live_key "site/applications.yaml:${app}:${key}" "${key}" "site/applications.yaml:applications.${app}.enabled:${key}"
    fi
  done <<< "${declarations}"
}

load_manifest() {
  local root_tag row_count idx row_num keys_output field
  local has_match has_external has_excluded subject_count
  local match_value external_value excluded_value class_value driver_value probe_value

  require_readable "rotation manifest" "${MANIFEST}" || return 0

  if ! root_tag="$(yq -r 'tag' "${MANIFEST}" 2>&1)"; then
    fail "failed to parse rotation manifest ${MANIFEST}: ${root_tag}"
    return 0
  fi
  if [[ "${root_tag}" != "!!seq" ]]; then
    fail "rotation manifest must be a top-level YAML sequence: ${MANIFEST}"
    return 0
  fi
  if ! row_count="$(yq -r 'length' "${MANIFEST}" 2>&1)"; then
    fail "failed to count rotation manifest rows: ${row_count}"
    return 0
  fi
  if ! [[ "${row_count}" =~ ^[0-9]+$ ]]; then
    fail "rotation manifest row count is not numeric: ${row_count}"
    return 0
  fi

  idx=0
  while (( idx < row_count )); do
    row_num=$((idx + 1))
    if ! keys_output="$(yq -r ".[${idx}] | keys | .[]" "${MANIFEST}" 2>&1)"; then
      fail "manifest row ${row_num} is not a mapping"
      idx=$((idx + 1))
      continue
    fi
    while IFS= read -r field; do
      [[ -n "${field}" ]] || continue
      case "${field}" in
        match|class|driver|probe|external|excluded|holders) ;;
        *) fail "manifest row ${row_num} uses unsupported field '${field}' (allowed: match, class, driver, probe, external, excluded, holders)" ;;
      esac
    done <<< "${keys_output}"

    has_match=0
    has_external=0
    has_excluded=0
    row_has "${idx}" match && has_match=1
    row_has "${idx}" external && has_external=1
    row_has "${idx}" excluded && has_excluded=1
    subject_count=$((has_match + has_external + has_excluded))
    if [[ "${subject_count}" -ne 1 ]]; then
      fail "manifest row ${row_num} must set exactly one of match, external, or excluded"
      idx=$((idx + 1))
      continue
    fi

    match_value="$(row_value "${idx}" match)"
    external_value="$(row_value "${idx}" external)"
    excluded_value="$(row_value "${idx}" excluded)"
    class_value="$(row_value "${idx}" class)"
    driver_value="$(row_value "${idx}" driver)"
    probe_value="$(row_value "${idx}" probe)"

    if [[ "${has_match}" -eq 1 ]]; then
      [[ -n "${match_value}" ]] || fail "manifest row ${row_num} has empty match"
      if ! valid_class "${class_value}"; then
        fail "manifest row ${row_num} (${match_value}) has invalid class '${class_value}'"
      fi
      [[ -n "${driver_value}" ]] || fail "manifest row ${row_num} (${match_value}) missing driver"
      [[ -n "${probe_value}" ]] || fail "manifest row ${row_num} (${match_value}) missing probe"
      if row_has "${idx}" holders; then
        if [[ "${match_value}" == "sops_age_key" && "${class_value}" == "M1" ]]; then
          valid_m1_holders "${idx}" "${row_num}" "${match_value}"
        else
          fail "manifest row ${row_num} (${match_value}) holders are only supported on the M1 sops_age_key row"
        fi
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "${row_num}" "${match_value}" "${class_value}" "${driver_value}" "${probe_value}" >> "${CLASS_ROWS}"
    elif [[ "${has_external}" -eq 1 ]]; then
      [[ -n "${external_value}" ]] || fail "manifest row ${row_num} has empty external"
      if [[ -n "${class_value}" ]] && ! valid_class "${class_value}"; then
        fail "manifest row ${row_num} (${external_value}) has invalid class '${class_value}'"
      fi
      [[ -n "${driver_value}" ]] || fail "manifest row ${row_num} (${external_value}) missing driver"
      [[ -n "${probe_value}" ]] || fail "manifest row ${row_num} (${external_value}) missing probe"
      printf '%s\t%s\t%s\t%s\t%s\n' "${row_num}" "${external_value}" "${class_value}" "${driver_value}" "${probe_value}" >> "${EXTERNAL_ROWS}"
    else
      [[ -n "${excluded_value}" ]] || fail "manifest row ${row_num} has empty excluded"
      if [[ -n "${class_value}${driver_value}${probe_value}" ]]; then
        fail "manifest row ${row_num} (${excluded_value}) is excluded and must not set class, driver, or probe"
      fi
      printf '%s\t%s\n' "${row_num}" "${excluded_value}" >> "${EXCLUDED_ROWS}"
    fi

    idx=$((idx + 1))
  done
}

matching_rows() {
  local rows_file="$1" identity="$2" key_path="$3"
  local row pattern _rest
  while IFS=$'\t' read -r row pattern _rest; do
    [[ -n "${row}" && -n "${pattern}" ]] || continue
    if pattern_matches "${pattern}" "${identity}" "${key_path}"; then
      printf 'row %s (%s)\n' "${row}" "${pattern}"
    fi
  done < "${rows_file}"
}

check_live_key_coverage() {
  local identity key_path origin class_matches excluded_matches
  local class_count excluded_count

  while IFS=$'\t' read -r identity key_path origin; do
    [[ -n "${identity}" ]] || continue
    class_matches="$(matching_rows "${CLASS_ROWS}" "${identity}" "${key_path}")"
    excluded_matches="$(matching_rows "${EXCLUDED_ROWS}" "${identity}" "${key_path}")"
    class_count="$(printf '%s\n' "${class_matches}" | line_count)"
    excluded_count="$(printf '%s\n' "${excluded_matches}" | line_count)"

    if (( excluded_count > 1 )); then
      fail "${origin} matches multiple excluded rows: $(printf '%s' "${excluded_matches}" | paste -sd '; ' -)"
      continue
    fi
    if (( excluded_count == 1 && class_count > 0 )); then
      fail "${origin} is both excluded and classified: excluded ${excluded_matches}; classified $(printf '%s' "${class_matches}" | paste -sd '; ' -)"
      continue
    fi
    if (( excluded_count == 1 )); then
      continue
    fi
    if (( class_count == 0 )); then
      fail "undeclared rotation key ${origin}"
      continue
    fi
    if (( class_count > 1 )); then
      fail "${origin} matches multiple classified rows: $(printf '%s' "${class_matches}" | paste -sd '; ' -)"
    fi
  done < "${LIVE_KEYS}"
}

check_dead_class_rows() {
  local row pattern _class _driver _probe matches identity key_path _origin
  while IFS=$'\t' read -r row pattern _class _driver _probe; do
    [[ -n "${row}" && -n "${pattern}" ]] || continue
    matches=0
    while IFS=$'\t' read -r identity key_path _origin; do
      [[ -n "${identity}" ]] || continue
      if pattern_matches "${pattern}" "${identity}" "${key_path}"; then
        matches=$((matches + 1))
      fi
    done < "${LIVE_KEYS}"
    if (( matches == 0 )); then
      fail "manifest row ${row} (${pattern}) matches no live derived key"
    fi
  done < "${CLASS_ROWS}"
}

main() {
  if ! command -v yq >/dev/null 2>&1; then
    fail "required tool not found: yq"
    finish
  fi

  enumerate_sops_files
  enumerate_ensure_app_secrets
  load_manifest
  check_live_key_coverage
  check_dead_class_rows
  finish
}

main "$@"
