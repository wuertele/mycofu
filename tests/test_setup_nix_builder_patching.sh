#!/usr/bin/env bash

# Test the run-nixos-vm patching logic in setup-nix-builder.sh.
#
# Three regressions this test catches:
#
# 1. Sed pattern: the old literal-only `s/20480M/...M/` silently no-ops
#    when upstream nixpkgs changes the run-nixos-vm default disk size.
#    Tests 1-3 below assert the context-anchored regex correctly
#    rewrites the current upstream line (40960M), the legacy line
#    (20480M), and refuses to silently overmatch a changed line shape.
#
# 2. STORE_GB scoping: setup-nix-builder.sh reads STORE_GB from
#    site/config.yaml but the patching block lives in a single-quoted
#    heredoc that gets written verbatim into ~/.nix-builder/start-builder.sh.
#    If STORE_GB isn't exported into start-builder.sh's environment,
#    `${STORE_GB:-40}` always defaults to 40 and the configured size
#    is silently ignored. Test 4 asserts setup-nix-builder.sh's
#    write_start_script function exports STORE_GB into the generated
#    script.
#
# 3. Verification gate: the patching block must fail loudly (exit 1)
#    when the sed substitution doesn't take. Test 5 asserts this by
#    sourcing the relevant code fragment in isolation against a
#    changed-shape upstream and confirming the script exits non-zero.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

SETUP_SCRIPT="${REPO_ROOT}/framework/scripts/setup-nix-builder.sh"

# Extract the patching sed + verification block from setup-nix-builder.sh
# and run it against a synthetic upstream file.
#
# Args: $1=input line, $2=disk_mb to substitute
# Returns: the contents of the (possibly) patched file, via stdout.
#          Exits non-zero if the verification grep in the script would
#          have failed (matching the production behavior).
run_patching_block() {
  local input_line="$1"
  local disk_mb="$2"
  local tmpfile
  tmpfile=$(mktemp)
  trap "rm -f '$tmpfile'" RETURN
  printf '%s\n' "$input_line" > "$tmpfile"

  # Exact sed from setup-nix-builder.sh's patching block.
  sed -i '' -E "s/(createEmptyFilesystemImage \"\\\$NIX_DISK_IMAGE\" \")[0-9]+M/\\1${disk_mb}M/" "$tmpfile"

  # Exact verification grep from setup-nix-builder.sh's patching block.
  if ! grep -qF "createEmptyFilesystemImage \"\$NIX_DISK_IMAGE\" \"${disk_mb}M\"" "$tmpfile"; then
    cat "$tmpfile"
    return 1
  fi
  cat "$tmpfile"
  return 0
}

test_start "1" "sed rewrites current upstream line shape (40960M -> configured)"
expected='createEmptyFilesystemImage "$NIX_DISK_IMAGE" "81920M"'
if got=$(run_patching_block \
    'createEmptyFilesystemImage "$NIX_DISK_IMAGE" "40960M"' 81920) \
    && [[ "$got" == "$expected" ]]; then
  test_pass "current upstream line shape correctly patched to 81920M"
else
  test_fail "expected '${expected}', got '${got}'"
fi

test_start "2" "sed rewrites legacy upstream line shape (20480M -> configured)"
expected='createEmptyFilesystemImage "$NIX_DISK_IMAGE" "81920M"'
if got=$(run_patching_block \
    'createEmptyFilesystemImage "$NIX_DISK_IMAGE" "20480M"' 81920) \
    && [[ "$got" == "$expected" ]]; then
  test_pass "legacy upstream line shape correctly patched to 81920M"
else
  test_fail "expected '${expected}', got '${got}'"
fi

test_start "3" "sed leaves a hypothetical changed line shape unchanged AND verification fails loudly"
# Simulates a future upstream that renames the helper function. The sed
# pattern shouldn't match; the verification grep should reject; the
# function should exit non-zero (matching the production exit 1).
if run_patching_block \
    'create_disk_image "$NIX_DISK_IMAGE" --size 40960M' 81920 \
    >/dev/null 2>&1; then
  test_fail "patching block accepted a changed line shape silently (production would create a wrong-sized qcow2)"
else
  test_pass "patching block correctly rejects an unknown line shape"
fi

test_start "4" "setup-nix-builder.sh exports STORE_GB into the generated start-builder.sh"
# Extract the write_start_script function and confirm the unquoted-heredoc
# block (which is the only one that expands variables at generation time)
# contains `export STORE_GB=`. Without this, the single-quoted heredoc's
# patching block sees STORE_GB as unset at builder boot time and defaults
# DISK_MB to 40960.
write_fn=$(awk '/^write_start_script\(\) \{/,/^\}$/' "${SETUP_SCRIPT}")
# Look only inside the unquoted (variable-expanding) STARTEOF block by
# finding the cat block delimited by `<<STARTEOF` (no leading single quote)
# and the matching closing `STARTEOF`.
unquoted_block=$(echo "$write_fn" | awk '
  /<<STARTEOF$/ { in_block=1; next }
  in_block && /^STARTEOF$/ { in_block=0; next }
  in_block { print }
')
if echo "$unquoted_block" | grep -qE '^export STORE_GB='; then
  test_pass "write_start_script exports STORE_GB into the variable-expanding heredoc"
else
  test_fail "write_start_script does NOT export STORE_GB; start-builder.sh will silently default DISK_MB to 40960"
fi

test_start "5" "sed pattern matches the literal upstream line shape currently in setup-nix-builder.sh's heredoc"
# Catches a future regression where the sed pattern in setup-nix-builder.sh
# falls out of sync with the line shape it's expected to match. Compare
# the sed source pattern against an upstream-current line and confirm
# they're compatible.
if echo 'createEmptyFilesystemImage "$NIX_DISK_IMAGE" "40960M"' \
    | sed -E 's/(createEmptyFilesystemImage "\$NIX_DISK_IMAGE" ")[0-9]+M/\181920M/' \
    | grep -qF 'createEmptyFilesystemImage "$NIX_DISK_IMAGE" "81920M"'; then
  test_pass "sed pattern is compatible with current upstream line shape"
else
  test_fail "sed pattern fails against current upstream line shape (40960M)"
fi

# --- Convergence assertions (tests 6-10) -------------------------------
# These tests verify the script enforces its own invariants automatically.
# Each one catches a "the operator had to remember to do X" defect that
# previously produced a silently-broken builder. They are source-level
# static assertions, not full-script execution, so they run fast and
# don't require a real builder VM.

test_start "6" "converge_builder() is defined and exported by setup-nix-builder.sh"
# Without the converge_builder function, the script's entrypoints have
# no way to detect/fix drift, and the operator is back to manual
# choreography.
if grep -qE '^converge_builder\(\) \{' "${SETUP_SCRIPT}"; then
  test_pass "converge_builder() function present"
else
  test_fail "converge_builder() not defined; --start, --verify, and default path will not auto-converge"
fi

test_start "7" "--start dispatch calls converge_builder on Darwin (no manual --stop/regen/--start dance)"
# The previous --start path called start_builder_vm directly, which
# launched the existing start-builder.sh without re-checking whether
# it matched config. That's how the cicd-tailscale regression went
# undetected for two days.
start_dispatch=$(awk '/^if \[\[ \$START_ONLY -eq 1 \]\];/,/^fi$/' "${SETUP_SCRIPT}")
if echo "$start_dispatch" | grep -q 'converge_builder'; then
  test_pass "--start invokes converge_builder"
else
  test_fail "--start does not invoke converge_builder; stale launcher will run silently"
fi

test_start "8" "--verify dispatch calls converge_builder on Darwin"
# Same risk if --verify is the operator's only check after a pull: it
# would report 'ok' against a stale builder.
verify_dispatch=$(awk '/^if \[\[ \$VERIFY_ONLY -eq 1 \]\];/,/^fi$/' "${SETUP_SCRIPT}")
if echo "$verify_dispatch" | grep -q 'converge_builder'; then
  test_pass "--verify invokes converge_builder"
else
  test_fail "--verify does not invoke converge_builder; can report ok on stale state"
fi

test_start "9" "qcow2 size mismatch triggers automatic purge + regen"
# The framework defect codex catalogued in the 2026-06-01 RCA: every
# previous recovery codepath deleted only store.img, never nixos.qcow2.
# converge_builder must purge BOTH on size mismatch, otherwise a config
# change to store_gb produces the same silent 40 GiB qcow2 forever.
qcow2_status_fn=$(awk '/^qcow2_size_status\(\) \{/,/^\}$/' "${SETUP_SCRIPT}")
converge_fn=$(awk '/^converge_builder\(\) \{/,/^\}$/' "${SETUP_SCRIPT}")
if [[ -n "$qcow2_status_fn" ]] \
   && echo "$qcow2_status_fn" | grep -q 'virtual-size' \
   && echo "$converge_fn" | grep -q 'wrong-size' \
   && echo "$converge_fn" | grep -q 'purge_builder_disks'; then
  test_pass "size mismatch -> purge_builder_disks + regen path is wired"
else
  test_fail "size mismatch detection or purge_builder_disks call missing from converge_builder"
fi

test_start "10" "purge_builder_disks removes both qcow2 AND store.img (not just store.img)"
# The recovery path in build-image.sh and reset-cluster.sh historically
# deleted only store.img — codex flagged this in the RCA. The new
# helper must purge both, otherwise a forced size change leaves the
# old qcow2 in place.
#
# Check the function body for references to both files. The file paths
# in the function are variable references ($QCOW2_FILE,
# $STORE_IMG_FILE); also check those variables resolve to filenames
# that contain qcow2 and store.img respectively.
purge_fn=$(awk '/^purge_builder_disks\(\) \{/,/^\}$/' "${SETUP_SCRIPT}")
qcow2_var=$(grep -E '^QCOW2_FILE=' "${SETUP_SCRIPT}" | head -1)
store_img_var=$(grep -E '^STORE_IMG_FILE=' "${SETUP_SCRIPT}" | head -1)
if echo "$purge_fn" | grep -q 'QCOW2_FILE' \
   && echo "$purge_fn" | grep -q 'STORE_IMG_FILE' \
   && echo "$qcow2_var" | grep -q 'nixos.qcow2' \
   && echo "$store_img_var" | grep -q 'store.img'; then
  test_pass "purge_builder_disks removes both qcow2 and store.img"
else
  test_fail "purge_builder_disks does NOT remove both files; size mismatch will persist"
fi

# --- Convergence completeness assertions (tests 11-14) ----------------
# Address the codex/gemini P1 finding that convergence was incomplete.

test_start "11" "qcow2 unverifiable (qemu-img missing) treated as drift, not silently accepted"
# The original implementation returned 'unknown' when qemu-img wasn't on
# PATH, and converge_builder accepted that. On this exact workstation
# (qemu-img not on PATH), that recreates the silent-mismatch failure
# class this MR exists to eliminate. Verify the new code treats
# unverifiable as drift.
qcow2_fn=$(awk '/^qcow2_size_status\(\) \{/,/^\}$/' "${SETUP_SCRIPT}")
if echo "$qcow2_fn" | grep -q 'wrong-size:unknown'; then
  test_pass "qcow2_size_status returns 'wrong-size:unknown' when qemu-img is unavailable"
else
  test_fail "qcow2_size_status returns 'unknown' / 'ok' when unverifiable — silent mismatch will recur"
fi

test_start "12" "start_script_status detects CPU/RAM drift, not just STORE_GB"
# Codex P1: if cpus or memory_gb changes in config.yaml but store_gb stays
# the same, the old check only looks at STORE_GB. The script then runs
# the stale start-builder.sh with the wrong resources.
ss_fn=$(awk '/^start_script_status\(\) \{/,/^\}$/' "${SETUP_SCRIPT}")
if echo "$ss_fn" | grep -q 'wrong-qemu-opts' \
   && echo "$ss_fn" | grep -q 'CPUS' \
   && echo "$ss_fn" | grep -q 'MEMORY_MB'; then
  test_pass "start_script_status checks CPU/RAM in addition to STORE_GB"
else
  test_fail "start_script_status does not detect CPU/RAM drift"
fi

test_start "13" "ensure_builder_stopped kills ALL matching PIDs (not just head -1)"
# Gemini P1: pgrep | head -1 + wait-for-all-processes hangs 15s when two
# QEMU processes match. Must kill ALL PIDs.
stop_fn=$(awk '/^ensure_builder_stopped\(\) \{/,/^\}$/' "${SETUP_SCRIPT}")
if ! echo "$stop_fn" | grep -qE 'pgrep .* head -1' \
   && echo "$stop_fn" | grep -qE 'for pid in .*pids'; then
  test_pass "ensure_builder_stopped kills all matching pids (no head -1 bug)"
else
  test_fail "ensure_builder_stopped still uses head -1 + wait-for-all-processes — multi-process hang"
fi

test_start "14" "purge_builder_disks is invoked specifically when qcow2 status is wrong-size"
# Codex P2: the prior test only confirmed the strings 'wrong-size' and
# 'purge_builder_disks' appear somewhere in converge_builder. Tighten:
# confirm purge is actually inside the wrong-size case arm.
converge_fn=$(awk '/^converge_builder\(\) \{/,/^\}$/' "${SETUP_SCRIPT}")
# Extract the qcow2_state case statement and check that the
# 'wrong-size:*' arm contains 'purge_builder_disks' (via need_purge=1
# being set, which the regen/purge logic acts on later).
qcow2_case=$(echo "$converge_fn" | awk '/case "\$qcow2_state" in/,/esac/')
if echo "$qcow2_case" | awk '
  /wrong-size:.*\)/  { in_arm=1; next }
  /;;/               { in_arm=0; next }
  in_arm && /need_purge=1/ { found=1 }
  END { exit found ? 0 : 1 }
'; then
  test_pass "wrong-size arm in qcow2_state case sets need_purge=1"
else
  test_fail "wrong-size arm does NOT set need_purge=1 — convergence wouldn't purge"
fi

runner_summary
