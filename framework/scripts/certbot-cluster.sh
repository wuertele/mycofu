#!/usr/bin/env bash
# certbot-cluster.sh -- Shared inventory and runtime helpers for certbot checks.
#
# This file is sourced by rebuild-cluster.sh, backup-now.sh, validate.sh, and
# shell tests. It intentionally avoids side effects at load time.

if [[ -z "${CERTBOT_CLUSTER_YQ_BIN:-}" ]]; then
  CERTBOT_CLUSTER_YQ_BIN="yq"
fi
if [[ -z "${CERTBOT_CLUSTER_SSH_BIN:-}" ]]; then
  CERTBOT_CLUSTER_SSH_BIN="ssh"
fi
if [[ -z "${CERTBOT_CLUSTER_CONFIG:-}" && -n "${CONFIG:-}" ]]; then
  CERTBOT_CLUSTER_CONFIG="${CONFIG}"
fi
if [[ -z "${CERTBOT_CLUSTER_APPS_CONFIG:-}" && -n "${APPS_CONFIG:-}" ]]; then
  CERTBOT_CLUSTER_APPS_CONFIG="${APPS_CONFIG}"
fi

_certbot_cluster_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${CERTBOT_CLUSTER_REPO_DIR:-}" ]]; then
  CERTBOT_CLUSTER_REPO_DIR="$(cd "${_certbot_cluster_script_dir}/../.." && pwd)"
fi
if [[ -z "${CERTBOT_CLUSTER_PERSISTED_STATE_SCRIPT:-}" ]]; then
  CERTBOT_CLUSTER_PERSISTED_STATE_SCRIPT="${_certbot_cluster_script_dir}/certbot-persisted-state.sh"
fi
if [[ -z "${CERTBOT_CLUSTER_GATUS_CERT_GROUP:-}" ]]; then
  CERTBOT_CLUSTER_GATUS_CERT_GROUP="certificates"
fi

certbot_cluster_expected_mode() {
  local config_path="${1:-${CERTBOT_CLUSTER_CONFIG}}"
  "${CERTBOT_CLUSTER_YQ_BIN}" -r '.acme // "production"' "${config_path}"
}

certbot_cluster_expected_url() {
  local config_path="${1:-${CERTBOT_CLUSTER_CONFIG}}"
  case "$(certbot_cluster_expected_mode "${config_path}")" in
    production)
      printf '%s\n' "https://acme-v02.api.letsencrypt.org/directory"
      ;;
    staging)
      printf '%s\n' "https://acme-staging-v02.api.letsencrypt.org/directory"
      ;;
    *)
      return 1
      ;;
  esac
}

certbot_cluster_module_for_vm_label() {
  local vm_label="$1"
  case "${vm_label}" in
    dns1_prod|dns2_prod)
      printf 'dns_prod\n'
      ;;
    dns1_dev|dns2_dev)
      printf 'dns_dev\n'
      ;;
    *)
      printf '%s\n' "${vm_label}"
      ;;
  esac
}

certbot_cluster_fqdn_for_vm_label() {
  local vm_label="$1"
  local domain="$2"
  local host_name env_name

  case "${vm_label}" in
    *_prod)
      host_name="${vm_label%_prod}"
      env_name="prod"
      ;;
    *_dev)
      host_name="${vm_label%_dev}"
      env_name="dev"
      ;;
    *)
      host_name="${vm_label}"
      env_name="prod"
      ;;
  esac

  printf '%s.%s.%s\n' "${host_name}" "${env_name}" "${domain}"
}

certbot_cluster_module_in_scope() {
  local module_name="$1"
  local tofu_targets="${2:-}"

  [[ -z "${tofu_targets}" ]] && return 0
  [[ " ${tofu_targets} " == *" -target=module.${module_name} "* ]]
}

certbot_cluster_vm_has_certbot_runtime() {
  local vm_ip="$1"
  local probe_output=""
  local probe_status=0

  CERTBOT_CLUSTER_LAST_PROBE_ERROR=""

  [[ -z "${vm_ip}" || "${vm_ip}" == "null" || "${vm_ip}" == "-" ]] && return 1

  if probe_output="$("${CERTBOT_CLUSTER_SSH_BIN}" \
    -n \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "root@${vm_ip}" \
    '
      if find /etc/letsencrypt/renewal -maxdepth 1 -name "*.conf" -print -quit 2>/dev/null | grep -q .; then
        exit 0
      fi
      if systemctl cat certbot-initial.service >/dev/null 2>&1; then
        exit 0
      fi
      exit 1
    ' 2>&1)"; then
    return 0
  else
    probe_status=$?
  fi

  [[ "${probe_status}" -eq 1 ]] && return 1

  if [[ -n "${probe_output}" ]]; then
    CERTBOT_CLUSTER_LAST_PROBE_ERROR="${probe_output}"
  else
    CERTBOT_CLUSTER_LAST_PROBE_ERROR="ssh probe failed for ${vm_ip} (exit ${probe_status})"
  fi
  return 2
}

certbot_cluster_run_remote_helper() {
  local vm_ip="$1"
  shift

  # This helper is streamed over stdin to `bash -s` on the target VM, so we
  # must keep ssh attached to stdin instead of using `ssh -n`.
  "${CERTBOT_CLUSTER_SSH_BIN}" \
    -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    "root@${vm_ip}" \
    bash -s -- "$@" < "${CERTBOT_CLUSTER_PERSISTED_STATE_SCRIPT}"
}

certbot_cluster_backup_inventory_records() {
  local config_path="${1:-${CERTBOT_CLUSTER_CONFIG}}"
  local apps_config_path="${2:-${CERTBOT_CLUSTER_APPS_CONFIG}}"
  local domain
  local app_name env_name ip_addr vmid fqdn module_name

  domain="$("${CERTBOT_CLUSTER_YQ_BIN}" -r '.domain' "${config_path}")"

  while IFS= read -r vm_key; do
    [[ -z "${vm_key}" ]] && continue
    ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".vms.${vm_key}.ip // \"\"" "${config_path}")"
    vmid="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".vms.${vm_key}.vmid // \"\"" "${config_path}")"
    [[ -z "${ip_addr}" || "${ip_addr}" == "null" ]] && ip_addr="-"
    [[ -z "${vmid}" || "${vmid}" == "null" ]] && vmid="-"
    fqdn="$(certbot_cluster_fqdn_for_vm_label "${vm_key}" "${domain}")"
    module_name="$(certbot_cluster_module_for_vm_label "${vm_key}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${vm_key}" "${module_name}" "${ip_addr}" "${vmid}" "${fqdn}" "infra"
  done < <("${CERTBOT_CLUSTER_YQ_BIN}" -r '.vms | to_entries[] | select(.value.backup == true) | .key' "${config_path}" 2>/dev/null)

  [[ -f "${apps_config_path}" ]] || return 0

  while IFS= read -r app_name; do
    [[ -z "${app_name}" ]] && continue
    while IFS= read -r env_name; do
      [[ -z "${env_name}" ]] && continue
      ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.environments.${env_name}.ip // \"\"" "${apps_config_path}")"
      vmid="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.environments.${env_name}.vmid // \"\"" "${apps_config_path}")"
      [[ -z "${vmid}" || "${vmid}" == "null" ]] && continue
      [[ -z "${ip_addr}" || "${ip_addr}" == "null" ]] && ip_addr="-"
      fqdn="$(certbot_cluster_fqdn_for_vm_label "${app_name}_${env_name}" "${domain}")"
      module_name="$(certbot_cluster_module_for_vm_label "${app_name}_${env_name}")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${app_name}_${env_name}" "${module_name}" "${ip_addr}" "${vmid}" "${fqdn}" "app"
    done < <("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.environments | keys | .[]" "${apps_config_path}" 2>/dev/null)
  done < <("${CERTBOT_CLUSTER_YQ_BIN}" -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "${apps_config_path}" 2>/dev/null)
}

certbot_cluster_cert_storage_records() {
  local config_path="${1:-${CERTBOT_CLUSTER_CONFIG}}"
  local apps_config_path="${2:-${CERTBOT_CLUSTER_APPS_CONFIG}}"
  local env_filter="${3:-}"
  local domain
  local vm_key app_name ip_addr vmid fqdn module_name

  domain="$("${CERTBOT_CLUSTER_YQ_BIN}" -r '.domain' "${config_path}")"

  emit_infra_record() {
    local infra_vm_key="$1"
    ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".vms.${infra_vm_key}.ip // \"\"" "${config_path}")"
    vmid="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".vms.${infra_vm_key}.vmid // \"\"" "${config_path}")"
    [[ -z "${ip_addr}" || "${ip_addr}" == "null" ]] && return 0
    [[ -z "${vmid}" || "${vmid}" == "null" ]] && vmid="-"
    fqdn="$(certbot_cluster_fqdn_for_vm_label "${infra_vm_key}" "${domain}")"
    module_name="$(certbot_cluster_module_for_vm_label "${infra_vm_key}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${infra_vm_key}" "${module_name}" "${ip_addr}" "${vmid}" "${fqdn}" "infra"
  }

  # Keep the infra inventory explicit instead of deriving it only from
  # manifest-backed Vault cert storage. Budget checks must also include roles
  # like vault that terminate LE certs locally and rely on the downstream SSH
  # fallback when no Vault KV metadata exists for that FQDN.
  case "${env_filter}" in
    ""|prod)
      for vm_key in dns1_prod dns2_prod gatus gitlab testapp_prod vault_prod; do
        emit_infra_record "${vm_key}"
      done
      ;;
  esac

  case "${env_filter}" in
    ""|dev)
      for vm_key in dns1_dev dns2_dev testapp_dev vault_dev; do
        emit_infra_record "${vm_key}"
      done
      ;;
  esac

  [[ -f "${apps_config_path}" ]] || return 0

  for app_name in influxdb grafana workstation; do
    if [[ "$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.enabled // false" "${apps_config_path}" 2>/dev/null)" != "true" ]]; then
      continue
    fi

    for env_name in prod dev; do
      if [[ -n "${env_filter}" && "${env_name}" != "${env_filter}" ]]; then
        continue
      fi
      ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.environments.${env_name}.ip // \"\"" "${apps_config_path}")"
      vmid="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.environments.${env_name}.vmid // \"\"" "${apps_config_path}")"
      [[ -z "${ip_addr}" || "${ip_addr}" == "null" ]] && continue
      [[ -z "${vmid}" || "${vmid}" == "null" ]] && continue
      fqdn="$(certbot_cluster_fqdn_for_vm_label "${app_name}_${env_name}" "${domain}")"
      module_name="$(certbot_cluster_module_for_vm_label "${app_name}_${env_name}")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${app_name}_${env_name}" "${module_name}" "${ip_addr}" "${vmid}" "${fqdn}" "app"
    done
  done
}

certbot_cluster_prod_shared_candidate_records() {
  local config_path="${1:-${CERTBOT_CLUSTER_CONFIG}}"
  local apps_config_path="${2:-${CERTBOT_CLUSTER_APPS_CONFIG}}"
  local tofu_targets="${3:-}"
  local domain
  local vm_key app_name ip_addr vmid fqdn module_name backup_flag

  domain="$("${CERTBOT_CLUSTER_YQ_BIN}" -r '.domain' "${config_path}")"

  while IFS= read -r vm_key; do
    [[ -z "${vm_key}" ]] && continue
    module_name="$(certbot_cluster_module_for_vm_label "${vm_key}")"
    certbot_cluster_module_in_scope "${module_name}" "${tofu_targets}" || continue
    ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".vms.${vm_key}.ip // \"\"" "${config_path}")"
    vmid="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".vms.${vm_key}.vmid // \"\"" "${config_path}")"
    backup_flag="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".vms.${vm_key}.backup // false" "${config_path}")"
    [[ -z "${ip_addr}" || "${ip_addr}" == "null" ]] && ip_addr="-"
    [[ -z "${vmid}" || "${vmid}" == "null" ]] && vmid="-"
    fqdn="$(certbot_cluster_fqdn_for_vm_label "${vm_key}" "${domain}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${vm_key}" "${module_name}" "${ip_addr}" "${vmid}" "${fqdn}" "${backup_flag}" "infra"
  done < <("${CERTBOT_CLUSTER_YQ_BIN}" -r '.vms | to_entries[] | select(.key != "acme_dev" and (.key | test("_dev$") | not)) | .key' "${config_path}" 2>/dev/null)

  [[ -f "${apps_config_path}" ]] || return 0

  while IFS= read -r app_name; do
    [[ -z "${app_name}" ]] && continue
    module_name="$(certbot_cluster_module_for_vm_label "${app_name}_prod")"
    certbot_cluster_module_in_scope "${module_name}" "${tofu_targets}" || continue
    ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.environments.prod.ip // \"\"" "${apps_config_path}")"
    vmid="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.environments.prod.vmid // \"\"" "${apps_config_path}")"
    [[ -z "${vmid}" || "${vmid}" == "null" ]] && continue
    backup_flag="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.backup // false" "${apps_config_path}")"
    [[ -z "${ip_addr}" || "${ip_addr}" == "null" ]] && ip_addr="-"
    fqdn="$(certbot_cluster_fqdn_for_vm_label "${app_name}_prod" "${domain}")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${app_name}_prod" "${module_name}" "${ip_addr}" "${vmid}" "${fqdn}" "${backup_flag}" "app"
  done < <("${CERTBOT_CLUSTER_YQ_BIN}" -r '.applications // {} | to_entries[] | select(.value.enabled == true and (.value.environments.prod.vmid // "") != "") | .key' "${apps_config_path}" 2>/dev/null)
}

certbot_cluster_staging_override_targets() {
  local config_path="${1:-${CERTBOT_CLUSTER_CONFIG}}"
  local apps_config_path="${2:-${CERTBOT_CLUSTER_APPS_CONFIG}}"
  local tofu_targets="${3:-}"
  local vm_label module_name ip_addr vmid fqdn backup_flag kind

  while IFS=$'\t' read -r vm_label module_name ip_addr vmid fqdn backup_flag kind; do
    [[ -z "${vm_label}" ]] && continue
    certbot_cluster_vm_has_certbot_runtime "${ip_addr}" || continue
    [[ "${backup_flag}" == "true" ]] && continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${vm_label}" "${module_name}" "${ip_addr}" "${vmid}" "${fqdn}" "${backup_flag}" "${kind}"
  done < <(certbot_cluster_prod_shared_candidate_records "${config_path}" "${apps_config_path}" "${tofu_targets}")
}

certbot_cluster_prod_shared_backup_certbot_records() {
  local config_path="${1:-${CERTBOT_CLUSTER_CONFIG}}"
  local apps_config_path="${2:-${CERTBOT_CLUSTER_APPS_CONFIG}}"
  local vm_label module_name ip_addr vmid fqdn backup_flag kind
  local probe_status

  while IFS=$'\t' read -r vm_label module_name ip_addr vmid fqdn backup_flag kind; do
    [[ -z "${vm_label}" ]] && continue
    [[ "${backup_flag}" == "true" ]] || continue
    if certbot_cluster_vm_has_certbot_runtime "${ip_addr}"; then
      probe_status=0
    else
      probe_status=$?
    fi
    case "${probe_status}" in
      0)
        ;;
      1)
        continue
        ;;
      *)
        # Backups are the last clean copy of persisted certbot state. If a
        # backup-backed VM cannot be inspected, fail closed instead of assuming
        # it is safe to snapshot.
        echo "ERROR: Unable to inspect certbot runtime on backup-backed VM ${vm_label} (${ip_addr}); refusing to proceed unchecked." >&2
        if [[ -n "${CERTBOT_CLUSTER_LAST_PROBE_ERROR:-}" ]]; then
          echo "DETAIL: ${CERTBOT_CLUSTER_LAST_PROBE_ERROR}" >&2
        fi
        return 1
        ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${vm_label}" "${module_name}" "${ip_addr}" "${vmid}" "${fqdn}" "${backup_flag}" "${kind}"
  done < <(certbot_cluster_prod_shared_candidate_records "${config_path}" "${apps_config_path}")
}

certbot_cluster_gatus_cert_group() {
  printf '%s\n' "${CERTBOT_CLUSTER_GATUS_CERT_GROUP}"
}

certbot_cluster_catalog_health_port() {
  local app_name="$1"
  local repo_dir="${2:-${CERTBOT_CLUSTER_REPO_DIR}}"
  local health_file="${repo_dir}/framework/catalog/${app_name}/health.yaml"

  [[ -f "${health_file}" ]] || return 1
  "${CERTBOT_CLUSTER_YQ_BIN}" -r '.port // ""' "${health_file}"
}

certbot_cluster_gatus_cert_monitor_records() {
  local config_path="${1:-${CERTBOT_CLUSTER_CONFIG}}"
  local apps_config_path="${2:-${CERTBOT_CLUSTER_APPS_CONFIG}}"
  local repo_dir="${3:-${CERTBOT_CLUSTER_REPO_DIR}}"
  local acme_mode domain ip_addr port fqdn app_name

  acme_mode="$(certbot_cluster_expected_mode "${config_path}")"
  [[ "${acme_mode}" == "production" ]] || return 0

  domain="$("${CERTBOT_CLUSTER_YQ_BIN}" -r '.domain' "${config_path}")"

  ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r '.vms.vault_prod.ip // ""' "${config_path}")"
  if [[ -n "${ip_addr}" && "${ip_addr}" != "null" ]]; then
    fqdn="$(certbot_cluster_fqdn_for_vm_label "vault_prod" "${domain}")"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "cert-vault-prod" "vault_prod" "${ip_addr}" "8200" "${fqdn}"
  fi

  ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r '.vms.gitlab.ip // ""' "${config_path}")"
  if [[ -n "${ip_addr}" && "${ip_addr}" != "null" ]]; then
    fqdn="$(certbot_cluster_fqdn_for_vm_label "gitlab" "${domain}")"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "cert-gitlab" "gitlab" "${ip_addr}" "443" "${fqdn}"
  fi

  [[ -f "${apps_config_path}" ]] || return 0

  while IFS= read -r app_name; do
    [[ -z "${app_name}" ]] && continue

    if [[ "${app_name}" == "workstation" ]]; then
      ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r '.applications.workstation.environments.prod.ip // ""' "${apps_config_path}")"
      if [[ -n "${ip_addr}" && "${ip_addr}" != "null" ]]; then
        port="$(certbot_cluster_catalog_health_port "workstation" "${repo_dir}" 2>/dev/null || true)"
        if [[ -n "${port}" && "${port}" != "null" ]]; then
          fqdn="$(certbot_cluster_fqdn_for_vm_label "workstation_prod" "${domain}")"
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "cert-workstation-prod" "workstation_prod" "${ip_addr}" "${port}" "${fqdn}"
        fi
      fi

      ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r '.applications.workstation.environments.dev.mgmt_nic.ip // ""' "${apps_config_path}")"
      if [[ -n "${ip_addr}" && "${ip_addr}" != "null" ]]; then
        port="$(certbot_cluster_catalog_health_port "workstation" "${repo_dir}" 2>/dev/null || true)"
        if [[ -n "${port}" && "${port}" != "null" ]]; then
          fqdn="$(certbot_cluster_fqdn_for_vm_label "workstation_dev" "${domain}")"
          printf '%s\t%s\t%s\t%s\t%s\n' \
            "cert-workstation-dev" "workstation_dev" "${ip_addr}" "${port}" "${fqdn}"
        fi
      fi
      continue
    fi

    ip_addr="$("${CERTBOT_CLUSTER_YQ_BIN}" -r ".applications.${app_name}.environments.prod.ip // \"\"" "${apps_config_path}")"
    [[ -z "${ip_addr}" || "${ip_addr}" == "null" ]] && continue

    port="$(certbot_cluster_catalog_health_port "${app_name}" "${repo_dir}" 2>/dev/null || true)"
    [[ -z "${port}" || "${port}" == "null" ]] && continue

    fqdn="$(certbot_cluster_fqdn_for_vm_label "${app_name}_prod" "${domain}")"
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "cert-${app_name}-prod" "${app_name}_prod" "${ip_addr}" "${port}" "${fqdn}"
  done < <("${CERTBOT_CLUSTER_YQ_BIN}" -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.monitor == true) | .key' "${apps_config_path}" 2>/dev/null)
}
