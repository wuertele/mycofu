variable "vm_id" {
  description = "Proxmox VM ID (pinned, from config.yaml)"
  type        = number
}

variable "environment" {
  description = "Environment name: prod or dev"
  type        = string

  validation {
    condition     = contains(["prod", "dev"], var.environment)
    error_message = "environment must be 'prod' or 'dev'"
  }
}

variable "all_node_names" {
  description = "All Proxmox node names (for HA snippet replication)"
  type        = list(string)
  default     = []
}

variable "target_node" {
  description = "Proxmox node to deploy to"
  type        = string
}

variable "vlan_id" {
  description = "VLAN ID for the environment"
  type        = number
}

variable "mac_address" {
  description = "Pre-assigned MAC address for DHCP reservation"
  type        = string
}

variable "image" {
  description = "Proxmox file ID for the Vault image (e.g., local:iso/vault-abc123.img)"
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

variable "vdb_size_gb" {
  description = "Data disk size in GB for Raft storage"
  type        = number
  default     = 10
}

variable "pdns_api_key" {
  description = "PowerDNS API key (for certbot DNS-01 challenges)"
  type        = string
  sensitive   = true
}

variable "acme_server_url" {
  description = "ACME directory URL (Pebble in dev, Let's Encrypt in prod)"
  type        = string
}

variable "acme_ca_cert" {
  description = "PEM content of the ACME CA cert (empty = use system CA bundle)"
  type        = string
  default     = ""
}

variable "pdns_api_servers" {
  description = "DNS server IPs for certbot hooks (newline-separated)"
  type        = string
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

