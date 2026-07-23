#!/usr/bin/env bash
# test_publish_to_github_oid_parser.sh — Regression for issue #297.
#
# publish-to-github.sh captures `git ls-remote 2>&1`, so the parser that
# extracts the remote main OID must ignore SSH warnings, agent notices,
# and any other stderr line that happens to appear before the oid line.
# The historical parser used `awk 'NF { print $1; exit }'`, which picked
# "Warning:" from "Warning: Permanently added 'github.com' (...)" on the
# first SSH connection from a runner whose known_hosts lacked github.com.
# That value was then handed to `git push --force-with-lease=main:Warning:`
# which fails with `cannot parse expected object name 'Warning:'`.
#
# The fix is github_publish_extract_remote_oid in
# framework/scripts/github-publish-lib.sh, which only accepts a 40-char
# lowercase-hex first field. This test exercises that helper plus the
# script-level guarantee that GIT_SSH_COMMAND has LogLevel=ERROR (which
# suppresses the "Permanently added" warning at the source).

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"
source "${REPO_ROOT}/framework/scripts/github-publish-lib.sh"

VALID_OID="abcdef0123456789abcdef0123456789abcdef01"
SECOND_OID="0123456789abcdef0123456789abcdef01234567"

# --- Case 1: bare oid line ------------------------------------------------
test_start "1" "bare ls-remote output yields the oid"
out="$(github_publish_extract_remote_oid "${VALID_OID}	refs/heads/main")"
if [[ "${out}" == "${VALID_OID}" ]]; then
  test_pass "extracted ${VALID_OID}"
else
  test_fail "expected ${VALID_OID}, got '${out}'"
fi

# --- Case 2: SSH 'Warning: Permanently added' before the oid -------------
test_start "2" "SSH accept-new warning ahead of oid is skipped (the #297 case)"
input="Warning: Permanently added 'github.com' (ED25519) to the list of known hosts.
${VALID_OID}	refs/heads/main"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ "${out}" == "${VALID_OID}" ]]; then
  test_pass "skipped Warning:, returned ${VALID_OID}"
else
  test_fail "expected ${VALID_OID}, got '${out}' — the #297 bug"
fi

# --- Case 3: agent forwarding notice ahead of oid ------------------------
test_start "3" "agent forwarding notice ahead of oid is skipped"
input="Agent admitted failure to sign using the key.
${VALID_OID}	refs/heads/main"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ "${out}" == "${VALID_OID}" ]]; then
  test_pass "skipped agent notice, returned ${VALID_OID}"
else
  test_fail "expected ${VALID_OID}, got '${out}'"
fi

# --- Case 4: blank lines and indentation do not derail the parser --------
test_start "4" "blank lines and leading whitespace before oid"
input="

   ${VALID_OID}	refs/heads/main"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ "${out}" == "${VALID_OID}" ]]; then
  test_pass "tolerated whitespace, returned ${VALID_OID}"
else
  test_fail "expected ${VALID_OID}, got '${out}'"
fi

# --- Case 5: no valid oid present yields empty (not a partial match) -----
test_start "5" "no valid oid present yields empty"
input="Warning: something happened
ERROR: something else happened"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ -z "${out}" ]]; then
  test_pass "empty output for stderr-only input"
else
  test_fail "expected empty, got '${out}'"
fi

# --- Case 6: empty input yields empty ------------------------------------
test_start "6" "empty input yields empty"
out="$(github_publish_extract_remote_oid "")"
if [[ -z "${out}" ]]; then
  test_pass "empty input → empty output"
else
  test_fail "expected empty, got '${out}'"
fi

# --- Case 7: short hex (39 chars) is rejected ----------------------------
test_start "7" "39-char hex first field is rejected"
short="abcdef0123456789abcdef0123456789abcdef0"
input="${short}	refs/heads/main"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ -z "${out}" ]]; then
  test_pass "39-char field rejected"
else
  test_fail "expected empty, got '${out}'"
fi

# --- Case 8: uppercase hex is rejected (git ls-remote always emits lower) -
test_start "8" "uppercase hex first field is rejected"
upper="ABCDEF0123456789ABCDEF0123456789ABCDEF01"
input="${upper}	refs/heads/main"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ -z "${out}" ]]; then
  test_pass "uppercase field rejected"
else
  test_fail "expected empty (lower-only), got '${out}'"
fi

# --- Case 9: returns FIRST valid oid when multiple are present ----------
test_start "9" "first valid oid wins on multi-line input"
input="${VALID_OID}	refs/heads/main
${SECOND_OID}	refs/heads/other"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ "${out}" == "${VALID_OID}" ]]; then
  test_pass "returned first valid oid"
else
  test_fail "expected ${VALID_OID}, got '${out}'"
fi

# --- Case 9b: only refs/heads/main is accepted; refs/heads/other is skipped
test_start "9b" "non-main ref alone is rejected even if oid is valid"
input="${SECOND_OID}	refs/heads/other"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ -z "${out}" ]]; then
  test_pass "non-main ref → empty output"
else
  test_fail "expected empty (\$2 must be refs/heads/main), got '${out}'"
fi

# --- Case 9c: 40-hex \$1 with garbage \$2 is rejected (defense-in-depth) -
test_start "9c" "valid 40-hex with non-ref second field is rejected"
input="${VALID_OID} garbage"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ -z "${out}" ]]; then
  test_pass "40-hex with garbage \$2 → empty output"
else
  test_fail "expected empty (defense-in-depth on \$2), got '${out}'"
fi

# --- Case 9d: CRLF line endings on the oid line --------------------------
# git ls-remote on Linux emits LF, but if a future proxy or environment
# munges to CRLF, the parser must still extract the oid. The CR ends up
# on $2; the regex's optional \r? handles this.
test_start "9d" "CRLF on oid line is tolerated"
input="$(printf 'Warning: Permanently added github.com\r\n%s\trefs/heads/main\r\n' "${VALID_OID}")"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ "${out}" == "${VALID_OID}" ]]; then
  test_pass "CRLF tolerated, returned ${VALID_OID}"
else
  test_fail "expected ${VALID_OID}, got '${out}'"
fi

# --- Case 9e: 41-char hex first field is rejected (anchored regex) ------
test_start "9e" "41-char hex first field is rejected"
long="abcdef0123456789abcdef0123456789abcdef012"
input="${long}	refs/heads/main"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ -z "${out}" ]]; then
  test_pass "41-char field rejected (anchor works)"
else
  test_fail "expected empty, got '${out}'"
fi

# --- Case 9f: one uppercase letter in otherwise lowercase 40-hex --------
test_start "9f" "single uppercase letter in 40-hex first field is rejected"
mixed="Abcdef0123456789abcdef0123456789abcdef01"
input="${mixed}	refs/heads/main"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ -z "${out}" ]]; then
  test_pass "mixed-case rejected (lower-only)"
else
  test_fail "expected empty, got '${out}'"
fi

# --- Case 9g: 40-hex token mid-line is not extracted --------------------
test_start "9g" "40-hex token mid-line (not \$1) is rejected"
input="Log: ${VALID_OID} something happened"
out="$(github_publish_extract_remote_oid "${input}")"
if [[ -z "${out}" ]]; then
  test_pass "mid-line oid rejected"
else
  test_fail "expected empty (oid must be \$1), got '${out}'"
fi

# --- Case 10: GIT_SSH_COMMAND has LogLevel=ERROR -------------------------
test_start "10" "publish-to-github.sh sets ssh LogLevel=ERROR"
script="${REPO_ROOT}/framework/scripts/publish-to-github.sh"
if grep -q 'GIT_SSH_COMMAND=.*-o LogLevel=ERROR' "${script}"; then
  test_pass "GIT_SSH_COMMAND includes -o LogLevel=ERROR"
else
  test_fail "GIT_SSH_COMMAND missing -o LogLevel=ERROR — SSH warnings will leak into stderr capture"
fi

# --- Case 11: no inline awk parser remains in publish-to-github.sh ------
test_start "11" "publish-to-github.sh has no inline NF-and-print awk parser"
if grep -qE "awk 'NF \{ print \\\$1; exit \}'" "${script}"; then
  test_fail "inline awk parser still present — call sites must use github_publish_extract_remote_oid"
else
  test_pass "no inline awk parser"
fi

# --- Case 12: verify-github-publish.sh — every GIT_SSH_COMMAND site sets
# -o LogLevel=ERROR (#299). Enumerate the actual GIT_SSH_COMMAND= lines and
# require each one to carry -o LogLevel=ERROR. This tightens the previous
# bare-line-count assertion so a future refactor cannot pass by consolidation.
test_start "12" "verify-github-publish.sh: every GIT_SSH_COMMAND= line includes -o LogLevel=ERROR"
verify_script="${REPO_ROOT}/framework/scripts/verify-github-publish.sh"
verify_cmd_lines=$(grep -n 'GIT_SSH_COMMAND=' "${verify_script}" || true)
verify_cmd_count=$(printf '%s\n' "${verify_cmd_lines}" | grep -c '.' || true)
# We know there are exactly 2 GIT_SSH_COMMAND= sites today; if that number
# grows or shrinks the test loudly reports so a reviewer can decide.
if [[ "${verify_cmd_count}" -ne 2 ]]; then
  test_fail "verify-github-publish.sh expected 2 GIT_SSH_COMMAND= sites, found ${verify_cmd_count}"
elif printf '%s\n' "${verify_cmd_lines}" | grep -vq -- '-o LogLevel=ERROR'; then
  # Every GIT_SSH_COMMAND= line has -o LogLevel=ERROR? Then grep -v -- must
  # find zero — i.e. return non-zero exit. If it finds anything, we fail.
  test_fail "verify-github-publish.sh: at least one GIT_SSH_COMMAND= site is missing -o LogLevel=ERROR"
else
  test_pass "both GIT_SSH_COMMAND= sites include -o LogLevel=ERROR"
fi

# --- Case 13: seed-github-deploy-key.sh sets LogLevel=ERROR (#299) -----
test_start "13" "seed-github-deploy-key.sh: GIT_SSH_COMMAND includes -o LogLevel=ERROR"
seed_script="${REPO_ROOT}/framework/scripts/seed-github-deploy-key.sh"
if grep -q 'GIT_SSH_COMMAND=.*-o LogLevel=ERROR' "${seed_script}"; then
  test_pass "GIT_SSH_COMMAND includes -o LogLevel=ERROR"
else
  test_fail "GIT_SSH_COMMAND missing -o LogLevel=ERROR — SSH warnings leak into ls-remote stderr capture"
fi

# --- Case 14: sync-to-main.sh sets LogLevel=ERROR (#299) ---------------
# Require the `-o` flag (matching test 13) so a future edit that drops `-o`
# — invalid ssh syntax — cannot pass this test.
test_start "14" "sync-to-main.sh: GIT_SSH_COMMAND includes -o LogLevel=ERROR"
sync_script="${REPO_ROOT}/framework/scripts/sync-to-main.sh"
if grep -q 'GIT_SSH_COMMAND=.*-o LogLevel=ERROR' "${sync_script}"; then
  test_pass "GIT_SSH_COMMAND includes -o LogLevel=ERROR"
else
  test_fail "GIT_SSH_COMMAND missing -o LogLevel=ERROR"
fi

# --- Case 15: sync-to-main.sh uses shared helper, not inline awk (#298) -
test_start "15" "sync-to-main.sh has no inline NF-and-print awk parser"
if grep -qE "awk 'NF \{ print \\\$1; exit \}'" "${sync_script}"; then
  test_fail "inline awk parser still present in sync-to-main.sh — must use github_publish_extract_remote_oid"
else
  test_pass "no inline awk parser in sync-to-main.sh"
fi

# --- Case 15b: the REMOTE_MAIN_OID assignment itself invokes the helper (#298)
# A previous version grepped for the helper anywhere in the file, which would
# false-pass on a rationale comment. Anchor on the actual assignment line so
# a future refactor that puts the helper in a comment but drops the call cannot
# pass.
test_start "15b" "sync-to-main.sh REMOTE_MAIN_OID= line invokes github_publish_extract_remote_oid"
if grep -qE '^REMOTE_MAIN_OID=.*github_publish_extract_remote_oid' "${sync_script}"; then
  test_pass "REMOTE_MAIN_OID assignment uses the helper"
else
  test_fail "sync-to-main.sh does not assign REMOTE_MAIN_OID via github_publish_extract_remote_oid"
fi

# --- Case 16: every github_publish_initial_rewrite_guard call is inside an
# explicit `if ! ...; then` guard (#292). sync-to-main.sh has TWO call sites
# (the empty-OID branch and the metadata-absent branch); the previous version
# only asserted at least one bare-call, which would false-pass if one site was
# fixed while the other regressed. Assert no *bare* call remains.
test_start "16" "sync-to-main.sh: no bare github_publish_initial_rewrite_guard call site remains"
# A bare call is a line whose ONLY non-whitespace token is
# `github_publish_initial_rewrite_guard` (no leading `if !`). Extract every
# guard line and confirm each has `if !` before the helper name.
bare_calls=$(grep -n 'github_publish_initial_rewrite_guard' "${sync_script}" \
  | grep -vE 'if ! github_publish_initial_rewrite_guard' || true)
if [[ -z "${bare_calls}" ]]; then
  test_pass "every guard call site is wrapped in if !"
else
  test_fail "sync-to-main.sh has a bare guard call site: ${bare_calls}"
fi

# --- Case 17: sync-to-main.sh quotes the OID on the force-with-lease push (#292)
# `--force-with-lease=main:${OID}` is unquoted; a future word-splitting value
# would be silently spliced. The quoted form protects against that. Accept
# either equivalent quoting form (whole value or expansion-only).
test_start "17" "sync-to-main.sh quotes REMOTE_MAIN_OID on the force-with-lease push"
if grep -qE 'force-with-lease="main:\$\{REMOTE_MAIN_OID\}"|force-with-lease=main:"\$\{REMOTE_MAIN_OID\}"' "${sync_script}"; then
  test_pass "REMOTE_MAIN_OID is quoted"
else
  test_fail "sync-to-main.sh does not quote REMOTE_MAIN_OID on --force-with-lease"
fi

runner_summary
