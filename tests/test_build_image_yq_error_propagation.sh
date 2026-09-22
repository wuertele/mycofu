#!/usr/bin/env bash
# Verifies that build-image.sh fails loudly on malformed image manifests
# instead of silently swallowing yq parse errors and treating the role as
# "not mentioned" (issue #549, sibling of #468). Also verifies that a
# well-formed manifest with the role missing continues to the next
# manifest as before.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

REAL_BUILD_IMAGE="${REPO_ROOT}/framework/scripts/build-image.sh"

# setup_fixture <site_images_body> <framework_images_body>
#
# Builds a self-contained tree; both site/images.yaml and
# framework/images.yaml get exactly the caller-supplied content so tests
# can exercise malformed and well-formed manifests independently.
setup_fixture() {
  local site_body="$1"
  local framework_body="$2"
  local tmp
  tmp="$(mktemp -d)"

  mkdir -p "$tmp/framework/scripts" "$tmp/site/nix/hosts" "$tmp/site/hil/sops"

  cp "$REAL_BUILD_IMAGE" "$tmp/framework/scripts/build-image.sh"
  chmod +x "$tmp/framework/scripts/build-image.sh"

  # Shim helper: never reached in these tests because they exit at yq or
  # at the "Unknown nix_builder.type" case afterward; provided so the
  # script's own guard against a missing helper does not fire.
  cat > "$tmp/framework/scripts/hil-boot-secret-env.sh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' 'unused-in-yq-tests'
SHIM
  chmod +x "$tmp/framework/scripts/hil-boot-secret-env.sh"

  cat > "$tmp/site/config.yaml" <<CFG
domain: test.example
nix_builder:
  type: bogus
nodes: []
CFG

  printf '%s' "$site_body" > "$tmp/site/images.yaml"
  printf '%s' "$framework_body" > "$tmp/framework/images.yaml"

  echo "{}" > "$tmp/site/nix/hosts/testrole.nix"
  echo "domain: fixture" > "$tmp/site/hil/config.yaml"
  echo "encrypted" > "$tmp/site/hil/sops/secrets.yaml"

  # Provide a fake operator.age.key so the SOPS auto-set (#550) does not
  # hard-fail before the yq / helper checks this test exercises.
  printf '%s\n' 'AGE-FIXTURE-KEY' > "$tmp/operator.age.key"

  printf '%s' "$tmp"
}

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

# --- Case 1: malformed site/images.yaml aborts with an explicit yq error.
# The old code masked this via `... 2>/dev/null || true` and behaved as if
# the role had no build_secret_config; nix then reported the misleading
# "MYCOFU_HIL_BOOT_ROOT_PASSWORD is required" downstream.
test_start "549.1" "malformed site/images.yaml aborts with explicit yq error"
tmp="$(setup_fixture $'roles:\n\ttestrole:\n\t\tbuild_secret_config: x\n' 'roles: {}')"
out="$(run_build_image "$tmp")"
rc="$(printf '%s' "$out" | head -1)"
stderr="$(printf '%s' "$out" | tail -n +2)"
rm -rf "$tmp"
if [[ "$rc" -ne 0 \
      && "$stderr" == *"yq failed parsing"* \
      && "$stderr" == *"site/images.yaml"* ]]; then
  test_pass "malformed manifest fails loudly with 'yq failed parsing' + path"
else
  test_fail "malformed manifest did not fail loudly (rc=$rc)"
  printf '%s\n' "$stderr" | sed 's/^/    /' >&2
fi

# --- Case 2: well-formed but role-absent site/images.yaml falls through to
# framework/images.yaml (no yq error). We use a malformed framework
# manifest so the fall-through is observable.
test_start "549.2" "well-formed manifest with role absent falls through cleanly"
tmp="$(setup_fixture $'roles:\n  otherrole:\n    build_secret_config: x\n    build_secret_ref: y\n' $'roles:\n\ttestrole:\n\t\tbuild_secret_config: x\n')"
out="$(run_build_image "$tmp")"
rc="$(printf '%s' "$out" | head -1)"
stderr="$(printf '%s' "$out" | tail -n +2)"
rm -rf "$tmp"
if [[ "$rc" -ne 0 \
      && "$stderr" == *"yq failed parsing"* \
      && "$stderr" == *"framework/images.yaml"* ]]; then
  test_pass "fall-through to framework/images.yaml proves site was parsed cleanly"
else
  test_fail "fall-through path masked or misreported (rc=$rc)"
  printf '%s\n' "$stderr" | sed 's/^/    /' >&2
fi

# --- Case 3: both manifests well-formed, role in neither — no yq error at
# all; script exits later on the "Unknown nix_builder.type" case. Proves
# the fail-fast wrapper does not fail-fast on the expected empty case.
test_start "549.3" "role absent from both manifests does not trigger yq-error path"
tmp="$(setup_fixture $'roles:\n  otherrole:\n    build_secret_config: x\n    build_secret_ref: y\n' $'roles:\n  yetanother:\n    build_secret_config: x\n    build_secret_ref: y\n')"
out="$(run_build_image "$tmp")"
rc="$(printf '%s' "$out" | head -1)"
stderr="$(printf '%s' "$out" | tail -n +2)"
rm -rf "$tmp"
if [[ "$rc" -ne 0 \
      && "$stderr" != *"yq failed parsing"* \
      && "$stderr" == *"Unknown nix_builder.type"* ]]; then
  test_pass "expected empty result treated as continue, not fail"
else
  test_fail "empty-role case tripped the yq-error path or reported wrong error (rc=$rc)"
  printf '%s\n' "$stderr" | sed 's/^/    /' >&2
fi

runner_summary
