# DNS server role — access to DNS-related secrets
path "secret/data/dns/*" {
  capabilities = ["read"]
}
