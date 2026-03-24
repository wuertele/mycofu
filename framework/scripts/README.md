## Quick Reference

| Script | Purpose |
|--------|---------|
| `ssh-refresh.sh <ip>` | Remove stale host key and SSH to a recently recreated VM |

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
