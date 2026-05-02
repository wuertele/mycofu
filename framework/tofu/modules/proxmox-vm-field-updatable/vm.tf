# --- VM (field-updatable variant) ---
#
# For control-plane VMs updated via converge-vm.sh --closure, not by
# VM recreation. Differs from proxmox-vm-precious in lifecycle only:
#
# - ignore_changes includes disk[0].file_id (image changes don't
#   trigger recreation — closures are pushed in-place)
# - replace_triggered_by is empty (CIDATA changes are absorbed via
#   overlay reboot, not VM recreation)
# - prevent_destroy = true (same as precious)
#
# Everything else (resource definitions, disk layout, network, cloud-init)
# is identical to proxmox-vm-precious. If you change the resource
# structure, change it in proxmox-vm/vm.tf (or proxmox-vm-precious/vm.tf)
# and propagate here.
#
# Why a separate module instead of a variable? OpenTofu lifecycle blocks
# require fully static expressions — no variables, ternaries, concat(),
# or splats. The only way to have different lifecycle behavior is a
# different resource definition.
#
# Used by: gitlab, cicd

resource "proxmox_virtual_environment_vm" "vm" {
  vm_id     = var.vm_id
  name      = var.vm_name
  node_name = var.target_node
  tags      = var.tags

  stop_on_destroy     = true
  timeout_stop_vm     = 60
  timeout_shutdown_vm = 60

  agent {
    enabled = true
    timeout = "2m"
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  memory {
    dedicated = var.ram_mb
  }

  # vda: OS disk imported from image.
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.vda_size_gb
    file_id      = var.image_file_id
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  # vdb: data disk (only if size > 0)
  dynamic "disk" {
    for_each = var.vdb_size_gb > 0 ? [1] : []
    content {
      datastore_id = var.storage_pool
      interface    = "scsi1"
      size         = var.vdb_size_gb
      file_format  = "raw"
      discard      = "on"
      iothread     = true
    }
  }

  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    vlan_id     = var.vlan_id
    mac_address = var.mac_address
  }

  dynamic "network_device" {
    for_each = var.mgmt_nic != null ? [var.mgmt_nic] : []
    content {
      bridge      = "vmbr1"
      model       = "virtio"
      mac_address = network_device.value.mac_address
    }
  }

  initialization {
    datastore_id      = var.storage_pool
    user_data_file_id = proxmox_virtual_environment_file.user_data[var.target_node].id
    meta_data_file_id = proxmox_virtual_environment_file.meta_data[var.target_node].id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  on_boot = true
  started = var.start_vms

  lifecycle {
    # Field-updatable VMs have precious state AND are updated via
    # closure push, not VM recreation.
    prevent_destroy = true

    # Static ignore list — no concat(), no variables, no ternaries.
    # OpenTofu lifecycle blocks require fully static expressions.
    ignore_changes = [
      disk[0].size,    # Proxmox may resize after import
      disk[0].file_id, # Image updates via closure push, not recreation
      node_name,       # HA failover moves VMs between nodes
      initialization,  # Node-specific snippet IDs change on HA migration
    ]

    # No replace_triggered_by — CIDATA changes are absorbed via overlay
    # reboot, not VM recreation. The cidata_hash resource still exists
    # (count=0 when field_updatable=true in snippets.tf) but we don't
    # reference it here.
  }
}
