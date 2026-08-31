#!/usr/bin/env bash
# test_configure_replication_refresh_artifact.sh — #693/#501.
#
# configure-replication.sh --refresh-artifact-only must:
#   1. Deliver /etc/repl-policy.vmids to every node as a pure projection of the
#      git-determined policy (POLICY_ON/OFF, CADENCE_MAP, POLICY_GEN).
#   2. Touch NO live replication job: no pvesh create/delete/set, no zfs
#      destroy, no VM discovery — so it cannot tear down a transient first-sync.
#   3. Deliver the SAME artifact content a full run would (projection
#      equivalence), and exit 0.
#
# The no-change-deploy staleness case (safe-apply.sh side) is covered in
# tests/test_safe_apply_recovery.sh Test 9; this test covers the delivery
# mechanism the no-change path relies on.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_SRC="${REPO_ROOT}/tests/fixtures/replication-policy"
CONFIGURE_SRC="${REPO_ROOT}/framework/scripts/configure-replication.sh"

CASE_REPO=""
CASE_SHIMS=""
RUN_RC=0

make_shims() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/ssh" <<'SSH'
#!/usr/bin/env bash
set -euo pipefail
host="" remote=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|-i|-p) shift 2 ;;
    -n|-q|-A) shift ;;
    root@*) host="${1#root@}"; shift; remote="$*"; break ;;
    *) shift ;;
  esac
done
case "$host" in
  10.0.0.1) node="pve01" ;;
  10.0.0.2) node="pve02" ;;
  10.0.0.3) node="pve03" ;;
  *) node="unknown" ;;
esac
record() { printf '%s\n' "$1" >> "${SHIM_DIR}/$2"; }
case "$remote" in
  *"cat > /etc/repl-policy.vmids.tmp"*)
    # FAIL_ARTIFACT_NODE injects a delivery failure for that node (P1 test).
    if [[ -n "${FAIL_ARTIFACT_NODE:-}" && "$node" == "${FAIL_ARTIFACT_NODE}" ]]; then
      cat >/dev/null   # drain stdin, then fail as a real remote mv error would
      exit 1
    fi
    cat > "${SHIM_DIR}/artifact_${node}.txt"
    ;;
  *"pvesh get /cluster/resources"*)
    record "$remote" vm_discovery.log
    cat "${SHIM_DIR}/vm_data.json" 2>/dev/null || echo '[]'
    ;;
  # A live replication-job READ. The refresh-only path must never issue this.
  *"pvesh get /cluster/replication"*) record "$remote" repl_reads.log; echo '[]' ;;
  *"pvesh create /cluster/replication"*) record "$remote" creates.log; echo created ;;
  *"pvesh delete /cluster/replication/"*) record "$remote" deletes.log ;;
  *"pvesh set /cluster/replication/"*) record "$remote" sets.log ;;
  *"pvesr status"*) record "$remote" pvesr_reads.log ;;
  *"zfs destroy"*) record "$remote" destroys.log ;;
  *) : ;;
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
  cp "${FIXTURE_SRC}/config.yaml" "${CASE_REPO}/site/config.yaml"
  cp "${FIXTURE_SRC}/applications.yaml" "${CASE_REPO}/site/applications.yaml"
  chmod +x "${CASE_REPO}/framework/scripts/configure-replication.sh"
  # Deterministic helper stub: 3 policy-on VMIDs (150,303,401 @ 60s), 1
  # policy-off (301). configure-replication.sh only calls `--format tsv
  # --mode all all`.
  cat > "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"--format tsv"*"--mode all"*)
    cat <<'TSV'
150	gitlab	shared	true	default-backup	1m	*/1	60	strict
301	dns1-dev	dev	false	default	24h	03:00	86400	async
303	vault-dev	dev	true	default-backup	1m	*/1	60	strict
401	dns1-prod	prod	true	default-backup	1m	*/1	60	strict
TSV
    ;;
  *) exit 2 ;;
esac
HELPER
  chmod +x "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh"
  make_shims "$CASE_SHIMS"
  # VM data for the full-run comparison (VM discovery).
  cat > "${CASE_SHIMS}/vm_data.json" <<'JSON'
[
  {"vmid":150,"name":"gitlab","node":"pve01"},
  {"vmid":301,"name":"dns1-dev","node":"pve02"},
  {"vmid":303,"name":"vault-dev","node":"pve02"},
  {"vmid":401,"name":"dns1-prod","node":"pve01"}
]
JSON
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

no_mutation_logs() {
  [[ ! -s "${CASE_SHIMS}/creates.log" && ! -s "${CASE_SHIMS}/deletes.log" \
     && ! -s "${CASE_SHIMS}/sets.log" && ! -s "${CASE_SHIMS}/destroys.log" ]]
}

EXPECTED_ON="150,303,401"
EXPECTED_OFF="301"
EXPECTED_CADENCE="150:60,303:60,401:60"
EXPECTED_GEN="$(printf '%s|%s|%s\n' "$EXPECTED_ON" "$EXPECTED_OFF" "$EXPECTED_CADENCE" | sha256sum | awk '{print $1}')"

assert_artifact_content() { # $1=artifact file
  local art="$1"
  grep -qx "POLICY_ON_VMIDS=${EXPECTED_ON}"   "$art" \
  && grep -qx "POLICY_OFF_VMIDS=${EXPECTED_OFF}" "$art" \
  && grep -qx "CADENCE_MAP=${EXPECTED_CADENCE}"  "$art" \
  && grep -qx "POLICY_GEN=${EXPECTED_GEN}"       "$art"
}

# ---------------------------------------------------------------------------
test_start "R1" "--refresh-artifact-only delivers the SAME correct artifact to EVERY node, exits 0, no VM discovery"
stage_repo "refresh"
run_configure --refresh-artifact-only
ok=1
[[ "$RUN_RC" -eq 0 ]] || ok=0
# Artifact delivered to all 3 nodes, each with the correct content (codex P3:
# assert every node copy, not just the first).
for node in pve01 pve02 pve03; do
  [[ -s "${CASE_SHIMS}/artifact_${node}.txt" ]] || ok=0
  assert_artifact_content "${CASE_SHIMS}/artifact_${node}.txt" || ok=0
done
# All three node copies are byte-identical.
cmp -s "${CASE_SHIMS}/artifact_pve01.txt" "${CASE_SHIMS}/artifact_pve02.txt" || ok=0
cmp -s "${CASE_SHIMS}/artifact_pve01.txt" "${CASE_SHIMS}/artifact_pve03.txt" || ok=0
# Banner present; VM discovery skipped.
grep -q 'Refresh-artifact-only' "${CASE_SHIMS}/stdout.txt" || ok=0
grep -q 'Finding VMs matching' "${CASE_SHIMS}/stdout.txt" && ok=0
[[ ! -s "${CASE_SHIMS}/vm_discovery.log" ]] || ok=0
if [[ "$ok" -eq 1 ]]; then
  test_pass "byte-identical artifact with correct POLICY_ON/OFF/CADENCE_MAP/POLICY_GEN on all 3 nodes; rc=0; VM discovery skipped"
else
  test_fail "refresh-artifact-only delivery/exit/discovery contract not met (rc=$RUN_RC)"
  printf -- '--- stdout ---\n%s\n--- stderr ---\n%s\n--- artifact_pve01 ---\n%s\n' \
    "$(cat "${CASE_SHIMS}/stdout.txt")" "$(cat "${CASE_SHIMS}/stderr.txt")" \
    "$(cat "${CASE_SHIMS}/artifact_pve01.txt" 2>/dev/null || true)" >&2
fi

test_start "R2" "--refresh-artifact-only reads/mutates NO live replication job"
# Guard-honoring assertion: the refresh must not read or tear down any live
# job. codex P2: `pvesh get /cluster/replication` is a live-job READ and must
# also stay empty (not just mutations + pvesr status).
if no_mutation_logs \
   && [[ ! -s "${CASE_SHIMS}/pvesr_reads.log" ]] \
   && [[ ! -s "${CASE_SHIMS}/repl_reads.log" ]]; then
  test_pass "no pvesh create/delete/set/get-replication, no zfs destroy, no pvesr status read"
else
  test_fail "refresh-artifact-only touched live replication state"
  for f in creates deletes sets destroys pvesr_reads repl_reads; do
    printf -- '--- %s.log ---\n%s\n' "$f" "$(cat "${CASE_SHIMS}/${f}.log" 2>/dev/null || true)" >&2
  done
fi

test_start "R3" "mutation contrast: a full run over the SAME fixture DOES the discovery/creates refresh-only skips"
# Proves R1/R2's "skipped" assertions are non-vacuous: with the identical
# policy fixture but WITHOUT --refresh-artifact-only, the script performs VM
# discovery and pvesh create (and reads pvesr) — exactly the create/seed
# machinery that would tear down transient first-syncs on a no-change deploy.
# (Byte equivalence of the delivered artifact is proven structurally: both
# paths call the same deliver_policy_artifact() with the same globals, and R1
# asserts the exact canonical bytes. The full run exits non-zero at the
# initial-sync wait in this minimal fixture — the caveat documented in
# test_configure_replication_policy_prune.sh — so it does not reach delivery;
# we assert on the machinery it reached, not on rc.)
stage_repo "fullrun"
run_configure --env dev
if [[ -s "${CASE_SHIMS}/vm_discovery.log" ]] \
   && [[ -s "${CASE_SHIMS}/creates.log" ]] \
   && grep -q 'Finding VMs matching' "${CASE_SHIMS}/stdout.txt" \
   && ! grep -q 'Refresh-artifact-only' "${CASE_SHIMS}/stdout.txt"; then
  test_pass "full run does VM discovery + pvesh create (the machinery refresh-only correctly skips)"
else
  test_fail "full-run-is-heavier mutation contrast failed"
  printf -- '--- vm_discovery ---\n%s\n--- creates ---\n%s\n--- stdout(head) ---\n%s\n' \
    "$(cat "${CASE_SHIMS}/vm_discovery.log" 2>/dev/null || true)" \
    "$(cat "${CASE_SHIMS}/creates.log" 2>/dev/null || true)" \
    "$(head -20 "${CASE_SHIMS}/stdout.txt" 2>/dev/null || true)" >&2
fi

test_start "R4" "a git POLICY change (cadence value) flows into a fresh CADENCE_MAP + rolled POLICY_GEN on the refresh path"
# agy P2 / claude P2: the whole point of the no-change refresh is that a git
# policy change lands in the artifact even with no VM/tofu change. Mutate the
# helper's cadence for 401 (60s → 300s) and assert the delivered artifact
# tracks it. This is the projection-tracks-git-policy guarantee at the core of
# #693.
stage_repo "refresh-changed"
# Rewrite the staged helper so 401's cadence_seconds is 300 (schedule */5).
cat > "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh" <<'HELPER2'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"--format tsv"*"--mode all"*)
    cat <<'TSV'
150	gitlab	shared	true	default-backup	1m	*/1	60	strict
301	dns1-dev	dev	false	default	24h	03:00	86400	async
303	vault-dev	dev	true	default-backup	1m	*/1	60	strict
401	dns1-prod	prod	true	default	5m	*/5	300	async
TSV
    ;;
  *) exit 2 ;;
esac
HELPER2
chmod +x "${CASE_REPO}/framework/scripts/list-replicated-vmids.sh"
run_configure --refresh-artifact-only
CHANGED_CADENCE="150:60,303:60,401:300"
CHANGED_GEN="$(printf '%s|%s|%s\n' "$EXPECTED_ON" "$EXPECTED_OFF" "$CHANGED_CADENCE" | sha256sum | awk '{print $1}')"
art="${CASE_SHIMS}/artifact_pve01.txt"
if [[ "$RUN_RC" -eq 0 ]] \
   && grep -qx "CADENCE_MAP=${CHANGED_CADENCE}" "$art" \
   && grep -qx "POLICY_GEN=${CHANGED_GEN}" "$art" \
   && [[ "$CHANGED_GEN" != "$EXPECTED_GEN" ]]; then
  test_pass "cadence-value change delivered a new CADENCE_MAP and a rolled POLICY_GEN"
else
  test_fail "refresh did not track the git cadence change (rc=$RUN_RC)"
  printf -- '--- artifact_pve01 ---\n%s\n' "$(cat "$art" 2>/dev/null || true)" >&2
fi

test_start "R5" "delivery failure to any node fails closed (non-zero rc, no false success)"
# codex P1 / agy P2 / claude P3: a partial/failed delivery must NOT report
# success, else the stale-artifact false-red this fix kills just re-appears as
# "refresh silently half-failed". Inject a pve02 delivery failure.
stage_repo "delivery-fail"
FAIL_ARTIFACT_NODE=pve02 run_configure --refresh-artifact-only
if [[ "$RUN_RC" -ne 0 ]] \
   && grep -q 'failed to deliver artifact to pve02' "${CASE_SHIMS}/stderr.txt" \
   && grep -q 'delivery incomplete' "${CASE_SHIMS}/stderr.txt"; then
  test_pass "a node delivery failure makes --refresh-artifact-only exit non-zero (fail closed)"
else
  test_fail "delivery failure did not fail closed (rc=$RUN_RC)"
  printf -- '--- stderr ---\n%s\n' "$(cat "${CASE_SHIMS}/stderr.txt" 2>/dev/null || true)" >&2
fi

runner_summary
