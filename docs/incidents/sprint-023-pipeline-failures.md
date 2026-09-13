# Sprint 023 Pipeline Failure Report

## Timeline

| Pipeline | Trigger | Result | Root Cause |
|----------|---------|--------|------------|
| #664 | MR !171 premerge | FAIL | Nix eval: `undefined variable 'label'` — unescaped bash `${label}` in Nix string |
| #665 | MR !171 premerge (fix) | FAIL | Nix eval: `nixosConfigurations.influxdb` doesn't exist (should be `influxdb_dev`) |
| #666 | MR !171 premerge (fix) | PASS | — |
| #668 | Merge to dev | FAIL | `configure-vault.sh` git commit: `unable to auto-detect email address` on CI runner |
| #670 | !172 merge (git identity fix) | FAIL | `configure-dashboard-tokens.sh`: `jq: command not found` on Proxmox node |
| #672 | !173 merge (jq fix) | FAIL | `configure-dashboard-tokens.sh`: InfluxDB rejects invalid permission resource types |
| #674 | !174 merge (permission fix) | FAIL | `validate.sh`: dashboard landing page check fails (nginx not running) |
| #676 | !175 merge (vault-agent `$env` fix) | FAIL | `validate.sh`: dashboard landing page check fails (vault-agent has no AppRole credentials) |

## What I Expected

After Sprint 023 code was merged and the pipeline deployed it, I expected:

1. The influxdb-dev VM would be recreated with the new NixOS image (nginx + vault-agent + dashboard)
2. `configure-vault.sh` would create the influxdb_dev AppRole and write credentials to SOPS
3. The SOPS credentials would be committed and available for the next deploy
4. CIDATA would include the AppRole credentials, vault-agent would authenticate, render tokens, and nginx would start
5. The dashboard would be accessible and the validate.sh check would pass

I told the operator "the pipeline handles it" and that no manual steps were needed. I was wrong on multiple counts.

## What Actually Happened

### Failure 1: Nix evaluation errors (pipelines #664, #665)

**Expected:** The NixOS module would evaluate cleanly since `node --check` passed locally.

**Actual:** Two distinct Nix evaluation errors:
- `${label}` in a Nix `''` string was parsed as a Nix variable interpolation, not a bash variable
- The CI job referenced `nixosConfigurations.influxdb` but the flake exports `influxdb_dev`/`influxdb_prod`

**Why I missed it:** The local test (`node --check dashboard.js`) validated JavaScript syntax, not Nix evaluation. I didn't run `nix eval` on the workstation before pushing. The `nixosConfigurations` attribute name was wrong because Codex assumed a 1:1 mapping between image role names and configuration names.

### Failure 2: Git identity on CI runner (pipeline #668)

**Expected:** `configure-vault.sh` would commit SOPS changes in the pipeline.

**Actual:** The CI runner (running as root on the cicd VM) had no git `user.email` or `user.name` configured. `git commit` failed.

**Why I missed it:** This was the first time `configure-vault.sh` created a NEW AppRole in the pipeline. All previous AppRoles (dns, gitlab, cicd) were created from the workstation, which has git identity. The pipeline only reconciled existing roles — it never hit the commit path before.

### Failure 3: jq not on Proxmox nodes (pipeline #670)

**Expected:** `configure-dashboard-tokens.sh` would run `pveum | jq` on the Proxmox node via SSH.

**Actual:** Proxmox nodes are stock Debian and don't have `jq` installed.

**Why I missed it:** The test mocked the SSH calls. I ran the InfluxDB token creation locally (workstation has jq) and via the runner (which also has jq), but the `pveum` commands run on the Proxmox NODE via SSH, not on the runner. I didn't trace the actual execution path — `pve_ssh "pveum ... | jq ..."` runs jq on the remote side, not locally.

### Failure 4: Invalid InfluxDB permission types (pipeline #672)

**Expected:** The InfluxDB API would accept `query` and `authorizations` as resource types for the scoped token.

**Actual:** InfluxDB 2.x only accepts concrete resource types like `buckets`, `orgs`, `users`. The API returned `"invalid resource type for permission: unknown resource type"`.

**Why I missed it:** I verified the token creation flow from the workstation AFTER fixing this — but I should have run it BEFORE pushing the original code. Codex generated the permission payload from documentation assumptions, not from testing against the real API.

### Failure 5: vault-agent `$env` unbound variable (pipeline #674)

**Expected:** vault-agent would start and render dashboard tokens.

**Actual:** The vault-agent config writer script failed with `env: unbound variable`. The Vault template variable `$env` was expanded by bash's unquoted heredoc `<<AGENTEOF` instead of being passed through to vault-agent.

**Why I missed it:** I tested Nix evaluation (`nix eval`) which succeeded because the Nix layer doesn't execute the generated bash script — it just produces it. The actual bash execution only happens at VM boot time. I should have inspected the generated script in the nix store to verify the heredoc variable handling.

### Failure 6: AppRole credentials not in CIDATA (pipeline #676)

**Expected:** After all the script fixes, the dashboard would work.

**Actual:** vault-agent starts but can't authenticate: `"no known role ID"`. The AppRole credentials are not in `/run/secrets/vault/` because they were never written to SOPS, so they were never included in CIDATA.

**Why this happened:** Pipeline #668 created the AppRole in Vault and generated the role_id/secret_id, but the git commit to SOPS failed (git identity issue). The credentials existed momentarily in the runner's working tree but were lost when the pipeline failed. Pipeline #670 (with the git identity fix) ran `configure-vault.sh` again, but it saw the Vault role already existed and re-generated credentials. However, the SOPS commit succeeded locally on the runner — but was never pushed. The CI runner checks out code in detached HEAD mode, and `configure-vault.sh` does `git commit` but not `git push`. The commit exists only in the runner's local checkout and is discarded on the next pipeline run.

## Why the Pipeline Can't Autoconverge

The fundamental issue is that the pipeline cannot persist SOPS changes back to the repository. This creates a chicken-and-egg problem for new AppRole onboarding:

1. **CIDATA is built from the repo at deploy time.** The AppRole credentials must be in `site/sops/secrets.yaml` in the repo so that OpenTofu can include them in the VM's CIDATA `write_files`.

2. **AppRole credentials are generated at deploy time.** `configure-vault.sh` creates the AppRole in Vault and generates the role_id/secret_id during `post-deploy.sh`, which runs AFTER `tofu apply` has already built CIDATA from the repo.

3. **The pipeline can't push changes back to the repo.** The CI runner operates in detached HEAD mode. Even with the git identity fix, a `git commit` on the runner is a local commit that is never pushed. The next pipeline gets a fresh checkout without the credentials.

4. **The result is a two-pipeline convergence that doesn't converge.**
   - Pipeline N: `tofu apply` creates VM with empty CIDATA (no AppRole creds) → `configure-vault.sh` creates the role and generates creds → creds exist in working tree but aren't pushed
   - Pipeline N+1: fresh checkout → SOPS still empty → CIDATA still empty → vault-agent still can't authenticate

This is the same architectural limitation documented for vault unseal keys at the top of `post-deploy.sh`: the pipeline generates secrets it can't persist. The existing pattern requires workstation intervention to commit SOPS changes and push.

### Why existing AppRoles (dns, gitlab, cicd) work

These were onboarded before the pipeline existed, or from the workstation during `rebuild-cluster.sh`. The operator ran `configure-vault.sh` locally, committed the SOPS changes, and pushed. By the time the pipeline deploys these VMs, the credentials are already in SOPS and flow into CIDATA normally.

The influxdb_dev AppRole is the first one created entirely through the pipeline path, which is why this gap was never hit before.

## Corrective Actions

### Immediate
Run `configure-vault.sh dev` from the workstation to regenerate and persist the influxdb_dev AppRole credentials to SOPS. Push to dev. The next pipeline deploy will include the credentials in CIDATA.

### Process
1. **Always run new scripts against real infrastructure from the workstation before pushing to an MR.** The Sprint 022 execution correctly did this for `configure-metrics.sh` and `tofu plan`. Sprint 023 skipped this step for `configure-dashboard-tokens.sh` and the NixOS module.

2. **For any sprint that adds vault-agent to a new VM**, the sprint plan should explicitly call out that AppRole onboarding requires a workstation `configure-vault.sh` run before the pipeline can deploy the VM with working credentials. This is not a pipeline limitation to fix — it's an architectural property to document.

3. **Nix evaluation should be tested locally before pushing.** `nix eval .#nixosConfigurations.<name>.config.system.build.toplevel.drvPath` catches variable scoping and attribute name errors that `node --check` and `bash -n` miss.

## Lessons

The six failures share a common theme: **testing structure without testing behavior.** Every automated test validated that files existed, syntax was correct, wiring was present, and contracts were met. None tested that the actual runtime behavior worked — that the bash script ran on the real target, that the API accepted the real payload, that the generated config contained the right variable escaping, or that the credentials flowed through the full CIDATA path.

The Sprint 022 execution got this right for its two critical paths (metrics and tags) by running them against the real cluster before declaring the sprint done. Sprint 023 skipped this step and paid for it with six pipeline failures over eight hours.
