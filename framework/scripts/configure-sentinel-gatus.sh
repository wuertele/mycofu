#!/usr/bin/env bash
# configure-sentinel-gatus.sh — Deploy sentinel Gatus on the NAS (Docker).
#
# Usage: configure-sentinel-gatus.sh
#
# Reads config.yaml for NAS SSH credentials and generates a minimal Gatus
# config that monitors the primary Gatus and critical cluster endpoints.
# Uses direct IPs (not DNS) — must work when cluster DNS is down.

set -euo pipefail

find_repo_root() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$dir" != "/" ]]; do
    [[ -f "${dir}/flake.nix" ]] && { echo "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  echo "ERROR: Could not find repo root" >&2
  exit 1
}

REPO_DIR="$(find_repo_root)"
CONFIG="${REPO_DIR}/site/config.yaml"

NAS_IP=$(yq -r '.nas.ip' "$CONFIG")
NAS_USER=$(yq -r '.nas.ssh_user' "$CONFIG")

# SSH options for NAS calls. Bound the local SSH so a wedged remote
# command cannot hold this script forever. DRT-001 on 2026-04-25 hung
# 30+ minutes inside `docker stop gatus-sentinel` against a NAS dockerd
# that had leaked container state after 55 days uptime; without these
# options the script had no way to detect or recover from the hang.
# See docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md.
#
# ControlMaster reuses one SSH master across the script's 16+ ssh/scp
# calls. Synology DSM's sshd defaults to MaxStartups=10:30:100, which
# starts dropping new unauthenticated connections after 10 in flight;
# combined with the new ConnectTimeout=10 from MR !200, rapid sequential
# connections were hitting refused/delayed handshakes (issue #243).
# Multiplexing makes the local SSH cost effectively zero after the first
# call, so the rate limit is no longer reachable. ControlPersist=60s
# keeps the master around long enough to absorb the script's full run
# but not so long that it lingers after exit. The mux socket lives in a
# per-invocation directory so concurrent invocations do not collide.
#
# Stored as a bash array so an option containing a space cannot
# silently break word-splitting. Sister Sprint 029 script
# cert-storage-backfill.sh follows the same convention.
#
# ControlPath note: Unix-domain-socket paths are capped at 104 bytes on
# macOS (108 on Linux). `mktemp -d -t prefix.XXX` honors $TMPDIR, which
# on macOS is the very long `/var/folders/.../T/` per-user dir — the
# resolved ControlPath would exceed the cap and SSH would refuse to
# create the mux socket with `unix_listener: path ... too long`. Use
# an explicit `/tmp/` prefix so the mktemp dir is short on every host.
# The trailing `c%p` (PID-derived suffix only) keeps the per-connection
# path tight even for long usernames or IPs.
SSH_MUX_DIR="$(mktemp -d "/tmp/cs-mux.XXXXXX")"
trap 'ssh -o "ControlPath=${SSH_MUX_DIR}/c%p" -O exit "${NAS_USER}@${NAS_IP}" 2>/dev/null || true; rm -rf "${SSH_MUX_DIR}" 2>/dev/null || true' EXIT
SSH_OPTS=(
  -o ConnectTimeout=10
  -o ServerAliveInterval=10
  -o ServerAliveCountMax=3
  -o ControlMaster=auto
  -o "ControlPath=${SSH_MUX_DIR}/c%p"
  -o ControlPersist=60s
)

# Bounds for the docker container-lifecycle operations. Each is wrapped
# in a NAS-side `timeout` so the remote command cannot block the local
# SSH indefinitely. 30s is generous for a healthy daemon; longer waits
# indicate a daemon-level wedge that won't be cured by waiting more.
DOCKER_STOP_TIMEOUT=30
DOCKER_KILL_TIMEOUT=30
DOCKER_INSPECT_TIMEOUT=15
DOCKER_RM_TIMEOUT=30
DOCKER_RUN_TIMEOUT=60
DOCKER_VERIFY_TIMEOUT=30
GATUS_IP=$(yq -r '.vms.gatus.ip' "$CONFIG")
DNS1_IP=$(yq -r '.vms.dns1_prod.ip' "$CONFIG")
DNS2_IP=$(yq -r '.vms.dns2_prod.ip' "$CONFIG")
DNS_DOMAIN="prod.$(yq -r '.domain' "$CONFIG")"

SMTP_HOST=$(yq -r '.email.smtp_host' "$CONFIG")
SMTP_PORT=$(yq -r '.email.smtp_port' "$CONFIG")
EMAIL_FROM="gatus@$(yq -r '.domain' "$CONFIG")"
EMAIL_TO=$(yq -r '.email.to' "$CONFIG")

# Read first node IP for Proxmox API check
NODE1_IP=$(yq -r '.nodes[0].mgmt_ip' "$CONFIG")

# NAS prereq check: this script's resilience depends on `timeout` being
# available on the NAS so docker calls can be bounded. If absent, fail
# loud rather than silently fall back to unbounded calls (which would
# reintroduce the DRT-001 hang class). DSM ships GNU coreutils
# `timeout` at /usr/bin/timeout in current ContainerManager versions;
# this check protects against package downgrade or a future NAS image
# that omits it.
if ! ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" 'command -v timeout >/dev/null 2>&1'; then
  cat >&2 <<EOF

ERROR: NAS ${NAS_IP} does not have 'timeout' available in PATH.

This script bounds docker container-lifecycle commands with NAS-side
'timeout' so a wedged daemon cannot hang convergence indefinitely.
Without 'timeout' the bound silently fails open and the script could
reintroduce the DRT-001 hang class
(docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md).

Verify GNU coreutils is installed on the NAS, or update
.claude/rules/nas-scripts.md and this script if a different bounding
mechanism is preferred.
EOF
  exit 1
fi

echo "Deploying sentinel Gatus to NAS at ${NAS_IP}..."

# Generate sentinel config
SENTINEL_CONFIG=$(cat <<EOF
# Sentinel Gatus — minimal watchdog on NAS.
# Monitors the primary Gatus and critical cluster endpoints.
# Uses direct IPs, not DNS. Must work when cluster DNS is down.

alerting:
  email:
    from: "${EMAIL_FROM}"
    host: "${SMTP_HOST}"
    port: ${SMTP_PORT}
    to: "${EMAIL_TO}"
    default-alert:
      enabled: true
      send-on-resolved: true
      failure-threshold: 3
      success-threshold: 2

endpoints:
  - name: primary-gatus
    group: cluster
    url: "http://${GATUS_IP}:8080/api/v1/endpoints/statuses"
    conditions:
      - "[STATUS] == 200"
    interval: 30s
    alerts:
      - type: email

  - name: proxmox-api
    group: cluster
    url: "https://${NODE1_IP}:8006"
    client:
      insecure: true
    conditions:
      - "[STATUS] < 500"
    interval: 30s
    alerts:
      - type: email

  - name: dns1-prod
    group: dns
    url: "${DNS1_IP}"
    dns:
      query-name: "dns1.${DNS_DOMAIN}"
      query-type: "A"
    conditions:
      - "[DNS_RCODE] == NOERROR"
    interval: 30s
    alerts:
      - type: email

  - name: dns2-prod
    group: dns
    url: "${DNS2_IP}"
    dns:
      query-name: "dns1.${DNS_DOMAIN}"
      query-type: "A"
    conditions:
      - "[DNS_RCODE] == NOERROR"
    interval: 30s
    alerts:
      - type: email
EOF
)

# Create config directory on NAS
ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" "mkdir -p /volume1/docker/gatus-sentinel"

# Write config to NAS
echo "$SENTINEL_CONFIG" | ssh "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_IP}" "cat > /volume1/docker/gatus-sentinel/config.yaml"

# Replace the gatus-sentinel container.
#
# Container-runtime states sometimes cause docker container-lifecycle
# commands to hang indefinitely (DRT-001 on 2026-04-25 hung 30+ minutes
# inside docker stop against a wedged dockerd). Every docker call below
# is bounded by NAS-side `timeout` so convergence converges instead of
# waiting forever. Per Sprint 029's Goal 10 propagation pattern, no
# `2>/dev/null || true` masking on mutation operations: failures here
# surface non-zero so the convergence step fails loudly rather than
# silently leaving a half-replaced container.
#
# Three sentinel exit codes from the wrapped commands are meaningful:
#   - SSH itself fails (255):  fail loud — NAS unreachable or sshd down,
#                              we don't actually know container state
#   - docker inspect non-zero: container is genuinely absent (the only
#                              path that returns non-zero from a
#                              successful SSH+timeout)
#   - docker stop/kill/rm/run non-zero with SSH success: docker-side
#                              failure (rate-limited image pull, name
#                              conflict, daemon wedge) — fail loud

# inspect_container_state: print one of "true", "false", "missing", or
# "ssh-failed"; never "unknown". Distinguishes the SSH transport's
# health from the daemon's view of the container.
inspect_container_state() {
  local out rc
  set +e
  out=$(ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" \
        "timeout ${DOCKER_INSPECT_TIMEOUT} /usr/local/bin/docker inspect -f '{{.State.Running}}' gatus-sentinel 2>/dev/null")
  rc=$?
  set -e
  case "$rc" in
    0)
      case "$out" in
        true|false) printf '%s\n' "$out" ;;
        *)          printf 'unexpected:%s\n' "$out" ;;
      esac
      ;;
    255)
      # SSH transport failure (connection refused, timeout, auth, etc.)
      printf 'ssh-failed\n'
      ;;
    *)
      # SSH succeeded but the remote command failed. For docker inspect
      # this means the container is genuinely absent, OR `timeout` was
      # tripped (rc 124) OR docker daemon was unresponsive in a different
      # way. We can't distinguish those at this layer; treat as missing
      # for the inspect path. The post-stop verification poll is more
      # cautious (it only treats explicit "false" as terminal-good).
      printf 'missing\n'
      ;;
  esac
}

# Step 1: detect whether gatus-sentinel exists.
container_state=$(inspect_container_state)

case "$container_state" in
  ssh-failed)
    cat >&2 <<EOF

ERROR: SSH to NAS ${NAS_IP} failed during initial container inspect.
       Cannot determine whether gatus-sentinel exists; refusing to
       proceed (Goal 10: unknowable state must fail, not pass).

Verify NAS reachability and sshd state, then retry.
EOF
    exit 1
    ;;
  unexpected:*)
    cat >&2 <<EOF

ERROR: docker inspect returned an unexpected value for gatus-sentinel
       on NAS ${NAS_IP}: '${container_state#unexpected:}'

Expected 'true' or 'false'. The container is in a state this script
does not know how to handle (e.g. Restarting, Paused, or a daemon
inconsistency). Refusing to proceed.
EOF
    exit 1
    ;;
  true|false|missing)
    : # fall through
    ;;
  *)
    echo "ERROR: inspect_container_state returned an unhandled sentinel: ${container_state}" >&2
    exit 1
    ;;
esac

if [[ "$container_state" == "true" || "$container_state" == "false" ]]; then
  # Container exists; need to stop it first (or confirm it's already stopped).

  if [[ "$container_state" == "true" ]]; then
    echo "Stopping gatus-sentinel (graceful, ${DOCKER_STOP_TIMEOUT}s bound)..."
    if ! ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" \
           "timeout ${DOCKER_STOP_TIMEOUT} /usr/local/bin/docker stop gatus-sentinel"; then
      echo "Graceful stop failed or timed out; escalating to SIGKILL..."
      if ! ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" \
             "timeout ${DOCKER_KILL_TIMEOUT} /usr/local/bin/docker kill -s SIGKILL gatus-sentinel"; then
        cat >&2 <<EOF

ERROR: docker stop AND docker kill both failed for gatus-sentinel
       on NAS ${NAS_IP}.

This usually means dockerd has leaked container state at the daemon
level (DRT-001 on 2026-04-25 first surfaced this; see
docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md). Recovery
requires restarting the NAS Container Manager package:

  ssh ${NAS_USER}@${NAS_IP} '/usr/syno/bin/synopkg restart ContainerManager'

After recovery, retry this script.
EOF
        exit 1
      fi
    fi
  fi

  # Step 2: poll-and-confirm the container is no longer running.
  # Even after stop/kill returns success, dockerd's state can lag
  # briefly; `docker rm` and `docker run --name` will race against
  # that lag without this verification step. The poll uses the same
  # SSH-vs-docker distinguishing helper as Step 1: if SSH fails
  # mid-poll we fail loud rather than treating the disconnect as
  # "container is gone" (which would race into docker rm/run against
  # an unknown daemon state).
  echo "Verifying gatus-sentinel is no longer running..."
  deadline=$(( $(date +%s) + DOCKER_VERIFY_TIMEOUT ))
  state="unknown"
  while [[ $(date +%s) -lt $deadline ]]; do
    state=$(inspect_container_state)
    case "$state" in
      false|missing)
        break ;;
      ssh-failed)
        cat >&2 <<EOF

ERROR: SSH to NAS ${NAS_IP} failed during post-stop verification poll.
       Cannot confirm container is gone; refusing to proceed to
       docker rm/run (Goal 10: unknowable state must fail, not pass).

Verify NAS reachability and retry.
EOF
        exit 1 ;;
      unexpected:*)
        cat >&2 <<EOF

ERROR: docker inspect returned an unexpected value '${state#unexpected:}'
       during post-stop verification poll. Refusing to proceed.
EOF
        exit 1 ;;
      true)
        sleep 2 ;;
      *)
        echo "ERROR: inspect_container_state returned unhandled value: ${state}" >&2
        exit 1 ;;
    esac
  done
  if [[ "$state" == "true" ]]; then
    echo "ERROR: gatus-sentinel still reports Running after stop+kill+wait." >&2
    echo "Refusing to proceed to docker rm/run; manual investigation needed." >&2
    exit 1
  fi

  # Step 3: remove the stopped container record. `-f` is safe here
  # because we've confirmed it's not running. Bounded by `timeout`
  # because the same daemon-leak class that wedges stop/kill can also
  # wedge rm.
  ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" \
    "timeout ${DOCKER_RM_TIMEOUT} /usr/local/bin/docker rm -f gatus-sentinel"
fi

# Step 4: start the new container. Bounded for the same reason as rm —
# docker run can wedge against a daemon-state issue, especially during
# image pull or network setup.
echo "Starting fresh gatus-sentinel container..."
ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" "timeout ${DOCKER_RUN_TIMEOUT} /usr/local/bin/docker run -d \
  --name gatus-sentinel \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /volume1/docker/gatus-sentinel/config.yaml:/config/config.yaml:ro \
  twinproduction/gatus@sha256:5f1c61ca012079a87202f7477e109f7499e11a1ed68cd683c775ccb35720d675"

# --- Deploy placement watchdog ---
echo ""
echo "Deploying placement watchdog to NAS..."

# Copy scripts and config needed for drift detection
ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" "mkdir -p /volume1/docker/placement-watchdog"
scp "${SSH_OPTS[@]}" -O -q "${REPO_DIR}/framework/scripts/placement-watchdog.sh" "${NAS_USER}@${NAS_IP}:/volume1/docker/placement-watchdog/"
scp "${SSH_OPTS[@]}" -O -q "${REPO_DIR}/framework/scripts/rebalance-cluster.sh" "${NAS_USER}@${NAS_IP}:/volume1/docker/placement-watchdog/"

# Convert config.yaml + applications.yaml to merged JSON for the NAS (NAS has jq but not yq).
# The NAS scripts use cfg_query() which reads from this merged JSON.
# Applications live in a separate file but the NAS scripts expect a single combined view.
APPS_YAML="${REPO_DIR}/site/applications.yaml"
CONFIG_JSON=$(yq -o json "${REPO_DIR}/site/config.yaml")
if [[ -f "$APPS_YAML" ]]; then
  APPS_JSON=$(yq -o json '.applications // {}' "$APPS_YAML")
else
  APPS_JSON='{}'
fi
echo "$CONFIG_JSON" "$APPS_JSON" | jq -s '(.[0] | del(.applications)) + {applications: .[1]}' | \
  ssh "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_IP}" "cat > /volume1/docker/placement-watchdog/config.json"

# Make scripts executable on NAS
ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" "chmod +x /volume1/docker/placement-watchdog/*.sh"

# Set up the health server (runs as a background process).
# Kill any existing instance and wait for the port to free up. The
# inner `kill ... 2>/dev/null || true` and `pkill ... || true` are
# expected to "fail" when there's nothing to kill (fresh install,
# or already-restarted server) — that is the no-op case the
# placement watchdog deployment is designed for. The OUTER SSH
# command itself is NOT softened: if SSH fails, that is a real
# error and should propagate. The inner shell exits 0 either way
# because the `for` loop is the last statement.
#
# pkill self-match note: `pkill -f PATTERN` reads each process's full
# command line and matches PATTERN as a regex. The pattern itself
# appears LITERALLY in the command line of the remote shell that
# runs this SSH command (the parent of pkill — typically a login
# shell or `sh -c` wrapper depending on remote sshd config), so a
# literal pattern like 'placement-watchdog.sh --health-server'
# would match the script's own remote shell, kill it, and the local
# SSH client returns 255 (channel torn down). The classic regex
# bracket trick — '[p]lacement-...' — matches the same processes
# (regex `[p]` resolves to literal `p`) but does NOT appear
# literally in any cmdline, so pkill does not self-match. The
# 2>/dev/null || true guard cannot recover from this: the 255 is
# the OUTER SSH's exit code, not pkill's. Without this trick the
# script would exit 255 here even though pkill's intent was pure
# no-op. Filed under issue #243.
ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" "
  # Kill any process holding port 9200 (old or new health server)
  PORT_PID=\$(netstat -tlnp 2>/dev/null | grep ':9200 ' | awk '{print \$7}' | cut -d/ -f1)
  if [ -n \"\$PORT_PID\" ]; then
    kill \$PORT_PID 2>/dev/null || true
    sleep 2
  fi
  # Also kill by name pattern in case it's not yet listening.
  # Regex bracket trick avoids self-match; see comment above.
  pkill -f '[p]lacement-watchdog.sh --health-server' 2>/dev/null || true
  # Wait for port to free
  for i in 1 2 3 4 5; do
    if ! netstat -tlnp 2>/dev/null | grep -q ':9200 '; then
      break
    fi
    sleep 1
  done
"

# Start health server (port 9200). nohup + & disowns; the SSH returns
# as soon as the launch command completes. SSH-level failure (NAS
# unreachable, sshd down) propagates per Sprint 029 Goal 10. If the
# nohup launch itself fails (e.g., script not found after the chmod
# step), bash's `nohup ... &` returns 0 because the disown happens
# before the script's first instruction would error — that
# limitation is inherent to fire-and-forget; runtime failures of
# the watchdog show up via its log and the Gatus health check.
ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" "
  export WATCHDOG_CONFIG_DIR=/volume1/docker/placement-watchdog
  nohup /volume1/docker/placement-watchdog/placement-watchdog.sh --health-server 9200 \
    >> /var/log/placement-watchdog.log 2>&1 &
"

# Set up periodic watchdog via Synology cron.
#
# Synology DSM does NOT ship a `crontab` binary anywhere — verified on
# this NAS (no `/usr/bin/crontab`, `/usr/local/bin/crontab`,
# `/usr/syno/bin/crontab`, or any other path). The DSM-native scheduler
# is `/usr/syno/bin/synoschedtask`, but its CLI exposes only
# --get/--del/--run/--reset-status/--sync — task creation goes through
# the DSM web UI or `/usr/syno/etc/synocron.d/` only.
#
# The actual DSM-native cron mechanism is `/etc/crontab` (the file).
# It uses Synology's 7-field format with a `who` column:
#   minute  hour  mday  month  wday  who  command
# That is different from the POSIX 6-field `crontab -e` format. The
# pre-existing operator-installed `pg-backup-tofu.sh` entry on this NAS
# confirms `/etc/crontab` is the right surface to extend.
#
# We append to /etc/crontab idempotently (grep marker, append on miss).
# Using a marker comment keeps the diff trivial to inspect and removes
# the need to parse fields. Synology's cron service rereads /etc/crontab
# on its own schedule; no daemon reload is required.
#
# Issue #243: prior versions of this script invoked `crontab -l` /
# `crontab -` and exited 255 on this NAS because the binary doesn't
# exist. That left the placement-watchdog cron entry uninstalled
# (and the placement-health server killed by call 7 above with no
# matching restart) until the next operator intervention.
CRON_MARKER="# placement-watchdog (managed by configure-sentinel-gatus.sh, issue #243)"
CRON_CMD="WATCHDOG_CONFIG_DIR=/volume1/docker/placement-watchdog /volume1/docker/placement-watchdog/placement-watchdog.sh"
CRON_LINE=$'*/5\t*\t*\t*\t*\troot\t'"${CRON_CMD}"' >> /var/log/placement-watchdog.log 2>&1'
ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" "
  if grep -qF 'placement-watchdog.sh' /etc/crontab; then
    echo 'Placement watchdog cron entry already exists in /etc/crontab'
  else
    printf '%s\n%s\n' '${CRON_MARKER}' '${CRON_LINE}' >> /etc/crontab
    echo 'Added placement-watchdog to /etc/crontab (every 5 minutes)'
  fi
"

echo ""
echo "Sentinel Gatus deployed to NAS at ${NAS_IP}:8080"
echo "Placement watchdog health endpoint at ${NAS_IP}:9200"
echo "Verify: ssh ${NAS_USER}@${NAS_IP} docker logs gatus-sentinel --tail 20"
echo "Verify watchdog: curl -s http://${NAS_IP}:9200/ | python3 -m json.tool"
