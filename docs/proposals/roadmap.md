# Mycofu Architectural Roadmap

**Date:** 2026-07-04
**Author:** Fable (architectural review per `docs/prompts/mycofu-fable-roadmap-prompt.md`)
**Goals referenced:** the distilled G1–G7 (MR !349). Old "Goal N" citations
in quoted sources use the original numbering; see architecture.md §2.2 for
the mapping.
**Status:** proposal — every item here is a candidate for operator decision,
not a commitment.

## Method and evidence

This review read: `architecture.md` (goals + commitments), all 43 sprint
specs and the ledger, ~395 report files, all 9 research docs, all 474
GitLab issues (311 open, 163 closed), the full git history (1,374 commits),
and the repo itself via six parallel inventory sweeps (scripts, Nix,
OpenTofu, CI/validation, docs archaeology, site/periphery).

The five highest-leverage claims were then **adversarially verified**: an
independent agent per claim, briefed to refute it against the code and
incident record. Verdicts: one claim was refuted as stated, four were
weakened; every roadmap item below carries only the *surviving* version.

Convention: **[V]** = verified directly against files/history/live issue
corpus during this review; **[A]** = reported by an inventory sweep with
file:line citations (spot-checked, not exhaustively re-verified); **[I]** =
inferred. Open unknowns are flagged rather than papered over.

---

# Phase 2 — System map

## The system in one paragraph

Mycofu converges an N-node Proxmox cluster to a Git commit (node count is
a site variable; three at this site — see the N-node residues note under
Deferred). The commit holds
site intent (`site/config.yaml`, `site/applications.yaml`, SOPS secrets),
NixOS role definitions (`framework/nix/`, `framework/catalog/`,
`site/nix/hosts/`), and OpenTofu wiring (`framework/tofu/`). Convergence
runs through two mechanisms: the GitLab pipeline (data plane) and
workstation scripts (`rebuild-cluster.sh` — control plane and DR). Around
that core sit support subsystems: PBS backup/restore, ZFS replication +
Proxmox HA, certificate management, monitoring (two Gatus instances,
InfluxDB/Grafana), the HIL/PXE regreener, GitHub publishing, benchmarks,
and the NAS (tofu state backend, sentinel Gatus, placement watchdog).

## Layer inventory (dev @ 272e659)

| Layer | Size | Notes |
|---|---|---|
| Shell glue (`framework/scripts/`) | 97 scripts + libs. Largest: rebuild-cluster.sh 2,353 / configure-node-network.sh 1,882 / validate.sh 1,821 / setup-nix-builder.sh 1,358 / reset-cluster.sh 1,224 [A] | All orchestration lives here. Vestigial: `migrate-snippet-state.sh`, `run-step2.sh`+`validate-step2.sh` (an unreferenced island), `ssh-refresh.sh` [A] |
| Nix | 12 framework modules, 5 catalog roles, 12 host files, 4 flake checks [A] | Most intricate machinery: per-role source filtering (Sprint 042). Host files + `roleModulesFor`/`configurationRoles`/`imageRoles` are hand-maintained parallel restatements of the same role set [A] |
| OpenTofu | 11 modules + root `main.tf` (1,123 lines) [A] | Three near-identical VM modules exist only because tofu lifecycle blocks must be static [A]. ~700 root lines are hand-paired dev/prod duplication [A]. Convergence crux: `ignore_changes[initialization]` + `replace_triggered_by[cidata_hash]` (`proxmox-vm/vm.tf:95-116`) [A]. `vault` wraps plain `proxmox-vm` — no `prevent_destroy` (acknowledged Sprint 022 deferral) [A] |
| CI (`.gitlab-ci.yml`) | 2,729 lines, 155 jobs, 15 stages; 136 validate-stage jobs (122 single-test one-liners) [A] | ~116 jobs carry a duplicated inline 8-line `rules:` block; HIL jobs already use a YAML anchor [A]. Dev-push critical path ≈ 8 sequential stages [A] |
| Tests (`tests/`) | ~185 hermetic shell tests [A] | 8 test files + `step0.sh`/`step3.sh`/`test_nocloud_init.py` referenced by nothing [A] |
| DR (`framework/dr-tests/`) | 8 registered tests | **Only DRT-004 and DRT-008 PASS at HEAD; the other 6 are INVALIDATED** [A] — the demonstrated convergence frontier (G3) is mostly stale |
| Docs | architecture.md 7,362 lines; 43 sprints; ~395 report files; 9 research docs [V] | Sprint ledger stopped being closed out after ~Sprint 031 [A]. Report volume is dominated by 3-model review triplets |

## VM inventory

- **Shared/control-plane:** gitlab (150), cicd (160), pbs (190, vendor
  appliance), hil_boot.
- **Prod:** dns1, dns2, vault, gatus, testapp + catalog apps (influxdb,
  grafana, roon, workstation).
- **Dev:** dns1, dns2, vault, acme-dev (step-ca), testapp + catalog dev twins.
- **Precious (`backup: true`):** gitlab, vault×2, influxdb×2, roon×2,
  workstation `/home`.
- **Field-updatable (closure push, never recreated):** gitlab, cicd,
  workstation only. **Every data-plane VM uses the standard wrapper and is
  recreated on any image-hash or CIDATA change** [V, confirmed by refuter
  sweep of module `main.tf`s].

## Dependency spine

```
config.yaml + SOPS
  → tofu-wrapper.sh (yq + sops → TF_VARs; age key ALSO on runner at
    /run/secrets/sops/age-key [V])
  → root main.tf (yamldecode of config.yaml; applications.yaml; zone extras)
  → proxmox-vm modules → CIDATA snippets (uploaded to ALL nodes) + VM
  → nocloud-init.py re-reads CIDATA EVERY boot [V, RESEARCH-001 F1]
  → /run/secrets/* → services

Images: flake per-role filtered src → build:image (10-way matrix)
  → content-addressed <role>-<hash8>.img → upload-image.sh (append-only)
  → image-versions.auto.tfvars (ONE map shared by both envs) → tofu

State: PostgreSQL on NAS (PG_CONN_STR from wrapper; schema "prod")

Restore choreography: backup-now.sh --pin-out → Phase-1 stopped apply
  (start_vms=false, register_ha=false) → restore-before-start.sh
  → Phase-2 apply (start + register HA)
```

## External-state register (hidden-state surfaces, G1 suspects) [A]

1. NAS `/etc/crontab` — placement-watchdog (5 min), pg-backup-tofu (daily)
2. NAS `nohup`'d placement health server :9200 — unsupervised, dies on reboot
3. NAS Docker — gatus-sentinel container + configs
4. NAS PostgreSQL (tofu state) + NFS export
5. UniFi gateway — WAN:53→dns1:8053 forward, VLAN firewall matrix, DNS overrides
6. UniFi DHCP reservations — bringup.md lists 4; config.yaml says none needed (contradiction)
7. APC PDU — outlet map + credentials on-device
8. Intel AMT — per-node firmware config + credentials
9. GitLab UI — scheduled pipelines (bench, reclaim), CI variables, runner registration
10. GitHub — mirror repo + deploy-key registration
11. Registrar — NS/glue records
12. macOS launchd — nix linux-builder
13. Vault runtime — AppRole materialization, Raft snapshot schedule
14. In-tree sensitive files — `operator.age.key`, `framework/step-ca/root-ca.key` (plaintext)

## Purpose-undetermined / vestigial inventory [A]

`migrate-snippet-state.sh` (one-shot 2026-03 migration); `run-step2.sh` +
`validate-step2.sh`; `ssh-refresh.sh`; 8 orphaned tests + `tests/step0.sh`,
`step3.sh`, `test_nocloud_init.py`; `__pycache__` dirs under
`framework/nix/modules/` and `tests/`; `site/tofu/terraform.tfstate` stub;
`.terraform/terraform.tfstate` committed under `framework/tofu/root/` and
`modules/gatus/` with divergent provider pins; `soakMr = 221` hardcoded in
root `main.tf`; roon catalog entry missing the scaffold its peers have;
GETTING-STARTED.md places HAOS at .63 while config.yaml assigns .63 to
hil_boot. Three coexisting issue-label taxonomies (`P1-now…`,
`priority-high…`, `severity::P2`/`type::`/`component::`).

---

# Phase 3 — Wrong-turns analysis

Ordered by downstream cost. Each includes the counterfactual and the
adversarial-verification outcome where one ran.

## WT-1 — VM recreation as the routine convergence primitive for the data plane

**What was decided.** Data-plane VMs are immutable appliances: any change
to a role's image hash (`disk[0].file_id` deliberately NOT in
`ignore_changes` — `proxmox-vm/vm.tf`) or to CIDATA content
(`replace_triggered_by[cidata_hash]`) destroys and recreates the VM. Origin:
the founding image-based deployment model (pre-code architecture.md,
commit cd0881f era) [V].

**What it was solving.** Drift-free deploys; the artifact tested in dev is
bit-identical to what boots in prod; rebuildability as the universal
recovery path (old goals 4/5, now G1/G2). These are real wins and the
model *does* deliver them.

**What it cost.** Recreation destroys vdb, so every routine deploy became a
potential data-loss event for precious-state VMs. The entire
destruction-safety apparatus exists to make that survivable [V]:
restore pins + `backup-now.sh`, the two-phase stopped-apply flow, Sprint 027
(guest-side gate; deleted by 028), Sprint 031 (restore-before-start),
Sprint 038 (PBS compliance), Sprint 041 (append-only uploads +
completeness gates), ~35 destruction-safety issues, and the incident record:
2026-03-12 vault-dev wipe, pipeline 710, pipeline 1199 (prune race torched a
boot image mid-recreate), #460 (a grafana dashboard commit recreated every
dev VM). Sprint 042's per-role source-isolation machinery — the most
intricate code in the Nix layer — exists **only** to shrink this blast
radius. Secondary costs: replication-orphan and cidata-orphan sweeps
(#417–419), SSH known_hosts churn, cert loss on recreation (→ WT-4), and
pipeline wall-clock.

**Adversarial verification.** The obvious counterfactual ("make everything
field-updatable via closure push") was tested and **weakened**: as built,
closure push silently skips CIDATA changes (#408), carries a latent
grub-brick defect (#339), and — combined with `prevent_destroy` +
`ignore_changes[file_id]` — produced a state with *no sanctioned recovery
path* when cicd's live disk corrupted (#340,
`2026-05-14-cicd-broken-after-r1-deploy-retrospective.md`). It also erodes
the tested-artifact property (live zvol accretes drift from N pushes) and
still reboots (#222). The "shrinks the destruction-safety surface" sub-claim
is **false as currently built** — it trades choreography for
unrecoverable-drift risk.

**Design-intent evidence (added 2026-07-05).** The destruction of vdb on
recreation was never the design's intent. architecture.md §11.0's
lifecycle table specifies, for both "Image update (factory)" and "Config
change (CIDATA edit, data-plane)": *"vdb: **Preserved — reattached to new
VM**"*, and the glossary states vdb "persists across VM recreation." That
behavior was never implemented: vdb is an inline `disk {}` block inside
the VM resource (`proxmox-vm/vm.tf:47-52`), so destroy takes it, and
`git log -S reattach` finds no reattachment machinery at any point in
history [V]. vdb destruction is an implementation compromise — the bpg/
tofu model owns data disks inside the VM resource — that was never
reconciled back into the design document; the Sprint-031 restore
choreography emulates, via PBS round-trip, the persistence §11.0 claims
the system has natively. Filed as #478; its option (b) — implement the
documented reattachment — is a candidate alternative to R6 that attacks
this wrong turn's root directly (feasibility spike required).

**Counterfactual.** Had in-place NixOS convergence been the routine
primitive from the start — with recreation reserved for structural changes,
first deploys, and DR — the destruction-safety apparatus would be a
DR-only path exercised by DRT tests instead of code that must hold on every
deploy, and Sprint 042's filter machinery would be unnecessary (an image
hash that doesn't trigger recreation doesn't need per-role isolation).
The framework already trusts closure push for its most precious VM
(gitlab). But the counterfactual is only reachable via the staged, gated
path in R6 — the current field-updatable implementation is not ready to
carry it.

**Status: load-bearing.** Do not delete the restore choreography; it is
what makes the current model survivable (and pipeline 1199 proved it holds).
The subtraction is gradual: narrow the recreation trigger set (R5), harden
then extend in-place convergence (R6), and only then shrink the apparatus.

## WT-2 — CIDATA as an every-boot channel and recreation trigger

**What was decided.** All bootstrap values — and some values that
legitimately change (DNS zone data, Tailscale first-join key, AppRole
creds) — are delivered via CIDATA; `nocloud-init.py` re-reads the ISO every
boot; any content change recreates the VM. [V — RESEARCH-001]

**Cost.** DNS zone edits are VM-recreation events (dns-pair
`main.tf:83-84` puts zone_data in CIDATA; DNS VMs use the standard
wrapper) [A]. The every-boot re-read makes stale/renamed cidata zvols a
live hazard: the Proxmox migration name-collision froze cicd's CIDATA for
~3 weeks (A2 chain, #417), spawning the cleanup-orphan machinery and a
validate.sh WARN. Snippets must be uploaded to all nodes;
converge-cluster.sh Phase A/B exists to heal snippet drift (#358, #359).

**Adversarial verification.** My initial framing ("this removes the main
class of gratuitous recreations") was **refuted**: CIDATA values are
bootstrap-stable by construction (RESEARCH-001 F2), so CIDATA-content
recreations are rare; **image-hash recreations are the dominant class**
(the 2026-06-28 drift: 7 destroys, 0 CIDATA changes; pipeline 1199 was
image-driven). Retiring #417 machinery requires RESEARCH-001 phase 4
(nocloud-init consumes bootstrap-only) *plus* migration-orphan handling —
not phases 1–3. The surviving value is real but narrower: decouple the
three actually-changeable values from VM lifecycle, and make canonical
naming irrelevant via phase 4.

**Counterfactual.** Zone data delivered as a runtime channel (Vault or
git-pull) from day one → DNS edits would be config pushes, not VM
replacements; the A2 investigation chain and #417–419 would not exist.

**Status:** RESEARCH-001 already charts the fix; this review endorses it
with corrected impact claims (R5).

## WT-3 — HA resources managed by OpenTofu through the bpg provider

**What was decided.** Per-VM Proxmox HA registration is a tofu resource
(`proxmox_virtual_environment_haresource`), so HA membership lives in tofu
state and the two-phase `register_ha` variable threads through every
module (~35 sites) [A].

**Cost.** The largest single RCA cluster in the repo (~15 reports): CREATE
silently dropped attributes, Read failed to detect deletion, perpetual plan
drift, the triple-apply workaround, the Sprint 008 "confirmed fixed"
ratchet that wasn't (`report-v0101-ha-read-still-broken-2026-04-09.md`).

**Adversarial verification — important correction.** The bug class is
**already tamed**: `ha.tf` now declares only `resource_id`+`state` (nothing
left for CREATE to drop), `known_changes=0` in validate.sh R7.1, the
triple-apply is removed (#159), and — decisively — a config.yaml-driven HA
reconciler **already exists** (`verify_ha_resources()` in both
safe-apply.sh and rebuild-cluster.sh) running *alongside* tofu, mutating HA
out-of-band via `ha-manager`. The Read-deletion provider bug remains
unfixed upstream but is worked around by that reconciler. [A, spot-checked]

**The residual wrong turn** is therefore *shared authority*: tofu has
already ceded placement (`ignore_changes[node_name]`, rebalance-cluster,
fence flows never touch tofu) and cedes existence-correction to the
reconciler — yet still owns registration, at the price of the `register_ha`
threading and the dual-default footgun (membership plan assumes `true`,
Phase 1 passes `false`). One authority per boundary (G5) argues for
finishing the cession, not maintaining the shard.

**Counterfactual.** HA managed by a reconciler from day one → no provider
haresource surface, no ~15-report saga, and preboot-restore ordering as one
explicit imperative step instead of a variable threaded through every module.

## WT-4 — Per-FQDN public Let's Encrypt certs for every service, coupled to VM lifecycle

**What was decided.** Every service gets its own publicly-trusted LE cert,
stored on the VM; private PKI for prod is a Non-Goal (rationale:
guest-device compatibility — predates the rate-limit incidents by ~2
months [V, git-dated by refuter]).

**Cost.** VM recreation (WT-1) destroys certs → rate-limit exhaustion
(Sprint 023 cascade, le-rate-limit-incident-2026-05-01) → cert-storage in
Vault (Sprint 026) → budget oracle (`check-cert-budget.sh`) →
backfill dedup bug #416 that tripped the budget gate with **zero actual
issuance** (A1 trace: five KV versions in 24h from five prod pipelines on
an unchanged cert). Meanwhile the actual renewal path on vault-prod was
silently broken for weeks (stale nix-store hook path, #458, Sprint 043
planned). Eight sprints and ~13 reports; still churning as of 2026-07-01.
This is the clearest instance of the pattern the review was asked to find:
**three layers of defense (Vault storage, budget gate, backfill) each
patching the consequence of an upstream coupling, each layer then growing
its own bugs.**

**Adversarial verification.** Internal-CA-for-prod is **refuted** as a
cluster-wide replacement — the load-bearing trust boundary is "clients
whose trust store the framework controls," and the operator's browser,
phones (HA companion), and git-over-HTTPS fall outside it; the extra-CA
mechanism only reaches framework-managed NixOS VMs; gatus.prod (the
incident VM) is itself browser-facing. The **wildcard variant survives
narrowly**: `*.prod.<domain>` via the existing certbot+PowerDNS DNS-01,
distributed through the existing Vault cert-restore path — genuinely
deletes the budget/backfill/oracle subsystem (~3 scripts + tests), but
**consciously reverses architecture.md §8.2** (shared key = wider
compromise blast radius, no per-service revocation) and makes Vault cert
distribution *more* central, not deletable. [A]

**Counterfactual.** Wildcard-from-Vault from day one → Sprint 023/026,
the budget machinery, and the rate-limit incident class don't exist; the
cost is one shared private key on ~8 VMs.

## WT-5 — The pipeline as 155 hand-written jobs

**What was decided.** Every hermetic test gets its own CI job with its own
inline rules block. Accreted, not designed — job count grew with the test
suite. Cost: 2,729 lines of YAML that cannot be audited confidently (#369,
codex F7); ~116 duplicated 8-line rules blocks that must be kept in sync;
per-job runner overhead on a shell executor with `concurrent = 8`.

**Adversarial verification.** "Collapse to one discovery job, lose
nothing" is **weakened**: 14 validate jobs are genuinely complex; HIL jobs
need their `exists:` guard; selective per-test retry and per-test duration
history are real losses; the 256M `/tmp` overlay caps mega-job internal
parallelism (commit 2bc28cd's temp-dir exhaustion). Surviving version:
hoist rules to `extends` (≈900+ lines deleted, zero behavior change) and
group the 122 one-liners by subsystem — a pattern the repo already accepted
(`validate:pbs-backup-compliance` bundles 15 tests). [A]

## WT-6 — Dev/prod as hand-duplicated pairs; one shared image map

**What was decided.** Each service is instantiated twice in root main.tf
by hand (~700 of 1,123 lines differ only in env parameters) [A]; AppRole
credentials are 30+ individually-declared TF_VARs [A]; and
`image-versions.auto.tfvars` is a single map shared by both envs, so every
build shows cross-env `file_id` changes — the exact property that killed
the Sprint 032 wave-0e rollout (`Moved resource instances excluded by
targeting`, #300) and that adds cross-env noise to every targeted plan [V].

**Counterfactual.** A `for_each` over an env map plus per-env image maps
(#300 Path 1 — already designed in-issue, 1–2 day estimate) → half the
root module deleted, targeted applies structurally clean, and the Sprint
032 redesign unblocked.

## WT-7 — Accretion without a decay path (process wrong turn)

**Not one decision but a standing bias.** The G3 loop (failure →
structural fix + test + report + issue) generates artifacts faster than
anything retires them. Evidence [V]: 311 open issues (66% of all ever
filed); three coexisting label taxonomies; the sprint ledger unclosed since
~031; 6 of 8 DR tests INVALIDATED with no forcing function (codex F3,
#365); 8 orphaned test files; vestigial scripts; stale docs (HAOS/.63,
DHCP-reservation contradiction, the DHCP-era comments RESEARCH-001 F9
found). Each is small; the aggregate is the "no longer legible even to its
author" condition that motivated this review. The DR-registry decay is the
most dangerous instance: the demonstrated convergence frontier (G3's core
artifact) is mostly stale, so recovery confidence rests on 2-month-old
proofs.

---

# Phase 4 — The roadmap

Items carry: problem, root cause, accreted workarounds, proposed change,
why it is subtraction, reliability effect (goals), complexity effect, risk
& reversibility, implementation sketch, and sequencing. Ordered here by
theme; Phase 5 re-sorts by leverage.

## R1 — Deletion sweep of verified-dead artifacts

- **Problem:** dead code and stale docs mislead every reader (human and
  agent) mapping the system.
- **Root cause:** WT-7 (no decay path).
- **Accreted workarounds:** none — this is pure residue.
- **Change:** delete `migrate-snippet-state.sh`, `run-step2.sh`,
  `validate-step2.sh`, `ssh-refresh.sh`, `tests/step0.sh`, `tests/step3.sh`,
  the 8 orphaned tests (or wire them into CI if any are load-bearing —
  check first), `__pycache__` dirs, the stray tfstate stubs, the
  `soakMr=221` remnant; fix the HAOS/.63 and DHCP-reservation doc
  contradictions; complete or delete roon's catalog scaffold.
- **Subtraction:** ~10 files + ~800 LOC + 2 doc lies removed.
- **Reliability (G1, G7):** the repo stops asserting things that aren't true.
- **Complexity:** fewer artifacts to hold in mind; zero concept count change.
- **Risk:** near-zero; each deletion is `git revert`-able. Verify
  "orphaned" by grep before each removal (the inventory did; re-verify at
  merge time).
- **Sketch:** one MR, one commit per artifact class.
- **Sequencing:** any time; good first mover.

## R2 — Collapse the pipeline's duplicated rules and single-test jobs

- **Problem:** 2,729-line un-auditable `.gitlab-ci.yml` (#369).
- **Root cause:** WT-5.
- **Accreted workarounds:** none load-bearing; HIL anchor shows the intended pattern.
- **Change:** (1) hoist the ~116 duplicated inline `rules:` blocks into
  shared `extends`/anchor definitions — zero behavior change; (2) group the
  122 single-test jobs into ~8–12 subsystem jobs (cert, backup/restore,
  image-store, vm-scope, publish, HIL-guarded group, …) running tests via
  the existing `tests/lib/runner.sh` summary; keep the 14 complex jobs
  standalone.
- **Subtraction:** ≈1,500–2,000 YAML lines; ~110 job definitions.
- **Reliability (G4):** an auditable pipeline is an enforceable one; rules
  drift between copies becomes impossible.
- **Complexity:** one rules definition instead of 116.
- **Risk:** loses per-test selective retry and duration history
  (accepted trade-off — runner prints named failures); mitigate temp-dir
  pressure by bounding runner parallelism. Reversible per group.
- **Sketch:** rules-hoist MR first (mechanical, verifiable by
  `gitlab-ci lint` + pipeline diff); then one grouping MR per subsystem.
- **Sequencing:** independent; before other pipeline work to shrink review surface.

## R3 — Consolidate root main.tf and split image maps per env

- **Problem:** ~700 hand-paired lines; cross-env image churn poisons
  targeted applies (#300); 30+ AppRole TF_VARs.
- **Root cause:** WT-6.
- **Accreted workarounds:** Sprint 032 revert (Option E); categorizer
  special cases in safe-apply.
- **Change:** `for_each` over an env map for paired modules; split
  `image_versions` into per-env maps (issue #300 Path 1, already designed);
  collapse AppRole vars into one `TF_VAR_vault_approles_json` map
  (mirroring `ssh_host_keys_json`); while in the file, replace the 8
  `target_node = local.node_names[N]` index placements with
  `vms.<name>.node` from config.yaml (#475 — source-of-truth violation,
  no recreation risk under `ignore_changes[node_name]`).
- **Subtraction:** ~600+ lines of root module; ~28 variable declarations;
  the #300 redesign blocker.
- **Reliability (G2, G5):** targeted applies become structurally clean —
  a dev deploy can no longer see prod "changes"; removes a whole class of
  cross-env plan noise the operator must interpret.
- **Complexity:** one instantiation pattern instead of two hand-kept copies.
- **Risk:** `for_each` re-keys state addresses → requires a planned
  `tofu state mv` migration (precedent exists: the snippet for_each
  migration). Do it env-by-env with plan-diff gates; reversible until the
  state mv, then roll-forward.
- **Sketch:** (1) approle map var (isolated); (2) per-env image maps
  (touches build scripts + wrapper validation + CI); (3) for_each refactor
  with scripted state mv and a `tofu plan` that must show zero resource
  changes.
- **Sequencing:** after R2 (pipeline legible); before any Sprint-032-shaped
  work resumes.

## R4 — Move HA registration out of OpenTofu into the existing reconciler

- **Problem:** shared HA authority between tofu, ha-manager, and the
  out-of-band `verify_ha_resources` reconciler; `register_ha` threaded
  through ~35 sites with a dual-default footgun.
- **Root cause:** WT-3.
- **Accreted workarounds:** `verify_ha_resources` (two copies),
  R7.1 known-drift bookkeeping, the attribute-stripped `ha.tf`.
- **Change:** delete `proxmox_virtual_environment_haresource` from all
  three VM modules and the `register_ha` variable everywhere; extend the
  existing reconciler to also *add* membership from config.yaml, invoked as
  an explicit step after `restore-before-start.sh` succeeds; consolidate its
  two copies into one lib.
- **Subtraction:** ~35 threaded sites, three `ha.tf` files, the
  R7.1 HA bookkeeping, one whole provider-resource surface (and its
  still-unfixed upstream Read bug).
- **Reliability (G5, G2):** restores one-authority-per-boundary; the
  restore-before-HA ordering becomes an explicit imperative step instead of
  a variable that must be threaded correctly through every module —
  removing the raw-`tofu apply` footgun on backup-backed recreation.
- **Complexity:** HA membership logic in exactly one place.
- **Risk:** the reconciler must be as reliable as tofu CRUD was; it already
  handles remove/orphan paths in production. Fence/recovery flows
  (storage-failure-fence.md) are untouched — they never used tofu.
  Reversible: re-add the resource blocks.
- **Sketch:** (1) unify reconciler copies into `framework/scripts/lib/`;
  (2) add register path + fixture tests; (3) remove tofu resources +
  variables with a state-rm migration; (4) update validate.sh R7.1 and DR
  docs.
- **Sequencing:** after or alongside R3 (same files); before further
  two-phase-apply simplification.

## R5 — Immutable CIDATA: decouple the three changeable values, then make naming irrelevant

- **Problem:** DNS zone edits, Tailscale key rotation, and AppRole rotation
  are VM-recreation events; stale cidata zvols are re-consumed every boot
  (#417 class).
- **Root cause:** WT-2.
- **Accreted workarounds:** cleanup-orphan-cidata.sh + validate WARN +
  operator procedure; converge-cluster snippet healing; the A2
  investigation chain.
- **Change:** adopt RESEARCH-001's recommendation with its own phasing:
  (a) declare + tripwire the immutable-CIDATA contract; (b) zone-data off
  CIDATA (runtime channel — Vault KV or git-pull — decision needed);
  (c) Tailscale first-join key → vault-agent-pull; (d) AppRole → SSH
  secure-introduction (init-vault.sh pattern); (e) **phase 4:** rework
  nocloud-init to consume bootstrap-only — this, plus migration-orphan
  handling, is what actually retires the #417 machinery.
- **Subtraction:** after (b): zone edits stop recreating VMs (the one
  *frequent* CIDATA-driven recreation). After (e): the every-boot re-read,
  the canonical-naming dependence, and eventually the orphan-cidata
  machinery.
- **Reliability (G2, G6):** removes a recreation trigger class and a
  boot-time dependence on mutable external state (the stale-zvol hazard).
- **Complexity:** one fewer channel whose lifecycle must be reasoned about
  per value; `domain`→universal-recreation is retained by design (it is a
  feature [V]).
- **Risk:** each move changes a bootstrap path — needs per-value fallback
  plans; phase 4 touches every VM's first boot. All phases independently
  shippable and reversible.
- **Sketch:** per RESEARCH-001 What-Next: phases (a)–(c) as one sprint
  seed; (d) separate; (e) its own sprint with throwaway-VM experiment
  first.
- **Sequencing:** (a)–(c) independent of everything above. (e) after (a)–(d).
- **Honest scope note:** this does NOT touch the dominant (image-driven)
  recreation class — that is R6.

## R6 — Harden, then extend, in-place convergence for the data plane (staged; gated)

- **Problem:** every routine role change recreates every affected data-plane
  VM (WT-1) — the root demand driver for the destruction-safety apparatus,
  the per-role source filter, upload/reclaim machinery, and orphan sweeps.
- **Root cause:** WT-1.
- **Accreted workarounds:** Sprints 027/028/031/038/041/042 (see WT-1).
- **Change (strictly staged, each stage gated on the previous):**
  0. **Evaluate the #478 alternative first:** architecture.md §11.0
     already specifies vdb as "Preserved — reattached to new VM" across
     recreation (never implemented — see WT-1 design-intent evidence).
     If a feasibility spike shows the data disk can genuinely outlive VM
     replacement (disk managed outside the VM resource, attached by a
     converge step; `qm destroy` purge semantics, replication-job and
     PBS-scope interactions verified), recreation stops being a
     data-loss event *without* switching update mechanisms — which may
     achieve most of this item's endpoint at lower risk than stages 3–4.
     **Status 2026-07-05:** Sprint 044 implements the evaluated stage-0
     bridge for dev only using RESEARCH-004's raw ZFS rename park/adopt
     mechanism. PBS pins remain mandatory, prod promotion is a separate
     decision, and the transition mechanism has a named sunset: replace it
     when upstream PVE ships a keep-volume/detach primitive. Track the
     sunset campaign in
     `docs/reports/2026-07-05-pve-upstream-detach-campaign.md`; issue #412
     must rerun the gated experiment before accepting a future qemu-server
     version beyond the verified 9.0.30 baseline.
  1. **Fix the three known field-updatable defects first** — #408 (CIDATA
     changes silently skipped: make converge-vm re-attach/regenerate the
     snippet or fail loudly), #339 (grub sed unreliability: fix at image/
     bootloader layer, not sed), #340 (define the sanctioned
     recreate-a-field-updatable-VM path, e.g. a scripted `-replace` flow
     with restore envelope). These are open P2s regardless of this roadmap.
  2. Add a drift ratchet: field-updatable VMs must pass a periodic
     "live closure == flake closure" check (exists for control plane —
     check-control-plane-drift.sh) and a reboot-boots-canonically check
     (catches #339-class latency).
  3. Convert the **stateless** data-plane VMs (dns, gatus, testapp) and
     observe across several deploy cycles.
  4. Only then decide on stateful VMs (vault, influxdb, roon) — separate
     operator decision with the WT-1 trade-offs restated.
  5. Recreate remains the first-deploy and DR path forever (G2 requires
     destroy-and-recreate to stay available and DR-tested).
- **Subtraction (eventual):** routine deploys stop being data-destruction
  events; restore choreography becomes DR-only; Sprint-042 filter machinery
  becomes removable (an image hash that doesn't trigger recreation doesn't
  need blast-radius isolation); upload/reclaim pressure drops.
- **Reliability (G2, G3):** deploy-time failure modes shrink from
  "destroy+restore must succeed" to "closure switch must succeed, with
  recreate as fallback."
- **Complexity:** near-term **increase** (two update paths in flight) —
  stated honestly; net reduction only lands at stage 4+.
- **Risk:** the refuter's findings are the risk register: image-parity
  erosion (mitigated by the stage-2 ratchet), latent boot corruption
  (#339 fix is a hard gate), no-recovery-path states (#340 fix is a hard
  gate). Each stage reversible by reverting the wrapper choice per VM.
- **Sequencing:** stage 1 can start now (they're open bugs); stage 3 after
  R5(a) so CIDATA immutability is declared first; do NOT delete any
  Sprint-042/destruction-safety machinery until stage 4 has soaked.

## R7 — Certificate model decision: wildcard vs. status quo (operator decision)

- **Problem:** the per-FQDN LE model carries a three-layer defensive stack
  (Vault cert storage + budget oracle + backfill) that has itself produced
  incidents (#416/A1: budget tripped with zero real issuance).
- **Root cause:** WT-4.
- **Accreted workarounds:** `check-cert-budget.sh`, `cert-storage-backfill.sh`,
  KV-version oracle, `--ignore-cert-budget`-shaped escape valves, Sprint 043
  (planned).
- **Change (two honest options):**
  - **(i) Wildcard:** one `*.prod.<domain>` LE cert, issued by one holder
    (vault VM or a dedicated issuer), distributed via the existing Vault
    cert-restore/cert-sync path. Deletes the budget gate, backfill, and
    oracle. **Consciously reverses §8.2**: one shared private key across
    ~8 VMs, no per-service revocation. Public trust preserved (browsers,
    phones, git clients all fine).
  - **(ii) Status quo hardened:** keep per-FQDN; land Sprint 043
    (persisted-state trust) and #473; keep the budget stack.
  - Internal CA for prod is **off the table** as a general replacement
    (refuted — guest-device trust); at most a narrow step-ca sliver for
    zero-external-client endpoints (dns API, InfluxDB), which does *not*
    delete the budget stack and is likely not worth the split model.
- **Subtraction (option i):** 3 scripts + their tests + the oracle concept
  + the rate-limit incident class (first-issuance/renewal residual risk
  only).
- **Reliability (G2):** cert issuance stops being coupled to deploy
  cadence entirely.
- **Complexity:** −3 defensive subsystems; +1 shared-key risk to document.
- **Risk (option i):** key compromise blast radius; renewal is a single
  point (mitigated: 30-day renewal window + Gatus cert monitors already
  exist). Reversible — per-FQDN issuance can resume anytime.
- **Sketch (i):** issue wildcard on one VM → store in Vault → point
  cert-restore at the shared path per FQDN → retire budget/backfill after
  one renewal cycle.
- **Sequencing:** independent; decision unblocks or obviates Sprint 043
  scope.

## R8 — DR-registry revalidation ratchet

- **Problem:** 6 of 8 DR tests INVALIDATED; the convergence frontier (G3)
  is asserted, not demonstrated (#365, codex F3).
- **Root cause:** WT-7 — reruns are manual, expensive, and nothing forces them.
- **Change:** (a) make registry staleness visible where it bites: a
  validate.sh WARN (or pipeline badge) when any DRT is INVALIDATED longer
  than N days; (b) schedule the two cheap non-destructive tests (DRT-007
  ~15 min, DRT-008 ~2 min) as periodic pipeline jobs after fixing #252;
  (c) fold a DRT-001 rerun into the next planned maintenance window and
  record it.
- **Subtraction:** none directly — this is the one additive item, justified
  as the smallest addition that keeps G3's core artifact honest (and it
  gates future deletions: R6 stage 4 must not proceed on a stale registry).
- **Reliability (G3, G4):** recovery confidence becomes current instead of
  archaeological.
- **Risk:** low; WARN-first, no gate until trust established (per G4's
  fail-loudly-but-don't-lie principle).
- **Sequencing:** before R6 stage 3+ and before any deletion of
  destruction-safety machinery.

## R9 — Shrink SOPS to the bootstrap residual; evaluate taking the age key off the runner

- **Problem:** `site/sops/secrets.yaml` is the most-modified file in the
  repo (217/1,374 commits [V]) — secret ceremonies are commit ceremonies;
  write-once invariants keep needing guards (#105, #110, #136). The CI
  runner holds the age key, so the pipeline can read *all* secrets [V] —
  the D2 discussion deferred evaluating whether it should.
- **Root cause:** SOPS serves as both bootstrap store and ongoing secret
  plane; Vault exists but is downstream of it.
- **Change (evaluation first, then staged):** classify every SOPS key as
  bootstrap-residual (age-encrypted, rarely written: node/API creds, ssh
  host keys, unseal/root tokens) vs. operational (runner tokens, app
  tokens, AppRole creds — candidates to live in Vault only). Then: (a)
  move operational secrets' source of truth to Vault, generated by the
  scripts that already write them, ending their SOPS write-backs; (b)
  evaluate replacing the runner's age key with a Vault AppRole scoped to
  deploy-time needs — ramifications documented for operator decision
  (per the Phase 1 D2 resolution).
- **Subtraction:** the majority of SOPS write paths and their write-once
  guard code; a broad-scope credential on the runner (option b).
- **Reliability (G1, G5):** fewer bidirectional-state couplings of the
  kind pbs-restore.md warns about; smaller pipeline secret blast radius.
- **Risk:** bootstrap ordering (Vault must exist before Vault-stored
  secrets are readable — the residual classification exists precisely to
  keep the bootstrap path SOPS-only). Chicken-and-egg audit required
  before (b); DR path (rebuild with Vault down) must stay SOPS-sufficient.
- **Sequencing:** evaluation doc first (research-shaped); implementation
  after R5(d) (AppRole delivery rework overlaps).

## R10 — External State Register + NAS runtime fixes

- **Problem:** 14 external-state surfaces (Phase 2 list) exist outside
  Git+cluster with no single inventory (codex F10, #372); one is actively
  fragile (the `nohup`'d health server dies on NAS reboot, violating the
  repo's own nas-scripts rule).
- **Change:** commit the Phase 2 register as an operator doc with, per
  surface: owner, how it's (re)created, how drift is detected; fix the
  health server (Synology Task Scheduler boot trigger); resolve the
  DHCP-reservation contradiction; evaluate #246 (should sentinel live on
  the NAS at all) as a register entry rather than a standalone debate.
- **Subtraction:** none in code; subtracts unknowns. Register maintenance
  cost is the honest price.
- **Reliability (G1):** hidden state becomes enumerated state.
- **Sequencing:** any time; pairs with R1.

## R11 — Wrap vault in the precious module

- **Problem:** vault (Raft on vdb, Category 3) uses plain `proxmox-vm` —
  no `prevent_destroy` — an acknowledged Sprint 022 deferral and a latent
  one-command data-loss footgun [A].
- **Change:** switch the vault module wrapper to `proxmox-vm-precious`;
  verify the rebuild-cluster `-replace` flow (already handles gitlab per
  #143/#144) covers vault recreation.
- **Subtraction:** one latent footgun; zero new concepts (module exists).
- **Risk:** intentional vault recreation now requires the `-replace`
  envelope — that is the point. Small MR, easily reverted.
- **Sequencing:** any time; arguably first (it's the cheapest real
  risk-reduction in this document).

## R12 — Process hygiene: one label taxonomy, truthful ledger

- **Problem:** three label taxonomies; ledger wrong since ~031 — status
  data can't be trusted, which feeds WT-7.
- **Change:** pick one taxonomy (the scoped `severity::`/`type::` style is
  the most machine-usable), batch-migrate labels via API, close ledger rows
  against the evidence already in docs/reports, and add "close the ledger
  row" to the sprint-completion definition-of-done.
- **Subtraction:** two taxonomies; a standing source of false status.
- **Sequencing:** any time.

## R13 — Recreation as the only convergence verb (the R6 fork; self-recreation via a node-resident executor)

- **Status:** research candidate. Captured 2026-07-09 from an architect/operator
  design dialogue prompted by a live incident. **Not scheduled** — this is the
  deliberate *opposite fork* to R6, recorded so the R6-vs-R13 direction is a
  conscious decision rather than a default. Deep dive seeded in
  `docs/prompts/prompt-research-seed-recreation-only-convergence.md`.
- **The fork:** WT-1 (recreation destroys precious data / drives the whole
  destruction-safety apparatus) has two escape directions:
  - **R6** — *reduce* recreation by hardening and extending in-place
    convergence (mechanism-B closure push + `nixos` switch). Keeps two update
    paths; R6 itself notes the near-term **complexity increase** and that net
    reduction "only lands at stage 4+."
  - **R13** — *embrace* recreation as the **only** convergence verb, delete
    in-place convergence entirely, and solve the one case it can't reach today
    (a VM recreating itself) with an external executor + async handoff.
- **The insight that motivates it:** every hard defect in the in-place path is
  an *artifact of having an in-place path.* #339 (install-grub emits the
  malformed `)/store/` grub path) cannot exist in a pure-recreation world — a
  fresh VM boots a content-addressed image with correct grub every time. The
  mechanism-B profile-generation drift (running `current-system` ≠ the profile
  link) and the reboot-during-switch edges are likewise in-place artifacts.
  Recreation-only *deletes* that bug class rather than hardening it (R6 stage 1
  hardens #339/#340; R13 makes them non-existent).
- **The mechanism (why "you can't recreate yourself" is an engineering
  inconvenience, not a law):** the precise constraint is only that *the process
  which gets destroyed cannot be the one that completes the operation.* Solve it
  with (a) an **external agent that is not a VM** — a Proxmox **node** is durable
  (installed by the PXE/answer-file path, never recreated by tofu), running
  `rebuild-cluster.sh`'s guts relocated off the workstation; and (b) **request/
  queue decoupling** — the in-VM pipeline job enqueues a recreate request
  (commit, image versions, restore pin), triggers the node executor, and *exits
  or is allowed to die*; a **subsequent** pipeline run (or the executor) verifies
  the outcome. GitLab self-recreation *forces* this decoupling (recreating the
  coordinator destroys the API the requester used) — which is the proof that
  sync-and-report is the thing that's impossible, not recreation.
- **The strongest argument for it (beyond line count):** recreation-only makes
  the **restore/DR path the everyday path.** The thing everyone fears — does the
  Sprint-044 bridge / PBS preboot-restore actually work — moves from quarterly
  DRTs to *every deploy*, continuously tested. Deeply aligned with G1 (commit
  fully determines the system; no in-place drift ever) and G2 (region grows
  because every deploy is a clean rebuild).
- **The honest costs:** per-change latency and blast radius (every changed role
  recreates — bounded by content-addressing so unchanged roles don't, and made
  vdb-cheap by the Sprint-044 bridge, but heavier than a switch); the node
  executor needs deploy authority (SOPS keys, tofu/PG state) **on the nodes** —
  a real relocation of secret/blast-radius surface off the workstation; and
  async request/verify is a new orchestration pattern (harder to reason about
  than a synchronous job, and it needs a durable place for the "did it come back
  correctly?" answer to land).
- **The pivotal question (potentially disqualifying):** G1 applies to the
  **executor itself.** The executor is implemented in git, so a change to its
  implementation must propagate to the running executor — it **cannot be the
  exception.** A privileged, hand-maintained, convergence-exempt executor "on a
  durable node" is a G1 violation, and G1 outranks everything but simplicity.
  This recurses ("who converges the converger?", with a window where no live
  executor exists to finish its own replacement) and threatens R13's core claim:
  if the executor needs a special convergence story recreation-only can't cleanly
  provide, R13 hasn't achieved "one verb" — it has *relocated* the exception,
  which is worse for G1 and simplicity than the in-place mode it deleted. The
  research must produce a G1-clean self-convergence for the executor or conclude
  R13 is disqualified. (Note the nodes are *already* a partial G1 seam —
  External-State Register — which R13 must close, not amplify.) **Leading
  candidate answer:** a reciprocal "ping-pong" recreator pair — A recreates B, B
  recreates A, so each is always converged by a live peer with no steady-state
  exception, leaving only the **foundational** bare-metal-bootstrap floor
  (Mycofu's founding "Proxmox + one command" promise — not a new cost; **R14**
  aims to shrink it to its true minimum: workstation seeds cicd only). The pair may
  reuse the capacity-motivated multiple-cicd VMs (#509/#517/#362), making the
  second component largely pre-paid — subject to a G5 check on putting deploy
  authority on the churny runner. See the seed for the honest hard parts
  (cold-start floor, simultaneous-change sequencing/split-brain, bad-recreator
  rollback gate).
- **The decision criterion:** does the in-place complexity **deleted**
  (mechanism-B + its bug class + R6's mode-selection guard + reboot sequencing)
  exceed the async complexity **added** (node executor + request queue + verify
  callback + deploy authority on nodes)? That is a numbers question for the
  research pass, not a hallway verdict.
- **Relationship to the near-term control-plane-convergence-safety fix**
  (approved 2026-07-09, being implemented separately): that fix adds a
  **converge-vs-recreate guard** — the pipeline converges control-plane in place
  autonomously and fails closed to the workstation *only* when the plan shows a
  control-plane *replace*. **That guard is precisely the seam where R13's external
  executor would later attach:** today the branch says "recreation needed → route
  to workstation"; R13 replaces that one handler with "recreation needed →
  enqueue to the node executor." So the near-term fix is a **stepping stone**
  toward R13, not a fork away from it — nothing is foreclosed.
- **Evidence (2026-07-09 incident):** a routine dev cert fix (!396, shared-base
  rehash) drove the pipeline to converge control-plane in place, autonomously,
  with no workstation step — proving the autonomous-convergence capability
  *already exists and runs*. cicd converged in place (uptime unbroken — never
  recreated) and was one grub-write bug (#339) from clean; GitLab rebooted during
  its own convergence, blipping the coordinator (a source of the #531 trace
  zombies). The damage originated entirely in the in-place path — which is the
  case for weighing R13 against R6.
- **Sequencing:** decide the R6-vs-R13 direction *before* committing heavily to
  either's later stages (R6 stages 3–4, or R13's executor build). The research
  pass produces that decision. Until then, the near-term guard keeps both futures
  open.

## R14 — Collapse to a single convergence pathway: workstation bootstraps cicd; cicd converges the rest (aspiration)

- **Status:** aspiration / direction (operator, 2026-07-09) — "more aspiration
  than plan." Captured to steer R6/R13, the two-tier model, and R9 toward it.
  This is the *pathway-level* companion to R13's *verb-level* question.
- **The wart:** two convergence pathways do overlapping work. The workstation
  (`rebuild-cluster.sh`, 2,353 lines) converges the **whole** cluster
  (control-plane + data-plane, cold-start + DR); the GitLab pipeline (on cicd)
  converges the data-plane subset. Two parallel implementations of
  "config.yaml → running cluster," kept in agreement by hand. This duplication is
  the root of the two-tier boundary confusion (what may the pipeline touch?) — the
  same boundary whose failure caused the **2026-07-09 control-plane-recreation
  incident** (a routine dev merge recreated GitLab + brick-risked cicd).
- **The founding promise, made true:** Mycofu's claim has always been "Proxmox
  installed + one workstation command → fully-converged HA cluster." The
  cold-start bootstrap floor is therefore **foundational, not a new cost**
  (correcting the R13 framing). But the workstation currently *does the whole
  cluster*, making it a full second convergence engine rather than a bootstrap.
  **Aspiration:** shrink the workstation's job to its true minimum — build and
  deploy **only the cicd VM** — after which the (single) cicd performs the
  **entire** remaining convergence to fully-converged.
- **The win:** ONE convergence engine (cicd), exercised one way, instead of two
  parallel ones. `rebuild-cluster.sh`-converges-everything collapses to "seed
  cicd." **DR unifies with normal operation** (DR = re-seed cicd → cicd converges
  the rest — R13's "restore path is the everyday path," at the pathway level).
  **The two-tier boundary dissolves:** cicd converging control-plane is the
  design, not a Tier-1-touching-Tier-2 hazard; the only special case left is
  cicd's own bootstrap. Image-building consolidates onto cicd (mostly already
  there), retiring the macOS nix-builder as a whole-cluster dependency and
  shrinking the workstation's SOPS/deploy-authority surface (aids R9).
- **Where the hard cases go:**
  - **cicd converges GitLab** (its own coordinator) — the reboot-blip accepted by
    the operator 2026-07-09 ("a brief GitLab blip during its own convergence is
    acceptable"). Async / bracket-and-wait.
  - **cicd converges cicd** — the self-convergence question. Single cicd → the
    workstation re-seeds cicd on cicd-only changes (a minimal, rare bootstrap
    step). A **cicd pair in R13's ping-pong relationship** → cicd converges cicd
    via its live peer, so the workstation is needed **only** for genuine
    cold-start (both down). **R14 and ping-pong compose:** R14 minimizes the
    pathway; ping-pong minimizes even the cicd-update floor.
  - **The seed step must be robust** — the workstation→cicd bootstrap is
    critical-path, but it is ONE small VM, the smallest possible surface.
- **Relationship:** R14 = *pathway-level* unification (who/where converges);
  R13 = *verb-level* unification (recreate vs in-place). Orthogonal axes, one
  aspiration; ping-pong lives at their intersection (cicd converging cicd). The
  near-term control-plane-convergence-safety fix (converge-vs-recreate guard) is
  a stepping stone toward both. The R13 research pass should treat R14's
  single-pathway target as its deployment context — an executor that converges
  everything, seeded minimally, *is* R14.
- **Sequencing:** aspiration — steer toward it; do not build directly. Fold into
  the R13 research question as its target architecture.

---

## R15 — Hardware-backed operator key; agent-resistant secret access (added 2026-07-19, post-review)

*Added after the RESEARCH-008 key-leak incident (#680: an agy sub-agent
read `operator.age.key` and embedded it in a scratch file — the key
transited a cloud model context; rotation via the #680 DRT). Not part of
the original adversarially-verified set — markers here are [V] for the
incident/topology facts, [I] for the migration claims.*

- **Problem:** `operator.age.key` is the root of trust for every site
  secret and is a plain file readable by any process or agent running as
  the operator [V]. It does the job an HSM/TPM does elsewhere, minus
  non-exfiltratability: a single read = permanent key compromise =
  full rotation (#680). The CI copy rides CIDATA into cicd
  (`modules/cicd/main.tf:72-75`) with the same all-secrets scope [V]
  (overlaps R9's runner-key concern).
- **Root cause:** the key predates any agent-in-the-loop threat model;
  bootstrap-vs-operational secret planes (R9) were never split, so one
  identity decrypts everything from everywhere.
- **Change (phased; each phase independently valuable):**
  - **Phase 0 (no hardware):** split operator vs CI age identities with
    per-file `.sops.yaml` scoping (CI identity decrypts only the
    deploy-time subset); move the operator key into the macOS Keychain
    behind `SOPS_AGE_KEY_CMD` so agent reads become authorization
    prompts instead of silent `cat`s. [I]
  - **Phase 1 (operator hardware):** operator identity onto a hardware
    token — `age-plugin-yubikey` (PIV, touch-policy decision) or
    `age-plugin-se` if the workstation's enclave is supported; introduce
    it via the #680 rotation DRT (introducing a new identity IS a
    rotation). Verify sops age-plugin support first (version-dependent). [I]
  - **Phase 2 (CI, evaluate-only):** vTPM-backed CI identity
    (`age-plugin-tpm`) vs accepting the Phase-0 scoped software identity
    minted per cicd recreation. A TPM identity is per-VM-incarnation and
    fights the cattle model (re-encrypt cycle per recreation); the
    evaluation may legitimately conclude Phase 0 is the stopping point. [I]
- **Anti-goal:** do NOT route SOPS decryption through Vault transit —
  Vault's own bootstrap depends on SOPS (unseal key), and the DR path
  must stay SOPS-sufficient with Vault down (same circularity guard as
  R9's residual classification).
- **Subtraction:** the "any agent can read the master key" property; the
  full-rotation-on-any-leak failure mode (hardware bounds exposure to
  actively-decrypted plaintexts).
- **Reliability (G1, G5):** secret blast radius bounded per-identity and
  per-incident; rotation becomes rare instead of incident-driven.
- **Risk:** sops/age-plugin ecosystem maturity (spike first); YubiKey
  touch friction against automation-heavy operator sessions (touch-policy
  `cached`); Phase-2 re-encrypt tax on cicd recreation.
- **Sequencing:** Phase 0 any time (pairs naturally with the #680 DRT);
  Phase 1 with/after #680 execution; Phase 2 evaluation after R9's
  bootstrap-vs-operational classification (shared taxonomy).

# Phase 5 — Leverage ranking

Impact ÷ effort, small-change/large-effect first. Effort: S (≤1 day),
M (≤1 week), L (multi-week/staged).

| # | Item | Effort | Why the effect outsizes the change |
|---|---|---|---|
| 1 | **R11 vault precious-wrap** | S | One wrapper swap closes the single largest latent data-loss footgun in the tofu layer. Minutes of change; category-of-incident prevention. |
| 2 | **R1 deletion sweep** | S | Pure subtraction. Every future reader (operator, agent, reviewer) stops paying the misdirection tax. The repo currently *lies* in ~10 places; after R1 it doesn't. |
| 3 | **R2a rules hoist** | S | ~900+ YAML lines deleted with provably zero behavior change (same rendered pipeline). Makes every later pipeline review tractable — a legibility multiplier for all subsequent items. |
| 4 | **R7(i) wildcard cert** (if the operator accepts the §8.2 reversal) | S–M | One issuance-model decision deletes three defensive subsystems and an entire incident class. Highest deletion-per-line-changed in the document. The trade-off is real but singular and documentable. |
| 5 | **R4 HA-out-of-tofu** | M | Deletes ~35 threaded sites + a provider surface with a known-unfixed upstream bug, and converts a subtle ordering contract into one explicit step. The reconciler already exists and is production-tested — the change is mostly deletion. |
| 6 | **R3 main.tf consolidation + per-env images** | M | ~600 lines + the #300 blocker + cross-env plan noise gone. Mechanical, with a designed migration path already written in-issue. |
| 7 | **R5(a–c) immutable CIDATA + zone-data decoupling** | M | Ends "editing a DNS record destroys a VM" — the most operator-visible gratuitous coupling — and starts the path that retires the #417 machinery. |
| 8 | **R2b job grouping** | M | Job count 155 → ~30; auditable CI. Costs per-test retry granularity. |
| 9 | **R8 DR ratchet** | S–M | Small addition; restores the honesty of the G3 frontier and gates the big subtractions safely. |
| 10 | **R12 + R10** (taxonomy/ledger; external-state register) | S–M | Cheap; converts unknowns and false status into enumerated facts. |
| 11 | **R9 SOPS shrink + runner-key evaluation** | M–L | Large long-term simplification of the secret plane; needs the bootstrap-ordering audit first. |
| 12 | **R6 in-place convergence** | L (staged) | The largest eventual subtraction in the system (the destruction-safety apparatus becomes DR-only, Sprint-042 machinery removable) — but only after gates #408/#339/#340 + ratchets land and the stateless cohort soaks. Near-term complexity *rises*; ranked last on effort despite highest ceiling. |
| 13 | **R5(e) nocloud-init bootstrap-only** | L | Follows R5(a–d); retires the every-boot CIDATA dependence and (with migration-orphan handling) the orphan machinery. |

**The through-line.** Items 1–7 are independently shippable subtractions
that require no architectural courage — each deletes real code or a real
footgun this month. Items 12–13 are the architectural repair of WT-1/WT-2;
they are sequenced last not because they matter least but because their
gates (open bugs #408/#339/#340, a current DR registry, CIDATA
immutability) must land first — and because the destruction-safety
machinery they would eventually retire is load-bearing today and must not
be weakened before its replacement has earned trust (G4's own standard).

## Deferred / explicitly not covered

- **Benchmarks, GitHub publishing, HIL** as subsystems: churn contributors
  (~20/~10/~15 issues) but designed, opt-in, and off the deploy hot path;
  no wrong-turn finding beyond WT-7 hygiene. Revisit only if their issue
  velocity stays disproportionate.
- **Sentinel/watchdog relocation (#246):** folded into R10 as a register
  decision, not analyzed to a recommendation here.
- **Two-tier deployment model:** examined; the workstation tier is the
  DR-shaped escape the pipeline cannot self-host. No subtraction found
  that doesn't violate G2's "every path equivalent" — revisit after R6.
- **Shell-substrate replacement (#367):** the fragility class is real
  (#125's 21 exit-0 instances, bash-3.2 hazards) but a rewrite fails the
  small-over-large principle; the roadmap shrinks the *demand* for
  orchestration instead (R4, R5, R6). Revisit if rebuild-cluster.sh is
  still >2,000 lines after R4–R6 land.
- **N-node scaling residues (filed 2026-07-05):** node count is a site
  variable by design and the framework is list-derived throughout, but
  three residues surfaced while correcting the system map's "3-node"
  phrasing: placement-by-index in root main.tf (#475, folded into R3);
  `discover_switched_links()` is an unimplemented stub, leaving 5+-node
  sites (bfnet = 6) with no viable replication-network path (#476); and
  even-node-count quorum (qdevice) is unaddressed (#477). #476/#477 are
  prerequisites for bfnet HIL commissioning, not wuertele work.
- **Open unknowns:** RESEARCH-002's UDM-Pro D-gate (unverified per-VLAN
  DHCP capability) still underpins the dev/prod isomorphism direction;
  the historical reason VLAN-based env detection was abandoned
  (RESEARCH-001 open sub-question 4) remains unrecovered.
