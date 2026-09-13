#!/usr/bin/env bash
# test_check_rotation_manifest.sh — hermetic coverage for the rotation manifest ratchet.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=tests/lib/runner.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rotation-manifest-test.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_ROOT="${REPO_ROOT}/tests/fixtures/rotation-manifest/base"
CHECKER="${REPO_ROOT}/framework/scripts/check-rotation-manifest.sh"

stage_fixture() {
  local name="$1"
  local dest="${TMP_DIR}/${name}"
  cp -R "${FIXTURE_ROOT}" "${dest}"
  chmod +x "${dest}/framework/scripts/ensure-app-secrets.sh"
  (
    cd "${dest}"
    git init -q
    git -c user.email=test@example.com -c user.name=test -c commit.gpgsign=false add -A
    git -c user.email=test@example.com -c user.name=test -c commit.gpgsign=false commit -q -m "fixture: initial"
  ) >/dev/null
  printf '%s\n' "${dest}"
}

run_checker() {
  local repo="$1" rc=0
  set +e
  OUTPUT="$(
    ROTATION_MANIFEST_REPO_DIR="${repo}" \
      "${CHECKER}" 2>&1
  )"
  rc=$?
  set -e
  STATUS="${rc}"
}

assert_pass() {
  local detail="$1"
  if [[ "${STATUS}" -eq 0 ]]; then
    test_pass "${detail}"
  else
    test_fail "${detail} (rc=${STATUS})"
    printf '%s\n' "${OUTPUT}" >&2
  fi
}

assert_fail_contains() {
  local expected="$1" detail="$2"
  if [[ "${STATUS}" -ne 0 && "${OUTPUT}" == *"${expected}"* ]]; then
    test_pass "${detail}"
  else
    test_fail "${detail} (rc=${STATUS}, expected '${expected}')"
    printf '%s\n' "${OUTPUT}" >&2
  fi
}

append_manifest_row() {
  local repo="$1"
  shift
  {
    printf '\n'
    printf '%s\n' "$@"
  } >> "${repo}/site/rotation-manifest.yaml"
}

remove_manifest_rows_for() {
  local repo="$1" selector="$2"
  SELECTOR="${selector}" yq -i 'del(.[] | select(.match == strenv(SELECTOR)))' "${repo}/site/rotation-manifest.yaml"
}

test_start "V1.1.1" "positive fixture passes, including glob rows, excluded row, app declaration, and external config field"
repo="$(stage_fixture pass)"
run_checker "${repo}"
if [[ "${STATUS}" -eq 0 && "${OUTPUT}" == *"rotation manifest OK"* ]]; then
  test_pass "positive fixture accepted"
else
  test_fail "positive fixture failed"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "V1.1.2" "undeclared SOPS key fails and names the key path"
repo="$(stage_fixture undeclared)"
yq -i '.orphan_secret = "ENC[AES256_GCM,data:SENTINEL_ORPHAN]"' "${repo}/fixture-sops/site-secrets.yaml"
run_checker "${repo}"
assert_fail_contains "fixture-sops/site-secrets.yaml:orphan_secret" "undeclared key path reported"

test_start "V1.1.3" "dead manifest row fails and names the row"
repo="$(stage_fixture dead-row)"
append_manifest_row "${repo}" \
  "- match: dead_secret" \
  "  class: M3" \
  "  driver: framework/scripts/dead.sh" \
  "  probe: framework/scripts/probe-dead.sh"
run_checker "${repo}"
assert_fail_contains "manifest row" "dead row reported"
if [[ "${OUTPUT}" == *"dead_secret"* ]]; then
  test_pass "dead row selector named"
else
  test_fail "dead row selector missing"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "V1.1.4" "duplicate classified match fails and names both rows"
repo="$(stage_fixture duplicate)"
append_manifest_row "${repo}" \
  "- match: alpha_*" \
  "  class: M2" \
  "  driver: framework/scripts/other.sh" \
  "  probe: framework/scripts/probe-other.sh"
run_checker "${repo}"
assert_fail_contains "matches multiple classified rows" "duplicate classified match rejected"
if [[ "${OUTPUT}" == *"alpha_secret"* && "${OUTPUT}" == *"row 1"* && "${OUTPUT}" == *"alpha_*"* ]]; then
  test_pass "duplicate output names key and both row selectors"
else
  test_fail "duplicate output missing key or row detail"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "V1.1.5" "excluded row suppresses classification only when no class row also matches"
repo="$(stage_fixture excluded-double)"
append_manifest_row "${repo}" \
  "- match: legacy_empty" \
  "  class: M3" \
  "  driver: framework/scripts/legacy.sh" \
  "  probe: framework/scripts/probe-legacy.sh"
run_checker "${repo}"
assert_fail_contains "both excluded and classified" "exclude-and-classified double detection rejected"

test_start "V1.1.6" "missing SOPS file fails closed"
repo="$(stage_fixture missing-sops)"
rm -f "${repo}/fixture-sops/hil-bfnet-secrets.yaml"
run_checker "${repo}"
assert_fail_contains "creation rule matched no files" "missing SOPS rule target fails instead of skipping"

test_start "V1.1.7" "app-declared secret derivation is part of the required live set"
repo="$(stage_fixture app-derived)"
remove_manifest_rows_for "${repo}" "app_declared_token"
run_checker "${repo}"
assert_fail_contains "site/applications.yaml:applications.fixtureapp.enabled:app_declared_token" "app-declared secret without row fails"

test_start "V1.1.8" "glob rows cover nested key paths"
repo="$(stage_fixture glob)"
remove_manifest_rows_for "${repo}" "ssh_host_keys.*"
run_checker "${repo}"
assert_fail_contains "fixture-sops/site-secrets.yaml:ssh_host_keys.app_dev" "nested ssh_host_keys path is derived and named"

test_start "V1.1.9" "external config.yaml field is accepted without SOPS membership"
repo="$(stage_fixture external)"
yq -i 'del(.[] | select(.external == "operator_ssh_pubkey"))' "${repo}/site/rotation-manifest.yaml"
run_checker "${repo}"
if [[ "${STATUS}" -eq 0 ]]; then
  test_pass "external rows are optional declarations, not derived SOPS requirements"
else
  test_fail "removing external-only row should not affect SOPS conformance"
  printf '%s\n' "${OUTPUT}" >&2
fi
repo="$(stage_fixture external-present)"
run_checker "${repo}"
assert_pass "external config field row present and accepted"

test_start "V1.1.10" "nested-worktree decoy is not enumerated"
repo="$(stage_fixture nested-decoy)"
mkdir -p "${repo}/.claude/worktrees/issue-fake/fixture-sops"
cat > "${repo}/.claude/worktrees/issue-fake/fixture-sops/site-secrets.yaml" <<'YAML'
decoy_orphan_secret: ENC[AES256_GCM,data:DECOY]
sops:
  age: []
YAML
run_checker "${repo}"
if [[ "${STATUS}" -eq 0 && "${OUTPUT}" == *"rotation manifest OK"* ]]; then
  test_pass "nested decoy ignored"
else
  test_fail "nested decoy should not affect rotation manifest"
  printf '%s\n' "${OUTPUT}" >&2
fi
if [[ "${OUTPUT}" != *".claude/worktrees/issue-fake/fixture-sops/site-secrets.yaml"* && "${OUTPUT}" != *"decoy_orphan_secret"* ]]; then
  test_pass "nested decoy path and key absent from output"
else
  test_fail "nested decoy leaked into checker output"
  printf '%s\n' "${OUTPUT}" >&2
fi

test_start "V1.1.11" "bounded grep spawn count"
repo="$(stage_fixture bounded-grep)"
real_grep="$(command -v grep)"
grep_call_log="${TMP_DIR}/grep-calls.log"
: > "${grep_call_log}"
mkdir -p "${TMP_DIR}/binshim" "${repo}/decoy-tree"
i=1
while (( i <= 1000 )); do
  printf 'decoy %s\n' "${i}" > "${repo}/decoy-tree/f-${i}.txt"
  i=$((i + 1))
done
(
  cd "${repo}"
  git add decoy-tree
  git -c user.email=test@example.com -c user.name=test -c commit.gpgsign=false commit -q -m "fixture: decoy tree"
) >/dev/null
cat > "${TMP_DIR}/binshim/grep" <<'SHIM'
#!/usr/bin/env bash
printf '.' >> "${GREP_CALL_LOG}"
exec "${REAL_GREP}" "$@"
SHIM
chmod +x "${TMP_DIR}/binshim/grep"
set +e
OUTPUT="$(
  ROTATION_MANIFEST_REPO_DIR="${repo}" \
  GREP_CALL_LOG="${grep_call_log}" \
  REAL_GREP="${real_grep}" \
  PATH="${TMP_DIR}/binshim:${PATH}" \
    "${CHECKER}" 2>&1
)"
STATUS=$?
set -e
if [[ "${STATUS}" -eq 0 ]]; then
  test_pass "large tracked fixture accepted"
else
  test_fail "large tracked fixture failed"
  printf '%s\n' "${OUTPUT}" >&2
fi
grep_count="$(wc -c < "${grep_call_log}" | tr -d ' ')"
if [[ "${grep_count}" =~ ^[0-9]+$ && "${grep_count}" -lt 50 ]]; then
  test_pass "grep invocations bounded (${grep_count})"
else
  test_fail "grep invocations exceeded bound (${grep_count})"
  printf '%s\n' "${OUTPUT}" >&2
fi

runner_summary
