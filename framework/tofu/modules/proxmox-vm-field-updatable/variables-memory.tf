# Memory variables that are local to proxmox-vm-field-updatable.
#
# variables.tf in this directory is a shared symlink to
# ../proxmox-vm/variables.tf. Keep ballooning inputs here so they do not leak
# into proxmox-vm or proxmox-vm-precious.

variable "ram_floating_mb" {
  description = "Balloon floor in MB; null omits floating and keeps the dedicated-only memory block."
  type        = number
  default     = null
  nullable    = true
}
