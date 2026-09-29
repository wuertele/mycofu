#!/usr/bin/env bash
# test_placement_readers.sh — Hermetic tests for the intended-placement query
# shared by framework/scripts/rebalance-cluster.sh and
# framework/scripts/placement-watchdog.sh.
#
# Guards #493: the previous query required a top-level .node and silently
# skipped apps that only defined per-env .environments.<env>.node (roon).
# The corrected query mirrors validate.sh R2.4: per-env wins, top-level
# is fallback, node from either scope produces one row per env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REBAL="${REPO_DIR}/framework/scripts/rebalance-cluster.sh"
WATCH="${REPO_DIR}/framework/scripts/placement-watchdog.sh"

# yq is a mandatory framework dependency. In a CI context, missing yq is a
# hard fail (a silent skip in CI is a silent lie); locally, we skip so a
# workstation without yq can still run the rest of the test suite.
if ! command -v yq >/dev/null; then
  if [[ -n "${CI:-}${GITLAB_CI:-}" ]]; then
    echo "FAIL: yq not installed (mandatory framework dep, refusing to skip in CI)"
    exit 1
  fi
  echo "SKIP: yq not installed (local run only)"
  exit 0
fi

# jq is used to prove the query works against the merged config.json path
# used by the NAS-hosted watchdog (configure-sentinel-gatus.sh emits JSON).
HAS_JQ=0
command -v jq >/dev/null && HAS_JQ=1

PASS=0
FAIL=0
FAILURES=()

record_pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
record_fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); FAILURES+=("$1"); }

# --- Extract the two query strings from the scripts as they run today ---
# The query line matches:
#   [optional leading whitespace]cfg_query '.applications ... "=" + $node' >> "$INTENDED_FILE" ...
# Leading whitespace is tolerated so a future refactor that indents the
# line inside a function or conditional doesn't break the test silently.
extract_query() {
  local script="$1"
  local line
  line=$(grep -E "^[[:space:]]*cfg_query '\.applications " "$script" | head -1)
  [[ -n "$line" ]] || { echo "ERROR: no applications query line in $script" >&2; return 1; }
  # Strip leading whitespace, then "cfg_query '" prefix and "' >>..." suffix.
  local trimmed="${line#"${line%%[![:space:]]*}"}"
  local expr="${trimmed#cfg_query \'}"
  expr="${expr%\' >>*}"
  printf '%s' "$expr"
}

REBAL_Q=$(extract_query "$REBAL")
WATCH_Q=$(extract_query "$WATCH")

# --- Test PR.1: query strings are byte-identical ---
if [[ "$REBAL_Q" == "$WATCH_Q" ]]; then
  record_pass "PR.1: rebalance-cluster.sh and placement-watchdog.sh queries match"
else
  record_fail "PR.1: query drift between rebalance-cluster.sh and placement-watchdog.sh"
  diff <(printf '%s\n' "$REBAL_Q") <(printf '%s\n' "$WATCH_Q") || true
fi

# --- Test PR.1b: the .vms (infrastructure) INTENDED_FILE reader is byte-identical too ---
# The INTENDED_FILE has TWO reader lines: the .applications query (PR.1) and the
# .vms query. Sprint 045 / #519 (A5) adds an HA-error probe to the watchdog that
# consumes INTENDED_FILE as its manifest; the two scripts must agree on the FULL
# intended-placement set or verify_recovery (rebalance) and the watchdog probe
# would classify different VMs. Guard the .vms line's byte-equivalence explicitly.
extract_vms_query() {
  local script="$1" line
  line=$(grep -E "^[[:space:]]*cfg_query '\.vms " "$script" | head -1)
  [[ -n "$line" ]] || { echo "ERROR: no .vms query line in $script" >&2; return 1; }
  local trimmed="${line#"${line%%[![:space:]]*}"}"
  local expr="${trimmed#cfg_query \'}"
  expr="${expr%\' > \"\$INTENDED_FILE\"}"
  printf '%s' "$expr"
}
REBAL_VMS_Q=$(extract_vms_query "$REBAL")
WATCH_VMS_Q=$(extract_vms_query "$WATCH")
if [[ "$REBAL_VMS_Q" == "$WATCH_VMS_Q" ]]; then
  record_pass "PR.1b: rebalance-cluster.sh and placement-watchdog.sh .vms queries match"
else
  record_fail "PR.1b: .vms query drift between rebalance-cluster.sh and placement-watchdog.sh"
  diff <(printf '%s\n' "$REBAL_VMS_Q") <(printf '%s\n' "$WATCH_VMS_Q") || true
fi

# --- Fixture runner ---
# Writes $2 (yaml) to a tempfile, runs REBAL_Q against it via yq, compares
# sorted output to $3 (expected rows, newline-separated, possibly empty).
# stderr is NOT suppressed — yq syntax errors must be visible.
run_fixture() {
  local name="$1" yaml="$2" expected="$3"
  local tmp; tmp=$(mktemp)
  printf '%s' "$yaml" > "$tmp"
  local got
  got=$(yq -r "$REBAL_Q" "$tmp" | sort)
  rm -f "$tmp"
  local want
  want=$(printf '%s' "$expected" | sort)
  if [[ "$got" == "$want" ]]; then
    record_pass "$name"
  else
    record_fail "$name"
    echo "  want:"; printf '%s\n' "$want" | sed 's/^/    /'
    echo "  got:"; printf '%s\n' "$got" | sed 's/^/    /'
  fi
}

# --- PR.2: per-env-only shape → row emitted ---
run_fixture "PR.2: per-env-only produces row" \
'applications:
  foo:
    enabled: true
    environments:
      prod:
        node: pve02
' \
'foo_prod=pve02'

# --- PR.3: top-level-only shape → one row per env ---
# (Envs must be present as keys; see PR.9 for the case where environments
# is missing/empty and the row must NOT be emitted.)
run_fixture "PR.3: top-level-only produces one row per env" \
'applications:
  foo:
    enabled: true
    node: pve02
    environments:
      prod: {}
      dev: {}
' \
'foo_prod=pve02
foo_dev=pve02'

# --- PR.4: both shapes → per-env wins for envs that override, top-level for others ---
run_fixture "PR.4: per-env wins when both defined; top-level covers gap" \
'applications:
  foo:
    enabled: true
    node: pve99
    environments:
      prod:
        node: pve02
      dev: {}
' \
'foo_prod=pve02
foo_dev=pve99'

# --- PR.5: disabled app → no rows even with per-env node ---
run_fixture "PR.5: disabled app is skipped even with per-env node" \
'applications:
  foo:
    enabled: false
    environments:
      prod:
        node: pve02
' \
''

# --- PR.6: no node defined anywhere → no rows ---
run_fixture "PR.6: enabled app with no node defined emits no rows" \
'applications:
  foo:
    enabled: true
    environments:
      prod: {}
      dev: {}
' \
''

# --- PR.7: empty applications map → no rows, no error ---
run_fixture "PR.7: empty applications map is a no-op" \
'applications: {}
' \
''

# --- PR.8: multi-app realistic mix (roon-shaped + top-level-only) ---
run_fixture "PR.8: mixed schema apps in one config" \
'applications:
  roon:
    enabled: true
    environments:
      prod:
        node: pve02
      dev:
        node: pve03
  influxdb:
    enabled: true
    node: pve02
    environments:
      prod: {}
      dev: {}
' \
'roon_prod=pve02
roon_dev=pve03
influxdb_prod=pve02
influxdb_dev=pve02'

# --- PR.9: enabled app with top-level node but no environments key → no rows ---
# Guards against a mikefarah yq v4 quirk where the outer to_entries[] on
# an empty/missing map still emits, yielding a garbage row like
# "foo_=pve02" (empty env key). See #493 review round.
run_fixture "PR.9: enabled app, top-level node, missing environments key: no rows" \
'applications:
  foo:
    enabled: true
    node: pve02
' \
''

# --- PR.10: environments: null (explicit) → no rows ---
run_fixture "PR.10: enabled app, top-level node, environments: null: no rows" \
'applications:
  foo:
    enabled: true
    node: pve02
    environments: null
' \
''

# --- PR.11: environments: {} (empty map) → no rows ---
run_fixture "PR.11: enabled app, top-level node, environments empty map: no rows" \
'applications:
  foo:
    enabled: true
    node: pve02
    environments: {}
' \
''

# --- PR.12: jq/JSON parity — the query must produce identical rows when
# consumed via jq against config.json (the NAS-hosted watchdog path in
# configure-sentinel-gatus.sh). This proves the fix works for the
# deployed path, not just the workstation yq path. ---
if [[ "$HAS_JQ" -eq 1 ]]; then
  json_fixture='{
    "applications": {
      "roon":     {"enabled": true, "environments": {"prod": {"node": "pve02"}, "dev": {"node": "pve03"}}},
      "influxdb": {"enabled": true, "node": "pve02", "environments": {"prod": {}, "dev": {}}},
      "disabled_app": {"enabled": false, "node": "pve99", "environments": {"prod": {}}},
      "no_envs":  {"enabled": true, "node": "pve02"}
    }
  }'
  tmp_json=$(mktemp)
  printf '%s' "$json_fixture" > "$tmp_json"
  got_jq=$(jq -r "$REBAL_Q" "$tmp_json" | sort)
  rm -f "$tmp_json"
  want_jq=$(printf '%s' 'roon_prod=pve02
roon_dev=pve03
influxdb_prod=pve02
influxdb_dev=pve02' | sort)
  if [[ "$got_jq" == "$want_jq" ]]; then
    record_pass "PR.12: jq/JSON path produces identical rows (NAS deploy path)"
  else
    record_fail "PR.12: jq/JSON path drift from yq expectations"
    echo "  want:"; printf '%s\n' "$want_jq" | sed 's/^/    /'
    echo "  got:"; printf '%s\n' "$got_jq" | sed 's/^/    /'
  fi
else
  echo "SKIP: PR.12 jq not installed (yq path exercised, jq path not verified)"
fi

# --- Summary ---
echo
echo "==================================="
echo "Placement reader tests: $PASS passed, $FAIL failed"
echo "==================================="
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
