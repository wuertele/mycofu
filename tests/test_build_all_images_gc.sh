#!/usr/bin/env bash
# Verifies the #469/#471/#472 fixes in build-all-images.sh:
#   - default host-store threshold is 40 GiB (was 20 GiB)
#   - NIX_MIN_FREE_GB env override still works
#   - periodic GC triggers based on GC_TIMESTAMP_FILE age even when
#     free space is above threshold
#   - run_host_gc writes the timestamp file
#
# And the #413 sudo_tee helpers in setup-nix-builder.sh:
#   - sudo_tee_write / sudo_tee_append return non-zero when the underlying
#     tee fails, instead of silently succeeding under `set -uo pipefail`
#
# Design: we extract just the helper region from each script via
# markers, source it in a fresh subshell with mocks on PATH, and assert
# the observable behaviors. This avoids sourcing the whole script (which
# executes site-config-validation at load time) and avoids a bespoke
# copy that would drift from the real script.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

BUILD_ALL_SCRIPT="${REPO_ROOT}/framework/scripts/build-all-images.sh"
SETUP_BUILDER_SCRIPT="${REPO_ROOT}/framework/scripts/setup-nix-builder.sh"

# Extract the GC helper block from build-all-images.sh: from the
# GC_ROOT_DIR assignment through the end of check_store_space. The
# extract stops at the first `^}` line that follows the check_store_space
# definition — that closing brace matches column 0.
extract_gc_helpers() {
  awk '
    /^GC_ROOT_DIR=/ { in_block=1 }
    in_block { print }
    in_block && /^check_store_space\(\)/ { saw_fn=1 }
    saw_fn && /^}$/ { exit }
  ' "$BUILD_ALL_SCRIPT"
}

# Extract the sudo_tee helpers from setup-nix-builder.sh: from
# sudo_tee_write() through the closing brace of sudo_tee_append.
extract_sudo_tee_helpers() {
  awk '
    /^sudo_tee_write\(\)/ { in_block=1 }
    in_block { print }
    in_block && /^sudo_tee_append\(\)/ { saw_append=1 }
    saw_append && /^}$/ { exit }
  ' "$SETUP_BUILDER_SCRIPT"
}

# --- Case s469.1: default NIX_MIN_FREE_GB is 40 (was 20) ---
test_start "s469.1" "default host-store threshold is 40 GiB, not 20"
default_val=$(grep -oE 'NIX_MIN_FREE_GB:-[0-9]+' "$BUILD_ALL_SCRIPT" | head -1)
if [[ "$default_val" == "NIX_MIN_FREE_GB:-40" ]]; then
  test_pass "check_store_space default threshold is 40 GiB"
else
  test_fail "check_store_space default is '${default_val}', expected NIX_MIN_FREE_GB:-40"
fi

# --- Case s469.2: NIX_MIN_FREE_GB env override still works ---
# The parameter expansion syntax `${NIX_MIN_FREE_GB:-40}` respects the
# env var if set. This is a syntactic assertion — the file uses the
# override-friendly form.
test_start "s469.2" "NIX_MIN_FREE_GB env-var override syntax preserved"
if grep -qF '${NIX_MIN_FREE_GB:-40}' "$BUILD_ALL_SCRIPT"; then
  test_pass "override form \${NIX_MIN_FREE_GB:-40} present"
else
  test_fail "override form missing — env override no longer works"
fi

# --- Case s472.1: periodic-GC trigger fires when timestamp is old ---
# Extract the helpers, mock df/nix-collect-garbage/date, verify triggering.
test_start "s472.1" "periodic GC triggers when GC_TIMESTAMP_FILE is older than NIX_GC_MAX_AGE_DAYS"
work="$(mktemp -d)"
GC_HELPERS="$work/gc-helpers.sh"
extract_gc_helpers > "$GC_HELPERS"

# Sanity: extraction included both helpers.
if ! grep -q 'run_host_gc()' "$GC_HELPERS" || ! grep -q 'check_store_space()' "$GC_HELPERS"; then
  test_fail "helper extraction did not include run_host_gc and check_store_space"
  rm -rf "$work"
else
  # Mock nix-collect-garbage in PATH so run_host_gc does not touch real nix.
  mock_bin="$work/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/nix-collect-garbage" <<'MOCKEOF'
#!/bin/sh
echo "MOCK: nix-collect-garbage called"
exit 0
MOCKEOF
  chmod +x "$mock_bin/nix-collect-garbage"

  # Backdate GC_TIMESTAMP_FILE to 30 days ago; force plenty of free
  # space via a df wrapper that reports 100 GiB free.
  cat > "$mock_bin/df" <<'MOCKEOF'
#!/bin/sh
# Emulate df -P output: header + one row with plenty of free space
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/mock 200000000 100000000 104857600 51% /nix/store"
MOCKEOF
  chmod +x "$mock_bin/df"

  REPO_DIR="$work"
  mkdir -p "$work/build/.gc-roots"
  # Timestamp: 30 days ago
  thirty_days_ago=$(( $(date -u +%s) - 30 * 86400 ))
  echo "$thirty_days_ago" > "$work/build/.gc-roots/.last-host-gc"

  set +e
  # shellcheck disable=SC1090
  out=$(REPO_DIR="$work" PATH="$mock_bin:$PATH" bash -c "
    set -euo pipefail
    REPO_DIR='$work'
    source '$GC_HELPERS'
    check_store_space 'Test'
  " 2>&1)
  rc=$?
  set -e

  if [[ $rc -eq 0 && "$out" == *"periodic-gc"* && "$out" == *"MOCK: nix-collect-garbage"* ]]; then
    test_pass "periodic-gc trigger fired and invoked nix-collect-garbage"
  else
    test_fail "expected periodic-gc trigger, got rc=${rc}, output: $(echo "$out" | tr '\n' '|')"
  fi

  rm -rf "$work"
fi

# --- Case s472.2: run_host_gc writes the timestamp file ---
test_start "s472.2" "run_host_gc records the timestamp in GC_TIMESTAMP_FILE"
work="$(mktemp -d)"
GC_HELPERS="$work/gc-helpers.sh"
extract_gc_helpers > "$GC_HELPERS"

mock_bin="$work/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/nix-collect-garbage" <<'MOCKEOF'
#!/bin/sh
exit 0
MOCKEOF
chmod +x "$mock_bin/nix-collect-garbage"

before_epoch=$(date -u +%s)
set +e
PATH="$mock_bin:$PATH" bash -c "
  set -euo pipefail
  REPO_DIR='$work'
  source '$GC_HELPERS'
  run_host_gc 'test' >/dev/null 2>&1
" 2>/dev/null
rc=$?
set -e
after_epoch=$(date -u +%s)

ts_file="$work/build/.gc-roots/.last-host-gc"
if [[ $rc -eq 0 && -f "$ts_file" ]]; then
  recorded=$(cat "$ts_file")
  if [[ "$recorded" =~ ^[0-9]+$ ]] && (( recorded >= before_epoch )) && (( recorded <= after_epoch + 5 )); then
    test_pass "run_host_gc recorded a plausible epoch timestamp ($recorded)"
  else
    test_fail "recorded timestamp '${recorded}' outside expected window [${before_epoch}, ${after_epoch}]"
  fi
else
  test_fail "run_host_gc failed (rc=$rc) or GC_TIMESTAMP_FILE not created at ${ts_file}"
fi
rm -rf "$work"

# --- Case s472.3: OK path (plenty of space, recent timestamp) does NOT GC ---
test_start "s472.3" "no GC when free space above threshold and timestamp recent"
work="$(mktemp -d)"
GC_HELPERS="$work/gc-helpers.sh"
extract_gc_helpers > "$GC_HELPERS"

mock_bin="$work/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/nix-collect-garbage" <<'MOCKEOF'
#!/bin/sh
echo "SHOULD_NOT_RUN" >&2
exit 42
MOCKEOF
chmod +x "$mock_bin/nix-collect-garbage"

cat > "$mock_bin/df" <<'MOCKEOF'
#!/bin/sh
# Plenty of free space
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/mock 200000000 100000000 104857600 51% /nix/store"
MOCKEOF
chmod +x "$mock_bin/df"

mkdir -p "$work/build/.gc-roots"
now_epoch=$(date -u +%s)
echo "$now_epoch" > "$work/build/.gc-roots/.last-host-gc"

set +e
out=$(REPO_DIR="$work" PATH="$mock_bin:$PATH" bash -c "
  set -euo pipefail
  REPO_DIR='$work'
  source '$GC_HELPERS'
  check_store_space 'Test'
" 2>&1)
rc=$?
set -e

# Match the specific healthy-path trailer emitted by check_store_space.
# Loose "OK" substring collided with future output — fork sub-claude P2.4.
if [[ $rc -eq 0 && "$out" != *"SHOULD_NOT_RUN"* && "$out" == *"free (threshold:"* && "$out" == *"— OK"* ]]; then
  test_pass "no GC invoked on healthy path (specific trailer matched)"
else
  test_fail "expected no GC on healthy path; rc=${rc}, out=$(echo "$out" | tr '\n' '|')"
fi
rm -rf "$work"

# --- Case s471.1: reset_builder_overlay actually calls check_store_space ---
# Guards against a silent revert of the #471 wiring (fork sub-claude P3.1).
test_start "s471.1" "reset_builder_overlay calls check_store_space 'Post-build' before the qcow2 check"
if grep -q 'check_store_space "Post-build" 8' "$BUILD_ALL_SCRIPT"; then
  test_pass "reset_builder_overlay wired to check_store_space Post-build"
else
  test_fail "reset_builder_overlay no longer calls check_store_space Post-build — #471 wiring reverted"
fi

# --- Case s469.3: NIX_GC_MAX_AGE_DAYS validation refuses non-integers ---
# Guards against codex P2 concern: set -u would otherwise turn a bad
# value into an obscure error deep inside the comparison.
test_start "s469.3" "NIX_GC_MAX_AGE_DAYS=0 or non-integer is rejected"
if grep -q 'NIX_GC_MAX_AGE_DAYS must be a positive integer' "$BUILD_ALL_SCRIPT"; then
  test_pass "validation guard present"
else
  test_fail "no NIX_GC_MAX_AGE_DAYS validation — non-integer input would produce obscure errors"
fi

# --- Case s472.4: gc_age_days treats future timestamps as overdue ---
# Codex P2: bad clock or manual edit could suppress periodic GC for years.
test_start "s472.4" "gc_age_days returns 999 on a future timestamp (clock-skew guard)"
work="$(mktemp -d)"
GC_HELPERS="$work/gc-helpers.sh"
extract_gc_helpers > "$GC_HELPERS"

mock_bin="$work/bin"
mkdir -p "$mock_bin" "$work/build/.gc-roots"
cat > "$mock_bin/nix-collect-garbage" <<'MOCKEOF'
#!/bin/sh
exit 0
MOCKEOF
chmod +x "$mock_bin/nix-collect-garbage"

# Timestamp 1000 years in the future
future_ts=$(( $(date -u +%s) + 1000 * 365 * 86400 ))
echo "$future_ts" > "$work/build/.gc-roots/.last-host-gc"

set +e
age=$(PATH="$mock_bin:$PATH" bash -c "
  set -uo pipefail
  REPO_DIR='$work'
  source '$GC_HELPERS'
  gc_age_days
" 2>&1)
rc=$?
set -e

if [[ $rc -eq 0 && "$age" == "999" ]]; then
  test_pass "future timestamp yields age 999 (overdue)"
else
  test_fail "expected age=999, got age='${age}', rc=${rc}"
fi
rm -rf "$work"

# --- Case s472.5: run_host_gc does NOT record timestamp on GC failure ---
# All three reviewers flagged: "record on failure" hides a broken GC for
# NIX_GC_MAX_AGE_DAYS days.
test_start "s472.5" "run_host_gc leaves timestamp file absent when nix-collect-garbage fails"
work="$(mktemp -d)"
GC_HELPERS="$work/gc-helpers.sh"
extract_gc_helpers > "$GC_HELPERS"

mock_bin="$work/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/nix-collect-garbage" <<'MOCKEOF'
#!/bin/sh
echo "GC boom" >&2
exit 42
MOCKEOF
chmod +x "$mock_bin/nix-collect-garbage"

set +e
PATH="$mock_bin:$PATH" bash -c "
  set -uo pipefail
  REPO_DIR='$work'
  source '$GC_HELPERS'
  run_host_gc 'test' 2>/dev/null
" 2>/dev/null
set -e

ts_file="$work/build/.gc-roots/.last-host-gc"
if [[ ! -e "$ts_file" ]]; then
  test_pass "no timestamp recorded on GC failure — next invocation will retry"
else
  test_fail "GC_TIMESTAMP_FILE was written despite GC failure (would silence periodic GC)"
fi
rm -rf "$work"

# --- Case s413.4: setup-nix-builder caller sites check helper return values ---
# Codex P1: bare `ensure_experimental_features` / `write_machines_file`
# calls would swallow failures. All 8 call sites must be `|| return 1`.
test_start "s413.4" "all callers of ensure_experimental_features / write_machines_file check the return"
# grep -c exits 1 on zero matches under set -e — use || true to capture safely.
bare_calls=$(grep -cE '^  (ensure_experimental_features|write_machines_file)$' "$SETUP_BUILDER_SCRIPT" || true)
if [[ "${bare_calls:-0}" -eq 0 ]]; then
  test_pass "no bare callers found (all 8 sites propagate return)"
else
  test_fail "found ${bare_calls} bare call sites that would swallow non-zero — #413 not end-to-end"
  grep -nE '^  (ensure_experimental_features|write_machines_file)$' "$SETUP_BUILDER_SCRIPT" >&2 || true
fi

# --- Case s413.1: sudo_tee_write returns non-zero when tee fails ---
test_start "s413.1" "sudo_tee_write propagates non-zero when the sudo pipeline fails"
work="$(mktemp -d)"
TEE_HELPERS="$work/tee-helpers.sh"
extract_sudo_tee_helpers > "$TEE_HELPERS"

if ! grep -q 'sudo_tee_write()' "$TEE_HELPERS" || ! grep -q 'sudo_tee_append()' "$TEE_HELPERS"; then
  test_fail "sudo_tee extraction did not include both helpers"
  rm -rf "$work"
else
  # Shim sudo to always fail. Under `set -uo pipefail` the pipe status
  # is the failing right-hand side, so the `if ! ... | sudo tee ...`
  # branch should catch it.
  mock_bin="$work/bin"
  mkdir -p "$mock_bin"
  cat > "$mock_bin/sudo" <<'MOCKEOF'
#!/bin/sh
# Simulate sudo tee failing (e.g., no write permission, wrong password)
exit 1
MOCKEOF
  chmod +x "$mock_bin/sudo"

  set +e
  err=$(PATH="$mock_bin:$PATH" bash -c "
    set -uo pipefail
    source '$TEE_HELPERS'
    sudo_tee_write 'x' '/tmp/mycofu-does-not-matter'
  " 2>&1)
  rc=$?
  set -e

  if [[ $rc -ne 0 && "$err" == *"ERROR: failed to write"* ]]; then
    test_pass "sudo_tee_write returned non-zero and printed the failure diagnostic"
  else
    test_fail "sudo_tee_write did not propagate failure; rc=${rc}, err='${err}'"
  fi
  rm -rf "$work"
fi

# --- Case s413.2: sudo_tee_append also propagates failure ---
test_start "s413.2" "sudo_tee_append propagates non-zero when the sudo pipeline fails"
work="$(mktemp -d)"
TEE_HELPERS="$work/tee-helpers.sh"
extract_sudo_tee_helpers > "$TEE_HELPERS"

mock_bin="$work/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/sudo" <<'MOCKEOF'
#!/bin/sh
exit 1
MOCKEOF
chmod +x "$mock_bin/sudo"

set +e
err=$(PATH="$mock_bin:$PATH" bash -c "
  set -uo pipefail
  source '$TEE_HELPERS'
  sudo_tee_append 'x' '/tmp/mycofu-does-not-matter'
" 2>&1)
rc=$?
set -e

if [[ $rc -ne 0 && "$err" == *"ERROR: failed to append"* ]]; then
  test_pass "sudo_tee_append returned non-zero and printed the failure diagnostic"
else
  test_fail "sudo_tee_append did not propagate failure; rc=${rc}, err='${err}'"
fi
rm -rf "$work"

# --- Case s413.3: sudo_tee_write happy path returns 0 ---
test_start "s413.3" "sudo_tee_write succeeds when sudo pipeline succeeds"
work="$(mktemp -d)"
TEE_HELPERS="$work/tee-helpers.sh"
extract_sudo_tee_helpers > "$TEE_HELPERS"

mock_bin="$work/bin"
mkdir -p "$mock_bin"
# Non-privileged shim that redirects the tee call to a writable path in $work.
cat > "$mock_bin/sudo" <<MOCKEOF
#!/bin/sh
# Strip 'sudo' and run the rest without privileges
exec "\$@"
MOCKEOF
chmod +x "$mock_bin/sudo"

dest="$work/dest.txt"
set +e
out=$(PATH="$mock_bin:$PATH" bash -c "
  set -uo pipefail
  source '$TEE_HELPERS'
  sudo_tee_write 'hello' '$dest'
" 2>&1)
rc=$?
set -e

if [[ $rc -eq 0 && -f "$dest" ]] && grep -q '^hello$' "$dest"; then
  test_pass "sudo_tee_write wrote the content and returned 0"
else
  test_fail "sudo_tee_write happy path failed; rc=${rc}, dest exists=$(test -f "$dest" && echo yes || echo no), out='${out}'"
fi
rm -rf "$work"

runner_summary
