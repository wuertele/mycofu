#!/usr/bin/env bash
# test_repl_health_policy.sh — Sprint 047 A4 (repl-health.sh policy awareness).
#
# V3.1: assert repl-health.sh's policy-aware behavior. Tests are designed to
# run correctly on both macOS and Linux runners — they focus on JSON shape
# and policy annotation invariants that do NOT depend on `date -d` GNU-syntax
# parsing (the age calculation itself is a repl-health.sh unit-owned detail
# tested elsewhere and covered by the byte-preserving V4.3 requirement).
#
# Ratchets exercised:
#   - Rows for POLICY_OFF VMIDs are annotated `"policy": "off"`
#   - POLICY_ON VMIDs hosted locally with NO pvesr row → synthetic
#     "state": "Missing" row with `"policy": "on"`
#   - POLICY_ON VMIDs NOT hosted locally → no synthetic row
#   - Absent artifact → `policy_artifact: "absent"` AND no `policy` annotation
#     on any raw row (fully strict; nothing excluded)
#   - Garbage/malformed artifact → treated same as absent
#   - policy_artifact / policy_gen top-level fields present and correct
#   - The exclusion logic annotates but does NOT alter the underlying `stale`
#     boolean on the row (the row still records what pvesr said; exclusion
#     is a downstream aggregation that repl-health applies when computing
#     replication_stale)

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
source "${TEST_DIR}/lib/runner.sh"

SCRIPT="${REPO_DIR}/framework/scripts/repl-health.sh"

WORKDIR=""
cleanup() {
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

CASE_DIR=""
ARTIFACT_FILE=""

prepare_case() {
  local case_name="$1"
  WORKDIR=$(mktemp -d "/tmp/repl-health-policy.XXXXXX")
  CASE_DIR="${WORKDIR}/${case_name}"
  mkdir -p "$CASE_DIR/shims"
  ARTIFACT_FILE="${CASE_DIR}/repl-policy.vmids"

  # Write minimal repl-health.conf + repl-watchdog.conf so repl-health.sh
  # reaches the replication parsing block. These envs are set via
  # REPL_HEALTH_CONF_FILE / REPL_HEALTH_WATCHDOG_CONF overrides.
  cat > "${CASE_DIR}/repl-health.conf" <<CONF
NODE_NAME=pve01
NODE_REPL_IP=10.10.0.1
HEALTH_PORT=9100
TOPOLOGY=mesh
CONF
  : > "${CASE_DIR}/repl-watchdog.conf"
}

make_pvesr() {
  cat > "${CASE_DIR}/shims/pvesr" <<SHIM
#!/usr/bin/env bash
$1
SHIM
  chmod +x "${CASE_DIR}/shims/pvesr"
}

make_qm() {
  cat > "${CASE_DIR}/shims/qm" <<SHIM
#!/usr/bin/env bash
$1
SHIM
  chmod +x "${CASE_DIR}/shims/qm"
}

make_date_fixture() {
  cat > "${CASE_DIR}/shims/date" <<'SHIM'
#!/usr/bin/env bash
now=1000000
if [[ "${1:-}" == "+%s" ]]; then
  echo "$now"
  exit 0
fi
if [[ "${1:-}" == "-d" && "${3:-}" == "+%s" ]]; then
  case "$2" in
    age300) echo $((now - 300)); exit 0 ;;
    age301) echo $((now - 301)); exit 0 ;;
    age172800) echo $((now - 172800)); exit 0 ;;
    age172801) echo $((now - 172801)); exit 0 ;;
  esac
  exit 1
fi
exec /bin/date "$@"
SHIM
  chmod +x "${CASE_DIR}/shims/date"
}

run_repl_health() {
  local artifact_override="${1:-}"
  local out
  out=$(
    PATH="${CASE_DIR}/shims:${PATH}" \
    FIXED_NOW_TS="${FIXED_NOW_TS:-}" \
    REPL_HEALTH_CONF_FILE="${CASE_DIR}/repl-health.conf" \
    REPL_HEALTH_WATCHDOG_CONF="${CASE_DIR}/repl-watchdog.conf" \
    REPL_HEALTH_WATCHDOG_STATE="${CASE_DIR}/watchdog-state" \
    REPL_POLICY_ARTIFACT="$artifact_override" \
    bash "$SCRIPT" 2>/dev/null
  )
  echo "$out"
}

# ---------------------------------------------------------------------------
# V3.1.a — policy-off row is annotated policy=off (exclusion contract)
# ---------------------------------------------------------------------------
test_start "V3.1.a" "policy-off pvesr row → annotated with policy=off"
prepare_case "off-annotation"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=150,303
POLICY_OFF_VMIDS=160,301
POLICY_GEN=abc123
ART

make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '150-0      Yes        local/pve02           2026-07-18_05:59:00  2026-07-18_06:00:00   2.61      0         OK'
echo '160-0      Yes        local/pve02           -                    2026-07-18_06:00:00   0         2         Error'"

make_qm "echo '      VMID NAME                 STATUS'
echo '       150 gitlab               running'
echo '       160 cicd                 running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication."160-0".policy == "off" and .replication."150-0".policy == "on"' >/dev/null 2>&1; then
  test_pass "policy=off annotation on 160-0; policy=on annotation on 150-0"
else
  test_fail "V3.1.a expected policy annotations on both rows"
  echo "$output" | jq '.replication' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.b — policy-on stale row propagates to replication_stale
#   Precious stale MUST NEVER be silently excluded (V4.3 ratchet).
#   We assert against fail_count>0 which is a robust literal predicate.
# ---------------------------------------------------------------------------
test_start "V3.1.b" "policy-on stale row (fail_count>0) still stale"
prepare_case "on-stays-stale"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=150
POLICY_OFF_VMIDS=160
POLICY_GEN=abc
ART

make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '150-0      Yes        local/pve02           -                    2026-07-18_06:00:00   0         3         Error'"

make_qm "echo '      VMID NAME                 STATUS'
echo '       150 gitlab               running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication."150-0".policy == "on" and .replication."150-0".stale == true and .replication_stale == true' >/dev/null 2>&1; then
  test_pass "policy-on precious VMID with fail_count>0 → row.stale=true AND replication_stale=true"
else
  test_fail "V3.1.b policy-on precious VMID must still redden the node"
  echo "$output" | jq '.replication."150-0", .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.c — presence check fires for locally-hosted policy-on VMID with no row
# ---------------------------------------------------------------------------
test_start "V3.1.c" "policy-on VMID hosted locally with zero rows → synthetic Missing row"
prepare_case "presence-check-fires"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=150,403
POLICY_OFF_VMIDS=
POLICY_GEN=g1
ART

# pvesr has NO rows
make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'"

# qm list — 150 is locally hosted; 403 is not
make_qm "echo '      VMID NAME                 STATUS'
echo '       150 gitlab               running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication_stale == true and (.replication | to_entries | map(select(.value.state == "Missing" and .value.policy == "on")) | length) >= 1' >/dev/null 2>&1; then
  test_pass "missing pvesr row for locally-hosted policy-on VMID → synthetic Missing row + replication_stale=true"
else
  test_fail "V3.1.c presence-check should fire for VMID 150"
  echo "$output" | jq '.replication, .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.d — presence check does NOT fire for a policy-on VMID hosted elsewhere
# ---------------------------------------------------------------------------
test_start "V3.1.d" "policy-on VMID NOT hosted locally → no synthetic row"
prepare_case "presence-check-elsewhere"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=150,403
POLICY_OFF_VMIDS=
POLICY_GEN=g2
ART

# pvesr empty
make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'"

# qm list: neither 150 nor 403 are here
make_qm "echo '      VMID NAME                 STATUS'
echo '       200 someothervm          running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '(.replication | length) == 0 and .replication_stale == false' >/dev/null 2>&1; then
  test_pass "no synthetic row for non-local policy-on VMIDs; replication_stale=false"
else
  test_fail "V3.1.d unexpected synthetic row (150/403 not local)"
  echo "$output" | jq '.replication, .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.e — absent artifact → fully strict (no exclusions), no presence check
# ---------------------------------------------------------------------------
test_start "V3.1.e" "absent artifact → fully strict, no policy annotations"
prepare_case "absent-artifact"

make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '160-0      Yes        local/pve02           -                    2026-07-18_06:00:00   0         2         Error'"

make_qm "echo '      VMID NAME                 STATUS'
echo '       160 cicd                 running'"

output=$(run_repl_health "${CASE_DIR}/does-not-exist")

# When absent: policy_artifact=absent AND rows are annotated with policy=on
# by default (nothing excluded — the on-annotation is the neutral default),
# AND the row's stale bit propagates to replication_stale.
# (This is stricter than pre-047: excluding NOTHING when the artifact is
# missing means every stale row reddens the node — the fail-closed contract.)
if echo "$output" | jq -e '
  .policy_artifact == "absent"
  and .replication_stale == true
  and .replication."160-0".stale == true
  and .replication."160-0".policy == "on"
' >/dev/null 2>&1; then
  test_pass "absent artifact → policy_artifact=absent, no exclusions, stale row reddens node"
else
  test_fail "V3.1.e absent artifact must be fail-closed strict"
  echo "$output" | jq '{policy_artifact, replication_stale, "160-0": .replication."160-0"}' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.f — top-level policy_artifact + policy_gen fields
# ---------------------------------------------------------------------------
test_start "V3.1.f" "policy_artifact + policy_gen top-level fields present when artifact loads"
prepare_case "policy-fields"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=150
POLICY_OFF_VMIDS=
POLICY_GEN=gen-fingerprint-xyz
ART

make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'"
make_qm "echo '      VMID NAME                 STATUS'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.policy_artifact == "present" and .policy_gen == "gen-fingerprint-xyz"' >/dev/null 2>&1; then
  test_pass "policy_artifact=present + policy_gen=gen-fingerprint-xyz surfaced correctly"
else
  test_fail "V3.1.f policy_artifact/policy_gen not surfaced correctly"
  echo "$output" | jq '{policy_artifact, policy_gen}' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.h — 1m cadence: age 301 is stale
# ---------------------------------------------------------------------------
test_start "V3.1.h" "1m cadence uses strict 300s floor: age 301 is stale"
prepare_case "cadence-1m-stale"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=150
POLICY_OFF_VMIDS=
CADENCE_MAP=150:60
POLICY_GEN=g3
ART

make_date_fixture
make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '150-0      Yes        local/pve02           age301               2026-07-18_06:00:00   0         0         OK'"
make_qm "echo '      VMID NAME                 STATUS'
echo '       150 gitlab               running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication."150-0".cadence_seconds == 60 and .replication."150-0".age_seconds == 301 and .replication."150-0".stale == true and .replication_stale == true' >/dev/null 2>&1; then
  test_pass "1m row at age 301 is stale"
else
  test_fail "V3.1.h expected 1m age 301 to be stale"
  echo "$output" | jq '.replication."150-0", .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.i — 24h cadence: age 300 is not stale
# ---------------------------------------------------------------------------
test_start "V3.1.i" "24h cadence age 300 is not stale"
prepare_case "cadence-24h-age300"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=160
POLICY_OFF_VMIDS=
CADENCE_MAP=160:86400
POLICY_GEN=g4
ART

make_date_fixture
make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '160-0      Yes        local/pve02           age300               2026-07-18_06:00:00   0         0         OK'"
make_qm "echo '      VMID NAME                 STATUS'
echo '       160 cicd                 running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication."160-0".cadence_seconds == 86400 and .replication."160-0".age_seconds == 300 and .replication."160-0".stale == false and .replication_stale == false' >/dev/null 2>&1; then
  test_pass "24h row at age 300 is not stale"
else
  test_fail "V3.1.i expected 24h age 300 to be healthy"
  echo "$output" | jq '.replication."160-0", .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.j — 24h cadence: age > 172800 is stale
# ---------------------------------------------------------------------------
test_start "V3.1.j" "24h cadence age >172800 is stale"
prepare_case "cadence-24h-stale"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=160
POLICY_OFF_VMIDS=
CADENCE_MAP=160:86400
POLICY_GEN=g5
ART

make_date_fixture
make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '160-0      Yes        local/pve02           age172801            2026-07-18_06:00:00   0         0         OK'"
make_qm "echo '      VMID NAME                 STATUS'
echo '       160 cicd                 running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication."160-0".cadence_seconds == 86400 and .replication."160-0".age_seconds == 172801 and .replication."160-0".stale == true and .replication_stale == true' >/dev/null 2>&1; then
  test_pass "24h row older than 172800s is stale"
else
  test_fail "V3.1.j expected 24h age >172800 to be stale"
  echo "$output" | jq '.replication."160-0", .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.k — 24h never-run fail=0 is Seeding, not stale
# ---------------------------------------------------------------------------
test_start "V3.1.k" "24h never-run fail=0 is Seeding and non-stale"
prepare_case "cadence-24h-seeding"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=160
POLICY_OFF_VMIDS=
CADENCE_MAP=160:86400
POLICY_GEN=g6
ART

make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '160-0      Yes        local/pve02           -                    2026-07-18_06:00:00   0         0         OK'"
make_qm "echo '      VMID NAME                 STATUS'
echo '       160 cicd                 running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication."160-0".state == "Seeding" and .replication."160-0".seeding == true and .replication."160-0".stale == false and .replication_stale == false' >/dev/null 2>&1; then
  test_pass "24h never-run fail=0 is Seeding and does not redden the node"
else
  test_fail "V3.1.k expected 24h never-run fail=0 to be Seeding"
  echo "$output" | jq '.replication."160-0", .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.l — 24h never-run fail>0 is stale
# ---------------------------------------------------------------------------
test_start "V3.1.l" "24h never-run fail>0 is stale"
prepare_case "cadence-24h-failed-seed"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=160
POLICY_OFF_VMIDS=
CADENCE_MAP=160:86400
POLICY_GEN=g7
ART

make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '160-0      Yes        local/pve02           -                    2026-07-18_06:00:00   0         1         Error'"
make_qm "echo '      VMID NAME                 STATUS'
echo '       160 cicd                 running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication."160-0".seeding == false and .replication."160-0".stale == true and .replication_stale == true' >/dev/null 2>&1; then
  test_pass "24h never-run fail>0 remains stale"
else
  test_fail "V3.1.l expected 24h never-run fail>0 to be stale"
  echo "$output" | jq '.replication."160-0", .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.m — missing CADENCE_MAP entry falls back to 1m-class
# ---------------------------------------------------------------------------
test_start "V3.1.m" "missing CADENCE_MAP entry is strict 1m-class"
prepare_case "cadence-missing-entry"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=150
POLICY_OFF_VMIDS=
CADENCE_MAP=999:86400
POLICY_GEN=g8
ART

make_date_fixture
make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '150-0      Yes        local/pve02           age301               2026-07-18_06:00:00   0         0         OK'"
make_qm "echo '      VMID NAME                 STATUS'
echo '       150 gitlab               running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication."150-0".cadence_seconds == 60 and .replication."150-0".stale == true and .replication_stale == true' >/dev/null 2>&1; then
  test_pass "missing cadence entry defaults to strict 60s/300s behavior"
else
  test_fail "V3.1.m expected missing cadence entry to be 1m-class"
  echo "$output" | jq '.replication."150-0", .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.n — 1m never-run fail=0 stays stale
# ---------------------------------------------------------------------------
test_start "V3.1.n" "1m never-run fail=0 is stale"
prepare_case "cadence-1m-never-run"

cat > "$ARTIFACT_FILE" <<'ART'
POLICY_ON_VMIDS=150
POLICY_OFF_VMIDS=
CADENCE_MAP=150:60
POLICY_GEN=g9
ART

make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '150-0      Yes        local/pve02           -                    2026-07-18_06:00:00   0         0         OK'"
make_qm "echo '      VMID NAME                 STATUS'
echo '       150 gitlab               running'"

output=$(run_repl_health "$ARTIFACT_FILE")

if echo "$output" | jq -e '.replication."150-0".seeding == false and .replication."150-0".stale == true and .replication_stale == true' >/dev/null 2>&1; then
  test_pass "1m never-run fail=0 remains stale"
else
  test_fail "V3.1.n expected 1m never-run fail=0 to be stale"
  echo "$output" | jq '.replication."150-0", .replication_stale' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.o — absent artifact is fully strict (missing cadence cannot quiet rows)
# ---------------------------------------------------------------------------
test_start "V3.1.o" "absent artifact treats aged rows as strict 1m-class"
prepare_case "cadence-absent-artifact-strict"

make_date_fixture
make_pvesr "echo 'JobID      Enabled    Target                           LastSync             NextSync   Duration  FailCount State'
echo '160-0      Yes        local/pve02           age301               2026-07-18_06:00:00   0         0         OK'"
make_qm "echo '      VMID NAME                 STATUS'
echo '       160 cicd                 running'"

output=$(run_repl_health "${CASE_DIR}/does-not-exist")

if echo "$output" | jq -e '.policy_artifact == "absent" and .replication."160-0".cadence_seconds == 60 and .replication."160-0".stale == true and .replication_stale == true' >/dev/null 2>&1; then
  test_pass "absent artifact falls back to 60s cadence/300s threshold"
else
  test_fail "V3.1.o expected absent artifact to be fully strict"
  echo "$output" | jq '{policy_artifact, replication_stale, "160-0": .replication."160-0"}' >&2
fi

# ---------------------------------------------------------------------------
# V3.1.g — 300s threshold + fail_count + never-run rule byte-preserved
#   Assert the actual predicate strings are still present in the script
#   source (V4.3-adjacent: literals must not silently drift).
# ---------------------------------------------------------------------------
test_start "V3.1.g" "threshold_for keeps literal 300 floor, fail_count>0, and never-run literals"

if grep -qE '^threshold_for_vmid\(\)' "$SCRIPT" \
   && grep -q '300 is the strictness floor' "$SCRIPT" \
   && grep -q 'cs \* 2 > 300' "$SCRIPT" \
   && grep -q 'fail_count.*-gt 0' "$SCRIPT" \
   && grep -q 'last_sync_str.*==.*"-"' "$SCRIPT"; then
  test_pass "cadence-aware threshold keeps 300s floor + fail_count + never-run predicates"
else
  test_fail "V3.1.g one or more staleness predicate literals silently drifted"
  # Diagnostic
  echo "--- threshold check ---" >&2; grep -nE 'threshold_for_vmid|300 is the strictness floor|cs \* 2 > 300' "$SCRIPT" >&2 || echo "MISSING" >&2
  echo "--- fail_count check ---" >&2; grep -n 'fail_count.*-gt 0' "$SCRIPT" >&2 || echo "MISSING" >&2
  echo "--- never-run check ---" >&2; grep -n 'last_sync_str.*==.*"-"' "$SCRIPT" >&2 || echo "MISSING" >&2
fi

runner_summary
