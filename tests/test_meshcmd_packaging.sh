#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

cd "$REPO_ROOT"

MESH_OUT=""
HELP_OUTPUT=""
AMTIDER_OUTPUT=""
RUNTIME_AVAILABLE=0

run_meshcmd_runtime() {
  local mesh_out="$1"
  local args="$2"

  if [[ "$(uname -s)" == "Linux" ]]; then
    cd /tmp
    timeout 15 "${mesh_out}/bin/meshcmd" ${args}
    return $?
  fi

  local key="${HOME}/.nix-builder/keys/builder_ed25519"
  if [[ -r "$key" ]] && ssh -i "$key" -o BatchMode=yes -o StrictHostKeyChecking=no -x builder@linux-builder true >/dev/null 2>&1; then
    ssh -i "$key" -o BatchMode=yes -o StrictHostKeyChecking=no -x builder@linux-builder \
      "cd /tmp && timeout 15 ${mesh_out}/bin/meshcmd ${args}"
    return $?
  fi

  return 86
}

test_start "s034.0.1" "MeshCmd package builds"
if MESH_OUT="$(nix build .#packages.x86_64-linux.meshcmd --no-link --print-out-paths 2>/dev/null | tail -1)" \
  && [[ -x "${MESH_OUT}/bin/meshcmd" ]]; then
  test_pass "built ${MESH_OUT}/bin/meshcmd"
else
  test_fail "nix build .#packages.x86_64-linux.meshcmd failed or produced no executable"
fi

test_start "s034.0.2" "MeshCmd package exposes pinned upstream metadata"
REV="$(nix eval --raw .#packages.x86_64-linux.meshcmd.meshcentralRev 2>/dev/null || true)"
HASH="$(nix eval --raw .#packages.x86_64-linux.meshcmd.meshcentralHash 2>/dev/null || true)"
if [[ "$REV" == "MeshCentral_v1.0.75" && "$HASH" == sha256-* ]]; then
  test_pass "pinned upstream metadata present (${REV}, ${HASH})"
else
  test_fail "missing or unexpected MeshCentral pin metadata: rev='${REV}' hash='${HASH}'"
fi

test_start "s034.0.3" "No MeshCmd binary is vendored in the repo"
if ! git ls-files framework/vendor 'framework/**/meshcmd' 'framework/**/meshcmd-*' 2>/dev/null | grep -Eq '(^framework/vendor/|/meshcmd(-|$))'; then
  test_pass "repo contains only the Nix package recipe, not a vendored MeshCmd executable"
else
  test_fail "found a vendored MeshCmd-looking executable path in git"
fi

test_start "s034.0.4" "meshcmd help lists AmtIDER"
set +e
HELP_OUTPUT="$(run_meshcmd_runtime "$MESH_OUT" "" 2>&1)"
HELP_RC=$?
set -e
if [[ "$HELP_RC" -eq 0 ]] && grep -q "AmtIDER" <<< "$HELP_OUTPUT"; then
  RUNTIME_AVAILABLE=1
  test_pass "meshcmd prints help and lists AmtIDER"
elif [[ "$HELP_RC" -eq 86 ]]; then
  test_skip "not Linux and local nix linux-builder SSH is unavailable"
else
  test_fail "meshcmd help failed or did not list AmtIDER (rc=${HELP_RC})"
  printf '%s\n' "$HELP_OUTPUT" >&2
fi

test_start "s034.0.5" "meshcmd help amtider documents required flags"
if [[ "$RUNTIME_AVAILABLE" -eq 1 ]]; then
  set +e
  AMTIDER_OUTPUT="$(run_meshcmd_runtime "$MESH_OUT" "help amtider" 2>&1)"
  AMTIDER_RC=$?
  set -e
  if [[ "$AMTIDER_RC" -eq 0 ]] && \
     grep -q -- "--host" <<< "$AMTIDER_OUTPUT" && \
     grep -q -- "--user" <<< "$AMTIDER_OUTPUT" && \
     grep -q -- "--pass" <<< "$AMTIDER_OUTPUT" && \
     grep -q -- "--cdrom" <<< "$AMTIDER_OUTPUT" && \
     grep -q -- "--iderstart" <<< "$AMTIDER_OUTPUT"; then
    test_pass "amtider help documents --host, --user, --pass, --cdrom, --iderstart"
  else
    test_fail "amtider help failed or omitted expected flags (rc=${AMTIDER_RC})"
    printf '%s\n' "$AMTIDER_OUTPUT" >&2
  fi
else
  test_skip "meshcmd runtime was not available in this environment"
fi

runner_summary
