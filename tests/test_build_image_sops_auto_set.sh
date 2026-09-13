#!/usr/bin/env bash
# Verifies that build-image.sh auto-sets SOPS_AGE_KEY_FILE the same way
# the other framework scripts do (issue #550). Two cases:
#
# 1. When operator.age.key exists at the repo root, SOPS_AGE_KEY_FILE is
#    set to that path.
# 2. When operator.age.key is absent, SOPS_AGE_KEY_FILE falls back to the
#    XDG-standard $XDG_CONFIG_HOME/sops/age/keys.txt (or ~/.config/... if
#    XDG_CONFIG_HOME is unset).
# 3. When SOPS_AGE_KEY_FILE is already set, it is not overwritten.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

REAL_BUILD_IMAGE="${REPO_ROOT}/framework/scripts/build-image.sh"

# setup_fixture <has_operator_key>
#
# Builds a self-contained tree; caller controls whether the fake repo
# root has an operator.age.key file. The nix_builder.type is `bogus` so
# the script exits at the "Unknown nix_builder.type" case just after
# reaching the point that would consume SOPS_AGE_KEY_FILE.
setup_fixture() {
  local has_key="$1"
  local tmp
  tmp="$(mktemp -d)"

  mkdir -p "$tmp/framework/scripts" "$tmp/site/nix/hosts" "$tmp/site/hil/sops"

  cp "$REAL_BUILD_IMAGE" "$tmp/framework/scripts/build-image.sh"
  chmod +x "$tmp/framework/scripts/build-image.sh"

  # Shim helper that echoes the SOPS_AGE_KEY_FILE it sees to a file the
  # test can inspect. Exit non-zero so the script fails before it tries
  # to actually build. The path is passed via an env var so the fixture
  # can put it in the shim's environment.
  cat > "$tmp/framework/scripts/hil-boot-secret-env.sh" <<'SHIM'
#!/usr/bin/env bash
printf '%s' "${SOPS_AGE_KEY_FILE:-<unset>}" > "${SOPS_CAPTURE_FILE}"
echo "shim exiting non-zero to short-circuit" >&2
exit 2
SHIM
  chmod +x "$tmp/framework/scripts/hil-boot-secret-env.sh"

  cat > "$tmp/site/config.yaml" <<CFG
domain: test.example
nix_builder:
  type: bogus
nodes: []
CFG

  cat > "$tmp/site/images.yaml" <<'YML'
roles:
  testrole:
    build_secret_config: site/hil/config.yaml
    build_secret_ref: proxmox_api_password
YML

  echo "{}" > "$tmp/site/nix/hosts/testrole.nix"
  echo "domain: fixture" > "$tmp/site/hil/config.yaml"
  echo "encrypted" > "$tmp/site/hil/sops/secrets.yaml"

  if [[ "$has_key" == "1" ]]; then
    printf '%s\n' 'AGE-KEY-FIXTURE-CONTENT' > "$tmp/operator.age.key"
  fi

  printf '%s' "$tmp"
}

# --- Case 1: SOPS_AGE_KEY_FILE unset, operator.age.key exists -> auto-set to repo key.
test_start "550.1" "auto-sets to \${REPO_DIR}/operator.age.key when present"
tmp="$(setup_fixture 1)"
capture="$(mktemp)"
set +e
( cd "$tmp" && unset SOPS_AGE_KEY_FILE && \
  SOPS_CAPTURE_FILE="$capture" "$tmp/framework/scripts/build-image.sh" --dev \
  site/nix/hosts/testrole.nix testrole ) >/dev/null 2>/dev/null
set -e
seen="$(cat "$capture" 2>/dev/null)"
rm -f "$capture"
if [[ "$seen" == "$tmp/operator.age.key" ]]; then
  test_pass "shim saw SOPS_AGE_KEY_FILE=${tmp}/operator.age.key"
else
  test_fail "expected '${tmp}/operator.age.key', shim saw '$seen'"
fi
rm -rf "$tmp"

# --- Case 2: SOPS_AGE_KEY_FILE unset, no operator.age.key at repo root,
# but an XDG-standard key exists -> XDG fallback wins.
test_start "550.2" "falls back to XDG path when operator.age.key absent but XDG key exists"
tmp="$(setup_fixture 0)"
xdg_dir="$(mktemp -d)"
mkdir -p "$xdg_dir/sops/age"
printf '%s\n' 'AGE-XDG-FIXTURE' > "$xdg_dir/sops/age/keys.txt"
capture="$(mktemp)"
set +e
( cd "$tmp" && unset SOPS_AGE_KEY_FILE && \
  HOME=/tmp/fixture-home-doesnotexist XDG_CONFIG_HOME="$xdg_dir" \
  SOPS_CAPTURE_FILE="$capture" "$tmp/framework/scripts/build-image.sh" --dev \
  site/nix/hosts/testrole.nix testrole ) >/dev/null 2>/dev/null
set -e
seen="$(cat "$capture" 2>/dev/null)"
rm -f "$capture"
if [[ "$seen" == "$xdg_dir/sops/age/keys.txt" ]]; then
  test_pass "shim saw SOPS_AGE_KEY_FILE=$xdg_dir/sops/age/keys.txt"
else
  test_fail "expected '$xdg_dir/sops/age/keys.txt', shim saw '$seen'"
fi
rm -rf "$tmp" "$xdg_dir"

# --- Case 2b: neither operator.age.key NOR XDG key exists -> hard-fail
# with the two candidate paths named. This is the P2-F case raised by
# sub-claude review of the initial batch-B fix: the old two-branch form
# silently set SOPS_AGE_KEY_FILE to a non-existent XDG path.
test_start "550.2b" "hard-fails with named candidate paths when NO key exists anywhere"
tmp="$(setup_fixture 0)"
stderr_file="$(mktemp)"
set +e
( cd "$tmp" && unset SOPS_AGE_KEY_FILE && \
  HOME=/tmp/fixture-home-doesnotexist XDG_CONFIG_HOME=/tmp/fixture-xdg-nonexistent \
  SOPS_CAPTURE_FILE=/tmp/should_not_be_created \
  "$tmp/framework/scripts/build-image.sh" --dev \
  site/nix/hosts/testrole.nix testrole ) >/dev/null 2>"$stderr_file"
rc=$?
set -e
stderr="$(cat "$stderr_file")"
rm -f "$stderr_file"
rm -rf "$tmp"
if [[ "$rc" -ne 0 \
      && "$stderr" == *"No SOPS age key found"* \
      && "$stderr" == *"operator.age.key"* \
      && "$stderr" == *"sops/age/keys.txt"* ]]; then
  test_pass "no-key case hard-fails with both candidate paths named"
else
  test_fail "expected hard-fail with named paths (rc=$rc, stderr snippet below)"
  printf '%s\n' "$stderr" | sed 's/^/    /' >&2
fi

# --- Case 3: SOPS_AGE_KEY_FILE already set -> not overwritten.
test_start "550.3" "does not overwrite an already-set SOPS_AGE_KEY_FILE"
tmp="$(setup_fixture 1)"
capture="$(mktemp)"
set +e
( cd "$tmp" && export SOPS_AGE_KEY_FILE=/absolute/path/set/by/caller.key && \
  SOPS_CAPTURE_FILE="$capture" "$tmp/framework/scripts/build-image.sh" --dev \
  site/nix/hosts/testrole.nix testrole ) >/dev/null 2>/dev/null
set -e
seen="$(cat "$capture" 2>/dev/null)"
rm -f "$capture"
if [[ "$seen" == "/absolute/path/set/by/caller.key" ]]; then
  test_pass "caller's SOPS_AGE_KEY_FILE preserved"
else
  test_fail "expected '/absolute/path/set/by/caller.key', shim saw '$seen'"
fi
rm -rf "$tmp"

runner_summary
