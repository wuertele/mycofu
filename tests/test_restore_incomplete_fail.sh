#!/usr/bin/env bash
# test_restore_incomplete_fail.sh — restore-before-start rc=2 on incomplete VM.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
MANIFEST="${TMP_DIR}/manifest.json"
PIN_FILE="${TMP_DIR}/pin.json"
STATUS_FILE="${TMP_DIR}/status.json"
RESTORE_LOG="${TMP_DIR}/restore.log"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "$SHIM_DIR"
cp "${REPO_ROOT}/framework/scripts/restore-before-start.sh" "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh"
cp "${REPO_ROOT}/framework/scripts/vm-topology-lib.sh" "${FIXTURE_REPO}/framework/scripts/vm-topology-lib.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-before-start.sh" "${FIXTURE_REPO}/framework/scripts/vm-topology-lib.sh"

cat > "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'restore-from-pbs.sh %s\n' "$*" >> "${RESTORE_LOG}"
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/restore-from-pbs.sh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
EOF

cat > "$MANIFEST" <<'EOF'
{
  "version": 1,
  "entries": [
    {
      "label": "vault_dev",
      "module": "module.vault_dev",
      "vmid": 303,
      "env": "dev",
      "kind": "infrastructure",
      "reason": "replace",
      "expected_disks": ["scsi0", "scsi1", "ide2"]
    }
  ]
}
EOF
cat > "$PIN_FILE" <<'EOF'
{
  "version": 1,
  "pins": {
    "303": "pbs-nas:backup/vm/303/2026-06-26T02:27:40Z"
  }
}
EOF

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${2:-}" in
  ".nodes[0].mgmt_ip")
    echo "127.0.0.1"
    ;;
  ".nodes[] | select(.name == \"pve01\") | .mgmt_ip")
    echo "127.0.0.1"
    ;;
  ".nodes[] | [.name, .mgmt_ip] | @tsv")
    printf 'pve01\t127.0.0.1\n'
    ;;
  ".storage.pool_name // .proxmox.storage_pool // \"local-zfs\"")
    echo "local-zfs"
    ;;
  *)
    echo "unexpected yq query: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/yq"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
case "$cmd" in
  *'/cluster/resources --type vm --output-format json'*)
    echo '[{"vmid":303,"node":"pve01"}]'
    ;;
  *'qm status 303'*)
    echo "stopped"
    ;;
  'ha-manager status')
    ;;
  *'zfs list -H -o name,volsize -r '*)
    ;;
  *'zfs list -H -o name -r '*)
    ;;
  *'zfs list -H -o name '*)
    exit 1
    ;;
  "qm config 303")
    if [[ "${STUB_QM_CONFIG_UNVERIFIABLE:-0}" == "1" ]]; then
      echo "ssh connection failed" >&2
      exit 255
    fi
    # Simulates the 1199 residual-damage shape: vdb and cidata exist, vda/scsi0 is missing.
    printf '%s\n' 'scsi1: vmstore:vm-303-disk-1.raw' 'ide2: local:cloudinit'
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"
export RESTORE_LOG
: > "$RESTORE_LOG"

test_start "RIF.1" "restore-before-start returns rc=2 for incomplete topology"
set +e
OUT="$(cd "$FIXTURE_REPO" && framework/scripts/restore-before-start.sh dev \
  --manifest "$MANIFEST" \
  --pin-file "$PIN_FILE" \
  --status-file "$STATUS_FILE" 2>&1)"
RC=$?
set -e

if [[ "$RC" -eq 2 ]] &&
   grep -Fq "Skipping phase 2: one or more restored VM(s) are incomplete." <<< "$OUT" &&
   ! grep -Fq "vault_dev: restored; leaving VM stopped" <<< "$OUT"; then
  test_pass "incomplete restore exits 2 and does not print restored success"
else
  test_fail "restore-before-start did not surface rc=2 incomplete topology"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "RIF.2" "status file records incomplete VMID and pin"
if jq -e '.entries[] | select(.vmid == 303 and .status == "incomplete" and .pin == "pbs-nas:backup/vm/303/2026-06-26T02:27:40Z")' "$STATUS_FILE" >/dev/null; then
  test_pass "status file records incomplete entry"
else
  test_fail "status file missing incomplete entry"
  cat "$STATUS_FILE" >&2
fi

test_start "RIF.3" "restore-before-start fails closed when topology is unverifiable"
rm -f "$STATUS_FILE"
export STUB_QM_CONFIG_UNVERIFIABLE=1
set +e
OUT="$(cd "$FIXTURE_REPO" && framework/scripts/restore-before-start.sh dev \
  --manifest "$MANIFEST" \
  --pin-file "$PIN_FILE" \
  --status-file "$STATUS_FILE" 2>&1)"
RC=$?
set -e
unset STUB_QM_CONFIG_UNVERIFIABLE

if [[ "$RC" -eq 1 ]] &&
   grep -Fq "topology unverifiable" <<< "$OUT" &&
   ! grep -Fq "one or more restored VM(s) are incomplete" <<< "$OUT"; then
  test_pass "unverifiable topology exits 1, not rc=2"
else
  test_fail "unverifiable topology did not fail closed"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "RIF.4" "status file records unverifiable, not incomplete"
if jq -e '.entries[] | select(.vmid == 303 and .status == "unverifiable")' "$STATUS_FILE" >/dev/null &&
   ! jq -e '.entries[] | select(.vmid == 303 and .status == "incomplete")' "$STATUS_FILE" >/dev/null; then
  test_pass "status file keeps unverifiable out of convergence status"
else
  test_fail "status file did not record unverifiable cleanly"
  cat "$STATUS_FILE" >&2
fi

runner_summary
