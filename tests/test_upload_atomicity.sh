#!/usr/bin/env bash
# test_upload_atomicity.sh — same-hash concurrent upload uses unique partials.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
REMOTE_ROOT="${TMP_DIR}/remote"
LOG="${TMP_DIR}/commands.log"
CONFIG="${TMP_DIR}/config.yaml"
IMAGE="${TMP_DIR}/vault-aa000001.img"
SCRIPT="${REPO_ROOT}/framework/scripts/upload-image.sh"

mkdir -p "$SHIM_DIR" "$REMOTE_ROOT/images"
printf 'same-content-for-both-uploaders\n' > "$IMAGE"
cat > "$CONFIG" <<'EOF'
proxmox:
  image_storage_path: /images
nodes:
  - name: pve01
    mgmt_ip: 127.0.0.1
EOF

cat > "${SHIM_DIR}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${2:-}" in
  ".proxmox.image_storage_path")
    echo "/images"
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

cat > "${SHIM_DIR}/scp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
src="$1"
dest="$2"
path="${dest#root@127.0.0.1:}"
printf 'scp %s\n' "$path" >> "${UPLOAD_LOG}"
mkdir -p "${REMOTE_ROOT}$(dirname "$path")"
cp "$src" "${REMOTE_ROOT}${path}"
sleep 0.1
EOF
chmod +x "${SHIM_DIR}/scp"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
printf 'ssh %s\n' "$cmd" >> "${UPLOAD_LOG}"
case "$cmd" in
  "test -s /images/vault-aa000001.img")
    # Force each concurrent uploader through the upload path. The later
    # verification command includes stat and is handled by the next branch.
    exit 1
    ;;
  "mkdir -p /images")
    mkdir -p "${REMOTE_ROOT}/images"
    ;;
  mv\ /images/vault-aa000001.img.partial.*\ /images/vault-aa000001.img)
    partial="${cmd#mv }"
    partial="${partial% /images/vault-aa000001.img}"
    mv "${REMOTE_ROOT}${partial}" "${REMOTE_ROOT}/images/vault-aa000001.img"
    ;;
  "test -s /images/vault-aa000001.img && stat -c %s /images/vault-aa000001.img")
    test -s "${REMOTE_ROOT}/images/vault-aa000001.img"
    wc -c < "${REMOTE_ROOT}/images/vault-aa000001.img" | tr -d ' '
    ;;
  "ls -lh /images/vault-aa000001.img")
    echo "-rw-r--r-- 1 root root $(wc -c < "${REMOTE_ROOT}/images/vault-aa000001.img") /images/vault-aa000001.img"
    ;;
  *)
    echo "unexpected ssh command: $cmd" >&2
    exit 9
    ;;
esac
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:${PATH}"
export REMOTE_ROOT UPLOAD_LOG="$LOG"
: > "$LOG"

run_upload() {
  bash "$SCRIPT" --config "$CONFIG" "$IMAGE" vault > "${TMP_DIR}/upload-$1.out" 2>&1
}

test_start "UAT.1" "two same-hash uploaders both succeed"
set +e
run_upload one &
PID1=$!
run_upload two &
PID2=$!
wait "$PID1"; RC1=$?
wait "$PID2"; RC2=$?
set -e
if [[ "$RC1" -eq 0 && "$RC2" -eq 0 ]]; then
  test_pass "both upload-image.sh invocations exited 0"
else
  test_fail "concurrent upload failed rc1=${RC1} rc2=${RC2}"
  cat "${TMP_DIR}"/upload-*.out >&2
fi

test_start "UAT.2" "partial upload paths are unique per uploader"
PARTIALS="$(grep '^scp /images/vault-aa000001.img.partial.' "$LOG" | awk '{print $2}' | sort -u)"
PARTIAL_COUNT="$(printf '%s\n' "$PARTIALS" | sed '/^$/d' | wc -l | tr -d ' ')"
if [[ "$PARTIAL_COUNT" -ge 2 ]]; then
  test_pass "observed at least two unique partial paths"
else
  test_fail "partial paths were not unique"
  cat "$LOG" >&2
fi

test_start "UAT.3" "final file is byte-identical and partials are gone"
if cmp -s "$IMAGE" "${REMOTE_ROOT}/images/vault-aa000001.img" &&
   ! find "${REMOTE_ROOT}/images" -name '*.partial.*' | grep -q .; then
  test_pass "final content matches and no partial remains"
else
  test_fail "final content or partial cleanup failed"
  find "${REMOTE_ROOT}/images" -maxdepth 1 -type f -print >&2
  cat "$LOG" >&2
fi

runner_summary
