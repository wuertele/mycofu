# --- HA resource (conditional) ---

resource "proxmox_virtual_environment_haresource" "ha" {
  count = var.ha_enabled && var.register_ha ? 1 : 0

  resource_id = "vm:${proxmox_virtual_environment_vm.vm.vm_id}"
  state       = "started"

  depends_on = [proxmox_virtual_environment_vm.vm]
}
