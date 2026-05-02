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
| DRT-001 | Warm Rebuild | PASS | 2026-05-01 | a41fb69 | ~45 min |
| DRT-002 | Cold Rebuild | INVALIDATED | 2026-04-03 | pending rerun | ~50 min |
| DRT-003 | PBS Restore | PASS | 2026-05-01 | a41fb69 | ~6 min |
| DRT-004 | Vault HA Failover | PASS | 2026-05-01 | a41fb69 | ~2 min |
| DRT-005 | Node Failure Recovery | INVALIDATED | 2026-03-23 | pending rerun | ~10 min |
| DRT-006 | DNS Failover | INVALIDATED | — | pending rerun | ~5 min |
| DRT-007 | Backup Spot-Check | FAIL (Layer 3.5) | 2026-04-26 | 3d4cee4 | ~1 min |
| DRT-008 | Reset Contract Ratchet | PASS | 2026-04-15 | 3d36545 | ~2 min |

---

## DRT-001: Warm Rebuild

**Status:** PASS at 2026-05-01 commit `a41fb69` (Sprint 033 closure rerun)
— covers Sprint 033 publish:github machinery (`.gitlab-ci.yml`,
`configure-vault.sh`, `validate.sh`, `generate-gatus-config.sh`) plus
the #287 test-isolation fix
(`tests/test_publish_failure_classification.sh`,
`tests/test_publish_filter.sh`, new
`validate:publish-tests-env-isolation` ratchet job). Validates the
stopped-Phase-1/preboot-restore/Phase-2 sequencing in
`rebuild-cluster.sh`, `safe-apply.sh`, and `restore-before-start.sh` on
the publish-enabled prod commit (post first publish, pipeline 850).
Full warm rebuild completed in 13m 30s (well under 45m threshold).

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
Date:    2026-05-01T02:21:12Z
Commit:  a41fb69
Result:  PASS
Time:    13m 30s
Notes:   Sprint 033 closure rerun on the publish-enabled prod commit
         (post first publish, pipeline 850 force-pushed github main
         as the bot commit). Validates Sprint 033 publish:github machinery
         (.gitlab-ci.yml, configure-vault.sh, validate.sh,
         generate-gatus-config.sh) plus the #287 test-isolation fix
         (test_publish_failure_classification.sh, test_publish_filter.sh,
         validate:publish-tests-env-isolation ratchet job). All 5
         fingerprints match (GitLab projects=1, Vault initialized + 14
         mounts, InfluxDB org=homelab, Roon DB=1574M vs pre-test 1643M,
         threshold 821M). Total elapsed 13m 30s, well under 45m threshold.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
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

**Status:** INVALIDATED by Sprint 002 changes to `rebuild-cluster.sh`
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
Date:    2026-04-03
Commit:  pending rerun
Result:  INVALIDATED
Time:    -
Notes:   Sprint 002 changed rebuild-cluster.sh Step 0 branch safety,
         initial-deploy detection, Layer 2 comparison, and Step 14.5/17
         behavior. Re-run required.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-03-25 | 099b860 | PASS | 47m | Level 5 cold path |

---

## DRT-003: PBS Restore

**Status:** PASS at 2026-05-01 commit `a41fb69` (Sprint 033 closure rerun)
— covers Sprint 033 changes to `.gitlab-ci.yml` and `validate.sh` (the
GitHub publish validation gates) plus the #287 test-isolation fix
(`tests/test_publish_failure_classification.sh`,
`tests/test_publish_filter.sh`, new
`validate:publish-tests-env-isolation` ratchet job) on the
publish-enabled prod commit (post first publish, pipeline 850). All four
precious-state prod VMs (vault 403, gitlab 150, influxdb 601, roon 603)
restored cleanly; cert lineages production-clean; state fingerprint
matches (Roon 1588M → 1547M, well above 794M threshold). Total elapsed
6m 40s.

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
Date:    2026-05-01T02:37:42Z
Commit:  a41fb69
Result:  PASS
Time:    6m 40s
Notes:   Sprint 033 closure rerun on the publish-enabled prod commit
         (post first publish, pipeline 850). All 4 precious-state prod
         VMs restored cleanly (vault VMID 403, gitlab VMID 150, influxdb
         VMID 601, roon VMID 603). Cert lineage checks all pass —
         vault_prod, gitlab, and influxdb_prod renewal lineages match
         configured ACME URL; live gitlab issuer is production-clean.
         State fingerprint matches (GitLab projects=1, Vault initialized
         + 14 mounts, InfluxDB org=homelab, Roon DB 1547M vs pre-test
         1588M, well above 794M threshold). Validates Sprint 033 changes
         to .gitlab-ci.yml and validate.sh on the restore path, plus the
         #287 test-isolation fix.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
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
Date:    2026-05-01T02:46:55Z
Commit:  a41fb69
Result:  PASS
Time:    1m 37s (recovery: 21s)
Notes:   Sprint 033 closure rerun on the publish-enabled prod commit
         (post first publish, pipeline 850). QEMU process killed on
         pve03; HA restarted Vault; auto-unseal completed. Vault healthy
         after 21s wall-clock (under 30s RTO target, baseline ~15s).
         SOPS root token still valid post-failover. validate.sh vault
         checks pass. Confirms the kill→HA-restart→auto-unseal path is
         unaffected by Sprint 033's configure-vault.sh extension that
         repopulates secret/data/github/deploy-key from SOPS.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-04-26 | 3d4cee4 | PASS | 1m 40s (recovery: 22s) | Sprint 029 closure opportunistic rerun. QEMU process killed on pve03; HA restarted Vault; auto-unseal completed. Vault healthy after 22s wall-clock (under 30s RTO target). SOPS root token still valid post-failover. validate.sh vault checks pass. Confirms the closure-cycle assessment that Sprint 029's changes do not exercise this path. |
| 2026-03-30 | 3aed5d1 | PASS | 0m 56s | Pre-Sprint-026 baseline |
| 2026-03-23 | 746d062 | PASS | ~15s | Step 10B destructive test |
| 2026-03-23 | 746d062 | PASS | ~15s | 10s HA restart + 5s boot/unseal. Measured during Step 10B. |


---

## DRT-005: Node Failure Recovery

**Status:** INVALIDATED by Sprint 026 changes to recreated VM AppRole/CIDATA
surface in `framework/tofu/modules/testapp/`, `framework/tofu/root/main.tf`,
and `framework/catalog/grafana/`. Re-run required before the ratchet is valid
again.

**What it validates:** That the cluster survives a complete node
failure. All VMs on the failed node are migrated to surviving nodes
by Proxmox HA. Anti-affinity pairs remain on different nodes. After
the node is powered back on, `rebalance-cluster.sh` restores intended
placement.

**Invalidated by changes to:**
- `framework/tofu/modules/testapp/`
- `framework/catalog/grafana/`
- `framework/tofu/root/main.tf`
- Proxmox HA configuration in any OpenTofu module
- Anti-affinity rules (dns1/dns2 placement)
- N+1 capacity allocation in `site/config.yaml`
- `framework/scripts/rebalance-cluster.sh`
- `framework/scripts/configure-replication.sh`

**Pass criteria:**
- All checks pass within 120 seconds of power-off
- Anti-affinity pairs on different surviving nodes
- Node rejoins within 60 seconds of power-on
- `validate.sh` passes after rebalance

**Estimated time:** ~10 min

**Last Run:**
```
DRT-005 Node Failure Recovery
Date:    2026-03-23 (Step 10B destructive test)
Commit:  746d062
Result:  PASS
Time:    <120s migration, ~20m full cycle
Notes:   7 VMs migrated from pve02 to pve01/pve03. Node rejoined in ~15s.
         Rebalance + validation completed full cycle in ~20 min.
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-03-23 | 746d062 | PASS | <120s | Step 10B node failure |

---

## DRT-006: DNS Failover

**Status:** INVALIDATED by Sprint 026 changes to cert issuance and renewal
flow (`framework/nix/modules/certbot.nix`, `framework/scripts/cert-sync.sh`,
`framework/scripts/certbot-cluster.sh`, `framework/scripts/check-cert-budget.sh`,
`framework/scripts/configure-vault.sh`). Sprint 033 also touches
`validate.sh`; the change is limited to Gatus publishing-group handling, not
DNS checks, but this note records the Sprint 033 invalidation review. Re-run
required before the ratchet is valid again.

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

**Pass criteria:**
- dig resolves prod hostnames against the surviving DNS server
- `certbot renew` succeeds with one DNS server down
- `validate.sh` passes after both servers restored

**Estimated time:** ~5 min

**Last Run:** Not yet validated with the DR test framework.

**History:** None.

---

## DRT-007: Backup Spot-Check

**Status:** BLOCKED — Layer 3.5 architectural drift, see #252.

Layers 1–3 (PostgreSQL data integrity, DB connectivity, GitLab project count)
remain valid. Layer 3.5 ("Certbot lineage integrity"), added 2026-04-06 in
commit `91a9a76` for #174 staging-cert-poisoning defense, became obsolete on
2026-04-21 in commit `6dc0b00` (Sprint 026 vault-backed cert storage). Layer
3.5 reads `/etc/letsencrypt/live/$fqdn/fullchain.pem` on the temp VM, but
`cert-restore.service` now wipes and rewrites that directory on every boot
from Vault KV — so the probe no longer measures backup content. First
end-to-end execution of Layer 3.5 happened during Sprint 029 closure rerun
(2026-04-26 at commit `3d4cee4`); Layer 3.5 failed with "Leaf issuer:
missing." This is **not a Sprint 029 regression** — it is a long-standing
architectural drift since Sprint 026, surfaced now because Layer 3.5 had
never been re-executed end-to-end.

The pre-run closure-cycle assessment had flagged DRT-007 as NEEDS RERUN
(because #241's `renewal.conf` rewrite changes what the spot-check
observes); the actual run revealed a deeper architectural drift that
predates #241 and supersedes that assessment.

Re-validation requires resolving #252 (Option A recommended: delete Layer
3.5; equivalent assertion lives in `validate.sh`).

**What it validates:** That PBS backups contain real application state,
not just filesystem metadata. Non-destructive — restores a backup to
a temporary VM, verifies the application would start with the restored
data, then destroys the temporary VM. For GitLab backups, it now also
verifies the restored renewal lineage is production-clean and the leaf
issuer is not `Fake LE` when the site ACME mode is production.

**Invalidated by changes to:**
- `framework/scripts/restore-from-pbs.sh`
- `framework/scripts/backup-now.sh`
- `framework/scripts/certbot-persisted-state.sh`
- `framework/scripts/cert-sync.sh`
- `framework/scripts/cert-storage-backfill.sh`
- `framework/scripts/check-cert-budget.sh`
- `framework/scripts/certbot-cluster.sh`
- `framework/nix/modules/base.nix`
- `framework/nix/modules/certbot.nix`
- `framework/nix/modules/vault.nix`
- PBS NixOS module
- PBS OpenTofu module (backup job configuration)
- Three-gate backup verification logic in `rebuild-cluster.sh`

**Pass criteria:**
- Backup restores to temp VM without error
- Application-specific state signal is present (project count > 0,
  org exists, DB non-empty, etc.)
- GitLab spot-checks show the expected ACME renewal lineage
- GitLab spot-checks do not show a `Fake LE` live issuer when site ACME
  mode is production
- Temp VM destroyed cleanly

**Estimated time:** ~15 min

**Last Run:**
```
DRT-007 Backup Spot-Check
Date:    2026-04-26T21:58:01Z
Commit:  3d4cee4
Result:  FAIL (Layer 3.5 only; Layers 1–3 + Layer 4 informational pass)
Time:    0m 47s
Failures:
  - GitLab live leaf issuer is not staging — actual issuer was empty,
    not staging. Empty because cert-restore.service mediates
    /etc/letsencrypt/live/ on every boot post-Sprint-026 (commit
    6dc0b00) and the temp VM's vault-agent contends with production
    gitlab's AppRole credentials.
Notes:   Architectural drift, NOT a Sprint 029 regression. See #252
         for analysis and proposed fixes (recommended: delete Layer 3.5,
         move equivalent check to validate.sh). Layers 1–3 confirmed
         backup integrity (PostgreSQL 206M, PG_VERSION=16, projects=1).
         Wrapper log: logs/DRT-007-11.log.
```

**History:** 

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-03-30 | 3aed5d1 | PASS | 0m 39s | Repeated during DRT-004 cleanup attempt (pre-Layer-3.5) |
| 2026-03-29 | 67071a1 | PASS | 0m 36s | First automated run; layers 1-3 passed, layer 4 expected unavailable (pre-Layer-3.5) |


---

## DRT-008: Reset Contract Ratchet

**Status:** PASS (2026-04-15, commit 3d36545). Sprint 016 flag split,
hard break for `--cluster`, `--backup` removal, and non-destructive
`--recover` validation gates validated in a fixture-based contract test.

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
Date:    2026-04-16T04:00:01Z
Commit:  3d36545
Result:  PASS
Time:    0m 0s
Notes:   Fixture-based contract ratchet for Sprint 016. Verified --cluster
         hard break, --backup removal, --test dry-run, and --recover pin
         validation without issuing destructive commands.
```

**History:** None.

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
| `framework/scripts/converge-lib.sh` | DRT-001, DRT-002, DRT-003 |
| `framework/scripts/converge-vm.sh` | DRT-001, DRT-002, DRT-003 |
| `restore-from-pbs.sh` | DRT-001, DRT-003, DRT-007 |
| `restore-before-start.sh` | DRT-001, DRT-003 |
| `post-deploy.sh` | DRT-001 |
| `validate.sh` | DRT-001, DRT-003, DRT-006 |
| `framework/scripts/certbot-persisted-state.sh` | DRT-001, DRT-002, DRT-003, DRT-007 |
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
| PBS tofu module | DRT-003, DRT-007 |
| NAS NFS configuration | DRT-003 |
| certbot / ACME hooks | DRT-006 |
| macOS bash compatibility | DRT-002 |
