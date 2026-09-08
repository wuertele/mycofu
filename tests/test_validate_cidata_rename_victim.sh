#!/usr/bin/env bash
# test_validate_cidata_rename_victim.sh — issue #511.
#
# validate.sh's Storage section had no detector for rename-victim cidata: a VM
# config referencing vm-<vmid>-disk-<N> where it should reference the canonical
# vm-<vmid>-cloudinit. The orphan sweep (cleanup-orphan-cidata.sh --dry-run)
# only finds cidata-shaped zvols referenced by NO config; the rename victim IS
# referenced, so it stayed invisible — worse, the migrate-back rename event
# CLEARS the orphan WARN, so a DR-broken cluster validated cleaner than a
# healthy one. DRT-005 2026-07-07: nine VMs carried victim references through
# two green validate.sh runs; when pve02 failed, HA restart of the victims
# failed ("no zvol device link for vm-NNN-disk-N") and 7 VMs were left stopped
# in HA error state, including precious-state influxdb/roon.
#
# This test covers the new cidata_canonical_names_check:
#   1. Static contract — FAIL (not WARN), multi-node survivor scan, snapshot
#      exclusion, zero-config fail-closed, VMID match, sanctioned realignment
#      guidance, and stderr-noise safety tokens.
#   2. Behavioral (executing shim) — the ssh shim runs the check's ACTUAL
#      remote command against fixture /etc/pve trees, so the real awk pipeline
#      (snapshot exclusion, drive-key anchor, file count, sentinel) is
#      exercised, not just the local parser:
#        - active rename victims        => FAIL, names the VMIDs + steps
#        - snapshot-frozen victim        => ignored (awk stops at [snapshot])
#        - description: line w/ cdrom    => ignored (drive-key anchor)
#        - cross-attached other-VMID vol => ignored (VMID must match config)
#        - canonical + ISO + appliance   => PASS (no false positive)
#        - configs exist, no cdrom       => PASS
#        - zero configs (pmxcfs down)    => FAIL (fail-closed)
#   3. Behavioral (canned shim) — transport failure and truncated scan both
#      FAIL (fail-closed); host-key stderr noise does not contaminate the scan.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

VALIDATE="${REPO_ROOT}/framework/scripts/validate.sh"

TMP_DIR="$(mktemp -d -t validate-cidata-rename.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# 1. Static contract
# ---------------------------------------------------------------------------

test_start "contract.a" "cidata_canonical_names_check is wired as FAIL (check_capture), not WARN"
body="$(awk '/^cidata_canonical_names_check\(\)/{f=1} f{print} f&&/^}/{exit}' "$VALIDATE")"
if grep -Fq 'check_capture "cidata drive names are canonical (no rename victims)"' "$VALIDATE" &&
   ! grep -Fq 'check_warn "cidata drive names are canonical' "$VALIDATE" &&
   grep -Fq 'MYCOFU_VALIDATE_ONLY_CIDATA_RENAME' "$VALIDATE"; then
  test_pass "check is invoked via check_capture (FAIL semantics) with an ONLY gate"
else
  test_fail "check must be wired via check_capture, not check_warn"
fi

test_start "contract.b" "detector, robustness guards, and sanctioned guidance are present"
if grep -Fq 'vm-([0-9]+)-disk-[0-9]+$' <<< "$body" &&      # victim regex w/ VMID capture
   grep -Fq 'BASH_REMATCH' <<< "$body" &&                   # VMID-of-volume must match config VMID
   grep -Fq '/^\[/{exit}' <<< "$body" &&                    # snapshot-section exclusion
   grep -Fq '__SCAN_FILES__' <<< "$body" &&                 # zero-config fail-closed
   grep -Fq '__SCAN_DONE__' <<< "$body" &&                  # truncation sentinel
   grep -Fq 'nodes[${i}].mgmt_ip' <<< "$body" &&            # multi-node survivor scan
   grep -Fq 'fail-closed' <<< "$body" &&
   grep -Fq 'realign-cidata.sh' <<< "$body" &&
   grep -Fq '.claude/rules/replication.md' <<< "$body" &&
   grep -Fq '#512' <<< "$body"; then
  test_pass "victim regex+VMID match, snapshot exclusion, fail-closed guards, multi-node, realignment, replication.md, #512"
else
  test_fail "detector/guidance/robustness contract missing"
  printf '%s\n' "$body" >&2
fi

test_start "contract.c" "ssh capture is stderr-noise safe (#506/#507): SSH_OPTS has LogLevel=ERROR, no 2>&1"
ssh_opts_def="$(grep -E '^export SSH_OPTS=' "$VALIDATE")"
if grep -Fq 'SSH_OPTS_ARGS' <<< "$body" &&
   grep -Fq '2>/dev/null' <<< "$body" &&
   ! grep -Fq '2>&1' <<< "$body" &&
   grep -Fq 'LogLevel=ERROR' <<< "$ssh_opts_def"; then
  test_pass "uses SSH_OPTS_ARGS, separates stderr (never 2>&1), and SSH_OPTS carries LogLevel=ERROR"
else
  test_fail "ssh capture is not stderr-noise safe"
  printf 'body:\n%s\nSSH_OPTS: %s\n' "$body" "$ssh_opts_def" >&2
fi

# ---------------------------------------------------------------------------
# Shared fixture repo (validate.sh + minimal config + certbot stub)
# ---------------------------------------------------------------------------

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site" "${SHIM_DIR}"

cp "${VALIDATE}" "${FIXTURE_REPO}/framework/scripts/validate.sh"
cp "${REPO_ROOT}/framework/scripts/vdb-park-lib.sh" "${FIXTURE_REPO}/framework/scripts/vdb-park-lib.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/validate.sh"

cat > "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh" <<'EOF'
#!/usr/bin/env bash
certbot_cluster_expected_mode() { echo "staging"; }
certbot_cluster_expected_url() { echo "https://staging.invalid/directory"; }
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/certbot-cluster.sh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
domain: example.test
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
nas:
  ip: 10.0.0.200
vms:
  pbs:
    ip: 10.0.0.60
  gatus:
    ip: 10.0.0.62
  gitlab:
    ip: 10.0.0.50
replication:
  health_port: 9100
proxmox:
  storage_pool: vmstore
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF

# ---------------------------------------------------------------------------
# Fixture /etc/pve trees (real Proxmox qemu-server conf shapes)
# ---------------------------------------------------------------------------

mkconf() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

# pve-clean: canonical cloudinit, ISO cdrom, and a vendor appliance (no cdrom).
CLEAN="${TMP_DIR}/pve-clean/nodes"
mkconf "${CLEAN}/pve01/qemu-server/160.conf" <<'EOF'
name: cicd
scsi0: vmstore:vm-160-disk-0,size=40G
ide2: vmstore:vm-160-cloudinit,media=cdrom,size=4M
EOF
mkconf "${CLEAN}/pve03/qemu-server/305.conf" <<'EOF'
name: installer
ide2: local:iso/debian-12.iso,media=cdrom
EOF
mkconf "${CLEAN}/pve01/qemu-server/190.conf" <<'EOF'
name: pbs
scsi0: vmstore:vm-190-disk-0,backup=1,size=32G
EOF

# pve-victim: two ACTIVE victims (402,500) plus decoys that must NOT be flagged.
VICTIM="${TMP_DIR}/pve-victim/nodes"
mkconf "${VICTIM}/pve01/qemu-server/302.conf" <<'EOF'
name: dns2-dev
ide2: vmstore:vm-302-cloudinit,media=cdrom,size=4M
EOF
mkconf "${VICTIM}/pve01/qemu-server/402.conf" <<'EOF'
name: dns2-prod
ide2: vmstore:vm-402-disk-1,media=cdrom,size=4M
EOF
mkconf "${VICTIM}/pve03/qemu-server/500.conf" <<'EOF'
name: testapp-dev
ide0: vmstore:vm-500-disk-2,media=cdrom
EOF
# 305: canonical NOW, but a snapshot froze a victim reference — must be ignored
# (realignment cannot fix a snapshot; flagging it would be an unclearable FAIL).
mkconf "${VICTIM}/pve03/qemu-server/305.conf" <<'EOF'
name: installer
ide2: vmstore:vm-305-cloudinit,media=cdrom
[preupgrade]
ide2: vmstore:vm-305-disk-9,media=cdrom
EOF
# 601: a description line that merely contains "media=cdrom" — must be ignored
# (the drive-key anchor excludes non-drive lines).
mkconf "${VICTIM}/pve01/qemu-server/601.conf" <<'EOF'
name: influxdb-prod
description: rebuilt from vmstore:vm-601-disk-1,media=cdrom per runbook
ide2: vmstore:vm-601-cloudinit,media=cdrom
EOF
# 603: a stray cdrom referencing a DIFFERENT VM's disk — not this VM's rename
# victim, so it must be ignored (VMID must match the config).
mkconf "${VICTIM}/pve03/qemu-server/603.conf" <<'EOF'
name: roon-prod
ide3: vmstore:vm-999-disk-1,media=cdrom
EOF

# pve-empty: configs exist but none have a cdrom drive.
EMPTY="${TMP_DIR}/pve-empty/nodes"
mkconf "${EMPTY}/pve01/qemu-server/150.conf" <<'EOF'
name: gitlab
scsi0: vmstore:vm-150-disk-0,size=80G
EOF

# pve-noconfigs: qemu-server dir exists but is empty (models pmxcfs unmounted).
mkdir -p "${TMP_DIR}/pve-noconfigs/nodes/pve01/qemu-server"

# ---------------------------------------------------------------------------
# Executing ssh shim: run the check's REAL remote command (last arg) locally,
# repointing /etc/pve/nodes at the fixture tree. Emits the host-key warning to
# stderr in every mode (a stub cannot honor LogLevel=ERROR) so PASS modes prove
# the 2>/dev/null separation held.
# ---------------------------------------------------------------------------
cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "Warning: Permanently added '10.0.0.11' (ED25519) to the list of known hosts." >&2
cmd="${*: -1}"
case "${CIDATA_SHIM_MODE:-}" in
  transport-fail)
    echo "ssh: connect to host 10.0.0.11 port 22: Connection refused" >&2
    exit 255
    ;;
  truncated)
    # Real scan, but the sentinel is lost mid-flight => must fail closed.
    real="$(printf '%s' "$cmd" | sed "s#/etc/pve/nodes#${CIDATA_FIX_ROOT}#g")"
    bash -c "$real" | grep -v '^__SCAN_DONE__$'
    ;;
  *)
    real="$(printf '%s' "$cmd" | sed "s#/etc/pve/nodes#${CIDATA_FIX_ROOT}#g")"
    bash -c "$real"
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

run_check() {
  local mode="$1" fix_root="${2:-}"
  set +e
  OUTPUT="$(
    cd "${FIXTURE_REPO}" &&
    PATH="${SHIM_DIR}:${PATH}" \
      CIDATA_SHIM_MODE="${mode}" \
      CIDATA_FIX_ROOT="${fix_root}" \
      MYCOFU_VALIDATE_ONLY_CIDATA_RENAME=1 \
      framework/scripts/validate.sh 2>&1
  )"
  STATUS=$?
  set -e
}

# ---------------------------------------------------------------------------
# 2. Behavioral — real remote pipeline against fixture trees
# ---------------------------------------------------------------------------

test_start "behavior.clean" "canonical cloudinit + ISO cdrom + no-cdrom appliance => PASS"
run_check scan "${CLEAN}"
if [[ "${STATUS}" -eq 0 ]] && grep -q '\[PASS\] cidata drive names are canonical' <<< "${OUTPUT}"; then
  test_pass "canonical/ISO/appliance drives do not false-positive"
else
  test_fail "clean cluster did not PASS (status=${STATUS})"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.victim" "active victims => FAIL naming only 402/500 with realignment steps"
run_check scan "${VICTIM}"
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q '\[FAIL\] cidata drive names are canonical' <<< "${OUTPUT}" &&
   grep -q 'VM 402' <<< "${OUTPUT}" &&
   grep -q 'VM 500' <<< "${OUTPUT}" &&
   ! grep -q 'VM 302' <<< "${OUTPUT}" &&
   ! grep -q 'VM 305' <<< "${OUTPUT}" &&   # snapshot-frozen victim ignored
   ! grep -q 'VM 601' <<< "${OUTPUT}" &&   # description line ignored
   ! grep -q 'VM 603' <<< "${OUTPUT}" &&   # cross-attach other-VMID ignored
   grep -q 'realign-cidata.sh --vmid 402' <<< "${OUTPUT}" &&
   grep -q 'realign-cidata.sh --vmid 500' <<< "${OUTPUT}"; then
  test_pass "only active victims 402/500 flagged; snapshot/description/cross-attach decoys ignored"
else
  test_fail "victim detection or decoy handling wrong (status=${STATUS})"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.empty" "configs exist but none have a cdrom drive => PASS"
run_check scan "${EMPTY}"
if [[ "${STATUS}" -eq 0 ]] && grep -q '\[PASS\] cidata drive names are canonical' <<< "${OUTPUT}"; then
  test_pass "cluster with no cdrom drives passes"
else
  test_fail "empty-cdrom scan did not PASS (status=${STATUS})"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.noconfigs" "zero VM configs read (pmxcfs unmounted) => FAIL (fail-closed)"
run_check scan "${TMP_DIR}/pve-noconfigs/nodes"
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q '\[FAIL\] cidata drive names are canonical' <<< "${OUTPUT}" &&
   grep -q 'read 0 VM configs' <<< "${OUTPUT}"; then
  test_pass "empty config tree fails closed instead of validating green"
else
  test_fail "zero-config scan did not fail closed (status=${STATUS})"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.stderr-noise" "host-key warning on stderr must not contaminate the scan (#506/#507)"
run_check scan "${CLEAN}"
if [[ "${STATUS}" -eq 0 ]] && ! grep -q 'Permanently added' <<< "${OUTPUT}"; then
  test_pass "stderr warning did not reach the parsed drive lines"
else
  test_fail "stderr warning contaminated the scan (status=${STATUS})"
  printf '%s\n' "${OUTPUT}" >&2
fi

# ---------------------------------------------------------------------------
# 3. Behavioral — transport / truncation fail-closed
# ---------------------------------------------------------------------------

test_start "behavior.transport-fail" "ssh transport failure => FAIL (fail-closed)"
run_check transport-fail ""
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q '\[FAIL\] cidata drive names are canonical' <<< "${OUTPUT}" &&
   grep -q 'fail-closed' <<< "${OUTPUT}"; then
  test_pass "unreachable cluster fails closed instead of validating green"
else
  test_fail "transport failure did not fail closed (status=${STATUS})"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.truncated" "missing __SCAN_DONE__ sentinel (even with a victim visible) => FAIL (fail-closed)"
run_check truncated "${VICTIM}"
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q '\[FAIL\] cidata drive names are canonical' <<< "${OUTPUT}" &&
   grep -q 'fail-closed' <<< "${OUTPUT}"; then
  test_pass "truncated scan fails closed"
else
  test_fail "truncated scan did not fail closed (status=${STATUS})"
  printf '%s\n' "${OUTPUT}" >&2
fi

runner_summary
