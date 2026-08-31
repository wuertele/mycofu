# Report: InfluxDB Prod Certificate Rate Limit Cascade

## Summary

After promoting Sprint 023 code to prod, the InfluxDB prod VM cannot
start because Let's Encrypt has rate-limited certificate issuance for
`influxdb.prod.wuertele.com` (5 certificates in 168 hours). The rate
limit clears at 2026-04-20 00:55 UTC. Until then, InfluxDB prod is
down.

## How We Got Here

### The recreation cascade

Sprint 023 added nginx, vault-agent, and the cluster dashboard to the
InfluxDB NixOS module. This changed the image hash, triggering VM
recreation on every deploy. The sprint also had multiple bug fixes that
each required a new merge → new pipeline → new deploy → new recreation:

| Pipeline | Branch | Result | InfluxDB-dev recreated? | InfluxDB-prod recreated? |
|----------|--------|--------|------------------------|-------------------------|
| 668 | dev (Sprint 023 merge) | FAIL (git identity) | Yes | — |
| 670 | dev (git identity fix) | FAIL (jq on Proxmox) | No | — |
| 672 | dev (jq fix) | FAIL (InfluxDB token) | No | — |
| 674 | dev (token fix) | FAIL (validate) | No | — |
| 676 | dev (vault-agent $env) | FAIL (validate) | Yes | — |
| 679 | dev (SOPS credentials) | FAIL (validate) | Yes | — |
| 681 | dev (nginx perms) | SUCCESS | Yes | — |
| 683 | dev (duplicate Host) | SUCCESS | Yes | — |
| 687 | dev (schema fix) | SUCCESS | Yes | — |
| 655 | prod (Sprint 022) | SUCCESS | — | Yes |
| 662 | prod (earlier) | SUCCESS | — | No |
| 689 | prod (Sprint 023) | FAIL (rate limit) | — | Yes |

**influxdb-dev was recreated ~6 times** across dev pipelines 668-687.
**influxdb-prod was recreated 2 times** (pipelines 655 and 689).

Each recreation triggers certbot-initial on boot, which requests a new
certificate from Let's Encrypt. Six dev recreations + two prod
recreations = 8 certificate requests across two FQDNs. The limit is 5
per FQDN per 168 hours.

### Why the empty cert files

Pipeline 689 (prod) recreated influxdb-prod. The PBS backup-restore
cycle restored vdb (InfluxDB data) but the cert directory structure on
the root filesystem was empty — certbot had created the directory and
symlinks during a previous failed attempt, leaving 0-byte PEM files.

Certbot-initial saw the 0-byte files and tried to load them, failing
with `no start line`. After cleaning the stale files, certbot
requested a fresh cert — but the rate limit was already exhausted.

### Why the TLS config service didn't catch the empty certs

`influxdb-tls-config.service` waits for the cert file to appear:
```bash
while [ ! -f "$CERT_DIR/fullchain.pem" ]; do
```

This uses `test -f` (file exists) not `test -s` (file exists AND is
non-empty). The 0-byte `fullchain.pem` satisfies `test -f`, so the
TLS config service proceeds, writes `tls.env`, and reports success.
InfluxDB then tries to parse the empty PEM and crashes.

This is a known anti-pattern documented in `.claude/rules/platform.md`:
"Use `test -s`, not `test -f`, for files that should have content."

### The RuntimeDirectory self-reinforcing loop

Once InfluxDB fails to start, a second bug amplifies the problem. The
InfluxDB systemd unit has `RuntimeDirectory=influxdb2`, which means
systemd manages `/run/influxdb2/`. When InfluxDB crashes, systemd
cleans up the RuntimeDirectory — removing the `tls.env` file that
`influxdb-tls-config.service` created. On the next restart attempt,
`tls.env` is gone and InfluxDB fails with "No such file or directory"
even before it gets to the PEM parsing.

This creates a self-reinforcing loop:
1. InfluxDB fails (empty PEM or missing tls.env)
2. Systemd removes `/run/influxdb2/` (RuntimeDirectory cleanup)
3. `tls.env` is gone
4. Next restart: "Failed to load environment files: No such file"
5. Systemd removes `/run/influxdb2/` again
6. Repeat forever

### Root cause: manual operations during Sprint 023

**The fundamental cause of the recreation cascade was manual operations
that I performed without adequate testing.** Specifically:

1. I ran `configure-metrics.sh` directly on the cluster during Sprint
   022 live verification. This was appropriate — it's a cluster config
   script, not a VM modification.

2. During Sprint 023, I ran `configure-dashboard-tokens.sh dev` from
   the workstation to test it against real infrastructure. This was
   appropriate and caught real bugs.

3. **However, I did not test the full NixOS module changes against real
   infrastructure before pushing to the MR.** The Sprint 023 code was
   merged to dev based on Codex's sandbox execution and automated
   tests, without verifying:
   - That the Nix module evaluated correctly (it didn't — `${label}`
     variable escaping)
   - That the CI job used correct flake attribute names (it didn't —
     `nixosConfigurations.influxdb` vs `influxdb_dev`)
   - That vault-agent `$env` in the heredoc was escaped (it wasn't)
   - That nginx header files were readable by the nginx user (they
     weren't)
   - That the InfluxDB proxy didn't send duplicate Host headers (it
     did)
   - That the InfluxDB permission types were valid (they weren't)

4. **Each of these bugs required a separate fix commit, merge, and
   pipeline run.** Each pipeline run that reached the deploy stage
   recreated the InfluxDB VM (because the image hash changed with
   every fix). Each recreation triggered a new cert request.

5. **The six dev recreations consumed the rate limit for
   `influxdb.dev.wuertele.com`.** The two prod recreations consumed
   the rate limit for `influxdb.prod.wuertele.com`.

If I had tested the NixOS module locally (`nix eval`, `nix build`) and
tested the scripts against real infrastructure (the way Sprint 022 did
with `configure-metrics.sh` and `tofu plan`) before pushing the first
MR, most of these bugs would have been caught in a single iteration.
One recreation instead of six.

## What guards exist and why they didn't help

### Guard 1: ACME staging mode for dev

`.claude/rules/certificates.md` says to use LE staging during active
development. `site/config.yaml` has `acme: production`. Dev uses
Pebble (not LE), so dev recreations don't hit LE rate limits — but
they DO hit LE limits when the same code is promoted to prod.

**Why it didn't help:** Dev VMs use Pebble, which has no rate limits.
The rate limit problem only surfaces on prod, after dev testing is
"complete." The guard protects dev but not prod.

### Guard 2: `test -s` for cert files

`.claude/rules/platform.md` documents this pattern. The certbot
module's `ExecCondition` (line 347) correctly uses `test -s`:
```bash
[ ! -s "$CERT" ]
```

**Why it didn't help:** The certbot check is correct, but the
*InfluxDB TLS config service* uses `test -f` (line 62 of
`influxdb/module.nix`). The guard exists in the certbot layer but
wasn't applied consistently in the consuming layer.

### Guard 3: Sprint 021 cert-readiness gate

`validate.sh` has `wait_for_certs()` that probes TLS endpoints with
`openssl s_client` and waits up to 10 minutes.

**Why it didn't help:** The cert-readiness gate detects missing certs
but can't fix them. If the rate limit is exhausted, waiting longer
doesn't help. The gate correctly reports the failure, but by that
point the damage (rate limit consumption) has already occurred.

### Guard 4: Stale cert deletion (#174)

`certbot-repair-persisted-state` deletes stale certs when the ACME
server URL changes.

**Why it didn't help:** The ACME server URL didn't change (prod uses
production LE throughout). The stale cert deletion only triggers on
server URL mismatch, not on empty cert files.

### Missing guard: cert file content validation on restore

When PBS restores vdb, the cert directory structure on vda is
recreated fresh by the NixOS module. But certbot can leave empty
PEM files from failed ACME challenges. There is no guard that detects
and removes 0-byte cert files before certbot-initial runs. The
certbot `ExecCondition` checks `test -s` on the fullchain, but if the
renewal config already exists (from the PBS restore), certbot tries to
load the existing cert instead of requesting a new one — and fails on
the empty PEM.

### Missing guard: rate limit awareness

No part of the system tracks how many cert requests have been made
or refuses to request another when close to the limit. Certbot
itself doesn't cache rate limit state across VM recreations (the
ACME account data is per-VM, and recreation wipes it).

## Bugs Found

1. **`influxdb/module.nix:62` uses `test -f` not `test -s`** — accepts
   0-byte cert files as valid. Fix: change to `test -s`.

2. **`influxdb.service` has `RuntimeDirectory=influxdb2`** — systemd
   removes `/run/influxdb2/` (including `tls.env`) when InfluxDB
   fails. The TLS config service creates `tls.env` before InfluxDB
   starts, but the RuntimeDirectory wipe destroys it on any failure.
   Fix: either write `tls.env` to a path not managed by
   RuntimeDirectory, or make it an `ExecStartPre` of the InfluxDB
   service.

3. **No empty-cert-file cleanup** — certbot leaves 0-byte PEM files
   on ACME failure. These prevent certbot from re-requesting because
   it thinks the cert exists. Fix: `certbot-repair` should detect and
   remove 0-byte PEM files.

## Immediate Recovery

Wait for rate limit to clear at 2026-04-20 00:55 UTC. Then:
1. Clean stale cert files (already done)
2. certbot-initial will successfully request a new cert
3. Fix `test -f` → `test -s` in `influxdb/module.nix`
4. Fix RuntimeDirectory race in the InfluxDB systemd unit
5. Redeploy

Alternatively: temporarily run InfluxDB without TLS (remove the TLS
env vars from the systemd override). Metrics would flow unencrypted
on localhost, which is acceptable for a few hours.

## Lessons

1. **Test NixOS module changes locally before pushing.** `nix eval` and
   `nix build` on the workstation would have caught the variable
   escaping, flake attribute, and other Nix-layer bugs in a single
   iteration. This was the lesson from the Sprint 023 pipeline
   failures report — and it was partially applied (the image was built
   locally) but the bugs that required multiple fix iterations were all
   runtime bugs that local testing would have caught.

2. **Each fix iteration that changes the image hash costs a VM
   recreation and a cert request.** With a 5-cert/week limit, six
   iterations exhaust the budget. The cost of "fix, push, wait for
   pipeline, discover next bug" is not just time — it's a finite
   resource (cert requests) that can't be replenished for a week.

3. **Applying `test -s` consistently is a systemic issue.** The rule
   exists in `.claude/rules/platform.md` and is applied in the certbot
   module, but not in consuming modules. Every cert file check in the
   codebase should be audited.

4. **RuntimeDirectory + external service creating files in that
   directory = race condition.** This is a systemd design pattern
   issue. Services that depend on files created by other services
   should not use RuntimeDirectory for the same path.
