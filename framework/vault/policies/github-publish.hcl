# GitHub publish role — read-only access to the GitHub deploy key.
path "secret/data/github/deploy-key" {
  capabilities = ["read"]
}
