#!/usr/bin/env bash
# git-deploy-context.sh -- Shared git/scope safety helpers for rebuild-cluster.sh.

# This file is sourced by rebuild-cluster.sh and by non-destructive tests.
# It intentionally avoids side effects at load time.

if [[ -z "${GIT_DEPLOY_GIT_BIN:-}" ]]; then
  GIT_DEPLOY_GIT_BIN="git"
fi
if [[ -z "${GIT_DEPLOY_YQ_BIN:-}" ]]; then
  GIT_DEPLOY_YQ_BIN="yq"
fi
if [[ -z "${GIT_DEPLOY_JQ_BIN:-}" ]]; then
  GIT_DEPLOY_JQ_BIN="jq"
fi
if [[ -z "${GIT_DEPLOY_PYTHON_BIN:-}" ]]; then
  GIT_DEPLOY_PYTHON_BIN="python3"
fi
if [[ -z "${GIT_DEPLOY_SSH_BIN:-}" ]]; then
  GIT_DEPLOY_SSH_BIN="ssh"
fi
if [[ -z "${GIT_DEPLOY_TOFU_WRAPPER_BIN:-}" ]]; then
  if [[ -n "${SCRIPT_DIR:-}" ]]; then
    GIT_DEPLOY_TOFU_WRAPPER_BIN="${SCRIPT_DIR}/tofu-wrapper.sh"
  else
    GIT_DEPLOY_TOFU_WRAPPER_BIN="tofu-wrapper.sh"
  fi
fi
if [[ -z "${REBUILD_COMMAND_NAME:-}" ]]; then
  REBUILD_COMMAND_NAME="framework/scripts/rebuild-cluster.sh"
fi

_gdc_join_by() {
  local delimiter="$1"
  shift
  local out=""
  local item
  for item in "$@"; do
    [[ -z "$item" ]] && continue
    if [[ -n "$out" ]]; then
      out+="${delimiter}"
    fi
    out+="${item}"
  done
  printf '%s\n' "$out"
}

_gdc_scope_label() {
  if [[ -n "${SCOPE:-}" ]]; then
    printf '%s\n' "$SCOPE"
  else
    printf 'full-cluster\n'
  fi
}

_gdc_branch_label() {
  if [[ "${GIT_DETACHED:-0}" -eq 1 ]]; then
    printf 'detached HEAD\n'
  else
    printf '%s\n' "${GIT_BRANCH:-unknown}"
  fi
}

_gdc_rebuild_command() {
  local cmd="${REBUILD_COMMAND_NAME}"
  if [[ -n "${SCOPE:-}" ]]; then
    cmd+=" --scope ${SCOPE}"
  fi
  if [[ "${ALLOW_DIRTY:-0}" -eq 1 ]]; then
    cmd+=" --allow-dirty"
  fi
  printf '%s\n' "$cmd"
}

_gdc_push_source_ref() {
  if [[ "${GIT_DETACHED:-0}" -eq 1 ]]; then
    printf 'HEAD\n'
  else
    printf '%s\n' "${GIT_BRANCH:-HEAD}"
  fi
}

_gdc_known_modules() {
  local search_paths=()
  if [[ -d "${REPO_DIR}/framework/tofu/root" ]]; then
    search_paths+=("${REPO_DIR}/framework/tofu/root")
  fi
  if [[ -d "${REPO_DIR}/site/tofu" ]]; then
    search_paths+=("${REPO_DIR}/site/tofu")
  fi

  if [[ "${#search_paths[@]}" -eq 0 ]]; then
    return 0
  fi

  grep -Rho 'module "[^"]\+"' "${search_paths[@]}" 2>/dev/null \
    | sed 's/^module "//; s/"$//' \
    | sort -u
}

_gdc_module_exists() {
  local target="$1"
  if [[ -z "${KNOWN_SCOPE_MODULES_CACHE:-}" ]]; then
    KNOWN_SCOPE_MODULES_CACHE="$(_gdc_known_modules)"
  fi
  printf '%s\n' "${KNOWN_SCOPE_MODULES_CACHE}" | grep -Fxq "$target"
}

_gdc_human_fetch_detail() {
  local detail="$1"
  if printf '%s' "$detail" | grep -Eqi 'timed out|operation timed out|connection timed out'; then
    printf 'ssh timeout after 5s\n'
    return 0
  fi
  if printf '%s' "$detail" | grep -qi 'No such remote'; then
    printf 'git remote "gitlab" is not configured\n'
    return 0
  fi
  detail="$(printf '%s' "$detail" | awk 'NF { print; exit }')"
  if [[ -z "$detail" ]]; then
    printf 'git fetch gitlab failed\n'
  else
    printf '%s\n' "$detail"
  fi
}

_gdc_pbs_output_matches_configured_vmid() {
  local pbs_output_file="$1"
  shift

  "${GIT_DEPLOY_PYTHON_BIN}" - "${pbs_output_file}" "$@" <<'PY'
import json
import re
import sys

pbs_output_file = sys.argv[1]
vmids = sys.argv[2:]

try:
    with open(pbs_output_file, encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    sys.exit(2)

if not isinstance(payload, list):
    sys.exit(2)

patterns = [
    (vmid, re.compile(r"(^|[^0-9])" + re.escape(vmid) + r"([^0-9]|$)"))
    for vmid in vmids
]

for entry in payload:
    if not isinstance(entry, dict):
        continue
    volid = str(entry.get("volid", ""))
    for vmid, pattern in patterns:
        if pattern.search(volid):
            print(vmid)
            sys.exit(0)

sys.exit(1)
PY
}

scope_requires_prod_branch() {
  case "${SCOPE_IMPACT:-}" in
    prod_affecting|shared_control_plane) return 0 ;;
    *) return 1 ;;
  esac
}

should_skip_gitlab_handoff() {
  [[ "${OVERRIDE_BRANCH_CHECK:-0}" -eq 1 ]] && scope_requires_prod_branch
}

resolve_git_context() {
  GIT_BRANCH=""
  GIT_DETACHED=0
  GIT_COMMIT=""
  GIT_COMMIT_SHORT=""
  GIT_SUBJECT=""
  GIT_DATE=""
  GIT_TREE_STATE="clean"

  if GIT_BRANCH="$("${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" symbolic-ref --quiet --short HEAD 2>/dev/null)"; then
    GIT_DETACHED=0
  else
    GIT_DETACHED=1
    GIT_BRANCH="detached HEAD"
  fi

  GIT_COMMIT="$("${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" rev-parse HEAD)"
  GIT_COMMIT_SHORT="$("${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" rev-parse --short=8 HEAD)"
  GIT_SUBJECT="$("${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" log -1 --format=%s HEAD)"
  GIT_DATE="$("${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" log -1 --format=%cI HEAD)"

  set +e
  "${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" diff --quiet HEAD -- ':!site/sops/secrets.yaml' 2>/dev/null
  local diff_exit=$?
  set -e
  if [[ "$diff_exit" -ne 0 ]]; then
    GIT_TREE_STATE="dirty"
  fi
}

classify_scope_impact() {
  SCOPE_IMPACT=""
  SCOPE_IMPACT_REASON=""
  SCOPE_UNKNOWN_TARGETS=""
  KNOWN_SCOPE_MODULES_CACHE=""

  case "${SCOPE:-}" in
    "")
      SCOPE_IMPACT="prod_affecting"
      SCOPE_IMPACT_REASON="full rebuilds always touch prod-affecting VMs"
      return 0
      ;;
    control-plane)
      SCOPE_IMPACT="shared_control_plane"
      SCOPE_IMPACT_REASON="control-plane scope targets shared VMs: gitlab, cicd, pbs"
      return 0
      ;;
    data-plane)
      SCOPE_IMPACT="prod_affecting"
      SCOPE_IMPACT_REASON="data-plane scope includes prod data-plane VMs"
      return 0
      ;;
    vm=*)
      ;;
    *)
      SCOPE_UNKNOWN_TARGETS="${SCOPE:-unknown}"
      SCOPE_IMPACT_REASON="scope format is not recognized"
      return 1
      ;;
  esac

  local raw_targets="${SCOPE#vm=}"
  local targets=()
  IFS=',' read -r -a targets <<< "$raw_targets"

  local dev_targets=()
  local prod_targets=()
  local shared_targets=()
  local unknown_targets=()
  local target
  for target in "${targets[@]}"; do
    [[ -z "$target" ]] && continue
    if ! _gdc_module_exists "$target"; then
      unknown_targets+=("$target")
      continue
    fi
    case "$target" in
      *_dev|acme_dev)
        dev_targets+=("$target")
        ;;
      *_prod|gatus)
        prod_targets+=("$target")
        ;;
      gitlab|cicd|pbs)
        shared_targets+=("$target")
        ;;
      *)
        unknown_targets+=("$target")
        ;;
    esac
  done

  if [[ "${#targets[@]}" -eq 0 || ( "${#dev_targets[@]}" -eq 0 && "${#prod_targets[@]}" -eq 0 && "${#shared_targets[@]}" -eq 0 && "${#unknown_targets[@]}" -eq 0 ) ]]; then
    SCOPE_UNKNOWN_TARGETS="(empty vm= scope)"
    SCOPE_IMPACT_REASON="vm= scope must list at least one module name"
    return 1
  fi

  if [[ "${#unknown_targets[@]}" -gt 0 ]]; then
    SCOPE_UNKNOWN_TARGETS="$(_gdc_join_by ", " "${unknown_targets[@]}")"
    SCOPE_IMPACT_REASON="scope includes unknown module name(s)"
    return 1
  fi

  if [[ "${#shared_targets[@]}" -gt 0 ]]; then
    SCOPE_IMPACT="shared_control_plane"
    SCOPE_IMPACT_REASON="scope includes shared control-plane targets: $(_gdc_join_by ", " "${shared_targets[@]}")"
    return 0
  fi

  if [[ "${#prod_targets[@]}" -gt 0 ]]; then
    SCOPE_IMPACT="prod_affecting"
    SCOPE_IMPACT_REASON="scope includes prod-affecting targets: $(_gdc_join_by ", " "${prod_targets[@]}")"
    return 0
  fi

  SCOPE_IMPACT="dev_only"
  SCOPE_IMPACT_REASON="all requested targets are dev-only: $(_gdc_join_by ", " "${dev_targets[@]}")"
  return 0
}

detect_initial_deploy() {
  INITIAL_DEPLOY=0
  INITIAL_DEPLOY_REASON=""

  local prod_ref=""
  set +e
  prod_ref="$("${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" rev-parse --verify --quiet refs/remotes/gitlab/prod 2>/dev/null)"
  local prod_ref_exit=$?
  set -e
  if [[ "$prod_ref_exit" -eq 0 && -n "$prod_ref" ]]; then
    INITIAL_DEPLOY=0
    INITIAL_DEPLOY_REASON="gitlab/prod ref exists locally; treating cluster as existing deployment"
    return 0
  fi

  set +e
  "${GIT_DEPLOY_TOFU_WRAPPER_BIN}" init -input=false >/dev/null 2>&1
  local init_exit=$?
  set -e
  if [[ "$init_exit" -ne 0 ]]; then
    INITIAL_DEPLOY=0
    INITIAL_DEPLOY_REASON="could not initialize tofu state; treating cluster as existing deployment"
    return 0
  fi

  local state_output=""
  set +e
  state_output="$("${GIT_DEPLOY_TOFU_WRAPPER_BIN}" state list 2>/dev/null)"
  local state_exit=$?
  set -e
  if [[ "$state_exit" -ne 0 ]]; then
    INITIAL_DEPLOY=0
    INITIAL_DEPLOY_REASON="could not query tofu state; treating cluster as existing deployment"
    return 0
  fi

  local state_resources
  state_resources="$(printf '%s\n' "$state_output" | grep -E '^[[:alnum:]_]+\.' || true)"
  if [[ -n "$state_resources" ]]; then
    INITIAL_DEPLOY=0
    INITIAL_DEPLOY_REASON="tofu state is not empty"
    return 0
  fi

  local node_names=()
  local node_ips=()
  local vmids=()
  local vmid
  local node_name
  local node_ip
  while IFS= read -r node_name; do
    [[ -n "$node_name" && "$node_name" != "null" ]] && node_names+=("$node_name")
  done < <("${GIT_DEPLOY_YQ_BIN}" -r '.nodes[].name' "${CONFIG}")
  while IFS= read -r node_ip; do
    [[ -n "$node_ip" ]] && node_ips+=("$node_ip")
  done < <("${GIT_DEPLOY_YQ_BIN}" -r '.nodes[].mgmt_ip' "${CONFIG}")
  while IFS= read -r vmid; do
    [[ -n "$vmid" && "$vmid" != "null" ]] && vmids+=("$vmid")
  done < <("${GIT_DEPLOY_YQ_BIN}" -r '.vms | to_entries[] | (.value.vmid // "")' "${CONFIG}")

  if [[ "${#node_names[@]}" -eq 0 || "${#node_ips[@]}" -eq 0 || "${#node_names[@]}" -ne "${#node_ips[@]}" || "${#vmids[@]}" -eq 0 ]]; then
    INITIAL_DEPLOY=0
    INITIAL_DEPLOY_REASON="could not determine configured VMIDs or Proxmox nodes; treating cluster as existing deployment"
    return 0
  fi

  local probe_output=""
  local probe_exit=0
  for vmid in "${vmids[@]}"; do
    for node_ip in "${node_ips[@]}"; do
      set +e
      probe_output="$("${GIT_DEPLOY_SSH_BIN}" -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${node_ip}" "if qm status ${vmid} >/dev/null 2>&1; then echo present; else echo absent; fi" 2>/dev/null)"
      probe_exit=$?
      set -e
      if [[ "$probe_exit" -ne 0 ]]; then
        INITIAL_DEPLOY=0
        INITIAL_DEPLOY_REASON="could not probe Proxmox for configured VMIDs; treating cluster as existing deployment"
        return 0
      fi
      if [[ "$probe_output" == "present" ]]; then
        INITIAL_DEPLOY=0
        INITIAL_DEPLOY_REASON="configured VMID ${vmid} already exists in Proxmox; treating cluster as existing deployment"
        return 0
      fi
    done
  done

  local pbs_probe_state="neutral"
  local pbs_probe_dir=""
  set +e
  pbs_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/git-deploy-context-pbs.XXXXXX")"
  local pbs_probe_dir_exit=$?
  set -e
  if [[ "$pbs_probe_dir_exit" -ne 0 || -z "$pbs_probe_dir" ]]; then
    INITIAL_DEPLOY=0
    INITIAL_DEPLOY_REASON="could not create PBS probe workspace; treating cluster as existing deployment"
    return 0
  fi

  local pbs_pids=()
  local pbs_idx=0
  local pbs_success_idx=""
  local pbs_jobs_remaining=0
  local pbs_job_status=""
  local pbs_match_vmid=""
  local pbs_match_exit=0
  for pbs_idx in "${!node_ips[@]}"; do
    node_name="${node_names[$pbs_idx]}"
    node_ip="${node_ips[$pbs_idx]}"
    (
      local pbs_output=""
      if pbs_output="$("${GIT_DEPLOY_SSH_BIN}" -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${node_ip}" "pvesh get /nodes/${node_name}/storage/pbs-nas/content --output-format json 2>/dev/null" 2>/dev/null)"; then
        printf '%s' "$pbs_output" > "${pbs_probe_dir}/${pbs_idx}.out"
        printf 'success\n' > "${pbs_probe_dir}/${pbs_idx}.status"
      else
        printf 'error\n' > "${pbs_probe_dir}/${pbs_idx}.status"
      fi
    ) &
    pbs_pids[$pbs_idx]=$!
    pbs_jobs_remaining=$((pbs_jobs_remaining + 1))
  done

  while [[ "$pbs_jobs_remaining" -gt 0 ]]; do
    for pbs_idx in "${!pbs_pids[@]}"; do
      [[ -z "${pbs_pids[$pbs_idx]:-}" ]] && continue

      if [[ -f "${pbs_probe_dir}/${pbs_idx}.status" ]]; then
        pbs_job_status="$(cat "${pbs_probe_dir}/${pbs_idx}.status")"
        if [[ "$pbs_job_status" == "success" ]]; then
          pbs_success_idx="$pbs_idx"
          pbs_jobs_remaining=0
          break
        fi
        wait "${pbs_pids[$pbs_idx]}" >/dev/null 2>&1 || true
        pbs_pids[$pbs_idx]=""
        pbs_jobs_remaining=$((pbs_jobs_remaining - 1))
      elif ! kill -0 "${pbs_pids[$pbs_idx]}" 2>/dev/null; then
        wait "${pbs_pids[$pbs_idx]}" >/dev/null 2>&1 || true
        pbs_pids[$pbs_idx]=""
        pbs_jobs_remaining=$((pbs_jobs_remaining - 1))
      fi
    done
    [[ -n "$pbs_success_idx" ]] && break
    sleep 0.1
  done

  if [[ -n "$pbs_success_idx" ]]; then
    pbs_probe_state="clear"
  fi

  for pbs_idx in "${!pbs_pids[@]}"; do
    [[ -z "${pbs_pids[$pbs_idx]:-}" ]] && continue
    if [[ "$pbs_idx" != "$pbs_success_idx" ]]; then
      kill "${pbs_pids[$pbs_idx]}" 2>/dev/null || true
    fi
    wait "${pbs_pids[$pbs_idx]}" >/dev/null 2>&1 || true
  done

  if [[ -n "$pbs_success_idx" ]]; then
    set +e
    pbs_match_vmid="$(_gdc_pbs_output_matches_configured_vmid "${pbs_probe_dir}/${pbs_success_idx}.out" "${vmids[@]}")"
    pbs_match_exit=$?
    set -e
    case "$pbs_match_exit" in
      0)
        rm -rf "${pbs_probe_dir}"
        INITIAL_DEPLOY=0
        INITIAL_DEPLOY_REASON="PBS has backups for configured VMIDs; treating cluster as existing deployment"
        return 0
        ;;
      1)
        pbs_probe_state="clear"
        ;;
      *)
        rm -rf "${pbs_probe_dir}"
        INITIAL_DEPLOY=0
        INITIAL_DEPLOY_REASON="could not parse PBS backup probe output; treating cluster as existing deployment"
        return 0
        ;;
    esac
  fi

  rm -rf "${pbs_probe_dir}"

  INITIAL_DEPLOY=1
  if [[ "$pbs_probe_state" == "neutral" ]]; then
    INITIAL_DEPLOY_REASON="tofu state is empty, no configured VMIDs found in Proxmox, no gitlab/prod ref, and PBS could not be reached"
  else
    INITIAL_DEPLOY_REASON="tofu state is empty, no configured VMIDs found in Proxmox, no gitlab/prod ref, and no PBS backups found"
  fi
  return 0
}

refresh_gitlab_prod_ref() {
  GITLAB_FETCH_ATTEMPTED=1
  GITLAB_FETCH_SUCCEEDED=0
  GITLAB_FETCH_DETAIL="not attempted"

  local fetch_stderr=""
  local ssh_command="ssh -o BatchMode=yes -o ConnectTimeout=5 -o ConnectionAttempts=1"
  set +e
  fetch_stderr="$(GIT_SSH_COMMAND="${ssh_command}" "${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" fetch gitlab --quiet 2>&1)"
  local fetch_exit=$?
  set -e

  if [[ "$fetch_exit" -eq 0 ]]; then
    GITLAB_FETCH_SUCCEEDED=1
    GITLAB_FETCH_DETAIL="ok"
  else
    GITLAB_FETCH_DETAIL="$(_gdc_human_fetch_detail "$fetch_stderr")"
  fi
}

resolve_last_known_prod_context() {
  LAST_KNOWN_PROD_AVAILABLE=0
  LAST_KNOWN_PROD_COMMIT=""
  LAST_KNOWN_PROD_COMMIT_SHORT=""
  LAST_KNOWN_PROD_DATE=""
  LAST_KNOWN_PROD_DIFFERS_FROM_CURRENT=0

  local prod_commit=""
  set +e
  prod_commit="$("${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" rev-parse --verify --quiet gitlab/prod 2>/dev/null)"
  local prod_exit=$?
  set -e
  if [[ "$prod_exit" -ne 0 || -z "$prod_commit" ]]; then
    LAST_KNOWN_PROD_AVAILABLE=0
    return 0
  fi

  LAST_KNOWN_PROD_AVAILABLE=1
  LAST_KNOWN_PROD_COMMIT="$prod_commit"
  LAST_KNOWN_PROD_COMMIT_SHORT="$("${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" rev-parse --short=8 "${prod_commit}")"
  LAST_KNOWN_PROD_DATE="$("${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" log -1 --format=%cI "${prod_commit}")"
  if [[ "${LAST_KNOWN_PROD_COMMIT}" != "${GIT_COMMIT}" ]]; then
    LAST_KNOWN_PROD_DIFFERS_FROM_CURRENT=1
  fi
}

detect_config_yaml_divergence() {
  CONFIG_YAML_DIFF=0

  if [[ "${LAST_KNOWN_PROD_AVAILABLE:-0}" -ne 1 || "${LAST_KNOWN_PROD_DIFFERS_FROM_CURRENT:-0}" -ne 1 ]]; then
    return 0
  fi

  set +e
  "${GIT_DEPLOY_GIT_BIN}" -C "${REPO_DIR}" diff --quiet "${GIT_COMMIT}" "${LAST_KNOWN_PROD_COMMIT}" -- site/config.yaml
  local diff_exit=$?
  set -e
  if [[ "$diff_exit" -eq 1 ]]; then
    CONFIG_YAML_DIFF=1
  fi
}

check_branch_safety() {
  BRANCH_SAFETY_ALLOWED=0
  BRANCH_SAFETY_REASON=""

  if [[ "${INITIAL_DEPLOY:-0}" -eq 1 ]]; then
    BRANCH_SAFETY_ALLOWED=1
    BRANCH_SAFETY_REASON="initial deploy detected"
    return 0
  fi

  if ! scope_requires_prod_branch; then
    BRANCH_SAFETY_ALLOWED=1
    BRANCH_SAFETY_REASON="scope is dev-only"
    return 0
  fi

  if [[ "${GIT_DETACHED:-0}" -eq 0 && "${GIT_BRANCH:-}" == "prod" ]]; then
    BRANCH_SAFETY_ALLOWED=1
    BRANCH_SAFETY_REASON="current branch is prod"
    return 0
  fi

  if [[ "${OVERRIDE_BRANCH_CHECK:-0}" -eq 1 ]]; then
    BRANCH_SAFETY_ALLOWED=1
    BRANCH_SAFETY_REASON="override branch check requested"
    return 0
  fi

  BRANCH_SAFETY_ALLOWED=0
  BRANCH_SAFETY_REASON="prod-affecting or shared control-plane scope requires the prod branch or an explicit override"
  return 1
}

print_scope_classification_failure() {
  echo "ERROR: Scope classification failed."
  echo "  Scope: $(_gdc_scope_label)"
  echo "  Reason: ${SCOPE_IMPACT_REASON:-unknown scope classification error}"
  if [[ -n "${SCOPE_UNKNOWN_TARGETS:-}" ]]; then
    echo "  Unknown targets: ${SCOPE_UNKNOWN_TARGETS}"
  fi
  echo "  Use real module names from framework/tofu/root (for example: dns_dev, dns_prod, vault_dev, vault_prod, acme_dev, gatus, gitlab, cicd, pbs)."
}

print_branch_safety_refusal() {
  local rerun_cmd
  local override_cmd
  rerun_cmd="$(_gdc_rebuild_command)"
  override_cmd="${rerun_cmd} --override-branch-check"

  echo "ERROR: Branch safety refused this rebuild."
  echo "  Current branch: $(_gdc_branch_label) (${GIT_COMMIT_SHORT})"
  echo "  Requested scope: $(_gdc_scope_label)"
  echo "  Derived impact: ${SCOPE_IMPACT}"
  echo "  Why this scope is guarded: ${SCOPE_IMPACT_REASON}"
  echo "  Corrective command for routine maintenance:"
  echo "    git checkout prod && ${rerun_cmd}"
  echo "  Override path for true disaster recovery:"
  echo "    ${override_cmd}"
}

_gdc_last_known_prod_summary() {
  if [[ "${INITIAL_DEPLOY:-0}" -eq 1 ]]; then
    printf 'not checked (initial deploy)\n'
    return 0
  fi

  local summary=""
  if [[ "${LAST_KNOWN_PROD_AVAILABLE:-0}" -eq 1 ]]; then
    if [[ "${LAST_KNOWN_PROD_DIFFERS_FROM_CURRENT:-0}" -eq 1 ]]; then
      summary="available (differs from current commit)"
    else
      summary="available (matches current commit)"
    fi
  else
    summary="unavailable"
  fi

  if [[ "${GITLAB_FETCH_ATTEMPTED:-0}" -eq 1 && "${GITLAB_FETCH_SUCCEEDED:-0}" -ne 1 ]]; then
    summary+="; fetch warning: ${GITLAB_FETCH_DETAIL}"
  fi

  printf '%s\n' "$summary"
}

print_deploy_banner() {
  echo "=== Deployment Context ==="
  echo "Branch: $(_gdc_branch_label)"
  echo "Commit: ${GIT_COMMIT_SHORT}"
  echo "Subject: ${GIT_SUBJECT}"
  echo "Date: ${GIT_DATE}"
  echo "Scope: $(_gdc_scope_label)"
  echo "Impact: ${SCOPE_IMPACT}"
  echo "Tree: ${GIT_TREE_STATE}"
  echo "Initial deploy: $([[ "${INITIAL_DEPLOY:-0}" -eq 1 ]] && echo yes || echo no)"
  echo "Initial deploy detail: ${INITIAL_DEPLOY_REASON}"
  echo "Override branch check: $([[ "${OVERRIDE_BRANCH_CHECK:-0}" -eq 1 ]] && echo yes || echo no)"
  echo "Last known prod: $(_gdc_last_known_prod_summary)"
  echo "=========================="
}

print_last_known_prod_comparison() {
  if [[ "${GITLAB_FETCH_ATTEMPTED:-0}" -eq 1 && "${GITLAB_FETCH_SUCCEEDED:-0}" -ne 1 ]]; then
    echo "WARNING: git fetch gitlab failed: ${GITLAB_FETCH_DETAIL}"
    echo "  Continuing with the locally cached ref state."
  fi

  if [[ "${LAST_KNOWN_PROD_AVAILABLE:-0}" -ne 1 ]]; then
    echo "WARNING: Last-known-prod comparison unavailable."
    echo "  Local ref gitlab/prod does not exist or could not be refreshed."
    echo "  When GitLab is reachable, run: git fetch gitlab"
    return 0
  fi

  echo "Your current commit:      ${GIT_COMMIT_SHORT} ($(_gdc_branch_label), ${GIT_DATE})"
  echo "Last known prod commit:   ${LAST_KNOWN_PROD_COMMIT_SHORT} (gitlab/prod, ${LAST_KNOWN_PROD_DATE})"

  if [[ "${LAST_KNOWN_PROD_DIFFERS_FROM_CURRENT:-0}" -eq 1 ]]; then
    echo "WARNING: You are deploying non-prod-branch code to prod VMs."
    echo "  To rebuild from the last known prod checkout instead:"
    echo "    git checkout gitlab/prod"
    echo "    $(_gdc_rebuild_command)"
  else
    echo "Current commit matches last known prod commit."
  fi

  if [[ "${CONFIG_YAML_DIFF:-0}" -eq 1 ]]; then
    echo "WARNING: site/config.yaml has changed between your commit and prod."
    echo "  This means CIDATA content (VM IPs, MACs, VMIDs, configuration) may differ"
    echo "  between what you are deploying and what was running in prod."
    echo "  Verify that your config.yaml reflects the intended prod state."
  fi
}

write_deploy_manifest() {
  local manifest_dir="${LOG_DIR:-${REPO_DIR}/build}"
  local manifest_path="${manifest_dir}/rebuild-manifest.json"
  mkdir -p "${manifest_dir}"

  "${GIT_DEPLOY_JQ_BIN}" -n \
    --arg branch "$(_gdc_branch_label)" \
    --arg commit "${GIT_COMMIT}" \
    --arg commit_short "${GIT_COMMIT_SHORT}" \
    --arg subject "${GIT_SUBJECT}" \
    --arg date "${GIT_DATE}" \
    --arg scope "$(_gdc_scope_label)" \
    --arg impact "${SCOPE_IMPACT}" \
    --arg tree "${GIT_TREE_STATE}" \
    --arg initial_reason "${INITIAL_DEPLOY_REASON}" \
    --arg fetch_detail "${GITLAB_FETCH_DETAIL:-not attempted}" \
    --arg last_known_prod_commit "${LAST_KNOWN_PROD_COMMIT:-}" \
    --arg last_known_prod_commit_short "${LAST_KNOWN_PROD_COMMIT_SHORT:-}" \
    --arg last_known_prod_date "${LAST_KNOWN_PROD_DATE:-}" \
    --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --argjson initial_deploy "${INITIAL_DEPLOY:-0}" \
    --argjson override_branch_check "${OVERRIDE_BRANCH_CHECK:-0}" \
    --argjson fetch_attempted "${GITLAB_FETCH_ATTEMPTED:-0}" \
    --argjson fetch_succeeded "${GITLAB_FETCH_SUCCEEDED:-0}" \
    --argjson last_known_prod_available "${LAST_KNOWN_PROD_AVAILABLE:-0}" \
    --argjson last_known_prod_differs "${LAST_KNOWN_PROD_DIFFERS_FROM_CURRENT:-0}" \
    --argjson config_yaml_diff "${CONFIG_YAML_DIFF:-0}" \
    '
    {
      branch: $branch,
      commit: $commit,
      commit_short: $commit_short,
      subject: $subject,
      date: $date,
      scope: $scope,
      impact: $impact,
      tree: $tree,
      initial_deploy: ($initial_deploy == 1),
      initial_deploy_reason: $initial_reason,
      override_branch_check: ($override_branch_check == 1),
      gitlab_fetch: {
        attempted: ($fetch_attempted == 1),
        succeeded: ($fetch_succeeded == 1),
        detail: $fetch_detail
      },
      last_known_prod: {
        available: ($last_known_prod_available == 1),
        commit: (if $last_known_prod_available == 1 then $last_known_prod_commit else null end),
        commit_short: (if $last_known_prod_available == 1 then $last_known_prod_commit_short else null end),
        date: (if $last_known_prod_available == 1 then $last_known_prod_date else null end),
        differs_from_current: ($last_known_prod_differs == 1),
        config_yaml_diff: ($config_yaml_diff == 1)
      },
      timestamp: $timestamp
    }' > "${manifest_path}"

  echo "Wrote deploy manifest: ${manifest_path}"
}

print_post_dr_reconciliation_instructions() {
  echo "=== Post-DR Reconciliation Required ==="
  echo "Your cluster was rebuilt from commit ${GIT_COMMIT_SHORT} (branch: $(_gdc_branch_label))."
  echo "This may differ from what was running in prod before the rebuild."
  echo ""
  echo "To reconcile:"
  echo "1. Verify data integrity (validate.sh, check application state)"
  echo "2. Push this commit to GitLab dev branch: git push gitlab $(_gdc_push_source_ref):dev"
  echo "3. Create a dev->prod MR in GitLab and merge it"
  echo "4. Let the pipeline redeploy from the correct branches"
  echo "5. Run backup-now.sh after the pipeline completes"
  echo ""
  echo "Until reconciliation is complete, prod VMs may be running code from"
  echo "the dev branch instead of the prod branch."
  echo "==="
}
