#!/usr/bin/env bash
# gitlab-runner-store-verify.sh — #685 crash-residue sweep for cicd's nix store.
#
# Invoked as gitlab-runner.service ExecStartPre (see gitlab-runner.nix). The
# module wrapper runs it via an explicit `${pkgs.bash}/bin/bash` with nix and
# coreutils on PATH, so the shebang above is cosmetic (the same pattern as
# gitlab-runner-budget.sh) and the tests invoke it via `bash <script>` too.
#
# WHY: an interrupted nix eval/build on cicd (most commonly a
# control-plane-convergence runner restart aborting in-flight evals — #623 made
# runner restarts routine on control-plane closure changes, and the 2026-07-19
# queue-is-abortable ruling means convergence never waits for the CI queue) can
# leave store residue: a path written to disk whose DB registration never
# completed. The residue is invisible until a LATER job references the path, at
# which point nix fails loudly ("path ... is not valid") on a job whose own code
# is fine (observed: job 131466 / pipeline 1729; and again on 048 baseline and
# the 2026-07-23 prod-promotion #1796). nix heals this lazily — the next
# successful eval of the same derivation re-instantiates and registers the path —
# so the failure is a RACE against that healing window. Running
# `nix-store --verify --repair` at the same restart that mints the residue turns
# lazy, race-prone healing into eager, deterministic healing before any job runs.
#
# SCOPE: structural DB/disk pass only. We deliberately do NOT pass
# --check-contents. Full content hashing of cicd's ~150 GB store on every runner
# start is prohibitive, and the residue class this targets is unregistered /
# partially-materialised paths (a DB-vs-disk structural inconsistency), not
# silent bit-rot of otherwise-valid paths. Trade-off: a corrupted-but-registered
# path would not be caught here; that is not the observed failure class.
#
# FAIL-SAFE DIRECTION — start-with-alarm, NOT fail-closed. If verify/repair exits
# non-zero we log LOUDLY and start the runner anyway. Rationale:
#   - This unit's established doctrine is availability-first: "CI slow beats CI
#     dead" (see the wants-not-requires budget ordering and OOMPolicy=continue in
#     gitlab-runner.nix). A fail-closed ExecStartPre, combined with the unit's
#     Restart=on-failure, would trap the runner in a restart loop and take cicd
#     CI fully dark — a self-inflicted outage worse than the residue it guards.
#   - cicd is Tier-2: the pipeline cannot redeploy it, so a fail-closed block
#     would force a workstation operator to recover — a heavy response to a class
#     whose failures are LOUD and RETRYABLE (a red job that heals on the next
#     eval), never silent data loss.
#   - destruction-safety's FAIL-not-SKIP doctrine governs safety checks that
#     guard IRREVERSIBLE operations, where a false "clean" hides danger. This hook
#     guards no destructive op and hides nothing: a non-zero verify is surfaced
#     loudly in the journal (the sanctioned human channel). The doctrine's real
#     requirement — never SILENTLY proceed as if clean — is met by the alarm, not
#     by blocking start. That is the reconciliation, not a waiver.
#
# NOTE (out of scope, tracked separately): this hook sweeps residue that exists
# AT START. Residue minted mid-uptime survives until the next restart; a periodic
# or pre-heavy-eval verify was raised on #685 (2026-07-23) and is deliberately
# left for a measured follow-up rather than built here.
set -uo pipefail

log() { echo "runner-store-verify: $*" >&2; }

# Bound the pass strictly below gitlab-runner.service's TimeoutStartSec (600s,
# set in gitlab-runner.nix). This bound is LOAD-BEARING for start-with-alarm:
# ExecStartPre time counts against the unit's start timeout, and an UNBOUNDED
# verify on cicd's ~150 GB store could exceed it — at which point systemd
# SIGKILLs this process BEFORE `exit 0` runs, the unit enters `failed`, and
# Restart=on-failure re-runs it: the exact tier-2-dark restart loop this design
# exists to prevent (adversarial review, unanimous P1). `timeout` guarantees we
# always reach `exit 0` first; the internal bound (default 300s) sits well under
# the 600s systemd window so systemd never kills us mid-pass. On expiry the
# residue is left for nix's lazy re-instantiation (the pre-fix status quo) — a
# runner that starts slightly un-swept beats a runner that never comes up.
STORE_VERIFY_TIMEOUT="${STORE_VERIFY_TIMEOUT:-300}"

log "nix store DB/disk consistency pass (verify --repair, structural; no --check-contents; bound ${STORE_VERIFY_TIMEOUT}s)"
rc=0
timeout "${STORE_VERIFY_TIMEOUT}" nix-store --verify --repair || rc=$?
if [ "$rc" -eq 0 ]; then
  log "store consistent (verify --repair completed cleanly)"
elif [ "$rc" -eq 124 ]; then
  log "WARNING: verify --repair exceeded ${STORE_VERIFY_TIMEOUT}s and was bounded; starting runner anyway (start-with-alarm)."
  log "WARNING: store consistency unconfirmed this start — nix's lazy re-instantiation still heals residue on the next successful eval; investigate if red jobs recur."
else
  log "WARNING: nix-store --verify --repair exited ${rc} (errors may remain, or the pass was interrupted); starting runner anyway (start-with-alarm)."
  log "WARNING: cicd nix store may carry unrepaired residue — investigate; do NOT dismiss red jobs as transient."
fi

# Start-with-alarm: never block the runner's start transaction on the verify outcome.
exit 0
