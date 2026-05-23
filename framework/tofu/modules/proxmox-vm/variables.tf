variable "vm_id" {
  description = "Proxmox VM ID (pinned, from config.yaml)"
  type        = number
}

variable "vm_name" {
  description = "VM name in Proxmox (e.g., dns1-prod)"
  type        = string
}

variable "hostname" {
  description = "Hostname set via cloud-init (e.g., dns1 — no environment prefix)"
  type        = string
}

variable "instance_id" {
  description = "cloud-init instance-id (e.g., dns1-prod)"
  type        = string
}

variable "target_node" {
  description = "Proxmox node to deploy to (e.g., pve01)"
  type        = string
}

variable "image_file_id" {
  description = "Proxmox file ID for the VM disk image (e.g., local:iso/base-v0.1.raw). Upload the image to the node's ISO storage first via upload-image.sh."
  type        = string
}

variable "vlan_id" {
  description = "VLAN tag for the VM's network interface (null = native/untagged)"
  type        = number
  default     = null
}

variable "mac_address" {
  description = "Pre-assigned MAC address (02:xx:xx format from config.yaml)"
  type        = string
}

variable "ram_mb" {
  description = "RAM in megabytes"
  type        = number
  default     = 512
}

variable "cores" {
  description = "CPU cores"
  type        = number
  default     = 1
}

variable "vda_size_gb" {
  description = "OS disk size in GB (must be >= image virtual size)"
  type        = number
  default     = 16
}

variable "vdb_size_gb" {
  description = "Data disk size in GB (0 = no data disk)"
  type        = number
  default     = 0
}

variable "ssh_pubkey" {
  description = "Framework SSH public key from SOPS (CI runner access)"
  type        = string
}

variable "operator_ssh_pubkey" {
  description = "Operator workstation SSH public key from config.yaml"
  type        = string
  default     = ""
}

variable "write_files" {
  description = "Files to inject via cloud-init write_files"
  type = list(object({
    path        = string
    content     = string
    permissions = string
  }))
  default = []
}

variable "ha_enabled" {
  description = "Whether to create an HA resource for this VM"
  type        = bool
  default     = true
}

variable "start_vms" {
  description = "Whether OpenTofu should start this managed NixOS VM."
  type        = bool
  default     = true
}

variable "register_ha" {
  description = "Whether OpenTofu should register this VM's HA resource."
  type        = bool
  default     = true
}

variable "storage_pool" {
  description = "ZFS pool name for disks"
  type        = string
  default     = "local-zfs"
}

variable "all_node_names" {
  description = "List of all Proxmox node names in the cluster (for snippet replication to support HA)"
  type        = list(string)
  default     = [] # If empty, falls back to [target_node] (single-node, no HA snippet replication)
}

variable "domain" {
  description = "Base domain (e.g., example.com). Written to /run/secrets/domain in CIDATA to ensure domain changes trigger VM recreation."
  type        = string
  default     = ""
}

variable "ip_address" {
  description = "Static IPv4 address for the primary NIC (from config.yaml)"
  type        = string
}

variable "subnet_mask" {
  description = "Subnet prefix length (e.g., 24)"
  type        = string
  default     = "24"
}

variable "gateway" {
  description = "Default gateway for the primary NIC"
  type        = string
}

variable "dns_servers" {
  description = "DNS server IPs"
  type        = list(string)
  default     = []
}

variable "search_domain" {
  description = "DNS search domain (e.g., prod.example.com)"
  type        = string
  default     = ""
}

variable "mgmt_nic" {
  description = "Optional management network NIC (on vmbr1). Set to null if not needed."
  type = object({
    ip          = string
    mac_address = string
  })
  default = null
}

variable "tailscale_auth_key" {
  description = "Tailscale pre-auth key. When non-empty, delivered via CIDATA to /run/secrets/tailscale/auth-key"
  type        = string
  default     = ""
}

variable "extra_ca_cert" {
  description = "Optional PEM-encoded extra CA certificate delivered via CIDATA to /run/secrets/extra-ca-cert"
  type        = string
  default     = ""
}

variable "vault_approle_role_id" {
  description = "Vault AppRole role_id for vault-agent authentication (from SOPS)"
  type        = string
  default     = ""
}

variable "vault_approle_secret_id" {
  description = "Vault AppRole secret_id for vault-agent authentication (from SOPS)"
  type        = string
  default     = ""
}

variable "mounts" {
  description = "Optional network mounts (NFS, CIFS, etc.) delivered via CIDATA"
  type = list(object({
    path    = string
    device  = string
    fstype  = string
    options = optional(string, "")
  }))
  default = []
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

variable "field_updatable" {
  description = "Skip recreation for image/CIDATA changes and rely on converge-vm.sh --closure for software updates"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Proxmox VM tags"
  type        = list(string)
}
