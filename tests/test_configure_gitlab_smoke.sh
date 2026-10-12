#!/usr/bin/env bash
# test_configure_gitlab_smoke.sh — hermetic happy-path execution smoke over
# the REAL framework/scripts/configure-gitlab.sh (#865).
#
# ## Why this file exists
#
# Until the #853 deletion, `configure-gitlab.sh`'s main path was executed
# end to end as a side effect of rotation Step 5b: the rotation fixture
# copied the real script in and the driver aborted on a non-zero child rc,
# so a passing success test proved the real script ran to completion.
# Deleting Step 5b removed that invocation, and with it the ONLY execution
# coverage of Steps 2b-8. The remaining references either install a stub
# (tests/test_converge_vm_scope.sh, tests/lib/rebuild_fixture_helpers.sh)
# or grep statically (tests/test_rotate_scripts_path_only.sh); the one
# fixture that still executes the real script,
# `make_configure_fail_closed_fixture` in tests/test_rotate_gitlab_password.sh,
# exits inside Step 2's fail-closed branch and never reaches Step 2b.
#
# Steps 2b-8 were therefore left with NO CI coverage of any kind. Contrary
# to #865's wording, the script is not even `bash -n`'d: `.gitlab-ci.yml`
# contains no reference to `configure-gitlab.sh` at all. Executing it here
# subsumes a syntax check, so no separate `bash -n` line is added for it.
#
# This test restores the lost coverage directly instead of incidentally.
#
# ## What it asserts (R-G-4: fixtures exercise paths end-to-end)
#
# 1. The real script runs to completion (rc 0) under fully hermetic shims.
# 2. Every step header from Step 1 through Step 8's "Configuration Complete"
#    is emitted, IN ORDER — a step trace, not an inference that "it probably
#    got there".
# 3. Both idempotency arms are driven: `fresh` (nothing exists yet, so every
#    create/POST branch runs, including the two `exit 1` failure branches in
#    Steps 4 and 6b that must NOT fire) and `existing` (everything already
#    exists, so every skip branch runs).
#
# ## The force-push hazard (#865, deliberately not softened)
#
# `framework/scripts/configure-gitlab.sh` force-pushes the current branch on
# its bootstrap path. That behaviour is legitimate there — it seeds a fresh
# GitLab repo — and was only ever a hazard when reachable from rotation. A
# fixture that executes the real script therefore executes a real
# `git push --force` invocation, and must prove it INTERCEPTED it rather
# than quietly letting it reach a remote. Three independent properties give
# that proof:
#
#   a. The `git` shim has no fall-through to a real git binary — no `exec`,
#      no `command git`, no absolute path. An unrecognized invocation exits
#      non-zero and is logged as `git-UNEXPECTED`. Asserted statically below
#      so a later edit cannot quietly add an escape hatch.
#   b. The shim recognizes the push only in its exact expected shape
#      (`--no-verify`, remote `gitlab`, refspec `dev`, `--force`), records
#      the full argv, and logs `git-force-push-intercepted`. Anything else
#      is `git-push-UNEXPECTED` + exit 1.
#   c. The fixture repo is deliberately NOT a git work tree, so even a
#      hypothetical bypass of (a) and (b) fails loudly instead of pushing.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

CONFIGURE_SCRIPT="${REPO_ROOT}/framework/scripts/configure-gitlab.sh"
TMP_DIR="$(mktemp -d -t configure-gitlab-smoke.XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

RUN_OUTPUT=""
RUN_STATUS=0

FIXTURE_PASSWORD="SENTINEL_GITLAB_PASSWORD"
FIXTURE_CI_PUBKEY="ssh-ed25519 AAAAFIXTURECI ci-runner"
FIXTURE_OPERATOR_PUBKEY="ssh-ed25519 AAAAFIXTUREOPERATOR operator"

# Step headers the real script emits, in the order it must emit them.
STEP_TRACE=(
  "=== Step 1: Wait for GitLab ==="
  "=== Step 2: Retrieve root password ==="
  "=== Step 2b: Obtain API access token ==="
  "=== Step 3: Create infrastructure project ==="
  "=== Step 4: Create runner token ==="
  "=== Step 5: Register SSH keys ==="
  "=== Step 6: Push repository to GitLab ==="
  "=== Step 6b: Create branches ==="
  "=== Step 6c: Protect prod branch ==="
  "=== Step 6c2: Require pipeline success for merging ==="
  "=== Step 6d: Create labels ==="
  "=== Step 6e: Create milestones ==="
  "=== Step 6f: Set merge method ==="
  "=== Step 7: Disable telemetry ==="
  "=== Configuration Complete ==="
)

first_line_number() {
  local pattern="$1" file="$2"
  grep -Fn "$pattern" "$file" | head -1 | cut -d: -f1 || true
}

# ---------------------------------------------------------------------------
# Fixture construction
# ---------------------------------------------------------------------------
# mode=fresh    → nothing exists in GitLab yet; every create/POST branch runs.
# mode=existing → project/runner/keys/branches/protection already exist;
#                 every skip branch runs.
make_configure_smoke_fixture() {
  local mode="$1"
  local fixture="${TMP_DIR}/${mode}"
  local repo="${fixture}/repo"
  local shims="${fixture}/shims"

  mkdir -p \
    "${repo}/framework/scripts" \
    "${repo}/site/sops" \
    "$shims" \
    "${fixture}/home/.ssh" \
    "${fixture}/state"

  cp "$CONFIGURE_SCRIPT" "${repo}/framework/scripts/configure-gitlab.sh"
  chmod +x "${repo}/framework/scripts/configure-gitlab.sh"
  printf '%s\n' 'fixture flake' > "${repo}/flake.nix"
  printf '%s\n' 'sops: fixture' > "${repo}/site/sops/secrets.yaml"

  printf '%s\n' "$mode" > "${fixture}/state/mode"
  printf '%s' "$repo" > "${fixture}/state/repo_path"
  printf '%s' "$FIXTURE_PASSWORD" > "${fixture}/state/password"
  printf '%s' "$FIXTURE_CI_PUBKEY" > "${fixture}/state/ci_pubkey"
  printf '%s\n' "$FIXTURE_OPERATOR_PUBKEY" > "${fixture}/home/.ssh/id_ed25519.pub"

  cat > "${repo}/site/config.yaml" <<'EOF'
domain: example.invalid
vms:
  gitlab:
    ip: 10.0.0.50
cicd:
  project_name: infra
EOF

  cat > "${repo}/site/gitlab.yaml" <<'EOF'
labels:
  - name: bug
    color: "#d9534f"
    description: Something is broken
  - name: infra
    color: "#5bc0de"
    description: Infrastructure work
milestones:
  - title: M1
    description: First milestone
EOF

  # --- yq shim -------------------------------------------------------------
  # configure-gitlab.sh calls yq in two argv shapes: `yq -r <expr> <file>`
  # (config.yaml reads) and `yq <expr> <file>` (site/gitlab.yaml reads), so
  # the shim matches on the expression wherever it lands rather than on $2.
  cat > "${shims}/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
expr=""
for arg in "$@"; do
  case "$arg" in
    -r|-e|-o) ;;
    .*) expr="$arg"; break ;;
  esac
done
case "$expr" in
  .vms.gitlab.ip)          printf '%s\n' '10.0.0.50' ;;
  .domain)                 printf '%s\n' 'example.invalid' ;;
  .cicd.project_name)      printf '%s\n' 'infra' ;;
  '.labels | length')      printf '%s\n' '2' ;;
  '.labels[0].name')         printf '%s\n' 'bug' ;;
  '.labels[0].color')        printf '%s\n' '#d9534f' ;;
  '.labels[0].description')  printf '%s\n' 'Something is broken' ;;
  '.labels[1].name')         printf '%s\n' 'infra' ;;
  '.labels[1].color')        printf '%s\n' '#5bc0de' ;;
  '.labels[1].description')  printf '%s\n' 'Infrastructure work' ;;
  '.milestones | length')  printf '%s\n' '1' ;;
  '.milestones[0].title')    printf '%s\n' 'M1' ;;
  '.milestones[0].description') printf '%s\n' 'First milestone' ;;
  *) echo "yq shim: unexpected expression: '${expr}' (argv: $*)" >&2; exit 1 ;;
esac
EOF
  chmod +x "${shims}/yq"

  # --- sops shim -----------------------------------------------------------
  cat > "${shims}/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-d" && "${2:-}" == "--extract" ]]; then
  case "${3:-}" in
    '["gitlab_root_password"]')
      printf 'sops-decrypt|gitlab_root_password\n' >> "$EVENT_LOG"
      cat "${STATE_DIR}/password"
      exit 0
      ;;
    '["ssh_pubkey"]')
      printf 'sops-decrypt|ssh_pubkey\n' >> "$EVENT_LOG"
      cat "${STATE_DIR}/ci_pubkey"
      exit 0
      ;;
  esac
fi
if [[ "${1:-}" == "--set" ]]; then
  # Log only the index, never the value — no decrypted material in evidence.
  printf 'sops-set|%s\n' "${2%% *}" >> "$EVENT_LOG"
  exit 0
fi
echo "sops shim: unexpected args: $*" >&2
exit 1
EOF
  chmod +x "${shims}/sops"

  # --- ssh shim ------------------------------------------------------------
  # The happy path authenticates with the SOPS password (Step 2 scenario 1)
  # and must never SSH to the GitLab VM. The shim exists so a real ssh can
  # never be reached, logs any call, and fails loudly. The test asserts the
  # event log records no `ssh|` line at all.
  cat > "${shims}/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh|%s\n' "$*" >> "$EVENT_LOG"
echo "ssh shim: happy path must not SSH to the GitLab VM: $*" >&2
exit 1
EOF
  chmod +x "${shims}/ssh"

  # --- sleep shim ----------------------------------------------------------
  # Step 1's wait loop is `sleep 15` up to MAX_WAIT=600. On the happy path the
  # sign_in shim answers on the first probe, so sleep is never called. Failing
  # here turns any regression in that probe into an immediate error instead of
  # a ten-minute stall per arm in CI.
  cat > "${shims}/sleep" <<'EOF'
#!/usr/bin/env bash
printf 'sleep|%s\n' "$*" >> "$EVENT_LOG"
echo "sleep shim: happy path must not wait; Step 1's probe did not answer" >&2
exit 1
EOF
  chmod +x "${shims}/sleep"

  cat > "${shims}/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf 'ssh-keygen|%s\n' "$*" >> "$EVENT_LOG"
exit 0
EOF
  chmod +x "${shims}/ssh-keygen"

  cat > "${shims}/ssh-keyscan" <<'EOF'
#!/usr/bin/env bash
printf 'ssh-keyscan|%s\n' "$*" >> "$EVENT_LOG"
printf '%s\n' '10.0.0.50 ssh-ed25519 AAAAFIXTUREHOSTKEY'
exit 0
EOF
  chmod +x "${shims}/ssh-keyscan"

  # --- git shim ------------------------------------------------------------
  # NO fall-through to a real git binary: no `exec`, no `command git`, no
  # absolute path. Every unrecognized invocation is logged and exits 1.
  cat > "${shims}/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
raw_argv="$*"
args=("$@")
dash_c_path=""
if [[ "${args[0]:-}" == "-C" ]]; then
  dash_c_path="${args[1]:-}"
  args=("${args[@]:2}")
fi
mode="$(cat "${STATE_DIR}/mode")"

case "${args[0]:-}:${args[1]:-}:${args[2]:-}" in
  remote:get-url:gitlab)
    printf 'git|remote get-url gitlab\n' >> "$EVENT_LOG"
    if [[ "$mode" == "existing" ]]; then
      printf '%s\n' 'gitlab@10.0.0.50:root/infra.git'
      exit 0
    fi
    exit 1
    ;;
  remote:add:gitlab|remote:set-url:gitlab)
    printf 'git|remote %s gitlab %s\n' "${args[1]}" "${args[3]:-}" >> "$EVENT_LOG"
    exit 0
    ;;
  branch:--show-current:)
    printf 'git|branch --show-current\n' >> "$EVENT_LOG"
    printf '%s\n' 'dev'
    exit 0
    ;;
esac

if [[ "${args[0]:-}" == "push" ]]; then
  # #865 hazard: configure-gitlab.sh legitimately force-pushes here. This
  # shim INTERCEPTS it and asserts its exact shape. It never dispatches to
  # a real git, so the force push cannot escape to a remote.
  #
  # The FULL argv is recorded, including the leading `-C <repo>`: losing or
  # misdirecting `-C "$REPO_DIR"` would push from whatever directory the
  # caller happened to be in, which is a different (and worse) force push.
  printf '%s' "$raw_argv" > "${STATE_DIR}/push_argv"
  printf '%s' "$dash_c_path" > "${STATE_DIR}/push_dash_c"
  has_force=0
  has_no_verify=0
  remote=""
  refspec=""
  idx=1
  while [[ $idx -lt ${#args[@]} ]]; do
    a="${args[$idx]}"
    idx=$((idx + 1))
    case "$a" in
      --force|-f)  has_force=1 ;;
      --no-verify) has_no_verify=1 ;;
      -*)          ;;
      *)
        if [[ -z "$remote" ]]; then remote="$a"; else refspec="$a"; fi
        ;;
    esac
  done
  if [[ "$has_force" -ne 1 || "$has_no_verify" -ne 1 || \
        "$remote" != "gitlab" || "$refspec" != "dev" || \
        "$dash_c_path" != "$(cat "${STATE_DIR}/repo_path")" ]]; then
    printf 'git-push-UNEXPECTED|%s\n' "$raw_argv" >> "$EVENT_LOG"
    echo "git shim: refusing unrecognized push shape: ${raw_argv}" >&2
    exit 1
  fi
  printf 'git-force-push-intercepted|remote=%s|refspec=%s|force=1|no-verify=1|scoped-to-repo=1\n' \
    "$remote" "$refspec" >> "$EVENT_LOG"
  exit 0
fi

printf 'git-UNEXPECTED|%s\n' "$*" >> "$EVENT_LOG"
echo "git shim: unexpected args: $*" >&2
exit 1
EOF
  chmod +x "${shims}/git"

  # --- curl shim -----------------------------------------------------------
  # Answers every endpoint configure-gitlab.sh reaches. Endpoint set and
  # response shapes recovered from 0c4c768:tests/test_rotate_gitlab_password.sh.
  cat > "${shims}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
method="GET"
url=""
output_file=""
write_format=""
data_args=()
headers=()
mode="$(cat "${STATE_DIR}/mode")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -X|--request)                        method="${2:-}"; shift 2 ;;
    -H|--header)                         headers+=("${2:-}"); shift 2 ;;
    -o)                                  output_file="${2:-}"; shift 2 ;;
    -w)                                  write_format="${2:-}"; shift 2 ;;
    --data-urlencode)                    data_args+=("${2:-}"); shift 2 ;;
    -d|--data|--data-raw|--data-binary)  data_args+=("${2:-}"); shift 2 ;;
    --max-time|-m)                       shift 2 ;;
    http://*|https://*)                  url="$1"; shift ;;
    *)                                   shift ;;
  esac
done

write_body() {
  local body="$1"
  if [[ -n "$output_file" ]]; then
    [[ "$output_file" == "/dev/null" ]] || printf '%s' "$body" > "$output_file"
  else
    printf '%s' "$body"
  fi
}

finish_status() {
  local status="$1"
  [[ -n "$write_format" ]] || return 0
  printf '%b' "${write_format//'%{http_code}'/$status}"
}

data_contains() {
  local needle="$1" item
  [[ ${#data_args[@]} -gt 0 ]] || return 1
  for item in "${data_args[@]}"; do
    case "$item" in *"$needle"*) return 0 ;; esac
  done
  return 1
}

respond() {
  printf 'curl|%s|%s|auth=%s\n' "$method" "${url#*://*/}" "$auth_kind" >> "$EVENT_LOG"
  write_body "$1"
  finish_status "$2"
  exit 0
}

# Every request that must carry the Step 2b bearer token, and did not, is a
# contract violation of the fixture — not a scenario. Exiting non-zero makes
# the run fail loudly rather than letting a later marker paper over it.
require_payload() {
  local what="$1"; shift
  local needle
  for needle in "$@"; do
    if ! data_contains "$needle"; then
      printf 'curl-PAYLOAD-VIOLATION|%s|missing=%s\n' "$what" "$needle" >> "$EVENT_LOG"
      echo "curl shim: ${what} payload missing '${needle}' (url=${url})" >&2
      exit 1
    fi
  done
}

require_method() {
  local what="$1" want="$2"
  if [[ "$method" != "$want" ]]; then
    printf 'curl-METHOD-VIOLATION|%s|want=%s|got=%s\n' "$what" "$want" "$method" >> "$EVENT_LOG"
    echo "curl shim: ${what} expected ${want}, got ${method} (url=${url})" >&2
    exit 1
  fi
}

# --- Bearer-token enforcement (Step 2b's token must reach every API call) ---
auth_kind="none"
for header in ${headers[@]+"${headers[@]}"}; do
  case "$header" in
    'Authorization: Bearer SENTINEL_GITLAB_TOKEN') auth_kind="ok" ;;
    'Authorization: Bearer '*)                     auth_kind="wrong" ;;
  esac
done
case "$url" in
  */api/v4/*)
    if [[ "$auth_kind" != "ok" ]]; then
      printf 'curl-AUTH-VIOLATION|%s|%s|auth=%s\n' "$method" "${url#*://*/}" "$auth_kind" >> "$EVENT_LOG"
      write_body '{"message":"401 Unauthorized"}'
      finish_status 401
      exit 0
    fi
    ;;
esac

case "$url" in
  */users/sign_in)
    respond 'Sign in' 200
    ;;
  */oauth/token)
    if data_contains "password=${FIXTURE_PASSWORD}"; then
      respond '{"access_token":"SENTINEL_GITLAB_TOKEN"}' 200
    fi
    respond '{"error":"invalid_grant"}' 401
    ;;
  */api/v4/version)
    respond '{"version":"18.0.0-fixture"}' 200
    ;;
  */api/v4/projects\?search=infra)
    if [[ "$mode" == "existing" ]]; then
      respond '[{"id":1,"name":"infra","path":"infra","default_branch":"main"}]' 200
    fi
    # fresh: Step 3 must see no match and create; Step 6b then resolves the
    # project id from the same endpoint after creation.
    if [[ -f "${STATE_DIR}/project_created" ]]; then
      respond '[{"id":1,"name":"infra","path":"infra","default_branch":"main"}]' 200
    fi
    respond '[]' 200
    ;;
  */api/v4/projects)
    require_method 'project create' POST
    require_payload 'project create' '"name": "infra"' '"visibility": "private"'
    : > "${STATE_DIR}/project_created"
    respond '{"id":1,"web_url":"https://gitlab.example.invalid/root/infra"}' 201
    ;;
  */api/v4/runners/all)
    if [[ "$mode" == "existing" ]]; then
      respond '[{"id":123}]' 200
    fi
    respond '[]' 200
    ;;
  */api/v4/user/runners)
    require_method 'runner create' POST
    require_payload 'runner create' '"runner_type": "instance_type"'
    respond '{"id":9,"token":"glrt-FIXTURE-RUNNER-TOKEN"}' 201
    ;;
  */api/v4/user/keys)
    if [[ "$method" == "POST" ]]; then
      require_payload 'ssh key register' '"key"' '"title"'
      respond '{"id":7}' 201
    fi
    if [[ "$mode" == "existing" ]]; then
      respond "[{\"id\":1,\"title\":\"ci-runner\",\"key\":\"${FIXTURE_CI_PUBKEY}\"},{\"id\":2,\"title\":\"operator\",\"key\":\"${FIXTURE_OPERATOR_PUBKEY}\"}]" 200
    fi
    respond '[]' 200
    ;;
  */api/v4/projects/1/repository/branches\?branch=*)
    require_method 'branch create' POST
    # Step 6b must branch dev off the project default and prod off dev.
    case "$url" in
      *'branch=dev&ref=main')  respond '{"name":"dev"}' 201 ;;
      *'branch=prod&ref=dev')  respond '{"name":"prod"}' 201 ;;
    esac
    printf 'curl-PAYLOAD-VIOLATION|branch create|url=%s\n' "$url" >> "$EVENT_LOG"
    echo "curl shim: branch create with unexpected branch/ref pair: ${url}" >&2
    exit 1
    ;;
  */api/v4/projects/1/repository/branches/dev)
    [[ "$mode" == "existing" ]] && respond '{"name":"dev"}' 200
    respond '{"message":"404 Branch Not Found"}' 404
    ;;
  */api/v4/projects/1/repository/branches/prod)
    [[ "$mode" == "existing" ]] && respond '{"name":"prod"}' 200
    respond '{"message":"404 Branch Not Found"}' 404
    ;;
  */api/v4/projects/1/protected_branches/prod)
    [[ "$mode" == "existing" ]] && respond '{"name":"prod"}' 200
    respond '{"message":"404 Not Found"}' 404
    ;;
  */api/v4/projects/1/protected_branches)
    require_method 'prod branch protection' POST
    # push=no one (0), merge=maintainers (40) — the MR-only prod contract.
    require_payload 'prod branch protection' \
      'name=prod' 'push_access_level=0' 'merge_access_level=40'
    respond '{"name":"prod"}' 201
    ;;
  */api/v4/projects/1/labels)
    require_method 'label create' POST
    require_payload 'label create' 'name=' 'color=' 'description='
    respond '{"id":11,"name":"fixture-label"}' 201
    ;;
  */api/v4/projects/1/milestones)
    require_method 'milestone create' POST
    require_payload 'milestone create' 'title=' 'description='
    respond '{"id":21,"title":"M1"}' 201
    ;;
  */api/v4/projects/1)
    if [[ "$method" == "PUT" ]]; then
      if data_contains 'merge_method=ff'; then
        respond '{"id":1,"merge_method":"ff"}' 200
      fi
      require_payload 'pipeline-success merge gate' \
        'only_allow_merge_if_pipeline_succeeds=true'
      respond '{"id":1,"only_allow_merge_if_pipeline_succeeds":true}' 200
    fi
    respond '{"id":1,"default_branch":"main","merge_method":"ff"}' 200
    ;;
  */api/v4/application/settings)
    require_method 'telemetry disable' PUT
    require_payload 'telemetry disable' \
      'usage_ping_enabled=false' 'version_check_enabled=false' \
      'gitlab_product_usage_data_enabled=false' \
      'include_optional_metrics_in_service_ping=false'
    respond '{"usage_ping_enabled":false,"version_check_enabled":false,"gitlab_product_usage_data_enabled":false,"include_optional_metrics_in_service_ping":false}' 200
    ;;
esac

echo "curl shim: unexpected request: method=${method} url=${url}" >&2
exit 1
EOF
  chmod +x "${shims}/curl"

  : > "${fixture}/events.log"
  printf '%s\n' "$fixture"
}

run_configure() {
  local fixture="$1"
  local repo="${fixture}/repo"

  : > "${fixture}/events.log"
  set +e
  # `env -i` clears stray operator/CI variables, but PATH must INHERIT the
  # ambient one with the shims prepended. A hardcoded /usr/bin:/bin has no
  # bash, jq, or curl on the NixOS cicd runner, whose job PATH is supplied by
  # `path = with pkgs; [ ... ]` in framework/nix/modules/gitlab-runner.nix —
  # the script's own prerequisite loop would then fail before Step 1.
  # Shims come first, so interception is unaffected by what follows.
  RUN_OUTPUT="$(
    env -i \
      PATH="${fixture}/shims:${PATH}" \
      HOME="${fixture}/home" \
      EVENT_LOG="${fixture}/events.log" \
      STATE_DIR="${fixture}/state" \
      FIXTURE_PASSWORD="$FIXTURE_PASSWORD" \
      FIXTURE_CI_PUBKEY="$FIXTURE_CI_PUBKEY" \
      FIXTURE_OPERATOR_PUBKEY="$FIXTURE_OPERATOR_PUBKEY" \
      bash -c 'cd "$1" && framework/scripts/configure-gitlab.sh' bash "$repo" 2>&1
  )"
  RUN_STATUS=$?
  set -e
}

assert_step_trace() {
  local label="$1" trace_file="$2"
  local prev=0 line missing="" out_of_order="" step

  for step in "${STEP_TRACE[@]}"; do
    line="$(first_line_number "$step" "$trace_file")"
    if [[ -z "$line" ]]; then
      missing="${missing}${step}; "
      continue
    fi
    if [[ "$line" -le "$prev" ]]; then
      out_of_order="${out_of_order}${step}; "
    fi
    prev="$line"
  done

  if [[ -n "$missing" ]]; then
    test_fail "${label}: step headers never emitted: ${missing}"
    return 1
  fi
  if [[ -n "$out_of_order" ]]; then
    test_fail "${label}: step headers emitted out of order: ${out_of_order}"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Arm 1: fresh — every create/POST branch runs
# ---------------------------------------------------------------------------
FRESH_FIXTURE="$(make_configure_smoke_fixture fresh)"
run_configure "$FRESH_FIXTURE"
FRESH_OUTPUT="$RUN_OUTPUT"
FRESH_STATUS="$RUN_STATUS"
FRESH_EVENTS="${FRESH_FIXTURE}/events.log"
printf '%s\n' "$FRESH_OUTPUT" > "${FRESH_FIXTURE}/output.log"

test_start "865-fresh-completes" "real configure-gitlab.sh runs to completion on a fresh GitLab"
if [[ "$FRESH_STATUS" -eq 0 ]]; then
  test_pass "configure-gitlab.sh exited 0 (fresh arm)"
else
  test_fail "configure-gitlab.sh exited ${FRESH_STATUS} on the fresh arm"
  printf '%s\n' "$FRESH_OUTPUT" >&2
fi

test_start "865-fresh-step-trace" "Steps 1-8 each emit their header, in order (step trace, not inference)"
if assert_step_trace "fresh" "${FRESH_FIXTURE}/output.log"; then
  test_pass "all ${#STEP_TRACE[@]} step headers present and ordered (fresh arm)"
else
  printf '%s\n' "$FRESH_OUTPUT" >&2
fi

test_start "865-fresh-create-branches" "create/POST branches of Steps 3, 4, 5, 6b, 6c all execute"
FRESH_MISSING=""
for marker in \
  "Creating project 'infra'" \
  "Creating a new runner via the API" \
  "Runner token obtained" \
  "Registering ci-runner key" \
  "Registering operator key" \
  "Created branch 'dev' from 'main'" \
  "Created branch 'prod' from 'dev'" \
  "Branch 'prod' protected"; do
  grep -Fq "$marker" <<< "$FRESH_OUTPUT" || FRESH_MISSING="${FRESH_MISSING}${marker}; "
done
if [[ -z "$FRESH_MISSING" ]] &&
   grep -Fq 'sops-set|["gitlab_runner_registration_token"]' "$FRESH_EVENTS"; then
  test_pass "project/runner/keys/branches/protection creation paths executed and runner token stored"
else
  test_fail "fresh arm did not exercise every create branch: ${FRESH_MISSING:-<runner token not stored in SOPS>}"
  printf '%s\n' "$FRESH_OUTPUT" >&2
  cat "$FRESH_EVENTS" >&2
fi

test_start "865-fresh-labels-milestones-telemetry" "Steps 6d/6e/6f/7 process their payloads rather than skipping"
if grep -Fq '  Created: bug' <<< "$FRESH_OUTPUT" &&
   grep -Fq '  Created: infra' <<< "$FRESH_OUTPUT" &&
   grep -Fq '  2 labels processed' <<< "$FRESH_OUTPUT" &&
   grep -Fq '  Created: M1' <<< "$FRESH_OUTPUT" &&
   grep -Fq '  1 milestones processed' <<< "$FRESH_OUTPUT" &&
   grep -Fq '  Merge method set to fast-forward' <<< "$FRESH_OUTPUT" &&
   grep -Fq '  All telemetry disabled.' <<< "$FRESH_OUTPUT"; then
  test_pass "labels created, milestones created, merge method ff, telemetry disabled"
else
  test_fail "Steps 6d/6e/6f/7 did not report their success shapes"
  printf '%s\n' "$FRESH_OUTPUT" >&2
fi

test_start "865-step2b-token-reaches-every-api-call" "Step 2b's bearer token authorizes every downstream /api/v4 call"
FRESH_AUTH_OK="$(grep -Fc '|auth=ok' "$FRESH_EVENTS" || true)"
if [[ "$FRESH_AUTH_OK" -ge 10 ]] &&
   ! grep -Fq 'curl-AUTH-VIOLATION' "$FRESH_EVENTS" &&
   ! grep -Fq 'curl-METHOD-VIOLATION' "$FRESH_EVENTS" &&
   ! grep -Fq 'curl-PAYLOAD-VIOLATION' "$FRESH_EVENTS"; then
  test_pass "${FRESH_AUTH_OK} API calls carried the Step 2b token; no method/payload contract violations"
else
  test_fail "API auth/method/payload contract violated (authorized calls=${FRESH_AUTH_OK})"
  cat "$FRESH_EVENTS" >&2
fi

# --- The #865 force-push hazard -------------------------------------------
test_start "865-force-push-intercepted" "Step 6's force push is intercepted and shape-asserted by the shim"
FRESH_PUSH_ARGV="$(cat "${FRESH_FIXTURE}/state/push_argv" 2>/dev/null || true)"
FRESH_PUSH_DASH_C="$(cat "${FRESH_FIXTURE}/state/push_dash_c" 2>/dev/null || true)"
FORCE_HITS="$(grep -Fc 'git-force-push-intercepted|remote=gitlab|refspec=dev|force=1|no-verify=1|scoped-to-repo=1' "$FRESH_EVENTS" || true)"
if [[ "$FORCE_HITS" == "1" ]] &&
   [[ "$FRESH_PUSH_ARGV" == "-C ${FRESH_FIXTURE}/repo push --no-verify gitlab dev --force" ]] &&
   [[ "$FRESH_PUSH_DASH_C" == "${FRESH_FIXTURE}/repo" ]] &&
   ! grep -Fq 'git-push-UNEXPECTED' "$FRESH_EVENTS" &&
   ! grep -Fq 'git-UNEXPECTED' "$FRESH_EVENTS"; then
  test_pass "shim caught exactly one force push, scoped to the fixture repo, argv='${FRESH_PUSH_ARGV}'"
else
  test_fail "force push was not intercepted in the expected shape (hits=${FORCE_HITS}, argv='${FRESH_PUSH_ARGV}')"
  cat "$FRESH_EVENTS" >&2
fi

test_start "865-git-shim-has-no-real-git-escape" "the git shim cannot dispatch to a real git binary"
GIT_SHIM="${FRESH_FIXTURE}/shims/git"
if [[ -x "$GIT_SHIM" ]] &&
   ! grep -Eq '(^|[^-[:alnum:]_])(exec|command)[[:space:]]+git([^-[:alnum:]_]|$)' "$GIT_SHIM" &&
   ! grep -Eq '/(usr/)?(local/)?bin/git([^-[:alnum:]_]|$)' "$GIT_SHIM"; then
  test_pass "git shim has no exec/command/absolute-path fall-through to a real git"
else
  test_fail "git shim contains a path that could reach a real git binary"
fi

test_start "865-fixture-repo-is-not-a-work-tree" "a bypassed shim would fail loudly, not push to a real remote"
if [[ ! -e "${FRESH_FIXTURE}/repo/.git" ]]; then
  test_pass "fixture repo has no .git — a real 'git push' there cannot reach a remote"
else
  test_fail "fixture repo is a git work tree; a shim bypass could reach a real remote"
fi

test_start "865-no-ssh-no-sleep-on-happy-path" "the happy path never SSHes to the GitLab VM and never waits in Step 1"
if ! grep -q '^ssh|' "$FRESH_EVENTS" && ! grep -q '^sleep|' "$FRESH_EVENTS"; then
  test_pass "no ssh and no sleep recorded (Step 2 took the SOPS-verified branch; Step 1 answered first probe)"
else
  test_fail "happy path invoked ssh and/or slept in Step 1's wait loop"
  grep -E '^(ssh|sleep)\|' "$FRESH_EVENTS" >&2
fi

# ---------------------------------------------------------------------------
# Arm 2: existing — every idempotent skip branch runs
# ---------------------------------------------------------------------------
EXISTING_FIXTURE="$(make_configure_smoke_fixture existing)"
run_configure "$EXISTING_FIXTURE"
EXISTING_OUTPUT="$RUN_OUTPUT"
EXISTING_STATUS="$RUN_STATUS"
EXISTING_EVENTS="${EXISTING_FIXTURE}/events.log"
printf '%s\n' "$EXISTING_OUTPUT" > "${EXISTING_FIXTURE}/output.log"

test_start "865-existing-completes" "re-running against an already-configured GitLab is idempotent and exits 0"
if [[ "$EXISTING_STATUS" -eq 0 ]]; then
  test_pass "configure-gitlab.sh exited 0 (existing arm)"
else
  test_fail "configure-gitlab.sh exited ${EXISTING_STATUS} on the existing arm"
  printf '%s\n' "$EXISTING_OUTPUT" >&2
fi

test_start "865-existing-step-trace" "Steps 1-8 each emit their header, in order, on the skip path too"
if assert_step_trace "existing" "${EXISTING_FIXTURE}/output.log"; then
  test_pass "all ${#STEP_TRACE[@]} step headers present and ordered (existing arm)"
else
  printf '%s\n' "$EXISTING_OUTPUT" >&2
fi

test_start "865-existing-skip-branches" "Steps 3, 4, 5, 6b, 6c all take their already-exists branch"
EXISTING_MISSING=""
for marker in \
  "Project 'infra' already exists — skipping" \
  "Runner already registered (ID: 123) — skipping token creation" \
  "ci-runner key already registered — skipping" \
  "operator key already registered — skipping" \
  "Branch 'dev' already exists" \
  "Branch 'prod' already exists" \
  "Branch 'prod' already protected"; do
  grep -Fq "$marker" <<< "$EXISTING_OUTPUT" || EXISTING_MISSING="${EXISTING_MISSING}${marker}; "
done
if [[ -z "$EXISTING_MISSING" ]] &&
   ! grep -Fq 'sops-set|["gitlab_runner_registration_token"]' "$EXISTING_EVENTS"; then
  test_pass "every idempotent skip branch executed and no runner token was re-stored"
else
  test_fail "existing arm did not exercise every skip branch: ${EXISTING_MISSING:-<runner token re-stored on a no-op run>}"
  printf '%s\n' "$EXISTING_OUTPUT" >&2
  cat "$EXISTING_EVENTS" >&2
fi

test_start "865-existing-force-push-intercepted" "Step 6 still force-pushes on the idempotent path, and is still intercepted"
EXISTING_PUSH_ARGV="$(cat "${EXISTING_FIXTURE}/state/push_argv" 2>/dev/null || true)"
if grep -Fq 'git-force-push-intercepted|remote=gitlab|refspec=dev|force=1|no-verify=1|scoped-to-repo=1' "$EXISTING_EVENTS" &&
   [[ "$EXISTING_PUSH_ARGV" == "-C ${EXISTING_FIXTURE}/repo push --no-verify gitlab dev --force" ]] &&
   grep -Fq 'git|remote set-url gitlab' "$EXISTING_EVENTS" &&
   ! grep -Fq 'git-UNEXPECTED' "$EXISTING_EVENTS" &&
   ! grep -Fq 'curl-AUTH-VIOLATION' "$EXISTING_EVENTS"; then
  test_pass "existing remote was re-pointed via set-url and the force push was intercepted"
else
  test_fail "existing arm did not intercept the force push in the expected shape (argv='${EXISTING_PUSH_ARGV}')"
  cat "$EXISTING_EVENTS" >&2
fi

runner_summary
