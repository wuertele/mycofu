#!/usr/bin/env bash
# check-plan-images-present.sh — Fail before destructive apply if plan images are missing.
#
# Usage:
#   check-plan-images-present.sh --plan-json <path> [--config <path>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG="${REPO_DIR}/site/config.yaml"
PLAN_JSON=""

usage() {
  sed -n '2,/^$/{ s/^# //; s/^#$//; p }' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-json)
      PLAN_JSON="$2"
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

if [[ -z "$PLAN_JSON" ]]; then
  echo "ERROR: --plan-json is required" >&2
  exit 2
fi
if [[ ! -f "$PLAN_JSON" ]]; then
  echo "ERROR: plan JSON not found: $PLAN_JSON" >&2
  exit 1
fi
if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: config not found: $CONFIG" >&2
  exit 1
fi

IMAGE_STORAGE_PATH="$(yq -r '.proxmox.image_storage_path // "/var/lib/vz/template/iso"' "$CONFIG")"
if [[ -z "$IMAGE_STORAGE_PATH" || "$IMAGE_STORAGE_PATH" == "null" ]]; then
  echo "ERROR: proxmox.image_storage_path not set" >&2
  exit 1
fi

IMAGE_LIST="$(PLAN_JSON="$PLAN_JSON" python3 - <<'PY'
import json
import os
import re
import sys

with open(os.environ["PLAN_JSON"]) as f:
    plan = json.load(f)

images = set()
pattern = re.compile(r'(?:^|[,\s"])(?:local:iso/)([^,\s"]+\.img)(?:$|[,\s"])')

def walk(value):
    if isinstance(value, dict):
        for child in value.values():
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)
    elif isinstance(value, str):
        for match in pattern.finditer(value):
            images.add(match.group(1))

for change in plan.get("resource_changes", []):
    if not isinstance(change, dict):
        continue
    # Validate images only for actions that actually pull an image onto a
    # node: create and replace. No-ops, in-place updates, resumes, and
    # deletes do not consume the image — their `after.disk.file_id` may
    # be a historical value carried in state (e.g. control-plane VMs
    # whose disk uses ignore_changes and whose creation-time image has
    # since been reclaimed). Walking those false-positives blocks every
    # workstation full-plan warm rebuild for no real safety gain. See
    # #492 for the RCA. Action classification matches rebuild-cluster.sh
    # / safe-apply.sh restore-manifest predicate; only the create and
    # replace arms — a started-false-resume already had its image
    # consumed in the earlier stopped-create phase, so validating it
    # here would re-introduce the same false-positive class.
    change_obj = change.get("change")
    if change_obj is None:
        continue  # entry has no plan change block — nothing to validate.
    # Fail closed on malformed plan shapes. This is a pre-destructive-apply
    # safety guard; if it cannot classify an entry, the correct answer is
    # to refuse the deploy with a named diagnostic, not silently skip.
    address = change.get("address", "<unknown>")
    if not isinstance(change_obj, dict):
        print(
            f"ERROR: {address} has malformed change block "
            f"(expected dict, got {type(change_obj).__name__})",
            file=sys.stderr,
        )
        sys.exit(1)
    actions = change_obj.get("actions")
    if not isinstance(actions, list) or not actions or \
            not all(isinstance(a, str) for a in actions):
        print(
            f"ERROR: {address} has malformed change.actions "
            f"(expected non-empty list of strings, got {actions!r})",
            file=sys.stderr,
        )
        sys.exit(1)
    is_create = actions == ["create"]
    is_replace = "create" in actions and "delete" in actions
    if not (is_create or is_replace):
        continue
    after = change_obj.get("after")
    walk(after)

for image in sorted(images):
    print(image)
PY
)"

if [[ -z "$IMAGE_LIST" ]]; then
  echo "No plan-referenced local:iso/*.img images found"
  exit 0
fi

FAILURES=0
while IFS=$'\t' read -r node_name node_ip; do
  [[ -z "${node_name:-}" || -z "${node_ip:-}" ]] && continue
  while IFS= read -r image; do
    [[ -z "$image" ]] && continue
    if ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "root@${node_ip}" "test -s ${IMAGE_STORAGE_PATH}/${image}" 2>/dev/null; then
      echo "image ${image} present on node ${node_name} (${node_ip})"
    else
      echo "image ${image} missing on node ${node_name} (${node_ip}); did not deploy" >&2
      FAILURES=$((FAILURES + 1))
    fi
  done <<< "$IMAGE_LIST"
done < <(yq -r '.nodes[] | [.name, .mgmt_ip] | @tsv' "$CONFIG")

if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
