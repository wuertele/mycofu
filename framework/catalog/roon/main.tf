# roon — Deploy a Roon Server VM for one environment.
#
# Wraps the proxmox-vm base module with Roon-specific defaults.
# No TLS/certbot — Roon uses its own protocol.
# No app-specific secrets — Roon is configured via Roon Remote app.
# Management NIC on vmbr1 for RAAT multicast discovery.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

module "roon" {
  source = "../../tofu/modules/proxmox-vm"

  vm_id         = var.vm_id
  vm_name       = "roon-${var.environment}"
  hostname      = "roon"
  instance_id   = "roon-${var.environment}"
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

  ram_mb      = var.ram_mb
  cores       = var.cores
  vda_size_gb = var.vda_size_gb
  vdb_size_gb = var.vdb_size_gb
  ha_enabled  = true

  # Management NIC on vmbr1 for RAAT multicast discovery
  mgmt_nic = var.mgmt_nic

  # Network mounts (e.g., NFS music library)
  mounts = var.mounts

  write_files = []
}
