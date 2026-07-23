#!/usr/bin/env bash
# validate.sh — Comprehensive infrastructure validation suite.
#
# Usage:
#   framework/scripts/validate.sh              # Run all checks (prod + dev)
#   framework/scripts/validate.sh prod         # Run prod checks only
#   framework/scripts/validate.sh dev          # Run dev checks only
#   framework/scripts/validate.sh --quick dev  # Skip slow checks, dev only
#   framework/scripts/validate.sh --regression-safe dev   # Non-destructive regression, dev + cluster-wide
#   framework/scripts/validate.sh --regression-safe prod  # Non-destructive regression, prod + cluster-wide
#   framework/scripts/validate.sh --regression dev        # Full regression incl. destructive (dev ONLY)
#   framework/scripts/validate.sh --regression prod       # REFUSED — destructive tests cannot target prod
#   framework/scripts/validate.sh --regression-deploy dev # Destroy+redeploy dev VMs, then full regression (dev→prod gate)
#
# Regression test scopes:
#   cluster    — tests cluster-wide properties, run regardless of env arg
#   cross-env  — tests spanning both environments, always query both
#   env        — tests for the specified environment only
#   destructive — modifies state, dev ONLY (requires --regression dev)
#
# Exit code 0 if all checks pass, 1 if any fail, 2 on usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${MYCOFU_VALIDATE_CONFIG:-${REPO_DIR}/site/config.yaml}"
APPS_CONFIG="${MYCOFU_VALIDATE_APPS_CONFIG:-${REPO_DIR}/site/applications.yaml}"
source "${SCRIPT_DIR}/certbot-cluster.sh"
# shellcheck source=framework/scripts/vdb-park-lib.sh
source "${SCRIPT_DIR}/vdb-park-lib.sh"
# github-publish-lib.sh is intentionally NOT sourced here. It is
# sourced lazily inside the publish-enabled branch of the Gatus
# github-mirror probe below so hermetic fixture tests that copy
# only validate.sh + certbot-cluster.sh + vdb-park-lib.sh
# (test_validate_vm_complete.sh, test_validate_pbs_ssh_stderr_noise.sh,
# test_validate_pbs_content_filter.sh, etc.) do not need to also
# stage the publish lib and its transitive helpers.

ENVS=()
QUICK=0
REGRESSION=0
REGRESSION_SAFE=0
REGRESSION_DEPLOY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=1; shift ;;
    --regression) REGRESSION=1; shift ;;
    --regression-safe) REGRESSION_SAFE=1; shift ;;
    --regression-deploy) REGRESSION_DEPLOY=1; REGRESSION=1; shift ;;
    prod|dev) ENVS+=("$1"); shift ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ${#ENVS[@]} -eq 0 ]]; then
  REPLICATION_POLICY_VALIDATE_SCOPE="all"
  ENVS=(prod dev)
elif [[ ${#ENVS[@]} -eq 1 ]]; then
  REPLICATION_POLICY_VALIDATE_SCOPE="${ENVS[0]}"
else
  REPLICATION_POLICY_VALIDATE_SCOPE="all"
fi

# Refuse --regression/--regression-deploy when prod is in scope
if [[ "$REGRESSION" -eq 1 ]]; then
  for _env in "${ENVS[@]}"; do
    if [[ "$_env" == "prod" ]]; then
      echo "ERROR: Destructive regression tests cannot target prod." >&2
      echo "Destructive tests only run against dev VMs." >&2
      echo "Use --regression-safe prod for non-destructive regression tests against prod." >&2
      exit 1
    fi
  done
fi

# --regression-deploy requires exactly "dev" as the environment
if [[ "$REGRESSION_DEPLOY" -eq 1 ]]; then
  if [[ ${#ENVS[@]} -ne 1 || "${ENVS[0]}" != "dev" ]]; then
    echo "ERROR: --regression-deploy requires exactly 'dev' as the environment." >&2
    exit 2
  fi
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 2
fi

# --- Counters ---
PASS=0
FAIL=0
SKIP=0
WARN=0

check() {
  local label="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "[PASS] ${label}"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] ${label}"
    FAIL=$((FAIL + 1))
  fi
}

check_skip() {
  local label="$1"
  local reason="$2"
  echo "[SKIP] ${label} — ${reason}"
  SKIP=$((SKIP + 1))
}

print_check_output() {
  local output="$1"
  if [[ -n "${output}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      echo "       ${line}"
    done <<< "${output}"
  fi
}

check_capture() {
  local label="$1"
  shift
  local output rc
  set +e
  output=$("$@" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "[PASS] ${label}"
    PASS=$((PASS + 1))
    print_check_output "${output}"
  else
    echo "[FAIL] ${label}"
    FAIL=$((FAIL + 1))
    print_check_output "${output}"
  fi
}

check_warn() {
  local label="$1"
  shift
  local output rc
  set +e
  output=$("$@" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "[PASS] ${label}"
    PASS=$((PASS + 1))
  elif [[ $rc -eq 3 ]]; then
    echo "[WARN] ${label}"
    WARN=$((WARN + 1))
  else
    echo "[FAIL] ${label}"
    FAIL=$((FAIL + 1))
  fi
  print_check_output "${output}"
}

vm_topology_complete_check() {
  local rows line vmid label failures output rc
  failures=0

  rows="$(
    CONFIG_FILE="$CONFIG" APPS_CONFIG_FILE="$APPS_CONFIG" python3 - <<'PY'
import json
import os
import subprocess


def load_yaml(path, default):
    if not os.path.exists(path):
        return default
    raw = subprocess.check_output(["yq", "-o=json", ".", path], text=True)
    return json.loads(raw)


config = load_yaml(os.environ["CONFIG_FILE"], {})
apps = load_yaml(os.environ["APPS_CONFIG_FILE"], {"applications": {}})

for label, vm in (config.get("vms") or {}).items():
    if not isinstance(vm, dict) or vm.get("enabled", True) is False:
        continue
    vmid = vm.get("vmid")
    if vmid not in (None, ""):
        print(f"{vmid}\t{label}")

for app, app_cfg in (apps.get("applications") or {}).items():
    if not isinstance(app_cfg, dict) or app_cfg.get("enabled") is not True:
        continue
    for env, env_cfg in (app_cfg.get("environments") or {}).items():
        if not isinstance(env_cfg, dict):
            continue
        vmid = env_cfg.get("vmid")
        if vmid not in (None, ""):
            print(f"{vmid}\t{app}_{env}")
PY
  )"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS=$'\t' read -r vmid label <<< "$line"
    set +e
    output="$("${SCRIPT_DIR}/vm-is-complete.sh" "$vmid" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]]; then
      echo "${label} (${vmid}): complete"
    elif [[ "$rc" -eq 2 ]]; then
      echo "${label} (${vmid}): incomplete"
      [[ -n "$output" ]] && echo "$output"
      failures=$((failures + 1))
    else
      echo "${label} (${vmid}): unverifiable"
      [[ -n "$output" ]] && echo "$output"
      failures=$((failures + 1))
    fi
  done <<< "$rows"

  [[ "$failures" -eq 0 ]]
}

# SSH options used throughout (direct calls and subshells)
export SSH_OPTS="-n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
read -r -a SSH_OPTS_ARGS <<< "$SSH_OPTS"

# SSH helper for regression tests (direct calls only — not available in bash -c)
ssh_node() {
  ssh "${SSH_OPTS_ARGS[@]}" "$@"
}

if [[ "${MYCOFU_VALIDATE_ONLY_VM_TOPOLOGY:-0}" == "1" ]]; then
  echo "=== VM Topology ==="
  check_capture "VM topology completeness" vm_topology_complete_check
  echo "========================================="
  echo "Results: ${PASS} passed, ${FAIL} failed"
  echo "========================================="
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

pbs_schedule_max_age_seconds() {
  local schedule="$1"

  if [[ ! "$schedule" =~ ^([0-9]|[01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "ERROR: unsupported pbs.backup_schedule '${schedule}'. Only bare HH:MM daily schedules are supported." >&2
    return 1
  fi

  # Bare HH:MM means daily cadence. Sprint 038 deliberately supports only
  # that format; new schedule syntaxes require explicit parser/test updates.
  echo 129600
}

format_epoch_utc() {
  local epoch="$1"

  date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || echo "$epoch"
}

pbs_backup_freshness_check() {
  local schedule max_age_seconds vm_rows first_node_ip now failures
  local any_backup no_backup_count line vmid label query_cmd content rc
  local latest age_seconds age_hours latest_display status bad_vmids unverifiable_count

  schedule="$(yq -r '.pbs.backup_schedule // "02:00"' "$CONFIG")"
  max_age_seconds="$(pbs_schedule_max_age_seconds "$schedule")" || return 1

  set +e
  vm_rows="$("${SCRIPT_DIR}/list-backup-backed-vmids.sh" --format tsv all 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "$vm_rows"
    return 1
  fi
  if [[ -z "$vm_rows" ]]; then
    echo "No enabled backup-backed VMIDs in config."
    return 2
  fi

  first_node_ip="$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")"
  now="${MYCOFU_VALIDATE_NOW:-$(date +%s)}"
  failures=0
  any_backup=0
  no_backup_count=0

  printf '%-7s %-24s %-20s %-10s %s\n' "VMID" "Name" "Latest" "Age" "Status"

  # ssh uses SSH_OPTS, which includes -n, so it will not consume this loop's stdin.
  # shellcheck disable=SC2095
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    IFS=$'\t' read -r vmid label _env_name <<< "$line"
    [[ -n "${vmid:-}" ]] || continue

    query_cmd="pvesh get /nodes/\$(hostname)/storage/pbs-nas/content --vmid ${vmid} --output-format json"
    set +e
    # Capture stdout (the JSON) separately from stderr. Folding stderr in with
    # `2>&1` lets SSH's "Warning: Permanently added <host> to the list of known
    # hosts" line (emitted on first connect, which is every connect because
    # UserKnownHostsFile=/dev/null) contaminate the JSON and trip the
    # fail-closed invalid-JSON path. LogLevel=ERROR also suppresses that warning;
    # this keeps the parse robust even if a future SSH emits other stderr noise.
    query_err="$(mktemp)"
    # shellcheck disable=SC2029
    content="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${first_node_ip}" "$query_cmd" 2>"$query_err")"
    rc=$?
    query_stderr="$(cat "$query_err" 2>/dev/null)"
    rm -f "$query_err"
    set -e
    if [[ "$rc" -ne 0 ]]; then
      printf '%-7s %-24s %-20s %-10s %s\n' "$vmid" "$label" "-" "-" "FAIL query failed"
      echo "PBS freshness query failed for VMID ${vmid}: ${query_stderr:-${content}}" >&2
      failures=$((failures + 1))
      continue
    fi
    if ! printf '%s\n' "$content" | jq -e 'type == "array"' >/dev/null 2>&1; then
      printf '%-7s %-24s %-20s %-10s %s\n' "$vmid" "$label" "-" "-" "FAIL invalid JSON"
      echo "PBS freshness query returned invalid JSON for VMID ${vmid}: ${content}" >&2
      failures=$((failures + 1))
      continue
    fi
    bad_vmids="$(printf '%s\n' "$content" | jq -r --arg vmid "$vmid" '
      def entry_vmid:
        if has("vmid") then
          (.vmid | tostring)
        elif has("volid") then
          (try (.volid | capture("/vm/(?<vmid>[0-9]+)/").vmid) catch "")
        else
          ""
        end;
      [.[] | entry_vmid | select(. != "" and . != $vmid)] | unique | join(",")
    ')"
    unverifiable_count="$(printf '%s\n' "$content" | jq -r '
      def entry_vmid:
        if has("vmid") then
          (.vmid | tostring)
        elif has("volid") then
          (try (.volid | capture("/vm/(?<vmid>[0-9]+)/").vmid) catch "")
        else
          ""
        end;
      [.[] | select((entry_vmid) == "")] | length
    ')"
    if [[ -n "$bad_vmids" || "$unverifiable_count" -gt 0 ]]; then
      printf '%-7s %-24s %-20s %-10s %s\n' "$vmid" "$label" "-" "-" "FAIL wrong VMID"
      if [[ -n "$bad_vmids" ]]; then
        echo "PBS freshness query for VMID ${vmid} returned backup content for VMID(s): ${bad_vmids}" >&2
      fi
      if [[ "$unverifiable_count" -gt 0 ]]; then
        echo "PBS freshness query for VMID ${vmid} returned ${unverifiable_count} item(s) without vmid or parseable volid" >&2
      fi
      failures=$((failures + 1))
      continue
    fi

    latest="$(printf '%s\n' "$content" | jq -r '[.[].ctime // empty] | map(tonumber) | sort | last // 0')"
    if [[ -z "$latest" || "$latest" == "0" || "$latest" == "null" ]]; then
      no_backup_count=$((no_backup_count + 1))
      printf '%-7s %-24s %-20s %-10s %s\n' "$vmid" "$label" "-" "-" "NO_BACKUP"
      continue
    fi

    any_backup=1
    age_seconds=$((now - latest))
    age_hours=$(((age_seconds + 3599) / 3600))
    latest_display="$(format_epoch_utc "$latest")"
    if [[ "$age_seconds" -le "$max_age_seconds" ]]; then
      status="OK"
    else
      status="STALE"
      failures=$((failures + 1))
    fi
    printf '%-7s %-24s %-20s %-10s %s\n' "$vmid" "$label" "$latest_display" "${age_hours}h" "$status"
  done <<< "$vm_rows"

  if [[ "$any_backup" -eq 0 && "$failures" -eq 0 ]]; then
    echo "no backups for any expected VMID (fresh cluster)"
    return 2
  fi

  if [[ "$any_backup" -eq 1 && "$no_backup_count" -gt 0 ]]; then
    failures=$((failures + no_backup_count))
  fi

  [[ "$failures" -eq 0 ]]
}

run_pbs_backup_freshness_check() {
  local output rc

  set +e
  output="$(pbs_backup_freshness_check 2>&1)"
  rc=$?
  set -e

  case "$rc" in
    0)
      echo "[PASS] PBS backup freshness per backup-backed VM"
      PASS=$((PASS + 1))
      print_check_output "$output"
      ;;
    2)
      echo "[SKIP] PBS backup freshness — no backups for any expected VMID (fresh cluster)"
      SKIP=$((SKIP + 1))
      print_check_output "$output"
      ;;
    *)
      echo "[FAIL] PBS backup freshness per backup-backed VM"
      FAIL=$((FAIL + 1))
      print_check_output "$output"
      ;;
  esac
}

# --- Read common config ---
DOMAIN=$(yq -r '.domain' "$CONFIG")
NODE_COUNT=$(yq -r '.nodes | length' "$CONFIG")
NAS_IP=$(yq -r '.nas.ip' "$CONFIG")
GATUS_IP=$(yq -r '.vms.gatus.ip' "$CONFIG")
GITLAB_IP=$(yq -r '.vms.gitlab.ip' "$CONFIG")
PBS_IP=$(yq -r '.vms.pbs.ip' "$CONFIG")
HEALTH_PORT=$(yq -r '.replication.health_port' "$CONFIG")
STORAGE_POOL=$(yq -r '.proxmox.storage_pool' "$CONFIG")
SITE_ACME_MODE="$(certbot_cluster_expected_mode "${CONFIG}")"
SITE_ACME_URL="$(certbot_cluster_expected_url "${CONFIG}")"

ha_maintenance_check() {
  local count i node_ip node_name status_txt="" rc saw_maintenance=0
  local line matched_line

  count="$NODE_COUNT"
  for (( i=0; i<count; i++ )); do
    node_ip=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    set +e
    status_txt="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${node_ip}" "ha-manager status" 2>/dev/null)"
    rc=$?
    set -e
    if [[ "$rc" -eq 0 && -n "$status_txt" ]]; then
      break
    fi
    status_txt=""
  done

  if [[ -z "$status_txt" ]]; then
    echo "could not read HA status from any cluster member"
    echo "FAIL (fail-closed): cannot determine whether a node is in HA maintenance"
    return 1
  fi

  for (( i=0; i<count; i++ )); do
    node_name=$(yq -r ".nodes[${i}].name" "$CONFIG")
    matched_line=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^lrm[[:space:]]+${node_name}[[:space:]]+\( ]] && [[ "$line" == *"maintenance mode"* ]]; then
        matched_line="$line"
        break
      fi
    done <<< "$status_txt"
    if [[ -n "$matched_line" ]]; then
      echo "${node_name}: ${matched_line}"
      saw_maintenance=1
    fi
  done

  if [[ "$saw_maintenance" -eq 0 ]]; then
    return 0
  fi

  echo ""
  echo "One or more nodes are in HA maintenance."
  echo "This can be expected during an in-flight rolling reboot, or it can"
  echo "mean Step z refused failback because the destination was not proven safe."
  echo "If this is not an active reboot, follow the Step-z remediation:"
  echo "  framework/scripts/cleanup-orphan-cidata.sh --dry-run"
  echo "  framework/scripts/realign-cidata.sh --dry-run --vmid <vmid>"
  echo "  framework/scripts/realign-cidata.sh --vmid <vmid>"
  echo "Only after the failback destination is safe:"
  echo "  ha-manager crm-command node-maintenance disable <node>"
  return 3
}

replication_policy_helper_csv() {
  local mode="$1" output rc
  # Separate helper stderr from stdout so any informational WARNs the
  # helper emits (e.g., the redundant-1m WARN on a backup:true VM
  # carrying an explicit "1m" cadence) don't contaminate the parsed CSV;
  # forward the captured WARNs to our own stderr.
  local err_file
  err_file="$(mktemp "${TMPDIR:-/tmp}/list-repl-vmids-err.XXXXXX")"

  set +e
  output="$("${SCRIPT_DIR}/list-replicated-vmids.sh" --format csv --mode "$mode" all 2>"$err_file")"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "helper unreadable: list-replicated-vmids.sh --format csv --mode ${mode} all failed"
    cat "$err_file"
    rm -f "$err_file"
    return 1
  fi
  [[ -s "$err_file" ]] && cat "$err_file" >&2
  rm -f "$err_file"

  printf '%s\n' "$output"
}

replication_policy_scope_tsv() {
  local mode="$1" scope="$2" output all_output rc
  local err_file
  err_file="$(mktemp "${TMPDIR:-/tmp}/list-repl-vmids-err.XXXXXX")"

  case "$scope" in
    all|prod)
      set +e
      output="$("${SCRIPT_DIR}/list-replicated-vmids.sh" --format tsv --mode "$mode" "$scope" 2>"$err_file")"
      rc=$?
      set -e
      if [[ "$rc" -ne 0 ]]; then
        echo "helper unreadable: list-replicated-vmids.sh --format tsv --mode ${mode} ${scope} failed"
        cat "$err_file"
        rm -f "$err_file"
        return 1
      fi
      [[ -s "$err_file" ]] && cat "$err_file" >&2
      rm -f "$err_file"
      printf '%s\n' "$output"
      ;;
    dev)
      set +e
      output="$("${SCRIPT_DIR}/list-replicated-vmids.sh" --format tsv --mode "$mode" dev 2>"$err_file")"
      rc=$?
      set -e
      if [[ "$rc" -ne 0 ]]; then
        echo "helper unreadable: list-replicated-vmids.sh --format tsv --mode ${mode} dev failed"
        cat "$err_file"
        rm -f "$err_file"
        return 1
      fi
      [[ -s "$err_file" ]] && cat "$err_file" >&2

      set +e
      all_output="$("${SCRIPT_DIR}/list-replicated-vmids.sh" --format tsv --mode "$mode" all 2>"$err_file")"
      rc=$?
      set -e
      if [[ "$rc" -ne 0 ]]; then
        echo "helper unreadable: list-replicated-vmids.sh --format tsv --mode ${mode} all failed"
        cat "$err_file"
        rm -f "$err_file"
        return 1
      fi
      [[ -s "$err_file" ]] && cat "$err_file" >&2
      rm -f "$err_file"

      {
        printf '%s\n' "$output"
        printf '%s\n' "$all_output"
      } | awk -F'\t' '$0 != "" && ($3 == "dev" || $3 == "shared")' | sort -u
      ;;
    *)
      echo "helper unreadable: invalid validate replication scope '${scope}'"
      return 1
      ;;
  esac
}

replication_policy_artifact_value() {
  local content="$1" key="$2"

  printf '%s\n' "$content" | awk -v key="$key" '
    index($0, key "=") == 1 {
      print substr($0, length(key) + 2)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  '
}

replication_policy_cadence_map_from_tsv() {
  local tsv="$1"

  printf '%s\n' "$tsv" | awk -F'\t' '
    $0 == "" {next}
    NF >= 8 {
      if ($8 !~ /^[0-9]+$/) {
        bad = 1
        next
      }
      print $1 ":" $8
    }
    END {
      if (bad) {
        exit 2
      }
    }
  ' | sort -n | paste -sd, -
}

replication_policy_conformance_check() {
  local scope="${REPLICATION_POLICY_VALIDATE_SCOPE:-all}"
  local global_on global_off global_on_tsv scoped_on scoped_off cadence_map local_gen node_names
  local first_node_ip jobs_json artifact artifact_on artifact_off artifact_gen
  local artifact_cadence pvesr_status_tsv node_status_raw node_status_tsv
  local node_name node_ip rc i failures=0

  if ! global_on="$(replication_policy_helper_csv replicated)"; then
    printf '%s\n' "$global_on"
    return 1
  fi
  if [[ -z "${global_on//[[:space:]]/}" ]]; then
    echo "helper returned empty policy-on set from --mode replicated all"
    return 1
  fi

  if ! global_off="$(replication_policy_helper_csv policy-off)"; then
    printf '%s\n' "$global_off"
    return 1
  fi

  if ! global_on_tsv="$(replication_policy_scope_tsv replicated all)"; then
    printf '%s\n' "$global_on_tsv"
    return 1
  fi

  if ! cadence_map="$(replication_policy_cadence_map_from_tsv "$global_on_tsv")"; then
    echo "helper unreadable: could not derive CADENCE_MAP from helper TSV"
    return 1
  fi

  if ! scoped_on="$(replication_policy_scope_tsv replicated "$scope")"; then
    printf '%s\n' "$scoped_on"
    return 1
  fi
  if [[ -z "${scoped_on//[[:space:]]/}" ]]; then
    echo "helper returned empty policy-on set for validate scope ${scope}"
    return 1
  fi

  if ! scoped_off="$(replication_policy_scope_tsv policy-off "$scope")"; then
    printf '%s\n' "$scoped_off"
    return 1
  fi

  set +e
  local_gen="$(printf '%s|%s|%s\n' "$global_on" "$global_off" "$cadence_map" | sha256sum | awk '{print $1}')"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 || -z "$local_gen" ]]; then
    echo "local POLICY_GEN computation failed"
    return 1
  fi

  if ! node_names="$(yq -r '.nodes[].name' "$CONFIG" 2>&1)"; then
    echo "failed to read node names from ${CONFIG}"
    printf '%s\n' "$node_names"
    return 1
  fi
  if [[ -z "${node_names//[[:space:]]/}" ]]; then
    echo "failed to read node names from ${CONFIG}: empty node set"
    return 1
  fi

  if ! first_node_ip="$(yq -r '.nodes[0].mgmt_ip' "$CONFIG" 2>&1)"; then
    echo "failed to read first node IP from ${CONFIG}"
    printf '%s\n' "$first_node_ip"
    return 1
  fi

  set +e
  jobs_json="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${first_node_ip}" \
    "pvesh get /cluster/replication --output-format json" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "cluster replication query failed on ${first_node_ip}: pvesh get /cluster/replication --output-format json"
    printf '%s\n' "$jobs_json"
    return 1
  fi
  if ! jq -e 'type == "array"' <<< "$jobs_json" >/dev/null 2>&1; then
    echo "cluster replication query returned invalid JSON on ${first_node_ip}: pvesh get /cluster/replication --output-format json"
    printf '%s\n' "$jobs_json"
    return 1
  fi

  pvesr_status_tsv=""
  while IFS= read -r node_name; do
    [[ -z "$node_name" ]] && continue
    if ! node_ip="$(yq -r ".nodes[] | select(.name == \"${node_name}\") | .mgmt_ip" "$CONFIG" 2>&1)"; then
      echo "failed to read mgmt_ip for node ${node_name} from ${CONFIG}"
      printf '%s\n' "$node_ip"
      return 1
    fi
    if [[ -z "$node_ip" || "$node_ip" == "null" ]]; then
      echo "failed to read mgmt_ip for node ${node_name} from ${CONFIG}: empty value"
      return 1
    fi

    set +e
    node_status_raw="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${node_ip}" "pvesr status 2>/dev/null" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      echo "pvesr status query failed on ${node_name} (${node_ip}); cannot evaluate replication seed progress"
      printf '%s\n' "$node_status_raw"
      failures=$((failures + 1))
      continue
    fi
    node_status_tsv="$(printf '%s\n' "$node_status_raw" | awk -v node="$node_name" '
      NR == 1 && /^JobID/ {next}
      /^[0-9]+-[0-9]+/ {
        state = ""
        for (i = 8; i <= NF; i++) {
          state = state (i > 8 ? " " : "") $i
        }
        printf "%s\t%s\t%s\t%s\t%s\n", $1, node, $4, $7, state
      }
    ')"
    if [[ -n "$node_status_tsv" ]]; then
      pvesr_status_tsv+="${node_status_tsv}"$'\n'
    fi
  done <<< "$node_names"

  set +e
  JOBS_JSON="$jobs_json" \
  NODE_NAMES="$node_names" \
  GLOBAL_ON_TSV="$global_on_tsv" \
  POLICY_ON_TSV="$scoped_on" \
  POLICY_OFF_TSV="$scoped_off" \
  PVESR_STATUS_TSV="$pvesr_status_tsv" \
  VALIDATE_SCOPE="$scope" \
  python3 - <<'PY'
import json
import os
import re
import sys
from collections import Counter


def parse_rows(raw):
    rows = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            print(f"helper unreadable: malformed TSV row: {line}", file=sys.stderr)
            sys.exit(2)
        row = {
            "vmid": parts[0],
            "label": parts[1],
            "env": parts[2],
            "replicated": parts[3] if len(parts) > 3 else "",
            "pvesr_schedule": parts[6] if len(parts) > 6 else "",
            "cadence_seconds": parts[7] if len(parts) > 7 else "",
            "seed_wait_class": parts[8] if len(parts) > 8 else "",
        }
        if row["replicated"] == "true":
            if (
                not row["pvesr_schedule"]
                or not re.match(r"^[0-9]+$", row["cadence_seconds"])
                or row["seed_wait_class"] not in {"strict", "async"}
            ):
                print(f"helper unreadable: malformed cadence TSV row: {line}", file=sys.stderr)
                sys.exit(2)
        rows.append(row)
    return rows


def parse_status_rows(raw):
    by_job = {}
    for line in raw.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            print(f"pvesr status parse failed: malformed status row: {line}", file=sys.stderr)
            sys.exit(2)
        by_job.setdefault(parts[0], []).append({
            "node": parts[1],
            "last_sync": parts[2],
            "fail_count": parts[3],
            "state": parts[4] if len(parts) > 4 else "",
        })
    return by_job


def job_id(job):
    return str(job.get("id") or "")


def job_vmid(job):
    guest = job.get("guest")
    if guest not in (None, ""):
        return str(guest)
    match = re.match(r"^([0-9]+)-[0-9]+$", job_id(job))
    if match:
        return match.group(1)
    return ""


try:
    jobs = json.loads(os.environ["JOBS_JSON"])
except json.JSONDecodeError as exc:
    print(f"cluster replication query JSON parse failed: {exc}", file=sys.stderr)
    sys.exit(2)

if not isinstance(jobs, list):
    print("cluster replication query returned non-array JSON", file=sys.stderr)
    sys.exit(2)

node_names = [line.strip() for line in os.environ["NODE_NAMES"].splitlines() if line.strip()]
node_set = set(node_names)
global_policy_on = parse_rows(os.environ["GLOBAL_ON_TSV"])
policy_on = parse_rows(os.environ["POLICY_ON_TSV"])
policy_off = parse_rows(os.environ["POLICY_OFF_TSV"])
status_by_job = parse_status_rows(os.environ.get("PVESR_STATUS_TSV", ""))
failures = 0

for row in policy_on:
    vmid = row["vmid"]
    label = row["label"]
    vm_jobs = [
        job for job in jobs
        if job_vmid(job) == vmid or job_id(job).startswith(f"{vmid}-")
    ]
    target_counts = Counter(str(job.get("target") or "") for job in vm_jobs)
    targets = {target for target in target_counts if target}
    sources = sorted({
        str(job.get("source"))
        for job in vm_jobs
        if job.get("source") not in (None, "")
    })

    if len(vm_jobs) != max(len(node_names) - 1, 0):
        print(
            f"policy-on VMID {label} ({vmid}) has {len(vm_jobs)} replication job(s); "
            f"expected {max(len(node_names) - 1, 0)}"
        )
        failures += 1

    bad_ids = sorted(
        jid for jid in (job_id(job) for job in vm_jobs)
        if not re.match(rf"^{re.escape(vmid)}-[0-9]+$", jid)
    )
    if bad_ids:
        print(f"policy-on VMID {label} ({vmid}) has nonconforming job id(s): {','.join(bad_ids)}")
        failures += 1

    missing_target_jobs = [job_id(job) or "<missing-id>" for job in vm_jobs if not str(job.get("target") or "")]
    if missing_target_jobs:
        print(f"policy-on VMID {label} ({vmid}) has job(s) without target: {','.join(missing_target_jobs)}")
        failures += 1

    duplicate_targets = sorted(target for target, count in target_counts.items() if target and count > 1)
    if duplicate_targets:
        print(f"policy-on VMID {label} ({vmid}) has duplicate target job(s): {','.join(duplicate_targets)}")
        failures += 1

    unknown_targets = sorted(target for target in targets if target not in node_set)
    if unknown_targets:
        print(f"policy-on VMID {label} ({vmid}) targets unknown node(s): {','.join(unknown_targets)}")
        failures += 1

    source = ""
    if len(sources) > 1:
        print(f"policy-on VMID {label} ({vmid}) has multiple source nodes in replication jobs: {','.join(sources)}")
        failures += 1
    elif len(sources) == 1:
        source = sources[0]
        if source not in node_set:
            print(f"policy-on VMID {label} ({vmid}) has unknown source node in replication jobs: {source}")
            failures += 1
    else:
        candidates = [node for node in node_names if node not in targets]
        if len(candidates) == 1:
            source = candidates[0]
        else:
            print(f"policy-on VMID {label} ({vmid}) source node cannot be determined from replication jobs")
            failures += 1

    if source:
        expected_targets = {node for node in node_names if node != source}
        missing = sorted(expected_targets - targets)
        extra = sorted(targets - expected_targets)
        if missing:
            print(f"policy-on VMID {label} ({vmid}) missing target job(s): {','.join(missing)}")
            failures += 1
        if extra:
            print(f"policy-on VMID {label} ({vmid}) has target job(s) outside non-source set: {','.join(extra)}")
            failures += 1

for row in global_policy_on:
    vmid = row["vmid"]
    label = row["label"]
    expected_schedule = row["pvesr_schedule"]
    cadence_seconds = int(row["cadence_seconds"])
    vm_jobs = [
        job for job in jobs
        if job_vmid(job) == vmid or job_id(job).startswith(f"{vmid}-")
    ]
    for job in vm_jobs:
        jid = job_id(job) or "<missing-id>"
        live_schedule = str(job.get("schedule") or "")
        if live_schedule != expected_schedule:
            print(
                f"policy-on VMID {label} ({vmid}) job {jid} schedule drift: "
                f"expected '{expected_schedule}', got '{live_schedule}'"
            )
            failures += 1

        status_rows = status_by_job.get(jid, [])
        for status_row in status_rows:
            last_sync = status_row["last_sync"]
            fail_count = status_row["fail_count"]
            if not re.match(r"^[0-9]+$", fail_count):
                continue
            fail_count_value = int(fail_count)
            if cadence_seconds > 60 and fail_count_value == 0 and (last_sync == "-" or not last_sync):
                print(f"[WARN] replication seed in progress: {jid} ({label})")
            elif cadence_seconds <= 60 and fail_count_value == 0 and (last_sync == "-" or not last_sync):
                print(f"policy-on VMID {label} ({vmid}) job {jid} never completed initial sync")
                failures += 1

for row in policy_off:
    vmid = row["vmid"]
    label = row["label"]
    residual = sorted(
        job_id(job) or "<missing-id>"
        for job in jobs
        if job_vmid(job) == vmid or job_id(job).startswith(f"{vmid}-")
    )
    if residual:
        print(f"policy-off VMID {label} ({vmid}) has residual replication job(s): {','.join(residual)}")
        failures += 1

if failures:
    sys.exit(1)
PY
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    failures=$((failures + 1))
  fi

  for (( i=0; i<NODE_COUNT; i++ )); do
    node_name=$(yq -r ".nodes[${i}].name" "$CONFIG")
    node_ip=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")

    set +e
    artifact="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${node_ip}" "cat /etc/repl-policy.vmids" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      echo "node artifact unreadable on ${node_name} (${node_ip}): /etc/repl-policy.vmids"
      printf '%s\n' "$artifact"
      failures=$((failures + 1))
      continue
    fi

    if ! artifact_on="$(replication_policy_artifact_value "$artifact" POLICY_ON_VMIDS)"; then
      echo "${node_name}: POLICY_ON_VMIDS missing from /etc/repl-policy.vmids"
      failures=$((failures + 1))
    elif [[ "$artifact_on" != "$global_on" ]]; then
      echo "${node_name}: POLICY_ON_VMIDS drift (expected '${global_on}', got '${artifact_on}')"
      failures=$((failures + 1))
    fi

    if ! artifact_off="$(replication_policy_artifact_value "$artifact" POLICY_OFF_VMIDS)"; then
      echo "${node_name}: POLICY_OFF_VMIDS missing from /etc/repl-policy.vmids"
      failures=$((failures + 1))
    elif [[ "$artifact_off" != "$global_off" ]]; then
      echo "${node_name}: POLICY_OFF_VMIDS drift (expected '${global_off}', got '${artifact_off}')"
      failures=$((failures + 1))
    fi

    if ! artifact_cadence="$(replication_policy_artifact_value "$artifact" CADENCE_MAP)"; then
      echo "${node_name}: CADENCE_MAP missing from /etc/repl-policy.vmids"
      failures=$((failures + 1))
    elif [[ "$artifact_cadence" != "$cadence_map" ]]; then
      echo "${node_name}: CADENCE_MAP drift (expected '${cadence_map}', got '${artifact_cadence}')"
      failures=$((failures + 1))
    fi

    if ! artifact_gen="$(replication_policy_artifact_value "$artifact" POLICY_GEN)"; then
      echo "${node_name}: POLICY_GEN missing from /etc/repl-policy.vmids"
      failures=$((failures + 1))
    elif [[ "$artifact_gen" != "$local_gen" ]]; then
      echo "${node_name}: POLICY_GEN drift (expected '${local_gen}', got '${artifact_gen}')"
      failures=$((failures + 1))
    fi
  done

  [[ "$failures" -eq 0 ]]
}

# Read live MemAvailable (kB) from a node via ssh. Echoes the integer on
# success; echoes nothing (empty) if the read failed or the field is absent —
# the caller treats empty as "unreadable" and applies flap resistance.
_failover_fit_read_memavail_kb() {
  local ip="$1" out rc
  set +e
  out="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${ip}" "cat /proc/meminfo" 2>/dev/null)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] && return 0
  # Anchor the whole field (unit + EOL): a trailing-garbage line like
  # "MemAvailable: 123 kBogus" must NOT parse to 123 — it yields empty, which
  # the caller treats as unreadable and fails closed (destruction-safety).
  printf '%s\n' "$out" | sed -n 's/^MemAvailable:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*kB[[:space:]]*$/\1/p' | head -1
}

# Diagnostic only: ZFS ARC reclaimable (size - c_min) in MiB, or "unknown".
# NEVER folded into the pass/fail number.
_failover_fit_arc_reclaimable_mib() {
  local ip="$1" out size cmin rc recl
  set +e
  out="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${ip}" "cat /proc/spl/kstat/zfs/arcstats" 2>/dev/null)"
  rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$out" ]]; then echo "unknown"; return 0; fi
  size="$(printf '%s\n' "$out" | awk '$1=="size"{print $3; exit}')"
  cmin="$(printf '%s\n' "$out" | awk '$1=="c_min"{print $3; exit}')"
  # Guard the arithmetic: a non-numeric arcstats value must degrade to "unknown",
  # never abort the check via set -u/set -e. ARC is diagnostic-only and must NOT
  # be able to change the pass/fail result.
  if [[ ! "$size" =~ ^[0-9]+$ || ! "$cmin" =~ ^[0-9]+$ ]]; then echo "unknown"; return 0; fi
  recl=$(( (size - cmin) / 1024 / 1024 ))
  [[ "$recl" -lt 0 ]] && recl=0
  echo "$recl"
}

# R4 (A4/V4.1) — cicd effective floor fits smallest survivor. FAIL, not WARN.
# Reads effective_floor from `qm config` (balloon>0?balloon:memory), home node
# from config.vms.cicd.node (DECLARED), survivor MemAvailable live. Never reads
# nodes[].ram_gb. Fail-closed on any unreadable input.
cicd_failover_fit_check() {
  local vmid home i node_name node_ip rc
  local reread_delay="${MYCOFU_FAILOVER_FIT_REREAD_DELAY:-2}"

  vmid="$(yq -r '.vms.cicd.vmid' "$CONFIG")"
  home="$(yq -r '.vms.cicd.node' "$CONFIG")"
  if [[ -z "$vmid" || "$vmid" == "null" || -z "$home" || "$home" == "null" ]]; then
    echo "FAIL (fail-closed): cannot read cicd vmid / home node from config"
    return 1
  fi

  # Find a reachable cluster member for the node-status list + qm config.
  # qm config reads the shared /etc/pve cluster fs, so any online node serves it.
  local ctrl_ip="" node_status_json=""
  for (( i=0; i<NODE_COUNT; i++ )); do
    node_ip="$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")"
    set +e
    node_status_json="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${node_ip}" "pvesh get /nodes --output-format json" 2>/dev/null)"
    rc=$?
    set -e
    if [[ $rc -eq 0 && -n "$node_status_json" ]]; then ctrl_ip="$node_ip"; break; fi
    node_status_json=""
  done
  if [[ -z "$ctrl_ip" ]]; then
    echo "FAIL (fail-closed): cannot reach any cluster member to read node status / qm config"
    return 1
  fi

  # effective_floor from qm config <vmid>.
  local qm_cfg mem balloon eff_floor
  set +e
  qm_cfg="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${ctrl_ip}" "qm config ${vmid}" 2>/dev/null)"
  rc=$?
  set -e
  if [[ $rc -ne 0 || -z "$qm_cfg" ]]; then
    echo "FAIL (fail-closed): cannot read 'qm config ${vmid}' (cicd) from ${ctrl_ip}"
    return 1
  fi
  # Anchor to end-of-field: a malformed "memory: 61440x" must fail closed rather
  # than parse to a numeric prefix. An absent or malformed balloon line yields
  # empty -> treated as 0 -> effective_floor widens to memory (the conservative,
  # larger-floor direction).
  mem="$(printf '%s\n' "$qm_cfg" | sed -n 's/^memory:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -1)"
  balloon="$(printf '%s\n' "$qm_cfg" | sed -n 's/^balloon:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' | head -1)"
  if [[ ! "$mem" =~ ^[0-9]+$ ]]; then
    echo "FAIL (fail-closed): 'memory:' missing/unparseable in qm config ${vmid}"
    return 1
  fi
  [[ -z "$balloon" ]] && balloon=0
  if [[ "$balloon" -gt 0 ]]; then eff_floor="$balloon"; else eff_floor="$mem"; fi
  echo "cicd (vmid ${vmid}) effective_floor = ${eff_floor} MiB (memory=${mem}, balloon=${balloon}; balloon>0?balloon:memory)"
  echo "home node (declared, config.vms.cicd.node) = ${home}"

  # Build the explicitly-OFFLINE set (status != "online") from the node status,
  # guarded so a malformed JSON fails closed rather than aborting under set -e.
  # A survivor is classified OFFLINE only when HA/corosync reports it offline —
  # a node merely absent from the list (or online-but-unreadable) is UNKNOWN.
  local offline_nodes="" rc_jq
  set +e
  offline_nodes="$(printf '%s\n' "$node_status_json" | jq -r '.[] | select(.status != "online") | .node' 2>/dev/null)"
  rc_jq=$?
  set -e
  if [[ $rc_jq -ne 0 ]]; then
    echo "FAIL (fail-closed): 'pvesh get /nodes' output from ${ctrl_ip} is unparseable; cannot classify survivor reachability"
    return 1
  fi

  local min_avail="" min_node="" survivor_count=0 home_found=0
  for (( i=0; i<NODE_COUNT; i++ )); do
    node_name="$(yq -r ".nodes[${i}].name" "$CONFIG")"
    node_ip="$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")"
    [[ "$node_name" == "$home" ]] && { home_found=1; continue; }
    survivor_count=$((survivor_count + 1))

    local avail_kb
    avail_kb="$(_failover_fit_read_memavail_kb "$node_ip")"
    if [[ -z "$avail_kb" ]]; then
      sleep "$reread_delay"
      avail_kb="$(_failover_fit_read_memavail_kb "$node_ip")"
    fi
    if [[ -z "$avail_kb" ]]; then
      if printf '%s\n' "$offline_nodes" | grep -qx "$node_name"; then
        echo "FAIL (fail-closed): survivor ${node_name} (${node_ip}) MemAvailable unreadable after re-read — node OFFLINE per HA/corosync. A real node outage reds this deploy check for the outage's duration; accepted, NOT weakened to a WARN."
      else
        echo "FAIL (fail-closed): survivor ${node_name} (${node_ip}) MemAvailable unreadable after re-read — read failed for UNKNOWN reasons (node NOT reported offline by HA/corosync)"
      fi
      return 1
    fi

    local avail_mib=$(( avail_kb / 1024 )) arc_diag
    arc_diag="$(_failover_fit_arc_reclaimable_mib "$node_ip")"
    echo "survivor ${node_name}: MemAvailable=${avail_mib} MiB (ZFS ARC reclaimable ~${arc_diag} MiB; NOT added to the pass/fail number)"
    if [[ -z "$min_avail" || "$avail_mib" -lt "$min_avail" ]]; then
      min_avail="$avail_mib"; min_node="$node_name"
    fi
  done

  if [[ "$home_found" -ne 1 ]]; then
    echo "FAIL (fail-closed): declared cicd home node '${home}' is not present in config nodes[]; cannot determine the survivor set"
    return 1
  fi

  if [[ "$survivor_count" -eq 0 || -z "$min_avail" ]]; then
    echo "FAIL (fail-closed): no survivor nodes (home=${home}); cannot evaluate failover fit"
    return 1
  fi

  echo "min survivor MemAvailable = ${min_avail} MiB (on ${min_node})"
  echo "NECESSARY-not-sufficient: bounds cicd's START-TIME balloon target against the smallest single"
  echo "  survivor. Does NOT model whole-cluster N-1 capacity (#563), steady-state residency after cicd"
  echo "  lands, or the R005 F6 residual (a loaded guest that cannot deflate -> host OOM, bounded by the"
  echo "  demand-side controls, not ballooning). Do not read it as protection it does not provide."

  if [[ "$eff_floor" -le "$min_avail" ]]; then
    echo "OK: effective_floor ${eff_floor} MiB <= min survivor ${min_avail} MiB (${min_node})"
    return 0
  fi
  echo "effective_floor ${eff_floor} MiB EXCEEDS min survivor ${min_avail} MiB (${min_node}): a failover"
  echo "onto ${min_node} would fail to start cicd (or OOM the survivor). Resize cicd's balloon floor to fit."
  return 1
}

if [[ "${MYCOFU_VALIDATE_ONLY_HA_MAINTENANCE:-0}" == "1" ]]; then
  check_warn "no nodes in HA maintenance" ha_maintenance_check
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "${MYCOFU_VALIDATE_ONLY_CICD_FAILOVER_FIT:-0}" == "1" ]]; then
  check_capture "cicd effective floor fits smallest survivor" cicd_failover_fit_check
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "${MYCOFU_VALIDATE_ONLY_PBS_FRESHNESS:-0}" == "1" ]]; then
  run_pbs_backup_freshness_check
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

# Rename-victim cidata detection (#511). The orphan sweep in the Storage
# section only finds cidata-shaped zvols referenced by NO VM config. A rename
# victim is the opposite: a VM config that references vm-<vmid>-disk-<N> where
# it should reference the canonical vm-<vmid>-cloudinit. Proxmox's migrate-back
# name collision (.claude/rules/replication.md) renames a VM's own cidata zvol
# from vm-<vmid>-cloudinit to vm-<vmid>-disk-<N>; the reference stays valid on
# the home node, so the orphan check stays silent (in fact the rename CLEARS
# the orphan WARN). But cloudinit-class zvols are never replicated and PVE's
# regeneration regex only matches the canonical name, so when HA restarts the
# VM on a survivor node the cidata volume neither exists nor can be regenerated:
# "no zvol device link for vm-<vmid>-disk-<N> found after 300 sec". A single
# node failure becomes a multi-VM outage (DRT-005 2026-07-07: 7 VMs, including
# precious-state, left stopped in HA error state). This is FAIL, not WARN, per
# destruction-safety WARN-vs-FAIL doctrine — it silently arms a future outage
# and must stop the line. One SSH to any cluster member sees the whole cluster:
# /etc/pve is corosync-shared (pmxcfs).
cidata_canonical_names_check() {
  local count i node_ip out rc scanned=0 files=""
  local remote line file confline drivekey after volume vol_vmid vmid node
  local -a records=()

  # Remote scan, emitted by whichever cluster member answers first. For each
  # VM config it prints its ACTIVE-config media=cdrom drive lines (grep -H
  # style: <path>:<line>), then a "__SCAN_FILES__ <n>" count, then a sentinel.
  # Notes on robustness (folded in from adversarial review):
  #   * awk '/^\[/{exit}' stops at the first [snapshot] header, so a victim
  #     reference frozen inside a snapshot section — which the realignment
  #     steps below cannot fix — does not produce an unclearable FAIL.
  #   * the ^(ide|sata|scsi|virtio)<N>: anchor matches only real drive keys,
  #     never a description: line that merely contains "media=cdrom".
  #   * the file count lets us fail closed if the glob did not expand (pmxcfs
  #     unmounted => zero configs read => we cannot prove the cluster clean).
  #   * the sentinel distinguishes a completed scan from a truncated one.
  # Outer double quotes let the awk program keep its own single quotes.
  remote="n=0; for f in /etc/pve/nodes/*/qemu-server/*.conf; do [ -e \"\$f\" ] || continue; n=\$((n+1)); awk '/^\\[/{exit} /^(ide|sata|scsi|virtio)[0-9]+:.*media=cdrom/{print FILENAME\":\"\$0}' \"\$f\"; done; echo \"__SCAN_FILES__ \$n\"; echo __SCAN_DONE__"

  # /etc/pve is corosync-shared, so ANY reachable member returns the whole
  # cluster view — one successful SSH suffices. Try members in order and stop
  # at the first that answers; only fail closed if none do (mirrors
  # cleanup-orphan-cidata.sh, and avoids a spurious FAIL when nodes[0] is the
  # very node that just died — the scenario this check guards against).
  # SSH_OPTS_ARGS carries -o LogLevel=ERROR so the host-key warning is not
  # emitted; stderr is additionally discarded so no residual noise can
  # contaminate the parsed drive lines (#506/#507).
  count=$(yq -r '.nodes | length' "$CONFIG")
  for (( i=0; i<count; i++ )); do
    node_ip=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    set +e
    out=$(ssh "${SSH_OPTS_ARGS[@]}" "root@${node_ip}" "$remote" 2>/dev/null)
    rc=$?
    set -e
    if [[ "$rc" -eq 0 ]] && grep -qx '__SCAN_DONE__' <<< "$out"; then
      scanned=1
      break
    fi
  done

  # Fail closed: an unreachable cluster or a truncated scan cannot prove the
  # cluster is clean (destruction-safety: unknown state => FAIL, not SKIP).
  if [[ "$scanned" -ne 1 ]]; then
    echo "could not scan cidata drive names on any of ${count} cluster member(s)"
    echo "FAIL (fail-closed): cannot confirm every cidata drive uses its canonical name"
    printf '%s\n' "$out"
    return 1
  fi

  files=$(sed -n 's/^__SCAN_FILES__ \([0-9][0-9]*\)$/\1/p' <<< "$out" | head -1)
  if [[ -z "$files" || "$files" -eq 0 ]]; then
    echo "cidata scan read 0 VM configs from /etc/pve (pmxcfs unmounted?)"
    echo "FAIL (fail-closed): cannot confirm cidata names on an unreadable config tree"
    printf '%s\n' "$out"
    return 1
  fi

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      __SCAN_DONE__|__SCAN_FILES__*) continue ;;
    esac
    # Remote line shape (grep -H style):
    #   /etc/pve/nodes/<node>/qemu-server/<vmid>.conf:<key>: <storage>:<volid>,media=cdrom,...
    file="${line%%.conf:*}.conf"
    confline="${line#*.conf:}"
    drivekey="${confline%%:*}"
    after="${confline#*:}"
    after="${after#"${after%%[![:space:]]*}"}"   # strip leading whitespace
    volume="${after%%,*}"
    vmid="${file##*/}"; vmid="${vmid%.conf}"
    node="${file#/etc/pve/nodes/}"; node="${node%%/*}"
    # A rename victim is THIS VM's own cidata renamed vm-<vmid>-cloudinit ->
    # vm-<vmid>-disk-<N>: data-pool-backed, disk-shaped, SAME VMID as the
    # config. Canonical -cloudinit, ISO cdroms (local:iso/...), empty cdroms
    # (none), and a stray other-VMID cross-attach are not this defect. The
    # STORAGE_POOL is quoted so a pool name with a regex metacharacter is
    # matched literally; the VMID capture group stays unquoted.
    if [[ "$volume" =~ ^"${STORAGE_POOL}":vm-([0-9]+)-disk-[0-9]+$ ]]; then
      vol_vmid="${BASH_REMATCH[1]}"
      if [[ "$vol_vmid" == "$vmid" ]]; then
        echo "rename-victim cidata: VM ${vmid} on ${node} drive ${drivekey} -> ${volume}"
        records+=("${vmid}|${node}|${drivekey}")
      fi
    fi
  done <<< "$out"

  if [[ "${#records[@]}" -eq 0 ]]; then
    return 0
  fi

  local rec r_vmid r_node r_key
  echo ""
  echo "${#records[@]} VM(s) reference a non-canonical (rename-victim) cidata volume."
  echo "These cloudinit-class zvols are unreplicated and cannot be regenerated"
  echo "off-node; an HA restart on a survivor node fails with"
  echo "'no zvol device link for vm-<vmid>-disk-<N>' (DRT-005 2026-07-07)."
  echo ""
  echo "Sanctioned realignment (framework/scripts/realign-cidata.sh; see"
  echo ".claude/rules/replication.md), per affected VM:"
  for rec in "${records[@]}"; do
    IFS='|' read -r r_vmid r_node r_key <<< "$rec"
    echo "  VM ${r_vmid} (${r_node}):"
    echo "    framework/scripts/realign-cidata.sh --dry-run --vmid ${r_vmid}   # inspect"
    echo "    framework/scripts/realign-cidata.sh --vmid ${r_vmid}             # repair + sweep orphan"
  done
  echo ""
  echo "realign-cidata.sh is state-aware (running VM: live hot-swap; stopped/HA-error:"
  echo "the storage-fence 6A ladder), uses the pinned allocate-form command, and sweeps"
  echo "the now-orphan victim itself. Then re-validate:"
  echo "  framework/scripts/validate.sh"
  echo ""
  echo "See .claude/rules/replication.md and issue #512 (prevention/realign tooling)."
  return 1
}

dns_antiaffinity_colocation_check() {
  local first_node_ip out rc crs_mode rules_json resources_json
  local envs env dns1_vmid dns2_vmid rule_ok dns1_node dns2_node healthy_count
  local failures=0

  first_node_ip="$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")"

  set +e
  out="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${first_node_ip}" \
    "pvesh get /cluster/options --output-format json" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "failed to read CRS mode from ${first_node_ip}; rc=${rc}"
    printf '%s\n' "$out"
    return 1
  fi
  if ! crs_mode="$(jq -r '.crs.ha // .crs // "unset(default static)"' <<< "$out" 2>/dev/null)"; then
    echo "failed to parse CRS mode JSON from ${first_node_ip}"
    printf '%s\n' "$out"
    return 1
  fi
  echo "CRS mode: ${crs_mode} (static scores on configured memory - #509)"

  set +e
  rules_json="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${first_node_ip}" \
    "pvesh get /cluster/ha/rules --output-format json" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "failed to read HA rules from ${first_node_ip}; rc=${rc}"
    printf '%s\n' "$rules_json"
    return 1
  fi
  if ! jq -e 'type == "array"' <<< "$rules_json" >/dev/null 2>&1; then
    echo "failed to parse HA rules JSON from ${first_node_ip}"
    printf '%s\n' "$rules_json"
    return 1
  fi

  set +e
  resources_json="$(ssh "${SSH_OPTS_ARGS[@]}" "root@${first_node_ip}" \
    "pvesh get /cluster/resources --output-format json" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    echo "failed to read cluster resources from ${first_node_ip}; rc=${rc}"
    printf '%s\n' "$resources_json"
    return 1
  fi
  if ! jq -e 'type == "array"' <<< "$resources_json" >/dev/null 2>&1; then
    echo "failed to parse cluster resources JSON from ${first_node_ip}"
    printf '%s\n' "$resources_json"
    return 1
  fi

  if ! envs="$(yq -r '.vms | keys | .[]' "$CONFIG" 2>/dev/null | sed -n 's/^dns1_//p' | sort -u)"; then
    echo "failed to discover DNS environments from ${CONFIG}"
    return 1
  fi

  while IFS= read -r env; do
    [[ -z "$env" ]] && continue

    # Honor the validate.sh run scope (validate.sh <env>). The per-env
    # anti-affinity rule is created by that env's own deploy
    # (proxmox_virtual_environment_harule "dns-${env}-antiaffinity" in the
    # dns-pair module), so a dev-scoped run must not require the prod rule that
    # only the prod deploy creates — otherwise every dev pipeline is red until
    # prod promotion (#513). A no-arg run keeps the default (prod dev) scope.
    [[ " ${ENVS[*]} " == *" ${env} "* ]] || continue

    # yq is mikefarah/yq (v4): the jq `// empty` idiom is not valid here and
    # aborts the lexer ("invalid input text \"empty\""). Use `// ""` and guard
    # the substitution so a genuine parse failure fails this check closed with
    # a clear message instead of crashing mid-pipe under `set -e` (#513).
    if ! dns1_vmid="$(yq -r ".vms.dns1_${env}.vmid // \"\"" "$CONFIG" 2>/dev/null)"; then
      echo "failed to read dns1_${env} vmid from ${CONFIG} (yq parse error)"
      failures=$((failures + 1))
      continue
    fi
    if ! dns2_vmid="$(yq -r ".vms.dns2_${env}.vmid // \"\"" "$CONFIG" 2>/dev/null)"; then
      echo "failed to read dns2_${env} vmid from ${CONFIG} (yq parse error)"
      failures=$((failures + 1))
      continue
    fi
    if [[ -z "$dns1_vmid" || -z "$dns2_vmid" || "$dns1_vmid" == "null" || "$dns2_vmid" == "null" ]]; then
      echo "dns pair vmids missing for env ${env}"
      failures=$((failures + 1))
      continue
    fi

    if jq -e \
      --arg dns1 "vm:${dns1_vmid}" \
      --arg dns2 "vm:${dns2_vmid}" \
      'any(.[]; .type == "resource-affinity" and .affinity == "negative" and ((.resources // []) | index($dns1)) and ((.resources // []) | index($dns2)))' \
      <<< "$rules_json" >/dev/null 2>&1; then
      rule_ok=1
    else
      rule_ok=0
    fi
    if [[ "$rule_ok" -ne 1 ]]; then
      echo "anti-affinity rule missing for env ${env} (vm:${dns1_vmid},vm:${dns2_vmid})"
      failures=$((failures + 1))
    fi

    dns1_node="$(jq -r --arg vmid "$dns1_vmid" '.[] | select(.type == "qemu" and (.vmid | tostring) == $vmid) | .node' <<< "$resources_json" | head -1)"
    dns2_node="$(jq -r --arg vmid "$dns2_vmid" '.[] | select(.type == "qemu" and (.vmid | tostring) == $vmid) | .node' <<< "$resources_json" | head -1)"
    if [[ -z "$dns1_node" || -z "$dns2_node" || "$dns1_node" == "null" || "$dns2_node" == "null" ]]; then
      continue
    fi

    healthy_count="$(jq -r '[.[] | select(.type == "node" and .status == "online") | .node] | unique | length' <<< "$resources_json")"
    if [[ "$dns1_node" == "$dns2_node" && "$healthy_count" -ge 2 ]]; then
      echo "dns pair co-located on ${dns1_node} while ${healthy_count} nodes healthy"
      failures=$((failures + 1))
    fi
  done <<< "$envs"

  [[ "$failures" -eq 0 ]]
}

if [[ "${MYCOFU_VALIDATE_ONLY_CIDATA_RENAME:-0}" == "1" ]]; then
  check_capture "cidata drive names are canonical (no rename victims)" \
    cidata_canonical_names_check
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

if [[ "${MYCOFU_VALIDATE_ONLY_ANTIAFFINITY:-0}" == "1" ]]; then
  check_capture "dns pair anti-affinity healthy-node-aware" \
    dns_antiaffinity_colocation_check
  if [[ "$FAIL" -gt 0 ]]; then
    exit 1
  fi
  exit 0
fi

gitlab_live_issuer_check() {
  # Check the cert the TLS listener actually serves, not the on-disk file.
  # This tests the real trust path (what the runner and clients see) and
  # avoids SSH + openssl PATH issues on NixOS VMs (#177).
  local issuer
  issuer=$(echo | openssl s_client -connect "${GITLAB_IP}:443" \
    -servername "gitlab.prod.${DOMAIN}" 2>/dev/null \
    | openssl x509 -noout -issuer 2>/dev/null || true)

  if [[ -z "${issuer}" ]]; then
    echo "gitlab.prod.${DOMAIN}: issuer unavailable via TLS connection to ${GITLAB_IP}:443"
    return 1
  fi

  echo "gitlab.prod.${DOMAIN}: ${issuer}"
  # LE staging certs use "(STAGING)" in issuer, not "Fake LE"
  [[ "${issuer}" != *"Fake LE"* && "${issuer}" != *"STAGING"* ]]
}

tls_cert_ready() {
  local endpoint_ip="$1"
  local endpoint_port="$2"
  local endpoint_fqdn="$3"

  echo | timeout 5 openssl s_client \
    -connect "${endpoint_ip}:${endpoint_port}" \
    -servername "${endpoint_fqdn}" 2>/dev/null \
    | openssl x509 -noout -checkend 0 >/dev/null 2>&1
}

wait_for_certs() {
  local timeout="${CERT_WAIT_TIMEOUT:-600}"
  local poll_interval=15
  local start_time
  local entry monitor_name vm_label endpoint_ip endpoint_port endpoint_fqdn
  local elapsed pending next_pending
  local records=()
  local failures=0

  if ! [[ "${timeout}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: CERT_WAIT_TIMEOUT must be an integer number of seconds; got '${timeout}'." >&2
    return 2
  fi

  while IFS=$'\t' read -r monitor_name vm_label endpoint_ip endpoint_port endpoint_fqdn; do
    [[ -z "${monitor_name}" ]] && continue
    records+=("${monitor_name}"$'\t'"${vm_label}"$'\t'"${endpoint_ip}"$'\t'"${endpoint_port}"$'\t'"${endpoint_fqdn}")
  done < <(certbot_cluster_gatus_cert_monitor_records "${CONFIG}" "${APPS_CONFIG}" "${REPO_DIR}")

  if [[ "${#records[@]}" -eq 0 ]]; then
    echo "No Gatus certificate monitors in scope; skipping cert readiness wait."
    return 0
  fi

  echo "Waiting for Gatus certificate endpoints (timeout: ${timeout}s)..."

  pending=()
  for entry in "${records[@]}"; do
    IFS=$'\t' read -r monitor_name vm_label endpoint_ip endpoint_port endpoint_fqdn <<< "${entry}"
    if tls_cert_ready "${endpoint_ip}" "${endpoint_port}" "${endpoint_fqdn}"; then
      continue
    fi
    pending+=("${entry}")
    echo "  Waiting for cert on ${vm_label} (${endpoint_ip}:${endpoint_port}, ${endpoint_fqdn})..."
  done

  if [[ "${#pending[@]}" -eq 0 ]]; then
    echo "  All Gatus certificate endpoints are ready."
    return 0
  fi

  start_time=$(date +%s)

  while true; do
    elapsed=$(( $(date +%s) - start_time ))
    if [[ "${elapsed}" -ge "${timeout}" ]]; then
      break
    fi

    sleep "${poll_interval}"

    next_pending=()
    for entry in "${pending[@]}"; do
      IFS=$'\t' read -r monitor_name vm_label endpoint_ip endpoint_port endpoint_fqdn <<< "${entry}"
      if tls_cert_ready "${endpoint_ip}" "${endpoint_port}" "${endpoint_fqdn}"; then
        elapsed=$(( $(date +%s) - start_time ))
        echo "  ${vm_label} is serving TLS after ${elapsed}s."
      else
        next_pending+=("${entry}")
      fi
    done

    if [[ "${#next_pending[@]}" -eq 0 ]]; then
      echo "  All Gatus certificate endpoints are ready."
      return 0
    fi

    pending=("${next_pending[@]}")
  done

  for entry in "${pending[@]}"; do
    IFS=$'\t' read -r monitor_name vm_label endpoint_ip endpoint_port endpoint_fqdn <<< "${entry}"
    elapsed=$(( $(date +%s) - start_time ))
    if tls_cert_ready "${endpoint_ip}" "${endpoint_port}" "${endpoint_fqdn}"; then
      echo "ERROR: cert appeared on ${vm_label} (${endpoint_ip}:${endpoint_port}, ${endpoint_fqdn}) but took ${elapsed}s (timeout was ${timeout}s) — raise CERT_WAIT_TIMEOUT." >&2
    else
      echo "ERROR: cert never appeared on ${vm_label} (${endpoint_ip}:${endpoint_port}, ${endpoint_fqdn}) after ${elapsed}s — check certbot-initial logs on the VM." >&2
    fi
    failures=$((failures + 1))
  done

  [[ "${failures}" -eq 0 ]]
}

field_from_probe_output() {
  local output="$1"
  local key="$2"
  awk -F '=' -v key="$key" '$1 == key { sub(/^[^=]*=/, "", $0); print; exit }' <<< "$output"
}

certbot_env_records() {
  local env_name=""
  for env_name in "${ENVS[@]}"; do
    certbot_cluster_cert_storage_records "${CONFIG}" "${APPS_CONFIG}" "${env_name}"
  done | sort -u
}

certbot_renewability_validate_check() {
  local records=""
  local vm_label module_name vm_ip vmid fqdn kind
  local output rc reason days near
  local failures=0
  local unknowns=0
  local checked=0

  records="$(certbot_env_records)"
  if [[ -z "$records" ]]; then
    echo "No config-derived certbot runtime VMs in scope."
    return 0
  fi

  while IFS=$'\t' read -r vm_label module_name vm_ip vmid fqdn kind; do
    [[ -z "$vm_label" ]] && continue
    checked=$((checked + 1))
    set +e
    output="$(certbot_cluster_run_remote_renewability_probe "$vm_ip" "$fqdn" 2>&1)"
    rc=$?
    set -e
    reason="$(field_from_probe_output "$output" "reason")"
    days="$(field_from_probe_output "$output" "days_remaining")"
    near="$(field_from_probe_output "$output" "near_expiry")"
    case "$rc" in
      0)
        echo "${vm_label} (${fqdn}): OK days_remaining=${days:-unknown} near_expiry=${near:-unknown}"
        ;;
      1)
        echo "${vm_label} (${fqdn}): BROKEN reason=${reason:-cert-unrenewable}"
        failures=$((failures + 1))
        ;;
      3)
        echo "${vm_label} (${fqdn}): UNKNOWN reason=${reason:-probe-unknowable}"
        unknowns=$((unknowns + 1))
        ;;
      255)
        echo "${vm_label} (${fqdn}): UNKNOWN reason=vm-unreachable"
        unknowns=$((unknowns + 1))
        ;;
      *)
        echo "${vm_label} (${fqdn}): UNKNOWN reason=predicate-rc-${rc}"
        unknowns=$((unknowns + 1))
        ;;
    esac
  done <<< "$records"

  echo "Checked ${checked} certbot runtime VM(s)."
  if [[ "$failures" -gt 0 ]]; then
    return 1
  fi
  if [[ "$unknowns" -gt 0 ]]; then
    return 3
  fi
  return 0
}

certbot_current_hook_resolve_check() {
  local records=""
  local vm_label module_name vm_ip vmid fqdn kind
  local output rc
  local failures=0
  local unknowns=0
  local checked=0

  records="$(certbot_env_records)"
  if [[ -z "$records" ]]; then
    echo "No config-derived certbot runtime VMs in scope."
    return 0
  fi

  while IFS=$'\t' read -r vm_label module_name vm_ip vmid fqdn kind; do
    [[ -z "$vm_label" ]] && continue
    checked=$((checked + 1))
    set +e
    output="$(ssh ${SSH_OPTS} "root@${vm_ip}" 'set -euo pipefail
      set +e
      unit="$(systemctl cat certbot-renew.service 2>&1)"
      unit_rc=$?
      set -e
      if [ "$unit_rc" -ne 0 ]; then
        echo "reason=renew-unit-cat-failed rc=$unit_rc"
        exit 3
      fi

      set +e
      exec_path="$(printf "%s\n" "$unit" | awk -F= '"'"'/^ExecStart=/ { print $2; exit }'"'"' | awk '"'"'{ print $1 }'"'"')"
      exec_rc=$?
      set -e
      if [ "$exec_rc" -ne 0 ]; then
        echo "reason=renew-unit-execstart-parse-failed rc=$exec_rc"
        exit 3
      fi
      if [ -z "$exec_path" ] || [ ! -r "$exec_path" ]; then
        echo "reason=renew-unit-execstart-unreadable"
        exit 3
      fi

      extract_hook_path() {
        flag="$1"
        set +e
        hook_path="$(grep -oE -- "${flag}[[:space:]]+\"?[^\"]+\"?" "$exec_path" | head -1 | sed -E "s/^${flag}[[:space:]]+//; s/^\"//; s/\"$//")"
        hook_rc=$?
        set -e
        if [ "$hook_rc" -ne 0 ] || [ -z "$hook_path" ]; then
          return 1
        fi
        printf "%s\n" "$hook_path"
      }

      if ! auth_path="$(extract_hook_path "--manual-auth-hook")"; then
        echo "reason=manual-auth-hook-missing-from-renew-script"
        exit 1
      fi
      if ! cleanup_path="$(extract_hook_path "--manual-cleanup-hook")"; then
        echo "reason=manual-cleanup-hook-missing-from-renew-script"
        exit 1
      fi
      if [ ! -x "$auth_path" ]; then
        echo "reason=auth-hook-not-executable path=$auth_path"
        exit 1
      fi
      if [ ! -x "$cleanup_path" ]; then
        echo "reason=cleanup-hook-not-executable path=$cleanup_path"
        exit 1
      fi
      echo "auth_hook=$auth_path"
      echo "cleanup_hook=$cleanup_path"
    ' 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq 255 && "$output" != *"reason="* ]]; then
      if [[ -n "$output" ]]; then
        output="${output}"$'\n'"reason=vm-unreachable"
      else
        output="reason=vm-unreachable"
      fi
    fi
    case "$rc" in
      0)
        echo "${vm_label} (${fqdn}): hooks OK"
        print_check_output "$output"
        ;;
      3|255)
        echo "${vm_label} (${fqdn}): UNKNOWN"
        print_check_output "$output"
        unknowns=$((unknowns + 1))
        ;;
      *)
        echo "${vm_label} (${fqdn}): BROKEN"
        print_check_output "$output"
        failures=$((failures + 1))
        ;;
    esac
  done <<< "$records"

  echo "Checked ${checked} certbot renew unit(s)."
  if [[ "$failures" -gt 0 ]]; then
    return 1
  fi
  if [[ "$unknowns" -gt 0 ]]; then
    return 3
  fi
  return 0
}

# =====================================================================
# Regression Deploy: destroy dev VMs and redeploy before validation
# =====================================================================
if [[ "$REGRESSION_DEPLOY" -eq 1 ]]; then
  echo ""
  echo "=== Regression Deploy: Destroy + Redeploy Dev VMs ==="
  echo ""
  echo "This test destroys selected dev VMs and redeploys them from the"
  echo "current code to verify the deploy path works end-to-end."
  echo ""

  FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
  # dns-pair module manages both dns1 and dns2 together — must destroy both
  DEPLOY_TARGETS="testapp_dev dns1_dev dns2_dev vault_dev"

  # Destroy selected dev VMs
  for vm in $DEPLOY_TARGETS; do
    VMID=$(yq -r ".vms.${vm}.vmid" "$CONFIG")
    VM_IP=$(yq -r ".vms.${vm}.ip" "$CONFIG")
    echo "  Destroying ${vm} (VMID ${VMID})..."
    # Find hosting node
    HOSTING_NODE=$(ssh "${SSH_OPTS_ARGS[@]}" "root@${FIRST_NODE_IP}" \
      "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
      | python3 -c "
import sys,json
for v in json.loads(sys.stdin.read()):
    if v.get('vmid') == ${VMID}: print(v['node']); break
" 2>/dev/null || true)
    if [[ -z "$HOSTING_NODE" ]]; then
      echo "    WARNING: VM ${vm} not found in cluster — skipping destroy"
      continue
    fi
    HOSTING_IP=$(yq -r ".nodes[] | select(.name == \"${HOSTING_NODE}\") | .mgmt_ip" "$CONFIG")
    # Remove HA, stop, destroy
    ssh "${SSH_OPTS_ARGS[@]}" "root@${HOSTING_IP}" "ha-manager remove vm:${VMID}" 2>/dev/null || true
    ssh "${SSH_OPTS_ARGS[@]}" "root@${HOSTING_IP}" "qm stop ${VMID} --skiplock" 2>/dev/null || true
    sleep 3
    ssh "${SSH_OPTS_ARGS[@]}" "root@${HOSTING_IP}" "qm destroy ${VMID} --skiplock --purge" 2>/dev/null || true
    echo "    Destroyed ${vm}"
    ssh-keygen -R "$VM_IP" 2>/dev/null || true
  done

  # Remove destroyed VMs from tofu state so tofu recreates them.
  # tofu-wrapper.sh handles SOPS_AGE_KEY_FILE discovery (env, repo, XDG).
  echo ""
  echo "  Removing destroyed VMs from tofu state..."
  cd "${REPO_DIR}"
  "${SCRIPT_DIR}/tofu-wrapper.sh" init -input=false >/dev/null 2>&1
  for vm in $DEPLOY_TARGETS; do
    # Map config key to tofu module name
    case "$vm" in
      dns1_dev|dns2_dev) MODULE="module.dns_dev" ;;
      vault_dev)         MODULE="module.vault_dev" ;;
      testapp_dev)       MODULE="module.testapp_dev" ;;
      *)                 MODULE="module.${vm}" ;;
    esac
    "${SCRIPT_DIR}/tofu-wrapper.sh" state rm "${MODULE}" 2>/dev/null || true
    echo "    Removed ${MODULE} from state"
  done

  # Redeploy with tofu apply (targeted)
  echo ""
  echo "  Redeploying destroyed VMs..."
  TARGETS=""
  for vm in $DEPLOY_TARGETS; do
    case "$vm" in
      dns1_dev|dns2_dev) TARGETS="$TARGETS -target=module.dns_dev" ;;
      vault_dev)         TARGETS="$TARGETS -target=module.vault_dev" ;;
      testapp_dev)       TARGETS="$TARGETS -target=module.testapp_dev" ;;
      *)                 TARGETS="$TARGETS -target=module.${vm}" ;;
    esac
  done
  # Deduplicate targets
  TARGETS=$(echo "$TARGETS" | tr ' ' '\n' | sort -u | tr '\n' ' ')
  "${SCRIPT_DIR}/tofu-wrapper.sh" apply $TARGETS -auto-approve -input=false
  echo "  Tofu apply complete"

  # Wait for VMs to boot and initialize
  echo ""
  echo "  Waiting for VMs to initialize..."
  for vm in $DEPLOY_TARGETS; do
    VM_IP=$(yq -r ".vms.${vm}.ip" "$CONFIG")
    echo -n "    ${vm} (${VM_IP}): "
    for attempt in $(seq 1 30); do
      if ssh -n -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 \
           -o BatchMode=yes "root@${VM_IP}" "true" 2>/dev/null; then
        echo "up (${attempt}0s)"
        break
      fi
      sleep 10
    done
  done

  # Wait for certificates (vault and dns need certs before being fully functional)
  echo "  Waiting for certificates..."
  sleep 30

  # Initialize and configure Vault if it was recreated.
  if echo "$DEPLOY_TARGETS" | grep -q "vault_dev"; then
    echo "  Initializing vault-dev..."
    if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]]; then
      if [[ -f "${REPO_DIR}/operator.age.key" ]]; then
        export SOPS_AGE_KEY_FILE="${REPO_DIR}/operator.age.key"
      fi
    fi
    "${SCRIPT_DIR}/init-vault.sh" dev 2>&1 | tail -1
    "${SCRIPT_DIR}/configure-vault.sh" dev 2>&1 | tail -1
  fi

  # Configure replication for recreated VMs.
  #
  # #535: do NOT swallow configure-replication.sh's stdout/stderr/exit. The
  # #502 wait block now fails loudly when a newly-created replication job
  # never confirms a successful initial sync, and emits per-job State
  # diagnostics on stderr. Muting `>/dev/null 2>&1 || true` hides both the
  # signal and the diagnostics from the operator. Surface the output and
  # emit a plain diagnostic line on non-zero — R2.6 downstream remains the
  # authoritative FAIL for the underlying condition, so this call itself
  # must not exit the script (this is still the deploy helper phase).
  #
  # The diagnostic deliberately does NOT use a `[WARN]` prefix: this
  # script has a distinct WARN counter (see check_warn) and a raw echo
  # with `[WARN]` would not be counted there, creating an inconsistency
  # in the summary. R2.6 owns the FAIL classification; this line is a
  # pointer, not a proper safety warning.
  echo "  Configuring replication..."
  # Sprint 047 review-round P1 (codex + agy + sub-claude, consensus).
  # --regression-deploy is dev-only by argument guard (see :83-85), so the
  # configure-replication call MUST forward --env dev. Without --env, MR-3's
  # unscoped-workstation path prunes ALL policy-off replicas cluster-wide,
  # including prod (gatus/404, testapp_prod/600, grafana_prod/602). That
  # would defeat the S1 two-derivation contract and destroy prod state from
  # a dev regression run.
  set +e
  "${SCRIPT_DIR}/configure-replication.sh" "*" --env dev
  CONFIGURE_REPL_RC=$?
  set -e
  if [[ "$CONFIGURE_REPL_RC" -ne 0 ]]; then
    echo "  configure-replication.sh: returned non-zero (rc=${CONFIGURE_REPL_RC}) — see R2.6 replication health check below."
  fi

  echo ""
  echo "  Deploy phase complete. Proceeding with validation..."
  echo ""
fi

# =====================================================================
echo "=== Network ==="
# =====================================================================

# Node SSH reachability
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
  NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
  check "${NODE_NAME} reachable via SSH" \
    ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${NODE_IP}" "true"
done

# Environment gateway ping
for ENV in "${ENVS[@]}"; do
  GW=$(yq -r ".environments.${ENV}.gateway" "$CONFIG")
  check "${ENV} gateway (${GW}) pingable" ping -c 1 -W 3 "$GW"
done

# =====================================================================
echo ""
echo "=== HA ==="
# =====================================================================

check_warn "no nodes in HA maintenance" ha_maintenance_check
# R4 (A4/V4.1) — cicd effective floor must fit the smallest survivor. FAIL, not
# WARN (destruction-safety). NECESSARY-not-sufficient: whole-cluster N-1 is #563.
# RED against today's fixed 24576/balloon:0 cicd BY DESIGN — goes green only
# after M2 resizes cicd to its balloon floor.
check_capture "cicd effective floor fits smallest survivor" cicd_failover_fit_check

# =====================================================================
echo ""
echo "=== Storage ==="
# =====================================================================

check "configure-node-storage.sh --verify" \
  "${SCRIPT_DIR}/configure-node-storage.sh" --verify --all

# ZFS replication health (via repl-health endpoints)
# Replication may still be syncing after a deploy that recreated VMs.
# Retry for up to 2 minutes before declaring stale.
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
  NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
  check "${NODE_NAME} replication not stale" \
    bash -c "
      for attempt in \$(seq 1 12); do
        if curl -sf http://${NODE_IP}:${HEALTH_PORT}/ | jq -e '.replication_stale == false' >/dev/null 2>&1; then
          exit 0
        fi
        [ \$attempt -lt 12 ] && sleep 10
      done
      echo 'Still stale after 2 minutes' >&2
      exit 1
    "
  # Data pool is required; rpool is optional (ext4/LVM boot drives don't have it)
  check "${NODE_NAME} ZFS pools healthy" \
    bash -c "curl -sf http://${NODE_IP}:${HEALTH_PORT}/ | jq -e --arg pool '${STORAGE_POOL}' '.zfs_pools[\$pool] == \"healthy\" and (.zfs_pools.rpool == null or .zfs_pools.rpool == \"healthy\")'"
done

check_capture "replication policy conformance" replication_policy_conformance_check

# Cidata orphan detection — surface "did the operator forget to run
# cleanup-orphan-cidata.sh after a migration?" as a structural signal,
# not a memory test. WARN (not FAIL) because orphan presence is not a
# functional outage; it's a sign that the next migration-back could
# rename a cidata zvol and silently freeze its content. See #417 and
# .claude/rules/replication.md.
cidata_orphans_check() {
  local out rc
  set +e
  out=$("${SCRIPT_DIR}/cleanup-orphan-cidata.sh" --dry-run 2>&1)
  rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "cleanup-orphan-cidata.sh --dry-run exited rc=${rc}"
    echo "${out}"
    return 1
  fi

  # Summary line shape: "Summary (dry-run): N orphan(s) found, 0 destroyed"
  local count
  count=$(printf '%s\n' "${out}" \
    | grep -oE '[0-9]+ orphan\(s\) found' \
    | head -1 \
    | awk '{print $1}')

  if [[ -z "${count}" ]]; then
    echo "could not parse orphan count from cleanup-orphan-cidata.sh"
    echo "${out}"
    return 1
  fi

  if [[ "${count}" -eq 0 ]]; then
    return 0
  fi

  echo "${count} cidata-shaped orphan zvol(s) found cluster-wide"
  printf '%s\n' "${out}" | grep -E '^\s*orphan:' || true
  echo ""
  echo "Run framework/scripts/cleanup-orphan-cidata.sh to destroy them"
  echo "(or --dry-run --verbose for more detail)."
  return 3
}
check_warn "no orphan cidata zvols cluster-wide" cidata_orphans_check

# Rename-victim cidata detection (#511) — FAIL, not WARN. Complements the
# orphan check above: catches cloudinit-class volumes that ARE referenced by a
# config but under the non-canonical vm-<vmid>-disk-<N> name. See the function
# definition near the top of this file for the full failure-mode rationale.
check_capture "cidata drive names are canonical (no rename victims)" \
  cidata_canonical_names_check

check_capture "dns pair anti-affinity healthy-node-aware" \
  dns_antiaffinity_colocation_check

vdb_park_bridge_enabled_any() {
  yq -r '.environments // {} | to_entries[] | select(.value.vdb_park_bridge == true) | .key' "$CONFIG" 2>/dev/null \
    | grep -q .
}

parked_vdb_zvols_check() {
  local node_name node_ip rows rc parks park vmid found=0

  for (( i=0; i<NODE_COUNT; i++ )); do
    node_name=$(yq -r ".nodes[${i}].name" "$CONFIG")
    node_ip=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    set +e
    rows=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${node_ip}" "zfs list -H -o name -r ${STORAGE_POOL}/data 2>/dev/null" 2>&1)
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
      echo "failed to scan parked vdb zvols on ${node_name} (${node_ip}); rc=${rc}"
      echo "${rows}"
      return 1
    fi
    parks="$(printf '%s\n' "$rows" | grep '/mycofu-park-[0-9][0-9]*-vdb$' || true)"
    while IFS= read -r park; do
      [[ -z "$park" ]] && continue
      vmid="$(sed -n 's|.*/mycofu-park-\([0-9][0-9]*\)-vdb$|\1|p' <<< "$park")"
      echo "parked vdb remains on ${node_name}: ${park}"
      echo "Inspect/recover first: framework/scripts/parked-vdb.sh inspect ${vmid}"
      echo "Release only after accepting freshness loss: framework/scripts/parked-vdb.sh release ${vmid}"
      found=1
    done <<< "$parks"
  done

  [[ "$found" -eq 0 ]] && return 0
  return 3
}
check_warn "no parked vdb zvols cluster-wide" parked_vdb_zvols_check

qemu_server_version_ratchet_check() {
  local node_name node_ip version rc drift=0

  if ! vdb_park_bridge_enabled_any; then
    return 0
  fi

  for (( i=0; i<NODE_COUNT; i++ )); do
    node_name=$(yq -r ".nodes[${i}].name" "$CONFIG")
    node_ip=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    set +e
    version=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR \
      "root@${node_ip}" "dpkg-query -W -f='\${Version}' qemu-server 2>/dev/null" 2>&1)
    rc=$?
    set -e
    if [[ "$rc" -ne 0 || -z "$version" ]]; then
      echo "failed to query qemu-server version on ${node_name} (${node_ip}); rc=${rc}"
      echo "${version}"
      return 1
    fi
    if ! vdb_park_version_allowed "$version"; then
      echo "${node_name}: qemu-server ${version} is outside Sprint 044 verified baseline ${VDB_PARK_VERIFIED_QEMU_SERVER}"
      echo "Re-run docs/research/RESEARCH-004 gated experiment before trusting vdb park/adopt on this version."
      drift=1
    fi
  done

  [[ "$drift" -eq 0 ]] && return 0
  return 3
}
check_warn "qemu-server versions remain on vdb park verified baseline" qemu_server_version_ratchet_check

# =====================================================================
echo ""
echo "=== DNS ==="
# =====================================================================

for ENV in "${ENVS[@]}"; do
  DNS_DOMAIN="${ENV}.$(yq -r '.domain' "$CONFIG")"
  DNS1_IP=$(yq -r ".vms.dns1_${ENV}.ip" "$CONFIG")
  DNS2_IP=$(yq -r ".vms.dns2_${ENV}.ip" "$CONFIG")
  VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")

  check "dns1-${ENV} responds to queries" \
    dig +short +time=3 "vault.${DNS_DOMAIN}" "@${DNS1_IP}"
  check "dns2-${ENV} responds to queries" \
    dig +short +time=3 "vault.${DNS_DOMAIN}" "@${DNS2_IP}"
  check "vault.${DNS_DOMAIN} resolves to correct IP via dns1" \
    bash -c "[[ \$(dig +short +time=3 vault.${DNS_DOMAIN} @${DNS1_IP}) == '${VAULT_IP}' ]]"
done

# =====================================================================
echo ""
echo "=== Certificates ==="
# =====================================================================

# wait_for_certs enumerates endpoints from
# certbot_cluster_gatus_cert_monitor_records, whose records are
# overwhelmingly prod-issuer (vault_prod, gitlab, applications.<x>.prod).
# It also emits one dev record (workstation_dev mgmt_nic), so this gate
# is not strictly prod-only — but in dev pipeline runs the prod records
# dominate, and a cluster-wide port change (e.g. framework/catalog/<app>/
# health.yaml) would block the dev wait on prod cert state until prod is
# redeployed. That deadlocks DRT runs needed before promotion. Skip when
# prod is not in scope. Per .claude/rules/destruction-safety.md this is a
# legitimate SKIP — prod cert health is asserted by test:prod, not test:dev.
# Coverage gap for workstation_dev mgmt_nic deferred (see issue #277).
WAIT_FOR_CERTS_SCOPED=0
for _env in "${ENVS[@]}"; do
  if [[ "$_env" == "prod" ]]; then
    WAIT_FOR_CERTS_SCOPED=1
    break
  fi
done
if [[ "$WAIT_FOR_CERTS_SCOPED" -eq 1 ]]; then
  wait_for_certs
else
  check_skip "Gatus cert readiness wait" "prod not in scope; gate is prod/shared-cert oriented (issue #277)"
fi
unset WAIT_FOR_CERTS_SCOPED

if [[ "$QUICK" -eq 0 ]]; then
  # Prod TLS services: check cert valid and >7 days remaining
  for ENV in "${ENVS[@]}"; do
    VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")
    check "vault-${ENV} cert valid (>7d remaining)" \
      bash -c "echo | openssl s_client -connect ${VAULT_IP}:8200 2>/dev/null | openssl x509 -noout -checkend 604800 2>/dev/null"
  done

  # GitLab cert (management network, LE cert)
  check "gitlab cert valid (>7d remaining)" \
    bash -c "echo | openssl s_client -connect ${GITLAB_IP}:443 2>/dev/null | openssl x509 -noout -checkend 604800 2>/dev/null"
else
  echo "[SKIP] Certificate expiry checks (--quick mode)"
fi

check_warn "Certbot renewability predicate per config-derived cert VM" \
  certbot_renewability_validate_check
check_warn "Certbot renew unit current-generation hooks resolve" \
  certbot_current_hook_resolve_check

LINEAGE_CHECKED=0
LINEAGE_RECORDS=""
LINEAGE_RECORDS_STATUS=0

set +e
LINEAGE_RECORDS="$(certbot_cluster_prod_shared_backup_certbot_records "${CONFIG}" "${APPS_CONFIG}" 2>&1)"
LINEAGE_RECORDS_STATUS=$?
set -e

if [[ "${LINEAGE_RECORDS_STATUS}" -ne 0 ]]; then
  echo "[FAIL] Renewal lineage inventory is inspectable"
  FAIL=$((FAIL + 1))
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    echo "       ${line}"
  done <<< "${LINEAGE_RECORDS}"
else
  while IFS=$'\t' read -r vm_label _ vm_ip _ fqdn _ _; do
    [[ -z "${vm_label}" ]] && continue
    LINEAGE_CHECKED=$((LINEAGE_CHECKED + 1))
    check_capture \
      "${vm_label} renewal lineage matches configured ACME URL (${fqdn})" \
      certbot_cluster_run_remote_helper \
      "${vm_ip}" \
      --mode check \
      --expected-acme-url "${SITE_ACME_URL}" \
      --expected-mode "${SITE_ACME_MODE}" \
      --fqdn "${fqdn}" \
      --label "${vm_label}"
  done <<< "${LINEAGE_RECORDS}"
fi

if [[ "${LINEAGE_RECORDS_STATUS}" -eq 0 && "${LINEAGE_CHECKED}" -eq 0 ]]; then
  check_skip "Renewal lineage checks" "no backup-backed prod/shared certbot VMs detected"
fi

if [[ "${SITE_ACME_MODE}" == "production" ]]; then
  check_capture "gitlab live issuer is production-trusted" gitlab_live_issuer_check
  check_capture "register-runner.sh --verify" "${SCRIPT_DIR}/register-runner.sh" --verify
else
  check_skip "GitLab live issuer is production-trusted" "site ACME mode is ${SITE_ACME_MODE}"
  check_skip "register-runner.sh --verify" "site ACME mode is ${SITE_ACME_MODE}"
fi

# =====================================================================
echo ""
echo "=== Vault ==="
# =====================================================================

for ENV in "${ENVS[@]}"; do
  VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")
  check "vault-${ENV} initialized and unsealed" \
    bash -c "curl -sk https://${VAULT_IP}:8200/v1/sys/health | jq -e '.initialized == true and .sealed == false'"
done

# =====================================================================
echo ""
echo "=== PBS ==="
# =====================================================================

check "PBS API responds" \
  bash -c "curl -sk https://${PBS_IP}:8007/ -o /dev/null -w '%{http_code}' | grep -qv '5[0-9][0-9]'"

# Check that backup jobs exist for all VMs with backup: true (infrastructure + applications)
BACKUP_VMS=$(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG")
BACKUP_APPS=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)
if [[ -n "$BACKUP_VMS" || -n "$BACKUP_APPS" ]]; then
  check "Backup jobs configured for VMs with precious state" \
    "${SCRIPT_DIR}/configure-backups.sh" --verify
fi

if [[ "$QUICK" -eq 0 ]]; then
  # Check PBS storage is accessible from first node
  FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
  FIRST_NODE_NAME=$(yq -r '.nodes[0].name' "$CONFIG")
  check "PBS storage (pbs-nas) accessible from ${FIRST_NODE_NAME}" \
    ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "root@${FIRST_NODE_IP}" "pvesm status 2>/dev/null | grep -q 'pbs-nas.*active'"
  run_pbs_backup_freshness_check
else
  echo "[SKIP] PBS backup freshness check (--quick mode)"
fi

# =====================================================================
echo ""
echo "=== CI/CD ==="
# =====================================================================

check "GitLab responds" \
  bash -c "code=\$(curl -sk -o /dev/null -w '%{http_code}' https://${GITLAB_IP}/); [[ \$code -lt 500 ]]"

# Check runner service is active on the runner VM
CICD_IP=$(yq -r '.vms.cicd.ip' "$CONFIG")
check "GitLab runner online" \
  ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "root@${CICD_IP}" "systemctl is-active gitlab-runner.service"

# Runner overlay usage — the 256M tmpfs overlay fills up from leaked
# test artifacts (publish-filter-test.*, etc.) and breaks the runner.
# Warn above 80%, fail above 95%.
check_warn "CI runner overlay usage below 95%" \
  bash -c "
    USAGE=\$(ssh ${SSH_OPTS} root@${CICD_IP} \"df --output=pcent / | tail -1 | tr -d ' %'\")
    if [[ \$USAGE -ge 95 ]]; then
      echo \"CRITICAL: cicd overlay at \${USAGE}%\"
      exit 1
    elif [[ \$USAGE -ge 80 ]]; then
      echo \"WARNING: cicd overlay at \${USAGE}%\"
      exit 3
    fi
  "

# Stale publish-filter temp dirs indicate EXIT cleanup regressed or a job
# was interrupted before cleanup ran. Warn so tmpfiles cleanup does not
# silently hide the underlying issue.
check_warn "CI runner stale publish-filter temp dirs absent" \
  bash -c "
    STALE=\$(ssh ${SSH_OPTS} root@${CICD_IP} \"find /tmp -maxdepth 1 -type d -name 'publish-filter-test.*' -mmin +30 | wc -l | tr -d ' '\")
    if [[ \$STALE -gt 0 ]]; then
      echo \"WARNING: found \${STALE} stale publish-filter temp dir(s) older than 30m in /tmp\"
      exit 3
    fi
  "

# =====================================================================
echo ""
echo "=== Tailscale ==="
# =====================================================================

TAILSCALE_VMS=$(yq -r '.vms | to_entries[] | select(.value.tailscale == true) | .key' "$CONFIG" 2>/dev/null || true)
if [[ -n "$TAILSCALE_VMS" ]]; then
  for VM_KEY in $TAILSCALE_VMS; do
    VM_IP=$(yq -r ".vms.${VM_KEY}.ip" "$CONFIG")

    check "${VM_KEY} tailscaled service active" \
      ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${VM_IP}" "systemctl is-active tailscaled.service"

    check "${VM_KEY} tailscale connected" \
      bash -c "ssh ${SSH_OPTS} root@${VM_IP} 'tailscale status --json --peers=false 2>/dev/null' | jq -e '.BackendState == \"Running\"'"

    check "${VM_KEY} tailscale IP assigned" \
      bash -c "ssh ${SSH_OPTS} root@${VM_IP} 'tailscale status --json --peers=false 2>/dev/null' | jq -e '(.Self.TailscaleIPs // []) | length > 0'"
  done
else
  check_skip "Tailscale health checks" "no VMs with tailscale: true in config.yaml"
fi

# =====================================================================
echo ""
echo "=== Monitoring ==="
# =====================================================================

check "Gatus (primary) responds" \
  curl -sf "http://${GATUS_IP}:8080/api/v1/endpoints/statuses?page=1"

check "Sentinel Gatus (NAS) responds" \
  curl -sf "http://${NAS_IP}:8080/api/v1/endpoints/statuses"

# Parse Gatus API for all-healthy (retry — Gatus needs time to cycle checks after recreation).
# When the aggregate fails, enumerate each unhealthy endpoint's group/name/key and its failing
# conditionResults so the trace names the problem instead of only counting (#618). Filters
# (cert_group + "publishing") are shared with the healthy/total count so the diagnostic and
# the decision use the same universe.
check_capture "All non-certificate Gatus endpoints healthy" \
  bash -c "
    cert_group='$(certbot_cluster_gatus_cert_group)'
    data=''
    total=0
    healthy=0
    for attempt in 1 2 3 4 5 6; do
      data=\$(curl -sf 'http://${GATUS_IP}:8080/api/v1/endpoints/statuses?page=1' || true)
      total=\$(echo \"\$data\" | jq --arg cert_group \"\$cert_group\" '[.[] | select((.group // \"\") != \$cert_group and (.group // \"\") != \"publishing\")] | length' 2>/dev/null || echo 0)
      healthy=\$(echo \"\$data\" | jq --arg cert_group \"\$cert_group\" '[.[] | select((.group // \"\") != \$cert_group and (.group // \"\") != \"publishing\" and .results[-1].success == true)] | length' 2>/dev/null || echo 0)
      if [[ \$healthy -eq \$total && \$total -gt 0 ]]; then
        echo \"Gatus: \${healthy}/\${total} non-certificate endpoints healthy\"
        exit 0
      fi
      sleep 30
    done
    echo \"Gatus: \${healthy}/\${total} non-certificate endpoints healthy (gave up after 3 min)\"
    unhealthy=\$(echo \"\$data\" | jq -r --arg cert_group \"\$cert_group\" '
      .[]
      | select((.group // \"\") != \$cert_group and (.group // \"\") != \"publishing\")
      | select(.results[-1].success != true)
      | (.group // \"\") as \$g
      | (.name // \"\") as \$n
      | (.key // \"\") as \$k
      | \"  \\(\$g)/\\(\$n) (key=\\(\$k))\",
        (
          (.results[-1].conditionResults // [])
          | map(select(.success != true))
          | if length == 0 then [\"    (endpoint result marked failing but no failing conditionResults reported)\"]
            else map(\"    \\(.condition)\")
            end
          | .[]
        )
    ' 2>/dev/null || true)
    if [[ -n \"\$unhealthy\" ]]; then
      echo 'Unhealthy endpoints:'
      printf '%s\n' \"\$unhealthy\"
    fi
    exit 1
  "

GATUS_STATUS_DATA="$(curl -sf "http://${GATUS_IP}:8080/api/v1/endpoints/statuses?page=1" 2>/dev/null || true)"
if [[ -n "${GATUS_STATUS_DATA}" ]] && echo "${GATUS_STATUS_DATA}" | jq -e '.[] | select((.group // "") == "publishing")' >/dev/null 2>&1; then
  echo "[SKIP] Gatus publishing endpoints in aggregate - checked by GitHub mirror telemetry after publish"
  SKIP=$((SKIP + 1))
fi

PUBLISH_GITHUB_ENABLED_VALIDATE="$(yq -r '.publish.github.enabled // false' "${CONFIG}")"
if [[ "${PUBLISH_GITHUB_ENABLED_VALIDATE}" != "true" ]]; then
  echo "[SKIP] Gatus publishing endpoint probe - publish.github.enabled is not true (issue #294)"
  SKIP=$((SKIP + 1))
else
  # Issue #619: the github-mirror probe compares against the *published*
  # (prod-tip) SHA. Use the shared resolver so validate.sh, the gatus
  # config generator, and validate-github-mirror.sh all agree on the
  # same value regardless of which branch triggered the pipeline. A
  # dev pipeline's CI_COMMIT_SHA is the dev tip, which a prod-tracking
  # public mirror will never match — that was the false-staleness
  # signal on pipeline 1650.
  #
  # Source lazily so publish-disabled fixtures (see comment near
  # top of the file) do not need to stage github-publish-lib.sh.
  # Sourced under `source` (not `.`) with an absolute path.
  # shellcheck source=framework/scripts/github-publish-lib.sh
  source "${SCRIPT_DIR}/github-publish-lib.sh"
  set +e
  GATUS_EXPECTED_SHA="$(resolve_gatus_expected_source_commit "${REPO_DIR}" 2>/dev/null)"
  set -e
  if [[ -n "${GATUS_EXPECTED_SHA}" ]]; then
    set +e
    # Issue #629: forward the operator's config override so the child
    # reads the same site config as validate.sh (both the publish gate
    # at validate-github-mirror.sh:106 and the vms.gatus.ip lookup at
    # validate-github-mirror.sh:135). Without this, running
    # `MYCOFU_VALIDATE_CONFIG=/custom/path validate.sh` silently made
    # the child fall back to REPO_DIR/site/config.yaml.
    GATUS_PROBE_OUTPUT="$(VALIDATE_GITHUB_MIRROR_CONFIG_FILE="${CONFIG}" "${SCRIPT_DIR}/validate-github-mirror.sh" --check-gatus-config --expected-sha "${GATUS_EXPECTED_SHA}" 2>&1)"
    GATUS_PROBE_EXIT=$?
    set -e
    case "${GATUS_PROBE_EXIT}" in
      0)
        echo "[PASS] Gatus publishing endpoint config matches prod tip"
        PASS=$((PASS + 1))
        ;;
      10)
        echo "[WARN] Gatus publishing endpoint config is stale (Gatus recreation lagged); not a publish failure"
        WARN=$((WARN + 1))
        print_check_output "${GATUS_PROBE_OUTPUT}"
        ;;
      11)
        echo "[WARN] Gatus publishing endpoint missing from deployed config"
        WARN=$((WARN + 1))
        print_check_output "${GATUS_PROBE_OUTPUT}"
        ;;
      12)
        echo "[WARN] Gatus publishing endpoint has the issue #301 quoted-RHS regression; the deployed check will stay red until Gatus is redeployed with the current generator"
        WARN=$((WARN + 1))
        print_check_output "${GATUS_PROBE_OUTPUT}"
        ;;
      *)
        echo "[WARN] Gatus config probe failed: ${GATUS_PROBE_OUTPUT}"
        WARN=$((WARN + 1))
        ;;
    esac
  else
    echo "[WARN] Gatus config probe failed: expected prod SHA unavailable"
    WARN=$((WARN + 1))
  fi
fi

# =====================================================================
echo ""
echo "=== Service Health ==="
# =====================================================================

# Closes #391. Detects sustained service restart loops and OOM-kill
# pathology that probe-based monitoring (Gatus, application health
# endpoints) misses when the probe target is independent of the
# failing service's state. See
# docs/reports/2026-05-25-testapp-prod-vault-agent-oom-investigation.md
# for the motivating incident.
#
# Gated on QUICK==0 like other SSH-heavy checks (cf. PBS backup
# freshness, lines 592-613) because this fans out one SSH session per
# VM. Cluster-wide scope by design — the testapp-prod incident proved
# that any VM crash-looping invisibly is a Goal 21 failure regardless
# of env arg.
if [[ "$QUICK" -eq 0 ]]; then
  check_capture "No service restart loops or OOM patterns on any VM" \
    "${SCRIPT_DIR}/check-service-restart-loop.sh"
else
  check_skip "Service restart loop check" "--quick mode"
fi

# =====================================================================
echo ""
echo "=== VM Topology ==="
# =====================================================================

if [[ "$QUICK" -eq 0 ]]; then
  check_capture "VM topology completeness" vm_topology_complete_check
else
  check_skip "VM topology completeness" "--quick mode"
fi

# =====================================================================
echo ""
echo "=== Applications ==="
# =====================================================================

for ENV in "${ENVS[@]}"; do
  TESTAPP_IP=$(yq -r ".vms.testapp_${ENV}.ip // \"\"" "$CONFIG")
  if [[ -n "$TESTAPP_IP" && "$TESTAPP_IP" != "null" ]]; then
    check "testapp-${ENV} healthy (status=healthy, count>0)" \
      bash -c "curl -sf http://${TESTAPP_IP}:8080/ | jq -e '.status == \"healthy\" and .count > 0'"
  fi

  # Catalog applications (from applications.yaml)
  # Health port/path come from the catalog module's metadata.yaml, not config.yaml.
  APP_NAMES=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.monitor == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)
  for APP in $APP_NAMES; do
    APP_IP=$(yq -r ".applications.${APP}.environments.${ENV}.ip // \"\"" "$APPS_CONFIG")
    HEALTH_FILE="${REPO_DIR}/framework/catalog/${APP}/health.yaml"
    if [[ ! -f "$HEALTH_FILE" ]]; then
      continue
    fi
    HEALTH_PORT_APP=$(yq -r '.port // ""' "$HEALTH_FILE")
    HEALTH_PATH_APP=$(yq -r '.path // ""' "$HEALTH_FILE")
    if [[ -n "$APP_IP" && "$APP_IP" != "null" && -n "$HEALTH_PORT_APP" && "$HEALTH_PORT_APP" != "null" ]]; then
      check "${APP}-${ENV} healthy (${HEALTH_PATH_APP})" \
        bash -c "curl -sfk https://${APP_IP}:${HEALTH_PORT_APP}${HEALTH_PATH_APP} >/dev/null"

      if [[ "$APP" == "influxdb" ]]; then
        check "${APP}-${ENV} dashboard landing page contains expected markers" \
          bash -c 'body=$(curl -sfk "https://'"${APP_IP}"':443/"); grep -q "Cluster Dashboard" <<< "$body" && grep -q "dashboard-root" <<< "$body"'
        check "${APP}-${ENV} InfluxDB /health still serves on :8086" \
          bash -c "curl -sfk https://${APP_IP}:8086/health | jq -e '.status == \"pass\"' >/dev/null"
      elif [[ "$APP" == "workstation" ]]; then
        WORKSTATION_CHECK_IP="$APP_IP"
        if [[ "$ENV" == "dev" ]]; then
          WORKSTATION_CHECK_IP=$(yq -r '.applications.workstation.environments.dev.mgmt_nic.ip // ""' "$APPS_CONFIG" 2>/dev/null || true)
          if [[ -z "$WORKSTATION_CHECK_IP" || "$WORKSTATION_CHECK_IP" == "null" ]]; then
            WORKSTATION_CHECK_IP="$APP_IP"
          fi
        fi

        check "${APP}-${ENV} health payload reports healthy" \
          bash -c "curl -sfk https://${WORKSTATION_CHECK_IP}:${HEALTH_PORT_APP}${HEALTH_PATH_APP} | jq -e '.status == \"healthy\" and .home.mounted == true and .home.user_home_exists == true and .home.disk_ok == true and .nix.shell_ok == true and .vault_agent_authenticated == true' >/dev/null"
      fi
    fi
  done
done

# =====================================================================
echo ""
echo "=== Dual-NIC (mgmt_nic) Connectivity ==="
# =====================================================================
# For VMs with mgmt_nic in config.yaml, verify all connectivity paths.

for ENV in "${ENVS[@]}"; do
  APP_NAMES=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)
  for APP in $APP_NAMES; do
    MGMT_IP=$(yq -r ".applications.${APP}.environments.${ENV}.mgmt_nic.ip // \"\"" "$APPS_CONFIG")
    [[ -z "$MGMT_IP" || "$MGMT_IP" == "null" ]] && continue

    VLAN_IP=$(yq -r ".applications.${APP}.environments.${ENV}.ip" "$APPS_CONFIG")
    VM_NODE=$(yq -r ".applications.${APP}.environments.${ENV}.node" "$APPS_CONFIG")
    VM_LABEL="${APP}-${ENV}"

    # Find a same-VLAN peer on a different node
    PEER_DIFF_NODE=""
    PEER_SAME_NODE=""
    for PEER_KEY in $(yq -r ".vms | to_entries[] | select(.key | test(\"_${ENV}$\")) | .key" "$CONFIG" 2>/dev/null); do
      PEER_IP=$(yq -r ".vms.${PEER_KEY}.ip" "$CONFIG")
      PEER_NODE=$(yq -r ".vms.${PEER_KEY}.node" "$CONFIG")
      [[ "$PEER_IP" == "$VLAN_IP" ]] && continue
      if [[ "$PEER_NODE" == "$VM_NODE" && -z "$PEER_SAME_NODE" ]]; then
        PEER_SAME_NODE="$PEER_IP"
      elif [[ "$PEER_NODE" != "$VM_NODE" && -z "$PEER_DIFF_NODE" ]]; then
        PEER_DIFF_NODE="$PEER_IP"
      fi
      [[ -n "$PEER_SAME_NODE" && -n "$PEER_DIFF_NODE" ]] && break
    done

    # Test 1: SSH via management IP
    check "${VM_LABEL} mgmt NIC reachable (${MGMT_IP})" \
      bash -c "ssh ${SSH_OPTS} root@${MGMT_IP} true"

    # Test 2: SSH via VLAN IP
    check "${VM_LABEL} VLAN NIC reachable (${VLAN_IP})" \
      bash -c "ssh ${SSH_OPTS} root@${VLAN_IP} true"

    # Test 3: Same VLAN, different node → VM
    if [[ -n "$PEER_DIFF_NODE" ]]; then
      check "${VM_LABEL} reachable from same-VLAN different-node peer" \
        bash -c "ssh ${SSH_OPTS} root@${PEER_DIFF_NODE} 'ping -c1 -W2 ${VLAN_IP}' >/dev/null 2>&1"
    fi

    # Test 4: Same VLAN, same node → VM
    if [[ -n "$PEER_SAME_NODE" ]]; then
      check "${VM_LABEL} reachable from same-VLAN same-node peer" \
        bash -c "ssh ${SSH_OPTS} root@${PEER_SAME_NODE} 'ping -c1 -W2 ${VLAN_IP}' >/dev/null 2>&1"
    fi

    # Test 5: VM → same-VLAN peer (different node)
    if [[ -n "$PEER_DIFF_NODE" ]]; then
      check "${VM_LABEL} can reach same-VLAN different-node peer" \
        bash -c "ssh ${SSH_OPTS} root@${VLAN_IP} 'ping -c1 -W2 ${PEER_DIFF_NODE}' >/dev/null 2>&1"
    fi

    # Test 6: DNS resolution from the VM
    check "${VM_LABEL} DNS resolution works" \
      bash -c "ssh ${SSH_OPTS} root@${MGMT_IP} 'getent hosts ${APP}.${ENV}.${DOMAIN}' >/dev/null 2>&1"

    # Test 7: Correct interface separation (VLAN IP on primary, mgmt IP on secondary)
    check "${VM_LABEL} interfaces correctly separated" \
      bash -c "
        IFACES=\$(ssh ${SSH_OPTS} root@${MGMT_IP} 'ip -br addr show | grep -v lo')
        echo \"\$IFACES\" | grep -q '${VLAN_IP}' && echo \"\$IFACES\" | grep -q '${MGMT_IP}'
      "
  done
done

# =====================================================================
# Regression Tests
# =====================================================================

if [[ "$REGRESSION" -eq 1 || "$REGRESSION_SAFE" -eq 1 ]]; then

  DESTRUCTIVE=0
  if [[ "$REGRESSION" -eq 1 && "$REGRESSION_SAFE" -eq 0 ]]; then
    DESTRUCTIVE=1
  fi

  # Helper: determine if destructive tests should run (dev only)
  can_run_destructive() {
    [[ "$DESTRUCTIVE" -eq 1 ]]
  }

  # =====================================================================
  echo ""
  echo "=== Regression: Environment Ignorance ==="
  # =====================================================================

  # Cross-env tests always read both environments (they verify cross-env properties)
  DNS1_PROD_IP=$(yq -r '.vms.dns1_prod.ip' "$CONFIG")
  DNS1_DEV_IP=$(yq -r '.vms.dns1_dev.ip' "$CONFIG")
  VAULT_PROD_IP=$(yq -r '.vms.vault_prod.ip' "$CONFIG")
  VAULT_DEV_IP=$(yq -r '.vms.vault_dev.ip' "$CONFIG")
  BASE_DOMAIN=$(yq -r '.domain' "$CONFIG")
  PROD_DNS_DOMAIN="prod.${BASE_DOMAIN}"
  DEV_DNS_DOMAIN="dev.${BASE_DOMAIN}"

  # R1.1 — Same image hash in dev and prod (per role) [cross-env]
  # After a full pipeline build, both environments deploy the same image per role.
  # Skip when running single-env regression — after a dev-only or prod-only deploy,
  # image hashes will differ until the other env is also deployed.
  if [[ ${#ENVS[@]} -ge 2 ]]; then
    for role_info in "dns:dns1" "vault:vault"; do
      role="${role_info%%:*}"
      vm="${role_info##*:}"
      DEV_IP=$(yq -r ".vms.${vm}_dev.ip" "$CONFIG")
      PROD_IP=$(yq -r ".vms.${vm}_prod.ip" "$CONFIG")
      check "R1.1: Same image hash in dev and prod (${role})" \
        bash -c "
          DEV_HASH=\$(ssh ${SSH_OPTS} root@${DEV_IP} 'cat /etc/image-hash 2>/dev/null || echo MISSING')
          PROD_HASH=\$(ssh ${SSH_OPTS} root@${PROD_IP} 'cat /etc/image-hash 2>/dev/null || echo MISSING')
          [[ \"\$DEV_HASH\" == \"\$PROD_HASH\" && \"\$DEV_HASH\" != 'MISSING' ]]
        "
    done
  else
    for role_info in "dns:dns1" "vault:vault"; do
      role="${role_info%%:*}"
      check_skip "R1.1: Same image hash in dev and prod (${role})" \
        "single-env mode — cross-env comparison requires both envs"
    done
  fi

  # R1.2 — Unqualified hostname resolves differently per environment [cross-env]
  check "R1.2: Unqualified 'vault' resolves differently per environment" \
    bash -c "
      PROD_RESULT=\$(dig +short +time=3 vault.${PROD_DNS_DOMAIN} @${DNS1_PROD_IP})
      DEV_RESULT=\$(dig +short +time=3 vault.${DEV_DNS_DOMAIN} @${DNS1_DEV_IP})
      [[ -n \"\$PROD_RESULT\" && -n \"\$DEV_RESULT\" && \"\$PROD_RESULT\" != \"\$DEV_RESULT\" ]]
    "

  check "R1.2a: vault resolves to correct prod IP" \
    bash -c "[[ \$(dig +short +time=3 vault.${PROD_DNS_DOMAIN} @${DNS1_PROD_IP}) == '${VAULT_PROD_IP}' ]]"

  check "R1.2b: vault resolves to correct dev IP" \
    bash -c "[[ \$(dig +short +time=3 vault.${DEV_DNS_DOMAIN} @${DNS1_DEV_IP}) == '${VAULT_DEV_IP}' ]]"

  # R1.2c — In-VM unqualified resolution (tests full DHCP → search domain → DNS chain) [cross-env]
  # This is the real environment ignorance test — it catches gateway DNS misconfigurations
  # that zone-data-only tests (R1.2/R1.2a/R1.2b) cannot detect.
  check "R1.2c: In-VM 'vault' resolves to prod IP from dns2-prod" \
    bash -c "
      RESOLVED=\$(ssh ${SSH_OPTS} root@$(yq -r '.vms.dns2_prod.ip' "$CONFIG") 'getent hosts vault 2>/dev/null' | awk '{print \$1}')
      [[ \"\$RESOLVED\" == '${VAULT_PROD_IP}' ]]
    "

  check "R1.2c: In-VM 'vault' resolves to dev IP from dns2-dev" \
    bash -c "
      RESOLVED=\$(ssh ${SSH_OPTS} root@$(yq -r '.vms.dns2_dev.ip' "$CONFIG") 'getent hosts vault 2>/dev/null' | awk '{print \$1}')
      [[ \"\$RESOLVED\" == '${VAULT_DEV_IP}' ]]
    "

  # R1.2d — VM DNS server verification (VMs use per-env DNS servers, not the gateway) [cross-env]
  check "R1.2d: dns2-prod uses prod DNS servers (not gateway)" \
    bash -c "
      DNS_INFO=\$(ssh ${SSH_OPTS} root@$(yq -r '.vms.dns2_prod.ip' "$CONFIG") 'networkctl status 2>/dev/null' | grep 'DNS:')
      echo \"\$DNS_INFO\" | grep -q '${DNS1_PROD_IP}'
    "

  check "R1.2d: dns2-dev uses dev DNS servers (not gateway)" \
    bash -c "
      DNS_INFO=\$(ssh ${SSH_OPTS} root@$(yq -r '.vms.dns2_dev.ip' "$CONFIG") 'networkctl status 2>/dev/null' | grep 'DNS:')
      echo \"\$DNS_INFO\" | grep -q '${DNS1_DEV_IP}'
    "

  # R1.3 — certbot config identical across environments [cross-env]
  check "R1.3: certbot config structure identical across envs (dns1)" \
    bash -c "
      PROD_KEYS=\$(ssh ${SSH_OPTS} root@${DNS1_PROD_IP} 'cat /etc/letsencrypt/renewal/*.conf 2>/dev/null' | grep -E '^\[|^[a-z]' | sed 's/=.*//' | sort)
      DEV_KEYS=\$(ssh ${SSH_OPTS} root@${DNS1_DEV_IP} 'cat /etc/letsencrypt/renewal/*.conf 2>/dev/null' | grep -E '^\[|^[a-z]' | sed 's/=.*//' | sort)
      [[ \"\$PROD_KEYS\" == \"\$DEV_KEYS\" ]]
    "

  # =====================================================================
  echo ""
  echo "=== Regression: HA Readiness ==="
  # =====================================================================

  # R2.1 — CIDATA snippets on all nodes (equal SET, not just equal count) [cluster]
  # On FAIL, name every missing snippet on every node (#347). Equal counts
  # are not enough — two nodes can have the same number of snippets yet hold
  # different files. The set diff is what HA migration actually needs.
  #
  # SSH failure is reported distinctively — without that distinction, an
  # unreachable node would silently look like "missing every snippet" and
  # mislead the operator into chasing a phantom snippet divergence.
  check_capture "R2.1: CIDATA snippets replicated to all nodes (equal sets)" \
    bash -c "
      set -euo pipefail
      WORK=\$(mktemp -d)
      trap 'rm -rf \"\$WORK\"' EXIT
      NODE_NAMES=()
      SSH_FAILED=()
      for i in \$(seq 0 $((NODE_COUNT - 1))); do
        NODE_NAME=\$(yq -r \".nodes[\${i}].name\" '$CONFIG')
        NODE_IP=\$(yq -r \".nodes[\${i}].mgmt_ip\" '$CONFIG')
        NODE_NAMES+=(\"\$NODE_NAME\")
        # Capture ssh exit status separately from the remote command's exit
        # status. The remote command ends with '|| true' so it always exits 0;
        # ssh's own exit code (255 on connect failure, 1 on auth failure)
        # propagates out of the pipeline only because there is no pipe here.
        if ! ssh ${SSH_OPTS} root@\${NODE_IP} \\
              'cd /var/lib/vz/snippets 2>/dev/null && ls *.yaml 2>/dev/null || true' \\
              > \"\$WORK/\$NODE_NAME.raw\" 2>/dev/null; then
          SSH_FAILED+=(\"\$NODE_NAME\")
          : > \"\$WORK/\$NODE_NAME\"
        else
          sort -u \"\$WORK/\$NODE_NAME.raw\" > \"\$WORK/\$NODE_NAME\"
        fi
      done
      RC=0
      if [[ \${#SSH_FAILED[@]} -gt 0 ]]; then
        echo \"ssh unreachable: \${SSH_FAILED[*]} (snippet state unknown)\"
        RC=1
      fi
      # Enumerate per-node files explicitly rather than glob \"\$WORK\"/* —
      # the latter would include any future bookkeeping file under \$WORK.
      UNION=\"\$WORK/_union\"
      : > \"\$UNION\"
      for NODE_NAME in \"\${NODE_NAMES[@]}\"; do
        cat \"\$WORK/\$NODE_NAME\" >> \"\$UNION\"
      done
      sort -u \"\$UNION\" -o \"\$UNION\"
      TOTAL=\$(wc -l < \"\$UNION\" | tr -d ' ')
      if [[ \$TOTAL -eq 0 ]]; then
        if [[ \${#SSH_FAILED[@]} -eq 0 ]]; then
          echo \"no snippets found on any node\"
        fi
        exit 1
      fi
      for NODE_NAME in \"\${NODE_NAMES[@]}\"; do
        # Skip nodes we already flagged as ssh-failed; their empty file
        # would falsely show them missing everything.
        skip=0
        for failed in \"\${SSH_FAILED[@]+\"\${SSH_FAILED[@]}\"}\"; do
          [[ \"\$failed\" == \"\$NODE_NAME\" ]] && skip=1
        done
        [[ \$skip -eq 1 ]] && continue
        COUNT=\$(wc -l < \"\$WORK/\$NODE_NAME\" | tr -d ' ')
        if [[ \$COUNT -eq \$TOTAL ]]; then
          echo \"\$NODE_NAME: \$COUNT/\$TOTAL snippets present\"
        else
          MISSING=\$(comm -23 \"\$UNION\" \"\$WORK/\$NODE_NAME\" | paste -sd, -)
          echo \"\$NODE_NAME: \$COUNT/\$TOTAL snippets (missing: \$MISSING)\"
          RC=1
        fi
      done
      exit \$RC
    "

  # R2.2 — Snippet content matches across nodes [cluster]
  # Spot-check: dns1-prod user-data must have identical hash on all nodes
  check "R2.2: dns1-prod user-data identical across all nodes" \
    bash -c "
      HASHES=''
      for i in \$(seq 0 $((NODE_COUNT - 1))); do
        NODE_IP=\$(yq -r \".nodes[\${i}].mgmt_ip\" '$CONFIG')
        HASH=\$(ssh ${SSH_OPTS} root@\${NODE_IP} 'md5sum /var/lib/vz/snippets/dns1-prod-user-data.yaml 2>/dev/null' | awk '{print \$1}')
        HASHES=\"\${HASHES} \${HASH}\"
      done
      UNIQUE=\$(echo \$HASHES | tr ' ' '\n' | sort -u | wc -l)
      [[ \$UNIQUE -eq 1 ]]
    "

  # R2.3 — Anti-affinity: dns1 and dns2 on different nodes [env]
  for ENV in "${ENVS[@]}"; do
    DNS1_NODE_INTENDED=$(yq -r ".vms.dns1_${ENV}.node" "$CONFIG")
    DNS2_NODE_INTENDED=$(yq -r ".vms.dns2_${ENV}.node" "$CONFIG")
    check "R2.3: Anti-affinity — dns1 and dns2 on different nodes (${ENV})" \
      bash -c "[[ '${DNS1_NODE_INTENDED}' != '${DNS2_NODE_INTENDED}' ]]"
  done

  # R2.4 — VM placement matches config.yaml [cluster]
  FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
  check "R2.4: VM placement matches config.yaml" \
    bash -c "
      RESOURCES=\$(ssh ${SSH_OPTS} root@${FIRST_NODE_IP} 'pvesh get /cluster/resources --type vm --output-format json 2>/dev/null')
      FAIL=0
      # Infrastructure VMs
      for vm in \$(yq -r '.vms | keys | .[]' '$CONFIG'); do
        INTENDED=\$(yq -r \".vms.\${vm}.node\" '$CONFIG')
        VM_NAME=\$(echo \"\$vm\" | tr '_' '-')
        ACTUAL=\$(echo \"\$RESOURCES\" | jq -r \".[] | select(.name==\\\"\${VM_NAME}\\\") | .node\" 2>/dev/null)
        if [[ -n \"\$ACTUAL\" && \"\$INTENDED\" != \"\$ACTUAL\" ]]; then
          echo \"DRIFT: \$vm intended=\$INTENDED actual=\$ACTUAL\" >&2
          FAIL=1
        fi
      done
      # Catalog applications
      for app in \$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true) | .key' '$APPS_CONFIG' 2>/dev/null); do
        for env in \$(yq -r \".applications.\${app}.environments | keys | .[]\" '$APPS_CONFIG' 2>/dev/null); do
          # Node can be per-environment or shared at the app level
          INTENDED=\$(yq -r \".applications.\${app}.environments.\${env}.node // .applications.\${app}.node\" '$APPS_CONFIG')
          VM_NAME=\"\${app}-\${env}\"
          ACTUAL=\$(echo \"\$RESOURCES\" | jq -r \".[] | select(.name==\\\"\${VM_NAME}\\\") | .node\" 2>/dev/null)
          if [[ -n \"\$ACTUAL\" && \"\$INTENDED\" != \"null\" && \"\$INTENDED\" != \"\$ACTUAL\" ]]; then
            echo \"DRIFT: \${app}_\${env} intended=\$INTENDED actual=\$ACTUAL\" >&2
            FAIL=1
          fi
        done
      done
      [[ \$FAIL -eq 0 ]]
    "

  # R2.5 — Cross-node migration [destructive — dev only]
  if can_run_destructive; then
    check_skip "R2.5: Cross-node migration works (dns1-dev)" \
      "destructive test — run manually with care"
  else
    check_skip "R2.5: Cross-node migration works (dns1-dev)" \
      "destructive test, requires --regression dev"
  fi

  # R2.6 — Replication network healthy [cluster]
  # Retry for up to 2 minutes (replication may still be syncing after deploy)
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    check "R2.6: ${NODE_NAME} healthy and replication not stale" \
      bash -c "
        for attempt in \$(seq 1 12); do
          HEALTH=\$(curl -sf http://${NODE_IP}:${HEALTH_PORT}/ 2>/dev/null || true)
          HEALTHY=\$(echo \"\$HEALTH\" | jq -r '.healthy' 2>/dev/null)
          STALE=\$(echo \"\$HEALTH\" | jq -r '.replication_stale' 2>/dev/null)
          if [[ \"\$HEALTHY\" == \"true\" && \"\$STALE\" == \"false\" ]]; then
            exit 0
          fi
          [ \$attempt -lt 12 ] && sleep 10
        done
        echo 'Still unhealthy/stale after 2 minutes' >&2
        exit 1
      "
  done

  # R2.7 — Migration-network /32 present on dummy0 [cluster]
  #
  # Direct fail-closed probe of the interface backing the corosync
  # ring-0 / Proxmox migration-network (10.10.0.0/24). R2.6 gates on
  # the health endpoint which itself factors dummy0 state via
  # repl-health.sh, but a broken health server would mask the very
  # failure mode #697 hit at boot on pve02. A separate ssh + `ip addr`
  # probe removes the health-endpoint dependency; if either the probe
  # errors or the expected /32 is not present, FAIL (never SKIP).
  #
  # The expected address is derived from site/config.yaml
  # (.nodes[i].repl_ip) — no hardcoded IPs. Nodes without a repl_ip
  # (single-node / non-mesh) skip this check by construction.
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    NODE_REPL_IP=$(yq -r ".nodes[${i}].repl_ip // \"\"" "$CONFIG")
    if [[ -z "$NODE_REPL_IP" || "$NODE_REPL_IP" == "null" ]]; then
      continue
    fi
    # check_capture (not check) so the "FAIL: ssh …" / "FAIL: dummy0 …"
    # diagnostic lines are actually shown to the operator — check would
    # swallow stderr wholesale (sub-claude P2-1).
    check_capture "R2.7: ${NODE_NAME} dummy0 carries ${NODE_REPL_IP}/32 (#697)" \
      bash -c "
        # Enumerate ALL IPv4 addresses on dummy0 (not just the first) — a
        # future config that legitimately parks a secondary address there
        # should not false-fail this check, and a missing expected /32
        # must still fail (agy P2/codex P2).
        ADDRS=\$(ssh ${SSH_OPTS} root@${NODE_IP} 'ip -o -4 addr show dev dummy0 2>/dev/null | awk \"{print \\\$4}\"' 2>/dev/null)
        SSH_RC=\$?
        if [[ \$SSH_RC -ne 0 ]]; then
          echo \"FAIL: ssh to ${NODE_NAME} (${NODE_IP}) failed (rc=\$SSH_RC); cannot verify dummy0\" >&2
          exit 1
        fi
        if [[ -z \"\$ADDRS\" ]]; then
          echo \"FAIL: dummy0 on ${NODE_NAME} has no IPv4 address (expected ${NODE_REPL_IP}/32)\" >&2
          exit 1
        fi
        if ! printf '%s\n' \"\$ADDRS\" | grep -qxF \"${NODE_REPL_IP}/32\"; then
          echo \"FAIL: dummy0 on ${NODE_NAME} has [\$(printf '%s ' \$ADDRS)] (expected ${NODE_REPL_IP}/32 to be present)\" >&2
          exit 1
        fi
        exit 0
      "
  done

  # =====================================================================
  echo ""
  echo "=== Regression: Secrets Architecture ==="
  # =====================================================================

  # R3.1 — No post-deploy secrets in TF_VARs [cluster]
  TOFU_WRAPPER="${SCRIPT_DIR}/tofu-wrapper.sh"
  check "R3.1: No post-deploy secrets in TF_VARs" \
    bash -c "
      # Should NOT find unseal, runner_token, or registration in TF_VAR exports
      ! grep -E 'TF_VAR.*(unseal|runner.*token|registration)' '${TOFU_WRAPPER}' | grep -v '^#'
    "

  # R3.2 — Vault unseal key on vdb, not in CIDATA [env]
  for ENV in "${ENVS[@]}"; do
    VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")
    check "R3.2: vault-${ENV} unseal key exists on vdb" \
      ssh_node "root@${VAULT_IP}" "test -f /var/lib/vault/unseal-key"
  done

  # R3.2a [cluster]
  check "R3.2a: No unseal key reference in CIDATA snippets" \
    bash -c "
      FIRST_NODE_IP=\$(yq -r '.nodes[0].mgmt_ip' '$CONFIG')
      ! ssh ${SSH_OPTS} root@\${FIRST_NODE_IP} 'grep -l unseal /var/lib/vz/snippets/vault-*-user-data.yaml 2>/dev/null' | grep -q .
    "

  # R3.3 — SOPS post-deploy section not consumed by TF_VAR [cluster]
  check "R3.3: tofu-wrapper.sh only exports pre-deploy secrets" \
    bash -c "
      # List all TF_VAR exports (non-comment lines)
      EXPORTS=\$(grep 'export TF_VAR_' '${TOFU_WRAPPER}' | grep -v '^#' | grep -v '^ *#')
      # Should only see: ssh_pubkey, pdns_api_key, sops_age_key, ssh_privkey, app pre-deploy secrets
      # Should NOT see: unseal_key, runner_token, root_password
      ! echo \"\$EXPORTS\" | grep -iE 'unseal|runner_token|root_password'
    "

  # =====================================================================
  echo ""
  echo "=== Regression: Storage Integrity ==="
  # =====================================================================

  # R4.1 — All VMs on vmstore, not rpool [cluster]
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    check "R4.1: ${NODE_NAME} — no VM zvols on rpool" \
      bash -c "
        RPOOL_VMS=\$(ssh ${SSH_OPTS} root@${NODE_IP} 'zfs list -r rpool/data 2>/dev/null | grep vm- | wc -l')
        [[ \$RPOOL_VMS -eq 0 ]]
      "
  done

  # R4.2 — vmstore cachefile set for auto-import [cluster]
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    check "R4.2: ${NODE_NAME} — ${STORAGE_POOL} cachefile set" \
      bash -c "
        CACHEFILE=\$(ssh ${SSH_OPTS} root@${NODE_IP} 'zpool get -H -o value cachefile ${STORAGE_POOL}')
        [[ \"\$CACHEFILE\" == '/etc/zfs/zpool.cache' || \"\$CACHEFILE\" == '-' ]]
      "
  done

  # R4.3 — No orphan zvols [cluster]
  r4_3_check_orphans() {
    local node_ip="$1"
    local pool="$2"
    local orphans
    orphans=$(ssh "${SSH_OPTS_ARGS[@]}" "root@${node_ip}" \
      "for zvol in \$(zfs list -H -o name -r ${pool}/data 2>/dev/null | grep vm-); do vmid=\$(echo \$zvol | grep -oP 'vm-\K[0-9]+'); if ! qm status \$vmid &>/dev/null 2>&1; then if ! pvesr list 2>/dev/null | grep -q \"\$vmid\"; then echo ORPHAN:\$zvol; fi; fi; done" \
      2>/dev/null) || true
    [[ -z "$orphans" ]]
  }
  for (( i=0; i<NODE_COUNT; i++ )); do
    NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG")
    NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG")
    check "R4.3: ${NODE_NAME} — no orphan zvols" \
      r4_3_check_orphans "${NODE_IP}" "${STORAGE_POOL}"
  done

  # =====================================================================
  echo ""
  echo "=== Regression: DNS Integrity ==="
  # =====================================================================

  # R5.1 — Both DNS servers return identical zone data [env]
  for ENV in "${ENVS[@]}"; do
    DNS1_IP=$(yq -r ".vms.dns1_${ENV}.ip" "$CONFIG")
    DNS2_IP=$(yq -r ".vms.dns2_${ENV}.ip" "$CONFIG")
    DNS_DOMAIN="${ENV}.$(yq -r '.domain' "$CONFIG")"
    VAULT_IP=$(yq -r ".vms.vault_${ENV}.ip" "$CONFIG")

    check "R5.1: DNS servers return identical data (${ENV})" \
      bash -c "
        RESULT1=\$(dig +short +time=3 vault.${DNS_DOMAIN} @${DNS1_IP})
        RESULT2=\$(dig +short +time=3 vault.${DNS_DOMAIN} @${DNS2_IP})
        [[ -n \"\$RESULT1\" && \"\$RESULT1\" == \"\$RESULT2\" ]]
      "
  done

  # R5.2 — DNS failover [destructive — dev only]
  if can_run_destructive; then
    check_skip "R5.2: DNS failover works (dns1-dev)" \
      "destructive test — run manually with care"
  else
    check_skip "R5.2: DNS failover works (dns1-dev)" \
      "destructive test, requires --regression dev"
  fi

  # =====================================================================
  echo ""
  echo "=== Regression: Backup Integrity ==="
  # =====================================================================

  # R6.1 — Backup jobs exist for precious-state VMs [cluster]
  BACKUP_VMS_REG=$(yq -r '.vms | to_entries[] | select(.value.backup == true) | .key' "$CONFIG")
  BACKUP_APPS_REG=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.backup == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)
  if [[ -n "$BACKUP_VMS_REG" || -n "$BACKUP_APPS_REG" ]]; then
    check "R6.1: Backup jobs exist for precious-state VMs" \
      "${SCRIPT_DIR}/configure-backups.sh" --verify
  else
    check_skip "R6.1: Backup jobs exist for precious-state VMs" \
      "no VMs with backup: true in config.yaml"
  fi

  # R6.2 — PBS backup/restore cycle [destructive — dev only]
  if can_run_destructive; then
    check_skip "R6.2: PBS backup/restore cycle (testapp-dev)" \
      "destructive test — run manually with care"
  else
    check_skip "R6.2: PBS backup/restore cycle (testapp-dev)" \
      "destructive test, requires --regression dev"
  fi

  # R6.3 — guest-side vdb gate removed from backup-backed VMs [env]
  r6_3_vdb_gate_absent() {
    local env="$1"
    local rows=""
    local failures=0
    local vdb_word="vdb"
    local legacy_service="wait-for-${vdb_word}.service"
    local legacy_target="${vdb_word}-ready.target"
    local legacy_flag="/run/secrets/${vdb_word}-restore-expected"

    rows="$(
      {
        yq -r "
          .vms
          | to_entries[]
          | select(.value.backup == true and (.key | test(\"_${env}\$\")))
          | [.key, .value.ip]
          | @tsv
        " "$CONFIG"
        yq -r "
          .applications // {}
          | to_entries[]
          | select(.value.enabled == true and .value.backup == true and (.value.environments.${env} // null) != null)
          | [.key + \"_${env}\", .value.environments.${env}.ip]
          | @tsv
        " "$APPS_CONFIG" 2>/dev/null || true
      } | sed '/^[[:space:]]*$/d'
    )"

    if [[ -z "$rows" ]]; then
      echo "no backup-backed ${env} VMs in config" >&2
      return 2
    fi

    while IFS=$'\t' read -r label ip; do
      [[ -n "$label" && -n "$ip" && "$ip" != "null" ]] || continue
      if ssh_node "root@${ip}" "
          set -e
          ! systemctl list-unit-files --no-legend \"${legacy_service}\" \"${legacy_target}\" 2>/dev/null | grep -q .
          ! systemctl list-units --all --no-legend \"${legacy_service}\" \"${legacy_target}\" 2>/dev/null | grep -q .
          test ! -e \"${legacy_flag}\"
        "; then
        echo "  ${label}: no guest-side vdb gate present" >&2
      else
        echo "  ${label}: legacy guest-side vdb gate still present" >&2
        failures=$((failures + 1))
      fi
    done <<< "$rows"

    [[ "$failures" -eq 0 ]]
  }

  for env in "${ENVS[@]}"; do
    check_capture "R6.3: Guest-side vdb gate removed (${env})" \
      r6_3_vdb_gate_absent "$env"
  done

  # =====================================================================
  echo ""
  echo "=== Regression: Tofu State Consistency ==="
  # =====================================================================

  # R7.1 — tofu plan shows only known drift [cluster]
  # Requires SOPS age key for tofu-wrapper.sh. Available on workstation and
  # CI/CD runner (both have /run/secrets/sops/age-key or operator.age.key).
  #
  # When running --regression-safe with a single env, uses -target flags to
  # check only the modules the pipeline deployed (Tier 1 data-plane VMs for
  # that env). This avoids false positives from Tier 2 control-plane VMs
  # whose images were built but not deployed by the pipeline.
  r7_1_tofu_drift() {
    local wrapper="${SCRIPT_DIR}/tofu-wrapper.sh"
    if [[ ! -f "${REPO_DIR}/site/tofu/image-versions.auto.tfvars" ]]; then
      echo "image-versions.auto.tfvars not found — skipping" >&2
      return 2  # signal skip
    fi
    if [[ ! -f "$wrapper" ]]; then
      echo "tofu-wrapper.sh not found" >&2
      return 2
    fi
    # Check for SOPS age key availability
    if [[ -z "${SOPS_AGE_KEY_FILE:-}" ]] \
       && [[ ! -f "${REPO_DIR}/operator.age.key" ]] \
       && [[ ! -f "${XDG_CONFIG_HOME:-${HOME}/.config}/sops/age/keys.txt" ]]; then
      echo "No SOPS age key available — skipping" >&2
      return 2
    fi

    # Build -target flags matching the pipeline deploy scope
    local targets=()
    if [[ "$REGRESSION_SAFE" -eq 1 && ${#ENVS[@]} -eq 1 ]]; then
      local env="${ENVS[0]}"
      if [[ "$env" == "dev" ]]; then
        targets=(-target=module.dns_dev -target=module.vault_dev -target=module.acme_dev -target=module.testapp_dev -target=module.influxdb_dev -target=module.grafana_dev -target=module.workstation_dev)
      elif [[ "$env" == "prod" ]]; then
        targets=(-target=module.dns_prod -target=module.vault_prod -target=module.gatus -target=module.testapp_prod -target=module.influxdb_prod -target=module.grafana_prod -target=module.workstation_prod)
      fi
    fi

    # Ensure tofu is initialized (test stage may start with clean .terraform/)
    # tofu-wrapper.sh does cd to framework/tofu/root/ — that's where .terraform/ lives
    if [[ ! -d "${REPO_DIR}/framework/tofu/root/.terraform" ]]; then
      "$wrapper" init -input=false >/dev/null 2>&1 || {
        echo "  tofu init failed — skipping" >&2
        return 2
      }
    fi

    local plan_output exitcode
    exitcode=0
    plan_output=$("$wrapper" plan -detailed-exitcode -no-color ${targets[@]+"${targets[@]}"} 2>&1) || exitcode=$?

    if [[ "$exitcode" -eq 0 ]]; then
      # No changes — ideal state
      echo "  tofu plan: no changes" >&2
      return 0
    elif [[ "$exitcode" -eq 2 ]]; then
      # Changes detected — check if they match known drift
      local adds changes destroys
      adds=$(echo "$plan_output" | sed -n 's/.*\([0-9][0-9]*\) to add.*/\1/p' | tail -1)
      changes=$(echo "$plan_output" | sed -n 's/.*\([0-9][0-9]*\) to change.*/\1/p' | tail -1)
      destroys=$(echo "$plan_output" | sed -n 's/.*\([0-9][0-9]*\) to destroy.*/\1/p' | tail -1)

      # Known drift thresholds — set to 0 when all VMs have current images
      local known_adds=0
      local known_changes=0
      local known_destroys=0

      if [[ "${adds:-0}" -le "$known_adds" ]] \
         && [[ "${changes:-0}" -le "$known_changes" ]] \
         && [[ "${destroys:-0}" -le "$known_destroys" ]]; then
        echo "  Known drift only: ${adds:-0} adds, ${changes:-0} changes, ${destroys:-0} destroys" >&2
        return 0
      else
        echo "  UNEXPECTED drift: ${adds:-0} adds, ${changes:-0} changes, ${destroys:-0} destroys" >&2
        return 1
      fi
    else
      echo "  tofu plan failed with exit code ${exitcode}" >&2
      echo "$plan_output" | tail -20 >&2
      return 1
    fi
  }

  # Capture function output and exit code. set +e prevents set -e from killing
  # the subshell (and the outer script) when the function returns non-zero.
  set +e
  R7_RESULT=$(r7_1_tofu_drift 2>&1; echo "EXIT:$?")
  set -e
  R7_EXIT=$(echo "$R7_RESULT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p' | tail -1)
  R7_MSG=$(echo "$R7_RESULT" | grep -v '^EXIT:')
  if [[ "$R7_EXIT" -eq 2 ]]; then
    check_skip "R7.1: tofu plan shows only known drift" \
      "${R7_MSG}"
  elif [[ "$R7_EXIT" -eq 0 ]]; then
    echo "[PASS] R7.1: tofu plan shows only known drift"
    [[ -n "$R7_MSG" ]] && echo "$R7_MSG"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] R7.1: tofu plan shows only known drift"
    [[ -n "$R7_MSG" ]] && echo "$R7_MSG"
    FAIL=$((FAIL + 1))
  fi

  # R7.2 — Control-plane VMs are running the desired live closures [cluster]
  #
  # This check compares the flake's desired closure path for gitlab/cicd
  # against /run/current-system on the live VMs. After Sprint 013, drift or
  # an incomplete check is a bug: the pipeline is responsible for deploying
  # these closures before R7.2 runs.
  r7_2_control_plane_drift() {
    if [[ ! -x "${SCRIPT_DIR}/check-control-plane-drift.sh" ]]; then
      echo "  check-control-plane-drift.sh not found or not executable" >&2
      return 2
    fi

    "${SCRIPT_DIR}/check-control-plane-drift.sh"
  }

  # Capture function output and exit code. set +e prevents set -e from killing
  # the subshell (and the outer script) when the function returns non-zero.
  set +e
  R7_2_RESULT=$(r7_2_control_plane_drift 2>&1; echo "EXIT:$?")
  set -e
  R7_2_EXIT=$(echo "$R7_2_RESULT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p' | tail -1)
  R7_2_MSG=$(echo "$R7_2_RESULT" | grep -v '^EXIT:')
  if [[ "$R7_2_EXIT" -eq 0 ]]; then
    echo "[PASS] R7.2: control-plane live closures match flake outputs"
    [[ -n "$R7_2_MSG" ]] && echo "$R7_2_MSG"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] R7.2: control-plane live closures match flake outputs"
    [[ -n "$R7_2_MSG" ]] && echo "$R7_2_MSG"
    FAIL=$((FAIL + 1))
  fi

  # R7.3 — grub.cfg boot-chain integrity on every framework NixOS VM [cluster]
  #
  # For each VM, SSH in and assert every ($drive*)/PATH referenced by
  # `linux` and `initrd` directives in /boot/grub/grub.cfg resolves to
  # a file on disk. Catches the #339 class silently before the next
  # cold boot bricks the VM. See:
  #   - #339 (this issue: verify-after-write + this probe)
  #   - #497 (retire the sed workaround entirely)
  #   - #496 (the 2026-07-06 incident that surfaced the gap)
  r7_3_boot_integrity() {
    if [[ ! -x "${SCRIPT_DIR}/check-boot-integrity.sh" ]]; then
      echo "  check-boot-integrity.sh not found or not executable" >&2
      return 2
    fi
    "${SCRIPT_DIR}/check-boot-integrity.sh"
  }

  set +e
  R7_3_RESULT=$(r7_3_boot_integrity 2>&1; echo "EXIT:$?")
  set -e
  R7_3_EXIT=$(echo "$R7_3_RESULT" | sed -n 's/^EXIT:\([0-9]*\)$/\1/p' | tail -1)
  R7_3_MSG=$(echo "$R7_3_RESULT" | grep -v '^EXIT:')
  if [[ "$R7_3_EXIT" -eq 0 ]]; then
    echo "[PASS] R7.3: grub.cfg boot-chain integrity"
    [[ -n "$R7_3_MSG" ]] && echo "$R7_3_MSG"
    PASS=$((PASS + 1))
  else
    echo "[FAIL] R7.3: grub.cfg boot-chain integrity"
    [[ -n "$R7_3_MSG" ]] && echo "$R7_3_MSG"
    FAIL=$((FAIL + 1))
  fi

fi  # end regression

# =====================================================================
echo ""
RESULT_LINE="Results: ${PASS} passed, ${FAIL} failed"
if [[ "$WARN" -gt 0 ]]; then
  RESULT_LINE="${RESULT_LINE}, ${WARN} warnings"
fi
if [[ "$SKIP" -gt 0 ]]; then
  RESULT_LINE="${RESULT_LINE} (${SKIP} skipped)"
fi
echo "========================================="
echo "$RESULT_LINE"
echo "========================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
