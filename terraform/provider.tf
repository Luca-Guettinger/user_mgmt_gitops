# Declared explicitly (rather than relying on the provider's own
# DIGITALOCEAN_TOKEN env lookup) so it can be passed as a variable. No
# default, and marked sensitive so it never prints in plan/apply output.
# Still never belongs in a committed file - supply it with -var,
# TF_VAR_do_token, or a real (gitignored) .tfvars: do_token = "...".
variable "do_token" {
  type      = string
  sensitive = true
}

provider "digitalocean" {
  token = var.do_token
}
