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
CIDATA_GUARD_LIB="${REPO_DIR}/framework/scripts/lib/cidata-guard.sh"

NAS_IP=$(yq -r '.nas.ip' "$CONFIG")
NAS_USER=$(yq -r '.nas.ssh_user' "$CONFIG")

if [[ ! -f "$CIDATA_GUARD_LIB" ]]; then
  echo "ERROR: cidata guard library not found at ${CIDATA_GUARD_LIB}." >&2
  exit 1
fi
cidata_guard_version_line="$(grep -m1 '^CIDATA_GUARD_LIB_VERSION=' "$CIDATA_GUARD_LIB")" || {
  echo "ERROR: CIDATA_GUARD_LIB_VERSION not found in ${CIDATA_GUARD_LIB}." >&2
  exit 1
}
CIDATA_GUARD_LIB_VERSION="${cidata_guard_version_line#CIDATA_GUARD_LIB_VERSION=}"
CIDATA_GUARD_LIB_VERSION="${CIDATA_GUARD_LIB_VERSION#\"}"
CIDATA_GUARD_LIB_VERSION="${CIDATA_GUARD_LIB_VERSION%\"}"

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

# Bound for the NAS-side docker path probe. The candidate list is two
# static file paths; on a healthy NAS the loop finishes in milliseconds.
# A > 10s wait means the NAS filesystem itself is wedged, which is the
# same DRT-001 hang class the rest of this script guards against. Fail
# closed rather than let discovery hang.
DOCKER_PATH_PROBE_TIMEOUT=10

# nas_docker: resolve the NAS docker binary path across Synology
# Container Manager layouts. Legacy DSM installs expose docker at
# /usr/local/bin/docker; newer package layouts ship it at
# /volume1/@appstore/ContainerManager/usr/bin/docker instead. Which one
# the NAS has depends on install history (fresh install vs. upgrade
# path), so a hard-coded path silently breaks convergence when the NAS
# only carries the other layout (issues #30, #61).
#
# The function probes the NAS once via SSH, walks the candidate paths in
# order, and populates NAS_DOCKER with the first path that exists AND is
# executable. Subsequent docker call sites reference "${NAS_DOCKER}"
# rather than a hard-coded path, so the script converges on whichever
# layout the NAS actually has.
#
# Fail-loud per Sprint 029 Goal 10 in three distinct failure modes:
#   * SSH transport failure (rc=255) — NAS unreachable / sshd down /
#     mux socket dead. Same distinction as inspect_container_state()
#     below: an operator seeing this error knows to check reachability
#     rather than Container Manager install state.
#   * Probe non-zero (rc != 0, rc != 255) — neither candidate path
#     exists, or the NAS-side `timeout ${DOCKER_PATH_PROBE_TIMEOUT}`
#     tripped (rc=124). Message says "docker binary not found in
#     known Synology paths" — the operator's action is to install
#     Container Manager or extend the candidate list.
#   * Probe rc=0 but stdout is not exactly one of the known paths —
#     Synology DSM logins can print MOTD/banner text that leaks into
#     $(ssh ...) capture. Refusing to accept unexpected stdout keeps
#     us from passing "Copyright... /usr/local/bin/docker" as a
#     docker binary path and getting a confusing failure downstream.
#
# The remote body is a single-quoted here-doc-shape shell fragment
# executed via `timeout ${DOCKER_PATH_PROBE_TIMEOUT} bash -s`. Piping
# the script over stdin keeps quoting flat; we drop `-n` here because
# this call is not inside a `while read` loop and needs its stdin as
# the payload (per .claude/rules/ssh.md).
#
# Runs on the NAS via `[ -x ]` from bash, per nas-scripts.md userland
# (bash/jq/curl/ssh only, no yq/socat/opkg).
nas_docker() {
  local path rc
  set +e
  # Wrap the probe with NAS-side `timeout` so even discovery can't hang
  # against a wedged NAS. The `timeout` prereq check at the top of this
  # script guarantees it is available. Client-side expansion of
  # DOCKER_PATH_PROBE_TIMEOUT is intentional (a workstation-side
  # constant baked into the remote command).
  # shellcheck disable=SC2029  # intentional client-side expansion; sister DOCKER_*_TIMEOUT sites use the same pattern
  path=$(ssh "${SSH_OPTS[@]}" "${NAS_USER}@${NAS_IP}" \
    "timeout ${DOCKER_PATH_PROBE_TIMEOUT} bash -s" <<'NASDOCKERPROBE'
for p in /usr/local/bin/docker /volume1/@appstore/ContainerManager/usr/bin/docker; do
  if [ -x "$p" ]; then
    printf '%s\n' "$p"
    exit 0
  fi
done
exit 1
NASDOCKERPROBE
  )
  rc=$?
  set -e
  case "$rc" in
    255)
      cat >&2 <<NASDOCKEREOF

ERROR: SSH to NAS ${NAS_IP} failed during docker-path resolution.
       Cannot determine which docker binary the NAS uses; refusing
       to proceed (Goal 10: unknowable state must fail, not pass).

Verify NAS reachability and sshd state, then retry.
NASDOCKEREOF
      exit 1
      ;;
    0)
      # SSH ok; validate stdout is exactly one of the known candidate
      # paths. Any MOTD/banner noise → treat as protocol violation.
      case "$path" in
        /usr/local/bin/docker|/volume1/@appstore/ContainerManager/usr/bin/docker)
          NAS_DOCKER="$path"
          ;;
        *)
          cat >&2 <<NASDOCKEREOF

ERROR: nas_docker() got unexpected stdout from NAS ${NAS_IP} probe:
-----BEGIN UNEXPECTED-----
${path}
-----END UNEXPECTED-----

Expected exactly one of:
  /usr/local/bin/docker
  /volume1/@appstore/ContainerManager/usr/bin/docker

Usually caused by a NAS-side shell printing a banner/MOTD to stdout;
the noise would break downstream docker invocations if passed through.
Fix by silencing the NAS login banner or extending the candidate list
in nas_docker() to include the new path.
NASDOCKEREOF
          exit 1
          ;;
      esac
      ;;
    *)
      # SSH ok but the remote probe exited non-zero. That is either
      # "neither candidate exists" (loop's `exit 1`) or the NAS-side
      # `timeout` fired (rc=124, wedged filesystem). Both are fatal
      # in the same way: we cannot converge.
      cat >&2 <<NASDOCKEREOF

ERROR: docker binary not found at any known Synology path on NAS ${NAS_IP}.
       Tried:
         /usr/local/bin/docker
         /volume1/@appstore/ContainerManager/usr/bin/docker

Verify Container Manager is installed on the NAS and reachable via SSH,
then retry. If the NAS uses a new ContainerManager layout, extend the
candidate list in nas_docker() in this script.

(Non-zero exit code from the NAS-side probe: ${rc}.
 rc=124 typically indicates the NAS-side 'timeout ${DOCKER_PATH_PROBE_TIMEOUT}'
 tripped, which points at a wedged NAS filesystem, not a missing package.)
NASDOCKEREOF
      exit 1
      ;;
  esac
}

# Resolve NAS docker path once; all downstream call sites use "${NAS_DOCKER}".
nas_docker
echo "Using NAS docker binary: ${NAS_DOCKER}"

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
# Five sentinel exit codes from the wrapped commands are meaningful:
#   - SSH itself fails (255):    fail loud — NAS unreachable or sshd
#                                down, we don't actually know container
#                                state
#   - `timeout` fires (rc=124):  fail loud — the NAS-side bound tripped
#                                and we don't know container state.
#                                Distinct from "genuinely absent"
#                                (issue #559): collapsing rc=124 into
#                                "missing" would race docker rm/run
#                                against an unknown daemon state.
#   - docker inspect rc=1:       docker CLI failure — only
#                                terminal-good when the captured
#                                stderr matches docker's documented
#                                missing-container text ("No such
#                                object" or "No such container").
#                                Every other rc=1 (daemon connection
#                                failure, template error, socket
#                                permission error) routes to
#                                probe-error:1 and fails loud
#                                (issue #614). Pre-#614 the branch
#                                mapped every rc=1 to "missing",
#                                which raced docker rm/run against
#                                daemon-side errors — the narrower
#                                DRT-001 wedge class #559 (rc=124)
#                                and #588 (rc=125/126/127) closed.
#   - docker inspect rc=other
#     (125/126/127/137/143/…):   fail loud — probe-invocation failure
#                                (issue #588). `timeout` errored, the
#                                docker binary is missing/not
#                                executable, or an alternate `timeout`
#                                impl signalled overrun via SIGKILL/
#                                SIGTERM. We do not know container
#                                state; collapsing these into
#                                "missing" would race docker rm/run
#                                the same as the rc=124 class.
#   - docker stop/kill/rm/run non-zero with SSH success: docker-side
#                                failure (rate-limited image pull,
#                                name conflict, daemon wedge) — fail
#                                loud

# LAST_INSPECT_STDERR_FILE side channel: the classifier writes the
# captured remote stderr to this file so error handlers can surface
# docker's own error text in operator-actionable messages (issue
# #614). A file, not a shell variable, because inspect_container_state
# is invoked via command substitution (`$(inspect_container_state)`)
# which runs in a subshell — any variable assigned inside is lost
# to the parent. The file lives inside SSH_MUX_DIR so the EXIT
# trap's `rm -rf "${SSH_MUX_DIR}"` reclaims it automatically. Path
# is fixed (not mktemp) so the caller can find it without needing
# a return value in a second channel.
LAST_INSPECT_STDERR_FILE="${SSH_MUX_DIR}/last-inspect-stderr"

# Reader for LAST_INSPECT_STDERR_FILE. Returns empty string on
# missing / empty / unreadable file rather than aborting under
# set -e. Callers on the probe-error path use this to compose the
# BEGIN DOCKER STDERR diagnostic block.
last_inspect_stderr() {
  cat "$LAST_INSPECT_STDERR_FILE" 2>/dev/null || true
}

# inspect_container_state: print one of "true", "false", "missing",
# "probe-timeout", "ssh-failed", or "probe-error:<rc>"; never
# "unknown". Distinguishes:
#   - the SSH transport's health (rc=255 → ssh-failed) from the
#     daemon's view of the container
#   - a bounded probe that hit its timeout (rc=124 → probe-timeout)
#     from a container that is genuinely absent (rc=1 with docker's
#     "No such object"/"No such container" stderr → missing)
#   - a genuine missing-container rc=1 from other rc=1 causes
#     (docker daemon connection failure, template errors, socket
#     permission errors, etc.) via captured remote stderr. Those
#     non-"No such" rc=1 causes route to "probe-error:1" rather
#     than being silently collapsed into "missing" (issue #614).
#   - probe-invocation failures on the NAS shell (rc=125/126/127 and
#     other unclassified non-zero) from either of the above. These
#     codes indicate the `timeout` wrapper or docker binary could
#     not be invoked normally (rc=125: timeout itself errored;
#     rc=126: command found but not executable; rc=127: command not
#     found) or the docker CLI reported a failure distinct from
#     "no such container". Alternate `timeout` implementations may
#     also signal an overrun as rc=137/143 (SIGKILL/SIGTERM) instead
#     of 124. Callers must fail loud rather than treat these as
#     terminal-good.
#
# Issue #559 fixed the specific rc=124 collapse into "missing".
# Issue #588 extended the classifier so rc=125/126/127 and other
# non-{0,1,124,255} codes route to "probe-error:<rc>" that carries
# the numeric rc for operator diagnosis.
# Issue #614 (this change) closes the remaining rc=1 sub-case: the
# post-#588 code still collapsed every rc=1 into "missing", but
# docker CLI uses rc=1 for daemon connection failures, template
# errors, and socket permission errors as well as its documented
# "No such container" case. The classifier now captures the remote
# stderr and text-matches "No such object"/"No such container" to
# distinguish a genuinely-missing container from a daemon-side rc=1
# error. Non-matching rc=1 routes to "probe-error:1"; the existing
# `probe-error:*` callers surface the captured stderr in operator
# diagnostics via last_inspect_stderr() (backed by LAST_INSPECT_STDERR_FILE).
#
inspect_container_state() {
  local out rc
  # Truncate the shared stderr file at the top so a caller reading
  # after this returns cannot see stale stderr from a prior call.
  : > "$LAST_INSPECT_STDERR_FILE"
  set +e
  # Capture remote stderr into $LAST_INSPECT_STDERR_FILE so the
  # classifier can distinguish docker's documented "No such
  # container" rc=1 from other rc=1 causes (daemon down, template
  # errors, socket permission errors). Prior to #614, `2>/dev/null`
  # on the remote command discarded the very stderr needed to make
  # that distinction and rc=1 was unconditionally mapped to
  # "missing" — a broken daemon returning rc=1 would race
  # docker rm/run against unknown state, the narrower DRT-001 wedge
  # class #559 (rc=124) and #588 (rc=125/126/127) closed.
  # LC_ALL=C pins docker's stderr text to English so the classifier's
  # "No such object"/"No such container" match is not fragile against
  # a future Synology DSM locale change. DSM defaults to en_US today,
  # so this is defense-in-depth (claude P3-1 + fork2 P2-1). The
  # `LC_ALL=C` is inside the remote command's shell quoting so it
  # exports to the docker process, not the local ssh client.
  out=$(ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" \
        "LC_ALL=C timeout ${DOCKER_INSPECT_TIMEOUT} ${NAS_DOCKER} inspect -f '{{.State.Running}}' gatus-sentinel" \
        2>"$LAST_INSPECT_STDERR_FILE")
  rc=$?
  set -e
  # Read stderr inside the function so the `case` below can pattern-
  # match on it; the file itself remains on disk for the caller
  # (this function runs in a `$(...)` subshell so a shell-variable
  # side channel would not survive back to the parent).
  local err
  err="$(last_inspect_stderr)"
  case "$rc" in
    0)
      case "$out" in
        true|false) printf '%s\n' "$out" ;;
        *)          printf 'unexpected:%s\n' "$out" ;;
      esac
      ;;
    1)
      # docker inspect writes "No such object" (docker >=1.13) or
      # "No such container" (older clients / some code paths) to
      # stderr when the container is genuinely absent. Match either
      # phrase to route to "missing" (terminal-good for callers).
      # Any other rc=1 stderr (typically "Cannot connect to the
      # Docker daemon", "template error", "permission denied while
      # trying to connect to the Docker daemon socket") is a
      # probe-invocation failure and routes to "probe-error:1" —
      # the existing `probe-error:*` handler in both callers picks
      # this up and surfaces last_inspect_stderr() (the LAST_INSPECT_STDERR_FILE reader) in the operator
      # diagnostic (issue #614).
      #
      # Match-set scope: this list is calibrated to the docker CLI
      # variants shipped by Synology Container Manager and tracked
      # by `nas_docker()` (`/usr/local/bin/docker` and
      # `/volume1/@appstore/ContainerManager/usr/bin/docker`). Both
      # are Docker CE and emit these exact phrases. If a future
      # sprint adds a non-Docker-CE candidate to `nas_docker()`
      # (a podman shim, a rootless-docker fork, an ARM-only
      # container CLI), audit the new binary's missing-container
      # stderr and extend this match — otherwise its "No such
      # container" case will silently route to `probe-error:1` and
      # look like a daemon-side failure at first blush. Fail-loud
      # is the safe direction, but the operator-diagnostic path
      # would be confusing.
      case "$err" in
        *"No such object"*|*"No such container"*)
          printf 'missing\n'
          ;;
        *)
          printf 'probe-error:1\n'
          ;;
      esac
      ;;
    124)
      # NAS-side `timeout ${DOCKER_INSPECT_TIMEOUT}` fired. SSH
      # succeeded but the remote `docker inspect` did not return
      # within its bound. This is distinct from "container is
      # missing": we don't know the container's state — dockerd may
      # be wedged, the NAS filesystem may be stuck, or the daemon
      # may be slow but recoverable. Callers must fail loud rather
      # than collapse into "missing" and race docker rm/run against
      # unknown state (issue #559).
      printf 'probe-timeout\n'
      ;;
    255)
      # SSH transport failure (connection refused, timeout, auth, etc.)
      printf 'ssh-failed\n'
      ;;
    *)
      # SSH succeeded, `timeout` did not fire, docker did not report
      # its documented "missing" rc=1, and no other classified code
      # matched. Common cases:
      #   rc=125  `timeout` itself errored (bad options, memory)
      #   rc=126  command found but not executable (permissions,
      #           broken symlink, ContainerManager package damage)
      #   rc=127  command not found (${NAS_DOCKER} path stale after
      #           a package upgrade / uninstall race)
      #   rc=137  SIGKILL — some alternate `timeout` implementations
      #           report overrun this way instead of 124
      #   rc=143  SIGTERM — same as above
      # Emit the numeric rc so the caller can surface it in the
      # error message and the operator has a concrete diagnostic
      # starting point instead of a collapsed "container missing"
      # false-good (issue #588).
      printf 'probe-error:%s\n' "$rc"
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
  probe-timeout)
    cat >&2 <<EOF

ERROR: docker inspect probe on NAS ${NAS_IP} timed out (rc=124)
       during initial container detection. Cannot determine whether
       gatus-sentinel exists; refusing to proceed (Goal 10:
       unknowable state must fail, not pass) (issue #559).

This usually means dockerd is wedged or the NAS filesystem is
stuck. Recovery typically requires restarting Container Manager:

  ssh ${NAS_USER}@${NAS_IP} '/usr/syno/bin/synopkg restart ContainerManager'

See docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md.
EOF
    exit 1
    ;;
  probe-error:*)
    probe_rc="${container_state#probe-error:}"
    cat >&2 <<EOF

ERROR: docker inspect probe on NAS ${NAS_IP} returned an
       unclassified non-zero exit code (rc=${probe_rc}) during
       initial container detection. Cannot determine whether
       gatus-sentinel exists; refusing to proceed (Goal 10:
       unknowable state must fail, not pass) (issues #588, #614).

Common causes for this rc:
  rc=1    Docker CLI failure distinct from "No such container"
          (daemon connection failure — "Cannot connect to the
          Docker daemon", template errors, socket permission
          errors). The captured docker stderr below usually
          names the specific cause (issue #614).
  rc=125  The NAS-side 'timeout' wrapper itself errored (bad
          options, memory pressure).
  rc=126  ${NAS_DOCKER} exists but is not executable (permissions,
          broken symlink, ContainerManager package damage).
  rc=127  ${NAS_DOCKER} not found (Container Manager uninstalled or
          the path is stale after a package upgrade).
  rc=137/143  Some alternate 'timeout' implementations signal an
          overrun as SIGKILL/SIGTERM instead of rc=124; the
          classifier treats these the same as any other
          probe-error (fail loud with rc captured).
  other   Docker CLI reported a failure the classifier does not
          specifically enumerate; the captured docker stderr
          below usually names the cause.

Note: rc=126/127 can also originate locally if the workstation's
ssh binary itself is missing or not executable — in that case
NAS-side diagnostics do not apply. Run 'command -v ssh' on the
workstation to rule this out.
EOF
    captured_stderr="$(last_inspect_stderr)"
    if [[ -n "$captured_stderr" ]]; then
      cat >&2 <<EOF

Captured remote-inspect stderr from the failing probe (may
include docker stderr + any ssh client diagnostics forwarded on
the same stream):
-----BEGIN REMOTE STDERR-----
${captured_stderr}
-----END REMOTE STDERR-----
EOF
    fi
    cat >&2 <<EOF

Diagnostic starting points:

  ssh -v ${NAS_USER}@${NAS_IP} \\
    'timeout ${DOCKER_INSPECT_TIMEOUT} ${NAS_DOCKER} inspect -f "{{.State.Running}}" gatus-sentinel'
  ssh ${NAS_USER}@${NAS_IP} '/usr/syno/bin/synopkg restart ContainerManager'

See docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md.
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
           "timeout ${DOCKER_STOP_TIMEOUT} ${NAS_DOCKER} stop gatus-sentinel"; then
      echo "Graceful stop failed or timed out; escalating to SIGKILL..."
      if ! ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" \
             "timeout ${DOCKER_KILL_TIMEOUT} ${NAS_DOCKER} kill -s SIGKILL gatus-sentinel"; then
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
      probe-timeout)
        cat >&2 <<EOF

ERROR: docker inspect probe on NAS ${NAS_IP} timed out (rc=124)
       during post-stop verification poll. Cannot confirm container
       is gone; refusing to proceed to docker rm/run (Goal 10:
       unknowable state must fail, not pass) (issue #559).

The stop/kill returned success but a subsequent inspect did not
respond within DOCKER_INSPECT_TIMEOUT — this is the DRT-001
daemon-wedge class. Recovery typically requires restarting
Container Manager:

  ssh ${NAS_USER}@${NAS_IP} '/usr/syno/bin/synopkg restart ContainerManager'

See docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md.
EOF
        exit 1 ;;
      probe-error:*)
        probe_rc="${state#probe-error:}"
        cat >&2 <<EOF

ERROR: docker inspect probe on NAS ${NAS_IP} returned an
       unclassified non-zero exit code (rc=${probe_rc}) during
       post-stop verification poll. Cannot confirm container is
       gone; refusing to proceed to docker rm/run (Goal 10:
       unknowable state must fail, not pass) (issues #588, #614).

The stop/kill returned success but a subsequent inspect failed
with an rc that either is not docker's documented "no such
container" case (issue #614 subclassifies rc=1 via the captured
docker stderr) or is one of the other probe-invocation failure
codes. Common causes:
  rc=1    Docker CLI failure distinct from "No such container"
          (daemon connection failure, template errors, socket
          permission errors). The captured docker stderr below
          usually names the specific cause (issue #614).
  rc=125  The NAS-side 'timeout' wrapper itself errored.
  rc=126  ${NAS_DOCKER} exists but is not executable (or the
          workstation's ssh binary itself is not executable).
  rc=127  ${NAS_DOCKER} not found (package upgrade/uninstall race)
          — or the workstation is missing ssh entirely.
  rc=137/143  Alternate 'timeout' impls signalling an overrun; the
          classifier treats these the same as any other
          probe-error (fail loud with rc captured).
  other   Docker CLI reported a failure the classifier does not
          specifically enumerate.
EOF
        captured_stderr="$(last_inspect_stderr)"
        if [[ -n "$captured_stderr" ]]; then
          cat >&2 <<EOF

Captured remote-inspect stderr from the failing probe (may
include docker stderr + any ssh client diagnostics forwarded on
the same stream):
-----BEGIN REMOTE STDERR-----
${captured_stderr}
-----END REMOTE STDERR-----
EOF
        fi
        cat >&2 <<EOF

Diagnostic starting points:

  ssh -v ${NAS_USER}@${NAS_IP} \\
    'timeout ${DOCKER_INSPECT_TIMEOUT} ${NAS_DOCKER} inspect -f "{{.State.Running}}" gatus-sentinel'
  ssh ${NAS_USER}@${NAS_IP} '/usr/syno/bin/synopkg restart ContainerManager'

See docs/reports/sprint-029-drt-001-sentinel-gatus-hang.md.
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
    "timeout ${DOCKER_RM_TIMEOUT} ${NAS_DOCKER} rm -f gatus-sentinel"
fi

# Step 4: start the new container. Bounded for the same reason as rm —
# docker run can wedge against a daemon-state issue, especially during
# image pull or network setup.
echo "Starting fresh gatus-sentinel container..."
ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" "timeout ${DOCKER_RUN_TIMEOUT} ${NAS_DOCKER} run -d \
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
ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" "mkdir -p /volume1/docker/placement-watchdog/lib"
scp "${SSH_OPTS[@]}" -O -q "${REPO_DIR}/framework/scripts/placement-watchdog.sh" "${NAS_USER}@${NAS_IP}:/volume1/docker/placement-watchdog/"
scp "${SSH_OPTS[@]}" -O -q "${REPO_DIR}/framework/scripts/rebalance-cluster.sh" "${NAS_USER}@${NAS_IP}:/volume1/docker/placement-watchdog/"
scp "${SSH_OPTS[@]}" -O -q "$CIDATA_GUARD_LIB" "${NAS_USER}@${NAS_IP}:/volume1/docker/placement-watchdog/lib/"
if ! ssh "${SSH_OPTS[@]}" -n "${NAS_USER}@${NAS_IP}" \
      "cat /volume1/docker/placement-watchdog/lib/cidata-guard.sh" \
      | diff -q - "$CIDATA_GUARD_LIB" >/dev/null; then
  echo "ERROR: NAS copy of cidata-guard.sh does not match the repo copy." >&2
  exit 1
fi
echo "Deployed cidata-guard.sh CIDATA_GUARD_LIB_VERSION=${CIDATA_GUARD_LIB_VERSION}; NAS copy matches repo."

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
echo "Verify: ssh ${NAS_USER}@${NAS_IP} ${NAS_DOCKER} logs gatus-sentinel --tail 20"
echo "Verify watchdog: curl -s http://${NAS_IP}:9200/ | python3 -m json.tool"
