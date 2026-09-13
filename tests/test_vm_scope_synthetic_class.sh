#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/vm-scope.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${TMP_DIR}/framework" "${TMP_DIR}/site"

cat > "${TMP_DIR}/framework/images.yaml" <<'EOF'
roles:
  vault:
    category: nix
    host_config: site/nix/hosts/vault.nix
    scope: env-bound
    control_plane: false
non_built_roles:
  synthappliance:
    category: vendor
    scope: shared
    control_plane: true
EOF

cat > "${TMP_DIR}/site/images.yaml" <<'EOF'
roles:
  synthrole:
    category: nix
    host_config: site/nix/hosts/synthrole.nix
    scope: shared
    control_plane: true
EOF

cat > "${TMP_DIR}/site/applications.yaml" <<'EOF'
applications:
  synthapp:
    enabled: true
    environments:
      dev: { vmid: 510 }
      prod: { vmid: 610 }
EOF

cat > "${TMP_DIR}/plan.json" <<'EOF'
{
  "resource_changes": [
    {"address":"module.synthrole.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.synthapp_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.synthapp_prod.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.vault_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}}
  ]
}
EOF

run_scope() {
  VM_SCOPE_FRAMEWORK_MANIFEST="${TMP_DIR}/framework/images.yaml" \
  VM_SCOPE_SITE_MANIFEST="${TMP_DIR}/site/images.yaml" \
  VM_SCOPE_APPS_CONFIG="${TMP_DIR}/site/applications.yaml" \
    "$SCRIPT" "$@"
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    test_pass "$name"
  else
    test_fail "$name expected [$expected] got [$actual]"
  fi
}

test_start "SYN1" "synthetic manifest classes appear in resolved taxonomy"
classes="$(run_scope classes --format json)"
if jq -e '
  .synthrole.scope == "shared"
  and .synthrole.control_plane == true
  and .synthrole.category == "nix"
  and .synthappliance.scope == "shared"
  and .synthappliance.control_plane == true
  and .synthappliance.category == "vendor"
  and .synthappliance.block == "non_built_roles"
  and .synthapp.scope == "env-bound"
  and .synthapp.control_plane == false
  and .synthapp.source == "applications"
' <<< "$classes" >/dev/null; then
  test_pass "synthetic role, vendor appliance, and enabled app are present with derived taxonomy"
else
  test_fail "synthetic role/vendor/app taxonomy was not resolved correctly"
  printf '%s\n' "$classes" >&2
fi

test_start "SYN2" "target-envs accepts synthetic classes without script edits"
assert_eq "shared control-plane role has no env-specific convergence" "" \
  "$(run_scope target-envs --targets "-target=module.synthrole")"
assert_eq "synthetic app dev target maps to dev" "dev" \
  "$(run_scope target-envs --targets "-target=module.synthapp_dev")"
assert_eq "synthetic app prod plus infra dev preserves target env order" "prod dev" \
  "$(run_scope target-envs --targets "-target=module.synthapp_prod -target=module.vault_dev")"

test_start "SYN3" "scope-impact derives synthetic class impact"
assert_eq "synthetic control-plane role is shared_control_plane" "shared_control_plane" \
  "$(run_scope scope-impact --scope "vm=synthrole" | jq -r '.impact')"
assert_eq "synthetic app dev target is dev_only" "dev_only" \
  "$(run_scope scope-impact --scope "vm=synthapp_dev" | jq -r '.impact')"

test_start "SYN4" "deployable-modules uses synthetic taxonomy"
assert_eq "dev deployables exclude synthetic control-plane role" $'module.synthapp_dev\nmodule.vault_dev' \
  "$(run_scope deployable-modules --env dev --plan-json "${TMP_DIR}/plan.json")"
assert_eq "prod deployables include synthetic prod app only" "module.synthapp_prod" \
  "$(run_scope deployable-modules --env prod --plan-json "${TMP_DIR}/plan.json")"

test_start "SYN5" "control-plane and backup derivations include synthetic role"
assert_eq "control-plane module set includes vendor appliance" $'module.synthappliance\nmodule.synthrole' \
  "$(run_scope control-plane-modules)"
assert_eq "control-plane built role set" "synthrole" \
  "$(run_scope control-plane-built-roles)"
assert_eq "synthetic role backup kind" "control-plane" \
  "$(run_scope backup-kind synthrole)"
assert_eq "synthetic vendor appliance backup kind" "control-plane" \
  "$(run_scope backup-kind synthappliance)"
assert_eq "synthetic app backup kind" "application" \
  "$(run_scope backup-kind synthapp_prod)"

test_start "SYN6" "undeclared synthetic target fails closed"
out="$(run_scope target-envs --targets "-target=module.not_declared" 2>&1)" && rc=0 || rc=$?
if [[ "$rc" -ne 0 && "$out" == *"not_declared"* ]]; then
  test_pass "undeclared synthetic target fails loudly"
else
  test_fail "undeclared target should fail loudly; rc=$rc output=$out"
fi

runner_summary
