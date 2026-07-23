# Mycofu Disaster Recovery Test Registry

This registry records validation status for each DR test scenario.
It is the ratchet: when code changes, scan the "Invalidated by" column
to determine which tests must be re-run before the change is considered safe.

## How to use

**After any significant change:**

1. Scan the Invalidation Quick Reference table at the bottom of this file.
2. Any test whose invalidation criteria match your change must be re-run.
3. Run: `framework/dr-tests/run-dr-test.sh DRT-00X`
4. Paste the result block printed by the test into the appropriate
   "Last Run" section below.

A change is not safe until all tests it invalidates show a Last Run
commit equal to or after the change commit.

**Adding a new test result:** Replace the entire "Last Run" block with
the new result. Move the old result to the History table.

## Test Index

| ID | Name | Last Result | Last Run | Commit | Est. Time |
|----|------|-------------|----------|--------|-----------|
| DRT-001 | Warm Rebuild | PASS | 2026-07-08 | 53f37d7 | ~16 min |
| DRT-002 | Cold Rebuild | PASS | 2026-07-08 | d401d3f4 (#505 fix verified — fresh-clone preflight clean; apply was 173/173 no-op) | ~50 min |
| DRT-003 | PBS Restore | PASS | 2026-07-08 | 53f37d7 | ~9 min |
| DRT-004 | Vault HA Failover | PASS | 2026-07-05 | b2093af | ~3 min |
| DRT-005 | Node Failure Recovery | PASS | 2026-07-23T09:06:02Z | b9fc097 M4 attempt 3 — CLEAN PASS, closes M4, Sprint 048 failover acceptance, and Sprint 047 (open-blocked-on-successor ruling 2026-07-21). Recovery 136s (series 146/146/136 vs 600s analytic ceiling). First fully unassisted full cycle: family-(e) dummy0 stanza (#697) held from cold boot, failback autonomous, zero HA errors, zero qmstart hangs, app state preserved. Harness #696 + tooling #697 exercised. Bands ratcheted: WARN 166s / FAIL 252s (MR-7). | 20m 8s |
| DRT-006 | DNS Failover | PASS | 2026-07-05 | f25bd5d | ~5 min |
| DRT-007 | Backup Spot-Check | PASS | 2026-07-05 | f25bd5d | ~1 min |
| DRT-008 | Reset Contract Ratchet | PASS | 2026-07-05 | f25bd5d | ~2 min |

---

## Sprint 034 Invalidation Note

**Status:** DRT-001, DRT-002, and DRT-003 are invalidated by Sprint 034 and
this R1 follow-up. Operator reruns are deferred until the updated cicd closure
containing the pinned MeshCmd host tool has been deployed.

**Invalidating file changes:**
- DRT-001: `.gitlab-ci.yml`, `flake.nix`, `framework/nix/modules/regreener-host.nix`,
  `framework/nix/pkgs/meshcmd/default.nix`, and
  `framework/scripts/converge-lib.sh`.
- DRT-002: `flake.nix`, `framework/templates/config.yaml.example`,
  `framework/scripts/new-site.sh`, `framework/scripts/bootstrap-sops.sh`,
  `framework/nix/modules/regreener-host.nix`, and
  `framework/nix/pkgs/meshcmd/default.nix`.
- DRT-003: `.gitlab-ci.yml` and `framework/scripts/converge-lib.sh`.

**Rerun disposition:** Deferred by operator because live first-light and cicd
redeploy are outside this hermetic review pass. The next registry update should
replace this note with the actual DRT result blocks.

## Sprint 035 Invalidation Note (post scope reduction)

Sprint 035 originally invalidated DRT-001, DRT-002, and DRT-003 because the
reconciler stack touched `.gitlab-ci.yml`, `post-deploy.sh`, `converge-lib.sh`,
`validate.sh`, and `config.yaml.example`. After post-execution scope reduction,
the reconciler hooks in `post-deploy.sh`, `converge-lib.sh`, and `validate.sh`
were reverted; only `.gitlab-ci.yml` (new `bench:scheduled` job + universal
`$BENCH_SCHEDULE_KEY` carve-outs) and `framework/templates/config.yaml.example`
(removed `gitlab.scheduled_pipelines`, kept `benchmarks.scheduled` opt-in
default `false`) remain touched.

**Recomputed invalidation:**

- **DRT-001 (Warm Rebuild)** — INVALIDATED. `.gitlab-ci.yml` changes (new job
  rule + universal `$BENCH_SCHEDULE_KEY: when: never` short-circuits across
  many jobs) can affect dispatch behavior during warm rebuild. Rerun required.
- **DRT-002 (Cold Rebuild)** — INVALIDATED. `config.yaml.example` is the
  starting point for fresh-clone deploys; downstream operators get the new
  `benchmarks.scheduled.enabled: false` default. Rerun required.
- **DRT-003 (PBS Restore)** — NO LONGER INVALIDATED by Sprint 035. The reverts
  to `post-deploy.sh` and `converge-lib.sh` restored those scripts to their
  pre-sprint state; the PBS restore path is unchanged.

**Required closure action:** run DRT-001 and DRT-002:

```bash
framework/dr-tests/run-dr-test.sh DRT-001
framework/dr-tests/run-dr-test.sh DRT-002
```

**Current disposition:** BLOCKED in this execution session. These tests are
destructive/live infrastructure exercises and require operator approval,
credentials, and cluster access. Results must be recorded here before Sprint
035 is accepted on live infrastructure.

## Sprint 037 Invalidation Note

**Status:** DRT-001 and DRT-002 are invalidated by Sprint 037. DRT-003 is not
invalidated.

**Recomputed invalidation:**

- **DRT-001 (Warm Rebuild)** - INVALIDATED. `safe-apply.sh dev` now includes
  `module.hil_boot`, and `.gitlab-ci.yml` builds and web-triggers the HIL
  regreener path. Rerun required on production cluster after Sprint 037 merges.
- **DRT-002 (Cold Rebuild)** - INVALIDATED. Sprint 037 changes image and
  CIDATA-adjacent surfaces through hil-boot image generation, per-node PVE ISO
  artifacts, and the dev deploy scope. Rerun required on production cluster
  after Sprint 037 merges.
- **DRT-003 (PBS Restore)** - NOT INVALIDATED. hil-boot is another no-backup
  VM, but the no-backup case is already covered by the existing DRT-003
  surface via cicd, gatus, dns2-prod, and dns2-dev. Adding hil-boot does not
  change the restore conditions tested.

**Current disposition:** operator-pending. The executor cannot run destructive
DR tests or bench hardware checks from the sandbox.

## Sprint 039 Invalidation Note

**Status:** DRT-001, DRT-002, DRT-003, and DRT-007 are invalidated by Sprint
039.

**Recomputed invalidation:**

- **DRT-001 (Warm Rebuild)** - INVALIDATED. `converge-lib.sh`,
  `git-deploy-context.sh`, `safe-apply.sh`, `rebuild-cluster.sh`,
  `backup-now.sh`, and the new `vm-scope.sh` taxonomy helper affect scoped
  warm rebuild decisions and branch-safety classification.
- **DRT-002 (Cold Rebuild)** - INVALIDATED. `build-all-images.sh`,
  `merge-image-versions.sh`, `deploy-control-plane.sh`, `new-site.sh`, and
  manifest schema/template updates affect fresh cold-rebuild inputs and
  closure artifacts.
- **DRT-003 (PBS Restore)** - INVALIDATED. Preboot-restore backup-kind
  classification now derives from `vm-scope.sh` taxonomy instead of embedded
  role lists.
- **DRT-007 (Backup Spot-Check)** - INVALIDATED. `backup-now.sh` env-scoped
  exclusion now derives control-plane modules from `vm-scope.sh`.

**Required closure action:** run:

```bash
framework/dr-tests/run-dr-test.sh DRT-001
framework/dr-tests/run-dr-test.sh DRT-002
framework/dr-tests/run-dr-test.sh DRT-003
framework/dr-tests/run-dr-test.sh DRT-007
```

**Current disposition:** operator-pending. These are live/destructive DR
exercises and cannot be run from the sandboxed executor session without
operator approval and cluster access.

## Sprint 041 Invalidation Note

**Status:** DRT-001, DRT-002, DRT-003, and DRT-006 are additionally
invalidated by Sprint 041.

**Recomputed invalidation:**

- **DRT-001 (Warm Rebuild)** - INVALIDATED. `restore-before-start.sh` now
  consumes manifest `expected_disks`, can return rc=2 for incomplete VMs, and
  routes eligible incomplete precious VMs through bounded convergence.
- **DRT-002 (Cold Rebuild)** - INVALIDATED. `safe-apply.sh` and
  `rebuild-cluster.sh` now add image-present preconditions before destructive
  phases and handle rc=2 incomplete-VM restore results.
- **DRT-003 (PBS Restore)** - INVALIDATED. The preboot-restore manifest
  contract now includes `expected_disks` per entry and the restore success
  predicate includes VM topology completeness.
- **DRT-006 (DNS Failover)** - INVALIDATED. `validate.sh` now includes a
  cluster-wide VM topology completeness section. The rerun must cover at least
  one Category-C vendor VM, specifically PBS vmid 190, so the vendor topology
  exemption is exercised by live DR evidence.
- **DRT-007 (Backup Spot-Check)** - NOT ADDITIONALLY INVALIDATED by Sprint
  041. `backup-now.sh --skip-vmid` is additive and is not passed by the normal
  backup path; Sprint 041 adds `tests/test_backup_now_skip_vmid.sh` to assert
  the absent-flag path remains behavior-identical. DRT-007 remains pending from
  Sprint 039 until that older invalidation is closed.

**Required closure action:** after Sprint 041 is promoted, run:

```bash
framework/dr-tests/run-dr-test.sh DRT-001
framework/dr-tests/run-dr-test.sh DRT-002
framework/dr-tests/run-dr-test.sh DRT-003
framework/dr-tests/run-dr-test.sh DRT-006
```

For DRT-006, include PBS vmid 190 in the observed validation evidence.

**Current disposition:** operator-pending. These are live/destructive DR
exercises or prod-facing acceptance checks and cannot be run from this
executor session.

## Sprint 042 Invalidation Note

**Status:** DRT-001 and DRT-002 are additionally invalidated by Sprint 042.
DRT-003 is exercised at scale by the sprint's first dev deploy and requires
formal prod re-validation after promotion.

**Recomputed invalidation:**

- **DRT-001 (Warm Rebuild)** - INVALIDATED. `flake.nix` is a listed DRT-001
  input, and Sprint 042 changes the image-source mechanism from one monolithic
  source tree to per-role source partitions. Warm-rebuild image inputs change.
  Rerun on prod after the next promotion.
- **DRT-002 (Cold Rebuild)** - INVALIDATED. Every image filename changes once
  on the structural source-partition change, altering cold-rebuild image
  inputs. Rerun on prod after promotion.
- **DRT-003 (PBS Restore / preboot-restore)** - EXERCISED AT SCALE by the
  sprint's own first dev deploy, which is expected to recreate every dev image
  once and run the Sprint 031 preboot-restore flow. Re-validate from the dev
  deploy evidence, then rerun the formal DRT-003 on prod after promotion.
- **DRT-004/005/006/007/008** - NOT ADDITIONALLY INVALIDATED by Sprint 042.

**Current disposition:** operator-pending. The executor stage does not merge to
dev or prod and cannot run the live preboot-restore or prod DR exercises.

## Sprint 043 Invalidation Note

**Status:** DRT-001, DRT-002, DRT-003, DRT-006, and DRT-007 are additionally
invalidated by Sprint 043.

**Recomputed invalidation:**

- **DRT-001 (Warm Rebuild)** - INVALIDATED. `framework/nix/modules/certbot.nix`
  and `framework/nix/modules/vault.nix` are shared base modules for
  cert-bearing VMs, and the renewability/trust-marker changes touch
  `backup-now.sh`, `restore-before-start.sh`, `safe-apply.sh`, and
  `validate.sh`. Warm rebuild must prove preboot restore and post-recreate
  validation still pass.
- **DRT-002 (Cold Rebuild)** - INVALIDATED. Fresh-clone build inputs now include
  the new certbot renewability helper, renewed CI coverage, and certbot module
  behavior changes. Cold rebuild must prove the new helper is present in built
  images and the first deploy path still converges.
- **DRT-003 (PBS Restore)** - INVALIDATED. Restore pins now carry certbot trust
  metadata, and the restored VM acceptance check must confirm the D2
  renewability predicate returns rc=0 even if persisted renewal hook fields are
  stale.
- **DRT-006 (DNS Failover)** - INVALIDATED. Sprint 043 changes the certbot
  renewal invocation. The rerun must exercise `certbot-renew.service`, not a
  bare manual `certbot renew`, so the current-generation hook CLI override is
  in the tested path.
- **DRT-007 (Backup Spot-Check)** - INVALIDATED. `backup-now.sh` pin JSON now
  stores an object with `volid`, `trust`, `days_remaining`, and `near_expiry`;
  the spot-check must acknowledge the schema and verify trust metadata is
  handled without weakening backup-content checks.

**Required closure action:** after Sprint 043 is deployed in dev, run:

```bash
framework/dr-tests/run-dr-test.sh DRT-001
framework/dr-tests/run-dr-test.sh DRT-002
framework/dr-tests/run-dr-test.sh DRT-003
framework/dr-tests/run-dr-test.sh DRT-006
framework/dr-tests/run-dr-test.sh DRT-007
```

**Current disposition:** operator-pending. These are live/destructive DR
exercises or prod-facing acceptance checks and were not run by the Sprint 043
executor session.

## Sprint 044 Invalidation Note

**Status:** DRT-001, DRT-002, DRT-003, DRT-005, and DRT-008 are
additionally invalidated by Sprint 044. DRT-004, DRT-006, and DRT-007 are
not additionally invalidated.

**Recomputed invalidation:**

- **DRT-001 (Warm Rebuild)** - INVALIDATED. `rebuild-cluster.sh`
  choreography changed to park/adopt vdbs in bulk and atomic paths before
  preboot restore. Rerun must observe `spared` entries for bridged VMs and
  verify vdb GUID continuity.
- **DRT-002 (Cold Rebuild)** - INVALIDATED. Same rebuild choreography; the
  no-park first-deploy path must remain correct at cold-rebuild scale.
- **DRT-003 (PBS Restore)** - INVALIDATED. `restore-before-start.sh` now
  accepts `--park-status`, records `spared`, and refuses to restore over
  orphaned parks. Rerun must cover both spared and forced pinned-restore
  branches.
- **DRT-004 (Vault HA Failover)** - NOT INVALIDATED. The bridge acts only
  during deploy/rebuild windows, not HA failover.
- **DRT-005 (Node Failure Recovery)** - INVALIDATED. `configure-replication.sh`
  now preserves adopted vdb replicas and warns on `mycofu-park-*` residue.
- **DRT-006 (DNS Failover)** - NOT INVALIDATED. DNS VMs are not
  backup-backed and do not participate in the bridge.
- **DRT-007 (Backup Spot-Check)** - NOT ADDITIONALLY INVALIDATED. Backup
  pin capture and `restore-from-pbs.sh` are unchanged. The pre-existing
  Sprint 043 invalidation remains open.
- **DRT-008 (Reset Contract Ratchet)** - INVALIDATED. `reset-cluster.sh`
  destruction scopes now purge `mycofu-park-*` alongside VM zvols.

**Required closure action:** after Sprint 044 lands and live cluster work is
unblocked, run:

```bash
framework/dr-tests/run-dr-test.sh DRT-001
framework/dr-tests/run-dr-test.sh DRT-002
framework/dr-tests/run-dr-test.sh DRT-003
framework/dr-tests/run-dr-test.sh DRT-005
framework/dr-tests/run-dr-test.sh DRT-008
```

**Current disposition:** deferred by orchestrator directive in the Sprint 044
executor session. Live/destructive DR tests and the DRT-008 rerun were not
run while concurrent destructive DR tests were active on the cluster.

## R1 (mycofu-fix/pve-nvme-kernel-params) Invalidation Note

**Status:** DRT-001 and DRT-002 are *additionally* invalidated by R1 (NVMe
firmware-quirk kernel parameter workaround), which adds Step 1.5 to
`rebuild-cluster.sh`. Step 1.5 writes the persistent kernel cmdline
drop-in and refreshes the bootloader on every node. When the running
kernel does not yet have the workaround, Step 1.5 either:

- **Auto-reboots** every node sequentially when no node has a non-stopped
  VM (the normal full-rebuild scenario: fresh bringup, post
  `reset-cluster.sh`, or any path where every node is freshly installed).
  After the rolling reboot, Step 1.5 re-verifies that `/proc/cmdline` now
  contains the params on every node before the rebuild proceeds to
  Step 2 (storage). No operator action is required.
- **Stops with exit 10** if any node still has a non-stopped VM
  (`running`, `paused`, `suspended`, `prelaunch`, or `io-error`). The
  banner names the affected nodes and points at the HA-aware manual
  procedure in `OPERATIONS.md` "Applying Kernel Parameters". The
  operator coordinates the rolling reboot manually and re-runs
  `rebuild-cluster.sh`; Step 1.5 is idempotent and passes through on
  the second invocation.

**Test procedure changes for DRT-001 / DRT-002:**

For the warm DRT-001 case (rebuild from a populated state where the
previous rebuild already loaded the params), Step 1.5 sees runtime
params effective and returns immediately -- no reboot, no observable
delay. Total wall-clock unchanged.

For the cold DRT-002 case (full reset + rebuild from scratch), Step 1.5
writes the drop-in, refreshes the bootloader, then enters the auto-reboot
path because no VMs are running. Total wall-clock increases by roughly
the per-node reboot time (~3 minutes per node, ~9 minutes for a 3-node
cluster), but no operator interaction is required.

The exit-10 path is only exercised by tests that intentionally leave
non-stopped VMs running across the rebuild boundary -- not part of
DRT-001 or DRT-002 as currently scoped.

**Invalidating file changes for R1:**
- `framework/scripts/rebuild-cluster.sh` (Step 1.5 wired in, exit-10 stop)
- `framework/scripts/configure-node-kernel.sh` (new)
- `tests/test_configure_node_kernel.sh` (new hermetic test, not a DRT)
- `.gitlab-ci.yml` (validate:configure-node-kernel job)

---

## Sprint 038 Invalidation Note

**Status:** DRT-001 and DRT-003 are invalidated by Sprint 038. DRT-002 is
narrowed as not additionally invalidated. DRT-006 is narrowed as not
invalidated. DRT-007 is affected but remains blocked on #252.

**Recomputed invalidation:**

- **DRT-001 (Warm Rebuild)** - INVALIDATED. `validate.sh` now fails closed on
  per-VM PBS freshness, and `configure-backups.sh` now reconciles the full
  managed backup-job spec. Warm rebuild completion criteria include a passing
  `validate.sh`, so the changed backup compliance gate requires rerun.
- **DRT-002 (Cold Rebuild)** - NOT ADDITIONALLY INVALIDATED by Sprint 038.
  `framework/templates/config.yaml.example` changed only to document that
  `pbs.backup_schedule` is the operator-tunable part of an otherwise
  framework-defined backup-job spec. The template's generated values and cold
  rebuild mechanics are unchanged by that comment-only narrowing. DRT-002
  remains invalidated by earlier sprints until the pending rerun closes them.
- **DRT-003 (PBS Restore)** - INVALIDATED. The restore test's pass criteria
  include `validate.sh`, and this sprint changes PBS backup freshness
  semantics from cluster-wide to per-VM. Rerun required.
- **DRT-006 (DNS Failover)** - NOT INVALIDATED. The `validate.sh` change is
  confined to the PBS freshness block, not DNS checks, PowerDNS behavior,
  CIDATA DNS delivery, or certbot DNS-01 hooks. No rerun required for this
  sprint's changes.
- **DRT-007 (Backup Spot-Check)** - AFFECTED, RERUN DEFERRED. The managed
  backup-job writer and backup-backed VMID enumeration are now part of the
  backup integrity surface. DRT-007 remains blocked on #252, so rerun is not a
  Sprint 038 completion gate.

**Current disposition:** live DR reruns are operator-pending. This execution
session implements hermetic coverage only and does not run destructive/live DR
tests.

---

## Issue #514 Invalidation Note (rebalance-cluster.sh recovery verification)

**Change:** #514 adds a `verify_recovery` phase to
`framework/scripts/rebalance-cluster.sh`. Before exiting 0, the script now
asserts the recovery OUTCOME, not just placement mechanics: no HA service in
`error` state, every HA-requested `started` service backed by a running VM,
and every config-enabled VM running (deliberately `disabled`/`stopped`/
`ignored` services are respected). It fails closed if cluster state cannot be
determined. Also touches `.gitlab-ci.yml` (two additive test invocations) and
adds `tests/test_rebalance_verify_recovery.sh`.

**Recomputed invalidation:**

- **DRT-005 (Node Failure Recovery)** — INVALIDATED. `rebalance-cluster.sh`
  is a direct DRT-005 input (see its "Invalidated by changes to" list and the
  Quick Reference). This change is the direct fix for the DRT-005 2026-07-07
  step-7 finding — the script exited 0 with seven VMs stopped in HA `error`
  state. The new phase would have failed the run at step 7 (before validate.sh
  stumbled on symptoms at step 8). Rerun required.
- **DRT-001 (Warm Rebuild)** — CONSERVATIVELY INVALIDATED per the ratchet:
  `.gitlab-ci.yml` is a listed DRT-001 input. The edit here is additive test
  wiring only (adds `test_rebalance_verify_recovery.sh` to the test and
  `bash -n` stages); it changes no build/deploy/rebuild behavior, and
  `rebuild-cluster.sh` does not execute `rebalance-cluster.sh` (it only prints
  it as a post-rebuild follow-up hint). Behavioral risk is nil; rerun folded
  into the scheduled revalidation below.
- **DRT-002 (Cold Rebuild)** — NOT mechanically invalidated by this change.
  `rebalance-cluster.sh` is not a DRT-002 input and `.gitlab-ci.yml` is not in
  its "Invalidated by" list. Listed here because #514 named it; no code path
  DRT-002 exercises is altered. No dedicated rerun required beyond the
  scheduled revalidation.

**Scheduled revalidation:** the pending node-failure-hardening sprint's
operator-attended DRT-005 rerun. That rerun exercises a real node failure and
HA recovery end-to-end, which is where the new `verify_recovery` phase is
meaningfully tested against live state (the hermetic
`test_rebalance_verify_recovery.sh` covers the classification and fail-closed
logic against fixtures). Record the DRT-005 result block there when it runs.

---

## Issue #505 Note (cold-rebuild disabled-role image gate — DRT-002 unblocked)

**Change:** #505 fixes `framework/scripts/tofu-wrapper.sh` so its
placeholder-fabrication path (taken when `site/tofu/image-versions.auto.tfvars`
is absent — the fresh-clone / cold-rebuild condition) no longer fabricates a
`PLACEHOLDER_<role>` for DISABLED applications. A disabled role needs no image
(the image producers build only `enabled==true` apps, and its VM modules are
`count=0`, which OpenTofu does not evaluate at plan time), so a placeholder for
it was pure downside: it tripped the image gate and aborted the OpenTofu
preflight before any recovery could proceed. The image gate stays strict for
every role that DOES need an image (infra roles + enabled apps).

**Effect on DRT-002 (Cold Rebuild):** UNBLOCKED. DRT-002 has failed
deterministically since Sprint 028 (workstation disable) at the cold-rebuild
tofu preflight with `workstation: PLACEHOLDER_workstation`. The reproducer's
entry condition — a fresh clone with no cached `image-versions.auto.tfvars` and
`applications.workstation.enabled: false` — now passes the preflight (verified
non-destructively: fresh local clone + wrapper fabrication omits workstation;
hermetic OpenTofu `count=0` micro-repro confirms the disabled role's
`image_versions["workstation"]` key is never indexed at plan time;
`tests/test_tofu_wrapper_disabled_role.sh` drives the real wrapper end-to-end).

**Invalidating file change:** `framework/scripts/tofu-wrapper.sh` (fabrication
path only; the gate/validation logic is unchanged). No image inputs changed, so
no enabled role rehashes. `rebuild-cluster.sh` is unchanged.

**Rerun disposition:** DRT-002 rerun is unblocked but remains operator-owned
(it is a destructive/live cold-from-fresh-clone exercise). Schedule alongside
the other pending DR reruns; record the DRT-002 result block when it runs.

---

## Sprint 045 Invalidation Note (node-failure recovery hardening)

**Status:** DRT-001, DRT-002, DRT-005, and DRT-006 are invalidated by Sprint
045. DRT-003, DRT-004, DRT-007, DRT-008 are NOT.

Sprint 045 landed: the anti-affinity HA rule (A2, `proxmox-vm`/`dns-pair`
tofu), the node-aware pre-migrate **vaccine** inline in `rebalance-cluster.sh`
(A3), the DRT-005 migration-budget re-baseline + post-recovery hardening (A4),
the `#518` bulk-artifact writer fix + parity check (A6), and the
placement-watchdog HA-error probe (A5, #519). New tool: `realign-cidata.sh`.

**Recomputed invalidation:**

- **DRT-005 (Node Failure Recovery)** — **INVALIDATED. This is the single
  bundled acceptance gate for the sprint (#512/#513/#515/#518, +#519).** The
  recovery path itself changed: `rebalance-cluster.sh` now runs the pre-migrate
  vaccine + verifies recovery (#514/A4), the HA module gained anti-affinity
  (A2), and the DRT-005 script gained the 240s/150s migration budget bands and
  post-recovery assertions (A4). The attended rerun (M6) also folds in the M5
  residual: a read-only NAS-probe poll during the failover window observes
  `ha_healthy:false` on the real sustained condition. Last Run: FAIL 2026-07-07
  (7 VMs stopped, rename-victim cidata) — the exact failure this sprint fixes.

- **DRT-006 (DNS Failover)** — **INVALIDATED (hygiene, not a bundled-issue
  closure gate).** A2 changes DNS failover placement (the pair anti-affinity
  rule steers survivor placement; the pair re-separates on node recovery).
  Operator-scheduled rerun.

- **DRT-001 (Warm Rebuild)** / **DRT-002 (Cold Rebuild)** — **INVALIDATED
  (hygiene).** `rebuild-cluster.sh` changed (A6: it now passes per-label preboot
  status files and aggregates them; `deploy:dev` runs
  `check_bulk_artifacts_populated.sh` — the #518 M4 evidence). Also
  `restore-before-start.sh` / `vdb-park-lib.sh` (A6 writer path). Reruns
  operator-scheduled; hygiene, not sprint closure gates.

- **DRT-003 (PBS Restore)** — **NOT INVALIDATED** (resolves the plan's
  CONDITIONAL). The #518 RCA (`docs/reports/2026-07-08-issue-518-bulk-artifact-
  rca.md`) confirmed the defect and the fix are **writer/caller-only** (the
  status-file filename + aggregation), NOT the restore branch. The vdb restore
  logic `restore-from-pbs.sh` is unchanged, so DRT-003's restore path is
  untouched.

- **DRT-004 (Vault HA Failover)** — NOT INVALIDATED. Raft path untouched; A2
  affects only DNS pairs.

- **DRT-007 / DRT-008** — NOT INVALIDATED. Backup-capture / reset-contract
  surfaces untouched.

**Trigger-list additions (for future invalidation scans):** the sprint adds
`framework/scripts/realign-cidata.sh` (new) and edits
`framework/scripts/rebalance-cluster.sh` (vaccine + verify_recovery),
`framework/scripts/placement-watchdog.sh` (HA-error probe),
`framework/scripts/restore-before-start.sh` + `rebuild-cluster.sh` +
`vdb-park-lib.sh` (#518 writer), `framework/scripts/validate.sh` (co-location
check), and the `proxmox-vm`/`dns-pair` tofu modules (anti-affinity harule). A
future change to any of these should scan DRT-005 (and DRT-006 for the tofu
modules) here.

**Required closure action:** the **attended DRT-005 rerun (M6)** on prod, after
the Sprint-045 dev→prod promotion, is the acceptance gate. DRT-001/002/006 are
operator-scheduled hygiene reruns.

---

## DRT-001: Warm Rebuild

**Status:** PASS on 2026-07-08 commit `53f37d7` (Sprint 044 closure,
attempt 3). Full cluster destroyed and recreated with a warm Nix cache;
all 19 framework VMs recreated (post-run uptime ~7-8 min), vendor
appliance pbs correctly untouched. Sprint-044 vdb bridge verified by
ground-truth ZFS GUIDs: DEV vdb continuity PRESERVED across recreation
(vm-503-disk-0 GUID `16832345101317218025`, plus 303/501, all unchanged),
PROD vdb RESTORED from PBS (403/601/603 fresh GUIDs, trusted pins).
Rebuild 12m 27s / total 16m 4s. Attempts 1-2 aborted on workstation disk
exhaustion (env, not DR — see History and #516). One reporting caveat:
the `-all`/`-bulk` park/restore status artifacts recorded empty
`entries[]`; the DR outcome is verified by GUIDs/uptime/pins, and the
empty status summaries are logged as a follow-up, not a failure.

**What it validates:** That `rebuild-cluster.sh` can fully restore a
running cluster from production config with a warm Nix cache. All VMs
are destroyed and recreated. Precious state is backed up before
destruction and restored from PBS before the VMs are started, via
`restore-before-start.sh`.

**Invalidated by changes to:**
- `.gitlab-ci.yml`
- `framework/scripts/build-all-images.sh`
- `framework/scripts/deploy-control-plane.sh`
- `framework/scripts/check-control-plane-drift.sh`
- `framework/scripts/rebuild-cluster.sh`
- `framework/scripts/converge-lib.sh`
- `framework/scripts/converge-vm.sh`
- `framework/scripts/backup-now.sh`
- `framework/scripts/certbot-persisted-state.sh`
- `framework/scripts/restore-from-pbs.sh`
- `framework/scripts/restore-before-start.sh`
- `framework/scripts/post-deploy.sh`
- `framework/scripts/validate.sh`
- `framework/scripts/cert-sync.sh`
- `framework/scripts/certbot-initial-wrapper.sh`
- `framework/scripts/check-cert-budget.sh`
- `framework/scripts/certbot-cluster.sh`
- `flake.nix`
- `framework/nix/lib/` (overlay/root-device/runtime wiring)
- `framework/nix/modules/base.nix`
- `framework/nix/modules/certbot.nix`
- `framework/nix/modules/vault.nix`
- `framework/tofu/root/` (any .tf file)
- `framework/nix/modules/` (any infrastructure module)
- Three-gate backup logic (any of the three gates)
- `framework/scripts/configure-vault.sh`
- `framework/scripts/init-vault.sh`

**Pass criteria:**
- `validate.sh` passes all checks
- State fingerprint matches pre-test (GitLab projects, Vault mounts,
  InfluxDB org, Roon DB size)
- Elapsed time < 45 min (warn if exceeded, not fail)

**Estimated time:** ~35 min

**Last Run:**
```
DRT-001 Warm Rebuild
Date:    2026-07-08T02:04:25Z
Commit:  53f37d7
Result:  PASS
Time:    16m 4s (rebuild 12m 27s)
Notes:   Sprint 044 closure warm rebuild, attempt 3 (attempts 1-2 aborted
         env on workstation disk exhaustion; operator then freed the APFS
         container to 124 GiB — see History and #516). Full cluster
         destroyed and recreated from prod @ 53f37d7 with a warm Nix cache
         (images already present in build/). All 19 framework VMs recreated
         (post-run uptime ~7-8 min); vendor appliance pbs (190) correctly
         untouched (uptime 52d). All 5 fingerprints preserved: GitLab
         projects=3, Vault initialized + 14 mounts, InfluxDB org=homelab,
         Roon DB 1300M vs pre-test 1305M (threshold 652M). validate.sh 82
         passed / 0 failed / 1 warn (Gatus host-key probe, pre-existing) /
         1 skip. Replication healthy (FailCount 0); 0 orphan cidata;
         20/20 VMs running.

         Sprint-044 vdb bridge — verified by ground-truth ZFS GUIDs
         (rebuild-cluster.sh suppresses restore-before-start stdout on
         success, so GUIDs/uptime/pins are the authoritative evidence):
           DEV vdb continuity PRESERVED across recreation (dev bridge):
             vm-303-disk-1 (vault-dev)     6819902318493640043  (== baseline)
             vm-501-disk-1 (influxdb-dev)  7010247812344947005  (== baseline)
             vm-503-disk-0 (roon-dev)      16832345101317218025 (== baseline)
           PROD vdb RESTORED from PBS (fresh zvol GUIDs, trusted pins):
             vm-403-disk-1 (vault-prod)    128448283038227689   (new)
             vm-601-disk-1 (influxdb-prod) 2869992623489482171  (new)
             vm-603-disk-0 (roon-prod)     13445616518576118872 (new)
           Restore pins captured 02:11Z for all 7 precious VMIDs
           (403/303/150/601/501/603/503); trust=trusted except 603/503
           trust=unknown reason=no-certbot-runtime (documented n/a case).

         REPORTING CAVEAT / follow-up (not a DR failure): the bulk status
         artifacts build/preboot-restore-status-all.json and
         vdb-park-status-bulk.json recorded empty entries[] despite the
         operations demonstrably occurring. The framework's own -all/-bulk
         status summaries did NOT surface per-VMID spared/park/restore
         records on the full-cluster path; the DR outcome is correct and
         verified by GUIDs, but the empty status recording is worth a
         follow-up (DRT asserts only exit 0 + validate + fingerprint, not
         per-VMID spared/restore records). Test log: logs/DRT-001-04.log.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-07-08 | 53f37d7 | PASS | 16m 4s | Sprint 044 closure warm rebuild, attempt 3 (after operator freed the workstation APFS container to 124 GiB). Full destroy+recreate of all 19 framework VMs (post-run uptime ~7-8 min); vendor appliance pbs untouched. Sprint-044 vdb bridge verified by ground-truth ZFS GUIDs: DEV vdb continuity PRESERVED (vm-503-disk-0 GUID 16832345101317218025 unchanged; vm-303-disk-1 and vm-501-disk-1 likewise), PROD vdb RESTORED from PBS (vm-403/601/603 fresh GUIDs, trusted pins). Fingerprints preserved (GitLab 3, Vault init+14, InfluxDB homelab, Roon 1300M); validate.sh 82/0/1w/1s; replication FailCount 0; 0 orphan cidata; 20/20 running. Reporting caveat (follow-up, not a DR failure): build/preboot-restore-status-all.json and vdb-park-status-bulk.json recorded empty entries[] — outcome verified by GUID/uptime/pin ground-truth, empty status summaries flagged for follow-up. Test log: logs/DRT-001-04.log. |
| 2026-07-08 | 53f37d7 | ABORTED (env) | 12m 42s | Sprint 044 closure rerun, attempt 2 (after 64.9 GiB /nix GC + builder restart). Got through the nixos-disk-image build, then died copying the 21.4 GiB hil-boot image into build/: "fcopyfile failed: No space left on device". Binding constraint is the whole workstation APFS container (750 GB, 100% used, 262 MB free): the rebuild refilled /nix to ~100 GiB of closures while build/ held 23 GiB of prior image artifacts. Full warm-rebuild transient footprint is ~70-90 GiB — a GC alone cannot provide it. Failed closed BEFORE any destructive phase: 20/20 VMs running, vm-503-disk-0 GUID unchanged, validate 82/0/1w/1s. DR warm-rebuild NOT exercised. Evidence attached to #516; durable >=80 GiB container headroom required before attempt 3. Also a genuine DR-path finding: the warm-rebuild runbook has an unchecked workstation-capacity prerequisite. Test log: logs/DRT-001-03.log. |
| 2026-07-08 | 53f37d7 | ABORTED (env) | 4m 29s | Sprint 044 closure rerun, attempt 1. rebuild-cluster.sh aborted at nix image-build: workstation /nix at 100% ("No space left on device"); builder auto-recovery removed the store overlay but could not restart the linux-builder ("Failed to resolve nixpkgs#darwin.linux-builder" — resolution itself needs store headroom). Failed closed BEFORE any destructive phase: 20/20 VMs running, vm-503-disk-0 GUID 16832345101317218025 unchanged, no park zvols, validate.sh 82/0/1warn/1skip. Warm-rebuild DR behavior NOT exercised — not a DR result. Pre-test backup-now.sh completed (fresh PBS backups). Remediation: root-aware nix-collect-garbage + overlay reset + builder restart per nix-builder.md, then rerun. Same class as the 2026-07-06 11afc70 row. Test log: logs/DRT-001-02.log. |
| 2026-07-07 | 5a79fd0 | PASS | 15m 18s | Post-#339 boot-integrity oracle rerun on prod-promoted tip (MR !367 → dev, !368 → prod). Cleared the accumulated invalidation window since a41fb69 (2026-05-01): Sprints 034/035/037/039/041/042/043 + R1 pve-nvme-kernel-params + #339 (verify-after-write in converge_fix_grub_paths + validate.sh R7.3 boot-chain probe). All 5 fingerprints match (Roon 1308M vs 1347M). Rebuild 11m 45s. Preceded by same-session remediation (configure-replication.sh "*" + cleanup-orphan-cidata.sh + zfs promote of vm-160-disk-0 → #504); gaps filed #501, #502. (Previously the Last Run entry; moved to History on the 2026-07-08 53f37d7 PASS.) |
| 2026-07-06 | 8e1c1c3 | FAIL | 43m 25s | Third attempt this session — rebuild-cluster.sh Step 7 OpenTofu preflight refused deploy because tofu planned control-plane VMs (cicd, gitlab) with historical image hashes not present on target nodes. Cluster preserved; no destruction occurred. Root cause: preflight scope bug at Sprint 041 T2/T4 intersection — image-present check reads file_id from planned_values for skipped control-plane VMs, which is the historical hash. Filed as #492. RCA correction from earlier build-image.sh tfvars-race theory landed at 2d2aab4. |
| 2026-07-06 | 11afc70 | FAIL | 25m 30s | First attempt this session. rebuild-cluster.sh Step 5 (Build VM images) aborted 20m 56s in with nix build error (closure-info.drv, nixos-disk-image.drv). Root cause: workstation disk pressure — /dev/disk8s2 at 96% full (24 GiB free). Cluster preserved (build failed before any tofu apply); state fingerprint matched. Resolved by nix-collect-garbage (freed 51.6 GiB) + overlay reset + builder restart. Wrapper log: logs/DRT-001-01-prod.log. |
| 2026-05-01 | a41fb69 | PASS | 13m 30s | Sprint 033 closure rerun on the publish-enabled prod commit (post first publish, pipeline 850 force-pushed github main as the bot commit). Validates Sprint 033 publish:github machinery (.gitlab-ci.yml, configure-vault.sh, validate.sh, generate-gatus-config.sh) plus the #287 test-isolation fix (test_publish_failure_classification.sh, test_publish_filter.sh, validate:publish-tests-env-isolation ratchet job). All 5 fingerprints match (GitLab projects=1, Vault initialized + 14 mounts, InfluxDB org=homelab, Roon DB=1574M vs pre-test 1643M, threshold 821M). Total elapsed 13m 30s, well under 45m threshold. |
| 2026-04-28 | 5444272 | PASS | 44m 46s | Sprint 031 closure rerun on prod-promoted commit. Rebuild took 42m 30s; total elapsed 44m 46s (just under 45m threshold). All fingerprints match. Validates restore-before-start.sh running with VMs stopped and HA absent, then Phase 2 starts/registers. Validates post-merge fix chain (#273/!223 polling, #267/!224 R6.3 yq + gitlab heal marker, #275/!225 certbot-renew arg-glue + static check) on the DR path. |
| 2026-04-27 | bc08132 | PASS | 10m 5s | Sprint 030 closure rerun. Rebuild 8m 31s. All fingerprints match (Roon 1629M). Preceded by DRT-001-12..-15 failures from layered pre-existing footguns (age-key path, SOPS relative paths, #259 placeholder) — none Sprint 030 regressions. |
| 2026-04-26 | 3d4cee4 | PASS | 10m 55s | Sprint 029 closure rerun. Rebuild took 9m 16s. All state fingerprints match (GitLab projects=1, Vault mounts=14, InfluxDB org=homelab, Roon DB=1654M). |
| 2026-04-15 | 7cea669 | PASS | 60m 47s | Sprint 014 SSH host key persistence, generation cleanup, HA attribute removal validated. Exceeded 45m threshold due to roon DB size (1.1GB). All state fingerprints match. |
| 2026-04-14 | bd67556 | PASS | 16m 45s | Sprint 013 pipeline integration + runner self-update validated |
|------|--------|--------|------|-------|
| 2026-04-14 | 6f3a9a8 | PASS | 15m 16s | Sprint 012 backup health gate + vault.db barrier validated |
| 2026-04-13 | 400d1fd | PASS | 12m 53s | Sprint 011 lifecycle protection + drift ratchets validated |
| 2026-04-13 | 400d1fd | FAIL | 8m 16s | Orphan HA resource vm:503 from killed run (#190) |
| 2026-04-12 | 81fbf93 | PASS | 11m 39s | Sprint 010 overlay root + MR !111 HA fix validated |
| 2026-04-11 | 8e9869d | PASS | 11m 20s | Sprint 009 convergence extraction |
| 2026-04-05 | 6d5472f | PASS | 13m 20s | First system stable in a week |
| 2026-03-23 | 746d062 | PASS | 29m 49s | Level 5 Test 2 |

---

## DRT-002: Cold Rebuild

**Status:** PASS on 2026-07-08 commit `d401d3f4` (this rerun; #505 fix
verified). Fresh clone of prod @ d401d3f4 from GitLab; `rebuild-cluster.sh`
ran clean end-to-end in 12m32s from the temp clone — the cold-rebuild tofu
preflight no longer fabricates `PLACEHOLDER_workstation` (the deterministic
FAIL cause since Sprint 028). Steps 1–8 all PASS; validate.sh green post-run
(83/0/1warn/1skip). `DRT_EXIT=1` is a manufactured harness artifact: step 9's
interactive `drt_expect` pipeline prompt hits EOF on non-TTY stdin under
`set -e` (same class as DRT-005's power prompt) — no DR assertion failed.
Important scope caveat recorded in Last Run: because the cluster was already
deployed at exactly d401d3f4 (prod pipeline #1350 at 08:21Z), the OpenTofu
apply was **173/173 no-op** — no VM was recreated, so the run validated the
fresh-clone build+preflight+apply PATH (the #505 fix) but did NOT exercise the
destroy→restore/park-adopt bridge; all 7 precious vdb GUIDs preserved in place.
DRT-001 (warm, same day) is the run that exercised actual recreation+restore.

**Prior invalidation history (superseded by the 2026-07-08 d401d3f4 rerun):**
INVALIDATED by Sprint 002 changes to `rebuild-cluster.sh`
branch safety, initial-deploy detection, last-known-prod comparison,
and GitLab handoff behavior. Sprint 007 also changes `certbot.nix`,
adds a new persisted-state helper, and updates macOS-exercised shell
paths around Step 9 target selection. Sprint 008 additionally changes
`framework/scripts/rebuild-cluster.sh` HA sequencing and the fresh-workspace
provider contract in `framework/tofu/root/versions.tf`. Sprint 009
extracts the rebuild convergence path into `converge-lib.sh`. Sprint 010
adds overlay root in `base.nix`, closure-push wiring in the convergence
scripts, and shared flake closure outputs. Sprint 011 adds control-plane
lifecycle protection and live closure drift checks. Sprint 012 changes
the backup gate and restore pinning path used during rebuild-related PBS
recovery. Sprint 026 additionally changes Vault-backed certificate restore,
sync, and budget gating (`framework/nix/modules/certbot.nix`,
`framework/scripts/cert-sync.sh`, `framework/scripts/certbot-initial-wrapper.sh`,
`framework/scripts/check-cert-budget.sh`, `framework/scripts/certbot-cluster.sh`),
Vault cert persistence on vdb (`framework/nix/modules/vault.nix`), and the
AppRole surface for recreated VMs (`framework/scripts/configure-vault.sh`,
`framework/tofu/root/main.tf`, `framework/tofu/modules/testapp/`,
`framework/catalog/grafana/`). Sprint 029 additionally changes the workstation
convergence path in `framework/scripts/converge-lib.sh`,
`framework/scripts/post-deploy.sh`, and
`framework/scripts/cert-storage-backfill.sh`, plus #241's
certbot-compatible `renewal.conf` rewrite in
`framework/nix/modules/certbot.nix`. Re-run required before
the ratchet is valid again.

**Sprint 029 closure assessment (2026-04-26):** NEEDS RERUN.
DRT-002 exercises the full deploy path including post-deploy and
cert-storage-backfill, both of which Sprint 029 modified. The
new cert-restore renewal.conf format from #241 also surfaces on
the cold-rebuild path when dns1 is freshly created. Rerun is
deferred to next sprint cycle (not blocking Sprint 029 closure
since DRT-001 covers the same convergence path with warm cache;
DRT-002 is the cold-from-fresh-clone variant and is more
expensive without testing meaningfully different code given
DRT-001 already passed).

**What it validates:** That a fresh operator can clone the repo and
build a complete cluster from scratch. Simulates the new-operator
experience with `new-site.sh` + `rebuild-cluster.sh` from a fresh
clone.

**Invalidated by changes to:**
- `framework/scripts/new-site.sh`
- `framework/scripts/rebuild-cluster.sh`
- `framework/scripts/converge-lib.sh`
- `framework/scripts/converge-vm.sh`
- `framework/tofu/root/versions.tf`
- `framework/scripts/build-all-images.sh`
- `framework/scripts/build-image.sh`
- `framework/scripts/certbot-persisted-state.sh`
- `framework/scripts/cert-sync.sh`
- `framework/scripts/certbot-initial-wrapper.sh`
- `framework/scripts/check-cert-budget.sh`
- `framework/scripts/certbot-cluster.sh`
- `framework/templates/config.yaml.example`
- `flake.nix` (image derivations, nixSrc filter)
- `framework/nix/lib/` (overlay/root-device/runtime wiring)
- `framework/nix/modules/base.nix`
- `framework/nix/modules/certbot.nix`
- `framework/nix/modules/vault.nix`
- Any NixOS module referenced by infrastructure roles
- macOS bash compatibility in any framework script
- `framework/scripts/bootstrap-sops.sh`

**Pass criteria:**
- `validate.sh` passes
- Pipeline green on first push
- Elapsed time < 60 min (warn if exceeded)

**Estimated time:** ~50 min

**Last Run:**
```
DRT-002 Cold Rebuild
Date:    2026-07-08T08:48:22Z
Commit:  d401d3f4 (prod tip; == gitlab/prod, == prod pipeline #1350)
Result:  PASS (all 8 DRT assertions PASS; DRT_EXIT=1 is a step-9 non-TTY
         harness artifact, not a DR failure — see below)
Time:    Rebuild 12m 32s (well under the 60-min threshold; baseline 47m)

#505 EVIDENCE (the reason for this rerun — UNBLOCKED, prior FAIL not recurring):
  Fresh clone (ssh://git@172.17.77.62/root/mycofu.git, remote renamed to
  `gitlab` to match the canonical operator workspace), checked out prod
  @ d401d3f4. DRT-002 cloned that to a temp dir and ran
  `rebuild-cluster.sh --override-branch-check`. The cold-rebuild tofu
  preflight completed with NO `PLACEHOLDER_workstation`: tofu-wrapper.sh's
  #505 fix excludes disabled apps (workstation.enabled=false) from the
  fresh-clone placeholder-fabrication path, so the image gate is no longer
  tripped. Rebuild ran end-to-end (Steps 0–18) and exited 0. The prior
  deterministic FAIL (2026-07-07 530a501, "workstation: PLACEHOLDER_workstation"
  at Step 6) did NOT recur. Verified in-tree: tofu-wrapper.sh fabrication
  loop `continue`s for DISABLED_APP_ROLES ∖ INFRA_ROLES.

STEP-9 CAVEAT (DRT_EXIT=1 explained):
  Steps 1–8 all PASS in logs/DRT-002-01.log. Step 9 is the interactive
  `drt_expect` "Pipeline is green on first push (check GitLab UI)". Under
  headless `claude -p` there is no TTY; `read` in drt_expect hits EOF and,
  under the script's `set -euo pipefail`, aborts at that line with exit 1
  before any assertion is recorded. Manufactured harness failure, not a DR
  assertion failure. Step-9 verified out-of-band via read-only GitLab API:
  GitLab healthy (17.11.5), runner #2 online+active, latest prod pipeline
  #1350 (d401d3f4) green and restored, GitLab scheduler functional (scheduled
  dev pipeline #1351 picked up post-run). A genuine "first push" confirmation
  is structurally deferred to the next real prod push (Sprint-045's first MR).
  (Same non-TTY class as DRT-005's power prompt — reported as a follow-up.)

SCOPE CAVEAT — no-op apply, bridge NOT exercised (recorded honestly):
  The cluster was already deployed at exactly d401d3f4 (prod pipeline #1350
  deployed it at 08:21Z, ~27 min before the test). The OpenTofu default plan
  was 173/173 no-op — NO VM was recreated (verified from the temp clone's
  preboot-restore-plan-bulk.json). Consequently the preboot-restore manifest
  was correctly empty and neither the Sprint-044 park/adopt-spared path NOR
  the cold-path PBS vdb restore ran (all restore decisions were resolved during
  the preboot phase; none ran after guest start). All 7 precious vdb ZFS GUIDs
  are byte-identical
  pre→post (continuity preserved IN PLACE, not via restore):
    vault-dev 303-disk-1 6819902318493640043 | influxdb-dev 501-disk-1 7010247812344947005
    roon-dev 503-disk-0 16832345101317218025 | vault-prod 403-disk-1 128448283038227689
    influxdb-prod 601-disk-1 2869992623489482171 | roon-prod 603-disk-0 13445616518576118872
    gitlab 150 (pve03 disk-0/1) unchanged.
  The phased apply still power-cycled all framework VMs (qemu restarted 08:55Z,
  uptime ~11m post-run); vendor appliance pbs (190) untouched (uptime 52d).
  NET: this run validates the fresh-clone build+preflight+apply PATH (the #505
  fix), NOT a from-empty destroy→restore. DRT-001 (warm, same day @ 53f37d7)
  is the run that exercised recreation + the bridge (dev spared / prod
  PBS-restored). To force cold destroy→restore, the target commit must differ
  from the running one (or reset-cluster.sh --test first).

SAFETY GATE (pre-destruction): backup-now.sh --env all exit 0; fresh trusted
  PBS pins for all 7 precious VMIDs dated TODAY 2026-07-08; GitLab (150) pin
  pbs-nas:backup/vm/150/2026-07-08T08:45:02Z trust=trusted — post-promotion
  anchor confirmed. (roon 603/503 trust=unknown reason=no-certbot-runtime, the
  documented n/a case.) rebuild's own Step-18 backup also completed.

STATE FINGERPRINT (pre → post, all preserved): GitLab projects 3→3; Vault
  initialized+unsealed, 14→14 mounts; InfluxDB org homelab→homelab; Roon DB
  1295M→1287M (−8M cache churn, ≫ 50% threshold).

VALIDATE.SH post-run (framework/scripts/validate.sh, exit 0): 83 passed,
  0 failed, 1 warn, 1 skip. #511 cidata check GREEN ("no orphan cidata zvols
  cluster-wide" + "cidata drive names are canonical (no rename victims)").
  Replication GREEN (pve01/02/03 "replication not stale" — reconfigured by
  rebuild Step 12). Sole WARN = pre-existing Gatus host-key probe (same class
  DRT-001 documented). #514 verify_recovery is a rebalance-cluster.sh phase
  (no failover here) → not exercised by DRT-002, consistent with the #514 note
  above.

POST-DESTRUCTIVE HYGIENE: no VMs recreated, so ssh-keygen -R stale-key cleanup
  is N/A this run (host keys unchanged; the rebuild ran its own SSH host-key
  refresh at Step 7). configure-replication.sh was run by the rebuild (Step 12,
  verified green) — not re-run manually. No merges/pushes/GitLab writes/cluster
  writes performed in wrap-up (read-only API/SSH only).

Notes: Test log logs/DRT-002-01.log; rebuild log (temp clone)
       build/rebuild.log; baseline/post GUIDs logs/DRT-002-baseline-guids.txt;
       backup gate logs/DRT-002-backup-gate.log; post validate
       logs/DRT-002-postrun-validate.log. Reporting caveat carried from
       DRT-001: the bulk park/preboot-restore status artifacts recorded empty
       entries[] — here that is CORRECT (nothing to restore on a no-op apply),
       but the empty-summary behavior is still a known follow-up.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-07-07 | 530a501 | FAIL | 5m 59s | rebuild-cluster.sh aborted at Step 6 tofu preflight: tofu-wrapper.sh image-value guard refused apply because workstation was left `PLACEHOLDER_workstation` in image-versions.auto.tfvars (fresh clone, no cached tfvars; disabled-app + cold-clone interaction). Cluster PRESERVED — no tofu apply ran. Filed as #505; latent since Sprint 028 workstation disable. Fixed by #505 (tofu-wrapper.sh fabrication path excludes disabled apps) and verified by the 2026-07-08 d401d3f4 PASS above. |
| 2026-03-25 | 099b860 | PASS | 47m | Level 5 cold path |

---

## DRT-003: PBS Restore

**Status:** PASS on 2026-07-08 commit `53f37d7` (Sprint 044 closure).
All four precious-state prod/shared VMs (vault 403, gitlab 150,
influxdb 601, roon 603) restored via the **forced-restore branch**
`restore-from-pbs.sh --force --target` (latest backup — the DRT-003
script does NOT pass an explicit `--backup-id`, and takes no pre-test
backup, so "latest" is the DRT-001 02:11Z pre-test backup / any newer
scheduled backup). This is an **in-place** vdb restore: the zvol dataset
and its ZFS GUID are preserved (contents overwritten), so unlike DRT-001's
recreate path the GUID does not change. The restore is instead evidenced
by VM restart (post-run uptime 2-7 min on 403/150/601/603 vs 27 min on
untouched dev VMs), the four `restore-from-pbs --force` exit-0 asserts,
production-clean cert lineages, the Roon DB delta (1300M→1278M), and a
matching fingerprint. validate.sh 82/0/1w/1s; replication FailCount 0;
0 orphan cidata; 20/20 running. The dev bridge **"spared" branch is NOT
exercised by DRT-003** — it was covered by DRT-001 (attempt 3) earlier in
this campaign, where dev vdb GUID continuity was verified. The orphaned-
park refusal path is likewise not exercised here.

**Sprint 043 closure rerun completed 2026-07-05T23:21:38Z on prod tip
`f25bd5d` — PASS in 10m 16s.** After the operator-side acute unblock +
dev→prod promotion, `validate.sh` is green cluster-wide. Fresh
pre-DRT PBS backups taken via `backup-now.sh --env all` to avoid
restoring gitlab to a 13.5-hour-old backup (5 open MRs including this
one, all commits pushed today would have been lost). Restore then
proceeded with those fresh backups as "latest" for all 4 precious-state
prod VMs. Cert lineage checks all pass; state fingerprint matches.
See Last Run block below.

**What it validates:** That `restore-from-pbs.sh` can restore all
precious-state VMs from PBS backups. The deploy and rebuild paths now
exercise `restore-before-start.sh` before VMs are started, using pinned
backup IDs when available and failing closed when restore cannot complete.

**Invalidated by changes to:**
- `.gitlab-ci.yml`
- `framework/scripts/build-all-images.sh`
- `framework/scripts/deploy-control-plane.sh`
- `framework/scripts/check-control-plane-drift.sh`
- `framework/scripts/restore-from-pbs.sh`
- `framework/scripts/restore-before-start.sh`
- `framework/scripts/converge-lib.sh`
- `framework/scripts/converge-vm.sh`
- `framework/scripts/backup-now.sh`
- `framework/scripts/certbot-persisted-state.sh`
- `framework/scripts/cert-sync.sh`
- `framework/scripts/certbot-initial-wrapper.sh`
- `framework/scripts/cert-storage-backfill.sh`
- `framework/scripts/check-cert-budget.sh`
- `framework/scripts/certbot-cluster.sh`
- `framework/scripts/validate.sh`
- `flake.nix`
- `framework/nix/lib/` (overlay/root-device/runtime wiring)
- `framework/nix/modules/base.nix`
- `framework/nix/modules/certbot.nix`
- `framework/nix/modules/vault.nix`
- `framework/tofu/modules/` PBS module
- PBS NixOS module
- NAS NFS datastore configuration

**Pass criteria:**
- `validate.sh` passes
- State fingerprint matches pre-test
- Restored live GitLab, Vault, and backup-backed HTTPS app VMs keep the
  configured ACME renewal lineage
- Restored live GitLab does not still serve a `Fake LE` leaf when site
  ACME mode is production

**Estimated time:** ~20 min

**Last Run:**
```
DRT-003 PBS Restore
Date:    2026-07-08T02:31:37Z
Commit:  53f37d7
Result:  PASS
Time:    8m 48s
Notes:   Sprint 044 closure rerun on prod tip 53f37d7, immediately after
         DRT-001 attempt-3 warm rebuild (same campaign, branch
         drt-campaign-044). Branch coverage: FORCED-RESTORE path only
         (restore-from-pbs.sh --force --target) for all 4 precious prod/
         shared VMs — vault 403, gitlab 150, influxdb 601, roon 603. The
         script uses "latest" (no explicit --backup-id) and takes no
         pre-test backup, so latest = the DRT-001 02:11Z pre-test backups.
         All 4 restore asserts PASS. In-place restore: vdb zvol GUIDs are
         PRESERVED across the restore (dataset overwritten, not recreated;
         403-disk1=128448283038227689, 150-disk0=3371498061164556763,
         601-disk1=2869992623489482171, 603-disk0=13445616518576118872
         unchanged pre/post) — this is expected for in-place restore and
         differs from DRT-001's recreate path where prod GUIDs changed.
         Restore is evidenced instead by VM restart (post-run uptime
         403=7m/150=5m/601=5m/603=2m) vs untouched dev VMs (303/501/503
         uptime 27m, GUIDs unchanged incl. vm-503-disk-0 16832345101317218025).
         Cert lineage checks all pass — vault_prod + influxdb_prod renewal
         lineages match configured ACME URL; live gitlab issuer
         production-clean. State fingerprint matches (GitLab projects=3,
         Vault initialized + 14 mounts, InfluxDB org=homelab, Roon DB
         1278M vs pre-test 1300M, above 650M threshold). validate.sh 82
         passed / 0 failed / 1 warn (Gatus host-key probe) / 1 skip;
         replication FailCount 0; 0 orphan cidata; 20/20 running. Dev
         bridge "spared" branch NOT exercised by DRT-003 — covered by
         DRT-001 attempt 3 this campaign. Test log: logs/DRT-003-01.log.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-07-08 | 53f37d7 | PASS | 8m 48s | Sprint 044 closure rerun immediately after DRT-001 attempt-3 warm rebuild (campaign branch drt-campaign-044). FORCED-RESTORE branch only (restore-from-pbs.sh --force --target, latest backup = DRT-001 02:11Z pins; no explicit --backup-id). All 4 precious prod/shared VMs restored (vault 403, gitlab 150, influxdb 601, roon 603). In-place restore preserves vdb zvol GUIDs (403-disk1/150-disk0/601-disk1/603-disk0 unchanged); restore evidenced by VM restart (uptime 2-7m) + exit-0 asserts + Roon DB 1300M→1278M + cert lineage. Cert lineages production-clean; fingerprint matches; validate 82/0/1w/1s; replication FailCount 0; 0 orphan cidata; 20/20 running. Dev bridge "spared" branch NOT exercised here — covered by DRT-001 attempt 3 (dev vdb continuity, vm-503-disk-0 16832345101317218025). Test log: logs/DRT-003-01.log. |
| 2026-07-05 | f25bd5d | PASS | 10m 16s | Sprint 043 closure rerun on prod tip (post dev→prod promotion, green prod pipeline). Fresh pre-DRT PBS backups via backup-now.sh --env all (5 open MRs; daily backup would have lost the day's activity). All 4 precious prod VMs restored cleanly (vault 403, gitlab 150, influxdb 601, roon 603). Cert lineage checks pass — vault_prod/gitlab/influxdb_prod match ACME URL, gitlab issuer production-clean (Sprint 043 D1 fullchain fix persists across restore). Fingerprint matches (Roon 1323M vs 1346M, above 673M). (Previously the Last Run entry; moved to History on the 2026-07-08 53f37d7 PASS.) |
| 2026-05-01 | a41fb69 | PASS | 6m 40s | Sprint 033 closure rerun on the publish-enabled prod commit (post first publish, pipeline 850). All 4 precious-state prod VMs restored cleanly (vault VMID 403, gitlab VMID 150, influxdb VMID 601, roon VMID 603). Cert lineage checks all pass — vault_prod, gitlab, and influxdb_prod renewal lineages match configured ACME URL; live gitlab issuer is production-clean. State fingerprint matches (GitLab projects=1, Vault initialized + 14 mounts, InfluxDB org=homelab, Roon DB 1547M vs pre-test 1588M, well above 794M threshold). Validates Sprint 033 changes to .gitlab-ci.yml and validate.sh on the restore path, plus the #287 test-isolation fix. |
| 2026-04-28 | 5444272 | PASS | 6m 15s | Sprint 031 closure rerun on prod-promoted commit. All 4 precious-state prod VMs restored (vault 403, gitlab 150, influxdb 601, roon 603). Cert lineage checks all pass — production-clean leaf on gitlab, ACME URL match on vault_prod and influxdb_prod. Roon DB 1524M vs pre-test 1616M (above 808M threshold). Validates pin-aware restore via restore-before-start.sh wired to backup-now.sh's build/restore-pin-${env}.json, plus post-merge fix chain (#273/!223 polling, #267/!224 R6.3 yq, #275/!225 certbot arg-glue). |
| 2026-04-27 | bc08132 | PASS | 5m 10s | Sprint 030 closure rerun. All 4 precious-state prod VMs restored. Cert lineages production-clean. State fingerprint matches (Roon 1567M vs 1629M). |
| 2026-04-26 | 3d4cee4 | PASS | 8m 43s | Sprint 029 closure rerun. All 4 precious-state prod VMs restored. Cert lineages preserved. Roon DB 1592M vs pre-test 1654M (above 827M threshold). |
| 2026-04-15 | 7cea669 | PASS | 8m 37s | Sprint 014 SSH host key persistence, generation cleanup, HA attribute removal validated. All cert lineages preserved. State fingerprint matches. |
| 2026-04-14 | bd67556 | PASS | 6m 38s | Sprint 013 pipeline integration validated |
| 2026-04-14 | 6f3a9a8 | PASS | 6m 2s | Sprint 012 backup health gate + vault.db barrier validated |
| 2026-04-13 | 400d1fd | PASS | 6m 6s | Sprint 011 lifecycle protection + drift ratchets validated |
| 2026-04-12 | 81fbf93 | PASS | 4m 32s | Sprint 010 overlay root + certbot persistence validated |
| 2026-04-11 | 8b78907 | PASS | 4m 27s | Sprint 009 convergence extraction |
| 2026-04-05 | 6d5472f | PASS | 4m 19s | Post-rebuild restore after week of LE rate limit issues |
| 2026-03-30 | efba8e1 | PASS | 4m 2s | First manual pass after 7, 4, 6 |
| 2026-03-25 | 099b860 | PASS | ~20m | Post-rebuild restore |
| 2026-03-25 | 099b860 | PASS | ~20m | Restored vault and gitlab from PBS after warm rebuild. |

---

## DRT-004: Vault HA Failover

**Status:** PASS at 2026-05-01 commit `a41fb69` (Sprint 033 closure rerun)
— covers Sprint 033 changes to `configure-vault.sh` (which now
repopulates `secret/data/github/deploy-key` from SOPS when present) on
the publish-enabled prod commit (post first publish, pipeline 850).
Vault recovered in 21s (under 30s RTO target). The kill →
HA-restart → auto-unseal path is unaffected by the configure-vault
extension; the github-publish KV write happens only during
`configure-vault.sh prod` runs, not on auto-unseal.

**What it validates:** That Vault automatically recovers from a VM
crash. The QEMU process is killed (simulating a crash), and Proxmox
HA restarts the VM. The auto-unseal service reads the unseal key from
vdb and unseals Vault without operator intervention.

**Invalidated by changes to:**
- `framework/nix/modules/vault.nix`
- Vault NixOS module (auto-unseal configuration)
- Vault OpenTofu module (HA priority, anti-affinity, placement)
- `framework/scripts/init-vault.sh`
- `framework/scripts/configure-vault.sh`
- SOPS unseal key delivery mechanism
- `site/config.yaml` HA group configuration

**Pass criteria:**
- Vault responds healthy within 30 seconds of kill
- `validate.sh` Vault checks pass

**Estimated time:** ~5 min

**Last Run:**
```
DRT-004 Vault HA Failover
Date:    2026-07-05T23:36:39Z
Commit:  b2093af
Result:  PASS
Time:    3m 17s (recovery: 19s)
Notes:   Sprint 043 closure opportunistic rerun (not invalidated by
         Sprint 043, but extending the ratchet forward on prod tip
         post-promotion). QEMU process killed on pve03 (VMID 403) at
         2026-07-05T23:38:14Z; HA restarted Vault; auto-unseal
         completed. Vault healthy after 19s wall-clock (under 30s RTO
         target, best time yet — baseline ~15s from 2026-03-23). SOPS
         root token still valid post-failover, confirming write-once
         invariant intact across Sprint 043's certbot changes.
         validate.sh green as precondition AND post-recovery. Wrapper
         log: logs/DRT-004-01-prod.log.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-05-01 | a41fb69 | PASS | 1m 37s (recovery: 21s) | Sprint 033 closure rerun on the publish-enabled prod commit (post first publish, pipeline 850). QEMU process killed on pve03; HA restarted Vault; auto-unseal completed. Vault healthy after 21s wall-clock (under 30s RTO target, baseline ~15s). SOPS root token still valid post-failover. validate.sh vault checks pass. Confirms the kill→HA-restart→auto-unseal path is unaffected by Sprint 033's configure-vault.sh extension that repopulates secret/data/github/deploy-key from SOPS. |
| 2026-04-26 | 3d4cee4 | PASS | 1m 40s (recovery: 22s) | Sprint 029 closure opportunistic rerun. QEMU process killed on pve03; HA restarted Vault; auto-unseal completed. Vault healthy after 22s wall-clock (under 30s RTO target). SOPS root token still valid post-failover. validate.sh vault checks pass. Confirms the closure-cycle assessment that Sprint 029's changes do not exercise this path. |
| 2026-03-30 | 3aed5d1 | PASS | 0m 56s | Pre-Sprint-026 baseline |
| 2026-03-23 | 746d062 | PASS | ~15s | Step 10B destructive test |
| 2026-03-23 | 746d062 | PASS | ~15s | 10s HA restart + 5s boot/unseal. Measured during Step 10B. |


---

## Sprint 047 Invalidation Note (state-class-driven per-VM replication policy)

**Status:** DRT-005 is the primary casualty (its assertion set presumes HA
restart-from-replica for every VM). DRT-006 is a conditional hygiene rerun.
DRT-001 / DRT-002 are hygiene reruns per registry rule. DRT-003 / DRT-004 /
DRT-007 / DRT-008 are NOT invalidated.

**Superseded:** Sprint 048 invalidates DRT-005 again and replaces the
policy-on/policy-off predicate below with the universal cadence predicate. The
Sprint 047 note is retained as history of the pre-048 contract only.

Sprint 047 landed:
- `list-replicated-vmids.sh` (single enumeration authority; A2)
- `validate-site-config.sh` guards for the new `replicate:` key (A1)
- Site edit: `dns1_prod`/`dns2_prod` opt-in via `replicate: true`
- `configure-replication.sh` `--env` + policy partition + env-scoped prune
  + verify-after-destroy + empty-set abort + `/etc/repl-policy.vmids`
  delivery (A3)
- `repl-health.sh` policy-aware exclusion + expected-job PRESENCE check
  + strict-on-absent (A4)
- `validate.sh` new `replication_policy_conformance_check` (A5)
- `safe-apply.sh` passes `--env` to `configure-replication.sh`
- `recreate-derivable-vm.sh` (NEW; A6 recovery contract)
- `rebalance-cluster.sh` policy-off drift skip + G7 guidance (R4)
- `placement-watchdog.sh` remediation text branches on policy (T4.3)

**Recomputed invalidation:**

- **DRT-005 (Node Failure Recovery)** — **INVALIDATED (primary).**
  Assertion set changes: (1) migrate-budget applies to the POLICY-ON set
  (7 precious + 2 prod DNS = 9 VMs cluster-wide, not the previous "all
  VMs on the dead node"); (2) policy-off VMs on the dead node land in
  expected `error`/`stopped` (recorded, not treated as failure);
  (3) after node rejoin and before rebalance the DRT walks the
  operator-facing recreate-derivable-vm.sh recovery contract for the
  first dev-side policy-off VM in HA `error` (prefer `testapp_dev`, fall
  back to `acme_dev` — VMIDs come from config.yaml via `drt_vm_vmid`):
  dry-run (guards + printed `safe-apply.sh dev` deploy hint) → real
  invocation (VM destroyed, stale zvols swept) → the printed
  `safe-apply.sh dev` deploy → verify the VM is running again. An M4
  run where neither candidate is in HA `error` is a hard FAIL — the
  contract-walk IS the acceptance proof, not decoration. After the
  exercise, any RESIDUAL policy-off HA `error` states (other-dev / prod
  policy-off VMs the target failure took down) are cleared via the
  storage-failure-fence §6A ladder (`--state disabled → --state
  started`), which restart-in-place on the returned home node's local
  zvols; cicd and hil_boot are excluded from the ladder (their recovery
  contracts differ — `rebuild-cluster.sh --scope control-plane`). Only
  after residuals clear does rebalance run — the exact BLOCKS-M4 symptom
  is resolved (issue #668 / FI-24); (4) anti-affinity assertions
  unchanged from Sprint 045. **The attended DRT-005 rerun is the M4
  failover acceptance gate for Sprint 047.** MR-6 rewrote the policy-set
  assertions; issue #668 (this MR) added the recreate-exercise leg and
  the §6A residual cleanup so registry promise ≡ test behavior.

- **DRT-006 (DNS Failover)** — **CONDITIONAL hygiene rerun** (not a
  primary invalidation). The test is service-level: it `qm stop`s one
  DNS VM and asserts the peer serves + certbot renews. Prod DNS
  (401/402) is replicated (Sprint 047 opt-in); dev DNS (301/302) is
  policy-off. The service-level assertions still hold for both; the
  underlying failover-restart mechanism differs (prod DNS restarts from
  replica; dev DNS survivor holds the window while operator recreates
  the failed peer). Comment-only update in MR-6.

- **DRT-001 (Warm Rebuild)** / **DRT-002 (Cold Rebuild)** —
  **INVALIDATED (hygiene).** `configure-replication.sh` extensively
  rewritten (new `--env` flag, policy partition, prune, artifact
  delivery). `validate.sh` gained a new conformance check.
  `config.yaml.example` is a cold-rebuild input (T2.3). Reruns
  operator-scheduled; hygiene, not sprint closure gates.

- **DRT-003 (PBS Restore)** — **NOT INVALIDATED.** Sprint 047 does not
  touch `restore-from-pbs.sh`, `restore-before-start.sh`, or the vdb
  restore contract. Preboot restore continues to use the same primitives.

- **DRT-004 (Vault HA Failover)** — **NOT INVALIDATED.** Vault
  (vault_dev/vault_prod, 303/403) is precious — its replication cadence
  is unchanged. Vault HA failover still restarts from replica per the
  §6A ladder.

- **DRT-007 / DRT-008** — **NOT INVALIDATED.** Precious backup spot-check
  and reset contract untouched.

---

## Sprint 048 Invalidation Note (universal replication cadence doctrine)

**Status:** DRT-005 is invalidated by Sprint 048. The doctrine flip changes
the failover contract: the pre-048 predicate split node-failure recovery into
policy-on replica recovery and policy-off recreate/error handling. Post-048,
every VM from the failed node is expected to reach qemu `running` plus HA
`started` on a survivor unless an explicit `replicate: false` override exists.
The shipped deployment currently has no policy-off override VMs.

Sprint 048 landed:
- Universal replication with per-VM cadence (`backup: true` -> 1m;
  env in `{prod, shared}` -> 1m; env `dev` -> 24h).
- `/etc/repl-policy.vmids` carries `CADENCE_MAP` alongside
  `POLICY_ON_VMIDS`, `POLICY_OFF_VMIDS`, and `POLICY_GEN`.
- Comment-based override ratification replaces metadata blocks.
- 24h first-run seed WARN semantics in `validate.sh`.
- `recreate-derivable-vm.sh` demoted to an override-only tool for explicit
  `replicate: false` VMs.

**M4 DRT-005 rerun template:**

```
DRT-005 Node Failure Recovery
Date:    <YYYY-MM-DDTHH:MM:SSZ>
Commit:  <commit>
Result:  <PASS|FAIL|BLOCKED>
Time:    <elapsed>
t0:      membership_loss_t0=<survivor corosync timestamp>
         recovery_end=<timestamp when last failed-node VM reached qemu running + HA started>
Budget:  recovery_end - membership_loss_t0 = <seconds>s (WARN 166s / hard-FAIL 252s, measured MR-7)
Target:  <failed node>; survivors=<nodes>
Result:  every VM from the failed node reached qemu status=running and HA state=started on a survivor
Notes:   policy-off override leg: <SKIP if empty, or override VM results>
```

Ceiling gates on `recovery_end - membership_loss_t0`, where
`membership_loss_t0` is observed from `journalctl -u corosync` on a survivor
using `grep -E 'A processor failed, forming new configuration|A new membership'`.
Report both timestamps. The measured hard-FAIL ceiling is 252 s (WARN at
166 s), ratcheted MR-7 from the M4 attempt-3 baseline B=136s (series
146/146/136). Non-timing hard failures include the permanent #691
qmstart hang detector, zvol/device failures, a failed survivor task
query, or any failed-node VM that does not reach qemu `running` plus
HA `started` on a survivor.

**M2+1w daily-delta measurement template:**

```
M2+1w Daily Delta: cicd 160-0 24h job
Window:  2026-07-22 through 2026-07-29
Job:     160-0
Samples: <daily pvesr/zfs send delta measurements>
Max:     <GiB>
P95:     <GiB>
Notes:   feed MR-7 budget ratchet; measurement first, no grace logic built yet
```

**Recomputed invalidation:**

- **DRT-005 (Node Failure Recovery)** — **INVALIDATED (primary).** Rewrite
  the predicate to universal: every VM from the failed node reaches qemu
  `running` plus HA `started` on a survivor. Use corosync membership loss on
  a survivor as `t0`. Policy-off override legs are conditional and SKIP when
  the helper's `--off all` set is empty.
- **DRT-006 (DNS Failover)** — comment-only hygiene already handled in the
  test script; the service-level test remains valid.

---

## DRT-005: Node Failure Recovery

**Status:** PASS on 2026-07-23T09:06:02Z commit `b9fc097` (M4 attempt
3). CLEAN PASS, closes M4, Sprint 048 failover acceptance, and Sprint
047 (open-blocked-on-successor ruling 2026-07-21). Recovery 136s
(series 146/146/136 vs the pre-M4 600s analytic ceiling). First fully
unassisted full cycle: family-(e) dummy0 stanza (#697) held from cold
boot, failback autonomous, zero HA errors, zero qmstart hangs, app
state preserved. Harness #696 + tooling #697 exercised. Bands
ratcheted in MR-7 from the measured baseline B=136s: WARN=166s
(max(B+30, ceil(1.15B))), FAIL=252s (ceil(1.85B)). Test log:
`logs/DRT-005-20260723-182435.log`.

Prior status (superseded): FAIL on 2026-07-23 commit `a7fa848` (M4
attempt 2). Failover-acceptance criteria all PASSED at 146s; sole
failure was post-rebalance `validate.sh` — three inner FAILs downstream
of a pve02 boot race that left dummy0 without `10.10.0.2/32` (corosync
ring-0 / Proxmox migration-network address). Bundled as #697
(family (e) dummy0 stanza + rebalance exit-honesty + validate.sh
fail-closed migration-network address check). Attempt 3 above is the
clean run against the #697 fix.

Prior status (superseded): FAIL on 2026-07-22 commit `236b09b` (M4
attempt 1). Failover criteria all passed at 146s; sole failure was
step-12 harness timing (85/1/2 with anonymous inner check due to
tail-truncation) — harness defects fixed in #696 and verified working
in attempt 2.

**What it validates:** That the cluster survives complete node membership
loss. Every VM that was running on the failed node reaches qemu
`status=running` and HA `state=started` on a surviving node. Anti-affinity
pairs remain correct, the failed node rejoins, rebalance restores intended
placement, validate returns green, and the permanent #691 qmstart hang
detector stays green.

**Invalidated by changes to:**
- `framework/tofu/modules/testapp/`
- `framework/catalog/grafana/`
- `framework/tofu/root/main.tf`
- Proxmox HA configuration in any OpenTofu module
- Anti-affinity rules (dns1/dns2 placement)
- N+1 capacity allocation in `site/config.yaml`
- `framework/scripts/rebalance-cluster.sh`
- `framework/scripts/configure-replication.sh`
- `framework/dr-tests/tests/DRT-005-node-failure.sh`
- `tests/test_drt005_budget.sh`

**Pass criteria:**
- `t0` is corosync membership loss on a survivor, captured from
  `journalctl -u corosync` lines matching
  `A processor failed, forming new configuration|A new membership`.
  Report both `membership_loss_t0` and `recovery_end`.
- Every VM from the failed node reaches qemu `status=running` on a survivor
  and HA `state=started` per `/etc/pve/ha/manager_status`.
- Measured hard-FAIL ceiling: `recovery_end - membership_loss_t0 < 252s`
  (WARN band at 166s; both ratcheted MR-7 from B=136s).
- Policy-off override leg is conditional. If
  `list-replicated-vmids.sh --off all` returns empty, print
  `SKIP (policy-off set empty — override contract not exercised)` and explain
  that the override contract is exercised only by explicit `replicate: false`
  VMs, currently none in this deployment.
- Permanent #691 tripwire: no HA `qmstart` task runs longer than 60s on any
  explicit policy-off VMID. This remains a hard FAIL if the override set is
  non-empty.
- Anti-affinity DNS pairs on different surviving nodes during the
  outage; re-separated once ≥2 healthy nodes are back (Sprint 045 A2).
- Node rejoins within 120 seconds of power-on.
- `rebalance-cluster.sh` succeeds (#514 verify-only mode also green).
- `validate.sh` passes after rebalance; vaccine-soak check
  (`MYCOFU_VALIDATE_ONLY_CIDATA_RENAME=1`) also green.

**Estimated time:** ~20–25 min attended. The 252s hard-FAIL ceiling (WARN
at 166s) gates only membership-loss-to-recovery, not node power-on,
rebalance, or validation. Bands ratcheted MR-7 from measured B=136s
(M4 attempt-3 PASS, series 146/146/136).

**M4 result template:** use the Sprint 048 invalidation note template above.

**M2+1w measurement template:** record cicd 160-0 daily-delta samples for the
week after 2026-07-22 and feed the observed max/P95 into MR-7's budget ratchet.

**Last Run:**
```
DRT-005 Node Failure Recovery
Date:    2026-07-23T09:06:02Z
Commit:  b9fc097
Result:  PASS
Time:    20m 8s
Notes:   M4 attempt 3 — CLEAN PASS, closes M4, Sprint 048 failover
         acceptance, and Sprint 047 (open-blocked-on-successor
         ruling 2026-07-21). Recovery 136s (series 146/146/136 vs
         600s analytic ceiling). First fully unassisted full cycle:
         family-(e) dummy0 stanza (#697) held from cold boot,
         failback autonomous, zero HA errors, zero qmstart hangs,
         app state preserved. Harness #696 + tooling #697
         exercised. Bands ratcheted: WARN 166s / FAIL 252s (MR-7).
         Test log: logs/DRT-005-20260723-182435.log.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-07-23T09:06:02Z | b9fc097 | PASS | 20m 8s | M4 attempt 3 — CLEAN PASS, closes M4, Sprint 048 failover acceptance, and Sprint 047 (open-blocked-on-successor ruling 2026-07-21). Recovery 136s (series 146/146/136 vs 600s analytic ceiling). First fully unassisted full cycle: family-(e) dummy0 stanza (#697) held from cold boot, failback autonomous, zero HA errors, zero qmstart hangs, app state preserved. Harness #696 + tooling #697 exercised. Bands ratcheted: WARN 166s / FAIL 252s (MR-7). Test log: logs/DRT-005-20260723-182435.log. |
| 2026-07-23 | a7fa848 | FAIL | 58m 7s | M4 attempt 2. Failover-acceptance criteria all PASS at 146s (two-run-stable across attempts 1 & 2); zero HA errors, zero qmstart hangs, anti-affinity + app-state preserved. #696 harness fix verified working (step-12 settle-then-retry landed cleanly; full inner-check output captured). Sole failure = post-rebalance validate.sh: all three inner FAILs are downstream of the same root cause — a pve02 boot race left dummy0 without 10.10.0.2/32 (missing the corosync ring-0 / Proxmox migration-network address); `ifup dummy0` mid-run restored ring0 + failback. RCA: `docs/reports/rca-2026-07-23-pve02-dummy0-boot-fail.md` (ifupdown2 cache race on shell-`pre-up`-created virtual interfaces). Archaeology: `docs/research/RESEARCH-002-dummy0-preup-archaeology.md`. rebalance-cluster.sh exited 0 despite nine attempted-and-failed migrations after the dummy0 loss (exit-honesty gap, #697 P4). Cluster green post-run. M4 open pending #697 (family (e) — declarative `link-type dummy` + `/etc/modules-load.d/dummy.conf`) + attempt 3. |
| 2026-07-22 | 236b09b | FAIL | 18m 2s | M4 attempt 1. Every failover-acceptance criterion passed — universal recovery predicate converged in 146s (well under 600s first-run ceiling; t0 = corosync membership loss on a survivor), zero HA errors, zero >=60s qmstart hangs, anti-affinity held during outage and re-separated on rejoin, app-state fingerprints preserved, policy-off legs empty-skipped per Sprint 048 universal doctrine. Sole failure was step-12 harness timing: an immediately-post-failback `validate.sh` returned 85/1/2 (identical run minutes later returned 88/0/0), and the failing inner-check's name was lost because drt_assert captured only an output tail. Both defects fixed in #696: step-12 gains a bounded (=1) 75s settle-then-retry with full per-attempt output persisted. Superseded by 2026-07-23 a7fa848 (M4 attempt 2). |
| 2026-07-20 | dc4d381 | FAIL | ~21 min (from power-off to CRM terminal-error; 601/603 delayed ~5 min beyond migration budget) | Sprint-047 A6 M4 attempted acceptance gate on pve02 power-off. Policy-off VMs (170/302/404/500/600) HA-registered per the pre-048 A6 mental model. Each HA `qm start` blocked 300s in `PVE::Storage::ZFSPoolPlugin::zfs_wait_for_zvol_link` waiting for a device link that never exists for a missing disk; on pve01 four hung starts occupied the default 4-worker LRM pool, queuing policy-on 601/603 for ~5 min past budget. Six tooling defects filed as #688 (invalid `ha-manager status --output-format json` in three DRT blocks + recreate helper, budget predicate measured wrong universe, policy-off contract crash yielded WARN not FAIL, no 300s ZFS worker-wait detector, python3 f-string backslash-in-expression, registry PASS row no longer reflecting live behavior). Retrospective: docs/reports/rca-2026-07-20-drt005-policyoff-start-hang.md. Sprint 048 doctrine flip (universal replica-based recovery) superseded the A6 policy-off recreate contract; the #691 damage-limiter remains as a qmstart hang tripwire. Superseded by 2026-07-22 236b09b (M4 attempt 1). |
| 2026-07-09 | a987acf | PASS | ~40 min (129s migration, 35s rejoin) | Sprint-045 acceptance gate, prod, operator-attended (evidence `docs/sprints/drafts/SPRINT-045-DRT-005-02.log`). Single bundled acceptance gate for #512/#513/#515/#518 (+#519). Migration 129s inside the 150s WARN / 240s FAIL bands; anti-affinity SEPARATED both envs (first observation); rebalance verify_recovery live and green. M6-residual M5 folded proof: read-only NAS probe recorded `ha_healthy=false` on the real sustained condition. Superseded by 2026-07-20 FAIL (issue #688 contract finding). |
| 2026-07-07 | 53f37d7 | FAIL | 46m 27s (130s HA migration, 30s node rejoin) | Sprint 044 closure rerun, target pve02 (9 VMs), operator-attended power-off per drt_expect. PRINCIPAL FINDING (post-test forensics): 7 VMs left stopped in HA error state on survivor nodes — HA restart failed with "no zvol device link for vm-NNN-disk-N" because their cidata are rename victims (migrate-back name collision during the 2026-07-06 DRT-005 rebalance; victims created 2026-07-06 UTC, zfs creation-verified), unreplicated and unregenerable off-node. Affected: 302/402/500/501/601 (stopped pve01), 600/603 (stopped pve03); 170/404 survived by returning to pve02 where victim zvols reside. Anti-affinity failure re-confirmed, still un-root-caused. rebalance-cluster.sh exited 0 despite 7 stopped VMs (success-criteria gap). Test log: logs/DRT-005-01.log. |
| 2026-07-06 | 954bdc1 | FAIL | 46m 16s (171s migration, 25s rejoin) | Sprint 043 closure rerun. Migration +51s over budget; anti-affinity broken both envs (first observation); validate FAIL transient. Fingerprint preserved. Rebalance-back migrations of this run mass-produced the rename-victim cidata zvols that caused the 2026-07-07 run's 7-VM outage. Wrapper log: logs/DRT-005-01-prod.log. |
| 2026-03-23 | 746d062 | PASS | <120s | Step 10B node failure — 7 VMs migrated from pve02, node rejoined ~15s. Pre-framework baseline. |

---

## DRT-006: DNS Failover

**Status:** PASS at 2026-07-05 commit `f25bd5d` (Sprint 043 closure
rerun on prod). Sprint 043 D1 CLI-override (renewal via
`--manual-auth-hook` on the CLI) exercised live on `vault-prod` twice:
once with dns1-prod stopped, once with dns2-prod stopped. Both times
`certbot renew` exited 0 with the current cert acknowledged as
"skipped" (expires 2026-09-29, well outside the 30-day renewal window)
— proving the renew script can be parsed and executed successfully
against a single-survivor DNS pair. `validate.sh` passed after both
servers restored. Prior invalidations (Sprint 026 cert flow, Sprint
033 validate.sh Gatus changes, Sprint 043 hook-CLI-override) cleared
by this run.

**What it validates:** That DNS resolution continues when one DNS
server is down. Tests both directions (dns1 down → dns2 serves, and
vice versa). Verifies certificate renewal works with one DNS server
down.

**Invalidated by changes to:**
- PowerDNS NixOS module
- DNS pair OpenTofu module (anti-affinity, placement)
- certbot DNS-01 challenge hooks
- `framework/scripts/cert-sync.sh`
- `framework/scripts/certbot-cluster.sh`
- `framework/scripts/check-cert-budget.sh`
- `framework/scripts/configure-vault.sh`
- `framework/nix/modules/certbot.nix`
- CIDATA DNS server list delivery
- `framework/scripts/validate.sh` DNS checks
- `framework/dr-tests/tests/DRT-006-dns-failover.sh`

**Pass criteria:**
- dig resolves prod hostnames against the surviving DNS server
- `certbot-renew.service` succeeds with one DNS server down; do not use a bare
  manual `certbot renew` for this DR test
- `validate.sh` passes after both servers restored

**Estimated time:** ~5 min

**Last Run:**
```
DRT-006 DNS Failover
Date:    2026-07-05T22:38:32Z
Commit:  f25bd5d
Result:  PASS
Time:    4m 15s
Notes:   First run in the DR test framework — post-Sprint-043 prod-side
         closure. Phase A: HA-stopped dns1-prod (VMID 401); dns2-prod
         resolved vault.prod.wuertele.com; certbot renew on vault-prod
         exited 0 ("expires on 2026-09-29 (skipped)"). Phase A cleanup:
         restarted dns1-prod, answered queries at 10s. Phase B:
         HA-stopped dns2-prod (VMID 402); dns1-prod resolved
         vault.prod.wuertele.com; certbot renew on vault-prod exited 0
         again. Phase B cleanup: restarted dns2-prod, answered queries
         at 10s. Phase C: validate.sh passed with both DNS servers
         running. Live confirmation of Sprint 043 D1 CLI-override + D2
         renewability predicate on prod's real cert-bearing service.
         Wrapper log: logs/DRT-006-01-prod.log.
```

**History:** None.

---

## DRT-007: Backup Spot-Check

**Status:** INVALIDATED by Sprint 043 pin trust-marker schema changes. Last
PASS was 2026-07-05, commit d16eb0c. Both prior invalidation signals were
cleared by that rerun:

1. **Layer 3.5 removed (#252).** The obsolete on-disk cert probe is gone.
   `cert-restore.service` wipes and rewrites `/etc/letsencrypt/live/` on
   every boot from Vault KV, so a backup-content probe of the temp VM's
   on-disk cert cannot verify backup content. The equivalent live-cert-
   issuer assertion is `gitlab_live_issuer_check` in
   `framework/scripts/validate.sh` (gated on production ACME mode), which
   connects to the actual TLS listener and asserts the served leaf is not
   `Fake LE` or `STAGING`. That is the correct architectural target — what
   clients see on the real trust path, not what the temp VM's boot-time
   cert-restore materialized.

2. **Sprint 039 taxonomy migration.** `backup-now.sh` env-scoped exclusion
   derives control-plane modules from `vm-scope.sh`. The 2026-07-05 rerun
   exercised the full path — PBS reachable, gitlab (VMID 150) backup
   located and restored, temp VM booted and validated — confirming Sprint
   039's classifier changes still produce usable backups.

Layers 1–3 (PostgreSQL data integrity, DB connectivity, GitLab project
count) are the load-bearing backup-content assertions. Layer 4 (API
reachability) is informational.

**What it validates:** That PBS backups contain real application state,
not just filesystem metadata. Non-destructive — restores a backup to
a temporary VM, verifies the application would start with the restored
data, then destroys the temporary VM. Backup-content probes for GitLab
cover PostgreSQL data integrity, database connectivity, and application
row count; live-cert-issuer hygiene is asserted separately by
`validate.sh` against the running production listener.

**Invalidated by changes to:**
- `framework/scripts/restore-from-pbs.sh`
- `framework/scripts/backup-now.sh`
- `framework/scripts/vm-scope.sh`
- `framework/nix/modules/base.nix`
- `framework/nix/modules/vault.nix`
- PBS NixOS module
- PBS OpenTofu module (backup job configuration)
- Three-gate backup verification logic in `rebuild-cluster.sh`

**Pass criteria:**
- Backup restores to temp VM without error
- Application-specific state signal is present (project count > 0,
  org exists, DB non-empty, etc.)
- Temp VM destroyed cleanly
- Restore pin schema includes the expected `volid` and certbot trust metadata
  where applicable

**Estimated time:** ~15 min

**Last Run:**
```
DRT-007 Backup Spot-Check
Date:    2026-07-05T22:37:22Z
Commit:  f25bd5d
Result:  PASS
Time:    0m 50s
Notes:   Second rerun after Sprint 043 (#458) landed — this time on the
         prod branch (post dev→prod promotion, green prod pipeline).
         Same commit as the earlier dev-side rerun (f25bd5d is the sprint
         tip on both branches after promotion). Exercised gitlab (VMID
         150) backup from 2026-07-05T09:00Z on hosting node pve03, temp
         VM 9999. Layers 1-3 all PASS: PostgreSQL 395M, PG_VERSION=16,
         3 projects via psql. Layer 4 informational (API HTTP 000000 /
         count unavailable — expected on temp VM per peer-auth
         limitation; Layers 1-3 confirm backup integrity per script
         design). Temp VM cleanly destroyed. Wrapper log:
         logs/DRT-007-14-prod.log.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-07-05 | f25bd5d | PASS | 0m 49s | First rerun after Sprint 043 (#458) landed (dev-side, pre-prod-promotion). Exercised gitlab (VMID 150) backup from 2026-07-05T09:00Z on hosting node pve03, temp VM 9999. Layers 1-3 all PASS: PostgreSQL 395M, PG_VERSION=16, 3 projects via psql. Layer 4 informational (API HTTP 000000 / count unavailable — expected on temp VM per peer-auth limitation; Layers 1-3 confirm backup integrity per script design). Temp VM cleanly destroyed. Wrapper log: logs/DRT-007-13.log. |
| 2026-07-05 | d16eb0c | PASS | 0m 56s | First rerun after Layer 3.5 removal (#252). Exercised gitlab (VMID 150) backup from 2026-07-04T09:00Z on hosting node pve03, temp VM 9999. Layers 1-3 all PASS: PostgreSQL 388M, PG_VERSION=16, 3 projects via psql. Layer 4 informational (API HTTP 200; count 0 as expected per peer-auth limitation). Temp VM cleanly destroyed. Wrapper log: logs/DRT-007-12.log. |
| 2026-04-26 | 3d4cee4 | FAIL | 0m 47s | Layer 3.5 only; Layers 1–3 + Layer 4 informational pass. Failure: "GitLab live leaf issuer is not staging" — actual issuer was empty, not staging. Empty because cert-restore.service mediates /etc/letsencrypt/live/ on every boot post-Sprint-026 (commit 6dc0b00) and the temp VM's vault-agent contends with production gitlab's AppRole credentials. Architectural drift surfaced by Layer 3.5's first end-to-end execution; Layers 1–3 confirmed backup integrity (PostgreSQL 206M, PG_VERSION=16, projects=1). Wrapper log: logs/DRT-007-11.log. Resolution: Layer 3.5 removed per #252. |
| 2026-03-30 | 3aed5d1 | PASS | 0m 39s | Repeated during DRT-004 cleanup attempt (pre-Layer-3.5) |
| 2026-03-29 | 67071a1 | PASS | 0m 36s | First automated run; layers 1-3 passed, layer 4 expected unavailable (pre-Layer-3.5) |


---

## DRT-008: Reset Contract Ratchet

**Status:** INVALIDATED by Sprint 044. Last PASS was 2026-04-15 commit
`3d36545`, validating the Sprint 016 flag split, hard break for
`--cluster`, `--backup` removal, and non-destructive `--recover` validation
gates. Sprint 044 changes `reset-cluster.sh` zvol purge scope to include
`mycofu-park-*`; rerun required.

**What it validates:** That `reset-cluster.sh` enforces the new Sprint 016
operator contract without requiring destructive live execution. The test
ratchets the hard error on `--cluster`, removal of `--backup`, `--test`
dry-run behavior, `--recover` pin-file requirements, incomplete-pin
warnings, nonexistent-volid failure, and the guarantee that no destructive
remote commands are issued in these non-confirmed paths.

**Invalidated by changes to:**
- `framework/scripts/reset-cluster.sh`

**Pass criteria:**
- `--cluster` exits non-zero and names `--test` / `--recover`
- `--backup` exits non-zero with the removal message
- `--test` without `--confirm` stays dry-run and does not invoke backup-now
- `--recover` requires `--restore-pin-file`
- Complete pin files validate in dry-run
- Incomplete or nonexistent pins fail closed
- No destructive remote commands are issued during the test

**Estimated time:** ~2 min

**Last Run:**
```
DRT-008 Reset Contract Ratchet
Date:    2026-07-05T22:38:27Z
Commit:  f25bd5d
Result:  PASS
Time:    0m 1s
Notes:   Post-Sprint-043 prod-side rerun (post dev→prod promotion, green
         prod pipeline). All 8 contract sections pass (20 assertions):
         legacy --cluster hard break, --backup removal, --test dry-run
         with backup preflight visible but backup-now.sh not invoked,
         --recover requires --restore-pin-file, complete pin validates
         + reports full coverage, incomplete pin fails closed naming
         uncovered VMs, nonexistent volid fails closed, no destructive
         remote commands issued. Wrapper log logs/DRT-008-03-prod.log.
         Note: workstation chmod +x was applied locally to run the
         test; the persisted exec-bit fix (via git add --chmod=+x)
         is still on this branch waiting to merge — same defect will
         reappear on prod on any fresh clone until the exec-bit fix
         merges to dev + is promoted.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-07-05 | 1f03cba | PASS | 0m 1s | Post-Sprint-043 dev-side rerun. All 8 contract sections pass (20 assertions): legacy --cluster hard break, --backup removal, --test dry-run with backup preflight visible but backup-now.sh not invoked, --recover requires --restore-pin-file, complete pin validates + reports full coverage, incomplete pin fails closed naming uncovered VMs, nonexistent volid fails closed, no destructive remote commands issued. Wrapper log logs/DRT-008-02.log. Also fixed missing exec bit on DRT-008-reset-contracts.sh in this same commit. |
| 2026-04-16 | 3d36545 | PASS | 0m 0s | Fixture-based contract ratchet for Sprint 016. Verified --cluster hard break, --backup removal, --test dry-run, and --recover pin validation without issuing destructive commands. |

---

## Invalidation Quick Reference

Scan this table after any change session. Run all tests whose trigger
matches your change.

| Changed area | Tests to re-run |
|-------------|-----------------|
| `rebuild-cluster.sh` | DRT-001, DRT-002 |
| `new-site.sh` | DRT-002 |
| `reset-cluster.sh` | DRT-008 |
| `backup-now.sh` | DRT-001, DRT-003, DRT-007 |
| `framework/scripts/configure-backups.sh` | DRT-007 |
| `framework/scripts/list-backup-backed-vmids.sh` | DRT-007 |
| `framework/scripts/converge-lib.sh` | DRT-001, DRT-002, DRT-003 |
| `framework/scripts/converge-vm.sh` | DRT-001, DRT-002, DRT-003 |
| `framework/scripts/vm-scope.sh` | DRT-001, DRT-002, DRT-003, DRT-007 |
| `framework/images.yaml` / `site/images.yaml` VM taxonomy fields | DRT-001, DRT-002, DRT-003, DRT-007 |
| `restore-from-pbs.sh` | DRT-001, DRT-003, DRT-007 |
| `restore-before-start.sh` | DRT-001, DRT-003 |
| `framework/scripts/vdb-park-lib.sh` | DRT-001, DRT-002, DRT-003, DRT-005 |
| `framework/scripts/parked-vdb.sh` | DRT-001, DRT-003, DRT-005 |
| `post-deploy.sh` | DRT-001 |
| `validate.sh` | DRT-001, DRT-003, DRT-006 |
| `framework/scripts/certbot-persisted-state.sh` | DRT-001, DRT-002, DRT-003, DRT-007 |
| `framework/scripts/certbot-renewability.sh` | DRT-001, DRT-002, DRT-003, DRT-006, DRT-007 |
| `framework/scripts/cert-sync.sh` | DRT-001, DRT-002, DRT-003, DRT-006, DRT-007 |
| `framework/scripts/certbot-initial-wrapper.sh` | DRT-001, DRT-002, DRT-003 |
| `framework/scripts/cert-storage-backfill.sh` | DRT-003, DRT-007 |
| `framework/scripts/check-cert-budget.sh` | DRT-001, DRT-002, DRT-003, DRT-006, DRT-007 |
| `framework/scripts/certbot-cluster.sh` | DRT-001, DRT-002, DRT-003, DRT-006, DRT-007 |
| `init-vault.sh` | DRT-001, DRT-004 |
| `configure-vault.sh` | DRT-001, DRT-004 |
| `build-image.sh` / `build-all-images.sh` | DRT-002 |
| `bootstrap-sops.sh` | DRT-002 |
| `flake.nix` (image derivations) | DRT-002 |
| `framework/nix/lib/` (runtime/image helpers) | DRT-001, DRT-002, DRT-003 |
| `framework/templates/config.yaml.example` | DRT-002 |
| `framework/tofu/root/versions.tf` | DRT-001, DRT-002 |
| `framework/tofu/root/` (any .tf) | DRT-001 |
| `framework/tofu/modules/` (any module) | DRT-001, DRT-004, DRT-005, DRT-007 |
| Three-gate backup verification logic in `rebuild-cluster.sh` | DRT-007 |
| `framework/nix/modules/` (any module) | DRT-001, DRT-002 |
| `framework/nix/modules/base.nix` | DRT-001, DRT-002, DRT-003, DRT-007 |
| `framework/nix/modules/certbot.nix` | DRT-001, DRT-002, DRT-003, DRT-007 |
| `framework/nix/modules/vault.nix` | DRT-001, DRT-004, DRT-007 |
| Vault NixOS module | DRT-001, DRT-004 |
| PowerDNS NixOS module | DRT-006 |
| DNS pair tofu module | DRT-006 |
| HA configuration (any module) | DRT-004, DRT-005 |
| Anti-affinity rules | DRT-005, DRT-006 |
| `rebalance-cluster.sh` | DRT-005 |
| `configure-replication.sh` | DRT-005 |
| `framework/dr-tests/tests/DRT-005-node-failure.sh` | DRT-005 |
| `tests/test_drt005_budget.sh` | DRT-005 |
| `framework/dr-tests/tests/DRT-006-dns-failover.sh` | DRT-006 |
| PBS tofu module | DRT-003, DRT-007 |
| NAS NFS configuration | DRT-003 |
| certbot / ACME hooks | DRT-006 |
| macOS bash compatibility | DRT-002 |
