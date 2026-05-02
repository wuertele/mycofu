# Mycofu Architecture

## 1. Purpose and Audience

This document describes the architectural intent of Mycofu. It explains why specific design choices were made and how those choices support long-term goals such as rebuildability, safety, and clarity.

**Audience:**
- Architects and senior developers extending or evaluating the system
- Anyone making foundational changes (networking, identity, secrets, deployment)

The companion **[README.md](README.md)** introduces the project — what it does, who it's for, and what's inside. **[GETTING-STARTED.md](GETTING-STARTED.md)** walks a new operator from a fresh clone to a running cluster. **[OPERATIONS.md](OPERATIONS.md)** covers day-to-day operation: adding VMs, deploying changes, troubleshooting, maintenance, and break-glass procedures.

---

## 2. Design Goals (Why This Exists)

These goals are ordered by foundational importance: the first goals are
the principles from which the later goals derive. Violating an earlier
goal makes the later goals unreliable.

1. **Convergence, not just rebuildability**

   The system must reach correct operational state from any valid starting
   point within its state space, not just from a clean slate. A rebuild
   script that works from bare metal but fails after a partial deployment,
   a botched restore, a provider bug that left orphaned state, or a manual
   intervention that created inconsistency is a rail, not a solution.

   The valid starting states include every degraded state that operational
   reality can produce: mid-deploy failures where some VMs were recreated
   and others weren't, PBS restores that overwrote newer data with older
   backups, provider bugs that left tofu state diverged from Proxmox
   reality, rate limit exhaustion that left a VM without a TLS certificate,
   and manual fixes that created dependencies not captured in the repo.

   The metaphor is water in a watershed: a water molecule anywhere in the
   basin eventually reaches the delta. You don't prove the watershed works
   by dropping water at one point — you prove it by demonstrating
   convergence from every point in the region bounded by the rim. DFMEA
   identifies the rim (the boundary of plausible starting states); testing
   probes points throughout the region.

   Rebuildability (goal 4) is the specific mechanism: any component can
   be destroyed and recreated deterministically. Convergence is the
   stronger claim: the system reaches correct state regardless of which
   components were destroyed, in what order, and what partial state they
   left behind.

2. **Single-pass convergence is the quality metric**

   The rebuild must reach correct operational state on one execution,
   without manual intervention, from any starting state within the valid
   state space. This is how convergence is measured.

   A single successful rebuild proves nothing — it proves that particular
   run didn't hit any of the hidden assumptions, timing dependencies, or
   undocumented state that would have caused it to fail. Longitudinal
   success across diverse starting states demonstrates control.

   A failure on any attempt, from any starting state, is diagnostic: it
   identifies a dependency not captured in the repo, a state transition
   not handled by automation, or an assumption that doesn't hold under
   degradation. Each fix that eliminates a failure mode strengthens
   convergence. Each manual workaround hides the gap and produces new
   untested starting states.

   The temptation to re-run a failed rebuild is the trap: success on a
   second attempt hides a non-determinism or ordering dependency that
   will surface again under different conditions. If the process is truly
   idempotent, one pass is sufficient. If one pass isn't sufficient, the
   process has a defect — the second-pass success is not a fix, it is
   evidence of the defect.

   This metric subsumes other quality measures. If rebuilds consistently
   converge from diverse starting states, the system is under control.
   If they don't, the failures tell you exactly what isn't under control
   yet.

3. **Rebuild failures are diagnostic, not operational**

   When a rebuild fails, the correct response is a structural fix that
   eliminates the failure mode — not a manual workaround that restores
   service while leaving the gap open.

   A manual workaround (SSH into the VM and fix it, manually manipulate
   tofu state, place a self-signed certificate) restores the system to
   working state but degrades the framework's convergence: the workaround
   is a dependency not in the repo, the workaround may create a new
   starting state that hasn't been tested, and the convergence gap is
   hidden rather than fixed.

   This is the Andon principle from the Toyota Production System applied
   to infrastructure automation: stopping the line to investigate and fix
   a quality problem is expensive in the moment but less expensive than
   allowing the defect to propagate. In software infrastructure, the
   temptation is stronger because an engineer who can SSH in and fix
   anything feels productive — they are actually degrading the system's
   convergence by adding hidden dependencies.

   The Mycofu operational rules (no manual fixes, configuration is
   software, automation output is operator instruction) are all
   expressions of this principle: they force the line to stop when
   something can't be automated, rather than allowing a manual workaround
   that hides the gap.

   **The exception:** A manual intervention is acceptable during an active
   incident if the structural fix cannot be deployed immediately (e.g.,
   the pipeline is down, or the fix requires a code change that must go
   through CI). In this case, the manual fix is explicitly temporary, and
   a structural fix is filed as a blocking issue before the incident is
   closed. The incident is not resolved until the structural fix is
   deployed and the manual intervention is no longer needed.

4. **Configuration is software**
   - Configuration is committed to the same repository as the framework code and versioned together
   - A configuration change is a git commit that triggers the same CI/CD pipeline as a code change
   - The git commit that built a VM image fully determines both the software and its configuration — there is no separate configuration state
   - This eliminates the class of failures where "the software was tested but the configuration was different" — when you test a commit, you test everything
   - The only state not captured by the git commit is runtime data (Category 3: database contents, Vault leases, application state), which is explicitly classified as precious state and handled by the backup system
   - This goal is what makes convergence (goal 1) achievable: if all dependencies are captured in code, then a rebuild from code should produce a correct system. A rebuild failure is a falsification of this claim and must be investigated as such.

5. **Rebuildability over repair**
   - Any VM or service can be destroyed and recreated deterministically
   - Infrastructure is code, not state
   - **Full-rebuild target:** After physically assembling hardware and installing
     Proxmox on each node's boot drive, the operator provides their SOPS age private
     key and runs `framework/scripts/rebuild-cluster.sh`. Everything else —
     OpenTofu state initialization, VM image builds, VM deployment, DNS, certificate
     issuance, Vault initialization and unseal, policy loading, and service
     verification — is automated. No other manual steps required.
   - **Two-path deployment model:** The pipeline deploys existing declared state,
     but it does not write SOPS. When a newly enabled catalog app needs fresh
     Vault AppRole bootstrap credentials, the operator first runs
     `framework/scripts/rebuild-cluster.sh --scope onboard-app=<name>` from the
     workstation. That writes the new SOPS entries and commits them locally.
     After that commit is pushed, the pipeline can deploy the app like any
     already-onboarded service.
   - The age private key is the only secret that cannot be stored in the repository.
     It is the encryption root — by definition it cannot be encrypted with itself.
     All other secrets are either encrypted in `site/sops/secrets.yaml` and
     unlockable with the age key, or generated fresh during rebuild and immediately
     encrypted and committed.

6. **Minimal hidden state**
   - Durable intent lives in Git or in narrowly scoped external systems
   - No "click-ops" or undocumented manual changes
   - Hidden state is the enemy of convergence: a dependency that isn't in the repo is a starting condition the system can't converge from.

7. **DFMEA defines the test surface**

   You cannot test convergence from every possible starting state. Failure
   mode and effects analysis (DFMEA) identifies the degraded states most
   likely to occur in operation — the rim of the watershed. Each
   identified failure mode becomes a starting state from which convergence
   must be demonstrated.

   Expanding this set is how the framework's reliability grows. The DR
   test registry (`framework/dr-tests/DR-REGISTRY.md`) is the inventory
   of tested starting states. The issue backlog contains identified but
   untested failure modes. Passing a DR test is not proof of quality;
   consistently passing it across code changes, across operator errors,
   and across infrastructure failures is.

   Every rebuild failure that occurs in practice should produce
   two artifacts: a structural fix (goal 3) and a new DR test case that
   starts from the degraded state the failure revealed. The DR test
   prevents the same starting state from causing a future failure. Over
   time, the DR test suite converges toward comprehensive coverage of the
   state space that operational reality produces.

8. **Clear ownership boundaries**
   - Each layer of the stack has exactly one controlling authority
   - No ambiguity about what manages what

9. **Strong dev/prod separation**
   - Prevent accidental cross-environment access by construction, not convention
   - Environments isolated by network, DNS, and policies

10. **Unknowable state must fail, not pass**
    - When a safety check cannot determine whether the system is safe — because a prerequisite is missing, a tool failed, or the check itself errored — the check must fail, not pass silently.
    - A SKIP that hides an undetectable safety problem is equivalent to a false pass. It gives the operator false confidence and allows unsafe operations to proceed.
    - The correct default is FAIL with a message explaining why the check could not complete. The operator can investigate and decide to proceed manually. The automation must not make that decision for them by silently passing.
    - This principle applies to all safety checks: pipeline gates, validate.sh checks, pre-deploy guards, and backup verification. When in doubt, fail loudly.
    - **The exception:** A check may SKIP when the condition it is checking is genuinely not applicable in the current context — for example, a drift check that requires build artifacts may legitimately skip in a pre-build pipeline stage where artifacts have not yet been produced. The distinction is: SKIP when the check cannot run because it is not yet applicable; FAIL when the check cannot run because something went wrong.

11. **Automation output is operator instruction**
    - When a script or CI job prints "run this command," the operator will run it. Every command printed by automation must be safe to copy-paste. If a command is dangerous (e.g., destroys precious-state VMs), the automation must either not print it, or route the operator through a safe path that handles backup and restore automatically.
    - Scripts that detect a problem must suggest the safe remediation path, not the raw low-level operation. For example: a CI guard that detects control-plane image drift must direct the operator to `rebuild-cluster.sh --scope control-plane` (which handles backup pinning, stopped creation, preboot restore, start/register, and convergence), not to a raw `tofu apply -target=module.gitlab` (which destroys data silently).
    - The same duty of care applies to error messages, remediation instructions, and diagnostic output. If automation tells the operator to do something, it is responsible for the consequences of the operator doing it.

12. **Human-auditable configuration**
    - Infrastructure and secrets changes are reviewable and explainable
    - Git history shows what changed and why

13. **Reusable framework, site-specific configuration**
    - The architecture and tooling should be separable from any specific deployment
    - A new operator can clone the repository, provide their own site configuration (domain, IPs, hardware), and get a working platform
    - Site-specific details are isolated in a clearly identified configuration layer

14. **Files are the operator interface**
    - YAML files are the primary surface through which the operator communicates intent to the framework. Programs read from files and write to files; they do not replace files as the interface.
    - A well-structured YAML file with inline comments teaches the operator the system as they use it. A wizard collects values and hides the system from the operator. When the operator needs to change something, they go to the file — not to a program they ran once and forgot.
    - **Generators are helpers, not gatekeepers.** `new-site.sh`, `enable-app.sh`, and similar scripts produce a starting point. The operator is the authority on the files they generate. A generator that has never been run is not a blocker — the operator can write `site/config.yaml` or `site/applications.yaml` by hand, and the framework works identically. Generators exist to save the operator from knowing every field and derivation rule on day one. They are not part of the framework's execution path.
    - **Re-running a generator must be safe.** Generators write to new entries and never touch existing content. If an operator has edited a generated file and re-runs the generator for any reason, their edits must survive unchanged. This is a hard invariant, not an implementation detail. A generator that silently overwrites operator edits is a data-loss bug.
    - **The framework must never fail because a generator was not run.** If `enable-app.sh` was never run and the operator wrote an app entry directly in `applications.yaml`, every consumer must work correctly. The framework reads files; it does not care how those files were produced.
    - Generators write initial structure and own the accuracy of what they generate at generation time. Generated content becomes operator-maintained from the moment it is written. Comments belong at the point of action — adjacent to the values they constrain, not at the file header.

15. **Early binding of environment, late binding of role**
    - Environment is decided before first boot (determined by VLAN)
    - Service role is selected at boot (from cloud-init metadata)

16. **Stateless identity where possible**
    - TLS certificates generated on VM, not transported
    - VMs authenticate to Vault using TLS certs

17. **Configuration constraints are software**

    When two configuration values have a constraint relationship — one
    must fit within the capacity of another, one must precede another
    in time, one must match another in format — that relationship must
    be expressed as a derivation, not maintained as two independent
    values.

    If A must be less than or equal to B, A is a function of B. Changing
    B automatically changes A. The constraint is self-enforcing because
    there is only one authoritative value; the other is computed.

    This is a stronger form of Design Goal 4. Design Goal 4 says the
    commit determines the configuration. Design Goal 17 says the commit
    determines the *relationships between* configurations. A system
    where A=500M and B=256M are both committed is configured
    deterministically but not consistently. A system where A is derived
    from B cannot produce the A>B mismatch by construction.

    The journal overlay incident (2026-04-17) illustrated the failure
    mode. `SystemMaxUse=500M` was set when VMs had ext4 root filesystems
    where 500M was reasonable. Sprint 010 moved to overlay-root with a
    256M tmpfs. Both values were independently correct within their own
    layer. Neither value knew about the other. After 40 hours of log
    accumulation, the journal filled the overlay and GitLab became
    unreachable. The fix was to derive the journal limit from the
    overlay size: `SystemMaxUse = overlayMB / 4`. The constraint became
    self-enforcing.

    The pattern applies across layers:

    - Within NixOS modules: journal size from overlay size, nginx log
      rotation from overlay size, redis maxmemory from VM RAM.
    - Across the OpenTofu/NixOS boundary: VM RAM is a tofu variable;
      NixOS resource limits that depend on RAM must receive the value
      through the config.yaml → NixOS pipeline, not be set independently.
    - Across the pipeline/runtime boundary: secrets available at build
      time vs runtime have different constraint relationships that must
      be encoded in the delivery mechanism, not in operator discipline.

    Convergence (Goal 1) handles configuration changes. It does not
    handle constraint violations between independently-converged values.
    A system can be fully converged to its commit and still be
    internally inconsistent. Goal 17 closes that gap by eliminating the
    possibility of independent values that must match.

    The practical implications:

    - **Build-time assertions.** Where NixOS modules can compute A from
      B at eval time, add `assertions` that fire at `nix build` when
      the constraint would be violated. The commit cannot produce a
      VM whose configuration is internally inconsistent.
    - **Cross-layer facts.** Values needed for derivations across the
      tofu/nix boundary must be exposed as facts, not duplicated as
      independent declarations.
    - **Runtime enforcement as a complement, not a substitute.** Some
      constraints are only knowable at runtime (actual log volumes,
      dataset sizes). These need runtime monitoring and automated
      response. But wherever a constraint can be enforced at build
      time, it should be — runtime enforcement is more expensive and
      less reliable than making the constraint violation impossible to
      commit.
    - **Documentation is not enough.** "Remember to update A when you
      change B" is a latent bug. If the relationship is important enough
      to document, it is important enough to derive. The journal limit
      was documented; the documentation didn't prevent the incident.

18. **The convergence mechanism handles all transitions in the desired state**

    When the desired-state representation evolves to require new derived
    state in the cluster — a new persistent dependency, a new schema for
    existing state, a new resource that other resources presuppose — the
    convergence mechanism must contain the logic to produce that derived
    state from any prior valid cluster state. A transition that requires
    a manual step to complete breaks Goal 1: some prior valid cluster
    states become unreachable through the normal convergence path.

    Convergence is a property of the convergence mechanism, not of the
    desired-state representation. A change that requires the operator to
    perform additional steps the convergence mechanism doesn't know about
    is incomplete — the additional steps are part of the
    desired-state-to-cluster transformation and must be embedded
    accordingly. "The change works once the operator runs the backfill"
    describes an incomplete change.

19. **All convergence paths produce equivalent end states**

    The system may admit multiple convergence mechanisms — typically one
    driven by ongoing changes to the desired-state representation, and
    one invoked by the operator for disaster recovery or initial cluster
    setup. All such mechanisms must produce equivalent cluster state from
    the same desired-state input.

    Divergence in capability between mechanisms means the cluster state
    becomes a function of which mechanism last ran rather than a function
    of the desired state alone, breaking the property that the desired
    state fully determines the cluster state. A change that is enacted by
    one convergence mechanism but not by others is incomplete by Goal 18,
    applied to each mechanism independently.

20. **No standing overrides for the system's correctness model**

    Mechanisms that exist to enforce the architecture's correctness model
    must not be paired with operator-facing overrides that bypass them.
    A flag like `--skip-reboot`, `--ignore-restore`, `--allow-empty-vdb`,
    or `--trust-me` for any mechanism whose purpose is to enforce a
    structural invariant is not an emergency tool; it is a standing
    weakening of the invariant.

    The reasoning is empirical, not aesthetic. An override added "for
    emergencies" or "in case we need it" has three predictable effects.
    First, every successful run without it is forgotten; every difficult
    moment becomes a reason to consider using it. The override accumulates
    use over time, not because the underlying mechanism is wrong but
    because the override is available. Second, the existence of the
    override means the mechanism never establishes the track record that
    would make the override obviously unnecessary — confidence in the
    mechanism remains conditional on the override's presence. Third, by
    the time the override would be removed, removing it feels like a
    regression: "we've been relying on this, are we sure we can do
    without it?"

    The pattern repeats across the project's history. The Sprint 027
    vdb readiness gate began as legitimate defense-in-depth and became
    the reason orchestration confidence couldn't grow; deleting it in
    Sprint 031 required explicit architectural commitment because the
    gate had become load-bearing in a way the architecture didn't
    sanction. Override flags on convergence-related operations have the
    same trajectory in compressed form.

    The principle: when a mechanism exists to enforce a structural
    invariant of the system, the only acceptable response to "what if
    we need to bypass this" is either (a) the invariant is genuinely
    unconditional and no bypass exists, or (b) the bypass is an explicit
    transition mechanism with a sunset condition and a successor
    mechanism that makes the bypass unnecessary. Standing overrides
    without a sunset are forbidden.

    This is distinct from Goal 3 (rebuild failures are diagnostic, not
    operational), which governs the response to a failure that has
    already occurred. Goal 20 governs the design choice before any
    failure: do not pre-build escape hatches that will become load-
    bearing through use. The two goals operate at different points in
    time but share an underlying commitment: the architecture's
    correctness must be earned through use, not protected from use by
    standing exceptions.

    **Distinguishing standing overrides from legitimate operator
    controls.** Not every operator-facing flag is a standing override.
    `--dry-run` flags surface intent without acting; they reinforce
    correctness rather than bypass it. Scope flags like
    `rebuild-cluster.sh --scope` constrain *what* the operation acts on
    without bypassing *how* it acts. Configuration flags that change
    parameters (a longer timeout, a different log level) operate within
    the correctness model rather than against it. Goal 20 specifically
    forbids flags whose effect is to suspend a structural invariant the
    operation otherwise enforces.

    **Distinguishing transition mechanisms from standing overrides.** An
    override flag with an explicit sunset condition and a successor
    mechanism is a transition tool, not a standing override. For example:
    a flag added because the underlying mechanism cannot yet handle a
    specific case, with a tracking issue for the mechanism's improvement
    and a commitment to remove the flag when that issue ships. Sunset
    conditions must be specific (an issue number, a release version,
    a successor mechanism), not aspirational ("when we're sure it
    works").

---

## 3. Non-Goals

- Managing switching or routing via OpenTofu (handled by gateway/switch appliance)
- Mutable configuration management (e.g., Ansible)
- Baking environment identity or secrets into VM images
- Cloud portability as a primary concern
- Running private PKI infrastructure for production (using Let's Encrypt for prod certificates; step-ca provides a local ACME server for dev only — see section 8.4)

---

## Glossary

These terms have specific meanings throughout this document.

**CIDATA:** The nocloud-init configuration payload delivered to a VM at creation time as a mounted ISO. Contains `user-data` (hostname, SSH keys, `write_files`) and `meta-data` (instance ID). Stored as snippet files on Proxmox `local` storage. CIDATA is a VM creation input — any change to its content triggers VM recreation via OpenTofu. See section 11.1.1.

**PBS (Proxmox Backup Server):** A Proxmox-native backup appliance running as a VM inside the cluster. Provides versioned, deduplicated, incremental-forever backups with retention policies. The PBS datastore is NFS-mounted from the NAS for off-cluster durability. See section 16.

**Category 1 (derivable):** Data that can be regenerated from Git sources. VM root disks (vda), NixOS configurations, container images. Never backed up — rebuilt on demand. See section 11.2.1.

**Category 2 (configuration):** Data that originates in Git but is pushed to a running service. DNS zone data, Vault policies, application config files. Not backed up via PBS — redeployed from Git. See section 11.2.1.

**Category 3 (precious state):** Data that is created at runtime and cannot be regenerated from Git. Database contents, Home Assistant entity registries, Vault leases. Backed up via PBS to NAS with verified recoverability — every `rebuild-cluster.sh` run confirms that backups contain real application state, not just filesystem metadata (see section 14.2, backup safety invariant). See section 11.2.1.

**Category 4 (VM-produced secrets safekept by Vault):** Secrets generated by a VM at runtime that must persist across VM recreation but are not application data. The defining characteristic is bidirectional flow: Vault delivers the secret to the VM on boot, and the VM writes the secret back to Vault after generating it. Examples: Tailscale node identity (generated at first tailnet join, restored from Vault on subsequent boots so the VM maintains a stable identity across rebuilds), and the live TLS certificate lineage for non-Vault certbot VMs (restored from Vault on boot when still valid, synced back to Vault after issuance or renewal). Unlike Category 3, these secrets are not backed up via PBS — they live exclusively in Vault. Unlike bootstrap-tier secrets, they are generated by the VM itself rather than pre-configured by the operator. The Vault VM's own `/etc/letsencrypt` lineage is the exception: it persists on Vault's vdb instead of being written back into Vault. See section 11.2.1.

**Bootstrap-tier secret:** A secret that must be available *before* Vault is reachable — because it's part of the chain that establishes Vault connectivity. Pre-deploy bootstrap secrets are stored in SOPS and delivered via CIDATA. Examples: PowerDNS API key (needed to get certificates), Proxmox API credentials. Note: Vault unseal keys are a special case — they are generated post-deploy by `init-vault.sh`, delivered via SSH to vdb, and backed up in SOPS. They are NOT in CIDATA (see section 11.1.1).

**Runtime-tier secret:** A secret that is accessed *after* a VM has authenticated to Vault. Stored in Vault. Examples: database passwords, API keys for application services.

**Environment-ignorant (VM):** A VM image that contains no environment-specific configuration — no environment names, FQDNs, IP addresses, or conditional logic. The same image boots on prod or dev and receives all environment-specific values at boot from CIDATA `write_files`: network configuration (IP, gateway, DNS servers, search domain) at `/run/secrets/network/`, and service configuration (ACME server URL, forward-zone domain, gateway IP for recursor, DNS zone data) at `/run/secrets/`. The search domain determines how unqualified hostnames like `vault` and `acme` resolve, which is the primary environment binding mechanism. The image is identical across environments; the boot-time inputs differ. See section 11.1.1 for the full contract.

**Precious state:** Synonym for Category 3 data. State that cannot be regenerated and must be protected by backups.

**Chain of trust:** The sequence of dependencies a VM traverses from first boot to fully operational: CIDATA (static network config) → DNS → ACME certificate → Vault authentication → runtime secrets → application start. Each link depends on the previous one. See section 13.2 and the chain of trust diagram.

**Anti-affinity:** A placement constraint requiring that two VMs run on different physical nodes. Used to ensure a single node failure doesn't eliminate both instances of a redundant service (e.g., dns1 and dns2).

**N+1 capacity:** A resource planning rule requiring that the cluster can absorb the loss of any one node without overcommitting. With N nodes, this means scheduling no more than (N-1) nodes' worth of total VM load.

**vda / vdb:** The two virtual disks attached to each VM. vda is the root/OS disk (Category 1, disposable, replaced on image update). vdb is the data disk (Category 2 and/or 3, persists across VM recreation, may contain precious state). See section 11.0 for the complete four-component VM model (vda, CIDATA, vdb, off-cluster storage) and their lifecycles across all operations.

**nixSrc:** The filtered source tree used as input to all NixOS image derivations. Created via `builtins.path` with a file filter in `flake.nix`. Contains only files that affect image builds — changes to other files (CI config, documentation, operational scripts) do not change image hashes. See section 11.1.2.

### Chain of Trust Diagram

The following shows the dependency chain a VM traverses from first boot to fully operational. Each step depends on all previous steps succeeding.

```
┌─────────────────────────────────────────────────────────────┐
│                     VM BOOT SEQUENCE                        │
│                                                             │
│  ┌──────────┐    ┌──────────┐    ┌───────────────────────┐  │
│  │  VLAN    │───▶│  CIDATA  │───▶│ IP address (static)   │  │
│  │(physical)│    │(config.  │    │ Search domain          │  │
│  │          │    │  yaml)   │    │ Gateway, DNS servers   │  │
│  └──────────┘    └──────────┘    └───────────┬───────────┘  │
│                                              │              │
│                                              ▼              │
│                                  ┌───────────────────────┐  │
│                                  │  DNS resolution       │  │
│                                  │  (via search domain)  │  │
│                                  │  "vault" → <vault IP>  │  │
│                                  │  "acme"  → <acme IP>   │  │
│                                  └───────────┬───────────┘  │
│                                              │              │
│                                              ▼              │
│                  ┌───────────────────────────────────────┐   │
│                  │  ACME certificate issuance            │   │
│                  │  certbot → PowerDNS API (SOPS key)    │   │
│                  │  → TXT record on dns1 + dns2          │   │
│                  │  → ACME server validates DNS-01       │   │
│                  │  → TLS certificate issued             │   │
│                  └──────────────────┬────────────────────┘   │
│                                     │                        │
│                                     ▼                        │
│                  ┌───────────────────────────────────────┐   │
│                  │  Vault authentication                 │   │
│                  │  VM presents TLS cert to Vault        │   │
│                  │  Vault validates cert (CA, CN/SAN)    │   │
│                  │  Vault issues token with role policy  │   │
│                  └──────────────────┬────────────────────┘   │
│                                     │                        │
│                                     ▼                        │
│                  ┌───────────────────────────────────────┐   │
│                  │  Runtime secrets retrieval            │   │
│                  │  vault-agent uses token               │   │
│                  │  Fetches DB passwords, API keys, etc. │   │
│                  │  Writes to /run/secrets/              │   │
│                  └──────────────────┬────────────────────┘   │
│                                     │                        │
│                                     ▼                        │
│                  ┌───────────────────────────────────────┐   │
│                  │  Application start                    │   │
│                  │  Service reads secrets from disk      │   │
│                  │  Connects to databases, APIs          │   │
│                  │  VM is fully operational              │   │
│                  └───────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

Bootstrap-tier secrets (SOPS):          Runtime-tier secrets (Vault):
  • PowerDNS API key ──────────┐          • Database passwords
  • Vault unseal keys          │          • API keys
  • Proxmox API creds          │          • Inter-service tokens
  • SSH public keys            │
                               │
            Used BEFORE Vault ─┘── Used AFTER Vault auth ──▶
```

**Key property:** Everything above the "Vault authentication" line uses only SOPS-tier secrets (baked into the image or injected via cloud-init). Everything below uses Vault-tier secrets (retrieved at runtime). This is the boundary between bootstrap and runtime.

---

## 4. Layered Architecture and Ownership

| Layer | Owner | Responsibility |
|-------|-------|----------------|
| Physical network | VLAN-capable gateway + switch | VLANs, routing, firewall |
| DHCP | Gateway | Addressing for non-Mycofu devices only (laptops, phones, IoT). Mycofu VMs use static addressing from config.yaml via CIDATA. |
| DNS | PowerDNS on NixOS VMs | Authoritative zones, ACME (Automatic Certificate Management Environment) DNS-01 |
| Certificates | Let's Encrypt (public CA) | TLS certificates via DNS-01 |
| VM lifecycle | OpenTofu | Create/destroy VMs, disk attachment |
| VM images | Nix build system | Offline image generation |
| OS & services | NixOS | Packages, services, convergence |
| Secrets (infrastructure) | SOPS/age | Encrypted bootstrap secrets in Git |
| Secrets (runtime) | Vault | Dynamic application secrets |
| OpenTofu state | PostgreSQL on off-cluster NAS | State storage + locking |

Crossing these boundaries is considered architectural drift.

### 4.1 Drift Prevention Strategy

Each component has an authoritative owner (the table above). The system is designed so that manual changes to managed components are either impossible, short-lived, or detectable.

| Component | Drift prevention mechanism |
|-----------|---------------------------|
| Proxmox VMs | OpenTofu is the only way to create/destroy VMs. Proxmox UI changes (manual VM creation, resource edits) are overwritten on next `tofu apply`. |
| NixOS configuration | VM images are immutable artifacts built from Git. To change a VM's config, you change Git and rebuild the image. There is no `ssh and edit` path that persists across image rebuilds. |
| DNS zones | PowerDNS web UI is disabled. Zone data is generated by OpenTofu from config.yaml and delivered via CIDATA. A systemd oneshot reconciles the database at every boot. Manual API changes are overwritten on next VM restart or redeploy. |
| Vault policies | Policies are synced from Git via CI/CD. Manual policy edits in Vault are overwritten on next sync. |
| Vault secrets | Runtime secrets in Vault are the one exception — they are created by Vault itself (dynamic credentials) or written by applications. These are Category 3 precious state, not managed by Git. |
| SOPS secrets | Changes require the operator's age key and a Git commit. No other path exists. |
| Proxmox HA/placement rules | Managed by OpenTofu. Manual changes in Proxmox UI are overwritten. |

**Residual drift risks:**
- Gateway/switch network configuration (VLANs, firewall rules, DHCP) is managed via the appliance's own UI, not OpenTofu. This is a declared non-goal (section 3). Changes should be documented manually.
- Proxmox host-level settings (apt repos, kernel parameters, ZFS pool config) are not managed by OpenTofu or Nix. A future iteration could address this with Ansible or similar, but for now these are rare, documented manual operations.
- Home Assistant UI-edited configuration is captured back to Git via the rsync workflow, but there's no automated enforcement preventing direct prod edits. The capture script and Git diff review are the detection mechanism.

---

## 5. Environment Model

### 5.1 Environments

Two environments are defined:
- **prod** - Production environment
- **dev** - Development/testing environment

### 5.2 Environment Binding Rule

> Environment is determined exclusively by network attachment (VLAN).

| Environment | VLAN | Subnet | DNS Domain |
|-------------|------|--------|------------|
| prod | (site) | (site) | prod.example.com |
| dev | (site) | (site) | dev.example.com |

VLAN IDs and subnets are site configuration. The examples `10.0.10.0/24` and `10.0.20.0/24` are used throughout this document as illustrations.

VM images are environment-agnostic. The VLAN determines environment at deployment time — OpenTofu places the VM on the correct VLAN and delivers the corresponding network config (IP, gateway, DNS servers, search domain) via CIDATA. VMs use unqualified hostnames for infrastructure services (e.g., `vault`, `acme`), and the CIDATA-provided search domain resolves them to the correct environment-specific address.

### 5.3 Dev/Prod Infrastructure Model

Each environment has its own complete infrastructure stack. VMs are fully environment-ignorant — the same image runs in both environments with no conditional behavior.

**Per-environment infrastructure (parallel stacks):**
- dns1, dns2 (PowerDNS + SQLite)
- vault (HashiCorp Vault)

**Prod-only service:**
- Gatus (Health monitoring) — monitors prod services, alerts on prod outages. See section 15.

**Dev-only testing service:**
- step-ca (dev ACME server) — see section 8.4

**Shared operational services (management network):**
- PBS (Proxmox Backup Server) — backs up prod VMs with precious state; dev VMs are not backed up (see section 16.3)
- GitLab (Git hosting + CI/CD) — separate pipelines deploy to dev and prod via branch-based promotion
- CI/CD runner — executes cross-environment pipeline jobs

**What determines where a service lives:**

The deciding factor is *who is the client* and *how they discover the service*:

| Client type | Network | Per-env? | Examples |
|-------------|---------|----------|----------|
| VMs (discover via CIDATA search domain) | Environment VLANs | Yes | DNS, Vault, step-ca (acme-dev) |
| Proxmox nodes (hypervisor operations) | Management network | No | PBS |
| Operator or CI (control plane) | Management network | No | GitLab, CI/CD runner |

Per-environment services are discovered by VMs using unqualified hostnames resolved
via the CIDATA-provided search domain. A dev VM resolves `vault` and gets the dev Vault; a prod
VM resolves `vault` and gets the prod Vault. This mechanism *requires* per-environment
instances — it's how environment isolation works.

Shared services are consumed by the Proxmox nodes or the operator, not by VMs at
runtime. Per-environment VMs do not access shared services. Shared services and any
VMs that need direct access to them (such as development workstations) are placed on
the management network. Backup traffic flows from Proxmox nodes to PBS. CI/CD
pipelines are triggered by Git pushes, not by VM DNS discovery. The CI runner
deploys to VMs via the Proxmox API and SSH (management → environment, already
routed). These services sit in the *control plane* that manages both environments,
not in the *data plane* that serves them.

**Single-environment services (prod-only and dev-only):**

Some services exist in only one environment because only that environment needs them:

- **step-ca (dev-only):** Dev VMs need a local ACME server because Let's Encrypt
  can't reach the dev VLAN (dev DNS is not publicly delegated). step-ca
  (Smallstep) is a private ACME server with a static, operator-provided root CA.
  The static root CA is checked into the repo and delivered to dev VMs via CIDATA,
  where a generic extra-CA boot service adds it to the system trust store. This
  keeps dev fully self-contained with no internet dependency for certificate
  issuance. Prod has no equivalent — it uses Let's Encrypt directly. See section
  8.4 for the full design and section 8.6 for the TLS trust architecture.
- **Gatus (prod-only):** Gatus's purpose is to alert when prod services are down.
  Dev infrastructure is expected to break during testing — dev alerts would be noise,
  not signal. Gatus lives on the prod VLAN, monitors prod services, and sends
  alerts to the operator. The NAS sentinel (Tier 2) monitors Gatus itself from
  outside the cluster. Gatus also monitors cross-environment resources (Proxmox
  nodes, NAS, PBS) via prod→management routing (already allowed by the gateway
  firewall). A dev Gatus instance can be added later if needed, but it is not
  deployed by default.

**Network placement follows from the client:**

| Service | Network | Rationale |
|---------|---------|-----------|
| dns1/dns2 | Environment VLAN | Clients are VMs on the VLAN |
| vault | Environment VLAN | Clients are VMs on the VLAN |
| acme-dev | Dev VLAN | Client is dev certbot (on dev VLAN) |
| gatus | Prod VLAN | Monitors prod services; operator views via prod VLAN routing |
| PBS | Management | Client is Proxmox nodes (management network) |
| GitLab | Management | Client is operator and CI runner (management network) |
| CI/CD runner | Management | Client is GitLab (management network); deploys via Proxmox API (management network) |

**Why shared services don't need a dev instance:**

- **PBS:** Vendor appliance, no project code. Hypervisor-level operation. A PBS
  "bug" doesn't cascade to VMs. Test upgrades in maintenance windows, not via
  parallel instances.
- **GitLab:** Hosts the single repository with branch-based deployment: pushes
  to `dev` deploy to the dev environment, merges to `prod` deploy to the prod
  environment. Two GitLabs would require repository synchronization — complex,
  fragile, and unnecessary when branch protection provides the promotion gate.
- **CI/CD runner:** Execution agent for GitLab. Environment-scoped runners (for
  deployment security) are a pipeline design choice, not a reason for separate
  instances.

**Motivations for parallel infrastructure (per-environment services):**
- **Testability:** Infrastructure configuration changes (DNS, Vault) are validated in dev before promotion to prod. The dev stack exercises the same code paths as prod.
- **Environment ignorance:** VMs don't need to know whether they're in dev or prod. Infrastructure services are discovered via DNS search domain, not hardcoded addresses.
- **Simplicity of rules:** One uniform rule (each environment has its own stack) is simpler than deciding per-service whether to share. Shared/non-shared distinctions increase cognitive load.
- **Acceptable resource cost:** Infrastructure VMs (DNS, Vault) are small — a DNS server needs ~256MB RAM and a few GB of disk. The cost of parallel stacks is trivial on modern mini-PC hardware with 32GB+ RAM per node.

### 5.4 Infrastructure VM Inventory

Complete list of infrastructure VMs across both environments. Application VMs (databases, Home Assistant, etc.) are additional.

| VM | Environment | Network | Purpose | Est. RAM | Precious State? | PBS Backup? |
|----|-------------|---------|---------|----------|-----------------|-------------|
| dns1-prod | Prod | Prod VLAN | PowerDNS + SQLite | 256MB | No | No |
| dns2-prod | Prod | Prod VLAN | PowerDNS + SQLite | 256MB | No | No |
| vault-prod | Prod | Prod VLAN | HashiCorp Vault | 512MB | Yes (Raft) | Yes |
| gatus | Prod | Prod VLAN | Health monitoring (primary) | 128MB | No | No |
| dns1-dev | Dev | Dev VLAN | PowerDNS + SQLite | 256MB | No | No |
| dns2-dev | Dev | Dev VLAN | PowerDNS + SQLite | 256MB | No | No |
| vault-dev | Dev | Dev VLAN | HashiCorp Vault | 512MB | Yes (Raft) | Yes |
| acme-dev | Dev | Dev VLAN | ACME server (step-ca) | 128MB | No | No |
| pbs | Shared | Management | Proxmox Backup Server | 1GB | No (datastore on NAS) | No |
| cicd | Shared | Management | GitLab Runner | 2–4GB | No | No |
| gitlab | Shared | Management | GitLab (Git hosting + CI/CD) | 4–8GB | Yes (repositories) | Yes |
| **Total infra** | | | | **~5–7GB** | | |

Resource estimates are approximate and will be refined during implementation. Total infrastructure VM allocation is well within the N+1 capacity limit — the cluster limits total VM load to 2 nodes' worth (~64GB of 96GB total) so that any single node failure can be absorbed without overcommitting (see section 11.4 for details). Remaining capacity (~57–59GB) is available for application VMs (Home Assistant, databases, monitoring, future services).

Anti-affinity requirements:
- dns1-prod and dns2-prod must be on different nodes
- dns1-dev and dns2-dev should be on different nodes (softer constraint)

---

## 6. Infrastructure Foundation

### 6.1 Physical Hardware

**Minimum requirements:**

| Component | Requirement | Notes |
|-----------|-------------|-------|
| Compute nodes | 2+ identical or similar nodes | 3+ recommended for N+1 capacity with HA |
| RAM per node | 16GB minimum | More allows more VMs; N+1 rule applies to total |
| Storage per node | 1 NVMe for Proxmox boot (ZFS), 1 NVMe for VM data (ZFS) | Separate boot and data drives simplify ZFS management |
| Networking | 1G+ Ethernet to a managed switch | VLAN-capable required |
| Gateway/router | VLAN-aware, routing, firewall | DHCP optional (for non-Mycofu devices). Mycofu VMs use static IPs from config.yaml. |
| Off-cluster NAS | Network-attached storage independent of the cluster | Holds OpenTofu state (PostgreSQL), PBS backup datastore, sentinel monitoring |

**Optional but recommended:**

| Component | Benefit |
|-----------|---------|
| Dedicated replication network | Separates high-bandwidth ZFS replication from VM/management traffic |
| 10G+ replication links | Reduces replication lag, enables faster planned migration |

**Architecture note on dedicated replication network:**

If nodes have additional network interfaces (e.g., SFP+ ports), a dedicated replication network can be configured to carry ZFS replication, VM migration, and corosync traffic. Two topologies are supported:

**Topology: mesh (point-to-point DAC cables)**

Direct cables between each node pair, no switch. For 3 nodes: 3 DAC cables. Scales as N×(N-1)/2 cables — practical for 3–4 nodes.

The mesh uses a hybrid addressing scheme:

1. **Point-to-point /30 subnets** on the physical interfaces between each pair of nodes. These carry ZFS replication and migration traffic directly between peers.

2. **A dummy0 interface per node** with a unique /32 address from a shared subnet. This is the corosync ring0_addr — the stable address that all nodes use to reach each other for cluster communication.

3. **Dual-metric static routes** to each peer's dummy0 /32: a direct route (low metric) via the point-to-point link, and a fallback route (high metric) via the third node. If a DAC cable fails cleanly (both ends lose carrier), the kernel drops the direct route and traffic automatically reroutes through the surviving node acting as a relay. All nodes have `net.ipv4.ip_forward=1` to support this forwarding. Routes are configured as `post-up` hooks on BOTH the physical interfaces (nic2/nic3) and the dummy0 interface, using `ip route replace` (idempotent). This dual placement ensures routes are restored when a physical link comes back up after a peer node reboots — the kernel removes routes via a downed interface, and ifupdown2 only re-runs post-up hooks on the interface that changed state, not on dummy0.

4. **A replication link watchdog** (`repl-watchdog.sh`) on each node, run by a systemd timer every 10 seconds. It pings each peer's point-to-point IP. If a peer is unreachable for 3 consecutive checks (30 seconds), the watchdog brings down the local interface to that peer. This converts asymmetric failures (one end down, other end still up) into symmetric failures that the dual-metric routing handles correctly. Without this watchdog, an asymmetric failure breaks bidirectional reachability: the node with the live interface keeps using its direct route, but the peer can't reply because its end is dead. The watchdog is mesh-specific and is NOT deployed in switched topologies.

5. **A replication health endpoint** (`repl-health.sh`) on each node, served on a local HTTP port. It reports interface state, dummy0 state, route completeness (both metrics present per peer), corosync link status, and peer reachability. This endpoint is scraped by the primary Gatus instance for cluster-layer monitoring. The health endpoint is topology-aware and is deployed in BOTH mesh and switched topologies (with different checks per topology).

This design was chosen because corosync requires each node to have a single ring address reachable by all other nodes. Point-to-point /30 subnets alone do not satisfy this — a /30 address is only reachable by the peer on the other end of that link. The dummy0 /32 with static routes provides globally reachable corosync addresses while preserving the point-to-point addressing for direct ZFS replication.

**Topology: switched (dual A/B switches)**

Each node connects to two redundant switches. All nodes share a common subnet on each switch. Corosync uses one switch's IP as link0, the other as link1. This is the standard Proxmox multi-link corosync pattern — no dummy0, no special routing, no watchdog. Scales linearly (adding a node = 2 cables regardless of cluster size). The replication health endpoint is deployed but the watchdog is not, as switch-based topologies have clean failure modes that corosync handles natively.

The switched topology is defined in `config.yaml` via `replication.topology: switched`. Its full implementation (per-node schema, `configure-node-network.sh` support) will be added when needed. The mesh implementation is topology-aware so that the switched path is a clean addition rather than a refactor.

**Topology selection guidance:** Mesh is cost-effective for 3–4 nodes with available SFP+ ports. Switched is recommended for 5+ nodes, when nodes have limited SFP+ ports, or when operational simplicity is preferred over cost savings.

Both topologies are optional. A single switched management network works fine for small clusters with moderate replication loads. The architecture does not depend on a dedicated replication network. When the replication network is not deployed, ZFS replication and corosync both use the management network. Corosync runs on a single link instead of dual links, and `repl-health.sh` should report only management-network health (not missing dummy0 or point-to-point interfaces). If the replication network was planned in config.yaml but `configure-node-network.sh` was not run (or was run before the DAC cables were connected), the health endpoints will report the replication interfaces as unhealthy — this is correct behavior indicating an incomplete deployment, not a monitoring false alarm.

**Intel iRDMA driver policy:**

The Intel E810 NICs (ice driver) used in the Minisforum MS-02 Ultra support RDMA (Remote Direct Memory Access) via the `irdma` kernel module, which implements iWARP and RoCEv2 protocols. Proxmox loads this module by default when the ice driver initializes. However, `irdma` is blacklisted on all nodes in this architecture (`/etc/modprobe.d/no-irdma.conf`), and `configure-node-network.sh` deploys this blacklist automatically.

This decision was made after a production incident in which the irdma module silently put a replication interface into a down state, causing a 12+ hour undetected corosync link failure. The upstream irdma module shipped with Proxmox's kernel has known stability issues when no RDMA workload is actually using it — it initializes, binds to hardware queues, and participates in link state management even when idle, creating a failure surface with no corresponding benefit.

All current cluster traffic (ZFS replication, VM migration, corosync) uses TCP/IP and does not benefit from RDMA. The blacklist eliminates an unnecessary failure mode.

**When to revisit this decision:** If the cluster runs workloads that benefit from RDMA — specifically distributed inference with tensor parallelism (e.g., vLLM, DeepSpeed, NCCL) or high-frequency inter-node data transfer — RDMA can provide 2–5x latency improvement over TCP. In that case:

1. Remove the blacklist on the relevant nodes
2. Install Intel's out-of-tree irdma driver (not the upstream kernel module, which has the stability issues that caused the incident)
3. If using RoCEv2 with switches (not point-to-point): configure Priority Flow Control (PFC) and ECN on the switches for lossless Ethernet — RoCEv2 degrades severely under packet loss
4. If using GPUs: evaluate whether GPUDirect RDMA is needed, which may favor Mellanox ConnectX NICs over E810 depending on the GPU vendor's support

The blacklist is topology-independent — it applies to both mesh and switched configurations unless RDMA workloads are explicitly introduced.

**NIC naming and auto-discovery:**

Interface names in config.yaml (e.g., `mgmt_iface: nic0`, repl_peers with `iface: nic2`) must map to the correct physical NICs. This mapping is not guaranteed by the Proxmox installer — kernel NIC enumeration order varies across nodes with identical hardware, and the installer's "pin interface names" feature assigns names without knowledge of which physical port is cabled to which destination.

`configure-node-network.sh` handles this automatically:

1. **Identifies the management NIC** by finding which physical interface currently holds the node's management IP (the one we're SSH'd through).
2. **Discovers replication links** by assigning temporary link-local IPs (169.254.x.y/30) on candidate NICs and pinging peer nodes to determine which physical port connects to which peer.
3. **Writes systemd `.link` files** that pin the discovered MACs to the interface names declared in config.yaml. Any conflicting `.link` files from the Proxmox installer are removed.
4. **Reboots nodes if naming changes are needed**, then re-runs to verify and proceed with full interface configuration.

The naming mechanism uses systemd `.link` files at `/etc/systemd/network/10-pmx-*.link`, NOT udev rules. On Proxmox (Debian with systemd v257+), the `net_setup_link` builtin in `/lib/udev/rules.d/80-net-setup-link.rules` processes `.link` files and overrides any earlier udev `NAME=` assignments. After writing `.link` files, `update-initramfs -u` is required so the files are available during early boot when interface naming occurs. This is a Debian/Proxmox-specific requirement — other distributions may handle `.link` file loading differently.

The discovery algorithm is topology-aware: in mesh mode, it probes point-to-point links per peer pair. Switched topology discovery is not yet implemented (stubbed with a clear error). The algorithm works for clusters of 2–4 nodes (mesh) and is designed to extend to arbitrary node counts (switched).

**Storage & Backup:**
- Off-cluster NAS (independent of cluster)
  - OpenTofu state (PostgreSQL)
  - Backups (off-cluster)

**Network:**
- VLAN-capable gateway (routing, firewall)
- Managed switch (VLAN trunking to nodes)

### 6.2 Network Architecture

**Required network infrastructure:**

**Switched Ethernet (managed switch):**
- VM traffic (north-south, VLAN-tagged)
- Management access (Proxmox web UI, SSH)
- Proxmox cluster communication — corosync link1 (fallback)
- ZFS replication (if no dedicated replication network)

**Dedicated replication network (optional, recommended):**
- Proxmox cluster communication — corosync link0 (primary)
- ZFS replication between nodes
- VM planned migration (final sync + restart)
- Two supported topologies:
  - **Mesh:** Direct point-to-point DAC cables, dummy0 /32 for corosync, dual-metric routes, link watchdog
  - **Switched:** Dual A/B switches, shared subnets, standard Proxmox multi-link corosync
- Replication health endpoint deployed in both topologies; link watchdog deployed in mesh only

If a dedicated replication network is used, the two networks provide fault isolation: a switch failure does not affect cluster quorum or replication (corosync continues over the replication network), and a replication link failure triggers automatic failover (via the third node in mesh, or via the redundant switch in switched). If a single switched network is used, all traffic shares the same path — simpler but without fault isolation.

**VLANs:**

| VLAN | Purpose | Subnet | Residents |
|------|---------|--------|-----------|
| Management (native/untagged) | Proxmox nodes, NAS, operator workstation, shared services | (site-specific) | Nodes, NAS, PBS, GitLab, CI/CD |
| Prod VLAN | Production workloads and monitoring | (site-specific) | Per-environment prod VMs (DNS, Vault), Gatus |
| Dev VLAN | Development/testing | (site-specific) | Per-environment dev VMs (DNS, Vault, step-ca (acme-dev)) |

VLAN IDs and subnets are site configuration. The architecture requires at least two tagged VLANs (prod and dev) with separate subnets, plus the management network (native/untagged). Mycofu VMs use static addressing from config.yaml — DHCP scopes on the VLANs are optional (only for non-Mycofu devices).

**Firewall rules:**
- DNS: gateway port-forwards WAN:53 to prod dns1 on port 8053 (the authoritative
  instance). See section 7.2 for why port 8053, not 53.
- All other services firewalled (no direct internet access)
- Inter-VLAN routing: Blocked by default. No exceptions needed — shared operational
  services (PBS, GitLab, CI/CD) are on the management network, not on environment
  VLANs. Gatus is on the prod VLAN and reaches management-network resources
  (nodes, NAS, PBS) via the existing prod→management route. See section 5.3.

**External access:**
- Tailscale (or similar overlay VPN) for remote access to services
- No port forwarding for services (except DNS)

**Proxmox bridges:**

| Bridge | Type | Purpose | Carries |
|--------|------|---------|---------|
| `vmbr0` | VLAN-aware | Primary VM networking | Tagged VLAN traffic (prod, dev) + untagged management for Proxmox nodes |
| `vmbr1` | Simple (no VLANs) | Management network for VMs | Untagged management traffic only |

`vmbr1` is connected to `vmbr0`'s untagged traffic via a veth pair
(`veth-mgmt` ↔ `veth-mgmt-br1`). This allows VMs on `vmbr1` to be on
the management network without being on the VLAN-aware bridge. Two
NICs from the same VM on the same VLAN-aware bridge causes MAC learning
confusion — `vmbr1` eliminates this. See section 7.1 for the full
design and policy routing details.

`configure-node-network.sh` creates both bridges and the veth pair on
all nodes. Most VMs have a single NIC on `vmbr0` with a VLAN tag. VMs
with a `mgmt_nic` in config.yaml get a second NIC on `vmbr1`.

### 6.3 Virtualization Platform

**Proxmox VE:**
- Multi-node cluster (3+ nodes recommended for HA)
- ZFS local storage with replication (each node owns its storage independently)
- VMs created/managed by OpenTofu
- HA enabled (VM restart on surviving node from ZFS replica)

**ZFS Configuration:**

Each node maintains an independent ZFS pool on its data drive:
- Pool name: from `config.yaml → proxmox.storage_pool` (e.g., `vmstore`). This is the pool on the data NVMe, separate from the Proxmox boot drive. The separation provides fault isolation: a boot drive failure doesn't affect VM data, and a data drive failure doesn't affect the OS. `configure-node-storage.sh` identifies the boot drive (by finding the device hosting the root filesystem) and creates the data pool on the other NVMe.
- **Two-drive requirement:** Each node currently requires two NVMe drives — one for Proxmox boot, one for the ZFS data pool. The boot drive filesystem is flexible (ZFS `rpool` or ext4 — the installer's choice). Single-drive nodes (using a partition or the Proxmox installer's default `local-lvm`/`local-zfs` for VM storage) are a future enhancement. The storage pool name flows through OpenTofu modules, replication config, and PBS datastore references, so single-drive support requires more than just a `configure-node-storage.sh` change.
- VM disks stored as raw zvols (not qcow2 — avoids double copy-on-write)
- ZFS replication between nodes via Proxmox (1-minute interval)
- ZFS scrubs scheduled weekly, SMART monitoring enabled

**Replication Strategy:**
- All VMs replicated to all other nodes (symmetric, no exceptions)
- Replication interval: 1 minute (uniform across all VMs)
- Simplicity over optimization: one rule, no per-VM differentiation

**Why ZFS instead of Ceph:**
- **Resilience:** Storage is local to each node; losing cluster quorum does not take storage offline. VMs keep running where they are even during quorum loss.
- **Maintenance safety:** Taking a node down for updates does not degrade a distributed storage pool. Remaining nodes are unaffected.
- **Operational simplicity:** No MON/OSD/MGR daemons to operate, no CRUSH maps, no placement groups. ZFS is well-understood, debuggable with local tools.
- **Right-sized for small clusters:** Ceph is uncomfortable below 5 nodes (fragile quorum, no room for re-replication during maintenance). ZFS replication is purpose-built for 2–5 node clusters.
- **Not a learning goal:** Storage should be boring infrastructure. ZFS is mature, proven, and requires minimal ongoing attention.
- **Future-compatible:** If nodes are added later (5+), Ceph can be introduced at a scale where it's comfortable. ZFS does not lock out future options.

**Trade-offs accepted:**
- No seamless sub-second live migration (Ceph's primary advantage). Planned migration requires a final replication sync + brief VM restart (typically 10–20 seconds of downtime).
- Unplanned node failure: up to 1 minute of writes may be lost on the data disk (bounded by replication interval). OS disks are rebuildable from Git, so this only affects application state on vdb.
- Unplanned failover time is ~45–90 seconds total (dominated by fencing/watchdog detection, not storage). This is the same as Ceph for unplanned failures — Ceph's sub-second advantage only applies to planned live migration, not crash recovery.
- These trade-offs are acceptable for small-to-medium clusters (3–4 nodes) where operational simplicity outweighs sub-second migration.

### 6.4 Time Service (NTP)

**Decision:** Gateway-provided NTP, not cluster-hosted.

Accurate time is required for TLS certificate validation (not-before /
not-after), Vault token expiry, PBS backup timestamps, log correlation, and
Proxmox cluster corosync. However, NTP is a network-layer service — it sits
below the cluster in the dependency stack, just like DHCP. The cluster cannot
bootstrap its own NTP service because the VMs that would run it need accurate
time to get TLS certificates to start the services that would provide time.

**Architecture:** The management gateway provides NTP to all clients. Most
home routers already serve NTP (synced to public pools). Mycofu configures:
- **Proxmox nodes:** `systemd-timesyncd` pointed at the NTP server
  (`configure-node-network.sh` writes the config)
- **NixOS VMs:** `systemd-timesyncd` pointed at the NTP server (delivered
  via CIDATA `write_files`, same pattern as DNS server and ACME URL)
- **PBS:** Timezone and NTP configured during installation (answer file)

The NTP server address defaults to the management gateway IP. If the
operator has a dedicated NTP appliance or wants to use a public pool
directly, they set `ntp_server` in config.yaml.

**Why not cluster-hosted NTP:** Same reasoning as DHCP (section 7.1) —
circular dependency. NTP must be available before any VM boots. Running it
on the gateway breaks the dependency cycle.

---

## 7. DNS and Network Addressing Strategy

### 7.1 Static Addressing from config.yaml

**config.yaml is the network authority for Mycofu VMs.** Every VM's IP
address, MAC address, gateway, DNS servers, and search domain are declared
in config.yaml and delivered via CIDATA at boot. VMs do not use DHCP.

**Why not DHCP:**
- DHCP re-discovers information the system already has (IP, gateway, DNS
  servers are all in config.yaml)
- DHCP reservations on the gateway must be manually kept in sync with
  config.yaml — a human relay between two systems that could talk directly
- `networking.useDHCP = true` applies to ALL interfaces, causing routing
  conflicts when a VM has multiple NICs (e.g., Roon's client VLAN NIC)
- DHCP depends on the gateway service being reachable at boot — an
  unnecessary fragility during disaster recovery
- DHCP lease renewal can briefly drop a VM's address

**What CIDATA delivers (via OpenTofu, from config.yaml):**

| Value | Source | Purpose |
|-------|--------|---------|
| IP address + prefix | `config.yaml → vms.<name>.ip` | Static address on the VLAN interface |
| Gateway | `config.yaml → environments.<env>.gateway` | Default route |
| DNS server IPs | `config.yaml → environments.<env>.dns_servers` | Nameservers for resolution |
| Search domain | `config.yaml → environments.<env>.domain` | Resolves unqualified names (`vault` → `vault.prod.example.com`) |

All values are written to a systemd-networkd `.network` file via CIDATA
at first boot, before any network negotiation. There are no race
conditions, no lease files to parse, no non-deterministic delays.

**Gateway DHCP still serves non-Mycofu devices** (operator workstation,
phones, IoT). The DHCP range on each VLAN must be configured to NOT
overlap with the Mycofu static range. A simple convention: Mycofu VMs
use the lower range (e.g., .50–.99), DHCP hands out the upper range
(e.g., .100–.254).

**No DHCP reservations needed.** Since Mycofu VMs use static addressing,
there are no DHCP reservations to create or maintain on the gateway. This
eliminates the manual sync step that was previously required when adding
a new VM to config.yaml.

#### Management Network NICs (vmbr1)

Some VMs need a second NIC on the management network — for example, the
Roon VM needs management network presence for RAAT multicast audio
discovery (group `239.255.90.90/UDP 9003`).

**Two NICs on the same VLAN-aware bridge (vmbr0) does not work.** Linux
VLAN-aware bridges cannot reliably deliver frames when a VM has multiple
tap devices on the same bridge with different VLAN tags. The bridge's MAC
learning table gets confused about which port to use, causing frames to
be delivered to the wrong tap device. This is a fundamental limitation of
the bridge architecture, not a misconfiguration.

**Solution: vmbr1 (management bridge).** A separate non-VLAN-aware bridge
on each Proxmox node carries untagged management traffic. A veth pair
bridges management traffic from vmbr0 to vmbr1:
- `veth-mgmt`: bridge port of vmbr0, PVID 1 (untagged)
- `veth-mgmt-br1`: bridge port of vmbr1

VMs needing a management NIC get their second NIC on vmbr1 (not vmbr0).
The bridges are independent — no MAC table confusion.

`configure-node-network.sh` creates the veth pair and vmbr1 on all nodes.
This is idempotent and survives reboots.

**config.yaml `mgmt_nic` block:** Any VM can declare a management NIC
with an operator-chosen DNS name:

```yaml
roon_prod:
  vmid: 603
  ip: "172.27.10.57"              # prod VLAN (primary NIC on vmbr0)
  mac: "02:xx:xx:xx:xx:xx"
  node: pve03
  backup: true
  mgmt_nic:
    name: "roon-mgmt"             # DNS: roon-mgmt.prod.example.com
    ip: "172.17.77.67"            # management subnet (second NIC on vmbr1)
    mac: "02:yy:yy:yy:yy:yy"
```

The DNS zone generator automatically creates an A record for
`<mgmt_nic.name>.<environment>.<domain>`. The `name` field is
operator-chosen — no convention imposed.

**Source-based policy routing on dual-NIC VMs:** When a VM has NICs on
two subnets, the kernel routes replies by shortest path to destination,
not by source address. A reply from the VLAN IP to a management network
host exits via the management NIC (direct route) instead of the VLAN
gateway — the gateway drops it as having the wrong source address for
that port.

The fix: the `configure-mgmt-nic` systemd service writes policy routing
rules alongside the management NIC's networkd config. Traffic sourced
from the VLAN IP uses routing table 100, which routes via the VLAN
gateway. Traffic sourced from the management IP uses the default table
(direct delivery on the management subnet). This ensures replies always
exit via the correct interface for their source address.

**Management NIC design constraints:**
- No default route on the management NIC — only a connected subnet route
- No DNS or search domain on the management NIC — DNS resolution uses
  the primary NIC's configuration via systemd-resolved
- Static IP from config.yaml (not DHCP) — same principle as the primary NIC

### 7.2 DNS on NixOS VMs

**Implementation:** PowerDNS with SQLite backend

**Motivations:**
- HTTP API simpler for automation than BIND's TSIG/RFC 2136
- Better integration with ACME DNS-01 challenges
- Declarative management via NixOS
- SQLite backend: lightweight, no external database dependency, disposable (zone data is Category 2, delivered via CIDATA at boot)

**Decision: SQLite over PostgreSQL**

Zone data is Category 2 (configuration derivable from Git — see section 11.2.1 for the full data taxonomy). OpenTofu generates zone records from config.yaml and delivers them to DNS VMs via CIDATA. A systemd oneshot on each DNS VM loads the zone data into PowerDNS at boot. The database is a cache of what's in Git, not a source of truth. If a DNS VM is rebuilt, it loads zone data from its own CIDATA — no external push step or database backup needed.

PostgreSQL would introduce unnecessary complexity: either a separate database VM (creating a circular dependency — DNS depends on the database, database depends on DNS), or PostgreSQL running locally on each DNS VM with replication to manage. SQLite eliminates all of this. Each DNS VM is fully independent and disposable.

**Architecture:**
- Two DNS servers per environment (dns1, dns2) — 4 total
- Both authoritative within their environment
- SQLite backend (local to each DNS VM, disposable)
- Prod DNS servers publicly queryable (port 53 exposed through firewall)
- Dev DNS servers internal only (not reachable from internet)

**Recursive resolution via `pdns-recursor`:**

PowerDNS authoritative is not a recursive resolver — it answers queries for its own
zones and returns REFUSED for everything else. But CIDATA delivers the DNS VM IPs as the
nameservers for all VMs in the environment. Without recursive resolution, no VM in
the environment can resolve external names (e.g., `github.com`,
`acme-v02.api.letsencrypt.org`). This is a hard blocker for certificate issuance
(certbot must reach Let's Encrypt in prod) and for any future service that needs
external connectivity.

**Decision:** Run `pdns-recursor` alongside `pdns` (authoritative) on each DNS VM.
The recursor is the entry point for all DNS queries (listening on port 53 on the
VM's external IP and on 127.0.0.1). It forwards queries for local zones to the
co-located authoritative instance (listening on a non-standard port, e.g., 8053, on
127.0.0.1 only) and resolves all other queries via an upstream forwarder.

**Why `pdns-recursor`, not the legacy `recursor` directive:**
PowerDNS 4.1+ removed the `recursor` configuration directive that previously allowed
the authoritative server to forward unknown queries. The modern approach is a
dedicated recursor process. This is PowerDNS's own recommended architecture for
combined authoritative + recursive service.

**Port layout on each DNS VM:**

| Process | Listen address | Port | Purpose |
|---------|---------------|------|---------|
| `pdns-recursor` | 0.0.0.0 | 53 | Entry point for VLAN clients (recursive + authoritative) |
| `pdns-recursor` | 127.0.0.1 | 53 | Local process resolution (resolv.conf points here) |
| `pdns` (auth) | 0.0.0.0 | 8053 | Authoritative zones — serves both recursor forwards and public queries |
| `pdns` (auth) | 0.0.0.0 | 8081 | HTTP API (boot-time zone loading, ACME challenges) |

**Split DNS: internal vs. public query paths:**

The DNS VMs serve two audiences that need different behavior:

- **Internal clients** (VMs on the VLAN) need full-service DNS: both local zone
  resolution and external name resolution. They query port 53 (the recursor).
- **Public resolvers** (following NS delegation from the registrar) need
  authoritative-only responses with the AA (Authoritative Answer) flag set. They
  must reach the authoritative instance, not the recursor. The recursor refuses
  non-recursive queries (RD=0) and never sets the AA flag — this is correct
  behavior for a recursor but makes the delegation appear "lame" to public
  resolvers.

The gateway's port forward rule bridges these two paths: WAN port 53 is forwarded
to the DNS VM's port 8053 (the authoritative), not port 53 (the recursor). Public
resolvers query WAN:53, get port-forwarded to VM:8053, and receive proper
authoritative answers. Internal VMs query VM:53 and get full recursive+authoritative
service.

```
Public resolver → WAN:53 → port forward → VM:8053 → pdns (auth) → AA response ✓
Internal VM     → VM:53                  → pdns-recursor → forward to auth or gateway
```

This split is transparent to both audiences — public resolvers see a standard
authoritative nameserver on port 53 (via the port forward), and internal VMs see
a full-service resolver on port 53 (the recursor). The VM image is unaware of the
port forward — it works identically in dev (no port forward, step-ca queries
directly) and prod (port forward active).

The recursor is configured with a `forward-zones` entry that sends queries for the
local zone (e.g., `dev.example.com`) to 127.0.0.1:8053 (the authoritative instance).
All other queries go to the upstream forwarder.

**Forward-zone domain:** The environment's DNS domain (e.g., `prod.example.com`,
`dev.example.com`). Injected per-environment via nocloud-init `write_files` at
`/run/secrets/dns/forward-zone-domain`. The recursor's `ExecStartPre` reads this
file and writes the `forward-zones=<domain>=127.0.0.1:8053` entry.

**Upstream forwarder:** The environment's gateway IP (e.g., `10.0.10.1` for prod,
`10.0.20.1` for dev). The gateway IP is injected per-environment via nocloud-init
`write_files` at `/run/secrets/dns/recursor-ip`, keeping the VM image
environment-ignorant.

**Both values come from write_files, not from DHCP.** This ensures
deterministic boot ordering: write_files are available from CIDATA at
first boot, as a mounted ISO. Services that depend on these values have
no race condition with network negotiation.

**Why the gateway as upstream, not a public resolver (8.8.8.8):**
- The gateway is always reachable from the VLAN (no firewall exceptions needed)
- Keeps DNS traffic within the local network
- The gateway's recursive resolver already handles all non-cluster DNS for the local network
- If the operator prefers a different upstream, they change the gateway's config (one
  place), not every DNS VM

**Benefits over the resolv.conf-only approach:**
- Every VM in the environment gets full-service DNS (authoritative + recursive) from
  the CIDATA-delivered nameservers. No per-VM resolv.conf workarounds needed.
- The DNS VMs are self-contained — a single service pair handles all resolution.
- Caching in the recursor reduces upstream query load.
- The `/etc/resolv.conf` on the DNS VM itself points to 127.0.0.1:53 (the recursor),
  so local processes also get full resolution.

**Alternatives considered:**
- `recursor` directive in pdns.conf: Removed in PowerDNS 4.1+. Not available.
- Gateway IP in resolv.conf only (no recursor): Works for the DNS VM's own processes
  but doesn't help other VMs in the environment — they query the DNS VMs on port 53
  and still get REFUSED for external names. Every VM would need its own resolv.conf
  workaround.
- Running `unbound` instead of `pdns-recursor`: Capable, but using the PowerDNS
  ecosystem's own recursor simplifies the `forward-zones` integration and avoids
  mixing DNS software stacks.

**DNS resolution on non-DNS VMs (systemd-resolved):**

Non-DNS VMs use `systemd-resolved` to bridge the DNS server IPs and search
domain from systemd-networkd's `.network` file to `/etc/resolv.conf`.
Without resolved, networkd's `DNS=` and `Domains=` directives do not
propagate to resolv.conf — applications that read resolv.conf would have
no nameservers configured.

DNS VMs disable `systemd-resolved` because it binds to port 53, which
conflicts with PowerDNS. DNS VMs manage their own resolv.conf (pointing
to `127.0.0.1:53`, the local recursor).

**DNS serves:**
- Prod DNS: authoritative for prod.example.com, reverse DNS for prod subnet
- Dev DNS: authoritative for dev.example.com, reverse DNS for dev subnet
- DNS-01 ACME challenges (via PowerDNS API)

**ACME challenge handling:**
- certbot on each VM writes DNS-01 challenge TXT records to both DNS servers in its environment (two API calls)
- This ensures the validating ACME server sees the record regardless of which DNS server it queries
- certbot discovers its environment's DNS server IPs from `write_files` at `/run/secrets/certbot/pdns-api-servers` (environment-ignorant — the value comes from config.yaml via OpenTofu, not from DHCP)

**Redundancy motivations:**
- DNS is extremely critical (failure breaks everything immediately)
- Resource cost is trivial: a PowerDNS + SQLite VM needs ~256MB RAM and 2–4GB disk
- Enables zero-downtime maintenance
- Proves rebuildability (forces handling multiple instances)
- Acceptable to have 4 DNS VMs total — the resource footprint is negligible on modern multi-node clusters

### 7.3 Public DNS Requirements

This architecture uses **subdomain delegation** — the domain registrar remains authoritative for the base domain (e.g., `example.com`), and only the `prod` subdomain is delegated to the self-hosted DNS servers. The `dev` subdomain is not publicly delegated — it exists only within the dev VLAN.

**Subdomain delegation at registrar:**
- Add A records for `dns1.<domain>` and `dns2.<domain>` pointing to the site's public IP
- Add NS records for `prod.<domain>` pointing to `dns1.<domain>` and `dns2.<domain>`
- Do NOT change the NS records for the base domain itself
- Existing records for the base domain (MX, SPF, DMARC, A, CNAME, etc.) are unaffected

**Why nameservers at the base domain (not inside the subdomain):**
- `dns1.<domain>` and `dns2.<domain>` are simple A records in the base zone — the registrar already serves them, no glue records needed
- The alternative (`dns1.prod.<domain>`) would require glue records at the registrar, which many registrars (including IONOS) only support for the domain's own nameservers, not for subdomain delegation
- The same nameserver names can serve multiple subdomain delegations if needed

**Prod DNS servers must be:**
- Publicly queryable via port forward (gateway forwards WAN:53 to VM:8053, the
  authoritative instance — see section 7.2 for the split DNS explanation)
- Listed as nameservers for `prod.<domain>` via NS delegation at registrar (as `dns1.<domain>` and `dns2.<domain>`)
- Reachable at the site's public IP (A records at base domain)

**Dev DNS servers:**
- Internal only (not reachable from internet, no public delegation, no port forward)
- Used by dev VMs for name resolution and ACME challenges
- ACME validation in dev uses step-ca (see section 8.4), not Let's Encrypt, so external reachability is not needed

**Firewall configuration:**
- Gateway port forward: WAN port 53 (UDP/TCP) → prod dns1 IP, port 8053. This
  sends public DNS queries to the authoritative instance (port 8053), bypassing
  the recursor (port 53). The recursor is only accessible from the VLAN.
- Port 8053 open in the NixOS firewall on DNS VMs (TCP/UDP)
- Rate limiting recommended (not implemented initially)
- DNSSEC optional (add later if desired)

### 7.4 DNS Zone Management Flow

**Source of truth:** Zone data is derived from `config.yaml` at deploy time. VM A records come from the `vms:` and `applications:` blocks. NS and SOA records are computed from the dns VM IPs. Non-VM records (MX, TXT, CNAME) come from optional extra records files (`site/dns/zones/<env>.yaml`). PowerDNS's SQLite database is a derived cache — it is never the source of truth and is fully disposable.

**Zone record derivation:**

| Record type | Source | Example |
|-------------|--------|---------|
| VM A records | `config.yaml → vms.<n>.ip` | `vault A 10.0.10.52` |
| Application A records | `config.yaml → applications.<n>.environments.<env>.ip` | `influxdb A 10.0.10.55` |
| NS records | Computed from dns VM names + base domain | `@ NS dns1.example.com.` (NOT `dns1.prod.example.com.` — must match registrar delegation names) |
| SOA record | Computed from dns1 IP + domain | Standard SOA |
| Extra records (MX, TXT, etc.) | `site/dns/zones/<env>.yaml → extra_records:` | `@ MX 10 mail.example.com.` |

The zone name itself is derived: `${env}.${domain}`, where `domain` is the single `domain:` field in config.yaml. Changing the domain and redeploying updates every zone name automatically.

**Extra records file (optional):**

```yaml
# site/dns/zones/prod.yaml
# Only for records NOT derived from config.yaml (MX, TXT, CNAME, SRV).
# VM A records are generated automatically — do NOT add them here.
extra_records:
  - name: "@"
    type: MX
    priority: 10
    content: "mail.example.com."
  - name: "@"
    type: TXT
    content: "v=spf1 include:_spf.google.com ~all"
```

These files use environment names (`prod.yaml`, `dev.yaml`), not domain names. Changing the domain doesn't affect them. If the file doesn't exist, no extra records are added — the zone works with just the derived records.

**Deployment flow:**

```
config.yaml + site/dns/zones/<env>.yaml
  → OpenTofu generates zone data JSON at plan/apply time
  → CIDATA write_files delivers zone-data.json to DNS VMs
  → DNS VM boots → systemd oneshot reads zone-data.json
  → Reconciles PowerDNS SQLite via localhost API
  → Both DNS servers in the environment get the same zone data
    (each has its own CIDATA with the same zone records)
```

The boot-time reconciliation performs a declarative sync: it creates the zone if it doesn't exist, adds missing records, removes extra records, and updates changed records. This ensures the DNS servers converge to the exact state defined in config.yaml, regardless of any prior drift. Both DNS servers in the environment receive the same zone data via their own CIDATA payloads.

**Drift prevention:**

PowerDNS has an HTTP API and an optional web UI. Manual changes via the API or UI would create drift between Git (source of truth) and the live DNS servers.

Mitigation strategy:
- PowerDNS web UI is not enabled (the NixOS config does not include the webserver module). The API is available only for programmatic access by the zone-loading boot service and certbot.
- Zone data is generated by OpenTofu from config.yaml and delivered via CIDATA. A systemd oneshot on each DNS VM reconciles the PowerDNS SQLite database with the declared zone state at every boot. Any manual API change is overwritten on the next VM restart or redeploy.
- ACME challenge TXT records (created by certbot) are ephemeral and short-lived. They do not conflict with the zone reconciliation because the boot service only manages the base zone records, not the `_acme-challenge.*` records.

**Rollback:**

DNS rollback is `git revert` + re-deploy. Because CIDATA zone data is generated from config.yaml at deploy time, reverting a commit and re-running the pipeline produces VMs with the previous zone state baked into their CIDATA. There is no need to interact with PowerDNS directly.

**Adding a new DNS record:**

For VM A records: add the VM to `config.yaml` (either in `vms:` or `applications:`). OpenTofu automatically generates the DNS record and includes it in the DNS VM's CIDATA. On the next deploy, the DNS VM's boot service loads the updated zone.

For non-VM records (MX, TXT, CNAME, SRV): add the record to `site/dns/zones/<env>.yaml` under `extra_records:`. OpenTofu reads this file and includes the extra records in the CIDATA zone payload.

Either way, the workflow is: edit config, commit, push, pipeline deploys. No separate zone deployment step.

---

## 8. Certificate Management

### 8.1 Decision: Public CA vs Private CA

**Decision:** Use Let's Encrypt (public CA)

**Options considered:**
- Private CA (step-ca, self-hosted)
- Public CA (Let's Encrypt)

**Motivations:**
- **Full automation:** certbot handles DNS-01 challenges, zero manual intervention
- **Guest device compatibility:** No root CA installation needed (critical blocker for private CA)
- **Not a learning goal:** Operating a CA is overhead, not educational value
- **DNS-01 works without service exposure:** Can get certs without opening HTTP/HTTPS ports
- **CT log exposure acceptable:** Internal hostnames in public logs not a concern
- **Simplicity:** Eliminates CA VM, bootstrap, intermediate management, trust distribution
- **90-day renewal is fine:** Automation handles it, actually better security (shorter lifetime)

**Rejected alternative:**
- Private CA: Requires guest CA installation (dealbreaker), operational overhead, complex bootstrap

### 8.2 Certificate Issuance

**Method:** ACME protocol with DNS-01 challenges

**How it works:**
1. certbot runs on VM (daily systemd timer)
2. Requests certificate from Let's Encrypt
3. Let's Encrypt issues DNS-01 challenge
4. certbot updates PowerDNS via API (creates TXT record)
5. Let's Encrypt queries public DNS, validates challenge
6. Let's Encrypt issues certificate
7. certbot installs certificate, reloads services
8. certbot deletes challenge TXT record

**Certificate strategy:** Individual certificates per service

**Motivations:**
- Security isolation (each service has own key pair)
- Selective revocation (can revoke one cert without affecting others)
- Aligns with rebuildability (each VM is independent)
- Not more complex (NixOS automation handles it)
- Better audit trail (see which services renewed when)

**Rejected alternative:**
- Wildcard certificate: Shared credential, larger blast radius on compromise

### 8.3 Certificate Renewal

**Automation:**
- certbot runs daily (systemd timer)
- Checks certificate expiration
- Renews when <30 days remaining
- 60-day renewal window provides buffer

**Failure handling:**
- Alert if renewal fails
- Manual intervention only if automation breaks
- 90-day certificates + 60-day renewal = 30-day buffer

**PowerDNS API credentials:**
- Stored in SOPS permanently (never migrated to Vault)
- certbot reads from `/run/secrets/certbot/pdns-api-key`
- Rationale: The PowerDNS API key is part of the certificate bootstrap chain. A VM needs a certificate to authenticate to Vault, and needs the PowerDNS API key to get that certificate. Migrating this key to Vault would create a circular dependency. The key stays in SOPS because it is bootstrap-tier, not runtime-tier.

#### Category 4 Pattern #2: Vault-Backed Certificate Storage

For non-Vault certbot VMs, the certificate lineage itself is treated as
Category 4 runtime-generated secret material. After `certbot-initial` or
`certbot-renew` succeeds, a deploy-hook writes the live lineage
(`fullchain.pem`, `privkey.pem`, `chain.pem`, `cert.pem`) plus metadata
(`not_after`, `fingerprint`, `issued_at`) to `mycofu/certs/<fqdn>` in Vault.

On subsequent boots, `cert-restore` runs before `certbot-initial`. If Vault has
a certificate for that FQDN with more than 30 days of validity remaining, the
VM restores the lineage locally and skips a fresh ACME issuance. If Vault is
unreachable, the entry is missing, or the stored cert is already inside the
30-day renewal window, restore exits cleanly and the normal ACME path runs.

This makes certificate persistence a second concrete Category 4 pattern after
Tailscale identity: the VM is both the producer and the consumer of the secret,
while Vault provides durability across VM recreation. The first-ever deploy is
still a live ACME event; Vault becomes the source of truth only after the first
successful issuance or an explicit backfill of an existing live cert.

### 8.4 ACME Validation in Dev: step-ca Private ACME Server

**Problem:** Dev DNS servers are internal only (not reachable from the internet). Let's Encrypt's external validators cannot query dev DNS to validate DNS-01 challenges. This means dev VMs cannot obtain real Let's Encrypt certificates.

**Solution:** Run step-ca (Smallstep's private ACME server) on the dev VLAN. Dev VMs' certbot uses step-ca instead of Let's Encrypt. step-ca performs DNS-01 validation by querying the dev DNS servers directly via the `--resolver` flag (which it can reach from the dev VLAN).

**Why step-ca instead of Pebble:** Pebble (Let's Encrypt's official test server) deliberately regenerates its ACME root CA on every startup (GitHub issue #298 — the maintainers rejected making the CA configurable). This means:

1. The CA that signs dev TLS certificates is unpredictable and ephemeral.
2. No mechanism exists to add it to the system trust store at image build time.
3. Any service that needs to verify a certificate issued by Pebble (e.g., vault-agent verifying Vault's TLS cert) requires special CA handling that prod does not need, violating environment ignorance.

step-ca supports a static, operator-provided root CA. The root CA is checked into the repo at `framework/step-ca/root-ca.crt` and `root-ca.key`. It is NOT a secret — it is a dev-only test CA on an isolated VLAN. The static root means:

- The CA can be delivered to dev VMs via CIDATA and added to the trust store at boot
- certbot and vault-agent both use the system CA bundle — identical behavior on dev and prod
- step-ca recreations generate a new intermediate CA but the same root, so existing certs on other VMs remain valid

**How environment ignorance is preserved:**
- VMs configure certbot to use the ACME server URL from CIDATA (at `/run/secrets/acme-url` or equivalent)
- CIDATA-provided search domain resolves the `acme` hostname to the dev step-ca VM or the prod Let's Encrypt endpoint
- The VM image contains no environment-specific ACME configuration
- The step-ca root CA is delivered via CIDATA `extra_ca_cert` to dev VMs (empty on prod). A generic extra-CA boot service augments the system trust store if the cert is present, and is a no-op if absent. See section 8.6.

**step-ca operational characteristics:**
- Smallstep step-ca with ACME provisioner, dns-01 challenge support
- Static root CA from `framework/step-ca/`, intermediate generated on first boot
- DNS resolver pointed at PowerDNS authoritative on port 8053 (same rationale as the prior Pebble deployment — avoids recursor negative cache poisoning)
- Certificate lifetime: 2160h (90 days, matching Let's Encrypt production)
- Listens on port 14000 (port is delivered via CIDATA ACME URL)
- No precious state (stateless — intermediate CA and database are regenerated from the static root on every VM recreation)
- NixOS module handles idempotent initialization: first boot generates intermediate and creates database; subsequent boots start normally; VM recreation reinitializes from the static root

**What step-ca enables testing of:**
- End-to-end ACME certificate issuance flow in dev
- certbot DNS-01 plugin configuration (correct TXT record name format, zone, TTL)
- PowerDNS API integration (certbot successfully creates and deletes challenge records)
- certbot writing challenges to both DNS servers in the environment
- Certificate renewal automation (systemd timer, expiration check, renewal trigger)
- vault-agent TLS verification against Vault (dev Vault has step-ca-issued cert, verified via system CA bundle with extra-CA — identical code path to prod where Vault has LE-issued cert verified via system CA bundle)
- The complete certificate → Vault → secrets chain, end to end

**What step-ca does not test:**
- Whether Let's Encrypt's external validators can reach your network (this is a network topology fact, not a configuration fact — it depends on firewall port 53 forwarding, which is identical for all prod DNS servers)

**Decision history:** The original implementation used Pebble (Let's Encrypt's official ACME test server). Pebble was replaced by step-ca in Sprint 005 after vault-agent exposed a fundamental incompatibility: Pebble's ephemeral CA made it impossible for dev VMs to verify TLS certificates issued by Pebble without environment-specific runtime workarounds. step-ca's static CA eliminated this class of problem entirely.

### 8.5 ACME Modes: Production, Staging, and Internal

The ACME server used for certificate issuance is configurable via
`config.yaml → acme` to support different stages of the operator's journey:

| Mode | `acme:` value | Prod certs from | Dev certs from | Requires domain? | Requires public DNS? | Rate limits |
|------|--------------|-----------------|----------------|-----------------|---------------------|-------------|
| **production** | `production` | Let's Encrypt | step-ca | Yes | Yes (NS delegation + port 53 forwarding) | 50 certs/domain/week |
| **staging** | `staging` | LE staging | step-ca | Yes | Yes (same as production) | 30,000 certs/domain/week |
| **internal** | `internal` | step-ca | step-ca | No | No | None |

**Production mode** is the steady-state configuration. Real domain, public DNS
delegation, browser-trusted certificates from Let's Encrypt.

**Staging mode** uses Let's Encrypt's staging server for prod certificates.
The staging server validates identically to production (same DNS-01 challenge
flow, same public DNS requirements) but issues untrusted certificates with
generous rate limits. Use staging during active development, scorched-earth
testing, and domain migration — any period where frequent rebuilds would hit
production rate limits. Switching between staging and production is a single
config.yaml change followed by a redeploy; the only difference is which ACME
directory URL the VMs receive via CIDATA.

**Internal mode** uses step-ca for ALL certificates — both prod and dev
environments. No registered domain is required; `config.yaml → domain` can be
any name (`mylab.test`, `home.example`). No public DNS delegation, no port
forwarding, no registrar configuration. The entire cluster operates
self-contained. This mode is for operators who are evaluating the framework,
experimenting with network design, or running infrastructure that doesn't need
publicly trusted certificates.

**Operator journey:**

```
internal (experimenting) → staging (domain registered, testing DNS) → production (go-live)
```

Each transition is a config.yaml change + redeploy. The chain of trust, service
configuration, and operational procedures are identical across all three modes.

**Implementation status:**
- `production`: Implemented (current default)
- `staging`: Implemented (same as production with a different ACME directory URL)
- `internal`: Designed but not yet implemented. Requires placing step-ca on the
  management network (shared service) so prod VMs can reach it, and ensuring
  all services accept step-ca-issued certificates via the extra-CA mechanism.
  Deferred until the framework's public release, where it will significantly
  lower the barrier to entry.

**Rate limit protection:** `rebuild-cluster.sh` with `--override-branch-check`
automatically uses LE staging for certificate issuance, regardless of the
`acme` setting in config.yaml. This prevents repeated development rebuilds
from exhausting the LE production rate limit (5 duplicate certs per 168 hours
per identifier set). Normal pipeline deploys from the prod branch use the
configured ACME server.

### 8.6 TLS Trust Architecture

Services that verify TLS certificates must trust the CA that issued those
certificates. In a system with two ACME environments (Let's Encrypt for prod,
step-ca for dev), TLS trust must work correctly on both environments without
environment-specific runtime logic in the VM.

This architecture emerged from three independent incidents that were all
manifestations of the same pattern — **stale trust**: a service caches a
trust anchor at one point in time, and the thing it trusts changes.

| Incident | Service | Trusted | Problem |
|----------|---------|---------|---------|
| vault-agent TLS failure | vault-agent → Vault cert | CIDATA CA file (wrong CA) | Pebble had two CAs; CIDATA contained the wrong one |
| LE rate limit exhaustion | certbot → LE | Cert on vda (destroyed on rebuild) | Every rebuild requested a new cert |
| Runner TLS failure | gitlab-runner → GitLab cert | Pinned CA from registration time | GitLab cert changed; pin went stale |

The general fix is a four-part trust architecture:

**1. System CA bundle as the trust source.** Services use the system CA
bundle — not pinned files, not per-service CA configs. The system bundle
includes well-known public CAs (including Let's Encrypt's ISRG Root X1).
On prod, this is sufficient. On dev, the bundle is augmented (see below).
vault-agent, certbot, and gitlab-runner all use the system bundle. No
`ca_cert`, no `tls-ca-file`, no `REQUESTS_CA_BUNDLE` pointing to custom files.

**2. Extra-CA augmentation via CIDATA.** For dev VMs, the step-ca root CA
is delivered via CIDATA `write_files` to `/run/secrets/extra-ca-cert`. A
generic NixOS boot service (`extra-ca.service`) reads this file, validates
it, and builds an augmented CA bundle (system bundle + extra cert). The
augmented bundle is placed where the system bundle was, so all programs
that use the system bundle automatically trust the extra CA. On prod, the
CIDATA field is empty, the service is a no-op, and the system bundle is
unmodified. The VM image is environment-ignorant — the service reacts to
the presence of the file, not to environment names.

**3. Certificate persistence on vdb.** TLS certificates acquired by certbot
are stored on vdb (the data disk that survives VM recreation and is backed
up by PBS). `/etc/letsencrypt` is symlinked to a directory on vdb for VMs
that have a data disk. On VM recreation, the cert survives. certbot-initial
sees the existing cert and exits 0 — no new certificate request, no rate
limit consumed. On VMs without vdb (DNS, Gatus, testapp), certs are on
vda and lost on recreation. This is acceptable: dev VMs use step-ca (no
rate limit), and prod data-plane VMs are rebuilt infrequently.

**4. LE staging as a development guardrail.** When `rebuild-cluster.sh`
runs with `--override-branch-check` (the DR/development path), it
automatically uses LE staging for certificate issuance. This prevents
repeated development rebuilds from exhausting the LE production rate
limit. Normal pipeline deploys use the configured ACME server.

These four mechanisms are layered defenses. Under normal operation (pipeline
deploys, infrequent rebuilds), layer 1 (system bundle) is sufficient. Layer
2 (extra-CA) handles the dev environment. Layer 3 (cert persistence)
prevents rate limit consumption on rebuild. Layer 4 (staging guardrail)
catches edge cases where layers 2 and 3 don't apply.

**Design principle:** No service should pin a trust anchor at deploy time.
Trust should come from the system CA bundle, augmented at boot from CIDATA
when needed. This ensures that cert renewals, CA rotations, and VM
recreations never break TLS verification for any service.

---

## 9. Secrets Management

### 9.1 Architecture: Hybrid SOPS + Vault

**Decision:** Use both SOPS and Vault for different purposes

**Options considered:**
- SOPS only (secrets as encrypted files in Git)
- Vault only (all secrets in Vault)
- Hybrid (SOPS for bootstrap, Vault for runtime)

**Motivations:**
- **SOPS enables disaster recovery:** Can rebuild from Git + operator key, no chicken-and-egg
- **Vault enables dynamic secrets:** Database passwords auto-rotate, generated on demand
- **Clear separation:** Infrastructure secrets (bootstrap) vs application secrets (runtime)
- **Audit logging:** Vault provides "who accessed what when" for compliance/debugging
- **Fine-grained access:** Vault policies more flexible than SOPS re-encryption
- **No secrets in Git history:** Application secrets never committed (even encrypted)
- **Both have value:** SOPS for simplicity/reliability, Vault for features/security

### 9.2 SOPS (Infrastructure Bootstrap Secrets)

**Stored in Git, encrypted with operator age key:**

SOPS stores two categories of secrets with different operational roles:

**Pre-deploy secrets (consumed by TF_VAR, delivered via CIDATA write_files):**
- Proxmox API credentials (OpenTofu needs to create VMs)
- SSH public key — framework/CI key (for CI runner access to VMs)
- OpenTofu PostgreSQL password (state backend access)
- PowerDNS API key (for certbot DNS-01 challenges)

**On-demand pre-deploy secrets (consumed by TF_VAR, auto-generated when needed):**
- InfluxDB admin token — random hex, given to InfluxDB during initial setup
- Grafana InfluxDB token — random hex, used to configure Grafana's datasource

These are pre-deploy secrets (they must exist before `tofu apply`
generates CIDATA), but they are NOT generated by `bootstrap-sops.sh`.
They are generated **on demand** by the deploy pipeline when an
application is first enabled in config.yaml. A pre-apply step in
`rebuild-cluster.sh` (or `tofu-wrapper.sh`) checks config.yaml for
enabled applications, checks SOPS for their required keys, and
generates any missing ones (write-once — existing values are never
overwritten).

This is the correct lifecycle because `bootstrap-sops.sh` runs once
during initial setup. An operator who enables InfluxDB six months later
should not have to re-run `bootstrap-sops.sh` — the deploy pipeline
generates the token automatically the first time it's needed.

**Workstation-onboarded pre-deploy secrets (consumed by TF_VAR, but NOT generated by the pipeline):**
- Catalog app Vault AppRole role_id / secret_id pairs

These secrets also must exist before `tofu apply`, but they are created by
the operator from the workstation rather than by the pipeline. The reason is
structural: AppRole onboarding needs to write new SOPS entries, and the
pipeline deliberately does not have write access to SOPS. The pipeline and
`safe-apply.sh` therefore run a preflight check and fail fast when a manifest-
backed catalog app is enabled without its AppRole credentials. The operator
then runs `rebuild-cluster.sh --scope onboard-app=<name>` to create the
AppRole in Vault, commit the new SOPS entries locally, and push them
manually. After that push, normal pipeline deploys resume.

| Category | Generated by | When | Examples |
|----------|-------------|------|----------|
| Bootstrap pre-deploy | `bootstrap-sops.sh` | Once, during initial setup | `pdns_api_key`, `proxmox_api_password`, `tofu_db_password` |
| On-demand pre-deploy | Pre-apply step in deploy pipeline | When an application is first enabled | `influxdb_admin_token`, `grafana_influxdb_token` |
| Workstation-onboarded pre-deploy | `rebuild-cluster.sh --scope onboard-app=<name>` | When a catalog app first needs Vault AppRole bootstrap credentials | `vault_approle_influxdb_dev_role_id`, `vault_approle_influxdb_prod_secret_id` |
| Post-deploy | The install/init script for the service | After the service is deployed | `pbs_root_password`, `vault_*_unseal_key`, `gitlab_root_password` |

**Post-deploy secrets (backup copies only, NOT consumed by TF_VAR):**
- Vault unseal key and root token — **write-once in SOPS.** Both are
  produced by the same `vault operator init` call and stored together.
  The unseal key is permanent (derived from Vault's master key), and the
  root token is valid for that Vault instance's lifetime. Primary copy of
  the unseal key is on Vault's vdb (`/var/lib/vault/unseal-key`), delivered
  by `init-vault.sh` via SSH. SOPS copies are for disaster recovery.
  `init-vault.sh` writes to SOPS only when Vault is freshly initialized
  (uninitialized API response). If SOPS entries already exist, they match

- PBS root password — **write-once in SOPS.** Written by `install-pbs.sh`
  after successful PBS installation (set to match the Proxmox API
  password). Used by `configure-pbs.sh` for `sshpass` connections to PBS.

**SSH keys: two credentials with different roles.**

Two SSH keys are installed on all managed hosts (Proxmox nodes, PBS, NixOS VMs):

| Key | Source | Installed on nodes by | Installed on NixOS VMs by | Installed on PBS by | Purpose |
|-----|--------|-----------------------|--------------------------|--------------------|---------| 
| Operator workstation key | `config.yaml` `operator_ssh_pubkey` | `configure-node-network.sh` | CIDATA `ssh_authorized_keys` | `configure-pbs.sh` | Operator SSH from workstation |
| Framework/CI key | SOPS `ssh_pubkey` / `ssh_privkey` | `configure-node-network.sh` | CIDATA `ssh_authorized_keys` | `configure-pbs.sh` | CI runner SSH for automated operations |

Both keys are installed on every managed host. The operator's key is
stable — it lives in `~/.ssh/` and in `config.yaml`, and doesn't change
when `bootstrap-sops.sh` generates fresh secrets. The SOPS key changes on
Level 5 rebuilds but is only used by the CI runner (which gets the private
key from SOPS/Vault).

**Why two keys, not one:** On a Level 5 rebuild, `bootstrap-sops.sh`
generates a fresh SOPS keypair. If scripts assumed the operator's
`~/.ssh/id_rsa` matched the SOPS key, they would fail. With two explicit
keys, the operator's key is always available for workstation SSH, and the
SOPS key is always available for CI SSH, regardless of whether secrets
were regenerated.

**Initial connection bootstrap:** Fresh Proxmox nodes and PBS VMs only
have password auth. `configure-node-network.sh` and `configure-pbs.sh`
use `sshpass` with the root password from SOPS for the initial connection,
install both keys, then subsequent connections use key auth. This
two-phase model (password → key) is the standard bootstrap pattern for
Proxmox nodes and PBS.

NixOS VMs receive both keys via CIDATA `ssh_authorized_keys` at creation
time — no password phase needed.

**The `operator_ssh_pubkey` field is in config.yaml, not SOPS.** It's a
public key — no encryption needed. It's site-specific (different
operators have different keys), so it belongs in config.yaml alongside
other operator-specific values. Changing it triggers VM recreation
(CIDATA content change), which is correct — the new key needs to be
installed on every VM.
  the current Vault instance — do not overwrite.
- GitLab runner registration token — used by `register-runner.sh` during
  registration, not stored on the runner VM.
- GitLab root password — for operator login, not stored on any VM.

The distinction matters for idempotency: pre-deploy secrets feed into CIDATA
(a VM creation input). If they change, VMs are recreated. Post-deploy secrets
are backup copies — changes to them have zero effect on `tofu plan`. See
section 11.1.1 for the full rationale.

**Tool:** SOPS with age encryption

**Access:** Operator's age key required to decrypt

**The age private key is the only secret that cannot be stored in the repository.**
It is the encryption root — by definition it cannot be encrypted with itself. Every
other secret in the system is either encrypted in `site/sops/secrets.yaml` and
unlockable with the age key, or derivable (generated fresh during a rebuild, then
immediately encrypted and committed without the operator handling the plaintext).
This means the full-rebuild procedure requires exactly one human input beyond
site-specific configuration: the age private key.

**Backup:** Git repository is the backup

**Bootstrap secret rotation:**

Bootstrap-tier secrets are long-lived by design (they must be available before Vault, so they can't use Vault's dynamic rotation). Rotation is a manual, planned operation:

| Secret | Rotation procedure | Blast radius |
|--------|--------------------|-------------|
| PowerDNS API key | Generate new key, update SOPS, deploy to DNS VMs, update certbot config on all VMs (rebuild images), verify cert issuance works | All VMs (cert renewal depends on this key) |
| Proxmox API credentials | Change in Proxmox UI, update SOPS, update OpenTofu provider config | CI/CD and Mac OpenTofu — VMs are unaffected |
| OpenTofu PostgreSQL password | Change in PostgreSQL on NAS, update SOPS, update OpenTofu backend config | CI/CD and Mac OpenTofu only |
| Vault unseal key | `vault operator rekey`, deliver new key to vdb via SSH, update SOPS backup, commit to Git | Vault restart only |
| Vault root token | Revoke old token via Vault API, `vault operator generate-root` to create new one, update SOPS, commit to Git. Alternatively, re-initialize Vault (generates both new key and token). | `configure-vault.sh`, any SOPS consumer using the token |
| Operator age key | Generate new key, re-encrypt all SOPS files with new key (`sops updatekeys`), commit to Git | All SOPS consumers (CI/CD, Mac) |
| SSH keys (framework/CI) | Generate new keypair, update SOPS, rebuild VM images (CIDATA change). CI runner uses this key — operator workstation key is unaffected. | All VMs (on next image rebuild), all nodes and PBS (on next configure script run) |
| SSH keys (operator) | Generate new workstation keypair, update `operator_ssh_pubkey` in config.yaml, rebuild VM images (CIDATA change), re-run `configure-node-network.sh` and `configure-pbs.sh` | All managed hosts |
| PBS root password | Change on PBS (`passwd root`), update SOPS, verify `configure-pbs.sh` can connect | `configure-pbs.sh`, `configure-backups.sh` |

Rotation frequency is driven by risk assessment, not a fixed schedule. For a single-operator infrastructure, annual rotation of bootstrap secrets is reasonable unless a compromise is suspected.

### 9.3 Vault (Application Runtime Secrets)

**Stored in Vault, accessed at runtime:**
- Database passwords (dynamic, auto-rotating)
- API keys for services
- Inter-service authentication tokens
- Application-specific credentials

**Location:** Inside Proxmox cluster (managed by OpenTofu), one instance per environment.

**Motivations for cluster location:**
- SOPS handles disaster recovery (don't need Vault outside cluster)
- Simpler architecture (NAS only does durable storage, cluster does compute)
- Cluster HA benefits Vault VM
- Vault is for runtime, not bootstrap

**Decision: Single instance per environment (no multi-instance Raft cluster)**

Vault runs as a single VM per environment, protected by Proxmox HA. This is a deliberate choice, not an oversight.

**Why Vault does not need app-level redundancy (unlike DNS):**
- DNS is in the hot path of every network operation — every connection, every service discovery, every TLS handshake involves a DNS query. Even a brief DNS outage causes cascading failures across all services immediately. This is why DNS has two instances per environment.
- Vault is queried periodically — at VM boot, on secret rotation, and on token renewal. Between these events, vault-agent caches secrets locally. A brief Vault outage (~15s for VM crash, <2 min for node failure) is invisible to any VM that already has valid cached secrets. The only impact is on VMs that happen to be bootstrapping or rotating secrets during the outage window, and they retry after Vault comes back.

**Why multi-instance Vault is not justified:**
- Raft consensus requires a minimum of 3 instances for any redundancy benefit (quorum of 2 out of 3). Two instances cannot form a quorum if one fails. This means the jump from 1 to redundant is 3 Vault VMs per environment, 6 total — a significant resource and complexity cost.
- Multi-instance Vault adds operational complexity: each instance needs its own certificate, its own storage, Raft peer discovery, leader election, and care around rolling upgrades to avoid quorum loss.
- The failure scenarios where multi-instance Vault provides benefit over single-instance with Proxmox HA (sub-second failover, thundering herd from hundreds of simultaneous clients, zero-downtime secret rotation) do not apply to a small cluster with a handful of VMs.
- Data corruption is not mitigated by Raft replication — corruption propagates to all replicas. The recovery path (restore from PBS backup) is the same regardless of instance count.

**Accepted trade-off:**
- During an unplanned node failure, Vault is unavailable for up to ~2 minutes (measured: <120s for HA migration + boot + auto-unseal). VMs with cached secrets are unaffected. VMs bootstrapping during this window must retry. This is acceptable for clusters at this scale.
- During planned maintenance, Vault is unavailable for 10–20 seconds (planned migration). Same impact, shorter window.

**Storage backend:** Integrated storage (Raft)

**Motivations:**
- Designed for Vault, no external dependency (self-contained)
- With a single instance, Raft functions as a local write-ahead log (no distributed consensus needed)
- If multi-instance Vault is ever desired (not currently planned), Raft supports it without changing the storage backend

**Unseal strategy:** Auto-unseal from persistent storage

Vault auto-unseals on boot by reading the unseal key from `/var/lib/vault/unseal-key`
on vdb (persistent across VM reboots and HA failover). The key is placed there by
`init-vault.sh` via SSH during initial deployment. SOPS stores a backup copy of the
key for disaster recovery, but the SOPS copy does NOT flow into CIDATA — see
section 11.1.1 for why post-deploy secrets must not be in CIDATA.

**Vault secrets in SOPS are write-once:**

The unseal key and root token are both produced by the same `vault operator init`
call and stored together in SOPS. Both are write-once — `init-vault.sh` writes
them only when Vault is freshly initialized (uninitialized API response). If
SOPS entries already exist, they correspond to the current Vault instance and
must not be overwritten.

| Secret | Stored on vdb? | Stored in SOPS? | Written when |
|--------|---------------|-----------------|-------------|
| **Unseal key** | Yes (`/var/lib/vault/unseal-key`) | Yes (backup) | `vault operator init` (fresh Vault only) |
| **Root token** | In Raft data (not a separate file) | Yes (backup) | `vault operator init` (fresh Vault only) |

**Why this works for PBS restore:** When Vault's vdb is restored from PBS,
the Raft data contains the unseal key and root token from the original
initialization. SOPS also has these values (write-once — never overwritten
by subsequent rebuilds). Since both came from the same `vault operator init`,
they match. `init-vault.sh` detects "already initialized," unseals with the
SOPS key, and `configure-vault.sh` authenticates with the SOPS root token.

**When the invariant breaks:** If secrets are regenerated (e.g., via
`bootstrap-sops.sh` during Level 5 recovery) but PBS restores a vdb from
a previous secret generation, the Raft data contains tokens from the old
`vault operator init` that don't match the new SOPS tokens. `init-vault.sh`
detects this via HTTP 403 on `/v1/auth/token/lookup-self` and auto-recovers:

1. Wipes `/var/lib/vault/data/*` (Raft data only — preserves TLS certs
   at `/var/lib/vault/tls/`)
2. Removes stale `unseal-key` and `root-token` from vdb
3. Restarts Vault (now uninitialized, but with valid TLS certs)
4. Falls through to normal initialization (generates new Raft data
   matching the current SOPS tokens)

This auto-recovery is always safe because Vault holds no state that
cannot be regenerated from SOPS — all policies are loaded by
`configure-vault.sh`, all runtime secrets are injected from SOPS, and
TLS certificates are re-acquirable from ACME. The Raft data is purely
internal consensus state.

**Motivations:**
- Enables full automation (Vault can restart without human)
- Disaster recovery preserved (backup copy of unseal key in SOPS)
- No external dependency (no cloud KMS needed)
- Acceptable security (vdb key protected by Proxmox access controls; SOPS backup
  encrypted with operator key)
- No recreation cycle (unseal key is not in CIDATA, so `tofu apply` doesn't
  recreate the VM when the key changes)

**Authentication:** TLS certificate-based (planned), SOPS-only bootstrap (current)

**Intended design — TLS certificate auth:**
- Reuses existing identity (VMs already get TLS certs from Let's Encrypt)
- Reduces key proliferation (no separate Vault Secret IDs)
- Simpler bootstrap (no Secret ID to inject via cloud-init)
- Strong binding (certificate CN — Common Name — maps to hostname/role)
- Automatic rotation (cert renewal handled by certbot)

**Known limitation — Vault cert auth incompatible with ACME certificates:**

Vault's TLS certificate auth method (`auth/cert`) uses the certificate's
`Subject.CommonName` (CN) field as the entity alias name. When the CN is empty,
Vault rejects the login with `"missing name in alias"`. Modern ACME CAs —
including Let's Encrypt and step-ca — issue certificates with an empty CN and
place the domain name only in the Subject Alternative Name (SAN) extension. This
is compliant with RFC 5280, which deprecated CN in favor of SANs.

This means Vault cert auth is incompatible with ACME-issued certificates in all
Vault versions up to and including 1.21.2. This is tracked upstream as Vault
GitHub issues #6820, #14432, and #23268 — all open with no merged fix.

**Current approach — SOPS bootstrap only:**

Until Vault cert auth supports SAN-based identity (or a private CA is deployed
that issues certificates with CN populated), all secrets are delivered via the
SOPS → OpenTofu → nocloud-init `write_files` → `/run/secrets/` path. vault-agent
is not deployed. Vault is initialized, auto-unsealing, and ready to serve, but no
VMs authenticate to it at runtime.

This is acceptable because:
- The SOPS bootstrap path already works and is proven
- No current service has secrets that require runtime rotation from Vault
- Dynamic database credentials (the primary Vault payoff) are not needed until
  application databases are added in later steps
- Vault is fully deployed and ready for immediate activation when the limitation
  is resolved

See section 13.2 step 11 for how this deferral affects the rebuild sequence.

**Activation path (when the limitation is resolved):**

Vault cert auth activation is gated on one of:
1. **Vault upstream fix:** HashiCorp ships a Vault version that supports
   SAN-based entity aliases (resolving issue #6820). At that point, enable cert
   auth, configure CN/SAN-based roles, deploy vault-agent to VMs.
2. **Vault PKI secrets engine:** Deploy Vault's built-in PKI secrets engine to
   issue machine identity certificates with CN populated. VMs would have two
   certificate sets: ACME certs for TLS (services), PKI certs for Vault auth
   (identity). This could be added as a later step.
3. **AppRole fallback:** If runtime secrets become urgently needed before the
   above options are available, AppRole auth can be implemented using the
   existing nocloud-init delivery mechanism for role_id and secret_id.

**How it will work (once activated):**
1. VM gets TLS certificate from Let's Encrypt (or Vault PKI)
2. VM authenticates to Vault using TLS cert
3. Vault validates cert (signed by trusted CA, CN/SAN matches expected pattern)
4. Vault maps cert identity to role (e.g., `dns1.prod.example.com` → role `dns`)
5. Vault returns token based on role policies
6. VM requests secrets using token

**Policies in Git:**
```hcl
# policies/postgres-role.hcl
path "secret/data/postgres/*" {
  capabilities = ["read"]
}

path "database/creds/postgres-admin" {
  capabilities = ["read"]  # Dynamic credentials
}
```

**Threat model for TLS cert auth:**

Using Let's Encrypt certificates as Vault identity tokens is appropriate for a single-operator infrastructure. The threat model acknowledges the following:

*What an attacker would need to impersonate a VM to Vault:*
- Obtain a valid TLS certificate with a CN matching an allowed role pattern (e.g., `dns1.prod.example.com`)
- This requires either: compromising the PowerDNS API key (to create DNS-01 challenges), compromising the domain registrar (to point nameservers elsewhere), or compromising Let's Encrypt itself
- The PowerDNS API key is the most realistic attack vector. It is protected by SOPS encryption and is only present on VMs that run certbot.

*Mitigations:*
- Vault cert auth roles use strict CN pattern matching (not wildcards). A cert for `random.prod.example.com` would not match any role unless explicitly configured.
- Vault policies follow least privilege — each role only accesses its own secrets. Compromising one VM's identity does not grant access to other VMs' secrets.
- Vault audit logging records all authentication attempts and secret accesses, enabling detection of unauthorized access.
- Token TTLs are short (24h), limiting the window of a compromised token.

*Accepted risks:*
- An attacker with the PowerDNS API key could potentially obtain certificates for any hostname in the zone. This is mitigated by the key being in SOPS (encrypted at rest) and only deployed to VMs that need it.
- This threat model does not protect against a compromised operator workstation (which has the SOPS key, SSH access, and OpenTofu credentials). That's an acceptable boundary for a single-operator infrastructure.

**Certificate renewal and Vault token lifecycle (when vault-agent is activated):**

The following describes the intended behavior once vault-agent is deployed (see
"Known limitation" above for why this is deferred):

certbot and vault-agent operate independently:
- certbot renews the TLS certificate when it's <30 days from expiration (90-day certs, 60-day renewal window)
- vault-agent manages its own Vault token with a shorter TTL (e.g., 24h)
- vault-agent re-authenticates to Vault using the current TLS cert whenever the token expires or the cert file changes on disk
- When certbot writes a new certificate, vault-agent detects the file change, re-authenticates with the new cert, and obtains a fresh token
- No service restart is required — vault-agent watches the certificate file path and handles rotation automatically
- During the brief window when certbot is replacing the cert file (seconds), vault-agent's existing token remains valid — there is no authentication gap

See Appendix E, Contract 4 for the detailed CN → role mapping and enforcement mechanics.

### 9.4 Secrets Injection into Applications

**Two delivery mechanisms, determined by when the secret is known:**

**Pre-deploy secrets (known before VM exists):** delivered via CIDATA write_files.
```
SOPS → tofu-wrapper.sh (decrypts) → TF_VAR_* → OpenTofu
  → nocloud-init write_files → /run/secrets/<app>/<file>
  → Application reads on startup
```
Examples: PowerDNS API key, ACME server URL, forward-zone domain.

**On-demand pre-deploy secrets (generated before VM exists, when application
is first enabled):** same delivery mechanism as pre-deploy secrets.
```
config.yaml (app enabled) → pre-apply check → SOPS key missing?
  → generate random token → write to SOPS (write-once)
  → tofu-wrapper.sh (decrypts) → TF_VAR_* → CIDATA write_files
```
Examples: InfluxDB admin token, Grafana InfluxDB token. These are
arbitrary random values — the application accepts whatever is provided
during initial setup. Generated on demand so that enabling an application
in config.yaml doesn't require re-running `bootstrap-sops.sh`.

**Post-deploy secrets (generated after VM boots):** delivered via SSH to vdb.
```
Post-deploy script (init-vault.sh, register-runner.sh)
  → generates or retrieves secret → SSH to VM
  → writes to persistent storage on vdb (/var/lib/<app>/<file>)
  → Application reads on startup
  → SOPS stores a backup copy (not consumed by TF_VAR)
```
Examples: Vault unseal key, GitLab runner token.

The post-deploy path exists because these secrets cannot be in CIDATA without
creating a VM recreation cycle (see section 11.1.1). The primary copy lives
on the VM's vdb (persistent across reboots). The SOPS copy is for disaster
recovery — if vdb is lost, the operator can re-run the post-deploy script
or restore from SOPS.

**Intended method (when vault-agent is activated):** vault-agent writes files,
applications read from filesystem

**Pattern (future — runtime secrets):**
```
Vault → vault-agent → /run/secrets/myapp/config
                    ↓
              Application reads on startup
```

**For Nix-native services:**
```nix
systemd.services.myapp.serviceConfig.EnvironmentFile = "/run/secrets/myapp/env";
```

**For containerized services:**
```yaml
services:
  myapp:
    env_file: /run/secrets/myapp/env
```

**Motivations (for the vault-agent path, when activated):**
- Works for both deployment models (Nix-native and containers)
- Standard pattern (environment files, mounted secrets)
- Vault can rotate secrets and trigger service restarts

---

## 10. OpenTofu State Management

### 10.0 IaC Tool Choice: OpenTofu

**Decision:** OpenTofu (the open-source fork of Terraform under MPL 2.0)

**Options considered:**
- Terraform (HashiCorp, BSL license)
- OpenTofu (Linux Foundation, MPL 2.0 license)
- Pulumi (general-purpose programming languages instead of HCL)

**Motivations:**
- **Open-source alignment:** This system is designed to be fully self-hosted with no external dependencies. OpenTofu's MPL 2.0 license and Linux Foundation governance guarantee it remains open-source with no single vendor able to change terms.
- **Drop-in compatibility:** OpenTofu forked from Terraform 1.6.x and maintains HCL syntax, CLI workflow (`tofu init/plan/apply`), provider ecosystem, and module compatibility. All Terraform documentation, tutorials, and provider docs apply directly.
- **Native state encryption:** OpenTofu supports encrypting state files at rest without additional tooling. State files contain sensitive data (resource IDs, interpolated secrets, infrastructure topology). While the PostgreSQL backend is on a private network, native encryption provides defense in depth.
- **Community-driven governance:** Feature prioritization is community-influenced rather than driven by a single vendor's commercial priorities.

**Terraform compatibility note:** The HCL configuration files use `terraform {}` blocks (not `opentofu {}`), and OpenTofu's working directory is still named `.terraform/`. This is intentional backward compatibility in OpenTofu's design. The project directories themselves are named `site/tofu/` and `framework/tofu/` to avoid confusion with the tool name.

**CLI reference:** Throughout this document and the implementation plan, `tofu` is used for all CLI commands. `terraform` can be substituted directly if using Terraform instead.

### 10.1 State Backend

**Decision:** PostgreSQL on NAS

**Options considered:**
- Local state file on Mac
- Git-committed state (encrypted with SOPS)
- S3-compatible backend (Minio)
- PostgreSQL backend
- State inside cluster

**Motivations:**
- **State locking required:** CI/CD will run OpenTofu, need to prevent concurrent applies
- **NAS is outside cluster:** Enables disaster recovery (state available when cluster is down)
- **Single service:** PostgreSQL handles both storage AND locking (vs Minio requiring separate DynamoDB)
- **Native package on NAS:** Reliable, well-supported, no Docker dependency
- **Will use Postgres anyway:** Likely needed for other services, shares infrastructure
- **Simple backup:** Standard Postgres backup tools, integrates with NAS backup tools

**Implementation:**
```hcl
terraform {
  backend "pg" {
    conn_str = "postgres://tofu:password@rs2423.prod.example.com/tofu_state"
    schema_name = "prod"  # or "dev" for dev environment
  }
}
```

**Access:**
- CI/CD VM: Network connection to NAS PostgreSQL
- Mac (disaster recovery): Same connection string

### 10.2 CI/CD Location

**Decision:** CI/CD runs inside Proxmox cluster

**Options considered:**
- CI/CD on NAS (outside cluster)
- CI/CD inside Proxmox cluster
- CI/CD on external cloud (GitHub Actions, etc.)

**Motivations:**
- **Normal operations efficiency:** CI/CD runs where the infrastructure is
- **Disaster recovery still possible:** OpenTofu state on NAS means you can run OpenTofu from Mac to rebuild
- **No circular dependency:** State being off-cluster breaks the circle
- **Simplicity:** One place to manage VMs (the cluster), NAS just stores state
- **Network access:** CI/CD has direct access to internal resources without VPN/tunneling

**CI/CD is inside the cluster it manages.** This means a cluster-level failure can take down CI/CD. This is accepted because the Mac fallback exists and is always available.

**CI/CD system choice:** GitLab (self-hosted). GitLab provides both Git repository hosting and CI/CD pipelines in a single system, eliminating the need for a separate Git host. Pipelines are defined in `.gitlab-ci.yml` (YAML in Git, Category 2). The GitLab Runner executes jobs and runs as a separate NixOS VM. The CI/CD system is specified in `site/config.yaml` (GitLab URL, runner tags). The architectural requirements are:
- Runs as a NixOS VM inside the cluster (standard image pipeline)
- Authenticated to Proxmox API (for image upload, VM management)
- Authenticated to Vault (for runtime secret access during deployments)
- Reads OpenTofu state from PostgreSQL on NAS
- Decrypts SOPS secrets (needs access to operator age key or a CI-specific age key)
- No precious state on the CI/CD VM itself (Category 1 — fully rebuildable)

**CI/CD credential model (preventing "god token"):**
- CI/CD authenticates to Vault like any other VM (TLS cert auth), receiving a token scoped to a `cicd` role
- The `cicd` Vault policy grants access only to the secrets CI/CD needs (Proxmox API creds, PowerDNS API key, deployment-specific secrets) — not all secrets in Vault
- SOPS decryption uses a CI-specific age key (not the operator's personal key). This key is itself stored in Vault (accessible via the `cicd` role) or injected via cloud-init from SOPS during VM creation
- OpenTofu state access uses a dedicated PostgreSQL user with access only to the state schemas
- Each credential is scoped to its purpose — CI/CD does not have a single "god token" that grants access to everything

**CI/CD runner SSH access:** The runner needs SSH access to Proxmox nodes
(for image upload) and NixOS VMs (for post-deploy operations like vault
init, replication cleanup). The framework/CI key from SOPS is installed
on all managed hosts — Proxmox nodes (by `configure-node-network.sh`),
NixOS VMs (via CIDATA `ssh_authorized_keys`), and PBS (by
`configure-pbs.sh`). The runner extracts the SOPS private key to
authenticate. See section 9.2 for the two-key model.

### 10.3 Two-Tier Deployment Model

This section describes the implementation of convergence in this system.
There are two convergence mechanisms (per Goal 19): the GitLab pipeline
running in the cluster, and operator-invoked scripts running on the
workstation. Each mechanism is responsible for a distinct class of
operation. Both must produce equivalent cluster state from the same git
ref (Goal 19), and both must contain the logic for every desired-state
transition the system supports (Goal 18).

The two-mechanism design is not a workaround or a limitation — it is a
fundamental property of a self-hosted CI/CD system. The pipeline runs
on infrastructure that it cannot safely redeploy, so that infrastructure
is managed by a different mechanism.

**The two mechanisms have non-overlapping responsibilities.** cicd
handles all normal forward progressions: a sprint adds capability, the
code lands on dev, gets tested, gets promoted to prod via MR merge. The
pipeline builds images, applies state, restores precious data, and the
cluster advances from old code with valid state to new code with valid
state without operator intervention. This is the common case. The
workstation handles DR-shaped operations: cluster from scratch, cluster
damaged beyond cicd's ability to recover, and transitions cicd was not
designed for. `rebuild-cluster.sh` is the primary workstation tool.
These cases should be rare.

Two failure modes are forbidden by this model.

The first: a sprint that requires a manual operator step to complete the
forward progression — for example, a backfill script that must be invoked
before cicd can deploy the new state. This is a Goal 18 violation against
the cicd mechanism. The desired-state transition is incomplete; cicd
cannot produce the new state from the prior state autonomously. Sprint
026's cert-storage-backfill is an instance: the script is correct, but
because it requires operator invocation rather than running as part of
cicd's deploy stages, prod cannot be brought to the post-Sprint-026
state through a normal pipeline run. The fix is to embed the backfill
as an idempotent step in cicd that detects whether it has already
completed and runs only when needed.

The second: a sprint that adds a step to one convergence mechanism but
not the other. This is a Goal 19 violation — the two mechanisms diverge
in capability, and the cluster state becomes a function of which
mechanism last ran. A sprint that adds a `deploy:*` step in the pipeline
must add the equivalent step to the workstation convergence path
(typically a new convergence step in the shared library that
`rebuild-cluster.sh` invokes). A sprint's definition of done covers both
mechanisms.

**Tier 1: Data-plane VMs — deployed by the pipeline**

These are the VMs that provide services to the environments. The pipeline can
safely destroy and recreate them because doing so does not affect the pipeline
itself.

The pipeline flow for data-plane changes (the common case):
```
Push to dev branch (or MR merge to dev):
  → validate stage: source filter lint, tofu plan, config checks
  → build stage: build ALL NixOS images (including control-plane, to verify)
  → upload stage: upload images to Proxmox nodes (skip if unchanged)
  → deploy stage: tofu apply targeting dev-environment data-plane VMs only
  → deploy stage: post-deploy.sh dev (replication cleanup, vault recovery,
    backup job configuration — see below)
  → validate stage: validate.sh --regression-safe dev

MR merge to prod branch (after dev validation):
  → validate stage: source filter lint, tofu plan, config checks
  → build stage: build ALL images (cache hit — same images as dev)
  → upload stage: upload images (skip — already present from dev pipeline)
  → deploy stage: tofu apply targeting prod-environment data-plane VMs only
  → deploy stage: post-deploy.sh prod
  → validate stage: validate.sh --regression-safe prod

MR pipeline (any MR, before merge):
  → validate stage: source filter lint, config checks
  → build stage: build ALL images (verifies build)
```

**`post-deploy.sh`** runs after every `tofu apply` and handles the operational
steps that are always required after a deployment:
- `configure-replication.sh "*"` — cleans orphan zvols from any recreated VMs,
  waits for initial replication sync to complete
- Vault recovery — detects vault state (uninitialized, sealed, or healthy) and
  handles each case: initializes if new, unseals if sealed, configures policies
  in all cases. Reads the root token from vdb (not SOPS) for fresh inits, or
  accepts it via environment variable for pipeline use
- `configure-backups.sh` — ensures PBS backup jobs exist for VMs with precious state

This eliminates the manual post-deploy checklist for pipeline deployments. The
same steps are built into `rebuild-cluster.sh` for workstation deployments.

| Data-plane VM | Environment | Deployed by |
|---------------|-------------|-------------|
| dns1, dns2 | Dev | Dev pipeline (push to `dev`) |
| dns1, dns2 | Prod | Prod pipeline (merge to `prod`) |
| vault | Dev | Dev pipeline |
| vault | Prod | Prod pipeline |
| acme-dev (step-ca) | Dev | Dev pipeline |
| gatus | Prod | Prod pipeline |
| Application VMs | Per config | Corresponding environment pipeline |

**Tier 2: Control-plane VMs — deployed from the workstation**

These are the VMs that *run* the pipeline. Deploying them from the pipeline
would be self-destructive: recreating the runner kills the running job,
recreating GitLab kills the system hosting the job. They are updated manually
from the operator workstation using the same tools the pipeline uses
(`build-image.sh`, `upload-image.sh`, `tofu apply -target=...`).

Control-plane updates are infrequent — they happen when GitLab or the runner's
NixOS module changes, or when upgrading to a new GitLab version. They are
maintenance events, scheduled during quiet periods, same as updating a Proxmox
node.

**Control-plane deploys are high-blast-radius.** When a control-plane rebuild
fails mid-way (Step 9 crash, boot-time service failure, cert issue), the
operator loses the ability to push code, run pipelines, and file issues.
Recovery requires manual intervention on a system that is down, using only
the workstation and SSH — the normal development workflow is unavailable.
This is a fundamentally different risk class from data-plane failures, where
the pipeline and GitLab remain operational and the operator can push fixes
through the normal MR workflow.

**Rule: untested NixOS module changes must never be deployed directly to
control-plane VMs.** When a sprint modifies a NixOS module that affects a
control-plane image (gitlab.nix, cicd.nix, or any module they import),
deploy the change to a non-precious dev VM first and verify that all new
or modified systemd services reach `active` state. Only after live
verification should the change be deployed to control-plane. This applies
even when the change passes `nix build`, `nix-instantiate --parse`, and
code review — static checks cannot detect runtime failures such as missing
binaries, incorrect PATH, broken systemd dependency chains, or services
that call scripts not present in the nix store.

Multiple major NixOS module changes should not be deployed to control-plane
simultaneously. Each change should be deployed and verified independently.
A single boot-time failure in any module takes down the entire control-plane
VM, and diagnosing which of several changes caused the failure is harder
than diagnosing a single change.

The pipeline still *builds* control-plane images on every run. This verifies
that the control-plane NixOS modules build successfully from the current
commit. The pipeline also builds `nixosConfigurations` outputs that share
the same module list as the images (enforced structurally via `mkVmModules`
in `flake.nix`). These closures are the artifacts used for field updates.

**Three deployment modes for NixOS VMs:**

| Mode | Used by | Mechanism | Cost |
|------|---------|-----------|------|
| **Factory (pipeline)** | Data-plane VMs | `safe-apply.sh` creates VMs stopped, runs `restore-before-start.sh`, then starts/registers HA and runs post-success convergence. | ~5-15 min per VM, requires PBS restore for precious state |
| **Factory (workstation)** | DR rebuild, initial deploy | `rebuild-cluster.sh` uses the same stopped apply, preboot restore, start apply sequence, then converges via `converge_run_all`. | ~15-30 min for full cluster |
| **Field update (workstation)** | Control-plane VMs (gitlab, cicd) | Operator builds closure, runs `converge-vm.sh --closure <path>`. Copies closure, activates, reboots (overlay clears), converges. No VM recreation, no PBS restore. | ~2 min per VM |

The field update mode was added in Sprints 010-011 (Convergent Deploy
Phase 2). Control-plane VMs use the `proxmox-vm-field-updatable` tofu
module, which has `lifecycle { ignore_changes }` on disk and CIDATA
attributes — tofu sees no changes when image hashes change. Updates
are delivered via closure push instead of VM recreation.

| Control-plane VM | Normal update procedure | DR/initial deploy |
|-----------------|------------------------|-------------------|
| GitLab | `converge-vm.sh --closure <path> --targets "-target=module.gitlab"` from workstation. No destruction, no PBS restore, no runner re-registration. ~2 min. | `rebuild-cluster.sh` creates it stopped via OpenTofu, restores vdb before start, then registers the runner. |
| CI/CD runner | `converge-vm.sh --closure <path> --targets "-target=module.cicd"` from workstation. Runner config persisted under `/nix/persist/`. ~2 min. | `rebuild-cluster.sh` creates via tofu, runner re-registers. |
| PBS | Vendor appliance. `apt upgrade` or reinstall via `install-pbs.sh` + `configure-pbs.sh`. | `rebuild-cluster.sh` step 7.5. |

**Why field updates work for control-plane VMs:**

The overlay root (Sprint 010) makes every reboot a "factory fresh" boot —
the tmpfs overlay is cleared, `/etc` and `/var` are reconstructed from the
NixOS closure, and only `/nix`, `/boot`, and vdb mounts persist. A field
update (`nix copy` + `switch-to-configuration switch` + reboot) produces
the same post-boot state as a factory deploy of the same closure. The
convergence function runs identically after both paths.

The `proxmox-vm-field-updatable` tofu module (Sprint 011) prevents tofu
from recreating these VMs when image hashes change. Drift detection
(`check-control-plane-drift.sh`) compares the live closure on the VM
(`readlink -f /run/current-system`) against the `nixosConfigurations`
output (`nix eval --raw`), not the image hash. This correctly detects
"VM needs a field update" without triggering tofu recreation.

**How the pipeline deploys control-plane VMs (Sprint 013):**

The pipeline deploys gitlab and cicd via closure push, not tofu
recreation. The `deploy-control-plane.sh` script runs after data-plane
deployment:

1. Reads `build/closure-paths.json` (built alongside images)
2. For each control-plane VM, compares the built closure against the
   live closure on the VM (`readlink -f /run/current-system`)
3. If they match: skip (no-op, ~10 seconds)
4. If they differ: push the closure via `nix copy`, activate via
   `switch-to-configuration switch`, fix grub paths, reboot
5. Order: gitlab first, cicd second. If gitlab fails, cicd is not
   attempted

The runner self-update case: when cicd's closure is pushed, the runner
service restarts and the running job dies. GitLab's `retry.when:
[runner_system_failure]` dispatches a second attempt. The updated runner
picks up the retry, sees the closure is already active, skips, and the
job completes green.

The prod pipeline's `deploy-control-plane.sh prod` refuses to push a
closure that differs from what the dev pipeline deployed — the dev
pipeline always deploys first (dev→prod promotion model). The prod
pipeline's control-plane stage is a verification no-op.

- **PBS** remains a vendor appliance. It is not deployed by the pipeline.
  Installation is automated via ISO remastering — `install-pbs.sh`
  templates an `answer.toml` from config.yaml/SOPS, embeds it into a
  remastered PBS installer ISO, and the installer runs unattended (~90
  seconds). After installation, `configure-pbs.sh` registers the
  datastore and API token. See section 13.2 step 7.5 for details.

**Workstation as fallback:**

The workstation can perform any operation that the pipeline performs. If
CI/CD is down (cluster failure, GitLab broken, runner broken), the
operator runs the same commands from the Mac:

```bash
# Control-plane field update from workstation (normal recovery):
nix build .#nixosConfigurations.gitlab.config.system.build.toplevel
framework/scripts/converge-vm.sh --closure /nix/store/...-nixos-system-gitlab-... \
  --targets "-target=module.gitlab"

# Full manual deployment from workstation (DR / break-glass path):
framework/scripts/build-all-images.sh
framework/scripts/upload-all-images.sh
cd site/tofu && tofu apply -auto-approve
framework/scripts/validate.sh prod
framework/scripts/validate.sh dev
```

The workstation `converge-vm.sh --closure` path is the standard
recovery for a broken control-plane VM. The `tofu apply` path is the
factory rebuild for DR. Both work without the pipeline running.

**Branch-aware workstation deploys:**

`rebuild-cluster.sh` enforces the same branch model that the pipeline uses.
The pipeline deploys dev-environment VMs from the `dev` branch and
prod-environment VMs from the `prod` branch. The workstation must do the
same — deploying prod-affecting or control-plane scope from a non-prod branch
risks deploying unreviewed code to prod, bypassing the MR-based promotion gate.

`rebuild-cluster.sh` classifies every invocation by scope and enforces:

- Prod-affecting and shared control-plane scope require the `prod` branch
- Dev-only scope (`--scope vm=dns_dev,vault_dev`, etc.) is allowed from any branch
- `--override-branch-check` is the explicit escape hatch for disaster recovery
- Initial deploy (empty tofu state, no existing VMs in Proxmox, no `gitlab/prod`
  local ref, no PBS backups for configured VMIDs) is auto-detected and the
  branch check is skipped — the current checkout is definitionally correct when
  there is nothing to protect. The detection uses four signals checked in order
  of cost: `gitlab/prod` ref (zero-cost local git check), tofu state (PostgreSQL
  query), Proxmox VM probe (SSH), and PBS backup probe (SSH, parallel to all
  nodes). Any positive signal indicates an existing deployment. PBS unreachable
  is treated as neutral (not fail-closed), because PBS may not exist on a genuine
  first deploy. All other query failures are fail-closed.

This policy is enforced before Step 5 (image builds). A refused invocation
exits non-zero without touching the cluster.

**CIDATA and branch divergence (correction to earlier assumptions):**

`site/config.yaml` is part of the branch. CIDATA content — VM IPs, MACs,
VMIDs, DNS zone data, ACME server URL, Vault endpoints — is derived from
config.yaml via OpenTofu. It is not environment-ignorant in the same way that
NixOS images are. When dev and prod branches have diverged on config.yaml,
deploying prod VMs from the dev branch produces VMs with incorrect CIDATA for
the prod environment. This is how the March 2026 DNS outage occurred: dev
contained vault-agent code absent from prod, and a workstation rebuild from
the dev branch deployed it to prod DNS VMs, causing 28,000+ crash-loop restarts
and OOM-induced DNS failure.

NixOS VM *images* are environment-ignorant (the same content-addressed image
runs in both environments). CIDATA payloads are not — they carry
environment-specific values derived from whatever config.yaml is on the
currently checked-out branch.

**Layer 2: last-known-prod awareness:**

When `--override-branch-check` is used, the script provides situational
awareness to help the operator make a sound decision:

1. Attempts `git fetch gitlab` (5 second SSH timeout, fails gracefully when
   GitLab is down)
2. Compares the current commit against `gitlab/prod` and prints both hashes
   and dates
3. If they differ, warns that non-prod-branch code will reach prod VMs
4. If `site/config.yaml` differs between the commits, adds a specific CIDATA
   divergence warning
5. Prints post-DR reconciliation instructions at completion

Layer 2 is informational only — it never blocks execution.

**Provenance:**

Every `rebuild-cluster.sh` run writes `build/rebuild-manifest.json` recording
branch, commit, scope, impact, override status, git fetch result, and
last-known-prod comparison. This provides an audit trail of every workstation
deploy — what was deployed, from which branch, under what conditions.

**Post-DR reconciliation:**

After a rebuild with `--override-branch-check`, prod VMs may be running code
from the recovery branch rather than the prod branch. Reconciliation restores
the pipeline invariant:

1. Verify data integrity (`validate.sh`)
2. Push the recovery commit to GitLab dev branch: `git push gitlab HEAD:dev`
3. Create a dev→prod MR and merge it
4. Let the pipeline redeploy from the correct branches
5. Run `backup-now.sh` after the pipeline completes

Until reconciliation completes, prod VMs run the recovery branch code. This is
acceptable during recovery but must be resolved before treating the cluster as
fully consistent with the promoted prod branch.

**Why this model works:**

- **Most changes are data-plane.** DNS zone changes, application deploys, Vault
  policy updates, NixOS security patches to service VMs — these flow through the
  pipeline automatically, no workstation needed.
- **Control-plane changes are rare.** GitLab and the runner's NixOS modules change
  infrequently. When they do, the workstation update is a 5-minute operation.
- **The build stage catches control-plane regressions.** Even though the pipeline
  doesn't deploy control-plane VMs, it builds their images every run. A broken
  `gitlab.nix` is caught immediately, not weeks later when the operator tries
  to update GitLab.
- **No partial deployment risk.** The `-target` flags ensure the pipeline only
  touches what it can safely touch. A pipeline bug or misconfiguration cannot
  destroy GitLab or the runner.

**Failure during `tofu apply`:**
- If the CI/CD VM dies mid-apply (node failure, reboot), OpenTofu may leave a stale state lock in PostgreSQL on NAS. The next `tofu` run will fail with "state locked."
- Recovery: `tofu force-unlock <lock-id>` (from Mac or from the restarted CI/CD VM)
- Partial apply is not dangerous: OpenTofu is idempotent. Running `tofu apply` again converges to the desired state, creating resources that were missed and leaving already-created resources unchanged.
- This is a known OpenTofu operational characteristic, not specific to this architecture.

---

## 11. VM Image Creation and Deployment

### 11.0 VM Anatomy: The Four-Component Model

Every VM in the system is composed of four storage components with distinct
authorities, lifecycles, and recovery paths. Understanding this model is
essential for understanding how builds, deployments, failovers, backups, and
disaster recovery work — they all operate on different components of the same VM.

```
┌─────────────────────────────────────────────────────────────────┐
│                         VM at runtime                           │
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐  │
│  │   vda        │  │   CIDATA     │  │   vdb                 │  │
│  │   (root)     │  │   (ISO)      │  │   (data)              │  │
│  │              │  │              │  │                       │  │
│  │  NixOS image │  │  user-data   │  │  /var/lib/app         │  │
│  │  /nix/store  │  │  meta-data   │  │  /var/lib/vault       │  │
│  │  /boot       │  │  write_files │  │  databases, state     │  │
│  │  /etc        │  │              │  │                       │  │
│  └──────┬───────┘  └──────┬───────┘  └───────────┬───────────┘  │
│         │                 │                      │              │
└─────────┼─────────────────┼──────────────────────┼──────────────┘
          │                 │                      │
          ▼                 ▼                      ▼
   ┌──────────────┐  ┌──────────────┐  ┌───────────────────────┐
   │  Git commit   │  │  config.yaml │  │  PBS backup on NAS    │
   │  (Nix build)  │  │  (OpenTofu)  │  │  (NFS datastore)      │
   │              │  │              │  │                       │
   │  Authority:  │  │  Authority:  │  │  Authority:           │
   │  framework   │  │  operator    │  │  runtime (app data)   │
   │  code + nix  │  │  config      │  │                       │
   └──────────────┘  └──────────────┘  └───────────────────────┘

Off-cluster (NAS):
  ┌──────────────────┐  ┌──────────────────┐
  │  PostgreSQL       │  │  PBS datastore    │
  │  (OpenTofu state) │  │  (NFS mount)      │
  │                  │  │                  │
  │  Tracks what     │  │  Stores vdb       │
  │  OpenTofu has    │  │  backups for      │
  │  deployed        │  │  disaster recovery│
  └──────────────────┘  └──────────────────┘
```

**The four components:**

| Component | What it contains | Authority | Created by | Destroyed when |
|-----------|-----------------|-----------|------------|----------------|
| **vda** (root disk) | OS, packages, service binaries, boot config | Git commit (Nix build) for framework VMs; vendor image for appliances | `build-image.sh` → `tofu apply` (framework); manual ISO install (vendor) | Every image update for framework VMs; manual vendor upgrade for appliances |
| **CIDATA** (cloud-init ISO) | Hostname, SSH keys, bootstrap secrets, ACME URL, DNS zone data | config.yaml → OpenTofu | `tofu apply` (generated per-VM) | Every `tofu apply` that changes CIDATA content (triggers VM recreation). Not used by all vendor appliances (e.g., HAOS ignores cloud-init). |
| **vdb** (data disk) | Application state, databases, Vault Raft, certificates | The running application | `tofu apply` (creates empty zvol) | Intentional destruction only; preserved across image updates |
| **Off-cluster** (NAS) | OpenTofu state (PostgreSQL), PBS backup data (NFS) | OpenTofu, PBS | `tofu init`, PBS backup jobs | Survives complete cluster loss (durability anchor) |

**Two classes of VM:**

The lifecycle model differs based on whether the framework controls the VM image:

| | Framework VMs (Category A/B) | Vendor appliances (Category C) |
|-|-----------------------------|---------------------------------|
| **Examples** | DNS, Vault, GitLab, CI/CD, Gatus, testapp | HAOS (Home Assistant), PBS |
| **vda authority** | Git commit → Nix build | Vendor ISO / vendor update mechanism |
| **vda rebuildable from Git?** | Yes — rebuild with `build-image.sh` | No — must restore from PBS backup |
| **CIDATA used?** | Yes — cloud-init configures the VM | Maybe not — HAOS has its own config mechanism |
| **PBS backs up vda?** | No (rebuildable) | **Yes (not rebuildable)** |
| **PBS backs up vdb?** | Yes (if precious state exists) | Yes |
| **Disaster recovery for vda** | Rebuild from current Git commit | Restore entire VM from PBS |

**Lifecycle across operations (framework VMs — Category A/B):**

| Operation | vda | CIDATA | vdb | Off-cluster |
|-----------|-----|--------|-----|-------------|
| **Image update (factory)** (new commit, data-plane) | Destroyed and rebuilt from new image | Regenerated (may be identical) | **Preserved** — reattached to new VM | State updated by tofu |
| **Image update (field)** (new commit, control-plane) | `/nix/store` updated via closure push. Overlay cleared on reboot. ext4 image unchanged. | Unchanged (absorbed via overlay) | **Untouched** — VM never destroyed | Unchanged — tofu sees no changes (`ignore_changes`) |
| **Config change** (CIDATA edit, data-plane) | Destroyed and rebuilt | Regenerated with new values | **Preserved** — reattached to new VM | State updated by tofu |
| **Config change** (CIDATA edit, control-plane) | Unchanged | Unchanged (`ignore_changes` on initialization) | **Untouched** | Unchanged |
| **HA failover** (node dies) | Replica on surviving node | Snippet files on all nodes | Replica on surviving node | Unchanged |
| **PBS backup** | **Not backed up** (rebuildable from Git) | **Not backed up** (regenerated by OpenTofu) | **Backed up** to NAS via NFS | Is the backup destination |
| **Disaster recovery** (NAS alive) | Rebuilt from current Git commit | Regenerated by OpenTofu | Restored from PBS (vdb only) | Survives — this is the recovery source |

**Lifecycle across operations (vendor appliances — Category C):**

| Operation | vda | CIDATA | vdb | Off-cluster |
|-----------|-----|--------|-----|-------------|
| **Vendor update** | Updated in-place by vendor mechanism (e.g., HAOS Supervisor) | N/A for most appliances | **Preserved** | Unchanged |
| **HA failover** (node dies) | Replica on surviving node | N/A or snippet on all nodes | Replica on surviving node | Unchanged |
| **PBS backup** | **Backed up** (not rebuildable from Git) | N/A | **Backed up** | Is the backup destination |
| **Disaster recovery** (NAS alive) | **Restored from PBS** (whole VM) | N/A | **Restored from PBS** (whole VM) | Survives — this is the recovery source |

**Key design properties:**

1. **vda is disposable for framework VMs (Category A/B).** It is rebuilt from
   Git on every image update. Restoring vda from backup is never correct for
   these VMs — it would install old software that may be missing security
   patches or configuration changes from the current commit. **vda is NOT
   disposable for vendor appliances (Category C).** The framework cannot
   rebuild a vendor image from Git. PBS must back up the entire VM, and
   disaster recovery restores the whole VM from PBS.

2. **CIDATA is always regenerated (for VMs that use it).** It is produced by
   OpenTofu from config.yaml on every `tofu apply`. It is not backed up and
   does not need to be — its content is fully determined by the Git commit and
   config.yaml. CIDATA snippets are deployed to ALL Proxmox nodes so that HA
   failover works. Vendor appliances that don't use cloud-init (e.g., HAOS)
   have no CIDATA — they configure themselves through their own mechanisms.

3. **vdb outlives the VM.** When an image update recreates a framework VM,
   the old vdb zvol is preserved and reattached to the new VM. New software,
   old data. This is the normal upgrade path. Applications are responsible for
   forward migration (database schema upgrades, etc.) when they encounter
   older data. For vendor appliances, vdb is backed up alongside vda as part
   of the whole-VM PBS backup.

4. **Off-cluster storage is the durability anchor.** OpenTofu state
   (PostgreSQL on NAS) tells the rebuild script what existed. PBS backup data
   (NFS on NAS) provides the precious state to restore — vdb-only for
   framework VMs, whole-VM for vendor appliances. Both survive a complete
   cluster wipe because they are physically on the NAS, not on any cluster
   node.

5. **Version skew between vda and vdb is normal (framework VMs only).**
   During disaster recovery, vda comes from the current commit and vdb comes
   from the last backup. This is identical to a routine image update where
   vda is new and vdb carries forward. The framework does not need special
   handling — it is the expected condition. This property does not apply to
   vendor appliances, where vda and vdb are restored together from the same
   PBS backup. See section 16.4 for the full discussion.

6. **Each component has exactly one authority.** For framework VMs: vda comes
   from Git, CIDATA from config.yaml via OpenTofu, vdb from the running
   application (backed up by PBS). For vendor appliances: the entire VM is the
   vendor's domain, backed up as a unit by PBS. Off-cluster state comes from
   OpenTofu and PBS. Restoring a framework VM's vda from PBS instead of
   rebuilding from Git violates the design. Restoring a vendor appliance's
   vda from PBS is the *only* option — there is no Git-based rebuild path.

7. **VM identity is stable across rebuilds.** Each VM's identity — VMID, MAC
   address, and IP — is declared in config.yaml and assigned by OpenTofu. These
   values do not change when a VM is destroyed and recreated (image update,
   scorched-earth rebuild, disaster recovery). Stable identity means:
   - PBS backups are filed under the same VMID across rebuilds
   - Static IP assignment via CIDATA is deterministic (same MAC → same config)
   - ZFS zvol names are predictable (`vm-<vmid>-disk-0`)
   - HA resources survive VM recreation
   - Replication cleanup is simpler (known zvol names)

8. **vda boots with an overlay root (framework VMs).** At runtime, the ext4
   root partition on vda is not the system root. The NixOS initrd creates an
   overlay filesystem: a read-only bind-mount of the ext4 as the lower layer,
   a tmpfs as the upper layer. Writes to `/etc`, `/var`, `/root`, `/tmp` go
   to the tmpfs and vanish on reboot. `/nix` and `/boot` are bind-mounted
   from the real ext4 (writable, persistent). vdb mounts are separate devices
   outside the overlay.

   ```
   ┌─────────────────────────────────────────────────────────────┐
   │                    VM root at runtime                        │
   │                                                             │
   │  overlayfs /                                                │
   │  ├── lowerdir: /mnt-root-ro (ro bind of ext4)              │
   │  ├── upperdir: tmpfs (ephemeral — cleared on reboot)        │
   │  │                                                          │
   │  ├── /nix  ← bind-mount from /mnt-root/nix (rw, persistent)│
   │  ├── /boot ← bind-mount from /mnt-root/boot (rw, persistent)│
   │  ├── /nix/persist/ (certbot state, runner config)           │
   │  │                                                          │
   │  └── /var/lib/<service> ← vdb mount (separate device)       │
   └─────────────────────────────────────────────────────────────┘
   ```

   The read-only lowerdir is a safety net: any write that bypasses the
   overlay and hits the ext4 through the lowerdir fails with EROFS, making
   overlay bypass bugs loud instead of silent. The ext4 superblock itself
   stays rw so that the `/nix` and `/boot` bind-mounts work.

   This design ensures that factory deploy (tofu creates VM from image) and
   field update (`converge-vm.sh --closure` pushes closure, reboots) produce
   indistinguishable post-boot states. See `convergent-deploy.md` section
   3.12 for the full design rationale.

   The overlay tmpfs size is configurable per role via the
   `mycofu.overlayTmpfsSize` NixOS option (default 256MB, DNS VMs use 64MB).
   The CI runner redirects its build sandbox and checkout directory to paths
   under `/nix` to avoid exhausting the overlay tmpfs.

**Changing VM identity (VMID, MAC, or IP):** These are stable by design and
should be changed rarely — only for deliberate migrations (e.g., resolving an
IP conflict, renumbering VMIDs). Changing a VM's VMID breaks the association
with its PBS backups: old backups are filed under the old VMID, new backups
will be filed under the new VMID. The old backups don't disappear — they
remain in PBS under the old VMID for the duration of the retention policy —
but restoring across the boundary requires manually mapping the old VMID's
backup to the new VMID's VM.

**VMID change protection:** `tofu-wrapper.sh` compares VMIDs in config.yaml
against the current OpenTofu state before running `tofu apply`. If any VMID
has changed, the wrapper refuses to apply and prints:
- Which VMs have changed VMIDs (old → new)
- Whether each affected VM has precious state (Category 3)
- A warning that PBS backup continuity will break

The operator must pass `--allow-vmid-change` to proceed. This prevents
accidental VMID changes (typos in config.yaml, merge conflicts) from silently
destroying VMs with precious state. The flag is logged in the git commit
message for auditability.

**Vendor appliances (Category C) have VMIDs too.** HAOS, PBS, and any other
vendor appliance in config.yaml gets a pinned VMID. This is especially
important for vendor appliances because their entire disaster recovery path
is "restore from PBS" — if the VMID changes, the operator must manually find
the backup under the old VMID. The VMID change protection applies equally to
vendor appliances.

If you need to change a VMID:
1. Take a final PBS backup under the old VMID
2. Change the VMID in config.yaml
3. Run `tofu-wrapper.sh apply --allow-vmid-change`
4. Note the old VMID for future reference (in case a restore is needed from
   pre-change backups)

**Bidirectional state coupling: the PBS restore hazard**

Some VMs generate credentials or state at runtime bringup that is then
recorded in a second location outside the VM. This creates a **bidirectional
coupling** between the VM's vdb and the external record:

| VM | Generated at bringup | Stored on vdb | Also stored externally |
|----|---------------------|---------------|----------------------|
| Vault | Unseal key + root token (`vault operator init`) | Raft data | SOPS (`secrets.yaml`) |
| GitLab | Initial root password (generated at first boot) | PostgreSQL database | SOPS (`secrets.yaml`) |
| GitLab ↔ Runner | Runner registration (created by `register-runner.sh`) | GitLab PostgreSQL (runner record) | Runner VM `config.toml` (not backed up — runner is stateless) |
| PBS | TLS certificate + API token (generated at install) | PBS config | Proxmox cluster config (`pbs-nas` storage entry) |

PBS can only restore one side — the vdb. The external record (SOPS,
Proxmox cluster config, runner VM config) is not part of the backup. If
the external record was modified after the backup was taken — or if the
external side is always fresh (like the stateless runner VM) — the two
sides diverge after restore.

**The write-once rule prevents divergence** for most cases. If the
external record is written only once (when the credential is first
generated) and never overwritten, it always matches any PBS backup —
because the backup captured vdb state from the same bringup event that
wrote the external record.

**The runner is a special case: asymmetric coupling.** The runner VM is
stateless — it has no vdb, is not backed up, and is always fresh after
rebuild. After PBS restores GitLab, the GitLab database has a runner
registration for a runner VM that no longer exists (its `config.toml` is
gone). Write-once doesn't help here because the runner side is always
destroyed. The fix is **always re-register:** `register-runner.sh` detects
the stale runner registration in the restored GitLab, deletes it, and
creates a fresh registration.

| VM | Resolution strategy | Enforced by |
|----|-------------------|-------------|
| Vault | Write-once | `init-vault.sh` — writes SOPS only during `vault operator init` (when Vault API reports uninitialized). If already initialized, reads from SOPS, does not write. |
| GitLab | Write-once | `configure-gitlab.sh` — writes SOPS only on first password capture. If SOPS entry exists, uses it (resets DB password to match SOPS if they differ). |
| GitLab ↔ Runner | Always re-register | `register-runner.sh` — checks GitLab for existing runner, deletes stale registration, creates fresh registration. Runner token is consumed once during registration and not stored long-term in SOPS. |
| PBS | Recreate fresh + write-once password | `configure-pbs.sh` — the `pbs-nas` storage entry is removed by `reset-cluster.sh --vms` and recreated fresh. PBS root password is write-once in SOPS (written by `install-pbs.sh` on first install, matches `proxmox_api_password`). SSH connections to PBS use `sshpass` with this password or the SOPS private key. |

**Which VMs do NOT have this pattern:**
- Stateless VMs (DNS, Gatus, acme-dev) — no runtime bringup state, no
  external coupling. PBS doesn't back them up.
- Application VMs with purely internal state (testapp, InfluxDB, Grafana) —
  vdb contains application data, but nothing outside the VM needs to match
  it. PBS restore recovers the data; no external record to reconcile.

**The principle:** For any VM with externally-coupled bringup state, choose
a resolution strategy based on which side is authoritative after restore:
- **Write-once** (Vault, GitLab password): both sides were written at the
  same event, never overwritten → they match after restore.
- **Always re-register** (runner): one side is always fresh → delete the
  stale record on the restored side, create a new registration.
- **Recreate fresh** (PBS): the external record is explicitly removed
  during reset → the configure script creates it from the new VM's state.

If you add a new VM that generates a credential at bringup and stores it
externally, it needs one of these strategies — otherwise PBS restore will
produce a mismatch.

The subsections below detail each component: 11.1 covers vda (image strategy,
build process, versioning, categories). 11.1.1 covers CIDATA (the boot contract,
write_files, pre-deploy vs post-deploy secrets). 11.2 covers vdb (storage
strategy, data taxonomy). Section 16 covers PBS backup and restore workflows.
Section 17 covers HAOS (the reference vendor appliance).

### 11.1 VM Image Strategy

**Decision:** Offline image build (cross-compiled approach)

**Options considered:**
- Pre-built generic template (clone then install packages on-target)
- Build from scratch (NixOS installer ISO on-target)
- Offline image build (build complete VM images on build machine)

**Motivations:**
- **Leverages embedded systems expertise:** 20 years of cross-compiled firmware builds
- **Purest rebuildability:** Git → Nix build → image artifact → deploy (no external dependencies except Nix)
- **Fastest operations:** No on-target building, no installer, just boot and run
- **Better CI/CD:** Build images in pipeline, deploy as versioned artifacts
- **Versioned infrastructure:** Images are immutable, versioned artifacts (like firmware releases)
- **Testable:** Boot images in QEMU locally before deploying to Proxmox
- **Familiar debugging:** Inspect image offline, mount filesystem, etc.
- **Aligns with "minimal hidden state":** Image is an artifact, not hidden state
- **No installer ISO dependency:** Entire VM built from Nix expression

**Build process:**
```bash
# On build machine (Mac or CI server) — uses Nix flakes for pinned, reproducible builds
# build-image.sh handles the full sequence: build → convert → version-stamp → upload
framework/scripts/build-image.sh site/nix/hosts/dns.nix dns
# Output: build/dns-<nix-hash8>.img  (e.g. build/dns-a3f82c1d.img)
# Hash is content-addressed: same nix inputs → same hash → same filename
# Also writes: site/tofu/image-versions.auto.tfvars  (consumed automatically by tofu apply)
```

See section 11.1.2 for the image versioning scheme.

**Build machine lifecycle:**

The machine that runs `build-image.sh` changes across the project lifecycle. This
is a bootstrap dependency: the cluster cannot build VM images until it has a running
VM to build them on, but it cannot have a running VM until an image is built.

| Phase | Builder | When | Why |
|-------|---------|------|-----|
| Phase 1: Local builder | Operator workstation | Steps 1–3 (pre-cluster or early cluster) | The cluster doesn't exist yet, or lacks a build-capable VM |
| Phase 2: Remote builder | Proxmox node via SSH | Steps 4–6 (cluster running, pre-CI/CD) | Avoids platform-specific local builder issues; builds natively on x86_64-linux |
| Phase 3: CI/CD builder | GitLab Runner VM | Step 7+ (steady state) | Fully automated; operator workstation becomes fallback only |

`build-image.sh` abstracts this via the `nix_builder.type` setting in
`site/config.yaml`. Supported types: `local` (Nix builds on the workstation),
`linux-builder` (Nix's QEMU-based Linux VM on macOS), and `remote` (delegates to
a Proxmox node over SSH). The operator changes the builder type in config.yaml
as they progress through the phases — no code changes required.

On a Linux workstation, Phase 1 is straightforward — `nix build` runs natively. On
macOS, Phase 1 requires Nix's `linux-builder` (a QEMU VM managed by the Nix daemon)
because NixOS images must be built on Linux. The linux-builder has known fragility
on macOS — see the implementation plan Step 2 for platform-specific guidance and
the recommended transition to a remote builder once the cluster is available.

The transition from Phase 1 to Phase 2 is optional but recommended. Some operators
may stay on the local builder through Step 6 if it works reliably on their platform.
The transition from Phase 2 to Phase 3 happens naturally when CI/CD is deployed.
In all phases, the operator workstation retains the ability to build images as a
fallback (same mechanism as the Mac fallback for `tofu apply` when CI/CD is down).

**Image types:**
- Generic base image (minimal NixOS, used by all VMs)
- Role-specific images (pre-built with application packages)
- Both approaches supported, choose per use case

### 11.1.1 VM Boot Contract: cloud-init and Environment Discovery

This section defines the exact contract between OpenTofu (which creates VMs) and the VM image (which boots and configures itself). This is the mechanism behind "early binding of environment, late binding of role" (design goal #5).

**What OpenTofu provides (via Proxmox cloud-init):**

| cloud-init field | Value | Purpose |
|------------------|-------|---------|
| `instance-id` | `dns1-prod`, `vault-dev`, etc. | Unique VM identity |
| `local-hostname` | `dns1`, `vault`, etc. | Hostname (no environment prefix) |
| `ssh_authorized_keys` | Operator SSH public key(s) | Admin access (from SOPS) |

**What CIDATA delivers via `write_files` (from config.yaml, via OpenTofu):**

| Value | Path on VM | Prod VLAN 10 | Dev VLAN 20 |
|-------|-----------|-------------|-------------|
| Primary MAC | `/run/secrets/network/mac` | (from config.yaml) | (from config.yaml) |
| IP address | `/run/secrets/network/ip` | 10.0.10.x | 10.0.20.x |
| Gateway | `/run/secrets/network/gateway` | 10.0.10.1 | 10.0.20.1 |
| DNS servers | `/run/secrets/network/dns` | dns1.prod, dns2.prod IPs | dns1.dev, dns2.dev IPs |
| Search domain | `/run/secrets/network/search-domain` | `prod.example.com` | `dev.example.com` |

**Why `write_files` instead of `network-config`:** NixOS's nocloud-init
implementation only processes `user-data` and `meta-data` from the CIDATA
ISO. It does not consume the `network-config` section that the Proxmox
provider generates via `ip_config`. The bpg/proxmox provider's `ip_config`
block sets `address = "dhcp"` (a no-op since `networking.useDHCP = false`).
All network configuration is delivered through `write_files` and applied
by a custom systemd-networkd service (`configure-static-network`) that
matches the primary NIC by MAC address.

**What the VM does at boot (NixOS activation):**

1. cloud-init runs: sets hostname, configures SSH keys, writes files from CIDATA
2. `configure-static-network` service reads `/run/secrets/network/*`, writes a
   systemd-networkd `.network` file matching the primary NIC by MAC address
3. systemd-networkd applies the static config → **network is immediately available, environment is determined**
4. `systemd-resolved` bridges networkd's DNS and search domain settings to resolv.conf
5. VM resolves `vault` → `vault.prod.example.com` or `vault.dev.example.com` (via search domain)
4. VM resolves `acme` → `acme.prod.example.com` or `acme.dev.example.com`
5. certbot requests certificate from `acme` using PowerDNS API key (from SOPS via `write_files`)
6. certbot writes TXT challenge to both DNS servers in the environment
7. ACME server (Let's Encrypt in prod, step-ca in dev) validates challenge, issues certificate
8. vault-agent authenticates to `vault` using the issued TLS certificate
9. Vault validates cert, issues token with role-specific policy
10. vault-agent retrieves runtime secrets, writes to `/run/secrets/`
11. Application services start, reading secrets from `/run/secrets/`

**Boot-time configuration principle: everything from CIDATA `write_files`.**

All environment-specific values — both network configuration and service
configuration — are delivered via CIDATA `write_files`. This provides a
single, uniform delivery mechanism with deterministic availability:

| Mechanism | Available when | Use for |
|-----------|---------------|---------|
| `write_files` (CIDATA) | Immediately at boot — CIDATA is a mounted ISO | Network config (IP, MAC, gateway, DNS, search domain) at `/run/secrets/network/` |
| `write_files` (CIDATA) | Immediately at boot — CIDATA is a mounted ISO | Service config (API keys, URLs, domain names) at `/run/secrets/` |

No DHCP dependency means no race conditions. The network is fully
configured before any service starts. Both network and service
configuration are available from CIDATA at the same instant, through
the same mechanism.

**Services must never parse DHCP lease files for configuration.** This
rule is now moot — there are no DHCP lease files. VMs have
`networking.useDHCP = false`. All network parameters come from CIDATA.

**CIDATA secret classification: pre-deploy vs post-deploy.**

CIDATA is a VM creation input — if any value in CIDATA changes, OpenTofu recreates
the VM. This is enforced by a `terraform_data.cidata_hash` resource that tracks
the SHA256 of CIDATA template content, referenced via `replace_triggered_by` on
the VM resource (see section 10.2 for details on how this interacts with
`ignore_changes = [initialization]`). A post-apply runtime check in
`rebuild-cluster.sh` verifies each VM's search domain matches config.yaml as a
safety net against partial applies or provider bugs.

This creates a critical constraint on which secrets can appear in CIDATA:

| Category | Examples | Known when | In CIDATA? | Delivery mechanism |
|----------|---------|-----------|-----------|-------------------|
| Pre-deploy | PowerDNS API key, ACME URL, forward-zone domain, SSH keys | Before VM exists (from config.yaml or operator-managed SOPS) | Yes — via write_files | cloud-init → `/run/secrets/` |
| Post-deploy | Vault unseal key, GitLab runner token, GitLab root password | After VM boots (generated by init-vault.sh, configure-gitlab.sh) | **No** — would create a recreation cycle | SSH to persistent storage (vdb) |

**Post-deploy secrets must never appear in CIDATA.** If they do, the following
cycle occurs: deploy VM → post-deploy script generates secret → writes to SOPS →
SOPS feeds CIDATA via TF_VAR → next `tofu apply` sees different CIDATA → recreates
VM → destroys the state that generated the secret → post-deploy script generates a
new secret → cycle repeats forever.

Post-deploy secrets are delivered via SSH by the post-deploy scripts directly to
persistent storage on the VM (typically vdb). The service reads from vdb on boot.
SOPS stores a backup copy for the operator, but in a section that is NOT consumed
by any TF_VAR — changes to the backup section have zero effect on `tofu plan`.

This separation is what makes `rebuild-cluster.sh` idempotent: CIDATA contains
only pre-deploy values that are stable across deploys, so `tofu plan` shows no
changes on a second run.

**HA availability principle: CIDATA on every node.**

CIDATA snippets are stored on Proxmox `local` storage — a per-node directory.
ZFS replication copies disk zvols but NOT local storage files. For Proxmox HA
to start a VM on any node after a failure, the VM's CIDATA snippets must exist
on every node in the cluster, not just the node where the VM was created.

OpenTofu must create a `proxmox_virtual_environment_file` resource for each
snippet on each node. This is a framework-level requirement that affects every
VM module — it is not optional. Without it, HA failover silently fails: Proxmox
selects a target node, attempts to start the VM, can't find the snippets, and
marks the VM as permanently failed.

**What the VM image does NOT contain:**
- No IP addresses, subnets, or gateways
- No environment names (`prod`, `dev`) anywhere in the image
- No FQDNs — only unqualified hostnames
- No runtime secrets — only pre-deploy bootstrap secrets (PowerDNS API key via SOPS)
- No post-deploy secrets — Vault unseal keys, runner tokens are delivered via SSH
- No Vault tokens or certificates — these are obtained at boot

**Role selection:**
The VM's role (which services to run) is determined by which NixOS configuration was used to build the image. A DNS image includes PowerDNS; a Vault image includes Vault; etc. This is baked at build time, not selected at boot. "Late binding of role" means the role-specific behavior (which Vault policies to request, which secrets to fetch) adapts to the environment discovered at boot, not that the role itself is chosen at boot.

**Preventing OpenTofu/Nix drift:**
OpenTofu references a specific image version for each VM. The image version is
derived from the nix output hash — a content-addressed identifier that changes only
when the image contents change. If a commit doesn't affect a role's nix derivation,
the image hash (and filename) stays the same, and OpenTofu sees no diff — the VM is
not recreated. This is the key property that makes the always-build-all-roles
pipeline efficient: most commits don't change most roles, so most VMs are untouched.

The pipeline builds all images and runs `tofu apply` in a single run from the same
commit, so the NixOS configuration and the deployed images are always consistent.
The `image-versions.auto.tfvars` file is a pipeline artifact (not committed to git)
that connects the build output to the deploy step. See section 11.1.2 for the full
versioning scheme.

**If cloud-init metadata is missing or invalid:**
- Missing `instance-id`: cloud-init generates a random ID. VM functions normally but won't match OpenTofu's expected identity. Detectable via bootstrap validation.
- Missing SSH keys: no admin access. VM is functionally correct but unmanageable. Must destroy and recreate.
- CIDATA network config invalid: VM has no IP, no DNS, no environment binding. All subsequent steps fail. VM is unreachable. Proxmox console is the only debug path.
- DNS failure: VM has IP but can't resolve `vault` or `acme`. Certificate issuance fails. Vault auth fails. Application can't start. Detectable via bootstrap validation (DNS health check).

**Update workflow:**
1. Change NixOS config (or config.yaml, Vault policies, etc.) in Git and commit
2. CI runs `build-all-images.sh` — every role is built from the current commit.
   Images are named with the nix output hash (e.g., `dns-a3f82c1d.img`). Unchanged
   roles produce the same hash and the same filename.
3. CI runs `upload-image.sh` for each role — skips if the image already exists on
   all nodes (content-addressed filename = content match)
4. CI runs `tofu apply` — OpenTofu reads `image-versions.auto.tfvars`. VMs whose
   image filename hasn't changed are untouched. Only VMs with a new image are
   recreated.
5. Data disks preserved (see storage strategy)

**Most pipeline runs don't recreate any VMs.** A DNS zone change, a Vault policy
update, or a documentation fix produces identical nix derivations for every role.
The image filenames are unchanged, `tofu apply` is a no-op for VMs, and the
pipeline completes in seconds (build from cache, `tofu apply` is a no-op). VM recreation only
happens when a NixOS module or its dependencies actually change.

### 11.1.2 Image Versioning Scheme

**Decision:** Images are named using the first 8 characters of the nix derivation
output hash — the content-addressed identifier from the nix store path.

**Image filename format:** `<role>-<nix-hash8>.img`

Examples:
```
dns-a3f82c1d.img      # nix output hash of the dns derivation
vault-a3f82c1d.img    # same hash if both share identical nix inputs
dns-a3f82c1d.img      # rebuilt from a different commit — SAME hash (nix inputs unchanged)
dns-b7e91204.img      # dns.nix changed — DIFFERENT hash (nix inputs changed)
```

**Motivations:**

- **Content-addressed:** The filename changes if and only if the image contents
  change. Rebuilding from a different git commit that doesn't affect the role's
  nix derivation produces the same hash and the same filename. This is the
  fundamental property that prevents unnecessary VM recreation.
- **Deterministic by nix guarantees:** Same nix inputs → same derivation → same
  output hash → same filename. This is nix's core promise, and the versioning
  scheme relies on it directly.
- **No unnecessary VM recreation:** OpenTofu sees the image filename as part of
  the VM's configuration. If the filename hasn't changed, OpenTofu makes no
  change and the VM is untouched. Most pipeline runs don't change most roles,
  so most VMs are never recreated. This makes the always-build-all pipeline
  practical: build is fast (nix cache), upload is fast (skip existing), and
  deploy is a no-op for unchanged roles.
- **Traceable:** The nix store path `/nix/store/<hash>-...` is logged during the
  build. `nix path-info --derivation` shows exactly what inputs produced the
  image. For git traceability, `build-image.sh` records the git commit SHA in
  an external build log (`build/build.log`), not inside the image — embedding
  the git SHA in the image would make it a derivation input, defeating
  content-addressed naming.
- **Automation-friendly:** `build-image.sh` extracts the hash from the nix build
  output path with no human input.

**Why not git commit SHA?** Using the git SHA as the filename causes every commit
to produce a different filename for every role, even when the nix content is
identical. This triggers VM recreation on every pipeline run — destructive for VMs
with state (Vault), wasteful for stateless VMs (DNS), and hostile to the HA
double-apply issue. Content-addressed naming eliminates this by construction.

**The `image-versions.auto.tfvars` file:**

`build-image.sh` writes the image name for each built role into
`site/tofu/image-versions.auto.tfvars`. OpenTofu automatically loads any
`*.auto.tfvars` file in the working directory, so `tofu apply` picks up new image
versions without any manual variable editing.

```hcl
# site/tofu/image-versions.auto.tfvars
# Auto-generated by build-image.sh / build-all-images.sh — do not edit manually
image_versions = {
  "dns"    = "dns-a3f82c1d.img"
  "vault"  = "vault-a3f82c1d.img"
  "gitlab" = "gitlab-e5c210ab.img"
  "cicd"   = "cicd-f7d391bc.img"
  "gatus"  = "gatus-a3f82c1d.img"
}
```

**`image-versions.auto.tfvars` is a build artifact, not committed to Git.** It is
gitignored and generated fresh during each pipeline run or workstation build
session. The rationale:

- **One commit, one pipeline.** Committing the file forces a two-commit pattern
  (commit source → build → commit image hashes) where commit N deploys images from
  commit N-1. With the file gitignored, the pipeline builds and deploys from a
  single commit. The source and the deployment are always consistent.
- **Pipeline artifacts are the delivery mechanism.** In CI/CD, the build stage
  generates the file and passes it to the deploy stage as a pipeline artifact. On the
  workstation, the operator runs `build-all-images.sh` then `tofu apply` in the same
  session.
- **OpenTofu state is the deployment record.** "Which image is deployed?" is answered
  by `tofu state show` or `tofu plan`, not by git history. The tofu state (on the NAS)
  is the source of truth for deployed versions.

**Always build all roles.** The pipeline runs `build-all-images.sh`, which builds
every NixOS role sequentially from the current commit. There is no smart detection
or diffing logic to determine which roles changed. Nix's content-addressed store
handles this: unchanged roles produce the same derivation, which is already in the
store, so the "build" is a cache lookup (seconds). `upload-image.sh` checks if the
content-addressed filename already exists on each Proxmox node and skips the upload.
The always-build approach is simple, correct, and catches transitive dependency
changes (e.g., a `flake.lock` update that changes a shared library) that diffing
would miss.

**Dirty working tree policy and `--dev` mode:**

`build-image.sh` requires a clean Git working tree for normal builds. This ensures
the git SHA is available for the external build log (for traceability). The image
filename is derived from the nix output hash (not the git SHA), and the git SHA is
recorded in `build/build.log` — outside the image, not as a nix build input.

**Critical:** The git commit SHA (`self.rev`) must NOT appear as an input to any
nix derivation that produces an image. If it does, the derivation hash changes on
every commit, defeating content-addressed naming. `self.rev` is for external logging
only.

**Flake source filter (`nixSrc`):**

The same principle — controlling what feeds into the derivation hash — extends to
the flake's source tree. By default, a flake's `self` includes every tracked file
in the git repo. This means changing `.gitlab-ci.yml`, `CLAUDE.md`, or any
non-nix file would change the source hash and therefore every derivation hash,
triggering recreation of every VM on every commit.

The fix is a filtered source tree created via `builtins.path`:

```nix
nixSrc = builtins.path {
  path = ./.;
  name = "mycofu-nix-src";
  filter = path: type:
    # Only include files that affect image builds:
    # - .nix files in framework/nix/, site/nix/, framework/catalog/, site/apps/
    # - flake.nix, flake.lock
    # - certbot hook scripts (referenced by NixOS modules)
    # - step-ca root CA files (referenced by NixOS modules)
    ...
};
```

All image derivation entry points in `flake.nix` reference `${nixSrc}/...` instead
of `./...` or `self`. NixOS modules loaded from `nixSrc` resolve their relative
imports within the filtered tree. A file not in the filter literally does not exist
in `nixSrc` — any reference to it produces a hard build failure, not silent use of
stale content. This is the same fail-closed property as a build sandbox: the filter
is an allowlist, and missing entries are build errors.

**Maintenance requirement:** When adding new files that NixOS modules reference
(scripts, configs, templates), the `nixSrc` filter in `flake.nix` must be updated
to include them. The pipeline validates filter integrity at build time via a
static lint check (`check-source-filter.sh`) and a nix-level canary test
(`source-filter-check.nix`) that detects `self` references that would bypass
the filter. See `.claude/rules/nixos.md` for the full invariant and verification
commands.

**Critical invariant:** No image-contributing nix code may reference `self`,
`self.outPath`, or bare `./` paths in `flake.nix` module lists. These resolve
against the unfiltered flake source, defeating the filter.

For development iteration — editing a NixOS module without committing between test
cycles — use the `--dev` flag:

```bash
build-image.sh --dev site/nix/hosts/dns.nix dns
```

A `--dev` build:
- Accepts a dirty working tree
- Names the image `<role>-<nix-hash>-dev.img` (visually distinct from clean images)
- The nix hash still reflects the actual content (including uncommitted changes)
- Writes the image name to `image-versions.auto.tfvars`

The `-dev` suffix is a visual marker for the operator, not a functional difference.
It prevents confusion between images built from committed vs. uncommitted state.

**Old image cleanup:**

Proxmox storage accumulates images over time. Because image filenames are
content-addressed, unchanged roles reuse the same filename indefinitely — only
roles that actually change produce new files. This naturally limits growth.
`upload-image.sh` accepts an optional `--prune` flag that removes images for the
same role that are not referenced by the current `image-versions.auto.tfvars`.
This cleans up old versions after a role's nix configuration changes.

### 11.1.3 VM Image Categories

Not all VMs are NixOS images built by nix. The build system supports three
categories of VM image, each with a different build mechanism but the same
content-addressed naming property.

**Category A: NixOS images (recommended)**

Built by nix from the flake. The image filename uses the nix derivation output
hash. This is the primary path — all infrastructure VMs and most application VMs
should use this category.

- Build mechanism: `nix build .#<role>-image`
- Hash source: nix store output path (content-addressed by nix)
- Content-addressed: yes (by nix's guarantees)
- Managed by: `build-image.sh` and `build-all-images.sh`
- Rebuilt by pipeline: yes (every run, but cache makes unchanged roles instant)
- Examples: DNS, Vault, GitLab, CI/CD runner, Gatus, PostgreSQL, any NixOS VM

NixOS can run any workload — native services, Docker containers (section 12), or
both. Choosing NixOS as the base doesn't limit what runs inside the VM. It gives
you declarative configuration, reproducible builds, and content-addressed images.

**Category B: Non-NixOS images (content-addressed)**

Built outside of nix from a user-defined build script. The image filename uses
a SHA256 hash of the final image file. This supports VMs that cannot or should
not use NixOS — for example, a Packer-built Debian image, a custom appliance, or
an image downloaded from a vendor that the operator customizes.

- Build mechanism: user-provided build script (specified in the image manifest)
- Hash source: SHA256 of the image file (first 8 characters)
- Content-addressed: yes (by file content hash)
- Managed by: `build-image.sh` (detects non-nix role from manifest) and
  `build-all-images.sh`
- Rebuilt by pipeline: yes — the build script runs every pipeline, and the file
  hash determines whether the output changed
- Examples: Packer-built Debian image, vendor image with local customization

The user provides a build script that produces an image file. `build-image.sh`
runs the script, hashes the output, and names it `<role>-<sha256-8>.img`. If the
hash matches the existing image on the Proxmox nodes, the upload is skipped and
OpenTofu sees no change.

**Category C: Vendor appliances (static)**

Not built by the pipeline at all. The image is a vendor-provided ISO or disk
image, installed manually. The filename is static or manually versioned. OpenTofu
manages the VM but not the image lifecycle.

- Build mechanism: none (manual ISO install or image download)
- Hash source: none (static filename or manual version string)
- Content-addressed: no
- Managed by: operator (manual download, install, version tracking)
- Rebuilt by pipeline: no — excluded from `build-all-images.sh`
- Examples: PBS (Proxmox Backup Server), HAOS (Home Assistant OS)

These VMs appear in OpenTofu but their image is not part of the automated build
pipeline. They are Tier 2 (workstation-managed) by nature.

**Choosing between categories:**

| Factor | Category A (NixOS) | Category B (non-NixOS hashed) | Category C (vendor appliance) |
|--------|-------------------|------------------------------|------------------------------|
| Reproducibility | Full (nix guarantees) | Depends on build script | None (manual install) |
| Content-addressed naming | Yes (nix hash) | Yes (file hash) | No |
| Pipeline integration | Full (build + deploy) | Full (build + deploy) | None (manual only) |
| VM recreation on no-change commits | No | No | N/A |
| Configuration management | Declarative (NixOS modules) | Depends on tooling (Packer, cloud-init, etc.) | Vendor-specific |
| When to use | Default choice. Any VM where you control the OS configuration. | When the workload requires a specific non-NixOS base (vendor kernel, commercial software, certified OS image). | Vendor appliances that ship as complete images with their own management interface (PBS, HAOS). |

**The recommendation is Category A for everything possible.** NixOS's declarative
model, reproducibility guarantees, and nix-native content addressing provide the
strongest operational properties. Category B exists for legitimate cases where
NixOS is not an option. Category C is for vendor appliances that are managed
outside the pipeline.

### 11.1.4 Image Build Manifest

`build-all-images.sh` reads the list of roles to build from two manifest files,
following the framework/site separation pattern used throughout the repo.

**Framework manifest:** `framework/images.yaml`

Defines infrastructure roles that are part of the framework. These are the
same across all deployments. The framework manifest is in the open-source repo.

```yaml
# Framework image manifest — infrastructure roles included in every deployment.
# Do not add site-specific application roles here — use site/images.yaml instead.

roles:
  dns:
    category: nix
    host_config: site/nix/hosts/dns.nix
    flake_output: dns-image

  vault:
    category: nix
    host_config: site/nix/hosts/vault.nix
    flake_output: vault-image

  gitlab:
    category: nix
    host_config: site/nix/hosts/gitlab.nix
    flake_output: gitlab-image

  cicd:
    category: nix
    host_config: site/nix/hosts/cicd.nix
    flake_output: cicd-image

  gatus:
    category: nix
    host_config: site/nix/hosts/gatus.nix
    flake_output: gatus-image

  acme-dev:
    category: nix
    host_config: site/nix/hosts/acme-dev.nix
    flake_output: acme-dev-image
```

**Site manifest:** `site/images.yaml`

Defines application roles specific to this deployment. This is the private,
site-specific file alongside `site/config.yaml`. A new site starts with an
empty roles section (generated by `new-site.sh`).

```yaml
# Site-specific image manifest — application roles for this deployment.
# Framework infrastructure roles are in framework/images.yaml.

roles:
  # Category A: NixOS application VMs
  # postgres:
  #   category: nix
  #   host_config: site/nix/hosts/postgres.nix
  #   flake_output: postgres-image

  # Category B: Non-NixOS images (content-addressed by file hash)
  # myapp:
  #   category: external
  #   build_script: site/images/myapp/build.sh
```

**Merging rules:**

`build-all-images.sh` reads both manifests and merges the role lists:
- Framework roles are loaded first
- Site roles are added second
- Duplicate role names (a role in both framework and site) are an error — this
  prevents accidentally shadowing an infrastructure role with a broken definition
- The merged list is iterated sequentially

**Vendor appliances (Category C) are not listed in either manifest.** PBS, HAOS,
and other vendor appliances are managed outside the pipeline. They appear in
OpenTofu but not in the image manifests.

**Old image cleanup:**

Proxmox storage accumulates images over time. Because image filenames are
content-addressed, unchanged roles reuse the same filename indefinitely — only
roles that actually change produce new files. This naturally limits growth.
`upload-image.sh` accepts an optional `--prune` flag that removes images for the
same role that are not referenced by the current `image-versions.auto.tfvars`.
This cleans up old versions after a role's nix configuration changes.

### 11.2 Storage Strategy

**Decision:** Separate OS and data volumes

**Storage layout per VM:**
```
/dev/vda (ZFS zvol on local pool, 20-30GB - OS root disk from image)
  ├── /nix/store (all packages, from pre-built image)
  ├── /boot (bootloader, kernel)
  ├── /etc (config symlinks to /nix/store)
  └── /var/log (system logs)

/dev/vdb (ZFS zvol on local pool, varies by app - persistent data)
  └── /var/lib/app (application data, databases, state)
```

**Options considered:**
- Monolithic (OS + data on single volume)
- Separate volumes (OS separate from data)
- Overlay filesystem (shared base, per-VM data layer)
- Shared /nix/store via NFS

**Motivations for separate volumes:**
- **Aligns with rebuildability:** vda is code (expendable), vdb is data (persistent)
- **Works with NixOS:** Standard usage, no fighting the system
- **Backup efficiency:** Only backup precious state on vdb, vda is rebuildable from Git
- **ZFS replication:** Both volumes replicated to other nodes, enabling HA restart
- **Data outlives VM:** Can rebuild VM, data persists
- **Clear separation:** vda = derivable from Git, vdb = configuration + state

**Rejected alternatives:**
- Monolithic: Mixes rebuildable (code) with persistent (data), rebuilding loses data
- Overlay: Breaks NixOS garbage collection, fragile shared dependencies, not justified
- Shared /nix/store: Network performance hit, shared GC issues, working against NixOS design

### 11.2.1 Data Taxonomy

VM data falls into four categories with different durability requirements:

**Category 1: Derivable (vda — never backed up)**
- OS, packages, binaries, boot configuration
- Fully derived from Git + Nix build
- If lost: rebuild VM image from Git (minutes)
- Examples: `/nix/store`, `/boot`, `/etc`

**Category 2: Configuration (subset of vdb — backed up via Git, not PBS)**
- Data provided to the VM from external sources (Git, OpenTofu, Nix)
- Can be regenerated by re-deploying from Git without any backups
- Examples: DNS zone data (derived from config.yaml, delivered via CIDATA at deploy time), Vault policies (synced from Git), application config files managed by Nix
- VMs with only derivable + configuration data can be completely destroyed and recreated from Git with zero data loss

**Category 3: Precious state (subset of vdb — backed up via PBS to NAS)**
- Runtime data generated by applications that cannot be derived or regenerated
- If lost: must restore from PBS backup
- Examples: Home Assistant entity states and history database, InfluxDB time series data, PostgreSQL table contents, Vault Raft storage (dynamic secrets, leases)

**Category 4: VM-produced secrets safekept by Vault**
- Secrets generated by a VM at runtime that must persist across VM recreation
- Defined by bidirectional flow: Vault delivers the secret to the VM on boot; the VM writes it back to Vault after generating it
- Not backed up via PBS — lives exclusively in Vault
- Not pre-configured by the operator — generated by the VM itself on first use
- If Vault is lost: the secret is regenerated on next boot (one-time cost: new identity, new registration)
- Examples: Tailscale node identity (generated at first tailnet join, stored in Vault, restored on subsequent boots so the VM maintains a stable Tailscale identity across rebuilds)
- Vault path convention: `secret/<service>/nodes/<domain>/<vmrole>`

**Why this taxonomy matters:**
- DNS servers have no precious state — they can be completely regenerated from Git sources and configuration. PBS backup of DNS vdb is unnecessary.
- Home Assistant has precious state (entity states, history, automations edited in UI). PBS backup of Home Assistant vdb is essential.
- Database servers (PostgreSQL, InfluxDB) have precious state (table data). The schema/config may be in Git, but the data itself requires PBS backup.
- Tailscale node identity is neither precious application state nor simple configuration — it is a VM-generated secret that Vault safekeeps. No PBS backup needed; Vault is the store.
- This distinction determines what PBS backs up, not how replication or HA works (which is uniform for all VMs).

**What goes where:**

**vda (root disk) contains:**
- Category 1 only: derivable from Git
- If lost: rebuild from image (generated from Git)
- `/boot`, `/nix/store`, `/etc`, `/var/log`

**vdb (data disk) contains:**
- Category 2 (configuration) and/or Category 3 (precious state), depending on the VM
- If lost and VM has only configuration: redeploy from Git
- If lost and VM has precious state: restore from PBS backup
- `/var/lib/postgresql`, `/var/lib/homeassistant`, etc.

**Vault contains:**
- Category 4: VM-produced secrets (Tailscale node identity, etc.)
- Bootstrap-tier secrets (not VM-produced, but operator-provided and stored in Vault for runtime delivery)

**Examples by VM type:**

| VM | vda (Cat 1) | vdb configuration (Cat 2) | vdb precious state (Cat 3) | Vault (Cat 4) | PBS backup needed? |
|----|-------------|--------------------------|---------------------------|---------------|-------------------|
| DNS (PowerDNS) | NixOS + PowerDNS | Zone data (from Git) | None | None | No |
| Vault | NixOS + Vault | Policies (from Git) | Raft storage, leases, dynamic secrets | None | Yes |
| Home Assistant | HAOS | YAML config (from Git) | Entity/device registries, history DB | None | Yes |
| InfluxDB | NixOS + InfluxDB | Schema (from Git) | Time series data | None | Yes |
| GitLab (Tailscale) | NixOS + GitLab | Config (from Git) | Repos, DB, CI history | Tailscale node identity | Yes (for Cat 3) |
| CI/CD runner | NixOS + runner | Pipeline config (from Git) | None | None | No |

### 11.3 Rebuild Process

**Standard rebuild (data preserved):**
1. Destroy VM (vda destroyed, vdb persists)
2. OpenTofu creates new VM from image
3. OpenTofu attaches existing vdb
4. VM boots, mounts vdb at `/var/lib/app`
5. Application starts with preserved data

**Complete rebuild (data lost, restore from backup):**
1. Destroy VM and vdb
2. OpenTofu creates new VM and new vdb
3. Restore data to vdb from backup
4. VM boots with restored data

### 11.4 Migration and HA Support

**Decision:** ZFS local storage with replication (enables HA and planned migration)

**HA strategy:** Uniform for all VMs. All VMs are HA-enabled, all replicated to both other nodes on 1-minute intervals. No per-VM differentiation for replication or HA policy.

**HA priority:** Home Assistant is the only VM without application-level redundancy (DNS has dns1/dns2, etc.). Proxmox HA priority is set so Home Assistant restarts first if multiple VMs need to restart after a node failure.

**Anti-affinity placement:** Redundant service pairs (dns1/dns2, and any future pairs) must run on different nodes. If both instances of a redundant service run on the same node, a single node failure eliminates all redundancy — defeating the purpose of running two instances. OpenTofu should enforce this placement constraint. The same principle applies across environments: prod dns1 and prod dns2 should be on different nodes, and ideally dev dns1 and dev dns2 should also be on different nodes (though this is a softer constraint since dev availability is less critical).

**Node load balancing and capacity planning:**

**N+1 capacity rule:** The cluster must never schedule more than (N-1) nodes' worth of VM load, even when all N nodes are healthy. This ensures that any single node failure can be absorbed by the survivors without overcommitting resources.

Concrete implication: with N nodes of equal RAM, the total VM RAM allocation must not exceed (N-1) nodes' worth. For example, with 3 nodes × 32GB RAM = 96GB total, the limit is ~64GB. During normal operations, load is spread across all nodes. If a node fails, its VMs are distributed across the N-1 survivors — full but not overcommitted. CPU follows the same principle, though CPU overcommit is more forgiving (throttled, not OOM-killed — Out Of Memory).

This is a capacity planning constraint that affects when a fourth node is needed. The question when adding a new VM is not "is there room on the cluster?" but "is there room while staying within 2 nodes' worth of total allocation?"

**Post-failover rebalancing:** After a node failure, all its VMs run on two nodes. The cluster is at full capacity with zero headroom — a second node failure would leave some VMs unable to restart. Once the failed node recovers, VMs must be rebalanced back to restore the N+1 distribution before resuming normal operations.

**Tooling:**

Proxmox VE (as of version 9) provides native HA affinity and anti-affinity rules. Anti-affinity rules can enforce that redundant pairs (dns1/dns2) are placed on separate nodes. Node affinity rules can express preferred placement. These rules are respected by the HA manager during failover.

However, native Proxmox does not provide automatic load-aware rebalancing — it will not migrate VMs to equalize load across nodes. For this, ProxLB is a well-regarded open-source tool that fills the gap. It operates via the Proxmox API (no SSH needed) and provides:
- Rebalancing VMs across nodes based on memory, CPU, or disk usage
- Anti-affinity enforcement via VM tags
- Maintenance mode (evacuate a node before updates)
- CI/CD integration (`--best-node` query for OpenTofu/Ansible placement decisions)
- Can run as a daemon with periodic rebalancing or as a one-shot command

ProxLB or similar tooling would be used for: initial VM placement during `tofu apply` (query best node), post-failover rebalancing (redistribute VMs after a node recovers), pre-maintenance evacuation (drain a node before Proxmox update), and capacity watchdogging (alert if total allocation approaches the 2-node limit).

**Decision: Evaluate ProxLB during implementation.** The capacity rule and anti-affinity constraints are architectural requirements. The specific tooling to enforce them (native Proxmox HA rules, ProxLB, custom scripts, or OpenTofu placement logic) is an implementation decision to be made during buildout. Native Proxmox HA rules handle anti-affinity. Load-aware rebalancing and capacity watchdogging may require ProxLB or similar.

**Planned migration (rolling updates, maintenance):**
1. Proxmox triggers final ZFS replication sync to target node (seconds for incremental delta)
2. VM is shut down on source node
3. VM starts on target node from ZFS replica
4. Downtime: typically 10–20 seconds (VM shutdown + boot time)

**Unplanned failover (node failure):**
1. Proxmox detects node failure via fencing/watchdog (~30–60 seconds)
2. Proxmox HA manager selects a surviving node with the ZFS replica
3. VM starts on that node from the replica (~10–15 seconds boot time)
4. Total failover time: <120 seconds measured (7 VMs migrated simultaneously)
5. Data loss: up to 1 minute of writes on vdb (bounded by replication interval)
6. vda (OS disk) loss is irrelevant — rebuildable from Git

**Single-VM crash (node healthy):**
When a VM process dies but the hosting node is healthy, HA restarts the VM
on the same node (no migration needed). Measured: ~10 seconds to running,
~15 seconds to application-ready (Vault auto-unseal included).

**HA boot requirements: what must be on every node.**

For HA to start a VM on a surviving node, that node must have ALL of:

| Artifact | Replication mechanism | What provides it |
|----------|----------------------|-----------------|
| vda (OS disk zvol) | ZFS replication (1-minute interval) | Automatic — Proxmox replication jobs |
| vdb (data disk zvol) | ZFS replication (1-minute interval) | Automatic — Proxmox replication jobs |
| CIDATA snippets (user-data + meta-data YAML) | **Must be explicitly deployed to all nodes** | OpenTofu or post-apply script |
| VM image (.img file) | upload-image.sh deploys to all nodes | Already handled — images are uploaded to every node |

**The critical gap that ZFS replication does NOT cover: CIDATA snippets.**
Proxmox stores nocloud-init snippets on `local` storage — a per-node
directory (`/var/lib/vz/snippets/`). ZFS replication copies zvols, not local
storage files. If a VM's snippets only exist on the node where OpenTofu
created it, HA cannot start the VM on any other node.

**Requirement:** OpenTofu must deploy each VM's CIDATA snippets to ALL nodes,
not just the node where the VM is created. The `proxmox_virtual_environment_file`
resource must be created once per node for each snippet file. This ensures
HA can start the VM anywhere in the cluster.

This is a hard requirement for HA to function. Without it, a node failure
causes all VMs on that node to enter HA "error" state — Proxmox selects a
target node, attempts to start the VM, fails because the snippets are missing,
and marks the VM as failed. The VMs remain down until an operator manually
copies the snippets or runs `tofu apply` targeting the surviving node.

**Important:** Unplanned failover time is the same whether using ZFS or Ceph. Ceph's sub-second advantage applies only to planned live migration, not crash recovery. Both storage architectures go through the same fencing detection timeout on unplanned node failure.

**Motivations:**
- Planned migration downtime is brief and acceptable for services at this scale
- ZFS replication keeps replicas current (1-minute interval)
- No dependency on distributed storage quorum — storage survives any single failure
- HA restart works from replica — but requires CIDATA snippets on all nodes
- Uniform policy: one rule for all VMs, no complexity from per-VM differentiation

**Post-failover recovery: placement drift and rebalancing.**

After HA migrates VMs to surviving nodes, the cluster is functional but degraded:
VMs are running on the "wrong" nodes (not their intended placement from
config.yaml), N+1 headroom is reduced, and OpenTofu state doesn't match reality.
The `node_name` attribute in the bpg provider is ForceNew — if `tofu apply` runs
while VMs are on the wrong node, it would destroy and recreate them (destroying
vdb). A `lifecycle { ignore_changes = [node_name, initialization] }` rule on the
VM resource prevents this, acting as a safety net. The `initialization` ignore
is necessary because snippet file IDs include the node name — HA migration
changes the node, which changes the snippet ID, which would otherwise trigger
recreation.

**CIDATA content changes still force recreation** despite `ignore_changes`.
A separate `terraform_data.cidata_hash` resource tracks the SHA256 of the
user_data and meta_data template content. The VM resource's
`replace_triggered_by` references this hash resource. This decouples two
concerns:
- **Content changes** (domain, IP, search domain, write_files) → hash changes
  → `replace_triggered_by` fires → VM replaced
- **Node changes** (HA migration) → snippet ID changes → `ignore_changes`
  suppresses → VM preserved

Without this decoupling, a partial or failed `tofu apply` could update
snippet files on the Proxmox host (consuming the diff) without recreating
VMs, leaving them running with stale CIDATA. Cloud-init reads CIDATA once
at VM creation — updating the snippet on the host does not update the
running VM.

Recovery is a two-step process: restore the failed node, then rebalance.
The framework handles this through notification, autonomous recovery, and a
manual fallback.

**Notification: Gatus placement drift alert.**

A placement health endpoint runs on the NAS (alongside the sentinel Gatus). It
compares actual VM placement (queried from the Proxmox API) against intended
placement (from `config.yaml → vms.<name>.node`). When there's a mismatch:

- If the intended node is down: Gatus alerts "VM placement drift detected —
  waiting for node recovery" with the list of misplaced VMs.
- If the intended node is back up: Gatus alerts "node recovered — rebalance
  ready" with the specific recovery steps.

Alert content includes:
```
VMs on wrong nodes after failover:
  dns1-prod: intended=pve01, actual=pve02
  cicd: intended=pve01, actual=pve03

pve01 status: DOWN (or: UP — ready for rebalance)

Recovery steps:
  1. Ensure pve01 is booted and has rejoined the cluster
  2. Run: framework/scripts/rebalance-cluster.sh
  3. Verify: tofu plan shows 0 changes
```

**Autonomous recovery: placement watchdog on the NAS.**

A systemd timer on the NAS (every 5 minutes) runs `placement-watchdog.sh`:

1. Query Proxmox API for actual VM placement on each node
2. Read intended placement from `config.yaml → vms.<name>.node`
3. If no drift: exit silently
4. If drift detected AND all nodes are healthy (all repl-health endpoints
   responding): run `rebalance-cluster.sh` automatically, send email
   confirmation
5. If drift detected BUT a node is still down: log and wait (VMs are
   correctly on survivors — rebalancing isn't possible yet)

**Safety constraint:** The watchdog only rebalances when ALL nodes are healthy.
It never moves VMs while a node is down — that would reduce availability, not
improve it.

**Manual fallback: `rebalance-cluster.sh`.**

The operator can always run `rebalance-cluster.sh` manually. The script:

1. Reads intended placement from config.yaml
2. Queries actual placement from the Proxmox API
3. For each VM on the wrong node: runs `ha-manager migrate <vmid> <intended-node>`
4. Waits for each migration to complete
5. Runs `tofu plan` to verify zero changes (with the appropriate ACME override
   if staging certs are in use)

The script is idempotent — if all VMs are already on their intended nodes, it
reports "no drift" and exits.

**Full lifecycle:**
```
Normal:     All VMs on intended nodes. Watchdog silent. tofu plan clean.

Failure:    Node dies.
            HA migrates VMs to survivors (<120 seconds measured).
            Gatus alerts: node health endpoint DOWN.
            Watchdog detects drift, logs "waiting for node recovery."
            Gatus alerts: "VM placement drift detected."

Recovery:   Node powers on (operator action, UPS recovery, or watchdog reboot).
            Node rejoins cluster (~15 seconds measured).
            Gatus alerts: node health endpoint UP.
            Watchdog detects all nodes healthy + drift exists.
            Watchdog runs rebalance-cluster.sh automatically.
            VMs migrate back to intended nodes (~1 min per VM, sequential).
            Watchdog sends email: "Automatic rebalance completed."
            Next watchdog run: no drift, exit silently.
            tofu plan shows 0 changes.
```

The operator's only required action is powering on the failed node. If the node
recovers automatically (power cycle, UPS restore), the entire sequence from
failure to full recovery is autonomous.

**Home Assistant note:**
- Home Assistant has no application-level redundancy or failover features
- All failover is handled by Proxmox HA (not by Home Assistant itself)
- Home Assistant tolerates up to 1 minute of state loss on failover (acceptable)
- Home Assistant VM is not generated from Git sources — it runs HAOS directly
- HA priority ensures it restarts before other VMs after node failure

**Contrast with Ceph (rejected for 3-node clusters, planned for 5+):**
- Ceph enables seamless live migration but requires 5+ nodes to be operationally comfortable
- At 3 nodes, Ceph quorum loss takes all storage offline — a catastrophic failure mode
- ZFS local storage is inherently resilient: losing a node only affects VMs running on that node
- For unplanned failures, both Ceph and ZFS have the same ~45–90 second failover time
- Ceph eliminates the ZFS-specific operational overhead (orphan zvol cleanup, snippet
  replication to all nodes, placement drift reconciliation) but introduces its own
  operational requirements (monitor quorum, OSD management, crush maps)
- The framework is designed for a future `storage.backend: ceph` abstraction —
  see section 20.6 for the planned design

### 11.4.1 Partial-Deploy Failure Pattern

**Problem:** When deploy orchestration fails partway through a VM recreation,
VMs can end up in inconsistent state: some recreated with new images, others
still running old images, and vdb restoration incomplete. PBS backups can then
capture the inconsistent post-failure state. If subsequent backup runs
overwrite the pre-failure backup, the damage propagates forward and recovery
requires manual investigation of which state is healthy.

This is a recurring architectural weakness. Known instances:

- **GitLab 11-hour data loss (March 2026):** raw `tofu apply` run by
  operator from automation output; restore did not run; GitLab vdb lost.
- **workstation_dev first-boot deadlock (April 2026):** partial deploy left
  VM in unconfigured state; manual intervention required.
- **roon_dev silent vdb wipe (April 2026):** the old late restore hook did
  not run after VM recreation; 14 subsequent empty backups captured the gap
  before the problem was detected.
- **influxdb_dev cert stub persistence (April 2026):** cert lineage written
  to wrong path during a partial deploy; PBS backups captured the stub and
  propagated it forward.

**Root cause class:** the old single-phase apply could start recreated VMs
before vdb restore. A crash at any point between VM recreation and restore
left the VM in a state the framework did not intend, and PBS dutifully backed
that state up.

**Mitigation (current, Sprint 031 / #224):** destructive deploy paths no
longer let backup-backed VMs boot between recreation and restore.
`safe-apply.sh` and `rebuild-cluster.sh` take a pre-deploy backup pin, derive
a restore manifest from `tofu plan -json`, run Phase 1 with
`start_vms=false` and `register_ha=false`, restore each manifest VMID's vdb
with `restore-before-start.sh`, and only then run Phase 2 to start VMs and
register HA. If Phase 1 fails partway, recovery runs
`restore-before-start.sh --recovery-mode` and skips Phase 2. PBS retention
still provides a recovery window, but it is no longer the primary mitigation
for deploys that recreate precious-state VMs.

---

## 12. Application Deployment Model

### 12.1 Deployment Strategy

**Decision:** Hybrid (Nix-native preferred, Docker Compose when practical)

**Options considered:**
- Nix-native only (all apps as NixOS services)
- Docker Compose only (all apps containerized)
- Hybrid (use what exists, migrate over time)

**Motivations:**
- **Fast initial deployment:** Use existing solutions (NixOS modules or Compose files)
- **Pragmatic approach:** Don't let perfect be the enemy of working
- **Migration path:** Can move from Compose to Nix-native based on experience
- **Learn by doing:** Discover the balance through actual implementation
- **Optimistic but prepared:** Hope for Nix-native, ready for Compose reality

**Decision rule:**
1. Check if good NixOS module exists → use it (Nix-native)
2. Check if official Docker Compose exists → wrap it (Compose wrapped by NixOS)
3. Later: evaluate migration based on complexity and value

### 12.2 Container Image Management

**Decision:** Images specified with SHA256 digests, managed declaratively

**Motivations:**
- **No surprise updates:** Components only change via Git commit
- **Reproducibility:** Same config = same deployment
- **Aligns with rebuildability goal:** Know exactly what's running
- **Audit trail:** Git history shows when/why images changed

**For Docker Compose:**
```yaml
services:
  myapp:
    image: myapp/myapp@sha256:abc123...  # Pinned digest
```

**For Nix:**
```nix
pkgs.dockerTools.pullImage {
  imageName = "myapp/myapp";
  imageDigest = "sha256:abc123...";
  sha256 = "...nix-hash...";
}
```

**Update workflow:**
1. New upstream version released
2. Pull image, get digest
3. Update digest in Git
4. PR → CI validates → merge → deploy

**Future exploration:** Nix building container images (declarative, no registry dependency)

### 12.3 Deployment Patterns

**Pattern 1: Simple Nix-Native Service**

**When to use:** Service has good NixOS module, straightforward config

**Example:**
```nix
services.postgresql = {
  enable = true;
  package = pkgs.postgresql_15;
  dataDir = "/var/lib/postgresql/15";  # On vdb (data disk)
  settings = {
    max_connections = 100;
    shared_buffers = "256MB";
  };
};

# Secrets from Vault
systemd.services.postgresql.serviceConfig = {
  EnvironmentFile = "/run/secrets/postgresql/env";
};

# Data disk mount
fileSystems."/var/lib/postgresql" = {
  device = "/dev/vdb";
  fsType = "ext4";
};
```

**Pattern 2: Docker Compose Wrapped by NixOS**

**When to use:** Complex app, official Compose file exists, no good Nix module

**Example:**
```nix
let
  composeFile = pkgs.writeText "docker-compose.yml" ''
    version: '3'
    services:
      homeassistant:
        image: homeassistant/home-assistant@sha256:abc123...
        volumes:
          - /var/lib/homeassistant:/config
        env_file:
          - /run/secrets/homeassistant/env
        network_mode: host
  '';
in
{
  virtualisation.docker.enable = true;
  
  # Data disk mount
  fileSystems."/var/lib/homeassistant" = {
    device = "/dev/vdb";
    fsType = "ext4";
  };
  
  # systemd manages compose lifecycle
  systemd.services.homeassistant = {
    description = "Home Assistant";
    after = [ "docker.service" ];
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.docker-compose}/bin/docker-compose -f ${composeFile} up -d";
      ExecStop = "${pkgs.docker-compose}/bin/docker-compose -f ${composeFile} down";
    };
  };
}
```

### 12.4 Service Discovery

**Decision:** DNS-based service discovery with unqualified hostnames

**Motivations:**
- Already building DNS infrastructure
- Works for all services (Nix-native and containerized)
- Standard protocol, well-understood
- No additional services needed (no Consul, service mesh)

**Pattern:**
- VMs reference infrastructure services using unqualified hostnames: `vault`, `acme`, `dns1`, `dns2`
- The CIDATA-provided search domain (e.g., `prod.example.com` or `dev.example.com`) resolves these to the correct environment-specific FQDN (Fully Qualified Domain Name)
- This is the mechanism by which VMs remain environment-ignorant — they never contain FQDNs that embed an environment name
- Application services may use FQDNs where appropriate (e.g., `postgres.prod.example.com` from within prod), but infrastructure services should always use unqualified names to preserve environment ignorance

**For containers:** Container can resolve external DNS (not isolated)

### 12.5 Service Addition Workflow

**To add a new service:**

1. **Create NixOS module** (`modules/services/myservice.nix`)
2. **Create host configuration** (`hosts/myservice-vm.nix`)
3. **Build VM image** (includes NixOS config for this role)
4. **Upload image to Proxmox**
5. **Create OpenTofu resources** (VM + data disk)
6. **Add DNS records**
7. **Configure secrets** (in Vault or SOPS)
8. **Deploy via CI/CD** (merge to dev, then main)

### 12.6 Migration Path: Compose → Nix-Native

**When to migrate:**
- Service becomes long-lived, business-critical
- Compose overrides grow large/fragile
- Want deeper integration (backup, monitoring)
- Learning opportunity

**How to migrate:**
1. Study Compose file, understand requirements
2. Write equivalent Nix module
3. Deploy in dev, test thoroughly
4. Compare behavior, ensure parity
5. Cutover in prod
6. Remove Compose wrapper

### 12.7 Monorepo Structure: Framework vs Site Configuration

The monorepo is organized to separate reusable framework components from site-specific configuration. This enables open-source release of the framework while keeping site secrets and details private.

```
mycofu/
├── framework/                    # Reusable (open-sourceable)
│   ├── nix/
│   │   ├── modules/              # NixOS modules for each role
│   │   │   ├── dns.nix           # PowerDNS server role
│   │   │   ├── vault.nix         # Vault server role
│   │   │   ├── gatus.nix         # Health monitoring role
│   │   │   ├── certbot.nix       # ACME certificate management
│   │   │   ├── vault-agent.nix   # Secret retrieval
│   │   │   └── base.nix          # Common config for all VMs
│   │   ├── lib/                  # Shared Nix functions
│   │   └── checks/
│   │       └── source-filter-check.nix  # Canary test: verifies nixSrc filter integrity
│   ├── tofu/
│   │   ├── modules/
│   │   │   ├── proxmox-vm/       # VM creation with vda/vdb, HA, cloud-init
│   │   │   ├── dns-pair/         # DNS server pair with anti-affinity
│   │   │   └── environment/      # Complete environment stack
│   │   └── providers.tf          # Provider configuration (parameterized)
│   ├── scripts/
│   │   ├── configure-node-network.sh  # Generate and deploy /etc/network/interfaces
│   │   ├── configure-node-storage.sh  # Identify data NVMe and create ZFS pool
│   │   ├── form-cluster.sh        # Automated Proxmox cluster formation
│   │   ├── repl-watchdog.sh       # Ping-based link watchdog (deployed to nodes by configure-node-network.sh)
│   │   ├── repl-health.sh         # Replication health endpoint (deployed to nodes by configure-node-network.sh)
│   │   ├── bootstrap-sops.sh      # Age key generation, SOPS config, initial secrets
│   │   ├── build-image.sh        # Build NixOS VM image (content-addressed)
│   │   ├── upload-image.sh       # Upload image to all Proxmox nodes
│   │   ├── configure-replication.sh  # Configure ZFS replication jobs
│   │   ├── new-site.sh           # Generate site/config.yaml from framework/templates/
│   │   ├── init-vault.sh         # Scripted Vault init and unseal (never exposes key in plaintext)
│   │   ├── rebuild-cluster.sh    # Full cluster rebuild from bare Proxmox nodes (single command)
│   │   ├── rebalance-cluster.sh  # Migrate VMs back to intended nodes after HA failover
│   │   ├── placement-watchdog.sh # Autonomous placement drift detection + auto-rebalance (runs on NAS)
│   │   ├── reset-cluster.sh      # Factory reset: tear down cluster, erase generated secrets
│   │   ├── ha-deploy.sh          # Home Assistant config deploy
│   │   ├── ha-capture.sh         # Home Assistant config capture
│   │   ├── validate.sh           # Bootstrap validation
│   │   ├── post-deploy.sh       # Post-deploy recovery (replication, vault, backups)
│   │   ├── check-source-filter.sh # Lint: verify nixSrc filter integrity
│   │   └── sync-to-main.sh      # Sync framework changes from dev to main branch
│   ├── templates/
│   │   ├── config.yaml.example   # Template with example values
│   │   └── images.yaml.example   # Template for site/images.yaml
│   ├── images.yaml               # Framework image manifest (infrastructure roles)
│   ├── bringup/
│   │   ├── generate-bringup.py   # Bringup checklist generator
│   │   ├── generate-bringup.sh   # Shell wrapper
│   │   └── templates/            # Platform-specific Jinja2 templates
│   ├── gatus/
│   │   └── config-template.yaml  # Gatus config with placeholders
│   └── docs/
│       └── ARCHITECTURE.md       # This document
│
├── site/                         # Site-specific (absent on main branch, tracked on dev/prod)
│   ├── config.yaml               # Actual site config (generated by new-site.sh, then tracked)
│   ├── images.yaml               # Site image manifest (application roles)
│   ├── bringup.md                # Generated by generate-bringup.sh (gitignored)
│   ├── tofu/
│   │   ├── main.tf               # Instantiates framework modules with site values
│   │   ├── prod.tfvars           # Prod environment values
│   │   ├── dev.tfvars            # Dev environment values
│   │   ├── .terraform/           # Provider cache (gitignored)
│   │   ├── .terraform.lock.hcl   # Provider lock file (gitignored)
│   │   └── image-versions.*.tfvars  # Build artifacts (gitignored)
│   ├── dns/
│   │   └── zones/                # Zone YAML files with actual IPs and records
│   ├── nix/
│   │   └── hosts/                # Per-VM host configs referencing framework modules
│   ├── sops/
│   │   ├── .sops.yaml            # SOPS configuration
│   │   └── secrets.yaml          # Encrypted site secrets
│   ├── apps/                     # Application config files (referenced by nix modules)
│   ├── gatus/
│   │   └── config.yaml           # Generated from template + site config (gitignored)
│   └── home-assistant/
│       └── config/               # HA configuration files
│
├── .gitignore                    # Ignores generated artifacts within site/, NOT site/ itself
└── README.md
```

**Key separation principles:**

The `framework/` directory contains everything that is parameterized and reusable. No domain names, IP addresses, hostnames, hardware details, or secrets appear here. A new user never needs to edit anything in `framework/`.

The `site/` directory contains everything specific to one deployment. A new user clones the repo, runs `new-site.sh` to generate their own `site/` from the template, and the framework handles the rest. The primary entry point is `site/config.yaml`, which defines:

```yaml
# site/config.yaml
# Domain — the single source of truth for all DNS names.
# Changing this field and rebuilding is all that's needed to migrate
# to a different domain. Everything else is derived:
#   DNS zones:    prod.<domain>, dev.<domain>
#   GitLab URL:   https://gitlab.prod.<domain>
#   VM FQDNs:     <hostname>.<env>.<domain>
domain: example.com
environments:
  prod:
    vlan_id: 10
    subnet: 10.0.10.0/24
    gateway: 10.0.10.1
    # dns_domain derived: prod.<domain>
  dev:
    vlan_id: 20
    subnet: 10.0.20.0/24
    gateway: 10.0.20.1
    # dns_domain derived: dev.<domain>

nodes:
  - name: node1
    ip: 10.0.10.1
  - name: node2
    ip: 10.0.10.2
  - name: node3
    ip: 10.0.10.3

# VM inventory — each VM has a VMID, IP, MAC, and intended node for placement.
# VMID uses a hundreds-digit scheme. Dev and prod are adjacent pairs:
# odd hundreds = dev, even hundreds = prod. Same role = same offset across
# environments (e.g., dns1=01, so dns1-dev=301, dns1-prod=401).
#   1xx = shared infra (gitlab=150, cicd=160, pbs=190)
#   3xx = dev infra     4xx = prod infra
#   5xx = dev apps      6xx = prod apps
#   7xx = vendor appliance apps (HAOS, etc.)
# VMIDs are pre-allocated by new-site.sh. They are stable across rebuilds:
#   - PBS backups are filed under the same ID after a scorched-earth rebuild
#   - HA resources survive VM recreation (no double-apply workaround needed)
#   - ZFS zvol names are predictable (vm-<vmid>-disk-0, vm-<vmid>-disk-1)
# The 'node' field is the source of truth for where each VM should run.
# After an HA failover, rebalance-cluster.sh reads these values to migrate
# VMs back to their intended nodes.
vms:
  dns1_prod:
    vmid: 401
    ip: 10.0.10.50
    mac: "02:xx:xx:xx:xx:xx"
    node: node1
  dns2_prod:
    vmid: 402
    ip: 10.0.10.51
    mac: "02:xx:xx:xx:xx:xx"
    node: node2
  # ... additional VMs with vmid, ip, mac, node ...

nas:
  hostname: nas.example.com
  ip: 10.0.10.100

# Additional site-specific values...
```

Framework modules read from this config (or from OpenTofu variables derived from it) and never hardcode site-specific values.

**Open-source release strategy:**

The public repository (GitHub) contains `framework/`, `README.md`, `.gitignore`, and documentation. The `site/` directory simply does not exist on the `main` branch — it is not gitignored, it was never created. The `main` branch has never had a `site/` directory, so there is nothing to ignore. The `.gitignore` contains entries for generated artifacts *within* `site/` that should not be tracked even on `dev`/`prod` branches where `site/` exists:

```gitignore
# Generated artifacts within site/ — these are build outputs, not source
site/tofu/image-versions.auto.tfvars
site/tofu/image-versions.local.auto.tfvars
```

The config template lives at `framework/templates/config.yaml.example` — on the framework side of the ownership boundary, because it is a framework artifact used by `new-site.sh` to generate the user's actual config.

**Why `site/` cannot be in `.gitignore`:** The Nix flake uses `self` as its source tree, which includes only git-tracked files. The `nixSrc` filter (see section 11.1.2) further restricts this to nix-relevant files. `site/nix/hosts/*.nix` and `site/apps/*` are nix build inputs — if `site/` were gitignored, these files would be invisible to `self` and every image build would fail. The `.gitignore` must only target specific generated artifacts within `site/`, never the directory itself.

**Third-party operator experience:**

A new operator who clones the public repo should be able to reach a fully operational
cluster by providing only the information that is genuinely theirs to decide:

| What the operator provides | Why it can't be auto-generated |
|---------------------------|-------------------------------|
| Domain name | Their registrar, their choice |
| Node management IPs | Set during Proxmox install |
| VLAN IDs and subnets | Their network, their choice |
| NAS IP | Their hardware |
| Public IP | Their ISP |
| SMTP settings | Their email provider |
| Proxmox API password | They set this during Proxmox install |
| PostgreSQL password | They set this during NAS setup |

Everything else — VM MAC addresses, VM IP assignments, PowerDNS API key, age keypair,
SSH keypair — is auto-generated by the tooling.

**New operator workflow:**

```bash
git clone <public-repo-url>
cd mycofu
framework/scripts/new-site.sh        # generates site/ with config.yaml,
                                      # nix host configs, tofu modules, etc.
# edit site/config.yaml              # fill in only the operator-specific values above
git add site/ && git commit -m "initial site configuration"
framework/scripts/bootstrap-sops.sh  # generates age key, prompts for the two passwords
                                      # the operator set themselves, auto-generates
                                      # everything else, produces site/sops/secrets.yaml
# physical steps: install Proxmox, configure gateway, set up NAS (see bringup.md)
framework/scripts/rebuild-cluster.sh # builds and deploys everything
```

The operator authors exactly one file (`site/config.yaml`) and is prompted for exactly
two secrets (the two passwords they already set up on their own hardware).

**`framework/scripts/new-site.sh`** copies `framework/templates/config.yaml.example` to `site/config.yaml` and generates a ready-to-edit config with:
- All VM IDs pre-allocated using a hundreds-digit scheme (1xx shared infra
  including PBS at 190; odd=dev, even=prod: 3xx/4xx infra, 5xx/6xx apps;
  7xx vendor appliance apps; same role = same offset across dev/prod)
- All VM MAC addresses pre-generated (random locally-administered MACs, `02:xx` format)
- All VM IPs pre-allocated using fixed offsets: DNS at `.50`/`.51`, Vault at `.52`,
  acme-dev at `.53`, PBS at `.60`, CI/CD at `.61`, Gatus at `.62`, HAOS at `.63`
- Sensible defaults for all optional fields pre-set
- `# REQUIRED:` and `# OPTIONAL:` markers on every field

The script is safe to re-run: exits with a warning and does nothing if
`site/config.yaml` already exists.

**Repository versioning model:**

Development uses three branches and two remotes:

- **`main` branch:** The public branch. Contains `framework/`, docs, `README.md`, and `.gitignore`. Does not contain `site/` — the directory was never created on this branch, not gitignored. Pushed to GitHub. Community PRs land here. No CI/CD pipeline on GitLab.

- **`dev` branch:** The development and dev-deployment branch. Contains everything on `main` plus `site/` — config, SOPS secrets, extra DNS records, application config, Home Assistant config. Pushed to GitLab (private). Pushes to `dev` trigger the dev deploy pipeline.

- **`prod` branch:** The production deployment branch. Always equal to or behind `dev`. Changes arrive only via merge requests from `dev`. Pushes to `prod` (via MR merge) trigger the prod deploy pipeline. Protected: no direct push.

`dev` and `prod` are both strict supersets of `main`. The merge directions are: `main → dev` (framework updates from public repo) and `dev → prod` (promotion after dev validation). There are never merge conflicts because `main` never touches `site/`, and `prod` only receives commits that already exist on `dev`.

This three-branch model is the intended deployment model for every Mycofu user. Every operator has the same structure: a `main` branch they pull framework updates into, a `dev` branch where development and dev deployment happen, and a `prod` branch that receives validated changes via merge request.

**Day-to-day development (framework maintainer):**

Development happens on `dev`, where both `framework/` and `site/` are
present and changes can be tested immediately against real configuration.
When framework changes are ready for release, they are synced to `main`:

```
# Develop and test on dev (framework + site available)
git checkout dev
# edit framework/... and test
git commit -m "fix DNS module edge case"
# iterate as needed — no branch switching during development

# When ready to publish framework changes
framework/scripts/sync-to-main.sh "description of framework changes"
# This script:
#   1. Checks out main
#   2. Applies framework/ changes from dev as a single commit
#   3. Pushes main to GitHub
#   4. Checks out dev
#   5. Merges main into dev (keeps branches in sync)
#   6. Pushes dev to private remote
```

Site-only changes never leave `dev`/`prod`:

```
# Already on dev
$EDITOR site/config.yaml
git commit -m "update site config"
git push gitlab dev
# Dev pipeline deploys to dev. Test. Then promote:
# Create MR from dev → prod in GitLab. Merge. Prod pipeline deploys to prod.
```

**Community PR workflow:**

```
git checkout main
git pull origin main        # Get the PR from GitHub
git checkout dev
git merge main              # Always clean — main never touches site/
git push gitlab dev         # Dev pipeline runs against merged code + site config
# After dev validation, promote to prod via MR
```

**Operator workflow (community user):**

```
# Initial setup
git clone <github-url> mycofu     # Clone public repo (gets main branch)
cd mycofu
git checkout -b dev               # Create dev branch
framework/scripts/new-site.sh     # Creates site/ from framework/templates/
$EDITOR site/config.yaml          # Fill in your values
git add site/                     # Track site-specific config
git commit -m "initial site config"
git checkout -b prod              # Create prod branch (identical to dev)

# Add private remote for dev and prod branches
git remote add gitlab <your-gitlab-url>
git push gitlab dev
git push gitlab prod

# Pull framework updates
git checkout main
git pull origin main              # Get upstream framework changes
git checkout dev
git merge main                    # Always clean
git push gitlab dev               # Dev pipeline runs
# After validation, promote to prod via MR in GitLab
```

**What goes where:**

| Content | `main` (GitHub) | `dev` / `prod` (GitLab) |
|---------|-----------------|---------------------|
| `framework/` (modules, scripts, templates, docs) | ✓ | ✓ |
| `framework/templates/config.yaml.example` | ✓ | ✓ |
| `site/config.yaml` | ✗ | ✓ |
| `site/sops/secrets.yaml` | ✗ | ✓ |
| `site/dns/zones/` | ✗ | ✓ |
| `site/home-assistant/config/` | ✗ | ✓ |
| `.gitlab-ci.yml` | ✓ | ✓ |
| `README.md` | ✓ | ✓ |

**Why merges are always clean:** `main` never contains `site/` — the directory simply doesn't exist on that branch. `dev` and `prod` have `site/` as additional tracked files. When merging `main → dev`, git only sees changes to files that exist on both sides (`framework/`, docs, etc.). The `site/` directory is invisible to the merge because `main` has no opinion about it. When merging `dev → prod`, both branches have the same set of tracked files, so the merge is a fast-forward (prod is always behind or equal to dev).

**Safety:** The `main` branch simply never contains `site/` — the directory was never created there. A contributor who clones the public repo gets no `site/` directory at all. If they run `new-site.sh` to test locally and then create a PR, their PR is against `main` which has no `site/` files, so `site/` won't appear in the diff unless they explicitly `git add` it — and code review catches that. The `.gitignore` contains entries only for build artifacts within `site/` (e.g., `site/tofu/image-versions.auto.tfvars`) that should not be tracked even on branches where `site/` exists.

**For new users:**

1. Clone the public repo (gets `main` branch)
2. Create `dev` and `prod` branches
3. Run `framework/scripts/new-site.sh` (creates `site/` from `framework/templates/`)
4. Fill in `site/config.yaml` with site-specific values
5. `git add site/` and commit on `dev`
6. Create `prod` from `dev` (`git checkout -b prod`)
7. Add GitLab as a remote, push both `dev` and `prod`
8. Keep `main` tracking the public repo for framework updates

### 12.8 Application Configuration Model

**Decision:** Application VM specifications live in `site/applications.yaml`, separate from framework VM and cluster topology configuration in `site/config.yaml`.

**Motivation:**

Framework VMs (DNS, Vault, PBS, Gatus, GitLab, CI/CD runner) and application VMs (Grafana, InfluxDB, Roon, Home Assistant, etc.) are genuinely different objects with different ownership, different lifecycle, and different who-edits-this. An operator adding a new application does not need to navigate framework VM configuration, and should not have to. The split makes each file's scope self-evident.

An application VM specification is a single logical object: node placement, resource allocation, per-environment addressing, and app-specific parameters. Spreading this object across multiple files — `config.yaml`, `site/nix/hosts/<app>.nix`, `flake.nix`, OpenTofu modules — makes the object implicit. The operator must hold the full object in their head by assembling pieces from multiple locations. `applications.yaml` makes the object explicit and contiguous.

**`enable-app.sh` contract:**

`enable-app.sh <appname>` is the generator for `applications.yaml` entries. It:

1. Reads `site/config.yaml` for cluster topology (subnets, VMID ranges, existing allocations)
2. Reads `framework/catalog/<app>/` for defaults (RAM, cores, disk sizes, health endpoints, backup flag)
3. Allocates VMID, IP, and MAC for each environment without prompting the operator
4. Appends a complete, self-documenting block to `site/applications.yaml`
5. Continues to write `site/nix/hosts/<app>.nix` and copy `site/apps/<app>/` config files as before
6. Prints a summary of what was generated and what the operator should review

The generated block is the operator's primary interface. Every derivable value is filled in with a comment explaining its derivation. Every constraint (valid IP range, VMID scheme) is stated adjacent to the value it constrains, with a grep command for duplicate checking. The operator reviews the block, overrides anything that needs changing, and proceeds. No interactive prompting.

**Inline comment format:**

```yaml
applications:
  grafana:
    # node: node1    # default: least-loaded node at generation time
    node: node1
    ram: 1024        # default from catalog; override if needed
    cores: 2
    disk_size: 4
    data_disk_size: 4
    backup: false    # set true if this app has precious state on vdb

    environments:
      prod:
        # IP must be in prod subnet: 10.0.10.50–10.0.10.254
        # Check for duplicates: grep 'ip:' site/config.yaml site/applications.yaml
        ip: 10.0.10.65
        # VMID scheme: 6xx = prod apps; same role offset across dev/prod
        # Check for duplicates: grep 'vmid:' site/config.yaml site/applications.yaml
        vmid: 601
        # MAC is stable across rebuilds — preserves layer 2 identity on rebuild
        mac: 02:ab:cd:ef:12:34
      dev:
        ip: 10.0.20.65
        vmid: 501
        mac: 02:ab:cd:ef:56:78

    # App-specific parameters — see framework/catalog/grafana/README.md
    # health_port: 443
    # health_path: /api/health
```

**Convention-over-configuration:**

Derived values are filled in by the generator; the operator overrides by editing the value directly. Framework defaults are shown as comments where relevant. App-specific optional parameters that cannot be derived (e.g., `mounts`, `mgmt_nic`, `proxmox_metrics`) are emitted as commented-out placeholders pointing to the app's README.

**Dependency note:**

`applications.yaml` depends on topology values defined in `site/config.yaml` (subnets, VMID ranges, node names). If you change subnets or VMID ranges in `config.yaml`, the range comments in `applications.yaml` will be stale and must be updated manually. A note in `config.yaml` near the subnet and VMID scheme definitions reminds the operator of this.

**Config validation:**

`framework/scripts/validate-site-config.sh` is a standalone consistency checker
for `site/config.yaml` and `site/applications.yaml`. It is called by every
consumer of these files before triggering any side effects. Consumers include
`enable-app.sh`, `tofu-wrapper.sh`, and `build-all-images.sh`. If validation
fails, the consumer prints the errors and exits without proceeding.

This script is distinct from `validate.sh`, which validates a running cluster.
`validate-site-config.sh` validates the config files themselves — before
anything is built or deployed.

Checks performed:
- VMID uniqueness across both files
- IP uniqueness per environment across both files
- MAC uniqueness across both files
- Application VMIDs within correct ranges (5xx dev, 6xx prod)
- Application IPs within declared subnets
- Node references exist in `config.yaml → nodes`
- Both files are valid YAML with required fields present

The script exits 0 silently on success. It exits 1 with all failures reported
before exiting — it does not stop at the first error.

**Migration:**

Existing application entries in `site/config.yaml` (added by previous versions of `enable-app.sh`) should be moved to `site/applications.yaml` manually by the operator. This is a one-time migration. Move the block, verify the result, remove the old entry from `config.yaml`. Do not run the migration with a script — the operator should see and confirm what moved.

---

## 13. Bootstrap Sequence

### 13.1 Pre-requisites

**Irreducible physical steps (always manual — cannot be automated):**

- Rack hardware and cable all nodes to the managed switch
- Cable point-to-point replication links between node pairs
- Boot each node from the Proxmox ISO and run the installer (sets management IP,
  hostname, root password, and creates the boot ZFS pool). NIC pinning during
  install is optional — `configure-node-network.sh` auto-discovers the cabling
  topology and writes correct interface naming rules regardless of installer choices.
- Configure the VLAN-capable gateway: VLANs, routing between subnets,
  firewall rules, and port 53 forwarding to prod DNS servers. DHCP scopes
  are optional (only needed for non-Mycofu devices on each VLAN). No DHCP
  reservations are needed — Mycofu VMs use static addressing from config.yaml.
- Configure DNS delegation at the registrar: A records for `dns1.<domain>` and
  `dns2.<domain>` pointing to the site's public IP, and NS delegation for
  `prod.<domain>` to those names. Do not change NS records for the base domain —
  the registrar stays authoritative for email (MX, SPF, DMARC).
- Provide the SOPS age private key (`operator.age.key`) on the operator workstation

**Operator workstation software requirements:**

The following tools must be installed on the operator workstation (macOS or Linux).
Framework scripts assume these are available in `$PATH`:

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

`sshpass` is used by `configure-node-network.sh` to install the operator's SSH
public key on freshly installed Proxmox nodes (which only have password auth).
The password is read from SOPS. After key installation, all subsequent SSH
connections use key auth.

**Everything else is automated by `framework/scripts/rebuild-cluster.sh`:**

Once the physical steps are complete and the age key is in place, the rebuild script
handles all remaining work in the correct dependency order. See section 13.2 for the
automated sequence.

**One-time setup (first deployment only, not needed on rebuild):**

- Run `framework/scripts/new-site.sh` to generate `site/config.yaml` with all
  auto-generatable fields pre-populated (VM MAC addresses, VM IPs, etc.)
- Edit `site/config.yaml` to fill in the genuinely site-specific values (domain,
  node management IPs, subnets, gateway IPs, NAS IP, SMTP settings)
- Run `framework/scripts/bootstrap-sops.sh` to generate the age keypair, prompt
  for the two passwords the operator set themselves (Proxmox API password,
  PostgreSQL password), auto-generate all other secrets (PowerDNS API key), and
  produce the encrypted `site/sops/secrets.yaml`
- Back up `operator.age.key` to a secure location before doing anything else
- Register the domain and configure the registrar (only needs doing once)

### 13.2 Day 1 - First Deployment

After completing the physical prerequisites in section 13.1, run:

```bash
framework/scripts/rebuild-cluster.sh
```

This script executes the following sequence automatically:

1. **Configure node networking** — runs `configure-node-network.sh` on each node.
   First bootstraps SSH key auth (using SOPS password if needed on fresh installs),
   then auto-discovers which physical NIC connects to which peer via link-local
   probing, writes systemd `.link` files for correct interface naming, reboots
   nodes if naming changes are needed, and deploys the full interface configuration
   (management, VLAN-aware bridge, replication interfaces, dummy0, routes, watchdog,
   health endpoint). The script is self-contained — it handles its own reboots and
   re-verification.

2. **Configure node storage** — runs `configure-node-storage.sh` on each node to
   create the ZFS data pool

3. **Form the Proxmox cluster** — runs `form-cluster.sh` to join all nodes into a
   single cluster with dual corosync links

4. **Build VM images** — runs `build-image.sh` for each VM role (dns, vault, pbs,
   cicd, gatus, haos) using the configured Nix builder

5. **Upload images** — runs `upload-image.sh` to place each image on all Proxmox nodes

6. **Initialize OpenTofu** — runs `tofu init` (creates the PostgreSQL schema if it
   does not exist, downloads providers)

7. **Deploy all VMs** — runs `tofu apply` which creates all VMs with nocloud-init
   delivering hostnames, SSH keys, and pre-deploy bootstrap secrets (PowerDNS API
   key, ACME URL, forward-zone domain) via `write_files`. DNS zone data is also
   delivered via CIDATA `write_files` — OpenTofu generates the zone records from
   `config.yaml` (infrastructure VMs + applications) and includes them in the DNS
   VM's CIDATA payload. A systemd oneshot on each DNS VM loads the zone data into
   PowerDNS at boot, so no separate zone deployment step is needed. Post-deploy
   secrets (Vault unseal key, runner token) are NOT in CIDATA — they are delivered
   in later steps via SSH. See section 9.4 for the two delivery mechanisms and
   section 11.1.1 for why post-deploy secrets must not be in CIDATA.

   The PBS VM is also created by `tofu apply`, but unlike NixOS VMs it boots into
   the Proxmox Backup Server installer ISO rather than a working system. Step 7.5
   handles the unattended installation.

7.5. **Install PBS** — runs `install-pbs.sh` which performs an unattended
   installation of the PBS VM using the Proxmox answer file mechanism.

   **How it works:** Proxmox installers (both VE and PBS) since version 8.1
   support automated installation via an answer file. The installer's GRUB
   menu checks for `auto-installer-mode.toml` on the ISO — if present, the
   "Automated" menu entry becomes the default and the installer reads
   `answer.toml` from the same ISO, running non-interactively.

   **Key constraint: the answer file must be embedded in the installer ISO.**
   The Proxmox installer searches only disk/USB partitions with the
   `proxmox-ais` label for answer files — it does NOT search CD-ROM devices.
   Since VMs have no physical USB, the solution is to remaster the installer
   ISO itself: extract it, add `answer.toml` and `auto-installer-mode.toml`,
   and rebuild with `genisoimage` on the Proxmox node. A separate answer ISO
   on a second CD-ROM does not work (the installer ignores it).

   The script:
   1. Checks idempotency — if PBS is already installed (HTTPS responding on
      port 8007), skips the entire step
   2. Templates `answer.toml` from config.yaml and SOPS:
      - Root password from SOPS (matching the Proxmox node password)
      - IP address, gateway, DNS from config.yaml's PBS VM entry
      - FQDN derived from domain
      - Timezone from config.yaml (`timezone` field, default UTC)
      - Disk target (the VM only has one virtual disk — always `sda`)
      - `reboot-mode = "power-off"` (see below)
      - `[network.filter]` with `ID_NET_NAME = "ens*"` (required by installer)
   3. Creates `auto-installer-mode.toml` (`[mode]\niso = {}`)
   4. Uploads both files to the Proxmox node hosting the PBS VM
   5. Remasters the PBS installer ISO on the node: extracts the original ISO,
      adds the answer file and mode file, rebuilds with `genisoimage`
   6. Removes the PBS VM from HA management (`ha-manager remove`, not
      `--state disabled` — see HA note below)
   7. Stops the VM (with verification loop — retries `qm stop --skiplock`
      until the VM is actually stopped)
   8. Attaches the remastered ISO, sets boot order to ISO first
   9. Starts the VM — installer runs unattended (~60 seconds)
   10. Waits for the VM to power off (not reboot — see below)
   11. Detaches the ISO, sets boot order to disk only
   12. Starts the VM — boots from the installed disk
   13. Waits for PBS HTTPS to respond on port 8007
   14. Cleans up: removes the remastered ISO from the node, re-adds the HA
       resource, configures NTP on the PBS VM
   15. Runs `configure-pbs.sh` which registers the datastore, creates the
       API token, and configures the Proxmox `pbs-nas` storage entry

   **Why `reboot-mode = "power-off"`:** The default installer behavior is to
   reboot after installation. In a VM, this causes a boot loop — the VM
   reboots back into the installer ISO because SeaBIOS boot order cannot be
   changed on a running VM (`qm set --boot` only modifies the config file,
   not the running QEMU process). Power-off gives the automation script a
   clean window to detach the ISO and change boot order before starting
   the VM from disk.

   **Why HA must be fully removed during install:** `ha-manager set --state
   disabled` is insufficient when the VM is actively managed — HA may have
   already queued a restart. During early iterations, this caused a race
   where HA restarted the VM into a boot loop, which Proxmox's restart
   limit then stopped, and the script mistook the stopped state for
   "installation complete." The fix is `ha-manager remove` (complete
   deregistration), `qm stop --skiplock` with a retry loop to verify the
   VM is actually stopped, then `ha-manager add` after installation.

   **Why ISO remastering happens on the Proxmox node, not the workstation:**
   macOS `hdiutil makehybrid` converts hyphens to underscores in ISO volume
   labels (`proxmox-ais` becomes `PROXMOX_AIS`). The Proxmox installer
   requires the exact label. `genisoimage` on the Proxmox node (Debian)
   handles labels correctly.

   **Answer file format** (TOML, per Proxmox documentation):
   ```toml
   [global]
   keyboard = "en-us"
   country = "us"
   fqdn = "pbs.prod.example.com"          # derived from config.yaml → domain
   mailto = "admin@example.com"            # from config.yaml → email.to
   timezone = "America/Los_Angeles"        # from config.yaml → timezone (default: UTC)
   root-password = "from-sops"             # from SOPS → proxmox_root_password
   reboot-mode = "power-off"              # essential for VM automation

   [network]
   source = "from-answer"
   cidr = "172.17.77.60/24"               # from config.yaml → vms.pbs.ip + subnet mask
   dns = "172.17.77.1"                    # management gateway
   gateway = "172.17.77.1"                # management gateway

   [network.filter]
   ID_NET_NAME = "ens*"                   # required — identifies which NIC to configure

   [disk-setup]
   filesystem = "ext4"
   disk-list = ["sda"]
   ```

   All values sourced from config.yaml and SOPS — the template is in
   `framework/templates/pbs-answer.toml.tmpl`.

   **Timing:** ~90 seconds for the full install cycle (answer file
   generation through PBS HTTPS responding). Previous manual install
   required ~10 minutes of active operator attention.

   **Applicability to other vendor appliances:** This ISO remastering
   pattern (extract → add answer file → rebuild) works for any Proxmox
   family installer (PVE, PBS, PMG). If HAOS or other vendor appliances
   support similar unattended installation mechanisms in the future, the
   same approach applies — the key is identifying where the installer
   looks for automation files and how to deliver them in a VM context
   (no physical USB, CD-ROM not searched).

7.6. **Restore precious state before VM start** — restores backup-backed VM
   data disks during the Sprint 031 preboot window, after VM creation but
   before HA registration or guest startup.

   **Rationale:** The NAS is the durability anchor. If it survived (Levels 0–2),
   PBS backups are available and precious state should be recovered — pipeline
   history, Vault secrets, application data. The operator shouldn't have to
   think about whether to restore; the deploy manifest and pin file determine
   which recreated VMs must be restored before they can start.

   **How it works:**
   1. `safe-apply.sh` and `rebuild-cluster.sh` derive a preboot restore
      manifest from the default `tofu plan -json` output. The manifest includes
      backup-backed VM creates/replaces and interrupted resumes where OpenTofu
      state shows a VM still stopped while the default plan wants it started.
   2. Phase 1 runs OpenTofu with `start_vms=false` and `register_ha=false`.
      Recreated VMs have current vda, CIDATA, MACs, and vdb attachments, but
      they remain stopped and absent from HA.
   3. `restore-before-start.sh` consumes the manifest plus the pre-deploy PBS
      pin file. For each manifest entry, it restores vdb from the pinned backup
      with `restore-from-pbs.sh --leave-stopped`. If PBS state is unknown, the
      required pin or approval is missing, or restore cannot complete, the
      deploy fails closed before any backup-backed VM starts. A known-absent PBS
      datastore is allowed only for an intentional first deploy with explicit
      per-run `FIRST_DEPLOY_ALLOW_VMIDS`.
   4. Phase 2 runs OpenTofu with `start_vms=true` and `register_ha=true`.
      Backup-backed VMs first boot with restored vdb contents, or with an
      explicitly approved first-deploy empty vdb.

   **Interaction with later steps:** Steps 9–12 detect existing state:
   - `init-vault.sh` (step 9): if vdb was restored, Vault is already
     initialized. The script unseals with the SOPS key and uses the SOPS
     root token — both match because both are write-once from the same
     `vault operator init`. If vdb was not restored, the script does fresh
     initialization and writes both to SOPS.
   - `configure-gitlab.sh` (step 12): if vdb was restored, GitLab has its
     database with projects, pipeline history, and settings. The script
     detects the existing project and skips creation. If vdb was not restored,
     the run must be an explicitly approved first deploy, so the script creates
     everything from scratch.

   **Failure semantics:** Missing or uninspectable PBS state is not treated as
   harmless. `restore-before-start.sh` records status for each manifest entry
   and aborts the batch when restore cannot be proven safe. Level 3+ rebuilds
   and first-ever deploys require the explicit first-deploy approval path before
   backup-backed VMs are permitted to boot empty.

8. **Wait for certificates** — polls each VM's certificate path until Let's Encrypt
   (prod) and step-ca (dev) have issued certs; certbot runs automatically on VM boot

9. **Initialize Vault** — runs `init-vault.sh`. Handles two cases:

    **Case 1: Fresh Vault (uninitialized — no Raft data).** The script calls
    `vault operator init`, captures the unseal key and root token entirely in
    memory, immediately encrypts them with SOPS (as backup copies), and commits
    to Git. The operator never sees the plaintext. The script then delivers the
    unseal key to the Vault VM via SSH, writing it to `/var/lib/vault/unseal-key`
    on vdb. The auto-unseal service detects the key and unseals Vault.

    **Case 2: Already initialized (vdb restored from PBS, or survived from
    previous deploy).** The script detects "already initialized" via the Vault
    API, reads the unseal key from SOPS, and unseals. The root token in SOPS
    is also valid — both values came from the same `vault operator init` and
    neither was overwritten (write-once guard). `configure-vault.sh` (step 11)
    authenticates with the SOPS root token.

    The write-once invariant is critical: `init-vault.sh` writes to SOPS ONLY
    during `vault operator init` (Case 1). If SOPS entries already exist
    (Case 2), they are not touched. This ensures SOPS always matches the
    Vault instance's Raft data, including after PBS restore.

10. **Configure Vault** — loads all policies from `framework/vault/policies/`.
    Cert auth configuration is deferred (see section 9.3 — ACME-issued
    certificates have empty CN, which Vault cert auth rejects). Policies are
    loaded so they're ready when the limitation is resolved.

11. **Configure ZFS replication** — runs `configure-replication.sh` to create
    replication jobs for all VMs. If VMs were recreated by step 7, the script
    detects orphaned zvols on target nodes (stale replicas from the old VMs),
    destroys them, and creates fresh replication jobs. This cleanup is required
    because VM recreation always orphans zvols — see section 13.2.1.

**Pipeline equivalent of steps 9–11:** In the CI/CD pipeline, these steps are
consolidated into `post-deploy.sh <env>`, which detects vault state (uninitialized,
sealed, or healthy), handles each case, runs replication cleanup, and configures
backup jobs. `rebuild-cluster.sh` runs the steps individually for more control
during a full rebuild; `post-deploy.sh` runs them automatically after every
pipeline deploy.

12. **Configure GitLab** — runs `configure-gitlab.sh`. If step 7.6 restored
    GitLab's vdb from PBS, the database already has the project, branches,
    pipeline history, and settings — the script detects the existing project
    and skips creation, but verifies branch protection and re-registers the
    runner (runner registration is stored in GitLab's database, and the runner
    VM is new). If vdb was not restored, the script creates the project from
    scratch, registers the operator's SSH key, pushes the repository, creates
    `dev` and `prod` branches, protects `prod` (MR-only), configures the CI/CD
    pipeline, disables telemetry, and adds the `gitlab` remote to the operator's
    local repo. After this step, `git push gitlab dev` triggers a pipeline.

13. **Register runner** — runs `register-runner.sh` to register the CI/CD
    runner with GitLab.

14. **Configure sentinel** — runs `configure-sentinel-gatus.sh` to deploy
    the sentinel Gatus and placement watchdog on the NAS.

15. **Run validation** — runs `framework/scripts/validate.sh` to confirm the
    full chain of trust (network → DNS → ACME → Vault → secrets → replication)
    is operational.

The script also includes sub-steps not listed above (numbered 15.5–17 in
the script output):
- **15.5** Configure PBS backup jobs for precious-state VMs
- **15.6** Trigger an immediate backup of all precious-state VMs (`vzdump`
  for each VM with `backup: true`). This ensures a known-good backup exists
  immediately after the rebuild, before the next scheduled backup window.
  Without this, a `reset-cluster.sh` run before the first daily backup
  would leave no data for step 7.6 (auto-restore) to recover.
- **15.7** Configure Proxmox metric server entries
- **16** Run `validate.sh` (hard gate — script fails if any check fails)
- **17** Wait for the pipeline to complete (all stages green)

The script is idempotent. Steps that detect existing state (Vault already initialized
in SOPS, images already built) skip gracefully. On subsequent rebuilds the same
command runs identically.

#### 13.2.1 VM Recreation and Replication Cleanup

**Principle: VM recreation and replication cleanup are a single atomic operation.**

Every `tofu apply` that recreates a VM (due to image hash change, node_name change,
or CIDATA change) orphans ZFS zvols on replication target nodes. The old VM's
replicated data remains on the target as `vmstore/data/vm-<VMID>-disk-{0,1}` with
replication snapshots that no longer share a common ancestor with the new VM's disk.
The Proxmox replication scheduler detects "No common base snapshot" and marks the
job as failed.

This is deterministic and unavoidable — it happens every time a VM is recreated.
Multi-disk VMs (e.g., Vault with vda + vdb) produce multiple orphan zvols per
target node.

**The required response:** Run `configure-replication.sh` after every `tofu apply`
that might recreate VMs. The script:
1. Detects failed replication jobs (fail_count > 0) on all source nodes
2. Destroys orphan zvols on target nodes (all `vm-<VMID>-*` zvols)
3. Deletes the broken replication jobs
4. Recreates fresh replication jobs
5. Waits for the first replication sync to complete

This is built into `rebuild-cluster.sh` (step 12) and must also be included in
the CI/CD pipeline after every `tofu apply` stage.

### 13.3 Day 2+ - Normal Operations

**Development workflow:**
1. Create issue in GitLab issue tracker
2. Fetch latest, create feature branch from `dev` (e.g., `issue-42-fix-dns-ttl`)
3. Develop and commit changes on feature branch
4. Push feature branch to GitLab, create merge request targeting `dev`
5. MR pipeline runs: build + test (no deployment)
6. Review, approve, merge to `dev`
7. Dev deploy pipeline runs:
   - Build all VM images (unchanged roles produce same hash — no rebuild)
   - Upload images to all Proxmox nodes (skip if already present)
   - `tofu apply` targeting dev-environment modules only
   - `post-deploy.sh dev` (replication cleanup, vault recovery, backup jobs)
   - `validate.sh --regression-safe dev`
8. Operator tests in dev environment
9. If dev is good: create merge request from `dev` to `prod`
10. MR pipeline runs: build + test (no deployment)
11. Review, approve, merge to `prod`
12. Prod deploy pipeline runs:
    - Build all VM images (same images as dev — nix cache hit)
    - Upload images (already present from dev pipeline — skip)
    - `tofu apply` targeting prod-environment modules only
    - `post-deploy.sh prod`
    - `validate.sh --regression-safe prod`

**Branch model (GitLab):**

| Branch | Deploys to | Protection | Direct push |
|--------|-----------|------------|-------------|
| `dev` | Dev environment | Relaxed (during active development) | Yes |
| `prod` | Prod environment | Strict (MR-only) | No |
| feature branches | Nothing | None | Yes |

`prod` is always equal to or behind `dev`. Changes flow:
`feature branch → dev (via MR or direct push) → prod (via MR only)`.

The `main` branch (GitHub public remote) is orthogonal — it contains only
`framework/` code for the public release, synced from `dev` via
`sync-to-main.sh`. It has no CI/CD pipeline on GitLab.

**Image safety during dev→prod promotion:** Images are content-addressed
by nix output hash (e.g., `dns-a3f82c1d.img`). Uploading a new image
creates a new file alongside any existing images — old image files are not
overwritten or deleted. Running VMs reference their boot disk as a ZFS zvol
(created from the image during `tofu apply`), not the image file itself. A
dev pipeline that uploads new images does not affect prod VMs because:
(a) the old image files remain on disk, (b) the prod `tofu apply` only runs
in the prod pipeline, and (c) even if the prod pipeline runs later with the
same images, only VMs whose image hash actually changed are recreated.

**Automated certificate renewal:**
- certbot runs daily on every VM
- Checks certificate expiration
- Renews if <30 days remaining
- No manual intervention

**VM updates:**
- Update NixOS config in Git
- Build new image (`build-image.sh`)
- `tofu apply` (uploads and recreates VMs with new image)
- Data disks preserved

**Proxmox HA and VM recreation:**
VMIDs are pinned in config.yaml and passed to the Proxmox provider via the
`vm_id` parameter. When a VM is destroyed and recreated (due to an image
update or CIDATA change), it gets the same VMID. This means:
- The HA resource survives VM recreation (no double-apply needed)
- PBS backups remain associated with the correct VM
- ZFS zvol names are predictable and stable (`vm-<vmid>-disk-0`)

If the bpg/proxmox provider does not preserve the HA resource even with a
stable VMID, run `tofu apply` twice — the second apply creates the missing
HA resource. This was a known provider limitation with auto-assigned VMIDs
and may be resolved with pinned VMIDs.

**SSH host key rotation after VM recreation:**
VMs get new SSH host keys after recreation. Before SSHing to a recreated VM:
```bash
ssh-keygen -R <vm-ip>
ssh -o StrictHostKeyChecking=accept-new root@<vm-ip>
```
Or use the helper: `framework/scripts/ssh-refresh.sh <vm-ip>`

### 13.4 Disaster Recovery (Cluster Completely Down)

**Procedure:**

1. Complete the irreducible physical steps: reinstall Proxmox on each node's boot
   drive (the data NVMe and its ZFS pool may still be intact — do not wipe them
   unless the data is also lost)
2. Ensure `operator.age.key` is present on the operator workstation
3. Run:
   ```bash
   framework/scripts/rebuild-cluster.sh
   ```

The script handles everything automatically, including precious state recovery:
- Configures networking, storage, and cluster (steps 1–3)
- Runs the stopped Phase 1 OpenTofu apply for framework VMs (steps 4–7):
  current vda images, CIDATA, MACs, and vdb attachments exist in Proxmox, but
  backup-backed VMs are not started or registered in HA yet
- Installs PBS and connects to the NFS datastore on the NAS (step 7.5)
- **Automatically restores precious state from PBS before guest startup**
  (step 7.6): `rebuild-cluster.sh` derives the same plan-based manifest as
  `safe-apply.sh`, passes the pre-deploy PBS pin file to
  `restore-before-start.sh`, and restores each backup-backed VM's vdb while the
  VM is still stopped and absent from HA. If a required backup or explicit
  first-deploy approval is missing, the rebuild fails closed before any
  backup-backed VM starts.
- Runs the Phase 2 OpenTofu apply with `start_vms=true` and
  `register_ha=true` only after preboot restore succeeds. This recovers GitLab
  (pipeline history, project settings), Vault (secrets, policies), and
  application VMs (Home Assistant, databases) without manual intervention.
- Detects restored vs fresh state in subsequent steps: `init-vault.sh`
  (step 9) unseals a restored Vault using the SOPS key and token (both
  write-once, both match the restored Raft data);
  `configure-gitlab.sh` (step 12) detects the existing project and skips
  creation.
- **Handles PBS restore incompatibilities:** If the domain or secrets
  changed since the last backup, restored state may be incompatible.
  `rebuild-cluster.sh` detects and resolves these automatically:
  - Stale TLS certificates (wrong domain in `/etc/letsencrypt/`): step 9
    pre-flight compares cert directory names against expected FQDNs,
    cleans mismatches, certbot re-acquires for the correct domain
  - Vault token mismatch: `init-vault.sh` detects HTTP 403, wipes
    `/var/lib/vault/data/*` (Raft data only, preserving TLS certs),
    and reinitializes with current SOPS tokens
- **Pre-backup data protection (step 16a):** Before taking new backups,
  verifies that VMs with precious state actually have data. If PBS has
  existing backups for a VMID but the VM appears fresh/empty (restore
  failed), the rebuild stops — preventing overwrite of good backups
  with empty state. See section 14.2 for the full backup safety model.

**Ordering invariant (full-rebuild bulk path):** PBS install/configure
must precede the bulk preboot restore so the `pbs-nas` storage is
registered in Proxmox and queryable before `restore-before-start.sh`
runs; the fixture test
`tests/test_rebuild_pbs_install_before_preboot_restore.sh` enforces
this invariant.

**PBS backup data survives a complete cluster wipe** because the PBS
datastore is NFS-mounted from the NAS — the backup data physically resides
on the NAS, not on the PBS VM. When `rebuild-cluster.sh` recreates the PBS
VM, it reconnects to the same NFS mount and all previous backups are
immediately available. Destroying the PBS VM does NOT destroy the backup data.

**This automatic restore applies to any reset level where the NAS survives**
(Levels 0–2). At Level 3+ (`--nas`), the PBS datastore is destroyed and no
backups are available; backup-backed VMs may boot empty only through the
explicit first-deploy approval path for that run.

**Level 5 recovery (fresh secrets + existing PBS backups):** When
`bootstrap-sops.sh` generates fresh secrets but the PBS datastore still
has backups from a previous deployment, the restored state is incompatible
(old Vault tokens, old-domain certificates). `rebuild-cluster.sh` handles
this gracefully through the mechanisms above — cert domain mismatch
detection, Vault token auto-recovery, and the pre-backup data protection
gate. To avoid incompatible restores entirely, point PBS at an empty
datastore for the Level 5 test (see the Level 5 spore test plan).

**Recovery time (measured):** ~35 minutes for `rebuild-cluster.sh` on bare
Proxmox nodes (including automatic PBS restore, NIC discovery with reboots,
and pipeline verification). Total RTO including sequential Proxmox
installation is ~83 minutes (dominated by ~45 minutes of manual Proxmox
installs on 3 nodes). See section 13.9 for detailed timing breakdown.

**The NAS is the durability anchor.** It holds three things that survive a
complete cluster wipe:
1. **OpenTofu state** (PostgreSQL) — so the rebuild script knows what existed
2. **PBS backup data** (NFS datastore) — so precious state is automatically
   restored
3. **Sentinel monitoring** (Docker) — so the operator was alerted when the
   cluster went down

It is intentionally off-cluster for exactly this reason.

If the NAS is also lost, restore the NAS first (it is a Synology appliance with its
own RAID and backup strategy), then run the rebuild script.

#### 13.4.1 Single-Node Recovery (One Node Dead, Cluster Degraded)

The most likely real disaster: one node fails (hardware, drive, firmware),
HA migrates its VMs to the two surviving nodes, and the cluster continues
running in a degraded state (quorum maintained with 2 of 3 nodes, but no
N+1 headroom). The operator replaces the hardware or reinstalls Proxmox on
the same hardware, then restores the node to full cluster participation.

This is fundamentally different from full-cluster rebuild
(`rebuild-cluster.sh`). The cluster is alive — there are running VMs,
active replication, PBS backing up, a working pipeline. The recovery is
asymmetric: one node needs to be brought back, the other two are
untouched.

**What works during degraded operation:**
- All VMs running (HA migrated to survivors)
- PBS backups continuing (PBS VM was migrated)
- Pipeline running (GitLab and runner were migrated)
- Replication degraded (jobs targeting the dead node fail, but data is
  safe on the surviving replica)
- Sentinel alerting the operator that a node is down

**What needs restoration:**
1. Proxmox reinstalled on the replacement node
2. Node joined to the existing cluster (not a new cluster)
3. NIC names pinned (fresh Proxmox has default names)
4. ZFS data pool created on the data NVMe
5. VMs migrated back to their intended placement (from config.yaml)
6. Replication jobs recreated for the replacement node

**Procedure (designed, implementation deferred):**

```bash
# Step 1: Operator reinstalls Proxmox on the replacement node
#         (same password, same management IP, same hostname)

# Step 2: Join the replacement node to the existing cluster
framework/scripts/join-node.sh <node-name>
```

`join-node.sh` would:
1. Bootstrap SSH key auth to the fresh node (using SOPS password)
2. Run NIC auto-discovery and pin interface names (same as
   `configure-node-network.sh` but single-node)
3. Join the existing cluster via `pvecm add` (not `pvecm create`)
4. Create the ZFS data pool on the data NVMe
5. Upload VM images to the new node (so HA can migrate VMs there)

```bash
# Step 3: Rebalance VMs back to intended placement
framework/scripts/rebalance-cluster.sh
```

`rebalance-cluster.sh` (already conceptually designed) would:
1. Compare current VM placement against config.yaml's intended node
2. Migrate VMs back to their intended nodes (including the replacement)
3. Recreate replication jobs for the replacement node
4. Wait for initial replication sync

**Why this is NOT a `reset-cluster.sh` level:** The reset tool destroys
things symmetrically (all nodes). Single-node recovery is inherently
asymmetric — one node is fresh, two are running. `rebuild-cluster.sh`
assumes a blank slate; `join-node.sh` assumes an existing cluster.
The tools, code paths, and failure modes are different.

**Why this can't use `rebuild-cluster.sh --node`:**
- Step 3 (`form-cluster.sh`): would try `pvecm create`, conflicting with
  the existing cluster. The replacement node needs `pvecm add` (join).
- Step 7 (`tofu apply`): would try to deploy ALL 17 VMs, but 14 already
  exist on the surviving nodes. Tofu would error on conflicts.
- Steps 8-15: configured for the full cluster; re-running them against a
  partially-recovered cluster could disrupt running services.

**Scorched-earth test level:** Level 1.5 (between Level 1 "storage
rebuild" and Level 2 "full cluster rebuild"). See the level mapping table
in section 13.5.

### 13.5 Cluster Reset (Multi-Level)

`framework/scripts/reset-cluster.sh` is an intentional, operator-initiated
teardown. It is distinct from disaster recovery (which rebuilds after an
unplanned failure). Use cases: reclaiming disk space, VMID renumbering,
testing rebuild paths, recovering from corrupted state, decommissioning
hardware, or security-sensitive disposal.

**Reset levels operate on two tracks that converge:**

```
Cluster track:    --vms → --storage → --cluster → --nas
Workstation track:                     --builds → --secrets
Combined:                                         --distclean
Terminal:                                          --forensic
```

**Cluster track levels (cumulative — each includes the previous):**

| Level | Flag | What it destroys | What survives |
|-------|------|-----------------|---------------|
| VMs | `--vms` | All VMs, HA resources, replication jobs, CIDATA snippets, OpenTofu state | ZFS pools, Proxmox cluster, NAS, workstation |
| Storage | `--storage` | Above + ZFS data pools, partition tables on data NVMes | Proxmox boot filesystem, cluster membership, NAS, workstation |
| Cluster | `--cluster` | Above + boot drives on all nodes. Requires manual Proxmox reinstall. | NAS, workstation (secrets.yaml, operator.age.key, config.yaml) |
| NAS | `--nas` | Above + PostgreSQL state, PBS backup datastore, sentinel, watchdog | Workstation, config.yaml, operator.age.key, git repo |

**Workstation track levels (cumulative — each includes the previous):**

| Level | Flag | What it destroys | What survives |
|-------|------|-----------------|---------------|
| Builds | `--builds` | `build/` directory, `image-versions.auto.tfvars`, Nix build results, any cached `.img` files | Everything else — source code, config, secrets, cluster |
| Secrets | `--secrets` | Above + `operator.age.key` + `site/sops/secrets.yaml`. The operator can no longer decrypt secrets (age key gone) and the secrets file itself is gone. | Source code, config.yaml (no secrets), git repo, cluster (still running) |

**Combined and terminal levels:**

| Level | Flag | What it destroys | What survives |
|-------|------|-----------------|---------------|
| Distclean | `--distclean` | Cluster `--nas` + workstation `--secrets` + `--builds`. Returns the workspace to freshly-cloned state. | Git repo (code + history), `config.yaml` (operator must re-run `bootstrap-sops.sh` to regenerate age key and secrets) |
| Forensic | `--forensic` | Cryptographic erasure of all cluster drives (`blkdiscard --secure` or `shred`), NAS cluster data (PostgreSQL, PBS datastore), workstation secrets. Best-effort unrecoverable deletion. | Git repo (code + history). Hardware is safe to hand off to an untrusted party. |

Without `--confirm`, the script prints what would be destroyed and exits.

**Boot disk safety (CRITICAL):** The `--storage` level wipes data NVMe
partition tables. The script must positively identify the boot device on
each node before any destructive operation, and the dry-run output must
show which device is PROTECTED (boot) and which will be WIPED (data) on
each node. The operator verifies this before running with `--confirm`.
See implementation notes for the triple safety net: (1) positive
identification via `findmnt`/`lvs`/`zpool` trace, (2) data devices by
exclusion, (3) final equality check before each wipe.

**Mapping to scorched-earth test levels:**

| Level | Name | Reset command | What's gone | What rebuild tests |
|-------|------|--------------|-------------|-------------------|
| 0 | Quick redeploy | `--vms` | VMs, HA, replication, PBS config, tofu state | Deploy into existing pools. Automatic PBS restore of precious state (step 7.6). |
| 1 | Storage rebuild | `--storage` | Above + ZFS pools, data NVMe partition tables | Pool creation from blank NVMes. Automatic PBS restore of precious state. |
| 1.5 | Single-node recovery | `--cluster --node <n>` | One node's boot + data drives | `join-node.sh` + `rebalance-cluster.sh`. Cluster stays running. Tests asymmetric recovery. |
| 2 | Disaster recovery | `--cluster` | Above + boot drives. Requires Proxmox reinstall. | Full bootstrap: NIC discovery, cluster formation. Secrets survive on workstation. Automatic PBS restore (NAS alive). |
| 3 | Total infrastructure loss | `--nas` | Above + NAS PostgreSQL, PBS datastore, sentinel | Rebuild with blank NAS. No PBS backups; backup-backed VMIDs require explicit first-deploy approval before empty start. |
| 4 | Secrets loss | `--nas` + `--secrets` | Above + operator.age.key + secrets.yaml | New age keypair + fresh secrets via `bootstrap-sops.sh`. Tests the "lost my laptop" scenario. |
| 5 | From the spore | `--distclean` | Above + build cache, Nix results | Cold image builds. Proves a fresh git clone + config.yaml is sufficient. |
| — | Decommissioning | `--forensic` | Cryptographic erasure of all drives | N/A — hardware is being disposed of, not rebuilt |

**Post-reset rebuild sequence by level:**

| Level | Steps to rebuild |
|-------|-----------------|
| 0 | `rebuild-cluster.sh` (skips steps 1–3: networking, storage, cluster already done) |
| 1 | `rebuild-cluster.sh` (skips steps 1, 3: networking and cluster done; step 2 recreates pools) |
| 1.5 | Reinstall Proxmox on one node → `join-node.sh <node>` (joins existing cluster, creates pool) → `rebalance-cluster.sh` (migrates VMs back) |
| 2 | Reinstall Proxmox from USB → `rebuild-cluster.sh` (secrets.yaml on workstation, full sequence including NIC discovery and cluster formation) |
| 3 | Restore NAS services → reinstall Proxmox → `rebuild-cluster.sh` (secrets.yaml on workstation, full sequence, no PBS backups) |
| 4 | `bootstrap-sops.sh` (new age key, fresh secrets) → restore NAS → reinstall Proxmox → `rebuild-cluster.sh` |
| 5 | `bootstrap-sops.sh` → restore NAS → reinstall Proxmox → `rebuild-cluster.sh` (cold builds) |

**The secrets identity boundary (why Level 5 finds bugs Levels 0–2 cannot):**

Levels 0–2 preserve `secrets.yaml` and `operator.age.key` on the
workstation. The SOPS SSH keypair, Vault tokens, PBS password, and all
other secrets are unchanged across the destroy/rebuild cycle. Every
script that SSHes to a managed host, authenticates to Vault, or
connects to PBS works because the credentials in SOPS are the same
ones that were in use before the reset.

Level 5 (and Levels 3–4) runs `bootstrap-sops.sh`, which generates
**fresh** credentials: a new age key, new SSH keypair, new PowerDNS
API key, new Vault tokens. This breaks any assumption that:

- The SOPS SSH key matches the operator's `~/.ssh/id_rsa` (it was the
  same key during development; `bootstrap-sops.sh` generates a fresh
  ed25519 key)
- A particular SOPS field exists (e.g., `pbs_root_password` was
  manually added during development, not generated by `bootstrap-sops.sh`)
- PBS backup data is compatible with current secrets (Vault Raft data
  and TLS certificates in restored vdb reference the old credentials)
- Application-level SSH keys (e.g., GitLab API registered keys) match
  the operator's workstation key

These bugs are invisible on Levels 0–2 because the credentials are
continuous — the same values survive from the original bootstrap. Level 5
is the first test where a genuinely new operator (or a returning operator
who lost their secrets) encounters the bootstrap chain with no credential
continuity. Every implicit dependency between "what's in SOPS" and
"what's on the workstation" or "what's in a PBS backup" is exposed.

Bugs found during the first Level 5 test (2026-03-21):
- `install-pbs.sh` did not write `pbs_root_password` to SOPS
- `configure-pbs.sh` installed only the SOPS key, not the operator key
- NixOS VM CIDATA had only the SOPS key, not the operator key
- Proxmox nodes had only the operator key, not the SOPS key (CI runner
  access required a workaround in step 14)
- `configure-gitlab.sh` registered only the SOPS key in GitLab's SSH
  key API, not the operator key
- PBS-restored Vault vdb had stale Raft data (token mismatch)
- PBS-restored TLS certs were for the wrong domain
- `init-vault.sh` error message suggested `rm -rf /var/lib/vault/*`
  which also wiped TLS certs
- `influxdb_admin_token` and `grafana_influxdb_token` not generated
  by `bootstrap-sops.sh` — on-demand pre-deploy secrets need a
  pre-apply generation step, not a bootstrap-time step

**What each cluster track level does:**

**`--vms`** — The lightest cluster reset. Destroys all VMs via the Proxmox
API (not `tofu destroy`, which may fail if state is corrupted). Removes HA
resources, replication jobs, and CIDATA snippet files. Also removes Proxmox
cluster-level config that references destroyed VMs: the PBS storage entry
(`pbs-nas` — stale fingerprint and API token after rebuild), all PBS backup
jobs (will be recreated by `configure-backups.sh`), and metric server entries.
Drops OpenTofu state from the NAS PostgreSQL database. After this,
`rebuild-cluster.sh` can redeploy all VMs from scratch into existing ZFS
pools. PBS backups on the NAS are preserved — `rebuild-cluster.sh` step 7.6
automatically restores precious state from these backups before the restored
framework VMs start (GitLab history, Vault secrets, application data).

**`--storage`** — Includes `--vms`, then destroys ZFS data pools on all
nodes and wipes partition tables on data NVMes (`sgdisk --zap-all`,
`wipefs -a`). This forces `rebuild-cluster.sh` to recreate ZFS pools, which
tests the `configure-node-storage.sh` path.

**`--cluster`** — Includes `--storage`, then destroys the boot drives on all
nodes. After this, the nodes cannot boot and require a manual Proxmox
reinstall from USB. `secrets.yaml` and `operator.age.key` are NOT touched
— they survive on the workstation, and the recovered cluster uses them
directly (the SOPS values match PBS backups because of the write-once
invariant). Secrets destruction belongs to the workstation track
(`--secrets`), not the cluster track.

Boot drive destruction must be thorough enough that the UEFI firmware finds
nothing bootable and falls through to the boot device selection menu. A
partial wipe — destroying the root filesystem but leaving the EFI System
Partition (ESP) intact — is dangerous: the firmware finds the boot loader,
loads the kernel, but the root filesystem is gone. The result is a hung
system with no keyboard input and no networking. With fastboot enabled in
BIOS, the firmware skips the boot menu entirely and boots the broken EFI
entry immediately, making recovery extremely time-consuming (requires
physical BIOS menu intervention or CMOS reset).

The correct destruction sequence per node:
1. Remove UEFI boot entries: `efibootmgr` to delete all boot entries
   referencing the boot NVMe
2. Zero each partition's header with `dd` (first 10MB): `wipefs -a` cannot
   clear LVM signatures on active/mounted partitions (the boot drive is in
   use). Raw `dd` writes bypass the filesystem and destroy LVM PV headers,
   filesystem superblocks, and other magic bytes. Without this, the Proxmox
   installer fails with "unable to initialize physical volume."
3. Wipe the entire boot NVMe: `sgdisk --zap-all` on the boot device
   (destroys the GPT partition table)
4. After wipe, the firmware should find no bootable device on the NVMe and
   present the boot device menu on next power cycle

**Data NVMe wipe (at `--storage` level) also requires thorough cleanup:**
1. `zpool labelclear -f` on each partition AND the whole disk: ZFS stores
   labels at both the beginning and end of each vdev. `sgdisk --zap-all`
   only removes the GPT header (first and last 33 sectors). ZFS backup
   labels at old partition offsets can survive and cause `zpool import` to
   find stale pools on the fresh Proxmox install.
2. `dd if=/dev/zero` on the first and last few MB of the disk: catches any
   remaining metadata signatures
3. `sgdisk --zap-all` + `wipefs -a`: removes partition table and filesystem
   signatures

**Defense in depth between reset and rebuild:** Every cleanup in
`reset-cluster.sh` should have a corresponding resilience in
`rebuild-cluster.sh`. If the reset misses something (stale ZFS label,
LVM metadata, wrong hostid), the rebuild handles it gracefully:
- `zpool destroy` + `labelclear` (reset) ↔ `zpool import -f` (rebuild,
  handles different hostid after Proxmox reinstall)
- Boot drive `dd` zeroing (reset) ↔ Proxmox installer handles clean disk
- Empty cert cleanup (reset) ↔ Step 9 pre-flight + mid-flight recovery
  (rebuild, cleans empty cert files from ACME outages)

**`--nas`** — Includes `--cluster`, then connects to the NAS and drops the
OpenTofu PostgreSQL database, clears the PBS backup datastore, and stops the
sentinel Gatus container and placement watchdog. After this, the NAS is a
blank slate — `rebuild-cluster.sh` will recreate the PostgreSQL schema,
configure PBS with a fresh datastore, and deploy the sentinel.

**What each workstation track level does:**

**`--builds`** — Removes reproducible build artifacts: `build/` directory,
`image-versions.auto.tfvars`, Nix result symlinks. These can all be
regenerated by running `build-all-images.sh`. This is a disk space recovery
operation — no state is lost that can't be rebuilt.

**`--secrets`** — Includes `--builds`, then erases both `operator.age.key`
and `site/sops/secrets.yaml` with `shred`. Without the age key, the
operator cannot decrypt secrets.yaml — and without secrets.yaml, there are
no secrets to decrypt. The git history still has encrypted copies of
secrets.yaml, but they are unrecoverable without the age key. The cluster
continues running (it doesn't need the workstation key at runtime), but
the operator loses the ability to manage secrets until a new key is
bootstrapped via `bootstrap-sops.sh` (which generates a new age key,
prompts for passwords, and produces a fresh secrets.yaml). This is also
the correct path when transferring operator responsibility (the new
operator runs `bootstrap-sops.sh` with their own age key).

**What the combined and terminal levels do:**

**`--distclean`** — Runs both `--nas` (full cluster track) and `--secrets`
(full workstation track). The result is a workspace that looks like a fresh
`git clone` plus a `site/config.yaml` that the operator already filled in.
To rebuild from distclean: `bootstrap-sops.sh` → reinstall Proxmox →
`rebuild-cluster.sh`.

**`--forensic`** — For hardware disposal or security-sensitive
decommissioning. Uses `blkdiscard --secure` on all NVMe devices (both boot
and data drives) on all nodes — this issues the NVMe Secure Erase command,
which is handled by the drive firmware and is the most thorough erasure
available for NVMe. Falls back to `shred` if `blkdiscard --secure` is not
supported. On the NAS, drops and overwrites PostgreSQL data, removes PBS
backup data, and overwrites with zeros where possible. On the workstation,
shreds `operator.age.key` and `secrets.yaml`. Best-effort: NAS filesystem-
level secure erasure depends on the Synology's RAID and filesystem
capabilities, which may not support per-file secure deletion. The operator
should consult Synology documentation for full-disk erasure if the NAS
itself is being decommissioned.

After `--forensic`, the cluster hardware is safe to hand off to an
untrusted party. The nodes will need Proxmox reinstall, the NAS will need
its cluster services reconfigured, and the operator will need
`bootstrap-sops.sh` to regenerate keys.

**What is always preserved (across all levels except `--forensic`):**

| Item | Preserved? | Reason |
|------|-----------|--------|
| `site/config.yaml` | ✓ Always | Operator-authored; defines the entire deployment |
| Git repo (code + history) | ✓ Always | The framework source; never destroyed by reset |

**Why `secrets.yaml` survives cluster track levels (`--vms` through `--cluster`):**
The Vault unseal keys and root token in `secrets.yaml` are write-once — they
were written during `vault operator init` and never overwritten. PBS backs up
Vault's vdb, which contains Raft data from the same init event. After a
cluster rebuild with PBS restore, the SOPS values match the restored Raft
data because neither side was modified. If `secrets.yaml` were erased at
`--cluster`, the operator would have to regenerate fresh secrets that don't
match the PBS backups — breaking the write-once invariant and making
disaster recovery lossy. See section 11.0 (bidirectional state coupling).

`secrets.yaml` is only erased by the workstation track (`--secrets`), along
with `operator.age.key`. At that level, the git history copies of
`secrets.yaml` also become unrecoverable (can't decrypt without the age key),
and `bootstrap-sops.sh` truly regenerates fresh secrets.

**Implementation:** `framework/scripts/reset-cluster.sh --<level> [--confirm]`.
Without `--confirm`, prints a detailed summary of what will be erased and
exits. With `--confirm`, executes. Exactly one level flag is required.

**Implementation status:**
- `--vms`, `--storage`, `--cluster`, `--nas`: Implement now
- `--builds`, `--secrets`: Implement now (simple)
- `--distclean`: Implement now (composes `--nas` + `--secrets`)
- `--forensic`: Design documented above; implementation deferred until
  hardware decommissioning is needed. Requires testing on actual hardware
  to verify `blkdiscard --secure` behavior and NAS erasure capabilities.

### 13.6 Bootstrap Chain Degradation

The chain of trust (CIDATA → DNS → ACME → Vault → secrets) is long. If any link is degraded, the impact depends on which link:

| Degraded link | Impact | Recovery |
|---------------|--------|----------|
| CIDATA missing | VM has no network config, no IP, no DNS. Unreachable. | Fix OpenTofu config, redeploy VM. Proxmox console is the only debug path. |
| DNS down (both servers) | Running VMs with cached DNS continue briefly (TTL-dependent). New VMs can't resolve `vault` or `acme`. Cert issuance fails. | Proxmox HA restarts DNS VMs. Rebuild if needed (stateless). |
| DNS down (one server) | No impact — CIDATA delivers both DNS server IPs, clients failover automatically. | Rebuild failed DNS VM. |
| ACME rate-limited (LE) | VMs with valid certs are unaffected. New VMs or VMs needing renewal can't get certs, can't auth to Vault, can't get secrets. | Wait for rate limit window to pass (resets weekly). Existing certs valid for 90 days. |
| ACME server down (step-ca in dev) | Dev VMs can't get certs. Prod unaffected. | Rebuild acme-dev (stateless). |
| Vault down | VMs with cached secrets (via vault-agent) are unaffected. New VMs can't get secrets. | Proxmox HA restarts Vault (~15s for VM crash, <2 min for node failure). |
| Vault sealed | Same as Vault down. Auto-unseal reads key from vdb on restart. | If auto-unseal fails: manual `vault operator unseal` with key from vdb or SOPS backup. |

**Key insight:** Most degradation scenarios only affect VMs that are actively bootstrapping or renewing. Running VMs with cached DNS, valid certificates, and cached secrets tolerate significant infrastructure outages. This is why the architecture emphasizes caching at every layer.

**Proxmox API behavior during cluster transitions:** When a node departs the
cluster (failure or graceful shutdown), the `pvesh get /cluster/resources` API
on surviving nodes may return empty results for several minutes while processing
the corosync membership change, HA fencing, and resource relocation. Different
surviving nodes may return results at different times. Any automation that queries
the Proxmox API during a failover (placement watchdog, validate.sh, monitoring
scripts) must treat empty API responses as "unable to determine state" rather
than "no VMs exist," and should retry on alternate nodes if the first returns
empty data.

### 13.7 Break-Glass Access

When DNS or other infrastructure is down, the normal operational path (SSH via hostname, web UIs via FQDN) doesn't work. Break-glass access uses direct IPs and out-of-band paths.

**Operator's Mac should maintain:**
- `/etc/hosts` entries for critical infrastructure (all Proxmox nodes, DNS servers, Vault, PBS) with direct IPs. These are static assignments from config.yaml and don't change.
- SSH config with direct IPs as fallback (`Host proxmox1-direct` → `10.0.10.x`)
- Proxmox web UI bookmarked by IP (`https://10.0.10.1:8006`)

**Debug path when DNS is completely down:**
1. Access Proxmox web UI via direct IP
2. Open VM console (Proxmox built-in noVNC/SPICE — no DNS needed)
3. Diagnose DNS VMs from console
4. If DNS VMs are gone: OpenTofu recreate from Mac (using direct IPs in provider config or `/etc/hosts`)

**Debug path when the entire cluster is down:**
1. SSH to NAS (direct IP, independent of cluster)
2. Check PBS (is backup data intact?)
3. Check OpenTofu state in PostgreSQL (is state intact?)
4. Follow disaster recovery procedure (section 13.4)

### 13.8 Rollback Model

**General principle:** Rollback is `git revert` + re-deploy. Because all configuration flows from Git through CI/CD to the running system, reverting a Git commit and re-running the pipeline restores the previous state.

**Per-component rollback safety:**

| Component | Rollback mechanism | Safe? | Notes |
|-----------|-------------------|-------|-------|
| NixOS VM images | Revert Nix config, rebuild image, `tofu apply` | Yes | Images are immutable. Old image can be kept in Proxmox storage for faster rollback. |
| DNS zones | Revert config.yaml, re-deploy | Yes | Zone data derived from config.yaml and delivered via CIDATA. Previous state restored on next deploy. |
| Vault policies | Revert policy HCL, re-sync | Yes | Policies are declarative and idempotent. |
| OpenTofu resources | `git revert` + `tofu apply` | Mostly | Safe for stateless resources (VMs, disks). Caution with stateful resources — destroying a VM with precious state requires PBS restore. The `tofu plan` output should be reviewed before applying a revert. |
| SOPS secrets | Revert encrypted file, re-deploy | Yes | Old secret values restored. May require restarting services that cached the old values. |
| Vault runtime secrets | N/A | N/A | Dynamic secrets are generated by Vault, not stored in Git. They're not reverted — they're rotated. |

**What rollback does NOT cover:**
- Data corruption on vdb (e.g., a bad migration script that corrupted a database). This requires PBS restore, not Git revert.
- Proxmox host-level changes (kernel updates, ZFS config). These are manual operations with their own rollback procedures.

### 13.9 RPO/RTO Targets

| Service class | RPO (max data loss) | RTO (max downtime) | Mechanism |
|---------------|--------------------|--------------------|-----------|
| DNS | Zero (stateless) | ~0s (single failure), <2 min (both down) | Redundant (dns1/dns2) with anti-affinity. Single failure: instant failover via CIDATA-delivered dual DNS server IPs. Both down: Proxmox HA restart. |
| Vault | 1 minute | ~15s (VM crash), <2 min (node failure) | ZFS replication (1-min interval). VM crash: HA restarts on same node (~10s) + auto-unseal (~5s). Node failure: HA migrates to survivor + auto-unseal. |
| Home Assistant | 1 minute | <2 minutes | ZFS replication (1-min interval). Proxmox HA restart (highest priority). |
| Databases (InfluxDB, etc.) | 1 minute (ZFS), 24 hours (PBS) | <2 min (ZFS), <30 min (PBS restore) | ZFS replication for node failure. PBS for data corruption requiring point-in-time restore. |
| CI/CD | Zero (stateless) | <30 minutes | Rebuild from Git. Mac fallback available immediately. No precious state. |
| Gatus (monitoring) | Zero (stateless) | <2 minutes | Rebuild from Git. Sentinel on NAS covers the gap. |

**Measured values (Step 10B destructive tests, 2026-03-12):**

| Scenario | Measured | Notes |
|----------|----------|-------|
| Vault VM crash → healthy (same node) | ~15s | 10s HA restart + 5s boot/unseal |
| Node failure → all VMs running on survivors | <120s | 7 VMs migrated from pve02 to pve01/pve03 |
| Node power-on → rejoins cluster | ~15s | Corosync membership restored |
| Replication recovery after node rejoin | Immediate | 0 failed jobs out of 34 |
| Rebalance (5 VMs, sequential migration) | ~5 min | One VM at a time with verification |
| Full recovery cycle (power-off → 51/51 PASS) | ~20 min | Includes node rejoin + rebalance + validation |

The estimated ~45–90 second HA failover window in this document refers to
the total time from node failure detection to VMs running on survivors. The
actual measured time was under 120 seconds for a 7-VM migration. Individual
VM crash recovery (same-node restart) is much faster (~10–15 seconds).

**RPO note:** The 1-minute RPO for ZFS-replicated services applies to unplanned node failure (up to 1 minute of writes lost). For data corruption scenarios, RPO is bounded by PBS backup frequency (daily), meaning up to 24 hours of data loss if the corruption isn't caught before the next backup overwrites the good one. PBS retention policies (keeping multiple daily snapshots) mitigate this — you can restore from any retained snapshot, not just the most recent.

**Backup overwrite protection:** `rebuild-cluster.sh` prevents the most
dangerous RPO failure: overwriting a good backup with empty state. During
a rebuild, the Sprint 031 preboot restore path prevents backup-backed VMs
from starting before restore succeeds or an explicit first-deploy empty start
is approved. The pre-backup validation gate (step 16a) remains
defense-in-depth: if a VM appears fresh while PBS has existing backups, the
rebuild stops before any backup can replace the recoverable backup with empty
state. See section 14.2 for the full three-gate backup safety model.

**Measured scorched-earth rebuild times (2026-03-16):**

| Level | Scenario | Reset time | Rebuild time | Total RTO |
|-------|----------|-----------|-------------|-----------|
| 0 | VMs gone, pools survive | ~5s | ~24 min | ~24 min |
| 1 | Pools gone, nodes survive | ~30s | ~23 min | ~23 min |
| 2 | Cluster dead, NAS alive | ~2 min + ~45 min Proxmox install | ~35 min | ~83 min |

Level 2 rebuild is ~10 minutes longer than Levels 0–1 because NIC
auto-discovery on fresh Proxmox installs includes node reboots for
interface renaming (~217s vs ~43s) and image builds are slower when the
nix store needs repopulation (~588s vs ~78s). The dominant contributor to
total Level 2 RTO is the manual sequential Proxmox installation (~15 min
per node × 3 nodes). Parallel installation (three USB sticks) or PXE boot
with answer files would reduce this to ~40 minutes total.

---

## 14. Validation and Testing Strategy

### 14.1 Design Goals → Tests

| Goal | Assertion | Test Method |
|------|-----------|-------------|
| Convergence | System reaches correct state from diverse starting points | DR test suite across degraded-state scenarios (DRT-001 through DRT-007+) |
| Single-pass convergence | Rebuild succeeds without manual intervention | Longitudinal tracking of single-pass success across DR test runs |
| Rebuild failures diagnostic | Every failure produces a structural fix + new test case | DR registry invalidation ratchet; issue backlog |
| Configuration is software | Git commit fully determines system state | Scorched-earth rebuild (DRT-002) from fresh clone |
| Rebuildability | Destroy/recreate yields identical behavior | Destructive VM rebuild test (DRT-001) |
| Minimal hidden state | No undocumented dependencies | Rebuild failure = hidden dependency found |
| DFMEA test surface | Failure modes systematically enumerated | DR test registry growth over time |
| Ownership boundaries | OpenTofu never mutates inside VMs | Static analysis + runtime checks |
| Dev/prod separation | Dev cannot read prod secrets or access prod services | Secrets decryption matrix, network isolation test |
| Unknowable state fails | Safety checks fail-closed on uncertainty | Forced-failure injection tests |
| Early env binding | CIDATA determines env before bootstrap | Environment discovery test |
| Stateless TLS | Certs re-issue on rebuild | Certificate regeneration test |
| HA resilience | Single node failure does not cause service outage for redundant services | Node failure simulation (DRT-005), anti-affinity verification |
| Backup integrity | Backups are restorable and data is consistent | Monthly restore drills in dev, quarterly prod spot-checks (DRT-003, DRT-007) |

### 14.2 Core Test Classes

**Static CI gates (every PR):**
- `tofu fmt`, `tofu validate`, `tofu plan`
- `nix flake check` (NixOS configurations)
- SOPS policy enforcement (secrets encrypted correctly)
- Lint checks (shell scripts, YAML, etc.)

**Bootstrap validation (post-OpenTofu):**
- DNS servers responding to queries
- DNS publicly queryable from internet (prod only)
- Certificates valid and not expiring soon
- Vault accessible and unsealed
- DNS-01 challenge capability (test TXT record create/verify/delete on both DNS servers)
- End-to-end certificate issuance test
- Anti-affinity placement verified (redundant pairs on different nodes)

**Integration tests (in dev):**
- Service health checks (all services respond)
- Inter-service communication (DNS resolution works)
- Secrets injection (services can read from Vault)
- End-to-end ACME certificate issuance via step-ca (certbot → PowerDNS API → DNS-01 challenge → step-ca validation → certificate issued)
- Vault TLS certificate authentication (dev VM authenticates to dev Vault using step-ca-issued cert)
- Complete certificate → Vault → secrets chain, end to end

**HA and failover tests (in dev):**
- DNS failover: stop dev dns1, verify dev dns2 serves all queries, verify dev VMs continue to resolve names without interruption
- Vault failover: destroy dev Vault VM, verify Proxmox HA restarts it on another node, verify dev VMs can authenticate after restart
- VM rebuild test: destroy a dev VM (vda destroyed, vdb preserved), OpenTofu recreates it, verify data preserved and service resumes
- Node failure simulation: power off or fence a node hosting dev VMs, verify Proxmox HA restarts affected VMs on surviving nodes (measured: <120 seconds for 7 VMs), verify services recover. Note: to simulate a crash for HA testing, kill the QEMU process directly (`kill -9 $(cat /run/qemu-server/<vmid>.pid)`); `qm stop` is an administrative action that HA respects as intentional and will not restart.
- Anti-affinity validation: after failover, verify that redundant pairs have not collapsed onto the same node (if they have, this is acceptable temporarily but should be corrected)

**Backup and restore tests (in dev):**
- PBS backup verification: confirm daily backups of dev VMs with precious state (Category 3) are completing successfully
- Single VM restore: use `restore-from-pbs.sh --target <vmid> --backup-id <volid>` against a dev VM and verify the application recovers with restored data and no corruption
- Full rebuild from backup: force a dev VM replacement through the normal deploy wrapper, verify `restore-before-start.sh` restores the new vdb before Phase 2 starts the VM, and confirm the application recovers
- Restore timing: measure actual RTO (recovery time) for each restore scenario, compare against expectations
- Restore freshness: verify RPO (recovery point) — the restored data should be no older than the backup frequency (daily for PBS, 1 minute for ZFS replication)
- A backup you've never restored is a theory, not a plan. These tests convert theory into verified capability.

**Backup safety invariant (enforced by `rebuild-cluster.sh`):**

A cluster that reports success must have verified, recoverable backups
of all precious-state VMs. `rebuild-cluster.sh` enforces this through
a three-gate sequence:

| Gate | Step | What it checks | What it prevents |
|------|------|---------------|-----------------|
| **Pre-backup validation** | 16a | VMs are healthy. If PBS has existing backups for a VMID but the VM appears fresh/empty, STOP. | Overwriting a good backup with empty state. If vdb restore failed (stale certs, token mismatch, NFS issue), the VM is running with no data. A backup taken now would destroy the recoverable backup on PBS. |
| **Backup execution** | 18 | All precious-state VMs backed up. Hard failure if any vzdump fails, with actual error output. | Silent backup failures. A cluster that passes validation but has no working backups is not production-ready. |
| **Post-backup validation** | 16b | Backups exist on PBS with real application state (not just non-zero size). Application-specific content checks or minimum size thresholds. Full health re-check. | Useless backups. A backup of an empty vdb has non-zero size (filesystem metadata) but is worthless for recovery. |

The data protection principle: **a backup is only as valuable as what it
contains.** The pre-backup gate (16a) prevents the most dangerous failure
mode — replacing a good backup with an empty one. This scenario occurs
when restored state is incompatible with the current config (domain change,
secret regeneration) or a destructive path bypasses the preboot restore
wrapper. Sprint 031 prevents the normal deploy path from starting such a VM
before restore, but the semantic gate remains as defense-in-depth before any
new backup is allowed.

On a genuinely fresh cluster with no previous backups, the preboot restore
step requires explicit first-deploy approval before backup-backed VMs can boot
empty. After that approved start, the pre-backup gate passes because there is
nothing to protect. On a cluster with existing backups, the gate verifies that
restored state is actually present before allowing new backups.

Application-specific content checks in 16a and 16b:

| VM | "Has real state" signal | "Empty/fresh" signal |
|----|------------------------|---------------------|
| GitLab | Project exists via API | No projects |
| Vault | Initialized and tokens match SOPS | Uninitialized or token mismatch |
| InfluxDB | Organization exists via API | No organizations |
| Roon | `/var/lib/roon-server/RoonServer/` has content | Empty directory |

These checks are used by `rebuild-cluster.sh`'s three-gate model —
they are semantic, application-level checks against running services.

**Pipeline restore detection (`restore-before-start.sh`):**

The pipeline determines restore membership from the default OpenTofu plan,
before any stopped apply runs. `safe-apply.sh` builds a preboot restore
manifest for backup-backed VM creates/replaces and for interrupted resumes
where state shows `started=false` and the default plan wants `started=true`.
The membership plan always uses default `start_vms=true` and
`register_ha=true`; this is required so a rerun after an interruption still
detects stopped VMs that need restore.

`safe-apply.sh` then runs Phase 1 with `start_vms=false` and
`register_ha=false`, calls `restore-before-start.sh`, and only then runs
Phase 2 with starts and HA registration enabled. The restore script uses
the pinned PBS backup when available. If no pin exists, CI fails when a
backup exists unless the run explicitly allows unpinned restore; if no
backup exists, first-deploy empty vdb requires explicit per-run approval.

This replaces uptime detection. A freshly formatted vdb is no longer allowed
to reach application service startup while waiting for a later restore hook.

**Prod verification drills:**

Dev tests validate configuration correctness. Prod drills verify that the prod environment works at least as well as dev — that no environment-specific issue (networking, firewall, DNS reachability, Let's Encrypt vs. step-ca, resource contention) has been missed.

- DNS failover (prod): stop prod dns1, verify prod dns2 serves all queries, verify prod VMs and external clients continue to resolve names. Restore dns1 and verify it resumes serving.
- Vault restart (prod): gracefully restart prod Vault VM, verify all prod VMs re-authenticate after Vault comes back, verify no leaked or expired tokens cause service failures.
- Node evacuation (prod): planned migration of all VMs off one node (simulates rolling Proxmox update), verify all services continue operating from other nodes within expected downtime (10–20 seconds per VM).
- Certificate renewal (prod): verify that certbot on prod VMs can successfully renew certificates via Let's Encrypt DNS-01 (this is the one flow that cannot be fully tested in dev, since dev uses step-ca).
- PBS restore spot-check (prod): periodically restore a prod VM's vdb from PBS to a temporary VM (not replacing the running one), verify the restored data is consistent and usable. This tests prod backup integrity without disrupting prod services.

Prod drills should be scheduled during low-impact windows and documented with results. Any drill that reveals a difference between dev and prod behavior is a high-priority finding.

### 14.3 Test Execution Strategy

**Triggers:**
- Every PR targeting dev or main: Static gates + bootstrap validation
- Every `tofu apply`: Bootstrap validation
- Scheduled (weekly): HA and failover tests in dev
- Scheduled (monthly): Backup and restore tests in dev
- Scheduled (quarterly): Prod verification drills
- Manual (before prod deploy): Integration tests

**Failure handling:**
- Validation failures **block merge** from dev to main
- CI provides clear error messages
- Failed VMs remain for debugging
- Rollback via Git revert

### 14.4 Validation Script

**Key checks performed by validation script:**
- DNS servers responding to queries
- DNS publicly queryable from internet
- Certificates valid and not expiring
- Vault accessible and unsealed
- DNS-01 challenge capability (create, verify, delete test TXT record)
- End-to-end certificate issuance test

**Exit codes:**
- 0 = all checks passed
- Non-zero = failure (blocks deployment)

### 14.5 Scorched-Earth Regression Principle

The scorched-earth test levels (0–5, see section 13.5) are tested in
ascending order. Each higher level exercises more of the rebuild path
and may require code changes to scripts that lower levels also depend on.

**Principle: after passing a level, re-run all lower levels that share
code paths with anything that was changed.**

In practice, the lower levels are fast (Level 0 ~5 min, Level 1 ~5 min),
so re-running them is cheap insurance against regressions. The expensive
levels (Level 2+ with Proxmox reinstall) are only re-run if the fix
actually touched the bootstrap path.

| After passing | Re-run | Rationale |
|--------------|--------|-----------|
| Level 1 | Level 0 | Level 1 may have changed pool handling or storage scripts |
| Level 1.5 | Level 0, 1 | Level 1.5 adds `join-node.sh` and changes to `rebalance-cluster.sh` |
| Level 2 | Level 0, 1 | Level 2 likely touches bootstrap/secrets scripts used by 0+1. Level 1.5 only if join/rebalance scripts changed. |
| Level 3 | Level 0, 1 | Level 3 touches NAS scripts. Re-run 2 only if bootstrap changed. |
| Level 4+ | Assess per-change | Changes are workstation-side, unlikely to affect cluster levels |

The goal is not to re-run every combination mechanically, but to verify
that fixes at higher levels didn't break assumptions at lower levels. When
in doubt, re-run — the time cost at the bottom of the stack is minimal
compared to the cost of discovering a regression during a real disaster.

### 14.6 Convergence Testing

The DR test registry (`framework/dr-tests/DR-REGISTRY.md`) is the
primary instrument for measuring convergence (Design Goal 1) and
single-pass convergence (Design Goal 2). Each DR test defines a starting
state, a recovery procedure, and pass criteria. The starting states
are chosen by DFMEA (Design Goal 7) — they represent the degraded
conditions that operational reality produces.

**The DR test registry is a ratchet, not a checklist.** When code
changes, the invalidation table identifies which tests must be re-run.
A change is not safe until all invalidated tests pass at or after the
change commit. This prevents convergence regressions: a fix to one
failure mode cannot silently break convergence from another starting
state.

**Convergence tracking:** Each DR test run is recorded with its commit hash,
pass/fail result, and elapsed time. Over time, this produces a
longitudinal record of single-pass convergence per starting state. A test that
used to pass and now fails is a convergence regression — the system
handles fewer starting states than it previously did. A test that
recently started passing (after a structural fix) is a convergence
expansion — the system handles a new starting state.

**The convergence improvement cycle:**

```
1. A rebuild fails from a starting state
   (operational incident, DR test failure, or manual test)

2. Root cause analysis identifies the hidden dependency
   (cert on vda instead of vdb, unconditional restore overwriting
   healthy state, provider not detecting deleted resources, pinned
   trust going stale)

3. Structural fix eliminates the dependency
   (cert persistence on vdb, conditional restore checking vdb content,
   pre-apply refresh, system CA bundle instead of pinned trust)

4. New DR test case codifies the starting state
   (add to DR-REGISTRY.md with the degraded state as the precondition)

5. The fix strengthens convergence; the test prevents regression
```

Steps 2 and 3 correspond to Design Goal 3 (rebuild failures are
diagnostic). Step 4 corresponds to Design Goal 7 (DFMEA defines the
test surface). The cycle is how the framework's reliability grows: each
incident that occurs in practice becomes a starting state from which
the system must converge, permanently.

**What convergence testing does NOT replace:**

Convergence testing validates that the rebuild path works from diverse
starting states. It does not replace:

- **Functional testing** (validate.sh): does the running system work?
- **Static analysis** (tofu validate, nix flake check, shellcheck):
  is the code correct?
- **Integration testing** (pipeline stages): do the components work
  together?
- **HA testing** (DRT-004, DRT-005): does the system survive node and
  VM failures?

Convergence testing is orthogonal: it validates the *recovery path*
from degraded states, not the *steady state* behavior. A system can
pass all functional tests and still fail to converge from a partial
deployment — the functional tests assume a clean starting state.

**Code review cannot replace live testing for NixOS modules.**

Static analysis (`nix build`, `nix-instantiate --parse`, `bash -n`)
and code review operate on source text, not on the runtime environment.
A NixOS module that calls a framework script by name passes every
static check and fails on every VM — the script is on the workstation,
not in the nix store. A systemd service with a `Requires` dependency
on a oneshot that fails at boot passes every syntax check and prevents
the dependent service from ever starting.

These are not exotic edge cases. They are the normal gap between "the
code is syntactically correct" and "the service works on a real VM."

**Sprint 007** (certbot staging fix): Three independent reviewers
examined NixOS module changes across two review rounds, caught real
bugs (undefined variables, missing policy attachments, template timing
races), and missed both runtime failures that caused a production
outage.

**Sprint 010** (overlay root): Three reviewers across three rounds
unanimously approved the overlay root implementation. The first deploy
to dev broke every VM. Seven follow-up MRs were required:
- Mount mode inheritance: `mount -o remount,ro` on the ext4 made all
  bind-mounts (including `/nix`) read-only. No reviewer caught this.
- Certbot directory permissions: overlay root doesn't persist mode 700
  on `/etc/letsencrypt`. No reviewer caught this.
- Grub path corruption: activation script `sed 's|/store/|/nix/store/|g'`
  matched inside `/nix/store/`, producing `/nix/nix/store/`. No reviewer
  caught this — the corruption was invisible until the next reboot.
- Nix store symlink footgun: writing through `/etc/nix/nix.conf` (a
  symlink into `/nix/store/`) corrupted the immutable nix store. No
  reviewer caught this.

Each of these bugs would have been caught by booting a single dev VM
with the new image before merging. Sprint 009 (convergence function
extraction) was live-tested before merging and deployed cleanly.
Sprint 010 was not, and it took four MRs and two days to stabilize.

**Rule: sprint completion for NixOS module changes requires deployment
to at least one VM and verification that all new or modified systemd
services reach `active` state.** This applies before the sprint is
marked complete, before the change is promoted to prod, and especially
before the change is deployed to control-plane VMs.

**Stronger rule for boot-critical changes: any change to base.nix,
initrd configuration, filesystem mounts, boot loader configuration,
or NixOS activation scripts that modify boot-critical files must be
tested on a temporary VM (VMID 9999 pattern) or non-precious dev VM
before the MR is merged to dev.** This includes overlay root changes,
grub configuration, `postMountCommands`, and any module imported by
all NixOS VMs. Sprint 010 proved that shipping these changes based
on code review alone results in cascading failures that are more
expensive to fix than the original change.

The verification is simple: deploy the image to a non-precious dev VM,
SSH in, and run `systemctl is-active <service>` for each new or modified
service. If any service is `failed` or `inactive`, the sprint has a
bug that static checks and code review cannot detect. This takes minutes
and prevents hours of incident recovery.

**Relationship to the scorched-earth principle (section 14.5):**

The scorched-earth principle says "after fixing a bug at a higher
reset level, re-run lower levels to catch regressions." Convergence
testing generalizes this: after any structural fix, re-run all DR
tests whose starting states overlap with the fix's blast radius. The
invalidation table in DR-REGISTRY.md encodes these overlaps.

The scorched-earth levels (0–5) are a specific set of starting states
ordered by severity. The DR test registry is the broader set, including
starting states that don't correspond to clean reset levels — partial
deploys, provider bugs, manual interventions, and other operational
realities that the reset levels don't cover.

### 14.7 Post-Condition Assertions and Adversarial Testing

**Principle: destructive operations must verify destruction.**

A script that destroys resources should not assume destruction succeeded
just because the destroy command returned. It must check the actual state
afterward and fail if resources remain. This was learned from a bug where
`qm destroy --purge` logged "cannot destroy snapshot ... it's being held"
but continued — the VM was removed from Proxmox config, but the underlying
ZFS zvol remained. The orphan zvol caused replication failures in the
subsequent rebuild. The bug survived 39 Level 0 test runs before timing
conditions finally exposed it.

**Post-condition assertions** are checks embedded in the script itself (not
external test scripts) that verify the script's own work:

```
# After destroying all VMs:
orphans=$(zfs list -o name -H | grep 'vmstore/data/vm-' | wc -l)
if [ "$orphans" -gt 0 ]; then
  echo "FATAL: $orphans orphan zvols remain after VM destruction"
  exit 1
fi
```

Every `reset-cluster.sh` level should have post-condition assertions:

| Level | Post-condition assertions |
|-------|-------------------------|
| `--vms` | 0 VMs on any node. 0 HA resources. 0 replication jobs. 0 VM zvols on any node (no orphans from held snapshots). 0 replication snapshots. 0 CIDATA snippets. No `pbs-nas` storage entry. No backup jobs. |
| `--storage` | All of `--vms` plus: ZFS data pool does not exist on any node. Data NVMe has no partition table. |
| `--cluster` | All of `--storage` plus: Boot NVMe has no partition table. No UEFI boot entries referencing boot NVMe. |
| `--nas` | All of `--cluster` plus: `tofu_state` database does not exist on NAS. Sentinel container not running. |

**Adversarial pre-conditions** maximize the chance of hitting race conditions
and timing-dependent bugs. Before running a destructive test, deliberately
create the worst case:

```bash
# Force a replication sync right before reset (creates fresh ZFS holds)
for job in $(ssh -n root@172.17.77.51 "pvesr list" | tail -n +2 | awk '{print $1}'); do
  ssh -n root@172.17.77.51 "pvesr schedule-now $job"
done
sleep 5
# NOW run the reset — if it handles this, it handles anything
```

**The testing gap this addresses:** External tests (validate.sh, pipeline
regression checks) verify state B — "is the rebuilt cluster healthy?" But
they don't verify the transition from state A to state B — "was every
resource in state A actually cleaned up?" Post-condition assertions verify
the transition. Adversarial pre-conditions ensure the transition is tested
under worst-case conditions, not just favorable timing.

---

## 15. Monitoring and Observability

### 15.1 Architecture: Gatus (Primary) + Gatus Sentinel (Off-Cluster)

**Decision:** Gatus for health monitoring, deployed in two tiers.

**Why Gatus:**
- Config-file-driven (YAML in Git, Category 2) — aligns with "no click-ops" principle
- Single Go binary, lightweight (~64–128MB RAM)
- Supports HTTP, TCP, DNS, TLS, ICMP checks with response validation
- Built-in alerting (email, webhook, Slack, PagerDuty, etc.)
- Simple enough to operate without becoming its own maintenance burden
- Not a metrics/time-series system — does not replace a TSDB for Home Assistant sensor data

**What Gatus is not:** Gatus is a health checker, not a metrics platform. It answers "is this service healthy right now?" with configurable checks. It does not store time-series metrics, render dashboards, or track trends over time. If deep infrastructure metrics become needed (ZFS replication lag trending, VM resource utilization over time, capacity forecasting), Prometheus can be added later alongside Gatus without disrupting it.

### 15.2 Two-Tier Monitoring

**Tier 1: Primary Gatus (prod VLAN)**
- Runs as a NixOS VM on the prod VLAN (see section 5.3 — Gatus is prod-only)
- Monitors all prod infrastructure and application services
- Also monitors cross-environment resources (Proxmox nodes, NAS, PBS) via
  prod→management routing (allowed by the gateway firewall)
- Sends alerts via email (and optionally Home Assistant webhook for in-home notifications)
- Config lives in Git, deployed via standard CI/CD pipeline
- Category 2 configuration, no precious state — fully rebuildable
- Dev services are not monitored by Gatus — dev is expected to break during
  testing. Dev issues surface during dev deploys, not via alerts.

**Tier 2: Sentinel Gatus (on NAS)**
- Runs as a Docker container on the off-cluster NAS
- Monitors exactly one thing: is the primary Gatus on the cluster responding?
- Also directly checks a small set of critical cluster endpoints as secondary verification: Proxmox API, prod DNS (dns1, dns2), and the cluster's outward-facing services
- Sends alerts via email (independent of cluster infrastructure)
- If the cluster is completely down, the sentinel detects it and emails the operator

**Why two tiers:**
The primary Gatus can't monitor itself or detect its own unavailability. If the cluster goes down, the primary Gatus goes down with it — and sends no alert. The sentinel on NAS closes this gap. NAS is outside the cluster, on independent hardware, with independent network connectivity and independent email capability.

**Mutual monitoring:** The two tiers watch each other. The sentinel monitors the primary (detects cluster failure). The primary monitors the sentinel (detects NAS/Docker failure). If either tier dies silently, the other detects it and alerts. This eliminates the blind spot where a dead sentinel goes unnoticed until the cluster fails and no alert arrives.

**Circular dependency avoidance:**
- The sentinel on NAS does not depend on cluster DNS (it uses direct IPs or NAS's own DNS resolution via the gateway)
- The sentinel does not depend on Vault (it has no secrets to retrieve — it's only making HTTP/TCP checks)
- Email sending from NAS uses the NAS mail relay, not any cluster service
- The primary Gatus on the cluster does depend on cluster DNS and networking, but that's acceptable — if DNS is down, Gatus detecting it is useful, and the sentinel provides the fallback detection path

### 15.3 Must-Have Health Checks (Primary Gatus)

These are the signals the reviewer identified as critical. All are configurable as Gatus endpoints in YAML.

**DNS health:**
- dns1-prod and dns2-prod respond to A record queries (UDP/53)
- DNS returns expected results for known records (not just "responds" but "responds correctly")
- Dev DNS is not monitored by Gatus (dev issues surface during dev deploys)

**Certificate health:**
- TLS certificates on all services have >14 days remaining (Gatus native TLS check)
- Escalating alerts: warning at 14 days, critical at 7 days

**Vault health:**
- Vault API responds at `/v1/sys/health`
- Vault is unsealed (health endpoint returns 200, not 503)
- Vault is initialized

**Backup health:**
- PBS API responds (or PBS web UI is reachable)
- Most recent backup for each Category 3 VM is <36 hours old (allows for a missed daily window + buffer)

**ZFS replication health:**
- Last successful replication for each VM is <5 minutes old (replication interval is 1 minute, so 5 minutes indicates a problem)
- Checked via Proxmox API or node-level script that exposes replication status on an HTTP endpoint

**Proxmox cluster health:**
- All nodes are online and quorate (Proxmox API `/cluster/status`)
- No VMs in "error" HA state
- Anti-affinity rules are satisfied (redundant pairs on different nodes)

**Replication mesh health (via repl-health.sh endpoint on each node):**
- All replication interfaces are UP with carrier
- dummy0 is UP with correct /32
- All static routes present (both direct and fallback metrics per peer)
- All corosync links connected (no "disconnected" in corosync-cfgtool output)
- All peers reachable on point-to-point IPs
- Watchdog service running (systemd unit active)

**Application health:**
- Home Assistant API responds
- Any other application-specific health endpoints

**Sentinel health (mutual monitoring):**
- Sentinel Gatus on NAS responds (HTTP 200 on its API endpoint)
- This creates mutual monitoring: the primary watches the sentinel, the sentinel
  watches the primary. If the sentinel dies silently (Docker crash, NAS reboot),
  the primary detects it and alerts the operator. Without this, a dead sentinel
  would go unnoticed until the cluster fails and no alert arrives — the worst
  possible time to discover backup monitoring is broken.

### 15.4 Must-Have Health Checks (Sentinel Gatus on NAS)

Minimal check set — the sentinel is a watchdog, not a comprehensive monitor:

- Primary Gatus web UI responds (HTTP 200)
- Proxmox API on at least one node responds
- dns1-prod responds to DNS query (direct IP, not via cluster DNS)
- dns2-prod responds to DNS query (direct IP)

If any of these fail, the sentinel emails the operator.

### 15.5 Alert Routing

| Severity | Source | Destination |
|----------|--------|-------------|
| Warning (cert expiring, backup >24h old) | Primary Gatus | Email |
| Critical (service down, Vault sealed, DNS failure) | Primary Gatus | Email + Home Assistant notification (webhook) |
| Cluster unreachable | Sentinel Gatus | Email (via NAS mail relay) |

**Home Assistant notifications** are a convenience — they provide immediate in-home alerts (phone push, smart speaker announcement, etc.). Email is the reliable fallback that works regardless of cluster state.

### 15.6 Configuration Example

```yaml
# gatus-config.yaml (lives in Git, deployed to Gatus VM)
endpoints:
  - name: dns1-prod
    group: dns
    url: "dns1.prod.example.com"
    dns:
      query-name: "vault.prod.example.com"
      query-type: "A"
    conditions:
      - "[DNS_RCODE] == NOERROR"
    alerts:
      - type: email
        send-on-resolved: true

  - name: vault-prod
    group: secrets
    url: "https://vault.prod.example.com:8200/v1/sys/health"
    conditions:
      - "[STATUS] == 200"
    alerts:
      - type: email
        send-on-resolved: true

  - name: cert-vault-prod
    group: certificates
    url: "https://vault.prod.example.com:8200"
    conditions:
      - "[CERTIFICATE_EXPIRATION] > 14d"
    alerts:
      - type: email
        failure-threshold: 1

alerting:
  email:
    from: "gatus@example.com"
    host: "smtp.example.com"
    port: 587
    to: "dave@example.com"
```

### 15.7 Design Principles

- Monitoring configuration is code (YAML in Git, Category 2)
- Monitoring is read-only (observes, never mutates)
- Two-tier design eliminates single point of monitoring failure
- Alerts go to durable channels (email) not just ephemeral ones (push notifications)
- Gatus VM has no precious state — fully rebuildable from Git
- If Gatus itself is down, the sentinel detects it — no silent failure mode
- If the sentinel is down, the primary detects it — no silent blind spot

### 15.8 NAS Platform Constraints (Synology DSM)

The NAS runs the sentinel Gatus (Docker container), the placement watchdog, and
the placement health server. Scripts deployed to the NAS must work within Synology
DSM's limited userland. These constraints were discovered during the placement
watchdog deployment and apply to all future NAS-deployed scripts.

**Available:** `bash`, `python3`, `jq`, `curl`, `ssh`, `scp`, `crontab`, Docker.

**Not available:** `socat`, `yq`, `opkg`/`apt` (no package manager for adding
tools). These cannot be installed without third-party package sources or Docker.

**SSH/SCP limitations:** The NAS SSH server does not enable the SFTP subsystem by
default. Modern OpenSSH `scp` uses SFTP internally, so `scp` calls to the NAS fail
with `subsystem request failed on channel 0`. Use `scp -O` (legacy SCP protocol)
for all file transfers to the NAS.

**Config file format:** Scripts that parse `config.yaml` on the workstation must
use a JSON conversion for NAS deployment (no `yq` on NAS). The deploy script
(`configure-sentinel-gatus.sh`) converts `config.yaml` to `config.json` via
`yq -o json` and copies the JSON version to the NAS. Scripts auto-detect the format:
if `config.json` exists, use it with `jq`; otherwise fall back to `config.yaml`
with `yq`. This preserves compatibility when running scripts from the workstation.

**Process persistence:** Background processes started via `nohup` do not survive
NAS reboots. Long-running services (like the placement health server on port 9200)
should be registered as Synology Task Scheduler entries with a boot-up trigger.
Cron jobs (`crontab`) are persistent across reboots.

---

## 16. Backup Strategy

**Design principle:** Backups that have never been verified are
assumptions, not protection. Mycofu's backup strategy ensures not only
that backups are taken, but that they contain real application state and
are recoverable. Every `rebuild-cluster.sh` run verifies backup safety
through a three-gate model (see section 14.2): pre-backup data
protection, backup execution with hard failure, and post-backup content
verification. A cluster that reports success has verified, recoverable
backups.

### 16.1 Architecture: ZFS Snapshots + PBS + NAS

**Design principle:** ZFS replication is the availability mechanism (keeps VMs running after failures). Proxmox Backup Server (PBS) is the backup mechanism (provides versioned, point-in-time recovery). These complement each other — replication faithfully copies mistakes and corruption; backups let you go back in time.

**Components:**
- **ZFS replication (availability):** Keeps VM storage replicated to other nodes for HA restart. Not a backup — propagates deletions and corruption.
- **Proxmox Backup Server (backup):** Runs as a VM inside the cluster. Provides incremental-forever, deduplicated, versioned backups with retention policies.
- **NAS (off-cluster durability):** PBS datastore is NFS-mounted from NAS. Backup data physically resides outside the cluster for disaster recovery.

### 16.2 PBS Configuration

**PBS runs as a VM** inside the Proxmox cluster (low resource cost, reliable).

**PBS datastore** is an NFS mount from NAS. This gives the best of both worlds:
- PBS VM benefits from cluster HA (restarts if node fails)
- Backup data lives on NAS (survives total cluster loss)
- Avoids NAS DSM VM reliability issues (PBS runs as a proper Proxmox VM, not a NAS VM)

**Retention policy:**
- Daily backups retained for 7 days
- Weekly backups retained for 4 weeks
- Monthly backups retained for 6 months
- Retention is configurable per VM based on criticality

### 16.3 What Gets Backed Up

Backup scope is determined by the data taxonomy (see section 11.2.1). Only VMs with precious state (Category 3) need PBS backup of their vdb. VMs with only derivable + configuration data can be fully recreated from Git.

**Dev VMs are not backed up.** The dev environment exists to prove that
rebuilding from scratch works. If a dev VM can't be destroyed and recreated
without data loss, that's a bug in the framework, not a reason to restore from
backup. Dev Vault is re-initializable with `init-vault.sh dev`. Dev DNS, acme-dev,
and testapp are stateless or fully regenerable. Backing up dev VMs wastes PBS
storage, adds noise to monitoring (backup job failures), and creates the
temptation to restore instead of rebuild — which is the opposite of dev's purpose.

The one exception: testapp-dev may be backed up periodically as a **guinea pig
to test the backup/restore workflow itself** — not because its heartbeat data
matters, but to prove PBS restore works before it's needed for prod. Once
proven, ongoing testapp-dev backups are unnecessary.

| What | Method | Frequency | Notes |
|------|--------|-----------|-------|
| Framework VM root disks (vda) | Not backed up | N/A | Category A/B: rebuildable from Git |
| Framework VM vdb with precious state (Cat 3) | PBS backup (vdb only) | Daily | GitLab, Vault, databases |
| Framework VM vdb with config only (Cat 2) | Not backed up via PBS | N/A | DNS — fully regenerable from Git |
| Vendor appliance VMs (Category C) | PBS backup (whole VM) | Daily | HAOS, PBS — vda is not rebuildable from Git |
| OpenTofu state | PostgreSQL backup on NAS | Daily | Already off-cluster |
| Vault data | Raft snapshots → PBS | Daily | Via Vault snapshot agent |
| Git repository | External (GitHub/GitLab) | Every push | All configs, SOPS secrets |
| Infrastructure secrets | SOPS in Git | Every push | Encrypted with operator key |

**GitLab's vdb is precious state (Category 3).** While the Mycofu git repo can
be re-pushed from the operator's workstation, GitLab also contains CI/CD pipeline
history, merge request history, project settings, runner registrations, and
potentially other repositories hosted for the operator's team. These cannot be
regenerated from Git. GitLab's vdb is backed up by PBS daily.

**Vault backup mechanics:**

Vault's Raft storage lives on Vault's vdb, which is backed up by PBS like any other Category 3 volume. However, PBS takes a filesystem-level snapshot of the vdb, which may catch Vault's Raft storage mid-write. To guarantee a consistent Vault backup, a Vault Raft snapshot is taken *before* PBS backs up the vdb.

The mechanism:
1. A systemd timer on the Vault VM runs daily (before the PBS backup window)
2. The timer triggers `vault operator raft snapshot save /var/lib/vault/raft-snapshot.gz`
3. This creates a point-in-time consistent snapshot of Vault's entire state (secrets, policies, leases, tokens)
4. PBS then backs up the vdb, which now contains both the live Raft data and the consistent snapshot file
5. On restore: if the live Raft data is consistent, Vault recovers normally. If not, the snapshot file provides a known-good fallback: `vault operator raft snapshot restore /var/lib/vault/raft-snapshot.gz`

The `vault operator raft snapshot` command runs locally on the Vault VM and authenticates using the Vault root token or a dedicated snapshot policy. Since it runs on the Vault VM itself (not on a remote agent), it has direct access to the Vault API via localhost — no network dependency, no additional TLS setup.

**Ordering guarantee:** The systemd timer is scheduled to complete before the PBS backup window. If the snapshot fails, Gatus detects the stale snapshot file (>36 hours old) and alerts. PBS still takes the disk-level backup regardless — the snapshot is a belt-and-suspenders consistency measure, not a replacement for the disk backup.

### 16.4 Restore Workflows

**Critical principle for framework VMs (Category A/B): restore only vdb, never the whole VM.**

PBS backs up VM disks. A "whole VM restore" from PBS replaces everything — vda
(root disk), vdb (data disk), and the VM configuration. For framework VMs
(built from Git via Nix), this is never what you want, because:
- **vda is stale.** It's from the backup, not from the current Git commit.
  The current commit may have NixOS module changes, security patches, or
  configuration updates that the backed-up vda doesn't include. vda is
  Category 1 (derivable from Git) — it should always be rebuilt, never restored.
- **CIDATA is missing.** PBS does not back up the cloud-init ISO — it's a
  Proxmox-generated attachment derived from OpenTofu, not a VM disk. A
  whole-VM restore boots without cloud-init configuration (no hostname, no SSH
  keys, no bootstrap secrets).
- **OpenTofu state desyncs.** OpenTofu tracks the VM it created (VMID, disk
  paths, configuration). A PBS restore replaces the VM's internals without
  updating tofu state. The next `tofu apply` sees drift and may recreate the
  VM, destroying the restore.

The correct restore procedure for framework VMs is: deploy the VM fresh from
OpenTofu (which gives you the current vda and CIDATA), then replace only the
vdb with the backed-up version. This combines the current software (from Git)
with the preserved precious state (from PBS).

**Exception: vendor appliance VMs (Category C) use whole-VM restore.** Vendor
appliances like HAOS are not built from Git — their vda is the vendor's image,
installed manually or via the vendor's update mechanism. The framework cannot
rebuild it. For these VMs, PBS backs up the entire VM (vda + vdb), and disaster
recovery restores the entire VM from PBS. See section 11.0 for the full
two-class model.

**Version skew between vda and vdb is normal.** When restoring a vdb from a
backup taken while commit A was running onto a VM built from commit B, the
result is newer software (B) with older data (A). This is the same thing that
happens during every routine image update — `tofu apply` deploys a new vda
while the existing vdb carries forward. Well-designed services handle this
through database migrations on startup (GitLab), Raft schema evolution (Vault),
and similar forward-migration mechanisms. The framework does not need special
handling for this; it is the expected, normal condition.

The problematic case — older software with newer data (a downgrade) — only
occurs if the operator deliberately checks out an older commit. Most services
do not handle downgrades gracefully. Avoid this by always building from the
latest commit, or from a commit known to be compatible with the data being
restored.

**Single VM data recovery (accidental deletion, corruption):**
Use the framework restore tool rather than a hand-written Proxmox sequence:

```bash
framework/scripts/restore-from-pbs.sh --force --target <vmid> --backup-id <volid>
```

The tool validates PBS availability, selects only the data disk, handles the
HA/stopped maintenance window, and preserves vda plus CIDATA from the current
deployment. Always pin the backup when corruption or a failed rebuild may have
poisoned the latest snapshot.

**VM rebuild (planned — image update or replacement):**
1. `safe-apply.sh` or `rebuild-cluster.sh` derives a preboot restore manifest
   from the default OpenTofu plan before changing VMs.
2. Phase 1 runs OpenTofu with `start_vms=false` and `register_ha=false`.
   Replacement VMs have fresh vda images, correct MACs from config.yaml,
   CIDATA from OpenTofu, and target vdb attachments, but they have not booted
   and are not under HA control.
3. For backup-backed VMs, `restore-before-start.sh` restores vdb from the
   pinned PBS backup while the VM is still stopped. A VM with no usable backup
   may proceed only through explicit per-run `FIRST_DEPLOY_ALLOW_VMIDS`
   approval.
4. Phase 2 runs OpenTofu with `start_vms=true` and `register_ha=true`.
   Backup-backed services first boot with restored state; stateless VMs need
   no restore step and simply start in Phase 2.

**Full cluster disaster recovery (Level 1 — NAS intact):**

This is the most complex restore scenario. `rebuild-cluster.sh` handles
it automatically — step 7.6 runs the Sprint 031 preboot restore flow for all
backup-backed framework VMs, and subsequent steps handle incompatibilities
(stale certs, Vault token mismatches). See section 13.4 for the full
automated sequence.

The reference procedure below describes the framework path. Use it as the
manual fallback only when `rebuild-cluster.sh` itself is unavailable; the
fallback reproduces the same phase boundaries and must keep backup-backed
framework VMs unbooted until their data disks are restored or explicitly
approved as first-deploy empty.

1. Run the stopped Phase 1 OpenTofu apply for framework VMs (Category A/B):
   - Fresh vda from current Git commit (correct software)
   - MAC from config.yaml (correct identity for static IP assignment)
   - CIDATA from OpenTofu (correct configuration)
   - Target vdb attachment present, with the VM still stopped and absent from HA
2. Recreate the PBS VM and reconnect it to the NFS datastore on the NAS; all
   pre-disaster backups become available from that datastore.
3. Run the preboot restore step for framework VMs with precious state (see
   section 5.4 VM inventory):
   a. Build the same plan-derived restore manifest used by `safe-apply.sh`.
   b. Run `restore-before-start.sh` with the pre-deploy PBS pin file.
   c. Treat a missing backup, missing pin, or restore failure as fail-closed;
      do not proceed to Phase 2 for backup-backed VMs until the data disk is
      restored or a first-deploy empty start is explicitly approved.
4. Run the Phase 2 OpenTofu apply with VM startup and HA registration enabled.
5. If the wrapper is unavailable and the operator must perform step 3 by hand,
   use the same primitive that the framework uses:
   `restore-from-pbs.sh --leave-stopped`. Confirm the target VM is stopped,
   absent from HA, and matched by VMID and vdb size before writing to its data
   zvol; then run Phase 2 only after all required restores or approvals are
   complete.
6. **Vendor appliance VMs** (Category C — HAOS, etc.):
   a. Restore the **entire VM** from PBS (whole-VM restore is correct here
      because vda is not rebuildable from Git)
   b. Verify the restored MAC matches config.yaml (it should — the backup was
      taken from a VM that was deployed with the same config.yaml MACs)
   c. Start the VM
7. Restore order matters for dependencies:
   - **Vault first** (if restoring, not fresh-init) — other services may need it
   - **GitLab second** — contains repos and CI history
   - **Application VMs last** — Home Assistant, databases, etc.
8. After restoring GitLab: re-register the runner (`register-runner.sh`) because
   runner registration is stored in GitLab's database, and the runner VM is new
9. Run `validate.sh` to confirm everything is healthy

**What NOT to do during disaster recovery:**
- Do NOT restore the entire VM from PBS **for framework VMs** (replaces vda
  with stale image, loses CIDATA, desyncs OpenTofu state). Whole-VM restore
  IS correct for vendor appliances (Category C) whose vda is not rebuildable.
- Do NOT restore vda from PBS for framework VMs (it's Category 1 — rebuild
  from Git instead)
- Do NOT skip the `rebuild-cluster.sh` step and try to restore VMs directly
  from PBS into a bare cluster (OpenTofu state, networking, storage, and CIDATA
  won't exist)

### 16.5 Restore Testing

Restore testing is part of the validation and testing strategy (see section 14.2, "Backup and restore tests" and "Prod verification drills"). In summary:
- Monthly restore drills using testapp-dev as a guinea pig (backup, destroy,
  restore, verify data continuity — tests the PBS workflow, not dev data)
- Quarterly prod spot-checks (restore a prod VM's vdb to a temporary VM, verify
  data integrity without disrupting prod)
- A backup you've never restored is a theory, not a plan

**Automated restore verification during rebuild:**

`rebuild-cluster.sh` verifies backup recoverability as part of every
rebuild through the three-gate model (section 14.2):

1. **Pre-backup (step 16a):** If PBS has existing backups but the VM
   appears fresh, the restore failed — stop before overwriting good data
2. **Backup (step 18):** Take backups, hard failure if any vzdump fails
3. **Post-backup (step 16b):** Verify backups contain real application
   state, not just filesystem metadata

This means every successful `rebuild-cluster.sh` run is also a backup
verification — the operator doesn't need to schedule a separate drill
to know backups are working. The monthly drill (manual restore to a
temp VM) tests a scenario the automated checks cannot: restoring to a
different VM and verifying the application actually starts with the
restored data.

---

## 17. Home Assistant (Tier-0)

**Tier-0 definition:**
- Systems required for basic household operation (lighting, HVAC, safety)
- Home Assistant OS (HAOS) is Tier-0

**How Home Assistant differs from other VMs:**
- HAOS is not generated from Git sources via the Nix image pipeline — it runs the official HAOS image directly
- Home Assistant has no application-level redundancy or failover features — all failover is handled by Proxmox HA
- HAOS does not participate in the cloud-init environment binding model
- The Supervisor (HAOS's internal management layer) is a second control plane not managed by OpenTofu or Nix
- These are accepted deviations from the design goals, motivated by HAOS being the officially supported and most broadly validated deployment model. The monorepo configuration management strategy (below) mitigates the most important goal violations.

### 17.1 Configuration Management: Monorepo with rsync

Home Assistant YAML configuration lives in the monorepo under `home-assistant/config/`. There is no Git repository or Git working directory on the HAOS VM. Configuration is deployed and captured via rsync.

**Deploy (from Mac or CI → HAOS VM):**
```
rsync [exclusions] monorepo/home-assistant/config/ → HAOS:/config/
```
Pushes authored YAML configuration from the monorepo into the HAOS VM's `/config/` directory. Excludes runtime state (`.storage/`, `*.db`, `secrets.yaml`). Can trigger a Home Assistant config reload or restart via the REST API.

**Capture (from HAOS VM → Mac):**
```
rsync [exclusions] HAOS:/config/ → monorepo/home-assistant/config/
```
Pulls edited configuration back from the HAOS VM into the monorepo for review and commit. Used after on-VM editing sessions.

**On-VM editing workflow:**
1. SSH or VS Code into HAOS, edit files in `/config/`
2. Test in Home Assistant UI (reload automations, check behavior)
3. Iterate until satisfied
4. From Mac: run capture script (rsync from HAOS to monorepo)
5. `git diff` — review changes locally with normal tools
6. `git add`, `git commit`, `git push`

**Rsync exclusion list (same for both directions):**
The exclusion list defines the boundary between authored config (Category 2, in Git) and runtime state (Category 3, not in Git). It lives in the monorepo as `home-assistant/rsync-filter.conf` and is itself version-controlled. Excluded from rsync:
- `.storage/` (entity registry, device registry — Category 3 precious state)
- `*.db`, `*.db-shm`, `*.db-wal` (history database — Category 3)
- `secrets.yaml` (managed via SOPS, deployed separately)
- `home-assistant.log*`, `deps/`, `__pycache__/`, and other runtime artifacts

**Guard rails:**
- Deploy script refuses to run if the monorepo checkout has uncommitted changes in `home-assistant/config/` (prevents overwriting un-captured on-VM edits)
- Capture script runs `git diff --stat` after rsync to prompt review before committing

**`secrets.yaml` handling:**
- `secrets.yaml` is gitignored (contains sensitive values)
- Managed via SOPS: encrypted in the monorepo, decrypted during deploy and written to `/config/secrets.yaml`
- This brings HAOS secrets into the existing SOPS secrets management model

**Optional `.storage/` snapshotting:**
Selected `.storage/` files (e.g., `core.entity_registry`, `core.device_registry`, `core.area_registry`) can optionally be captured into the monorepo for version tracking. This is a read-only snapshot operation (capture direction only, never deployed back). It provides versioned history of entity naming changes without making `.storage/` part of the deploy flow.

### 17.2 Data Taxonomy for Home Assistant

| Data | In Git? | Category | Recovery path |
|------|---------|----------|---------------|
| YAML config (automations, scripts, configuration.yaml, etc.) | Yes (monorepo) | Cat 2 (configuration) | Git + rsync deploy |
| `.storage/` (entity/device/area registries, naming history) | No (optionally snapshotted) | Cat 3 (precious state) | PBS backup or ZFS replica |
| `home-assistant_v2.db` (history, statistics) | No | Cat 3 (precious state) | PBS backup or ZFS replica |
| `secrets.yaml` | No (SOPS-encrypted in Git) | Managed separately | SOPS decrypt during deploy |
| Add-on data (ESPHome configs, etc.) | Partially | Mixed | Depends on add-on |

### 17.3 Migration from Standalone Home Assistant

**One-time procedure to transfer existing Home Assistant state to the new Proxmox HAOS VM:**

1. **On the existing standalone Home Assistant:** Create a full backup from Settings → System → Backups. This captures the entire `/config/` directory including `.storage/` (entity/device registries, naming history), `home-assistant_v2.db` (history), add-on data, and all configuration files.

2. **On Proxmox:** Create a new HAOS VM from the official HAOS qcow2 image (imported as a ZFS zvol). On first boot, HAOS presents an onboarding screen with a "Restore from backup" option.

3. **Restore:** Upload the backup file from step 1. HAOS restores all state — entity IDs, device mappings, naming disambiguation history, automations, dashboards, integrations, the history database.

4. **Post-migration:**
   - Assign the new VM the same IP address as the old standalone host (or update DNS). This ensures integrations that connect by IP continue working.
   - If USB devices are used (Zigbee coordinator, Z-Wave stick), pass them through to the Proxmox VM. Device paths may change (e.g., `/dev/ttyUSB0` → `/dev/ttyACM0`) — update the relevant integration config.
   - Verify all integrations, automations, and dashboards are functioning.
   - Monitor the Proxmox VM console during restore — the HA UI provides minimal feedback on progress. Watch for CPU/disk activity to settle.

5. **After successful migration:** Transition to the monorepo rsync workflow. Run the capture script to pull the current `/config/` (excluding `.storage/` and databases) into the monorepo. This becomes the initial commit of Home Assistant configuration in the infrastructure repo.

### 17.4 Normal Operation

- HAOS runs on one node, ZFS zvols replicated to both other nodes every 1 minute
- Proxmox HA enabled with highest priority (restarts before other VMs after node failure)
- PBS backs up HAOS vdb daily to NAS

### 17.5 Failover (Unplanned Node Failure)

1. Proxmox detects failure (~30–60 seconds fencing timeout)
2. Proxmox HA restarts HAOS on a surviving node from ZFS replica (highest priority)
3. HAOS boots, reads state from disk (~10–15 seconds)
4. State loss: up to 1 minute (bounded by replication interval)
5. Total time to recovery: <2 minutes (based on measured HA migration times for other VMs; HAOS boot time may differ)

### 17.6 Why ZFS Simplifies Tier-0

- With Ceph (rejected), Tier-0 required a complex dual-mode design: Ceph for normal operation, local storage fallback for rescue mode. This was necessary because Ceph quorum loss at 3 nodes could take all storage offline.
- With ZFS, storage is always local. A single node failure never affects storage on surviving nodes. The failover scenario is just the standard Proxmox HA restart — no special architecture needed.

### 17.7 Remaining Considerations

- Only one HAOS instance should run at a time (Proxmox HA fencing handles this)
- Backup/restore procedures tested specifically for HAOS
- HAOS update procedure documented (not part of Nix image pipeline)
- Future evaluation: Home Assistant Core on NixOS as an alternative to HAOS, for tighter alignment with design goals. Can be tested on the dev VLAN without affecting prod.

---

## 18. Update and Upgrade Procedures

*[To be detailed in next iteration]*

**NixOS updates:**
- Update flake inputs
- Build new VM images
- Deploy via standard CI/CD (dev → prod)

**Proxmox updates:**
- One node at a time (rolling update)
- Trigger final ZFS replication sync for all VMs on the target node
- Shut down VMs, restart on other nodes from ZFS replicas (10–20s downtime per VM)
- All VMs are HA-enabled and replicated to both other nodes, so any surviving node can host any VM
- Update Proxmox on the evacuated node
- Reboot, verify, move VMs back (or leave them distributed)
- Storage on remaining nodes is unaffected during update (no degraded distributed pool)

**Application updates:**
- Update image digest in Git (for containers)
- Update package version in Nix (for Nix-native)
- Standard CI/CD deployment

**Security patching:**
- Critical CVEs: Expedited update process
- Regular updates: Standard dev → prod flow

---

## 19. Network Configuration

Network architecture is documented in section 6.2. This section is reserved for implementation-specific network details to be added during buildout (interface naming, bridge configuration, IP assignments, etc.).

---

## 20. Scaling and Site Configuration Changes

The separation between framework and site configuration (section 12.7) means that common scaling operations are primarily changes to `site/config.yaml` and the OpenTofu site layer, not changes to the framework itself. This section documents the most common operations.

### 20.1 Adding a Node

Adding a node to the cluster increases total capacity and improves the N+1 budget.

**Site configuration changes:**
1. Add the new node to `site/config.yaml` (hostname, management IP, replication network addresses if applicable)
2. Add OpenTofu resources for any VMs that should be placed on the new node

**Infrastructure operations:**
1. Install Proxmox on the new node (standard Proxmox installer)
2. Configure the data pool (`configure-node-storage.sh <node>`) — creates the ZFS pool on the data NVMe, configures Proxmox storage
3. Join the node to the existing Proxmox cluster (`pvecm add`)
4. If using a dedicated replication network: cable the new node to all existing nodes and configure the new point-to-point links
5. Run `tofu apply` — OpenTofu creates any new VMs and may redistribute existing VMs based on placement rules
6. Proxmox begins replicating existing VMs to the new node automatically (configured by OpenTofu or Proxmox HA rules)

**What changes architecturally:**
- N+1 capacity budget increases. With 4 nodes of equal RAM, you can now schedule 3 nodes' worth of VMs (75% of total capacity, up from 67% with 3 nodes).
- ZFS replication fan-out increases — each VM is replicated to more nodes, giving more failover options. You may choose to replicate to all nodes or to a subset (e.g., 2 of 3 peers).
- Anti-affinity constraints have more placement options, reducing the chance of constraint conflicts.
- No framework changes are needed. The NixOS modules, OpenTofu modules, and operational scripts are node-count-agnostic.

**What does NOT change:**
- VM images (they don't know how many nodes exist)
- DNS configuration (no per-node DNS records for infrastructure services)
- Vault configuration (same auth policies regardless of node count)
- Monitoring (Gatus automatically checks new node if added to Proxmox API responses)

### 20.2 Removing a Node

Planned decommission of a node (hardware replacement, downsizing).

1. Verify the remaining nodes have sufficient capacity under N+1 rule for all VMs
2. Evacuate: migrate all VMs off the target node (Proxmox live migration or stop/start on other nodes)
3. Remove ZFS replication targets pointing to the target node
4. Remove the node from the Proxmox cluster (`pvecm delnode`)
5. Update `site/config.yaml` — remove the node entry
6. Run `tofu apply` to reconcile
7. If using dedicated replication network: remove the cables/links to the decommissioned node

### 20.3 Replacing a Node (Hardware Failure)

If a node fails, VMs are already running on surviving nodes (restarted by Proxmox HA from ZFS replicas). No data is lost beyond the replication interval (1 minute).

Recovery:
1. Install Proxmox on replacement hardware
2. Configure identically to the failed node (same hostname, same ZFS pool name)
3. Join to cluster
4. Proxmox begins replicating VMs to the new node
5. No site config changes needed if the replacement uses the same hostname and IPs

### 20.4 Changing the Domain

If the base domain changes (e.g., `example.com` → `newdomain.com`):

**Pre-deploy (operator, manual):**

1. At the new domain's registrar: create A records for `dns1.<new-domain>` and
   `dns2.<new-domain>` pointing to the public IP. Create NS delegation for
   `prod.<new-domain>` to those nameservers. No delegation needed for
   `dev.<new-domain>` (dev uses step-ca, not public LE).
2. If the gateway has DHCP search domains configured for non-Mycofu devices,
   update those (two fields: prod VLAN and dev VLAN). Mycofu VMs get the
   search domain from CIDATA, so they pick up the change on the next deploy.
3. Update `domain:` in `site/config.yaml` — this is the only code change needed.
   All DNS zone names, FQDNs, GitLab URLs, and email addresses are derived from
   this single field.
4. Regenerate Gatus config: `generate-gatus-config.sh > site/gatus/config.yaml`
   (Gatus monitors domain-specific endpoints; the config must reflect the new domain).

**Deploy:**

5. Build DNS image if the DNS NixOS module changed, otherwise skip (other role
   images are environment-ignorant and unchanged by a domain change).
6. `tofu-wrapper.sh apply` — two runs required (HA resources need a second apply
   after VM recreation due to the bpg provider VMID limitation).

A domain change triggers CIDATA changes on every VM because write_files contain
domain-derived values (FQDNs, search domains, API URLs, zone data). This means
`tofu apply` recreates ALL VMs. This is correct behavior — every VM needs its
identity regenerated when the domain changes.

**Post-deploy recovery** (required because all VMs are recreated):

7. Clear SSH host keys for all recreated VMs
8. `init-vault.sh dev` + `configure-vault.sh dev`
9. `init-vault.sh prod` + `configure-vault.sh prod`
10. `configure-replication.sh "*"` (all VMs recreated = all replication jobs need cleanup)
11. `configure-gitlab.sh` (new GitLab instance)
12. `register-runner.sh` (new runner registration)
13. `configure-backups.sh` (recreate PBS backup jobs)
14. `validate.sh` to confirm the full chain of trust is operational

**PBS restore stale artifact handling:** When VMs are recreated after a
domain change, PBS restores vdb from backups made under the old domain.
Two incompatibilities are automatically detected and resolved:

- **Stale TLS certificates:** Step 9 pre-flight compares cert directory
  names in `/etc/letsencrypt/live/` against the expected FQDN
  (`<hostname>.<env>.<domain>`). Mismatched certs are cleaned, and
  certbot re-acquires for the correct domain.
- **Vault token mismatch:** `init-vault.sh` detects HTTP 403 when the
  SOPS root token doesn't match the restored Raft data. It auto-recovers
  by wiping `/var/lib/vault/data/*` (Raft only, preserving TLS certs)
  and reinitializing. See the Vault section for details.

For pipeline-driven domain changes, steps 8–10 and 13 are handled automatically by
`post-deploy.sh <env>` which runs after each deploy stage. Steps 11–12 (GitLab and
runner) are Tier 2 operations that require workstation intervention.

**Note:** Vault re-initialization (steps 8–9) commits new SOPS-encrypted unseal keys
and root tokens to Git. If any VMs reference these SOPS values via CIDATA, a
subsequent `tofu apply` may detect CIDATA drift and recreate those VMs again. This
is a known two-pass behavior for domain changes. For normal deploys (image-only
changes), only the changed VMs are recreated and the recovery is scoped to those VMs.

**Cleanup:**

15. At the old domain's registrar: leave the old delegation in place temporarily,
    then remove after cutover is confirmed.

**Validated:** This procedure was exercised during the `wuertele.com` → `bfnet.com`
migration. 36/37 validation checks passed; the single failure was a pre-existing gap
unrelated to the domain change.

**Known gap — Gatus snippet content detection:** The bpg Proxmox provider references
CIDATA snippets by path, not content hash. Changing Gatus config content (step 4)
does not trigger VM recreation. The operator must either taint the Gatus VM or include
a config content hash in CIDATA to make tofu detect the change. This gap applies to
any snippet content change, not just domain changes.

**Known gap — stale DHCP leases on non-recreated VMs:** VMs whose CIDATA has no
domain-derived values (currently only acme-dev) are not recreated by `tofu apply` during
a domain change. These VMs retain their old DHCP lease with the previous search domain
until natural lease renewal. The correct fix is to include a domain-derived value in
every VM's CIDATA (e.g., `/run/secrets/domain`), so a domain change forces recreation
of all VMs. Impact is minimal for acme-dev (it uses explicit IP addresses, not the search
domain, for its DNS operations), but the gap violates the principle that CIDATA defines
VM identity.

### 20.5 Adding an Environment

To add a new environment (e.g., a staging VLAN):

1. Add the environment to `site/config.yaml` (VLAN ID, subnet, gateway, DNS server IPs, search domain)
2. Configure the new VLAN on the gateway/switch (manual — gateway management is a non-goal)
3. Optionally configure a DHCP scope for non-Mycofu devices on the new VLAN
4. Add OpenTofu resources for the new environment's infrastructure stack (DNS pair, Vault instance, acme-dev if non-prod)
5. Add any extra DNS records for the new environment in `site/dns/zones/staging.yaml` (optional — VM A records are derived from config.yaml)
6. Run `tofu apply` — creates the new VMs with CIDATA containing the correct zone data

The framework modules are environment-agnostic by design. The same NixOS modules and OpenTofu modules work for any number of environments — each environment is just another instance with its own VLAN, subnet, and DNS domain.

### 20.6 Changing the Storage Backend (Planned)

**Status: Architecture designed, not yet implemented.**

The framework currently uses ZFS local storage with replication. This is the
right choice for 3-node clusters where Ceph's quorum fragility is unacceptable.
However, at 5+ nodes, Ceph becomes operationally attractive: shared storage
eliminates the CIDATA snippet replication requirement, the orphan zvol lifecycle,
the placement watchdog, and the rebalance script. HA "just works" because all
nodes see the same storage.

The framework should support both storage backends behind a `config.yaml`
abstraction:

```yaml
storage:
  backend: zfs-replication    # or: ceph
  pool_name: vmstore          # ZFS pool name (zfs-replication) or Ceph pool name (ceph)

  # ZFS-replication-specific:
  replication_interval: 1     # minutes between replication syncs

  # Ceph-specific (when backend: ceph):
  # ceph_network: 10.10.0.0/24
  # ceph_replication_factor: 3
```

**What changes between backends:**

| Concern | ZFS replication | Ceph |
|---------|----------------|------|
| CIDATA snippets | Deploy to all nodes (framework handles) | Shared storage — visible everywhere |
| VM recreation cleanup | `configure-replication.sh` cleans orphan zvols | Not needed — no per-node replicas |
| Post-failover rebalance | `rebalance-cluster.sh` migrates VMs back | Not needed — Ceph supports live migration |
| Placement watchdog | Required (NAS monitors drift) | Not needed |
| `node_name` lifecycle rule | Required (prevents ForceNew destruction) | Not needed (migration, not recreation) |
| Replication health monitoring | `repl-health.sh` on each node | Ceph health (`ceph status`) |
| Backup | PBS backs up from any node | PBS backs up from any node (same) |
| Minimum viable nodes | 2 (degraded) or 3 (full N+1) | 5 (comfortable quorum + capacity) |
| Storage failure mode | Node loss affects VMs on that node only | Quorum loss (< 3 monitors) loses all storage |

**What does NOT change between backends:**

- Dev/prod environment separation (VLANs, CIDATA, DNS)
- Certificate management (ACME, step-ca, DNS-01)
- Secrets management (SOPS, Vault, pre-deploy/post-deploy classification)
- NixOS image builds (content-addressed, environment-ignorant)
- OpenTofu VM lifecycle (VM creation, HA resources)
- CI/CD pipeline (GitLab, runner, two-tier deployment)
- Monitoring (Gatus, sentinel)
- Backup (PBS to NAS — Ceph replication is not backup)
- `rebuild-cluster.sh` (minus the replication steps, plus Ceph pool setup)
- `validate.sh` (storage health checks adapted per backend)
- The config.yaml / new-site.sh / framework/site separation

The majority of the framework — roughly 85% — is storage-backend independent.
The storage-dependent code is concentrated in a small number of scripts and
OpenTofu module behaviors that can be selected by `config.yaml → storage.backend`.

**Implementation approach:** A `storage.backend` field in config.yaml selects
the behavior at every decision point. Scripts check the backend and branch:
the ZFS path runs `configure-replication.sh`, the Ceph path runs
`configure-ceph-pool.sh`. The OpenTofu proxmox-vm module conditionally deploys
snippets to all nodes (ZFS) or relies on shared storage (Ceph). The
`rebuild-cluster.sh` sequence includes storage setup (ZFS pool creation or
Ceph cluster bootstrap) as an early step, and the rest of the sequence
proceeds identically.

**The contract for changing backends:** The operator changes
`storage.backend` in config.yaml, runs `reset-cluster.sh` (to tear down the
existing storage), and runs `rebuild-cluster.sh`. The framework handles
everything else — Ceph cluster formation, pool creation, VM migration to
shared storage. This is the same one-config-one-command contract that the
framework provides for initial deployment.

**When to implement:** After the current ZFS replication backend is proven
through the scorched-earth test (Step 10C) and the framework has been used
for real applications. The Ceph backend should be developed on a separate
branch, tested on a 5-node cluster, and merged when validated. The ZFS
backend remains the default for small clusters.

### 20.7 Immutable Root Image: SquashFS + Overlay (Planned)

**Status: Planned improvement, not yet implemented.**

The current NixOS VM images are raw block device images with an ext4
partition. This produces a writable root filesystem — vda is a read-write
ext4 mounted as `/`. The Mycofu architecture treats vda as Category 1
(derivable, disposable), but the writability is tolerated rather than
enforced. Nothing *should* write persistent data to vda, but nothing
*prevents* it either. A process that writes to `/var/lib/something` on vda
appears to work until the VM is recreated, at which point the data silently
vanishes. This is the same failure mode as a manual fix that isn't in the
repo — it works until it doesn't.

**The improvement:** Replace the writable ext4 image with a squashfs root
plus a tmpfs overlay:

| Component | Current (ext4) | Planned (squashfs + tmpfs) |
|-----------|---------------|---------------------------|
| Root filesystem | Writable ext4 on ZFS zvol | Read-only squashfs mounted from zvol |
| `/nix/store` | Writable (but NixOS mounts read-only in practice) | Read-only by construction |
| `/var`, `/tmp`, `/etc` | Writable on ext4 (persists across reboots) | tmpfs overlay (lost on reboot — correct, since persistent data belongs on vdb) |
| Image size | Full ext4 with free space (~4-6GB typical) | Compressed squashfs (~1-2GB estimated) |
| Runtime writes to vda | Possible (silent Category 1 violation) | Impossible (squashfs is read-only) |

**Why this is architecturally correct:**

The data taxonomy (section 11.2.1) classifies vda as Category 1: fully
derivable from Git, never backed up, rebuilt on demand. A writable ext4
doesn't enforce this classification — it merely documents it. SquashFS
makes the classification structural: the root image is physically
immutable, and any attempt to write to it fails immediately (or goes to
the tmpfs overlay, which is ephemeral by design). This is the embedded
systems principle of treating firmware as a read-only artifact with a
separate writable partition for runtime state — exactly the vda/vdb split
that the architecture already describes.

**Benefits:**

- **Smaller images:** SquashFS compression (zstd or lz4) typically achieves
  2-3x compression on NixOS closures. A 4GB ext4 image becomes ~1.5GB
  squashfs. This means faster image uploads to Proxmox nodes, less storage
  consumed on the data NVMe, and less ZFS replication bandwidth for vda.
- **Faster image creation:** `mksquashfs` is a single-pass tool that reads
  the nix closure and writes a compressed image. No QEMU VM boot, no
  `cptofs`, no ext4 formatting. This eliminates the "diskSize might be too
  small" class of build failures entirely.
- **Structural immutability:** The Category 1 property is enforced by the
  filesystem, not by convention. Rogue writes to vda are impossible.
- **Cleaner boot semantics:** The tmpfs overlay ensures that every reboot
  starts from a clean state. Runtime debris (`/var/log` growth, stale PID
  files, crashed service state) is automatically cleaned. Only vdb persists.

**The CI runner exception:**

The CI runner writes to `/nix/store` during builds — it's the only VM that
uses the nix store as a writable build cache. Options:
- Mount the runner's nix store as a separate writable filesystem on vdb
  (cache survives recreation but adds vdb complexity for a non-precious cache)
- Use a large tmpfs overlay (cache lost on reboot, equivalent to the current
  automatic GC behavior — the next pipeline after reboot has a cold cache)
- Exempt the runner from squashfs (keep ext4 for this one role)

The simplest approach is a large tmpfs overlay — the runner already has
automatic daily GC with 7-day retention, so losing the cache on reboot is
operationally equivalent to a GC run.

**Implementation approach:**

1. Replace `make-disk-image.nix` with a custom `make-squashfs-image.nix`
   that runs `mksquashfs` on the NixOS closure
2. Configure the NixOS initrd to mount the squashfs as the root filesystem
   with a tmpfs overlay (using `overlayfs` or `unionfs-fuse`)
3. Ensure vdb is mounted at its current paths (`/var/lib/vault`,
   `/var/lib/gitlab`, etc.) from the overlay init, so persistent data is
   unaffected
4. Update `upload-image.sh` if the file extension or Proxmox import
   procedure changes
5. Verify the boot sequence works with Proxmox's QEMU/KVM and cloud-init

**When to implement:** After Step 11 (Home Assistant migration) and the
scorched-earth test. The current ext4 images work correctly — this
improvement makes the Category 1 property structural rather than
conventional, reduces image sizes, and eliminates a class of build
failures. It is not blocking any current work.

---

## Appendix A: Decision Log with Motivations

### Infrastructure Foundation

| Decision | Alternatives Considered | Motivation |
|----------|------------------------|------------|
| Dedicated replication mesh with dummy0 + dual-metric routes + link watchdog | (A) Same-IP /32 host routes (Proxmox wiki), (B) FRR/OSPF dynamic routing, (C) Bridge with STP, (E) Management-only corosync | Corosync needs each node's ring address reachable by all peers — /30 point-to-point subnets alone don't satisfy this. Approach A (Proxmox wiki's same-IP method) is simpler but has no cable failover. Approach B (FRR) provides full dynamic routing but is overkill for 3 nodes. Approach C (bridge) creates broadcast storms without STP, and STP blocks a link. Approach E (management-only) works but switch failure kills quorum. The chosen design (D) uses a dummy0 /32 per node with dual-metric static routes — direct (low metric) and fallback via third node (high metric). A ping-based watchdog converts asymmetric link failures (one end down, other up) into symmetric ones that the routing handles correctly. |
| Dedicated replication network (mesh or switched, topology-aware) | Single management network for all traffic | Separation of concerns: dedicated links carry replication and corosync, Ethernet carries management and VM traffic. Mesh topology uses point-to-point DACs with dummy0/routed corosync and a link watchdog — cost-effective for 3–4 nodes. Switched topology uses dual A/B switches with standard Proxmox multi-link corosync — scales linearly for 5+ nodes. Both share a common health endpoint for monitoring. Config selects topology; scripts adapt automatically. |
| Blacklist Intel iRDMA kernel module | Leave irdma loaded (Proxmox default), install Intel out-of-tree irdma driver | The upstream irdma module shipped with Proxmox caused a production incident — it silently downed a replication interface with no logged event. No current workload uses RDMA. Blacklisting eliminates the failure surface. If RDMA is needed for future workloads (e.g., distributed inference with tensor parallelism), the out-of-tree Intel driver should be used instead, with lossless Ethernet configuration if using switches. |
| ZFS local storage with replication (over Ceph) | Ceph shared storage, NFS shared storage, iSCSI | At 3 nodes, Ceph quorum loss takes all storage offline — a catastrophic failure mode. ZFS local storage is resilient: losing a node only affects VMs on that node. The operational overhead of ZFS replication (orphan zvol cleanup, snippet deployment, placement drift) is absorbed by framework automation. At 5+ nodes, Ceph becomes attractive — the framework is designed for a future `storage.backend: ceph` abstraction (see section 20.6). |
| OpenTofu state on NAS PostgreSQL | Local file, Git-committed, Minio, inside cluster | Single service for state + locking, outside cluster for disaster recovery, native NAS package |
| OpenTofu (MPL 2.0) over Terraform (BSL) | Terraform (HashiCorp BSL), Pulumi | Open-source license with Linux Foundation governance — no single vendor can change terms. Drop-in compatible with Terraform HCL, providers, and modules. Native state encryption (defense in depth for sensitive state data). Community-driven feature prioritization. BSL does not restrict small-scale use, but open-source alignment and governance stability are architectural values. |
| Self-hosted GitLab CI/CD for IaC orchestration | Spacelift, Terraform Cloud, env0 | Spacelift is a managed IaC orchestration platform providing GitOps workflows, drift detection, OPA policy enforcement, approval workflows, and audit logging — purpose-built for running OpenTofu/Terraform at scale. It overlaps with what GitLab CI + SOPS + Vault + Gatus provide in this architecture. Rejected because: (1) SaaS dependency contradicts self-hosting goals (Spacelift offers self-hosted but adds significant complexity), (2) GitLab CI already provides merge request gates, scheduled jobs, and environment separation, (3) Gatus provides drift/health monitoring, (4) Vault provides secrets, (5) the overhead of a dedicated IaC platform is not justified for a single-operator cluster. Spacelift is well-suited for teams managing cloud infrastructure at scale with multiple operators and compliance requirements. |
| CI/CD inside cluster | On NAS, external cloud | Normal ops efficiency, disaster recovery via Mac + NAS state, no circular dependency |
| GitLab (self-hosted) | Gitea+Woodpecker, Forgejo, GitHub Actions self-hosted | Single system for Git hosting + CI/CD, mature pipeline features (merge request gates, environments, scheduled jobs), widely known, NixOS module available. Self-hosted eliminates external dependency. |
| Single `domain:` field, all values derived | Explicit `dns_domain`, `gitlab_url`, `email.from` fields per environment | DNS zone names (`prod.<domain>`, `dev.<domain>`), GitLab URL, Gatus alert sender, and all FQDNs are derived from the single `domain:` field in config.yaml. Eliminates a class of inconsistency bugs (e.g., changing the domain but forgetting to update `dns_domain` in one environment). The framework contains zero hardcoded domain references — changing `domain:` and redeploying migrates everything. The only kept non-derived field is `email.to` (operator's personal address, not domain-dependent). |

### DNS and Certificates

| Decision | Alternatives Considered | Motivation |
|----------|------------------------|------------|
| PowerDNS over BIND | BIND (traditional) | HTTP API simpler than TSIG, better ACME integration, declarative via NixOS |
| SQLite backend for PowerDNS | PostgreSQL | Zone data is Category 2 (from Git). Database is a disposable cache, not a source of truth. SQLite eliminates external database dependency, replication complexity, and circular dependencies. |
| Redundant DNS per environment (dns1, dns2) | Single DNS | DNS failure is catastrophic, cost is trivial (~256MB RAM per VM), enables zero-downtime maintenance |
| Parallel DNS stacks (prod and dev) | Shared DNS serving both environments | Enables testing DNS configuration changes in dev before prod. Uniform rule (each environment has its own stack) is simpler than per-service sharing decisions. Resource cost is negligible. |
| certbot writes to both DNS servers | Zone transfers, single-server writes | Simple, explicit, no zone transfer complexity. Both servers see ACME challenges regardless of which is queried by the ACME validator. |
| Zone data via CIDATA (boot-time reconciliation) | Post-deploy script (`zone-deploy.sh`) pushing via API | CIDATA delivery makes DNS VMs self-configuring: they load their zone data at first boot with no external push step. This is critical for HA — when Proxmox migrates a DNS VM to a surviving node, it boots with zone data already in its CIDATA snippet. A post-deploy script would require the operator (or CI/CD) to re-push zones after every failover. Eliminates an operational step from the pipeline and the rebuild sequence. |
| step-ca private ACME server in dev | No ACME testing in dev, Let's Encrypt staging | Dev DNS is internal-only (single public IP, port 53 forwards to prod only). LE staging is a viable alternative (generous rate limits, same validation as prod) but requires publicly delegating dev DNS — adding an external dependency for dev cert issuance. A local ACME server keeps dev fully self-contained: no internet required, no registrar configuration, no failure coupling between dev and prod. step-ca was chosen over Pebble because Pebble's ephemeral CA (regenerated on every boot, by design) made it impossible for services to verify certificates issued by Pebble without environment-specific runtime workarounds. step-ca's static root CA is delivered via CIDATA and added to the system trust store at boot, making dev and prod TLS verification identical. See section 8.4 for the full design and section 8.6 for the TLS trust architecture. |
| step-ca queries authoritative (port 8053), not recursor (port 53) | Query recursor like other clients, flush recursor cache in certbot auth hook, reduce negative TTL | The recursor caches NXDOMAIN responses (300s). certbot's auth hook creates TXT records on the authoritative via API, but the recursor doesn't see them until the cache expires. Since certbot retries every 10s (< 300s TTL), the recursor never serves fresh data — creating a permanent failure loop. Querying the authoritative directly is the cleanest fix: the dev ACME server's sole purpose is to verify challenge records actually exist in the zone, so caching defeats the purpose. Prod is unaffected (LE validators query through WAN port forward → port 8053 directly). |
| PowerDNS API key stays in SOPS | Migrate to Vault at runtime | Bootstrap-tier secret: needed to obtain certificates, which are needed to authenticate to Vault. Migrating to Vault creates a circular dependency. |
| Let's Encrypt (public CA) | Private CA (step-ca) | Guest device compatibility (no CA install), full automation, not a learning goal, simplicity |
| Individual certs per service | Wildcard certificate | Security isolation, selective revocation, aligns with rebuildability |

### Secrets Management

| Decision | Alternatives Considered | Motivation |
|----------|------------------------|------------|
| Hybrid SOPS + Vault | SOPS only, Vault only | SOPS for disaster recovery, Vault for dynamic secrets, clear separation |
| Vault inside cluster | On NAS | SOPS handles bootstrap, cleaner separation of concerns |
| Single Vault instance per environment | 3-instance Raft cluster | Vault is queried periodically (not in hot path like DNS). vault-agent caching means running VMs tolerate brief outages. Measured HA restart: ~15s for VM crash (same node), <2 min for node failure. Multi-instance requires 3 nodes minimum (Raft quorum), adding significant complexity for marginal benefit at this cluster scale. Proxmox HA provides sufficient availability. |
| Vault Raft storage | PostgreSQL backend | Designed for Vault, no external dependency, supports future multi-instance if ever needed |
| Auto-unseal with SOPS | Manual unseal, cloud KMS | Full automation, disaster recovery preserved, no external dependency |
| TLS cert auth to Vault | AppRole (Role ID + Secret ID) | Reuses existing identity, reduces key proliferation, simpler bootstrap |

### VM Images and Storage

| Decision | Alternatives Considered | Motivation |
|----------|------------------------|------------|
| Offline image build | Template clone, build from scratch on-target | Leverages embedded systems expertise, fastest deployment, purest rebuildability, CI/CD friendly |
| Separate data volume | Monolithic, overlay filesystem, shared /nix/store | Rebuildability (code vs data separation), backup efficiency, works with NixOS design |
| ZFS local storage with replication | Ceph HCI, LINSTOR/DRBD, NFS/iSCSI | Resilient at 3 nodes (no quorum-dependent storage), operationally simple, storage is boring. Ceph requires 5+ nodes for comfort; ZFS replication is purpose-built for small clusters. Unplanned failover time is identical (~45-90s) for both ZFS and Ceph. |
| Raw zvols for VM disks | qcow2 on ZFS | Avoids double copy-on-write (qcow2 CoW + ZFS CoW causes write amplification and poor performance) |
| Uniform replication (all VMs, both nodes, 1-min) | Per-VM differentiation | Simplicity over optimization. Resources are not tight. One rule, no exceptions. If capacity becomes tight, add capacity rather than add complexity. |
| Three-category data taxonomy | Backup everything / backup nothing | Derivable (vda, from Git), configuration (vdb subset, from Git), precious state (vdb subset, needs PBS). Determines PBS scope without affecting replication/HA (which is uniform). |
| PBS with NFS datastore on NAS | Raw ZFS exports, application-level only | Versioned deduplicated backups, point-in-time recovery, PBS datastore on NAS for off-cluster durability, clean split of concerns |
| HA priority for Home Assistant | Uniform HA priority | Home Assistant is the only Tier-0 VM with no app-level redundancy. Restarts first after node failure. |
| Anti-affinity for redundant pairs | Allow any placement | Redundant service pairs (dns1/dns2) must run on different nodes. Otherwise a single node failure eliminates all redundancy. Enforced via Proxmox native HA anti-affinity rules. |
| N+1 capacity rule (max 2 nodes' worth of load) | Use full cluster capacity | Ensures any single node failure can be absorbed without overcommitting. Each node runs ~2/3 capacity during normal operations. Determines when a fourth node is needed. |
| Filtered nix source (`nixSrc`) for image builds | Use full flake source (`self`) | Without filtering, every tracked file in the repo is a nix derivation input. Changing `.gitlab-ci.yml` or `CLAUDE.md` changes every image hash, recreating every VM on every pipeline run. The `builtins.path` filter creates a store path containing only image-relevant files. Missing filter entries cause hard build failures (fail-closed). A static lint and nix canary test verify filter integrity in the pipeline. See section 11.1.2. |
| `post-deploy.sh` for pipeline recovery | Manual post-deploy checklist, separate pipeline steps | Consolidates replication cleanup, vault init/unseal/configure, and backup job configuration into one script called after every pipeline deploy. Handles three vault states (uninitialized, sealed, healthy) so partial failures recover on the next pipeline run. Eliminates the class of pipeline failures where deploy succeeds but post-deploy steps are forgotten. |
| SquashFS immutable root (planned) | Writable ext4 image (current) | vda is Category 1 (disposable, derivable from Git) but a writable ext4 doesn't enforce this — writes to vda silently persist until VM recreation, then vanish. SquashFS makes the immutability structural: compressed read-only root, tmpfs overlay for ephemeral runtime state. Smaller images (~2-3x compression), faster builds (no QEMU boot for `cptofs`), impossible to accidentally persist state on vda. Same embedded systems principle as firmware with a separate writable data partition. See section 20.7. |

### Tailscale Integration

| Decision | Alternatives Considered | Motivation |
|----------|------------------------|------------|
| Tailscale auth key stored in Vault, delivered by vault-agent | SOPS + CIDATA delivery, interactive browser approval | Vault is the correct store for runtime secrets. CIDATA would make key rotation require VM recreation (CIDATA change triggers replacement). Browser approval breaks the automated rebuild path. Vault delivery means the auth key is never in Git, has per-role access policies, and audit logging. |
| Tailscale connects after Vault is reachable, not during boot | Connect during early boot via CIDATA-delivered key | No operational need for Tailscale in the first 30–60 seconds of boot. Connecting after Vault is reachable means the auth key is a proper runtime secret, not a bootstrap secret. The chain is: CIDATA → DNS → ACME → Vault auth → Tailscale join. |
| Node identity stored in Vault (Category 4) | Ephemeral identity (re-join on every rebuild), PBS backup of /var/lib/tailscale | Ephemeral identity requires cleaning up stale entries in Tailscale admin after every rebuild and re-applying any per-machine ACL rules. PBS backup of node identity exposes the private node key in unencrypted backup storage. Vault provides the correct store: per-VM access policies, audit logging, survives VM recreation, never in backups. |
| Single reusable auth key shared across all Tailscale-enabled VMs | Per-VM auth keys | Per-VM keys require N secrets in Vault, per-VM key generation in configure-vault.sh, and key rotation touches every VM. A single reusable key is operationally simpler. Individual VMs are controlled by Vault access policies (only authorized roles can retrieve the key) and by Tailscale node identity (each VM has a distinct identity). If the key is compromised, rotate one secret in Vault and rebuild affected VMs. |
| Machine name `<vmrole>-<domain-with-dashes>` | Role name alone, random ID, IP-based | Role name alone collides across multiple clusters on the same tailnet. Random ID loses the human-readable VM identification. Domain-qualified name is unique across clusters (domain is cluster-unique by construction — two clusters on the same domain would have DNS conflicts) and human-readable in the Tailscale admin console. |
| Auto-derived tags (tag:mycofu, tag:mycofu-prod/dev, tag:mycofu-ctl) with optional extra tags | Manual tag configuration per VM | Tag-based ACLs survive identity changes (new machine, same tags → same access rules). Auto-derivation means adding a new VM to the tailnet requires no Tailscale admin console changes. Environment tags enable prod/dev ACL differentiation. Control-plane tag enables tighter access control for GitLab, PBS, and cicd. |
| Per-VM opt-in requires two edits (YAML flag + nix import) | base.nix inclusion (all VMs) | Tailscale free tier limits devices to 100. With dev+prod environments and a growing VM count, including Tailscale in every image would consume the device budget quickly. Per-VM opt-in keeps only intentionally accessible VMs on the tailnet. The two-file edit is intentional: the YAML flag controls Vault policy and tofu behavior; the nix import enables the NixOS service. Both are required and serve different purposes. |
| AppRole auth method for vault-agent | Cert auth (TLS certificate) | Vault cert auth is incompatible with ACME-issued certificates (empty CN field — Vault rejects with "missing name in alias"). This is an upstream Vault limitation tracked in multiple open issues. AppRole with CIDATA-delivered role_id and secret_id is the available fallback: credentials are bootstrap-tier secrets (stable, not frequently rotated), delivered via the existing nocloud-init write_files path. |

### Application Deployment

| Decision | Alternatives Considered | Motivation |
|----------|------------------------|------------|
| Hybrid (Nix + Compose) | Nix-native only, Compose only | Fast initial deployment, pragmatic, migration path, learn by doing |
| Pinned image digests | Latest tags, Nix-built images | No surprise updates, reproducibility, audit trail |
| DNS-based service discovery with unqualified hostnames | FQDNs only, Consul | Unqualified hostnames + CIDATA-provided search domain preserves environment ignorance. VMs never contain environment-specific FQDNs. |

### Home Assistant

| Decision | Alternatives Considered | Motivation |
|----------|------------------------|------------|
| HAOS (official image) | HA Core on NixOS, HA Container on NixOS | HAOS is the officially supported, most broadly validated deployment. Deviations from design goals (no Nix pipeline, Supervisor as second control plane) are accepted and mitigated by monorepo config management. Core on NixOS may be evaluated later on dev VLAN. |
| Monorepo with rsync deploy/capture | Separate HA Git repo, Git subtree, Git on HAOS VM | Monorepo gives unified review and atomic commits. rsync avoids Git on the HAOS VM (no credentials, no dirty state, no working directory conflicts with HAOS runtime writes). Capture runs from Mac for better tooling. |
| No Git on HAOS VM | Git clone on HAOS VM | Eliminates Git credentials on HAOS, avoids dirty working directory from runtime state, all Git operations happen on Mac with full tooling. |
| `secrets.yaml` via SOPS | Manual copy, Vault | Brings HAOS secrets into existing SOPS model. HAOS doesn't have vault-agent, so Vault integration is impractical. SOPS decrypt during deploy is simple and auditable. |

### Application Configuration

| Decision | Alternatives Considered | Motivation |
|----------|------------------------|------------|
| Application VM specs in `site/applications.yaml`, separate from `site/config.yaml` | Single `config.yaml` for all VM types | Framework VMs and application VMs have different ownership, lifecycle, and editors. Mixing them in one file forces the operator to navigate framework configuration when adding an application. A separate file makes each file's scope self-evident and keeps the application VM specification contiguous. |
| `enable-app.sh` and `new-site.sh` are helpers, not gatekeepers | Generators as required setup steps | The framework reads files; it does not care how those files were produced. An operator who writes `applications.yaml` by hand without running `enable-app.sh` gets a fully working cluster. Generators exist to save the operator from knowing every field and derivation rule on day one. They are not in the framework's execution path. Making them required would mean a generator bug could block all deployments. |
| Re-running a generator must never overwrite operator edits | Generator re-runs update or replace generated content | Operator edits in generated files represent intent. A generator that silently overwrites them is a data-loss bug. Generators write to new entries only; existing content is never touched. This is a hard invariant enforced by the idempotency check (exit if entry already exists). |
| `enable-app.sh` writes complete blocks to `applications.yaml` without interactive prompting | Interactive wizard collecting values one at a time | The file is the interface. An operator who edits the generated block directly sees the full context — constraints, ranges, adjacent values. A wizard presents values one at a time with no context. The generated block is reviewable, auditable, and editable; a wizard's output is opaque until you open the file afterward. |
| Inline comments at point of action (adjacent to the value they constrain) | Header comment summarizing constraints, separate documentation | An operator editing a specific value reads the comment immediately above that line. They do not scroll back to a file header. Constraints and verification commands belong where the operator's cursor is. |
| Generator writes comments once; operator maintains them thereafter | Generator refreshes comments on re-run | Re-running a generator over operator-authored content creates a boundary problem: which content does the generator own, which does the operator own? Writing once is simpler and puts the operator fully in control of the file after generation. The staleness risk (subnet changes invalidating range comments) is real but rare and addressed by a reminder note in `config.yaml`. |
| `validate-site-config.sh` called by all consumers before side effects | Per-consumer validation, or no validation | Config errors (duplicate VMIDs, IPs out of range, missing node references) are best caught once in one place, before any consumer acts on them. Per-consumer validation duplicates logic and risks inconsistency. Calling a shared validator as the first step of every consumer is the correct pattern: the caller fails fast with a clear error, and the validation logic has one place to improve. |


### Validation


### Monitoring

| Decision | Alternatives Considered | Motivation |
|----------|------------------------|------------|
| Gatus for health monitoring | Prometheus + Alertmanager, Uptime Kuma | Config-file-driven (YAML in Git), lightweight Go binary, sufficient for health checking at this scale. Prometheus deferred — can be added later if metrics trending is needed. |
| Two-tier monitoring (cluster + NAS) | Single monitor on cluster, external SaaS | Cluster monitor can't detect its own failure. Sentinel on NAS (independent hardware, independent network) closes the gap. No external SaaS dependency. |
| Gatus for sentinel (not Uptime Kuma) | Uptime Kuma on NAS | Same tool for both tiers — one system to learn, one config format. Gatus runs in Docker on NAS. |

---

## Appendix B: Programs and Components to Build

### Infrastructure Tools
1. **OpenTofu modules** - Proxmox provider, VM creation, disk management, networking
2. **NixOS base configuration** - Common settings for all VMs
3. **NixOS role modules** - DNS, Vault, application-specific roles

### VM Image Building
4. **VM image build system** - Nix expressions to generate bootable VM images
5. **CI pipeline for image builds** - Automated building, versioning, uploading
6. **Image registry management** - Storage and organization of VM images in Proxmox

### DNS
7. **PowerDNS configuration** - Zones, API, SQLite backend
8. **DNS zone data** - Derived from config.yaml, delivered via CIDATA, reconciled at boot

### Certificates
9. **certbot integration** - NixOS module for ACME certificates, per-VM, writes to both environment DNS servers
10. **PowerDNS API plugin** - DNS-01 challenge automation
11. **Certificate monitoring** - Expiration alerts, renewal failure alerts
12. **step-ca (acme-dev)** - Dev-only VM for end-to-end ACME validation testing

### Secrets
13. **SOPS configuration** - `.sops.yaml`, encrypted infrastructure secrets
14. **Vault bootstrap script** - Initialize, unseal, load policies
15. **Vault policy sync** - Git → Vault policy application
16. **Vault agent configuration** - NixOS module for secret retrieval

### Validation
17. **Bootstrap validation script** - All health checks, DNS, certs, Vault
18. **CI integration** - Run validation on PR, block merge on failure
19. **Destructive drill scripts** - VM rebuild, DNS failover, node failure tests
19a. **Source filter integrity** - Static lint (`check-source-filter.sh`) and nix canary test (`source-filter-check.nix`) verify that `nixSrc` filter is not bypassed

### Operations
20. **PBS VM configuration** - Proxmox Backup Server VM, NFS datastore on NAS, retention policies
21. **Backup jobs** - PBS scheduled backups for vdb volumes, Vault Raft snapshots
21a. **Post-deploy recovery** - `post-deploy.sh` consolidates replication cleanup, vault init/unseal/configure, and backup job configuration into a single pipeline-callable script
22. **Gatus primary (on cluster)** - NixOS VM with Gatus config from Git, health checks for all infrastructure and application services, email + HA webhook alerting
23. **Gatus sentinel (on NAS)** - Docker container on NAS, monitors primary Gatus and critical cluster endpoints, email alerting via NAS mail relay
24. **Update procedures** - Rolling Proxmox updates, VM image updates
25. **ZFS maintenance** - Weekly scrubs, SMART monitoring, replication health checks
26. **Capacity management** - N+1 capacity rule enforcement, allocation tracking, alerting when approaching 2-node limit
27. **VM placement and rebalancing** - Evaluate ProxLB or similar for load-aware placement, post-failover rebalancing, pre-maintenance node evacuation

### Home Assistant
28. **ha-deploy script** - rsync from monorepo `home-assistant/config/` to HAOS `/config/`, with exclusion filter, SOPS decrypt for `secrets.yaml`, optional HA config reload via REST API
29. **ha-capture script** - rsync from HAOS `/config/` to monorepo, with exclusion filter, runs `git diff --stat` after capture
30. **rsync-filter.conf** - Shared exclusion list defining the boundary between authored config (Cat 2) and runtime state (Cat 3), version-controlled in monorepo
31. **Migration runbook** - Step-by-step procedure for initial migration from standalone HA to Proxmox HAOS VM (backup, restore, network, USB passthrough, verification)

---

## Appendix C: Documentation Structure

### README.md (Operational Guide)
- Quick start instructions
- Day-to-day operations
- Common tasks (add VM, update service, restart, etc.)
- Emergency procedures
- Regular maintenance tasks:
  - Monitor certificate renewals
  - Check backup status
  - Review logs
  - Update VM images

### ARCHITECTURE.md (This Document)
- Design goals and motivations
- Layer-by-layer architecture
- Decision log with rationales
- Bootstrap sequence detailed
- For architects/engineers evaluating or extending

### BOOTSTRAP.md (Runbook)
- Step-by-step first deployment
- Pre-requisite checklist
- Disaster recovery procedure
- Validation steps
- Troubleshooting common issues

### DEVELOPMENT.md
- How to contribute
- Testing strategy
- CI/CD pipeline details
- Release process (dev → main)
- Coding standards (Nix, OpenTofu)

---

## Appendix D: Workflows

### Standard Deployment Workflow

```
Developer → Git commit → Feature branch
                      ↓
                   Create PR → dev
                      ↓
                 CI validation
              (build images, tofu plan)
                      ↓
                   Merge to dev
                      ↓
           CI builds VM images (if config changed)
                      ↓
           CI uploads images to Proxmox
                      ↓
         CI runs tofu apply (dev env)
                      ↓
              Test in dev environment
                      ↓
                  Create PR → main
                      ↓
              Review, approval
                      ↓
                  Merge to main
                      ↓
         CI runs tofu apply (prod env)
                      ↓
             Production deployment
```

### VM Rebuild Workflow

```
Issue detected → Decision to rebuild
                      ↓
              tofu destroy <vm>
                      ↓
            Data disk (vdb) preserved
                      ↓
              tofu apply
                      ↓
          New VM from image (vda)
                      ↓
         Attach existing data disk (vdb)
                      ↓
                  Boot VM
                      ↓
         certbot gets certificate
                      ↓
        Vault auth via TLS cert
                      ↓
           Retrieve secrets
                      ↓
         Mount data disk, start services
                      ↓
          VM operational with preserved data
```

### Certificate Renewal Workflow

```
Daily systemd timer → certbot runs
                      ↓
              Check cert expiration
                      ↓
           < 30 days remaining?
                      ↓
                    Yes
                      ↓
           Request renewal from Let's Encrypt
                      ↓
        Create TXT record via PowerDNS API
                      ↓
       Let's Encrypt validates DNS-01 challenge
                      ↓
           Let's Encrypt issues certificate
                      ↓
              Install new certificate
                      ↓
           Reload services (nginx, etc.)
                      ↓
          Delete challenge TXT record
                      ↓
                    Done
```

---

## Appendix E: Interface Contracts

These contracts define the concrete interfaces between system components. They are the agreements that must be maintained for the architecture to function correctly. Changes to any contract require review across both sides of the interface.

### Contract 1: OpenTofu → Proxmox (VM Creation)

**OpenTofu creates each VM with (using `bpg/proxmox` provider):**
```
resource "proxmox_virtual_environment_vm" "<role>-<env>" {
  name        = "<role>-<env>"           # e.g., "dns1-prod"
  node_name   = "<node>"                 # Placement (respects anti-affinity)

  # cloud-init via snippets (cicustom) — NOT built-in fields.
  # Snippets support write_files for SOPS secret injection.
  # IMPORTANT: Snippets must be deployed to ALL nodes for HA to work.
  # Create proxmox_virtual_environment_file resources for each node,
  # not just the node where the VM is created (see section 11.4).
  initialization {
    type                = "nocloud"
    user_data_file_id   = "<local:snippets/...>"  # hostname, SSH keys, write_files
    meta_data_file_id   = "<local:snippets/...>"  # instance-id
  }
  
  # Network: primary NIC on environment VLAN
  network_device {
    bridge      = "vmbr0"
    vlan_id     = <vlan_id>              # From config.yaml environments
    mac_address = "<pre-assigned MAC>"   # From config.yaml vms, for static IP identity
  }
  
  # Optional: management NIC on vmbr1 (for VMs with mgmt_nic in config.yaml)
  # network_device {
  #   bridge      = "vmbr1"             # Management bridge (not vmbr0 — see section 7.1)
  #   mac_address = "<mgmt_nic.mac>"    # From config.yaml vms.<vm>.mgmt_nic.mac
  # }
  
  # Disks — pool name from config.yaml → proxmox.storage_pool
  disk {                                 # vda: OS (imported from image)
    interface    = "scsi0"
    datastore_id = "<storage_pool>"      # e.g., "vmstore"
    file_id      = "<local:iso/image>"   # .img file on Proxmox ISO storage
  }
  disk {                                 # vdb: data (blank, created by OpenTofu)
    interface    = "scsi1"
    datastore_id = "<storage_pool>"
    size         = <size_gb>
  }
  
  # HA configuration
  # Managed via separate proxmox_virtual_environment_haresource
}
```

**Anti-affinity enforcement:** Proxmox native HA resource affinity rules (not OpenTofu logic). OpenTofu creates the HA rules; Proxmox enforces them during failover.

**OpenTofu does NOT:**
- Write to any file inside the VM after creation
- Configure services, secrets, or certificates
- Set environment-specific addresses or FQDNs

### Contract 2: VM Boot → Environment Discovery (CIDATA)

**Precondition:** VM is attached to a VLAN (10 or 20) via OpenTofu.

**CIDATA provides (via `write_files` at `/run/secrets/network/`):** primary
MAC, IP, gateway, DNS server IPs, search domain. A `configure-static-network`
systemd service reads these values at boot and writes a systemd-networkd
`.network` file matching the primary NIC by MAC address. `systemd-resolved`
bridges the DNS and search domain settings to resolv.conf.

**The search domain is the single mechanism that binds a VM to its environment.** All environment-specific behavior derives from DNS resolution of unqualified hostnames.

| Unqualified hostname | Prod resolution | Dev resolution |
|---------------------|----------------|----------------|
| `vault` | vault.prod.example.com → 10.0.10.x | vault.dev.example.com → 10.0.20.x |
| `acme` | acme.prod.example.com → (Let's Encrypt endpoint) | acme.dev.example.com → 10.0.20.x (step-ca) |
| `dns1` | dns1.prod.example.com → 10.0.10.x | dns1.dev.example.com → 10.0.20.x |
| `dns2` | dns2.prod.example.com → 10.0.10.x | dns2.dev.example.com → 10.0.20.x |

**Note on `acme` in prod:** The DNS A record for `acme.prod.example.com` does not point to a local server. Instead, the certbot configuration uses `acme` as a short alias that is resolved and then used as the ACME directory URL. The exact mechanism (DNS A record pointing to Let's Encrypt's IP, or a certbot config that maps the hostname to a URL) is an implementation detail to be resolved during buildout.

### Contract 3: certbot → PowerDNS (ACME DNS-01)

**Authentication:** PowerDNS API key from SOPS (available at `/run/secrets/certbot/pdns-api-key` on the VM).

**API calls (for each DNS server in the environment):**

```
# Create challenge TXT record
POST https://dns1:8081/api/v1/servers/localhost/zones/{zone}
Authorization: X-API-Key: <pdns-api-key>
Content-Type: application/json
{
  "rrsets": [{
    "name": "_acme-challenge.{hostname}.{zone}.",
    "type": "TXT",
    "ttl": 60,
    "changetype": "REPLACE",
    "records": [{ "content": "\"{challenge-token}\"", "disabled": false }]
  }]
}

# Delete challenge TXT record (after validation)
PATCH https://dns1:8081/api/v1/servers/localhost/zones/{zone}
# Same structure with "changetype": "DELETE"
```

**certbot writes to BOTH dns1 and dns2** in the environment (two API calls per challenge). This ensures the ACME validator sees the challenge regardless of which DNS server it queries.

**Failure modes:**
- DNS server unreachable: certbot retries (configurable). If both DNS servers are down, cert issuance fails. Existing certs remain valid until expiration (90 days).
- API key invalid: all cert issuance/renewal fails. Requires SOPS key rotation (see bootstrap secret rotation).
- Rate limiting (Let's Encrypt, prod only): 50 certificates per registered domain per week. Not a concern at small cluster scale.

### Contract 4: Vault TLS Certificate Authentication

**Status: Designed but not yet active.** Vault cert auth is incompatible with
ACME-issued certificates (empty CN field — see section 9.3). The contract below
describes the intended behavior once the limitation is resolved. Currently, no
VMs authenticate to Vault at runtime.

**Vault auth method:** `cert` (TLS certificate authentication)

**What Vault checks when a VM authenticates:**
- Certificate is signed by a trusted CA (Let's Encrypt in prod, step-ca root in dev)
- Certificate Common Name (CN) matches an allowed pattern for the requested role
- Certificate is not expired

**Role mapping (CN → Vault policy):**

| Certificate CN pattern | Vault role | Policy grants access to |
|----------------------|------------|------------------------|
| `dns1.*.example.com` | `dns` | DNS-related secrets only |
| `dns2.*.example.com` | `dns` | DNS-related secrets only |
| `vault.*.example.com` | `vault-self` | Vault internal secrets |
| `*.*.example.com` (fallback) | `default` | Read-only, minimal secrets |

**Certificate renewal behavior:**
- vault-agent manages the Vault token lifecycle independently of the TLS certificate lifecycle
- When certbot renews the TLS certificate, vault-agent detects the new cert and re-authenticates to Vault automatically
- No service restart required — vault-agent watches the certificate file path
- Token TTL is set shorter than certificate lifetime (e.g., 24h token TTL vs 90-day cert), so token rotation happens frequently regardless of cert renewal

**What Vault does NOT check:**
- Source IP address (VMs may move between nodes during failover, changing IPs)
- The specific ACME server that issued the cert (prod and dev Vault instances trust different CAs)

---

### Contract 5: NixOS Systemd Service Ordering — Requires vs After vs Wants

This contract documents the systemd dependency semantics that must be
used correctly in NixOS service definitions. Incorrect use has caused
multiple production failures in this system where services that were
expected to be blocked by a failed dependency started anyway.

**The three dependency directives have fundamentally different semantics:**

| Directive | What it does | Does it block if dependency fails? |
|-----------|-------------|-----------------------------------|
| `after = ["X"]` | Ordering only — start after X has started | **No.** The service starts regardless of whether X succeeded or failed. |
| `wants = ["X"]` | Soft dependency — try to start X first | **No.** The service starts even if X failed. |
| `requires = ["X"]` | Hard dependency — start X, and if X fails, this service fails too | **Yes.** If X is inactive or failed, this service will not start. |

**The rule:** If a service must not start when a dependency has failed,
use `requires =`. Using `after =` or `wants =` for safety-critical
ordering is wrong and will silently fail to provide the guarantee.

**Why this is commonly misunderstood:** NixOS module documentation and
examples frequently use `after =` for what looks like "wait for X to be
ready" ordering. In many cases this works in practice because the
dependency succeeds. But when the dependency fails — which is exactly
when you need the ordering to matter — `after =` provides no protection.

**Historical vdb gate note:**

Earlier versions used a guest-side vdb readiness target to block services
after boot until vdb appeared populated. Sprint 031 removes that mechanism.
The current contract is simpler: vdb population happens before start in the
orchestration layer. Do not add service dependencies whose purpose is to
probe vdb from inside the guest.

---

### Contract 6: vdb Population Before Start

This contract defines how VMs with precious state (Category 3) receive
restored vdb content before application services can start.

**Problem:** If a recreated VM starts before vdb restore, application
services may initialize empty state or write stale bootstrap data. That
state can then be captured by PBS and obscure the known-good backup.

**Mechanism:**

1. The deploy path takes a pre-deploy backup and records restore pins.
2. The manifest is derived from the default OpenTofu plan.
3. Phase 1 applies with `start_vms=false` and `register_ha=false`.
4. `restore-before-start.sh` restores vdb with `restore-from-pbs.sh
   --leave-stopped`, or records explicit first-deploy empty approval.
5. Phase 2 applies with `start_vms=true` and `register_ha=true`.

If restore fails for any VMID in the manifest, the batch aborts and Phase
2 does not run. Successfully restored VMs remain stopped until the operator
reruns the deploy or takes an explicit recovery action.

**Adding a new precious-state application:**

1. Set `backup: true` and stable VMID/environment metadata in
   `site/applications.yaml` or `site/config.yaml`.
2. Ensure the app module creates a vdb disk and mounts it at the service's
   data path.
3. Verify `restore-before-start.sh` manifest derivation includes the VMID
   during creates/replaces.

Do not add guest-side vdb probes, CIDATA restore flags, or service gates.

---

## Appendix F: Site Configuration Reference

This appendix lists every value that is site-specific and must be provided by the operator when deploying this architecture. These values belong in `site/config.yaml` (or equivalent site configuration files) and never appear in the framework.

### Required Site Values

| Category | Value | Example | Where Used |
|----------|-------|---------|------------|
| Domain | Base domain | `example.com` | DNS zones, certificate CNs, CIDATA search domains. All other domain values are derived from this single field (see section 20.4). |
| Domain | Domain registrar | (varies) | NS record configuration |
| Network | Prod VLAN ID | `10` | Gateway, OpenTofu VM creation |
| Network | Dev VLAN ID | `20` | Gateway, OpenTofu VM creation |
| Network | Prod subnet | `10.0.10.0/24` | CIDATA static addressing, DNS zones, firewall rules |
| Network | Dev subnet | `10.0.20.0/24` | CIDATA static addressing, DNS zones, firewall rules |
| Network | Prod gateway IP | `10.0.10.1` | CIDATA default route, PowerDNS recursor |
| Network | Dev gateway IP | `10.0.20.1` | CIDATA default route, PowerDNS recursor |
| Nodes | Node hostnames | `node1`, `node2`, `node3` | Proxmox cluster, OpenTofu |
| Nodes | Node management IPs | (site-specific) | OpenTofu provider, break-glass access |
| Nodes | Number of nodes | `3` | N+1 capacity calculation, replication targets |
| NAS | NAS hostname/IP | (site-specific) | OpenTofu state, PBS datastore, sentinel monitoring |
| DNS | DNS server IPs | (site-specific) | CIDATA nameserver config, zone data derivation, Gatus checks |
| DNS | Vault server IPs | (site-specific) | Zone data derivation |
| DNS | Public IP for DNS | (site-specific) | Registrar NS delegation glue records, firewall port 53 forwarding |
| Email | SMTP relay | (site-specific) | Gatus alerting, sentinel alerting |
| Email | Alert recipient | (site-specific) | Gatus config |
| SSH | Operator SSH public key(s) | (site-specific) | cloud-init, SOPS. Supports multiple keys (newline-separated in SOPS `ssh_pubkey`): operator key + CI runner key. All keys are deployed to all VMs via CIDATA. |
| Secrets | Operator age public key | (site-specific) | SOPS encryption |

**Auto-generated by `new-site.sh`** (operator may adjust but does not need to provide):

| Category | Value | Generation scheme | Where Used |
|----------|-------|-------------------|------------|
| VMs | VMID | Hundreds digit encodes category: 1xx shared (gitlab=150, cicd=160, pbs=190); odd=dev, even=prod: 3xx/4xx infra, 5xx/6xx apps; 7xx vendor appliance apps. Same role = same offset across dev/prod (e.g., dns1=01 → 301/401). | Proxmox VM ID, PBS backup index, ZFS zvol names. Stable across rebuilds. |
| VMs | IP | Fixed offset within subnet (.50, .51, .52, ...) | CIDATA static addressing, DNS zone data, Gatus checks |
| VMs | MAC | Random locally-administered (`02:xx`) | CIDATA interface matching, OpenTofu VM creation |

### Optional Site Values

| Category | Value | Default | Notes |
|----------|-------|---------|-------|
| ACME | `acme` mode | `production` | `production`, `staging`, or `internal`. Controls which ACME server prod VMs use for certificates. See section 8.5. |
| Locale | `timezone` | `UTC` | IANA timezone (e.g., `America/Los_Angeles`). Used by PBS answer file, NixOS VMs, Gatus, log timestamps. Set to match Proxmox node timezone. |
| Network | `ntp_server` | Management gateway IP | NTP server for all nodes and VMs. Defaults to the management gateway (most routers provide NTP). Override if using a dedicated NTP appliance or pool. |
| Network | Replication network config | (none) | Only if dedicated replication network is used |
| HA | Home Assistant USB devices | (none) | For USB passthrough (Zigbee, Z-Wave, etc.) |
| Backup | PBS retention policy | 7 daily, 4 weekly | Adjust based on storage capacity |
| Monitoring | Additional Gatus endpoints | (none) | Site-specific application health checks |

### What Is NOT Site-Specific

The following are architectural decisions, not site configuration. They are the same for every deployment:

- Data taxonomy (Category 1/2/3)
- Chain of trust sequence (CIDATA → DNS → ACME → Vault → secrets)
- vda/vdb disk separation
- NixOS module structure
- OpenTofu module interfaces
- Secret management architecture (SOPS for bootstrap, Vault for runtime)
- Environment binding mechanism (VLAN + CIDATA search domain → unqualified hostnames)
- Monitoring architecture (primary + sentinel)
- Backup architecture (ZFS replication + PBS + off-cluster NAS)

---

*End of Architecture Plan*
