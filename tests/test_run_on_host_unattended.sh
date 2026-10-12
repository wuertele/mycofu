#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
FIXTURE="${TMP_DIR}/benchmarks"
SHIMS="${TMP_DIR}/shims"
SSH_LOG="${TMP_DIR}/ssh.log"
RSYNC_LOG="${TMP_DIR}/rsync.log"
cp -R "${REPO_ROOT}/benchmarks" "$FIXTURE"
mkdir -p "$SHIMS"

cat > "${FIXTURE}/influx-push.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${SHIMS}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SSH_LOG"
exit 0
EOF
cat > "${SHIMS}/rsync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$RSYNC_LOG"
last="${*: -1}"
if [[ "$last" != *:* ]]; then
  mkdir -p "${last%/}"
  printf '{}\n' > "${last%/}/env.json"
fi
EOF
chmod +x "${FIXTURE}/influx-push.sh" "${SHIMS}/ssh" "${SHIMS}/rsync"

test_start "1" "timeout, run-id, and keepalive are used"
if PATH="${SHIMS}:${PATH}" SSH_LOG="$SSH_LOG" RSYNC_LOG="$RSYNC_LOG" \
   "${FIXTURE}/run-on-host.sh" 192.0.2.10 unattended --timeout-sec 60 --run-id run123 >/tmp/run-on-host-unattended.out 2>&1 &&
   grep -q -- '-o ServerAliveInterval=30 -o ServerAliveCountMax=10' "$SSH_LOG" &&
   [[ "$(grep -c -- '-e ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=10' "$RSYNC_LOG" || true)" == "2" ]] &&
   grep -q "cd '/tmp/benchmarks-unattended-run123' && timeout 60 ./bench.sh unattended --trigger manual --no-push" "$SSH_LOG"; then
  test_pass "timeout, run-id, and SSH/rsync keepalive are wired"
else
  test_fail "unattended mode wiring missing"
  sed 's/^/    /' "$SSH_LOG" >&2
  sed 's/^/    /' "$RSYNC_LOG" >&2
fi

runner_summary
