#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/s042-underinclude.XXXXXX")"
WORK="${TMP_DIR}/repo"
BASE_PATCH="${TMP_DIR}/base.patch"
WORKTREE_CREATED=0

cleanup() {
  if [[ "$WORKTREE_CREATED" -eq 1 ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$WORK" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

NIX_STORE_ARGS=()
if [[ -n "${MYCOFU_NIX_STORE:-}" ]]; then
  NIX_STORE_ARGS=(--store "$MYCOFU_NIX_STORE")
fi

NIX_INPUT_ARGS=()
if [[ -n "${MYCOFU_NIXPKGS_PATH:-}" ]]; then
  NIX_INPUT_ARGS+=(--override-input nixpkgs "path:${MYCOFU_NIXPKGS_PATH}")
fi
if [[ -n "${MYCOFU_NIXPKGS_UNSTABLE_PATH:-}" ]]; then
  NIX_INPUT_ARGS+=(--override-input nixpkgs-unstable "path:${MYCOFU_NIXPKGS_UNSTABLE_PATH}")
fi

nix_eval() {
  # bash 3.2 (macOS) + `set -u` errors on ${arr[@]} when the array is
  # empty; ${arr[@]+"${arr[@]}"} expands to nothing in that case.
  nix \
    ${NIX_STORE_ARGS[@]+"${NIX_STORE_ARGS[@]}"} \
    eval \
    ${NIX_INPUT_ARGS[@]+"${NIX_INPUT_ARGS[@]}"} \
    "$@"
}

prepare_work_repo() {
  git -C "$REPO_ROOT" diff --binary > "$BASE_PATCH"

  if git -C "$REPO_ROOT" worktree add --detach "$WORK" HEAD >/dev/null 2>&1; then
    WORKTREE_CREATED=1
  else
    git clone --no-local "$REPO_ROOT" "$WORK" >/dev/null 2>&1
  fi

  if [[ -s "$BASE_PATCH" ]]; then
    (cd "$WORK" && git apply --whitespace=nowarn "$BASE_PATCH")
  fi
}

prepare_work_repo

test_start "s042.under.1" "baseline grafana and dns eval before deliberate break"
if (cd "$WORK" && nix_eval --raw .#packages.x86_64-linux.grafana-image >/dev/null 2>&1) &&
   (cd "$WORK" && nix_eval --raw .#packages.x86_64-linux.dns-image >/dev/null 2>&1); then
  test_pass "baseline grafana-image and dns-image eval"
else
  test_fail "baseline eval failed before under-inclusion mutation"
  runner_summary
fi

test_start "s042.under.2" "removing site/apps role partition makes grafana eval fail loudly"
perl -0pi -e 's/\n\s+"site\/apps\/\$\{role\}\/"//' "$WORK/flake.nix"

ERR="${TMP_DIR}/grafana.err"
set +e
(cd "$WORK" && nix_eval --raw .#packages.x86_64-linux.grafana-image >"${TMP_DIR}/grafana.out" 2>"$ERR")
GRAFANA_RC=$?
set -e

if [[ "$GRAFANA_RC" -eq 0 ]]; then
  test_fail "grafana-image eval succeeded after site/apps role partition removal"
elif grep -Fq "site/apps/grafana" "$ERR" &&
     (grep -Fq "does not exist" "$ERR" || grep -Fq "not found" "$ERR"); then
  test_pass "grafana-image eval failed loudly for missing site/apps/grafana"
else
  test_fail "grafana-image failed, but error did not identify missing site/apps/grafana"
  tail -80 "$ERR" >&2 || true
fi

test_start "s042.under.3" "grafana-local partition break does not break dns eval"
if (cd "$WORK" && nix_eval --raw .#packages.x86_64-linux.dns-image >/dev/null 2>&1); then
  test_pass "dns-image still evals"
else
  test_fail "dns-image eval failed after grafana app partition removal"
fi

runner_summary
