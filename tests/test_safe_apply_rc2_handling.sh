#!/usr/bin/env bash
# test_safe_apply_rc2_handling.sh — safe-apply treats restore rc=2 distinctly.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
EVENT_LOG="${TMP_DIR}/events.log"
VM_SCOPE="${TMP_DIR}/vm-scope.sh"

mkdir -p "${FIXTURE_REPO}/framework/scripts/lib" "${FIXTURE_REPO}/framework/tofu/root" "${FIXTURE_REPO}/site" "$SHIM_DIR"
cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"

cat > "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
converge_incomplete_vm() {
  printf 'converge-incomplete-vm %s\n' "$*" >> "${EVENT_LOG}"
  return 0
}
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/lib/converge-incomplete-vm.sh"

for script in check-approle-creds.sh check-control-plane-drift.sh check-plan-images-present.sh configure-replication.sh post-deploy.sh configure-backups.sh; do
  cat > "${FIXTURE_REPO}/framework/scripts/${script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${script} %s\n' "\$*" >> "${EVENT_LOG}"
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/${script}"
done

cat > "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'tofu-wrapper %s\n' "$*" >> "${EVENT_LOG}"
case "${1:-}" in
  plan)
    for arg in "$@"; do
      [[ "$arg" == -out=* ]] && : > "${arg#-out=}"
    done
    ;;
  apply)
    ;;
  state)
    [[ "${2:-}" == "list" ]] && exit 0
    ;;
esac
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

cat > "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-before-start.sh %s\n' "$*" >> "${EVENT_LOG}"
mkdir -p build
cat > build/preboot-restore-status-dev.json <<'JSON'
{
  "version": 1,
  "scope": "dev",
  "entries": [
    {"label": "testapp_dev", "vmid": 500, "status": "incomplete", "reason": "replace", "message": "missing scsi0"}
  ]
}
JSON
exit 2
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"

cat > "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Empty set: VMID 500 is non-precious and must not be converged.
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/list-backup-backed-vmids.sh"

cat > "$VM_SCOPE" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  control-plane-modules)
    ;;
  deployable-modules)
    echo "module.testapp_dev"
    ;;
  classes)
    echo '{"testapp":{"category":"nix"}}'
    ;;
  *)
    echo "unexpected vm-scope invocation: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "$VM_SCOPE"

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -chdir=* ]] && shift
if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  cat <<'JSON'
{
  "resource_changes": [
    {
      "address": "module.testapp_dev.module.testapp.proxmox_virtual_environment_vm.vm",
      "change": {
        "actions": ["create"],
        "after": {
          "disk": [{"interface": "scsi0"}],
          "initialization": [{"type": "nocloud"}]
        }
      }
    }
  ]
}
JSON
  exit 0
fi
exit 2
EOF
chmod +x "${SHIM_DIR}/tofu"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF
chmod +x "${SHIM_DIR}/ssh"

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-o=json" ]]; then
  cat <<'JSON'
{"nodes":[{"name":"pve01","mgmt_ip":"127.0.0.1"}],"vms":{"testapp_dev":{"vmid":500,"backup":true}}}
JSON
  exit 0
fi
case "${2:-}" in
  ".nodes[0].mgmt_ip") echo "127.0.0.1" ;;
  *) echo "127.0.0.1" ;;
esac
EOF
chmod +x "${SHIM_DIR}/yq"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
vms:
  testapp_dev:
    vmid: 500
    backup: true
EOF

export PATH="${SHIM_DIR}:${PATH}"
export VM_SCOPE_SCRIPT="$VM_SCOPE"
export EVENT_LOG
: > "$EVENT_LOG"

test_start "SAR.1" "safe-apply propagates rc=2 for incomplete non-precious VM"
set +e
OUT="$(cd "$FIXTURE_REPO" && framework/scripts/safe-apply.sh dev 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 2 ]] &&
   grep -Fq "restore-before-start.sh found incomplete VM topology (rc=2)" <<< "$OUT" &&
   grep -Fq "needs full recreate because vdb-only restore cannot repair missing boot topology" <<< "$OUT" &&
   grep -Fq "qmrestore <exact-pin> 500 --force" <<< "$OUT"; then
  test_pass "rc=2 has distinct full-recreate diagnostic and propagates"
else
  test_fail "safe-apply rc=2 handling changed"
  printf 'rc=%s\noutput:\n%s\nevents:\n%s\n' "$RC" "$OUT" "$(cat "$EVENT_LOG")" >&2
fi

test_start "SAR.2" "rc=2 refusal does not run phase 2 or convergence"
if [[ "$(grep -c 'start_vms=true' "$EVENT_LOG" || true)" == "0" ]] &&
   [[ "$(grep -c '^converge-incomplete-vm' "$EVENT_LOG" || true)" == "0" ]]; then
  test_pass "no phase 2 apply and no convergence for non-precious VM"
else
  test_fail "safe-apply continued after rc=2 refusal"
  cat "$EVENT_LOG" >&2
fi

runner_summary
