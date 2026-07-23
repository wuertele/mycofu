#!/usr/bin/env bash
# tests/test_fio_disk_workdir.sh — covers benchmarks/synthetic/fio.sh
# path_is_on_real_disk() and set_disk_workdir() per #249.
#
# Strategy: copy benchmarks/ to a fixture dir and inject an early exit
# after the top-level `set_disk_workdir` call at the tail of fio.sh, so
# the real script runs its arg-parsing, is_linux check, tool resolution,
# function definitions, trap installation, and set_disk_workdir — but
# exits before actually calling fio. The DISK_WORKDIR global is printed
# so the test can verify which candidate was chosen.
#
# benchmarks/synthetic/fio.sh is NEVER modified — only the fixture
# copy in TMP_DIR is patched.
#
# PATH-front-loaded shims control:
#   - findmnt: returns the FSTYPE for a queried path per a case-specific
#     map file, or exits 1 for unmapped paths (mirroring findmnt's real
#     behavior for paths not under any known mount).
#   - fio: a stub that exits 0 (never invoked; set_disk_workdir exits
#     first) but must exist so require_tool_bin resolves it during
#     fio.sh startup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1" >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
# chmod first so the trap can rm the readonly-override subdir.
trap 'rm -rf "${TMP_DIR}"' EXIT

FIX_DIR="${TMP_DIR}/benchmarks"
cp -R "${REPO_DIR}/benchmarks" "${FIX_DIR}"
FIXTURE_FIO="${FIX_DIR}/synthetic/fio.sh"

# ------------------------------------------------------------------
# Fixture patch: inject an early exit after the top-level
# `set_disk_workdir` invocation. Anchored to the bare-call line (no
# arguments, at column 0), which appears exactly once in fio.sh.
# ------------------------------------------------------------------
awk '
  BEGIN { injected=0 }
  /^set_disk_workdir$/ && !injected {
    print
    print "printf \"__TEST_DISK_WORKDIR=%s\\n\" \"${DISK_WORKDIR:-}\""
    print "printf \"__TEST_DISK_WORKDIR_CREATED_PARENT=%s\\n\" \"${DISK_WORKDIR_CREATED_PARENT:-}\""
    print "if [[ -n \"${DISK_WORKDIR:-}\" && -d \"${DISK_WORKDIR}\" ]]; then"
    print "  printf \"__TEST_DISK_WORKDIR_EXISTED=1\\n\""
    print "else"
    print "  printf \"__TEST_DISK_WORKDIR_EXISTED=0\\n\""
    print "fi"
    print "# Disable the EXIT trap so cleanup does not rm-rf the workdir"
    print "# before the test harness scrapes stdout. Test-only mutation of"
    print "# the fixture copy; benchmarks/synthetic/fio.sh is untouched."
    print "trap - EXIT"
    print "exit 0"
    injected=1
    next
  }
  { print }
' "${FIXTURE_FIO}" > "${FIXTURE_FIO}.new"
mv "${FIXTURE_FIO}.new" "${FIXTURE_FIO}"
chmod +x "${FIXTURE_FIO}"

grep -q '__TEST_DISK_WORKDIR=' "${FIXTURE_FIO}" \
  || fail "fixture prep: early-exit injection did not take effect"

# Verify exactly one injection point (would catch a future rename that
# duplicates the bare call).
# Expect exactly one injection: the two printf lines' regex-anchors
# are unique enough that a duplicate awk match would produce 2 hits.
inject_count="$(grep -c '^printf "__TEST_DISK_WORKDIR=' "${FIXTURE_FIO}")"
[[ "$inject_count" -eq 1 ]] \
  || fail "fixture prep: expected 1 injected printf line, got ${inject_count}"

# ------------------------------------------------------------------
# Shim setup
# ------------------------------------------------------------------
SHIMS="${TMP_DIR}/shims"
mkdir -p "${SHIMS}"

# fio shim — never actually reached (fixture exits after set_disk_workdir)
# but must exist so require_tool_bin resolves it during fio.sh startup.
cat > "${SHIMS}/fio" <<'FIO_SHIM'
#!/usr/bin/env bash
exit 0
FIO_SHIM
chmod +x "${SHIMS}/fio"

# findmnt shim — driven by ${TEST_FINDMNT_MAP} (space-separated
# `<path> <fstype>` per line). Absent mapping → exit 1 (real findmnt's
# behavior for paths not on any known filesystem; fstype_of_path's
# `|| true` swallows it and returns empty, and path_is_on_real_disk
# returns false).
#
# Also handles `findmnt -rn -t tmpfs -o TARGET` (tmpfs listing used by
# tmpfs_target); the test always returns empty so no tmpfs workload
# runs.
cat > "${SHIMS}/findmnt" <<'FINDMNT_SHIM'
#!/usr/bin/env bash
set -u
MAP_FILE="${TEST_FINDMNT_MAP:-}"

target_path=""
list_tmpfs=0
i=1
argv=("$@")
while (( i <= $# )); do
  case "${argv[$((i - 1))]}" in
    -T)
      i=$((i + 1))
      target_path="${argv[$((i - 1))]:-}"
      ;;
    -t)
      i=$((i + 1))
      if [[ "${argv[$((i - 1))]:-}" == "tmpfs" ]]; then
        list_tmpfs=1
      fi
      ;;
  esac
  i=$((i + 1))
done

if [[ "$list_tmpfs" -eq 1 ]]; then
  # Always report no tmpfs mounts. tmpfs_target's awk consumes empty
  # input and prints nothing; fio.sh then skips the tmpfs workload.
  exit 0
fi

if [[ -n "$target_path" && -n "$MAP_FILE" && -f "$MAP_FILE" ]]; then
  fstype="$(awk -v p="$target_path" '$1 == p { print $2; exit }' "$MAP_FILE")"
  if [[ -n "$fstype" ]]; then
    printf '%s\n' "$fstype"
    exit 0
  fi
fi
exit 1
FINDMNT_SHIM
chmod +x "${SHIMS}/findmnt"

# ------------------------------------------------------------------
# Test 1 — BENCH_FIO_DISK_DIR override with writable directory
# ------------------------------------------------------------------
mkdir -p "${TMP_DIR}/operator_override"
: > "${TMP_DIR}/map_empty.txt"
set +e
BENCH_FIO_DISK_DIR="${TMP_DIR}/operator_override" \
  TEST_FINDMNT_MAP="${TMP_DIR}/map_empty.txt" \
  PATH="${SHIMS}:${PATH}" \
  BENCH_UNAME_S=Linux \
  HOME="${TMP_DIR}/fake_home_t1" \
  "${FIXTURE_FIO}" --output "${TMP_DIR}/o1.json" \
  >"${TMP_DIR}/t1.out" 2>&1
rc1=$?
set -e
if [[ "$rc1" -ne 0 ]]; then
  cat "${TMP_DIR}/t1.out" >&2; fail "test 1 (BENCH_FIO_DISK_DIR override, writable): rc=$rc1"
fi
workdir1="$(awk -F= '/^__TEST_DISK_WORKDIR=/ { print $2; exit }' "${TMP_DIR}/t1.out")"
case "$workdir1" in
  "${TMP_DIR}/operator_override/bench-fio."*)
    pass "set_disk_workdir honors writable BENCH_FIO_DISK_DIR operator override"
    ;;
  *)
    fail "test 1: expected DISK_WORKDIR under ${TMP_DIR}/operator_override, got: '$workdir1'"
    ;;
esac
# Verify the injection recorded the workdir as existing BEFORE the
# fixture exited (the fixture's `trap - EXIT` disables cleanup so the
# path also still exists at post-run inspection time).
existed1="$(awk -F= '/^__TEST_DISK_WORKDIR_EXISTED=/ { print $2; exit }' "${TMP_DIR}/t1.out")"
[[ "$existed1" == "1" ]] \
  || fail "test 1: DISK_WORKDIR=$workdir1 was not a directory at set_disk_workdir return"
[[ -d "$workdir1" ]] \
  || fail "test 1: DISK_WORKDIR=$workdir1 no longer exists (cleanup trap fired unexpectedly)"

# ------------------------------------------------------------------
# Test 2 — BENCH_FIO_DISK_DIR override that is not a writable directory
# must die. Uses a non-existent path so the assertion holds under root
# too — `[[ -w /some/chmod-000 ]]` returns true for uid 0, making a
# chmod-000 variant of this test false-pass on CI runners (which run
# as root). The fio.sh guard is `[[ -d && -w ]]` with a fixed die
# message, so a non-existent path exercises the same code path and
# produces the same error text.
# ------------------------------------------------------------------
set +e
BENCH_FIO_DISK_DIR="${TMP_DIR}/does-not-exist-parent/does-not-exist" \
  TEST_FINDMNT_MAP="${TMP_DIR}/map_empty.txt" \
  PATH="${SHIMS}:${PATH}" \
  BENCH_UNAME_S=Linux \
  HOME="${TMP_DIR}/fake_home_t2" \
  "${FIXTURE_FIO}" --output "${TMP_DIR}/o2.json" \
  >"${TMP_DIR}/t2.out" 2>&1
rc2=$?
set -e
if [[ "$rc2" -eq 0 ]]; then
  cat "${TMP_DIR}/t2.out" >&2; fail "test 2: non-existent BENCH_FIO_DISK_DIR should have died (rc=0); log"
fi
if grep -q 'BENCH_FIO_DISK_DIR=' "${TMP_DIR}/t2.out"; then
  pass "set_disk_workdir dies with helpful message when BENCH_FIO_DISK_DIR is not a writable directory (root-safe)"
else
  cat "${TMP_DIR}/t2.out" >&2; fail "test 2: expected error mentioning BENCH_FIO_DISK_DIR, got"
fi

# ------------------------------------------------------------------
# Test 3 — Auto-detect picks a real-disk candidate.
#
# Map HOME to ext4 explicitly. Earlier candidates (/nix/var/bench-tmp
# and /var/tmp) are unmapped → shim exits 1 → path_is_on_real_disk
# returns false → loop advances. HOME wins.
# ------------------------------------------------------------------
mkdir -p "${TMP_DIR}/fake_home_t3"
cat > "${TMP_DIR}/map3.txt" <<EOF_MAP
${TMP_DIR}/fake_home_t3 ext4
EOF_MAP

# On a host that has /nix present, ensure_dir_exists /nix/var/bench-tmp
# would normally succeed as root but fail as a non-root user. We
# short-circuit both by mapping /nix/var/bench-tmp to a rejected fstype
# (its ensure_dir_exists succeed/fail doesn't matter — path_is_on_real_disk
# would still return false due to findmnt shim returning nothing) —
# but the safest belt-and-suspenders is to leave the mapping absent
# and rely on the shim's exit-1 default. We ALSO map /var/tmp absent.

# Additional protection: the test host's /var/tmp is real-disk on a
# typical macOS/Linux workstation. Without shimming it, path_is_on_real_disk
# would accept it. But our findmnt shim returns exit 1 for unmapped
# paths, so /var/tmp evaluates as "no fstype" → rejected. HOME is
# mapped explicitly and chosen.

set +e
TEST_FINDMNT_MAP="${TMP_DIR}/map3.txt" \
  PATH="${SHIMS}:${PATH}" \
  BENCH_UNAME_S=Linux \
  HOME="${TMP_DIR}/fake_home_t3" \
  "${FIXTURE_FIO}" --output "${TMP_DIR}/o3.json" \
  >"${TMP_DIR}/t3.out" 2>&1
rc3=$?
set -e
if [[ "$rc3" -ne 0 ]]; then
  cat "${TMP_DIR}/t3.out" >&2; fail "test 3 (auto-detect real disk on HOME): rc=$rc3"
fi
workdir3="$(awk -F= '/^__TEST_DISK_WORKDIR=/ { print $2; exit }' "${TMP_DIR}/t3.out")"
case "$workdir3" in
  "${TMP_DIR}/fake_home_t3/bench-fio."*)
    pass "set_disk_workdir picks HOME when earlier candidates fail path_is_on_real_disk"
    ;;
  *)
    cat "${TMP_DIR}/t3.out" >&2; fail "test 3: expected DISK_WORKDIR under ${TMP_DIR}/fake_home_t3, got: '$workdir3'; log"
    ;;
esac

# ------------------------------------------------------------------
# Test 4 — All candidates are overlay/tmpfs: die with helpful message.
#
# Every candidate that path_is_on_real_disk would query gets an overlay
# mapping. cd into a fake pwd so PWD is also mapped.
# ------------------------------------------------------------------
mkdir -p "${TMP_DIR}/fake_home_t4" "${TMP_DIR}/fake_pwd_t4"
cat > "${TMP_DIR}/map4.txt" <<EOF_MAP
/nix/var/bench-tmp overlay
/var/tmp overlay
${TMP_DIR}/fake_home_t4 overlay
${TMP_DIR}/fake_pwd_t4 overlay
EOF_MAP

set +e
( cd "${TMP_DIR}/fake_pwd_t4" && \
    TEST_FINDMNT_MAP="${TMP_DIR}/map4.txt" \
    PATH="${SHIMS}:${PATH}" \
    BENCH_UNAME_S=Linux \
    HOME="${TMP_DIR}/fake_home_t4" \
    "${FIXTURE_FIO}" --output "${TMP_DIR}/o4.json" \
    >"${TMP_DIR}/t4.out" 2>&1 )
rc4=$?
set -e
if [[ "$rc4" -eq 0 ]]; then
  cat "${TMP_DIR}/t4.out" >&2; fail "test 4: all-overlay case should have died (rc=0); log"
fi
# Must mention both "real disk" hint and the escape hatch env var so
# operators diagnosing a stuck run see how to override.
if grep -q 'real disk' "${TMP_DIR}/t4.out" && grep -q 'BENCH_FIO_DISK_DIR' "${TMP_DIR}/t4.out"; then
  pass "set_disk_workdir dies with a clear message + escape hatch when all candidates are overlay/tmpfs"
else
  cat "${TMP_DIR}/t4.out" >&2; fail "test 4: expected error mentioning 'real disk' and 'BENCH_FIO_DISK_DIR', got"
fi

# ------------------------------------------------------------------
# Test 5 — path_is_on_real_disk rejects each RAM/network/hypervisor
# fstype the case statement enumerates.
#
# For each fstype known to be rejected, run the fixture with only that
# fstype mapped to HOME and confirm the auto-detect run dies. This
# exercises the case-statement branches individually so a future edit
# that (say) drops `virtiofs` from the reject list is caught here.
# ------------------------------------------------------------------
reject_fstypes=(tmpfs ramfs overlay nfs nfs4 cifs smbfs 9p sshfs virtiofs fuse.virtiofs)
for fstype in "${reject_fstypes[@]}"; do
  mkdir -p "${TMP_DIR}/fake_home_reject" "${TMP_DIR}/fake_pwd_reject"
  cat > "${TMP_DIR}/map_reject.txt" <<EOF_MAP
/nix/var/bench-tmp ${fstype}
/var/tmp ${fstype}
${TMP_DIR}/fake_home_reject ${fstype}
${TMP_DIR}/fake_pwd_reject ${fstype}
EOF_MAP
  set +e
  ( cd "${TMP_DIR}/fake_pwd_reject" && \
      TEST_FINDMNT_MAP="${TMP_DIR}/map_reject.txt" \
      PATH="${SHIMS}:${PATH}" \
      BENCH_UNAME_S=Linux \
      HOME="${TMP_DIR}/fake_home_reject" \
      "${FIXTURE_FIO}" --output "${TMP_DIR}/o_reject.json" \
      >"${TMP_DIR}/t_reject.out" 2>&1 )
  rc=$?
  set -e
  if [[ "$rc" -eq 0 ]]; then
    fail "test 5/${fstype}: path_is_on_real_disk accepted a ${fstype} candidate (should reject)"
  fi
  # Ensure the die was caused by set_disk_workdir's real-disk check,
  # not by some other error path (e.g., a syntax regression). The
  # specific die message is fixed in fio.sh.
  if ! grep -q 'Could not find a writable directory on a real disk' "${TMP_DIR}/t_reject.out"; then
    fail "test 5/${fstype}: rc!=0 but no real-disk die message; got: $(cat "${TMP_DIR}/t_reject.out")"
  fi
done
pass "path_is_on_real_disk rejects every documented RAM/network/hypervisor fstype (${#reject_fstypes[@]} cases; die message verified)"

# ------------------------------------------------------------------
# Test 6 — path_is_on_real_disk accepts each disk fstype the code
# comment enumerates. Same shape as test 5 but positive: pick HOME
# and confirm it's chosen.
# ------------------------------------------------------------------
accept_fstypes=(ext4 xfs btrfs zfs ext3 f2fs)
for fstype in "${accept_fstypes[@]}"; do
  mkdir -p "${TMP_DIR}/fake_home_accept"
  cat > "${TMP_DIR}/map_accept.txt" <<EOF_MAP
${TMP_DIR}/fake_home_accept ${fstype}
EOF_MAP
  set +e
  TEST_FINDMNT_MAP="${TMP_DIR}/map_accept.txt" \
    PATH="${SHIMS}:${PATH}" \
    BENCH_UNAME_S=Linux \
    HOME="${TMP_DIR}/fake_home_accept" \
    "${FIXTURE_FIO}" --output "${TMP_DIR}/o_accept.json" \
    >"${TMP_DIR}/t_accept.out" 2>&1
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    cat "${TMP_DIR}/t_accept.out" >&2; fail "test 6/${fstype}: path_is_on_real_disk rejected a ${fstype} candidate (should accept); log"
  fi
  workdir="$(awk -F= '/^__TEST_DISK_WORKDIR=/ { print $2; exit }' "${TMP_DIR}/t_accept.out")"
  case "$workdir" in
    "${TMP_DIR}/fake_home_accept/bench-fio."*) ;;
    *)
      fail "test 6/${fstype}: DISK_WORKDIR is not under HOME; got '$workdir'"
      ;;
  esac
done
pass "path_is_on_real_disk accepts every documented disk fstype (${#accept_fstypes[@]} cases)"

# ------------------------------------------------------------------
# Test 7 — cicd-style: /var/tmp is overlay, HOME is a real disk.
# Verifies the exact failure mode #249 was filed against: on a host
# whose root fs is overlay-over-tmpfs (cicd), path_is_on_real_disk
# must reject /var/tmp and set_disk_workdir must fall through to a
# real-disk candidate.
# ------------------------------------------------------------------
mkdir -p "${TMP_DIR}/fake_home_cicd"
cat > "${TMP_DIR}/map_cicd.txt" <<EOF_MAP
/var/tmp overlay
${TMP_DIR}/fake_home_cicd ext4
EOF_MAP
set +e
TEST_FINDMNT_MAP="${TMP_DIR}/map_cicd.txt" \
  PATH="${SHIMS}:${PATH}" \
  BENCH_UNAME_S=Linux \
  HOME="${TMP_DIR}/fake_home_cicd" \
  "${FIXTURE_FIO}" --output "${TMP_DIR}/o_cicd.json" \
  >"${TMP_DIR}/t_cicd.out" 2>&1
rc7=$?
set -e
if [[ "$rc7" -ne 0 ]]; then
  cat "${TMP_DIR}/t_cicd.out" >&2; fail "test 7 (cicd-style: /var/tmp overlay + HOME ext4): rc=$rc7"
fi
workdir7="$(awk -F= '/^__TEST_DISK_WORKDIR=/ { print $2; exit }' "${TMP_DIR}/t_cicd.out")"
case "$workdir7" in
  "${TMP_DIR}/fake_home_cicd/bench-fio."*)
    pass "cicd-style host (overlay /var/tmp): set_disk_workdir falls through to HOME real disk"
    ;;
  *)
    fail "test 7: expected DISK_WORKDIR under HOME on cicd-style layout, got: '$workdir7'"
    ;;
esac
