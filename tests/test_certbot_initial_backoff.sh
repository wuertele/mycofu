#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

BIN_DIR="${TMP_DIR}/bin"
STATE_FILE="${TMP_DIR}/initial-retry.json"
CERTBOT_LOG="${TMP_DIR}/certbot.log"
SYNC_LOG="${TMP_DIR}/sync.log"
SLEEP_LOG="${TMP_DIR}/sleep.log"

mkdir -p "${BIN_DIR}"

cat > "${BIN_DIR}/certbot-command" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'run\n' >> "${CERTBOT_LOG}"
exit "${CERTBOT_EXIT_CODE:-1}"
EOF
chmod +x "${BIN_DIR}/certbot-command"

cat > "${BIN_DIR}/cert-sync" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sync\n' >> "${SYNC_LOG}"
EOF
chmod +x "${BIN_DIR}/cert-sync"

cat > "${BIN_DIR}/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "${SLEEP_LOG}"
EOF
chmod +x "${BIN_DIR}/sleep"

run_wrapper() {
  PATH="${BIN_DIR}:${PATH}" \
  CERTBOT_INITIAL_STATE_FILE="${STATE_FILE}" \
  CERTBOT_INITIAL_SINGLE_SHOT=1 \
  CERTBOT_FQDN="testapp.dev.example.com" \
  CERTBOT_LOG="${CERTBOT_LOG}" \
  SYNC_LOG="${SYNC_LOG}" \
  SLEEP_LOG="${SLEEP_LOG}" \
  CERTBOT_EXIT_CODE="${CERTBOT_EXIT_CODE:-1}" \
  "${REPO_ROOT}/framework/scripts/certbot-initial-wrapper.sh" \
  "${BIN_DIR}/certbot-command" \
  "${BIN_DIR}/cert-sync"
}

test_start "1" "first invocation runs immediately without sleeping"
rm -f "${STATE_FILE}" "${CERTBOT_LOG}" "${SYNC_LOG}" "${SLEEP_LOG}"
export CERTBOT_EXIT_CODE=1
set +e
run_wrapper >/dev/null 2>&1
FIRST_STATUS=$?
set -e
if [[ "${FIRST_STATUS}" -eq 1 ]] && \
   grep -Fxq 'run' "${CERTBOT_LOG}" && \
   [[ ! -e "${SLEEP_LOG}" ]] && \
   [[ "$(jq -r '.attempts' "${STATE_FILE}")" == "1" ]]; then
  test_pass "first failure records state and does not sleep"
else
  test_fail "first invocation should fail once without sleeping"
fi

test_start "2" "subsequent invocation reads the persisted 60s backoff"
: > "${CERTBOT_LOG}"
: > "${SLEEP_LOG}"
set +e
run_wrapper >/dev/null 2>&1
SECOND_STATUS=$?
set -e
if [[ "${SECOND_STATUS}" -eq 1 ]] && \
   grep -Fxq '60' "${SLEEP_LOG}" && \
   [[ "$(jq -r '.attempts' "${STATE_FILE}")" == "2" ]]; then
  test_pass "second failure sleeps for 60s and increments the retry state"
else
  test_fail "second invocation should honor the 60s backoff"
fi

test_start "3" "ten failures in 24h give up without running certbot again"
python3 - "${STATE_FILE}" <<'PY'
import json, sys, time
path = sys.argv[1]
with open(path, "w") as fh:
    json.dump({"attempts": 10, "first_failure_epoch": int(time.time())}, fh)
PY
rm -f "${CERTBOT_LOG}" "${SLEEP_LOG}"
set +e
GIVE_UP_OUTPUT="$(
  run_wrapper 2>&1
)"
GIVE_UP_STATUS=$?
set -e
if [[ "${GIVE_UP_STATUS}" -eq 1 ]] && \
   grep -Fq 'giving up for testapp.dev.example.com after 10 failures in 24h' <<< "${GIVE_UP_OUTPUT}" && \
   grep -Fq 'systemctl restart certbot-initial' <<< "${GIVE_UP_OUTPUT}" && \
   [[ ! -e "${CERTBOT_LOG}" ]]; then
  test_pass "wrapper refuses an eleventh attempt and prints the operator action"
else
  test_fail "wrapper should give up after ten failures in 24h"
  printf '    output:\n%s\n' "${GIVE_UP_OUTPUT}" >&2
fi

test_start "4" "success clears the retry state and runs cert-sync"
python3 - "${STATE_FILE}" <<'PY'
import json, sys, time
path = sys.argv[1]
with open(path, "w") as fh:
    json.dump({"attempts": 2, "first_failure_epoch": int(time.time())}, fh)
PY
rm -f "${CERTBOT_LOG}" "${SYNC_LOG}" "${SLEEP_LOG}"
export CERTBOT_EXIT_CODE=0
set +e
run_wrapper >/dev/null 2>&1
SUCCESS_STATUS=$?
set -e
unset CERTBOT_EXIT_CODE
if [[ "${SUCCESS_STATUS}" -eq 0 ]] && \
   grep -Fxq '120' "${SLEEP_LOG}" && \
   [[ ! -f "${STATE_FILE}" ]] && \
   grep -Fxq 'sync' "${SYNC_LOG}"; then
  test_pass "successful issuance clears state and triggers cert-sync"
else
  test_fail "success should clear retry state and run cert-sync"
fi

runner_summary
