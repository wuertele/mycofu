# acme-dev module — Deploy the dev ACME VM (step-ca).
#
# Single VM, stateless (Category 1). No vdb, no custom snippets beyond the
# generic CIDATA content handled by proxmox-vm.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

module "acme_dev" {
  source = "../proxmox-vm"

  vm_id               = var.vm_id
  vm_name             = "acme-dev"
  hostname            = "acme"
  instance_id         = "acme-dev"
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

  # Dev ACME: 256MB RAM, 4GB OS disk, no data disk, HA enabled
  ram_mb      = 256
  cores       = 1
  vdb_size_gb = 0
  ha_enabled  = true
}
