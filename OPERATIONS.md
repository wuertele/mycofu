# Mycofu Operations Guide

This document covers day-to-day operation and maintenance of a running Mycofu
cluster. It assumes the cluster has been built and validated per
[GETTING-STARTED.md](GETTING-STARTED.md).

For architecture decisions and design rationale, see
[architecture.md](architecture.md). For project overview, see
[README.md](README.md).

---

## Quick Reference

Most operational tasks are handled automatically by the GitLab pipeline
(`post-deploy.sh` runs replication cleanup, vault recovery, and backup
configuration after every deploy; `validate.sh` runs in the pipeline's
validation stage; the placement watchdog on the NAS handles rebalancing).
The commands below are for manual/workstation use — when you're debugging,
deploying Tier 2 VMs, or recovering from a failure outside the pipeline.

```bash
# Deploy a change (normal workflow — the pipeline handles the rest)
git push gitlab dev                          # triggers dev pipeline

# Promote dev to prod
# Create MR from dev → prod in GitLab UI, merge it

# Validate the cluster (run by pipeline automatically; manual for spot-checks)
framework/scripts/validate.sh

# Rebalance VMs after HA failover (run by NAS watchdog automatically;
# manual only if watchdog is down or you want to force it)
framework/scripts/rebalance-cluster.sh

# Clean up replication after VM recreation (run by post-deploy.sh in
# pipeline; manual only for Tier 2 workstation deploys)
framework/scripts/configure-replication.sh "*"

# Rebuild the entire cluster from bare Proxmox
# (must be on prod branch for routine use; see Full Disaster Recovery for override)
git checkout prod
framework/scripts/rebuild-cluster.sh

# Rebuild control-plane VMs only (gitlab, cicd, pbs) — must be on prod branch
git checkout prod
framework/scripts/rebuild-cluster.sh --scope control-plane

# Disaster recovery rebuild (override branch safety when GitLab is down)
framework/scripts/rebuild-cluster.sh --override-branch-check

# Reset cluster to factory state (destructive!)
framework/scripts/reset-cluster.sh --confirm

# Decrypt secrets for inspection
sops -d site/sops/secrets.yaml
```

---

## Adding a New VM

Application VMs are specified in `site/applications.yaml`. Framework VMs
(DNS, Vault, PBS, GitLab, etc.) are in `site/config.yaml` and are not
operator-managed in normal use.

You can add an application VM in two ways — both are fully supported and
produce identical results. The framework reads `applications.yaml` directly;
it does not require that entries were produced by a generator.

**Application secrets are auto-generated.** If your application needs a
SOPS secret (like an admin API token), the deploy pipeline generates it
automatically on first deploy. You do not need to run `bootstrap-sops.sh`
or manually add tokens to SOPS. The framework checks `applications.yaml` for
enabled applications, generates any missing SOPS keys, and proceeds.
See architecture.md section 9.2 for the on-demand secret lifecycle.

### Using enable-app.sh (Catalog Applications)

If the application exists in `framework/catalog/`, `enable-app.sh` saves
you from knowing every field. It allocates VMIDs, IPs, and MACs; writes a
complete entry to `site/applications.yaml` with inline documentation; and
generates the NixOS host config and app config stubs.

```bash
framework/scripts/enable-app.sh grafana
```

After it runs:

1. **Review `site/applications.yaml`** — the generated entry has all
   derivable values filled in with inline comments explaining each one.
   Override anything that needs changing by editing directly.
2. **Edit `site/apps/grafana/`** — replace any `CHANGEME` values in the
   app config files.
3. **Add secrets to SOPS** — follow the prompts in the script summary.
4. **Add flake output** to `flake.nix`.
5. **Deploy** via the pipeline.

The script is idempotent — running it twice for the same app is safe.
It never modifies an existing entry.

Available catalog applications:

```bash
ls framework/catalog/
```

### Writing applications.yaml Directly

For applications not in the catalog, or if you prefer to write entries
by hand, add a block to `site/applications.yaml` directly. The format
is the same regardless of how the entry was created. Then continue from
step 2 above.

```yaml
# site/applications.yaml
applications:
  myapp:
    node: node1
    ram: 2048
    cores: 2
    disk_size: 4
    data_disk_size: 10
    backup: true        # set true if this app has precious state on vdb
    monitor: false      # set true once you add health.yaml to your catalog entry

    environments:
      prod:
        # IP must be within prod app range — check site/config.yaml for subnet
        # Verify no duplicate: grep 'ip:' site/config.yaml site/applications.yaml
        ip: 10.0.10.70
        # VMID scheme: 6xx = prod apps — check site/config.yaml for scheme
        # Verify no duplicate: grep 'vmid:' site/config.yaml site/applications.yaml
        vmid: 601
        # MAC is stable across rebuilds — preserves layer 2 identity
        mac: "02:aa:bb:cc:dd:ee"
      dev:
        ip: 10.0.20.70
        vmid: 501
        mac: "02:aa:bb:cc:dd:ff"
```

To generate locally-administered MACs manually:

```bash
printf '02:%02x:%02x:%02x:%02x:%02x\n' \
  $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
```

### NixOS VM — Additional Steps

**1. Create the NixOS host configuration** at `site/nix/hosts/myapp.nix`:

```nix
{ config, pkgs, lib, ... }:
{
  imports = [
    ../../../framework/nix/modules/base.nix
    ../../../framework/nix/modules/myapp.nix
  ];
  # Site-specific overrides here
}
```

**2. Add to the flake outputs** in `flake.nix`:

```nix
myapp-image = mkImage {
  hostConfig = "${nixSrc}/site/nix/hosts/myapp.nix";
};
```

**3. Update the nixSrc filter** in `flake.nix` if you added new files that
the build references — otherwise the build fails with a file-not-found error
(by design).

**4. Add to the site image manifest** (`site/images.yaml`):

```yaml
roles:
  myapp:
    category: nix
    host_config: site/nix/hosts/myapp.nix
    flake_output: myapp-image
```

**5. Add the OpenTofu module** in `site/tofu/main.tf`:

```hcl
module "myapp_prod" {
  source = "../../framework/tofu/modules/proxmox-vm"
  # parameters from applications.yaml
}
module "myapp_dev" {
  source = "../../framework/tofu/modules/proxmox-vm"
}
```

**6. Deploy:**

```bash
git add -A && git commit -m "add myapp VM"
git push gitlab dev
# Pipeline builds image, deploys to dev. Verify, then promote to prod via MR.
```

### Non-NixOS VM (Custom Image)

For VMs that need a non-NixOS base (Debian, Ubuntu, vendor kernel).

Add an entry to `site/applications.yaml` as above, then:

1. Create a build script at `site/images/myapp/build.sh` that produces an
   `.img` file (idempotent).
2. Add to `site/images.yaml`:
   ```yaml
   roles:
     myapp:
       category: external
       build_script: site/images/myapp/build.sh
   ```
3. Add the OpenTofu module and deploy via pipeline.

### Vendor Appliance (Manual Image)

For vendor-provided appliances (PBS, HAOS) that ship as ISOs or pre-built
images.

Add an entry to `site/applications.yaml`. Add the OpenTofu module in
`site/tofu/main.tf` using the vendor image directly. Install manually via
Proxmox UI or disk import. Category C VMs are Tier 2 (workstation-managed):

```bash
cd site/tofu
../../framework/scripts/tofu-wrapper.sh apply -target=module.myapp_prod
```

### DNS Records

Adding a VM to `site/applications.yaml` (with an IP) automatically generates
a DNS A record. OpenTofu includes the record in the DNS VM's CIDATA. On the
next deploy, the DNS VM loads the updated zone at boot. No manual DNS step
is needed.

For non-VM DNS records (MX, TXT, CNAME), add them to
`site/dns/zones/<env>.yaml` and deploy.

### Deciding on vdb (Data Disk)

- **Stateless VMs** (web servers, proxies): omit `data_disk_size` or set to 0.
  The VM is fully disposable — `tofu apply` recreates it from the image.
- **VMs with precious state** (databases, Home Assistant): set `data_disk_size`
  and `backup: true`. The data lives on vdb, which persists across VM
  recreation and is backed up by PBS.
- **VMs with configuration state** (category 2 data pushed from Git): vdb is
  optional. If config can be re-pushed on every deploy, no vdb needed.

---

## Day-to-Day Workflow

### Making Changes

Most changes follow the dev-first pipeline workflow:

1. Edit code or config on a feature branch (or directly on `dev`)
2. Commit and push to GitLab
3. Pipeline builds images, deploys to dev, runs validation
4. Verify in dev
5. Create MR from `dev` → `prod`, merge
6. Pipeline deploys to prod

The pipeline handles: image builds, image upload, `tofu apply`, replication
cleanup, vault recovery, and validation. You don't run these manually for
data-plane VMs.

### Updating Control-Plane VMs (Tier 2)

GitLab, the CI/CD runner, and PBS are Tier 2 — the pipeline can't redeploy
the infrastructure it runs on. When a commit changes a control-plane VM
image (new NixOS module, base.nix change, etc.), the pipeline correctly
blocks deployment with a BLOCKED message from `safe-apply.sh`.

Deploy from the workstation — **you must be on the `prod` branch:**

```bash
git checkout prod
framework/scripts/rebuild-cluster.sh --scope control-plane
```

`rebuild-cluster.sh` enforces branch safety: it refuses prod-affecting or
control-plane scope from a non-prod branch, exiting before any build or
apply. If you're on `dev`, the script will tell you to switch to `prod`.
Use `--override-branch-check` only for genuine disaster recovery (see
Full Disaster Recovery below).

`rebuild-cluster.sh` is idempotent — it skips completed steps (networking,
storage, cluster are already done) and deploys the changed VMs. If a
control-plane VM is recreated, `rebuild-cluster.sh` automatically:
- Restores vdb from PBS (GitLab gets its database back, not a fresh
  empty instance)
- Cleans stale SSH host keys
- Re-registers the CI runner (if GitLab was recreated)
- Configures replication
- Runs the three-gate backup validation

You do not need to run individual scripts (build-image, upload-image,
tofu apply) manually — `rebuild-cluster.sh` handles the entire sequence.

Update GitLab before the runner — runner registration is stored in GitLab's
database.

### After Any VM Recreation

When `tofu apply` recreates a VM (new image hash, CIDATA change, etc.),
`rebuild-cluster.sh` handles post-recreation steps automatically:

1. SSH host key cleanup
2. PBS vdb restore (for VMs with `backup: true` and existing PBS backups)
3. Replication cleanup (`configure-replication.sh`)
4. Vault init/unseal (if Vault was recreated, with auto-recovery from
   token mismatch)
5. GitLab configuration and runner registration (if GitLab was recreated)
6. Three-gate backup validation

For manual workstation deploys outside `rebuild-cluster.sh` (not
recommended), the individual steps are:

1. `ssh-keygen -R <vm-ip>` — clear stale SSH host key
2. Replication cleanup: `configure-replication.sh "*"`
3. If Vault was recreated: `init-vault.sh` + `configure-vault.sh`
4. If GitLab was recreated: `configure-gitlab.sh` + `register-runner.sh`
5. Run `validate.sh` to confirm everything is healthy

---

## Troubleshooting

### Pipeline is Red

The pipeline was green before your change. If it's red now, your change broke
it.

- **Build failure:** Check the nix build log. Common causes: missing file in
  the nixSrc filter (add it to `flake.nix`), syntax error in a .nix file,
  missing dependency.
- **Deploy failure:** Check `tofu apply` output. Common causes: stale state
  (VM exists but tofu doesn't know about it), resource conflict, provider error.
- **Validation failure:** Check which `validate.sh` check failed. Fix the
  underlying issue, don't skip the check.
- **Control-plane drift:** See the dedicated section below.

### Control-Plane Drift

**What it is**

Control-plane VMs — gitlab, cicd, and pbs — are not deployed by the
automated pipeline. They run shared infrastructure that both environments
depend on, and the pipeline runs on them (GitLab hosts the pipeline; the
cicd runner executes it). They can only be deployed from the operator's
workstation.

Control-plane drift means the running VMs no longer match what the current
git commit specifies — either the OS image hash has changed (a NixOS module
update), or the CIDATA content has changed (a new secret, config value, or
credentials added via `write_files`). Any change to CIDATA triggers VM
recreation, which destroys and recreates the VM including its data disk (vdb).

**When you'll see it**

The post-merge dev pipeline fails at the test/validate stage with a message
identifying which control-plane VMs have drift and what kind (image, CIDATA,
or both). The prod pipeline also fails at validation, blocking promotion until
drift is resolved.

**Why you must follow the sequence carefully**

The remediation sequence is: backup → rebuild → verify. Each step matters:

- **Backup first, always.** `rebuild-cluster.sh --scope control-plane`
  destroys and recreates gitlab, which loses vdb. The only recovery path
  is the PBS backup taken before the destroy. If you skip the backup and
  the rebuild fails partway through, there is no recovery.

- **Verify the backup before destroying anything.** After running
  `backup-now.sh`, confirm it exited 0 and check that the PBS timestamp
  is recent. A backup job that ran on a VM with empty state creates a
  useless backup. The backup must contain real data.

- **Verify the restore before declaring success.** After the rebuild
  completes, confirm GitLab has your expected data — check that your
  git repositories exist, that your issue count is plausible, that
  pipelines can run. Do not re-trigger the pipeline until you have
  verified the restore.

**Remediation sequence**

```bash
# Step 1: Switch to the prod branch (rebuild-cluster.sh enforces this)
git checkout prod

# Step 2: Take and verify a backup
framework/scripts/backup-now.sh
# Must exit 0. If it fails, stop — check PBS before proceeding.

# Step 2: Verify the backup contains real data (not empty state)
# Check the PBS timestamp — it should be from just now
# Check backup size — it should be similar to previous backups for this VM
# If in doubt, run DRT-007 (backup spot-check) before destroying anything

# Step 3: Rebuild control-plane VMs from workstation
framework/scripts/rebuild-cluster.sh --scope control-plane
# This will: stop the VMs, destroy them, recreate with current images,
# restore vdb from PBS, reconnect the runner if cicd was rebuilt.
# Estimated time: 15-25 minutes.

# Step 4: Verify the restore
GITLAB_IP=$(yq '.vms.gitlab.ip' site/config.yaml)
ssh root@${GITLAB_IP} \
  "su -s /bin/sh postgres -c \"psql -d gitlab -tAc 'SELECT COUNT(*) FROM projects;'\""
# Must return a non-zero count matching your expected number of projects.

# Step 5: Run validate.sh to confirm full cluster health
framework/scripts/validate.sh
# Must pass all checks before re-triggering the pipeline.

# Step 6: Re-trigger the failed pipeline in GitLab UI
# Or push an empty commit to re-run:
git commit --allow-empty -m "ci: re-trigger after control-plane rebuild"
git push gitlab dev
```

**If cicd was rebuilt**

The CI/CD runner must be re-registered after cicd recreation:

```bash
framework/scripts/register-runner.sh
```

The `rebuild-cluster.sh --scope control-plane` script should do this
automatically, but verify the runner is online in GitLab before
re-triggering the pipeline (Settings → CI/CD → Runners).

**If the rebuild fails partway through**

Stop. Do not run more commands. Identify the last known-good PBS backup
timestamps for each precious-state VM:

```bash
# List available backups per VM
FIRST_NODE=$(yq '.nodes[0].mgmt_ip' site/config.yaml)
ssh root@${FIRST_NODE} \
  "pvesh get /nodes/pve01/storage/pbs-nas/content --output-format json" \
  | jq -r '.[] | "\(.vmid) \(.ctime | strftime("%Y-%m-%dT%H:%M:%SZ")) \(.size)"' \
  | sort
```

Do not run `backup-now.sh` or let scheduled PBS jobs run until the VMs
have verified real state. A backup of empty state overwrites the recoverable
backup.

See the Break-Glass Procedures section for full recovery from a failed
rebuild.

**Nuances an experienced operator knows**

The following are not obvious and have caused incidents in this system:

- The latest PBS backup may not be the best backup to restore from. If a
  previous rebuild failed and created backup jobs before the restore was
  verified, the latest backup may contain empty state. Always check the
  backup timestamp and size before restoring.

- CIDATA drift does not change the NixOS image hash. The pre-deploy image
  drift warning checks image hashes only — it will not warn about CIDATA
  changes. CIDATA drift is caught by the post-deploy validation (R7.2).
  If the pipeline fails after deploy with a CIDATA drift message but no
  image drift warning appeared, this is expected behavior, not a bug.

- PBS is not a NixOS VM and does not have a NixOS image. PBS config
  changes are deployed in-place with a targeted tofu apply, not via
  `rebuild-cluster.sh`. If the drift message identifies PBS only, the
  remediation is different:
  ```bash
  framework/scripts/tofu-wrapper.sh apply -target=module.pbs
  ```
  This does not destroy PBS or require a backup.

- vault-dev is not in the control-plane group and is deployed by the
  pipeline. If vault-dev drifts, the pipeline handles it automatically.

- **Never run `tofu apply` from the workstation without first verifying
  that `site/tofu/image-versions.auto.tfvars` contains real image hashes.**
  When this file is missing, `tofu-wrapper.sh` generates a placeholder with
  empty image paths (`local:iso/` with no filename). Running tofu apply with
  a placeholder destroys every VM whose image path changed — all of them —
  then fails to create them because the image file doesn't exist. If the file
  is missing or was deleted, download it from the last pipeline's build
  artifacts (GitLab CI → build:images → Artifacts) before running any
  workstation tofu apply. Deleting the file to "clear" it is never the right
  approach — it is a transient build artifact that only exists during an active
  build+deploy session.

- **`site/config.yaml` is part of the branch.** All CIDATA content — VM IPs,
  MACs, VMIDs, DNS zone content, ACME server URL, Vault endpoints — is derived
  from config.yaml via OpenTofu. If dev and prod branches have diverged on
  config.yaml, deploying prod VMs from the dev branch produces VMs with
  incorrect CIDATA. `rebuild-cluster.sh` warns about config.yaml divergence
  between your current commit and `gitlab/prod` when `--override-branch-check`
  is used.

### Vault is Sealed

Vault auto-unseals on restart using the key on vdb at
`/var/lib/vault/unseal-key`. If auto-unseal fails:

```bash
# Check if the key exists on vdb
ssh root@<vault-ip> "cat /var/lib/vault/unseal-key"

# If the key is there, unseal manually
ssh root@<vault-ip> "curl -sk -X PUT https://127.0.0.1:8200/v1/sys/unseal \
  -d '{\"key\": \"<unseal-key>\"}'"

# If the key is missing (vdb was lost), restore from SOPS backup
UNSEAL_KEY=$(sops -d site/sops/secrets.yaml | yq '.vault_<env>_unseal_key')
# Then deliver via SSH and unseal
```

### Replication Jobs Failed

After any `tofu apply` that recreates VMs, old replication jobs break because
the source zvols changed.

```bash
# Check status
ssh root@<node> "pvesr status"

# Fix (cleans orphans, recreates jobs, waits for sync)
framework/scripts/configure-replication.sh "*"
```

Do NOT manually delete zvols or replication jobs. Use the script.

### Certificate Issuance Failed

```bash
# Check certbot logs on the affected VM
ssh root@<vm-ip> "journalctl -u certbot-renew --since '1 hour ago'"
```

Common causes:
- **DNS not resolving:** The ACME challenge TXT record wasn't created. Check
  PowerDNS API connectivity from the VM.
- **Rate limited (Let's Encrypt):** 50 certs per domain per week. Wait for the
  window to reset. Don't rapid-fire `certbot` while debugging.
- **Pebble unreachable (dev):** Check if the pebble VM is running. Pebble is
  stateless — rebuilding it is safe.
- **Pebble negative cache (dev):** If Pebble queries the recursor (port 53)
  instead of the authoritative (port 8053), it caches NXDOMAIN for 5 minutes.
  This is a configuration bug — Pebble should query port 8053 directly.

### VM Won't Start After HA Migration

If Proxmox HA migrates a VM and it won't start on the new node:

```bash
# Check if CIDATA snippets exist on the target node
ssh root@<target-node> "ls /var/lib/vz/snippets/ | grep <vm-name>"
```

CIDATA snippets must be on ALL nodes (the proxmox-vm module deploys them
everywhere). If they're missing, run `tofu apply` to redeploy them.

### Node Rejoined but VMs Are on Wrong Nodes

After a node failure and recovery, VMs are displaced from their intended
placement.

```bash
# Check current vs intended placement
framework/scripts/rebalance-cluster.sh --dry-run

# Rebalance (migrates VMs back to intended nodes)
framework/scripts/rebalance-cluster.sh
```

The placement watchdog on the NAS does this automatically when all nodes are
healthy. Manual intervention is only needed to power on the failed node.

### DNS Resolution Broken

If VMs can't resolve hostnames:

```bash
# Check if DNS servers are running
dig @<dns1-ip> vault.<env>.<domain>
dig @<dns2-ip> vault.<env>.<domain>

# Check if the zone is loaded
ssh root@<dns-vm-ip> "pdnsutil list-all-zones"
ssh root@<dns-vm-ip> "pdnsutil list-zone <env>.<domain>"
```

DNS zone data is loaded from CIDATA at boot. If a record is missing, check
config.yaml and redeploy the DNS VM (zone data is regenerated from config.yaml
on every deploy).

### Tailscale Identity Lost or Mismatched

If a Tailscale-enabled VM fails to rejoin the tailnet with its expected
identity (appears as a new machine in Tailscale admin, or `tailscale status`
shows a different node ID than before), the node identity in Vault may be
stale, corrupt, or missing.

**Check the current state:**
```bash
# On the affected VM
tailscale status --json | jq '{BackendState, Self: .Self.ID}'

# In Vault
vault kv get secret/tailscale/nodes/<domain>/<vmrole>
```

**Recovery: clear the Vault identity and let the VM re-join fresh**

```bash
# Delete the stale identity from Vault
vault kv delete secret/tailscale/nodes/<domain>/<vmrole>

# Restart tailscale services on the VM to trigger a fresh join
ssh root@<vm-mgmt-ip> "systemctl restart tailscale-identity-restore tailscale tailscale-vault-sync"
```

After a fresh join:
- The VM appears in Tailscale admin as a new machine with the same name
  (`<vmrole>-<domain-with-dashes>`) — the old entry can be removed from
  the Tailscale admin console
- The new identity is written back to Vault automatically
- Any per-machine ACL rules in Tailscale admin must be re-applied if you
  use per-machine rules (prefer tag-based rules which survive identity
  changes automatically)

**If the auth key is rejected (403 from Tailscale):**

The reusable auth key in Vault may have been revoked or expired.
Generate a new key in the Tailscale admin console and update Vault:

```bash
vault kv put secret/tailscale auth_key="tskey-auth-XXXXXX"
```

VMs will pick up the new key on next vault-agent refresh cycle (within
24 hours, or immediately after a service restart).

---

## Maintenance

### Secret Rotation

**Bootstrap secrets (SOPS):** Long-lived by design. Rotate when a compromise
is suspected or on a planned schedule (annually is reasonable).

| Secret | Rotation procedure |
|--------|-------------------|
| PowerDNS API key | Generate new key, update SOPS, rebuild all VM images, verify cert issuance |
| Proxmox API password | Change on all nodes, update SOPS |
| SSH keys | Generate new keypair, update SOPS, rebuild VM images |

See architecture.md section 9.2 for the full rotation procedures.

**Runtime secrets (Vault):** Managed by Vault's own rotation mechanisms. Not
covered here.

### Proxmox Upgrades

Proxmox nodes are not managed by the framework (declared non-goal). Upgrade
via the standard Proxmox procedure:

1. Upgrade one node at a time
2. Evacuate VMs from the node first (`qm migrate`)
3. Run `apt update && apt full-upgrade`
4. Reboot
5. Verify the node rejoins the cluster
6. Rebalance VMs back
7. Repeat for the next node

### NixOS / Nix Flake Updates

To update the Nix package set (nixpkgs):

```bash
nix flake update
git add flake.lock
git commit -m "update nixpkgs"
git push gitlab dev
# Pipeline rebuilds all images with updated packages
# Verify in dev, then promote to prod
```

This rebuilds every NixOS image because the nix inputs changed. The pipeline
handles the full deploy.

### PBS Backup Verification

**Automated (every rebuild):** `rebuild-cluster.sh` verifies backup safety
through a three-gate model:

1. **Pre-backup validation (step 16a):** Checks that VMs with precious state
   have real application data. If PBS has existing backups for a VMID but the
   VM appears fresh (empty GitLab, uninitialized Vault), the rebuild stops —
   preventing overwrite of good backups with empty state.
2. **Backup execution (step 18):** Hard failure if any vzdump fails, with
   actual error output displayed.
3. **Post-backup validation (step 16b):** Verifies backups on PBS contain
   real application state, not just filesystem metadata.

A successful `rebuild-cluster.sh` implies working, verified backups.
See architecture.md section 14.2 for the full three-gate model.

**Continuous (daily):** PBS runs scheduled backup jobs automatically.
These daily backups do NOT have the pre-backup validation gate — if
application state is corrupted between rebuilds, the daily backup may
capture corrupted state. PBS retention policies (keeping multiple daily
snapshots) mitigate this: you can restore from any retained snapshot,
not just the most recent. Monitor daily backup completion via the PBS
web UI or the Gatus dashboard.

**Monthly (manual spot-check):** Restore a precious-state VM's vdb to a
temporary VM and verify the application starts with the restored data.
This tests what the automated checks cannot — actual application recovery
from a PBS backup.

```bash
# List available backups
ssh root@<pbs-ip> "proxmox-backup-client list --repository <datastore>"

# Restore a vdb to a temporary location and verify
# (see architecture.md section 16.5 for the procedure)
```

**What to watch for:**
- Daily backup jobs completing (check PBS web UI or Gatus)
- Backup sizes not dropping unexpectedly (could indicate empty state was
  backed up — see the data protection principle below)
- PBS datastore disk usage trending (retention policy keeping expected
  number of snapshots)

**Data protection principle:** A backup is only as valuable as what it
contains. The most dangerous failure is not a failed backup (which is
visible) — it's a successful backup of empty state that replaces a good
backup. `rebuild-cluster.sh` guards against this with the pre-backup
validation gate. Daily backups rely on PBS retention policies for
protection against this scenario (see the Continuous section above).

### Operational Cadence

| Frequency | Task |
|-----------|------|
| Continuous | Pipeline deploys changes, Gatus monitors health |
| Daily | certbot renews certificates (automatic), PBS runs backups (automatic, no pre-backup validation) |
| Every rebuild | Three-gate backup verification: pre-backup health + data protection, backup execution, post-backup content verification (automatic) |
| Weekly | ZFS scrub (automatic), review Gatus dashboard |
| Monthly | Backup restore spot-check (restore one VM's vdb to a temp VM, verify application starts) |
| Quarterly | Prod verification drills (DNS failover, Vault restart, node evacuation) |
| Annually | Bootstrap secret rotation (or on suspected compromise) |

### ACME Staging for DR Tests

**During DR tests that involve full cluster rebuilds (DRT-001, DRT-008):**
Set `acme: staging` in `site/config.yaml` before running
`rebuild-cluster.sh`. The Let's Encrypt production server rate-limits
duplicate certificate issuance to 5 per 168 hours — a troubled rebuild
session that issues multiple certs for the same domain can exhaust this
limit and leave the cluster without valid TLS for up to 7 days.
The staging server has no rate limit and its certs work for all cluster
purposes (ACME challenge validation, Vault TLS auth, nginx) except
browser trust. Set `acme: production` when promoting to prod.

---

## Break-Glass Procedures

When normal access paths (DNS, VMs) are down, fall back to direct IP access.

### Direct Access Reference

Keep this on your workstation (e.g., in `/etc/hosts` or a printed runbook):

```
# Proxmox UI (direct IP, no DNS needed)
https://<node1-ip>:8006     # pve01
https://<node2-ip>:8006     # pve02
https://<node3-ip>:8006     # pve03

# SSH to nodes (direct IP)
ssh root@<node1-ip>         # pve01
ssh root@<node2-ip>         # pve02
ssh root@<node3-ip>         # pve03
```

VM IPs are in `site/config.yaml → vms.*` (framework VMs) and
`site/applications.yaml → applications.*` (application VMs).

### When DNS Is Down

Add entries to your workstation's `/etc/hosts`:

```bash
# Framework VMs
yq '.vms | to_entries | .[] | .value.ip + " " + .key' site/config.yaml
# Application VMs
yq '.applications | to_entries | .[] | .value.environments.prod.ip + " " + .key' site/applications.yaml
```

### Full Disaster Recovery

See architecture.md section 13.4 for details. See architecture.md section
13.5 for the multi-level reset model.

**Routine control-plane maintenance (GitLab is up, planned operation):**

```bash
git checkout prod
framework/scripts/backup-now.sh
framework/scripts/rebuild-cluster.sh --scope control-plane
```

**Initial cluster deployment (no existing cluster):**

```bash
# Any branch — branch check is automatically skipped when no deployment exists
framework/scripts/rebuild-cluster.sh
```

The script detects "no existing deployment" (empty tofu state and no
configured VMs in Proxmox) and skips the branch check with an informational
message. No `--override-branch-check` is needed for a first-time deploy.

**Disaster recovery (cluster down, GitLab may be unreachable):**

First choice — use the prod commit if you have it locally:
```bash
git checkout gitlab/prod   # or: git checkout prod if local is current
framework/scripts/rebuild-cluster.sh
```

Second choice — if you don't know which commit was prod or GitLab is down:
```bash
framework/scripts/rebuild-cluster.sh --override-branch-check
```

With `--override-branch-check`, the script prints your current commit and the
last known prod commit (from `gitlab/prod` ref, if available), warns if
`site/config.yaml` differs between the two commits (different CIDATA for prod
VMs), skips the GitLab push and pipeline wait, and prints post-DR
reconciliation instructions at the end.

**If secrets survive (Levels 0–2):**

1. Reinstall Proxmox on all nodes (set management IPs from config.yaml)
2. Ensure `operator.age.key` is on the workstation
3. Run `framework/scripts/rebuild-cluster.sh`

PBS restores precious state automatically from backups on the NAS (if NAS
survived). `rebuild-cluster.sh` detects and handles incompatibilities:
- Stale TLS certificates (wrong domain) are cleaned and re-acquired
- Vault token mismatches are auto-recovered (Raft data wiped, reinitialized)
- The pre-backup validation gate prevents overwriting good backups with
  empty state if any restore fails

**If secrets are lost (Levels 4–5):**

1. Recover `operator.age.key` from backup (or generate fresh via
   `bootstrap-sops.sh`)
2. Recover `secrets.yaml` from git history (or generate fresh)
3. Reinstall Proxmox on all nodes
4. Run `framework/scripts/rebuild-cluster.sh`

On Level 5 (fresh secrets), PBS backups from the previous deployment
contain state encrypted with/keyed to the old secrets. `rebuild-cluster.sh`
handles this gracefully — Vault auto-recovers from token mismatches, and
the pre-backup gate detects empty VMs. All services initialize fresh.

**After DR with override — reconciliation required:**

After rebuilding with `--override-branch-check`, prod VMs may be running code
from the recovery branch rather than the prod branch. Once GitLab is back:

```bash
# 1. Verify data integrity
framework/scripts/validate.sh

# 2. Push the recovery commit to GitLab dev
git push gitlab HEAD:dev

# 3. Create a dev→prod MR in GitLab and merge it

# 4. Let the pipeline redeploy from the correct branches

# 5. Take a backup after the pipeline completes
framework/scripts/backup-now.sh
```

Until reconciliation completes, prod VMs run the recovery branch code rather
than the prod-branch code. This is acceptable during recovery but should be
resolved as soon as GitLab is available.

**What you need to recover from anything:**
- The git repository (in git — contains `site/config.yaml`,
  `site/applications.yaml`, all NixOS configs, encrypted secrets,
  and the full framework)
- `operator.age.key` (backed up separately — decrypts all SOPS secrets)
- The NAS (PostgreSQL for tofu state, NFS for PBS backups) — if it survived

These three things, plus bare Proxmox nodes, are sufficient for a complete
rebuild.

---

## Command Reference

| Command | Purpose |
|---------|---------|
| `validate.sh` | Run all health checks including backup freshness (must pass before declaring work done) |
| `rebuild-cluster.sh` | Full rebuild from bare Proxmox nodes — must be on `prod` branch for routine use. Includes PBS restore, three-gate backup verification, and all post-deploy steps |
| `rebuild-cluster.sh --scope control-plane` | Rebuild only gitlab, cicd, and pbs. Must be on `prod` branch. |
| `rebuild-cluster.sh --override-branch-check` | Override branch safety for disaster recovery. Prints last-known-prod comparison and post-DR reconciliation instructions. |
| `reset-cluster.sh [--confirm]` | Multi-level reset: `--vms` (VMs only), `--storage` (+ pools), `--cluster` (+ boot drives, requires Proxmox reinstall), `--secrets` (age key + secrets.yaml), `--nas` (PBS backups + PostgreSQL). Without --confirm: dry run |
| `rebalance-cluster.sh [--dry-run]` | Migrate VMs back to intended nodes after HA failover |
| `configure-replication.sh "*"` | Clean orphan zvols, recreate replication jobs |
| `configure-node-network.sh --all` | Auto-discover NICs, pin interfaces, deploy network config |
| `configure-node-storage.sh --all` | Create/import ZFS data pools |
| `build-image.sh <host.nix> <role>` | Build a single VM image |
| `build-all-images.sh` | Build all images from both manifests |
| `upload-image.sh <image> <role>` | Upload image to all Proxmox nodes |
| `tofu-wrapper.sh <cmd>` | Run OpenTofu with correct backend config |
| `init-vault.sh <env>` | Initialize/unseal Vault (auto-recovers from PBS token mismatch) |
| `configure-vault.sh <env>` | Load Vault policies from SOPS |
| `configure-gitlab.sh` | Create GitLab project, push repo |
| `register-runner.sh` | Register CI/CD runner with GitLab |
| `configure-pbs.sh` | Configure PBS storage, NFS mount, API token |
| `configure-backups.sh` | Create/update backup jobs for VMs with `backup: true` |
| `configure-sentinel-gatus.sh` | Deploy sentinel Gatus + watchdog on NAS |
| `post-deploy.sh <env>` | Pipeline post-deploy (replication, vault, backups) |
| `ha-deploy.sh` | Push Home Assistant config from Git to HAOS |
| `ha-capture.sh` | Capture Home Assistant config from HAOS to Git |
