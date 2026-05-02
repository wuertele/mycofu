# Mycofu Operations Guide

This document covers day-to-day operation and maintenance of a running Mycofu
cluster. It assumes the cluster has been built and validated per
[GETTING-STARTED.md](GETTING-STARTED.md).

For architecture decisions and design rationale, see
[architecture.md](architecture.md). For project overview, see
[README.md](README.md).

---

## Quick Reference

Most operational tasks are handled automatically by the GitLab pipeline.
`safe-apply.sh` runs a stopped OpenTofu apply, `restore-before-start.sh`,
then a start/register apply before post-success convergence
(`configure-replication.sh "*"` and `post-deploy.sh`). Phase 1 apply
failures use `restore-before-start.sh --recovery-mode` (#224).
`validate.sh` runs in the pipeline's validation stage; the placement
watchdog on the NAS handles rebalancing. The commands below are for
manual/workstation use when you're debugging, deploying Tier 2 VMs, or
recovering from a failure outside the pipeline.

**Suppressing recovery (`--no-recovery`):** for DR tests that need to
observe the un-recovered partial-failure state, pass `--no-recovery` to
`safe-apply.sh`. Preboot restore still runs; the flag only suppresses
failure recovery and post-success convergence. Do not set this in normal
workflows.

**Fresh cluster with no PBS backups yet:** the pre-deploy backup stage may
warn that PBS is not configured yet, but `restore-before-start.sh` will still
fail closed before starting any backup-backed VM with an empty vdb. For an
intentional first deploy, generate the explicit approval value and rerun the
manual pipeline/job with `FIRST_DEPLOY_ALLOW_VMIDS` set for that one run:

```bash
framework/scripts/list-backup-backed-vmids.sh dev
# Example output: 303,305

FIRST_DEPLOY_ALLOW_VMIDS=303,305 framework/scripts/safe-apply.sh dev
```

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

# Clean up replication after VM recreation (run by safe-apply.sh's
# post-success convergence after preboot restore; manual only for Tier 2
# workstation deploys outside safe-apply.sh)
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

# DR rehearsal reset on a healthy cluster (destructive!)
framework/scripts/reset-cluster.sh --test --confirm

# Corrupt-state recovery reset with explicit restore pins (destructive!)
framework/scripts/reset-cluster.sh --recover --restore-pin-file build/restore-pin-reset.json --confirm

# Decrypt secrets for inspection
sops -d site/sops/secrets.yaml
```

---

## Pre-Promotion Dashboard Check

Before promoting `dev` to `prod`, validate the cluster dashboard from the
dev copy. This is the rollout preview for the production UI.

1. Open `https://influxdb.dev.<domain>/`.
2. Confirm all VMs are visible and each card has a chart.
3. Confirm node headers and VM labels are colored appropriately for current load/state.
4. Confirm VM and node label click-through opens the correct Grafana detail dashboard.
5. Confirm `Swap Axes` works, switch to `Flat`, reload, and verify the layout preference persists.

If any check fails, investigate before promoting the change to `prod`.

---

## Adding a New VM

Application VMs are specified in `site/applications.yaml`. Framework VMs
(DNS, Vault, PBS, GitLab, etc.) are in `site/config.yaml` and are not
operator-managed in normal use.

You can add an application VM in two ways — both are fully supported and
produce identical results. The framework reads `applications.yaml` directly;
it does not require that entries were produced by a generator.

**Most application secrets are auto-generated.** If your application needs a
pipeline-managed SOPS secret (like an admin API token), the deploy pipeline
generates it automatically on first deploy. You do not need to run
`bootstrap-sops.sh` or manually add those keys to SOPS. The exception is
catalog app Vault AppRole credentials: the pipeline checks for them, but the
operator creates them from the workstation via the onboarding flow below.
See architecture.md section 9.2 for the secret lifecycle split.

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
        # Required for OpenTofu pool-* tagging
        pool: prod
      dev:
        ip: 10.0.20.70
        vmid: 501
        mac: "02:aa:bb:cc:dd:ff"
        pool: dev
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
  tags   = ["pool-${local.app_myapp.environments.prod.pool}"]
  # parameters from applications.yaml
}
module "myapp_dev" {
  source = "../../framework/tofu/modules/proxmox-vm"
  tags   = ["pool-${local.app_myapp.environments.dev.pool}"]
  # parameters from applications.yaml
}
```

**6. Deploy:**

```bash
git add -A && git commit -m "add myapp VM"
git push gitlab dev
# Pipeline builds image, deploys to dev. Verify, then promote to prod via MR.
```

## Onboarding New Catalog Apps

Some catalog apps ship `framework/catalog/<app>/vault-requirements.yaml`.
Those apps need Vault AppRole credentials in SOPS before `tofu apply` can
deliver their bootstrap secrets via CIDATA.

When those credentials are missing, the pipeline and `safe-apply.sh` fail fast
with a preflight error naming the app and the remediation command:

```text
ERROR: <app> is enabled in applications.yaml but has no AppRole
credentials in SOPS for <env>.
```

Run the onboarding command from the workstation:

```bash
framework/scripts/rebuild-cluster.sh --scope onboard-app=<app>
```

What it does:

1. Verifies the app is enabled in `site/applications.yaml` and has a
   `vault-requirements.yaml` manifest.
2. Configures the AppRole in Vault for `dev`.
3. Verifies the new SOPS keys exist and commits `site/sops/secrets.yaml` with:
   `onboard: AppRole credentials for <app> (dev)`
4. Repeats the same flow for `prod`, producing:
   `onboard: AppRole credentials for <app> (prod)` when new prod creds were needed.
5. Stops. It does **not** push anything to GitLab.

After the command finishes:

```bash
git log --oneline -2 -- site/sops/secrets.yaml
git push
```

That push is the handoff point. Once the commits reach the branch you are
deploying from, rerun the pipeline or `safe-apply.sh` and the preflight passes.

Example:

```bash
# 1. Enable the app and push. The preflight fails with the remediation.
git push gitlab dev

# 2. From the workstation, create dev+prod AppRole credentials locally.
framework/scripts/rebuild-cluster.sh --scope onboard-app=influxdb

# 3. Inspect the local SOPS commits, then push them.
git log --oneline -2 -- site/sops/secrets.yaml
git push

# 4. Retry the deploy. The preflight now passes.
framework/scripts/safe-apply.sh dev
```

Re-running onboarding for an already-onboarded app is safe. If the AppRole and
SOPS entries already exist, the command reports that no new SOPS commit is
needed for that environment.

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

### Workstation Access and Operations

Sprint 024 adds a single catalog workstation role, deployed as:

- `workstation_dev` — canary workstation for dev deploys
- `workstation_prod` — primary interactive workstation

SSH access:

```bash
# LAN / project DNS
ssh kentaro@workstation.dev.<domain>
ssh kentaro@workstation.prod.<domain>

# Tailscale uses the same FQDNs once the node has joined the tailnet
ssh kentaro@workstation.dev.<domain>
ssh kentaro@workstation.prod.<domain>
```

What to expect:

- The login shell is `zsh`.
- `/home/kentaro` lives on `vdb` (`ext4`, label `home`), not on the overlay root.
- `home-manager` is installed system-wide and `nix-shell`, `nix profile install`, and `nix develop` are available to the user.
- X11 forwarding is enabled. Example:
  `ssh -X kentaro@workstation.prod.<domain> xterm`

Monitoring and health:

- Gatus monitors the workstation health endpoint, TLS certificate, and SSH reachability.
- The functional health endpoint is `https://workstation.<env>.<domain>:8443/status`.
- On `dev`, Gatus reaches the workstation via the management NIC (`workstation-mgmt.dev.<domain>`).

Update behavior and persistence:

- The workstation is field-updatable. Routine software changes are delivered by closure push, not VM recreation.
- Closure push still ends with a reboot in the current implementation. SSH sessions and tmux sessions do **not** survive that reboot.
- `/home` is preserved across those field updates because it is mounted from `vdb`.

Security posture:

- The workstation is currently LAN-accessible on its environment VLAN and also reachable over Tailscale.
- Restricting access to tailnet-only is a future hardening change, not part of Sprint 024.

How the user submits MRs:

- Work on the workstation in a normal Git clone.
- Push branches to GitLab.
- Open merge requests against `dev`.
- Promote to `prod` only through the normal `dev` → `prod` MR flow.

### Publishing to GitHub

Publishing is **opt-in** via `publish.github.enabled` in `site/config.yaml`.
When the flag is `false` or absent, the `publish:github` pipeline job
self-skips (exits 0 with a log line) and `validate-site-config.sh` does not
require `github.remote_url`. Downstream adopters who clone Mycofu without a
public mirror can leave it disabled. The scaffolded default in
`framework/templates/config.yaml.example` is `false`.

When `publish.github.enabled: true` (this site's setting), every successful
merge to `prod` automatically runs the `publish:github` job after `test:prod`.
That job filters the repo to framework-safe paths, creates a single publish
commit, and force-pushes it to the `github` remote's `main` branch with
`--force-with-lease`.

`github.remote_url` in `site/config.yaml` is required when
`publish.github.enabled` is true. Missing deploy key material or a missing runner remote URL is now an error,
not a successful skip (this matters only when publish is enabled). Run the
seeding and verification commands below before promoting a publish-enabled
config to prod.

Configuration and auth failures make `publish:github` red: missing key, missing
URL, invalid URL, repository-not-found, permission denied, host key failures,
bad key format, unknown post-transport failures, and repeated
force-with-lease conflicts. DNS, TCP, and GitHub transport outages are the only
non-blocking class; those exit 0 with `PUBLISH_STATUS=outage_skip` and are
surfaced by the `github-mirror-main` Gatus endpoint.

For workstation fallback, run:

```bash
framework/scripts/sync-to-main.sh
```

The wrapper fetches `gitlab/prod`, verifies that the prod HEAD commit already
has a passing GitLab pipeline, and then publishes the same filtered tree to the
`github` remote. Use `--force-unvalidated` only for emergencies when the GitLab
API is unavailable and you have separately confirmed the code should be
published.

The pipeline and workstation credential paths are deliberately different. The
pipeline uses a Vault-delivered deploy key at
`/run/secrets/vault-agent/github-deploy-key`; `sync-to-main.sh` uses the
operator's local SSH credentials for the workstation `github` remote. Keep this
credential seam intact. The two paths are parity-compatible in published
content and `.mycofu-publish.json` metadata, not identical in auth mechanism.

If the push fails with `--force-with-lease`, the GitHub remote has commits that
your private repo has not absorbed yet. This usually means a GitHub PR was
merged directly to `main`. Fetch it, cherry-pick it into your private flow, and
let the next prod deploy publish the reconciled history.

#### Initial Setup

The GitHub deploy key is a dedicated ed25519 key pair used only by the
CI runner for publishing. Set it up once:

```bash
# 1. Generate a dedicated key pair
ssh-keygen -t ed25519 -f /tmp/mycofu-github-deploy-key -N "" \
  -C "mycofu-cicd-publish"

# 2. Add the PUBLIC key to your GitHub repo:
#    Settings → Deploy keys → Add deploy key → "Allow write access"
cat /tmp/mycofu-github-deploy-key.pub

# 3. Seed the private key into SOPS and Vault.
framework/scripts/seed-github-deploy-key.sh prod \
  --key-file /tmp/mycofu-github-deploy-key \
  --shred-source

# 4. After the Phase 3 config.yaml change lands and before merging dev -> prod
#    for the first publish, converge cicd CIDATA from the workstation.
framework/scripts/rebuild-cluster.sh --scope control-plane

# 5. Verify SOPS, Vault, runner materialization, and GitHub read access.
framework/scripts/verify-github-publish.sh prod
# Confirm this line before triggering the prod pipeline:
# [PASS] runner remote-url materialized

# 6. Prove write access without moving main.
framework/scripts/verify-github-publish.sh prod \
  --write-smoke-branch sprint-033-smoke
```

For the first publish after Sprint 033, GitHub `main` does not yet contain
`.mycofu-publish.json`. The prod job refuses to rewrite public history unless
`GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE=1` is set for that first run. Review the
baseline GitHub `main` OID in
`docs/reports/sprint-033-github-publish-baseline.md` before setting it. The
rewrite replaces the current public history with one squashed `Mycofu Publish
Bot` commit.

After seeding, vault-agent on the runner delivers the key at runtime.
`configure-vault.sh prod` can repopulate `secret/data/github/deploy-key` from
SOPS if Vault is reset and reconfigured. Rotate the key with:

```bash
framework/scripts/seed-github-deploy-key.sh prod \
  --key-file /tmp/new-mycofu-github-deploy-key \
  --rotate \
  --shred-source
framework/scripts/verify-github-publish.sh prod
```

#### First-publish disciplines

These three disciplines apply to the first prod publish (the one that
moves GitHub `main` from its pre-Sprint-033 OID to the first
`Mycofu Publish Bot` commit) and matter only in that window. Once
`.mycofu-publish.json` exists at GitHub `main`, the rewrite-guard is
dormant and these disciplines are no longer load-bearing.

1. **Treat `GITHUB_PUBLISH_ALLOW_INITIAL_REWRITE=1` as a per-run
   override.** Set it for the one-shot first publish (manual
   pipeline trigger or temporary CI variable), then unset it
   immediately after the publish succeeds. Do not pin it
   permanently. The guard is consulted only when the metadata file
   is missing at GitHub `main`; on the steady-state path the
   variable is never read. Keeping it permanently set means a later
   metadata loss (force-push erasure, manual deletion via the
   GitHub UI) would silently re-rewrite without operator
   acknowledgement.

2. **Run `verify-github-publish.sh prod --write-smoke-branch <name>`
   before authorizing the first main rewrite.** The smoke-branch
   mode soaks the seeding ceremony — vault-agent materialization,
   key validity, write access, transport, configured remote URL —
   without consuming the one-shot main rewrite event. It does
   *not* soak the publisher's content-handling logic
   (`publish_filter`, metadata writer, force-with-lease retry).
   That logic runs end-to-end for the first time on the actual
   first publish. Smoke-branch passing is necessary but not
   sufficient.

3. **If the first prod pipeline publish surfaces unexpected
   behavior, revert the merge — do not patch
   `publish-to-github.sh` in place and re-run.** The publisher
   logic can be fixed in a follow-up MR with proper test
   coverage; patching against a live mirror rewrite is the
   Sprint-027 anti-pattern. Each "fix and re-run" iteration on a
   force-rewrite alters public history and compounds whatever
   surfaced.

Gatus monitors mirror drift through `github-mirror-main` in group
`publishing`. It fetches the public
`https://raw.githubusercontent.com/<owner>/<repo>/main/.mycofu-publish.json`
file and compares `[BODY].source_commit` to the prod commit used to generate
the deployed Gatus config. `validate.sh` excludes the `publishing` group from
the pre-publish aggregate health gate, so `test:prod` does not fail in the
deploy-to-publish window.

### Accepting a GitHub Contribution

GitHub is a public mirror, not the deployment source of truth. To bring an
external GitHub PR into the private deployment flow:

```bash
# 1. Fetch the public contribution
git fetch github pull/<PR-number>/head:github-pr-<PR-number>

# 2. Cherry-pick it onto a private feature branch
git checkout -b issue-<id>-github-pr dev
git cherry-pick github-pr-<PR-number>

# 3. Push the feature branch to GitLab and merge to dev
git push gitlab issue-<id>-github-pr

# 4. Promote dev to prod through the normal MR flow
# After the prod pipeline passes, publish:github republishes the filtered result.
```

Do not merge GitHub `main` directly into `dev` or `prod`. Cherry-picking keeps
the private deployment history explicit and ensures the change is validated in
dev before it is re-published from prod.

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
- Pins the latest known-good PBS backup, creates the VM stopped, restores vdb
  before first boot, and then starts/registers HA (GitLab gets its database
  back, not an empty instance)
- Cleans stale SSH host keys
- Re-registers the CI runner (if GitLab was recreated)
- Configures replication
- Runs the three-gate backup validation

You do not need to run individual scripts (build-image, upload-image,
tofu apply) manually — `rebuild-cluster.sh` handles the entire sequence.

Update GitLab before the runner — runner registration is stored in GitLab's
database.

### After Any VM Recreation

When a deploy recreates a VM (new image hash, CIDATA change, etc.),
`safe-apply.sh` or `rebuild-cluster.sh` handles the restore boundary and
post-success convergence automatically:

1. Backup pin capture (`backup-now.sh --pin-out ...`)
2. Plan-derived restore manifest from `tofu plan -json`
3. Stopped Phase 1 apply (`start_vms=false`, `register_ha=false`)
4. Preboot vdb restore with `restore-before-start.sh`
5. Start/register Phase 2 apply (`start_vms=true`, `register_ha=true`)
6. SSH host key cleanup
7. Replication cleanup (`configure-replication.sh`)
8. Vault init/unseal (if Vault was recreated, with auto-recovery from
   token mismatch)
9. GitLab configuration and runner registration (if GitLab was recreated)
10. Three-gate backup validation

For manual workstation deploys outside `rebuild-cluster.sh` (not
recommended), do not use raw `tofu apply` for backup-backed VMs. Use
`framework/scripts/safe-apply.sh <env>` so recreated VMs remain stopped until
restore succeeds. After the wrapper completes, the remaining manual checks are:

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
# This will: pin backups, create replacement VMs stopped, restore vdb before
# first boot, start/register HA, and reconnect the runner if cicd was rebuilt.
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
  artifacts (GitLab CI → build:merge → Artifacts) before running any
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
- **Rate limited (Let's Encrypt):** 5 certs per FQDN per 168 hours. The
  pipeline runs `check-cert-budget.sh` before prod deploys and refuses to
  proceed if any FQDN is at or over the limit. Example error:
  ```
  ERROR: influxdb.prod.wuertele.com has already had 5 certificates
  issued in the last 168 hours. The Let's Encrypt rate limit is 5 per
  FQDN per 168 hours.
  ```
  Options: wait for the window to clear, use closure push instead of
  recreation, or override with `--ignore-cert-budget` (not recommended
  for prod). Don't rapid-fire `certbot` while debugging.
- **Pebble unreachable (dev):** Check if the pebble VM is running. Pebble is
  stateless — rebuilding it is safe.
- **Pebble negative cache (dev):** If Pebble queries the recursor (port 53)
  instead of the authoritative (port 8053), it caches NXDOMAIN for 5 minutes.
  This is a configuration bug — Pebble should query port 8053 directly.

### Vault-Backed Certificate Storage

For every non-Vault certbot VM, `/etc/letsencrypt` is now backed by Vault after
the first successful issuance or an explicit backfill. `cert-restore` runs
before `certbot-initial`; if Vault has a cert for the VM's FQDN with more than
30 days remaining, the VM restores that lineage locally and skips a fresh ACME
request.

Inspect the stored cert and the last restore/sync activity:

```bash
vault kv get -format=json mycofu/certs/<fqdn> \
  | jq '.data.data | {not_after, fingerprint, issued_at}'

vault kv metadata get -format=json mycofu/certs/<fqdn> \
  | jq '.data.custom_metadata'

ssh root@<vm-ip> "journalctl -u cert-restore -u cert-sync --since '-15m'"
```

Backfill existing live certs into Vault before a prod rollout or after enabling
the feature on an already-issued environment:

```bash
framework/scripts/cert-storage-backfill.sh prod
framework/scripts/check-cert-budget.sh prod
```

Expected prod result: every FQDN is reported as covered by Vault and `0` FQDNs
remain subject to the Let's Encrypt budget gate.

To force a fresh ACME issuance on the next initial-issuance path, delete the
Vault copy before recreating the VM or before restarting `certbot-initial` on a
VM where the local lineage has been intentionally cleared:

```bash
vault kv metadata delete mycofu/certs/<fqdn>
ssh root@<vm-ip> "systemctl restart certbot-initial"
```

If the VM still has a non-empty local cert, `certbot-initial` skips by design.
For an in-place rotation on a running VM, use:

```bash
ssh root@<vm-ip> "certbot renew --force-renewal --cert-name <fqdn>"
```

Known limitation: the very first deploy of a cert-bearing VM still has to talk
to the ACME server. Vault becomes the source of truth only after that first
issuance succeeds, or after `cert-storage-backfill.sh` seeds an existing live
cert into Vault.

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

### Tailscale Remote Access

Tailscale uses a split-secret model:

- The reusable auth key is a bootstrap secret stored in SOPS and delivered
  by CIDATA to `/run/secrets/tailscale/auth-key`
- The node identity is runtime state stored in Vault at
  `secret/tailscale/nodes/<domain>/<role>`

**Troubleshooting**

```bash
# Check daemon and helper services
ssh root@<vm-mgmt-ip> "systemctl status tailscaled tailscale-identity-restore tailscale-join --no-pager"

# Check current Tailscale state on the VM
ssh root@<vm-mgmt-ip> "tailscale status --json --peers=false | jq '{BackendState, HostName: .Self.HostName, TailscaleIPs: .Self.TailscaleIPs}'"

# Check recent logs
ssh root@<vm-mgmt-ip> "journalctl -u tailscaled -u tailscale-identity-restore -u tailscale-join -b --no-pager"

# Check the stored identity in Vault
vault kv get secret/tailscale/nodes/<domain>/<role>
```

**Auth key rotation**

Rotating `tailscale_auth_key` is a CIDATA change, so it recreates any VM
that consumes it.

```bash
# 1. Update SOPS
sops site/sops/secrets.yaml
# Update: tailscale_auth_key: "tskey-auth-..."

# 2. Rebuild and redeploy the affected VM
git checkout prod
framework/scripts/rebuild-cluster.sh --scope control-plane

# 3. Re-run post-recreation checks
framework/scripts/register-runner.sh
framework/scripts/configure-replication.sh "*"
framework/scripts/validate.sh
```

**Identity recovery**

If the VM is already connected but Vault has lost the identity record, a
restart of `tailscale-join` is enough to self-heal the missing Vault entry:

```bash
ssh root@<vm-mgmt-ip> "systemctl restart tailscale-join"
```

If the identity itself is stale or must be discarded, delete the Vault
record and restart the Tailscale services so the VM performs a fresh join:

```bash
vault kv delete secret/tailscale/nodes/<domain>/<role>
ssh root@<vm-mgmt-ip> "rm -rf /var/lib/tailscale/* && systemctl restart tailscale-identity-restore tailscaled tailscale-join"
```

After a fresh join, the VM appears in Tailscale admin as a new machine with
the same hostname (`<role>-<domain-dashed>`) but a new node identity.

**Adding Tailscale to another VM**

Phase 1 enables Tailscale only on GitLab. To add another VM in a later
change:

1. Add `tailscale: true` to the VM in `site/config.yaml`
2. Import `framework/nix/modules/tailscale.nix` in that host file
3. Run `framework/scripts/configure-vault.sh <env>` before first boot so the
   AppRole policy exists
4. Rebuild, plan, deploy, and validate the VM as usual

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
   For backup-backed prod/shared certbot VMs, the rebuild also checks that
   persisted renewal lineage still matches the configured site ACME URL before
   any new PBS backup is allowed.
2. **Backup execution (step 18):** Hard failure if any vzdump fails, with
   actual error output displayed.
3. **Post-backup validation (step 16b):** Verifies backups on PBS contain
   real application state, not just filesystem metadata.

A successful `rebuild-cluster.sh` implies working, verified backups.
See architecture.md section 14.2 for the full three-gate model.

**Continuous (daily):** PBS runs scheduled backup jobs automatically.
These scheduled jobs do NOT have the pre-backup validation gate — if
application state is corrupted between rebuilds, the daily backup may
capture corrupted state. PBS retention policies (keeping multiple daily
snapshots) mitigate this: you can restore from any retained snapshot,
not just the most recent. Monitor daily backup completion via the PBS
web UI or the Gatus dashboard.

**Manual ad hoc backups:** `framework/scripts/backup-now.sh` now runs the
same persisted-certbot lineage gate as rebuild Step 18 for backup-backed
prod/shared certbot VMs (GitLab, `vault_prod`, and enabled backup-backed
HTTPS apps). If the site ACME mode is production and any of those VMs still
has staging renewal lineage, the script refuses to take a new backup.

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

**If the certbot backup gate blocks:** Read the reported VM label, FQDN, and
renewal path/value first — the helper prints exactly which lineage is wrong.
Then repair the persisted renewal state on the VM, re-run validation, and
only then take a new backup. From the repo root on the workstation:

```bash
ssh root@<vm-ip> \
  'bash -s -- --mode repair \
    --expected-acme-url https://acme-v02.api.letsencrypt.org/directory \
    --expected-mode production \
    --fqdn <fqdn> \
    --label <vm-label>' \
  < framework/scripts/certbot-persisted-state.sh

framework/scripts/validate.sh
framework/scripts/backup-now.sh
```

If the VM still serves a `Fake LE` leaf after repair, that is a warning about
the current live cert, not a reason to re-poison the renewal lineage. The
important fix is the renewal config. The next `certbot renew` will use the
correct production server, or the operator can force-renew manually if an
immediate production leaf is required.

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

`--override-branch-check` is narrower than `acme: staging`. The override path
only stages stateless prod/shared certbot VMs during the rebuild. GitLab and
other backup-backed certbot VMs keep the configured long-term ACME lineage
from `site/config.yaml` so persisted `/etc/letsencrypt` state and PBS backups
do not get poisoned. If you intentionally want those persisted VMs on staging,
set `acme: staging` in `site/config.yaml`; `--override-branch-check` alone
will not rewrite their renewal lineage.

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

**Full-cluster DR rehearsal on a healthy cluster:**

```bash
git checkout prod
framework/scripts/reset-cluster.sh --test --confirm
framework/scripts/rebuild-cluster.sh --restore-pin-file build/restore-pin-reset.json
```

**Corrupt-state escape with explicit restore pins:**

```bash
# Use a known-good pin file from a previous backup run
framework/scripts/reset-cluster.sh --recover --restore-pin-file build/restore-pin-reset.json --confirm
framework/scripts/rebuild-cluster.sh --restore-pin-file build/restore-pin-reset.json
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

The override path may still switch stateless prod/shared certbot VMs to
Let's Encrypt staging for the rebuild, but it does not rewrite persisted
certbot lineage on GitLab or any other backup-backed certbot VM.

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

## Operational Runbooks

### Field Update Workflow

Control-plane VMs (gitlab, cicd) are updated via NixOS closure push, not
VM recreation. The pipeline handles this automatically; manual workstation
deployment is the fallback.

**Pipeline path (normal):**
```bash
git push gitlab dev    # triggers pipeline: build -> deploy -> converge
```

The pipeline's `deploy-control-plane` stage calls `converge-vm.sh --closure`
for each control-plane VM. After completion, the R7.2 drift check verifies
the pushed closure matches the running system.

**Workstation fallback (when pipeline is unavailable):**
```bash
# Build the closure
nix build .#nixosConfigurations.gitlab.config.system.build.toplevel

# Push it to the VM
framework/scripts/converge-vm.sh \
  --closure ./result \
  --targets "-target=module.gitlab" \
  --override-branch-check
```

### Recovery from Broken Control-Plane Closure

When a closure push breaks a control-plane VM (gitlab or cicd), the
correct response is to fix the code and reconverge — not to roll back
to a state that diverges from the repo. The commit is the authority for
what VMs should run.

**Standard recovery (preferred):**

```bash
# 1. Fix the NixOS module that broke the VM
#    Edit the code locally, commit to a branch

# 2. Build the corrected closure
nix build .#nixosConfigurations.gitlab.config.system.build.toplevel \
  --out-link build/closure-gitlab

# 3. Push the corrected closure directly (bypasses the pipeline)
framework/scripts/converge-vm.sh \
  --config site/config.yaml \
  --apps-config site/applications.yaml \
  --closure $(readlink -f build/closure-gitlab) \
  --targets "-target=module.gitlab"

# 4. Verify the VM is working, then push the fix to GitLab
git push gitlab dev

# 5. The pipeline deploys the same corrected closure (no-op)
```

This produces a VM state that matches the fix commit. The pipeline
sees zero drift on the next run.

### Recovery: gitlab Down After Closure Push

**Symptoms:** GitLab UI unreachable, pipeline stuck, can't push to GitLab.

```bash
# 1. Fix the code locally and build the corrected closure
nix build .#nixosConfigurations.gitlab.config.system.build.toplevel \
  --out-link build/closure-gitlab

# 2. Push the corrected closure directly to gitlab via SSH
framework/scripts/converge-vm.sh \
  --config site/config.yaml \
  --apps-config site/applications.yaml \
  --closure $(readlink -f build/closure-gitlab) \
  --targets "-target=module.gitlab"

# 3. Verify gitlab is back
curl -sk https://gitlab.prod.<domain>/ | head -5

# 4. Now push the fix (gitlab is back, git push works)
git push gitlab dev
```

### Recovery: Runner Down After Self-Update

**Symptoms:** Pipeline jobs stuck in "pending", runner VM SSH-reachable
but `gitlab-runner` service is failing.

```bash
# 1. Fix the code and build the corrected cicd closure
nix build .#nixosConfigurations.cicd.config.system.build.toplevel \
  --out-link build/closure-cicd

# 2. Push the corrected closure
framework/scripts/converge-vm.sh \
  --config site/config.yaml \
  --apps-config site/applications.yaml \
  --closure $(readlink -f build/closure-cicd) \
  --targets "-target=module.cicd"

# 3. Verify runner is online
ssh root@<cicd-ip> "gitlab-runner status"

# 4. Push the fix
git push gitlab dev
```

### Break-Glass: Previous Generation Activation via SSH

**Use only when the operator cannot build a closure at all** (nix builder
down, workstation broken, no access to a working nix installation). This
produces a VM state that diverges from the repo — the next pipeline run
will redeploy the current (possibly broken) closure. Fix the code and
push before the next pipeline runs.

```bash
# SSH to the VM
ssh root@<vm-ip>

# List available generations
ls -d /nix/var/nix/profiles/system-*-link | sort -V

# Check current generation
readlink /nix/var/nix/profiles/system

# Activate the previous generation (replace N with the generation number)
/nix/var/nix/profiles/system-N-link/bin/switch-to-configuration switch

# Fix grub paths (required on overlay-root VMs)
if [ -f /boot/grub/grub.cfg ]; then
  sed -i 's|)/store/|)/nix/store/|g' /boot/grub/grub.cfg
fi

# Reboot
reboot
```

After reboot, verify with `readlink -f /run/current-system` that the VM
is running the expected generation. Then fix the code and push as soon
as possible — the VM is now diverged from the repo.

### Recovery Decision Table

| Scenario | Use | Command |
|----------|-----|---------|
| Closure regression (software broke) | Fix code + reconverge | `converge-vm.sh --closure` from workstation |
| Data corruption on vdb | PBS restore | `restore-from-pbs.sh --force --target <vmid>` |
| VM won't boot at all | Factory rebuild | `rebuild-cluster.sh` |
| Total cluster loss | Full DR | `rebuild-cluster.sh` from bare Proxmox |
| Can't build a closure (nix broken) | Break-glass SSH | Manual generation activation (see above) |

**Key principle:** The commit is the authority. Fix the code first,
then converge. Break-glass generation rollback is a last resort that
creates repo divergence.

### known_hosts Management After Sprint 014

SSH host keys are now persistent across reboots, field updates, and factory
rebuilds. You should not see `known_hosts` warnings during normal operation.

If a warning appears after a reboot or field update:
1. Check the `ssh-host-key-restore` service:
   `ssh root@<ip> "systemctl status ssh-host-key-restore"`
2. If the service failed, check whether CIDATA delivered the keys:
   `ssh root@<ip> "ls -la /run/secrets/ssh/"`
3. If keys are missing from CIDATA, verify the SOPS entry exists:
   `sops -d site/sops/secrets.yaml | grep ssh_host_keys.<vm_key>`

---

## Command Reference

| Command | Purpose |
|---------|---------|
| `validate.sh` | Run all health checks including backup freshness (must pass before declaring work done) |
| `rebuild-cluster.sh` | Full rebuild from bare Proxmox nodes — must be on `prod` branch for routine use. Includes PBS restore, three-gate backup verification, and all post-deploy steps |
| `rebuild-cluster.sh --scope control-plane` | Rebuild only gitlab, cicd, and pbs. Must be on `prod` branch. |
| `rebuild-cluster.sh --override-branch-check` | Override branch safety for disaster recovery. Prints last-known-prod comparison and post-DR reconciliation instructions. |
| `reset-cluster.sh --test [--confirm]` | Healthy-cluster DR rehearsal: runs `backup-now.sh --env all --verify --pin-out build/restore-pin-reset.json`, then performs the full cluster reset if confirmed |
| `reset-cluster.sh --recover --restore-pin-file <path> [--confirm]` | Corrupt-state recovery: validates every pinned volid in PBS, warns about uncovered precious-state VMs, and performs the full cluster reset if confirmed |
| `reset-cluster.sh --vms [--confirm]` | VM-only reset (HA, replication, snippets, tofu state). Lower blast radius than `--test` / `--recover` |
| `reset-cluster.sh --storage [--confirm]` | `--vms` plus ZFS pools and data-NVMe partition tables |
| `reset-cluster.sh --nas [--confirm]` | Full cluster reset plus NAS PostgreSQL state and sentinel/watchdog cleanup |
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
