#!/usr/bin/env bash
# test_ci_pipeline_gcroot_register.sh — HERMETIC behavioral test for R8 register
# (#560). The structural grep test cannot catch a missing realise op or a
# fail-OPEN parse; this exercises `ci-pipeline-gcroot.sh register` end-to-end
# against a MOCK nix-store + fixture closure-paths.json.
#
# Proves: (1) register passes a realise op to nix-store (the missing-`-r` P1) and
#         produces one indirect root per closure; (2) it fails CLOSED on
#         malformed JSON and on a semantic `{}` (fail-OPEN was the #560 hole).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT="${REPO_ROOT}/framework/scripts/ci-pipeline-gcroot.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

command -v jq >/dev/null 2>&1 || fail "jq required for the hermetic register test"
[[ -f "${SCRIPT}" ]] || fail "helper script missing: ${SCRIPT}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# --- mock nix-store: FAIL unless a realise op (-r/--realise) is present; else
#     create the --add-root symlink and record the realise target. ---
# FIDELITY CAVEAT (issue #573 P2-1): the mock uses `ln -sf`, which unconditionally
# succeeds when the root symlink already exists. So the idempotency case below
# (re-registering an already-pinned root) passes here REGARDLESS of whether real
# nix-store would accept a duplicate indirect root. The "both registers succeed"
# property the #573 fix hinges on was therefore ALSO verified empirically against
# the workstation's real nix daemon: re-running
# `nix-store --add-root <link> --indirect -r <store-path>` over an existing link
# returns rc=0 with the symlink intact. This mock proves the -r ratchet and the
# fail-closed paths; the real-nix probe proves idempotency.
mkdir -p "${WORK}/bin"
MARKER="${WORK}/realise-ops.txt"
cat > "${WORK}/bin/nix-store" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
has_realise=0; root=""; target=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--realise) has_realise=1; shift ;;
    --add-root)   root="${2:-}"; shift 2 ;;
    --indirect)   shift ;;
    *)            target="$1"; shift ;;
  esac
done
if [[ "${has_realise}" -ne 1 ]]; then
  echo "mock nix-store: error: no operation specified" >&2
  exit 1
fi
[[ -n "${root}" ]] || { echo "mock nix-store: no --add-root" >&2; exit 1; }
echo "${target}" >> "${MOCK_MARKER}"
mkdir -p "$(dirname "${root}")"
ln -sf "${target}" "${root}"
MOCK
chmod +x "${WORK}/bin/nix-store"

# --- fake store + valid fixture ---
mkdir -p "${WORK}/store"
: > "${WORK}/store/aaa-gitlab"
: > "${WORK}/store/bbb-cicd"
GOOD="${WORK}/good.json"
printf '{\n  "gitlab": "%s/store/aaa-gitlab",\n  "cicd": "%s/store/bbb-cicd"\n}\n' \
  "${WORK}" "${WORK}" > "${GOOD}"

# run register in a fully hermetic env; echo its exit code
run_register() {
  local rc
  set +e
  env PATH="${WORK}/bin:${PATH}" \
      CI_PIPELINE_ID="999999" \
      MOCK_MARKER="${MARKER}" \
      MYCOFU_GCROOT_BASE="${WORK}/gcroots" \
      MYCOFU_NIX_STORE_PREFIX="${WORK}/store" \
      MYCOFU_CLOSURE_PATHS_FILE="$1" \
      bash "${SCRIPT}" register > "${WORK}/out.log" 2>&1
  rc=$?
  set -e
  echo "${rc}"
}

# run `register-closure <host> <path>` (the build:image single-host pin, #573) in
# the same hermetic env; echo its exit code.
run_register_closure() {
  local rc
  set +e
  env PATH="${WORK}/bin:${PATH}" \
      CI_PIPELINE_ID="999999" \
      MOCK_MARKER="${MARKER}" \
      MYCOFU_GCROOT_BASE="${WORK}/gcroots" \
      MYCOFU_NIX_STORE_PREFIX="${WORK}/store" \
      bash "${SCRIPT}" register-closure "$1" "$2" > "${WORK}/out.log" 2>&1
  rc=$?
  set -e
  echo "${rc}"
}

# 1. Happy path: exit 0, a realise op observed per host, one root symlink per host.
: > "${MARKER}"; rm -rf "${WORK}/gcroots"
rc="$(run_register "${GOOD}")"
[[ "${rc}" -eq 0 ]] || { cat "${WORK}/out.log"; fail "register on a valid fixture exited ${rc} (expected 0)"; }
root_dir="${WORK}/gcroots/999999"
[[ -L "${root_dir}/gitlab" ]] || fail "no indirect root symlink created for gitlab"
[[ -L "${root_dir}/cicd" ]]   || fail "no indirect root symlink created for cicd"
[[ "$(grep -c . "${MARKER}")" -eq 2 ]] \
  || { cat "${MARKER}"; fail "mock nix-store did not observe 2 realise ops (missing -r?)"; }
ok "register realises + pins one indirect root per closure (the -r ratchet)"

# 2. Fail-closed: malformed JSON must make register exit non-zero.
BAD="${WORK}/bad.json"; printf '{ this is not json' > "${BAD}"
: > "${MARKER}"; rm -rf "${WORK}/gcroots"
rc="$(run_register "${BAD}")"
[[ "${rc}" -ne 0 ]] || { cat "${WORK}/out.log"; fail "register on malformed JSON exited 0 (fail-open)"; }
ok "register fails closed on malformed closure-paths.json"

# 3. Fail-closed: a semantic {} (zero hosts) must make register exit non-zero.
EMPTY="${WORK}/empty.json"; printf '{}\n' > "${EMPTY}"
: > "${MARKER}"; rm -rf "${WORK}/gcroots"
rc="$(run_register "${EMPTY}")"
[[ "${rc}" -ne 0 ]] || { cat "${WORK}/out.log"; fail "register on '{}' exited 0 (pinned nothing, fail-open)"; }
ok "register fails closed on an empty {} (>=1 pinned host required)"

# 4. register-closure (#573): pins a SINGLE host's closure at an explicit store
#    path — the build:image early pin, before closure-paths.json exists.
: > "${MARKER}"; rm -rf "${WORK}/gcroots"
rc="$(run_register_closure gitlab "${WORK}/store/aaa-gitlab")"
[[ "${rc}" -eq 0 ]] || { cat "${WORK}/out.log"; fail "register-closure exited ${rc} (expected 0)"; }
[[ -L "${WORK}/gcroots/999999/gitlab" ]] || fail "register-closure created no indirect root for gitlab"
[[ "$(grep -c . "${MARKER}")" -eq 1 ]] \
  || { cat "${MARKER}"; fail "register-closure did not realise exactly 1 closure"; }
ok "register-closure pins one indirect root at an explicit path (build:image window)"

# 4b. register-closure fails closed when the store path is already gone (the
#     die-guard is the intended fail-closed signal, not a silent no-op).
: > "${MARKER}"; rm -rf "${WORK}/gcroots"
rc="$(run_register_closure gitlab "${WORK}/store/does-not-exist")"
[[ "${rc}" -ne 0 ]] || { cat "${WORK}/out.log"; fail "register-closure on a missing path exited 0 (should fail closed)"; }
ok "register-closure fails closed on a missing store path"

# 5. Idempotency (#573): the build:image early pin and the build:merge batch
#    re-pin of the SAME (host, path) must BOTH succeed — re-registering an
#    already-pinned root is not an error. Simulate: register-closure gitlab,
#    then register-closure gitlab again, then the batch register over a fixture
#    that includes gitlab. All three exit 0 and the root survives.
: > "${MARKER}"; rm -rf "${WORK}/gcroots"
rc="$(run_register_closure gitlab "${WORK}/store/aaa-gitlab")"
[[ "${rc}" -eq 0 ]] || { cat "${WORK}/out.log"; fail "first register-closure exited ${rc}"; }
rc="$(run_register_closure gitlab "${WORK}/store/aaa-gitlab")"
[[ "${rc}" -eq 0 ]] || { cat "${WORK}/out.log"; fail "re-register-closure of an already-pinned root exited ${rc} (not idempotent)"; }
rc="$(run_register "${GOOD}")"
[[ "${rc}" -eq 0 ]] || { cat "${WORK}/out.log"; fail "batch register after an early build:image pin exited ${rc} (not idempotent)"; }
[[ -L "${WORK}/gcroots/999999/gitlab" ]] || fail "gitlab root vanished after re-registration"
[[ -L "${WORK}/gcroots/999999/cicd" ]]   || fail "batch register did not pin cicd alongside the pre-pinned gitlab"
ok "re-registering an already-pinned root succeeds (build:image + build:merge idempotency)"

# 6. Parallel build:image legs (#573 P3-2): build:image[gitlab] and
#    build:image[cicd] run concurrently and each register-closure into the SAME
#    per-pipeline dir but under distinct host filenames. Simulate both early
#    pins (sequential here; the on-runner concurrency is safe because mkdir -p is
#    idempotent and the filenames never collide) and assert BOTH roots coexist.
: > "${MARKER}"; rm -rf "${WORK}/gcroots"
rc="$(run_register_closure gitlab "${WORK}/store/aaa-gitlab")"
[[ "${rc}" -eq 0 ]] || { cat "${WORK}/out.log"; fail "gitlab early pin exited ${rc}"; }
rc="$(run_register_closure cicd "${WORK}/store/bbb-cicd")"
[[ "${rc}" -eq 0 ]] || { cat "${WORK}/out.log"; fail "cicd early pin exited ${rc}"; }
[[ -L "${WORK}/gcroots/999999/gitlab" ]] || fail "gitlab root missing after both early pins"
[[ -L "${WORK}/gcroots/999999/cicd" ]]   || fail "cicd root missing after both early pins"
ok "two build:image early pins coexist in one pipeline dir (parallel-leg shape)"

# 7. register-closure rejects a non-store path (#573 P3-3): the NIX_STORE_PREFIX
#    guard in pin_one must fail closed, not silently pin an off-store path.
: > "${MARKER}"; rm -rf "${WORK}/gcroots"
rc="$(run_register_closure gitlab "/etc/passwd")"
[[ "${rc}" -ne 0 ]] || { cat "${WORK}/out.log"; fail "register-closure pinned a non-store path (guard missing)"; }
ok "register-closure fails closed on a non-store path"

echo "PASS: register realises the pin (-r), register-closure pins early, and both fail closed / stay idempotent"
