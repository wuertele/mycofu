#!/usr/bin/env bash
# test_validate_gatus_noncert_diagnostics.sh — #618 regression.
#
# validate.sh's "All non-certificate Gatus endpoints healthy" aggregate check
# must, on failure, name each unhealthy endpoint (group/name/key) and the
# failing conditionResults. Before #618, the aggregate reported only a
# healthy/total count, which caused a multi-hour misdiagnosis on pipeline
# 1650 (see docs/reports/2026-07-17-gatus-github-mirror-noncert-check-rca).
#
# This is a diagnostic-only guard; the pass/fail decision is unchanged.
#
# The test has two parts:
#
#   A. Structural — grep validate.sh for the required diagnostic patterns,
#      so a future silent regression that reverts the check to the count-only
#      form is caught by CI.
#   B. Behavioral — reproduce the exact bash -c body from validate.sh (via
#      substitution) and run it against a synthesized Gatus payload with a
#      known-unhealthy replication endpoint. Assert the output names the
#      endpoint, names the failing condition, filters out the healthy
#      condition on the same endpoint, and honors the (cert_group +
#      "publishing") filter.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
# shellcheck source=tests/lib/runner.sh
source "${REPO_ROOT}/tests/lib/runner.sh"

VALIDATE="${REPO_ROOT}/framework/scripts/validate.sh"

# --- Part A: Structural checks ------------------------------------------------

test_start "618.a" "aggregate uses check_capture (which surfaces failure output)"
# The check line is `check_capture "All non-certificate Gatus endpoints healthy" \`.
# The plain `check` helper redirects stdout+stderr to /dev/null, which was the
# root cause: the diagnostic could not be printed.
if grep -Eq 'check_capture[[:space:]]+"All non-certificate Gatus endpoints healthy"' "$VALIDATE"; then
  test_pass "aggregate check uses check_capture"
else
  test_fail "aggregate check does not use check_capture — diagnostic output would be swallowed"
fi

test_start "618.b" "diagnostic preamble 'Unhealthy endpoints:' is present"
if grep -Fq "Unhealthy endpoints:" "$VALIDATE"; then
  test_pass "preamble present"
else
  test_fail "preamble missing"
fi

test_start "618.c" "diagnostic jq query references group, name, key, and conditionResults"
# The jq query must extract all four fields; each is the fix's contract.
missing=()
grep -Fq '.group //' "$VALIDATE" || missing+=("group")
grep -Fq '.name //' "$VALIDATE" || missing+=("name")
grep -Fq '.key //' "$VALIDATE" || missing+=("key")
grep -Fq 'conditionResults' "$VALIDATE" || missing+=("conditionResults")
if [[ ${#missing[@]} -eq 0 ]]; then
  test_pass "jq query references group/name/key/conditionResults"
else
  test_fail "jq query missing fields: ${missing[*]}"
fi

test_start "618.d" "diagnostic filters honor cert_group and \"publishing\""
# The diagnostic MUST use the same exclusion filter as the count so the
# named endpoints are a subset of what the count includes. This is the
# invariant the #618 fix restores. The strings appear in validate.sh with
# backslash-escaped quotes because the block is inside a bash -c "..." arg.
count=$(sed -n '/# Parse Gatus API for all-healthy/,/exit 1/p' "$VALIDATE" \
  | grep -cE '!=[[:space:]]+\\"publishing\\"')
if [[ "$count" -ge 3 ]]; then
  # The count filter uses it twice (total + healthy) and the diagnostic once.
  test_pass "publishing exclusion appears in count + healthy + diagnostic ($count occurrences)"
else
  test_fail "publishing exclusion appears fewer than 3 times (got $count) — diagnostic may not share filter with count"
fi

# --- Part B: Behavioral check on the diagnostic jq query ----------------------
#
# We extract the aggregate check block from validate.sh and run it with:
#   - a curl shim that returns a synthesized Gatus payload
#   - a sleep shim that no-ops (aggregate retries 6 times with 30s sleeps)
# The block references ${GATUS_IP} and $(certbot_cluster_gatus_cert_group)
# via outer-shell substitution; we replace both with test literals before
# running.

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Extract lines between `bash -c "` and the closing `"` for the aggregate check.
# Anchor: the `check_capture "All non-certificate Gatus endpoints healthy" \`
# line is followed by `  bash -c "` then the body then `  "`.
BODY_RAW="$WORK/body-raw.sh"
awk '
  /check_capture "All non-certificate Gatus endpoints healthy"/ { armed=1; next }
  armed && /^  bash -c "$/ { grabbing=1; armed=0; next }
  grabbing && /^  "$/ { exit }
  grabbing { print }
' "$VALIDATE" > "$BODY_RAW"

test_start "618.e" "bash -c body is extractable from validate.sh"
if [[ -s "$BODY_RAW" ]]; then
  test_pass "extracted $(wc -l < "$BODY_RAW") lines"
else
  test_fail "could not extract bash -c body"
  runner_summary
  exit 1
fi

# The extracted body has outer-shell escape sequences (`\\`, `\$`, `\"`) and
# outer-shell substitutions (`${GATUS_IP}`, `$(certbot_cluster_gatus_cert_group)`).
# Simulate what the outer shell would do to a bash -c "..." argument:
#   `\\` → `\`  (needed so jq's `\(...)` interpolations survive)
#   `\$` → `$`
#   `\"` → `"`
# Then substitute the two outer-shell placeholders with test literals.
BODY="$WORK/body.sh"
sed -e 's/\\\\/\\/g' -e 's/\\\$/$/g' -e 's/\\"/"/g' \
    -e 's|${GATUS_IP}|10.0.0.62|g' \
    -e 's|$(certbot_cluster_gatus_cert_group)|certificates|g' \
    "$BODY_RAW" > "$BODY"

# Shim curl to return the fixture and sleep to no-op.
SHIM_DIR="$WORK/shims"
mkdir -p "$SHIM_DIR"

# Fixture: one healthy app endpoint, one unhealthy replication endpoint (the
# exact scenario from pipeline 1650), one unhealthy cert endpoint (should be
# filtered), one unhealthy publishing endpoint (should be filtered).
FIXTURE_JSON='[
  {"group":"applications","name":"grafana-prod","key":"applications_grafana-prod","results":[{"success":true,"conditionResults":[{"condition":"[STATUS] == 200","success":true}]}]},
  {"group":"replication","name":"repl-pve01","key":"replication_repl-pve01","results":[{"success":false,"conditionResults":[{"condition":"[STATUS] == 200","success":true},{"condition":"[BODY].replication_stale (true) == false","success":false},{"condition":"[BODY].zfs_pools.vmstore == healthy","success":true}]}]},
  {"group":"certificates","name":"vault-dev-cert","key":"certificates_vault-dev-cert","results":[{"success":false,"conditionResults":[{"condition":"cert valid >7d","success":false}]}]},
  {"group":"publishing","name":"github-mirror-main","key":"publishing_github-mirror-main","results":[{"success":false,"conditionResults":[{"condition":"[BODY].source_commit == expected","success":false}]}]}
]'

cat > "$SHIM_DIR/curl" <<EOF
#!/usr/bin/env bash
# Ignore flags/URL; always return the fixture.
printf '%s\n' '${FIXTURE_JSON}'
EOF
chmod +x "$SHIM_DIR/curl"

cat > "$SHIM_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SHIM_DIR/sleep"

# Run the body.
OUT="$WORK/out"
set +e
PATH="$SHIM_DIR:$PATH" bash "$BODY" >"$OUT" 2>&1
RC=$?
set -e

test_start "618.f" "aggregate exits non-zero when an unhealthy non-cert endpoint exists"
if [[ "$RC" -eq 1 ]]; then
  test_pass "exit=1 (fail) as expected"
else
  test_fail "expected exit 1, got $RC"
  printf '  output:\n' >&2
  sed 's/^/    /' "$OUT" >&2 || true
fi

test_start "618.g" "diagnostic names the unhealthy replication endpoint (group/name + key)"
if grep -Fq "replication/repl-pve01" "$OUT" \
   && grep -Fq "key=replication_repl-pve01" "$OUT"; then
  test_pass "replication endpoint identified"
else
  test_fail "replication endpoint not identified"
  printf '  output:\n' >&2
  sed 's/^/    /' "$OUT" >&2 || true
fi

test_start "618.h" "diagnostic names the failing condition on that endpoint"
if grep -Fq '[BODY].replication_stale (true) == false' "$OUT"; then
  test_pass "failing condition identified verbatim"
else
  test_fail "failing condition not named"
  printf '  output:\n' >&2
  sed 's/^/    /' "$OUT" >&2 || true
fi

test_start "618.i" "diagnostic excludes healthy conditions on the same failing endpoint"
# repl-pve01's [STATUS] == 200 succeeded; it should not be listed as failing.
# We look at the diagnostic section only (after "Unhealthy endpoints:") to
# avoid a false positive on any prefixing summary line.
diagnostic_only=$(sed -n '/^Unhealthy endpoints:/,$p' "$OUT")
if grep -Fq '[STATUS] == 200' <<<"${diagnostic_only}"; then
  test_fail "healthy condition [STATUS] == 200 leaked into diagnostic"
  printf '  diagnostic section:\n' >&2
  sed 's/^/    /' <<<"${diagnostic_only}" >&2 || true
else
  test_pass "healthy conditions filtered out"
fi

test_start "618.j" "diagnostic excludes the certificates group (owned by cert gate)"
if grep -Fq "certificates/vault-dev-cert" "$OUT"; then
  test_fail "certificates endpoint leaked into non-cert diagnostic"
  printf '  output:\n' >&2
  sed 's/^/    /' "$OUT" >&2 || true
else
  test_pass "certificates group excluded"
fi

test_start "618.k" "diagnostic excludes the publishing group (owned by publish telemetry)"
if grep -Fq "publishing/github-mirror-main" "$OUT"; then
  test_fail "publishing endpoint leaked into non-cert diagnostic"
  printf '  output:\n' >&2
  sed 's/^/    /' "$OUT" >&2 || true
else
  test_pass "publishing group excluded"
fi

test_start "618.l" "the count preamble names the healthy/total ratio"
# The failing case should still print the count line so the operator sees
# how many endpoints were sampled vs how many were healthy.
if grep -Eq 'Gatus: [0-9]+/[0-9]+ non-certificate endpoints healthy' "$OUT"; then
  test_pass "count preamble present"
else
  test_fail "count preamble missing"
  printf '  output:\n' >&2
  sed 's/^/    /' "$OUT" >&2 || true
fi

runner_summary
