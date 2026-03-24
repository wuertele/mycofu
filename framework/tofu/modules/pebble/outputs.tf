output "vm_id" {
  description = "Proxmox VM ID for the Pebble VM"
  value       = module.pebble.vm_id
}

output "node_name" {
  description = "Proxmox node running Pebble"
  value       = module.pebble.node_name
}
