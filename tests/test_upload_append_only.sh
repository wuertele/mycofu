#!/usr/bin/env bash
# test_upload_append_only.sh — upload-image.sh never deletes.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/upload-image.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

CONFIG="${TMP_DIR}/config.yaml"
IMAGE="${TMP_DIR}/vault-aa000001.img"
SHIM_DIR="${TMP_DIR}/shims"
LOG="${TMP_DIR}/commands.log"

mkdir -p "$SHIM_DIR"
printf 'image-bytes\n' > "$IMAGE"
cat > "$CONFIG" <<'EOF'
proxmox:
  image_storage_path: /var/lib/vz/template/iso
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
EOF

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${2:-}" in
  ".proxmox.image_storage_path")
    echo "/var/lib/vz/template/iso"
    ;;
  ".nodes[].mgmt_ip")
    echo "127.0.0.1"
    ;;
  *)
    if [[ "${2:-}" == *'select(.mgmt_ip == "127.0.0.1")'* ]]; then
      echo "pve01"
    else
      echo "unexpected yq query: $*" >&2
      exit 9
    fi
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/yq"

export PATH="${SHIM_DIR}:${PATH}"

test_start "UAI.1" "upload-image.sh has no executable deletion primitive"
if grep -Eq '(^|[[:space:];|&])rm([[:space:]-]|$)|(^|[[:space:];|&])unlink([[:space:]]|$)|qm[[:space:]]+destroy' "$SCRIPT"; then
  test_fail "upload-image.sh contains rm/unlink/qm destroy"
  grep -En '(^|[[:space:];|&])rm([[:space:]-]|$)|(^|[[:space:];|&])unlink([[:space:]]|$)|qm[[:space:]]+destroy' "$SCRIPT" >&2 || true
else
  test_pass "no rm/unlink/qm destroy tokens in upload hot path"
fi

test_start "UAI.2" "--prune remains a deprecated no-op"
set +e
OUT="$(bash "$SCRIPT" --dry-run --prune --config "$CONFIG" "$IMAGE" vault 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 ]] &&
   grep -Fq -- "--prune is deprecated; reclaim is now a separate job; ignoring" <<< "$OUT" &&
   grep -Fq ".partial." <<< "$OUT" &&
   ! grep -Eq '(^|[[:space:];|&])rm([[:space:]-]|$)|unlink|qm[[:space:]]+destroy' <<< "$OUT"; then
  test_pass "--prune warns, upload dry-run proceeds, no delete command appears"
else
  test_fail "--prune no-op behavior changed"
  printf '%s\n' "$OUT" >&2
fi

test_start "UAI.3" "dry-run transcript uses scp to a per-uploader partial then mv"
if grep -Eq 'scp .*\.partial\.[0-9]+\.[0-9a-f]{4}' <<< "$OUT" &&
   grep -Eq 'mv .+\.partial\.[0-9]+\.[0-9a-f]{4} /var/lib/vz/template/iso/vault-aa000001\.img' <<< "$OUT"; then
  test_pass "dry-run shows partial upload and final rename"
else
  test_fail "dry-run did not show expected partial/mv shape"
  printf '%s\n' "$OUT" >&2
fi

runner_summary
