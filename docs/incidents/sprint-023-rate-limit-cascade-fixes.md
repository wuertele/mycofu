# Sprint 023 Rate Limit Cascade — Fixes Summary

## Bugs Fixed

### 1. `test -f` → `test -s` in InfluxDB TLS config (Part 1)
**File:** `framework/catalog/influxdb/module.nix:62`
**Bug:** Cert wait loop used `test -f` (exists), accepting 0-byte PEM files.
**Fix:** Changed to `test -s` for both `fullchain.pem` and `privkey.pem`.

### 2. RuntimeDirectory crash loop (Part 2)
**File:** `framework/catalog/influxdb/module.nix` (InfluxDB systemd service)
**Bug:** `RuntimeDirectory=influxdb2` caused systemd to clean up `/run/influxdb2/`
(including `tls.env`) on InfluxDB failure. Next restart: "No such file."
**Fix:** Run `influxdbConfigScript` as InfluxDB's `ExecStartPre` (with `+`
prefix for root). The tls.env file is recreated on every start attempt
inside the RuntimeDirectory that systemd just created.

### 3. Empty PEM cleanup in certbot-repair (Part 3)
**Files:** `framework/nix/modules/certbot.nix`,
`framework/scripts/certbot-persisted-state.sh`
**Bug:** certbot-repair didn't detect 0-byte PEM files from failed ACME
challenges. These prevented certbot from re-requesting.
**Fix:** Both the NixOS module inline and standalone script now detect
0-byte PEMs and remove the entire lineage (live, archive, renewal config).
**Tests:** Two new tests in `test_certbot_persisted_state.sh` (check mode
detects, repair mode removes).

## Audit Results (Part 4)

**Scope:** All `test -f` / `[ -f` / `[[ -f` usage in `framework/` and `site/`

| Category | Count |
|----------|-------|
| Shell script `test -f` matches | 9 |
| Nix `! -f` matches | 17 |
| Changed to `test -s` | 2 (vault.nix, grafana/module.nix) |
| Previously fixed (Part 1) | 1 (influxdb/module.nix) |
| Left as `test -f` (correct sentinel) | 7 |
| Already using `test -s` | 8 |
| Flagged for operator review | 3 |

Full audit: `docs/audits/test-f-audit-2026-04-19.md`

Two additional cert-wait bugs found and fixed:
- `framework/nix/modules/vault.nix:256` — same `test -f` bug
- `framework/catalog/grafana/module.nix:67` — same `test -f` bug

## Cert Budget Preflight (Part 5)

**File:** `framework/scripts/check-cert-budget.sh`
**Wired into:** `.gitlab-ci.yml` `deploy:prod` stage, before `tofu apply`

How it works:
- SSHes to each prod VM, counts cert files in
  `/etc/letsencrypt/archive/<FQDN>/` with mtime in last 168 hours
- Fails if any FQDN has >= 5 recent issuances (LE rate limit)
- Warns at >= 4
- Skips dev entirely (Pebble, no rate limits)
- Operator escape: `--ignore-cert-budget`

Error message example:
```
ERROR: influxdb.prod.wuertele.com has already had 5 certificates
issued in the last 168 hours. The Let's Encrypt rate limit is 5 per
FQDN per 168 hours.

Options:
  1. Wait for the oldest cert in the window to age out.
  2. Review whether the VM truly needs recreation (closure push instead?).
  3. Override with --ignore-cert-budget if you accept the risk.
```

**Tests:** 5 assertions in `tests/test_cert_budget.sh`
**Docs:** Updated OPERATIONS.md rate limit section

## Architectural Follow-up Issue (Part 6)

**Issue:** [#221](https://gitlab.prod.wuertele.com/root/mycofu/-/issues/221)
— Cert storage in Vault with cross-recreation restore

This issue seeds a future sprint to store application certificates in
Vault using the Category 4 bidirectional pattern (Sprint 006 Tailscale).
VM recreation would restore the existing cert from Vault instead of
requesting a new one from LE, eliminating rate limit consumption on
recreation.

## What Was NOT Done

The architectural fix (cert storage in Vault) was explicitly deferred
to the sprint seeded by issue #221. This branch contains only defensive
fixes and the preflight enhancement. The architectural fix requires
Vault policy additions, a new `cert-restore` NixOS service, a
`cert-sync` certbot hook, migration tooling, and DR testing — a
sprint-sized effort.

## Branch

`fix/cert-handling-bugs-sprint-023-fallout`

Commits:
1. `fix: use test -s for cert file checks in influxdb TLS config`
2. `fix: run TLS config as InfluxDB ExecStartPre to survive RuntimeDirectory cleanup`
3. `fix: detect and remove 0-byte PEM files in certbot-repair`
4. `fix: audit and fix test -f on cert files across codebase`
5. `feat: cert budget preflight for prod deploys`
