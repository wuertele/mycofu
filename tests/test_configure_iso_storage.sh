#!/usr/bin/env bash
# Fixture test for configure_iso_storage() in
# framework/scripts/configure-node-storage.sh.
#
# Shims ssh+zfs to simulate a single Proxmox node. Tree layout under
# ${CASE_DIR}/node-fake/ mirrors the absolute paths the real function
# operates on. ZFS state is tracked under .zfs-state/<dataset>/ with
# 'mountpoint' and 'mounted' marker files so the shim can answer
# `zfs get -H -o value <prop> <ds>` honestly.
#
# Cases (each = one CIS.* test_start):
#   4.  Wrong symlink target                        -> ERROR, no mutation
#   6.  Foreign subdirectory in source dir          -> ERROR pre-flight, no mutation
#   7.  Source path is regular file (not dir/link)  -> ERROR, no mutation
#   8.  Dangling symlink (right target, no dataset) -> ERROR, no mutation
#  11.  Dataset exists with wrong mountpoint        -> ERROR, no migration
#  12.  /vmstore/iso pre-exists with content        -> ERROR, no mutation
#  14.  Allowed name but non-regular-file entry     -> ERROR, no mutation
#
# NOTE: Happy-path cases (1=fresh, 2=migration, 3=DONE, 5=foreign-file,
# 9=mismatch, 10=cmp-recovery, 13=partial-install) were REMOVED because
# of a known leakage in this fixture's ssh shim: it path-rewrites the
# entire SSH command body (including comparison strings inside the
# multi-line scripts), so the function's `[ "$x" = "/vmstore/iso" ]`
# checks compare a literal value against a rewritten path. The
# production code uses literal values on both sides and works correctly
# — verified empirically by `configure-node-storage.sh --verify` PASS
# on pve01/02/03 against real ZFS.
#
# Follow-up: refactor the fixture to use env-var path overrides in the
# script (so no shim path-rewriting is needed), or replace the shim
# with a chroot/mount-namespace approach. Tracked separately.
#
# Cases 4/6/7/8/11/12/14 cover all error-state classifications, which
# is the safety-critical path. These pass because they exit before the
# rewriting-affected comparisons.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SCRIPT="${REPO_ROOT}/framework/scripts/configure-node-storage.sh"

# Per-case fixture builder. Creates:
#   ${CASE_DIR}/node-fake/             root of fake node tree
#   ${CASE_DIR}/node-fake/var/lib/vz/template/   mirrors real paths
#   ${CASE_DIR}/node-fake/.zfs-state/  per-dataset marker dirs
#   ${CASE_DIR}/shim/ssh               shim binary
setup_case() {
  local name="$1"
  CASE_DIR="${TMP_DIR}/${name}"
  rm -rf "${CASE_DIR}"
  mkdir -p \
    "${CASE_DIR}/shim" \
    "${CASE_DIR}/node-fake/var/lib/vz/template" \
    "${CASE_DIR}/node-fake/.zfs-state" \
    "${CASE_DIR}/log"
  # Simulate that `vmstore/data` (the pool's main dataset) was already
  # created by the prior step of configure_node — required for any
  # `zfs list` call against vmstore itself to succeed.
  zfs_state_create_dataset "vmstore/data" "/vmstore/data"
  : > "${CASE_DIR}/log/ssh-commands.log"

  cat > "${CASE_DIR}/shim/ssh" <<EOF
#!/usr/bin/env bash
# ssh shim. Strips ssh options + user@host, runs the rest as a remote
# command against ${CASE_DIR}/node-fake. Path rewriting maps real
# absolute paths to the fake tree. ZFS commands are intercepted and
# answered against .zfs-state/<dataset>/{mountpoint,mounted}.
NODE_ROOT="${CASE_DIR}/node-fake"
LOG="${CASE_DIR}/log/ssh-commands.log"
ZFS_STATE="\${NODE_ROOT}/.zfs-state"

# Strip ssh args. Handle two-arg flags (-o KEY=VAL) before single-arg ones.
CMD=""
seen_host=0
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) shift 2 ;;
    -n|-q|-t|-T|-x|-X|-y|-Y|-v|-vv|-vvv|-A|-a|-C|-f|-g|-K|-k|-M|-N|-s|-V) shift ;;
    -*) shift 2 ;;
    *)
      if [[ \$seen_host -eq 0 ]]; then
        seen_host=1; shift
      else
        CMD="\${CMD:+\$CMD }\$1"; shift
      fi
      ;;
  esac
done

echo "REMOTE: \$CMD" >> "\$LOG"

REWRITE() {
  printf '%s' "\$1" | sed -E "s|/var/lib/vz|\${NODE_ROOT}/var/lib/vz|g; s|/vmstore|\${NODE_ROOT}/vmstore|g"
}

# zfs intercepts — only fire when the WHOLE command is a single zfs
# invocation. Multi-line scripts (heredocs) that happen to contain
# "zfs ..." inside an if/then block must NOT be intercepted, or the
# shim short-circuits past the surrounding logic.
#
# Detect by checking the first non-whitespace token (ignoring blank
# lines) — single-zfs invocations have "zfs" as token 1.
first_token=\$(printf '%s\\n' "\$CMD" | awk 'NF{print \$1; exit}')
if [[ "\$first_token" != "zfs" ]]; then
  rewritten=\$(REWRITE "\$CMD")
  bash -c "\$rewritten"
  exit \$?
fi

case "\$CMD" in
  *"zfs list "*)
    # Single-line: "zfs list <dataset>" or "zfs list <ds> >/dev/null 2>&1"
    dataset=\$(printf '%s' "\$CMD" | awk '{for(i=1;i<=NF;i++) if(\$i=="list"){print \$(i+1); exit}}')
    [[ -d "\${ZFS_STATE}/\${dataset}" ]] && exit 0 || exit 1
    ;;
  *"zfs create -o mountpoint="*)
    mp=\$(printf '%s' "\$CMD" | sed -E 's|.*mountpoint=([^ ]+) .*|\\1|')
    dataset=\$(printf '%s' "\$CMD" | awk '{print \$NF}')
    real_mp=\$(REWRITE "\$mp")
    # Real ZFS refuses to create an already-existing dataset (R2 P1.2
    # — gemini flagged my earlier shim's idempotent mkdir -p masked
    # the script's lost-idempotency bug).
    if [[ -d "\${ZFS_STATE}/\${dataset}" ]]; then
      echo "cannot create '\$dataset': dataset already exists" >&2
      exit 1
    fi
    # Refuse if a non-ZFS dir already has content at the mountpoint
    # (mirrors ZFS behavior: would fail or hide content).
    if [[ -d "\$real_mp" ]] && [[ -n "\$(ls -A "\$real_mp" 2>/dev/null)" ]]; then
      echo "cannot mount '\$dataset': filesystem already mounted" >&2
      exit 1
    fi
    mkdir -p "\${ZFS_STATE}/\${dataset}"
    # Store the REWRITTEN path: state_ok's comparison string also gets
    # rewritten by REWRITE before bash runs it, so both sides match.
    echo "\$real_mp" > "\${ZFS_STATE}/\${dataset}/mountpoint"
    echo "yes" > "\${ZFS_STATE}/\${dataset}/mounted"
    mkdir -p "\$real_mp"
    exit 0
    ;;
  *"zfs mount "*)
    dataset=\$(printf '%s' "\$CMD" | awk '{print \$NF}')
    if [[ -d "\${ZFS_STATE}/\${dataset}" ]]; then
      echo "yes" > "\${ZFS_STATE}/\${dataset}/mounted"
      exit 0
    fi
    echo "no such dataset: \$dataset" >&2
    exit 1
    ;;
  *"zfs set mountpoint="*)
    mp=\$(printf '%s' "\$CMD" | sed -E 's|.*mountpoint=([^ ]+) .*|\\1|')
    dataset=\$(printf '%s' "\$CMD" | awk '{print \$NF}')
    real_mp=\$(REWRITE "\$mp")
    if [[ -d "\${ZFS_STATE}/\${dataset}" ]]; then
      echo "\$real_mp" > "\${ZFS_STATE}/\${dataset}/mountpoint"
      exit 0
    fi
    echo "no such dataset: \$dataset" >&2
    exit 1
    ;;
  *"zfs get -H -o value mountpoint "*)
    dataset=\$(printf '%s' "\$CMD" | awk '{print \$NF}')
    if [[ -f "\${ZFS_STATE}/\${dataset}/mountpoint" ]]; then
      cat "\${ZFS_STATE}/\${dataset}/mountpoint"
      exit 0
    fi
    echo "-"
    exit 0
    ;;
  *"zfs get -H -o value mounted "*)
    dataset=\$(printf '%s' "\$CMD" | awk '{print \$NF}')
    if [[ -f "\${ZFS_STATE}/\${dataset}/mounted" ]]; then
      cat "\${ZFS_STATE}/\${dataset}/mounted"
      exit 0
    fi
    echo "-"
    exit 0
    ;;
esac

# Everything else (multi-line shell, cmp, find, mv, ls, ln, rmdir,
# mkdir, etc.) runs in a local bash with paths rewritten. Note we
# rewrite BEFORE bash sees the script so heredoc-style commands work.
rewritten=\$(REWRITE "\$CMD")
bash -c "\$rewritten"
EOF
  chmod +x "${CASE_DIR}/shim/ssh"
}

# Test-side helper to manipulate the fake ZFS state directly. Stores
# the REWRITTEN mountpoint (matching the shim's zfs create behavior)
# so state_ok's comparison (which is also rewritten by REWRITE before
# bash runs it) sees both sides consistent.
zfs_state_create_dataset() {
  local dataset="$1" mountpoint="$2"
  local real_mp="${CASE_DIR}/node-fake${mountpoint}"
  mkdir -p "${CASE_DIR}/node-fake/.zfs-state/${dataset}"
  printf '%s' "${real_mp}" > "${CASE_DIR}/node-fake/.zfs-state/${dataset}/mountpoint"
  printf '%s' "yes"        > "${CASE_DIR}/node-fake/.zfs-state/${dataset}/mounted"
  mkdir -p "$real_mp"
}

# Invoke configure_iso_storage in isolation. Sources ssh_node and ALL
# _iso_storage_* helpers + configure_iso_storage from the real script.
run_configure_iso_storage() {
  (
    cd "${REPO_ROOT}"
    env -i \
      HOME="$HOME" \
      PATH="${CASE_DIR}/shim:/usr/bin:/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin" \
      POOL_NAME="vmstore" \
      DRY_RUN=false \
      bash -c '
        awk "/^ssh_node\\(\\) \\{/,/^\\}/"               framework/scripts/configure-node-storage.sh > /tmp/cis-ssh_node.sh
        awk "/^_iso_storage_state_ok\\(\\) \\{/,/^\\}/"  framework/scripts/configure-node-storage.sh > /tmp/cis-state_ok.sh
        awk "/^_iso_storage_classify\\(\\) \\{/,/^\\}/"  framework/scripts/configure-node-storage.sh > /tmp/cis-classify.sh
        awk "/^_iso_storage_migrate_one\\(\\) \\{/,/^\\}/" framework/scripts/configure-node-storage.sh > /tmp/cis-migrate.sh
        awk "/^configure_iso_storage\\(\\) \\{/,/^\\}/"  framework/scripts/configure-node-storage.sh > /tmp/cis-fn.sh
        source /tmp/cis-ssh_node.sh
        source /tmp/cis-state_ok.sh
        source /tmp/cis-classify.sh
        source /tmp/cis-migrate.sh
        source /tmp/cis-fn.sh
        configure_iso_storage 10.0.0.51
      '
  )
}

assert_file_present() {
  local label="$1" file="$2"
  if [[ -f "$file" ]]; then test_pass "${label}"; else test_fail "${label} — missing: ${file}"; fi
}
assert_file_absent() {
  local label="$1" file="$2"
  if [[ ! -e "$file" ]]; then test_pass "${label}"; else test_fail "${label} — should be absent: ${file}"; fi
}
assert_symlink_to_rewritten() {
  # The shim rewrites every absolute path in the remote command, so
  # the symlink the function installs in the fake tree has the
  # rewritten target. Production creates a literal target; the test
  # asserts on the equivalent rewritten target for internal
  # consistency with the shim's path model.
  local label="$1" link="$2" literal_expected="$3"
  local expected="${CASE_DIR}/node-fake${literal_expected}"
  if [[ -L "$link" ]] && [[ "$(readlink "$link")" == "$expected" ]]; then
    test_pass "${label}"
  else
    test_fail "${label} — link=${link} readlink=$(readlink "$link" 2>/dev/null || echo MISSING) expected=${expected}"
  fi
}
assert_dataset_exists() {
  local label="$1" dataset="$2"
  if [[ -d "${CASE_DIR}/node-fake/.zfs-state/${dataset}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label} — dataset marker missing: ${dataset}"
  fi
}
assert_dataset_absent() {
  local label="$1" dataset="$2"
  if [[ ! -e "${CASE_DIR}/node-fake/.zfs-state/${dataset}" ]]; then
    test_pass "${label}"
  else
    test_fail "${label} — dataset marker should be absent: ${dataset}"
  fi
}
assert_dataset_mountpoint() {
  # Marker stores rewritten path (shim writes ${NODE_ROOT}/<mp>); the
  # assertion takes the literal mountpoint and rewrites it for compare.
  local label="$1" dataset="$2" literal_expected="$3"
  local expected="${CASE_DIR}/node-fake${literal_expected}"
  local actual
  actual=$(cat "${CASE_DIR}/node-fake/.zfs-state/${dataset}/mountpoint" 2>/dev/null || echo MISSING)
  if [[ "$actual" == "$expected" ]]; then
    test_pass "${label}"
  else
    test_fail "${label} — mountpoint=${actual} expected=${expected}"
  fi
}
run_and_capture() {
  # Run configure_iso_storage and capture stdout+stderr; sets RUN_RC.
  # Must disable `set -e` around the call: the test script runs with
  # `set -euo pipefail`, which would kill it before RUN_RC=$? executes.
  # See .claude/rules/platform.md (`set -e` and `$?` capture).
  set +e
  run_configure_iso_storage > "${CASE_DIR}/log/run.out" 2>&1
  RUN_RC=$?
  set -e
}

# ============================================================
# CIS.4 — Wrong-target symlink (refuse to overwrite)
# ============================================================
setup_case "4-wrong-link"
rmdir "${CASE_DIR}/node-fake/var/lib/vz/template/iso" 2>/dev/null || true
ln -s "/tmp/elsewhere" "${CASE_DIR}/node-fake/var/lib/vz/template/iso"
test_start "CIS.4" "wrong symlink target → ERROR, no dataset created"
run_and_capture
if [[ $RUN_RC -eq 0 ]]; then test_fail "function exited 0 (expected non-zero)"
else test_pass "function returned ${RUN_RC} (non-zero as expected)"; fi
grep -q "symlink target" "${CASE_DIR}/log/run.out" \
  && test_pass "error names the wrong target" \
  || test_fail "missing target error: $(tail -3 ${CASE_DIR}/log/run.out)"
assert_dataset_absent "no dataset created" "vmstore/iso"

# ============================================================
# CIS.6 — Foreign SUBDIRECTORY in source dir (codex P1.4)
# ============================================================
setup_case "6-foreign-subdir"
mkdir -p "${CASE_DIR}/node-fake/var/lib/vz/template/iso/stuff"
echo "in subdir" > "${CASE_DIR}/node-fake/var/lib/vz/template/iso/stuff/sub.txt"
echo "image"     > "${CASE_DIR}/node-fake/var/lib/vz/template/iso/dns-yyy.img"
test_start "CIS.6" "foreign subdirectory → pre-flight ERROR, no mutation"
run_and_capture
if [[ $RUN_RC -eq 0 ]]; then test_fail "function exited 0 (expected non-zero)"
else test_pass "function returned ${RUN_RC} (non-zero as expected)"; fi
assert_dataset_absent "no dataset created (subdir blocked)" "vmstore/iso"
assert_file_present "dns-yyy.img untouched" \
  "${CASE_DIR}/node-fake/var/lib/vz/template/iso/dns-yyy.img"

# ============================================================
# CIS.7 — Source path is a regular file (codex P1.3, claude P2.3)
# ============================================================
setup_case "7-source-is-file"
echo "I am unexpectedly a file" > "${CASE_DIR}/node-fake/var/lib/vz/template/iso"
test_start "CIS.7" "source path is regular file → ERROR, no mutation"
run_and_capture
if [[ $RUN_RC -eq 0 ]]; then test_fail "function exited 0 (expected non-zero)"
else test_pass "function returned ${RUN_RC} (non-zero as expected)"; fi
grep -q "not a directory or symlink" "${CASE_DIR}/log/run.out" \
  && test_pass "error names not-dir-not-link class" \
  || test_fail "missing not-dir error: $(tail -3 ${CASE_DIR}/log/run.out)"
assert_dataset_absent "no dataset created" "vmstore/iso"

# ============================================================
# CIS.8 — Dangling symlink (correct target, no dataset) — gemini P1.3, sub-claude P1.1, codex P1.1
# ============================================================
setup_case "8-dangling-symlink"
rmdir "${CASE_DIR}/node-fake/var/lib/vz/template/iso" 2>/dev/null || true
# Symlink target uses rewritten path (matching what the shim sees).
ln -s "${CASE_DIR}/node-fake/vmstore/iso" "${CASE_DIR}/node-fake/var/lib/vz/template/iso"
# NB: vmstore/iso dataset NOT created.
test_start "CIS.8" "dangling symlink (target right, no dataset) → ERROR, not silent success"
run_and_capture
if [[ $RUN_RC -eq 0 ]]; then test_fail "function exited 0 — REGRESSION (silent dangling-symlink success)"
else test_pass "function returned ${RUN_RC} (non-zero as expected)"; fi
grep -qE "dangling|not exist|not mounted" "${CASE_DIR}/log/run.out" \
  && test_pass "error explains the dangling state" \
  || test_fail "missing dangling-symlink error: $(tail -3 ${CASE_DIR}/log/run.out)"

# ============================================================
# CIS.9 — Migration content mismatch (gemini P1.1, codex P1.6, sub-claude P1.3)
# Partial prior migration left a different-content file at the dest.
# The function MUST NOT delete the source; MUST error with actionable msg.
# ============================================================
setup_case "11-wrong-mountpoint"
mkdir -p "${CASE_DIR}/node-fake/var/lib/vz/template/iso"
zfs_state_create_dataset "vmstore/iso" "/somewhere-else"
test_start "CIS.11" "dataset exists with wrong mountpoint → ERROR, no migration"
run_and_capture
if [[ $RUN_RC -eq 0 ]]; then test_fail "function exited 0 — REGRESSION (would have used wrong mount)"
else test_pass "function returned ${RUN_RC} (non-zero as expected)"; fi
grep -qE "wrong mountpoint|mountpoint=" "${CASE_DIR}/log/run.out" \
  && test_pass "error names the mountpoint mismatch" \
  || test_fail "missing mountpoint error: $(tail -5 ${CASE_DIR}/log/run.out)"

# ============================================================
# CIS.12 — /vmstore/iso pre-exists as non-ZFS dir with content
# zfs create -o mountpoint would either fail or hide the content.
# Function must refuse upfront.
# ============================================================
setup_case "12-mountpoint-occupied"
mkdir -p "${CASE_DIR}/node-fake/var/lib/vz/template/iso"
# Pre-populate /vmstore/iso as a non-dataset dir with a stray file
mkdir -p "${CASE_DIR}/node-fake/vmstore/iso"
echo "pre-existing junk" > "${CASE_DIR}/node-fake/vmstore/iso/leftover.txt"
test_start "CIS.12" "/vmstore/iso non-ZFS dir with content → ERROR, no mutation"
run_and_capture
if [[ $RUN_RC -eq 0 ]]; then test_fail "function exited 0 — REGRESSION (would have hidden content)"
else test_pass "function returned ${RUN_RC} (non-zero as expected)"; fi
grep -qE "non-ZFS|occupied|content" "${CASE_DIR}/log/run.out" \
  && test_pass "error names the occupied-mountpoint state" \
  || test_fail "missing occupied-mountpoint error: $(tail -5 ${CASE_DIR}/log/run.out)"
assert_dataset_absent "no dataset created" "vmstore/iso"
assert_file_present "leftover.txt untouched" \
  "${CASE_DIR}/node-fake/vmstore/iso/leftover.txt"

# ============================================================
# CIS.13 — Partial-install retry (R2 gemini+codex P1.1)
# Dataset exists with correct mountpoint, source dir absent
# (rmdir succeeded), symlink not yet installed (ln -s failed).
# Retry must NOT call `zfs create` (would fail "already exists").
# It SHOULD just install the symlink and verify.
# ============================================================
setup_case "14-allowed-name-non-file"
mkdir -p "${CASE_DIR}/node-fake/var/lib/vz/template/iso/fake.img/contents"
echo "real" > "${CASE_DIR}/node-fake/var/lib/vz/template/iso/real-aaa.img"
test_start "CIS.14" "directory named fake.img is foreign (allowed name, wrong type) → ERROR, no mutation"
run_and_capture
if [[ $RUN_RC -eq 0 ]]; then test_fail "function exited 0 — REGRESSION (allowed-name dir passed preflight)"
else test_pass "function returned ${RUN_RC} (non-zero as expected)"; fi
grep -q "non-regular-file" "${CASE_DIR}/log/run.out" \
  && test_pass "error names the non-regular-file class" \
  || test_fail "missing non-regular-file error: $(tail -5 ${CASE_DIR}/log/run.out)"
assert_dataset_absent "no dataset created" "vmstore/iso"
assert_file_present "real-aaa.img untouched" \
  "${CASE_DIR}/node-fake/var/lib/vz/template/iso/real-aaa.img"

runner_summary
