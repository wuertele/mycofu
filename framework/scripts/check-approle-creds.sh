#!/usr/bin/env bash
# check-approle-creds.sh — Fail fast when required AppRole creds are missing.

set -euo pipefail

find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2
  exit 1
}

REPO_DIR="$(find_repo_root)"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
CONFIG_FILE="${REPO_DIR}/site/config.yaml"

for tool in sops yq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: Required tool not found: ${tool}" >&2
    exit 1
  fi
done

if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
  if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
  elif [[ -f "${REPO_DIR}/operator.age.key.production" ]]; then
    export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key.production"
  elif [[ -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
    export SOPS_AGE_KEY_FILE="${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt"
  else
    echo "ERROR: No SOPS age key found." >&2
    echo "Set SOPS_AGE_KEY_FILE, or place your key at:" >&2
    echo "  ${REPO_DIR}/operator.age.key" >&2
    echo "  ${REPO_DIR}/operator.age.key.production" >&2
    echo "  ${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" >&2
    exit 1
  fi
fi

export VAULT_REQUIREMENTS_REPO_DIR="${REPO_DIR}"
source "${REPO_DIR}/framework/scripts/vault-requirements-lib.sh"

determine_target_env() {
  # Precedence: CI_COMMIT_BRANCH (dev/prod push) > FORCE_ENV (test/manual override).
  # CI_MERGE_REQUEST_TARGET_BRANCH_NAME was previously consulted as a second-tier
  # source, but the corresponding `validate:approle-creds` job no longer runs on
  # MR pipelines (removed in commit 16f0179 to resolve the new-app onboarding
  # chicken-and-egg). Keeping the dead branch made FORCE_ENV silently ignored on
  # any MR pipeline that targeted prod, which broke the test fixtures the first
  # time a dev->prod MR ran them. If the live preflight is ever re-enabled on
  # MRs (follow-up: "Re-enable approle-creds live preflight on dev->prod MRs"),
  # add the precedence entry back here together with whatever resolution
  # semantics that work decides on, and update tests/test_approle_onboarding.sh
  # sub-test 4 to assert the new behavior.
  if [[ "${CI_COMMIT_BRANCH:-}" == "dev" || "${CI_COMMIT_BRANCH:-}" == "prod" ]]; then
    printf '%s\n' "${CI_COMMIT_BRANCH}"
    return 0
  fi

  if [[ "${FORCE_ENV:-}" == "dev" || "${FORCE_ENV:-}" == "prod" ]]; then
    printf '%s\n' "${FORCE_ENV}"
    return 0
  fi

  cat >&2 <<'EOF'
ERROR: Cannot determine target environment for AppRole preflight.
CI_COMMIT_BRANCH is unset or not dev/prod.

Set FORCE_ENV=dev or FORCE_ENV=prod to specify the environment,
or run this check from a dev or prod branch push.
EOF
  return 1
}

print_missing_creds_error() {
  local app="$1"
  local env="$2"
  cat >&2 <<EOF
ERROR: ${app} is enabled in applications.yaml but has no AppRole
credentials in SOPS for ${env}.

New catalog apps require a one-time onboarding step from the
workstation:

  framework/scripts/rebuild-cluster.sh --scope onboard-app=${app}
  git push

This creates the AppRole in Vault and commits credentials to
SOPS. After pushing, retry your deploy.

See OPERATIONS.md section "Onboarding new catalog apps".
EOF
}

print_missing_fixed_role_creds_error() {
  local role="$1"
  local env="$2"
  cat >&2 <<EOF
ERROR: ${role} is defined in site/config.yaml for ${env} but has no AppRole
credentials in SOPS.

This fixed role now declares a vault-requirements.yaml manifest so the
preflight fails before CIDATA is generated with empty Vault auth files.

Remaining operator step:
  Create or update the live ${role}_${env} AppRole from an operator
  workstation, then write these keys to site/sops/secrets.yaml:
    vault_approle_${role}_${env}_role_id
    vault_approle_${role}_${env}_secret_id

Commit the SOPS change and retry the deploy.
EOF
}

fixed_role_present_in_env() {
  local role="$1"
  local env="$2"

  if [[ "$(yq -r ".vms | has(\"${role}_${env}\")" "${CONFIG_FILE}" 2>/dev/null)" == "true" ]]; then
    return 0
  fi

  if [[ "${env}" == "prod" ]] && \
     [[ "$(yq -r ".vms | has(\"${role}\")" "${CONFIG_FILE}" 2>/dev/null)" == "true" ]]; then
    return 0
  fi

  return 1
}

check_subject_creds() {
  local subject="$1"
  local env="$2"
  local error_handler="$3"
  local role_key=""
  local secret_key=""
  local resolved_keys=""

  resolved_keys="$(resolve_sops_keys "$subject" "$env")" || exit 1
  while IFS=$'\t' read -r role_key secret_key; do
    if ! check_sops_key_exists "$role_key" || ! check_sops_key_exists "$secret_key"; then
      "${error_handler}" "$subject" "$env"
      MISSING=1
      break
    fi
  done <<< "$resolved_keys"
}

ENVIRONMENT="$(determine_target_env)"
MISSING=0
APP=""
ROLE=""
ROLE_KEY=""
SECRET_KEY=""
RESOLVED_KEYS=""

while IFS= read -r APP; do
  [[ -z "$APP" ]] && continue
  if [[ "$(yq -r ".applications.${APP}.enabled // false" "${APPS_CONFIG}" 2>/dev/null)" != "true" ]]; then
    continue
  fi

  check_subject_creds "$APP" "$ENVIRONMENT" print_missing_creds_error
done < <(list_catalog_apps_with_approle)

# Keep fixed roles manifest-backed instead of trying to infer every Vault
# consumer from Nix imports or Terraform wiring. The preflight should follow
# explicit AppRole declarations, and testapp is the first non-catalog role
# that needs the same fail-loud coverage as catalog apps.
while IFS= read -r ROLE; do
  [[ -z "$ROLE" ]] && continue
  if ! fixed_role_present_in_env "$ROLE" "$ENVIRONMENT"; then
    continue
  fi

  check_subject_creds "$ROLE" "$ENVIRONMENT" print_missing_fixed_role_creds_error
done < <(list_fixed_roles_with_approle)

if [[ $MISSING -ne 0 ]]; then
  exit 1
fi

echo "AppRole credential preflight passed for ${ENVIRONMENT}."
