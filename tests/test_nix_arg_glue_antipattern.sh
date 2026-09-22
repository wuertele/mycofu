#!/usr/bin/env bash
# test_nix_arg_glue_antipattern.sh
#
# Catches the certbot-renew bug class: a Nix `''...''` multi-line string
# whose first non-blank content line is a bare line-continuation
# backslash. When such a string is interpolated immediately after a
# command-line argument, bash glues the previous arg directly to the
# next line's content WITH NO SPACE — producing nonsense like
# "--non-interactive--deploy-hook" (one token) instead of two flags.
#
# Example of the bug:
#   certbot renew --non-interactive${lib.optionalString cond ''
#     \
#     --deploy-hook "..."''}
#
# After Nix indent-stripping the optional string is "\n\\\n--deploy-hook ..."
# which when concatenated to "--non-interactive" produces:
#   certbot renew --non-interactive\
#   --deploy-hook "..."
# Bash's `\<newline>` continuation glues the next line on with no space.
#
# Correct form: put the leading space inside the optional string itself,
# or use a single-line optional string:
#   ${lib.optionalString cond " --deploy-hook \"...\""}

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

test_start "1" "no Nix multi-line string opens with a bare continuation backslash"

set +e
HITS="$(
  python3 - "${REPO_ROOT}" <<'PY'
import os
import re
import sys

repo_root = sys.argv[1]
roots = [
    os.path.join(repo_root, 'framework', 'nix'),
    os.path.join(repo_root, 'site', 'nix'),
]

# Pattern: opening of a Nix multi-line string (two single quotes), then
# optional trailing whitespace, newline, optional indent, a backslash,
# optional trailing whitespace, newline. This is the exact shape that
# produces the arg-glue bug when interpolated after a non-whitespace
# token.
pattern = re.compile(r"''[ \t]*\n[ \t]*\\[ \t]*\n")

found = []
for root in roots:
    if not os.path.isdir(root):
        continue
    for dirpath, _dirs, files in os.walk(root):
        for fname in files:
            if not fname.endswith('.nix'):
                continue
            path = os.path.join(dirpath, fname)
            try:
                with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                    text = fh.read()
            except OSError:
                continue
            for m in pattern.finditer(text):
                line = text.count('\n', 0, m.start()) + 1
                rel = os.path.relpath(path, repo_root)
                found.append(f"{rel}:{line}")

for f in found:
    print(f)

sys.exit(0 if not found else 1)
PY
)"
GREP_STATUS=$?
set -e

if [[ "$GREP_STATUS" -eq 0 ]]; then
  test_pass "no anti-pattern matches found in framework/nix or site/nix"
elif [[ "$GREP_STATUS" -eq 1 ]]; then
  test_fail "Nix files contain a multi-line string opening with a continuation backslash (arg-glue hazard)"
  printf '%s\n' "$HITS" >&2
  cat >&2 <<'HINT'

Fix: put the leading space inside the optional string, or use a
single-line form. Multi-line opening with a bare backslash glues the
previous arg directly to the next line with no separator.
HINT
else
  test_fail "python3 scan failed (exit ${GREP_STATUS})"
fi

test_start "2" "self-test: detector matches a synthetic anti-pattern"

# Build a temporary fixture under /tmp that contains the anti-pattern, then
# point the detector at it explicitly. This guards against false negatives
# (e.g. someone breaks the regex and the test still claims to pass).
FIXTURE_DIR="$(mktemp -d -t nix-arg-glue-fixture-XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "${FIXTURE_DIR}/framework/nix"
cat > "${FIXTURE_DIR}/framework/nix/bad.nix" <<'BAD_FIXTURE'
{ lib, ... }:
{
  bad = ''
    cmd --foo${lib.optionalString true ''
      \
      --bar "value"''}
  '';
}
BAD_FIXTURE

set +e
FIXTURE_HITS="$(
  python3 - "${FIXTURE_DIR}" <<'PY'
import os
import re
import sys

repo_root = sys.argv[1]
roots = [
    os.path.join(repo_root, 'framework', 'nix'),
    os.path.join(repo_root, 'site', 'nix'),
]

pattern = re.compile(r"''[ \t]*\n[ \t]*\\[ \t]*\n")

found = []
for root in roots:
    if not os.path.isdir(root):
        continue
    for dirpath, _dirs, files in os.walk(root):
        for fname in files:
            if not fname.endswith('.nix'):
                continue
            path = os.path.join(dirpath, fname)
            try:
                with open(path, 'r', encoding='utf-8', errors='replace') as fh:
                    text = fh.read()
            except OSError:
                continue
            for m in pattern.finditer(text):
                line = text.count('\n', 0, m.start()) + 1
                rel = os.path.relpath(path, repo_root)
                found.append(f"{rel}:{line}")

for f in found:
    print(f)

sys.exit(0 if not found else 1)
PY
)"
FIXTURE_STATUS=$?
set -e

if [[ "$FIXTURE_STATUS" -eq 1 && -n "$FIXTURE_HITS" ]]; then
  test_pass "detector catches the synthetic anti-pattern (exit 1, hit reported)"
else
  test_fail "detector did NOT catch the synthetic anti-pattern (status=${FIXTURE_STATUS}, hits=${FIXTURE_HITS:-<empty>})"
fi

runner_summary
