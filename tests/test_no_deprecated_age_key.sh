#!/usr/bin/env bash
# test_no_deprecated_age_key.sh — CI ratchet forbidding active-code
# references to the deprecated `operator.age.key.production` SOPS key
# (#375, follow-up to #363).
#
# ## Background
#
# `.production` was a misguided SOPS-age-key fallback that lived in 8
# scripts for months. #363 (MR !282) removed it from the tracked tree
# and from every script fallback path; the canonical key is now
# `operator.age.key` (no `.production` suffix). Codex's #363 review
# (P3) observed there is nothing structural preventing a 9th script
# from drifting the fallback back in. This ratchet is that structure.
#
# ## What this forbids
#
# Any active-code reference to the literal string
# `operator.age.key.production`. "Active code" is the whole repo
# EXCEPT:
#   - `.git/`                    (VCS internals)
#   - `docs/`                    (historical sprint docs / reviewer reports)
#   - any `*.md`                 (prose, incl. this MR's own review files)
#   - `.gitignore`               (a defensive ignore entry is intentional —
#                                 it keeps a stray key file from being
#                                 committed; it is not a code fallback path)
#   - this test file itself      (it names the string as its pattern)
#
# The exclusions match the #363 cleanup contract exactly: the grep is
# clean today, and this ratchet keeps it clean.
#
# ## Fixing a failure
#
# If this test fails, an active-code path referenced
# `operator.age.key.production`. The `.production` variant is deprecated;
# use `operator.age.key`. See `.claude/rules` SOPS usage and #363.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

SELF_BASENAME="$(basename "${BASH_SOURCE[0]}")"

# Scan a tree for active-code references to the deprecated key.
# Prints `path:line:content` for each hit; returns 0 if clean, 1 if hits.
scan_for_deprecated_key() {
  local root="$1"
  # grep returns 1 when there are no matches (clean) — that is success
  # for us, so guard against `set -e` killing the script.
  local hits
  set +e
  hits="$(grep -rn 'operator\.age\.key\.production' \
    --exclude-dir=.git \
    --exclude-dir=docs \
    --exclude='*.md' \
    --exclude='.gitignore' \
    --exclude="${SELF_BASENAME}" \
    "$root" 2>/dev/null)"
  set -e
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    return 1
  fi
  return 0
}

# --- Test 1: the repo is clean --------------------------------------------
test_start "1" "no active-code references to operator.age.key.production"
SCAN_OUT="$(mktemp -t age-key-scan.XXXXXX)"
SCRATCH=""
trap 'rm -f "$SCAN_OUT"; [[ -n "$SCRATCH" ]] && rm -rf "$SCRATCH"' EXIT
SCAN_RC=0
scan_for_deprecated_key "$REPO_ROOT" > "$SCAN_OUT" 2>&1 || SCAN_RC=$?
if [[ "$SCAN_RC" -eq 0 ]]; then
  test_pass "no deprecated age-key references in active code"
else
  {
    echo "FAIL: active-code references to operator.age.key.production found:"
    sed 's/^/  /' "$SCAN_OUT"
    echo ""
    echo "The .production variant is deprecated. Use operator.age.key."
    echo "See tests/test_no_deprecated_age_key.sh and #375 / #363."
  } >&2
  test_fail "found $(wc -l < "$SCAN_OUT" | tr -d ' ') active-code reference(s)"
fi

# --- Test 2: self-test — the scanner catches a synthetic offender ---------
# A green ratchet is only trustworthy if it can go red for a real defect.
test_start "2" "scanner catches synthetic offender (self-test)"
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/framework/scripts"
# Reconstruct the literal at runtime so this fixture line does not itself
# trip a naive repo-wide grep for the deprecated string.
KEY="operator.age.key.$(printf 'production')"
cat > "$SCRATCH/framework/scripts/offender.sh" <<EOF
#!/usr/bin/env bash
SOPS_AGE_KEY_FILE=${KEY} sops -d site/sops/secrets.yaml
EOF
SELF_RC=0
scan_for_deprecated_key "$SCRATCH" >/dev/null 2>&1 || SELF_RC=$?
rm -rf "$SCRATCH"; SCRATCH=""
if [[ "$SELF_RC" -eq 1 ]]; then
  test_pass "scanner correctly flagged synthetic offender"
else
  test_fail "scanner missed the synthetic offender (rc=${SELF_RC}) — detector may be broken"
fi

runner_summary
