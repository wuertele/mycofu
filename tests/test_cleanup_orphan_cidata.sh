#!/usr/bin/env bash
# Fixture test for framework/scripts/cleanup-orphan-cidata.sh.
#
# Shims ssh, yq, and zfs/qm-over-ssh to simulate a tiny cluster with
# orphan and attached cidata zvols, plus large data zvols matching the
# disk-N pattern that must NOT be touched. Verifies the script:
#   - destroys orphan cidata zvols (canonical and disk-N named)
#   - leaves attached cidata zvols alone
#   - refuses to destroy large zvols even when name matches the pattern
#   - is idempotent (second run finds zero orphans)
#   - --dry-run reports without destroying

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SCRIPT="${REPO_ROOT}/framework/scripts/cleanup-orphan-cidata.sh"

# ----- fixture state -----
# For each "node" (just labels in the fixture), we keep:
#   ${FIXTURE_DIR}/node-<ip>/zvols.tsv      — name<TAB>refer per zvol
#   ${FIXTURE_DIR}/node-<ip>/qm-<vmid>.cfg  — qm config dump per vmid
#   ${FIXTURE_DIR}/destroy.log              — destroy calls
FIXTURE_DIR=""

setup_case() {
  FIXTURE_DIR="${TMP_DIR}/$1"
  mkdir -p "${FIXTURE_DIR}"
  : > "${FIXTURE_DIR}/destroy.log"

  # config.yaml with three nodes
  mkdir -p "${FIXTURE_DIR}/repo/site"
  cat > "${FIXTURE_DIR}/repo/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.51
  - name: pve02
    mgmt_ip: 10.0.0.52
  - name: pve03
    mgmt_ip: 10.0.0.53
proxmox:
  storage_pool: vmstore
EOF

  # shims directory on PATH
  mkdir -p "${FIXTURE_DIR}/shims"

  # ssh shim: dispatches by node IP + command pattern.
  # ssh root@<ip> "zfs list ..."   → cat zvols.tsv for that node
  # ssh root@<ip> "qm config N"    → cat qm-N.cfg for that node (or nothing)
  # ssh root@<ip> "zfs destroy X"  → record in destroy.log, remove from zvols.tsv
  cat > "${FIXTURE_DIR}/shims/ssh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

# Strip option flags up to "root@<ip>"
node_ip=""
remote=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|-q|-A) shift ;;
    -o) shift 2 ;;
    root@*) node_ip="${1#root@}"; shift; remote="$*"; break ;;
    *) shift ;;
  esac
done

[[ -z "${node_ip}" ]] && { echo "shim ssh: missing root@<ip>" >&2; exit 2; }
node_dir="${FIXTURE_DIR}/node-${node_ip}"

if [[ "${remote}" == *"zfs list"* ]]; then
  # Model real zfs semantics: `zfs list -t volume <fs_path>` errors with
  # "operation not applicable to datasets of this type" because <fs_path>
  # is a filesystem, not a volume. The correct invocation is either to
  # pass a volume path, or to add `-r` so zfs recurses from <fs_path>.
  # Without `-r`, the cluster scan silently no-ops on the real cluster —
  # see issue #419. Refuse the non-recursive form here so a regression
  # of the same shape fails the test.
  if [[ "${remote}" != *"zfs list"*" -r "* ]]; then
    # Extract the dataset argument (the last word before any redirect).
    # Strip 2>/dev/null and trailing whitespace, then take the last word.
    dataset=$(printf '%s\n' "${remote%2>/dev/null*}" | awk '{print $NF}')
    echo "cannot open '${dataset}': operation not applicable to datasets of this type (simulated)" >&2
    exit 1
  fi
  # Simulate node unreachability via FIXTURE_DIR/zfs-fail-<ip>.
  if [[ -f "${FIXTURE_DIR}/zfs-fail-${node_ip}" ]]; then
    echo "ssh: connect failed (simulated)" >&2
    exit 255
  fi
  if [[ -f "${node_dir}/zvols.tsv" ]]; then
    cat "${node_dir}/zvols.tsv"
  fi
  exit 0
fi

if [[ "${remote}" == *"qm config"* ]]; then
  vmid="${remote##*qm config }"
  vmid="${vmid%% *}"
  vmid="${vmid%%2>*}"
  vmid="${vmid// /}"
  if [[ -f "${node_dir}/qm-${vmid}.cfg" ]]; then
    cat "${node_dir}/qm-${vmid}.cfg"
    exit 0
  fi
  # No config on this node for this vmid → simulate qm error
  exit 2
fi

# /etc/pve is a cluster-shared filesystem (pmxcfs). The shim models this by
# concatenating every node's qm-<vmid>.cfg fixtures regardless of which node
# the SSH call lands on — matching real Proxmox behavior where any node can
# read every VM's config under /etc/pve/nodes/<owner>/qemu-server/.
#
# If the node is marked "unreachable" via FIXTURE_DIR/unreachable-<ip>,
# return rc=255 to mimic SSH connect-failure (exercises the failover loop).
if [[ "${remote}" == *"/etc/pve/nodes/"* ]]; then
  if [[ -f "${FIXTURE_DIR}/unreachable-${node_ip}" ]]; then
    echo "ssh: connect to ${node_ip}: simulated" >&2
    exit 255
  fi
  found=0
  for dir in "${FIXTURE_DIR}"/node-*; do
    [[ -d "${dir}" ]] || continue
    for cfg in "${dir}"/qm-*.cfg; do
      [[ -f "${cfg}" ]] || continue
      cat "${cfg}"
      found=1
    done
  done
  # grep -h's empty-input rc is 1; mirror that.
  [[ "${found}" -eq 1 ]] && exit 0 || exit 1
fi

if [[ "${remote}" == *"zfs destroy"* ]]; then
  # Detect -r flag (recursive — removes child snapshots).
  recursive=0
  if [[ "${remote}" == *"zfs destroy -r"* ]]; then
    recursive=1
    zvol="${remote##*zfs destroy -r }"
  else
    zvol="${remote##*zfs destroy }"
  fi
  zvol="${zvol%%2>*}"
  zvol="${zvol// /}"

  echo "${node_ip} ${zvol} recursive=${recursive}" >> "${FIXTURE_DIR}/destroy.log"

  # Simulate a forced destroy failure when this zvol is in the
  # ${FIXTURE_DIR}/fail-destroy-for file.
  if [[ -f "${FIXTURE_DIR}/fail-destroy-for" ]] && grep -qF "${zvol}" "${FIXTURE_DIR}/fail-destroy-for"; then
    echo "cannot destroy '${zvol}': filesystem busy (simulated)" >&2
    exit 1
  fi

  # Simulate the @__migration__ child-snapshot case: if the zvol has
  # snapshot markers AND -r was NOT passed, fail like real zfs does.
  if [[ -f "${node_dir}/snapshots-${zvol##*/}" && "${recursive}" -ne 1 ]]; then
    echo "cannot destroy '${zvol}': filesystem has children" >&2
    exit 1
  fi

  # Remove from zvols.tsv to make the operation observable in subsequent runs.
  if [[ -f "${node_dir}/zvols.tsv" ]]; then
    grep -vF "${zvol}	" "${node_dir}/zvols.tsv" > "${node_dir}/zvols.tsv.new" || true
    mv "${node_dir}/zvols.tsv.new" "${node_dir}/zvols.tsv"
  fi
  rm -f "${node_dir}/snapshots-${zvol##*/}"
  exit 0
fi

echo "shim ssh: unhandled command: ${remote}" >&2
exit 1
SHIM
  chmod +x "${FIXTURE_DIR}/shims/ssh"
}

add_zvol() {
  local node_ip="$1" zvol="$2" refer="$3"
  local node_dir="${FIXTURE_DIR}/node-${node_ip}"
  mkdir -p "${node_dir}"
  printf '%s\t%s\n' "${zvol}" "${refer}" >> "${node_dir}/zvols.tsv"
}

# Mark a zvol as having Proxmox's @__migration__ snapshot. The shim's
# `zfs destroy` then refuses to destroy it unless -r is passed (matching
# real zfs semantics).
add_zvol_with_snapshot() {
  local node_ip="$1" zvol="$2" refer="$3"
  add_zvol "${node_ip}" "${zvol}" "${refer}"
  local node_dir="${FIXTURE_DIR}/node-${node_ip}"
  : > "${node_dir}/snapshots-${zvol##*/}"
}

# Make destroy on this zvol fail (to exercise the failure path).
mark_destroy_fails_for() {
  local zvol="$1"
  echo "${zvol}" >> "${FIXTURE_DIR}/fail-destroy-for"
}

add_qm_config() {
  local node_ip="$1" vmid="$2" content="$3"
  local node_dir="${FIXTURE_DIR}/node-${node_ip}"
  mkdir -p "${node_dir}"
  printf '%s\n' "${content}" > "${node_dir}/qm-${vmid}.cfg"
}

run_cleanup() {
  local extra_args=("$@")
  set +e
  (
    export PATH="${FIXTURE_DIR}/shims:${PATH}"
    export FIXTURE_DIR
    # Trick the script into reading our fixture config.yaml by faking the repo root.
    mkdir -p "${FIXTURE_DIR}/repo/framework/scripts"
    cp "${SCRIPT}" "${FIXTURE_DIR}/repo/framework/scripts/cleanup-orphan-cidata.sh"
    chmod +x "${FIXTURE_DIR}/repo/framework/scripts/cleanup-orphan-cidata.sh"
    cd "${FIXTURE_DIR}/repo"
    "${FIXTURE_DIR}/repo/framework/scripts/cleanup-orphan-cidata.sh" "${extra_args[@]+${extra_args[@]}}"
  ) > "${FIXTURE_DIR}/output.log" 2>&1
  local rc=$?
  set -e
  echo "${rc}" > "${FIXTURE_DIR}/exit-code"
  return 0
}

destroy_count() {
  if [[ -f "${FIXTURE_DIR}/destroy.log" ]]; then
    wc -l < "${FIXTURE_DIR}/destroy.log" | tr -d ' '
  else
    echo 0
  fi
}

destroy_log_has() {
  local pattern="$1"
  grep -qF "${pattern}" "${FIXTURE_DIR}/destroy.log" 2>/dev/null
}

output_has() {
  grep -qF "$1" "${FIXTURE_DIR}/output.log"
}

exit_code() {
  cat "${FIXTURE_DIR}/exit-code"
}

# ============================================================================

test_start "C1" "empty cluster yields zero orphans, exit 0"
setup_case "c1"
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "empty cluster exits 0" || test_fail "empty cluster exits 0"
[[ "$(destroy_count)" == "0" ]] && test_pass "empty cluster destroys nothing" || test_fail "empty cluster destroys nothing"
output_has "0 orphan(s) found" && test_pass "summary reports zero" || test_fail "summary reports zero"

test_start "C2" "orphan canonical-named cidata is destroyed"
setup_case "c2"
# pve01 has vm-160-cloudinit zvol but no qm config for 160 → orphan
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
[[ "$(destroy_count)" == "1" ]] && test_pass "destroys exactly one zvol" || test_fail "destroys exactly one zvol"
destroy_log_has "vmstore/data/vm-160-cloudinit" && test_pass "destroys the orphan" || test_fail "destroys the orphan"

test_start "C3" "orphan disk-N-named cidata is destroyed (the rename-victim case)"
setup_case "c3"
# pve03 has vm-160-disk-1 zvol but the vmid was attached to a different node → orphan
add_zvol 10.0.0.53 vmstore/data/vm-160-disk-1 18.5K
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
[[ "$(destroy_count)" == "1" ]] && test_pass "destroys exactly one zvol" || test_fail "destroys exactly one zvol"
destroy_log_has "vmstore/data/vm-160-disk-1" && test_pass "destroys the disk-1 orphan" || test_fail "destroys the disk-1 orphan"

test_start "C4" "attached cidata zvol is NOT destroyed"
setup_case "c4"
# pve01 has vm-160-cloudinit AND a qm config that attaches it
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
add_qm_config 10.0.0.51 160 "ide2: vmstore:vm-160-cloudinit,media=cdrom"
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
[[ "$(destroy_count)" == "0" ]] && test_pass "attached zvol not destroyed" || test_fail "attached zvol not destroyed"

test_start "C5" "large zvol matching disk-N pattern is NOT destroyed (boot disk safety)"
setup_case "c5"
# pve01 has vm-160-disk-0 sized like a boot disk (192G). Even though the name
# matches the cidata regex, the size filter must reject it.
add_zvol 10.0.0.51 vmstore/data/vm-160-disk-0 50G
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
[[ "$(destroy_count)" == "0" ]] && test_pass "large disk not destroyed" || test_fail "large disk not destroyed"

test_start "C6" "mixed: orphan + attached + boot disk → only orphan destroyed"
setup_case "c6"
# Realistic snapshot: cicd VM 160 has attached canonical cidata, boot disk,
# AND a renamed orphan disk-1 left behind by past migration.
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
add_zvol 10.0.0.51 vmstore/data/vm-160-disk-0 50G
add_zvol 10.0.0.51 vmstore/data/vm-160-disk-1 18.5K
add_qm_config 10.0.0.51 160 "ide2: vmstore:vm-160-cloudinit,media=cdrom
scsi0: vmstore:vm-160-disk-0,size=192G"
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
[[ "$(destroy_count)" == "1" ]] && test_pass "destroys exactly one zvol (the orphan)" || test_fail "destroys exactly one zvol (the orphan)"
destroy_log_has "vmstore/data/vm-160-disk-1" && test_pass "destroys the disk-1 orphan" || test_fail "destroys the disk-1 orphan"

test_start "C7" "idempotency: second run finds zero orphans"
setup_case "c7"
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
run_cleanup
[[ "$(destroy_count)" == "1" ]] && test_pass "first run destroys one" || test_fail "first run destroys one"
# Second run: nothing left
run_cleanup
[[ "$(destroy_count)" == "1" ]] && test_pass "second run destroys nothing additional" || test_fail "second run destroys nothing additional"
output_has "0 orphan(s) found" && test_pass "second-run summary is zero" || test_fail "second-run summary is zero"

test_start "C8" "--dry-run reports but does not destroy"
setup_case "c8"
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
add_zvol 10.0.0.53 vmstore/data/vm-160-disk-1 18.5K
run_cleanup --dry-run
[[ "$(exit_code)" -eq 0 ]] && test_pass "dry-run exits 0" || test_fail "dry-run exits 0"
[[ "$(destroy_count)" == "0" ]] && test_pass "dry-run destroys nothing" || test_fail "dry-run destroys nothing"
output_has "Summary (dry-run): 2 orphan(s) found" && test_pass "dry-run reports orphan count" || test_fail "dry-run reports orphan count"

test_start "C9" "zvol attached on a DIFFERENT node is NOT destroyed from that node"
setup_case "c9"
# vm-150-cloudinit lives on pve03 (gitlab's actual case)
add_zvol 10.0.0.53 vmstore/data/vm-150-cloudinit 18.5K
add_qm_config 10.0.0.53 150 "ide2: vmstore:vm-150-cloudinit,media=cdrom"
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
[[ "$(destroy_count)" == "0" ]] && test_pass "attached on its own node not destroyed" || test_fail "attached on its own node not destroyed"

test_start "C10" "destroy uses -r to clear @__migration__ snapshots"
setup_case "c10"
# This is the live cicd shape: orphan cidata zvol with a Proxmox
# @__migration__ snapshot attached, as left behind on the source node
# after a migration. Real `zfs destroy` (no -r) fails with "filesystem
# has children" on these. The script must pass -r.
add_zvol_with_snapshot 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0 (snapshot did not block destroy)" || test_fail "exits 0 (snapshot did not block destroy)"
[[ "$(destroy_count)" == "1" ]] && test_pass "destroyed exactly one zvol" || test_fail "destroyed exactly one zvol"
grep -q "recursive=1" "${FIXTURE_DIR}/destroy.log" && test_pass "destroy used -r" || test_fail "destroy used -r"

test_start "C11" "destroy failure reports rc=1 and is counted"
setup_case "c11"
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
mark_destroy_fails_for "vmstore/data/vm-160-cloudinit"
run_cleanup
[[ "$(exit_code)" -eq 1 ]] && test_pass "script exits 1 when destroy fails" || test_fail "script exits 1 when destroy fails"
output_has "DESTROY FAILED" && test_pass "failure is logged" || test_fail "failure is logged"
output_has "1 failed" && test_pass "summary includes failed count" || test_fail "summary includes failed count"

test_start "C12" "rename-victim explicit: cidata-shaped zvol, qm config exists for VMID but does not reference this zvol"
setup_case "c12"
# This is the rename-victim case spelled out: pve01 hosts cicd (160).
# qm config 160 references vm-160-cloudinit (the canonical name).
# pve01 ALSO holds vm-160-disk-1 — a smaller copy left over from a
# prior migration cycle where Proxmox renamed during import. The script
# must destroy disk-1 (not referenced) and leave cloudinit alone.
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
add_zvol 10.0.0.51 vmstore/data/vm-160-disk-1 18.5K
add_qm_config 10.0.0.51 160 "ide2: vmstore:vm-160-cloudinit,media=cdrom"
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
[[ "$(destroy_count)" == "1" ]] && test_pass "destroys exactly one" || test_fail "destroys exactly one"
destroy_log_has "vmstore/data/vm-160-disk-1" && test_pass "destroys the rename-victim" || test_fail "destroys the rename-victim"
! destroy_log_has "vmstore/data/vm-160-cloudinit" && test_pass "leaves the attached canonical zvol alone" || test_fail "leaves the attached canonical zvol alone"

test_start "C13" "ZFS replication target: zvol exists on Node A while VM owned by Node B"
setup_case "c13"
# gitlab (150) is owned by pve03. Its boot disk vm-150-disk-0 is replicated
# from pve03 to pve01 and pve02 so HA can restart there. On pve01, qm config
# 150 does NOT exist (config lives under /etc/pve/nodes/pve03/...), but the
# zvol IS attached to gitlab cluster-wide. The script must read the
# cluster-wide attached set (from /etc/pve) and NOT destroy the replica.
add_zvol 10.0.0.51 vmstore/data/vm-150-disk-0 668M
add_zvol 10.0.0.52 vmstore/data/vm-150-disk-0 668M
add_zvol 10.0.0.53 vmstore/data/vm-150-disk-0 668M
add_qm_config 10.0.0.53 150 "scsi0: vmstore:vm-150-disk-0,size=669M"
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
[[ "$(destroy_count)" == "0" ]] && test_pass "replicated data disk NOT destroyed on any node" || test_fail "replicated data disk NOT destroyed on any node"

test_start "C14" "Small replicated zvol: cluster-wide attached check protects cross-node copies"
setup_case "c14"
# Hypothetical: a VM with a small (sub-1MiB) data disk that's replicated.
# The size filter alone would destroy this. The cluster-wide attached
# check prevents destruction because the zvol IS attached on its owner.
add_zvol 10.0.0.51 vmstore/data/vm-200-disk-0 800K
add_zvol 10.0.0.53 vmstore/data/vm-200-disk-0 800K
add_qm_config 10.0.0.53 200 "scsi0: vmstore:vm-200-disk-0,size=1G"
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0" || test_fail "exits 0"
[[ "$(destroy_count)" == "0" ]] && test_pass "small replicated zvol NOT destroyed" || test_fail "small replicated zvol NOT destroyed"

# Helper for failover/fail-closed tests.
mark_node_unreachable() {
  local node_ip="$1"
  : > "${FIXTURE_DIR}/unreachable-${node_ip}"
}

test_start "C15" "failover: first node's /etc/pve unreachable, second node succeeds"
setup_case "c15"
# pve01 (NODE_IPS[0]) is unreachable for the /etc/pve read. pve02 and pve03
# work. The script should warn about pve01, try pve02, succeed, and proceed
# to per-node zfs sweep — which still destroys the orphan on pve01 itself.
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
mark_node_unreachable 10.0.0.51
run_cleanup
[[ "$(exit_code)" -eq 0 ]] && test_pass "exits 0 after failover" || test_fail "exits 0 after failover"
output_has "could not read /etc/pve on 10.0.0.51" && test_pass "warns about first-node failure" || test_fail "warns about first-node failure"
destroy_log_has "vmstore/data/vm-160-cloudinit" && test_pass "orphan still destroyed via failover-read attached set" || test_fail "orphan still destroyed via failover-read attached set"

test_start "C16" "fail-closed: all nodes' /etc/pve unreachable"
setup_case "c16"
# All three nodes reject /etc/pve reads. There's an orphan that WOULD be
# destroyed if the attached set could be confirmed empty. The script must
# refuse to proceed rather than treat an unverifiable empty set as
# permission to destroy.
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
mark_node_unreachable 10.0.0.51
mark_node_unreachable 10.0.0.52
mark_node_unreachable 10.0.0.53
run_cleanup
[[ "$(exit_code)" -eq 1 ]] && test_pass "exits 1 when all nodes unreachable" || test_fail "exits 1 when all nodes unreachable"
output_has "refusing to proceed" && test_pass "refusal message present" || test_fail "refusal message present"
[[ "$(destroy_count)" == "0" ]] && test_pass "nothing destroyed when attached set unverifiable" || test_fail "nothing destroyed when attached set unverifiable"

# Helper: simulate per-node zfs list failure (e.g. SSH connect timeout
# after the /etc/pve read succeeded).
mark_zfs_fail_on() {
  local node_ip="$1"
  : > "${FIXTURE_DIR}/zfs-fail-${node_ip}"
}

test_start "C17" "fail-closed when per-node zfs list scan fails (codex R1 P2)"
setup_case "c17"
# /etc/pve read succeeds (no nodes marked unreachable) but the per-node
# zfs list on pve02 fails. With the old swallow-and-continue behavior the
# script would print "0 orphan(s) found" and exit 0 — masking that we
# never saw pve02. The fix makes scan failures bump SCAN_FAILURES and
# exit 1, so validate.sh treats this as a real failure rather than PASS.
add_zvol 10.0.0.51 vmstore/data/vm-160-cloudinit 18.5K
add_qm_config 10.0.0.51 160 "ide2: vmstore:vm-160-cloudinit,media=cdrom"
mark_zfs_fail_on 10.0.0.52
run_cleanup
[[ "$(exit_code)" -eq 1 ]] && test_pass "exits 1 when any node's scan fails" || test_fail "exits 1 when any node's scan fails"
output_has "could not list zvols on 10.0.0.52" && test_pass "warns about failing node" || test_fail "warns about failing node"
output_has "1 scan failure" && test_pass "summary reports scan failure count" || test_fail "summary reports scan failure count"

runner_summary
