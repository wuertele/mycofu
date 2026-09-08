#!/usr/bin/env bash
# Hermetic test for framework/scripts/known-hosts-scope-lib.sh
#
# Covers #349: rebuild-cluster.sh must not invalidate known_hosts entries
# for VMs outside --scope.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

REAL_YQ="$(command -v yq)"

CONFIG_FILE="${TMP_DIR}/config.yaml"
KEYGEN_LOG="${TMP_DIR}/keygen.log"
SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "${SHIM_DIR}"

# ssh-keygen shim: append every "-R <ip>" invocation to KEYGEN_LOG so the
# test can assert which IPs were touched.
cat > "${SHIM_DIR}/ssh-keygen" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-R" ]]; then
  printf '%s\n' "\$2" >> "${KEYGEN_LOG}"
fi
EOF
chmod +x "${SHIM_DIR}/ssh-keygen"

# Fixture mirrors site/config.yaml's .vms keys at the time of writing
# (single-instance, multi-instance, env-suffixed, and digit-bearing role
# bases) so the regex used by vm_key_to_module_name is exercised against
# every shape that ships in production. If the production set drifts and
# this fixture is not updated, the diff will surface in code review.
cat > "${CONFIG_FILE}" <<'EOF'
vms:
  cicd:
    ip: 172.17.77.61
  gitlab:
    ip: 172.17.77.62
  pbs:
    ip: 172.17.77.51
  gatus:
    ip: 172.27.10.62
  vault_prod:
    ip: 172.27.10.51
  vault_dev:
    ip: 172.27.60.51
  acme_dev:
    ip: 172.27.60.52
  testapp_prod:
    ip: 172.27.10.99
  testapp_dev:
    ip: 172.27.60.99
  dns1_prod:
    ip: 172.27.10.50
  dns2_prod:
    ip: 172.27.10.49
  dns1_dev:
    ip: 172.27.60.50
  dns2_dev:
    ip: 172.27.60.49
EOF

export CONFIG="${CONFIG_FILE}"
export YQ_BIN="${REAL_YQ}"
export SSH_KEYGEN_BIN="${SHIM_DIR}/ssh-keygen"

# shellcheck source=../framework/scripts/known-hosts-scope-lib.sh
source "${REPO_ROOT}/framework/scripts/known-hosts-scope-lib.sh"

reset_log() {
  : > "${KEYGEN_LOG}"
}

logged_ips_sorted() {
  if [[ -s "${KEYGEN_LOG}" ]]; then
    sort -u "${KEYGEN_LOG}"
  fi
}

assert_logged_set() {
  local case_id="$1" desc="$2"
  shift 2
  local expected_sorted actual_sorted
  expected_sorted="$(printf '%s\n' "$@" | sort -u)"
  actual_sorted="$(logged_ips_sorted)"
  if [[ "$expected_sorted" == "$actual_sorted" ]]; then
    test_pass "${case_id}: ${desc}"
  else
    test_fail "${case_id}: ${desc}"
    echo "    expected (sorted):"
    printf '      %s\n' "$expected_sorted" | sed 's/^      $/      <empty>/'
    echo "    actual (sorted):"
    printf '      %s\n' "$actual_sorted" | sed 's/^      $/      <empty>/'
  fi
}

# --- vm_key_to_module_name -------------------------------------------------

test_start "TC1" "vm_key_to_module_name covers all VM-key shapes"

assert_eq() {
  local case_id="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    test_pass "${case_id} → ${actual}"
  else
    test_fail "${case_id} expected '${expected}' got '${actual}'"
  fi
}

assert_eq "TC1a single-instance no env"     "cicd"          "$(vm_key_to_module_name cicd)"
assert_eq "TC1b single-instance no env"     "gitlab"        "$(vm_key_to_module_name gitlab)"
assert_eq "TC1c single-instance with env"   "vault_prod"    "$(vm_key_to_module_name vault_prod)"
assert_eq "TC1d single-instance with env"   "vault_dev"     "$(vm_key_to_module_name vault_dev)"
assert_eq "TC1e single-instance with env"   "acme_dev"      "$(vm_key_to_module_name acme_dev)"
assert_eq "TC1f multi-instance with env"    "dns_prod"      "$(vm_key_to_module_name dns1_prod)"
assert_eq "TC1g multi-instance with env"    "dns_prod"      "$(vm_key_to_module_name dns2_prod)"
assert_eq "TC1h multi-instance with env"    "dns_dev"       "$(vm_key_to_module_name dns1_dev)"
assert_eq "TC1i multi-instance with env"    "dns_dev"       "$(vm_key_to_module_name dns2_dev)"

# --- refresh_known_hosts_for_scope: full rebuild (empty scope) --------------

test_start "TC2" "Empty TOFU_TARGETS removes all VM entries (full-rebuild behavior)"

reset_log
TOFU_TARGETS="" refresh_known_hosts_for_scope

assert_logged_set "TC2" "every IP touched" \
  172.17.77.61 172.17.77.62 172.17.77.51 172.27.10.62 \
  172.27.10.51 172.27.60.51 172.27.60.52 \
  172.27.10.99 172.27.60.99 \
  172.27.10.50 172.27.10.49 172.27.60.50 172.27.60.49

# --- refresh_known_hosts_for_scope: single-VM scope -------------------------

test_start "TC3" "Scope of just cicd touches only cicd's IP"

reset_log
TOFU_TARGETS="-target=module.cicd" refresh_known_hosts_for_scope

assert_logged_set "TC3" "only cicd's IP touched" 172.17.77.61

# --- refresh_known_hosts_for_scope: multi-VM scope (dns_prod has 2 VMs) ----

test_start "TC4" "Scope of dns_prod touches both dns1_prod and dns2_prod"

reset_log
TOFU_TARGETS="-target=module.dns_prod" refresh_known_hosts_for_scope

assert_logged_set "TC4" "both dns_prod VM IPs touched" \
  172.27.10.50 172.27.10.49

# --- refresh_known_hosts_for_scope: multi-target scope ----------------------

test_start "TC5" "Scope with two modules touches only those modules' VMs"

reset_log
TOFU_TARGETS="-target=module.cicd -target=module.gatus" refresh_known_hosts_for_scope

assert_logged_set "TC5" "cicd + gatus IPs touched, others untouched" \
  172.17.77.61 172.27.10.62

# --- refresh_known_hosts_for_scope: no prefix-collision false positives -----
#
# A scope of `module.vault` must NOT match vms.vault_prod or vms.vault_dev
# (their modules are `module.vault_prod` and `module.vault_dev`).
# Conversely, scope of `module.vault_prod` must match only vault_prod.

test_start "TC6" "Module name match is exact, not prefix"

reset_log
TOFU_TARGETS="-target=module.vault" refresh_known_hosts_for_scope
assert_logged_set "TC6a" "module.vault matches no VM" ""

reset_log
TOFU_TARGETS="-target=module.vault_prod" refresh_known_hosts_for_scope
assert_logged_set "TC6b" "module.vault_prod matches only vault_prod" \
  172.27.10.51

# --- refresh_known_hosts_for_scope: regression for #349 ---------------------
#
# Models the failure pattern from 2026-05-16: a sequence of scoped rebuilds
# (`--scope vm=cicd`, then `--scope vm=dns_prod,...,dns_dev`) must touch
# only the IPs of VMs whose module appears in scope across the union of
# both runs. Specifically, gatus's IP must NEVER be touched by either run
# — that was the regression that surfaced as validate-github-mirror.sh's
# "Host key verification failed".
#
# Note: application VMs (roon_prod etc.) are not in `.vms.` of config.yaml
# and so are out of scope for this lib regardless; see follow-up issue.

test_start "TC7" "#349 regression: scoped runs touch only in-scope IPs, gatus stays untouched"

reset_log
TOFU_TARGETS="-target=module.cicd" refresh_known_hosts_for_scope
TOFU_TARGETS="-target=module.dns_prod -target=module.dns_dev" refresh_known_hosts_for_scope

assert_logged_set "TC7" "union of cicd + dns_prod + dns_dev IPs touched, gatus and others untouched" \
  172.17.77.61 \
  172.27.10.50 172.27.10.49 \
  172.27.60.50 172.27.60.49

runner_summary
