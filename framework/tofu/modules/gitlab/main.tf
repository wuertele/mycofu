# gitlab module — Deploy a GitLab CE VM on the management network.
#
# GitLab is Category 3 (precious state) — vdb holds Git repositories.
# Uses Let's Encrypt TLS via certbot with explicit FQDN.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

module "gitlab" {
  source = "../proxmox-vm-precious"

  vm_id               = var.vm_id
  vm_name             = "gitlab"
  hostname            = "gitlab"
  instance_id         = "gitlab"
  target_node         = var.target_node
  all_node_names      = var.all_node_names
  image_file_id       = var.image
  vlan_id             = null # Management network (native/untagged)
  mac_address         = var.mac_address
  ssh_pubkey          = var.ssh_pubkey
  operator_ssh_pubkey = var.operator_ssh_pubkey
  storage_pool        = var.storage_pool
  domain              = var.domain

  ip_address    = var.ip_address
  gateway       = var.gateway
  dns_servers   = var.dns_servers
  search_domain = var.search_domain

  tailscale_auth_key = var.tailscale_auth_key

  vault_approle_role_id   = var.vault_approle_role_id
  vault_approle_secret_id = var.vault_approle_secret_id

  # GitLab: 6GB RAM, 2 cores, 12GB OS disk, 50GB data disk, HA enabled
  ram_mb               = var.ram_mb
  cores                = var.cores
  vdb_size_gb          = var.vdb_size_gb
  vdb_restore_expected = var.vdb_restore_expected
  ha_enabled           = true

  write_files = concat(
    [
      {
        path        = "/run/secrets/gitlab/external-url"
        content     = var.external_url
        permissions = "0400"
      },
      {
        path        = "/run/secrets/certbot/fqdn"
        content     = var.certbot_fqdn
        permissions = "0400"
      },
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
    ],
    var.smtp_config != "" ? [
      {
        path        = "/run/secrets/gitlab/smtp-config"
        content     = var.smtp_config
        permissions = "0400"
      }
    ] : []
  )
}
