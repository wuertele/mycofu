# proxmox-vm module — Deploy a NixOS VM to Proxmox with cloud-init snippets.
#
# This module handles: snippet upload, VM creation with disk import, and
# optional HA registration. Every infrastructure VM is an instance of this module.

terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

# --- cloud-init snippets ---
# Deploy to ALL nodes so HA can start the VM on any surviving node.
# Proxmox `local` storage is per-node — snippets must exist on every node.

locals {
  snippet_nodes = length(var.all_node_names) > 0 ? toset(var.all_node_names) : toset([var.target_node])

  # Automatically inject /run/secrets/domain into every VM's CIDATA.
  # This ensures a domain change in config.yaml triggers CIDATA hash changes
  # on ALL VMs, forcing universal recreation.
  all_write_files = concat(
    var.domain != "" ? [
      {
        path        = "/run/secrets/domain"
        content     = var.domain
        permissions = "0444"
      }
    ] : [],
    # Static network config — NixOS doesn't use Proxmox cloud-init
    # network-config (ip_config). Deliver via write_files instead.
    [
      {
        path        = "/run/secrets/network/mac"
        content     = var.mac_address
        permissions = "0444"
      },
      {
        path        = "/run/secrets/network/ip"
        content     = "${var.ip_address}/${var.subnet_mask}"
        permissions = "0444"
      },
      {
        path        = "/run/secrets/network/gateway"
        content     = var.gateway
        permissions = "0444"
      },
      {
        path        = "/run/secrets/network/dns"
        content     = join("\n", var.dns_servers)
        permissions = "0444"
      },
      {
        path        = "/run/secrets/network/search-domain"
        content     = var.search_domain
        permissions = "0444"
      }
    ],
    var.mgmt_nic != null ? [
      {
        path        = "/run/secrets/mgmt-ip"
        content     = var.mgmt_nic.ip
        permissions = "0444"
      },
      {
        path        = "/run/secrets/mgmt-mac"
        content     = var.mgmt_nic.mac_address
        permissions = "0444"
      }
    ] : [],
    length(var.mounts) > 0 ? [
      {
        path        = "/run/secrets/mounts.json"
        content     = jsonencode(var.mounts)
        permissions = "0444"
      }
    ] : [],
    var.tailscale_auth_key != "" ? [
      {
        path        = "/run/secrets/tailscale/auth-key"
        content     = var.tailscale_auth_key
        permissions = "0400"
      }
    ] : [],
    var.extra_ca_cert != "" ? [
      {
        path        = "/run/secrets/extra-ca-cert"
        content     = var.extra_ca_cert
        permissions = "0400"
      }
    ] : [],
    var.vault_approle_role_id != "" ? [
      {
        path        = "/run/secrets/vault/role-id"
        content     = var.vault_approle_role_id
        permissions = "0400"
      },
      {
        path        = "/run/secrets/vault/secret-id"
        content     = var.vault_approle_secret_id
        permissions = "0400"
      }
    ] : [],
    var.vdb_restore_expected ? [
      {
        path        = "/run/secrets/vdb-restore-expected"
        content     = "true"
        permissions = "0444"
      }
    ] : [],
    var.write_files
  )
}

# Compute CIDATA content once — used for both snippet upload and hash tracking.
locals {
  # Combine framework key (SOPS) and operator key (config.yaml) for SSH access.
  # Both are installed so the CI runner and the operator can SSH to VMs.
  combined_ssh_pubkeys = compact([var.ssh_pubkey, var.operator_ssh_pubkey])

  user_data_content = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname    = var.hostname
    ssh_pubkeys = local.combined_ssh_pubkeys
    write_files = local.all_write_files
  })
  meta_data_content = templatefile("${path.module}/templates/meta-data.yaml.tftpl", {
    instance_id = var.instance_id
    hostname    = var.hostname
  })
}

# Track CIDATA content hash — triggers VM replacement when content changes.
# The initialization block is in ignore_changes (for HA node migration),
# so we use this resource to force recreation when CIDATA content changes.
resource "terraform_data" "cidata_hash" {
  input = {
    user_data = sha256(local.user_data_content)
    meta_data = sha256(local.meta_data_content)
  }
}

resource "proxmox_virtual_environment_file" "user_data" {
  for_each     = local.snippet_nodes
  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value

  source_raw {
    data      = local.user_data_content
    file_name = "${var.vm_name}-user-data.yaml"
  }
}

resource "proxmox_virtual_environment_file" "meta_data" {
  for_each     = local.snippet_nodes
  content_type = "snippets"
  datastore_id = "local"
  node_name    = each.value

  source_raw {
    data      = local.meta_data_content
    file_name = "${var.vm_name}-meta-data.yaml"
  }
}
