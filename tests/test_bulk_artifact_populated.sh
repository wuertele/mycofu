#!/usr/bin/env bash
# test_bulk_artifact_populated.sh — Sprint 045 / #518 (A6).
#
# Covers the bulk-artifact population fix end to end:
#   - aggregate-preboot-status.sh merges per-phase status files, and the H1
#     regression case (an empty bulk phase must NOT clobber the atomic entries).
#   - check_bulk_artifacts_populated.sh FAILs on a clobbered/short artifact,
#     passes the both-empty legitimate no-op.
#   - restore-before-start.sh and vdb-park-lib.sh manifest-vs-entries parity
#     checks (non-empty manifest with a missing VMID entry => FAIL naming it).
#   - Sprint-044 park-status contract is preserved (their suites stay green).
#
# RCA: docs/reports/2026-07-08-issue-518-bulk-artifact-rca.md (H1: one shared
# preboot-restore-status-all.json overwritten whole by each phase).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

AGG="${REPO_ROOT}/framework/scripts/aggregate-preboot-status.sh"
CHECK="${REPO_ROOT}/framework/scripts/check_bulk_artifacts_populated.sh"
RBS="${REPO_ROOT}/framework/scripts/restore-before-start.sh"
PARK_LIB="${REPO_ROOT}/framework/scripts/vdb-park-lib.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# Emit a phase status file: $1=path $2=generated_at $3...=vmid entries (vmid:status)
write_phase_status() {
  local path="$1" gen="$2"; shift 2
  local entries="[]"
  local parts=()
  for spec in "$@"; do
    local vmid="${spec%%:*}" st="${spec##*:}"
    parts+=("{\"label\":\"vm${vmid}\",\"vmid\":${vmid},\"env\":\"dev\",\"status\":\"${st}\"}")
  done
  local joined
  joined="$(IFS=,; echo "${parts[*]-}")"
  printf '{"version":1,"scope":"all","generated_at":"%s","entries":[%s]}\n' "$gen" "$joined" > "$path"
}

# ===================== BA.1 — H1 regression (empty bulk must not clobber) =====
test_start "BA.1" "aggregate: empty bulk phase does NOT clobber the atomic phase entries"
D="${TMP_DIR}/ba1"; mkdir -p "$D"
write_phase_status "${D}/preboot-restore-status-atomic-gitlab.json" "2026-07-08T10:00:00Z" "150:restored"
write_phase_status "${D}/preboot-restore-status-atomic-vault_dev.json" "2026-07-08T10:01:00Z" "302:spared"
write_phase_status "${D}/preboot-restore-status-bulk.json" "2026-07-08T10:05:00Z"   # empty bulk
bash "$AGG" --out "${D}/preboot-restore-status-all.json" --glob-dir "$D" 2>/dev/null
got="$(jq -c '[.entries[].vmid] | sort' "${D}/preboot-restore-status-all.json")"
if [[ "$got" == "[150,302]" ]]; then
  test_pass "BA.1: atomic entries 150,302 survive the empty bulk merge"
else
  test_fail "BA.1: expected [150,302], got ${got}"
fi

# ===================== BA.2 — both-empty legitimate no-op ======================
test_start "BA.2" "aggregate: all phases empty => entries:[] (no VM recreated)"
D="${TMP_DIR}/ba2"; mkdir -p "$D"
write_phase_status "${D}/preboot-restore-status-bulk.json" "2026-07-08T10:05:00Z"
bash "$AGG" --out "${D}/preboot-restore-status-all.json" --glob-dir "$D" 2>/dev/null
[[ "$(jq -c '.entries' "${D}/preboot-restore-status-all.json")" == "[]" ]] \
  && test_pass "BA.2: empty union yields entries:[]" \
  || test_fail "BA.2: expected empty entries"

# ===================== BA.3 — dedup by vmid, latest generated_at wins ==========
test_start "BA.3" "aggregate: a VMID present in two phases keeps the latest-generated entry"
D="${TMP_DIR}/ba3"; mkdir -p "$D"
write_phase_status "${D}/preboot-restore-status-atomic-a.json" "2026-07-08T10:00:00Z" "150:restored"
write_phase_status "${D}/preboot-restore-status-bulk.json"     "2026-07-08T10:09:00Z" "150:spared"
bash "$AGG" --out "${D}/preboot-restore-status-all.json" --glob-dir "$D" 2>/dev/null
n="$(jq '.entries | length' "${D}/preboot-restore-status-all.json")"
st="$(jq -r '.entries[0].status' "${D}/preboot-restore-status-all.json")"
if [[ "$n" == "1" && "$st" == "spared" ]]; then
  test_pass "BA.3: deduped to 1 entry, latest (spared) wins"
else
  test_fail "BA.3: expected 1 entry status=spared, got n=${n} status=${st}"
fi

# ===================== BA.4 — unreadable/missing phase files are skipped =======
test_start "BA.4" "aggregate: a malformed phase file is skipped, not fatal"
D="${TMP_DIR}/ba4"; mkdir -p "$D"
write_phase_status "${D}/preboot-restore-status-atomic-a.json" "2026-07-08T10:00:00Z" "150:restored"
printf 'not json{{{' > "${D}/preboot-restore-status-bulk.json"
set +e
bash "$AGG" --out "${D}/preboot-restore-status-all.json" --glob-dir "$D" 2>/dev/null
agg_rc=$?
set -e
got="$(jq -c '[.entries[].vmid]' "${D}/preboot-restore-status-all.json" 2>/dev/null || echo FAIL)"
if [[ "$agg_rc" -eq 0 && "$got" == "[150]" ]]; then
  test_pass "BA.4: malformed bulk skipped; atomic entry preserved"
else
  test_fail "BA.4: rc=${agg_rc} got=${got}"
fi

# ===================== BA.5 — checker PASS on a populated artifact =============
test_start "BA.5" "check: populated aggregated artifact matching manifests => PASS"
D="${TMP_DIR}/ba5"; mkdir -p "$D"
printf '{"version":1,"scope":"all","entries":[{"label":"gitlab","module":"m","vmid":150,"env":"prod","kind":"nix","reason":"create"}]}\n' > "${D}/preboot-restore-atomic-gitlab.json"
printf '{"version":1,"scope":"all","entries":[]}\n' > "${D}/preboot-restore-bulk.json"
write_phase_status "${D}/preboot-restore-status-atomic-gitlab.json" "2026-07-08T10:00:00Z" "150:restored"
write_phase_status "${D}/preboot-restore-status-bulk.json" "2026-07-08T10:05:00Z"
bash "$AGG" --out "${D}/preboot-restore-status-all.json" --glob-dir "$D" 2>/dev/null
set +e; bash "$CHECK" --build-dir "$D" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -eq 0 ]] && test_pass "BA.5: checker passes populated artifact" || test_fail "BA.5: checker rc=${rc}"

# ===================== BA.6 — checker FAIL on the H1 clobber symptom ===========
test_start "BA.6" "check: manifest names VMID 150 but status-all is empty => FAIL naming 150"
printf '{"version":1,"scope":"all","entries":[]}\n' > "${D}/preboot-restore-status-all.json"
set +e; out="$(bash "$CHECK" --build-dir "$D" 2>&1)"; rc=$?; set -e
if [[ "$rc" -ne 0 ]] && grep -q '150' <<<"$out"; then
  test_pass "BA.6: checker fails and names the missing VMID"
else
  test_fail "BA.6: rc=${rc} out=${out}"
fi

# ===================== BA.7 — checker FAIL when status-all absent ==============
test_start "BA.7" "check: manifest non-empty but status-all absent => FAIL"
rm -f "${D}/preboot-restore-status-all.json"
set +e; out="$(bash "$CHECK" --build-dir "$D" 2>&1)"; rc=$?; set -e
[[ "$rc" -ne 0 ]] && grep -qi 'absent' <<<"$out" \
  && test_pass "BA.7: absent aggregated artifact fails closed" \
  || test_fail "BA.7: rc=${rc} out=${out}"

# ===================== BA.8 — checker both-empty no-op PASS ====================
test_start "BA.8" "check: no manifest VMIDs + empty status => legitimate no-op PASS"
D="${TMP_DIR}/ba8"; mkdir -p "$D"
printf '{"version":1,"scope":"all","entries":[]}\n' > "${D}/preboot-restore-bulk.json"
printf '{"version":1,"scope":"all","entries":[]}\n' > "${D}/preboot-restore-status-all.json"
set +e; bash "$CHECK" --build-dir "$D" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -eq 0 ]] && test_pass "BA.8: both-empty no-op passes" || test_fail "BA.8: rc=${rc}"

# ===================== BA.9 — checker FAIL on malformed park artifact ==========
test_start "BA.9" "check: a malformed vdb-park-status file => FAIL"
D="${TMP_DIR}/ba9"; mkdir -p "$D"
printf '{"version":1,"scope":"all","entries":[]}\n' > "${D}/preboot-restore-bulk.json"
printf '{"version":1,"scope":"all","entries":[]}\n' > "${D}/preboot-restore-status-all.json"
printf 'garbage{{{' > "${D}/vdb-park-status-bulk.json"
set +e; out="$(bash "$CHECK" --build-dir "$D" 2>&1)"; rc=$?; set -e
[[ "$rc" -ne 0 ]] && grep -qi 'park' <<<"$out" \
  && test_pass "BA.9: malformed park artifact fails closed" \
  || test_fail "BA.9: rc=${rc} out=${out}"

# ===================== BA.10 — vdb_park_batch parity FIRES on a gap ============
test_start "BA.10" "park parity: an eligible VMID with no status entry => vdb_park_batch FAILs naming it"
D="${TMP_DIR}/ba10"; mkdir -p "$D"
printf '{"version":1,"scope":"all","entries":[]}\n' > "${D}/manifest.json"
out="$(
  set +e
  source "$PARK_LIB" 2>/dev/null
  set +e  # the lib re-enables set -e; keep it off so we can capture RC
  # Stub the surface vdb_park_batch depends on. vdb_park_one records ONLY 201,
  # silently dropping eligible 202 — the injected gap the parity check must catch.
  vdb_park_require_file() { return 0; }
  vdb_park_status_init() { printf '{"version":1,"scope":"%s","entries":[]}\n' "$2" > "$1"; }
  vdb_park_eligible_entry_jsons() {
    printf '%s\n' '{"label":"a","vmid":201,"env":"dev","reason":"replace"}'
    printf '%s\n' '{"label":"b","vmid":202,"env":"dev","reason":"replace"}'
  }
  vdb_park_one() {
    local entry="$1" status_file="$2" vmid
    vmid="$(jq -r '.vmid' <<<"$entry")"
    [[ "$vmid" == "201" ]] && vdb_park_status_upsert_json "$status_file" "$entry"
    return 0
  }
  vdb_park_error() { echo "PARK_ERROR: $*"; }
  vdb_unpark_batch() { return 0; }
  # vdb_park_batch re-enables set -e internally; the || idiom keeps our RC capture
  # from being aborted by the leaked set -e on a non-zero return.
  rc=0
  vdb_park_batch "${D}/manifest.json" "${D}/status.json" dev || rc=$?
  echo "RC=$rc"
)"
if grep -q 'RC=1' <<<"$out" && grep -q 'parity check failed' <<<"$out" && grep -q '202' <<<"$out"; then
  test_pass "BA.10: park parity fails closed and names missing VMID 202"
else
  test_fail "BA.10: out=${out}"
fi

# ===================== BA.11 — vdb_park_batch parity PASSES when all recorded ==
test_start "BA.11" "park parity: all eligible entries recorded => vdb_park_batch succeeds"
D="${TMP_DIR}/ba11"; mkdir -p "$D"
printf '{"version":1,"scope":"all","entries":[]}\n' > "${D}/manifest.json"
out="$(
  set +e
  source "$PARK_LIB" 2>/dev/null
  set +e  # the lib re-enables set -e; keep it off so we can capture RC
  vdb_park_require_file() { return 0; }
  vdb_park_status_init() { printf '{"version":1,"scope":"%s","entries":[]}\n' "$2" > "$1"; }
  vdb_park_eligible_entry_jsons() {
    printf '%s\n' '{"label":"a","vmid":201,"env":"dev","reason":"replace"}'
    printf '%s\n' '{"label":"b","vmid":202,"env":"dev","reason":"replace"}'
  }
  vdb_park_one() { vdb_park_status_upsert_json "$2" "$1"; return 0; }
  vdb_park_error() { echo "PARK_ERROR: $*"; }
  vdb_unpark_batch() { return 0; }
  rc=0
  vdb_park_batch "${D}/manifest.json" "${D}/status.json" dev || rc=$?
  echo "RC=$rc"
)"
if grep -q 'RC=0' <<<"$out" && ! grep -q 'parity check failed' <<<"$out"; then
  test_pass "BA.11: park parity passes when eligible == recorded"
else
  test_fail "BA.11: out=${out}"
fi

# ===================== BA.12 — restore-before-start parity guard present =======
# The inline guard is a defensive net that, by construction, only fires when a
# terminal branch skips status_add. It is exercised (non-firing) green by the
# 56-assertion test_restore_before_start.sh suite; here we ratchet its presence.
test_start "BA.12" "restore-before-start: manifest-vs-entries parity guard is wired"
if grep -q 'parity check failed (#518)' "$RBS" \
   && grep -q 'parity_manifest_vmids' "$RBS" \
   && grep -q 'parity_status_vmids' "$RBS"; then
  test_pass "BA.12: parity guard present and compares manifest vs status VMIDs"
else
  test_fail "BA.12: restore-before-start parity guard missing"
fi

# ===================== BA.13 — Sprint-044 park-status contract preserved =======
test_start "BA.13" "Sprint-044 park suites stay green under the #518 changes"
sub_ok=1
for t in test_vdb_park_lib test_configure_replication_park_status test_restore_spared_status; do
  if ! bash "${REPO_ROOT}/tests/${t}.sh" >/dev/null 2>&1; then
    test_fail "BA.13: ${t}.sh regressed"
    sub_ok=0
  fi
done
[[ "$sub_ok" -eq 1 ]] && test_pass "BA.13: vdb park lib + replication park-status + spared status suites pass"

runner_summary
