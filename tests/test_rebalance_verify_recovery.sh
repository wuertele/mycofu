#!/usr/bin/env bash
# test_rebalance_verify_recovery.sh — issue #514.
#
# rebalance-cluster.sh is a recovery tool whose success criteria historically
# covered placement mechanics only. DRT-005 2026-07-07 step 7: it exited 0 with
# SEVEN VMs stopped in HA `error` state (unrecovered from a node failure); the
# outage was only noticed when validate.sh tripped over symptoms at step 8. The
# new verify_recovery phase asserts the OUTCOME before exit 0: after migrations
# settle, no HA service in `error`, every HA-requested `started` service backed
# by a running VM, and every config-enabled VM running — respecting deliberately
# `disabled`/`stopped`/`ignored` services and failing closed when cluster state
# cannot be determined.
#
# Coverage:
#   1. Static contract — phase gates exit 0, bounded settle poll, fail-closed,
#      INTENTIONAL-state respect, config-parser section reset, unresolved
#      manifest is non-fatal, NAS-safe (cfg_query/python3, no direct yq),
#      storage-failure-fence 6A/6B remediation.
#   2. Behavioral (shimmed ssh feeding fixture ha-manager status/config + pvesh):
#        healthy                     => exit 0
#        HA error state              => FAIL, names the service
#        two services in error       => FAIL, both named
#        requested started, VM down  => FAIL
#        deliberately disabled + off => PASS (intent respected)
#        stopped, not HA-managed     => FAIL (condition c)
#        unresolved manifest entry   => PASS (co-located app / not-yet-created)
#        ha-manager config bleed      => FAIL (no state bleed across ct:/group:)
#        empty HA status             => FAIL (fail-closed)
#        no parseable HA services    => FAIL (fail-closed)
#        empty ha-manager config     => FAIL (fail-closed)
#        empty pvesh data            => FAIL (fail-closed)
#        settle: fail then recover   => exit 0 (poll loop)
#        concrete error then blip    => FAIL, concrete VM still named
#        config.json + yq absent     => exit 0 (NAS jq path; proves no yq call)

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

REBALANCE="${REPO_ROOT}/framework/scripts/rebalance-cluster.sh"

TMP_DIR="$(mktemp -d -t rebalance-verify.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# ---------------------------------------------------------------------------
# 1. Static contract
# ---------------------------------------------------------------------------

test_start "contract.a" "verify_recovery exists, is gated, and gates the real-run exit 0"
if grep -Fq 'verify_recovery() {' "$REBALANCE" &&
   grep -Fq 'MYCOFU_REBALANCE_ONLY_VERIFY' "$REBALANCE" &&
   grep -Fq 'if ! verify_recovery; then' "$REBALANCE"; then
  test_pass "verify_recovery defined, has ONLY-verify gate, and blocks exit 0"
else
  test_fail "verify_recovery not wired into the exit-0 path"
fi

body="$(awk '/^verify_recovery\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$REBALANCE")"

test_start "contract.b" "settle poll, fail-closed, INTENTIONAL respect, parser reset, remediation"
if grep -Fq 'MYCOFU_REBALANCE_VERIFY_TIMEOUT' <<< "$body" &&
   grep -Fq 'sleep "$interval"' <<< "$body" &&
   grep -Fq 'fail-closed' <<< "$body" &&
   grep -Fq "INTENTIONAL = {'disabled', 'ignored', 'stopped'}" <<< "$body" &&
   grep -Fq 'ERROR state' <<< "$body" &&
   grep -Fq 'cur = None' <<< "$body" &&                    # config parser section reset
   grep -Fq 'not treated as a failure' <<< "$body" &&      # unresolved manifest is non-fatal
   grep -Fq 'storage-failure-fence.md' <<< "$body"; then
  test_pass "bounded settle, fail-closed, disabled/stopped/ignored respected, parser reset, fence"
else
  test_fail "settle/fail-closed/intent/parser/remediation contract missing"
  printf '%s\n' "$body" >&2
fi

test_start "contract.c" "NAS-safe (.claude/rules/nas-scripts.md): cfg_query + python3, no direct yq"
if grep -Fq 'cfg_query' <<< "$body" &&
   grep -Fq 'python3' <<< "$body" &&
   ! grep -Eq '(^|[^_])yq ' <<< "$body"; then
  test_pass "config read via cfg_query dispatch; parsing via python3; no bare yq call"
else
  test_fail "verify_recovery is not NAS-safe"
  printf '%s\n' "$body" >&2
fi

# ---------------------------------------------------------------------------
# Fixtures: config (yaml + json) and an ssh shim keyed on REB_MODE
# ---------------------------------------------------------------------------

CFG_YAML_DIR="${TMP_DIR}/cfg-yaml"; mkdir -p "${CFG_YAML_DIR}"
cat > "${CFG_YAML_DIR}/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
  - name: pve02
    mgmt_ip: 10.0.0.12
  - name: pve03
    mgmt_ip: 10.0.0.13
vms:
  dns1_prod:
    vmid: 401
    node: pve01
  influxdb_prod:
    vmid: 601
    node: pve02
  roon_prod:
    vmid: 603
    node: pve03
applications: {}
EOF

# JSON equivalent — models the NAS (Synology DSM) deployment where cfg_query
# must dispatch to jq (no yq available). Same manifest as the yaml fixture.
CFG_JSON_DIR="${TMP_DIR}/cfg-json"; mkdir -p "${CFG_JSON_DIR}"
cat > "${CFG_JSON_DIR}/config.json" <<'EOF'
{
  "nodes": [
    {"name": "pve01", "mgmt_ip": "10.0.0.11"},
    {"name": "pve02", "mgmt_ip": "10.0.0.12"},
    {"name": "pve03", "mgmt_ip": "10.0.0.13"}
  ],
  "vms": {
    "dns1_prod": {"vmid": 401, "node": "pve01"},
    "influxdb_prod": {"vmid": 601, "node": "pve02"},
    "roon_prod": {"vmid": 603, "node": "pve03"}
  },
  "applications": {}
}
EOF

SHIM_DIR="${TMP_DIR}/shims"; mkdir -p "${SHIM_DIR}"

# A `yq` shim that always fails, in its OWN directory — prepended to PATH only
# for the NAS json case to PROVE cfg_query never shells out to yq when a
# config.json is present. (yaml cases legitimately use the real yq, so this
# guard must NOT be on their PATH.)
NAS_GUARD_DIR="${TMP_DIR}/nas-guard"; mkdir -p "${NAS_GUARD_DIR}"
cat > "${NAS_GUARD_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
echo "yq must not be invoked on the NAS (no yq in DSM userland)" >&2
exit 97
EOF
chmod +x "${NAS_GUARD_DIR}/yq"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
# Fixture ssh: respond to the three read-only queries verify_recovery issues,
# selected by REB_MODE. Stateful modes advance a per-poll counter on each
# `ha-manager status` call (the first query of each poll).
set -uo pipefail
cmd="${*: -1}"

poll=1
if [[ -n "${REB_COUNTER:-}" ]]; then
  case "$cmd" in
    *"ha-manager status"*)
      poll=$(( $(cat "$REB_COUNTER" 2>/dev/null || echo 0) + 1 ))
      echo "$poll" > "$REB_COUNTER" ;;
    *)
      poll=$(cat "$REB_COUNTER" 2>/dev/null || echo 1) ;;
  esac
fi

mode="${REB_MODE}"
case "${REB_MODE}" in
  retry-then-pass)  [[ "$poll" -ge 2 ]] && mode="healthy" || mode="error" ;;
  concrete-then-fc) [[ "$poll" -ge 2 ]] && mode="empty-status" || mode="error" ;;
esac

emit_status() {
  echo "quorum OK"
  echo "master pve01 (active, now)"
  echo "lrm pve01 (active, now)"
  case "${mode}" in
    zero-services) : ;;                                    # header lines only, no services
    error)         echo "service vm:401 (pve01, started)"; echo "service vm:601 (pve02, error)";    echo "service vm:603 (pve03, started)" ;;
    multi-error)   echo "service vm:401 (pve01, started)"; echo "service vm:601 (pve02, error)";    echo "service vm:603 (pve03, error)" ;;
    disabled)      echo "service vm:401 (pve01, started)"; echo "service vm:601 (pve02, started)";  echo "service vm:603 (pve03, disabled)" ;;
    manifest-stopped) echo "service vm:401 (pve01, started)"; echo "service vm:601 (pve02, started)" ;;  # 603 not HA-managed
    unresolved)    echo "service vm:401 (pve01, started)"; echo "service vm:601 (pve02, started)" ;;     # 603 absent entirely
    *)             echo "service vm:401 (pve01, started)"; echo "service vm:601 (pve02, started)";  echo "service vm:603 (pve03, started)" ;;
  esac
}

emit_config() {
  printf 'vm:401\n\tstate started\n\n'
  case "${mode}" in
    disabled) printf 'vm:601\n\tstate started\n\nvm:603\n\tstate disabled\n' ;;
    bleed)
      # A container block with `state disabled` sits between vm:601 and vm:603.
      # A parser that does not reset its pointer on the ct: header would bleed
      # 'disabled' onto vm:601's requested state.
      printf 'vm:601\n\tstate started\n\nct:900\n\tstate disabled\n\nvm:603\n\tstate started\n' ;;
    manifest-stopped|unresolved) printf 'vm:601\n\tstate started\n' ;;   # 603 not HA-managed
    *) printf 'vm:601\n\tstate started\n\nvm:603\n\tstate started\n' ;;
  esac
}

emit_resources() {
  local r601="running" r603="running"
  case "${mode}" in
    started-down|bleed) r601="stopped" ;;
    disabled|manifest-stopped) r603="stopped" ;;
  esac
  {
    printf '['
    printf '{"type":"qemu","vmid":401,"name":"dns1-prod","node":"pve01","status":"running"}'
    printf ',{"type":"qemu","vmid":601,"name":"influxdb-prod","node":"pve02","status":"%s"}' "$r601"
    if [[ "${mode}" != "unresolved" ]]; then
      printf ',{"type":"qemu","vmid":603,"name":"roon-prod","node":"pve03","status":"%s"}' "$r603"
    fi
    printf ']\n'
  }
}

case "$cmd" in
  *"ha-manager status"*)
    [[ "${mode}" == "empty-status" ]] && exit 0
    emit_status ;;
  *"ha-manager config"*)
    [[ "${mode}" == "empty-config" ]] && exit 0
    emit_config ;;
  *"pvesh get /cluster/resources"*)
    [[ "${mode}" == "empty-resources" ]] && { echo "[]"; exit 0; }
    emit_resources ;;
  *) echo "unexpected ssh cmd: $cmd" >&2; exit 98 ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

run_verify() {
  local mode="$1" cfg_dir="${2:-${CFG_YAML_DIR}}" counter="${3:-}" extra_path="${4:-}"
  set +e
  OUTPUT="$(
    PATH="${extra_path}${SHIM_DIR}:${PATH}" \
      REB_MODE="${mode}" \
      REB_COUNTER="${counter}" \
      WATCHDOG_CONFIG_DIR="${cfg_dir}" \
      MYCOFU_REBALANCE_ONLY_VERIFY=1 \
      MYCOFU_REBALANCE_VERIFY_TIMEOUT="${VERIFY_TIMEOUT:-0}" \
      MYCOFU_REBALANCE_VERIFY_INTERVAL="${VERIFY_INTERVAL:-1}" \
      bash "${REBALANCE}" 2>&1
  )"
  STATUS=$?
  set -e
}

# ---------------------------------------------------------------------------
# 2. Behavioral
# ---------------------------------------------------------------------------

test_start "behavior.healthy" "all services started + all config VMs running => exit 0"
run_verify healthy
if [[ "${STATUS}" -eq 0 ]] && grep -q 'Recovery verified' <<< "${OUTPUT}"; then
  test_pass "healthy cluster passes"
else
  test_fail "healthy cluster did not pass (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.error" "HA service in error state => FAIL naming the service"
run_verify error
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q 'did not reach a recovered cluster state' <<< "${OUTPUT}" &&
   grep -q 'vm:601 (influxdb_prod): HA service in ERROR state' <<< "${OUTPUT}"; then
  test_pass "error-state service fails the run and is named"
else
  test_fail "error state not caught (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.multi-error" "two services in error => FAIL, both named"
run_verify multi-error
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q 'vm:601 (influxdb_prod): HA service in ERROR state' <<< "${OUTPUT}" &&
   grep -q 'vm:603 (roon_prod): HA service in ERROR state' <<< "${OUTPUT}"; then
  test_pass "all error-state services are named (DRT-005 had 7)"
else
  test_fail "multi-error not fully reported (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.started-down" "HA-requested started but VM not running => FAIL"
run_verify started-down
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q "vm:601 (influxdb_prod): HA-requested 'started' but VM not running" <<< "${OUTPUT}"; then
  test_pass "started-but-not-running is caught"
else
  test_fail "started-but-not-running not caught (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.disabled" "deliberately disabled + powered off => PASS (intent respected)"
run_verify disabled
if [[ "${STATUS}" -eq 0 ]] && grep -q 'Recovery verified' <<< "${OUTPUT}"; then
  test_pass "an intentionally disabled, stopped VM is not a failure"
else
  test_fail "disabled VM wrongly failed the run (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.manifest-stopped" "config VM present, stopped, NOT HA-managed => FAIL (cond. c)"
run_verify manifest-stopped
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q 'vm:603 (roon_prod): config-enabled VM not running and not HA-managed' <<< "${OUTPUT}"; then
  test_pass "a stopped non-HA config VM fails the run"
else
  test_fail "stopped non-HA config VM not caught (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.unresolved" "config VM with no matching Proxmox VM => PASS (non-fatal note)"
run_verify unresolved
if [[ "${STATUS}" -eq 0 ]] &&
   grep -q 'Recovery verified' <<< "${OUTPUT}" &&
   grep -q "no matching Proxmox VM" <<< "${OUTPUT}"; then
  test_pass "an unresolved manifest entry is an informational note, not a false failure"
else
  test_fail "unresolved manifest entry mishandled (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.bleed" "ha-manager config parser does not bleed state across a ct: block"
run_verify bleed
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q "vm:601 (influxdb_prod): HA-requested 'started' but VM not running" <<< "${OUTPUT}"; then
  test_pass "vm:601 requested state is not corrupted by the intervening ct:900 disabled block"
else
  test_fail "config parser bled state across blocks (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.zero-services" "HA status with no service entries => FAIL (fail-closed)"
run_verify zero-services
if [[ "${STATUS}" -ne 0 ]] && grep -q 'no parseable HA service entries' <<< "${OUTPUT}"; then
  test_pass "malformed/partial HA status fails closed instead of passing"
else
  test_fail "zero-service HA status did not fail closed (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.empty-config" "empty ha-manager config => FAIL (fail-closed)"
run_verify empty-config
if [[ "${STATUS}" -ne 0 ]] && grep -q 'could not read HA requested state' <<< "${OUTPUT}"; then
  test_pass "empty ha-manager config fails closed"
else
  test_fail "empty config did not fail closed (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.empty-status" "empty ha-manager status => FAIL (fail-closed)"
run_verify empty-status
if [[ "${STATUS}" -ne 0 ]] && grep -q 'could not read HA state' <<< "${OUTPUT}"; then
  test_pass "undeterminable HA state fails closed"
else
  test_fail "empty HA status did not fail closed (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.empty-resources" "empty pvesh data => FAIL (fail-closed)"
run_verify empty-resources
if [[ "${STATUS}" -ne 0 ]] && grep -q 'could not read VM run state' <<< "${OUTPUT}"; then
  test_pass "undeterminable VM run state fails closed"
else
  test_fail "empty pvesh did not fail closed (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.settle-retry" "fail on first poll, recover on second => exit 0"
VERIFY_TIMEOUT=5 VERIFY_INTERVAL=1 run_verify retry-then-pass "${CFG_YAML_DIR}" "${TMP_DIR}/ctr-retry"
if [[ "${STATUS}" -eq 0 ]] && grep -q 'Recovery verified' <<< "${OUTPUT}"; then
  test_pass "the settle poll waits out a transient failure and then passes"
else
  test_fail "settle retry did not converge to pass (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.concrete-then-blip" "concrete error then a final query blip => FAIL, VM still named"
VERIFY_TIMEOUT=2 VERIFY_INTERVAL=1 run_verify concrete-then-fc "${CFG_YAML_DIR}" "${TMP_DIR}/ctr-blip"
if [[ "${STATUS}" -ne 0 ]] &&
   grep -q 'vm:601 (influxdb_prod): HA service in ERROR state' <<< "${OUTPUT}"; then
  test_pass "a concrete failure is retained over a later transient fail-closed"
else
  test_fail "concrete failure was erased by a later blip (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

test_start "behavior.nas-json" "config.json (NAS jq path) with yq absent => exit 0 (nas-scripts.md)"
run_verify healthy "${CFG_JSON_DIR}" "" "${NAS_GUARD_DIR}:"
# NAS_GUARD_DIR is prepended to PATH so a failing `yq` shadows the real yq. A
# pass proves cfg_query dispatched to jq for the config.json (never called yq).
if [[ "${STATUS}" -eq 0 ]] &&
   grep -q 'Recovery verified' <<< "${OUTPUT}" &&
   ! grep -q 'yq must not be invoked' <<< "${OUTPUT}"; then
  test_pass "cfg_query jq dispatch works for the NAS config.json; yq never invoked"
else
  test_fail "NAS json path failed or invoked yq (status=${STATUS})"; printf '%s\n' "${OUTPUT}" >&2
fi

runner_summary
