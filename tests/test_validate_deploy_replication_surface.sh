#!/usr/bin/env bash
# test_validate_deploy_replication_surface.sh — #535 regression.
#
# validate.sh's `--regression-deploy` helper phase must NOT swallow
# configure-replication.sh's stdout/stderr/exit. #502 tightened
# configure-replication.sh so that a newly-created job that never
# confirms a successful initial sync produces:
#   - a non-zero exit code,
#   - loud per-job State diagnostics on stderr.
#
# The old call form `configure-replication.sh "*" >/dev/null 2>&1 || true`
# muted all three signals. This test asserts:
#
#   1. Structural — the muting form is gone from validate.sh.
#   2. Behavioral — extract the surface block from validate.sh, run it
#      against a stub configure-replication.sh whose stdout/stderr are
#      distinctive and whose exit code is 7. Assert distinctive lines
#      appear in captured output AND the WARN line appears AND the
#      block does not itself exit non-zero (R2.6 owns FAIL later).
#
# shellcheck disable=SC2016
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

VALIDATE="${REPO_ROOT}/framework/scripts/validate.sh"

# --- Structural: the swallow form must be absent ---

test_start "535.a" "muting form 'configure-replication.sh \"*\" >/dev/null 2>&1 || true' is gone"
# Match the whole call form defensively — the flag can be spread on one line.
if grep -Eq 'configure-replication\.sh"[[:space:]]+"\*"[[:space:]]*>/dev/null[[:space:]]*2>&1[[:space:]]*\|\|[[:space:]]*true' "$VALIDATE"; then
  test_fail "found the swallowed call form in validate.sh"
else
  test_pass "no swallowed call form"
fi

test_start "535.b" "call form surfaces stdout/stderr (no >/dev/null on the configure-replication.sh line)"
if grep -nE 'configure-replication\.sh"[[:space:]]+"\*"' "$VALIDATE" | grep -Eq '>/dev/null|2>&1'; then
  test_fail "configure-replication.sh call still redirects stdout/stderr"
else
  test_pass "configure-replication.sh call preserves stdout/stderr"
fi

test_start "535.c" "the diagnostic line is emitted on non-zero exit"
# Look for the pointer to R2.6, not for a [WARN] prefix — see the
# `[WARN] deliberately not used` comment in validate.sh.
if grep -Fq 'configure-replication.sh: returned non-zero' "$VALIDATE" \
   && grep -Fq 'R2.6 replication health check below' "$VALIDATE"; then
  test_pass "diagnostic line present and points at R2.6"
else
  test_fail "diagnostic line missing or does not point at R2.6"
fi

test_start "535.d" "the exit code is captured (not lost to '|| true')"
# We expect a $? capture very near the call.
if grep -Fq 'CONFIGURE_REPL_RC=$?' "$VALIDATE"; then
  test_pass "exit code captured into CONFIGURE_REPL_RC"
else
  test_fail "exit code capture missing"
fi

# --- Behavioral: extract the surface block and exec it with a stub ---

# The block: from "  echo \"  Configuring replication...\"" up to and
# including the matching "  fi". We extract with awk, guarding against
# the block growing an inner "fi" by counting nested if-depth.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

BLOCK="$WORK/block.sh"

awk '
  # Enter the block on the first "Configuring replication..." echo.
  !in_blk && /echo "  Configuring replication\.\.\."/ { in_blk=1; depth=0 }
  in_blk {
    print
    # Block ends at the fi that matches the inner if introduced by
    # `if [[ "$CONFIGURE_REPL_RC" -ne 0 ]]; then` inside the block. If
    # there is no inner if (a future refactor removes the WARN branch),
    # exit at the first bare `fi` we see (depth goes to -1).
    if ($0 ~ /^[[:space:]]*if[[:space:]]/ ) depth++
    else if ($0 ~ /^[[:space:]]*fi[[:space:]]*$/ ) {
      depth--
      if (depth <= 0) exit
    }
  }
' "$VALIDATE" > "$BLOCK"

if [[ ! -s "$BLOCK" ]]; then
  test_start "535.e" "surface block is extractable"
  test_fail "could not extract surface block from validate.sh"
  runner_summary
  exit 1
fi

# Build a stub configure-replication.sh under a fake SCRIPT_DIR that:
#   - prints a distinctive stdout line
#   - prints a distinctive stderr line
#   - exits 7
STUB_DIR="$WORK/scripts"
mkdir -p "$STUB_DIR"
STUB="$STUB_DIR/configure-replication.sh"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
echo "STUB-STDOUT-VISIBLE-ABC"
echo "STUB-STDERR-VISIBLE-XYZ" >&2
exit 7
STUB_EOF
chmod +x "$STUB"

# Wrap the block in a runnable script that:
#   - sets SCRIPT_DIR to our stub dir,
#   - starts with `set -euo pipefail` to match validate.sh's disposition,
#   - after the block, echoes a marker so we can prove we reached the end
#     (i.e. the block did NOT exit the caller).
RUNNER="$WORK/runner.sh"
{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  # Match validate.sh: SCRIPT_DIR is the directory holding the scripts.
  echo "SCRIPT_DIR=\"$STUB_DIR\""
  cat "$BLOCK"
  echo 'echo "SURFACE-BLOCK-COMPLETED"'
} > "$RUNNER"
chmod +x "$RUNNER"

OUT="$WORK/out"
ERR="$WORK/err"
set +e
bash "$RUNNER" >"$OUT" 2>"$ERR"
RC=$?
set -e

test_start "535.e" "surface block extracted and executed"
if [[ -s "$OUT" ]]; then
  test_pass "surface block produced output"
else
  test_fail "surface block produced no output"
  echo "STDERR:" >&2
  cat "$ERR" >&2 || true
fi

test_start "535.f" "stub STDOUT is visible (not redirected to /dev/null)"
if grep -Fq 'STUB-STDOUT-VISIBLE-ABC' "$OUT"; then
  test_pass "stub stdout reached captured stdout"
else
  test_fail "stub stdout was swallowed"
  echo "captured stdout:" >&2; cat "$OUT" >&2 || true
fi

test_start "535.g" "stub STDERR is visible (not redirected to /dev/null)"
if grep -Fq 'STUB-STDERR-VISIBLE-XYZ' "$ERR"; then
  test_pass "stub stderr reached captured stderr"
else
  test_fail "stub stderr was swallowed"
  echo "captured stderr:" >&2; cat "$ERR" >&2 || true
fi

test_start "535.h" "diagnostic line is emitted for non-zero configure-replication.sh exit"
if grep -Fq 'configure-replication.sh: returned non-zero' "$OUT" \
   && grep -Fq 'R2.6 replication health check below' "$OUT"; then
  test_pass "diagnostic line seen in stdout, points at R2.6"
else
  test_fail "diagnostic line not emitted (or missing R2.6 pointer) despite non-zero stub exit"
  echo "captured stdout:" >&2; cat "$OUT" >&2 || true
fi

test_start "535.h2" "diagnostic line does NOT prefix with [WARN] (see counter-consistency note)"
if grep -Fq '[WARN] configure-replication.sh' "$OUT"; then
  test_fail "diagnostic uses [WARN] prefix — collides with unincremented WARN counter"
else
  test_pass "no [WARN] prefix on the diagnostic line"
fi

test_start "535.i" "surface block does not itself abort the caller (R2.6 owns FAIL)"
if [[ "$RC" -eq 0 ]] && grep -Fq 'SURFACE-BLOCK-COMPLETED' "$OUT"; then
  test_pass "caller continued past the block"
else
  test_fail "block aborted the caller (RC=$RC); the deploy helper phase must not exit here"
  echo "captured stdout:" >&2; cat "$OUT" >&2 || true
  echo "captured stderr:" >&2; cat "$ERR" >&2 || true
fi

runner_summary
