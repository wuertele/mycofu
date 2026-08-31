#!/usr/bin/env bash
# test_rebalance_policy_skip.sh — Sprint 047 V6.2 (rebalance-cluster.sh
# policy-off skip).
#
# Sprint 047 MR-4 FI-15 rewrite: the predicate is now vmid_is_policy_off,
# a pure /etc/repl-policy.vmids reader — no local YAML parsing. Tests
# exercise the REAL code path (no config-format dispatcher shim).
#
# Assert:
#   V6.2.a — vmid_is_policy_off classifies VMIDs correctly against a
#            synthesized artifact (present); fails-closed to policy-on
#            when the artifact is absent (unknown → migrate).
#   V6.2.b — drift loop skips policy-off and prints G7 guidance.
#   V6.2.c — G7 guidance carries the repetition note.
#   V6.2.d — placement-watchdog.sh remediation text branches on policy.
#   V6.2.e — placement readers byte-identity ratchet still passes.
#   V6.2.f — the WARN-on-absent-artifact path preserves pre-sprint
#            behavior (fail-closed direction is migrate, not skip).
#   V6.2.g — the WARN message on artifact-absent path is present.
#   V6.2.h — _policy_parse_artifact rejects malformed / truncated
#            content (r2 codex P1 #1: require POLICY_GEN).
#   V6.2.i — load_policy_artifact requires unanimous agreement across
#            all readable nodes (r2 codex P1 #2 / sub-claude P2-1).
#   V6.2.j — DOS line-ending defense (r2 sub-claude P3-1: trailing CR
#            on the last VMID must not misclassify it).
#   V6.2.k — empty target guard on vmid_is_policy_off (r2 sub-claude
#            P3-4: never match trailing-comma "" element).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
source "${TEST_DIR}/lib/runner.sh"

REBAL="${REPO_DIR}/framework/scripts/rebalance-cluster.sh"

# ---------------------------------------------------------------------------
# Extract the loader + predicate + their helpers into a temp script we can
# source safely (rebalance-cluster.sh has a top-level guard-library require
# that must run under a full env; we only want the policy machinery).
# ---------------------------------------------------------------------------
build_policy_driver() {
  local out="$1"
  cat > "$out" <<'DRIVER_HEAD'
POLICY_ARTIFACT_STATE="absent"
POLICY_OFF_VMIDS=""
POLICY_GEN=""
POLICY_OFF_ARR=()
DRIVER_HEAD
  # Extract every helper the loader depends on.
  for fn in _policy_extract _policy_csv_ok _policy_parse_artifact \
            load_policy_artifact vmid_is_policy_off; do
    sed -n "/^${fn}()/,/^}\$/p" "$REBAL" >> "$out"
  done
  # Sanity: the extracted body must end with `}` — a future refactor that
  # reformats the closing brace would break silent extraction (r2 P3-5).
  if ! tail -1 "$out" | grep -qE '^}\s*$'; then
    echo "  ✗ build_policy_driver: extracted body did not end with '}'" >&2
    return 1
  fi
}

DRIVER=$(mktemp /tmp/v62-driver.XXXXXX)
trap 'rm -f "$DRIVER"' EXIT
build_policy_driver "$DRIVER" || { echo "driver build failed"; exit 1; }

# ---------------------------------------------------------------------------
# V6.2.a — vmid_is_policy_off classifies known VMIDs against a synthesized
#          artifact whose content is the same shape configure-replication.sh
#          writes.
# ---------------------------------------------------------------------------
test_start "V6.2.a" "vmid_is_policy_off classifies present-artifact VMIDs correctly"

PRESENT_OFF="160,170,190,301,302,305,404,500,502,600,602"

check_present() {
  local vmid="$1" expected="$2" actual rc
  set +e
  actual=$(
    bash -c "
      $(cat "$DRIVER")
      POLICY_ARTIFACT_STATE=present
      POLICY_OFF_VMIDS='${PRESENT_OFF}'
      IFS=',' read -ra POLICY_OFF_ARR <<< \"\$POLICY_OFF_VMIDS\"
      if vmid_is_policy_off '${vmid}'; then echo off; else echo on; fi
    "
  )
  rc=$?
  set -e
  if [[ "$rc" -eq 0 && "$actual" == "$expected" ]]; then
    echo "  ✓ vmid=${vmid} → ${actual}"
    return 0
  else
    echo "  ✗ vmid=${vmid} expected=${expected} actual=${actual} rc=${rc}" >&2
    return 1
  fi
}

failures=0
# Precious (backup:true → default replicate on) — MUST be policy-on
for vmid in 150 303 403 501 503 601 603; do
  check_present "$vmid" on || failures=$((failures + 1))
done
# Explicit opt-in (dns_prod) — MUST be policy-on
for vmid in 401 402; do
  check_present "$vmid" on || failures=$((failures + 1))
done
# Derivable — MUST be policy-off
for vmid in 160 170 190 301 302 305 404 500 502 600 602; do
  check_present "$vmid" off || failures=$((failures + 1))
done
# Unknown-to-artifact VMID — MUST be classified policy-on (preserve
# pre-sprint behavior; fail-closed direction is migrate).
if check_present "9999" on; then :; else failures=$((failures + 1)); fi

if [[ $failures -eq 0 ]]; then
  test_pass "vmid_is_policy_off classifies all 21 tested VMIDs correctly against the present artifact"
else
  test_fail "V6.2.a: $failures VMID(s) misclassified against the present artifact"
fi

# ---------------------------------------------------------------------------
# V6.2.b — drift loop skips policy-off VMs and prints G7 guidance to
#          recreate-derivable-vm.sh.
# ---------------------------------------------------------------------------
test_start "V6.2.b" "drift loop skips explicit-override VMs and prints G7 guidance"
# The predicate (vmid_is_policy_off) reads POLICY_OFF_VMIDS from the
# artifact — the literal `replicate: false` set, empty on the shipped
# site. The operator-facing SKIP text names the explicit-override class.
if grep -q "vmid_is_policy_off" "$REBAL" \
   && grep -q "recreate-derivable-vm.sh" "$REBAL" \
   && grep -qE "SKIP.*(policy-off|explicit-override)" "$REBAL"; then
  test_pass "explicit-override drift skip is present and routes to recreate-derivable-vm.sh"
else
  test_fail "V6.2.b: missing drift-skip branch OR recreate-derivable-vm.sh reference"
fi

# ---------------------------------------------------------------------------
# V6.2.c — G7 guidance carries the repetition note.
# ---------------------------------------------------------------------------
test_start "V6.2.c" "G7 guidance carries the repetition note (expected, not escalating)"
if grep -qE "repeats.*(cycle|each|every)" "$REBAL" \
   && grep -qE "until.*(recreated|updates|updated)" "$REBAL"; then
  test_pass "repetition note present (expected-not-escalating; no cross-invocation dedup state)"
else
  test_fail "V6.2.c: G7 repetition-language missing"
fi

# ---------------------------------------------------------------------------
# V6.2.d — placement-watchdog.sh remediation text branches on policy.
# ---------------------------------------------------------------------------
test_start "V6.2.d" "placement-watchdog.sh remediation text uses universal doctrine (§6A/§6B + explicit-override recreate)"
# Watchdog remediation text under universal replication: every shipped
# VM gets the §6A/§6B ladder. The recreate path is scoped to
# explicit-override (empty set on shipped site) plus disk-loss recovery.
# Assert the shape:
#   - "every shipped VM" / "Universal replication" language present
#   - §6A and §6B ladders named
#   - explicit-override recreate branch named
#   - recreate-derivable-vm.sh referenced
#   - no branch-split "POLICY-ON services" / "POLICY-OFF services" text
PLACEMENT="${REPO_DIR}/framework/scripts/placement-watchdog.sh"
if grep -qE "every shipped VM|Universal replication" "$PLACEMENT" \
   && grep -q "recreate-derivable-vm.sh" "$PLACEMENT" \
   && grep -q "6A" "$PLACEMENT" \
   && grep -q "6B" "$PLACEMENT" \
   && grep -q "explicit-override" "$PLACEMENT" \
   && ! grep -qE '  POLICY-ON services|  POLICY-OFF services' "$PLACEMENT"; then
  test_pass "watchdog text uses universal doctrine; §6A/§6B ladder for every VM; recreate scoped to explicit-override"
else
  test_fail "V6.2.d: placement-watchdog.sh remediation text does not match universal-replication doctrine"
fi

# ---------------------------------------------------------------------------
# V6.2.e — placement readers byte-identical (PR.1/PR.1b ratchet).
# ---------------------------------------------------------------------------
test_start "V6.2.e" "placement readers byte-identical (existing test_placement_readers.sh)"
set +e
placement_output=$(bash "${TEST_DIR}/test_placement_readers.sh" 2>&1)
placement_rc=$?
set -e
if [[ $placement_rc -eq 0 ]] && echo "$placement_output" | grep -qE "[0-9]+ passed, 0 failed"; then
  test_pass "test_placement_readers.sh green (PR.1/PR.1b byte-identity preserved)"
else
  test_fail "V6.2.e: test_placement_readers.sh regressed"
  echo "$placement_output" | tail -6 >&2
fi

# ---------------------------------------------------------------------------
# V6.2.f — absent-artifact fail-closed direction is policy-on (migrate),
#          not policy-off (skip). This is the constraint that keeps a
#          precious VM's migration from being silently skipped.
# ---------------------------------------------------------------------------
test_start "V6.2.f" "absent-artifact fail-closed direction is policy-on (migrate)"
set +e
absent_result=$(
  bash -c "
    $(cat "$DRIVER")
    # POLICY_ARTIFACT_STATE remains 'absent' — simulates unreachable nodes.
    if vmid_is_policy_off '160'; then echo off; else echo on; fi
    if vmid_is_policy_off '999'; then echo off; else echo on; fi
    if vmid_is_policy_off '303'; then echo off; else echo on; fi
  "
)
absent_rc=$?
set -e
expected_absent=$'on\non\non'
if [[ "$absent_rc" -eq 0 && "$absent_result" == "$expected_absent" ]]; then
  test_pass "absent-artifact: every VMID classified policy-on (pre-sprint migrate path)"
else
  test_fail "V6.2.f: absent-artifact fail-closed direction incorrect"
  echo "  expected: $expected_absent" >&2
  echo "  actual:   $absent_result" >&2
fi

# ---------------------------------------------------------------------------
# V6.2.g — the WARN message on artifact-absent path is present.
# ---------------------------------------------------------------------------
test_start "V6.2.g" "rebalance-cluster.sh WARNs on unreadable/divergent artifact and treats VMs as policy-on"
if grep -qE 'repl-policy\.vmids (unreadable|POLICY_GEN divergence|(unreadable|absent).*malformed)' "$REBAL" \
   && grep -qE 'pre-sprint (migrate|behavior)' "$REBAL"; then
  test_pass "WARN + pre-sprint-behavior text present on artifact-absent/divergent path"
else
  test_fail "V6.2.g: artifact-absent/divergent WARN text missing"
fi

# ---------------------------------------------------------------------------
# V6.2.h — _policy_parse_artifact rejects malformed / truncated content
#          (r2 codex P1 #1: missing POLICY_GEN, non-numeric CSV, bad
#          POLICY_GEN, missing list keys).
# ---------------------------------------------------------------------------
test_start "V6.2.h" "_policy_parse_artifact rejects truncated / malformed artifacts"
parse_case() {
  local name="$1" content="$2" expect_rc="$3" actual_rc
  set +e
  bash -c "
    $(cat "$DRIVER")
    _policy_parse_artifact \"\$1\" >/dev/null 2>&1
  " _ "$content"
  actual_rc=$?
  set -e
  if [[ "$actual_rc" -eq "$expect_rc" ]]; then
    echo "  ✓ ${name} → rc=${actual_rc}"
    return 0
  fi
  echo "  ✗ ${name} expected_rc=${expect_rc} actual_rc=${actual_rc}" >&2
  return 1
}

parse_failures=0
# Well-formed complete artifact — accepted.
parse_case "well-formed" \
  "POLICY_ON_VMIDS=150,303
POLICY_OFF_VMIDS=160,170
POLICY_GEN=abcdef1234567890" 0 || parse_failures=$((parse_failures + 1))
# Legitimate empty policy-off — accepted.
parse_case "empty-off-legit" \
  "POLICY_ON_VMIDS=150
POLICY_OFF_VMIDS=
POLICY_GEN=deadbeef" 0 || parse_failures=$((parse_failures + 1))
# Missing POLICY_GEN — REJECTED (r2 codex P1 #1).
parse_case "missing-gen" \
  "POLICY_ON_VMIDS=150
POLICY_OFF_VMIDS=160" 1 || parse_failures=$((parse_failures + 1))
# Missing POLICY_ON_VMIDS — REJECTED.
parse_case "missing-on" \
  "POLICY_OFF_VMIDS=160
POLICY_GEN=abc123" 1 || parse_failures=$((parse_failures + 1))
# Missing POLICY_OFF_VMIDS — REJECTED.
parse_case "missing-off" \
  "POLICY_ON_VMIDS=150
POLICY_GEN=abc123" 1 || parse_failures=$((parse_failures + 1))
# Non-numeric junk in POLICY_OFF_VMIDS — REJECTED (r2 codex P2 #1).
parse_case "junk-off" \
  "POLICY_ON_VMIDS=150
POLICY_OFF_VMIDS=160,abc,999
POLICY_GEN=abc123" 1 || parse_failures=$((parse_failures + 1))
# Non-hex POLICY_GEN — REJECTED.
parse_case "junk-gen" \
  "POLICY_ON_VMIDS=150
POLICY_OFF_VMIDS=160
POLICY_GEN=NOT-A-HASH!" 1 || parse_failures=$((parse_failures + 1))
# Empty content — REJECTED.
parse_case "empty" "" 1 || parse_failures=$((parse_failures + 1))

if [[ $parse_failures -eq 0 ]]; then
  test_pass "_policy_parse_artifact correctly accepts/rejects 8 fixture cases"
else
  test_fail "V6.2.h: $parse_failures parse-fixture case(s) misbehaved"
fi

# ---------------------------------------------------------------------------
# V6.2.i — load_policy_artifact requires unanimous POLICY_GEN across
#          all readable nodes (r2 codex P1 #2 / sub-claude P2-1).
# ---------------------------------------------------------------------------
test_start "V6.2.i" "load_policy_artifact requires unanimous agreement across readable nodes"

# Drive load_policy_artifact with mocked cfg_query + ssh. Each fixture
# stages what each node "returns" via ARTIFACT_<node> env vars; ssh
# echoes the content and returns 0 (or empty + rc=255 for unreachable).
load_case() {
  local name="$1" node_count="$2" expect_state="$3" \
        expect_gen="$4" node0="$5" node1="$6" node2="${7:-}"
  local actual_state actual_gen actual_rc
  set +e
  local out
  out=$(bash -c "
    $(cat "$DRIVER")
    cfg_query() {
      case \"\$1\" in
        '.nodes[0].name')     echo pve01 ;;
        '.nodes[0].mgmt_ip')  echo 10.0.0.1 ;;
        '.nodes[1].name')     echo pve02 ;;
        '.nodes[1].mgmt_ip')  echo 10.0.0.2 ;;
        '.nodes[2].name')     echo pve03 ;;
        '.nodes[2].mgmt_ip')  echo 10.0.0.3 ;;
        *) echo '' ;;
      esac
    }
    export N0='${node0}'
    export N1='${node1}'
    export N2='${node2}'
    ssh() {
      local target=''
      for a in \"\$@\"; do case \"\$a\" in root@*) target=\"\$a\" ;; esac; done
      case \"\$target\" in
        root@10.0.0.1) if [[ \"\$N0\" == UNREACHABLE ]]; then return 255; fi; printf '%s' \"\$N0\" ;;
        root@10.0.0.2) if [[ \"\$N1\" == UNREACHABLE ]]; then return 255; fi; printf '%s' \"\$N1\" ;;
        root@10.0.0.3) if [[ \"\$N2\" == UNREACHABLE ]]; then return 255; fi; printf '%s' \"\$N2\" ;;
        *) return 255 ;;
      esac
    }
    if load_policy_artifact ${node_count} >/dev/null 2>&1; then
      echo \"state=\$POLICY_ARTIFACT_STATE gen=\$POLICY_GEN off=\$POLICY_OFF_VMIDS\"
    else
      echo \"state=absent gen= off=\"
    fi
  ")
  actual_rc=$?
  set -e
  actual_state=$(echo "$out" | grep -oE 'state=[^ ]*' | cut -d= -f2)
  actual_gen=$(echo "$out"   | grep -oE 'gen=[^ ]*'   | cut -d= -f2)
  if [[ "$actual_rc" -eq 0 && "$actual_state" == "$expect_state" && ( "$expect_gen" == '*' || "$actual_gen" == "$expect_gen" ) ]]; then
    echo "  ✓ ${name}: state=${actual_state} gen=${actual_gen:-<none>}"
    return 0
  fi
  echo "  ✗ ${name}: expected state=${expect_state} gen=${expect_gen}; actual: ${out}" >&2
  return 1
}

# Fixtures for the artifact
ART_FRESH='POLICY_ON_VMIDS=150,303
POLICY_OFF_VMIDS=160,170
POLICY_GEN=abcdef1234567890'
ART_STALE='POLICY_ON_VMIDS=150,303
POLICY_OFF_VMIDS=160
POLICY_GEN=0011223344556677'

load_failures=0
# All three nodes agree — present.
load_case "unanimous-3" 3 present "abcdef1234567890" \
  "$ART_FRESH" "$ART_FRESH" "$ART_FRESH" || load_failures=$((load_failures + 1))
# Node 0 unreachable, nodes 1+2 agree — present (partial-reach warns only).
load_case "n0-unreachable-1+2-agree" 3 present "abcdef1234567890" \
  "UNREACHABLE" "$ART_FRESH" "$ART_FRESH" || load_failures=$((load_failures + 1))
# Divergent (fresh + stale) — MUST fall back to absent (r2 codex P1 #2).
load_case "divergent-fresh-then-stale" 3 absent "" \
  "$ART_FRESH" "$ART_STALE" "$ART_FRESH" || load_failures=$((load_failures + 1))
# Stale-first-then-fresh — MUST fall back to absent (this is the exact
# scenario codex-r2 reproduced with the mocked two-node loader).
load_case "stale-then-fresh" 2 absent "" \
  "$ART_STALE" "$ART_FRESH" || load_failures=$((load_failures + 1))
# Every node unreadable — absent.
load_case "all-unreachable" 3 absent "" \
  "UNREACHABLE" "UNREACHABLE" "UNREACHABLE" || load_failures=$((load_failures + 1))
# One node has structurally-invalid content, others agree — present
# (structurally-bad is warned, agreeing readable copies win).
load_case "one-node-truncated" 3 present "abcdef1234567890" \
  "POLICY_ON_VMIDS=150" "$ART_FRESH" "$ART_FRESH" || load_failures=$((load_failures + 1))

if [[ $load_failures -eq 0 ]]; then
  test_pass "load_policy_artifact enforces unanimous agreement across readable nodes (6 fixtures)"
else
  test_fail "V6.2.i: $load_failures load-fixture case(s) misbehaved"
fi

# ---------------------------------------------------------------------------
# V6.2.j — DOS line-ending defense: a trailing CR on the last VMID must
#          not misclassify it (r2 sub-claude P3-1).
# ---------------------------------------------------------------------------
test_start "V6.2.j" "artifact with CRLF line endings does not misclassify the last VMID"
crlf_artifact=$'POLICY_ON_VMIDS=150\r\nPOLICY_OFF_VMIDS=160,170\r\nPOLICY_GEN=abcdef1234567890\r\n'
set +e
crlf_result=$(bash -c "
  $(cat "$DRIVER")
  cfg_query() {
    case \"\$1\" in
      '.nodes[0].name') echo pve01 ;;
      '.nodes[0].mgmt_ip') echo 10.0.0.1 ;;
      *) echo '' ;;
    esac
  }
  export CONTENT=\"\$1\"
  ssh() { printf '%s' \"\$CONTENT\"; }
  if load_policy_artifact 1 >/dev/null 2>&1; then
    if vmid_is_policy_off '170'; then echo off; else echo on; fi
  else
    echo load_failed
  fi
" _ "$crlf_artifact")
crlf_rc=$?
set -e
if [[ "$crlf_rc" -eq 0 && "$crlf_result" == "off" ]]; then
  test_pass "CRLF artifact: trailing-CR stripped, last VMID correctly classified policy-off"
else
  test_fail "V6.2.j: CRLF handling incorrect — result=${crlf_result} rc=${crlf_rc}"
fi

# ---------------------------------------------------------------------------
# V6.2.k — empty target guard: vmid_is_policy_off "" never returns 0.
# ---------------------------------------------------------------------------
test_start "V6.2.k" "vmid_is_policy_off refuses empty target (never match trailing-comma element)"
set +e
empty_result=$(
  bash -c "
    $(cat "$DRIVER")
    POLICY_ARTIFACT_STATE=present
    POLICY_OFF_VMIDS='160,'
    IFS=',' read -ra POLICY_OFF_ARR <<< \"\$POLICY_OFF_VMIDS\"
    if vmid_is_policy_off ''; then echo off; else echo on; fi
    if vmid_is_policy_off '160'; then echo off; else echo on; fi
  "
)
empty_rc=$?
set -e
expected_empty=$'on\noff'
if [[ "$empty_rc" -eq 0 && "$empty_result" == "$expected_empty" ]]; then
  test_pass "empty target returns policy-on; valid target still classifies correctly"
else
  test_fail "V6.2.k: empty-target guard failed — result=${empty_result} rc=${empty_rc}"
fi

runner_summary
