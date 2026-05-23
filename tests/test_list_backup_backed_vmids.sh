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

run_helper() {
  (
    cd "${FIXTURE_REPO}"
    framework/scripts/list-backup-backed-vmids.sh "$1"
  )
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

runner_summary
