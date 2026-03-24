# pebble module — Deploy the Pebble ACME test server VM (dev-only).
#
# Single VM, stateless (Category 1). No vdb, no secrets injection.
# Pebble reads its config from the NixOS-managed filesystem.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

module "pebble" {
  source = "../proxmox-vm"

  vm_id         = var.vm_id
  vm_name       = "pebble"
  hostname      = "pebble"
  instance_id   = "pebble"
  target_node    = var.target_node
  all_node_names = var.all_node_names
  image_file_id = var.image
  vlan_id       = var.vlan_id
  mac_address   = var.mac_address
  ssh_pubkey    = var.ssh_pubkey
  operator_ssh_pubkey = var.operator_ssh_pubkey
  storage_pool  = var.storage_pool
  domain        = var.domain

  ip_address    = var.ip_address
  gateway       = var.gateway
  dns_servers   = var.dns_servers
  search_domain = var.search_domain

  # Pebble: 256MB RAM, 4GB OS disk, no data disk, HA enabled
  ram_mb      = 256
  cores       = 1
  vda_size_gb = 4
  vdb_size_gb = 0
  ha_enabled  = true

  write_files = [
    {
      path        = "/run/pebble/dns-server"
      content     = var.dns_server
      permissions = "0444"
    }
  ]
}
