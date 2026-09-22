#!/usr/bin/env bash
# test_list_backup_backed_vmids.sh — first-bootstrap VMID helper fixture.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site"

cp "${REPO_ROOT}/framework/scripts/list-backup-backed-vmids.sh" \
  "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
vms:
  gitlab:
    vmid: 150
    backup: true
  vault_dev:
    vmid: 303
    backup: true
  vault_prod:
    vmid: 403
    backup: true
  testapp_dev:
    vmid: 500
    backup: false
  disabled_shared:
    vmid: 151
    backup: true
    enabled: false
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications:
  roon:
    enabled: true
    backup: true
    environments:
      dev:
        vmid: 305
      prod:
        vmid: 405
  scratch:
    enabled: true
    backup: false
    environments:
      dev:
        vmid: 306
  disabled:
    enabled: false
    backup: true
    environments:
      dev:
        vmid: 307
EOF

cp "${FIXTURE_REPO}/site/config.yaml" "${TMP_DIR}/base-config.yaml"
cp "${FIXTURE_REPO}/site/applications.yaml" "${TMP_DIR}/base-applications.yaml"

restore_fixture_configs() {
  cp "${TMP_DIR}/base-config.yaml" "${FIXTURE_REPO}/site/config.yaml"
  cp "${TMP_DIR}/base-applications.yaml" "${FIXTURE_REPO}/site/applications.yaml"
}

run_helper() {
  (
    cd "${FIXTURE_REPO}"
    framework/scripts/list-backup-backed-vmids.sh "$@"
  )
}

run_helper_capture() {
  set +e
  HELPER_OUTPUT="$(
    cd "${FIXTURE_REPO}" &&
    framework/scripts/list-backup-backed-vmids.sh "$@" 2>&1
  )"
  HELPER_STATUS=$?
  set -e
}

assert_output() {
  local scope="$1"
  local expected="$2"
  local label="$3"
  local actual

  actual="$(run_helper "$scope")"
  if [[ "$actual" == "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected: %s\n    actual:   %s\n' "$expected" "$actual" >&2
  fi
}

test_start "1" "dev helper lists backup-backed dev VMIDs"
assert_output dev "303,305" "dev scope excludes shared/prod and non-backup VMs"

test_start "2" "prod helper lists backup-backed prod VMIDs"
assert_output prod "403,405" "prod scope excludes shared/dev and non-backup VMs"

test_start "3" "all helper lists shared and environment VMIDs"
assert_output all "150,303,403,305,405" "all scope includes every backup-backed VMID"

test_start "4" "tsv helper format includes VMID, label, and environment"
expected_tsv=$'150\tgitlab\tshared\n303\tvault-dev\tdev\n403\tvault-prod\tprod\n305\troon-dev\tdev\n405\troon-prod\tprod'
actual_tsv="$(run_helper --format tsv all)"
if [[ "$actual_tsv" == "$expected_tsv" ]]; then
  test_pass "tsv output has stable three-column rows"
else
  test_fail "tsv output mismatch"
  printf '    expected:\n%s\n    actual:\n%s\n' "$expected_tsv" "$actual_tsv" >&2
fi

test_start "5" "disabled backup:true entries are excluded"
all_output="$(run_helper all)"
if [[ "$all_output" != *"151"* && "$all_output" != *"307"* ]]; then
  test_pass "disabled VM and disabled app are omitted"
else
  test_fail "disabled backup:true entry leaked into output"
  printf '    output: %s\n' "$all_output" >&2
fi

test_start "6" "missing VMID fails closed"
restore_fixture_configs
yq -i 'del(.vms.gitlab.vmid)' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture all
if [[ "$HELPER_STATUS" -eq 1 && "$HELPER_OUTPUT" == *"has no vmid"* ]]; then
  test_pass "missing VMID exits non-zero with explicit error"
else
  test_fail "missing VMID should fail closed"
  printf '    status=%s\n    output:\n%s\n' "$HELPER_STATUS" "$HELPER_OUTPUT" >&2
fi

test_start "7" "invalid VMID fails closed"
restore_fixture_configs
yq -i '.vms.gitlab.vmid = "not-a-number"' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture all
if [[ "$HELPER_STATUS" -eq 1 && "$HELPER_OUTPUT" == *"invalid vmid"* ]]; then
  test_pass "invalid VMID exits non-zero with explicit error"
else
  test_fail "invalid VMID should fail closed"
  printf '    status=%s\n    output:\n%s\n' "$HELPER_STATUS" "$HELPER_OUTPUT" >&2
fi

test_start "8" "duplicate VMID fails closed"
restore_fixture_configs
yq -i '.applications.roon.environments.dev.vmid = 150' "${FIXTURE_REPO}/site/applications.yaml"
run_helper_capture all
if [[ "$HELPER_STATUS" -eq 1 && "$HELPER_OUTPUT" == *"duplicate backup-backed VMID 150"* ]]; then
  test_pass "duplicate VMID exits non-zero with explicit error"
else
  test_fail "duplicate VMID should fail closed"
  printf '    status=%s\n    output:\n%s\n' "$HELPER_STATUS" "$HELPER_OUTPUT" >&2
fi

runner_summary
