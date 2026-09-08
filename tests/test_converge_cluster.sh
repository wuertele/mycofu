#!/usr/bin/env bash
# Hermetic test for framework/scripts/converge-cluster.sh (#358).
#
# The script enumerates safe-to-apply tofu resources, plans, and applies
# (or skips with --dry-run). We test the orchestration logic with a
# shimmed tofu-wrapper.sh that returns canned state-list / plan outputs
# and records every invocation.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

source "${REPO_ROOT}/tests/lib/runner.sh"

SCRIPT="${REPO_ROOT}/framework/scripts/converge-cluster.sh"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- TC0: bash syntax + script header anchors ---------------------------

test_start "TC0" "converge-cluster.sh parses"
if bash -n "$SCRIPT" 2>/tmp/converge-syntax.err; then
  test_pass "TC0a: bash -n passed"
else
  test_fail "TC0a: bash -n failed"
  cat /tmp/converge-syntax.err | sed 's/^/    /'
fi

test_start "TC0b" "Phase A selects by content_type=snippets and requires --env"
if grep -q 'SNIPPET_CONTENT_TYPE="snippets"' "$SCRIPT" \
   && grep -q 'content_type' "$SCRIPT" \
   && grep -q 'deployable-modules' "$SCRIPT" \
   && grep -qE '\-\-env <dev\|prod> is required' "$SCRIPT"; then
  test_pass "TC0b: content_type/vm-scope selection + required --env present"
else
  test_fail "TC0b: env-scoped snippet selection markers missing"
fi

test_start "TC0c" "control plane is dev-authoritative (control-plane-modules added for --env dev only)"
# Structural anchor for the #623 extension: converge-cluster.sh must augment
# the dev allowed set with vm-scope.sh control-plane-modules, gated on --env dev.
if grep -q 'control-plane-modules' "$SCRIPT" \
   && grep -qE 'if \[\[ "\$ENV" == "dev" \]\]' "$SCRIPT"; then
  test_pass "TC0c: control-plane-modules augmentation gated on --env dev present"
else
  test_fail "TC0c: dev-authoritative control-plane augmentation marker missing"
fi

# --- Test harness -------------------------------------------------------

# Each scenario sets up a fresh fixture: a fake REPO_DIR with a shim
# tofu-wrapper.sh under framework/scripts. The shim records every
# invocation to a log file and returns canned output based on env vars:
#   STUB_STATE_LIST  : what `tofu-wrapper.sh state list` prints
#   STUB_STATE_RC    : exit code for the state list call (default 0)
#   STUB_PLAN_OUT    : what `tofu-wrapper.sh plan ...` prints
#   STUB_PLAN_RC     : exit code for the plan call (default 0)
#   STUB_APPLY_RC    : exit code for the apply call (default 0)

setup_fixture() {
  FX="${TMP_DIR}/fx-$$-$RANDOM"
  FX_REPO="${FX}/repo"
  FX_SCRIPTS="${FX_REPO}/framework/scripts"
  FX_SITE="${FX_REPO}/site"
  FX_BIN="${FX}/bin"
  LOG="${FX}/log"
  SSH_LOG="${FX}/ssh.log"
  mkdir -p "$FX_SCRIPTS" "$FX_SITE" "$FX_BIN"
  : > "$LOG"
  : > "$SSH_LOG"

  cp "$SCRIPT" "${FX_SCRIPTS}/converge-cluster.sh"
  chmod +x "${FX_SCRIPTS}/converge-cluster.sh"

  # Fixture site/config.yaml — Phase B reads it for node enumeration.
  cat > "${FX_SITE}/config.yaml" <<'EOF'
nodes:
  - name: pve01
    mgmt_ip: 10.0.0.1
  - name: pve02
    mgmt_ip: 10.0.0.2
  - name: pve03
    mgmt_ip: 10.0.0.3
EOF

  # Phase A env-scoping (#529) calls the REAL vm-scope.sh deployable-modules
  # against these synthetic manifests, so converge scope == deploy scope is
  # tested end-to-end (not against a shimmed classifier). The taxonomy below
  # declares exactly the modules the test JSONs reference; any OTHER module
  # in state is undeclared -> vm-scope fails -> converge fails closed.
  cp "${REPO_ROOT}/framework/scripts/vm-scope.sh" "${FX_SCRIPTS}/vm-scope.sh"
  chmod +x "${FX_SCRIPTS}/vm-scope.sh"
  cat > "${FX_REPO}/framework/images.yaml" <<'EOF'
roles:
  testapp:     {category: nix, scope: env-bound, control_plane: false}
  vault:       {category: nix, scope: env-bound, control_plane: false}
  workstation: {category: nix, scope: env-bound, control_plane: false}
  gatus:       {category: nix, scope: prod-only, control_plane: false}
  gitlab:      {category: nix, scope: prod-only, control_plane: true}
  cicd:        {category: nix, scope: shared,    control_plane: true}
  hil_boot:    {category: nix, scope: shared,    control_plane: false}
non_built_roles:
  pbs:         {category: vendor, scope: shared, control_plane: true}
EOF
  cat > "${FX_REPO}/site/images.yaml" <<'EOF'
roles: {}
non_built_roles: {}
EOF

  cat > "${FX_SCRIPTS}/tofu-wrapper.sh" <<EOF
#!/usr/bin/env bash
# Shim tofu-wrapper for converge-cluster.sh tests.
printf 'tofu-wrapper.sh %s\n' "\$*" >> "$LOG"
case "\${1:-}" in
  state)
    case "\${2:-}" in
      list)
        printf '%s\n' "\${STUB_STATE_LIST:-}"
        exit "\${STUB_STATE_RC:-0}"
        ;;
    esac
    ;;
  plan)
    printf '%s\n' "\${STUB_PLAN_OUT:-No changes.}"
    exit "\${STUB_PLAN_RC:-0}"
    ;;
  apply)
    exit "\${STUB_APPLY_RC:-0}"
    ;;
  show)
    # Phase B uses 'show -json' to extract expected (node, file_name)
    # snippet pairs. The script strips a preamble before the first '{'
    # so wrappers can prepend "Decrypting secrets..." etc; we mirror
    # that by including a preamble line.
    #
    # STUB_SHOW_JSON is a JSON document that the script will jq through.
    # Default = empty values structure → no expected snippets.
    # NOTE: bash brace-matching in \${VAR:-default} is broken when the
    # default contains literal "\\\"" — use an explicit if/else instead.
    if [[ "\${2:-}" == "-json" ]]; then
      printf 'Decrypting secrets...\n'
      if [[ -n "\${STUB_SHOW_JSON:-}" ]]; then
        printf '%s\n' "\$STUB_SHOW_JSON"
      else
        printf '%s\n' '{"values":{"root_module":{}}}'
      fi
      exit "\${STUB_SHOW_RC:-0}"
    fi
    ;;
esac
exit 0
EOF
  chmod +x "${FX_SCRIPTS}/tofu-wrapper.sh"

  # ssh shim — Phase B's snippet enumeration + orphan deletion.
  # STUB_SSH_LS_<lastoctet>="file1.yaml file2.yaml" controls what `ls`
  # returns for a node. STUB_SSH_RM_FAIL=1 makes rm calls fail.
  # STUB_SSH_LS_FAIL_<lastoctet>=1 makes the ls call fail (rc=255).
  cat > "${FX_BIN}/ssh" <<EOF
#!/usr/bin/env bash
# Args: <opts...> root@<ip> <remote command...>
# Find the root@ argument among "\$@" and extract host info.
HOST_ARG=""
for a in "\$@"; do
  case "\$a" in
    root@*) HOST_ARG="\$a"; break;;
  esac
done
if [[ -z "\$HOST_ARG" ]]; then
  echo "shim ssh: no root@host argument" >&2
  exit 99
fi
HOST_IP="\${HOST_ARG#root@}"
HOST_LAST="\${HOST_IP##*.}"

# Remote command is the LAST positional arg.
REMOTE_CMD="\${!#}"
printf 'ssh root@%s :: %s\n' "\$HOST_IP" "\$REMOTE_CMD" >> "$SSH_LOG"

case "\$REMOTE_CMD" in
  *"ls *.yaml"*|*"ls \\*.yaml"*)
    FAIL_VAR="STUB_SSH_LS_FAIL_\${HOST_LAST}"
    if [[ "\${!FAIL_VAR:-0}" == "1" ]]; then
      exit 255
    fi
    LIST_VAR="STUB_SSH_LS_\${HOST_LAST}"
    printf '%s\n' "\${!LIST_VAR:-}" | tr ' ' '\n' | grep -v '^\$' || true
    exit 0
    ;;
  rm*"/var/lib/vz/snippets/"*)
    if [[ "\${STUB_SSH_RM_FAIL:-0}" == "1" ]]; then
      echo "shim rm: forced failure" >&2
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "${FX_BIN}/ssh"
}

# run_converge injects `--env dev` by default so existing single-env tests
# stay concise. Override with CONVERGE_ENV=prod to run a prod scope, or
# CONVERGE_ENV=none to run with NO --env (the required-arg failure path).
run_converge() {
  local args=()
  case "${CONVERGE_ENV:-dev}" in
    none) : ;;  # deliberately omit --env
    *)    args=(--env "${CONVERGE_ENV:-dev}") ;;
  esac
  args+=("$@")
  # ${args[@]+...} guards empty-array expansion under `set -u` on bash 3.2
  # (macOS default), which the no-arg TC22 case would otherwise trip.
  OUT="$(PATH="${FX_BIN}:$PATH" bash "${FX_SCRIPTS}/converge-cluster.sh" ${args[@]+"${args[@]}"} 2>&1)"
  RC=$?
}

# mk_show_json builds a `tofu show -json` document from resource specs.
# Each arg is "MODULE|NODE|FILE|CONTENT_TYPE[|TYPE]":
#   - CONTENT_TYPE of "NONE" omits the content_type field entirely (used to
#     test the missing-content_type fail-closed path).
#   - TYPE defaults to proxmox_virtual_environment_file.
# The single module segment (module.<MODULE>.<TYPE>...) is enough for the
# classifier: root-module = first module segment either way.
mk_show_json() {
  python3 - "$@" <<'PY'
import json, sys
resources = []
for i, spec in enumerate(sys.argv[1:]):
    parts = (spec.split("|") + [""] * 5)[:5]
    mod, node, file, ct, rtype = parts
    if not rtype:
        rtype = "proxmox_virtual_environment_file"
    # Unique resource name per spec so distinct resources get distinct
    # addresses (root-module classification uses only the first segment).
    addr = 'module.%s.%s.res%d["%s"]' % (mod, rtype, i, node)
    values = {"node_name": node, "file_name": file}
    if ct != "NONE":
        values["content_type"] = ct
    resources.append({"address": addr, "type": rtype, "values": values})
doc = {"values": {"root_module": {"child_modules": [{"resources": resources}]}}}
print(json.dumps(doc))
PY
}

# --- TC1: empty state — nothing to converge -----------------------------

test_start "TC1" "empty state → Phase A no-op, Phase B reports no orphans, rc=0"
setup_fixture
# Default STUB_SHOW_JSON ('{"values":{"root_module":{}}}') has no snippet
# resources → Phase A no-op.
run_converge
if [[ $RC -eq 0 ]]; then
  test_pass "TC1a: rc=0"
else
  test_fail "TC1a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -q "Phase A is a no-op" <<<"$OUT"; then
  test_pass "TC1b: 'Phase A is a no-op' diagnostic printed"
else
  test_fail "TC1b: 'Phase A is a no-op' message missing"
fi
if grep -qE 'tofu-wrapper.sh plan' "$LOG"; then
  test_fail "TC1c: plan was called despite empty state"
  cat "$LOG" | sed 's/^/    /'
else
  test_pass "TC1c: plan NOT called (correct: nothing to plan)"
fi
if grep -qE 'tofu-wrapper.sh apply' "$LOG"; then
  test_fail "TC1d: apply was called despite empty state"
else
  test_pass "TC1d: apply NOT called"
fi
# Phase B still runs and finds no orphans on any node.
if [[ $(grep -c 'no orphan snippets' <<<"$OUT") -eq 3 ]]; then
  test_pass "TC1e: Phase B ran on all 3 nodes, all clean"
else
  test_fail "TC1e: Phase B did not run on all 3 nodes cleanly"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# --- TC2: dev-allowed snippet, plan rc=0 (detailed-exitcode no-op) -------
#
# tofu -detailed-exitcode returns 0 when there are no changes. The script
# must treat that as "converged, exit 0" without calling apply.

test_start "TC2" "dev-allowed snippet, plan rc=0 (detailed-exitcode) → skip apply, rc=0"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json \
  'testapp_dev|pve01|testapp-user-data.yaml|snippets' \
  'testapp_dev|pve02|testapp-meta-data.yaml|snippets')" \
  STUB_PLAN_OUT="No changes. Your infrastructure matches the configuration." \
  STUB_PLAN_RC=0 \
  STUB_SSH_LS_1="testapp-user-data.yaml" \
  STUB_SSH_LS_2="testapp-meta-data.yaml" \
  run_converge
if [[ $RC -eq 0 ]]; then
  test_pass "TC2a: rc=0"
else
  test_fail "TC2a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -q "Phase A: no additive changes needed" <<<"$OUT"; then
  test_pass "TC2b: 'Phase A: no additive changes needed' diagnostic printed"
else
  test_fail "TC2b: Phase A 'no additive changes' message missing"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'tofu-wrapper.sh apply' "$LOG"; then
  test_fail "TC2c: apply was called despite no-changes plan"
else
  test_pass "TC2c: apply NOT called (correct: plan said no changes)"
fi

# --- TC3: drift, plan says '1 to add' → apply called with all targets ----
#
# STUB_PLAN_RC=2 mirrors tofu's -detailed-exitcode contract: rc=2 means
# "changes pending." The script branches on that to fall through to apply.

test_start "TC3" "dev drift (plan rc=2) → apply called with all dev targets"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json \
  'testapp_dev|pve01|testapp-user-data.yaml|snippets' \
  'testapp_dev|pve02|testapp-meta-data.yaml|snippets' \
  'testapp_dev|pve03|testapp-user-data.yaml|snippets')" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  STUB_SSH_LS_1="testapp-user-data.yaml" \
  STUB_SSH_LS_2="testapp-meta-data.yaml" \
  STUB_SSH_LS_3="testapp-user-data.yaml" \
  run_converge
if [[ $RC -eq 0 ]]; then
  test_pass "TC3a: rc=0 on successful apply"
else
  test_fail "TC3a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'tofu-wrapper.sh apply' "$LOG"; then
  test_pass "TC3b: apply was called"
else
  test_fail "TC3b: apply was NOT called despite drift"
  cat "$LOG" | sed 's/^/    /'
fi
APPLY_LINE=$(grep -E 'tofu-wrapper.sh apply' "$LOG" | head -1)
TARGET_COUNT=$(grep -oE '\-target=[^ ]+' <<<"$APPLY_LINE" | wc -l | tr -d ' ')
if [[ "$TARGET_COUNT" -eq 3 ]]; then
  test_pass "TC3c: apply included 3 -target= flags (one per snippet resource)"
else
  test_fail "TC3c: expected 3 -target= flags, got $TARGET_COUNT"
  echo "    APPLY: $APPLY_LINE"
fi
if grep -q "Cluster converged" <<<"$OUT"; then
  test_pass "TC3d: 'Cluster converged' success message printed"
else
  test_fail "TC3d: success message missing"
fi

# --- TC4: --dry-run mode → plan called, apply skipped -------------------

test_start "TC4" "--dry-run with drift (plan rc=2) → plan called, apply NOT called, rc=0"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json 'testapp_dev|pve01|testapp-user-data.yaml|snippets')" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  STUB_SSH_LS_1="testapp-user-data.yaml" \
  run_converge --dry-run
if [[ $RC -eq 0 ]]; then
  test_pass "TC4a: rc=0 in dry-run mode"
else
  test_fail "TC4a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'tofu-wrapper.sh plan' "$LOG"; then
  test_pass "TC4b: plan was called"
else
  test_fail "TC4b: plan NOT called in dry-run"
fi
if grep -qE 'tofu-wrapper.sh apply' "$LOG"; then
  test_fail "TC4c: apply was called despite --dry-run"
else
  test_pass "TC4c: apply NOT called (correct: --dry-run)"
fi
if grep -q "DRY RUN" <<<"$OUT"; then
  test_pass "TC4d: 'DRY RUN' diagnostic printed"
else
  test_fail "TC4d: 'DRY RUN' message missing"
fi

# --- TC5: file resource missing content_type → fail-closed --------------
#
# #529/#360 fail-closed: a proxmox_virtual_environment_file with no
# content_type cannot be classified snippet-vs-non-snippet. The script must
# refuse rather than guess, and must not call plan/apply.

test_start "TC5" "file resource missing content_type → rc=1, no plan/apply"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json \
  'testapp_dev|pve01|testapp-user-data.yaml|snippets' \
  'testapp_dev|pve01|mystery-file.yaml|NONE')" \
  STUB_PLAN_RC=2 \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC5a: missing content_type → rc=$RC (non-zero)"
else
  test_fail "TC5a: missing content_type swallowed (rc=0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -q 'content_type' <<<"$OUT" && grep -q 'missing' <<<"$OUT"; then
  test_pass "TC5b: error names the missing content_type condition"
else
  test_fail "TC5b: error did not mention content_type"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'tofu-wrapper.sh plan|tofu-wrapper.sh apply' "$LOG"; then
  test_fail "TC5c: plan or apply was called despite missing content_type"
  cat "$LOG" | sed 's/^/    /'
else
  test_pass "TC5c: plan and apply NOT called (correct: fail-closed)"
fi

# --- TC6: plan fails → script exits non-zero, apply NOT called ----------

test_start "TC6" "plan fails → non-zero exit, apply NOT called"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json 'testapp_dev|pve01|testapp-user-data.yaml|snippets')" \
  STUB_PLAN_OUT="Error: provider down" STUB_PLAN_RC=1 \
  STUB_SSH_LS_1="testapp-user-data.yaml" \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC6a: plan failure → rc=$RC (non-zero)"
else
  test_fail "TC6a: plan failure swallowed (rc=0)"
fi
if grep -qE 'tofu plan failed' <<<"$OUT"; then
  test_pass "TC6b: error message names plan as the failure"
else
  test_fail "TC6b: error message did not name plan"
fi
if grep -qE 'tofu-wrapper.sh apply' "$LOG"; then
  test_fail "TC6c: apply was called despite plan failure"
  cat "$LOG" | sed 's/^/    /'
else
  test_pass "TC6c: apply NOT called (correct: plan failed)"
fi

# --- TC7: apply fails → script exits with apply's rc --------------------

test_start "TC7" "apply fails → exit code matches apply's rc"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json 'testapp_dev|pve01|testapp-user-data.yaml|snippets')" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  STUB_APPLY_RC=7 \
  STUB_SSH_LS_1="testapp-user-data.yaml" \
  run_converge
if [[ $RC -eq 7 ]]; then
  test_pass "TC7a: apply rc=7 propagated"
elif [[ $RC -ne 0 ]]; then
  test_pass "TC7a: apply failure → rc=$RC (non-zero; expected 7)"
else
  test_fail "TC7a: apply failure swallowed (rc=0)"
fi
if grep -qE 'tofu apply failed' <<<"$OUT"; then
  test_pass "TC7b: error message names apply as the failure"
else
  test_fail "TC7b: error message did not name apply"
fi

# --- TC8: VM resources are NEVER targeted (structural type check) -------
#
# Selection is now by JSON type + content_type, not address grepping. A
# proxmox_virtual_environment_vm resource has no content_type=snippets, so it
# is structurally excluded from Phase A even when it shares a module with a
# real snippet.

test_start "TC8" "VM resources in state are EXCLUDED from targets"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json \
  'testapp_dev|pve01|testapp-vm|NONE|proxmox_virtual_environment_vm' \
  'testapp_dev|pve01|testapp-user-data.yaml|snippets' \
  'testapp_dev|pve02|testapp-meta-data.yaml|snippets')" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  STUB_SSH_LS_1="testapp-user-data.yaml" \
  STUB_SSH_LS_2="testapp-meta-data.yaml" \
  run_converge
if [[ $RC -eq 0 ]]; then
  test_pass "TC8a: rc=0"
else
  test_fail "TC8a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
APPLY_LINE=$(grep -E 'tofu-wrapper.sh apply' "$LOG" | head -1)
if grep -q "proxmox_virtual_environment_vm" <<<"$APPLY_LINE"; then
  test_fail "TC8b: VM resource was targeted — SAFETY VIOLATION"
  echo "    APPLY: $APPLY_LINE"
else
  test_pass "TC8b: no VM resource in apply targets"
fi
TARGET_COUNT=$(grep -oE '\-target=[^ ]+' <<<"$APPLY_LINE" | wc -l | tr -d ' ')
if [[ "$TARGET_COUNT" -eq 2 ]]; then
  test_pass "TC8c: exactly 2 -target= flags (the 2 snippet resources)"
else
  test_fail "TC8c: expected 2 -target= flags, got $TARGET_COUNT"
  echo "    APPLY: $APPLY_LINE"
fi

# --- TC9: unknown arg → rc=2, usage printed -----------------------------

test_start "TC9" "unknown arg → rc=2 with usage message"
setup_fixture
run_converge --bogus-flag
if [[ $RC -eq 2 ]]; then
  test_pass "TC9a: unknown arg → rc=2"
else
  test_fail "TC9a: unknown arg → rc=$RC (expected 2)"
fi
if grep -qE 'Unknown argument' <<<"$OUT"; then
  test_pass "TC9b: error message names the unknown argument"
else
  test_fail "TC9b: error message missing"
fi

# --- TC10: exact resource-type match (substring does not over-match) ----
#
# A hypothetical future type "proxmox_virtual_environment_file_extra" must
# NOT match the exact-string jq select for proxmox_virtual_environment_file.

test_start "TC10" "resource-type matching is exact — substring does not over-match"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json \
  'testapp_dev|pve01|extra-thing|snippets|proxmox_virtual_environment_file_extra' \
  'testapp_dev|pve02|testapp-real.yaml|snippets')" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  STUB_SSH_LS_2="testapp-real.yaml" \
  run_converge
APPLY_LINE=$(grep -E 'tofu-wrapper.sh apply' "$LOG" | head -1)
if grep -q "proxmox_virtual_environment_file_extra" <<<"$APPLY_LINE"; then
  test_fail "TC10a: over-matched on substring — _file_extra was targeted"
  echo "    APPLY: $APPLY_LINE"
else
  test_pass "TC10a: no over-match — _extra suffix not targeted"
fi
TARGET_COUNT=$(grep -oE '\-target=[^ ]+' <<<"$APPLY_LINE" | wc -l | tr -d ' ')
if [[ "$TARGET_COUNT" -eq 1 ]]; then
  test_pass "TC10b: only the genuine file resource was targeted (1 -target=)"
else
  test_fail "TC10b: expected 1 -target=, got $TARGET_COUNT"
  echo "    APPLY: $APPLY_LINE"
fi

# --- TC11: module named like the resource type → fail-closed ------------
#
# A module NAMED proxmox_virtual_environment_file carrying a snippet is
# undeclared in the vm-scope taxonomy, so classification fails closed rather
# than smuggling it in. (Old code string-matched the type at the address
# position; the new code classifies by module, and an unknown module is a
# hard error — a stronger guarantee.)

test_start "TC11" "module named like the resource type is not classifiable → fail-closed"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json \
  'proxmox_virtual_environment_file|pve01|trap-user-data.yaml|snippets' \
  'testapp_dev|pve02|testapp-real.yaml|snippets')" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC11a: undeclared trap module → rc=$RC (fail-closed)"
else
  test_fail "TC11a: trap module was classified (rc=0) — should fail closed"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'tofu-wrapper.sh apply' "$LOG"; then
  test_fail "TC11b: apply fired despite unclassifiable module — SAFETY VIOLATION"
  cat "$LOG" | sed 's/^/    /'
else
  test_pass "TC11b: apply NOT called (correct: fail-closed on unknown module)"
fi

# --- TC22: missing --env → rc=2 (required-arg failure) ------------------

test_start "TC22" "missing --env → rc=2, refuses to converge all modules"
setup_fixture
CONVERGE_ENV=none run_converge
if [[ $RC -eq 2 ]]; then
  test_pass "TC22a: missing --env → rc=2"
else
  test_fail "TC22a: missing --env → rc=$RC (expected 2)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE '\-\-env <dev\|prod> is required' <<<"$OUT"; then
  test_pass "TC22b: error names the required --env"
else
  test_fail "TC22b: error did not name --env requirement"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'tofu-wrapper.sh (plan|apply)' "$LOG"; then
  test_fail "TC22c: plan/apply fired despite missing --env"
else
  test_pass "TC22c: no plan/apply (correct: refused before doing work)"
fi

# --- TC23: invalid --env value → rc=2 -----------------------------------

test_start "TC23" "invalid --env value → rc=2"
setup_fixture
CONVERGE_ENV=staging run_converge
if [[ $RC -eq 2 ]]; then
  test_pass "TC23a: invalid --env → rc=2"
else
  test_fail "TC23a: invalid --env → rc=$RC (expected 2)"
fi
if grep -qE "must be 'dev' or 'prod'" <<<"$OUT"; then
  test_pass "TC23b: error names the valid values"
else
  test_fail "TC23b: error did not name valid values"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# --- TC24: --env dev targets dev-deployable + control-plane snippet modules -
#
# Headline #529 case, extended for the #623 dev-authoritative control plane.
# State carries snippets for testapp_dev (dev), gatus (prod-only), vault_prod
# (prod), gitlab (prod-only control-plane), cicd (shared control-plane), pbs
# (vendor shared control-plane), and hil_boot (shared data-plane).
#
# converge scope == deploy scope: --env dev converges testapp_dev + hil_boot
# (dev data-plane + shared data-plane) PLUS the control plane (gitlab, cicd,
# pbs), which is dev-authoritative. It must NOT touch prod data-plane
# (gatus, vault_prod).

ENV_STATE_SPECS=(
  'testapp_dev|pve01|testapp-user-data.yaml|snippets'
  'gatus|pve01|gatus-user-data.yaml|snippets'
  'vault_prod|pve01|vault-user-data.yaml|snippets'
  'gitlab|pve01|gitlab-user-data.yaml|snippets'
  'cicd|pve01|cicd-user-data.yaml|snippets'
  'pbs|pve01|pbs-user-data.yaml|snippets'
  'hil_boot|pve01|hil-boot-user-data.yaml|snippets'
)
ENV_ONDISK_1="testapp-user-data.yaml gatus-user-data.yaml vault-user-data.yaml gitlab-user-data.yaml cicd-user-data.yaml pbs-user-data.yaml hil-boot-user-data.yaml"

test_start "TC24" "--env dev targets testapp_dev+hil_boot+control-plane; excludes gatus/vault_prod"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json "${ENV_STATE_SPECS[@]}")" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  STUB_SSH_LS_1="$ENV_ONDISK_1" \
  run_converge
if [[ $RC -eq 0 ]]; then
  test_pass "TC24a: rc=0"
else
  test_fail "TC24a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
APPLY_LINE=$(grep -E 'tofu-wrapper.sh apply' "$LOG" | head -1)
if grep -q 'module.testapp_dev' <<<"$APPLY_LINE" \
   && grep -q 'module.hil_boot' <<<"$APPLY_LINE"; then
  test_pass "TC24b: testapp_dev + hil_boot (dev + shared data-plane) targeted"
else
  test_fail "TC24b: expected testapp_dev + hil_boot in targets"
  echo "    APPLY: $APPLY_LINE"
fi
# #623: control plane (gitlab, cicd, pbs) is dev-authoritative → targeted here.
CP_OK=1
for m in 'module.gitlab' 'module.cicd' 'module.pbs'; do
  if ! grep -q "$m" <<<"$APPLY_LINE"; then
    test_fail "TC24c: control-plane module $m NOT targeted under --env dev — #623 REGRESSION"
    echo "    APPLY: $APPLY_LINE"
    CP_OK=0
  fi
done
[[ $CP_OK -eq 1 ]] && test_pass "TC24c: control plane (gitlab+cicd+pbs) targeted from --env dev (#623)"
# Prod data-plane must never leak into the dev converge (#529).
LEAK=0
for m in 'module.gatus' 'module.vault_prod'; do
  if grep -q "$m" <<<"$APPLY_LINE"; then
    test_fail "TC24d: prod data-plane module $m LEAKED into --env dev — #529 VIOLATION"
    echo "    APPLY: $APPLY_LINE"
    LEAK=1
  fi
done
[[ $LEAK -eq 0 ]] && test_pass "TC24d: no prod data-plane module targeted from --env dev"
TARGET_COUNT=$(grep -oE '\-target=[^ ]+' <<<"$APPLY_LINE" | wc -l | tr -d ' ')
if [[ "$TARGET_COUNT" -eq 5 ]]; then
  test_pass "TC24e: exactly 5 -target= flags (testapp_dev + hil_boot + gitlab + cicd + pbs)"
else
  test_fail "TC24e: expected 5 -target= flags, got $TARGET_COUNT"
  echo "    APPLY: $APPLY_LINE"
fi
# Phase B env-agnostic regression: the prod data-plane snippets (gatus,
# vault) are tracked in state AND present on disk, so Phase B must NOT delete
# them as orphans under --env dev. Phase A env scoping must not leak into
# Phase B's expected set (a narrowed Phase B set would rm these — #529).
if grep -qE ':: rm .*(gatus|vault)-user-data\.yaml' "$SSH_LOG"; then
  test_fail "TC24f: Phase B deleted a prod snippet under --env dev — ENV-AGNOSTIC VIOLATION (#529)"
  grep -E ':: rm ' "$SSH_LOG" | sed 's/^/    /'
else
  test_pass "TC24f: Phase B did NOT delete prod snippets (gatus/vault) under --env dev"
fi

# --- TC25: --env prod targets prod modules; hil_boot NOT targeted -------

test_start "TC25" "--env prod targets gatus + vault_prod; hil_boot/testapp_dev/control-plane excluded"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json "${ENV_STATE_SPECS[@]}")" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  STUB_SSH_LS_1="$ENV_ONDISK_1" \
  CONVERGE_ENV=prod run_converge
if [[ $RC -eq 0 ]]; then
  test_pass "TC25a: rc=0"
else
  test_fail "TC25a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
APPLY_LINE=$(grep -E 'tofu-wrapper.sh apply' "$LOG" | head -1)
if grep -q 'module.gatus' <<<"$APPLY_LINE" \
   && grep -q 'module.vault_prod' <<<"$APPLY_LINE"; then
  test_pass "TC25b: gatus + vault_prod targeted"
else
  test_fail "TC25b: expected gatus + vault_prod in targets"
  echo "    APPLY: $APPLY_LINE"
fi
# hil_boot is shared data-plane: deploy:prod does NOT deploy it, so
# converge:prod must NOT target it (converge scope == deploy scope).
if grep -q 'module.hil_boot' <<<"$APPLY_LINE"; then
  test_fail "TC25c: hil_boot targeted under --env prod — shared belongs to dev"
  echo "    APPLY: $APPLY_LINE"
else
  test_pass "TC25c: hil_boot NOT targeted under --env prod"
fi
# #623: control plane is dev-authoritative → must NOT be targeted under prod.
LEAK=0
for m in 'module.testapp_dev' 'module.gitlab' 'module.cicd' 'module.pbs'; do
  if grep -q "$m" <<<"$APPLY_LINE"; then
    test_fail "TC25d: $m LEAKED into --env prod — dev-authoritative control plane (#623) VIOLATION"
    echo "    APPLY: $APPLY_LINE"
    LEAK=1
  fi
done
[[ $LEAK -eq 0 ]] && test_pass "TC25d: no dev data-plane / control-plane module targeted from --env prod"
TARGET_COUNT=$(grep -oE '\-target=[^ ]+' <<<"$APPLY_LINE" | wc -l | tr -d ' ')
if [[ "$TARGET_COUNT" -eq 2 ]]; then
  test_pass "TC25e: exactly 2 -target= flags (gatus + vault_prod)"
else
  test_fail "TC25e: expected 2 -target= flags, got $TARGET_COUNT"
  echo "    APPLY: $APPLY_LINE"
fi
# Phase B env-agnostic regression (prod direction): the dev/shared/control-plane
# snippets (testapp, hil-boot, gitlab, cicd, pbs) are tracked in state AND on
# disk, so Phase B must NOT delete them as orphans under --env prod.
if grep -qE ':: rm .*(testapp|hil-boot|gitlab|cicd|pbs)-user-data\.yaml' "$SSH_LOG"; then
  test_fail "TC25f: Phase B deleted a dev/shared/control-plane snippet under --env prod — ENV-AGNOSTIC VIOLATION"
  grep -E ':: rm ' "$SSH_LOG" | sed 's/^/    /'
else
  test_pass "TC25f: Phase B did NOT delete dev/shared/control-plane snippets under --env prod"
fi

# --- TC26: undeclared module in state → fail-closed ---------------------

test_start "TC26" "undeclared snippet module → --env dev fails closed, no apply"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json \
  'testapp_dev|pve01|testapp-user-data.yaml|snippets' \
  'mystery_thing|pve01|mystery-user-data.yaml|snippets')" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC26a: undeclared module → rc=$RC (fail-closed)"
else
  test_fail "TC26a: undeclared module classified (rc=0) — should fail closed"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'deployable-modules|undeclared module' <<<"$OUT"; then
  test_pass "TC26b: error names the classification failure"
else
  test_fail "TC26b: error did not name deployable-modules/undeclared module"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'tofu-wrapper.sh apply' "$LOG"; then
  test_fail "TC26c: apply fired despite unclassifiable module — SAFETY VIOLATION"
  cat "$LOG" | sed 's/^/    /'
else
  test_pass "TC26c: apply NOT called (correct: fail-closed)"
fi

# --- TC27: #360 regression — content_type=iso is NOT targeted -----------

test_start "TC27" "#360: a proxmox_virtual_environment_file with content_type=iso is NOT targeted"
setup_fixture
STUB_SHOW_JSON="$(mk_show_json \
  'testapp_dev|pve01|testapp-user-data.yaml|snippets' \
  'testapp_dev|pve01|debian.iso|iso')" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  STUB_SSH_LS_1="testapp-user-data.yaml" \
  run_converge
if [[ $RC -eq 0 ]]; then
  test_pass "TC27a: rc=0"
else
  test_fail "TC27a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
APPLY_LINE=$(grep -E 'tofu-wrapper.sh apply' "$LOG" | head -1)
# The iso resource is res1 on module.testapp_dev; the snippet is res0. Both
# share the module, so assert on the resource name, not the module.
if grep -q 'res1' <<<"$APPLY_LINE"; then
  test_fail "TC27b: iso resource (res1) was targeted — #360 VIOLATION"
  echo "    APPLY: $APPLY_LINE"
else
  test_pass "TC27b: iso resource NOT targeted"
fi
TARGET_COUNT=$(grep -oE '\-target=[^ ]+' <<<"$APPLY_LINE" | wc -l | tr -d ' ')
if [[ "$TARGET_COUNT" -eq 1 ]]; then
  test_pass "TC27c: exactly 1 -target= (the snippet only)"
else
  test_fail "TC27c: expected 1 -target=, got $TARGET_COUNT"
  echo "    APPLY: $APPLY_LINE"
fi

# --- TC28: CI wiring — converge:dev passes --env dev, converge:prod prod -

test_start "TC28" "CI wiring: converge:dev invokes --env dev, converge:prod --env prod"
CI_YML="${REPO_ROOT}/.gitlab-ci.yml"
if [[ -f "$CI_YML" ]]; then
  # Extract each job's block (from the job header to the next top-level key)
  # and assert the converge-cluster invocation inside it carries the right
  # --env.
  DEV_BLOCK="$(awk '/^converge:dev:/{f=1;print;next} f&&/^[^[:space:]]/{exit} f{print}' "$CI_YML")"
  PROD_BLOCK="$(awk '/^converge:prod:/{f=1;print;next} f&&/^[^[:space:]]/{exit} f{print}' "$CI_YML")"
  if grep -qE 'converge-cluster\.sh --env dev' <<<"$DEV_BLOCK"; then
    test_pass "TC28a: converge:dev invokes converge-cluster.sh --env dev"
  else
    test_fail "TC28a: converge:dev does not invoke --env dev"
    printf '%s\n' "$DEV_BLOCK" | sed 's/^/    /'
  fi
  if grep -qE 'converge-cluster\.sh --env prod' <<<"$PROD_BLOCK"; then
    test_pass "TC28b: converge:prod invokes converge-cluster.sh --env prod"
  else
    test_fail "TC28b: converge:prod does not invoke --env prod"
    printf '%s\n' "$PROD_BLOCK" | sed 's/^/    /'
  fi
  # Negative: neither job should invoke converge-cluster.sh with NO --env.
  if grep -qE 'converge-cluster\.sh\s*$' <<<"$DEV_BLOCK$PROD_BLOCK"; then
    test_fail "TC28c: a converge job invokes converge-cluster.sh without --env"
  else
    test_pass "TC28c: no converge job invokes converge-cluster.sh without --env"
  fi
else
  test_fail "TC28: .gitlab-ci.yml not found at $CI_YML"
fi

# --- TC29: control-plane-modules failure under --env dev → fail-closed ---
#
# #623 augmentation fail-closed path: deployable-modules SUCCEEDS but
# control-plane-modules FAILS. Converge must abort (exit 1, no plan/apply)
# rather than treat the classifier failure as an empty control-plane set
# (which would silently skip converging gitlab/cicd/pbs under --env dev).

test_start "TC29" "control-plane-modules failure under --env dev → fail-closed, no apply"
setup_fixture
# Preserve the real classifier; shim vm-scope.sh to fail ONLY on
# control-plane-modules and delegate everything else to the real copy (which
# reads the fixture manifests because it lives in FX_SCRIPTS).
mv "${FX_SCRIPTS}/vm-scope.sh" "${FX_SCRIPTS}/vm-scope-real.sh"
cat > "${FX_SCRIPTS}/vm-scope.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "control-plane-modules" ]]; then
  echo "ERROR: simulated control-plane-modules failure" >&2
  exit 1
fi
exec "$(dirname "$0")/vm-scope-real.sh" "$@"
EOF
chmod +x "${FX_SCRIPTS}/vm-scope.sh"
STUB_SHOW_JSON="$(mk_show_json \
  'testapp_dev|pve01|testapp-user-data.yaml|snippets' \
  'gitlab|pve01|gitlab-user-data.yaml|snippets')" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC29a: control-plane-modules failure → rc=$RC (fail-closed)"
else
  test_fail "TC29a: control-plane-modules failure classified (rc=0) — should fail closed"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'control-plane-modules' <<<"$OUT"; then
  test_pass "TC29b: error names the control-plane-modules failure"
else
  test_fail "TC29b: error did not name control-plane-modules"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'tofu-wrapper.sh apply' "$LOG"; then
  test_fail "TC29c: apply fired despite control-plane classifier failure — SAFETY VIOLATION"
  cat "$LOG" | sed 's/^/    /'
else
  test_pass "TC29c: apply NOT called (correct: fail-closed)"
fi

# --- TC30: --env=<value> (equals form) is parsed and scopes correctly ----

test_start "TC30" "--env=prod equals-form is parsed and scopes Phase A to prod"
setup_fixture
OUT="$(STUB_SHOW_JSON="$(mk_show_json "${ENV_STATE_SPECS[@]}")" \
  STUB_PLAN_OUT="Plan: 1 to add, 0 to change, 0 to destroy." \
  STUB_PLAN_RC=2 \
  STUB_SSH_LS_1="$ENV_ONDISK_1" \
  PATH="${FX_BIN}:$PATH" bash "${FX_SCRIPTS}/converge-cluster.sh" --env=prod 2>&1)"
RC=$?
if [[ $RC -eq 0 ]]; then
  test_pass "TC30a: --env=prod → rc=0"
else
  test_fail "TC30a: --env=prod → rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
APPLY_LINE=$(grep -E 'tofu-wrapper.sh apply' "$LOG" | head -1)
TARGET_COUNT=$(grep -oE '\-target=[^ ]+' <<<"$APPLY_LINE" | wc -l | tr -d ' ')
if grep -q 'module.gatus' <<<"$APPLY_LINE" \
   && grep -q 'module.vault_prod' <<<"$APPLY_LINE" \
   && [[ "$TARGET_COUNT" -eq 2 ]]; then
  test_pass "TC30b: --env=prod scoped to prod data-plane (gatus + vault_prod, 2 targets)"
else
  test_fail "TC30b: --env=prod did not scope to prod (targets=$TARGET_COUNT)"
  echo "    APPLY: $APPLY_LINE"
fi


# --- Phase B test cases (#359) ------------------------------------------

# Helper: a canned tofu show -json for "gitlab snippet exists on pve01
# only" (mirrors the v1 acceptance case in the issue).
STUB_JSON_GITLAB_PVE01='
{
  "values": {
    "root_module": {
      "child_modules": [
        {
          "child_modules": [
            {
              "resources": [
                {
                  "address": "module.gitlab.module.gitlab.proxmox_virtual_environment_file.user_data[\"pve01\"]",
                  "type": "proxmox_virtual_environment_file",
                  "values": {
                    "content_type": "snippets",
                    "node_name": "pve01",
                    "file_name": "gitlab-user-data.yaml"
                  }
                }
              ]
            }
          ]
        }
      ]
    }
  }
}'

# --- TC12: Phase B finds orphans and deletes them -----------------------

test_start "TC12" "Phase B: orphan found on pve02 → ssh rm fires, rc=0"
setup_fixture
# State: only the gitlab snippet on pve01 is expected.
# Reality: pve01 has the expected gitlab snippet; pve02 has TWO orphans;
# pve03 is empty.
STUB_SSH_LS_1="gitlab-user-data.yaml" \
STUB_SSH_LS_2="workstation-dev-meta-data.yaml workstation-dev-user-data.yaml" \
STUB_SSH_LS_3="" \
STUB_SHOW_JSON="$STUB_JSON_GITLAB_PVE01" \
  run_converge
if [[ $RC -eq 0 ]]; then
  test_pass "TC12a: rc=0 after successful orphan cleanup"
else
  test_fail "TC12a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -q "pve02: 2 orphan snippet(s):" <<<"$OUT"; then
  test_pass "TC12b: 'pve02: 2 orphan snippet(s)' diagnostic printed"
else
  test_fail "TC12b: orphan count diagnostic missing"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
# Both orphans should have generated rm calls on pve02 (10.0.0.2).
RM_PVE02=$(grep -cE 'ssh root@10\.0\.0\.2 :: rm.*workstation-dev' "$SSH_LOG" || true)
if [[ "$RM_PVE02" -eq 2 ]]; then
  test_pass "TC12c: 2 rm calls fired for pve02 orphans"
else
  test_fail "TC12c: expected 2 rm calls on pve02, got $RM_PVE02"
  cat "$SSH_LOG" | sed 's/^/    /'
fi
# pve01 has a legit snippet — must NOT trigger rm.
if grep -qE 'ssh root@10\.0\.0\.1 :: rm' "$SSH_LOG"; then
  test_fail "TC12d: rm fired on pve01 — legit snippet was wrongly deleted"
else
  test_pass "TC12d: no rm fired on pve01 (correct: file is tofu-tracked)"
fi
# pve03 has no files at all — no rm.
if grep -qE 'ssh root@10\.0\.0\.3 :: rm' "$SSH_LOG"; then
  test_fail "TC12e: rm fired on pve03 — no orphans existed"
else
  test_pass "TC12e: no rm fired on pve03"
fi
if grep -qE 'Phase B: deleted 2 orphan' <<<"$OUT"; then
  test_pass "TC12f: deletion-summary line printed (2 orphans)"
else
  test_fail "TC12f: summary line missing"
fi

# --- TC13: --dry-run + orphans → no rm calls ----------------------------

test_start "TC13" "Phase B --dry-run: orphans identified, NO rm calls"
setup_fixture
STUB_SSH_LS_2="workstation-dev-meta-data.yaml workstation-dev-user-data.yaml" \
STUB_SHOW_JSON="$STUB_JSON_GITLAB_PVE01" \
  run_converge --dry-run
if [[ $RC -eq 0 ]]; then
  test_pass "TC13a: rc=0 in dry-run with orphans"
else
  test_fail "TC13a: rc=$RC (expected 0)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE "DRY RUN — not deleting [0-9]+ orphan" <<<"$OUT"; then
  test_pass "TC13b: 'DRY RUN — not deleting N orphan(s)' diagnostic printed"
else
  test_fail "TC13b: dry-run diagnostic missing"
fi
if grep -qE 'ssh root@10\.0\.0\..*:: rm' "$SSH_LOG"; then
  test_fail "TC13c: rm fired despite --dry-run — SAFETY VIOLATION"
  cat "$SSH_LOG" | sed 's/^/    /'
else
  test_pass "TC13c: NO rm calls fired (correct: --dry-run)"
fi

# --- TC14: ssh ls fails on one node → fail-closed exit ------------------

test_start "TC14" "Phase B: ssh ls failure on a node → rc=1 (fail-closed)"
setup_fixture
STUB_SSH_LS_FAIL_2=1 \
STUB_SHOW_JSON="$STUB_JSON_GITLAB_PVE01" \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC14a: ssh enumeration failure → rc=$RC (non-zero)"
else
  test_fail "TC14a: ssh failure swallowed (rc=0)"
fi
if grep -qE "ssh enumeration failed on pve02" <<<"$OUT"; then
  test_pass "TC14b: error message names the failing node"
else
  test_fail "TC14b: error message did not name pve02"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'ssh root@10\.0\.0\..*:: rm' "$SSH_LOG"; then
  test_fail "TC14c: rm fired despite enumeration failure"
else
  test_pass "TC14c: no rm fired (correct: fail-closed)"
fi

# --- TC15: rm failure → exit 1, count reported --------------------------

test_start "TC15" "Phase B: rm failure → rc=1, failure count reported"
setup_fixture
STUB_SSH_LS_2="workstation-dev-meta-data.yaml workstation-dev-user-data.yaml" \
STUB_SHOW_JSON="$STUB_JSON_GITLAB_PVE01" \
STUB_SSH_RM_FAIL=1 \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC15a: rm failure → rc=$RC (non-zero)"
else
  test_fail "TC15a: rm failure swallowed (rc=0)"
fi
if grep -qE "Phase B deleted 0 orphan\(s\) but 2 deletion\(s\) failed" <<<"$OUT"; then
  test_pass "TC15b: failure summary names both counts"
else
  test_fail "TC15b: failure summary missing or wrong shape"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# --- TC16: orphan filename fails regex → reject -------------------------

test_start "TC16" "Phase B: orphan name violating FILENAME_REGEX is rejected"
setup_fixture
# A file name with a slash would be a path-traversal vector if passed
# straight to `rm /var/lib/vz/snippets/<NAME>`. The shim returns it as
# if `ls` somehow produced it.
STUB_SSH_LS_2='good.yaml ../bad-traversal.yaml' \
STUB_SHOW_JSON="$STUB_JSON_GITLAB_PVE01" \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC16a: regex rejection → rc=$RC (non-zero)"
else
  test_fail "TC16a: regex bypass — rc=0 with bad filename"
fi
if grep -qE "fails filename regex" <<<"$OUT"; then
  test_pass "TC16b: error message names the regex guard"
else
  test_fail "TC16b: error message did not name the regex"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
# The legit 'good.yaml' should have been deleted; the bad one must NOT
# have triggered rm.
if grep -qE 'ssh root@10\.0\.0\.2 :: rm.*good\.yaml' "$SSH_LOG"; then
  test_pass "TC16c: legit orphan was deleted"
else
  test_fail "TC16c: legit orphan was not deleted"
  cat "$SSH_LOG" | sed 's/^/    /'
fi
if grep -qE 'ssh root@10\.0\.0\..*:: rm.*\.\./' "$SSH_LOG"; then
  test_fail "TC16d: path-traversal rm fired — SAFETY VIOLATION"
  cat "$SSH_LOG" | sed 's/^/    /'
else
  test_pass "TC16d: path-traversal rm NOT fired (regex guard worked)"
fi

# --- TC17: tofu show -json failure → fail-closed ------------------------

test_start "TC17" "Phase B: tofu show -json failure → rc=1"
setup_fixture
STUB_SHOW_RC=1 \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC17a: show failure → rc=$RC (non-zero)"
else
  test_fail "TC17a: show failure swallowed (rc=0)"
fi
if grep -qE "tofu show -json failed" <<<"$OUT"; then
  test_pass "TC17b: error message names show -json as the failure"
else
  test_fail "TC17b: error message did not name show -json"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# Phase B safety gate + shape validation cases (#359 R1 fixes after
# adversarial review). These cover the failure modes codex and gemini
# independently identified: an empty/invalid tofu show output would
# silently classify every on-disk snippet as an orphan and delete it.

# Empty tofu show (zero expected snippets) — the high-impact failure mode.
STUB_JSON_EMPTY='{"values":{"root_module":{}}}'

# Valid JSON but WRONG shape (e.g., a response from the wrong API). The
# shape validator should refuse this BEFORE the per-pair jq filter ever
# runs, so the failure surfaces as a shape error, not silent zero-expected.
STUB_JSON_WRONG_SHAPE='{"foo":"bar"}'

# Snippet resource with a null/missing file_name. Without per-pair shape
# validation, this would emit "pve02\tnull" as an expected pair, and the
# real workstation-dev-*.yaml files on pve02 would still be classified
# as orphans (matching codex's "stamp the cluster from a broken state"
# scenario).
STUB_JSON_NULL_FILENAME='
{
  "values": {
    "root_module": {
      "child_modules": [
        {
          "resources": [
            {
              "address": "module.workstation_dev.proxmox_virtual_environment_file.user_data[\"pve02\"]",
              "type": "proxmox_virtual_environment_file",
              "values": {
                "content_type": "snippets",
                "node_name": "pve02",
                "file_name": null
              }
            }
          ]
        }
      ]
    }
  }
}'

# --- TC18: empty expected + orphans → fail-closed (the headline P1) ----

test_start "TC18" "Phase B: empty-expected gate refuses to mass-delete"
setup_fixture
STUB_SSH_LS_1="gitlab-user-data.yaml" \
STUB_SSH_LS_2="workstation-dev-meta-data.yaml workstation-dev-user-data.yaml" \
STUB_SSH_LS_3="" \
STUB_SHOW_JSON="$STUB_JSON_EMPTY" \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC18a: empty-expected gate trips → rc=$RC (non-zero)"
else
  test_fail "TC18a: gate failed to trip — rc=0 with empty expected + orphans"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE "tofu state shows zero expected snippets but [0-9]+" <<<"$OUT"; then
  test_pass "TC18b: gate diagnostic names the empty-expected condition"
else
  test_fail "TC18b: gate error message did not mention zero-expected"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'ssh root@10\.0\.0\..*:: rm' "$SSH_LOG"; then
  test_fail "TC18c: rm fired despite empty-expected gate — SAFETY VIOLATION"
  cat "$SSH_LOG" | sed 's/^/    /'
else
  test_pass "TC18c: NO rm calls fired (correct: gate held)"
fi

# --- TC19: --allow-empty-expected overrides the gate -------------------

test_start "TC19" "Phase B: --allow-empty-expected overrides the gate"
setup_fixture
STUB_SSH_LS_1="" \
STUB_SSH_LS_2="workstation-dev-meta-data.yaml workstation-dev-user-data.yaml" \
STUB_SSH_LS_3="" \
STUB_SHOW_JSON="$STUB_JSON_EMPTY" \
  run_converge --allow-empty-expected
if [[ $RC -eq 0 ]]; then
  test_pass "TC19a: rc=0 with --allow-empty-expected"
else
  test_fail "TC19a: rc=$RC (expected 0 with override)"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE "Proceeding because --allow-empty-expected" <<<"$OUT"; then
  test_pass "TC19b: warning printed when override is used"
else
  test_fail "TC19b: override warning missing"
fi
RM_COUNT=$(grep -cE 'ssh root@10\.0\.0\..*:: rm' "$SSH_LOG" 2>/dev/null || true)
[[ -z "$RM_COUNT" ]] && RM_COUNT=0
if [[ "$RM_COUNT" -eq 2 ]]; then
  test_pass "TC19c: both orphans deleted after override"
else
  test_fail "TC19c: expected 2 rm calls, saw $RM_COUNT"
  cat "$SSH_LOG" | sed 's/^/    /'
fi

# --- TC20: JSON with wrong shape → shape validator catches it ----------

test_start "TC20" "Phase B: JSON without .values.root_module → fail-closed"
setup_fixture
STUB_SSH_LS_2="something.yaml" \
STUB_SHOW_JSON="$STUB_JSON_WRONG_SHAPE" \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC20a: wrong-shape JSON → rc=$RC (non-zero)"
else
  test_fail "TC20a: wrong-shape JSON accepted — rc=0"
fi
if grep -qE "not a valid tofu state snapshot" <<<"$OUT"; then
  test_pass "TC20b: shape error message printed"
else
  test_fail "TC20b: shape error message missing"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'ssh root@10\.0\.0\..*:: rm' "$SSH_LOG"; then
  test_fail "TC20c: rm fired despite shape rejection — SAFETY VIOLATION"
else
  test_pass "TC20c: NO rm calls fired (correct: shape gate held)"
fi

# --- TC21: per-pair shape validation: null file_name ignored ----------

test_start "TC21" "Phase B: snippet resource with null file_name is ignored"
setup_fixture
# pve02 has the workstation-dev files on disk; tofu state has ONE
# malformed pve02 snippet resource (file_name=null). Without per-pair
# validation, the filter would emit "pve02\tnull" → EXPECTED_COUNT=1 →
# gate would NOT trip → real files would be deleted as orphans. With
# the per-pair shape filter, that broken resource is dropped, so
# EXPECTED_COUNT=0 and the empty-expected gate then refuses.
STUB_SSH_LS_2="workstation-dev-meta-data.yaml workstation-dev-user-data.yaml" \
STUB_SHOW_JSON="$STUB_JSON_NULL_FILENAME" \
  run_converge
if [[ $RC -ne 0 ]]; then
  test_pass "TC21a: per-pair filter dropped null-file_name → gate trips → rc=$RC"
else
  test_fail "TC21a: rc=0 — null file_name was treated as a valid expected pair"
  printf '%s\n' "$OUT" | sed 's/^/    /'
fi
if grep -qE 'ssh root@10\.0\.0\..*:: rm' "$SSH_LOG"; then
  test_fail "TC21b: rm fired despite null-file_name — SAFETY VIOLATION"
else
  test_pass "TC21b: NO rm calls fired (correct)"
fi

runner_summary
