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

variable "vlan_id" {
  description = "VLAN ID (prod VLAN)"
  type        = number
}

variable "mac_address" {
  description = "Pre-assigned MAC address for DHCP reservation"
  type        = string
}

variable "image" {
  description = "Proxmox file ID for the Gatus image (e.g., local:iso/gatus-abc123.img)"
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

variable "gatus_config" {
  description = "Generated Gatus YAML config content (for write_files)"
  type        = string
}

variable "pdns_api_key" {
  description = "PowerDNS API key (for certbot DNS-01 challenges)"
  type        = string
  sensitive   = true
}

variable "acme_server_url" {
  description = "ACME directory URL (Let's Encrypt production)"
  type        = string
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

variable "extra_ca_cert" {
  description = "PEM content of the extra CA root delivered via CIDATA (empty = no extra CA)"
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


variable "vault_approle_role_id" {
  description = "Vault AppRole role_id for vault-agent"
  type        = string
  sensitive   = true
  default     = ""
}

variable "vault_approle_secret_id" {
  description = "Vault AppRole secret_id for vault-agent"
  type        = string
  sensitive   = true
  default     = ""
}
