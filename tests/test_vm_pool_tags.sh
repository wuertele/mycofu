#!/usr/bin/env bash
# test_vm_pool_tags.sh — Verify pool contract across config, generators, and validation.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

valid_pool() {
  case "$1" in
    control-plane|prod|dev) return 0 ;;
    *) return 1 ;;
  esac
}

check_pool_records() {
  local label="$1"
  local description="$2"
  local query_cmd="$3"

  local had_failure=0
  local count=0

  test_start "${label}" "${description}"

  while IFS=$'\t' read -r record_type record_name pool; do
    [[ -z "${record_type}" ]] && continue
    count=$((count + 1))

    if [[ -z "${pool}" ]]; then
      test_fail "${record_type} ${record_name} is missing pool"
      had_failure=1
      continue
    fi

    if valid_pool "${pool}"; then
      test_pass "${record_type} ${record_name} uses valid pool ${pool}"
    else
      test_fail "${record_type} ${record_name} uses invalid pool ${pool}"
      had_failure=1
    fi
  done < <(eval "${query_cmd}")

  if [[ "${count}" -eq 0 ]]; then
    test_fail "${description} returned no VM records"
    return
  fi

  if [[ "${had_failure}" -eq 0 ]]; then
    test_pass "${description} covers ${count} records"
  fi
}

setup_validator_fixture_repo() {
  local repo_dir="$1"

  mkdir -p "${repo_dir}/framework/scripts" "${repo_dir}/site"
  cp "${REPO_ROOT}/framework/scripts/validate-site-config.sh" "${repo_dir}/framework/scripts/validate-site-config.sh"
  cp "${REPO_ROOT}/framework/templates/config.yaml.example" "${repo_dir}/site/config.yaml"

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications:
  grafana:
    enabled: true
    node: node1
    ram: 2048
    cores: 2
    disk_size: 4
    data_disk_size: 10
    backup: true
    monitor: true
    environments:
      prod:
        ip: 10.0.10.70
        vmid: 601
        mac: "02:aa:bb:cc:dd:70"
        pool: prod
      dev:
        ip: 10.0.20.70
        vmid: 501
        mac: "02:aa:bb:cc:dd:71"
        pool: dev
EOF
}

run_validator_fixture() {
  local scenario="$1"
  local edit_cmd="${2:-}"
  local repo_dir="${TMP_DIR}/${scenario}-validator-repo"
  local output_file="${TMP_DIR}/${scenario}-validator.out"

  setup_validator_fixture_repo "${repo_dir}"
  if [[ -n "${edit_cmd}" ]]; then
    (
      cd "${repo_dir}"
      eval "${edit_cmd}"
    )
  fi

  set +e
  (
    cd "${repo_dir}"
    bash framework/scripts/validate-site-config.sh
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\t%s\n' "${status}" "${output_file}"
}

setup_enable_app_fixture_repo() {
  local repo_dir="$1"

  mkdir -p \
    "${repo_dir}/framework/scripts" \
    "${repo_dir}/framework/catalog/grafana" \
    "${repo_dir}/site" \
    "${repo_dir}/site/apps" \
    "${repo_dir}/site/nix/hosts"

  cp "${REPO_ROOT}/framework/scripts/enable-app.sh" "${repo_dir}/framework/scripts/enable-app.sh"
  cp "${REPO_ROOT}/framework/scripts/validate-site-config.sh" "${repo_dir}/framework/scripts/validate-site-config.sh"
  cp "${REPO_ROOT}/framework/templates/config.yaml.example" "${repo_dir}/site/config.yaml"

  cat > "${repo_dir}/site/applications.yaml" <<'EOF'
applications: {}
EOF

  cat > "${repo_dir}/framework/catalog/grafana/variables.tf" <<'EOF'
variable "ram_mb" {
  default = 2048
}

variable "cores" {
  default = 2
}

variable "vdb_size_gb" {
  default = 10
}
EOF

  cat > "${repo_dir}/framework/catalog/grafana/health.yaml" <<'EOF'
port: 3000
path: /api/health
EOF
}

run_enable_app_fixture() {
  local scenario="$1"
  local repo_dir="${TMP_DIR}/${scenario}-enable-app-repo"
  local output_file="${TMP_DIR}/${scenario}-enable-app.out"

  setup_enable_app_fixture_repo "${repo_dir}"

  set +e
  (
    cd "${repo_dir}"
    bash framework/scripts/enable-app.sh grafana
  ) > "${output_file}" 2>&1
  local status=$?
  set -e

  printf '%s\t%s\t%s\n' "${status}" "${repo_dir}" "${output_file}"
}

check_pool_records \
  "22.4" \
  "site/config.yaml VMs declare valid pools" \
  "yq -r '.vms | to_entries[] | [\"config\", .key, (.value.pool // \"\")] | @tsv' '${REPO_ROOT}/site/config.yaml'"

check_pool_records \
  "22.5" \
  "site/applications.yaml app environments declare valid pools" \
  "yq -r '.applications | to_entries[] | .key as \$app | (.value.environments // {}) | to_entries[] | [\"app\", (\$app + \"_\" + .key), (.value.pool // \"\")] | @tsv' '${REPO_ROOT}/site/applications.yaml'"

check_pool_records \
  "22.6" \
  "framework template VMs declare valid pools" \
  "yq -r '.vms | to_entries[] | [\"template\", .key, (.value.pool // \"\")] | @tsv' '${REPO_ROOT}/framework/templates/config.yaml.example'"

test_start "22.7" "validate-site-config.sh accepts valid pool data"
IFS=$'\t' read -r STATUS OUTPUT_FILE <<< "$(run_validator_fixture validator-valid)"
if [[ "${STATUS}" -eq 0 ]]; then
  test_pass "validator accepts complete config/app pool data"
else
  test_fail "validator accepts complete config/app pool data"
fi

test_start "22.8" "validate-site-config.sh rejects a missing infrastructure pool"
IFS=$'\t' read -r STATUS OUTPUT_FILE <<< "$(run_validator_fixture validator-missing-infra-pool 'yq -i '\''del(.vms.gitlab.pool)'\'' site/config.yaml')"
if [[ "${STATUS}" -ne 0 ]] && grep -q 'vms.gitlab.pool' "${OUTPUT_FILE}"; then
  test_pass "validator rejects missing infrastructure pool before tofu"
else
  test_fail "validator rejects missing infrastructure pool before tofu"
fi

test_start "22.9" "validate-site-config.sh rejects an invalid application pool"
IFS=$'\t' read -r STATUS OUTPUT_FILE <<< "$(run_validator_fixture validator-invalid-app-pool 'yq -i '\''.applications.grafana.environments.dev.pool = "qa"'\'' site/applications.yaml')"
if [[ "${STATUS}" -ne 0 ]] && grep -q 'applications.grafana.environments.dev.pool' "${OUTPUT_FILE}"; then
  test_pass "validator rejects invalid application pool values"
else
  test_fail "validator rejects invalid application pool values"
fi

test_start "22.10" "enable-app.sh emits pool fields and tag guidance for new apps"
IFS=$'\t' read -r STATUS REPO_DIR OUTPUT_FILE <<< "$(run_enable_app_fixture enable-app-pools)"
if [[ "${STATUS}" -eq 0 ]]; then
  test_pass "enable-app.sh exits 0 for catalog app generation"
else
  test_fail "enable-app.sh exits 0 for catalog app generation"
fi

if [[ "$(yq -r '.applications.grafana.environments.prod.pool' "${REPO_DIR}/site/applications.yaml")" == "prod" ]] && \
   [[ "$(yq -r '.applications.grafana.environments.dev.pool' "${REPO_DIR}/site/applications.yaml")" == "dev" ]]; then
  test_pass "enable-app.sh writes prod/dev pool defaults"
else
  test_fail "enable-app.sh writes prod/dev pool defaults"
fi

if grep -Fq 'tags   = ["pool-${local.app_<name>.environments.<env>.pool}"]' "${OUTPUT_FILE}"; then
  test_pass "enable-app.sh prints the required tags wiring hint"
else
  test_fail "enable-app.sh prints the required tags wiring hint"
fi

runner_summary
