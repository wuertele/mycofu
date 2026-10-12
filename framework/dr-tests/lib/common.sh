#!/usr/bin/env bash
# common.sh — Shared library for DR test scripts.
#
# Sourced by every test script. Provides consistent structure:
# drt_init, drt_check, drt_step, drt_assert, drt_expect,
# drt_fingerprint_state, drt_verify_state_fingerprint, drt_finish.
#
# Usage in test scripts:
#   DRT_ID="DRT-001"; DRT_NAME="Warm Rebuild"
#   source "$(dirname "$0")/../lib/common.sh"
#   drt_init
#   drt_check "validate.sh is green" framework/scripts/validate.sh
#   drt_step "Taking pre-test backup"
#   drt_assert "backup completed" framework/scripts/backup-now.sh
#   drt_finish
#
# Headless mode (#523): setting DRT_HEADLESS=1 — or running with stdin
# redirected away from a TTY — routes drt_expect through a machine
# verifier or a structured BLOCKED(attended-required) verdict instead
# of an interactive `read`. See drt_expect below.

# --- State tracking ---
# DRT_ID and DRT_NAME are set by the test script BEFORE sourcing this file.
# Do not reset them here.
DRT_COMMIT=""
DRT_START=""
DRT_START_EPOCH=0
DRT_STEP_NUM=0
DRT_FAILURES=0
DRT_FAILURE_LIST=()
DRT_WARNINGS=0
DRT_WARNING_LIST=()
DRT_COVERAGE_LIST=()
DRT_VM_DISKS_BASELINE=""
DRT_BLOCKED_LIST=()
DRT_FINGERPRINT=""
# Set by drt_finish on its first invocation to make the function idempotent
# under callers that also install `trap drt_finish EXIT` (re-entrancy guard).
DRT_FINISHED=0

# Distinct exit code for a BLOCKED test (POSIX-style skip convention). Not 0
# (PASS) and not 1 (FAIL) — a genuinely-third outcome so callers, wrappers,
# and CI cannot silently misclassify a headless attended-only run as PASS.
# A run with both real failures AND blocked steps ALWAYS exits 1 (FAIL); the
# blocked list is surfaced in the verdict block for context but does not
# soft-classify a genuinely-failing run as skipped.
DRT_BLOCKED_EXIT=77

# --- Headless detection ---
# A "headless" run is one where the operator is not present to answer an
# interactive prompt. Two triggers:
#   - `DRT_HEADLESS=1` explicit override — set by CI jobs, agent sessions,
#     the drt-lib self-test, or any wrapper that knows attended prompts
#     cannot be serviced.
#   - stdin is not a TTY (`[ ! -t 0 ]`) — matches agent shells, piped runs,
#     `< /dev/null`, and non-interactive CI shells even without the override.
# Structural property: once _drt_is_headless returns true, drt_expect NEVER
# invokes `read`. That is the impossibility guarantee this fix rests on —
# with no `read` there is no EOF, no `set -e` abort, and no path from a
# closed stdin to a manufactured [FAIL] block.
_drt_is_headless() {
  if [[ "${DRT_HEADLESS:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    return 0
  fi
  return 1
}

# --- Init ---

drt_init() {
  # Verify repo root
  if [[ ! -d "framework/dr-tests" ]]; then
    echo "ERROR: Must run from the repo root (framework/dr-tests/ not found)" >&2
    echo "  cd to your repo root and run: framework/dr-tests/run-dr-test.sh ${DRT_ID}" >&2
    exit 1
  fi

  DRT_COMMIT=$(git rev-parse --short HEAD)
  DRT_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  DRT_START_EPOCH=$(date +%s)

  echo "════════════════════════════════════════════════════════"
  echo "${DRT_ID} ${DRT_NAME}"
  echo "Commit:  ${DRT_COMMIT}"
  echo "Started: ${DRT_START}"
  echo "════════════════════════════════════════════════════════"
  echo ""
}

# --- Precondition check (fatal on failure) ---

drt_check() {
  local desc="$1"; shift
  printf "[PRE] %s... " "$desc"
  local output rc
  set +e
  output=$("$@" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "OK"
  else
    echo "FAILED"
    echo "      Command: $*"
    echo "$output" | tail -5 | sed 's/^/      /'
    echo ""
    echo "Precondition failed — test did not run."
    exit 1
  fi
}

# --- Step marker ---

drt_step() {
  DRT_STEP_NUM=$((DRT_STEP_NUM + 1))
  echo ""
  echo "[${DRT_STEP_NUM}] $1"
}

# --- Assertion (non-fatal, collects failures) ---

drt_assert() {
  local desc="$1"; shift
  local output rc
  set +e
  output=$("$@" 2>&1)
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "[PASS] ${desc}"
  else
    echo "[FAIL] ${desc}"
    echo "       Command: $*"
    echo "       Expected: exit 0"
    echo "       Got: exit ${rc}"
    echo "$output" | tail -10 | sed 's/^/       /'
    DRT_FAILURES=$((DRT_FAILURES + 1))
    DRT_FAILURE_LIST+=("$desc")
  fi
}

# --- Non-fatal warning (recorded as a registry note, not a silent log) ---
# A WARN does not fail the DRT, but it IS carried into the DR-REGISTRY paste
# block emitted by drt_finish. A soft-threshold breach — a migration slower than
# the WARN band, or a live cluster shape that differs from the baseline the bands
# were measured against (Sprint 045 / #515) — must be recorded where the operator
# reviews the run, not buried in scrollback.
drt_warn() {
  local desc="$1"
  echo "[WARN] ${desc}"
  DRT_WARNINGS=$((DRT_WARNINGS + 1))
  DRT_WARNING_LIST+=("$desc")
}

# --- Manual expectation (operator confirms) ---
#
# Usage:
#   drt_expect "<description>"                 — attended-only step
#   drt_expect "<description>" <verify_cmd>... — machine-verifiable step
#
# TTY behavior (unchanged): prompt operator for y/N; y → PASS, else → FAIL
# (recorded, script continues — mirrors drt_assert). The operator can observe
# the [FAIL] line and intervene manually if the failure is unsafe to proceed
# past.
#
# Headless behavior (issue #523 fix — structural elimination of manufactured
# FAILs on EOF stdin):
#   - With a verify_cmd: execute it. Exit 0 → PASS, script continues. Non-zero
#     → real [FAIL] with the tail of the verifier's output, THEN drt_finish +
#     exit 1. drt_expect failures are *terminal in headless mode* because there
#     is no operator to observe the [FAIL] and stop the script; the prerequisite
#     the step guards has not been established, and continuing may mutate
#     cluster state against unverified conditions (the DRT-005 "power off ->
#     rebalance-cluster.sh" concern). Use drt_assert if you specifically want
#     record-and-continue semantics under a machine check.
#   - Without a verify_cmd: emit [SKIP-ATTENDED], record the step on
#     DRT_BLOCKED_LIST, print the BLOCKED verdict via drt_finish, and exit
#     $DRT_BLOCKED_EXIT. This terminates the test *immediately* so that no
#     subsequent step (poll loops, rebalance-cluster.sh, `qm start`, etc.)
#     runs against unverified cluster state. The impossibility of "manufactured
#     FAIL then side-effect commands" is enforced by this early exit, not by
#     hoping every downstream caller checks a flag.
#
# Complex verifiers (pipes, redirects, conditionals) must be wrapped in
# `bash -c '<cmd>'` — drt_expect uses `"$@"` for the verifier, same as
# drt_assert, so shell metacharacters are NOT re-interpreted after argument
# expansion. Example:
#   drt_expect "pipeline is green" bash -c '
#     status=$(curl -sk ... | jq -r .status)
#     [[ "$status" == "success" ]]
#   '
drt_expect() {
  if [[ $# -lt 1 ]]; then
    echo "drt_expect: internal error — missing description" >&2
    exit 1
  fi
  local desc="$1"; shift
  echo ""

  if _drt_is_headless; then
    if [[ $# -gt 0 ]]; then
      # Machine-verifiable step: run the verify command.
      echo "[VERIFY] Headless machine check: ${desc}"
      echo "         Command: $*"
      local output rc
      set +e
      output=$("$@" 2>&1)
      rc=$?
      set -e
      if [[ $rc -eq 0 ]]; then
        echo "[PASS] ${desc} (headless verify)"
        return 0
      fi
      echo "[FAIL] ${desc} (headless verify)"
      echo "       Expected: exit 0"
      echo "       Got: exit ${rc}"
      echo "$output" | tail -10 | sed 's/^/       /'
      DRT_FAILURES=$((DRT_FAILURES + 1))
      DRT_FAILURE_LIST+=("$desc")
      # A drt_expect failure in headless mode is TERMINAL. The prerequisite
      # is not established; downstream steps may mutate cluster state.
      drt_finish
      # drt_finish exits; defensive belt-and-braces.
      exit 1
    fi

    # Attended-only step reached under a headless run — never manufacture a
    # FAIL, never proceed into any following step (which may mutate cluster
    # state). Record BLOCKED and terminate the whole test now.
    #
    # Deliberately do NOT reprint the raw description as an imperative before
    # the SKIP marker: DRT-005's "Power off node X now" descriptions are
    # written for an attended operator; echoing that verbatim on the headless
    # path invites a log-reader to think a physical action was expected.
    echo "[SKIP-ATTENDED] ${desc}"
    echo "    Attended-only step reached in headless mode. No physical/manual"
    echo "    action was performed. This DRT cannot certify PASS or FAIL for"
    echo "    this step without an operator."
    echo "    Rerun this test at an interactive terminal:"
    echo "        framework/dr-tests/run-dr-test.sh ${DRT_ID}"
    DRT_BLOCKED_LIST+=("$desc")
    drt_finish
    # drt_finish exits; defensive belt-and-braces.
    exit "$DRT_BLOCKED_EXIT"
  fi

  # TTY path (unchanged pre-fix behavior).
  echo "[?] Verify manually: ${desc}"
  local response
  read -rp "    Pass? [y/N]: " response
  if [[ "$response" == "y" || "$response" == "Y" ]]; then
    echo "[PASS] ${desc} (operator confirmed)"
  else
    echo "[FAIL] ${desc} (operator rejected)"
    DRT_FAILURES=$((DRT_FAILURES + 1))
    DRT_FAILURE_LIST+=("$desc")
  fi
}

# --- Helper functions ---

# Curl wrapper — always includes --max-time to prevent indefinite hangs
drt_curl() {
  curl --max-time 10 "$@"
}

drt_config() { yq "$1" site/config.yaml; }

drt_app_config() {
  [ -f site/applications.yaml ] && yq "$1" site/applications.yaml || echo ""
}

drt_vm_ip() {
  local name="$1" env="${2:-prod}"
  local ip

  # Try infra flat schema: .vms.<name>_<env>.ip
  ip=$(yq -r ".vms.${name}_${env}.ip" site/config.yaml 2>/dev/null)
  [[ "$ip" == "null" ]] && ip=""

  # Try infra flat schema without env suffix: .vms.<name>.ip (shared VMs)
  if [ -z "$ip" ]; then
    ip=$(yq -r ".vms.${name}.ip" site/config.yaml 2>/dev/null)
    [[ "$ip" == "null" ]] && ip=""
  fi

  # Try app nested schema: .applications.<name>.environments.<env>.ip
  if [ -z "$ip" ] && [ -f site/applications.yaml ]; then
    ip=$(yq -r ".applications.${name}.environments.${env}.ip" \
      site/applications.yaml 2>/dev/null)
    [[ "$ip" == "null" ]] && ip=""
  fi

  echo "$ip"
}

drt_vm_vmid() {
  local name="$1" env="${2:-prod}"
  local vmid

  vmid=$(yq -r ".vms.${name}_${env}.vmid" site/config.yaml 2>/dev/null)
  [[ "$vmid" == "null" ]] && vmid=""
  if [ -z "$vmid" ]; then
    vmid=$(yq -r ".vms.${name}.vmid" site/config.yaml 2>/dev/null)
    [[ "$vmid" == "null" ]] && vmid=""
  fi
  if [ -z "$vmid" ] && [ -f site/applications.yaml ]; then
    vmid=$(yq -r ".applications.${name}.environments.${env}.vmid" \
      site/applications.yaml 2>/dev/null)
    [[ "$vmid" == "null" ]] && vmid=""
  fi

  echo "$vmid"
}

drt_node_ip() {
  local node_name="$1"
  yq ".nodes[] | select(.name == \"${node_name}\") | .mgmt_ip" site/config.yaml
}

drt_domain() { yq '.domain' site/config.yaml; }

drt_sops_value() {
  local key_file="${SOPS_AGE_KEY_FILE:-operator.age.key}"
  SOPS_AGE_KEY_FILE="$key_file" sops -d site/sops/secrets.yaml | yq "$1"
}

drt_elapsed() {
  local end; end=$(date +%s)
  local elapsed=$((end - DRT_START_EPOCH))
  printf "%dm %ds" $((elapsed / 60)) $((elapsed % 60))
}

# --- VM recreation evidence ---

# The inventory follows config's flat VM labels and enabled app environments.
# Unsuffixed VM labels are shared; PBS is outside recreation coverage.
drt_in_scope_vmids() {
  python3 - "$1" <<'PY'
import json
import os
import subprocess
import sys

scope = sys.argv[1]
if scope not in {"dev", "prod", "all"}:
    sys.exit("Expected VM scope dev, prod, or all")

def load(path):
    return json.loads(subprocess.check_output(["yq", "-o=json", ".", path], text=True))

config = load("site/config.yaml")
apps = load("site/applications.yaml") if os.path.exists("site/applications.yaml") else {}
vmids = set()

def add(label, env, vm):
    if scope != "all" and env != scope:
        return
    value = vm.get("vmid")
    if isinstance(value, bool) or not str(value).isdigit() or int(value) <= 0:
        sys.exit(f"Invalid or missing VMID for {label}: {value!r}")
    value = int(value)
    if value in vmids:
        sys.exit(f"Duplicate in-scope VMID: {value} ({label})")
    vmids.add(value)

for label, vm in config["vms"].items():
    if label == "pbs" or vm.get("enabled", True) is False:
        continue
    env = "dev" if label.endswith("_dev") else "prod" if label.endswith("_prod") else "shared"
    add(label, env, vm)
for label, app in (apps.get("applications") or {}).items():
    if app.get("enabled") is not True:
        continue
    for env, vm in (app.get("environments") or {}).items():
        if vm.get("enabled", True) is not False:
            add(f"{label}_{env}", env, vm)
if not vmids:
    sys.exit(f"No VMIDs found for recreation scope {scope}")
print("\n".join(str(vmid) for vmid in sorted(vmids)))
PY
}

# Write a disk snapshot, collecting every node before accepting any evidence.
# Pool resolution matches vdb_park_dataset_parent. disk-N is just a dataset
# name here: never infer vda/vdb from the allocation suffix, and omit CIDATA.
#
# Replication targets hold old-incarnation copies of every zvol, so a row
# is evidence only on the VM's hosting node. The hosting node is resolved at
# every read (HA may move a VM between capture and verify) from `qm list` on
# each node — the node whose local guest list carries the VMID owns it, the
# same probe shape rebuild-cluster.sh uses per node. Every row records
# `hosting`; replica rows stay in the JSON as informational context only. A
# VMID whose hosting node cannot be resolved, is listed on more than one
# node, or has no non-cloudinit disk on its hosting node fails the read.
_drt_read_vm_disks() {
  python3 - "$@" <<'PY'
import json
import re
import subprocess
import sys

out, *vmids = sys.argv[1:]
if not vmids or any(not v.isdigit() for v in vmids):
    sys.exit("At least one numeric VMID is required for disk evidence")
config = json.loads(subprocess.check_output(["yq", "-o=json", ".", "site/config.yaml"], text=True))
pool = (config.get("storage") or {}).get("pool_name") or (config.get("proxmox") or {}).get("storage_pool")
if not isinstance(pool, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", pool):
    sys.exit("Cannot resolve ZFS pool for disk evidence")
nodes = config.get("nodes")
if not isinstance(nodes, list) or not nodes:
    sys.exit("No nodes configured for disk evidence")

def remote(ip, command):
    return subprocess.check_output([
        "ssh", "-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=no", "root@" + ip, command,
    ], text=True)

disks = {vmid: [] for vmid in vmids}
hosting = {vmid: [] for vmid in vmids}
for node in nodes:
    ip = node.get("mgmt_ip")
    if not ip:
        sys.exit("Node is missing its management IP")
    raw = remote(ip, f"zfs list -Hp -o name,creation,guid -t volume -r {pool}/data")
    if not raw.strip():
        sys.exit(f"Empty ZFS volume listing from {ip}")
    for line in raw.splitlines():
        fields = line.split()
        if len(fields) != 3 or not all(v.isdigit() for v in fields[1:]):
            sys.exit(f"Invalid ZFS evidence from {ip}: {line!r}")
        name, creation, guid = fields
        match = re.fullmatch(re.escape(pool) + r"/data/vm-([0-9]+)-disk-[0-9]+", name)
        if match and match[1] in disks:
            disks[match[1]].append({"node": ip, "name": name, "creation": int(creation), "guid": guid})
    # `qm list` prints the guests whose config lives on this node; only that
    # node's zvols are the VM's live disks.
    for line in remote(ip, "qm list").splitlines():
        fields = line.split()
        if fields and fields[0].isdigit() and fields[0] in hosting:
            hosting[fields[0]].append(ip)

unresolved = [vmid for vmid, ips in hosting.items() if not ips]
if unresolved:
    sys.exit("Cannot resolve hosting node for VMIDs: " + ", ".join(unresolved))
ambiguous = [vmid for vmid, ips in hosting.items() if len(ips) > 1]
if ambiguous:
    sys.exit("VMIDs listed on more than one node: " + ", ".join(ambiguous))
for vmid, rows in disks.items():
    for row in rows:
        row["hosting"] = row["node"] == hosting[vmid][0]
missing = [vmid for vmid, rows in disks.items() if not any(row["hosting"] for row in rows)]
if missing:
    sys.exit("No non-cloudinit disks on the hosting node for VMIDs: " + ", ".join(
        f"{vmid} ({hosting[vmid][0]})" for vmid in missing))
with open(out, "w") as f:
    json.dump(disks, f)
    f.write("\n")
PY
}

# Call directly, then drt_assert the captured exit code: drt_assert runs its
# command in a subshell, which cannot set DRT_VM_DISKS_BASELINE in the caller.
drt_capture_vm_disks() {
  [[ -z "$DRT_VM_DISKS_BASELINE" ]] || rm -f "$DRT_VM_DISKS_BASELINE"
  DRT_VM_DISKS_BASELINE="$(mktemp)" || return 1
  _drt_read_vm_disks "$DRT_VM_DISKS_BASELINE" "$@"
}

drt_verify_vm_recreated() {
  local since="$1"; shift
  local current rc=0 observed=0 vmid verdict
  current="$(mktemp)" || { drt_assert "Can create disk evidence file" false; return; }
  _drt_read_vm_disks "$current" "$@" || rc=$?
  for vmid in "$@"; do
    verdict=1
    if [[ "$rc" -eq 0 ]] && jq -e --arg vmid "$vmid" --argjson since "$since" \
      'any(.[$vmid][] | select(.hosting); .creation >= $since)' "$current" >/dev/null; then
      verdict=0
      observed=$((observed + 1))
    fi
    drt_assert "VM ${vmid}: non-cloudinit disk created on its hosting node since ${since}" test "$verdict" -eq 0
  done
  [[ $# -gt 0 ]] || drt_assert "Recreation inventory is non-empty" false
  local coverage="recreation observed ${observed}/$#"
  echo "$coverage"
  DRT_COVERAGE_LIST+=("$coverage")
  rm -f "$current"
}

drt_verify_vdb_guid_preserved() {
  local current rc=0 vmid verdict
  current="$(mktemp)" || { drt_assert "Can create GUID evidence file" false; return; }
  _drt_read_vm_disks "$current" "$@" || rc=$?
  for vmid in "$@"; do
    verdict=1
    # Baseline and current rows are both restricted to the hosting node: a
    # replica that still carries the old GUID is not adoption evidence.
    if [[ "$rc" -eq 0 && -s "$DRT_VM_DISKS_BASELINE" ]] && \
      jq -e --arg vmid "$vmid" --slurpfile before "$DRT_VM_DISKS_BASELINE" \
        '[$before[0][$vmid][]? | select(.hosting) | .guid] as $guids
         | any(.[$vmid][] | select(.hosting); .guid as $g | $guids | index($g) != null)' \
        "$current" >/dev/null; then
      verdict=0
    fi
    drt_assert "VM ${vmid}: baseline disk GUID preserved on its hosting node (vdb park/adopt)" test "$verdict" -eq 0
  done
  [[ $# -gt 0 ]] || drt_assert "Precious VM inventory is non-empty" false
  rm -f "$current"
}

drt_record_plan_replacements() {
  local coverage
  if ! coverage="$(python3 - "$1" <<'PY'
import json
import sys
with open(sys.argv[1]) as f:
    plan = json.load(f)
replace = create = noop = total = 0
for rc in plan["resource_changes"]:
    if rc.get("type") != "proxmox_virtual_environment_vm" and ".proxmox_virtual_environment_vm.vm" not in rc.get("address", ""):
        continue
    total += 1
    actions = rc["change"]["actions"]
    if "replace" in actions or ("create" in actions and "delete" in actions):
        replace += 1
    elif actions == ["create"]:
        create += 1
    elif actions == ["no-op"]:
        noop += 1
print(f"replacements observed: {replace} replace / {create} create / {noop} no-op of {total} VM resources")
PY
  )"; then
    drt_warn "Could not record replacements from ${1}; retained plan is missing or unreadable"
    return 0
  fi
  echo "$coverage"
  DRT_COVERAGE_LIST+=("$coverage")
}

# --- Fingerprint state ---

drt_fingerprint_state() {
  DRT_FINGERPRINT=$(mktemp)
  echo ""
  echo "[FINGERPRINT] Capturing pre-test state..."

  local domain
  domain=$(drt_domain)

  # SSH proxy VM for Vault checks — avoids macOS TLS 1.3 incompatibility
  # with Go's post-quantum key exchange (X25519MLKEM768)
  local dns1_ip
  dns1_ip=$(drt_vm_ip dns1 prod)

  # GitLab — project count via OAuth API
  local gitlab_password gitlab_token gitlab_project_count
  gitlab_password=$(drt_sops_value '.gitlab_root_password')
  gitlab_token=$(drt_curl -sk -X POST "https://gitlab.prod.${domain}/oauth/token" \
    -d "grant_type=password&username=root&password=${gitlab_password}" 2>/dev/null \
    | jq -r '.access_token // ""')
  if [[ -n "$gitlab_token" ]]; then
    gitlab_project_count=$(drt_curl -sk \
      "https://gitlab.prod.${domain}/api/v4/projects" \
      -H "Authorization: Bearer ${gitlab_token}" 2>/dev/null | jq 'length')
  else
    gitlab_project_count="UNKNOWN"
  fi
  echo "gitlab_project_count=${gitlab_project_count}" >> "$DRT_FINGERPRINT"

  # Vault — initialized state and mount count via HTTP API
  # Curl via SSH to prod VM to avoid macOS TLS 1.3 incompatibility
  local vault_initialized vault_mount_count vault_response
  vault_response=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "root@${dns1_ip}" \
    "curl -sk --max-time 10 'https://vault.prod.${domain}:8200/v1/sys/health'" 2>/dev/null || echo "{}")
  vault_initialized=$(echo "$vault_response" | jq -r 'if .initialized == null then "UNKNOWN" else (.initialized | tostring) end')
  local vault_token
  vault_token=$(drt_sops_value '.vault_prod_root_token')
  if [[ -n "$vault_token" && "$vault_token" != "null" ]]; then
    vault_mount_count=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      "root@${dns1_ip}" \
      "curl -sk --max-time 10 -H 'X-Vault-Token: ${vault_token}' \
        'https://vault.prod.${domain}:8200/v1/sys/mounts'" 2>/dev/null \
      | jq 'keys | length')
  else
    vault_mount_count="UNKNOWN"
  fi
  echo "vault_initialized=${vault_initialized}" >> "$DRT_FINGERPRINT"
  echo "vault_mount_count=${vault_mount_count:-UNKNOWN}" >> "$DRT_FINGERPRINT"

  # InfluxDB — organization exists via HTTP API
  local influxdb_ip influxdb_token influxdb_org
  influxdb_ip=$(drt_vm_ip influxdb prod)
  influxdb_token=$(drt_sops_value '.influxdb_admin_token')
  if [[ -n "$influxdb_ip" && -n "$influxdb_token" ]]; then
    influxdb_org=$(drt_curl -sk \
      "https://${influxdb_ip}:8086/api/v2/orgs" \
      -H "Authorization: Token ${influxdb_token}" 2>/dev/null \
      | jq -r '.orgs[0].name // "UNKNOWN"')
  else
    influxdb_org="UNKNOWN"
  fi
  echo "influxdb_org=${influxdb_org}" >> "$DRT_FINGERPRINT"

  # Roon — RoonServer directory size in MB (integer for threshold comparison)
  local roon_ip roon_db_size_mb
  roon_ip=$(drt_vm_ip roon prod)
  if [[ -n "$roon_ip" ]]; then
    roon_db_size_mb=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      "root@${roon_ip}" \
      "du -sm /var/lib/roon-server/RoonServer/ 2>/dev/null | cut -f1" 2>/dev/null || echo "0")
  else
    roon_db_size_mb="0"
  fi
  echo "roon_db_size_mb=${roon_db_size_mb}" >> "$DRT_FINGERPRINT"

  echo "[FINGERPRINT] Pre-test state captured:"
  echo "  GitLab projects:     ${gitlab_project_count}"
  echo "  Vault initialized:   ${vault_initialized}"
  echo "  Vault secret mounts: ${vault_mount_count:-UNKNOWN}"
  echo "  InfluxDB org:        ${influxdb_org}"
  echo "  Roon DB size:        ${roon_db_size_mb}M"
  echo ""
}

# --- Verify fingerprint ---

drt_verify_state_fingerprint() {
  local strict="${1:-}"
  if [[ -z "$DRT_FINGERPRINT" || ! -f "$DRT_FINGERPRINT" ]]; then
    if [[ "$strict" == --strict ]]; then
      drt_assert "State fingerprint is available" false
      return
    fi
    echo "[WARN] No fingerprint file — skipping state verification"
    return
  fi

  echo ""
  echo "[VERIFY] Comparing post-test state against pre-test fingerprint..."

  local domain
  domain=$(drt_domain)

  # SSH proxy for Vault checks
  local dns1_ip
  dns1_ip=$(drt_vm_ip dns1 prod)

  # GitLab
  local pre_gitlab post_gitlab
  pre_gitlab=$(grep "gitlab_project_count=" "$DRT_FINGERPRINT" | cut -d= -f2 || echo "UNKNOWN")
  local gitlab_password gitlab_token
  gitlab_password=$(drt_sops_value '.gitlab_root_password')
  gitlab_token=$(drt_curl -sk -X POST "https://gitlab.prod.${domain}/oauth/token" \
    -d "grant_type=password&username=root&password=${gitlab_password}" 2>/dev/null \
    | jq -r '.access_token // ""')
  if [[ -n "$gitlab_token" ]]; then
    post_gitlab=$(drt_curl -sk \
      "https://gitlab.prod.${domain}/api/v4/projects" \
      -H "Authorization: Bearer ${gitlab_token}" 2>/dev/null | jq 'length')
  else
    post_gitlab="UNKNOWN"
  fi
  if [[ "$pre_gitlab" == "UNKNOWN" || "$post_gitlab" == "UNKNOWN" ]]; then
    [[ "$strict" != --strict ]] || drt_assert "GitLab fingerprint is known" false
    echo "[WARN] GitLab project count: pre=${pre_gitlab} post=${post_gitlab} (could not verify)"
  else
    drt_assert "GitLab project count: ${post_gitlab} (pre-test: ${pre_gitlab})" \
      test "$post_gitlab" -ge "$pre_gitlab"
  fi

  # Vault — via SSH to prod VM to avoid macOS TLS 1.3 incompatibility
  local pre_vault_init post_vault_init vault_response
  pre_vault_init=$(grep "vault_initialized=" "$DRT_FINGERPRINT" | cut -d= -f2 || echo "UNKNOWN")
  vault_response=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    "root@${dns1_ip}" \
    "curl -sk --max-time 10 'https://vault.prod.${domain}:8200/v1/sys/health'" 2>/dev/null || echo "{}")
  post_vault_init=$(echo "$vault_response" | jq -r 'if .initialized == null then "UNKNOWN" else (.initialized | tostring) end')
  if [[ "$strict" == --strict ]]; then
    drt_assert "Vault fingerprint is known" test "$post_vault_init" != UNKNOWN
  fi
  drt_assert "Vault initialized: ${post_vault_init} (pre-test: ${pre_vault_init})" \
    test "$post_vault_init" = "$pre_vault_init"

  local pre_vault_mounts post_vault_mounts
  pre_vault_mounts=$(grep "vault_mount_count=" "$DRT_FINGERPRINT" | cut -d= -f2 || echo "UNKNOWN")
  local vault_token
  vault_token=$(drt_sops_value '.vault_prod_root_token')
  if [[ -n "$vault_token" && "$vault_token" != "null" ]]; then
    post_vault_mounts=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      "root@${dns1_ip}" \
      "curl -sk --max-time 10 -H 'X-Vault-Token: ${vault_token}' \
        'https://vault.prod.${domain}:8200/v1/sys/mounts'" 2>/dev/null \
      | jq 'keys | length')
  else
    post_vault_mounts="UNKNOWN"
  fi
  if [[ "$pre_vault_mounts" != "UNKNOWN" && "$post_vault_mounts" != "UNKNOWN" ]]; then
    drt_assert "Vault secret mounts: ${post_vault_mounts} (pre-test: ${pre_vault_mounts})" \
      test "$post_vault_mounts" -ge "$pre_vault_mounts"
  elif [[ "$strict" == --strict ]]; then
    drt_assert "Vault mount fingerprint is known" false
  fi

  # InfluxDB
  local pre_influx post_influx
  pre_influx=$(grep "influxdb_org=" "$DRT_FINGERPRINT" | cut -d= -f2 || echo "UNKNOWN")
  local influxdb_ip influxdb_token
  influxdb_ip=$(drt_vm_ip influxdb prod)
  influxdb_token=$(drt_sops_value '.influxdb_admin_token')
  if [[ -n "$influxdb_ip" && -n "$influxdb_token" ]]; then
    post_influx=$(drt_curl -sk \
      "https://${influxdb_ip}:8086/api/v2/orgs" \
      -H "Authorization: Token ${influxdb_token}" 2>/dev/null \
      | jq -r '.orgs[0].name // "UNKNOWN"')
  else
    post_influx="UNKNOWN"
  fi
  drt_assert "InfluxDB org: ${post_influx} (pre-test: ${pre_influx})" \
    test "$post_influx" = "$pre_influx"
  if [[ "$strict" == --strict ]]; then
    drt_assert "InfluxDB fingerprint is known" test "$post_influx" != UNKNOWN
  fi

  # Roon — threshold comparison (post must be >= 50% of pre)
  local pre_roon_mb post_roon_mb
  pre_roon_mb=$(grep "roon_db_size_mb=" "$DRT_FINGERPRINT" | cut -d= -f2 || echo "0")
  if [[ "$strict" == --strict ]]; then
    drt_assert "Roon baseline contains state" test "$pre_roon_mb" -gt 0
  fi
  local roon_ip
  roon_ip=$(drt_vm_ip roon prod)
  if [[ -n "$roon_ip" ]]; then
    post_roon_mb=$(ssh -n -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
      "root@${roon_ip}" \
      "du -sm /var/lib/roon-server/RoonServer/ 2>/dev/null | cut -f1" 2>/dev/null || echo "0")
  else
    post_roon_mb="0"
  fi
  # Allow up to 50% shrinkage — Roon DB size fluctuates due to cache/temp files
  local roon_threshold
  roon_threshold=$(( pre_roon_mb / 2 ))
  drt_assert "Roon DB size: ${post_roon_mb}M (pre-test: ${pre_roon_mb}M, threshold: ${roon_threshold}M)" \
    test "$post_roon_mb" -ge "$roon_threshold"

  echo ""
}

# --- Finish ---

drt_finish() {
  # Re-entrancy guard: if a caller installed `trap drt_finish EXIT` alongside
  # our own drt_expect-driven call, ensure the verdict block prints once.
  if [[ "${DRT_FINISHED:-0}" == "1" ]]; then
    return 0
  fi
  DRT_FINISHED=1
  [[ -z "$DRT_VM_DISKS_BASELINE" ]] || rm -f "$DRT_VM_DISKS_BASELINE"

  local elapsed
  elapsed=$(drt_elapsed)

  local blocked_count=${#DRT_BLOCKED_LIST[@]}

  # Verdict precedence: FAIL > BLOCKED > PASS. A run with real assertion
  # failures always exits 1 even if a later drt_expect blocked — otherwise
  # a FAILing DRT would masquerade as SKIPPED (exit 77), which CI/wrappers
  # may treat as a soft pass.
  echo ""
  echo "════════════════════════════════════════════════════════"
  if [[ $DRT_FAILURES -eq 0 && $blocked_count -gt 0 ]]; then
    # BLOCKED: at least one attended-only step was reached under a headless
    # run without a machine verifier. This is *not* a manufactured FAIL — the
    # run genuinely could not certify PASS/FAIL for the attended steps, and
    # we stopped before any downstream cluster mutation.
    local step_word="step"
    [[ $blocked_count -gt 1 ]] && step_word="steps"
    echo "RESULT: BLOCKED(attended-required) (${blocked_count} attended ${step_word} skipped)"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "Paste this block into DR-REGISTRY.md under ${DRT_ID} → Last Run:"
    echo ""
    echo "${DRT_ID} ${DRT_NAME}"
    echo "Date:    ${DRT_START}"
    echo "Commit:  ${DRT_COMMIT}"
    echo "Result:  BLOCKED(attended-required)"
    echo "Time:    ${elapsed}"
    for coverage in ${DRT_COVERAGE_LIST[@]+"${DRT_COVERAGE_LIST[@]}"}; do
      echo "Coverage: ${coverage}"
    done
    echo "Attended ${step_word} skipped:"
    for s in ${DRT_BLOCKED_LIST[@]+"${DRT_BLOCKED_LIST[@]}"}; do
      echo "  - ${s}"
    done
    if [[ $DRT_WARNINGS -gt 0 ]]; then
      echo "Warnings:"
      for w in ${DRT_WARNING_LIST[@]+"${DRT_WARNING_LIST[@]}"}; do
        echo "  - ${w}"
      done
    fi
    echo "Notes:   Rerun attended: framework/dr-tests/run-dr-test.sh ${DRT_ID}"
    echo ""
    [[ -n "$DRT_FINGERPRINT" && -f "$DRT_FINGERPRINT" ]] && rm -f "$DRT_FINGERPRINT"
    exit "$DRT_BLOCKED_EXIT"
  fi

  if [[ $DRT_FAILURES -eq 0 ]]; then
    echo "RESULT: PASS"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "Paste this block into DR-REGISTRY.md under ${DRT_ID} → Last Run:"
    echo ""
    echo "${DRT_ID} ${DRT_NAME}"
    echo "Date:    ${DRT_START}"
    echo "Commit:  ${DRT_COMMIT}"
    echo "Result:  PASS"
    echo "Time:    ${elapsed}"
    for coverage in ${DRT_COVERAGE_LIST[@]+"${DRT_COVERAGE_LIST[@]}"}; do
      echo "Coverage: ${coverage}"
    done
    if [[ $DRT_WARNINGS -gt 0 ]]; then
      echo "Warnings:"
      for w in ${DRT_WARNING_LIST[@]+"${DRT_WARNING_LIST[@]}"}; do
        echo "  - ${w}"
      done
    fi
    echo "Notes:   [operator: add any observations here before pasting]"
  else
    echo "RESULT: FAIL (${DRT_FAILURES} assertions failed)"
    echo "════════════════════════════════════════════════════════"
    echo ""
    echo "Paste this block into DR-REGISTRY.md under ${DRT_ID} → Last Run:"
    echo ""
    echo "${DRT_ID} ${DRT_NAME}"
    echo "Date:    ${DRT_START}"
    echo "Commit:  ${DRT_COMMIT}"
    echo "Result:  FAIL"
    echo "Time:    ${elapsed}"
    for coverage in ${DRT_COVERAGE_LIST[@]+"${DRT_COVERAGE_LIST[@]}"}; do
      echo "Coverage: ${coverage}"
    done
    echo "Failures:"
    for f in ${DRT_FAILURE_LIST[@]+"${DRT_FAILURE_LIST[@]}"}; do
      echo "  - ${f}"
    done
    if [[ $DRT_WARNINGS -gt 0 ]]; then
      echo "Warnings:"
      for w in ${DRT_WARNING_LIST[@]+"${DRT_WARNING_LIST[@]}"}; do
        echo "  - ${w}"
      done
    fi
    echo "Notes:   [operator: add root cause before pasting]"
  fi

  echo ""
  # Clean up fingerprint
  [[ -n "$DRT_FINGERPRINT" && -f "$DRT_FINGERPRINT" ]] && rm -f "$DRT_FINGERPRINT"

  [[ $DRT_FAILURES -eq 0 ]] && exit 0 || exit 1
}
