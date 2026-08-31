#!/usr/bin/env bash
# #685 — gitlab-runner nix-store crash-residue sweep hook.
# #738 — gitlab-runner service-level secret prerequisite guard.
#
# Asserts (static ratchet) that gitlab-runner.service carries the store-verify
# hook as ExecStartPre and that the pass is structural-only, and exercises
# (behavioral) the two outcomes of the standalone script: clean store starts
# cleanly, and a non-zero verify starts-with-alarm (exit 0 + loud WARNING) so
# the runner is never trapped in a Restart=on-failure loop.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
MODULE="${REPO_ROOT}/framework/nix/modules/gitlab-runner.nix"
SCRIPT="${REPO_ROOT}/framework/nix/modules/gitlab-runner-store-verify.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# --- Static ratchet: the unit wires both pre-start hooks as ExecStartPre ---
test -f "$SCRIPT" || fail "store-verify script missing at $SCRIPT"
grep -q 'runnerStoreVerifyScript' "$MODULE" \
  || fail "module does not define runnerStoreVerifyScript"
grep -q 'runnerSecretPrereqScript' "$MODULE" \
  || fail "module does not define runnerSecretPrereqScript"
grep -Eq 'ExecStartPre[[:space:]]*=[[:space:]]*\[[^]]*runnerSecretPrereqScript[^]]*runnerStoreVerifyScript[^]]*\]' "$MODULE" \
  || fail "gitlab-runner.service does not wire secret-prereq and store-verify hooks as ExecStartPre"
grep -q '/var/lib/mycofu-secrets/age-key' "$MODULE" \
  || fail "secret-prereq hook does not assert the persistent age-key path"
grep -q '/var/lib/mycofu-secrets/framework-deploy-ssh-privkey' "$MODULE" \
  || fail "secret-prereq hook does not assert the framework deploy ssh-privkey path"
# Nix multi-line strings escape shell $var references as ''${var}, so the
# module reads `stat -f -c %T "''${path}"` — match the semantic invocation
# regardless of the nix-escape form.
grep -q 'stat -f -c %T' "$MODULE" \
  || fail "secret-prereq hook does not assert non-ephemeral filesystem backing"
# Anchor to the ACTUAL invocation line (wrapped in `timeout`), not a token pair —
# this asserts nix-store --verify --repair runs AND is time-bounded in one match,
# and is robust to prose/log lines that also name the command (sub-claude P3).
verify_invocation="$(grep -E 'timeout.*nix-store[[:space:]]+--verify[[:space:]]+--repair' "$SCRIPT")" \
  || fail "script does not run a time-bounded 'nix-store --verify --repair'"
# Structural-only: full content hashing of a ~150 GB store at every start is
# prohibitive. The actual invocation must not carry --check-contents (prose that
# explains the omission may still name the flag).
case "$verify_invocation" in
  *--check-contents*) fail "the nix-store --verify invocation uses --check-contents (prohibitive full hashing at every start)" ;;
esac
ok "unit wires secret-prereq and store-verify ExecStartPre hooks; store verify is structural and time-bounded"

# --- Static ratchet: the SYSTEMD-level non-blocking guarantee (unanimous P1) ---
# ExecStartPre time counts against the unit start timeout; an unbounded verify
# SIGKILLed past it would loop the runner (tier-2 dark). Assert (via nix eval,
# when nix is available) that ExecStartPre is wired and TimeoutStartSec exceeds
# the script's internal bound so systemd never kills the pass first.
if command -v nix >/dev/null 2>&1; then
  FLAKE="$REPO_ROOT"
  espre="$(nix eval --json "${FLAKE}#nixosConfigurations.cicd.config.systemd.services.gitlab-runner.serviceConfig.ExecStartPre" 2>/dev/null || true)"
  if [[ -z "$espre" ]]; then
    echo "ok - (skipped nix-eval ratchet: nix eval returned no serviceConfig)"
  else
    case "$espre" in
      *gitlab-runner-secret-prereqs*gitlab-runner-store-verify*) ok "evaluated gitlab-runner.service ExecStartPre resolves to both pre-start hooks" ;;
      *) fail "evaluated gitlab-runner.service ExecStartPre is not the expected hook list: '$espre'" ;;
    esac
    tstart="$(nix eval --raw "${FLAKE}#nixosConfigurations.cicd.config.systemd.services.gitlab-runner.serviceConfig.TimeoutStartSec" 2>/dev/null || true)"
    tnum="${tstart%%s}"; tnum="${tnum//[!0-9]/}"
    [[ "$tnum" =~ ^[0-9]+$ ]] || fail "gitlab-runner.service has no numeric TimeoutStartSec (got '$tstart') — an unbounded ExecStartPre can loop the runner"
    [[ "$tnum" -ge 360 ]] || fail "TimeoutStartSec ${tnum}s is too tight above the 300s internal verify bound (need margin so systemd never SIGKILLs the pass)"
    ok "gitlab-runner.service TimeoutStartSec=${tstart} exceeds the 300s internal verify bound"
  fi
else
  echo "ok - (skipped nix-eval ratchet: nix not on PATH)"
fi

# --- Behavioral: fake nix-store on PATH drives the two outcomes ---
TMP="$(mktemp -d "${TMPDIR:-/tmp}/store-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
make_fake_nix_store() { # $1 = exit code the fake should return
  cat > "$TMP/bin/nix-store" <<EOF
#!/usr/bin/env bash
echo "fake nix-store \$*" >&2
exit $1
EOF
  chmod +x "$TMP/bin/nix-store"
}

# Clean store (verify rc=0): exit 0, logs consistency.
make_fake_nix_store 0
out0="$TMP/out0"
PATH="$TMP/bin:$PATH" bash "$SCRIPT" >"$out0" 2>&1 && rc0=0 || rc0=$?
[[ "$rc0" -eq 0 ]] || fail "clean-store run did not exit 0 (got $rc0)"
grep -qi 'store consistent' "$out0" || fail "clean-store run did not log the consistent path"
ok "clean store: exit 0, logs consistency"

# Verify errors (rc!=0): start-with-alarm — exit 0 AND a loud WARNING.
make_fake_nix_store 3
out3="$TMP/out3"
PATH="$TMP/bin:$PATH" bash "$SCRIPT" >"$out3" 2>&1 && rc3=0 || rc3=$?
[[ "$rc3" -eq 0 ]] || fail "verify-error run must still exit 0 (start-with-alarm), got $rc3"
grep -q 'WARNING' "$out3" || fail "verify-error run did not log a loud WARNING (start-with-alarm)"
grep -qi 'starting runner anyway' "$out3" \
  || fail "verify-error run did not announce start-with-alarm"
ok "verify error: start-with-alarm (exit 0 + loud WARNING)"

# Verify times out (rc=124, as `timeout` returns): start-with-alarm — exit 0 AND
# a WARNING that names the bound. This is the systemd-timeout hole's script-level
# counterpart: even a pass that blows its budget must not block start.
make_fake_nix_store 124
out124="$TMP/out124"
PATH="$TMP/bin:$PATH" bash "$SCRIPT" >"$out124" 2>&1 && rc124=0 || rc124=$?
[[ "$rc124" -eq 0 ]] || fail "timeout run must still exit 0 (start-with-alarm), got $rc124"
grep -qi 'bounded' "$out124" || fail "timeout run did not report the pass was bounded"
grep -qi 'starting runner anyway' "$out124" || fail "timeout run did not announce start-with-alarm"
ok "verify timeout (rc=124): start-with-alarm (exit 0 + bounded WARNING)"

echo "all tests passed"
