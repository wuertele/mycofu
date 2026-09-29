#!/usr/bin/env bash
# test_upload_atomicity.sh — upload atomicity: same-hash concurrent uploads use
# unique partials (UAT.1-3), and only a size-verified partial is ever promoted
# to the final path (UAT.4-5, #720).

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
if [[ "${UPLOAD_TRUNCATE:-0}" == "1" ]]; then
  # A transfer that exits 0 but lands the wrong number of bytes. scp cannot
  # be relied on to fail in this case, which is exactly why upload-image.sh
  # must size-check the partial itself.
  head -c 3 "$src" > "${REMOTE_ROOT}${path}"
else
  cp "$src" "${REMOTE_ROOT}${path}"
fi
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
    # The name-match skip. UPLOAD_FORCE_MISS forces each concurrent uploader
    # through the upload path for UAT.1-3; everywhere else this answers
    # honestly, so a run that follows a failed upload really does re-evaluate
    # the skip against remote state (the downstream step #720 is about).
    if [[ "${UPLOAD_FORCE_MISS:-0}" == "1" ]]; then
      exit 1
    fi
    test -s "${REMOTE_ROOT}/images/vault-aa000001.img"
    ;;
  "mkdir -p /images")
    mkdir -p "${REMOTE_ROOT}/images"
    ;;
  mv\ /images/vault-aa000001.img.partial.*\ /images/vault-aa000001.img)
    partial="${cmd#mv }"
    partial="${partial% /images/vault-aa000001.img}"
    mv "${REMOTE_ROOT}${partial}" "${REMOTE_ROOT}/images/vault-aa000001.img"
    ;;
  test\ -s\ /images/vault-aa000001.img*\ \&\&\ stat\ -c\ %s\ /images/vault-aa000001.img*)
    # Size-verify. Post-#720 the script checks the UNPROMOTED partial; the
    # DEST-targeted form is still answered so that a regression to
    # verify-after-mv runs to completion and is caught by the UAT.4/UAT.5
    # assertions below, rather than dying here as an "unexpected command".
    target="${cmd#test -s }"
    target="${target%% *}"
    test -s "${REMOTE_ROOT}${target}"
    wc -c < "${REMOTE_ROOT}${target}" | tr -d ' '
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
export REMOTE_ROOT UPLOAD_LOG="$LOG" UPLOAD_FORCE_MISS=1
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

# --- #720: a wrong-size transfer must never be promoted to DEST_PATH -------
#
# Uses a private remote root so the UAT.1-3 state above is untouched. The
# first run truncates the transfer; the second run is clean. Both runs are
# asserted, because the defect being guarded is not the failing run itself
# (which already errored before the fix) but what the NEXT run sees: a
# corrupt file at DEST_PATH satisfies the name-match skip forever.

REMOTE2="${TMP_DIR}/remote2"
LOG2="${TMP_DIR}/commands2.log"
FINAL2="${REMOTE2}/images/vault-aa000001.img"
mkdir -p "${REMOTE2}/images"
: > "$LOG2"

set +e
env REMOTE_ROOT="$REMOTE2" UPLOAD_LOG="$LOG2" UPLOAD_TRUNCATE=1 UPLOAD_FORCE_MISS=0 \
  bash "$SCRIPT" --config "$CONFIG" "$IMAGE" vault > "${TMP_DIR}/upload-trunc.out" 2>&1
RC_TRUNC=$?
set -e

test_start "UAT.4" "truncated transfer fails and never reaches the final path"
# The rejected bytes are asserted to REMAIN at the partial: upload-image.sh is
# append-only, so not-deleting them is a stated design property, not an
# accident. Removing them is reclaim's job, not the upload hot path's.
if [[ "$RC_TRUNC" -ne 0 ]] && [[ ! -e "$FINAL2" ]] &&
   grep -Fq "size mismatch" "${TMP_DIR}/upload-trunc.out" &&
   find "${REMOTE2}/images" -name '*.partial.*' | grep -q .; then
  test_pass "upload failed with a size mismatch; no final file, rejected bytes left at the partial"
else
  test_fail "truncated transfer was promoted or failed without diagnosis (rc=${RC_TRUNC})"
  cat "${TMP_DIR}/upload-trunc.out" >&2
  find "${REMOTE2}/images" -maxdepth 1 -type f -print >&2
fi

test_start "UAT.5" "a later clean run still uploads (no poisoned name-match skip)"
set +e
env REMOTE_ROOT="$REMOTE2" UPLOAD_LOG="$LOG2" UPLOAD_TRUNCATE=0 UPLOAD_FORCE_MISS=0 \
  bash "$SCRIPT" --config "$CONFIG" "$IMAGE" vault > "${TMP_DIR}/upload-retry.out" 2>&1
RC_RETRY=$?
set -e
if [[ "$RC_RETRY" -eq 0 ]] && cmp -s "$IMAGE" "$FINAL2" &&
   ! grep -Fq "already exists" "${TMP_DIR}/upload-retry.out"; then
  test_pass "retry uploaded the correct bytes instead of skipping a corrupt file"
else
  test_fail "retry skipped or produced wrong content (rc=${RC_RETRY})"
  cat "${TMP_DIR}/upload-retry.out" >&2
fi

runner_summary
