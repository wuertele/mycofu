output "vm_id" {
  description = "Proxmox VM ID for the dev ACME VM"
  value       = module.acme_dev.vm_id
}

output "node_name" {
  description = "Proxmox node running the dev ACME VM"
  value       = module.acme_dev.node_name
}
