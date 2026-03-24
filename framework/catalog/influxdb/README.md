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
framework/scripts/tofu-wrapper.sh apply -target=module.influxdb_dev
framework/scripts/configure-replication.sh "*"
framework/scripts/configure-backups.sh
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
