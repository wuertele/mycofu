#!/usr/bin/env bash
# test_validate_vm_complete.sh — validate.sh wires fail-closed VM topology check.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

VALIDATE="${REPO_ROOT}/framework/scripts/validate.sh"

test_start "VVC.1" "validate.sh defines VM topology completeness check"
if grep -Fq 'vm_topology_complete_check()' "$VALIDATE" &&
   grep -Fq '"${SCRIPT_DIR}/vm-is-complete.sh" "$vmid"' "$VALIDATE"; then
  test_pass "validate.sh walks VMIDs through vm-is-complete.sh"
else
  test_fail "validate.sh VM topology function missing or not using vm-is-complete.sh"
fi

test_start "VVC.2" "VM topology section is fail-closed outside --quick"
SECTION="$(awk '/=== VM Topology ===/{flag=1} flag{print} /=== Applications ===/{flag=0}' "$VALIDATE")"
if grep -Fq 'check_capture "VM topology completeness" vm_topology_complete_check' <<< "$SECTION" &&
   grep -Fq 'check_skip "VM topology completeness" "--quick mode"' <<< "$SECTION"; then
  test_pass "topology check runs through check_capture and quick mode skips explicitly"
else
  test_fail "validate.sh topology section wiring changed"
  printf '%s\n' "$SECTION" >&2
fi

test_start "VVC.3" "topology row builder includes config VMs and enabled app environments"
if grep -Fq 'for label, vm in (config.get("vms") or {}).items()' "$VALIDATE" &&
   grep -Fq 'for app, app_cfg in (apps.get("applications") or {}).items()' "$VALIDATE" &&
   grep -Fq 'app_cfg.get("enabled") is not True' "$VALIDATE"; then
  test_pass "validate.sh enumerates config.yaml VMs and enabled application environments"
else
  test_fail "validate.sh topology enumeration changed"
fi

test_start "VVC.4" "class-aware false-positive coverage lives in vm-is-complete fixture"
if bash "${REPO_ROOT}/tests/test_vm_is_complete.sh" >/dev/null; then
  test_pass "vm-is-complete fixture covers PBS vendor and hil_boot no-vdb cases"
else
  test_fail "vm-is-complete fixture failed"
fi

test_start "VVC.5" "validate.sh execution fails on an incomplete VM topology"
TMP_DIR="$(mktemp -d)"
FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "$SHIM_DIR"
cp "$VALIDATE" "${FIXTURE_REPO}/framework/scripts/validate.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/validate.sh"
cat > "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
certbot_cluster_expected_mode() { echo "staging"; }
EOF
cat > "${FIXTURE_REPO}/framework/scripts/vm-is-complete.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "VM ${1} is incomplete; missing expected disk(s): scsi0" >&2
exit 2
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/vm-is-complete.sh"
cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
vms:
  vault_dev:
    vmid: 303
EOF
cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF
cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-o=json" ]]; then
  case "${4:-${3:-}}" in
    *config.yaml)
      echo '{"vms":{"vault_dev":{"vmid":303}}}'
      ;;
    *applications.yaml)
      echo '{"applications":{}}'
      ;;
    *)
      echo "unexpected yq json file: $*" >&2
      exit 9
      ;;
  esac
  exit 0
fi
echo "unexpected yq invocation: $*" >&2
exit 9
EOF
chmod +x "${SHIM_DIR}/yq"
set +e
OUT="$(cd "$FIXTURE_REPO" && PATH="${SHIM_DIR}:${PATH}" MYCOFU_VALIDATE_ONLY_VM_TOPOLOGY=1 framework/scripts/validate.sh dev 2>&1)"
RC=$?
set -e
rm -rf "$TMP_DIR"
if [[ "$RC" -eq 1 ]] &&
   grep -Fq '[FAIL] VM topology completeness' <<< "$OUT" &&
   grep -Fq 'vault_dev (303): incomplete' <<< "$OUT" &&
   grep -Fq 'missing expected disk(s): scsi0' <<< "$OUT"; then
  test_pass "validate.sh surfaces incomplete topology as a failed check"
else
  test_fail "validate.sh topology execution did not fail as expected"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

runner_summary
