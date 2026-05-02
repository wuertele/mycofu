# Grafana — Catalog Application

Grafana dashboards and visualization platform with HTTPS, automatic TLS,
persistent storage, and InfluxDB integration.

## Quick Start

```bash
# 1. Enable the application (generates config entries and files):
framework/scripts/enable-app.sh grafana

# 2. Edit your config files:
$EDITOR site/apps/grafana/datasources.yaml   # Set org, bucket
$EDITOR site/apps/grafana/grafana.ini        # Adjust settings if needed

# 3. Add secrets to SOPS:
sops --set '["grafana_admin_password"] "your-password"' site/sops/secrets.yaml
sops --set '["grafana_influxdb_token"] "'"$(sops -d --extract '["influxdb_admin_token"]' site/sops/secrets.yaml)"'"' site/sops/secrets.yaml

# 4. Add flake output to flake.nix:
#    grafana-image = mkImage [ ./site/nix/hosts/grafana.nix ];

# 5. Build and deploy:
framework/scripts/build-image.sh site/nix/hosts/grafana.nix grafana
framework/scripts/safe-apply.sh dev
```

## Configuration

### Layer 1: Framework integration (site/config.yaml)

Grafana is configured in the `applications:` block:

```yaml
applications:
  grafana:
    enabled: true
    node: pve03
    ram: 1024
    disk_size: 4
    data_disk_size: 4
    backup: false           # Dashboards can be provisioned from Git
    monitor: true
    health_port: 443
    health_path: "/api/health"
    environments:
      prod:
        ip: 10.0.10.56
        mac: "02:xx:xx:xx:xx:xx"
      dev:
        ip: 10.0.60.56
        mac: "02:xx:xx:xx:xx:xx"
```

### Layer 2: Application configuration (site/apps/grafana/)

#### grafana.ini (REQUIRED)

Grafana server configuration. TLS settings (cert paths, protocol, domain)
are injected automatically by the module — do NOT set them in grafana.ini.

The admin password is also injected via environment variable from SOPS.

```ini
[server]
http_port = 443

[security]
admin_user = admin

[auth.anonymous]
enabled = false
```

See: https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/

#### datasources.yaml (REQUIRED)

Data source provisioning. Uses the unqualified hostname `influxdb` for
environment-ignorant cross-service connections.

```yaml
apiVersion: 1
datasources:
  - name: InfluxDB
    type: influxdb
    access: proxy
    url: https://influxdb:8086
    jsonData:
      version: Flux
      organization: homelab
      defaultBucket: default
      tlsSkipVerify: true
    secureJsonData:
      token: ${INFLUXDB_TOKEN}
```

The `${INFLUXDB_TOKEN}` is Grafana's built-in env var substitution. The
catalog module reads the token from SOPS and sets the environment variable.

#### dashboards.yaml (OPTIONAL)

Dashboard provisioning config (which directories to scan for JSON files).

#### dashboards/ (OPTIONAL)

Directory of JSON dashboard files for automatic provisioning.

## Secrets

Grafana needs two pre-deploy secrets:

```bash
# Admin password
sops --set '["grafana_admin_password"] "your-password"' site/sops/secrets.yaml

# InfluxDB token (reuse admin token or create read-only token)
sops --set '["grafana_influxdb_token"] "token-value"' site/sops/secrets.yaml
```

Both are pre-deploy secrets — set by the operator, stable across deploys,
delivered via CIDATA write_files.

## Health Endpoint

`GET https://<ip>/api/health` returns `{"commit":"...","database":"ok","version":"..."}`.

## Data Persistence

All Grafana data is stored on vdb (`/var/lib/grafana`):
- SQLite database (users, dashboards, alert state)
- Plugins

vdb survives VM recreation. The format-vdb service creates ext4 on
first boot only.

## Build Errors

If a required file is missing or contains placeholder values, the NixOS
build fails with a message explaining what's needed:

- Missing `grafana.ini`: tells you what to put in it
- Missing `datasources.yaml`: shows a minimal example
- `grafana.ini` contains "CHANGEME": tells you to edit it
- `datasources.yaml` contains "CHANGEME": tells you to edit it
