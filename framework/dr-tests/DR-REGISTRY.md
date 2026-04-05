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
| DRT-001 | Warm Rebuild | INVALIDATED | 2026-04-03 | pending rerun | ~35 min |
| DRT-002 | Cold Rebuild | INVALIDATED | 2026-04-03 | pending rerun | ~50 min |
| DRT-003 | PBS Restore | PASS | 2026-03-25 | 099b860 | ~20 min |
| DRT-004 | Vault HA Failover | PASS | 2026-03-23 | 746d062 | ~5 min |
| DRT-005 | Node Failure Recovery | PASS | 2026-03-23 | 746d062 | ~10 min |
| DRT-006 | DNS Failover | — | — | — | ~5 min |
| DRT-007 | Backup Spot-Check | — | — | — | ~15 min |

---

## DRT-001: Warm Rebuild

**Status:** INVALIDATED by Sprint 002 changes to `rebuild-cluster.sh`
branch safety, initial-deploy detection, last-known-prod comparison,
and GitLab handoff behavior. Re-run required before the ratchet is valid
again.

**What it validates:** That `rebuild-cluster.sh` can fully restore a
running cluster from production config with a warm Nix cache. All VMs
are destroyed and recreated. Precious state is backed up before
destruction and restored from PBS after.

**Invalidated by changes to:**
- `framework/scripts/rebuild-cluster.sh`
- `framework/scripts/backup-now.sh`
- `framework/scripts/restore-from-pbs.sh`
- `framework/scripts/restore-after-deploy.sh`
- `framework/scripts/post-deploy.sh`
- `framework/scripts/validate.sh`
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
| 2026-03-23 | 746d062 | PASS | 29m 49s | Level 5 Test 2 |

---

## DRT-002: Cold Rebuild

**Status:** INVALIDATED by Sprint 002 changes to `rebuild-cluster.sh`
branch safety, initial-deploy detection, last-known-prod comparison,
and GitLab handoff behavior. Re-run required before the ratchet is valid
again.

**What it validates:** That a fresh operator can clone the repo and
build a complete cluster from scratch. Simulates the new-operator
experience with `new-site.sh` + `rebuild-cluster.sh` from a fresh
clone.

**Invalidated by changes to:**
- `framework/scripts/new-site.sh`
- `framework/scripts/rebuild-cluster.sh`
- `framework/scripts/build-all-images.sh`
- `framework/scripts/build-image.sh`
- `framework/templates/config.yaml.example`
- `flake.nix` (image derivations, nixSrc filter)
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

**What it validates:** That `restore-from-pbs.sh` can restore all
precious-state VMs from PBS backups. The restore path in
`restore-after-deploy.sh` is also exercised automatically by the
pipeline on every deploy that causes VM recreation — this provides
ongoing confidence between explicit DRT-003 runs.
`restore-after-deploy.sh` uses uptime-based detection (not filesystem
markers) to determine which VMs need restore.

**Invalidated by changes to:**
- `framework/scripts/restore-from-pbs.sh`
- `framework/scripts/restore-after-deploy.sh`
- `framework/scripts/backup-now.sh`
- `framework/tofu/modules/` PBS module
- PBS NixOS module
- NAS NFS datastore configuration

**Pass criteria:**
- `validate.sh` passes
- State fingerprint matches pre-test

**Estimated time:** ~20 min

**Last Run:**
```
DRT-003 PBS Restore
Date:    2026-03-30T03:44:12Z
Commit:  efba8e1
Result:  PASS
Time:    4m 2s
Notes:   First manual pass after 7, 4, 6
Notes:   
```

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-03-25 | 099b860 | PASS | ~20m | Post-rebuild restore |
| 2026-03-25 | 099b860 | PASS | ~20m | Restored vault and gitlab from PBS after warm rebuild. |

---

## DRT-004: Vault HA Failover

**What it validates:** That Vault automatically recovers from a VM
crash. The QEMU process is killed (simulating a crash), and Proxmox
HA restarts the VM. The auto-unseal service reads the unseal key from
vdb and unseals Vault without operator intervention.

**Invalidated by changes to:**
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
DRT-004 Vault HA Failover
Date:    2026-03-30T02:21:11Z
Commit:  3aed5d1
Result:  PASS
Time:    0m 56s

**History:**

| Date | Commit | Result | Time | Notes |
|------|--------|--------|------|-------|
| 2026-03-23 | 746d062 | PASS | ~15s | Step 10B destructive test |
| 2026-03-23 | 746d062 | PASS | ~15s | 10s HA restart + 5s boot/unseal. Measured during Step 10B. |


---

## DRT-005: Node Failure Recovery

**What it validates:** That the cluster survives a complete node
failure. All VMs on the failed node are migrated to surviving nodes
by Proxmox HA. Anti-affinity pairs remain on different nodes. After
the node is powered back on, `rebalance-cluster.sh` restores intended
placement.

**Invalidated by changes to:**
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

**What it validates:** That DNS resolution continues when one DNS
server is down. Tests both directions (dns1 down → dns2 serves, and
vice versa). Verifies certificate renewal works with one DNS server
down.

**Invalidated by changes to:**
- PowerDNS NixOS module
- DNS pair OpenTofu module (anti-affinity, placement)
- certbot DNS-01 challenge hooks
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

**What it validates:** That PBS backups contain real application state,
not just filesystem metadata. Non-destructive — restores a backup to
a temporary VM, verifies the application would start with the restored
data, then destroys the temporary VM.

**Invalidated by changes to:**
- `framework/scripts/restore-from-pbs.sh`
- PBS NixOS module
- PBS OpenTofu module (backup job configuration)
- Three-gate backup verification logic in `rebuild-cluster.sh`

**Pass criteria:**
- Backup restores to temp VM without error
- Application-specific state signal is present (project count > 0,
  org exists, DB non-empty, etc.)
- Temp VM destroyed cleanly

**Estimated time:** ~15 min

**Last Run:**

DRT-007 Backup Spot-Check
Date:    2026-03-30T02:19:52Z
Commit:  3aed5d1
Result:  PASS
Time:    0m 39s
Notes:   [repeating in an attempt to get a clean run of DRT-004]

**History:** 

DRT-007 Backup Spot-Check
Date:    2026-03-29T18:58:57Z
Commit:  67071a1
Result:  PASS
Time:    0m 36s
Notes:   First automated run; four-layer verification; layers 1-3 pass,
         layer 4 expected unavailable on temp VM.


---

## Invalidation Quick Reference

Scan this table after any change session. Run all tests whose trigger
matches your change.

| Changed area | Tests to re-run |
|-------------|-----------------|
| `rebuild-cluster.sh` | DRT-001, DRT-002 |
| `new-site.sh` | DRT-002 |
| `backup-now.sh` | DRT-001, DRT-003 |
| `restore-from-pbs.sh` | DRT-001, DRT-003, DRT-007 |
| `restore-after-deploy.sh` | DRT-001, DRT-003 |
| `post-deploy.sh` | DRT-001 |
| `validate.sh` | DRT-001, DRT-006 |
| `init-vault.sh` | DRT-001, DRT-004 |
| `configure-vault.sh` | DRT-001, DRT-004 |
| `build-image.sh` / `build-all-images.sh` | DRT-002 |
| `bootstrap-sops.sh` | DRT-002 |
| `flake.nix` (image derivations) | DRT-002 |
| `framework/templates/config.yaml.example` | DRT-002 |
| `framework/tofu/root/` (any .tf) | DRT-001 |
| `framework/tofu/modules/` (any module) | DRT-001, DRT-004, DRT-005, DRT-007 |
| `framework/nix/modules/` (any module) | DRT-001, DRT-002 |
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
