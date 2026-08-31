#!/usr/bin/env bash

# Assert framework/scripts/configure-backups.sh's MANAGED_MARKER is
# ASCII-only.
#
# Why this test exists: the marker string is sent via pvesh over SSH to
# Proxmox, which uses Perl. /usr/share/perl5/PVE/File.pm writes the
# notes-template field to a filehandle that is NOT opened in :utf8 mode.
# When the marker contained an em-dash (U+2014, UTF-8 bytes 0xE2 0x80 0x94)
# Perl emitted "Wide character in print at .../File.pm line 77" and the
# bytes written got reinterpreted as Latin-1 on read-back. The script's
# write -> read-back -> drift-check loop then always reported a mismatch
# and exited 1, breaking both rebuild-cluster.sh's Step 15.5 and the
# deploy:prod pipeline's post-success convergence.
#
# This regression is invisible to local testing — both writes and reads go
# through PVE on a real cluster, so a code review wouldn't catch a curly-
# quote auto-substitution by an editor without a real cluster to exercise
# the script. This static test catches the source-level non-ASCII without
# needing PVE.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/configure-backups.sh"

test_start "1" "MANAGED_MARKER assignment exists"
marker_line=$(grep -nE '^MANAGED_MARKER=' "${SCRIPT}" || true)
if [[ -n "$marker_line" ]]; then
  test_pass "MANAGED_MARKER= line present at: ${marker_line%%:*}"
else
  test_fail "no MANAGED_MARKER= assignment in ${SCRIPT}"
fi

test_start "2" "MANAGED_MARKER is ASCII-only (no byte >= 0x80)"
# Extract the assigned string and check every byte is in [0x09, 0x7E].
# Python is more reliable than locale-dependent grep -P for this.
marker_value=$(awk -F= '/^MANAGED_MARKER=/ { sub(/^MANAGED_MARKER=/, ""); print; exit }' "${SCRIPT}")
# Strip surrounding double quotes.
marker_value="${marker_value%\"}"
marker_value="${marker_value#\"}"
if python3 -c "
import sys
s = sys.argv[1]
for i, ch in enumerate(s):
    if ord(ch) > 127:
        print(f'byte {i}: U+{ord(ch):04X} ({ch!r})', file=sys.stderr)
        sys.exit(1)
sys.exit(0)
" "$marker_value"; then
  test_pass "marker is ASCII-only: ${marker_value}"
else
  test_fail "marker contains non-ASCII characters; pvesh round-trip will mangle them"
fi

runner_summary
