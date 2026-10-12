#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/restore-from-pbs.sh" "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-state-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-state-lib.sh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
vms:
  pbs:
    ip: 10.0.0.60
  vault_dev:
    vmid: 303
    ip: 10.0.0.23
    backup: true
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${*: -1}"

case "$cmd" in
  'pvesm status 2>/dev/null')
    printf '%s\n' 'pbs-nas active'
    ;;
  *'/storage/pbs-nas/content --output-format json'*)
    if [[ "${STUB_FAIL_ON_CONTENT_QUERY:-}" == "1" ]]; then
      echo "content query should not have been called" >&2
      exit 97
    fi
    printf '%s\n' "${STUB_PBS_OUTPUT:-[]}"
    ;;
  *)
    echo "unexpected ssh invocation: $*" >&2
    exit 98
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

run_capture() {
  local fixture_repo="$1"
  shift
  local output=""
  set +e
  output="$(
    cd "${fixture_repo}" &&
    "$@" 2>&1
  )"
  STATUS=$?
  set -e
  OUTPUT="$output"
}

assert_exit() {
  local expected="$1"
  local label="$2"

  if [[ "$STATUS" -eq "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    expected exit %s, got %s\n' "$expected" "$STATUS" >&2
    printf '    output:\n%s\n' "$OUTPUT" >&2
  fi
}

assert_output_contains() {
  local needle="$1"
  local label="$2"

  if grep -Fq -- "$needle" <<< "$OUTPUT"; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    missing output: %s\n' "$needle" >&2
    printf '    output:\n%s\n' "$OUTPUT" >&2
  fi
}

export PATH="${SHIM_DIR}:${PATH}"

test_start "12.15" "restore-from-pbs uses a pinned backup id verbatim"
export STUB_FAIL_ON_CONTENT_QUERY="1"
run_capture "${FIXTURE_REPO}" \
  framework/scripts/restore-from-pbs.sh \
  --target 303 \
  --backup-id 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z' \
  --leave-stopped \
  --dry-run
assert_exit 0 "pinned dry run succeeds"
assert_output_contains 'Backup: pbs-nas:backup/vm/303/2026-04-12T18:30:00Z' "dry run reports the pinned backup"
assert_output_contains '[DRY RUN] Would restore vdb from this backup' "dry run stays on the restore path"

test_start "12.16" "restore-from-pbs rejects mismatched target and backup ids"
unset STUB_FAIL_ON_CONTENT_QUERY
run_capture "${FIXTURE_REPO}" \
  framework/scripts/restore-from-pbs.sh \
  --target 303 \
  --backup-id 'pbs-nas:backup/vm/304/2026-04-12T18:30:00Z' \
  --dry-run
assert_exit 1 "mismatched VMID is fatal"
assert_output_contains '--backup-id VMID 304 does not match --target 303' "mismatch error is explicit"

test_start "12.17" "restore-from-pbs still falls back to the latest backup when no pin is supplied"
export STUB_PBS_OUTPUT='[
  {"vmid":303,"ctime":1000,"volid":"pbs-nas:backup/vm/303/2026-04-12T18:20:00Z"},
  {"vmid":303,"ctime":1001,"volid":"pbs-nas:backup/vm/303/2026-04-12T18:30:00Z"}
]'
run_capture "${FIXTURE_REPO}" \
  framework/scripts/restore-from-pbs.sh \
  --target 303 \
  --dry-run
assert_exit 0 "latest-backup dry run succeeds"
assert_output_contains 'Backup: pbs-nas:backup/vm/303/2026-04-12T18:30:00Z' "latest backup is selected when no pin is supplied"

runner_summary
