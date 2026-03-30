# Getting Started with Mycofu

This guide walks you from a fresh clone to a fully operational Proxmox HA
cluster with dev/prod separation, automated DNS, TLS certificates, secrets
management, and one-command rebuild.

**Time estimate:** 2–4 hours for the physical and manual steps (hardware,
Proxmox install, gateway, NAS). The automated rebuild takes 15–30 minutes
after that.

**Prerequisites:**
- 2–4 nodes with Proxmox VE (see hardware requirements below)
- A VLAN-capable gateway (UniFi, pfSense, OPNsense, etc.)
- A managed switch (VLAN trunking)
- An off-cluster NAS with PostgreSQL and NFS (Synology, TrueNAS, etc.)
- A registered domain name
- An operator workstation (macOS or Linux)

For project overview and design rationale, see [README.md](README.md). For
architecture decisions, see [architecture.md](architecture.md). For day-to-day
operations after setup, see [OPERATIONS.md](OPERATIONS.md).

---

## Before You Start

Mycofu has real prerequisites — things you need to have in place before the
automated parts can run. This section tells you exactly what each one is, why
it's required, and what to do if you don't have it yet. Budget time for these
upfront: the automated rebuild itself takes 30 minutes, but the environmental
setup can take a few hours if you're starting from scratch.

### A VLAN-capable network

**What it is:** VLANs let one physical network carry multiple isolated virtual
networks. Mycofu uses three: management (for Proxmox cluster traffic and
workstation access), prod (for production VMs), and dev (for development VMs).
Your gateway router and any managed switch connecting the Proxmox nodes must
support VLANs.

**Why it's required:** The dev/prod separation that Mycofu provides is enforced
by the network — dev and prod VMs are physically isolated, not just configured
differently. Without VLANs, you don't have a dev/prod boundary; you have a
naming convention. That's the problem Mycofu is designed to solve. The
management VLAN is equally essential: it carries Proxmox cluster heartbeats,
OpenTofu API calls, and NAS access — all on a network that is separate from
your application traffic.

**What "VLAN-capable" means in practice:**
- Your router/gateway can create VLANs with separate subnets and firewall rules.
  UniFi, pfSense, OPNsense, and most prosumer/SMB routers support this. Consumer
  routers (most ISP-provided devices) generally do not.
- Any switch between the router and the Proxmox nodes must support "VLAN trunking"
  — carrying multiple tagged VLANs on the same cable. Unmanaged switches (with
  no web UI) cannot do this. Most managed switches sold for home lab use can.

**If you don't have this:** A UniFi Express (~$80) or UniFi Cloud Gateway Ultra
(~$130) paired with any managed switch works well and is the Tier 1 tested
platform. pfSense or OPNsense running on a spare PC is a free alternative if
you have the hardware.

**Time to set up:** 30–60 minutes once you have the hardware.

---

### A registered domain name

**What it is:** A domain name you own and control — something like
`myhome.net` or `smithfamily.io`. You register these through a domain
registrar (Cloudflare, Namecheap, IONOS, etc.) for $10–$15/year.

**Why it's required:** Mycofu uses real TLS certificates from Let's Encrypt
for every service. Let's Encrypt requires you to prove you own the domain by
creating DNS records — this is the DNS-01 challenge. Without a real domain,
you can't get real certificates. Without real certificates, the chain of trust
that connects VMs to Vault doesn't work.

**A few things worth knowing:**
- The domain does not need a public-facing website. You can use it
  entirely for internal cluster services while keeping your home network
  private. The only public exposure is DNS port 53 (UDP+TCP) forwarded
  to your prod DNS VM — no HTTP/HTTPS ports need to be open.
- You only delegate a subdomain (`prod.yourdomain.com`), not the entire
  domain. Your registrar keeps control of email records (MX, SPF, DMARC).
- DNS delegation propagates through the internet's DNS system, which can
  take up to 48 hours. In practice it's usually under an hour, but plan
  for this before running `rebuild-cluster.sh` for the first time.
- The `acme: internal` mode in config.yaml lets you use a self-signed CA
  for early testing — certificates won't be trusted by browsers, but the
  full chain of trust works internally. Switch to `acme: production` when
  you're ready for real certificates. This avoids Let's Encrypt rate limits
  (50 certs per domain per week) during initial bringup.

**If you don't have this:** Register a domain with Cloudflare Registrar
(at-cost pricing, no markup) or any other registrar. Cloudflare DNS hosting
is free and has native certbot support for the DNS-01 challenge.

**Time to set up:** 10 minutes to register. DNS delegation propagation takes
up to 48 hours (plan for this, even if it resolves faster in practice).

---

### Port 53 forwarding from your public IP

**What it is:** Your home router forwards incoming DNS queries (UDP and TCP,
port 53) from the internet to your prod DNS VM on port 8053.

**Why it's required:** Let's Encrypt validates your domain ownership by querying
your DNS servers over the public internet. Your PowerDNS VM needs to be reachable
from Let's Encrypt's validators to complete the DNS-01 challenge and issue
certificates.

**What this means in practice:** You need a static or stable public IP, or a
dynamic DNS service if your ISP assigns a changing IP. The port forward is a
single rule in your router: WAN port 53 → prod dns1 IP port 8053. No other
ports need to be open.

**If your ISP blocks port 53:** Some ISPs block inbound port 53. If yours does,
the `acme: internal` mode lets you start without a public DNS setup — you can
add it later when you're ready for production certificates.

**Time to set up:** 5 minutes (one firewall rule) once your router supports it.

---

### An off-cluster NAS

**What it is:** A separate storage device — a NAS appliance (Synology, TrueNAS)
or a Linux machine with drives — that lives outside your Proxmox cluster. It
needs to run two services: PostgreSQL (for OpenTofu state) and NFS (for PBS
backup storage).

**Why it's required:** OpenTofu state must survive a cluster failure — if it
lived on the cluster, you'd lose the ability to rebuild the cluster from state
when the cluster is down, which is precisely when you need it. PBS backup data
must be off-cluster for the same reason: a backup stored on the same machines
it backs up doesn't survive catastrophic failure.

**What "off-cluster" means:** Any machine that is not a Proxmox node. A spare
PC, an old laptop, a Raspberry Pi 4 with USB storage, or a NAS appliance all
work. The machine should be reliable and always-on, since backup jobs run
nightly.

**Minimum requirements:**
- PostgreSQL 14+ (most platforms have a package or Docker image)
- NFS server with a shared folder exported with `no_root_squash`
- Docker (for the sentinel monitoring container)
- Accessible from your management subnet

**If you have a Synology NAS:** PostgreSQL is available via the Package Center.
The bringup checklist covers the exact configuration steps for DSM.

**If you don't have a NAS:** A Linux machine (Ubuntu, Debian, NixOS) with
PostgreSQL, NFS, and Docker installed works identically. This is a good use for
a spare PC. The bringup checklist covers this path too.

**Time to set up:** 30–90 minutes, depending on whether PostgreSQL and NFS are
already installed on your platform.

---

### Summary: what to have ready before running rebuild-cluster.sh

| Prerequisite | Required? | Can defer? |
|---|---|---|
| VLAN-capable gateway and switch | Yes | No — the dev/prod boundary depends on it |
| Registered domain name | Yes | No — needed for TLS certificates |
| DNS delegation configured at registrar | Yes | Can use `acme: internal` mode initially, switch later |
| Port 53 forwarding on your router | Yes | Can use `acme: internal` mode initially, switch later |
| Off-cluster NAS with PostgreSQL + NFS | Yes | No — OpenTofu state and backups must be off-cluster |
| Proxmox installed on all nodes | Yes | No — the rebuild script starts from bare Proxmox |

The "Can defer" column is honest: `acme: internal` mode lets you build the
cluster and test everything internally without public DNS or port forwarding.
When you're ready for production certificates, switch to `acme: production`,
set up DNS delegation, and re-run `rebuild-cluster.sh`. Everything else
rebuilds from the same configuration.

The bringup generator (Step 4) produces a step-by-step checklist tailored
to your specific hardware for each of these items. Run it after filling in
`site/config.yaml` to get concrete instructions with your actual IPs,
VLAN IDs, and platform-specific UI steps.

---

## Step 1: Install Workstation Tools

The following tools must be available in `$PATH` on your workstation:

| Tool | Purpose | macOS install |
|------|---------|---------------|
| `nix` | NixOS image builds | `curl -L https://nixos.org/nix/install \| sh` |
| `sops` | Decrypt bootstrap secrets | `nix-env -i sops` or `brew install sops` |
| `age` | SOPS encryption backend | `nix-env -i age` or `brew install age` |
| `yq` | Parse config.yaml | `brew install yq` |
| `jq` | JSON processing | `brew install jq` |
| `sshpass` | SSH key bootstrap on fresh Proxmox nodes | `brew install sshpass` |
| `tofu` | OpenTofu IaC | `brew install opentofu` |
| `git` | Version control | Pre-installed on macOS |

On Linux with Nix installed, most of these are available via `nix-env` or
your distribution's package manager.

---

## Step 2: Clone and Generate Config

```bash
git clone <public-repo-url> mycofu
cd mycofu
```

Run the site generator:

```bash
framework/scripts/new-site.sh
```

This creates the `site/` directory from `framework/templates/`,
including:

- `site/config.yaml` — cluster topology and framework VM configuration
- `site/applications.yaml` — application VM specifications (initially empty;
  populated by `enable-app.sh` or written directly by the operator)
- `site/nix/hosts/*.nix` — NixOS host configs for each VM role
- `site/tofu/` — OpenTofu root module that instantiates framework modules
- `site/apps/` — application configuration files
- `site/dns/zones/` — extra DNS records (MX, TXT, etc.)
- `site/images.yaml` — site-specific VM roles (for adding your own applications)

These are your files. `new-site.sh` gives you a starting point — correct
defaults, pre-generated MACs and IPs, inline documentation. The framework
reads from these files directly; you are welcome to edit any of them at any
time without running a generator first. If you understand the format, you
can write entries by hand and they work identically.

The `config.yaml` has all auto-generatable fields pre-filled:

- **VM MAC addresses** — random locally-administered MACs (`02:xx` format),
  one per VM per environment
- **VM IPs** — pre-allocated using fixed offsets within each subnet (DNS at
  `.50`/`.51`, Vault at `.52`, Pebble at `.53`, PBS at `.60`, CI/CD at `.61`,
  Gatus at `.62`, HAOS at `.63`)
- **Sensible defaults** for all optional fields
- **`# REQUIRED:`** markers on every field you need to fill in

The script never modifies files that already exist — re-running it is always
safe. If `site/config.yaml` is present, the script exits with a warning and
touches nothing.

**Templates:** The source templates live in `framework/templates/`. If you
want to understand what `new-site.sh` generates, examine
`framework/templates/config.yaml.example` — it contains every field with
documentation comments explaining the purpose, allowed values, and defaults.

---

## Step 3: Fill In Your Config

Open `site/config.yaml` and fill in the fields marked `# REQUIRED:`. These
are the values that only you can provide — everything else is auto-generated
or has sensible defaults.

| What to fill in | Where to find it |
|-----------------|-----------------|
| **Domain** | Your registered domain name |
| **VLAN IDs and subnets** | Your network plan (must not conflict with existing LAN) |
| **Management subnet and gateway** | Your existing LAN (e.g., `192.168.1.0/24`, `192.168.1.1`) |
| **Node hostnames and management IPs** | You'll set these during Proxmox install |
| **Node RAM** | Your hardware spec |
| **NAS IP** | Your NAS's current LAN address |
| **Public IP** | Your home's public IP (for DNS delegation) |
| **SMTP settings** | Your email provider's relay (e.g., `smtp-relay.gmail.com:587`) |
| **Operator SSH public key** | Your workstation's `~/.ssh/id_*.pub` (paste the content) |

**Things you do NOT fill in** (they're auto-generated):

- VM MAC addresses (pre-generated by `new-site.sh`)
- VM IPs (pre-allocated by `new-site.sh`)
- PowerDNS API key (generated by `bootstrap-sops.sh`)
- Age keypair (generated by `bootstrap-sops.sh`)
- CI/CD SSH keypair (generated by `bootstrap-sops.sh` — separate from your workstation key)

**Adjust pre-allocated VM IPs** if they conflict with existing devices on your
subnets. The offsets are conventions, not requirements.

**Tip:** If you're doing your initial setup and expect to rebuild several times,
set `acme: staging` in config.yaml. This uses Let's Encrypt's staging server
(untrusted certs, but 30,000/week rate limit instead of 50/week). Switch to
`acme: production` when you're ready to go live. See architecture.md section 8.5
for all three ACME modes.

**Tip:** Set `timezone` in config.yaml to your IANA timezone (e.g.,
`America/Los_Angeles`). This is used by PBS, NixOS VMs, and log timestamps.
When installing Proxmox on the nodes, select the same timezone so everything
is consistent.

**Tip:** If your gateway provides NTP (most routers do), you don't need to set
`ntp_server` — it defaults to the management gateway IP. If you have a dedicated
NTP appliance, set `ntp_server` to its IP.

---

## Step 4: Physical Setup

These steps are manual and hardware-specific. The order matters — the
management network must work before anything else.

### 4a. Hardware

- Install RAM and NVMe drives in each node (two NVMe drives per node — one
  for the Proxmox boot drive, one for the ZFS data pool)
- Connect all nodes to the managed switch via Ethernet
- If using a dedicated replication network: cable point-to-point links between
  each pair of nodes (for 3 nodes: 3 DAC cables)

### 4b. Gateway and Switch

Configure your gateway appliance:

1. **Create VLANs** — one for prod, one for dev, with the IDs and subnets
   from your config.yaml
2. **Optionally configure DHCP** on each VLAN for non-Mycofu devices
   (laptops, phones, IoT). Mycofu VMs use static addressing from
   config.yaml — no DHCP reservations needed. If you enable DHCP, ensure
   the range doesn't overlap with the Mycofu static range (e.g., Mycofu
   uses .50–.99, DHCP hands out .100–.254).
3. **Configure switch trunk ports** — ports connected to Proxmox nodes carry
   the management VLAN (untagged) and both environment VLANs (tagged)
4. **Block inter-VLAN routing** by default. No exceptions are needed.
5. **Forward port 53** (UDP+TCP) from your public IP to the prod dns1 VM's IP
   on port 8053

**For detailed, platform-specific instructions:** Run the bringup generator
after filling in config.yaml:

```bash
framework/bringup/generate-bringup.sh
```

This produces `site/bringup.md` — a site-specific checklist with concrete
UI instructions for your exact gateway, switch, NAS, and registrar
(derived from the `platforms` section of config.yaml). It includes
per-node IP tables, VLAN verification steps, and firewall zone
configuration specific to your hardware. The bringup checklist is the
detailed companion to this high-level guide.

### 4c. NAS

Configure your NAS for two roles:

**PostgreSQL** (OpenTofu state storage):
- Enable or install PostgreSQL (Synology: built-in; TrueNAS: plugin or Docker)
- Create a user `tofu` and database `tofu_state`
- Configure `pg_hba.conf` to accept connections from the management subnet
- Record the password — you'll enter it during `bootstrap-sops.sh`

**NFS** (PBS backup storage):
- Create a shared folder for PBS backup data
- Export it via NFS, accessible from the management subnet
- **Critical: set the NFS squash to "No mapping"** (Synology DSM label).
  This produces `no_root_squash` in the NFS export, which PBS requires.
  The Synology label "Map all users to admin" sounds correct but actually
  produces `all_squash`, which breaks PBS — every user is mapped to
  `nobody` and can't write to the datastore.
- Don't worry about POSIX permissions — Synology creates new shared
  folders with mode 000 and ACLs, but `rebuild-cluster.sh` detects and
  fixes this automatically.

**Docker** (sentinel monitoring):
- Verify Docker is available (Synology: Container Manager; TrueNAS: Docker or jail)
- Don't configure anything yet — the rebuild script deploys the sentinel later

**Verify NAS setup** (optional but recommended):

```bash
framework/scripts/verify-nas-prereqs.sh
```

This checks all NAS prerequisites (PostgreSQL, NFS export, permissions,
Docker) and reports pass/fail with specific remediation for any failures.
`rebuild-cluster.sh` runs this automatically at the start, but you can
run it early to catch problems before the rebuild.

### 4d. DNS Registrar

At your domain registrar:

1. Create A records for `dns1.<your-domain>` and `dns2.<your-domain>` pointing
   to your public IP
2. Add NS records delegating `prod.<your-domain>` to `dns1.<your-domain>` and
   `dns2.<your-domain>`
3. Do NOT change NS records for the base domain — the registrar stays
   authoritative for email (MX, SPF, DMARC)

### 4e. Proxmox Installation

Install Proxmox VE on each node from the ISO:

1. Boot from USB with the Proxmox installer
2. Install to the boot NVMe drive
3. Set the management IP from your config.yaml
4. Set the hostname from your config.yaml
5. Set a root password — remember this, you'll enter it during `bootstrap-sops.sh`
6. NIC pinning during install is **optional** — `configure-node-network.sh`
   auto-discovers the cabling topology and pins interfaces correctly regardless

Verify each node is reachable from your workstation:

```bash
ssh root@<node-ip> "hostname; uptime"
```

---

## Step 5: Generate Secrets

```bash
framework/scripts/bootstrap-sops.sh
```

This interactive script:

1. Generates a fresh `age` keypair (your encryption root)
2. Prompts for the **Proxmox root password** (the one you set during install)
3. Prompts for the **PostgreSQL password** (the one you set on the NAS)
4. Auto-generates all other secrets (PowerDNS API key, SSH keypair, etc.)
5. Produces `site/sops/secrets.yaml` encrypted with your age key

**Back up your age key immediately.** It is stored at `operator.age.key`
in the repo root. This is the one secret that cannot be regenerated — it
is the encryption root for all other secrets. Store a copy somewhere safe
(password manager, offline USB, printed QR code). Do not commit it to git
(it is in `.gitignore`).

Commit the site configuration and encrypted secrets:

```bash
git add site/
git commit -m "initial site configuration"
```

**This commit is required before the rebuild.** The Nix flake uses the
git tree as its source — `site/nix/hosts/*.nix` and `site/apps/*` must
be git-tracked or they will be invisible to the image builder.

---

## Step 5b: Start the Nix Builder (macOS only)

If your workstation is macOS, you need a Linux builder VM for cross-compiling
NixOS images:

```bash
framework/scripts/setup-nix-builder.sh --start
```

This downloads and starts a lightweight Linux VM that Nix uses for
`x86_64-linux` builds. The VM runs in the background and persists
across rebuilds. On Linux workstations, this step is not needed.

---

## Step 6: Build and Deploy

```bash
framework/scripts/rebuild-cluster.sh
```

One command. No interaction. This runs the full bootstrap sequence:

0. Verify prerequisites (workstation tools, node reachability, NAS setup)
1. Configure node networking (auto-discovers NICs, pins interfaces, deploys
   bridge/replication config — reboots nodes if naming changes are needed)
2. Configure node storage (creates ZFS data pool on each node's data NVMe)
3. Form the Proxmox cluster
4. Configure storage snippets
5. Build all VM images (NixOS, content-addressed)
7. Deploy all VMs via OpenTofu
7.5. Install and configure PBS (backup server, connects to NAS NFS)
7.6. Restore from PBS backups (if any exist — skipped on first run)
8. Load DNS zones
9. Acquire TLS certificates (Let's Encrypt for prod, Pebble for dev)
10. Initialize and unseal Vault
11. Configure Vault policies
12. Set up ZFS replication
13. Configure GitLab (push repo, create branches, protect `prod`)
14. Register CI/CD runner
15. Deploy sentinel Gatus on NAS, configure backup jobs, set up metrics
16. Run validation suite (51 checks)
17. Verify CI/CD pipeline
18. Take immediate backups of all VMs with precious state

**If the script fails at any step:** Note the error, fix the underlying issue,
and re-run. The script is idempotent — it detects completed steps and skips
them.

**Expected duration:** ~30 minutes. First-time builds are slower because
the Nix store must download the full NixOS closure (~6 GB for the GitLab
image alone). Subsequent rebuilds reuse the Nix cache and complete faster.

---

## Step 7: Verify

The rebuild runs validation automatically (step 16: 51 checks). If you
want to re-run it independently:

```bash
framework/scripts/validate.sh
```

**Note:** Gatus needs ~13 minutes after a fresh rebuild to complete its
health check cycle. If the Gatus endpoint check fails, wait and re-run.

All checks should pass. You now have:

- **DNS** — per-environment PowerDNS servers, serving zones derived from
  config.yaml
- **TLS** — automatic certificates via Let's Encrypt (prod) and Pebble (dev)
- **Vault** — initialized, unsealed, policies loaded, auto-unseal on restart
- **PBS** — backing up VMs with precious state to the NAS
- **GitLab** — self-hosted, repo pushed, CI/CD pipeline operational
- **Gatus** — monitoring all services, alerting via email
- **Sentinel** — monitoring Gatus itself from the NAS (outside the cluster)
- **Testapp** — running in both environments, proving the full chain of trust

Open the Gatus dashboard at `http://<gatus-ip>:8080` to see the health of
every service.

---

## Step 8: Verify CI/CD Pipeline

Step 12 of the rebuild (`configure-gitlab.sh`) already set up everything
needed for the CI/CD pipeline:

- Created the GitLab project
- Added the `gitlab` remote to your local repo
- Pushed the repo with `dev` and `prod` branches
- Protected the `prod` branch (MR-only)
- Configured the CI/CD pipeline

Verify the pipeline is working:

```bash
# The rebuild already pushed — check if the pipeline ran
# Open GitLab UI at https://gitlab.<env>.<your-domain>
# Navigate to CI/CD → Pipelines — you should see a completed run

# Or trigger a fresh pipeline by pushing a trivial change
git checkout dev
git commit --allow-empty -m "test pipeline"
git push gitlab dev
# Watch the pipeline: build → upload → deploy → validate
```

If you plan to publish the framework on GitHub:

```bash
git remote add github <your-github-url>
# Use sync-to-main.sh to push framework-only code to the public repo
```

---

## What's Next

Your cluster is operational. From here:

- **Add applications** — use `enable-app.sh` to add catalog applications
  (InfluxDB, Grafana, Roon, etc.):

  ```bash
  framework/scripts/enable-app.sh influxdb
  ```

  This allocates VMIDs, IPs, and MACs; writes a complete entry to
  `site/applications.yaml`; and generates NixOS host configs and application
  config stubs in `site/apps/<app>/`. Review the generated entry in
  `site/applications.yaml` and adjust any values. **Then edit the config
  files before building** — generated files contain `CHANGEME` placeholders
  for values only you can provide (organization name, bucket name, admin
  password, etc.). The build will fail with an assertion error if any
  `CHANGEME` values remain.

  After reviewing and editing, commit and push through the pipeline:

  ```bash
  git add site/
  git commit -m "enable influxdb"
  git push gitlab dev
  ```

  Each catalog application has a README at `framework/catalog/<app>/README.md`
  explaining what the config values mean and what to set them to.
- **Push changes via the pipeline** — `git push gitlab dev` deploys to dev;
  merge to `prod` deploys to prod
- **Review the operational cadence** — [OPERATIONS.md](OPERATIONS.md) covers
  maintenance schedules, troubleshooting, and break-glass procedures
- **Understand the architecture** — [architecture.md](architecture.md)
  explains every design decision when you want to know why things work the
  way they do
- **Regenerate the bringup checklist** — if you change hardware or network
  config, run `framework/bringup/generate-bringup.sh` to produce an updated
  site-specific setup checklist at `site/bringup.md`

---

## Hardware Requirements

### Minimum

| Component | Requirement |
|-----------|-------------|
| Nodes | 2 (HA requires 3 for quorum, but 2 works with limitations) |
| NVMe per node | 2 (one boot, one data pool) |
| RAM per node | 16 GB minimum (32 GB recommended) |
| Network | 1 GbE management + VLAN-capable switch |
| NAS | PostgreSQL + NFS capable |
| Gateway | VLAN-capable, routing, firewall |

### Recommended (3-Node HA)

| Component | Recommendation |
|-----------|---------------|
| Nodes | 3 (full HA with N+1 capacity) |
| NVMe per node | 2 (boot + data) |
| RAM per node | 32 GB (96 GB total, ~64 GB usable with N+1 reserve) |
| Management network | 1 GbE switched |
| Replication network | 25 GbE point-to-point mesh (DAC cables) |
| NAS | Synology or TrueNAS with RAID, PostgreSQL, NFS, Docker |
| Gateway | UniFi, pfSense, or OPNsense |

The replication network is optional but strongly recommended — it separates
high-bandwidth ZFS replication traffic from the management network and
provides fault isolation for corosync.

---

## Troubleshooting First-Time Setup

**`new-site.sh` fails:**
- Ensure you're in the repo root directory
- Check that `framework/templates/config.yaml.example` exists

**`bootstrap-sops.sh` fails:**
- Ensure `sops` and `age` are installed
- The script creates the age key directory if it doesn't exist

**Nodes unreachable after Proxmox install:**
- Verify the management IP was set correctly during install
- Check that the switch port is in the correct VLAN (native/untagged)
- Try pinging the node from the workstation

**`rebuild-cluster.sh` fails at NIC discovery:**
- Check that all DAC cables are connected (the script probes point-to-point
  links and reports which pairs failed)
- If a node has no replication NICs, ensure config.yaml doesn't declare
  replication peers for it

**`rebuild-cluster.sh` fails at image build:**
- First build downloads the full NixOS closure — ensure internet connectivity
- On macOS: ensure the nix linux-builder is running
  (`framework/scripts/setup-nix-builder.sh --start`)
- Check disk space (the nix store can be large)

**`rebuild-cluster.sh` fails at certificate issuance:**
- Verify DNS delegation is configured at your registrar
- Verify port 53 forwarding from your public IP to the prod dns1 VM on port
  8053
- Check Let's Encrypt rate limits (50 certs per domain per week)
- For dev: check that the Pebble VM is running

**`validate.sh` reports failures:**
- Read the specific check that failed — each check names the component
  and expected state
- Common first-time issues: search domain not configured in CIDATA (VMs
  can't resolve `vault`), firewall blocking inter-VLAN to management
  traffic that Proxmox needs, incorrect IP in config.yaml

**`rebuild-cluster.sh` fails at NAS prerequisites (step 0):**
- Run `framework/scripts/verify-nas-prereqs.sh` independently — it
  reports pass/fail with specific remediation for each check
- Common issues: NFS squash set to "Map all users to admin" instead of
  "No mapping" (Synology DSM), PostgreSQL not accepting connections from
  the management subnet, Docker not installed
- The script auto-fixes Synology's default mode 000 permissions — if
  you see "mode 000 auto-fixed" in the output, that's normal

**`rebuild-cluster.sh` fails at image build with "does not exist" errors:**
- Ensure you ran `git add site/ && git commit` before the rebuild. The
  Nix flake uses the git tree as its source — untracked files in `site/`
  are invisible to the builder. This is the most common first-time mistake.

**Image build fails with "Failed assertions" and "contains placeholder values":**
- An application config file in `site/apps/<app>/` still has `CHANGEME`
  placeholders. Edit the file, replace all `CHANGEME` values with your
  actual configuration, commit, and re-run. Check all enabled app config
  files before re-running — the build stops at the first assertion, so
  there may be more in other apps.

**Backups fail at step 18:**
- Check that the NFS export is accessible from the PBS VM
- Verify the NFS squash setting is "No mapping" (`no_root_squash`) — PBS
  runs backups as the `backup` user (uid 34), which is blocked by
  `all_squash`
- The rebuild shows the full vzdump error output — read it for specifics
