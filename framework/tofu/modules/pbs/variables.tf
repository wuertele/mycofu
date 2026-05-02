variable "vm_id" {
  description = "Proxmox VM ID (pinned, from config.yaml)"
  type        = number
}

variable "target_node" {
  description = "Proxmox node to deploy to"
  type        = string
}

variable "vlan_id" {
  description = "VLAN ID for the VM's network interface. Null = native/untagged (management network)."
  type        = number
  default     = null
}

variable "mac_address" {
  description = "Pre-assigned MAC address (02:xx:xx format from config.yaml)"
  type        = string
}

variable "iso_file" {
  description = "Proxmox file ID for the PBS ISO (e.g., local:iso/proxmox-backup-server_3.3-1.iso). Set to empty string after installation to detach."
  type        = string
  default     = ""
}

variable "ram_mb" {
  description = "RAM in megabytes"
  type        = number
  default     = 2048
}

variable "cores" {
  description = "CPU cores"
  type        = number
  default     = 2
}

variable "vda_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 32
}

variable "storage_pool" {
  description = "ZFS pool name for VM disks"
  type        = string
  default     = "local-zfs"
}

variable "tags" {
  description = "Proxmox VM tags"
  type        = list(string)
}

variable "ha_enabled" {
  description = "Whether to create an HA resource for this VM"
  type        = bool
  default     = true
}
