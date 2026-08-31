#!/usr/bin/env bash
# DRT-ID: DRT-009
# DRT-NAME: Key Rotation
# DRT-TIME: depth-dependent
# DRT-DESTRUCTIVE: depth-dependent (rekey: no | resecret-all: yes)
# DRT-DESC: Orchestrate credential rotation by manifest row and depth.
#           DRT-009 routes key material by PATH only. It never decrypts
#           secret values into this script; per-driver and per-probe
#           stdout+stderr are captured to the evidence sink and the tail
#           is surfaced inline on failure (#800 fix). Drivers must not
#           emit raw key material on stdout/stderr — enforced by
#           V2.3-sentinel-leak and V2.7-prove-negative-redirection.

set -euo pipefail

DRT_ID="DRT-009"
DRT_NAME="Key Rotation"

source "$(dirname "$0")/../lib/common.sh"

eval "$(
  declare -f drt_finish | sed '1s/drt_finish/_drt_common_finish/'
)"

DEPTH=""
ONLY_SCOPE=""
DRT009_REGISTRY_PRINTED=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MANIFEST="${DRT009_MANIFEST_FILE:-${REPO_DIR}/site/rotation-manifest.yaml}"
CONFIG_FILE="${DRT009_CONFIG_FILE:-${REPO_DIR}/site/config.yaml}"
CHECK_MANIFEST_CMD="${DRT009_CHECK_MANIFEST_CMD:-${REPO_DIR}/framework/scripts/check-rotation-manifest.sh}"
BACKUP_NOW_CMD="${DRT009_BACKUP_NOW_CMD:-${REPO_DIR}/framework/scripts/backup-now.sh}"
VALIDATE_CMD="${DRT009_VALIDATE_CMD:-${REPO_DIR}/framework/scripts/validate.sh}"
TOFU_WRAPPER_CMD="${DRT009_TOFU_WRAPPER_CMD:-${REPO_DIR}/framework/scripts/tofu-wrapper.sh}"
PIPELINE_GREEN_CMD="${DRT009_PIPELINE_GREEN_CMD:-}"
# #839: measured DRT-009-triggered replication settle was <=15m under one
# workload; 30m is 2x headroom, with a 30s production poll cadence.
REPL_QUIESCE_POLL_SECONDS="${DRT009_REPL_QUIESCE_POLL_SECONDS:-30}"
REPL_QUIESCE_TIMEOUT_SECONDS="${DRT009_REPL_QUIESCE_TIMEOUT_SECONDS:-1800}"
UTC_STAMP="${DRT009_UTC_STAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
EVIDENCE_DIR="${DRT009_EVIDENCE_DIR:-${REPO_DIR}/build/drt/DRT-009/${UTC_STAMP}}"
ESCROW_BASE="${DRT009_ESCROW_BASE:-${HOME}/.mycofu-escrow}"
ESCROW_DIR="${DRT009_ESCROW_DIR:-${ESCROW_BASE}/${UTC_STAMP}}"
PRE_PIN_FILE="${DRT009_PRE_PIN_FILE:-${EVIDENCE_DIR}/pre-rotation-pin.json}"
POST_PIN_FILE="${DRT009_POST_PIN_FILE:-${EVIDENCE_DIR}/post-m4-rotation-pin.json}"
PRE_M1_DIGEST_FILE="${DRT009_PRE_M1_DIGEST_FILE:-${EVIDENCE_DIR}/pre-m1-plan-digest.txt}"
POST_M1_DIGEST_FILE="${DRT009_POST_M1_DIGEST_FILE:-${EVIDENCE_DIR}/post-m1-plan-digest.txt}"
SUMMARY_FILE="${EVIDENCE_DIR}/drt009-summary.txt"
PROVE_NEGATIVE_FILE="${EVIDENCE_DIR}/drt009-prove-negative-summary.txt"
DRIVER_LOG="${EVIDENCE_DIR}/driver-invocations.tsv"
PRE_PIN_VOLIDS=""
POST_PIN_VOLIDS=""
SECRET_CLASSES_TOUCHED=""

usage() {
  cat <<EOF
Usage:
  framework/dr-tests/run-dr-test.sh DRT-009 --depth {rekey|resecret-stateless|resecret-all} [--only <row>[,<row>...]]

Options:
  --depth   Required. One of: rekey, resecret-stateless, resecret-all.
  --only    Optional M4 target list. Valid only at --depth resecret-all.

Valid --only rows are manifest M4 match values:
$(valid_m4_targets 2>/dev/null | sed 's/^/  - /' || true)
EOF
}

valid_m4_targets() {
  [[ -r "$MANIFEST" ]] || return 0
  yq -r '.[] | select(.class == "M4" and has("match")) | .match' "$MANIFEST"
}

split_only_targets() {
  local value="$1" item
  IFS=',' read -r -a _drt009_only_parts <<< "$value"
  for item in "${_drt009_only_parts[@]}"; do
    [[ -n "$item" ]] || continue
    printf '%s\n' "$item"
  done
}

target_in_only_scope() {
  local target="$1" item
  [[ -n "$ONLY_SCOPE" ]] || return 1
  while IFS= read -r item; do
    [[ "$item" == "$target" ]] && return 0
  done < <(split_only_targets "$ONLY_SCOPE")
  return 1
}

validate_only_scope() {
  local target valid found
  while IFS= read -r target; do
    [[ -n "$target" ]] || {
      echo "ERROR: --only contains an empty row" >&2
      usage >&2
      exit 1
    }
    found=0
    while IFS= read -r valid; do
      if [[ "$valid" == "$target" ]]; then
        found=1
        break
      fi
    done < <(valid_m4_targets)
    if [[ "$found" -ne 1 ]]; then
      echo "ERROR: unknown --only row: ${target}" >&2
      usage >&2
      exit 1
    fi
  done < <(split_only_targets "$ONLY_SCOPE")
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --depth)
        [[ $# -ge 2 ]] || {
          usage >&2
          exit 1
        }
        DEPTH="$2"
        shift 2
        ;;
      --only)
        [[ $# -ge 2 ]] || {
          usage >&2
          exit 1
        }
        ONLY_SCOPE="$2"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done

  case "$DEPTH" in
    rekey|resecret-stateless|resecret-all) ;;
    *)
      usage >&2
      exit 1
      ;;
  esac

  if [[ -n "$ONLY_SCOPE" && "$DEPTH" != "resecret-all" ]]; then
    echo "targeting valid only at --depth resecret-all" >&2
    exit 1
  fi

  if [[ -n "$ONLY_SCOPE" ]]; then
    validate_only_scope
  fi

  case "$DEPTH" in
    rekey) SECRET_CLASSES_TOUCHED="M1" ;;
    resecret-stateless) SECRET_CLASSES_TOUCHED="M1,M3" ;;
    resecret-all) SECRET_CLASSES_TOUCHED="M1,M2,M3,M4,M5-automated" ;;
  esac
}

pin_volids() {
  local pin_file="$1"
  [[ -s "$pin_file" ]] || return 0
  jq -r '
    .pins // {} |
    to_entries[] |
    if (.value | type) == "object" then (.value.volid // empty) else .value end
  ' "$pin_file" 2>/dev/null | awk 'BEGIN{sep=""} NF{printf "%s%s", sep, $0; sep=","} END{print ""}'
}

record_line() {
  printf '%s\n' "$*" >> "$SUMMARY_FILE"
}

drt009_registry_fields() {
  if [[ "$DRT009_REGISTRY_PRINTED" -eq 1 ]]; then
    return 0
  fi
  DRT009_REGISTRY_PRINTED=1

  mkdir -p "$EVIDENCE_DIR"
  {
    printf 'depth=%s\n' "$DEPTH"
    printf 'only_scope=%s\n' "${ONLY_SCOPE:-none}"
    printf 'secret_classes_touched=%s\n' "$SECRET_CLASSES_TOUCHED"
    printf 'prove_negative_evidence=%s\n' "$PROVE_NEGATIVE_FILE"
    printf 'escrow_path=%s\n' "$ESCROW_DIR"
    printf 'pre_pbs_pin_volids=%s\n' "${PRE_PIN_VOLIDS:-none}"
    printf 'post_pbs_pin_volids=%s\n' "${POST_PIN_VOLIDS:-none}"
    printf 'evidence_sink=%s\n' "$EVIDENCE_DIR"
  } >> "$SUMMARY_FILE"

  echo ""
  echo "DRT-009 registry fields:"
  echo "  depth: ${DEPTH}"
  echo "  --only scope: ${ONLY_SCOPE:-none}"
  echo "  secret classes touched: ${SECRET_CLASSES_TOUCHED}"
  echo "  prove-negative evidence: ${PROVE_NEGATIVE_FILE}"
  echo "  escrow path: ${ESCROW_DIR}"
  echo "  pre PBS pin volids: ${PRE_PIN_VOLIDS:-none}"
  echo "  post PBS pin volids: ${POST_PIN_VOLIDS:-none}"
  echo "  evidence sink path: ${EVIDENCE_DIR}"
}

drt_finish() {
  drt009_registry_fields
  # Record the verdict in SUMMARY_FILE so the G3 post-process can fail closed
  # on an Act 1 whose summary survives a failed run. drt_finish always writes
  # registry lines regardless of DRT_FAILURES; a bare `test -s` on the summary
  # cannot distinguish PASS from FAIL. Mirrors the Act 2 driver's pass-only
  # prove-negative verdict sentinel
  # (framework/scripts/rotate-gitlab-root-password.sh:534-552).
  local _drt009_verdict
  if [[ "${DRT_FAILURES:-0}" -gt 0 ]]; then
    _drt009_verdict=FAIL
  elif [[ ${#DRT_BLOCKED_LIST[@]} -gt 0 ]]; then
    _drt009_verdict=BLOCKED
  else
    _drt009_verdict=PASS
  fi
  printf 'result=%s\n' "$_drt009_verdict" >> "$SUMMARY_FILE"
  _drt_common_finish
}

run_command_string_suppressed() {
  local command_string="$1"
  bash -c "$command_string" >/dev/null 2>/dev/null
}

# run_and_capture_to_evidence <log_path> <argv...>
# Runs <argv...> with stdout AND stderr captured to <log_path> (created,
# 0600). On non-zero exit, prints tail-9 of the combined log to DRT
# stdout with the seven-space indent already used by drt_assert (see
# framework/dr-tests/lib/common.sh:137), then prints the persistent log
# path so post-hoc diagnosis works even after scrollback is lost.
#
# This is the fix for #800: before it, run_driver_path_only discarded
# driver output entirely (>/dev/null 2>/dev/null), so the M1 driver's
# `git tree must be clean` error in G3 attempt 8 was undiagnosable from
# the DRT log alone (log operator had to read the driver source to know
# what its own message said). The precondition path (drt_check,
# framework/dr-tests/lib/common.sh:95-112) already prints captured output
# on failure; this helper brings the driver + probe paths to parity.
#
# Secret-safety: rotation drivers and probes must never emit raw key
# material on stdout/stderr (V2.7-prove-negative-redirection asserts this
# for `sops -d`; V2.3-sentinel-leak asserts it for rotate-sops-recipient.sh
# end-to-end). This helper captures verbatim; the driver-side ratchets are
# where redaction lives. Adding DRT-side scrubbing would give a false sense
# of protection against arbitrary emissions.
#
# Returns the child's exit code; caller decides whether to propagate.
run_and_capture_to_evidence() {
  local log_path="$1"; shift
  local rc
  # Fail-closed setup (#820 R2 codex P2-1 rev2): mkdir / truncate / chmod
  # must NOT silently swallow errors. drt_assert (framework/dr-tests/lib/
  # common.sh:126-128) invokes assertion helpers with errexit disabled;
  # without `|| return 1` a failing setup step is dropped on the floor
  # and the helper returns the child command's rc instead — masking the
  # setup failure entirely. Setting umask 077 process-locally covers the
  # narrow race window where the log path is replaced (unlink+create)
  # between our chmod and the subsequent `>"$log_path"` redirect: the
  # redirect would then open a fresh fd, and inheriting umask 077 keeps
  # it at 0600 even in that recreate case.
  local _prev_umask; _prev_umask="$(umask)"
  local final_chmod_rc
  umask 077
  mkdir -p "$(dirname "$log_path")" || { umask "$_prev_umask"; return 1; }
  : > "$log_path" || { umask "$_prev_umask"; return 1; }
  chmod 600 "$log_path" || { umask "$_prev_umask"; return 1; }
  set +e
  "$@" >"$log_path" 2>&1
  rc=$?
  # Final mode enforcement — belt-and-suspenders for the case where the
  # child command itself recreates or replaces the log by name. Runs
  # under drt_assert's `set +e` context, so the exit status is captured
  # explicitly rather than dropped on the floor. Codex R2 rev2 P2-1
  # flagged the earlier `... 2>/dev/null || true` form as still
  # unsafe: a child that unlinks/replaces the log with a non-chmod-able
  # object would let the helper report success while the persistent-log
  # 0600 contract is silently broken.
  chmod 600 "$log_path"
  final_chmod_rc=$?
  set -e
  umask "$_prev_umask"
  # Escalate the final chmod failure over a successful child rc: if the
  # child returned 0 but the persistent-log contract is broken, the
  # helper MUST report non-zero so drt_assert reports FAIL. If the
  # child already failed we keep its rc (the failure tail below is the
  # useful diagnostic) but still surface a chmod-broken note inline.
  if [[ "$final_chmod_rc" -ne 0 ]]; then
    echo "       (persistent-log 0600 contract broken: final chmod exit ${final_chmod_rc} for ${log_path})"
    if [[ "$rc" -eq 0 ]]; then
      return "$final_chmod_rc"
    fi
  fi
  if [[ "$rc" -ne 0 ]]; then
    # Budget: drt_assert re-tails our stdout to 10 lines (common.sh:137).
    # Cap the tail at 9 so the "See persistent log:" pointer survives
    # drt_assert's re-tail and every log-tail line is preserved
    # end-to-end (codex R1 P2 finding — tail-10 in a nested-tail chain
    # dropped one line silently).
    if [[ -s "$log_path" ]]; then
      tail -9 "$log_path" | sed 's/^/       /'
    else
      echo "       (driver produced no output on stdout or stderr)"
    fi
    echo "       See persistent log: ${log_path}"
  fi
  return "$rc"
}

# run_and_capture_command_string_to_evidence <log_path> <command_string>
# Same contract as run_and_capture_to_evidence but for probe strings from
# the manifest (which are shell command strings, not argv). Kept separate
# so the argv variant stays exec-based and cannot accidentally re-glob.
run_and_capture_command_string_to_evidence() {
  local log_path="$1"; shift
  local command_string="$1"
  local rc final_chmod_rc
  # Fail-closed setup and mode-enforcement — see run_and_capture_to_evidence
  # above for the full rationale (#820 R2 codex P2-1 rev2 and rev3).
  local _prev_umask; _prev_umask="$(umask)"
  umask 077
  mkdir -p "$(dirname "$log_path")" || { umask "$_prev_umask"; return 1; }
  : > "$log_path" || { umask "$_prev_umask"; return 1; }
  chmod 600 "$log_path" || { umask "$_prev_umask"; return 1; }
  set +e
  bash -c "$command_string" >"$log_path" 2>&1
  rc=$?
  chmod 600 "$log_path"
  final_chmod_rc=$?
  set -e
  umask "$_prev_umask"
  if [[ "$final_chmod_rc" -ne 0 ]]; then
    echo "       (persistent-log 0600 contract broken: final chmod exit ${final_chmod_rc} for ${log_path})"
    if [[ "$rc" -eq 0 ]]; then
      return "$final_chmod_rc"
    fi
  fi
  if [[ "$rc" -ne 0 ]]; then
    # Tail cap 9, same reason as run_and_capture_to_evidence above:
    # drt_assert re-tails our stdout to 10 (common.sh:137).
    if [[ -s "$log_path" ]]; then
      tail -9 "$log_path" | sed 's/^/       /'
    else
      echo "       (probe produced no output on stdout or stderr)"
    fi
    echo "       See persistent log: ${log_path}"
  fi
  return "$rc"
}

capture_replication_quiescence_failure_evidence() {
  local rows node_name node_ip safe_node message
  local -a ssh_opts=(
    -n
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o ServerAliveInterval=5
    -o ServerAliveCountMax=2
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
  )

  if ! rows="$(yq -r '.nodes[] | [.name, .mgmt_ip] | @tsv' "$CONFIG_FILE" 2>&1)"; then
    message="evidence capture failed to enumerate nodes from ${CONFIG_FILE}: ${rows}"
    echo "       ${message}"
    record_line "replication_quiescence_evidence_capture_error=${message}" || true
    return 1
  fi
  if [[ -z "$rows" ]]; then
    message="evidence capture found no nodes in ${CONFIG_FILE}"
    echo "       ${message}"
    record_line "replication_quiescence_evidence_capture_error=${message}" || true
    return 1
  fi

  while IFS=$'\t' read -r node_name node_ip; do
    [[ -n "$node_name" ]] || continue
    if [[ -z "$node_ip" || "$node_ip" == "null" ]]; then
      message="evidence capture skipped for ${node_name}: missing node IP"
      echo "       ${message}"
      record_line "replication_quiescence_evidence_capture_error=${message}" || true
      continue
    fi
    safe_node="$(printf '%s' "$node_name" | tr -c 'A-Za-z0-9._-' '_')"
    if ! ssh "${ssh_opts[@]}" "root@${node_ip}" \
      "timeout 10 pvesr status" \
      >"${EVIDENCE_DIR}/pvesr-status-${safe_node}.txt" 2>&1; then
      echo "       pvesr status capture failed for ${node_name}"
    fi
    if ! ssh "${ssh_opts[@]}" "root@${node_ip}" \
      "timeout 10 zpool status -x" \
      >"${EVIDENCE_DIR}/zpool-status-${safe_node}.txt" 2>&1; then
      echo "       zpool status -x capture failed for ${node_name}"
    fi
  done <<< "$rows"
}

wait_for_replication_quiescence() {
  local health_port storage_pool rows start_epoch deadline now_epoch sleep_for
  local waited node_name node_ip safe_node safe_key json json_file status
  local fail_reason bad_rows sample_errors first_sample last_error_keys
  local last_error_var last_error_summary error_key error_value

  first_sample=1
  last_error_keys=""

  if [[ ! -r "$CONFIG_FILE" ]]; then
    echo "config not readable: ${CONFIG_FILE}" >&2
    return 1
  fi
  health_port="$(yq -r '.replication.health_port' "$CONFIG_FILE")" || return 1
  storage_pool="$(yq -r '.proxmox.storage_pool' "$CONFIG_FILE")" || return 1
  if [[ "$health_port" == "null" || -z "$health_port" ]]; then
    echo "missing replication.health_port" >&2
    return 1
  fi
  if [[ "$storage_pool" == "null" || -z "$storage_pool" ]]; then
    echo "missing proxmox.storage_pool" >&2
    return 1
  fi
  if ! [[ "$REPL_QUIESCE_POLL_SECONDS" =~ ^[1-9][0-9]*$ &&
    "$REPL_QUIESCE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "invalid quiescence poll/cap seconds: " \
      "${REPL_QUIESCE_POLL_SECONDS}/${REPL_QUIESCE_TIMEOUT_SECONDS}" >&2
    return 1
  fi

  start_epoch="$(date +%s)"
  deadline=$((start_epoch + REPL_QUIESCE_TIMEOUT_SECONDS))
  while true; do
    rows="$(yq -r '.nodes[] | [.name, .mgmt_ip] | @tsv' "$CONFIG_FILE")" || return 1
    if [[ -z "$rows" ]]; then
      echo "no nodes found in ${CONFIG_FILE}" >&2
      return 1
    fi

    bad_rows=""
    sample_errors=""
    while IFS=$'\t' read -r node_name node_ip; do
      fail_reason=""
      status=""
      safe_node="$(printf '%s' "$node_name" | tr -c 'A-Za-z0-9._-' '_')"
      [[ -n "$safe_node" ]] || safe_node="unknown"
      safe_key="$(printf '%s' "${node_name:-unknown}" | tr -c 'A-Za-z0-9_' '_')"
      [[ -n "$safe_key" ]] || safe_key="unknown"
      json_file="${EVIDENCE_DIR}/repl-health-${safe_node}.json"

      if [[ -z "$node_name" || "$node_name" == "null" ||
        -z "$node_ip" || "$node_ip" == "null" ]]; then
        fail_reason="invalid node row"
      elif ! json="$(drt_curl -sf "http://${node_ip}:${health_port}/")"; then
        printf '%s\n' "$json" > "$json_file" || true
        fail_reason="curl failed"
      else
        printf '%s\n' "$json" > "$json_file" || return 1

        # Mirrors framework/scripts/validate.sh:2189 and :2203. The
        # staleness and ZFS predicates must stay in agreement with validate.sh.
        if ! status="$(printf '%s\n' "$json" | jq -re --arg pool "$storage_pool" '
          if (
            ((.replication_stale | type) != "boolean") or
            ((.zfs_pools | type) != "object") or
            ((.zfs_pools[$pool] | type) != "string") or
            (
              .zfs_pools.rpool != null and
              ((.zfs_pools.rpool | type) != "string")
            )
          ) then
            error("unparseable repl-health")
          elif (
            .replication_stale == false and
            .zfs_pools[$pool] == "healthy" and
            (.zfs_pools.rpool == null or .zfs_pools.rpool == "healthy")
          ) then
            "ok"
          else
            "stale=\(.replication_stale) " +
            "pool=\(.zfs_pools[$pool]) " +
            "rpool=\(.zfs_pools.rpool // "absent")"
          end
        ')"; then
          fail_reason="unparseable repl-health"
        fi
      fi

      if [[ -n "$fail_reason" ]]; then
        sample_errors="${sample_errors}${sample_errors:+; }${node_name:-unknown}(${fail_reason})"
        now_epoch="$(date +%s)"
        waited=$((now_epoch - start_epoch))
        echo "replication quiescence probe error: ${node_name:-unknown}: ${fail_reason}" >&2
        record_line \
          "replication_quiescence_probe_error=${waited}s ${node_name:-unknown}: ${fail_reason}"

        last_error_var="replication_quiescence_last_error_${safe_key}"
        printf -v "$last_error_var" '%s: %s' "${node_name:-unknown}" "$fail_reason"
        case " ${last_error_keys} " in
          *" ${safe_key} "*) ;;
          *) last_error_keys="${last_error_keys}${last_error_keys:+ }${safe_key}" ;;
        esac
        continue
      fi

      if [[ "$status" != "ok" ]]; then
        bad_rows="${bad_rows}${bad_rows:+; }${node_name}(${status})"
      fi
    done <<< "$rows"

    if [[ "$first_sample" -eq 1 ]]; then
      echo "replication quiescence start non-quiescent rows: ${bad_rows:-none}"
      echo "replication quiescence start probe errors: ${sample_errors:-none}"
      record_line "replication_quiescence_start_non_quiescent_rows=${bad_rows:-none}"
      record_line "replication_quiescence_start_probe_errors=${sample_errors:-none}"
      first_sample=0
    fi

    now_epoch="$(date +%s)"
    waited=$((now_epoch - start_epoch))
    if [[ -z "$bad_rows" && -z "$sample_errors" ]]; then
      echo "replication quiescence waited ${waited}s"
      record_line "replication_quiescence_waited_seconds=${waited}"
      return 0
    fi

    if [[ "$now_epoch" -ge "$deadline" ]]; then
      last_error_summary=""
      for error_key in $last_error_keys; do
        last_error_var="replication_quiescence_last_error_${error_key}"
        error_value="${!last_error_var:-}"
        [[ -n "$error_value" ]] || continue
        last_error_summary="${last_error_summary}${last_error_summary:+; }${error_value}"
      done
      [[ -n "$last_error_summary" ]] || last_error_summary="none"

      echo "replication quiescence cap exhausted with rows: " \
        "${bad_rows:-none}; last probe errors: ${last_error_summary}" >&2
      echo "replication quiescence waited ${waited}s"
      record_line "replication_quiescence_waited_seconds=${waited}"
      capture_replication_quiescence_failure_evidence || true
      return 1
    fi

    sleep_for="$REPL_QUIESCE_POLL_SECONDS"
    if [[ $((deadline - now_epoch)) -lt "$sleep_for" ]]; then
      sleep_for=$((deadline - now_epoch))
    fi
    if [[ "$sleep_for" -gt 0 ]]; then
      sleep "$sleep_for"
    fi
  done
}

run_validate_unscoped() {
  # #820: the pre-fix delegation to run_command_string_suppressed discarded
  # both stdout and stderr, so the G3 Act 1 20260731T231437Z transient FAIL
  # of validate.sh had no diagnosable evidence (every rotation assertion
  # PASSED for the first time in ten attempts; validate.sh alone was red
  # with unrecoverable identity). run_and_capture_command_string_to_evidence
  # is the #800 command-string variant: it writes stdout+stderr to a 0600
  # log in the evidence sink and, on non-zero exit, prints tail-9 plus the
  # log path so drt_assert's tail-10 re-tail (common.sh:137) carries the
  # inline tail forward. On success the log is still persisted for post-hoc
  # diagnosis of transients whose identity would otherwise be lost.
  run_and_capture_command_string_to_evidence \
    "${EVIDENCE_DIR}/validate-unscoped.log" \
    "$VALIDATE_CMD"
}

run_pipeline_green_verifier() {
  if [[ -n "$PIPELINE_GREEN_CMD" ]]; then
    run_command_string_suppressed "$PIPELINE_GREEN_CMD"
    return
  fi

  command -v glab >/dev/null 2>&1 || {
    echo "glab not found for GitLab pipeline-green verifier" >&2
    return 1
  }
  local project="${DRT009_GITLAB_PROJECT:-root%2Fmycofu}"
  local ref="${DRT009_GITLAB_REF:-dev}"
  local status
  status="$(glab api "/projects/${project}/pipelines?ref=${ref}&per_page=1" 2>/dev/null | jq -r '.[0].status // "none"')"
  case "$status" in
    success|running) return 0 ;;
    *) echo "latest pipeline status is ${status}" >&2; return 1 ;;
  esac
}

# Capture a canonical digest of `tofu plan` output for delta comparison.
#
# The M1 SOPS envelope rekey re-encrypts the SOPS DEK with the updated
# recipient list; the plaintext for every value except `sops_age_key`
# is preserved. `sops_age_key` itself is not exported as a TF_VAR by
# tofu-wrapper.sh, so no tofu plan input changes as a result of the
# rekey. But absolute convergence (an unscoped `tofu plan
# -detailed-exitcode` returning 0) cannot be asserted from a workstation
# checkout of dev against a live cluster where prod VMs run prod-branch
# images: pre-existing dev/prod image drift makes the plan non-empty
# regardless of the rekey. The drift-tolerant assertion is that the plan
# BEFORE the rekey equals the plan AFTER the rekey.
#
# Digest source: canonicalize `resource_changes` from
# `tofu show -json <plan>` (address + actions + before + after per entry,
# sorted by address, keys lexicographically sorted by `jq -S`). Uses the
# plan-out / show-json pattern already established at
# framework/scripts/rebuild-cluster.sh:1359,
# framework/scripts/safe-apply.sh:428, and
# framework/scripts/tofu-wrapper.sh:630.
#
# Fail-closed on every stage: plan file production, plan JSON extraction,
# jq canonicalization, and digest computation. An empty upstream stream
# would otherwise produce sha256("") = e3b0c442… (64 hex chars, would
# pass a naive length check) and both pre- and post-captures would agree
# on that value, silently falsifying a PASS.
#
# `-refresh=false` prevents provider refresh between the two captures
# from reordering computed attributes (or timestamps) into a spurious
# delta.
#
# `tofu-wrapper.sh:157` emits `Decrypting secrets...` on stdout before
# running the underlying subcommand, so `show -json` output begins with
# non-JSON preamble that would break jq. `sed -n '/^{/,$p'` skips
# everything before the first line whose first character is `{`.
# Robust for the actual wrapper: audited stdout emits at :157
# (`Decrypting secrets...`) and :394/:399 (`image_versions = {` /
# `}`), none of which start with `{`. tofu's `show -json` first output
# line always begins with `{`. The shape fixture exercises the strip
# end-to-end against the real preamble text.
capture_plan_digest() {
  local out_file="$1"
  local plan_file plan_json canonical digest
  local plan_rc show_rc jq_rc
  plan_file="$(mktemp)"
  plan_json="$(mktemp)"

  set +e
  "$TOFU_WRAPPER_CMD" plan -no-color -refresh=false -out="$plan_file" \
    >/dev/null 2>/dev/null
  plan_rc=$?
  set -e
  if [[ "$plan_rc" -ne 0 ]]; then
    rm -f "$plan_file" "$plan_json"
    return 1
  fi

  set +e
  "$TOFU_WRAPPER_CMD" show -json "$plan_file" 2>/dev/null \
    | sed -n '/^{/,$p' \
    > "$plan_json"
  show_rc=${PIPESTATUS[0]}
  set -e
  if [[ "$show_rc" -ne 0 || ! -s "$plan_json" ]]; then
    rm -f "$plan_file" "$plan_json"
    return 1
  fi

  # jq -e fails-closed on missing `.resource_changes`; the field is
  # required by the tofu plan JSON contract, so a missing value means
  # the plan JSON is malformed and no digest is defensible. Do not use
  # `// []` to swallow the malformed case — it would silently produce a
  # digest of the empty array on both pre and post captures and the
  # assertion would falsely PASS.
  set +e
  canonical="$(jq -S -c -e '
    .resource_changes
    | map({
        address,
        actions: (.change.actions // []),
        before: (.change.before // null),
        after: (.change.after // null)
      })
    | sort_by(.address)
  ' "$plan_json" 2>/dev/null)"
  jq_rc=$?
  set -e
  rm -f "$plan_file" "$plan_json"
  if [[ "$jq_rc" -ne 0 || -z "$canonical" ]]; then
    return 1
  fi

  digest="$(printf '%s' "$canonical" | sha256sum | awk '{print $1}')"
  [[ ${#digest} -eq 64 ]] || return 1
  printf '%s\n' "$digest" > "$out_file"
}

capture_pre_m1_plan_digest() {
  capture_plan_digest "$PRE_M1_DIGEST_FILE"
}

# Guard the M1 mutation on a successful pre-M1 baseline capture. If the
# baseline capture failed (drt_assert is non-fatal, so the driver call
# is otherwise unaffected), we must NOT run the mutation — there would
# be no baseline to compare against, and the assertion at the next
# drt_step would silently register a mismatch that reads as a rotation
# defect rather than a diagnostics gap.
run_m1_driver_if_baseline_captured() {
  if [[ ! -s "$PRE_M1_DIGEST_FILE" ]]; then
    echo "  M1 driver not invoked: pre-M1 plan digest missing" >&2
    return 1
  fi
  run_class_drivers M1 yes
}

assert_m1_plan_delta_zero() {
  # Property: an M1 envelope rekey must produce zero delta against the
  # pre-rotation plan. If the pre-digest is missing (previous step did not
  # capture), fail closed rather than silently pass.
  [[ -s "$PRE_M1_DIGEST_FILE" ]] || return 1
  capture_plan_digest "$POST_M1_DIGEST_FILE" || return 1
  local pre post
  pre="$(cat "$PRE_M1_DIGEST_FILE")"
  post="$(cat "$POST_M1_DIGEST_FILE")"
  [[ "$pre" == "$post" ]]
}

manifest_rows_for_class() {
  local class="$1"
  yq -r ".[] | select(.class == \"${class}\") | [(.match // .external // \"\"), (.driver // \"\"), (.probe // \"\")] | @tsv" "$MANIFEST"
}

class_has_rows() {
  local class="$1" count
  count="$(yq -r "[.[] | select(.class == \"${class}\")] | length" "$MANIFEST")"
  [[ "${count:-0}" -gt 0 ]]
}

manifest_m1_probe() {
  yq -r '.[] | select(.class == "M1" and .match == "sops_age_key") | .probe // ""' "$MANIFEST" | head -1
}

manifest_m1_holders() {
  yq -r '.[] | select(.class == "M1" and .match == "sops_age_key") | .holders[]? | [.name, .delivery] | @tsv' "$MANIFEST"
}

unique_driver_file_for_class() {
  local class="$1" out_file="$2" row driver probe
  : > "$out_file"
  while IFS=$'\t' read -r row driver probe; do
    [[ -n "$driver" ]] || continue
    [[ "$driver" == procedure:* ]] && continue
    if [[ "$class" == "M4" && -n "$ONLY_SCOPE" ]]; then
      target_in_only_scope "$row" || continue
    fi
    printf '%s\n' "$driver" >> "$out_file"
  done < <(manifest_rows_for_class "$class")
  sort -u "$out_file" -o "$out_file"
}

# Per-class driver invocation counter: file-backed rather than an
# associative array, because the operator workstation is macOS bash 3.2
# (see .claude/rules/platform.md — same reason enable-app.sh:119 avoids
# `declare -A`). One file per class under a hidden dir in the evidence
# sink; the file's integer content is the ordinal for that class within
# this run. Persists across sub-shells that source common.sh.
DRIVER_INVOCATION_COUNT_DIR="${EVIDENCE_DIR}/.drv-counts"

_next_driver_invocation_ordinal() {
  local label="$1" count_file count
  mkdir -p "$DRIVER_INVOCATION_COUNT_DIR"
  count_file="${DRIVER_INVOCATION_COUNT_DIR}/${label}"
  count=0
  [[ -s "$count_file" ]] && count=$(cat "$count_file")
  count=$((count + 1))
  printf '%s' "$count" > "$count_file"
  printf '%s' "$count"
}

run_driver_path_only() {
  local label="$1" driver="$2" i_mean_it="$3" rc
  local -a words
  # Manifest driver strings are intentionally simple command words plus args.
  # DRT-009 passes paths/args only. Output is captured to a per-invocation
  # log file in the evidence sink and the tail is surfaced on failure — see
  # run_and_capture_to_evidence above (#800 fix).
  # shellcheck disable=SC2206
  words=($driver)

  local count
  count="$(_next_driver_invocation_ordinal "$label")"
  local driver_log="${EVIDENCE_DIR}/driver-${label}-${count}.log"

  record_line "driver_start=${label}|${driver}|log=${driver_log#${REPO_DIR}/}"
  set +e
  if [[ "$i_mean_it" == "yes" ]]; then
    run_and_capture_to_evidence "$driver_log" \
      env \
        ROTATE_UTC_STAMP="$UTC_STAMP" \
        ROTATE_EVIDENCE_DIR="$EVIDENCE_DIR" \
        ROTATE_ESCROW_BASE="$ESCROW_BASE" \
        "${words[@]}" --i-mean-it
  else
    run_and_capture_to_evidence "$driver_log" \
      env \
        ROTATE_UTC_STAMP="$UTC_STAMP" \
        ROTATE_EVIDENCE_DIR="$EVIDENCE_DIR" \
        ROTATE_ESCROW_BASE="$ESCROW_BASE" \
        "${words[@]}"
  fi
  rc=$?
  set -e
  printf '%s\t%s\t%s\t%s\n' "$label" "$rc" "$driver" "${driver_log#${REPO_DIR}/}" >> "$DRIVER_LOG"
  record_line "driver_exit=${label}|${rc}"
  return "$rc"
}

run_class_drivers() {
  local class="$1" i_mean_it="$2" driver_file driver
  driver_file="${EVIDENCE_DIR}/drivers-${class}.txt"
  unique_driver_file_for_class "$class" "$driver_file"
  while IFS= read -r driver; do
    [[ -n "$driver" ]] || continue
    run_driver_path_only "$class" "$driver" "$i_mean_it" || return 1
  done < "$driver_file"
}

run_m1_holder_probes() {
  local probe holder delivery saw_holder=0
  probe="$(manifest_m1_probe)"
  [[ -n "$probe" && "$probe" != "null" ]] || {
    echo "M1 manifest row has no probe command" >&2
    return 1
  }
  local holder_idx=0
  while IFS=$'\t' read -r holder delivery; do
    [[ -n "$holder" ]] || continue
    saw_holder=1
    holder_idx=$((holder_idx + 1))
    # Sanitize the holder name for the filename in case a future manifest
    # ships a holder with punctuation. Current allowed set (checked by
    # framework/scripts/check-rotation-manifest.sh:101-103) is
    # `workstation` and `cicd`, both safe; the sanitizer is defense in
    # depth (codex R1 P3 finding — matches probe_rows_for_class's
    # existing safe_row sanitizer).
    local safe_holder
    safe_holder="$(printf '%s' "$holder" | tr -c 'A-Za-z0-9._-' '_')"
    local probe_log="${EVIDENCE_DIR}/m1-holder-probe-${holder_idx}-${safe_holder}.log"
    # Inline env-var assignment on a shell-function call: bash sets the
    # vars for the function's duration AND exports them to subshells that
    # function spawns (`bash -c "$probe"` inside the helper). `env` would
    # NOT work here — env expects an external program name and fails on
    # shell functions with "No such file or directory".
    if ! DRT009_HOLDER_NAME="$holder" DRT009_HOLDER_DELIVERY="$delivery" \
         run_and_capture_command_string_to_evidence "$probe_log" "$probe"; then
      return 1
    fi
  done < <(manifest_m1_holders)
  [[ "$saw_holder" -eq 1 ]]
}

run_probe_rows_for_class() {
  local class="$1" row driver probe
  local probe_idx=0
  while IFS=$'\t' read -r row driver probe; do
    [[ -n "$probe" && "$probe" != procedure:* ]] || continue
    probe_idx=$((probe_idx + 1))
    local safe_row
    # Sanitize row → filename-safe token; manifest match values are already
    # kebab / underscore / alnum in practice, but strip anything else.
    safe_row="$(printf '%s' "$row" | tr -c 'A-Za-z0-9._-' '_')"
    local probe_log="${EVIDENCE_DIR}/probe-${class}-${probe_idx}-${safe_row}.log"
    run_and_capture_command_string_to_evidence "$probe_log" "$probe" || return 1
  done < <(manifest_rows_for_class "$class")
}

run_m4_fresh_backup_assertion() {
  "$BACKUP_NOW_CMD" --pin-out "$POST_PIN_FILE" >/dev/null 2>/dev/null
  POST_PIN_VOLIDS="$(pin_volids "$POST_PIN_FILE")"
  [[ -s "$POST_PIN_FILE" ]]
}

assert_prove_negative_evidence() {
  : > "$PROVE_NEGATIVE_FILE"
  local count=0

  if [[ "$DEPTH" == "rekey" || "$DEPTH" == "resecret-stateless" || "$DEPTH" == "resecret-all" ]]; then
    if [[ -s "${EVIDENCE_DIR}/prove-negative.txt" ]]; then
      printf 'M1: exit=0 message=old SOPS recipient proof recorded at %s\n' "${EVIDENCE_DIR}/prove-negative.txt" >> "$PROVE_NEGATIVE_FILE"
      count=$((count + 1))
    else
      printf 'M1: exit=missing message=old SOPS recipient proof evidence missing\n' >> "$PROVE_NEGATIVE_FILE"
      return 1
    fi
  fi

  if [[ "$DEPTH" == "resecret-all" ]]; then
    while IFS= read -r proof; do
      [[ -n "$proof" ]] || continue
      printf 'M4: exit=0 message=401/403 old-credential proof recorded at %s\n' "$proof" >> "$PROVE_NEGATIVE_FILE"
      count=$((count + 1))
    done < <(find "$EVIDENCE_DIR" -type f -name '*prove-negative*.txt' ! -name 'drt009-prove-negative-summary.txt' 2>/dev/null | sort)
  fi

  [[ "$count" -gt 0 ]]
}

parse_args "$@"

mkdir -p "$EVIDENCE_DIR" "$ESCROW_DIR" "$(dirname "$PRE_PIN_FILE")" "$(dirname "$POST_PIN_FILE")"
chmod 0700 "$ESCROW_DIR"
: > "$SUMMARY_FILE"
: > "$DRIVER_LOG"
# Remove any stale digest files from a prior run in this evidence dir.
# The M1 baseline guard (`run_m1_driver_if_baseline_captured`) treats a
# non-empty $PRE_M1_DIGEST_FILE as proof the current-run capture
# succeeded. If DRT009_EVIDENCE_DIR / DRT009_UTC_STAMP / DRT009_PRE_M1_DIGEST_FILE
# are reused across runs and this run's `capture_pre_m1_plan_digest`
# fails (without touching the file), a stale digest from the prior
# run would falsely satisfy the guard. Truncate here so a failed
# current capture leaves the file empty and the guard fails closed.
rm -f "$PRE_M1_DIGEST_FILE" "$POST_M1_DIGEST_FILE"

export ROTATION_MANIFEST_FILE="$MANIFEST"

drt_init

# Preconditions: inventory is the first drt_check by construction.
drt_check "rotation manifest inventory" "$CHECK_MANIFEST_CMD"
drt_check "fresh backup pin" "$BACKUP_NOW_CMD" --pin-out "$PRE_PIN_FILE"
PRE_PIN_VOLIDS="$(pin_volids "$PRE_PIN_FILE")"
drt_check "escrow directory writable" test -d "$ESCROW_DIR" -a -w "$ESCROW_DIR"

drt_step "Rotate M1 envelope rekey"
drt_assert "pre-M1 tofu plan digest captured" capture_pre_m1_plan_digest
drt_assert "M1 driver completed by path" run_m1_driver_if_baseline_captured

drt_step "Validate M1 zero-plan and holder probes"
drt_assert "M1 tofu plan delta zero vs pre-M1 baseline" assert_m1_plan_delta_zero
drt_assert "M1 per-holder decrypt probes from manifest holders" run_m1_holder_probes

if [[ "$DEPTH" == "resecret-stateless" || "$DEPTH" == "resecret-all" ]]; then
  drt_step "Rotate M3 stateless service tokens"
  drt_assert "M3 owning drivers completed by manifest driver field" run_class_drivers M3 no

  drt_step "Validate M3 owning probes from manifest probe field"
  drt_assert "M3 probes completed" run_probe_rows_for_class M3
fi

if [[ "$DEPTH" == "resecret-all" ]]; then
  if class_has_rows M2; then
    drt_step "M2 attended CIDATA rotation and deploy review"
    drt_expect "M2 plan review complete; operator confirmed ordinary deploy/recreate envelope and abort point"
    drt_expect "M2 pipeline-green verifier passed" run_pipeline_green_verifier
  fi

  drt_step "M4 attended write-once credential rotations"
  drt_expect "M4 attended gate accepted; escrow, pin, emails, and abort points reviewed before mutation"
  drt_assert "M4 drivers completed by manifest driver field and --only scope" run_class_drivers M4 yes

  drt_step "Validate M4 sealed=false, new-token lookup-self OK, and fresh-backup assertion"
  drt_assert "M4 driver validation covered sealed=false and new-token lookup-self" test -s "$DRIVER_LOG"
  drt_assert "M4 fresh-backup assertion captured post PBS pin" run_m4_fresh_backup_assertion

  drt_step "Rotate M5 automated external rows"
  drt_assert "M5-automated drivers completed by manifest driver field" run_class_drivers M5-automated no
fi

# #839/#799: wait only on the condition that should disappear after runner
# secret delivery is decoupled from cicd VM-disk replication; once #799 lands,
# this should log ~0s and the step becomes deletable.
drt_step "Wait for replication quiescence before validate.sh"
_drt009_failures_before_quiescence="$DRT_FAILURES"
_drt009_quiescence_failed=0
drt_assert "replication quiescent before validate.sh" wait_for_replication_quiescence
if [[ "$DRT_FAILURES" -ne "$_drt009_failures_before_quiescence" ]]; then
  _drt009_quiescence_failed=1
fi

if [[ "$_drt009_quiescence_failed" -eq 0 ]]; then
  drt_step "Run unscoped validate.sh"
  drt_assert "validate.sh unscoped passes" run_validate_unscoped
fi

drt_step "Retire + PROVE-NEGATIVE evidence"
drt_assert "prove-negative evidence exists before drt_finish" assert_prove_negative_evidence

drt_finish
