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
  #
  # Sprint 047 M1 (pbs 190 replication opt-in): pbs can now succeed at HA
  # failover to a survivor (before M1 the failover landed in HA `error` because
  # no replica existed, so this class of drift was blocked upstream). Without
  # `node_name` in ignore_changes, the next full-scope `tofu apply` after a
  # pbs HA failover would see `pvesh get /cluster/resources` reporting pbs on
  # the survivor and plan destroy+recreate (`node_name` is ForceNew), which
  # `prevent_destroy = true` then refuses — deadlocking the apply until the
  # operator manually runs `rebalance-cluster.sh`. Mirror the
  # `proxmox-vm-precious` module's ignore_changes list (`vm.tf:112-121`) so
  # tofu apply survives an HA-migrated pbs the same way it survives an
  # HA-migrated precious VM. `disk[0].size` is defensive against provider
  # readback rounding on the OS zvol; `initialization` is intentionally
  # omitted because pbs has no cloud-init block.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [boot_order, cdrom, node_name, disk[0].size]
  }
}

# --- HA resource ---

resource "proxmox_virtual_environment_haresource" "ha" {
  count = var.ha_enabled ? 1 : 0

  resource_id = "vm:${proxmox_virtual_environment_vm.vm.vm_id}"
  state       = "started"

  # See framework/tofu/modules/proxmox-vm/ha.tf for the #691 rationale.
  # pbs (VMID 190) is normally policy-on (opted in via the site config), so
  # this defaults to null → zero plan diff. Wired symmetrically so a future
  # policy change on PBS flows through the same variable.
  max_restart  = var.replication_policy_on == false ? 0 : null
  max_relocate = var.replication_policy_on == false ? 0 : null

  depends_on = [proxmox_virtual_environment_vm.vm]
}
