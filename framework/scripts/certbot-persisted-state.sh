#!/usr/bin/env bash
# certbot-persisted-state.sh -- Check or repair persisted certbot lineage.

set -euo pipefail

MODE=""
EXPECTED_ACME_URL=""
EXPECTED_MODE=""
LETSENCRYPT_DIR="/etc/letsencrypt"
WORK_DIR="/var/lib/letsencrypt"
LOGS_DIR="/var/log/letsencrypt"
CERTBOT_BIN="${CERTBOT_BIN:-certbot}"
OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
FQDN=""
LABEL=""
FAIL_ON_FAKE_LEAF=0
EXPECTED_ACCOUNT_CACHE=""

usage() {
  cat <<'EOF'
Usage:
  certbot-persisted-state.sh --mode check|repair \
    --expected-acme-url URL \
    --expected-mode production|staging \
    [--letsencrypt-dir DIR] \
    [--work-dir DIR] \
    [--logs-dir DIR] \
    [--fqdn NAME] \
    [--label NAME] \
    [--certbot-bin PATH] \
    [--openssl-bin PATH] \
    [--fail-on-fake-leaf]
EOF
}

trim_whitespace() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "${value}"
}

log_line() {
  local level="$1"
  shift
  if [[ -n "${LABEL}" ]]; then
    printf '%s: %s: %s\n' "${level}" "${LABEL}" "$*" >&2
  else
    printf '%s: %s\n' "${level}" "$*" >&2
  fi
}

info() {
  log_line "INFO" "$@"
}

warn() {
  log_line "WARN" "$@"
}

error() {
  log_line "ERROR" "$@"
}

account_storage_root() {
  local server_url="$1"
  local server_path="${server_url#https://}"
  server_path="${server_path#http://}"
  printf '%s/accounts/%s\n' "${LETSENCRYPT_DIR}" "${server_path}"
}

list_renewal_files() {
  if [[ -n "${FQDN}" ]]; then
    local renewal_file="${LETSENCRYPT_DIR}/renewal/${FQDN}.conf"
    [[ -f "${renewal_file}" ]] && printf '%s\n' "${renewal_file}"
    return 0
  fi

  [[ -d "${LETSENCRYPT_DIR}/renewal" ]] || return 0
  find "${LETSENCRYPT_DIR}/renewal" -maxdepth 1 -type f -name '*.conf' | sort
}

extract_conf_value() {
  local renewal_file="$1"
  local key_name="$2"
  awk -F '=' -v key_name="${key_name}" '
    $1 ~ "^[[:space:]]*" key_name "[[:space:]]*$" {
      value = $2
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "${renewal_file}"
}

account_exists_under_server() {
  local server_url="$1"
  local account_id="$2"
  [[ -n "${account_id}" ]] || return 1
  [[ -d "$(account_storage_root "${server_url}")/${account_id}" ]]
}

pick_account_for_server() {
  local server_url="$1"
  local account_root
  local account_dir

  account_root="$(account_storage_root "${server_url}")"
  [[ -d "${account_root}" ]] || return 1

  while IFS= read -r account_dir; do
    [[ -z "${account_dir}" ]] && continue
    if [[ -s "${account_dir}/regr.json" || -f "${account_dir}/meta.json" ]]; then
      basename "${account_dir}"
      return 0
    fi
  done < <(find "${account_root}" -mindepth 1 -maxdepth 1 -type d | sort)

  account_dir="$(find "${account_root}" -mindepth 1 -maxdepth 1 -type d | sort | head -1)"
  [[ -n "${account_dir}" ]] || return 1
  basename "${account_dir}"
}

account_server_for_id() {
  local account_id="$1"
  local account_dir
  account_dir="$(find "${LETSENCRYPT_DIR}/accounts" -mindepth 2 -maxdepth 3 -type d -name "${account_id}" 2>/dev/null | sort | head -1 || true)"
  [[ -n "${account_dir}" ]] || return 1

  account_dir="${account_dir#${LETSENCRYPT_DIR}/accounts/}"
  account_dir="${account_dir%/${account_id}}"
  printf 'https://%s\n' "${account_dir}"
}

ensure_expected_account() {
  local account_id

  if [[ -n "${EXPECTED_ACCOUNT_CACHE}" ]]; then
    printf '%s\n' "${EXPECTED_ACCOUNT_CACHE}"
    return 0
  fi

  if account_id="$(pick_account_for_server "${EXPECTED_ACME_URL}" 2>/dev/null)"; then
    EXPECTED_ACCOUNT_CACHE="${account_id}"
    printf '%s\n' "${account_id}"
    return 0
  fi

  info "No account found for ${EXPECTED_ACME_URL}; registering one"
  mkdir -p "${WORK_DIR}" "${LOGS_DIR}"
  "${CERTBOT_BIN}" register \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    --server "${EXPECTED_ACME_URL}" \
    --config-dir "${LETSENCRYPT_DIR}" \
    --work-dir "${WORK_DIR}" \
    --logs-dir "${LOGS_DIR}" >/dev/null

  if ! account_id="$(pick_account_for_server "${EXPECTED_ACME_URL}" 2>/dev/null)"; then
    error "certbot registered an account but no account directory was created for ${EXPECTED_ACME_URL}"
    return 1
  fi

  EXPECTED_ACCOUNT_CACHE="${account_id}"
  printf '%s\n' "${account_id}"
}

rewrite_conf_value() {
  local renewal_file="$1"
  local key_name="$2"
  local value="$3"
  local tmp_file

  tmp_file="$(mktemp "${TMPDIR:-/tmp}/certbot-persisted-state.XXXXXX")"
  awk -v key_name="${key_name}" -v value="${value}" '
    BEGIN { updated = 0 }
    $0 ~ "^[[:space:]]*" key_name "[[:space:]]*=" {
      print key_name " = " value
      updated = 1
      next
    }
    { print }
    END {
      if (!updated) {
        print key_name " = " value
      }
    }
  ' "${renewal_file}" > "${tmp_file}"
  cat "${tmp_file}" > "${renewal_file}"
  rm -f "${tmp_file}"
}

leaf_issuer() {
  local cert_name="$1"
  local fullchain="${LETSENCRYPT_DIR}/live/${cert_name}/fullchain.pem"
  [[ -s "${fullchain}" ]] || return 0
  "${OPENSSL_BIN}" x509 -in "${fullchain}" -noout -issuer 2>/dev/null | sed 's/^issuer= *//'
}

issuer_is_fake_le() {
  local issuer_line="$1"
  # LE staging certs use "(STAGING)" in issuer, not "Fake LE"
  [[ "${issuer_line}" == *"Fake LE"* || "${issuer_line}" == *"STAGING"* ]]
}

# Check for 0-byte PEM files in a cert lineage. Returns 0 if any
# empty PEM is found. Certbot can leave these after failed ACME
# challenges, and they prevent certbot from re-requesting.
has_empty_pems() {
  local cert_name="$1"
  local live_dir="${LETSENCRYPT_DIR}/live/${cert_name}"
  local archive_dir="${LETSENCRYPT_DIR}/archive/${cert_name}"
  local pem
  for pem in "${live_dir}"/*.pem "${archive_dir}"/*.pem; do
    [[ -e "${pem}" ]] || continue
    if [[ ! -s "${pem}" ]]; then
      return 0
    fi
  done
  return 1
}

# Remove an entire cert lineage (live, archive, renewal config).
remove_lineage() {
  local cert_name="$1"
  local renewal_file="$2"
  rm -rf "${LETSENCRYPT_DIR}/live/${cert_name}" "${LETSENCRYPT_DIR}/archive/${cert_name}"
  rm -f "${renewal_file}"
  info "${cert_name}: removed live/, archive/, and renewal config"
}

check_renewal_state() {
  local renewal_file="$1"
  local cert_name="$2"
  local current_server current_account account_server issuer_line
  local failed=0

  current_server="$(extract_conf_value "${renewal_file}" "server")"
  current_account="$(extract_conf_value "${renewal_file}" "account")"

  if [[ "${current_server}" != "${EXPECTED_ACME_URL}" ]]; then
    error "${cert_name}: renewal ${renewal_file} has server = ${current_server:-<missing>} (expected ${EXPECTED_ACME_URL})"
    failed=1
  fi

  if [[ -z "${current_account}" ]]; then
    error "${cert_name}: renewal ${renewal_file} is missing account ="
    failed=1
  elif ! account_exists_under_server "${EXPECTED_ACME_URL}" "${current_account}"; then
    account_server="$(account_server_for_id "${current_account}" || true)"
    if [[ -n "${account_server}" ]]; then
      error "${cert_name}: renewal ${renewal_file} uses account ${current_account} from ${account_server} (expected ${EXPECTED_ACME_URL})"
    else
      error "${cert_name}: renewal ${renewal_file} uses account ${current_account} but no matching account exists under ${EXPECTED_ACME_URL}"
    fi
    failed=1
  fi

  if has_empty_pems "${cert_name}"; then
    error "${cert_name}: EMPTY PEM FILES DETECTED — lineage contains 0-byte cert files"
    failed=1
  fi

  issuer_line="$(leaf_issuer "${cert_name}" || true)"
  if [[ "${EXPECTED_MODE}" == "production" && -n "${issuer_line}" ]] && issuer_is_fake_le "${issuer_line}"; then
    if [[ "${FAIL_ON_FAKE_LEAF}" -eq 1 ]]; then
      error "${cert_name}: live issuer is ${issuer_line}"
      failed=1
    else
      warn "${cert_name}: live issuer is ${issuer_line}"
    fi
  fi

  return "${failed}"
}

repair_renewal_state() {
  local renewal_file="$1"
  local cert_name="$2"
  local current_server current_account desired_account issuer_line
  local account_is_expected=0

  current_server="$(extract_conf_value "${renewal_file}" "server")"
  current_account="$(extract_conf_value "${renewal_file}" "account")"
  desired_account="${current_account}"

  if account_exists_under_server "${EXPECTED_ACME_URL}" "${current_account}"; then
    account_is_expected=1
  fi

  if [[ -z "${current_account}" || "${account_is_expected}" -ne 1 ]]; then
    desired_account="$(ensure_expected_account)"
  fi

  # Empty PEM cleanup — remove the entire lineage so certbot treats it
  # as a fresh request on the next run.
  if has_empty_pems "${cert_name}"; then
    warn "${cert_name}: EMPTY PEM FILES DETECTED — removing stale lineage"
    remove_lineage "${cert_name}" "${renewal_file}"
    return 0
  fi

  if [[ "${current_server}" != "${EXPECTED_ACME_URL}" ]]; then
    rewrite_conf_value "${renewal_file}" "server" "${EXPECTED_ACME_URL}"
    info "${cert_name}: rewrote server to ${EXPECTED_ACME_URL}"
  fi

  if [[ -z "${current_account}" || "${current_account}" != "${desired_account}" ]]; then
    rewrite_conf_value "${renewal_file}" "account" "${desired_account}"
    info "${cert_name}: rewrote account to ${desired_account}"
  fi

  issuer_line="$(leaf_issuer "${cert_name}" || true)"
  if [[ "${EXPECTED_MODE}" == "production" && -n "${issuer_line}" ]] && issuer_is_fake_le "${issuer_line}"; then
    warn "${cert_name}: live issuer is still ${issuer_line}; renewal lineage is fixed but the leaf cert will rotate on the next renewal"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --expected-acme-url)
      EXPECTED_ACME_URL="$2"
      shift 2
      ;;
    --expected-mode)
      EXPECTED_MODE="$2"
      shift 2
      ;;
    --letsencrypt-dir)
      LETSENCRYPT_DIR="$2"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="$2"
      shift 2
      ;;
    --logs-dir)
      LOGS_DIR="$2"
      shift 2
      ;;
    --fqdn)
      FQDN="$2"
      shift 2
      ;;
    --label)
      LABEL="$2"
      shift 2
      ;;
    --certbot-bin)
      CERTBOT_BIN="$2"
      shift 2
      ;;
    --openssl-bin)
      OPENSSL_BIN="$2"
      shift 2
      ;;
    --fail-on-fake-leaf)
      FAIL_ON_FAKE_LEAF=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "${MODE}" != "check" && "${MODE}" != "repair" ]]; then
  echo "ERROR: --mode must be check or repair" >&2
  exit 2
fi

if [[ -z "${EXPECTED_ACME_URL}" ]]; then
  echo "ERROR: --expected-acme-url is required" >&2
  exit 2
fi

if [[ "${EXPECTED_MODE}" != "production" && "${EXPECTED_MODE}" != "staging" ]]; then
  echo "ERROR: --expected-mode must be production or staging" >&2
  exit 2
fi

RENEWAL_FILES=()
while IFS= read -r renewal_file; do
  [[ -z "${renewal_file}" ]] && continue
  RENEWAL_FILES+=("${renewal_file}")
done < <(list_renewal_files)
if [[ "${#RENEWAL_FILES[@]}" -eq 0 ]]; then
  info "No renewal files found under ${LETSENCRYPT_DIR}/renewal"
  exit 0
fi

FAILURES=0
for renewal_file in "${RENEWAL_FILES[@]}"; do
  cert_name="$(basename "${renewal_file}" .conf)"
  if [[ "${MODE}" == "check" ]]; then
    if ! check_renewal_state "${renewal_file}" "${cert_name}"; then
      FAILURES=$((FAILURES + 1))
    fi
  else
    if ! repair_renewal_state "${renewal_file}" "${cert_name}"; then
      FAILURES=$((FAILURES + 1))
    fi
  fi
done

if [[ "${FAILURES}" -gt 0 ]]; then
  exit 1
fi
