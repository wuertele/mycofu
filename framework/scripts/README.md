## Quick Reference

| Script | Purpose |
|--------|---------|
| `ssh-refresh.sh <ip>` | Remove stale host key and SSH to a recently recreated VM |
| `seed-github-deploy-key.sh prod --key-file <path>` | Seed or rotate the prod GitHub publish deploy key into SOPS and Vault |
| `verify-github-publish.sh prod` | Check GitHub remote config, SOPS/Vault key parity, runner materialization, and optional smoke-branch write access |
| `validate-github-mirror.sh --expected-sha <sha>` | Compare public `.mycofu-publish.json` metadata or deployed Gatus config against the expected prod commit |

## Backup Pins

`backup-now.sh --pin-out <path>` writes a JSON pin file mapping VMIDs to the
exact PBS `volid` captured before a destructive deploy. The pipeline writes
environment-scoped artifacts such as `build/restore-pin-dev.json` and
`build/restore-pin-prod.json`.

`safe-apply.sh` and `rebuild-cluster.sh` pass these pins to
`restore-before-start.sh` for the preboot restore window. For ad hoc single-VM
recovery, the operator should pin an exact snapshot manually with:

```bash
framework/scripts/restore-from-pbs.sh --target 303 \
  --backup-id 'pbs-nas:backup/vm/303/2026-04-12T18:30:00Z'
```

Omitting `--backup-id` falls back to latest only for deliberate manual
recovery, never as the normal destructive deploy path.

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
See `upload-image.sh` for an example of the nested case (prune section).
