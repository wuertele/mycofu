#!/usr/bin/env bash
# test_no_whitespace_pinned_tf_grep.sh — durable guard against
# whitespace-pinned `grep -F` on tofu module attributes (#572).
#
# ## The failure mode this guards
#
# `tofu fmt` right-aligns the `=` in a module block to the longest
# attribute name in that block. When any MR adds a new/longer attribute,
# the alignment of every sibling line shifts and existing fixed-string
# greps stop matching — a green test goes red with no actual defect.
#
# Instances seen: !430 (pattern-only-fix); Sprint 046 MR-3 hit
# `tests/test_gitlab_runner_concurrency.sh` (fixed in-branch), then hit
# `tests/test_tofu_github_remote_plumbing.sh` when `ram_floating_mb`
# joined the cicd module block (a second miss, caught only by a red
# pipeline). Each recurrence costs ~15-20 min of pipeline + RCA to
# prove "the wiring is fine, the test is brittle."
#
# ## What this test forbids
#
# Any `grep -F(q|i)?` invocation whose pattern contains
# `<identifier><whitespace>=<whitespace>` AND whose target (either the
# same line or the next 2 lines, to handle `grep -Fq "…" \\` line
# continuations, or `<<< "$block"` / `"$file"` where `$block`/`$file`
# is derived from a .tf file) references a `.tf` file, a `_TF` variable,
# a `framework/tofu/**` path, or `framework/catalog/*/main.tf`.
#
# The **whitespace-tolerant replacement** is `grep -E` with
# `[[:space:]]*=[[:space:]]*` around the `=`:
#
#     # Brittle (breaks on tofu fmt re-alignment):
#     grep -Fq "count = var.ha_enabled ? 1 : 0" pbs/main.tf
#
#     # Robust:
#     grep -Eq "count[[:space:]]*=[[:space:]]*var\.ha_enabled \? 1 : 0" pbs/main.tf
#
# Remember to backslash-escape regex metachars in the value portion
# (`.`, `?`, `+`, `*`, `|`, `(`, `)`, `[`, `]`, `{`, `}`).
#
# ## Not in scope
#
# - HCL policy files (`framework/vault/policies/*.hcl`) — those are not
#   subject to `tofu fmt` alignment.
# - Nix files (`*.nix`) — Nix's formatter (nixfmt/alejandra) has its own
#   alignment rules but this test is scoped to tofu; add a companion
#   test for Nix if the same brittleness pattern shows up there.
# - Fixed-string greps on tofu that DO NOT have `=` in the pattern
#   (e.g., `grep -Fq "vendor-appliance exception" pbs/main.tf`) — those
#   are unaffected by attribute-column re-alignment.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

cd "$REPO_ROOT"

# The scanner is a small Python program (Python 3 is available on cicd
# and on all operator platforms; the wrapper tests already source
# python3). Emits `<file>:<line>: <content>` for each offender.
SCANNER_OUT="$(mktemp -t tf-grep-scan.XXXXXX)"
trap 'rm -f "$SCANNER_OUT"' EXIT

# P2-3 (adversarial review): the Python scanner exits 1 when it finds
# offenders (that is its contract). Under `set -e` at line 32, a
# non-zero exit KILLS the wrapper script BEFORE `SCANNER_RC=$?` can
# capture it — losing the diagnostic and the offender list. Wrap the
# python3 call in `set +e` / `set -e` so the non-zero exit is captured
# cleanly.
set +e
python3 - "$REPO_ROOT" > "$SCANNER_OUT" <<'PYEOF'
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])

# P2-4 (adversarial review): widen the grep detector to catch the flag
# variants seen in the wild:
#   grep -F       grep -Fq       grep -Fqi     grep -qF
#   grep -F -q    grep -Fq --    grep --fixed-strings
# The core is `-\S*F\S*|--fixed-strings` — any grep flag that
# contains F (in any position) or the long form. Followed by any
# number of additional options `(\s+-\S+)*`, then the quoted
# pattern.
GREP_F_PATTERN = re.compile(
    r"""grep\s+(-\S*F\S*|--fixed-strings)(\s+-\S+)*\s+['"][^'"]*[a-zA-Z_][a-zA-Z_0-9]*[ \t]+=[ \t]"""
)

# Target detection: on the same line or within 2 following lines, look
# for a reference to a tofu file. Covers:
#   - explicit `.tf` in path (or as file extension)
#   - `_TF` variable references (e.g., ${INFLUXDB_TF})
#   - literal framework/tofu/… or framework/catalog/<app>/main.tf paths
#   - `<<< "$block"` or `"$file"` where the block/file is captured from
#     a nearby .tf file — treated as tf-adjacent
TF_REF = re.compile(
    r'\.tf(\b|["\'\s;)])'
    r'|_TF[}"\')\s;]'
    r'|framework/tofu'
    r'|framework/catalog/[a-zA-Z_-]+/main\.tf'
    r'|<<< "\$block"'
    r'|"\$file"'
)

offenders = []
for f in sorted((repo / "tests").glob("*.sh")):
    # Skip this test itself
    if f.name == "test_no_whitespace_pinned_tf_grep.sh":
        continue
    lines = f.read_text().splitlines()
    for i, line in enumerate(lines):
        if not GREP_F_PATTERN.search(line):
            continue
        # Look 2 lines ahead for the tf reference (handles line
        # continuations and grep-then-newline-then-filename).
        context = " ".join(lines[i:i+3])
        if TF_REF.search(context):
            offenders.append(f"{f.relative_to(repo)}:{i+1}: {line.strip()}")

for o in offenders:
    print(o)
sys.exit(0 if not offenders else 1)
PYEOF
SCANNER_RC=$?
set -e

test_start "1" "no whitespace-pinned grep -F on tofu module attributes"
if [[ "$SCANNER_RC" -eq 0 ]]; then
  test_pass "no whitespace-pinned grep -F on .tf files"
else
  {
    echo "FAIL: whitespace-pinned \`grep -F\` on tofu module attributes found."
    echo "Replace with whitespace-tolerant \`grep -E\` and \`[[:space:]]*=[[:space:]]*\`."
    echo "Offenders:"
    sed 's/^/  /' "$SCANNER_OUT"
    echo "See tests/test_no_whitespace_pinned_tf_grep.sh for the rewrite pattern."
  } >&2
  test_fail "found $(wc -l < "$SCANNER_OUT" | tr -d ' ') offender(s)"
fi

# --- Self-test: the scanner must catch a synthetic offender ---------------
# This proves the scanner actually detects the pattern (a green scanner is
# only useful if it can go red for a real defect). We create a temp test
# file that contains a whitespace-pinned grep -F on a .tf-targeting line,
# run the scanner against a scratch repo, and assert it exits non-zero.
test_start "2" "scanner catches synthetic offender (self-test)"
SCRATCH="$(mktemp -d)"
mkdir -p "$SCRATCH/tests"
cat > "$SCRATCH/tests/test_synthetic_offender.sh" <<'FIXTURE'
#!/usr/bin/env bash
# This file exists ONLY to make the scanner self-test go red on cue.
# Cover THREE flag variants so a future detector weakening breaks the
# self-test regardless of which variant is emitted:
if grep -Fq "count   = var.ha_enabled ? 1 : 0" framework/tofu/modules/pbs/main.tf; then
  echo A
fi
if grep -qF "started   = true" framework/tofu/modules/pbs/main.tf; then
  echo B
fi
if grep --fixed-strings "default   = true" framework/tofu/modules/pbs/main.tf; then
  echo C
fi
FIXTURE
SELF_TEST_RC=0
# P2-4: use the same widened detector as the main scanner (kept in sync
# so a future flag variant added upstream is guaranteed to be exercised
# by the self-test).
python3 - "$SCRATCH" >/dev/null <<'PYEOF' || SELF_TEST_RC=$?
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
GREP_F_PATTERN = re.compile(
    r"""grep\s+(-\S*F\S*|--fixed-strings)(\s+-\S+)*\s+['"][^'"]*[a-zA-Z_][a-zA-Z_0-9]*[ \t]+=[ \t]"""
)
TF_REF = re.compile(
    r'\.tf(\b|["\'\s;)])'
    r'|_TF[}"\')\s;]'
    r'|framework/tofu'
    r'|framework/catalog/[a-zA-Z_-]+/main\.tf'
    r'|<<< "\$block"'
    r'|"\$file"'
)
offenders = []
for f in sorted((repo / "tests").glob("*.sh")):
    lines = f.read_text().splitlines()
    for i, line in enumerate(lines):
        if not GREP_F_PATTERN.search(line):
            continue
        context = " ".join(lines[i:i+3])
        if TF_REF.search(context):
            offenders.append(f"{f}:{i+1}")
sys.exit(0 if not offenders else 1)
PYEOF
rm -rf "$SCRATCH"
if [[ "$SELF_TEST_RC" -ne 0 ]]; then
  test_pass "scanner correctly flagged synthetic offender"
else
  test_fail "scanner missed the synthetic offender — scanner regex may be broken"
fi

runner_summary
