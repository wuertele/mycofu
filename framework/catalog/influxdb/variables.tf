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
  description = "Proxmox file ID for the InfluxDB image"
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
  default     = 4
}

variable "vdb_size_gb" {
  description = "Data disk size in GB for InfluxDB storage"
  type        = number
  default     = 20
}

variable "dashboard_config_json" {
  description = "Runtime cluster dashboard config delivered via CIDATA"
  type        = string
}

variable "pdns_api_key" {
  description = "PowerDNS API key (for certbot DNS-01 challenges)"
  type        = string
  sensitive   = true
}

variable "acme_server_url" {
  description = "ACME directory URL (step-ca in dev, Let's Encrypt in prod)"
  type        = string
}

variable "extra_ca_cert" {
  description = "PEM content of the extra CA root delivered via CIDATA (empty = no extra CA)"
  type        = string
  default     = ""
}

variable "pdns_api_servers" {
  description = "DNS server IPs for certbot hooks (newline-separated)"
  type        = string
}

variable "influxdb_admin_token" {
  description = "InfluxDB admin API token (from SOPS)"
  type        = string
  sensitive   = true
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

variable "mgmt_nic" {
  description = "Optional management NIC for dashboard access to the Proxmox API"
  type = object({
    ip          = string
    mac_address = string
  })
  default = null
}

variable "ssh_host_key_private" {
  description = "SSH ed25519 host private key from SOPS (empty = ephemeral keys)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "ssh_host_key_public" {
  description = "SSH ed25519 host public key from SOPS (empty = ephemeral keys)"
  type        = string
  default     = ""
}

variable "vault_approle_role_id" {
  description = "Vault AppRole role_id for dashboard secret retrieval"
  type        = string
  default     = ""
}

variable "vault_approle_secret_id" {
  description = "Vault AppRole secret_id for dashboard secret retrieval"
  type        = string
  default     = ""
}
