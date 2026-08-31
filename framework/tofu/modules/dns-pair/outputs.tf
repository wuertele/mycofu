output "dns1_vmid" {
  description = "Proxmox VM ID for dns1"
  value       = module.dns1.vm_id
}

output "dns2_vmid" {
  description = "Proxmox VM ID for dns2"
  value       = module.dns2.vm_id
}

output "dns1_ip" {
  description = "IP address of dns1"
  value       = var.dns1_ip
}

output "dns2_ip" {
  description = "IP address of dns2"
  value       = var.dns2_ip
}

output "dns1_node" {
  description = "Proxmox node running dns1"
  value       = module.dns1.node_name
}

output "dns2_node" {
  description = "Proxmox node running dns2"
  value       = module.dns2.node_name
}
