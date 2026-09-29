#!/usr/bin/env bash
# test_validate_site_config.sh - replication policy schema validation.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REAL_YQ="$(command -v yq)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

make_fixture() {
  local target_var="$1"
  local fixture
  fixture="$(mktemp -d "${TMP_DIR}/validate-site-config.XXXXXX")"
  cp "${REPO_ROOT}/site/config.yaml" "${fixture}/config.yaml"
  cp "${REPO_ROOT}/site/applications.yaml" "${fixture}/applications.yaml"
  printf -v "$target_var" '%s' "$fixture"
}

run_validator() {
  local fixture="$1"
  local helper="${2:-${REPO_ROOT}/framework/scripts/list-replicated-vmids.sh}"

  set +e
  OUTPUT="$(
    VALIDATE_SITE_CONFIG_CONFIG="${fixture}/config.yaml" \
    VALIDATE_SITE_CONFIG_APPS_CONFIG="${fixture}/applications.yaml" \
    VALIDATE_SITE_CONFIG_REPLICATED_HELPER="$helper" \
      "${REPO_ROOT}/framework/scripts/validate-site-config.sh" 2>&1
  )"
  STATUS=$?
  set -e
  printf '%s' "$OUTPUT" > "${fixture}/output.txt"
  printf '%s' "$STATUS" > "${fixture}/exit.txt"
}

assert_validator_ok() {
  local fixture="$1"
  local label="$2"

  run_validator "$fixture"
  if [[ "$(cat "${fixture}/exit.txt")" -eq 0 ]]; then
    test_pass "$label"
  else
    test_fail "$label"
    sed 's/^/    /' "${fixture}/output.txt" >&2
  fi
}

assert_validator_fails_with_path() {
  local fixture="$1"
  local key_path="$2"
  local label="$3"

  run_validator "$fixture"
  if [[ "$(cat "${fixture}/exit.txt")" -ne 0 ]] &&
     grep -Fq "$key_path" "${fixture}/output.txt"; then
    test_pass "$label"
  else
    test_fail "$label"
    sed 's/^/    /' "${fixture}/output.txt" >&2
  fi
}

test_start "1" "clean config validates under MR-4 doctrine (opt-ins absorbed, cicd 24h explicit)"
make_fixture CLEAN_FIXTURE
run_validator "$CLEAN_FIXTURE"
# Sprint 048 MR-4 T4.2: the three Sprint 047 `replicate: true` opt-ins
# (dns1_prod:202, dns2_prod:209, pbs:248) were REMOVED — absorbed by
# the ratified default rule (backup+prod+shared ⇒ 1m). cicd now
# carries an explicit `replicate: "24h"` line per operator ratification.
# CI ratchet: a regression that reintroduces any of the removed opt-ins
# (or removes cicd's 24h line, or reintroduces boolean `true`) fails
# here before it can silently drift the M2 seed doctrine.
if [[ "$(cat "${CLEAN_FIXTURE}/exit.txt")" -eq 0 ]] &&
   [[ "$("${REAL_YQ}" -r '.vms.dns1_prod.replicate // "unset"' "${CLEAN_FIXTURE}/config.yaml")" == "unset" ]] &&
   [[ "$("${REAL_YQ}" -r '.vms.dns2_prod.replicate // "unset"' "${CLEAN_FIXTURE}/config.yaml")" == "unset" ]] &&
   [[ "$("${REAL_YQ}" -r '.vms.pbs.replicate // "unset"' "${CLEAN_FIXTURE}/config.yaml")" == "unset" ]] &&
   [[ "$("${REAL_YQ}" -r '.vms.cicd.replicate' "${CLEAN_FIXTURE}/config.yaml")" == "24h" ]]; then
  test_pass "current config validates; MR-4 doctrine intact (no boolean opt-ins; cicd 24h explicit)"
else
  test_fail "clean config failed validation or MR-4 doctrine drifted"
  sed 's/^/    /' "${CLEAN_FIXTURE}/output.txt" >&2
fi

test_start "2" "validator accepts cadence shorthand for top-level VMs"
while IFS=$'\t' read -r label expr vm_key; do
  [[ -z "$label" ]] && continue
  make_fixture ACCEPT_VM_FIXTURE
  "${REAL_YQ}" -i ".vms.${vm_key}.replicate = ${expr}" "${ACCEPT_VM_FIXTURE}/config.yaml"
  assert_validator_ok "$ACCEPT_VM_FIXTURE" "vms.${vm_key}.replicate accepts ${label}"
done <<'EOF'
1m	"1m"	cicd
24h	"24h"	cicd
15m	"15m"	cicd
6h	"6h"	cicd
EOF

test_start "3" "validator rejects invalid top-level VM replicate values with key path"
while IFS=$'\t' read -r label expr; do
  [[ -z "$label" ]] && continue
  make_fixture BAD_VM_FIXTURE
  "${REAL_YQ}" -i ".vms.cicd.replicate = ${expr}" "${BAD_VM_FIXTURE}/config.yaml"
  assert_validator_fails_with_path "$BAD_VM_FIXTURE" "vms.cicd.replicate" \
    "vms.cicd.replicate rejects ${label}"
done <<'EOF'
cron-step	"*/1"
wall-time	"03:00"
day-unit	"1d"
zero-minute	"0m"
seconds-unit	"90s"
numeric-literal	60
yaml-array	[]
yaml-map	{}
EOF

test_start "4" "validator rejects invalid application replicate values with key path"
while IFS=$'\t' read -r label expr; do
  [[ -z "$label" ]] && continue
  make_fixture BAD_APP_FIXTURE
  "${REAL_YQ}" -i ".applications.grafana.replicate = ${expr}" "${BAD_APP_FIXTURE}/applications.yaml"
  assert_validator_fails_with_path "$BAD_APP_FIXTURE" "applications.grafana.replicate" \
    "applications.grafana.replicate rejects ${label}"
done <<'EOF'
cron-step	"*/1"
wall-time	"03:00"
day-unit	"1d"
zero-minute	"0m"
seconds-unit	"90s"
numeric-literal	60
yaml-array	[]
yaml-map	{}
EOF

test_start "5" "precious top-level VM cadence floor is enforced"
make_fixture VAULT_FALSE_FIXTURE
"${REAL_YQ}" -i '.vms.vault_prod.replicate = false' "${VAULT_FALSE_FIXTURE}/config.yaml"
assert_validator_fails_with_path "$VAULT_FALSE_FIXTURE" "vms.vault_prod.replicate" \
  "vms.vault_prod.replicate:false is rejected by key path"

make_fixture VAULT_24H_FIXTURE
"${REAL_YQ}" -i '.vms.vault_prod.replicate = "24h"' "${VAULT_24H_FIXTURE}/config.yaml"
assert_validator_fails_with_path "$VAULT_24H_FIXTURE" "vms.vault_prod.replicate" \
  "vms.vault_prod.replicate:\"24h\" is rejected by key path"

make_fixture VAULT_1M_FIXTURE
"${REAL_YQ}" -i '.vms.vault_prod.replicate = "1m"' "${VAULT_1M_FIXTURE}/config.yaml"
assert_validator_ok "$VAULT_1M_FIXTURE" "vms.vault_prod.replicate:\"1m\" is legal"

test_start "6" "precious application cadence floor is enforced"
make_fixture ROON_FALSE_FIXTURE
"${REAL_YQ}" -i '.applications.roon.replicate = false' "${ROON_FALSE_FIXTURE}/applications.yaml"
assert_validator_fails_with_path "$ROON_FALSE_FIXTURE" "applications.roon.replicate" \
  "applications.roon.replicate:false is rejected by key path"

make_fixture ROON_24H_FIXTURE
"${REAL_YQ}" -i '.applications.roon.replicate = "24h"' "${ROON_24H_FIXTURE}/applications.yaml"
assert_validator_fails_with_path "$ROON_24H_FIXTURE" "applications.roon.replicate" \
  "applications.roon.replicate:\"24h\" is rejected by key path"

make_fixture ROON_1M_FIXTURE
"${REAL_YQ}" -i '.applications.roon.replicate = "1m"' "${ROON_1M_FIXTURE}/applications.yaml"
assert_validator_ok "$ROON_1M_FIXTURE" "applications.roon.replicate:\"1m\" is legal"

test_start "7" "comment-based ratification above replicate is ignored by YAML parser"
make_fixture COMMENT_FIXTURE
"${REAL_YQ}" -i '.vms.cicd.replicate = "1m"' "${COMMENT_FIXTURE}/config.yaml"
comment_tmp="${COMMENT_FIXTURE}/config.yaml.tmp"
awk '
  !inserted && $0 ~ /^    replicate: "?1m"?$/ {
    print "    # ratified 2026-07-21 — reason: MR-2 test fixture"
    inserted = 1
  }
  { print }
' "${COMMENT_FIXTURE}/config.yaml" > "$comment_tmp"
mv "$comment_tmp" "${COMMENT_FIXTURE}/config.yaml"
if grep -Fq "ratified 2026-07-21" "${COMMENT_FIXTURE}/config.yaml"; then
  assert_validator_ok "$COMMENT_FIXTURE" "ratified comment above replicate line passes"
else
  test_fail "ratified comment fixture was not constructed"
  sed 's/^/    /' "${COMMENT_FIXTURE}/config.yaml" >&2
fi

test_start "8" "replicate_override metadata block is legal but ignored"
make_fixture OVERRIDE_FIXTURE
"${REAL_YQ}" -i '
  .vms.cicd.replicate_override = {
    "ratified_by": "ops",
    "ratified_on": "2026-07-21",
    "reason": "MR-2 validator fixture"
  }
' "${OVERRIDE_FIXTURE}/config.yaml"
"${REAL_YQ}" -i '
  .applications.grafana.replicate_override = {
    "ratified_by": "ops",
    "ratified_on": "2026-07-21",
    "reason": "MR-2 validator fixture"
  }
' "${OVERRIDE_FIXTURE}/applications.yaml"
assert_validator_ok "$OVERRIDE_FIXTURE" "replicate_override blocks do not add schema requirements"

test_start "9" "enabled VM missing from helper output is rejected"
make_fixture MISSING_HELPER_FIXTURE
helper_rows="${MISSING_HELPER_FIXTURE}/helper-rows.tsv"
LIST_REPLICATED_VMIDS_CONFIG="${MISSING_HELPER_FIXTURE}/config.yaml" \
LIST_REPLICATED_VMIDS_APPS_CONFIG="${MISSING_HELPER_FIXTURE}/applications.yaml" \
  "${REPO_ROOT}/framework/scripts/list-replicated-vmids.sh" --format tsv --mode all all \
    2>"${MISSING_HELPER_FIXTURE}/helper-warnings.txt" |
  awk -F '\t' '$1 != "160"' > "$helper_rows"
stub_helper="${MISSING_HELPER_FIXTURE}/list-replicated-vmids.sh"
cat > "$stub_helper" <<EOF
#!/usr/bin/env bash
cat "$helper_rows"
EOF
chmod +x "$stub_helper"
run_validator "$MISSING_HELPER_FIXTURE" "$stub_helper"
if [[ "$(cat "${MISSING_HELPER_FIXTURE}/exit.txt")" -ne 0 ]] &&
   grep -q 'vms.cicd vmid 160 is missing' "${MISSING_HELPER_FIXTURE}/output.txt"; then
  test_pass "validator rejects helper output missing an enabled VM"
else
  test_fail "validator did not reject helper output missing an enabled VM"
  sed 's/^/    /' "${MISSING_HELPER_FIXTURE}/output.txt" >&2
fi

assert_validator_fails_with_text() {
  local fixture="$1"
  local needle="$2"
  local label="$3"

  run_validator "$fixture"
  if [[ "$(cat "${fixture}/exit.txt")" -ne 0 ]] &&
     grep -Fq "$needle" "${fixture}/output.txt"; then
    test_pass "$label"
  else
    test_fail "$label"
    sed 's/^/    /' "${fixture}/output.txt" >&2
  fi
}

# --- #731: canonical-boolean validation for the remaining boolean flags ---
#
# #295 established that a boolean flag consumed by a literal `== "true"` shell
# compare must be rejected when it is not canonical `true`/`false`, because a
# non-canonical value reads as not-true and fails closed with no error. These
# tests extend that coverage to every remaining boolean flag the validator
# reads, and pin the shared message wording so the five sites cannot drift
# apart again (the drift that produced this issue).

test_start "10" "#731: canonical boolean values remain accepted for every guarded flag"
while IFS=$'\t' read -r label expr file; do
  [[ -z "$label" ]] && continue
  make_fixture CANON_FIXTURE
  "${REAL_YQ}" -i "$expr" "${CANON_FIXTURE}/${file}"
  assert_validator_ok "$CANON_FIXTURE" "#731 accepts ${label}"
done <<'EOF'
environments.dev.vdb_park_bridge=true	.environments.dev.vdb_park_bridge = true	config.yaml
environments.dev.vdb_park_bridge=false	.environments.dev.vdb_park_bridge = false	config.yaml
environments.prod.vdb_park_bridge=false	.environments.prod.vdb_park_bridge = false	config.yaml
vms.hil_boot.backup=false	.vms.hil_boot.backup = false	config.yaml
nodes[0].regreen_enabled=false	.nodes[0].regreen_enabled = false	config.yaml
benchmarks.scheduled.enabled=false	.benchmarks.scheduled.enabled = false	config.yaml
publish.github.enabled=false	.publish.github.enabled = false	config.yaml
EOF

test_start "11" "#731: non-canonical boolean values are rejected with the standardized message"
# Each row mutates one flag to a value that renders as neither "true" nor
# "false" through `yq -r`. Every consumer of these flags compares the rendered
# text against the literal "true" (install-pve-node.sh:363,
# regreen-cluster.sh:151, vdb-park-lib.sh:113), so without the guard each of
# these silently reads as not-true and the run exits 0.
while IFS=$'\t' read -r label expr needle; do
  [[ -z "$label" ]] && continue
  make_fixture BAD_BOOL_FIXTURE
  "${REAL_YQ}" -i "$expr" "${BAD_BOOL_FIXTURE}/config.yaml"
  assert_validator_fails_with_text "$BAD_BOOL_FIXTURE" "$needle" \
    "#731 rejects ${label}"
done <<'EOF'
environments.dev.vdb_park_bridge="True"	.environments.dev.vdb_park_bridge = "True"	environments.dev.vdb_park_bridge must be a boolean (got 'True', expected true or false)
environments.dev.vdb_park_bridge="yes"	.environments.dev.vdb_park_bridge = "yes"	environments.dev.vdb_park_bridge must be a boolean (got 'yes', expected true or false)
environments.prod.vdb_park_bridge="1"	.environments.prod.vdb_park_bridge = "1"	environments.prod.vdb_park_bridge must be a boolean (got '1', expected true or false)
vms.hil_boot.backup="True"	.vms.hil_boot.backup = "True"	vms.hil_boot.backup must be a boolean (got 'True', expected true or false)
vms.hil_boot.backup="tru"	.vms.hil_boot.backup = "tru"	vms.hil_boot.backup must be a boolean (got 'tru', expected true or false)
nodes[0].regreen_enabled="True"	.nodes[0].regreen_enabled = "True"	regreen_enabled must be a boolean (got 'True', expected true or false)
nodes[0].regreen_enabled="yes"	.nodes[0].regreen_enabled = "yes"	regreen_enabled must be a boolean (got 'yes', expected true or false)
benchmarks.scheduled.enabled="yes"	.benchmarks.scheduled.enabled = "yes"	benchmarks.scheduled.enabled must be a boolean (got 'yes', expected true or false)
publish.github.enabled="Yes"	.publish.github.enabled = "Yes"	publish.github.enabled must be a boolean (got 'Yes', expected true or false)
EOF

test_start "12" "#731: bare YAML True is rejected even though YAML tags it !!bool"
# The guard deliberately checks the RENDERED TEXT rather than the YAML tag.
# `yq` parses a bare `True` as !!bool but renders it as "True", which no
# consumer's `== "true"` compare matches. A tag-based check would pass this
# fixture and leave the silent-not-true defect in place.
make_fixture YAML_TRUE_FIXTURE
sed -i.bak 's/^\( *vdb_park_bridge:\) *true/\1 True/' "${YAML_TRUE_FIXTURE}/config.yaml"
rm -f "${YAML_TRUE_FIXTURE}/config.yaml.bak"
if [[ "$("${REAL_YQ}" -r '.environments.dev.vdb_park_bridge | tag' "${YAML_TRUE_FIXTURE}/config.yaml")" == "!!bool" ]] &&
   [[ "$("${REAL_YQ}" -r '.environments.dev.vdb_park_bridge' "${YAML_TRUE_FIXTURE}/config.yaml")" == "True" ]]; then
  assert_validator_fails_with_text "$YAML_TRUE_FIXTURE" \
    "environments.dev.vdb_park_bridge must be a boolean (got 'True', expected true or false)" \
    "#731 rejects bare YAML True (bool-tagged, non-canonically rendered)"
else
  test_fail "#731 bare-YAML-True fixture was not constructed"
  "${REAL_YQ}" -r '.environments.dev' "${YAML_TRUE_FIXTURE}/config.yaml" >&2
fi

test_start "13" "#731: a non-canonical regreen_enabled does not silently skip node field checks"
# Before #731 a non-canonical regreen_enabled read as not-true, so the five
# required-field checks below it (amt_ip, amt_user, amt_password_ref,
# install_nic_driver, install_disk_id_path) were skipped in silence and the
# validator exited 0 on a node the operator believed was regreen-enabled.
make_fixture REGREEN_SKIP_FIXTURE
"${REAL_YQ}" -i '.nodes[0].regreen_enabled = "True"' "${REGREEN_SKIP_FIXTURE}/config.yaml"
run_validator "$REGREEN_SKIP_FIXTURE"
if [[ "$(cat "${REGREEN_SKIP_FIXTURE}/exit.txt")" -ne 0 ]] &&
   grep -Fq "regreen_enabled must be a boolean" "${REGREEN_SKIP_FIXTURE}/output.txt" &&
   ! grep -Fq "amt_ip" "${REGREEN_SKIP_FIXTURE}/output.txt"; then
  # The guard reports the uninterpretable flag and stops evaluating the
  # checks that depend on it, rather than reporting them as satisfied.
  test_pass "#731 non-canonical regreen_enabled fails closed without asserting the dependent checks passed"
else
  test_fail "#731 non-canonical regreen_enabled did not fail closed"
  sed 's/^/    /' "${REGREEN_SKIP_FIXTURE}/output.txt" >&2
fi

runner_summary
