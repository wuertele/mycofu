# Application Catalog

Pre-built application modules that operators enable via config.yaml and
deploy through the standard pipeline.

## How to Enable an Application

1. Run `framework/scripts/enable-app.sh <app-name>` — adds the entry to
   `site/config.yaml`, generates host .nix, copies example configs
2. Edit the generated config files in `site/apps/<app-name>/`
3. Add secrets to SOPS
4. Add the flake output to `flake.nix`
5. Build and deploy with the standard pipeline or `safe-apply.sh`; backup-backed
   apps use the Sprint 031 preboot restore flow on recreation

## Config.yaml Schema

Applications are declared in the `applications:` block in `site/config.yaml`:

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

- **Shared properties** (node, ram, disk sizes, backup, monitoring) are
  declared once, not duplicated per environment
- **Per-environment properties** (IP, MAC) are nested under `environments:`
- **`enabled: true/false`** allows an application to exist in config.yaml
  without being deployed
- **Machine-readable metadata** (health_port, health_path, backup, monitor)
  is used directly by scripts — no per-application hardcoding needed

The build system (`build-all-images.sh`) derives the application build list
from this block. Catalog applications do NOT need entries in `site/images.yaml`.

## Two-Layer Configuration

**Layer 1: Framework integration** (`site/config.yaml`)

Standard VM fields the framework needs to deploy and integrate the
application: IP, MAC, node, disk sizes, backup, monitoring. Defined in
the `applications:` block (separate from infrastructure VMs in `vms:`).

**Layer 2: Application configuration** (`site/apps/<app-name>/`)

Native application config files. The catalog module knows where each
file belongs on the VM filesystem and places it there. The operator
provides content; the module provides placement.

The `configDir` NixOS option points at the operator's config directory.
The module maps recognized filenames to their standard locations:

```nix
services.<app>.configDir = ../../../site/apps/<app>;
```

## Required vs Optional Files

Each catalog module declares which config files are REQUIRED and which
are optional. If a required file is missing, the NixOS build fails with
a clear error message — not a silent default.

If a required file exists but contains placeholder values (CHANGEME),
the build also fails. The operator must make deliberate configuration
choices before the application will build.

## Adding a New Application to the Catalog

Create `framework/catalog/<app-name>/` with:

```
framework/catalog/<app-name>/
  module.nix           — NixOS module (configDir option, file placement, service)
  main.tf              — OpenTofu module (wraps proxmox-vm)
  variables.tf         — OpenTofu variables (standard app interface)
  outputs.tf           — OpenTofu outputs (vm_id)
  host.nix.template    — Template for site/nix/hosts/<app>.nix
  config.example/      — Example config files (with .example suffix)
  README.md            — How to enable, configure, and use
```

The module.nix pattern:
1. Define `services.<app>.configDir` option
2. Assert required files exist (with helpful error messages)
3. Assert no CHANGEME placeholders in required files
4. Map config files to VM filesystem locations
5. Mount vdb for persistent data (if stateful)
6. Import certbot.nix for TLS
7. Configure the application service
8. Run initial setup on first boot (if needed)
9. Open firewall ports

The main.tf pattern:
1. Wrap `proxmox-vm` with application defaults
2. Pass secrets via `write_files` to `/run/secrets/<app>/`
3. Pass certbot secrets (pdns key, ACME URL, CA cert)
