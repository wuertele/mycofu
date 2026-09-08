#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SCRIPT="${REPO_ROOT}/framework/scripts/vm-scope.sh"

write_base_manifests() {
  local dir="$1"
  mkdir -p "${dir}/framework" "${dir}/site"
  cat > "${dir}/framework/images.yaml" <<'EOF'
roles:
  dns:
    category: nix
    host_config: site/nix/hosts/dns.nix
    flake_output: dns-image
    scope: env-bound
    control_plane: false
  gitlab:
    category: nix
    host_config: site/nix/hosts/gitlab.nix
    flake_output: gitlab-image
    scope: prod-only
    control_plane: true
non_built_roles:
  pbs:
    category: vendor
    scope: shared
    control_plane: true
EOF
  cat > "${dir}/site/images.yaml" <<'EOF'
roles:
  hil-boot:
    category: nix
    host_config: site/nix/hosts/hil-boot.nix
    flake_output: hil-boot-image
    scope: shared
    control_plane: false
EOF
  cat > "${dir}/site/applications.yaml" <<'EOF'
applications:
  grafana:
    enabled: true
  disabled_app:
    enabled: false
EOF
}

run_vm_scope() {
  local dir="$1"
  shift
  VM_SCOPE_FRAMEWORK_MANIFEST="${dir}/framework/images.yaml" \
  VM_SCOPE_SITE_MANIFEST="${dir}/site/images.yaml" \
  VM_SCOPE_APPS_CONFIG="${dir}/site/applications.yaml" \
    "${SCRIPT}" "$@" 2>&1
}

test_start "L1" "loader merges manifests, non-built roles, and enabled apps"
fixture="${TMP_DIR}/l1"
write_base_manifests "$fixture"
out="$(run_vm_scope "$fixture" classes --format json)"
if jq -e '.dns.scope == "env-bound" and .hil_boot.role == "hil-boot" and .pbs.category == "vendor" and .grafana.source == "applications" and (has("disabled_app") | not)' <<< "$out" >/dev/null; then
  test_pass "merged JSON shape uses module-form keys and excludes disabled apps"
else
  test_fail "merged JSON shape was not as expected: $out"
fi

test_start "L2" "missing scope fails closed with role name"
fixture="${TMP_DIR}/l2"
write_base_manifests "$fixture"
yq -i 'del(.roles.dns.scope)' "${fixture}/framework/images.yaml"
out="$(run_vm_scope "$fixture" validate)" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$out" == *"roles.dns missing required scope"* ]]; then
  test_pass "missing scope fails with named role"
else
  test_fail "expected missing scope failure; rc=$rc output=$out"
fi

test_start "L3" "missing yq fails closed"
fixture="${TMP_DIR}/l3"
write_base_manifests "$fixture"
# Unset both the current script-scoped name and the legacy YQ_BIN so an
# operator with either variable exported cannot false-pass this
# fails-closed assertion (#444). env -u strips them from the child env
# even when they are set + exported in the caller.
out="$(env -u VM_SCOPE_YQ_BIN -u YQ_BIN PATH="/nonexistent" VM_SCOPE_FRAMEWORK_MANIFEST="${fixture}/framework/images.yaml" VM_SCOPE_SITE_MANIFEST="${fixture}/site/images.yaml" VM_SCOPE_APPS_CONFIG="${fixture}/site/applications.yaml" "${BASH}" "$SCRIPT" validate 2>&1)" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$out" == *"yq not found"* ]]; then
  test_pass "missing yq is a hard failure"
else
  test_fail "expected missing yq failure; rc=$rc output=$out"
fi

test_start "L3b" "VM_SCOPE_YQ_BIN override beats PATH shim (#443)"
fixture="${TMP_DIR}/l3b"
write_base_manifests "$fixture"
# Place a fake yq early on PATH that would return wrong data if consulted.
# Set VM_SCOPE_YQ_BIN to the real yq. The loader must use the override
# and produce the actual manifest content.
shim_dir="${TMP_DIR}/l3b_shim"
mkdir -p "$shim_dir"
cat > "${shim_dir}/yq" <<'YQ_EOF'
#!/usr/bin/env bash
# Fake yq: prints wrong JSON for any invocation so a false pass is impossible.
echo '{"roles":{"WRONG_ROLE":{"category":"nix","scope":"env-bound"}}}'
YQ_EOF
chmod +x "${shim_dir}/yq"
real_yq="$(command -v yq)"
if [[ -z "$real_yq" || ! -x "$real_yq" ]]; then
  test_fail "cannot resolve a real yq to point VM_SCOPE_YQ_BIN at"
else
  out="$(PATH="${shim_dir}:${PATH}" VM_SCOPE_YQ_BIN="$real_yq" \
    VM_SCOPE_FRAMEWORK_MANIFEST="${fixture}/framework/images.yaml" \
    VM_SCOPE_SITE_MANIFEST="${fixture}/site/images.yaml" \
    VM_SCOPE_APPS_CONFIG="${fixture}/site/applications.yaml" \
    "${SCRIPT}" classes --format json 2>&1)" && rc=0 || rc=$?
  # If the override worked, we see the real manifest keys (dns, gitlab,
  # hil_boot, pbs, grafana). If the shim leaked through, we see WRONG_ROLE.
  if [[ $rc -eq 0 ]] \
      && jq -e '.dns.scope == "env-bound" and .hil_boot.role == "hil-boot" and (has("WRONG_ROLE") | not)' <<< "$out" >/dev/null; then
    test_pass "VM_SCOPE_YQ_BIN override wins over PATH shim"
  else
    test_fail "expected real manifest content via VM_SCOPE_YQ_BIN override; rc=$rc output=$out"
  fi
fi

test_start "L4" "malformed YAML fails closed"
fixture="${TMP_DIR}/l4"
write_base_manifests "$fixture"
printf 'roles:\n  broken: [\n' > "${fixture}/site/images.yaml"
out="$(run_vm_scope "$fixture" validate)" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$out" == *"malformed YAML"* ]]; then
  test_pass "malformed YAML fails"
else
  test_fail "expected malformed YAML failure; rc=$rc output=$out"
fi

test_start "L5" "duplicate normalized names fail closed"
fixture="${TMP_DIR}/l5"
write_base_manifests "$fixture"
yq -i '.roles.hil_boot = .roles."hil-boot"' "${fixture}/site/images.yaml"
out="$(run_vm_scope "$fixture" validate)" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$out" == *"duplicate normalized role name 'hil_boot'"* ]]; then
  test_pass "hyphen/underscore collision fails"
else
  test_fail "expected normalized duplicate failure; rc=$rc output=$out"
fi

test_start "L6" "cross-manifest duplicate fails closed"
fixture="${TMP_DIR}/l6"
write_base_manifests "$fixture"
yq -i '.roles.dns = {"category":"nix","host_config":"site/nix/hosts/dns.nix","scope":"env-bound"}' "${fixture}/site/images.yaml"
out="$(run_vm_scope "$fixture" validate)" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$out" == *"duplicate normalized role name 'dns'"* ]]; then
  test_pass "cross-manifest duplicate fails"
else
  test_fail "expected cross-manifest duplicate failure; rc=$rc output=$out"
fi

test_start "L7" "vendor with build fields fails closed"
fixture="${TMP_DIR}/l7"
write_base_manifests "$fixture"
yq -i '.non_built_roles.pbs.host_config = "site/nix/hosts/pbs.nix"' "${fixture}/framework/images.yaml"
out="$(run_vm_scope "$fixture" validate)" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$out" == *"vendor role has build field"* ]]; then
  test_pass "vendor build fields fail"
else
  test_fail "expected vendor build-field failure; rc=$rc output=$out"
fi

test_start "L8" "role in roles and non_built_roles fails closed"
fixture="${TMP_DIR}/l8"
write_base_manifests "$fixture"
yq -i '.non_built_roles.dns = {"category":"vendor","scope":"shared"}' "${fixture}/framework/images.yaml"
out="$(run_vm_scope "$fixture" validate)" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$out" == *"duplicate normalized role name 'dns'"* ]]; then
  test_pass "role/non-built collision fails"
else
  test_fail "expected role/non-built collision failure; rc=$rc output=$out"
fi

runner_summary
