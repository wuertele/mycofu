# --- VM (field-updatable variant) ---
#
# For control-plane VMs updated via converge-vm.sh --closure, not by
# VM recreation. Differs from proxmox-vm-precious in:
#
# - ignore_changes includes disk[0].file_id (image changes don't
#   trigger recreation — closures are pushed in-place)
# - replace_triggered_by is empty (CIDATA changes are absorbed via
#   overlay reboot, not VM recreation)
# - prevent_destroy = true (same as precious)
# - the memory block is elastic: this module — and ONLY this module —
#   can render `floating` (the balloon floor), via var.ram_floating_mb
#   declared in the module-local variables-memory.tf. See below.
#
# Otherwise the resource definitions, disk layout, network, and cloud-init
# match proxmox-vm-precious. If you change the SHARED resource structure,
# change it in proxmox-vm/vm.tf (or proxmox-vm-precious/vm.tf) and propagate
# here. The memory block is the ONE deliberate exception: do NOT propagate
# `floating` back into proxmox-vm/ or proxmox-vm-precious/. Those modules back
# every data-plane VM; giving them a floating memory attribute would plan an
# in-place memory diff across the fleet. (variables.tf here is a git SYMLINK to
# ../proxmox-vm/variables.tf, which is why ram_floating_mb lives in the separate
# real file variables-memory.tf and cannot leak into the other two modules.)
#
# Why a separate module instead of a variable? OpenTofu lifecycle blocks
# require fully static expressions — no variables, ternaries, concat(),
# or splats. The only way to have different lifecycle behavior is a
# different resource definition.
#
# Used by: gitlab, cicd, workstation-dev/prod

resource "proxmox_virtual_environment_vm" "vm" {
  vm_id     = var.vm_id
  name      = var.vm_name
  node_name = var.target_node
  tags      = var.tags

  stop_on_destroy     = true
  timeout_stop_vm     = 60
  timeout_shutdown_vm = 60

  agent {
    enabled = true
    timeout = "2m"
  }

  cpu {
    cores = var.cores
    type  = "host"
  }

  # P1 contract: bpg defaults memory.floating to 0 when ballooning is absent, and
  # PVE reads balloon:0 as "balloon device disabled". A coalesce(null, ram_mb)
  # fallback would instead render floating=ram_mb for the non-ballooned consumers
  # (gitlab [PRECIOUS], workstation) and plan a real in-place memory diff on them.
  # So the null path must stay byte-identical to the old dedicated-only block.
  # tests/test_cicd_memory_ballooning.sh ratchets that no-op against an untouched
  # proxmox-vm control instance, and carries a mutation self-check proving the
  # fixture would catch a regression here.
  dynamic "memory" {
    for_each = var.ram_floating_mb == null ? [var.ram_mb] : []
    content {
      dedicated = memory.value
    }
  }

  dynamic "memory" {
    for_each = var.ram_floating_mb == null ? [] : [{
      dedicated = var.ram_mb
      floating  = var.ram_floating_mb
    }]
    content {
      dedicated = memory.value.dedicated
      floating  = memory.value.floating
    }
  }

  # vda: OS disk imported from image.
  disk {
    datastore_id = var.storage_pool
    interface    = "scsi0"
    size         = var.vda_size_gb
    file_id      = var.image_file_id
    file_format  = "raw"
    discard      = "on"
    iothread     = true
  }

  # vdb: data disk (only if size > 0)
  dynamic "disk" {
    for_each = var.vdb_size_gb > 0 ? [1] : []
    content {
      datastore_id = var.storage_pool
      interface    = "scsi1"
      size         = var.vdb_size_gb
      file_format  = "raw"
      discard      = "on"
      iothread     = true
    }
  }

  scsi_hardware = "virtio-scsi-single"
  boot_order    = ["scsi0"]

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    vlan_id     = var.vlan_id
    mac_address = var.mac_address
  }

  dynamic "network_device" {
    for_each = var.mgmt_nic != null ? [var.mgmt_nic] : []
    content {
      bridge      = "vmbr1"
      model       = "virtio"
      mac_address = network_device.value.mac_address
    }
  }

  initialization {
    datastore_id      = var.storage_pool
    user_data_file_id = proxmox_virtual_environment_file.user_data[var.target_node].id
    meta_data_file_id = proxmox_virtual_environment_file.meta_data[var.target_node].id

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  on_boot = true
  started = var.start_vms

  lifecycle {
    # Field-updatable VMs have precious state AND are updated via
    # closure push, not VM recreation.
    prevent_destroy = true

    # Static ignore list — no concat(), no variables, no ternaries.
    # OpenTofu lifecycle blocks require fully static expressions.
    ignore_changes = [
      disk[0].size,    # Proxmox may resize after import
      disk[0].file_id, # Image updates via closure push, not recreation
      node_name,       # HA failover moves VMs between nodes
      initialization,  # Node-specific snippet IDs change on HA migration
    ]

    # No replace_triggered_by — CIDATA changes are absorbed via overlay
    # reboot, not VM recreation. The cidata_hash resource still exists
    # (count=0 when field_updatable=true in snippets.tf) but we don't
    # reference it here.

    # Null (every non-ballooned consumer) is always OK. A NON-null floor must be a
    # real float range: strictly between 0 and the ceiling.
    #   - floor >= ceiling: qemu would get balloon >= memory. Not a range.
    #   - floor == 0: PVE reads balloon:0 as "balloon device DISABLED", not "a floor
    #     of zero". A site that set 0 would look opted-in to ballooning and silently
    #     get a fixed VM instead — the failure this whole seam exists to avoid. Opting
    #     out is spelled "omit the key" (null), never "0".
    # This guards every site, including ones whose config.yaml the root module reads
    # through try(..., null).
    precondition {
      condition     = var.ram_floating_mb == null || (var.ram_floating_mb > 0 && var.ram_floating_mb < var.ram_mb)
      error_message = "ram_floating_mb (balloon floor) must be greater than 0 and below ram_mb (ceiling); got floor=${coalesce(var.ram_floating_mb, 0)} ceiling=${var.ram_mb}. To disable ballooning, omit ram_floating_mb entirely (null) — 0 means 'balloon device disabled' to PVE, which is not the same thing as a zero floor."
    }
  }
}
