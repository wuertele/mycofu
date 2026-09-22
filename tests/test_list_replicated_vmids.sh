#!/usr/bin/env bash
# test_list_replicated_vmids.sh - replication policy VMID helper fixture.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/site"

cp "${REPO_ROOT}/framework/scripts/list-replicated-vmids.sh" \
  "${FIXTURE_REPO}/framework/scripts/list-replicated-vmids.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/list-replicated-vmids.sh"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
vms:
  gitlab:
    vmid: 150
    backup: true
  cicd:
    vmid: 160
  vault_dev:
    vmid: 303
    backup: true
  dns1_dev:
    vmid: 301
  dns2_dev:
    vmid: 302
    replicate: "1m"
  dns1_prod:
    vmid: 401
    replicate: "1m"
  vault_prod:
    vmid: 403
    backup: true
  gatus:
    vmid: 404
  disabled_shared:
    vmid: 151
    backup: true
    enabled: false
EOF

cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications:
  roon:
    enabled: true
    backup: true
    environments:
      dev:
        vmid: 503
      prod:
        vmid: 603
  grafana:
    enabled: true
    backup: false
    replicate: "1m"
    environments:
      dev:
        vmid: 502
      prod:
        vmid: 602
  scratch:
    enabled: true
    backup: false
    replicate: false
    environments:
      dev:
        vmid: 504
      prod:
        vmid: 604
  disabled:
    enabled: false
    backup: true
    replicate: "1m"
    environments:
      dev:
        vmid: 505
EOF

cp "${FIXTURE_REPO}/site/config.yaml" "${TMP_DIR}/base-config.yaml"
cp "${FIXTURE_REPO}/site/applications.yaml" "${TMP_DIR}/base-applications.yaml"

restore_fixture_configs() {
  cp "${TMP_DIR}/base-config.yaml" "${FIXTURE_REPO}/site/config.yaml"
  cp "${TMP_DIR}/base-applications.yaml" "${FIXTURE_REPO}/site/applications.yaml"
}

write_testvm_fixture() {
  local vmid="${1:-305}"
  local backup="${2:-false}"

  cat > "${FIXTURE_REPO}/site/config.yaml" <<EOF
vms:
  testvm:
    vmid: ${vmid}
    backup: ${backup}
EOF
  cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF
}

write_anchor_fixture() {
  cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
vms:
  anchor_160:
    vmid: 160
    replicate: "24h"
  anchor_301:
    vmid: 301
    replicate: "24h"
  anchor_302:
    vmid: 302
    replicate: "24h"
  anchor_305:
    vmid: 305
    replicate: "24h"
  anchor_500:
    vmid: 500
    replicate: "24h"
  anchor_502:
    vmid: 502
    replicate: "24h"
EOF
  cat > "${FIXTURE_REPO}/site/applications.yaml" <<'EOF'
applications: {}
EOF
}

run_helper() {
  (
    cd "${FIXTURE_REPO}"
    framework/scripts/list-replicated-vmids.sh "$@"
  )
}

run_helper_capture() {
  set +e
  HELPER_OUTPUT="$(
    cd "${FIXTURE_REPO}" &&
    framework/scripts/list-replicated-vmids.sh "$@" 2>&1
  )"
  HELPER_STATUS=$?
  set -e
}

run_helper_capture_split() {
  local stdout_file="${TMP_DIR}/helper.stdout"
  local stderr_file="${TMP_DIR}/helper.stderr"

  set +e
  (
    cd "${FIXTURE_REPO}" &&
    framework/scripts/list-replicated-vmids.sh "$@" >"$stdout_file" 2>"$stderr_file"
  )
  HELPER_STATUS=$?
  set -e
  HELPER_STDOUT="$(cat "$stdout_file")"
  HELPER_STDERR="$(cat "$stderr_file")"
}

assert_output() {
  local args="$1"
  local expected="$2"
  local label="$3"
  local actual

  # shellcheck disable=SC2086
  actual="$(run_helper $args)"
  if [[ "$actual" == "$expected" ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    printf '    args:     %s\n    expected: %s\n    actual:   %s\n' "$args" "$expected" "$actual" >&2
  fi
}

assert_testvm_translation() {
  local cadence="$1"
  local vmid="$2"
  local expected_schedule="$3"
  local expected_seconds="$4"
  local expected_seed_wait="$5"
  local expected_row

  write_testvm_fixture "$vmid" false
  yq -i ".vms.testvm.replicate = \"${cadence}\"" "${FIXTURE_REPO}/site/config.yaml"
  run_helper_capture_split --format tsv --mode all all
  expected_row="${vmid}"$'\t''testvm'$'\t''shared'$'\t''true'$'\t''explicit'$'\t'"${cadence}"$'\t'"${expected_schedule}"$'\t'"${expected_seconds}"$'\t'"${expected_seed_wait}"
  if [[ "$HELPER_STATUS" -eq 0 && "$HELPER_STDOUT" == "$expected_row" ]]; then
    test_pass "${cadence} on VMID ${vmid} translates to ${expected_schedule}/${expected_seconds}"
  else
    test_fail "${cadence} on VMID ${vmid} translation mismatch"
    printf '    status=%s\n    expected:\n%s\n    stdout:\n%s\n    stderr:\n%s\n' \
      "$HELPER_STATUS" "$expected_row" "$HELPER_STDOUT" "$HELPER_STDERR" >&2
  fi
}

csv_to_lines() {
  tr ',' '\n' | sed '/^$/d'
}

test_start "1" "replicated mode applies MR-4 ratified defaults and cadence opt-ins"
# MR-4 doctrine: every enabled non-explicit-false VM is policy-on.
# 12 policy-on VMIDs (all except scratch's 504/604 which are explicit false).
assert_output "--mode replicated all" "150,160,303,301,302,401,403,404,503,603,502,602" \
  "MR-4 defaults + explicit-cadence entries are policy-on"

test_start "2" "policy-off mode contains only explicit replicate:false entries under MR-4"
assert_output "--mode policy-off all" "504,604" \
  "explicit replicate:false app entries are policy-off"
assert_output "--off all" "504,604" \
  "--off emits only explicit replicate:false rows"

test_start "3" "tsv all mode reflects MR-4 flipped defaults (default-precious/prod/shared/dev)"
expected_tsv=$'150\tgitlab\tshared\ttrue\tdefault-precious\t1m\t*/1\t60\tstrict\n160\tcicd\tshared\ttrue\tdefault-shared\t1m\t*/1\t60\tstrict\n303\tvault-dev\tdev\ttrue\tdefault-precious\t1m\t*/1\t60\tstrict\n301\tdns1-dev\tdev\ttrue\tdefault-dev\t24h\t02:10\t86400\tasync\n302\tdns2-dev\tdev\ttrue\texplicit\t1m\t*/1\t60\tstrict\n401\tdns1-prod\tprod\ttrue\texplicit\t1m\t*/1\t60\tstrict\n403\tvault-prod\tprod\ttrue\tdefault-precious\t1m\t*/1\t60\tstrict\n404\tgatus\tprod\ttrue\tdefault-prod\t1m\t*/1\t60\tstrict\n503\troon-dev\tdev\ttrue\tdefault-precious\t1m\t*/1\t60\tstrict\n603\troon-prod\tprod\ttrue\tdefault-precious\t1m\t*/1\t60\tstrict\n502\tgrafana-dev\tdev\ttrue\texplicit\t1m\t*/1\t60\tstrict\n602\tgrafana-prod\tprod\ttrue\texplicit\t1m\t*/1\t60\tstrict\n504\tscratch-dev\tdev\tfalse\texplicit\t\t\t\t\n604\tscratch-prod\tprod\tfalse\texplicit\t\t\t\t'
actual_tsv="$(run_helper --format tsv --mode all all)"
if [[ "$actual_tsv" == "$expected_tsv" ]]; then
  test_pass "tsv all output exposes flipped default labels + cadence metadata for every enabled VM"
else
  test_fail "tsv all output mismatch"
  printf '    expected:\n%s\n    actual:\n%s\n' "$expected_tsv" "$actual_tsv" >&2
fi

test_start "4" "app-level replicate applies to all env VMs and disabled apps are ignored"
all_tsv="$(run_helper --format tsv --mode all all)"
if grep -Fq $'502\tgrafana-dev\tdev\ttrue\texplicit\t1m\t*/1\t60\tstrict' <<< "$all_tsv" &&
   grep -Fq $'602\tgrafana-prod\tprod\ttrue\texplicit\t1m\t*/1\t60\tstrict' <<< "$all_tsv" &&
   grep -Fq $'504\tscratch-dev\tdev\tfalse\texplicit\t\t\t\t' <<< "$all_tsv" &&
   grep -Fq $'604\tscratch-prod\tprod\tfalse\texplicit\t\t\t\t' <<< "$all_tsv" &&
   ! grep -Fq $'\t505\t' <<< "$all_tsv" &&
   ! grep -Fq 'disabled' <<< "$all_tsv"; then
  test_pass "app-level cadence/false and enabled:false semantics are honored"
else
  test_fail "app-level replicate or disabled-app semantics drifted"
  printf '    output:\n%s\n' "$all_tsv" >&2
fi

test_start "5" "top-level enabled != false semantics are honored"
all_csv="$(run_helper --mode all all)"
if grep -Fxq "150" <<< "$(printf '%s' "$all_csv" | csv_to_lines)" &&
   ! grep -Fxq "151" <<< "$(printf '%s' "$all_csv" | csv_to_lines)"; then
  test_pass "missing enabled is included and enabled:false is excluded"
else
  test_fail "top-level enabled semantics drifted"
  printf '    output: %s\n' "$all_csv" >&2
fi

test_start "6" "--mode policy-off is the exact complement of --mode replicated"
replicated_sorted="$(run_helper --mode replicated all | csv_to_lines | sort)"
policy_off_sorted="$(run_helper --mode policy-off all | csv_to_lines | sort)"
all_sorted="$(run_helper --mode all all | csv_to_lines | sort)"
union_sorted="$(printf '%s\n%s\n' "$replicated_sorted" "$policy_off_sorted" | sed '/^$/d' | sort)"
intersection="$(comm -12 <(printf '%s\n' "$replicated_sorted") <(printf '%s\n' "$policy_off_sorted") || true)"
if [[ "$union_sorted" == "$all_sorted" && -z "$intersection" ]]; then
  test_pass "replicated and policy-off partitions cover every enabled VM exactly once"
else
  test_fail "replicated and policy-off partitions are not exact complements"
  printf '    replicated:\n%s\n    policy-off:\n%s\n    all:\n%s\n' "$replicated_sorted" "$policy_off_sorted" "$all_sorted" >&2
fi

test_start "7" "dev/prod/all scoping works under MR-4 defaults"
# All dev enabled non-explicit-false VMs are policy-on (303, 301, 302,
# 503, 502); no dev-scoped policy-off except scratch's 504.
assert_output "--mode replicated dev" "303,301,302,503,502" "dev replicated scope is env-only"
assert_output "--mode policy-off dev" "504" "dev policy-off scope contains only explicit-false"
# All prod enabled non-explicit-false VMs are policy-on incl. gatus.
assert_output "--mode replicated prod" "401,403,404,603,602" "prod replicated scope includes gatus"
assert_output "--mode policy-off prod" "604" "prod policy-off scope contains only explicit-false"

test_start "8" "default function is the MR-4 ratified doctrine"
# backup:true → default-precious 1m; env==dev+no-explicit → default-dev 24h;
# env==prod+no-explicit → default-prod 1m; env==shared+no-explicit →
# default-shared 1m; gatus stays prod-pinned.
all_tsv="$(run_helper --format tsv --mode all all)"
if grep -Fq $'150\tgitlab\tshared\ttrue\tdefault-precious\t1m\t*/1\t60\tstrict' <<< "$all_tsv" &&
   grep -Fq $'160\tcicd\tshared\ttrue\tdefault-shared\t1m\t*/1\t60\tstrict' <<< "$all_tsv" &&
   grep -Fq $'404\tgatus\tprod\ttrue\tdefault-prod\t1m\t*/1\t60\tstrict' <<< "$all_tsv" &&
   grep -Fq $'301\tdns1-dev\tdev\ttrue\tdefault-dev\t24h\t02:10\t86400\tasync' <<< "$all_tsv"; then
  test_pass "backup ⇒ 1m default-precious; shared ⇒ 1m; prod ⇒ 1m; dev ⇒ 24h; gatus prod-pinned"
else
  test_fail "default policy function or gatus env pin drifted"
  printf '    output:\n%s\n' "$all_tsv" >&2
fi

test_start "9" "duplicate VMID fails closed"
restore_fixture_configs
yq -i '.vms.dns1_dev.vmid = 150' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture --mode all all
if [[ "$HELPER_STATUS" -eq 1 && "$HELPER_OUTPUT" == *"duplicate replication-policy VMID 150"* ]]; then
  test_pass "duplicate VMID exits non-zero with explicit error"
else
  test_fail "duplicate VMID should fail closed"
  printf '    status=%s\n    output:\n%s\n' "$HELPER_STATUS" "$HELPER_OUTPUT" >&2
fi

test_start "10" "missing VMID fails closed"
restore_fixture_configs
yq -i 'del(.vms.gitlab.vmid)' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture --mode all all
if [[ "$HELPER_STATUS" -eq 1 && "$HELPER_OUTPUT" == *"has no vmid"* ]]; then
  test_pass "missing VMID exits non-zero with explicit error"
else
  test_fail "missing VMID should fail closed"
  printf '    status=%s\n    output:\n%s\n' "$HELPER_STATUS" "$HELPER_OUTPUT" >&2
fi

test_start "11" "non-positive VMID fails closed"
restore_fixture_configs
yq -i '.vms.gitlab.vmid = 0' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture --mode all all
if [[ "$HELPER_STATUS" -eq 1 && "$HELPER_OUTPUT" == *"invalid vmid"* ]]; then
  test_pass "non-positive VMID exits non-zero with explicit error"
else
  test_fail "non-positive VMID should fail closed"
  printf '    status=%s\n    output:\n%s\n' "$HELPER_STATUS" "$HELPER_OUTPUT" >&2
fi

test_start "12" "cadence syntax matrix accepts supported shorthand"
while IFS=$'\t' read -r label expr vmid; do
  [[ -z "$label" ]] && continue
  write_testvm_fixture "$vmid" false
  yq -i ".vms.testvm.replicate = ${expr}" "${FIXTURE_REPO}/site/config.yaml"
  run_helper_capture_split --mode all all
  if [[ "$HELPER_STATUS" -eq 0 ]]; then
    test_pass "${label} cadence is accepted"
  else
    test_fail "${label} cadence should be accepted"
    printf '    status=%s\n    stdout:\n%s\n    stderr:\n%s\n' "$HELPER_STATUS" "$HELPER_STDOUT" "$HELPER_STDERR" >&2
  fi
done <<'EOF'
1m	"1m"	305
24h	"24h"	160
15m	"15m"	305
6h	"6h"	305
EOF

test_start "13" "cadence syntax matrix rejects invalid values with key path"
while IFS=$'\t' read -r label expr; do
  [[ -z "$label" ]] && continue
  write_testvm_fixture 305 false
  yq -i ".vms.testvm.replicate = ${expr}" "${FIXTURE_REPO}/site/config.yaml"
  run_helper_capture_split --mode all all
  if [[ "$HELPER_STATUS" -ne 0 && "$HELPER_STDERR" == *"vms.testvm.replicate"* ]]; then
    test_pass "${label} cadence is rejected with key path"
  else
    test_fail "${label} cadence should fail closed with key path"
    printf '    expr=%s\n    status=%s\n    stdout:\n%s\n    stderr:\n%s\n' \
      "$expr" "$HELPER_STATUS" "$HELPER_STDOUT" "$HELPER_STDERR" >&2
  fi
done <<'EOF'
cron-step	"*/1"
wall-time	"03:00"
day-unit	"1d"
zero-minute	"0m"
sixty-minute-out-of-range	"60m"
twenty-five-hour-out-of-range	"25h"
seconds-unit	"90s"
numeric-literal	60
quoted-numeric-string	"60"
yaml-array	[]
yaml-map	{}
EOF

test_start "14" "cadence translation table emits exact strings"
assert_testvm_translation "1m" 305 "*/1" "60" "strict"
assert_testvm_translation "15m" 305 "*/15" "900" "async"
assert_testvm_translation "6h" 305 "0/6:00" "21600" "async"
assert_testvm_translation "24h" 160 "03:00" "86400" "async"
assert_testvm_translation "24h" 301 "02:10" "86400" "async"

write_testvm_fixture 999 false
yq -i '.vms.testvm.replicate = "24h"' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture_split --format tsv --mode all all
if [[ "$HELPER_STATUS" -ne 0 && "$HELPER_STDERR" == *"24h anchor table"* && "$HELPER_STDERR" == *"vms.testvm.replicate"* ]]; then
  test_pass "24h cadence on unmapped VMID fails closed with anchor-table error"
else
  test_fail "24h cadence on unmapped VMID should fail closed"
  printf '    status=%s\n    stdout:\n%s\n    stderr:\n%s\n' "$HELPER_STATUS" "$HELPER_STDOUT" "$HELPER_STDERR" >&2
fi

test_start "15" "boolean replicate handling is transition-compatible"
write_testvm_fixture 305 false
yq -i '.vms.testvm.replicate = false' "${FIXTURE_REPO}/site/config.yaml"
policy_off_csv="$(run_helper --format csv --mode policy-off all)"
explicit_off_csv="$(run_helper --format csv --off all)"
replicated_csv="$(run_helper --format csv --mode replicated all)"
all_tsv="$(run_helper --format tsv --mode all all)"
if [[ "$policy_off_csv" == "305" && "$explicit_off_csv" == "305" && -z "$replicated_csv" ]] &&
   grep -Fq $'305\ttestvm\tshared\tfalse\texplicit\t\t\t\t' <<< "$all_tsv"; then
  test_pass "replicate:false appears in policy-off and --off with empty cadence metadata"
else
  test_fail "replicate:false mode semantics drifted"
  printf '    policy_off=%s\n    explicit_off=%s\n    replicated=%s\n    tsv:\n%s\n' \
    "$policy_off_csv" "$explicit_off_csv" "$replicated_csv" "$all_tsv" >&2
fi

write_testvm_fixture 305 false
yq -i '.vms.testvm.replicate = true' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture_split --format tsv --mode all all
# MR-4 T4.1 (S4 refinement): the transitional boolean `true` acceptance
# branch was REMOVED entirely. `replicate: true` now returns the same
# "invalid cadence" error as any non-string non-`false` value — closes
# the taste-#4 window by deletion rather than by semantic override.
if [[ "$HELPER_STATUS" -ne 0 ]] &&
   [[ "$HELPER_STDERR" == *"invalid cadence"* ]] &&
   [[ "$HELPER_STDERR" == *"vms.testvm.replicate"* ]] &&
   [[ "$HELPER_STDERR" != *"deprecated"* ]]; then
  test_pass "boolean replicate:true is fatal (transitional branch removed at MR-4)"
else
  test_fail "replicate:true post-MR-4 behavior drifted (must be fatal, no deprecation WARN)"
  printf '    status=%s\n    stdout:\n%s\n    stderr:\n%s\n' "$HELPER_STATUS" "$HELPER_STDOUT" "$HELPER_STDERR" >&2
fi

test_start "16" "precious floor rejects weaker cadences and warns on redundant 1m"
write_testvm_fixture 150 true
yq -i '.vms.testvm.replicate = false' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture_split --mode all all
if [[ "$HELPER_STATUS" -ne 0 && "$HELPER_STDERR" == *"vms.testvm.replicate must not be false"* ]]; then
  test_pass "backup:true plus replicate:false is fatal"
else
  test_fail "backup:true plus replicate:false should be fatal"
  printf '    status=%s\n    stdout:\n%s\n    stderr:\n%s\n' "$HELPER_STATUS" "$HELPER_STDOUT" "$HELPER_STDERR" >&2
fi

write_testvm_fixture 150 true
yq -i '.vms.testvm.replicate = "24h"' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture_split --mode all all
if [[ "$HELPER_STATUS" -ne 0 && "$HELPER_STDERR" == *'vms.testvm.replicate must be "1m"'* ]]; then
  test_pass "backup:true plus replicate:\"24h\" is fatal"
else
  test_fail "backup:true plus replicate:\"24h\" should be fatal"
  printf '    status=%s\n    stdout:\n%s\n    stderr:\n%s\n' "$HELPER_STATUS" "$HELPER_STDOUT" "$HELPER_STDERR" >&2
fi

write_testvm_fixture 150 true
yq -i '.vms.testvm.replicate = "1m"' "${FIXTURE_REPO}/site/config.yaml"
run_helper_capture_split --format tsv --mode all all
if [[ "$HELPER_STATUS" -eq 0 ]] &&
   [[ "$HELPER_STDOUT" == $'150\ttestvm\tshared\ttrue\texplicit\t1m\t*/1\t60\tstrict' ]] &&
   [[ "$HELPER_STDERR" == *'replicate: "1m" on backup:true VMs is redundant'* ]] &&
   [[ "$HELPER_STDERR" == *"vms.testvm.replicate"* ]]; then
  test_pass "backup:true plus replicate:\"1m\" is legal with redundant-explicit WARN"
else
  test_fail "backup:true plus replicate:\"1m\" should be legal with WARN"
  printf '    status=%s\n    stdout:\n%s\n    stderr:\n%s\n' "$HELPER_STATUS" "$HELPER_STDOUT" "$HELPER_STDERR" >&2
fi

test_start "17" "shipped site csv reflects MR-4 universal replication (20 VMIDs, all POLICY_ON)"
# MR-4 T4.1 flip: every enabled VM is policy-on. Shipped site has 20
# enabled VMs (workstation dev/prod are disabled). The Failover Manifest
# in SPRINT-048.md §"Cadence changes" is the ground truth.
site_replicated_csv="$("${REPO_ROOT}/framework/scripts/list-replicated-vmids.sh" --format csv --mode replicated all 2>"${TMP_DIR}/site-replicated.stderr")"
expected_policy_on_mr4=$'150\n160\n170\n190\n301\n302\n303\n305\n401\n402\n403\n404\n500\n501\n502\n503\n600\n601\n602\n603'
actual_policy_on="$(printf '%s' "$site_replicated_csv" | csv_to_lines | sort -n)"
if [[ "$actual_policy_on" == "$expected_policy_on_mr4" ]]; then
  test_pass "shipped site replicated csv emits the MR-4 universal POLICY_ON set (20 VMIDs)"
else
  test_fail "shipped site replicated csv POLICY_ON set drifted from MR-4 doctrine"
  printf '    csv=%s\n    expected sorted:\n%s\n    actual sorted:\n%s\n    stderr:\n%s\n' \
    "$site_replicated_csv" "$expected_policy_on_mr4" "$actual_policy_on" "$(cat "${TMP_DIR}/site-replicated.stderr")" >&2
fi

test_start "18" "shipped site --off mode is empty"
site_off_csv="$("${REPO_ROOT}/framework/scripts/list-replicated-vmids.sh" --format csv --off all 2>"${TMP_DIR}/site-off.stderr")"
if [[ -z "$site_off_csv" ]]; then
  test_pass "shipped site has no explicit replicate:false rows"
else
  test_fail "shipped site --off output should be empty"
  printf '    output=%s\n    stderr:\n%s\n' "$site_off_csv" "$(cat "${TMP_DIR}/site-off.stderr")" >&2
fi

test_start "19" "fixed 24h anchor table emits exact HH:MM schedules"
write_anchor_fixture
anchor_tsv="$(run_helper --format tsv --mode replicated all)"
if grep -Fq $'160\tanchor-160\tshared\ttrue\texplicit\t24h\t03:00\t86400\tasync' <<< "$anchor_tsv" &&
   grep -Fq $'301\tanchor-301\tshared\ttrue\texplicit\t24h\t02:10\t86400\tasync' <<< "$anchor_tsv" &&
   grep -Fq $'302\tanchor-302\tshared\ttrue\texplicit\t24h\t02:20\t86400\tasync' <<< "$anchor_tsv" &&
   grep -Fq $'305\tanchor-305\tshared\ttrue\texplicit\t24h\t02:30\t86400\tasync' <<< "$anchor_tsv" &&
   grep -Fq $'500\tanchor-500\tshared\ttrue\texplicit\t24h\t02:40\t86400\tasync' <<< "$anchor_tsv" &&
   grep -Fq $'502\tanchor-502\tshared\ttrue\texplicit\t24h\t02:50\t86400\tasync' <<< "$anchor_tsv"; then
  test_pass "24h anchor table exactness is pinned"
else
  test_fail "24h anchor table output mismatch"
  printf '    output:\n%s\n' "$anchor_tsv" >&2
fi

runner_summary
