#!/usr/bin/env bash
# Verifies that validate-step2.sh guards the two `yq -r` values it
# interpolates into the operator-facing V2.5 here-doc against yq's
# null-with-exit-0 behavior on missing keys (issue #630). A missing
# environments.prod.vlan_id or domain must fail loudly with an ERROR
# naming the key — never print "(currently null)" or "prod.null" into
# instructions the operator might paste.
#
# The V2.5 MANUAL block runs unconditionally (V2.5 always sets MANUAL=1),
# so the fixture only needs V2.1 to skip its nix build (a sparse >500M
# result/*.qcow2), a stub tofu-wrapper.sh for V2.3, and a stub ssh for
# V2.2; V2.4 fails (no secrets) — the MANUAL block still executes before
# the final FAIL exit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

REAL_SCRIPT="${REPO_ROOT}/framework/scripts/validate-step2.sh"

# Cleanup registry. setup_fixture is called via command substitution
# (tmp="$(setup_fixture ...)"), which runs in a SUBSHELL — so it cannot
# register its own dir in the parent; the CALLER appends to _FIXTURE_DIRS
# after capturing the path. OUT/ERR are assigned later. The single EXIT
# trap below must be set-e-proof: a failing command as the trap's last
# action would override the script's real exit status under `set -e`
# (see .claude/rules/platform.md — set-e in cleanup paths). The trailing
# `return 0` guarantees the trap ends on success and preserves the exit code.
_FIXTURE_DIRS=()
OUT=""
ERR=""
cleanup() {
  local d
  for d in "${_FIXTURE_DIRS[@]:-}"; do
    [[ -n "$d" ]] && rm -rf "$d"
  done
  [[ -n "$OUT" ]] && rm -f "$OUT"
  [[ -n "$ERR" ]] && rm -f "$ERR"
  return 0
}
trap cleanup EXIT

# setup_fixture <config_body> — build a self-contained tree that reaches
# the V2.5 here-doc without a live cluster, with the caller-supplied
# site/config.yaml body. Echoes the fixture root path; the caller must
# append that path to _FIXTURE_DIRS (this runs in a subshell).
setup_fixture() {
  local config_body="$1"
  local tmp
  tmp="$(mktemp -d)"

  mkdir -p "$tmp/framework/scripts" "$tmp/site" "$tmp/result" "$tmp/bin"

  cp "$REAL_SCRIPT" "$tmp/framework/scripts/validate-step2.sh"
  chmod +x "$tmp/framework/scripts/validate-step2.sh"

  # Stub tofu-wrapper.sh so V2.3 fails fast instead of running real tofu.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$tmp/framework/scripts/tofu-wrapper.sh"
  chmod +x "$tmp/framework/scripts/tofu-wrapper.sh"

  # Stub ssh so V2.2 returns immediately instead of a real (slow) TCP
  # connect + timeout. Its exit status/output do not affect what these
  # cases assert (the V2.5 here-doc runs regardless of V2.1–V2.4 results).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/ssh"
  chmod +x "$tmp/bin/ssh"

  # Sparse >500 MiB qcow2 so V2.1 takes the "recent build exists" branch
  # and never invokes `nix build`. bs=1 seek keeps it portable (no
  # truncate on macOS); count=0 writes no data (sparse, zero disk use).
  dd if=/dev/zero of="$tmp/result/base.qcow2" bs=1 count=0 seek=629145600 \
    >/dev/null 2>&1

  printf '%s' "$config_body" > "$tmp/site/config.yaml"

  printf '%s' "$tmp"
}

# run_step2 <tmp> <out_file> <err_file> — run the fixture script, writing
# stdout and stderr to the two given files; echoes the exit code. Keeping
# the streams in separate files avoids any regex demultiplexing that a
# stderr banner could break.
run_step2() {
  local tmp="$1" out_file="$2" err_file="$3" rc
  set +e
  ( cd "$tmp" && PATH="$tmp/bin:$PATH" "$tmp/framework/scripts/validate-step2.sh" ) \
    >"$out_file" 2>"$err_file"
  rc=$?
  set -e
  printf '%s' "$rc"
}

# A config that reaches V2.5; environments.prod / domain are appended
# per-case. nodes[0] is present so V2.2's config reads succeed (ssh is
# stubbed, so the address value itself is irrelevant).
BASE_CONFIG='proxmox:
  image_storage_path: /var/lib/vz/template/iso
nodes:
  - name: pve01
    mgmt_ip: 192.0.2.1
nas:
  ip: 192.0.2.2
  postgres_port: 5432
'

OUT="$(mktemp)"; ERR="$(mktemp)"

# --- Case 1: environments.prod.vlan_id missing → fail loudly, no "null".
test_start "630.1" "missing environments.prod.vlan_id fails loudly, no 'null' leak"
tmp="$(setup_fixture "${BASE_CONFIG}domain: wuertele.com"$'\n')"; _FIXTURE_DIRS+=("$tmp")
rc="$(run_step2 "$tmp" "$OUT" "$ERR")"
stdout="$(cat "$OUT")"; stderr="$(cat "$ERR")"
if [[ "$rc" -ne 0 \
      && "$stderr" == *"environments.prod.vlan_id not set"* \
      && "$stdout" != *"currently null"* ]]; then
  test_pass "aborts with ERROR naming the key; no '(currently null)' in instructions"
else
  test_fail "missing vlan_id not guarded (rc=$rc)"
  { echo "STDOUT:"; echo "$stdout"; echo "STDERR:"; echo "$stderr"; } | sed 's/^/    /' >&2
fi

# --- Case 2: domain missing → fail loudly, no "prod.null".
test_start "630.2" "missing domain fails loudly, no 'prod.null' leak"
tmp="$(setup_fixture "${BASE_CONFIG}"$'environments:\n  prod:\n    vlan_id: 10\n')"; _FIXTURE_DIRS+=("$tmp")
rc="$(run_step2 "$tmp" "$OUT" "$ERR")"
stdout="$(cat "$OUT")"; stderr="$(cat "$ERR")"
if [[ "$rc" -ne 0 \
      && "$stderr" == *"domain not set"* \
      && "$stdout" != *"prod.null"* ]]; then
  test_pass "aborts with ERROR naming the key; no 'prod.null' in instructions"
else
  test_fail "missing domain not guarded (rc=$rc)"
  { echo "STDOUT:"; echo "$stdout"; echo "STDERR:"; echo "$stderr"; } | sed 's/^/    /' >&2
fi

# --- Case 3: both keys present → instructions render real values, no
# guard error. (The script still exits 1 from the failing V2.3/V2.4
# checks in this fixture; that is expected and not what this case asserts
# — the assertion is on the rendered here-doc content.)
test_start "630.3" "both keys present render real values into the here-doc"
tmp="$(setup_fixture "${BASE_CONFIG}domain: wuertele.com"$'\nenvironments:\n  prod:\n    vlan_id: 10\n')"; _FIXTURE_DIRS+=("$tmp")
run_step2 "$tmp" "$OUT" "$ERR" >/dev/null
stdout="$(cat "$OUT")"; stderr="$(cat "$ERR")"
if [[ "$stdout" == *"currently 10"* \
      && "$stdout" == *"prod.wuertele.com"* \
      && "$stderr" != *"not set"* \
      && "$stdout" != *"null"* ]]; then
  test_pass "here-doc shows '(currently 10)' and 'prod.wuertele.com', no null, no guard error"
else
  test_fail "valid config did not render real values cleanly"
  { echo "STDOUT:"; echo "$stdout"; echo "STDERR:"; echo "$stderr"; } | sed 's/^/    /' >&2
fi

# ---------------------------------------------------------------------------
# Issue #698 — the same yq null-with-exit-0 class in the V2.2 and V2.4
# CHECK inputs (not just the V2.5 here-doc #630 covered).
#
# These are sharper than #630's: a null here does not merely print an ugly
# string into pasteable instructions, it makes a validation gate emit a
# DEFINITE verdict from an INDETERMINATE input — `root@null` for V2.2,
# `psql -h null -p null` for V2.4, whose connection error the psql line's
# `2>/dev/null || echo "0"` converts into "prod schema not found". Per
# .claude/rules/destruction-safety.md a check that cannot determine its
# answer must FAIL loudly, never report one.
#
# Each case asserts the guard fires BEFORE the probe it protects runs, so
# the fixture needs no live cluster.
# ---------------------------------------------------------------------------

# Config pieces. FULL_* is a complete, valid config; each case omits
# exactly one key so the assertion isolates that key's guard.
NODES_OK=$'nodes:\n  - name: pve01\n    mgmt_ip: 192.0.2.1\n'
NAS_OK=$'nas:\n  ip: 192.0.2.2\n  postgres_port: 5432\n'
TAIL_OK=$'domain: wuertele.com\nenvironments:\n  prod:\n    vlan_id: 10\n'
PROXMOX_OK=$'proxmox:\n  image_storage_path: /var/lib/vz/template/iso\n'

# --- Case 698.1: nodes[0].mgmt_ip missing → V2.2 aborts before ssh.
test_start "698.1" "missing nodes[0].mgmt_ip fails loudly, never probes root@null"
tmp="$(setup_fixture "${PROXMOX_OK}"$'nodes:\n  - name: pve01\n'"${NAS_OK}${TAIL_OK}")"
_FIXTURE_DIRS+=("$tmp")
rc="$(run_step2 "$tmp" "$OUT" "$ERR")"
stdout="$(cat "$OUT")"; stderr="$(cat "$ERR")"
if [[ "$rc" -ne 0 \
      && "$stderr" == *"nodes[0].mgmt_ip not set"* \
      && "$stdout" != *"V2.2"* ]]; then
  test_pass "aborts naming nodes[0].mgmt_ip; no V2.2 verdict emitted"
else
  test_fail "missing nodes[0].mgmt_ip not guarded (rc=$rc)"
  { echo "STDOUT:"; echo "$stdout"; echo "STDERR:"; echo "$stderr"; } | sed 's/^/    /' >&2
fi

# --- Case 698.2: nodes[0].name missing → V2.2 aborts before ssh.
test_start "698.2" "missing nodes[0].name fails loudly, no 'null' in a V2.2 verdict"
tmp="$(setup_fixture "${PROXMOX_OK}"$'nodes:\n  - mgmt_ip: 192.0.2.1\n'"${NAS_OK}${TAIL_OK}")"
_FIXTURE_DIRS+=("$tmp")
rc="$(run_step2 "$tmp" "$OUT" "$ERR")"
stdout="$(cat "$OUT")"; stderr="$(cat "$ERR")"
if [[ "$rc" -ne 0 \
      && "$stderr" == *"nodes[0].name not set"* \
      && "$stdout" != *"V2.2"* ]]; then
  test_pass "aborts naming nodes[0].name; no V2.2 verdict emitted"
else
  test_fail "missing nodes[0].name not guarded (rc=$rc)"
  { echo "STDOUT:"; echo "$stdout"; echo "STDERR:"; echo "$stderr"; } | sed 's/^/    /' >&2
fi

# enable_v24_path <tmp> — make the fixture REACH the V2.4 psql probe.
#
# Without this, V2.4 short-circuits at `[[ -f "$SECRETS_FILE" ]] && command -v
# sops` and reports "cannot decrypt secrets or sops not found" — so a test
# would prove only that the guard aborts, never that it aborted INSTEAD OF
# the misleading "prod schema not found" verdict the null actually produced
# (R-G-4: a fixture must exercise the path the fix's claim depends on).
#
# The psql stub records its argv and exits 1, reproducing what a real
# connection to host "null" does. That failure is swallowed by the script's
# own `2>/dev/null || echo "0"`, which is precisely the mechanism that turned
# an unreachable host into a specific claim about the state backend.
enable_v24_path() {
  local tmp="$1"
  mkdir -p "$tmp/site/sops"
  printf 'tofu_db_password: fixture\n' > "$tmp/site/sops/secrets.yaml"
  printf '#!/usr/bin/env bash\nprintf %%s "{\\"tofu_db_password\\":\\"fixture\\"}"\n' \
    > "$tmp/bin/sops"
  cat > "$tmp/bin/psql" <<'PSQLSHIM'
#!/usr/bin/env bash
echo "$*" >> "${PSQL_ARGV_LOG}"
# Exit non-zero like a real connection failure. When the host/port are valid
# the caller sets PSQL_SCHEMA_COUNT to emit a row instead.
if [[ -n "${PSQL_SCHEMA_COUNT:-}" ]]; then
  echo "${PSQL_SCHEMA_COUNT}"
  exit 0
fi
exit 2
PSQLSHIM
  chmod +x "$tmp/bin/sops" "$tmp/bin/psql"
}

# --- Case 698.3: nas.ip missing → V2.4 aborts, and psql is never reached.
# V2.2 must still PASS here (nodes are present, ssh is stubbed), which proves
# the abort came from the V2.4 guard and not from an earlier one. The psql
# log being empty is the load-bearing assertion: pre-fix the same fixture
# invokes `psql -h null -p 5432` and prints a V2.4 verdict.
test_start "698.3" "missing nas.ip aborts without ever invoking the psql probe"
tmp="$(setup_fixture "${PROXMOX_OK}${NODES_OK}"$'nas:\n  postgres_port: 5432\n'"${TAIL_OK}")"
_FIXTURE_DIRS+=("$tmp")
enable_v24_path "$tmp"
PSQL_ARGV_LOG="$tmp/psql-argv.log"; : > "$PSQL_ARGV_LOG"; export PSQL_ARGV_LOG
rc="$(run_step2 "$tmp" "$OUT" "$ERR")"
unset PSQL_ARGV_LOG
stdout="$(cat "$OUT")"; stderr="$(cat "$ERR")"
psql_calls=$(wc -l < "$tmp/psql-argv.log" | tr -d ' ')
if [[ "$rc" -ne 0 \
      && "$stderr" == *"nas.ip not set"* \
      && "$stdout" == *"V2.2"* \
      && "$stdout" != *"V2.4"* \
      && "$psql_calls" -eq 0 ]]; then
  test_pass "aborts naming nas.ip after V2.2 ran; psql never invoked, no V2.4 verdict"
else
  test_fail "missing nas.ip not guarded (rc=$rc psql_calls=$psql_calls)"
  { echo "STDOUT:"; echo "$stdout"; echo "STDERR:"; echo "$stderr";
    echo "PSQL:"; cat "$tmp/psql-argv.log"; } | sed 's/^/    /' >&2
fi

# --- Case 698.4: nas.postgres_port missing → same, on the port key.
test_start "698.4" "missing nas.postgres_port aborts without invoking the psql probe"
tmp="$(setup_fixture "${PROXMOX_OK}${NODES_OK}"$'nas:\n  ip: 192.0.2.2\n'"${TAIL_OK}")"
_FIXTURE_DIRS+=("$tmp")
enable_v24_path "$tmp"
PSQL_ARGV_LOG="$tmp/psql-argv.log"; : > "$PSQL_ARGV_LOG"; export PSQL_ARGV_LOG
rc="$(run_step2 "$tmp" "$OUT" "$ERR")"
unset PSQL_ARGV_LOG
stdout="$(cat "$OUT")"; stderr="$(cat "$ERR")"
psql_calls=$(wc -l < "$tmp/psql-argv.log" | tr -d ' ')
if [[ "$rc" -ne 0 \
      && "$stderr" == *"nas.postgres_port not set"* \
      && "$stdout" != *"V2.4"* \
      && "$psql_calls" -eq 0 ]]; then
  test_pass "aborts naming nas.postgres_port; psql never invoked, no V2.4 verdict"
else
  test_fail "missing nas.postgres_port not guarded (rc=$rc psql_calls=$psql_calls)"
  { echo "STDOUT:"; echo "$stdout"; echo "STDERR:"; echo "$stderr";
    echo "PSQL:"; cat "$tmp/psql-argv.log"; } | sed 's/^/    /' >&2
fi

# --- Case 698.4b: positive control — a COMPLETE nas block still reaches psql
# with the real values and still produces a V2.4 verdict.
#
# This is what makes 698.3/698.4's "psql never invoked" meaningful: it proves
# the fixture genuinely can reach the probe, so an empty psql log in those
# cases is the guard working rather than the fixture never getting there.
test_start "698.4b" "complete nas block reaches psql with real host/port and yields V2.4 PASS"
tmp="$(setup_fixture "${PROXMOX_OK}${NODES_OK}${NAS_OK}${TAIL_OK}")"
_FIXTURE_DIRS+=("$tmp")
enable_v24_path "$tmp"
PSQL_ARGV_LOG="$tmp/psql-argv.log"; : > "$PSQL_ARGV_LOG"
export PSQL_ARGV_LOG PSQL_SCHEMA_COUNT=1
run_step2 "$tmp" "$OUT" "$ERR" >/dev/null
unset PSQL_ARGV_LOG PSQL_SCHEMA_COUNT
stdout="$(cat "$OUT")"; stderr="$(cat "$ERR")"
psql_args="$(cat "$tmp/psql-argv.log")"
# The exact `-h`/`-p` values are the whole assertion. A broader
# `$psql_args != *null*` clause was deliberately NOT used: it would add
# nothing (a real value is already proven) while being able to fire on a
# future argument that merely contains the substring — a check that can go
# red on coincidence is worse than no check (design-taste Principle 11(c)).
if [[ "$psql_args" == *"-h 192.0.2.2"* \
      && "$psql_args" == *"-p 5432"* \
      && "$stdout" == *"V2.4"* \
      && "$stderr" != *"not set"* ]]; then
  test_pass "psql invoked with -h 192.0.2.2 -p 5432; V2.4 verdict emitted, no guard error"
else
  test_fail "valid nas block did not reach psql cleanly"
  { echo "STDOUT:"; echo "$stdout"; echo "STDERR:"; echo "$stderr";
    echo "PSQL:"; echo "$psql_args"; } | sed 's/^/    /' >&2
fi

# --- Case 698.5: BOTH V2.2 ssh calls carry BatchMode + ConnectTimeout.
#
# The probe on the `if` line always had them; the follow-up call that reads
# the filename back did not. Without BatchMode that second ssh can block on
# an interactive password/passphrase prompt, and without ConnectTimeout it
# inherits the OS default (~2 min) — hanging the gate AFTER the probe has
# already proved the host reachable.
#
# This asserts on the argv the script actually passes to ssh (a recording
# shim), not on the source text, so it cannot be satisfied by a comment and
# does not fire when unrelated lines move.
test_start "698.5" "both V2.2 ssh calls pass -o BatchMode=yes and -o ConnectTimeout"
tmp="$(setup_fixture "${PROXMOX_OK}${NODES_OK}${NAS_OK}${TAIL_OK}")"
_FIXTURE_DIRS+=("$tmp")
# Replace the plain stub with one that records each invocation's full argv
# on one line, then succeeds so the second ssh is reached.
cat > "$tmp/bin/ssh" <<'SSHSHIM'
#!/usr/bin/env bash
echo "$*" >> "${SSH_ARGV_LOG}"
exit 0
SSHSHIM
chmod +x "$tmp/bin/ssh"
SSH_ARGV_LOG="$tmp/ssh-argv.log"; : > "$SSH_ARGV_LOG"
export SSH_ARGV_LOG
run_step2 "$tmp" "$OUT" "$ERR" >/dev/null
unset SSH_ARGV_LOG
ssh_calls=$(wc -l < "$tmp/ssh-argv.log" | tr -d ' ')
# `grep -vc` already PRINTS "0" when nothing is non-matching and then exits
# 1; a `|| echo 0` fallback would append a second line and break the
# arithmetic test below. `|| true` keeps grep's own count and swallows only
# the exit status.
unguarded=$(grep -vc 'BatchMode=yes' "$tmp/ssh-argv.log" || true)
untimed=$(grep -vc 'ConnectTimeout=' "$tmp/ssh-argv.log" || true)
if [[ "$ssh_calls" -eq 2 && "$unguarded" -eq 0 && "$untimed" -eq 0 ]]; then
  test_pass "both ssh invocations carry BatchMode=yes and ConnectTimeout"
else
  test_fail "ssh bounds missing (calls=$ssh_calls without-BatchMode=$unguarded without-ConnectTimeout=$untimed)"
  sed 's/^/    /' "$tmp/ssh-argv.log" >&2
fi

runner_summary
