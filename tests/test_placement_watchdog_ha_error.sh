#!/usr/bin/env bash
# test_placement_watchdog_ha_error.sh — Hermetic tests for the placement-watchdog
# HA-error probe (Sprint 045 / #519, A5).
#
# The watchdog gains a READ-ONLY HA-error probe: it classifies the DRT-005
# outage shape (no drift + services stuck in HA `error`), plus
# requested-started-but-not-running and config-manifest-VM-not-running, and on an
# outage it logs the storage-failure-fence remediation ladder + the
# realign-cidata.sh pointer. It must NEVER invoke a cluster write — not even
# rebalance-cluster.sh (verify-only). These tests assert the classification, the
# backward-compatible --detect-only superset (ha_healthy + ha_errors, legacy
# fields unchanged), and — critically — that rebalance-cluster.sh is not invoked
# on any HA-error path.
#
# Strategy: run a byte-identical COPY of the watchdog in a temp bin dir next to a
# recording rebalance-cluster.sh shim (so SCRIPT_DIR resolves to the shim, and we
# can assert it was / was not called). An `ssh` PATH-shim serves per-scenario
# fixtures for `true` (reachability), `pvesh get /cluster/resources`,
# `ha-manager status`, and `ha-manager config`. LOG_FILE is redirected to a temp
# file via PLACEMENT_WATCHDOG_LOG.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

WATCHDOG_SRC="${REPO_ROOT}/framework/scripts/placement-watchdog.sh"

# yq is a mandatory framework dependency (config parsing). Skip locally if
# absent, but never skip silently in CI (a CI skip is a silent lie).
if ! command -v yq >/dev/null; then
  if [[ -n "${CI:-}${GITLAB_CI:-}" ]]; then
    echo "FAIL: yq not installed (mandatory framework dep, refusing to skip in CI)"
    exit 1
  fi
  echo "SKIP: yq not installed (local run only)"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="${TMP_DIR}/bin"          # copy of watchdog + rebalance shim live here
SHIM_DIR="${TMP_DIR}/shims"       # ssh shim on PATH
CFG_DIR="${TMP_DIR}/cfg"          # WATCHDOG_CONFIG_DIR (config.yaml)
FIX_DIR="${TMP_DIR}/fix"          # per-scenario fixtures
mkdir -p "$BIN_DIR" "$SHIM_DIR" "$CFG_DIR" "$FIX_DIR"

# Byte-identical copy of the watchdog (so we test the real logic, but SCRIPT_DIR
# resolves to our recording rebalance shim rather than the real script).
cp "$WATCHDOG_SRC" "${BIN_DIR}/placement-watchdog.sh"
chmod +x "${BIN_DIR}/placement-watchdog.sh"

REBALANCE_INVOCATION_LOG="${TMP_DIR}/rebalance-invocations.log"
: > "$REBALANCE_INVOCATION_LOG"

# Recording rebalance shim — ANY invocation is a cluster-write violation on the
# HA-error paths, and the expected action on the drift-only regression path.
cat > "${BIN_DIR}/rebalance-cluster.sh" <<REBAL
#!/usr/bin/env bash
echo "REBALANCE_INVOKED \$*" >> "${REBALANCE_INVOCATION_LOG}"
exit 0
REBAL
chmod +x "${BIN_DIR}/rebalance-cluster.sh"

# ssh shim — dispatch on the remote command (last positional arg).
cat > "${SHIM_DIR}/ssh" <<'SSH'
#!/usr/bin/env bash
dest=""
for a in "$@"; do
  case "$a" in root@*) dest="$a";; esac
done
cmd="${@: -1}"
# Down-node simulation: every command to this destination fails.
if [[ -n "${DOWN_NODE_IP:-}" && "$dest" == "root@${DOWN_NODE_IP}" ]]; then
  exit 255
fi
case "$cmd" in
  true) exit 0 ;;
  "pvesh get /cluster/resources"*) cat "${FIX_RESOURCES}"; exit 0 ;;
  "ha-manager status") cat "${FIX_HA_STATUS}"; exit 0 ;;
  "ha-manager config") cat "${FIX_HA_CONFIG}"; exit 0 ;;
  *) echo "unexpected ssh cmd: ${cmd}" >&2; exit 3 ;;
esac
SSH
chmod +x "${SHIM_DIR}/ssh"

# Fixture config: 3 nodes; intended placement dns1_prod=pve01, dns2_prod=pve02,
# testapp_prod=pve02. Actual placement is set per-scenario in the resources file.
cat > "${CFG_DIR}/config.yaml" <<'CFG'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
  - name: pve02
    mgmt_ip: 10.0.0.2
  - name: pve03
    mgmt_ip: 10.0.0.3
vms:
  dns1_prod:
    node: pve01
    vmid: 401
  dns2_prod:
    node: pve02
    vmid: 402
  testapp_prod:
    node: pve02
    vmid: 500
applications: {}
CFG

# --- Fixture builders (write per-scenario resource/status/config files) ---

# Resources JSON. Args pick testapp's node + status to induce drift / not-running.
# Usage: write_resources <testapp_node> <testapp_status>
write_resources() {
  local ta_node="$1" ta_status="$2"
  cat > "${FIX_DIR}/resources.json" <<RES
[
  {"type":"qemu","vmid":401,"name":"dns1-prod","node":"pve01","status":"running"},
  {"type":"qemu","vmid":402,"name":"dns2-prod","node":"pve02","status":"running"},
  {"type":"qemu","vmid":500,"name":"testapp-prod","node":"${ta_node}","status":"${ta_status}"}
]
RES
}

# HA status. Usage: write_ha_status <testapp_state>  (started|error)
write_ha_status() {
  local ta_state="$1"
  cat > "${FIX_DIR}/ha_status" <<HAS
quorum OK
master pve01 (active, ...)
lrm pve01 (active, ...)
service vm:401 (pve01, started)
service vm:402 (pve02, started)
service vm:500 (pve02, ${ta_state})
HAS
}

# HA config — all VMs HA-managed, requested state started (default).
cat > "${FIX_DIR}/ha_config" <<'HAC'
vm:401
	state started
vm:402
	state started
vm:500
	state started
HAC

# --- Scenario runner ---
# run_watchdog <mode: detect|normal>  — echoes stdout; sets RC.
DETECT_OUT=""
LAST_RC=0
LAST_LOG="${TMP_DIR}/last.log"

run_watchdog() {
  local mode="$1"
  : > "$REBALANCE_INVOCATION_LOG"
  : > "$LAST_LOG"
  local args=()
  [[ "$mode" == "detect" ]] && args=(--detect-only)
  set +e
  DETECT_OUT=$(
    PATH="${SHIM_DIR}:${PATH}" \
    WATCHDOG_CONFIG_DIR="${CFG_DIR}" \
    PLACEMENT_WATCHDOG_LOG="${LAST_LOG}" \
    FIX_RESOURCES="${FIX_DIR}/resources.json" \
    FIX_HA_STATUS="${FIX_DIR}/ha_status" \
    FIX_HA_CONFIG="${FIX_DIR}/ha_config" \
    DOWN_NODE_IP="${DOWN_NODE_IP:-}" \
      bash "${BIN_DIR}/placement-watchdog.sh" ${args[@]+"${args[@]}"}
  )
  LAST_RC=$?
  set -e
}

# JSON field extractor (python3 — always present on the NAS and CI).
json_field() {
  local json="$1" expr="$2"
  printf '%s' "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print($expr)" 2>/dev/null
}

assert_no_rebalance() {
  local detail="$1"
  if [[ -s "$REBALANCE_INVOCATION_LOG" ]]; then
    test_fail "${detail}: rebalance-cluster.sh WAS invoked (cluster-write violation)"
    sed 's/^/    /' "$REBALANCE_INVOCATION_LOG" >&2
  else
    test_pass "${detail}: no cluster write (rebalance-cluster.sh not invoked)"
  fi
}

assert_rebalance_invoked() {
  local detail="$1"
  if [[ -s "$REBALANCE_INVOCATION_LOG" ]]; then
    test_pass "${detail}: rebalance-cluster.sh invoked (drift-only path preserved)"
  else
    test_fail "${detail}: rebalance-cluster.sh was NOT invoked (drift path regressed)"
  fi
}

# ========================= WH.1 — neither (healthy) =========================
test_start "WH.1" "neither drift nor HA error: detect-only healthy superset; normal exits clean, no write"
write_resources pve02 running   # testapp on intended node
write_ha_status started
DOWN_NODE_IP="" run_watchdog detect
if [[ "$(json_field "$DETECT_OUT" 'd["ha_healthy"]')" == "True" ]]; then
  test_pass "WH.1: ha_healthy true"
else
  test_fail "WH.1: expected ha_healthy true, got: ${DETECT_OUT}"
fi
[[ "$(json_field "$DETECT_OUT" 'len(d["ha_errors"])')" == "0" ]] \
  && test_pass "WH.1: ha_errors empty" || test_fail "WH.1: ha_errors not empty: ${DETECT_OUT}"
# Legacy fields present + unchanged shape.
[[ "$(json_field "$DETECT_OUT" 'd["placement_healthy"]')" == "True" ]] \
  && test_pass "WH.1: legacy placement_healthy present/true" || test_fail "WH.1: placement_healthy wrong: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" 'd["all_nodes_up"]')" == "True" ]] \
  && test_pass "WH.1: legacy all_nodes_up present/true" || test_fail "WH.1: all_nodes_up wrong: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" 'len(d["drift"])')" == "0" ]] \
  && test_pass "WH.1: legacy drift present/empty" || test_fail "WH.1: drift wrong: ${DETECT_OUT}"
DOWN_NODE_IP="" run_watchdog normal
[[ "$LAST_RC" -eq 0 ]] && test_pass "WH.1: normal mode exit 0" || test_fail "WH.1: normal exit ${LAST_RC}"
assert_no_rebalance "WH.1"

# ==================== WH.2 — HA-error only (DRT-005 shape) ===================
test_start "WH.2" "no drift + vm:500 in HA error: outage detected, ladder logged, NO write"
write_resources pve02 stopped   # on intended node (no drift), but stopped
write_ha_status error
DOWN_NODE_IP="" run_watchdog detect
[[ "$(json_field "$DETECT_OUT" 'd["ha_healthy"]')" == "False" ]] \
  && test_pass "WH.2: ha_healthy false" || test_fail "WH.2: expected ha_healthy false: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" '[e["vmid"] for e in d["ha_errors"]]')" == "[500]" ]] \
  && test_pass "WH.2: ha_errors names vm:500" || test_fail "WH.2: ha_errors wrong: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" 'd["ha_errors"][0]["state"]')" == "error" ]] \
  && test_pass "WH.2: classified as error state" || test_fail "WH.2: state wrong: ${DETECT_OUT}"
# Legacy fields still healthy for placement (no drift) — superset preserved.
[[ "$(json_field "$DETECT_OUT" 'len(d["drift"])')" == "0" ]] \
  && test_pass "WH.2: no drift in legacy field (DRT-005 shape)" || test_fail "WH.2: drift unexpectedly present: ${DETECT_OUT}"
DOWN_NODE_IP="" run_watchdog normal
[[ "$LAST_RC" -eq 0 ]] && test_pass "WH.2: normal mode exit 0 (detection is the action)" || test_fail "WH.2: exit ${LAST_RC}"
assert_no_rebalance "WH.2"
grep -q "HA outage detected" "$LAST_LOG" \
  && test_pass "WH.2: outage logged" || test_fail "WH.2: outage not logged"
grep -q "storage-failure-fence" "$LAST_LOG" \
  && test_pass "WH.2: storage-failure-fence remediation ladder printed" || test_fail "WH.2: ladder missing"
grep -q "realign-cidata.sh" "$LAST_LOG" \
  && test_pass "WH.2: realign-cidata.sh pointer printed" || test_fail "WH.2: realign pointer missing"
grep -q "6A" "$LAST_LOG" && grep -q "6B" "$LAST_LOG" \
  && test_pass "WH.2: 6A/6B ladder branches present" || test_fail "WH.2: 6A/6B branches missing"

# ============= WH.3 — requested-started-but-not-running (not error) ==========
test_start "WH.3" "vm:500 HA state started but VM stopped: classified as outage (requested-started-not-running)"
write_resources pve02 stopped   # no drift; status stopped
write_ha_status started         # HA says started, but VM is not running
DOWN_NODE_IP="" run_watchdog detect
[[ "$(json_field "$DETECT_OUT" 'd["ha_healthy"]')" == "False" ]] \
  && test_pass "WH.3: ha_healthy false" || test_fail "WH.3: expected ha_healthy false: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" '[e["vmid"] for e in d["ha_errors"]]')" == "[500]" ]] \
  && test_pass "WH.3: ha_errors names vm:500" || test_fail "WH.3: ha_errors wrong: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" '"not running" in d["ha_errors"][0]["reason"]')" == "True" ]] \
  && test_pass "WH.3: reason is requested-started-but-not-running" || test_fail "WH.3: reason wrong: ${DETECT_OUT}"
DOWN_NODE_IP="" run_watchdog normal
assert_no_rebalance "WH.3"

# ==================== WH.4 — both drift AND HA error ========================
test_start "WH.4" "drift + HA error: outage path wins, NO rebalance (detection only)"
write_resources pve03 running   # testapp drifted to pve03 (intended pve02), still running
write_ha_status error           # ...and its HA service is in error
DOWN_NODE_IP="" run_watchdog detect
[[ "$(json_field "$DETECT_OUT" 'd["ha_healthy"]')" == "False" ]] \
  && test_pass "WH.4: ha_healthy false" || test_fail "WH.4: expected ha_healthy false: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" 'len(d["drift"])')" == "1" ]] \
  && test_pass "WH.4: drift also reported (superset intact)" || test_fail "WH.4: drift wrong: ${DETECT_OUT}"
DOWN_NODE_IP="" run_watchdog normal
[[ "$LAST_RC" -eq 0 ]] && test_pass "WH.4: normal exit 0" || test_fail "WH.4: exit ${LAST_RC}"
assert_no_rebalance "WH.4"

# ================= WH.5 — drift-only regression (HA healthy) =================
test_start "WH.5" "drift + HA healthy: rebalance IS invoked (existing path not regressed by the probe)"
write_resources pve03 running   # drifted but healthy/running
write_ha_status started
DOWN_NODE_IP="" run_watchdog normal
[[ "$LAST_RC" -eq 0 ]] && test_pass "WH.5: normal exit 0" || test_fail "WH.5: exit ${LAST_RC}"
assert_rebalance_invoked "WH.5"

# ===================== WH.6 — node down + drift ============================
test_start "WH.6" "one node down + drift + HA healthy: nodes-down wait path, NO rebalance"
write_resources pve03 running   # drift present (intended pve02)
write_ha_status started
DOWN_NODE_IP="10.0.0.3" run_watchdog normal
[[ "$LAST_RC" -eq 0 ]] && test_pass "WH.6: normal exit 0" || test_fail "WH.6: exit ${LAST_RC}"
assert_no_rebalance "WH.6"
grep -qi "Node(s) down" "$LAST_LOG" \
  && test_pass "WH.6: nodes-down wait logged (legacy behavior preserved)" || test_fail "WH.6: nodes-down not logged"

# =============== WH.7 — detect-only JSON validity + legacy keys ==============
test_start "WH.7" "detect-only output is valid JSON with the full legacy + superset key set"
write_resources pve02 running
write_ha_status started
DOWN_NODE_IP="" run_watchdog detect
if printf '%s' "$DETECT_OUT" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
  test_pass "WH.7: detect-only emits valid JSON"
else
  test_fail "WH.7: detect-only JSON invalid: ${DETECT_OUT}"
fi
keys=$(json_field "$DETECT_OUT" 'sorted(d.keys())')
for k in placement_healthy all_nodes_up drift ha_healthy ha_errors; do
  if printf '%s' "$keys" | grep -q "'$k'"; then
    test_pass "WH.7: key '$k' present"
  else
    test_fail "WH.7: key '$k' missing (keys=${keys})"
  fi
done

# ============ WH.8 — no cluster-write commands anywhere in HA path ============
# Source-level ratchet: the HA-outage block must not call ha-manager set/migrate,
# qm, pvesm, or rebalance-cluster.sh. Assert the guidance is emitted with `echo`
# (into the log), never executed. We check the block between the HA-outage guard
# and its exit contains no bare invocation of those write verbs.
test_start "WH.8" "source: HA-outage block issues zero cluster-write commands"
ha_block=$(awk '/HA outage handling \(#519\/A5\)/,/^# --- No drift/' "$WATCHDOG_SRC")
violation=0
# Any line that is NOT a comment and NOT an echo/print string, yet calls a write
# verb, is a violation. All ha-manager/qm/pvesm text in this block lives inside
# echoed guidance strings.
while IFS= read -r line; do
  # strip leading whitespace
  trimmed="${line#"${line%%[![:space:]]*}"}"
  case "$trimmed" in
    \#*) continue ;;                 # comment
    echo*|*'>> "$LOG_FILE"'*) continue ;;  # echoed guidance
  esac
  if printf '%s' "$trimmed" | grep -qE '(^|[^"'\''])((ha-manager (set|migrate|remove|add))|qm (stop|start|set|destroy)|pvesm |rebalance-cluster\.sh)'; then
    echo "  suspect line: ${line}" >&2
    violation=1
  fi
done <<< "$ha_block"
[[ "$violation" -eq 0 ]] \
  && test_pass "WH.8: no executable cluster-write verb in the HA-outage block" \
  || test_fail "WH.8: HA-outage block contains an executable cluster-write command"

# =============== WH.9 — HA state 'migrate' with postmigrate status ===========
# Regression guard for #532: DRT-005 rerun (2026-07-09) captured the classifier
# briefly flagging vm:302 (dns2_dev) and vm:603 (roon_prod) as HA-unhealthy
# because HA state was 'migrate' and pvesh status was 'postmigrate'. Migrate is
# a healthy in-progress CRM state; the probe must NOT flag it as an outage.
# vm:500 (testapp_prod) is the fixture surrogate for those production VMIDs.
test_start "WH.9" "HA state 'migrate' + postmigrate status: healthy in-progress, no flag, no rebalance"
write_resources pve02 postmigrate   # on intended node, transient postmigrate
write_ha_status migrate
DOWN_NODE_IP="" run_watchdog detect
[[ "$(json_field "$DETECT_OUT" 'd["ha_healthy"]')" == "True" ]] \
  && test_pass "WH.9: ha_healthy true during migrate" || test_fail "WH.9: expected ha_healthy true: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" 'len(d["ha_errors"])')" == "0" ]] \
  && test_pass "WH.9: ha_errors empty during migrate" || test_fail "WH.9: ha_errors not empty: ${DETECT_OUT}"
DOWN_NODE_IP="" run_watchdog normal
[[ "$LAST_RC" -eq 0 ]] && test_pass "WH.9: normal mode exit 0 during migrate" || test_fail "WH.9: exit ${LAST_RC}"
assert_no_rebalance "WH.9"

# =========== WH.9b — negative: TRANSITIONAL is per-vmid, not a loop break ====
# Regression guard: a bare `continue` on transitional state must NOT swallow
# outage detection for an unrelated VM. If vm:500 is migrating AND vm:401 is
# genuinely in HA error, the probe must still flag vm:401.
test_start "WH.9b" "HA migrate on one VM + HA error on another: only the errored VM is flagged"
write_resources pve02 postmigrate   # vm:500 mid-migration on intended node
cat > "${FIX_DIR}/ha_status" <<HAS
quorum OK
master pve01 (active, ...)
lrm pve01 (active, ...)
service vm:401 (pve01, error)
service vm:402 (pve02, started)
service vm:500 (pve02, migrate)
HAS
DOWN_NODE_IP="" run_watchdog detect
[[ "$(json_field "$DETECT_OUT" 'd["ha_healthy"]')" == "False" ]] \
  && test_pass "WH.9b: ha_healthy false (outage on vm:401 not swallowed)" \
  || test_fail "WH.9b: expected ha_healthy false: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" '[e["vmid"] for e in d["ha_errors"]]')" == "[401]" ]] \
  && test_pass "WH.9b: only vm:401 flagged, vm:500 excluded (transitional)" \
  || test_fail "WH.9b: expected only vm:401: ${DETECT_OUT}"

# =============== WH.10 — HA state 'relocate' likewise does NOT flag ==========
# Relocate is the offline-migration counterpart of migrate — same transient
# class per #532.
test_start "WH.10" "HA state 'relocate' + transient status: healthy in-progress, no flag, no rebalance"
write_resources pve02 postmigrate   # transient window
write_ha_status relocate
DOWN_NODE_IP="" run_watchdog detect
[[ "$(json_field "$DETECT_OUT" 'd["ha_healthy"]')" == "True" ]] \
  && test_pass "WH.10: ha_healthy true during relocate" || test_fail "WH.10: expected ha_healthy true: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" 'len(d["ha_errors"])')" == "0" ]] \
  && test_pass "WH.10: ha_errors empty during relocate" || test_fail "WH.10: ha_errors not empty: ${DETECT_OUT}"
DOWN_NODE_IP="" run_watchdog normal
[[ "$LAST_RC" -eq 0 ]] && test_pass "WH.10: normal mode exit 0 during relocate" || test_fail "WH.10: exit ${LAST_RC}"
assert_no_rebalance "WH.10"

# ============ WH.11 — annotated migrate state ("(node, migrate, target)") ====
# Regression guard: some PVE versions decorate transitional states with a
# trailing target-node hint, either comma-separated ("(pve01, migrate, pve02)")
# or parenthesised ("(pve01, migrate (pve02))"). The classifier's state parse
# must normalise to the primary CRM state token so TRANSITIONAL keyed on
# {'migrate','relocate'} matches regardless of annotation shape. See #532
# adversarial-review P1 (regex fragility).
test_start "WH.11" "annotated 'migrate' state (comma target): still classified as transitional"
write_resources pve02 postmigrate
cat > "${FIX_DIR}/ha_status" <<'HAS'
quorum OK
master pve01 (active, ...)
lrm pve01 (active, ...)
service vm:401 (pve01, started)
service vm:402 (pve02, started)
service vm:500 (pve02, migrate, pve03)
HAS
DOWN_NODE_IP="" run_watchdog detect
[[ "$(json_field "$DETECT_OUT" 'd["ha_healthy"]')" == "True" ]] \
  && test_pass "WH.11a: comma-target annotation still classified as transitional" \
  || test_fail "WH.11a: expected ha_healthy true: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" 'len(d["ha_errors"])')" == "0" ]] \
  && test_pass "WH.11a: ha_errors empty (annotation stripped)" \
  || test_fail "WH.11a: ha_errors not empty: ${DETECT_OUT}"

# Parenthesised-target variant.
cat > "${FIX_DIR}/ha_status" <<'HAS'
quorum OK
master pve01 (active, ...)
lrm pve01 (active, ...)
service vm:401 (pve01, started)
service vm:402 (pve02, started)
service vm:500 (pve02, migrate (pve03))
HAS
DOWN_NODE_IP="" run_watchdog detect
[[ "$(json_field "$DETECT_OUT" 'd["ha_healthy"]')" == "True" ]] \
  && test_pass "WH.11b: paren-target annotation still classified as transitional" \
  || test_fail "WH.11b: expected ha_healthy true: ${DETECT_OUT}"
[[ "$(json_field "$DETECT_OUT" 'len(d["ha_errors"])')" == "0" ]] \
  && test_pass "WH.11b: ha_errors empty (annotation stripped)" \
  || test_fail "WH.11b: ha_errors not empty: ${DETECT_OUT}"

runner_summary
