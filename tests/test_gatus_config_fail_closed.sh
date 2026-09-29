#!/usr/bin/env bash
# test_gatus_config_fail_closed.sh — the gatus module must fail closed at PLAN
# time on an empty / zero-endpoint monitoring config (#690), while keeping the
# artifact-absent `tofu validate` stage green.
#
# Incident (DRT-005, 2026-07-21): site/gatus/config.yaml is a generated artifact
# (generate-gatus-config.sh) that is NOT in git. When absent, the root module's
# `fileexists(...) ? file(...) : ""` ternary passed gatus_config="", which
# silently deployed an EMPTY prod monitoring config; gatus crash-looped
# ("configuration should contain at least 1 endpoint").
#
# The fix keeps the fileexists() ternary at the call site — a bare file() would
# redden the pre-build `validate:plan` CI stage where the artifact is absent —
# and adds a terraform_data precondition inside the gatus module that rejects an
# empty / zero-endpoint config. Preconditions evaluate at plan/apply, NOT at
# validate, so a real deploy fails loudly while validate stays green.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib/runner.sh"

GATUS_MAIN="${REPO_ROOT}/framework/tofu/modules/gatus/main.tf"
ROOT_MAIN="${REPO_ROOT}/framework/tofu/root/main.tf"

# --- Structural ratchets (CI-enforced; no tofu needed) --------------------

test_start "GCF.1" "gatus module declares a terraform_data.config_guard resource"
if grep -Eq 'resource[[:space:]]+"terraform_data"[[:space:]]+"config_guard"' "$GATUS_MAIN"; then
  test_pass "terraform_data.config_guard resource is present"
else
  test_fail "terraform_data.config_guard resource is missing from gatus/main.tf"
fi

test_start "GCF.2" "config_guard has a usable-endpoint precondition (fail-closed)"
# The precondition must reject any config whose first endpoint lacks a non-empty,
# non-placeholder url. #704 strengthened this from can(...endpoints[0])
# (fail-OPEN on endpoints:[null]/[x]/[{}]) to a try() that checks
# length(endpoints[0].url) > 0 AND != "null". Assert the load-bearing tokens on
# the condition line so a weakening — dropping the yamldecode, the [0].url reach,
# the length()>0 non-empty check, or the != "null" placeholder check — trips the
# ratchet.
if grep -Eq 'condition[[:space:]]*=.*length\(yamldecode\(var\.gatus_config\)\.endpoints\[0\]\.url\)[[:space:]]*>[[:space:]]*0' "$GATUS_MAIN" &&
   grep -Eq 'endpoints\[0\]\.url[[:space:]]*!=[[:space:]]*"null"' "$GATUS_MAIN" &&
   grep -Eq 'precondition[[:space:]]*\{' "$GATUS_MAIN"; then
  test_pass "precondition asserts length(...endpoints[0].url) > 0 && != \"null\""
else
  test_fail "config_guard precondition endpoint check is missing or weakened"
fi

test_start "GCF.3" "precondition error_message names the generator and the issues"
if grep -Fq 'generate-gatus-config.sh' "$GATUS_MAIN" &&
   grep -Fq '#690' "$GATUS_MAIN" &&
   grep -Fq '#704' "$GATUS_MAIN"; then
  test_pass "error_message points at generate-gatus-config.sh and #690/#704"
else
  test_fail "config_guard error_message does not name the generator / issues"
fi

test_start "GCF.3b" "gatus VM module depends_on config_guard (covers targeted plans)"
# Without this edge, a targeted plan of the inner consumer module
# (-target=module.gatus.module.gatus...) skips the sibling config_guard and its
# precondition, so an empty config could still reach the VM's write_files.
if grep -Eq 'depends_on[[:space:]]*=[[:space:]]*\[[[:space:]]*terraform_data\.config_guard[[:space:]]*\]' "$GATUS_MAIN"; then
  test_pass "the gatus VM module depends_on terraform_data.config_guard"
else
  test_fail "the gatus VM module does not depends_on config_guard — targeted plans could skip the guard"
fi

test_start "GCF.4" "root call site keeps the fileexists() ternary (validate-safe)"
# A bare file() at the call site errors during `tofu validate` when the artifact
# is absent (pre-build validate:plan stage). The ternary keeps validate green;
# the module precondition is what enforces fail-closed at plan time. Guard the
# ternary so a well-meaning "simplification" cannot reopen the validate breakage.
if grep -Eq 'gatus_config[[:space:]]*=[[:space:]]*fileexists\(' "$ROOT_MAIN"; then
  test_pass "gatus_config call site uses the fileexists() ternary"
else
  test_fail "gatus_config call site no longer uses fileexists() — validate stage would break"
fi

# --- Live behavioral check (skips if tofu is unavailable) -----------------
# Proves the two properties end to end using the REAL condition expression
# extracted from the module, on a terraform_data resource (no proxmox provider
# needed): (a) `tofu validate` passes even with an empty config; (b) `tofu plan`
# FAILS on an empty config and SUCCEEDS on a config with endpoints.

test_start "GCF.5" "precondition passes validate but fails plan on an empty config"
if ! command -v tofu >/dev/null 2>&1; then
  test_skip "tofu not installed in this sandbox (structural ratchets GCF.1-4 cover the wiring)"
else
  # Extract the real condition expression verbatim (everything after the first '=').
  COND_LINE="$(grep -E 'condition[[:space:]]*=.*yamldecode\(var\.gatus_config\)\.endpoints' "$GATUS_MAIN" | head -1)"
  COND_EXPR="${COND_LINE#*= }"
  if [[ -z "$COND_EXPR" ]]; then
    test_skip "could not extract the precondition expression (GCF.2 already asserts its presence)"
  else
    SCRATCH="$(mktemp -d)"
    cat > "${SCRATCH}/main.tf" <<EOF
variable "gatus_config" {
  type = string
}
resource "terraform_data" "config_guard" {
  input = sha256(var.gatus_config)
  lifecycle {
    precondition {
      condition     = ${COND_EXPR}
      error_message = "gatus_config has no endpoints (#690)."
    }
  }
}
EOF
    printf 'gatus_config = "endpoints:\\n  - name: x\\n    url: https://x\\n"\n' > "${SCRATCH}/good.tfvars"
    # tofu plan is EXPECTED to fail on the empty config, so run all tofu calls
    # with set -e disabled and capture each exit code explicitly.
    set +e
    init_out="$(cd "${SCRATCH}" && tofu init -backend=false -input=false 2>&1)"; init_rc=$?
    # validate must PASS with no config supplied (mirrors the artifact-absent
    # validate:plan stage; validate does not evaluate resource preconditions).
    val_out="$(cd "${SCRATCH}" && tofu validate 2>&1)"; val_rc=$?
    # plan with an empty config must FAIL closed on the precondition.
    plan_empty_out="$(cd "${SCRATCH}" && tofu plan -input=false -var 'gatus_config=' 2>&1)"; plan_empty_rc=$?
    # plan with a real endpoints config must SUCCEED.
    plan_good_out="$(cd "${SCRATCH}" && tofu plan -input=false -var-file=good.tfvars 2>&1)"; plan_good_rc=$?
    set -e
    rm -rf "${SCRATCH}"

    if [[ "$init_rc" -eq 0 && "$val_rc" -eq 0 && "$plan_empty_rc" -ne 0 && "$plan_good_rc" -eq 0 ]] &&
       grep -Fq 'endpoints' <<< "$plan_empty_out"; then
      test_pass "empty config: validate green, plan red; endpoints config: plan green"
    elif [[ "$init_out" == *"Failed to resolve provider"* || "$init_out" == *"bind: operation not permitted"* ]]; then
      test_skip "tofu init could not complete in this sandbox"
    else
      test_fail "precondition did not exhibit validate-green / plan-fail-closed behavior"
      printf 'init_rc=%s val_rc=%s plan_empty_rc=%s plan_good_rc=%s\nval:\n%s\nplan_empty:\n%s\nplan_good:\n%s\n' \
        "$init_rc" "$val_rc" "$plan_empty_rc" "$plan_good_rc" \
        "$val_out" "$plan_empty_out" "$plan_good_out" >&2
    fi
  fi
fi

# --- Generator fail-closed on malformed config.yaml (#704) ----------------
# The generator is the PRIMARY #704 fix: mikefarah `yq -r` prints "null" and
# exits 0 on a missing key, so before the null-guards a config.yaml missing
# `.domain` produced "prod.null" endpoints and exited 0. Assert the generator
# now fails closed and names the offending key. No tofu needed; always runs.

test_start "GCF.6" "generator fails closed when config.yaml is missing .domain (#704)"
GENERATOR="${REPO_ROOT}/framework/scripts/generate-gatus-config.sh"
BAD_CONFIG="$(mktemp)"
# Minimal malformed config: no .domain. publish/github omitted so the generator
# takes no network path (publish defaults to false); the .domain guard is the
# first endpoint-critical read and must fire before any endpoint work.
cat > "$BAD_CONFIG" <<'YAML'
vms: {}
nas:
  ip: "10.0.0.1"
YAML
set +e
gen_out="$("$GENERATOR" "$BAD_CONFIG" 2>&1)"; gen_rc=$?
set -e
rm -f "$BAD_CONFIG"
if [[ "$gen_rc" -ne 0 ]] && grep -Fq '.domain' <<< "$gen_out"; then
  test_pass "generator exits non-zero and names the missing .domain key"
else
  test_fail "generator did not fail closed on a config.yaml missing .domain"
  printf 'gen_rc=%s\ngen_out:\n%s\n' "$gen_rc" "$gen_out" >&2
fi

test_start "GCF.8" "generator fails closed when config.yaml has no .nodes (#704)"
# A config with all scalar keys but no `.nodes` would make NODE_COUNT=0 and skip
# the Proxmox/replication loops, silently shipping a config with no node
# endpoints. Assert the count guard fails closed and names .nodes.
NODELESS_CONFIG="$(mktemp)"
cat > "$NODELESS_CONFIG" <<'YAML'
domain: example.com
vms:
  dns1_prod: {ip: "10.0.0.1"}
  dns2_prod: {ip: "10.0.0.2"}
  vault_prod: {ip: "10.0.0.3"}
  pbs: {ip: "10.0.0.4"}
  gitlab: {ip: "10.0.0.5"}
  gatus: {ip: "10.0.0.6"}
nas: {ip: "10.0.0.7"}
replication: {health_port: 9200}
proxmox: {storage_pool: vmstore}
email: {smtp_host: h, smtp_port: 25, to: "a@b.c"}
YAML
set +e
gen_out="$("$GENERATOR" "$NODELESS_CONFIG" 2>&1)"; gen_rc=$?
set -e
rm -f "$NODELESS_CONFIG"
if [[ "$gen_rc" -ne 0 ]] && grep -Fq '.nodes' <<< "$gen_out"; then
  test_pass "generator exits non-zero and names the missing .nodes key"
else
  test_fail "generator did not fail closed on a config.yaml with no .nodes"
  printf 'gen_rc=%s\ngen_out:\n%s\n' "$gen_rc" "$gen_out" >&2
fi

# --- Precondition fails closed on malformed NON-EMPTY endpoint lists (#704) -
# These are the cases the pre-#704 can(...endpoints[0]) guard passed (fail-open):
# endpoints:[null], endpoints:[x] (scalar), endpoints:[{}]. The strengthened
# guard must also reject a first endpoint whose url is null / "" / "null"
# (the literal placeholder a mikefarah `yq -r` on a missing key produces), while
# still accepting a real endpoint that has a non-empty url.

test_start "GCF.7" "precondition rejects malformed non-empty endpoint lists (#704)"
if ! command -v tofu >/dev/null 2>&1; then
  test_skip "tofu not installed in this sandbox (GCF.2 structurally asserts the strengthened condition)"
else
  COND_LINE="$(grep -E 'condition[[:space:]]*=.*yamldecode\(var\.gatus_config\)\.endpoints' "$GATUS_MAIN" | head -1)"
  COND_EXPR="${COND_LINE#*= }"
  if [[ -z "$COND_EXPR" ]]; then
    test_skip "could not extract the precondition expression (GCF.2 already asserts its presence)"
  else
    SCRATCH="$(mktemp -d)"
    cat > "${SCRATCH}/main.tf" <<EOF
variable "gatus_config" {
  type = string
}
resource "terraform_data" "config_guard" {
  input = sha256(var.gatus_config)
  lifecycle {
    precondition {
      condition     = ${COND_EXPR}
      error_message = "gatus_config has no usable endpoints (#704)."
    }
  }
}
EOF
    # Each malformed non-empty list, as a gatus_config string value.
    printf 'gatus_config = "endpoints:\\n  - null\\n"\n'  > "${SCRATCH}/null.tfvars"
    printf 'gatus_config = "endpoints:\\n  - x\\n"\n'     > "${SCRATCH}/scalar.tfvars"
    printf 'gatus_config = "endpoints:\\n  - {}\\n"\n'    > "${SCRATCH}/emptyobj.tfvars"
    # First endpoint present but with an unusable url: null / empty / "null".
    printf 'gatus_config = "endpoints:\\n  - name: n\\n    url: null\\n"\n'   > "${SCRATCH}/urlnull.tfvars"
    printf 'gatus_config = "endpoints:\\n  - name: n\\n    url: \\"\\"\\n"\n' > "${SCRATCH}/urlempty.tfvars"
    printf 'gatus_config = "endpoints:\\n  - name: n\\n    url: \\"null\\"\\n"\n' > "${SCRATCH}/urlnullstr.tfvars"
    # A well-formed endpoint (has a real url) must still be ACCEPTED.
    printf 'gatus_config = "endpoints:\\n  - name: x\\n    url: https://x\\n"\n' > "${SCRATCH}/good.tfvars"
    set +e
    init_out="$(cd "${SCRATCH}" && tofu init -backend=false -input=false 2>&1)"; init_rc=$?
    reject_all_ok=1
    for tv in null scalar emptyobj urlnull urlempty urlnullstr; do
      (cd "${SCRATCH}" && tofu plan -input=false -var-file="${tv}.tfvars" >/dev/null 2>&1)
      [[ $? -eq 0 ]] && { reject_all_ok=0; echo "  UNEXPECTED ACCEPT: ${tv}" >&2; }
    done
    plan_good_rc=1;  (cd "${SCRATCH}" && tofu plan -input=false -var-file=good.tfvars >/dev/null 2>&1); plan_good_rc=$?
    set -e
    rm -rf "${SCRATCH}"
    if [[ "$init_rc" -eq 0 && "$reject_all_ok" -eq 1 && "$plan_good_rc" -eq 0 ]]; then
      test_pass "[null]/[x]/[{}] and url:null/\"\"/\"null\" all fail plan; a real url passes"
    elif [[ "$init_out" == *"Failed to resolve provider"* || "$init_out" == *"bind: operation not permitted"* ]]; then
      test_skip "tofu init could not complete in this sandbox"
    else
      test_fail "strengthened precondition did not reject all malformed non-empty configs"
      printf 'init_rc=%s reject_all_ok=%s good_rc=%s\n' "$init_rc" "$reject_all_ok" "$plan_good_rc" >&2
    fi
  fi
fi

# --- Generator fail-closed on catalog health.yaml missing port (#708) -------
# #704 guarded config.yaml reads; #708 guards the health *port* reads that come
# from committed catalog metadata (framework/catalog/<app>/health.yaml) in the
# catalog app loop, the co-hosted cluster-dashboard synthesis, and the
# workstation loop. A mikefarah `yq -r '.port // ""'` on a present file with a
# missing `port` key returns "" at exit 0 (verified: the fail-open path), so an
# enabled+monitored app/workstation with an IP present but no health port
# emitted a portless `https://<ip>:<path>` URL and exited 0 — and because that
# endpoint is not necessarily endpoints[0], the module config_guard (which only
# checks endpoints[0].url) does not catch it.
#
# The generator hardcodes APPS_CONFIG and the catalog dir relative to its own
# location (find_repo_root walks up to flake.nix), so these cases run the
# generator from a SYNTHETIC repo root: the generator + its sourced libs copied
# into a temp tree with a flake.nix, a well-formed config.yaml (`acme: staging`
# so the cert-monitor path is skipped and no network/catalog cert reads run),
# and a controllable applications.yaml + framework/catalog/<app>/health.yaml.
# No tofu needed; always runs.

GENERATOR="${REPO_ROOT}/framework/scripts/generate-gatus-config.sh"

# _gcf708_make_repo <troot> — build a synthetic repo root with a well-formed
# config.yaml. Caller adds site/applications.yaml + catalog health.yaml files.
_gcf708_make_repo() {
  local troot="$1"
  mkdir -p "${troot}/framework/scripts" "${troot}/framework/catalog" "${troot}/site"
  : > "${troot}/flake.nix"
  cp "${REPO_ROOT}/framework/scripts/generate-gatus-config.sh" \
     "${REPO_ROOT}/framework/scripts/certbot-cluster.sh" \
     "${REPO_ROOT}/framework/scripts/github-publish-lib.sh" \
     "${troot}/framework/scripts/"
  chmod +x "${troot}/framework/scripts/generate-gatus-config.sh"
  cat > "${troot}/site/config.yaml" <<'YAML'
domain: example.com
acme: staging
vms:
  dns1_prod: {ip: "10.0.0.1"}
  dns2_prod: {ip: "10.0.0.2"}
  vault_prod: {ip: "10.0.0.3"}
  pbs: {ip: "10.0.0.4"}
  gitlab: {ip: "10.0.0.5"}
  gatus: {ip: "10.0.0.6"}
nas: {ip: "10.0.0.7"}
replication: {health_port: 9200}
proxmox: {storage_pool: vmstore}
email: {smtp_host: h, smtp_port: 25, to: "a@b.c"}
nodes:
  - {name: pve01, mgmt_ip: "10.0.0.10"}
YAML
}

# _gcf708_run <troot> — run the synthetic-root generator; sets _GCF_RC/_GCF_OUT.
_gcf708_run() {
  local troot="$1"
  set +e
  _GCF_OUT="$("${troot}/framework/scripts/generate-gatus-config.sh" "${troot}/site/config.yaml" 2>&1)"
  _GCF_RC=$?
  set -e
}

test_start "GCF.9" "generator fails closed when a monitored app's health.yaml has no port (#708)"
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
mkdir -p "${TROOT}/framework/catalog/myapp"
printf 'path: /health\n' > "${TROOT}/framework/catalog/myapp/health.yaml"   # NO port key
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  myapp:
    enabled: true
    monitor: true
    environments:
      prod: {ip: "10.9.9.9"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -ne 0 ]] &&
   grep -Fq "gatus target 'myapp'" <<< "$_GCF_OUT" &&
   grep -Fq 'health.yaml' <<< "$_GCF_OUT" &&
   grep -Fq '(#708)' <<< "$_GCF_OUT" &&
   ! grep -Eq 'https://10\.9\.9\.9:[^0-9]' <<< "$_GCF_OUT"; then
  test_pass "exits non-zero, names the app + health.yaml, emits no portless URL"
else
  test_fail "generator did not fail closed on a monitored app with a portless health.yaml"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.10" "generator ACCEPTS a monitored app whose health.yaml has a port (#708)"
# Guards against an over-eager guard: a well-formed catalog app must still emit
# a well-formed https://<ip>:<port><path> endpoint and exit 0.
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
mkdir -p "${TROOT}/framework/catalog/myapp"
printf 'port: 8080\npath: /health\n' > "${TROOT}/framework/catalog/myapp/health.yaml"
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  myapp:
    enabled: true
    monitor: true
    environments:
      prod: {ip: "10.9.9.9"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -eq 0 ]] && grep -Fq 'url: "https://10.9.9.9:8080/health"' <<< "$_GCF_OUT"; then
  test_pass "exit 0 and a well-formed https://10.9.9.9:8080/health endpoint"
else
  test_fail "generator did not accept / emit a well-formed endpoint for a valid app health.yaml"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.11" "a monitored app with no prod IP is DROPPED, not failed (#708 scope)"
# The fail-closed guard is scoped to endpoint EMISSION: an app can be
# enabled+monitored yet deployed only to dev, and the gatus config is prod-only.
# A missing prod IP must still drop the (nonexistent) prod endpoint silently —
# even when its health.yaml also lacks a port — rather than fail the generator.
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
mkdir -p "${TROOT}/framework/catalog/myapp"
printf 'path: /health\n' > "${TROOT}/framework/catalog/myapp/health.yaml"   # NO port key
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  myapp:
    enabled: true
    monitor: true
    environments:
      dev: {ip: "10.1.1.1"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -eq 0 ]] && ! grep -Fq 'myapp' <<< "$_GCF_OUT"; then
  test_pass "exit 0 and no myapp endpoint emitted (dev-only app correctly dropped)"
else
  test_fail "a prod-IP-less monitored app should be dropped, not fail the generator"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.12" "generator fails closed when cluster-dashboard health.yaml has no port (#708)"
# The co-hosted cluster-dashboard synthesis (influxdb only) reads its own
# framework/catalog/cluster-dashboard/health.yaml. influxdb's own port is valid
# here, so the failure must come specifically from the dashboard port and name
# cluster-dashboard.
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
mkdir -p "${TROOT}/framework/catalog/influxdb" "${TROOT}/framework/catalog/cluster-dashboard"
printf 'port: 8086\npath: /health\n' > "${TROOT}/framework/catalog/influxdb/health.yaml"
printf 'path: /\n' > "${TROOT}/framework/catalog/cluster-dashboard/health.yaml"   # NO port key
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  influxdb:
    enabled: true
    monitor: true
    environments:
      prod: {ip: "10.8.8.8"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -ne 0 ]] &&
   grep -Fq "gatus target 'cluster-dashboard'" <<< "$_GCF_OUT" &&
   grep -Fq '(#708)' <<< "$_GCF_OUT" &&
   ! grep -Eq 'https://10\.8\.8\.8:[^0-9]' <<< "$_GCF_OUT"; then
  test_pass "exits non-zero, names cluster-dashboard, emits no portless dashboard URL"
else
  test_fail "generator did not fail closed on a portless cluster-dashboard health.yaml"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.13" "generator fails closed when workstation health.yaml has no port (#708)"
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
mkdir -p "${TROOT}/framework/catalog/workstation"
printf 'path: /status\n' > "${TROOT}/framework/catalog/workstation/health.yaml"   # NO port key
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  workstation:
    enabled: true
    environments:
      prod: {ip: "10.7.7.7"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -ne 0 ]] &&
   grep -Fq "gatus target 'workstation'" <<< "$_GCF_OUT" &&
   grep -Fq '(#708)' <<< "$_GCF_OUT" &&
   ! grep -Eq 'https://10\.7\.7\.7:[^0-9]' <<< "$_GCF_OUT"; then
  test_pass "exits non-zero, names workstation, emits no portless URL"
else
  test_fail "generator did not fail closed on a portless workstation health.yaml"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

# --- #708 review-round-2 hardening cases -----------------------------------
# Added after the three-model adversarial review surfaced: (a) a MISSING
# health.yaml FILE (distinct from a present file with no port key) must fall
# through to the same fail-closed-or-drop logic, not abort under set -e before
# the guard; (b) a non-numeric port must also fail closed; (c) the workstation
# dev path (environments.dev.mgmt_nic.ip) and the dev-only-influxdb dashboard
# drop were previously uncovered.

test_start "GCF.14" "missing health.yaml FILE for a monitored app with a prod IP fails closed (#708)"
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
# Note: NO framework/catalog/myapp/ directory at all → HEALTH_FILE absent.
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  myapp:
    enabled: true
    monitor: true
    environments:
      prod: {ip: "10.9.9.9"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -ne 0 ]] &&
   grep -Fq "gatus target 'myapp'" <<< "$_GCF_OUT" &&
   grep -Fq '(#708)' <<< "$_GCF_OUT" &&
   ! grep -Eq 'https://10\.9\.9\.9:[^0-9]' <<< "$_GCF_OUT"; then
  test_pass "exits non-zero with the #708 diagnostic (not a silent set -e abort)"
else
  test_fail "a missing health.yaml file should fail closed with the #708 diagnostic"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.15" "missing health.yaml FILE for a dev-only app is DROPPED, not aborted (#708 scope)"
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
# No catalog dir AND no prod IP: the endpoint must be dropped, not fail.
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  myapp:
    enabled: true
    monitor: true
    environments:
      dev: {ip: "10.1.1.1"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -eq 0 ]] && ! grep -Fq 'myapp' <<< "$_GCF_OUT"; then
  test_pass "exit 0 and no myapp endpoint (dev-only app dropped despite a missing health.yaml)"
else
  test_fail "a dev-only app with a missing health.yaml should be dropped, not abort"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.16" "non-numeric health port fails closed (#708)"
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
mkdir -p "${TROOT}/framework/catalog/myapp"
printf 'port: "abc"\npath: /health\n' > "${TROOT}/framework/catalog/myapp/health.yaml"
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  myapp:
    enabled: true
    monitor: true
    environments:
      prod: {ip: "10.9.9.9"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -ne 0 ]] &&
   grep -Fq 'non-numeric' <<< "$_GCF_OUT" &&
   ! grep -Fq 'url: "https://10.9.9.9:abc' <<< "$_GCF_OUT"; then
  test_pass "exits non-zero on a non-numeric port; no malformed URL emitted"
else
  test_fail "a non-numeric health port should fail closed"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.17" "workstation dev path (dev.mgmt_nic.ip) emits with a valid port (#708)"
# Covers the WORK_ENV==dev branch that reads environments.dev.mgmt_nic.ip.
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
mkdir -p "${TROOT}/framework/catalog/workstation"
printf 'port: 8443\npath: /status\n' > "${TROOT}/framework/catalog/workstation/health.yaml"
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  workstation:
    enabled: true
    environments:
      dev:
        mgmt_nic: {ip: "10.6.6.6"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -eq 0 ]] && grep -Fq 'url: "https://10.6.6.6:8443/status"' <<< "$_GCF_OUT"; then
  test_pass "exit 0 and a well-formed workstation-dev https endpoint"
else
  test_fail "workstation dev path did not emit a well-formed endpoint"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.18" "dev-only influxdb drops BOTH app and co-hosted dashboard endpoints (#708)"
# influxdb enabled+monitored but with no prod IP: the dashboard synthesis is now
# gated on APP_IP, so neither the app nor a hostless dashboard URL is emitted.
TROOT="$(mktemp -d)"
_gcf708_make_repo "$TROOT"
mkdir -p "${TROOT}/framework/catalog/influxdb" "${TROOT}/framework/catalog/cluster-dashboard"
printf 'port: 8086\npath: /health\n' > "${TROOT}/framework/catalog/influxdb/health.yaml"
printf 'port: 443\npath: /\n' > "${TROOT}/framework/catalog/cluster-dashboard/health.yaml"
cat > "${TROOT}/site/applications.yaml" <<'YAML'
applications:
  influxdb:
    enabled: true
    monitor: true
    environments:
      dev: {ip: "10.1.1.2"}
YAML
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -eq 0 ]] &&
   ! grep -Fq 'influxdb-prod' <<< "$_GCF_OUT" &&
   ! grep -Fq 'influxdb-dashboard-prod' <<< "$_GCF_OUT" &&
   ! grep -Eq 'https://:[0-9]' <<< "$_GCF_OUT"; then
  test_pass "exit 0; no app or hostless dashboard endpoint for a dev-only influxdb"
else
  test_fail "dev-only influxdb should drop both app and dashboard, with no hostless URL"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

# --- Cert-monitor producer failure must stop the line (#717) ----------------
# #704 guarded config.yaml reads and #708 guarded catalog health ports, but the
# cert-monitor block reached its producer through a process substitution
# (`done < <(certbot_cluster_gatus_cert_monitor_records ...)`). A process
# substitution never propagates the producer's exit status to the parent — the
# parent only sees `read`'s status — so a producer that died mid-stream left the
# generator exiting 0 with a config missing some or all cert-expiry endpoints.
# The module config_guard cannot catch that either: it only inspects
# endpoints[0].url, and endpoints[0] is never a cert endpoint — it is
# github-mirror-main when publishing is opted in, dns1-prod otherwise.
# Fail-OPEN through both guards, same class as #704/#708.
#
# Scope: these cases pin the CONSUMER's contract. A failure inside one of the
# producer's own nested process substitutions still returns 0 to the consumer
# and is not detectable here — that residual is #907.
#
# These cases drive the generator with a STUBBED producer (appended to the
# synthetic root's copy of certbot-cluster.sh, which the generator sources), so
# they assert the consumer's fail-closed contract without any network or real
# cert inventory.

# _gcf717_make_repo <troot> <producer-stub-body> — synthetic root under
# `acme: production` (the only mode in which the cert block runs) with the
# cert-monitor producer replaced by the caller's stub.
_gcf717_make_repo() {
  local troot="$1" stub="$2"
  _gcf708_make_repo "$troot"
  # Flip acme staging -> production without sed -i (BSD/GNU portability,
  # .claude/rules/platform.md).
  { grep -v '^acme:' "${troot}/site/config.yaml"; printf 'acme: production\n'; } \
    > "${troot}/site/config.yaml.new"
  mv "${troot}/site/config.yaml.new" "${troot}/site/config.yaml"
  printf 'applications: {}\n' > "${troot}/site/applications.yaml"
  # The generator sources certbot-cluster.sh, so a redefinition appended to the
  # end of the sourced file wins over the real implementation.
  printf '%s\n' "$stub" >> "${troot}/framework/scripts/certbot-cluster.sh"
}

_GCF717_RECORD=$'cert-vault-prod\tvault_prod\t10.0.0.3\t8200\tvault.prod.example.com'

test_start "GCF.19" "producer failure AFTER partial output fails the generator closed (#717)"
# The pre-fix shape's worst case: the producer emits some records and then dies.
# The old process substitution consumed the partial stream and exited 0, so a
# Gatus config shipped with a SUBSET of its cert monitors and nothing went red.
TROOT="$(mktemp -d)"
_gcf717_make_repo "$TROOT" \
  "certbot_cluster_gatus_cert_monitor_records() { printf '%s\\n' '${_GCF717_RECORD}'; return 1; }"
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -ne 0 ]] &&
   grep -Fq '(#717)' <<< "$_GCF_OUT" &&
   grep -Fq 'certbot_cluster_gatus_cert_monitor_records failed' <<< "$_GCF_OUT" &&
   ! grep -Fq 'cert-vault-prod' <<< "$_GCF_OUT"; then
  test_pass "exits non-zero, names #717, and emits no partial cert-monitor endpoint"
else
  test_fail "generator did not fail closed on a producer that failed after partial output"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.20" "producer that silently emits nothing fails the generator closed (#717)"
# Under `acme: production` an empty record set is not reachable from a valid
# config: the producer emits cert-vault-prod from `.vms.vault_prod.ip`, and the
# generator has already refused to continue unless that key is present and
# non-null. Empty therefore means the producer stopped emitting without
# reporting failure — which must not ship a config with an empty cert group.
TROOT="$(mktemp -d)"
_gcf717_make_repo "$TROOT" \
  'certbot_cluster_gatus_cert_monitor_records() { return 0; }'
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -ne 0 ]] &&
   grep -Fq '(#717)' <<< "$_GCF_OUT" &&
   grep -Fq 'produced no records' <<< "$_GCF_OUT"; then
  test_pass "exits non-zero and names the empty cert-monitor record set"
else
  test_fail "generator did not fail closed on a producer that emitted nothing at exit 0"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.22" "a producer that fails INTERNALLY (no explicit return) fails closed (#717)"
# The failure class the real producer actually exhibits: a command inside it
# fails (yq missing, unreadable config) and errexit aborts it mid-stream. It
# never reaches an explicit `return 1`, so GCF.19's stub does not model it.
#
# This case is what distinguishes a working fix from one that only looks fixed.
# Bash honors errexit inside a process substitution but NOT inside a command
# substitution, so capturing with a plain `VAR="$(producer)"` lets the producer
# run straight past its internal failure and return 0 — both guards go
# unreachable and the #717 fail-open survives. The `set -e` re-armed inside the
# subshell is what makes this case fail closed; drop it and this test goes red
# while GCF.19/20/21 all stay green.
#
# `false` stands in for the failing internal command; the trailing marker record
# is the evidence: if it appears in the output, the producer did NOT abort.
TROOT="$(mktemp -d)"
_gcf717_make_repo "$TROOT" \
  "certbot_cluster_gatus_cert_monitor_records() { printf '%s\\n' '${_GCF717_RECORD}'; false; printf 'cert-after-internal-failure\\tx\\t10.0.0.9\\t1\\tx\\n'; }"
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -ne 0 ]] &&
   grep -Fq '(#717)' <<< "$_GCF_OUT" &&
   ! grep -Fq 'cert-after-internal-failure' <<< "$_GCF_OUT" &&
   ! grep -Fq 'cert-vault-prod' <<< "$_GCF_OUT"; then
  test_pass "producer aborted at its internal failure and the generator failed closed"
else
  test_fail "an internally-failing producer did not stop the generator (errexit lost in \$( ))"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

test_start "GCF.21" "a healthy producer still emits cert monitors and a complete config (#717)"
# Guards against an over-eager guard (same role GCF.10 plays for #708) and
# carries the fixture past the guarded step through the REST of the generator —
# the blocks emitted after the cert loop must still be present (R-G-4).
TROOT="$(mktemp -d)"
_gcf717_make_repo "$TROOT" \
  "certbot_cluster_gatus_cert_monitor_records() { printf '%s\\n' '${_GCF717_RECORD}'; return 0; }"
_gcf708_run "$TROOT"
rm -rf "$TROOT"
if [[ "$_GCF_RC" -eq 0 ]] &&
   grep -Fq 'name: cert-vault-prod' <<< "$_GCF_OUT" &&
   grep -Fq 'url: "https://10.0.0.3:8200"' <<< "$_GCF_OUT" &&
   grep -Fq '[CERTIFICATE_EXPIRATION] > 14d' <<< "$_GCF_OUT" &&
   grep -Fq 'name: nas' <<< "$_GCF_OUT" &&
   grep -Fq 'name: sentinel-gatus' <<< "$_GCF_OUT"; then
  test_pass "exit 0; cert monitor emitted and the post-cert blocks still render"
else
  test_fail "healthy producer path regressed — cert monitor or later blocks missing"
  printf 'rc=%s\nout:\n%s\n' "$_GCF_RC" "$_GCF_OUT" >&2
fi

runner_summary
