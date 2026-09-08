#!/usr/bin/env bash
# Hermetic validate.sh fixture for the DNS anti-affinity co-location gate.
# This invokes validate.sh through its early MYCOFU_VALIDATE_ONLY_ANTIAFFINITY
# gate because the gate runs before live network/storage checks; PATH shims
# provide yq, ssh, and pvesh responses.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

# Resolve the REAL yq before any shim shadows it. The vmid-lookup shim cases
# delegate to this so the actual yq expression syntax is exercised against real
# mikefarah/yq — the gap that let #513 ship (a hard-coded `// empty` shim case
# masked the fact that the jq `// empty` idiom is invalid in mikefarah/yq).
YQ_REAL_BIN="$(command -v yq || true)"
if [[ -z "${YQ_REAL_BIN}" ]]; then
  echo "test requires yq on PATH" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_CONFIG="${TMP_DIR}/config.yaml"
SHIMS_DIR="${TMP_DIR}/shims"
mkdir -p "${SHIMS_DIR}"

cat > "${FIXTURE_CONFIG}" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.51
  - name: pve02
    mgmt_ip: 10.0.0.52
  - name: pve03
    mgmt_ip: 10.0.0.53
vms:
  dns1_dev:
    vmid: 301
  dns2_dev:
    vmid: 302
EOF

cat > "${SHIMS_DIR}/yq" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-r" ]]; then
  expr="$2"
else
  expr="$1"
fi

case "${expr}" in
  '.domain') echo "example.test" ;;
  '.nodes | length') echo "3" ;;
  '.nodes[0].mgmt_ip') echo "10.0.0.51" ;;
  '.nas.ip') echo "10.0.0.10" ;;
  '.vms.gatus.ip') echo "10.0.0.20" ;;
  '.vms.gitlab.ip') echo "10.0.0.30" ;;
  '.vms.pbs.ip') echo "10.0.0.40" ;;
  '.replication.health_port') echo "9100" ;;
  '.proxmox.storage_pool') echo "vmstore" ;;
  '.acme // "production"') echo "production" ;;
  '.vms | keys | .[]')
    printf '%s\n' "dns1_dev" "dns2_dev"
    ;;
  .vms.dns1_*.vmid*|.vms.dns2_*.vmid*)
    # Delegate to the REAL yq so the exact expression the check emits is
    # evaluated by mikefarah/yq. This is what catches #513: if the expression
    # ever regresses to the jq-only `// empty` idiom, real yq aborts and the
    # test fails, instead of a hard-coded shim case silently returning a vmid.
    exec "${YQ_REAL_BIN}" "$@"
    ;;
  *) echo "yq shim: unhandled expression: ${expr}" >&2; exit 1 ;;
esac
SHIM
chmod +x "${SHIMS_DIR}/yq"

cat > "${SHIMS_DIR}/ssh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
remote=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-q|-A) shift ;;
    -o) shift 2 ;;
    root@*) shift; remote="$*"; break ;;
    *) shift ;;
  esac
done
[[ -n "${remote}" ]] || { echo "ssh shim: missing remote command" >&2; exit 2; }
PATH="${FIXTURE_SHIMS_DIR}:${PATH}" bash -c "${remote}"
SHIM
chmod +x "${SHIMS_DIR}/ssh"

cat > "${SHIMS_DIR}/pvesh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${PVE_FAIL:-0}" == "1" ]]; then
  echo "simulated pvesh failure" >&2
  exit 2
fi
case "$*" in
  'get /cluster/options --output-format json')
    printf '%s\n' "${PVE_OPTIONS_JSON}"
    ;;
  'get /cluster/ha/rules --output-format json')
    printf '%s\n' "${PVE_RULES_JSON}"
    ;;
  'get /cluster/resources --output-format json')
    printf '%s\n' "${PVE_RESOURCES_JSON}"
    ;;
  *) echo "pvesh shim: unhandled $*" >&2; exit 1 ;;
esac
SHIM
chmod +x "${SHIMS_DIR}/pvesh"

# Live-shaped payload: `pvesh get /cluster/ha/rules --output-format json`
# returns `resources` as a comma-joined STRING ("vm:301,vm:302"), not a JSON
# array. The earlier array-shaped fixture never exercised the real shape (#513).
RULE_PRESENT='[{"rule":"dns-dev-antiaffinity","type":"resource-affinity","affinity":"negative","resources":"vm:301,vm:302","order":1,"comment":"Managed by Mycofu (Sprint 045) - dns pair anti-affinity (preferential)","digest":"1d1a81049dbf156f1d433e15be3a8872d50436e1"}]'
RULE_ABSENT='[]'
OPTIONS_JSON='{"crs":{"ha":"static"}}'

run_validate_case() {
  local expected_rc="$1"
  local expected_msg="$2"
  local resources_json="$3"
  local rules_json="$4"
  local pve_fail="${5:-0}"
  local output rc

  set +e
  output="$(FIXTURE_SHIMS_DIR="${SHIMS_DIR}" \
    YQ_REAL_BIN="${YQ_REAL_BIN}" \
    PATH="${SHIMS_DIR}:${PATH}" \
    MYCOFU_VALIDATE_CONFIG="${FIXTURE_CONFIG}" \
    MYCOFU_VALIDATE_ONLY_ANTIAFFINITY=1 \
    PVE_OPTIONS_JSON="${OPTIONS_JSON}" \
    PVE_RULES_JSON="${rules_json}" \
    PVE_RESOURCES_JSON="${resources_json}" \
    PVE_FAIL="${pve_fail}" \
    bash "${REPO_ROOT}/framework/scripts/validate.sh" 2>&1)"
  rc=$?
  set -e

  if [[ "$rc" -ne "$expected_rc" ]]; then
    printf '    expected rc=%s got rc=%s\n%s\n' "$expected_rc" "$rc" "$output" >&2
    return 1
  fi
  if [[ -n "$expected_msg" && "$output" != *"$expected_msg"* ]]; then
    printf '    expected output to contain: %s\n%s\n' "$expected_msg" "$output" >&2
    return 1
  fi
  return 0
}

test_start "s045.2.6" "co-located dns pair fails while three nodes are healthy"
if run_validate_case 1 \
  "dns pair co-located on pve01 while 3 nodes healthy" \
  '[{"type":"node","node":"pve01","status":"online"},{"type":"node","node":"pve02","status":"online"},{"type":"node","node":"pve03","status":"online"},{"type":"qemu","vmid":301,"node":"pve01"},{"type":"qemu","vmid":302,"node":"pve01"}]' \
  "${RULE_PRESENT}"; then
  test_pass "co-location fails closed when two or more nodes are healthy"
else
  test_fail "co-location did not fail with three healthy nodes"
fi

test_start "s045.2.7" "co-located dns pair passes with one online survivor"
if run_validate_case 0 \
  "[PASS] dns pair anti-affinity healthy-node-aware" \
  '[{"type":"node","node":"pve01","status":"online"},{"type":"node","node":"pve02","status":"offline"},{"type":"node","node":"pve03","status":"offline"},{"type":"qemu","vmid":301,"node":"pve01"},{"type":"qemu","vmid":302,"node":"pve01"}]' \
  "${RULE_PRESENT}"; then
  test_pass "single-survivor co-location is accepted"
else
  test_fail "single-survivor co-location was rejected"
fi

test_start "s045.2.8" "separated dns pair passes with three online nodes"
if run_validate_case 0 \
  "[PASS] dns pair anti-affinity healthy-node-aware" \
  '[{"type":"node","node":"pve01","status":"online"},{"type":"node","node":"pve02","status":"online"},{"type":"node","node":"pve03","status":"online"},{"type":"qemu","vmid":301,"node":"pve01"},{"type":"qemu","vmid":302,"node":"pve02"}]' \
  "${RULE_PRESENT}"; then
  test_pass "separated dns pair is accepted"
else
  test_fail "separated dns pair was rejected"
fi

test_start "s045.2.9" "missing live anti-affinity rule fails even when VMs are separated"
if run_validate_case 1 \
  "anti-affinity rule missing for env dev (vm:301,vm:302)" \
  '[{"type":"node","node":"pve01","status":"online"},{"type":"node","node":"pve02","status":"online"},{"type":"node","node":"pve03","status":"online"},{"type":"qemu","vmid":301,"node":"pve01"},{"type":"qemu","vmid":302,"node":"pve02"}]' \
  "${RULE_ABSENT}"; then
  test_pass "missing rule is reported as a failure"
else
  test_fail "missing rule was not reported as a failure"
fi

test_start "s045.2.10" "unreadable pvesh data fails closed"
if run_validate_case 1 \
  "failed to read CRS mode" \
  '[]' \
  "${RULE_PRESENT}" \
  1; then
  test_pass "pvesh failure returns a validation failure instead of skipping"
else
  test_fail "pvesh failure did not fail closed"
fi

test_start "s045.2.11" "live-shaped rule payload (comma-string resources) is parsed via real yq (#513 regression)"
# Regression guard for #513: with the yq shim delegating vmid lookups to real
# mikefarah/yq and the rule payload carrying `resources` as a comma-string, the
# check must run to a real verdict — not abort with a yq lexer error. Separated
# pair + rule present + three healthy nodes => PASS.
if run_validate_case 0 \
  "[PASS] dns pair anti-affinity healthy-node-aware" \
  '[{"type":"node","node":"pve01","status":"online"},{"type":"node","node":"pve02","status":"online"},{"type":"node","node":"pve03","status":"online"},{"type":"qemu","vmid":301,"node":"pve01"},{"type":"qemu","vmid":302,"node":"pve02"}]' \
  "${RULE_PRESENT}"; then
  test_pass "live comma-string rule payload evaluated without a yq parse crash"
else
  test_fail "live-shaped rule payload was not parsed to a clean verdict"
fi

runner_summary
