#!/usr/bin/env bash
# test_tofu_wrapper_vmid_guard.sh — hermetic coverage for the tofu-wrapper.sh
# VMID-change guard (G7 safety fence for PBS backup continuity).
#
# Regression test for #540. Pre-fix code (inline block, roughly lines
# 638-679 pre-#540):
#
#   if "$TOFU_BIN" state list 2>/dev/null | grep -q "..."; then
#     ...
#     CURRENT_VMID=$("$TOFU_BIN" state show "$("$TOFU_BIN" state list \
#       2>/dev/null | grep ...)" 2>/dev/null | grep vm_id ... || echo "")
#     ...
#   fi
#
# Three swallows: (1) the outer `state list 2>/dev/null | grep -q` treated
# a backend outage as first-deploy (empty stdout) and silently skipped the
# guard; (2) the nested `state list 2>/dev/null` inside `state show` swallowed
# the same class; (3) the nested `state show ... 2>/dev/null ... || echo ""`
# swallowed backend errors DURING the drift check and reported empty
# CURRENT_VMID (which the comparison treats as "no drift").
#
# Per .claude/rules/destruction-safety.md "When a Safety Check Cannot
# Determine State", the correct default is FAIL, not SKIP. Symmetric to the
# #538 CP-guard fix (same wrapper, same class, explicitly scoped out of
# #538 to keep that MR focused; called out as follow-up by both the codex
# and fork-sub-claude reviewers of !407).
#
# The test extracts guard_vmid_changes() from the wrapper and sources it
# with a stub `tofu` (TOFU_BIN) plus minimal fixture config.yaml /
# applications.yaml so no real cluster/backend is touched.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

WRAPPER="${REPO_ROOT}/framework/scripts/tofu-wrapper.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# --- Structural assertions on the shipped wrapper ------------------------
test_start "S1" "guard is defined and invoked"
if grep -q '^guard_vmid_changes() {' "$WRAPPER" \
   && grep -q 'if ! guard_vmid_changes; then' "$WRAPPER"; then
  test_pass "guard defined and invoked"
else
  test_fail "guard function/invocation missing from wrapper"
fi

test_start "S2" "guard is gated on apply + \$ALLOW_VMID_CHANGE"
if grep -q '"\$TOFU_COMMAND" == "apply" && \$ALLOW_VMID_CHANGE -eq 0' "$WRAPPER"; then
  test_pass "gate wired to apply + --allow-vmid-change"
else
  test_fail "expected apply + ALLOW_VMID_CHANGE gating"
fi

# --- Extract the guard function for behavioral tests ---------------------
GUARD_LIB="${TMP_DIR}/guard.sh"
awk '
  /^guard_vmid_changes\(\) \{/ { f=1 }
  f { print }
  f && /^\}$/ { exit }
' "$WRAPPER" > "$GUARD_LIB"

if ! grep -q '^guard_vmid_changes()' "$GUARD_LIB"; then
  test_start "X" "extract guard function"
  test_fail "could not extract guard_vmid_changes from wrapper"
  runner_summary
fi

# Stub tofu:
#   `state list` — prints a single VM resource address unless
#     STUB_EMPTY_STATE=1 (first-deploy path). STUB_STATE_FAIL=1 forces
#     rc=1 with stderr, simulating a postgres backend outage / state lock /
#     network partition. Pre-#540 code was
#     `state list 2>/dev/null | grep -q ...` which swallowed this rc and
#     treated it as first-deploy — Case 3 asserts the fix now discriminates.
#   `state show <addr>` — prints "vm_id = <STUB_CURRENT_VMID>" (default 150,
#     matching the fixture gitlab.vmid). STUB_SHOW_FAIL=1 forces rc=1 with
#     stderr, simulating a backend outage BETWEEN the state list and the
#     drift-check show. Pre-#540 code was
#     `state show ... 2>/dev/null | ... || echo ""` which swallowed this rc
#     and fed an empty CURRENT_VMID into the comparison — Case 4 asserts
#     the fix now fails closed.
STUB_TOFU="${TMP_DIR}/tofu"
cat > "$STUB_TOFU" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
sub="${1:-}"
if [[ "$sub" == "state" ]]; then
  subsub="${2:-}"
  if [[ "$subsub" == "list" ]]; then
    if [[ "${STUB_STATE_FAIL:-0}" == "1" ]]; then
      echo "Error: Failed to load state: pq: connection refused" >&2
      exit 1
    fi
    if [[ "${STUB_EMPTY_STATE:-0}" != "1" ]]; then
      # gitlab and the app fixture's foo_prod are both present so the
      # apps loop is behaviorally exercised alongside the infra loop.
      # Post-#542: state addresses preserve underscores in outer module
      # names (module.foo_prod.…), which is the real shape tofu emits;
      # the pre-#542 fixture used `foo-prod` (with hyphen) to match the
      # broken `tr '_' '-'` substring-grep. The anchored regex now matches
      # the correct underscore-preserving address.
      echo "module.gitlab.module.gitlab.proxmox_virtual_environment_vm.vm"
      echo "module.foo_prod.module.foo.proxmox_virtual_environment_vm.vm"
      if [[ "${STUB_EMIT_DNS_PAIR:-0}" == "1" ]]; then
        # Real dns-pair state address shape (main.tf: module "dns_prod"
        # wraps `module "dns1"` / `module "dns2"` via dns-pair). Case 8
        # asserts the anchored regex matches this address for the
        # pair-structured vm_key `dns1_prod`, which the pre-#542 `tr '_'
        # '-'` substring-grep silently missed.
        echo "module.dns_prod.module.dns1.proxmox_virtual_environment_vm.vm"
      fi
      if [[ "${STUB_EMIT_COUNT_APP:-0}" == "1" ]]; then
        # Catalog-app state shape: `module.<app>_<env>[0].module.<app>.…`.
        # Every catalog-app module in framework/tofu/root/main.tf uses
        # `count = try(local.app_<app>.enabled, false) ? 1 : 0` (see
        # main.tf:801/844/889/928/969/1007/1047/1099), producing the `[0]`
        # index in state. Case 12 asserts the anchored regex matches this
        # shape for vm_key=qux_prod without an explicit "qux" in main.tf
        # (we use `qux` here to avoid conflicting with the real influxdb/
        # grafana/roon/workstation modules the fixture doesn't declare).
        echo "module.qux_prod[0].module.qux.proxmox_virtual_environment_vm.vm"
      fi
      if [[ "${STUB_EMIT_COLLIDING_PAIR:-0}" == "1" ]]; then
        # Substring-collision pair: `bar` is a substring of `barbaz`. Under
        # the pre-#542 unanchored `grep -i` filter, `head -1` for vm_key=bar
        # would pick whichever of these two lines printed first (bug 2).
        # The anchored regex rejects `barbaz` structurally.
        echo "module.barbaz.module.barbaz.proxmox_virtual_environment_vm.vm"
        echo "module.bar.module.bar.proxmox_virtual_environment_vm.vm"
      fi
    fi
    exit 0
  fi
  if [[ "$subsub" == "show" ]]; then
    addr="${3:-}"
    # STUB_SHOW_FAIL=1 fails on the FIRST show (gitlab), which returns
    # before the app loop; Case 4 uses that.
    if [[ "${STUB_SHOW_FAIL:-0}" == "1" ]]; then
      echo "Error: Failed to read state for ${addr}: pq: connection refused" >&2
      exit 1
    fi
    # STUB_SHOW_APP_FAIL=1 fails only when the show address is for the
    # app fixture (foo_prod). Gitlab shows succeed with its planned VMID
    # so the app loop is reached; then this failure surfaces the app
    # loop's own fail-closed rc-branch. Case 7 exercises this.
    if [[ "${STUB_SHOW_APP_FAIL:-0}" == "1" ]] && [[ "$addr" == *foo_prod* ]]; then
      echo "Error: Failed to read state for ${addr}: pq: connection refused" >&2
      exit 1
    fi
    # STUB_NESTED_VM_ID=1 emits a nested attribute (template_vm_id) BEFORE
    # the real vm_id line. Pre-#543 code used substring grep "vm_id"
    # which would pick `template_vm_id = 42` as the first hit (bug: wrong
    # value). Post-#543 code uses `grep -E '^ *vm_id *='` to anchor the
    # match to the top-level attribute. Case 10 exercises this.
    if [[ "${STUB_NESTED_VM_ID:-0}" == "1" ]] && [[ "$addr" == *gitlab* ]]; then
      # Emit a nested attribute BEFORE the real vm_id line, scoped to
      # the gitlab address so the app loop's foo_prod path is unaffected.
      echo "  template_vm_id  =  42"
      echo "  vm_id  =  ${STUB_CURRENT_VMID:-150}"
      exit 0
    fi
    # STUB_NO_VM_ID_LINE=1 forces rc=0 output with no vm_id line — the
    # adversarial-review-found fail-open path (state show succeeds but the
    # awk parse produces empty CURRENT_VMID). Case 6 exercises this.
    if [[ "${STUB_NO_VM_ID_LINE:-0}" == "1" ]]; then
      # Output that would arise if the state resource's schema changed
      # and no longer emits a "vm_id" attribute (or the awk-parsed line
      # got renamed). Deliberately does NOT contain the substring "vm_id"
      # anywhere — even in a comment, since the guard uses a substring
      # grep and would match a comment mentioning it.
      echo "  name  =  \"placeholder-resource\""
      exit 0
    fi
    # Real tofu's "state show" output aligns "vm_id" with spaces around "="
    # (roughly "  vm_id                     = 150"). The guard extracts
    # $3 from `awk`, i.e. the value column. Two spaces around "=" match
    # both real and stub outputs.
    if [[ "$addr" == *qux_prod* ]]; then
      # Case 12 count-shape catalog app (qux_prod, planned vmid 700).
      echo "  vm_id  =  ${STUB_QUX_CURRENT_VMID:-700}"
    elif [[ "$addr" == *dns1* ]]; then
      # Case 8 pair-structured VM (dns1_prod, planned vmid 104).
      echo "  vm_id  =  ${STUB_DNS1_CURRENT_VMID:-104}"
    elif [[ "$addr" == module.bar.* ]]; then
      # Case 9 substring-collision "bar" (planned vmid 505).
      echo "  vm_id  =  ${STUB_BAR_CURRENT_VMID:-505}"
    elif [[ "$addr" == *barbaz* ]]; then
      # Case 9 substring-collision "barbaz" (planned vmid 506).
      echo "  vm_id  =  ${STUB_BARBAZ_CURRENT_VMID:-506}"
    elif [[ "$addr" == *gitlab* ]]; then
      echo "  vm_id  =  ${STUB_CURRENT_VMID:-150}"
    else
      # foo_prod default: matches its planned VMID (200) so no drift for
      # the app loop unless overridden via a case-specific stub tweak.
      echo "  vm_id  =  ${STUB_APP_CURRENT_VMID:-200}"
    fi
    exit 0
  fi
fi
exit 0
EOF
chmod +x "$STUB_TOFU"

# Minimal test fixtures for CONFIG_FILE / APPS_CONFIG.
# gitlab.vmid = 150 matches the stub's default vm_id → Case 1 (no drift).
# foo_prod is an application fixture with vmid = 200; used by Cases 6+7 to
# behaviorally exercise the guard's application-VM loop (the codex/fork
# adversarial review of MR !408 called out that the previous fixture's
# `applications: {}` left the app loop's fail-closed path unverified).
FIXTURE_CONFIG="${TMP_DIR}/config.yaml"
cat > "$FIXTURE_CONFIG" <<'EOF'
vms:
  gitlab:
    vmid: 150
    backup: true
EOF
FIXTURE_APPS="${TMP_DIR}/applications.yaml"
cat > "$FIXTURE_APPS" <<'EOF'
applications:
  foo:
    enabled: true
    backup: true
    environments:
      prod:
        vmid: 200
EOF

# Minimal context the guard closes over.
TOFU_BIN="$STUB_TOFU"
CONFIG_FILE="$FIXTURE_CONFIG"
APPS_CONFIG="$FIXTURE_APPS"
export STUB_STATE_FAIL STUB_EMPTY_STATE STUB_SHOW_FAIL STUB_SHOW_APP_FAIL \
       STUB_NO_VM_ID_LINE STUB_CURRENT_VMID STUB_APP_CURRENT_VMID \
       STUB_EMIT_DNS_PAIR STUB_EMIT_COLLIDING_PAIR STUB_EMIT_COUNT_APP \
       STUB_DNS1_CURRENT_VMID STUB_BAR_CURRENT_VMID STUB_BARBAZ_CURRENT_VMID \
       STUB_QUX_CURRENT_VMID
STUB_STATE_FAIL=0
STUB_EMPTY_STATE=0
STUB_SHOW_FAIL=0
STUB_SHOW_APP_FAIL=0
STUB_NO_VM_ID_LINE=0
STUB_CURRENT_VMID=150
STUB_APP_CURRENT_VMID=200
STUB_EMIT_DNS_PAIR=0
STUB_EMIT_COLLIDING_PAIR=0
STUB_EMIT_COUNT_APP=0
STUB_DNS1_CURRENT_VMID=104
STUB_BAR_CURRENT_VMID=505
STUB_BARBAZ_CURRENT_VMID=506
STUB_QUX_CURRENT_VMID=700
export STUB_NESTED_VM_ID
STUB_NESTED_VM_ID=0
# shellcheck disable=SC1090
source "$GUARD_LIB"

run_guard() {
  set +e
  GUARD_OUT="$(guard_vmid_changes 2>&1)"
  GUARD_RC=$?
  set -e
}

# --- Case 1: no drift (current == planned) -> PROCEED (rc 0) --------------
test_start "1" "no drift proceeds"
STUB_CURRENT_VMID=150; STUB_STATE_FAIL=0; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=0
run_guard
if [[ "$GUARD_RC" -eq 0 ]]; then
  test_pass "no-drift case proceeds"
else
  test_fail "expected rc 0 for no-drift, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi

# --- Case 2: drift (planned != current) -> BLOCK (rc 1) -------------------
# gitlab is a backup-backed precious-state VM (backup: true in the fixture),
# so the drift message must include the PRECIOUS-STATE annotation.
test_start "2" "drift detected, guard blocks with precious-state annotation"
STUB_CURRENT_VMID=999; STUB_STATE_FAIL=0; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=0
run_guard
if [[ "$GUARD_RC" -eq 1 ]] \
   && grep -q 'VMID changes detected' <<< "$GUARD_OUT" \
   && grep -q '999 → 150' <<< "$GUARD_OUT" \
   && grep -q 'HAS PRECIOUS STATE' <<< "$GUARD_OUT" \
   && grep -q '\-\-allow-vmid-change' <<< "$GUARD_OUT"; then
  test_pass "drift blocked with precious-state annotation + escape-hatch guidance"
else
  test_fail "expected rc 1 + drift message, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi

# --- Case 3: `tofu state list` errors -> FAIL CLOSED (rc 1) ---------------
# Regression for #540 (mirrors #538 Case 6). Pre-fix code was
#   `if "$TOFU_BIN" state list 2>/dev/null | grep -q "..."; then`
# which swallowed the exit code and treated a backend outage identically to
# first-deploy (empty stdout), silently disabling the drift check precisely
# when a VMID rename would have caused the most damage to PBS backup
# continuity. Under the pre-fix code this test FAILS: the guard silently
# returns rc=0 with empty output, but Case 3 expects rc=1 with the G7
# diagnostic. Under the fix it PASSES because the guard now distinguishes
# "state list errored" (indeterminate → fail closed) from "state list
# returned empty" (legitimate first deploy → proceed).
test_start "3" "\`tofu state list\` error fails closed with G7 diagnostic"
STUB_STATE_FAIL=1; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=0; STUB_CURRENT_VMID=999
run_guard
# Also assert the tofu stderr ("pq: connection refused" from the stub) is
# surfaced — the fix captures stderr into a tmpfile and prints it under
# "tofu state list stderr:" so the operator gets the actual cause in one
# round trip, not just an exit code.
if [[ "$GUARD_RC" -eq 1 ]] \
   && grep -q 'G7' <<< "$GUARD_OUT" \
   && grep -qi 'failing closed' <<< "$GUARD_OUT" \
   && grep -qi 'determine tofu state' <<< "$GUARD_OUT" \
   && grep -q 'pq: connection refused' <<< "$GUARD_OUT" \
   && grep -q 'PBS backup continuity' <<< "$GUARD_OUT"; then
  test_pass "state-list error fails closed with G7 + captured stderr + PBS reference"
else
  test_fail "expected rc 1 + G7 fail-closed + determine-tofu-state + stub stderr, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi

# --- Case 4: `tofu state show` errors DURING drift check -> FAIL CLOSED --
# Regression for the nested #540 swallow. Pre-fix:
#   CURRENT_VMID=$(... state show ... 2>/dev/null ... || echo "")
# Backend went down between `state list` (success) and the per-VM `state
# show` — the swallow reported empty CURRENT_VMID and the comparison
# silently treated it as "no drift", proceeding past a potentially unsafe
# apply. The fix captures state show's rc and stderr and fails closed.
test_start "4" "\`tofu state show\` error fails closed with G7 diagnostic"
STUB_STATE_FAIL=0; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=1; STUB_CURRENT_VMID=150
run_guard
if [[ "$GUARD_RC" -eq 1 ]] \
   && grep -q 'G7' <<< "$GUARD_OUT" \
   && grep -qi 'failing closed' <<< "$GUARD_OUT" \
   && grep -qi 'current VMID' <<< "$GUARD_OUT" \
   && grep -q 'pq: connection refused' <<< "$GUARD_OUT" \
   && grep -q 'gitlab' <<< "$GUARD_OUT"; then
  test_pass "state-show error fails closed with G7 + captured stderr + VM label"
else
  test_fail "expected rc 1 + G7 fail-closed + current-VMID + stub stderr, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi

# --- Case 5: first deploy (empty state) -> PROCEED (rc 0) -----------------
# The pipeline runs `tofu init` before this apply; post-init `tofu state
# list` returns rc=0 with empty stdout on a genuine first deploy. With no
# VMs in state there is nothing to compare against; the guard proceeds.
# Distinct from Case 3 (rc != 0 = indeterminate = fail closed).
test_start "5" "first deploy (rc=0, empty state) proceeds"
STUB_STATE_FAIL=0; STUB_EMPTY_STATE=1; STUB_SHOW_FAIL=0
run_guard
if [[ "$GUARD_RC" -eq 0 ]]; then
  test_pass "first-deploy empty state proceeds"
else
  test_fail "expected rc 0 for empty-state first deploy, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi

# --- Case 6: state show rc=0 but no parseable vm_id -> FAIL CLOSED --------
# Codex adversarial review of MR !408 flagged: pre- and post-refactor, if
# `state show` succeeds but the output doesn't contain a `vm_id` line, the
# awk parse silently yields empty CURRENT_VMID and the comparison treats
# it as "no drift". Same class of "cannot determine safety" the outer fix
# addresses. The fix now fails closed with a G7 diagnostic naming the
# offending resource and dumping the unparseable output.
test_start "6" "state show rc=0 but no vm_id line -> fail closed"
STUB_STATE_FAIL=0; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=0
STUB_SHOW_APP_FAIL=0; STUB_NO_VM_ID_LINE=1
run_guard
STUB_NO_VM_ID_LINE=0
if [[ "$GUARD_RC" -eq 1 ]] \
   && grep -q 'G7' <<< "$GUARD_OUT" \
   && grep -qi 'could not parse current VMID' <<< "$GUARD_OUT" \
   && grep -qi 'failing closed' <<< "$GUARD_OUT" \
   && grep -q 'gitlab' <<< "$GUARD_OUT"; then
  test_pass "unparseable state show output fails closed with G7 diagnostic"
else
  test_fail "expected rc 1 + G7 fail-closed + could-not-parse, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi

# --- Case 7: state show fails on APP path -> FAIL CLOSED ------------------
# Codex and the fork sub-claude reviewer both called out that the previous
# fixture's `applications: {}` left the wrapper's second `for app_key …
# for env …` loop (which is a near-duplicate of the infra loop, so a
# refactor could break only that copy) entirely un-exercised. The fixture
# now enables an app `foo/prod`. Gitlab's show succeeds with its planned
# VMID (no infra drift) so the guard reaches the app loop; then STUB_SHOW_APP_FAIL
# makes the app's own state show error out, exercising the app loop's
# fail-closed rc-branch — the same class as Case 4 but on the app path.
test_start "7" "state show fails on app path -> fail closed via app loop"
STUB_STATE_FAIL=0; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=0
STUB_SHOW_APP_FAIL=1; STUB_NO_VM_ID_LINE=0
STUB_CURRENT_VMID=150   # gitlab matches planned -> no drift for infra loop
run_guard
STUB_SHOW_APP_FAIL=0
if [[ "$GUARD_RC" -eq 1 ]] \
   && grep -q 'G7' <<< "$GUARD_OUT" \
   && grep -qi 'failing closed' <<< "$GUARD_OUT" \
   && grep -qi 'current VMID' <<< "$GUARD_OUT" \
   && grep -q 'pq: connection refused' <<< "$GUARD_OUT" \
   && grep -q 'foo_prod' <<< "$GUARD_OUT"; then
  test_pass "app-loop state show error fails closed with G7 + app label"
else
  test_fail "expected rc 1 + G7 fail-closed via app loop, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi


# --- Case 8: pair-structured DNS VM (regression for #542 bug 1) ----------
# Pre-#542: for vm_key=dns1_prod the guard did
#   grep -i "$(echo dns1_prod | tr '_' '-')" = grep -i "dns1-prod"
# against state list containing `module.dns_prod.module.dns1.…`. The
# literal substring "dns1-prod" is not present, so VM_ADDR was empty and
# the guard silently continued — meaning DNS VMs got NO drift protection.
# The fix pins outer=dns_prod AND inner=dns1 with an anchored regex.
#
# This case: config has dns1_prod with backup: true and a stub state
# list that includes the real dns-pair address. STUB_DNS1_CURRENT_VMID is
# tweaked to 999 to force a drift; the guard must detect it and block
# with the PRECIOUS STATE annotation. Case 8b re-runs with matching VMID
# and asserts no false-fire.
test_start "8" "pair-structured dns1_prod: drift is detected (was silently missed pre-#542)"
FIXTURE_CONFIG_DNS="${TMP_DIR}/config-dns.yaml"
cat > "$FIXTURE_CONFIG_DNS" <<CFG
vms:
  gitlab:
    vmid: 150
    backup: true
  dns1_prod:
    vmid: 104
    backup: true
CFG
CONFIG_FILE_SAVED="$CONFIG_FILE"
CONFIG_FILE="$FIXTURE_CONFIG_DNS"
STUB_EMIT_DNS_PAIR=1
STUB_CURRENT_VMID=150; STUB_DNS1_CURRENT_VMID=999   # dns1 drift only
STUB_STATE_FAIL=0; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=0
STUB_SHOW_APP_FAIL=0; STUB_NO_VM_ID_LINE=0
run_guard
if [[ "$GUARD_RC" -eq 1 ]] \
   && grep -q 'VMID changes detected' <<< "$GUARD_OUT" \
   && grep -q 'dns1_prod' <<< "$GUARD_OUT" \
   && grep -q '999 → 104' <<< "$GUARD_OUT" \
   && grep -q 'HAS PRECIOUS STATE' <<< "$GUARD_OUT"; then
  test_pass "dns1_prod drift detected + PRECIOUS STATE annotation (was silent pre-#542)"
else
  test_fail "expected rc 1 + dns1_prod drift, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi

test_start "8b" "pair-structured dns1_prod: NO drift when VMID matches (no false-fire)"
STUB_DNS1_CURRENT_VMID=104
run_guard
if [[ "$GUARD_RC" -eq 0 ]]; then
  test_pass "no false-fire on matched dns1_prod VMID"
else
  test_fail "expected rc 0 for no-drift dns1_prod, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi
STUB_EMIT_DNS_PAIR=0
CONFIG_FILE="$CONFIG_FILE_SAVED"
STUB_DNS1_CURRENT_VMID=104
STUB_CURRENT_VMID=150

# --- Case 9: substring-collision resistance (regression for #542 bug 2) ---
# Pre-#542: the unanchored `grep -i` filter would allow a vm_key like
# `bar` to substring-match `module.barbaz.module.barbaz.…` and
# `head -1` would pick whichever printed first. With the anchored regex
# `^module\.bar(\.module\.[^.]+)?\.…\.vm$`, the barbaz address does
# NOT match `bar`, and vice versa.
#
# Fixture: config has both `bar` (vmid 505) and `barbaz` (vmid 506).
# State emits both addresses (barbaz FIRST so pre-#542 head -1 would
# have picked wrong for `bar`). The stub returns bar's real vmid as 999
# (drift) but barbaz's as 506 (match). The guard must report drift ONLY
# for `bar`, and MUST NOT mislabel it with barbaz's vmid.
test_start "9" "substring collision: vm_key=bar does not match module.barbaz.…"
FIXTURE_CONFIG_COLL="${TMP_DIR}/config-collide.yaml"
cat > "$FIXTURE_CONFIG_COLL" <<CFG
vms:
  gitlab:
    vmid: 150
    backup: true
  bar:
    vmid: 505
  barbaz:
    vmid: 506
CFG
CONFIG_FILE="$FIXTURE_CONFIG_COLL"
STUB_EMIT_COLLIDING_PAIR=1
STUB_BAR_CURRENT_VMID=999    # bar drifts
STUB_BARBAZ_CURRENT_VMID=506 # barbaz matches
STUB_CURRENT_VMID=150
run_guard
if [[ "$GUARD_RC" -eq 1 ]] \
   && grep -q 'VMID changes detected' <<< "$GUARD_OUT" \
   && grep -q '  bar: 999 → 505' <<< "$GUARD_OUT" \
   && ! grep -q 'barbaz:' <<< "$GUARD_OUT"; then
  test_pass "bar drift reported, barbaz not falsely conflated"
else
  test_fail "expected bar drift 999-505 without barbaz mention, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi
STUB_EMIT_COLLIDING_PAIR=0
CONFIG_FILE="$CONFIG_FILE_SAVED"

# --- Case 12: catalog-app count-shape state address (#542 P1 review fix) -
# Adversarial review of the initial #542 fix (codex P1) flagged that all
# catalog app modules in framework/tofu/root/main.tf use `count = try(...)
# ? 1 : 0`, so their state addresses carry a `[0]` index:
#     module.influxdb_dev[0].module.influxdb.proxmox_virtual_environment_vm.vm
# The initial anchored regex `^module\.${APP_MODULE}(\.module\.[^.]+)?…`
# does not accept `[0]`, so the guard silently returned "not in state" for
# every enabled catalog app — the same class of bug the fix was supposed
# to close, hidden by fixtures that used `module.foo_prod.…` without the
# index. The current regex adds `(\[[0-9]+\])?` after the outer.
#
# This case emits `module.qux_prod[0].module.qux.…` in state, adds
# qux/prod to the app fixture, and asserts drift is detected.
test_start "12" "count-shape state address (catalog app): drift is detected"
FIXTURE_APPS_COUNT="${TMP_DIR}/applications-count.yaml"
cat > "$FIXTURE_APPS_COUNT" <<CFG
applications:
  qux:
    enabled: true
    backup: true
    environments:
      prod:
        vmid: 700
CFG
APPS_CONFIG_SAVED="$APPS_CONFIG"
APPS_CONFIG="$FIXTURE_APPS_COUNT"
STUB_EMIT_COUNT_APP=1
STUB_QUX_CURRENT_VMID=888   # planned 700 → drift
STUB_STATE_FAIL=0; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=0
STUB_SHOW_APP_FAIL=0; STUB_NO_VM_ID_LINE=0
STUB_CURRENT_VMID=150  # gitlab matches, no infra drift
run_guard
if [[ "$GUARD_RC" -eq 1 ]] \
   && grep -q 'VMID changes detected' <<< "$GUARD_OUT" \
   && grep -q 'qux_prod' <<< "$GUARD_OUT" \
   && grep -q '888 → 700' <<< "$GUARD_OUT" \
   && grep -q 'HAS PRECIOUS STATE' <<< "$GUARD_OUT"; then
  test_pass "count-shape address matched; qux_prod drift detected"
else
  test_fail "expected rc 1 + qux_prod drift, got rc=$GUARD_RC out=[$GUARD_OUT]"
fi
STUB_EMIT_COUNT_APP=0
STUB_QUX_CURRENT_VMID=700
export STUB_NESTED_VM_ID
STUB_NESTED_VM_ID=0
APPS_CONFIG="$APPS_CONFIG_SAVED"


# --- Case 10: nested vm_id substring — anchored parse (regression #543 item 2)
# Pre-#543: `grep "vm_id" <<< "$vmid_show_output" | head -1` matched
# `template_vm_id = 42` as the first line and awk-extracted 42 as the
# "current" VMID — wrong. Post-#543: `grep -E '^ *vm_id *='` anchors to
# the top-level vm_id attribute and skips nested-attribute lines like
# `template_vm_id`. Case 10 emits `template_vm_id = 42` before `vm_id = 150`;
# the guard must read 150 (matching planned, no drift) rather than 42
# (which would falsely fire drift 42 → 150).
test_start "10" "nested template_vm_id: anchored parse picks real vm_id (not the nested substring)"
STUB_STATE_FAIL=0; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=0
STUB_SHOW_APP_FAIL=0; STUB_NO_VM_ID_LINE=0
STUB_NESTED_VM_ID=1
STUB_CURRENT_VMID=150  # planned matches; no drift expected
run_guard
STUB_NESTED_VM_ID=0
if [[ "$GUARD_RC" -eq 0 ]]; then
  test_pass "anchored ^ *vm_id *= skipped template_vm_id, read 150 correctly"
else
  test_fail "expected rc 0 (no drift on matched 150), got rc=$GUARD_RC out=[$GUARD_OUT]"
fi

# --- Case 11: null-safe `.vms // {}` (regression #543 item 3) -------------
# Pre-#543: `yq -r '.vms | keys | .[]'` errored under `set -e` when
# .vms was missing (empty config), which killed the wrapper. Post-#543:
# `.vms // {}` treats a missing .vms block as empty; the infra loop is
# skipped and the guard proceeds to the app loop.
test_start "11" "config with no .vms block: null-safe yq, guard proceeds"
FIXTURE_CONFIG_EMPTY="${TMP_DIR}/config-no-vms.yaml"
cat > "$FIXTURE_CONFIG_EMPTY" <<CFG
# Deliberately empty — no vms: block. Pre-#543 would abort here.
CFG
CONFIG_FILE_SAVED2="$CONFIG_FILE"
CONFIG_FILE="$FIXTURE_CONFIG_EMPTY"
STUB_STATE_FAIL=0; STUB_EMPTY_STATE=0; STUB_SHOW_FAIL=0
STUB_SHOW_APP_FAIL=0; STUB_NO_VM_ID_LINE=0
STUB_APP_CURRENT_VMID=200  # foo_prod matches its planned VMID (200)
run_guard
CONFIG_FILE="$CONFIG_FILE_SAVED2"
if [[ "$GUARD_RC" -eq 0 ]]; then
  test_pass "missing .vms block handled by // {} — app loop proceeds"
else
  test_fail "expected rc 0 (empty .vms + matching app), got rc=$GUARD_RC out=[$GUARD_OUT]"
fi

runner_summary
