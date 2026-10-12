output "vm_id" {
  description = "Proxmox VM ID (numeric)"
  value       = proxmox_virtual_environment_vm.vm.vm_id
}

output "vm_name" {
  description = "VM name (pass-through for chaining)"
  value       = proxmox_virtual_environment_vm.vm.name
}

output "node_name" {
  description = "Node the VM was placed on"
  value       = proxmox_virtual_environment_vm.vm.node_name
}
