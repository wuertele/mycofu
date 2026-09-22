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

test_start "1" "--trigger scheduled reaches remote bench.sh"
if PATH="${SHIMS}:${PATH}" SSH_LOG="$SSH_LOG" RSYNC_LOG="$RSYNC_LOG" \
   "${FIXTURE}/run-on-host.sh" 192.0.2.10 scheduled --trigger scheduled >/tmp/run-on-host-trigger.out 2>&1 &&
   grep -q './bench.sh scheduled --trigger scheduled --no-push' "$SSH_LOG"; then
  test_pass "--trigger scheduled propagated"
else
  test_fail "--trigger scheduled did not propagate"
  sed 's/^/    /' "$SSH_LOG" >&2
fi

test_start "2" "default manual trigger remains manual"
: > "$SSH_LOG"
if PATH="${SHIMS}:${PATH}" SSH_LOG="$SSH_LOG" RSYNC_LOG="$RSYNC_LOG" \
   "${FIXTURE}/run-on-host.sh" 192.0.2.10 manual-default >/tmp/run-on-host-trigger.out 2>&1 &&
   grep -q './bench.sh manual-default --trigger manual --no-push' "$SSH_LOG"; then
  test_pass "default manual trigger propagated"
else
  test_fail "default manual trigger missing"
fi

runner_summary
