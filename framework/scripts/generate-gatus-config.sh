#!/usr/bin/env bash
# generate-gatus-config.sh — Generate Gatus health check configuration from config.yaml.
#
# Usage: generate-gatus-config.sh [--allow-test-seams] [--] [config.yaml]
#
# Reads site/config.yaml and produces a Gatus YAML config on stdout.
# The output is consumed by OpenTofu (passed to write_files on the Gatus VM).
#
# Idempotent: running twice with the same config.yaml produces identical output.

set -euo pipefail

# --- Issue #718: lock the resolver's test seams out of production ---
#
# Three environment variables steer how the published (prod) source commit is
# resolved, and they exist ONLY so tests can point the resolver at a fixture:
#
#   GATUS_GITHUB_EXPECTED_SOURCE_COMMIT — bypasses the resolver entirely and
#     emits the given SHA verbatim into deployed CIDATA (see the mirror block
#     below).
#   GATUS_SOURCE_REPO_DIR              — redirects which repo prod is resolved
#     from.
#   GATUS_SOURCE_COMMIT_REMOTE         — redirects the remote used by the
#     `ls-remote` fallback in github-publish-lib.sh.
#
# Before #718 every one of them was read straight from the ambient environment,
# so a stale export in the shell that ran a *production* deploy authority
# steered production resolution. #701 patched exactly one caller
# (rebuild-cluster.sh) with a call-site `env -u` scrub; safe-apply.sh (the
# documented workstation data-plane deploy path) and CI build:merge still
# inherited the ambient environment. A caller-side scrub is a check without
# teeth: it defends only the callers that remembered it, and every future
# caller re-opens the hole by default.
#
# The lockout therefore lives HERE, in the single authority every caller already
# goes through, so no caller has to remember to scrub (design-taste principle 2:
# one source of truth; principle 8: a safety input fails closed).
#
# The opt-in is a COMMAND-LINE FLAG, deliberately not another environment
# variable: ambient environment alone must never be able to re-enable the
# seams. A stale export cannot manufacture an argv entry.
GATUS_ALLOW_TEST_SEAMS=0
GATUS_CONFIG_ARG=""
# bash 3.2 (macOS system bash — .claude/rules/platform.md) errors on
# `set -- "${arr[@]}"` for an empty array under `set -u`, so parse into scalars.
GATUS_END_OF_OPTIONS=0
while (( $# > 0 )); do
  if (( GATUS_END_OF_OPTIONS == 1 )); then
    # After `--`, everything is positional — including a config path that
    # begins with `-`, which the pre-#718 `CONFIG="${1:-...}"` contract
    # accepted and which the `-*` arm below would otherwise reject.
    if [[ -n "${GATUS_CONFIG_ARG}" ]]; then
      echo "ERROR: unexpected extra argument: $1 (only one config path is accepted)" >&2
      exit 1
    fi
    GATUS_CONFIG_ARG="$1"
    shift
    continue
  fi
  case "$1" in
    --)
      GATUS_END_OF_OPTIONS=1
      ;;
    --allow-test-seams)
      GATUS_ALLOW_TEST_SEAMS=1
      ;;
    -h|--help)
      echo "Usage: generate-gatus-config.sh [--allow-test-seams] [--] [config.yaml]" >&2
      exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      echo "Usage: generate-gatus-config.sh [--allow-test-seams] [--] [config.yaml]" >&2
      exit 1
      ;;
    *)
      if [[ -n "${GATUS_CONFIG_ARG}" ]]; then
        echo "ERROR: unexpected extra argument: $1 (only one config path is accepted)" >&2
        exit 1
      fi
      GATUS_CONFIG_ARG="$1"
      ;;
  esac
  shift
done

if (( GATUS_ALLOW_TEST_SEAMS == 0 )); then
  # Production path. Clear the three seams before anything reads them, so
  # resolution goes through the internal resolve_gatus_expected_source_commit()
  # and cannot be short-circuited or redirected by these three names. They are
  # shell variables read by a sourced function in this same shell, so `unset` is
  # sufficient and is a no-op when they were never set (safe under `set -u`).
  #
  # SCOPE OF THIS GUARANTEE — deliberately not stated as an absolute. It covers
  # the three GATUS_* seams and nothing else. It does NOT cover git-native
  # environment: the resolver selects its repo with `git -C "${repo_dir}"`
  # (github-publish-lib.sh), and `git -C` does NOT override an ambient GIT_DIR,
  # so an exported GIT_DIR (or GIT_CONFIG_COUNT/GIT_CONFIG_KEY_n redirecting a
  # remote URL) can still choose which repo prod is read from. That is a wider
  # class than #718 and is tracked as its own issue, #915 — do not read this
  # block as a claim that ambient environment can no longer influence the
  # result.
  unset GATUS_GITHUB_EXPECTED_SOURCE_COMMIT
  unset GATUS_SOURCE_REPO_DIR
  unset GATUS_SOURCE_COMMIT_REMOTE
fi

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
CONFIG="${GATUS_CONFIG_ARG:-${REPO_DIR}/site/config.yaml}"
APPS_CONFIG="${REPO_DIR}/site/applications.yaml"
source "${REPO_DIR}/framework/scripts/certbot-cluster.sh"
source "${REPO_DIR}/framework/scripts/github-publish-lib.sh"

if [[ ! -f "$CONFIG" ]]; then
  echo "ERROR: Config file not found: $CONFIG" >&2
  exit 1
fi

# --- Read values from config.yaml ---
# #704: null-guard every endpoint-critical read. mikefarah `yq -r` prints the
# literal string "null" and exits 0 on a missing key, so a config.yaml missing
# (e.g.) `domain` would otherwise silently ship "prod.null" DNS endpoints and
# url:"null" checks — passing the generator's own exit 0 AND the module's
# can(...endpoints[0]) precondition, failing OPEN through both guards. Fail
# closed here, naming the offending key (same pattern #630 added to
# validate-step2.sh). Optional reads keep their `// ""` / `// default` and are
# intentionally NOT guarded (testapp_prod.ip, github.remote_url, publish, acme).
require_config_value() {
  # require_config_value <value> <config-key-for-error-message>
  if [[ -z "$1" || "$1" == "null" ]]; then
    echo "ERROR: ${2} is missing or null in ${CONFIG} — refusing to generate a Gatus config with placeholder endpoints (#704)." >&2
    exit 1
  fi
}

# #708 (follow-up to #704): the app/workstation health *port* comes from
# committed catalog metadata (framework/catalog/<app>/health.yaml), NOT from
# config.yaml, so #704's require_config_value guards did not cover it. A
# mikefarah `yq -r '.port // ""'` on a missing/empty key yields "" at exit 0,
# so an enabled+monitored app with a prod IP but a health.yaml missing `port`
# emitted a malformed portless URL of the shape `https://<ip>:<path>` and
# exited 0. That endpoint is not necessarily endpoints[0], so the gatus module
# `config_guard` precondition (which only checks endpoints[0].url) does not
# catch it either — fail-OPEN through both guards. Once we have decided to emit
# an endpoint (the app/workstation IP is present), the health `port` is a
# required safety input: fail closed, naming the app and the offending
# health.yaml. `path` stays optional (a health check at `/` is valid).
require_health_port() {
  # require_health_port <port-value> <gatus-target-name> <health-file>
  # The port must be a bare positive integer. Reject empty/null (the fail-open
  # placeholder) AND any non-numeric value: a whitespace-only, list, map, bool,
  # or string port all pass `yq -r '.port // ""'` at exit 0 yet produce a
  # malformed URL (e.g. `https://<ip>:/<path>` or `https://<ip>:  /path`).
  # Numeric-only is a deliberate strengthening over #704's require_config_value
  # (which guards non-numeric values like IPs/domains); it is specific to the
  # port domain and is exactly what prevents a malformed endpoint here.
  if [[ -z "$1" || "$1" == "null" || ! "$1" =~ ^[0-9]+$ ]]; then
    echo "ERROR: health port (.port) is missing, null, or non-numeric in ${3} for gatus target '${2}' — refusing to emit a malformed Gatus endpoint (#708)." >&2
    exit 1
  fi
}

DOMAIN=$(yq -r '.domain' "$CONFIG"); require_config_value "$DOMAIN" '.domain'
DNS_DOMAIN="prod.${DOMAIN}"
DNS1_IP=$(yq -r '.vms.dns1_prod.ip' "$CONFIG"); require_config_value "$DNS1_IP" '.vms.dns1_prod.ip'
DNS2_IP=$(yq -r '.vms.dns2_prod.ip' "$CONFIG"); require_config_value "$DNS2_IP" '.vms.dns2_prod.ip'
VAULT_IP=$(yq -r '.vms.vault_prod.ip' "$CONFIG"); require_config_value "$VAULT_IP" '.vms.vault_prod.ip'
PBS_IP=$(yq -r '.vms.pbs.ip' "$CONFIG"); require_config_value "$PBS_IP" '.vms.pbs.ip'
GITLAB_IP=$(yq -r '.vms.gitlab.ip' "$CONFIG"); require_config_value "$GITLAB_IP" '.vms.gitlab.ip'
GATUS_IP=$(yq -r '.vms.gatus.ip' "$CONFIG"); require_config_value "$GATUS_IP" '.vms.gatus.ip'
TESTAPP_PROD_IP=$(yq -r '.vms.testapp_prod.ip // ""' "$CONFIG")
NAS_IP=$(yq -r '.nas.ip' "$CONFIG"); require_config_value "$NAS_IP" '.nas.ip'
HEALTH_PORT=$(yq -r '.replication.health_port' "$CONFIG"); require_config_value "$HEALTH_PORT" '.replication.health_port'
STORAGE_POOL=$(yq -r '.proxmox.storage_pool' "$CONFIG"); require_config_value "$STORAGE_POOL" '.proxmox.storage_pool'
ACME_MODE=$(yq -r '.acme // "production"' "$CONFIG")
CERT_GROUP="$(certbot_cluster_gatus_cert_group)"

SMTP_HOST=$(yq -r '.email.smtp_host' "$CONFIG"); require_config_value "$SMTP_HOST" '.email.smtp_host'
SMTP_PORT=$(yq -r '.email.smtp_port' "$CONFIG"); require_config_value "$SMTP_PORT" '.email.smtp_port'
EMAIL_FROM="gatus@${DOMAIN}"
EMAIL_TO=$(yq -r '.email.to' "$CONFIG"); require_config_value "$EMAIL_TO" '.email.to'
GITHUB_REMOTE_URL=$(yq -r '.github.remote_url // ""' "$CONFIG")
PUBLISH_GITHUB_ENABLED=$(yq -r '.publish.github.enabled // false' "$CONFIG")
GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="${GATUS_GITHUB_EXPECTED_SOURCE_COMMIT:-}"

# Issue #528: derive the expected source commit from the repo when the
# caller does not pass one. Previously, .gitlab-ci.yml set this env var
# to $CI_COMMIT_SHA (the pipeline's branch tip) while rebuild-cluster.sh
# resolved gitlab/prod's tip — the two resolvers disagreed and dev
# pipelines churned gatus CIDATA every run. Now both call sites converge
# on resolve_gatus_expected_source_commit() (github-publish-lib.sh),
# which always returns prod's tip. #718: the env var survives only as a
# test seam behind --allow-test-seams; without that flag it was already
# cleared at the top of this script, so this branch is unconditional on
# any production path. Only resolve when publishing is opted in —
# downstream adopters with publish disabled must not fail on a missing
# prod branch (issue #294 opt-in semantics preserved).
if [[ -z "${GATUS_GITHUB_EXPECTED_SOURCE_COMMIT}" && "${PUBLISH_GITHUB_ENABLED}" == "true" ]]; then
  RESOLVER_REPO_DIR="${GATUS_SOURCE_REPO_DIR:-${REPO_DIR}}"
  if ! GATUS_GITHUB_EXPECTED_SOURCE_COMMIT="$(resolve_gatus_expected_source_commit "${RESOLVER_REPO_DIR}")"; then
    echo "ERROR: publish.github.enabled=true but could not resolve the published (prod) commit SHA." >&2
    # #718: do NOT advise setting GATUS_GITHUB_EXPECTED_SOURCE_COMMIT here. On a
    # production invocation it is cleared before it is read, so the advice would
    # be inert; fetching prod is the only real remedy.
    echo "  Fetch prod (git fetch origin prod) so the published tip is resolvable." >&2
    exit 1
  fi
fi

# Read node management IPs. #704: guard the count too — `yq -r '.nodes | length'`
# returns 0 for a missing/null/empty `.nodes`, which would skip the Proxmox and
# replication loops entirely and silently ship a config with no node endpoints
# (fail-open on an incomplete config). Every real cluster has ≥1 node.
NODE_COUNT=$(yq -r '.nodes | length' "$CONFIG")
if ! [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] || (( NODE_COUNT < 1 )); then
  echo "ERROR: .nodes is missing, null, or empty in ${CONFIG} — refusing to generate a Gatus config with no Proxmox/replication node endpoints (#704)." >&2
  exit 1
fi

cat <<EOF
# Gatus configuration — generated by generate-gatus-config.sh
# Source: site/config.yaml
# Do not edit manually — regenerate from config.yaml.

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
EOF

if [[ -n "${GATUS_GITHUB_EXPECTED_SOURCE_COMMIT}" && "${PUBLISH_GITHUB_ENABLED}" == "true" ]]; then
  # Issue #294: only emit the GitHub mirror endpoint when publishing is opted in.
  # GATUS_GITHUB_EXPECTED_SOURCE_COMMIT is a test-only override, and since #718
  # it is unreachable without --allow-test-seams: on every production path the
  # value here came from the internal resolver above. Gating on
  # PUBLISH_GITHUB_ENABLED (not the env-var alone) is still required: a test
  # must not force emission for downstream adopters with
  # publishing disabled, where the URL would be empty and
  # github_remote_to_raw_metadata_url would crash the script under set -e.
  GITHUB_METADATA_URL="$(github_remote_to_raw_metadata_url "${GITHUB_REMOTE_URL}")"
  cat <<EOF
  # --- GitHub Publish Mirror ---
  - name: github-mirror-main
    group: publishing
    url: "${GITHUB_METADATA_URL}"
    conditions:
      - "[STATUS] == 200"
      # Issue #301: Gatus 5.x condition parser keeps quotes as part of the
      # string literal, so a quoted RHS never matches the jsonpath-resolved
      # LHS (which has no surrounding quotes). Compare against the bare
      # SHA — same convention as other [BODY].field == identifier checks
      # in this file (e.g. [BODY].status == healthy).
      - "[BODY].source_commit == ${GATUS_GITHUB_EXPECTED_SOURCE_COMMIT}"
    interval: 10m
    alerts:
      - type: email
        failure-threshold: 3
        success-threshold: 2

EOF
fi

cat <<EOF
  # --- DNS Health ---
  - name: dns1-prod
    group: dns
    url: "${DNS1_IP}"
    dns:
      query-name: "vault.${DNS_DOMAIN}"
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
      query-name: "vault.${DNS_DOMAIN}"
      query-type: "A"
    conditions:
      - "[DNS_RCODE] == NOERROR"
    interval: 30s
    alerts:
      - type: email

  # --- Vault Health ---
  - name: vault-prod
    group: secrets
    url: "https://${VAULT_IP}:8200/v1/sys/health"
    client:
      insecure: true
    conditions:
      - "[STATUS] == 200"
    interval: 30s
    alerts:
      - type: email

EOF

if [[ "${ACME_MODE}" == "production" ]]; then
  cat <<EOF
  # --- Certificate Health (production ACME only) ---
EOF
  # #717: the cert-monitor records used to be fed to the loop below through a
  # process substitution (`done < <(certbot_cluster_gatus_cert_monitor_records
  # ...)`). A process substitution does NOT propagate the producer's exit
  # status to the parent, not even under `set -euo pipefail` — the parent only
  # ever sees the exit status of `read`. So a producer that died partway (yq
  # missing, unreadable config, an internal errexit abort, or a future
  # fail-closed `die`) left this script consuming whatever partial output had
  # already been written and then exiting 0 with a Gatus config missing some or
  # all of its certificate-expiry endpoints. Nothing downstream catches that:
  # the gatus module's `terraform_data.config_guard` precondition
  # (framework/tofu/modules/gatus/main.tf) only inspects endpoints[0].url, and
  # endpoints[0] is never a cert endpoint — it is github-mirror-main when
  # publishing is opted in (emitted above) and dns1-prod otherwise. So a
  # cert-monitor-less config passes the generator's exit 0 AND the module
  # precondition, failing OPEN through both guards. That is the same class
  # #704 closed for the node loop and #708 closed for health ports.
  #
  # Capture first, then branch on the producer's own exit code. Two details
  # are load-bearing and neither is obvious:
  #
  #   * `set -e` INSIDE the command substitution is required. Bash honors
  #     errexit inside a process substitution `<(...)` but NOT inside a
  #     command substitution `$(...)`, so a plain `VAR="$(producer)"` lets an
  #     internal failure fall through: the producer keeps running past it and
  #     returns 0, which would make both guards below unreachable and leave
  #     exactly the #717 fail-open in place while looking fixed. Re-arming
  #     errexit in the subshell restores the abort-on-internal-failure the
  #     process substitution had, and turns it into a status the parent can
  #     see. (The house form at line ~114, `if ! VAR="$(...)"`, has the same
  #     blind spot — errexit suppression in an `if` condition is inherited by
  #     the subshell — so it is not an alternative here.)
  #
  #     Bounded claim: this recovers failures errexit can see. It does NOT
  #     recover a failure inside one of the producer's OWN nested process
  #     substitutions — those still return 0 to the producer, which then
  #     returns 0 to us having emitted a short list. A corrupt
  #     site/applications.yaml reproduces it. That residual is #907, and it
  #     cannot be closed from this file: the producer lives in the shared Nix
  #     image closure (flake.nix `sharedWantedPaths`).
  #   * `set +e` / `rc=$?` / `set -e` around the assignment is the
  #     .claude/rules/platform.md form for keeping the actual exit code:
  #     `|| true` would flatten it to 0, and letting errexit kill the parent
  #     would abort with no diagnostic (BASH_LINENO in an EXIT trap reports
  #     the trap's context, not the failing line).
  #
  # Only stdout is captured, so the producer's own stderr still reaches the
  # operator's log.
  set +e
  CERT_MONITOR_RECORDS="$(set -e; certbot_cluster_gatus_cert_monitor_records "${CONFIG}" "${APPS_CONFIG}" "${REPO_DIR}")"
  CERT_MONITOR_RC=$?
  set -e
  if (( CERT_MONITOR_RC != 0 )); then
    echo "ERROR: certbot_cluster_gatus_cert_monitor_records failed (exit ${CERT_MONITOR_RC}) — refusing to generate a Gatus config that would silently omit certificate-expiry endpoints (#717)." >&2
    exit 1
  fi
  # Under `acme: production` the record set can never legitimately be empty:
  # certbot_cluster_gatus_cert_monitor_records emits cert-vault-prod from
  # `.vms.vault_prod.ip` (framework/scripts/certbot-cluster.sh), and this
  # script has already
  # refused to continue unless that same key is present and non-null
  # (require_config_value at line ~83). An empty capture therefore means the
  # producer stopped emitting without reporting failure — fail closed rather
  # than ship a certificates group with nothing in it.
  if [[ -z "${CERT_MONITOR_RECORDS}" ]]; then
    echo "ERROR: certbot_cluster_gatus_cert_monitor_records produced no records under acme: production — at minimum cert-vault-prod was expected, from the .vms.vault_prod.ip this script already required. Refusing to generate a Gatus config with an empty '${CERT_GROUP}' group (#717)." >&2
    exit 1
  fi
  while IFS=$'\t' read -r endpoint_name _ endpoint_ip endpoint_port _; do
    [[ -z "${endpoint_name}" ]] && continue
    cat <<EOF
  - name: ${endpoint_name}
    group: ${CERT_GROUP}
    url: "https://${endpoint_ip}:${endpoint_port}"
    client:
      insecure: true
    conditions:
      - "[CERTIFICATE_EXPIRATION] > 14d"
    interval: 1h
    alerts:
      - type: email
        failure-threshold: 1

EOF
  done <<< "${CERT_MONITOR_RECORDS}"
else
  cat <<EOF
  # Certificate checks disabled (acme: ${ACME_MODE})
EOF
fi

cat <<EOF

  # --- PBS Health ---
  - name: pbs
    group: backups
    url: "https://${PBS_IP}:8007"
    client:
      insecure: true
    conditions:
      - "[STATUS] < 500"
    interval: 60s
    alerts:
      - type: email

  # --- GitLab Health ---
  - name: gitlab
    group: services
    url: "https://${GITLAB_IP}"
    client:
      insecure: true
    conditions:
      - "[STATUS] < 500"
    interval: 60s
    alerts:
      - type: email

  # --- Testapp Health ---
EOF

if [[ -n "$TESTAPP_PROD_IP" ]]; then
  cat <<EOF
  - name: testapp-prod
    group: applications
    url: "http://${TESTAPP_PROD_IP}:8080/"
    conditions:
      - "[STATUS] == 200"
      - "[BODY].status == healthy"
    interval: 60s
    alerts:
      - type: email

EOF
fi

# --- Catalog Application Health (from config.yaml applications block) ---
# Health port/path come from the catalog module's metadata.yaml, not config.yaml.
APP_NAMES=$(yq -r '.applications // {} | to_entries[] | select(.value.enabled == true and .value.monitor == true) | .key' "$APPS_CONFIG" 2>/dev/null || true)
for APP in $APP_NAMES; do
  if [[ "$APP" == "workstation" ]]; then
    continue
  fi

  APP_IP=$(yq -r ".applications.${APP}.environments.prod.ip // \"\"" "$APPS_CONFIG")
  HEALTH_FILE="${REPO_DIR}/framework/catalog/${APP}/health.yaml"
  # `|| true`: a MISSING health.yaml file makes yq exit non-zero, which under
  # `set -e` would abort here (silently, stderr is /dev/null'd) before the
  # drop-vs-emit decision below — wrongly aborting a dev-only app instead of
  # dropping it, and skipping the require_health_port diagnostic when an
  # endpoint IS due. Fall through with an empty value so the guard/drop logic
  # runs. (Matches the house-style `|| true` on the APP_IP read above.)
  HEALTH_PORT_APP=$(yq -r '.port // ""' "$HEALTH_FILE" 2>/dev/null || true)
  HEALTH_PATH_APP=$(yq -r '.path // ""' "$HEALTH_FILE" 2>/dev/null || true)
  # A missing prod IP legitimately DROPS the endpoint: an app can be
  # enabled+monitored yet deployed only to dev, and the gatus config is
  # prod-only. But once the prod IP IS present we are committed to emitting an
  # endpoint, so the health port is required (#708) rather than fail-open.
  if [[ -n "$APP_IP" && "$APP_IP" != "null" ]]; then
    require_health_port "$HEALTH_PORT_APP" "$APP" "$HEALTH_FILE"
    cat <<EOF
  # --- ${APP} Health ---
  - name: ${APP}-prod
    group: applications
    url: "https://${APP_IP}:${HEALTH_PORT_APP}${HEALTH_PATH_APP}"
    client:
      insecure: true
    conditions:
      - "[STATUS] == 200"
    interval: 60s
    alerts:
      - type: email

EOF
  fi

  # The co-hosted cluster-dashboard is synthesized on InfluxDB's VM, so it
  # shares InfluxDB's prod IP. Gate on that IP being present for the same
  # reason as the app endpoint above (a dev-only influxdb emits neither), and
  # once committed require the dashboard health port (#708) instead of the old
  # `if [[ -n "$DASHBOARD_HEALTH_PORT" ]]` which silently DROPPED the dashboard
  # check on a missing/empty port (fail-open, and — like the app URL — the
  # portless URL would otherwise be `https://<ip>:<path>`).
  if [[ "$APP" == "influxdb" && -n "$APP_IP" && "$APP_IP" != "null" ]]; then
    DASHBOARD_HEALTH_FILE="${REPO_DIR}/framework/catalog/cluster-dashboard/health.yaml"
    DASHBOARD_HEALTH_PORT=$(yq -r '.port // ""' "$DASHBOARD_HEALTH_FILE" 2>/dev/null || true)
    DASHBOARD_HEALTH_PATH=$(yq -r '.path // ""' "$DASHBOARD_HEALTH_FILE" 2>/dev/null || true)
    # Trade-off: keep the app-level health check on InfluxDB's real backend
    # surface (:8086/health) and synthesize a second check for the co-hosted
    # dashboard. The nested cluster-dashboard catalog metadata is otherwise
    # invisible to the app-health inventory that Gatus consumes.
    require_health_port "$DASHBOARD_HEALTH_PORT" "cluster-dashboard" "$DASHBOARD_HEALTH_FILE"
    cat <<EOF
  # --- ${APP} Dashboard Health ---
  - name: ${APP}-dashboard-prod
    group: applications
    url: "https://${APP_IP}:${DASHBOARD_HEALTH_PORT}${DASHBOARD_HEALTH_PATH}"
    client:
      insecure: true
    conditions:
      - "[STATUS] == 200"
    interval: 60s
    alerts:
      - type: email

EOF
  fi
done

WORKSTATION_ENABLED=$(yq -r '.applications.workstation.enabled // false' "$APPS_CONFIG" 2>/dev/null || true)
if [[ "$WORKSTATION_ENABLED" == "true" ]]; then
  WORKSTATION_HEALTH_FILE="${REPO_DIR}/framework/catalog/workstation/health.yaml"
  WORKSTATION_HEALTH_PORT=$(yq -r '.port // ""' "$WORKSTATION_HEALTH_FILE" 2>/dev/null || true)
  WORKSTATION_HEALTH_PATH=$(yq -r '.path // ""' "$WORKSTATION_HEALTH_FILE" 2>/dev/null || true)

  for WORK_ENV in prod dev; do
    if [[ "$WORK_ENV" == "dev" ]]; then
      WORK_IP=$(yq -r '.applications.workstation.environments.dev.mgmt_nic.ip // ""' "$APPS_CONFIG" 2>/dev/null || true)
    else
      WORK_IP=$(yq -r ".applications.workstation.environments.${WORK_ENV}.ip // \"\"" "$APPS_CONFIG" 2>/dev/null || true)
    fi

    [[ -z "$WORK_IP" || "$WORK_IP" == "null" ]] && continue

    # A per-env workstation with no IP is legitimately skipped above; once an IP
    # is present we are committed to emitting the HTTPS health endpoint, so the
    # workstation health port is required (#708) rather than emitting a portless
    # `https://<ip>:<path>` URL. (The tcp:// SSH check below uses a literal :22,
    # so it needs no port guard.)
    require_health_port "$WORKSTATION_HEALTH_PORT" "workstation" "$WORKSTATION_HEALTH_FILE"

    cat <<EOF
  # --- Workstation ${WORK_ENV} Health ---
  - name: workstation-${WORK_ENV}
    group: workstations
    url: "https://${WORK_IP}:${WORKSTATION_HEALTH_PORT}${WORKSTATION_HEALTH_PATH}"
    client:
      insecure: true
    conditions:
      - "[STATUS] == 200"
    interval: 60s
    alerts:
      - type: email

  - name: workstation-ssh-${WORK_ENV}
    group: workstations
    url: "tcp://${WORK_IP}:22"
    conditions:
      - "[CONNECTED] == true"
    interval: 60s
    alerts:
      - type: email

EOF
  done
fi

cat <<EOF
  # --- Proxmox Cluster Health ---
EOF

for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG"); require_config_value "$NODE_NAME" ".nodes[${i}].name"
  NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG"); require_config_value "$NODE_IP" ".nodes[${i}].mgmt_ip"
  cat <<EOF
  - name: ${NODE_NAME}
    group: proxmox
    url: "https://${NODE_IP}:8006"
    client:
      insecure: true
    conditions:
      - "[STATUS] < 500"
    interval: 30s
    alerts:
      - type: email

EOF
done

# --- Replication Mesh Health ---
for (( i=0; i<NODE_COUNT; i++ )); do
  NODE_NAME=$(yq -r ".nodes[${i}].name" "$CONFIG"); require_config_value "$NODE_NAME" ".nodes[${i}].name"
  NODE_IP=$(yq -r ".nodes[${i}].mgmt_ip" "$CONFIG"); require_config_value "$NODE_IP" ".nodes[${i}].mgmt_ip"
  cat <<EOF
  - name: repl-${NODE_NAME}
    group: replication
    url: "http://${NODE_IP}:${HEALTH_PORT}/"
    conditions:
      - "[STATUS] == 200"
      - "[BODY].replication_stale == false"
      - "[BODY].zfs_pools.${STORAGE_POOL} == healthy"
    interval: 60s
    alerts:
      - type: email

EOF
done

cat <<EOF
  # --- NAS Reachability ---
  - name: nas
    group: infrastructure
    url: "tcp://${NAS_IP}:5000"
    conditions:
      - "[CONNECTED] == true"
    interval: 60s
    alerts:
      - type: email

  # --- Placement Health (off-cluster watchdog on NAS) ---
  - name: placement-health
    group: cluster
    url: "http://${NAS_IP}:9200/"
    conditions:
      - "[STATUS] == 200"
      - "[BODY].placement_healthy == true"
    interval: 5m
    alerts:
      - type: email

  # --- Sentinel Gatus (Mutual Monitoring) ---
  - name: sentinel-gatus
    group: monitoring
    url: "http://${NAS_IP}:8080/api/v1/endpoints/statuses"
    conditions:
      - "[STATUS] == 200"
    interval: 60s
    alerts:
      - type: email
EOF
