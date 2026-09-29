#!/usr/bin/env bash
# rebalance-cluster.sh — Migrate VMs back to their intended Proxmox nodes.
#
# After an HA failover, VMs run on surviving nodes — not their intended
# placement from config.yaml. This script detects drift and migrates VMs
# back using ha-manager migrate.
#
# Usage:
#   framework/scripts/rebalance-cluster.sh [--dry-run]
#
# Prerequisites: all nodes must be healthy and reachable.
# Idempotent: exits with "no drift" if all VMs are correctly placed.
#
# Reads: site/config.yaml (vms.<name>.node for intended placement)
# Queries: Proxmox API via pvesh on any reachable node

set -euo pipefail

die() {
  echo "ERROR: $*" >&2
  exit 1
}

GUARD_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/cidata-guard.sh"
if [[ ! -f "$GUARD_LIB" ]]; then
  echo "ERROR: cidata guard library not found at ${GUARD_LIB}." >&2
  echo "Refusing to rebalance unguarded (fail-closed). The cidata guard fix is required." >&2
  echo "  Workstation: the repo is incomplete — re-checkout framework/scripts/lib/." >&2
  echo "  NAS: re-run framework/scripts/configure-sentinel-gatus.sh from the workstation." >&2
  exit 1
fi
# shellcheck source=framework/scripts/lib/cidata-guard.sh
source "$GUARD_LIB" || die "failed to source ${GUARD_LIB} (fail-closed)."

# A MISSING lib fails closed above. A STALE-BUT-VALID lib does not announce itself:
# the NAS copy arrives by scp, not by git, so a partial or skipped
# configure-sentinel-gatus.sh run can leave a new rebalancer sourcing an OLD guard —
# one that still defines every function but lacks, say, the owner-drift abort. Pin the
# minimum contract version and refuse below it.
REQUIRED_CIDATA_GUARD_LIB_VERSION=3
if [[ ! "${CIDATA_GUARD_LIB_VERSION:-}" =~ ^[0-9]+$ ]] \
   || [[ "$CIDATA_GUARD_LIB_VERSION" -lt "$REQUIRED_CIDATA_GUARD_LIB_VERSION" ]]; then
  echo "ERROR: cidata guard library at ${GUARD_LIB} is version '${CIDATA_GUARD_LIB_VERSION:-unset}';" >&2
  echo "this script requires >= ${REQUIRED_CIDATA_GUARD_LIB_VERSION}. Refusing to rebalance (fail-closed)." >&2
  echo "  NAS: re-run framework/scripts/configure-sentinel-gatus.sh from the workstation." >&2
  exit 1
fi
for required_fn in cidata_guard_node_change cidata_ha_service_node cidata_ha_service_state vm_is_ballooned; do
  if ! declare -F "$required_fn" >/dev/null; then
    die "cidata guard library at ${GUARD_LIB} does not define ${required_fn} (fail-closed)."
  fi
done

# --- Locate repo root ---
find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2; exit 1
}

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# --- Locate config ---
# Supports config.json (NAS, parsed with jq) and config.yaml (workstation, parsed with yq).
CONFIG=""
CONFIG_FORMAT=""
if [[ -n "${WATCHDOG_CONFIG_DIR:-}" ]]; then
  if [[ -f "${WATCHDOG_CONFIG_DIR}/config.json" ]]; then
    CONFIG="${WATCHDOG_CONFIG_DIR}/config.json"
    CONFIG_FORMAT="json"
  elif [[ -f "${WATCHDOG_CONFIG_DIR}/config.yaml" ]]; then
    CONFIG="${WATCHDOG_CONFIG_DIR}/config.yaml"
    CONFIG_FORMAT="yaml"
  fi
fi
if [[ -z "$CONFIG" ]]; then
  REPO_DIR="$(find_repo_root)"
  CONFIG="${REPO_DIR}/site/config.yaml"
  CONFIG_FORMAT="yaml"
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: $CONFIG" >&2
  exit 1
fi

# Config query helper — uses jq for JSON, yq for YAML
cfg_query() {
  if [[ "$CONFIG_FORMAT" == "json" ]]; then
    jq -r "$1" "$CONFIG"
  else
    yq -r "$1" "$CONFIG"
  fi
}

STORAGE_POOL="$(cfg_query '.proxmox.storage_pool // "vmstore"')"

# Replication policy classification for the drift-skip decision
# (universal replication doctrine).
#
# Every shipped VM has a replica (cadence: 1m or 24h).
# POLICY_OFF_VMIDS is the literal explicit-override set (bool false) —
# EMPTY on the shipped site. In steady state this migrate-skip branch
# never fires; it is preserved as machinery gating a future
# explicit-false override.
#
# Historical note: an earlier doctrine had a "derivable" class with no
# replica that could not be `ha-manager migrate`d cross-node without a
# full send. Under universal replication that skip-and-route-to-recreate
# path applies only to explicit-override VMs. cicd (24h cadence,
# ~318 GB replica) is migratable as a replica-delta send; a0's 10-min
# bound survives because the delta is a daily-delta, not a full send.
#
# Policy is derived by exactly one authority, list-replicated-vmids.sh
# (V5.1.a static ratchet). Because rebalance runs both on the workstation
# (repo checkout) AND on the NAS (no repo, limited userland — no yq — see
# .claude/rules/nas-scripts.md), it cannot invoke the helper directly on
# both surfaces. Instead: consume /etc/repl-policy.vmids from a reachable
# Proxmox node via SSH. This artifact is the Sprint 047 A4
# derived-config-delivery surface (analogous to CIDATA in authority shape).
# configure-replication.sh refreshes it every run; validate.sh's V5.1.b
# equivalence check ratchets it against the helper output; repl-health.sh
# reads it node-locally with the identical POLICY_ON/POLICY_OFF/POLICY_GEN
# shape.
#
# Fail-closed semantics for rebalance:
#   - Artifact readable on any node → parse POLICY_OFF_VMIDS; VMIDs on
#     that list SKIP migration with G7 guidance to recreate-derivable-vm.sh.
#   - Artifact absent/unparseable on all nodes → WARN and treat every
#     VMID as policy-on (pre-sprint behavior: migrate). This is the
#     stricter direction — never silently skip a precious VM's migration,
#     and never classify a VM policy-off without positive evidence.
#
# App-level compounds (roon_prod is precious via applications.roon.backup)
# are correctly classified because the artifact is generated by the single
# authority which already handles app-level policy — no local parsing.

POLICY_ARTIFACT_STATE="absent"
POLICY_OFF_VMIDS=""
POLICY_GEN=""
POLICY_OFF_ARR=()

# Extract a single POLICY_* value from artifact content.
# Uses `sub()` (not `awk -F=`) so a value containing `=` survives intact.
# Strips a trailing CR (defensive against DOS line endings).
_policy_extract() {
  local key="$1" content="$2"
  printf '%s\n' "$content" | awk -v k="$key" '
    index($0, k "=") == 1 {
      s = substr($0, length(k) + 2)
      sub(/\r$/, "", s)
      print s
      exit
    }'
}

# Validate an artifact value is a numeric CSV: "" | "N" | "N,N,..."
# Rejects anything else (empty tokens, non-numeric tokens, whitespace).
_policy_csv_ok() {
  local val="$1"
  [[ -z "$val" ]] && return 0
  [[ "$val" =~ ^[0-9]+(,[0-9]+)*$ ]]
}

# Extract POLICY_ON/OFF/GEN from artifact content; validate structure.
# Prints on stdout as three lines: on, off, gen. Returns 0 on success,
# 1 on any structural / shape failure.
_policy_parse_artifact() {
  local content="$1" on off gen
  # All three keys must be present as line prefixes. A key with an empty
  # value ("POLICY_OFF_VMIDS=") is legitimate — it means no policy-off
  # VMs — but the line MUST exist. Missing lines indicate truncated /
  # non-artifact input.
  printf '%s\n' "$content" | grep -qE '^POLICY_ON_VMIDS='  || return 1
  printf '%s\n' "$content" | grep -qE '^POLICY_OFF_VMIDS=' || return 1
  printf '%s\n' "$content" | grep -qE '^POLICY_GEN='       || return 1
  on=$(_policy_extract  POLICY_ON_VMIDS  "$content")
  off=$(_policy_extract POLICY_OFF_VMIDS "$content")
  gen=$(_policy_extract POLICY_GEN       "$content")
  # POLICY_GEN is a sha256 hex — must be non-empty and match [0-9a-f]+.
  [[ -n "$gen" && "$gen" =~ ^[0-9a-f]+$ ]] || return 1
  # POLICY_ON / POLICY_OFF must be numeric CSVs.
  _policy_csv_ok "$on"  || return 1
  _policy_csv_ok "$off" || return 1
  printf '%s\n%s\n%s\n' "$on" "$off" "$gen"
}

# Read /etc/repl-policy.vmids from EVERY reachable node and require
# unanimous agreement (identical POLICY_ON / POLICY_OFF / POLICY_GEN)
# across every readable copy. Any divergence, structural failure, or
# no-readable-node failure → return 1 with an explanatory WARN. Callers
# treat non-zero as "absent" (fail-closed to policy-on = migrate).
#
# Why unanimous agreement (r2 codex P1 #2 / sub-claude P2-1 / agy P2):
# configure-replication.sh does not fail the run if artifact delivery to
# a single node fails — it logs a warning and continues. A stale artifact
# on one node is therefore a realistic state; short-circuiting on the
# first responsive node could pick that stale copy and silently misclass
# a VM that was recently flipped policy-off ↔ policy-on. Unanimous
# agreement is what validate.sh's V5.1.b equivalence check also enforces
# (framework/scripts/validate.sh:821-841) — we mirror its trust boundary.
load_policy_artifact() {
  local count="$1" i node_ip node_name content parsed
  local on_val off_val gen_val
  local first_on="" first_off="" first_gen=""
  local read_count=0 divergent_nodes=()
  local structurally_bad_nodes=() unreadable_nodes=()

  for (( i=0; i<count; i++ )); do
    node_name=$(cfg_query ".nodes[${i}].name")
    node_ip=$(cfg_query ".nodes[${i}].mgmt_ip")
    content=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${node_ip}" \
      "cat /etc/repl-policy.vmids" 2>/dev/null) || content=""
    if [[ -z "$content" ]]; then
      unreadable_nodes+=("$node_name")
      continue
    fi
    if ! parsed=$(_policy_parse_artifact "$content"); then
      structurally_bad_nodes+=("$node_name")
      continue
    fi
    on_val=$(printf '%s\n' "$parsed"  | sed -n '1p')
    off_val=$(printf '%s\n' "$parsed" | sed -n '2p')
    gen_val=$(printf '%s\n' "$parsed" | sed -n '3p')
    if [[ "$read_count" -eq 0 ]]; then
      first_on="$on_val"
      first_off="$off_val"
      first_gen="$gen_val"
    elif [[ "$on_val" != "$first_on" || "$off_val" != "$first_off" || "$gen_val" != "$first_gen" ]]; then
      divergent_nodes+=("$node_name")
    fi
    read_count=$((read_count + 1))
  done

  if [[ "$read_count" -eq 0 ]]; then
    return 1
  fi
  if [[ "${#divergent_nodes[@]}" -gt 0 ]]; then
    echo "WARNING: /etc/repl-policy.vmids POLICY_GEN divergence across nodes: ${divergent_nodes[*]} disagree with the first readable copy (POLICY_GEN=${first_gen:0:8}...)." >&2
    echo "  Treating artifact as absent to preserve pre-sprint migrate behavior." >&2
    echo "  Fix: run configure-replication.sh to refresh the artifact on all nodes." >&2
    return 1
  fi
  if [[ "${#structurally_bad_nodes[@]}" -gt 0 ]]; then
    echo "WARNING: /etc/repl-policy.vmids on ${structurally_bad_nodes[*]} is structurally invalid (missing key or bad value shape); ignored." >&2
  fi
  if [[ "${#unreadable_nodes[@]}" -gt 0 ]]; then
    echo "WARNING: /etc/repl-policy.vmids unreadable on ${unreadable_nodes[*]}; used ${read_count} agreeing copy(ies)." >&2
  fi

  POLICY_OFF_VMIDS="$first_off"
  POLICY_GEN="$first_gen"
  POLICY_OFF_ARR=()
  if [[ -n "$POLICY_OFF_VMIDS" ]]; then
    IFS=',' read -ra POLICY_OFF_ARR <<< "$POLICY_OFF_VMIDS"
  fi
  POLICY_ARTIFACT_STATE="present"
  return 0
}

vmid_is_policy_off() {
  local target="$1" v
  # Empty target is never policy-off — hardens the predicate against a
  # future caller-side refactor that could pass "" (e.g. a trailing-comma
  # POLICY_OFF_VMIDS from a writer bug would parse to an empty array
  # element, which would then match target="" and silently skip).
  [[ -n "$target" ]] || return 1
  # Fail-closed for rebalance: unknown policy → NOT policy-off (i.e.,
  # keep the pre-sprint migrate path). The WARN was already logged at
  # load time.
  [[ "$POLICY_ARTIFACT_STATE" == "present" ]] || return 1
  for v in ${POLICY_OFF_ARR[@]+"${POLICY_OFF_ARR[@]}"}; do
    [[ "$v" == "$target" ]] && return 0
  done
  return 1
}

# Temp files for lookups (bash 3.2 has no associative arrays)
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

INTENDED_FILE="${TMPDIR_WORK}/intended"
ACTUAL_FILE="${TMPDIR_WORK}/actual"

# --- Read intended placement from config ---
# Produces lines like: dns1_prod=pve01
# Infrastructure VMs (from vms section)
cfg_query '.vms | to_entries | .[] | select(.value | has("node")) | .key + "=" + .value.node' > "$INTENDED_FILE"
# Application VMs (from applications section).
# Placement can be defined per-env (.environments.<env>.node) or top-level
# (.node). Per-env wins when both are present. This mirrors validate.sh
# R2.4's reader; see #493 for the RCA (per-env-only apps like roon were
# silently skipped by the previous top-level-only query).
# Must remain byte-identical to placement-watchdog.sh's query
# (tests/test_placement_readers.sh asserts this).
cfg_query '.applications // {} | to_entries[] | select(.value.enabled == true and (.value.environments // {} | length > 0)) | .key as $app | (.value.environments | to_entries[]) as $env_entry | ($env_entry.value.node // .value.node) as $node | select($node != null) | ($app + "_" + $env_entry.key) + "=" + $node' >> "$INTENDED_FILE" || true

if [[ ! -s "$INTENDED_FILE" ]]; then
  echo "ERROR: No VMs with 'node' field found in config.yaml" >&2
  exit 1
fi

# --- Recovery verification (#514) ---
# rebalance-cluster.sh is a recovery tool; its success criteria historically
# covered placement mechanics only. DRT-005 2026-07-07 step 7: it exited 0 with
# SEVEN VMs stopped in HA `error` state (unrecovered from a node failure) — the
# outage was only noticed when validate.sh stumbled on symptoms at step 8. This
# phase asserts the OUTCOME before exit 0: after all migrations settle, every
# HA service must be out of `error`, every service HA-requested `started` must
# have a running VM, and every config-enabled VM must be running. Services the
# operator deliberately set `disabled` (or `stopped`/`ignored`) are respected.
# Fail-closed: if the check cannot determine cluster state (SSH failure, empty
# HA status, no API data), that is a FAIL with a distinct message — never a
# silent pass (same principle as .claude/rules/destruction-safety.md).
#
# NAS-safe (.claude/rules/nas-scripts.md): config reads go through cfg_query
# (jq/yq dispatch); parsing is python3 + ssh only, no yq/socat/new tooling.
verify_recovery() {
  # Default settle window matches the script's existing 5-minute per-migration
  # patience: after a real node failover HA restarts services serially through
  # transient recovery/request_start states, so a batch (DRT-005 had 7) can be
  # legitimately mid-recovery for a while. Overridable for tests.
  local timeout="${MYCOFU_REBALANCE_VERIFY_TIMEOUT:-300}"
  local interval="${MYCOFU_REBALANCE_VERIFY_INTERVAL:-10}"
  local node_count i node_ip elapsed=0
  local status_txt config_txt resources_json fc_report vrc report
  local last_failure="" last_fc=""
  local sfile="${TMPDIR_WORK}/ha_status"
  local cfile="${TMPDIR_WORK}/ha_config"
  local rfile="${TMPDIR_WORK}/verify_resources.json"

  node_count=$(cfg_query '.nodes | length')

  echo ""
  echo "Verifying recovery (HA services out of error, config-enabled VMs running)..."

  while : ; do
    status_txt=""; config_txt=""; resources_json=""; fc_report=""

    # HA status + config from the first member that answers (/etc/pve and the
    # HA manager are cluster-wide, so any reachable node gives the full view).
    for (( i=0; i<node_count; i++ )); do
      node_ip=$(cfg_query ".nodes[${i}].mgmt_ip")
      status_txt=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${node_ip}" \
        "ha-manager status" 2>/dev/null) || status_txt=""
      if [[ -n "$status_txt" ]]; then
        config_txt=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${node_ip}" \
          "ha-manager config" 2>/dev/null) || config_txt=""
        break
      fi
    done

    # Fresh VM run-state from the first node returning non-empty API data.
    for (( i=0; i<node_count; i++ )); do
      node_ip=$(cfg_query ".nodes[${i}].mgmt_ip")
      resources_json=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${node_ip}" \
        "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null) || resources_json=""
      if [[ -n "$resources_json" ]] && \
         printf '%s' "$resources_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); sys.exit(0 if isinstance(d,list) and len(d)>0 else 1)' 2>/dev/null; then
        break
      fi
      resources_json=""
    done

    # Fail-closed on any undeterminable input. Empty config_txt is treated as
    # fail-closed because every Mycofu VM is HA-managed, so an empty
    # `ha-manager config` on a quorate node means the read failed, not that HA
    # is genuinely unconfigured.
    if [[ -z "$status_txt" ]]; then
      fc_report="fail-closed: could not read HA state ('ha-manager status' returned nothing from any node)"
    elif [[ -z "$config_txt" ]]; then
      fc_report="fail-closed: could not read HA requested state ('ha-manager config' returned nothing)"
    elif [[ -z "$resources_json" ]]; then
      fc_report="fail-closed: could not read VM run state ('pvesh /cluster/resources' returned no data from any node)"
    fi

    if [[ -n "$fc_report" ]]; then
      last_fc="$fc_report"
    else
      printf '%s' "$status_txt"   > "$sfile"
      printf '%s' "$config_txt"   > "$cfile"
      printf '%s' "$resources_json" > "$rfile"
      set +e
      report=$(python3 - "$sfile" "$cfile" "$rfile" "$INTENDED_FILE" <<'PYEOF'
import sys, json, re

status   = open(sys.argv[1]).read()
config   = open(sys.argv[2]).read()
res      = json.load(open(sys.argv[3]))
manifest = [ln.split('=', 1)[0].strip() for ln in open(sys.argv[4]) if ln.strip()]

# A not-running VM is acceptable only when the operator deliberately asked for
# it via the HA requested state.
INTENTIONAL = {'disabled', 'ignored', 'stopped'}

# Current HA state: "service vm:<vmid> (<node>, <state>)"
current = {}
for m in re.finditer(r'^service vm:(\d+)\s+\([^,]+,\s*([^)]+)\)', status, re.M):
    current[m.group(1)] = m.group(2).strip()

# Requested HA state from `ha-manager config`: a "vm:<vmid>" header followed by
# an indented "state <s>" (default 'started' when omitted). Reset the current
# resource pointer on ANY unindented header line so a non-VM block (ct:, group:)
# and its `state` cannot bleed into the preceding vm's requested state.
requested = {}
cur = None
for line in config.splitlines():
    if re.match(r'^\s', line):
        s = re.match(r'^\s+state\s+(\S+)', line)
        if s and cur is not None:
            requested[cur] = s.group(1)
    else:
        h = re.match(r'^vm:(\d+)\s*$', line)
        if h:
            cur = h.group(1)
            requested[cur] = 'started'
        else:
            cur = None

# Fail-closed: HA status text was present but no service entries parsed out of
# it (malformed/partial output). We cannot confirm HA health, so this is not a
# pass. (Every Mycofu VM is HA-managed, so zero services is never legitimate.)
if not current:
    print("fail-closed: 'ha-manager status' returned no parseable HA service entries")
    sys.exit(2)

running, vmid2status, name2vmid, vmid2name = set(), {}, {}, {}
for v in res:
    if v.get('type') != 'qemu':
        continue
    vmid = str(v.get('vmid'))
    st = v.get('status', 'unknown')
    vmid2status[vmid] = st
    nm = str(v.get('name', '')).replace('-', '_')
    vmid2name[vmid] = nm or ('vm' + vmid)
    if nm:
        name2vmid[nm] = vmid
    if st == 'running':
        running.add(vmid)

# Resolve manifest names to VMIDs. Entries that do NOT resolve to a Proxmox VM
# (a co-located app that has no VM of its own, or a name that predates creation)
# are NOT "a VM that failed to run" — reporting them as failures false-positives
# the whole check. They are surfaced as an informational note on stderr instead.
# HA-managed VMs are authoritatively covered by the HA checks below regardless
# of whether they appear in this (platform-dependent) manifest, so nothing that
# matters is lost by treating unresolved manifest names as non-fatal.
manifest_ids, unresolved = set(), []
for n in manifest:
    if n in name2vmid:
        manifest_ids.add(name2vmid[n])
    else:
        unresolved.append(n)

reported = {}
for vmid in (set(current) | set(requested) | manifest_ids):
    name = vmid2name.get(vmid, 'vm' + vmid)
    st = vmid2status.get(vmid, 'unknown')
    # (a) error state — the DRT-005 shape.
    if current.get(vmid) == 'error':
        reported[vmid] = f"vm:{vmid} ({name}): HA service in ERROR state (vm status={st})"
        continue
    # Desired run-state: HA requested state wins; else current HA state if it is
    # an intentional off-state; else 'started' (a plain manifest VM must run).
    if vmid in requested:
        desired = requested[vmid]
    elif current.get(vmid) in INTENTIONAL:
        desired = current[vmid]
    else:
        desired = 'started'
    if desired in INTENTIONAL:
        continue
    if vmid not in running:
        if vmid in requested or vmid in current:
            # (b) HA thinks it should be started, but the VM is not running.
            reported[vmid] = f"vm:{vmid} ({name}): HA-requested '{desired}' but VM not running (status={st})"
        else:
            # (c) a config-manifest VM that is NOT HA-managed and not running.
            reported[vmid] = f"vm:{vmid} ({name}): config-enabled VM not running and not HA-managed (status={st})"

if unresolved:
    sys.stderr.write("note: config-manifest entries with no matching Proxmox VM "
                     "(co-located app or not-yet-created; not treated as a failure): "
                     + ", ".join(sorted(unresolved)) + "\n")

msgs = [reported[v] for v in sorted(reported, key=int)]
for m in msgs:
    print(m)
sys.exit(0 if not msgs else 3)
PYEOF
)
      vrc=$?
      set -e
      case "$vrc" in
        0) echo "Recovery verified: no HA error states; all config-enabled VMs running."
           return 0 ;;
        3) last_failure="$report" ;;                       # concrete recovery failures
        2) last_fc="$report" ;;                            # fail-closed (unparseable HA)
        *) last_fc="fail-closed: recovery verifier errored on cluster data (unexpected ha-manager/pvesh output)" ;;
      esac
    fi

    if [[ "$elapsed" -ge "$timeout" ]]; then
      break
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  # Prefer a concrete failure list (actionable) over a fail-closed reason, so a
  # transient query failure on the final poll cannot erase an HA-error list seen
  # earlier in the settle window.
  local final_report="${last_failure:-$last_fc}"
  echo "ERROR: rebalance did not reach a recovered cluster state (#514)." >&2
  echo "A recovery tool must not report success on an unrecovered cluster." >&2
  echo "Unresolved after ${timeout}s settle window:" >&2
  printf '%s\n' "$final_report" | while IFS= read -r l; do
    [[ -n "$l" ]] && echo "  - $l" >&2
  done
  echo "" >&2
  echo "To mark a VM intentionally off (so it is not a failure), set its HA" >&2
  echo "requested state: ha-manager set vm:<vmid> --state disabled" >&2
  echo "For HA services stuck in ERROR state, follow the branch that matches" >&2
  echo ".claude/rules/storage-failure-fence.md: 6A (storage recovered — clear" >&2
  echo "with --state disabled then --state started) or 6B (storage still dead —" >&2
  echo "fence the node FIRST, then clear errors so HA re-places from replicas)." >&2
  return 1
}

if [[ "${MYCOFU_REBALANCE_ONLY_VERIFY:-0}" == "1" ]]; then
  verify_recovery
  exit $?
fi

ha_maintenance_warning() {
  local count="$1" i node_ip node_name status_txt="" rc line matched_line
  local found=0

  for (( i=0; i<count; i++ )); do
    node_ip=$(cfg_query ".nodes[${i}].mgmt_ip")
    set +e
    status_txt=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${node_ip}" \
      "ha-manager status" 2>/dev/null)
    rc=$?
    set -e
    if [[ "$rc" -eq 0 && -n "$status_txt" ]]; then
      break
    fi
    status_txt=""
  done

  if [[ -z "$status_txt" ]]; then
    echo "ERROR: Could not read HA status from any node; refusing to rebalance (fail-closed)." >&2
    return 1
  fi

  for (( i=0; i<count; i++ )); do
    node_name=$(cfg_query ".nodes[${i}].name")
    matched_line=""
    while IFS= read -r line; do
      if [[ "$line" =~ ^lrm[[:space:]]+${node_name}[[:space:]]+\( ]] && [[ "$line" == *"maintenance mode"* ]]; then
        matched_line="$line"
        break
      fi
    done <<< "$status_txt"
    if [[ -n "$matched_line" ]]; then
      echo "WARNING: Node ${node_name} appears in HA maintenance; rebalance will continue." >&2
      echo "  HA status: ${matched_line}" >&2
      found=1
    fi
  done

  if [[ "$found" -ne 0 ]]; then
    echo "" >&2
    # rolling-reboot-node-inner.sh:76-77 documents a real PVE behavior:
    # after a successful rolling reboot, the LRM's local state field can remain
    # cosmetically stuck at `maintenance` for hours even though CRM treats the
    # node as online. A genuine in-maintenance node and that stale label are
    # indistinguishable in `ha-manager status`, so this signal cannot be a
    # safety gate. Proceed in the common stale-label case; if maintenance is
    # genuinely active, the existing per-VM 5-minute placement wait bounds the
    # cost and surfaces the failed placement as a WARNING.
    echo "WARNING: HA maintenance labels are advisory for rebalance." >&2
    echo "Proceeding because a stale post-reboot LRM label and real maintenance" >&2
    echo "are indistinguishable from ha-manager status alone." >&2
  fi

  return 0
}

# --- Check all nodes are healthy ---
echo "Checking node health..."
NODE_COUNT=$(cfg_query '.nodes | length')
FIRST_NODE_IP=""
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAME=$(cfg_query ".nodes[${i}].name")
  NODE_IP=$(cfg_query ".nodes[${i}].mgmt_ip")
  [[ -z "$FIRST_NODE_IP" ]] && FIRST_NODE_IP="$NODE_IP"

  if ! ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_IP}" "true" 2>/dev/null; then
    echo "ERROR: Node ${NODE_NAME} (${NODE_IP}) is not reachable via SSH." >&2
    echo "All nodes must be healthy before rebalancing." >&2
    exit 1
  fi
  echo "  ${NODE_NAME}: reachable"
done
ha_maintenance_warning "$NODE_COUNT" || exit 1
echo ""

# --- Load Sprint 047 replication-policy artifact from any node ---
# See vmid_is_policy_off comment above for full rationale. Absent artifact
# is a WARN, NOT a fail — the fail-closed direction here is to migrate
# every drifted VM (pre-sprint behavior), which is stricter for precious
# VMs than silently skipping them.
if load_policy_artifact "$NODE_COUNT"; then
  echo "Loaded replication-policy artifact (POLICY_GEN=${POLICY_GEN:0:8}..., ${#POLICY_OFF_ARR[@]} policy-off VMIDs)."
else
  echo "WARNING: /etc/repl-policy.vmids unreadable, divergent, or malformed across nodes." >&2
  echo "  Treating every drifted VM as policy-on (pre-sprint migrate path)." >&2
  echo "  Fix: run configure-replication.sh to refresh the artifact." >&2
fi
echo ""

# --- Query actual VM placement from Proxmox API ---
# Proxmox VM names use hyphens (dns1-prod), config.yaml uses underscores (dns1_prod).
# API resilience: try each node until we get non-empty results (pvesh can return
# empty JSON during cluster state transitions like a node departing).
echo "Querying actual VM placement..."
CLUSTER_RESOURCES=""
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_IP=$(cfg_query ".nodes[${i}].mgmt_ip")
  RESULT=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_IP}" \
    "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null) || continue
  if echo "$RESULT" | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); exit(0 if len(d)>0 else 1)" 2>/dev/null; then
    CLUSTER_RESOURCES="$RESULT"
    break
  fi
done

if [[ -z "$CLUSTER_RESOURCES" ]]; then
  echo "ERROR: All nodes returned empty API data. Cannot determine VM placement." >&2
  exit 1
fi

echo "$CLUSTER_RESOURCES" | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    if vm.get('type') == 'qemu' and vm.get('status') == 'running':
        name = vm['name'].replace('-', '_')
        print(f'{name}={vm[\"node\"]}={vm[\"vmid\"]}')
" > "$ACTUAL_FILE"

# --- Lookup helpers ---
get_actual_node() {
  local vm="$1"
  { grep "^${vm}=" "$ACTUAL_FILE" 2>/dev/null || echo ""; } | head -1 | cut -d= -f2
}

get_vmid() {
  local vm="$1"
  { grep "^${vm}=" "$ACTUAL_FILE" 2>/dev/null || echo ""; } | head -1 | cut -d= -f3
}

# --- Move-primitive selection (Sprint 046 A3) ------------------------------
# Never live-migrate a ballooned VM. A live migrate carries the guest's CURRENT
# working set — for a ceiling-resident VM on a big node, that can be tens of GiB
# — onto a survivor that may not have it. `crm-command relocate` is a stop→start,
# and a fresh start re-applies the balloon FLOOR (R005 F3), so the VM lands at a
# size the survivor can actually hold. Fixed VMs (balloon device disabled) keep
# `migrate` — unchanged behavior.
#
# The predicate is read at RUNTIME from `qm config <vmid>`, never from
# config.yaml: the framework never learns which VM is "the big one", it just asks
# Proxmox whether the VM in front of it has a balloon. That is what keeps this
# size-agnostic and portable to a smaller site.
#
# A relocate is NOT safer than a migrate with respect to cidata — both mint
# rename-victims by the identical mechanism — so cidata_guard_node_change runs
# before EITHER primitive (see the call sites below).
select_move_primitive() {
  local vmid="$1" intended_node="$2" owner_target="$3" bal_rc

  MOVE_CMD=""
  MOVE_VERB=""
  vm_is_ballooned "$owner_target" "$vmid" && bal_rc=0 || bal_rc=$?
  case "$bal_rc" in
    0)
      MOVE_CMD="ha-manager crm-command relocate vm:${vmid} ${intended_node}"
      MOVE_VERB="relocate"
      ;;
    1)
      MOVE_CMD="ha-manager migrate vm:${vmid} ${intended_node}"
      MOVE_VERB="migrate"
      ;;
    2)
      echo "    ERROR: cannot determine whether vm:${vmid} is ballooned; aborting rebalance (fail-closed)." >&2
      return 1
      ;;
    *)
      echo "    ERROR: vm_is_ballooned returned unexpected status ${bal_rc} for vm:${vmid}; aborting rebalance (fail-closed)." >&2
      return 1
      ;;
  esac
}

# --- Compare and migrate ---
DRIFT=0
MIGRATED=0
# Collect per-VM migration failures so `Rebalance complete. Migrated 0` never
# hides nine attempted-and-failed moves. Sprint 048 M4 attempt-2 (2026-07-23)
# observed exactly that shape: nine attempted migrations, zero successful,
# exit 0 — because the loop's WARNING on timeout did not feed the exit code.
# Any attempted-then-failed migration adds to MIGRATE_FAILURES and produces a
# nonzero exit at the tail (#697 P4). placement-watchdog.sh tolerates the
# nonzero exit (it saves ${PIPESTATUS[0]} across a `set +e`/`set -e` window
# and logs the rc, no crash-loop).
MIGRATE_FAILURES=()

while IFS='=' read -r vm intended_node; do
  [[ -z "$vm" ]] && continue
  actual_node=$(get_actual_node "$vm")
  vmid=$(get_vmid "$vm")

  if [[ -z "$actual_node" ]]; then
    echo "  WARNING: ${vm} not found in cluster (may be stopped or missing)"
    continue
  fi

  if [[ "$intended_node" != "$actual_node" ]]; then
    DRIFT=1

    # Explicit-override VMs (empty set on the shipped site) have no
    # replica delta and cannot be migrated cross-node. The recovery
    # contract for a drifted explicit-override VM is recreation via
    # framework/scripts/recreate-derivable-vm.sh, NOT `ha-manager
    # migrate`.
    #
    # Under universal replication this branch is
    # machinery-guarding-an-empty-set on the shipped site: the
    # POLICY_OFF_VMIDS artifact list is empty because no VM ships with
    # an explicit override. The G7 branch remains for the future case.
    #
    # The G7 report REPEATS on every rebalance/watchdog cycle until the
    # operator either recreates the VM or updates its intended node in
    # config.yaml. That is EXPECTED, not an escalating condition.
    if vmid_is_policy_off "$vmid"; then
      echo "  SKIP: ${vm} (VMID ${vmid}) is an explicit-override VM (no cross-node replica delta available); drift ${actual_node} -> ${intended_node} NOT auto-migrated."
      echo "    G7 — recovery path:"
      echo "         framework/scripts/recreate-derivable-vm.sh ${vmid}"
      echo "         then follow its printed deploy instructions."
      echo "    (This message repeats each cycle until the VM is recreated OR"
      echo "     its intended node in site/config.yaml is updated to ${actual_node}.)"
      continue
    fi

    # Resolve destination IP for the pre-migrate vaccine (fail-closed if unknown).
    dest_ip=$(cfg_query ".nodes[] | select(.name == \"${intended_node}\") | .mgmt_ip")
    if [[ -z "$dest_ip" || "$dest_ip" == "null" ]]; then
      echo "    ERROR: could not resolve management IP for destination ${intended_node}; cannot run the pre-migrate vaccine." >&2
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  Would migrate ${vm} (VMID ${vmid}): ${actual_node} -> ${intended_node} [BLOCKED: destination IP unresolved]"
        continue
      fi
      echo "    Aborting rebalance (fail-closed) before migrating ${vm}." >&2
      exit 1
    fi

    # `qm config <vmid>` is node-local, so balloon detection must query the
    # VM's current owner, not an arbitrary cluster member.
    actual_ip=$(cfg_query ".nodes[] | select(.name == \"${actual_node}\") | .mgmt_ip")
    if [[ -z "$actual_ip" || "$actual_ip" == "null" ]]; then
      echo "    ERROR: could not resolve management IP for actual owner ${actual_node}; cannot determine balloon state." >&2
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  Would migrate ${vm} (VMID ${vmid}): ${actual_node} -> ${intended_node} [BLOCKED: actual owner IP unresolved]"
        continue
      fi
      echo "    Aborting rebalance (fail-closed) before migrating ${vm}." >&2
      exit 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
      if ! cidata_guard_node_change "$vmid" "$actual_node" "root@${FIRST_NODE_IP}" "$STORAGE_POOL" "$DRY_RUN" "${intended_node}=root@${dest_ip}"; then
        echo "    [DRY-RUN] pre-migrate vaccine would BLOCK this migrate (reason above)."
      else
        if ! select_move_primitive "$vmid" "$intended_node" "root@${actual_ip}"; then
          exit 1
        fi
        if [[ "$MOVE_VERB" == "relocate" ]]; then
          echo "  Would relocate ${vm} (VMID ${vmid}): ${actual_node} -> ${intended_node}"
        else
          echo "  Would migrate ${vm} (VMID ${vmid}): ${actual_node} -> ${intended_node}"
        fi
        echo "    [DRY-RUN] would issue: ${MOVE_CMD}"
      fi
    else
      # Vaccine: clear a stale destination cidata orphan BEFORE the migrate, or
      # abort the rebalance if safety cannot be proven (G4 fail-closed).
      if ! cidata_guard_node_change "$vmid" "$actual_node" "root@${FIRST_NODE_IP}" "$STORAGE_POOL" "$DRY_RUN" "${intended_node}=root@${dest_ip}"; then
        echo "    Aborting rebalance (fail-closed): pre-migrate vaccine blocked ${vm} (VMID ${vmid})." >&2
        exit 1
      fi
      if ! select_move_primitive "$vmid" "$intended_node" "root@${actual_ip}"; then
        exit 1
      fi
      if [[ "$MOVE_VERB" == "relocate" ]]; then
        echo "  Relocating ${vm} (VMID ${vmid}): ${actual_node} -> ${intended_node}"
      else
        echo "  Migrating ${vm} (VMID ${vmid}): ${actual_node} -> ${intended_node}"
      fi
      set +e
      ssh -n "root@${FIRST_NODE_IP}" "$MOVE_CMD" 2>/dev/null
      move_rc=$?
      set -e
      if [[ "$move_rc" -ne 0 ]]; then
        echo "    FAIL: ${MOVE_VERB} of ${vm} (VMID ${vmid}) returned rc=${move_rc}"
        MIGRATE_FAILURES+=("${vm} (VMID ${vmid}): ${MOVE_VERB} command failed rc=${move_rc}")
        continue
      fi

      # Wait for migration to complete (up to 5 minutes)
      # Poll under set +e so a transient ssh/pvesh/JSON hiccup cannot kill
      # the rebalance mid-loop and skip the MIGRATE_FAILURES bookkeeping —
      # `set -euo pipefail` at file scope would otherwise abort here after
      # the move command has already returned 0 (codex P2).
      migration_done=0
      current=""
      set +e
      for i in $(seq 1 60); do
        current=$(ssh -n "root@${FIRST_NODE_IP}" \
          "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null | \
          python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
for v in data:
    if str(v.get('vmid')) == '${vmid}':
        print(v.get('node', ''))
        break
" 2>/dev/null)
        if [[ "$current" == "$intended_node" ]]; then
          echo "    OK: ${vm} now on ${intended_node}"
          MIGRATED=$((MIGRATED + 1))
          migration_done=1
          break
        fi
        sleep 5
      done
      set -e
      if [[ "$migration_done" -ne 1 ]]; then
        echo "    FAIL: ${vm} (VMID ${vmid}) still on ${current:-unknown} after 5 min (expected ${intended_node})"
        MIGRATE_FAILURES+=("${vm} (VMID ${vmid}): ${MOVE_VERB} timed out — on ${current:-unknown}, expected ${intended_node}")
      fi
    fi
  fi
done < "$INTENDED_FILE"

# Dry-run changes no state, so there is nothing to verify — report and stop.
if [[ "$DRY_RUN" == "true" ]]; then
  if [[ "$DRIFT" -eq 0 ]]; then
    echo "No placement drift detected. All VMs on intended nodes."
  else
    echo ""
    echo "Dry run complete. Use without --dry-run to migrate."
  fi
  exit 0
fi

if [[ "$DRIFT" -eq 0 ]]; then
  echo "No placement drift detected. All VMs on intended nodes."
else
  echo ""
  echo "Rebalance complete. Migrated ${MIGRATED} VM(s); ${#MIGRATE_FAILURES[@]} failed."
  if [[ "${#MIGRATE_FAILURES[@]}" -gt 0 ]]; then
    echo ""
    echo "Migration failures:"
    for f in "${MIGRATE_FAILURES[@]}"; do
      echo "  - $f"
    done
  fi
fi

# Any VM the script ATTEMPTED to migrate but could not place on its intended
# node counts as a rebalance failure. But BEFORE we exit — even on the
# failed-migration path — still run verify_recovery so the operator sees
# the current HA state (services in error? VMs not running?), because
# those signals are independent of placement drift and orthogonal to why a
# migration failed (sub-claude P2-2). aggregate both outcomes.
migration_rc=0
verify_rc=0
if [[ "${#MIGRATE_FAILURES[@]}" -gt 0 ]]; then
  echo "" >&2
  echo "ERROR: ${#MIGRATE_FAILURES[@]} rebalance migration(s) failed (#697 P4)." >&2
  migration_rc=1
fi

# Do not report success until the cluster is actually recovered (#514). This
# runs on BOTH exit-0 paths above — a "no drift" cluster can still be sitting
# with VMs stopped in HA error state (exactly the DRT-005 shape).
if ! verify_recovery; then
  verify_rc=1
fi

if [[ "$migration_rc" -ne 0 || "$verify_rc" -ne 0 ]]; then
  exit 1
fi
exit 0
