## Quick Reference

| Script | Purpose |
|--------|---------|
| `ssh-refresh.sh <ip>` | Remove stale host key and SSH to a recently recreated VM |
| `remaster-pve-installer.sh --config <config> --node <name>` | Build a per-node unattended Proxmox installer ISO from config and SOPS |
| `install-pve-node.sh --config <config> --node <name> [--dry-run]` | Regreen one AMT-capable node via hil-boot PXE and AMT one-shot reset |
| `regreen-cluster.sh --config <config> [--node <name>] [--dry-run]` | Serial fail-fast orchestrator for enabled regreener nodes |
| `pdu-cycle.sh --config <config> <node>` | Last-resort PDU cycle using `pdu` and `nodes[].pdu_outlet` from config |
| `seed-github-deploy-key.sh prod --key-file <path>` | Seed or rotate the prod GitHub publish deploy key into SOPS and Vault |
| `verify-github-publish.sh prod` | Check GitHub remote config, SOPS/Vault key parity, runner materialization, and optional smoke-branch write access |
| `validate-github-mirror.sh --expected-sha <sha>` | Compare public `.mycofu-publish.json` metadata or deployed Gatus config against the expected prod commit |

## Cluster Regreener

The regreener is an optional AMT/PXE automation path for bringing physical
nodes to stock Proxmox before `rebuild-cluster.sh` takes over. It consists of
framework primitives:

- `remaster-pve-installer.sh` renders the Proxmox unattended answer file from
  `config.yaml` and the co-located SOPS file, then writes a content-addressed
  ISO under `build/regreener/isos/`.
- `install-pve-node.sh` handles one enabled node: hil-boot SSH and HTTP
  preflight, MeshCmd AMT feature healing, one-shot PXE reset, SSH-down then
  SSH-up wait, PVE web wait, and the green predicate.
- `regreen-cluster.sh` chooses nodes with `regreen_enabled: true`, runs them
  serially, stops on the first failure, and writes `build/regreen/status.json`.
- `pdu-cycle.sh` is a last-resort recovery path when AMT is wedged. It reads
  the PDU host/user/password reference and outlet mapping from config; outlets
  are data, not derived from node names.

Run the regreener from the operator workstation or the HIL GitLab web-trigger
job. hil-boot owns dnsmasq/TFTP/HTTP and contains the generated PXE artifacts;
MeshCmd remains a pinned Nix host tool on the executor, not software installed
by hand on Proxmox nodes. The workstation-side scripts only orchestrate AMT,
PDU, and status collection.

`remaster-pve-installer.sh` remains as the legacy standalone ISO helper. When
running it somewhere without `/nix/var/regreener-cache` or `/nix/tmp`, set
`MYCOFU_REGREENER_CACHE_DIR` and `MYCOFU_REGREENER_WORK_ROOT` to absolute
writable paths with enough room for the stock ISO and xorriso working tree.

Non-destructive preflight:

```bash
framework/scripts/regreen-cluster.sh \
  --config <hil-config.yaml> \
  --node <node> \
  --dry-run
```

Destructive regreen has no runtime confirmation flag. The opt-in is in config:
the targeted node must have `regreen_enabled: true`.

```bash
framework/scripts/regreen-cluster.sh \
  --config <hil-config.yaml> \
  --node <node>
```

For a first-light run, capture the command output, the per-node log under
`build/regreen/`, and `build/regreen/status.json`.
After all intended nodes report green, hand off to the existing
`framework/scripts/rebuild-cluster.sh` path.

GitLab HIL invocation is a web-triggered pipeline on a branch containing
`tests/hil/.gitlab-ci-hil.yml`. Set `REGREEN_NODE=<node>` for one node or omit
it for all enabled nodes. The web pipeline source is the regreen signal; there
is no separate `HIL_REGREEN` variable.

## Backup Pins

`backup-now.sh --pin-out <path>` writes a JSON pin file mapping VMIDs to the
exact PBS `volid` captured before a destructive deploy. The pipeline writes
environment-scoped artifacts such as `build/restore-pin-dev.json` and
`build/restore-pin-prod.json`.

`backup-now.sh --skip-vmid <vmid>` is reserved for incomplete-VM convergence:
the framework already has an exact repair pin for that VMID and must back up
the rest of the selected precious-state set without trying to snapshot the
broken VM. Unknown skip VMIDs warn and continue; they do not change the normal
selected backup set.

`safe-apply.sh` and `rebuild-cluster.sh` pass these pins to
`restore-before-start.sh` for the preboot restore window. For ad hoc single-VM
recovery, the operator should pin an exact snapshot manually with:

```bash
framework/scripts/restore-from-pbs.sh --target 303 \
  --backup-id 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z'
```

Omitting `--backup-id` falls back to latest only for deliberate manual
recovery, never as the normal destructive deploy path.

`build/repair-pin-${env}.json` is an operator-supplied pin file for
pre-existing incomplete topology discovered before the deploy backup starts.
The CI pre-deploy gate currently consumes this repair pin in `deploy:dev` only,
per the Sprint 041 F4 scope decision; prod repair should be handled explicitly
from the workstation unless that contract is expanded.

## Image Store Reclaim

`upload-image.sh` is append-only. It uploads to a per-writer
`*.partial.<pid>.<rand>` path, renames that path into place on the Proxmox
node, and never deletes old images.

`reclaim-images.sh` is the only framework path that deletes old image files.
It is dry-run by default and requires `--apply` for deletion. CI runs it only
from operator-approved schedule/web pipelines. The CI job is split per role and
each shard shares the matching `build-image-${ROLE}` resource group with the
upload job, so reclaim cannot run concurrently with a same-role image publish.
It fails closed when deployed-image metadata cannot be fetched in strict mode.

The keep set is conservative: the newest five images per role, images deployed
by dev or prod, images referenced by any VM config, and images younger than
24 hours are retained. Stale `*.partial.*` upload leftovers are swept only by
the reclaim job after their TTL.

## vm-scope.sh fixture-test conventions

`vm-scope.sh` is the single reader for VM-class taxonomy (see
`docs/sprints/SPRINT-039.md`). Fixture tests point it at synthetic
manifests so the loader's fail-closed modes and subcommand output are
exercised without touching real `framework/images.yaml` / `site/images.yaml`
/ `site/applications.yaml`. Every knob the script consults is
script-scoped so a wrapper test can control it independently of the
operator's shell environment.

| Env var | What it overrides | Default |
|---------|-------------------|---------|
| `VM_SCOPE_FRAMEWORK_MANIFEST` | Path to `framework/images.yaml` | `<repo>/framework/images.yaml` |
| `VM_SCOPE_SITE_MANIFEST` | Path to `site/images.yaml` | `<repo>/site/images.yaml` |
| `VM_SCOPE_APPS_CONFIG` | Path to `site/applications.yaml` | `<repo>/site/applications.yaml` |
| `VM_SCOPE_TOFU_ROOT` | Path to the tofu root module | `<repo>/framework/tofu/root` |
| `VM_SCOPE_YQ_BIN` | Path to the `yq` binary the loader invokes | first `yq` on `PATH` |

`VM_SCOPE_YQ_BIN` matters when a test shims `yq` on `PATH` (for
example, `safe-apply.sh` fixture tests use a fake `yq` that returns
test-specific config). Pointing `VM_SCOPE_YQ_BIN` at the real `yq`
lets `vm-scope.sh` keep reading the actual manifests while the outer
shim still answers other callers on the same run. The name mirrors
the `CERTBOT_CLUSTER_YQ_BIN` / `VALIDATE_GITHUB_MIRROR_YQ_BIN` /
`SYNC_TO_MAIN_YQ_BIN` pattern used elsewhere in `framework/scripts/`.

`tests/test_vm_scope_loader.sh` uses all four `VM_SCOPE_*_MANIFEST` /
`VM_SCOPE_APPS_CONFIG` vars to build synthetic manifests under
`mktemp -d` and covers the fail-closed modes (missing scope, missing
`yq`, malformed YAML, duplicate normalized names, cross-manifest
duplicate, vendor with build fields, role in both `roles` and
`non_built_roles`). Its "missing yq fails closed" case unsets both
`VM_SCOPE_YQ_BIN` and the legacy `YQ_BIN` from the child env so an
operator with either variable exported cannot false-pass it, and the
"override beats PATH shim" case pairs `VM_SCOPE_YQ_BIN=<real yq>`
with a PATH-front-loaded fake `yq` to prove the override actually
wins.

## Shell Scripting Conventions

### SSH inside `while read` loops: always use `ssh -n`

**Rule:** Any `ssh` call inside a `while read` loop must use `ssh -n`.

**Why:** `ssh` reads from stdin by default. Inside a `while read` loop, stdin is
the loop's input source (the pipe or process substitution). Without `-n`, `ssh`
consumes the remaining input, causing the loop to exit after the first iteration
with no error or warning.

**Wrong:**
```bash
while IFS= read -r NODE; do
  ssh root@$NODE "do something"   # consumes loop stdin — only first node processed
done < <(yq '.nodes[].mgmt_ip' site/config.yaml)
```

**Right:**
```bash
while IFS= read -r NODE; do
  ssh -n root@$NODE "do something"  # -n: redirect stdin from /dev/null
done < <(yq '.nodes[].mgmt_ip' site/config.yaml)
```

This applies to all `ssh` calls in loops, including nested process substitutions.
See `upload-image.sh` and `reclaim-images.sh` for nested loop examples.
