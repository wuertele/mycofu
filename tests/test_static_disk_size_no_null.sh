#!/usr/bin/env bash
#
# Regression test for issue #276: workstation disk-resize bug.
#
# Pipeline 710 (2026-04-21) failed because vda_size_gb resolved to null at
# the proxmox provider. Root cause: try(local.app_workstation.disk_size, null)
# in framework/tofu/root/main.tf passed null to the workstation catalog
# module, which propagated it to proxmox-vm-field-updatable, which sent
# null to the provider. The provider rejected it with "shrinking disks is
# not supported". Commit d2b1dde "fixed" the original disk_size:4 problem
# but introduced this null-cascade footgun assuming OpenTofu would coerce
# null to the receiving variable's default — it does not.
#
# This test prevents reintroduction of the null-fallback pattern for VM
# sizing fields. If a future change reintroduces try(..., null) for these
# fields, this test fails.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

ROOT_TF="${REPO_ROOT}/framework/tofu/root/main.tf"

# Pattern: <field> = try(<anything>, null) — null fallback for a sizing field
# directly to a module argument. Catches the d2b1dde-shaped footgun.
SIZING_FIELDS=(
  vda_size_gb
)

# vdb_size_gb intentionally omitted from the regression list for now: the
# field-updatable module's dynamic disk block guards on `var.vdb_size_gb > 0`
# which currently relies on the same null-cascade; auditing those callers is
# tracked in a follow-up issue. This test focuses on vda_size_gb where the
# proxmox provider directly rejects null.

test_start "1" "no try(..., null) fallback for vda_size_gb in root callers"

found_violations=0
for field in "${SIZING_FIELDS[@]}"; do
  # Match: "<field> = try(...,  null)" with arbitrary spacing.
  # The pattern intentionally only flags `try(..., null)` direct fallbacks;
  # nested try() chains where the OUTER try's fallback is null are also
  # flagged. coalesce(try(..., null), 16) is fine because the outer
  # coalesce() converts null to a concrete value before module assignment.
  if grep -nE "^\s*${field}\s*=\s*try\([^)]*,\s*null\s*\)\s*$" "${ROOT_TF}" >/tmp/disk-size-no-null.violations 2>/dev/null; then
    if [[ -s /tmp/disk-size-no-null.violations ]]; then
      found_violations=1
      printf '    violation in %s:\n' "${ROOT_TF}" >&2
      sed 's/^/      /' /tmp/disk-size-no-null.violations >&2
    fi
  fi
done

if [[ "${found_violations}" -eq 0 ]]; then
  test_pass "no try(..., null) fallback for vda_size_gb in framework/tofu/root/main.tf"
else
  test_fail "found try(..., null) fallback for vda_size_gb (regression of #276)"
fi

test_start "2" "workstation catalog vda_size_gb default is non-null"

CATALOG_VARS="${REPO_ROOT}/framework/catalog/workstation/variables.tf"
# Extract the vda_size_gb variable block and confirm default is not null.
# Match `default = ...` precisely (not free-text mentions of the word).
DEFAULT_LINE="$(awk '/variable "vda_size_gb"/{flag=1} flag && /^[[:space:]]*default[[:space:]]*=/{print; exit}' "${CATALOG_VARS}")"

if [[ -z "${DEFAULT_LINE}" ]]; then
  test_fail "could not find vda_size_gb default in ${CATALOG_VARS}"
elif grep -qE 'default\s*=\s*null' <<< "${DEFAULT_LINE}"; then
  test_fail "workstation catalog vda_size_gb default is null (regression of #276)"
  printf '    line: %s\n' "${DEFAULT_LINE}" >&2
else
  test_pass "workstation catalog vda_size_gb default is non-null: ${DEFAULT_LINE# *}"
fi

test_start "3" "workstation root callers use coalesce or non-null literal for vda_size_gb"

# Both workstation_dev and workstation_prod blocks must have a non-null
# fallback for vda_size_gb. Acceptable patterns:
#   coalesce(try(..., null), <number>)
#   try(..., <number>)
#   <number>
# Unacceptable:
#   try(..., null)
#   null
#   <none>

ws_module_violations=0
for module_name in workstation_dev workstation_prod; do
  # Extract the lines from `module "<name>"` to the closing `}` (single-line
  # heuristic: stop at next `module "` or end-of-file).
  block="$(awk -v m="module \"${module_name}\"" '
    $0 ~ m {flag=1; next}
    flag && /^module "/ {flag=0}
    flag {print}
  ' "${ROOT_TF}")"

  if [[ -z "${block}" ]]; then
    test_fail "could not locate module block for ${module_name}"
    ws_module_violations=$((ws_module_violations + 1))
    continue
  fi

  vda_line="$(grep -E '^\s*vda_size_gb\s*=' <<< "${block}" || true)"
  if [[ -z "${vda_line}" ]]; then
    test_fail "${module_name}: vda_size_gb assignment not found"
    ws_module_violations=$((ws_module_violations + 1))
    continue
  fi

  # Reject try(..., null) without surrounding coalesce.
  if grep -qE 'coalesce\(' <<< "${vda_line}"; then
    : # OK — coalesce protects against null
  elif grep -qE 'try\([^)]*,\s*null\s*\)' <<< "${vda_line}"; then
    test_fail "${module_name}: vda_size_gb uses try(..., null) without coalesce"
    printf '    line: %s\n' "${vda_line}" >&2
    ws_module_violations=$((ws_module_violations + 1))
    continue
  fi

  test_pass "${module_name}: vda_size_gb has non-null fallback"
done

rm -f /tmp/disk-size-no-null.violations

runner_summary
