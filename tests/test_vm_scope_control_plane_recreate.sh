#!/usr/bin/env bash
# test_vm_scope_control_plane_recreate.sh — hermetic coverage for the
# converge-vs-recreate classifier that backs the tofu-wrapper.sh G7 safety
# fence (control-plane convergence safety).
#
# Contract under test (vm-scope.sh control-plane-recreate --plan-json):
#   0 — no control-plane VM recreate in the plan (safe to apply)
#   3 — at least one control-plane VM would be replaced/destroyed (offenders
#       printed as "<action>\t<address>")
#   1 — plan could not be inspected (missing/garbage/not-a-plan) -> fail closed
#
# Runs against the real repo manifests so the control-plane set (gitlab,
# cicd, pbs) is the shipped taxonomy, never a hardcoded fixture list.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/vm-scope.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Run the classifier, capture stdout+stderr and exit code.
run_classify() {
  local plan="$1"
  set +e
  CLASSIFY_OUT="$("$SCRIPT" control-plane-recreate --plan-json "$plan" 2>&1)"
  CLASSIFY_RC=$?
  set -e
}

write_plan() {
  cat > "${TMP_DIR}/$1"
}

# --- Case 1: control-plane VM replace (delete+create) -> FAIL (rc 3) ---
write_plan cp-replace.json <<'JSON'
{"resource_changes":[
 {"address":"module.gitlab.module.gitlab.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["delete","create"]}}
]}
JSON
test_start "1" "control-plane VM replace fails closed (rc 3)"
run_classify "${TMP_DIR}/cp-replace.json"
if [[ "$CLASSIFY_RC" -eq 3 ]] && grep -q $'replace\tmodule.gitlab' <<< "$CLASSIFY_OUT"; then
  test_pass "gitlab replace detected"
else
  test_fail "expected rc 3 + gitlab offender, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 2: control-plane VM in-place update -> PASS (rc 0) ---
write_plan cp-update.json <<'JSON'
{"resource_changes":[
 {"address":"module.cicd.module.cicd.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["update"]}}
]}
JSON
test_start "2" "control-plane VM update proceeds (rc 0)"
run_classify "${TMP_DIR}/cp-update.json"
if [[ "$CLASSIFY_RC" -eq 0 && -z "$CLASSIFY_OUT" ]]; then
  test_pass "cicd in-place update allowed"
else
  test_fail "expected rc 0 empty, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 3: control-plane VM create-before-destroy order -> FAIL (rc 3) ---
write_plan cp-cbd.json <<'JSON'
{"resource_changes":[
 {"address":"module.cicd.module.cicd.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["create","delete"]}}
]}
JSON
test_start "3" "create-before-destroy replace fails closed (rc 3)"
run_classify "${TMP_DIR}/cp-cbd.json"
if [[ "$CLASSIFY_RC" -eq 3 ]] && grep -q $'replace\tmodule.cicd' <<< "$CLASSIFY_OUT"; then
  test_pass "cicd create+delete detected as replace"
else
  test_fail "expected rc 3 + cicd offender, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 4: control-plane VM bare destroy -> FAIL (rc 3) ---
write_plan cp-delete.json <<'JSON'
{"resource_changes":[
 {"address":"module.pbs.module.pbs.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["delete"]}}
]}
JSON
test_start "4" "control-plane VM bare delete fails closed (rc 3)"
run_classify "${TMP_DIR}/cp-delete.json"
if [[ "$CLASSIFY_RC" -eq 3 ]] && grep -q $'delete\tmodule.pbs' <<< "$CLASSIFY_OUT"; then
  test_pass "pbs destroy detected"
else
  test_fail "expected rc 3 + pbs offender, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 5: data-plane VM replace -> PASS (rc 0, unaffected) ---
write_plan dp-replace.json <<'JSON'
{"resource_changes":[
 {"address":"module.dns_dev.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["delete","create"]}},
 {"address":"module.vault_prod.module.vault_prod.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["create","delete"]}}
]}
JSON
test_start "5" "data-plane VM replace is unaffected (rc 0)"
run_classify "${TMP_DIR}/dp-replace.json"
if [[ "$CLASSIFY_RC" -eq 0 && -z "$CLASSIFY_OUT" ]]; then
  test_pass "data-plane recreation not fenced"
else
  test_fail "expected rc 0 empty, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 6: control-plane CHILD resource replace (not the VM) -> PASS ---
# A replace of a cloud-init file / HA rule under a control-plane module is
# in-place convergence, not a VM destroy. Only the VM resource counts.
write_plan cp-child.json <<'JSON'
{"resource_changes":[
 {"address":"module.gitlab.module.gitlab.proxmox_virtual_environment_file.cidata",
  "type":"proxmox_virtual_environment_file","change":{"actions":["delete","create"]}}
]}
JSON
test_start "6" "control-plane child-resource replace proceeds (rc 0)"
run_classify "${TMP_DIR}/cp-child.json"
if [[ "$CLASSIFY_RC" -eq 0 && -z "$CLASSIFY_OUT" ]]; then
  test_pass "non-VM child replace not fenced"
else
  test_fail "expected rc 0 empty, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 7: mixed plan (cp replace + dp update) -> FAIL (rc 3) ---
write_plan mixed.json <<'JSON'
{"resource_changes":[
 {"address":"module.dns_dev.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["update"]}},
 {"address":"module.gitlab.module.gitlab.proxmox_virtual_environment_vm.vm",
  "type":"proxmox_virtual_environment_vm","change":{"actions":["delete","create"]}}
]}
JSON
test_start "7" "mixed plan with a control-plane replace fails closed (rc 3)"
run_classify "${TMP_DIR}/mixed.json"
if [[ "$CLASSIFY_RC" -eq 3 ]] && grep -q $'replace\tmodule.gitlab' <<< "$CLASSIFY_OUT"; then
  test_pass "control-plane replace detected amid data-plane changes"
else
  test_fail "expected rc 3 + gitlab offender, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 8: valid plan, no changes -> PASS (rc 0) ---
write_plan nochanges.json <<'JSON'
{"resource_changes":[]}
JSON
test_start "8" "empty resource_changes proceeds (rc 0)"
run_classify "${TMP_DIR}/nochanges.json"
if [[ "$CLASSIFY_RC" -eq 0 && -z "$CLASSIFY_OUT" ]]; then
  test_pass "no-op plan allowed"
else
  test_fail "expected rc 0 empty, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 9: garbage document (no resource_changes) -> FAIL CLOSED (rc 1) ---
write_plan garbage.json <<'JSON'
{}
JSON
test_start "9" "garbage/empty document fails closed (rc 1)"
run_classify "${TMP_DIR}/garbage.json"
if [[ "$CLASSIFY_RC" -eq 1 ]]; then
  test_pass "not-a-plan document fails closed"
else
  test_fail "expected rc 1, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 10: zero-byte / unreadable file -> FAIL CLOSED (rc 1) ---
: > "${TMP_DIR}/zero.json"
test_start "10" "zero-byte plan file fails closed (rc 1)"
run_classify "${TMP_DIR}/zero.json"
if [[ "$CLASSIFY_RC" -eq 1 ]]; then
  test_pass "empty file fails closed"
else
  test_fail "expected rc 1, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

# --- Case 11: missing plan file -> FAIL CLOSED (rc 1) ---
test_start "11" "missing plan file fails closed (rc 1)"
run_classify "${TMP_DIR}/does-not-exist.json"
if [[ "$CLASSIFY_RC" -eq 1 ]]; then
  test_pass "unreadable path fails closed"
else
  test_fail "expected rc 1, got rc=$CLASSIFY_RC out=[$CLASSIFY_OUT]"
fi

runner_summary
