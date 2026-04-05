# --- VM ---

resource "proxmox_virtual_environment_vm" "vm" {
  vm_id     = var.vm_id
  name      = var.vm_name
  node_name = var.target_node

  # Force-stop before destroy so we never hang waiting for a non-responsive agent
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
  # Size must be >= the image's virtual size or Proxmox refuses to shrink.
  # Auto-sized NixOS images range from 3-10GB depending on the closure.
  # ignore_changes on disk[0].size prevents drift on subsequent applies.
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

  # Management NIC (optional — on vmbr1 for management network access)
  dynamic "network_device" {
    for_each = var.mgmt_nic != null ? [var.mgmt_nic] : []
    content {
      bridge      = "vmbr1"
      model       = "virtio"
      mac_address = network_device.value.mac_address
    }
  }

  # cloud-init via custom snippets (NoCloud)
  initialization {
    datastore_id      = var.storage_pool
    user_data_file_id = proxmox_virtual_environment_file.user_data[var.target_node].id
    meta_data_file_id = proxmox_virtual_environment_file.meta_data[var.target_node].id

    # NixOS doesn't consume Proxmox cloud-init network-config.
    # Network config is delivered via write_files and applied by
    # the configure-static-network service in base.nix.
    # Keep DHCP here so Proxmox doesn't generate unused static config.
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  on_boot = true
  started = true

  lifecycle {
    ignore_changes = [
      # Proxmox may change the disk size after import
      disk[0].size,
      # After HA failover, VMs run on surviving nodes. Without this,
      # tofu apply would destroy and recreate the VM (node_name is ForceNew).
      # Recovery path: rebalance-cluster.sh migrates VMs back to intended nodes.
      node_name,
      # initialization references node-specific snippet IDs; ignore to prevent
      # recreation when HA moves VMs to a different node. The snippet IDs
      # change when the target_node changes, but the CONTENT is the same.
      # Content changes are tracked separately via replace_triggered_by below.
      initialization,
    ]
    # Force VM recreation when CIDATA content changes. The initialization
    # block is ignored (for HA node migration), so we track snippet content
    # hashes via terraform_data. Any change to user_data or meta_data
    # content changes the hash, which triggers VM replacement.
    replace_triggered_by = [
      terraform_data.cidata_hash,
    ]
  }
}
