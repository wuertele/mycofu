#!/usr/bin/env bash
# ci-pipeline-gcroot.sh — pin control-plane deploy closures for a pipeline's
# lifetime with durable, per-CI_PIPELINE_ID Nix GC roots (#560, Sprint 046 R8).
#
# WHY. cicd's daily nix.gc.timer can delete a control-plane deploy closure in
# the window between `build:merge` (which packages it into
# build/closure-paths.json) and `deploy:control-plane:*` (which consumes it by
# bare /nix/store path — deploy-control-plane.sh:531 dies if it is gone). The
# closure is pinned by no per-pipeline GC root, so a pipeline whose deploy lands
# after a GC run — notably one crossing 00:00 UTC — fails with
# "built closure missing from local store" (dev pipeline #1472, RCA committed at
# docs/reports/rca-2026-07-11-dev-pipeline-1472-nix-gc-race.md). R3's during-job
# GC busy-check cannot cover this between-jobs window.
#
# This registers an INDIRECT GC root per to-be-deployed closure so GC cannot
# reclaim it mid-pipeline, and sweeps roots left by pipelines that died between
# build and deploy so a closure is never pinned forever. Reliability, not safety
# (like #544): it does not participate in the memory-safety invariant.
#
# CI-only, deploy-free: the runner executes this from the repo checkout, so it
# is effective on the next pipeline with no cicd rebuild. Roots live on the
# runner host (outside the repo, not a CI artifact) precisely so they survive
# across the build:merge -> deploy:control-plane job boundary.
#
# Sweep cadence (design note). The stale sweep runs only at the FRONT of the
# next `register`, so orphan reclamation relies on regular pipeline activity: an
# orphan root persists until some later pipeline reaches build:merge. Given the
# cluster's normal pipeline cadence this is acceptable; a scheduled sweep job is
# intentionally NOT added (extra mechanism vs. the simplicity goal) unless that
# assumption proves false. `register-closure` (issue #573) adds a SECOND orphan
# source: a pipeline that dies between build:image and build:merge now leaves a
# per-pipeline dir created in build:image. It is reclaimed by the same
# STALE_MMIN sweep at the next pipeline's build:merge, so the bound is unchanged.
# register-closure itself deliberately does NOT sweep — parallel build:image
# legs would race the sweep against each other's fresh roots.
#
# Two register windows (issue #573). The batch `register` in build:merge only
# protects build:merge -> deploy; the closure is built earlier, in
# build:image[<host>], and nix's automatic min-free GC can reclaim it in the
# build:image -> build:merge window (dev pipeline 1509, all-image rebuild under
# store pressure). `register-closure` closes that earlier window by pinning each
# control-plane closure the instant build:image finishes building it. build:merge
# then re-pins as defense-in-depth, so both registers are idempotent: pinning a
# host that is already pinned at the same store path re-registers the same
# indirect root and succeeds (nix-store --add-root replaces the symlink).
#
# Subcommands:
#   register              Sweep stale roots, then realise + add an indirect GC
#                         root for every control-plane closure in
#                         closure-paths.json (build:merge; batch).
#   register-closure H P  Realise + add an indirect GC root for a SINGLE
#                         control-plane closure H at explicit store path P
#                         (build:image; before closure-paths.json exists).
#   release [host...]     Remove this pipeline's root(s) after a successful
#                         deploy; with no host, remove the whole pipeline dir.
set -euo pipefail

# Base dir for per-pipeline indirect roots. Test seam: MYCOFU_GCROOT_BASE lets
# the hermetic register test write roots into a temp dir instead of the real
# /nix/var tree. Defaults to the real gcroots path.
GCROOT_BASE="${MYCOFU_GCROOT_BASE:-/nix/var/nix/gcroots/pipelines}"

# Nix store prefix guard. Test seam: MYCOFU_NIX_STORE_PREFIX lets the hermetic
# register test point at a temp store. Defaults to the real store.
NIX_STORE_PREFIX="${MYCOFU_NIX_STORE_PREFIX:-/nix/store}"

# Stale-root reclaim window (minutes). MUST exceed the maximum pipeline
# wall-clock so a LIVE pipeline's roots are never swept out from under it. The
# longest observed pipeline (full build matrix + deploy) runs well under 3h;
# 360 min (6h) is a safe >2x margin. A root dir older than this belongs to no
# live pipeline, so reclaiming it cannot orphan a running deploy. Do NOT lower
# this below the max pipeline duration.
STALE_MMIN="${MYCOFU_GCROOT_STALE_MMIN:-360}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLOSURE_PATHS_FILE="${MYCOFU_CLOSURE_PATHS_FILE:-${REPO_DIR}/build/closure-paths.json}"

log() { echo "[ci-pipeline-gcroot] $*"; }
die() { echo "[ci-pipeline-gcroot] ERROR: $*" >&2; exit 1; }

require_pipeline_id() {
  [[ -n "${CI_PIPELINE_ID:-}" ]] \
    || die "CI_PIPELINE_ID is unset — must run inside a GitLab pipeline"
}

# Fail-closed reclaim. A pipeline that died between build:merge and
# deploy:control-plane:* would otherwise pin its closure against GC forever.
# Guarded so a diagnostic non-zero (empty base dir, missing dir, a concurrent
# sweep winning the race) cannot crash the job under `set -euo pipefail`
# (.claude/rules/platform.md).
sweep_stale() {
  [[ -d "${GCROOT_BASE}" ]] || return 0
  find "${GCROOT_BASE}" -mindepth 1 -maxdepth 1 -type d -mmin +"${STALE_MMIN}" \
    -exec rm -rf {} + 2>/dev/null || true
  log "swept pipeline GC roots older than ${STALE_MMIN} min"
}

# Pin one closure store path with a durable per-pipeline indirect GC root.
# Idempotent: `nix-store --add-root` atomically replaces any existing indirect
# root symlink, so a build:image pin followed by the build:merge batch re-pin of
# the same (host, path) both succeed. Shared by cmd_register (batch, from
# closure-paths.json) and cmd_register_closure (single host, explicit path).
pin_one() {
  local host="$1" path="$2" dir="$3"
  [[ -n "${host}" && -n "${path}" ]] || die "pin_one: empty host or path"
  [[ "${path}" == "${NIX_STORE_PREFIX}"/* ]] \
    || die "refusing non-store closure path for '${host}': ${path}"
  [[ -e "${path}" ]] \
    || die "closure for '${host}' already missing from local store: ${path}"
  # `-r` (--realise) is the REQUIRED operation. `nix-store --add-root …
  # --indirect` with NO operation errors "no operation specified" and fails on
  # every pipeline (the round-1 P1). --realise on an already-valid store path
  # just returns it and registers (or re-registers) the indirect root.
  nix-store --add-root "${dir}/${host}" --indirect -r "${path}" >/dev/null
  log "pinned ${host} -> ${path} (root ${dir}/${host})"
}

cmd_register() {
  require_pipeline_id
  sweep_stale
  [[ -s "${CLOSURE_PATHS_FILE}" ]] \
    || die "closure paths file not found or empty: ${CLOSURE_PATHS_FILE}"

  # Fail-closed parse. Capture jq's output AND exit status: a `done < <(jq …)`
  # process substitution hides jq's status, so a malformed non-empty JSON — or a
  # semantic `{}` with no control-plane hosts — would silently yield zero roots
  # and let build:merge PASS having pinned nothing (fail-OPEN, the #560 hole).
  local tsv jq_rc
  set +e
  tsv="$(jq -r 'to_entries[] | [.key, .value] | @tsv' "${CLOSURE_PATHS_FILE}")"
  jq_rc=$?
  set -e
  [[ ${jq_rc} -eq 0 ]] \
    || die "failed to parse closures (jq exit ${jq_rc}) from ${CLOSURE_PATHS_FILE}"
  [[ -n "${tsv}" ]] \
    || die "no closures to pin in ${CLOSURE_PATHS_FILE} (empty object?)"

  local dir="${GCROOT_BASE}/${CI_PIPELINE_ID}"
  mkdir -p "${dir}"

  local host path pinned=0
  while IFS=$'\t' read -r host path; do
    [[ -n "${host}" && -n "${path}" ]] || continue
    pin_one "${host}" "${path}" "${dir}"
    pinned=$((pinned + 1))
  done <<< "${tsv}"

  [[ "${pinned}" -ge 1 ]] \
    || die "pinned 0 closures from ${CLOSURE_PATHS_FILE} — refusing to fail open"
}

# register-closure <host> <path>: pin ONE control-plane closure the instant it is
# built in build:image[<host>], BEFORE any GC can run — closing the
# build:image -> build:merge window (issue #573). Does not read
# closure-paths.json (not composed until build:merge). Idempotent with the
# build:merge batch register; the die-guard in pin_one is the intended fail-closed
# signal if the just-built path is already gone.
cmd_register_closure() {
  require_pipeline_id
  local host="${1:-}" path="${2:-}"
  [[ -n "${host}" ]] || die "register-closure: missing host argument"
  [[ -n "${path}" ]] || die "register-closure: missing closure path argument"
  local dir="${GCROOT_BASE}/${CI_PIPELINE_ID}"
  mkdir -p "${dir}"
  pin_one "${host}" "${path}" "${dir}"
}

cmd_release() {
  require_pipeline_id
  local dir="${GCROOT_BASE}/${CI_PIPELINE_ID}"
  if [[ $# -eq 0 ]]; then
    rm -rf "${dir}" 2>/dev/null || true
    log "released all GC roots for pipeline ${CI_PIPELINE_ID}"
    return 0
  fi
  local host
  for host in "$@"; do
    rm -f "${dir}/${host}" 2>/dev/null || true
    log "released ${host} GC root for pipeline ${CI_PIPELINE_ID}"
  done
  # Prune the pipeline dir once the LAST consumer removed the LAST root. rmdir
  # succeeds only when empty, so the terminal control-plane deploy job (which
  # removes the last host) reclaims the dir; order-independent, and a still-
  # pending host keeps the dir alive. Cleanup is guarded (2>/dev/null || true):
  # release runs in the deploy job script, so a spurious cleanup error must
  # never fail an otherwise-successful deploy.
  rmdir "${dir}" 2>/dev/null || true
}

main() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    register)         cmd_register "$@" ;;
    register-closure) cmd_register_closure "$@" ;;
    release)          cmd_release "$@" ;;
    *) die "usage: $(basename "$0") {register|register-closure <host> <path>|release [host...]}" ;;
  esac
}

main "$@"
