# influxdb — Deploy an InfluxDB VM for one environment.
#
# Wraps the proxmox-vm base module with InfluxDB-specific defaults.
# Application configuration is baked into the NixOS image via configDir;
# only secrets are injected via CIDATA write_files.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

module "influxdb" {
  source = "../../tofu/modules/proxmox-vm"

  vm_id               = var.vm_id
  vm_name             = "influxdb-${var.environment}"
  hostname            = "influxdb"
  instance_id         = "influxdb-${var.environment}"
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

  ram_mb               = var.ram_mb
  cores                = var.cores
  vda_size_gb          = var.vda_size_gb
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
    },
    {
      path        = "/run/secrets/influxdb/admin-token"
      content     = var.influxdb_admin_token
      permissions = "0400"
    }
  ]
}
