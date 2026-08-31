#!/usr/bin/env bash
# test_ci_gcroot_pipeline_pinning.sh — structural ratchet for Sprint 046 R8
# (#560): the pipeline must pin each to-be-deployed control-plane closure with a
# durable per-CI_PIPELINE_ID GC root, release it after a successful deploy, and
# fail-closed sweep stale roots with a window wider than the max pipeline run.
# yq/grep only, fail-closed on parse error, vacuity-proof (every anchor asserted).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"
SCRIPT="${REPO_ROOT}/framework/scripts/ci-pipeline-gcroot.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# Fail-closed: a malformed .gitlab-ci.yml must fail the test, not silently pass.
yq '.' "${CI_FILE}" >/dev/null 2>&1 || fail ".gitlab-ci.yml failed yq parse"

# 0. The helper script exists and is syntactically valid.
[[ -f "${SCRIPT}" ]] || fail "helper script missing: ${SCRIPT}"
bash -n "${SCRIPT}" || fail "helper script has a bash syntax error"
ok "ci-pipeline-gcroot.sh present and bash -n clean"

# 1. build:merge REGISTERS a per-pipeline GC root (the pin point, right where
#    build/closure-paths.json is finalized). Assert the exact register call is a
#    script step of build:merge — not merely present somewhere in the file.
#    Capture-then-grep (not `yq | grep -q`): under `set -o pipefail`, `grep -q`
#    closes the pipe on first match and can SIGPIPE yq, propagating a false
#    failure.
merge_steps="$(yq -r '.["build:merge"].script[]' "${CI_FILE}")"
grep -qE 'ci-pipeline-gcroot\.sh +register' <<<"${merge_steps}" \
  || fail "build:merge does not run ci-pipeline-gcroot.sh register"
ok "build:merge registers a per-pipeline GC root"

# 1b. register must come AFTER merge-image-versions.sh writes closure-paths.json
#     (a reorder would pin a stale/absent file and the grep above still passes).
mrg_idx="$(yq -r '.["build:merge"].script | to_entries[] | select(.value | test("merge-image-versions\\.sh")) | .key' "${CI_FILE}" | head -1)"
reg_idx="$(yq -r '.["build:merge"].script | to_entries[] | select(.value | test("ci-pipeline-gcroot\\.sh +register")) | .key' "${CI_FILE}" | head -1)"
[[ -n "${mrg_idx}" ]] || fail "build:merge has no merge-image-versions.sh step"
[[ -n "${reg_idx}" ]] || fail "build:merge has no register step"
[[ "${reg_idx}" -gt "${mrg_idx}" ]] \
  || fail "register (step ${reg_idx}) must run AFTER merge-image-versions.sh (step ${mrg_idx})"
ok "register runs after merge-image-versions.sh in build:merge"

# 1c. build:image PINS each control-plane closure the instant it is built (#573),
#     closing the earlier build:image -> build:merge GC window. The pin must
#     (a) call register-closure, (b) pass $ROLE dynamically (no new hardcoded
#     role list — reuses the existing gitlab/cicd closure gate), and (c) come
#     AFTER build/closure-path-${ROLE}.txt is written in the same script block.
img_script="$(yq -r '.["build:image"].script[]' "${CI_FILE}")"
grep -qE 'ci-pipeline-gcroot\.sh +register-closure +"\$ROLE"' <<<"${img_script}" \
  || fail "build:image does not run 'ci-pipeline-gcroot.sh register-closure \"\$ROLE\" ...'"
cp_write_ln="$(grep -nE '> +"build/closure-path-\$\{ROLE\}\.txt"' <<<"${img_script}" | head -1 | cut -d: -f1)"
reg_closure_ln="$(grep -nE 'ci-pipeline-gcroot\.sh +register-closure' <<<"${img_script}" | head -1 | cut -d: -f1)"
[[ -n "${cp_write_ln}" ]] || fail "build:image never writes build/closure-path-\${ROLE}.txt"
[[ -n "${reg_closure_ln}" ]] || fail "build:image has no register-closure step"
[[ "${reg_closure_ln}" -gt "${cp_write_ln}" ]] \
  || fail "register-closure (line ${reg_closure_ln}) must come AFTER the closure-path write (line ${cp_write_ln})"
ok "build:image pins each control-plane closure after building it (register-closure, \$ROLE, ordered)"

# 2. EVERY deploy:control-plane:* job RELEASES the root after its deploy step,
#    and the release comes AFTER the deploy-control-plane.sh call in that job's
#    script (release-before-deploy would defeat the pin). Vacuity-proof: there
#    must be at least one such job, and each one must satisfy the ordering.
# Portable collect (macOS bash 3.2 has no `mapfile`; .claude/rules/platform.md).
CP_JOBS=()
while IFS= read -r job; do
  [[ -n "${job}" ]] && CP_JOBS+=("${job}")
done < <(yq -r 'keys[] | select(test("^deploy:control-plane:"))' "${CI_FILE}")
[[ "${#CP_JOBS[@]}" -ge 1 ]] || fail "no deploy:control-plane:* jobs found (yq/key drift?)"
for job in "${CP_JOBS[@]}"; do
  deploy_line="$(J="$job" yq -r '.[strenv(J)].script | to_entries[] | select(.value | test("deploy-control-plane\\.sh")) | .key' "${CI_FILE}" | head -1)"
  release_line="$(J="$job" yq -r '.[strenv(J)].script | to_entries[] | select(.value | test("ci-pipeline-gcroot\\.sh +release")) | .key' "${CI_FILE}" | head -1)"
  [[ -n "${deploy_line}" ]] || fail "$job: no deploy-control-plane.sh step"
  [[ -n "${release_line}" ]] || fail "$job: does not release its GC root"
  [[ "${release_line}" -gt "${deploy_line}" ]] \
    || fail "$job: release (step ${release_line}) must come AFTER deploy (step ${deploy_line})"
  ok "$job releases its GC root after a successful deploy"
done

# 3. The register subcommand adds an INDIRECT root under the per-CI_PIPELINE_ID
#    path — the durable, cross-job pin.
grep -qE 'nix-store +--add-root .*--indirect' "${SCRIPT}" \
  || fail "register does not use 'nix-store --add-root ... --indirect'"
grep -q '/nix/var/nix/gcroots/pipelines' "${SCRIPT}" \
  || fail "GC roots are not written under /nix/var/nix/gcroots/pipelines"
grep -q 'CI_PIPELINE_ID' "${SCRIPT}" \
  || fail "GC root path is not scoped per CI_PIPELINE_ID"
ok "register adds an indirect root under /nix/var/nix/gcroots/pipelines/\${CI_PIPELINE_ID}"

# 3b. The helper dispatches the register-closure subcommand (#573). An unrouted
#     subcommand would make build:image's early pin die "usage" on every
#     pipeline instead of closing the window.
grep -qE 'register-closure\)[[:space:]]+cmd_register_closure' "${SCRIPT}" \
  || fail "main() does not dispatch the register-closure subcommand"
ok "ci-pipeline-gcroot.sh routes register-closure -> cmd_register_closure"

# 4. The release subcommand actually removes the pipeline's root(s).
grep -qE 'rm +-(rf|f) +"?\$\{?dir\}?"?' "${SCRIPT}" \
  || fail "release does not rm the pipeline GC root dir"
ok "release removes the pipeline GC root(s)"

# 4b. cmd_release cleanup must stay failure-tolerant: release runs in the deploy
#     job script, so a spurious rm/rmdir error must not fail a good deploy.
grep -qE 'rm +-f +"\$\{dir\}/\$\{host\}".*2>/dev/null.*\|\| *true' "${SCRIPT}" \
  || fail "cmd_release per-host 'rm -f' is not guarded (2>/dev/null || true)"
grep -qE 'rmdir +"\$\{dir\}".*2>/dev/null.*\|\| *true' "${SCRIPT}" \
  || fail "cmd_release 'rmdir' is not guarded (2>/dev/null || true)"
ok "cmd_release cleanup (rm -f / rmdir) is failure-tolerant"

# 5. Fail-closed stale sweep exists and its window is WIDER than the max
#    pipeline duration. Extract the numeric STALE_MMIN default and assert it
#    strictly exceeds the documented max pipeline wall-clock (180 min / 3h). A
#    window <= max duration could sweep a live pipeline's roots — the exact
#    thing this must never do.
grep -qE 'find .*-type d.*-mmin \+' "${SCRIPT}" \
  || fail "no fail-closed stale sweep (find ... -type d ... -mmin +N)"
grep -qE '^GCROOT_BASE=.*/nix/var/nix/gcroots/pipelines' "${SCRIPT}" \
  || fail "the stale sweep base (GCROOT_BASE) is not /nix/var/nix/gcroots/pipelines"
STALE="$(grep -oE 'STALE_MMIN=\"\$\{MYCOFU_GCROOT_STALE_MMIN:-[0-9]+\}\"' "${SCRIPT}" \
         | grep -oE ':-[0-9]+' | tr -d ':-')"
[[ -n "${STALE}" ]] || fail "could not extract STALE_MMIN default from the script"
MAX_PIPELINE_MIN=180
[[ "${STALE}" -gt "${MAX_PIPELINE_MIN}" ]] \
  || fail "stale-sweep window ${STALE}m must exceed the max pipeline duration ${MAX_PIPELINE_MIN}m"
ok "stale sweep window ${STALE}m > max pipeline ${MAX_PIPELINE_MIN}m (fail-closed, no live-pipeline hazard)"

# 6. Wiring: a validate job must actually run this test (an unwired ratchet is
#    dead weight — the exact defect the R5 rework calls out).
gate_steps="$(yq -r '.["validate:ci-gcroot-pipeline-pinning"].script[]' "${CI_FILE}" 2>/dev/null || true)"
grep -qx 'bash tests/test_ci_gcroot_pipeline_pinning.sh' <<<"${gate_steps}" \
  || fail "validate:ci-gcroot-pipeline-pinning is not wired to run this test"
ok "validate:ci-gcroot-pipeline-pinning runs this test"

echo "PASS: R8 pipeline GC-root pinning is wired register -> release with a safe stale sweep"
