# --- HA resource (conditional) ---

resource "proxmox_virtual_environment_haresource" "ha" {
  count = var.ha_enabled ? 1 : 0

  resource_id  = "vm:${proxmox_virtual_environment_vm.vm.vm_id}"
  state        = "started"
  comment      = "Managed by OpenTofu"
  max_restart  = 3
  max_relocate = 2

  depends_on = [proxmox_virtual_environment_vm.vm]
}
