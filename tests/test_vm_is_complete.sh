#!/usr/bin/env bash
# test_vm_is_complete.sh — plan-derived and class-aware topology predicate.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
CONFIG="${TMP_DIR}/config.yaml"
APPS="${TMP_DIR}/applications.yaml"
CLASSES="${TMP_DIR}/classes.sh"
SCRIPT="${REPO_ROOT}/framework/scripts/vm-is-complete.sh"

mkdir -p "$SHIM_DIR"
cat > "$CONFIG" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
vms:
  backup_dev:
    vmid: 303
    backup: true
  nobackup_dev:
    vmid: 304
    backup: false
  pbs:
    vmid: 190
    backup: true
  hil_boot:
    vmid: 170
    backup: false
  dns1_dev:
    vmid: 301
    backup: false
  dns2_dev:
    vmid: 302
    backup: false
  dns1_prod:
    vmid: 402
    backup: false
  dns2_prod:
    vmid: 401
    backup: false
EOF
cat > "$APPS" <<'EOF'
applications: {}
EOF

cat > "$CLASSES" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "classes" && "${2:-}" == "--format" && "${3:-}" == "json" ]]; then
  if [[ "${STUB_CLASSES_BROKEN:-0}" == "1" ]]; then
    echo "classes unavailable" >&2
    exit 9
  fi
  if [[ "${STUB_CLASSES_MALFORMED:-0}" == "1" ]]; then
    echo "not-json"
    exit 0
  fi
  if [[ "${STUB_CLASSES_NO_CATEGORY:-0}" == "1" ]]; then
    cat <<'JSON'
{
  "backup": {},
  "nobackup": {},
  "pbs": {},
  "hil_boot": {}
}
JSON
    exit 0
  fi
  cat <<'JSON'
{
  "backup": {"category": "nix"},
  "nobackup": {"category": "nix"},
  "pbs": {"category": "vendor"},
  "hil_boot": {"category": "nix"},
  "dns": {"category": "nix"}
}
JSON
  exit 0
fi
echo "unexpected vm-scope invocation: $*" >&2
exit 9
EOF
chmod +x "$CLASSES"

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
query="${2:-}"
file="${4:-${3:-}}"
case "$query" in
  ".nodes[] | [.name, .mgmt_ip] | @tsv")
    printf 'pve01\t127.0.0.1\n'
    ;;
  ".")
    case "$file" in
      *config.yaml)
        cat <<'JSON'
{"nodes":[{"name":"pve01","mgmt_ip":"127.0.0.1"}],"vms":{"backup_dev":{"vmid":303,"backup":true},"nobackup_dev":{"vmid":304,"backup":false},"pbs":{"vmid":190,"backup":true},"hil_boot":{"vmid":170,"backup":false},"dns1_dev":{"vmid":301,"backup":false},"dns2_dev":{"vmid":302,"backup":false},"dns1_prod":{"vmid":402,"backup":false},"dns2_prod":{"vmid":401,"backup":false}}}
JSON
        ;;
      *applications.yaml)
        echo '{"applications":{}}'
        ;;
      *)
        echo "unexpected yq json file: $file" >&2
        exit 9
        ;;
    esac
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
if [[ "${STUB_SSH_FAIL:-0}" == "1" ]]; then
  echo "ssh connection failed" >&2
  exit 255
fi
case "$cmd" in
  "qm config 303")
    printf '%s\n' "${QM_303:-scsi0: vmstore:vm-303-disk-0.raw
scsi1: vmstore:vm-303-disk-1.raw
ide2: local:cloudinit}"
    ;;
  "qm config 304")
    if [[ "${STUB_VM_MISSING:-0}" == "1" ]]; then
      echo "configuration file does not exist" >&2
      exit 1
    fi
    printf '%s\n' "${QM_304:-scsi0: vmstore:vm-304-disk-0.raw
ide2: local:cloudinit}"
    ;;
  "qm config 190")
    printf '%s\n' "${QM_190:-scsi0: local:iso/pbs.img}"
    ;;
  "qm config 170")
    printf '%s\n' "${QM_170:-scsi0: vmstore:vm-170-disk-0.raw
ide2: local:cloudinit}"
    ;;
  "qm config 301")
    printf '%s\n' "${QM_301:-scsi0: vmstore:vm-301-disk-0.raw
ide2: local:cloudinit}"
    ;;
  "qm config 302")
    printf '%s\n' "${QM_302:-scsi0: vmstore:vm-302-disk-0.raw
ide2: local:cloudinit}"
    ;;
  "qm config 401")
    printf '%s\n' "${QM_401:-scsi0: vmstore:vm-401-disk-0.raw
ide2: local:cloudinit}"
    ;;
  "qm config 402")
    printf '%s\n' "${QM_402:-scsi0: vmstore:vm-402-disk-0.raw
ide2: local:cloudinit}"
    ;;
  *)
    echo "unexpected ssh command: $*" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"
export VM_TOPOLOGY_CONFIG="$CONFIG"
export VM_TOPOLOGY_APPS_CONFIG="$APPS"
export VM_SCOPE_SCRIPT="$CLASSES"

run_complete() {
  set +e
  OUT="$(bash "$SCRIPT" "$@" 2>&1)"
  RC=$?
  set -e
}

clear_unverifiable_stubs() {
  unset STUB_CLASSES_BROKEN STUB_CLASSES_MALFORMED STUB_CLASSES_NO_CATEGORY \
        STUB_SSH_FAIL STUB_VM_MISSING
}

test_start "VIC.1" "plan-derived mode fails when expected scsi1 is missing"
clear_unverifiable_stubs
export QM_303=$'scsi0: vmstore:vm-303-disk-0.raw\nide2: local:cloudinit'
run_complete 303 --expected-disks scsi0,scsi1
if [[ "$RC" -eq 2 ]] && grep -Fq "missing expected disk(s): scsi1" <<< "$OUT"; then
  test_pass "plan-derived missing scsi1 fails"
else
  test_fail "plan-derived missing scsi1 did not fail"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.2" "nix non-backup VM does not require scsi1"
clear_unverifiable_stubs
unset QM_304
run_complete 304
if [[ "$RC" -eq 0 ]] && grep -Fq "VM 304 complete (scsi0,ide2)" <<< "$OUT"; then
  test_pass "nix non-backup topology is scsi0+ide2"
else
  test_fail "nix non-backup topology check failed"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.3" "nix VM missing scsi0 fails"
clear_unverifiable_stubs
export QM_304=$'ide2: local:cloudinit'
run_complete 304
if [[ "$RC" -eq 2 ]] && grep -Fq "missing expected disk(s): scsi0" <<< "$OUT"; then
  test_pass "nix missing scsi0 fails"
else
  test_fail "nix missing scsi0 did not fail"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.4" "vendor PBS requires scsi0 only, not ide2"
clear_unverifiable_stubs
unset QM_190
run_complete 190
if [[ "$RC" -eq 0 ]] && grep -Fq "VM 190 complete (scsi0)" <<< "$OUT"; then
  test_pass "vendor PBS without ide2 passes"
else
  test_fail "vendor PBS topology check failed"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.5" "vendor PBS missing scsi0 fails"
clear_unverifiable_stubs
export QM_190=$'ide2: local:cloudinit'
run_complete 190
if [[ "$RC" -eq 2 ]] && grep -Fq "missing expected disk(s): scsi0" <<< "$OUT"; then
  test_pass "vendor missing scsi0 fails"
else
  test_fail "vendor missing scsi0 did not fail"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.6" "hil_boot nix no-vdb topology passes with scsi0+ide2"
clear_unverifiable_stubs
unset QM_170
run_complete 170
if [[ "$RC" -eq 0 ]] && grep -Fq "VM 170 complete (scsi0,ide2)" <<< "$OUT"; then
  test_pass "hil_boot no-vdb topology passes"
else
  test_fail "hil_boot topology check failed"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.6a" "numbered DNS instances resolve to dns class"
clear_unverifiable_stubs
unset QM_301 QM_302 QM_401 QM_402
dns_failures=()
for vmid in 301 302 401 402; do
  run_complete "$vmid"
  if [[ "$RC" -ne 0 ]] || ! grep -Fq "VM ${vmid} complete (scsi0,ide2)" <<< "$OUT"; then
    dns_failures+=("vmid=${vmid} rc=${RC} output=${OUT}")
  fi
done
if [[ "${#dns_failures[@]}" -eq 0 ]]; then
  test_pass "dns1_dev, dns2_dev, dns1_prod, and dns2_prod use shared dns topology class"
else
  test_fail "numbered DNS instance topology resolution failed"
  printf '%s\n' "${dns_failures[@]}" >&2
fi

test_start "VIC.7" "vm-scope classes failure returns topology-unverifiable"
clear_unverifiable_stubs
export STUB_CLASSES_BROKEN=1
run_complete 304
if [[ "$RC" -eq 3 ]] && grep -Fq "vm-scope classes query failed" <<< "$OUT"; then
  test_pass "broken vm-scope classes fails as unverifiable"
else
  test_fail "broken vm-scope classes did not return rc=3"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.8" "malformed vm-scope class JSON returns topology-unverifiable"
clear_unverifiable_stubs
export STUB_CLASSES_MALFORMED=1
run_complete 304
if [[ "$RC" -eq 3 ]] && grep -Fq "malformed JSON" <<< "$OUT"; then
  test_pass "malformed class JSON fails as unverifiable"
else
  test_fail "malformed class JSON did not return rc=3"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.9" "missing category in class data returns topology-unverifiable"
clear_unverifiable_stubs
export STUB_CLASSES_NO_CATEGORY=1
run_complete 304
if [[ "$RC" -eq 3 ]] && grep -Fq "unsupported or missing VM category" <<< "$OUT"; then
  test_pass "missing class category fails as unverifiable"
else
  test_fail "missing class category did not return rc=3"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.10" "SSH failure during qm config returns topology-unverifiable"
clear_unverifiable_stubs
export STUB_SSH_FAIL=1
run_complete 304 --expected-disks scsi0
if [[ "$RC" -eq 3 ]] && grep -Fq "qm config query failed" <<< "$OUT"; then
  test_pass "SSH failure fails as unverifiable"
else
  test_fail "SSH failure did not return rc=3"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

test_start "VIC.11" "missing qm config returns topology-unverifiable"
clear_unverifiable_stubs
export STUB_VM_MISSING=1
run_complete 304 --expected-disks scsi0
if [[ "$RC" -eq 3 ]] && grep -Fq "qm config was not found" <<< "$OUT"; then
  test_pass "missing qm config fails as unverifiable"
else
  test_fail "missing qm config did not return rc=3"
  printf 'rc=%s\n%s\n' "$RC" "$OUT" >&2
fi

runner_summary
