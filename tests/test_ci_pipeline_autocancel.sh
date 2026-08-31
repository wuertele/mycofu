#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
CI_FILE="${REPO_ROOT}/.gitlab-ci.yml"
HIL_CI_FILE="${REPO_ROOT}/tests/hil/.gitlab-ci-hil.yml"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok - $*"; }

# Fail-closed: malformed CI YAML is a test failure, not a skip.
yq '.' "${CI_FILE}" >/dev/null 2>&1 || fail ".gitlab-ci.yml failed yq parse"
yq '.' "${HIL_CI_FILE}" >/dev/null 2>&1 || fail "tests/hil/.gitlab-ci-hil.yml failed yq parse"

auto_cancel="$(yq -r '.workflow.auto_cancel.on_new_commit // ""' "${CI_FILE}")"
[[ "${auto_cancel}" == "interruptible" ]] \
  || fail "workflow.auto_cancel.on_new_commit is '${auto_cancel}', expected interruptible"
ok "workflow auto_cancel cancels interruptible jobs on new commits"

# Unsafe families must never opt into interruptible cancellation. A mid-run
# cancel of any of these can strand partial state:
#   deploy:/upload/converge:/prepare:/reclaim:/publish:  cluster, image store, mirror
#   build:merge   registers the R8 CI GC roots; register/release must pair
#   validate:plan takes a lock on the shared PostgreSQL tofu state backend
#   regression    validate.sh --regression runs DESTRUCTIVE tests against dev VMs
#   test:/bench:  live-cluster jobs; kept non-interruptible for defense in depth
#   measure:      (Sprint 046 R2) measure:build-at-floor clamps the SHARED
#                 nix-daemon.service MemoryMax and restores it from a trap. A
#                 mid-build auto-cancel is precisely the path on which the restore
#                 is least likely to run, and a stranded clamp OOMs every later
#                 build on the runner until reboot.
# validate:* coverage is asserted separately; the converge family here means the
# top-level deploy-stage converge jobs, not validate:converge-* structural tests.
UNSAFE_JOB_RE='^(deploy:|upload|converge:|reclaim:|prepare:|publish:|bench:|test:|measure:)|^build:merge$|^validate:plan$|^regression$'
unsafe_count="$(R="${UNSAFE_JOB_RE}" yq -r '[to_entries[] | select((.value | tag == "!!map") and (.key | test(strenv(R))))] | length' "${CI_FILE}")"
[[ "${unsafe_count}" -ge 8 ]] \
  || fail "unsafe-job guard matched only ${unsafe_count} jobs; expected at least 8"
ok "unsafe-job guard is non-vacuous (${unsafe_count} jobs matched)"

unsafe_true="$(R="${UNSAFE_JOB_RE}" yq -r 'to_entries[] | select((.value | tag == "!!map") and (.key | test(strenv(R))) and (.value.interruptible == true)) | .key' "${CI_FILE}")"
[[ -z "${unsafe_true}" ]] \
  || fail "unsafe jobs set interruptible: true: $(tr '\n' ' ' <<< "${unsafe_true}" | sed 's/ *$//')"
ok "unsafe main-pipeline mutator jobs do not opt into interruptible cancellation"

hil_true="$(yq -r 'to_entries[] | select((.value | tag == "!!map") and (.value.interruptible == true)) | .key' "${HIL_CI_FILE}")"
[[ -z "${hil_true}" ]] \
  || fail "HIL jobs set interruptible: true: $(tr '\n' ' ' <<< "${hil_true}" | sed 's/ *$//')"
ok "HIL pipeline jobs do not opt into interruptible cancellation"

REPRESENTATIVE_OPT_INS=(
  "build:image"
  "build:image:hil-boot"
  "validate:source-filter"
  "validate:per-role-isolation"
  "validate:nix-checks"
  "validate:cicd-memory-safety"
  "validate:shell-syntax"
)

for job in "${REPRESENTATIVE_OPT_INS[@]}"; do
  value="$(J="${job}" yq -r '.[strenv(J)].interruptible // "<absent>"' "${CI_FILE}")"
  [[ "${value}" == "true" ]] || fail "${job} interruptible is '${value}', expected true"
  ok "${job} is interruptible"
done

validate_offenders="$(yq -r 'to_entries[] | select((.value | tag == "!!map") and (.key | test("^validate:")) and .key != "validate:plan" and (.value.interruptible != true)) | .key' "${CI_FILE}")"
if [[ -n "${validate_offenders}" ]]; then
  echo "FAIL: validate jobs missing interruptible: true:" >&2
  echo "${validate_offenders}" >&2
  exit 1
fi
ok "every validate:* job except validate:plan is interruptible"

false_jobs="$(yq -r 'to_entries[] | select((.value | tag == "!!map") and (.value.interruptible == false)) | .key' "${CI_FILE}")"
[[ -z "${false_jobs}" ]] \
  || fail ".gitlab-ci.yml jobs set interruptible: false: $(tr '\n' ' ' <<< "${false_jobs}" | sed 's/ *$//')"

hil_false_jobs="$(yq -r 'to_entries[] | select((.value | tag == "!!map") and (.value.interruptible == false)) | .key' "${HIL_CI_FILE}")"
[[ -z "${hil_false_jobs}" ]] \
  || fail "HIL jobs set interruptible: false: $(tr '\n' ' ' <<< "${hil_false_jobs}" | sed 's/ *$//')"
ok "no jobs set interruptible: false"

default_interruptible="$(yq -r '(.default // {}) | has("interruptible")' "${CI_FILE}")"
[[ "${default_interruptible}" == "false" ]] || fail ".default.interruptible is set"
ok ".default.interruptible is absent"

exit 0
