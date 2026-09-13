#!/usr/bin/env bash
# configure-backups.sh — Reconcile the managed Proxmox vzdump backup job.
#
# Usage:
#   framework/scripts/configure-backups.sh
#   framework/scripts/configure-backups.sh --verify   # Check only, don't write
#
# The managed job is a closed framework policy: one backup job covers every
# enabled VM marked backup:true in site config, and every tracked field is
# compared, reconciled, and read back after writes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"

VERIFY_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify) VERIFY_ONLY=1; shift ;;
    --help|-h)
      sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: ${CONFIG}" >&2
  exit 1
fi

FIRST_NODE_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")
BACKUP_SCHEDULE=$(yq -r '.pbs.backup_schedule // "02:00"' "$CONFIG")

# The marker MUST be ASCII-only. Earlier versions used an em-dash (U+2014)
# which round-trips broken through pvesh: Perl writes the UTF-8 bytes to a
# non-:utf8 filehandle in /usr/share/perl5/PVE/File.pm (logged as
# "Wide character in print at .../File.pm line 77"), and the read-back via
# pvesh get returns the bytes interpreted as Latin-1. The drift report then
# always reports a notes-template mismatch, configure-backups.sh exits 1,
# and rebuild-cluster.sh / the deploy:prod pipeline both fail at Step 15.5
# / post-success convergence. See run logs/rebuild-cluster-196.log line
# 4047 and prod pipeline #1099 deploy:prod failure for reproductions.
#
# tests/test_configure_backups_marker_ascii.sh asserts this stays ASCII.
MANAGED_MARKER="Precious state -- automated by configure-backups.sh"
PBS_STORAGE="pbs-nas"
BACKUP_MODE="snapshot"
BACKUP_COMPRESS="zstd"
EXPECTED_ALL="0"
EXPECTED_EXCLUDE=""
EXPECTED_ENABLED="1"
TRACKED_FIELDS="enabled storage mode compress all exclude notes-template schedule vmid"

EXPECTED_ROWS=""
EXPECTED_VMIDS=""
MANAGED_JOB_JSON=""
MANAGED_JOB_ID=""

die() {
  echo "ERROR: $*" >&2
  exit 1
}

pve_ssh() {
  # LogLevel=ERROR suppresses the "Warning: Permanently added <host> to the list
  # of known hosts" line that SSH prints on first connect (every connect, since
  # UserKnownHostsFile=/dev/null). Without it, fetch_json's stderr capture folds
  # that warning into the JSON and trips the invalid-JSON die.
  ssh -n -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o LogLevel=ERROR "root@${FIRST_NODE_IP}" "$@"
}

normalize_vmid_list() {
  local value="${1:-}"

  [[ -z "$value" || "$value" == "null" ]] && return 0
  printf '%s\n' "$value" \
    | tr ',' '\n' \
    | awk 'NF { print $0 + 0 }' \
    | sort -n \
    | awk 'BEGIN { sep="" } { printf "%s%s", sep, $0; sep="," } END { print "" }'
}

normalize_bool() {
  local value="${1:-}"
  local default_value="$2"

  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    ""|"null") echo "$default_value" ;;
    1|true|yes|on) echo "1" ;;
    0|false|no|off) echo "0" ;;
    *) echo "$value" ;;
  esac
}

canonical_value() {
  local field="$1"
  local value="${2:-}"

  case "$field" in
    enabled) normalize_bool "$value" "1" ;;
    all) normalize_bool "$value" "0" ;;
    exclude)
      if [[ -z "$value" || "$value" == "null" ]]; then
        echo ""
      else
        echo "$value"
      fi
      ;;
    vmid) normalize_vmid_list "$value" ;;
    *)
      if [[ "$value" == "null" ]]; then
        echo ""
      else
        echo "$value"
      fi
      ;;
  esac
}

display_value() {
  local value="$1"
  if [[ -z "$value" ]]; then
    echo "<empty>"
  else
    echo "$value"
  fi
}

expected_value() {
  local field="$1"

  case "$field" in
    enabled) echo "$EXPECTED_ENABLED" ;;
    storage) echo "$PBS_STORAGE" ;;
    mode) echo "$BACKUP_MODE" ;;
    compress) echo "$BACKUP_COMPRESS" ;;
    all) echo "$EXPECTED_ALL" ;;
    exclude) echo "$EXPECTED_EXCLUDE" ;;
    notes-template) echo "$MANAGED_MARKER" ;;
    schedule) echo "$BACKUP_SCHEDULE" ;;
    vmid) echo "$EXPECTED_VMIDS" ;;
    *) die "unknown tracked field: $field" ;;
  esac
}

job_field() {
  local job_json="$1"
  local field="$2"

  case "$field" in
    vmid)
      printf '%s\n' "$job_json" | jq -r '
        if has("vmid") then
          if (.vmid | type) == "array" then
            .vmid | map(tostring) | join(",")
          else
            .vmid | tostring
          end
        else
          ""
        end
      '
      ;;
    exclude)
      printf '%s\n' "$job_json" | jq -r '
        if has("exclude") then
          if (.exclude | type) == "array" then
            .exclude | map(tostring) | join(",")
          else
            (.exclude // "") | tostring
          end
        else
          ""
        end
      '
      ;;
    *)
      printf '%s\n' "$job_json" | jq -r --arg field "$field" '
        if has($field) then .[$field] | tostring else "" end
      '
      ;;
  esac
}

build_drift_report() {
  local job_json="$1"
  local field expected_raw actual_raw expected actual

  for field in $TRACKED_FIELDS; do
    expected_raw="$(expected_value "$field")"
    actual_raw="$(job_field "$job_json" "$field")"
    expected="$(canonical_value "$field" "$expected_raw")"
    actual="$(canonical_value "$field" "$actual_raw")"

    if [[ "$expected" != "$actual" ]]; then
      printf '%s: expected=%s actual=%s\n' \
        "$field" "$(display_value "$expected")" "$(display_value "$actual")"
    fi
  done
}

load_expected_vmids() {
  EXPECTED_ROWS="$("${SCRIPT_DIR}/list-backup-backed-vmids.sh" --format tsv all)"

  if [[ -z "$EXPECTED_ROWS" ]]; then
    echo "No enabled VMs with backup: true in config"
    exit 0
  fi

  set_expected_vmids_from_rows
}

set_expected_vmids_from_rows() {
  EXPECTED_VMIDS="$(
    while IFS=$'\t' read -r vmid _ _; do
      [[ -z "${vmid:-}" ]] && continue
      echo "$vmid"
    done <<< "$EXPECTED_ROWS" | sort -n | awk 'BEGIN { sep="" } { printf "%s%s", sep, $0; sep="," } END { print "" }'
  )"

  [[ -n "$EXPECTED_VMIDS" ]] || die "no backup-backed VMIDs resolved from config"
}

print_expected_vmids() {
  echo "VMs marked for backup in the live reconciliation scope:"
  while IFS=$'\t' read -r vmid label env_name; do
    [[ -z "${vmid:-}" ]] && continue
    echo "  ${label} (${env_name}) -> VMID ${vmid}"
  done <<< "$EXPECTED_ROWS"
  echo ""
}

resource_has_vmid() {
  local resources_json="$1"
  local vmid="$2"

  printf '%s\n' "$resources_json" \
    | jq -e --argjson vmid "$vmid" '.[] | select((.vmid | tonumber) == $vmid)' >/dev/null
}

env_has_live_expected_vmid() {
  local resources_json="$1"
  local target_env="$2"
  local vmid label env_name

  while IFS=$'\t' read -r vmid label env_name; do
    [[ -z "${vmid:-}" ]] && continue
    [[ "$env_name" == "$target_env" ]] || continue
    if resource_has_vmid "$resources_json" "$vmid"; then
      return 0
    fi
  done <<< "$EXPECTED_ROWS"

  return 1
}

fetch_json() {
  local command="$1"
  local label="$2"
  local output="" err_file err_output
  err_file="$(mktemp)"

  # Capture stdout (the JSON) separately from stderr so an SSH host-key warning
  # cannot contaminate the parsed JSON. LogLevel=ERROR (pve_ssh) also suppresses
  # that warning; this is the belt-and-suspenders.
  if ! output="$(pve_ssh "$command" 2>"$err_file")"; then
    err_output="$(cat "$err_file" 2>/dev/null)"; rm -f "$err_file"
    echo "${err_output:-$output}" >&2
    die "failed to query ${label}"
  fi
  rm -f "$err_file"
  if ! printf '%s\n' "$output" | jq -e . >/dev/null 2>&1; then
    echo "$output" >&2
    die "invalid JSON while querying ${label}"
  fi
  printf '%s\n' "$output"
}

verify_expected_vmids_exist() {
  local resources_json="$1"
  local missing="" skipped="" filtered_rows=""
  local vmid label env_name
  local any_live=0

  # Trade-off: this script is called both after full-cluster convergence and
  # during staged per-environment bringup. A wholly absent env is treated as
  # not deployed yet and omitted from the live job so present VMs still get
  # coverage; once any VM in an env exists, missing peers in that env fail
  # closed. Shared VMIDs are required as soon as any backup-backed VM exists,
  # because live resources alone cannot distinguish intentional shared absence
  # from a broken control-plane VM.
  while IFS=$'\t' read -r vmid label env_name; do
    [[ -z "${vmid:-}" ]] && continue
    if resource_has_vmid "$resources_json" "$vmid"; then
      filtered_rows+="${vmid}"$'\t'"${label}"$'\t'"${env_name}"$'\n'
      any_live=1
    fi
  done <<< "$EXPECTED_ROWS"

  if [[ "$any_live" -eq 0 ]]; then
    if [[ "$VERIFY_ONLY" -eq 1 ]]; then
      die "no configured backup-backed VMIDs are present in the live cluster"
    fi
    echo "No configured backup-backed VMs are present in the live cluster; nothing to reconcile yet"
    exit 0
  fi

  while IFS=$'\t' read -r vmid label env_name; do
    [[ -z "${vmid:-}" ]] && continue
    if resource_has_vmid "$resources_json" "$vmid"; then
      continue
    fi

    if [[ "$env_name" == "shared" ]] || env_has_live_expected_vmid "$resources_json" "$env_name"; then
      missing+=" ${vmid}(${label}/${env_name})"
    else
      skipped+=" ${vmid}(${label}/${env_name})"
    fi
  done <<< "$EXPECTED_ROWS"

  if [[ -n "$missing" ]]; then
    die "configured backup VMID(s) missing from active live scope:${missing}"
  fi

  if [[ -n "$skipped" ]]; then
    echo "Skipping backup VMID(s) for envs not yet present in the live cluster:${skipped}"
  fi

  EXPECTED_ROWS="${filtered_rows%$'\n'}"
  set_expected_vmids_from_rows
}

find_managed_job() {
  local jobs_json="$1"
  local marker_count legacy_count candidate_count

  MANAGED_JOB_JSON=""
  MANAGED_JOB_ID=""

  marker_count="$(printf '%s\n' "$jobs_json" \
    | jq --arg marker "$MANAGED_MARKER" '[.[] | select((.["notes-template"] // "") == $marker)] | length')"
  candidate_count="$(printf '%s\n' "$jobs_json" \
    | jq --arg marker "$MANAGED_MARKER" --arg storage "$PBS_STORAGE" \
      '[.[] | select(((.["notes-template"] // "") == $marker) or ((.storage // "") == $storage))] | length')"

  if [[ "$marker_count" -gt 1 ]]; then
    die "ambiguous managed backup jobs: ${marker_count} jobs have marker '${MANAGED_MARKER}'"
  fi

  if [[ "$marker_count" -eq 1 ]]; then
    if [[ "$candidate_count" -gt 1 ]]; then
      die "ambiguous managed backup jobs: marker job exists alongside legacy ${PBS_STORAGE} candidate"
    fi
    MANAGED_JOB_JSON="$(printf '%s\n' "$jobs_json" \
      | jq -c --arg marker "$MANAGED_MARKER" '[.[] | select((.["notes-template"] // "") == $marker)] | first')"
  else
    legacy_count="$(printf '%s\n' "$jobs_json" \
      | jq --arg storage "$PBS_STORAGE" '[.[] | select((.storage // "") == $storage)] | length')"
    if [[ "$legacy_count" -gt 1 ]]; then
      die "ambiguous legacy backup jobs: ${legacy_count} jobs use storage ${PBS_STORAGE}"
    fi
    if [[ "$legacy_count" -eq 1 ]]; then
      MANAGED_JOB_JSON="$(printf '%s\n' "$jobs_json" \
        | jq -c --arg storage "$PBS_STORAGE" '[.[] | select((.storage // "") == $storage)] | first')"
    fi
  fi

  if [[ -n "$MANAGED_JOB_JSON" && "$MANAGED_JOB_JSON" != "null" ]]; then
    MANAGED_JOB_ID="$(printf '%s\n' "$MANAGED_JOB_JSON" | jq -r '.id // empty')"
    [[ -n "$MANAGED_JOB_ID" ]] || die "managed backup job is missing an id"
  fi
}

full_spec_command_args() {
  printf "%s" \
    "--enabled ${EXPECTED_ENABLED} " \
    "--storage ${PBS_STORAGE} " \
    "--mode ${BACKUP_MODE} " \
    "--compress ${BACKUP_COMPRESS} " \
    "--all ${EXPECTED_ALL} "
  if [[ -n "$EXPECTED_EXCLUDE" ]]; then
    printf "%s" "--exclude '${EXPECTED_EXCLUDE}' "
  fi
  printf "%s" \
    "--notes-template '${MANAGED_MARKER}' " \
    "--schedule '${BACKUP_SCHEDULE}' " \
    "--vmid '${EXPECTED_VMIDS}'"
}

clear_live_exclude_if_needed() {
  local job_id="$1"
  local job_json="$2"
  local actual_exclude

  actual_exclude="$(canonical_value exclude "$(job_field "$job_json" exclude)")"
  if [[ -z "$EXPECTED_EXCLUDE" && -n "$actual_exclude" ]]; then
    pve_ssh "pvesh set /cluster/backup/${job_id} --delete exclude"
  fi
}

write_full_spec() {
  local mode="$1"
  local job_id="${2:-}"
  local job_json="${3:-}"
  local command=""

  if [[ "$mode" == "create" ]]; then
    command="pvesh create /cluster/backup $(full_spec_command_args)"
  else
    clear_live_exclude_if_needed "$job_id" "$job_json"
    command="pvesh set /cluster/backup/${job_id} $(full_spec_command_args)"
  fi

  pve_ssh "$command"
}

read_back_and_verify() {
  local jobs_json drift

  jobs_json="$(fetch_json "pvesh get /cluster/backup --output-format json" "backup jobs")"
  find_managed_job "$jobs_json"
  [[ -n "$MANAGED_JOB_JSON" ]] || die "managed backup job missing after write"

  drift="$(build_drift_report "$MANAGED_JOB_JSON")"
  if [[ -n "$drift" ]]; then
    echo "ERROR: managed backup job still diverges after write:" >&2
    echo "$drift" >&2
    exit 1
  fi
}

load_expected_vmids
RESOURCES_JSON="$(fetch_json "pvesh get /cluster/resources --type vm --output-format json" "cluster VM resources")"
verify_expected_vmids_exist "$RESOURCES_JSON"
print_expected_vmids

JOBS_JSON="$(fetch_json "pvesh get /cluster/backup --output-format json" "backup jobs")"
find_managed_job "$JOBS_JSON"

if [[ -z "$MANAGED_JOB_JSON" ]]; then
  if [[ "$VERIFY_ONLY" -eq 1 ]]; then
    echo "VERIFY FAILED: no managed backup job exists for VMs with precious state" >&2
    exit 1
  fi

  echo "Creating managed backup job..."
  echo "  VMIDs: ${EXPECTED_VMIDS}"
  write_full_spec create
  read_back_and_verify
  echo "Backup job created and read-back verified"
  exit 0
fi

DRIFT="$(build_drift_report "$MANAGED_JOB_JSON")"
if [[ -z "$DRIFT" ]]; then
  echo "Backup job ${MANAGED_JOB_ID} matches spec"
  exit 0
fi

if [[ "$VERIFY_ONLY" -eq 1 ]]; then
  echo "VERIFY FAILED: managed backup job diverges from spec" >&2
  echo "$DRIFT" >&2
  exit 1
fi

echo "Backup job ${MANAGED_JOB_ID} drift detected:"
echo "$DRIFT"
echo "Writing full managed backup spec..."
write_full_spec set "$MANAGED_JOB_ID" "$MANAGED_JOB_JSON"
read_back_and_verify
echo "Backup job ${MANAGED_JOB_ID} reconciled and read-back verified"
