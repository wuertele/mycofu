# InfluxDB — Catalog Application

InfluxDB 2.x time-series database with HTTPS, automatic TLS, persistent
storage, backup, and monitoring integration.

## Quick Start

```bash
# 1. Add influxdb to site/config.yaml (see Configuration below)
# 2. Enable the application:
framework/scripts/enable-app.sh influxdb

# 3. Edit your config files:
$EDITOR site/apps/influxdb/setup.json    # Set org, bucket, retention
$EDITOR site/apps/influxdb/env.conf      # Set any InfluxDB overrides

# 4. Add the admin token to SOPS:
sops --set '["influxdb_admin_token"] "'"$(openssl rand -hex 32)"'"' site/sops/secrets.yaml

# 5. Build and deploy:
framework/scripts/build-image.sh site/nix/hosts/influxdb.nix influxdb
framework/scripts/safe-apply.sh dev
```

## Configuration

### Layer 1: Framework integration (site/config.yaml)

Add to the `applications` section:

```yaml
applications:
  influxdb:
    enabled: true
    node: pve02
    ram: 2048
    disk_size: 4
    data_disk_size: 20
    backup: true
    monitor: true
    health_port: 8086
    health_path: "/health"
    environments:
      prod:
        ip: 10.0.10.55
        mac: "02:xx:xx:xx:xx:xx"
      dev:
        ip: 10.0.60.55
        mac: "02:xx:xx:xx:xx:xx"
```

### Layer 2: Application configuration (site/apps/influxdb/)

#### env.conf (REQUIRED)

InfluxDB environment variable overrides. These are passed directly to
the `influxd` process. The framework does not parse or limit these —
any InfluxDB configuration option is supported.

TLS certificate paths are injected automatically by the module. Do NOT
set `INFLUXD_TLS_CERT` or `INFLUXD_TLS_KEY` in env.conf.

```bash
INFLUXD_BOLT_PATH=/var/lib/influxdb2/influxd.bolt
INFLUXD_ENGINE_PATH=/var/lib/influxdb2/engine
INFLUXD_HTTP_BIND_ADDRESS=:8086
```

See: https://docs.influxdata.com/influxdb/v2/reference/config-options/

#### setup.json (REQUIRED)

Initial setup parameters consumed on first boot. The admin password/token
comes from SOPS (not from this file).

```json
{
  "org": "homelab",
  "bucket": "default",
  "retention": "30d",
  "username": "admin"
}
```

- `org`: Organization name
- `bucket`: Default bucket name
- `retention`: Default retention period ("30d", "720h", "0" for infinite)
- `username`: Admin username

#### config.toml (OPTIONAL)

Full InfluxDB TOML configuration file. If present, placed at
`/etc/influxdb2/config.toml`. Settings here override corresponding
env.conf values. Most operators won't need this.

#### buckets.json (OPTIONAL)

Declarative additional bucket management. `setup.json` is bootstrap-only
(consumed on first boot only); for any buckets beyond the initial default,
list them in `buckets.json`. The `influxdb-reconcile-buckets` service
runs every boot, creates missing buckets, and updates retention on
existing ones.

```json
[
  { "name": "default",           "retention": "30d" },
  { "name": "homeassistant_raw", "retention": "90d" },
  { "name": "homeassistant_1h",  "retention": "0"   }
]
```

- `name`: bucket name (must match across boots)
- `retention`: same format as setup.json (`30d`, `720h`, `120s`, or `0` for infinite)

**The reconciler creates + updates only. It never deletes.** Removing a
bucket from `buckets.json` has no effect on InfluxDB — the bucket and
its data remain. To delete a bucket, use the InfluxDB CLI or API
directly.

**To apply changes**, edit `buckets.json` and redeploy. `buckets.json`
is part of the InfluxDB image (via `environment.etc."influxdb2/buckets.json"`),
so an edit changes the image hash. The next deploy rebuilds the image,
OpenTofu recreates the VM (vdb is preserved), and the reconciler runs
at boot against the updated file. There is no in-place edit path —
`/etc/influxdb2/buckets.json` is a read-only Nix store symlink.

If the reconciler unit failed transiently at boot (e.g. InfluxDB was
not yet ready inside the timeout window), re-run it manually:

```bash
# `restart`, not `start` — the unit is `RemainAfterExit=true`, so once
# it has exited, `start` is a no-op. `restart` forces it to re-run.
systemctl restart influxdb-reconcile-buckets
```

### Note on `setup.json` and reconciliation

`setup.json` is bootstrap-only for `org`, `bucket`, `retention`, and
`username` — the values are only applied to InfluxDB on first boot.
However, the bucket reconciler reads `.org` from `setup.json` on
every run to know which org's buckets to manage. Changing the `.org`
field in `setup.json` after first boot will NOT rename the org
inside InfluxDB; it will cause the reconciler to fail to resolve
the org ID. If you ever need to change the org name, do it via the
InfluxDB API and update `setup.json` to match.

## Secrets

The admin token is a pre-deploy secret stored in SOPS and delivered via
CIDATA write_files to `/run/secrets/influxdb/admin-token`.

```bash
sops --set '["influxdb_admin_token"] "'"$(openssl rand -hex 32)"'"' site/sops/secrets.yaml
```

Do NOT put runtime-generated tokens back into SOPS or CIDATA — that
creates the VM recreation cycle.

## Health Endpoint

`GET https://<ip>:8086/health` returns `{"status": "pass"}` when healthy.

## Data Persistence

All InfluxDB data is stored on vdb (`/var/lib/influxdb2`):
- Bolt database: `influxd.bolt`
- TSM engine: `engine/`
- Setup config: `setup.json` (copied from image on boot)

vdb survives VM recreation. The format-vdb service creates ext4 on
first boot only.

## Build Errors

If a required file is missing or contains placeholder values, the NixOS
build fails with a message explaining what's needed:

- Missing `env.conf`: tells you what to put in it
- Missing `setup.json`: shows a minimal example
- `setup.json` contains "CHANGEME": tells you to edit it
