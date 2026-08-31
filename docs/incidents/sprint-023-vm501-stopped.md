# Report: influxdb-dev (VM 501) Stuck in HA Stopped State

## Summary

After Sprint 023 code was merged and deployed to dev, the influxdb-dev
VM ended up in Proxmox HA state "stopped". Subsequent pipeline runs
cannot proceed because the pre-deploy backup preflight refuses to back
up an unhealthy VM, and the deploy stage (which would recreate the VM
with a healthy image) never runs.

## What Was Observed

### Current state

- VM 501 exists on pve02, status: stopped, HA state: stopped
- VM conf, CIDATA snippets, and zvols are all present and valid
- CIDATA contains AppRole credentials (role-id and secret-id)
- Tofu state shows the VM and its HA resource both exist, with
  HA state = "started" (contradicts Proxmox reality of "stopped")
- The image attached to the VM is the correct Sprint 023 build

### Pipeline behavior

- Pipeline #679 (MR !176 merge): Deploy SUCCEEDED. VM recreated,
  vdb restored, VM started. Test stage failed (dashboard marker
  check — vault-agent couldn't render tokens yet).
- Pipeline #681 (MR !177 merge): Deploy FAILED at pre-deploy
  backup. `backup-now.sh` refused because influxdb-dev health
  probe was unreachable. Message: "Refusing backup while 1 VM(s)
  failed health check."
- All subsequent pipelines: Same failure. Deploy never reaches
  `tofu apply` because the backup preflight blocks it.

### Timeline reconstruction

All times PDT (UTC-7).

| Time | Event | Source |
|------|-------|--------|
| 22:36:17 | qmstop — old VM stopped for recreation | Pipeline #679 tofu apply |
| 22:36:18 | qmdestroy — old VM destroyed | Pipeline #679 tofu apply |
| 22:36:20 | qmcreate — new VM created | Pipeline #679 tofu apply |
| 22:36:28 | qmstart — new VM started | Pipeline #679 tofu apply |
| 22:37:03 | qmstop — VM stopped for vdb restore | Pipeline #679 restore-after-deploy |
| 22:37:28 | qmstart — VM restarted after restore | Pipeline #679 restore-after-deploy |
| 22:40:15 | Pipeline #679 test:dev completes (FAIL — dashboard marker) | Pipeline |
| 22:49-22:57 | Pipeline #681 validate + build stages run | Pipeline |
| **22:57:55** | **vzdump — backup of VM 501 triggered** | Unknown source |
| **22:58:35** | **hastop — HA explicitly stopped VM 501** | CRM command received |
| **22:58:47** | **qmstop — VM 501 stopped** | HA LRM executing stop |
| 23:03:50 | Pipeline #681 deploy:dev starts | Pipeline |
| 23:03:59 | Pipeline #681 deploy:dev FAILS at backup preflight | Pipeline |

### The mystery: what triggered the vzdump and hastop at 22:57-22:58?

The vzdump backup at 22:57:55 PDT is not from:
- The scheduled backup job (runs at 02:00 PDT daily)
- Pipeline #679's deploy stage (finished at 22:37)
- Pipeline #681's deploy stage (started at 23:03)
- Pipeline #681's build stage (builds nix images, doesn't run backups)

The CRM log shows `got crm command: stop vm:501 0` at 22:58:44. An SSH
session from pve02 (172.17.77.52) disconnected from pve03 (the CRM
master) at 22:58:35. This is consistent with a script running on the CI
runner SSHing to Proxmox nodes and issuing `ha-manager set vm:501
--state stopped` or equivalent.

**Hypothesis:** A background process from pipeline #679's deploy stage
completed asynchronously after the job reported success. The deploy
stage runs `restore-after-deploy.sh` which uses `ha-manager remove` /
`ha-manager add` patterns. If a restore operation was slow and completed
after the pipeline job exited, its cleanup could have left the HA
resource in an inconsistent state. Alternatively, `configure-backups.sh`
at the end of the deploy stage triggered a verification backup that
completed after the test stage started.

I cannot definitively determine the source without more detailed
process-level logging. The vzdump was triggered by `root@pam` which
is the same user as all pipeline operations.

## What I Tried and Why It Didn't Match Expectations

### Expectation 1: "The pipeline handles it"

I told the operator that the pipeline's backup-restore cycle handles
InfluxDB VM recreation automatically, with no manual steps needed.

**What happened:** The pipeline DID handle the recreation correctly
in pipeline #679. The VM was deployed, restored, and started. But
something stopped the VM 20 minutes after the pipeline finished, and
subsequent pipelines could not recover because the backup preflight
blocked the deploy.

### Expectation 2: "Retrying should work"

When the first post-fix pipeline (#681) failed with a Proxmox 500
error, I told the operator it was transient and to retry. After two
retries, the operator reported it wasn't transient.

**What happened:** I misread the error source. The initial error I
found (`PSS memory-stat`) was from my first trace query, which may
have read a different job than I thought (the job IDs changed between
retries). The actual failure in pipeline #681 and its retries was the
backup preflight refusing to proceed because influxdb-dev was
unhealthy. This is a persistent condition, not a transient one — the
VM is stopped and nothing in the pipeline can start it.

### Expectation 3: "The PSS error is transient"

I filed issue #218 claiming this was a transient Proxmox 500 that
`safe-apply.sh` should retry.

**What happened:** I may have been wrong about the PSS error occurring
at all in these pipeline runs. The backup preflight failure is
definitely not transient — it's a self-reinforcing loop.

## The Self-Reinforcing Failure Loop

The pipeline has a chicken-and-egg problem:

```
VM is stopped
  → backup-now.sh health check fails
    → backup-now.sh exits non-zero
      → deploy:dev refuses to proceed ("FATAL: PBS is configured
        but backup failed. Refusing to deploy.")
        → tofu apply never runs
          → VM is never recreated
            → VM stays stopped
              → next pipeline hits the same failure
```

The backup preflight is correct in principle — backing up an unhealthy
VM risks overwriting good backups with corrupt data. But it creates
an irrecoverable state when the VM being deployed IS the unhealthy one,
because the deploy that would fix it is blocked by the preflight that
checks it.

## Proposed Solutions

### Option A: Skip backup for the VM being recreated

If `tofu plan` shows that a VM will be destroyed and recreated, skip
the health check for that specific VM in `backup-now.sh`. The rationale:
a backup of a VM that's about to be destroyed is pointless anyway — the
restore-after-deploy will use the pinned backup from a previous
successful run.

**Trade-offs:**
- (+) Breaks the self-reinforcing loop automatically
- (+) Logically sound — why back up something you're about to destroy?
- (-) Requires `backup-now.sh` to know which VMs will be recreated,
  which means running `tofu plan` before the backup (adds time and
  complexity)
- (-) If the VM is unhealthy for a reason OTHER than "about to be
  recreated," skipping its backup is wrong

### Option B: Start stopped VMs before backup preflight

If the health check finds a VM in HA stopped state, issue
`ha-manager set vm:<id> --state started` and wait for it to come up
before proceeding with the backup.

**Trade-offs:**
- (+) Simple — just start the VM
- (+) Works regardless of why the VM is stopped
- (-) Starting an unhealthy VM might make things worse (corrupt data,
  boot loop)
- (-) The VM might be stopped for a reason (operator maintenance)
- (-) If the VM can't start (missing image, broken config), the
  pipeline still fails — just later

### Option C: Allow backup to proceed with a warning for unhealthy VMs

Change the backup preflight from a hard failure to a warning when a VM
is unhealthy, but still take the backup of healthy VMs and create the
pin file. The unhealthy VM won't be in the pin file, so
`restore-after-deploy` won't try to restore it from this run.

**Trade-offs:**
- (+) Breaks the loop — deploy proceeds
- (+) Healthy VMs are still backed up
- (-) Weakens the safety envelope — the original reason for the hard
  failure was to prevent deploys when the cluster is in a bad state
- (-) If the unhealthy VM has precious data that wasn't backed up,
  the deploy might destroy it without a recovery path

### Option D: Distinguish "stopped but deployable" from "unhealthy"

Check the specific failure mode. If the VM's HA state is "stopped"
but the VM conf and disks exist, and tofu state shows it should exist,
treat it as "stopped but deployable" rather than "unhealthy." Only
hard-fail on truly unhealthy VMs (missing from Proxmox, unresponsive
to qm status, etc.).

**Trade-offs:**
- (+) Most precise — distinguishes recoverable from non-recoverable
- (+) The backup preflight still catches real problems
- (-) More complex logic in `backup-now.sh`
- (-) "Stopped but deployable" is still ambiguous — the VM might be
  stopped because it's in a bad state, not just because HA stopped it

### Recommendation

**Option A** is the most architecturally sound. The pre-deploy backup
exists to protect precious-state VMs from destruction. If a VM is
already being destroyed and recreated by `tofu apply`, backing it up
immediately before destruction is wasted work — the protection comes
from the PREVIOUS backup, pinned by the PREVIOUS successful run.
The implementation complexity (running `tofu plan` first to identify
recreated VMs) is manageable because `tofu plan` already runs in the
validate stage.

**Option D** is the most pragmatic short-term fix. It handles the
immediate case (HA stopped state is not the same as "unhealthy") without
requiring `tofu plan` integration.

## Immediate Recovery

To unblock the pipeline now, the operator needs to start VM 501:

```bash
ssh root@172.17.77.52 "ha-manager set vm:501 --state started"
```

This restarts the VM with the existing image (which has the correct
Sprint 023 code). vault-agent should authenticate, render tokens, and
nginx should start. Once the VM is healthy, the next pipeline run's
backup preflight will pass.
