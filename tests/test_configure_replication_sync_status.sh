#!/usr/bin/env bash
# test_configure_replication_sync_status.sh — #502 regression.
#
# configure-replication.sh must verify the actual initial-sync JOB OUTCOME
# (LastSync != "-" AND FailCount == 0), not mere job presence, and must FAIL
# LOUDLY (exit non-zero) when a created job never completed a successful sync.
# This is a G4 data-protection gate: a check that cannot confirm sync success
# must fail, not pass.
#
# The core of this test is END-TO-END: it runs the real script with shimmed
# `ssh`/`yq`/`sleep`/`pvesh` and a fake `pvesr status`, and asserts the exit
# code and stderr for the concrete #502 fixture, a healthy fixture, and an
# unreachable-node fixture. A few structural assertions guard the predicate.
# shellcheck disable=SC2016

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIGURE="${REPO_ROOT}/framework/scripts/configure-replication.sh"

# --- Structural guards (cheap, catch obvious regressions in the predicate) ---

wait_block() {
  awk '
    /==> Waiting for initial replication sync/ { in_blk=1 }
    in_blk { print }
    in_blk && /^fi$/ { exit }
  ' "$CONFIGURE"
}
BLK="$(wait_block)"

test_start "502.a" "wait loop inspects LastSync and treats '-' as not-synced"
if grep -Fq 'r_last' <<< "$BLK" && grep -Fq '"-"' <<< "$BLK"; then
  test_pass "LastSync='-' is checked"
else
  test_fail "LastSync check missing"; printf '%s\n' "$BLK" >&2
fi

test_start "502.b" "wait loop fails a job whose FailCount is non-zero OR non-numeric (no fail-open coercion)"
# Nonzero check has two accepted shapes:
#   arithmetic:  [[ "$r_fail" -gt 0 ]]      (original)
#   string-match: [[ ! "$r_fail" =~ ^0+$ ]] (#594-adjacent octal-safe form)
# Both are equivalent given the earlier `^[0-9]+$` shape guard.
if grep -Eq 'r_fail.*=~.*\^\[0-9\]\+\$' <<< "$BLK" \
   && { grep -Eq 'r_fail.*-gt 0' <<< "$BLK" || grep -Eq '!.*"[^"]*r_fail[^"]*".*=~.*\^0\+\$' <<< "$BLK"; }; then
  test_pass "non-numeric FailCount is not coerced to 0; nonzero fails (arithmetic or string-match)"
else
  test_fail "FailCount predicate is fail-open or missing"; printf '%s\n' "$BLK" >&2
fi

test_start "502.c" "the old presence-only 'grep -cv OK\$' proxy is gone"
if grep -Fq "grep -cv 'OK\$'" "$CONFIGURE" || grep -Fq 'grep -cv "OK$"' "$CONFIGURE"; then
  test_fail "presence-only staleness proxy still present"
else
  test_pass "presence-only proxy removed"
fi

test_start "502.d" "unconfirmable job (absent from pvesr) is fail-closed; loop exits non-zero"
if grep -Fq 'not found in pvesr status' <<< "$BLK" && grep -Fq 'exit 1' <<< "$BLK"; then
  test_pass "missing job counts as not-synced and the loop exits 1"
else
  test_fail "missing-job case not fail-closed"; printf '%s\n' "$BLK" >&2
fi

# --- End-to-end harness ---------------------------------------------------
# Build a shim directory that fakes every external command the script calls,
# feeding a scripted `pvesr status` per node so we can drive the wait loop
# deterministically without a cluster.
make_harness() {
  local dir="$1"
  mkdir -p "$dir"

  # yq: answer the exact queries the script issues against config.yaml.
  cat > "$dir/yq" <<'YQ'
#!/usr/bin/env bash
# Minimal yq stub: only the queries configure-replication.sh makes.
if [[ "${1:-}" == "-o=json" ]]; then
  target="${!#}"
  case "$target" in
    *applications.yaml) echo '{"applications":{}}' ;;
    *) echo '{"vms":{"gitlab":{"vmid":150,"backup":true}}}' ;;
  esac
  exit 0
fi
q="$*"
case "$q" in
  *".nodes[0].mgmt_ip"*)          echo "10.0.0.1" ;;
  *".nodes[].name"*)              printf '%s\n' pve01 pve02 pve03 ;;
  *".proxmox.storage_pool"*)      echo "vmstore" ;;
  *'select(.name == "pve01")'*)   echo "10.0.0.1" ;;
  *'select(.name == "pve02")'*)   echo "10.0.0.2" ;;
  *'select(.name == "pve03")'*)   echo "10.0.0.3" ;;
  *) echo "" ;;
esac
YQ

  # ssh: dispatch on the remote command. pvesr status output is driven by
  # fixture files named pvesr_<nodeip-lastoctet>.txt in the shim dir.
  cat > "$dir/ssh" <<'SSH'
#!/usr/bin/env bash
# Args include flags, then root@IP, then the remote command string.
host=""; for a in "$@"; do case "$a" in root@*) host="${a#root@}";; esac; done
remote="${!#}"   # last arg is the remote command
octet="${host##*.}"
case "$remote" in
  *"pvesr status"*)
    f="${SHIM_DIR}/pvesr_${octet}.txt"
    if [[ -f "$f" ]]; then cat "$f"; else exit 0; fi
    ;;
  *"pvesh get /cluster/resources"*)
    # One matching policy-on VM by default; tests can override with vm_data.json.
    if [[ -f "${SHIM_DIR}/vm_data.json" ]]; then
      cat "${SHIM_DIR}/vm_data.json"
    else
      echo '[{"vmid":150,"name":"gitlab","node":"pve01"}]'
    fi
    ;;
  *"pvesh get /cluster/replication"*)
    echo '[]'
    ;;
  *"zfs list"*)  exit 0 ;;   # no orphan/park zvols
  *"pvesh create /cluster/replication"*)
    # record that a create happened; succeed
    echo "created" ;;
  *"pvesr schedule-now"*)
    jid=$(printf '%s\n' "$remote" | sed -E 's|.*pvesr schedule-now ([^[:space:]]+).*|\1|')
    printf '%s\n' "$jid" >> "${SHIM_DIR}/schedule_now.log"
    ;;
  *"pvesh delete"*) exit 0 ;;
  *) exit 0 ;;
esac
SSH

  # sleep: no-op so the 30-attempt loop returns instantly.
  cat > "$dir/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP

  # seq/mktemp/awk/grep/etc come from the real PATH; only override the above.
  chmod +x "$dir/yq" "$dir/ssh" "$dir/sleep"
}

run_configure() {
  # $1 = shim dir (with fixtures already written). Runs the real script.
  local dir="$1"
  # Provide a config.yaml path that exists (content is irrelevant — yq stub).
  local cfgdir; cfgdir="$(mktemp -d)"
  mkdir -p "$cfgdir/site"
  echo "domain: example.com" > "$cfgdir/site/config.yaml"
  SHIM_DIR="$dir" PATH="$dir:$PATH" \
    bash -c '
      # Point the script at our throwaway config by copying it into place.
      exec "$0" "*"
    ' "$CONFIGURE" 2>"$dir/stderr.txt"
}

# The script computes CONFIG from its own location, so we cannot easily
# redirect it. Instead, run against the real repo config but override every
# external call. The real site/config.yaml is present in the repo; the yq
# stub answers deterministically regardless, and ssh is fully stubbed.
run_e2e() {
  local dir="$1" rc=0
  SHIM_DIR="$dir" PATH="$dir:$PATH" \
    "$CONFIGURE" "*" >"$dir/stdout.txt" 2>"$dir/stderr.txt" || rc=$?
  echo "$rc"
}

stage_configure_repo() {
  local dir="$1"
  mkdir -p "$dir/repo/framework/scripts" "$dir/repo/site"
  cp "$CONFIGURE" "$dir/repo/framework/scripts/configure-replication.sh"
  chmod +x "$dir/repo/framework/scripts/configure-replication.sh"
  cat > "$dir/repo/site/config.yaml" <<'YAML'
domain: fixture.test
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
  - name: pve02
    mgmt_ip: 10.0.0.2
  - name: pve03
    mgmt_ip: 10.0.0.3
replication:
  health_port: 9100
proxmox:
  storage_pool: vmstore
YAML
}

write_helper_stub() {
  local dir="$1"
  shift
cat > "$dir/repo/framework/scripts/list-replicated-vmids.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"--format tsv"*"--mode all"*)
    cat "${HELPER_TSV_FIXTURE}"
    ;;
  *"--format csv"*"--mode replicated"*)
    awk -F'\t' '$4 == "true" {print $1}' "${HELPER_TSV_FIXTURE}" | paste -sd, -
    ;;
  *"--format csv"*"--mode policy-off"*)
    awk -F'\t' '$4 == "false" {print $1}' "${HELPER_TSV_FIXTURE}" | paste -sd, -
    ;;
  *"--format tsv"*"--mode replicated"*)
    awk -F'\t' '$4 == "true"' "${HELPER_TSV_FIXTURE}"
    ;;
  *"--format tsv"*"--mode policy-off"*)
    awk -F'\t' '$4 == "false"' "${HELPER_TSV_FIXTURE}"
    ;;
  *)
    exit 0
    ;;
esac
HELPER
  chmod +x "$dir/repo/framework/scripts/list-replicated-vmids.sh"
}

run_e2e_staged() {
  local dir="$1" rc=0
  SHIM_DIR="$dir" HELPER_TSV_FIXTURE="$dir/helper.tsv" PATH="$dir:$PATH" \
    "$dir/repo/framework/scripts/configure-replication.sh" "*" >"$dir/stdout.txt" 2>"$dir/stderr.txt" || rc=$?
  echo "$rc"
}

# Fixture rows use the real pvesr column order:
# JobID Enabled Target LastSync NextSync Duration FailCount State...
HEADER='JobID  Enabled  Target       LastSync             NextSync             Duration  FailCount  State'

# --- 502.e: #502 scenario — created job never synced -> exit 1 + loud error --
test_start "502.e" "#502 fixture (LastSync=-, FailCount=2) makes the script exit non-zero"
d="$(mktemp -d)"; make_harness "$d"
# VM 150 lives on pve01, so the script creates 150-0 (->pve02) and 150-1
# (->pve03). Both jobs are sourced from pve01, so both rows appear in pve01's
# pvesr status. Make BOTH fail exactly like #502.
{
  echo "$HEADER"
  printf '150-0  Yes  local/pve02  %s  %s  %s  %s  %s\n' \
    '-' '2026-07-06_19:32:03' '1.560931' '2' "command 'pvesm export ... | pvesm import ...' failed: exit code 1"
  printf '150-1  Yes  local/pve03  %s  %s  %s  %s  %s\n' \
    '-' '2026-07-06_19:32:06' '1.434154' '2' "command 'pvesm export ... | pvesm import ...' failed: exit code 1"
} > "$d/pvesr_1.txt"     # 10.0.0.1 => pve01
: > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"
rc="$(run_e2e "$d")"
if [[ "$rc" -ne 0 ]] && grep -q 'did NOT complete a successful initial sync' "$d/stderr.txt" \
   && grep -q '150-0' "$d/stderr.txt"; then
  test_pass "script exits ${rc} and names the failing job 150-0 in a loud error"
else
  test_fail "script did not fail loudly on the #502 fixture (rc=${rc})"
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
  echo "--- stdout tail ---" >&2; tail -20 "$d/stdout.txt" >&2
fi
rm -rf "$d"

# --- 502.f: healthy scenario — created job synced -> exit 0 -----------------
test_start "502.f" "a genuinely-synced job (LastSync set, FailCount=0) lets the script exit 0"
d="$(mktemp -d)"; make_harness "$d"
{
  echo "$HEADER"
  printf '150-0  Yes  local/pve02  %s  %s  %s  %s  %s\n' \
    '2026-07-06_19:40:00' '2026-07-06_19:41:00' '3.20' '0' 'OK'
  printf '150-1  Yes  local/pve03  %s  %s  %s  %s  %s\n' \
    '2026-07-06_19:40:05' '2026-07-06_19:41:05' '3.10' '0' 'OK'
} > "$d/pvesr_1.txt"
: > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"
rc="$(run_e2e "$d")"
if [[ "$rc" -eq 0 ]] && grep -q 'completed a successful initial sync' "$d/stdout.txt"; then
  test_pass "script exits 0 and reports a successful initial sync"
else
  test_fail "script did not pass on a healthy fixture (rc=${rc})"
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
  echo "--- stdout tail ---" >&2; tail -20 "$d/stdout.txt" >&2
fi
rm -rf "$d"

# --- 502.g: created job absent from all node status -> fail-closed -> exit 1 -
test_start "502.g" "a created job that never appears in any node's pvesr status is fail-closed"
d="$(mktemp -d)"; make_harness "$d"
# Every node's pvesr status is empty — the created jobs 150-0/150-1 are never
# confirmable. The script must NOT report success for a signal it cannot see.
: > "$d/pvesr_1.txt"; : > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"
rc="$(run_e2e "$d")"
if [[ "$rc" -ne 0 ]] && grep -q 'not found in pvesr status' "$d/stderr.txt"; then
  test_pass "unconfirmable created job exits non-zero (fail-closed)"
else
  test_fail "unconfirmable created job did not fail closed (rc=${rc})"
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
fi
rm -rf "$d"

# --- V2.1.h: async registered -> schedule-now + nonfatal seeding ------------
test_start "V2.1.h" "async created job is registered, schedule-now is issued, and seeding remains nonfatal"
d="$(mktemp -d)"; make_harness "$d"; stage_configure_repo "$d"; write_helper_stub "$d"
cat > "$d/helper.tsv" <<'TSV'
160	cicd	shared	true	explicit	24h	03:00	86400	async
TSV
cat > "$d/vm_data.json" <<'JSON'
[
  {"vmid":160,"name":"cicd","node":"pve01"}
]
JSON
{
  echo "$HEADER"
  printf '160-0  Yes  local/pve02  %s  %s  %s  %s  %s\n' \
    '-' '2026-07-06_03:00:00' '-' '0' '-'
  printf '160-1  Yes  local/pve03  %s  %s  %s  %s  %s\n' \
    '-' '2026-07-06_03:00:00' '-' '0' '-'
} > "$d/pvesr_1.txt"
: > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"
rc="$(run_e2e_staged "$d")"
if [[ "$rc" -eq 0 ]] \
   && grep -qx '160-0' "$d/schedule_now.log" \
   && grep -qx '160-1' "$d/schedule_now.log" \
   && grep -q 'SEEDING (async): 160-0' "$d/stdout.txt"; then
  test_pass "async seed was registered, kicked, observed for 90s, and left nonfatal"
else
  test_fail "async registered case did not kick or did not remain nonfatal (rc=${rc})"
  echo "--- stdout ---" >&2; cat "$d/stdout.txt" >&2
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
  echo "--- schedule_now ---" >&2; cat "$d/schedule_now.log" 2>/dev/null >&2 || true
fi
rm -rf "$d"

# --- V2.1.i: async not registered -> fail closed ----------------------------
test_start "V2.1.i" "async created job absent from source pvesr status fails closed"
d="$(mktemp -d)"; make_harness "$d"; stage_configure_repo "$d"; write_helper_stub "$d"
cat > "$d/helper.tsv" <<'TSV'
160	cicd	shared	true	explicit	24h	03:00	86400	async
TSV
cat > "$d/vm_data.json" <<'JSON'
[
  {"vmid":160,"name":"cicd","node":"pve01"}
]
JSON
: > "$d/pvesr_1.txt"; : > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"
rc="$(run_e2e_staged "$d")"
if [[ "$rc" -ne 0 ]] \
   && grep -q 'async job 160-0 not registered' "$d/stderr.txt" \
   && [[ ! -s "$d/schedule_now.log" ]]; then
  test_pass "async registration absence exits non-zero before schedule-now"
else
  test_fail "async registration absence did not fail closed (rc=${rc})"
  echo "--- stdout ---" >&2; cat "$d/stdout.txt" >&2
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
  echo "--- schedule_now ---" >&2; cat "$d/schedule_now.log" 2>/dev/null >&2 || true
fi
rm -rf "$d"

# --- V2.1.j: mixed strict+async -> strict wait covers strict subset ----------
test_start "V2.1.j" "mixed strict+async create waits strictly only on strict jobs"
d="$(mktemp -d)"; make_harness "$d"; stage_configure_repo "$d"; write_helper_stub "$d"
cat > "$d/helper.tsv" <<'TSV'
150	gitlab	shared	true	default-backup	1m	*/1	60	strict
160	cicd	shared	true	explicit	24h	03:00	86400	async
TSV
cat > "$d/vm_data.json" <<'JSON'
[
  {"vmid":150,"name":"gitlab","node":"pve01"},
  {"vmid":160,"name":"cicd","node":"pve01"}
]
JSON
{
  echo "$HEADER"
  printf '150-0  Yes  local/pve02  %s  %s  %s  %s  %s\n' \
    '2026-07-06_19:40:00' '2026-07-06_19:41:00' '3.20' '0' 'OK'
  printf '150-1  Yes  local/pve03  %s  %s  %s  %s  %s\n' \
    '2026-07-06_19:40:05' '2026-07-06_19:41:05' '3.10' '0' 'OK'
  printf '160-0  Yes  local/pve02  %s  %s  %s  %s  %s\n' \
    '-' '2026-07-06_03:00:00' '-' '0' '-'
  printf '160-1  Yes  local/pve03  %s  %s  %s  %s  %s\n' \
    '-' '2026-07-06_03:00:00' '-' '0' '-'
} > "$d/pvesr_1.txt"
: > "$d/pvesr_2.txt"; : > "$d/pvesr_3.txt"
rc="$(run_e2e_staged "$d")"
if [[ "$rc" -eq 0 ]] \
   && grep -q 'All replication jobs completed a successful initial sync' "$d/stdout.txt" \
   && grep -q 'SEEDING (async): 160-0' "$d/stdout.txt" \
   && ! grep -q 'did NOT complete a successful initial sync' "$d/stderr.txt"; then
  test_pass "strict wait passed on strict jobs while async jobs stayed nonfatal"
else
  test_fail "mixed strict+async case did not partition the wait correctly (rc=${rc})"
  echo "--- stdout ---" >&2; cat "$d/stdout.txt" >&2
  echo "--- stderr ---" >&2; cat "$d/stderr.txt" >&2
fi
rm -rf "$d"

runner_summary
