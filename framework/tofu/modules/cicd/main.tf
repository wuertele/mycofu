# cicd module — Deploy a GitLab Runner VM on the management network.
#
# The runner is Category 1 (fully rebuildable). No vdb, no precious state.
# Uses shell executor with all infrastructure CI/CD tools installed.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

# cicd is stateless — the runner holds no precious data of its own.
# VM recreation requires re-running register-runner.sh but loses no state.
# prevent_destroy is not needed. source = proxmox-vm (not proxmox-vm-precious).
module "cicd" {
  source = "../proxmox-vm"

  vm_id         = var.vm_id
  vm_name       = "cicd"
  hostname      = "cicd"
  instance_id   = "cicd"
  target_node    = var.target_node
  all_node_names = var.all_node_names
  image_file_id = var.image
  vlan_id       = null  # Management network (native/untagged)
  mac_address   = var.mac_address
  ssh_pubkey    = var.ssh_pubkey
  operator_ssh_pubkey = var.operator_ssh_pubkey
  storage_pool  = var.storage_pool
  domain        = var.domain

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

  write_files = concat(
    [
      {
        path        = "/run/secrets/gitlab-runner/gitlab-url"
        content     = var.gitlab_url
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
