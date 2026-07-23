#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_DIR="${TMP_DIR}/fixture"
SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "${FIXTURE_DIR}/site" "${SHIM_DIR}"

REAL_YQ="$(command -v yq)"

cat > "${FIXTURE_DIR}/site/config.yaml" <<'EOF'
domain: example.test
vms:
  dns1_prod:
    ip: 10.0.0.11
  dns2_prod:
    ip: 10.0.0.12
  vault_prod:
    ip: 10.0.0.21
    backup: true
  gitlab:
    ip: 10.0.0.31
    backup: true
  cicd:
    ip: 10.0.0.32
  pbs:
    ip: 10.0.0.33
  gatus:
    ip: 10.0.0.34
  testapp_prod:
    ip: 10.0.0.41
  acme_dev:
    ip: 10.0.0.99
EOF

cat > "${FIXTURE_DIR}/site/applications.yaml" <<'EOF'
applications:
  influxdb:
    enabled: true
    backup: true
    environments:
      prod:
        ip: 10.0.1.10
        vmid: 601
      dev:
        ip: 10.0.1.11
        vmid: 501
  grafana:
    enabled: true
    backup: false
    environments:
      prod:
        ip: 10.0.1.20
        vmid: 602
  roon:
    enabled: true
    backup: true
    environments:
      prod:
        ip: 10.0.1.30
        vmid: 603
EOF

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

host=""
for arg in "$@"; do
  if [[ "$arg" == root@* ]]; then
    host="${arg#root@}"
  fi
done

case " ${STUB_CERTBOT_IPS:-} " in
  *" ${host} "*) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"
export CERTBOT_CLUSTER_YQ_BIN="${REAL_YQ}"
export CERTBOT_CLUSTER_SSH_BIN="ssh"
export CERTBOT_CLUSTER_CONFIG="${FIXTURE_DIR}/site/config.yaml"
export CERTBOT_CLUSTER_APPS_CONFIG="${FIXTURE_DIR}/site/applications.yaml"

source "${REPO_ROOT}/framework/scripts/certbot-cluster.sh"

export STUB_CERTBOT_IPS="10.0.0.11 10.0.0.12 10.0.0.21 10.0.0.31 10.0.0.34 10.0.0.41 10.0.1.10 10.0.1.20"

collect_labels() {
  local tofu_targets="${1:-}"
  certbot_cluster_staging_override_targets \
    "${CERTBOT_CLUSTER_CONFIG}" \
    "${CERTBOT_CLUSTER_APPS_CONFIG}" \
    "${tofu_targets}" | awk -F '\t' '{print $1}'
}

assert_lines_equal() {
  local actual="$1"
  local expected="$2"
  local label="$3"

  if [[ "${actual}" == "${expected}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label}"
    printf '    expected:\n%s\n' "${expected}" >&2
    printf '    actual:\n%s\n' "${actual}" >&2
  fi
}

test_start "1.1" "full-cluster override excludes backup-backed certbot VMs and keeps stateless prod/shared certbot VMs"
FULL_LABELS="$(collect_labels)"
assert_lines_equal \
  "${FULL_LABELS}" \
  $'dns1_prod\ndns2_prod\ngatus\ntestapp_prod\ngrafana_prod' \
  "full-cluster scope selects only stateless prod/shared certbot VMs"

test_start "1.2" "control-plane scope no longer stages GitLab"
CONTROL_PLANE_LABELS="$(collect_labels " -target=module.gitlab -target=module.cicd -target=module.pbs")"
assert_lines_equal \
  "${CONTROL_PLANE_LABELS}" \
  "" \
  "control-plane scope excludes backup-backed GitLab and non-certbot shared VMs"

test_start "1.3" "dns pair scope still stages both prod DNS VMs"
DNS_LABELS="$(collect_labels " -target=module.dns_prod")"
assert_lines_equal \
  "${DNS_LABELS}" \
  $'dns1_prod\ndns2_prod' \
  "dns_prod scope includes both stateless prod DNS VMs"

test_start "1.4" "single-VM and prod-app scopes still stage stateless targets"
GATUS_LABELS="$(collect_labels " -target=module.gatus")"
GRAFANA_LABELS="$(collect_labels " -target=module.grafana_prod")"
assert_lines_equal "${GATUS_LABELS}" "gatus" "vm=gatus equivalent scope still stages Gatus"
assert_lines_equal "${GRAFANA_LABELS}" "grafana_prod" "enabled stateless prod app stays eligible for staging override"

runner_summary
