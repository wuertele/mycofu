#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SCRIPT="${REPO_ROOT}/framework/scripts/vm-scope.sh"

mkdir -p "${TMP_DIR}/framework" "${TMP_DIR}/site"
cat > "${TMP_DIR}/framework/images.yaml" <<'EOF'
roles:
  dns:
    category: nix
    host_config: site/nix/hosts/dns.nix
    scope: env-bound
EOF
cat > "${TMP_DIR}/site/images.yaml" <<'EOF'
roles: {}
EOF
cat > "${TMP_DIR}/site/applications.yaml" <<'EOF'
applications:
  enabled_app:
    enabled: true
  disabled_app:
    enabled: false
EOF

run_vm_scope() {
  VM_SCOPE_FRAMEWORK_MANIFEST="${TMP_DIR}/framework/images.yaml" \
  VM_SCOPE_SITE_MANIFEST="${TMP_DIR}/site/images.yaml" \
  VM_SCOPE_APPS_CONFIG="${TMP_DIR}/site/applications.yaml" \
    "$SCRIPT" "$@" 2>&1
}

test_start "A1" "enabled apps derive env-bound scope"
out="$(run_vm_scope classes --format json)"
if jq -e '.enabled_app.scope == "env-bound" and .enabled_app.source == "applications" and (has("disabled_app") | not)' <<< "$out" >/dev/null; then
  test_pass "enabled app appears as derived env-bound class; disabled app is absent"
else
  test_fail "app derivation output was wrong: $out"
fi

test_start "A2" "app duplicate with image manifest fails closed"
yq -i '.roles.enabled_app = {"category":"nix","host_config":"site/nix/hosts/enabled_app.nix","scope":"env-bound"}' "${TMP_DIR}/site/images.yaml"
out="$(run_vm_scope validate)" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$out" == *"duplicate normalized role name 'enabled_app'"* ]]; then
  test_pass "app/image duplicate fails"
else
  test_fail "expected app duplicate failure; rc=$rc output=$out"
fi

runner_summary
