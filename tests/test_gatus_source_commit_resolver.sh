#!/usr/bin/env bash
# test_gatus_source_commit_resolver.sh — Teeth for issue #528.
#
# The Gatus github-mirror-main endpoint asserts a SHA that names what has
# been *published* to GitHub main. That's always the tip of prod. Every
# call site — CI's build:merge job, rebuild-cluster.sh on the workstation,
# manual invocations — must resolve to the same value from the same repo
# state. Otherwise generated gatus CIDATA differs by one line, the bpg
# provider drifts on inline source_raw.data, and the gatus VM churns on
# every dev pipeline (the specific defect logged in #528, ultimately
# suspected root cause of the "unexplained" prod-gatus drift in #527).
#
# This test builds a fixture git repo where dev and prod tips are
# deliberately different, then asserts:
#
#   T1. resolve_gatus_expected_source_commit returns prod's tip from any
#       HEAD, using local refs (workstation fast path).
#   T2. It falls back to `git ls-remote origin prod` when prod is not
#       fetched locally (the CI shallow-clone case). This is the
#       structural fix for #528.
#   T3. generate-gatus-config.sh — with GATUS_GITHUB_EXPECTED_SOURCE_COMMIT
#       unset — embeds the same SHA (prod tip) regardless of HEAD. This
#       is the end-to-end assertion that "CI-shaped invocation" and
#       "rebuild-cluster-shaped invocation" produce byte-identical
#       github-mirror endpoint blocks.
#   T4. When publish is disabled, the resolver is not called (the
#       downstream-adopter path stays clean under set -e).
#   T5. Structural regression ratchet: neither `.gitlab-ci.yml` nor
#       `rebuild-cluster.sh` sets GATUS_GITHUB_EXPECTED_SOURCE_COMMIT to
#       $CI_COMMIT_SHA or another non-prod value. Since #718 such a set is
#       inert rather than dangerous (the generator clears the seam unless
#       --allow-test-seams is passed), but it is kept as a readability
#       ratchet: a caller that appears to inject a SHA which is then
#       silently ignored is a trap for the next reader.
#   T6. Issue #718: the test seams above cannot steer a PRODUCTION
#       invocation. They are honoured only behind --allow-test-seams, so an
#       ambient export in an operator or CI shell cannot choose the SHA that
#       ships in gatus CIDATA. Two-sided, so the negative cases cannot pass
#       vacuously.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TEMP_PATHS=()

cleanup() {
  set +u
  local path
  for path in "${TEMP_PATHS[@]}"; do
    rm -rf "${path}"
  done
}
trap cleanup EXIT

make_temp_dir() {
  local var="$1"
  local path
  path="$(mktemp -d "${TMPDIR:-/tmp}/gatus-src-resolver.XXXXXX")"
  TEMP_PATHS+=("${path}")
  printf -v "${var}" '%s' "${path}"
}

git_q() { git "$@" >/dev/null 2>&1; }

# Build a fixture "remote" repo with a prod branch and a dev branch whose
# tips differ. Returns:
#   $1 var    — path to the remote bare repo
#   $2 var    — the prod-tip SHA
#   $3 var    — the dev-tip SHA
build_fixture_remote() {
  local remote_var="$1"
  local prod_var="$2"
  local dev_var="$3"

  local remote seed prod_sha dev_sha
  make_temp_dir remote
  make_temp_dir seed

  git_q -C "${seed}" init -b prod
  git_q -C "${seed}" config user.email t@t
  git_q -C "${seed}" config user.name t
  echo prod > "${seed}/f"
  git_q -C "${seed}" add f
  git_q -C "${seed}" commit -m prod-tip
  prod_sha="$(git -C "${seed}" rev-parse HEAD)"

  git_q -C "${seed}" checkout -b dev
  echo dev > "${seed}/g"
  git_q -C "${seed}" add g
  git_q -C "${seed}" commit -m dev-tip
  dev_sha="$(git -C "${seed}" rev-parse HEAD)"

  git_q -C "${seed}" checkout prod

  git_q clone --bare "${seed}" "${remote}"

  printf -v "${remote_var}" '%s' "${remote}"
  printf -v "${prod_var}"   '%s' "${prod_sha}"
  printf -v "${dev_var}"    '%s' "${dev_sha}"
}

# Full clone with the given remote NAME configured (workstation shape).
make_full_clone() {
  local clone_var="$1"
  local remote_url="$2"
  local remote_name="$3"

  local clone
  make_temp_dir clone
  git_q clone --origin "${remote_name}" "${remote_url}" "${clone}"
  # Fetch prod explicitly so refs/remotes/<remote>/prod exists.
  git_q -C "${clone}" fetch "${remote_name}" prod
  printf -v "${clone_var}" '%s' "${clone}"
}

# Shallow clone shaped like a GitLab CI checkout: only the pipeline
# branch is fetched (--single-branch --depth 20), origin is the remote,
# no refs/remotes/origin/prod.
make_ci_shaped_clone() {
  local clone_var="$1"
  local remote_url="$2"
  local pipeline_branch="$3"

  local clone
  make_temp_dir clone
  git_q clone --origin origin --single-branch --branch "${pipeline_branch}" \
    --depth 20 "${remote_url}" "${clone}"
  printf -v "${clone_var}" '%s' "${clone}"
}

# --- Build the fixture universe once ---
build_fixture_remote REMOTE_REPO PROD_SHA DEV_SHA

# ---------------------------------------------------------------------
# T1 — Workstation fast path: local ref points at prod, resolver returns
#      prod tip regardless of HEAD.
# ---------------------------------------------------------------------
test_start "1a" "workstation with gitlab/prod fetched: resolver returns prod tip from HEAD=prod"
make_full_clone WS_CLONE "${REMOTE_REPO}" gitlab
git_q -C "${WS_CLONE}" checkout prod
GOT="$(
  cd "${WS_CLONE}"
  source "${REPO_ROOT}/framework/scripts/github-publish-lib.sh"
  resolve_gatus_expected_source_commit "${WS_CLONE}"
)"
if [[ "${GOT}" == "${PROD_SHA}" ]]; then
  test_pass "resolved prod tip via refs/remotes/gitlab/prod"
else
  test_fail "expected prod tip ${PROD_SHA:0:12}, got ${GOT:0:12}"
fi

test_start "1b" "workstation with gitlab/prod fetched: resolver returns prod tip from HEAD=dev"
git_q -C "${WS_CLONE}" fetch gitlab dev
git_q -C "${WS_CLONE}" checkout -B dev "refs/remotes/gitlab/dev"
GOT="$(
  cd "${WS_CLONE}"
  source "${REPO_ROOT}/framework/scripts/github-publish-lib.sh"
  resolve_gatus_expected_source_commit "${WS_CLONE}"
)"
if [[ "${GOT}" == "${PROD_SHA}" ]]; then
  test_pass "HEAD=dev still resolved to prod tip"
else
  test_fail "expected prod tip ${PROD_SHA:0:12}, got ${GOT:0:12} — resolver leaked HEAD (this is exactly #528)"
fi

# ---------------------------------------------------------------------
# T2 — CI shape: shallow clone of the pipeline branch, no
#      refs/remotes/origin/prod. Resolver must fall back to ls-remote
#      and still return prod tip.
# ---------------------------------------------------------------------
test_start "2" "CI-shaped shallow clone of dev: ls-remote fallback resolves prod tip"
make_ci_shaped_clone CI_CLONE "${REMOTE_REPO}" dev
# Confirm the shape we're testing: no local prod ref of any kind.
if git -C "${CI_CLONE}" rev-parse --verify refs/heads/prod^{commit} >/dev/null 2>&1 \
  || git -C "${CI_CLONE}" rev-parse --verify refs/remotes/origin/prod^{commit} >/dev/null 2>&1 \
  || git -C "${CI_CLONE}" rev-parse --verify refs/remotes/gitlab/prod^{commit} >/dev/null 2>&1; then
  test_fail "fixture setup is wrong: CI clone unexpectedly has a local prod ref"
else
  GOT="$(
    cd "${CI_CLONE}"
    source "${REPO_ROOT}/framework/scripts/github-publish-lib.sh"
    resolve_gatus_expected_source_commit "${CI_CLONE}"
  )"
  if [[ "${GOT}" == "${PROD_SHA}" ]]; then
    test_pass "ls-remote fallback resolved prod tip from a CI-shaped shallow clone"
  else
    test_fail "expected prod tip ${PROD_SHA:0:12}, got ${GOT:0:12}"
  fi
fi

# ---------------------------------------------------------------------
# T3 — End-to-end equivalence: generate-gatus-config.sh with no env-var
#      set produces the same source_commit line whether HEAD is prod, dev,
#      or a feature branch, AND whether the clone is workstation-shaped
#      or CI-shaped. This is the direct assertion for #528.
# ---------------------------------------------------------------------
# Fake a config fixture that opts in to publishing and has a valid
# GitHub remote URL (github_remote_to_raw_metadata_url needs a
# well-formed value or it exits under set -e).
build_config_fixture() {
  local cfg_dir_var="$1"
  local cfg_dir
  make_temp_dir cfg_dir

  # Use the real config.yaml as a base so unrelated yq reads succeed,
  # then override the fields the mirror block depends on.
  cp "${REPO_ROOT}/site/config.yaml" "${cfg_dir}/config.yaml"
  cp "${REPO_ROOT}/site/applications.yaml" "${cfg_dir}/applications.yaml"
  yq -i '.publish.github.enabled = true'                    "${cfg_dir}/config.yaml"
  yq -i '.github.remote_url = "git@github.com:owner/repo.git"' "${cfg_dir}/config.yaml"

  printf -v "${cfg_dir_var}" '%s' "${cfg_dir}"
}

extract_source_commit_line() {
  # Read stdin, print just the source_commit assertion line. Consume the
  # entire stream (no `exit`) so the generate-gatus-config.sh producer
  # does not receive SIGPIPE mid-write, which under `set -o pipefail`
  # would fail the pipeline with 141.
  awk '/\[BODY\].source_commit ==/ { print }'
}

# Emulate a full CI-shaped invocation of the build:merge step by
# arranging cwd to be the CI clone and calling generate-gatus-config.sh
# with a substituted config file path.
run_generate() {
  local clone_dir="$1"
  local cfg_path="$2"
  # GATUS_SOURCE_REPO_DIR is a test seam: generate-gatus-config.sh
  # normally computes REPO_DIR from its own script location (the real
  # framework tree). For fixture-repo tests we point the resolver at
  # the fixture repo instead. #718: the seam is not merely "a no-op in
  # production" — it is now unreachable there, because the generator clears it
  # unless --allow-test-seams is passed, so this fixture harness declares it.
  ( unset GATUS_GITHUB_EXPECTED_SOURCE_COMMIT
    export GATUS_SOURCE_REPO_DIR="${clone_dir}"
    "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" \
      --allow-test-seams "${cfg_path}" )
}

build_config_fixture CFG_DIR

test_start "3a" "generate-gatus-config.sh from workstation clone (HEAD=dev) embeds prod tip"
git_q -C "${WS_CLONE}" checkout dev
WS_LINE="$(run_generate "${WS_CLONE}" "${CFG_DIR}/config.yaml" | extract_source_commit_line)"
EXPECT_LINE="      - \"[BODY].source_commit == ${PROD_SHA}\""
if [[ "${WS_LINE}" == "${EXPECT_LINE}" ]]; then
  test_pass "workstation-clone dev-HEAD embeds prod tip"
else
  test_fail "workstation-clone dev-HEAD embedded the wrong SHA. Got: ${WS_LINE}"
fi

test_start "3b" "generate-gatus-config.sh from CI-shaped clone (HEAD=dev) embeds prod tip"
CI_LINE="$(run_generate "${CI_CLONE}" "${CFG_DIR}/config.yaml" | extract_source_commit_line)"
if [[ "${CI_LINE}" == "${EXPECT_LINE}" ]]; then
  test_pass "CI-shaped clone embeds prod tip via ls-remote fallback"
else
  test_fail "CI-shaped clone embedded the wrong SHA. Got: ${CI_LINE}"
fi

test_start "3c" "CI-shaped output equals workstation output byte-for-byte"
# The strongest form of the #528 assertion: with no env var, the two
# call shapes converge on identical CIDATA regardless of HEAD.
WS_ALL="$(run_generate "${WS_CLONE}" "${CFG_DIR}/config.yaml")"
CI_ALL="$(run_generate "${CI_CLONE}" "${CFG_DIR}/config.yaml")"
if [[ "${WS_ALL}" == "${CI_ALL}" ]]; then
  test_pass "workstation and CI paths produce byte-identical gatus config"
else
  test_fail "workstation and CI paths diverge — CIDATA churn remains possible (#528 not fixed)"
  diff <(echo "${WS_ALL}") <(echo "${CI_ALL}") | sed 's/^/    /' >&2 || true
fi

# ---------------------------------------------------------------------
# T4 — Downstream adopter: publish disabled, no prod branch. The resolver
#      must NOT run (its failure would break generate-gatus-config.sh
#      under set -e for adopters who never intend to publish).
# ---------------------------------------------------------------------
test_start "4" "publish disabled: resolver is not called even when prod does not exist"
make_temp_dir NO_PROD_DIR
git_q -C "${NO_PROD_DIR}" init -b main
git_q -C "${NO_PROD_DIR}" config user.email t@t
git_q -C "${NO_PROD_DIR}" config user.name t
echo x > "${NO_PROD_DIR}/x"
git_q -C "${NO_PROD_DIR}" add x
git_q -C "${NO_PROD_DIR}" commit -m x

make_temp_dir DISABLED_CFG
cp "${REPO_ROOT}/site/config.yaml" "${DISABLED_CFG}/config.yaml"
cp "${REPO_ROOT}/site/applications.yaml" "${DISABLED_CFG}/applications.yaml"
yq -i '.publish.github.enabled = false' "${DISABLED_CFG}/config.yaml"
yq -i 'del(.github)'                    "${DISABLED_CFG}/config.yaml"

set +e
OUT="$( cd "${NO_PROD_DIR}" && unset GATUS_GITHUB_EXPECTED_SOURCE_COMMIT && \
  "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" "${DISABLED_CFG}/config.yaml" 2>&1 )"
STATUS=$?
set -e
if [[ ${STATUS} -eq 0 ]] && ! grep -q 'github-mirror-main' <<<"${OUT}"; then
  test_pass "disabled-publish + missing prod: exit 0, no github-mirror endpoint"
else
  test_fail "expected clean skip, got exit=${STATUS}"
  sed 's/^/    /' <<<"${OUT}" >&2
fi

# ---------------------------------------------------------------------
# T5 — Structural regression ratchet: catch anyone reintroducing the
#      $CI_COMMIT_SHA leak or an inline HEAD fallback that would silently
#      diverge from the shared resolver.
# ---------------------------------------------------------------------
test_start "5a" ".gitlab-ci.yml no longer sets GATUS_GITHUB_EXPECTED_SOURCE_COMMIT=\$CI_COMMIT_SHA"
if grep -Fq 'GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${CI_COMMIT_SHA' "${REPO_ROOT}/.gitlab-ci.yml"; then
  test_fail "CI reintroduced the pipeline-branch leak into gatus CIDATA (#528)"
else
  test_pass "CI does not pass a pipeline-branch SHA to generate-gatus-config.sh"
fi

test_start "5b" "rebuild-cluster.sh defers to the single resolver, does not inject or redefine a SHA"
# #528 + #701. The anti-divergence property is now enforced by having exactly
# ONE resolver call site (generate-gatus-config.sh's internal opt-in path).
# rebuild-cluster.sh must therefore:
#   - NOT set GATUS_GITHUB_EXPECTED_SOURCE_COMMIT (no injected/divergent SHA),
#   - NOT call resolve_gatus_expected_source_commit (no pre-resolve; #701
#     removed the unconditional pre-resolve die), AND
#   - NOT redefine the resolver locally.
# Any of these reintroduces the #528 divergence path or the #701 false die.
if ! grep -Fq 'GATUS_GITHUB_EXPECTED_SOURCE_COMMIT=' \
     "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" && \
   ! grep -Fq 'resolve_gatus_expected_source_commit' \
     "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh" && \
   ! grep -Eq '^resolve_gatus_expected_source_commit\(\) *\{' \
     "${REPO_ROOT}/framework/scripts/rebuild-cluster.sh"; then
  test_pass "rebuild-cluster.sh defers to generate-gatus-config.sh; no SHA injection, pre-resolve, or redefinition"
else
  test_fail "rebuild-cluster.sh injects/pre-resolves/redefines the resolver — CI and workstation can diverge again (#528) or die needlessly (#701)"
fi

test_start "5c" "shared resolver has no HEAD fallback (would reintroduce the defect)"
if grep -Fq 'HEAD^{commit}' "${REPO_ROOT}/framework/scripts/github-publish-lib.sh"; then
  test_fail "HEAD fallback present — resolver can leak the current-branch SHA into gatus CIDATA"
else
  test_pass "no HEAD fallback in the shared resolver"
fi

# ---------------------------------------------------------------------
# T6 — Issue #718: ambient test seams cannot steer a PRODUCTION invocation.
#
# The seams exist for the fixture harness above. Before #718 they were read
# straight from the environment, so a stale export in the shell running a
# production deploy authority (safe-apply.sh, CI build:merge) chose the SHA
# that shipped in gatus CIDATA — the #528 anti-divergence property could be
# defeated from outside the repo. #701 patched one caller with a call-site
# `env -u`; the lockout now lives in generate-gatus-config.sh itself.
#
# These cases are deliberately two-sided. 6a/6c prove the seams are inert
# without the flag; 6b proves they still work WITH the flag, so a 6a pass can
# never be vacuous (e.g. from the mirror block silently not being emitted).
# ---------------------------------------------------------------------
BOGUS_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

test_start "6a" "production invocation ignores an ambient GATUS_GITHUB_EXPECTED_SOURCE_COMMIT (#718)"
set +e
SEAM_PROD_OUT="$(
  GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${BOGUS_SHA}" \
  GATUS_SOURCE_REPO_DIR="${WS_CLONE}" \
  GATUS_SOURCE_COMMIT_REMOTE="bogus-remote-that-does-not-exist" \
  "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" "${CFG_DIR}/config.yaml" 2>&1
)"
SEAM_PROD_STATUS=$?
set -e
if [[ ${SEAM_PROD_STATUS} -eq 0 ]] && \
   grep -q 'github-mirror-main' <<<"${SEAM_PROD_OUT}" && \
   ! grep -Fq "${BOGUS_SHA}" <<<"${SEAM_PROD_OUT}"; then
  test_pass "exported seams did not reach the emitted source_commit assertion"
else
  test_fail "a stale ambient export steered (or broke) production resolution (exit=${SEAM_PROD_STATUS})"
  # Dump the WHOLE output, not just source_commit lines: the most likely
  # failure is the generator exiting non-zero with an ERROR line that contains
  # no "source_commit" at all, and a filtered dump would discard it (R-G-5 #5).
  sed 's/^/    /' <<<"${SEAM_PROD_OUT}" >&2
fi

test_start "6b" "--allow-test-seams still honours the seam (6a is not vacuous) (#718)"
set +e
SEAM_TEST_OUT="$(
  GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${BOGUS_SHA}" \
  "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" \
    --allow-test-seams "${CFG_DIR}/config.yaml" 2>&1
)"
SEAM_TEST_STATUS=$?
set -e
if [[ ${SEAM_TEST_STATUS} -eq 0 ]] && \
   grep -Fq "[BODY].source_commit == ${BOGUS_SHA}" <<<"${SEAM_TEST_OUT}"; then
  test_pass "the declared test seam still overrides resolution"
else
  test_fail "--allow-test-seams did not honour the seam (exit=${SEAM_TEST_STATUS}) — 6a would be vacuous"
  sed 's/^/    /' <<<"${SEAM_TEST_OUT}" >&2
fi

test_start "6d" "hermetic: production resolution comes from the script's OWN repo, not the seams (#718)"
# 6a/6c assert only that the seam values are ABSENT. That is a negative, and a
# negative can be satisfied by a third repo being selected (an ambient GIT_DIR
# does exactly that — see #915). This case is the positive form: stand up a
# complete synthetic framework root whose own prod tip is a known fixture SHA,
# export the seams pointing somewhere else, and require the emitted SHA to be
# EXACTLY that root's prod tip. Hermetic — no dependence on the real repo's
# prod ref, and no network.
make_temp_dir FW_ROOT
mkdir -p "${FW_ROOT}/framework/scripts" "${FW_ROOT}/site"
: > "${FW_ROOT}/flake.nix"
cp "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" \
   "${REPO_ROOT}/framework/scripts/certbot-cluster.sh" \
   "${REPO_ROOT}/framework/scripts/github-publish-lib.sh" \
   "${FW_ROOT}/framework/scripts/"
chmod +x "${FW_ROOT}/framework/scripts/generate-gatus-config.sh"
printf 'applications: {}\n' > "${FW_ROOT}/site/applications.yaml"
cat > "${FW_ROOT}/site/config.yaml" <<'YAML'
domain: example.com
acme: staging
publish:
  github:
    enabled: true
github:
  remote_url: "git@github.com:owner/repo.git"
vms:
  dns1_prod: {ip: "10.0.0.1"}
  dns2_prod: {ip: "10.0.0.2"}
  vault_prod: {ip: "10.0.0.3"}
  pbs: {ip: "10.0.0.4"}
  gitlab: {ip: "10.0.0.5"}
  gatus: {ip: "10.0.0.6"}
nas: {ip: "10.0.0.7"}
replication: {health_port: 9200}
proxmox: {storage_pool: vmstore}
email: {smtp_host: h, smtp_port: 25, to: "a@b.c"}
nodes:
  - {name: pve01, mgmt_ip: "10.0.0.10"}
YAML
git_q -C "${FW_ROOT}" init -b main
git_q -C "${FW_ROOT}" config user.email t@t
git_q -C "${FW_ROOT}" config user.name t
git_q -C "${FW_ROOT}" add -A
git_q -C "${FW_ROOT}" commit -m fixture
git_q -C "${FW_ROOT}" branch prod
FW_PROD_SHA="$(git -C "${FW_ROOT}" rev-parse refs/heads/prod)"

set +e
FW_OUT="$(
  GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${BOGUS_SHA}" \
  GATUS_SOURCE_REPO_DIR="${WS_CLONE}" \
  GATUS_SOURCE_COMMIT_REMOTE="bogus-remote-that-does-not-exist" \
  "${FW_ROOT}/framework/scripts/generate-gatus-config.sh" 2>&1
)"
FW_STATUS=$?
set -e
if [[ ${FW_STATUS} -eq 0 ]] && \
   grep -Fq "[BODY].source_commit == ${FW_PROD_SHA}" <<<"${FW_OUT}"; then
  test_pass "emitted SHA is exactly the synthetic root's own prod tip"
else
  test_fail "production resolution did not come from the script's own repo (exit=${FW_STATUS}, expected ${FW_PROD_SHA})"
  sed 's/^/    /' <<<"${FW_OUT}" >&2
fi

test_start "6c" "production invocation ignores an ambient GATUS_SOURCE_REPO_DIR (#718)"
# WS_CLONE's prod tip is a fixture commit that cannot be the real repo's prod
# tip, so its presence in the output would prove the repo redirect was honoured.
set +e
SEAM_DIR_OUT="$(
  GATUS_SOURCE_REPO_DIR="${WS_CLONE}" \
  "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" "${CFG_DIR}/config.yaml" 2>&1
)"
SEAM_DIR_STATUS=$?
set -e
if [[ ${SEAM_DIR_STATUS} -eq 0 ]] && \
   grep -q 'github-mirror-main' <<<"${SEAM_DIR_OUT}" && \
   ! grep -Fq "${PROD_SHA}" <<<"${SEAM_DIR_OUT}"; then
  test_pass "exported repo-dir seam did not redirect production resolution"
else
  test_fail "an ambient GATUS_SOURCE_REPO_DIR redirected (or broke) production resolution (exit=${SEAM_DIR_STATUS})"
  sed 's/^/    /' <<<"${SEAM_DIR_OUT}" >&2
fi

runner_summary
