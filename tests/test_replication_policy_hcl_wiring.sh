#!/usr/bin/env bash
# test_replication_policy_hcl_wiring.sh — Sprint 047 #691 equivalence ratchet.
#
# #691 introduces an interim HA-retry damage limiter in
# framework/tofu/modules/proxmox-vm/ha.tf that clamps max_restart /
# max_relocate to 0 for POLICY-OFF VMs and leaves them unset for
# POLICY-ON VMs. The per-VM policy is wired from framework/tofu/root/
# main.tf through every proxmox-vm-based module invocation via a new
# `replication_policy_on` variable.
#
# V5.1 (Sprint 047) mandates ONE replication-policy authority:
# framework/scripts/list-replicated-vmids.sh. #691 needs the same policy
# available in HCL at `tofu plan` time, but shelling out from HCL
# (`data.external`) would require vendoring hashicorp/external in the
# sovereign provider mirror — a large change that this fix must not
# require (see #691 review P1-1). The pragmatic answer is the sanctioned
# V5.1 alternative for exactly this shape: re-derive the same rule in
# HCL, add the .tf file to the V5.1.a allowlist, and add an equivalence
# ratchet that fails closed if HCL and shell drift.
#
# THIS TEST IS THAT RATCHET. It asserts:
#
#   1. Structural — main.tf declares
#      local.replication_policy_on_by_vmid computed from the SAME field
#      names as the helper (`replicate`, `backup`, `enabled`); the local
#      is derived from local.config.vms + local.applications (not from
#      any shell-out) and uses the same policy rule shape as the helper
#      (`explicit replicate → else backup:true → else false`).
#
#   2. Interior — the ha.tf files (proxmox-vm/ha.tf, and the inline
#      haresource in pbs/main.tf) set max_restart / max_relocate
#      conditionally on `var.replication_policy_on == false`. The
#      sentinel is exactly that shape; a change to `!= true` or similar
#      trips this test.
#
#   3. Structural — every root module invocation that owns a VMID
#      passes `replication_policy_on` (or, for dns-pair, both
#      `dns1_replication_policy_on` and `dns2_replication_policy_on`)
#      looked up from local.replication_policy_on_by_vmid keyed by that
#      module's OWN VMID expression. This is the anti-desync ratchet:
#      it catches "vault_prod keyed by cicd.vmid" mis-wires.
#
#   4. Semantic equivalence — the shell helper's output for the current
#      site config matches an independent Python mimic of the SAME rule
#      applied to the same config. If shell OR the mimic drift, this
#      fires. And the same mimic is used to derive the expected
#      policy-off / policy-on sets that `.claude/rules/replication.md`
#      documents.
#
#   5. Semantic anchoring — the operator-documented policy-off /
#      policy-on sets (as of 2026-07-20, in the #691 MR body) match the
#      helper's output on the current site config. Any policy change
#      fires this and requires operator confirmation to update.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${TEST_DIR}/.." && pwd)"
source "${TEST_DIR}/lib/runner.sh"

MAIN_TF="${REPO_DIR}/framework/tofu/root/main.tf"
HELPER="${REPO_DIR}/framework/scripts/list-replicated-vmids.sh"
PROXMOX_VM_HA="${REPO_DIR}/framework/tofu/modules/proxmox-vm/ha.tf"
PBS_MAIN="${REPO_DIR}/framework/tofu/modules/pbs/main.tf"
DNS_PAIR_MAIN="${REPO_DIR}/framework/tofu/modules/dns-pair/main.tf"

# ---------------------------------------------------------------------------
# 1. Structural — HCL policy local uses the SAME rule shape as the helper.
# ---------------------------------------------------------------------------
test_start "1.a" "main.tf defines local.replication_policy_on_by_vmid"
if grep -qE '^\s+replication_policy_on_by_vmid\s*=' "$MAIN_TF"; then
  test_pass "local declared"
else
  test_fail "local.replication_policy_on_by_vmid missing from main.tf"
fi

test_start "1.b" "HCL rule references replicate + enabled fields (MR-4/MR-5 override-only)"
# Sprint 048 MR-4/MR-5: HCL rule was rescoped to override-only —
# `backup` no longer participates because default-precious is a
# helper-side concern; the HCL only distinguishes "literal
# replicate:false" from everything else.
POLICY_BLOCK=$(awk '/# --- Sprint 047 #691 replication-policy wiring ---/,/^}$/' "$MAIN_TF")
missing=""
for field in "replicate" "enabled"; do
  if ! echo "$POLICY_BLOCK" | grep -qE "\.${field}\b|\"${field}\""; then
    missing="$missing $field"
  fi
done
if [[ -z "$missing" ]]; then
  test_pass "HCL rule references replicate + enabled (backup deliberately dropped at MR-5)"
else
  test_fail "HCL rule missing references to fields:$missing"
fi

test_start "1.c" "HCL rule shape matches helper --off (literal replicate:false only)"
# Sprint 048 MR-5 rescope: policy_on is TRUE for every enabled VM
# EXCEPT those with literal `replicate: false`. Assert the shape
# `!(contains(keys(...), "replicate") && ...replicate == false)`
# appears in the block — the override-contract predicate.
if echo "$POLICY_BLOCK" | grep -q 'contains(keys' \
   && echo "$POLICY_BLOCK" | grep -qE '\.replicate *== *false'; then
  test_pass "HCL rule shape matches helper's --off (literal replicate:false only)"
else
  test_fail "HCL rule shape does not match the MR-5 override-only rule"
fi

# ---------------------------------------------------------------------------
# 2. Interior — the ha.tf sentinels use the correct '== false ? 0 : null'
#    shape. Applies to the shared proxmox-vm/ha.tf (also symlinked into
#    proxmox-vm-precious and proxmox-vm-field-updatable) and to the pbs
#    inline haresource.
# ---------------------------------------------------------------------------
test_start "2.a" "proxmox-vm/ha.tf clamps max_restart on policy_on == false"
if grep -qE 'max_restart\s*=\s*var\.replication_policy_on\s*==\s*false\s*\?\s*0\s*:\s*null' "$PROXMOX_VM_HA"; then
  test_pass "max_restart guard uses '== false ? 0 : null'"
else
  test_fail "proxmox-vm/ha.tf max_restart guard is not the expected shape"
fi

test_start "2.b" "proxmox-vm/ha.tf clamps max_relocate on policy_on == false"
if grep -qE 'max_relocate\s*=\s*var\.replication_policy_on\s*==\s*false\s*\?\s*0\s*:\s*null' "$PROXMOX_VM_HA"; then
  test_pass "max_relocate guard uses '== false ? 0 : null'"
else
  test_fail "proxmox-vm/ha.tf max_relocate guard is not the expected shape"
fi

test_start "2.c" "pbs/main.tf inline haresource uses the same guard shape"
if grep -qE 'max_restart\s*=\s*var\.replication_policy_on\s*==\s*false\s*\?\s*0\s*:\s*null' "$PBS_MAIN" \
   && grep -qE 'max_relocate\s*=\s*var\.replication_policy_on\s*==\s*false\s*\?\s*0\s*:\s*null' "$PBS_MAIN"; then
  test_pass "pbs inline haresource matches"
else
  test_fail "pbs/main.tf inline haresource guards do not match the proxmox-vm/ha.tf shape"
fi

# ---------------------------------------------------------------------------
# 3. Structural — every root module invocation wires replication_policy_on
#    keyed by its OWN VMID expression. This catches "vault_prod keyed by
#    cicd.vmid" mis-wires.
# ---------------------------------------------------------------------------
test_start "3.a" "every root module invocation wires replication_policy_on"
mod_count=$(grep -cE '^module "' "$MAIN_TF")
# Assignments come in two shapes: `replication_policy_on = ...` (regular
# modules) and `dns1_replication_policy_on = ... / dns2_replication_policy_on = ...`
# (dns-pair, which is one module block but wires two VMs).
# One dns-pair block counts as one module but has two policy assignments,
# so tally: (regular replication_policy_on lines) + (dns1/dns2 lines /2
# per pair, i.e., 1 per pair). Simpler: count dns_pair modules once, all
# others once.
regular_assignments=$(grep -cE '^\s+replication_policy_on\s*=' "$MAIN_TF")
dns_pair_assignments=$(grep -cE '^\s+dns1_replication_policy_on\s*=' "$MAIN_TF")
# Each dns-pair module contributes ONE effective wiring in the tally
# (both dns1_ and dns2_ are its per-VM assignments). We assert:
#   assignments_effective == mod_count
# where assignments_effective = regular + dns_pair_count
if [[ "$((regular_assignments + dns_pair_assignments))" -eq "$mod_count" ]]; then
  test_pass "$mod_count module blocks; $regular_assignments single + $dns_pair_assignments dns-pair wirings match"
else
  test_fail "module blocks=$mod_count, effective wirings=$((regular_assignments + dns_pair_assignments)) (must match)"
fi

test_start "3.b" "every module's policy lookup keys by that module's own vm_id expression"
# Parse each module block and confirm the VMID expression used in the
# lookup matches the module's own vm_id / dns1_vm_id / dns2_vm_id
# expression. This is the anti-desync ratchet.
python3 - "$MAIN_TF" <<'PY'
import re, sys, pathlib
main_tf = pathlib.Path(sys.argv[1]).read_text()

# Split into module blocks by finding `^module "...` and the matching `^}`.
# Simple approach: iterate lines; a module block starts at `module "name" {`
# (indent 0) and ends at `^}` (indent 0).
blocks = []
current = None
for lineno, line in enumerate(main_tf.splitlines(), start=1):
    m = re.match(r'^module "(?P<name>[^"]+)" \{', line)
    if m:
        current = {"name": m.group("name"), "start": lineno, "lines": [], "vm_id": None,
                   "dns1_vm_id": None, "dns2_vm_id": None,
                   "wirings": []}
    if current is not None:
        current["lines"].append(line)
        # Capture vm_id / dns1_vm_id / dns2_vm_id assignments
        for key in ("vm_id", "dns1_vm_id", "dns2_vm_id"):
            m = re.match(rf'^\s+{key}\s*=\s*(.+?)\s*$', line)
            if m:
                current[key] = m.group(1)
        # Capture replication_policy_on / dns1_replication_policy_on / dns2_replication_policy_on
        for key in ("replication_policy_on", "dns1_replication_policy_on", "dns2_replication_policy_on"):
            m = re.match(rf'^\s+{key}\s*=\s*(.+?)\s*$', line)
            if m:
                current["wirings"].append((key, m.group(1)))
        if line == "}":
            blocks.append(current)
            current = None

def normalize(expr):
    """Strip a wrapping try(<inner>, null) and normalize whitespace.

    Catalog modules wrap vm_id in `try(..., null)` for the count=0 path
    but pass the same raw expression to the policy lookup, or vice
    versa. The two forms are semantically identical (both evaluate to
    the same VMID when the app is enabled, and both are unused when
    count=0). Compare after stripping the defensive wrapper.
    """
    if expr is None:
        return None
    s = expr.strip()
    m = re.match(r'^try\((.+),\s*null\)$', s)
    if m:
        s = m.group(1).strip()
    return s.replace(' ', '')

fails = []
for b in blocks:
    for wire_key, wire_expr in b["wirings"]:
        # Extract the vmid expression from tostring(<expr>) inside the
        # (possibly-try-wrapped) lookup: `try(local.map[tostring(<X>)], null)`
        # or the bare `local.map[tostring(<X>)]`.
        m = re.search(r'tostring\((.+?)\)\]', wire_expr)
        if not m:
            fails.append(f"module {b['name']}: wiring {wire_key} does not use tostring(<expr>): {wire_expr}")
            continue
        wire_vmid = m.group(1)
        # Determine which vm_id source this wiring should match
        if wire_key == "dns1_replication_policy_on":
            expected_source = b["dns1_vm_id"]
            label = "dns1_vm_id"
        elif wire_key == "dns2_replication_policy_on":
            expected_source = b["dns2_vm_id"]
            label = "dns2_vm_id"
        else:
            expected_source = b["vm_id"]
            label = "vm_id"
        if expected_source is None:
            fails.append(f"module {b['name']}: wires {wire_key} but has no {label}")
            continue
        # Normalize both sides (strip try(..., null), collapse whitespace)
        if normalize(wire_vmid) != normalize(expected_source):
            fails.append(
                f"module {b['name']}: {wire_key} keys by '{wire_vmid}' "
                f"but {label} is '{expected_source}'"
            )
if fails:
    print("VMID desync detected in module wirings:", file=sys.stderr)
    for f in fails:
        print(f"  {f}", file=sys.stderr)
    sys.exit(1)
PY
if [[ $? -eq 0 ]]; then
  test_pass "every wiring keys by its module's own vm_id expression"
else
  test_fail "3.b: at least one module wiring keys by a different VMID than its vm_id"
fi

# ---------------------------------------------------------------------------
# 4. Semantic equivalence — shell helper output == independent Python mimic
#    output for the current site config. The mimic implements the SAME
#    rule (explicit replicate → else backup:true → else false) that both
#    the shell helper and the HCL local implement. If any two of the
#    three drift, at least one check in this test catches it.
# ---------------------------------------------------------------------------
test_start "4.a" "helper output equals independent Python mimic of the same rule"
python3 - "$REPO_DIR" "$HELPER" <<'PY'
import json, subprocess, sys

repo, helper = sys.argv[1], sys.argv[2]

def load(path):
    return json.loads(subprocess.check_output(["yq", "-o=json", ".", path], text=True))

cfg = load(f"{repo}/site/config.yaml")
try:
    apps = load(f"{repo}/site/applications.yaml")
except Exception:
    apps = {"applications": {}}

# Sprint 048 MR-4/MR-5: policy_on is TRUE for every VM except those
# with LITERAL `replicate: false` (the override-contract set — empty
# on the shipped site under MR-4 doctrine). The mimic must match the
# HCL rule (main.tf locals _fw_vm_policy / _app_vm_policy) and the
# helper's --off output byte-for-byte.
policy = {}
for name, vm in (cfg.get("vms") or {}).items():
    if vm.get("enabled", True) is False:
        continue
    # policy_on = NOT (explicit replicate: false)
    policy[vm["vmid"]] = not ("replicate" in vm and vm["replicate"] is False)

for app_name, app in (apps.get("applications") or {}).items():
    if app.get("enabled") is not True:
        continue
    app_off = "replicate" in app and app["replicate"] is False
    for env, env_cfg in (app.get("environments") or {}).items():
        policy[env_cfg["vmid"]] = not app_off

mimic_off = sorted(v for v, on in policy.items() if not on)
mimic_on = sorted(v for v, on in policy.items() if on)

helper_off_csv = subprocess.check_output([helper, "--mode", "policy-off", "all"], text=True).strip()
helper_on_csv = subprocess.check_output([helper, "--mode", "replicated", "all"], text=True).strip()
h_off = sorted(int(x) for x in helper_off_csv.split(",") if x)
h_on = sorted(int(x) for x in helper_on_csv.split(",") if x)

ok = True
if mimic_off != h_off:
    print(f"    mimic policy-off: {mimic_off}", file=sys.stderr)
    print(f"    helper policy-off: {h_off}", file=sys.stderr)
    ok = False
if mimic_on != h_on:
    print(f"    mimic policy-on: {mimic_on}", file=sys.stderr)
    print(f"    helper policy-on: {h_on}", file=sys.stderr)
    ok = False
sys.exit(0 if ok else 1)
PY
if [[ $? -eq 0 ]]; then
  test_pass "helper agrees with independent Python mimic on the current site config"
else
  test_fail "4.a: helper diverges from independent Python mimic of the same rule"
fi

# ---------------------------------------------------------------------------
# 5. Semantic anchoring — the MR-documented expected sets match the
#    helper's output today. Any policy change on the current site
#    (a VM added/removed, opted in/out) fires this and requires operator
#    intent confirmation before merging.
# ---------------------------------------------------------------------------
test_start "5" "helper output matches Sprint 048 MR-4 universal manifest (20 POLICY_ON, empty --off)"
# Sprint 048 MR-4 T4.1/T4.2 doctrine flip: all 20 enabled VMs are
# POLICY_ON; --off is empty (zero literal `replicate: false` shipped).
# --mode policy-off is also empty under MR-4 defaults (every derivable
# gets a cadence, so cadence != None for every enabled VM).
EXPECTED_OFF=""
EXPECTED_ON="150,160,170,190,301,302,303,305,401,402,403,404,500,501,502,503,600,601,602,603"

actual_off=$("$HELPER" --format csv --off all | tr ',' '\n' | sort -n | paste -sd, -)
actual_on=$("$HELPER" --format csv --mode replicated all | tr ',' '\n' | sort -n | paste -sd, -)

if [[ "$actual_off" == "$EXPECTED_OFF" && "$actual_on" == "$EXPECTED_ON" ]]; then
  test_pass "policy sets match Sprint 048 MR-4 universal manifest"
else
  test_fail "policy set drift — expected/actual differ"
  echo "    expected --off (empty)=$EXPECTED_OFF" >&2
  echo "    actual   --off        =$actual_off"   >&2
  echo "    expected PON =$EXPECTED_ON"  >&2
  echo "    actual   PON =$actual_on"    >&2
  echo "    (Operator: confirm intent and update the expected sets in this test.)" >&2
fi

runner_summary
