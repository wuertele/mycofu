#!/usr/bin/env bash
# Fixture test for framework/scripts/get-deployed-image-hashes.sh.
#
# Shims curl and runs the script with controlled CI_PROJECT_ID +
# MYCOFU_GITLAB_URL. Verifies:
#   - missing auth → exits 0 with empty output and stderr warning
#   - missing project id → exits 0 with empty output and stderr warning
#   - HTTP 200 with a fragment line → emits the filename
#   - HTTP 404 → emits stderr INFO but exits 0
#   - both dev and prod return: union, sorted, deduped
#   - URL encoding of the parallel:matrix job name (`build:image: [acme-dev]`)
#     produces the expected percent-encoded query parameter

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SCRIPT="${REPO_ROOT}/framework/scripts/get-deployed-image-hashes.sh"

# Build a curl shim that:
#   - matches request URL against ${CASE_DIR}/responses/<ref>.tfvars-fragment
#     and ${CASE_DIR}/responses/<ref>.status
#   - writes the response body to the -o destination
#   - prints the status code (for -w '%{http_code}')
#   - logs each invocation to ${CASE_DIR}/curl-log
make_curl_shim() {
  local case_dir="$1"
  cat > "${case_dir}/curl" <<EOF
#!/usr/bin/env bash
ARGS=("\$@")
echo "curl \${ARGS[*]}" >> "${case_dir}/curl-log"

OUT=""
URL=""
i=0
while [[ \$i -lt \${#ARGS[@]} ]]; do
  case "\${ARGS[\$i]}" in
    -o) OUT="\${ARGS[\$((i+1))]}"; i=\$((i+2));;
    -w) i=\$((i+2));;
    -H) i=\$((i+2));;
    -*) i=\$((i+1));;
    *) URL="\${ARGS[\$i]}"; i=\$((i+1));;
  esac
done

REF=\$(printf '%s' "\$URL" | sed -E 's|.*/jobs/artifacts/([^/]+)/raw/.*|\\1|')
BODY="${case_dir}/responses/\${REF}.tfvars-fragment"
STATUS_FILE="${case_dir}/responses/\${REF}.status"

if [[ -f "\$BODY" ]]; then
  cat "\$BODY" > "\$OUT"
else
  : > "\$OUT"
fi
if [[ -f "\$STATUS_FILE" ]]; then
  cat "\$STATUS_FILE"
else
  echo "404"
fi
EOF
  chmod +x "${case_dir}/curl"
}

setup_case() {
  local name="$1"
  CASE_DIR="${TMP_DIR}/${name}"
  rm -rf "${CASE_DIR}"
  mkdir -p "${CASE_DIR}/responses"
  : > "${CASE_DIR}/curl-log"
  make_curl_shim "${CASE_DIR}"
}

run_helper() {
  local case_dir="$1"; shift
  # Wrap to control env explicitly: defaults match a CI-like context, tests
  # override as needed.
  env -i PATH="${PATH}" \
    CI_JOB_TOKEN="fake-job-token" \
    CI_PROJECT_ID="42" \
    MYCOFU_GITLAB_URL="https://gitlab.example.test" \
    MYCOFU_GITLAB_CURL="${case_dir}/curl" \
    "$@" \
    bash "${SCRIPT}" --role acme-dev --ref dev --ref prod
}

# --- no-auth ---
setup_case "no-auth"
test_start "GDH.1" "no auth — exit 0, empty output, stderr warning"
OUT=$(env -i PATH="${PATH}" \
  MYCOFU_GITLAB_URL=x MYCOFU_GITLAB_CURL=true \
  bash "${SCRIPT}" --role acme-dev --ref dev 2> "${CASE_DIR}/stderr.txt")
[[ -z "$OUT" ]] && test_pass "stdout empty" || test_fail "stdout not empty: $OUT"
grep -q "No GitLab auth" "${CASE_DIR}/stderr.txt" \
  && test_pass "stderr names the missing-auth reason" \
  || test_fail "stderr missing the warning"

# --- no project id ---
setup_case "no-project-id"
test_start "GDH.2" "no project id — exit 0, empty output, stderr warning"
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake MYCOFU_GITLAB_URL=x MYCOFU_GITLAB_CURL=true \
  bash "${SCRIPT}" --role acme-dev --ref dev 2> "${CASE_DIR}/stderr.txt")
[[ -z "$OUT" ]] && test_pass "stdout empty" || test_fail "stdout not empty: $OUT"
grep -q "CI_PROJECT_ID" "${CASE_DIR}/stderr.txt" \
  && test_pass "stderr names the missing-project-id reason" \
  || test_fail "stderr missing the warning"

# --- single ref, HTTP 200, fragment present ---
setup_case "single-ref-200"
echo "200" > "${CASE_DIR}/responses/dev.status"
cat > "${CASE_DIR}/responses/dev.tfvars-fragment" <<EOF
  "acme-dev" = "acme-dev-3g4w5csn.img"
EOF
test_start "GDH.3" "dev returns one fragment — emit the filename"
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  bash "${SCRIPT}" --role acme-dev --ref dev)
[[ "$OUT" == "acme-dev-3g4w5csn.img" ]] \
  && test_pass "filename parsed correctly" \
  || test_fail "expected acme-dev-3g4w5csn.img, got '$OUT'"

# --- multi ref: union + dedup + sort ---
setup_case "multi-ref-union"
for ref in dev prod; do
  echo "200" > "${CASE_DIR}/responses/${ref}.status"
done
cat > "${CASE_DIR}/responses/dev.tfvars-fragment"  <<EOF
"acme-dev" = "acme-dev-alpha000.img"
EOF
cat > "${CASE_DIR}/responses/prod.tfvars-fragment" <<EOF
"acme-dev" = "acme-dev-beta00000.img"
EOF
test_start "GDH.4" "dev + prod return distinct — emit union, sorted"
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  bash "${SCRIPT}" --role acme-dev --ref dev --ref prod)
EXPECTED=$'acme-dev-alpha000.img\nacme-dev-beta00000.img'
if [[ "$OUT" == "$EXPECTED" ]]; then
  test_pass "output is the sorted union"
else
  test_fail "unexpected output: $(printf '%q' "$OUT")"
fi

# --- 404 on one ref, 200 on other ---
setup_case "404-one-ref"
echo "200" > "${CASE_DIR}/responses/dev.status"
cat > "${CASE_DIR}/responses/dev.tfvars-fragment" <<EOF
"acme-dev" = "acme-dev-only00000.img"
EOF
# prod intentionally absent → curl shim returns 404
test_start "GDH.5" "404 on prod is tolerated — dev still contributes"
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  bash "${SCRIPT}" --role acme-dev --ref dev --ref prod 2> "${CASE_DIR}/stderr.txt")
[[ "$OUT" == "acme-dev-only00000.img" ]] \
  && test_pass "dev contribution kept despite prod 404" \
  || test_fail "expected acme-dev-only00000.img, got '$OUT'"
grep -q "No artifact for acme-dev on ref prod" "${CASE_DIR}/stderr.txt" \
  && test_pass "stderr names the 404 ref" \
  || test_fail "stderr missing the 404 message"

# --- URL encoding of job name ---
setup_case "url-encoding"
echo "200" > "${CASE_DIR}/responses/dev.status"
cat > "${CASE_DIR}/responses/dev.tfvars-fragment" <<EOF
"acme-dev" = "acme-dev-x00000000.img"
EOF
test_start "GDH.6" "parallel:matrix job name URL-encodes spaces and brackets"
env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  bash "${SCRIPT}" --role acme-dev --ref dev >/dev/null
# job=build%3Aimage%3A%20%5Bacme-dev%5D
if grep -q 'job=build%3Aimage%3A%20%5Bacme-dev%5D' "${CASE_DIR}/curl-log"; then
  test_pass "job query param is properly percent-encoded"
else
  test_fail "encoded job param not seen — log: $(cat ${CASE_DIR}/curl-log | head -2)"
fi

# --- Fallback to standalone job name when matrix form returns 404 ---
setup_case "fallback-standalone-job"
# Patch the curl shim to return 404 on the matrix form and 200 on the
# standalone form. We discriminate by the encoded job param.
cat > "${CASE_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
ARGS=("$@")
echo "curl ${ARGS[*]}" >> "$(dirname "$0")/curl-log"
OUT=""
URL=""
i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  case "${ARGS[$i]}" in
    -o) OUT="${ARGS[$((i+1))]}"; i=$((i+2));;
    -w) i=$((i+2));;
    -H) i=$((i+2));;
    -*) i=$((i+1));;
    *) URL="${ARGS[$i]}"; i=$((i+1));;
  esac
done
# Matrix-form URL has %5B (the [); standalone form does not.
if [[ "$URL" == *"%5B"* ]]; then
  : > "$OUT"
  echo "404"
else
  cat > "$OUT" <<INNER
"hil-boot" = "hil-boot-zzzzzz00.img"
INNER
  echo "200"
fi
EOF
chmod +x "${CASE_DIR}/curl"
test_start "GDH.7" "standalone-job fallback: 404 on matrix form → try literal name"
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  bash "${SCRIPT}" --role hil-boot --ref dev)
[[ "$OUT" == "hil-boot-zzzzzz00.img" ]] \
  && test_pass "fallback succeeded with standalone form" \
  || test_fail "expected hil-boot-zzzzzz00.img, got '$OUT'"
# Verify both forms were attempted in the log
grep -q '%5B' "${CASE_DIR}/curl-log" \
  && test_pass "matrix form was attempted" \
  || test_fail "matrix form not seen in log"
grep -q 'job=build%3Aimage%3Ahil-boot' "${CASE_DIR}/curl-log" \
  && test_pass "standalone form was attempted as fallback" \
  || test_fail "standalone form not seen in log"

# --- Explicit --job override skips the fallback ladder ---
setup_case "explicit-job-override"
cat > "${CASE_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
ARGS=("$@")
echo "curl ${ARGS[*]}" >> "$(dirname "$0")/curl-log"
OUT=""; URL=""; i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  case "${ARGS[$i]}" in
    -o) OUT="${ARGS[$((i+1))]}"; i=$((i+2));;
    -w|-H) i=$((i+2));;
    -*) i=$((i+1));;
    *) URL="${ARGS[$i]}"; i=$((i+1));;
  esac
done
if [[ "$URL" == *"job=build%3Aimage%3Ahil-boot" ]]; then
  cat > "$OUT" <<INNER
"hil-boot" = "hil-boot-explicit.img"
INNER
  echo "200"
else
  : > "$OUT"; echo "404"
fi
EOF
chmod +x "${CASE_DIR}/curl"
test_start "GDH.8" "--job override skips the matrix form entirely"
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  bash "${SCRIPT}" --role hil-boot --ref dev --job "build:image:hil-boot")
[[ "$OUT" == "hil-boot-explicit.img" ]] \
  && test_pass "override fetched correctly" \
  || test_fail "expected hil-boot-explicit.img, got '$OUT'"
# Should NOT have attempted matrix form
if grep -q '%5B' "${CASE_DIR}/curl-log"; then
  test_fail "matrix form attempted despite explicit --job override"
else
  test_pass "matrix form was correctly skipped"
fi

# --- Extractor anchored to ROLE: cross-role strings ignored ---
setup_case "extractor-anchored-to-role"
echo "200" > "${CASE_DIR}/responses/dev.status"
cat > "${CASE_DIR}/responses/dev.tfvars-fragment" <<EOF
"acme-dev" = "acme-dev-good00000.img"
# Stray reference to another role's image — must NOT be emitted
"dns"      = "dns-stray00000.img"
EOF
test_start "GDH.9" "extractor emits only ROLE-prefixed filenames"
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  bash "${SCRIPT}" --role acme-dev --ref dev)
if [[ "$OUT" == "acme-dev-good00000.img" ]]; then
  test_pass "only role-prefixed filename emitted; stray dns- ignored"
else
  test_fail "expected acme-dev-good00000.img only, got '$OUT'"
fi

# --- MYCOFU_UPLOAD_HELPER_JOB_NAME env-var is honored ---
setup_case "env-job-override"
cat > "${CASE_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
ARGS=("$@")
echo "curl ${ARGS[*]}" >> "$(dirname "$0")/curl-log"
OUT=""; URL=""; i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  case "${ARGS[$i]}" in
    -o) OUT="${ARGS[$((i+1))]}"; i=$((i+2));;
    -w|-H) i=$((i+2));;
    -*) i=$((i+1));;
    *) URL="${ARGS[$i]}"; i=$((i+1));;
  esac
done
if [[ "$URL" == *"job=build%3Aimage%3Ahil-boot" ]]; then
  cat > "$OUT" <<INNER
"hil-boot" = "hil-boot-fromenv0.img"
INNER
  echo "200"
else
  : > "$OUT"; echo "404"
fi
EOF
chmod +x "${CASE_DIR}/curl"
test_start "GDH.10" "MYCOFU_UPLOAD_HELPER_JOB_NAME env var sets default job"
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  MYCOFU_UPLOAD_HELPER_JOB_NAME="build:image:hil-boot" \
  bash "${SCRIPT}" --role hil-boot --ref dev)
[[ "$OUT" == "hil-boot-fromenv0.img" ]] \
  && test_pass "env-var override took effect" \
  || test_fail "expected hil-boot-fromenv0.img, got '$OUT'"

# --- Strict mode: missing auth fails closed ---
setup_case "strict-no-auth"
test_start "GDH.11" "--strict missing auth exits non-zero"
set +e
OUT=$(env -i PATH="${PATH}" \
  MYCOFU_GITLAB_URL=x MYCOFU_GITLAB_CURL=true \
  bash "${SCRIPT}" --strict --role acme-dev --ref dev 2> "${CASE_DIR}/stderr.txt")
RC=$?
set -e
if [[ "$RC" -ne 0 && -z "$OUT" ]] &&
   grep -q "ERROR: No GitLab auth" "${CASE_DIR}/stderr.txt"; then
  test_pass "strict missing auth fails closed"
else
  test_fail "strict missing auth did not fail closed"
  printf 'rc=%s out=%s stderr=%s\n' "$RC" "$OUT" "$(cat "${CASE_DIR}/stderr.txt")" >&2
fi

# --- Strict mode: fetch failure fails closed ---
setup_case "strict-fetch-failure"
test_start "GDH.12" "--strict artifact fetch failure exits non-zero"
set +e
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  bash "${SCRIPT}" --strict --role acme-dev --ref dev 2> "${CASE_DIR}/stderr.txt")
RC=$?
set -e
if [[ "$RC" -ne 0 && -z "$OUT" ]] &&
   grep -q "ERROR: failed to fetch deployed image artifact" "${CASE_DIR}/stderr.txt"; then
  test_pass "strict fetch failure fails closed"
else
  test_fail "strict fetch failure did not fail closed"
  printf 'rc=%s out=%s stderr=%s\n' "$RC" "$OUT" "$(cat "${CASE_DIR}/stderr.txt")" >&2
fi

# --- Strict mode: HTTP 200 without role filename fails closed ---
setup_case "strict-empty-result"
echo "200" > "${CASE_DIR}/responses/dev.status"
cat > "${CASE_DIR}/responses/dev.tfvars-fragment" <<EOF
"other" = "other-only00000.img"
EOF
test_start "GDH.13" "--strict empty role result exits non-zero"
set +e
OUT=$(env -i PATH="${PATH}" \
  CI_JOB_TOKEN=fake CI_PROJECT_ID=42 \
  MYCOFU_GITLAB_URL="https://gitlab.example.test" \
  MYCOFU_GITLAB_CURL="${CASE_DIR}/curl" \
  bash "${SCRIPT}" --strict --role acme-dev --ref dev 2> "${CASE_DIR}/stderr.txt")
RC=$?
set -e
if [[ "$RC" -ne 0 && -z "$OUT" ]] &&
   grep -q "strict deployed image query returned no filenames" "${CASE_DIR}/stderr.txt"; then
  test_pass "strict empty result fails closed"
else
  test_fail "strict empty result did not fail closed"
  printf 'rc=%s out=%s stderr=%s\n' "$RC" "$OUT" "$(cat "${CASE_DIR}/stderr.txt")" >&2
fi

runner_summary
