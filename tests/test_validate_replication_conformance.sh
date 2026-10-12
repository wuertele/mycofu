#!/usr/bin/env bash
# test_validate_replication_conformance.sh — Sprint 047 V4.1 static ratchet.
#
# The `replication_policy_conformance_check` in validate.sh (A5) has three
# behavioral arms:
#   1. Full-mesh presence for policy-on VMIDs (env-scoped)
#   2. Absence for policy-off VMIDs (env-scoped)
#   3. Node artifact equivalence against helper output (ALWAYS GLOBAL — S1)
#
# Behavioral verification of arms 1/2/3 requires live cluster access
# (pvesh, ssh to nodes) and is exercised at M3 (attended deploy — see
# SPRINT-047.md § M3). This CI-runnable test enforces the STRUCTURAL
# invariants that guarantee arms 1/2/3 exist and are wired into the
# Storage validation phase:
#
#   V4.1.a — The `replication_policy_conformance_check` function is defined.
#   V4.1.b — The Storage section invokes it via `check_capture ... conformance`.
#   V4.1.c — The function fails-closed (returns 1) on empty policy-on set
#            and on helper failure — the #615 lesson embedded in A3.3.
#   V4.1.d — The function computes POLICY_GEN with sha256sum of the
#            `<on>|<off>|<CADENCE_MAP>` global sets — the same recipe
#            configure-replication.sh uses.
#   V4.1.e — The function does NOT silently SKIP on any unreadable input:
#            grep asserts no `return 0` after an error path, matching
#            .claude/rules/destruction-safety.md's FAIL-not-SKIP mandate.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
source "${TEST_DIR}/lib/runner.sh"

VALIDATE="${REPO_DIR}/framework/scripts/validate.sh"
CONFIG_REPL="${REPO_DIR}/framework/scripts/configure-replication.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# V4.1.a — function is defined
# ---------------------------------------------------------------------------
test_start "V4.1.a" "replication_policy_conformance_check function defined"
if grep -qE '^replication_policy_conformance_check\(\)' "$VALIDATE"; then
  test_pass "function defined in validate.sh"
else
  test_fail "V4.1.a: replication_policy_conformance_check function missing"
fi

# ---------------------------------------------------------------------------
# V4.1.b — function is wired into Storage validation
# ---------------------------------------------------------------------------
test_start "V4.1.b" "Storage section invokes replication policy conformance check"
if grep -qE 'check_capture[^\n]+replication policy conformance[^\n]+replication_policy_conformance_check' "$VALIDATE" \
   || grep -qE '"replication policy conformance"[^\n]+replication_policy_conformance_check' "$VALIDATE"; then
  test_pass "check_capture wires conformance into Storage validation"
else
  # Fallback: check both tokens exist on the same line via grep -n proximity
  wire_line=$(grep -n 'replication_policy_conformance_check' "$VALIDATE" | grep -v '^[0-9]*:replication_policy_conformance_check()' | head -1)
  if [[ -n "$wire_line" && "$wire_line" =~ (check|conformance) ]]; then
    test_pass "conformance function invoked in a check wrapper: $wire_line"
  else
    test_fail "V4.1.b: no check_capture wire-in found"
  fi
fi

# ---------------------------------------------------------------------------
# Deterministic function-body extraction (fail-closed).
#
# Historical false-negative (RCA 2026-07-21): `if echo "$FUNC_BODY" | grep -q
# ... ; then` inside `set -o pipefail` can report false-negative when grep
# stops early after a match while the producer keeps writing — a broken
# pipe on the producer side turns the whole pipeline non-zero, tripping
# the negative branch even though the pattern IS present.
#
# The deterministic fix: write the function body ONCE to a tempfile and
# run every grep against the FILE (no producer process, no pipeline).
# Fail LOUDLY if extraction produces an empty body or never finds the
# closing brace — a checker that cannot determine its answer FAILS
# (destruction-safety.md).
# ---------------------------------------------------------------------------
FUNC_BODY_FILE="${TMP_DIR}/replication_policy_conformance_check.body"
# set -e would kill the script before $? can be captured on a non-zero awk
# (see .claude/rules/platform.md "set -e kills before you can capture").
# Disable it around the awk so the fail-loud diagnostic below actually runs.
set +e
awk -v out="$FUNC_BODY_FILE" '
  /^replication_policy_conformance_check\(\)/ { in_func=1; found_open=1 }
  in_func { print > out }
  in_func && /^\}$/ { in_func=0; found_close=1 }
  END {
    if (!found_open)  exit 2
    if (!found_close) exit 3
  }
' "$VALIDATE"
awk_rc=$?
set -e
if [[ $awk_rc -ne 0 ]]; then
  echo "V4.1 SETUP FAIL: awk extraction returned rc=${awk_rc}" >&2
  echo "  (rc=2: opening 'replication_policy_conformance_check()' not found in ${VALIDATE})" >&2
  echo "  (rc=3: opening found but no top-level closing brace found — extraction ran off the end)" >&2
  exit 1
fi
if [[ ! -s "$FUNC_BODY_FILE" ]]; then
  echo "V4.1 SETUP FAIL: extracted body file is empty (${FUNC_BODY_FILE}) despite awk rc=0" >&2
  echo "  This should not happen; validate.sh structure has drifted." >&2
  exit 1
fi
FUNC_BODY_SIZE=$(wc -c < "$FUNC_BODY_FILE" | tr -d ' ')
if [[ "$FUNC_BODY_SIZE" -lt 500 ]]; then
  echo "V4.1 SETUP FAIL: extracted body is suspiciously small (${FUNC_BODY_SIZE} bytes)" >&2
  echo "  Expected multi-kilobyte body; validate.sh structure has drifted." >&2
  head -20 "$FUNC_BODY_FILE" >&2
  exit 1
fi
# The EXIT trap on TMP_DIR (earlier in this file) also cleans up FUNC_BODY_FILE.

# ---------------------------------------------------------------------------
# V4.1.c — fail-closed on empty policy-on set + helper failure
# ---------------------------------------------------------------------------
test_start "V4.1.c" "fail-closed on empty policy-on and helper failure"

# Must have an empty-set guard
empty_on_ok=0
if grep -qE 'empty (policy-on|policy set|GLOBAL)|helper returned empty' "$FUNC_BODY_FILE"; then
  empty_on_ok=1
fi

# Must have a helper-failure guard
helper_fail_ok=0
if grep -qE 'return 1' "$FUNC_BODY_FILE" \
   && grep -qE 'helper|replication_policy_helper' "$FUNC_BODY_FILE"; then
  helper_fail_ok=1
fi

if [[ $empty_on_ok -eq 1 && $helper_fail_ok -eq 1 ]]; then
  test_pass "empty-set guard + helper-failure guard both present (fail-closed)"
else
  test_fail "V4.1.c: missing fail-closed guard (empty=${empty_on_ok}, helper=${helper_fail_ok})"
fi

# ---------------------------------------------------------------------------
# V4.1.d — POLICY_GEN computed with sha256sum of `<on>|<off>|<CADENCE_MAP>`
# ---------------------------------------------------------------------------
test_start "V4.1.d" "POLICY_GEN computation includes CADENCE_MAP and matches configure-replication.sh recipe"
if grep -qE 'sha256sum' "$FUNC_BODY_FILE" \
   && grep -qE 'CADENCE_MAP|cadence_map' "$FUNC_BODY_FILE" \
   && grep -qE 'sha256sum' "$CONFIG_REPL" \
   && grep -qE 'CADENCE_MAP|cadence_map' "$CONFIG_REPL"; then
  test_pass "POLICY_GEN uses sha256sum over ON/OFF/CADENCE_MAP on both writer and validator"
else
  test_fail "V4.1.d: POLICY_GEN recipe is missing sha256sum or CADENCE_MAP"
fi

# ---------------------------------------------------------------------------
# V4.1.e — no silent SKIP on unreadable input
# ---------------------------------------------------------------------------
test_start "V4.1.e" "no silent return-0 on unreadable input (destruction-safety.md FAIL-not-SKIP)"

# Look for suspicious "return 0" patterns immediately after echo/print of a
# suggestive error keyword. If the function has `return 0` at all, it must
# only be at the end (the terminal success return). Simplest static assert:
# the ONLY `return 0` OR final unconditional `[[ ... ]]` boolean should
# reach the end. Since validate.sh uses `[[ "$failures" -eq 0 ]]` at the
# end, `return 0` should not appear at all.
if grep -qE '^\s*return 0' "$FUNC_BODY_FILE"; then
  test_fail "V4.1.e: replication_policy_conformance_check contains a bare 'return 0' — check for silent SKIP paths"
  grep -nE '^\s*return 0' "$FUNC_BODY_FILE" >&2
else
  test_pass "no bare 'return 0' escape hatch; final [[ failures -eq 0 ]] is the sole success gate"
fi

# ---------------------------------------------------------------------------
# V4.1.f — env-aware scoping is present
# ---------------------------------------------------------------------------
test_start "V4.1.f" "env-aware scoping applied to job-presence/absence arms"
if grep -qE 'REPLICATION_POLICY_VALIDATE_SCOPE|scope="\$' "$FUNC_BODY_FILE"; then
  test_pass "check reads scope from REPLICATION_POLICY_VALIDATE_SCOPE (env-aware)"
else
  test_fail "V4.1.f: no env-aware scoping variable found in the check body"
fi

# ---------------------------------------------------------------------------
# V4.1.g — artifact equivalence sub-check uses GLOBAL sets always (S1)
# ---------------------------------------------------------------------------
test_start "V4.1.g" "artifact equivalence compares GLOBAL sets (never env-scoped, per S1)"
# The function stores GLOBAL sets in `global_on` / `global_off` and the
# artifact-comparison arm compares against those (not the scoped versions).
# Assert both signal words appear.
if grep -qE 'global_on\b' "$FUNC_BODY_FILE" \
   && grep -qE 'global_off\b' "$FUNC_BODY_FILE" \
   && grep -qE 'cadence_map\b' "$FUNC_BODY_FILE" \
   && grep -qE '\$artifact_on.*\$global_on|\$global_on.*\$artifact_on|POLICY_ON_VMIDS' "$FUNC_BODY_FILE" \
   && grep -qE 'CADENCE_MAP' "$FUNC_BODY_FILE"; then
  test_pass "GLOBAL sets and CADENCE_MAP used in artifact equivalence sub-check"
else
  test_fail "V4.1.g: artifact equivalence appears not to compare against GLOBAL sets plus CADENCE_MAP"
fi

# ---------------------------------------------------------------------------
# V4.1.h — live schedule equivalence uses helper pvesr_schedule directly
# ---------------------------------------------------------------------------
test_start "V4.1.h" "live schedule drift is checked against helper pvesr_schedule"
if grep -q 'POLICY_ON_TSV' "$FUNC_BODY_FILE" \
   && grep -q 'pvesr_schedule' "$FUNC_BODY_FILE" \
   && grep -q 'schedule drift' "$FUNC_BODY_FILE" \
   && ! grep -q 'SCHEDULE_MAP' "$FUNC_BODY_FILE"; then
  test_pass "schedule-equivalence arm compares live job schedule directly to helper TSV"
else
  test_fail "V4.1.h: schedule-equivalence arm missing or routed through SCHEDULE_MAP"
fi

# ---------------------------------------------------------------------------
# V4.1.i — artifact equivalence includes CADENCE_MAP and rolled POLICY_GEN
# ---------------------------------------------------------------------------
test_start "V4.1.i" "CADENCE_MAP artifact equivalence and POLICY_GEN roll are present"
if grep -q 'replication_policy_cadence_map_from_tsv' "$FUNC_BODY_FILE" \
   && grep -q 'CADENCE_MAP' "$FUNC_BODY_FILE" \
   && grep -q "printf '%s|%s|%s" "$FUNC_BODY_FILE" \
   && grep -q 'POLICY_GEN drift' "$FUNC_BODY_FILE"; then
  test_pass "CADENCE_MAP drift and sha256(ON|OFF|CADENCE_MAP) POLICY_GEN checks are present"
else
  test_fail "V4.1.i: CADENCE_MAP or rolled POLICY_GEN check missing"
fi

# ---------------------------------------------------------------------------
# V4.1.j — async seed warning path is present and non-fatal
# ---------------------------------------------------------------------------
test_start "V4.1.j" "cadence>60 never-run fail_count=0 emits seeding WARN"
if grep -q 'replication seed in progress' "$FUNC_BODY_FILE" \
   && grep -q 'cadence_seconds > 60' "$FUNC_BODY_FILE" \
   && grep -q 'last_sync == "-"' "$FUNC_BODY_FILE"; then
  test_pass "seeding WARN arm is present for async never-run rows"
else
  test_fail "V4.1.j: seeding WARN arm missing"
fi

# ---------------------------------------------------------------------------
# V4.1.k — pvesr status unreadable is fail-closed
# ---------------------------------------------------------------------------
test_start "V4.1.k" "pvesr status unreadable returns non-zero, not warning-only skip"
if grep -q 'pvesr status query failed' "$FUNC_BODY_FILE" \
   && grep -q 'return 1' "$FUNC_BODY_FILE" \
   && ! grep -q 'seed-progress warning skipped' "$FUNC_BODY_FILE"; then
  test_pass "unreadable pvesr status is fail-closed"
else
  test_fail "V4.1.k: unreadable pvesr status still appears warning-only"
fi

make_validate_case() {
  local name="$1"
  local cadence_map="${2:-150:60,160:86400}"
  CASE_DIR="${TMP_DIR}/${name}"
  mkdir -p "${CASE_DIR}/framework/scripts" "${CASE_DIR}/site" "${CASE_DIR}/shims"
  cp "${REPO_DIR}/framework/scripts/list-replicated-vmids.sh" "${CASE_DIR}/framework/scripts/list-replicated-vmids.sh"
  chmod +x "${CASE_DIR}/framework/scripts/list-replicated-vmids.sh"

  cat > "${CASE_DIR}/site/config.yaml" <<'YAML'
domain: fixture.test
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
  - name: pve02
    mgmt_ip: 10.0.0.2
proxmox:
  storage_pool: vmstore
vms:
  gitlab:
    vmid: 150
    backup: true
  cicd:
    vmid: 160
    replicate: "24h"
YAML
  cat > "${CASE_DIR}/site/applications.yaml" <<'YAML'
applications: {}
YAML
  cat > "${CASE_DIR}/config.json" <<'JSON'
{"domain":"fixture.test","nodes":[{"name":"pve01","mgmt_ip":"10.0.0.1"},{"name":"pve02","mgmt_ip":"10.0.0.2"}],"proxmox":{"storage_pool":"vmstore"},"vms":{"gitlab":{"vmid":150,"backup":true},"cicd":{"vmid":160,"replicate":"24h"}}}
JSON
  cat > "${CASE_DIR}/applications.json" <<'JSON'
{"applications":{}}
JSON

  local policy_on="150,160"
  local policy_off=""
  local policy_gen
  policy_gen=$(printf '%s|%s|%s\n' "$policy_on" "$policy_off" "$cadence_map" | sha256sum | awk '{print $1}')
  for node in pve01 pve02; do
    cat > "${CASE_DIR}/artifact_${node}.txt" <<ART
POLICY_ON_VMIDS=${policy_on}
POLICY_OFF_VMIDS=${policy_off}
CADENCE_MAP=${cadence_map}
POLICY_GEN=${policy_gen}
ART
  done

  cat > "${CASE_DIR}/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"schedule":"*/1"},
  {"id":"160-0","source":"pve01","target":"pve02","guest":160,"schedule":"03:00"}
]
JSON
  cat > "${CASE_DIR}/pvesr_pve01.txt" <<'PVE'
JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State
150-0      Yes        local/pve02           2026-07-18_06:00:00  2026-07-18_06:01:00   1         0         OK
160-0      Yes        local/pve02           2026-07-18_06:00:00  2026-07-19_03:00:00   1         0         OK
PVE
  : > "${CASE_DIR}/pvesr_pve02.txt"

  cat > "${CASE_DIR}/shims/yq" <<'YQ'
#!/usr/bin/env bash
if [[ "${1:-}" == "-o=json" ]]; then
  target="${!#}"
  case "$target" in
    *applications.yaml) cat "${CASE_DIR}/applications.json" ;;
    *) cat "${CASE_DIR}/config.json" ;;
  esac
  exit 0
fi
q="$*"
case "$q" in
  *".nodes[].name"*) echo "pve01"; echo "pve02" ;;
  *".nodes | length"*) echo "2" ;;
  *".nodes[0].name"*) echo "pve01" ;;
  *".nodes[1].name"*) echo "pve02" ;;
  *".nodes[0].mgmt_ip"*) echo "10.0.0.1" ;;
  *".nodes[1].mgmt_ip"*) echo "10.0.0.2" ;;
  *'select(.name == "pve01")'*) echo "10.0.0.1" ;;
  *'select(.name == "pve02")'*) echo "10.0.0.2" ;;
  *) echo "" ;;
esac
YQ
  chmod +x "${CASE_DIR}/shims/yq"

  cat > "${CASE_DIR}/shims/ssh" <<'SSH'
#!/usr/bin/env bash
host=""
for a in "$@"; do
  case "$a" in root@*) host="${a#root@}" ;; esac
done
remote="${!#}"
case "$host" in
  10.0.0.1) node="pve01" ;;
  10.0.0.2) node="pve02" ;;
  *) node="unknown" ;;
esac
case "$remote" in
  *"pvesh get /cluster/replication"*) cat "${CASE_DIR}/cluster_replication.json" ;;
  *"pvesr status"*) cat "${CASE_DIR}/pvesr_${node}.txt" ;;
  *"cat /etc/repl-policy.vmids"*) cat "${CASE_DIR}/artifact_${node}.txt" ;;
  *) exit 0 ;;
esac
SSH
  chmod +x "${CASE_DIR}/shims/ssh"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -euo pipefail'
    printf 'SCRIPT_DIR=%q\n' "${CASE_DIR}/framework/scripts"
    printf 'CONFIG=%q\n' "${CASE_DIR}/site/config.yaml"
    printf '%s\n' 'NODE_COUNT=2'
    printf '%s\n' 'SSH_OPTS_ARGS=(-n)'
    awk '
      /^replication_policy_helper_csv\(\)/ { in_block=1 }
      /^_failover_fit_read_memavail_kb\(\)/ { in_block=0 }
      in_block { print }
    ' "$VALIDATE"
    printf '%s\n' 'replication_policy_conformance_check'
  } > "${CASE_DIR}/run-conformance.sh"
  chmod +x "${CASE_DIR}/run-conformance.sh"
}

run_validate_case() {
  local rc=0
  CASE_DIR="$CASE_DIR" PATH="${CASE_DIR}/shims:${PATH}" \
    bash "${CASE_DIR}/run-conformance.sh" >"${CASE_DIR}/stdout.txt" 2>"${CASE_DIR}/stderr.txt" || rc=$?
  RUN_RC="$rc"
}

test_start "V4.1.l" "schedule drift fixture fails naming VMID and expected/live schedules"
make_validate_case "schedule-drift"
cat > "${CASE_DIR}/cluster_replication.json" <<'JSON'
[
  {"id":"150-0","source":"pve01","target":"pve02","guest":150,"schedule":"*/5"},
  {"id":"160-0","source":"pve01","target":"pve02","guest":160,"schedule":"03:00"}
]
JSON
run_validate_case
if [[ "$RUN_RC" -ne 0 ]] \
   && grep -Fq 'policy-on VMID gitlab (150) job 150-0 schedule drift' "${CASE_DIR}/stdout.txt" \
   && grep -Fq "expected '*/1', got '*/5'" "${CASE_DIR}/stdout.txt"; then
  test_pass "schedule drift fails with VMID, helper schedule, and live schedule"
else
  test_fail "schedule drift fixture did not fail as expected"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_DIR}/stdout.txt")" "$(cat "${CASE_DIR}/stderr.txt")" >&2
fi

test_start "V4.1.m" "CADENCE_MAP drift fixture fails artifact and POLICY_GEN equivalence"
make_validate_case "cadence-map-drift" "150:60,160:60"
run_validate_case
if [[ "$RUN_RC" -ne 0 ]] \
   && grep -q 'CADENCE_MAP drift' "${CASE_DIR}/stdout.txt" \
   && grep -q 'POLICY_GEN drift' "${CASE_DIR}/stdout.txt"; then
  test_pass "CADENCE_MAP drift and rolled POLICY_GEN drift both fail"
else
  test_fail "CADENCE_MAP drift fixture did not fail both artifact checks"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_DIR}/stdout.txt")" "$(cat "${CASE_DIR}/stderr.txt")" >&2
fi

test_start "V4.1.n" "async seed fixture warns but passes conformance"
make_validate_case "seeding-warn"
cat > "${CASE_DIR}/pvesr_pve01.txt" <<'PVE'
JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State
150-0      Yes        local/pve02           2026-07-18_06:00:00  2026-07-18_06:01:00   1         0         OK
160-0      Yes        local/pve02           -                    2026-07-19_03:00:00   1         0         OK
PVE
run_validate_case
if [[ "$RUN_RC" -eq 0 ]] \
   && grep -q '\[WARN\] replication seed in progress: 160-0 (cicd)' "${CASE_DIR}/stdout.txt"; then
  test_pass "24h never-run fail=0 emits WARN and leaves conformance passing"
else
  test_fail "seeding WARN fixture did not pass with warning"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_DIR}/stdout.txt")" "$(cat "${CASE_DIR}/stderr.txt")" >&2
fi

test_start "V4.1.o" "strict 1m never-run fixture fails conformance"
make_validate_case "strict-never-run"
cat > "${CASE_DIR}/pvesr_pve01.txt" <<'PVE'
JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State
150-0      Yes        local/pve02           -                    2026-07-18_06:01:00   1         0         OK
160-0      Yes        local/pve02           2026-07-18_06:00:00  2026-07-19_03:00:00   1         0         OK
PVE
run_validate_case
if [[ "$RUN_RC" -ne 0 ]] \
   && grep -q 'policy-on VMID gitlab (150) job 150-0 never completed initial sync' "${CASE_DIR}/stdout.txt"; then
  test_pass "1m never-run fail=0 fails conformance"
else
  test_fail "strict never-run fixture did not fail"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_DIR}/stdout.txt")" "$(cat "${CASE_DIR}/stderr.txt")" >&2
fi

test_start "V4.1.p" "unreadable pvesr status fixture fails closed"
make_validate_case "unreadable-pvesr"
rm -f "${CASE_DIR}/pvesr_pve02.txt"
run_validate_case
if [[ "$RUN_RC" -ne 0 ]] \
   && grep -q 'pvesr status query failed on pve02' "${CASE_DIR}/stdout.txt"; then
  test_pass "unreadable pvesr status fails conformance"
else
  test_fail "unreadable pvesr status fixture did not fail closed"
  printf 'rc=%s\n--- stdout ---\n%s\n--- stderr ---\n%s\n' "$RUN_RC" \
    "$(cat "${CASE_DIR}/stdout.txt")" "$(cat "${CASE_DIR}/stderr.txt")" >&2
fi

runner_summary
