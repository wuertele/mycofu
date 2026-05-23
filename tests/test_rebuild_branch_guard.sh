#!/usr/bin/env bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE_REPO="${TMP_DIR}/repo"
SHIM_DIR="${TMP_DIR}/shims"
mkdir -p "${FIXTURE_REPO}/site" "${FIXTURE_REPO}/framework/tofu/root" "${FIXTURE_REPO}/build" "${SHIM_DIR}"

REAL_GIT="$(command -v git)"
REAL_YQ="$(command -v yq)"
REAL_JQ="$(command -v jq)"
REAL_PYTHON3="$(command -v python3)"

cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
  - name: pve02
    mgmt_ip: 10.0.0.12
vms:
  dns_dev:
    vmid: 301
  dns_prod:
    vmid: 401
  vault_dev:
    vmid: 302
  vault_prod:
    vmid: 402
  acme_dev:
    vmid: 303
  gitlab:
    vmid: 150
  cicd:
    vmid: 160
  pbs:
    vmid: 190
  gatus:
    vmid: 650
EOF

cat > "${FIXTURE_REPO}/framework/tofu/root/main.tf" <<'EOF'
module "dns_dev" {}
module "dns_prod" {}
module "vault_dev" {}
module "vault_prod" {}
module "acme_dev" {}
module "gitlab" {}
module "cicd" {}
module "pbs" {}
module "gatus" {}
EOF

cat > "${FIXTURE_REPO}/README.md" <<'EOF'
fixture
EOF

"${REAL_GIT}" -C "${FIXTURE_REPO}" init -b prod >/dev/null
"${REAL_GIT}" -C "${FIXTURE_REPO}" config user.name "Test Runner"
"${REAL_GIT}" -C "${FIXTURE_REPO}" config user.email "tests@example.invalid"
"${REAL_GIT}" -C "${FIXTURE_REPO}" add .
"${REAL_GIT}" -C "${FIXTURE_REPO}" commit -m "prod baseline" >/dev/null
PROD_COMMIT="$("${REAL_GIT}" -C "${FIXTURE_REPO}" rev-parse HEAD)"

"${REAL_GIT}" -C "${FIXTURE_REPO}" branch dev-same "${PROD_COMMIT}"
"${REAL_GIT}" -C "${FIXTURE_REPO}" checkout -b dev-no-config >/dev/null
printf 'dev readme change\n' >> "${FIXTURE_REPO}/README.md"
"${REAL_GIT}" -C "${FIXTURE_REPO}" add README.md
"${REAL_GIT}" -C "${FIXTURE_REPO}" commit -m "dev readme change" >/dev/null
DEV_NO_CONFIG_COMMIT="$("${REAL_GIT}" -C "${FIXTURE_REPO}" rev-parse HEAD)"

"${REAL_GIT}" -C "${FIXTURE_REPO}" checkout -b dev-config >/dev/null
cat > "${FIXTURE_REPO}/site/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.11
  - name: pve02
    mgmt_ip: 10.0.0.12
vms:
  dns_dev:
    vmid: 301
  dns_prod:
    vmid: 451
  vault_dev:
    vmid: 302
  vault_prod:
    vmid: 402
  acme_dev:
    vmid: 303
  gitlab:
    vmid: 150
  cicd:
    vmid: 160
  pbs:
    vmid: 190
  gatus:
    vmid: 650
EOF
"${REAL_GIT}" -C "${FIXTURE_REPO}" add site/config.yaml
"${REAL_GIT}" -C "${FIXTURE_REPO}" commit -m "dev config change" >/dev/null
DEV_CONFIG_COMMIT="$("${REAL_GIT}" -C "${FIXTURE_REPO}" rev-parse HEAD)"

"${REAL_GIT}" -C "${FIXTURE_REPO}" checkout prod >/dev/null
"${REAL_GIT}" -C "${FIXTURE_REPO}" update-ref refs/remotes/gitlab/prod "${PROD_COMMIT}"

cat > "${SHIM_DIR}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_args=()
if [[ "${1:-}" == "-C" ]]; then
  repo_args=(-C "$2")
  shift 2
fi

if [[ "${1:-}" == "fetch" && "${2:-}" == "gitlab" ]]; then
  if [[ -n "${STUB_GIT_FETCH_EXIT:-}" ]]; then
    if [[ -n "${STUB_GIT_FETCH_STDERR:-}" ]]; then
      printf '%s\n' "${STUB_GIT_FETCH_STDERR}" >&2
    fi
    exit "${STUB_GIT_FETCH_EXIT}"
  fi
  exit 0
fi

exec "${REAL_GIT}" "${repo_args[@]}" "$@"
EOF
chmod +x "${SHIM_DIR}/git"

cat > "${SHIM_DIR}/tofu-wrapper.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  init)
    exit "${STUB_TOFU_INIT_EXIT:-0}"
    ;;
  state)
    if [[ "${2:-}" == "list" ]]; then
      if [[ -n "${STUB_TOFU_STATE_EXIT:-}" ]]; then
        exit "${STUB_TOFU_STATE_EXIT}"
      fi
      printf '%s' "${STUB_TOFU_STATE_OUTPUT:-}"
      exit 0
    fi
    ;;
esac

echo "unexpected tofu-wrapper invocation: $*" >&2
exit 2
EOF
chmod +x "${SHIM_DIR}/tofu-wrapper.sh"

cat > "${SHIM_DIR}/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

remote_cmd="${*: -1}"
if [[ "${remote_cmd}" =~ qm[[:space:]]+status[[:space:]]+([0-9]+) ]]; then
  if [[ "${STUB_SSH_FAIL:-0}" == "1" ]]; then
    printf '%s\n' "${STUB_SSH_STDERR:-ssh failed}" >&2
    exit 255
  fi
  vmid="${BASH_REMATCH[1]}"
  case " ${STUB_PRESENT_VMIDS:-} " in
    *" ${vmid} "*) printf 'present\n' ;;
    *) printf 'absent\n' ;;
  esac
  exit 0
fi

if [[ "${remote_cmd}" == *"pvesh get "* ]]; then
  if [[ "${STUB_PBS_FAIL:-0}" == "1" ]]; then
    printf '%s\n' "${STUB_PBS_STDERR:-pbs probe failed}" >&2
    exit 255
  fi
  printf '%s' "${STUB_PBS_OUTPUT:-[]}"
  exit 0
fi

if [[ "${STUB_SSH_FAIL:-0}" == "1" ]]; then
  printf '%s\n' "${STUB_SSH_STDERR:-ssh failed}" >&2
  exit 255
fi

printf '%s\n' "${STUB_SSH_OUTPUT:-absent}"
EOF
chmod +x "${SHIM_DIR}/ssh"

export PATH="${SHIM_DIR}:$PATH"
export REAL_GIT
export REPO_DIR="${FIXTURE_REPO}"
export CONFIG="${FIXTURE_REPO}/site/config.yaml"
export LOG_DIR="${FIXTURE_REPO}/build"
export GIT_DEPLOY_TOFU_WRAPPER_BIN="tofu-wrapper.sh"
export GIT_DEPLOY_GIT_BIN="git"
export GIT_DEPLOY_YQ_BIN="${REAL_YQ}"
export GIT_DEPLOY_JQ_BIN="${REAL_JQ}"
export GIT_DEPLOY_PYTHON_BIN="${REAL_PYTHON3}"
export GIT_DEPLOY_SSH_BIN="ssh"
export REBUILD_COMMAND_NAME="framework/scripts/rebuild-cluster.sh"

source "${REPO_ROOT}/framework/scripts/git-deploy-context.sh"

checkout_ref() {
  "${REAL_GIT}" -C "${FIXTURE_REPO}" checkout "$1" >/dev/null 2>&1
}

checkout_detached() {
  "${REAL_GIT}" -C "${FIXTURE_REPO}" checkout --detach "$1" >/dev/null 2>&1
}

restore_prod_ref() {
  "${REAL_GIT}" -C "${FIXTURE_REPO}" update-ref refs/remotes/gitlab/prod "${PROD_COMMIT}"
}

remove_prod_ref() {
  "${REAL_GIT}" -C "${FIXTURE_REPO}" update-ref -d refs/remotes/gitlab/prod
}

reset_case() {
  export STUB_TOFU_INIT_EXIT=0
  export STUB_TOFU_STATE_EXIT=""
  export STUB_TOFU_STATE_OUTPUT="module.gitlab"
  export STUB_PRESENT_VMIDS=""
  export STUB_SSH_FAIL=0
  export STUB_SSH_STDERR=""
  export STUB_SSH_OUTPUT="absent"
  export STUB_PBS_FAIL=0
  export STUB_PBS_STDERR=""
  export STUB_PBS_OUTPUT="[]"
  export STUB_GIT_FETCH_EXIT=""
  export STUB_GIT_FETCH_STDERR=""

  SCOPE=""
  OVERRIDE_BRANCH_CHECK=0
  ALLOW_DIRTY=0

  unset KNOWN_SCOPE_MODULES_CACHE
  unset SCOPE_IMPACT SCOPE_IMPACT_REASON SCOPE_UNKNOWN_TARGETS
  unset GIT_BRANCH GIT_DETACHED GIT_COMMIT GIT_COMMIT_SHORT GIT_SUBJECT GIT_DATE GIT_TREE_STATE
  unset INITIAL_DEPLOY INITIAL_DEPLOY_REASON
  unset GITLAB_FETCH_ATTEMPTED GITLAB_FETCH_SUCCEEDED GITLAB_FETCH_DETAIL
  unset LAST_KNOWN_PROD_AVAILABLE LAST_KNOWN_PROD_COMMIT LAST_KNOWN_PROD_COMMIT_SHORT LAST_KNOWN_PROD_DATE LAST_KNOWN_PROD_DIFFERS_FROM_CURRENT
  unset CONFIG_YAML_DIFF BRANCH_SAFETY_ALLOWED BRANCH_SAFETY_REASON

  restore_prod_ref
}

run_context() {
  resolve_git_context
  classify_scope_impact || return 1
  detect_initial_deploy
  if [[ "${INITIAL_DEPLOY}" -eq 0 ]]; then
    refresh_gitlab_prod_ref
  else
    GITLAB_FETCH_ATTEMPTED=0
    GITLAB_FETCH_SUCCEEDED=0
    GITLAB_FETCH_DETAIL="not attempted (initial deploy)"
    LAST_KNOWN_PROD_AVAILABLE=0
    LAST_KNOWN_PROD_COMMIT=""
    LAST_KNOWN_PROD_COMMIT_SHORT=""
    LAST_KNOWN_PROD_DATE=""
    LAST_KNOWN_PROD_DIFFERS_FROM_CURRENT=0
    CONFIG_YAML_DIFF=0
  fi
  check_branch_safety || return 1
  if [[ "${INITIAL_DEPLOY}" -eq 0 ]]; then
    resolve_last_known_prod_context
    detect_config_yaml_divergence
  fi
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$actual" == "$expected" ]]; then
    test_pass "$message"
  else
    test_fail "$message (expected '${expected}', got '${actual}')"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    test_pass "$message"
  else
    test_fail "$message (missing '${needle}')"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    test_fail "$message (unexpected '${needle}')"
  else
    test_pass "$message"
  fi
}

assert_jq() {
  local file="$1"
  local expr="$2"
  local expected="$3"
  local message="$4"
  local actual
  actual="$("${REAL_JQ}" -r "${expr}" "${file}")"
  assert_eq "${expected}" "${actual}" "${message}"
}

test_start "RBG-1" "prod control-plane is allowed"
reset_case
checkout_ref prod
SCOPE="control-plane"
if run_context; then
  test_pass "prod control-plane run allowed"
else
  test_fail "prod control-plane run should be allowed"
fi
assert_eq "shared_control_plane" "${SCOPE_IMPACT}" "control-plane classified as shared control plane"
assert_eq "0" "${INITIAL_DEPLOY}" "existing deployment detected from non-empty state"

test_start "RBG-2" "dev control-plane is refused without override"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
if run_context; then
  test_fail "dev control-plane run should be refused"
else
  test_pass "dev control-plane run refused"
fi
assert_eq "shared_control_plane" "${SCOPE_IMPACT}" "refused control-plane scope still classified correctly"

test_start "RBG-3" "override allows guarded scope"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
if run_context; then
  test_pass "override allowed dev control-plane run"
else
  test_fail "override should allow dev control-plane run"
fi
if should_skip_gitlab_handoff; then
  test_pass "override prod/shared run skips GitLab handoff"
else
  test_fail "override prod/shared run should skip GitLab handoff"
fi

test_start "RBG-4" "dev-only scope stays allowed"
reset_case
checkout_ref dev-no-config
SCOPE="vm=dns_dev,vault_dev"
if run_context; then
  test_pass "dev-only targeted rebuild allowed"
else
  test_fail "dev-only targeted rebuild should be allowed"
fi
assert_eq "dev_only" "${SCOPE_IMPACT}" "dev-only vm scope classified correctly"
if should_skip_gitlab_handoff; then
  test_fail "dev-only override skip should not trigger"
else
  test_pass "dev-only run does not skip GitLab handoff"
fi

test_start "RBG-5" "prod-affecting targeted scope is refused from dev"
reset_case
checkout_ref dev-no-config
SCOPE="vm=dns_prod"
if run_context; then
  test_fail "prod-affecting vm scope should be refused from dev"
else
  test_pass "prod-affecting vm scope refused from dev"
fi
assert_eq "prod_affecting" "${SCOPE_IMPACT}" "dns_prod classified as prod affecting"

test_start "RBG-6" "full rebuild from dev is refused"
reset_case
checkout_ref dev-no-config
if run_context; then
  test_fail "full rebuild from dev should be refused"
else
  test_pass "full rebuild from dev refused"
fi
assert_eq "prod_affecting" "${SCOPE_IMPACT}" "full rebuild classified as prod affecting"

test_start "RBG-7" "detached HEAD is refused unless override"
reset_case
checkout_detached "${DEV_NO_CONFIG_COMMIT}"
SCOPE="control-plane"
if run_context; then
  test_fail "detached HEAD control-plane should be refused"
else
  test_pass "detached HEAD control-plane refused"
fi
reset_case
checkout_detached "${DEV_NO_CONFIG_COMMIT}"
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
if run_context; then
  test_pass "override allows detached HEAD control-plane run"
else
  test_fail "override should allow detached HEAD control-plane run"
fi
assert_eq "1" "${GIT_DETACHED}" "detached checkout detected"

test_start "RBG-8" "special cases and unknown targets"
reset_case
checkout_ref dev-no-config
SCOPE="vm=acme_dev"
if classify_scope_impact; then
  test_pass "acme_dev classified successfully"
else
  test_fail "acme_dev should classify successfully"
fi
assert_eq "dev_only" "${SCOPE_IMPACT}" "acme_dev classified as dev_only"
SCOPE="vm=gatus"
if classify_scope_impact; then
  test_pass "gatus classified successfully"
else
  test_fail "gatus should classify successfully"
fi
assert_eq "prod_affecting" "${SCOPE_IMPACT}" "gatus classified as prod_affecting"
SCOPE="vm=bogus"
if classify_scope_impact; then
  test_fail "unknown target should fail closed"
else
  test_pass "unknown target failed closed"
fi
assert_contains "${SCOPE_UNKNOWN_TARGETS}" "bogus" "unknown target is reported"

test_start "RBG-9" "initial deploy skips branch gate only when all signals are clear"
reset_case
checkout_ref dev-no-config
remove_prod_ref
export STUB_TOFU_STATE_OUTPUT=""
export STUB_PRESENT_VMIDS=""
if run_context; then
  test_pass "true initial deploy allowed from dev"
else
  test_fail "true initial deploy should be allowed"
fi
assert_eq "1" "${INITIAL_DEPLOY}" "initial deploy detected when state and Proxmox are empty"
assert_contains "${INITIAL_DEPLOY_REASON}" "no PBS backups found" "initial deploy reason explains all-clear PBS result"
banner_output="$(print_deploy_banner)"
assert_contains "${banner_output}" "Initial deploy: yes" "banner shows initial deploy"

test_start "RBG-9a" "gitlab/prod ref prevents initial deploy when other signals are clear"
reset_case
checkout_ref dev-no-config
SCOPE="vm=dns_dev"
remove_prod_ref
restore_prod_ref
export STUB_TOFU_INIT_EXIT=1
export STUB_TOFU_STATE_OUTPUT=""
export STUB_PRESENT_VMIDS=""
if run_context; then
  test_pass "gitlab/prod ref short-circuited initial deploy detection"
else
  test_fail "gitlab/prod ref case should remain allowed for dev-only scope"
fi
assert_eq "0" "${INITIAL_DEPLOY}" "gitlab/prod ref prevents initial deploy classification"
assert_contains "${INITIAL_DEPLOY_REASON}" "gitlab/prod ref" "initial deploy reason explains local prod ref"

test_start "RBG-9b" "PBS backups prevent initial deploy when state and Proxmox are empty"
reset_case
checkout_ref dev-no-config
SCOPE="vm=dns_dev"
remove_prod_ref
export STUB_TOFU_STATE_OUTPUT=""
export STUB_PRESENT_VMIDS=""
export STUB_PBS_OUTPUT='[{"volid":"pbs-nas:backup/vm/150/2026-04-03T12:00:00Z"}]'
if run_context; then
  test_pass "PBS backup signal allowed dev-only scope to continue"
else
  test_fail "PBS backup case should remain allowed for dev-only scope"
fi
assert_eq "0" "${INITIAL_DEPLOY}" "matching PBS backup prevents initial deploy classification"
assert_contains "${INITIAL_DEPLOY_REASON}" "PBS" "initial deploy reason explains PBS backup match"

test_start "RBG-9c" "PBS unreachable is neutral when other signals are clear"
reset_case
checkout_ref dev-no-config
remove_prod_ref
export STUB_TOFU_STATE_OUTPUT=""
export STUB_PRESENT_VMIDS=""
export STUB_PBS_FAIL=1
if run_context; then
  test_pass "PBS-unreachable initial deploy allowed from dev"
else
  test_fail "PBS-unreachable initial deploy should still be allowed"
fi
assert_eq "1" "${INITIAL_DEPLOY}" "PBS probe unreachability remains neutral"
assert_contains "${INITIAL_DEPLOY_REASON}" "PBS could not be reached" "initial deploy reason explains neutral PBS result"

test_start "RBG-9d" "PBS backups for unrelated VMIDs do not prevent initial deploy"
reset_case
checkout_ref dev-no-config
remove_prod_ref
export STUB_TOFU_STATE_OUTPUT=""
export STUB_PRESENT_VMIDS=""
export STUB_PBS_OUTPUT='[{"volid":"pbs-nas:backup/vm/999/2026-04-03T12:00:00Z"}]'
if run_context; then
  test_pass "non-matching PBS backups do not block true initial deploy"
else
  test_fail "non-matching PBS backups should still allow true initial deploy"
fi
assert_eq "1" "${INITIAL_DEPLOY}" "non-matching PBS backups keep initial deploy classification"

test_start "RBG-10" "configured VMIDs in Proxmox disable initial deploy skip"
reset_case
checkout_ref dev-no-config
SCOPE="vm=dns_dev"
remove_prod_ref
export STUB_TOFU_STATE_OUTPUT=""
export STUB_PRESENT_VMIDS="150"
if run_context; then
  test_pass "dev-only scope still allowed after existing VM probe"
else
  test_fail "dev-only scope should remain allowed"
fi
assert_eq "0" "${INITIAL_DEPLOY}" "existing Proxmox VM prevents initial deploy classification"
assert_contains "${INITIAL_DEPLOY_REASON}" "configured VMID 150 already exists" "initial deploy reason explains Proxmox match"

test_start "RBG-10-state" "non-empty tofu state detected (without gitlab/prod ref masking)"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
remove_prod_ref
export STUB_TOFU_STATE_OUTPUT="module.gitlab"
run_context
assert_eq "0" "${INITIAL_DEPLOY}" "non-empty tofu state prevents initial deploy"
assert_contains "${INITIAL_DEPLOY_REASON}" "tofu state is not empty" "reason explains non-empty state"

test_start "RBG-10a" "tofu init failure fails closed — treated as existing deployment"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
remove_prod_ref
export STUB_TOFU_INIT_EXIT=1
export STUB_TOFU_STATE_OUTPUT=""
export STUB_PRESENT_VMIDS=""
run_context
assert_eq "0" "${INITIAL_DEPLOY}" "tofu init failure prevents initial deploy classification"
assert_contains "${INITIAL_DEPLOY_REASON}" "could not initialize tofu state" "reason explains init failure"

test_start "RBG-10b" "tofu state list failure fails closed — treated as existing deployment"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
remove_prod_ref
export STUB_TOFU_STATE_EXIT=1
export STUB_PRESENT_VMIDS=""
run_context
assert_eq "0" "${INITIAL_DEPLOY}" "tofu state list failure prevents initial deploy classification"
assert_contains "${INITIAL_DEPLOY_REASON}" "could not query tofu state" "reason explains state list failure"

test_start "RBG-10c" "SSH probe failure fails closed — treated as existing deployment"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
remove_prod_ref
export STUB_TOFU_STATE_OUTPUT=""
export STUB_SSH_FAIL=1
run_context
assert_eq "0" "${INITIAL_DEPLOY}" "SSH probe failure prevents initial deploy classification"
assert_contains "${INITIAL_DEPLOY_REASON}" "could not probe Proxmox" "reason explains SSH failure"

test_start "RBG-10d" "state empty but VMs found (contradiction) fails closed"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
remove_prod_ref
export STUB_TOFU_STATE_OUTPUT=""
export STUB_PRESENT_VMIDS="150"
run_context
assert_eq "0" "${INITIAL_DEPLOY}" "contradiction prevents initial deploy classification"
assert_contains "${INITIAL_DEPLOY_REASON}" "already exists" "reason explains VM found despite empty state"

test_start "RBG-11" "allow-dirty does not bypass guarded scope"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
ALLOW_DIRTY=1
if run_context; then
  test_fail "allow-dirty should not bypass branch safety"
else
  test_pass "allow-dirty does not bypass branch safety"
fi

test_start "RBG-12" "comparison reports same commit when gitlab/prod matches"
reset_case
checkout_ref dev-same
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
if run_context; then
  test_pass "same-commit override context resolved"
else
  test_fail "same-commit override context should resolve"
fi
comparison_output="$(print_last_known_prod_comparison)"
assert_contains "${comparison_output}" "Current commit matches last known prod commit." "same-commit comparison reports match"

test_start "RBG-13" "comparison warns on differing commit without config diff"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
if run_context; then
  test_pass "different-commit override context resolved"
else
  test_fail "different-commit override context should resolve"
fi
comparison_output="$(print_last_known_prod_comparison)"
assert_contains "${comparison_output}" "WARNING: You are deploying non-prod-branch code to prod VMs." "different commit warning printed"
assert_not_contains "${comparison_output}" "site/config.yaml has changed between your commit and prod." "config divergence warning omitted when config is unchanged"

test_start "RBG-14" "comparison warns when gitlab/prod is missing"
reset_case
checkout_ref dev-no-config
remove_prod_ref
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
if run_context; then
  test_pass "missing-ref override context resolved"
else
  test_fail "missing-ref override context should resolve"
fi
comparison_output="$(print_last_known_prod_comparison)"
assert_contains "${comparison_output}" "WARNING: Last-known-prod comparison unavailable." "missing-ref warning printed"

test_start "RBG-15" "fetch failure is warned but does not refuse"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
export STUB_GIT_FETCH_EXIT=1
export STUB_GIT_FETCH_STDERR="ssh: connect to host gitlab.example port 22: Operation timed out"
if run_context; then
  test_pass "fetch failure did not refuse override run"
else
  test_fail "fetch failure should not refuse override run"
fi
comparison_output="$(print_last_known_prod_comparison)"
assert_contains "${comparison_output}" "WARNING: git fetch gitlab failed: ssh timeout after 5s" "fetch failure warning printed"
assert_contains "${comparison_output}" "Last known prod commit:" "local prod ref comparison still printed after fetch failure"

test_start "RBG-16" "config divergence warning appears only when config changed"
reset_case
checkout_ref dev-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
if run_context; then
  test_pass "config-diff override context resolved"
else
  test_fail "config-diff override context should resolve"
fi
assert_eq "1" "${CONFIG_YAML_DIFF}" "config diff detected"
comparison_output="$(print_last_known_prod_comparison)"
assert_contains "${comparison_output}" "site/config.yaml has changed between your commit and prod." "config divergence warning printed"

test_start "RBG-17" "banner and manifest include Sprint 002 provenance fields"
reset_case
checkout_ref dev-config
SCOPE="control-plane"
OVERRIDE_BRANCH_CHECK=1
if run_context; then
  test_pass "manifest context resolved"
else
  test_fail "manifest context should resolve"
fi
banner_output="$(print_deploy_banner)"
assert_contains "${banner_output}" "Override branch check: yes" "banner shows override status"
assert_contains "${banner_output}" "Last known prod:" "banner shows last-known-prod summary"
manifest_output="$(write_deploy_manifest)"
assert_contains "${manifest_output}" "rebuild-manifest.json" "manifest writer reports output path"
MANIFEST_PATH="${FIXTURE_REPO}/build/rebuild-manifest.json"
assert_jq "${MANIFEST_PATH}" '.impact' 'shared_control_plane' "manifest captures impact"
assert_jq "${MANIFEST_PATH}" '.initial_deploy' 'false' "manifest captures initial deploy flag"
assert_jq "${MANIFEST_PATH}" '.override_branch_check' 'true' "manifest captures override flag"
assert_jq "${MANIFEST_PATH}" '.gitlab_fetch.attempted' 'true' "manifest captures fetch attempt"
assert_jq "${MANIFEST_PATH}" '.last_known_prod.available' 'true' "manifest captures last-known-prod availability"
assert_jq "${MANIFEST_PATH}" '.last_known_prod.differs_from_current' 'true' "manifest captures commit divergence"
assert_jq "${MANIFEST_PATH}" '.last_known_prod.config_yaml_diff' 'true' "manifest captures config divergence"

test_start "RBG-18" "refusal text includes corrective and override commands"
reset_case
checkout_ref dev-no-config
SCOPE="control-plane"
if run_context; then
  test_fail "refusal-text case should be refused"
else
  test_pass "refusal-text case refused as expected"
fi
refusal_output="$(print_branch_safety_refusal)"
assert_contains "${refusal_output}" "Current branch: dev-no-config" "refusal output includes current branch"
assert_contains "${refusal_output}" "Requested scope: control-plane" "refusal output includes scope"
assert_contains "${refusal_output}" "Derived impact: shared_control_plane" "refusal output includes impact class"
assert_contains "${refusal_output}" "git checkout prod && framework/scripts/rebuild-cluster.sh --scope control-plane" "refusal output includes corrective prod command"
assert_contains "${refusal_output}" "--override-branch-check" "refusal output includes DR override path"

runner_summary
