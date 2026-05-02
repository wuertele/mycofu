#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
LOG_FILE="${TMP_DIR}/safe-apply.log"
APPROLE_LOG_FILE="${TMP_DIR}/approle.log"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"

mkdir -p "${FIXTURE_REPO}/framework/scripts" "${FIXTURE_REPO}/framework/tofu/root" "${SHIM_DIR}"

cp "${REPO_ROOT}/framework/scripts/safe-apply.sh" "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"
chmod +x "${FIXTURE_REPO}/framework/scripts/safe-apply.sh"

cat > "${FIXTURE_REPO}/framework/scripts/check-control-plane-drift.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/check-control-plane-drift.sh"

cat > "${FIXTURE_REPO}/framework/scripts/check-approle-creds.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'check-approle-creds\n' >> "${APPROLE_LOG_FILE}"
exit "${STUB_APPROLE_EXIT:-0}"
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/check-approle-creds.sh"

# Stub preboot restore and post-success convergence scripts. Default behavior:
# log invocation and exit 0. test_safe_apply_recovery.sh exercises failure-path
# semantics in a separate fixture.
for recovery_script in restore-before-start.sh configure-replication.sh post-deploy.sh; do
  cat > "${FIXTURE_REPO}/framework/scripts/${recovery_script}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '${recovery_script} %s\n' "\$*" >> "${LOG_FILE}.recovery"
exit 0
EOF
  chmod +x "${FIXTURE_REPO}/framework/scripts/${recovery_script}"
done

cat > "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "${STUB_LOG_FILE}"

case "${1:-}" in
  plan)
    for arg in "$@"; do
      if [[ "${arg}" == -out=* ]]; then
        : > "${arg#-out=}"
      fi
    done
    exit 0
    ;;
  apply)
    exit 0
    ;;
  init)
    exit 0
    ;;
  state)
    case "${2:-}" in
      list)
        # Return empty — no HA resources in state (clean fixture)
        exit 0
        ;;
      show|rm)
        exit 0
        ;;
    esac
    ;;
esac

echo "unexpected tofu-wrapper invocation: $*" >&2
exit 2
EOF
chmod +x "${FIXTURE_REPO}/framework/scripts/tofu-wrapper.sh"

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == -chdir=* ]]; then
  shift
fi

if [[ "${1:-}" == "show" && "${2:-}" == "-json" ]]; then
  printf '%s' "${STUB_PLAN_JSON}"
  exit 0
fi

echo "unexpected tofu invocation: $*" >&2
exit 2
EOF
chmod +x "${SHIM_DIR}/tofu"

# SSH shim — verify_ha_resources calls ssh to query Proxmox
cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
# Return empty HA resource list (clean state, no stale entries)
echo '[]'
exit 0
EOF
chmod +x "${SHIM_DIR}/ssh"

# Fixture config.yaml for verify_ha_resources (needs nodes[0].mgmt_ip)
mkdir -p "${FIXTURE_REPO}/site"
cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
EOF

export PATH="${SHIM_DIR}:${PATH}"
export STUB_LOG_FILE="${LOG_FILE}"
export APPROLE_LOG_FILE="${APPROLE_LOG_FILE}"
export STUB_APPROLE_EXIT=0
export STUB_PLAN_JSON='{"resource_changes":[
  {"address":"module.testapp_dev.module.testapp.proxmox_virtual_environment_vm.vm","change":{"actions":["create"]}},
  {"address":"module.influxdb_dev[0].module.influxdb.proxmox_virtual_environment_haresource.ha[0]","change":{"actions":["update"]}},
  {"address":"module.vault_prod.module.vault.proxmox_virtual_environment_vm.vm","change":{"actions":["create"]}}
]}'

count_lines() {
  local pattern="$1"
  local file="$2"
  local matches
  matches="$(grep "${pattern}" "${file}" 2>/dev/null || true)"
  printf '%s\n' "${matches}" | sed '/^$/d' | wc -l | tr -d ' '
}

line_at() {
  local pattern="$1"
  local file="$2"
  local index="$3"
  local matches
  matches="$(grep "${pattern}" "${file}" 2>/dev/null || true)"
  printf '%s\n' "${matches}" | sed -n "${index}p"
}

matching_lines() {
  local pattern="$1"
  local file="$2"
  grep "${pattern}" "${file}" 2>/dev/null || true
}

set +e
OUTPUT="$(
  cd "${FIXTURE_REPO}" &&
  framework/scripts/safe-apply.sh dev 2>&1
)"
STATUS=$?
set -e

test_start "2.4" "safe-apply.sh runs successfully with the HA shim fixture"
if [[ "${STATUS}" -eq 0 ]]; then
  test_pass "safe-apply fixture run exited 0"
else
  test_fail "safe-apply fixture run exited 0"
  printf '    output:\n%s\n' "${OUTPUT}" >&2
fi

EXPECTED_TARGETS='-target=module.influxdb_dev -target=module.testapp_dev'
APPLY_COUNT="$(count_lines '^apply ' "${LOG_FILE}")"
PLAN_COUNT="$(count_lines '^plan ' "${LOG_FILE}")"
REFRESH_COUNT="$(count_lines '^refresh ' "${LOG_FILE}")"
FIRST_APPLY_LINE="$(line_at '^apply ' "${LOG_FILE}" 1)"
SECOND_APPLY_LINE="$(line_at '^apply ' "${LOG_FILE}" 2)"
PLAN_LINE="$(line_at '^plan ' "${LOG_FILE}" 1)"

test_start "2.5" "no third apply occurs and exactly two apply calls remain"
if [[ "${APPLY_COUNT}" == "2" ]]; then
  test_pass "safe-apply performs exactly two apply calls"
else
  test_fail "safe-apply performs exactly two apply calls"
  printf '    apply log:\n%s\n' "$(matching_lines '^apply ' "${LOG_FILE}")" >&2
fi

test_start "2.6" "both applies reuse the same target set"
EXPECTED_FIRST_APPLY_LINE="apply ${EXPECTED_TARGETS} -var=start_vms=false -var=register_ha=false -auto-approve"
EXPECTED_SECOND_APPLY_LINE="apply ${EXPECTED_TARGETS} -var=start_vms=true -var=register_ha=true -auto-approve"
if [[ "${APPLY_COUNT}" == "2" ]] \
  && [[ "${FIRST_APPLY_LINE}" == "${EXPECTED_FIRST_APPLY_LINE}" ]] \
  && [[ "${SECOND_APPLY_LINE}" == "${EXPECTED_SECOND_APPLY_LINE}" ]]; then
  test_pass "safe-apply reuses the same targets for both apply passes"
else
  test_fail "safe-apply reuses the same targets for both apply passes"
  printf '    apply log:\n%s\n' "$(matching_lines '^apply ' "${LOG_FILE}")" >&2
fi

test_start "2.7" "the standalone refresh call is absent"
if [[ "${REFRESH_COUNT}" == "0" ]]; then
  test_pass "safe-apply does not run a standalone refresh"
else
  test_fail "safe-apply does not run a standalone refresh"
  printf '    refresh log:\n%s\n' "$(matching_lines '^refresh ' "${LOG_FILE}")" >&2
fi

test_start "2.8" "the initial plan still drives target selection"
# safe-apply.sh now uses mktemp -d for tmpfiles to avoid concurrent-run
# collisions (codex P2.2 / #224), so the -out= path is no longer a fixed
# /tmp/safe-apply-plan.out. Match by prefix and suffix instead.
EXPECTED_PLAN_PREFIX='plan -exclude=module.gitlab -exclude=module.cicd -exclude=module.pbs -out='
EXPECTED_PLAN_SUFFIX='/plan.out -no-color'
if [[ "${PLAN_COUNT}" == "1" \
  && "${PLAN_LINE}" == "${EXPECTED_PLAN_PREFIX}"*"${EXPECTED_PLAN_SUFFIX}" ]]; then
  test_pass "safe-apply still performs the excluded control-plane plan"
else
  test_fail "safe-apply still performs the excluded control-plane plan"
  printf '    plan log:\n%s\n' "$(matching_lines '^plan ' "${LOG_FILE}")" >&2
fi

: > "${LOG_FILE}"
: > "${APPROLE_LOG_FILE}"
export STUB_APPROLE_EXIT=1

set +e
IGNORE_OUTPUT="$(
  cd "${FIXTURE_REPO}" &&
  framework/scripts/safe-apply.sh dev --ignore-approle-creds 2>&1
)"
IGNORE_STATUS=$?
set -e

test_start "2.9" "the AppRole escape hatch skips the preflight and still deploys"
IGNORE_APPLY_COUNT="$(count_lines '^apply ' "${LOG_FILE}")"
IGNORE_APPROLE_COUNT="$(count_lines '^check-approle-creds$' "${APPROLE_LOG_FILE}")"
if [[ "${IGNORE_STATUS}" -eq 0 ]] && \
   grep -Fq 'Skipping AppRole credential preflight due to --ignore-approle-creds' <<< "${IGNORE_OUTPUT}" && \
   [[ "${IGNORE_APPLY_COUNT}" == "2" ]] && \
   [[ "${IGNORE_APPROLE_COUNT}" == "0" ]]; then
  test_pass "safe-apply bypasses the AppRole preflight only when explicitly told to"
else
  test_fail "safe-apply bypasses the AppRole preflight only when explicitly told to"
  printf '    output:\n%s\n' "${IGNORE_OUTPUT}" >&2
fi

test_start "2.10" "prod deploy keeps the cert-budget gate ahead of safe-apply"
CERT_BUDGET_LINE="$(grep -Fn 'framework/scripts/check-cert-budget.sh prod' "${CI_FILE}" | head -1 | cut -d: -f1 || true)"
SAFE_APPLY_LINE="$(grep -Fn 'framework/scripts/safe-apply.sh prod' "${CI_FILE}" | head -1 | cut -d: -f1 || true)"
if [[ -n "${CERT_BUDGET_LINE}" && -n "${SAFE_APPLY_LINE}" && "${SAFE_APPLY_LINE}" -gt "${CERT_BUDGET_LINE}" ]]; then
  test_pass "prod deploy still gates safe-apply behind the cert-budget preflight"
else
  test_fail "prod deploy must run the cert-budget preflight before safe-apply"
fi

runner_summary
