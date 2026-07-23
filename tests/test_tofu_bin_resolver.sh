#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/framework/scripts/lib/tofu-bin.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "$SHIM_DIR"

cat > "${SHIM_DIR}/tofu" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${SHIM_DIR}/tofu"

test_start "1" "MYCOFU_TOFU_BIN override wins"
OVERRIDE="${TMP_DIR}/mycofu-tofu"
printf '#!/usr/bin/env bash\nexit 0\n' > "$OVERRIDE"
chmod +x "$OVERRIDE"
if [[ "$(MYCOFU_TOFU_BIN="$OVERRIDE" PATH="${SHIM_DIR}:${PATH}" mycofu_resolve_tofu_bin)" == "$OVERRIDE" ]]; then
  test_pass "explicit override is returned"
else
  test_fail "explicit override was not returned"
fi

test_start "2" "bad MYCOFU_TOFU_BIN fails closed"
BAD="${TMP_DIR}/missing-tofu"
set +e
OUT="$(MYCOFU_TOFU_BIN="$BAD" PATH="${SHIM_DIR}:${PATH}" mycofu_resolve_tofu_bin 2>&1)"
RC=$?
set -e
if [[ $RC -ne 0 && "$OUT" == *"MYCOFU_TOFU_BIN is not executable"* ]]; then
  test_pass "bad override fails with diagnostic"
else
  test_fail "bad override did not fail closed"
  printf '    rc=%s output=%s\n' "$RC" "$OUT" >&2
fi

test_start "3" "PATH tofu is used without override"
unset MYCOFU_TOFU_BIN || true
if [[ "$(PATH="${SHIM_DIR}:${PATH}" mycofu_resolve_tofu_bin)" == "${SHIM_DIR}/tofu" ]]; then
  test_pass "PATH fallback resolves tofu"
else
  test_fail "PATH fallback did not resolve shim tofu"
fi

test_start "4" "missing tofu fails closed"
EMPTY_PATH="${TMP_DIR}/empty-path"
mkdir -p "$EMPTY_PATH"
unset MYCOFU_TOFU_BIN || true
set +e
OUT="$(PATH="$EMPTY_PATH" mycofu_resolve_tofu_bin 2>&1)"
RC=$?
set -e
if [[ $RC -ne 0 && "$OUT" == *"Required tool not found: tofu"* ]]; then
  test_pass "missing tofu fails with diagnostic"
else
  test_fail "missing tofu did not fail closed"
  printf '    rc=%s output=%s\n' "$RC" "$OUT" >&2
fi

runner_summary
