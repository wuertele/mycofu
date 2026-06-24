#!/usr/bin/env bash
# vault-requirements-lib.sh — Shared helpers for Vault requirement manifests.

vault_requirements_find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2
  return 1
}

if [[ -z "${VAULT_REQUIREMENTS_REPO_DIR:-}" ]]; then
  if [[ -n "${REPO_DIR:-}" ]]; then
    VAULT_REQUIREMENTS_REPO_DIR="${REPO_DIR}"
  else
    VAULT_REQUIREMENTS_REPO_DIR="$(vault_requirements_find_repo_root)"
  fi
fi

VAULT_REQUIREMENTS_CATALOG_DIR="${VAULT_REQUIREMENTS_REPO_DIR}/framework/catalog"
VAULT_REQUIREMENTS_FIXED_ROLE_DIR="${VAULT_REQUIREMENTS_REPO_DIR}/framework/tofu/modules"
VAULT_REQUIREMENTS_APPS_CONFIG="${VAULT_REQUIREMENTS_REPO_DIR}/site/applications.yaml"
VAULT_REQUIREMENTS_SECRETS_FILE="${VAULT_REQUIREMENTS_REPO_DIR}/site/sops/secrets.yaml"

catalog_app_manifest_path() {
  local app="$1"
  printf '%s\n' "${VAULT_REQUIREMENTS_CATALOG_DIR}/${app}/vault-requirements.yaml"
}

fixed_role_manifest_path() {
  local role="$1"
  printf '%s\n' "${VAULT_REQUIREMENTS_FIXED_ROLE_DIR}/${role}/vault-requirements.yaml"
}

vault_requirements_manifest_path() {
  local subject="$1"
  local catalog_manifest fixed_role_manifest

  catalog_manifest="$(catalog_app_manifest_path "$subject")"
  if [[ -f "${catalog_manifest}" ]]; then
    printf '%s\n' "${catalog_manifest}"
    return 0
  fi

  fixed_role_manifest="$(fixed_role_manifest_path "$subject")"
  if [[ -f "${fixed_role_manifest}" ]]; then
    printf '%s\n' "${fixed_role_manifest}"
    return 0
  fi

  echo "ERROR: '${subject}' does not define vault requirements at ${catalog_manifest} or ${fixed_role_manifest}" >&2
  return 1
}

catalog_app_has_approle_manifest() {
  local app="$1"
  [[ -f "$(catalog_app_manifest_path "$app")" ]]
}

list_catalog_apps_with_approle() {
  [[ -d "${VAULT_REQUIREMENTS_CATALOG_DIR}" ]] || return 0
  find "${VAULT_REQUIREMENTS_CATALOG_DIR}" -mindepth 2 -maxdepth 2 -type f -name 'vault-requirements.yaml' \
    | sed -E 's#^.*/framework/catalog/([^/]+)/vault-requirements\.yaml$#\1#' \
    | sort -u
}

list_fixed_roles_with_approle() {
  [[ -d "${VAULT_REQUIREMENTS_FIXED_ROLE_DIR}" ]] || return 0
  find "${VAULT_REQUIREMENTS_FIXED_ROLE_DIR}" -mindepth 2 -maxdepth 2 -type f -name 'vault-requirements.yaml' \
    | sed -E 's#^.*/framework/tofu/modules/([^/]+)/vault-requirements\.yaml$#\1#' \
    | sort -u
}

list_enabled_catalog_apps_with_approle() {
  local app=""
  while IFS= read -r app; do
    [[ -z "$app" ]] && continue
    if [[ "$(yq -r ".applications.${app}.enabled // false" "${VAULT_REQUIREMENTS_APPS_CONFIG}" 2>/dev/null)" == "true" ]]; then
      printf '%s\n' "$app"
    fi
  done < <(list_catalog_apps_with_approle)
}

vault_requirements_render_template() {
  local template="$1"
  local env="$2"
  printf '%s\n' "${template//\$\{env\}/${env}}"
}

list_manifest_approles() {
  local subject="$1"
  local env="$2"
  local manifest
  manifest="$(vault_requirements_manifest_path "$subject")" || return 1

  if [[ ! -f "$manifest" ]]; then
    echo "ERROR: '${subject}' does not define vault requirements at ${manifest}" >&2
    return 1
  fi

  local raw_rows=""
  raw_rows="$(yq -r '.approles[]? | [.name_template, (.policy // ""), .sops_keys.role_id, .sops_keys.secret_id] | @tsv' "$manifest" 2>/dev/null || true)"
  if [[ -z "$raw_rows" ]]; then
    echo "ERROR: ${manifest} has no approles entries" >&2
    return 1
  fi

  local name_template=""
  local policy=""
  local role_key_template=""
  local secret_key_template=""
  while IFS=$'\t' read -r name_template policy role_key_template secret_key_template; do
    [[ -z "$name_template" || -z "$role_key_template" || -z "$secret_key_template" ]] && {
      echo "ERROR: ${manifest} has an incomplete approles entry" >&2
      return 1
    }
    printf '%s\t%s\t%s\t%s\n' \
      "$(vault_requirements_render_template "$name_template" "$env")" \
      "$policy" \
      "$(vault_requirements_render_template "$role_key_template" "$env")" \
      "$(vault_requirements_render_template "$secret_key_template" "$env")"
  done <<< "$raw_rows"
}

resolve_sops_keys() {
  local subject="$1"
  local env="$2"
  local role_name=""
  local policy=""
  local role_key=""
  local secret_key=""
  while IFS=$'\t' read -r role_name policy role_key secret_key; do
    printf '%s\t%s\n' "$role_key" "$secret_key"
  done < <(list_manifest_approles "$subject" "$env")
}

check_sops_key_exists() {
  local key="$1"
  local value=""
  set +e
  value="$(sops -d --extract "[\"${key}\"]" "${VAULT_REQUIREMENTS_SECRETS_FILE}" 2>/dev/null)"
  local sops_exit=$?
  set -e
  [[ $sops_exit -eq 0 && -n "$value" && "$value" != "null" ]]
}
