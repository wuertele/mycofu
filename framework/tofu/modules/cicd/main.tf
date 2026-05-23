# cicd module — Deploy a GitLab Runner VM on the management network.
#
# The runner is field-updatable and uses shell executor with all
# infrastructure CI/CD tools installed.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

# cicd stays operationally field-updatable even though its own state is
# rebuildable. The precious module provides lifecycle protection so image and
# CIDATA drift can be handled with converge-vm.sh instead of recreation.
module "cicd" {
  source = "../proxmox-vm-field-updatable"

  vm_id               = var.vm_id
  vm_name             = "cicd"
  hostname            = "cicd"
  instance_id         = "cicd"
  target_node         = var.target_node
  all_node_names      = var.all_node_names
  image_file_id       = var.image
  vlan_id             = null # Management network (native/untagged)
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

  ip_address    = var.ip_address
  gateway       = var.gateway
  dns_servers   = var.dns_servers
  search_domain = var.search_domain

  # Runner: 4GB RAM, 2 cores, 192GB OS disk (nix store for builds), no data disk, HA enabled
  ram_mb      = var.ram_mb
  cores       = var.cores
  vda_size_gb = 192
  vdb_size_gb = 0
  ha_enabled  = true

  vault_approle_role_id   = var.vault_approle_role_id
  vault_approle_secret_id = var.vault_approle_secret_id

  write_files = concat(
    [
      {
        path        = "/run/secrets/gitlab-runner/gitlab-url"
        content     = var.gitlab_url
        permissions = "0400"
      },
      {
        path        = "/run/secrets/github/remote-url"
        content     = var.github_remote_url
        permissions = "0400"
      }
    ],
    var.sops_age_key != "" ? [
      {
        path        = "/run/secrets/sops/age-key"
        content     = var.sops_age_key
        permissions = "0400"
      }
    ] : [],
    var.ssh_privkey != "" ? [
      {
        path        = "/run/secrets/gitlab-runner/ssh-privkey"
        content     = var.ssh_privkey
        permissions = "0400"
      }
    ] : []
  )
}
