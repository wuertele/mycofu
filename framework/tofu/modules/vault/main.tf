# vault module — Deploy a Vault VM for one environment.
#
# Single instance per environment, protected by Proxmox HA.
# Vault is Category 3 (precious state) — vdb holds Raft storage.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

module "vault" {
  source = "../proxmox-vm"

  vm_id               = var.vm_id
  vm_name             = "vault-${var.environment}"
  hostname            = "vault"
  instance_id         = "vault-${var.environment}"
  target_node         = var.target_node
  all_node_names      = var.all_node_names
  image_file_id       = var.image
  vlan_id             = var.vlan_id
  mac_address         = var.mac_address
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = var.operator_ssh_pubkey
  storage_pool        = var.storage_pool
  domain              = var.domain
  extra_ca_cert       = var.extra_ca_cert

  ip_address    = var.ip_address
  gateway       = var.gateway
  dns_servers   = var.dns_servers
  search_domain = var.search_domain

  # Vault: 512MB RAM, 4GB OS disk, 10GB data disk (Raft), HA enabled
  ram_mb               = 512
  cores                = 1
  vdb_size_gb          = var.vdb_size_gb
  vdb_restore_expected = var.vdb_restore_expected
  ha_enabled           = true

  write_files = [
    {
      path        = "/run/secrets/certbot/pdns-api-key"
      content     = var.pdns_api_key
      permissions = "0400"
    },
    {
      path        = "/run/secrets/certbot/acme-server-url"
      content     = var.acme_server_url
      permissions = "0400"
    },
    {
      path        = "/run/secrets/certbot/pdns-api-servers"
      content     = var.pdns_api_servers
      permissions = "0400"
    }
  ]
}
