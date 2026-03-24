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
framework/scripts/rebuild-cluster.sh

# Reset cluster to factory state (destructive!)
framework/scripts/reset-cluster.sh --confirm

# Decrypt secrets for inspection
sops -d site/sops/secrets.yaml
```

---

## Adding a New VM

Every new VM follows the same pattern: define it in config.yaml, create its
image source, add it to OpenTofu, and deploy. The specifics vary by image
category.

**Application secrets are auto-generated.** If your application needs a
SOPS secret (like an admin API token), the deploy pipeline generates it
automatically on first deploy. You do not need to run `bootstrap-sops.sh`
or manually add tokens to SOPS. The framework checks config.yaml for
enabled applications, generates any missing SOPS keys, and proceeds.
See architecture.md section 9.2 for the on-demand secret lifecycle.

### Category A: NixOS VM (Recommended)

This is the default choice for any VM where you control the OS configuration.
Full pipeline integration, content-addressed images, declarative config.

**1. Add the VM to config.yaml:**

```yaml
# In site/config.yaml → applications:
applications:
  myapp:
    environments:
      prod:
        ip: 10.0.10.70          # pick an unused IP in the prod subnet
        mac: "02:aa:bb:cc:dd:ee" # see below for generation
        node: pve01              # intended placement
      dev:
        ip: 10.0.60.70
        mac: "02:aa:bb:cc:dd:ff"
        node: pve02
    ram_mb: 2048
    cores: 2
    disk_gb: 20                  # vda (root)
    data_disk_gb: 10             # vdb (data, if needed — omit if stateless)
```

Generate unique locally-administered MACs (the `02:` prefix marks them as
locally administered, avoiding collisions with real hardware MACs):

```bash
# Generate one MAC
printf '02:%02x:%02x:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))

# Or generate a pair (prod + dev) for a new VM
for env in prod dev; do
  printf "  %s: \"02:%02x:%02x:%02x:%02x:%02x\"\n" "$env" $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))
done
```

Note: `new-site.sh` pre-generates MACs for all infrastructure VMs. You only
need to generate MACs manually when adding application VMs after initial setup.

**2. Create the NixOS host configuration:**

```bash
# site/nix/hosts/myapp.nix
{ config, pkgs, lib, ... }:
{
  imports = [
    ../../../framework/nix/modules/base.nix       # common base (SSH, certbot, etc.)
    ../../../framework/nix/modules/myapp.nix       # your service module
  ];

  # Any site-specific overrides
}
```

**3. Create or reuse a NixOS module:**

```bash
# framework/nix/modules/myapp.nix (if reusable across deployments)
# OR site/nix/modules/myapp.nix (if site-specific)
{ config, pkgs, lib, ... }:
{
  services.myapp = {
    enable = true;
    # ...
  };
}
```

**4. Add to the flake outputs** in `flake.nix`:

```nix
myapp-image = mkImage {
  hostConfig = "${nixSrc}/site/nix/hosts/myapp.nix";
};
```

**5. Update the nixSrc filter** in `flake.nix` if you added new files that the
build references. If you don't, the build will fail with a file-not-found error
(this is by design — see `.claude/rules/nixos.md`).

**6. Add to the site image manifest** (`site/images.yaml`):

```yaml
roles:
  myapp:
    category: nix
    host_config: site/nix/hosts/myapp.nix
    flake_output: myapp-image
```

**7. Add the OpenTofu module instantiation** in `site/tofu/main.tf`:

```hcl
module "myapp_prod" {
  source = "../../framework/tofu/modules/proxmox-vm"
  # ... standard parameters from config.yaml
}

module "myapp_dev" {
  source = "../../framework/tofu/modules/proxmox-vm"
  # ... same module, dev values
}
```

**8. Deploy:**

```bash
git add -A && git commit -m "add myapp VM"
git push gitlab dev
# Pipeline builds the image, deploys to dev
# Verify in dev, then promote to prod via MR
```

**9. Post-deploy (if the VM has precious state):**
- Add PBS backup jobs via `configure-backups.sh` or update the backup
  configuration
- The pipeline's `post-deploy.sh` handles replication cleanup automatically

### Category B: Non-NixOS VM (Custom Image)

For VMs that need a specific non-NixOS base (Debian, Ubuntu, vendor kernel).

**1–2.** Same as Category A (config.yaml entry and OpenTofu module).

**3. Create a build script** at `site/images/myapp/build.sh` that produces
an image file. The script should be idempotent and output a single `.img` file.

**4. Add to `site/images.yaml`:**

```yaml
roles:
  myapp:
    category: external
    build_script: site/images/myapp/build.sh
```

**5–8.** Same as Category A (OpenTofu module, deploy via pipeline).

The pipeline runs your build script, hashes the output, and names it
`myapp-<sha256>.img`. If the hash matches the existing image, the VM is not
recreated.

### Category C: Vendor Appliance (Manual Image)

For vendor-provided appliances (PBS, HAOS) that ship as ISOs or pre-built
images.

**1.** Add to config.yaml as above.

**2.** Add the OpenTofu module in `site/tofu/main.tf`. Use the vendor image
directly — no build pipeline.

**3.** Install the appliance manually (ISO boot via Proxmox UI, or import
a pre-built disk image).

**4.** Category C VMs are Tier 2 (workstation-managed). They do not appear
in the image manifests and are not built by the pipeline. Deploy from the
workstation:

```bash
cd site/tofu
../../framework/scripts/tofu-wrapper.sh apply -target=module.myapp_prod
```

### DNS Records

Adding a VM to `config.yaml → applications` (with an IP) automatically
generates a DNS A record. OpenTofu includes the record in the DNS VM's CIDATA.
On the next deploy, the DNS VM loads the updated zone at boot. No manual DNS
step is needed.

For non-VM DNS records (MX, TXT, CNAME), add them to
`site/dns/zones/<env>.yaml` and deploy.

### Deciding on vdb (Data Disk)

- **Stateless VMs** (web servers, proxies): no vdb needed. The VM is fully
  disposable — `tofu apply` recreates it from the image.
- **VMs with precious state** (databases, Home Assistant): add a `data_disk_gb`
  in config.yaml. The data lives on vdb, which persists across VM recreation.
  Add PBS backup jobs for the vdb.
- **VMs with configuration state** (category 2 data pushed from Git): vdb is
  optional. If the config can be re-pushed on every deploy, no vdb is needed.

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

Deploy from the workstation:

```bash
framework/scripts/rebuild-cluster.sh
```

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

VM IPs are in `config.yaml → vms.*` and `config.yaml → applications.*`.

### When DNS Is Down

Add entries to your workstation's `/etc/hosts`:

```bash
# Generate from config.yaml
yq '.vms | to_entries | .[] | .value.ip + " " + .key' site/config.yaml
```

### Full Disaster Recovery

See architecture.md section 13.4 for details. See architecture.md section
13.5 for the multi-level reset model.

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

**What you need to recover from anything:**
- `site/config.yaml` (in git — describes your entire infrastructure)
- `operator.age.key` (backed up — decrypts all SOPS secrets)
- The git repository (code + configuration + encrypted secrets)
- The NAS (PostgreSQL for tofu state, NFS for PBS backups) — if it survived

These four things, plus bare Proxmox nodes, are sufficient for a complete
rebuild.

---

## Command Reference

| Command | Purpose |
|---------|---------|
| `validate.sh` | Run all health checks including backup freshness (must pass before declaring work done) |
| `rebuild-cluster.sh` | Full rebuild from bare Proxmox nodes — includes PBS restore, three-gate backup verification, and all post-deploy steps |
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
