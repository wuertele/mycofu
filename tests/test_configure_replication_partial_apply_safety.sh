#!/usr/bin/env bash
# test_configure_replication_partial_apply_safety.sh — #257.
#
# End-to-end, shim-driven coverage of `configure-replication.sh "*"` on
# partially-applied cluster state. #224 wired configure-replication.sh into
# safe-apply.sh's recovery suite on the strength of a code-reading safety
# argument; the existing tests/test_safe_apply_recovery.sh stubs
# configure-replication.sh to a no-op, so it proves the script is INVOKED, not
# that it is SAFE. This test drives the REAL script against three
# partial-apply shapes and asserts the state-safety contract:
#
#   S1 (destroyed-VM orphan + live-VM untouched): one live VM with a healthy
#      replication job on every target, plus a destroyed VM whose replica zvols
#      remain on a target node. The destroyed VM's orphan zvols must be swept
#      by the global-orphan phase, while the live VM's job and replicas must be
#      left completely undisturbed (no pvesh delete, no zfs destroy of its
#      zvols, no re-create).
#
#   S2 (cluster API empty / network blip): `pvesh get /cluster/resources`
#      returns []. The run must destroy NOTHING and create NOTHING — the
#      empty-inventory case must never be read as "every zvol is an orphan".
#      (This complements the synthetic global-orphan WARNING-branch reproducers
#      in tests/test_configure_replication_global_orphans_unbound.sh, which
#      documents that the WARNING branch is unreachable via normal control flow
#      because the empty-MATCHING_VMS early exit fires first. This test pins the
#      end-to-end consequence of that early exit: an empty API is inert.)
#
#   S3 (partial apply — mixed skip/create/orphan): five VMIDs in three states.
#      vm-101 still exists with healthy jobs (must SKIP, untouched); vm-102/103/
#      104 are freshly recreated with no jobs yet (must get new jobs created);
#      vm-105 was destroyed and its replicas remain (must be swept as a global
#      orphan). This is the exact shape #257 calls out; it exercises the
#      GLOBAL_ORPHANS path whose unset-variable bug (#615/#255) motivated the
#      issue.
#
# The safety assertions are DESTROY-SCOPE assertions: the set of zvols the run
# destroys must equal exactly the destroyed VMIDs, never a live VMID. A
# regression that swept live replicas (the catastrophic #624 blast radius) or
# tore down a healthy job would flip these.
#
# Mocking approach: a stateful `ssh` shim emulates pvesh (cluster resources +
# replication jobs), pvesr status, and per-node zvol inventories via
# case-matching on the remote command string. Newly created replication jobs
# are recorded and surfaced back through `pvesr status` as registered+synced so
# the (async) initial-sync gate completes and the full run exits 0. All source
# VMs in these fixtures use the async (dev/24h) seed class so the run never
# blocks on the strict initial-sync wait.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CONFIGURE_SRC="${REPO_ROOT}/framework/scripts/configure-replication.sh"

CASE_REPO=""
CASE_SHIMS=""
RUN_RC=0

# ---------------------------------------------------------------------------
# The stateful ssh shim. Per-node state lives in $SHIM_DIR:
#   vm_data.json          — pvesh get /cluster/resources (live inventory)
#   existing_jobs.json     — pvesh get /cluster/replication (live jobs)
#   zvols_<node>.txt       — full zvol names present on <node>
#   base_status_<node>.txt — pre-existing pvesr status rows for <node>
#   created_jobs.tsv       — <job_id>\t<source_node> appended on pvesh create
#   creates.log/deletes.log/sets.log/destroys.log/artifact_<node>.txt — records
make_ssh_shim() {
  cat > "$1" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail

# Identify the target host and the remote command (always the final argument).
host=""
for a in "$@"; do
  case "$a" in root@*) host="${a#root@}" ;; esac
done
remote="${*: -1}"

case "$host" in
  10.0.0.1) node="pve01" ;;
  10.0.0.2) node="pve02" ;;
  10.0.0.3) node="pve03" ;;
  *) node="unknown" ;;
esac

record() { printf '%s\n' "$1" >> "${SHIM_DIR}/$2"; }

# Emit pvesr status rows for a node: the pre-existing base rows plus a
# registered+synced row for every job created in this run whose source node is
# this node (so the async registration + observe gates pass).
emit_pvesr_status() {
  local n="$1" job src
  [[ -f "${SHIM_DIR}/base_status_${n}.txt" ]] && cat "${SHIM_DIR}/base_status_${n}.txt"
  if [[ -f "${SHIM_DIR}/created_jobs.tsv" ]]; then
    while IFS=$'\t' read -r job src; do
      [[ -z "$job" ]] && continue
      [[ "$src" == "$n" ]] || continue
      # cols: JobID Enabled Target LastSync NextSync Duration FailCount State
      printf '%s 1 target 2026-07-25_10:00:00 2026-07-25_10:01:00 1.0 0 OK\n' "$job"
    done < "${SHIM_DIR}/created_jobs.tsv"
  fi
}

# Extract "vm-<vmid>-" style VMID from a remote command's grep pattern.
# grep -oE is portable across GNU and BSD (macOS) userlands; a sed BRE with
# '\?' is not (BSD sed treats it literally), so avoid it here. The `|| true`
# is load-bearing: the shim runs under `set -euo pipefail`, so a zero-match
# grep (a remote command with no vm-<vmid>- token) would otherwise fail the
# pipeline and abort the shim inside `vmid="$(grep_vmid ...)"` (agy P1).
grep_vmid() { { grep -oE 'vm-[0-9]+-' <<< "$1" || true; } | head -1 | tr -dc '0-9'; }

case "$remote" in
  # --- Order matters: destroy (also contains "zfs list"/"grep vm-") first. ---
  *"zfs destroy"*)
    vmid="$(grep_vmid "$remote")"
    if [[ -n "$vmid" && -f "${SHIM_DIR}/zvols_${node}.txt" ]]; then
      while IFS= read -r z; do
        [[ "$z" == *"vm-${vmid}-"* ]] && record "${node} ${z}" destroys.log
      done < "${SHIM_DIR}/zvols_${node}.txt"
    fi
    ;;
  *"grep -oP"*)
    # Global-orphan VMID scan: emit sorted-unique VMIDs on this node.
    if [[ -f "${SHIM_DIR}/zvols_${node}.txt" ]]; then
      sed -n 's|.*/vm-\([0-9][0-9]*\)-.*|\1|p' "${SHIM_DIR}/zvols_${node}.txt" | sort -un
    fi
    ;;
  *"mycofu-park-"*)
    # Parked-vdb sweep: no parked volumes in these fixtures.
    ;;
  *"pvesh get /cluster/resources"*)
    cat "${SHIM_DIR}/vm_data.json" 2>/dev/null || echo '[]'
    ;;
  *"pvesh get /cluster/replication"*)
    cat "${SHIM_DIR}/existing_jobs.json" 2>/dev/null || echo '[]'
    ;;
  *"pvesh create /cluster/replication"*)
    record "$remote" creates.log
    # Record the created job id and its source node (the home node of the VM,
    # from the live inventory) so pvesr status can report it registered+synced.
    jid="$(sed -n 's/.*--id \([0-9][0-9]*-[0-9]\).*/\1/p' <<< "$remote")"
    if [[ -n "$jid" ]]; then
      cvmid="${jid%-*}"
      src="$(jq -r --argjson v "$cvmid" '.[] | select(.vmid == $v) | .node' \
        "${SHIM_DIR}/vm_data.json" 2>/dev/null | head -1)"
      printf '%s\t%s\n' "$jid" "${src:-pve01}" >> "${SHIM_DIR}/created_jobs.tsv"
    fi
    echo created
    ;;
  *"pvesh delete /cluster/replication/"*)
    record "$remote" deletes.log
    ;;
  *"pvesh set /cluster/replication/"*)
    record "$remote" sets.log
    ;;
  *"pvesr schedule-now"*)
    ;;
  *"pvesr status"*)
    emit_pvesr_status "$node"
    ;;
  *"zfs list"*)
    # Per-VM orphan check: `zfs list ... | grep 'vm-<vmid>-'`. Emit this node's
    # matching zvols so the script sees whether the VM has replicas here.
    vmid="$(grep_vmid "$remote")"
    if [[ -n "$vmid" && -f "${SHIM_DIR}/zvols_${node}.txt" ]]; then
      grep "vm-${vmid}-" "${SHIM_DIR}/zvols_${node}.txt" || true
    fi
    ;;
  *"cat > /etc/repl-policy.vmids.tmp"*)
    cat > "${SHIM_DIR}/artifact_${node}.txt"
    ;;
  *)
    : ;;
esac
exit 0
SSH
  chmod +x "$1"
}

# helper stub: emit a deterministic policy TSV. Every VM is policy-on (col4
# true), dev, async 24h seed class (so the run never hits the strict sync gate).
# Columns: vmid name env policy_on col5 cadence pvesr_schedule cadence_secs seed
make_helper_stub() {
  local dir="$1"; shift
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    echo 'case "$*" in'
    echo '  *"--format tsv"*"--mode all"*)'
    echo '    cat <<'"'"'TSV'"'"''
    for row in "$@"; do printf '%s\n' "$row"; done
    echo 'TSV'
    echo '    ;;'
    echo '  *) exit 2 ;;'
    echo 'esac'
  } > "${dir}/list-replicated-vmids.sh"
  chmod +x "${dir}/list-replicated-vmids.sh"
}

stage_repo() {
  local name="$1"
  CASE_REPO="${TMP_DIR}/${name}/repo"
  CASE_SHIMS="${TMP_DIR}/${name}/shims"
  mkdir -p "${CASE_REPO}/framework/scripts" "${CASE_REPO}/site" "${CASE_SHIMS}"
  cp "$CONFIGURE_SRC" "${CASE_REPO}/framework/scripts/configure-replication.sh"
  chmod +x "${CASE_REPO}/framework/scripts/configure-replication.sh"
  cat > "${CASE_REPO}/site/config.yaml" <<'YAML'
domain: fixture.test
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
  - name: pve02
    mgmt_ip: 10.0.0.2
  - name: pve03
    mgmt_ip: 10.0.0.3
proxmox:
  storage_pool: vmstore
YAML
  make_ssh_shim "${CASE_SHIMS}/ssh"
  cat > "${CASE_SHIMS}/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP
  chmod +x "${CASE_SHIMS}/sleep"
}

# shellcheck disable=SC2120  # extra args are forwarded to configure-replication.sh; cases here pass none
run_configure() {
  local rc=0
  (
    cd "$CASE_REPO"
    SHIM_DIR="$CASE_SHIMS" PATH="$CASE_SHIMS:$PATH" \
      framework/scripts/configure-replication.sh "*" "$@"
  ) >"${CASE_SHIMS}/stdout.txt" 2>"${CASE_SHIMS}/stderr.txt" || rc=$?
  RUN_RC="$rc"
}

# Assertion helpers over the recorded logs.
destroyed_vmids() { # -> sorted-unique VMIDs that had a zvol destroyed
  [[ -s "${CASE_SHIMS}/destroys.log" ]] || return 0
  sed -n 's|.*/vm-\([0-9][0-9]*\)-.*|\1|p' "${CASE_SHIMS}/destroys.log" | sort -un
}
created_vmids() { # -> sorted-unique VMIDs that had a replication job created
  [[ -s "${CASE_SHIMS}/creates.log" ]] || return 0
  sed -n 's/.*--id \([0-9][0-9]*\)-[0-9].*/\1/p' "${CASE_SHIMS}/creates.log" | sort -un
}
created_pairs() { # -> sorted "<job_id> <target>" pairs actually created
  [[ -s "${CASE_SHIMS}/creates.log" ]] || return 0
  # Each create line: "pvesh create ... --id 102-0 ... --target pve02 ...".
  sed -n 's/.*--id \([0-9][0-9]*-[0-9]\).*--target \([a-z0-9]*\).*/\1 \2/p' \
    "${CASE_SHIMS}/creates.log" | sort -u
}
log_empty() { [[ ! -s "${CASE_SHIMS}/$1" ]]; }

# ===========================================================================
# S1: destroyed-VM orphan swept; live VM completely undisturbed.
# ===========================================================================
# 201 lives on pve01 with healthy jobs to pve02 AND pve03 (replicas present on
# both). 205 was destroyed; its replica zvol remains on pve02. Expect: 205
# swept, 201 untouched (no create — already has both jobs; no delete; no
# destroy of 201's zvols).
test_start "S1" "destroyed-VM orphan zvols swept while the live VM's job + replicas are untouched"
stage_repo "s1"
make_helper_stub "${CASE_REPO}/framework/scripts" \
  $'201\tapp-a\tdev\ttrue\tdefault\t24h\t03:00\t86400\tasync'
cat > "${CASE_SHIMS}/vm_data.json" <<'JSON'
[{"vmid":201,"name":"app-a","node":"pve01"}]
JSON
cat > "${CASE_SHIMS}/existing_jobs.json" <<'JSON'
[{"id":"201-0","guest":201,"target":"pve02","schedule":"03:00"},
 {"id":"201-1","guest":201,"target":"pve03","schedule":"03:00"}]
JSON
# 201 primary on pve01; replicas on pve02/pve03 (each backed by a job). 205
# orphan replica lingers on pve02.
printf 'vmstore/data/vm-201-disk-0\n'                            > "${CASE_SHIMS}/zvols_pve01.txt"
printf 'vmstore/data/vm-201-disk-0\nvmstore/data/vm-205-disk-0\n' > "${CASE_SHIMS}/zvols_pve02.txt"
printf 'vmstore/data/vm-201-disk-0\n'                            > "${CASE_SHIMS}/zvols_pve03.txt"
# 201's jobs are healthy on their source node so they are never staled.
printf '201-0 1 pve02 2026-07-25_10:00:00 - 1.0 0 OK\n201-1 1 pve03 2026-07-25_10:00:00 - 1.0 0 OK\n' \
  > "${CASE_SHIMS}/base_status_pve01.txt"
run_configure
S1_DESTROYED="$(destroyed_vmids)"
S1_CREATED="$(created_vmids)"
if [[ "$RUN_RC" -eq 0 ]] \
   && [[ "$S1_DESTROYED" == "205" ]] \
   && [[ -z "$S1_CREATED" ]] \
   && log_empty deletes.log \
   && log_empty sets.log; then
  test_pass "swept exactly VMID 205; VMID 201 untouched (no create, no delete, no schedule-set, no zvol destroy)"
else
  test_fail "S1 destroy-scope/undisturbed contract not met (rc=$RUN_RC, destroyed='$S1_DESTROYED', created='$S1_CREATED')"
  printf -- '--- destroys ---\n%s\n--- creates ---\n%s\n--- deletes ---\n%s\n--- stderr ---\n%s\n' \
    "$(cat "${CASE_SHIMS}/destroys.log" 2>/dev/null)" \
    "$(cat "${CASE_SHIMS}/creates.log" 2>/dev/null)" \
    "$(cat "${CASE_SHIMS}/deletes.log" 2>/dev/null)" \
    "$(cat "${CASE_SHIMS}/stderr.txt" 2>/dev/null)" >&2
fi

# ===========================================================================
# S2: empty cluster API destroys/creates nothing (network-blip safety).
# ===========================================================================
test_start "S2" "empty cluster API (blip) destroys nothing and creates nothing"
stage_repo "s2"
make_helper_stub "${CASE_REPO}/framework/scripts" \
  $'201\tapp-a\tdev\ttrue\tdefault\t24h\t03:00\t86400\tasync'
echo '[]' > "${CASE_SHIMS}/vm_data.json"
echo '[]' > "${CASE_SHIMS}/existing_jobs.json"
# Real replicas exist on nodes; an empty API must NOT cause them to be swept.
printf 'vmstore/data/vm-201-disk-0\n' > "${CASE_SHIMS}/zvols_pve01.txt"
printf 'vmstore/data/vm-201-disk-0\n' > "${CASE_SHIMS}/zvols_pve02.txt"
printf 'vmstore/data/vm-201-disk-0\n' > "${CASE_SHIMS}/zvols_pve03.txt"
run_configure
if [[ "$RUN_RC" -eq 0 ]] \
   && log_empty destroys.log \
   && log_empty creates.log \
   && log_empty deletes.log \
   && grep -q "No VMs found matching" "${CASE_SHIMS}/stdout.txt"; then
  test_pass "empty API is inert: no zvol destroyed, no job created/deleted, exit 0"
else
  test_fail "S2 empty-API inertness not met (rc=$RUN_RC)"
  printf -- '--- destroys ---\n%s\n--- creates ---\n%s\n--- stdout(tail) ---\n%s\n' \
    "$(cat "${CASE_SHIMS}/destroys.log" 2>/dev/null)" \
    "$(cat "${CASE_SHIMS}/creates.log" 2>/dev/null)" \
    "$(tail -5 "${CASE_SHIMS}/stdout.txt" 2>/dev/null)" >&2
fi

# ===========================================================================
# S3: partial apply — mixed skip / create / per-VM-orphan / global-orphan.
# ===========================================================================
# Five live VMs home on pve01, exercising every distinct partial-apply state:
#   101 — already has healthy jobs to pve02/pve03            → SKIP (untouched)
#   102/103/104 — freshly recreated, primaries on pve01 only → new jobs created
#   106 — freshly recreated BUT a stale replica of its prior incarnation lingers
#         on pve02 with NO job → the PER-VM orphan phase (configure-replication.sh
#         "orphan zvols on target nodes") sweeps that stale pve02 replica, then a
#         fresh job is created. Its primary on pve01 must survive.
#   105 — destroyed (absent from the live inventory), replica lingers on pve02 →
#         swept by the GLOBAL-orphan phase.
# 106 vs 105 deliberately separates the per-VM orphan path (live VM, stale
# target replica) from the global-orphan path (dead VMID) so a regression in
# EITHER sweep is caught (codex P2).
test_start "S3" "partial apply: skip + create + per-VM-orphan sweep + global-orphan sweep, exact matrix"
stage_repo "s3"
make_helper_stub "${CASE_REPO}/framework/scripts" \
  $'101\tapp-01\tdev\ttrue\tdefault\t24h\t03:00\t86400\tasync' \
  $'102\tapp-02\tdev\ttrue\tdefault\t24h\t03:00\t86400\tasync' \
  $'103\tapp-03\tdev\ttrue\tdefault\t24h\t03:00\t86400\tasync' \
  $'104\tapp-04\tdev\ttrue\tdefault\t24h\t03:00\t86400\tasync' \
  $'106\tapp-06\tdev\ttrue\tdefault\t24h\t03:00\t86400\tasync'
cat > "${CASE_SHIMS}/vm_data.json" <<'JSON'
[{"vmid":101,"name":"app-01","node":"pve01"},
 {"vmid":102,"name":"app-02","node":"pve01"},
 {"vmid":103,"name":"app-03","node":"pve01"},
 {"vmid":104,"name":"app-04","node":"pve01"},
 {"vmid":106,"name":"app-06","node":"pve01"}]
JSON
cat > "${CASE_SHIMS}/existing_jobs.json" <<'JSON'
[{"id":"101-0","guest":101,"target":"pve02","schedule":"03:00"},
 {"id":"101-1","guest":101,"target":"pve03","schedule":"03:00"}]
JSON
# pve01 holds every live primary (101/102/103/104/106) — none are orphans.
printf 'vmstore/data/vm-101-disk-0\nvmstore/data/vm-102-disk-0\nvmstore/data/vm-103-disk-0\nvmstore/data/vm-104-disk-0\nvmstore/data/vm-106-disk-0\n' \
  > "${CASE_SHIMS}/zvols_pve01.txt"
# pve02: 101's healthy replica (job-backed), 105's dead-VMID orphan (global), and
# 106's stale-but-jobless replica (per-VM orphan).
printf 'vmstore/data/vm-101-disk-0\nvmstore/data/vm-105-disk-0\nvmstore/data/vm-106-disk-0\n' > "${CASE_SHIMS}/zvols_pve02.txt"
# pve03 holds only 101's healthy replica.
printf 'vmstore/data/vm-101-disk-0\n'                             > "${CASE_SHIMS}/zvols_pve03.txt"
printf '101-0 1 pve02 2026-07-25_10:00:00 - 1.0 0 OK\n101-1 1 pve03 2026-07-25_10:00:00 - 1.0 0 OK\n' \
  > "${CASE_SHIMS}/base_status_pve01.txt"
run_configure
S3_DESTROYED="$(destroyed_vmids)"
S3_CREATED="$(created_vmids)"
S3_PAIRS="$(created_pairs)"
# Exact create matrix: source is pve01, so every policy-on VM without an
# existing job gets VMID-0 -> pve02 and VMID-1 -> pve03. 101 (both jobs exist)
# must appear NOWHERE in the matrix.
S3_EXPECTED_PAIRS="$(printf '%s\n' \
  '102-0 pve02' '102-1 pve03' \
  '103-0 pve02' '103-1 pve03' \
  '104-0 pve02' '104-1 pve03' \
  '106-0 pve02' '106-1 pve03' | sort -u)"
if [[ "$RUN_RC" -eq 0 ]] \
   && [[ "$S3_DESTROYED" == $'105\n106' ]] \
   && [[ "$S3_CREATED" == $'102\n103\n104\n106' ]] \
   && [[ "$S3_PAIRS" == "$S3_EXPECTED_PAIRS" ]] \
   && log_empty deletes.log \
   && log_empty sets.log; then
  test_pass "101 skipped; 102/103/104/106 jobs created with exact target matrix; 105 (global) + 106-stale (per-VM) swept; no delete/set"
else
  test_fail "S3 partial-apply contract not met (rc=$RUN_RC, destroyed='$(echo "$S3_DESTROYED" | paste -sd, -)', created='$(echo "$S3_CREATED" | paste -sd, -)')"
  printf -- '--- creates ---\n%s\n--- created_pairs ---\n%s\n--- destroys ---\n%s\n--- deletes ---\n%s\n--- sets ---\n%s\n--- stderr ---\n%s\n' \
    "$(cat "${CASE_SHIMS}/creates.log" 2>/dev/null)" \
    "$S3_PAIRS" \
    "$(cat "${CASE_SHIMS}/destroys.log" 2>/dev/null)" \
    "$(cat "${CASE_SHIMS}/deletes.log" 2>/dev/null)" \
    "$(cat "${CASE_SHIMS}/sets.log" 2>/dev/null)" \
    "$(cat "${CASE_SHIMS}/stderr.txt" 2>/dev/null)" >&2
fi

test_start "S3.guard" "no live VM's job-backed replica or primary is destroyed during the mixed partial apply"
# Non-vacuity: 101/102/103/104 are fully healthy (primary + job-backed replicas)
# and must never appear in the destroy log. 106 IS legitimately swept on pve02
# (its stale, jobless replica), but its PRIMARY on pve01 must survive — assert
# no destroy line targets vm-106 on pve01. A mis-scoped sweep (the #624 blast
# radius) would flip one of these.
S3_BAD=""
for v in 101 102 103 104; do
  grep -q "vm-${v}-" "${CASE_SHIMS}/destroys.log" 2>/dev/null && S3_BAD+="${v} "
done
grep -q "^pve01 .*vm-106-" "${CASE_SHIMS}/destroys.log" 2>/dev/null && S3_BAD+="106-primary "
if [[ -z "$S3_BAD" ]]; then
  test_pass "healthy live replicas (101/102/103/104) and 106's primary untouched; only jobless stale replicas swept"
else
  test_fail "live replica/primary destroyed for: ${S3_BAD}"
  printf -- '--- destroys ---\n%s\n' "$(cat "${CASE_SHIMS}/destroys.log" 2>/dev/null)" >&2
fi

runner_summary
