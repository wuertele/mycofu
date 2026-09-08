# Audit: `test -f` vs `test -s` for content-bearing files

**Date:** 2026-04-19
**Scope:** `framework/` and `site/` — all `.sh`, `.nix`, `.bash` files
**Trigger:** Sprint 023 rate limit cascade — 0-byte PEM files accepted by `test -f`

## Summary

- **Total `test -f` / `[ -f` / `[[ -f` matches:** 9 (shell scripts)
- **Total `! -f` matches in .nix files:** 17
- **Changed to `test -s`:** 3 (vault.nix, grafana/module.nix, gitlab.nix — last caught by adversarial review)
- **Previously fixed in this branch:** 1 (influxdb/module.nix, Part 1)
- **Left as `test -f` (correct):** 7 (sentinel/existence checks)
- **Already using `test -s` (correct):** 8

## Changes Made

| File | Line | Before | After | Rationale |
|------|------|--------|-------|-----------|
| `framework/nix/modules/vault.nix` | 256 | `! -f "$CERT_DIR/fullchain.pem"` | `! -s "$CERT_DIR/fullchain.pem" \|\| ! -s "$CERT_DIR/privkey.pem"` | Cert file must have content |
| `framework/catalog/grafana/module.nix` | 67 | `! -f "$CERT_DIR/fullchain.pem"` | `! -s "$CERT_DIR/fullchain.pem" \|\| ! -s "$CERT_DIR/privkey.pem"` | Cert file must have content |
| `framework/nix/modules/gitlab.nix` | 290 | `! -f "$CERT_DIR/fullchain.pem"` | `! -s "$CERT_DIR/fullchain.pem" \|\| ! -s "$CERT_DIR/privkey.pem"` | Cert file must have content (caught by adversarial review) |

## Left as `test -f` (Correct — Sentinel/Existence Checks)

| File | Line | Check | Rationale |
|------|------|-------|-----------|
| `framework/dr-tests/tests/DRT-002-cold-rebuild.sh` | 26 | `test -f framework/scripts/setup-nix-builder.sh` | Script existence check — presence is the signal |
| `framework/dr-tests/tests/DRT-002-cold-rebuild.sh` | 33 | `test -f operator.age.key` | Key file existence — but should arguably be `test -s` (flagged below) |
| `framework/scripts/validate.sh` | 973 | `test -f /var/lib/vault/unseal-key` | Unseal key existence — written by init-vault.sh, content matters |
| `framework/scripts/configure-storage.sh` | 83 | `test -f /etc/pve/storage.cfg` | Config existence check — presence is the signal |
| `framework/scripts/register-runner.sh` | 67,118 | `test -f /etc/gitlab-runner/config.toml` | Config existence + grep for content — the grep validates content |
| `framework/scripts/upload-image.sh` | 107 | `test -f ${DEST_PATH}` | Image file existence on node — presence means already uploaded |
| `framework/scripts/configure-node-network.sh` | 685 | `test -f /etc/apt/sources.list.d/pve-no-subscription.list` | Repo file existence — presence is the signal |

## Already Using `test -s` (Correct)

| File | Line | Check |
|------|------|-------|
| `framework/catalog/influxdb/module.nix` | 66 | Cert wait (fixed in Part 1 of this branch) |
| `framework/catalog/cluster-dashboard/module.nix` | 27 | Token file wait |
| `framework/nix/modules/certbot.nix` | 263 | Empty PEM detection (fixed in Part 3) |
| `framework/nix/modules/certbot.nix` | 370 | ExecCondition cert check |
| `framework/nix/modules/step-ca.nix` | 91 | DNS file wait |
| `framework/nix/modules/tailscale.nix` | 171 | Vault token wait |
| `framework/nix/modules/base.nix` | 266 | CA bundle check |
| `framework/nix/modules/dns.nix` | 133 | SQLite DB existence — arguably sentinel (DB is created empty) |

## Flagged for Operator Review

| File | Line | Check | Concern |
|------|------|-------|---------|
| `framework/scripts/validate.sh` | 973 | `test -f /var/lib/vault/unseal-key` | The unseal key is critical — an empty file would cause silent failure on unseal. Should this be `test -s`? Left as-is because the script checks the key by using it (unseal attempt), not by trusting the file's content. |
| `framework/dr-tests/tests/DRT-002-cold-rebuild.sh` | 33 | `test -f operator.age.key` | The age key must have content to decrypt SOPS. An empty file would cause cryptic SOPS errors. Could be `test -s` but it's a test precondition, not production code. |
| `framework/nix/modules/dns.nix` | 133 | `! -f /var/lib/pdns/pdns.db` | SQLite DB — `test -f` is correct because the DB is created empty (SQLite creates on open). Content is added later. |

## Nix-Specific `! -f` Checks (Correct — Sentinel/Config Presence)

| File | Line | Check | Rationale |
|------|------|-------|-----------|
| `framework/nix/modules/certbot.nix` | 78,154 | `! -f /run/secrets/certbot/acme-server-url` | CIDATA file existence — nocloud-init writes with content |
| `framework/nix/modules/dns.nix` | 219 | `! -f "$ZONE_DATA"` | Zone data file existence |
| `framework/nix/modules/wait-for-vdb.nix` | 67 | `! -f /run/secrets/vdb-restore-expected` | CIDATA sentinel — existence IS the signal |
| `framework/catalog/influxdb/module.nix` | 120 | `! -f /run/secrets/influxdb/admin-token` | CIDATA file existence |
| `framework/catalog/influxdb/module.nix` | 128 | `! -f "$SETUP_JSON"` | Config file existence |
| `framework/nix/checks/source-filter-check.nix` | 26 | `! -f "${nixSrc}/framework/nix/modules/base.nix"` | Build-time source check |
