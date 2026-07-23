#!/usr/bin/env bash
# test_tofu_github_remote_plumbing.sh — Verify GitHub remote URL plumbing to cicd.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

# Extract a brace-balanced block that starts at the first line containing $header.
# Used to scope an assertion to the ACTUAL block it is about (e.g. the root
# `module "cicd"` call), so a decoy block elsewhere in the same file cannot satisfy it.
extract_block() {
  local file="$1" header="$2"
  awk -v header="$header" '
    !in_block && index($0, header) { in_block = 1 }
    in_block {
      print
      n += gsub(/{/, "{"); n -= gsub(/}/, "}")
      if (started && n == 0) exit
      if (n > 0) started = 1
    }
  ' "$file"
}

# Emit the INNERMOST brace-balanced object that contains a line matching $target, so
# `path` and `content` are proven to live in the SAME write_files object rather than
# merely both appearing somewhere in the file. Keeps a per-depth line buffer (the objects
# here are line-delimited: `{`, `path=…`, `content=…`, `}` each on their own line, with no
# stray braces inside content values), and emits the buffer of the deepest frame that both
# contains $target and closes — i.e. the tightest enclosing object, not the module block.
extract_writefiles_object() {
  local file="$1" target="$2"
  awk -v target="$target" '
    {
      o = gsub(/{/, "{"); c = gsub(/}/, "}")
      if (o > c) {                         # net-opening line: start a new frame
        depth++
        buf[depth] = $0 "\n"
        seen[depth] = index($0, target) ? 1 : 0
      } else if (c > o) {                  # net-closing line: finish this frame
        if (depth < 1) next
        buf[depth] = buf[depth] $0 "\n"
        if (index($0, target)) seen[depth] = 1
        if (seen[depth]) { printf "%s", buf[depth]; exit }
        depth--
      } else if (depth > 0) {              # interior line
        buf[depth] = buf[depth] $0 "\n"
        if (index($0, target)) seen[depth] = 1
      }
    }
  ' "$file"
}

test_start "1" "tofu-wrapper.sh reads github.remote_url"
if grep -Fq "GITHUB_REMOTE_URL=\$(yq -r '.github.remote_url // \"\"' \"\$CONFIG_FILE\")" "${REPO_ROOT}/framework/scripts/tofu-wrapper.sh"; then
  test_pass "tofu-wrapper reads github.remote_url from config.yaml"
else
  test_fail "tofu-wrapper does not read github.remote_url"
fi

test_start "2" "tofu-wrapper.sh exports TF_VAR_github_remote_url"
if grep -Fq 'export TF_VAR_github_remote_url="${GITHUB_REMOTE_URL}"' "${REPO_ROOT}/framework/scripts/tofu-wrapper.sh"; then
  test_pass "TF_VAR_github_remote_url export exists"
else
  test_fail "TF_VAR_github_remote_url export missing"
fi

# These assert the WIRING, not the formatting. `tofu fmt` aligns `=` across a run of
# arguments to the longest attribute name in the run, so adding or removing ANY sibling
# argument re-pads every other line in the block. A fixed-string grep that bakes in the
# padding therefore fails on an unrelated, correct change — which is exactly what happened
# when Sprint 046 added ram_floating_mb to the module "cicd" call (pipeline 1506). Match
# the wiring, tolerate the padding, and allow the trailing comments this repo idiomatically
# puts on arguments (see root/main.tf:665). Scope each assertion to the ACTUAL block it is
# about, so a decoy block elsewhere in the same file cannot satisfy it.
ROOT_TF="${REPO_ROOT}/framework/tofu/root/main.tf"
CICD_TF="${REPO_ROOT}/framework/tofu/modules/cicd/main.tf"

test_start "3" "root module trims and threads var.github_remote_url"
root_cicd_block="$(extract_block "$ROOT_TF" 'module "cicd"')"
if grep -Eq '^[[:space:]]*github_remote_url[[:space:]]*=[[:space:]]*trimspace\([[:space:]]*(#.*)?$' "$ROOT_TF" && \
   grep -Fq 'var.github_remote_url != "" ? var.github_remote_url : try(local.config.github.remote_url, "")' "$ROOT_TF" && \
   grep -Eq '^[[:space:]]*github_remote_url[[:space:]]*=[[:space:]]*local\.github_remote_url[[:space:]]*(#.*)?$' <<< "$root_cicd_block"; then
  test_pass "root module derives and passes github_remote_url into module \"cicd\""
else
  test_fail "root module github_remote_url threading is missing"
fi

test_start "4" "cicd module materializes /run/secrets/github/remote-url"
gh_secret_object="$(extract_writefiles_object "$CICD_TF" '/run/secrets/github/remote-url')"
if [[ -n "$gh_secret_object" ]] && \
   grep -Eq '^[[:space:]]*path[[:space:]]*=[[:space:]]*"/run/secrets/github/remote-url"[[:space:]]*(#.*)?$' <<< "$gh_secret_object" && \
   grep -Eq '^[[:space:]]*content[[:space:]]*=[[:space:]]*var\.github_remote_url[[:space:]]*(#.*)?$' <<< "$gh_secret_object"; then
  test_pass "cicd module writes var.github_remote_url to /run/secrets/github/remote-url in one object"
else
  test_fail "cicd module remote-url materialization missing or split across objects"
fi

test_start "5" "framework does not hardcode wuertele/mycofu"
if ! rg -n 'wuertele/mycofu' "${REPO_ROOT}/framework" >/dev/null 2>&1; then
  test_pass "framework code does not hardcode the site GitHub owner/repo"
else
  test_fail "framework code hardcodes wuertele/mycofu"
fi

test_start "6" "site/config.yaml.production is deleted"
if [[ ! -e "${REPO_ROOT}/site/config.yaml.production" ]]; then
  test_pass "orphan production config file is absent"
else
  test_fail "site/config.yaml.production still exists"
fi

test_start "7" "active deploy paths do not reference config.yaml.production"
if ! rg -n 'config\.yaml\.production' "${REPO_ROOT}/framework" "${REPO_ROOT}/site" "${REPO_ROOT}/.gitlab-ci.yml" \
  -g '*.sh' -g '*.nix' -g '*.tf' -g '*.py' -g '*.yaml' -g '*.yml' >/dev/null 2>&1; then
  test_pass "active deploy paths do not reference config.yaml.production"
else
  test_fail "active deploy paths still reference config.yaml.production"
fi

runner_summary

