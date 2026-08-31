#!/usr/bin/env bash
# reclaim-images.sh — Off-hot-path image store reclamation.
#
# Usage:
#   reclaim-images.sh [--dry-run|--apply] [--role <role>] [--config <path>]
#
# Dry-run is the default. --apply deletes only images outside the conservative
# keep-set and stale upload partials older than one hour.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
FRAMEWORK_IMAGES="${REPO_DIR}/framework/images.yaml"
SITE_IMAGES="${REPO_DIR}/site/images.yaml"
DEPLOYED_HELPER="${MYCOFU_RECLAIM_DEPLOYED_HELPER:-${SCRIPT_DIR}/get-deployed-image-hashes.sh}"

APPLY=0
ROLE_FILTER=""
NOW="${MYCOFU_RECLAIM_NOW:-$(date +%s)}"
GRACE_SECONDS="${MYCOFU_RECLAIM_GRACE_SECONDS:-86400}"
PARTIAL_TTL_MINUTES="${MYCOFU_RECLAIM_PARTIAL_TTL_MINUTES:-60}"

usage() {
  sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      APPLY=0
      shift
      ;;
    --apply)
      APPLY=1
      shift
      ;;
    --role)
      ROLE_FILTER="$2"
      shift 2
      ;;
    --config)
      CONFIG="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config not found: $CONFIG" >&2
  exit 1
fi

IMAGE_STORAGE_PATH="$(yq -r '.proxmox.image_storage_path // "/var/lib/vz/template/iso"' "$CONFIG")"
if [[ -z "$IMAGE_STORAGE_PATH" || "$IMAGE_STORAGE_PATH" == "null" ]]; then
  echo "ERROR: proxmox.image_storage_path not set" >&2
  exit 1
fi

roles_from_manifest() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 0
  yq -r '.roles // {} | keys | .[]' "$manifest"
}

all_roles() {
  {
    roles_from_manifest "$FRAMEWORK_IMAGES"
    roles_from_manifest "$SITE_IMAGES"
  } | sed '/^$/d' | sort -u
}

node_rows() {
  yq -r '.nodes[] | [.name, .mgmt_ip] | @tsv' "$CONFIG"
}

contains_line() {
  local needle="$1"
  local haystack="$2"
  grep -Fxq "$needle" <<< "$haystack"
}

prefetch_deployed_sets() {
  local role="$1"
  local out_file="$2"

  if [[ ! -x "$DEPLOYED_HELPER" ]]; then
    echo "ERROR: deployed image helper not executable: $DEPLOYED_HELPER" >&2
    return 1
  fi

  "$DEPLOYED_HELPER" --strict --role "$role" > "$out_file"
}

remote_image_rows() {
  local node_ip="$1"
  local role="$2"

  ssh -n "root@${node_ip}" \
    "find ${IMAGE_STORAGE_PATH} -maxdepth 1 -type f -name '${role}-*.img' -printf '%f\t%T@\n' 2>/dev/null"
}

remote_in_use_images() {
  local node_ip="$1"

  ssh -n "root@${node_ip}" '
    for vmid in $(qm list 2>/dev/null | tail -n +2 | awk "{print \$1}"); do
      qm config "$vmid" 2>/dev/null | grep -oE "[^ ,]*:iso/[^ ,]+" | sed "s|.*iso/||"
    done
  ' | sort -u
}

remote_partial_rows() {
  local node_ip="$1"
  local role="$2"

  ssh -n "root@${node_ip}" \
    "find ${IMAGE_STORAGE_PATH} -maxdepth 1 -type f -name '${role}-*.img.partial.*' -mmin +${PARTIAL_TTL_MINUTES} -printf '%f\n' 2>/dev/null"
}

delete_remote_file() {
  local node_ip="$1"
  local filename="$2"

  ssh -n "root@${node_ip}" "rm -f ${IMAGE_STORAGE_PATH}/${filename}"
}

last_five_for_rows() {
  sort -k2,2nr | awk 'NR <= 5 {print $1}'
}

ROLE_LIST="$(all_roles)"
if [[ -n "$ROLE_FILTER" ]]; then
  if ! contains_line "$ROLE_FILTER" "$ROLE_LIST"; then
    echo "ERROR: role not found in image manifests: $ROLE_FILTER" >&2
    exit 1
  fi
  ROLE_LIST="$ROLE_FILTER"
fi

DEPLOYED_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reclaim-deployed.XXXXXX")"
trap 'rm -rf "$DEPLOYED_DIR"' EXIT

echo "=== Reclaim image store ($(if [[ "$APPLY" -eq 1 ]]; then echo apply; else echo dry-run; fi)) ==="
echo "Image path: ${IMAGE_STORAGE_PATH}"

for role in $ROLE_LIST; do
  prefetch_deployed_sets "$role" "${DEPLOYED_DIR}/${role}.txt"
done

while IFS= read -r role; do
  [[ -z "$role" ]] && continue
  deployed_set="$(cat "${DEPLOYED_DIR}/${role}.txt")"

  echo ""
  echo "==> role ${role}"

  while IFS=$'\t' read -r node_name node_ip; do
    [[ -z "${node_name:-}" || -z "${node_ip:-}" ]] && continue
    echo "-- ${node_name} (${node_ip})"

    image_rows="$(remote_image_rows "$node_ip" "$role")"
    in_use_set="$(remote_in_use_images "$node_ip")"
    last_five_set="$(printf '%s\n' "$image_rows" | last_five_for_rows)"

    while IFS=$'\t' read -r filename mtime_raw; do
      [[ -z "${filename:-}" ]] && continue
      mtime="${mtime_raw%.*}"
      [[ "$mtime" =~ ^[0-9]+$ ]] || {
        echo "ERROR: could not determine mtime for ${node_name}:${filename}" >&2
        exit 1
      }

      age_seconds=$((NOW - mtime))
      if contains_line "$filename" "$last_five_set"; then
        echo "KEEP ${node_name}:${filename} reason=last-five"
      elif contains_line "$filename" "$deployed_set"; then
        echo "KEEP ${node_name}:${filename} reason=deployed"
      elif contains_line "$filename" "$in_use_set"; then
        echo "KEEP ${node_name}:${filename} reason=in-use"
      elif [[ "$age_seconds" -lt "$GRACE_SECONDS" ]]; then
        echo "KEEP ${node_name}:${filename} reason=grace"
      elif [[ "$APPLY" -eq 1 ]]; then
        echo "PRUNE ${node_name}:${filename} reason=unreferenced"
        delete_remote_file "$node_ip" "$filename"
      else
        echo "PRUNE ${node_name}:${filename} reason=unreferenced dry-run"
      fi
    done <<< "$image_rows"

    while IFS= read -r partial; do
      [[ -z "$partial" ]] && continue
      if [[ "$APPLY" -eq 1 ]]; then
        echo "SWEEP ${node_name}:${partial} reason=stale-partial"
        delete_remote_file "$node_ip" "$partial"
      else
        echo "SWEEP ${node_name}:${partial} reason=stale-partial dry-run"
      fi
    done < <(remote_partial_rows "$node_ip" "$role")
  done < <(node_rows)
done <<< "$ROLE_LIST"
