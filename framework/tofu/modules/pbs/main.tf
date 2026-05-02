# pbs module — Deploy a Proxmox Backup Server VM.
#
# PBS is a vendor appliance (official Proxmox ISO), NOT a NixOS VM.
# No cloud-init, no nocloud-init, no write_files. The VM boots from the ISO
# for initial installation, then runs from the installed OS disk.
#
# After installation, detach the ISO by setting iso_file to "" and re-applying.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  vm_id     = var.vm_id
  name      = "pbs"
  node_name = var.target_node
  tags      = var.tags

  stop_on_destroy     = true
  timeout_stop_vm     = 60
  timeout_shutdown_vm = 60

  # PBS is a vendor appliance — qemu-guest-agent may not be installed.
  # Disable the agent to prevent tofu from hanging on network interface queries.
  agent {
    enabled = false
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.ram_mb
  }

  # vda: OS disk (installed from ISO)
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.vda_size_gb
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  scsi_hardware = "virtio-scsi-single"
  # Boot from CD-ROM first during installation, then hard disk after
  boot_order = var.iso_file != "" ? ["ide3", "scsi0"] : ["scsi0"]

  # CD-ROM: PBS ISO for installation (set iso_file = "" after install to detach)
  dynamic "cdrom" {
    for_each = var.iso_file != "" ? [1] : []
    content {
      file_id = var.iso_file
    }
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    vlan_id     = var.vlan_id # null = native/untagged (management network)
    mac_address = var.mac_address
  }

  # Sprint 031 vendor-appliance exception: PBS is not a reusable NixOS VM
  # module, so it intentionally does not consume start_vms/register_ha.
  on_boot = true
  started = true

  # PBS is a vendor appliance — Proxmox retains the ide3 CD-ROM device even
  # after the ISO is detached.  The provider reads back ide3 in boot_order and
  # a disabled cdrom block, creating a perpetual diff against our config (which
  # omits both when iso_file = "").  Ignore these installation artifacts.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [boot_order, cdrom]
  }
}

# --- HA resource ---

resource "proxmox_virtual_environment_haresource" "ha" {
  count = var.ha_enabled ? 1 : 0

  resource_id = "vm:${proxmox_virtual_environment_vm.vm.vm_id}"
  state       = "started"

  depends_on = [proxmox_virtual_environment_vm.vm]
}
