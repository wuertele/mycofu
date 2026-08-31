#!/usr/bin/env bash
# Verifies that build-image.sh does not swallow hil-boot-secret-env.sh
# failures via command substitution (issue #468). Each non-happy case
# must exit non-zero and surface the SOPS_AGE_KEY_FILE diagnostic;
# the happy-path case must NOT emit that diagnostic.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

REAL_BUILD_IMAGE="${REPO_ROOT}/framework/scripts/build-image.sh"

# setup_fixture <shim_body> [nix_builder_type]
#
# Creates a self-contained repo tree in a temp dir that build-image.sh
# can operate on. The helper `hil-boot-secret-env.sh` is a shim whose
# body is provided by the caller so each test controls exit code and
# output independently.
setup_fixture() {
  local shim_body="$1"
  local builder_type="${2:-bogus}"   # default triggers "Unknown nix_builder.type"
  local tmp
  tmp="$(mktemp -d)"

  mkdir -p "$tmp/framework/scripts" "$tmp/site/nix/hosts" "$tmp/site/hil/sops"

  cp "$REAL_BUILD_IMAGE" "$tmp/framework/scripts/build-image.sh"
  chmod +x "$tmp/framework/scripts/build-image.sh"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "$shim_body"
  } > "$tmp/framework/scripts/hil-boot-secret-env.sh"
  chmod +x "$tmp/framework/scripts/hil-boot-secret-env.sh"

  cat > "$tmp/site/config.yaml" <<EOF
domain: test.example
nix_builder:
  type: ${builder_type}
nodes: []
EOF

  cat > "$tmp/site/images.yaml" <<'EOF'
roles:
  testrole:
    build_secret_config: site/hil/config.yaml
    build_secret_ref: proxmox_api_password
EOF

  echo "{}" > "$tmp/site/nix/hosts/testrole.nix"
  echo "domain: fixture" > "$tmp/site/hil/config.yaml"
  echo "encrypted" > "$tmp/site/hil/sops/secrets.yaml"

  # Provide a fake operator.age.key so the SOPS auto-set (#550) does not
  # hard-fail before the yq / helper checks this test exercises.
  printf '%s\n' 'AGE-FIXTURE-KEY' > "$tmp/operator.age.key"

  printf '%s' "$tmp"
}

# run_build_image <tmp> — invokes build-image.sh in --dev mode inside the
# fixture repo, captures stderr, and echoes "<exit_code>\n<stderr>".
run_build_image() {
  local tmp="$1"
  local stderr_file rc
  stderr_file="$(mktemp)"
  set +e
  ( cd "$tmp" && "$tmp/framework/scripts/build-image.sh" --dev \
      site/nix/hosts/testrole.nix testrole ) >/dev/null 2>"$stderr_file"
  rc=$?
  set -e
  printf '%s\n' "$rc"
  cat "$stderr_file"
  rm -f "$stderr_file"
}

# --- Case (a): SOPS_AGE_KEY_FILE unset (helper exits 2 with matching stderr)
test_start "s468.1" "helper failure for missing SOPS_AGE_KEY_FILE is propagated"
tmp="$(setup_fixture 'echo "ERROR: SOPS_AGE_KEY_FILE is required for hil-boot secret injection" >&2; exit 2')"
out="$(run_build_image "$tmp")"
rc="$(printf '%s' "$out" | head -1)"
stderr="$(printf '%s' "$out" | tail -n +2)"
rm -rf "$tmp"
if [[ "$rc" -ne 0 && "$stderr" == *"SOPS_AGE_KEY_FILE"* && "$stderr" == *"exit 2"* ]]; then
  test_pass "build-image exits non-zero and surfaces SOPS_AGE_KEY_FILE diagnostic"
else
  test_fail "build-image did not propagate helper failure (rc=$rc)"
  printf '%s\n' "$stderr" | sed 's/^/    /' >&2
fi

# --- Case (b): SOPS_AGE_KEY_FILE points to non-existent path (helper exits 2)
test_start "s468.2" "helper failure for unreadable SOPS_AGE_KEY_FILE is propagated"
tmp="$(setup_fixture 'echo "ERROR: SOPS_AGE_KEY_FILE is not readable: /nonexistent" >&2; exit 2')"
out="$(run_build_image "$tmp")"
rc="$(printf '%s' "$out" | head -1)"
stderr="$(printf '%s' "$out" | tail -n +2)"
rm -rf "$tmp"
if [[ "$rc" -ne 0 && "$stderr" == *"SOPS_AGE_KEY_FILE"* && "$stderr" == *"exit 2"* ]]; then
  test_pass "build-image exits non-zero and includes SOPS_AGE_KEY_FILE hint"
else
  test_fail "build-image did not propagate unreadable-key failure (rc=$rc)"
  printf '%s\n' "$stderr" | sed 's/^/    /' >&2
fi

# --- Case (c): helper returns 0 but empty (defense-in-depth)
test_start "s468.3" "helper returning empty on exit 0 is rejected with a distinct message"
tmp="$(setup_fixture 'exit 0')"
out="$(run_build_image "$tmp")"
rc="$(printf '%s' "$out" | head -1)"
stderr="$(printf '%s' "$out" | tail -n +2)"
rm -rf "$tmp"
if [[ "$rc" -ne 0 \
      && "$stderr" == *"returned empty output despite exit 0"* \
      && "$stderr" == *"SOPS_AGE_KEY_FILE"* ]]; then
  test_pass "empty-output branch fires with distinct diagnostic + SOPS hint"
else
  test_fail "build-image accepted empty helper output or reported wrong message (rc=$rc)"
  printf '%s\n' "$stderr" | sed 's/^/    /' >&2
fi

# --- Case (d): helper returns non-empty password (happy path)
# We use an invalid nix_builder.type so build-image.sh exits at the case
# statement immediately AFTER the secret input has been accepted.
# Verifying the SOPS-related diagnostic is absent proves the caller did
# NOT fail on the secret step.
test_start "s468.4" "happy-path helper output does not trigger the SOPS diagnostic"
tmp="$(setup_fixture 'printf "%s\n" "not-a-real-secret"' bogus-builder-type)"
out="$(run_build_image "$tmp")"
rc="$(printf '%s' "$out" | head -1)"
stderr="$(printf '%s' "$out" | tail -n +2)"
rm -rf "$tmp"
if [[ "$rc" -ne 0 \
      && "$stderr" == *"Unknown nix_builder.type"* \
      && "$stderr" != *"Common cause: SOPS_AGE_KEY_FILE"* ]]; then
  test_pass "secret step accepted; script failed later on unrelated cause"
else
  test_fail "happy-path helper output tripped the SOPS-related caller check (rc=$rc)"
  printf '%s\n' "$stderr" | sed 's/^/    /' >&2
fi

# --- Case (e): a decrypted secret in helper output is not leaked by the caller
# The helper output could plausibly contain a real password. If the caller
# were to log it under any failure branch, that would be a G7 violation.
# Here we simulate: helper prints a distinctive marker on stdout AND
# exits non-zero. The caller must NOT include that marker in EITHER
# stdout OR stderr — a future regression could accidentally route the
# captured secret to either stream.
test_start "s468.5" "caller does not leak helper stdout to either stream on failure"
LEAK_MARKER="LEAK_MARKER_A7F2C9E1"
tmp="$(setup_fixture "printf '%s\n' '${LEAK_MARKER}'; exit 3")"
stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
set +e
( cd "$tmp" && "$tmp/framework/scripts/build-image.sh" --dev \
    site/nix/hosts/testrole.nix testrole ) >"$stdout_file" 2>"$stderr_file"
rc=$?
set -e
stdout_content="$(cat "$stdout_file")"
stderr_content="$(cat "$stderr_file")"
rm -f "$stdout_file" "$stderr_file"
rm -rf "$tmp"
if [[ "$rc" -ne 0 \
      && "$stderr_content" != *"${LEAK_MARKER}"* \
      && "$stdout_content" != *"${LEAK_MARKER}"* ]]; then
  test_pass "helper stdout surfaced on neither stream on failure"
else
  test_fail "caller may leak helper output on failure (rc=$rc)"
  printf 'stderr:\n%s\nstdout:\n%s\n' "$stderr_content" "$stdout_content" | sed 's/^/    /' >&2
fi

# --- Case (f): stronger happy-path check — MYCOFU_HIL_BOOT_ROOT_PASSWORD actually
# reaches the nix invocation. A regression that accepts non-empty helper output
# but forgets `export MYCOFU_HIL_BOOT_ROOT_PASSWORD="$password"` would pass case (d)
# by exiting on "Unknown nix_builder.type", but it would fail this test.
test_start "s468.6" "exported MYCOFU_HIL_BOOT_ROOT_PASSWORD reaches nix invocation"
SECRET_MARKER="SECRET_MARKER_B3E5D2A9"
tmp="$(setup_fixture "printf '%s\n' '${SECRET_MARKER}'" local)"
# Shim `nix` to capture the env var it inherits, then fail so the test
# terminates quickly instead of driving a real nix build.
env_capture="$(mktemp)"
shim_dir="$(mktemp -d)"
cat > "$shim_dir/nix" <<SHIM
#!/usr/bin/env bash
printenv MYCOFU_HIL_BOOT_ROOT_PASSWORD > "$env_capture" 2>/dev/null || true
# Emit a distinctive marker on stderr so build-image.sh treats it as an
# ordinary build failure (not the disk-space recovery path).
echo "NIX_SHIM_INVOKED_FOR_TEST" >&2
exit 1
SHIM
chmod +x "$shim_dir/nix"
set +e
( cd "$tmp" && PATH="$shim_dir:$PATH" "$tmp/framework/scripts/build-image.sh" --dev \
    site/nix/hosts/testrole.nix testrole ) >/dev/null 2>/dev/null
rc=$?
set -e
captured="$(cat "$env_capture" 2>/dev/null || true)"
rm -f "$env_capture"
rm -rf "$shim_dir" "$tmp"
# rc will be non-zero because the shim exits 1; the check is that the
# secret marker is present in the captured env.
if [[ "$captured" == "${SECRET_MARKER}" ]]; then
  test_pass "MYCOFU_HIL_BOOT_ROOT_PASSWORD was exported to child processes"
else
  test_fail "env var did not reach nix child process (captured='$captured', rc=$rc)"
fi

runner_summary
