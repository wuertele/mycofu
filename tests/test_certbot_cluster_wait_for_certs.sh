#!/usr/bin/env bash
# tests/test_certbot_cluster_wait_for_certs.sh — Test the certbot-cluster wait logic.

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

# Mock config.yaml
cat > "${FIXTURE_DIR}/site/config.yaml" <<'EOF'
domain: example.test
vms:
  vault_dev:
    ip: 10.0.0.33
  dns1_dev:
    ip: 10.0.0.30
  other_vm:
    ip: 10.0.0.100
EOF

cat > "${FIXTURE_DIR}/site/applications.yaml" <<'EOF'
applications:
  myapp:
    enabled: true
    environments:
      dev:
        ip: 10.0.0.200
EOF

# Mock ssh
cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
# Simulate reachability
if [[ "$*" == *"true"* ]]; then exit 0; fi
# Simulate certbot-initial presence
if [[ "$*" == *"systemctl cat certbot-initial.service"* ]]; then
  if [[ "$*" == *"10.0.0.33"* || "$*" == *"10.0.0.30"* || "$*" == *"10.0.0.200"* ]]; then exit 0; else exit 1; fi
fi
# Simulate cert presence
if [[ "$*" == *"[[ -s /etc/letsencrypt/live/vault.dev.example.test/fullchain.pem ]]"* ]]; then
  # On first call, pretend it's missing, then OK
  if [[ -f "/tmp/vault_ready" ]]; then exit 0; else touch "/tmp/vault_ready"; exit 1; fi
fi
if [[ "$*" == *"[[ -s /etc/letsencrypt/live/dns1.dev.example.test/fullchain.pem ]]"* ]]; then
  exit 0
fi
if [[ "$*" == *"[[ -s /etc/letsencrypt/live/myapp.dev.example.test/fullchain.pem ]]"* ]]; then
  exit 0
fi
exit 98
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"
export CERTBOT_CLUSTER_YQ_BIN="${REAL_YQ}"
export CERTBOT_CLUSTER_SSH_BIN="ssh"
export CERTBOT_CLUSTER_CONFIG="${FIXTURE_DIR}/site/config.yaml"
export CERTBOT_CLUSTER_APPS_CONFIG="${FIXTURE_DIR}/site/applications.yaml"

# Source the script under test
source "${REPO_ROOT}/framework/scripts/certbot-cluster.sh"

# Helper for capturing output and status
run_capture() {
  set +e
  OUTPUT="$("$@" 2>&1)"
  STATUS=$?
  set -e
}

# Override timeout and sleep for faster test
sed -i '' 's/timeout=900/timeout=30/' "${REPO_ROOT}/framework/scripts/certbot-cluster.sh"
sed -i '' 's/sleep 10/sleep 0/' "${REPO_ROOT}/framework/scripts/certbot-cluster.sh"
trap "sed -i '' 's/timeout=30/timeout=900/' '${REPO_ROOT}/framework/scripts/certbot-cluster.sh'; sed -i '' 's/sleep 0/sleep 10/' '${REPO_ROOT}/framework/scripts/certbot-cluster.sh'; rm -f /tmp/vault_ready; rm -rf ${TMP_DIR}" EXIT

test_start "WAIT" "certbot_cluster_wait_for_certs waits for all certs in dev environment"
rm -f /tmp/vault_ready
run_capture certbot_cluster_wait_for_certs dev
if [[ "${STATUS}" -eq 0 ]] && grep -q "All certificates present" <<< "${OUTPUT}"; then
  test_pass "wait-for-certs dev success"
else
  test_fail "wait-for-certs dev failure"
  echo "Output: ${OUTPUT}"
fi

runner_summary
