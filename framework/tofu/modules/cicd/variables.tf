variable "vm_id" {
  description = "Proxmox VM ID (pinned, from config.yaml)"
  type        = number
}

variable "target_node" {
  description = "Proxmox node to deploy to"
  type        = string
}

variable "all_node_names" {
  description = "All Proxmox node names (for HA snippet replication)"
  type        = list(string)
  default     = []
}

variable "mac_address" {
  description = "Pre-assigned MAC address for DHCP reservation"
  type        = string
}

variable "image" {
  description = "Proxmox file ID for the Runner image (e.g., local:iso/cicd-abc123.img)"
  type        = string
}

variable "ssh_pubkey" {
  description = "Operator SSH public key for cloud-init"
  type        = string
}

variable "operator_ssh_pubkey" {
  description = "Operator workstation SSH public key from config.yaml"
  type        = string
  default     = ""
}

variable "storage_pool" {
  description = "ZFS pool name for VM disks"
  type        = string
  default     = "local-zfs"
}

variable "ram_mb" {
  description = "RAM in megabytes (4096 for builds)"
  type        = number
  default     = 4096
}

variable "cores" {
  description = "CPU cores"
  type        = number
  default     = 2
}

variable "gitlab_url" {
  description = "GitLab instance URL (e.g., https://gitlab.prod.example.com)"
  type        = string
}

variable "sops_age_key" {
  description = "SOPS age private key for decrypting secrets during pipeline runs"
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssh_privkey" {
  description = "SSH private key for runner to access Proxmox nodes and VMs"
  type        = string
  sensitive   = true
  default     = ""
}

variable "domain" {
  description = "Base domain (written to CIDATA to trigger recreation on domain change)"
  type        = string
  default     = ""
}

variable "ip_address" {
  description = "Static IPv4 address for the primary NIC"
  type        = string
}

variable "gateway" {
  description = "Default gateway"
  type        = string
}

variable "dns_servers" {
  description = "DNS server IPs"
  type        = list(string)
  default     = []
}

variable "search_domain" {
  description = "DNS search domain"
  type        = string
  default     = ""
}

