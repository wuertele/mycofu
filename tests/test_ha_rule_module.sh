#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

PROXMOX_VM_HA="${REPO_ROOT}/framework/tofu/modules/proxmox-vm/ha.tf"
PROXMOX_VM_VARS="${REPO_ROOT}/framework/tofu/modules/proxmox-vm/variables.tf"
DNS_PAIR_MAIN="${REPO_ROOT}/framework/tofu/modules/dns-pair/main.tf"

has_line() {
  local file="$1"
  local needle="$2"
  grep -Fq "$needle" "$file"
}

# Ratchet (Sprint 045 / #513, M1 ruling 2026-07-08): node-affinity harules are
# DROPPED and must NOT be reintroduced. M1 proved PVE 9.1.1 honors node-affinity
# by actively auto-migrating a running service to its preferred node — a
# migrate-BACK executed OUTSIDE rebalance-cluster.sh, i.e. the exact rename-victim
# minting event on the path the Phase-3 vaccine does not guard. Home placement is
# owned by config.yaml + rebalance-cluster.sh, not by an HA node-affinity rule.
test_start "s045.2.1" "no node-affinity harule (dropped; would reopen the rename-victim hole)"
if grep -q 'type *= *"node-affinity"' "$PROXMOX_VM_HA" ||
   has_line "$PROXMOX_VM_HA" 'resource "proxmox_virtual_environment_harule" "node_affinity"'; then
  test_fail "a node-affinity harule was reintroduced in proxmox-vm/ha.tf"
else
  test_pass "no node-affinity harule in proxmox-vm/ha.tf"
fi

test_start "s045.2.2" "no ha_node_priorities variable (dropped with node-affinity)"
if has_line "$PROXMOX_VM_VARS" 'variable "ha_node_priorities"'; then
  test_fail "ha_node_priorities variable was reintroduced"
else
  test_pass "ha_node_priorities variable is absent"
fi

test_start "s045.2.3" "dns-pair module declares negative resource-affinity harule"
if has_line "$DNS_PAIR_MAIN" 'resource "proxmox_virtual_environment_harule" "dns_antiaffinity"' &&
   has_line "$DNS_PAIR_MAIN" 'type      = "resource-affinity"' &&
   has_line "$DNS_PAIR_MAIN" 'affinity  = "negative"' &&
   has_line "$DNS_PAIR_MAIN" 'strict    = false' &&
   has_line "$DNS_PAIR_MAIN" 'resources = ["vm:${var.dns1_vm_id}", "vm:${var.dns2_vm_id}"]' &&
   has_line "$DNS_PAIR_MAIN" 'count = var.register_ha ? 1 : 0'; then
  test_pass "dns anti-affinity harule has the expected type, affinity, resources, and count gate"
else
  test_fail "dns anti-affinity harule resource is missing or has an unexpected shape"
fi

test_start "s045.2.4" "legacy hagroup resource is absent"
if grep -R --exclude-dir=.terraform "proxmox_virtual_environment_hagroup" "${REPO_ROOT}/framework/tofu" >/dev/null 2>&1; then
  test_fail "legacy proxmox_virtual_environment_hagroup still appears under framework/tofu"
else
  test_pass "no legacy proxmox_virtual_environment_hagroup resource remains under framework/tofu"
fi

test_start "s045.2.5" "harule resources validate against the real provider schema"
PROVIDER_MIRROR="${REPO_ROOT}/framework/tofu/root/.terraform/providers"
if ! command -v tofu >/dev/null 2>&1; then
  test_skip "tofu is not installed in this sandbox"
elif [[ ! -d "${PROVIDER_MIRROR}" ]]; then
  # The live schema check is a best-effort bonus: it runs on a workstation (or any
  # job) where the provider has been fetched into framework/tofu/root/.terraform,
  # and skips on a fresh CI checkout that has no provider cache. The structural
  # greps above (s045.2.1-2.4) are the CI-enforced assertions on the harule shape.
  test_skip "provider cache absent (${PROVIDER_MIRROR}); run 'tofu init' in framework/tofu/root to enable the live schema check"
else
  SCRATCH="$(mktemp -d)"
  trap 'rm -rf "${SCRATCH}"' EXIT

  cat > "${SCRATCH}/.tofurc" <<EOF
provider_installation {
  filesystem_mirror {
    path = "${PROVIDER_MIRROR}"
  }
}
EOF

  cat > "${SCRATCH}/versions.tf" <<'EOF'
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.101.1"
    }
  }
}
EOF

  cat > "${SCRATCH}/main.tf" <<'EOF'
provider "proxmox" {
  endpoint = "https://127.0.0.1:8006/api2/json"
  insecure = true
  username = "root@pam"
  password = "dummy"
}

resource "proxmox_virtual_environment_harule" "dns_antiaffinity" {
  rule      = "dns-dev-antiaffinity"
  type      = "resource-affinity"
  affinity  = "negative"
  resources = ["vm:301", "vm:302"]
  strict    = false
  comment   = "schema validation"
}
EOF

  set +e
  init_output="$(cd "${SCRATCH}" && TF_LOG=ERROR TF_CLI_CONFIG_FILE="${SCRATCH}/.tofurc" tofu init -backend=false -input=false 2>&1)"
  init_rc=$?
  validate_output=""
  validate_rc=99
  if [[ "$init_rc" -eq 0 ]]; then
    validate_output="$(cd "${SCRATCH}" && TF_LOG=ERROR TF_CLI_CONFIG_FILE="${SCRATCH}/.tofurc" tofu validate 2>&1)"
    validate_rc=$?
  fi
  set -e

  if [[ "$init_rc" -eq 0 && "$validate_rc" -eq 0 ]]; then
    test_pass "standalone harule resources validate against bpg/proxmox 0.101.1"
  elif [[ "$validate_output" == *"bind: operation not permitted"* ]]; then
    test_skip "provider plugin cannot bind its schema handshake socket in this sandbox"
  elif [[ "$init_output" == *"Failed to resolve provider"* \
       || "$init_output" == *"Could not resolve provider"* \
       || "$init_output" == *"no such file or directory"* ]]; then
    test_skip "provider package unavailable in this environment; skipping live schema validation"
  else
    test_fail "standalone harule resources failed provider validation"
    printf '    tofu init rc=%s\n%s\n' "$init_rc" "$init_output" >&2
    printf '    tofu validate rc=%s\n%s\n' "$validate_rc" "$validate_output" >&2
  fi
fi

runner_summary
