#!/usr/bin/env bash
# placement-watchdog.sh — Autonomous placement drift detection and recovery.
#
# Runs on the NAS via cron (every 5 minutes). Detects VMs on wrong nodes,
# waits for all nodes to be healthy, then calls rebalance-cluster.sh.
#
# If no drift: exits silently (exit 0).
# If drift but nodes down: logs and exits (retries on next run).
# If drift and all nodes healthy: runs rebalance and logs.
#
# Usage:
#   placement-watchdog.sh                     # Normal watchdog mode
#   placement-watchdog.sh --health-server [PORT]  # HTTP health endpoint (default 9200)
#   placement-watchdog.sh --detect-only       # JSON drift report (no rebalance)
#
# Configuration:
#   Set WATCHDOG_CONFIG_DIR to a directory containing config.yaml,
#   or REPO_DIR to the repo root (uses site/config.yaml).
#
# Deployed to NAS by configure-sentinel-gatus.sh.

set -euo pipefail

# Overridable for hermetic tests; the NAS deployment uses the default path.
LOG_FILE="${PLACEMENT_WATCHDOG_LOG:-/var/log/placement-watchdog.log}"
HEALTH_PORT=9200

# --- Health server mode (Python http.server — no socat dependency) ---
if [[ "${1:-}" == "--health-server" ]]; then
  [[ -n "${2:-}" ]] && HEALTH_PORT="$2"

  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  exec python3 -c "
import http.server, subprocess, json

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            r = subprocess.run(['${SCRIPT_PATH}', '--detect-only'],
                               capture_output=True, text=True, timeout=30)
            body = r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else \
                json.dumps({'placement_healthy': False, 'error': 'detection failed', 'all_nodes_up': False, 'drift': [], 'ha_healthy': False, 'ha_errors': []})
        except Exception as e:
            body = json.dumps({'placement_healthy': False, 'error': str(e), 'all_nodes_up': False, 'drift': [], 'ha_healthy': False, 'ha_errors': []})
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body.encode())
    def log_message(self, fmt, *args):
        pass  # suppress per-request logs

http.server.HTTPServer(('', ${HEALTH_PORT}), Handler).serve_forever()
"
fi

# --- Locate config ---
# Supports both config.json (NAS deployment, parsed with jq) and
# config.yaml (local workstation, parsed with yq).
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
elif [[ -n "${REPO_DIR:-}" ]]; then
  CONFIG="${REPO_DIR}/site/config.yaml"
  CONFIG_FORMAT="yaml"
else
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "${dir}/flake.nix" ]]; then
      CONFIG="${dir}/site/config.yaml"
      CONFIG_FORMAT="yaml"
      REPO_DIR="$dir"
      break
    fi
    dir="$(dirname "$dir")"
  done
fi

if [[ ! -f "${CONFIG:-}" ]]; then
  echo "ERROR: config not found. Set REPO_DIR or WATCHDOG_CONFIG_DIR." >&2
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

DETECT_ONLY=false
[[ "${1:-}" == "--detect-only" ]] && DETECT_ONLY=true

# Temp files (bash 3.2 compatible — no associative arrays)
TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

INTENDED_FILE="${TMPDIR_WORK}/intended"
ACTUAL_FILE="${TMPDIR_WORK}/actual"

# --- Read intended placement ---
# Infrastructure VMs (from vms section)
cfg_query '.vms | to_entries | .[] | select(.value | has("node")) | .key + "=" + .value.node' > "$INTENDED_FILE"
# Application VMs (from applications section).
# Placement can be defined per-env (.environments.<env>.node) or top-level
# (.node). Per-env wins when both are present. This mirrors validate.sh
# R2.4's reader; see #493 for the RCA (per-env-only apps like roon were
# silently skipped by the previous top-level-only query).
# Must remain byte-identical to rebalance-cluster.sh's query
# (tests/test_placement_readers.sh asserts this).
cfg_query '.applications // {} | to_entries[] | select(.value.enabled == true and (.value.environments // {} | length > 0)) | .key as $app | (.value.environments | to_entries[]) as $env_entry | ($env_entry.value.node // .value.node) as $node | select($node != null) | ($app + "_" + $env_entry.key) + "=" + $node' >> "$INTENDED_FILE" || true

# --- Check node health ---
NODE_COUNT=$(cfg_query '.nodes | length')
ALL_NODES_UP=true
FIRST_NODE_IP=""

for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_IP=$(cfg_query ".nodes[${i}].mgmt_ip")

  if ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_IP}" "true" 2>/dev/null; then
    [[ -z "$FIRST_NODE_IP" ]] && FIRST_NODE_IP="$NODE_IP"
  else
    ALL_NODES_UP=false
  fi
done

if [[ -z "$FIRST_NODE_IP" ]]; then
  if [[ "$DETECT_ONLY" == "true" ]]; then
    echo '{"placement_healthy": false, "error": "no nodes reachable", "all_nodes_up": false, "drift": [], "ha_healthy": false, "ha_errors": []}'
  fi
  exit 1
fi

# --- Query actual placement (API resilience: try each node until non-empty) ---
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
  if [[ "$DETECT_ONLY" == "true" ]]; then
    echo '{"placement_healthy": false, "error": "all nodes returned empty API data", "all_nodes_up": false, "drift": [], "ha_healthy": false, "ha_errors": []}'
  fi
  exit 1
fi

echo "$CLUSTER_RESOURCES" | python3 -c "
import sys, json
for vm in json.loads(sys.stdin.read()):
    if vm.get('type') == 'qemu' and vm.get('status') == 'running':
        name = vm['name'].replace('-', '_')
        print(f'{name}={vm[\"node\"]}={vm[\"vmid\"]}')
" > "$ACTUAL_FILE"

# --- HA-error probe (Sprint 045 / #519, A5; DETECTION + GUIDANCE ONLY) ---
# Classify the DRT-005 outage shape (no drift, services stuck in HA `error`)
# plus requested-started-but-not-running and config-manifest-VM-not-running.
# This is a READ-ONLY probe: it never clears errors, migrates, realigns, or
# invokes any cluster write (not even rebalance verify-only). The classifier
# mirrors rebalance-cluster.sh's verify_recovery (#514) so the two agree on what
# "recovered" means, with one deliberate divergence (#532): the periodic probe
# treats CRM transitional states (migrate/relocate) as healthy-in-progress,
# whereas verify_recovery uses retry/settle since it runs immediately after a
# rebalance's migrations complete. Both agree on the terminal outage shape.
# NAS-safe: python3 + ssh only; config reads via cfg_query.
#
# `ha-manager status` and `ha-manager config` are cluster-wide (any reachable
# node gives the full view), so query the first node that answers.
HA_STATUS_TXT=""
HA_CONFIG_TXT=""
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_IP=$(cfg_query ".nodes[${i}].mgmt_ip")
  HA_STATUS_TXT=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_IP}" \
    "ha-manager status" 2>/dev/null) || HA_STATUS_TXT=""
  if [[ -n "$HA_STATUS_TXT" ]]; then
    HA_CONFIG_TXT=$(ssh -n -o ConnectTimeout=5 -o BatchMode=yes "root@${NODE_IP}" \
      "ha-manager config" 2>/dev/null) || HA_CONFIG_TXT=""
    break
  fi
done

HA_STATUS_FILE="${TMPDIR_WORK}/ha_status"
HA_CONFIG_FILE="${TMPDIR_WORK}/ha_config"
HA_RES_FILE="${TMPDIR_WORK}/ha_resources.json"
printf '%s' "$HA_STATUS_TXT"  > "$HA_STATUS_FILE"
printf '%s' "$HA_CONFIG_TXT"  > "$HA_CONFIG_FILE"
printf '%s' "$CLUSTER_RESOURCES" > "$HA_RES_FILE"

# Emit a compact JSON object: {ha_healthy, ha_errors:[{vmid,name,state,reason}],
# ha_read_error}. Fail-closed: unreadable/unparseable HA state => ha_healthy
# false with an ha_read_error string (never a silent "healthy").
HA_PROBE_JSON=$(python3 - "$HA_STATUS_FILE" "$HA_CONFIG_FILE" "$HA_RES_FILE" "$INTENDED_FILE" <<'PYEOF'
import sys, json, re

status   = open(sys.argv[1]).read()
config   = open(sys.argv[2]).read()
try:
    res = json.load(open(sys.argv[3]))
except Exception:
    res = []
manifest = [ln.split('=', 1)[0].strip() for ln in open(sys.argv[4]) if ln.strip()]

# A not-running VM is acceptable only when the operator deliberately asked for it.
INTENTIONAL = {'disabled', 'ignored', 'stopped'}

# HA state class: PVE CRM "healthy work in progress". A service in one of these
# states is mid-transition (an in-flight migration or relocation). During the
# window, the VM's pvesh cluster/resources status briefly reports transient
# labels like 'postmigrate' that are not equal to 'running', so the plain
# not-running check below would flag it as an outage. It is not — a stuck
# transition IS reportable, but that requires cross-probe persistence and is
# deliberately out of scope here (see #532); the false-positive cost of a
# 5-min-cadence probe hitting a mid-migration tick is worse than a missed stuck
# migration, which is separately visible in Proxmox UI. See #532 for the DRT-005
# rerun evidence (vm:302 dns2_dev, vm:603 roon_prod).
#
# Set spelled as a class, not a phrase-blacklist: matching `migrate`/`relocate`
# by name would be a symptom-level patch; classifying by CRM state class is the
# structural fix (G3).
TRANSITIONAL = {'migrate', 'relocate'}

def emit(healthy, errors, read_error=None):
    print(json.dumps({"ha_healthy": bool(healthy),
                      "ha_errors": errors,
                      "ha_read_error": read_error}))
    sys.exit(0)

# Fail-closed: no HA status text means we could not read HA state.
if not status.strip():
    emit(False, [], "could not read 'ha-manager status' from any node")

# Current HA state: "service vm:<vmid> (<node>, <state>)"
# Some PVE versions annotate transitional states with a trailing target-node
# hint, either comma-separated ("(pve01, migrate, pve02)") or parenthesised
# ("(pve01, migrate (pve02))"). Normalize to the primary state token so the
# TRANSITIONAL/INTENTIONAL/error checks below key off just the CRM state,
# not the annotation shape. See #532.
current = {}
for m in re.finditer(r'^service vm:(\d+)\s+\([^,]+,\s*([^)]+)\)', status, re.M):
    raw = m.group(2).strip()
    state = raw.split(',', 1)[0].split('(', 1)[0].strip()
    current[m.group(1)] = state

# Requested HA state from `ha-manager config`: a "vm:<vmid>" header followed by
# an indented "state <s>" (default 'started' when omitted). Reset on ANY
# unindented header so a non-VM block (ct:, group:) can't bleed its state in.
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

# Fail-closed: status present but no service entries parsed (partial output).
# Every Mycofu VM is HA-managed, so zero services is never legitimate.
if not current:
    emit(False, [], "'ha-manager status' returned no parseable HA service entries")

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

# Resolve manifest names to VMIDs; unresolved names (co-located app w/o its own
# VM, or not-yet-created) are not "a VM that failed to run" — skip them.
manifest_ids = set()
for n in manifest:
    if n in name2vmid:
        manifest_ids.add(name2vmid[n])

errors = []
for vmid in (set(current) | set(requested) | manifest_ids):
    name = vmid2name.get(vmid, 'vm' + vmid)
    st = vmid2status.get(vmid, 'unknown')
    # (a) error state — the DRT-005 shape.
    if current.get(vmid) == 'error':
        errors.append({"vmid": int(vmid), "name": name, "state": "error",
                       "reason": "HA service in ERROR state (vm status=%s)" % st})
        continue
    # (a2) transitional in-progress state — a healthy migration/relocation.
    # The VM briefly reports pvesh status like 'postmigrate' during finalization,
    # which is not 'running' but is not an outage. See #532.
    if current.get(vmid) in TRANSITIONAL:
        continue
    # Desired run-state: HA requested wins; else current HA if intentional-off;
    # else 'started' (a plain manifest VM must run).
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
            errors.append({"vmid": int(vmid), "name": name,
                           "state": current.get(vmid, "unknown"),
                           "reason": "HA-requested '%s' but VM not running (status=%s)" % (desired, st)})
        else:
            # (c) a config-manifest VM that is NOT HA-managed and not running.
            errors.append({"vmid": int(vmid), "name": name, "state": "n/a",
                           "reason": "config-enabled VM not running and not HA-managed (status=%s)" % st})

errors.sort(key=lambda e: e["vmid"])
emit(len(errors) == 0, errors, None)
PYEOF
)

# Extract scalar + array views for bash. Fail-closed to unhealthy on any parse
# failure of our own probe output.
HA_HEALTHY=$(printf '%s' "$HA_PROBE_JSON" | python3 -c \
  'import sys,json; print("true" if json.load(sys.stdin).get("ha_healthy") else "false")' \
  2>/dev/null || echo "false")
HA_ERRORS_ARRAY=$(printf '%s' "$HA_PROBE_JSON" | python3 -c \
  'import sys,json; print(json.dumps(json.load(sys.stdin).get("ha_errors", [])))' \
  2>/dev/null || echo "[]")
[[ -n "$HA_HEALTHY" ]] || HA_HEALTHY="false"
[[ -n "$HA_ERRORS_ARRAY" ]] || HA_ERRORS_ARRAY="[]"

# --- Detect drift ---
DRIFT_ENTRIES=""
DRIFT_COUNT=0

while IFS='=' read -r vm intended_node; do
  [[ -z "$vm" ]] && continue
  actual_line=$({ grep "^${vm}=" "$ACTUAL_FILE" 2>/dev/null || echo ""; } | head -1)
  [[ -z "$actual_line" ]] && continue

  actual_node=$(echo "$actual_line" | cut -d= -f2)
  vmid=$(echo "$actual_line" | cut -d= -f3)

  if [[ "$intended_node" != "$actual_node" ]]; then
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
    DRIFT_ENTRIES="${DRIFT_ENTRIES}${vm}:${actual_node}:${intended_node}:${vmid}
"
  fi
done < "$INTENDED_FILE"

# --- Output for --detect-only (health endpoint) ---
if [[ "$DETECT_ONLY" == "true" ]]; then
  placement_healthy=true
  [[ "$DRIFT_COUNT" -gt 0 ]] && placement_healthy=false

  drift_json="["
  first=true
  while IFS=':' read -r vm actual intended vmid; do
    [[ -z "$vm" ]] && continue
    $first || drift_json+=", "
    first=false
    drift_json+="{\"vm\": \"${vm}\", \"actual\": \"${actual}\", \"intended\": \"${intended}\", \"vmid\": ${vmid}}"
  done <<< "$DRIFT_ENTRIES"
  drift_json+="]"

  # Backward-compatible superset (#519/A5): legacy fields unchanged and
  # first; ha_healthy + ha_errors appended.
  echo "{\"placement_healthy\": ${placement_healthy}, \"all_nodes_up\": ${ALL_NODES_UP}, \"drift\": ${drift_json}, \"ha_healthy\": ${HA_HEALTHY}, \"ha_errors\": ${HA_ERRORS_ARRAY}}"
  exit 0
fi

# --- HA outage handling (#519/A5): DETECTION + GUIDANCE ONLY, NEVER a write ---
# Runs independently of drift: the DRT-005 shape is a NO-DRIFT cluster with
# services stuck in HA `error`. On an outage the watchdog logs loudly, prints
# the storage-failure-fence 6A/6B remediation ladder and the realign-cidata.sh
# pointer, and STOPS. It must never auto-clear HA errors, migrate, realign, or
# invoke any cluster write — not even rebalance-cluster.sh (even verify-only).
# Autonomously rebalancing an HA-error cluster is exactly what made the
# 2026-05-03 incident worse. Recovery is operator-driven.
if [[ "$HA_HEALTHY" != "true" ]]; then
  echo "$(date): HA outage detected (no auto-action — detection only):" >> "$LOG_FILE"
  printf '%s' "$HA_PROBE_JSON" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if d.get("ha_read_error"):
    print("  fail-closed: %s" % d["ha_read_error"])
for e in d.get("ha_errors", []):
    print("  vm:%s (%s): %s" % (e["vmid"], e["name"], e["reason"]))
' >> "$LOG_FILE" 2>/dev/null || echo "  (could not render HA error detail)" >> "$LOG_FILE"

  # G7 remediation ladder — files-in / instructions-out; only names safe
  # framework/operator commands. The watchdog never runs any of these itself.
  #
  # Universal replication: the 6A/6B ladder applies to every shipped VM
  # (each has a replica). The recreate path
  # (framework/scripts/recreate-derivable-vm.sh) has two remaining roles:
  #   (a) disk-loss / data-corruption recovery on any VM
  #   (b) recovery of an explicit-override VM (explicit false) after
  #       failover — contract: max_restart=0, max_relocate=0 → terminal
  #       error; empty set on shipped site; machinery preserved by the
  #       V6.1 HCL wiring equivalence test.
  # See .claude/rules/storage-failure-fence.md and
  # .claude/rules/replication.md for the ladder + recreate contract.
  {
    echo "$(date): The watchdog will NOT auto-clear, migrate, realign, or rebalance"
    echo "  an HA-error cluster. Operator remediation:"
    echo ""
    echo "  For EVERY shipped VM (Sprint 048 universal replication)"
    echo "  — .claude/rules/storage-failure-fence.md:"
    echo "    6A storage recovered (zpool ONLINE): for each vm:<vmid> in error, from a"
    echo "       healthy node — ha-manager set vm:<vmid> --state disabled  (error -> stopped)"
    echo "       then ha-manager set vm:<vmid> --state started  (restart in place)."
    echo "    6B storage still dead: fence the failing node FIRST (systemctl stop corosync"
    echo "       while >=1 service is still 'started', or a hard reboot / IPMI power cycle"
    echo "       if all services are already in error), THEN clear errors from a survivor"
    echo "       so HA re-places each service from its replicated zvol."
    echo ""
    echo "  For an explicit-override VM (empty set on shipped site):"
    echo "  HA \`error\` after failover is the EXPECTED terminal state"
    echo "  (max_restart=0 / max_relocate=0 by design, no local replica). Recover via:"
    echo "    framework/scripts/recreate-derivable-vm.sh <vmid>"
    echo "  Then follow that script's printed deploy command (safe-apply.sh <env> for"
    echo "  Tier-1; rebuild-cluster.sh --scope control-plane + register-runner.sh for"
    echo "  cicd)."
    echo ""
    echo "  If a config references vm-<vmid>-disk-<N> where vm-<vmid>-cloudinit is"
    echo "  canonical (rename-victim cidata), run framework/scripts/realign-cidata.sh"
    echo "  to repoint it (state-aware, HA-safe), then framework/scripts/validate.sh."
  } >> "$LOG_FILE"

  # Detection is the action. Do not fall through to the drift/rebalance path.
  exit 0
fi

# --- No drift: exit silently ---
if [[ "$DRIFT_COUNT" -eq 0 ]]; then
  exit 0
fi

# --- Drift detected ---
echo "$(date): Placement drift detected (${DRIFT_COUNT} VM(s) misplaced):" >> "$LOG_FILE"
while IFS=':' read -r vm actual intended vmid; do
  [[ -z "$vm" ]] && continue
  echo "  ${vm} (VMID ${vmid}): on ${actual}, should be ${intended}" >> "$LOG_FILE"
done <<< "$DRIFT_ENTRIES"

# If nodes are down, log and wait for next timer run
if [[ "$ALL_NODES_UP" != "true" ]]; then
  echo "$(date): Node(s) down — waiting for recovery before rebalancing." >> "$LOG_FILE"
  exit 0
fi

# All nodes healthy — run rebalance
echo "$(date): All nodes healthy. Running rebalance..." >> "$LOG_FILE"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBALANCE="${SCRIPT_DIR}/rebalance-cluster.sh"

if [[ -x "$REBALANCE" ]]; then
  # rebalance-cluster.sh may exit nonzero when a migration attempt fails or
  # verify_recovery finds unrecovered HA state (#697 P4 / #514). Capture that
  # exit under `set -o pipefail` — a bare pipe would kill the watchdog and,
  # since cron re-runs it every 5 minutes, that would crash-loop the log.
  set +e
  "$REBALANCE" 2>&1 | tee -a "$LOG_FILE"
  REBALANCE_RC=${PIPESTATUS[0]}
  set -e
  if [[ "$REBALANCE_RC" -ne 0 ]]; then
    echo "$(date): WARNING: rebalance-cluster.sh exited with rc=${REBALANCE_RC} — cluster remains unrecovered; will retry on next cron cycle." >> "$LOG_FILE"
  else
    echo "$(date): Rebalance complete." >> "$LOG_FILE"
  fi
else
  echo "$(date): ERROR: rebalance-cluster.sh not found at ${REBALANCE}" >> "$LOG_FILE"
  exit 1
fi
