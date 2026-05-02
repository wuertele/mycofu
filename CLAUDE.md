# Mycofu Infrastructure Platform

Self-hosted infrastructure framework using Proxmox, NixOS, and OpenTofu.
3-node HA cluster with dev/prod environment separation.

## Authoritative Documents

- `architecture.md` — architectural decisions, rationale, and contracts
- `implementation-plan.md` — step-by-step build plan with validation gates
- `.claude/rules/` — operational rules (read ALL of these before starting work)
- Prompt documents in `prompts/prompt*` are write-once instructions; do not update them
- Current operator-facing docs (`README.md`, `GETTING-STARTED.md`,
  `OPERATIONS.md`, and the framework docs) are maintained with the same
  deployment semantics as the architecture docs

## Key Rules (read `.claude/rules/` for full details)

- **No manual fixes, no manual recovery.** Every change must be persistent
  — captured in NixOS modules, OpenTofu configs, or framework scripts. If
  it's not in the repo, it doesn't survive VM recreation. The same
  discipline applies to recovery: when restoring a VM, a disk, or a cert,
  use framework tooling (`restore-from-pbs.sh`, `rebuild-cluster.sh`), not
  manual file extraction from backups. "Restore the backup" is goal
  language, not mechanism language — the mechanism is always the framework
  tool. (`.claude/rules/no-manual-fixes.md`)
- **Pipeline must be green.** A task is not done until validate.sh passes
  AND the GitLab pipeline shows all stages green. Do not dismiss test
  failures as "pre-existing." (`.claude/rules/testing.md`)
- **Config.yaml is the single source of truth.** All site-specific values
  come from `site/config.yaml`. Zero hardcoded IPs, domains, or hostnames
  in `framework/`. (`.claude/rules/config-yaml.md`)
- **CIDATA is a creation-time input.** Only pre-deploy values belong in
  CIDATA. Post-deploy secrets (Vault unseal key, runner token) are delivered
  via SSH to vdb. (`.claude/rules/proxmox-tofu.md`)
- **Use the pipeline, not --dev.** Build and deploy via GitLab CI, not
  manual `build-image.sh --dev` + `tofu apply`. (`.claude/rules/build-deploy.md`)

## Key Commands

- Build image: `framework/scripts/build-image.sh site/nix/hosts/<role>.nix <role>`
- Build all images: `framework/scripts/build-all-images.sh`
- Upload image: `framework/scripts/upload-image.sh <image-file> <role>`
- Deploy (pipeline): push to `dev` branch → pipeline deploys to dev
- Deploy (workstation): `framework/scripts/safe-apply.sh <env>` for
  data-plane VMs; `framework/scripts/rebuild-cluster.sh --scope control-plane`
  for GitLab/runner/PBS
- Image gate: `tofu-wrapper.sh apply` blocks on placeholder or invalid `site/tofu/image-versions.auto.tfvars` values; run `build-image.sh`/`build-all-images.sh` first, or bypass intentionally with `--allow-placeholder-images`
- Validate: `framework/scripts/validate.sh` (must show 37/37 PASS)
- Decrypt secrets: `sops -d site/sops/secrets.yaml`
- Replication cleanup: `framework/scripts/configure-replication.sh "*"`
- Rebalance after failover: `framework/scripts/rebalance-cluster.sh`

## Branch Model

| Branch | Remote | Deploys to | Protection |
|--------|--------|------------|------------|
| `main` | GitHub (public) | Nothing (framework-only, no CI) | Yes |
| `dev` | GitLab (private) | Dev environment | Direct push OK |
| `prod` | GitLab (private) | Prod environment | MR-only |

Changes flow: `feature branch → dev → prod`. Promotion to prod requires
a merge request in GitLab. See `.claude/rules/build-deploy.md`.

## Repository Structure

- `framework/` — reusable modules, scripts, templates (no site-specific values)
- `site/` — site-specific config, secrets, zone files, host configs
- `site/config.yaml` — single source of truth for all site-specific values
- `site/sops/secrets.yaml` — SOPS-encrypted bootstrap secrets
- `site/tofu/main.tf` — OpenTofu root module (site-level resource config)
- `site/nix/hosts/` — per-role NixOS host configurations

## Two-Tier Deployment

- **Tier 1 (pipeline):** DNS, Vault, Pebble, Gatus, application VMs.
  Deployed automatically by CI/CD. Dev pipeline targets dev modules only;
  prod pipeline targets prod modules only.
- **Tier 2 (workstation):** GitLab, CI/CD runner, PBS. Updated manually
  by the operator. The pipeline cannot redeploy the infrastructure it runs on.

## After Any Destructive Operation

1. SSH host keys: `ssh-keygen -R` for affected VMs
2. Vault: `init-vault.sh` + `configure-vault.sh` for recreated Vaults
3. Replication: `configure-replication.sh "*"`
4. Runner: `register-runner.sh` if GitLab was recreated
5. Validation: `validate.sh` — MUST pass before declaring done

See `.claude/rules/testing.md` for the full checklist.

## Conventions

- All site-specific values come from `site/config.yaml`, never hardcoded
- VM images are environment-ignorant: no env names, FQDNs, or IPs in images
- Environment binding is via VLAN → DHCP search domain → unqualified hostnames
- Dev-first deployment: always validate in dev before promoting to prod
- Completion reports must document all differences from prompt assumptions
- Completion reports must state where each fix is persisted (which file in the repo)
