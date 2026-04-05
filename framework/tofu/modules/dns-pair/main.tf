# dns-pair module — Deploy a redundant pair of DNS VMs for one environment.
#
# Anti-affinity: dns1 is placed on node_names[0], dns2 on node_names[1].
# This simple node-pinning approach is sufficient for home lab anti-affinity
# without needing the Proxmox Enterprise cluster scheduler.
#
# DNS VMs are Category 2 (zone data derived from config.yaml via CIDATA).
# No vdb data disk is needed — the SQLite database is disposable.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

module "dns1" {
  source = "../proxmox-vm"

  vm_id               = var.dns1_vm_id
  vm_name             = "dns1-${var.environment}"
  hostname            = "dns1"
  instance_id         = "dns1-${var.environment}"
  target_node         = var.node_names[0]
  all_node_names      = var.node_names
  image_file_id       = var.image
  vlan_id             = var.vlan_id
  mac_address         = var.dns1_mac
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = var.operator_ssh_pubkey
  storage_pool        = var.storage_pool
  domain              = var.domain
  extra_ca_cert       = var.extra_ca_cert

  ip_address    = var.dns1_ip
  gateway       = var.gateway_ip
  dns_servers   = var.dns_servers
  search_domain = var.search_domain

  # DNS VMs: 256MB RAM, 4GB OS disk, no data disk, HA enabled
  ram_mb      = 256
  cores       = 1
  vdb_size_gb = 0
  ha_enabled  = true

  vault_approle_role_id   = var.dns1_vault_approle_role_id
  vault_approle_secret_id = var.dns1_vault_approle_secret_id

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
      content     = "${var.dns1_ip}\n${var.dns2_ip}\n"
      permissions = "0400"
    },
    {
      path        = "/run/secrets/dns/recursor-ip"
      content     = var.gateway_ip
      permissions = "0400"
    },
    {
      path        = "/run/secrets/dns/forward-zone-domain"
      content     = var.dns_domain
      permissions = "0400"
    },
    {
      path        = "/run/secrets/dns/zone-data.json"
      content     = var.zone_data
      permissions = "0444"
    }
  ]
}

module "dns2" {
  source = "../proxmox-vm"

  vm_id               = var.dns2_vm_id
  vm_name             = "dns2-${var.environment}"
  hostname            = "dns2"
  instance_id         = "dns2-${var.environment}"
  target_node         = var.node_names[1]
  all_node_names      = var.node_names
  image_file_id       = var.image
  vlan_id             = var.vlan_id
  mac_address         = var.dns2_mac
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = var.operator_ssh_pubkey
  storage_pool        = var.storage_pool
  domain              = var.domain
  extra_ca_cert       = var.extra_ca_cert

  ip_address    = var.dns2_ip
  gateway       = var.gateway_ip
  dns_servers   = var.dns_servers
  search_domain = var.search_domain

  ram_mb      = 256
  cores       = 1
  vdb_size_gb = 0
  ha_enabled  = true

  vault_approle_role_id   = var.dns2_vault_approle_role_id
  vault_approle_secret_id = var.dns2_vault_approle_secret_id

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
      content     = "${var.dns1_ip}\n${var.dns2_ip}\n"
      permissions = "0400"
    },
    {
      path        = "/run/secrets/dns/recursor-ip"
      content     = var.gateway_ip
      permissions = "0400"
    },
    {
      path        = "/run/secrets/dns/forward-zone-domain"
      content     = var.dns_domain
      permissions = "0400"
    },
    {
      path        = "/run/secrets/dns/zone-data.json"
      content     = var.zone_data
      permissions = "0444"
    }
  ]
}
