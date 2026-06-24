variable "vm_id" {
  description = "Proxmox VM ID (pinned, from applications.yaml)"
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
  description = "Proxmox file ID for the workstation image"
  type        = string
}

variable "ssh_pubkey" {
  description = "Framework SSH public key for root access"
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

variable "tags" {
  description = "Proxmox VM tags"
  type        = list(string)
}

variable "start_vms" {
  description = "Whether OpenTofu should start managed NixOS VMs."
  type        = bool
  default     = true
}

variable "register_ha" {
  description = "Whether OpenTofu should register VM HA resources."
  type        = bool
  default     = true
}

variable "ram_mb" {
  description = "RAM in MB"
  type        = number
  default     = 4096
}

variable "cores" {
  description = "CPU cores"
  type        = number
  default     = 2
}

variable "vda_size_gb" {
  description = "OS disk size in GB. Must be >= the workstation image partition size. The OS disk is ephemeral (rebuilt from image on every deploy) so oversizing is harmless. 16 GB matches proxmox-vm-field-updatable's default and gives generous headroom over the ~5 GB workstation closure. Do not set to null — the proxmox provider rejects null disk sizes."
  type        = number
  default     = 16
}

variable "vdb_size_gb" {
  description = "Home disk size in GB"
  type        = number
  default     = 80
}

variable "username" {
  description = "Initial workstation username delivered via CIDATA"
  type        = string
}

variable "shell" {
  description = "Initial workstation login shell delivered via CIDATA"
  type        = string
}

variable "user_ssh_public_key" {
  description = "Initial user SSH public key delivered via CIDATA"
  type        = string
}

variable "pdns_api_key" {
  description = "PowerDNS API key for certbot DNS-01 challenges"
  type        = string
  sensitive   = true
}

variable "acme_server_url" {
  description = "ACME directory URL"
  type        = string
}

variable "extra_ca_cert" {
  description = "PEM content of the extra CA root delivered via CIDATA"
  type        = string
  default     = ""
}

variable "pdns_api_servers" {
  description = "DNS server IPs for certbot hooks (newline-separated)"
  type        = string
}

variable "domain" {
  description = "Base domain written to CIDATA"
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

variable "mgmt_nic" {
  description = "Optional management NIC for cross-network monitoring"
  type = object({
    ip          = string
    mac_address = string
  })
  default = null
}

variable "tailscale_auth_key" {
  description = "Tailscale reusable pre-auth key"
  type        = string
  default     = ""
  sensitive   = true
}

variable "vault_approle_role_id" {
  description = "Vault AppRole role_id for workstation secret retrieval"
  type        = string
  default     = ""
  sensitive   = true
}

variable "vault_approle_secret_id" {
  description = "Vault AppRole secret_id for workstation secret retrieval"
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_host_key_private" {
  description = "SSH ed25519 host private key from SOPS"
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_host_key_public" {
  description = "SSH ed25519 host public key from SOPS"
  type        = string
  default     = ""
}
