#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
REPO_ROOT="${PARITY_REPO_ROOT:-${DEFAULT_REPO_ROOT}}"

source "${DEFAULT_REPO_ROOT}/tests/lib/runner.sh"

PARITY_SCRIPTS=(
  configure-replication.sh
  configure-vault.sh
  configure-backups.sh
  configure-dashboard-tokens.sh
  cert-storage-backfill.sh
  deploy-workstation-closure.sh
)

PIPELINE_ONLY_SCRIPTS=(
  backup-now.sh
  safe-apply.sh
  restore-before-start.sh
  post-deploy.sh
  tofu-wrapper.sh
  ensure-app-secrets.sh
  check-cert-budget.sh
  check-approle-creds.sh
  check-control-plane-drift.sh
)

parity_step_for() {
  case "$1" in
    configure-replication.sh) printf '%s\n' "converge_step_replication" ;;
    configure-vault.sh) printf '%s\n' "converge_step_vault" ;;
    configure-backups.sh) printf '%s\n' "converge_step_backups" ;;
    configure-dashboard-tokens.sh) printf '%s\n' "converge_step_dashboard_tokens" ;;
    cert-storage-backfill.sh) printf '%s\n' "converge_step_cert_backfill" ;;
    deploy-workstation-closure.sh) printf '%s\n' "converge_step_workstation_closure" ;;
    *) return 1 ;;
  esac
}

pipeline_only_reason_for() {
  case "$1" in
    # Creates a restore pin before deployment; workstation rebuilds receive
    # pins through rebuild-cluster.sh --restore-pin-file.
    backup-now.sh) printf '%s\n' "pre-deploy backup orchestration" ;;

    # Applies OpenTofu with repository safety checks, runs preboot restore
    # between the stopped and start applies, then runs post-success
    # convergence. Workstation convergence uses
    # rebuild-cluster.sh/converge-vm.sh instead of this pipeline wrapper.
    # Its transitive script calls are parsed separately below.
    safe-apply.sh) printf '%s\n' "pipeline apply wrapper" ;;

    # Restores recreated precious-state VMs from the pipeline backup pin
    # before Phase 2 starts and registers them.
    restore-before-start.sh) printf '%s\n' "pipeline preboot restore orchestration" ;;

    # Pipeline wrapper around Vault/dashboard/backup hooks. Its transitive
    # script calls are parsed separately below.
    post-deploy.sh) printf '%s\n' "pipeline post-deploy orchestrator" ;;

    # OpenTofu CLI guard used by pipeline deploy jobs before safe apply.
    tofu-wrapper.sh) printf '%s\n' "pipeline OpenTofu wrapper" ;;

    # Ensures app secrets exist before apply; not an end-state convergence hook.
    ensure-app-secrets.sh) printf '%s\n' "pre-apply secret prerequisite" ;;

    # Prod preflight gate. It observes ACME quota and does not converge state.
    check-cert-budget.sh) printf '%s\n' "validation/preflight gate" ;;

    # Pre-apply guard invoked by safe-apply.sh that ensures every Vault AppRole
    # consumer has matching credentials in SOPS before tofu apply. Read-only
    # preflight; not a converge step.
    check-approle-creds.sh) printf '%s\n' "pre-apply AppRole credential preflight" ;;

    # Pre-apply guard invoked by safe-apply.sh that compares the flake's
    # control-plane closures against deployed control-plane VMs. Read-only
    # drift detector; not a converge step.
    check-control-plane-drift.sh) printf '%s\n' "pre-apply control-plane drift preflight" ;;
    *) return 1 ;;
  esac
}

extract_ci_job_block() {
  local job_name="$1"
  awk -v job="${job_name}:" '
    $0 == job { in_job=1; next }
    in_job && /^[A-Za-z0-9_.:-]+:[[:space:]]*$/ { exit }
    in_job { print }
  ' "${REPO_ROOT}/.gitlab-ci.yml"
}

extract_framework_script_invocations() {
  sed 's/#.*//' |
    grep -Eo 'framework/scripts/[A-Za-z0-9_.-]+\.sh' |
    sed 's#framework/scripts/##' |
    sort -u
}

extract_post_deploy_invocations() {
  sed 's/#.*//' "${REPO_ROOT}/framework/scripts/post-deploy.sh" |
    grep -Ev '^[[:space:]]*echo[[:space:]]' |
    grep -E 'SCRIPT_DIR|framework/scripts/' |
    grep -Eo '[A-Za-z0-9_.-]+\.sh' |
    sort -u
}

extract_safe_apply_invocations() {
  sed 's/#.*//' "${REPO_ROOT}/framework/scripts/safe-apply.sh" |
    grep -Ev '^[[:space:]]*echo[[:space:]]' |
    grep -E 'SCRIPT_DIR|framework/scripts/' |
    grep -Eo '[A-Za-z0-9_.-]+\.sh' |
    sort -u
}

extract_converge_run_all_steps() {
  awk '
    /^converge_run_all\(\)/ { in_fn=1; next }
    in_fn && /^}/ { exit }
    in_fn && /^[[:space:]]*converge_step_/ {
      gsub(/^[[:space:]]+/, "", $0)
      print $1
    }
  ' "${REPO_ROOT}/framework/scripts/converge-lib.sh"
}

mark_referenced_parity() {
  local script="$1"

  REFERENCED_PARITY="${REFERENCED_PARITY} ${script} "
}

parity_was_referenced() {
  local script="$1"

  [[ "${REFERENCED_PARITY}" == *" ${script} "* ]]
}

assert_invocation_classified() {
  local script="$1"
  local source_label="$2"
  local step=""
  local reason=""

  if step="$(parity_step_for "${script}")"; then
    if grep -qx "${step}" <<< "${RUN_ALL_STEPS}"; then
      test_pass "${source_label} calls ${script}; converge_run_all includes ${step}"
    else
      test_fail "Pipeline calls ${script} but converge_run_all has no ${step}"
    fi
    mark_referenced_parity "${script}"
    return 0
  fi

  if reason="$(pipeline_only_reason_for "${script}")"; then
    test_pass "${source_label} calls pipeline-only ${script}: ${reason}"
    return 0
  fi

  test_fail "Pipeline invocation '${script}' is in neither PARITY_MAPPING nor PIPELINE_ONLY_ALLOWLIST. Add it to one or the other (and explain WHY in the allowlist reason if pipeline-only)."
}

position_of_step() {
  local step="$1"
  local pos=""

  pos="$(grep -n "^${step}$" <<< "${RUN_ALL_STEPS}" | head -1 | cut -d: -f1 || true)"
  printf '%s\n' "${pos}"
}

assert_order_after() {
  local step="$1"
  local dependency="$2"
  local step_pos dep_pos

  step_pos="$(position_of_step "${step}")"
  dep_pos="$(position_of_step "${dependency}")"
  if [[ -n "${step_pos}" && -n "${dep_pos}" && "${step_pos}" -gt "${dep_pos}" ]]; then
    test_pass "${step} runs after ${dependency}"
  else
    test_fail "${step} runs after ${dependency}"
    printf '    converge_run_all steps:\n%s\n' "${RUN_ALL_STEPS}" >&2
  fi
}

RUN_ALL_STEPS="$(extract_converge_run_all_steps)"
REFERENCED_PARITY=" "

test_start "C1" "deploy:dev/deploy:prod framework script invocations are classified"
for job_name in deploy:dev deploy:prod; do
  while IFS= read -r script; do
    [[ -z "${script}" ]] && continue
    assert_invocation_classified "${script}" "${job_name}"
  done < <(extract_ci_job_block "${job_name}" | extract_framework_script_invocations)
done

test_start "C2" "post-deploy.sh and safe-apply.sh transitive script invocations are classified"
while IFS= read -r script; do
  [[ -z "${script}" ]] && continue
  assert_invocation_classified "${script}" "post-deploy.sh"
done < <(extract_post_deploy_invocations)
while IFS= read -r script; do
  [[ -z "${script}" ]] && continue
  # safe-apply.sh references itself in its --help text and as ${SCRIPT_DIR}/safe-apply
  # comments; skip to avoid recursive classification.
  [[ "${script}" == "safe-apply.sh" ]] && continue
  assert_invocation_classified "${script}" "safe-apply.sh"
done < <(extract_safe_apply_invocations)

test_start "C3" "converge_run_all ordering invariants"
assert_order_after "converge_step_cert_backfill" "converge_step_vault"
assert_order_after "converge_step_cert_backfill" "converge_step_certs"
assert_order_after "converge_step_dashboard_tokens" "converge_step_vault"
assert_order_after "converge_step_dashboard_tokens" "converge_step_metrics"
assert_order_after "converge_step_workstation_closure" "converge_step_metrics"
assert_order_after "converge_step_workstation_closure" "converge_step_dashboard_tokens"

test_start "C4" "PARITY_MAPPING entries are referenced by pipeline or post-deploy"
for script in "${PARITY_SCRIPTS[@]}"; do
  if parity_was_referenced "${script}"; then
    test_pass "PARITY_MAPPING entry for ${script} has a matching invocation"
  else
    test_fail "PARITY_MAPPING entry for ${script} has no pipeline invocation; remove the entry or restore the pipeline call"
  fi
done

test_start "C5" "PIPELINE_ONLY_ALLOWLIST entries have reason strings"
for script in "${PIPELINE_ONLY_SCRIPTS[@]}"; do
  reason="$(pipeline_only_reason_for "${script}" || true)"
  if [[ -n "${reason}" ]]; then
    test_pass "PIPELINE_ONLY_ALLOWLIST entry for ${script} has a reason"
  else
    test_fail "PIPELINE_ONLY_ALLOWLIST entry for ${script} has an empty reason"
  fi
done

test_start "C6" "classification arrays match lookup functions"
for script in "${PARITY_SCRIPTS[@]}"; do
  step="$(parity_step_for "${script}" || true)"
  if [[ -n "${step}" ]]; then
    test_pass "PARITY_MAPPING lookup returns a step for ${script}"
  else
    test_fail "PARITY_MAPPING array entry ${script} has no parity_step_for case"
  fi
done
for script in "${PIPELINE_ONLY_SCRIPTS[@]}"; do
  reason="$(pipeline_only_reason_for "${script}" || true)"
  if [[ -n "${reason}" ]]; then
    test_pass "PIPELINE_ONLY_ALLOWLIST lookup returns a reason for ${script}"
  else
    test_fail "PIPELINE_ONLY_ALLOWLIST array entry ${script} has no pipeline_only_reason_for case"
  fi
done

runner_summary
