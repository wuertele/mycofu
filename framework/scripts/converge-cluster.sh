#!/usr/bin/env bash
# converge-cluster.sh — Non-destructive cluster-state reconciliation.
#
# Reconciles two directions of drift between tofu state and the live
# cluster, for resource classes safe to apply on a running cluster:
#
#   Phase A (additive): tofu state says X should exist, reality doesn't
#     → create X via targeted `tofu apply`. See issue #358.
#
#   Phase B (orphan cleanup): reality says file Y exists on a node,
#     tofu state doesn't track it → delete Y from the node. See issue
#     #359. Today Phase B is snippet-specific: enumerates
#     /var/lib/vz/snippets/*.yaml on each node, compares against the
#     set of `(node, file_name)` pairs in state filtered by
#     content_type=snippets, deletes the difference.
#
# Both directions together implement tofu's declarative promise:
# reality should match state. Tofu does this natively for resources it
# tracks; the orphan-cleanup direction is for files that escaped tofu
# tracking (e.g., past `tofu state rm`, partial-destroy failures,
# enabled→disabled flips without an apply afterward).
#
# Why this script exists: the Tier 1 pipeline cannot run `tofu apply`
# against Tier 2 modules because
# doing so could recreate the control-plane VM the pipeline itself
# depends on. That restriction is overly broad for snippet uploads:
# `proxmox_virtual_environment_file` resources upload CIDATA snippets
# to Proxmox node-local storage and have NO effect on running VMs —
# they only matter at next VM recreate. So this script reconciles
# snippet drift for ALL modules (Tier 1 + Tier 2), without touching
# the VM-recreation boundary.
#
# Currently in scope (Phase A, -target apply):
#   - proxmox_virtual_environment_file resources with content_type=snippets,
#     whose owning module is deployable in the requested --env
#
# Currently in scope (Phase B, orphan removal):
#   - /var/lib/vz/snippets/*.yaml files not in tofu state
#
# Explicitly out of scope:
#   - proxmox_virtual_environment_vm — recreating a VM would destroy vdb
#   - proxmox_virtual_environment_haresource — HA state changes have known
#     bpg-provider drift edge cases; see safe-apply.sh verify_ha_resources
#   - Anything not a content_type=snippets file whose owning module is
#     env-deployable (Phase A), or anything outside
#     /var/lib/vz/snippets/ (Phase B)
#
# Replication is handled separately by configure-replication.sh (already
# called from safe-apply.sh post-success and from rebuild-cluster.sh).
#
# Usage:
#   converge-cluster.sh --env <dev|prod> [--dry-run] [--allow-empty-expected]
#
# Environment scoping (#529):
#   --env is REQUIRED. There is NO all-modules fallback. Phase A targets ONLY
#   the snippet resources whose owning module is deployable in the requested
#   environment, as classified by the single authoritative reader
#   `vm-scope.sh deployable-modules --env <env>`. The invariant is:
#
#       converge scope == deploy scope, per env.
#
#   Prod-classified modules (gatus, *_prod) are unreachable from --env dev;
#   dev-classified and shared data-plane modules are unreachable from
#   --env prod. Shared data-plane modules (currently hil_boot) are converged
#   by --env dev only, matching safe-apply.sh's dev-deploys-shared exception —
#   so converge:dev maintaining hil_boot snippets adds no authority a dev push
#   does not already have.
#
#   Control-plane modules (gitlab/cicd/pbs) are DEV-AUTHORITATIVE (operator
#   decision 2026-07-17, #623): they are converged by --env dev ONLY and are
#   unreachable from --env prod. Rationale — per Design Goal G1 the control
#   plane is the escape hatch from a bad cluster state and fixes land on dev
#   first; prod trails dev, so a prod-side control-plane converge write would
#   be a revert footgun (pushing prod's older snippet state back over dev).
#   Invariant: each pipeline converges exactly what it deploys; the control
#   plane converges from dev only.
#
#   This closes the #529 authority leak (a dev pipeline's converge job could
#   rewrite prod gatus snippet state) and subsumes #360 (Phase A now selects
#   by content_type == "snippets", so non-snippet files such as ISOs are
#   never targeted). Phase B orphan detection is env-agnostic by design (an
#   on-disk file tracked by NO module's state is an orphan regardless of
#   env), so its expected set is still drawn from ALL modules.
#
# Exit codes:
#   0  no drift, or drift fully reconciled
#   1  fail-closed condition:
#        - tofu show -json / plan / apply failed
#        - tofu show -json output unparseable or wrong shape
#        - a file resource is missing content_type (cannot classify)
#        - a snippet resource's owning module cannot be classified by
#          vm-scope.sh (undeclared module)
#        - orphan enumeration / deletion failed (Phase B)
#        - empty-expected safety gate tripped (Phase B)
#   2  argument parsing error (including a missing or invalid --env)
#
# Empty-expected safety gate (Phase B):
#   If `tofu show -json` reports zero expected snippets but nodes have
#   .yaml files in /var/lib/vz/snippets/, the script REFUSES to delete
#   them by default. Override with --allow-empty-expected only when every
#   snippet-bearing module is genuinely removed from the deployment.
#   Rationale: framework modules always produce snippets, so an empty
#   expected set almost always means state corruption, wrong backend, or
#   a tofu show -json shape change — not a legitimate full cleanup. The
#   gate prevents one bad state read from wiping every snippet on every
#   node. (added in #359 R1 after adversarial review.)
#
# History:
#   - #358 — initial implementation: Phase A only.
#   - #359 — added Phase B (orphan cleanup). The motivating case was
#     workstation-dev snippets on pve02/pve03 left over from when the
#     module was enabled, never destroyed when the module was disabled.
#     Phase A heals the gitlab half of the original incident; Phase B
#     heals the workstation-dev half.
#   - #359 R1 — hardened against empty/lost state: added shape validation
#     of tofu show output, per-pair shape validation in the jq filter,
#     and the empty-expected safety gate. Two independent reviewers
#     (codex P1 + gemini P1.1) caught that a valid-but-empty state read
#     would mass-delete every snippet on every node.

set -euo pipefail

# Deterministic sort/comm. Phase B uses comm -23 to compute orphans; without
# LC_ALL=C the collation order depends on the runner's locale and can produce
# spurious orphan classifications (gemini review, P2).
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# The only tofu resource type + content_type converge reconciles in Phase A.
# Selection is done structurally from `tofu show -json` (type + content_type
# fields), NOT by string-matching state-list addresses, so a module *named*
# like the resource type cannot smuggle a VM into the target set, and a
# non-snippet file (content_type=iso, etc.) is never targeted (#360).
SAFE_RESOURCE_TYPE="proxmox_virtual_environment_file"
SNIPPET_CONTENT_TYPE="snippets"

# tofu lock timeout: snippet apply against PostgreSQL backend can race
# with operator workstation activity (rebuild-cluster.sh, configure-*).
# Wait up to 10 minutes for the lock rather than failing immediately —
# turns a transient race into a slower-but-successful run.
TOFU_LOCK_TIMEOUT="10m"

usage() {
  cat <<EOF
Usage: $(basename "$0") --env <dev|prod> [--dry-run] [--allow-empty-expected]

Non-destructive cluster-state reconciliation. Phase A targets only the
snippet resources whose owning module is deployable in the requested
environment (converge scope == deploy scope, per env). Idempotent — safe to
run repeatedly. Never touches VMs or HA state.

Options:
  --env <dev|prod>         REQUIRED. Environment whose deployable snippet
                           modules Phase A may converge. There is no
                           all-modules fallback; a missing --env is an error.
  --dry-run                Show what would be applied; do not apply
  --allow-empty-expected   Override the safety gate that refuses to delete
                           orphan snippets when the expected set is empty.
                           See "Empty-expected safety gate" in script header.
  --help                   Show this help
EOF
}

DRY_RUN=0
ALLOW_EMPTY_EXPECTED=0
ENV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h) usage; exit 0;;
    --env)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --env requires an argument (dev or prod)" >&2
        usage >&2
        exit 2
      fi
      ENV="$2"; shift 2;;
    --env=*) ENV="${1#--env=}"; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --allow-empty-expected) ALLOW_EMPTY_EXPECTED=1; shift;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# --env is mandatory and must be dev or prod. Fail closed: never fall back to
# converging every module's snippets across all environments (#529).
if [[ -z "$ENV" ]]; then
  echo "ERROR: --env <dev|prod> is required. Refusing to converge without an" >&2
  echo "       explicit environment scope (would otherwise target every" >&2
  echo "       module's snippets across all environments — the #529 leak)." >&2
  usage >&2
  exit 2
fi
if [[ "$ENV" != "dev" && "$ENV" != "prod" ]]; then
  echo "ERROR: --env must be 'dev' or 'prod', got '$ENV'" >&2
  usage >&2
  exit 2
fi

cd "${REPO_DIR}"

CONFIG_FILE="${REPO_DIR}/site/config.yaml"

# SSH options mirror validate.sh:157 (R2.1 enumeration). BatchMode and
# UserKnownHostsFile are needed for unattended pipeline use.
SSH_OPTS=(-n -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)

# --- Acquire the tofu state snapshot ONCE (shared by Phase A env-scoped
#     target selection AND Phase B orphan detection). This replaces the old
#     `tofu state list` enumeration; selection is now structural (type +
#     content_type from the JSON), not address string-matching. ---
echo "=== converge-cluster: reading tofu state snapshot ==="

# Capture stderr to a temp file so a failure (state lock, PG backend
# timeout, uninitialized slot) surfaces the tofu diagnostic instead of a
# bare rc. Fail-closed diagnostics must explain WHY (destruction-safety rule).
SHOW_ERR="$(mktemp)"
set +e
SHOW_JSON_RAW="$("${SCRIPT_DIR}/tofu-wrapper.sh" show -json 2>"$SHOW_ERR")"
SJ_RC=$?
set -e

if [[ $SJ_RC -ne 0 ]]; then
  echo "ERROR: tofu show -json failed (rc=$SJ_RC); cannot read cluster state." >&2
  if [[ -s "$SHOW_ERR" ]]; then
    sed 's/^/  tofu: /' "$SHOW_ERR" >&2
  fi
  rm -f "$SHOW_ERR"
  exit 1
fi
rm -f "$SHOW_ERR"

# Strip wrapper preamble before the first '{' at start-of-line. The wrapper
# prints "Decrypting secrets..." etc. on stdout. Anchored to ^{ so a stray
# mid-preamble '{' does not start the extraction.
SHOW_JSON="$(printf '%s\n' "$SHOW_JSON_RAW" | sed -n '/^{/,$p')"
if [[ -z "$SHOW_JSON" ]]; then
  echo "ERROR: tofu show -json output had no JSON body." >&2
  exit 1
fi

# Shape validation: confirm SHOW_JSON parses and has the structure tofu
# state-show always produces (.values.root_module). Fail closed otherwise —
# a valid-but-irrelevant JSON object must not be silently accepted.
if ! printf '%s' "$SHOW_JSON" | jq -e '.values.root_module' >/dev/null 2>&1; then
  echo "ERROR: tofu show -json output is not a valid tofu state snapshot." >&2
  echo "       Expected '.values.root_module' to exist." >&2
  exit 1
fi

# --- Phase A: select env-scoped snippet resources ---
echo ""
echo "=== converge-cluster Phase A: selecting env=$ENV snippet resources ==="

# Fail closed if ANY file resource lacks a string content_type. Without a
# content_type we cannot prove a file is (or is not) a snippet, so we refuse
# to guess. (#360/#529 — structural discrimination replaces address grepping.)
set +e
BAD_CT="$(printf '%s' "$SHOW_JSON" | jq '
  [.. | objects
    | select(.type? == "'"$SAFE_RESOURCE_TYPE"'")
    | select((.values?.content_type? | type) != "string")]
  | length' 2>&1)"
CT_RC=$?
set -e
if [[ $CT_RC -ne 0 ]]; then
  echo "ERROR: jq content_type check failed (rc=$CT_RC):" >&2
  printf '%s\n' "$BAD_CT" >&2
  exit 1
fi
if [[ "$BAD_CT" != "0" ]]; then
  echo "ERROR: $BAD_CT ${SAFE_RESOURCE_TYPE} resource(s) in state are missing a" >&2
  echo "       string content_type; cannot classify snippet vs non-snippet." >&2
  echo "       Refusing to converge (fail-closed)." >&2
  exit 1
fi

# All snippet resource addresses (content_type == snippets). Non-snippet
# files (content_type=iso, etc.) are structurally excluded here (#360).
set +e
SNIPPET_ADDRS="$(printf '%s' "$SHOW_JSON" | jq -r '
  [.. | objects
    | select(.type? == "'"$SAFE_RESOURCE_TYPE"'"
             and .values?.content_type? == "'"$SNIPPET_CONTENT_TYPE"'")]
  | .[] | .address // ""' 2>&1)"
SA_RC=$?
set -e
if [[ $SA_RC -ne 0 ]]; then
  echo "ERROR: jq snippet-address extraction failed (rc=$SA_RC):" >&2
  printf '%s\n' "$SNIPPET_ADDRS" >&2
  exit 1
fi

# Count snippet resources vs non-empty addresses. A snippet resource with no
# address is a malformed snapshot — fail closed rather than skip it silently.
SNIPPET_COUNT="$(printf '%s' "$SHOW_JSON" | jq '
  [.. | objects
    | select(.type? == "'"$SAFE_RESOURCE_TYPE"'"
             and .values?.content_type? == "'"$SNIPPET_CONTENT_TYPE"'")]
  | length')"
ADDR_COUNT=0
if [[ -n "$SNIPPET_ADDRS" ]]; then
  ADDR_COUNT=$(printf '%s\n' "$SNIPPET_ADDRS" | grep -c '.' || true)
fi
if [[ "$ADDR_COUNT" -ne "$SNIPPET_COUNT" ]]; then
  echo "ERROR: $((SNIPPET_COUNT - ADDR_COUNT)) snippet resource(s) have no address" >&2
  echo "       in the state snapshot; cannot classify. Failing closed." >&2
  exit 1
fi

TARGETS=()
if [[ "$SNIPPET_COUNT" -eq 0 ]]; then
  echo "No snippet resources in state. Phase A is a no-op."
else
  # Authoritative env classification: reuse `vm-scope.sh deployable-modules`
  # so converge scope == deploy scope, per env. Build a synthetic plan
  # document (each snippet resource as a non-noop resource_change) and let
  # the single taxonomy reader decide which modules are deployable in $ENV.
  # This yields the exact set safe-apply.sh would deploy: dev-classified +
  # shared data-plane for --env dev; prod-classified for --env prod; an
  # undeclared module is a HARD failure (fail-closed, #529). Control-plane
  # (gitlab/cicd/pbs) is added back below for --env dev ONLY (dev-authoritative
  # single-writer, #623).
  SYNTH_PLAN="$(mktemp)"
  ALLOWED_ERR="$(mktemp)"
  cleanup_synth() { rm -f "$SYNTH_PLAN" "$ALLOWED_ERR"; }

  set +e
  printf '%s' "$SHOW_JSON" | jq '{
    resource_changes: [ .. | objects
      | select(.type? == "'"$SAFE_RESOURCE_TYPE"'"
               and .values?.content_type? == "'"$SNIPPET_CONTENT_TYPE"'")
      | {address: .address, type: .type, change: {actions: ["update"]}} ]
  }' > "$SYNTH_PLAN" 2>"$ALLOWED_ERR"
  JB_RC=$?
  set -e
  if [[ $JB_RC -ne 0 ]]; then
    echo "ERROR: failed to build synthetic plan for classification (rc=$JB_RC):" >&2
    cat "$ALLOWED_ERR" >&2
    cleanup_synth
    exit 1
  fi

  set +e
  ALLOWED_MODULES="$("${SCRIPT_DIR}/vm-scope.sh" deployable-modules \
    --env "$ENV" --plan-json "$SYNTH_PLAN" 2>"$ALLOWED_ERR")"
  VS_RC=$?
  set -e

  # Surface vm-scope diagnostics (e.g., control-plane "does not match any
  # environment -- skipping" lines) for operator visibility.
  if [[ -s "$ALLOWED_ERR" ]]; then
    sed 's/^/  vm-scope: /' "$ALLOWED_ERR" >&2
  fi
  if [[ $VS_RC -ne 0 ]]; then
    echo "ERROR: vm-scope.sh deployable-modules --env $ENV failed (rc=$VS_RC);" >&2
    echo "       a snippet module could not be classified. Failing closed (#529)." >&2
    cleanup_synth
    exit 1
  fi

  # Control-plane snippets (gitlab/cicd/pbs) are DEV-AUTHORITATIVE
  # (operator decision 2026-07-17, issue #623). `deployable-modules`
  # deliberately excludes control-plane from BOTH envs — it emits the
  # "does not match any environment -- skipping" WARNING surfaced above — so
  # we add the control-plane set back to the allowed modules for --env dev
  # ONLY, using the same authoritative reader (`vm-scope.sh
  # control-plane-modules`). --env prod gets no control-plane modules.
  #
  # Rationale — single-writer authority. Per Design Goal G1 the control plane
  # (gitlab/cicd) is the escape hatch from a bad cluster state, and fixes land
  # on dev first; prod trails dev. A prod-side control-plane converge write
  # would therefore be a revert footgun: it would push prod's older
  # control-plane snippet state back over the newer dev state. So the control
  # plane converges from dev only. Invariant: each pipeline converges exactly
  # what it deploys; the control plane converges from dev only. (#623 covers
  # the closure-level counterpart of this same single-writer rule.)
  if [[ "$ENV" == "dev" ]]; then
    set +e
    CP_MODULES="$("${SCRIPT_DIR}/vm-scope.sh" control-plane-modules 2>"$ALLOWED_ERR")"
    CP_RC=$?
    set -e
    if [[ -s "$ALLOWED_ERR" ]]; then
      sed 's/^/  vm-scope: /' "$ALLOWED_ERR" >&2
    fi
    if [[ $CP_RC -ne 0 ]]; then
      echo "ERROR: vm-scope.sh control-plane-modules failed (rc=$CP_RC); cannot" >&2
      echo "       determine the dev-authoritative control-plane set. Failing" >&2
      echo "       closed (#529/#623)." >&2
      cleanup_synth
      exit 1
    fi
    if [[ -n "$CP_MODULES" ]]; then
      ALLOWED_MODULES="$(printf '%s\n%s' "$ALLOWED_MODULES" "$CP_MODULES")"
    fi
  fi
  cleanup_synth

  # Membership filter: keep a snippet address iff its normalized root module
  # is in the env-deployable set. The normalization mirrors vm-scope's
  # root_module_from_address (first module segment, [key] stripped, hyphens
  # -> underscores) so the strings compare exactly.
  while IFS= read -r addr; do
    [[ -z "$addr" ]] && continue
    case "$addr" in
      module.*) : ;;
      *)
        echo "ERROR: snippet resource '$addr' is not under a module; cannot" >&2
        echo "       classify its environment. Failing closed." >&2
        exit 1;;
    esac
    seg="${addr#module.}"; seg="${seg%%.*}"; seg="${seg%%[*}"; seg="${seg//-/_}"
    rootmod="module.${seg}"
    if printf '%s\n' "$ALLOWED_MODULES" | grep -qxF "$rootmod"; then
      TARGETS+=(-target="$addr")
    fi
  done <<< "$SNIPPET_ADDRS"
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "Phase A: no env=$ENV snippet resources to converge (of $SNIPPET_COUNT total snippet resource(s) in state). Phase A is a no-op."
else
  echo "Found ${#TARGETS[@]} env=$ENV snippet target(s) of $SNIPPET_COUNT total snippet resource(s) in state."

  # --- Phase A: plan ---
  echo ""
  echo "=== converge-cluster Phase A: tofu plan -target=... ==="
  PLAN_OUT="$(mktemp)"
  cleanup_plan() { rm -f "$PLAN_OUT"; }
  trap cleanup_plan EXIT

  # --allow-placeholder-images: converge-cluster.sh by design touches ONLY
  # non-VM resources, so image version values are never consumed. If an
  # operator runs this on a fresh checkout without having built recently
  # (workstation case), the wrapper's placeholder guard would otherwise
  # block. In the pipeline image-versions.auto.tfvars is real by the time
  # this stage runs, so the flag is a no-op there.
  #
  # -detailed-exitcode: rc=0 no changes, rc=1 error, rc=2 changes pending.
  # More robust than string-grepping "No changes." (which would break if
  # upstream wording changes).
  #
  # -lock-timeout: wait up to TOFU_LOCK_TIMEOUT for the state lock instead
  # of failing immediately. Concurrent workstation activity (e.g.,
  # rebuild-cluster.sh) holds the lock briefly; failing fast turns a
  # benign overlap into a red pipeline.
  set +e
  "${SCRIPT_DIR}/tofu-wrapper.sh" plan \
    --allow-placeholder-images \
    -detailed-exitcode \
    -lock-timeout="${TOFU_LOCK_TIMEOUT}" \
    "${TARGETS[@]}" -no-color > "$PLAN_OUT" 2>&1
  PLAN_RC=$?
  set -e

  # Echo the summary line(s) for operator visibility regardless of rc.
  grep -E "^(Plan:|No changes\.)" "$PLAN_OUT" || true

  case $PLAN_RC in
    0)
      echo ""
      echo "Phase A: no additive changes needed."
      ;;
    2)
      if [[ $DRY_RUN -eq 1 ]]; then
        echo ""
        echo "=== DRY RUN — not applying Phase A. Full plan: ==="
        cat "$PLAN_OUT"
      else
        # --- Phase A: apply ---
        echo ""
        echo "=== converge-cluster Phase A: applying ==="
        set +e
        "${SCRIPT_DIR}/tofu-wrapper.sh" apply \
          --allow-placeholder-images \
          -lock-timeout="${TOFU_LOCK_TIMEOUT}" \
          "${TARGETS[@]}" -auto-approve
        APPLY_RC=$?
        set -e

        if [[ $APPLY_RC -ne 0 ]]; then
          echo "ERROR: tofu apply failed (rc=$APPLY_RC)" >&2
          exit $APPLY_RC
        fi
      fi
      ;;
    *)
      echo "ERROR: tofu plan failed (rc=$PLAN_RC):" >&2
      cat "$PLAN_OUT" >&2
      exit $PLAN_RC
      ;;
  esac
fi

# --- Phase B: orphan cleanup ---
# Snippet files present on a node but NOT tracked by tofu state are
# orphans — typically left over from a past `tofu state rm`, a partial
# destroy failure, or a module disable that was never followed by an
# apply. These files are safe to remove: tofu doesn't know about them,
# no running VM is reading them (snippets are CIDATA inputs consumed
# only at VM boot), and on next VM recreate tofu would write fresh
# snippets if the module was re-enabled.
#
# Algorithm:
#   1. Get expected (node, file_name) set from `tofu show -json` filtered
#      by content_type=snippets.
#   2. For each node, ssh+ls /var/lib/vz/snippets/*.yaml.
#   3. Per-node orphans = (on-disk - expected_for_that_node).
#   4. Delete orphans via ssh+rm. Fail-closed on any ssh/rm failure.
#
# Hardcoded to snippet path; if the converged resource set grows beyond
# content_type=snippets files, Phase B will need parallel logic for them (or
# this script stays snippet-specific and other classes get their own
# convergence helpers).
echo ""
echo "=== converge-cluster Phase B: enumerating expected snippets from state ==="

# Phase B reuses the SHOW_JSON snapshot acquired once up front (validated for
# shape there). Its "expected" set is drawn from ALL modules across every
# environment — an on-disk snippet tracked by NO module's state is an orphan
# regardless of env, so Phase B is deliberately NOT env-scoped. (Env scoping
# lives in Phase A target selection only; scoping Phase B's expected set would
# make converge:dev misclassify legitimate prod snippets as orphans.)

# EXPECTED_TSV: one line per expected snippet, tab-separated "node\tfile".
# Per-pair shape validation: require node_name and file_name to be non-empty
# strings. Without this, a tofu state snapshot with a partially-populated
# resource (e.g., file_name absent or null) would emit "null\tnull" lines
# that get treated as a real pair, causing real files to be classified as
# orphans (codex review P1 — second leg of the empty-state vulnerability).
EXPECTED_TSV="$(printf '%s' "$SHOW_JSON" | jq -r '
  [.. | objects
    | select(.type? == "proxmox_virtual_environment_file"
             and .values?.content_type? == "snippets"
             and (.values?.node_name | type) == "string"
             and (.values?.node_name | length) > 0
             and (.values?.file_name | type) == "string"
             and (.values?.file_name | length) > 0)]
  | .[]
  | "\(.values.node_name)\t\(.values.file_name)"
' 2>&1)"
JQ_RC=$?
if [[ $JQ_RC -ne 0 ]]; then
  echo "ERROR: jq filtering of tofu show output failed (rc=$JQ_RC):" >&2
  printf '%s\n' "$EXPECTED_TSV" >&2
  exit 1
fi

EXPECTED_COUNT=$(printf '%s' "$EXPECTED_TSV" | grep -c '	' || true)
echo "Found $EXPECTED_COUNT expected (node, snippet) pairs in state."

# Read node list from config.yaml — fail closed if config not available.
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: $CONFIG_FILE not found; cannot enumerate nodes for Phase B." >&2
  exit 1
fi

# Bash 3.2 (macOS default) has no `mapfile`; use a portable read loop.
NODES=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  NODES+=("$line")
# yq < v4.45 emits literal '\t' for backslash-escapes inside string
# interpolation; jq handles \t consistently across versions, so go
# YAML→JSON→jq for the tab separator. (Discovered when validate:converge-cluster
# failed against runner's yq v4.44.3 even though local yq v4.53.2 worked.)
done < <(yq -o=json '.nodes' "$CONFIG_FILE" | jq -r '.[] | "\(.name)\t\(.mgmt_ip)"')
if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "ERROR: no nodes found in $CONFIG_FILE; cannot run Phase B." >&2
  exit 1
fi

# Strict hostname validation — defense in depth against config.yaml
# tampering. Names that don't look like hostnames could be shell-injection
# vectors when interpolated into ssh arguments.
HOSTNAME_REGEX='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'
FILENAME_REGEX='^[a-zA-Z0-9._-]+\.yaml$'

ORPHAN_DELETE_FAILURES=0
ORPHAN_DELETIONS=0

# Phase B is 2-pass: pass 1 enumerates every node's orphans into parallel
# arrays, then the empty-expected safety gate runs against the total,
# then pass 2 performs deletions. This separation makes the gate evaluate
# the WHOLE picture (not just the first node) before any rm fires.
ORPHAN_NODES=()
ORPHAN_IPS=()
ORPHAN_FILES=()

for entry in "${NODES[@]}"; do
  NODE_NAME="${entry%%	*}"
  NODE_IP="${entry##*	}"

  if [[ ! "$NODE_NAME" =~ $HOSTNAME_REGEX ]]; then
    echo "ERROR: node name '$NODE_NAME' from config.yaml fails hostname regex; refusing to ssh." >&2
    exit 1
  fi

  # Expected files for THIS node (from state).
  EXPECTED_FOR_NODE="$(printf '%s\n' "$EXPECTED_TSV" \
    | awk -F'\t' -v n="$NODE_NAME" 'NR>=1 && $1==n {print $2}' \
    | sort -u)"

  # Actual files on THIS node. Mirror R2.1's enumeration exactly.
  set +e
  ACTUAL_RAW="$(ssh "${SSH_OPTS[@]}" "root@${NODE_IP}" \
    'cd /var/lib/vz/snippets 2>/dev/null && ls *.yaml 2>/dev/null || true' \
    2>/dev/null)"
  SSH_RC=$?
  set -e

  if [[ $SSH_RC -ne 0 ]]; then
    echo "ERROR: ssh enumeration failed on $NODE_NAME (rc=$SSH_RC); cannot determine orphans." >&2
    exit 1
  fi

  ACTUAL_FOR_NODE="$(printf '%s\n' "$ACTUAL_RAW" | sort -u)"

  # Orphans = actual - expected. comm -23 needs sorted inputs.
  ORPHANS="$(comm -23 \
    <(printf '%s\n' "$ACTUAL_FOR_NODE") \
    <(printf '%s\n' "$EXPECTED_FOR_NODE"))"

  # Strip empty lines (comm output for empty side).
  ORPHANS="$(printf '%s\n' "$ORPHANS" | grep -v '^$' || true)"

  if [[ -z "$ORPHANS" ]]; then
    echo "$NODE_NAME: no orphan snippets."
    continue
  fi

  ORPHAN_COUNT=$(printf '%s\n' "$ORPHANS" | wc -l | tr -d ' ')
  echo "$NODE_NAME: $ORPHAN_COUNT orphan snippet(s):"
  printf '%s\n' "$ORPHANS" | sed 's/^/    /'

  # Pass-1: validate every orphan filename now (FILENAME_REGEX). Running the
  # validation in pass-1 means dry-run also reports rejections, and we
  # exit before any rm fires if the regex would have refused (codex P3 —
  # dry-run filename validation parity).
  while IFS= read -r FILE; do
    [[ -z "$FILE" ]] && continue
    if [[ ! "$FILE" =~ $FILENAME_REGEX ]]; then
      echo "ERROR: orphan filename '$FILE' on $NODE_NAME fails filename regex; refusing to delete." >&2
      ORPHAN_DELETE_FAILURES=$((ORPHAN_DELETE_FAILURES + 1))
      continue
    fi
    ORPHAN_NODES+=("$NODE_NAME")
    ORPHAN_IPS+=("$NODE_IP")
    ORPHAN_FILES+=("$FILE")
  done <<<"$ORPHANS"
done

TOTAL_ORPHANS=${#ORPHAN_FILES[@]}

# --- Empty-expected safety gate ---
# If state says zero snippets are expected anywhere AND we found orphans,
# something is wrong. Legitimate causes (every snippet-bearing module
# genuinely disabled) are vanishingly rare; framework modules
# (gitlab, vault, dns, etc.) always produce snippets. Far more likely:
# wrong tofu backend, state corruption, partial tofu show output, or a
# state-shape change the script doesn't know about. Default-deny in
# automation; require the operator to opt in via --allow-empty-expected
# for the rare legitimate case. (codex P1 + gemini P1.1.)
if [[ $EXPECTED_COUNT -eq 0 && $TOTAL_ORPHANS -gt 0 ]]; then
  if [[ $ALLOW_EMPTY_EXPECTED -eq 1 ]]; then
    echo ""
    echo "WARNING: tofu state shows zero expected snippets but $TOTAL_ORPHANS"
    echo "         orphan(s) found. Proceeding because --allow-empty-expected"
    echo "         was passed."
  else
    echo ""
    echo "ERROR: tofu state shows zero expected snippets but $TOTAL_ORPHANS" >&2
    echo "       orphan(s) found on nodes. Refusing to delete." >&2
    echo "" >&2
    echo "       This usually means:" >&2
    echo "         - state corruption or wrong tofu backend, OR" >&2
    echo "         - tofu show -json output had unexpected shape" >&2
    echo "       Investigate state first; rerun manually with" >&2
    echo "       --allow-empty-expected ONLY if every snippet-bearing module" >&2
    echo "       is genuinely removed (very rare in practice)." >&2
    exit 1
  fi
fi

# --- Dry-run short-circuit ---
# Per-orphan filename validation already ran in pass 1; if any rejection
# occurred, surface it now even in dry-run so the operator sees the
# would-have-failed condition before they let the next non-dry-run go.
if [[ $DRY_RUN -eq 1 ]]; then
  echo ""
  if [[ $ORPHAN_DELETE_FAILURES -gt 0 ]]; then
    echo "ERROR: DRY RUN — $ORPHAN_DELETE_FAILURES orphan filename(s) rejected by" >&2
    echo "       regex guard; non-dry-run would have failed." >&2
    exit 1
  fi
  echo "DRY RUN — not deleting $TOTAL_ORPHANS orphan(s)."
  echo "Cluster converged."
  exit 0
fi

# --- Pass 2: delete ---
for ((i=0; i<TOTAL_ORPHANS; i++)); do
  NODE_NAME="${ORPHAN_NODES[$i]}"
  NODE_IP="${ORPHAN_IPS[$i]}"
  FILE="${ORPHAN_FILES[$i]}"
  set +e
  ssh "${SSH_OPTS[@]}" "root@${NODE_IP}" \
    "rm -- '/var/lib/vz/snippets/${FILE}'" 2>&1
  RM_RC=$?
  set -e
  if [[ $RM_RC -ne 0 ]]; then
    echo "ERROR: rm of $FILE on $NODE_NAME failed (rc=$RM_RC)." >&2
    ORPHAN_DELETE_FAILURES=$((ORPHAN_DELETE_FAILURES + 1))
  else
    echo "$NODE_NAME: deleted $FILE"
    ORPHAN_DELETIONS=$((ORPHAN_DELETIONS + 1))
  fi
done

echo ""
if [[ $ORPHAN_DELETE_FAILURES -gt 0 ]]; then
  echo "ERROR: Phase B deleted $ORPHAN_DELETIONS orphan(s) but $ORPHAN_DELETE_FAILURES deletion(s) failed." >&2
  exit 1
fi

if [[ $ORPHAN_DELETIONS -gt 0 ]]; then
  echo "Phase B: deleted $ORPHAN_DELETIONS orphan snippet(s)."
fi

echo "Cluster converged."
