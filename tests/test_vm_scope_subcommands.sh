#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/vm-scope.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PLAN_JSON="${TMP_DIR}/plan.json"
cat > "$PLAN_JSON" <<'JSON'
{
  "resource_changes": [
    {"address":"module.dns_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.vault_prod.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.acme_dev.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.hil_boot.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.gatus.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.gitlab.proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.grafana_dev[0].proxmox_virtual_environment_vm.vm","change":{"actions":["update"]}},
    {"address":"module.grafana_prod.proxmox_virtual_environment_vm.vm","change":{"actions":["no-op"]}}
  ]
}
JSON

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    test_pass "$name"
  else
    test_fail "$name expected [$expected] got [$actual]"
  fi
}

test_start "S1" "control-plane outputs are stable"
assert_eq "control-plane-modules" $'module.gitlab\nmodule.cicd\nmodule.pbs' "$("$SCRIPT" control-plane-modules)"
assert_eq "control-plane-built-roles" $'gitlab\ncicd' "$("$SCRIPT" control-plane-built-roles)"

test_start "S2" "buildable roles exclude vendor pbs"
out="$("$SCRIPT" buildable-roles)"
if grep -Fxq "hil-boot" <<< "$out" && grep -Fxq "grafana" <<< "$out" && ! grep -Fxq "pbs" <<< "$out"; then
  test_pass "buildable roles include built roles/apps and exclude vendor"
else
  test_fail "buildable role set was wrong: $out"
fi

test_start "S3" "target-envs reproduces current target classification"
assert_eq "empty targets" "dev prod" "$("$SCRIPT" target-envs --targets "")"
assert_eq "gitlab is prod env-axis" "prod" "$("$SCRIPT" target-envs --targets "-target=module.gitlab")"
assert_eq "hil_boot is shared/envless" "" "$("$SCRIPT" target-envs --targets "-target=module.hil_boot")"
assert_eq "mixed env targets" "dev prod" "$("$SCRIPT" target-envs --targets "-target=module.vault_dev -target=module.gatus")"

test_start "S4" "target-envs unknown role exits non-zero"
out="$("$SCRIPT" target-envs --targets "-target=module.not_declared" 2>&1)" && rc=0 || rc=$?
if [[ $rc -ne 0 && "$out" == *"not_declared"* ]]; then
  test_pass "unknown target fails loudly"
else
  test_fail "expected unknown target failure; rc=$rc output=$out"
fi

test_start "S5" "scope-impact produces expected impact JSON"
assert_eq "vm=hil_boot impact" "shared_control_plane" "$("$SCRIPT" scope-impact --scope "vm=hil_boot" | jq -r '.impact')"
assert_eq "vm=dns_dev impact" "dev_only" "$("$SCRIPT" scope-impact --scope "vm=dns_dev" | jq -r '.impact')"
assert_eq "vm=gatus impact" "prod_affecting" "$("$SCRIPT" scope-impact --scope "vm=gatus" | jq -r '.impact')"

test_start "S6" "deployable-modules uses manifest taxonomy"
assert_eq "dev deployables" $'module.acme_dev\nmodule.dns_dev\nmodule.grafana_dev\nmodule.hil_boot' "$("$SCRIPT" deployable-modules --env dev --plan-json "$PLAN_JSON")"
assert_eq "prod deployables" $'module.gatus\nmodule.vault_prod' "$("$SCRIPT" deployable-modules --env prod --plan-json "$PLAN_JSON")"

test_start "S7" "backup-kind covers all kind branches"
assert_eq "control-plane nix" "control-plane" "$("$SCRIPT" backup-kind gitlab)"
assert_eq "control-plane vendor" "control-plane" "$("$SCRIPT" backup-kind pbs)"
assert_eq "infrastructure" "infrastructure" "$("$SCRIPT" backup-kind vault_prod)"
assert_eq "application" "application" "$("$SCRIPT" backup-kind grafana_prod)"

runner_summary
