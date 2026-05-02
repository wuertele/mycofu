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
  # Trade-off: backup-enabled catalog apps stay on the base VM module for this
  # sprint. Moving them to proxmox-vm-precious changes prevent_destroy
  # semantics and needs separate DR review from the pool/tag contract work.
  source = "../../tofu/modules/proxmox-vm"

  vm_id               = var.vm_id
  vm_name             = "roon-${var.environment}"
  hostname            = "roon"
  instance_id         = "roon-${var.environment}"
  target_node         = var.target_node
  all_node_names      = var.all_node_names
  image_file_id       = var.image
  vlan_id             = var.vlan_id
  mac_address         = var.mac_address
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = var.operator_ssh_pubkey
  storage_pool        = var.storage_pool
  tags                = var.tags
  domain              = var.domain
  start_vms           = var.start_vms
  register_ha         = var.register_ha

  ssh_host_key_private = var.ssh_host_key_private
  ssh_host_key_public  = var.ssh_host_key_public
  extra_ca_cert        = var.extra_ca_cert

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
