# Workstation — Catalog Application

Field-updatable NixOS workstation VM with:

- persistent `/home` on `vdb`
- user-scoped Nix workflows (`nix-shell`, `nix profile install`)
- `home-manager` available as a system package
- Tailscale connectivity with per-environment identity paths
- Vault agent bootstrap for cluster secret access
- HTTPS health endpoint on `:8443/status`

## Configuration

`site/applications.yaml`:

```yaml
applications:
  workstation:
    enabled: true
    name: kenbox
    node: pve03
    username: kentaro
    shell: zsh
    ssh_public_key: "ssh-ed25519 AAAA... kentaro@laptop"
    ram_prod: 16384
    ram_dev: 4096
    cpus_prod: 8
    cpus_dev: 2
    # disk_size: optional, defaults to 16 GB. Must be >= the workstation
    # image partition size (~5 GB). Do not set below the image; Proxmox
    # will reject the resize. See issue #276.
    data_disk_size_prod: 500
    data_disk_size_dev: 80
    backup: true
    monitor: true
    health_port: 8443
    health_path: "/status"
    environments:
      prod:
        vmid: 801
        ip: 172.27.10.58
        mac: "02:9a:4b:88:31:0a"
        pool: prod
      dev:
        vmid: 701
        ip: 172.27.60.58
        mac: "02:3d:92:57:41:1c"
        pool: dev
        mgmt_nic:
          name: "workstation-mgmt"
          ip: 172.17.77.68
          mac: "02:7e:2f:b1:64:20"
```

The workstation uses the `proxmox-vm-field-updatable` path, so software
updates are delivered by closure push and reboot rather than VM recreation.

## Health Endpoint

`GET https://<ip-or-mgmt-ip>:8443/status`

Returns HTTP `200` only when:

- `/home` is mounted
- the configured user home directory exists
- `/home` has free space above the threshold
- `nix-shell -p hello --run hello` succeeds
- `vault-agent` has an authenticated token

Otherwise nginx returns `503` and the last JSON payload remains available on
disk at `/run/workstation-health/status.json`.
