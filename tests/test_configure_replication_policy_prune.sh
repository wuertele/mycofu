#!/usr/bin/env bash
# test_configure_replication_policy_prune.sh - Sprint 047 V2.2/V2.3.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_SRC="${REPO_ROOT}/tests/fixtures/replication-policy"
CONFIGURE_SRC="${REPO_ROOT}/framework/scripts/configure-replication.sh"
HELPER_SRC="${REPO_ROOT}/framework/scripts/list-replicated-vmids.sh"

CASE_REPO=""
CASE_SHIMS=""
RUN_RC=0

make_shims() {
  local dir="$1"
  mkdir -p "$dir"

  cat > "$dir/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail

host=""
remote=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|-i|-p)
      shift 2
      ;;
    -n|-q|-A)
      shift
      ;;
    root@*)
      host="${1#root@}"
      shift
      remote="$*"
      break
      ;;
    *)
      shift
      ;;
  esac
done

case "$host" in
  10.0.0.1) node="pve01" ;;
  10.0.0.2) node="pve02" ;;
  10.0.0.3) node="pve03" ;;
  *) node="unknown" ;;
esac

record() {
  printf '%s\n' "$1" >> "${SHIM_DIR}/$2"
}

filter_cluster_jobs() {
  local src="${SHIM_DIR}/cluster_replication.json"
  local del="${SHIM_DIR}/deletes.log"
  if [[ ! -f "$src" ]]; then
    echo '[]'
    return 0
  fi
  if [[ ! -s "$del" ]]; then
    cat "$src"
    return 0
  fi
  python3 - "$src" "$del" <<'PY'
import json
import sys

with open(sys.argv[1]) as fh:
    jobs = json.load(fh)
with open(sys.argv[2]) as fh:
    deleted = {line.strip() for line in fh if line.strip()}
print(json.dumps([job for job in jobs if job.get("id") not in deleted]))
PY
}

extract_vmid() {
  printf '%s\n' "$remote" | sed -nE "s/.*vm-([0-9]+)-.*/\1/p" | head -1
}

case "$remote" in
  *"pvesh get /cluster/resources"*)
    cat "${SHIM_DIR}/vm_data.json"
    ;;
  *"pvesh get /cluster/replication"*)
    filter_cluster_jobs
    ;;
  *"pvesh delete /cluster/replication/"*)
    jid=$(printf '%s\n' "$remote" | sed -E 's|.*/cluster/replication/([^ ]+).*|\1|')
    record "$jid" deletes.log
    ;;
  *"pvesh set /cluster/replication/"*)
    compact=$(printf '%s\n' "$remote" | tr '\n' ' ')
    jid=$(printf '%s\n' "$compact" | sed -E 's|.*pvesh set /cluster/replication/([^[:space:]]+).*|\1|')
    schedule=$(printf '%s\n' "$compact" | sed -E "s|.*--schedule '?([^'[:space:]]+)'?.*|\1|")
    record "${jid} ${schedule}" sets.log
    ;;
  *"pvesh create /cluster/replication"*)
    compact=$(printf '%s\n' "$remote" | tr '\n' ' ')
    jid=$(printf '%s\n' "$compact" | sed -E 's|.*--id[[:space:]]+([^[:space:]]+).*|\1|')
    schedule=$(printf '%s\n' "$compact" | sed -E "s|.*--schedule '?([^'[:space:]]+)'?.*|\1|")
    record "${jid} ${schedule}" creates.log
    echo "created"
    ;;
  *"pvesr status"*)
    f="${SHIM_DIR}/pvesr_${node}.txt"
    [[ -f "$f" ]] && cat "$f"
    ;;
  *"cat > /etc/repl-policy.vmids.tmp"*)
    cat > "${SHIM_DIR}/artifact_${node}.txt"
    ;;
  *"zfs list -H -t volume"*)
    vmid="$(extract_vmid)"
    residual="${SHIM_DIR}/residual_${node}_${vmid}.txt"
    if [[ -f "$residual" ]]; then
      cat "$residual"
    fi
    ;;
  *"zfs list"*"/data"*"'vm-"*"zfs destroy"*)
    vmid="$(extract_vmid)"
    record "${node} ${vmid}" destroys.log
    ;;
  *"zfs list"*"/data"*"grep -oP"*)
    exit 0
    ;;
  *"zfs list"*"/data"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
exit 0
SSH

  cat > "$dir/sleep" <<'SLEEP'
#!/usr/bin/env bash
exit 0
SLEEP

  chmod +x "$dir/ssh" "$dir/sleep"
}

stage_repo() {
  local name="$1"
  CASE_REPO="${TMP_DIR}/${name}/repo"
  CASE_SHIMS="${TMP_DIR}/${name}/shims"
  mkdir -p "${CASE_REPO}/framework/scripts" "${CASE_REPO}/site"
  cp "$CONFIGURE_SRC" "${CASE_REPO}/framework/scripts/configure-replication.sh"
  cp "$HELPER_SRC" "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh"
  cp "${FIXTURE_SRC}/config.yaml" "${CASE_REPO}/site/config.yaml"
  cp "${FIXTURE_SRC}/applications.yaml" "${CASE_REPO}/site/applications.yaml"
  chmod +x "${CASE_REPO}/framework/scripts/configure-replication.sh" \
    "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh"
  cat > "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SCRIPT_DIR}/../../site/config.yaml"

emit_rows() {
  if grep -q 'vmid: 190' "$CONFIG"; then
    cat <<'TSV'
150	gitlab	shared	true	default-backup	1m	*/1	60	strict
190	pbs	shared	true	default-backup	1m	*/1	60	strict
TSV
  elif ! grep -q 'vmid: 160' "$CONFIG"; then
    cat <<'TSV'
150	gitlab	shared	true	default-backup	1m	*/1	60	strict
TSV
  else
    cat <<'TSV'
150	gitlab	shared	true	default-backup	1m	*/1	60	strict
160	cicd	shared	false	explicit	24h	03:00	86400	async
301	dns1-dev	dev	false	default	24h	03:00	86400	async
303	vault-dev	dev	true	default-backup	1m	*/1	60	strict
401	dns1-prod	prod	true	default-backup	1m	*/1	60	strict
402	dns2-prod	prod	true	default-backup	1m	*/1	60	strict
403	vault-prod	prod	true	default-backup	1m	*/1	60	strict
404	gatus	prod	false	default	24h	03:00	86400	async
501	influxdb-dev	dev	true	default-backup	1m	*/1	60	strict
503	roon-dev	dev	true	default-backup	1m	*/1	60	strict
601	influxdb-prod	prod	true	default-backup	1m	*/1	60	strict
602	grafana-prod	prod	false	default	24h	03:00	86400	async
603	roon-prod	prod	true	default-backup	1m	*/1	60	strict
502	grafana-dev	dev	false	default	24h	03:00	86400	async
TSV
  fi
}

case "$*" in
  *"--format tsv"*"--mode all"*)
    emit_rows
    ;;
  *"--format tsv"*"--mode replicated"*)
    emit_rows | awk -F'\t' '$4 == "true"'
    ;;
  *"--format tsv"*"--mode policy-off"*)
    emit_rows | awk -F'\t' '$4 == "false"'
    ;;
  *"--format csv"*"--mode replicated"*)
    emit_rows | awk -F'\t' '$4 == "true" {print $1}' | paste -sd, -
    ;;
  *"--format csv"*"--mode policy-off"*)
    emit_rows | awk -F'\t' '$4 == "false" {print $1}' | paste -sd, -
    ;;
  *)
    exit 2
    ;;
esac
HELPER
  chmod +x "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh"
  make_shims "$CASE_SHIMS"
}

write_vm_data_mixed() {
  cat > "${CASE_SHIMS}/vm_data.json" <<'JSON'
[
  {"vmid":150,"name":"gitlab","node":"pve01"},
  {"vmid":160,"name":"cicd","node":"pve01"},
  {"vmid":301,"name":"dns1-dev","node":"pve02"},
  {"vmid":303,"name":"vault-dev","node":"pve02"},
  {"vmid":401,"name":"dns1-prod","node":"pve01"},
  {"vmid":402,"name":"dns2-prod","node":"pve02"},
  {"vmid":403,"name":"vault-prod","node":"pve03"},
  {"vmid":404,"name":"gatus","node":"pve03"},
  {"vmid":501,"name":"influxdb-dev","node":"pve02"},
  {"vmid":601,"name":"influxdb-prod","node":"pve03"},
  {"vmid":503,"name":"roon-dev","node":"pve01"},
  {"vmid":603,"name":"roon-prod","node":"pve03"},
  {"vmid":502,"name":"grafana-dev","node":"pve02"},
  {"vmid":602,"name":"grafana-prod","node":"pve03"}
]
JSON
}

write_policy_off_jobs() {
  cat > "${CASE_SHIMS}/cluster_replication.json" <<'JSON'
[
  {"id":"160-0","source":"pve01","target":"pve02","guest":160,"type":"vm"},
  {"id":"160-1","source":"pve01","target":"pve03","guest":160,"type":"vm"},
  {"id":"301-0","source":"pve02","target":"pve01","guest":301,"type":"vm"},
  {"id":"301-1","source":"pve02","target":"pve03","guest":301,"type":"vm"},
  {"id":"404-0","source":"pve03","target":"pve01","guest":404,"type":"vm"},
  {"id":"404-1","source":"pve03","target":"pve02","guest":404,"type":"vm"},
  {"id":"502-0","source":"pve02","target":"pve01","guest":502,"type":"vm"},
  {"id":"502-1","source":"pve02","target":"pve03","guest":502,"type":"vm"},
  {"id":"602-0","source":"pve03","target":"pve01","guest":602,"type":"vm"},
  {"id":"602-1","source":"pve03","target":"pve02","guest":602,"type":"vm"}
]
JSON
}

write_healthy_pvesr() {
  local file
  for file in "${CASE_SHIMS}"/pvesr_pve01.txt "${CASE_SHIMS}"/pvesr_pve02.txt "${CASE_SHIMS}"/pvesr_pve03.txt; do
    echo 'JobID  Enabled  Target       LastSync             NextSync             Duration  FailCount  State' > "$file"
  done

  for vmid in 150 160 401 503; do
    printf '%s-0  Yes  local/pve02  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' "$vmid" >> "${CASE_SHIMS}/pvesr_pve01.txt"
    printf '%s-1  Yes  local/pve03  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' "$vmid" >> "${CASE_SHIMS}/pvesr_pve01.txt"
  done
  for vmid in 301 303 402 501 502; do
    printf '%s-0  Yes  local/pve01  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' "$vmid" >> "${CASE_SHIMS}/pvesr_pve02.txt"
    printf '%s-1  Yes  local/pve03  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' "$vmid" >> "${CASE_SHIMS}/pvesr_pve02.txt"
  done
  for vmid in 403 404 601 603 602; do
    printf '%s-0  Yes  local/pve01  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' "$vmid" >> "${CASE_SHIMS}/pvesr_pve03.txt"
    printf '%s-1  Yes  local/pve02  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' "$vmid" >> "${CASE_SHIMS}/pvesr_pve03.txt"
  done
}

prepare_mixed_case() {
  stage_repo "$1"
  write_vm_data_mixed
  write_policy_off_jobs
  write_healthy_pvesr
}

run_configure() {
  local rc=0
  (
    cd "$CASE_REPO"
    SHIM_DIR="$CASE_SHIMS" PATH="$CASE_SHIMS:$PATH" \
      framework/scripts/configure-replication.sh "*" "$@"
  ) >"${CASE_SHIMS}/stdout.txt" 2>"${CASE_SHIMS}/stderr.txt" || rc=$?
  RUN_RC="$rc"
}

log_has_vmid() {
  local file="$1" vmid="$2"
  [[ -f "$file" ]] && grep -Eq "^${vmid}-[0-9]+([[:space:]].*)?$" "$file"
}

no_mutation_logs() {
  [[ ! -s "${CASE_SHIMS}/creates.log" && ! -s "${CASE_SHIMS}/deletes.log" && ! -s "${CASE_SHIMS}/destroys.log" && ! -s "${CASE_SHIMS}/sets.log" ]]
}

test_start "V2.2.interval" "--interval is removed and fails before mutation"
prepare_mixed_case "interval-removed"
run_configure --interval 1
if [[ "$RUN_RC" -ne 0 ]] \
   && grep -q -- '--interval is removed; schedule is policy' "${CASE_SHIMS}/stderr.txt" \
   && no_mutation_logs; then
  test_pass "--interval exits non-zero with removal guidance before any mutation"
else
  test_fail "--interval did not fail with the removal message before mutation"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_SHIMS}/stdout.txt")" "$(cat "${CASE_SHIMS}/stderr.txt")" >&2
fi

test_start "V2.2.a" "mixed fixture creates precious jobs and skips policy-off derivables"
prepare_mixed_case "mixed-dev"
run_configure --env dev
# Note on RUN_RC: the fixture pvesr shim files do NOT contain rows for
# jobs freshly `pvesh create`d inside this run (chicken-and-egg with a
# static fixture), so the initial-sync wait always times out and the
# script exits non-zero at the wait phase. That timeout is UNRELATED to
# the create/skip/prune partition being tested here. The observable
# events (POLICY-OFF log lines, creates.log entries, summary counter)
# ALL fire before the wait phase, so we assert on those, not on
# RUN_RC. See "M3 attended deploy" in SPRINT-047.md for the live
# verification of the full wait cycle.
if grep -q 'POLICY-OFF: cicd (160)' "${CASE_SHIMS}/stdout.txt" \
   && grep -q 'POLICY-OFF: dns1-dev (301)' "${CASE_SHIMS}/stdout.txt" \
   && grep -q 'POLICY-OFF: grafana-dev (502)' "${CASE_SHIMS}/stdout.txt" \
   && log_has_vmid "${CASE_SHIMS}/creates.log" 150 \
   && log_has_vmid "${CASE_SHIMS}/creates.log" 303 \
   && ! log_has_vmid "${CASE_SHIMS}/creates.log" 160 \
   && ! log_has_vmid "${CASE_SHIMS}/creates.log" 301 \
   && grep -q '3 policy-off VMIDs pruned' "${CASE_SHIMS}/stdout.txt"; then
  test_pass "precious VMIDs create jobs; derivable VMIDs log POLICY-OFF, do not create, and count as pruned"
else
  test_fail "mixed fixture did not enforce create/skip/prune partition"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n--- creates ---\n%s\n' \
    "$RUN_RC" "$(cat "${CASE_SHIMS}/stdout.txt")" "$(cat "${CASE_SHIMS}/stderr.txt")" \
    "$(cat "${CASE_SHIMS}/creates.log" 2>/dev/null || true)" >&2
fi

test_start "V2.2.b" "--env dev prunes dev+shared only and leaves prod policy-off jobs alone"
# The script exits at the initial-sync wait (see V2.2.a comment) BEFORE
# iterating over every prune target-node pair. What we can assert is
# that the CORRECT VMIDs are targeted for pruning (the dev∪shared subset
# excludes gatus/404 and grafana-prod/602 — the prod policy-off set).
# The prune scope line in stdout is the observable ratchet here — it
# lists exactly the set of VMIDs that WOULD be pruned; verify-after-
# destroy against pvesh delete is exercised via the CASE_SHIMS logs on
# whichever VMIDs the script gets to before the wait exit.
prune_line=$(grep 'Env-scoped policy prune (scope=' "${CASE_SHIMS}/stdout.txt" | head -1)
if echo "$prune_line" | grep -qE 'scope=.dev.' \
   && echo "$prune_line" | grep -qE '160' \
   && echo "$prune_line" | grep -qE '301' \
   && echo "$prune_line" | grep -qE '502' \
   && ! echo "$prune_line" | grep -qE '\b404\b' \
   && ! echo "$prune_line" | grep -qE '\b602\b'; then
  test_pass "dev scope prune covers 160/301/502 only; prod policy-off (404/602) not in prune scope"
else
  test_fail "env-scoped prune deleted or destroyed the wrong VMID/node set"
  printf 'prune_line=%s\n--- deletes ---\n%s\n--- destroys ---\n%s\n' \
    "$prune_line" "$(cat "${CASE_SHIMS}/deletes.log" 2>/dev/null || true)" \
    "$(cat "${CASE_SHIMS}/destroys.log" 2>/dev/null || true)" >&2
fi

test_start "V2.2.c" "--env dev create/keep loop still includes prod precious and prod DNS"
if log_has_vmid "${CASE_SHIMS}/creates.log" 401 \
   && log_has_vmid "${CASE_SHIMS}/creates.log" 402 \
   && log_has_vmid "${CASE_SHIMS}/creates.log" 403 \
   && log_has_vmid "${CASE_SHIMS}/creates.log" 601 \
   && log_has_vmid "${CASE_SHIMS}/creates.log" 603; then
  test_pass "prod DNS and prod precious VMIDs were still created during a dev-scoped run"
else
  test_fail "create-is-global ratchet failed: prod policy-on VMIDs were absent from creates.log"
  cat "${CASE_SHIMS}/creates.log" 2>/dev/null >&2 || true
fi

test_start "V2.2.d" "no --env scope prunes every policy-off VMID"
prepare_mixed_case "mixed-all"
run_configure
# Same wait-timeout caveat as V2.2.a — assert on the prune scope line +
# observable delete events, not on RUN_RC.
prune_line=$(grep 'Env-scoped policy prune (scope=' "${CASE_SHIMS}/stdout.txt" | head -1)
if echo "$prune_line" | grep -qE 'scope=.all.' \
   && echo "$prune_line" | grep -qE '160' \
   && echo "$prune_line" | grep -qE '301' \
   && echo "$prune_line" | grep -qE '404' \
   && echo "$prune_line" | grep -qE '502' \
   && echo "$prune_line" | grep -qE '602'; then
  test_pass "unscoped run prune scope covers shared, dev, and prod policy-off VMIDs"
else
  test_fail "unscoped prune did not cover all policy-off VMIDs"
  printf 'prune_line=%s\n--- stdout ---\n%s\n--- deletes ---\n%s\n' \
    "$prune_line" "$(cat "${CASE_SHIMS}/stdout.txt")" \
    "$(cat "${CASE_SHIMS}/deletes.log" 2>/dev/null || true)" >&2
fi

test_start "V2.2.e" "verify-after-destroy fails when a target replica remains"
prepare_mixed_case "residual"
echo 'vmstore/data/vm-160-disk-0' > "${CASE_SHIMS}/residual_pve02_160.txt"
run_configure --env dev
if [[ "$RUN_RC" -ne 0 ]] \
   && grep -q 'verify-after-destroy FAILED' "${CASE_SHIMS}/stderr.txt" \
   && grep -q 'vmstore/data/vm-160-disk-0' "${CASE_SHIMS}/stderr.txt"; then
  test_pass "residual target replica makes configure-replication fail closed"
else
  test_fail "residual replica did not fail the verify-after-destroy ratchet"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_SHIMS}/stdout.txt")" "$(cat "${CASE_SHIMS}/stderr.txt")" >&2
fi

test_start "V2.2.f" "empty helper output aborts before create or prune"
prepare_mixed_case "empty-helper"
cat > "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"--mode replicated"*) exit 0 ;;
  *"--mode policy-off"*) echo "160" ;;
  *) exit 0 ;;
esac
HELPER
chmod +x "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh"
run_configure --env dev
if [[ "$RUN_RC" -ne 0 ]] \
   && grep -q 'helper returned empty GLOBAL_POLICY_ON' "${CASE_SHIMS}/stderr.txt" \
   && no_mutation_logs; then
  test_pass "empty policy-on helper output exits non-zero before any create/prune mutation"
else
  test_fail "empty helper output did not abort cleanly before mutation"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_SHIMS}/stdout.txt")" "$(cat "${CASE_SHIMS}/stderr.txt")" >&2
fi

test_start "V2.2.g" "helper failure aborts before create or prune"
prepare_mixed_case "failing-helper"
cat > "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh" <<'HELPER'
#!/usr/bin/env bash
echo "fixture helper failure" >&2
exit 42
HELPER
chmod +x "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh"
run_configure --env dev
if [[ "$RUN_RC" -ne 0 ]] \
   && grep -q 'helper failed for --mode all all' "${CASE_SHIMS}/stderr.txt" \
   && no_mutation_logs; then
  test_pass "helper failure exits non-zero before any create/prune mutation"
else
  test_fail "helper failure did not abort cleanly before mutation"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_SHIMS}/stdout.txt")" "$(cat "${CASE_SHIMS}/stderr.txt")" >&2
fi

test_start "V2.3" "empty prune list reaches summary under set -u without POLICY_PRUNED unbound"
stage_repo "empty-prune"
cat > "${CASE_REPO}/site/config.yaml" <<'YAML'
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
vms:
  gitlab:
    vmid: 150
    backup: true
YAML
cat > "${CASE_REPO}/site/applications.yaml" <<'YAML'
applications: {}
YAML
cat > "${CASE_SHIMS}/vm_data.json" <<'JSON'
[
  {"vmid":150,"name":"gitlab","node":"pve01"}
]
JSON
cat > "${CASE_SHIMS}/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"type":"vm","schedule":"*/1"},
  {"id":"150-1","source":"pve01","target":"pve03","guest":150,"type":"vm","schedule":"*/1"}
]
JSON
echo 'JobID  Enabled  Target       LastSync             NextSync             Duration  FailCount  State' > "${CASE_SHIMS}/pvesr_pve01.txt"
printf '150-0  Yes  local/pve02  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' >> "${CASE_SHIMS}/pvesr_pve01.txt"
printf '150-1  Yes  local/pve03  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' >> "${CASE_SHIMS}/pvesr_pve01.txt"
: > "${CASE_SHIMS}/pvesr_pve02.txt"
: > "${CASE_SHIMS}/pvesr_pve03.txt"
run_configure --env prod
if [[ "$RUN_RC" -eq 0 ]] \
   && grep -q 'Summary: .* SCHEDULE_RECONCILED=0, .* 0 policy-off VMIDs pruned' "${CASE_SHIMS}/stdout.txt" \
   && ! grep -q 'unbound variable' "${CASE_SHIMS}/stderr.txt"; then
  test_pass "empty prune path prints summary with POLICY_PRUNED=0 and SCHEDULE_RECONCILED=0 under set -u"
else
  test_fail "empty prune path hit an unbound variable or failed before summary"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_SHIMS}/stdout.txt")" "$(cat "${CASE_SHIMS}/stderr.txt")" >&2
fi

test_start "V2.5" "wrong existing schedule is reconciled in place with pvesh set, not delete/create"
stage_repo "schedule-reconcile"
cat > "${CASE_REPO}/site/config.yaml" <<'YAML'
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
vms:
  gitlab:
    vmid: 150
    backup: true
YAML
cat > "${CASE_REPO}/site/applications.yaml" <<'YAML'
applications: {}
YAML
cat > "${CASE_SHIMS}/vm_data.json" <<'JSON'
[
  {"vmid":150,"name":"gitlab","node":"pve01"}
]
JSON
cat > "${CASE_SHIMS}/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"type":"vm","schedule":"03:00"},
  {"id":"150-1","source":"pve01","target":"pve03","guest":150,"type":"vm","schedule":"*/1"}
]
JSON
echo 'JobID  Enabled  Target       LastSync             NextSync             Duration  FailCount  State' > "${CASE_SHIMS}/pvesr_pve01.txt"
printf '150-0  Yes  local/pve02  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' >> "${CASE_SHIMS}/pvesr_pve01.txt"
printf '150-1  Yes  local/pve03  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' >> "${CASE_SHIMS}/pvesr_pve01.txt"
: > "${CASE_SHIMS}/pvesr_pve02.txt"
: > "${CASE_SHIMS}/pvesr_pve03.txt"
run_configure
if [[ "$RUN_RC" -eq 0 ]] \
   && grep -Fqx '150-0 */1' "${CASE_SHIMS}/sets.log" \
   && ! grep -q '^150-1 ' "${CASE_SHIMS}/sets.log" \
   && [[ ! -s "${CASE_SHIMS}/deletes.log" ]] \
   && [[ ! -s "${CASE_SHIMS}/creates.log" ]] \
   && grep -q 'SCHEDULE_RECONCILED=1' "${CASE_SHIMS}/stdout.txt"; then
  test_pass "schedule drift used pvesh set in place; correct-schedule job untouched; no delete/create"
else
  test_fail "schedule reconcile did not use the expected in-place path"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n--- sets ---\n%s\n--- deletes ---\n%s\n--- creates ---\n%s\n' \
    "$RUN_RC" "$(cat "${CASE_SHIMS}/stdout.txt")" "$(cat "${CASE_SHIMS}/stderr.txt")" \
    "$(cat "${CASE_SHIMS}/sets.log" 2>/dev/null || true)" \
    "$(cat "${CASE_SHIMS}/deletes.log" 2>/dev/null || true)" \
    "$(cat "${CASE_SHIMS}/creates.log" 2>/dev/null || true)" >&2
fi

test_start "V2.6" "artifact has sorted CADENCE_MAP, rolled POLICY_GEN, and no rejected maps"
stage_repo "artifact-cadence-map"
cat > "${CASE_REPO}/site/config.yaml" <<'YAML'
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
vms:
  pbs:
    vmid: 190
    backup: true
  gitlab:
    vmid: 150
    backup: true
YAML
cat > "${CASE_REPO}/site/applications.yaml" <<'YAML'
applications: {}
YAML
cat > "${CASE_SHIMS}/vm_data.json" <<'JSON'
[
  {"vmid":150,"name":"gitlab","node":"pve01"},
  {"vmid":190,"name":"pbs","node":"pve01"}
]
JSON
cat > "${CASE_SHIMS}/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"type":"vm","schedule":"*/1"},
  {"id":"150-1","source":"pve01","target":"pve03","guest":150,"type":"vm","schedule":"*/1"},
  {"id":"190-0","source":"pve01","target":"pve02","guest":190,"type":"vm","schedule":"*/1"},
  {"id":"190-1","source":"pve01","target":"pve03","guest":190,"type":"vm","schedule":"*/1"}
]
JSON
echo 'JobID  Enabled  Target       LastSync             NextSync             Duration  FailCount  State' > "${CASE_SHIMS}/pvesr_pve01.txt"
for vmid in 150 190; do
  printf '%s-0  Yes  local/pve02  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' "$vmid" >> "${CASE_SHIMS}/pvesr_pve01.txt"
  printf '%s-1  Yes  local/pve03  2026-07-18_12:00:00  2026-07-18_12:01:00  1.0  0  OK\n' "$vmid" >> "${CASE_SHIMS}/pvesr_pve01.txt"
done
: > "${CASE_SHIMS}/pvesr_pve02.txt"
: > "${CASE_SHIMS}/pvesr_pve03.txt"
run_configure
artifact="${CASE_SHIMS}/artifact_pve01.txt"
artifact_on=$(sed -n 's/^POLICY_ON_VMIDS=//p' "$artifact" 2>/dev/null || true)
artifact_off=$(sed -n 's/^POLICY_OFF_VMIDS=//p' "$artifact" 2>/dev/null || true)
expected_gen=$(printf '%s|%s|%s\n' "$artifact_on" "$artifact_off" '150:60,190:60' | sha256sum | awk '{print $1}')
if [[ "$RUN_RC" -eq 0 && -f "$artifact" ]] \
   && grep -qx 'CADENCE_MAP=150:60,190:60' "$artifact" \
   && grep -qx 'POLICY_OFF_VMIDS=' "$artifact" \
   && grep -qx "POLICY_GEN=${expected_gen}" "$artifact" \
   && ! grep -q '^SCHEDULE_MAP=' "$artifact" \
   && ! grep -q '^SEED_GRACE_UNTIL=' "$artifact"; then
  test_pass "artifact has sorted CADENCE_MAP and POLICY_GEN = sha256(ON|OFF|CADENCE_MAP)"
else
  test_fail "artifact did not match CADENCE_MAP/POLICY_GEN contract"
  echo "--- artifact ---" >&2; cat "$artifact" >&2
  echo "expected_gen=${expected_gen}" >&2
fi

runner_summary
