#!/usr/bin/env bash
#
# On macOS, this test's nix build of the x86_64-linux logrotate derivation
# requires the local linux-builder to be running.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

GITLAB_DATA_MOUNT="/var/lib/gitlab"
GITLAB_DATA_DEVICE="/dev/disk/by-label/gitlab-data"
NGINX_LOG_MOUNT="/var/log/nginx"
GITLAB_NGINX_LOG_PATH="/var/lib/gitlab/nginx/logs"
GITLAB_NGINX_CLIENT_BODY_TEMP_PATH="/var/lib/gitlab/nginx/client-body"
GITLAB_NGINX_PROXY_TEMP_PATH="/var/lib/gitlab/nginx/proxy"
GITLAB_NGINX_FASTCGI_TEMP_PATH="/var/lib/gitlab/nginx/fastcgi"
GITLAB_NGINX_UWSGI_TEMP_PATH="/var/lib/gitlab/nginx/uwsgi"
GITLAB_NGINX_SCGI_TEMP_PATH="/var/lib/gitlab/nginx/scgi"

FILESYSTEMS_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.fileSystems')"
NGINX_AFTER_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.systemd.services.nginx.after')"
NGINX_REQUIRES_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.systemd.services.nginx.requires')"
NGINX_SERVICE_CONFIG_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.systemd.services.nginx.serviceConfig')"
NGINX_LOG_ERROR="$(nix eval --raw '.#nixosConfigurations.gitlab.config.services.nginx.logError')"
NGINX_APPEND_HTTP_CONFIG="$(nix eval --raw '.#nixosConfigurations.gitlab.config.services.nginx.appendHttpConfig')"
NGINX_STORAGE_AFTER_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.systemd.services."gitlab-nginx-storage".after')"
NGINX_STORAGE_REQUIRES_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.systemd.services."gitlab-nginx-storage".requires')"
NGINX_STORAGE_BEFORE_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.systemd.services."gitlab-nginx-storage".before')"
NGINX_STORAGE_REQUIRED_BY_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.systemd.services."gitlab-nginx-storage".requiredBy')"
NGINX_STORAGE_SERVICE_CONFIG_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.systemd.services."gitlab-nginx-storage".serviceConfig')"
NGINX_STORAGE_UNIT_CONFIG_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.systemd.services."gitlab-nginx-storage".unitConfig')"
LOGROTATE_NGINX_JSON="$(nix eval --json '.#nixosConfigurations.gitlab.config.services.logrotate.settings.nginx')"

mount_for_path() {
  local path="$1"
  printf '%s\n' "${FILESYSTEMS_JSON}" | jq -c --arg path "${path}" '
    def is_parent($mount; $path):
      $mount == "/" or $path == $mount or ($path | startswith($mount + "/"));

    to_entries
    | map(select(is_parent(.key; $path)))
    | sort_by(.key | length)
    | last
    | {
        mountPoint: .key,
        device: .value.device,
        fsType: .value.fsType,
        options: (.value.options // []),
        depends: (.value.depends // [])
      }
  '
}

json_list_has() {
  local json="$1"
  local value="$2"
  printf '%s\n' "${json}" | jq -e --arg value "${value}" 'index($value)' >/dev/null
}

json_attr_list_has() {
  local json="$1"
  local attr="$2"
  local value="$3"
  printf '%s\n' "${json}" | jq -e --arg attr "${attr}" --arg value "${value}" \
    '.[$attr] | if type == "array" then index($value) else . == $value end' >/dev/null
}

assert_json_field_equals() {
  local json="$1"
  local jq_filter="$2"
  local expected="$3"
  local label="$4"
  local actual

  actual="$(printf '%s\n' "${json}" | jq -r "${jq_filter}")"
  if [[ "${actual}" == "${expected}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label} (got ${actual}, expected ${expected})"
  fi
}

assert_nginx_http_directive() {
  local directive="$1"
  local label="$2"

  if printf '%s\n' "${NGINX_APPEND_HTTP_CONFIG}" | grep -Fq "${directive}"; then
    test_pass "${label}"
  else
    test_fail "missing nginx directive: ${directive}"
  fi
}

assert_path_backed_by_gitlab_data() {
  local path="$1"
  local label="$2"
  local resolved_path="${path}"
  local first_mount
  local backing_mount
  local mount_point
  local device
  local fs_type

  first_mount="$(mount_for_path "${resolved_path}")"
  mount_point="$(printf '%s\n' "${first_mount}" | jq -r '.mountPoint')"

  if [[ "${mount_point}" == "${NGINX_LOG_MOUNT}" ]]; then
    device="$(printf '%s\n' "${first_mount}" | jq -r '.device')"
    fs_type="$(printf '%s\n' "${first_mount}" | jq -r '.fsType')"

    if [[ "${device}" != "${GITLAB_NGINX_LOG_PATH}" || "${fs_type}" != "none" ]] || \
       ! printf '%s\n' "${first_mount}" | jq -e '.options | index("bind")' >/dev/null || \
       ! printf '%s\n' "${first_mount}" | jq -e --arg mount "${GITLAB_DATA_MOUNT}" '.depends | index($mount)' >/dev/null; then
      test_fail "${label} does not use the expected /var/log/nginx bind mount"
      return
    fi

    resolved_path="${GITLAB_NGINX_LOG_PATH}${resolved_path#${NGINX_LOG_MOUNT}}"
    backing_mount="$(mount_for_path "${resolved_path}")"
  else
    backing_mount="${first_mount}"
  fi

  mount_point="$(printf '%s\n' "${backing_mount}" | jq -r '.mountPoint')"
  device="$(printf '%s\n' "${backing_mount}" | jq -r '.device')"
  fs_type="$(printf '%s\n' "${backing_mount}" | jq -r '.fsType')"

  if [[ "${mount_point}" == "${GITLAB_DATA_MOUNT}" && \
        "${device}" == "${GITLAB_DATA_DEVICE}" && \
        "${fs_type}" == "ext4" ]] && \
     printf '%s\n' "${backing_mount}" | jq -e '.options | index("nofail")' >/dev/null; then
    test_pass "${label} resolves to the gitlab-data ext4 mount"
  else
    test_fail "${label} resolves to ${mount_point} (${device}, ${fs_type}), not ${GITLAB_DATA_DEVICE}"
  fi
}

test_start "1" "nginx log paths resolve through the stock path to the data disk"
assert_path_backed_by_gitlab_data "/var/log/nginx/access.log" "nginx access log"
assert_path_backed_by_gitlab_data "/var/log/nginx/error.log" "nginx error log"

test_start "2" "nginx evaluated config writes logs and temp spools to data-backed paths"
if [[ "${NGINX_LOG_ERROR}" == "/var/log/nginx/error.log" ]]; then
  test_pass "nginx main error_log uses /var/log/nginx/error.log at default severity"
else
  test_fail "nginx main error_log is not /var/log/nginx/error.log"
fi

assert_nginx_http_directive "client_body_temp_path ${GITLAB_NGINX_CLIENT_BODY_TEMP_PATH};" \
  "nginx client_body_temp_path uses the GitLab data disk path"
assert_nginx_http_directive "proxy_temp_path ${GITLAB_NGINX_PROXY_TEMP_PATH};" \
  "nginx proxy_temp_path uses the GitLab data disk path"
assert_nginx_http_directive "fastcgi_temp_path ${GITLAB_NGINX_FASTCGI_TEMP_PATH};" \
  "nginx fastcgi_temp_path uses the GitLab data disk path"
assert_nginx_http_directive "uwsgi_temp_path ${GITLAB_NGINX_UWSGI_TEMP_PATH};" \
  "nginx uwsgi_temp_path uses the GitLab data disk path"
assert_nginx_http_directive "scgi_temp_path ${GITLAB_NGINX_SCGI_TEMP_PATH};" \
  "nginx scgi_temp_path uses the GitLab data disk path"

assert_path_backed_by_gitlab_data "${GITLAB_NGINX_CLIENT_BODY_TEMP_PATH}/0000000001" \
  "nginx request-body temp spool"
assert_path_backed_by_gitlab_data "${GITLAB_NGINX_PROXY_TEMP_PATH}/0000000001" \
  "nginx proxy temp spool"
assert_path_backed_by_gitlab_data "${GITLAB_NGINX_FASTCGI_TEMP_PATH}/0000000001" \
  "nginx fastcgi temp spool"
assert_path_backed_by_gitlab_data "${GITLAB_NGINX_UWSGI_TEMP_PATH}/0000000001" \
  "nginx uwsgi temp spool"
assert_path_backed_by_gitlab_data "${GITLAB_NGINX_SCGI_TEMP_PATH}/0000000001" \
  "nginx scgi temp spool"

test_start "3" "nginx hardening remains enabled and permits only relocated temp writes"
assert_json_field_equals "${NGINX_SERVICE_CONFIG_JSON}" '.ProtectSystem' "strict" \
  "nginx keeps ProtectSystem=strict"
assert_json_field_equals "${NGINX_SERVICE_CONFIG_JSON}" '.LogsDirectory' "nginx" \
  "nginx keeps LogsDirectory=nginx for /var/log/nginx writes"

for temp_path in \
  "${GITLAB_NGINX_CLIENT_BODY_TEMP_PATH}" \
  "${GITLAB_NGINX_PROXY_TEMP_PATH}" \
  "${GITLAB_NGINX_FASTCGI_TEMP_PATH}" \
  "${GITLAB_NGINX_UWSGI_TEMP_PATH}" \
  "${GITLAB_NGINX_SCGI_TEMP_PATH}"
do
  if json_attr_list_has "${NGINX_SERVICE_CONFIG_JSON}" "ReadWritePaths" "${temp_path}"; then
    test_pass "nginx ReadWritePaths permits ${temp_path}"
  else
    test_fail "nginx ReadWritePaths does not include ${temp_path}"
  fi
done

if json_list_has "${NGINX_AFTER_JSON}" "var-log-nginx.mount" && \
   json_list_has "${NGINX_REQUIRES_JSON}" "var-log-nginx.mount" && \
   json_list_has "${NGINX_REQUIRES_JSON}" "gitlab-nginx-storage.service"; then
  test_pass "nginx is ordered after and requires the data-backed log mount"
else
  test_fail "nginx is not ordered against the data-backed log mount"
fi

if json_list_has "${NGINX_STORAGE_AFTER_JSON}" "var-lib-gitlab.mount" && \
   json_list_has "${NGINX_STORAGE_REQUIRES_JSON}" "var-lib-gitlab.mount" && \
   json_list_has "${NGINX_STORAGE_BEFORE_JSON}" "var-log-nginx.mount" && \
   json_list_has "${NGINX_STORAGE_REQUIRED_BY_JSON}" "var-log-nginx.mount"; then
  test_pass "gitlab-nginx-storage prepares the bind source after /var/lib/gitlab and before /var/log/nginx"
else
  test_fail "gitlab-nginx-storage ordering does not protect the overlay from source-dir creation"
fi

assert_json_field_equals "${NGINX_STORAGE_SERVICE_CONFIG_JSON}" '.Restart' "on-failure" \
  "gitlab-nginx-storage retries if the data mount is late"
assert_json_field_equals "${NGINX_STORAGE_SERVICE_CONFIG_JSON}" '.RestartSec' "5s" \
  "gitlab-nginx-storage uses a short restart delay"
assert_json_field_equals "${NGINX_STORAGE_UNIT_CONFIG_JSON}" '.StartLimitIntervalSec | tostring' "0" \
  "gitlab-nginx-storage retry loop is not start-limit capped"

test_start "4" "nginx logrotate is bounded and keeps upstream delaycompress"
assert_json_field_equals "${LOGROTATE_NGINX_JSON}" '.frequency' "daily" \
  "nginx logrotate runs daily"
assert_json_field_equals "${LOGROTATE_NGINX_JSON}" '.rotate | tostring' "14" \
  "nginx logrotate keeps 14 rotations"
assert_json_field_equals "${LOGROTATE_NGINX_JSON}" '.maxsize' "32M" \
  "nginx logrotate rotates early at 32M"
assert_json_field_equals "${LOGROTATE_NGINX_JSON}" '.compress | tostring' "true" \
  "nginx logrotate compression is enabled"
assert_json_field_equals "${LOGROTATE_NGINX_JSON}" '.delaycompress | tostring' "true" \
  "nginx logrotate delays compression for nginx worker reopen"

if printf '%s\n' "${LOGROTATE_NGINX_JSON}" | jq -e '.files == ["/var/log/nginx/*.log"]' >/dev/null; then
  test_pass "nginx logrotate still targets the stock /var/log/nginx glob"
else
  test_fail "nginx logrotate no longer targets /var/log/nginx/*.log"
fi

LOGROTATE_CONFIG="$(
  nix build --no-link --print-out-paths --no-warn-dirty \
    '.#nixosConfigurations.gitlab.config.services.logrotate.configFile'
)"
NGINX_LOGROTATE_SECTION="$(
  awk '
    /"\/var\/log\/nginx\/\*\.log" \{/ { in_section = 1 }
    in_section { print }
    in_section && /^\}/ { exit }
  ' "${LOGROTATE_CONFIG}"
)"

if printf '%s\n' "${NGINX_LOGROTATE_SECTION}" | grep -Fq 'daily' && \
   printf '%s\n' "${NGINX_LOGROTATE_SECTION}" | grep -Fq 'maxsize 32M' && \
   printf '%s\n' "${NGINX_LOGROTATE_SECTION}" | grep -Eq '^[[:space:]]*delaycompress$' && \
   printf '%s\n' "${NGINX_LOGROTATE_SECTION}" | grep -Fq 'rotate 14'; then
  test_pass "generated logrotate config renders the bounded nginx policy"
else
  test_fail "generated logrotate config does not render daily/maxsize/delaycompress/rotate 14"
fi

runner_summary
