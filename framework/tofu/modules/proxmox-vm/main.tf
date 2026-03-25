# proxmox-vm module — Deploy a NixOS VM to Proxmox with cloud-init snippets.
#
# This module handles: snippet upload, VM creation with disk import, and
# optional HA registration. Every infrastructure VM is an instance of this module.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

# --- cloud-init snippets ---
# Deploy to ALL nodes so HA can start the VM on any surviving node.
# Proxmox `local` storage is per-node — snippets must exist on every node.

locals {
  snippet_nodes = length(var.all_node_names) > 0 ? toset(var.all_node_names) : toset([var.target_node])

  # Automatically inject /run/secrets/domain into every VM's CIDATA.
  # This ensures a domain change in config.yaml triggers CIDATA hash changes
  # on ALL VMs, forcing universal recreation.
  all_write_files = concat(
    var.domain != "" ? [
      {
        path        = "/run/secrets/domain"
        content     = var.domain
        permissions = "0444"
      }
    ] : [],
    # Static network config — NixOS doesn't use Proxmox cloud-init
    # network-config (ip_config). Deliver via write_files instead.
    [
      {
        path        = "/run/secrets/network/mac"
        content     = var.mac_address
        permissions = "0444"
      },
      {
        path        = "/run/secrets/network/ip"
        content     = "${var.ip_address}/${var.subnet_mask}"
        permissions = "0444"
      },
      {
        path        = "/run/secrets/network/gateway"
        content     = var.gateway
        permissions = "0444"
      },
      {
        path        = "/run/secrets/network/dns"
        content     = join("\n", var.dns_servers)
        permissions = "0444"
      },
      {
        path        = "/run/secrets/network/search-domain"
        content     = var.search_domain
        permissions = "0444"
      }
    ],
    var.mgmt_nic != null ? [
      {
        path        = "/run/secrets/mgmt-ip"
        content     = var.mgmt_nic.ip
        permissions = "0444"
      },
      {
        path        = "/run/secrets/mgmt-mac"
        content     = var.mgmt_nic.mac_address
        permissions = "0444"
      }
    ] : [],
    length(var.mounts) > 0 ? [
      {
        path        = "/run/secrets/mounts.json"
        content     = jsonencode(var.mounts)
        permissions = "0444"
      }
    ] : [],
    var.write_files
  )
}

# Compute CIDATA content once — used for both snippet upload and hash tracking.
locals {
  # Combine framework key (SOPS) and operator key (config.yaml) for SSH access.
  # Both are installed so the CI runner and the operator can SSH to VMs.
  combined_ssh_pubkeys = compact([var.ssh_pubkey, var.operator_ssh_pubkey])

  user_data_content = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname    = var.hostname
    ssh_pubkeys = local.combined_ssh_pubkeys
    write_files = local.all_write_files
  })
  meta_data_content = templatefile("${path.module}/templates/meta-data.yaml.tftpl", {
    instance_id = var.instance_id
    hostname    = var.hostname
  })
}

# Track CIDATA content hash — triggers VM replacement when content changes.
# The initialization block is in ignore_changes (for HA node migration),
# so we use this resource to force recreation when CIDATA content changes.
resource "terraform_data" "cidata_hash" {
  input = {
    user_data = sha256(local.user_data_content)
    meta_data = sha256(local.meta_data_content)
  }
}

resource "proxmox_virtual_environment_file" "user_data" {
  for_each     = local.snippet_nodes
  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value

  source_raw {
    data      = local.user_data_content
    file_name = "${var.vm_name}-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_file" "meta_data" {
  for_each     = local.snippet_nodes
  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value

  source_raw {
    data      = local.meta_data_content
    file_name = "${var.vm_name}-meta-data.yaml"
  }
}

# --- VM ---

resource "proxmox_virtual_environment_vm" "vm" {
  vm_id     = var.vm_id
  name      = var.vm_name
  node_name = var.target_node

  # Force-stop before destroy so we never hang waiting for a non-responsive agent
  stop_on_destroy    = true
  timeout_stop_vm    = 60
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

# --- HA resource (conditional) ---

resource "proxmox_virtual_environment_haresource" "ha" {
  count = var.ha_enabled ? 1 : 0

  resource_id  = "vm:${proxmox_virtual_environment_vm.vm.vm_id}"
  state        = "started"
  comment      = "Managed by OpenTofu"
  max_restart  = 3
  max_relocate = 2

  depends_on = [proxmox_virtual_environment_vm.vm]
}
