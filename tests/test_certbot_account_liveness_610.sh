#!/usr/bin/env bash
#
# Regression coverage for #610 (follow-up to #525/#568):
#
# vault-dev's TLS renewal got stuck because its vdb-persisted ACME account was
# dead after a dev step-ca account-DB reset, and certbot-repair-persisted-state
# failed to self-heal it. Two source-level defects, both fixed in
# framework/nix/modules/certbot.nix:
#
#   1. The dead-account classifier in the repair's account-liveness probe
#      matched ONLY the ACME URN token `accountDoesNotExist`. On the live
#      incident `certbot show_account` emitted the plain-text CLI form
#      `Account does not exist`, so the probe returned "no verdict" and the
#      repair failed closed instead of re-registering. The classifier must now
#      treat BOTH forms as dead, case/whitespace-robust.
#
#   2. certbot-repair-persisted-state.service was a boot oneshot with
#      RemainAfterExit=true. After a successful boot repair it sits
#      `active (exited)`, so certbot-renew.service (which only `wants`/`after`s
#      it) does NOT re-run it before a later renewal — if step-ca loses the
#      account between renewals, the account-liveness repair is skipped. The
#      unit must be rerunnable (no RemainAfterExit) so it is re-triggered and
#      ordered ahead of every renewal.
#
# This file asserts against the actual certbot.nix source for the two #610
# defects (dead-account classifier, repair-service rerunnability) and against
# BOTH certbot.nix and certbot-persisted-state.sh for the #611 parity guard.
# The behavioral end-to-end coverage of the classifier (repair re-registers on
# plain-text rejection) lives in test_certbot_persisted_state.sh, tests 2.11
# through 2.11d (#610-provenance).
#
# #611 parity guard: the same dead-account classifier ERE is textually
# duplicated in framework/scripts/certbot-persisted-state.sh (the helper's
# account-liveness probe), and only the certbot.nix copy was behavior-tested
# here before. Silent drift (e.g. broadening one to accept a new ACME error
# phrasing) would let the other regress unnoticed. A611.1a/b below extract
# the ERE from BOTH files and assert byte-equality at CI time.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
CERTBOT_NIX="${REPO_ROOT}/framework/nix/modules/certbot.nix"
CERTBOT_SH="${REPO_ROOT}/framework/scripts/certbot-persisted-state.sh"

source "${REPO_ROOT}/tests/lib/runner.sh"

# --- 1. The classifier pattern, extracted from source, behaves correctly ------

# Pull the exact extended-regex the repair uses to classify a dead account:
# the `grep -qiE '<pattern>'` on the show_account output. Matching on
# accountDoesNotExist inside the pattern uniquely identifies the classifier
# line (there is only one per file, and this test enforces that).
#
# The regex is tolerant of grep option ordering (-qiE / -Eqi / -iEq ...) so a
# benign flag reorder in either consumer does not silently break the
# behavioral tests below. The `^[^#]*` anchor rejects any commented-out or
# in-comment reference to `grep -qiE '...accountDoesNotExist'` (docstrings,
# notes about the classifier, dead code left in a comment) so a comment
# cannot be mistaken for the live classifier line. `extract_classifier`
# also asserts there is EXACTLY ONE matching line per file: a future
# duplicate would otherwise let `head -1` arbitrarily pick one and make
# parity pass spuriously.
#
# The pattern is single-quoted by repo convention (aligned across certbot.nix
# and certbot-persisted-state.sh).
CLASSIFIER_EXTRACTION_RE="^[^#]*grep -[a-zA-Z]*E[a-zA-Z]* '[^']*accountDoesNotExist"

extract_classifier() {
  local source_file="$1"
  local match_count classifier_line pattern
  match_count="$(grep -cE "${CLASSIFIER_EXTRACTION_RE}" "${source_file}" || true)"
  if [[ "${match_count}" -ne 1 ]]; then
    # Zero or many active classifier lines. Return empty so the FATAL guard
    # below fires with a deterministic pointer (the file and the count)
    # instead of silently picking an arbitrary match via head -1.
    printf ''
    return 0
  fi
  classifier_line="$(grep -E "${CLASSIFIER_EXTRACTION_RE}" "${source_file}")"
  pattern="$(printf '%s' "${classifier_line}" | sed -E "s/.*grep -[a-zA-Z]*E[a-zA-Z]* '//; s/'.*\$//")"
  printf '%s' "${pattern}"
}

PATTERN_NIX="$(extract_classifier "${CERTBOT_NIX}")"
PATTERN_SH="$(extract_classifier "${CERTBOT_SH}")"

# Fail fast on an empty pattern from either consumer BEFORE running any of
# A610.1 / A611.1a / A611.1b. An empty ERE matches everything and would
# false-pass A610.2/A610.3; more subtly, cascading three test_fails from a
# single root cause (extraction returned empty) buries the diagnostic. A
# single FATAL that names the file AND the count of matching lines gives
# the operator one place to look.
fatal_classifier_extraction() {
  local source_file="$1"
  local match_count
  match_count="$(grep -cE "${CLASSIFIER_EXTRACTION_RE}" "${source_file}" || true)"
  echo "FATAL: expected exactly one classifier line in ${source_file} but found ${match_count}; aborting to avoid false-pass" >&2
  echo "       (a live classifier looks like: grep -qiE 'accountDoesNotExist|... — see either consumer for the canonical form)" >&2
  exit 1
}
[[ -n "${PATTERN_NIX}" ]] || fatal_classifier_extraction "${CERTBOT_NIX}"
[[ -n "${PATTERN_SH}" ]]  || fatal_classifier_extraction "${CERTBOT_SH}"

test_start "A610.1" "the certbot.nix dead-account classifier pattern was located in source"
test_pass "extracted classifier pattern from certbot.nix: ${PATTERN_NIX}"

# #611: the helper script carries an independent copy of the same ERE. Assert
# it was located so the parity check below is meaningful.
test_start "A611.1a" "the certbot-persisted-state.sh dead-account classifier pattern was located in source"
test_pass "extracted classifier pattern from certbot-persisted-state.sh: ${PATTERN_SH}"

# #611: the classifier ERE is duplicated across certbot.nix (repair path) and
# certbot-persisted-state.sh (helper probe). Silent drift — one broadened for a
# new ACME error phrasing, the other left behind — would let the un-broadened
# consumer regress with no test signal. Assert byte-equality at CI time.
test_start "A611.1b" "classifier ERE is byte-identical across certbot.nix and certbot-persisted-state.sh (#611)"
if [[ "${PATTERN_NIX}" == "${PATTERN_SH}" ]]; then
  test_pass "classifier ERE is byte-identical across both consumers"
else
  test_fail "classifier ERE differs between certbot.nix and certbot-persisted-state.sh"
  printf '    certbot.nix                : %s\n' "${PATTERN_NIX}" >&2
  printf '    certbot-persisted-state.sh : %s\n' "${PATTERN_SH}" >&2
fi

# A611.1b just asserted byte-equality between PATTERN_NIX and PATTERN_SH, so
# the behavioral tests below cover the shared extracted ERE for both consumers
# by exercising a single pattern. (The tests do NOT cover call-site framing
# such as grep flag composition — see the note above on the extraction regex.)
# Keep PATTERN as the canonical variable name the rest of the file uses.
PATTERN="${PATTERN_NIX}"

# Echoes "dead" when the pattern classifies the input as a dead account,
# "other" otherwise — exactly mirroring the repair's dead vs. unreachable fork.
classify() {
  if printf '%s' "$1" | grep -qiE "${PATTERN}"; then
    printf 'dead'
  else
    printf 'other'
  fi
}

test_start "A610.2" "classifier treats plain-text 'Account does not exist' as dead (#610)"
if [[ "$(classify 'An unexpected error occurred:
Account does not exist')" == "dead" ]]; then
  test_pass "plain-text CLI rendering classifies dead"
else
  test_fail "plain-text 'Account does not exist' was NOT classified dead — the #610 bug"
fi

test_start "A610.3" "classifier still treats the ACME URN token as dead (no regression)"
if [[ "$(classify 'Error: urn:ietf:params:acme:error:accountDoesNotExist :: Account does not exist')" == "dead" ]]; then
  test_pass "URN token classifies dead"
else
  test_fail "accountDoesNotExist URN token was NOT classified dead"
fi

test_start "A610.4" "classifier is case- and whitespace-robust"
robust=1
for sample in \
  'ACCOUNT DOES NOT EXIST' \
  'account does not exist' \
  'Account   does    not   exist' \
  'The request specified an account that does not exist :: Account does not exist'; do
  if [[ "$(classify "${sample}")" != "dead" ]]; then
    robust=0
    printf '    NOT classified dead: %q\n' "${sample}" >&2
  fi
done
if [[ "${robust}" -eq 1 ]]; then
  test_pass "case/whitespace variants all classify dead"
else
  test_fail "a case/whitespace variant failed to classify dead"
fi

test_start "A610.5" "classifier does NOT fire on generic connection/TLS failures (stays fail-closed)"
notdead=1
for sample in \
  'Could not connect to https://acme:14000/directory: [Errno 111] Connection refused' \
  'certificate verify failed: unable to get local issuer certificate' \
  'CERTIFICATE_VERIFY_FAILED' \
  'Requesting acme/acme: Connection refused'; do
  if [[ "$(classify "${sample}")" == "dead" ]]; then
    notdead=0
    printf '    wrongly classified dead: %q\n' "${sample}" >&2
  fi
done
if [[ "${notdead}" -eq 1 ]]; then
  test_pass "connection/TLS errors return no dead verdict (caller fails closed, G4)"
else
  test_fail "a generic failure was wrongly classified dead — would re-register blind"
fi

# --- 2. The repair unit is rerunnable before every renewal --------------------

# Extract the certbot-repair-persisted-state.service declaration up to (but not
# including) its embedded `script = ''` shell block. serviceConfig precedes the
# script, so RemainAfterExit — if present — is in this region. Stopping at the
# script avoids brace-counting through the shell body.
read -r -d '' REPAIR_HEAD_AWK <<'AWK' || true
/systemd\.services\.certbot-repair-persisted-state = \{/ { in_svc = 1 }
in_svc && /^[[:space:]]*script = ''/ { exit }
in_svc { print }
AWK
repair_head="$(awk "${REPAIR_HEAD_AWK}" "${CERTBOT_NIX}")"

test_start "A610.6" "certbot-repair-persisted-state.service is NOT RemainAfterExit (rerunnable) (#610)"
if [[ -z "${repair_head}" ]]; then
  test_fail "could not locate certbot-repair-persisted-state.service in certbot.nix"
elif grep -Eq 'RemainAfterExit[[:space:]]*=[[:space:]]*true' <<< "${repair_head}"; then
  test_fail "repair service still sets RemainAfterExit=true — a successful boot repair would sit active(exited) and be skipped before a later renewal"
else
  test_pass "repair service has no RemainAfterExit=true; it returns to inactive and re-runs when pulled in"
fi

# Extract the certbot-renew.service block. It contains no '' shell block
# (ExecStart = certbotRenewScript), so brace counting is safe.
read -r -d '' RENEW_BLOCK_AWK <<'AWK' || true
/systemd\.services\.certbot-renew = \{/ { in_blk = 1 }
in_blk {
  print
  n = gsub(/\{/, "{"); depth += n
  m = gsub(/\}/, "}"); depth -= m
  if (started && depth <= 0) { exit }
  if (n > 0) started = 1
}
AWK
renew_block="$(awk "${RENEW_BLOCK_AWK}" "${CERTBOT_NIX}")"

# Does the `<key> = [ ... ]` list (possibly spanning multiple lines) in the
# given block contain the needle? Handles both the single-line `wants = [...]`
# and the multi-line `after = [ \n ... \n ];` forms.
list_has() {
  local block="$1" key="$2" needle="$3"
  awk -v key="${key}" -v needle="${needle}" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" { grab = 1 }
    grab {
      buf = buf $0 "\n"
      if ($0 ~ /\][[:space:]]*;/) grab = 0
    }
    END { print (index(buf, needle) ? "yes" : "no") }
  ' <<< "${block}"
}

test_start "A610.7" "certbot-renew.service wants AND after certbot-repair-persisted-state.service"
after_ok=0; wants_ok=0
[[ "$(list_has "${renew_block}" after "certbot-repair-persisted-state.service")" == "yes" ]] && after_ok=1
[[ "$(list_has "${renew_block}" wants "certbot-repair-persisted-state.service")" == "yes" ]] && wants_ok=1
if [[ -n "${renew_block}" && "${after_ok}" -eq 1 && "${wants_ok}" -eq 1 ]]; then
  test_pass "renewal pulls in (wants) and orders after (after) the rerunnable repair, so repair runs before every renewal"
else
  test_fail "certbot-renew.service must wants+after certbot-repair-persisted-state.service (after=${after_ok} wants=${wants_ok})"
fi

runner_summary
