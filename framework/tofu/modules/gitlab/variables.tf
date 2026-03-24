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
  description = "Proxmox file ID for the GitLab image (e.g., local:iso/gitlab-abc123.img)"
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
  description = "RAM in megabytes (GitLab needs headroom for Puma + Sidekiq + rake tasks)"
  type        = number
  default     = 6144
}

variable "cores" {
  description = "CPU cores"
  type        = number
  default     = 2
}

variable "vdb_size_gb" {
  description = "Data disk size in GB for Git repositories"
  type        = number
  default     = 50
}

variable "external_url" {
  description = "GitLab external URL (e.g., https://gitlab.prod.example.com)"
  type        = string
}

variable "certbot_fqdn" {
  description = "Explicit FQDN for certbot (e.g., gitlab.prod.example.com)"
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
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "pdns_api_servers" {
  description = "DNS server IPs for certbot hooks (newline-separated)"
  type        = string
}

variable "smtp_config" {
  description = "SMTP configuration (host:port:from, or empty to skip)"
  type        = string
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

